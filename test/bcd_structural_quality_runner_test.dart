import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/bcd_finalize_coordinator.dart';
import 'package:pocketworld_flutter/capture/bcd_structural_quality_runner.dart';
import 'package:pocketworld_flutter/structural_candidate_ffi.dart';
import 'package:pocketworld_flutter/structural_planesweep_ffi.dart';

class _FakeBackend implements BcdStructuralQualityBackend {
  _FakeBackend({this.coarseFloorCount = 12, this.fineFloorCount = 12});

  final int coarseFloorCount;
  final int fineFloorCount;
  int strictWallSweeps = 0;
  final floorSweepGridMeters = <double>[];
  final wallSweepGridMeters = <double>[];
  final wallSweepScaleCounts = <int>[];

  static const floor = StructuralFloorProposal(
    index: 0,
    supportPoints20mm: 200,
    coverageCells10cm: 100,
    normal: [0, 1, 0],
    planeValue: -1,
    basisU: [1, 0, 0],
    basisV: [0, 0, 1],
    boundsU: [-2, 2],
    boundsV: [-2, 2],
    rmsErrorM: 0.01,
    tiltDeg: 0,
    priorScore: 20,
  );
  static const legacy = StructuralWall(
    index: 0,
    thetaDeg: 0,
    certified: true,
    supportPoints35mm: 100,
    coverageCells10cm: 50,
    domainPoints: 100,
    supportPoints20mm: [1, 2, 3, 4, 5],
    supportCells10cm: [1, 2, 3, 4, 5],
    normal: [1, 0, 0],
    basisU: [0, 0, 1],
    basisV: [0, 1, 0],
    planeValue: 1,
    boundsU: [-2, 2],
    boundsHeight: [0, 2],
    score: 100,
    supportProminenceVs5cm: 1,
    coverageProminenceVs5cm: 1,
  );
  static const envelope = StructuralEnvelopeWallProposal(
    index: 0,
    supportPoints35mm: 80,
    coverageCells10cm: 40,
    thetaDeg: 90,
    normal: [0, 0, 1],
    basisU: [1, 0, 0],
    basisV: [0, 1, 0],
    planeValue: 2,
    boundsU: [-2, 2],
    boundsHeight: [0, 2],
    score: 80,
    cameraDistanceMinM: -3,
    cameraDistanceMaxM: -1,
    cameraClearanceMinAbsM: 1,
  );

  @override
  List<StructuralFloorProposal> proposeFloors({
    required Float32List sparseXyz,
    required double minimumCameraHeight,
  }) => const [floor];

  @override
  List<StructuralWall> fitLegacyWalls({
    required Float32List sparseXyz,
    required StructuralFloorDomain floor,
  }) => const [legacy];

  @override
  List<StructuralEnvelopeWallProposal> proposeEnvelopeWalls({
    required Float32List sparseXyz,
    required Float64List cameraCentersXyz,
    required StructuralFloorDomain floor,
  }) => const [envelope];

