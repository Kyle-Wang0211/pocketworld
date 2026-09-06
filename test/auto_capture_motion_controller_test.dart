import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_controller.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_geometry.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_governor.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_telemetry.dart';
import 'package:pocketworld_flutter/official_capture/shutter_backpressure_gate.dart';
import 'package:pocketworld_flutter/official_dome/ar_pose.dart';
import 'package:vector_math/vector_math_64.dart';

FrameQualityReport _quality(double t) => FrameQualityReport(
  sharpness: 300,
  roiSharpness: 300,
  multiScaleSharpness252: 300,
  multiScaleSharpness512: 300,
  edgeBlockSharpness: 300,
  backgroundSharpness: 300,
  subjectVsBackgroundSharpnessDelta: 0,
  sharpnessConsensus: 300,
  meanBrightness: 128,
  globalVariance: 100,
  signature: Uint8List.fromList(<int>[
    for (var i = 0; i < 256; i++) ((t * 1000003).round() + i * 73) & 0xff,
  ]),
  signatureWidth: 16,
  signatureHeight: 16,
);

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
    quality: _quality(t),
  );
}

class _Harness {
  int fires = 0;
  int startAnchorAttempts = 0;
  bool startAnchorSucceeds = true;

  late final AutoCaptureController controller = AutoCaptureController(
    onStartAnchor: () {
      startAnchorAttempts++;
      return startAnchorSucceeds;
    },
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
  test('starting auto capture photographs the healthy seed immediately', () {
    final h = _Harness();

    h.controller.start(_pose(t: 0));

    expect(h.startAnchorAttempts, 1);
    expect(h.controller.baselinePosition, Vector3.zero());
    expect(h.fires, 0, reason: 'the anchor is not a four-role motion fire');
  });

  test('a rejected startup anchor is retried without a phantom baseline', () {
    final h = _Harness()..startAnchorSucceeds = false;
    h.controller.start(_pose(t: 0));
    expect(h.controller.baselinePosition, isNull);

    h.controller.onPose(_pose(t: 0.1));
    expect(h.startAnchorAttempts, 1, reason: 'retry obeys the 250 ms floor');
    h.startAnchorSucceeds = true;
    h.controller.onPose(_pose(t: 0.25));
    expect(h.startAnchorAttempts, 2);
    expect(h.controller.baselinePosition, Vector3.zero());
  });

  test(
    'the first healthy pose after an unhealthy start anchors immediately',
    () {
      final h = _Harness();
      h.controller.start(_pose(t: 0, isTracking: false));
      expect(h.startAnchorAttempts, 0);
      expect(h.controller.baselinePosition, isNull);

      h.controller.onPose(_pose(t: 0.1));

      expect(
        h.startAnchorAttempts,
        1,
        reason: 'the 250 ms retry floor applies only after a real rejection',
      );
      expect(h.controller.baselinePosition, Vector3.zero());
    },
  );

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
    // 照片拍成(台架:瞬间);真机由页面在快门事务完成时回调。
    h.controller.onCaptureCompleted(captureTimestampSec: 1);

    expect(
      h.controller.onPose(_pose(t: 2, position: Vector3(0.22, 0, 0))),
      AutoCaptureDecision.fire,
    );
    expect(h.controller.lastMotionRole, AutoCaptureMotionRole.geometry);
    expect(h.controller.geometryBaselinePosition, Vector3(0.22, 0, 0));
  });

  test('[2026-09-06] every actual photo advances both baselines — radial too', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));

    expect(
      h.controller.onPose(_pose(t: 1, position: Vector3(0, 0, -0.2))),
      AutoCaptureDecision.fire,
    );
    expect(h.controller.lastMotionRole, AutoCaptureMotionRole.radialBridge);
    expect(h.controller.baselinePosition, Vector3(0, 0, -0.2));
    // 视差底线(COLMAP 1.5°)按上一张实拍量 ⇒ 几何基准跟着每张实拍走。
    expect(h.controller.geometryBaselinePosition, Vector3(0, 0, -0.2));
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

  test('0.22m geometry fire is unchanged when roll-up telemetry reads it', () {
    final h = _Harness();
    final telemetry = AutoCaptureTelemetry()..recordSessionStart(0);
    h.controller.start(_pose(t: 0));

    final decision = h.controller.onPose(
      _pose(t: 0.25, position: Vector3(0.22, 0, 0)),
    );
    telemetry.recordDecision(
      decision,
      tSec: 0.25,
      pace: ShutterPace.normal,
      motion: h.controller.lastMotionMetrics,
    );

    expect(decision, AutoCaptureDecision.fire);
    expect(h.fires, 1);
    expect(h.controller.lastMotionRole, AutoCaptureMotionRole.geometry);
    expect(h.controller.geometryBaselinePosition, Vector3(0.22, 0, 0));
    final snap = telemetry.snapshot();
    final fireRoles = snap['fire_role_counts']! as Map<String, int>;
    final roles = snap['role_counts']! as Map<String, Object>;
    final geometry = roles['geometry']! as Map<String, int>;
    expect(fireRoles['geometry'], 1);
    expect(geometry['fired'], fireRoles['geometry']);
  });

  test('low-overlap warning stays separate from the geometry fire', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));

    expect(
      h.controller.onPose(_pose(t: 0.25, position: Vector3(0.76, 0, 0))),
      AutoCaptureDecision.fire,
    );
    expect(h.controller.lastMotionRole, AutoCaptureMotionRole.geometry);
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
