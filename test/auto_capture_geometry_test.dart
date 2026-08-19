import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_geometry.dart';
import 'package:pocketworld_flutter/official_dome/ar_pose.dart';
import 'package:vector_math/vector_math_64.dart';

ARPreviewPoint _pt(double x, double y, double z) =>
    ARPreviewPoint(position: Vector3(x, y, z), r: 0, g: 0, b: 0, confidence: 1);

void main() {
  test('medianSceneDepthM projects onto the forward axis', () {
    // Camera at origin looking down -Z. Points at depth 1,2,3 => median 2.
    final depth = medianSceneDepthM(
      cameraPosition: Vector3.zero(),
      forward: Vector3(0, 0, -1),
      points: <ARPreviewPoint>[
        for (var i = 0; i < 3; i++) _pt(0, 0, -(i + 1).toDouble()),
        // pad to the 8-anchor minimum with copies of the same depths
        for (var i = 0; i < 3; i++) _pt(0.1, 0.1, -(i + 1).toDouble()),
        _pt(0, 0, -2.0),
        _pt(0, 0, -2.0),
      ],
    );
    expect(depth, isNotNull);
    expect(depth!, closeTo(2.0, 1e-9));
  });

  test('medianSceneDepthM returns null below the anchor minimum', () {
    expect(
      medianSceneDepthM(
        cameraPosition: Vector3.zero(),
        forward: Vector3(0, 0, -1),
        points: <ARPreviewPoint>[_pt(0, 0, -1), _pt(0, 0, -2)],
      ),
      isNull,
    );
  });

  test('medianSceneDepthM drops points behind the camera', () {
    // 8 valid at depth 1.0 plus 4 behind-camera points that must not count.
    final depth = medianSceneDepthM(
      cameraPosition: Vector3.zero(),
      forward: Vector3(0, 0, -1),
      points: <ARPreviewPoint>[
        for (var i = 0; i < 8; i++) _pt(0, 0, -1.0),
        for (var i = 0; i < 4; i++) _pt(0, 0, 5.0),
      ],
    );
    expect(depth!, closeTo(1.0, 1e-9));
  });

  test('parallaxAngleDeg is the angle subtended at the target', () {
    // Target 1m ahead; camera slides 1m sideways => 45°.
    final target = Vector3(0, 0, -1);
    expect(
      parallaxAngleDeg(
        baseCamera: Vector3.zero(),
        currentCamera: Vector3(1, 0, 0),
        target: target,
      ),
      closeTo(45.0, 1e-9),
    );
  });

  test('parallaxAngleDeg is ~0 for pure forward motion — the double-wall case',
      () {
    // Walking straight at the object: base, current and target are collinear.
    final target = Vector3(0, 0, -1);
    final deg = parallaxAngleDeg(
      baseCamera: Vector3.zero(),
      currentCamera: Vector3(0, 0, -0.5),
      target: target,
    );
    expect(deg, lessThan(0.001));
  });

  test('viewAxisTurnDeg measures the angle between optical axes', () {
    expect(
      viewAxisTurnDeg(
        baseForward: Vector3(0, 0, -1),
        currentForward: Vector3(1, 0, 0),
      ),
      closeTo(90.0, 1e-9),
    );
  });

  test('normalizedCenterShift is zero when the target stays centred', () {
    expect(
      normalizedCenterShift(
        target: Vector3(0, 0, -1),
        currentCamera: Vector3.zero(),
        currentOrientation: Quaternion.identity(),
        fx: 1000,
        fy: 1000,
        imageWidth: 1000,
        imageHeight: 1000,
      ),
      closeTo(0.0, 1e-9),
    );
  });

  test('normalizedCenterShift grows with lateral camera translation', () {
    // Target 1m ahead, fx = imageWidth => a 0.3m sideways slide puts the
    // target 0.3 * imageWidth px off centre => s = 0.30.
    expect(
      normalizedCenterShift(
        target: Vector3(0, 0, -1),
        currentCamera: Vector3(-0.3, 0, 0),
        currentOrientation: Quaternion.identity(),
        fx: 1000,
        fy: 1000,
        imageWidth: 1000,
        imageHeight: 1000,
      ),
      closeTo(0.30, 1e-9),
    );
  });

  test('normalizedCenterShift is infinite when the target falls behind', () {
    expect(
      normalizedCenterShift(
        target: Vector3(0, 0, 1), // behind a camera that looks down -Z
        currentCamera: Vector3.zero(),
        currentOrientation: Quaternion.identity(),
        fx: 1000,
        fy: 1000,
        imageWidth: 1000,
        imageHeight: 1000,
      ),
      double.infinity,
    );
  });
}