  @override
  BcdSurfaceSweepResult sweep(BcdStructuralSurfaceRequest request) {
    final isFloor = request.grid.normal[1].abs() > 0.9;
    (isFloor ? floorSweepGridMeters : wallSweepGridMeters).add(
      request.grid.gridM,
    );
    if (!isFloor) {
      wallSweepScaleCounts.add(request.patchRadiusMByScale.length);
    }
    final strictWall = !isFloor && request.patchRadiusMByScale.length == 2;
    if (strictWall) strictWallSweeps++;
    final baselineCount = isFloor
        ? request.grid.gridM == 0.10
              ? coarseFloorCount
              : fineFloorCount
        : (request.grid.normal[0].abs() > 0.9 ? 8 : 9);
    final count = baselineCount + (strictWall ? 2 : 0);
    final evaluatedCount = isFloor ? count : 12;
    final xyz = Float32List(count * 3);
    final rgb = Uint8List(count * 3);
    rgb.fillRange(0, rgb.length, (request.grid.gridM * 100).round());
    for (var index = 0; index < count; index++) {
      // Make strict coordinates observably different so the runner test can
      // prove candidate support remains the base-sweep snapshot.
      xyz[index * 3] =
          (strictWall && index >= baselineCount ? 100 : 0) + index * 0.051;
      xyz[index * 3 + 1] = isFloor ? request.grid.planeValue : index * 0.051;
      xyz[index * 3 + 2] = isFloor ? index * 0.051 : request.grid.planeValue;
    }
    final evidence = [
      for (var index = 0; index < evaluatedCount; index++)
        PlaneSweepCandidateResult(
          accepted: index < count,
          supportingViews: 5,
          medianNcc: 0.9,
          maxParallaxDeg: 20,
          observedDepthMargin: 0.04,
        ),
    ];
    final birth = BcdStructuralBirthResult(
      cloud: BcdPointCloud(xyz: xyz, rgb: rgb),
      evaluatedCandidateIndices: [
        for (var index = 0; index < evaluatedCount; index++) index,
      ],
      acceptedCandidateIndices: [
        for (var index = 0; index < count; index++) index,
      ],
      evidence: evidence,
    );
    return BcdSurfaceSweepResult(
      births: [birth],
      summary: BcdFinalizeCoordinator.aggregateStructuralEvidence(
        batches: [birth],
        basisU: request.grid.basisU,
        basisV: request.grid.basisV,
      ),
    );
  }

  @override
  List<BcdSurfaceSweepResult> sweepMany(
    List<BcdStructuralSurfaceRequest> requests,
  ) => [for (final request in requests) sweep(request)];
}

class _KnownFloorBackend extends _FakeBackend {
  int calibrationSweeps = 0;
  StructuralFloorDomain? fittedAgainst;
  final legacySweepGrids = <StructuralCandidateGridSpec>[];
  final envelopeSweepGrids = <StructuralCandidateGridSpec>[];

  static const knownWall = StructuralWall(
    index: 3,
    thetaDeg: 4,
    certified: true,
    supportPoints35mm: 120,
    coverageCells10cm: 60,
    domainPoints: 120,
    supportPoints20mm: [1, 6, 10, 2, 1],
    supportCells10cm: [1, 6, 10, 2, 1],
    normal: [1, 0, 0],
    basisU: [0, 0, 1],
    basisV: [0, 1, 0],
    planeValue: 1.2,
    boundsU: [-2, 2],
    boundsHeight: [0, 2],
    score: 120,
    supportProminenceVs5cm: 1.5,
    coverageProminenceVs5cm: 1.5,
  );

  @override
  List<StructuralWall> fitLegacyWalls({
    required Float32List sparseXyz,
    required StructuralFloorDomain floor,
  }) {
    fittedAgainst = floor;
    final up = floor.normal;
    final horizontalLength = math.sqrt(up[1] * up[1] + up[2] * up[2]);
    return [
      StructuralWall(
        index: knownWall.index,
        thetaDeg: knownWall.thetaDeg,
        certified: knownWall.certified,
        supportPoints35mm: knownWall.supportPoints35mm,
        coverageCells10cm: knownWall.coverageCells10cm,
        domainPoints: knownWall.domainPoints,
        supportPoints20mm: knownWall.supportPoints20mm,
        supportCells10cm: knownWall.supportCells10cm,
        normal: knownWall.normal,
        basisU: [0, -up[2] / horizontalLength, up[1] / horizontalLength],
        basisV: up,
        planeValue: knownWall.planeValue,
        boundsU: knownWall.boundsU,
        boundsHeight: knownWall.boundsHeight,
        score: knownWall.score,
        supportProminenceVs5cm: knownWall.supportProminenceVs5cm,
        coverageProminenceVs5cm: knownWall.coverageProminenceVs5cm,
      ),
    ];
  }

