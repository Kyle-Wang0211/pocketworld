// zero_arkit_capture_runtime.dart —— 开关 ON 时**代替 ARKit** 的那条运行时。
//
// ══ 一句话 ═════════════════════════════════════════════════════════════════
// 相机归 `PwCameraSlot`(经 `pw_zero_arkit_camera_start` 的租约闸),位姿归
// `PwXrslamLive` / `XrslamSession`,内参与曝光从我们自己的相机流拿。
// **整条路上一次 `ARSession` 都不起。**
//
// ══ 抄的是台架那条已验过的序,不是新发明 ═══════════════════════════════════
// `lib/vio/render/ar_minimal_loop_page.dart` 的起法逐条对应:
//     ① `PwCameraSlot.start(width: 1920, height: 1440)`   ← 相机先起
//     ② 等第一帧的**真实内参**(相机不报内参就不建会话)
//     ③ `XrslamSession.start(intrinsics:…, cameraTimeOffsetSeconds:…)`
//     ④ 之后每帧 `XrslamLive.latest()`(由 `EnginePosePoller` 做)
// 🔴 顺序不能换:`XrslamSession.start` 内部起 IMU 时要用相机那条串行队列
//   (没登记返回 −4,见 `xrslam_session.dart` 的 ③)。
//
// ══ 🔴 [pw 2026-09-22 时序] ② 是**等**出来的,不是读一次 ═══════════════════
// `pw_camera_slot_intrinsics` 要等**第一帧交付**才非 null(Swift 侧返回 −1),
// 而相机刚起时第一帧还没来 ⇒ 以前 [start] 是同步的、起完相机**立刻**读内参
// ⇒ 真机上必踩「相机还没自报内参」然后把相机又关掉(台架探针 09-22 核实)。
// 台架页 `zero_arkit_capture_probe_page.dart` 绕开了它(先起相机、自己轮询
// ≤ 5 s 再调 provider.start());生产 `CaptureSession.attach()` →
// `VioArPoseProvider.start()` → 本类没人替它等。
// ⇒ 现在**等内参是运行时自己的事**:[start] 变成异步,起相机后按
//   [intrinsicsPoll] 间隔有界轮询到 [intrinsicsTimeout](数值抄台架页的
//   `kZeroArkitProbeIntrinsicsTimeout` / `kZeroArkitProbeIntrinsicsPoll`;
//   口径抄 `ar_minimal_loop_page.dart` `_ensureSession`「还没有交付过帧,
//   下一帧再试」),拿到再建会话;超时才失败关闭(停相机、error 写清等了多久)。
//   等了多久如实进 [ZeroArkitStartResult.intrinsicsWaitMs]。
// 🔴 没有同步版 —— 留一个同步 `start()` 就等于留一个「第一帧没到就必失败」
//   的入口给下一个人误用。
//
// ══ 🔴 [pw 2026-09-22 改口] 喂料尺寸 = 采集尺寸,默认**不降采样** ═══════════
// 以前默认喂 640×480、采 1920×1440,理由是「上游 18 份 iPhone 标定 18/18 都是
// 640×480、1920×1440 直喂撞吞吐墙(10.5 fps / 丢 16.5%)」。那条吞吐墙是
// **generic 引擎臂**的;gpufenothread 臂 1920×1440 实测 30 fps 留 94%(09-20)。
// **分辨率不降,引擎臂换** —— 用户铁律「最低 1920×1440」。
// 而且原生喂帧那条(`PwXrslamLive.swift` 文件头「我们喂 1920×1440」)本来就是
// 整帧推给引擎的;Dart 这边把内参缩到 640×480 再交会话 = 内参与像素**不同尺寸**,
// 引擎不报错、只会安静地算错。
// ⇒ 默认 [feedWidth]/[feedHeight] **等于** [captureWidth]/[captureHeight],
//   [scaleIntrinsicsForFeed] 在等尺寸时是恒等(有单测);要降只能**显式传参**,
//   回执 [ZeroArkitStartResult.feedDownscaled] 如实标出来。降采样**不能是默认**。
//   🔴 换算这一步 09-22 的安卓喂料链里漏过一次(fx 写成 0),所以仍是
//     一个独立函数 + 单测,而不是内联一行。
//
// ══ [pw 2026-09-22] 每机常量 c 接进来了 ═══════════════════════════════════
// 在此之前 `cameraTimeOffsetSeconds` 默认 0,而采集页构造时不传参 ⇒
// **生产 ON 臂的 c 恒 0**,09-22 在 iPhone 14 Pro 上扫出来的 +3 ms 只活在
// 台架页的 `--dart-define` 里。现在默认值改成**查表**
// (`camera_time_offset.dart`:`hw.machine` → c + provenance)。
// 🔴 c **不是**曝光/2 —— 曝光那一半是逐帧的,在原生
// (`PwCameraSlot.swift` → `PwXrslamLive.swift` 偏离 (d))里加;
// c 只是剩下的常量部分(卷帘读出/2 + 管线固定延迟),建会话时传一次。
// 🔴 未知机型给 **0** 不给 3 —— 未测就是未测,理由写在 camera_time_offset.dart 头上。
// 🔴 **已知窗口**:`deviceMachine()` 是异步 MethodChannel,而本类的 [start]
//   在**被调用那一刻**(第一个 await 之前)就把 c 定下来 ⇒ 进程内第一次建
//   会话时查表可能还没回来,那一次会如实打 `provenance=PLACEHOLDER(机型未知)`。
//   缺口与两条出路同样写在那个文件头上(采集页现已在起采集前
//   `await PwDeviceMachine.prime()`,走的是出路 (b))。
//
// ══ 🔴 不做的事 ════════════════════════════════════════════════════════════
// * **不采帧、不喂帧。** 喂料(camera→引擎)在原生侧的传感器回调里完成
//   (`PwXrslamLive.swift` + `vendor/xrslam/transport/`)。Dart 侧自己喂
//   在 09-20 实测**真机位姿 45 秒发散到 1.6 km**,那条路已判死。
// * **不渲染。** 预览用什么画由渲染那条分支决定,不在这里。
// * **不拍照。** 走 `ZeroArkitPhotoApi`(另一位 agent 实现)。

