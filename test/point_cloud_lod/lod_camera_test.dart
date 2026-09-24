// Judges for lib/point_cloud_lod/lod_camera.dart. Each positive check has a negative
// control that must trip the same checker, so a checker that cannot fail is caught.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/point_cloud_lod/lod_camera.dart';
import 'package:pocketworld_flutter/point_cloud_lod/lod_scene_fit.dart';
import 'package:pocketworld_flutter/ui/official_capture/cloud_camera.dart';

class _Case {
  _Case(this.cam, this.size, this.points);
  final CloudCamera cam;
  final Size size;
  final List<List<double>> points; // inside the fit sphere

  /// A cube whose three.js bounding sphere is exactly the fit sphere (half-diagonal = radius).
  List<double> get boxMin => [
    cam.pivotX - cam.radius / math.sqrt(3),
    cam.pivotY - cam.radius / math.sqrt(3),
    cam.pivotZ - cam.radius / math.sqrt(3),
  ];
  List<double> get boxMax => [
    cam.pivotX + cam.radius / math.sqrt(3),
    cam.pivotY + cam.radius / math.sqrt(3),
    cam.pivotZ + cam.radius / math.sqrt(3),
  ];
}

List<_Case> _cases({
  required bool orthographic,
  int n = 60,
  int seed = 20260924,
}) {
  final rng = math.Random(seed);
  double u(double a, double b) => a + (b - a) * rng.nextDouble();
  final out = <_Case>[];
  for (var i = 0; i < n; i++) {
    final radius = u(0.05, 40);
    final pivot = [u(-100, 100), u(-100, 100), u(-100, 100)];
    final cam = CloudCamera(
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
      orthographic: orthographic,
    );
    final size = Size(u(200, 1400), u(200, 1400));
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
    out.add(_Case(cam, size, pts));
  }
  return out;
}

/// Row-major world -> clip -> the old viewer's screen pixels (y down).
(double, double, double, double) _screen(
  List<double> m,
  List<double> p,
  Size s,
) {
  double row(int r) =>
      m[r * 4] * p[0] +
      m[r * 4 + 1] * p[1] +
      m[r * 4 + 2] * p[2] +
      m[r * 4 + 3];
  final w = row(3);
  final nx = row(0) / w, ny = row(1) / w, nz = row(2) / w;
  return (s.width / 2 * (1 + nx), s.height / 2 * (1 - ny), nz, w);
}

/// Max pixel disagreement between a matrix and CloudProjection.project over a case.
double _maxPixelError(
  List<double> m,
  _Case c, {
  required CloudProjection oldViewer,
}) {
  var worst = 0.0;
  for (final p in c.points) {
    final (sx, sy, _) = oldViewer.project(p[0], p[1], p[2]);
    final (mx, my, _, _) = _screen(m, p, c.size);
    worst = math.max(worst, math.max((mx - sx).abs(), (my - sy).abs()));
  }
  return worst;
}

Float64List _transpose(List<double> m) {
  final t = Float64List(16);
  for (var r = 0; r < 4; r++) {
    for (var c = 0; c < 4; c++) {
      t[c * 4 + r] = m[r * 4 + c];
    }
  }
  return t;
}

