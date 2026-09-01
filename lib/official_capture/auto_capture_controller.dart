// auto_capture_controller.dart — 自动采集的有状态编排。
//
// 挂在现成的 pose 流上(**逐 ARFrame,20–60 Hz**),维护基准帧与去抖计时,
// 判定 fire 就回调宿主的快门入口。**不自建捕获路径** —— onFire 回调里必须是
// 现有的 `_onShutterTap()` 等价物,这样 300 张上限、in-flight 守卫、12MP 静照、
// 落盘、SfM 喂帧全部自动继承。
//
// 时钟一律取 ARPose.timestamp(ARFrame 时间轴),不用 DateTime.now(),
// 这样纯 Dart 测试可确定性复现。
//
// 2026-08-26:选帧只消费后端统一后的位姿、相机内参与可选特征健康度。
// 横/纵有效视差、前后尺度、原地旋转和重叠保底分开分类；不读取 ARKit
// trackingStateName、centerRayDepthM 或其它苹果私有质量/选帧算法。
//
// 设计见 docs/superpowers/specs/2026-08-19-auto-capture-design.md。
// 几何在 auto_capture_geometry.dart,决策谓词在 auto_capture_governor.dart;
// 本文件只做"状态 + 接线",不新造任何阈值。

import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

import '../official_dome/ar_pose.dart';
import '../official_quality/frame_quality_constants.dart';
import '../official_quality/frame_signature_similarity.dart';
import 'auto_capture_geometry.dart';
import 'auto_capture_governor.dart';
import 'continuous_feature_tracks.dart';
import 'official_actual_photo_gate.dart' show officialActualPhotoTrackAccepted;
import 'photo_card_state.dart' show medianOf;
import 'shutter_backpressure_gate.dart' show ShutterPace;

/// Stable identity for one automatic high-resolution transaction.
///
/// [runGeneration] changes every time automatic capture starts. [ticketId]
/// never repeats during the controller lifetime. A terminal receipt must
/// match both values, so a result from a stopped run cannot settle a candidate
/// admitted after restart.
class AutomaticStillTicket {
  const AutomaticStillTicket({
    required this.runGeneration,
    required this.ticketId,
  });

  final int runGeneration;
  final int ticketId;

  @override
  bool operator ==(Object other) =>
      other is AutomaticStillTicket &&
      other.runGeneration == runGeneration &&
      other.ticketId == ticketId;

  @override
  int get hashCode => Object.hash(runGeneration, ticketId);

  @override
  String toString() =>
      'AutomaticStillTicket(run=$runGeneration, ticket=$ticketId)';
}

/// Evidence from the exact high-resolution frame returned by the native
/// camera transaction. Preview candidates are never allowed to populate this
/// type.
class AcceptedAutomaticStill {
  AcceptedAutomaticStill({
    required this.frame,
    required this.captureTimestamp,
    required Uint8List gray128,
  }) : gray128 = Uint8List.fromList(gray128) {
    if (!captureTimestamp.isFinite) {
      throw ArgumentError.value(
        captureTimestamp,
        'captureTimestamp',
        'must be finite',
      );
    }
    if (gray128.length != 128 * 128) {
      throw ArgumentError.value(
        gray128.length,
        'gray128.length',
        'must be 128x128',
      );
    }
  }

  final AutoCaptureGeometryFrame frame;
  final double captureTimestamp;
  final Uint8List gray128;
}

/// Image evidence from a real 12 MP transaction that the final gate rejected.
/// It is not a photo baseline and cannot advance coverage. It only prevents the
/// preview selector from immediately requesting the same rejected view again
/// using a weaker 16x16 brightness signature.
class RejectedAutomaticStillEvidence {
  RejectedAutomaticStillEvidence({
    required Uint8List gray128,
    required this.intrinsics,
  }) : gray128 = Uint8List.fromList(gray128) {
    if (gray128.length != 128 * 128) {
      throw ArgumentError.value(
        gray128.length,
        'gray128.length',
        'must be 128x128',
      );
    }
  }

  final Uint8List gray128;
  final AutoCaptureIntrinsics intrinsics;
}

class AutoCaptureController {
  AutoCaptureController({
    required bool Function(AutomaticStillTicket ticket) onStartAnchor,
    required bool Function(AutomaticStillTicket ticket) onFire,
    required ShutterPace Function() paceProvider,
    required int Function() capturedCountProvider,
    required int Function() thermalStateProvider,
    required double? Function(ARPose pose) liveDepthProvider,
    PortableTrackHealth? Function(ARPose pose)? trackHealthProvider,
    bool? Function()? synchronousReceiptProvider,
    bool testOnlyAllowLegacySignatureEvidence = false,
  }) : _onStartAnchor = onStartAnchor,
       _onFire = onFire,
       _paceProvider = paceProvider,
       _capturedCountProvider = capturedCountProvider,
       _thermalStateProvider = thermalStateProvider,
       _liveDepthProvider = liveDepthProvider,
       _trackHealthProvider = trackHealthProvider,
       _synchronousReceiptProvider = synchronousReceiptProvider,
       _testOnlyAllowLegacySignatureEvidence =
           testOnlyAllowLegacySignatureEvidence;

  /// 自动模式起跑锚点。它不是四类运动角色中的任何一种；只有真实入队成功
  /// 才能建立 capture/geometry baseline。
  final bool Function(AutomaticStillTicket ticket) _onStartAnchor;

  /// 触发快门。**返回 true 表示入队成功** —— 只有 true 才更新基准帧。
  final bool Function(AutomaticStillTicket ticket) _onFire;

  /// 每个 pose 现问一次,不在 start() 缓存 —— 背压分级本来就是跑着变的,
  /// 缓存等于把一次采集的节奏钉死在起跑那一刻的队列深度上。
  final ShutterPace Function() _paceProvider;

