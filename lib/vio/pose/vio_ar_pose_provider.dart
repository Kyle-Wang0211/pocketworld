// vio_ar_pose_provider.dart —— 自研 VIO 臂的 `ARPoseProvider` 适配器。
//
// ══ 这一刀接的是什么 ═══════════════════════════════════════════════════════
// 2026-09-22 盘点实证:`lib/vio/pose/` 12 个文件 + `lib/vio/quality/` 6 个文件、
// 约 75 个公开契约,**生产调用者全部为 0**。唯一 import 它们的
// `lib/vio/render/` 自己也没有任何 import 者 —— 是一座够不着的探针孤岛。
//
// 缝本来就在:`CaptureSession` 收一个可选的 `ARPoseProvider`
// (`capture_session.dart:707`),默认 `PlatformARPoseProvider()`。
// 本文件就是那个缺的实现类,把
//
//     XrslamLive/XrslamSession → EnginePosePoller → VioPoseSource
//         → TrackedPose → ARPose
//
// 接成一条,并且顺手把 `lib/vio/quality/` 的可信度结论一起带出去。
//
// ══ [pw 2026-09-22 零 ARKit 那一刀] 本文件改了三处 ═════════════════════════
// 1. **换轴了。** 见 `xrslam_world_axis.dart`。交出的位姿从此是 **ARKit 口径
//    (y 向上)**,而不再是引擎自己的 z-up 世界系。真值是 09-16 共享录制的
//    SE(3) 实测拟合 `x_A=−y_X, y_A=+z_X, z_A=−x_X`;上游 SceneKit 那个
//    `(x,y,z)→(−y,−x,−z)` 行列式是 −1(镜像,不是旋转),**不是**世界系换算,
//    两者的区别写在那个文件的头上。
//    ⇒ `poseSource` 标签仍是 `'xrslam'` —— 换了系不等于变成了 ARKit;
//      下游要知道这条位姿是谁算的。
// 2. **照片有出口了。** 走 `ZeroArkitPhotoApi`(另一位 agent 实现原生侧,
//    本文件**只按签名调**)。之前是硬 `unsupported`。
// 3. **相机与会话由本文件负责起**(经 `ZeroArkitCaptureRuntime`)——
//    开关 ON 时页面不再起 ARSession,相机归我们。
//
// ══ 🔴 [pw 2026-09-22 换轴统一] 本文件是生产路径**唯一**的换轴点 ═════════
// 以前零 ARKit 臂里并存两条 z-up → y-up:本文件的 `xrslam_world_axis.dart`
// (给 dome / `gravity_align` / 落盘 extrinsic),和渲染那条
// `WorldToRenderer.zUpToYUp`(给 Filament 相机矩阵)。两者都把引擎的上送到
// y-up 的上,但**差一个 Ry(+90°) 的偏航**(算式在 world_to_renderer.dart
// 文件头)。偏航在 VIO 里不可观 ⇒ 没有"哪个对",但两条不一致,以后把按
// `ARPose` 摆的东西(照片卡片、点云)画进预览就会整体歪 90°。
// ⇒ 定案:**生产以本文件的换轴为准**(消费者最多;而且 `lockOrigin` 本来
//   就按会话重锚 `_worldYaw`,固化的偏航只是约定不是真值)。
//   新出口 [VioArPoseProvider.lastRendererPose] 交已换好的 y-up 位姿,
//   渲染器带 `PoseFrame.rendererYUp` 收,**一份位姿只换一次**。
//   `WorldToRenderer.zUpToYUp` 退成台架/探针口径。
//
// ══ 🔴 仍然**不**做的两件事 ════════════════════════════════════════════════
// * **不做显示时刻预测。** 引擎的位姿补到**图像时刻**,不是显示时刻。
//   补显示延迟要 Monado 的 `m_predict_relation`,那是另一刀。
// * **不做杠杆臂换算 —— 而且这次是查过的,不是省略。**
//   `EnginePosePoller._readFromEngine` 取的是 **CAMERA_POSE**
//   (`PwXrslamTransportCore.cpp:229` 的 `PW_XRSLAM_T_WORLD_CAMERA`),
//   ARKit 的 `camera.transform` 也是相机位姿 ⇒ **两边同口径**。
//   33.75 mm 的 `p_bc` 只在一边是 body 位姿时才要补(09-16 我们正是因为
//   没补它而带着 3.38 cm 的偏差比了很久)。这里补它反而会引入 3.38 cm。
//
// ══ 🔴 仍然缺的:喂料只在「页面没起 ARKit」时才通 ═════════════════════════
// `PwCameraSlot` 自建 `AVCaptureSession`,ARKit 在跑时独占后置相机
// (`ar_capture_page.dart:737-747` 实证:并行开 ⇒ `err=-17281`,两条都废)。
// 本刀把采集页的 ON 分支改成**不起 ARSession**,并在原生侧加了租约闸
// (`pw_zero_arkit_camera_start`)⇒ 抢不到就明确失败,不静默两败俱伤。
// 但这条路**没有在真机上跑过**(本任务禁止开摄像头/碰 iPhone),
// 只有单测级证据。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

