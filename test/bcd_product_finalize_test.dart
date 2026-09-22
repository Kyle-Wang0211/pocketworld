import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/bcd_detector_free_scheduler.dart';
import 'package:pocketworld_flutter/capture/bcd_finalize_coordinator.dart';
import 'package:pocketworld_flutter/capture/bcd_finalize_input_builder.dart';
import 'package:pocketworld_flutter/capture/bcd_product_finalize.dart';
import 'package:pocketworld_flutter/capture/bcd_structural_quality_runner.dart';
import 'package:pocketworld_flutter/capture/sfm_live_recon.dart';
import 'package:pocketworld_flutter/structural_planesweep_ffi.dart';

class _StructuralRunner implements BcdProductStructuralRunner {
  _StructuralRunner(this.result, {this.failure});

  final BcdStructuralQualityResult result;
  final Object? failure;
  Float32List? receivedSparseXyz;

  @override
  BcdStructuralQualityResult run({
    required Float32List sparseXyz,
    required List<BcdPlaneSweepView> registeredViews,
    BcdKnownFloorPlane? knownFloorPlane,
  }) {
    receivedSparseXyz = Float32List.fromList(sparseXyz);
    if (failure != null) throw failure!;
    return result;
  }
}

Matcher closeToList(List<num> expected, double delta) =>
    predicate<Object?>((actual) {
      if (actual is! Iterable<num>) return false;
      final values = actual.toList(growable: false);
      if (values.length != expected.length) return false;
      for (var index = 0; index < values.length; index++) {
        if ((values[index] - expected[index]).abs() > delta) return false;
      }
      return true;
    }, 'numeric list within $delta of $expected');

class _TestFullScenePlan implements BcdProductDetectorFreeFullScenePlan {
  _TestFullScenePlan({
    required this.metricSparseXyz,
    required this.selectedFloor,
    required this.certifiedWalls,
  });

  final Float32List metricSparseXyz;
  final StructuralFloorDomain selectedFloor;
  final List<StructuralWall> certifiedWalls;
}

typedef _BuildPlan =
    BcdProductDetectorFreeFullScenePlan? Function(
      BcdFinalizeInputBundle inputs,
      StructuralFloorDomain selectedFloor,
      List<StructuralWall> certifiedWalls,
    );

class _PlanFactory implements BcdProductDetectorFreeFullScenePlanFactory {
  _PlanFactory(this.callback);

  final _BuildPlan callback;

  @override
  BcdProductDetectorFreeFullScenePlan? build({
    required BcdFinalizeInputBundle inputs,
    required StructuralFloorDomain selectedFloor,
    required List<StructuralWall> certifiedWalls,
  }) => callback(inputs, selectedFloor, certifiedWalls);
}

class _DetectorFreeRunner implements BcdProductDetectorFreeFullSceneRunner {
  _DetectorFreeRunner(this.result, {this.failure});

  final BcdProductDetectorFreeFullSceneExecution result;
  final Object? failure;
  BcdProductDetectorFreeFullScenePlan? receivedPlan;

  @override
  BcdProductDetectorFreeFullSceneExecution run(
    BcdProductDetectorFreeFullScenePlan plan,
  ) {
    receivedPlan = plan;
    if (failure != null) throw failure!;
    return result;
  }
}

class _MutatingStructuralRunner implements BcdProductStructuralRunner {
  @override
  BcdStructuralQualityResult run({
    required Float32List sparseXyz,
    required List<BcdPlaneSweepView> registeredViews,
    BcdKnownFloorPlane? knownFloorPlane,
  }) {
    sparseXyz[0] = 999;
    throw StateError('mutating B failed');
  }
}

class _MutatingDetectorFreeRunner
    implements BcdProductDetectorFreeFullSceneRunner {
  @override
  BcdProductDetectorFreeFullSceneExecution run(
    BcdProductDetectorFreeFullScenePlan plan,
  ) {
    final testPlan = plan as _TestFullScenePlan;
    testPlan.metricSparseXyz[0] = 999;
    throw StateError('mutating D failed');
  }
}

class _FiniteMutatingDetectorFreeRunner
    implements BcdProductDetectorFreeFullSceneRunner {
  _FiniteMutatingDetectorFreeRunner(this.result);

  final BcdProductDetectorFreeFullSceneExecution result;

  @override
  BcdProductDetectorFreeFullSceneExecution run(
    BcdProductDetectorFreeFullScenePlan plan,
  ) {
    final testPlan = plan as _TestFullScenePlan;
    testPlan.selectedFloor.normal[0] = 0.25;
    testPlan.certifiedWalls.first.normal[0] = 0.75;
    testPlan.metricSparseXyz[0] += 0.5;
    return result;
  }
}

