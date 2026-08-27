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
import 'alicevision_motion_segment.dart';
import 'continuous_feature_tracks.dart';
import 'photo_card_state.dart' show medianOf;
import 'shutter_backpressure_gate.dart' show ShutterPace;

class AutoCaptureController {
  AutoCaptureController({
    required bool Function() onStartAnchor,
    required bool Function() onFire,
    required ShutterPace Function() paceProvider,
    required int Function() capturedCountProvider,
    required int Function() thermalStateProvider,
    required double? Function(ARPose pose) liveDepthProvider,
    PortableTrackHealth? Function(ARPose pose)? trackHealthProvider,
  }) : _onStartAnchor = onStartAnchor,
       _onFire = onFire,
       _paceProvider = paceProvider,
       _capturedCountProvider = capturedCountProvider,
       _thermalStateProvider = thermalStateProvider,
       _liveDepthProvider = liveDepthProvider,
       _trackHealthProvider = trackHealthProvider;

  /// 自动模式起跑锚点。它不是四类运动角色中的任何一种；只有真实入队成功
  /// 才能建立 capture/geometry baseline。
  final bool Function() _onStartAnchor;

  /// 触发快门。**返回 true 表示入队成功** —— 只有 true 才更新基准帧。
  final bool Function() _onFire;

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

  bool _running = false;
  AutoCaptureGeometryFrame? _captureBaseline;
  AutoCaptureGeometryFrame? _geometryBaseline;
  Vector3? _activeTarget;
  Uint8List? _capturedSignature;
  Uint8List? _capturedGray128;
  double? _capturedGrayFocalX;
  double? _capturedGrayFocalY;
  double? _capturedGraySourceTimestamp;
  final ContinuousFeatureTracks _continuousTracks = ContinuousFeatureTracks();
  final AliceVisionMotionSegment _smartMotionSegment = AliceVisionMotionSegment(
    width: 128,
    height: 128,
  );
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
  /// 只保留给遥测观察，不参与硬拒绝。AliceVision 的段内锐度是候选排序，
  /// 不能把“低于段中位”偷换成“客观模糊”。
  final List<double> _segmentSharpness = <double>[];
  static const int _kSegmentSharpnessCap = 64;
  static const int _kSharpnessMedianMinSamples = 3;

  /// Aether3D 的原版帧级硬门：全图 Laplacian variance < 200 即拒收。
  /// 这是跨端同一份 128×128 灰度计算，不读取平台私有质量枚举。
  static bool _objectivelyBlurry(FrameQualityReport? quality) =>
      quality != null &&
      quality.sharpness < FrameQualityConstants.blurThresholdLaplacian;

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
  double? get lastVisualSourceAgeSec => _lastVisualSourceAgeSec;
  double? _lastVisualSourceAgeSec;
  AutoCaptureMotionMetrics? get lastMotionMetrics => _lastMotion;
  bool get shouldPromptSlowDown => _lastMotion?.shouldPromptSlowDown ?? false;
  AutoCaptureMotionMetrics? _lastMotion;

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
  double? get lastSegmentMotionPx => _lastSegmentMotionPx;
  double? _lastSegmentMotionPx;
  double get segmentMotionThresholdPx =>
      _smartMotionSegment.thresholdPixelMotion;

