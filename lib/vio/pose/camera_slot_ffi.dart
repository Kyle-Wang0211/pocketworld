// camera_slot_ffi.dart — 相机帧保留槽的 Dart 侧绑定。
//
// 对应 `ios/Runner/PwCameraSlot.swift` 的 C ABI 出口。用
// `DynamicLibrary.process()` 查找 —— 那些符号由 `@_cdecl` 提供 C 链接,链在
// app 主二进制里(仓里 `official_aether_sfm_ffi.dart:31` 已有同样的用法)。
//
// ══ 为什么是 Dart 主动拉,而不是原生推 ═══════════════════════════════════
// Dart→原生的 FFI 调用是**同步的、在调用方 isolate 线程上**执行的,没有线程
// 亲和性问题。反方向的三种推法各有硬伤:
//   ⚰️ `NativeCallable.isolateLocal` 从非 mutator 线程调 = **进程 abort**
//      (Dart 官方文档原话),而采集回调恰好不在那个线程上;
//   ⚰️ `NativeCallable.listener` 异步 + 只能 void + 无背压;
//   ⚰️ `MethodChannel` 要求平台主线程,且地址到手已过期。
//
// ══ 🔴 所有权:acquire 与 release 必须成对 ═══════════════════════════════
// [acquire] 交出的是一个**已 retain 的 +1**。把它交给 Filament 的
// `setExternalImage` 之后**必须** [release] 还掉自己那份 —— Filament 自己会
// 再 retain 一份(`MetalExternalImage.mm:109`),它不接管你的。
// 不还 = 每帧漏一个全分辨率缓冲。台架实测过这条路的终点:**3592 帧掉 539 帧
// `OutOfBuffers`(15%)**,p95 延迟 908 ms。
// [PwCameraSlot.withFrame] 用 try/finally 把这件事做成机械保证。

import 'dart:ffi';

import 'camera_projection.dart';

typedef _StartNative = Int32 Function(Int32, Int32);
typedef _StartDart = int Function(int, int);
typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();
typedef _AcquireNative = Uint64 Function();
typedef _AcquireDart = int Function();
typedef _ReleaseNative = Void Function(Uint64);
typedef _ReleaseDart = void Function(int);
typedef _OutDoubleNative = Int32 Function(Pointer<Double>);
typedef _OutDoubleDart = int Function(Pointer<Double>);
typedef _OutInt64Native = Void Function(Pointer<Int64>);
typedef _OutInt64Dart = void Function(Pointer<Int64>);

/// 槽的计账。`acquired - released` 是当前未归还数,**应当恒为 0 或 1**。
class CameraSlotStats {
  const CameraSlotStats({
    required this.offered,
    required this.displaced,
    required this.acquired,
    required this.released,
    required this.slotOccupied,
  });

  /// 相机交付的帧数。
  final int offered;

  /// 被新帧顶掉、未被消费的帧数。**这是正常的**(深度 1 的代价),
  /// 不是丢帧错误 —— 渲染器要的是最新一帧。
  final int displaced;

  final int acquired;
  final int released;
  final bool slotOccupied;

  /// 未归还的缓冲数。**> 1 就是泄漏。**
  int get outstanding => acquired - released;

  @override
  String toString() => 'CameraSlot(offered:$offered displaced:$displaced '
      'acquired:$acquired released:$released outstanding:$outstanding '
      'occupied:$slotOccupied)';
}

/// 原生相机保留槽。
abstract final class PwCameraSlot {
  static final DynamicLibrary _lib = DynamicLibrary.process();

  static final _StartDart _start =
      _lib.lookupFunction<_StartNative, _StartDart>('pw_camera_slot_start');
  static final _VoidDart _stop =
      _lib.lookupFunction<_VoidNative, _VoidDart>('pw_camera_slot_stop');
  static final _AcquireDart _acquire = _lib
      .lookupFunction<_AcquireNative, _AcquireDart>('pw_camera_slot_acquire');
  static final _ReleaseDart _release = _lib
      .lookupFunction<_ReleaseNative, _ReleaseDart>('pw_camera_slot_release');
  static final _OutDoubleDart _intrinsics =
      _lib.lookupFunction<_OutDoubleNative, _OutDoubleDart>(
          'pw_camera_slot_intrinsics');
  static final _OutInt64Dart _stats = _lib
      .lookupFunction<_OutInt64Native, _OutInt64Dart>('pw_camera_slot_stats');