import '../../official_capture/metric_rescale.dart' show MetricRescaleResult;
import '../../official_dome/ar_pose.dart';
import '../ffi/xrslam_session.dart';
import '../quality/initialization_window.dart';
import '../quality/pose_confidence.dart';
import 'camera_projection.dart';
import 'camera_slot_ffi.dart';
import 'engine_pose_poller.dart';
import 'tracked_pose.dart';
import '../capture/zero_arkit_capture_runtime.dart';
import '../capture/zero_arkit_photo_api.dart';
import '../capture/zero_arkit_scale_provenance.dart';
import 'vio_pose_source.dart';
import 'vio_pose_source_switch.dart';
import 'xrslam_tracking_state.dart';
import 'xrslam_world_axis.dart';

/// 从 `PwCameraSlot` 读内参。真机以外(单测、模拟器、没链引擎的构建)符号
/// 不存在 ⇒ 抛 `ArgumentError`。**一次失败就永久放弃**,与
/// `EnginePosePoller` 的粘性闸同款理由:每帧 lookup 一个不存在的符号是纯浪费。
typedef VioIntrinsicsReader = PinholeIntrinsics? Function();

/// XRSLAM 活体位姿 → `ARPose`。
///
/// 只在 [PwVioPoseSourceSwitch.isSelfVio] 为真时被构造(见
/// `ar_capture_page.dart` 的接线点)。**默认永远构造不到。**
class VioArPoseProvider implements ARPoseProvider, ARPoseSourceLabel {
  VioArPoseProvider({
    EnginePosePoller? poller,
    VioPoseSource? poseSource,
    VioIntrinsicsReader? intrinsicsReader,
    ZeroArkitCaptureRuntime? runtime,
    ZeroArkitPhotoApi? photoApi,
    this.pollInterval = const Duration(milliseconds: 16),
    this.feedWidth = 1920,
    this.feedHeight = 1440,
  }) : _poller = poller ?? EnginePosePoller(),
       _source = poseSource ?? VioPoseSource(),
       _intrinsicsReader = intrinsicsReader,
       _runtime = runtime,
       _photoApi = photoApi ?? const NativeZeroArkitPhotoApi();

  final EnginePosePoller _poller;
  final VioPoseSource _source;
  final VioIntrinsicsReader? _intrinsicsReader;

  /// 相机 + XRSLAM 会话。`null` = 由调用方自己起(台架那样),
  /// 本适配器就只读结果。生产采集页会传一个进来。
  final ZeroArkitCaptureRuntime? _runtime;

  /// 成片出口。另一位 agent 实现原生侧;本文件只按签名调。
  final ZeroArkitPhotoApi _photoApi;

  /// 尺度状态。🔴 **每条零 ARKit 采集都从「未锚定」开始** ——
  /// 没有 ARKit 可锚(SCALE-ANCHOR 是相对 ARKit 重锚的),
  /// 用户没量过距离之前 `mayReportAbsoluteDimensions` 恒 false。
  ZeroArkitScaleState _scale = ZeroArkitScaleState.unanchored;
  ZeroArkitScaleState get scaleState => _scale;

  /// 相机/会话起没起来。
  ///
  /// * `null` = 本适配器不负责起(台架那样由调用方自己起),**或者**
  ///   [start] 之后运行时还在等第一帧内参(`ZeroArkitCaptureRuntime.start`
  ///   是异步的,见其文件头「时序」段;[runtimeStarting] 为 true);
  /// * 非 null = 那一次起动的回执,成功或失败都在里面(`ok` / `error` /
  ///   `intrinsicsWaitMs`)。
  ///
  /// 内参已经在手时(台架页先自己轮询再调 [start])整条路同步完成,
  /// [start] 返回时它就已经是本次回执。
  ZeroArkitStartResult? get runtimeStart => _runtime?.lastStart;

  /// 运行时是否正在等第一帧内参(已起相机、还没建会话)。
  bool get runtimeStarting => _runtime?.starting ?? false;

  /// 尺度锚定的**唯一入口**:用户量了一段已知距离。
  ///
  /// 🔴 **不做 UI**(选点与输距离的交互由产品负责人定)。这里只把
  ///    `metric_rescale.dart` 的机制接上,并把 [scaleState] 从
  ///    「未锚定」推进到「用户距离」。
  /// 🔴 抛 `MetricRescaleException` 时 [scaleState] **不变** —— 仍是未锚定,
  ///    `mayReportAbsoluteDimensions` 仍是 false。调用方不要在 catch 里
  ///    把它打开。
  MetricRescaleResult anchorScaleWithUserDistance({
    required Float32List xyz,
    required List<double> pointA,
    required List<double> pointB,
    required double realDistanceMeters,
    Float64List? posesPacked,
    List<double>? center,
    DateTime? timestampUtc,
  }) {
    final r = anchorScaleByUserDistance(
      xyz: xyz,
      pointA: pointA,
      pointB: pointB,
      realDistanceMeters: realDistanceMeters,
      posesPacked: posesPacked,
      center: center,
      timestampUtc: timestampUtc,
    );
    _scale = r.state;
    return r.result;
  }

  int _photoRequestSeq = 0;

  /// 轮询周期。**拉取而非回调**的理由抄 `xrslam_bindings.dart` 的原注释:
  /// dart:ffi 是同步同线程的,`NativeCallable.isolateLocal` 从非创建线程调用
  /// 会硬 abort,`listener` 拿不到同步结果 ⇒ 正确形状就是 Dart 侧按需 poll。
  final Duration pollInterval;

