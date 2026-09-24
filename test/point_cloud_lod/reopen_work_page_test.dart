// Page-level judges for 「重新打开作品」, on the REAL OfficialARCapturePage in review mode (no camera
// in that mode) over the fake iOS shell. Every judge has a negative control.
//   build 172 (user 2026-09-24): 「有树秒开，没树就停在稀疏点云的展示页面」.
//   build 174 (user 2026-09-24): the tree lives in <作品目录>/lod/ (found by its place, migrated once
//   from the 171–173 cache place), and 「永远不会重新训练稠密。如果有那就是 bug」 — a complete
//   official_dense. py on disk = dense done: no 下一步, the tree is built from that PLY in the
//   background; only a work without a (complete) dense PLY offers 下一步 (the first training).
//
// Background: build 171 decoded the whole dense PLY (未命名(12): 6,922,990 points / 99 MB) through
// loadReviewCloud on re-entry; on the phone that never finished while the tree was long ready,
// and the page showed 「正在生成最终点云…」 the whole time.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/dense/dense_live_cloud.dart';
import 'package:pocketworld_flutter/dense/dense_stage_progress.dart';
import 'package:pocketworld_flutter/dense/dense_work_state.dart';
import 'package:pocketworld_flutter/dense/native_dense_stage_launcher.dart';
import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/official_capture/dense_stage.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/point_cloud_lod/dense_lod_cache.dart';
import 'package:pocketworld_flutter/ui/official_capture/ar_capture_page.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_viewer_page.dart';

import 'fake_lod_platform.dart';

