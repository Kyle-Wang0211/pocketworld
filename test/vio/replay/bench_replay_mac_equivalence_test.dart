// Mac 等价核对的 Dart 那一半:用 DynamicLibrary.open() 装上
// tool/bench/replay_mac/build_mac_harness.sh 编出的 macOS 动态库(**同一批**原生源文件),
// 按台架回放页的同一条路(BenchReplayController:启动参数 → 选录制 → 产品 yaml 生成器 →
// 原生回放 → 回执)跑一场,把输出目录写到 PW_BENCH_REPLAY_RESULT 指定的文件里。
// 与 Mac 宿主回放的逐行比对在 tool/bench/replay_mac/mac_equivalence.sh 里做。
//
// 没设 PW_BENCH_REPLAY_MAC_DYLIB 就跳过(普通 `flutter test` 不受影响)。
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/replay/bench_replay_controller.dart';
import 'package:pocketworld_flutter/vio/replay/bench_replay_native.dart';

typedef _SetArgNative = ffi.Void Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>);
typedef _SetArgDart = void Function(ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>);

void main() {
  final Map<String, String> env = Platform.environment;
  final String? dylib = env['PW_BENCH_REPLAY_MAC_DYLIB'];

  test('Mac:Dart 编排 + 原生回放(同源文件)跑完一场并写回执', () async {
    final ffi.DynamicLibrary lib = ffi.DynamicLibrary.open(dylib!);
    // 等价于 iOS 上 `devicectl … -- -PWPerFrameIntrinsics off -PWBenchReplayRecording …`:
    // 写进 NSArgumentDomain,必须在原生第一次读开关之前。
    final _SetArgDart setArg = lib.lookupFunction<_SetArgNative, _SetArgDart>(
        'pw_bench_replay_mac_set_argument');
    void arg(String k, String v) {
      final ffi.Pointer<Utf8> a = k.toNativeUtf8();
      final ffi.Pointer<Utf8> b = v.toNativeUtf8();
      setArg(a.cast(), b.cast());
      calloc.free(a);
      calloc.free(b);
    }

    arg('PWPerFrameIntrinsics', env['PW_BENCH_REPLAY_PFK'] ?? 'on');
    arg('PWBenchReplayRecording', env['PW_BENCH_REPLAY_RECORDING']!);
    arg('PWBenchReplayPace', env['PW_BENCH_REPLAY_PACE'] ?? 'max');
    arg('PWBenchReplayLimitFrames', env['PW_BENCH_REPLAY_LIMIT'] ?? '0');
    arg('PWBenchReplayIgnoreExposure', env['PW_BENCH_REPLAY_IGNORE_EXPOSURE'] ?? 'off');
    if (env['PW_BENCH_REPLAY_C_MS'] != null) {
      arg('PWBenchReplayCameraTimeOffsetMs', env['PW_BENCH_REPLAY_C_MS']!);
    }
    arg('PWBenchReplayTag', env['PW_BENCH_REPLAY_TAG'] ?? 'mac');

    final BenchReplayNative native = BenchReplayNative.tryOpen(lib)!;
    final BenchReplayController c = BenchReplayController(
      native: native,
      documents: Directory(env['PW_BENCH_REPLAY_DOCS']!),
      pollInterval: const Duration(milliseconds: 100),
    );
    final BenchReplayArgs args = c.launchArgs();
    expect(args.problems, isEmpty);
    final List<BenchReplayRecording> recs = c.listRecordings();
    final BenchReplayRecording? r =
        BenchReplayController.resolve(recs, args.recording!);
    expect(r, isNotNull, reason: recs.map((BenchReplayRecording x) => x.describe()).join('\n'));
    final BenchReplayResult res = await c.run(c.plan(r!, args));
    File(env['PW_BENCH_REPLAY_RESULT']!).writeAsStringSync(res.runDir.path);
    expect(res.receipt['phase'], 'done', reason: '${res.error}');
    expect(res.ok, isTrue, reason: '${res.receipt['invariants']}');
  }, skip: dylib == null ? '没设 PW_BENCH_REPLAY_MAC_DYLIB(Mac 等价核对专用)' : false,
      timeout: const Timeout(Duration(minutes: 30)));
}
