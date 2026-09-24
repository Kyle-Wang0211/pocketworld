// DenseLodCache (build 174): the finished dense cloud's octree in <作品目录>/lod/, found by its place
// relative to the work directory, gated by C1/C2/S2, migrated once from the 171–173 cache place, and
// never built from a dense PLY that is cut short. Every positive has a negative control through the
// same judge.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/point_cloud_lod/dense_lod_cache.dart';

import 'fake_lod_platform.dart';

/// Waits for the cache's queue (every check/build started so far), then reads the state.
Future<DenseLodState> settleOn(DenseLodCache c, ValueListenable<DenseLodState> s) async {
  await c.whenIdle();
  return s.value;
}

const String kCap = 'cap_1789381704918369';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp, work, caches;
  late FakeLodPlatform fake;
  late DenseLodCache lod;
  late String ply;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dense_lod_cache');
    work = Directory('${tmp.path}/Documents/captures_official/$kCap')..createSync(recursive: true);
    caches = Directory('${tmp.path}/Library/Caches')..createSync(recursive: true);
    ply = writeDensePly('${work.path}/official_dense.ply', 5000).path;
    File('${work.path}/official_sfm_sparse.ply').writeAsStringSync('sparse');
    fake = FakeLodPlatform()..install();
    lod = DenseLodCache(cacheRoot: () async => caches);
  });
  tearDown(() {
    FakeLodPlatform.uninstall();
    tmp.deleteSync(recursive: true);
  });

  List<String> names(Directory d) => [for (final e in d.listSync()) e.path.split('/').last]..sort();

  test('builds into <作品目录>/lod.building, renamed to lod/ after its self-check; scratch in the cache', () async {
    final s = await settleOn(lod, lod.watch(ply));
    expect(s.phase, DenseLodPhase.ready, reason: '$s');
    expect(s.octreeDir, '${work.path}/lod');
    expect(fake.methods, ['buildFromPly', 'verifyOctree']);
    final build = fake.of('buildFromPly').single.arguments as Map;
    expect(build['out_dir'], '${work.path}/lod.building');
    expect(build['chunk_dir'], '${caches.path}/lod_chunks/$kCap');
    expect(Directory(build['chunk_dir'] as String).existsSync(), isFalse);
    // the work directory holds its PLYs and the tree — nothing else was added
    expect(names(work), ['lod', 'official_dense.ply', 'official_sfm_sparse.ply']);
    expect(names(Directory(s.octreeDir!)), ['hierarchy.bin', 'metadata.json', 'octree.bin', 'pw_lod_source.json']);
    // the stamp is a small record, with no path in it (nothing absolute to go stale)
    final stampText = File('${s.octreeDir}/pw_lod_source.json').readAsStringSync();
    final stamp = jsonDecode(stampText) as Map;
    expect(stamp['schema'], 'pw_lod_source/2');
    expect(stamp['engine'], '72ee817f abi=3');
    expect(stamp['points'], 5000);
    expect((stamp['checks'] as List).every((c) => (c as Map)['pass'] == true), isTrue);
    expect(stampText.contains(tmp.path), isFalse);
    expect(stampText.contains('Documents'), isFalse);
  });

  test('the stamp never decides: a tree without it is still valid (the rule is files + sizes)', () async {
    final s = await settleOn(lod, lod.watch(ply));
    File('${s.octreeDir}/pw_lod_source.json').deleteSync();
    expect(await DenseLodCache(cacheRoot: () async => caches).findValid(ply), '${work.path}/lod');
  });

  test('C1: one point short ⇒ no tree, flat display stays; the half-built lod.building is removed', () async {
    fake.buildLosesPoints = 1;
    final s = await settleOn(lod, lod.watch(ply));
    expect(s.phase, DenseLodPhase.failed);
    expect(s.message, contains('C1'));
    expect(fake.methods, ['buildFromPly']); // verify is not even run
    expect(names(work), ['official_dense.ply', 'official_sfm_sparse.ply']);
    // NEGATIVE control of the judge: the same PLY with a faithful build passes
    final ok = DenseLodCache(cacheRoot: () async => caches);
    fake.buildLosesPoints = 0;
    expect((await settleOn(ok, ok.watch(ply))).phase, DenseLodPhase.ready);
  });

  test('S2: an unreachable leaf ⇒ no tree', () async {
    fake.verifyUnreachableLeaves = 1;
    final s = await settleOn(lod, lod.watch(ply));
    expect(s.phase, DenseLodPhase.failed);
    expect(s.message, contains('S2'));
    expect(Directory('${work.path}/lod').existsSync(), isFalse);
    expect(Directory('${work.path}/lod.building').existsSync(), isFalse);
  });

  test('a failed PLY is not rebuilt on every visit; a changed PLY is', () async {
    fake.buildLosesPoints = 1;
    expect((await settleOn(lod, lod.watch(ply))).phase, DenseLodPhase.failed);
    fake.calls.clear();
    fake.buildLosesPoints = 0;
    lod.watch(ply);
    expect((await settleOn(lod, lod.watch(ply))).phase, DenseLodPhase.failed);
    expect(fake.methods, isEmpty);
    writeDensePly(ply, 5001, seed: 2);
    final s = await settleOn(lod, lod.watch(ply));
    expect(s.phase, DenseLodPhase.ready);
    expect(fake.methods, ['buildFromPly', 'verifyOctree']);
  });

  test('re-entry: a valid tree is used without building (fresh cache object = new app session)', () async {
    expect((await settleOn(lod, lod.watch(ply))).phase, DenseLodPhase.ready);
    final again = DenseLodCache(cacheRoot: () async => caches);
    fake.calls.clear();
    expect(await again.findValid(ply), '${work.path}/lod');
    final s = await settleOn(again, again.watch(ply));
    expect(s.phase, DenseLodPhase.ready);
    expect(fake.methods, isEmpty, reason: 'valid tree must be reused');
    // NEGATIVE: the dense PLY now declares another point count ⇒ the tree is not its tree
    writeDensePly(ply, 5002, seed: 3);
    expect(await again.findValid(ply), isNull);
  });

  test('isValidTree: every part of the rule can reject', () async {
    final s = await settleOn(lod, lod.watch(ply));
    final tree = Directory(s.octreeDir!);
    expect(DenseLodCache.isValidTree(tree, 5000), isTrue);
    expect(DenseLodCache.isValidTree(tree, 4999), isFalse, reason: 'points ≠ dense PLY header');
    for (final f in ['metadata.json', 'hierarchy.bin', 'octree.bin']) {
      final file = File('${tree.path}/$f');
      final bytes = file.readAsBytesSync();
      file.deleteSync();
      expect(DenseLodCache.isValidTree(tree, 5000), isFalse, reason: 'missing $f');
      file.writeAsBytesSync(bytes);
      expect(DenseLodCache.isValidTree(tree, 5000), isTrue);
    }
    // octree.bin one 18-byte record short ⇒ not 18 × points
    final bin = File('${tree.path}/octree.bin');
    final bytes = bin.readAsBytesSync();
    bin.writeAsBytesSync(bytes.sublist(0, bytes.length - 18));
    expect(DenseLodCache.isValidTree(tree, 5000), isFalse);
    bin.writeAsBytesSync(bytes);
    // unreadable metadata.json
    final meta = File('${tree.path}/metadata.json');
    final m = meta.readAsStringSync();
    meta.writeAsStringSync('{"points":');
    expect(DenseLodCache.isValidTree(tree, 5000), isFalse);
    meta.writeAsStringSync(m);
    expect(DenseLodCache.isValidTree(tree, 5000), isTrue);
  });

  group('[174] the tree is found by its place in the work directory', () {
    // Same work, two container prefixes: install N …/Application/<UUID-A>/, install N+1 …/Application/<UUID-B>/.
    test('container number change: still found at once, no rebuild', () async {
      final c1 = Directory('${tmp.path}/Application/AAAAAAAA-0000-0000-0000-000000000001');
      final c2 = Directory('${tmp.path}/Application/BBBBBBBB-0000-0000-0000-000000000002');
      final ply1 = writeDensePly('${c1.path}/Documents/captures_official/$kCap/official_dense.ply', 4000).path;
      final lod1 = DenseLodCache(cacheRoot: () async => Directory('${c1.path}/Library/Caches'));
      expect((await settleOn(lod1, lod1.watch(ply1))).phase, DenseLodPhase.ready);
      final builtFor = ply1; // what an absolute-path rule would have recorded at build time
      c1.renameSync(c2.path); // the app update: same files, new container path
      fake.calls.clear();
      final ply2 = '${c2.path}/Documents/captures_official/$kCap/official_dense.ply';
      final lod2 = DenseLodCache(cacheRoot: () async => Directory('${c2.path}/Library/Caches'));
      expect(await lod2.findValid(ply2), '${c2.path}/Documents/captures_official/$kCap/lod');
      expect((await settleOn(lod2, lod2.watch(ply2))).phase, DenseLodPhase.ready);
      expect(fake.methods, isEmpty);
      // NEGATIVE: an absolute-path judgment (171–173: path recorded at build == path now) fails here
      expect(builtFor == ply2, isFalse);
      expect(File(ply2).absolute.path == File(builtFor).absolute.path, isFalse);
    });

    test('lod.building/ and lod.deleting.* are never a tree, even when complete and correct', () async {
      final s = await settleOn(lod, lod.watch(ply));
      Directory(s.octreeDir!).renameSync('${work.path}/lod.building');
      final fresh = DenseLodCache(cacheRoot: () async => caches);
      expect(DenseLodCache.isValidTree(Directory('${work.path}/lod.building'), 5000), isTrue,
          reason: 'the same files would pass the rule — only the name keeps them out');
      expect(await fresh.findValid(ply), isNull);
      Directory('${work.path}/lod.building').renameSync('${work.path}/lod.deleting.123');
      expect(await fresh.findValid(ply), isNull);
      // POSITIVE control: the same files under lod/ are found
      Directory('${work.path}/lod.deleting.123').renameSync('${work.path}/lod');
      expect(await fresh.findValid(ply), '${work.path}/lod');
    });

    test('a new build removes leftovers first and replaces an old lod/ in one rename', () async {
      // an old tree for another point count + a leftover lod.building from a killed build
      final old = Directory('${work.path}/lod')..createSync();
      File('${old.path}/metadata.json').writeAsStringSync(jsonEncode({'points': 10}));
      File('${old.path}/hierarchy.bin').writeAsBytesSync([0]);
      File('${old.path}/octree.bin').writeAsBytesSync(List.filled(180, 0));
      final left = Directory('${work.path}/lod.building')..createSync();
      File('${left.path}/octree.bin').writeAsBytesSync([1, 2, 3]);
      expect(await lod.findValid(ply), isNull);
      final s = await settleOn(lod, lod.watch(ply));
      expect(s.phase, DenseLodPhase.ready);
      expect(names(work), ['lod', 'official_dense.ply', 'official_sfm_sparse.ply']);
      expect(DenseLodCache.treePointsOf(Directory('${work.path}/lod')), 5000);
    });

    test('discardTree (a dense run starts): lod/ and leftovers go, the next watch builds anew', () async {
      expect((await settleOn(lod, lod.watch(ply))).phase, DenseLodPhase.ready);
      Directory('${work.path}/lod.building').createSync();
      lod.discardTree(work.path);
      expect(names(work), ['official_dense.ply', 'official_sfm_sparse.ply']);
      // NEGATIVE: a leftover lod.building made after the discard is still not a tree
      final left = Directory('${work.path}/lod.building')..createSync();
      File('${left.path}/metadata.json').writeAsStringSync(jsonEncode({'points': 5000}));
      File('${left.path}/hierarchy.bin').writeAsBytesSync([0]);
      File('${left.path}/octree.bin').writeAsBytesSync(List.filled(18 * 5000, 0));
      expect(await lod.findValid(ply), isNull);
      fake.calls.clear();
      expect((await settleOn(lod, lod.watch(ply))).phase, DenseLodPhase.ready);
      expect(fake.methods, ['buildFromPly', 'verifyOctree']);
      expect(names(work), ['lod', 'official_dense.ply', 'official_sfm_sparse.ply']);
    });
  });

  group('[174] migration of a 171–173 tree from Library/Caches/lod/<作品标识>/', () {
    Directory legacyTree(int points) {
      final d = Directory('${caches.path}/lod/$kCap')..createSync(recursive: true);
      File('${d.path}/metadata.json').writeAsStringSync(jsonEncode({'version': '2.0', 'points': points}));
      File('${d.path}/hierarchy.bin').writeAsBytesSync(List.filled(22, 0));
      File('${d.path}/octree.bin').writeAsBytesSync(List.filled(18 * points, 0));
      File('${d.path}/pw_lod_source.json').writeAsStringSync('{"ply_path":"/old/container/path"}');
      return d;
    }

    test('matching points ⇒ renamed into <作品目录>/lod once, no rebuild', () async {
      final legacy = legacyTree(5000);
      expect(await lod.findValid(ply), '${work.path}/lod');
      expect(legacy.existsSync(), isFalse, reason: 'moved, not copied');
      expect(DenseLodCache.treePointsOf(Directory('${work.path}/lod')), 5000);
      expect(fake.methods, isEmpty);
      // the next visit finds it in place
      expect(await DenseLodCache(cacheRoot: () async => caches).findValid(ply), '${work.path}/lod');
    });

    test('NEGATIVE: point mismatch ⇒ not migrated, left in place, no tree (the page shows sparse)', () async {
      final legacy = legacyTree(4999);
      expect(await lod.findValid(ply), isNull);
      expect(legacy.existsSync(), isTrue);
      expect(Directory('${work.path}/lod').existsSync(), isFalse);
      expect(fake.methods, isEmpty, reason: 'findValid never builds');
    });

    test('NEGATIVE: an existing <作品目录>/lod blocks the migration (the rule says: only when there is none)', () async {
      final legacy = legacyTree(5000);
      Directory('${work.path}/lod').createSync(); // present but not a valid tree
      expect(await lod.findValid(ply), isNull);
      expect(legacy.existsSync(), isTrue);
    });

    test('watch migrates too (no build)', () async {
      legacyTree(5000);
      final s = await settleOn(lod, lod.watch(ply));
      expect(s.phase, DenseLodPhase.ready);
      expect(s.octreeDir, '${work.path}/lod');
      expect(fake.methods, isEmpty);
    });
  });

  group('[174] a dense PLY cut short is not done and is never a source', () {
    test('densePlyPoints: complete ⇒ count; one byte short or long, or no file ⇒ null', () {
      expect(densePlyPoints(ply), 5000);
      expect(densePlyComplete(ply), isTrue);
      final bytes = File(ply).readAsBytesSync();
      File(ply).writeAsBytesSync(bytes.sublist(0, bytes.length - 1));
      expect(densePlyPoints(ply), isNull);
      File(ply).writeAsBytesSync([...bytes, 0]);
      expect(densePlyPoints(ply), isNull);
      File(ply).writeAsBytesSync(bytes.sublist(0, 200)); // killed right after the header
      expect(densePlyComplete(ply), isFalse);
      expect(densePlyComplete('${work.path}/missing.ply'), isFalse);
      File(ply).writeAsBytesSync(bytes);
      expect(densePlyComplete(ply), isTrue);
    });

    test('truncated PLY: no tree is built from it, and an old tree for its header count is not used', () async {
      expect((await settleOn(lod, lod.watch(ply))).phase, DenseLodPhase.ready);
      final bytes = File(ply).readAsBytesSync();
      File(ply).writeAsBytesSync(bytes.sublist(0, bytes.length - 15 * 100));
      final fresh = DenseLodCache(cacheRoot: () async => caches);
      expect(await fresh.findValid(ply), isNull, reason: 'header still says 5000 — the length does not');
      Directory('${work.path}/lod').deleteSync(recursive: true);
      fake.calls.clear();
      final s = await settleOn(fresh, fresh.watch(ply));
      expect(s.phase, DenseLodPhase.failed);
      expect(s.message, contains('incomplete'));
      expect(fake.methods, isEmpty);
    });
  });

  test('no cache directory: scratch goes next to the tree and is cleaned; no PLY ⇒ failed', () async {
    final noRoot = DenseLodCache(cacheRoot: () async => null);
    expect((await settleOn(noRoot, noRoot.watch(ply))).phase, DenseLodPhase.ready);
    final build = fake.of('buildFromPly').single.arguments as Map;
    expect(build['chunk_dir'], '${work.path}/lod.building.chunks');
    expect(names(work), ['lod', 'official_dense.ply', 'official_sfm_sparse.ply']);
    fake.calls.clear();
    expect((await settleOn(lod, lod.watch('${work.path}/missing.ply'))).phase, DenseLodPhase.failed);
    expect(fake.methods, isEmpty);
  });

  test('key = the work directory name (171–173 legacy name, chunk scratch name)', () {
    expect(DenseLodCache.keyFor('/a/Documents/captures_official/cap_17/official_dense.ply'), 'cap_17');
    expect(DenseLodCache.treeDirOf('/a/Documents/captures_official/cap_17/official_dense.ply'),
        '/a/Documents/captures_official/cap_17/lod');
  });

  test('the engine identity in stamps is the vendored archive (drift guard)', () {
    final receipt = jsonDecode(
      File('vendor/aether_lod/libs/ios-arm64/libpw_lod_$kLodEngineSha8.a.receipt.json').readAsStringSync(),
    ) as Map;
    expect(receipt['artifact'], 'libpw_lod_$kLodEngineSha8.a');
    expect(File('vendor/aether_lod/include/pwlod_viewer.h').readAsStringSync(), contains('#define PWLOD_ABI_VERSION $kLodEngineAbi'));
    final pbx = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    expect(pbx, contains('libpw_lod_$kLodEngineSha8.a'));
    // NEGATIVE: the superseded archives (v2 afb521e6, v3 ee942e08 before R18) are not what the project links
    expect(pbx.contains('libpw_lod_afb521e6.a'), isFalse);
    expect(pbx.contains('libpw_lod_ee942e08.a'), isFalse);
  });
}
