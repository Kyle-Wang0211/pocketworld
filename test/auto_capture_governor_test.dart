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
  bool exposureRejected = false,
  bool geometryEligible = false,
  bool rotationCoverageEligible = false,
  bool radialBridgeEligible = false,
  bool overlapSafetyEligible = false,
  double? visualSimilarity = 0.0,
  FrameTrackEvidence? trackEvidence,
  bool trackEvidenceRequired = false,
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
  blurry: blurry,
  exposureRejected: exposureRejected,
);

/// The shutter bar for a 12 MP 4:3 frame on the 128x128 tracker grid.
/// fx = fy = 3230 px is a real iPhone main-camera intrinsic at 4032x3024;
/// the grid focals are that scaled per axis, exactly as the gate scales them.
const double _fx128 = 3230.0 * 128.0 / 4032.0;
const double _fy128 = 3230.0 * 128.0 / 3024.0;
final double _shutterBar = kOfficialCaptureNoveltyThreshold(
  gridWidth: 128,
  gridHeight: 128,
  focalXPixels: _fx128,
  focalYPixels: _fy128,
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

  test('dark or blown preview evidence defers the candidate', () {
    expect(
      _decide(role: AutoCaptureMotionRole.geometry, exposureRejected: true),
      AutoCaptureDecision.skipQuality,
    );
  });

  test('spatial candidate needs fresh visual evidence', () {
    expect(
      _decide(role: AutoCaptureMotionRole.geometry, visualSimilarity: null),
      AutoCaptureDecision.skipNoVisualEvidence,
    );
  });

  test('a geometry candidate stays live when the official VINS keyframe signal '
      'survives after photo-anchor tracks expire', () {
    final replenishedVinsTracks = FrameTrackEvidence(
      seedTrackCount: 132,
      commonTrackCount: 0,
      commonTrackFraction: 0,
      medianPixelDisplacement: double.nan,
      medianNormalizedDisplacement: double.nan,
      vinsTrackedCount: 45,
      vinsActiveTrackCount: 110,
      vinsMeanStepNormalizedParallax: 0.146,
      vinsGeometricInputCount: 92,
      vinsGeometricInlierCount: 46,
      vinsOccupiedGridFraction: 0.875,
      captureNoveltyThresholdNormalized: _shutterBar,
    );
    expect(replenishedVinsTracks.isVinsEstimatorKeyframeCandidate, isTrue);
    expect(
      _decide(
        role: AutoCaptureMotionRole.geometry,
        trackEvidenceRequired: true,
        trackEvidence: replenishedVinsTracks,
      ),
      AutoCaptureDecision.fire,
    );
    expect(
      _decide(
        role: AutoCaptureMotionRole.geometry,
        trackEvidenceRequired: true,
        trackEvidence: replenishedVinsTracks,
        blurry: true,
      ),
      AutoCaptureDecision.skipBlurry,
    );
  });

  test('the official VINS under-20 signal cannot bypass the geometry gate', () {
    final lostTracks = FrameTrackEvidence(
      seedTrackCount: 114,
      commonTrackCount: 0,
      commonTrackFraction: 0,
      medianPixelDisplacement: double.nan,
      medianNormalizedDisplacement: double.nan,
      vinsTrackedCount: 19,
      vinsActiveTrackCount: 100,
      vinsMeanStepNormalizedParallax: 0.001,
      captureNoveltyThresholdNormalized: _shutterBar,
    );
    expect(lostTracks.isVinsEstimatorKeyframeCandidate, isTrue);
    expect(
      _decide(
        role: AutoCaptureMotionRole.none,
        trackEvidenceRequired: true,
        trackEvidence: lostTracks,
      ),
      AutoCaptureDecision.skipNotMoved,
    );
  });

  test('VINS estimator parallax never replaces photographic displacement', () {
    final vinsCandidate = FrameTrackEvidence(
      seedTrackCount: 114,
      commonTrackCount: 80,
      commonTrackFraction: 80 / 114,
      medianPixelDisplacement: 4,
      medianNormalizedDisplacement: 4 / 128,
      captureNoveltyThresholdNormalized: _shutterBar,
    );
    expect(vinsCandidate.hasEnoughNovelty, isTrue);
    expect(
      _decide(
        role: AutoCaptureMotionRole.none,
        trackEvidenceRequired: true,
        trackEvidence: vinsCandidate,
      ),
      AutoCaptureDecision.skipNotMoved,
    );
    expect(
      _decide(
        role: AutoCaptureMotionRole.geometry,
        trackEvidenceRequired: true,
        trackEvidence: vinsCandidate,
      ),
      AutoCaptureDecision.skipRedundant,
    );

    final captureCandidate = FrameTrackEvidence(
      seedTrackCount: 114,
      commonTrackCount: 80,
      commonTrackFraction: 80 / 114,
      medianPixelDisplacement: 14,
      medianNormalizedDisplacement: 14 / 128,
      captureNoveltyThresholdNormalized: _shutterBar,
    );
    expect(captureCandidate.isCaptureNoveltyVerified, isTrue);
    expect(
      _decide(
        role: AutoCaptureMotionRole.geometry,
        trackEvidenceRequired: true,
        trackEvidence: captureCandidate,
      ),
      AutoCaptureDecision.fire,
    );

    final duplicate = FrameTrackEvidence(
      seedTrackCount: 114,
      commonTrackCount: 80,
      commonTrackFraction: 80 / 114,
      medianPixelDisplacement: 1,
      medianNormalizedDisplacement: 1 / 128,
      captureNoveltyThresholdNormalized: _shutterBar,
    );
    expect(
      _decide(
        role: AutoCaptureMotionRole.geometry,
        trackEvidenceRequired: true,
        trackEvidence: duplicate,
      ),
      AutoCaptureDecision.skipRedundant,
    );
  });

  test('missing or never-healthy tracks still fail closed', () {
    final noTracks = FrameTrackEvidence(
      seedTrackCount: 0,
      commonTrackCount: 0,
      commonTrackFraction: 0,
      medianPixelDisplacement: double.nan,
      medianNormalizedDisplacement: double.nan,
      captureNoveltyThresholdNormalized: _shutterBar,
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
