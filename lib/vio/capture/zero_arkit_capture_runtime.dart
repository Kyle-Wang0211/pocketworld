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
// ══ 🔴 两个口径必须分开(台架页文件头栽过一次)═════════════════════════════
// * **喂 VIO 的**是 640×480 —— 上游 18 份 iPhone 标定 18/18 全是这个尺寸,
//   而 1920×1440 直喂 VIO 实测撞吞吐墙(10.5 fps 处理 / 丢 16.5% 帧)。
// * **相机采的**是 1920×1440 —— 显示与成片都要它。
// ⇒ 相机按 [captureWidth]×[captureHeight] 采;交给引擎的内参按
//   [feedWidth]×[feedHeight] **等比换算**(见 [_scaleIntrinsics])。
//   🔴 换算这一步 09-22 的安卓喂料链里漏过一次(fx 写成 0),所以这里
//     写成一个独立函数 + 单测,而不是内联一行。
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
//   是同步的 ⇒ 进程内第一次建会话时查表可能还没回来,那一次会如实打
//   `provenance=PLACEHOLDER(机型未知)`。缺口与两条出路同样写在那个文件头上。
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

/// 启动结果。失败时 [error] 一定非空 —— 不返回一个「看起来起来了」的实例。
class ZeroArkitStartResult {
  const ZeroArkitStartResult({
    required this.cameraRc,
    required this.sessionStarted,
    required this.intrinsics,
    required this.cameraTimeOffset,
    required this.error,
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

  final String? error;

  bool get ok => error == null;

  /// 失败原因是不是「ARKit 还占着相机」。调用方据此给出可操作的提示,
  /// 而不是笼统的「相机起不来」。
  bool get blockedByArkit => cameraRc == kZeroArkitCameraBusy;

  @override
  String toString() => 'ZeroArkitStartResult(cameraRc=$cameraRc '
      'session=$sessionStarted K=${intrinsics == null ? 'null' : 'ok'} '
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
    this.feedWidth = 640,
    this.feedHeight = 480,
    this.fps = 30,
    this.lensPosition = 0.835,
    CameraTimeOffset? cameraTimeOffset,
    String? machineIdentifier,
  })  : _platform = platform,
        _explicitOffset = cameraTimeOffset,
        _machineIdentifier = machineIdentifier {
    // 机型查表预热。**不 await** —— 本类的 [start] 是同步的(见文件头
    // 「已知窗口」),这里能做的只有「尽早去问」。
    // `prime()` 自己吞掉通道不存在的异常,不会上抛。
    if (cameraTimeOffset == null && machineIdentifier == null) {
      unawaited(PwDeviceMachine.prime());
    }
  }

  final ZeroArkitPlatform _platform;

  /// 调用方显式指定的 c。`null` = 由 [cameraTimeOffset] 查表。
  final CameraTimeOffset? _explicitOffset;

  /// 调用方显式指定的 `hw.machine`。`null` = 用 [PwDeviceMachine.cached]。
  final String? _machineIdentifier;

  /// 相机采集尺寸(显示/成片口径)。
  final int captureWidth;
  final int captureHeight;

  /// 喂引擎的尺寸(VIO 口径)。上游 18/18 份 iPhone 标定都是 640×480。
  final int feedWidth;
  final int feedHeight;

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

  ZeroArkitStartResult? _lastStart;
  ZeroArkitStartResult? get lastStart => _lastStart;

  /// 起整条路。**幂等**:已起过就原样返回上次的结果。
  ZeroArkitStartResult start() {
    // 🔴 c 在**这一刻**定下来:机型查表是异步回来的,早一点读到的可能是
    //    「未知」。定下来之后原样进 [ZeroArkitStartResult],
    //    引擎实际收到的是不是它,要靠 `XrslamLive.timebase()` 的
    //    `c传入 / c施加` 两行在真机上核 —— 本刀没有真机证据。
    final CameraTimeOffset c = cameraTimeOffset;

    if (_started) {
      return _lastStart ??
          ZeroArkitStartResult(
            cameraRc: null,
            sessionStarted: true,
            intrinsics: null,
            cameraTimeOffset: c,
            error: null,
          );
    }

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
        error: rc == kZeroArkitCameraBusy
            ? '相机被 ARKit 占着(租约 rc=$rc)—— 开关 ON 时不该有 ARSession 在跑'
            : '相机起不来 rc=$rc',
      );
      return _lastStart!;
    }

    // ② 内参。🔴 拿不到就**不建会话** —— 没有真实内参建出来的会话会拿
    //    xrslam_session 的 PLACEHOLDER 值(fx=1000/cx=640)去解一台完全
    //    不同的相机,而且不会报任何错。宁可不起。
    final PinholeIntrinsics? k = _platform.intrinsics(
      imageWidth: captureWidth,
      imageHeight: captureHeight,
    );
    if (k == null || !k.isUsable) {
      _platform.stopCamera();
      _lastStart = ZeroArkitStartResult(
        cameraRc: rc,
        sessionStarted: false,
        intrinsics: null,
        cameraTimeOffset: c,
        error: '相机还没自报内参(或内参不可用)—— 不拿 PLACEHOLDER 建会话',
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
      error: null,
    );
    // 🔴 可核的一行:值 + 来源 + 这个值怎么来的。
    //    台架页对应的那行是 `[arloop] 时基 c传入=… c施加=…`
    //    (`ar_minimal_loop_page.dart:430`),两行要对得上。
    debugPrint('[zero-arkit] ${c.describe} —— ${c.note}');
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

  /// 停整条路。**幂等**。
  void stop() {
    if (!_started) {
      // 没起成也要确保相机是停的 —— start 的失败分支已经停过,这里再停一次
      // 是无害的(槽的 stop 是幂等的),但会把租约还干净。
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
