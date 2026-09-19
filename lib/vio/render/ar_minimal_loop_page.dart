// ar_minimal_loop_page.dart — 最小可见回路的宿主页。
//
// 这一页**只为验证一件事**:相机帧能不能经由我们自己算的 UV 与投影,在
// Filament 里显示出来。它不接 VIO、不接锚点、不接采集 —— 那些是下一步。
//
// ══ 🔴 它会打开摄像头 ═══════════════════════════════════════════════════════
// 开的是 [PwCameraSlot] 自己那个最小 AVCaptureSession(640×480 / 32BGRA)。
//   * 要不要动手机:**不用**。静止摆着就能验证背景和方向。
//   * 写多少数据:**零**。深度 1 的槽只在内存里留最新一帧,不落盘。
//   * 时长:由使用者停留决定;离开本页即 [PwCameraSlot.stop]。
// 🔴 iOS 把后置相机只给一个会话 ⇒ 本页与 ARKit / 生产采集**不能同时跑**。
//
// ══ 怎么看结果 ═════════════════════════════════════════════════════════════
// 左上角那块计账条就是判据,不用猜:
//   frame=false  持续为假 ⇒ 相机没在交付(槽空)。
//   K=false      ⇒ 相机没自报内参。
//   proj=false   ⇒ 内参不可用或 near/far 非法,投影没设上。
//   pose=false   ⇒ 本页没接位姿源,**这是预期的**。
//   outstanding  ⇒ 未归还的缓冲数。**恒为 0 或 1;>1 就是漏**。
//   displaced    ⇒ 被新帧顶掉的帧数。**这是正常的**,深度 1 的代价,不是丢帧。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:thermion_flutter/thermion_flutter.dart' hide VoidCallback;

import 'dart:async';

import 'package:sensors_plus/sensors_plus.dart';

import '../ffi/xrslam_config.dart';
import '../ffi/xrslam_live_ffi.dart';
import '../ffi/xrslam_session.dart';
import '../pose/camera_projection.dart' show PinholeIntrinsics;
import '../pose/camera_slot_ffi.dart';
import '../pose/display_transform.dart';
import '../pose/engine_pose_poller.dart';
import '../pose/gravity_attitude.dart' show ImuSample;
import '../pose/native_imu_ffi.dart';
import '../pose/static_initializer.dart';
import '../pose/stationarity_gate.dart';
import '../pose/tracked_pose.dart';
import 'ar_render_loop.dart';

/// 采集尺寸 —— **显示口径**,不是 VIO 口径。
///
/// 🔴 这两个口径必须分开,之前我把它们混成了一个,导致背景糊:
///
/// * **VIO 的输入**是 640×480。出处硬:XRSLAM 上游 18 份 iPhone 标定
///   **18/18 全是 640×480**(含 iPhone 16e),上游 demo 默认也是
///   `.vga640x480`。而且实测**1920×1440 直接喂 VIO 会撞吞吐墙**
///   (只处理 10.5 fps / 相机供 24.4 / 丢 16.5% 帧)。
/// * **显示的背景**没有任何理由跟着降到 640×480。
///
/// 算一下就知道差多少:640×480 转 90° 后是 480×640,aspect-fill 进
/// 1179×2556 的视口只看得到 **295×640**,即 **3.99× 放大**;换成
/// 1920×1440 是 886×1920 → **1.33×**。**像素密度差 9 倍。**
///
/// ⇒ 正解是**双流**:相机出 1920×1440 给显示,降采样后喂 VIO。生产的影子
///   VIO 本来就在做 3× 降采样,不是新东西。本页还没接 VIO,所以先只改显示。
const int kFeedWidth = 1920;
const int kFeedHeight = 1440;

class ArMinimalLoopPage extends StatefulWidget {
  const ArMinimalLoopPage({super.key});

  @override
  State<ArMinimalLoopPage> createState() => _ArMinimalLoopPageState();
}

class _ArMinimalLoopPageState extends State<ArMinimalLoopPage> {
  ArRenderLoop? _loop;
  Future Function()? _frameHook;
  Size _viewport = Size.zero;
  double _dpr = 1.0;
  bool _cameraStarted = false;
  String _status = '等待渲染器…';
  ArFrameOutcome? _last;
  CameraSlotStats? _stats;
  bool _stepping = false;
  int _ticks = 0;
  bool _capturedOnce = false;