  void start(ARPose pose) {
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
    _capturedGray128 = null;
    _capturedGrayFocalX = null;
    _capturedGrayFocalY = null;
    _capturedGraySourceTimestamp = null;
    _lastTrackedGraySourceTimestamp = null;
    _continuousTracks.clear();
    _smartMotionSegment.reset();
    _lastVisualSimilarity = null;
    if (_trackingNormal(pose)) {
      _lastStartAnchorAttemptSec = pose.timestamp;
      if (_onStartAnchor()) {
        _seedBaselines(pose);
        _commitSignature(pose);
      }
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
    _capturedGray128 = null;
    _capturedGrayFocalX = null;
    _capturedGrayFocalY = null;
    _capturedGraySourceTimestamp = null;
    _lastTrackedGraySourceTimestamp = null;
    _continuousTracks.clear();
    _smartMotionSegment.reset();
    _lastVisualSimilarity = null;
    _lastStartAnchorAttemptSec = null;
    _segmentSharpness.clear();
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
    final trackEvidenceRequired = currentGray != null;
    final trackEvidence =
        !sourceBound ||
            !sourceOrderValid ||
            currentGray == null ||
            currentFocalX == null ||
            currentFocalY == null ||
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
          );
    if (trackEvidence != null && sourceTimestamp != null) {
      _lastTrackedGraySourceTimestamp = sourceTimestamp;
      _smartMotionSegment.add(trackEvidence);
      // VINS uses track loss to manage its estimator window. A camera shutter
      // cannot treat missing correspondences as new content, so reseed the
      // preview tracker and keep waiting for comparable accumulated flow.
      if (!trackEvidence.comparable && currentGray != null) {
        _continuousTracks.setReference(
          gray: currentGray,
          width: 128,
          height: 128,
        );
      }
    }
    final target = _activeTarget ?? _targetFrom(pose);
    final effectiveCaptureBase = captureBase ?? current;
    final effectiveGeometryBase = geometryBase ?? effectiveCaptureBase;
    final motion = classifyAutoCaptureMotion(
      geometryBaseline: effectiveGeometryBase,
      captureBaseline: effectiveCaptureBase,
      current: current,
      target: target,
      trackHealth: _trackHealthProvider?.call(pose),
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
      smartSelectionMotionReady: _smartMotionSegment.ready,
      blurry: _objectivelyBlurry(q),
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
    _lastSegmentMotionPx = _smartMotionSegment.accumulatedPixelMotion;

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
          final lastAttemptSec = _lastStartAnchorAttemptSec;
          if (trackingOk &&
              (lastAttemptSec == null ||
                  pose.timestamp - lastAttemptSec >=
                      kAutoCaptureSafetyDebounceSec)) {
            _lastStartAnchorAttemptSec = pose.timestamp;
            _lastTickSec = pose.timestamp;
            if (_onStartAnchor()) {
              _seedBaselines(pose);
              _commitSignature(pose);
            }
          }
          return AutoCaptureDecision.skipNotMoved;
        }
        return decision;
      case AutoCaptureDecision.fire:
        // 去抖先记账:入队失败按 spec §7「下 tick 重试」,不是下一帧重试 ——
        // 失败的开火照样吃掉一次节奏预算,tickIntervalSec 之内不再返回 fire。
        _lastTickSec = pose.timestamp;
        // 入队失败时基准帧**不动** —— 否则下一次会拿一个根本没拍成
        // 的位置当基准,位移闸直接漏判。
        if (_onFire()) {
          _captureBaseline = current;
          if (motion.advancesGeometryBaseline) {
            _geometryBaseline = current;
          }
          _capturedSignature = Uint8List.fromList(currentSignature!);
          if (q != null) _commitTrackSource(q);
          // 开火 = 本段结束,锐度段清零(subsequence 语义)。
          _segmentSharpness.clear();
          _smartMotionSegment.reset();
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

  void _seedBaselines(ARPose pose) {
    final frame = _frameFrom(pose);
    _captureBaseline = frame;
    _geometryBaseline = frame;
    _activeTarget = _targetFrom(pose);
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

  void _commitSignature(ARPose pose) {
    final signature = _signatureFrom(pose);
    if (signature != null) {
      _capturedSignature = Uint8List.fromList(signature);
    }
    final quality = pose.quality;
    if (quality != null) _commitTrackSource(quality);
  }

  void _commitTrackSource(FrameQualityReport quality) {
    final gray = quality.rawGray128;
    final focalX = quality.sourceFocalX;
    final focalY = quality.sourceFocalY;
    if (gray == null ||
        gray.length != 128 * 128 ||
        focalX == null ||
        focalY == null ||
        !focalX.isFinite ||
        !focalY.isFinite ||
        focalX <= 0 ||
        focalY <= 0) {
      return;
    }
    _capturedGray128 = Uint8List.fromList(gray);
    _capturedGrayFocalX = focalX;
    _capturedGrayFocalY = focalY;
    _capturedGraySourceTimestamp = quality.sourceTimestamp;
    _lastTrackedGraySourceTimestamp = quality.sourceTimestamp;
    _continuousTracks.setReference(gray: gray, width: 128, height: 128);
    _smartMotionSegment.reset();
  }
}