  /// 喂给引擎的图像尺寸。只用来向 `PwCameraSlot` 要内参(进 `ARPose` 的
  /// `intrinsicFxFyCxCy` / `imageWidth` / `imageHeight`)—— 本文件不采帧。
  /// 🔴 [pw 2026-09-22 改口] 默认 1920×1440 = 采集尺寸,与
  ///    `ZeroArkitCaptureRuntime` 的默认喂料尺寸同步(用户铁律「最低 1920×1440」,
  ///    理由在那个文件头「改口」段)。以前默认 640×480。
  final int feedWidth;
  final int feedHeight;

  @override
  String get poseSourceLabel =>
      PwVioPoseSourceSwitch.labelOf(PwVioPoseSource.xrslam);

  final StreamController<ARPose> _controller =
      StreamController<ARPose>.broadcast();
  final Stopwatch _clock = Stopwatch();
  Timer? _timer;
  ARPose? _last;
  bool _stopped = false;

  Vector3 _worldOrigin = Vector3.zero();
  double _worldYaw = 0;
  bool _hasOrigin = false;

  // ── 可信度 ───────────────────────────────────────────────────────────────
  // `lib/vio/quality/` 的三条判据里,**只有初始化窗口这一条**能靠位姿流
  // 自己驱动;纹理判据要关键点(引擎导出的 `GetResultFeatures` 是**空实现**),
  // 尺度可观测性要世界系线加速度(要 IMU 流 + 已解算重力)。
  // 🔴 所以这里只喂得起 `VioInitializationGate` 一条,另两条**如实留空**
  //    (`null` ⇒ 汇总时按 fail-safe 方向算)。不去编一个假的样本填上。
  final VioInitializationGate _initGate = VioInitializationGate();
  VioPoseConfidence _confidence = VioPoseConfidence.unknown;

  /// 最近一帧的可信度。**永远非 null** —— 第一帧之前是
  /// [VioPoseConfidence.unknown]。
  VioPoseConfidence get confidence => _confidence;

  final StreamController<VioPoseConfidence> _confCtrl =
      StreamController<VioPoseConfidence>.broadcast();

  /// 与 [start] 的位姿流一一对应的可信度流。
  Stream<VioPoseConfidence> get confidenceStream => _confCtrl.stream;

  /// 引擎为什么不可用(`null` = 正常或还没试过)。诊断用。
  Object? get engineUnavailableReason => _poller.unavailableReason;

  @override
  ARPose? get lastPose => _last;

  /// 最近一次引擎位姿,**引擎系**(XRSLAM z-up),**未换轴**。
  ///
  /// 🔴 [pw 2026-09-22 换轴统一] **渲染器不再用它**。
  ///    以前预览把这条喂给 `ArRenderLoop`,由 `WorldToRenderer.zUpToYUp`
  ///    自己换轴 —— 那是第二条换轴,与 [lastPose] 走的
  ///    `xrslam_world_axis.dart` 差一个 Ry(+90°) 的偏航。现在渲染器改吃
  ///    [lastRendererPose],本 getter **只剩诊断用途**(想看引擎原样交出
  ///    什么,以及 `test/zero_arkit_camera_preview_test.dart` 的 (D) 组
  ///    仍据它钉住"两条不能混")。
  TrackedPose? get lastTrackedPose => _lastTracked;
  TrackedPose? _lastTracked;

  /// 最近一次位姿,**已经是 y 向上**(ARKit / 渲染器口径)。
  ///
  /// ══ 这是渲染器唯一该读的那条 ═══════════════════════════════════════════
  /// 它与 [lastPose] 的 `position` / `orientation` / `extrinsic4x4` 来自
  /// **同一次** `_toArPose` 的换算(`xrslam_world_axis.dart`),不是再算一遍
  /// —— 再算一遍就给了两份结果各自漂移的机会。
  ///
  /// ARKit 世界系与 OpenXR/Filament 的渲染器世界系是同一套约定(右手、
  /// y 上、相机看 −z),所以喂给 `ArRenderLoop.step` 时要带
  /// `poseFrame: PoseFrame.rendererYUp`,让它**一次都不要再换**。
  ///
  /// 四个 OpenXR 标志位(VALID/TRACKED × 朝向/位置)与 [lastTrackedPose]
  /// **逐位相同** —— 换轴只动数值,不动"这个字段能不能读"。
  TrackedPose? get lastRendererPose => _lastRenderer;
  TrackedPose? _lastRenderer;

  @override
  Stream<ARPose> start() {
    if (_timer != null) return _controller.stream;
    _stopped = false;
    if (!_clock.isRunning) _clock.start();
    // 🔴 相机 + 会话在这里起,**不等它起完**就开始轮询:`ARPoseProvider.start()`
    //    的签名是同步的(接口如此,`CaptureSession.attach()` 也不 await 它),
    //    而运行时起相机之后要等第一帧内参(异步,见
    //    `zero_arkit_capture_runtime.dart` 文件头「时序」段)。
    //    ⇒ `unawaited(...)`(仓里现成写法:`lib/main.dart` 的
    //    `unawaited(DeviceLog.init())`),定时器照起;会话建成之前每一 tick
    //    交出的位姿**如实**是 none / `isTracking=false`,`CaptureSession` 的
    //    既有闸把它们挡在落盘外。起不来**不抛**,打印一次 —— 抛了会把整个
    //    采集页打成 `_initError`,而这条臂本来就是研究臂。
    unawaited(_startRuntime());
    _timer = Timer.periodic(pollInterval, (_) => tick());
    return _controller.stream;
  }

