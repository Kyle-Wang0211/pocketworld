// lod_camera.dart — the GPU viewer's camera (pwlod_viewer.h v3 pwlod_camera), built from the
// product viewer's own projection.
//
// Pure Dart, no platform types (the same file serves the iOS / Android / HarmonyOS shells).
// Nothing here is new math: every piece is taken from an existing source and only composed.
//
//   What the camera IS — the product viewer's CloudProjection, unchanged:
//     lib/ui/official_capture/cloud_camera.dart (168 source 86a45cf) CloudCamera.projectionFor →
//     CloudProjection, the single source of truth SparseCloudPainter paints with. The caller hands
//     in exactly the projection the view paints with; nothing is re-derived from yaw/pitch here.
//       * basis rows (x1, y2, z2): CloudProjection.project — x1 = cosY·px + sinY·pz;
//         y2 = sinY·sinP·px + cosP·py − cosY·sinP·pz; z2 = −sinY·cosP·px + sinP·py + cosY·cosP·pz
//         (p = world − pivot);
//       * depth = z2 + camDist; divisor(depth) = CloudProjection.divisorAt (orthoMix 1 → camDist,
//         0 → depth, between: depth + (camDist − depth)·orthoMix = (1 − orthoMix)·z2 + camDist);
//       * screen x = ox − x1·f/d, y = oy − y2·f/d, then roll about (ox, oy):
//         (ox + dx·cosR − dy·sinR, oy + dx·sinR + dy·cosR).
//     Because the divisor is affine in z2, the whole map is ONE projective 4×4 with
//     w_clip = divisor: x_clip = (2·sx/W − 1)·w, y_clip = (1 − 2·sy/H)·w (NDC, y up), which is
//     pwlod_viewer.h v3's requirement ("view_proj_row_major must be exactly that projection, incl.
//     roll and the screen-X negation"). The v2 lookAt + three.js makeOrthographic /
//     makePerspective route (feat/lod-viewer 327969c) covered only the two endpoints and roll by
//     rotating `up`; it is replaced by this direct form, which also covers 0 < orthoMix < 1.
//   Near / far planes — Potree @5636cd471d9eb464969e758be45c44d7613d3859 Viewer.update,
//     src/viewer/viewer.js:1749-1771 (potreeNearFar below, unchanged from feat/lod-viewer):
//     orthoMix == 1 is Potree's orthographic camera (near = −far); anything else takes the
//     perspective branch. z_clip maps depth ∈ [near, far] onto WebGPU [0, 1]:
//     z_clip = a·(depth − near) with a = w(far)/(far − near), w(far) = (1 − m)·far + m·camDist;
//     at m = 0 this is three.js makePerspective's WebGPU branch (Matrix4.js:1140-1183 @6101189ee28b,
//     c = −far/(far−near), d = −far·near/(far−near) on view z = −depth), at m = 1 makeOrthographic's
//     (Matrix4.js:1200-1242, c = −1/(far−near), d = −near/(far−near)) scaled by w = camDist.
//   eye_world = pivot − camDist·row3 (the point where depth = 0; for the perspective endpoint the
//     engine's Potree screen-size rule uses the Euclidean eye→node distance, pwlod_viewer.h v3).
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Size;

import '../ui/official_capture/cloud_camera.dart';

/// Potree Scene.js:21-22 @5636cd4: the cameras start with near 0.1, far 1000*1000; Viewer.update
/// keeps whatever near/far the camera has while no node spacing is known (viewer.js:1766-1768).
const double kPotreeInitialNear = 0.1;
const double kPotreeInitialFar = 1000 * 1000;

/// pwlod_frame_stats.lowest_spacing (ABI v2+, pwlod_viewer.h: Potree's lowestSpacing
/// over every node popped from the queue this frame, "<= 0 if the queue was empty") →
/// Potree's `result.lowestSpacing`, which stays at its initial Infinity when no node was
/// popped (Potree_update_visibility.js:114). Non-finite is treated the same way.
double potreeLowestSpacingFromStats(double statsLowestSpacing) =>
    statsLowestSpacing > 0 && statsLowestSpacing.isFinite
    ? statsLowestSpacing
    : double.infinity;

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
/// [lowestSpacing] = Potree_update_visibility.js:114, :276-280; Infinity = not known ⇒ the
/// "don't change" branch keeps [previousNear]/[previousFar] (initially Scene.js:21-22).
/// [closestImage] is Potree's nearest oriented image; this viewer has none ⇒ Infinity.
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

/// One pwlod_camera (pwlod_viewer.h v3), in Dart. Field names follow the C struct.
class LodCameraFrame {
  LodCameraFrame({
    required this.viewProjRowMajor,
    required this.eyeWorld,
    required this.focalPx,
    required this.orbitDistance,
    required this.orthoMix,
    required this.viewportWidthPx,
    required this.viewportHeightPx,
    required this.near,
    required this.far,
    required this.viewRowMajor,
  }) : assert(viewProjRowMajor.length == 16),
       assert(eyeWorld.length == 3);