  /// 同上:张数由宿主队列现问。自动拍跑着的时候手动快门也可能在加张数。
  final int Function() _capturedCountProvider;

  /// thermal 桶(0..3,<0 = 未知按冷处理)。同样每帧现问 —— 热是跑着变的。
  /// spec §7「热态 critical **只拉长间隔**、不停止」在
  /// [autoCaptureTickIntervalSec] 兑现。
  final int Function() _thermalStateProvider;

  /// 无锁定目标时用于播种一个稳定目标点的跨端 SfM 深度；有 worldOrigin 的
  /// 正常生产路径不调用。目标在本轮冻结，不用深度逐帧缩放触发阈值。
  final double? Function(ARPose pose) _liveDepthProvider;

  /// 跨端归一化的特征留存率/分布健康度。未接线时固定走 12° 常规档；这里
  /// 不读取 ARKit trackingStateName、Vision 或任何平台私有质量枚举。
  final PortableTrackHealth? Function(ARPose pose)? _trackHealthProvider;

  /// Deterministic host/test adapter. Production leaves this null because its
  /// 12 MP receipt is asynchronous and arrives through [resolveAutomaticStill].
  final bool? Function()? _synchronousReceiptProvider;

  /// Unit-test seam for older geometry/state-machine fixtures that deliberately
  /// isolate themselves from the visual front end. Production never sets this;
  /// the page source contract forbids it. With the default false, missing exact
  /// grayscale/intrinsics evidence always fails closed.
  final bool _testOnlyAllowLegacySignatureEvidence;

  bool _running = false;
  int _runGeneration = 0;
  int _nextAutomaticTicketId = 1;
  AutoCaptureGeometryFrame? _captureBaseline;
  AutoCaptureGeometryFrame? _geometryBaseline;
  Vector3? _activeTarget;
  Uint8List? _capturedSignature;
  Uint8List? _rejectedCandidateSignature;

  /// How often a failed automatic candidate could NOT arm the retry-suppression
  /// signature, because the candidate had none.
  ///
  /// The comment below the failure branch promises this controller "does not
  /// blindly retry the camera a few milliseconds later against the same scene."
  /// On 2026-08-31 it did exactly that: a 12 MP capture failed on malformed
  /// intrinsics and a second shutter fired 125 ms later on the same scene, two
  /// haptics 167 ms apart. The suppression signature is only armed when the
  /// pending candidate HAS a signature, and signatures come from the 6 Hz
  /// grayscale sampler while firing happens on the 60 Hz pose tick — a
  /// candidate born between two samples carries none, and the branch that would
  /// have armed the guard is skipped in silence.
  ///
  /// Counters only: nothing here changes when the controller fires. They exist
  /// so the next occurrence proves or refutes that explanation instead of
  /// leaving it an inference.
  /// Pose fallback for the retry-suppression guard, used ONLY when the failed
  /// candidate had no signature.
  ///
  /// The guard below ("does not blindly retry the camera a few milliseconds
  /// later against the same scene") is armed from `_pendingSignature`, and a
  /// signature can be absent: signatures come from the 6 Hz grayscale sampler
  /// while firing happens on the 60 Hz pose tick, so a candidate born between
  /// two samples carries none. A native capture failure — malformed intrinsics,
  /// which fails before the 12 MP frame exists — also arrives with no rejected
  /// evidence at all, so it lands on exactly that branch. With no signature the
  /// branch was skipped in silence and nothing suppressed the retry: measured
  /// 2026-08-31, two haptics 167 ms apart, and 458 ms on another session.
  ///
  /// Content is the better signal and stays primary — a stationary user whose
  /// SCENE changed must still be able to shoot, which is what
  /// `blocks retries until that same feature gate sees new content` pins. This
  /// is only the floor for when content is unavailable, and it uses the same
  /// motion classifier and the same thresholds as the photo gate rather than
  /// inventing a second number.
  AutoCaptureGeometryFrame? _rejectedCandidatePose;
  int _failedCandidatesWithoutSignature = 0;
  int _failedCandidatesWithSignature = 0;
  int _suppressedRepeatOfRejected = 0;
  Uint8List? _rejectedActualGray128;
  double? _rejectedActualFocalX;
  double? _rejectedActualFocalY;
  double? _rejectedActualPrincipalX;
  double? _rejectedActualPrincipalY;
  Uint8List? _capturedGray128;
  double? _capturedGrayFocalX;
  double? _capturedGrayFocalY;
  double? _capturedGrayPrincipalX;
  double? _capturedGrayPrincipalY;
  final ContinuousFeatureTracks _continuousTracks = ContinuousFeatureTracks();
  double? _lastTrackedGraySourceTimestamp;
  static const double _kMaximumGraySourceAgeSec = 1.0 / 6.0;

  /// 本轮起点(ARFrame 时间轴)。**注意本轮 ≠ 整场**:时间上限按整场累积,
  /// 见 [_elapsedBeforeRunSec]。
  double _startedAtSec = 0;

  /// 本轮**之前**各轮已经跑掉的自动拍时长(秒),整场累积。
  ///
  /// 〔2026-08-19 D8 改正〕此前 `start()` 把起点置成本帧时间戳、不带任何
  /// 累积,于是用户点停再点开就把 5 分钟预算整个清零。而 D8 那两条上限
  /// (300 张 / 5 分钟)**都是防过热的独立天花板,热是整场累积的**;300 张
  /// 那条本来就跨轮累计(宿主的 capturedCountProvider 读的是整场张数),
  /// 时间这条逐轮清零等于把自己架空 —— 切一次模式就能无限续杯。
  ///
  /// 累的是**自动拍真正在跑的时长**,不是从进采集页起算的墙钟:停着的那段
  /// 不进预算,而手动模式下的时长由 300 张那条天花板管。controller 实例是
  /// **每次采集一个**(采集页 State 的 `late final` 字段),所以"本对象累计"
  /// 就是"整场累计",不需要额外的会话标识。
  double _elapsedBeforeRunSec = 0;

