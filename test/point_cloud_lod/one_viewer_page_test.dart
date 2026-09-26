// Page-level judges for 「查看器全程一致」 (user 2026-09-24): the capture page's cloud layer
// (SfmPreviewOverlay → SparseCloudView, gpu: true) and the full-screen viewer page
// (SparseCloudViewerPage) over a fake iOS shell (fake_lod_platform.dart). Every judge has a
// negative control through the same finder / comparison. Lesson from the ledger (09-15): byte
// self-checks do not prove a page draws, so these pump the real widgets.
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/dense/dense_stage_progress.dart';
import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/official_capture/sfm_live_recon.dart';
import 'package:pocketworld_flutter/point_cloud_lod/dense_lod_cache.dart';
import 'package:pocketworld_flutter/point_cloud_lod/lod_camera.dart';
import 'package:pocketworld_flutter/ui/official_capture/sfm_preview_overlay.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_view.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_viewer_page.dart';

import 'fake_lod_platform.dart';

SfmLiveSnapshot snap(int n, {int seed = 1, bool colored = true}) {
  final r = math.Random(seed);
  final xyz = Float32List(n * 3);
  final rgb = Uint8List(n * 3);
  for (var i = 0; i < n * 3; i++) {
    xyz[i] = r.nextDouble() * 2 - 1;
    if (colored) rgb[i] = r.nextInt(256);
  }
  return SfmLiveSnapshot(
    xyz: xyz,
    rgb: rgb,
    posesPacked: Float64List(0),
    summary: const {},
    refined: true,
    obsOffsets: Int32List(0),
    obsFrameIds: Int32List(0),
    obsXY: Float32List(0),
  );
}

Widget host(
  SfmLiveSnapshot s, {
  String? octree,
  bool editing = false,
  SelectionBox? box,
}) => MaterialApp(
  localizationsDelegates: AppL10n.localizationsDelegates,
  supportedLocales: AppL10n.supportedLocales,
  home: Scaffold(
    body: Stack(
      children: [
        SfmPreviewOverlay(
          phase: SfmPreviewPhase.refined,
          snapshot: s,
          onBack: () {},
          onDone: () {},
          lodOctreeDir: octree,
          editing: editing,
          selectionBox: box,
          onBoxChanged: (_) {},
        ),
      ],
    ),
  ),
);

final _cpuPainter = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is SparseCloudPainter);
final _texture = find.byType(Texture);
final _view = find.byKey(const ValueKey('capture_preview_cloud'));

/// Lets the fake shell answer and the 250 ms stats poll run a few times (real async for file IO).
Future<void> settle(WidgetTester tester, [int rounds = 4]) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 300));
  }
}

/// Screen rows (x, y, w) of the last matrix sent — the part of the camera the eye sees.
List<double> screenRows(FakeLodPlatform f) {
  final m = (f.of('setCamera').last.arguments as Map)['view_proj_row_major'] as Float64List;
  return [...m.sublist(0, 8), ...m.sublist(12, 16)];
}

double maxDiff(List<double> a, List<double> b) {
  var d = 0.0;
  for (var i = 0; i < a.length; i++) {
    d = math.max(d, (a[i] - b[i]).abs());
  }
  return d;
}

