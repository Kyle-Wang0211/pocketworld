// vio_pose_source_runtime_flag.dart —— 位姿源开关的**第二来源**(运行期)。
//
// ══ 为什么要第二来源 ═══════════════════════════════════════════════════════
// `vio_pose_source_switch.dart` 的第一来源是 `--dart-define=PW_VIO_POSE_SOURCE`。
// 但 `lib/main.dart:183-192` 的注释是 2026-08-09 的真机实证:
// **`--dart-define` 到不了本工程的 iOS xcconfig 链** —— 后端地址正是因为这条
// 才改成运行期解析的。⇒ 出货 iOS 包里那个编译期常量**永远**是默认值,
// 这条自研臂在真机上**物理上打不开**。
//
// 本文件补那条路:读原生的 `pw_vio_pose_source`
// (`ios/Runner/PwZeroArkitGate.swift`),它从启动参数 / `NSArgumentDomain`
// 里取 `-PWVioPoseSource`。
//
// 真机打开方式(**不需要重新出包**):
//
//     xcrun devicectl device process launch --terminate-existing \
//       --device <UDID> com.kyle.PocketWorld -- -PWVioPoseSource xrslam
//
// ══ 🔴 三条不变量 ══════════════════════════════════════════════════════════
// 1. **默认仍然是关的。** 没传参数 ⇒ 空串 ⇒ arkit。符号不存在(模拟器 /
//    单测 / 安卓 / 没链进去)⇒ `null` ⇒ 当作没设,按第一来源走。
// 2. **只读一次。** 启动参数在进程生存期内不会变;每次 `current` 都去做一次
//    FFI + 分配是纯浪费,而且这个 getter 在采集页上会被高频调用。
//    缓存是**粘性**的,与 `EnginePosePoller` 的不可用闸同款理由。
// 3. **符号缺失是降级不是崩溃。** 整个解析与调用都包在 try 里,失败就永久
//    记为「没有第二来源」。09-19 栽过一次:一个缺失符号的异常打断了整条
//    渲染回路,表现成「卡住」而日志里什么都没有。

import 'dart:ffi';

typedef _ReadNative = Int32 Function(Pointer<Uint8>, Int32);
typedef _ReadDart = int Function(Pointer<Uint8>, int);
typedef _MallocNative = Pointer<Void> Function(IntPtr);
typedef _FreeNative = Void Function(Pointer<Void>);

/// 运行期位姿源开关的读取器。
abstract final class PwVioPoseSourceRuntimeFlag {
  /// 缓冲区容量。`xrslam` 6 字节,给到 64 足够放下任何合法值,
  /// 也足够让一个打错的长串**整串**回来被识别成「无法识别」而不是被截断。
  static const int _capacity = 64;

  static bool _read = false;
  static String? _cached;

  /// 仅供测试的覆盖。`null` = 不覆盖;传空串 = 模拟「符号在但没设值」。
  /// 生产代码**不要**写它。
  static String? debugOverrideRaw;

  /// 是否已经尝试读过(诊断用)。
  static bool get attempted => _read;

  /// 原生侧读到的原始字符串。
  ///
  /// * `null` —— 符号不存在 / 调用失败 / 容量不足 ⇒ **没有第二来源**;
  /// * `''`  —— 符号在,但没传 `-PWVioPoseSource` ⇒ 按没设处理;
  /// * 其它  —— 原样交给 `PwVioPoseSourceSwitch.parse`。
  static String? get raw {
    final String? override = debugOverrideRaw;
    if (override != null) return override;
    if (_read) return _cached;
    _read = true;
    _cached = _readFromNative();
    return _cached;
  }

  /// 重置缓存。**只给测试用。**
  static void debugReset() {
    _read = false;
    _cached = null;
    debugOverrideRaw = null;
  }

  static String? _readFromNative() {
    try {
      final DynamicLibrary lib = DynamicLibrary.process();
      final _ReadDart read =
          lib.lookupFunction<_ReadNative, _ReadDart>('pw_vio_pose_source');
      final Pointer<Void> Function(int) malloc =
          lib.lookupFunction<_MallocNative, Pointer<Void> Function(int)>(
              'malloc');
      final void Function(Pointer<Void>) free =
          lib.lookupFunction<_FreeNative, void Function(Pointer<Void>)>('free');

      final Pointer<Uint8> buf = malloc(_capacity).cast<Uint8>();
      try {
        final int n = read(buf, _capacity);
        // 🔴 −1 = 原生侧认为容量不够。它**不截断**(截断会把 "xrslam" 变成
        //    "xrsl" 然后被静默当成无法识别的值)。当作没有第二来源。
        if (n < 0) return null;
        final List<int> bytes = <int>[for (int i = 0; i < n; i++) buf[i]];
        return String.fromCharCodes(bytes);
      } finally {
        free(buf.cast<Void>());
      }
    } catch (_) {
      // 符号不在(单测 / 模拟器 / 安卓 / dead-strip)⇒ 永久判定为没有第二来源。
      return null;
    }
  }
}