  // ══ 位姿链 ═══════════════════════════════════════════════════════════════
  // 引擎 → EnginePosePoller → StaticInitPoseChain → TrackedPose → 渲染器。
  // 🔴 在这之前 `EnginePoseSample` 全仓只有探针页构造过、且写死 ok:false ——
  //    也就是说这条链**从建成起没有一条真引擎位姿进去过**。这里补上。
  final EnginePosePoller _poller = EnginePosePoller();
  XrslamSessionStart? _session;
  bool _sessionAttempted = false;

  // ── 初始化延迟实测 ──────────────────────────────────────────────────────
  // 🔴 口径必须说死,否则又是一笔不能比的数:
  //   起点 = `XRSLAMCreate` 返回成功那一刻(不是 app 启动,也不是相机开)
  //   终点 = 引擎**第一次**报 XRSLAM_STATE_TRACKING_SUCCESS 那一刻
  // 与 ARKit 对比要拿同口径:ARSession.run → 第一次 trackingState == .normal。
  // ⚠️「ARKit 44 秒进 fair」是**跟踪质量等级**,不是这个量,不能当对照。
  /// 与台架 ARKit 参照同口径的起点:**相机启动之前**(= 台架的 runStart)。
  int? _runStartMicros;

  /// 会话建立成功的时刻。只用于把总延迟拆成两段看,**不作为对比口径**。
  int? _sessionReadyMicros;
  int? _firstTrackingMicros;
  bool _initLatencyReported = false;
  late final StaticInitPoseChain _chain = StaticInitPoseChain(
    initializer: StaticInitializer(
      gate: StationarityGate(
        // 整份抄 tum_vi —— 14 份已发布配置里唯一的**手持**场景。
        imuExcitationThreshold: kTumViHandheld.imuExcitationThreshold,
        disparityThresholdPixels: kTumViHandheld.maxDisparityPixels,
        windowSeconds: kTumViHandheld.windowSeconds,
        // 🔴 这里取 true,理由见 static_initializer.dart 文件头:
        //    我们交出的是给渲染器的 3DOF 兜底(走 VioPoseSource 的
        //    orientationOnly 档,**不回灌任何滤波器**),不是 EKF 状态初始化。
        //    ARKit 静止时也是这个行为。若日后要回灌 XRSLAM 状态,必须改回 false。
        zeroVelocityUpdateEnabled: true,
      ),
    ),
  );
  StreamSubscription<AccelerometerEvent>? _accSub;
  StreamSubscription<GyroscopeEvent>? _gyrSub;
  double _gx = 0, _gy = 0, _gz = 0;
  bool _gotGyro = false;
  final Stopwatch _imuClock = Stopwatch()..start();
  TrackedPose? _pose;
  StaticInitAttempt? _lastAttempt;

  @override
  void dispose() {
    _accSub?.cancel();
    _gyrSub?.cancel();
    _poller.dispose();
    NativeImu.stop();
    // 🔴 必须销毁:上游 Detail 是进程级单例,不销毁下一次 Create 是覆盖。
    XrslamSession.current?.destroy();
    final hook = _frameHook;
    if (hook != null) {
      FilamentApp.instance?.unregisterRequestFrameHook(hook);
      _frameHook = null;
    }
    // 🔴 先停相机再拆回路。反过来的话,最后一帧可能已经交给了 Filament 而
    // 纹理已被销毁。
    if (_cameraStarted) {
      PwCameraSlot.stop();
      _cameraStarted = false;
    }
    _loop?.dispose();
    super.dispose();
  }