  @override
  BcdSurfaceSweepResult sweep(BcdStructuralSurfaceRequest request) {
    final calibration =
        request.grid.gridM == 0.20 && request.depthOffsetsM.length == 1;
    if (!calibration) {
      if (request.grid.normal[0].abs() > 0.9) {
        legacySweepGrids.add(request.grid);
      } else if (request.grid.normal[2].abs() > 0.9) {
        envelopeSweepGrids.add(request.grid);
      }
      return super.sweep(request);
    }
    calibrationSweeps++;
    final offset = request.grid.planeValue - knownWall.planeValue;
    final count = offset < -0.075
        ? 2
        : offset < -0.025
        ? 8
        : offset < 0.025
        ? 3
        : offset < 0.075
        ? 1
        : 0;
    final xyz = Float32List(count * 3);
    final rgb = Uint8List(count * 3);
    final birth = BcdStructuralBirthResult(
      cloud: BcdPointCloud(xyz: xyz, rgb: rgb),
      evaluatedCandidateIndices: [
        for (var index = 0; index < 12; index++) index,
      ],
      acceptedCandidateIndices: [
        for (var index = 0; index < count; index++) index,
      ],
      evidence: [
        for (var index = 0; index < 12; index++)
          PlaneSweepCandidateResult(
            accepted: index < count,
            supportingViews: 4,
            medianNcc: index < count ? 0.9 : 0,
            maxParallaxDeg: 15,
            observedDepthMargin: double.infinity,
          ),
      ],
    );
    return BcdSurfaceSweepResult(
      births: [birth],
      summary: BcdFinalizeCoordinator.aggregateStructuralEvidence(
        batches: [birth],
        basisU: request.grid.basisU,
        basisV: request.grid.basisV,
      ),
    );
  }
}

class _LegacyAnchorBackend extends _FakeBackend {
  _LegacyAnchorBackend({required this.conflictingBaseSupport});

  final bool conflictingBaseSupport;

  static const rawCertified = StructuralWall(
    index: 0,
    thetaDeg: 0,
    certified: true,
    supportPoints35mm: 100,
    coverageCells10cm: 50,
    domainPoints: 100,
    supportPoints20mm: [1, 2, 3, 4, 5],
    supportCells10cm: [1, 2, 3, 4, 5],
    normal: [1, 0, 0],
    basisU: [0, 0, 1],
    basisV: [0, 1, 0],
    planeValue: 1,
    boundsU: [-2, 2],
    boundsHeight: [0, 2],
    score: 100,
    supportProminenceVs5cm: 1,
    coverageProminenceVs5cm: 1,
  );
  static const birthEligible = StructuralWall(
    index: 1,
    thetaDeg: 0,
    certified: false,
    supportPoints35mm: 90,
    coverageCells10cm: 45,
    domainPoints: 90,
    supportPoints20mm: [1, 2, 3, 4, 5],
    supportCells10cm: [1, 2, 3, 4, 5],
    normal: [1, 0, 0],
    basisU: [0, 0, 1],
    basisV: [0, 1, 0],
    planeValue: 1.5,
    boundsU: [-2, 2],
    boundsHeight: [0, 2],
    score: 90,
    supportProminenceVs5cm: 1,
    coverageProminenceVs5cm: 1,
  );

  @override
  List<StructuralWall> fitLegacyWalls({
    required Float32List sparseXyz,
    required StructuralFloorDomain floor,
  }) => const [rawCertified, birthEligible];

  @override
  List<StructuralEnvelopeWallProposal> proposeEnvelopeWalls({
    required Float32List sparseXyz,
    required Float64List cameraCentersXyz,
    required StructuralFloorDomain floor,
  }) => const [];