import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show debugPrint;

import '../ffi/xrslam_config.dart' show CameraIntrinsics, FieldProvenance;
import '../ffi/xrslam_session.dart';
import '../pose/camera_projection.dart' show PinholeIntrinsics;
import '../pose/camera_slot_ffi.dart' show CameraExposure, PwCameraSlot;
import '../pose/zero_arkit_camera_gate.dart';
import 'camera_time_offset.dart';

/// 等第一帧内参的上限与轮询间隔。**数值抄台架页**
/// (`zero_arkit_capture_probe_page.dart` 的 `kZeroArkitProbeIntrinsicsTimeout`
/// / `kZeroArkitProbeIntrinsicsPoll`:相机起后第一帧通常 100–500 ms 到),
/// 不是调出来的。
const Duration kZeroArkitIntrinsicsTimeout = Duration(seconds: 5);
const Duration kZeroArkitIntrinsicsPoll = Duration(milliseconds: 50);

/// 启动结果。失败时 [error] 一定非空 —— 不返回一个「看起来起来了」的实例。
class ZeroArkitStartResult {
  const ZeroArkitStartResult({
    required this.cameraRc,
    required this.sessionStarted,
    required this.intrinsics,
    required this.cameraTimeOffset,
    required this.error,
    this.intrinsicsWaitMs = 0,
    this.feedDownscaled = false,
  });

  /// `pw_zero_arkit_camera_start` 的返回码。**−100 = 相机被 ARKit 占着**,
  /// 那是「开关 ON 但 ARKit 还在跑」的确凿证据,不是相机坏了。
  final int? cameraRc;

  final bool sessionStarted;

  /// 真正交给引擎的那组内参(已按喂料尺寸换算)。
  final CameraIntrinsics? intrinsics;

  /// 真正交给引擎的每机常量 c(值 + 来源 + 人话说明)。
  ///
  /// 🔴 下游/报告要能读到**来源**,而不只是一个数:
  /// `measured` 才是这台机实测的,`PLACEHOLDER` 是「没测过 ⇒ 0」,
  /// `dev-override` 是命令行传进来的研发值。
  final CameraTimeOffset cameraTimeOffset;

