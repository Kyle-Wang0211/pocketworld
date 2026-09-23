// bench_replay_native.dart —— 台架回放的 dart:ffi 绑定(`ios/Runner/PwBenchReplay.swift`
// 的五个 `@_cdecl`)。
//
// 只给台架(arloopbench)用;生产里**没有 import 者**(与
// `lib/vio/render/zero_arkit_capture_probe_page.dart` 同一处境),生产二进制里也没有
// 这几个符号 —— [BenchReplayNative.process] 找不到就返回 null,不抛。
//
// 形状抄 `lib/vio/ffi/xrslam_live_ffi.dart`:`lookupFunction` + calloc 出参缓冲。
// 不同之处只有一条:库**可注入**。iOS 上是 `DynamicLibrary.process()`(与 XrslamLive
// 同一个);Mac 等价核对(tool/bench/replay_mac/)在 flutter test 里用
// `DynamicLibrary.open(<Mac 上编的同一批源文件>)`。
//
// 所有出参是 UTF-8 JSON。缓冲不够时原生返回 −需要的字节数、不截断,这里按需扩容重取。

import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

typedef _OutJsonNative = ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Int32);
typedef _OutJsonDart = int Function(ffi.Pointer<ffi.Char>, int);
typedef _InspectNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, ffi.Int32);
typedef _InspectDart = int Function(
    ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, int);
typedef _StartNative = ffi.Int32 Function(ffi.Pointer<ffi.Char>);
typedef _StartDart = int Function(ffi.Pointer<ffi.Char>);
typedef _VoidNative = ffi.Void Function();
typedef _VoidDart = void Function();

/// 五个原生入口。构造失败(符号不在)⇒ [BenchReplayNative.tryOpen] 返回 null。
class BenchReplayNative {
  BenchReplayNative._(ffi.DynamicLibrary lib)
      : _launchArgs = lib.lookupFunction<_OutJsonNative, _OutJsonDart>(
            'pw_bench_replay_launch_args'),
        _inspect = lib.lookupFunction<_InspectNative, _InspectDart>(
            'pw_bench_replay_inspect'),
        _start = lib
            .lookupFunction<_StartNative, _StartDart>('pw_bench_replay_start'),
        _status = lib.lookupFunction<_OutJsonNative, _OutJsonDart>(
            'pw_bench_replay_status'),
        _cancel =
            lib.lookupFunction<_VoidNative, _VoidDart>('pw_bench_replay_cancel');

  final _OutJsonDart _launchArgs;
  final _InspectDart _inspect;
  final _StartDart _start;
  final _OutJsonDart _status;
  final _VoidDart _cancel;

  /// 任一符号找不到 ⇒ null(台架旧包 / 生产包)。
  static BenchReplayNative? tryOpen(ffi.DynamicLibrary lib) {
    try {
      return BenchReplayNative._(lib);
    } catch (_) {
      return null;
    }
  }

  /// iOS 台架:与 `XrslamLive` 同一个 `DynamicLibrary.process()`。
  static BenchReplayNative? process() =>
      tryOpen(ffi.DynamicLibrary.process());

  static Map<String, Object?> _decode(String s) {
    final Object? o = jsonDecode(s);
    return o is Map<String, Object?> ? o : <String, Object?>{};
  }

  /// 按需扩容地取一段 JSON。
  static String _readJson(int Function(ffi.Pointer<ffi.Char>, int) call) {
    int cap = 64 * 1024;
    for (int attempt = 0; attempt < 4; attempt++) {
      final ffi.Pointer<ffi.Char> buf = calloc<ffi.Char>(cap);
      try {
        final int n = call(buf, cap);
        if (n >= 0) return buf.cast<Utf8>().toDartString(length: n);
        cap = -n + 1024;
      } finally {
        calloc.free(buf);
      }
    }
    return '{}';
  }

  /// 本进程的台架回放启动参数(原生按 NSArgumentDomain + argv 读,
  /// 读法与 `-PWPerFrameIntrinsics` 同一段,见 PwBenchReplay.swift)。
  Map<String, Object?> launchArgs() => _decode(_readJson(_launchArgs));

  /// 只读地装载一次录制(不开会话)。`ok == false` 时带 `error`。
  Map<String, Object?> inspect(String recordingDir) {
    final ffi.Pointer<Utf8> dir = recordingDir.toNativeUtf8();
    try {
      return _decode(_readJson((b, c) => _inspect(dir.cast(), b, c)));
    } finally {
      calloc.free(dir);
    }
  }

  /// 0 已开跑;-1 正在跑;-2 配置不对。
  int start(Map<String, Object?> config) {
    final ffi.Pointer<Utf8> s = jsonEncode(config).toNativeUtf8();
    try {
      return _start(s.cast());
    } finally {
      calloc.free(s);
    }
  }

  /// `phase`:idle / loading / running / draining / writing / done / failed。
  /// done 时带 `summary`(原生汇总,同 replay_native_summary.json)。
  Map<String, Object?> status() => _decode(_readJson(_status));

  void cancel() => _cancel();
}
