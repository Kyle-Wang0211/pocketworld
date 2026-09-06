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
  _twoTierLightContract();

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
      meanNormalizedDisplacement: 0.21,
      newFeatureCount: -1,
      liveTrackCount: -1,
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
      meanNormalizedDisplacement: 4 / 128,
      newFeatureCount: -1,
      liveTrackCount: -1,
    );
    expect(vinsCandidate.hasEnoughNovelty, isTrue);
    expect(
      _decide(
        role: AutoCaptureMotionRole.geometry,
        trackEvidenceRequired: true,
        trackEvidence: vinsCandidate,
        smartSelectionMotionReady: false,
      ),
      // [2026-09-06] AliceVision 累计光流是决策者:没到 10% 短边 = 没动够。
      AutoCaptureDecision.skipNotMoved,
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

  test('[2026-09-06 抄对②] 光流到阈后视差角只当 COLMAP 1.5° 底线', () {
    const evidence = FrameTrackEvidence(
      seedTrackCount: 114,
      commonTrackCount: 80,
      commonTrackFraction: 80 / 114,
      medianPixelDisplacement: 4,
      medianNormalizedDisplacement: 4 / 128,
      meanNormalizedDisplacement: 4 / 128,
      newFeatureCount: -1,
      liveTrackCount: -1,
    );
    // 几何角色不合格(视差 0°、无旋转覆盖、无径向)⇒ 光流够也不拍:原地没动。
    expect(
      _decide(
        role: AutoCaptureMotionRole.none,
        trackEvidenceRequired: true,
        trackEvidence: evidence,
        smartSelectionMotionReady: true,
      ),
      AutoCaptureDecision.skipNotMoved,
    );
    // 纯旋转覆盖合格 + 光流够 ⇒ 拍(不需要 12° 视差角)。
    expect(
      _decide(
        role: AutoCaptureMotionRole.rotationCoverage,
        rotationCoverageEligible: true,
        trackEvidenceRequired: true,
        trackEvidence: evidence,
        smartSelectionMotionReady: true,
      ),
      AutoCaptureDecision.fire,
    );
    // 请求中的快门未拍成 ⇒ 不判定。
    expect(
      autoCaptureDecideMotion(
        trackingNormal: true,
        capturedCount: 10,
        elapsedSec: 30,
        sinceLastTickSec: 1,
        tickIntervalSec: kAutoCaptureNormalIntervalSec,
        motion: _motion(AutoCaptureMotionRole.geometry, geometryEligible: true),
        visualSimilarity: 0.0,
        trackEvidence: evidence,
        trackEvidenceRequired: true,
        smartSelectionMotionReady: true,
        awaitingCaptureBaseline: true,
      ),
      AutoCaptureDecision.skipAwaitingCapture,
    );
  });

  test('missing or never-healthy tracks still fail closed', () {
    const noTracks = FrameTrackEvidence(
      seedTrackCount: 0,
      commonTrackCount: 0,
      commonTrackFraction: 0,
      medianPixelDisplacement: double.nan,
      medianNormalizedDisplacement: double.nan,
      meanNormalizedDisplacement: double.nan,
      newFeatureCount: -1,
      liveTrackCount: -1,
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

// ── Apple 两级光照:tooDark 硬停选帧(skipTooDark),lowLight 不设闸 ──────
// ObjectCaptureSession API docs 逐字:
//   .environmentTooDark:  "…too dark to proceed. Auto-capture will stop…"
//   .environmentLowLight: "…Auto-capture still proceeds but reconstruction
//                          quality may suffer."
void _twoTierLightContract() {
  test('tooDark → skipTooDark,先于运动判据(遥测要显示真实原因)', () {
    final d = autoCaptureDecideMotion(
      trackingNormal: true,
      capturedCount: 1,
      elapsedSec: 10,
      sinceLastTickSec: 10,
      tickIntervalSec: 0.25,
      motion: _motion(AutoCaptureMotionRole.geometry, geometryEligible: true),
      visualSimilarity: 0.1,
      blurry: false,
      tooDark: true,
    );
    expect(
      d,
      AutoCaptureDecision.skipTooDark,
      reason: 'Apple: tooDark 时自动拍停止选帧 —— 拍都不拍,没有快门声',
    );
  });

  test('lowLight(不 tooDark)不拦截 —— 照拍', () {
    final d = autoCaptureDecideMotion(
      trackingNormal: true,
      capturedCount: 1,
      elapsedSec: 10,
      sinceLastTickSec: 10,
      tickIntervalSec: 0.25,
      motion: _motion(AutoCaptureMotionRole.geometry, geometryEligible: true),
      visualSimilarity: 0.1,
      blurry: false,
      tooDark: false,
    );
    expect(d, AutoCaptureDecision.fire);
  });
}