  /// c 的秒值。等价于 `cameraTimeOffset.seconds`,给只要数的调用方。
  double get cameraTimeOffsetSeconds => cameraTimeOffset.seconds;

  /// 相机起来之后**等第一帧内参等了多久**(毫秒)。与台架页 manifest 里的
  /// `intrinsics_wait_ms` 同口径。相机都没起来(没等过)= 0;
  /// 超时失败时 ≈ [ZeroArkitCaptureRuntime.intrinsicsTimeout]。
  final int intrinsicsWaitMs;

  /// 交给引擎的内参是不是**比采集尺寸小**(显式传了 `feedWidth/feedHeight`
  /// 降采样)。默认构造的运行时恒 false(见文件头「改口」段:降采样不能是默认)。
  /// 读报告的人要能分辨「这场是全分辨率」还是「有人显式降了」。
  final bool feedDownscaled;

  final String? error;

  bool get ok => error == null;

  /// 失败原因是不是「ARKit 还占着相机」。调用方据此给出可操作的提示,
  /// 而不是笼统的「相机起不来」。
  bool get blockedByArkit => cameraRc == kZeroArkitCameraBusy;

  @override
  String toString() => 'ZeroArkitStartResult(cameraRc=$cameraRc '
      'session=$sessionStarted K=${intrinsics == null ? 'null' : 'ok'} '
      'feed=${intrinsics == null ? '?' : '${intrinsics!.resolutionWidth}x${intrinsics!.resolutionHeight}'}'
      '${feedDownscaled ? '(显式降采样)' : '(=采集)'} '
      'intrinsicsWait=${intrinsicsWaitMs}ms '
      '${cameraTimeOffset.describe} '
      'err=$error)';
}

/// 相机/会话这两件事的可注入面。单测用替身证明「ARSession 没起、
/// PwCameraSlot.start 起了」。
abstract interface class ZeroArkitPlatform {
  /// 起相机。返回码语义见 [ZeroArkitStartResult.cameraRc]。
  int startCamera({
    required int width,
    required int height,
    required double fps,
    required double lensPosition,
  });

  void stopCamera();

  /// 相机是否确实在自研臂名下(运行期自证)。
  bool cameraOwnedBySelfVio();

  /// 相机自报内参(**采集尺寸**口径)。`null` = 还没交付过帧。
  PinholeIntrinsics? intrinsics({
    required int imageWidth,
    required int imageHeight,
  });

  CameraExposure? exposure();

  /// 建 XRSLAM 会话。
  XrslamSessionStart startSession({
    required CameraIntrinsics intrinsics,
    required double cameraTimeOffsetSeconds,
  });

  void destroySession();
}

/// 生产实现:直接打到原生。
class NativeZeroArkitPlatform implements ZeroArkitPlatform {
  const NativeZeroArkitPlatform();

  @override
  int startCamera({
    required int width,
    required int height,
    required double fps,
    required double lensPosition,
  }) =>
      ZeroArkitCameraGate.start(
        width: width,
        height: height,
        fps: fps,
        lensPosition: lensPosition,
      );

  @override
  void stopCamera() => ZeroArkitCameraGate.stop();

  @override
  bool cameraOwnedBySelfVio() => ZeroArkitCameraGate.ownedBySelfVio();

  @override
  PinholeIntrinsics? intrinsics({
    required int imageWidth,
    required int imageHeight,
  }) =>
      PwCameraSlot.intrinsics(imageWidth: imageWidth, imageHeight: imageHeight);

  @override
  CameraExposure? exposure() => PwCameraSlot.exposure();

  @override
  XrslamSessionStart startSession({
    required CameraIntrinsics intrinsics,
    required double cameraTimeOffsetSeconds,
  }) =>
      XrslamSession.start(
        intrinsics: intrinsics,
        cameraTimeOffsetSeconds: cameraTimeOffsetSeconds,
      );

  @override
  void destroySession() => XrslamSession.current?.destroy();
}

