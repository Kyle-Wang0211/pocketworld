// Judges for lib/point_cloud_lod/lod_camera.dart (pwlod_viewer.h v3). Each positive check has a
// negative control that must trip the same checker, so a checker that cannot fail is caught.
// [v3 2026-09-24] Rewritten from feat/lod-viewer@56f3bb9: the camera is now built from the view's
// CloudProjection itself (incl. orthoMix, camDistOverride, roll); the LodSceneFit and Potree near/far
// groups are kept from that revision.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/point_cloud_lod/lod_camera.dart';
import 'package:pocketworld_flutter/point_cloud_lod/lod_scene_fit.dart';
import 'package:pocketworld_flutter/ui/official_capture/cloud_camera.dart';

/// Aether3D tests/pointcloud_lod/test_select.cpp:51-61 @d251451 `lookAt` (row-major), for the
/// hand-evaluated Potree near/far lines.
List<double> _lookAt(List<double> eye, List<double> target, List<double> up) {
  List<double> norm(List<double> v) {
    final l = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return [v[0] / l, v[1] / l, v[2] / l];
  }

  List<double> cross(List<double> a, List<double> b) => [
    a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2],
    a[0] * b[1] - a[1] * b[0],
  ];
  double dot(List<double> a, List<double> b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  final f = norm([target[0] - eye[0], target[1] - eye[1], target[2] - eye[2]]);
  final s = norm(cross(f, up));
  final u = cross(s, f);
  return [
    s[0], s[1], s[2], -dot(s, eye), //
    u[0], u[1], u[2], -dot(u, eye), //
    -f[0], -f[1], -f[2], dot(f, eye), //
    0, 0, 0, 1,
  ];
}

class _Case {
  _Case(this.proj, this.size, this.points, this.pivot, this.radius);
  final CloudProjection proj;
  final Size size;
  final List<List<double>> points; // inside the fit sphere
  final List<double> pivot;
  final double radius;

  /// A cube whose bounding sphere is exactly the fit sphere (half-diagonal = radius).
  List<double> get boxMin => [for (final c in pivot) c - radius / math.sqrt(3)];
  List<double> get boxMax => [for (final c in pivot) c + radius / math.sqrt(3)];
}

/// Random views of the product rig: [mix] = CloudProjection.orthoMix (1 ortho, 0 perspective,
/// between = the LIVE-WAIT morph); odd cases carry roll, every third a camDistOverride (the
/// capture-pose start puts the eye at the capture camera).
List<_Case> _cases({required double mix, int n = 60, int seed = 20260924}) {
  final rng = math.Random(seed);
  double u(double a, double b) => a + (b - a) * rng.nextDouble();
  final out = <_Case>[];
  for (var i = 0; i < n; i++) {
    final radius = u(0.05, 40);
    final pivot = [u(-100, 100), u(-100, 100), u(-100, 100)];
    final size = Size(u(200, 1400), u(200, 1400));
    final proj = CloudCamera(
      yaw: u(-math.pi, math.pi),
      pitch: u(-math.pi / 2 + 0.02, math.pi / 2 - 0.02),
      roll: i.isEven ? 0.0 : u(-math.pi, math.pi),
      zoom: u(0.15, 20),
      panX: u(-300, 300),
      panY: u(-300, 300),
      pivotX: pivot[0],
      pivotY: pivot[1],
      pivotZ: pivot[2],
      radius: radius,
      orthographic: true, // kCloudOrthographic; the divisor follows orthoMix
      camDistOverride: i % 3 == 0 ? radius * u(1.5, 10) : null,
      orthoMix: mix,
    ).projectionFor(size);
    final pts = <List<double>>[];
    while (pts.length < 40) {
      final d = [u(-1, 1), u(-1, 1), u(-1, 1)];
      if (d[0] * d[0] + d[1] * d[1] + d[2] * d[2] > 1) continue;
      pts.add([
        pivot[0] + d[0] * radius,
        pivot[1] + d[1] * radius,
        pivot[2] + d[2] * radius,
      ]);
    }
    out.add(_Case(proj, size, pts, pivot, radius));
  }
  return out;
}

LodCameraFrame _frame(_Case c) => lodCameraFrame(
  projection: c.proj,
  logicalSize: c.size,
  viewportWidthPx: 3 * c.size.width.round(),
  viewportHeightPx: 3 * c.size.height.round(),
  sceneBoxMin: c.boxMin,
  sceneBoxMax: c.boxMax,
);

