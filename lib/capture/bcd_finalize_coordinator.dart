// Background B/C/D finalize orchestration.
//
// B and D numerics stay in the shared C++/WGSL core. Dart controls only
// deterministic batch order, native lifetime, and append-only publication.
// Existing sparse XYZ/RGB are never removed, reordered, or rewritten.

import 'dart:typed_data';
import 'dart:math' as math;

import '../detector_free_depth_ffi.dart';
import '../structural_candidate_ffi.dart';
import '../structural_planesweep_ffi.dart';

class BcdPointCloud {
  const BcdPointCloud({required this.xyz, required this.rgb});

  final Float32List xyz;
  final Uint8List rgb;

  int get pointCount => xyz.length ~/ 3;

  static BcdPointCloud empty() =>
      BcdPointCloud(xyz: Float32List(0), rgb: Uint8List(0));
}

class BcdPlaneSweepView {
  const BcdPlaneSweepView({
    required this.jpegPath,
    required this.projection3x4,
    required this.cameraCenter,
    required this.width,
    required this.height,
  });

  final String jpegPath;
  final Float64List projection3x4;
  final Float64List cameraCenter;
  final int width;
  final int height;
}

/// One registered frame in the gravity-world/OpenGL-camera convention used by
/// ARKit and ARCore: camera +X right, +Y up, and visible points have -Z.
class BcdRegisteredCameraFrame {
  const BcdRegisteredCameraFrame({
    required this.frameId,
    required this.jpegPath,
    required this.imageWidth,
    required this.imageHeight,
    required this.grayWidth,
    required this.grayHeight,
    required this.grayFx,
    required this.grayFy,
    required this.grayCx,
    required this.grayCy,
    required this.cameraFromWorldQuaternionWxyz,
    required this.cameraFromWorldTranslation,
  });

  final int frameId;
  final String jpegPath;
  final int imageWidth;
  final int imageHeight;
  final int grayWidth;
  final int grayHeight;
  final double grayFx;
  final double grayFy;
  final double grayCx;
  final double grayCy;
  final List<double> cameraFromWorldQuaternionWxyz;
  final List<double> cameraFromWorldTranslation;
}

class BcdPlaneSweepBatch {
  const BcdPlaneSweepBatch({
    required this.pointsXyz,
    required this.candidateCount,
    required this.hypothesesPerCandidate,
    required this.patchN,
    required this.basisU,
    required this.basisV,
    required this.views,
    required this.patchRadiusMByScale,
    required this.minimumStdU8ByScale,
    required this.candidateViewMasks,
    required this.birthOptionsByScale,
    required this.sourceCandidateIndices,
  });

  /// Candidate-major and hypothesis-minor. The first hypothesis of each
  /// candidate is the certified structural-plane point; later hypotheses are
  /// parallel competitors and can never be published.
  final Float32List pointsXyz;
  final int candidateCount;
  final int hypothesesPerCandidate;
  final int patchN;
  final List<double> basisU;
  final List<double> basisV;
  final List<BcdPlaneSweepView> views;
  final List<double> patchRadiusMByScale;
  final List<double> minimumStdU8ByScale;
  final Uint8List candidateViewMasks;
  final List<PlaneSweepBirthOptions> birthOptionsByScale;
  final List<int> sourceCandidateIndices;
}

class BcdStructuralSurfaceRequest {
  const BcdStructuralSurfaceRequest({
    required this.grid,
    required this.depthOffsetsM,
    required this.tilePoints,
    required this.viewMode,
    required this.maximumViews,
    required this.patchN,
    required this.frames,
    required this.patchRadiusMByScale,
    required this.minimumStdU8ByScale,
    required this.birthOptionsByScale,
    this.imageMarginPx = 2,
    this.maximumGrazeDeg = 72,
  });

  final StructuralCandidateGridSpec grid;
  final List<double> depthOffsetsM;
  final int tilePoints;
  final StructuralViewMode viewMode;
  final int maximumViews;
  final int patchN;
  final List<BcdPlaneSweepView> frames;
  final List<double> patchRadiusMByScale;
  final List<double> minimumStdU8ByScale;
  final List<PlaneSweepBirthOptions> birthOptionsByScale;
  final double imageMarginPx;
  final double maximumGrazeDeg;
}

class BcdStructuralBirthResult {
  const BcdStructuralBirthResult({
    required this.cloud,
    required this.acceptedCandidateIndices,
    required this.evidence,
    this.evaluatedCandidateIndices = const [],
  });

  final BcdPointCloud cloud;
  final List<int> evaluatedCandidateIndices;
  final List<int> acceptedCandidateIndices;
  final List<PlaneSweepCandidateResult> evidence;
}

class BcdStructuralEvidenceSummary {
  const BcdStructuralEvidenceSummary({
    required this.evaluated,
    required this.accepted,
    required this.coverageCells5cm,
    required this.medianNcc,
    required this.nccP10,
    required this.medianSupportingViews,
    required this.medianParallaxDeg,
    required this.depthMarginMin,
    required this.depthMarginMedian,
  });

  final int evaluated;
  final int accepted;
  final int coverageCells5cm;
  final double? medianNcc;
  final double? nccP10;
  final double? medianSupportingViews;
  final double? medianParallaxDeg;
  final double? depthMarginMin;
  final double? depthMarginMedian;
}

class BcdStrictWallRescueResult {
  const BcdStrictWallRescueResult({
    required this.eligible,
    required this.addedBirths,
    required this.publication,
    required this.baselineSummary,
    required this.mergedSummary,
    required this.strictMetrics,
    required this.nonRegressionChecks,
  });

  final bool eligible;
  final int addedBirths;
  final BcdStructuralBirthResult publication;
  final BcdStructuralEvidenceSummary baselineSummary;
  final BcdStructuralEvidenceSummary mergedSummary;
  final BcdWallStrictMetrics strictMetrics;
  final Map<String, bool> nonRegressionChecks;
}

class _AcceptedStructuralSite {
  const _AcceptedStructuralSite({
    required this.index,
    required this.xyz,
    required this.rgb,
    required this.evidence,
  });

  final int index;
  final List<double> xyz;
  final List<int> rgb;
  final PlaneSweepCandidateResult evidence;
}

class BcdDetectorFreeBirthResult {
  const BcdDetectorFreeBirthResult({
    required this.cloud,
    required this.bornCandidateIndices,
    required this.floorRerouteCandidateIndices,
    required this.ownership,
  });

  final BcdPointCloud cloud;
  final List<int> bornCandidateIndices;

  /// Reciprocal candidates transferred to B floor adjudication before they
  /// have any product-point identity.
  final List<int> floorRerouteCandidateIndices;
  final ReferenceCertifiedBirthOwnershipResult ownership;

  /// The only authority allowed to mint D product-point identity. The
  /// ownership result delegates [ReferenceCertifiedBirthOwnershipResult.born]
  /// to this same object, so downstream code cannot observe a second truth.
  ReferenceBirthCertificateResult get certificate => ownership.certificate;
}

/// One capture-scoped detector-free depth solve. The first gray plane is the
/// reference image and the remaining planes are its source views, matching
/// [DetectorFreeDepthSession.create]. No image or model state is retained
/// after [BcdFinalizeCoordinator.runAndGateDetectorFreeCandidates] returns.
class BcdDetectorFreeDepthJob {
  const BcdDetectorFreeDepthJob({
    required this.options,
    required this.grayFrames,
    required this.sourceProjections,
    this.aggregation = DetectorFreeViewAggregation.topMinimumWithDissent,
    this.refineOptions = const DetectorFreeRefineOptions(),
  });

  final DetectorFreeDepthOptions options;
  final Float32List grayFrames;
  final Float32List sourceProjections;
  final DetectorFreeViewAggregation aggregation;

  /// Null runs only the interpolated coarse solve. A value runs the bounded
  /// fine solve for each tile after coarse peak selection.
  final DetectorFreeRefineOptions? refineOptions;
}

class BcdDetectorFreeDepthMap {
  const BcdDetectorFreeDepthMap({
    required this.width,
    required this.height,
    required this.depthM,
    required this.accepted,
    this.coarseDepthM,
    this.coarseAccepted,
  });

  final int width;
  final int height;
  final Float32List depthM;
  final Uint8List accepted;

  /// Exact discrete coarse result used to freeze point identity. Fine or
  /// interpolated coordinates may improve an existing birth, but cannot
  /// remove a reciprocal birth that the coarse solve already proved.
  final Float32List? coarseDepthM;
  final Uint8List? coarseAccepted;

  bool get hasCoarseIdentity => coarseDepthM != null && coarseAccepted != null;

  Float32List get identityDepthM => hasCoarseIdentity ? coarseDepthM! : depthM;
  Uint8List get identityAccepted =>
      hasCoarseIdentity ? coarseAccepted! : accepted;
}

class BcdDetectorFreeReciprocalInput {
  const BcdDetectorFreeReciprocalInput({
    required this.imageWidth,
    required this.imageHeight,
    required this.referenceInverseK,
    required this.referenceDepthM,
    required this.referenceAccepted,
    required this.reciprocalDepthsM,
    required this.reciprocalAccepted,
    required this.referenceToReciprocalProjections,
    required this.reciprocalCameraCentersInReference,
    required this.options,
  });

  final int imageWidth;
  final int imageHeight;
  final Float32List referenceInverseK;
  final Float32List referenceDepthM;
  final Uint8List referenceAccepted;
  final Float32List reciprocalDepthsM;
  final Uint8List reciprocalAccepted;
  final Float32List referenceToReciprocalProjections;
  final Float32List reciprocalCameraCentersInReference;
  final DetectorFreeReciprocalOptions options;
}

/// Injectable boundary for deterministic coordinator tests. Production uses
/// [BcdFfiDetectorFreeDepthRunner], which owns the native session lifetime and
/// executes tiles in stable row-major order.
abstract interface class BcdDetectorFreeDepthRunner {
  BcdDetectorFreeDepthMap runDepth(BcdDetectorFreeDepthJob job);

  DetectorFreeReciprocalBirthResult filterReciprocal(
    BcdDetectorFreeReciprocalInput input,
  );
}

class BcdFfiDetectorFreeDepthRunner implements BcdDetectorFreeDepthRunner {
  const BcdFfiDetectorFreeDepthRunner();

  @override
  BcdDetectorFreeDepthMap runDepth(BcdDetectorFreeDepthJob job) {
    final options = job.options;
    options.validate();
    job.refineOptions?.validate();
    final pixels = options.imageWidth * options.imageHeight;
    final depth = Float32List(pixels);
    final accepted = Uint8List(pixels);
    final coarseDepth = Float32List(pixels);
    final coarseAccepted = Uint8List(pixels);
    final session = DetectorFreeDepthSession.create(
      options: options,
      grayFrames: job.grayFrames,
      sourceProjections: job.sourceProjections,
    );
    try {
      session.setViewAggregation(job.aggregation);
      for (
        var originY = 0;
        originY < options.imageHeight;
        originY += options.maxTileHeight
      ) {
        final height = math.min(
          options.maxTileHeight,
          options.imageHeight - originY,
        );
        for (
          var originX = 0;
          originX < options.imageWidth;
          originX += options.maxTileWidth
        ) {
          final width = math.min(
            options.maxTileWidth,
            options.imageWidth - originX,
          );
          final coarse = session.runInterpolatedTile(
            originX: originX,
            originY: originY,
            width: width,
            height: height,
          );
          final refine = job.refineOptions;
          final refined = refine == null
              ? null
              : session.runRefinedTile(
                  originX: originX,
                  originY: originY,
                  width: width,
                  height: height,
                  coarseBestIndex: coarse.bestIndex,
                  coarseAccepted: coarse.accepted,
                  refineOptions: refine,
                );
          final tileDepth = refined?.depthM ?? coarse.depthM;
          final tileAccepted = refined?.accepted ?? coarse.accepted;
          for (var localY = 0; localY < height; localY++) {
            final source = localY * width;
            final target = (originY + localY) * options.imageWidth + originX;
            depth.setRange(target, target + width, tileDepth, source);
            accepted.setRange(target, target + width, tileAccepted, source);
            coarseAccepted.setRange(
              target,
              target + width,
              coarse.accepted,
              source,
            );
            for (var localX = 0; localX < width; localX++) {
              final sourceIndex = source + localX;
              final inverseDepth =
                  options.inverseDepthFirst +
                  coarse.bestIndex[sourceIndex] * options.inverseDepthStep;
              coarseDepth[target + localX] = 1 / inverseDepth;
            }
          }
        }
      }
    } finally {
      session.dispose();
    }
    return BcdDetectorFreeDepthMap(
      width: options.imageWidth,
      height: options.imageHeight,
      depthM: depth,
      accepted: accepted,
      coarseDepthM: coarseDepth,
      coarseAccepted: coarseAccepted,
    );
  }