  Future<void> _onViewer(ThermionViewer viewer) async {
    try {
      // 🔴 **不要**用 setBackgroundColor —— 在 thermion 0.3.4 里它会建一个
      // **天空盒**。而我们这个三角形按上游写法坐在**远平面**上
      // (`vertexDomain: device` + z=1,Filament 对 device 域做 z*-0.5+0.5,
      //  反向 Z 下落在远平面),天空盒也在远平面、且在不透明体之后画 ⇒
      // 它会盖掉我们的三角形。上游 hello-ar **没有天空盒**,这一行是我加的。
      //
      // 改用清屏色。颜色选品红,为的是三种失败长得不一样、一眼可分:
      //   品红 = 三角形根本没上屏(清屏色透出来)
      //   全黑 = 三角形画了,但采样到的是空纹理
      //   相机画面 = 成了
      await FilamentApp.instance!.setClearOptions(1.0, 0.0, 1.0, 1.0);
      // 🔴 **后处理必须开着** —— 2026-09-19 修正,原来这里是 `false`,
      // 注释写着"材质已经用 inverseTonemapSRGB 抵消过一次色调映射,不需要后处理"。
      // **那条推理是反的**,而且正是画面偏暗的根因:
      //
      //   `inverseTonemapSRGB` 的作用是**预先抵消 Filament 的色调映射**,
      //   而色调映射(ColorGrading/tonemapping)**本身就跑在后处理阶段**。
      //   关掉后处理 = 关掉"正向"那一半,只剩材质里的"反向"那一半:
      //   反向变换把显示值往 HDR 线性空间拉,本该由 tonemapper 压回来 ——
      //   没人压,中低调就整体偏暗。
      //
      //   上游 hello-ar(`FilamentApp.cpp`)**完全没有配置后处理**,
      //   即用 Filament 的默认值:**开启**。它的 inverseTonemapSRGB 是配着
      //   后处理一起工作的。我们关掉它,就是对复刻件的无记录偏离。
      //
      // ⚠️ 如果日后确实要省掉泛光/FXAA 的开销,应当**单独关那几项**,
      //    绝不能再关整个 post-processing 阶段 —— 那会连 tonemapping 一起误伤。
      await viewer.setPostProcessing(true);

      final ByteData bytes =
          await rootBundle.load('assets/materials/pw_camera_feed.filamat');
      final loop = await ArRenderLoop.create(
        viewer,
        materialBytes: bytes.buffer.asUint8List(),
        imageWidth: kFeedWidth,
        imageHeight: kFeedHeight,
      );

      // 🔴 B3 方向自检:建三个**钉在世界系固定点**的球(红 1 m / 绿 2 m /
      //    蓝 3 m,直径 20 cm,各带不同方向的横纵偏移)。
      //    没有它们,"位姿进了渲染器"就只是一句日志 —— 符号/轴映射错了
      //    所有指标照样全绿(见 ar_render_loop 里 createWorldMarker 的说明)。
      //    判据:正常拍房间,球应当像钉在空中 —— 手机动它在画面里的位置变,
      //    但它在房间里的位置不变。跟着手机走或反向飞 = 这条链错。
      //    三个深度是为了**转身时总有一个在画面里**;单个 0.8 m 的那版一动
      //    就出画,用户的原话是"后来就看不见红球了"。
      await loop.createWorldMarker(rotationDegrees: 90); // 与本页锁竖屏同口径

      // 🔴 会话**不在这里建** —— 见 _ensureSession:要等第一帧交付、拿到
      //    相机自报的真实内参之后才建,否则只能拿占位内参去建。

      // IMU:静止兜底那一半要它。100 Hz,与探针页同口径。
      _gyrSub = gyroscopeEventStream(
        samplingPeriod: const Duration(milliseconds: 10),
      ).listen((GyroscopeEvent e) {
        _gx = e.x;
        _gy = e.y;
        _gz = e.z;
        _gotGyro = true;
      });
      _accSub = accelerometerEventStream(
        samplingPeriod: const Duration(milliseconds: 10),
      ).listen((AccelerometerEvent e) {
        if (!_gotGyro) return;
        final ImuSample s = ImuSample(
          timestampSeconds: _imuClock.elapsedMicroseconds / 1e6,
          ax: e.x,
          ay: e.y,
          az: e.z,
          gx: _gx,
          gy: _gy,
          gz: _gz,
        );
        // 🔴 这条**只喂静止兜底**,不喂引擎。静止兜底只看相对时间,
        //    用 Stopwatch 无妨。
        //    引擎那一路在原生侧的 CoreMotion 回调里直推,不经过 Dart ——
        //    上一版在这里轮询 `NativeImu.latest()` 再配对推,是发散的根因。
        _chain.addImu(s);
      });

      // 🔴 初始化延迟的**起点**打在这里,不是打在会话建立处。
      // 理由:要与台架 ARKit 参照同口径。台架用的是
      // `runStartNanoseconds` = **整场 run 开始**,包含相机启动、第一帧交付、
      // 会话建立在内(BenchmarkCoordinator.swift:1691 firstPoseLatencyMilliseconds)。
      // 我们原来从「XRSLAMCreate 成功」起算,把上面那一整段排除在外了 ——
      // 而我们的会话恰恰是**等第一帧内参到了才建**,所以那个起点晚得多,
      // 拿去和 ARKit 比是**对我们有利的不公平比较**。
      _runStartMicros = _imuClock.elapsedMicroseconds;
      // 🔴 [2026-09-20] `NativeImu` 已从喂数通路上摘掉,这里也不再起它。
      //    理由:它的文件头自己就写着"**轮询会漏样本,不能当最终通路**",
      //    而我上一版恰恰把它当成了最终通路 —— 真机位姿 45 秒发散到 1.6 km。
      //    现在 IMU 由 `PwXrslamLive` 在 CoreMotion 回调里直推引擎(与上游
      //    `Motion.swift` → `XRSLAMer` → `XRSLAMPushSensorData` 同位),
      //    起停由 `XrslamSession.start/destroy` 管。再起一个 CMMotionManager
      //    只是白耗电。
      //
      // 🔴 相机**必须先起**:`pw_xrslam_live_begin` 要用相机那条串行队列
      //    (没登记就返回 -4)。这条顺序就是上游"两条流共用 .main"那条性质。
      final int rc = PwCameraSlot.start(width: kFeedWidth, height: kFeedHeight);
      if (rc != 0) {
        setState(() => _status = '相机启动失败,原生返回码 $rc');
        await loop.dispose();
        return;
      }
      _cameraStarted = true;

      // 🔴 **不要** `setRendering(false)`。
      //
      // 它的名字像是"关掉 viewer 自己的渲染循环",实际做的是
      //     _rendering = render;
      //     await view.setRenderable(render);   // ← 把 View 标成不可渲染
      // (thermion_viewer_ffi.dart:115-118)。View 一旦不可渲染,Filament
      // 渲染时整个跳过它:beginFrame 照跑、清屏色照画,而**场景里的东西
      // 一个都不画**。症状是屏幕永远停在清屏色,同时 FilamentApp.capture
      // 返回空列表 —— 而纹理/投影/UV 的计数全都正常,极具迷惑性。
      //
      // 本会话实测:就是这一行让最小回路一直显示清屏色。

      // 一次性诊断:三角形建出来没有、在不在场景里。
      // 「没显示」有很多种死法,这几行把前几种直接排掉。
      try {
        final e = loop.triangleEntity;
        debugPrint('[arloop] 材质字节 = ${bytes.lengthInBytes}');
        debugPrint('[arloop] 三角形 entity = $e');
        debugPrint('[arloop] isRenderable = '
            '${await FilamentApp.instance!.isRenderable(e)}');
        debugPrint('[arloop] primitiveCount = '
            '${await FilamentApp.instance!.getPrimitiveCount(e)}');
        debugPrint('[arloop] boundingBox = '
            '${await FilamentApp.instance!.getBoundingBox(e)}');
      } catch (e) {
        debugPrint('[arloop] 一次性诊断失败: $e');
      }

      if (!mounted) {
        PwCameraSlot.stop();
        _cameraStarted = false;
        await loop.dispose();
        return;
      }
      setState(() {
        _loop = loop;
        _status = '运行中';
      });

      // 🔴 挂成 viewer 的 per-frame hook,而不是自己起 Ticker。
      //
      // 对照件 `FilamentApp.cpp:52-70` 的结构是:**唯一一个渲染循环**,每帧
      // 依次「喂纹理 → 喂 UV → 设位姿 → 设投影 → beginFrame/render/endFrame」。
      // ViewerWidget 自带渲染循环,我们再起一个 Ticker 自己 render,就成了同
      // 一个 Renderer 上两对 beginFrame/endFrame 并发 —— 真机实测直接
      // SIGABRT(`Precondition in endFrame:410 / SwapChain must remain valid
      // until endFrame is called.`)。
      //
      // `FilamentApp.requestFrame()` 先**按序 await 所有 hook**、再请求渲染
      // (ffi_filament_app.dart:656-667),所以挂 hook 得到的正是上游那个
      // 「推完状态紧接着出图」的顺序,而循环仍然只有一个。
      final hook = _onFrame;
      _frameHook = hook;
      await FilamentApp.instance!.registerRequestFrameHook(hook);
    } catch (e, st) {
      setState(() => _status = '建回路失败:$e\n$st');
    }
  }

