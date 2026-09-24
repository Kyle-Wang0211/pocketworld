// lod_camera.dart — the LOD page's camera, expressed as the frozen pwlod_camera.
//
// Pure Dart, no platform types (the same file serves the iOS / Android / HarmonyOS
// shells). Nothing here is new math: every piece is taken from an existing source and
// only composed.
//
//   What the camera IS  — the old point-cloud viewer's camera, unchanged:
//     lib/ui/official_capture/cloud_camera.dart @875fe67 (CloudCamera / CloudProjection,
//     the single source of truth SparseCloudView paints with). We call it; we do not
//     re-derive it. Orthographic by default because the old viewer is
//     (sparse_cloud_view.dart:199 `kCloudOrthographic = true`, user decision 2026-07-30).
//       * basis rows (x1, y2, z2)  cloud_camera.dart:99-106 (project) and :173-186
//         (composeViewMatrix: row1 = (cosY,0,sinY), row2 = (sinY·sinP, cosP, −cosY·sinP),
//         row3 = (−sinY·cosP, sinP, cosY·cosP)).
//       * screen x = ox − x1·f/d, y = oy − y2·f/d, d = camDist (ortho) or depth
//         (cloud_camera.dart:106-108); roll about (ox,oy) :109-113.
//   Near / far planes — Potree @5636cd471d9eb464969e758be45c44d7613d3859 Viewer.update,
//     src/viewer/viewer.js:1749-1771 (see potreeNearFar below), on the scene box of
//     lod_scene_fit.dart; initial values src/viewer/Scene.js:21-22.
//   View matrix — the LOD library's own test helper, so the engine's selectVisible()
//     sees the convention its host tests use:
//     Aether3D tests/pointcloud_lod/test_select.cpp:51-61 @d251451 `lookAt`
//     (rows s, u, −f; translation −s·eye, −u·eye, f·eye), row-major.
//   Projection — three.js src/math/Matrix4.js @6101189ee28b (the revision the LOD
//     library pins for its frustum, DEVIATIONS.md:21), WebGPU branch because the
//     engine's clip space is WebGPU's (z in [0,1]; pwlod_viewer.h:81):
//       makeOrthographic :1200-1242 (WebGPU c = −1/(far−near), d = −near/(far−near))
//       makePerspective  :1140-1183 (WebGPU c = −far/(far−near), d = −far·near/(far−near))
//     three.js stores column-major (`te[0], te[4], te[8], te[12]` is row 0); we write
//     the same numbers row-major (pwlod_viewer.h:81).
//
// Why the old viewer's pixels come out unchanged (checked by
// test/point_cloud_lod/lod_camera_test.dart against CloudProjection.project):
//   the old viewer is right-handed with screen-right = −row1, screen-up = row2,
//   into-the-screen = row3 (cloud_camera.dart:121-156 rightAxisWorld/upAxisWorld), so
//   lookAt(eye = pivot − camDist·row3, target = pivot, up) reproduces it; roll is a
//   rotation of `up` (right' = cosR·right + sinR·up — cloud_camera.dart:124-131);
//   pan (ox = W/2 + panX) is an off-centre frustum, not a camera move, which is exactly
//   what makeOrthographic / makePerspective's left/right/top/bottom express.
//
// Pivot / radius: Potree fitToScreen's bounding sphere of the octree box
// (lod_scene_fit.dart, every step pinned there).
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import '../ui/official_capture/cloud_camera.dart';

/// pwlod_projection (pwlod_viewer.h:70-73). Values are the C enum values.
enum LodProjection {
  perspective(0),
  orthographic(1);

  const LodProjection(this.wireValue);
  final int wireValue;
}

/// Potree Scene.js:21-22 @5636cd4: the cameras start with near 0.1, far 1000*1000; Viewer.update
/// keeps whatever near/far the camera has while no node spacing is known (viewer.js:1766-1768).
const double kPotreeInitialNear = 0.1;
const double kPotreeInitialFar = 1000 * 1000;

