// zero_arkit_photo_api.dart —— 零 ARKit 臂的**照片出口**(只调不实现)。
//
// ══ 🔴 实现不在这里 ════════════════════════════════════════════════════════
// 拍照通路由**另一位 agent**落地(原生 `PwCameraSlot.swift` 的
// `AVCapturePhotoOutput` + Dart 门面 `lib/vio/ffi/pw_camera_photo_ffi.dart`),
// 已 cherry-pick 进本分支(`405eca6` + `28ff7de`)。
// 本文件只剩**一个薄适配器**:把他们的 `PwCameraPhoto` / `PwCapturedPhoto`
// 适配成本臂的 [ZeroArkitPhotoApi] 接口,好让单测能注入替身。
// 拍照逻辑一行都不在这里,`camera_slot_ffi.dart` / `PwCameraSlot.swift`
// 一个字节没动。
//
// ══ 早先那版 stub 的下场 ═══════════════════════════════════════════════════
// 两条分支并行时我先按约定好的 C ABI 自己绑了一遍符号
// (`pw_camera_slot_capture_photo` / `pw_camera_slot_photo_result`)。
// 对方分支落地后**换成直接调他们的门面** —— 同一套符号绑两遍迟早会漂,
// 而且他们的 `PwCapturedPhoto.parse` 还多做了两件本臂需要的事:
// 数目/尺寸不对时返回 null(不交半条记录),以及 sidecar 路径推导。

import '../ffi/pw_camera_photo_ffi.dart';

/// 一次成片的结果。**就是** `PwCapturedPhoto` 的别名级包装 —— 字段一一对应,
/// 存在的唯一理由是让 [ZeroArkitPhotoApi] 的单测替身不必依赖 FFI 类型。
class ZeroArkitPhotoResult {
  const ZeroArkitPhotoResult({
    required this.requestId,
    required this.path,
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    required this.width,
    required this.height,
    required this.timestampSeconds,
    required this.exposureSeconds,
  });

  /// 从对方的 `PwCapturedPhoto` 转过来。**逐字段直抄,不做任何换算** ——
  /// 特别是**不**替调用方把曝光中点加上去(见 [exposureSeconds])。
  factory ZeroArkitPhotoResult.fromNative(PwCapturedPhoto p) =>
      ZeroArkitPhotoResult(
        requestId: p.requestId,
        path: p.path,
        fx: p.fx,
        fy: p.fy,
        cx: p.cx,
        cy: p.cy,
        width: p.width,
        height: p.height,
        timestampSeconds: p.timestampSeconds,
        exposureSeconds: p.exposureSeconds,
      );

  final int requestId;
  final String path;

  /// 逐张内参,**已经缩到这张照片自己的像素尺寸**(对方门面的契约)。
  final double fx;
  final double fy;
  final double cx;
  final double cy;
  final int width;
  final int height;

  /// 拍照时刻,秒。host clock,与视频流 PTS 同域 ⇒ 可以直接和位姿对齐。
  final double timestampSeconds;

  /// 这张照片自己的曝光时长。🔴 时间戳配对要用**曝光中点**
  /// (09-22 定案:`t + exposure/2`),这里交出的是原始 t 与 exposure 两项,
  /// **不替调用方做那个加法** —— 做了就没人知道加过没加过。
  final double exposureSeconds;

  @override
  String toString() =>
      'ZeroArkitPhotoResult(#$requestId $path ${width}x$height '
      'K=[$fx,$fy,$cx,$cy] t=$timestampSeconds exp=$exposureSeconds)';
}

/// 照片出口的契约。生产用 [NativeZeroArkitPhotoApi];测试注入替身。
abstract interface class ZeroArkitPhotoApi {
  /// 请求拍一张。返回**原生受理码**,与 `PwCameraPhoto.capture` 同口径:
  /// **0 = 已受理**,负数 = 原生失败码,`null` = 接口不可用。
  /// 🔴 返回的**不是** requestId —— 09-22 真机上 provider 曾拿它去比
  ///    `photoResult().requestId`,13 次快门全部超时。配对要用调用方自己的
  ///    [requestId]。
  int? capturePhoto(int requestId);

  /// 取最近一次完成的成片。`null` = 还没有新结果。
  ZeroArkitPhotoResult? photoResult();
}

/// 生产实现:**转调对方的门面**,不自己绑符号。
///
/// 🔴 `PwCameraPhoto` 自己在符号不在时全部降级返回 null 且不抛
/// (模拟器 / 没链进去 / Release 没导出),所以这里不需要第二道粘性闸 ——
/// 加一道只会变成两份互相不知道的状态。
class NativeZeroArkitPhotoApi implements ZeroArkitPhotoApi {
  const NativeZeroArkitPhotoApi();

  /// 原生拍照通路在不在(诊断 / 报告用)。
  bool get available => PwCameraPhoto.available;

  @override
  int? capturePhoto(int requestId) => PwCameraPhoto.capture(requestId);

  @override
  ZeroArkitPhotoResult? photoResult() {
    final PwCapturedPhoto? p = PwCameraPhoto.result();
    return p == null ? null : ZeroArkitPhotoResult.fromNative(p);
  }
}