  /// 每帧渲染**之前**跑。由 FilamentApp.requestFrame 按序 await。
  Future<void> _onFrame() async {
    final loop = _loop;
    if (loop == null || !mounted) return;
    // requestFrame 是顺序 await 的,不会重入;这道闸只防万一。
    if (_stepping) return;
    _stepping = true;
    try {
      final Size size = _viewport;
      final double dpr = _dpr;
      if (size.width <= 0 || size.height <= 0) return;
      _ensureSession();

      // ── 位姿:每帧向引擎拉一次,拉不到就走静止兜底 ──────────────────────
      // 🔴 拉取而非回调:dart:ffi 同步同线程,NativeCallable.isolateLocal 从
      //    非创建线程调用会**硬 abort**。理由见 engine_pose_poller.dart。
      final double nowSeconds = _imuClock.elapsedMicroseconds / 1e6;
      final TrackedPose pose = _chain.update(
        sample: _poller.poll(nowSeconds: nowSeconds),
        nowSeconds: nowSeconds,
      );
      _pose = pose;
      _lastAttempt = _chain.lastAttempt;
      _markFirstTracking();

      final outcome = await loop.step(
        viewportWidth: (size.width * dpr).round(),
        viewportHeight: (size.height * dpr).round(),
        pose: pose,
        // 🔴 [2026-09-20] 这里不再喂引擎。
        //    上游是在**相机回调内部**一次 lock、同一个 baseAddress 同时派生
        //    SLAM 灰度与显示图(`XRSLAM_iOS.mm:130-167`)。我们现在也是:
        //    `PwCameraSlot.captureOutput` 里当场调
        //    `PwXrslamLive.onCameraFrame`,渲染侧照旧从槽里取。
        //    这样引擎吃到的是**每一帧、按采集顺序**,不再是"渲染循环想起来
        //    才取一次"。
        // 本页锁竖屏。接生产时这里要读真实的屏幕旋转
        // (iOS: UIInterfaceOrientation;安卓/鸿蒙: ScreenRotation.fromIndex)。
        displayRotation: ScreenRotation.degrees0,
      );
      final stats = PwCameraSlot.stats();
      // 每约 60 帧打一次。屏幕上那块字太小,控制台才读得到。
      if (++_ticks % 60 == 0) {
        debugPrint('[arloop] ${outcome.toDiagnosticString()}');
        // 🔴 这一行是判断「引擎位姿到底有没有进来」的唯一现场证据:
        //    stage=tracking ⇒ 引擎给了 6DOF;orientationOnly ⇒ 走静止兜底;
        //    none ⇒ 两头都没有。rc 是 XRSLAMTryGetLatestPose 的返回码。
        debugPrint('[arloop] pose stage=${_chain.source.stage.name} '
            'state=${_poller.lastState} '
            'hasPos=${_pose?.position != null} '
            'hasOri=${_pose?.orientation != null}'
            '${_lastAttempt == null ? '' : ' init=${_lastAttempt!.verdict.decision.name}'}'
            ' sess=${_session?.ok} rc=${_session?.createRc}');
        debugPrint('[arloop] $stats');
        // 🔴 吞吐瓶颈定位:引擎 RunOneFrame 的**整体**耗时。
        //    对照:60fps 的帧间隔是 16.67ms,30fps 是 33.3ms。
        //    若 p50 已经接近或超过帧间隔 ⇒ 瓶颈就在引擎,丢帧是必然结果;
        //    若 p50 远小于帧间隔 ⇒ 瓶颈在别处(渲染/取帧/主线程)。
        // 🔴 渲染回路分段 p50:喂纹理/内参/UV/投影/位姿/出图。
        //    引擎侧已实测不是瓶颈(Push 1.9ms、Run 0.0ms vs 帧间隔 16.7ms),
        //    所以开销必在这六段里 —— 逐段量,不猜。
        // 🔴 取证行:球在相机系的坐标。前方 ⇒ z<0,距离 = −z。
        //    对照初值 红(0.20,0.15,−1.00)/绿(−0.30,−0.10,−2.00)/
        //    蓝(0.05,0.35,−3.00) —— 手机放回原处时应回到这附近。
        final String? md = loop.markerDiagnostic();
        if (md != null) debugPrint('[arloop] 锚点 $md');
        final List<double>? stg = loop.stageP50Millis();
        if (stg != null) {
          final double sum = stg.reduce((a, b) => a + b);
          debugPrint('[arloop] step 分段 p50(ms) 纹理=${stg[0].toStringAsFixed(1)} '
              '内参=${stg[1].toStringAsFixed(1)} UV=${stg[2].toStringAsFixed(1)} '
              '投影=${stg[3].toStringAsFixed(1)} 位姿=${stg[4].toStringAsFixed(1)} '
              '出图=${stg[5].toStringAsFixed(1)} | 合计=${sum.toStringAsFixed(1)} '
              '(帧间隔 16.7)');
        }
        // 🔴 喂料账本 —— 全部来自 C++ 侧的同一本账,Dart/Swift 都不合成。
        //    判读:`拒:非单调` 相机那一路非 0 ⇒ PTS 没严格递增;
        //    IMU 两路非 0 ⇒ 同一条样本被推了两遍(上一版的原病,现在应当恒 0)。
        //    `acc`/`gyr` 的增速应当各约 100/s;`cam` 与 `cam回调` 应当相等。
        final XrslamLiveStats? ls = XrslamLive.stats();
        if (ls != null) debugPrint('[arloop] 喂料 $ls');
        // 🔴 相机与 IMU 的时间轴是不是同一条 —— 删掉时钟映射时靠的是文档论证,
        //    这一行是把它变成实测。同域 ⇒ delta 是几十毫秒;跨域 ⇒ 是开机时长。
        final t = XrslamLive.timing();
        if (t != null) {
          debugPrint('[arloop] 时钟 camPTS=${t.cameraPts.toStringAsFixed(3)}s '
              'imuTS=${t.imuTs.toStringAsFixed(3)}s '
              'delta=${(t.delta * 1000).toStringAsFixed(1)}ms '
              '|delta|峰值=${(t.maxAbsDelta * 1000).toStringAsFixed(1)}ms');
        }
        // [pw 2026-09-19] 曝光实测 —— 回答"为什么比系统相机暗"。只读,不改设置。
        final CameraExposure? e = PwCameraSlot.exposure();
        if (e != null) debugPrint('[arloop] ${e.toDiagnosticString()}');
        debugPrint('[arloop] viewport = '
            '${(size.width * dpr).round()}x${(size.height * dpr).round()}');
      }
      // 一次性取像:把"屏幕上到底是什么颜色"变成机器判据,不用人去看。
      // 三态可分:近品红 = 三角形没上屏;近黑 = 上屏了但纹理是空的;
      // 方差大 = 真的是相机画面。
      if (!_capturedOnce && _ticks > 90) {
        _capturedOnce = true;
        await _dumpFramebuffer();
      }

      if (mounted) {
        setState(() {
          _last = outcome;
          _stats = stats;
        });
      }
    } finally {
      _stepping = false;
    }
  }

