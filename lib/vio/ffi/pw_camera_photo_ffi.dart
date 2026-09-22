// pw_camera_photo_ffi.dart —— 我们自己的相机栈拍**高清照片**的 Dart 侧绑定。
//
// 对应 `ios/Runner/PwCameraSlot.swift` 里 `MARK: - 高清拍照(零 ARKit 路径)`
// 那一节的两个 C ABI 出口:
//   `pw_camera_slot_capture_photo(int64 requestId) -> int32`
//   `pw_camera_slot_photo_result(char* path, int32 cap, double* nums9) -> int32`
//
// ══ 这块拼图解决的是什么 ═════════════════════════════════════════════════
// 生产拍摄页现在由 ARKit 拥有相机,高清照片走
// `OfficialAetherARKitPlugin.captureHighResolutionFrame`。而 iOS **一次只把
// 后置相机给一个会话** ⇒ 想让拍摄流程在完全不启动 ARKit 的情况下也出照片,
// 照片就必须由我们自己的 `AVCaptureSession` 拍。这里是那条路的 Dart 门面。
//
// ══ 🔴 降级风格与 `xrslam_live_ffi.dart` 一致 ════════════════════════════
// 符号查不到(旧构建的二进制、或这条路没编进去)时**返回 null,不抛**。
// 调用方据此回落到 ARKit 路径,而不是崩在启动路径上。
//
// ══ 语义:FIFO 逐个取走,不是"读最近一次" ═══════════════════════════════
// [PwCameraPhoto.result] 取走**最早一个**已完成的结果并把它从原生队列里消费掉。
// 连拍时先完成的先出;原生侧上限 32 条,超了丢最老的并 NSLog 计账。
// 所以正确用法是**循环取到 null 为止**,而不是取一次就以为拿全了。

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

typedef _CaptureNative = ffi.Int32 Function(ffi.Int64);
typedef _CaptureDart = int Function(int);
typedef _ResultNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Char>, ffi.Int32, ffi.Pointer<ffi.Double>);
typedef _ResultDart = int Function(
    ffi.Pointer<ffi.Char>, int, ffi.Pointer<ffi.Double>);

