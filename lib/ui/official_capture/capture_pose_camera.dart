// capture_pose_camera.dart — the ARKit camera at the finish tap → the cloud
// view's orbit rig ("关灯了,点云还在原地", 2026-09-15).
//
// Every step below is a cited formula; nothing is fitted or tuned:
//  1. Camera axes — Apple, ARCamera.transform: "the x-axis always points along
//     the long axis of the device, from the front-facing camera toward the
//     Home button. The y-axis points upward (with respect to
//     UIDeviceOrientation.landscapeLeft orientation), and the z-axis points
//     away from the device on the screen side." ⇒ the camera looks along −z.
//  2. Portrait relabel — U3DC/Unity-ARKit-Plugin (MIT), ARSessionNative.mm
//     L543-548, L569: display frame = camera.transform × R with
//     R.columns[0] = (0,1,0), R.columns[1] = (−1,0,0) ⇒ display-right =
//     camera +y, display-up = camera −x ⇒ screen-down = camera +x. The same
//     follows from (1): in portrait the Home button (+x) is at the bottom of
//     the screen and the landscape "up" edge (+y) is the screen's right edge.
//  3. Sensor-frame pinhole — COLMAP src/colmap/sensor/models/pinhole.h
//     L46-54 (BSD-3): x = f·u/w + c. Apple, ARCamera.intrinsics: "fx and fy
//     are the pixel focal length, and are identical for square pixels. ox and
//     oy are the offsets of the principal point from the top-left corner of
//     the image frame. All values are expressed in pixels." The image is in
//     "the camera device's native sensor orientation" (ARCamera.imageResolution).
//  4. Aspect-fill of the rotated image into the viewport — Apple,
//     ARFrame.displayTransform: "the correct rotation and aspect-fill";
//     CALayerContentsGravity.resizeAspectFill: scaled to fill the bounds
//     preserving aspect ratio, the excess clipped symmetrically ⇒
//     s = max(vpW/H_img, vpH/W_img), centred.
//  5. Orbit rig from the free camera — pivot = C + forward·r (Potree
//     src/viewer/View.js L73-75 getPivot); r = the distance to the point under
//     the screen centre (CesiumJS Camera.js L1202-1247, the distance Cesium
//     uses when it switches perspective → orthographic); the rig's angles come
//     from its own view matrix (decomposeViewMatrix, cloud_camera.dart).
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'cloud_camera.dart';
import 'sparse_cloud_view.dart' show PerspectiveStart;

/// The AR viewport's pinhole expressed in the cloud view's pixel coordinates.
class CapturePinhole {
  const CapturePinhole({
    required this.right,
    required this.up,
    required this.forward,
    required this.center,
    required this.f,
    required this.ox,
    required this.oy,
  });

  /// World-space unit axes of the DISPLAY (portrait) frame and the camera centre.
  final List<double> right, up, forward, center;

  /// Pixel focal length and principal point in view pixels (top-left origin).
  final double f, ox, oy;

  /// (screen x, screen y, depth); depth ≤ 0 ⇒ behind the camera.
  (double, double, double) project(double wx, double wy, double wz) {
    final px = wx - center[0], py = wy - center[1], pz = wz - center[2];
    final depth = forward[0] * px + forward[1] * py + forward[2] * pz;
    final rx = right[0] * px + right[1] * py + right[2] * pz;
    final uy = up[0] * px + up[1] * py + up[2] * pz;
    return (ox + f * rx / depth, oy - f * uy / depth, depth);
  }
}