  @override
  BcdSurfaceSweepResult sweep(BcdStructuralSurfaceRequest request) {
    if (request.grid.normal[1].abs() > 0.9) return super.sweep(request);

    final isRawCertified =
        (request.grid.planeValue - rawCertified.planeValue).abs() < 1e-12;
    final strict = request.patchRadiusMByScale.length == 2;
    if (strict) strictWallSweeps++;
    final acceptedCount = strict ? (isRawCertified ? 10 : 14) : 8;
    const evaluatedCount = 16;
    final xyz = Float32List(acceptedCount * 3);
    final rgb = Uint8List(acceptedCount * 3);
    for (var index = 0; index < acceptedCount; index++) {
      final baseX = isRawCertified
          ? conflictingBaseSupport
                ? (index < 5 ? birthEligible.planeValue : 0.5)
                : rawCertified.planeValue
          : birthEligible.planeValue;
      xyz[index * 3] = index < 8 ? baseX : 100.0 + index;
      xyz[index * 3 + 1] = 0;
      xyz[index * 3 + 2] = -0.75 + index * 0.11;
    }
    final evidence = [
      for (var index = 0; index < evaluatedCount; index++)
        PlaneSweepCandidateResult(
          accepted: index < acceptedCount,
          supportingViews: 5,
          medianNcc: 0.9,
          maxParallaxDeg: 20,
          observedDepthMargin: 0.04,
        ),
    ];
    final birth = BcdStructuralBirthResult(
      cloud: BcdPointCloud(xyz: xyz, rgb: rgb),
      evaluatedCandidateIndices: [
        for (var index = 0; index < evaluatedCount; index++) index,
      ],
      acceptedCandidateIndices: [
        for (var index = 0; index < acceptedCount; index++) index,
      ],
      evidence: evidence,
    );
    return BcdSurfaceSweepResult(
      births: [birth],
      summary: BcdFinalizeCoordinator.aggregateStructuralEvidence(
        batches: [birth],
        basisU: request.grid.basisU,
        basisV: request.grid.basisV,
      ),
    );
  }
}

class _WallRequirementBackend extends _FakeBackend {
  _WallRequirementBackend({
    required this.hasCandidate,
    required this.acceptedWallBirths,
  });

  final bool hasCandidate;
  final int acceptedWallBirths;
  int floorSweeps = 0;

  @override
  List<StructuralWall> fitLegacyWalls({
    required Float32List sparseXyz,
    required StructuralFloorDomain floor,
  }) => hasCandidate ? const [_FakeBackend.legacy] : const [];

  @override
  List<StructuralEnvelopeWallProposal> proposeEnvelopeWalls({
    required Float32List sparseXyz,
    required Float64List cameraCentersXyz,
    required StructuralFloorDomain floor,
  }) => const [];

  @override
  BcdSurfaceSweepResult sweep(BcdStructuralSurfaceRequest request) {
    final isFloor = request.grid.normal[1].abs() > 0.9;
    if (isFloor) {
      floorSweeps++;
      return super.sweep(request);
    }
    const evaluated = 12;
    final count = acceptedWallBirths;
    final xyz = Float32List(count * 3);
    final rgb = Uint8List(count * 3);
    for (var index = 0; index < count; index++) {
      xyz[index * 3] = request.grid.planeValue;
      xyz[index * 3 + 1] = index * 0.051;
      xyz[index * 3 + 2] = index * 0.051;
    }
    final birth = BcdStructuralBirthResult(
      cloud: BcdPointCloud(xyz: xyz, rgb: rgb),
      evaluatedCandidateIndices: [
        for (var index = 0; index < evaluated; index++) index,
      ],
      acceptedCandidateIndices: [
        for (var index = 0; index < count; index++) index,
      ],
      evidence: [
        for (var index = 0; index < evaluated; index++)
          PlaneSweepCandidateResult(
            accepted: index < count,
            supportingViews: index < count ? 5 : 0,
            medianNcc: index < count ? 0.9 : 0,
            maxParallaxDeg: index < count ? 20 : 0,
            observedDepthMargin: index < count ? 0.04 : 0,
          ),
      ],
    );
    return BcdSurfaceSweepResult(
      births: [birth],
      summary: BcdFinalizeCoordinator.aggregateStructuralEvidence(
        batches: [birth],
        basisU: request.grid.basisU,
        basisV: request.grid.basisV,
      ),
    );
  }
}

