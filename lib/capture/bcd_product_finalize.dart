// Product boundary for append-only B/C/D post-capture reconstruction.
//
// This API is deliberately synchronous. The caller may create and invoke the
// whole object inside a background isolate, but native runners and closures are
// never transferred across isolates. Dart owns ordering and failure isolation;
// all numerical work stays in the existing shared C++/WGSL runners.

import 'dart:typed_data';

import '../structural_planesweep_ffi.dart';
import 'bcd_detector_free_job_builder.dart';
import 'bcd_detector_free_scheduler.dart';
import 'bcd_finalize_coordinator.dart';
import 'bcd_finalize_input_builder.dart';
import 'bcd_native_asset_reader.dart';
import 'bcd_structural_quality_runner.dart';
import 'sfm_live_recon.dart';

abstract interface class BcdProductStructuralRunner {
  BcdStructuralQualityResult run({
    required Float32List sparseXyz,
    required List<BcdPlaneSweepView> registeredViews,
    BcdKnownFloorPlane? knownFloorPlane,
  });
}

class NativeBcdProductStructuralRunner implements BcdProductStructuralRunner {
  const NativeBcdProductStructuralRunner({
    this.runner = const BcdStructuralQualityRunner(),
  });

  final BcdStructuralQualityRunner runner;

  @override
  BcdStructuralQualityResult run({
    required Float32List sparseXyz,
    required List<BcdPlaneSweepView> registeredViews,
    BcdKnownFloorPlane? knownFloorPlane,
  }) => runner.run(
    sparseXyz: sparseXyz,
    registeredViews: registeredViews,
    knownFloorPlane: knownFloorPlane,
  );
}

/// Opaque full-scene D plan. Production uses
/// [NativeBcdProductDetectorFreeFullScenePlan]; tests may provide an explicit
/// adapter without reintroducing a singular-reference production path.
abstract interface class BcdProductDetectorFreeFullScenePlan {}

final class NativeBcdProductDetectorFreeFullScenePlan
    implements BcdProductDetectorFreeFullScenePlan {
  NativeBcdProductDetectorFreeFullScenePlan._(this.plan) {
    plan.requireCertifiedProduct();
  }

  final BcdDetectorFreeFullScenePlan plan;
}

/// Builds every D reference only after B has certified its metric floor and
/// walls. Product planning is therefore lazy and cannot run on a failed B.
abstract interface class BcdProductDetectorFreeFullScenePlanFactory {
  BcdProductDetectorFreeFullScenePlan? build({
    required BcdFinalizeInputBundle inputs,
    required StructuralFloorDomain selectedFloor,
    required List<StructuralWall> certifiedWalls,
  });
}

final class NativeBcdProductDetectorFreeFullScenePlanFactory
    implements BcdProductDetectorFreeFullScenePlanFactory {
  const NativeBcdProductDetectorFreeFullScenePlanFactory({
    required this.captureDigest,
    required this.backendAbi,
  });

  final String captureDigest;
  final String backendAbi;

  @override
  BcdProductDetectorFreeFullScenePlan build({
    required BcdFinalizeInputBundle inputs,
    required StructuralFloorDomain selectedFloor,
    required List<StructuralWall> certifiedWalls,
  }) {
    final buildSet = BcdDetectorFreeJobBuilder.buildAll(
      bundle: inputs,
      assetReader: const BcdNativeDetectorFreeAssetReader.path(),
      floorValue: selectedFloor.planeValue,
      selectedFloor: selectedFloor,
      certifiedWalls: certifiedWalls,
    );
    return NativeBcdProductDetectorFreeFullScenePlan._(
      BcdDetectorFreeFullSceneScheduler.buildAll(
        captureDigest: captureDigest,
        backendAbi: backendAbi,
        buildSet: buildSet,
      ),
    );
  }
}

enum BcdProductDetectorFreeReferenceStatus { certified, blocked, skipped }

final class BcdProductDetectorFreeReferenceSummary {
  const BcdProductDetectorFreeReferenceSummary({
    required this.referenceFrameId,
    required this.status,
    required this.failedFoldMask,
    required this.preCertificateBirthCount,
    required this.blockedBirthCount,
    required this.finalBirthCount,
    this.skipReason,
  });

  final int referenceFrameId;
  final BcdProductDetectorFreeReferenceStatus status;
  final int failedFoldMask;
  final int preCertificateBirthCount;
  final int blockedBirthCount;
  final int finalBirthCount;
  final String? skipReason;
}

