// [173] Engine A13 (Aether3D 72ee817f aether_cpp/src/pointcloud_lod_render/DEVIATIONS.md:269-275):
// pwlod_style / pwlod_camera are in TARGET pixels; a shell drawing at device pixel ratio d passes
// focal_px, point_size and max_sprite_scale multiplied by d. Build 172 passed logical values
// (user: 「每个点云的半径都变小了」 — 1/3 on a 3× iPhone).
//
// Judges:
//  1. On a 3× screen the real view → GpuCloudLayer → channel sends point_size 9, max_sprite_scale
//     3·50/16, focal_px 3·f, sprite_px 16 / disc 7 unchanged (NEGATIVE: the same judge rejects the
//     172 values; at 1× they are the logical values).
//  2. Radius parity with the REAL painter: for every point the painter draws (perspective, incl. the
//     Potree 50 px cap), the engine's disc radius from the header formula (pwlod_viewer.h pwlod_style
//     comment: radius = disc_radius_px_at_scale1 · scale, scale = point_size / sprite_px [· orbit /
//     divisor], capped at max_sprite_scale) with the wire values equals 3 × the painter's radius —
//     i.e. the painter on its 3× canvas. NEGATIVE: the 172 wire values give 1/3 of it.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/l10n/app_localizations.dart';
import 'package:pocketworld_flutter/official_capture/sfm_live_recon.dart';
import 'package:pocketworld_flutter/point_cloud_lod/lod_bridge.dart';
import 'package:pocketworld_flutter/ui/official_capture/cloud_camera.dart';
import 'package:pocketworld_flutter/ui/official_capture/sfm_preview_overlay.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_view.dart';

import 'fake_lod_platform.dart';

class _Atlas implements Canvas {
  Float32List? rst;
  @override
  void drawRawAtlas(ui.Image a, Float32List r, Float32List rects, Int32List? c, BlendMode? b, Rect? cull, Paint p) =>
      rst = Float32List.fromList(r);
  @override
  dynamic noSuchMethod(Invocation i) => throw StateError('unexpected ${i.memberName}');
}