  Future<void> _startRuntime() async {
    final ZeroArkitCaptureRuntime? rt = _runtime;
    if (rt == null) return;
    final ZeroArkitStartResult r = await rt.start();
    // 被自己的 [stop] 叫停不算「起不来」,不打这一行。
    if (!r.ok && !_stopped) {
      // ignore: avoid_print
      print('[zero-arkit] 运行时起不来:$r');
    }
  }

  /// 拉一帧并投递。生产由 [start] 的 Timer 驱动;单测直接调它,
  /// **不要**在测试里等真实定时器。
  void tick() {
    if (_stopped || _controller.isClosed) return;
    final double now = _clock.elapsedMicroseconds / 1e6;
    final EnginePoseSample sample = _poller.poll(nowSeconds: now);
    // 🔴 `stationaryAttitude` 传 null:静止姿态要重力解算(`gravity_attitude`
    //    + `StationarityGate`),那条链由台架页 `StaticInitPoseChain` 驱动,
    //    需要一条独立的 IMU 订阅。采集页上 IMU 已经被 `OrientationTracker`
    //    占着,再起一条是第二个 CMMotionManager —— 上游明确不这么做。
    //    ⇒ 本适配器不供 3DOF 兜底,如实少这一档。
    final TrackedPose tracked = _source.update(
      sample: sample,
      stationaryAttitude: null,
      nowSeconds: now,
    );
    _lastTracked = tracked;

    final VioFrameDisposition disposition = _initGate.admit(tSec: now);
    _confidence = summarizeVioPoseConfidence(
      poseStage: _source.stage,
      scale: null,
      disposition: disposition,
      texture: null,
    );

    final ARPose pose = _toArPose(tracked, now);
    _last = pose;
    if (!_controller.isClosed) _controller.add(pose);
    if (!_confCtrl.isClosed) _confCtrl.add(_confidence);
  }

  ARPose _toArPose(TrackedPose tracked, double now) {
    final PoseQuaternion? q = tracked.orientation;
    final PosePosition? p = tracked.position;

    // 🔴 **换轴在这里发生,而且只发生一次。**
    //    引擎交出的是 XRSLAM 的 z-up 世界系;下游(az/el 数学、dome、
    //    gravity_align、落盘的 extrinsic)全部按 ARKit 的 y-up 写。
    //    不换就是把 z-up 塞进 y-up 的消费者 —— 不抛异常,只是安静地全错。
    //    真值与「为什么只左乘」见 `xrslam_world_axis.dart`。
    final Quaternion orientationEngine = q == null
        ? Quaternion.identity()
        : Quaternion(q.x, q.y, q.z, q.w);
    final Vector3 positionEngine = p == null
        ? Vector3.zero()
        : Vector3(p.x, p.y, p.z);

    final Quaternion orientation =
        xrslamOrientationToArkit(orientationEngine);
    final Vector3 position = xrslamPositionToArkit(positionEngine);

    // 🔴 渲染器那条出口就在这里派生,**复用上面这一次换算**,不再算第二遍。
    //    见 [lastRendererPose]。
    _lastRenderer = _toRendererPose(
      tracked,
      orientation: q == null ? null : orientation,
      position: p == null ? null : position,
    );

    double azimuth = 0, elevation = 0;
    if (_hasOrigin && p != null) {
      final double relX = position.x - _worldOrigin.x;
      final double relY = position.y - _worldOrigin.y;
      final double relZ = position.z - _worldOrigin.z;
      final double horiz = math.sqrt(relX * relX + relZ * relZ);
      azimuth = math.atan2(relZ, relX) - _worldYaw;
      elevation = math.atan2(relY, horiz < 0.001 ? 0.001 : horiz);
    } else if (q != null) {
      final Vector3 forward = cameraForwardInWorld(orientation);
      azimuth = math.atan2(forward.x, forward.z);
      elevation = math.asin(forward.y.clamp(-1.0, 1.0));
    }

    final PinholeIntrinsics? k = _readIntrinsics();

    return ARPose(
      position: position,
      orientation: orientation,
      azimuth: azimuth,
      elevation: elevation,
      // 🔴 只有 6DOF 才算「在跟踪」。lastKnown 那一档规范上是 VALID 但
      //    **不是** TRACKED,交给下游当成跟踪中是错的。
      isTracking: tracked.isSixDegreeOfFreedom,
      timestamp: tracked.timestampSeconds > 0 ? tracked.timestampSeconds : now,
      hasOrigin: _hasOrigin,
      worldOrigin: _worldOrigin.clone(),
      worldYaw: _worldYaw,
      // 引擎自己世界系下的 camera→world。列主序 16 个 double,与
      // `arkit_extrinsic_4x4` 同形状但**不同系** —— 靠 poseSource='xrslam'
      // 区分,见文件头第 1 条。
      // 已换系的 camera→world。与 `arkit_extrinsic_4x4` **同形状且同系**,
      // 但仍靠 poseSource='xrslam' 标明是谁算的(换了系 ≠ 变成了 ARKit)。
      extrinsic4x4: (q != null && p != null)
          ? xrslamCameraToWorldArkitColumnMajor(
              orientationEngine,
              positionEngine,
            )
          : const <double>[],
      intrinsicFxFyCxCy: k == null
          ? const <double>[]
          : <double>[k.fx, k.fy, k.cx, k.cy],
      imageWidth: k?.imageWidth ?? 0,
      imageHeight: k?.imageHeight ?? 0,
      // 🔴 `XRSLAMGetResult(RESULT_FEATURES)` 在出货引擎里是**空实现**
      //    (09-19 实证),所以稀疏锚点数只能是 0。**不编一个数填上** ——
      //    填了会直接骗过 `capture_session` 的
      //    `_minScaleAlignAnchorsForPersistedFrame` 闸。
      scaleAlignAnchorCount: 0,
      scaleAlignDepthSpanM: 0.0,
      scaleAlignReliabilityPrior: 0.0,
      trackingStateName: _trackingStateName(tracked),
      quality: null,
      previewPoints: const <ARPreviewPoint>[],
    );
  }