/// Screen pixel of [p] through a row-major world→clip matrix; null when w <= 0.
(double, double, double)? _screen(List<double> m, List<double> p, Size size) {
  double row(int r) => m[r * 4] * p[0] + m[r * 4 + 1] * p[1] + m[r * 4 + 2] * p[2] + m[r * 4 + 3];
  final w = row(3);
  if (w <= 0) return null;
  return (size.width / 2 * (1 + row(0) / w), size.height / 2 * (1 - row(1) / w), row(2) / w);
}

/// Worst pixel distance between the matrix and CloudProjection.project over the case's points
/// that are in front of the eye (depth > 2% radius, the painter's own cull) — the judge.
double _worstPx(List<double> m, _Case c) {
  var worst = 0.0;
  for (final p in c.points) {
    final (ox, oy, depth) = c.proj.project(p[0], p[1], p[2]);
    if (depth <= c.radius * 0.02) continue;
    final s = _screen(m, p, c.size);
    if (s == null) return double.infinity;
    final e = math.sqrt(math.pow(s.$1 - ox, 2) + math.pow(s.$2 - oy, 2)).toDouble();
    if (e > worst) worst = e;
  }
  return worst;
}

double _maxAbsDiff(List<double> a, List<double> b) {
  var m = 0.0;
  for (var i = 0; i < a.length; i++) {
    m = math.max(m, (a[i] - b[i]).abs());
  }
  return m;
}