  /// 启动采集。返回 0 成功;负数是原生侧的失败码(见 Swift 文件)。
  ///
  /// 🔴 iOS 把后置相机只给一个会话 ⇒ 这条通路与 ARKit / 生产采集
  /// **不能同时跑**。只在显式验证时调用。
  static int start({int width = 640, int height = 480}) =>
      _start(width, height);

  static void stop() => _stop();

  /// 取当前帧。返回**已 retain** 的 `CVPixelBufferRef` 地址,0 = 无新帧。
  /// 🔴 优先用 [withFrame],它保证配对释放。
  static int acquire() => _acquire();

  static void release(int address) => _release(address);

  /// 拿一帧、**同步地**用它、保证还掉。
  ///
  /// [body] 返回值原样透出;无新帧时返回 `null` 且 [body] 不被调用。
  ///
  /// 🔴 [body] **不能是 async**。它一旦返回 Future,下面的 finally 会在
  /// Future 还没完成时就把缓冲还掉 —— 消费方(Filament 的
  /// `setupExternalImage`)还没来得及自己 retain,缓冲就可能被回收。
  /// 而且 IOSurface 是复用的,读到的是**别人的像素,不是崩溃** ——
  /// 这种错不会有任何报错。异步消费请用 [withFrameAsync]。
  /// 运行时也拦一道,免得只靠注释。
  static T? withFrame<T>(T Function(int address) body) {
    final int addr = _acquire();
    if (addr == 0) return null;
    try {
      final T result = body(addr);
      if (result is Future) {
        throw ArgumentError(
          'withFrame 的 body 返回了 Future。同步入口会在 Future 完成前就'
          '归还缓冲,消费方读到的会是复用 IOSurface 里的陈旧像素(不报错)。'
          '请改用 withFrameAsync。',
        );
      }
      return result;
    } finally {
      // finally 而不是顺序执行:body 抛异常也必须还,否则一次异常就漏一个
      // 全分辨率缓冲,而相机池只有几个。
      _release(addr);
    }
  }

  /// 拿一帧、**异步地**用它、等它用完再还掉。
  ///
  /// 送进 Filament 的那条路必须走这个:`Texture.setExternalImage` 在
  /// thermion 里是排到渲染线程上再执行的,真正的 `CVPixelBufferRetain`
  /// (`MetalDriver.mm:1254-1262`)发生在那一侧。await 完成之后才归还,
  /// 是让"Filament 已经自己 retain 过"这件事成立的唯一方式。
  ///
  /// 无新帧时返回 `null` 且 [body] 不被调用。
  static Future<T?> withFrameAsync<T>(
      Future<T> Function(int address) body) async {
    final int addr = _acquire();
    if (addr == 0) return null;
    try {
      return await body(addr);
    } finally {
      _release(addr);
    }
  }

  /// 相机自报的内参。`null` 表示还没有交付过。
  ///
  /// 🔴 每帧都会变 —— 自动对焦全程在动,实测单场 120 秒 fx 漂 **10.90%**
  /// (426.842 → 476.037)。所以这是**当前值**,不是常量,不要缓存。
  static PinholeIntrinsics? intrinsics({
    required int imageWidth,
    required int imageHeight,
  }) {
    final Pointer<Double> buf = calloc4();
    try {
      if (_intrinsics(buf) != 0) return null;
      return PinholeIntrinsics(
        fx: buf[0],
        fy: buf[1],
        cx: buf[2],
        cy: buf[3],
        imageWidth: imageWidth,
        imageHeight: imageHeight,
      );
    } finally {
      _free(buf.cast());
    }
  }