  /// 把换过轴的数值包回一个 `TrackedPose`,**四个标志位逐位照搬**。
  ///
  /// 🔴 不用 `TrackedPose.tracked` 一档打天下:那会把 3DOF(位置不可观)
  ///    和跟丢之后的 lastKnown 一起谎报成"正在跟踪",而 `TrackedPose` 的
  ///    整个存在理由就是不让人误读不该读的字段(tracked_pose.dart 规范
  ///    语义 (1)(2)(3))。所以逐档还原:
  ///      · 朝向都没有        ⇒ none
  ///      · 只有朝向          ⇒ orientationOnly
  ///      · 六自由度且在跟踪  ⇒ tracked
  ///      · 其余(VALID 不 TRACKED)⇒ lastKnown
  TrackedPose _toRendererPose(
    TrackedPose source, {
    required Quaternion? orientation,
    required Vector3? position,
  }) {
    final double t = source.timestampSeconds;
    if (orientation == null) return TrackedPose.none(timestampSeconds: t);
    final PoseQuaternion q = PoseQuaternion(
      orientation.x,
      orientation.y,
      orientation.z,
      orientation.w,
    );
    if (position == null) {
      return TrackedPose.orientationOnly(orientation: q, timestampSeconds: t);
    }
    final PosePosition p = PosePosition(position.x, position.y, position.z);
    if (source.isSixDegreeOfFreedom) {
      return TrackedPose.tracked(
        orientation: q,
        position: p,
        timestampSeconds: t,
      );
    }
    return TrackedPose.lastKnown(
      orientation: q,
      position: p,
      timestampSeconds: t,
      orientationStillTracked: source.orientationTracked,
    );
  }

  /// 把 XRSLAM 的引擎状态翻成 `ARPose.trackingStateName` 的既有词表。
  ///
  /// 🔴 [pw 2026-09-22] 映射表搬到 `xrslam_tracking_state.dart`,并且**改了
  ///    一处**:原来 `lastKnown` 档报 `'limited_relocalizing'` —— 那是**错的**,
  ///    出货 XRSLAM 构建**没有重定位**(loop closure 结果通道 09-19 实证是
  ///    空实现)。报一个不存在的能力会让 `PoseDriftTracker` 的分桶读起来
  ///    像「它在重定位,再等等」,而实际上它永远不会回来。
  ///    现在 `lastKnown`(引擎不再报 TRACKING_SUCCESS)走引擎状态表 ⇒
  ///    `limited_unknown`,并在表里显式标成 confidence=unknown。
  String _trackingStateName(TrackedPose tracked) {
    if (tracked.isSixDegreeOfFreedom) return 'normal';
    return xrslamTrackingStateName(
      engineState: _poller.lastState,
      sessionAlive: XrslamSession.current != null,
    );
  }

  bool _intrinsicsGaveUp = false;

  PinholeIntrinsics? _readIntrinsics() {
    final reader = _intrinsicsReader;
    if (reader != null) return reader();
    if (_intrinsicsGaveUp) return null;
    try {
      return PwCameraSlot.intrinsics(
        imageWidth: feedWidth,
        imageHeight: feedHeight,
      );
    } catch (_) {
      // 符号不在(没链引擎 / 单测 / 模拟器)⇒ 永久放弃,不每帧付异常的钱。
      _intrinsicsGaveUp = true;
      return null;
    }
  }

  @override
  Future<ARLockResult?> lockOrigin({double distanceMeters = 1.0}) async {
    final ARPose? last = _last;
    if (last == null || !last.isTracking) {
      // 还没有 6DOF ⇒ 锁不了。调用方按契约在下一帧重试。
      return null;
    }
    final Vector3 forward = cameraForwardInWorld(last.orientation);
    _worldOrigin = last.position + forward.normalized() * distanceMeters;
    final Vector3 rel = last.position - _worldOrigin;
    _worldYaw = math.atan2(rel.z, rel.x);
    _hasOrigin = true;
    return ARLockResult(worldOrigin: _worldOrigin, worldYaw: _worldYaw);
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _timer?.cancel();
    _timer = null;
    _clock.stop();
    // 相机与会话一停,位姿就是陈旧的 —— 渲染器不该再拿到它。
    // 两条出口一起清:留一条不清等于留一条陈旧位姿的后门。
    _lastTracked = null;
    _lastRenderer = null;
    // 🔴 相机与会话必须跟着停,否则离开采集页后相机还开着(而且租约还在
    //    我们名下 ⇒ 再进页面时 ARKit 那条臂也起不来)。`stop` 是幂等的。
    _runtime?.stop();
  }

