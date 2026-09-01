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

Uint8List _motionGray(int shiftX) {
  const side = 128;
  final out = Uint8List(side * side);
  for (var y = 0; y < side; y++) {
    for (var x = 0; x < side; x++) {
      final worldX = x - shiftX + 2048;
      final value =
          128 +
          48 * math.sin(worldX * 0.071) +
          41 * math.cos(y * 0.093) +
          29 * math.sin((worldX + y) * 0.041) +
          17 * math.cos((worldX - 2 * y) * 0.057);
      out[y * side + x] = value.round().clamp(0, 255);
    }
  }
  return out;
}

FrameQualityReport _quality(
  double t, {
  required int grayShiftX,
  int? signatureByte,
}) => FrameQualityReport(
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
  signature: signatureByte == null
      ? Uint8List.fromList(<int>[
          for (var i = 0; i < 256; i++) ((t * 1000003).round() + i * 73) & 0xff,
        ])
      : (Uint8List(256)..fillRange(0, 256, signatureByte)),
  signatureWidth: 16,
  signatureHeight: 16,
);

ARPose _pose({
  required double t,
  Vector3? position,
  double yawDeg = 0,
  bool isTracking = true,
  String? trackingStateName = 'normal',
  int? signatureByte,
}) {
  final camera = position ?? Vector3.zero();
  final grayShiftX = (camera.x * 80 - camera.z * 80 - yawDeg * (4 / 3)).round();
  return ARPose(
    position: camera,
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
    quality: _quality(t, grayShiftX: grayShiftX, signatureByte: signatureByte),
  );
}

AcceptedAutomaticStill _acceptedStill({
  required Vector3 position,
  required double timestamp,
}) => AcceptedAutomaticStill(
  frame: AutoCaptureGeometryFrame(
    camera: position,
    orientation: Quaternion.identity(),
    intrinsics: const AutoCaptureIntrinsics(
      fx: 3100,
      fy: 3100,
      cx: 2016,
      cy: 1512,
      imageWidth: 4032,
      imageHeight: 3024,
    ),
  ),
  captureTimestamp: timestamp,
  gray128: _motionGray((position.x * 80 - position.z * 80).round()),
);

class _Harness {
  int fires = 0;
  int startAnchorAttempts = 0;
  bool startAnchorSucceeds = true;
  bool synchronousReceipt = true;

  late final AutoCaptureController controller = AutoCaptureController(
    onStartAnchor: (_) {
      startAnchorAttempts++;
      return startAnchorSucceeds;
    },
    onFire: (_) {
      fires++;
      return true;
    },
    paceProvider: () => ShutterPace.normal,
    capturedCountProvider: () => fires,
    thermalStateProvider: () => 0,
    liveDepthProvider: (_) => null,
    synchronousReceiptProvider: () => synchronousReceipt ? true : null,
    testOnlyAllowLegacySignatureEvidence: true,
  );
}