void main() {
  late Directory grayDirectory;
  const solvedCenters = <int, List<double>>{
    1: <double>[0, 0, 0],
    2: <double>[1, 0, 0],
    3: <double>[0, 1, 0],
    4: <double>[0.2, 0.3, 1],
  };
  const metricScale = 2.0;
  const metricTranslation = <double>[3, -1, 0.5];

  setUpAll(() async {
    grayDirectory = await Directory.systemTemp.createTemp(
      'pocketworld-bcd-product-finalize-',
    );
    for (final id in solvedCenters.keys) {
      await File(
        '${grayDirectory.path}/frame-$id.gray',
      ).writeAsBytes(Uint8List(320 * 240), flush: true);
    }
  });

  tearDownAll(() async {
    if (await grayDirectory.exists()) {
      await grayDirectory.delete(recursive: true);
    }
  });

  StructuralFloorDomain floor({bool certified = true}) => StructuralFloorDomain(
    certified: certified,
    normal: <double>[0, 1, 0],
    basisU: <double>[1, 0, 0],
    basisV: <double>[0, 0, 1],
    planeValue: 0,
    boundsU: <double>[-2, 2],
    boundsV: <double>[-2, 2],
  );

  StructuralWall wall({bool certified = true}) => StructuralWall(
    index: 0,
    thetaDeg: 0,
    certified: certified,
    supportPoints35mm: 20,
    coverageCells10cm: 10,
    domainPoints: 40,
    supportPoints20mm: <int>[12, 8],
    supportCells10cm: <int>[7, 3],
    normal: <double>[1, 0, 0],
    basisU: <double>[0, 0, 1],
    basisV: <double>[0, 1, 0],
    planeValue: 2,
    boundsU: <double>[-1, 1],
    boundsHeight: <double>[0, 2.5],
    score: 0.9,
    supportProminenceVs5cm: 1.5,
    coverageProminenceVs5cm: 1.4,
  );

  List<double> poseRow(int id) {
    final center = solvedCenters[id]!;
    return <double>[
      id.toDouble(),
      1,
      1,
      0,
      0,
      0,
      -center[0],
      -center[1],
      -center[2],
    ];
  }

  SfmLiveSnapshot snapshot({
    Float32List? xyz,
    Uint8List? rgb,
    bool refined = true,
  }) => SfmLiveSnapshot(
    xyz: xyz ?? Float32List.fromList(const [1, 2, 3, 4, 5, 6]),
    rgb: rgb ?? Uint8List.fromList(const [10, 20, 30, 40, 50, 60]),
    posesPacked: Float64List.fromList(<double>[
      for (final id in solvedCenters.keys) ...poseRow(id),
    ]),
    summary: const {'n_registered': 3, 'result': 'ok'},
    refined: refined,
    obsOffsets: Int32List.fromList(const [0, 0, 0]),
    obsFrameIds: Int32List(0),
    obsXY: Float32List(0),
  );

  SfmFedFrameMeta meta(int id) => SfmFedFrameMeta(
    jpegPath: '/capture/frame_$id.jpg',
    imageW: 640,
    imageH: 480,
    grayW: 320,
    grayH: 240,
    fx: 200,
    fy: 200,
    cx: 160,
    cy: 120,
    arkitQuatWxyz: const [0, 1, 0, 0],
    arkitCameraCenterWorld: <double>[
      for (var axis = 0; axis < 3; axis++)
        metricScale * solvedCenters[id]![axis] + metricTranslation[axis],
    ],
  );

  Map<int, SfmFedFrameMeta> metadata() => {
    for (final id in solvedCenters.keys) id: meta(id),
  };

  Map<int, String> grayPaths() => {
    for (final id in solvedCenters.keys)
      id: '${grayDirectory.path}/frame-$id.gray',
  };

  List<SfmDurableFedFrameInput> durableInputs() => [
    for (final id in solvedCenters.keys)
      SfmDurableFedFrameInput(
        sequence: id,
        frameId: id,
        grayPath: grayPaths()[id]!,
        meta: metadata()[id]!,
      ),
  ];

  BcdStructuralBirthResult structuralBirth({double firstX = 17}) =>
      BcdStructuralBirthResult(
        cloud: BcdPointCloud(
          xyz: Float32List.fromList([firstX, 15, 18.5]),
          rgb: Uint8List.fromList(const [70, 80, 90]),
        ),
        acceptedCandidateIndices: const [0],
        evidence: const [],
      );

  BcdStructuralQualityResult structuralResult({
    bool passed = true,
    double firstBirthX = 17,
    BcdStructuralBirthResult? birthOverride,
    BcdStructuralBirthResult? publicationBirthOverride,
    List<StructuralWall>? certifiedWalls,
    bool floorCertified = true,
    bool floorDecisive = true,
    int floorWinnerProposalIndex = 0,
    BcdFloorSelectionStage? floorStage,
    bool wallDecisionPresent = true,
    bool wallDecisionComplete = true,
    int wallUnresolvedFamilyCount = 0,
    bool wallBirthsPresent = true,
  }) {
    final birth = birthOverride ?? structuralBirth(firstX: firstBirthX);
    final selectedFloor = passed ? floor(certified: floorCertified) : null;
    return BcdStructuralQualityResult(
      qualityPassed: passed,
      rejectedReason: passed ? null : 'ambiguous floor',
      floorDecision: BcdFloorSelectionDecision(
        decisive: passed && floorDecisive,
        stage:
            floorStage ??
            (passed && floorDecisive
                ? BcdFloorSelectionStage.coarse10cm
                : BcdFloorSelectionStage.rejectedAmbiguous),
        winnerProposalIndex: passed && floorDecisive
            ? floorWinnerProposalIndex
            : null,
        requiredFineProposalIndices: const [],
      ),
      selectedFloorProposal: null,
      selectedFloor: selectedFloor,
      wallDecision: passed && wallDecisionPresent
          ? BcdWallSelectionDecision(
              selectedCandidateIds: const ['wall-0'],
              requiredStrictCandidateIds: wallDecisionComplete
                  ? const []
                  : const ['wall-0'],
              unresolvedFamilyCount: wallDecisionComplete
                  ? wallUnresolvedFamilyCount
                  : 1,
            )
          : null,
      certifiedWalls:
          certifiedWalls ?? (passed ? <StructuralWall>[wall()] : const []),
      floorBirths: const [],
      wallBirths: passed && wallBirthsPresent ? [birth] : const [],
      structuralBirths: passed ? [publicationBirthOverride ?? birth] : const [],
    );
  }

  BcdProductDetectorFreeFullSceneExecution detectorExecution({
    bool empty = false,
    double firstBirthX = 23,
    BcdPointCloud? cloudOverride,
    List<BcdProductDetectorFreeReferenceSummary>? references,
    BcdDetectorFreeDepthCacheStats cacheStats =
        const BcdDetectorFreeDepthCacheStats(
          hits: 0,
          misses: 0,
          lruEvictions: 0,
          lastUseEvictions: 0,
          currentEntries: 0,
          currentBytes: 0,
          peakBytes: 0,
        ),
  }) {
    final cloud =
        cloudOverride ??
        (empty
            ? BcdPointCloud.empty()
            : BcdPointCloud(
                xyz: Float32List.fromList([firstBirthX, 21, 24.5]),
                rgb: Uint8List.fromList(const [100, 110, 120]),
              ));
    return BcdProductDetectorFreeFullSceneExecution(
      mergedMetricBirthCloud: cloud,
      references:
          references ??
          <BcdProductDetectorFreeReferenceSummary>[
            BcdProductDetectorFreeReferenceSummary(
              referenceFrameId: 10,
              status: BcdProductDetectorFreeReferenceStatus.certified,
              failedFoldMask: 0,
              preCertificateBirthCount: cloud.pointCount,
              blockedBirthCount: 0,
              finalBirthCount: cloud.pointCount,
            ),
          ],
      cacheStats: cacheStats,
    );
  }

  BcdProductDetectorFreeFullScenePlanFactory detectorPlanFactory() =>
      _PlanFactory(
        (inputs, selectedFloor, certifiedWalls) => _TestFullScenePlan(
          metricSparseXyz: inputs.metricSparseXyz,
          selectedFloor: selectedFloor,
          certifiedWalls: certifiedWalls,
        ),
      );

  test(
    'B appends only births and preserves sparse bytes, poses, and summary',
    () {
      final source = snapshot();
      final sourceXyzBytes = Uint8List.fromList(
        source.xyz.buffer.asUint8List(
          source.xyz.offsetInBytes,
          source.xyz.lengthInBytes,
        ),
      );
      final sourceRgbBytes = Uint8List.fromList(source.rgb);
      final structuralRunner = _StructuralRunner(structuralResult());
      final result = BcdProductFinalize(
        structuralRunner: structuralRunner,
        detectorFreeRunner: _DetectorFreeRunner(detectorExecution(empty: true)),
      ).run(snapshot: source, durableFedFrames: durableInputs());

      expect(result.publication, BcdProductPublication.structural);
      expect(result.finalize.originalPointCount, 2);
      expect(result.finalize.structuralBirthCount, 1);
      expect(result.finalize.detectorFreeBirthCount, 0);
      expect(result.inputs!.sim3.scale, closeTo(metricScale, 2e-6));
      expect(
        result.inputs!.sim3.translation,
        closeToList(metricTranslation, 2e-6),
      );
      expect(
        structuralRunner.receivedSparseXyz,
        closeToList(const [5, 3, 6.5, 11, 9, 12.5], 2e-6),
        reason: 'B must consume metric Sim3 sparse XYZ',
      );
      expect(result.xyz, orderedEquals(const [1, 2, 3, 4, 5, 6, 7, 8, 9]));
      expect(
        result.rgb,
        orderedEquals(const [10, 20, 30, 40, 50, 60, 70, 80, 90]),
      );
      expect(
        result.xyz.buffer.asUint8List(
          result.xyz.offsetInBytes,
          sourceXyzBytes.length,
        ),
        orderedEquals(sourceXyzBytes),
      );
      expect(
        result.rgb.buffer.asUint8List(
          result.rgb.offsetInBytes,
          sourceRgbBytes.length,
        ),
        orderedEquals(sourceRgbBytes),
      );
      expect(identical(result.posesPacked, source.posesPacked), isTrue);
      expect(identical(result.summary, source.summary), isTrue);
      expect(result.refined, source.refined);
    },
  );

  test(
    'B rejection and B exception return the exact original sparse objects',
    () {
      for (final runner in [
        _StructuralRunner(structuralResult(passed: false)),
        _StructuralRunner(structuralResult(), failure: StateError('B failed')),
      ]) {
        final source = snapshot();
        final result =
            BcdProductFinalize(
              structuralRunner: runner,
              detectorFreeRunner: _DetectorFreeRunner(detectorExecution()),
            ).run(
              snapshot: source,
              durableFedFrames: durableInputs(),
              detectorFreePlanFactory: detectorPlanFactory(),
            );
        expect(result.publication, BcdProductPublication.sparseOnly);
        expect(identical(result.xyz, source.xyz), isTrue);
        expect(identical(result.rgb, source.rgb), isTrue);
        expect(result.finalize.structuralBirthCount, 0);
        expect(result.finalize.detectorFreeBirthCount, 0);
        expect(result.structuralFailure, isNotNull);
      }
    },
  );

  test('D full-scene plan factory is lazy and never runs before B passes', () {
    var factoryCalls = 0;
    final source = snapshot();
    final result =
        BcdProductFinalize(
          structuralRunner: _StructuralRunner(structuralResult(passed: false)),
          detectorFreeRunner: _DetectorFreeRunner(detectorExecution()),
        ).run(
          snapshot: source,
          durableFedFrames: durableInputs(),
          detectorFreePlanFactory: _PlanFactory((
            inputs,
            selectedFloor,
            certifiedWalls,
          ) {
            factoryCalls++;
            throw StateError('factory must not run');
          }),
        );

    expect(factoryCalls, 0);
    expect(result.publication, BcdProductPublication.sparseOnly);
    expect(result.structuralFailure, contains('ambiguous floor'));
  });

  test('D never runs on a self-declared but incomplete B certificate', () {
    final invalid = <BcdStructuralQualityResult>[
      structuralResult(floorCertified: false),
      structuralResult(floorDecisive: false),
      structuralResult(floorWinnerProposalIndex: -1),
      structuralResult(floorStage: BcdFloorSelectionStage.rejectedAmbiguous),
      structuralResult(wallDecisionPresent: false),
      structuralResult(wallDecisionComplete: false),
      structuralResult(certifiedWalls: const []),
      structuralResult(
        certifiedWalls: <StructuralWall>[wall(certified: false)],
      ),
      structuralResult(wallBirthsPresent: false),
      structuralResult(publicationBirthOverride: structuralBirth(firstX: 99)),
    ];

    for (final structural in invalid) {
      var factoryCalls = 0;
      final source = snapshot();
      final result =
          BcdProductFinalize(
            structuralRunner: _StructuralRunner(structural),
            detectorFreeRunner: _DetectorFreeRunner(detectorExecution()),
          ).run(
            snapshot: source,
            durableFedFrames: durableInputs(),
            detectorFreePlanFactory: _PlanFactory((
              inputs,
              selectedFloor,
              certifiedWalls,
            ) {
              factoryCalls++;
              return _TestFullScenePlan(
                metricSparseXyz: inputs.metricSparseXyz,
                selectedFloor: selectedFloor,
                certifiedWalls: certifiedWalls,
              );
            }),
          );

      expect(factoryCalls, 0);
      expect(result.publication, BcdProductPublication.sparseOnly);
      expect(identical(result.xyz, source.xyz), isTrue);
      expect(result.structuralFailure, isNotNull);
    }
  });

  test('weak unresolved wall families do not block a certified wall owner', () {
    var factoryCalls = 0;
    final result =
        BcdProductFinalize(
          structuralRunner: _StructuralRunner(
            structuralResult(wallUnresolvedFamilyCount: 3),
          ),
          detectorFreeRunner: _DetectorFreeRunner(detectorExecution()),
        ).run(
          snapshot: snapshot(),
          durableFedFrames: durableInputs(),
          detectorFreePlanFactory: _PlanFactory((
            inputs,
            selectedFloor,
            certifiedWalls,
          ) {
            factoryCalls++;
            return _TestFullScenePlan(
              metricSparseXyz: inputs.metricSparseXyz,
              selectedFloor: selectedFloor,
              certifiedWalls: certifiedWalls,
            );
          }),
        );

    expect(factoryCalls, 1);
    expect(result.publication, BcdProductPublication.structuralAndDetectorFree);
    expect(result.finalize.detectorFreeBirthCount, 1);
  });

  test('D appends after B without changing the sparse/B prefix', () {
    final source = snapshot();
    final detectorRunner = _DetectorFreeRunner(detectorExecution());
    final result =
        BcdProductFinalize(
          structuralRunner: _StructuralRunner(structuralResult()),
          detectorFreeRunner: detectorRunner,
        ).run(
          snapshot: source,
          durableFedFrames: durableInputs(),
          detectorFreePlanFactory: detectorPlanFactory(),
        );

    expect(result.publication, BcdProductPublication.structuralAndDetectorFree);
    expect(result.finalize.structuralBirthCount, 1);
    expect(result.finalize.detectorFreeBirthCount, 1);
    expect(
      (detectorRunner.receivedPlan! as _TestFullScenePlan).metricSparseXyz,
      closeToList(const [5, 3, 6.5, 11, 9, 12.5], 2e-6),
      reason: 'D ownership and depth gating must stay in metric gauge',
    );
    expect(
      result.xyz,
      orderedEquals(const [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]),
    );
    final frozenXyz = Float32List.fromList(const [1, 2, 3, 4, 5, 6, 7, 8, 9]);
    expect(
      result.xyz.buffer.asUint8List(
        result.xyz.offsetInBytes,
        frozenXyz.lengthInBytes,
      ),
      orderedEquals(frozenXyz.buffer.asUint8List()),
      reason: 'D must preserve the frozen sparse+B byte prefix',
    );
  });

  test(
    'absent or zero-birth D is a successful structural-only publication',
    () {
      for (final includeRequest in [false, true]) {
        final source = snapshot();
        final result =
            BcdProductFinalize(
              structuralRunner: _StructuralRunner(structuralResult()),
              detectorFreeRunner: _DetectorFreeRunner(
                detectorExecution(empty: true),
              ),
            ).run(
              snapshot: source,
              durableFedFrames: durableInputs(),
              detectorFreePlanFactory: includeRequest
                  ? detectorPlanFactory()
                  : null,
            );
        expect(result.publication, BcdProductPublication.structural);
        expect(result.finalize.structuralBirthCount, 1);
        expect(result.finalize.detectorFreeBirthCount, 0);
        expect(result.detectorFreeFailure, isNull);
      }
    },
  );

  test('D failure retains B and records a zero-birth failure', () {
    final source = snapshot();
    final result =
        BcdProductFinalize(
          structuralRunner: _StructuralRunner(structuralResult()),
          detectorFreeRunner: _DetectorFreeRunner(
            detectorExecution(),
            failure: StateError('unsupported D backend'),
          ),
        ).run(
          snapshot: source,
          durableFedFrames: durableInputs(),
          detectorFreePlanFactory: detectorPlanFactory(),
        );

    expect(result.publication, BcdProductPublication.structural);
    expect(result.finalize.structuralBirthCount, 1);
    expect(result.finalize.detectorFreeBirthCount, 0);
    expect(result.xyz, orderedEquals(const [1, 2, 3, 4, 5, 6, 7, 8, 9]));
    expect(result.detectorFreeFailure, contains('unsupported D backend'));
    expect(result.inputs, isNull);
    expect(result.structural, isNull);
  });

  test('D factory failure retains B without exposing live B aliases', () {
    final source = snapshot();
    final bResult = structuralResult();
    final result =
        BcdProductFinalize(
          structuralRunner: _StructuralRunner(bResult),
          detectorFreeRunner: _DetectorFreeRunner(detectorExecution()),
        ).run(
          snapshot: source,
          durableFedFrames: durableInputs(),
          detectorFreePlanFactory: _PlanFactory((
            inputs,
            selectedFloor,
            certifiedWalls,
          ) {
            selectedFloor.normal[0] = 0.125;
            inputs.metricSparseXyz[0] += 0.25;
            throw StateError('factory failed after mutation');
          }),
        );

    expect(result.publication, BcdProductPublication.structural);
    expect(result.xyz, orderedEquals(const [1, 2, 3, 4, 5, 6, 7, 8, 9]));
    expect(result.inputs, isNull);
    expect(result.structural, isNull);
    expect(result.detectorFreeFailure, contains('factory failed'));
    expect(bResult.selectedFloor!.normal, orderedEquals(const [0, 1, 0]));
  });

  test('D cannot mutate an aliased source sparse buffer', () {
    final source = snapshot();
    final result =
        BcdProductFinalize(
          structuralRunner: _StructuralRunner(structuralResult()),
          detectorFreeRunner: _MutatingDetectorFreeRunner(),
        ).run(
          snapshot: source,
          durableFedFrames: durableInputs(),
          detectorFreePlanFactory: detectorPlanFactory(),
        );

    expect(source.xyz, orderedEquals(const [1, 2, 3, 4, 5, 6]));
    expect(result.xyz, orderedEquals(const [1, 2, 3, 4, 5, 6, 7, 8, 9]));
    expect(result.finalize.detectorFreeBirthCount, 0);
    expect(result.detectorFreeFailure, contains('mutating D failed'));
  });

  test('B cannot mutate the baseline sparse buffer before failing', () {
    final source = snapshot();
    final result = BcdProductFinalize(
      structuralRunner: _MutatingStructuralRunner(),
      detectorFreeRunner: _DetectorFreeRunner(detectorExecution()),
    ).run(snapshot: source, durableFedFrames: durableInputs());

    expect(result.publication, BcdProductPublication.sparseOnly);
    expect(identical(result.xyz, source.xyz), isTrue);
    expect(source.xyz, orderedEquals(const [1, 2, 3, 4, 5, 6]));
    expect(result.structuralFailure, contains('mutating B failed'));
  });

  test('non-finite original or B birth fails closed to sparse only', () {
    final nonFiniteSource = snapshot(
      xyz: Float32List.fromList(const [double.nan, 2, 3, 4, 5, 6]),
    );
    final originalRejected = BcdProductFinalize(
      structuralRunner: _StructuralRunner(structuralResult()),
      detectorFreeRunner: _DetectorFreeRunner(detectorExecution()),
    ).run(snapshot: nonFiniteSource, durableFedFrames: durableInputs());
    expect(originalRejected.publication, BcdProductPublication.sparseOnly);
    expect(identical(originalRejected.xyz, nonFiniteSource.xyz), isTrue);
    expect(originalRejected.structuralFailure, contains('non-finite'));

    final source = snapshot();
    final birthRejected = BcdProductFinalize(
      structuralRunner: _StructuralRunner(
        structuralResult(firstBirthX: double.infinity),
      ),
      detectorFreeRunner: _DetectorFreeRunner(detectorExecution()),
    ).run(snapshot: source, durableFedFrames: durableInputs());
    expect(birthRejected.publication, BcdProductPublication.sparseOnly);
    expect(identical(birthRejected.xyz, source.xyz), isTrue);
    expect(birthRejected.structuralFailure, contains('non-finite'));
  });

  test('non-finite D birth retains the frozen sparse+B publication', () {
    final source = snapshot();
    final corrupted = detectorExecution();
    corrupted.mergedMetricBirthCloud.xyz[0] = double.nan;
    final result =
        BcdProductFinalize(
          structuralRunner: _StructuralRunner(structuralResult()),
          detectorFreeRunner: _DetectorFreeRunner(corrupted),
        ).run(
          snapshot: source,
          durableFedFrames: durableInputs(),
          detectorFreePlanFactory: detectorPlanFactory(),
        );

    expect(result.publication, BcdProductPublication.structural);
    expect(result.xyz, orderedEquals(const [1, 2, 3, 4, 5, 6, 7, 8, 9]));
    expect(result.finalize.detectorFreeBirthCount, 0);
    expect(result.detectorFreeFailure, contains('non-finite'));
  });

  test(
    'D preserves multi-reference order, certificate states, and cache stats',
    () {
      final source = snapshot();
      final execution = detectorExecution(
        references: const <BcdProductDetectorFreeReferenceSummary>[
          BcdProductDetectorFreeReferenceSummary(
            referenceFrameId: 10,
            status: BcdProductDetectorFreeReferenceStatus.certified,
            failedFoldMask: 0,
            preCertificateBirthCount: 1,
            blockedBirthCount: 0,
            finalBirthCount: 1,
          ),
          BcdProductDetectorFreeReferenceSummary(
            referenceFrameId: 20,
            status: BcdProductDetectorFreeReferenceStatus.skipped,
            failedFoldMask: 0,
            preCertificateBirthCount: 0,
            blockedBirthCount: 0,
            finalBirthCount: 0,
            skipReason: 'missingReferenceRgb',
          ),
          BcdProductDetectorFreeReferenceSummary(
            referenceFrameId: 30,
            status: BcdProductDetectorFreeReferenceStatus.blocked,
            failedFoldMask: 2,
            preCertificateBirthCount: 2,
            blockedBirthCount: 2,
            finalBirthCount: 0,
          ),
        ],
        cacheStats: const BcdDetectorFreeDepthCacheStats(
          hits: 7,
          misses: 11,
          lruEvictions: 2,
          lastUseEvictions: 5,
          currentEntries: 0,
          currentBytes: 0,
          peakBytes: 4096,
        ),
      );
      final result =
          BcdProductFinalize(
            structuralRunner: _StructuralRunner(structuralResult()),
            detectorFreeRunner: _DetectorFreeRunner(execution),
          ).run(
            snapshot: source,
            durableFedFrames: durableInputs(),
            detectorFreePlanFactory: detectorPlanFactory(),
          );

      expect(
        result.publication,
        BcdProductPublication.structuralAndDetectorFree,
      );
      expect(
        result.detectorFreeExecution!.references.map(
          (item) => item.referenceFrameId,
        ),
        orderedEquals(const [10, 20, 30]),
      );
      expect(result.detectorFreeExecution!.certifiedReferenceCount, 1);
      expect(result.detectorFreeExecution!.skippedReferenceCount, 1);
      expect(result.detectorFreeExecution!.blockedReferenceCount, 1);
      expect(result.detectorFreeExecution!.cacheStats.hits, 7);
      expect(result.detectorFreeExecution!.cacheStats.misses, 11);
      expect(result.detectorFreeExecution!.cacheStats.peakBytes, 4096);
    },
  );

  test('finite factory mutation cannot self-authorize D ownership', () {
    final source = snapshot();
    final bResult = structuralResult(certifiedWalls: <StructuralWall>[wall()]);
    final result =
        BcdProductFinalize(
          structuralRunner: _StructuralRunner(bResult),
          detectorFreeRunner: _DetectorFreeRunner(detectorExecution()),
        ).run(
          snapshot: source,
          durableFedFrames: durableInputs(),
          detectorFreePlanFactory: _PlanFactory((
            inputs,
            selectedFloor,
            certifiedWalls,
          ) {
            selectedFloor.normal[0] = 0.125;
            certifiedWalls.first.normal[0] = 0.625;
            return _TestFullScenePlan(
              metricSparseXyz: inputs.metricSparseXyz,
              selectedFloor: selectedFloor,
              certifiedWalls: certifiedWalls,
            );
          }),
        );

    expect(result.publication, BcdProductPublication.structural);
    expect(result.finalize.detectorFreeBirthCount, 0);
    expect(result.xyz, orderedEquals(const [1, 2, 3, 4, 5, 6, 7, 8, 9]));
    expect(bResult.selectedFloor!.normal, orderedEquals(const [0, 1, 0]));
    expect(bResult.certifiedWalls.first.normal, orderedEquals(const [1, 0, 0]));
    expect(result.detectorFreeFailure, contains('frozen B metric contract'));
    expect(result.inputs, isNull);
    expect(result.structural, isNull);
  });

  test('finite runner mutation cannot alter frozen B publication', () {
    final source = snapshot();
    final bResult = structuralResult(certifiedWalls: <StructuralWall>[wall()]);
    final result =
        BcdProductFinalize(
          structuralRunner: _StructuralRunner(bResult),
          detectorFreeRunner: _FiniteMutatingDetectorFreeRunner(
            detectorExecution(),
          ),
        ).run(
          snapshot: source,
          durableFedFrames: durableInputs(),
          detectorFreePlanFactory: detectorPlanFactory(),
        );

    expect(result.publication, BcdProductPublication.structural);
    expect(result.finalize.detectorFreeBirthCount, 0);
    expect(result.xyz, orderedEquals(const [1, 2, 3, 4, 5, 6, 7, 8, 9]));
    expect(bResult.selectedFloor!.normal, orderedEquals(const [0, 1, 0]));
    expect(bResult.certifiedWalls.first.normal, orderedEquals(const [1, 0, 0]));
    expect(result.detectorFreeFailure, contains('frozen B metric contract'));
    expect(result.inputs, isNull);
    expect(result.structural, isNull);
  });

  test('captured B birth alias cannot change the frozen publication', () {
    final source = snapshot();
    final bResult = structuralResult(certifiedWalls: <StructuralWall>[wall()]);
    final result =
        BcdProductFinalize(
          structuralRunner: _StructuralRunner(bResult),
          detectorFreeRunner: _DetectorFreeRunner(detectorExecution()),
        ).run(
          snapshot: source,
          durableFedFrames: durableInputs(),
          detectorFreePlanFactory: _PlanFactory((
            inputs,
            selectedFloor,
            certifiedWalls,
          ) {
            bResult.structuralBirths.first.cloud.xyz[0] += 0.25;
            return _TestFullScenePlan(
              metricSparseXyz: inputs.metricSparseXyz,
              selectedFloor: selectedFloor,
              certifiedWalls: certifiedWalls,
            );
          }),
        );

    expect(result.publication, BcdProductPublication.structural);
    expect(result.finalize.detectorFreeBirthCount, 0);
    expect(result.xyz, orderedEquals(const [1, 2, 3, 4, 5, 6, 7, 8, 9]));
    expect(result.detectorFreeFailure, contains('frozen B metric contract'));
  });

  test('malformed original XYZ or RGB length returns exact sparse objects', () {
    for (final source in <SfmLiveSnapshot>[
      snapshot(xyz: Float32List(4), rgb: Uint8List(4)),
      snapshot(xyz: Float32List(6), rgb: Uint8List(3)),
    ]) {
      final result = BcdProductFinalize(
        structuralRunner: _StructuralRunner(structuralResult()),
        detectorFreeRunner: _DetectorFreeRunner(detectorExecution()),
      ).run(snapshot: source, durableFedFrames: durableInputs());

      expect(result.publication, BcdProductPublication.sparseOnly);
      expect(identical(result.xyz, source.xyz), isTrue);
      expect(identical(result.rgb, source.rgb), isTrue);
      expect(result.structuralFailure, contains('malformed'));
    }
  });

  test('malformed B birth length fails closed to original sparse', () {
    final source = snapshot();
    final malformed = BcdStructuralBirthResult(
      cloud: BcdPointCloud(xyz: Float32List(4), rgb: Uint8List(4)),
      acceptedCandidateIndices: const [0],
      evidence: const [],
    );
    final result = BcdProductFinalize(
      structuralRunner: _StructuralRunner(
        structuralResult(birthOverride: malformed),
      ),
      detectorFreeRunner: _DetectorFreeRunner(detectorExecution()),
    ).run(snapshot: source, durableFedFrames: durableInputs());

    expect(result.publication, BcdProductPublication.sparseOnly);
    expect(identical(result.xyz, source.xyz), isTrue);
    expect(identical(result.rgb, source.rgb), isTrue);
    expect(result.structuralFailure, contains('malformed'));
  });

  test('malformed D batch cannot cross the runner boundary', () {
    expect(
      () => detectorExecution(
        cloudOverride: BcdPointCloud(xyz: Float32List(3), rgb: Uint8List(2)),
      ),
      throwsStateError,
    );
  });

  test(
    'all skipped references publish zero D births with explicit evidence',
    () {
      final execution = detectorExecution(
        empty: true,
        references: const <BcdProductDetectorFreeReferenceSummary>[
          BcdProductDetectorFreeReferenceSummary(
            referenceFrameId: 10,
            status: BcdProductDetectorFreeReferenceStatus.skipped,
            failedFoldMask: 0,
            preCertificateBirthCount: 0,
            blockedBirthCount: 0,
            finalBirthCount: 0,
            skipReason: 'missingReferenceRgb',
          ),
          BcdProductDetectorFreeReferenceSummary(
            referenceFrameId: 20,
            status: BcdProductDetectorFreeReferenceStatus.skipped,
            failedFoldMask: 0,
            preCertificateBirthCount: 0,
            blockedBirthCount: 0,
            finalBirthCount: 0,
            skipReason: 'insufficientPoseOverlap',
          ),
        ],
      );
      final result =
          BcdProductFinalize(
            structuralRunner: _StructuralRunner(structuralResult()),
            detectorFreeRunner: _DetectorFreeRunner(execution),
          ).run(
            snapshot: snapshot(),
            durableFedFrames: durableInputs(),
            detectorFreePlanFactory: detectorPlanFactory(),
          );

      expect(result.publication, BcdProductPublication.structural);
      expect(result.finalize.detectorFreeBirthCount, 0);
      expect(result.detectorFreeExecution!.skippedReferenceCount, 2);
      expect(result.detectorFreeFailure, isNull);
    },
  );

  test('failed reference certificate can never publish a D point', () {
    final execution = detectorExecution(
      empty: true,
      references: const <BcdProductDetectorFreeReferenceSummary>[
        BcdProductDetectorFreeReferenceSummary(
          referenceFrameId: 10,
          status: BcdProductDetectorFreeReferenceStatus.blocked,
          failedFoldMask: 4,
          preCertificateBirthCount: 3,
          blockedBirthCount: 3,
          finalBirthCount: 0,
        ),
      ],
    );
    final result =
        BcdProductFinalize(
          structuralRunner: _StructuralRunner(structuralResult()),
          detectorFreeRunner: _DetectorFreeRunner(execution),
        ).run(
          snapshot: snapshot(),
          durableFedFrames: durableInputs(),
          detectorFreePlanFactory: detectorPlanFactory(),
        );

    expect(result.publication, BcdProductPublication.structural);
    expect(result.detectorFreeExecution!.blockedReferenceCount, 1);
    expect(result.detectorFreeExecution!.blockedBirthCount, 3);
    expect(result.finalize.detectorFreeBirthCount, 0);
  });

  test(
    '299-reference batch preserves stable order without singular fallback',
    () {
      final references = <BcdProductDetectorFreeReferenceSummary>[
        for (var id = 1; id < 299; id++)
          BcdProductDetectorFreeReferenceSummary(
            referenceFrameId: id,
            status: BcdProductDetectorFreeReferenceStatus.skipped,
            failedFoldMask: 0,
            preCertificateBirthCount: 0,
            blockedBirthCount: 0,
            finalBirthCount: 0,
            skipReason: 'noCertifiedWork',
          ),
        const BcdProductDetectorFreeReferenceSummary(
          referenceFrameId: 299,
          status: BcdProductDetectorFreeReferenceStatus.certified,
          failedFoldMask: 0,
          preCertificateBirthCount: 1,
          blockedBirthCount: 0,
          finalBirthCount: 1,
        ),
      ];
      final execution = detectorExecution(references: references);
      final result =
          BcdProductFinalize(
            structuralRunner: _StructuralRunner(structuralResult()),
            detectorFreeRunner: _DetectorFreeRunner(execution),
          ).run(
            snapshot: snapshot(),
            durableFedFrames: durableInputs(),
            detectorFreePlanFactory: detectorPlanFactory(),
          );

      expect(result.detectorFreeExecution!.references, hasLength(299));
      expect(
        result.detectorFreeExecution!.references.first.referenceFrameId,
        1,
      );
      expect(
        result.detectorFreeExecution!.references.last.referenceFrameId,
        299,
      );
      expect(result.finalize.detectorFreeBirthCount, 1);
    },
  );

  test('default native runner rejects every non-native plan adapter', () {
    final result =
        BcdProductFinalize(
          structuralRunner: _StructuralRunner(structuralResult()),
        ).run(
          snapshot: snapshot(),
          durableFedFrames: durableInputs(),
          detectorFreePlanFactory: detectorPlanFactory(),
        );

    expect(result.publication, BcdProductPublication.structural);
    expect(result.finalize.detectorFreeBirthCount, 0);
    expect(result.detectorFreeFailure, contains('native full-scene plan'));
  });

  test('refined state propagates unchanged on fail-closed output', () {
    final source = snapshot(refined: false);
    final result = BcdProductFinalize(
      structuralRunner: _StructuralRunner(structuralResult()),
      detectorFreeRunner: _DetectorFreeRunner(detectorExecution()),
    ).run(snapshot: source, durableFedFrames: durableInputs());

    expect(result.publication, BcdProductPublication.sparseOnly);
    expect(result.refined, isFalse);
    expect(identical(result.posesPacked, source.posesPacked), isTrue);
    expect(identical(result.summary, source.summary), isTrue);
  });
}
