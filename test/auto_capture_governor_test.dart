import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_geometry.dart';
import 'package:pocketworld_flutter/official_capture/auto_capture_governor.dart';
import 'package:pocketworld_flutter/official_capture/continuous_feature_tracks.dart';
import 'package:pocketworld_flutter/official_capture/shutter_backpressure_gate.dart';

AutoCaptureMotionMetrics _motion(
  AutoCaptureMotionRole role, {
  bool geometryEligible = false,
  bool rotationCoverageEligible = false,
  bool radialBridgeEligible = false,
  bool overlapSafetyEligible = false,
}) => AutoCaptureMotionMetrics(
  role: role,
  geometryParallaxDeg: role == AutoCaptureMotionRole.geometry ? 12 : 0,
  geometryThresholdDeg: 12,
  horizontalBaselineM: 0,
  verticalBaselineM: 0,
  radialTravelM: 0,
  depthScaleRatio: 1,
  viewTurnDeg: 0,
  overlapFraction: overlapSafetyEligible ? 0.69 : 0.9,
  advancesGeometryBaseline: role == AutoCaptureMotionRole.geometry,
  shouldPromptSlowDown: overlapSafetyEligible,
  overlapSafetyEligible: overlapSafetyEligible,
  geometryEligible: geometryEligible,
  rotationCoverageEligible: rotationCoverageEligible,
  radialBridgeEligible: radialBridgeEligible,
);