void main() {
  group('automatic still receipt identity', () {
    AutoCaptureController buildController(
      List<AutomaticStillTicket> admitted,
    ) => AutoCaptureController(
      onStartAnchor: (ticket) {
        admitted.add(ticket);
        return true;
      },
      onFire: (ticket) {
        admitted.add(ticket);
        return true;
      },
      paceProvider: () => ShutterPace.normal,
      capturedCountProvider: () => 0,
      thermalStateProvider: () => 0,
      liveDepthProvider: (_) => null,
      testOnlyAllowLegacySignatureEvidence: true,
    );

    test('restart keeps the old ticket as the only automatic transaction', () {
      final admitted = <AutomaticStillTicket>[];
      final controller = buildController(admitted);

      controller.start(_pose(t: 0));
      final oldTicket = admitted.single;
      controller.stop();
      controller.start(_pose(t: 1, position: Vector3(1, 0, 0)));

      expect(admitted, <AutomaticStillTicket>[oldTicket]);
      expect(controller.pendingAutomaticStillTicket, oldTicket);

      expect(
        controller.resolveAutomaticStill(
          ticket: oldTicket,
          accepted: true,
          acceptedStill: _acceptedStill(
            position: Vector3.zero(),
            timestamp: 1.1,
          ),
        ),
        isTrue,
      );
      expect(controller.baselinePosition, isNull);

      controller.onPose(_pose(t: 1.11, position: Vector3(1, 0, 0)));
      expect(admitted, hasLength(2));
      final currentTicket = admitted.last;
      expect(
        controller.resolveAutomaticStill(
          ticket: currentTicket,
          accepted: true,
          acceptedStill: _acceptedStill(
            position: Vector3(1, 0, 0),
            timestamp: 1.1,
          ),
        ),
        isTrue,
      );
      expect(controller.baselinePosition, Vector3(1, 0, 0));
    });

    test(
      'late failure re-arms the restarted run without a second in-flight ticket',
      () {
        final admitted = <AutomaticStillTicket>[];
        final controller = buildController(admitted);

        controller.start(_pose(t: 0));
        final oldTicket = admitted.single;
        controller.stop();
        controller.start(_pose(t: 1));

        expect(admitted, <AutomaticStillTicket>[oldTicket]);

        expect(
          controller.resolveAutomaticStill(ticket: oldTicket, accepted: false),
          isTrue,
        );
        expect(controller.hasPendingAutomaticStill, isFalse);

        controller.onPose(_pose(t: 1.01));
        expect(admitted, hasLength(2));
        final currentTicket = admitted.last;
        expect(controller.pendingAutomaticStillTicket, currentTicket);
      },
    );

    test('wrong ticket in the current generation is ignored', () {
      final admitted = <AutomaticStillTicket>[];
      final controller = buildController(admitted);

      controller.start(_pose(t: 0));
      final currentTicket = admitted.single;
      final wrongTicket = AutomaticStillTicket(
        runGeneration: currentTicket.runGeneration,
        ticketId: currentTicket.ticketId + 1,
      );

      expect(
        controller.resolveAutomaticStill(ticket: wrongTicket, accepted: true),
        isFalse,
      );
      expect(controller.pendingAutomaticStillTicket, currentTicket);
      expect(controller.baselinePosition, isNull);
    });

    test(
      'accepted receipt commits the returned 12MP frame, not its preview',
      () {
        final admitted = <AutomaticStillTicket>[];
        final controller = buildController(admitted);
        controller.start(_pose(t: 0, position: Vector3.zero()));
        final ticket = admitted.single;
        final returnedFrame = AutoCaptureGeometryFrame(
          camera: Vector3(0.45, 0.02, -0.08),
          orientation: Quaternion.axisAngle(Vector3(0, 1, 0), 0.2),
          intrinsics: const AutoCaptureIntrinsics(
            fx: 3100,
            fy: 3100,
            cx: 2016,
            cy: 1512,
            imageWidth: 4032,
            imageHeight: 3024,
          ),
        );

        expect(
          controller.resolveAutomaticStill(
            ticket: ticket,
            accepted: true,
            acceptedStill: AcceptedAutomaticStill(
              frame: returnedFrame,
              captureTimestamp: 0.72,
              gray128: Uint8List(128 * 128),
            ),
          ),
          isTrue,
        );

        expect(controller.baselinePosition, returnedFrame.camera);
        expect(controller.geometryBaselinePosition, returnedFrame.camera);
        expect(controller.lastAcceptedStillTimestamp, 0.72);
      },
    );
  });

  test('starting auto capture photographs the healthy seed immediately', () {
    final h = _Harness();

    h.controller.start(_pose(t: 0));

    expect(h.startAnchorAttempts, 1);
    expect(h.controller.baselinePosition, Vector3.zero());
    expect(h.fires, 0, reason: 'the anchor is not a four-role motion fire');
  });

  test('startup anchor waits for the actual 12MP terminal receipt', () {
    final h = _Harness()..synchronousReceipt = false;

    h.controller.start(_pose(t: 0));

    expect(h.startAnchorAttempts, 1);
    expect(h.controller.hasPendingAutomaticStill, isTrue);
    expect(h.controller.baselinePosition, isNull);
    h.controller.resolveAutomaticStill(
      ticket: h.controller.pendingAutomaticStillTicket!,
      accepted: true,
      acceptedStill: _acceptedStill(position: Vector3.zero(), timestamp: 0.1),
    );
    expect(h.controller.baselinePosition, Vector3.zero());
    expect(h.controller.geometryBaselinePosition, Vector3.zero());
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
    expect(
      h.controller.onPose(_pose(t: 2, position: Vector3(0.22, 0, 0))),
      AutoCaptureDecision.fire,
    );
    expect(h.controller.lastMotionRole, AutoCaptureMotionRole.geometry);
    expect(h.controller.geometryBaselinePosition, Vector3(0.22, 0, 0));
  });

  test('actual 12MP receipt, not ticket admission, commits the baseline', () {
    final h = _Harness();
    h.controller.start(_pose(t: 0));
    expect(h.controller.baselinePosition, Vector3.zero());

    h.synchronousReceipt = false;

    expect(
      h.controller.onPose(_pose(t: 1, yawDeg: 12)),
      AutoCaptureDecision.fire,
    );
    expect(h.controller.hasPendingAutomaticStill, isTrue);
    expect(h.controller.baselinePosition, Vector3.zero());

    h.controller.resolveAutomaticStill(
      ticket: h.controller.pendingAutomaticStillTicket!,
      accepted: false,
    );
    expect(h.controller.hasPendingAutomaticStill, isFalse);
    expect(h.controller.baselinePosition, Vector3.zero());

    expect(h.controller.hasPendingAutomaticStill, isFalse);
  });

  test('a rejected candidate is not blindly retried at the same view', () {
    final admitted = <AutomaticStillTicket>[];
    final controller = AutoCaptureController(
      onStartAnchor: (ticket) {
        admitted.add(ticket);
        return true;
      },
      onFire: (ticket) {
        admitted.add(ticket);
        return true;
      },
      paceProvider: () => ShutterPace.normal,
      capturedCountProvider: () => 0,
      thermalStateProvider: () => 0,
      liveDepthProvider: (_) => null,
      testOnlyAllowLegacySignatureEvidence: true,
    );
    controller.start(_pose(t: 0, signatureByte: 0));
    controller.resolveAutomaticStill(
      ticket: admitted.single,
      accepted: true,
      acceptedStill: _acceptedStill(position: Vector3.zero(), timestamp: 0.1),
    );

    expect(
      controller.onPose(_pose(t: 1, yawDeg: 12, signatureByte: 80)),
      AutoCaptureDecision.fire,
    );
    final rejected = admitted.last;
    controller.resolveAutomaticStill(ticket: rejected, accepted: false);
    expect(
      controller.onPose(_pose(t: 1.3, yawDeg: 12, signatureByte: 80)),
      AutoCaptureDecision.skipRedundant,
    );
    expect(admitted, hasLength(2));

    expect(
      controller.onPose(_pose(t: 1.6, yawDeg: 13, signatureByte: 160)),
      AutoCaptureDecision.fire,
    );
    expect(admitted, hasLength(3));
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