/// 一张已经落盘的高清照片 + 它的逐张内参。
///
/// 与原生 `pw_camera_slot_photo_result` 写出的 9 个 double 一一对应,
/// 顺序是冻结的:`[requestId, fx, fy, cx, cy, width, height, t, exposure]`。
class PwCapturedPhoto {
  const PwCapturedPhoto({
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

  /// 发起拍照时传进去的那个 id。照片落在
  /// `Documents/pw_photos/<requestId>.heic|jpg`,sidecar 是同名 `.json`。
  final int requestId;

  /// 照片文件的绝对路径。sidecar 就是把扩展名换成 `.json`。
  final String path;

  /// 逐张内参,**已经缩到这张照片自己的像素尺寸上**(不是视频流的尺寸)。
  /// 走哪条来源(照片自带标定 / 视频连接缩放)写在 sidecar 的
  /// `intrinsics_provenance` 里 —— 这里只给数。
  final double fx;
  final double fy;
  final double cx;
  final double cy;

  /// 照片的实际像素尺寸。原生侧是从**文件头**读的,不是抄请求值。
  final int width;
  final int height;

  /// 拍照时刻,秒,**host clock,与视频流 PTS 同域**
  /// (`AVCapturePhoto.timestamp`,Apple 头文件:"synchronized to the
  /// synchronizationClock of the AVCaptureSession … analogous to
  /// CMSampleBufferGetPresentationTimeStamp()")。
  /// 所以它可以直接和 VIO 位姿的时间轴对齐,不需要换算。
  final double timestampSeconds;

  /// 这张照片自己的曝光时长,秒。优先来自照片 EXIF 的 ExposureTime。
  final double exposureSeconds;

  /// sidecar 路径 = 同目录同名 `.json`。
  String get sidecarPath {
    final int dot = path.lastIndexOf('.');
    final int slash = path.lastIndexOf('/');
    if (dot <= slash) return '$path.json';
    return '${path.substring(0, dot)}.json';
  }

  /// 从"路径 + 9 个 double"解析。**与 FFI 解耦**,所以可以离线测。
  ///
  /// 数目不对、或 requestId/尺寸不是正数时返回 `null` —— 宁可当作没结果,
  /// 也不把半条记录交给下游。
  static PwCapturedPhoto? parse(String path, List<double> nums) {
    if (nums.length < 9) return null;
    if (path.isEmpty) return null;
    final double w = nums[5];
    final double h = nums[6];
    if (!w.isFinite || !h.isFinite || w <= 0 || h <= 0) return null;
    final double id = nums[0];
    if (!id.isFinite) return null;
    return PwCapturedPhoto(
      requestId: id.toInt(),
      path: path,
      fx: nums[1],
      fy: nums[2],
      cx: nums[3],
      cy: nums[4],
      width: w.toInt(),
      height: h.toInt(),
      timestampSeconds: nums[7],
      exposureSeconds: nums[8],
    );
  }

  @override
  String toString() => 'PwCapturedPhoto(#$requestId ${width}x$height '
      'fx=${fx.toStringAsFixed(2)} fy=${fy.toStringAsFixed(2)} '
      'cx=${cx.toStringAsFixed(2)} cy=${cy.toStringAsFixed(2)} '
      't=${timestampSeconds.toStringAsFixed(6)} '
      'exp=${(exposureSeconds * 1000).toStringAsFixed(2)}ms $path)';
}

/// 原生高清拍照通路的门面。**符号不在时全部降级返回 null,不抛。**
abstract final class PwCameraPhoto {
  static ffi.DynamicLibrary get _lib => ffi.DynamicLibrary.process();

  /// 路径缓冲。沙盒路径实测 ~120 字节,1024 是充裕的上限;
  /// 原生侧放不下时返回 -2 且**不消费**结果,所以这里放不下不会丢照片。
  static const int pathCapacity = 1024;

  static bool _looked = false;
  static _CaptureDart? _capture;
  static _ResultDart? _result;

  static void _lookup() {
    if (_looked) return;
    _looked = true;
    try {
      _capture = _lib.lookupFunction<_CaptureNative, _CaptureDart>(
          'pw_camera_slot_capture_photo');
      _result = _lib.lookupFunction<_ResultNative, _ResultDart>(
          'pw_camera_slot_photo_result');
    } catch (_) {
      // 没链上就保持 null —— 调用方回落到 ARKit 路径。
    }
  }

  /// 两个符号是否都在。
  static bool get available {
    _lookup();
    return _capture != null && _result != null;
  }

  /// 触发一次高清拍照。**只受理,不等待**;结果用 [result] 轮询。
  ///
  /// 返回 0 已受理;负数是原生失败码:
  ///   -1 相机没起来(先 `PwCameraSlot.start`)
  ///   -2 这个会话上装不了 `AVCapturePhotoOutput`
  ///   -3 同一个 [requestId] 还在飞
  ///   -4 沙盒 `Documents/pw_photos/` 建不出来
  /// 符号不在返回 `null`。
  static int? capture(int requestId) {
    _lookup();
    return _capture?.call(requestId);
  }

  // 复用同两块缓冲:每张照片一次调用,没必要每次 malloc/free。
  static final ffi.Pointer<ffi.Char> _pathOut =
      calloc<ffi.Char>(pathCapacity);
  static final ffi.Pointer<ffi.Double> _numsOut = calloc<ffi.Double>(9);

  /// 取走**最早一个**已完成的拍照结果。
  ///
  /// `null` = 还没有结果 / 符号不在 / 原生给回了放不下的路径。
  /// 🔴 要拿全就**循环取到 null 为止**。
  static PwCapturedPhoto? result() {
    _lookup();
    final _ResultDart? f = _result;
    if (f == null) return null;
    if (f(_pathOut, pathCapacity, _numsOut) != 0) return null;
    final String path = _pathOut.cast<Utf8>().toDartString();
    return PwCapturedPhoto.parse(
      path,
      <double>[
        _numsOut[0], _numsOut[1], _numsOut[2], _numsOut[3], _numsOut[4],
        _numsOut[5], _numsOut[6], _numsOut[7], _numsOut[8],
      ],
    );
  }

  /// 把当前所有已完成的结果一次取空。
  static List<PwCapturedPhoto> drain({int max = 64}) {
    final List<PwCapturedPhoto> out = <PwCapturedPhoto>[];
    for (int i = 0; i < max; i++) {
      final PwCapturedPhoto? p = result();
      if (p == null) break;
      out.add(p);
    }
    return out;
  }
}