/// Immutable batch evidence returned to the product layer. The merged cloud
/// contains certified births only and remains in metric gauge until the
/// product boundary inverse-transforms it exactly once.
final class BcdProductDetectorFreeFullSceneExecution {
  BcdProductDetectorFreeFullSceneExecution({
    required BcdPointCloud mergedMetricBirthCloud,
    required List<BcdProductDetectorFreeReferenceSummary> references,
    required this.cacheStats,
  }) : mergedMetricBirthCloud = BcdPointCloud(
         xyz: Float32List.fromList(mergedMetricBirthCloud.xyz),
         rgb: Uint8List.fromList(mergedMetricBirthCloud.rgb),
       ),
       references = List.unmodifiable(references) {
    _validate();
  }

  final BcdPointCloud mergedMetricBirthCloud;
  final List<BcdProductDetectorFreeReferenceSummary> references;
  final BcdDetectorFreeDepthCacheStats cacheStats;

  int get certifiedReferenceCount => references
      .where(
        (item) =>
            item.status == BcdProductDetectorFreeReferenceStatus.certified,
      )
      .length;
  int get blockedReferenceCount => references
      .where(
        (item) => item.status == BcdProductDetectorFreeReferenceStatus.blocked,
      )
      .length;
  int get skippedReferenceCount => references
      .where(
        (item) => item.status == BcdProductDetectorFreeReferenceStatus.skipped,
      )
      .length;
  int get preCertificateBirthCount =>
      references.fold(0, (sum, item) => sum + item.preCertificateBirthCount);
  int get blockedBirthCount =>
      references.fold(0, (sum, item) => sum + item.blockedBirthCount);
  int get birthCount => mergedMetricBirthCloud.pointCount;

  void _validate() {
    if (!_cloudFiniteForExecution(mergedMetricBirthCloud) ||
        cacheStats.hits < 0 ||
        cacheStats.misses < 0 ||
        cacheStats.lruEvictions < 0 ||
        cacheStats.lastUseEvictions < 0 ||
        cacheStats.currentEntries < 0 ||
        cacheStats.currentBytes < 0 ||
        cacheStats.peakBytes < 0) {
      throw StateError('malformed detector-free full-scene execution');
    }
    var certifiedBirths = 0;
    for (var index = 0; index < references.length; index++) {
      final item = references[index];
      if (item.referenceFrameId < 0 ||
          (index > 0 &&
              references[index - 1].referenceFrameId >=
                  item.referenceFrameId) ||
          item.failedFoldMask < 0 ||
          item.preCertificateBirthCount < 0 ||
          item.blockedBirthCount < 0 ||
          item.finalBirthCount < 0 ||
          item.blockedBirthCount > item.preCertificateBirthCount ||
          item.preCertificateBirthCount - item.blockedBirthCount !=
              item.finalBirthCount) {
        throw StateError('malformed detector-free reference summary');
      }
      switch (item.status) {
        case BcdProductDetectorFreeReferenceStatus.certified:
          if (item.failedFoldMask != 0 || item.skipReason != null) {
            throw StateError('malformed certified detector-free reference');
          }
          certifiedBirths += item.finalBirthCount;
        case BcdProductDetectorFreeReferenceStatus.blocked:
          if (item.failedFoldMask == 0 ||
              item.finalBirthCount != 0 ||
              item.skipReason != null) {
            throw StateError('malformed blocked detector-free reference');
          }
        case BcdProductDetectorFreeReferenceStatus.skipped:
          if (item.failedFoldMask != 0 ||
              item.preCertificateBirthCount != 0 ||
              item.blockedBirthCount != 0 ||
              item.finalBirthCount != 0 ||
              item.skipReason == null) {
            throw StateError('malformed skipped detector-free reference');
          }
      }
    }
    if (certifiedBirths != mergedMetricBirthCloud.pointCount) {
      throw StateError('D merged cloud disagrees with certified references');
    }
  }

  static bool _cloudFiniteForExecution(BcdPointCloud cloud) =>
      cloud.xyz.length % 3 == 0 &&
      cloud.rgb.length == cloud.xyz.length &&
      cloud.xyz.every((value) => value.isFinite);
}

/// Injectable batch D boundary. Production executes a scheduler-owned
/// full-scene plan serially in the same background isolate as B/C.
abstract interface class BcdProductDetectorFreeFullSceneRunner {
  BcdProductDetectorFreeFullSceneExecution run(
    BcdProductDetectorFreeFullScenePlan plan,
  );
}