  /// [pw 2026-09-19] 实际曝光参数 —— **只读诊断**,回答"为什么比系统相机暗"。
  ///
  /// `null` 表示还没开始采集。字段含义见 `PwCameraSlot.swift` 的
  /// `pw_camera_slot_exposure`。
  static CameraExposure? exposure() {
    final Pointer<Double> buf = calloc8();
    try {
      if (_exposure(buf) != 0) return null;
      return CameraExposure(
        exposureSeconds: buf[0],
        iso: buf[1],
        aperture: buf[2],
        exposureMode: buf[3].toInt(),
        targetOffsetEv: buf[4],
        formatIsBinned: buf[5] != 0,
        minFrameDurationSeconds: buf[6],
        maxFrameDurationSeconds: buf[7],
      );
    } finally {
      _free(buf.cast());
    }
  }

  static final int Function(Pointer<Double>) _exposure = _lib.lookupFunction<
      Int32 Function(Pointer<Double>),
      int Function(Pointer<Double>)>('pw_camera_slot_exposure');

  static CameraSlotStats stats() {
    final Pointer<Int64> buf = calloc5();
    try {
      _stats(buf);
      return CameraSlotStats(
        offered: buf[0],
        displaced: buf[1],
        acquired: buf[2],
        released: buf[3],
        slotOccupied: buf[4] != 0,
      );
    } finally {
      _free(buf.cast());
    }
  }

  // ── 极小的分配助手 ────────────────────────────────────────────────────
  // 不引 package:ffi,免得为两个 buffer 加一个依赖。
  static final Pointer<Void> Function(int) _malloc = DynamicLibrary.process()
      .lookupFunction<Pointer<Void> Function(IntPtr), Pointer<Void> Function(int)>(
          'malloc');
  static final void Function(Pointer<Void>) _free = DynamicLibrary.process()
      .lookupFunction<Void Function(Pointer<Void>), void Function(Pointer<Void>)>(
          'free');

  static Pointer<Double> calloc4() => _malloc(8 * 4).cast<Double>();
  static Pointer<Int64> calloc5() => _malloc(8 * 5).cast<Int64>();
  static Pointer<Double> calloc8() => _malloc(8 * 8).cast<Double>();
}


/// 采集侧实际曝光参数。**只读诊断用**,不参与任何决策。
///
/// 🔴 判读要点(2026-09-19 为"bench 比系统相机暗"加的):
///   · `exposureSeconds` 若已经等于 `minFrameDurationSeconds`,说明曝光时间
///     **顶到了帧率给的硬上限** —— 想更亮只能降帧率,而降帧率会增加运动模糊。
///   · `iso` 顶满 + `targetOffsetEv` 明显为负 ⇒ 测光认为仍然欠曝,已无余量。
///   · `formatIsBinned=false` ⇒ 我们选的是非 binned 格式(单像素进光更少,
///     换取分辨率);这是 `PwCameraSlot.swift` 里显式的取舍。
class CameraExposure {
  const CameraExposure({
    required this.exposureSeconds,
    required this.iso,
    required this.aperture,
    required this.exposureMode,
    required this.targetOffsetEv,
    required this.formatIsBinned,
    required this.minFrameDurationSeconds,
    required this.maxFrameDurationSeconds,
  });

  final double exposureSeconds;
  final double iso;
  final double aperture;
  final int exposureMode;
  final double targetOffsetEv;
  final bool formatIsBinned;
  final double minFrameDurationSeconds;
  final double maxFrameDurationSeconds;

  /// 曝光是否已经顶到帧率给的上限(容差 5%)。
  bool get exposureClampedByFrameRate =>
      minFrameDurationSeconds > 0 &&
      exposureSeconds >= minFrameDurationSeconds * 0.95;

  String toDiagnosticString() => 'exp=${(exposureSeconds * 1000).toStringAsFixed(2)}ms '
      'iso=${iso.toStringAsFixed(0)} f/${aperture.toStringAsFixed(1)} '
      'mode=$exposureMode evOff=${targetOffsetEv.toStringAsFixed(2)} '
      'binned=$formatIsBinned '
      'minFrameDur=${(minFrameDurationSeconds * 1000).toStringAsFixed(2)}ms'
      '${exposureClampedByFrameRate ? ' **曝光已顶帧率上限**' : ''}';
}