/// The old viewer's orthographic formula (cloud_camera.dart:99-113) written directly as
/// a 4×4 affine map — an independent construction of the expected matrix.
Float64List _closedFormOrtho(
  CloudCamera cam,
  Size size,
  double near,
  double far,
) {
  final p = cam.projectionFor(size);
  final w = size.width, h = size.height;
  final k = p.f / p.camDist;
  final r1 = [p.cosY, 0.0, p.sinY];
  final r2 = [p.sinY * p.sinP, p.cosP, -p.cosY * p.sinP];
  final r3 = [-p.sinY * p.cosP, p.sinP, p.cosY * p.cosP];
  final s = [-r1[0], -r1[1], -r1[2]]; // screen right
  final sr = [for (var i = 0; i < 3; i++) p.cosR * s[i] + p.sinR * r2[i]];
  final ur = [for (var i = 0; i < 3; i++) -p.sinR * s[i] + p.cosR * r2[i]];
  final piv = [p.pivotX, p.pivotY, p.pivotZ];
  double dot(List<double> a, List<double> b) =>
      a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  // depth = r3·(x − pivot) + camDist
  final r3p = dot(r3, piv);
  return Float64List.fromList([
    2 * k / w * sr[0],
    2 * k / w * sr[1],
    2 * k / w * sr[2],
    -2 * k / w * dot(sr, piv) + 2 * cam.panX / w,
    2 * k / h * ur[0],
    2 * k / h * ur[1],
    2 * k / h * ur[2],
    -2 * k / h * dot(ur, piv) - 2 * cam.panY / h,
    r3[0] / (far - near),
    r3[1] / (far - near),
    r3[2] / (far - near),
    (-r3p + p.camDist - near) / (far - near),
    0,
    0,
    0,
    1,
  ]);
}

/// Aether3D src/pointcloud_lod/select.cpp:40-52 @d251451 (the engine's frustum from a
/// row-major WebGPU view-projection), unnormalized: a point is inside iff all >= 0.
bool _insideEngineFrustum(List<double> m, List<double> p) {
  double r(int i, int j) => m[i * 4 + j];
  final planes = <List<double>>[
    [for (var j = 0; j < 4; j++) r(3, j) - r(0, j)],
    [for (var j = 0; j < 4; j++) r(3, j) + r(0, j)],
    [for (var j = 0; j < 4; j++) r(3, j) + r(1, j)],
    [for (var j = 0; j < 4; j++) r(3, j) - r(1, j)],
    [for (var j = 0; j < 4; j++) r(3, j) - r(2, j)],
    [for (var j = 0; j < 4; j++) r(2, j)],
  ];
  for (final pl in planes) {
    if (pl[0] * p[0] + pl[1] * p[1] + pl[2] * p[2] + pl[3] < 0) return false;
  }
  return true;
}

double _maxAbsDiff(List<double> a, List<double> b) {
  var d = 0.0;
  for (var i = 0; i < 16; i++) {
    d = math.max(d, (a[i] - b[i]).abs());
  }
  return d;
}

double _maxAbs(List<double> a) => a.fold(0.0, (m, v) => math.max(m, v.abs()));