  /// 本轮最近一帧的时间戳,收尾时用来把本轮时长结算进 [_elapsedBeforeRunSec]。
  double _lastPoseSec = 0;

  /// 上一次开火尝试(不论入队成败)的时刻 —— 去抖/背压闸的参照。
  /// 入队失败时基准帧不动,重试节奏由它统一管(spec §7「下 tick 重试」:
  /// 旧判据时代 R2 绕过 tick 需要单独的失败冷却,新判据只有一条开火路,
  /// 这一个时钟就够了)。
  double _lastTickSec = 0;

  /// 最近一次真实的启动锚点入队尝试。null 表示还没试过；这种情况下第一
  /// 帧恢复正常 tracking 后必须立刻拍，250ms 地板只约束一次真实拒绝后的
  /// 重试，不能惩罚算法尚未获得健康姿态的冷启动阶段。
  double? _lastStartAnchorAttemptSec;

  /// 本段(距上一次开火以来)的锐度样本(roiSharpness,6Hz 随 pose 到达)。
  /// 只保留给遥测观察，不参与快门授权或硬拒绝。AliceVision 的离线段内
  /// 排序不能被伪装成可回溯的实时 12 MP 选择。
  final List<double> _segmentSharpness = <double>[];
  static const int _kSegmentSharpnessCap = 64;
  static const int _kSharpnessMedianMinSamples = 3;

  /// Aether3D 的原版帧级硬门：全图 Laplacian variance < 200 即拒收。
  /// 这是跨端同一份 128×128 灰度计算，不读取平台私有质量枚举。
  static bool _objectivelyBlurry(FrameQualityReport? quality) =>
      quality != null &&
      quality.sharpness < FrameQualityConstants.blurThresholdLaplacian;

  static bool _objectivelyBadExposure(FrameQualityReport? quality) =>
      quality != null &&
      (quality.meanBrightness < FrameQualityConstants.darkThresholdBrightness ||
          quality.meanBrightness >
              FrameQualityConstants.brightThresholdBrightness);

  bool get isRunning => _running;

  /// 整场已经跑掉的自动拍时长(秒)。用于测试断言"停/开不清零"这条不变量
  /// (D8,见 [_elapsedBeforeRunSec])。
  double get sessionElapsedSec => _elapsedBeforeRunSec;

  /// 基准帧(上一张真正入队的照片,或起跑种子)的相机位置。
  /// **测试接缝** —— 断言"入队失败时基准帧不动"用。null = 尚未播种。
  Vector3? get baselinePosition => _captureBaseline?.camera;

  /// 上一张真正具备正式三角化基线的帧。前后连接帧与原地旋转覆盖帧不会
  /// 推动它，否则会把尚未形成的几何进展误当成已经完成。
  Vector3? get geometryBaselinePosition => _geometryBaseline?.camera;

  /// 最近一次判定用的量,**只读、只给遥测**。判定本身不读它们。
  double? get lastMovedM => _lastMovedM;
  double? _lastMovedM;
  double? get lastTurnDeg => _lastTurnDeg;
  double? _lastTurnDeg;
  double? get lastFireDistM => _lastFireDistM;
  double? _lastFireDistM;
  AutoCaptureMotionRole? get lastMotionRole => _lastMotion?.role;
  double? get lastGeometryParallaxDeg => _lastMotion?.geometryParallaxDeg;
  double? get lastOverlapFraction => _lastMotion?.overlapFraction;
  double? get lastDepthScaleRatio => _lastMotion?.depthScaleRatio;
  double? get lastVisualSimilarity => _lastVisualSimilarity;
  double? _lastVisualSimilarity;
  FrameTrackEvidence? get lastTrackEvidence => _lastTrackEvidence;
  FrameTrackEvidence? _lastTrackEvidence;
  FrameTrackEvidence? get lastRejectedActualTrackEvidence =>
      _lastRejectedActualTrackEvidence;
  FrameTrackEvidence? _lastRejectedActualTrackEvidence;
  double? get lastVisualSourceAgeSec => _lastVisualSourceAgeSec;
  double? _lastVisualSourceAgeSec;
  AutoCaptureMotionMetrics? get lastMotionMetrics => _lastMotion;
  bool get shouldPromptSlowDown => _lastMotion?.shouldPromptSlowDown ?? false;
  AutoCaptureMotionMetrics? _lastMotion;
  bool _automaticStillPending = false;
  AutomaticStillTicket? _pendingAutomaticStillTicket;
  AutoCaptureGeometryFrame? _pendingCaptureFrame;
  AutoCaptureMotionMetrics? _pendingMotion;
  Uint8List? _pendingSignature;
  FrameQualityReport? _pendingQuality;
  double? _pendingCandidateTimestamp;
  bool _pendingIsStartAnchor = false;
  Vector3? _pendingTarget;

  bool get hasPendingAutomaticStill => _automaticStillPending;

  /// See [_failedCandidatesWithoutSignature]. Surfaced so the page can fold
  /// these into the periodic auto_capture telemetry it already writes.
  int get failedCandidatesWithoutSignature => _failedCandidatesWithoutSignature;
  int get failedCandidatesWithSignature => _failedCandidatesWithSignature;
  int get suppressedRepeatOfRejected => _suppressedRepeatOfRejected;
  AutomaticStillTicket? get pendingAutomaticStillTicket =>
      _pendingAutomaticStillTicket;
  double? get lastAcceptedStillTimestamp => _lastAcceptedStillTimestamp;
  double? _lastAcceptedStillTimestamp;