  @override
  DetectorFreeReciprocalBirthResult filterReciprocal(
    BcdDetectorFreeReciprocalInput input,
  ) => DetectorFreeReciprocalBirth.filterMetricDepths(
    imageWidth: input.imageWidth,
    imageHeight: input.imageHeight,
    referenceInverseK: input.referenceInverseK,
    referenceDepthM: input.referenceDepthM,
    referenceAccepted: input.referenceAccepted,
    reciprocalViewCount:
        input.reciprocalDepthsM.length ~/
        (input.imageWidth * input.imageHeight),
    reciprocalDepthsM: input.reciprocalDepthsM,
    reciprocalAccepted: input.reciprocalAccepted,
    referenceToReciprocalProjections: input.referenceToReciprocalProjections,
    reciprocalCameraCentersInReference:
        input.reciprocalCameraCentersInReference,
    options: input.options,
  );
}

/// Complete product input for D. All matrices use row-major storage and the
/// positive-depth image camera convention shared by the detector-free C ABI.
class BcdDetectorFreeFinalizeRequest {
  const BcdDetectorFreeFinalizeRequest({
    required this.sparseXyz,
    required this.primary,
    required this.reciprocals,
    required this.referenceRgb,
    required this.worldToReferenceProjection3x4,
    required this.referenceToReciprocalProjections,
    required this.reciprocalCameraCentersInReference,
    required this.floorValue,
    required this.selectedFloor,
    required this.certifiedWalls,
    this.reciprocalOptions = const DetectorFreeReciprocalOptions(),
    this.localManifoldOptions = const LocalManifoldBirthOptions(),
  });

  final Float32List sparseXyz;
  final BcdDetectorFreeDepthJob primary;
  final List<BcdDetectorFreeDepthJob> reciprocals;
  final Uint8List referenceRgb;

  /// K[R|t] for the reference depth grid. K must be the inverse of
  /// [DetectorFreeDepthOptions.referenceInverseK].
  final Float32List worldToReferenceProjection3x4;
  final Float32List referenceToReciprocalProjections;
  final Float32List reciprocalCameraCentersInReference;
  final double floorValue;
  final StructuralFloorDomain selectedFloor;
  final List<StructuralWall> certifiedWalls;
  final DetectorFreeReciprocalOptions reciprocalOptions;
  final LocalManifoldBirthOptions localManifoldOptions;
}

class BcdFloorCandidateMetrics {
  const BcdFloorCandidateMetrics({
    required this.proposalIndex,
    required this.accepted,
    required this.coverageCells5cm,
    required this.medianNcc,
  });

  final int proposalIndex;
  final int accepted;
  final int coverageCells5cm;
  final double medianNcc;

  double get winnerScore => accepted * medianNcc.clamp(0, double.infinity);
}

enum BcdFloorSelectionStage {
  coarse10cm,
  fine5cmSingle,
  fine5cmTop2,
  needsFine5cmSingle,
  needsFine5cmTop2,
  rejectedAmbiguous,
}

class BcdFloorSelectionDecision {
  const BcdFloorSelectionDecision({
    required this.decisive,
    required this.stage,
    required this.winnerProposalIndex,
    required this.requiredFineProposalIndices,
  });

  final bool decisive;
  final BcdFloorSelectionStage stage;
  final int? winnerProposalIndex;
  final List<int> requiredFineProposalIndices;
}

class BcdWallStrictMetrics {
  const BcdWallStrictMetrics({
    required this.eligible,
    required this.accepted,
    required this.coverageCells5cm,
    required this.medianNcc,
    required this.nccP10,
  });

  final bool eligible;
  final int accepted;
  final int coverageCells5cm;
  final double medianNcc;
  final double nccP10;

  double get winnerScore => accepted * medianNcc.clamp(0, double.infinity);
}

/// Finite wall rectangle retained with bench evidence for geometric audits.
/// It has no ownership authority: family anchors and multi-view evidence make
/// the product decision, while this domain keeps false merges inspectable.
class BcdWallFiniteDomain {
  const BcdWallFiniteDomain({
    required this.normal,
    required this.basisU,
    required this.basisV,
    required this.planeValue,
    required this.basisVOriginValue,
    required this.boundsU,
    required this.boundsV,
  });

  final List<double> normal;
  final List<double> basisU;
  final List<double> basisV;
  final double planeValue;
  final double basisVOriginValue;
  final List<double> boundsU;
  final List<double> boundsV;
}

class BcdWallCandidateMetrics {
  const BcdWallCandidateMetrics({
    required this.candidateId,
    required this.thetaDeg,
    required this.planeValue,
    required this.sparseScore,
    required this.sparseSupportPoints,
    required this.accepted,
    required this.coverageCells5cm,
    required this.medianNcc,
    required this.nccP10,
    this.incumbent = false,
    this.strict,
    this.finiteDomain,
    this.birthSupportXyz,
  });

  final String candidateId;
  final double thetaDeg;
  final double planeValue;
  final double sparseScore;
  final int sparseSupportPoints;
  final int accepted;
  final int coverageCells5cm;
  final double medianNcc;
  final double nccP10;
  final bool incumbent;
  final BcdWallStrictMetrics? strict;
  final BcdWallFiniteDomain? finiteDomain;

  /// Base-scale multi-view births retained for reproducible owner audits.
  final List<double>? birthSupportXyz;

  double get winnerScore => accepted * medianNcc.clamp(0, double.infinity);
}

class BcdWallSelectionDecision {
  const BcdWallSelectionDecision({
    required this.selectedCandidateIds,
    required this.requiredStrictCandidateIds,
    required this.unresolvedFamilyCount,
  });

  final List<String> selectedCandidateIds;
  final List<String> requiredStrictCandidateIds;
  final int unresolvedFamilyCount;

  bool get complete => requiredStrictCandidateIds.isEmpty;
}

class BcdFinalizeResult {
  const BcdFinalizeResult({
    required this.cloud,
    required this.originalPointCount,
    required this.structuralBirthCount,
    required this.detectorFreeBirthCount,
  });

  final BcdPointCloud cloud;
  final int originalPointCount;
  final int structuralBirthCount;
  final int detectorFreeBirthCount;
}

class BcdFinalizeCoordinator {
  BcdFinalizeCoordinator._();

  // Native compares float depths against 0.05f. Use the same representable
  // threshold instead of a wider Dart double literal at the FFI boundary.
  static final double _detectorFreeMinimumMetricDepthM = Float32List.fromList(
    const [0.05],
  ).single;

  /// Exact product port of the frozen floor owner selector. Sparse proposal
  /// score never decides ownership: only multi-view accepted sites and their
  /// median ZNCC can select one physical floor. Ambiguity fails closed or asks
  /// the caller to run a denser 5cm sweep for only the required candidate(s).
  static BcdFloorSelectionDecision selectFloorOwner({
    required List<BcdFloorCandidateMetrics> coarse,
    List<BcdFloorCandidateMetrics> fine = const [],
  }) {
    if (coarse.isEmpty ||
        coarse.any(
          (row) =>
              row.proposalIndex < 0 ||
              row.accepted < 0 ||
              row.coverageCells5cm < 0 ||
              !row.medianNcc.isFinite,
        ) ||
        coarse.map((row) => row.proposalIndex).toSet().length !=
            coarse.length ||
        fine.any(
          (row) =>
              row.proposalIndex < 0 ||
              row.accepted < 0 ||
              row.coverageCells5cm < 0 ||
              !row.medianNcc.isFinite,
        ) ||
        fine.map((row) => row.proposalIndex).toSet().length != fine.length) {
      throw ArgumentError('floor owner metrics are malformed or duplicated');
    }
    final ranking = [...coarse]..sort(_compareFloorMetrics);
    final winner = ranking.first;
    final runnerUp = ranking.length > 1 ? ranking[1] : null;
    final coarseDecisive =
        winner.accepted >= 12 &&
        winner.coverageCells5cm >= 12 &&
        winner.winnerScore >= (runnerUp?.winnerScore ?? 0) * 1.25 &&
        winner.accepted >= (runnerUp?.accepted ?? 0) + 5;
    if (coarseDecisive) {
      return BcdFloorSelectionDecision(
        decisive: true,
        stage: BcdFloorSelectionStage.coarse10cm,
        winnerProposalIndex: winner.proposalIndex,
        requiredFineProposalIndices: const [],
      );
    }

    final required = [
      winner.proposalIndex,
      if (runnerUp != null) runnerUp.proposalIndex,
    ];
    final fineByIndex = {for (final row in fine) row.proposalIndex: row};
    if (required.any((index) => !fineByIndex.containsKey(index))) {
      return BcdFloorSelectionDecision(
        decisive: false,
        stage: runnerUp == null
            ? BcdFloorSelectionStage.needsFine5cmSingle
            : BcdFloorSelectionStage.needsFine5cmTop2,
        winnerProposalIndex: null,
        requiredFineProposalIndices: List.unmodifiable(required),
      );
    }
    if (runnerUp == null) {
      final refined = fineByIndex[winner.proposalIndex]!;
      final decisive = refined.accepted >= 12 && refined.coverageCells5cm >= 12;
      return BcdFloorSelectionDecision(
        decisive: decisive,
        stage: decisive
            ? BcdFloorSelectionStage.fine5cmSingle
            : BcdFloorSelectionStage.rejectedAmbiguous,
        winnerProposalIndex: decisive ? refined.proposalIndex : null,
        requiredFineProposalIndices: const [],
      );
    }
    final refined = [for (final index in required) fineByIndex[index]!]
      ..sort(_compareFloorMetrics);
    final refinedWinner = refined[0];
    final refinedRunnerUp = refined[1];
    final decisive =
        refinedWinner.accepted >= 20 &&
        refinedWinner.coverageCells5cm >= 20 &&
        refinedWinner.winnerScore >= refinedRunnerUp.winnerScore * 1.25 &&
        refinedWinner.accepted >= refinedRunnerUp.accepted + 10;
    return BcdFloorSelectionDecision(
      decisive: decisive,
      stage: decisive
          ? BcdFloorSelectionStage.fine5cmTop2
          : BcdFloorSelectionStage.rejectedAmbiguous,
      winnerProposalIndex: decisive ? refinedWinner.proposalIndex : null,
      requiredFineProposalIndices: const [],
    );
  }

  static int _compareFloorMetrics(
    BcdFloorCandidateMetrics left,
    BcdFloorCandidateMetrics right,
  ) {
    final score = right.winnerScore.compareTo(left.winnerScore);
    if (score != 0) return score;
    final accepted = right.accepted.compareTo(left.accepted);
    if (accepted != 0) return accepted;
    return left.proposalIndex.compareTo(right.proposalIndex);
  }

  /// Exact Dart port of the frozen wall-family owner policy. Certified legacy
  /// walls anchor distinct families. Open families publish at most one wall;
  /// ambiguity either requests the strict scale or fails closed. The secondary
  /// gate is not a threshold relaxation: image and independent sparse evidence
  /// must both dominate, which makes ULP-level candidate-domain drift harmless.
  static BcdWallSelectionDecision selectWallOwners(
    List<BcdWallCandidateMetrics> candidates,
  ) {
    _validateWallCandidates(candidates);
    if (candidates.isEmpty) {
      return const BcdWallSelectionDecision(
        selectedCandidateIds: [],
        requiredStrictCandidateIds: [],
        unresolvedFamilyCount: 0,
      );
    }
    final families = _wallFamilies(candidates);
    final selected = <String>[];
    final requiredStrict = <String>[];
    var unresolved = 0;
    for (final family in families) {
      final ranking = [...family]
        ..sort((left, right) => _compareWallBase(candidates, left, right));
      final evidenceWinner = ranking.first;
      final evidenceRunner = ranking.length > 1 ? ranking[1] : null;
      final incumbentRanking = [
        for (final index in family)
          if (candidates[index].incumbent &&
              _passesWallBirthMinimum(candidates[index]))
            index,
      ]..sort((left, right) => _compareWallBase(candidates, left, right));
      final incumbent = incumbentRanking.isEmpty
          ? null
          : incumbentRanking.first;
      int? winner;
      if (incumbent == null) {
        if (_wallDecisivelyBeats(
          candidates[evidenceWinner],
          evidenceRunner == null ? null : candidates[evidenceRunner],
          allowDualEvidence: true,
        )) {
          winner = evidenceWinner;
        }
      } else if (evidenceWinner == incumbent) {
        winner = incumbent;
      } else if (_wallDecisivelyBeats(
        candidates[evidenceWinner],
        candidates[incumbent],
      )) {
        winner = evidenceWinner;
      } else {
        winner = incumbent;
      }
      if (winner != null) {
        selected.add(candidates[winner].candidateId);
        continue;
      }

      final contenders = [
        for (final index in family)
          if (_passesWallBirthMinimum(candidates[index])) index,
      ];
      if (contenders.length < 2) {
        unresolved++;
        continue;
      }
      final missingStrict = [
        for (final index in contenders)
          if (candidates[index].strict == null) candidates[index].candidateId,
      ];
      if (missingStrict.isNotEmpty) {
        requiredStrict.addAll(missingStrict);
        unresolved++;
        continue;
      }
      final eligible = [
        for (final index in contenders)
          if (candidates[index].strict!.eligible) index,
      ]..sort((left, right) => _compareWallStrict(candidates, left, right));
      if (eligible.length == 1) {
        selected.add(candidates[eligible.first].candidateId);
        continue;
      }
      if (eligible.length >= 2) {
        final strictWinner = candidates[eligible[0]].strict!;
        final strictRunner = candidates[eligible[1]].strict!;
        if (strictWinner.winnerScore >= strictRunner.winnerScore * 1.25 &&
            strictWinner.accepted >= strictRunner.accepted + 3) {
          selected.add(candidates[eligible[0]].candidateId);
          continue;
        }
      }
      unresolved++;
    }
    return BcdWallSelectionDecision(
      selectedCandidateIds: List.unmodifiable(selected),
      requiredStrictCandidateIds: List.unmodifiable(requiredStrict),
      unresolvedFamilyCount: unresolved,
    );
  }

