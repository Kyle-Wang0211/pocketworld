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
    this.feedWidth = 640,
    this.feedHeight = 480,
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

  /// 相机/会话起没起来(`null` = 本适配器不负责起)。
  ZeroArkitStartResult? get runtimeStart => _runtime?.lastStart;

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

  /// 喂给引擎的图像尺寸。只用来向 `PwCameraSlot` 要内参 —— 本文件不采帧。
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
  /// 给渲染器用:`WorldToRenderer` 自己做 z-up → y-up
  /// (world_to_renderer.dart 文件头,实测判死的换轴)。**不是** [lastPose]
  /// 那条 ARKit 口径 —— 那条已按 `xrslam_world_axis.dart` 换成 y-up 给
  /// dome / 落盘用。两条都 y-up,但差一个绕竖轴的偏航(VIO 里不可观);
  /// 画虚拟内容之前必须统一成一条,见 zero_arkit_camera_preview.dart 文件头。
  /// 本刀只画相机背景,位姿不影响背景像素。
  TrackedPose? get lastTrackedPose => _lastTracked;
  TrackedPose? _lastTracked;

  @override
  Stream<ARPose> start() {
    if (_timer != null) return _controller.stream;
    _stopped = false;
    if (!_clock.isRunning) _clock.start();
    // 🔴 相机 + 会话先起,再开始轮询。起不来**不抛** —— 位姿流照样交出
    //    `isTracking=false` 的帧,`CaptureSession` 的既有闸把它们挡在落盘外。
    //    抛了会把整个采集页打成 `_initError`,而这条臂本来就是研究臂。
    final ZeroArkitStartResult? r = _runtime?.start();
    if (r != null && !r.ok) {
      // ignore: avoid_print
      print('[zero-arkit] 运行时起不来:$r');
    }
    _timer = Timer.periodic(pollInterval, (_) => tick());
    return _controller.stream;
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
    _lastTracked = null;
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
  }) async {
    final int id = ++_photoRequestSeq;
    final int? accepted = _photoApi.capturePhoto(id);
    if (accepted == null) return null;

    final Stopwatch sw = Stopwatch()..start();
    while (sw.elapsed < timeout) {
      final ZeroArkitPhotoResult? r = _photoApi.photoResult();
      // 🔴 按 requestId 配对,**不按到达顺序** —— 上一张迟到的结果会被
      //    当成这一张,而且不会报任何错。
      if (r != null && r.requestId == accepted) return r;
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
    // 🔴 本臂的成片是原生自己选路径写的,**改不了落到调用方指定的两个路径**
    //    (那要动对方的接口)。所以这条老入口如实返回 false,让既有失败路径
    //    生效;新代码走 `saveCurrentFrame` / `requestPhoto`。
    return false;
  }

  @override
  Future<ARFrameSaveResult> saveCurrentFrame(ARFrameSaveSpec spec) async {
    final ZeroArkitPhotoResult? r = await requestPhoto();
    if (r == null) {
      return ARFrameSaveResult(
        spec: spec,
        status: 'unsupported',
        message: '成片接口不可用(pw_camera_slot_capture_photo 未链入)'
            '或超时未返回',
      );
    }
    // 🔴 状态不是 'saved':原生写的是**它自己选的路径**,不是 spec 里那两个。
    //    报 'saved' 会让 `CaptureSession` 去 spec.jpegPath 找一个不存在的文件。
    //    如实报一个非 saved 的状态 + 真实路径,由调用方决定怎么接。
    return ARFrameSaveResult(
      spec: spec,
      status: 'saved_elsewhere',
      message: '成片已写到 ${r.path}(零 ARKit 臂由原生相机槽选路径,'
          '不是 spec.jpegPath)',
    );
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
    //    ⇒ 如实 null。成片本身照样拍了(下面这行),只是走不通这条契约。
    await requestPhoto();
    return null;
  }
}
