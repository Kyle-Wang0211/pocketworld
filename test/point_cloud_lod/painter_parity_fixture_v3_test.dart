// painter_parity_fixture_v3_test.dart — reference data for the GPU viewer (pwlod_viewer.h v3,
// pwlod_style / set_points) taken from the REAL product painter, not from a re-derivation.
//
// What runs: SparseCloudPainter from lib/ui/official_capture/sparse_cloud_view.dart (168 source
// 86a45cf), with the disc sprite of a real SparseCloudView (pumped, then read back off its
// CustomPaint), painting onto
//   (a) a canvas that records the arguments of the painter's single drawRawAtlas call — i.e. the
//       per-instance RSTransform (scale, 0, vx − 8·scale, vy − 8·scale), source rect and modulate
//       colour the painter actually hands to Skia/Impeller, in the painter's far → near order;
//   (b) a PictureRecorder canvas (black clear, as the view's Container) rasterised to PNG at 1× and
//       3× (3× = the phone's devicePixelRatio; the painter works in logical px).
// Per-point values come from painting the SAME painter once per point with a visibility mask that
// keeps only that point (the painter's own L2 mask path, lib/ui/official_capture/
// sparse_cloud_view.dart paint(): `if (vis != null && vis[i] == 0) continue;`), so point i's
// vx / vy / scale / argb are exactly what the full paint wrote for it; the test checks that the
// multiset of per-point records equals the full paint's atlas, bit for bit.
//
// Writes the fixture only when PW_PARITY_FIXTURE_OUT is set (the coordinator's location is
// ~/Developer/pw_lod_data/parity_fixture_v3/); otherwise it runs the same generation into a temp dir
// as a self-check and deletes nothing but that temp dir.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/selection_box.dart';
import 'package:pocketworld_flutter/ui/official_capture/cloud_camera.dart';
import 'package:pocketworld_flutter/ui/official_capture/sparse_cloud_view.dart';

/// Records the painter's drawRawAtlas; anything else the painter might call is a test failure.
class _AtlasRecorder implements Canvas {
  final List<({Float32List rst, Float32List rects, Int32List colors})> calls = [];

  @override
  void drawRawAtlas(
    ui.Image atlas,
    Float32List rstTransforms,
    Float32List rects,
    Int32List? colors,
    BlendMode? blendMode,
    Rect? cullRect,
    Paint paint,
  ) {
    calls.add((
      rst: Float32List.fromList(rstTransforms),
      rects: Float32List.fromList(rects),
      colors: Int32List.fromList(colors ?? Int32List(0)),
    ));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('painter called ${invocation.memberName} (only drawRawAtlas expected)');
}

/// Deterministic 32-bit LCG (Numerical Recipes constants) so the cloud is reproducible anywhere.
class _Lcg {
  _Lcg(this._s);
  int _s;
  double next() {
    _s = (1664525 * _s + 1013904223) & 0xFFFFFFFF;
    return _s / 4294967296.0;
  }
}

/// A small structured cloud: a sphere shell (object), a floor plane, a back wall and a few far
/// strays (so the painter's robust fit has something to reject). Colours cover dark, saturated
/// and over-bright values (PBR Neutral compresses above peak 0.76).
({Float32List xyz, Uint8List rgb}) _cloud(int n) {
  final r = _Lcg(20260924);
  final xyz = Float32List(n * 3);
  final rgb = Uint8List(n * 3);
  for (var i = 0; i < n; i++) {
    double x, y, z;
    int cr, cg, cb;
    final kind = i % 10;
    if (kind < 5) {
      // sphere shell r = 0.35 around (0, 0.35, 0)
      final u = r.next() * 2 - 1, t = r.next() * 2 * math.pi;
      final s = math.sqrt(1 - u * u);
      x = 0.35 * s * math.cos(t);
      y = 0.35 + 0.35 * u;
      z = 0.35 * s * math.sin(t);
      cr = (40 + 215 * (0.5 + 0.5 * u)).round();
      cg = (30 + 60 * r.next()).round();
      cb = (200 * (0.5 - 0.5 * u)).round();
    } else if (kind < 8) {
      // floor y = 0, 2 m × 2 m
      x = r.next() * 2 - 1;
      y = (r.next() - 0.5) * 0.004;
      z = r.next() * 2 - 1;
      final g = (90 + 60 * r.next()).round();
      cr = g;
      cg = g;
      cb = g - 10;
    } else if (kind < 9) {
      // back wall z = -1, bright (tone-map compression)
      x = r.next() * 2 - 1;
      y = r.next() * 1.4;
      z = -1 + (r.next() - 0.5) * 0.004;
      cr = 250;
      cg = (235 + 20 * r.next()).round().clamp(0, 255);
      cb = 220;
    } else {
      // clutter near the scene; 1 in 40 of these (0.25% of the cloud) a far stray, below the
      // painter's 99.5th-percentile framing radius so it frames the scene, not the strays
      final far = (i ~/ 10) % 40 == 0;
      final k = far ? 6.0 : 1.2;
      x = (r.next() * 2 - 1) * k;
      y = r.next() * k;
      z = (r.next() * 2 - 1) * k;
      cr = (255 * r.next()).round();
      cg = (255 * r.next()).round();
      cb = (255 * r.next()).round();
    }
    xyz[i * 3] = x;
    xyz[i * 3 + 1] = y;
    xyz[i * 3 + 2] = z;
    rgb[i * 3] = cr.clamp(0, 255);
    rgb[i * 3 + 1] = cg.clamp(0, 255);
    rgb[i * 3 + 2] = cb.clamp(0, 255);
  }
  return (xyz: xyz, rgb: rgb);
}

class _Cam {
  const _Cam(
    this.name, {
    required this.yaw,
    required this.pitch,
    this.roll = 0,
    this.zoom = 1,
    this.panX = 0,
    this.panY = 0,
    this.pivot,
    this.camDistOverrideRadii,
    this.camDistOverrideAbs,
    required this.orthoMix,
  });
  final String name;
  final double yaw, pitch, roll, zoom, panX, panY;