class NativeBcdProductDetectorFreeFullSceneRunner
    implements BcdProductDetectorFreeFullSceneRunner {
  const NativeBcdProductDetectorFreeFullSceneRunner({
    this.runner = const BcdFfiDetectorFreeDepthRunner(),
    this.maximumCacheEntries = 64,
    this.maximumCacheBytes = 4 * 1024 * 1024,
  });

  final BcdDetectorFreeDepthRunner runner;
  final int maximumCacheEntries;
  final int maximumCacheBytes;

  @override
  BcdProductDetectorFreeFullSceneExecution run(
    BcdProductDetectorFreeFullScenePlan plan,
  ) {
    if (plan is! NativeBcdProductDetectorFreeFullScenePlan) {
      throw ArgumentError('native D runner requires a native full-scene plan');
    }
    plan.plan.requireCertifiedProduct();
    final execution = BcdDetectorFreeFullSceneScheduler.execute(
      plan: plan.plan,
      runner: runner,
      maximumCacheEntries: maximumCacheEntries,
      maximumCacheBytes: maximumCacheBytes,
    );
    return BcdProductDetectorFreeFullSceneExecution(
      mergedMetricBirthCloud: execution.mergedMetricBirthCloud,
      references: [
        for (final outcome in execution.outcomes)
          BcdProductDetectorFreeReferenceSummary(
            referenceFrameId: outcome.referenceFrameId,
            status: outcome.isSkipped
                ? BcdProductDetectorFreeReferenceStatus.skipped
                : outcome.isBlocked
                ? BcdProductDetectorFreeReferenceStatus.blocked
                : BcdProductDetectorFreeReferenceStatus.certified,
            failedFoldMask:
                outcome.birthResult?.certificate.failedFoldMask ?? 0,
            preCertificateBirthCount:
                outcome.birthResult?.certificate.preCertificateBirthCount ?? 0,
            blockedBirthCount:
                outcome.birthResult?.certificate.blockedBirthCount ?? 0,
            finalBirthCount:
                outcome.birthResult?.certificate.finalBirthCount ?? 0,
            skipReason: outcome.skipped?.reason.name,
          ),
      ],
      cacheStats: execution.cacheStats,
    );
  }
}

enum BcdProductPublication { sparseOnly, structural, structuralAndDetectorFree }

class BcdProductFinalizeResult {
  const BcdProductFinalizeResult({
    required this.finalize,
    required this.posesPacked,
    required this.summary,
    required this.refined,
    required this.publication,
    required this.inputs,
    required this.structural,
    required this.structuralFailure,
    required this.detectorFreeFailure,
    required this.detectorFreeExecution,
  });

  final BcdFinalizeResult finalize;

  /// Exact source objects; product enrichment never edits pose or summary.
  final Float64List posesPacked;
  final Map<String, dynamic> summary;
  final bool refined;
  final BcdProductPublication publication;
  final BcdFinalizeInputBundle? inputs;
  final BcdStructuralQualityResult? structural;
  final String? structuralFailure;
  final String? detectorFreeFailure;
  final BcdProductDetectorFreeFullSceneExecution? detectorFreeExecution;

  Float32List get xyz => finalize.cloud.xyz;
  Uint8List get rgb => finalize.cloud.rgb;
}

class BcdProductFinalize {
  const BcdProductFinalize({
    this.structuralRunner = const NativeBcdProductStructuralRunner(),
    this.detectorFreeRunner =
        const NativeBcdProductDetectorFreeFullSceneRunner(),
  });

  final BcdProductStructuralRunner structuralRunner;
  final BcdProductDetectorFreeFullSceneRunner detectorFreeRunner;

