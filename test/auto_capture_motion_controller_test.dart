import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_controller.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_geometry.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_governor.dart';
import 'package:pocketworld_flutter/official_capture/shutter_backpressure_gate.dart';
import 'package:pocketworld_flutter/official_dome/ar_pose.dart';
import 'package:vector_math/vector_math_64.dart';

ARPose _pose({
  required double t,
  Vector3? position,
  double yawDeg = 0,
  bool isTracking = true,
  String? trackingStateName = 'normal',
}) {
  return ARPose(
    position: position ?? Vector3.zero(),
    orientation: Quaternion.axisAngle(Vector3(0, 1, 0), yawDeg * math.pi / 180),
    azimuth: 0,
    elevation: 0,
    isTracking: isTracking,
    trackingStateName: trackingStateName,
    timestamp: t,
    hasOrigin: true,
    worldOrigin: Vector3(0, 0, -1),
    worldYaw: 0,
    extrinsic4x4: const <double>[],
    intrinsicFxFyCxCy: const <double>[400, 400, 500, 500],
    imageWidth: 1000,
    imageHeight: 1000,
  );
}

class _Harness {
  int fires = 0;

  late final AutoCaptureController controller = AutoCaptureController(
    onFire: () {
      fires++;
      return true;
    },
    paceProvider: () => ShutterPace.normal,
    capturedCountProvider: () => fires,
    thermalStateProvider: () => 0,
    liveDepthProvider: (_) => null,
  );
}

void main() {
  test('rotation coverage updates only the capture baseline', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));

    expect(
      h.controller.onPose(_pose(t: 1, yawDeg: 12)),
      AutoCaptureDecision.fire,
    );
    expect(h.controller.lastMotionRole, AutoCaptureMotionRole.rotationCoverage);
    expect(h.controller.baselinePosition, Vector3.zero());
    expect(h.controller.geometryBaselinePosition, Vector3.zero());

    expect(
      h.controller.onPose(_pose(t: 2, position: Vector3(0.22, 0, 0))),
      AutoCaptureDecision.fire,
    );
    expect(h.controller.lastMotionRole, AutoCaptureMotionRole.geometry);
    expect(h.controller.geometryBaselinePosition, Vector3(0.22, 0, 0));
  });

  test('radial bridge does not advance the geometry baseline', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));

    expect(
      h.controller.onPose(_pose(t: 1, position: Vector3(0, 0, -0.2))),
      AutoCaptureDecision.fire,
    );
    expect(h.controller.lastMotionRole, AutoCaptureMotionRole.radialBridge);
    expect(h.controller.baselinePosition, Vector3(0, 0, -0.2));
    expect(h.controller.geometryBaselinePosition, Vector3.zero());
  });

  test('regular geometry is movement-driven after duplicate debounce', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));

    expect(
      h.controller.onPose(_pose(t: 0.25, position: Vector3(0.22, 0, 0))),
      AutoCaptureDecision.fire,
    );
    expect(h.controller.lastMotionRole, AutoCaptureMotionRole.geometry);
  });

  test('overlap safety can fire at the 250 ms debounce and asks to slow', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));

    expect(
      h.controller.onPose(_pose(t: 0.25, position: Vector3(0.76, 0, 0))),
      AutoCaptureDecision.fire,
    );
    expect(h.controller.lastMotionRole, AutoCaptureMotionRole.overlapSafety);
    expect(h.controller.shouldPromptSlowDown, isTrue);
  });

  test('an Apple-specific tracking string cannot veto a normalized pose', () {
    final h = _Harness();
    h.controller.start(
      _pose(
        t: 0,
        isTracking: true,
        trackingStateName: 'limited_excessiveMotion',
      ),
    );

    expect(
      h.controller.onPose(
        _pose(
          t: 1,
          position: Vector3(0.22, 0, 0),
          isTracking: true,
          trackingStateName: 'limited_excessiveMotion',
        ),
      ),
      AutoCaptureDecision.fire,
    );
  });

  test('normalized tracking false still blocks capture', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0, isTracking: false));
    expect(
      h.controller.onPose(
        _pose(t: 1, position: Vector3(0.22, 0, 0), isTracking: false),
      ),
      AutoCaptureDecision.skipTracking,
    );
  });
}