  /// null = orbitPivotOf(xyz) (the view's default pivot).
  final List<double>? pivot;

  /// camDistOverride in units of the painter's fit radius (null = the historical rig).
  final double? camDistOverrideRadii;

  /// camDistOverride in world units (wins over [camDistOverrideRadii]).
  final double? camDistOverrideAbs;

  double? camDistOverride(double radius) =>
      camDistOverrideAbs ?? (camDistOverrideRadii == null ? null : camDistOverrideRadii! * radius);
  final double orthoMix;
}

class _Look {
  const _Look(this.name, {this.selection = 'none', this.mask = 'none'});
  final String name;

  /// none | tint | cull (tint = editing: cullOutsideSelection false; cull = browsing: true).
  final String selection;

  /// none | every3rd_and_sphere_top | wrong_length
  final String mask;
}

const _kCams = <_Cam>[
  _Cam('ortho_default', yaw: math.pi, pitch: -math.pi / 4, orthoMix: 1),
  _Cam('ortho_zoom_pan', yaw: 0.7, pitch: -0.3, zoom: 2.3, panX: 30, panY: -45, orthoMix: 1),
  _Cam('persp_capture', yaw: 2.4, pitch: -0.35, zoom: 1.4, camDistOverrideRadii: 2.5, orthoMix: 0),
  _Cam('mix_0p5', yaw: 2.4, pitch: -0.35, zoom: 1.4, camDistOverrideRadii: 2.5, orthoMix: 0.5),
  _Cam('ortho_roll', yaw: -1.2, pitch: -0.9, roll: 0.6, zoom: 1.2, orthoMix: 1),
  _Cam('persp_roll_near', yaw: 0.3, pitch: -0.2, roll: -1.1, zoom: 3.0, panX: -20, camDistOverrideRadii: 1.3, orthoMix: 0),
  // Eye just in front of the sphere, looking +z (yaw 0, pitch 0 ⇒ row3 = +z; eye = pivot − camDist·row3
  // = (0, 0.35, −0.5)), wide angle (zoom 0.15): the sphere's near side (depth ≈ 0.15) hits the Potree
  // maxSize cap (scale 50/16), the floor and wall further away do not.
  _Cam('persp_maxsize', yaw: 0, pitch: 0, zoom: 0.15, pivot: [0, 0.35, 4.5], camDistOverrideAbs: 5.0, orthoMix: 0),
];

const _kLooks = <_Look>[
  _Look('plain'),
  _Look('tint', selection: 'tint'),
  _Look('cull', selection: 'cull'),
  _Look('mask', mask: 'every3rd_and_sphere_top'),
  _Look('mask_wrong_length', mask: 'wrong_length'),
];

/// (cloud, camera, look) groups written to the fixture.
List<(String, String, String)> _groups() => [
  for (final c in _kCams) ('colored', c.name, 'plain'),
  ('colored', 'persp_maxsize', 'tint'),
  for (final c in ['ortho_default', 'persp_capture', 'mix_0p5', 'ortho_roll'])
    for (final l in ['tint', 'cull', 'mask']) ('colored', c, l),
  ('colored', 'ortho_default', 'mask_wrong_length'),
  for (final c in ['ortho_default', 'persp_capture', 'mix_0p5'])
    for (final l in ['plain', 'tint']) ('uncolored', c, l),
];

const Size _kSize = Size(390, 748); // iPhone 14 Pro width; 844 − 96 (overlay bottom padding)
const double _kDpr = 3.0;
const int _kPoints = 1536;

// The view's look (SparseCloudView state fields, sparse_cloud_view.dart :382-384).
const double _kPointSize = 3.0;
const double _kExposure = 1.0;
const int _kTone = 2;

SelectionBox _box() => SelectionBox(
  cx: 0.1,
  cy: 0.3,
  cz: -0.05,
  sx: 0.9,
  sy: 0.7,
  sz: 1.1,
  rot: mulRot(rotAboutAxisDeg(const [0, 1, 0], 25), rotAboutAxisDeg(const [1, 0, 0], -10)),
);

Uint8List? _mask(String kind, Float32List xyz) {
  final n = xyz.length ~/ 3;
  switch (kind) {
    case 'none':
      return null;
    case 'wrong_length':
      return Uint8List(n - 1); // all zero, but the wrong length ⇒ the painter ignores it
    default:
      final m = Uint8List(n);
      for (var i = 0; i < n; i++) {
        final sphereTop = i % 10 < 5 && xyz[i * 3 + 1] > 0.5;
        m[i] = (i % 3 == 0 || sphereTop) ? 0 : 1;
      }
      return m;
  }
}

SparseCloudPainter _painter({
  required Float32List xyz,
  required Uint8List rgb,
  required ui.Image sprite,
  required _Cam cam,
  required _Look look,
  required List<double> pivot,
  required double radius,
  Uint8List? visibility,
}) {
  final sel = look.selection == 'none' ? null : _box();
  return SparseCloudPainter(
    xyz: xyz,
    rgb: rgb,
    visibility: visibility,
    sprite: sprite,
    yaw: cam.yaw,
    pitch: cam.pitch,
    roll: cam.roll,
    zoom: cam.zoom,
    panX: cam.panX,
    panY: cam.panY,
    pivotX: pivot[0],
    pivotY: pivot[1],
    pivotZ: pivot[2],
    pointSize: _kPointSize,
    exposure: _kExposure,
    tone: _kTone,
    selectionBox: sel,
    cullOutsideSelection: look.selection == 'cull',
    drawSelectionWireframe: false, // what SparseCloudView passes (sparse_cloud_view.dart build())
    orthographic: kCloudOrthographic,
    camDistOverride: cam.camDistOverride(radius),
    orthoMix: cam.orthoMix,
  );
}

({Float32List rst, Float32List rects, Int32List colors})? _record(SparseCloudPainter p) {
  final rec = _AtlasRecorder();
  p.paint(rec, _kSize);
  expect(rec.calls.length, lessThanOrEqualTo(1));
  return rec.calls.isEmpty ? null : rec.calls.single;
}

Future<Uint8List> _png(SparseCloudPainter p, double dpr) async {
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.scale(dpr);
  c.drawRect(Offset.zero & _kSize, Paint()..color = const Color(0xFF000000));
  p.paint(c, _kSize);
  final pic = rec.endRecording();
  final img = await pic.toImage((_kSize.width * dpr).round(), (_kSize.height * dpr).round());
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  img.dispose();
  pic.dispose();
  return bd!.buffer.asUint8List();
}

String _key(double s, double tx, double ty, int argb) => '$s|$tx|$ty|$argb';

Future<Map<String, Object?>> _generate(Directory out, ui.Image sprite) async {
  out.createSync(recursive: true);
  final base = _cloud(_kPoints);
  final clouds = <String, ({Float32List xyz, Uint8List rgb})>{
    'colored': base,
    'uncolored': (xyz: base.xyz, rgb: Uint8List(base.rgb.length)),
  };
  final fit = SparseCloudPainter.fitOf(base.xyz);
  final ramp = SparseCloudPainter.heightRampOf(base.xyz);
  final pivot0 = orbitPivotOf(base.xyz);

  for (final e in clouds.entries) {
    File('${out.path}/cloud_${e.key}.json').writeAsStringSync(
      jsonEncode({
        'n': e.value.xyz.length ~/ 3,
        'xyz_float32': [for (final v in e.value.xyz) v],
        'rgb_u8': e.value.rgb.toList(),
      }),
    );
  }
  final sb = _box();
  final summary = <Map<String, Object?>>[];
  for (final (cloudName, camName, lookName) in _groups()) {
    final cloud = clouds[cloudName]!;
    final cam = _kCams.firstWhere((c) => c.name == camName);
    final look = _kLooks.firstWhere((l) => l.name == lookName);
    final pivot = cam.pivot ?? pivot0;
    final mask = _mask(look.mask, cloud.xyz);
    final n = cloud.xyz.length ~/ 3;
    final full = _painter(
      xyz: cloud.xyz,
      rgb: cloud.rgb,
      sprite: sprite,
      cam: cam,
      look: look,
      pivot: pivot,
      radius: fit.radius,
      visibility: mask,
    );
    final atlas = _record(full);
    final m = atlas == null ? 0 : atlas.colors.length;
    // draw-order lookup of the full paint
    final order = <String, List<int>>{};
    for (var k = 0; k < m; k++) {
      order
          .putIfAbsent(
            _key(atlas!.rst[k * 4], atlas.rst[k * 4 + 2], atlas.rst[k * 4 + 3], atlas.colors[k]),
            () => [],
          )
          .add(k);
    }
    // per point: the same painter with a one-point mask (AND the look's own mask)
    final baseMask = mask != null && mask.length == n ? mask : null;
    final points = <Map<String, Object?>>[];
    var drawn = 0;
    final used = <int>{};
    for (var i = 0; i < n; i++) {
      final one = Uint8List(n);
      one[i] = (baseMask == null || baseMask[i] != 0) ? 1 : 0;
      final solo = _record(
        _painter(
          xyz: cloud.xyz,
          rgb: cloud.rgb,
          sprite: sprite,
          cam: cam,
          look: look,
          pivot: pivot,
          radius: fit.radius,
          visibility: one,
        ),
      );
      if (solo == null) {
        points.add({'i': i, 'drawn': false});
        continue;
      }
      expect(solo.colors.length, 1);
      final s = solo.rst[0], tx = solo.rst[2], ty = solo.rst[3], argb = solo.colors[0];
      final ks = order[_key(s, tx, ty, argb)] ?? const <int>[];
      final k = ks.firstWhere((k) => !used.contains(k), orElse: () => -1);
      expect(k, isNot(-1), reason: '$cloudName/$camName/$lookName point $i not in the full paint');
      used.add(k);
      drawn++;
      points.add({
        'i': i,
        'drawn': true,
        'vx': tx + s * 8.0,
        'vy': ty + s * 8.0,
        'scale': s,
        'argb': argb & 0xFFFFFFFF,
        'draw_order': k,
        'rst': [s, solo.rst[1], tx, ty],
      });
    }
    // every atlas instance of the full paint is accounted for by exactly one point
    expect(drawn, m, reason: '$cloudName/$camName/$lookName');
    final proj = CloudCamera(
      yaw: cam.yaw,
      pitch: cam.pitch,
      zoom: cam.zoom,
      panX: cam.panX,
      panY: cam.panY,
      pivotX: pivot[0],
      pivotY: pivot[1],
      pivotZ: pivot[2],
      radius: fit.radius,
      fillK: SparseCloudPainter.fitFillK,
      orthographic: kCloudOrthographic,
      roll: cam.roll,
      camDistOverride: cam.camDistOverride(fit.radius),
      orthoMix: cam.orthoMix,
    ).projectionFor(_kSize);
    final name = '${cloudName}__${camName}__$lookName';
    File('${out.path}/$name.png').writeAsBytesSync(await _png(full, 1));
    File('${out.path}/${name}_3x.png').writeAsBytesSync(await _png(full, _kDpr));
    final group = <String, Object?>{
      'schema': 'pw_painter_parity_fixture/v3',
      'name': name,
      'cloud': 'cloud_$cloudName.json',
      'colored': cloudName == 'colored',
      'size_logical': [_kSize.width, _kSize.height],
      'png_1x': '$name.png',
      'png_3x': '${name}_3x.png',
      'png_3x_device_pixel_ratio': _kDpr,
      'png_background_argb': 0xFF000000,
      'camera': {
        'yaw': cam.yaw,
        'pitch': cam.pitch,
        'roll': cam.roll,
        'zoom': cam.zoom,
        'pan_x': cam.panX,
        'pan_y': cam.panY,
        'pivot': pivot,
        'cam_dist_override': cam.camDistOverride(fit.radius),
        'ortho_mix': cam.orthoMix,
        'orthographic_flag': kCloudOrthographic,
        'fill_k': SparseCloudPainter.fitFillK,
        'fit_radius': fit.radius,
      },
      'projection': {
        'cos_y': proj.cosY,
        'sin_y': proj.sinY,
        'cos_p': proj.cosP,
        'sin_p': proj.sinP,
        'f': proj.f,
        'cam_dist': proj.camDist,
        'ox': proj.ox,
        'oy': proj.oy,
        'pivot': [proj.pivotX, proj.pivotY, proj.pivotZ],
        'ortho_mix': proj.orthoMix,
        'cos_r': proj.cosR,
        'sin_r': proj.sinR,
      },
      'style': {
        'point_size': _kPointSize,
        'sprite_px': 16.0,
        'disc_radius_px_at_scale1': 7.0,
        'max_sprite_scale': kMaxPointSpriteScale,
        'tone': _kTone,
        'exposure': _kExposure,
        'uncolored_min_y': ramp.minY,
        'uncolored_inv_y_span': ramp.invYSpan,
        'selection_mode': look.selection,
        if (look.selection != 'none') ...{
          'selection_center': [sb.cx, sb.cy, sb.cz],
          'selection_size': [sb.sx, sb.sy, sb.sz],
          'selection_rot_row_major': sb.rot,
        },
        'selection_out_argb': kSelectionOutColor,
        'near_cull_depth': fit.radius * 0.02,
        'offscreen_margin_px': 24,
      },
      'visibility': {
        'kind': look.mask,
        if (mask != null) 'length': mask.length,
        if (mask != null) 'mask_u8': mask.toList(),
      },
      'atlas': {
        'instances': m,
        'rst': atlas == null ? const <double>[] : [for (final v in atlas.rst) v],
        'rects': atlas == null ? const <double>[] : [for (final v in atlas.rects) v],
        'colors_argb': atlas == null ? const <int>[] : [for (final v in atlas.colors) v & 0xFFFFFFFF],
      },
      'points': points,
    };
    File('${out.path}/$name.json').writeAsStringSync(jsonEncode(group));
    summary.add({'name': name, 'points': n, 'drawn': drawn});
  }
  final index = <String, Object?>{
    'schema': 'pw_painter_parity_fixture_index/v3',
    'generator': 'test/point_cloud_lod/painter_parity_fixture_v3_test.dart',
    'painter': 'lib/ui/official_capture/sparse_cloud_view.dart SparseCloudPainter',
    'contract': 'pwlod_viewer.h v3 sha256 4e867aa338c40f1d4c2389626b8de790083ce5cf62441a7349aa1bc19a3b8509',
    'fit': {'cx': fit.cx, 'cy': fit.cy, 'cz': fit.cz, 'radius': fit.radius},
    'height_ramp': {'min_y': ramp.minY, 'inv_y_span': ramp.invYSpan},
    'orbit_pivot': pivot0,
    'groups': summary,
    'notes': [
      'vx = rst[2] + 8*scale, vy = rst[3] + 8*scale (anchor = scale * 8, sprite 16 px).',
      'argb is the modulate colour handed to drawRawAtlas (white sprite x colour).',
      'draw_order = index in the full paint (far -> near; painter sorts by depth descending).',
      'drawn=false: the painter skipped the point (visibility mask, CULL, near cull depth <= 0.02 R, or > 24 px off screen).',
      'PNG = the painter on a black clear; 3x = canvas.scale(3) like the phone.',
    ],
  };
  File('${out.path}/index.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(index));
  return index;
}

void main() {
  testWidgets('painter parity fixture v3 (real SparseCloudPainter + real view sprite)', (tester) async {
    // A real SparseCloudView builds the sprite the painter draws with.
    final c = _cloud(64);
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 200,
          height: 300,
          child: SparseCloudView(xyz: c.xyz, rgb: c.rgb, showControls: false),
        ),
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump();
    final painter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<SparseCloudPainter>()
        .first;
    final sprite = painter.sprite;
    expect(sprite, isNotNull, reason: 'the view must have built its sprite');
    expect(sprite!.width, 16);
    expect(sprite.height, 16);

    final target = Platform.environment['PW_PARITY_FIXTURE_OUT'];
    final tmp = target == null ? Directory.systemTemp.createTempSync('pw_parity_v3_') : null;
    final out = Directory(target ?? tmp!.path);
    try {
      final index = await tester.runAsync(() => _generate(out, sprite));
      final groups = (index!['groups'] as List).cast<Map<String, Object?>>();
      expect(groups.length, _groups().length);
      // Non-vacuous: every group drew something, and the looks really differ.
      for (final g in groups) {
        expect(g['drawn'] as int, greaterThan(0), reason: '${g['name']}');
      }
      int drawnOf(String n) => groups.firstWhere((g) => g['name'] == n)['drawn'] as int;
      // CULL drops points TINT keeps (TINT only recolours).
      expect(drawnOf('colored__ortho_default__cull'), lessThan(drawnOf('colored__ortho_default__tint')));
      expect(drawnOf('colored__ortho_default__tint'), drawnOf('colored__ortho_default__plain'));
      // A mask of the right length hides points; a wrong-length mask is ignored (painter rule).
      expect(drawnOf('colored__ortho_default__mask'), lessThan(drawnOf('colored__ortho_default__plain')));
      expect(drawnOf('colored__ortho_default__mask_wrong_length'), drawnOf('colored__ortho_default__plain'));
      // TINT really paints kSelectionOutColor; plain never does.
      Map<String, Object?> read(String n) =>
          jsonDecode(File('${out.path}/$n.json').readAsStringSync()) as Map<String, Object?>;
      int redCount(String n) => ((read(n)['atlas'] as Map)['colors_argb'] as List)
          .where((c) => c == (kSelectionOutColor & 0xFFFFFFFF))
          .length;
      expect(redCount('colored__ortho_default__tint'), greaterThan(0));
      expect(redCount('colored__ortho_default__plain'), 0);
      // Uncoloured = height ramp: all three channels equal.
      final unc = ((read('uncolored__ortho_default__plain')['atlas'] as Map)['colors_argb'] as List).cast<int>();
      expect(unc.every((c) => ((c >> 16) & 0xFF) == ((c >> 8) & 0xFF) && ((c >> 8) & 0xFF) == (c & 0xFF)), isTrue);
      final col = ((read('colored__ortho_default__plain')['atlas'] as Map)['colors_argb'] as List).cast<int>();
      expect(col.any((c) => ((c >> 16) & 0xFF) != (c & 0xFF)), isTrue);
      // Perspective scales vary with depth; orthographic scale is the constant pointSize / 16.
      List<double> scales(String n) => [
        for (final p in (read(n)['points'] as List).cast<Map<String, Object?>>())
          if (p['drawn'] == true) (p['scale'] as num).toDouble(),
      ];
      expect(scales('colored__ortho_default__plain').toSet(), {_kPointSize / 16.0});
      expect(scales('colored__persp_capture__plain').toSet().length, greaterThan(10));
      expect(File('${out.path}/colored__mix_0p5__plain_3x.png').lengthSync(), greaterThan(1000));
      // The Potree maxSize cap (kMaxPointSpriteScale) is exercised, and not everywhere.
      final capped = scales('colored__persp_maxsize__plain');
      expect(capped.where((s) => s == kMaxPointSpriteScale).length, greaterThan(0));
      expect(capped.where((s) => s < kMaxPointSpriteScale).length, greaterThan(0));
    } finally {
      if (tmp != null) tmp.deleteSync(recursive: true);
    }
  });
}