  /// Builds the solved-camera Sim3 bridge, runs B/C and D entirely in metric
  /// gauge, then inverse-transforms only new births and publishes in the fixed
  /// order `original sparse -> structural births -> D births`.
  ///
  /// B/C is fail-closed: any missing registered asset, quality rejection,
  /// exception, malformed birth, or prefix mutation returns the exact original
  /// sparse list objects. D is constructed lazily after B certifies metric
  /// floor/wall owners and is failure-isolated: an absent/unsupported/failed D
  /// full-scene plan produces zero D births without discarding accepted B
  /// births.
  BcdProductFinalizeResult run({
    required SfmLiveSnapshot snapshot,
    required List<SfmDurableFedFrameInput> durableFedFrames,
    BcdKnownFloorPlane? metricKnownFloorPlane,
    BcdProductDetectorFreeFullScenePlanFactory? detectorFreePlanFactory,
  }) {
    if (snapshot.xyz.length % 3 != 0 ||
        snapshot.rgb.length != snapshot.xyz.length ||
        snapshot.xyz.any((value) => !value.isFinite)) {
      return _sparseOnly(
        snapshot,
        structuralFailure: 'original sparse XYZ/RGB is malformed or non-finite',
      );
    }

    BcdFinalizeInputBundle inputs;
    BcdStructuralQualityResult structural;
    late Float32List metricSparseBaseline;
    late StructuralFloorDomain frozenMetricFloor;
    late List<StructuralWall> frozenMetricWalls;
    late List<BcdStructuralBirthResult> frozenMetricBirths;
    try {
      inputs = BcdFinalizeInputBuilder.buildFromDurableFedFrames(
        snapshot: snapshot,
        durableFedFrames: durableFedFrames,
      );
      metricSparseBaseline = Float32List.fromList(inputs.metricSparseXyz);
      if (metricSparseBaseline.isEmpty ||
          metricSparseBaseline.length % 3 != 0 ||
          metricSparseBaseline.any((value) => !value.isFinite)) {
        throw StateError(
          'metric sparse Sim3 output is malformed or non-finite',
        );
      }
      structural = structuralRunner.run(
        sparseXyz: Float32List.fromList(metricSparseBaseline),
        registeredViews: inputs.registeredViews,
        knownFloorPlane: metricKnownFloorPlane,
      );
      final certificateFailure = _structuralCertificateFailure(structural);
      if (certificateFailure != null) {
        return _sparseOnly(
          snapshot,
          inputs: inputs,
          structural: structural,
          structuralFailure: certificateFailure,
        );
      }
      for (final birth in <BcdStructuralBirthResult>[
        ...structural.floorBirths,
        ...structural.wallBirths,
        ...structural.structuralBirths,
      ]) {
        if (!_cloudFinite(birth.cloud)) {
          throw StateError('B/C structural birth is malformed or non-finite');
        }
      }
      frozenMetricFloor = _copyFloor(structural.selectedFloor!);
      frozenMetricWalls = List.unmodifiable([
        for (final wall in structural.certifiedWalls) _copyWall(wall),
      ]);
      frozenMetricBirths = List.unmodifiable([
        for (final birth in structural.structuralBirths)
          _deepCopyStructuralBirth(birth),
      ]);
    } catch (error) {
      return _sparseOnly(snapshot, structuralFailure: '$error');
    }

    final noDetectorFree = _emptyDetectorFree();
    BcdFinalizeResult structuralPublication;
    late List<BcdStructuralBirthResult> snapshotStructuralBirths;
    try {
      snapshotStructuralBirths = List.unmodifiable([
        for (final birth in frozenMetricBirths)
          _structuralBirthWithCloud(
            birth,
            inputs.metricBirthToSnapshot(birth.cloud),
          ),
      ]);
      for (final birth in snapshotStructuralBirths) {
        if (!_cloudFinite(birth.cloud)) {
          throw StateError('inverse-Sim3 B/C birth is malformed or non-finite');
        }
      }
      structuralPublication = BcdFinalizeCoordinator.appendPreservingSparse(
        originalXyz: snapshot.xyz,
        originalRgb: snapshot.rgb,
        structural: snapshotStructuralBirths,
        detectorFree: noDetectorFree,
      );
      if (!_sparsePrefixBytesExact(structuralPublication.cloud, snapshot)) {
        return _sparseOnly(
          snapshot,
          inputs: inputs,
          structural: structural,
          structuralFailure: 'B/C publication changed original sparse bytes',
        );
      }
    } catch (error) {
      return _sparseOnly(
        snapshot,
        inputs: inputs,
        structural: structural,
        structuralFailure: '$error',
      );
    }

    if (detectorFreePlanFactory == null) {
      return _published(
        snapshot: snapshot,
        finalize: structuralPublication,
        inputs: inputs,
        structural: structural,
        publication: BcdProductPublication.structural,
      );
    }

    try {
      final factoryFloor = _copyFloor(frozenMetricFloor, mutable: true);
      final factoryWalls = List<StructuralWall>.unmodifiable([
        for (final wall in frozenMetricWalls) _copyWall(wall, mutable: true),
      ]);
      final detectorFreePlan = detectorFreePlanFactory.build(
        inputs: inputs,
        selectedFloor: factoryFloor,
        certifiedWalls: factoryWalls,
      );
      if (!_floatBytesEqual(inputs.metricSparseXyz, metricSparseBaseline)) {
        inputs.metricSparseXyz.setAll(0, metricSparseBaseline);
        throw StateError('D factory changed the metric sparse baseline');
      }
      if (!_sameFloor(factoryFloor, frozenMetricFloor) ||
          !_sameWalls(factoryWalls, frozenMetricWalls) ||
          !_structuralContractUnchanged(
            structural,
            frozenMetricFloor,
            frozenMetricWalls,
            frozenMetricBirths,
          )) {
        throw StateError('D factory changed the frozen B metric contract');
      }
      if (detectorFreePlan == null) {
        return _published(
          snapshot: snapshot,
          finalize: structuralPublication,
          inputs: null,
          structural: null,
          publication: BcdProductPublication.structural,
        );
      }
      final metricDetectorFree = detectorFreeRunner.run(detectorFreePlan);
      if (!_floatBytesEqual(inputs.metricSparseXyz, metricSparseBaseline)) {
        inputs.metricSparseXyz.setAll(0, metricSparseBaseline);
        throw StateError('D runner changed the frozen B metric contract');
      }
      if (!_sameFloor(factoryFloor, frozenMetricFloor) ||
          !_sameWalls(factoryWalls, frozenMetricWalls) ||
          !_structuralContractUnchanged(
            structural,
            frozenMetricFloor,
            frozenMetricWalls,
            frozenMetricBirths,
          )) {
        throw StateError('D runner changed the frozen B metric contract');
      }
      if (!_cloudFinite(metricDetectorFree.mergedMetricBirthCloud)) {
        throw StateError('D merged birth is malformed or non-finite');
      }
      if (!_sparsePrefixBytesExact(structuralPublication.cloud, snapshot)) {
        throw StateError('D execution changed original sparse bytes');
      }
      final detectorFreeCloud = inputs.metricBirthToSnapshot(
        metricDetectorFree.mergedMetricBirthCloud,
      );
      if (!_cloudFinite(detectorFreeCloud)) {
        throw StateError(
          'inverse-Sim3 D merged birth is malformed or non-finite',
        );
      }
      final publication = _appendFullSceneCloud(
        structuralPublication: structuralPublication,
        detectorFreeCloud: detectorFreeCloud,
      );
      if (!_sparsePrefixBytesExact(publication.cloud, snapshot)) {
        throw StateError('D publication changed original sparse bytes');
      }
      if (!_cloudPrefixBytesExact(
        publication.cloud,
        structuralPublication.cloud,
      )) {
        throw StateError('D publication changed the frozen sparse+B prefix');
      }
      return _published(
        snapshot: snapshot,
        finalize: publication,
        inputs: null,
        structural: null,
        publication: detectorFreeCloud.pointCount == 0
            ? BcdProductPublication.structural
            : BcdProductPublication.structuralAndDetectorFree,
        detectorFreeExecution: metricDetectorFree,
      );
    } catch (error) {
      return _published(
        snapshot: snapshot,
        finalize: structuralPublication,
        inputs: null,
        structural: null,
        publication: BcdProductPublication.structural,
        detectorFreeFailure: '$error',
      );
    }
  }

