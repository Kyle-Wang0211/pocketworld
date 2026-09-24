// bench_lidar_native.dart —— 台架「LiDAR 米尺录制」页的 dart:ffi 绑定
// (`ios/Runner/PwBenchLidarSession.swift` 的五个 `@_cdecl`;第五个 reexport 是 2026-09-24 rec30 加的、可缺)。
//
// 🔴 bench-only ruler:LiDAR 深度只在台架里当研发期米尺,永不进产品代码、产品管线、产品提案。
// 本目录(lib/bench_lidar/)只由 arloopbench 的 main.dart 在
// `--dart-define=PW_LIDAR_RULER_BENCH=true`(const 分支)时引用;不带这个 define 的包里整页被树摇掉。
// 生产里**没有 import 者**,生产二进制里也没有这几个符号 —— [BenchLidarNative.process] 找不到就返回
// null,不抛。
//
// 形状逐字抄 `lib/vio/replay/bench_replay_native.dart`:`lookupFunction` + calloc 出参缓冲,
// 原生缓冲不够时返回 −需要的字节数、不截断,这里按需扩容重取。

import 'dart:convert';
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

typedef _OutJsonNative = ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Int32);
typedef _OutJsonDart = int Function(ffi.Pointer<ffi.Char>, int);
typedef _StartNative = ffi.Int32 Function(ffi.Pointer<ffi.Char>);
typedef _StartDart = int Function(ffi.Pointer<ffi.Char>);
typedef _VoidNative = ffi.Void Function();
typedef _VoidDart = void Function();

class BenchLidarNative {
  BenchLidarNative._(ffi.DynamicLibrary lib)
      : _capability = lib.lookupFunction<_OutJsonNative, _OutJsonDart>(
            'pw_bench_lidar_capability'),
        _start =
            lib.lookupFunction<_StartNative, _StartDart>('pw_bench_lidar_start'),
        _stop = lib.lookupFunction<_VoidNative, _VoidDart>('pw_bench_lidar_stop'),
        _status = lib.lookupFunction<_OutJsonNative, _OutJsonDart>(
            'pw_bench_lidar_status'),
        _reexport = _tryLookupStart(lib, 'pw_bench_lidar_reexport_subset');

  final _OutJsonDart _capability;
  final _StartDart _start;
  final _VoidDart _stop;
  final _OutJsonDart _status;
  // [2026-09-24 rec30] 可选:老包没有这个符号 ⇒ null,整页照常可用。
  final _StartDart? _reexport;

  static _StartDart? _tryLookupStart(ffi.DynamicLibrary lib, String name) {
    try {
      return lib.lookupFunction<_StartNative, _StartDart>(name);
    } catch (_) {
      return null;
    }
  }

  static BenchLidarNative? tryOpen(ffi.DynamicLibrary lib) {
    try {
      return BenchLidarNative._(lib);
    } catch (_) {
      return null;
    }
  }

  static BenchLidarNative? process() => tryOpen(ffi.DynamicLibrary.process());

  static Map<String, Object?> _decode(String s) {
    final Object? o = jsonDecode(s);
    return o is Map<String, Object?> ? o : <String, Object?>{};
  }

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

  /// 不开会话:是否支持 sceneDepth、相机权限、机型、剩余空间。
  Map<String, Object?> capability() => _decode(_readJson(_capability));

  /// 0 已开录;-1 正在录;-2 配置不对;-3 设备/权限不支持;-4 空间不足(`status()['error']` 有原因)。
  int start(Map<String, Object?> config) {
    final ffi.Pointer<Utf8> s = jsonEncode(config).toNativeUtf8();
    try {
      return _start(s.cast());
    } finally {
      calloc.free(s);
    }
  }

  void stop() => _stop();

  /// [2026-09-24 rec30] 给已有录制重导尺子子集(只挑 XRSLAM 回放会收的帧,录制本身不动)。
  /// 0 已开跑;-1 正忙;-2 配置不对;-9 这个包没有该符号。进度 / 结果走 [status]。
  int reexportSubset(Map<String, Object?> config) {
    final _StartDart? f = _reexport;
    if (f == null) return -9;
    final ffi.Pointer<Utf8> s = jsonEncode(config).toNativeUtf8();
    try {
      return f(s.cast());
    } finally {
      calloc.free(s);
    }
  }

  /// `phase`:idle / starting / recording / stopping / exporting / done / failed。
  /// done 时带 `result`(manifest 摘要 + timing + 子集导出摘要)。
  Map<String, Object?> status() => _decode(_readJson(_status));
}
