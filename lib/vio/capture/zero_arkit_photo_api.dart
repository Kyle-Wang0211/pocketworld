// zero_arkit_photo_api.dart —— 零 ARKit 臂的**照片出口**(只调不实现)。
//
// ══ 🔴 实现不在这里 ════════════════════════════════════════════════════════
// 照片这条路由**另一位 agent**在另一条分支上落地(原生 `PwCameraSlot.swift`
// 的 `AVCapturePhotoOutput` + Dart 侧 `PwCameraSlot.capturePhoto` /
// `PwCameraSlot.photoResult`)。本文件**只按约定好的签名调用**,一行都不实现
// 拍照逻辑,也**不改** `lib/vio/pose/camera_slot_ffi.dart`(那是对方的文件)。
//
// ══ 为什么不直接写 `PwCameraSlot.capturePhoto(...)` ═════════════════════════
// 那两个 Dart 方法今天还不存在 ⇒ 直接写会让本分支编不过,而两条分支是
// **独立的**、不互相依赖。所以这里走**同一套 C ABI**(那才是两边真正的约定面):
//
//     int64_t pw_camera_slot_capture_photo(int64_t request_id);
//     int32_t pw_camera_slot_photo_result(char* out_path, int32_t cap,
//                                         double out9[9]);
//
// 对方的 `PwCameraSlot.capturePhoto` / `photoResult` 绑的是同两个符号,
// 所以两条路在真机上落到**同一个实现**;合分支时把本文件的默认实现换成
// 直接调他们的 Dart 方法即可,调用点([ZeroArkitPhotoApi] 这个接口)不用动。
//
// ══ `out9` 的九个槽 ════════════════════════════════════════════════════════
//     [0] requestId   [1] fx  [2] fy  [3] cx  [4] cy
//     [5] width       [6] height      [7] t(秒,与位姿同一时基)
//     [8] exposureSeconds
// 🔴 `requestId` 走 double 槽 ⇒ 精度只到 2^53。它是个单调计数器,够用;
//    但**不要**往里塞时间戳纳秒那种量级的值。

import 'dart:ffi';

/// 一次成片的结果。字段与 `out9` + `out_path` 一一对应。
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

  final int requestId;
  final String path;
  final double fx;
  final double fy;
  final double cx;
  final double cy;
  final int width;
  final int height;

  /// 与位姿同一时基(`PwMonotonicClock`)。配位姿靠它,不靠到达顺序。
  final double timestampSeconds;

  /// 实际曝光时长。🔴 时间戳配对要用**曝光中点**
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
  /// 请求拍一张。返回原生接受的 requestId(`null` = 拒绝 / 接口不可用)。
  int? capturePhoto(int requestId);

  /// 取最近一次完成的成片。`null` = 还没有新结果。
  ZeroArkitPhotoResult? photoResult();
}

/// 走 C ABI 的生产实现。
///
/// 🔴 符号不在(对方分支还没合 / 模拟器 / 单测)⇒ **永久**降级成
/// 「接口不可用」,不每帧付一次异常的钱。与 `EnginePosePoller` 的粘性闸同款。
class NativeZeroArkitPhotoApi implements ZeroArkitPhotoApi {
  NativeZeroArkitPhotoApi();

  static const int _pathCapacity = 1024;

  bool _gaveUp = false;

  /// 为什么不可用(诊断用)。`null` = 正常或还没试过。
  Object? get unavailableReason => _reason;
  Object? _reason;

  @override
  int? capturePhoto(int requestId) {
    if (_gaveUp) return null;
    try {
      final int rc = _capture(requestId);
      // 约定:>=0 是接受(原样回 requestId),负数是拒绝。
      return rc >= 0 ? rc : null;
    } catch (e) {
      _gaveUp = true;
      _reason = e;
      return null;
    }
  }

  @override
  ZeroArkitPhotoResult? photoResult() {
    if (_gaveUp) return null;
    try {
      final Pointer<Void> pathBuf = _malloc(_pathCapacity);
      final Pointer<Void> numBuf = _malloc(8 * 9);
      try {
        final int rc = _result(
          pathBuf.cast<Uint8>(),
          _pathCapacity,
          numBuf.cast<Double>(),
        );
        if (rc != 0) return null; // 0 = 有新结果;其余一律当「没有」
        final Pointer<Double> n = numBuf.cast<Double>();
        return ZeroArkitPhotoResult(
          requestId: n[0].toInt(),
          path: _readCString(pathBuf.cast<Uint8>(), _pathCapacity),
          fx: n[1],
          fy: n[2],
          cx: n[3],
          cy: n[4],
          width: n[5].toInt(),
          height: n[6].toInt(),
          timestampSeconds: n[7],
          exposureSeconds: n[8],
        );
      } finally {
        _free(pathBuf);
        _free(numBuf);
      }
    } catch (e) {
      _gaveUp = true;
      _reason = e;
      return null;
    }
  }

  static String _readCString(Pointer<Uint8> p, int cap) {
    final List<int> bytes = <int>[];
    for (int i = 0; i < cap; i++) {
      final int b = p[i];
      if (b == 0) break;
      bytes.add(b);
    }
    return String.fromCharCodes(bytes);
  }

  static final DynamicLibrary _lib = DynamicLibrary.process();

  static final int Function(int) _capture = _lib.lookupFunction<
      Int64 Function(Int64),
      int Function(int)>('pw_camera_slot_capture_photo');

  static final int Function(Pointer<Uint8>, int, Pointer<Double>) _result =
      _lib.lookupFunction<
          Int32 Function(Pointer<Uint8>, Int32, Pointer<Double>),
          int Function(Pointer<Uint8>, int, Pointer<Double>)>(
        'pw_camera_slot_photo_result',
      );

  static final Pointer<Void> Function(int) _malloc = _lib.lookupFunction<
      Pointer<Void> Function(IntPtr),
      Pointer<Void> Function(int)>('malloc');

  static final void Function(Pointer<Void>) _free = _lib.lookupFunction<
      Void Function(Pointer<Void>),
      void Function(Pointer<Void>)>('free');
}