  static BcdProductFinalizeResult _sparseOnly(
    SfmLiveSnapshot snapshot, {
    BcdFinalizeInputBundle? inputs,
    BcdStructuralQualityResult? structural,
    required String structuralFailure,
  }) => BcdProductFinalizeResult(
    finalize: BcdFinalizeResult(
      cloud: BcdPointCloud(xyz: snapshot.xyz, rgb: snapshot.rgb),
      originalPointCount: snapshot.pointCount,
      structuralBirthCount: 0,
      detectorFreeBirthCount: 0,
    ),
    posesPacked: snapshot.posesPacked,
    summary: snapshot.summary,
    refined: snapshot.refined,
    publication: BcdProductPublication.sparseOnly,
    inputs: inputs,
    structural: structural,
    structuralFailure: structuralFailure,
    detectorFreeFailure: null,
    detectorFreeExecution: null,
  );

  static BcdProductFinalizeResult _published({
    required SfmLiveSnapshot snapshot,
    required BcdFinalizeResult finalize,
    required BcdFinalizeInputBundle? inputs,
    required BcdStructuralQualityResult? structural,
    required BcdProductPublication publication,
    String? detectorFreeFailure,
    BcdProductDetectorFreeFullSceneExecution? detectorFreeExecution,
  }) => BcdProductFinalizeResult(
    finalize: finalize,
    posesPacked: snapshot.posesPacked,
    summary: snapshot.summary,
    refined: snapshot.refined,
    publication: publication,
    inputs: inputs,
    structural: structural,
    structuralFailure: null,
    detectorFreeFailure: detectorFreeFailure,
    detectorFreeExecution: detectorFreeExecution,
  );