/// Potree Viewer.update's near/far, src/viewer/viewer.js:1749-1771 @5636cd4, verbatim:
///
///     if(result.lowestSpacing !== Infinity){
///         let near = result.lowestSpacing * 10.0;
///         let far = -this.getBoundingBox().applyMatrix4(camera.matrixWorldInverse).min.z;
///         far = Math.max(far * 1.5, 10000);
///         near = Math.min(100.0, Math.max(0.01, near));
///         near = Math.min(near, closestImage);
///         far = Math.max(far, near + 10000);
///         if(near === Infinity){ near = 0.1; }
///         camera.near = near;  camera.far = far;
///     }else{ // don't change near and far in this case }
///     if(this.scene.cameraMode == CameraMode.ORTHOGRAPHIC) { camera.near = -camera.far; }
///
/// [lowestSpacing] = Potree_update_visibility.js:114, :276-280 (smallest spacing among the
/// nodes the selection walked); Infinity = not known ⇒ the "don't change" branch keeps
/// [previousNear]/[previousFar] (initially Scene.js:21-22). [closestImage] is Potree's nearest
/// oriented image; this viewer has none ⇒ Infinity (the loop at :1739-1746 over no images).
/// `getBoundingBox().applyMatrix4(matrixWorldInverse)` = the scene box's 8 corners in view
/// space, axis-aligned again (three.js r124 Box3.applyMatrix4, three.module.js:4296-4316);
/// [viewRowMajor] is world→view (= camera.matrixWorldInverse).
({double near, double far}) potreeNearFar({
  required double lowestSpacing,
  required List<double> viewRowMajor,
  required List<double> boxMin,
  required List<double> boxMax,
  required bool orthographic,
  double closestImage = double.infinity,
  double previousNear = kPotreeInitialNear,
  double previousFar = kPotreeInitialFar,
}) {
  var near = previousNear, far = previousFar;
  if (lowestSpacing != double.infinity) {
    var minZ = double.infinity;
    for (var i = 0; i < 8; i++) {
      final x = (i & 4) == 0 ? boxMin[0] : boxMax[0];
      final y = (i & 2) == 0 ? boxMin[1] : boxMax[1];
      final z = (i & 1) == 0 ? boxMin[2] : boxMax[2];
      final vz =
          viewRowMajor[8] * x +
          viewRowMajor[9] * y +
          viewRowMajor[10] * z +
          viewRowMajor[11];
      if (vz < minZ) minZ = vz;
    }
    var n = lowestSpacing * 10.0;
    var f = -minZ;
    f = math.max(f * 1.5, 10000);
    n = math.min(100.0, math.max(0.01, n));
    n = math.min(n, closestImage);
    f = math.max(f, n + 10000);
    if (n == double.infinity) {
      n = 0.1;
    }
    near = n;
    far = f;
  }
  if (orthographic) {
    near = -far;
  }
  return (near: near, far: far);
}

/// One pwlod_camera (pwlod_viewer.h:80-89), in Dart. Field names follow the C struct.
class LodCameraFrame {
  LodCameraFrame({
    required this.viewProjRowMajor,
    required this.eyeWorld,
    required this.projection,
    required this.fovYDegrees,
    required this.orthoWidthWorld,
    required this.orthoHeightWorld,
    required this.viewportWidthPx,
    required this.viewportHeightPx,
    required this.near,
    required this.far,
  }) : assert(viewProjRowMajor.length == 16),
       assert(eyeWorld.length == 3);

  /// world -> clip, ROW-major (`[r * 4 + c]`), WebGPU clip z in [0, 1].
  final Float64List viewProjRowMajor;
  final Float64List eyeWorld;
  final LodProjection projection;

  /// PERSPECTIVE only (0 when orthographic): 2·atan((H/2)/f).
  final double fovYDegrees;