class _FakeDenseLauncher implements DenseStageLauncher {
  final starts = <DenseStageRequest>[];
  @override
  bool get isAvailable => true;
  @override
  Future<DenseStageResult> start(DenseStageRequest request) async {
    starts.add(request);
    denseStageProgress.value = DenseStageProgress(
      captureDir: request.captureDir,
      state: DenseStageState.running,
      phase: 'session',
      startedAt: DateTime.now(),
      live: DenseLiveCloud(framesPlanned: 1),
    );
    return const DenseStageResult.started();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late String dir, sparsePly, densePly;
  late FakeLodPlatform fake;
  late DenseLodCache cache;
  late _FakeDenseLauncher launcher;
  final loads = <String>[];
  final defaultLoader = OfficialARCapturePage.debugReviewCloudLoader;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('reopen_work');
    dir = '${tmp.path}/Documents/captures_official/cap_1789381704918369';
    sparsePly = writeDensePly('$dir/official_sfm_sparse.ply', 400, seed: 3).path;
    densePly = '$dir/official_dense.ply';
    fake = FakeLodPlatform()..install();
    cache = DenseLodCache(cacheRoot: () async => Directory('${tmp.path}/Library/Caches'));
    DenseLodCache.instanceForTesting = cache;
    launcher = _FakeDenseLauncher();
    denseStageLauncher = launcher;
    denseStageProgress.value = null;
    loads.clear();
    OfficialARCapturePage.debugReviewCloudLoader = (path, label) {
      loads.add(path);
      return defaultLoader(path, label);
    };
    OfficialARCapturePage.debugLegacyDenseReviewLoad = false;
    OfficialARCapturePage.debug172DenseDoneRule = false;
  });
  tearDown(() {
    OfficialARCapturePage.debugReviewCloudLoader = defaultLoader;
    OfficialARCapturePage.debugLegacyDenseReviewLoad = false;
    OfficialARCapturePage.debug172DenseDoneRule = false;
    denseStageLauncher = const UnavailableDenseStageLauncher();
    denseStageProgress.value = null;
    FakeLodPlatform.uninstall();
    tmp.deleteSync(recursive: true);
  });

  Future<void> buildValidTree() async {
    writeDensePly(densePly, 3000, seed: 5);
    cache.watch(densePly);
    await cache.whenIdle();
    expect(await cache.findValid(densePly), isNotNull);
    fake.calls.clear();
  }

  /// Lets the page's background work (tree check / build in the real zone) run and repaints.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await DenseLodCache.instance.whenIdle();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  Future<void> open(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppL10n.localizationsDelegates,
          supportedLocales: AppL10n.supportedLocales,
          locale: const Locale('zh'),
          home: OfficialARCapturePage(reviewCaptureDir: dir),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
    });
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  final next = find.text('下一步');
  final editEntry = find.byKey(const ValueKey('sfm_preview_enter_editing'));

  testWidgets('有树：秒开 — the tree is loaded into the view, the dense PLY is never decoded, nothing is built', (tester) async {
    await tester.runAsync(buildValidTree);
    await open(tester);
    expect(loads, [sparsePly], reason: 'only the sparse PLY may be decoded on re-entry');
    expect(fake.methods, contains('loadOctree'));
    expect((fake.of('loadOctree').single.arguments as Map)['octree_dir'], '$dir/lod');
    expect(fake.methods, isNot(contains('buildFromPly')));
    expect(fake.source, 2);
    expect(find.byType(Texture), findsOneWidget);
    // dense counts as done: only viewing, no 下一步 / editing (the dense stage has no editing)
    expect(next, findsNothing);
    expect(editEntry, findsNothing);
    expect(find.textContaining('生成'), findsNothing);
  });

  testWidgets('[174] container number change (iOS app update): the tree in <作品目录>/lod still opens at once', (tester) async {
    // build in the OLD container, then move the whole container like an iOS update does
    final old = Directory('${tmp.path}/Application/AAAAAAAA-OLD')..createSync(recursive: true);
    final neu = Directory('${tmp.path}/Application/BBBBBBBB-NEW');
    final oldDir = '${old.path}/Documents/captures_official/cap_1789381704918369';
    writeDensePly('$oldDir/official_sfm_sparse.ply', 400, seed: 3);
    final oldPly = writeDensePly('$oldDir/official_dense.ply', 3000, seed: 5).path;
    await tester.runAsync(() async {
      final c = DenseLodCache(cacheRoot: () async => Directory('${old.path}/Library/Caches'));
      c.watch(oldPly);
      await c.whenIdle();
      old.renameSync(neu.path);
    });
    fake.calls.clear();
    dir = '${neu.path}/Documents/captures_official/cap_1789381704918369';
    sparsePly = '$dir/official_sfm_sparse.ply';
    final newPly = '$dir/official_dense.ply';
    DenseLodCache.instanceForTesting = DenseLodCache(cacheRoot: () async => Directory('${neu.path}/Library/Caches'));
    await open(tester);
    expect(loads, [sparsePly]);
    expect(fake.methods, contains('loadOctree'), reason: 'the tree must survive the container move');
    expect((fake.of('loadOctree').single.arguments as Map)['octree_dir'], '$dir/lod');
    expect(fake.methods, isNot(contains('buildFromPly')));
    expect(next, findsNothing);
    expect(launcher.starts, isEmpty);
    // NEGATIVE: an absolute-path judgment (171–173 recorded the PLY's absolute path) fails here
    expect(newPly == oldPly, isFalse);
  });

  testWidgets('[174] a 171/172 tree in Library/Caches/lod/<作品标识>/ is migrated (rename) and opens at once', (tester) async {
    writeDensePly(densePly, 3000, seed: 5);
    final legacy = Directory('${tmp.path}/Library/Caches/lod/cap_1789381704918369');
    await tester.runAsync(() async {
      // the tree exactly where 171/172 put it (built by the same fake engine, then moved there)
      final c = DenseLodCache(cacheRoot: () async => Directory('${tmp.path}/Library/Caches'));
      c.watch(densePly);
      await c.whenIdle();
      legacy.parent.createSync(recursive: true);
      Directory('$dir/lod').renameSync(legacy.path);
    });
    fake.calls.clear();
    await open(tester);
    expect(loads, [sparsePly]);
    expect((fake.of('loadOctree').single.arguments as Map)['octree_dir'], '$dir/lod');
    expect(fake.methods, isNot(contains('buildFromPly')), reason: 'migration is a rename, never a rebuild');
    expect(legacy.existsSync(), isFalse);
    expect(next, findsNothing);
    expect(launcher.starts, isEmpty);
  });

  testWidgets('[174] NEGATIVE migration: point mismatch ⇒ not migrated, the sparse cloud shows first', (tester) async {
    writeDensePly(densePly, 3000, seed: 5);
    final legacy = Directory('${tmp.path}/Library/Caches/lod/cap_1789381704918369')..createSync(recursive: true);
    File('${legacy.path}/metadata.json').writeAsStringSync(jsonEncode({'points': 2999}));
    File('${legacy.path}/hierarchy.bin').writeAsBytesSync(List.filled(22, 0));
    File('${legacy.path}/octree.bin').writeAsBytesSync(List.filled(18 * 2999, 0));
    final gate = Completer<void>();
    fake.buildGate = gate.future; // hold the background build to look at the page meanwhile
    await open(tester);
    expect(legacy.existsSync(), isTrue, reason: 'a tree for another point count is not this work\'s tree');
    expect(fake.methods, isNot(contains('loadOctree')));
    expect(fake.source, 1, reason: 'sparse flat set on screen');
    expect(fake.methods, contains('buildFromPly'), reason: 'complete dense PLY ⇒ its tree is built from it');
    expect(next, findsNothing);
    await tester.runAsync(() async => gate.complete());
    await settle(tester);
    expect((fake.of('loadOctree').single.arguments as Map)['octree_dir'], '$dir/lod');
    expect(launcher.starts, isEmpty);
  });

  testWidgets('NEGATIVE: the old 171 path (decode the dense PLY) is caught by the same judge', (tester) async {
    await tester.runAsync(buildValidTree);
    OfficialARCapturePage.debugLegacyDenseReviewLoad = true;
    await open(tester);
    expect(loads, contains(densePly));
    expect(() => expect(loads, [sparsePly]), throwsA(isA<TestFailure>()));
  });

  testWidgets('no dense PLY: the sparse page — no build, 下一步 runs the FIRST dense training (the only one allowed)', (tester) async {
    await open(tester);
    expect(loads, [sparsePly]);
    expect(fake.methods, isNot(contains('buildFromPly')));
    expect(fake.methods, isNot(contains('loadOctree')));
    expect(fake.source, 1); // the sparse flat set on the GPU viewer
    expect(editEntry, findsOneWidget); // sparse editing as before
    expect(next, findsOneWidget);
    await tester.tap(next);
    await tester.pump();
    expect(launcher.starts.single.captureDir, dir);
  });

  testWidgets('[174] complete dense PLY, no tree: dense is done — no 下一步, no training; the tree is built from that PLY', (tester) async {
    writeDensePly(densePly, 3000, seed: 5);
    final before = File(densePly).readAsBytesSync();
    final gate = Completer<void>();
    fake.buildGate = gate.future; // hold the build: first the page must show the sparse cloud
    await open(tester);
    expect(loads, [sparsePly], reason: 'the dense PLY must not be decoded in Dart');
    expect(fake.source, 1, reason: 'sparse on screen while the tree is built');
    expect(fake.methods, isNot(contains('loadOctree')));
    expect((fake.of('buildFromPly').single.arguments as Map)['ply_path'], densePly);
    expect((fake.of('buildFromPly').single.arguments as Map)['out_dir'], '$dir/lod.building');
    expect(next, findsNothing, reason: '「永远不会重新训练稠密」');
    expect(editEntry, findsNothing);
    await tester.runAsync(() async => gate.complete());
    await settle(tester);
    // same viewer switches to the tree
    expect(fake.methods, containsAllInOrder(['buildFromPly', 'verifyOctree', 'loadOctree']));
    expect((fake.of('loadOctree').single.arguments as Map)['octree_dir'], '$dir/lod');
    expect(fake.source, 2);
    expect(find.byType(Texture), findsOneWidget);
    expect(next, findsNothing);
    expect(launcher.starts, isEmpty);
    expect(File(densePly).readAsBytesSync(), before);
  });

  testWidgets('[174] tree build fails: stays sparse, logged, and still never trains', (tester) async {
    writeDensePly(densePly, 3000, seed: 5);
    fake.buildLosesPoints = 1; // C1 rejects the tree
    await open(tester);
    await settle(tester);
    expect(fake.methods, contains('buildFromPly'));
    expect(fake.methods, isNot(contains('loadOctree')));
    expect(fake.source, 1);
    expect(next, findsNothing);
    expect(editEntry, findsNothing);
    expect(launcher.starts, isEmpty);
    expect(Directory('$dir/lod').existsSync(), isFalse);
  });

  testWidgets('[174] NEGATIVE: build 172\'s rule put back (下一步 over a complete dense PLY) is caught', (tester) async {
    writeDensePly(densePly, 3000, seed: 5);
    OfficialARCapturePage.debug172DenseDoneRule = true;
    await open(tester);
    await settle(tester);
    // the judges of the test above fail under 172's rule:
    expect(() => expect(next, findsNothing), throwsA(isA<TestFailure>()));
    expect(() => expect(fake.methods, contains('buildFromPly')), throwsA(isA<TestFailure>()));
    await tester.tap(next);
    await tester.pump();
    expect(launcher.starts.length, 1, reason: '172 trained the dense stage again');
    expect(() => expect(launcher.starts, isEmpty), throwsA(isA<TestFailure>()));
  });

  final finish = find.text('完成稠密');
  const box = SelectionBox(cx: 0.1, cy: 0.2, cz: 0.3, sx: 0.5, sy: 0.6, sz: 0.7);

  testWidgets('[174] killed mid-training (下一步 tapped, PLY cut short): only 「完成稠密」, same selection; no 选区编辑, no tree', (tester) async {
    final full = writeDensePly(densePly, 3000, seed: 5).readAsBytesSync();
    File(densePly).writeAsBytesSync(full.sublist(0, full.length - 15 * 700));
    writeDenseStartedMarker(dir, selection: box, sparsePoints: 400);
    await open(tester);
    await settle(tester);
    expect(fake.methods, isNot(contains('buildFromPly')), reason: 'a cut-short PLY is never a source');
    expect(fake.methods, isNot(contains('loadOctree')));
    expect(finish, findsOneWidget);
    expect(next, findsNothing);
    expect(editEntry, findsNothing, reason: '「当用户点击下一步的时候，数据采集阶段就正式结束了」');
    await tester.runAsync(() async {
      await tester.tap(finish);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    final req = launcher.starts.single;
    expect(req.captureDir, dir);
    expect(req.selection?.toJson(), box.toJson(), reason: 'finish the run that began, on its selection');
  });

  testWidgets('[174] killed by a build without the marker (dense_work/ left behind): same, selection from the saved box', (tester) async {
    Directory('$dir/$kDenseWorkDirName').createSync();
    await tester.runAsync(() => box.saveTo(dir));
    await open(tester);
    await settle(tester);
    expect(finish, findsOneWidget);
    expect(editEntry, findsNothing);
    await tester.runAsync(() async {
      await tester.tap(finish);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pump();
    expect(launcher.starts.single.selection?.toJson(), box.toJson());
  });

  testWidgets('[174] NEGATIVE: a work that never tapped 下一步 keeps 选区编辑 and 下一步 (no 「完成稠密」)', (tester) async {
    await tester.runAsync(() => box.saveTo(dir)); // a saved selection alone is not a dense run
    await open(tester);
    await settle(tester);
    expect(editEntry, findsOneWidget);
    expect(next, findsOneWidget);
    expect(finish, findsNothing);
  });

  testWidgets('[174] 下一步 tapped in this session ⇒ 选区编辑 gone at once (the capture stage is over)', (tester) async {
    await open(tester);
    expect(editEntry, findsOneWidget);
    await tester.tap(next);
    await tester.pump();
    expect(launcher.starts.length, 1);
    // the run fails (e.g. killed): 选区编辑 stays gone, the button finishes the run
    await tester.runAsync(() async {
      denseStageProgress.value = denseStageProgress.value!.copyWith(state: DenseStageState.failed);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    await tester.pump(const Duration(milliseconds: 300));
    expect(editEntry, findsNothing);
    expect(finish, findsOneWidget);
  });

  testWidgets('[174] NEGATIVE of the cut-short case: the same PLY complete ⇒ no 下一步', (tester) async {
    writeDensePly(densePly, 3000, seed: 5);
    fake.buildGate = Completer<void>().future; // never finishes here; only the buttons matter
    await open(tester);
    expect(next, findsNothing);
  });

  test('[174] the launcher refuses a work with a complete dense PLY (every entry goes through it)', () async {
    writeDensePly(densePly, 3000, seed: 5);
    expect(denseDenyReason(dir), contains('complete official_dense.ply'));
    final r = await NativeDenseStageLauncher().start(
      DenseStageRequest(captureDir: dir, sparsePlyPath: sparsePly, pointCount: 400),
    );
    expect(r.status, DenseStageStatus.failed);
    expect(r.message, '稠密点云已经生成过,不会重新训练');
    // NEGATIVE: no PLY / a cut-short PLY ⇒ not refused (on this host the framework is then simply absent)
    final bytes = File(densePly).readAsBytesSync();
    File(densePly).writeAsBytesSync(bytes.sublist(0, bytes.length - 15));
    expect(denseDenyReason(dir), isNull);
    final r2 = await NativeDenseStageLauncher().start(
      DenseStageRequest(captureDir: dir, sparsePlyPath: sparsePly, pointCount: 400),
    );
    expect(r2.status, DenseStageStatus.unavailable);
    File(densePly).deleteSync();
    expect(denseDenyReason(dir), isNull);
  });

  test('[174] launcher wiring: the refusal comes first; a real start discards <作品目录>/lod before the job', () {
    final src = File('lib/dense/native_dense_stage_launcher.dart').readAsStringSync();
    final start = src.indexOf('Future<DenseStageResult> start(DenseStageRequest request)');
    final deny = src.indexOf('denseDenyReason(request.captureDir)', start);
    final ffi = src.indexOf('if (_ffi == null)', start);
    final running = src.indexOf('_running = true;', start);
    final discard = src.indexOf('DenseLodCache.instance.discardTree(request.captureDir)', start);
    final job = src.indexOf('unawaited(_runJob(', start);
    expect([start, deny, ffi, running, discard, job].every((i) => i > 0), isTrue);
    expect(deny < ffi, isTrue);
    expect(running < discard && discard < job, isTrue);
  });

  testWidgets('the loading cover says 正在载入点云… (never 生成) while the sparse PLY loads', (tester) async {
    final gate = Completer<void>();
    OfficialARCapturePage.debugReviewCloudLoader = (path, label) async {
      loads.add(path);
      await gate.future;
      return loadSparsePly(path);
    };
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        locale: const Locale('zh'),
        home: OfficialARCapturePage(reviewCaptureDir: dir),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('正在载入点云…'), findsOneWidget);
    expect(find.text('正在生成最终点云…'), findsNothing);
    gate.complete();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 300));
    // NEGATIVE: the cover is gone once loaded (the judge above is not satisfied by a stale widget)
    expect(find.text('正在载入点云…'), findsNothing);
  });

  test('no path decodes the dense PLY: loadReviewCloud refuses official_dense.ply (same bytes decode under another name)', () {
    writeDensePly(densePly, 2000, seed: 7);
    expect(loadReviewCloud(densePly), isNull);
    // NEGATIVE control: the guard is about the dense PLY, not a broken loader — the identical
    // bytes under the sparse name decode fine.
    final copy = File(densePly).copySync('${tmp.path}/official_sfm_sparse.ply');
    expect(loadReviewCloud(copy.path)?.count, 2000);
    // and the page's legacy switch (the 171 call put back) is what made the dense path show up
    // in the loader log in the NEGATIVE test above; with it off, no production path asks for it.
    final lib = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => f.readAsStringSync().split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n'))
        .join('\n');
    expect(lib.contains('compute(loadReviewCloud, densePly'), isFalse);
    expect(RegExp(r'debugReviewCloudLoader\(densePly').allMatches(lib).length, 1); // the switch only
  });

  test('build log carries start / end / peak and whether the app went to the background', () async {
    final logged = <String>[];
    final c = DenseLodCache(cacheRoot: () async => Directory('${tmp.path}/Library/Caches'));
    writeDensePly(densePly, 1000);
    await runZoned(
      () async {
        c.watch(densePly);
        await c.whenIdle();
      },
      zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) => logged.add(line)),
    );
    final timing = logged.firstWhere((l) => l.contains('build timing'), orElse: () => '');
    expect(timing, contains('start 20'));
    expect(timing, contains(' end 20'));
    expect(timing, contains('peak '));
    expect(timing, contains('background during build: no'));
    // NEGATIVE: a lifecycle pause during the build flips the line to YES
    fake.calls.clear();
    final c2 = DenseLodCache(cacheRoot: () async => Directory('${tmp.path}/Library/Caches'));
    final densePly2 = writeDensePly('${tmp.path}/Documents/captures_official/cap_2/official_dense.ply', 1000).path;
    final logged2 = <String>[];
    final binding = TestWidgetsFlutterBinding.instance;
    final gate = Completer<void>();
    fake.buildGate = gate.future;
    await runZoned(
      () async {
        c2.watch(densePly2);
        for (var i = 0; i < 100 && !fake.methods.contains('buildFromPly'); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(fake.methods, contains('buildFromPly'), reason: 'the build must be in flight');
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        gate.complete();
        await c2.whenIdle();
      },
      zoneSpecification: ZoneSpecification(print: (self, parent, zone, line) => logged2.add(line)),
    );
    final t2 = logged2.firstWhere((l) => l.contains('build timing'), orElse: () => '');
    expect(t2, contains('background during build: YES'));
  });
}