  static BcdDetectorFreeBirthResult _emptyDetectorFree() {
    final empty = Uint8List(0);
    return BcdDetectorFreeBirthResult(
      cloud: BcdPointCloud.empty(),
      bornCandidateIndices: const [],
      floorRerouteCandidateIndices: const [],
      ownership: ReferenceCertifiedBirthOwnershipResult(
        inputEligible: empty,
        floorOwned: empty,
        wallOwned: empty,
        structuralOwned: empty,
        certificate: ReferenceBirthCertificateResult(
          failedFoldMask: 0,
          preCertificateBirthCount: 0,
          blockedBirthCount: 0,
          finalBirthCount: 0,
          born: Uint8List(0),
        ),
      ),
    );
  }

  static String? _structuralCertificateFailure(
    BcdStructuralQualityResult structural,
  ) {
    if (!structural.qualityPassed) {
      return structural.rejectedReason ?? 'B/C structural quality rejected';
    }
    final floor = structural.selectedFloor;
    if (floor == null || !floor.certified) {
      return 'B/C selected floor is not certified';
    }
    final floorDecision = structural.floorDecision;
    if (!floorDecision.decisive ||
        floorDecision.winnerProposalIndex == null ||
        floorDecision.winnerProposalIndex! < 0 ||
        (floorDecision.stage != BcdFloorSelectionStage.coarse10cm &&
            floorDecision.stage != BcdFloorSelectionStage.fine5cmSingle &&
            floorDecision.stage != BcdFloorSelectionStage.fine5cmTop2) ||
        floorDecision.requiredFineProposalIndices.isNotEmpty) {
      return 'B/C floor decision is incomplete';
    }
    final wallDecision = structural.wallDecision;
    if (wallDecision == null ||
        !wallDecision.complete ||
        wallDecision.selectedCandidateIds.isEmpty ||
        wallDecision.selectedCandidateIds.any((id) => id.trim().isEmpty) ||
        wallDecision.selectedCandidateIds.toSet().length !=
            wallDecision.selectedCandidateIds.length) {
      return 'B/C wall decision is incomplete';
    }
    if (structural.certifiedWalls.isEmpty ||
        structural.certifiedWalls.any((wall) => !wall.certified)) {
      return 'B/C wall ownership is not certified';
    }
    if (structural.wallBirths.isEmpty ||
        structural.wallBirths.every((birth) => birth.cloud.pointCount == 0)) {
      return 'B/C wall birth evidence is absent';
    }
    final ownedBirths = <BcdStructuralBirthResult>[
      ...structural.floorBirths,
      ...structural.wallBirths,
    ];
    if (!_sameBirthCloudSequence(structural.structuralBirths, ownedBirths)) {
      return 'B/C publication is not the certified floor+wall birth sequence';
    }
    return null;
  }

  static bool _sameBirthCloudSequence(
    List<BcdStructuralBirthResult> publication,
    List<BcdStructuralBirthResult> owners,
  ) {
    if (publication.length != owners.length) return false;
    for (var index = 0; index < publication.length; index++) {
      if (!_cloudBytesEqual(publication[index].cloud, owners[index].cloud)) {
        return false;
      }
    }
    return true;
  }

  static BcdFinalizeResult _appendFullSceneCloud({
    required BcdFinalizeResult structuralPublication,
    required BcdPointCloud detectorFreeCloud,
  }) {
    if (!_cloudFinite(structuralPublication.cloud) ||
        !_cloudFinite(detectorFreeCloud)) {
      throw StateError('cannot append malformed full-scene D cloud');
    }
    final xyz = Float32List(
      structuralPublication.cloud.xyz.length + detectorFreeCloud.xyz.length,
    )..setAll(0, structuralPublication.cloud.xyz);
    xyz.setAll(structuralPublication.cloud.xyz.length, detectorFreeCloud.xyz);
    final rgb = Uint8List(
      structuralPublication.cloud.rgb.length + detectorFreeCloud.rgb.length,
    )..setAll(0, structuralPublication.cloud.rgb);
    rgb.setAll(structuralPublication.cloud.rgb.length, detectorFreeCloud.rgb);
    return BcdFinalizeResult(
      cloud: BcdPointCloud(xyz: xyz, rgb: rgb),
      originalPointCount: structuralPublication.originalPointCount,
      structuralBirthCount: structuralPublication.structuralBirthCount,
      detectorFreeBirthCount: detectorFreeCloud.pointCount,
    );
  }