/// 零 ARKit 采集运行时。
class ZeroArkitCaptureRuntime {
  ZeroArkitCaptureRuntime({
    ZeroArkitPlatform platform = const NativeZeroArkitPlatform(),
    this.captureWidth = 1920,
    this.captureHeight = 1440,
    int? feedWidth,
    int? feedHeight,
    this.fps = 30,
    this.lensPosition = 0.835,
    CameraTimeOffset? cameraTimeOffset,
    String? machineIdentifier,
    this.intrinsicsTimeout = kZeroArkitIntrinsicsTimeout,
    this.intrinsicsPoll = kZeroArkitIntrinsicsPoll,
    DateTime Function()? now,
  })  : _platform = platform,
        // 🔴 喂料默认 = 采集尺寸(用户铁律「最低 1920×1440」;见文件头「改口」段)。
        feedWidth = feedWidth ?? captureWidth,
        feedHeight = feedHeight ?? captureHeight,
        _explicitOffset = cameraTimeOffset,
        _machineIdentifier = machineIdentifier,
        _now = now ?? DateTime.now {
    // 机型查表预热。**不 await** —— [start] 在被调用那一刻就读 c(见文件头
    // 「已知窗口」),这里能做的只有「尽早去问」。
    // `prime()` 自己吞掉通道不存在的异常,不会上抛。
    if (cameraTimeOffset == null && machineIdentifier == null) {
      unawaited(PwDeviceMachine.prime());
    }
  }

  final ZeroArkitPlatform _platform;

  /// 等第一帧内参的上限与轮询间隔。默认抄台架页(见
  /// [kZeroArkitIntrinsicsTimeout] / [kZeroArkitIntrinsicsPoll]);
  /// 单测缩短上限用。
  final Duration intrinsicsTimeout;
  final Duration intrinsicsPoll;

  /// 时钟。台架页用 `Stopwatch` 量 `intrinsics_wait_ms`;这里做成可注入,
  /// 因为单测跑在 FakeAsync 里 `Stopwatch` 不走(同
  /// `test/sparse_cloud_viewer_selection_test.dart` 文件头说的那件事),
  /// 用例传 `TestWidgetsFlutterBinding.instance.clock.now` 才能既驱动超时
  /// 又核 [ZeroArkitStartResult.intrinsicsWaitMs]。生产不传 = `DateTime.now`。
  final DateTime Function() _now;

  /// 调用方显式指定的 c。`null` = 由 [cameraTimeOffset] 查表。
  final CameraTimeOffset? _explicitOffset;

  /// 调用方显式指定的 `hw.machine`。`null` = 用 [PwDeviceMachine.cached]。
  final String? _machineIdentifier;

  /// 相机采集尺寸(显示/成片口径)。
  final int captureWidth;
  final int captureHeight;

  /// 喂引擎的尺寸(VIO 口径)。**默认 = 采集尺寸,不降采样**(文件头「改口」段:
  /// 分辨率不降、引擎臂换;原生本来就整帧推给引擎)。显式传比采集小的值才缩,
  /// 回执 [ZeroArkitStartResult.feedDownscaled] 如实标出。
  final int feedWidth;
  final int feedHeight;

  /// 喂料是否比采集小。只有显式传参才可能为 true。
  bool get feedDownscaled =>
      feedWidth != captureWidth || feedHeight != captureHeight;

  /// 抄上游 `ViewController.swift:255` 的 30,不是调出来的。
  final double fps;

  /// 锁镜头,抄上游 `ViewController.swift:256` 的 `setFocus(0.835)`。
  /// 不锁的话 fx 全程游走(实测单场 120 秒漂 10.90%),而引擎的内参是定值。
  final double lensPosition;

