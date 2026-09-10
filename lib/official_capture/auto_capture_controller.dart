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
import 'orb_descriptor.dart';
import 'visual_word_dictionary.dart';
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
    // [2026-09-07 stella_vslam] mapper 是否空闲 / 是否接受新关键帧。
    bool Function()? mapperAcceptingProvider,
    PortableTrackHealth? Function(ARPose pose)? trackHealthProvider,
  }) : _onStartAnchor = onStartAnchor,
       _onFire = onFire,
       _paceProvider = paceProvider,
       _capturedCountProvider = capturedCountProvider,
       _thermalStateProvider = thermalStateProvider,
       _liveDepthProvider = liveDepthProvider,
       _mapperAcceptingProvider = mapperAcceptingProvider ?? _alwaysTrue,
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
  final bool Function() _mapperAcceptingProvider;
  static bool _alwaysTrue() => true;
  // stella_vslam:last_inserted_keyfrm 的时刻与世界位置(insert 时更新)。
  double? _lastKeyframeSec;
  Vector3? _lastKeyframePos;

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

  /// 上游 `ref_keyfrm`(与当前画面共视最多的关键帧)的对应物 —— RTAB-Map 的
  /// 增量视觉词典。**不带预训练词表,出货成本 0。**
  /// 为什么不用 [_continuousTracks] 做这件事:它是传播式的,相机离开视角后
  /// 轨迹永久死;而 LK 本身没有「匹配对不对」的概念,跨大位移会收敛到垃圾并
  /// 报成功(实测老照片"匹配"156/160)。详见
  /// docs/handoffs/PLACE_RECOGNITION_RTABMAP_PLAN.md。
  final VisualWordDictionary _placeDictionary = VisualWordDictionary();
  int _placeSignatureSeq = 0;

  /// 最近一次地点识别的读数(遥测用)。
  PlaceRecognitionScan? _lastPlaceScan;
  PlaceRecognitionScan? get lastPlaceRecognitionScan => _lastPlaceScan;

  /// VINS-Fusion 新旧比开火条件的节流与闩锁。
  ///
  /// 检测 host 实测 1.36ms/次(128×128,含金字塔),不能上 60Hz 位姿流;
  /// 上游前端本来就只有 10Hz。0.3s ≈ 3.3Hz。时钟取 pose.timestamp ——
  /// 与本控制器其余全部计时同一条 ARFrame 时间轴(时钟纪律)。
  ///
  /// 闩锁:检测是 3.3Hz 的,判决是每 tick 的 —— 两次检测之间沿用上一次的
  /// burst 结论,否则信号会以检测节奏闪烁。开火或拍到新照片即清零。
  static const double _kNewFeatureDetectIntervalSec = 0.3;
  double _lastNewFeatureDetectSec = double.negativeInfinity;
  bool _newFeatureBurst = false;
  bool? _pendingFireSegmentReady;
  bool? _pendingFireNewFeatureBurst;

  /// 最近一次**成功**开火时,两个授权信号的状态 —— 读一次即清(一枪一账,
  /// 页面在 recordDecision 之后消费;失败的入队不留快照,与红键脉冲同一条
  /// 「开火 ≠ 拍成」纪律)。
  ({bool segmentReady, bool newFeatureBurst})? takeFireReason() {
    final segment = _pendingFireSegmentReady;
    final burst = _pendingFireNewFeatureBurst;
    _pendingFireSegmentReady = null;
    _pendingFireNewFeatureBurst = null;
    if (segment == null || burst == null) return null;
    return (segmentReady: segment, newFeatureBurst: burst);
  }

  final AliceVisionMotionSegment _smartMotionSegment = AliceVisionMotionSegment(
    width: 128,
    height: 128,
  );

  // ─── [2026-09-06 抄对①,09-07 单独复活] 实拍瞬间的基准 ─────────────────
  // 快门请求到照片真正拍成之间有 0.27–0.74 s;快扫时用请求时刻的位姿/预览
  // 当基准会过期(未命名(15):279→283 位姿差 42°,实拍画面只差 4.8%)。
  // 因此:开火后先记"等实拍",页面拿到 captureTimestamp 后回调
  // [onCaptureCompleted],从最近样本环里取**实拍瞬间**的位姿/灰度做下一张的
  // 基准与流量起点;等待期间不判定(skipAwaitingCapture)。
  // 几何基准是否前进仍按开火角色(advancesGeometryBaseline)——决策规则不动。
  final List<_RecentSample> _recent = <_RecentSample>[];

  /// 真机实测的快门事务上限(请求 → 照片真正拍成):0.27–0.74 s
  /// (2026-09-06 未命名(15) 定罪时逐张量的)。下面三个时间常数都由它推出,
  /// 不是拍脑袋的数:
  ///  * 样本环要覆盖最坏一次事务并留一倍余量 ⇒ 2 × 0.74 ≈ 1.5,取 2.0 s;
  ///  * 认定"这一份样本就是实拍那一刻"的容差取 ARKit 位姿周期(30 Hz)的
  ///    上限侧,0.25 s 覆盖 6 Hz 灰度采样的一个周期(1/6 s)还有余量;
  ///  * 回调迟迟不来的超时同样取 2.0 s —— 超过它就认定事务丢了,退回请求时刻
  ///    的临时基准,绝不让采集停摆。
  static const double kMeasuredShutterTransactionMaxSec = 0.74;
  static const double _kRecentWindowSec =
      2 * kMeasuredShutterTransactionMaxSec > 2.0
      ? 2 * kMeasuredShutterTransactionMaxSec
      : 2.0;
  static const double _kCaptureMatchToleranceSec = 0.25;
  static const double _kAwaitingCaptureTimeoutSec = _kRecentWindowSec;
  double? _awaitingCaptureSinceSec;
  bool _pendingAdvanceGeometry = false;
  bool get awaitingCaptureBaseline => _awaitingCaptureSinceSec != null;
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

  /// Apple 两级光照的 tooDark 档(见 governor 的 skipTooDark 注释)。
  /// 预览报告缺失时不判暗 —— 宁可放行,与 physFootprintMB 失败不刹车同一条
  /// 「读数失败不误伤拍照」纪律。
  static bool _tooDark(FrameQualityReport? quality) =>
      quality != null && quality.meanBrightness < kAutoCaptureTooDarkMeanLuma;

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
    _placeDictionary.clear();
    _placeSignatureSeq = 0;
    _lastPlaceScan = null;
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

  /// 页面在照片**真正拍成**后调用(快门事务完成,拿到 ARFrame 时间线上的
  /// captureTimestamp)。从最近样本环取实拍瞬间的位姿/签名/灰度做基准。
  void onCaptureCompleted({required double captureTimestampSec}) {
    if (!_running) return;
    _awaitingCaptureSinceSec = null;
    final advanceGeometry = _pendingAdvanceGeometry;
    _pendingAdvanceGeometry = false;
    if (!captureTimestampSec.isFinite || _recent.isEmpty) return;
    _RecentSample? best;
    double bestDt = double.infinity;
    for (final r in _recent) {
      final dt = (r.timestampSec - captureTimestampSec).abs();
      if (dt < bestDt) {
        bestDt = dt;
        best = r;
      }
    }
    if (best == null || bestDt > _kCaptureMatchToleranceSec) return;
    // last_inserted_keyfrm 的时刻与世界位置也要对齐到**实拍瞬间**:min_distance
    // 是从上一张照片真正拍成的位置量起的,不是从按快门那一刻量起的。快门事务
    // 0.27–0.74 s 里相机还在走,用请求时刻当原点会把距离算大 ⇒ 门形同虚设。
    _lastKeyframeSec = captureTimestampSec;
    _lastKeyframePos = best.frame.camera;
    _captureBaseline = best.frame;
    if (advanceGeometry) _geometryBaseline = best.frame;
    final sig = best.signature;
    if (sig != null) _capturedSignature = Uint8List.fromList(sig);
    // 流量起点 = 实拍瞬间最近的一份预览灰度(≤ tolerance);没有就保留
    // 请求时刻那份(临时兜底)。
    _RecentSample? grayBest;
    double grayDt = double.infinity;
    for (final r in _recent) {
      if (r.gray128 == null) continue;
      final dt = (r.timestampSec - captureTimestampSec).abs();
      if (dt < grayDt) {
        grayDt = dt;
        grayBest = r;
      }
    }
    if (grayBest != null && grayDt <= _kCaptureMatchToleranceSec) {
      _capturedGray128 = Uint8List.fromList(grayBest.gray128!);
      _capturedGrayFocalX = grayBest.focalX;
      _capturedGrayFocalY = grayBest.focalY;
      _capturedGraySourceTimestamp = grayBest.sourceTimestamp;
      _lastTrackedGraySourceTimestamp = grayBest.sourceTimestamp;
      _continuousTracks.setReference(
        gray: grayBest.gray128!,
        width: 128,
        height: 128,
      );
      _smartMotionSegment.reset();
      _newFeatureBurst = false;
    }
  }

  /// 快门事务失败:没有实拍,退回请求时刻的临时基准,恢复判定。
  void onCaptureFailed() {
    _awaitingCaptureSinceSec = null;
    _pendingAdvanceGeometry = false;
  }

  void _recordRecentSample(
    ARPose pose,
    AutoCaptureGeometryFrame frame,
    Uint8List? signature,
  ) {
    final q = pose.quality;
    final gray = q?.rawGray128;
    final fx = q?.sourceFocalX;
    final fy = q?.sourceFocalY;
    final grayOk =
        gray != null &&
        gray.length == 128 * 128 &&
        fx != null &&
        fy != null &&
        fx.isFinite &&
        fy.isFinite &&
        fx > 0 &&
        fy > 0;
    _recent.add(
      _RecentSample(
        timestampSec: pose.timestamp,
        frame: frame,
        signature: signature == null ? null : Uint8List.fromList(signature),
        gray128: grayOk ? Uint8List.fromList(gray) : null,
        focalX: grayOk ? fx : null,
        focalY: grayOk ? fy : null,
        sourceTimestamp: grayOk ? q?.sourceTimestamp : null,
      ),
    );
    while (_recent.isNotEmpty &&
        pose.timestamp - _recent.first.timestampSec > _kRecentWindowSec) {
      _recent.removeAt(0);
    }
  }

  void stop() {
    _awaitingCaptureSinceSec = null;
    _pendingAdvanceGeometry = false;
    _recent.clear();
    _lastKeyframeSec = null;
    _lastKeyframePos = null;
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
    _placeDictionary.clear();
    _placeSignatureSeq = 0;
    _lastPlaceScan = null;
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
    _recordRecentSample(pose, current, currentSignature);
    final awaitingSince = _awaitingCaptureSinceSec;
    if (awaitingSince != null &&
        pose.timestamp - awaitingSince > _kAwaitingCaptureTimeoutSec) {
      // 快门事务超时/失败没回调:退回请求时刻的临时基准,不能让采集停摆。
      _awaitingCaptureSinceSec = null;
      _pendingAdvanceGeometry = false;
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
            detectNewFeatures:
                pose.timestamp - _lastNewFeatureDetectSec >=
                _kNewFeatureDetectIntervalSec,
            focalXPixels: _capturedGrayFocalX == null
                ? currentFocalX
                : (_capturedGrayFocalX! + currentFocalX) * 0.5,
            focalYPixels: _capturedGrayFocalY == null
                ? currentFocalY
                : (_capturedGrayFocalY! + currentFocalY) * 0.5,
          );
    if (trackEvidence != null && sourceTimestamp != null) {
      _lastTrackedGraySourceTimestamp = sourceTimestamp;
      if (trackEvidence.newFeatureCount >= 0) {
        _lastNewFeatureDetectSec = pose.timestamp;
        _newFeatureBurst = trackEvidence.hasNewFeatureBurst;
      }
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
    // ─── [2026-09-07 整本复刻] stella_vslam keyframe_inserter ───────────
    // 几何角色/签名相似度/AliceVision 流量段从此只进遥测,不再决定开火。
    final lastKfSec = _lastKeyframeSec;
    final lastKfPos = _lastKeyframePos;

    // ─── 地点识别:上游 `ref_keyfrm` 的对应物 ──────────────────────────
    // 上游取的是 **argmax 共视**,不是"换一个参考"。这里也只做 argmax:
    //   候选① 最近拍的那张 —— 仍用**传播式**读数。tracker 类文档写明了理由:
    //          一次大跳变的 LK 会失败,所以它一路跟过来;对最近那张,传播式
    //          是更准的估计。
    //   候选② 更早的每一张 —— 用词袋(RTAB-Map)。它们的轨迹早就断了,只有
    //          外观检索认得出来。
    // 🔴 两个候选用的是**不同的量**(轨迹 vs 词),所以比的是**比例**而不是
    // 原始计数 —— 两者都是"参考图的特征还剩多少看得见",比例才可比。这是与
    // 上游(按共视计数 argmax)的一处明确偏离,如实记在这里。
    // 只在**这一帧确实有新灰度**时做(与 trackEvidence 同一个门)。
    PlaceRecognitionScan? placeScan;
    if (trackEvidence != null &&
        currentGray != null &&
        _placeDictionary.signatureCount > 1) {
      final swDesc = Stopwatch()..start();
      final descriptors = _describePlace(currentGray);
      swDesc.stop();
      final swQuery = Stopwatch()..start();
      final counts = _placeDictionary.quantizeQuery(descriptors);
      var bestId = 0;
      var bestShared = 0;
      var bestTotal = 0;
      var bestRatio = 0.0;
      // 末号那张 = 最近拍的,已由传播式跟踪覆盖,不重复算。
      for (final sig in _placeDictionary.signatures) {
        if (sig.signatureId >= _placeSignatureSeq) continue;
        final (shared, total) = _placeDictionary.sharedWordsWith(
          counts,
          sig.signatureId,
        );
        if (total == 0) continue;
        final ratio = shared / total;
        if (ratio > bestRatio) {
          bestRatio = ratio;
          bestId = sig.signatureId;
          bestShared = shared;
          bestTotal = total;
        }
      }
      swQuery.stop();
      placeScan = PlaceRecognitionScan(
        signatureCount: _placeDictionary.signatureCount,
        wordCount: _placeDictionary.wordCount,
        queryWordCount: counts.values.fold<int>(0, (a, b) => a + b),
        bestSignatureId: bestId,
        bestSharedWords: bestShared,
        bestReferenceWords: bestTotal,
        describeMicros: swDesc.elapsedMicroseconds,
        queryMicros: swQuery.elapsedMicroseconds,
      );
      _lastPlaceScan = placeScan;
    }
    final propagatedCommon = trackEvidence?.commonTrackCount ?? 0;
    final propagatedRef = trackEvidence?.seedTrackCount ?? 0;
    final propagatedRatio = propagatedRef == 0
        ? 0.0
        : propagatedCommon / propagatedRef;
    // 老照片只有在**比例更高**时才夺走参考权。
    final olderWins =
        placeScan != null &&
        placeScan.hasMatch &&
        placeScan.bestSharedRatio > propagatedRatio;
    // min_distance = 12% × 场景深度中位数(SVO 论文的式子;上游把这个数留给
    // 集成方)。没有活体点云深度时退回上游默认 -1 = 关闭。
    final sceneDepthM = _liveDepthProvider(pose);
    final decision = stellaVslamNewKeyframeIsNeeded(
      trackingNormal: trackingOk,
      capturedCount: _capturedCountProvider(),
      elapsedSec: _elapsedBeforeRunSec + (pose.timestamp - _startedAtSec),
      tooDark: _tooDark(q),
      awaitingCaptureBaseline: awaitingCaptureBaseline,
      blurry: _objectivelyBlurry(q),
      initialized: captureBase != null,
      mapperAccepting: _mapperAcceptingProvider(),
      // 上游 `mapper_is_skipping_localBA()` 是**罕见的背压逃生阀**:30 fps 视频、
      // 一个关键帧几十毫秒,只有建图线程被压垮到放弃局部 BA 时才为真。
      // 2026-09-07 真机定罪:我曾把它接成 `remainingCount != 0`(SfM 队列非空)。
      // 我们一张 12MP 重建要 1.1–4.1 s,这个闸于是几乎全程关闭、只在每帧落地后
      // 开几十毫秒 —— 未命名(24) 20/20 次快门都落在上一帧 `add_frame rc=ok` 之后
      // 23–303 ms 内;到达该闸的 196 个 tick 里 178 个被它挡下,而**通过它的 18 个
      // 全部开火**(skipNotMoved/skipPaced/skipMinDistance/skipBlurry 全为 0)。
      // 也就是说这个我自己编的代理是唯一在决定快门节奏的东西,复刻的 stella
      // 条件排在它后面从未生效;用户的体感是"动的时候不拍、停一两秒就拍"。
      // 队列深度不是上游那个量,接上去就是移位前提。本工程的建图侧没有
      // 「放弃局部 BA」这个状态,上游健康态的取值是 false,照搬。
      mapperSkippingLocalBA: false,
      hasTrackEvidence: trackEvidence != null,
      // `num_tracked_lms` 是**当前帧自己**跟得稳不稳(喂 tracking 不稳闸),
      // 与参考是谁无关 ⇒ 仍取传播式读数,不动。
      numTrackedLms: propagatedCommon,
      // 这两路走 ref_keyfrm(见上面的 argmax 注释)。
      numReliableLms: olderWins ? placeScan!.bestSharedWords : propagatedCommon,
      numReliableLmsRef: olderWins
          ? placeScan!.bestReferenceWords
          : propagatedRef,
      sinceLastKeyframeSec: lastKfSec == null
          ? null
          : pose.timestamp - lastKfSec,
      distanceTraveledM: lastKfPos == null
          ? null
          : (pose.position - lastKfPos).length,
      minDistanceM: autoCaptureMinDistanceMetres(sceneDepthM),
    );

    _lastMovedM = movedM;
    _lastTurnDeg = motion.viewTurnDeg;
    _lastFireDistM = null;
    _lastMotion = decision == AutoCaptureDecision.fire
        ? motion.withRole(AutoCaptureMotionRole.keyframeInserter)
        : motion;
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
      case AutoCaptureDecision.skipAwaitingCapture:
      case AutoCaptureDecision.skipMapperStopped:
      case AutoCaptureDecision.skipMapperBusy:
      case AutoCaptureDecision.skipMinDistance:
        return decision;
      case AutoCaptureDecision.skipTooDark:
      case AutoCaptureDecision.skipBlurry:
        // 客观模糊是硬拒绝；基准与去抖时钟都不动。下一份清晰视觉样本
        // 仍可立即开火，但等待多久都不会把糊片强行放入队列。
        return decision;
      case AutoCaptureDecision.skipNotMoved:
      case AutoCaptureDecision.skipPaced:
        // 起跑锚点没入队或起跑帧 tracking 异常时，基准保持为空；后续只在
        // tracking 恢复后的第一帧立即尝试;只有真实入队被拒后,才等一个
        // stella 的 min_interval(0.1 s)再重试。绝不能把一帧没拍下来的 pose
        // 偷偷播成"上一张照片"。
        // [2026-09-07 出处更正] 原来等的是自研的 250 ms 去抖地板;那个地板已随
        // 判据整本换成 stella 而退役,这里改用同一家的 min_interval。
        if (captureBase == null || geometryBase == null) {
          final lastAttemptSec = _lastStartAnchorAttemptSec;
          if (trackingOk &&
              (lastAttemptSec == null ||
                  pose.timestamp - lastAttemptSec >= kStellaMinIntervalSec)) {
            _lastStartAnchorAttemptSec = pose.timestamp;
            _lastTickSec = pose.timestamp;
            if (_onStartAnchor()) {
              // 起跑锚也是一张真照片 ⇒ 上游的 last_inserted_keyfrm 就是它。
              _lastKeyframeSec = pose.timestamp;
              _lastKeyframePos = pose.position;
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
          // 开火成因快照,页面一次性消费(takeFireReason)。必须在段清零
          // **之前**落下 —— 与锐度快照同一条纪律。
          _pendingFireSegmentReady = _smartMotionSegment.ready;
          _pendingFireNewFeatureBurst = _newFeatureBurst;
          // 请求时刻的位姿只是**临时**基准(拍成回调前的兜底);实拍瞬间的
          // 基准由 onCaptureCompleted 覆盖。几何基准是否前进仍按角色。
          _captureBaseline = current;
          if (motion.advancesGeometryBaseline) {
            _geometryBaseline = current;
          }
          _pendingAdvanceGeometry = motion.advancesGeometryBaseline;
          _awaitingCaptureSinceSec = pose.timestamp;
          // insert_new_keyframe: last_inserted_keyfrm ← 这一张
          _lastKeyframeSec = pose.timestamp;
          _lastKeyframePos = pose.position;
          _capturedSignature = Uint8List.fromList(currentSignature!);
          if (q != null) _commitTrackSource(q, entersMap: true);
          // 开火 = 本段结束,锐度段清零(subsequence 语义)。
          _segmentSharpness.clear();
          _smartMotionSegment.reset();
          _newFeatureBurst = false;
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
    if (quality != null) _commitTrackSource(quality, entersMap: true);
  }

  /// RTAB-Map `Kp/DetectorStrategy = 8`(GFTT/ORB):关键点用已复刻的
  /// goodFeaturesToTrack,描述子用 ORB。**角度传 −1** —— 上游把 GFTT 关键点
  /// 直接喂 `cv::ORB::compute`,而它对外部关键点不重算方向,实际就是 −1。
  static List<Uint8List> _describePlace(Uint8List gray) {
    final corners = goodFeaturesToTrack(
      gray: gray,
      width: 128,
      height: 128,
      maxCorners: kRtabmapMaxFeatures,
    );
    if (corners.isEmpty) return const <Uint8List>[];
    final blurred = orbBlurForDescriptors(gray, 128, 128);
    return <Uint8List>[
      for (final c in corners)
        computeOrbDescriptor(blurred, 128, 128, c.$1, c.$2, angleDeg: -1.0),
    ];
  }

  /// [entersMap] = 这一次提交对应**真的进了地图的一张照片**(开火 / 起跑锚)。
  /// 只有它才有资格当上游的 `ref_keyfrm` 候选。第三个调用点是"还没拍过任何
  /// 一张时先把跟踪器种下"的兜底 —— 那不是照片,混进候选集会让"回到从未拍过
  /// 的起始画面"被误判成重复。
  void _commitTrackSource(
    FrameQualityReport quality, {
    bool entersMap = false,
  }) {
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
    if (entersMap) {
      // 上游 insert_new_keyframe 之后这一张就进了地图、可以当 ref_keyfrm。
      final descriptors = _describePlace(gray);
      if (descriptors.isNotEmpty) {
        _placeSignatureSeq++;
        _placeDictionary.addNewWords(descriptors, _placeSignatureSeq);
      }
    }
    _capturedGray128 = Uint8List.fromList(gray);
    _capturedGrayFocalX = focalX;
    _capturedGrayFocalY = focalY;
    _capturedGraySourceTimestamp = quality.sourceTimestamp;
    _lastTrackedGraySourceTimestamp = quality.sourceTimestamp;
    _continuousTracks.setReference(gray: gray, width: 128, height: 128);
    _smartMotionSegment.reset();
    _newFeatureBurst = false;
  }
}

/// 最近 2 s 的位姿/签名/预览灰度样本(供 onCaptureCompleted 回取实拍瞬间)。
class _RecentSample {
  const _RecentSample({
    required this.timestampSec,
    required this.frame,
    required this.signature,
    required this.gray128,
    required this.focalX,
    required this.focalY,
    required this.sourceTimestamp,
  });
  final double timestampSec;
  final AutoCaptureGeometryFrame frame;
  final Uint8List? signature;
  final Uint8List? gray128;
  final double? focalX;
  final double? focalY;
  final double? sourceTimestamp;
}
