// Widget judges for lib/ui/official_capture/lod_cloud_view.dart over a mocked channel:
// the page creates the texture at its PHYSICAL size, every setCamera carries that same
// viewport, the default is orthographic, gestures send a new matrix, and the toggle sends
// perspective. Negative controls: the first camera is not the dragged one; a disposed page
// disposes its texture.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/point_cloud_lod/lod_bridge.dart';
import 'package:pocketworld_flutter/point_cloud_lod/lod_camera.dart';
import 'package:pocketworld_flutter/point_cloud_lod/lod_scene_fit.dart';
import 'package:pocketworld_flutter/ui/official_capture/cloud_camera.dart';
import 'package:pocketworld_flutter/ui/official_capture/lod_cloud_view.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_view.dart'
    show kCloudOrthographic;
import 'package:pocketworld_flutter/ui/sparse_thumbnail.dart'
    show kSparseThumbPitch, kSparseThumbYaw;

/// Snippets the LOD page copies from the old viewer (sparse_cloud_view.dart:294, :722-757).
/// Each must appear verbatim in BOTH files.
const List<String> kCopiedGestureSnippets = [
  'math.pi / 2 - 0.02',
  '_panX += d.focalPointDelta.dx;',
  '_panY += d.focalPointDelta.dy;',
  '(_zoom * (1 + (d.scale - 1) * 0.08)).clamp(',
  '0.15,',
  '20.0,',
  '_yaw -= d.focalPointDelta.dx * 0.008;',
  '(_pitch + d.focalPointDelta.dy * 0.006).clamp(',
  'if (d.pointerCount >= 2) {',
];