  /// 每机常量 c(值 + 来源)。09-22 定案的时间戳公式是 `c + (读出 + 曝光)/2`,
  /// 其中曝光那一半由原生传输层**逐帧**加;**这里只传常量 c**。
  ///
  /// 构造时不传就**查表**(`camera_time_offset.dart`):
  /// `--dart-define=PW_CAM_TD_MS` > `hw.machine` 查表 > 0(未测)。
  /// 🔴 每次读都重新解析 —— 机型查表是异步回来的,早读到的是「未知」,
  /// 晚读到的才可能是实测值。[start] 只在建会话那一刻读一次并记进结果里。
  CameraTimeOffset get cameraTimeOffset =>
      _explicitOffset ??
      resolveCameraTimeOffset(
        machine: _machineIdentifier ?? PwDeviceMachine.cached,
      );

  /// c 的秒值。原样交给 `XrslamSession.start(cameraTimeOffsetSeconds:)`。
  double get cameraTimeOffsetSeconds => cameraTimeOffset.seconds;

  bool _started = false;
  bool get started => _started;

  /// 在飞的那次 [start](起相机之后、会话建成/失败之前)。幂等靠它:
  /// 等内参途中再调 [start] 拿到的是**同一个** Future,不会再起一次相机。
  Future<ZeroArkitStartResult>? _starting;

  /// 正在等第一帧内参(已起相机、还没建会话)。
  bool get starting => _starting != null && !_started;

  /// [stop] 每叫一次加一。在飞的 [start] 每次从 `await` 醒来都比对它:
  /// 变了就说明等的途中被叫停 —— 相机已由 [stop] 关掉,不再建会话。
  /// 抄台架页轮询循环里的 `mounted` 检查(页面拆了就不再往下走),
  /// 本类没有 `mounted`,用代数代替。
  int _stopGeneration = 0;

  /// 每次真正发起的 [start](起了相机的那种)编号。被叫停的旧尝试醒来时,
  /// 只有它仍是**最新一次**尝试才把自己的失败写进 [lastStart] ——
  /// `stop()` 之后紧接着又 `start()`(离开采集页又立刻进来)时,
  /// 旧尝试不能把新尝试的回执盖掉。
  int _attemptSeq = 0;

  /// 最近一次 [start] 的回执。**建成/失败之前是上一次的值(第一次是 null)**
  /// —— 起相机到拿到内参之间是异步的,这段时间里读它读不到「这一次」。
  ZeroArkitStartResult? _lastStart;
  ZeroArkitStartResult? get lastStart => _lastStart;

  /// 起整条路。**幂等**:已起过就原样返回上次的结果;正在起就返回在飞的
  /// 那个 Future。
  ///
  /// 异步只在一处:起相机之后**等第一帧内参**(见文件头「时序」段)。
  /// 相机没起来 / 内参已经在手 / 会话起不来 这三条路上没有 await,
  /// 返回的 Future 在本调用返回前就已完成 ⇒ 台架页先自己轮询到内参再调
  /// 的那种用法,`lastStart` 在 [start] 返回时就已经是本次回执。
  Future<ZeroArkitStartResult> start() {
    if (_started) {
      return Future<ZeroArkitStartResult>.value(
        _lastStart ??
            ZeroArkitStartResult(
              cameraRc: null,
              sessionStarted: true,
              intrinsics: null,
              cameraTimeOffset: cameraTimeOffset,
              feedDownscaled: feedDownscaled,
              error: null,
            ),
      );
    }
    final Future<ZeroArkitStartResult>? inflight = _starting;
    if (inflight != null) return inflight;

    final Future<ZeroArkitStartResult> f =
        _startImpl(++_attemptSeq, _stopGeneration);
    _starting = f;
    // `.ignore()`:只是把「在飞」记账清掉;万一 `_startImpl` 抛了,错误由
    // 调用方 await 的那个 `f` 收,这条分支不再重复报一次未处理异常。
    f.whenComplete(() {
      if (identical(_starting, f)) _starting = null;
    }).ignore();
    return f;
  }