  static BcdStructuralBirthResult _structuralBirthWithCloud(
    BcdStructuralBirthResult source,
    BcdPointCloud cloud,
  ) => BcdStructuralBirthResult(
    cloud: cloud,
    evaluatedCandidateIndices: source.evaluatedCandidateIndices,
    acceptedCandidateIndices: source.acceptedCandidateIndices,
    evidence: source.evidence,
  );

  static BcdStructuralBirthResult _deepCopyStructuralBirth(
    BcdStructuralBirthResult source,
  ) => BcdStructuralBirthResult(
    cloud: BcdPointCloud(
      xyz: Float32List.fromList(source.cloud.xyz),
      rgb: Uint8List.fromList(source.cloud.rgb),
    ),
    evaluatedCandidateIndices: List<int>.unmodifiable(
      source.evaluatedCandidateIndices,
    ),
    acceptedCandidateIndices: List<int>.unmodifiable(
      source.acceptedCandidateIndices,
    ),
    evidence: List<PlaneSweepCandidateResult>.unmodifiable([
      for (final row in source.evidence)
        PlaneSweepCandidateResult(
          accepted: row.accepted,
          supportingViews: row.supportingViews,
          medianNcc: row.medianNcc,
          maxParallaxDeg: row.maxParallaxDeg,
          observedDepthMargin: row.observedDepthMargin,
        ),
    ]),
  );

  static StructuralFloorDomain _copyFloor(
    StructuralFloorDomain source, {
    bool mutable = false,
  }) => StructuralFloorDomain(
    certified: source.certified,
    normal: _copyDoubles(source.normal, mutable: mutable),
    basisU: _copyDoubles(source.basisU, mutable: mutable),
    basisV: _copyDoubles(source.basisV, mutable: mutable),
    planeValue: source.planeValue,
    boundsU: _copyDoubles(source.boundsU, mutable: mutable),
    boundsV: _copyDoubles(source.boundsV, mutable: mutable),
  );

  static StructuralWall _copyWall(
    StructuralWall source, {
    bool mutable = false,
  }) => StructuralWall(
    index: source.index,
    thetaDeg: source.thetaDeg,
    certified: source.certified,
    supportPoints35mm: source.supportPoints35mm,
    coverageCells10cm: source.coverageCells10cm,
    domainPoints: source.domainPoints,
    supportPoints20mm: _copyInts(source.supportPoints20mm, mutable: mutable),
    supportCells10cm: _copyInts(source.supportCells10cm, mutable: mutable),
    normal: _copyDoubles(source.normal, mutable: mutable),
    basisU: _copyDoubles(source.basisU, mutable: mutable),
    basisV: _copyDoubles(source.basisV, mutable: mutable),
    planeValue: source.planeValue,
    boundsU: _copyDoubles(source.boundsU, mutable: mutable),
    boundsHeight: _copyDoubles(source.boundsHeight, mutable: mutable),
    score: source.score,
    supportProminenceVs5cm: source.supportProminenceVs5cm,
    coverageProminenceVs5cm: source.coverageProminenceVs5cm,
  );

  static List<double> _copyDoubles(
    List<double> source, {
    required bool mutable,
  }) => mutable ? List<double>.of(source) : List<double>.unmodifiable(source);

  static List<int> _copyInts(List<int> source, {required bool mutable}) =>
      mutable ? List<int>.of(source) : List<int>.unmodifiable(source);

  static bool _structuralContractUnchanged(
    BcdStructuralQualityResult current,
    StructuralFloorDomain frozenFloor,
    List<StructuralWall> frozenWalls,
    List<BcdStructuralBirthResult> frozenBirths,
  ) =>
      current.selectedFloor != null &&
      _sameFloor(current.selectedFloor!, frozenFloor) &&
      _sameWalls(current.certifiedWalls, frozenWalls) &&
      _sameStructuralBirths(current.structuralBirths, frozenBirths);