  /// 最新锐度样本与本段中位(只给遥测):开火帧锐度 ≥ 段中位的占比
  /// 就是锐度缓拍门的疗效指标 —— 门在干活,开火帧应系统性不低于中位。
  ///
  /// ⚠️ 是**判定时快照的字段**,不是活 getter:开火会把锐度段清空
  /// (subsequence 语义),页面在 onPose 返回后才读遥测 —— 活 getter 在
  /// 开火帧上永远读到空(b29 真机实证 fire_sharpness 恒 None 的成因)。
  double? get lastSharpness => _lastSharpness;
  double? _lastSharpness;
  double? get lastSegmentMedianSharpness => _lastSegMedianSharpness;
  double? _lastSegMedianSharpness;
  void start(ARPose pose) {
    _runGeneration += 1;
    _running = true;
    _startedAtSec = pose.timestamp;
    _lastPoseSec = pose.timestamp;
    _lastTickSec = pose.timestamp;
    _lastStartAnchorAttemptSec = null;
    // ⚠️ [_elapsedBeforeRunSec] **刻意不清** —— D8:5 分钟是整场累积的热
    // 天花板,不是每轮自动拍各发一份。清它就等于"点停再点开"能无限续杯。
    // 新一轮 = 新场景:锐度遥测段不跨轮继承。
    _segmentSharpness.clear();
    // spec §7「tracking 丢失 / limited ⇒ 暂停触发,**且基准帧不更新**」是
    // 无条件的,起跑那一帧也算:丢跟踪时的位置估计不可信,拿它当基准会
    // 毒化整轮的位移判据。播种推迟到 onPose 里第一帧正常的位姿。
    _captureBaseline = null;
    _geometryBaseline = null;
    _activeTarget = null;
    _capturedSignature = null;
    _rejectedCandidateSignature = null;
    _clearRejectedActualEvidence();
    _capturedGray128 = null;
    _capturedGrayFocalX = null;
    _capturedGrayFocalY = null;
    _capturedGrayPrincipalX = null;
    _capturedGrayPrincipalY = null;
    _lastTrackedGraySourceTimestamp = null;
    _continuousTracks.clear();
    _lastVisualSimilarity = null;
    // A previously admitted automatic 12 MP transaction survives a quick
    // stop/restart until its terminal receipt arrives. Starting a new run must
    // not enqueue a second automatic transaction beside it.
    if (_trackingNormal(pose) && !_automaticStillPending) {
      _lastStartAnchorAttemptSec = pose.timestamp;
      _requestStartAnchor(pose);
    }
  }

  void stop() {
    // 先结算本轮时长再翻 _running:整场预算按"自动拍真正在跑的时间"累积。
    _settleElapsed(_lastPoseSec);
    _running = false;
    _captureBaseline = null;
    _geometryBaseline = null;
    _activeTarget = null;
    _capturedSignature = null;
    _rejectedCandidateSignature = null;
    _clearRejectedActualEvidence();
    _capturedGray128 = null;
    _capturedGrayFocalX = null;
    _capturedGrayFocalY = null;
    _capturedGrayPrincipalX = null;
    _capturedGrayPrincipalY = null;
    _lastTrackedGraySourceTimestamp = null;
    _continuousTracks.clear();
    _lastVisualSimilarity = null;
    _lastStartAnchorAttemptSec = null;
    _segmentSharpness.clear();
  }

  /// Terminal receipt from the canonical 4032×3024 transaction. Admission to
  /// the shutter queue is not a photograph and therefore cannot advance any
  /// spatial baseline.
  bool resolveAutomaticStill({
    required AutomaticStillTicket ticket,
    required bool accepted,
    AcceptedAutomaticStill? acceptedStill,
    RejectedAutomaticStillEvidence? rejectedStill,
  }) {
    if (!_automaticStillPending || ticket != _pendingAutomaticStillTicket) {
      return false;
    }
    // A receipt from an admitted ticket must still be consumed after stop, but
    // it belongs to neither the stopped run nor a subsequently restarted run.
    // Clearing it re-arms the new run without letting an old frame advance any
    // capture, geometry, or visual baseline.
    if (!_running || ticket.runGeneration != _runGeneration) {
      _clearPendingAutomaticStill();
      return true;
    }
    if (accepted) {
      if (acceptedStill == null) {
        throw ArgumentError.notNull('acceptedStill');
      }
      final frame = acceptedStill.frame;
      _captureBaseline = frame;
      if (_pendingIsStartAnchor ||
          (_pendingMotion?.advancesGeometryBaseline ?? false)) {
        _geometryBaseline = frame;
      }
      if (_pendingIsStartAnchor && _pendingTarget != null) {
        _activeTarget = _pendingTarget!.clone();
      }
      _commitAcceptedStill(acceptedStill);
      _rejectedCandidateSignature = null;
      _rejectedCandidatePose = null;
      _clearRejectedActualEvidence();
    } else if (rejectedStill != null) {
      _rememberRejectedActualEvidence(rejectedStill);
      _rejectedCandidateSignature = null;
      _rejectedCandidatePose = null;
    } else if (_pendingSignature != null) {
      // A failed automatic candidate is not a photo baseline, but requesting
      // the same preview content again is a blind retry. Keep only a retry-
      // suppression signature; spatial/geometry baselines remain untouched.
      _failedCandidatesWithSignature++;
      _rejectedCandidateSignature = Uint8List.fromList(_pendingSignature!);
      _rejectedCandidatePose = null;
    } else {
      // No signature to arm the content guard, so fall back to the pose the
      // failed candidate was shot from. See [_rejectedCandidatePose].
      _failedCandidatesWithoutSignature++;
      _rejectedCandidatePose = _pendingCaptureFrame;
    }
    // A rejected 12 MP frame re-arms spatial selection. It does not blindly
    // retry the camera a few milliseconds later against the same scene.
    _segmentSharpness.clear();
    _clearPendingAutomaticStill();
    return true;
  }