  /// 建会话 —— **等到相机交出真实内参之后**才建,且只建一次。
  ///
  /// ══ 跨端分工照 `xrslam_config.dart` 文件头定的那套,不是新设计 ══
  ///   · Dart 生成两份 YAML、写会话私有临时文件、传**路径**、标 provenance;
  ///   · 原生侧(Swift/Kotlin/ArkTS)**只把路径搬到五函数 C ABI,
  ///     "不解析也不判参数"**(原话);
  ///   · 内参各端从自己的系统 API 读,填进同一个 [CameraIntrinsics]。
  /// ⇒ [XrslamSession.start] 的签名本身就是跨端接口;平台差异只剩
  ///   "这四个数从哪读"。
  /// ⚠️ 上游那套**逐机型 yaml** 明确不抄 —— 同一份文件头记着:那 18 个 iPhone
  ///   配置里 16e 与 14 Pro 的 intrinsics/p_bc **逐字节相同**,是占位拷贝;
  ///   我们的硬需求是"一套管线服务所有手机,绝不逐机型实测"。
  ///
  /// 🔴 为什么不能在启动时建:`PwCameraSlot.intrinsics` 在第一帧交付之前返回
  /// `null`,那时只能拿占位值(fx=1000 @1280×720)去建会话,而实际帧是
  /// 1920×1440 —— 内参错了,三角化和重投影全跟着错,精度直接废掉。
  ///
  /// ⚠️ **已知局限,不假装解决了**:`XRSLAMCreate` 只吃一次内参,而相机自动对焦
  /// 全程在动(该文件的文档实测单场 120 s 内 fx 漂 **10.90%**)。出货引擎导出的
  /// 五个符号里**没有**任何"更新内参"的入口,所以这里只能取**建会话那一刻**的
  /// 快照。这与台架既有的"冻第 0 帧焦距"是同一个已知缺陷,不是本次引入的。
  void _ensureSession() {
    if (_sessionAttempted || XrslamSession.current != null) return;
    final PinholeIntrinsics? k = PwCameraSlot.intrinsics(
      imageWidth: kFeedWidth,
      imageHeight: kFeedHeight,
    );
    if (k == null) return; // 还没有交付过帧,下一帧再试
    _sessionAttempted = true;
    _session = XrslamSession.start(
      intrinsics: CameraIntrinsics(
        fx: k.fx,
        fy: k.fy,
        cx: k.cx,
        cy: k.cy,
        resolutionWidth: k.imageWidth,
        resolutionHeight: k.imageHeight,
        // 🔴 用仓里**已有**的取值:背后是 AVCameraCalibrationData ⇒ deviceApi。
        //    (我第一版写了个自造的 `deviceReported`,仓里没有这个值。)
        provenance: FieldProvenance.deviceApi,
      ),
    );
    debugPrint('[arloop] XRSLAMCreate rc=${_session!.createRc} '
        'ok=${_session!.ok} '
        'fx=${k.fx.toStringAsFixed(2)} fy=${k.fy.toStringAsFixed(2)} '
        'cx=${k.cx.toStringAsFixed(2)} cy=${k.cy.toStringAsFixed(2)} '
        '${k.imageWidth}x${k.imageHeight}'
        '${_session!.error == null ? '' : ' err=${_session!.error}'}');
    // 初始化延迟的**起点**:会话建立成功那一刻。失败就不计时。
    if (_session!.ok) _sessionReadyMicros = _imuClock.elapsedMicroseconds;
    // 🔴 GPU 前端到底有没有真的起来 —— Dawn 失败会**静默回落 CPU**。
    //    必须在**会话建好之后**读:痕迹是 `XRSLAMCreate` 期间写的。
    //    不看这个,就会把"没提速"误判成"GPU 前端没用"。
    final String trail = XrslamLive.gpuFrontEndTrail();
    debugPrint('[arloop] GPU前端 '
        '${trail.isEmpty ? "(无痕迹 ⇒ 没链 GPU 前端那条臂)" : trail.trim().split("\n").last}');
  }

