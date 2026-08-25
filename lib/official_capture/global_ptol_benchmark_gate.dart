import 'dart:math' as math;

const expectedGlobalPtolArchiveSha256 =
    '9114ec5e078f1730fe4f399789e26994bd26cbaacecb4f6c19f3c3120f2fc3f4';
const expectedGlobalPtolArchiveManifestSha256 =
    '3e0757b9f3ae3a9e69c087c9a2f7c5d7c0ad0fc47f2e59531634ba8d19874f7e';
const expectedGlobalPtolPoseSha256 =
    'd4f6d3c079cf9993cee9dceb7b5e3445ac990f1f2626986b95acbdcb35b615c1';
const expectedGlobalPtolFedFramesSha256 =
    '659e4ac8d4bf4f976956e71b801c74ea0b68a87348734f66c9ddb62067f24f61';
const expectedGlobalPtolArchivePolicySha256 =
    'b381512431f6416bf11fbe667c77e4d027dc60ad48a1ea276a39ee1096dead03';
const expectedGlobalPtolMaterializedSqliteSha256 =
    'f829c281aea6ed7956e3afb134959b663cf35cfee633956029c09d3b2af3290d';
const expectedGlobalPtolNativeFrameworkSha256 =
    'bd1220f12b84b6de06319bda28e2902d375b59b9150d3dd947bc1d04afc34062';

const expectedGlobalPtolArchiveBytes = 7286278;
const expectedGlobalPtolArchiveManifestBytes = 638;
const expectedGlobalPtolPoseBytes = 14176;
const expectedGlobalPtolFedFramesBytes = 97133;
const expectedGlobalPtolArchivePolicyBytes = 252;
const expectedGlobalPtolMaterializedSqliteBytes = 15839232;

class GlobalPtolInputIdentity {
  const GlobalPtolInputIdentity({
    required this.archiveSha256,
    required this.archiveManifestSha256,
    required this.poseSha256,
    required this.materializedSqliteSha256,
    required this.nativeFrameworkSha256,
  });

  final String archiveSha256;
  final String archiveManifestSha256;
  final String poseSha256;
  final String materializedSqliteSha256;
  final String nativeFrameworkSha256;
}

bool isFrozenGlobalPtolInputIdentity(GlobalPtolInputIdentity identity) =>
    identity.archiveSha256 == expectedGlobalPtolArchiveSha256 &&
    identity.archiveManifestSha256 == expectedGlobalPtolArchiveManifestSha256 &&
    identity.poseSha256 == expectedGlobalPtolPoseSha256 &&
    identity.materializedSqliteSha256 ==
        expectedGlobalPtolMaterializedSqliteSha256 &&
    identity.nativeFrameworkSha256 == expectedGlobalPtolNativeFrameworkSha256;

class GlobalPtolArmSpec {
  const GlobalPtolArmSpec({required this.label, required this.ptol});

  final String label;
  final String ptol;
}

class GlobalPtolArmMetrics {
  const GlobalPtolArmMetrics({
    required this.label,
    required this.ptol,
    required this.elapsedMs,
    required this.registeredCameras,
    required this.pointCount,
    required this.reprojectionErrorPx,
    required this.succeeded,
    required this.plyBytes,
  });

  final String label;
  final String ptol;
  final int elapsedMs;
  final int registeredCameras;
  final int pointCount;
  final double reprojectionErrorPx;
  final bool succeeded;
  final int plyBytes;

  Map<String, Object?> toJson() => <String, Object?>{
    'label': label,
    'ptol': ptol,
    'elapsed_ms': elapsedMs,
    'registered': registeredCameras,
    'delivered_points': pointCount,
    'reprojection_error_px': reprojectionErrorPx,
    'succeeded': succeeded,
    'ply_bytes': plyBytes,
  };
}

const globalPtolArmSpecs = <GlobalPtolArmSpec>[
  GlobalPtolArmSpec(label: 'A1', ptol: '0'),
  GlobalPtolArmSpec(label: 'B1', ptol: '1e-8'),
  GlobalPtolArmSpec(label: 'A2', ptol: '0'),
  GlobalPtolArmSpec(label: 'B2', ptol: '1e-8'),
];

bool hasExactGlobalPtolArmOrder(List<GlobalPtolArmMetrics> arms) {
  if (arms.length != globalPtolArmSpecs.length) return false;
  for (var i = 0; i < arms.length; i++) {
    if (arms[i].label != globalPtolArmSpecs[i].label ||
        arms[i].ptol != globalPtolArmSpecs[i].ptol) {
      return false;
    }
  }
  return true;
}