  void _clearPendingAutomaticStill() {
    _automaticStillPending = false;
    _pendingAutomaticStillTicket = null;
    _pendingCaptureFrame = null;
    _pendingMotion = null;
    _pendingSignature = null;
    _pendingQuality = null;
    _pendingCandidateTimestamp = null;
    _pendingIsStartAnchor = false;
    _pendingTarget = null;
  }

  /// 把 `[_startedAtSec, tSec]` 这段并进整场累计,并把本轮起点推到 [tSec]。
  /// **幂等**:连着调两次(用户停 + dispose 各调一次)第二次加的是 0。
  void _settleElapsed(double tSec) {
    final run = tSec - _startedAtSec;
    if (run > 0) _elapsedBeforeRunSec += run;
    _startedAtSec = tSec;
  }

  AutoCaptureDecision onPose(ARPose pose) {
    if (!_running) return AutoCaptureDecision.skipNotMoved;
    // 本轮最后一帧 —— stop() 用它把本轮时长结算进整场累计(D8)。
    _lastPoseSec = pose.timestamp;
    // 收锐度样本(6Hz 随 pose 到达,大多数帧为 null)。
    final q = pose.quality;
    if (q != null) {
      _segmentSharpness.add(q.roiSharpness);
      if (_segmentSharpness.length > _kSegmentSharpnessCap) {
        _segmentSharpness.removeAt(0);
      }
    }
    final captureBase = _captureBaseline;
    final geometryBase = _geometryBaseline;
    final trackingOk = _trackingNormal(pose);
    final current = _frameFrom(pose);
    final currentSignature = _signatureFrom(pose);
    final rejectedCandidateSignature = _rejectedCandidateSignature;
    final rejectedCandidateSimilarity =
        currentSignature == null || rejectedCandidateSignature == null
        ? null
        : aetherFrameSignatureSimilarity(
            current: currentSignature,
            previous: rejectedCandidateSignature,
          );
    final repeatsRejectedCandidate =
        rejectedCandidateSimilarity != null &&
        rejectedCandidateSimilarity > FrameQualityConstants.maxFrameSimilarity;
    if (repeatsRejectedCandidate) _suppressedRepeatOfRejected++;
    if (!repeatsRejectedCandidate && currentSignature != null) {
      _rejectedCandidateSignature = null;
    }
    // The start anchor can land on one of the pose-only ticks between the
    // 6 Hz grayscale samples. The first real visual sample becomes its
    // conservative comparison baseline; that same sample therefore cannot
    // immediately spend another photo.
    if (_capturedSignature == null &&
        captureBase != null &&
        currentSignature != null) {
      _capturedSignature = Uint8List.fromList(currentSignature);
    }
    if (_capturedGray128 == null && captureBase != null && q != null) {
      _commitTrackSource(q);
    }
    final capturedSignature = _capturedSignature;
    final visualSimilarity =
        currentSignature == null || capturedSignature == null
        ? null
        : aetherFrameSignatureSimilarity(
            current: currentSignature,
            previous: capturedSignature,
          );
    final currentGray = q?.rawGray128;
    final currentFocalX = q?.sourceFocalX;
    final currentFocalY = q?.sourceFocalY;
    final currentPrincipalX = q?.sourcePrincipalX;
    final currentPrincipalY = q?.sourcePrincipalY;
    final rejectedActualGray = _rejectedActualGray128;
    final rejectedActualTrackEvidence =
        rejectedActualGray == null ||
            currentGray == null ||
            currentGray.length != 128 * 128 ||
            currentFocalX == null ||
            currentFocalY == null ||
            currentPrincipalX == null ||
            currentPrincipalY == null ||
            _rejectedActualFocalX == null ||
            _rejectedActualFocalY == null ||
            _rejectedActualPrincipalX == null ||
            _rejectedActualPrincipalY == null
        ? null
        : trackFrameNovelty(
            previousGray: rejectedActualGray,
            currentGray: currentGray,
            width: 128,
            height: 128,
            focalXPixels: (_rejectedActualFocalX! + currentFocalX) * 0.5,
            focalYPixels: (_rejectedActualFocalY! + currentFocalY) * 0.5,
            principalXPixels:
                (_rejectedActualPrincipalX! + currentPrincipalX) * 0.5,
            principalYPixels:
                (_rejectedActualPrincipalY! + currentPrincipalY) * 0.5,
          );
    final rejectedActualStillBlocksRetry =
        rejectedActualGray != null &&
        (rejectedActualTrackEvidence == null ||
            !officialActualPhotoTrackAccepted(rejectedActualTrackEvidence));
    _lastRejectedActualTrackEvidence = rejectedActualTrackEvidence;
    if (rejectedActualGray != null && !rejectedActualStillBlocksRetry) {
      _clearRejectedActualEvidence();
    }
    final previousSourceTimestamp = _lastTrackedGraySourceTimestamp;
    final sourceTimestamp = q?.sourceTimestamp;
    final sourceAgeSec = sourceTimestamp == null
        ? null
        : pose.timestamp - sourceTimestamp;
    final sourceBound =
        sourceAgeSec != null &&
        sourceAgeSec.isFinite &&
        sourceAgeSec >= 0 &&
        sourceAgeSec <= _kMaximumGraySourceAgeSec;
    final sourceOrderValid =
        sourceTimestamp != null &&
        (previousSourceTimestamp == null ||
            sourceTimestamp > previousSourceTimestamp);
    // Every post-anchor candidate must carry the exact portable grayscale and
    // intrinsics receipt. The legacy 16x16 block signature is diagnostics and
    // retry suppression only; it must never become platform-dependent shutter
    // authority when a bridge omits the feature-tracking source.
    final trackEvidenceRequired =
        !_testOnlyAllowLegacySignatureEvidence || currentGray != null;
    final trackEvidence =
        !sourceBound ||
            !sourceOrderValid ||
            currentGray == null ||
            currentFocalX == null ||
            currentFocalY == null ||
            currentPrincipalX == null ||
            currentPrincipalY == null ||
            currentGray.length != 128 * 128
        ? null
        : _continuousTracks.advance(
            gray: currentGray,
            width: 128,
            height: 128,
            focalXPixels: _capturedGrayFocalX == null
                ? currentFocalX
                : (_capturedGrayFocalX! + currentFocalX) * 0.5,
            focalYPixels: _capturedGrayFocalY == null
                ? currentFocalY
                : (_capturedGrayFocalY! + currentFocalY) * 0.5,
            principalXPixels: _capturedGrayPrincipalX == null
                ? currentPrincipalX
                : (_capturedGrayPrincipalX! + currentPrincipalX) * 0.5,
            principalYPixels: _capturedGrayPrincipalY == null
                ? currentPrincipalY
                : (_capturedGrayPrincipalY! + currentPrincipalY) * 0.5,
          );
    if (trackEvidence != null && sourceTimestamp != null) {
      _lastTrackedGraySourceTimestamp = sourceTimestamp;
    }
    final evidenceRetention = trackEvidence?.commonTrackFraction;
    final evidenceDistribution = trackEvidence?.vinsOccupiedGridFraction;
    final portableTrackHealth =
        evidenceRetention != null &&
            evidenceRetention.isFinite &&
            evidenceRetention >= 0 &&
            evidenceRetention <= 1 &&
            evidenceDistribution != null &&
            evidenceDistribution.isFinite
        ? PortableTrackHealth(
            retentionRatio: evidenceRetention,
            distributionHealthy: evidenceDistribution >= 0.5,
          )
        : _trackHealthProvider?.call(pose);
    final target = _activeTarget ?? _targetFrom(pose);
    final effectiveCaptureBase = captureBase ?? current;
    final effectiveGeometryBase = geometryBase ?? effectiveCaptureBase;
    final motion = classifyAutoCaptureMotion(
      geometryBaseline: effectiveGeometryBase,
      captureBaseline: effectiveCaptureBase,
      current: current,
      target: target,
      trackHealth: portableTrackHealth,
    );

    final movedM = captureBase == null
        ? 0.0
        : (pose.position - captureBase.camera).length;

    // 档位与热态都**每帧现问**:两者都是跑着变的(见各自 provider 的注释)。
    final tickIntervalSec = autoCaptureTickIntervalSec(
      pace: _paceProvider(),
      thermalState: _thermalStateProvider(),
    );
    final decision = autoCaptureDecideMotion(
      trackingNormal: trackingOk,
      capturedCount: _capturedCountProvider(),
      // 整场累积(D8):本轮已跑 + 之前各轮已跑。
      elapsedSec: _elapsedBeforeRunSec + (pose.timestamp - _startedAtSec),
      sinceLastTickSec: pose.timestamp - _lastTickSec,
      tickIntervalSec: tickIntervalSec,
      motion: motion,
      visualSimilarity: visualSimilarity,
      trackEvidence: trackEvidence,
      trackEvidenceRequired: trackEvidenceRequired,
      blurry: _objectivelyBlurry(q),
      exposureRejected: _objectivelyBadExposure(q),
    );
    _lastMovedM = movedM;
    _lastTurnDeg = motion.viewTurnDeg;
    _lastFireDistM = null;
    _lastMotion = motion;
    _lastVisualSimilarity = visualSimilarity;
    _lastTrackEvidence = trackEvidence;
    _lastVisualSourceAgeSec = sourceAgeSec;
    // 锐度快照必须在 fire 分支清段**之前**落下(见 getter 注释)。
    _lastSharpness = _segmentSharpness.isEmpty ? null : _segmentSharpness.last;
    _lastSegMedianSharpness =
        _segmentSharpness.length < _kSharpnessMedianMinSamples
        ? null
        : medianOf(_segmentSharpness);
    switch (decision) {
      case AutoCaptureDecision.skipCapped:
      case AutoCaptureDecision.skipTimeLimit:
        // 到顶就停,不再每帧撞一次墙。先结算本轮时长(与 stop() 同一条路,
        // 自停这条路根本不经过 stop() —— 宿主的 _stopAutoCapture 开头就
        // `if (!isRunning) return;`)。
        _settleElapsed(pose.timestamp);
        _running = false;
        return decision;
      case AutoCaptureDecision.skipTracking:
        // 丢跟踪期间**不播种**:位置估计不可信(spec §7)。
        return decision;
      case AutoCaptureDecision.skipNoVisualEvidence:
      case AutoCaptureDecision.skipRedundant:
        return decision;
      case AutoCaptureDecision.skipBlurry:
      case AutoCaptureDecision.skipQuality:
        // 客观模糊是硬拒绝；基准与去抖时钟都不动。下一份清晰视觉样本
        // 仍可立即开火，但等待多久都不会把糊片强行放入队列。
        return decision;
      case AutoCaptureDecision.skipNotMoved:
      case AutoCaptureDecision.skipPaced:
        // 起跑锚点没入队或起跑帧 tracking 异常时，基准保持为空；后续只在
        // tracking 恢复后的第一帧立即尝试；只有真实入队被拒后，才等共同
        // 250 ms 地板再重试。绝不能把一帧没拍下来的 pose 偷偷播成
        // “上一张照片”。
        if (captureBase == null || geometryBase == null) {
          if (_automaticStillPending) {
            return AutoCaptureDecision.skipPaced;
          }
          final lastAttemptSec = _lastStartAnchorAttemptSec;
          if (trackingOk &&
              !repeatsRejectedCandidate &&
              (lastAttemptSec == null ||
                  pose.timestamp - lastAttemptSec >=
                      kAutoCaptureSafetyDebounceSec)) {
            _lastStartAnchorAttemptSec = pose.timestamp;
            _lastTickSec = pose.timestamp;
            _requestStartAnchor(pose);
          }
          return AutoCaptureDecision.skipNotMoved;
        }
        return decision;
      case AutoCaptureDecision.fire:
        if (_automaticStillPending) return AutoCaptureDecision.skipPaced;
        if (rejectedActualStillBlocksRetry) {
          return rejectedActualTrackEvidence == null
              ? AutoCaptureDecision.skipNoVisualEvidence
              : AutoCaptureDecision.skipRedundant;
        }
        if (repeatsRejectedCandidate) {
          return AutoCaptureDecision.skipRedundant;
        }
        // Pose floor for the same guard, active ONLY when the failed candidate
        // had no signature to arm the content check with. See
        // [_rejectedCandidatePose]. Same classifier and same thresholds as the
        // photo gate — deliberately not a second number.
        final rejectedPose = _rejectedCandidatePose;
        if (rejectedPose != null) {
          final sinceRejected = classifyAutoCaptureMotion(
            geometryBaseline: rejectedPose,
            captureBaseline: rejectedPose,
            current: current,
            target: target,
            trackHealth: portableTrackHealth,
          );
          if (!sinceRejected.shouldCapture) {
            return AutoCaptureDecision.skipRedundant;
          }
          _rejectedCandidatePose = null;
        }
        // 去抖先记账:入队失败按 spec §7「下 tick 重试」,不是下一帧重试 ——
        // 失败的开火照样吃掉一次节奏预算,tickIntervalSec 之内不再返回 fire。
        _lastTickSec = pose.timestamp;
        // 入队失败时基准帧**不动** —— 否则下一次会拿一个根本没拍成
        // 的位置当基准,位移闸直接漏判。
        final automaticTicket = _newAutomaticStillTicket();
        if (_onFire(automaticTicket)) {
          _automaticStillPending = true;
          _pendingAutomaticStillTicket = automaticTicket;
          _pendingCaptureFrame = current;
          _pendingMotion = motion;
          _pendingSignature = currentSignature == null
              ? null
              : Uint8List.fromList(currentSignature);
          _pendingQuality = q;
          _pendingCandidateTimestamp = pose.timestamp;
          final synchronousReceipt = _synchronousReceiptProvider?.call();
          if (synchronousReceipt != null) {
            resolveAutomaticStill(
              ticket: automaticTicket,
              accepted: synchronousReceipt,
              acceptedStill: synchronousReceipt
                  ? _syntheticAcceptedStillForTest()
                  : null,
            );
          }
        }
        return decision;
    }
  }