  /// 初始化延迟的**终点**:引擎第一次报 TRACKING_SUCCESS。只打一次。
  ///
  /// 🔴 这个数要跟 ARKit 比,必须同口径:ARSession.run → 第一次
  /// `trackingState == .normal`。**别拿「进 fair」的秒数来比** —— 那是
  /// 跟踪质量等级,不是首次出位姿的时刻,两者量的不是同一件事。
  ///
  /// ⚠️ 还有一个绕不开的前提:单目 VIO **静止时初始化不了**
  /// (VINS-Mono 原文:"cannot start from a stationary condition")。
  /// 所以这个延迟里包含**用户开始移动之前的等待**,跨设备比必须同样的运动剧本。
  void _markFirstTracking() {
    if (_initLatencyReported) return;
    if (_runStartMicros == null) return;
    if (_poller.lastState != 1) return; // XRSLAM_STATE_TRACKING_SUCCESS
    _firstTrackingMicros = _imuClock.elapsedMicroseconds;
    _initLatencyReported = true;
    // 🔴 **可比口径**:runStart(相机启动前)→ 首次 TRACKING_SUCCESS。
    final double total = (_firstTrackingMicros! - _runStartMicros!) / 1e6;
    // 拆段只为诊断,不用于对比。
    final String breakdown = _sessionReadyMicros == null
        ? ''
        : ' [相机+建会话 ${((_sessionReadyMicros! - _runStartMicros!) / 1e6).toStringAsFixed(3)}s'
            ' + 引擎初始化 ${((_firstTrackingMicros! - _sessionReadyMicros!) / 1e6).toStringAsFixed(3)}s]';
    debugPrint('[arloop] INIT_LATENCY runStart→首次TRACKING = '
        '${total.toStringAsFixed(3)} s$breakdown');
  }