/// Whitespace-insensitive "contains".
bool containsCode(String haystack, String needle) => haystack
    .replaceAll(RegExp(r'\s+'), '')
    .contains(needle.replaceAll(RegExp(r'\s+'), ''));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(kPwLodChannel);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  late Directory oct;
  Map<String, Object>? statsReply;

  setUp(() {
    calls.clear();
    statsReply = null;
    oct = Directory.systemTemp.createTempSync('lod_view_oct');
    File('${oct.path}/metadata.json').writeAsStringSync(
      '{"points":1000,"boundingBox":{"min":[-1,-2,-3],"max":[3,2,1]}}',
    );
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'stats') return statsReply;
      if (call.method == 'create') {
        final a = call.arguments as Map;
        return {
          'textureId': 5,
          'version': 'deadbeef abi=1',
          'backend': 5,
          'viewport_width_px': a['viewport_width_px'],
          'viewport_height_px': a['viewport_height_px'],
        };
      }
      return null;
    });
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    oct.deleteSync(recursive: true);
  });

  test('pinned defaults equal the old viewer\'s constants', () {
    expect(kLodDefaultOrthographic, kCloudOrthographic);
    expect(kLodDefaultYaw, kSparseThumbYaw);
    expect(kLodDefaultPitch, kSparseThumbPitch);
  });

  test('gesture constants are the old viewer\'s, verbatim in both sources', () {
    final old = File(
      'lib/ui/official_capture/sparse_cloud_view.dart',
    ).readAsStringSync();
    final mine = File(
      'lib/ui/official_capture/lod_cloud_view.dart',
    ).readAsStringSync();
    for (final snippet in kCopiedGestureSnippets) {
      expect(
        containsCode(old, snippet),
        isTrue,
        reason: 'old viewer lost "$snippet"',
      );
      expect(
        containsCode(mine, snippet),
        isTrue,
        reason: 'LOD page lost "$snippet"',
      );
    }
    // NEGATIVE: the checker is not vacuous — a drifted coefficient is not found.
    expect(containsCode(old, '_yaw -= d.focalPointDelta.dx * 0.009;'), isFalse);
    expect(
      containsCode(mine, '(_zoom * (1 + (d.scale - 1) * 0.1)).clamp('),
      isFalse,
    );
  });

  testWidgets(
    'create at physical size; camera viewport = targets; drag + toggle',
    (tester) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: LodCloudView(octreeDir: oct.path, showStats: false),
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();

      final create =
          calls.firstWhere((c) => c.method == 'create').arguments as Map;
      expect(create['viewport_width_px'], 1170);
      expect(create['viewport_height_px'], 2532);
      expect(
        calls.map((c) => c.method),
        containsAll(['create', 'setParams', 'loadOctree']),
      );
      expect(
        (calls.firstWhere((c) => c.method == 'loadOctree').arguments
            as Map)['octree_dir'],
        oct.path,
      );

      final cams = calls.where((c) => c.method == 'setCamera').toList();
      expect(cams, isNotEmpty);
      final first = cams.last.arguments as Map;
      expect(first['projection'], 1); // orthographic by default
      expect(first['viewport_width_px'], 1170);
      expect(first['viewport_height_px'], 2532);
      final vp0 = Float64List.fromList(
        first['view_proj_row_major'] as Float64List,
      );

      // one-finger drag = orbit
      await tester.dragFrom(const Offset(200, 400), const Offset(80, 30));
      await tester.pump();
      final dragged =
          calls.where((c) => c.method == 'setCamera').last.arguments as Map;
      final vp1 = dragged['view_proj_row_major'] as Float64List;
      var differs = false;
      for (var i = 0; i < 16; i++) {
        if ((vp1[i] - vp0[i]).abs() > 1e-9) differs = true;
      }
      expect(
        differs,
        isTrue,
        reason: 'NEGATIVE: an orbit must change the matrix',
      );
      expect(dragged['viewport_width_px'], 1170);

      await tester.tap(find.text('正交'));
      await tester.pump();
      final toggled =
          calls.where((c) => c.method == 'setCamera').last.arguments as Map;
      expect(toggled['projection'], 0);
      expect(toggled['fov_y_degrees'] as double, greaterThan(0));

      await tester.pumpWidget(const SizedBox());
      expect(calls.last.method, 'dispose');
      expect((calls.last.arguments as Map)['textureId'], 5);
    },
  );

  /// Mounts the page at 390×844 logical (1170×2532 px), lets create/load/camera settle, then
  /// lets the real 250 ms stats timer fire once with [ls] as lowest_spacing.
  Future<({Float64List before, Float64List after})> runWithStats(
    WidgetTester tester,
    double ls,
  ) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.runAsync(() async {
      await tester.pumpWidget(
        MaterialApp(home: LodCloudView(octreeDir: oct.path, showStats: false)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    Float64List lastCam() => Float64List.fromList(
      (calls.where((c) => c.method == 'setCamera').last.arguments
              as Map)['view_proj_row_major']
          as Float64List,
    );
    final before = lastCam();
    statsReply = {
      'frame_number': 7,
      'completed_frame_number': 6,
      'points_drawn': 1000,
      'nodes_drawn': 3,
      'nodes_loading': 0,
      'uploads_this_frame': 0,
      'dropped_for_cache': 0,
      'min_node_pixel_size': 150.0,
      'cpu_ms': 1.0,
      'gpu_ms': 2.0,
      'lowest_spacing': ls,
    };
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 400)),
    );
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(calls.where((c) => c.method == 'stats'), isNotEmpty);
    final after = lastCam();
    await tester.pumpWidget(const SizedBox());
    return (before: before, after: after);
  }

  /// What the page must send for its default pose with a given lowestSpacing.
  Float64List expected(double ls) {
    final fit = LodSceneFit.fromMetadataJson(
      File('${oct.path}/metadata.json').readAsStringSync(),
    );
    return lodCameraFrame(
      camera: CloudCamera(
        yaw: kLodDefaultYaw,
        pitch: kLodDefaultPitch,
        zoom: 1,
        panX: 0,
        panY: 0,
        pivotX: fit.pivot[0],
        pivotY: fit.pivot[1],
        pivotZ: fit.pivot[2],
        radius: fit.radius,
        orthographic: true,
      ),
      logicalSize: const Size(390, 844),
      viewportWidthPx: 1170,
      viewportHeightPx: 2532,
      sceneBoxMin: fit.boxMin,
      sceneBoxMax: fit.boxMax,
      lowestSpacing: ls,
    ).viewProjRowMajor;
  }

  double maxDiff(List<double> a, List<double> b) {
    var d = 0.0;
    for (var i = 0; i < 16; i++) {
      d = math.max(d, (a[i] - b[i]).abs());
    }
    return d;
  }

  testWidgets(
    'stats lowest_spacing > 0 ⇒ Potree known branch (viewer.js:1749-1765)',
    (tester) async {
      final r = await runWithStats(tester, 0.002);
      final unknown = expected(double.infinity), known = expected(0.002);
      expect(
        maxDiff(r.before, unknown),
        lessThan(1e-12),
      ); // before any stats: unknown branch
      expect(
        maxDiff(r.after, known),
        lessThan(1e-12),
      ); // after the poll: known branch
      // NEGATIVE: the two branches are distinguishable, so the checks above can fail
      expect(maxDiff(known, unknown), greaterThan(1e-9));
    },
  );

  testWidgets(
    'NEGATIVE: stats lowest_spacing <= 0 stays in the unknown branch',
    (tester) async {
      final r = await runWithStats(tester, 0.0);
      expect(maxDiff(r.after, expected(double.infinity)), lessThan(1e-12));
      expect(maxDiff(r.after, expected(0.002)), greaterThan(1e-9));
    },
  );
}
