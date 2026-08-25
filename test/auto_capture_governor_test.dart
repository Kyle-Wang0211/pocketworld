import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_geometry.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_governor.dart';
import 'package:pocketworld_flutter/official_capture/shutter_backpressure_gate.dart';

AutoCaptureMotionMetrics _motion(AutoCaptureMotionRole role) =>
    AutoCaptureMotionMetrics(
      role: role,
      geometryParallaxDeg: role == AutoCaptureMotionRole.geometry ? 12 : 0,
      geometryThresholdDeg: 12,
      horizontalBaselineM: 0,
      verticalBaselineM: 0,
      radialTravelM: 0,
      depthScaleRatio: 1,
      viewTurnDeg: 0,
      overlapFraction: role == AutoCaptureMotionRole.overlapSafety ? 0.69 : 0.9,
      advancesGeometryBaseline: role == AutoCaptureMotionRole.geometry,
      shouldPromptSlowDown: role == AutoCaptureMotionRole.overlapSafety,
    );

AutoCaptureDecision _decide({
  AutoCaptureMotionRole role = AutoCaptureMotionRole.none,
  bool trackingNormal = true,
  int capturedCount = 10,
  double elapsedSec = 30,
  double sinceLastTickSec = 1,
  double tickIntervalSec = kAutoCaptureNormalIntervalSec,
  bool blurry = false,
  double blurDeferredSec = 0,
}) => autoCaptureDecideMotion(
  trackingNormal: trackingNormal,
  capturedCount: capturedCount,
  elapsedSec: elapsedSec,
  sinceLastTickSec: sinceLastTickSec,
  tickIntervalSec: tickIntervalSec,
  motion: _motion(role),
  blurry: blurry,
  blurDeferredSec: blurDeferredSec,
);

void main() {
  test('geometry, radial, and rotation roles obey only duplicate debounce', () {
    for (final role in <AutoCaptureMotionRole>[
      AutoCaptureMotionRole.geometry,
      AutoCaptureMotionRole.radialBridge,
      AutoCaptureMotionRole.rotationCoverage,
    ]) {
      expect(
        _decide(role: role, sinceLastTickSec: 0.249),
        AutoCaptureDecision.skipPaced,
      );
      expect(
        _decide(role: role, sinceLastTickSec: 0.25),
        AutoCaptureDecision.fire,
      );
    }
  });

  test('overlap safety bypasses stretched pace but not 250 ms debounce', () {
    expect(
      _decide(
        role: AutoCaptureMotionRole.overlapSafety,
        sinceLastTickSec: 0.249,
        tickIntervalSec: 3,
      ),
      AutoCaptureDecision.skipPaced,
    );
    expect(
      _decide(
        role: AutoCaptureMotionRole.overlapSafety,
        sinceLastTickSec: 0.25,
        tickIntervalSec: 3,
      ),
      AutoCaptureDecision.fire,
    );
  });

  test('overlap safety wins over blur deferral', () {
    expect(
      _decide(
        role: AutoCaptureMotionRole.overlapSafety,
        sinceLastTickSec: 0.25,
        blurry: true,
      ),
      AutoCaptureDecision.fire,
    );
    expect(
      _decide(role: AutoCaptureMotionRole.geometry, blurry: true),
      AutoCaptureDecision.skipBlurry,
    );
  });

  test('blur defer is bounded and never labels a non-candidate', () {
    expect(_decide(blurry: true), AutoCaptureDecision.skipNotMoved);
    expect(
      _decide(
        role: AutoCaptureMotionRole.geometry,
        blurry: true,
        blurDeferredSec: kAutoCaptureBlurDeferMaxSec,
      ),
      AutoCaptureDecision.fire,
    );
  });

  test('priority is cap, time, tracking, motion, pace, blur, fire', () {
    expect(
      _decide(
        role: AutoCaptureMotionRole.geometry,
        capturedCount: 300,
        elapsedSec: 300,
        trackingNormal: false,
      ),
      AutoCaptureDecision.skipCapped,
    );
    expect(
      _decide(
        role: AutoCaptureMotionRole.geometry,
        elapsedSec: 300,
        trackingNormal: false,
      ),
      AutoCaptureDecision.skipTimeLimit,
    );
    expect(
      _decide(role: AutoCaptureMotionRole.geometry, trackingNormal: false),
      AutoCaptureDecision.skipTracking,
    );
    expect(_decide(), AutoCaptureDecision.skipNotMoved);
  });

  test('normal pace is debounce-only; pressure and thermal stretch it', () {
    double at(ShutterPace pace, int thermal) =>
        autoCaptureTickIntervalSec(pace: pace, thermalState: thermal);

    expect(at(ShutterPace.normal, 0), kAutoCaptureSafetyDebounceSec);
    expect(at(ShutterPace.soft, 0), 2);
    expect(at(ShutterPace.hard, 0), 3);
    expect(at(ShutterPace.normal, kAutoCaptureThermalSerious), 2);
    expect(at(ShutterPace.normal, kAutoCaptureThermalCritical), 3);
    expect(at(ShutterPace.normal, -1), kAutoCaptureSafetyDebounceSec);
    expect(at(ShutterPace.hard, kAutoCaptureThermalSerious), 3);
  });
}
