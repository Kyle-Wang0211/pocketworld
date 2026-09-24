// Judges for lib/point_cloud_lod/lod_jobs.dart (plan L6 build + self-check, plan M1 run)
// over a mocked channel and a temp "Documents". Each verdict has a negative control.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/point_cloud_lod/lod_bridge.dart';
import 'package:pocketworld_flutter/point_cloud_lod/lod_jobs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(kPwLodChannel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late Directory docs;
  late Directory cap;

  const ply = 36232793;
  Map<String, Object> buildReply({
    String status = 'PWLOD_OK',
    int tree = ply,
    int? bytes,
  }) => {
    'status': status,
    'error': status == 'PWLOD_OK' ? '' : 'boom',
    'ply_points': ply,
    'tree_points': tree,
    'octree_bin_bytes': bytes ?? 18 * tree,
    'nodes': 12000,
    'elapsed_ms': 24300.0,
    'shell_wall_ms': 24310.0,
    'peak_footprint_mb': 519.0,
    'baseline_footprint_mb': 80.0,
    'footprint_samples': 2431,
    'chunk_dir_removed': true,
  };
  Map<String, Object> verifyReply({int tree = ply, int gaps = 0}) => {
    'status': 'PWLOD_OK',
    'tree_points': tree,
    'octree_bin_bytes': 18 * tree,
    'nodes': 12000,
    'leaves': 9000,
    'leaves_selected': 9000,
    'byte_gaps': gaps,
    'byte_overlaps': 0,
  };
  late Map<String, Object> nextBuild;
  late Map<String, Object> nextVerify;

  setUp(() {
    calls.clear();
    docs = Directory.systemTemp.createTempSync('lod_jobs_docs');
    cap = Directory('${docs.path}/scan1')..createSync();
    File('${cap.path}/a_other.ply').writeAsStringSync('ply other');
    File('${cap.path}/official_dense.ply').writeAsStringSync('ply dense');
    nextBuild = buildReply();
    nextVerify = verifyReply();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      switch (call.method) {
        case 'buildFromPly':
          return nextBuild;
        case 'verifyOctree':
          return nextVerify;
        case 'runBench':
          final a = call.arguments as Map;
          final out = '${a['out_dir']}/lod_x.json';
          File(out).writeAsStringSync('{}');
          return {
            'result': out,
            'result_is_file': true,
            'wall_ms': 61000.0,
            'probe_start': {
              'thermal_state': 0,
              'footprint_mb': 90.0,
              'avail_mb': 3000.0,
            },
            'probe_end': {
              'thermal_state': 1,
              'footprint_mb': 400.0,
              'avail_mb': 2600.0,
            },
            'version': 'deadbeef abi=1',
          };
      }
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    docs.deleteSync(recursive: true);
  });

  test('findCapturePly prefers official_dense.ply, else the first *.ply', () {
    expect(findCapturePly(cap)!.path, endsWith('/official_dense.ply'));
    File('${cap.path}/official_dense.ply').deleteSync();
    expect(findCapturePly(cap)!.path, endsWith('/a_other.ply'));
    File('${cap.path}/a_other.ply').deleteSync();
    expect(findCapturePly(cap), isNull);
  });

  test('build + verify: paths, all checks pass, receipt written', () async {
    final r = await buildAndVerify(
      bridge: LodBridge(),
      captureDir: cap,
      threads: 4,
    );
    expect(r.pass, isTrue);
    expect(r.checks.map((c) => c.name), ['C1', 'C2', 'S2', 'build==verify']);
    final a = calls.first.arguments as Map;
    expect(a['ply_path'], '${cap.path}/official_dense.ply');
    expect(a['out_dir'], '${cap.path}/lod');
    expect(a['chunk_dir'], '${cap.path}/lod_chunks_tmp');
    expect(a['threads'], 4);
    expect(calls[1].method, 'verifyOctree');
    expect((calls[1].arguments as Map)['octree_dir'], '${cap.path}/lod');
    final j =
        jsonDecode(
              File('${cap.path}/lod_build_receipt.json').readAsStringSync(),
            )
            as Map;
    expect(j['pass'], isTrue);
    expect((j['build'] as Map)['peak_footprint_mb'], 519.0);
    expect((j['checks'] as List).length, 4);
  });

  test('NEGATIVE: one lost point fails C1 and the receipt says so', () async {
    nextBuild = buildReply(tree: ply - 1);
    nextVerify = verifyReply(tree: ply - 1);
    final r = await buildAndVerify(bridge: LodBridge(), captureDir: cap);
    expect(r.pass, isFalse);
    expect(r.checks.firstWhere((c) => c.name == 'C1').pass, isFalse);
    final j =
        jsonDecode(
              File('${cap.path}/lod_build_receipt.json').readAsStringSync(),
            )
            as Map;
    expect(j['pass'], isFalse);
  });

  test('NEGATIVE: a byte gap fails C2 even when C1 holds', () async {
    nextVerify = verifyReply(gaps: 18);
    final r = await buildAndVerify(bridge: LodBridge(), captureDir: cap);
    expect(r.checks.firstWhere((c) => c.name == 'C1').pass, isTrue);
    expect(r.checks.firstWhere((c) => c.name == 'C2').pass, isFalse);
    expect(r.pass, isFalse);
  });

  test('NEGATIVE: a failed build is not verified and does not pass', () async {
    nextBuild = buildReply(status: 'PWLOD_ERR_FORMAT', tree: 0);
    final r = await buildAndVerify(bridge: LodBridge(), captureDir: cap);
    expect(r.pass, isFalse);
    expect(r.verify, isNull);
    expect(calls.map((c) => c.method), ['buildFromPly']);
  });

  test('an existing lod/ is never overwritten silently', () async {
    Directory('${cap.path}/lod').createSync();
    File('${cap.path}/lod/octree.bin').writeAsStringSync('old');
    await expectLater(
      buildAndVerify(bridge: LodBridge(), captureDir: cap),
      throwsA(isA<StateError>()),
    );
    expect(File('${cap.path}/lod/octree.bin').existsSync(), isTrue);
    expect(calls, isEmpty);
    await buildAndVerify(bridge: LodBridge(), captureDir: cap, rebuild: true);
    expect(
      File('${cap.path}/lod/octree.bin').existsSync(),
      isFalse,
    ); // removed before rebuild
    expect(calls.first.method, 'buildFromPly');
  });

  test(
    'M1: out dir under Documents/lod_bench, tag appended, receipt next to result',
    () async {
      final oct = Directory('${cap.path}/lod')..createSync();
      final r = await runM1(
        bridge: LodBridge(),
        octreeDir: oct,
        documentsDir: docs,
        args: 'mode=perf frames=900 rounds=3',
        tag: 'a16',
        clock: () => DateTime(2026, 9, 24, 10, 30, 5),
      );
      expect(r.outDir.path, '${docs.path}/lod_bench/a16_20260924_103005');
      final a = calls.single.arguments as Map;
      expect(a['args'], 'mode=perf frames=900 rounds=3 tag=a16');
      expect(a['octree_dir'], oct.path);
      final j = jsonDecode(r.receipt.readAsStringSync()) as Map;
      expect(j['pwlod_run_result_is_file'], isTrue);
      expect((j['probe_end'] as Map)['thermal_state'], 1);
      expect(File(j['pwlod_run_result'] as String).existsSync(), isTrue);
    },
  );
}
