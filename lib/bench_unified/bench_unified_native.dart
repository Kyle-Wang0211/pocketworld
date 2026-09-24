// bench_unified_native.dart — Dart side of channel 'pw_bench_unified'
// (ios/Runner/PwBenchUnifiedPlugin.swift). Bench-only (arloopbench); never used by production.

import 'package:flutter/services.dart';

class BenchUnifiedNative {
  BenchUnifiedNative._();

  static const MethodChannel _ch = MethodChannel('pw_bench_unified');

  static Map<String, String>? _launchArgs;

  /// Every `-PW<Key> <value>` pair of this launch, key without the dash. Cached per process.
  static Future<Map<String, String>> launchArgs() async {
    final cached = _launchArgs;
    if (cached != null) return cached;
    try {
      final raw = await _ch.invokeMapMethod<String, String>('launchArgs');
      return _launchArgs = raw ?? const <String, String>{};
    } on MissingPluginException {
      return _launchArgs = const <String, String>{};
    }
  }

  /// Registers production 168's Runner plugins on this engine (idempotent).
  static Future<bool> enterFullChain() async =>
      (await _ch.invokeMethod<bool>('enterFullChain')) ?? false;

  static Future<Map<String, Object?>> vioKitStatus() async {
    try {
      return (await _ch.invokeMapMethod<String, Object?>('vioKitStatus')) ??
          const <String, Object?>{};
    } on MissingPluginException {
      return const <String, Object?>{'present': false};
    }
  }

  /// Presents the old VIO Replacement Bench harness full screen (native SwiftUI).
  static Future<void> openVioKit() => _ch.invokeMethod<bool>('openVioKit');

  /// Starts one PWSplatAB run. false = a run is already in progress.
  static Future<bool> splatStart(Map<String, String> params) async =>
      (await _ch.invokeMethod<bool>('splatStart', params)) ?? false;

  static Future<Map<String, Object?>> splatStatus() async =>
      (await _ch.invokeMapMethod<String, Object?>('splatStatus')) ??
      const <String, Object?>{};
}