AutoCaptureDecision _decide({
  AutoCaptureMotionRole role = AutoCaptureMotionRole.none,
  bool trackingNormal = true,
  int capturedCount = 10,
  double elapsedSec = 30,
  double sinceLastTickSec = 1,
  double tickIntervalSec = kAutoCaptureNormalIntervalSec,
  bool blurry = false,
  bool geometryEligible = false,
  bool rotationCoverageEligible = false,
  bool radialBridgeEligible = false,
  bool overlapSafetyEligible = false,
  double? visualSimilarity = 0.0,
  FrameTrackEvidence? trackEvidence,
  bool trackEvidenceRequired = false,
  bool smartSelectionMotionReady = true,
}) => autoCaptureDecideMotion(
  trackingNormal: trackingNormal,
  capturedCount: capturedCount,
  elapsedSec: elapsedSec,
  sinceLastTickSec: sinceLastTickSec,
  tickIntervalSec: tickIntervalSec,
  motion: _motion(
    role,
    geometryEligible: geometryEligible,
    rotationCoverageEligible: rotationCoverageEligible,
    radialBridgeEligible: radialBridgeEligible,
    overlapSafetyEligible: overlapSafetyEligible,
  ),
  visualSimilarity: visualSimilarity,
  trackEvidence: trackEvidence,
  trackEvidenceRequired: trackEvidenceRequired,
  smartSelectionMotionReady: smartSelectionMotionReady,
  blurry: blurry,
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

  test('overlap warning alone prompts but does not spend a photo', () {
    expect(
      _decide(overlapSafetyEligible: true, sinceLastTickSec: 1),
      AutoCaptureDecision.skipNotMoved,
    );
  });

  test(
    'overlap warning never bypasses stretched pace even with spatial value',
    () {
      expect(
        _decide(
          role: AutoCaptureMotionRole.geometry,
          overlapSafetyEligible: true,
          sinceLastTickSec: 0.249,
          tickIntervalSec: 3,
          geometryEligible: true,
        ),
        AutoCaptureDecision.skipPaced,
      );
      expect(
        _decide(
          role: AutoCaptureMotionRole.geometry,
          overlapSafetyEligible: true,
          sinceLastTickSec: 0.25,
          tickIntervalSec: 3,
          geometryEligible: true,
        ),
        AutoCaptureDecision.skipPaced,
      );
    },
  );

  test('overlap warning never bypasses blur deferral', () {
    expect(
      _decide(
        role: AutoCaptureMotionRole.radialBridge,
        overlapSafetyEligible: true,
        sinceLastTickSec: 0.25,
        blurry: true,
        radialBridgeEligible: true,
      ),
      AutoCaptureDecision.skipBlurry,
    );
    expect(
      _decide(role: AutoCaptureMotionRole.geometry, blurry: true),
      AutoCaptureDecision.skipBlurry,
    );
  });

  test('spatial candidate needs fresh visual evidence', () {
    expect(
      _decide(role: AutoCaptureMotionRole.geometry, visualSimilarity: null),
      AutoCaptureDecision.skipNoVisualEvidence,
    );
  });

  test('VINS under-20 track loss waits for reseeded visual evidence', () {
    const lostTracks = FrameTrackEvidence(
      seedTrackCount: 114,
      commonTrackCount: 19,
      commonTrackFraction: 19 / 114,
      medianPixelDisplacement: 26.8,
      medianNormalizedDisplacement: 0.21,
    );
    expect(
      _decide(
        role: AutoCaptureMotionRole.geometry,
        trackEvidenceRequired: true,
        trackEvidence: lostTracks,
      ),
      AutoCaptureDecision.skipNoVisualEvidence,
    );
    expect(
      _decide(
        role: AutoCaptureMotionRole.geometry,
        trackEvidenceRequired: true,
        trackEvidence: lostTracks,
        blurry: true,
      ),
      AutoCaptureDecision.skipNoVisualEvidence,
    );
  });

  test('VINS parallax alone cannot bypass the smart motion segment', () {
    const vinsCandidate = FrameTrackEvidence(
      seedTrackCount: 114,
      commonTrackCount: 80,
      commonTrackFraction: 80 / 114,
      medianPixelDisplacement: 4,
      medianNormalizedDisplacement: 4 / 128,
    );
    expect(vinsCandidate.hasEnoughNovelty, isTrue);
    expect(
      _decide(
        role: AutoCaptureMotionRole.geometry,
        trackEvidenceRequired: true,
        trackEvidence: vinsCandidate,
        smartSelectionMotionReady: false,
      ),
      AutoCaptureDecision.skipRedundant,
    );
    expect(
      _decide(
        role: AutoCaptureMotionRole.geometry,
        trackEvidenceRequired: true,
        trackEvidence: vinsCandidate,
        smartSelectionMotionReady: true,
      ),
      AutoCaptureDecision.fire,
    );
  });

  test('missing or never-healthy tracks still fail closed', () {
    const noTracks = FrameTrackEvidence(
      seedTrackCount: 0,
      commonTrackCount: 0,
      commonTrackFraction: 0,
      medianPixelDisplacement: double.nan,
      medianNormalizedDisplacement: double.nan,
    );
    expect(
      _decide(
        role: AutoCaptureMotionRole.geometry,
        trackEvidenceRequired: true,
        trackEvidence: null,
      ),
      AutoCaptureDecision.skipNoVisualEvidence,
    );
    expect(
      _decide(
        role: AutoCaptureMotionRole.geometry,
        trackEvidenceRequired: true,
        trackEvidence: noTracks,
      ),
      AutoCaptureDecision.skipNoVisualEvidence,
    );
  });

  test('Aether similarity above 0.92 hard-rejects a redundant candidate', () {
    expect(
      _decide(
        role: AutoCaptureMotionRole.geometry,
        visualSimilarity: 0.9200001,
      ),
      AutoCaptureDecision.skipRedundant,
    );
    expect(
      _decide(role: AutoCaptureMotionRole.geometry, visualSimilarity: 0.92),
      AutoCaptureDecision.fire,
    );
  });

  test('objective blur is a hard reject and never labels a non-candidate', () {
    expect(_decide(blurry: true), AutoCaptureDecision.skipNotMoved);
    expect(
      _decide(role: AutoCaptureMotionRole.geometry, blurry: true),
      AutoCaptureDecision.skipBlurry,
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

  test('pressure and thermal are telemetry-only and never stretch capture', () {
    double at(ShutterPace pace, int thermal) =>
        autoCaptureTickIntervalSec(pace: pace, thermalState: thermal);

    expect(at(ShutterPace.normal, 0), kAutoCaptureSafetyDebounceSec);
    expect(at(ShutterPace.soft, 0), kAutoCaptureSafetyDebounceSec);
    expect(at(ShutterPace.hard, 0), kAutoCaptureSafetyDebounceSec);
    expect(
      at(ShutterPace.normal, kAutoCaptureThermalSerious),
      kAutoCaptureSafetyDebounceSec,
    );
    expect(
      at(ShutterPace.normal, kAutoCaptureThermalCritical),
      kAutoCaptureSafetyDebounceSec,
    );
    expect(at(ShutterPace.normal, -1), kAutoCaptureSafetyDebounceSec);
    expect(
      at(ShutterPace.hard, kAutoCaptureThermalSerious),
      kAutoCaptureSafetyDebounceSec,
    );
  });
}