  /// ORTHOGRAPHIC only (0 when perspective): right − left, top − bottom.
  final double orthoWidthWorld;
  final double orthoHeightWorld;

  /// Must equal the render targets' size (pwlod_viewer.h:87).
  final int viewportWidthPx;
  final int viewportHeightPx;

  /// Diagnostics only (not in pwlod_camera): the planes baked into the matrix
  /// (potreeNearFar; orthographic near is −far, as in Potree).
  final double near;
  final double far;
}

/// three.js makeOrthographic, WebGPU branch (Matrix4.js:1200-1242 @6101189ee28b),
/// written row-major.
Float64List orthographicWebGpuRowMajor(
  double left,
  double right,
  double top,
  double bottom,
  double near,
  double far,
) {
  final x = 2 / (right - left);
  final y = 2 / (top - bottom);
  final a = -(right + left) / (right - left);
  final b = -(top + bottom) / (top - bottom);
  final c = -1 / (far - near);
  final d = -near / (far - near);
  return Float64List.fromList(<double>[
    x, 0, 0, a, //
    0, y, 0, b, //
    0, 0, c, d, //
    0, 0, 0, 1,
  ]);
}

/// three.js makePerspective, WebGPU branch (Matrix4.js:1140-1183 @6101189ee28b),
/// written row-major. left/right/top/bottom are at the near plane.
Float64List perspectiveWebGpuRowMajor(
  double left,
  double right,
  double top,
  double bottom,
  double near,
  double far,
) {
  final x = 2 * near / (right - left);
  final y = 2 * near / (top - bottom);
  final a = (right + left) / (right - left);
  final b = (top + bottom) / (top - bottom);
  final c = -far / (far - near);
  final d = (-far * near) / (far - near);
  return Float64List.fromList(<double>[
    x, 0, a, 0, //
    0, y, b, 0, //
    0, 0, c, d, //
    0, 0, -1, 0,
  ]);
}

/// Aether3D tests/pointcloud_lod/test_select.cpp:51-61 @d251451 `lookAt`, row-major.
Float64List lookAtRowMajor(
  List<double> eye,
  List<double> target,
  List<double> up,
) {
  List<double> norm(List<double> v) {
    final l = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    return l > 0 ? <double>[v[0] / l, v[1] / l, v[2] / l] : v;
  }

  List<double> cross(List<double> a, List<double> b) => <double>[
    a[1] * b[2] - a[2] * b[1],
    a[2] * b[0] - a[0] * b[2],
    a[0] * b[1] - a[1] * b[0],
  ];
  double dot(List<double> a, List<double> b) =>
      a[0] * b[0] + a[1] * b[1] + a[2] * b[2];

  final f = norm(<double>[
    target[0] - eye[0],
    target[1] - eye[1],
    target[2] - eye[2],
  ]); // forward
  final s = norm(cross(f, up)); // right
  final u = cross(s, f);
  return Float64List.fromList(<double>[
    s[0], s[1], s[2], -dot(s, eye), //
    u[0], u[1], u[2], -dot(u, eye), //
    -f[0], -f[1], -f[2], dot(f, eye), //
    0, 0, 0, 1,
  ]);
}

/// Row-major 4×4 product a·b (test_select.cpp:34-41 @d251451 `mul`, same loop order).
Float64List mulRowMajor(List<double> a, List<double> b) {
  final o = Float64List(16);
  for (var r = 0; r < 4; r++) {
    for (var c = 0; c < 4; c++) {
      var s = 0.0;
      for (var k = 0; k < 4; k++) {
        s += a[r * 4 + k] * b[k * 4 + c];
      }
      o[r * 4 + c] = s;
    }
  }
  return o;
}