SfmLiveSnapshot snap(int n) {
  final r = math.Random(4);
  final xyz = Float32List(n * 3), rgb = Uint8List(n * 3);
  for (var i = 0; i < n * 3; i++) {
    xyz[i] = r.nextDouble() * 2 - 1;
    rgb[i] = r.nextInt(256);
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

/// The engine's disc radius in target px from the style (pwlod_viewer.h v3 pwlod_style comment).
double engineRadius(Map<Object?, Object?> style, double orthoMix, double orbitOverDivisor) {
  final ps = (style['point_size'] as num).toDouble();
  final spr = (style['sprite_px'] as num).toDouble();
  final disc = (style['disc_radius_px_at_scale1'] as num).toDouble();
  final maxS = (style['max_sprite_scale'] as num).toDouble();
  final scale = orthoMix == 1.0 ? ps / spr : math.min(ps / spr * orbitOverDivisor, maxS);
  return disc * scale;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeLodPlatform fake;
  setUp(() => fake = FakeLodPlatform()..install());
  tearDown(FakeLodPlatform.uninstall);

  Future<void> pumpAt(WidgetTester tester, double dpr) async {
    tester.view.physicalSize = Size(390 * dpr, 844 * dpr);
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppL10n.localizationsDelegates,
        supportedLocales: AppL10n.supportedLocales,
        home: Scaffold(
          body: Stack(
            children: [
              SfmPreviewOverlay(phase: SfmPreviewPhase.refined, snapshot: snap(200), onBack: () {}, onDone: () {}),
            ],
          ),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  /// The A13 judge: the wire values are the logical ones × d.
  void expectTargetPixels(Map<Object?, Object?> style, Map<Object?, Object?> cam, double f, double d) {
    expect(style['point_size'], closeTo(3.0 * d, 1e-9));
    expect(style['max_sprite_scale'], closeTo(50 / 16 * d, 1e-9));
    expect(style['sprite_px'], 16.0); // R18 condition (viewer_look.cpp:184) untouched
    expect(style['disc_radius_px_at_scale1'], 7.0);
    expect(cam['focal_px'], closeTo(f * d, 1e-9));
  }

  testWidgets('3× screen: point_size, max_sprite_scale, focal_px are the logical values × 3', (tester) async {
    await pumpAt(tester, 3);
    final style = fake.of('setStyle').last.arguments as Map;
    final cam = fake.of('setCamera').last.arguments as Map;
    final st = tester.state(find.byKey(const ValueKey('capture_preview_cloud'))) as dynamic;
    final f = (st.debugProjection() as CloudProjection).f;
    expectTargetPixels(style, cam, f, 3);
    // NEGATIVE: the 172 wire (logical values) is rejected by the same judge
    expect(
      () => expectTargetPixels({...style, 'point_size': 3.0, 'max_sprite_scale': 50 / 16}, {...cam, 'focal_px': f}, f, 3),
      throwsA(isA<TestFailure>()),
    );
  });

  testWidgets('1× screen: the same values stay logical (the multiplier is the device pixel ratio)', (tester) async {
    await pumpAt(tester, 1);
    final style = fake.of('setStyle').last.arguments as Map;
    final cam = fake.of('setCamera').last.arguments as Map;
    final st = tester.state(find.byKey(const ValueKey('capture_preview_cloud'))) as dynamic;
    expectTargetPixels(style, cam, (st.debugProjection() as CloudProjection).f, 1);
  });

  testWidgets('radius parity with the real painter at 3× (perspective + Potree cap), NEGATIVE: 172 is 1/3', (tester) async {
    // A real view builds the painter's sprite; its painter gives the per-point scale it draws with.
    final s = snap(300);
    await tester.pumpWidget(MaterialApp(home: SizedBox(width: 390, height: 748, child: SparseCloudView(xyz: s.xyz, rgb: s.rgb))));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    final sprite = tester.widgetList<CustomPaint>(find.byType(CustomPaint)).map((w) => w.painter).whereType<SparseCloudPainter>().first.sprite!;
    final fit = SparseCloudPainter.fitOf(s.xyz);
    const size = Size(390, 748);
    // Eye INSIDE the cloud (at its centre): pivot = centre + camDist·row3 with camDist = 3 R, so the
    // points within camDist/16.7 of the eye hit the Potree 50/16 cap and the rest do not.
    const yaw = 0.4, pitch = -0.3;
    final r3 = [-math.sin(yaw) * math.cos(pitch), math.sin(pitch), math.cos(yaw) * math.cos(pitch)];
    final camDist = fit.radius * 3;
    final pivot = [fit.cx + camDist * r3[0], fit.cy + camDist * r3[1], fit.cz + camDist * r3[2]];
    final proj = CloudCamera(
      yaw: yaw,
      pitch: pitch,
      zoom: 0.3,
      panX: 0,
      panY: 0,
      pivotX: pivot[0],
      pivotY: pivot[1],
      pivotZ: pivot[2],
      radius: fit.radius,
      orthographic: true,
      camDistOverride: camDist,
      orthoMix: 0,
    ).projectionFor(size);
    // the wire style the shell sends at 3× (GpuCloudLayer: style.inTargetPixels(dpr))
    const logical = LodStyle(
      pointSize: 3,
      spritePx: 16,
      discRadiusPxAtScale1: 7,
      maxSpriteScale: kMaxPointSpriteScale,
      tone: LodTone.pbrNeutral,
      exposure: 1,
      uncoloredMinY: 0,
      uncoloredInvYSpan: 1,
      selectionOutArgb: kSelectionOutColor,
    );
    final wire3 = logical.inTargetPixels(3).toWire();
    final wire172 = logical.toWire();
    var drawn = 0, capped = 0;
    for (var i = 0; i < 300; i++) {
      final vis = Uint8List(300)..[i] = 1;
      final rec = _Atlas();
      SparseCloudPainter(
        xyz: s.xyz,
        rgb: s.rgb,
        visibility: vis,
        sprite: sprite,
        yaw: yaw,
        pitch: pitch,
        zoom: 0.3,
        panX: 0,
        panY: 0,
        pivotX: pivot[0],
        pivotY: pivot[1],
        pivotZ: pivot[2],
        pointSize: 3,
        exposure: 1,
        tone: 2,
        drawSelectionWireframe: false,
        orthographic: true,
        camDistOverride: camDist,
        orthoMix: 0,
      ).paint(rec, size);
      final r = rec.rst;
      if (r == null || r.isEmpty) continue;
      drawn++;
      final painterRadius3x = 3 * 7 * r[0]; // the painter on its 3× canvas
      final depth = proj.project(s.xyz[i * 3], s.xyz[i * 3 + 1], s.xyz[i * 3 + 2]).$3;
      final ratio = proj.camDist / proj.divisorAt(depth);
      if (r[0] == kMaxPointSpriteScale.toDouble()) capped++;
      expect(engineRadius(wire3, 0, ratio), closeTo(painterRadius3x, 1e-4 * painterRadius3x), reason: 'point $i');
      // NEGATIVE: the 172 wire values draw 1/3 of the radius
      expect((engineRadius(wire172, 0, ratio) - painterRadius3x).abs(), greaterThan(0.5 * painterRadius3x));
    }
    expect(drawn, greaterThan(20));
    expect(capped, greaterThan(0), reason: 'the cap branch must be exercised');
  });
}
