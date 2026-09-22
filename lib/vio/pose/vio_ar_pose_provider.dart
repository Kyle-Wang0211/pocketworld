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
// ══ 🔴 它**不**做的四件事(照抄下游契约,不自研)═══════════════════════════
// 1. **不换轴。** `vio_pose_source.dart` 文件头写死了这条:世界系约定我们有
//    **两个互相矛盾**的记录(实测 SE(3) 拟合 `x_A=−y_X, y_A=+z_X, z_A=−x_X`
//    vs 上游 SceneKit 硬编码 `(x,y,z)→(−y,−x,−z)`),在从我们自己的 build 打
//    一个真实位姿判死之前,任何换轴都是猜。所以本文件交出的位姿在
//    **引擎自己的世界系**里,并且**不假装**它是 ARKit 的系
//    (ARKit y 向上、XRSLAM z 向上,两者差一个带符号置换)。
//    ⇒ 这就是为什么 `poseSource` 标签必须是 `'xrslam'` 而不是 `'arkit'`:
//      下游看到这个标签才知道这份外参不是 ARKit 口径。
// 2. **不做显示时刻预测。** 引擎的位姿补到**图像时刻**,不是显示时刻。
//    补显示延迟要 Monado 的 `m_predict_relation`,那是另一刀。
// 3. **不做杠杆臂换算。** `EnginePosePoller` 取的是 **CAMERA_POSE**(与上游
//    一致),不是 body pose;body↔camera 差 33.75mm 的 `p_bc`,换算属于比对层。
// 4. **不碰相机。** 本文件一帧都不采 —— 喂料由 `PwCameraSlot` → `PwXrslamLive`
//    在原生侧完成。见下面「已知缺口」。
//
// ══ 🔴 已知缺口:开关 ON 时真机上拿不到 6DOF ═══════════════════════════════
// `PwCameraSlot` 自己建 `AVCaptureSession`;而 ARKit 在会话运行期间**独占**
// 后置相机(`ar_capture_page.dart:737-747` 的注释是实证:并行开相机会
// `FigCaptureSourceRemote err=-17281`)。生产采集页今天由 ARKit 开着相机,
// 所以本适配器在真机上会一直拿到 `TRACKING_SUCCESS` 之前的状态 ——
// **契约通了,喂料没通。** 这不是本文件能修的:要么采集页改成不开 ARKit,
// 要么原生侧把 `ARFrame.capturedImage` 转喂给 `PwXrslamLive`。两条都没做,
// 也**不该**在「默认关闭的开关」这一刀里做。
// ⇒ 降级是**优雅**的:拿不到位姿时交出 `isTracking=false` 的 ARPose,
//   `tier=none`,`CaptureSession` 的既有闸照常把它挡在落盘之外。

import 'dart:async';
import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../../official_dome/ar_pose.dart';
import '../ffi/xrslam_session.dart';
import '../quality/initialization_window.dart';
import '../quality/pose_confidence.dart';
import 'camera_projection.dart';
import 'camera_slot_ffi.dart';
import 'engine_pose_poller.dart';
import 'tracked_pose.dart';
import 'vio_pose_source.dart';
import 'vio_pose_source_switch.dart';

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
    this.pollInterval = const Duration(milliseconds: 16),
    this.feedWidth = 640,
    this.feedHeight = 480,
  }) : _poller = poller ?? EnginePosePoller(),
       _source = poseSource ?? VioPoseSource(),
       _intrinsicsReader = intrinsicsReader;

  final EnginePosePoller _poller;
  final VioPoseSource _source;
  final VioIntrinsicsReader? _intrinsicsReader;

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

  @override
  Stream<ARPose> start() {
    if (_timer != null) return _controller.stream;
    _stopped = false;
    if (!_clock.isRunning) _clock.start();
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

    final Quaternion orientation = q == null
        ? Quaternion.identity()
        : Quaternion(q.x, q.y, q.z, q.w);
    final Vector3 position = p == null
        ? Vector3.zero()
        : Vector3(p.x, p.y, p.z);

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
      extrinsic4x4: (q != null && p != null)
          ? _cameraToWorldColumnMajor(orientation, position)
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

  /// 把 XRSLAM 的档位翻成 `ARPose.trackingStateName` 的既有词表。
  /// 🔴 词表是 `ar_pose.dart:76-88` 定死的那七个字符串,**不新增取值** ——
  /// `PoseDriftTracker` 按字符串聚合,多一个词它就归不了类。
  String _trackingStateName(TrackedPose tracked) {
    if (tracked.isSixDegreeOfFreedom) return 'normal';
    if (_source.stage == VioPoseStage.lastKnown) return 'limited_relocalizing';
    if (tracked.orientationValid) return 'limited_initializing';
    return XrslamSession.current == null
        ? 'not_available'
        : 'limited_initializing';
  }

  static List<double> _cameraToWorldColumnMajor(Quaternion q, Vector3 t) {
    final Matrix4 m = Matrix4.compose(t, q, Vector3(1, 1, 1));
    return List<double>.generate(16, (i) => m.storage[i], growable: false);
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
  }

  Future<void> dispose() async {
    await stop();
    _poller.dispose();
    _source.reset();
    await _controller.close();
    await _confCtrl.close();
  }

  // ── 🔴 照片路径:**本臂没有**,如实返回 unsupported ────────────────────
  // 生产的成片来自 `ARFrame.capturedImage`(native 的 `saveCurrentFrame` /
  // `captureHighResolutionStill`)。XRSLAM 臂只有位姿,没有任何取帧出口 ——
  // 出货引擎导出的 5 个符号里一个都不是取图像的。
  // 假装成功会让 `CaptureSession` 以为落盘了而实际没有;所以这里返回
  // `unsupported`,让既有的失败路径原样生效。

  @override
  Future<bool> saveCurrentFrameAsJpeg({
    required String jpegPath,
    required String metadataPath,
    double? targetTimestamp,
    double maxTimestampDelta = 0.18,
    double quality = 0.9,
  }) async => false;

  @override
  Future<ARFrameSaveResult> saveCurrentFrame(ARFrameSaveSpec spec) async =>
      ARFrameSaveResult(
        spec: spec,
        status: 'unsupported',
        message: 'XRSLAM 臂只产位姿,没有帧保存出口(出货引擎 5 个符号里没有取图)',
      );

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
  }) async => null;
}