  /// Converts only image-certified envelope proposals into the finite wall
  /// ABI consumed by D ownership. The selector must be complete; unresolved
  /// proposals never receive a `certified` bit. Existing legacy incumbents are
  /// supplied separately and remain byte-for-byte untouched.
  static List<StructuralWall> certifyEnvelopeWallOwners({
    required List<StructuralEnvelopeWallProposal> proposals,
    required BcdWallSelectionDecision decision,
    String candidateIdPrefix = 'envelope__wall_envelope_',
  }) {
    if (!decision.complete || candidateIdPrefix.isEmpty) {
      throw StateError('wall ownership is incomplete or has no ID namespace');
    }
    final byIndex = <int, StructuralEnvelopeWallProposal>{};
    for (final proposal in proposals) {
      if (proposal.index < 0 || byIndex.containsKey(proposal.index)) {
        throw ArgumentError('envelope wall proposal indices are invalid');
      }
      byIndex[proposal.index] = proposal;
    }
    final result = <StructuralWall>[];
    for (final candidateId in decision.selectedCandidateIds) {
      if (!candidateId.startsWith(candidateIdPrefix)) continue;
      final suffix = candidateId.substring(candidateIdPrefix.length);
      final index = int.tryParse(suffix);
      final proposal = index == null ? null : byIndex[index];
      if (proposal == null) {
        throw StateError('selected envelope wall is absent: $candidateId');
      }
      result.add(
        StructuralWall(
          index: proposal.index,
          thetaDeg: proposal.thetaDeg.round(),
          certified: true,
          supportPoints35mm: proposal.supportPoints35mm,
          coverageCells10cm: proposal.coverageCells10cm,
          domainPoints: proposal.supportPoints35mm,
          supportPoints20mm: [0, 0, proposal.supportPoints35mm, 0, 0],
          supportCells10cm: [0, 0, proposal.coverageCells10cm, 0, 0],
          normal: proposal.normal,
          basisU: proposal.basisU,
          basisV: proposal.basisV,
          planeValue: proposal.planeValue,
          boundsU: proposal.boundsU,
          boundsHeight: proposal.boundsHeight,
          score: proposal.score,
          supportProminenceVs5cm: 0,
          coverageProminenceVs5cm: 0,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  /// Certifies both sparse-fit and camera-envelope wall proposals after one
  /// complete image-owner decision. This is the production form used when a
  /// scene (cap41/50/51) needs both proposal populations.
  static List<StructuralWall> certifyWallOwners({
    required List<StructuralWall> legacyProposals,
    required List<StructuralEnvelopeWallProposal> envelopeProposals,
    required BcdWallSelectionDecision decision,
  }) {
    if (!decision.complete) {
      throw StateError('wall ownership is incomplete');
    }
    final legacyById = {
      for (final proposal in legacyProposals)
        'legacy__wall_${proposal.index}': proposal,
    };
    final envelopeById = {
      for (final proposal in envelopeProposals)
        'envelope__wall_envelope_${proposal.index}': proposal,
    };
    final certified = <StructuralWall>[];
    for (final candidateId in decision.selectedCandidateIds) {
      final legacy = legacyById[candidateId];
      if (legacy != null) {
        certified.add(_withWallCertification(legacy, true));
        continue;
      }
      final envelope = envelopeById[candidateId];
      if (envelope != null) {
        certified.add(_wallFromEnvelope(envelope));
        continue;
      }
      throw StateError('selected wall proposal is absent: $candidateId');
    }
    return List.unmodifiable(certified);
  }

  static StructuralWall _withWallCertification(
    StructuralWall wall,
    bool certified,
  ) => StructuralWall(
    index: wall.index,
    thetaDeg: wall.thetaDeg,
    certified: certified,
    supportPoints35mm: wall.supportPoints35mm,
    coverageCells10cm: wall.coverageCells10cm,
    domainPoints: wall.domainPoints,
    supportPoints20mm: wall.supportPoints20mm,
    supportCells10cm: wall.supportCells10cm,
    normal: wall.normal,
    basisU: wall.basisU,
    basisV: wall.basisV,
    planeValue: wall.planeValue,
    boundsU: wall.boundsU,
    boundsHeight: wall.boundsHeight,
    score: wall.score,
    supportProminenceVs5cm: wall.supportProminenceVs5cm,
    coverageProminenceVs5cm: wall.coverageProminenceVs5cm,
  );

  static StructuralWall _wallFromEnvelope(
    StructuralEnvelopeWallProposal proposal,
  ) => StructuralWall(
    index: proposal.index,
    thetaDeg: proposal.thetaDeg.round(),
    certified: true,
    supportPoints35mm: proposal.supportPoints35mm,
    coverageCells10cm: proposal.coverageCells10cm,
    domainPoints: proposal.supportPoints35mm,
    supportPoints20mm: [0, 0, proposal.supportPoints35mm, 0, 0],
    supportCells10cm: [0, 0, proposal.coverageCells10cm, 0, 0],
    normal: proposal.normal,
    basisU: proposal.basisU,
    basisV: proposal.basisV,
    planeValue: proposal.planeValue,
    boundsU: proposal.boundsU,
    boundsHeight: proposal.boundsHeight,
    score: proposal.score,
    supportProminenceVs5cm: 0,
    coverageProminenceVs5cm: 0,
  );

  static List<List<int>> _wallFamilies(
    List<BcdWallCandidateMetrics> candidates,
  ) {
    final representatives = <int>[];
    final families = <List<int>>[];
    for (var index = 0; index < candidates.length; index++) {
      if (candidates[index].incumbent) {
        representatives.add(index);
        families.add([index]);
      }
    }
    final challengers =
        [
          for (var index = 0; index < candidates.length; index++)
            if (!candidates[index].incumbent) index,
        ]..sort((left, right) {
          final score = candidates[right].sparseScore.compareTo(
            candidates[left].sparseScore,
          );
          return score != 0 ? score : left.compareTo(right);
        });
    for (final index in challengers) {
      var bestFamily = -1;
      var bestAngle = double.infinity;
      var bestValue = double.infinity;
      for (var family = 0; family < families.length; family++) {
        final representative = candidates[representatives[family]];
        final angle = _wallAngleDistance(
          candidates[index].thetaDeg,
          representative.thetaDeg,
        );
        final value = (candidates[index].planeValue - representative.planeValue)
            .abs();
        if (angle <= 15 &&
            value <= 0.75 &&
            (angle < bestAngle ||
                (angle == bestAngle &&
                    (value < bestValue ||
                        (value == bestValue && family < bestFamily))))) {
          bestFamily = family;
          bestAngle = angle;
          bestValue = value;
        }
      }
      if (bestFamily >= 0) {
        families[bestFamily].add(index);
      } else {
        representatives.add(index);
        families.add([index]);
      }
    }
    for (final family in families) {
      family.sort();
    }
    return families;
  }

  static double _wallAngleDistance(double left, double right) {
    final difference = (left - right).abs() % 180;
    return difference < 180 - difference ? difference : 180 - difference;
  }

  /// Returns true when either candidate's actual base-scale births mostly lie
  /// inside the other's finite +/-10 cm depth band. This is used only to stop
  /// duplicate sparse proposals from becoming separate family anchors; open
  /// envelope-family ownership remains on the frozen selector above.
  static bool wallBirthSupportsCompete(
    BcdWallCandidateMetrics left,
    BcdWallCandidateMetrics right,
  ) {
    final leftDomain = left.finiteDomain;
    final rightDomain = right.finiteDomain;
    final leftSupport = left.birthSupportXyz;
    final rightSupport = right.birthSupportXyz;
    if (leftDomain == null ||
        rightDomain == null ||
        leftSupport == null ||
        rightSupport == null ||
        leftSupport.isEmpty ||
        rightSupport.isEmpty) {
      return false;
    }
    const maximumCompetingDepthM = 0.10;
    return _wallSupportMostlyInsideDomain(
          leftSupport,
          rightDomain,
          maximumCompetingDepthM,
        ) ||
        _wallSupportMostlyInsideDomain(
          rightSupport,
          leftDomain,
          maximumCompetingDepthM,
        );
  }

  static bool _wallSupportMostlyInsideDomain(
    List<double> supportXyz,
    BcdWallFiniteDomain target,
    double maximumDistanceM,
  ) {
    final total = supportXyz.length ~/ 3;
    final required = (total + 1) ~/ 2;
    var near = 0;
    var visited = 0;
    final targetOriginX =
        target.normal[0] * target.planeValue +
        target.basisV[0] * target.basisVOriginValue;
    final targetOriginY =
        target.normal[1] * target.planeValue +
        target.basisV[1] * target.basisVOriginValue;
    final targetOriginZ =
        target.normal[2] * target.planeValue +
        target.basisV[2] * target.basisVOriginValue;
    // Birth clouds cross the C ABI as Float32.  Keep an exact 10 cm boundary
    // inclusive after the subtractions below without widening the physical
    // competition band by a meaningful amount.
    final maximumDistanceWithFloatSlackM = maximumDistanceM + 1e-6;
    final maximumDistanceSquared =
        maximumDistanceWithFloatSlackM * maximumDistanceWithFloatSlackM;
    for (var offset = 0; offset < supportXyz.length; offset += 3) {
      final relativeX = supportXyz[offset] - targetOriginX;
      final relativeY = supportXyz[offset + 1] - targetOriginY;
      final relativeZ = supportXyz[offset + 2] - targetOriginZ;
      final normalDistance =
          relativeX * target.normal[0] +
          relativeY * target.normal[1] +
          relativeZ * target.normal[2];
      final targetU =
          relativeX * target.basisU[0] +
          relativeY * target.basisU[1] +
          relativeZ * target.basisU[2];
      final targetV =
          relativeX * target.basisV[0] +
          relativeY * target.basisV[1] +
          relativeZ * target.basisV[2];
      final outsideU = targetU < target.boundsU[0]
          ? target.boundsU[0] - targetU
          : targetU > target.boundsU[1]
          ? targetU - target.boundsU[1]
          : 0.0;
      final outsideV = targetV < target.boundsV[0]
          ? target.boundsV[0] - targetV
          : targetV > target.boundsV[1]
          ? targetV - target.boundsV[1]
          : 0.0;
      final distanceSquared =
          normalDistance * normalDistance +
          outsideU * outsideU +
          outsideV * outsideV;
      if (distanceSquared <= maximumDistanceSquared) {
        near++;
      }
      visited++;
      if (near >= required) return true;
      if (near + total - visited < required) return false;
    }
    return near >= required;
  }

  static bool _passesWallBirthMinimum(BcdWallCandidateMetrics row) =>
      row.accepted >= 8 && row.coverageCells5cm >= 8;

  static bool _wallDecisivelyBeats(
    BcdWallCandidateMetrics winner,
    BcdWallCandidateMetrics? runner, {
    bool allowDualEvidence = false,
  }) {
    if (!_passesWallBirthMinimum(winner)) return false;
    if (runner == null) return true;
    final primary =
        winner.winnerScore >= runner.winnerScore * 1.25 &&
        winner.accepted >= runner.accepted + 3;
    if (primary || !allowDualEvidence) return primary;
    return winner.accepted >= runner.accepted + 2 &&
        winner.coverageCells5cm >= runner.coverageCells5cm + 2 &&
        winner.winnerScore >= runner.winnerScore * 1.20 &&
        winner.medianNcc >= runner.medianNcc &&
        winner.nccP10 >= runner.nccP10 &&
        winner.sparseScore >= runner.sparseScore * 1.50 &&
        winner.sparseSupportPoints >= runner.sparseSupportPoints;
  }

  static int _compareWallBase(
    List<BcdWallCandidateMetrics> candidates,
    int left,
    int right,
  ) {
    final score = candidates[right].winnerScore.compareTo(
      candidates[left].winnerScore,
    );
    if (score != 0) return score;
    final accepted = candidates[right].accepted.compareTo(
      candidates[left].accepted,
    );
    return accepted != 0 ? accepted : left.compareTo(right);
  }

  static int _compareWallStrict(
    List<BcdWallCandidateMetrics> candidates,
    int left,
    int right,
  ) {
    final score = candidates[right].strict!.winnerScore.compareTo(
      candidates[left].strict!.winnerScore,
    );
    if (score != 0) return score;
    final accepted = candidates[right].strict!.accepted.compareTo(
      candidates[left].strict!.accepted,
    );
    return accepted != 0 ? accepted : left.compareTo(right);
  }

  static void _validateWallCandidates(
    List<BcdWallCandidateMetrics> candidates,
  ) {
    if (candidates.map((row) => row.candidateId).toSet().length !=
        candidates.length) {
      throw ArgumentError('wall owner candidate ids are duplicated');
    }
    for (final row in candidates) {
      final strict = row.strict;
      final scalarInvalid =
          row.candidateId.isEmpty ||
          !row.thetaDeg.isFinite ||
          !row.planeValue.isFinite ||
          !row.sparseScore.isFinite ||
          row.sparseScore < 0 ||
          row.sparseSupportPoints < 0 ||
          row.accepted < 0 ||
          row.coverageCells5cm < 0 ||
          !row.medianNcc.isFinite ||
          !row.nccP10.isFinite;
      final domainInvalid =
          row.finiteDomain != null &&
          !_validWallFiniteDomain(row.finiteDomain!);
      final supportInvalid = !_validWallBirthSupport(
        row.birthSupportXyz,
        row.accepted,
      );
      final strictInvalid =
          strict != null &&
          (strict.accepted < 0 ||
              strict.coverageCells5cm < 0 ||
              !strict.medianNcc.isFinite ||
              !strict.nccP10.isFinite);
      if (scalarInvalid || domainInvalid || supportInvalid || strictInvalid) {
        throw ArgumentError(
          'wall owner metric ${row.candidateId} is malformed: '
          'scalar=$scalarInvalid domain=$domainInvalid '
          'support=$supportInvalid '
          '(accepted=${row.accepted}, '
          'supportPoints=${(row.birthSupportXyz?.length ?? 0) ~/ 3}) '
          'strict=$strictInvalid',
        );
      }
    }
  }

  static bool _validWallFiniteDomain(BcdWallFiniteDomain domain) {
    final vectors = [domain.normal, domain.basisU, domain.basisV];
    const orthonormalTolerance = 1e-6;
    double squaredNorm(List<double> vector) =>
        vector[0] * vector[0] + vector[1] * vector[1] + vector[2] * vector[2];
    double dot(List<double> left, List<double> right) =>
        left[0] * right[0] + left[1] * right[1] + left[2] * right[2];
    return vectors.every(
          (vector) =>
              vector.length == 3 && vector.every((value) => value.isFinite),
        ) &&
        vectors.every(
          (vector) => (squaredNorm(vector) - 1).abs() <= orthonormalTolerance,
        ) &&
        dot(domain.normal, domain.basisU).abs() <= orthonormalTolerance &&
        dot(domain.normal, domain.basisV).abs() <= orthonormalTolerance &&
        dot(domain.basisU, domain.basisV).abs() <= orthonormalTolerance &&
        domain.planeValue.isFinite &&
        domain.basisVOriginValue.isFinite &&
        domain.boundsU.length == 2 &&
        domain.boundsV.length == 2 &&
        domain.boundsU.every((value) => value.isFinite) &&
        domain.boundsV.every((value) => value.isFinite) &&
        domain.boundsU[1] >= domain.boundsU[0] &&
        domain.boundsV[1] >= domain.boundsV[0];
  }

  static bool _validWallBirthSupport(List<double>? xyz, int accepted) =>
      xyz == null ||
      (xyz.length == accepted * 3 && xyz.every((value) => value.isFinite));

  /// Converts registered AR camera poses into the positive-depth pinhole
  /// convention consumed by shared C++/WGSL. Intrinsics are scaled from the
  /// fed gray grid to the stored JPEG grid. The fixed C=diag(1,-1,-1) camera
  /// conversion changes OpenGL (+Y up, -Z forward) to image (+Y down, +Z
  /// forward); no platform-specific algorithm is involved.
  static List<BcdPlaneSweepView> buildRegisteredPlaneSweepViews(
    List<BcdRegisteredCameraFrame> frames,
  ) {
    if (frames.isEmpty ||
        frames.map((frame) => frame.frameId).toSet().length != frames.length) {
      throw ArgumentError('registered camera frames are empty or duplicated');
    }
    final ordered = [...frames]
      ..sort((left, right) => left.frameId.compareTo(right.frameId));
    final result = <BcdPlaneSweepView>[];
    for (final frame in ordered) {
      final q = frame.cameraFromWorldQuaternionWxyz;
      final t = frame.cameraFromWorldTranslation;
      final scalars = [
        frame.grayFx,
        frame.grayFy,
        frame.grayCx,
        frame.grayCy,
        ...q,
        ...t,
      ];
      if (frame.frameId < 0 ||
          frame.jpegPath.isEmpty ||
          frame.imageWidth <= 1 ||
          frame.imageHeight <= 1 ||
          frame.grayWidth <= 1 ||
          frame.grayHeight <= 1 ||
          q.length != 4 ||
          t.length != 3 ||
          scalars.any((value) => !value.isFinite)) {
        throw ArgumentError('registered camera frame is malformed');
      }
      final qNorm = math.sqrt(
        q[0] * q[0] + q[1] * q[1] + q[2] * q[2] + q[3] * q[3],
      );
      if (!(qNorm > 1e-12)) {
        throw ArgumentError('registered camera quaternion is degenerate');
      }
      final w = q[0] / qNorm;
      final x = q[1] / qNorm;
      final y = q[2] / qNorm;
      final z = q[3] / qNorm;
      final r00 = 1 - 2 * (y * y + z * z);
      final r01 = 2 * (x * y - z * w);
      final r02 = 2 * (x * z + y * w);
      final r10 = 2 * (x * y + z * w);
      final r11 = 1 - 2 * (x * x + z * z);
      final r12 = 2 * (y * z - x * w);
      final r20 = 2 * (x * z - y * w);
      final r21 = 2 * (y * z + x * w);
      final r22 = 1 - 2 * (x * x + y * y);
      final tx = t[0];
      final ty = t[1];
      final tz = t[2];
      final cameraCenter = Float64List.fromList([
        -(r00 * tx + r10 * ty + r20 * tz),
        -(r01 * tx + r11 * ty + r21 * tz),
        -(r02 * tx + r12 * ty + r22 * tz),
      ]);

      final fx = frame.grayFx * frame.imageWidth / frame.grayWidth;
      final fy = frame.grayFy * frame.imageHeight / frame.grayHeight;
      final cx = frame.grayCx * frame.imageWidth / frame.grayWidth;
      final cy = frame.grayCy * frame.imageHeight / frame.grayHeight;
      // C * [R|t], followed by K. Rows 1 and 2 flip sign.
      final c00 = r00, c01 = r01, c02 = r02, ct0 = tx;
      final c10 = -r10, c11 = -r11, c12 = -r12, ct1 = -ty;
      final c20 = -r20, c21 = -r21, c22 = -r22, ct2 = -tz;
      result.add(
        BcdPlaneSweepView(
          jpegPath: frame.jpegPath,
          projection3x4: Float64List.fromList([
            fx * c00 + cx * c20,
            fx * c01 + cx * c21,
            fx * c02 + cx * c22,
            fx * ct0 + cx * ct2,
            fy * c10 + cy * c20,
            fy * c11 + cy * c21,
            fy * c12 + cy * c22,
            fy * ct1 + cy * ct2,
            c20,
            c21,
            c22,
            ct2,
          ]),
          cameraCenter: cameraCenter,
          width: frame.imageWidth,
          height: frame.imageHeight,
        ),
      );
    }
    return List.unmodifiable(result);
  }

  /// Frozen quality-first floor contract used by cap40/41/50/51. The caller
  /// may request 10 cm coarse or 5 cm adaptive refinement; every image gate
  /// and competing-depth hypothesis remains identical between the two.
  static BcdStructuralSurfaceRequest floorSurfaceRequest({
    required StructuralFloorProposal proposal,
    required List<BcdPlaneSweepView> frames,
    required double gridM,
  }) {
    _requirePlaneSweepFrames(frames);
    if (gridM != 0.10 && gridM != 0.05) {
      throw ArgumentError('floor grid must be frozen at 10 cm or 5 cm');
    }
    return BcdStructuralSurfaceRequest(
      grid: StructuralCandidateGridSpec(
        normal: proposal.normal,
        basisU: proposal.basisU,
        basisV: proposal.basisV,
        planeValue: proposal.planeValue,
        basisVOriginValue: 0,
        boundsU: proposal.boundsU,
        boundsV: proposal.boundsV,
        gridM: gridM,
      ),
      depthOffsetsM: const [0, -0.05, 0.05],
      tilePoints: 128,
      viewMode: StructuralViewMode.perPoint,
      maximumViews: math.min(10, frames.length),
      patchN: 7,
      frames: frames,
      patchRadiusMByScale: const [0.015],
      // Decoder/backend interpolation moves the cap50 boundary by roughly
      // 0.06 U8 stddev. 6.05 rejects that cross-backend-only observation while
      // retaining the independently valid 6.06+ views required by cap41.
      // This changes no sampling work or execution time.
      minimumStdU8ByScale: const [6.05],
      birthOptionsByScale: const [
        PlaneSweepBirthOptions(
          minimumViews: 3,
          nccMin: 0.70,
          minimumParallaxDeg: 5,
          uniqueDepthMargin: 0.02,
        ),
      ],
    );
  }

  /// Frozen quality-first wall contract. A wall is tiled in its tangent and
  /// selected-floor axes; the sparse proposal never receives birth authority
  /// until [selectWallOwners] certifies its image evidence.
  static BcdStructuralSurfaceRequest wallSurfaceRequest({
    required StructuralEnvelopeWallProposal proposal,
    required StructuralFloorDomain selectedFloor,
    required List<BcdPlaneSweepView> frames,
  }) => _wallSurfaceRequest(
    normal: proposal.normal,
    basisU: proposal.basisU,
    planeValue: proposal.planeValue,
    boundsU: proposal.boundsU,
    boundsHeight: proposal.boundsHeight,
    selectedFloor: selectedFloor,
    frames: frames,
    patchRadiusMByScale: const [0.03],
    minimumStdU8ByScale: const [6],
    birthOptionsByScale: const [
      PlaneSweepBirthOptions(
        minimumViews: 4,
        nccMin: 0.80,
        minimumParallaxDeg: 10,
        uniqueDepthMargin: 0.02,
      ),
    ],
  );

  static BcdStructuralSurfaceRequest legacyWallSurfaceRequest({
    required StructuralWall proposal,
    required StructuralFloorDomain selectedFloor,
    required List<BcdPlaneSweepView> frames,
  }) => _wallSurfaceRequest(
    normal: proposal.normal,
    basisU: proposal.basisU,
    planeValue: proposal.planeValue,
    boundsU: proposal.boundsU,
    boundsHeight: proposal.boundsHeight,
    selectedFloor: selectedFloor,
    frames: frames,
    patchRadiusMByScale: const [0.03],
    minimumStdU8ByScale: const [6],
    birthOptionsByScale: const [
      PlaneSweepBirthOptions(
        minimumViews: 4,
        nccMin: 0.80,
        minimumParallaxDeg: 10,
        uniqueDepthMargin: 0.02,
      ),
    ],
  );

  /// Coarse image-only depth calibration for a sparse wall proposed relative
  /// to a capture-time known floor.  Each offset is evaluated as the sole
  /// center plane; no competing hypothesis can accidentally publish a point
  /// from a different depth.  The caller applies the frozen unique-peak and
  /// sparse-agreement gates before admitting the calibrated wall as a proposal.
  static BcdStructuralSurfaceRequest calibrationLegacyWallSurfaceRequest({
    required StructuralWall proposal,
    required StructuralFloorDomain sourceFloor,
    required List<BcdPlaneSweepView> frames,
    required double planeOffsetM,
  }) {
    _requirePlaneSweepFrames(frames);
    if (!sourceFloor.certified ||
        !planeOffsetM.isFinite ||
        !const [-0.10, -0.05, 0.0, 0.05, 0.10].contains(planeOffsetM)) {
      throw ArgumentError('invalid known-floor wall calibration request');
    }
    return BcdStructuralSurfaceRequest(
      grid: StructuralCandidateGridSpec(
        normal: proposal.normal,
        basisU: proposal.basisU,
        basisV: sourceFloor.normal,
        planeValue: proposal.planeValue + planeOffsetM,
        basisVOriginValue: sourceFloor.planeValue,
        boundsU: proposal.boundsU,
        boundsV: proposal.boundsHeight,
        gridM: 0.20,
      ),
      depthOffsetsM: const [0],
      tilePoints: 64,
      viewMode: StructuralViewMode.perTile,
      maximumViews: math.min(10, frames.length),
      patchN: 9,
      frames: frames,
      patchRadiusMByScale: const [0.03],
      minimumStdU8ByScale: const [6],
      birthOptionsByScale: const [
        PlaneSweepBirthOptions(
          minimumViews: 4,
          nccMin: 0.80,
          minimumParallaxDeg: 10,
          uniqueDepthMargin: 0,
        ),
      ],
    );
  }

  /// Re-evaluates only an unresolved wall family with the frozen 6 cm scale.
  /// Rescue thresholds can only become stricter than 5 views / 18 degrees /
  /// 0.90 NCC because they are raised to the baseline medians.
  static BcdStructuralSurfaceRequest strictWallSurfaceRequest({
    required StructuralEnvelopeWallProposal proposal,
    required StructuralFloorDomain selectedFloor,
    required List<BcdPlaneSweepView> frames,
    required BcdStructuralEvidenceSummary baseline,
  }) {
    final postViews = math.max(5, (baseline.medianSupportingViews ?? 0).ceil());
    final postParallax = math.max(18.0, baseline.medianParallaxDeg ?? 0);
    final postNcc = math.max(0.90, baseline.medianNcc ?? 0);
    return _wallSurfaceRequest(
      normal: proposal.normal,
      basisU: proposal.basisU,
      planeValue: proposal.planeValue,
      boundsU: proposal.boundsU,
      boundsHeight: proposal.boundsHeight,
      selectedFloor: selectedFloor,
      frames: frames,
      patchRadiusMByScale: const [0.03, 0.06],
      minimumStdU8ByScale: const [6, 6],
      birthOptionsByScale: [
        const PlaneSweepBirthOptions(
          minimumViews: 4,
          nccMin: 0.80,
          minimumParallaxDeg: 10,
          uniqueDepthMargin: 0.02,
        ),
        PlaneSweepBirthOptions(
          minimumViews: 5,
          nccMin: 0.80,
          minimumParallaxDeg: 18,
          uniqueDepthMargin: 0.06,
          postMinNcc: postNcc,
          postMinimumViews: postViews,
          postMinimumParallaxDeg: postParallax,
        ),
      ],
    );
  }

  static BcdStructuralSurfaceRequest strictLegacyWallSurfaceRequest({
    required StructuralWall proposal,
    required StructuralFloorDomain selectedFloor,
    required List<BcdPlaneSweepView> frames,
    required BcdStructuralEvidenceSummary baseline,
  }) => _strictWallSurfaceRequest(
    normal: proposal.normal,
    basisU: proposal.basisU,
    planeValue: proposal.planeValue,
    boundsU: proposal.boundsU,
    boundsHeight: proposal.boundsHeight,
    selectedFloor: selectedFloor,
    frames: frames,
    baseline: baseline,
  );

  static BcdStructuralSurfaceRequest _strictWallSurfaceRequest({
    required List<double> normal,
    required List<double> basisU,
    required double planeValue,
    required List<double> boundsU,
    required List<double> boundsHeight,
    required StructuralFloorDomain selectedFloor,
    required List<BcdPlaneSweepView> frames,
    required BcdStructuralEvidenceSummary baseline,
  }) {
    final postViews = math.max(5, (baseline.medianSupportingViews ?? 0).ceil());
    final postParallax = math.max(18.0, baseline.medianParallaxDeg ?? 0);
    final postNcc = math.max(0.90, baseline.medianNcc ?? 0);
    return _wallSurfaceRequest(
      normal: normal,
      basisU: basisU,
      planeValue: planeValue,
      boundsU: boundsU,
      boundsHeight: boundsHeight,
      selectedFloor: selectedFloor,
      frames: frames,
      patchRadiusMByScale: const [0.03, 0.06],
      minimumStdU8ByScale: const [6, 6],
      birthOptionsByScale: [
        const PlaneSweepBirthOptions(
          minimumViews: 4,
          nccMin: 0.80,
          minimumParallaxDeg: 10,
          uniqueDepthMargin: 0.02,
        ),
        PlaneSweepBirthOptions(
          minimumViews: 5,
          nccMin: 0.80,
          minimumParallaxDeg: 18,
          uniqueDepthMargin: 0.06,
          postMinNcc: postNcc,
          postMinimumViews: postViews,
          postMinimumParallaxDeg: postParallax,
        ),
      ],
    );
  }

  static BcdStructuralSurfaceRequest _wallSurfaceRequest({
    required List<double> normal,
    required List<double> basisU,
    required double planeValue,
    required List<double> boundsU,
    required List<double> boundsHeight,
    required StructuralFloorDomain selectedFloor,
    required List<BcdPlaneSweepView> frames,
    required List<double> patchRadiusMByScale,
    required List<double> minimumStdU8ByScale,
    required List<PlaneSweepBirthOptions> birthOptionsByScale,
  }) {
    _requirePlaneSweepFrames(frames);
    if (!selectedFloor.certified) {
      throw StateError('wall sweep requires an image-certified floor owner');
    }
    return BcdStructuralSurfaceRequest(
      grid: StructuralCandidateGridSpec(
        normal: normal,
        basisU: basisU,
        basisV: selectedFloor.normal,
        planeValue: planeValue,
        basisVOriginValue: selectedFloor.planeValue,
        boundsU: boundsU,
        boundsV: boundsHeight,
        gridM: 0.05,
      ),
      depthOffsetsM: const [0, -0.10, -0.05, 0.05, 0.10],
      tilePoints: 64,
      viewMode: StructuralViewMode.perTile,
      maximumViews: math.min(10, frames.length),
      patchN: 9,
      frames: frames,
      patchRadiusMByScale: patchRadiusMByScale,
      minimumStdU8ByScale: minimumStdU8ByScale,
      birthOptionsByScale: birthOptionsByScale,
    );
  }

  static void _requirePlaneSweepFrames(List<BcdPlaneSweepView> frames) {
    if (frames.length < 3) {
      throw ArgumentError('B plane-sweep requires at least three views');
    }
  }

  /// Moves grid generation, competing-depth construction, visibility, and
  /// view ranking through the shared C++ candidate ABI, then performs only
  /// deterministic grouping in Dart. Memory remains tile-bounded.
  static List<BcdPlaneSweepBatch> prepareStructuralBatches(
    BcdStructuralSurfaceRequest request,
  ) {
    _validateStructuralRequest(request);
    final fullGrid = StructuralCandidatePreparation.buildGrid(
      spec: request.grid,
      depthOffsetsM: request.depthOffsetsM,
    );
    final batches = <BcdPlaneSweepBatch>[];
    final hypotheses = fullGrid.hypothesesPerCandidate;
    final scaleCount = request.birthOptionsByScale.length;
    final candidateFrames = [
      for (final frame in request.frames)
        StructuralCandidateFrame(
          projection3x4: frame.projection3x4,
          cameraCenter: frame.cameraCenter,
          width: frame.width,
          height: frame.height,
        ),
    ];
    for (
      var tileStart = 0;
      tileStart < fullGrid.candidateCount;
      tileStart += request.tilePoints
    ) {
      final tileCount = (fullGrid.candidateCount - tileStart).clamp(
        0,
        request.tilePoints,
      );
      final tileGrid = StructuralPreparedGrid(
        centersXyz: Float64List.fromList(
          fullGrid.centersXyz.sublist(
            tileStart * 3,
            (tileStart + tileCount) * 3,
          ),
        ),
        pointsXyz: Float64List.fromList(
          fullGrid.pointsXyz.sublist(
            tileStart * hypotheses * 3,
            (tileStart + tileCount) * hypotheses * 3,
          ),
        ),
        candidateCount: tileCount,
        hypothesesPerCandidate: hypotheses,
      );
      final plan = StructuralCandidatePreparation.prepareViews(
        grid: tileGrid,
        frames: candidateFrames,
        normal: request.grid.normal,
        maximumViews: request.maximumViews,
        mode: request.viewMode,
        imageMarginPx: request.imageMarginPx,
        maximumGrazeDeg: request.maximumGrazeDeg,
      );
      final groups = <String, List<int>>{};
      for (var local = 0; local < tileCount; local++) {
        final views = plan.selectedViewIndices[local];
        if (views.isEmpty) continue;
        groups.putIfAbsent(views.join(','), () => <int>[]).add(local);
      }
      for (final locals in groups.values) {
        final selectedViews = plan.selectedViewIndices[locals.first];
        final pointCount = locals.length * hypotheses;
        final points = Float32List(pointCount * 3);
        final oneScaleMasks = Uint8List(pointCount * selectedViews.length);
        final sourceCandidates = <int>[];
        for (
          var groupCandidate = 0;
          groupCandidate < locals.length;
          groupCandidate++
        ) {
          final localCandidate = locals[groupCandidate];
          sourceCandidates.add(tileStart + localCandidate);
          for (var hypothesis = 0; hypothesis < hypotheses; hypothesis++) {
            final sourcePoint = localCandidate * hypotheses + hypothesis;
            final destinationPoint = groupCandidate * hypotheses + hypothesis;
            for (var axis = 0; axis < 3; axis++) {
              points[destinationPoint * 3 + axis] =
                  tileGrid.pointsXyz[sourcePoint * 3 + axis];
            }
            for (var view = 0; view < selectedViews.length; view++) {
              oneScaleMasks[destinationPoint * selectedViews.length + view] =
                  plan.hypothesisVisibility[sourcePoint * plan.frameCount +
                      selectedViews[view]];
            }
          }
        }
        final masks = Uint8List(scaleCount * oneScaleMasks.length);
        for (var scale = 0; scale < scaleCount; scale++) {
          masks.setRange(
            scale * oneScaleMasks.length,
            (scale + 1) * oneScaleMasks.length,
            oneScaleMasks,
          );
        }
        batches.add(
          BcdPlaneSweepBatch(
            pointsXyz: points,
            candidateCount: locals.length,
            hypothesesPerCandidate: hypotheses,
            patchN: request.patchN,
            basisU: request.grid.basisU,
            basisV: request.grid.basisV,
            views: [for (final index in selectedViews) request.frames[index]],
            patchRadiusMByScale: request.patchRadiusMByScale,
            minimumStdU8ByScale: request.minimumStdU8ByScale,
            candidateViewMasks: masks,
            birthOptionsByScale: request.birthOptionsByScale,
            sourceCandidateIndices: List.unmodifiable(sourceCandidates),
          ),
        );
      }
    }
    return List.unmodifiable(batches);
  }

  /// Runs one bounded B plane-sweep batch. Every JPEG is decoded once for all
  /// scales and the result is read back exactly once with RGB.
  static BcdStructuralBirthResult runStructuralBatch(BcdPlaneSweepBatch batch) {
    _validateStructuralBatch(batch);
    final session = StructuralPlaneSweepSession.create(
      pointsXyz: batch.pointsXyz,
      candidateCount: batch.candidateCount,
      hypothesesPerCandidate: batch.hypothesesPerCandidate,
      patchN: batch.patchN,
      maxViews: batch.views.length,
      scaleCount: batch.birthOptionsByScale.length,
      basisU: batch.basisU,
      basisV: batch.basisV,
    );
    try {
      for (var viewIndex = 0; viewIndex < batch.views.length; viewIndex++) {
        final view = batch.views[viewIndex];
        final dimensions = session.addJpegViewAllScales(
          viewIndex: viewIndex,
          jpegPath: view.jpegPath,
          projection3x4: Float32List.fromList(view.projection3x4),
          cameraCenter: Float32List.fromList(view.cameraCenter),
          patchRadiusMByScale: batch.patchRadiusMByScale,
          minimumStdU8ByScale: batch.minimumStdU8ByScale,
        );
        if (dimensions.width != view.width ||
            dimensions.height != view.height) {
          throw StateError(
            'JPEG dimensions changed after candidate preparation: '
            '${dimensions.width}x${dimensions.height} != '
            '${view.width}x${view.height}',
          );
        }
      }
      final finish = session.finishWithRgb(
        candidateViewMasks: batch.candidateViewMasks,
        scales: batch.birthOptionsByScale,
      );
      final local = assembleStructuralBirths(
        pointsXyz: batch.pointsXyz,
        hypothesesPerCandidate: batch.hypothesesPerCandidate,
        finish: finish,
      );
      return BcdStructuralBirthResult(
        cloud: local.cloud,
        evaluatedCandidateIndices: List.unmodifiable(
          batch.sourceCandidateIndices,
        ),
        acceptedCandidateIndices: List.unmodifiable([
          for (final index in local.acceptedCandidateIndices)
            batch.sourceCandidateIndices[index],
        ]),
        evidence: local.evidence,
      );
    } finally {
      session.dispose();
    }
  }

  /// Runs tile sessions in bounded waves while decoding and uploading each
  /// source image only once per wave.
  ///
  /// Candidate preparation, per-tile view lists, masks, shader dispatches,
  /// finish order, and publication order are unchanged. Only immutable image
  /// input is shared. The default 512-candidate wave keeps patch tensors
  /// bounded while amortizing the dominant 4K JPEG decode/upload cost.
  static List<BcdStructuralBirthResult> runStructuralBatchesSharedImages(
    List<BcdPlaneSweepBatch> batches, {
    int waveCandidateCapacity = 512,
  }) {
    if (batches.isEmpty) return const [];
    if (waveCandidateCapacity <= 0) {
      throw ArgumentError.value(
        waveCandidateCapacity,
        'waveCandidateCapacity',
        'must be positive',
      );
    }
    for (final batch in batches) {
      _validateStructuralBatch(batch);
    }
    final output = <BcdStructuralBirthResult>[];
    var waveStart = 0;
    while (waveStart < batches.length) {
      var waveEnd = waveStart;
      var waveCandidates = 0;
      while (waveEnd < batches.length) {
        final next = batches[waveEnd].candidateCount;
        if (waveEnd > waveStart &&
            waveCandidates + next > waveCandidateCapacity) {
          break;
        }
        waveCandidates += next;
        waveEnd++;
      }
      final wave = batches.sublist(waveStart, waveEnd);
      final sessions = <StructuralPlaneSweepSession>[
        for (final batch in wave)
          StructuralPlaneSweepSession.create(
            pointsXyz: batch.pointsXyz,
            candidateCount: batch.candidateCount,
            hypothesesPerCandidate: batch.hypothesesPerCandidate,
            patchN: batch.patchN,
            maxViews: batch.views.length,
            scaleCount: batch.birthOptionsByScale.length,
            basisU: batch.basisU,
            basisV: batch.basisV,
          ),
      ];
      try {
        final usesByPath = <String, List<({int batchIndex, int viewIndex})>>{};
        for (var batchIndex = 0; batchIndex < wave.length; batchIndex++) {
          final batch = wave[batchIndex];
          for (var viewIndex = 0; viewIndex < batch.views.length; viewIndex++) {
            usesByPath
                .putIfAbsent(
                  batch.views[viewIndex].jpegPath,
                  () => <({int batchIndex, int viewIndex})>[],
                )
                .add((batchIndex: batchIndex, viewIndex: viewIndex));
          }
        }
        for (final entry in usesByPath.entries) {
          final image = StructuralPlaneSweepImage.decodeJpeg(entry.key);
          try {
            for (final use in entry.value) {
              final batch = wave[use.batchIndex];
              final view = batch.views[use.viewIndex];
              if (image.width != view.width || image.height != view.height) {
                throw StateError(
                  'JPEG dimensions changed after candidate preparation: '
                  '${image.width}x${image.height} != '
                  '${view.width}x${view.height}',
                );
              }
              sessions[use.batchIndex].addImageViewAllScales(
                viewIndex: use.viewIndex,
                image: image,
                projection3x4: Float32List.fromList(view.projection3x4),
                cameraCenter: Float32List.fromList(view.cameraCenter),
                patchRadiusMByScale: batch.patchRadiusMByScale,
                minimumStdU8ByScale: batch.minimumStdU8ByScale,
              );
            }
          } finally {
            image.dispose();
          }
        }
        for (var index = 0; index < wave.length; index++) {
          final batch = wave[index];
          final finish = sessions[index].finishWithRgb(
            candidateViewMasks: batch.candidateViewMasks,
            scales: batch.birthOptionsByScale,
          );
          final local = assembleStructuralBirths(
            pointsXyz: batch.pointsXyz,
            hypothesesPerCandidate: batch.hypothesesPerCandidate,
            finish: finish,
          );
          output.add(
            BcdStructuralBirthResult(
              cloud: local.cloud,
              evaluatedCandidateIndices: List.unmodifiable(
                batch.sourceCandidateIndices,
              ),
              acceptedCandidateIndices: List.unmodifiable([
                for (final accepted in local.acceptedCandidateIndices)
                  batch.sourceCandidateIndices[accepted],
              ]),
              evidence: local.evidence,
            ),
          );
        }
      } finally {
        for (final session in sessions.reversed) {
          session.dispose();
        }
      }
      waveStart = waveEnd;
    }
    return List.unmodifiable(output);
  }

  /// Pure center-hypothesis publication step shared by tests and the native
  /// runner. A competitor hypothesis can prove ambiguity but is never copied
  /// into the product cloud.
  static BcdStructuralBirthResult assembleStructuralBirths({
    required Float32List pointsXyz,
    required int hypothesesPerCandidate,
    required PlaneSweepFinishResult finish,
  }) {
    if (hypothesesPerCandidate <= 0 ||
        pointsXyz.length % (hypothesesPerCandidate * 3) != 0 ||
        finish.candidates.length * hypothesesPerCandidate * 3 !=
            pointsXyz.length ||
        finish.rgb.length != finish.candidates.length * 3) {
      throw ArgumentError('structural finish dimensions do not match');
    }
    final accepted = <int>[];
    for (var index = 0; index < finish.candidates.length; index++) {
      if (finish.candidates[index].accepted) accepted.add(index);
    }
    final xyz = Float32List(accepted.length * 3);
    final rgb = Uint8List(accepted.length * 3);
    for (var outputIndex = 0; outputIndex < accepted.length; outputIndex++) {
      final candidate = accepted[outputIndex];
      final sourcePoint = candidate * hypothesesPerCandidate;
      for (var axis = 0; axis < 3; axis++) {
        xyz[outputIndex * 3 + axis] = pointsXyz[sourcePoint * 3 + axis];
        rgb[outputIndex * 3 + axis] = finish.rgb[candidate * 3 + axis];
      }
    }
    return BcdStructuralBirthResult(
      cloud: BcdPointCloud(xyz: xyz, rgb: rgb),
      evaluatedCandidateIndices: List.unmodifiable([
        for (var index = 0; index < finish.candidates.length; index++) index,
      ]),
      acceptedCandidateIndices: List.unmodifiable(accepted),
      evidence: List.unmodifiable(finish.candidates),
    );
  }

  /// Reduces tile-local C/WGSL evidence to the exact quality fields used by
  /// the frozen B floor/wall owner contracts. Rejected sites contribute no
  /// quality statistics. A missing parallel competitor has infinite margin
  /// in the C ABI and is intentionally excluded from observed-margin metrics,
  /// matching the research reference's `None` semantics.
  static BcdStructuralEvidenceSummary aggregateStructuralEvidence({
    required List<BcdStructuralBirthResult> batches,
    required List<double> basisU,
    required List<double> basisV,
    double coverageCellM = 0.05,
  }) {
    if (basisU.length != 3 ||
        basisV.length != 3 ||
        [...basisU, ...basisV].any((value) => !value.isFinite) ||
        !coverageCellM.isFinite ||
        coverageCellM <= 0) {
      throw ArgumentError('structural evidence basis or coverage cell is bad');
    }
    final evaluated = <int>{};
    final accepted = <int>{};
    final cells = <String>{};
    final ncc = <double>[];
    final views = <double>[];
    final parallax = <double>[];
    final depthMargins = <double>[];
    for (final batch in batches) {
      final evaluatedIndices = batch.evaluatedCandidateIndices;
      final acceptedEvidence = [
        for (var index = 0; index < batch.evidence.length; index++)
          if (batch.evidence[index].accepted) index,
      ];
      if (evaluatedIndices.length != batch.evidence.length ||
          batch.cloud.pointCount != batch.acceptedCandidateIndices.length ||
          acceptedEvidence.length != batch.cloud.pointCount ||
          batch.acceptedCandidateIndices.length != acceptedEvidence.length) {
        throw ArgumentError('structural evidence tile dimensions do not match');
      }
      for (var local = 0; local < evaluatedIndices.length; local++) {
        final global = evaluatedIndices[local];
        final evidence = batch.evidence[local];
        if (global < 0 || !evaluated.add(global)) {
          throw ArgumentError('structural evidence candidates overlap');
        }
        if (!evidence.accepted) continue;
        if (evidence.supportingViews <= 0 ||
            !evidence.medianNcc.isFinite ||
            !evidence.maxParallaxDeg.isFinite ||
            evidence.observedDepthMargin.isNaN) {
          throw ArgumentError('accepted structural evidence is malformed');
        }
        final acceptedPosition = acceptedEvidence.indexOf(local);
        if (acceptedPosition < 0 ||
            batch.acceptedCandidateIndices[acceptedPosition] != global ||
            !accepted.add(global)) {
          throw ArgumentError('structural accepted candidate mapping is bad');
        }
        final pointOffset = acceptedPosition * 3;
        final x = batch.cloud.xyz[pointOffset];
        final y = batch.cloud.xyz[pointOffset + 1];
        final z = batch.cloud.xyz[pointOffset + 2];
        if (![x, y, z].every((value) => value.isFinite)) {
          throw ArgumentError('structural accepted point is non-finite');
        }
        final u = (x * basisU[0] + y * basisU[1] + z * basisU[2]);
        final v = (x * basisV[0] + y * basisV[1] + z * basisV[2]);
        cells.add(
          '${(u / coverageCellM).floor()},${(v / coverageCellM).floor()}',
        );
        ncc.add(evidence.medianNcc);
        views.add(evidence.supportingViews.toDouble());
        parallax.add(evidence.maxParallaxDeg);
        if (evidence.observedDepthMargin.isFinite) {
          depthMargins.add(evidence.observedDepthMargin);
        }
      }
    }
    return BcdStructuralEvidenceSummary(
      evaluated: evaluated.length,
      accepted: accepted.length,
      coverageCells5cm: cells.length,
      medianNcc: _quantile(ncc, 0.5),
      nccP10: _quantile(ncc, 0.1),
      medianSupportingViews: _quantile(views, 0.5),
      medianParallaxDeg: _quantile(parallax, 0.5),
      depthMarginMin: depthMargins.isEmpty
          ? null
          : depthMargins.reduce(math.min),
      depthMarginMedian: _quantile(depthMargins, 0.5),
    );
  }

  static double? _quantile(List<double> source, double probability) {
    if (source.isEmpty) return null;
    final values = [...source]..sort();
    final position = (values.length - 1) * probability;
    final lower = position.floor();
    final upper = position.ceil();
    if (lower == upper) return values[lower];
    final fraction = position - lower;
    return values[lower] * (1 - fraction) + values[upper] * fraction;
  }

  /// Merges a baseline wall sweep with its two-scale replay without allowing
  /// the replay to reorder or recolor any baseline point. The C ABI's combined
  /// output is candidate-sorted, so this explicit merge restores the research
  /// contract: exact baseline prefix followed only by newly certified sites.
  /// The returned [eligible] bit is false when any frozen quality metric drops.
  static BcdStrictWallRescueResult mergeStrictWallRescue({
    required List<BcdStructuralBirthResult> baselineBatches,
    required List<BcdStructuralBirthResult> combinedBatches,
    required List<double> basisU,
    required List<double> basisV,
  }) {
    final baselineSummary = aggregateStructuralEvidence(
      batches: baselineBatches,
      basisU: basisU,
      basisV: basisV,
    );
    final combinedSummary = aggregateStructuralEvidence(
      batches: combinedBatches,
      basisU: basisU,
      basisV: basisV,
    );
    final baselineSites = _acceptedStructuralSites(baselineBatches);
    final combinedSites = _acceptedStructuralSites(combinedBatches);
    final baselineEvaluated = {
      for (final batch in baselineBatches) ...batch.evaluatedCandidateIndices,
    };
    final combinedEvaluated = {
      for (final batch in combinedBatches) ...batch.evaluatedCandidateIndices,
    };
    if (baselineEvaluated.length != baselineSummary.evaluated ||
        combinedEvaluated.length != combinedSummary.evaluated ||
        baselineEvaluated.length != combinedEvaluated.length ||
        !baselineEvaluated.containsAll(combinedEvaluated)) {
      throw StateError('strict wall replay changed the evaluated grid');
    }
    for (final site in baselineSites) {
      final replay = combinedSites.firstWhere(
        (candidate) => candidate.index == site.index,
        orElse: () => throw StateError('strict replay lost a baseline birth'),
      );
      if (!_sameStructuralSite(site, replay)) {
        throw StateError('strict replay changed a baseline birth');
      }
    }
    final baselineIds = {for (final site in baselineSites) site.index};
    final rescue = [
      for (final site in combinedSites)
        if (!baselineIds.contains(site.index)) site,
    ];
    final publicationSites = [...baselineSites, ...rescue];
    final publication = _structuralResultFromSites(publicationSites);
    final publicationSummary = aggregateStructuralEvidence(
      batches: [publication],
      basisU: basisU,
      basisV: basisV,
    );
    final mergedSummary = BcdStructuralEvidenceSummary(
      evaluated: baselineSummary.evaluated,
      accepted: publicationSummary.accepted,
      coverageCells5cm: publicationSummary.coverageCells5cm,
      medianNcc: publicationSummary.medianNcc,
      nccP10: publicationSummary.nccP10,
      medianSupportingViews: publicationSummary.medianSupportingViews,
      medianParallaxDeg: publicationSummary.medianParallaxDeg,
      depthMarginMin: publicationSummary.depthMarginMin,
      depthMarginMedian: publicationSummary.depthMarginMedian,
    );
    bool notLower(double? baseline, double? merged) =>
        baseline == null || merged != null && merged >= baseline - 1e-12;
    final checks = <String, bool>{
      'baseline_point_prefix_exact': _cloudPrefixExact(
        publication.cloud,
        _structuralResultFromSites(baselineSites).cloud,
      ),
      'accepted_not_lower': mergedSummary.accepted >= baselineSummary.accepted,
      'coverage_cells_5cm_not_lower':
          mergedSummary.coverageCells5cm >= baselineSummary.coverageCells5cm,
      'median_views_not_lower': notLower(
        baselineSummary.medianSupportingViews,
        mergedSummary.medianSupportingViews,
      ),
      'median_parallax_not_lower': notLower(
        baselineSummary.medianParallaxDeg,
        mergedSummary.medianParallaxDeg,
      ),
      'median_ncc_not_lower': notLower(
        baselineSummary.medianNcc,
        mergedSummary.medianNcc,
      ),
      'ncc_p10_not_lower': notLower(
        baselineSummary.nccP10,
        mergedSummary.nccP10,
      ),
      'depth_margin_min_not_lower': notLower(
        baselineSummary.depthMarginMin,
        mergedSummary.depthMarginMin,
      ),
      'depth_margin_median_not_lower': notLower(
        baselineSummary.depthMarginMedian,
        mergedSummary.depthMarginMedian,
      ),
    };
    final eligible = checks.values.every((passed) => passed);
    final strictMetrics = BcdWallStrictMetrics(
      eligible: eligible,
      accepted: mergedSummary.accepted,
      coverageCells5cm: mergedSummary.coverageCells5cm,
      medianNcc: mergedSummary.medianNcc ?? 0,
      nccP10: mergedSummary.nccP10 ?? 0,
    );
    return BcdStrictWallRescueResult(
      eligible: eligible,
      addedBirths: rescue.length,
      publication: publication,
      baselineSummary: baselineSummary,
      mergedSummary: mergedSummary,
      strictMetrics: strictMetrics,
      nonRegressionChecks: Map.unmodifiable(checks),
    );
  }

  static List<_AcceptedStructuralSite> _acceptedStructuralSites(
    List<BcdStructuralBirthResult> batches,
  ) {
    final sites = <_AcceptedStructuralSite>[];
    final seen = <int>{};
    for (final batch in batches) {
      var acceptedPosition = 0;
      for (var local = 0; local < batch.evidence.length; local++) {
        final evidence = batch.evidence[local];
        if (!evidence.accepted) continue;
        final index = batch.evaluatedCandidateIndices[local];
        if (!seen.add(index) ||
            acceptedPosition >= batch.acceptedCandidateIndices.length ||
            batch.acceptedCandidateIndices[acceptedPosition] != index) {
          throw ArgumentError('structural accepted sites are malformed');
        }
        final offset = acceptedPosition * 3;
        sites.add(
          _AcceptedStructuralSite(
            index: index,
            xyz: [
              batch.cloud.xyz[offset],
              batch.cloud.xyz[offset + 1],
              batch.cloud.xyz[offset + 2],
            ],
            rgb: [
              batch.cloud.rgb[offset],
              batch.cloud.rgb[offset + 1],
              batch.cloud.rgb[offset + 2],
            ],
            evidence: evidence,
          ),
        );
        acceptedPosition++;
      }
    }
    return sites;
  }

  static bool _sameStructuralSite(
    _AcceptedStructuralSite left,
    _AcceptedStructuralSite right,
  ) =>
      left.index == right.index &&
      _listEquals(left.xyz, right.xyz) &&
      _listEquals(left.rgb, right.rgb) &&
      left.evidence.supportingViews == right.evidence.supportingViews &&
      left.evidence.medianNcc == right.evidence.medianNcc &&
      left.evidence.maxParallaxDeg == right.evidence.maxParallaxDeg &&
      left.evidence.observedDepthMargin == right.evidence.observedDepthMargin;

  static bool _listEquals<T>(List<T> left, List<T> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  static BcdStructuralBirthResult _structuralResultFromSites(
    List<_AcceptedStructuralSite> sites,
  ) {
    final xyz = Float32List(sites.length * 3);
    final rgb = Uint8List(sites.length * 3);
    for (var index = 0; index < sites.length; index++) {
      xyz.setRange(index * 3, index * 3 + 3, sites[index].xyz);
      rgb.setRange(index * 3, index * 3 + 3, sites[index].rgb);
    }
    return BcdStructuralBirthResult(
      cloud: BcdPointCloud(xyz: xyz, rgb: rgb),
      evaluatedCandidateIndices: List.unmodifiable([
        for (final site in sites) site.index,
      ]),
      acceptedCandidateIndices: List.unmodifiable([
        for (final site in sites) site.index,
      ]),
      evidence: List.unmodifiable([for (final site in sites) site.evidence]),
    );
  }

  static bool _cloudPrefixExact(BcdPointCloud merged, BcdPointCloud baseline) {
    if (merged.xyz.length < baseline.xyz.length ||
        merged.rgb.length < baseline.rgb.length) {
      return false;
    }
    for (var index = 0; index < baseline.xyz.length; index++) {
      if (merged.xyz[index] != baseline.xyz[index] ||
          merged.rgb[index] != baseline.rgb[index]) {
        return false;
      }
    }
    return true;
  }

  /// Generates D candidates from the shared tiled depth ABI and immediately
  /// applies the fixed production sequence. The reciprocal mask is produced
  /// inside this method; callers cannot accidentally publish an unchecked
  /// depth sample. Native depth sessions are capture-scoped and disposed by
  /// [runner] before the structural/local-manifold gate begins.
  static BcdDetectorFreeBirthResult runAndGateDetectorFreeCandidates({
    required BcdDetectorFreeFinalizeRequest request,
    BcdDetectorFreeDepthRunner runner = const BcdFfiDetectorFreeDepthRunner(),
  }) {
    final primaryOptions = request.primary.options;
    final width = primaryOptions.imageWidth;
    final height = primaryOptions.imageHeight;
    final pixels = width * height;
    _validateDetectorFreeDepthJob(request.primary);
    if (request.reciprocals.isEmpty) {
      throw ArgumentError('detector-free reciprocal jobs are empty');
    }
    for (final reciprocal in request.reciprocals) {
      _validateDetectorFreeDepthJob(reciprocal);
      if (reciprocal.options.imageWidth != width ||
          reciprocal.options.imageHeight != height) {
        throw ArgumentError('detector-free depth grids do not match');
      }
    }
    final reciprocalCount = request.reciprocals.length;
    request.reciprocalOptions.validate(reciprocalCount);
    if (request.sparseXyz.length % 3 != 0 ||
        request.sparseXyz.any((value) => !value.isFinite) ||
        request.referenceRgb.length != pixels * 3 ||
        request.worldToReferenceProjection3x4.length != 12 ||
        request.referenceToReciprocalProjections.length !=
            reciprocalCount * 12 ||
        request.reciprocalCameraCentersInReference.length !=
            reciprocalCount * 3 ||
        request.worldToReferenceProjection3x4.any((value) => !value.isFinite) ||
        request.referenceToReciprocalProjections.any(
          (value) => !value.isFinite,
        ) ||
        request.reciprocalCameraCentersInReference.any(
          (value) => !value.isFinite,
        )) {
      throw ArgumentError('detector-free finalize input is malformed');
    }

    final primary = runner.runDepth(request.primary);
    _validateDetectorFreeDepthMap(
      primary,
      width,
      height,
      requireCoarseIdentity: request.primary.refineOptions != null,
    );
    final reciprocalDepths = Float32List(reciprocalCount * pixels);
    final reciprocalAccepted = Uint8List(reciprocalCount * pixels);
    final reciprocalIdentityDepths = Float32List(reciprocalCount * pixels);
    final reciprocalIdentityAccepted = Uint8List(reciprocalCount * pixels);
    for (var index = 0; index < reciprocalCount; index++) {
      final depth = runner.runDepth(request.reciprocals[index]);
      _validateDetectorFreeDepthMap(
        depth,
        width,
        height,
        requireCoarseIdentity: request.reciprocals[index].refineOptions != null,
      );
      reciprocalDepths.setRange(
        index * pixels,
        (index + 1) * pixels,
        depth.depthM,
      );
      reciprocalAccepted.setRange(
        index * pixels,
        (index + 1) * pixels,
        depth.accepted,
      );
      reciprocalIdentityDepths.setRange(
        index * pixels,
        (index + 1) * pixels,
        depth.identityDepthM,
      );
      reciprocalIdentityAccepted.setRange(
        index * pixels,
        (index + 1) * pixels,
        depth.identityAccepted,
      );
    }
    final reciprocalIdentity = runner.filterReciprocal(
      BcdDetectorFreeReciprocalInput(
        imageWidth: width,
        imageHeight: height,
        referenceInverseK: Float32List.fromList(
          primaryOptions.referenceInverseK,
        ),
        referenceDepthM: primary.identityDepthM,
        referenceAccepted: primary.identityAccepted,
        reciprocalDepthsM: reciprocalIdentityDepths,
        reciprocalAccepted: reciprocalIdentityAccepted,
        referenceToReciprocalProjections:
            request.referenceToReciprocalProjections,
        reciprocalCameraCentersInReference:
            request.reciprocalCameraCentersInReference,
        options: request.reciprocalOptions,
      ),
    );
    final reciprocalMetric = runner.filterReciprocal(
      BcdDetectorFreeReciprocalInput(
        imageWidth: width,
        imageHeight: height,
        referenceInverseK: Float32List.fromList(
          primaryOptions.referenceInverseK,
        ),
        referenceDepthM: primary.depthM,
        referenceAccepted: primary.accepted,
        reciprocalDepthsM: reciprocalDepths,
        reciprocalAccepted: reciprocalAccepted,
        referenceToReciprocalProjections:
            request.referenceToReciprocalProjections,
        reciprocalCameraCentersInReference:
            request.reciprocalCameraCentersInReference,
        options: request.reciprocalOptions,
      ),
    );
    if (reciprocalIdentity.born.length != pixels ||
        reciprocalIdentity.consistentViews.length != pixels ||
        reciprocalMetric.born.length != pixels ||
        reciprocalMetric.consistentViews.length != pixels ||
        reciprocalIdentity.born.any((value) => value > 1) ||
        reciprocalMetric.born.any((value) => value > 1)) {
      throw StateError('detector-free reciprocal output is malformed');
    }
    final publicationDepth = Float32List.fromList(primary.identityDepthM);
    for (var index = 0; index < pixels; index++) {
      if (reciprocalIdentity.born[index] != 0 &&
          reciprocalMetric.born[index] != 0) {
        publicationDepth[index] = primary.depthM[index];
      }
    }
    final candidateXyz = _unprojectDetectorFreeCandidates(
      width: width,
      height: height,
      inverseK: primaryOptions.referenceInverseK,
      worldToReferenceProjection3x4: request.worldToReferenceProjection3x4,
      depthM: publicationDepth,
      born: reciprocalIdentity.born,
    );
    return gateDetectorFreeCandidates(
      sparseXyz: request.sparseXyz,
      candidateXyz: candidateXyz,
      candidateRgb: request.referenceRgb,
      reciprocalBorn: reciprocalIdentity.born,
      floorValue: request.floorValue,
      selectedFloor: request.selectedFloor,
      certifiedWalls: request.certifiedWalls,
      options: request.localManifoldOptions,
    );
  }

  /// Applies the fixed production sequence to already generated D candidates:
  /// reciprocal evidence -> finite B floor/wall ownership -> two independent
  /// sparse local-manifold partitions. Only the final [born] mask is copied.
  /// Product orchestration should prefer [runAndGateDetectorFreeCandidates] so
  /// the reciprocal evidence cannot be supplied independently of its depths.
  static BcdDetectorFreeBirthResult gateDetectorFreeCandidates({
    required Float32List sparseXyz,
    required Float32List candidateXyz,
    required Uint8List candidateRgb,
    required Uint8List reciprocalBorn,
    required double floorValue,
    required StructuralFloorDomain selectedFloor,
    required List<StructuralWall> certifiedWalls,
    LocalManifoldBirthOptions options = const LocalManifoldBirthOptions(),
  }) {
    final count = candidateXyz.length ~/ 3;
    if (candidateXyz.length % 3 != 0 ||
        candidateRgb.length != count * 3 ||
        reciprocalBorn.length != count ||
        reciprocalBorn.any((value) => value > 1)) {
      throw ArgumentError('detector-free candidate dimensions do not match');
    }
    if (count == 0) {
      final certificate = ReferenceBirthCertificateResult(
        failedFoldMask: 0,
        preCertificateBirthCount: 0,
        blockedBirthCount: 0,
        finalBirthCount: 0,
        born: Uint8List(0),
      );
      final emptyOwnership = ReferenceCertifiedBirthOwnershipResult(
        inputEligible: Uint8List(0),
        floorOwned: Uint8List(0),
        wallOwned: Uint8List(0),
        structuralOwned: Uint8List(0),
        certificate: certificate,
      );
      return BcdDetectorFreeBirthResult(
        cloud: BcdPointCloud.empty(),
        bornCandidateIndices: const [],
        floorRerouteCandidateIndices: const [],
        ownership: emptyOwnership,
      );
    }
    final session = LocalManifoldBirthSession.create(
      sparseXyz: sparseXyz,
      options: options,
    );
    try {
      final certified = session.filterReferenceCertifiedWithStructuralOwnership(
        candidateXyz: candidateXyz,
        candidateEligible: reciprocalBorn,
        floorValue: floorValue,
        selectedFloor: selectedFloor,
        certifiedWalls: certifiedWalls,
        // Product fold is deliberately fixed. No public request/config field
        // may select a more favorable blind fold and bypass the certificate.
        productionFold: 2,
      );
      final certificate = certified.certificate;
      final born = <int>[];
      final floorReroute = <int>[];
      for (var index = 0; index < count; index++) {
        if (certificate.born[index] != 0) born.add(index);
        if (reciprocalBorn[index] != 0 && certified.floorOwned[index] != 0) {
          floorReroute.add(index);
        }
      }
      return BcdDetectorFreeBirthResult(
        cloud: _gather(candidateXyz, candidateRgb, born),
        bornCandidateIndices: List.unmodifiable(born),
        floorRerouteCandidateIndices: List.unmodifiable(floorReroute),
        ownership: certified,
      );
    } finally {
      session.dispose();
    }
  }

  static void _validateDetectorFreeDepthJob(BcdDetectorFreeDepthJob job) {
    final options = job.options;
    options.validate();
    job.refineOptions?.validate();
    final pixels = options.imageWidth * options.imageHeight;
    // Mirror the native/WebGPU kernel contract before opening a session. The
    // public FFI option object intentionally accepts a wider diagnostic range;
    // product orchestration must fail before native allocation for values the
    // shared tiled kernel cannot execute.
    if (options.imageWidth > 8192 ||
        options.imageHeight > 8192 ||
        options.depthCount > 64 ||
        options.patchN > 5 ||
        options.nccMin < 0 ||
        options.exclusionRadiusSamples >= options.depthCount ||
        job.grayFrames.length != pixels * (options.sourceCount + 1) ||
        job.sourceProjections.length != options.sourceCount * 12 ||
        job.grayFrames.any((value) => !value.isFinite) ||
        job.sourceProjections.any((value) => !value.isFinite)) {
      throw ArgumentError('detector-free depth job dimensions do not match');
    }
  }

  static void _validateDetectorFreeDepthMap(
    BcdDetectorFreeDepthMap map,
    int width,
    int height, {
    bool requireCoarseIdentity = false,
  }) {
    final pixels = width * height;
    final hasCoarseDepth = map.coarseDepthM != null;
    final hasCoarseMask = map.coarseAccepted != null;
    if (map.width != width ||
        map.height != height ||
        map.depthM.length != pixels ||
        map.accepted.length != pixels ||
        hasCoarseDepth != hasCoarseMask ||
        (requireCoarseIdentity && !map.hasCoarseIdentity) ||
        (map.coarseDepthM != null && map.coarseDepthM!.length != pixels) ||
        (map.coarseAccepted != null && map.coarseAccepted!.length != pixels) ||
        map.depthM.any((value) => !value.isFinite || value < 0) ||
        map.accepted.any((value) => value > 1) ||
        map.identityDepthM.any((value) => !value.isFinite || value < 0) ||
        map.identityAccepted.any((value) => value > 1)) {
      throw StateError('detector-free depth output is malformed');
    }
    for (var index = 0; index < pixels; index++) {
      if ((map.accepted[index] != 0 &&
              !(map.depthM[index] > _detectorFreeMinimumMetricDepthM)) ||
          (map.identityAccepted[index] != 0 &&
              !(map.identityDepthM[index] >
                  _detectorFreeMinimumMetricDepthM))) {
        throw StateError('detector-free accepted depth is not metric-valid');
      }
    }
  }

  static Float32List _unprojectDetectorFreeCandidates({
    required int width,
    required int height,
    required List<double> inverseK,
    required Float32List worldToReferenceProjection3x4,
    required Float32List depthM,
    required Uint8List born,
  }) {
    if (inverseK.length != 9) {
      throw ArgumentError('detector-free inverse K is malformed');
    }
    // E = K^-1 P = [R|t]. The positive-depth camera convention is already
    // baked into P by the caller, so one transpose maps camera coordinates
    // back into the shared gravity-world frame.
    final e = List<double>.filled(12, 0);
    for (var row = 0; row < 3; row++) {
      for (var column = 0; column < 4; column++) {
        e[row * 4 + column] =
            inverseK[row * 3] * worldToReferenceProjection3x4[column] +
            inverseK[row * 3 + 1] * worldToReferenceProjection3x4[4 + column] +
            inverseK[row * 3 + 2] * worldToReferenceProjection3x4[8 + column];
      }
    }
    double dotRow(int left, int right) =>
        e[left * 4] * e[right * 4] +
        e[left * 4 + 1] * e[right * 4 + 1] +
        e[left * 4 + 2] * e[right * 4 + 2];
    final determinant =
        e[0] * (e[5] * e[10] - e[6] * e[9]) -
        e[1] * (e[4] * e[10] - e[6] * e[8]) +
        e[2] * (e[4] * e[9] - e[5] * e[8]);
    const rotationTolerance = 2e-3;
    if (e.any((value) => !value.isFinite) ||
        (determinant - 1).abs() > rotationTolerance ||
        (dotRow(0, 0) - 1).abs() > rotationTolerance ||
        (dotRow(1, 1) - 1).abs() > rotationTolerance ||
        (dotRow(2, 2) - 1).abs() > rotationTolerance ||
        dotRow(0, 1).abs() > rotationTolerance ||
        dotRow(0, 2).abs() > rotationTolerance ||
        dotRow(1, 2).abs() > rotationTolerance) {
      throw ArgumentError('detector-free reference extrinsics are invalid');
    }

    final xyz = Float32List(width * height * 3);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final index = y * width + x;
        if (born[index] == 0) continue;
        final depth = depthM[index];
        if (!depth.isFinite || !(depth > 0)) {
          throw StateError('reciprocal birth has no positive depth');
        }
        final cameraX =
            (inverseK[0] * x + inverseK[1] * y + inverseK[2]) * depth;
        final cameraY =
            (inverseK[3] * x + inverseK[4] * y + inverseK[5]) * depth;
        final cameraZ =
            (inverseK[6] * x + inverseK[7] * y + inverseK[8]) * depth;
        final centeredX = cameraX - e[3];
        final centeredY = cameraY - e[7];
        final centeredZ = cameraZ - e[11];
        xyz[index * 3] = e[0] * centeredX + e[4] * centeredY + e[8] * centeredZ;
        xyz[index * 3 + 1] =
            e[1] * centeredX + e[5] * centeredY + e[9] * centeredZ;
        xyz[index * 3 + 2] =
            e[2] * centeredX + e[6] * centeredY + e[10] * centeredZ;
      }
    }
    return xyz;
  }

  /// Publishes an append-only cloud in deterministic order: original sparse,
  /// structural B batches, then non-structural D births.
  static BcdFinalizeResult appendPreservingSparse({
    required Float32List originalXyz,
    required Uint8List originalRgb,
    required List<BcdStructuralBirthResult> structural,
    required BcdDetectorFreeBirthResult detectorFree,
  }) {
    _validateCloud(originalXyz, originalRgb, 'original sparse');
    var structuralPoints = 0;
    for (final batch in structural) {
      _validateCloud(batch.cloud.xyz, batch.cloud.rgb, 'structural birth');
      structuralPoints += batch.cloud.pointCount;
    }
    _validateCloud(
      detectorFree.cloud.xyz,
      detectorFree.cloud.rgb,
      'detector-free birth',
    );
    _validateDetectorFreePublication(detectorFree);
    final originalPoints = originalXyz.length ~/ 3;
    final totalPoints =
        originalPoints + structuralPoints + detectorFree.cloud.pointCount;
    final xyz = Float32List(totalPoints * 3);
    final rgb = Uint8List(totalPoints * 3);
    var xyzOffset = 0;
    var rgbOffset = 0;
    void append(BcdPointCloud cloud) {
      xyz.setAll(xyzOffset, cloud.xyz);
      rgb.setAll(rgbOffset, cloud.rgb);
      xyzOffset += cloud.xyz.length;
      rgbOffset += cloud.rgb.length;
    }

    append(BcdPointCloud(xyz: originalXyz, rgb: originalRgb));
    for (final batch in structural) {
      append(batch.cloud);
    }
    append(detectorFree.cloud);
    return BcdFinalizeResult(
      cloud: BcdPointCloud(xyz: xyz, rgb: rgb),
      originalPointCount: originalPoints,
      structuralBirthCount: structuralPoints,
      detectorFreeBirthCount: detectorFree.cloud.pointCount,
    );
  }

  static BcdPointCloud _gather(
    Float32List xyzSource,
    Uint8List rgbSource,
    List<int> indices,
  ) {
    final xyz = Float32List(indices.length * 3);
    final rgb = Uint8List(indices.length * 3);
    for (var output = 0; output < indices.length; output++) {
      final source = indices[output];
      for (var axis = 0; axis < 3; axis++) {
        xyz[output * 3 + axis] = xyzSource[source * 3 + axis];
        rgb[output * 3 + axis] = rgbSource[source * 3 + axis];
      }
    }
    return BcdPointCloud(xyz: xyz, rgb: rgb);
  }

  static void _validateDetectorFreePublication(
    BcdDetectorFreeBirthResult result,
  ) {
    final certificate = result.certificate;
    final count = certificate.born.length;
    final bornCount = certificate.born.where((value) => value != 0).length;
    final masks = [
      result.ownership.inputEligible,
      result.ownership.floorOwned,
      result.ownership.wallOwned,
      result.ownership.structuralOwned,
      result.ownership.born,
    ];
    final indices = result.bornCandidateIndices;
    if (certificate.failedFoldMask & ~0x7 != 0 ||
        certificate.preCertificateBirthCount < 0 ||
        certificate.blockedBirthCount < 0 ||
        certificate.finalBirthCount < 0 ||
        certificate.blockedBirthCount > certificate.preCertificateBirthCount ||
        certificate.finalBirthCount > certificate.preCertificateBirthCount ||
        bornCount != certificate.finalBirthCount ||
        result.cloud.pointCount != certificate.finalBirthCount ||
        indices.length != certificate.finalBirthCount ||
        indices.toSet().length != indices.length ||
        indices.any(
          (index) =>
              index < 0 || index >= count || certificate.born[index] == 0,
        ) ||
        masks.any(
          (mask) => mask.length != count || mask.any((value) => value > 1),
        ) ||
        (certificate.certified
            ? certificate.blockedBirthCount != 0 ||
                  certificate.finalBirthCount !=
                      certificate.preCertificateBirthCount
            : certificate.blockedBirthCount !=
                      certificate.preCertificateBirthCount ||
                  certificate.finalBirthCount != 0)) {
      throw StateError('detector-free publication certificate is invalid');
    }
    for (var index = 0; index < count; index++) {
      final structurallyOwned =
          result.ownership.floorOwned[index] != 0 ||
          result.ownership.wallOwned[index] != 0;
      if (result.ownership.structuralOwned[index] !=
              (structurallyOwned ? 1 : 0) ||
          (certificate.born[index] != 0 &&
              (result.ownership.inputEligible[index] == 0 ||
                  structurallyOwned))) {
        throw StateError('detector-free ownership certificate is invalid');
      }
    }
  }

  static void _validateStructuralBatch(BcdPlaneSweepBatch batch) {
    final scaleCount = batch.birthOptionsByScale.length;
    final pointCount = batch.candidateCount * batch.hypothesesPerCandidate;
    if (batch.candidateCount <= 0 ||
        batch.hypothesesPerCandidate <= 0 ||
        batch.sourceCandidateIndices.length != batch.candidateCount ||
        batch.pointsXyz.length != pointCount * 3 ||
        batch.patchN <= 0 ||
        batch.views.isEmpty ||
        scaleCount <= 0 ||
        batch.patchRadiusMByScale.length != scaleCount ||
        batch.minimumStdU8ByScale.length != scaleCount ||
        batch.candidateViewMasks.length !=
            scaleCount * pointCount * batch.views.length ||
        batch.candidateViewMasks.any((value) => value > 1) ||
        batch.basisU.length != 3 ||
        batch.basisV.length != 3 ||
        batch.views.any(
          (view) =>
              view.jpegPath.isEmpty ||
              view.projection3x4.length != 12 ||
              view.cameraCenter.length != 3 ||
              view.width <= 0 ||
              view.height <= 0,
        )) {
      throw ArgumentError('invalid B/C plane-sweep batch');
    }
  }

  static void _validateStructuralRequest(BcdStructuralSurfaceRequest request) {
    final scaleCount = request.birthOptionsByScale.length;
    if (request.depthOffsetsM.isEmpty ||
        request.depthOffsetsM.first.abs() > 1e-12 ||
        request.tilePoints <= 0 ||
        request.maximumViews <= 0 ||
        request.maximumViews > request.frames.length ||
        request.patchN <= 0 ||
        request.frames.isEmpty ||
        scaleCount <= 0 ||
        request.patchRadiusMByScale.length != scaleCount ||
        request.minimumStdU8ByScale.length != scaleCount ||
        !request.imageMarginPx.isFinite ||
        !request.maximumGrazeDeg.isFinite) {
      throw ArgumentError('invalid B/C structural surface request');
    }
  }

  static void _validateCloud(Float32List xyz, Uint8List rgb, String label) {
    if (xyz.length % 3 != 0 || rgb.length != xyz.length) {
      throw ArgumentError('$label XYZ/RGB dimensions do not match');
    }
  }
}