  /// 只消费后端统一后的 tracking 布尔值。ARKit 专属的 limited_* 字符串只
  /// 留给诊断；xrslam/ARCore/其它端不需要伪造苹果枚举才能获得同一行为。
  static bool _trackingNormal(ARPose p) => p.isTracking;

  static Vector3 _forwardOf(ARPose pose) =>
      cameraForwardInWorld(pose.orientation);

  AutoCaptureGeometryFrame _frameFrom(ARPose pose) {
    final k = pose.intrinsicFxFyCxCy;
    return AutoCaptureGeometryFrame(
      camera: pose.position.clone(),
      orientation: pose.orientation.clone(),
      intrinsics: AutoCaptureIntrinsics(
        fx: k.length >= 4 ? k[0] : 0,
        fy: k.length >= 4 ? k[1] : 0,
        cx: k.length >= 4 ? k[2] : 0,
        cy: k.length >= 4 ? k[3] : 0,
        imageWidth: pose.imageWidth,
        imageHeight: pose.imageHeight,
      ),
    );
  }

  Vector3 _targetFrom(ARPose pose) {
    final originDistance = (pose.worldOrigin - pose.position).length;
    if (pose.hasOrigin && originDistance.isFinite && originDistance > 0.05) {
      return pose.worldOrigin.clone();
    }

    // 无锁定目标时只允许跨端 SfM 深度作冷启动近似；不读 centerRayDepthM，
    // 因为后者是苹果原生 raycast，不能成为四端一致算法的依赖。
    final d = _liveDepthProvider(pose);
    final depth = d != null && d.isFinite && d > 0.05 ? d : 1.0;
    return pose.position + _forwardOf(pose).normalized() * depth;
  }

