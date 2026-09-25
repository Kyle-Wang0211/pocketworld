// zero_arkit_camera_gate.dart —— `ios/Runner/PwZeroArkitGate.swift` 的 Dart 绑定。
//
// 为什么不直接调 `PwCameraSlot.start`:那个入口**不经过 `PwARCameraLease`**
// (`PwCameraSlot.swift:49` 自己写着)。iOS 把后置相机只给一个会话,ARKit
// 在跑时再开一个 `AVCaptureSession` ⇒ `FigCaptureSourceRemote err=-17281`,
// **两条路一起废**。所以自研臂走这条带租约的入口:拿不到锁就**失败关闭**,
// 不去抢。
//
// 🔴 这同时是这条臂的**运行期自证**(09-20 的教训:换臂实验必须能在运行期
// 证明跑的是哪条臂)。[ZeroArkitCameraGate.ownedBySelfVio] 回答「相机现在
// 在谁手里」,不用靠日志猜。
//
// 🔴 本文件**不改** `camera_slot_ffi.dart` —— 那是照片接口那条分支的文件。

import 'dart:ffi';

import 'camera_slot_ffi.dart';

/// `pw_zero_arkit_camera_start` 在**相机被别人占着**时的返回码。
/// 与 `PwZeroArkitGate.swift` 里的 `-100` 一一对应。
const int kZeroArkitCameraBusy = -100;

/// 符号不存在(模拟器 / 单测 / 安卓 / dead-strip)时 [ZeroArkitCameraGate.start]
/// 的返回码。**与 −100 分开** —— 「没链进去」和「被 ARKit 占着」是两件完全
/// 不同的事,混成一个码会让真机排查走岔。
const int kZeroArkitCameraSymbolMissing = -101;

typedef _StartNative = Int32 Function(Int32, Int32, Double, Double);
typedef _StartDart = int Function(int, int, double, double);
typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();
typedef _OwnedNative = Int32 Function();
typedef _OwnedDart = int Function();

abstract final class ZeroArkitCameraGate {
  /// 仅供测试的注入点。`null` = 走真符号。
  static int Function(int, int, double, double)? debugStart;
  static void Function()? debugStop;
  static int Function()? debugOwned;

  static bool _gaveUp = false;

  /// 为什么不可用(诊断用)。
  static Object? get unavailableReason => _reason;
  static Object? _reason;

  /// 起相机(先拿租约)。返回码见文件头与 [kZeroArkitCameraBusy]。
  static int start({
    required int width,
    required int height,
    required double fps,
    required double lensPosition,
  }) {
    final injected = debugStart;
    if (injected != null) return injected(width, height, fps, lensPosition);
    if (_gaveUp) return kZeroArkitCameraSymbolMissing;
    // [ENTRY-ANY-4X3 2026-09-25] 照片取本格式支持的最大 4:3(规则在 Dart,宿主只查)。
    // 必须在起相机之前预设;符号不在时内部静默跳过,不影响起相机。
    PwCameraSlot.requestLargestFourByThreePhoto(width: width, height: height);
    try {
      return _start(width, height, fps, lensPosition);
    } catch (e) {
      _gaveUp = true;
      _reason = e;
      return kZeroArkitCameraSymbolMissing;
    }
  }

  /// 停相机并还租约。**幂等**,失败静默(停不下来时没有更好的补救)。
  static void stop() {
    final injected = debugStop;
    if (injected != null) {
      injected();
      return;
    }
    if (_gaveUp) return;
    try {
      _stop();
    } catch (e) {
      _gaveUp = true;
      _reason = e;
    }
  }

  /// 相机是不是在自研臂名下。符号不在时返回 `false`(**不是** true)——
  /// 拿不到证据就不宣称拥有。
  static bool ownedBySelfVio() {
    final injected = debugOwned;
    if (injected != null) return injected() == 1;
    if (_gaveUp) return false;
    try {
      return _owned() == 1;
    } catch (e) {
      _gaveUp = true;
      _reason = e;
      return false;
    }
  }

  /// 重置粘性闸与注入点。**只给测试用。**
  static void debugReset() {
    debugStart = null;
    debugStop = null;
    debugOwned = null;
    _gaveUp = false;
    _reason = null;
  }

  static final DynamicLibrary _lib = DynamicLibrary.process();

  static final _StartDart _start = _lib
      .lookupFunction<_StartNative, _StartDart>('pw_zero_arkit_camera_start');
  static final _VoidDart _stop = _lib
      .lookupFunction<_VoidNative, _VoidDart>('pw_zero_arkit_camera_stop');
  static final _OwnedDart _owned = _lib
      .lookupFunction<_OwnedNative, _OwnedDart>('pw_zero_arkit_camera_owned');
}