  /// world -> clip, ROW-major (`[r * 4 + c]`), WebGPU clip z in [0, 1].
  final Float64List viewProjRowMajor;
  final Float64List eyeWorld;

  /// CloudProjection.f (= half · fillK · zoom), in LOGICAL pixels like the view (the engine works
  /// in NDC; the viewport below is physical).
  final double focalPx;

  /// CloudProjection.camDist.
  final double orbitDistance;

  /// CloudProjection.orthoMix: 1 orthographic … 0 perspective.
  final double orthoMix;

  /// Must equal the render targets' size (pwlod_viewer.h).
  final int viewportWidthPx;
  final int viewportHeightPx;

  /// Diagnostics / Potree bookkeeping (not in pwlod_camera): the planes baked into the matrix and
  /// the world→view matrix they were computed from (view z = −depth).
  final double near;
  final double far;
  final Float64List viewRowMajor;
}

/// Row-major 4×4 product a·b (Aether3D tests/pointcloud_lod/test_select.cpp:34-41 @d251451 `mul`).
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

/// The product viewer's CloudProjection → pwlod_camera (v3).
///
/// [projection] is exactly what SparseCloudView paints with (CloudCamera.projectionFor at
/// [logicalSize]); [viewportWidthPx]/[viewportHeightPx] are the render targets' physical size
/// (NDC is resolution independent, so the matrix does not depend on devicePixelRatio).
/// [sceneBoxMin]/[sceneBoxMax] (the flat set's or octree's axis-aligned box), [lowestSpacing] and
/// [previousNear]/[previousFar] feed potreeNearFar.
LodCameraFrame lodCameraFrame({
  required CloudProjection projection,
  required Size logicalSize,
  required int viewportWidthPx,
  required int viewportHeightPx,
  required List<double> sceneBoxMin,
  required List<double> sceneBoxMax,
  double lowestSpacing = double.infinity,
  double previousNear = kPotreeInitialNear,
  double previousFar = kPotreeInitialFar,
}) {
  final p = projection;
  final w = logicalSize.width, h = logicalSize.height;
  final m = p.orthoMix, c = p.camDist, f = p.f;
  final orthographic = m == 1.0;

  // World → (x1, y2, z2, 1): rows of CloudProjection.project, translation −R·pivot.
  final r1 = <double>[p.cosY, 0.0, p.sinY];
  final r2 = <double>[p.sinY * p.sinP, p.cosP, -p.cosY * p.sinP];
  final r3 = <double>[-p.sinY * p.cosP, p.sinP, p.cosY * p.cosP];
  final pivot = <double>[p.pivotX, p.pivotY, p.pivotZ];
  double dot3(List<double> a, List<double> b) =>
      a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
  final basis = Float64List.fromList(<double>[
    r1[0], r1[1], r1[2], -dot3(r1, pivot), //
    r2[0], r2[1], r2[2], -dot3(r2, pivot), //
    r3[0], r3[1], r3[2], -dot3(r3, pivot), //
    0, 0, 0, 1,
  ]);
  // Potree's matrixWorldInverse convention: view z = −depth = −(z2 + camDist).
  final view = Float64List.fromList(<double>[
    basis[0], basis[1], basis[2], basis[3], //
    basis[4], basis[5], basis[6], basis[7], //
    -basis[8], -basis[9], -basis[10], -(basis[11] + c), //
    0, 0, 0, 1,
  ]);
  final nf = potreeNearFar(
    lowestSpacing: lowestSpacing,
    viewRowMajor: view,
    boxMin: sceneBoxMin,
    boxMax: sceneBoxMax,
    orthographic: orthographic,
    previousNear: previousNear,
    previousFar: previousFar,
  );
  final near = nf.near, far = nf.far;

  // (x1, y2, z2, 1) → clip.
  final kx = 2 * p.ox / w - 1, ky = 1 - 2 * p.oy / h;
  final fx = 2 * f / w, fy = 2 * f / h;
  final wz = 1 - m; // w = (1 − m)·z2 + camDist
  final wFar = (1 - m) * far + m * c;
  final a = wFar / (far - near);
  final clip = Float64List.fromList(<double>[
    -fx * p.cosR, fx * p.sinR, kx * wz, kx * c, //
    fy * p.sinR, fy * p.cosR, ky * wz, ky * c, //
    0, 0, a, a * (c - near), //
    0, 0, wz, c,
  ]);
  return LodCameraFrame(
    viewProjRowMajor: mulRowMajor(clip, basis),
    eyeWorld: Float64List.fromList(<double>[
      pivot[0] - c * r3[0],
      pivot[1] - c * r3[1],
      pivot[2] - c * r3[2],
    ]),
    focalPx: f,
    orbitDistance: c,
    orthoMix: m,
    viewportWidthPx: viewportWidthPx,
    viewportHeightPx: viewportHeightPx,
    near: near,
    far: far,
    viewRowMajor: view,
  );
}