  static bool _sameStructuralBirths(
    List<BcdStructuralBirthResult> left,
    List<BcdStructuralBirthResult> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      final a = left[index];
      final b = right[index];
      if (!_cloudBytesEqual(a.cloud, b.cloud) ||
          !_intListEqual(
            a.evaluatedCandidateIndices,
            b.evaluatedCandidateIndices,
          ) ||
          !_intListEqual(
            a.acceptedCandidateIndices,
            b.acceptedCandidateIndices,
          ) ||
          !_sameEvidence(a.evidence, b.evidence)) {
        return false;
      }
    }
    return true;
  }

  static bool _sameEvidence(
    List<PlaneSweepCandidateResult> left,
    List<PlaneSweepCandidateResult> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      final a = left[index];
      final b = right[index];
      if (a.accepted != b.accepted ||
          a.supportingViews != b.supportingViews ||
          a.medianNcc != b.medianNcc ||
          a.maxParallaxDeg != b.maxParallaxDeg ||
          a.observedDepthMargin != b.observedDepthMargin) {
        return false;
      }
    }
    return true;
  }

  static bool _cloudBytesEqual(BcdPointCloud left, BcdPointCloud right) =>
      left.xyz.length == right.xyz.length &&
      left.rgb.length == right.rgb.length &&
      _bytesEqual(_floatBytes(left.xyz), _floatBytes(right.xyz)) &&
      _bytesEqual(_uint8Bytes(left.rgb), _uint8Bytes(right.rgb));

  static bool _sparsePrefixBytesExact(
    BcdPointCloud publication,
    SfmLiveSnapshot snapshot,
  ) =>
      publication.xyz.length >= snapshot.xyz.length &&
      publication.rgb.length >= snapshot.rgb.length &&
      _bytesEqual(
        _floatBytes(snapshot.xyz),
        _floatBytes(publication.xyz, length: snapshot.xyz.length),
      ) &&
      _bytesEqual(
        _uint8Bytes(snapshot.rgb),
        _uint8Bytes(publication.rgb, length: snapshot.rgb.length),
      );

  static bool _cloudPrefixBytesExact(
    BcdPointCloud publication,
    BcdPointCloud frozenPrefix,
  ) =>
      publication.xyz.length >= frozenPrefix.xyz.length &&
      publication.rgb.length >= frozenPrefix.rgb.length &&
      _bytesEqual(
        _floatBytes(frozenPrefix.xyz),
        _floatBytes(publication.xyz, length: frozenPrefix.xyz.length),
      ) &&
      _bytesEqual(
        _uint8Bytes(frozenPrefix.rgb),
        _uint8Bytes(publication.rgb, length: frozenPrefix.rgb.length),
      );

  static bool _cloudFinite(BcdPointCloud cloud) =>
      cloud.xyz.length % 3 == 0 &&
      cloud.rgb.length == cloud.xyz.length &&
      cloud.xyz.every((value) => value.isFinite);

  static bool _floatBytesEqual(Float32List left, Float32List right) =>
      left.length == right.length &&
      _bytesEqual(_floatBytes(left), _floatBytes(right));

  static Uint8List _floatBytes(Float32List values, {int? length}) =>
      values.buffer.asUint8List(
        values.offsetInBytes,
        (length ?? values.length) * Float32List.bytesPerElement,
      );

  static Uint8List _uint8Bytes(Uint8List values, {int? length}) =>
      values.buffer.asUint8List(values.offsetInBytes, length ?? values.length);

  static bool _bytesEqual(Uint8List left, Uint8List right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  static bool _sameFloor(
    StructuralFloorDomain left,
    StructuralFloorDomain right,
  ) =>
      left.certified == right.certified &&
      left.planeValue == right.planeValue &&
      _doubleListEqual(left.normal, right.normal) &&
      _doubleListEqual(left.basisU, right.basisU) &&
      _doubleListEqual(left.basisV, right.basisV) &&
      _doubleListEqual(left.boundsU, right.boundsU) &&
      _doubleListEqual(left.boundsV, right.boundsV);

  static bool _sameWalls(
    List<StructuralWall> left,
    List<StructuralWall> right,
  ) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      final a = left[index];
      final b = right[index];
      if (a.index != b.index ||
          a.thetaDeg != b.thetaDeg ||
          a.certified != b.certified ||
          a.supportPoints35mm != b.supportPoints35mm ||
          a.coverageCells10cm != b.coverageCells10cm ||
          a.domainPoints != b.domainPoints ||
          !_intListEqual(a.supportPoints20mm, b.supportPoints20mm) ||
          !_intListEqual(a.supportCells10cm, b.supportCells10cm) ||
          !_doubleListEqual(a.normal, b.normal) ||
          !_doubleListEqual(a.basisU, b.basisU) ||
          !_doubleListEqual(a.basisV, b.basisV) ||
          a.planeValue != b.planeValue ||
          !_doubleListEqual(a.boundsU, b.boundsU) ||
          !_doubleListEqual(a.boundsHeight, b.boundsHeight) ||
          a.score != b.score ||
          a.supportProminenceVs5cm != b.supportProminenceVs5cm ||
          a.coverageProminenceVs5cm != b.coverageProminenceVs5cm) {
        return false;
      }
    }
    return true;
  }

  static bool _doubleListEqual(List<double> left, List<double> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }

  static bool _intListEqual(List<int> left, List<int> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}
