// Page-level judges for build 172 「重新打开作品」 (user 2026-09-24: 「有树秒开，没树就停在稀疏点云
// 的展示页面。用户点击下一步再正常训练稠密」), on the REAL OfficialARCapturePage in review mode
// (no camera in that mode) over the fake iOS shell. Every judge has a negative control.
//
// Background: build 171 decoded the whole dense PLY (未命名(12): 6,922,990 points / 99 MB) through
// loadReviewCloud on re-entry; on the phone that never finished while the tree was long ready,
// and the page showed 「正在生成最终点云…」 the whole time.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/dense/dense_live_cloud.dart';
import 'package:pocketworld_flutter/dense/dense_stage_progress.dart';
import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/official_capture/dense_stage.dart';
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
    cache = DenseLodCache(cacheRoot: () async => Directory('${tmp.path}/Library/Caches/lod'));
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
  });
  tearDown(() {
    OfficialARCapturePage.debugReviewCloudLoader = defaultLoader;
    OfficialARCapturePage.debugLegacyDenseReviewLoad = false;
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
    expect((fake.of('loadOctree').single.arguments as Map)['octree_dir'], endsWith('/lod/cap_1789381704918369'));
    expect(fake.methods, isNot(contains('buildFromPly')));
    expect(fake.source, 2);
    expect(find.byType(Texture), findsOneWidget);
    // dense counts as done: only viewing, no 下一步 / editing (the dense stage has no editing)
    expect(next, findsNothing);
    expect(editEntry, findsNothing);
    expect(find.textContaining('生成'), findsNothing);
  });

  testWidgets('NEGATIVE: the old 171 path (decode the dense PLY) is caught by the same judge', (tester) async {
    await tester.runAsync(buildValidTree);
    OfficialARCapturePage.debugLegacyDenseReviewLoad = true;
    await open(tester);
    expect(loads, contains(densePly));
    expect(() => expect(loads, [sparsePly]), throwsA(isA<TestFailure>()));
  });

  testWidgets('没树：stays on the sparse page — no dense read, no build, 下一步 runs the dense stage', (tester) async {
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

  testWidgets('old project with a dense PLY but no tree behaves exactly like 没树 (PLY untouched)', (tester) async {
    writeDensePly(densePly, 3000, seed: 5);
    final before = File(densePly).readAsBytesSync();
    await open(tester);
    expect(loads, [sparsePly], reason: 'the old dense PLY must not be read');
    expect(fake.methods, isNot(contains('buildFromPly')), reason: 're-entry must not build a tree');
    expect(fake.methods, isNot(contains('loadOctree')));
    expect(next, findsOneWidget);
    expect(editEntry, findsOneWidget);
    await tester.tap(next);
    await tester.pump();
    expect(launcher.starts.length, 1, reason: '下一步 re-runs the dense stage even though a dense PLY exists');
    expect(File(densePly).readAsBytesSync(), before);
    // NEGATIVE control of 「不建树」: the same cache DOES build when the dense stage finishes (171 flow).
    // (Set inside runAsync so the page's listener starts the build in the real zone.)
    await tester.runAsync(() async {
      denseStageProgress.value = denseStageProgress.value!.copyWith(state: DenseStageState.done, outPly: densePly);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await cache.whenIdle();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(fake.methods, containsAllInOrder(['buildFromPly', 'verifyOctree', 'loadOctree']));
    expect(next, findsNothing);
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
    final c = DenseLodCache(cacheRoot: () async => Directory('${tmp.path}/Library/Caches/lod2'));
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
    final c2 = DenseLodCache(cacheRoot: () async => Directory('${tmp.path}/Library/Caches/lod3'));
    final logged2 = <String>[];
    final binding = TestWidgetsFlutterBinding.instance;
    final gate = Completer<void>();
    fake.buildGate = gate.future;
    await runZoned(
      () async {
        c2.watch(densePly);
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
