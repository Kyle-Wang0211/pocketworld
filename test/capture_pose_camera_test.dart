// capture_pose_camera_test.dart — the capture pose → rig conversion reproduces the pinhole exactly,
// the portrait axis mapping matches Apple's camera-axis statement, and the perspective/orthographic
// blend is bit-identical to the historical rig at both endpoints.
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/official_capture/capture_pose_camera.dart';
import 'package:pocketworld_flutter/ui/official_capture/cloud_camera.dart';

const _img = (w: 1920, h: 1440);
const _k = [
  1450.0,
  1450.0,
  960.0,
  720.0,
]; // fx fy cx cy on the 1920×1440 sensor image
final _view = const Size(393, 756); // overlay cloud view: 852 − 96
final _vp = const Rect.fromLTWH(
  0,
  59,
  393,
  524,
); // CapturePreviewRect: full width, 3:4, below the safe top

List<double> _cam2world(List<double> r9, List<double> c) => [
  r9[0], r9[3], r9[6], 0, // column 0 = camera +x in world
  r9[1], r9[4], r9[7], 0, // column 1 = camera +y
  r9[2], r9[5], r9[8], 0, // column 2 = camera +z
  c[0], c[1], c[2], 1,
];

void main() {
  test(
    'identity pose: camera +y lands screen-right, camera +x lands screen-down (Apple axes, portrait)',
    () {
      final pin = capturePinholeFromPose(
        extrinsic4x4: _cam2world([1, 0, 0, 0, 1, 0, 0, 0, 1], [0, 0, 0]),
        intrinsicFxFyCxCy: _k,
        imageWidth: _img.w,
        imageHeight: _img.h,
        viewport: _vp,
      )!;
      final (cx, cy, dz) = pin.project(
        0,
        0,
        -1,
      ); // straight ahead (camera looks along −z)
      expect(dz, closeTo(1, 1e-12));
      expect(
        cx,
        closeTo(_vp.center.dx, 1e-9),
      ); // 4:3 image in a 3:4 viewport: no crop, principal point at the centre
      expect(cy, closeTo(_vp.center.dy, 1e-9));
      final (rx, ry, _) = pin.project(0, 0.5, -1); // camera +y
      expect(rx, greaterThan(cx));
      expect(ry, closeTo(cy, 1e-9));
      final (bx, by, _) = pin.project(
        0.5,
        0,
        -1,
      ); // camera +x (toward the Home button)
      expect(by, greaterThan(cy));
      expect(bx, closeTo(cx, 1e-9));
      // scale: s = vpW / H_img; f = s·fx
      expect(pin.f, closeTo(393 / 1440 * 1450, 1e-9));
    },
  );

  test(
    'random poses: the rig (camDist override, orthoMix 0) reproduces the pinhole to 1e-9',
    () {
      final rng = math.Random(11);
      for (var trial = 0; trial < 40; trial++) {
        final axis = [
          rng.nextDouble() - .5,
          rng.nextDouble() - .5,
          rng.nextDouble() - .5,
        ];
        final r9 = rotationFromAxisAngle(axis, (rng.nextDouble() - .5) * 2.5);
        final c = [
          rng.nextDouble() * 2 - 1,
          rng.nextDouble() * 2 - 1,
          rng.nextDouble() * 2 - 1,
        ];
        final pin = capturePinholeFromPose(
          extrinsic4x4: _cam2world(r9, c),
          intrinsicFxFyCxCy: _k,
          imageWidth: _img.w,
          imageHeight: _img.h,
          viewport: _vp,
        )!;
        // a cloud in front of the camera: 200 points within the frustum
        final xyz = Float32List(600);
        for (var i = 0; i < 200; i++) {
          final d = 0.6 + rng.nextDouble() * 3;
          final u = (rng.nextDouble() - .5) * 0.8 * d,
              v = (rng.nextDouble() - .5) * 0.8 * d;
          for (var k = 0; k < 3; k++) {
            xyz[i * 3 + k] =
                c[k] + pin.forward[k] * d + pin.right[k] * u + pin.up[k] * v;
          }
        }
        final start = capturePoseToRig(pin: pin, xyz: xyz, viewport: _vp)!;
        final cam = rigCameraFor(start, _view, 1.7).projectionFor(_view);
        for (var i = 0; i < 200; i++) {
          final x = xyz[i * 3], y = xyz[i * 3 + 1], z = xyz[i * 3 + 2];
          final (ax, ay, ad) = pin.project(x, y, z);
          final (bx, by, bd) = cam.project(x, y, z);
          expect(
            bx,
            closeTo(ax, 1e-9 * (1 + ax.abs())),
            reason: 'trial $trial pt $i x',
          );
          expect(
            by,
            closeTo(ay, 1e-9 * (1 + ay.abs())),
            reason: 'trial $trial pt $i y',
          );
          expect(
            bd,
            closeTo(ad, 1e-9 * (1 + ad.abs())),
            reason: 'trial $trial pt $i depth',
          );
        }
        // the pivot sits on the optical axis at the centre-pick depth: its rig depth == camDist
        final (_, _, pd) = cam.project(
          start.pivotX,
          start.pivotY,
          start.pivotZ,
        );
        expect(pd, closeTo(start.camDist, 1e-9));
      }
    },
  );

  test(
    'aspect-fill: a 16:9 image in the 3:4 viewport is cropped symmetrically (image centre → viewport centre)',
    () {
      final pin = capturePinholeFromPose(
        extrinsic4x4: _cam2world([1, 0, 0, 0, 1, 0, 0, 0, 1], [0, 0, 0]),
        intrinsicFxFyCxCy: const [3000, 3000, 1920, 1080],
        imageWidth: 3840,
        imageHeight: 2160,
        viewport: _vp,
      )!;
      final (cx, cy, _) = pin.project(0, 0, -1);
      expect(cx, closeTo(_vp.center.dx, 1e-9));
      expect(cy, closeTo(_vp.center.dy, 1e-9));
      expect(pin.f, closeTo(math.max(393 / 2160, 524 / 3840) * 3000, 1e-9));
    },
  );

  test(
    'centre pick: the point nearest the screen centre sets the eye distance; empty cloud ⇒ null',
    () {
      final pin = capturePinholeFromPose(
        extrinsic4x4: _cam2world([1, 0, 0, 0, 1, 0, 0, 0, 1], [0, 0, 0]),
        intrinsicFxFyCxCy: _k,
        imageWidth: _img.w,
        imageHeight: _img.h,
        viewport: _vp,
      )!;
      final xyz = Float32List.fromList([
        0.4,
        0,
        -1.0,
        0.01,
        0,
        -2.5,
        0,
        0,
        3.0,
      ]); // off-axis near, on-axis far, behind
      expect(centrePickDepth(pin, xyz, _vp), closeTo(2.5, 1e-9));
      expect(
        capturePoseToRig(pin: pin, xyz: Float32List(0), viewport: _vp),
        isNull,
      );
      expect(
        capturePoseToRig(
          pin: pin,
          xyz: Float32List.fromList([0, 0, 3]),
          viewport: _vp,
        ),
        isNull,
      );
    },
  );

  test(
    'orthoMix endpoints are bit-identical to the historical rig; the pivot plane is invariant mid-morph',
    () {
      const size = Size(393, 756);
      final rng = math.Random(3);
      CloudCamera mk(math.Random r, {required bool ortho, double? mix}) =>
          CloudCamera(
            yaw: r.nextDouble() * 6 - 3,
            pitch: r.nextDouble() * 2 - 1,
            roll: r.nextDouble() - .5,
            zoom: 0.5 + r.nextDouble() * 2,
            panX: r.nextDouble() * 40 - 20,
            panY: r.nextDouble() * 40 - 20,
            pivotX: r.nextDouble(),
            pivotY: r.nextDouble(),
            pivotZ: r.nextDouble(),
            radius: 0.5 + r.nextDouble() * 3,
            orthographic: ortho,
            orthoMix: mix,
          );
      for (var t = 0; t < 30; t++) {
        final seed = rng.nextInt(1 << 30);
        // the same random camera, built four ways from the same seed
        final o1 = mk(math.Random(seed), ortho: true).projectionFor(size);
        final o2 = mk(
          math.Random(seed),
          ortho: true,
          mix: 1.0,
        ).projectionFor(size);
        final p1 = mk(math.Random(seed), ortho: false).projectionFor(size);
        final p2 = mk(
          math.Random(seed),
          ortho: false,
          mix: 0.0,
        ).projectionFor(size);
        final half = mk(
          math.Random(seed),
          ortho: false,
          mix: 0.37,
        ).projectionFor(size);
        final pt = [
          rng.nextDouble() * 4 - 2,
          rng.nextDouble() * 4 - 2,
          rng.nextDouble() * 4 - 2,
        ];
        expect(
          o2.project(pt[0], pt[1], pt[2]),
          equals(o1.project(pt[0], pt[1], pt[2])),
        );
        expect(
          p2.project(pt[0], pt[1], pt[2]),
          equals(p1.project(pt[0], pt[1], pt[2])),
        );
        // mid-morph: a point ON the pivot plane (z2 == 0) projects identically for every mix.
        // Row 3 of the (roll-free) view matrix is the depth axis; remove the point's z2 along it.
        final m = composeViewMatrix(
          math.atan2(p1.sinY, p1.cosY),
          math.atan2(p1.sinP, p1.cosP),
          0,
        );
        final q = [p1.pivotX + 0.3, p1.pivotY - 0.2, p1.pivotZ + 0.1];
        final z2 =
            m[6] * (q[0] - p1.pivotX) +
            m[7] * (q[1] - p1.pivotY) +
            m[8] * (q[2] - p1.pivotZ);
        final onPlane = [q[0] - m[6] * z2, q[1] - m[7] * z2, q[2] - m[8] * z2];
        final (hx, hy, hd) = half.project(onPlane[0], onPlane[1], onPlane[2]);
        final (fx, fy, fd) = p1.project(onPlane[0], onPlane[1], onPlane[2]);
        expect(hd, closeTo(fd, 1e-9));
        expect(hx, closeTo(fx, 1e-7));
        expect(hy, closeTo(fy, 1e-7));
      }
    },
  );
}