void main() {
  List<BcdPlaneSweepView> threeViews() => [
    for (var index = 0; index < 3; index++)
      BcdPlaneSweepView(
        jpegPath: '/tmp/$index.jpg',
        projection3x4: Float64List(12),
        cameraCenter: Float64List.fromList([index.toDouble(), 1, 0]),
        width: 100,
        height: 100,
      ),
  ];

  test('known floor metadata resolves the capture-time plane sign', () {
    final floor = BcdKnownFloorPlane.fromSignedDistanceMetadata(
      normal: const [0, 2, 0],
      rawPlaneD: 2,
      sparseXyz: Float32List.fromList(const [
        0,
        -1.00,
        0,
        1,
        -1.01,
        0,
        2,
        -0.99,
        0,
        0,
        0.5,
        0,
      ]),
    );

    expect(floor.normal, const [0, 1, 0]);
    expect(floor.planeValue, -1);
  });

  test('quality runner publishes only selected floor and wall owners', () {
    final backend = _FakeBackend();
    final sparse = Float32List(300);
    final views = [
      for (var index = 0; index < 3; index++)
        BcdPlaneSweepView(
          jpegPath: '/tmp/$index.jpg',
          projection3x4: Float64List(12),
          cameraCenter: Float64List.fromList([index.toDouble(), 1, 0]),
          width: 100,
          height: 100,
        ),
    ];
    final result = BcdStructuralQualityRunner(
      backend: backend,
    ).run(sparseXyz: sparse, registeredViews: views);

    expect(result.qualityPassed, isTrue);
    expect(result.rejectedReason, isNull);
    expect(result.floorDecision.winnerProposalIndex, 0);
    expect(result.selectedFloor?.certified, isTrue);
    expect(result.certifiedWalls, hasLength(2));
    expect(
      result.certifiedWalls,
      everyElement(predicate<StructuralWall>((w) => w.certified)),
    );
    expect(result.floorBirths, hasLength(1));
    expect(result.wallBirths, hasLength(2));
    expect(result.structuralBirths, hasLength(3));
    expect(
      backend.strictWallSweeps,
      4,
      reason: 'two 5 cm strict selections plus two 1 cm publications',
    );
    expect(
      result.wallBirths.fold<int>(
        0,
        (sum, birth) => sum + birth.cloud.pointCount,
      ),
      21,
      reason: 'selected base owners receive nonregressing strict-scale births',
    );
    expect(
      result.wallCandidates
          .singleWhere((row) => row.candidateId == 'legacy__wall_0')
          .incumbent,
      isTrue,
      reason:
          'sparse certification anchors a family but still needs image births',
    );
    for (final candidate in result.wallCandidates) {
      final support = candidate.birthSupportXyz;
      expect(
        support,
        isNotNull,
        reason: '${candidate.candidateId} must retain its base birth support',
      );
      expect(
        support,
        hasLength(candidate.accepted * 3),
        reason:
            '${candidate.candidateId} support must describe base births only',
      );
      expect(
        candidate.strict?.accepted,
        greaterThan(candidate.accepted),
        reason: 'the fake strict replay must append accepted sites',
      );
      expect(
        support,
        hasLength(candidate.accepted * 3),
        reason:
            '${candidate.candidateId} strict replay must not append to base support',
      );
      expect(
        [
          for (var index = 0; index < support!.length; index += 3)
            support[index],
        ],
        everyElement(lessThan(1)),
        reason:
            '${candidate.candidateId} strict replay must not overwrite base support',
      );
    }
    final legacyMetrics = result.wallCandidates.singleWhere(
      (row) => row.candidateId == 'legacy__wall_0',
    );
    expect(legacyMetrics.accepted, 8);
    expect(legacyMetrics.strict?.accepted, 10);
    expect(legacyMetrics.birthSupportXyz, hasLength(24));
    final envelopeMetrics = result.wallCandidates.singleWhere(
      (row) => row.candidateId == 'envelope__wall_envelope_0',
    );
    expect(envelopeMetrics.accepted, 9);
    expect(envelopeMetrics.strict?.accepted, 11);
    expect(envelopeMetrics.birthSupportXyz, hasLength(27));
    expect(
      result.wallDecision?.selectedCandidateIds,
      unorderedEquals(const ['legacy__wall_0', 'envelope__wall_envelope_0']),
    );
  });

  test(
    'coarse/fine sweeps only select owners; published births come from 1 cm winner sweeps',
    () {
      final backend = _FakeBackend();
      final result = BcdStructuralQualityRunner(
        backend: backend,
      ).run(sparseXyz: Float32List(300), registeredViews: threeViews());

      expect(result.qualityPassed, isTrue);
      expect(backend.floorSweepGridMeters, contains(0.10));
      expect(
        backend.floorSweepGridMeters.where((gridM) => gridM == 0.01),
        hasLength(1),
        reason: 'only the selected floor owner receives a dense replay',
      );
      expect(result.floorBirths.expand((birth) => birth.cloud.rgb), isNotEmpty);
      expect(
        result.floorBirths.expand((birth) => birth.cloud.rgb),
        everyElement(1),
        reason: '10 cm/5 cm selection births must never be published',
      );

      expect(backend.wallSweepGridMeters, contains(0.05));
      expect(
        backend.wallSweepGridMeters.where((gridM) => gridM == 0.01),
        hasLength(result.wallDecision!.selectedCandidateIds.length * 2),
        reason:
            'each selected wall owner receives 1 cm base and strict replays',
      );
      final denseWallScaleCounts = <int>[
        for (var index = 0; index < backend.wallSweepGridMeters.length; index++)
          if (backend.wallSweepGridMeters[index] == 0.01)
            backend.wallSweepScaleCounts[index],
      ];
      expect(
        denseWallScaleCounts,
        [
          for (final _ in result.wallDecision!.selectedCandidateIds) ...[1, 2],
        ],
        reason:
            'strict births append only after nonregression against the same 1 cm base grid',
      );
      expect(result.wallBirths.expand((birth) => birth.cloud.rgb), isNotEmpty);
      expect(
        result.wallBirths.expand((birth) => birth.cloud.rgb),
        everyElement(1),
        reason: '5 cm wall selection/rescue births must never be published',
      );
    },
  );

  test('5 cm floor refinement selects but never publishes its samples', () {
    final backend = _FakeBackend(coarseFloorCount: 11, fineFloorCount: 20);
    final result = BcdStructuralQualityRunner(
      backend: backend,
    ).run(sparseXyz: Float32List(300), registeredViews: threeViews());

    expect(result.qualityPassed, isTrue);
    expect(result.floorDecision.stage, BcdFloorSelectionStage.fine5cmSingle);
    expect(backend.floorSweepGridMeters, [0.10, 0.05, 0.01]);
    expect(result.floorFineSummaries.values.single.accepted, 20);
    expect(
      result.floorBirths.expand((birth) => birth.cloud.rgb),
      everyElement(1),
      reason: 'the selected 5 cm evidence may not leak into final births',
    );
  });

  test('no wall candidates cannot turn a decisive floor into B success', () {
    final backend = _WallRequirementBackend(
      hasCandidate: false,
      acceptedWallBirths: 0,
    );
    final result = BcdStructuralQualityRunner(
      backend: backend,
    ).run(sparseXyz: Float32List(300), registeredViews: threeViews());

    expect(backend.floorSweeps, greaterThan(0));
    expect(result.selectedFloor?.certified, isTrue);
    expect(result.qualityPassed, isFalse);
    expect(result.rejectedReason, 'wall_candidates_absent');
    expect(result.certifiedWalls, isEmpty);
    expect(result.floorBirths, isEmpty);
    expect(result.structuralBirths, isEmpty);
  });

  test('all image-rejected wall candidates fail closed', () {
    final result = BcdStructuralQualityRunner(
      backend: _WallRequirementBackend(
        hasCandidate: true,
        acceptedWallBirths: 7,
      ),
    ).run(sparseXyz: Float32List(300), registeredViews: threeViews());

    expect(result.qualityPassed, isFalse);
    expect(result.rejectedReason, 'wall_owner_unresolved');
    expect(result.wallCandidates.single.accepted, 7);
    expect(result.certifiedWalls, isEmpty);
    expect(result.wallBirths, isEmpty);
  });

  test(
    'sparse-certified geometry with zero wall births is not certified B',
    () {
      final result = BcdStructuralQualityRunner(
        backend: _WallRequirementBackend(
          hasCandidate: true,
          acceptedWallBirths: 0,
        ),
      ).run(sparseXyz: Float32List(300), registeredViews: threeViews());

      expect(_FakeBackend.legacy.certified, isTrue);
      expect(result.qualityPassed, isFalse);
      expect(result.rejectedReason, 'wall_birth_evidence_absent');
      expect(result.wallCandidates.single.accepted, 0);
      expect(result.certifiedWalls, isEmpty);
      expect(result.structuralBirths, isEmpty);
    },
  );

  test(
    'one image-certified wall with births satisfies required B wall gate',
    () {
      final result = BcdStructuralQualityRunner(
        backend: _WallRequirementBackend(
          hasCandidate: true,
          acceptedWallBirths: 8,
        ),
      ).run(sparseXyz: Float32List(300), registeredViews: threeViews());

      expect(result.qualityPassed, isTrue);
      expect(result.rejectedReason, isNull);
      expect(result.certifiedWalls, hasLength(1));
      expect(result.certifiedWalls.single.certified, isTrue);
      expect(result.wallBirths, hasLength(1));
      expect(result.wallBirths.single.cloud.pointCount, 8);
    },
  );

  test('known floor walls require a unique sparse-supported image peak', () {
    final backend = _KnownFloorBackend();
    final sparse = Float32List(300);
    final views = [
      for (var index = 0; index < 3; index++)
        BcdPlaneSweepView(
          jpegPath: '/tmp/$index.jpg',
          projection3x4: Float64List(12),
          cameraCenter: Float64List.fromList([index.toDouble(), 1, 0]),
          width: 100,
          height: 100,
        ),
    ];
    final result = BcdStructuralQualityRunner(backend: backend).run(
      sparseXyz: sparse,
      registeredViews: views,
      knownFloorPlane: const BcdKnownFloorPlane(
        normal: [0, 0.99995, 0.01],
        planeValue: -1.1,
      ),
    );

    expect(backend.calibrationSweeps, 5);
    expect(backend.fittedAgainst?.normal, const [0, 0.99995, 0.01]);
    expect(backend.fittedAgainst?.planeValue, -1.1);
    expect(backend.legacySweepGrids, isNotEmpty);
    for (final grid in backend.legacySweepGrids) {
      expect(grid.basisV, const [0, 0.99995, 0.01]);
      expect(grid.basisVOriginValue, -1.1);
    }
    expect(backend.envelopeSweepGrids, isNotEmpty);
    for (final grid in backend.envelopeSweepGrids) {
      expect(grid.basisV, const [0, 1, 0]);
      expect(grid.basisVOriginValue, -1);
    }
    final calibration = result.wallPlaneCalibrations.single;
    expect(calibration.certified, isTrue);
    expect(calibration.bestOffsetM, -0.05);
    expect(calibration.bestAccepted, 8);
    expect(calibration.secondAccepted, 3);
    expect(calibration.uniqueCountPeak, isTrue);
    expect(calibration.sparseAgrees, isTrue);
    final legacy = result.certifiedWalls.singleWhere((wall) => wall.index == 3);
    expect(legacy.planeValue, closeTo(1.15, 1e-12));
    expect(legacy.boundsHeight[0], closeTo(-0.1, 1e-12));
    expect(legacy.boundsHeight[1], closeTo(1.9, 1e-12));
    final calibratedCandidate = result.wallCandidates.singleWhere(
      (row) => row.candidateId == 'legacy__wall_3',
    );
    expect(calibratedCandidate.planeValue, closeTo(1.15, 1e-12));
    expect(
      calibratedCandidate.incumbent,
      isTrue,
      reason: 'image-calibrated sparse wall remains a family anchor',
    );
  });

  test('base births demote a raw-certified conflicting legacy anchor', () {
    final backend = _LegacyAnchorBackend(conflictingBaseSupport: true);
    final result = BcdStructuralQualityRunner(backend: backend).run(
      sparseXyz: Float32List(300),
      registeredViews: [
        for (var index = 0; index < 3; index++)
          BcdPlaneSweepView(
            jpegPath: '/tmp/$index.jpg',
            projection3x4: Float64List(12),
            cameraCenter: Float64List.fromList([index.toDouble(), 1, 0]),
            width: 100,
            height: 100,
          ),
      ],
    );

    final rawCertified = result.wallCandidates.singleWhere(
      (row) => row.candidateId == 'legacy__wall_0',
    );
    final birthEligible = result.wallCandidates.singleWhere(
      (row) => row.candidateId == 'legacy__wall_1',
    );
    expect(result.qualityPassed, isTrue);
    expect(rawCertified.accepted, 8);
    expect(rawCertified.coverageCells5cm, 8);
    expect(birthEligible.accepted, 8);
    expect(birthEligible.coverageCells5cm, 8);
    expect(
      BcdFinalizeCoordinator.wallBirthSupportsCompete(
        rawCertified,
        birthEligible,
      ),
      isTrue,
      reason: 'five of eight base births lie in the other finite 10 cm domain',
    );
    expect(rawCertified.incumbent, isFalse);
    expect(result.wallDecision?.selectedCandidateIds, const ['legacy__wall_1']);
    expect(rawCertified.strict?.accepted, 10);
    expect(birthEligible.strict?.accepted, 14);
    expect(rawCertified.birthSupportXyz, hasLength(24));
    expect(
      [
        for (
          var offset = 0;
          offset < rawCertified.birthSupportXyz!.length;
          offset += 3
        )
          rawCertified.birthSupportXyz![offset],
      ],
      everyElement(lessThan(3)),
      reason: 'strict-only coordinates must not overwrite base birth support',
    );
  });

  test('spatially separated base births retain a raw-certified anchor', () {
    final backend = _LegacyAnchorBackend(conflictingBaseSupport: false);
    final result = BcdStructuralQualityRunner(backend: backend).run(
      sparseXyz: Float32List(300),
      registeredViews: [
        for (var index = 0; index < 3; index++)
          BcdPlaneSweepView(
            jpegPath: '/tmp/$index.jpg',
            projection3x4: Float64List(12),
            cameraCenter: Float64List.fromList([index.toDouble(), 1, 0]),
            width: 100,
            height: 100,
          ),
      ],
    );

    final rawCertified = result.wallCandidates.singleWhere(
      (row) => row.candidateId == 'legacy__wall_0',
    );
    final birthEligible = result.wallCandidates.singleWhere(
      (row) => row.candidateId == 'legacy__wall_1',
    );
    expect(result.qualityPassed, isTrue);
    expect(rawCertified.accepted, 8);
    expect(rawCertified.coverageCells5cm, 8);
    expect(birthEligible.accepted, 8);
    expect(birthEligible.coverageCells5cm, 8);
    expect(
      BcdFinalizeCoordinator.wallBirthSupportsCompete(
        rawCertified,
        birthEligible,
      ),
      isFalse,
    );
    expect(rawCertified.incumbent, isTrue);
    expect(result.wallDecision?.selectedCandidateIds, const ['legacy__wall_0']);
    expect(rawCertified.strict?.accepted, 10);
    expect(rawCertified.birthSupportXyz, hasLength(24));
    expect(
      [
        for (
          var offset = 0;
          offset < rawCertified.birthSupportXyz!.length;
          offset += 3
        )
          rawCertified.birthSupportXyz![offset],
      ],
      everyElement(1),
      reason: 'strict-only coordinates must not overwrite base birth support',
    );
  });
}