  Future<void> dispose() async {
    await stop();
    _poller.dispose();
    _source.reset();
    await _controller.close();
    await _confCtrl.close();
  }

  // ── 照片路径:走 `ZeroArkitPhotoApi` ───────────────────────────────────
  //
  // 🔴 **实现不在这里。** 原生侧的 `AVCapturePhotoOutput` 由另一位 agent 落地,
  //    已 cherry-pick 进本分支(`405eca6`);本文件经 [ZeroArkitPhotoApi]
  //    转调他们的门面 `lib/vio/ffi/pw_camera_photo_ffi.dart`。
  //    符号不在(模拟器 / Release 没导出)⇒ 门面自己降级返回 null,
  //    这里如实返回 `unsupported`,**不假装落盘成功** ——
  //    假装成功会让 `CaptureSession` 以为有图而实际没有。
  //
  // 🔴 成片是从**我们自己的相机流**出来的,不是 `ARFrame.capturedImage`。
  //    所以内参/曝光也跟着成片一起回来(`ZeroArkitPhotoResult`),
  //    不用再去猜「这张图是用哪组内参拍的」。

  /// 请求一张成片并等它回来。超时/失败返回 `null`。
  ///
  /// 🔴 有界轮询,**不等真实墙钟的 `Future.delayed` 链** —— 09-22 栽过一次:
  ///    让测试去等墙钟只会把「异常」伪装成「很慢」。
  Future<ZeroArkitPhotoResult?> requestPhoto({
    Duration timeout = const Duration(seconds: 3),
    Duration pollEvery = const Duration(milliseconds: 20),
  }) {
    // 🔴 [pw 2026-09-22 零 ARKit 成片提升] **串行化。** 原生只有一个结果槽
    //    (`pw_camera_slot_photo_result` 交最近一张),两条请求并发时,先完成
    //    的那张会被后完成的覆盖,而它的轮询方只会按 requestId 等到超时。
    //    采集页的手动快门正是两条并发调用者(证据 spec + 预览 spec),所以把
    //    请求排成一条 Future 链 —— 标准 dart:async 做法,不是新机制。
    final Future<ZeroArkitPhotoResult?> next = _photoChain
        .catchError((_) => null)
        .then((_) => _requestPhotoNow(timeout: timeout, pollEvery: pollEvery));
    _photoChain = next;
    return next;
  }

  Future<ZeroArkitPhotoResult?> _photoChain = Future<ZeroArkitPhotoResult?>.value();