/// Builds the pinhole from an ARKit pose (column-major camera→world 4×4,
/// as `ARPose.extrinsic4x4`), the sensor intrinsics and the viewport rect the
/// AR image is drawn in (view pixels). Returns null on degenerate input.
CapturePinhole? capturePinholeFromPose({
  required List<double> extrinsic4x4,
  required List<double> intrinsicFxFyCxCy,
  required int imageWidth,
  required int imageHeight,
  required Rect viewport,
}) {
  if (extrinsic4x4.length != 16 || intrinsicFxFyCxCy.length != 4) return null;
  if (imageWidth <= 0 || imageHeight <= 0 || viewport.isEmpty) return null;
  final m = extrinsic4x4;
  // Column-major: column c holds the world direction of camera axis c.
  final camX = [m[0], m[1], m[2]];
  final camY = [m[4], m[5], m[6]];
  final camZ = [m[8], m[9], m[10]];
  final c = [m[12], m[13], m[14]];
  final fx = intrinsicFxFyCxCy[0], cx = intrinsicFxFyCxCy[2];
  final cy = intrinsicFxFyCxCy[3];
  if (!(fx > 0)) return null;
  // (4) aspect-fill of the rotated (portrait) image: rotated size = (H, W).
  final rw = imageHeight.toDouble(), rh = imageWidth.toDouble();
  final s = math.max(viewport.width / rw, viewport.height / rh);
  final offX = (viewport.width - s * rw) / 2;
  final offY = (viewport.height - s * rh) / 2;
  // (2)+(3): sensor u = cx + fx·xc/depth (u along camera +x), v = cy − fy·yc/depth
  // (v down ⇔ camera −y); portrait: screen-right = +y ⇒ u' = s·(H − v),
  // screen-down = +x ⇒ v' = s·u.
  return CapturePinhole(
    right: camY,
    up: [-camX[0], -camX[1], -camX[2]],
    forward: [-camZ[0], -camZ[1], -camZ[2]],
    center: c,
    f: s * fx,
    ox: viewport.left + offX + s * (imageHeight - cy),
    oy: viewport.top + offY + s * cx,
  );
}

/// The point under the screen centre (Cesium's rule) ⇒ its depth is the rig's
/// eye distance. Nearest to the centre in screen pixels, ties → nearer.
double? centrePickDepth(CapturePinhole pin, Float32List xyz, Rect viewport) {
  final cxv = viewport.center.dx, cyv = viewport.center.dy;
  var best = double.infinity, bestDepth = double.infinity;
  for (var i = 0; i + 2 < xyz.length; i += 3) {
    final (sx, sy, d) = pin.project(xyz[i], xyz[i + 1], xyz[i + 2]);
    if (!(d > 0)) continue;
    final dx = sx - cxv, dy = sy - cyv;
    final r2 = dx * dx + dy * dy;
    if (r2 < best || (r2 == best && d < bestDepth)) {
      best = r2;
      bestDepth = d;
    }
  }
  return bestDepth.isFinite ? bestDepth : null;
}

/// The rig start that reproduces [pin] pixel-for-pixel in a view of any size
/// (zoom/pan are resolved by the view from f/ox/oy when it knows its size).
/// null when the cloud has no point in front of the camera.
PerspectiveStart? capturePoseToRig({
  required CapturePinhole pin,
  required Float32List xyz,
  required Rect viewport,
}) {
  final r = centrePickDepth(pin, xyz, viewport);
  if (r == null || !(r > 0)) return null;
  // Rig view matrix rows (see CloudProjection.project): x1 = −screen-right,
  // y2 = screen-up, z2 = forward (depth). rows (−right, up, forward) form a
  // proper rotation: (−right)×up = −(right×up) = forward.
  final mtx = <double>[
    -pin.right[0], -pin.right[1], -pin.right[2], //
    pin.up[0], pin.up[1], pin.up[2], //
    pin.forward[0], pin.forward[1], pin.forward[2],
  ];
  final (yaw, pitch, roll) = decomposeViewMatrix(mtx);
  return PerspectiveStart(
    yaw: yaw,
    pitch: pitch,
    roll: roll,
    pivotX: pin.center[0] + pin.forward[0] * r,
    pivotY: pin.center[1] + pin.forward[1] * r,
    pivotZ: pin.center[2] + pin.forward[2] * r,
    camDist: r,
    f: pin.f,
    ox: pin.ox,
    oy: pin.oy,
  );
}

/// zoom/pan the view derives from a [PerspectiveStart] for a given size — the
/// same arithmetic as _SparseCloudViewState._applyPendingPerspective, exposed
/// so tests can build the exact CloudCamera the view will use.
CloudCamera rigCameraFor(PerspectiveStart p, Size size, double fitRadius) =>
    CloudCamera(
      yaw: p.yaw,
      pitch: p.pitch,
      roll: p.roll,
      zoom: p.f / (size.shortestSide * 0.5 * kFitFillK),
      panX: p.ox - size.width * 0.5,
      panY: p.oy - size.height * 0.5,
      pivotX: p.pivotX,
      pivotY: p.pivotY,
      pivotZ: p.pivotZ,
      radius: fitRadius,
      orthographic: true,
      camDistOverride: p.camDist,
      orthoMix: 0.0,
    );