/// A tree directory the way DenseLodCache leaves it (metadata.json is all the view reads).
String fakeTree(Directory root) {
  final d = Directory('${root.path}/cap_test')..createSync(recursive: true);
  File('${d.path}/metadata.json').writeAsStringSync(
    '{"version":"2.0","points":400,"boundingBox":{"min":[-1,-1,-1],"max":[1,1,1]}}',
  );
  return d.path;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeLodPlatform fake;
  late Directory tmp;

  setUp(() {
    fake = FakeLodPlatform()..install();
    tmp = Directory.systemTemp.createTempSync('one_viewer');
  });
  tearDown(() {
    FakeLodPlatform.uninstall();
    tmp.deleteSync(recursive: true);
  });

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
  }

  testWidgets('one view instance from sparse → growing dense → tree; the GPU camera is the view\'s', (tester) async {
    phone(tester);
    final sparse = snap(200, seed: 1), dense1 = snap(400, seed: 2), dense2 = snap(600, seed: 3);
    await tester.pumpWidget(host(sparse));
    await settle(tester);
    expect(_texture, findsOneWidget);
    expect(_cpuPainter, findsNothing);
    final state0 = tester.state(_view);
    final create = fake.of('create').single.arguments as Map;
    expect(create['viewport_width_px'], 1170); // physical, view is full width
    expect(create['viewport_height_px'], (844 - 96) * 3); // overlay's 96 px bottom padding
    expect((fake.of('setPoints').last.arguments as Map)['count'], 200);

    // user turns the cloud
    await tester.drag(_view, const Offset(60, -40));
    await settle(tester, 2);
    final cam = (tester.state(_view) as dynamic).debugCamera;

    // the GPU camera equals the view's own projection (same matrix the view would build)
    List<double> expectedRows() {
      final st = tester.state(_view) as dynamic;
      final proj = st.debugProjection();
      final f = lodCameraFrame(
        projection: proj,
        logicalSize: const Size(390, 748),
        viewportWidthPx: 1170,
        viewportHeightPx: 2244,
        sceneBoxMin: const [-1, -1, -1],
        sceneBoxMax: const [1, 1, 1],
      ).viewProjRowMajor;
      return [...f.sublist(0, 8), ...f.sublist(12, 16)];
    }

    expect(maxDiff(screenRows(fake), expectedRows()), lessThan(1e-9));

    // dense grows on the same page
    for (final d in [dense1, dense2]) {
      await tester.pumpWidget(host(d));
      await settle(tester, 2);
      expect(identical(tester.state(_view), state0), isTrue, reason: 'view rebuilt');
      expect((tester.state(_view) as dynamic).debugCamera, cam, reason: 'camera moved');
      expect((fake.of('setPoints').last.arguments as Map)['count'], d.xyz.length ~/ 3);
      expect(maxDiff(screenRows(fake), expectedRows()), lessThan(1e-9));
    }
    final beforeTree = screenRows(fake);

    // finished dense: the tree replaces the flat copy in the same view, camera untouched
    final tree = fakeTree(tmp);
    await tester.pumpWidget(host(dense2, octree: tree));
    await settle(tester);
    expect(identical(tester.state(_view), state0), isTrue);
    expect((fake.of('loadOctree').single.arguments as Map)['octree_dir'], tree);
    expect(fake.source, 2);
    expect((tester.state(_view) as dynamic).debugCamera, cam);
    expect(maxDiff(screenRows(fake), beforeTree), lessThan(1e-12), reason: 'picture jumped at the tree swap');
    expect(fake.of('create').length, 1, reason: 'one engine viewer for the whole page');

    // NEGATIVE: the same comparison sees a real camera change
    await tester.drag(_view, const Offset(80, 0));
    await settle(tester, 2);
    expect(maxDiff(screenRows(fake), beforeTree), greaterThan(1e-3));
  });

  testWidgets('sparse editing keeps its behaviour: tint while editing, cull while browsing, handles and pick in Dart', (tester) async {
    phone(tester);
    final s = snap(300, seed: 4);
    const box = SelectionBox(cx: 0, cy: 0, cz: 0, sx: 0.8, sy: 0.8, sz: 0.8);
    Map<Object?, Object?> lastStyle() => fake.of('setStyle').last.arguments as Map;

    await tester.pumpWidget(host(s, editing: true, box: box));
    await settle(tester);
    expect(_texture, findsOneWidget);
    expect(lastStyle()['selection_mode'], 1); // TINT_OUTSIDE (painter: cullOutsideSelection = !editing)
    expect((lastStyle()['selection_size'] as Float64List).toList(), [0.8, 0.8, 0.8]);
    expect(lastStyle()['selection_out_argb'], kSelectionOutColor & 0xFFFFFFFF);
    // the selection handles and the bottom fade are still drawn by Dart, over the texture
    expect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString() == 'RectHandlesPainter'), findsOneWidget);
    expect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is CloudBottomFadeMask), findsOneWidget);

    await tester.pumpWidget(host(s, box: box));
    await settle(tester, 2);
    expect(lastStyle()['selection_mode'], 2); // CULL_OUTSIDE
    expect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is CloudBottomFadeMask), findsNothing);
    await tester.pumpWidget(host(s));
    await settle(tester, 2);
    expect(lastStyle()['selection_mode'], 0);
    // NEGATIVE: the style really follows the page (a stuck mode would fail the first check)
    expect(fake.of('setStyle').map((c) => (c.arguments as Map)['selection_mode']).toSet(), {1, 2, 0});

    // double-tap pick still re-targets the orbit pivot on a cloud point (CPU path, no GPU read-back)
    final before = List<double>.of((tester.state(_view) as dynamic).debugPivot as List<double>);
    final c = tester.getCenter(_view);
    await tester.tapAt(c);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(c);
    await settle(tester, 3);
    final after = (tester.state(_view) as dynamic).debugPivot as List<double>;
    expect(maxDiff(after, before), greaterThan(1e-6));
    var onPoint = false;
    for (var i = 0; i < s.xyz.length; i += 3) {
      if (maxDiff([s.xyz[i], s.xyz[i + 1], s.xyz[i + 2]], after) < 1e-6) onPoint = true;
    }
    expect(onPoint, isTrue, reason: 'pivot must land on a cloud point');
  });

  testWidgets('hand-over: CPU painter until the engine has published a frame, never a blank', (tester) async {
    phone(tester);
    fake.publishFrames = false;
    await tester.pumpWidget(host(snap(100)));
    await settle(tester);
    expect(_cpuPainter, findsOneWidget);
    expect(_texture, findsNothing);
    fake.publishFrames = true;
    await settle(tester);
    expect(_texture, findsOneWidget);
    expect(_cpuPainter, findsNothing);
  });

  testWidgets('no GPU (no plugin / create fails) ⇒ the CPU painter keeps drawing', (tester) async {
    phone(tester);
    fake.createFails = true;
    await tester.pumpWidget(host(snap(100)));
    await settle(tester);
    expect(_cpuPainter, findsOneWidget);
    expect(_texture, findsNothing);
    FakeLodPlatform.uninstall(); // MissingPluginException path
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(host(snap(100, seed: 9)));
    await settle(tester);
    expect(_cpuPainter, findsOneWidget);
    expect(_texture, findsNothing);
  });

  testWidgets('octree that fails to load ⇒ stays on the flat set (logged, no crash)', (tester) async {
    phone(tester);
    fake.loadOctreeFails = true;
    final d = snap(400, seed: 5);
    await tester.pumpWidget(host(d));
    await settle(tester);
    final flatSends = fake.of('setPoints').length;
    await tester.pumpWidget(host(d, octree: fakeTree(tmp)));
    await settle(tester);
    expect(fake.of('loadOctree').length, 1);
    expect(fake.source, 1); // the engine still holds the flat set
    expect(_texture, findsOneWidget);
    expect(fake.of('setPoints').length, flatSends); // nothing re-sent, the flat set never left
  });

  group('full-screen viewer page (「稠密点云」, SparseCloudViewerPage), build 174 rules', () {
    late String ply, sparse, capDir;
    late Directory cacheRoot;

    setUp(() {
      capDir = '${tmp.path}/Documents/captures_official/cap_77';
      ply = writeDensePly('$capDir/official_dense.ply', 3000).path;
      sparse = writeDensePly('$capDir/official_sfm_sparse.ply', 300, seed: 9).path;
      cacheRoot = Directory('${tmp.path}/Library/Caches');
      denseStageProgress.value = null;
      SparseCloudViewerPage.debug172DenseDoneRule = false;
    });
    tearDown(() {
      denseStageProgress.value = null;
      SparseCloudViewerPage.debug172DenseDoneRule = false;
    });

    /// [idle] false when a test holds the build (fake.buildGate): waiting for the cache would hang.
    Future<void> openPage(WidgetTester tester, {String? path, bool idle = true}) async {
      phone(tester);
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            localizationsDelegates: AppL10n.localizationsDelegates,
            supportedLocales: AppL10n.supportedLocales,
            locale: const Locale('zh'),
            home: SparseCloudViewerPage(plyPath: path ?? ply, title: '稠密点云'),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 400));
        if (idle) await DenseLodCache.instance.whenIdle();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await settle(tester, 6);
    }

    Future<void> release(WidgetTester tester) async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await DenseLodCache.instance.whenIdle();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await settle(tester, 6);
    }

    void denseRanThisSession() => denseStageProgress.value = DenseStageProgress(
      captureDir: capDir,
      state: DenseStageState.done,
      outPly: ply,
    );

    final next = find.text('下一步');
    final bottomButton = find.byType(SfmBottomActionButton);

    final sparsePainter = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is SparseCloudPainter);

    testWidgets('complete dense PLY, no tree: the tree is built from that PLY, same view switches; no 下一步; [175] sparse never shown', (tester) async {
      DenseLodCache.instanceForTesting = DenseLodCache(cacheRoot: () async => cacheRoot);
      final gate = Completer<void>();
      fake.buildGate = gate.future;
      await openPage(tester, idle: false);
      expect((fake.of('setPoints').last.arguments as Map)['count'], 300); // the sparse sibling, not the dense PLY
      // [175] 「只要是有稠密点云的项目，打开就直接是稠密点云」: the sparse stand-in is held back
      expect(_texture, findsNothing);
      expect(sparsePainter, findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('正在准备稠密点云…'), findsOneWidget);
      expect(fake.methods, isNot(contains('loadOctree')));
      final build = fake.of('buildFromPly').single.arguments as Map;
      expect(build['ply_path'], ply);
      expect(build['out_dir'], '$capDir/lod.building');
      expect(next, findsNothing, reason: '「永远不会重新训练稠密」');
      expect(bottomButton, findsNothing, reason: 'the dense page is already the dense view');
      await tester.runAsync(() async => gate.complete());
      await release(tester);
      expect(fake.methods, containsAllInOrder(['buildFromPly', 'verifyOctree', 'loadOctree']));
      expect((fake.of('loadOctree').single.arguments as Map)['octree_dir'], '$capDir/lod');
      expect(fake.source, 2);
      expect(_texture, findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('正在准备稠密点云…'), findsNothing);
    });

    testWidgets('[175] valid tree: while it loads only the spinner (same place as the loading one), never the sparse cloud', (tester) async {
      final first = DenseLodCache(cacheRoot: () async => cacheRoot);
      first.watch(ply);
      await tester.runAsync(() => first.whenIdle());
      fake.calls.clear();
      DenseLodCache.instanceForTesting = DenseLodCache(cacheRoot: () async => cacheRoot);
      final gate = Completer<void>();
      fake.loadOctreeGate = gate.future;
      await openPage(tester);
      expect(fake.methods, contains('loadOctree'));
      expect(_texture, findsNothing);
      expect(sparsePainter, findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(tester.getCenter(find.byType(CircularProgressIndicator)), tester.getCenter(find.byType(Scaffold)),
          reason: 'the wait spinner sits where the loading spinner sat');
      expect(find.text('正在准备稠密点云…'), findsNothing, reason: 'the tree exists: nothing is being prepared');
      await tester.runAsync(() async => gate.complete());
      await release(tester);
      expect(fake.source, 2);
      expect(_texture, findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('NEGATIVE: build 172\'s rule put back is caught (no build, 下一步 over a complete dense PLY)', (tester) async {
      DenseLodCache.instanceForTesting = DenseLodCache(cacheRoot: () async => cacheRoot);
      SparseCloudViewerPage.debug172DenseDoneRule = true;
      await openPage(tester);
      expect(() => expect(fake.methods, contains('buildFromPly')), throwsA(isA<TestFailure>()));
      expect(() => expect(next, findsNothing), throwsA(isA<TestFailure>()));
    });

    testWidgets('tree fails its self-check ⇒ flat display stays, still no 下一步', (tester) async {
      DenseLodCache.instanceForTesting = DenseLodCache(cacheRoot: () async => cacheRoot);
      fake.buildLosesPoints = 1;
      await openPage(tester);
      expect(fake.methods, contains('buildFromPly'));
      expect(fake.methods, isNot(contains('loadOctree')));
      expect(fake.source, 1);
      expect(_texture, findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing, reason: '[175] the fallback shows at once, no spinner left up');
      expect(next, findsNothing);
    });

    testWidgets('dense ran this session ⇒ the same shared build; a good tree is loaded into the same view', (tester) async {
      DenseLodCache.instanceForTesting = DenseLodCache(cacheRoot: () async => cacheRoot);
      denseRanThisSession();
      await openPage(tester);
      expect(fake.of('buildFromPly').length, 1, reason: 'one build, shared');
      expect(fake.methods, containsAllInOrder(['buildFromPly', 'verifyOctree', 'loadOctree']));
      expect(fake.source, 2);
      expect((fake.of('loadOctree').single.arguments as Map)['octree_dir'], '$capDir/lod');
    });

    testWidgets('re-entry: a valid tree is used at once, nothing rebuilt', (tester) async {
      final first = DenseLodCache(cacheRoot: () async => cacheRoot);
      first.watch(ply);
      await tester.runAsync(() => first.whenIdle());
      fake.calls.clear();
      DenseLodCache.instanceForTesting = DenseLodCache(cacheRoot: () async => cacheRoot); // new session
      await openPage(tester);
      expect(fake.methods, isNot(contains('buildFromPly')));
      expect((fake.of('loadOctree').single.arguments as Map)['octree_dir'], '$capDir/lod');
      expect(fake.source, 2);
    });

    testWidgets('the sparse page of a work with a complete dense PLY offers 查看稠密点云, never 下一步', (tester) async {
      DenseLodCache.instanceForTesting = DenseLodCache(cacheRoot: () async => cacheRoot);
      await openPage(tester, path: sparse);
      expect(next, findsNothing);
      expect(find.text('查看稠密点云'), findsOneWidget);
      expect(fake.methods, isNot(contains('buildFromPly')), reason: 'the sparse page builds nothing');
    });

    final editButton = find.byKey(const ValueKey('viewer-enter-editing'));
    final finish = find.text('完成稠密');

    testWidgets('[174] a work that entered the dense stage has no 选区编辑 on either page', (tester) async {
      DenseLodCache.instanceForTesting = DenseLodCache(cacheRoot: () async => cacheRoot);
      await openPage(tester, path: sparse); // complete dense PLY (setUp)
      expect(editButton, findsNothing);
      await openPage(tester); // the dense page
      expect(editButton, findsNothing);
    });

    testWidgets('[174] dense PLY cut short (killed mid-training): the sparse page only finishes it — 「完成稠密」, no 选区编辑', (tester) async {
      DenseLodCache.instanceForTesting = DenseLodCache(cacheRoot: () async => cacheRoot);
      final bytes = File(ply).readAsBytesSync();
      File(ply).writeAsBytesSync(bytes.sublist(0, bytes.length - 15 * 10));
      await openPage(tester, path: sparse);
      expect(finish, findsOneWidget);
      expect(next, findsNothing);
      expect(find.text('查看稠密点云'), findsNothing);
      expect(editButton, findsNothing);
    });

    testWidgets('[174] NEGATIVE: a work that never tapped 下一步 keeps 选区编辑 and 下一步', (tester) async {
      DenseLodCache.instanceForTesting = DenseLodCache(cacheRoot: () async => cacheRoot);
      File(ply).deleteSync();
      await openPage(tester, path: sparse);
      expect(editButton, findsOneWidget);
      expect(next, findsOneWidget);
      expect(finish, findsNothing);
    });
  });

  test('the capture page wires the tree only while the finished dense cloud is on screen', () {
    // Source anchors (the page needs ARKit and cannot be pumped): comments stripped.
    String code(String p) =>
        File(p).readAsStringSync().split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n');
    final page = code('lib/ui/official_capture/ar_capture_page.dart');
    expect(page, contains('lodOctreeDir: _lodOctreeDirOnScreen,'));
    expect(page, contains('if (p.state == DenseStageState.done && p.outPly != null) _watchDenseLod(p.outPly!);'));
    final getter = page.indexOf('String? get _lodOctreeDirOnScreen {');
    expect(page.indexOf('if (_denseRunningHere || !_denseDoneHere) return null;', getter), greaterThan(getter));
    final review = page.indexOf('Future<void> _enterReviewMode(String dir) async {');
    // [172] re-entry LOOKS for a valid tree first (never decodes the dense PLY); [174] without one
    // it builds from the complete dense PLY on disk (_watchDenseLod) — never a dense run
    expect(page.indexOf('DenseLodCache.instance.findValid(densePly)', review), greaterThan(review));
    expect(page.indexOf('_watchDenseLod(doneThisSession ? p.outPly! : densePly);', review), greaterThan(review));
    final overlay = code('lib/ui/official_capture/sfm_preview_overlay.dart');
    expect(overlay, contains('gpu: true,'));
    expect(overlay, contains('octreeDir: lodOctreeDir,'));
    // the gallery card stays on the CPU painter
    final card = code('lib/ui/official_capture/auto_rotating_cloud_view.dart');
    expect(card.contains('gpu: true'), isFalse);
    // NEGATIVE: the anchor finder is not vacuous
    expect(page.contains('lodOctreeDir: _somethingElse,'), isFalse);
  });

  test('no LOD debug / M1 entry reaches production code', () {
    final lib = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .map((f) => f.readAsStringSync().split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n'))
        .join('\n');
    expect(lib.contains('LodDebugPage'), isFalse);
    expect(lib.contains('runBench'), isFalse);
    expect(lib.contains('lod_debug_page'), isFalse);
    // NEGATIVE: the scan sees the production LOD code it should see
    expect(lib.contains('class GpuCloudLayer'), isTrue);
    final plugin = File('ios/Runner/PwLodTexturePlugin.swift').readAsStringSync();
    expect(plugin.contains('pwlod_run('), isFalse);
    expect(plugin.contains('"runBench"'), isFalse);
    // services import keeps MissingPluginException in scope for readers of this test
    expect(MissingPluginException, isNotNull);
  });
}