void main() {
  const pxTol = 1e-6; // pixels; observed max is printed

  group('orthographic (default, kCloudOrthographic = true)', () {
    final cases = _cases(orthographic: true);

    test('same pixels as CloudProjection.project for every point', () {
      var worst = 0.0;
      for (final c in cases) {
        final f = lodCameraFrame(
          camera: c.cam,
          logicalSize: c.size,
          viewportWidthPx: 3,
          viewportHeightPx: 3,
          sceneBoxMin: c.boxMin,
          sceneBoxMax: c.boxMax,
        );
        final e = _maxPixelError(
          f.viewProjRowMajor,
          c,
          oldViewer: c.cam.projectionFor(c.size),
        );
        worst = math.max(worst, e);
      }
      // ignore: avoid_print
      print('ortho max |Δpx| = $worst');
      expect(worst, lessThan(pxTol));
    });

    test(
      'NEGATIVE: the perspective matrix does NOT reproduce the ortho viewer',
      () {
        var worst = 0.0;
        for (final c in cases) {
          final persp = CloudCamera(
            yaw: c.cam.yaw,
            pitch: c.cam.pitch,
            roll: c.cam.roll,
            zoom: c.cam.zoom,
            panX: c.cam.panX,
            panY: c.cam.panY,
            pivotX: c.cam.pivotX,
            pivotY: c.cam.pivotY,
            pivotZ: c.cam.pivotZ,
            radius: c.cam.radius,
          );
          final f = lodCameraFrame(
            camera: persp,
            logicalSize: c.size,
            viewportWidthPx: 3,
            viewportHeightPx: 3,
            sceneBoxMin: c.boxMin,
            sceneBoxMax: c.boxMax,
          );
          worst = math.max(
            worst,
            _maxPixelError(
              f.viewProjRowMajor,
              c,
              oldViewer: c.cam.projectionFor(c.size),
            ),
          );
        }
        // ignore: avoid_print
        print('perspective-vs-ortho max |Δpx| = $worst');
        expect(worst, greaterThan(1.0));
      },
    );

    test(
      'NEGATIVE: a transposed matrix is caught by the same pixel checker',
      () {
        var worst = 0.0;
        for (final c in cases) {
          final f = lodCameraFrame(
            camera: c.cam,
            logicalSize: c.size,
            viewportWidthPx: 3,
            viewportHeightPx: 3,
            sceneBoxMin: c.boxMin,
            sceneBoxMax: c.boxMax,
          );
          worst = math.max(
            worst,
            _maxPixelError(
              _transpose(f.viewProjRowMajor),
              c,
              oldViewer: c.cam.projectionFor(c.size),
            ),
          );
        }
        expect(worst, greaterThan(1.0));
      },
    );

    test('element-wise equal to the old formula written as a matrix', () {
      var worstRel = 0.0;
      for (final c in cases) {
        final f = lodCameraFrame(
          camera: c.cam,
          logicalSize: c.size,
          viewportWidthPx: 3,
          viewportHeightPx: 3,
          sceneBoxMin: c.boxMin,
          sceneBoxMax: c.boxMax,
        );
        final ref = _closedFormOrtho(c.cam, c.size, f.near, f.far);
        worstRel = math.max(
          worstRel,
          _maxAbsDiff(f.viewProjRowMajor, ref) / _maxAbs(ref),
        );
      }
      // ignore: avoid_print
      print('ortho element-wise max rel diff = $worstRel');
      expect(worstRel, lessThan(1e-12));
    });

    test('NEGATIVE: the perspective matrix is element-wise different', () {
      final c = cases.first;
      final persp = CloudCamera(
        yaw: c.cam.yaw,
        pitch: c.cam.pitch,
        zoom: c.cam.zoom,
        panX: c.cam.panX,
        panY: c.cam.panY,
        pivotX: c.cam.pivotX,
        pivotY: c.cam.pivotY,
        pivotZ: c.cam.pivotZ,
        radius: c.cam.radius,
      );
      final f = lodCameraFrame(
        camera: persp,
        logicalSize: c.size,
        viewportWidthPx: 3,
        viewportHeightPx: 3,
        sceneBoxMin: c.boxMin,
        sceneBoxMax: c.boxMax,
      );
      final ref = _closedFormOrtho(c.cam, c.size, f.near, f.far);
      expect(
        _maxAbsDiff(f.viewProjRowMajor, ref) / _maxAbs(ref),
        greaterThan(1e-3),
      );
    });

    test('clip z is the old depth, linearly mapped into WebGPU [0, 1]', () {
      var worst = 0.0;
      for (final c in cases) {
        final f = lodCameraFrame(
          camera: c.cam,
          logicalSize: c.size,
          viewportWidthPx: 3,
          viewportHeightPx: 3,
          sceneBoxMin: c.boxMin,
          sceneBoxMax: c.boxMax,
        );
        final old = c.cam.projectionFor(c.size);
        for (final p in c.points) {
          final (_, _, depth) = old.project(p[0], p[1], p[2]);
          final (_, _, z, w) = _screen(f.viewProjRowMajor, p, c.size);
          expect(w, 1.0);
          expect(
            z,
            inInclusiveRange(0.0, 1.0),
          ); // A1: nothing the old viewer draws is clipped
          worst = math.max(
            worst,
            (z - (depth - f.near) / (f.far - f.near)).abs(),
          );
        }
      }
      expect(worst, lessThan(1e-12));
    });

    test(
      'ortho fields: frustum width/height, no fov, Cesium pixel size = old px size',
      () {
        for (final c in cases) {
          final f = lodCameraFrame(
            camera: c.cam,
            logicalSize: c.size,
            viewportWidthPx: 1179,
            viewportHeightPx: 2556,
            sceneBoxMin: c.boxMin,
            sceneBoxMax: c.boxMax,
          );
          final old = c.cam.projectionFor(c.size);
          expect(f.projection, LodProjection.orthographic);
          expect(f.projection.wireValue, 1); // PWLOD_PROJ_ORTHOGRAPHIC
          expect(f.fovYDegrees, 0);
          // one logical pixel of the old viewer, in world units (cloud_camera.dart
          // worldPerPixelAt, depth-independent in ortho)
          final wpp = old.worldPerPixelAt(123.0);
          expect(
            (f.orthoWidthWorld - c.size.width * wpp).abs(),
            lessThan(1e-9 * f.orthoWidthWorld),
          );
          expect(
            (f.orthoHeightWorld - c.size.height * wpp).abs(),
            lessThan(1e-9 * f.orthoHeightWorld),
          );
          expect(f.viewportWidthPx, 1179);
          expect(f.viewportHeightPx, 2556);
          // eye = pivot − camDist·row3 (in front of every scene point)
          final (_, _, dPivot) = old.project(
            c.cam.pivotX,
            c.cam.pivotY,
            c.cam.pivotZ,
          );
          expect((dPivot - old.camDist).abs(), lessThan(1e-9 * old.camDist));
          final (_, _, dEye) = old.project(
            f.eyeWorld[0],
            f.eyeWorld[1],
            f.eyeWorld[2],
          );
          expect(dEye.abs(), lessThan(1e-9 * old.camDist));
        }
      },
    );

    test(
      'engine frustum (select.cpp) keeps on-screen points, rejects off-screen',
      () {
        var inside = 0, outside = 0;
        final rng = math.Random(7);
        for (final c in _cases(orthographic: true, n: 20, seed: 99)) {
          final f = lodCameraFrame(
            camera: c.cam,
            logicalSize: c.size,
            viewportWidthPx: 3,
            viewportHeightPx: 3,
            sceneBoxMin: c.boxMin,
            sceneBoxMax: c.boxMax,
          );
          final old = c.cam.projectionFor(c.size);
          for (var i = 0; i < 400; i++) {
            final r = c.cam.radius * 3;
            final p = [
              c.cam.pivotX + (rng.nextDouble() * 2 - 1) * r,
              c.cam.pivotY + (rng.nextDouble() * 2 - 1) * r,
              c.cam.pivotZ + (rng.nextDouble() * 2 - 1) * r,
            ];
            final (sx, sy, depth) = old.project(p[0], p[1], p[2]);
            final onScreen =
                sx > 1e-6 &&
                sx < c.size.width - 1e-6 &&
                sy > 1e-6 &&
                sy < c.size.height - 1e-6 &&
                depth > f.near &&
                depth < f.far;
            final offScreen =
                sx < -1e-6 ||
                sx > c.size.width + 1e-6 ||
                sy < -1e-6 ||
                sy > c.size.height + 1e-6;
            if (onScreen) {
              expect(_insideEngineFrustum(f.viewProjRowMajor, p), isTrue);
              inside++;
            } else if (offScreen) {
              expect(_insideEngineFrustum(f.viewProjRowMajor, p), isFalse);
              outside++;
            }
          }
        }
        expect(inside, greaterThan(100));
        expect(outside, greaterThan(100));
      },
    );

    test(
      'NEGATIVE: engine frustum on the transposed matrix disagrees with the screen',
      () {
        var disagreements = 0;
        final rng = math.Random(7);
        for (final c in _cases(orthographic: true, n: 20, seed: 99)) {
          final f = lodCameraFrame(
            camera: c.cam,
            logicalSize: c.size,
            viewportWidthPx: 3,
            viewportHeightPx: 3,
            sceneBoxMin: c.boxMin,
            sceneBoxMax: c.boxMax,
          );
          final t = _transpose(f.viewProjRowMajor);
          final old = c.cam.projectionFor(c.size);
          for (var i = 0; i < 400; i++) {
            final r = c.cam.radius * 3;
            final p = [
              c.cam.pivotX + (rng.nextDouble() * 2 - 1) * r,
              c.cam.pivotY + (rng.nextDouble() * 2 - 1) * r,
              c.cam.pivotZ + (rng.nextDouble() * 2 - 1) * r,
            ];
            final (sx, sy, _) = old.project(p[0], p[1], p[2]);
            final on =
                sx >= 0 && sx <= c.size.width && sy >= 0 && sy <= c.size.height;
            if (_insideEngineFrustum(t, p) != on) disagreements++;
          }
        }
        expect(disagreements, greaterThan(100));
      },
    );
  });

  group('perspective (the switch the page keeps)', () {
    final cases = _cases(orthographic: false, seed: 11);

    test(
      'same pixels as CloudProjection.project (perspective) for every point',
      () {
        var worst = 0.0;
        for (final c in cases) {
          final f = lodCameraFrame(
            camera: c.cam,
            logicalSize: c.size,
            viewportWidthPx: 3,
            viewportHeightPx: 3,
            sceneBoxMin: c.boxMin,
            sceneBoxMax: c.boxMax,
          );
          worst = math.max(
            worst,
            _maxPixelError(
              f.viewProjRowMajor,
              c,
              oldViewer: c.cam.projectionFor(c.size),
            ),
          );
          expect(f.projection, LodProjection.perspective);
          expect(f.orthoWidthWorld, 0);
          // fov from f: tan(fov/2) = (H/2)/f
          final old = c.cam.projectionFor(c.size);
          expect(
            (math.tan(f.fovYDegrees * math.pi / 360) -
                    c.size.height / 2 / old.f)
                .abs(),
            lessThan(1e-12),
          );
        }
        // ignore: avoid_print
        print('perspective max |Δpx| = $worst');
        expect(worst, lessThan(pxTol));
      },
    );

    test(
      'NEGATIVE: the ortho matrix does NOT reproduce the perspective viewer',
      () {
        var worst = 0.0;
        for (final c in cases) {
          final ortho = CloudCamera(
            yaw: c.cam.yaw,
            pitch: c.cam.pitch,
            roll: c.cam.roll,
            zoom: c.cam.zoom,
            panX: c.cam.panX,
            panY: c.cam.panY,
            pivotX: c.cam.pivotX,
            pivotY: c.cam.pivotY,
            pivotZ: c.cam.pivotZ,
            radius: c.cam.radius,
            orthographic: true,
          );
          final f = lodCameraFrame(
            camera: ortho,
            logicalSize: c.size,
            viewportWidthPx: 3,
            viewportHeightPx: 3,
            sceneBoxMin: c.boxMin,
            sceneBoxMax: c.boxMax,
          );
          worst = math.max(
            worst,
            _maxPixelError(
              f.viewProjRowMajor,
              c,
              oldViewer: c.cam.projectionFor(c.size),
            ),
          );
        }
        expect(worst, greaterThan(1.0));
      },
    );
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
    final view = lookAtRowMajor(const [0, 0, 10], const [0, 0, 0], const [
      0,
      1,
      0,
    ]);
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
        for (final ortho in [true, false]) {
          for (final c in _cases(orthographic: ortho, seed: 77)) {
            for (final ls in [double.infinity, 1e-4 + rng.nextDouble()]) {
              final f = lodCameraFrame(
                camera: c.cam,
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

    test('NEGATIVE: a far plane in front of the farthest corner is reported', () {
      // Same camera, ortho frustum [-2,2]^2, far 10.5 < 11 (the corner at view z −11).
      final good = mulRowMajor(
        orthographicWebGpuRowMajor(-2, 2, 2, -2, -10020, 10020),
        view,
      );
      expect(clippedCorners(good, bmin, bmax, true), isEmpty);
      final shortFar = mulRowMajor(
        orthographicWebGpuRowMajor(-2, 2, 2, -2, -10.5, 10.5),
        view,
      );
      expect(clippedCorners(shortFar, bmin, bmax, true), isNotEmpty);
      final shortPersp = mulRowMajor(
        perspectiveWebGpuRowMajor(-1, 1, 1, -1, 1, 10.5),
        view,
      );
      expect(clippedCorners(shortPersp, bmin, bmax, false), isNotEmpty);
    });
  });
}
