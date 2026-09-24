import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/point_cloud_lod/dense_lod_cache.dart';

import 'point_cloud_lod/fake_lod_platform.dart';

/// Product rule CLAUDE.md:14 (user 2026-09-24): 「全量存盘、任一点拉近可见」. The shown tree must
/// hold every PLY point on disk and every leaf must be reachable; otherwise it is not shown.
/// Judged on the files, not on the builder's own report: points on disk = octree.bin / 18
/// compared with the PLY header this test reads itself.
({bool shown, int? diskPoints}) judgeShownTree(DenseLodState s, int plyPoints) {
  if (s.phase != DenseLodPhase.ready) return (shown: false, diskPoints: null);
  final bin = File('${s.octreeDir}/octree.bin');
  final disk = bin.lengthSync() ~/ 18;
  expect(bin.lengthSync() % 18, 0);
  expect(disk, greaterThanOrEqualTo(plyPoints), reason: '盘上点数少于 PLY');
  return (shown: true, diskPoints: disk);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CLAUDE.md:14 全量存盘、任一点拉近可见', () {
    late Directory tmp;
    late FakeLodPlatform fake;
    late String ply;
    late String plySha;
    const n = 4096;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('contract_lod');
      ply = writeDensePly('${tmp.path}/Documents/captures_official/cap_c/official_dense.ply', n).path;
      plySha = sha256.convert(File(ply).readAsBytesSync()).toString();
      fake = FakeLodPlatform()..install();
    });
    tearDown(() {
      FakeLodPlatform.uninstall();
      tmp.deleteSync(recursive: true);
    });

    Future<DenseLodState> run(String root) async {
      final c = DenseLodCache(cacheRoot: () async => Directory('${tmp.path}/$root'));
      final s = c.watch(ply);
      await c.whenIdle();
      return s.value;
    }

    test('the rule is written down, and the old wording is gone', () {
      final line = File('CLAUDE.md').readAsStringSync().split('\n')[13];
      expect(line, contains('全量存盘、任一点拉近可见'));
      expect(line, contains('C1'));
      expect(line, contains('S2'));
      // NEGATIVE: the superseded rule is not what line 14 says any more
      expect(line.startsWith('- 点云**全量交付**,不为展示降采样。'), isFalse);
    });

    test('a complete tree is shown: every PLY point is on disk, every leaf reachable, the PLY untouched', () async {
      final s = await run('ok');
      final j = judgeShownTree(s, n);
      expect(j.shown, isTrue, reason: '$s');
      expect(j.diskPoints, n);
      expect(sha256.convert(File(ply).readAsBytesSync()).toString(), plySha, reason: 'PLY rewritten');
    });

    test('NEGATIVE: a tree one point short is never shown', () async {
      fake.buildLosesPoints = 1;
      final s = await run('short');
      expect(judgeShownTree(s, n).shown, isFalse);
      expect(Directory('${tmp.path}/short/cap_c').existsSync(), isFalse);
    });

    test('NEGATIVE: a tree with an unreachable leaf is never shown', () async {
      fake.verifyUnreachableLeaves = 1;
      final s = await run('leaf');
      expect(judgeShownTree(s, n).shown, isFalse);
    });

    test('NEGATIVE: the disk judge itself catches a short octree.bin', () async {
      final s = await run('disk');
      final bin = File('${s.octreeDir}/octree.bin');
      bin.writeAsBytesSync(bin.readAsBytesSync().sublist(18));
      expect(() => judgeShownTree(s, n), throwsA(isA<TestFailure>()));
    });
  });

  test('Review renders the complete persisted point set', () {
    final source = File(
      'lib/ui/official_capture/sparse_cloud_view.dart',
    ).readAsStringSync();

    expect(source, contains('ReviewPointCloudPolicy.drawStrideFor(n)'));
    expect(source, isNot(contains('_maxDrawnPoints')));
  });

  test(
    'Capture sends a progressive display copy and keeps SfM source intact',
    () {
      final source = File(
        'lib/ui/official_capture/ar_capture_page.dart',
      ).readAsStringSync();

      expect(source, contains('buildProgressivePointCloud'));
      expect(source, contains('snapshot.xyz'));
      expect(
        source,
        contains(
          'display-only: the source SfM snapshot and final PLY stay intact',
        ),
      );
    },
  );

  test(
    'iOS Capture renderer owns full buffers and only draws stable prefixes',
    () {
      final source = File(
        'ios/Runner/OfficialAetherARKitPlugin.swift',
      ).readAsStringSync();

      expect(source, contains('CapturePointCloudLodController'));
      expect(source, contains('fullPointCloudXyz'));
      expect(source, contains('fullPointCloudRgb'));
      expect(source, contains('prefix(renderCount * 3)'));
      expect(source, contains('ProcessInfo.processInfo.thermalState'));
      expect(source, contains('pointCloudLod.observeFrame'));
    },
  );
}