void main() {
  group('matrix = CloudProjection.project (v3: every orthoMix, roll, camDistOverride)', () {
    for (final mix in [1.0, 0.0, 0.25, 0.5, 0.8]) {
      test('orthoMix $mix: same pixels for every point in front of the eye', () {
        var checked = 0;
        for (final c in _cases(mix: mix)) {
          final f = _frame(c);
          final worst = _worstPx(f.viewProjRowMajor, c);
          // 1e-6 px relative to the scale of the numbers involved
          expect(worst, lessThan(1e-6 * math.max(1.0, c.proj.f / 100)), reason: 'mix $mix');
          checked++;
        }
        expect(checked, 60);
      });
    }

    test('NEGATIVE: an endpoint matrix used mid-morph is off by pixels (the checker sees it)', () {
      var caught = 0;
      final mids = _cases(mix: 0.5, seed: 99);
      final ends = _cases(mix: 1.0, seed: 99); // identical cameras, only orthoMix differs
      for (var i = 0; i < mids.length; i++) {
        final wrong = _frame(ends[i]).viewProjRowMajor;
        if (_worstPx(wrong, mids[i]) > 1.0) caught++;
      }
      expect(caught, greaterThan(50));
    });

    test('NEGATIVE: a transposed matrix and a roll-less matrix are caught', () {
      final rolled = _cases(mix: 1.0, seed: 5).where((c) => c.proj.sinR.abs() > 0.2).first;
      final f = _frame(rolled).viewProjRowMajor;
      final t = Float64List(16);
      for (var r = 0; r < 4; r++) {
        for (var k = 0; k < 4; k++) {
          t[k * 4 + r] = f[r * 4 + k];
        }
      }
      expect(_worstPx(t, rolled), greaterThan(1.0));
      final noRoll = CloudCamera(
        yaw: math.atan2(rolled.proj.sinY, rolled.proj.cosY),
        pitch: math.atan2(rolled.proj.sinP, rolled.proj.cosP),
        zoom: 1,
        panX: rolled.proj.ox - rolled.size.width / 2,
        panY: rolled.proj.oy - rolled.size.height / 2,
        pivotX: rolled.pivot[0],
        pivotY: rolled.pivot[1],
        pivotZ: rolled.pivot[2],
        radius: rolled.radius,
        orthographic: true,
        orthoMix: 1,
      ).projectionFor(rolled.size);
      final wrongRoll = lodCameraFrame(
        projection: noRoll,
        logicalSize: rolled.size,
        viewportWidthPx: 3,
        viewportHeightPx: 3,
        sceneBoxMin: rolled.boxMin,
        sceneBoxMax: rolled.boxMax,
      ).viewProjRowMajor;
      expect(_worstPx(wrongRoll, rolled), greaterThan(1.0));
    });

    test('pwlod_camera scalars are the projection\'s; eye = pivot − camDist·row3 (depth 0)', () {
      for (final mix in [1.0, 0.0, 0.5]) {
        for (final c in _cases(mix: mix, n: 10, seed: 7)) {
          final f = _frame(c);
          expect(f.focalPx, c.proj.f);
          expect(f.orbitDistance, c.proj.camDist);
          expect(f.orthoMix, mix);
          expect(f.viewportWidthPx, 3 * c.size.width.round());
          final (_, _, depth) = c.proj.project(f.eyeWorld[0], f.eyeWorld[1], f.eyeWorld[2]);
          expect(depth.abs(), lessThan(1e-9 * math.max(1.0, c.proj.camDist)));
        }
      }
    });

    test('clip z/w rises with depth and lies in [0, 1] between near and far', () {
      for (final mix in [1.0, 0.0, 0.5]) {
        for (final c in _cases(mix: mix, n: 20, seed: 13)) {
          final f = _frame(c);
          final zs = <(double, double)>[];
          for (final p in c.points) {
            final depth = c.proj.project(p[0], p[1], p[2]).$3;
            if (depth <= f.near || depth >= f.far) continue;
            final s = _screen(f.viewProjRowMajor, p, c.size)!;
            expect(s.$3, inInclusiveRange(-1e-9, 1 + 1e-9));
            zs.add((depth, s.$3));
          }
          zs.sort((a, b) => a.$1.compareTo(b.$1));
          for (var i = 1; i < zs.length; i++) {
            expect(zs[i].$2, greaterThanOrEqualTo(zs[i - 1].$2 - 1e-12));
          }
        }
      }
    });
  });

  group('LodSceneFit = Potree fitToScreen sphere of metadata boundingBox', () {
    // Trimmed from ~/Developer/pw_lod_data/oct_prod/metadata.json (PotreeConverter 2.0).
    const bbMin = [-7.6491875648498535, -11.163127899169922, -4.17525053024292];
    const bbMax = [11.090600490570068, 7.57666015625, 14.564537525177002];
    String meta({
      List<double> posMin = const [
        -7.64918756027688,
        -11.163127899169922,
        -4.175250532160115,
      ],
      List<double> posMax = const [
        5.2376065208481695,
        7.57666015625,
        12.987323762903523,
      ],
      List<double> min = bbMin,
      List<double> max = bbMax,
    }) =>
        '''
{"version":"2.0","points":36232793,
 "boundingBox":{"min":$min,"max":$max},
 "attributes":[{"name":"position","size":12,"numElements":3,"elementSize":4,"type":"int32",
   "min":$posMin,"max":$posMax},
  {"name":"rgb","size":6,"numElements":3,"elementSize":2,"type":"uint16",
   "min":[0,0,0],"max":[65535,65535,65535]}]}''';

    test(
      'box = metadata boundingBox; sphere = three.js r124 getBoundingSphere',
      () {
        final fit = LodSceneFit.fromMetadataJson(meta());
        expect(fit.points, 36232793);
        expect(fit.boxMin, bbMin);
        expect(fit.boxMax, bbMax);
        for (var i = 0; i < 3; i++) {
          expect(fit.pivot[i], (bbMin[i] + bbMax[i]) * 0.5);
        }
        final s = [for (var i = 0; i < 3; i++) bbMax[i] - bbMin[i]];
        expect(
          fit.radius,
          math.sqrt(s[0] * s[0] + s[1] * s[1] + s[2] * s[2]) * 0.5,
        );
        // every box corner sits exactly on the sphere
        for (var c = 0; c < 8; c++) {
          final p = [
            for (var i = 0; i < 3; i++) (c >> i) & 1 == 0 ? bbMin[i] : bbMax[i],
          ];
          final d = math.sqrt(
            [
              for (var i = 0; i < 3; i++)
                math.pow(p[i] - fit.pivot[i], 2).toDouble(),
            ].reduce((a, b) => a + b),
          );
          expect((d - fit.radius).abs(), lessThan(1e-12));
        }
      },
    );

    test(
      'NEGATIVE: the position attribute extent is ignored (OctreeLoader.js:405-406)',
      () {
        final a = LodSceneFit.fromMetadataJson(meta());
        final b = LodSceneFit.fromMetadataJson(
          meta(posMin: const [0, 0, 0], posMax: const [1, 1, 1]),
        );
        expect(b.pivot, a.pivot);
        expect(b.radius, a.radius);
        // ...while the boundingBox is not: move it and the fit moves.
        final c = LodSceneFit.fromMetadataJson(
          meta(min: const [0.0, 0.0, 0.0], max: const [2.0, 2.0, 2.0]),
        );
        expect(c.pivot, [1.0, 1.0, 1.0]);
        expect(c.radius, closeTo(math.sqrt(3), 1e-15));
      },
    );

    test('rejects metadata without a usable boundingBox', () {
      expect(() => LodSceneFit.fromMetadataJson('[]'), throwsFormatException);
      expect(
        () => LodSceneFit.fromMetadataJson('{"points":1}'),
        throwsFormatException,
      );
      expect(
        () => LodSceneFit.fromMetadataJson(
          '{"attributes":[{"name":"position","min":[0,0,0],"max":[1,1,1]}]}',
        ),
        throwsFormatException,
      );
      expect(
        () => LodSceneFit.fromMetadataJson(
          '{"boundingBox":{"min":[0,0,0],"max":[-1,2,2]}}',
        ),
        throwsFormatException,
      );
    });
  });

  group('near/far = Potree Viewer.update (viewer.js:1749-1771 @5636cd4)', () {
    // Camera at (0,0,10) looking at the origin; box [-1,1]^3 ⇒ farthest corner at view z −11.
    final view = _lookAt(const [0, 0, 10], const [0, 0, 0], const [0, 1, 0]);
    const bmin = [-1.0, -1.0, -1.0], bmax = [1.0, 1.0, 1.0];
    ({double near, double far}) nf(
      double ls, {
      bool ortho = false,
      List<double>? mn,
      List<double>? mx,
    }) => potreeNearFar(
      lowestSpacing: ls,
      viewRowMajor: view,
      boxMin: mn ?? bmin,
      boxMax: mx ?? bmax,
      orthographic: ortho,
    );

    test('hand-evaluated Potree lines', () {
      // lowestSpacing unknown ⇒ keep Scene.js:21-22's 0.1 / 1000*1000
      expect(nf(double.infinity), (near: 0.1, far: 1000000.0));
      // near = min(100, max(0.01, 0.0005*10)) = 0.01; far = max(11*1.5, 10000) = 10000;
      // far = max(far, near + 10000) = 10000.01
      expect(nf(0.0005), (near: 0.01, far: 10000.01));
      expect(nf(2), (near: 20.0, far: 10020.0));
      expect(nf(50), (near: 100.0, far: 10100.0)); // near clamped at 100
      // box [-5000,5000]^3 seen from z = 10: far corner view z = −5010 ⇒ max(7515, 10000) ⇒ 10010
      expect(
        nf(1, mn: const [-5000, -5000, -5000], mx: const [5000, 5000, 5000]),
        (near: 10.0, far: 10010.0),
      );
      final far = nf(
        1,
        mn: const [-50000, -50000, -50000],
        mx: const [50000, 50000, 50000],
      );
      expect(far.far, 50010 * 1.5);
      // orthographic: near = −far after either branch (:1769-1771)
      expect(nf(double.infinity, ortho: true), (
        near: -1000000.0,
        far: 1000000.0,
      ));
      expect(nf(2, ortho: true), (near: -10020.0, far: 10020.0));
    });

    /// The requested judge: no corner of the scene box may fall behind the far plane (clip
    /// z/w > 1); in orthographic mode none may fall in front of near either (z/w < 0).
    List<String> clippedCorners(
      List<double> m,
      List<double> mn,
      List<double> mx,
      bool ortho,
    ) {
      final bad = <String>[];
      for (var c = 0; c < 8; c++) {
        final p = [
          for (var i = 0; i < 3; i++) (c >> i) & 1 == 0 ? mn[i] : mx[i],
        ];
        double row(int r) =>
            m[r * 4] * p[0] +
            m[r * 4 + 1] * p[1] +
            m[r * 4 + 2] * p[2] +
            m[r * 4 + 3];
        final z = row(2) / row(3);
        if (z > 1 + 1e-12 || (ortho && z < -1e-12)) bad.add('corner $c z=$z');
      }
      return bad;
    }

    test(
      'real frames: no box corner is cut by far (both branches, both projections)',
      () {
        final rng = math.Random(5);
        for (final mix in [1.0, 0.0, 0.5]) {
          final ortho = mix == 1.0;
          for (final c in _cases(mix: mix, seed: 77)) {
            for (final ls in [double.infinity, 1e-4 + rng.nextDouble()]) {
              final f = lodCameraFrame(
                projection: c.proj,
                logicalSize: c.size,
                viewportWidthPx: 3,
                viewportHeightPx: 3,
                sceneBoxMin: c.boxMin,
                sceneBoxMax: c.boxMax,
                lowestSpacing: ls,
              );
              expect(
                clippedCorners(f.viewProjRowMajor, c.boxMin, c.boxMax, ortho),
                isEmpty,
              );
              if (ortho) expect(f.near, -f.far);
            }
          }
        }
      },
    );

    test('stats lowest_spacing <= 0 (empty queue) is Potree\'s Infinity', () {
      expect(potreeLowestSpacingFromStats(0.0), double.infinity);
      expect(potreeLowestSpacingFromStats(-1.0), double.infinity);
      expect(potreeLowestSpacingFromStats(double.nan), double.infinity);
      expect(potreeLowestSpacingFromStats(0.002), 0.002);
    });

    test(
      'unknown branch keeps the camera\'s previous near/far (viewer.js:1766-1768)',
      () {
        ({double near, double far}) prev(bool ortho) => potreeNearFar(
          lowestSpacing: double.infinity,
          viewRowMajor: view,
          boxMin: bmin,
          boxMax: bmax,
          orthographic: ortho,
          previousNear: 5,
          previousFar: 20000,
        );
        expect(prev(false), (near: 5.0, far: 20000.0));
        expect(prev(true), (near: -20000.0, far: 20000.0));
        // NEGATIVE: the known branch ignores the previous values
        final known = potreeNearFar(
          lowestSpacing: 2,
          viewRowMajor: view,
          boxMin: bmin,
          boxMax: bmax,
          orthographic: false,
          previousNear: 5,
          previousFar: 20000,
        );
        expect(known, (near: 20.0, far: 10020.0));
      },
    );

    test(
      'lodCameraFrame: known spacing changes the planes, unknown keeps previous',
      () {
        final c = _cases(mix: 1.0, n: 1, seed: 3).single;
        LodCameraFrame frame(
          double ls, {
          double pn = kPotreeInitialNear,
          double pf = kPotreeInitialFar,
        }) => lodCameraFrame(
          projection: c.proj,
          logicalSize: c.size,
          viewportWidthPx: 3,
          viewportHeightPx: 3,
          sceneBoxMin: c.boxMin,
          sceneBoxMax: c.boxMax,
          lowestSpacing: ls,
          previousNear: pn,
          previousFar: pf,
        );
        final unknown = frame(double.infinity);
        expect(
          (unknown.near, unknown.far),
          (-kPotreeInitialFar, kPotreeInitialFar),
        );
        final known = frame(0.002);
        // c.radius < 40 ⇒ 1.5·(farthest corner) < 10000 ⇒ far = max(10000, 0.02 + 10000)
        expect((known.near, known.far), (-10000.02, 10000.02));
        final kept = frame(double.infinity, pn: known.near, pf: known.far);
        expect((kept.near, kept.far), (known.near, known.far));
        expect(kept.viewProjRowMajor, known.viewProjRowMajor);
        // NEGATIVE: the two branches give different matrices (a test that mixed them up fails)
        expect(
          _maxAbsDiff(unknown.viewProjRowMajor, known.viewProjRowMajor),
          greaterThan(0),
        );
      },
    );

    test('NEGATIVE: a far plane in front of the farthest corner is reported', () {
      // The same checker on frames whose kept (unknown-branch) far plane is too short.
      final c = _cases(mix: 0.0, n: 1, seed: 11).single;
      final good = lodCameraFrame(
        projection: c.proj,
        logicalSize: c.size,
        viewportWidthPx: 3,
        viewportHeightPx: 3,
        sceneBoxMin: c.boxMin,
        sceneBoxMax: c.boxMax,
      );
      expect(clippedCorners(good.viewProjRowMajor, c.boxMin, c.boxMax, false), isEmpty);
      // farthest box corner depth
      var maxDepth = 0.0;
      for (var k = 0; k < 8; k++) {
        final pt = [for (var i = 0; i < 3; i++) (k >> i) & 1 == 0 ? c.boxMin[i] : c.boxMax[i]];
        maxDepth = math.max(maxDepth, c.proj.project(pt[0], pt[1], pt[2]).$3);
      }
      final short = lodCameraFrame(
        projection: c.proj,
        logicalSize: c.size,
        viewportWidthPx: 3,
        viewportHeightPx: 3,
        sceneBoxMin: c.boxMin,
        sceneBoxMax: c.boxMax,
        previousNear: 1e-3,
        previousFar: maxDepth * 0.9,
      );
      expect(clippedCorners(short.viewProjRowMajor, c.boxMin, c.boxMax, false), isNotEmpty);
    });
  });
}