  /// 取一帧渲染结果,统计像素。判据见调用处。
  Future<void> _dumpFramebuffer() async {
    try {
      final shots = await FilamentApp.instance!.capture(null);
      if (shots.isEmpty) {
        debugPrint('[arloop] capture 返回空');
        return;
      }
      final (_, Uint8List bytes) = shots.first;
      final Float32List px = bytes.buffer.asFloat32List();
      final int n = px.length ~/ 4;
      debugPrint('[arloop] capture: ${bytes.lengthInBytes} 字节 = $n 像素');
      if (n == 0) return;

      // 均值 / 极值 / 方差 —— 均匀色的方差≈0,相机画面不可能。
      double sr = 0, sg = 0, sb = 0, s2 = 0;
      double lo = 1e9, hi = -1e9;
      for (int i = 0; i < n; i++) {
        final double r = px[i * 4], g = px[i * 4 + 1], b = px[i * 4 + 2];
        sr += r; sg += g; sb += b;
        final double l = (r + g + b) / 3.0;
        s2 += l * l;
        if (l < lo) lo = l;
        if (l > hi) hi = l;
      }
      final double mr = sr / n, mg = sg / n, mb = sb / n;
      final double ml = (mr + mg + mb) / 3.0;
      final double varL = (s2 / n) - ml * ml;
      debugPrint('[arloop] 均值 RGB = '
          '(${mr.toStringAsFixed(3)}, ${mg.toStringAsFixed(3)}, '
          '${mb.toStringAsFixed(3)})');
      debugPrint('[arloop] 亮度 min=${lo.toStringAsFixed(3)} '
          'max=${hi.toStringAsFixed(3)} 方差=${varL.toStringAsFixed(5)}');
      String verdict;
      if (varL < 1e-6 && mr > 0.5 && mg < 0.2 && mb > 0.5) {
        verdict = '🔴 近品红且均匀 ⇒ 三角形没上屏(清屏色透出来)';
      } else if (varL < 1e-6 && ml < 0.05) {
        verdict = '🔴 近黑且均匀 ⇒ 三角形上屏了,但采样到空纹理';
      } else if (varL > 1e-4) {
        verdict = '✅ 方差大 ⇒ 屏上有真实图像内容';
      } else {
        verdict = '❓ 均匀但不是品红也不是黑';
      }
      debugPrint('[arloop] 判据: $verdict');
    } catch (e, st) {
      debugPrint('[arloop] capture 失败: $e\n$st');
    }
  }