  void _requestStartAnchor(ARPose pose) {
    if (_automaticStillPending) return;
    final automaticTicket = _newAutomaticStillTicket();
    if (!_onStartAnchor(automaticTicket)) return;
    _automaticStillPending = true;
    _pendingAutomaticStillTicket = automaticTicket;
    _pendingCaptureFrame = _frameFrom(pose);
    _pendingMotion = null;
    final signature = _signatureFrom(pose);
    _pendingSignature = signature == null
        ? null
        : Uint8List.fromList(signature);
    _pendingQuality = pose.quality;
    _pendingCandidateTimestamp = pose.timestamp;
    _pendingIsStartAnchor = true;
    _pendingTarget = _targetFrom(pose);
    final synchronousReceipt = _synchronousReceiptProvider?.call();
    if (synchronousReceipt != null) {
      resolveAutomaticStill(
        ticket: automaticTicket,
        accepted: synchronousReceipt,
        acceptedStill: synchronousReceipt
            ? _syntheticAcceptedStillForTest()
            : null,
      );
    }
  }

  AutomaticStillTicket _newAutomaticStillTicket() {
    final ticket = AutomaticStillTicket(
      runGeneration: _runGeneration,
      ticketId: _nextAutomaticTicketId,
    );
    _nextAutomaticTicketId += 1;
    return ticket;
  }

