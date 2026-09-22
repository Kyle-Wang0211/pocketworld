import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/bcd_detector_free_job_builder.dart';
import 'package:pocketworld_flutter/capture/bcd_detector_free_scheduler.dart';
import 'package:pocketworld_flutter/capture/bcd_finalize_coordinator.dart';
import 'package:pocketworld_flutter/capture/bcd_finalize_input_builder.dart';
import 'package:pocketworld_flutter/capture/sfm_live_recon.dart';
import 'package:pocketworld_flutter/detector_free_depth_ffi.dart';
import 'package:pocketworld_flutter/structural_planesweep_ffi.dart';

void main() {
  BcdDetectorFreeDepthJob job({int width = 3, int height = 3}) =>
      BcdDetectorFreeDepthJob(
        options: DetectorFreeDepthOptions(
          imageWidth: width,
          imageHeight: height,
          maxTileWidth: width,
          maxTileHeight: height,
          depthCount: 3,
          sourceCount: 1,
          patchN: 3,
          minimumViews: 1,
          exclusionRadiusSamples: 1,
          minimumStdU8: 1,
          nccMin: 0.5,
          uniqueDepthMargin: 0,
          inverseDepthFirst: 0.5,
          inverseDepthStep: 0.25,
          referenceInverseK: const [1, 0, 0, 0, 1, 0, 0, 0, 1],
        ),
        // Cache bounds are checked before native/job validation. Keeping this
        // empty lets the 4K rejection test prove no giant buffer is allocated.
        grayFrames: width * height <= 128 * 72
            ? Float32List(width * height * 2)
            : Float32List(0),
        sourceProjections: Float32List.fromList(const [
          1,
          0,
          0,
          0,
          0,
          1,
          0,
          0,
          0,
          0,
          1,
          0,
        ]),
        refineOptions: null,
      );

  BcdDetectorFreeDepthMap map(int marker) => BcdDetectorFreeDepthMap(
    width: 3,
    height: 3,
    depthM: Float32List.fromList(List<double>.filled(9, marker.toDouble())),
    accepted: Uint8List(9),
  );

  test('2311 uses with 387 exact repeats solve only 1924 unique jobs', () {
    const unique = 1924;
    const duplicates = 387;
    final uses = <String, int>{
      for (var index = 0; index < unique; index++)
        'job-$index': index < duplicates ? 2 : 1,
    };
    final cache = BcdDetectorFreeDepthCache(
      captureDigest: 'cap-four-scene-fixture',
      backendAbi: 'aether-d-abi-test',
      futureUses: uses,
      maximumEntries: 512,
      maximumBytes: 1024 * 1024,
    );
    addTearDown(cache.dispose);
    var solves = 0;
    final depthJob = job();
    for (var index = 0; index < unique; index++) {
      cache.acquire(
        key: 'job-$index',
        job: depthJob,
        load: () => map(solves++),
      );
    }
    for (var index = 0; index < duplicates; index++) {
      cache.acquire(
        key: 'job-$index',
        job: depthJob,
        load: () => map(solves++),
      );
    }

    expect(unique + duplicates, 2311);
    expect(solves, unique);
    expect(cache.stats.misses, unique);
    expect(cache.stats.hits, duplicates);
    expect(cache.stats.lastUseEvictions, duplicates);
    expect(cache.stats.currentEntries, 0);
    expect(cache.stats.currentBytes, 0);
    expect(cache.stats.peakBytes, lessThanOrEqualTo(1024 * 1024));
  });

  test(
    'LRU hard bound preserves correctness when a repeated entry is evicted',
    () {
      final cache = BcdDetectorFreeDepthCache(
        captureDigest: 'cap-lru',
        backendAbi: 'backend-v1',
        futureUses: const {'a': 2, 'b': 2},
        maximumEntries: 1,
        maximumBytes: 1024,
      );
      addTearDown(cache.dispose);
      var solves = 0;
      final depthJob = job();
      for (final key in const ['a', 'b', 'a', 'b']) {
        cache.acquire(key: key, job: depthJob, load: () => map(++solves));
      }

      expect(solves, 3);
      expect(cache.stats.hits, 1);
      expect(cache.stats.lruEvictions, 1);
      expect(cache.stats.currentBytes, 0);
    },
  );

  test('same text key never crosses capture/backend cache lifecycle', () {
    final first = BcdDetectorFreeDepthCache(
      captureDigest: 'cap-a',
      backendAbi: 'abi-a',
      futureUses: const {'same': 2},
    );
    final second = BcdDetectorFreeDepthCache(
      captureDigest: 'cap-a',
      backendAbi: 'abi-b',
      futureUses: const {'same': 1},
    );
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    var solves = 0;
    final depthJob = job();
    first.acquire(key: 'same', job: depthJob, load: () => map(++solves));
    second.acquire(key: 'same', job: depthJob, load: () => map(++solves));

    expect(solves, 2);
    expect(first.stats.hits, 0);
    expect(second.stats.hits, 0);
  });

  test(
    'oversized 4K materialized job is rejected before load or allocation',
    () {
      final cache = BcdDetectorFreeDepthCache(
        captureDigest: 'cap-4k',
        backendAbi: 'abi-v1',
        futureUses: const {'4k': 1},
      );
      addTearDown(cache.dispose);
      var loaded = false;

      expect(
        () => cache.acquire(
          key: '4k',
          job: job(width: 4096, height: 2160),
          load: () {
            loaded = true;
            return map(1);
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(loaded, isFalse);
      expect(cache.stats.currentBytes, 0);
    },
  );

  test('disposed capture cache cannot be reused', () {
    final cache = BcdDetectorFreeDepthCache(
      captureDigest: 'cap-dispose',
      backendAbi: 'abi-v1',
      futureUses: const {'job': 1},
    );
    cache.dispose();

    expect(
      () => cache.acquire(key: 'job', job: job(), load: () => map(1)),
      throwsA(isA<StateError>()),
    );
  });

  test('buildAll plans every reference without materializing Float32 gray', () {
    final fixture = _fullSceneFixture();
    addTearDown(() => fixture.directory.deleteSync(recursive: true));
    final buildSet = _buildSet(fixture);

    expect(buildSet.plans, hasLength(6));
    expect(buildSet.materializedJobGrayFloatValueCount, 0);
    final first = BcdDetectorFreeFullSceneScheduler.buildAll(
      captureDigest: 'bundle-sha256',
      backendAbi: 'native-abi-a',
      buildSet: buildSet,
    );
    final otherBackend = BcdDetectorFreeFullSceneScheduler.buildAll(
      captureDigest: 'bundle-sha256',
      backendAbi: 'native-abi-b',
      buildSet: buildSet,
    );
    final certifiedSet = _buildCertifiedSet(fixture);
    final certified = BcdDetectorFreeFullSceneScheduler.buildAll(
      captureDigest: 'bundle-sha256',
      backendAbi: 'native-abi-a',
      buildSet: certifiedSet,
    );

    expect(buildSet.materializedJobGrayFloatValueCount, 0);
    expect(buildSet.certifiedProduct, isFalse);
    expect(first.certifiedProduct, isFalse);
    expect(first.planDigest, hasLength(64));
    expect(first.requireCertifiedProduct, throwsA(isA<StateError>()));
    expect(certifiedSet.certifiedProduct, isTrue);
    expect(certified.certifiedProduct, isTrue);
    expect(certified.planDigest, hasLength(64));
    expect(certified.requireCertifiedProduct, returnsNormally);
    expect(certified.planDigest, isNot(first.planDigest));
    expect(first.readyReferenceCount, 6);
    expect(first.skippedReferenceCount, 0);
    expect(
      first.references.map((item) => item.referenceFrameId),
      orderedEquals(const [10, 20, 30, 40, 50, 60]),
    );
    expect(first.depthJobUseCount, 18);
    expect(first.depthJobUseCount, greaterThan(first.uniqueDepthJobCount));
    expect(
      first.references.expand((item) => item.depthJobKeys),
      isNot(
        orderedEquals(
          otherBackend.references.expand((item) => item.depthJobKeys),
        ),
      ),
    );
  });

  test('runner failure is fail-closed and reports stable reference id', () {
    final fixture = _fullSceneFixture();
    addTearDown(() => fixture.directory.deleteSync(recursive: true));
    final buildSet = _buildSet(fixture);
    final plan = BcdDetectorFreeFullSceneScheduler.buildAll(
      captureDigest: 'bundle-sha256',
      backendAbi: 'native-abi-a',
      buildSet: buildSet,
    );

    expect(
      () => BcdDetectorFreeFullSceneScheduler.execute(
        plan: plan,
        runner: const _ThrowingDepthRunner(),
      ),
      throwsA(
        isA<BcdDetectorFreeScheduleException>()
            .having((error) => error.referenceFrameId, 'referenceFrameId', 10)
            .having((error) => error.cause, 'cause', isA<StateError>()),
      ),
    );
    expect(
      buildSet.materializedJobGrayFloatValueCount,
      3 * 8 * 6,
      reason: 'only the first primary job is packed before fail-close',
    );
  });

  test('real builder duplicate descriptors hit before materialization', () {
    final fixture = _fullSceneFixture();
    addTearDown(() => fixture.directory.deleteSync(recursive: true));
    final buildSet = _buildSet(fixture);
    final plan = BcdDetectorFreeFullSceneScheduler.buildAll(
      captureDigest: 'bundle-sha256',
      backendAbi: 'native-abi-a',
      buildSet: buildSet,
    );
    final runner = _ZeroDepthRunner();

    final result = BcdDetectorFreeFullSceneScheduler.execute(
      plan: plan,
      runner: runner,
    );

    expect(plan.depthJobUseCount, greaterThan(plan.uniqueDepthJobCount));
    expect(result.outcomes, hasLength(6));
    expect(result.outcomes.every((item) => item.birthCount == 0), isTrue);
    expect(runner.depthRuns, plan.uniqueDepthJobCount);
    expect(
      result.cacheStats.hits,
      plan.depthJobUseCount - plan.uniqueDepthJobCount,
    );
    expect(
      buildSet.materializedJobGrayFloatValueCount,
      plan.uniqueDepthJobCount * 3 * 8 * 6,
      reason: 'cache hits never claim or pack a repeated descriptor',
    );
    expect(result.cacheStats.currentBytes, 0);
  });

  test('evicted real descriptor is recomputed bit-exactly', () {
    final fixture = _fullSceneFixture();
    addTearDown(() => fixture.directory.deleteSync(recursive: true));
    final buildSet = _buildSet(fixture);
    final plan = BcdDetectorFreeFullSceneScheduler.buildAll(
      captureDigest: 'bundle-sha256',
      backendAbi: 'native-abi-a',
      buildSet: buildSet,
    );
    final runner = _DeterministicDepthRunner();

    final result = BcdDetectorFreeFullSceneScheduler.execute(
      plan: plan,
      runner: runner,
      maximumCacheEntries: 1,
      maximumCacheBytes: 1024,
    );

    expect(result.outcomes, hasLength(6));
    expect(result.cacheStats.lruEvictions, greaterThan(0));
    expect(runner.depthRuns, greaterThan(plan.uniqueDepthJobCount));
    expect(runner.bitExactRecomputations, greaterThan(0));
    expect(
      buildSet.materializedJobGrayFloatValueCount,
      runner.depthRuns * 3 * 8 * 6,
    );
  });

  test(
    'bounded executor caps concurrency and preserves reference order',
    () async {
      final fixture = _fullSceneFixture();
      addTearDown(() => fixture.directory.deleteSync(recursive: true));
      final plan = BcdDetectorFreeFullSceneScheduler.buildAll(
        captureDigest: 'bundle-sha256',
        backendAbi: 'native-abi-a',
        buildSet: _buildSet(fixture),
      );
      var active = 0;
      var peak = 0;

      final results =
          await BcdDetectorFreeFullSceneScheduler.executeBounded<int>(
            items: plan.references,
            maximumConcurrentReferences: 2,
            execute: (item) async {
              active++;
              if (active > peak) peak = active;
              await Future<void>.delayed(
                Duration(milliseconds: item.referenceFrameId == 10 ? 8 : 1),
              );
              active--;
              return item.referenceFrameId;
            },
          );

      expect(peak, 2);
      expect(results, orderedEquals(const [10, 20, 30, 40, 50, 60]));
    },
  );

  test('failed reference certificate publishes zero and remains explicit', () {
    final blocked = BcdDetectorFreeReferenceOutcome.completed(
      7,
      _birthResult(
        pointCount: 0,
        candidateCount: 21,
        preCertificateBirthCount: 21,
        blockedBirthCount: 21,
        failedFoldMask: 1,
        marker: 7,
      ),
    );
    final skipped = BcdDetectorFreeReferenceOutcome.skipped(
      const BcdDetectorFreeSkippedReference(
        frameId: 8,
        reason: BcdDetectorFreeSkipReason.insufficientPoseOverlap,
        detail: 'two independent views unavailable',
      ),
    );
    final execution = BcdDetectorFreeFullSceneExecution(
      outcomes: [blocked, skipped],
      cacheStats: _emptyCacheStats,
    );

    expect(blocked.isBlocked, isTrue);
    expect(blocked.birthCount, 0);
    expect(skipped.birthCount, 0);
    expect(
      skipped.skipped!.reason,
      BcdDetectorFreeSkipReason.insufficientPoseOverlap,
    );
    expect(execution.certifiedReferenceCount, 0);
    expect(execution.blockedReferenceCount, 1);
    expect(execution.skippedReferenceCount, 1);
    expect(execution.blockedBirthCount, 21);
    expect(execution.birthCount, 0);
    expect(execution.mergedMetricBirthCloud.xyz, isEmpty);

    expect(
      () => BcdDetectorFreeReferenceOutcome.completed(
        9,
        _birthResult(
          pointCount: 1,
          candidateCount: 1,
          preCertificateBirthCount: 1,
          blockedBirthCount: 0,
          failedFoldMask: 1,
          marker: 9,
        ),
      ),
      throwsA(isA<StateError>()),
      reason: 'a failed certificate can never carry a published birth',
    );
  });

  test(
    'full299 certified model merges 28542 births in reference byte order',
    () {
      final counts = List<int>.filled(299, 0)
        ..[0] = 200
        ..[46] = 26
        ..[142] = 20744
        ..[246] = 7572;
      final outcomes = <BcdDetectorFreeReferenceOutcome>[
        for (var frameId = 0; frameId < counts.length; frameId++)
          BcdDetectorFreeReferenceOutcome.completed(
            frameId,
            _birthResult(
              pointCount: counts[frameId],
              candidateCount: counts[frameId],
              preCertificateBirthCount: counts[frameId],
              blockedBirthCount: 0,
              failedFoldMask: 0,
              marker: frameId,
            ),
          ),
      ];

      final execution = BcdDetectorFreeFullSceneExecution(
        outcomes: outcomes,
        cacheStats: _emptyCacheStats,
      );

      expect(execution.certifiedReferenceCount, 299);
      expect(execution.blockedReferenceCount, 0);
      expect(execution.skippedReferenceCount, 0);
      expect(execution.preCertificateBirthCount, 28542);
      expect(execution.blockedBirthCount, 0);
      expect(execution.birthCount, 28542);
      expect(execution.mergedMetricBirthCloud.xyz.length, 28542 * 3);
      expect(execution.mergedMetricBirthCloud.rgb.length, 28542 * 3);
      expect(
        execution.mergedMetricBirthCloud.xyz.sublist(0, 3),
        orderedEquals(const [0, 0, 0]),
      );
      expect(
        execution.mergedMetricBirthCloud.xyz.sublist(200 * 3, 200 * 3 + 3),
        orderedEquals(const [46, 0, 0]),
      );
      expect(
        execution.mergedMetricBirthCloud.xyz.sublist(226 * 3, 226 * 3 + 3),
        orderedEquals(const [142, 0, 0]),
      );
      expect(
        execution.mergedMetricBirthCloud.rgb.sublist(200 * 3, 200 * 3 + 3),
        orderedEquals(const [46, 0, 255]),
      );
    },
  );
}

const _emptyCacheStats = BcdDetectorFreeDepthCacheStats(
  hits: 0,
  misses: 0,
  lruEvictions: 0,
  lastUseEvictions: 0,
  currentEntries: 0,
  currentBytes: 0,
  peakBytes: 0,
);

BcdDetectorFreeBirthResult _birthResult({
  required int pointCount,
  required int candidateCount,
  required int preCertificateBirthCount,
  required int blockedBirthCount,
  required int failedFoldMask,
  required int marker,
}) {
  final born = Uint8List(candidateCount);
  final bornIndices = <int>[];
  for (var index = 0; index < pointCount; index++) {
    born[index] = 1;
    bornIndices.add(index);
  }
  final xyz = Float32List(pointCount * 3);
  final rgb = Uint8List(pointCount * 3);
  for (var index = 0; index < pointCount; index++) {
    xyz[index * 3] = marker.toDouble();
    xyz[index * 3 + 1] = index.toDouble();
    xyz[index * 3 + 2] = -index.toDouble();
    rgb[index * 3] = marker & 0xff;
    rgb[index * 3 + 1] = index & 0xff;
    rgb[index * 3 + 2] = (255 - index) & 0xff;
  }
  final certificate = ReferenceBirthCertificateResult(
    failedFoldMask: failedFoldMask,
    preCertificateBirthCount: preCertificateBirthCount,
    blockedBirthCount: blockedBirthCount,
    finalBirthCount: pointCount,
    born: born,
  );
  final inputEligible = Uint8List(candidateCount)
    ..fillRange(0, candidateCount, 1);
  return BcdDetectorFreeBirthResult(
    cloud: BcdPointCloud(xyz: xyz, rgb: rgb),
    bornCandidateIndices: bornIndices,
    floorRerouteCandidateIndices: const [],
    ownership: ReferenceCertifiedBirthOwnershipResult(
      inputEligible: inputEligible,
      floorOwned: Uint8List(candidateCount),
      wallOwned: Uint8List(candidateCount),
      structuralOwned: Uint8List(candidateCount),
      certificate: certificate,
    ),
  );
}

const _floor = StructuralFloorDomain(
  certified: true,
  normal: [0, 1, 0],
  basisU: [1, 0, 0],
  basisV: [0, 0, 1],
  planeValue: 0,
  boundsU: [-10, 10],
  boundsV: [-10, 10],
);

class _Fixture {
  const _Fixture({
    required this.directory,
    required this.bundle,
    required this.reader,
  });

  final Directory directory;
  final BcdFinalizeInputBundle bundle;
  final BcdDetectorFreeAssetReader reader;
}

_Fixture _fullSceneFixture() {
  const centers = <int, List<double>>{
    60: [0.50, 0.00, 0.02],
    10: [0.10, 0.00, 0.00],
    50: [0.40, 0.02, 0.00],
    30: [0.00, 0.00, 0.00],
    20: [0.20, 0.02, 0.00],
    40: [0.30, 0.00, 0.01],
  };
  final directory = Directory.systemTemp.createTempSync('bcd-d-scheduler-');
  final metadata = <int, SfmFedFrameMeta>{};
  final grayPaths = <int, String>{};
  final poses = <double>[];
  final solveAssets = <int, BcdDetectorFreeSolveAsset>{};
  for (final entry in centers.entries) {
    final frameId = entry.key;
    final center = entry.value;
    final gray = Uint8List(8 * 6)..fillRange(0, 8 * 6, frameId);
    final rgb = Uint8List(8 * 6 * 3);
    for (var index = 0; index < rgb.length; index++) {
      rgb[index] = (frameId + index) & 0xff;
    }
    final path = '${directory.path}/frame-$frameId.gray';
    File(path).writeAsBytesSync(gray, flush: true);
    grayPaths[frameId] = path;
    metadata[frameId] = SfmFedFrameMeta(
      jpegPath: '${directory.path}/frame-$frameId.jpg',
      imageW: 8,
      imageH: 6,
      grayW: 8,
      grayH: 6,
      fx: 4,
      fy: 6,
      cx: 4,
      cy: 3,
      arkitQuatWxyz: const [0, 1, 0, 0],
      arkitCameraCenterWorld: [center[0] + 3, center[1] - 1, center[2] + 0.5],
    );
    poses.addAll([
      frameId.toDouble(),
      1,
      1,
      0,
      0,
      0,
      -center[0],
      -center[1],
      -center[2],
    ]);
    solveAssets[frameId] = BcdDetectorFreeSolveAsset(
      frameId: frameId,
      width: 8,
      height: 6,
      gray: gray,
      rgb: rgb,
      grayDigest: 'gray-$frameId',
      rgbDigest: 'rgb-$frameId',
      provenance: BcdDetectorFreePhotometricProvenance.jpegRgbArea,
    );
  }
  final sparse = Float32List.fromList([
    for (var sample = -10; sample <= 10; sample++) ...[
      0.25 + sample * 0.01,
      -0.002,
      1.2 + (sample % 5) * 0.01,
      0.25 + sample * 0.01,
      0.002,
      1.2 + (sample % 5) * 0.01,
      0.25 + sample * 0.01,
      0.006,
      1.2 + (sample % 5) * 0.01,
    ],
  ]);
  final snapshot = SfmLiveSnapshot(
    xyz: sparse,
    rgb: Uint8List(sparse.length),
    posesPacked: Float64List.fromList(poses),
    summary: const {},
    refined: true,
    obsOffsets: Int32List(sparse.length ~/ 3 + 1),
    obsFrameIds: Int32List(0),
    obsXY: Float32List(0),
  );
  return _Fixture(
    directory: directory,
    bundle: BcdFinalizeInputBuilder.build(
      snapshot: snapshot,
      fedFrameMeta: metadata,
      grayPathByFrameId: grayPaths,
    ),
    reader: _MemoryAssetReader(solveAssets),
  );
}

BcdDetectorFreeJobBuildSet _buildSet(_Fixture fixture) =>
    BcdDetectorFreeJobBuilder.buildAllExperimental(
      bundle: fixture.bundle,
      assetReader: fixture.reader,
      floorValue: 0,
      selectedFloor: _floor,
      certifiedWalls: const [],
      options: const BcdDetectorFreeJobBuilderOptions.experimental(
        solveWidth: 8,
        solveHeight: 6,
        minimumSourceViews: 2,
        maximumSourceViews: 2,
        minimumBaselineM: 0.05,
        maximumBaselineM: 0.75,
        targetBaselineM: 0.20,
        depthCount: 3,
        maxTileWidth: 8,
        maxTileHeight: 6,
        patchN: 3,
        exclusionRadiusSamples: 1,
        refineOptions: null,
        reciprocalOptions: DetectorFreeReciprocalOptions(
          minimumReciprocalViews: 2,
        ),
      ),
    );

BcdDetectorFreeJobBuildSet _buildCertifiedSet(_Fixture fixture) =>
    BcdDetectorFreeJobBuilder.buildAll(
      bundle: fixture.bundle,
      assetReader: fixture.reader,
      floorValue: 0,
      selectedFloor: _floor,
      certifiedWalls: const [],
    );

class _MemoryAssetReader implements BcdDetectorFreeAssetReader {
  const _MemoryAssetReader(this.assets);

  final Map<int, BcdDetectorFreeSolveAsset> assets;

  @override
  BcdDetectorFreeSolveAsset? readSolveAsset(
    BcdFinalizeRegisteredFrameInput input, {
    required int width,
    required int height,
  }) {
    final source = assets[input.cameraFrame.frameId];
    if (source == null) return null;
    if (source.width == width && source.height == height) return source;
    final gray = Uint8List(width * height)
      ..fillRange(0, width * height, source.frameId & 0xff);
    final rgb = source.rgb == null ? null : Uint8List(width * height * 3);
    if (rgb != null) {
      for (var index = 0; index < rgb.length; index++) {
        rgb[index] = (source.frameId + index) & 0xff;
      }
    }
    return BcdDetectorFreeSolveAsset(
      frameId: source.frameId,
      width: width,
      height: height,
      gray: gray,
      rgb: rgb,
      grayDigest: 'gray-${source.frameId}-${width}x$height',
      rgbDigest: rgb == null ? null : 'rgb-${source.frameId}-${width}x$height',
      provenance: source.provenance,
    );
  }
}

class _ThrowingDepthRunner implements BcdDetectorFreeDepthRunner {
  const _ThrowingDepthRunner();

  @override
  BcdDetectorFreeDepthMap runDepth(BcdDetectorFreeDepthJob job) =>
      throw StateError('synthetic depth failure');

  @override
  DetectorFreeReciprocalBirthResult filterReciprocal(
    BcdDetectorFreeReciprocalInput input,
  ) => throw StateError('unreachable reciprocal filter');
}

class _ZeroDepthRunner implements BcdDetectorFreeDepthRunner {
  int depthRuns = 0;

  @override
  BcdDetectorFreeDepthMap runDepth(BcdDetectorFreeDepthJob job) {
    depthRuns++;
    final pixels = job.options.imageWidth * job.options.imageHeight;
    return BcdDetectorFreeDepthMap(
      width: job.options.imageWidth,
      height: job.options.imageHeight,
      depthM: Float32List(pixels),
      accepted: Uint8List(pixels),
    );
  }

  @override
  DetectorFreeReciprocalBirthResult filterReciprocal(
    BcdDetectorFreeReciprocalInput input,
  ) {
    final pixels = input.imageWidth * input.imageHeight;
    return DetectorFreeReciprocalBirthResult(
      consistentViews: Uint8List(pixels),
      born: Uint8List(pixels),
    );
  }
}

class _DeterministicDepthRunner extends _ZeroDepthRunner {
  final Map<String, Uint8List> _firstBytesByInput = <String, Uint8List>{};
  int bitExactRecomputations = 0;

  @override
  BcdDetectorFreeDepthMap runDepth(BcdDetectorFreeDepthJob job) {
    depthRuns++;
    final pixels = job.options.imageWidth * job.options.imageHeight;
    final checksum = job.grayFrames.fold<int>(
      0,
      (sum, value) => (sum * 131 + value.toInt()) & 0x7fffffff,
    );
    final projectionChecksum = job.sourceProjections.fold<int>(
      0,
      (sum, value) => (sum * 131 + (value * 100000).round()) & 0x7fffffff,
    );
    final identity =
        '${job.options.inverseDepthFirst}/'
        '${job.options.inverseDepthStep}/$checksum/$projectionChecksum';
    final depth = Float32List(pixels)
      ..fillRange(0, pixels, 0.1 + (checksum % 100) * 0.0001);
    final bytes = Uint8List.fromList(
      Uint8List.view(depth.buffer, depth.offsetInBytes, depth.lengthInBytes),
    );
    final first = _firstBytesByInput[identity];
    if (first == null) {
      _firstBytesByInput[identity] = bytes;
    } else {
      expect(bytes, orderedEquals(first));
      bitExactRecomputations++;
    }
    return BcdDetectorFreeDepthMap(
      width: job.options.imageWidth,
      height: job.options.imageHeight,
      depthM: depth,
      accepted: Uint8List(pixels),
    );
  }
}