  @override
  Widget build(BuildContext context) {
    // hook 在渲染线程节奏上跑,拿不到 BuildContext,所以在这里存一份。
    _viewport = MediaQuery.of(context).size;
    _dpr = MediaQuery.of(context).devicePixelRatio;
    // 🔴 B3 判读闸:引擎初始化完成前位姿是 null,相机矩阵**从没被设过**
    //    ⇒ 球必然固定在屏幕同一处、"跟着手机走"。那是正常的,不是缺陷。
    //    把这个窗口画在屏上,人才知道**什么时候可以开始判方向**。
    final bool tracking =
        _poller.lastState == 1 && _pose?.position != null;
    return Scaffold(
      backgroundColor: const Color(0xFF001018),
      body: Stack(
        children: <Widget>[
          Positioned.fill(
            child: ViewerWidget(
              initial: const ColoredBox(color: Color(0xFF001018)),
              // 🔴 **不传 background**。
              //
              // ViewerWidget 拿这个参数去调 viewer.setBackgroundColor
              // (viewer_widget.dart:184-186),而它在 0.3.4 里**建的是天空盒**。
              // 天空盒和这个全屏三角形都坐在**远平面**上,且天空盒在不透明体
              // 之后画 ⇒ 把三角形整个盖掉。
              //
              // 对照件 FilamentApp.cpp 的 setupFilament/setupView **没有建
              // 任何天空盒**,清屏色由 Renderer 给。照它来。
              manipulatorType: ManipulatorType.NONE,
              transformToUnitCube: false,
              postProcessing: false,
              destroyEngineOnUnload: true,
              onViewerAvailable: _onViewer,
            ),
          ),
          Positioned(
            left: 12,
            top: MediaQuery.of(context).padding.top + 12,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: DefaultTextStyle(
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontFamily: 'Menlo',
                    height: 1.4,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Container(
                            width: 10,
                            height: 10,
                            margin: const EdgeInsets.only(right: 6),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: tracking
                                  ? Colors.greenAccent
                                  : Colors.orangeAccent,
                            ),
                          ),
                          Text(
                            tracking
                                ? 'TRACKING — 可以开始判方向了'
                                : '初始化中 — 球贴在屏上不动是正常的',
                            style: TextStyle(
                              color: tracking
                                  ? Colors.greenAccent
                                  : Colors.orangeAccent,
                            ),
                          ),
                        ],
                      ),
                      Text(_status),
                      if (_last != null) Text('$_last'),
                      if (_stats != null) Text('$_stats'),
                      if (_stats != null && _stats!.outstanding > 1)
                        const Text('🔴 缓冲泄漏:outstanding > 1',
                            style: TextStyle(color: Colors.redAccent)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