  Future<ZeroArkitPhotoResult?> _requestPhotoNow({
    required Duration timeout,
    required Duration pollEvery,
  }) async {
    final int id = ++_photoRequestSeq;
    // 🔴 [pw 2026-09-22 真机] 原生 `pw_camera_slot_capture_photo` **成功返回 0**
    //    (门面 `pw_camera_photo_ffi.dart`:「返回 0 已受理;负数是原生失败码」),
    //    **不是** requestId。以前这里拿受理码去比 `r.requestId`,永远不等 ⇒
    //    13 次快门全部 3 s 超时报 `unsupported`,而原生每张都写好了
    //    (4032×3024 JPEG + sidecar,request_id 正确)。
    //    受理码只判「受没受理」;配对用**我们自己发出去的** [id]。
    final int? accepted = _photoApi.capturePhoto(id);
    if (accepted == null || accepted < 0) return null;

    final Stopwatch sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      final ZeroArkitPhotoResult? r = _photoApi.photoResult();
      // 🔴 按 requestId 配对,**不按到达顺序** —— 上一张迟到的结果会被
      //    当成这一张,而且不会报任何错。
      if (r != null && r.requestId == id) return r;
      await Future<void>.delayed(pollEvery);
    }
    return null;
  }

  @override
  Future<bool> saveCurrentFrameAsJpeg({
    required String jpegPath,
    required String metadataPath,
    double? targetTimestamp,
    double maxTimestampDelta = 0.18,
    double quality = 0.9,
  }) async {
    // 旧入口。`CaptureSession` 的生产路径已全部走密封的 [saveCurrentFrame];
    // 这里如实 false,不再另开一条半套的实现。
    return false;
  }

  // ══ [pw 2026-09-22 零 ARKit 成片提升] saveCurrentFrame 真正落到 spec ═════
  //
  // 之前这里拍了一张、报 `saved_elsewhere`,`CaptureSession` 看到非 saved 就打
  // `photo not promoted` —— 一张都进不了库,而且与 [captureHighResolutionStill]
  // 各拍一张 ⇒ 一次快门两次曝光。现在:
  //   · 一次调用只拍**一张**([requestPhoto],按 requestId 配对);
  //   · 原生写好的 JPEG **搬到** `spec.jpegPath`(`File.rename`,跨卷失败
  //     退成 copy + delete —— dart:io 标准做法);
  //   · 在 `spec.metadataPath` 写 sidecar,**键名逐个照抄原生 ARKit 帧 sidecar
  //     的密封契约**(`ios/Runner/OfficialAetherARKitPlugin.swift:2763-2790`,
  //     `saveCurrentFrame` 那条 "Per-photo metadata JSON"),值用真实的 VIO
  //     数据;VIO 没有的东西写空/0 并标 provenance,**不编**;
  //   · 两个文件都落地才报 `saved`;任何一步失败如实非 saved + message。
  //
  // 🔴 触发时刻位姿的口径:进入本方法时同步取 [_last]。`CaptureSession` 传的
  //    `spec.targetTimestamp` 就是它自己 `lastPose.timestamp`,而 `lastPose`
  //    正是 [_last] —— 两者是同一条位姿,所以不必再按时间戳去找"最近者"。
  //    照片的曝光发生在这之后(AVFoundation 回执的 `t`),配对差写进
  //    `save_dt` / `pose_pairing`,由下游自己判断。

  @override
  Future<ARFrameSaveResult> saveCurrentFrame(ARFrameSaveSpec spec) async {
    // 先取位姿再拍:没有位姿的成片进不了库,拍了只是白曝光一次。
    final ARPose? pose = _last;
    if (pose == null) {
      return ARFrameSaveResult(
        spec: spec,
        status: 'no_pose',
        message: '零 ARKit 臂尚无任何位姿(未 tick),不拍',
      );
    }
    final ZeroArkitScaleState scaleAtTrigger = _scale;

    final ZeroArkitPhotoResult? r = await requestPhoto();
    if (r == null) {
      return ARFrameSaveResult(
        spec: spec,
        status: 'unsupported',
        message: '成片接口不可用(pw_camera_slot_capture_photo 未链入)'
            '或超时未返回',
      );
    }

    // 🔴 原生在支持 HEVC 的机型上按 AVCam 默认写 **HEIC**
    //    (`PwCameraSlot.swift` 拍照 settings:`availablePhotoCodecTypes.contains(.hevc)`
    //    ⇒ `.heic`)。把 HEIC 改名成 `.jpg` 是把一张不是 JPEG 的文件塞给整条
    //    只认 JPEG 的下游。如实拒绝,文件留在原生写的位置。
    final String lower = r.path.toLowerCase();
    if (!(lower.endsWith('.jpg') || lower.endsWith('.jpeg'))) {
      return ARFrameSaveResult(
        spec: spec,
        status: 'native_format_not_jpeg',
        message: '原生成片是 ${r.path.split('.').last},不是 JPEG;'
            '未搬到 ${spec.jpegPath}(不改名伪装)',
      );
    }
    final File source = File(r.path);
    if (!await source.exists()) {
      return ARFrameSaveResult(
        spec: spec,
        status: 'jpeg_missing',
        message: '原生回执指向 ${r.path},但文件不存在',
      );
    }

    // 原生自己的 sidecar(同名 .json,`PwCameraSlot.swift` 写的)——
    // 读进来整体嵌到我们的 sidecar 里(保留 intrinsics/exposure provenance),
    // 然后删掉孤儿。读不到就不嵌,不算失败。
    final Map<String, Object?>? nativeSidecar = await _readNativeSidecar(
      r.path,
    );

    try {
      await _moveFile(source, spec.jpegPath);
    } catch (e) {
      return ARFrameSaveResult(
        spec: spec,
        status: 'jpeg_move_failed',
        message: '${r.path} → ${spec.jpegPath}: $e',
      );
    }

    final Map<String, Object?> sidecar = buildFrameSidecar(
      spec: spec,
      pose: pose,
      photo: r,
      scale: scaleAtTrigger,
      nativeSidecar: nativeSidecar,
    );
    try {
      final File meta = File(spec.metadataPath);
      await meta.parent.create(recursive: true);
      await meta.writeAsString(jsonEncode(sidecar), flush: true);
    } catch (e) {
      return ARFrameSaveResult(
        spec: spec,
        status: 'metadata_write_failed',
        message: '${spec.metadataPath}: $e(JPEG 已在 ${spec.jpegPath})',
      );
    }
    return ARFrameSaveResult(spec: spec, status: 'saved');
  }

  /// 帧 sidecar。**键名逐个照抄** `ios/Runner/OfficialAetherARKitPlugin.swift`
  /// `saveCurrentFrame` 执行器写的那份(2763-2790 行):
  ///
  ///   version / native_role / t / image_w / image_h / extrinsic /
  ///   intrinsics_fxfycxcy / trackingStateName / tracking_state / is_tracking /
  ///   anchors_world / anchor_ids /
  ///   scale_align_premetrics{anchor_depth_count, anchor_depth_min_m,
  ///     anchor_depth_max_m, anchor_depth_span_m, reliability_prior} /
  ///   save_dt / dart_save_contract / save_target_t
  ///
  /// 额外键**只加不改**:`poseSource`(与 `CaptureSession._sampleToCanonicalJson`
  /// 同名)、`source` / `exposure_s`(与 `PwCameraSlot.swift` 的 sidecar 同名)、
  /// `scale_provenance`、`pose_pairing`、`photo_request_id`、`native_photo_sidecar`。
  ///
  /// 公开是为了单测能逐键核对;生产只经 [saveCurrentFrame] 调。
  static Map<String, Object?> buildFrameSidecar({
    required ARFrameSaveSpec spec,
    required ARPose pose,
    required ZeroArkitPhotoResult photo,
    required ZeroArkitScaleState scale,
    Map<String, Object?>? nativeSidecar,
  }) {
    final double? target = spec.targetTimestamp;
    final String trackingState = pose.trackingStateName ?? 'not_available';
    return <String, Object?>{
      // ── 原生契约的键,顺序照抄 ──
      'version': spec.metadataSchemaVersion,
      'native_role': 'pw_camera_slot_photo_output',
      't': photo.timestampSeconds,
      'image_w': photo.width,
      'image_h': photo.height,
      // 触发时刻 ARPose 的 camera→world,列主序 16 个,**已是 y-up**
      // (`xrslam_world_axis.dart`,本文件 `_toArPose` 唯一换轴点)。
      // 非 6DOF 时是空表 —— 如实,`CaptureSession` 的闸会拒。
      'extrinsic': List<double>.of(pose.extrinsic4x4),
      // 成片回执里的**全分辨率**内参(对方门面契约:已缩到照片像素尺寸)。
      'intrinsics_fxfycxcy': <double>[photo.fx, photo.fy, photo.cx, photo.cy],
      'trackingStateName': trackingState,
      'tracking_state': trackingState,
      'is_tracking': pose.isTracking,
      // 🔴 VIO 没有 ARKit 深度锚点:出货引擎 `RESULT_FEATURES` 是空实现。
      //    写空/0,不编。尺度来源见下方 `scale_provenance`。
      'anchors_world': const <List<double>>[],
      'anchor_ids': const <int>[],
      'scale_align_premetrics': <String, Object?>{
        'anchor_depth_count': 0,
        'anchor_depth_min_m': 0.0,
        'anchor_depth_max_m': 0.0,
        'anchor_depth_span_m': 0.0,
        'reliability_prior': 0.0,
      },
      // 原生:`abs(timestamp - targetTimestamp)`,无 target 时 0.0。
      'save_dt': target == null ? 0.0 : (photo.timestampSeconds - target).abs(),
      'dart_save_contract': spec.toJson(),
      'save_target_t': ?target,
      // ── 额外键(只加不改)──
      'poseSource': PwVioPoseSourceSwitch.labelOf(PwVioPoseSource.xrslam),
      'source': 'avfoundation_photo_output',
      'exposure_s': photo.exposureSeconds,
      'photo_request_id': photo.requestId,
      'scale_provenance': scale.toJson(),
      'pose_pairing': <String, Object?>{
        'policy': 'vio_pose_at_trigger',
        'pose_t': pose.timestamp,
        'photo_t': photo.timestampSeconds,
        'photo_exposure_s': photo.exposureSeconds,
        'note': 'extrinsic 是快门触发时刻的 VIO 位姿(= CaptureSession 的 '
            'lastPose);照片曝光发生在其后,t 是 AVCapturePhoto.timestamp。'
            '未做曝光中点补偿,两项原样交出。',
      },
      'native_photo_sidecar': ?nativeSidecar,
    };
  }

  /// `File.rename` 优先;跨卷(`FileSystemException`,EXDEV)退成 copy + delete。
  static Future<void> _moveFile(File source, String destPath) async {
    final File dest = File(destPath);
    await dest.parent.create(recursive: true);
    try {
      await source.rename(destPath);
    } on FileSystemException {
      await source.copy(destPath);
      await source.delete();
    }
  }

  /// 读原生同名 `.json`(`PwCapturedPhoto.sidecarPath` 同一条推导),
  /// 读到就删掉原文件(它的内容已嵌进我们的 sidecar)。任何失败 ⇒ null。
  static Future<Map<String, Object?>?> _readNativeSidecar(
    String photoPath,
  ) async {
    final int dot = photoPath.lastIndexOf('.');
    final int slash = photoPath.lastIndexOf('/');
    final String sidecarPath = dot <= slash
        ? '$photoPath.json'
        : '${photoPath.substring(0, dot)}.json';
    try {
      final File f = File(sidecarPath);
      if (!await f.exists()) return null;
      final Object? decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map) return null;
      final Map<String, Object?> out = decoded.map(
        (Object? k, Object? v) => MapEntry<String, Object?>('$k', v),
      );
      try {
        await f.delete();
      } catch (_) {
        // 孤儿删不掉不算失败。
      }
      return out;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<HighResolutionStillCapture?> captureHighResolutionStill({
    required String highresPath,
    required String previewPath,
    double? triggerTimestamp,
    double quality = 0.92,
    ARFrameSaveSpec? saveSpec,
    bool feedSfm = false,
    bool deriveAuxiliary = true,
    bool stagePhotoFeedback = false,
    String? transactionId,
    String? cardTexturePath,
    double? maxTimestampDelta,
  }) async {
    // 🔴 `HighResolutionStillCapture` 的契约里有一串 ARKit 专有字段
    //    (photo-card 反馈、SfM 灰度喂料、缩略图),零 ARKit 臂一个都产不出。
    //    半真半假地填一个回来,比返回 null 更危险 —— 下游会按「有」处理。
    //    ⇒ 如实 null,**而且不拍**。[pw 2026-09-22 零 ARKit 成片提升] 之前这里
    //    还 `await requestPhoto()` 拍了一张再返回 null,而 `CaptureSession`
    //    收到 null 之后接着调 [saveCurrentFrame] 又拍一张 ⇒ 一次快门两次曝光。
    //    现在这条把活整个让给 [saveCurrentFrame]:`CaptureSession` 走它的
    //    fallback 提升路径(`_promoteStillViaFrameSidecar` /
    //    `_fallbackStillFromMetadata`),从 JPEG + sidecar 造出
    //    `HighResolutionStillCapture`,一次快门一次曝光。
    return null;
  }
}