  Future<ZeroArkitStartResult> _startImpl(int attempt, int generation) async {
    // 🔴 c 在**这一刻**定下来:机型查表是异步回来的,早一点读到的可能是
    //    「未知」。定下来之后原样进 [ZeroArkitStartResult],
    //    引擎实际收到的是不是它,要靠 `XrslamLive.timebase()` 的
    //    `c传入 / c施加` 两行在真机上核 —— 本刀没有真机证据。
    final CameraTimeOffset c = cameraTimeOffset;

    // ① 相机先起(经租约闸)。
    final int rc = _platform.startCamera(
      width: captureWidth,
      height: captureHeight,
      fps: fps,
      lensPosition: lensPosition,
    );
    if (rc < 0) {
      _lastStart = ZeroArkitStartResult(
        cameraRc: rc,
        sessionStarted: false,
        intrinsics: null,
        cameraTimeOffset: c,
        feedDownscaled: feedDownscaled,
        error: rc == kZeroArkitCameraBusy
            ? '相机被 ARKit 占着(租约 rc=$rc)—— 开关 ON 时不该有 ARSession 在跑'
            : '相机起不来 rc=$rc',
      );
      return _lastStart!;
    }

    // ② 等第一帧内参。🔴 拿不到就**不建会话** —— 没有真实内参建出来的会话
    //    会拿 xrslam_session 的 PLACEHOLDER 值(fx=1000/cx=640)去解一台完全
    //    不同的相机,而且不会报任何错。宁可不起。
    //    循环抄台架页 `zero_arkit_capture_probe_page.dart` 的
    //    `while (mounted && sw.elapsed < timeout) { 读; 可用就 break; 等 poll }`,
    //    `mounted` 换成 [_stopGeneration] 比对(同一件事:被拆/被停就不再往下走)。
    //    第一次读不 await —— 内参已经在手(台架页那种先轮询后调的用法、
    //    或 start 被重调)时整条路仍是同步完成的。
    final DateTime t0 = _now();
    PinholeIntrinsics? k;
    while (generation == _stopGeneration &&
        _now().difference(t0) < intrinsicsTimeout) {
      k = _platform.intrinsics(
        imageWidth: captureWidth,
        imageHeight: captureHeight,
      );
      if (k != null && k.isUsable) break;
      await Future<void>.delayed(intrinsicsPoll);
    }
    final int waitedMs = _now().difference(t0).inMilliseconds;

    if (generation != _stopGeneration) {
      // 等的途中 [stop] 来了:相机已由它关掉,这里只如实记账。
      final ZeroArkitStartResult cancelled = ZeroArkitStartResult(
        cameraRc: rc,
        sessionStarted: false,
        intrinsics: null,
        cameraTimeOffset: c,
        feedDownscaled: feedDownscaled,
        intrinsicsWaitMs: waitedMs,
        error: '等第一帧内参 ${waitedMs}ms 时被 stop() 叫停 —— 不建会话',
      );
      // stop() 之后已经又 start() 了一次的话,[lastStart] 归新的那次。
      if (attempt == _attemptSeq) _lastStart = cancelled;
      return cancelled;
    }
    if (k == null || !k.isUsable) {
      _platform.stopCamera();
      _lastStart = ZeroArkitStartResult(
        cameraRc: rc,
        sessionStarted: false,
        intrinsics: null,
        cameraTimeOffset: c,
        feedDownscaled: feedDownscaled,
        intrinsicsWaitMs: waitedMs,
        error: '相机起来 ${waitedMs}ms 仍没自报可用内参'
            '(上限 ${intrinsicsTimeout.inMilliseconds}ms,'
            '每 ${intrinsicsPoll.inMilliseconds}ms 问一次)'
            '—— 不拿 PLACEHOLDER 建会话,相机已停',
      );
      return _lastStart!;
    }

    final CameraIntrinsics feedK = scaleIntrinsicsForFeed(
      captured: k,
      feedWidth: feedWidth,
      feedHeight: feedHeight,
    );

    // ③ 建会话。c 只在这里传一次 —— 引擎的 create 只吃一次,
    //    中途改不了(出货引擎导出的五个符号里没有「更新时间偏置」的入口)。
    final XrslamSessionStart s = _platform.startSession(
      intrinsics: feedK,
      cameraTimeOffsetSeconds: c.seconds,
    );
    if (!s.ok) {
      _platform.stopCamera();
      _lastStart = ZeroArkitStartResult(
        cameraRc: rc,
        sessionStarted: false,
        intrinsics: feedK,
        cameraTimeOffset: c,
        feedDownscaled: feedDownscaled,
        intrinsicsWaitMs: waitedMs,
        error: 'XRSLAM 会话起不来:${s.error}',
      );
      return _lastStart!;
    }

    _started = true;
    _lastStart = ZeroArkitStartResult(
      cameraRc: rc,
      sessionStarted: true,
      intrinsics: feedK,
      cameraTimeOffset: c,
      feedDownscaled: feedDownscaled,
      intrinsicsWaitMs: waitedMs,
      error: null,
    );
    // 🔴 可核的一行:值 + 来源 + 这个值怎么来的。
    //    台架页对应的那行是 `[arloop] 时基 c传入=… c施加=…`
    //    (`ar_minimal_loop_page.dart:430`),两行要对得上。
    debugPrint('[zero-arkit] ${c.describe} —— ${c.note};'
        '内参等待 ${waitedMs}ms;'
        '喂料 ${feedWidth}x$feedHeight${feedDownscaled ? '(显式降采样)' : '(=采集)'}');
    return _lastStart!;
  }