/// The old viewer's camera -> pwlod_camera.
///
/// [camera] is a CloudCamera exactly as SparseCloudView builds it; its
/// `orthographic` flag picks the projection. [logicalSize] is the widget size in
/// logical pixels (what CloudCamera.projectionFor takes); [viewportWidthPx] /
/// [viewportHeightPx] are the render targets' physical size. NDC is resolution
/// independent, so the matrix is the same for any devicePixelRatio.
/// [sceneBoxMin]/[sceneBoxMax] and [lowestSpacing] feed potreeNearFar.
LodCameraFrame lodCameraFrame({
  required CloudCamera camera,
  required Size logicalSize,
  required int viewportWidthPx,
  required int viewportHeightPx,
  required List<double> sceneBoxMin,
  required List<double> sceneBoxMax,
  double lowestSpacing = double.infinity,
}) {
  final p = camera.projectionFor(logicalSize);
  final w = logicalSize.width, h = logicalSize.height;
  final panX = camera.panX, panY = camera.panY;

  // Basis rows (cloud_camera.dart:173-186 composeViewMatrix with roll = 0).
  final r1 = <double>[p.cosY, 0.0, p.sinY];
  final r2 = <double>[p.sinY * p.sinP, p.cosP, -p.cosY * p.sinP];
  final r3 = <double>[-p.sinY * p.cosP, p.sinP, p.cosY * p.cosP];

  final pivot = <double>[p.pivotX, p.pivotY, p.pivotZ];
  // depth = z2 + camDist = row3·(x − pivot) + camDist = row3·(x − eye)
  // ⇒ eye = pivot − camDist·row3.
  final eye = <double>[
    pivot[0] - p.camDist * r3[0],
    pivot[1] - p.camDist * r3[1],
    pivot[2] - p.camDist * r3[2],
  ];
  // Screen-up after roll: up' = −sinR·right + cosR·up with right = −row1
  // (cloud_camera.dart:145-156 upAxisWorld) ⇒ up' = sinR·row1 + cosR·row2.
  final up = <double>[
    p.sinR * r1[0] + p.cosR * r2[0],
    p.sinR * r1[1] + p.cosR * r2[1],
    p.sinR * r1[2] + p.cosR * r2[2],
  ];
  final view = lookAtRowMajor(eye, pivot, up);

  final nf = potreeNearFar(
    lowestSpacing: lowestSpacing,
    viewRowMajor: view,
    boxMin: sceneBoxMin,
    boxMax: sceneBoxMax,
    orthographic: p.orthographic,
  );
  final near = nf.near, far = nf.far;

  final Float64List proj;
  final double fovY, orthoW, orthoH;
  if (p.orthographic) {
    // x_view·(f/camDist) + panX = pixels right of the widget centre
    // (cloud_camera.dart:106-108 with d = camDist).
    final k = p.f / p.camDist;
    final left = (-w / 2 - panX) / k;
    final right = (w / 2 - panX) / k;
    final bottom = (-h / 2 + panY) / k;
    final top = (h / 2 + panY) / k;
    proj = orthographicWebGpuRowMajor(left, right, top, bottom, near, far);
    fovY = 0;
    orthoW = right - left;
    orthoH = top - bottom;
  } else {
    // Same bounds scaled to the near plane (d = depth).
    final k = p.f / near;
    final left = (-w / 2 - panX) / k;
    final right = (w / 2 - panX) / k;
    final bottom = (-h / 2 + panY) / k;
    final top = (h / 2 + panY) / k;
    proj = perspectiveWebGpuRowMajor(left, right, top, bottom, near, far);
    fovY = 2 * math.atan((h / 2) / p.f) * 180 / math.pi;
    orthoW = 0;
    orthoH = 0;
  }

  return LodCameraFrame(
    viewProjRowMajor: mulRowMajor(proj, view),
    eyeWorld: Float64List.fromList(eye),
    projection: p.orthographic
        ? LodProjection.orthographic
        : LodProjection.perspective,
    fovYDegrees: fovY,
    orthoWidthWorld: orthoW,
    orthoHeightWorld: orthoH,
    viewportWidthPx: viewportWidthPx,
    viewportHeightPx: viewportHeightPx,
    near: near,
    far: far,
  );
}