  AcceptedAutomaticStill _syntheticAcceptedStillForTest() {
    final frame = _pendingCaptureFrame;
    if (frame == null) {
      throw StateError('synchronous receipt has no pending candidate frame');
    }
    return AcceptedAutomaticStill(
      frame: frame,
      captureTimestamp: _pendingCandidateTimestamp ?? _lastPoseSec,
      gray128: _pendingQuality?.rawGray128 ?? Uint8List(128 * 128),
    );
  }

  void _commitAcceptedStill(AcceptedAutomaticStill still) {
    final gray = Uint8List.fromList(still.gray128);
    final intrinsics = still.frame.intrinsics;
    final imageWidth = intrinsics.imageWidth;
    final imageHeight = intrinsics.imageHeight;
    final focalX = imageWidth <= 0 ? 0.0 : intrinsics.fx * 128.0 / imageWidth;
    final focalY = imageHeight <= 0 ? 0.0 : intrinsics.fy * 128.0 / imageHeight;
    final principalX = imageWidth <= 0
        ? double.nan
        : intrinsics.cx * 128.0 / imageWidth;
    final principalY = imageHeight <= 0
        ? double.nan
        : intrinsics.cy * 128.0 / imageHeight;
    _capturedGray128 = gray;
    _capturedGrayFocalX = focalX > 0 && focalX.isFinite ? focalX : null;
    _capturedGrayFocalY = focalY > 0 && focalY.isFinite ? focalY : null;
    _capturedGrayPrincipalX = principalX.isFinite ? principalX : null;
    _capturedGrayPrincipalY = principalY.isFinite ? principalY : null;
    _capturedSignature = _signature16FromGray128(gray);
    _lastTrackedGraySourceTimestamp = still.captureTimestamp;
    _lastAcceptedStillTimestamp = still.captureTimestamp;
    _continuousTracks.setReference(gray: gray, width: 128, height: 128);
  }

  void _rememberRejectedActualEvidence(
    RejectedAutomaticStillEvidence evidence,
  ) {
    final intrinsics = evidence.intrinsics;
    if (intrinsics.imageWidth <= 0 || intrinsics.imageHeight <= 0) {
      _clearRejectedActualEvidence();
      return;
    }
    final focalX = intrinsics.fx * 128.0 / intrinsics.imageWidth;
    final focalY = intrinsics.fy * 128.0 / intrinsics.imageHeight;
    final principalX = intrinsics.cx * 128.0 / intrinsics.imageWidth;
    final principalY = intrinsics.cy * 128.0 / intrinsics.imageHeight;
    if (!focalX.isFinite ||
        !focalY.isFinite ||
        focalX <= 0 ||
        focalY <= 0 ||
        !principalX.isFinite ||
        !principalY.isFinite) {
      _clearRejectedActualEvidence();
      return;
    }
    _rejectedActualGray128 = Uint8List.fromList(evidence.gray128);
    _rejectedActualFocalX = focalX;
    _rejectedActualFocalY = focalY;
    _rejectedActualPrincipalX = principalX;
    _rejectedActualPrincipalY = principalY;
  }

  void _clearRejectedActualEvidence() {
    _rejectedActualGray128 = null;
    _rejectedActualFocalX = null;
    _rejectedActualFocalY = null;
    _rejectedActualPrincipalX = null;
    _rejectedActualPrincipalY = null;
    _lastRejectedActualTrackEvidence = null;
  }

  static Uint8List _signature16FromGray128(Uint8List gray) {
    final signature = Uint8List(16 * 16);
    for (var by = 0; by < 16; by++) {
      for (var bx = 0; bx < 16; bx++) {
        var sum = 0;
        for (var y = 0; y < 8; y++) {
          final row = (by * 8 + y) * 128 + bx * 8;
          for (var x = 0; x < 8; x++) {
            sum += gray[row + x];
          }
        }
        signature[by * 16 + bx] = sum ~/ 64;
      }
    }
    return signature;
  }

  static Uint8List? _signatureFrom(ARPose pose) {
    final quality = pose.quality;
    if (quality == null ||
        quality.signatureWidth <= 0 ||
        quality.signatureHeight <= 0 ||
        quality.signature.length !=
            quality.signatureWidth * quality.signatureHeight) {
      return null;
    }
    return quality.signature;
  }

  void _commitTrackSource(FrameQualityReport quality) {
    final gray = quality.rawGray128;
    final focalX = quality.sourceFocalX;
    final focalY = quality.sourceFocalY;
    final principalX = quality.sourcePrincipalX;
    final principalY = quality.sourcePrincipalY;
    if (gray == null ||
        gray.length != 128 * 128 ||
        focalX == null ||
        focalY == null ||
        principalX == null ||
        principalY == null ||
        !focalX.isFinite ||
        !focalY.isFinite ||
        !principalX.isFinite ||
        !principalY.isFinite ||
        focalX <= 0 ||
        focalY <= 0 ||
        principalX < 0 ||
        principalY < 0 ||
        principalX > 128 ||
        principalY > 128) {
      return;
    }
    _capturedGray128 = Uint8List.fromList(gray);
    _capturedGrayFocalX = focalX;
    _capturedGrayFocalY = focalY;
    _capturedGrayPrincipalX = principalX;
    _capturedGrayPrincipalY = principalY;
    _lastTrackedGraySourceTimestamp = quality.sourceTimestamp;
    _continuousTracks.setReference(gray: gray, width: 128, height: 128);
  }
}
