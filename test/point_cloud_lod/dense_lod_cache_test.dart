// DenseLodCache: the finished dense cloud's octree in <cache>/lod/<作品标识>/, gated by C1/C2/S2,
// invalidated by the review cache's rule (902c509 / 87b33dc). Every positive has a negative control
// through the same judge.
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp, docs, cache;
  late FakeLodPlatform fake;
  late DenseLodCache lod;
  late String ply;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dense_lod_cache');
    docs = Directory('${tmp.path}/Documents/captures_official/cap_1788832166373381')..createSync(recursive: true);
    cache = Directory('${tmp.path}/Library/Caches');
    ply = writeDensePly('${docs.path}/official_dense.ply', 5000).path;
    fake = FakeLodPlatform()..install();
    lod = DenseLodCache(cacheRoot: () async => Directory('${cache.path}/lod'));
  });
  tearDown(() {
    FakeLodPlatform.uninstall();
    tmp.deleteSync(recursive: true);
  });

  List<String> captureDirListing() => [for (final e in docs.listSync()) e.path.split('/').last]..sort();

  test('builds into Library/Caches/lod/<cap id>/, verified, stamped; the capture dir is untouched', () async {
    final before = captureDirListing();
    final s = await settleOn(lod, lod.watch(ply));
    expect(s.phase, DenseLodPhase.ready, reason: '$s');
    expect(s.octreeDir, '${cache.path}/lod/cap_1788832166373381');
    expect(fake.methods, ['buildFromPly', 'verifyOctree']);
    final build = fake.of('buildFromPly').single.arguments as Map;
    expect(build['out_dir'], '${cache.path}/lod/cap_1788832166373381.building');
    expect(build['chunk_dir'], '${cache.path}/lod/cap_1788832166373381.chunks');
    expect(Directory(build['chunk_dir'] as String).existsSync(), isFalse);
    expect(Directory(build['out_dir'] as String).existsSync(), isFalse); // renamed into place
    final stamp = jsonDecode(File('${s.octreeDir}/pw_lod_source.json').readAsStringSync()) as Map;
    expect(stamp['pass'], true);
    expect(stamp['ply_points'], 5000);
    expect(stamp['engine'], '72ee817f abi=3');
    expect((stamp['checks'] as List).every((c) => (c as Map)['pass'] == true), isTrue);
    // gate B: nothing added under captures_official/<cap_id>/
    expect(captureDirListing(), before);
    expect(Directory('${tmp.path}/Documents').listSync().map((e) => e.path.split('/').last), ['captures_official']);
  });

  test('C1: one point short ⇒ no tree, flat display stays; the half-built tree is removed', () async {
    fake.buildLosesPoints = 1;
    final s = await settleOn(lod, lod.watch(ply));
    expect(s.phase, DenseLodPhase.failed);
    expect(s.message, contains('C1'));
    expect(fake.methods, ['buildFromPly']); // verify is not even run
    expect(Directory('${cache.path}/lod/cap_1788832166373381').existsSync(), isFalse);
    expect(Directory('${cache.path}/lod/cap_1788832166373381.building').existsSync(), isFalse);
    // NEGATIVE control of the judge: the same PLY with a faithful build passes
    final ok = DenseLodCache(cacheRoot: () async => Directory('${cache.path}/lod2'));
    fake.buildLosesPoints = 0;
    expect((await settleOn(ok, ok.watch(ply))).phase, DenseLodPhase.ready);
  });

  test('S2: an unreachable leaf ⇒ no tree', () async {
    fake.verifyUnreachableLeaves = 1;
    final s = await settleOn(lod, lod.watch(ply));
    expect(s.phase, DenseLodPhase.failed);
    expect(s.message, contains('S2'));
    expect(Directory('${cache.path}/lod/cap_1788832166373381').existsSync(), isFalse);
  });

  test('a failed PLY is not rebuilt on every visit; a changed PLY is', () async {
    fake.buildLosesPoints = 1;
    expect((await settleOn(lod, lod.watch(ply))).phase, DenseLodPhase.failed);
    fake.calls.clear();
    fake.buildLosesPoints = 0;
    lod.watch(ply);
    expect((await settleOn(lod, lod.watch(ply))).phase, DenseLodPhase.failed);
    expect(fake.methods, isEmpty);
    // the dense stage ran again: new content
    writeDensePly(ply, 5001, seed: 2);
    final s = await settleOn(lod, lod.watch(ply));
    expect(s.phase, DenseLodPhase.ready);
    expect(fake.methods, ['buildFromPly', 'verifyOctree']);
  });

  test('re-entry: a valid tree is used without building; 「内容换了拿新云」 rebuilds', () async {
    expect((await settleOn(lod, lod.watch(ply))).phase, DenseLodPhase.ready);
    // a fresh cache object = a new app session
    final again = DenseLodCache(cacheRoot: () async => Directory('${cache.path}/lod'));
    fake.calls.clear();
    final s = await settleOn(again, again.watch(ply));
    expect(s.phase, DenseLodPhase.ready);
    expect(fake.methods, isEmpty, reason: 'valid tree must be reused');
    // NEGATIVE: same length, different content and mtime ⇒ stale ⇒ rebuilt
    final src = File(ply);
    final len = src.lengthSync();
    writeDensePly(ply, 5000, seed: 99);
    expect(src.lengthSync(), len);
    src.setLastModifiedSync(DateTime.now().add(const Duration(seconds: 5)));
    final third = DenseLodCache(cacheRoot: () async => Directory('${cache.path}/lod'));
    expect((await settleOn(third, third.watch(ply))).phase, DenseLodPhase.ready);
    expect(fake.methods, ['buildFromPly', 'verifyOctree']);
  });

  test('isValidTree: each stamp field and the on-disk C1 can reject', () async {
    final s = await settleOn(lod, lod.watch(ply));
    final tree = Directory(s.octreeDir!);
    final id = denseLodSourceOf(ply)!;
    expect(DenseLodCache.isValidTree(tree, id), isTrue);
    expect(DenseLodCache.isValidTree(tree, (path: id.path, bytes: id.bytes + 1, mtimeMs: id.mtimeMs, points: id.points)), isFalse);
    expect(DenseLodCache.isValidTree(tree, (path: id.path, bytes: id.bytes, mtimeMs: id.mtimeMs + 1, points: id.points)), isFalse);
    expect(DenseLodCache.isValidTree(tree, (path: '${id.path}x', bytes: id.bytes, mtimeMs: id.mtimeMs, points: id.points)), isFalse);
    expect(DenseLodCache.isValidTree(tree, (path: id.path, bytes: id.bytes, mtimeMs: id.mtimeMs, points: id.points - 1)), isFalse);
    // truncated octree.bin (one record short) ⇒ on-disk C1 fails
    final bin = File('${tree.path}/octree.bin');
    final bytes = bin.readAsBytesSync();
    bin.writeAsBytesSync(bytes.sublist(0, bytes.length - 18));
    expect(DenseLodCache.isValidTree(tree, id), isFalse);
    bin.writeAsBytesSync(bytes);
    expect(DenseLodCache.isValidTree(tree, id), isTrue);
    // a different engine artifact ⇒ stale
    final stampFile = File('${tree.path}/pw_lod_source.json');
    final stamp = jsonDecode(stampFile.readAsStringSync()) as Map;
    stampFile.writeAsStringSync(jsonEncode({...stamp, 'engine': 'afb521e6 abi=2'}));
    expect(DenseLodCache.isValidTree(tree, id), isFalse);
  });

  test('no cache directory / no PLY ⇒ failed, nothing built', () async {
    final noRoot = DenseLodCache(cacheRoot: () async => null);
    expect((await settleOn(noRoot, noRoot.watch(ply))).phase, DenseLodPhase.failed);
    expect((await settleOn(lod, lod.watch('${docs.path}/missing.ply'))).phase, DenseLodPhase.failed);
    expect(fake.methods, isEmpty);
  });

  test('prune keeps at most 8 trees and never the one in use', () async {
    final root = Directory('${cache.path}/lod')..createSync(recursive: true);
    for (var i = 0; i < 10; i++) {
      final d = Directory('${root.path}/cap_old$i')..createSync();
      File('${d.path}/pw_lod_source.json')
        ..writeAsStringSync('{}')
        ..setLastModifiedSync(DateTime(2026, 9, 1, 0, i));
    }
    Directory('${root.path}/cap_old3.building').createSync();
    // two hours later: the leftover `.building` is past kTmpStaleAfter (1 h)
    final later = DenseLodCache(
      cacheRoot: () async => root,
      clock: () => DateTime.now().add(const Duration(hours: 2)),
    );
    expect((await settleOn(later, later.watch(ply))).phase, DenseLodPhase.ready);
    final left = [for (final e in root.listSync()) e.path.split('/').last]..sort();
    expect(left, contains('cap_1788832166373381'));
    expect(left.where((n) => n.startsWith('cap_old')).length, lessThanOrEqualTo(7));
    expect(left.contains('cap_old9'), isTrue); // newest kept
    expect(left.contains('cap_old0'), isFalse); // oldest gone
    expect(left.contains('cap_old3.building'), isFalse);
  });

  test('key = capture directory name; unusual names fall back to a path hash', () {
    expect(DenseLodCache.keyFor('/a/Documents/captures_official/cap_17/official_dense.ply'), 'cap_17');
    final k = DenseLodCache.keyFor('/a/空 格/official_dense.ply');
    expect(k, matches(RegExp(r'^p[0-9a-f]{16}$')));
    expect(DenseLodCache.keyFor('/b/空 格/official_dense.ply'), isNot(k));
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