bool passesGlobalPtolQualityGate({
  required GlobalPtolArmMetrics control,
  required GlobalPtolArmMetrics candidate,
}) {
  if (!control.succeeded ||
      !candidate.succeeded ||
      control.plyBytes <= 0 ||
      candidate.plyBytes <= 0 ||
      control.registeredCameras != candidate.registeredCameras ||
      control.pointCount <= 0 ||
      !control.reprojectionErrorPx.isFinite ||
      !candidate.reprojectionErrorPx.isFinite) {
    return false;
  }
  final relativePointDelta =
      (candidate.pointCount - control.pointCount).abs() / control.pointCount;
  return relativePointDelta <= 0.01 + 1e-12 &&
      candidate.reprojectionErrorPx <=
          control.reprojectionErrorPx + 0.01 + 1e-12;
}

bool isGlobalPtolFamilyRepeatable({
  required GlobalPtolArmMetrics first,
  required GlobalPtolArmMetrics second,
}) {
  if (!first.succeeded ||
      !second.succeeded ||
      first.elapsedMs <= 0 ||
      second.elapsedMs <= 0 ||
      first.registeredCameras != second.registeredCameras) {
    return false;
  }
  return _relativePairSpread(first.elapsedMs, second.elapsedMs) <= 0.10 + 1e-12;
}

class GlobalPtolWinnerEvaluation {
  const GlobalPtolWinnerEvaluation({
    required this.eligible,
    required this.aMedianElapsedMs,
    required this.bMedianElapsedMs,
    required this.observedWithinFamilyNoiseFraction,
    required this.requiredImprovementFraction,
    required this.improvementFraction,
  });

  final bool eligible;
  final double aMedianElapsedMs;
  final double bMedianElapsedMs;
  final double observedWithinFamilyNoiseFraction;
  final double requiredImprovementFraction;
  final double improvementFraction;

  Map<String, Object?> toJson() => <String, Object?>{
    'eligible': eligible,
    'a_median_elapsed_ms': aMedianElapsedMs,
    'b_median_elapsed_ms': bMedianElapsedMs,
    'observed_within_family_noise_fraction': observedWithinFamilyNoiseFraction,
    'required_improvement_fraction': requiredImprovementFraction,
    'improvement_fraction': improvementFraction,
  };
}

GlobalPtolWinnerEvaluation evaluateGlobalPtolWinner(
  List<GlobalPtolArmMetrics> arms,
) {
  if (!hasExactGlobalPtolArmOrder(arms)) return _invalidEvaluation;
  final a1 = arms[0];
  final b1 = arms[1];
  final a2 = arms[2];
  final b2 = arms[3];
  final aMedian = (a1.elapsedMs + a2.elapsedMs) / 2.0;
  final bMedian = (b1.elapsedMs + b2.elapsedMs) / 2.0;
  final noise = math.max(
    _relativePairSpread(a1.elapsedMs, a2.elapsedMs),
    _relativePairSpread(b1.elapsedMs, b2.elapsedMs),
  );
  final requiredImprovement = math.max(0.05, noise);
  final improvement = aMedian > 0 ? (aMedian - bMedian) / aMedian : 0.0;
  final qualityPasses =
      passesGlobalPtolQualityGate(control: a1, candidate: b1) &&
      passesGlobalPtolQualityGate(control: a2, candidate: b2);
  final repeatable =
      isGlobalPtolFamilyRepeatable(first: a1, second: a2) &&
      isGlobalPtolFamilyRepeatable(first: b1, second: b2);
  return GlobalPtolWinnerEvaluation(
    eligible:
        qualityPasses &&
        repeatable &&
        bMedian < aMedian &&
        improvement > requiredImprovement + 1e-12,
    aMedianElapsedMs: aMedian,
    bMedianElapsedMs: bMedian,
    observedWithinFamilyNoiseFraction: noise,
    requiredImprovementFraction: requiredImprovement,
    improvementFraction: improvement,
  );
}

double _relativePairSpread(int first, int second) {
  final denominator = math.min(first, second);
  if (denominator <= 0) return double.infinity;
  return (first - second).abs() / denominator;
}

const _invalidEvaluation = GlobalPtolWinnerEvaluation(
  eligible: false,
  aMedianElapsedMs: 0,
  bMedianElapsedMs: 0,
  observedWithinFamilyNoiseFraction: double.infinity,
  requiredImprovementFraction: double.infinity,
  improvementFraction: 0,
);