  /// 当前内参(**采集尺寸**口径)。每帧会变(自动对焦在动)⇒ 不要缓存。
  PinholeIntrinsics? currentIntrinsics() => _platform.intrinsics(
        imageWidth: captureWidth,
        imageHeight: captureHeight,
      );

  /// 当前曝光。
  CameraExposure? currentExposure() => _platform.exposure();

  /// 运行期自证:相机是不是在自研臂手里。
  bool cameraOwnedBySelfVio() => _platform.cameraOwnedBySelfVio();

  /// 停整条路。**幂等**。等第一帧内参的途中被叫停也算数:相机在这里关,
  /// 在飞的 [start] 下次醒来看到 [_stopGeneration] 变了就如实退出、不建会话。
  void stop() {
    if (!_started) {
      // 没起成(或还在等内参)也要确保相机是停的 —— start 的失败分支已经
      // 停过,这里再停一次是无害的(槽的 stop 是幂等的),但会把租约还干净。
      // 在飞的那次不再算「在飞」:之后再 start 是新的一次(重新起相机),
      // 不能把旧的、注定以「被叫停」收场的 Future 交给新调用方。
      _stopGeneration++;
      _starting = null;
      _platform.stopCamera();
      return;
    }
    _started = false;
    _platform.destroySession();
    _platform.stopCamera();
  }
}

/// 采集尺寸的内参 → 喂料尺寸的内参。
///
/// 各向同性与否由两个方向的比例各自决定:`sx = feedW/capW`,`sy = feedH/capH`。
/// 针孔模型下 `fx' = fx·sx`,`cx' = cx·sx`,y 方向同理 —— 这是纯图像缩放,
/// 不是标定。
///
/// 🔴 provenance 标 [FieldProvenance.deviceApi]:这是**系统 API 自报**的内参
/// (`AVCameraCalibrationData`)按比例换算来的 —— 不是我们测的(那是
/// `measured`)、不是查表(`sharedDefault`)、更不是占位。
/// 🔴 09-22 的安卓喂料链在这一步漏写过(fx 留成 0),所以这里是独立函数
/// 并且有单测。
CameraIntrinsics scaleIntrinsicsForFeed({
  required PinholeIntrinsics captured,
  required int feedWidth,
  required int feedHeight,
}) {
  if (captured.imageWidth <= 0 || captured.imageHeight <= 0) {
    throw ArgumentError(
      '采集尺寸非法:${captured.imageWidth}x${captured.imageHeight}',
    );
  }
  if (feedWidth <= 0 || feedHeight <= 0) {
    throw ArgumentError('喂料尺寸非法:${feedWidth}x$feedHeight');
  }
  final double sx = feedWidth / captured.imageWidth;
  final double sy = feedHeight / captured.imageHeight;
  return CameraIntrinsics(
    fx: captured.fx * sx,
    fy: captured.fy * sy,
    cx: captured.cx * sx,
    cy: captured.cy * sy,
    resolutionWidth: feedWidth,
    resolutionHeight: feedHeight,
    provenance: FieldProvenance.deviceApi,
  );
}
