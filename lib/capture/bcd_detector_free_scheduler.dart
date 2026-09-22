// Capture-scoped full-scene scheduling for detector-free (D) finalize.
//
// The job builder owns geometry, source selection, resampling, and depth-range
// memoization. This scheduler owns stable reference order, lazy execution,
// capture/backend-scoped depth reuse, and hard memory/concurrency bounds.

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../detector_free_depth_ffi.dart';
import 'bcd_detector_free_job_builder.dart';
import 'bcd_finalize_coordinator.dart';

const int _defaultMaximumDepthJobPixels = 128 * 72;

class BcdDetectorFreeScheduledReference {
  const BcdDetectorFreeScheduledReference._({
    required this.referenceFrameId,
    required this.skipped,
    required BcdDetectorFreeReferencePlan? plan,
    required List<_ScheduledDepthJob> depthJobs,
  }) : _plan = plan,
       _depthJobs = depthJobs;

  final int referenceFrameId;
  final BcdDetectorFreeSkippedReference? skipped;
  final BcdDetectorFreeReferencePlan? _plan;
  final List<_ScheduledDepthJob> _depthJobs;

  bool get isSkipped => skipped != null;
  int get depthJobCount => _depthJobs.length;
  List<String> get depthJobKeys =>
      List<String>.unmodifiable(_depthJobs.map((item) => item.key));
}

/// Lightweight plan: no depth job or packed Float32 gray stack is retained.
class BcdDetectorFreeFullScenePlan {
  const BcdDetectorFreeFullScenePlan._({
    required this.captureDigest,
    required this.backendAbi,
    required this.certifiedProduct,
    required this.planDigest,
    required this.references,
    required this.maximumDepthJobPixels,
  });

  final String captureDigest;
  final String backendAbi;
  final bool certifiedProduct;
  final String planDigest;
  final List<BcdDetectorFreeScheduledReference> references;
  final int maximumDepthJobPixels;

  /// Product callers use this exact assertion before opening native sessions.
  /// The value is inherited from the builder's private certified/experimental
  /// route and cannot be supplied to this plan by a caller.
  void requireCertifiedProduct() {
    if (!certifiedProduct) {
      throw StateError('experimental detector-free plan cannot be published');
    }
  }

  int get readyReferenceCount =>
      references.where((item) => !item.isSkipped).length;
  int get skippedReferenceCount => references.length - readyReferenceCount;
  int get depthJobUseCount =>
      references.fold<int>(0, (sum, item) => sum + item.depthJobCount);
  int get uniqueDepthJobCount =>
      {for (final reference in references) ...reference.depthJobKeys}.length;
}

class BcdDetectorFreeReferenceOutcome {
  const BcdDetectorFreeReferenceOutcome._({
    required this.referenceFrameId,
    required this.skipped,
    required this.birthResult,
    required this.blocked,
  });

  factory BcdDetectorFreeReferenceOutcome.skipped(
    BcdDetectorFreeSkippedReference skipped,
  ) => BcdDetectorFreeReferenceOutcome._(
    referenceFrameId: skipped.frameId,
    skipped: skipped,
    birthResult: null,
    blocked: false,
  );

  factory BcdDetectorFreeReferenceOutcome.completed(
    int referenceFrameId,
    BcdDetectorFreeBirthResult result,
  ) {
    _validateCertifiedBirthResult(referenceFrameId, result);
    return BcdDetectorFreeReferenceOutcome._(
      referenceFrameId: referenceFrameId,
      skipped: null,
      birthResult: result,
      blocked: !result.certificate.certified,
    );
  }

  final int referenceFrameId;
  final BcdDetectorFreeSkippedReference? skipped;
  final BcdDetectorFreeBirthResult? birthResult;
  final bool blocked;

  bool get isSkipped => skipped != null;
  bool get isBlocked => blocked;
  bool get isCertified => birthResult?.certificate.certified ?? false;
  int get birthCount => birthResult?.bornCandidateIndices.length ?? 0;
}

class BcdDetectorFreeFullSceneExecution {
  BcdDetectorFreeFullSceneExecution({
    required List<BcdDetectorFreeReferenceOutcome> outcomes,
    required this.cacheStats,
  }) : outcomes = List.unmodifiable(outcomes),
       mergedMetricBirthCloud = _mergeCertifiedMetricBirths(outcomes) {
    _validateStableOutcomeOrder(outcomes);
  }

  final List<BcdDetectorFreeReferenceOutcome> outcomes;
  final BcdDetectorFreeDepthCacheStats cacheStats;
  final BcdPointCloud mergedMetricBirthCloud;

  int get certifiedReferenceCount =>
      outcomes.where((item) => item.isCertified).length;
  int get blockedReferenceCount =>
      outcomes.where((item) => item.isBlocked).length;
  int get skippedReferenceCount =>
      outcomes.where((item) => item.isSkipped).length;
  int get preCertificateBirthCount => outcomes.fold<int>(
    0,
    (sum, item) =>
        sum + (item.birthResult?.certificate.preCertificateBirthCount ?? 0),
  );
  int get blockedBirthCount => outcomes.fold<int>(
    0,
    (sum, item) => sum + (item.birthResult?.certificate.blockedBirthCount ?? 0),
  );

  /// Sum of per-reference certified births. Cross-reference first-claim/radius
  /// deduplication is intentionally absent: it regressed cap40/50/51 coverage
  /// and error metrics. B ownership and each reference certificate remain the
  /// publication gates.
  int get birthCount => mergedMetricBirthCloud.xyz.length ~/ 3;
}

class BcdDetectorFreeScheduleException implements Exception {
  const BcdDetectorFreeScheduleException({
    required this.referenceFrameId,
    required this.cause,
    this.stackTrace,
  });

  final int referenceFrameId;
  final Object cause;
  final StackTrace? stackTrace;

  @override
  String toString() =>
      'BcdDetectorFreeScheduleException(reference=$referenceFrameId, cause=$cause)';
}

void _validateCertifiedBirthResult(
  int referenceFrameId,
  BcdDetectorFreeBirthResult result,
) {
  final certificate = result.certificate;
  final pointCount = result.cloud.xyz.length ~/ 3;
  var certificateBirths = 0;
  final expectedIndices = <int>[];
  final ownershipMasks = <Uint8List>[
    result.ownership.inputEligible,
    result.ownership.floorOwned,
    result.ownership.wallOwned,
    result.ownership.structuralOwned,
  ];
  if (result.cloud.xyz.length % 3 != 0 ||
      result.cloud.rgb.length != result.cloud.xyz.length ||
      result.cloud.xyz.any((value) => !value.isFinite) ||
      certificate.failedFoldMask < 0 ||
      certificate.failedFoldMask > 7 ||
      certificate.preCertificateBirthCount < 0 ||
      certificate.blockedBirthCount < 0 ||
      certificate.finalBirthCount < 0 ||
      certificate.blockedBirthCount > certificate.preCertificateBirthCount ||
      certificate.preCertificateBirthCount - certificate.blockedBirthCount !=
          certificate.finalBirthCount ||
      (certificate.certified && certificate.blockedBirthCount != 0) ||
      certificate.born.any((value) => value > 1) ||
      !identical(result.ownership.born, certificate.born) ||
      ownershipMasks.any(
        (mask) =>
            mask.length != certificate.born.length ||
            mask.any((value) => value > 1),
      )) {
    throw StateError(
      'detector-free reference $referenceFrameId has malformed certificate',
    );
  }
  for (var index = 0; index < certificate.born.length; index++) {
    final structural = result.ownership.structuralOwned[index];
    if (structural !=
            ((result.ownership.floorOwned[index] != 0 ||
                    result.ownership.wallOwned[index] != 0)
                ? 1
                : 0) ||
        (certificate.born[index] != 0 &&
            (result.ownership.inputEligible[index] == 0 || structural != 0))) {
      throw StateError(
        'detector-free reference $referenceFrameId has malformed ownership',
      );
    }
    if (certificate.born[index] != 0) {
      certificateBirths++;
      expectedIndices.add(index);
    }
  }
  if (certificateBirths != certificate.finalBirthCount ||
      pointCount != certificate.finalBirthCount ||
      result.bornCandidateIndices.length != certificate.finalBirthCount ||
      !_sameIntList(result.bornCandidateIndices, expectedIndices) ||
      (!certificate.certified && certificate.finalBirthCount != 0)) {
    throw StateError(
      'detector-free reference $referenceFrameId failed publication certificate',
    );
  }
}

bool _sameIntList(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

void _validateStableOutcomeOrder(
  List<BcdDetectorFreeReferenceOutcome> outcomes,
) {
  for (var index = 1; index < outcomes.length; index++) {
    if (outcomes[index - 1].referenceFrameId >=
        outcomes[index].referenceFrameId) {
      throw StateError(
        'detector-free full-scene outcomes are not in stable reference order',
      );
    }
  }
}

BcdPointCloud _mergeCertifiedMetricBirths(
  List<BcdDetectorFreeReferenceOutcome> outcomes,
) {
  var xyzLength = 0;
  for (final outcome in outcomes) {
    if (outcome.isCertified) {
      xyzLength += outcome.birthResult!.cloud.xyz.length;
    }
  }
  final xyz = Float32List(xyzLength);
  final rgb = Uint8List(xyzLength);
  var offset = 0;
  for (final outcome in outcomes) {
    if (!outcome.isCertified) continue;
    final cloud = outcome.birthResult!.cloud;
    xyz.setRange(offset, offset + cloud.xyz.length, cloud.xyz);
    rgb.setRange(offset, offset + cloud.rgb.length, cloud.rgb);
    offset += cloud.xyz.length;
  }
  return BcdPointCloud(xyz: xyz, rgb: rgb);
}

class BcdDetectorFreeDepthCacheStats {
  const BcdDetectorFreeDepthCacheStats({
    required this.hits,
    required this.misses,
    required this.lruEvictions,
    required this.lastUseEvictions,
    required this.currentEntries,
    required this.currentBytes,
    required this.peakBytes,
  });

  final int hits;
  final int misses;
  final int lruEvictions;
  final int lastUseEvictions;
  final int currentEntries;
  final int currentBytes;
  final int peakBytes;
}

/// Hard-bounded cache for one immutable capture and one exact native backend
/// ABI. An entry is stored only when another planned use exists, and is
/// removed immediately after its final consumer.
class BcdDetectorFreeDepthCache {
  BcdDetectorFreeDepthCache({
    required this.captureDigest,
    required this.backendAbi,
    required Map<String, int> futureUses,
    this.maximumEntries = 64,
    this.maximumBytes = 4 * 1024 * 1024,
    this.maximumDepthJobPixels = _defaultMaximumDepthJobPixels,
  }) : _remainingUses = Map<String, int>.from(futureUses) {
    if (captureDigest.trim().isEmpty ||
        backendAbi.trim().isEmpty ||
        maximumEntries <= 0 ||
        maximumBytes <= 0 ||
        maximumDepthJobPixels <= 0 ||
        _remainingUses.values.any((count) => count <= 0)) {
      throw ArgumentError('invalid detector-free capture cache contract');
    }
  }

  final String captureDigest;
  final String backendAbi;
  final int maximumEntries;
  final int maximumBytes;
  final int maximumDepthJobPixels;
  final Map<String, int> _remainingUses;
  final LinkedHashMap<String, _DepthCacheEntry> _entries = LinkedHashMap();
  final Set<String> _loadingKeys = <String>{};

  int _bytes = 0;
  int _peakBytes = 0;
  int _hits = 0;
  int _misses = 0;
  int _lruEvictions = 0;
  int _lastUseEvictions = 0;
  bool _disposed = false;

  BcdDetectorFreeDepthMap acquire({
    required String key,
    required BcdDetectorFreeDepthJob job,
    required BcdDetectorFreeDepthMap Function() load,
  }) => acquireLazy(
    key: key,
    imageWidth: job.options.imageWidth,
    imageHeight: job.options.imageHeight,
    load: load,
  );

  /// Performs lookup before [load]. Product scheduling uses this boundary so
  /// an exact repeated descriptor never materializes a second Float32 job.
  BcdDetectorFreeDepthMap acquireLazy({
    required String key,
    required int imageWidth,
    required int imageHeight,
    required BcdDetectorFreeDepthMap Function() load,
  }) {
    _ensureOpen();
    final pixels = imageWidth * imageHeight;
    if (imageWidth <= 0 || imageHeight <= 0 || pixels > maximumDepthJobPixels) {
      throw StateError(
        'detector-free depth job ${imageWidth}x'
        '$imageHeight exceeds scheduler bound '
        '$maximumDepthJobPixels',
      );
    }
    final usesBefore = _remainingUses[key];
    if (usesBefore == null || usesBefore <= 0) {
      throw StateError('unplanned detector-free depth job key');
    }

    var entry = _entries.remove(key);
    late final BcdDetectorFreeDepthMap result;
    if (entry == null) {
      _misses++;
      if (!_loadingKeys.add(key)) {
        throw StateError('reentrant detector-free depth load for $key');
      }
      try {
        result = load();
      } finally {
        _loadingKeys.remove(key);
      }
      entry = _DepthCacheEntry(result);
    } else {
      _hits++;
      _entries[key] = entry;
      result = entry.map;
    }

    final usesAfter = usesBefore - 1;
    _remainingUses[key] = usesAfter;
    if (usesAfter == 0) {
      final resident = _entries.remove(key);
      if (resident != null) {
        _bytes -= resident.bytes;
        _lastUseEvictions++;
      }
      return result;
    }

    if (!_entries.containsKey(key) && entry.bytes <= maximumBytes) {
      _entries[key] = entry;
      _bytes += entry.bytes;
      _trimLru();
      if (_bytes > _peakBytes) _peakBytes = _bytes;
    }
    return result;
  }

  void _trimLru() {
    while (_entries.length > maximumEntries || _bytes > maximumBytes) {
      final removed = _entries.remove(_entries.keys.first)!;
      _bytes -= removed.bytes;
      _lruEvictions++;
    }
  }

  BcdDetectorFreeDepthCacheStats get stats => BcdDetectorFreeDepthCacheStats(
    hits: _hits,
    misses: _misses,
    lruEvictions: _lruEvictions,
    lastUseEvictions: _lastUseEvictions,
    currentEntries: _entries.length,
    currentBytes: _bytes,
    peakBytes: _peakBytes,
  );

  void dispose() {
    if (_disposed) return;
    _entries.clear();
    _loadingKeys.clear();
    _remainingUses.clear();
    _bytes = 0;
    _disposed = true;
  }

  void _ensureOpen() {
    if (_disposed) throw StateError('detector-free capture cache is disposed');
  }
}

class _DepthCacheEntry {
  const _DepthCacheEntry(this.map);

  final BcdDetectorFreeDepthMap map;
  int get bytes =>
      map.depthM.lengthInBytes +
      map.accepted.lengthInBytes +
      (map.coarseDepthM?.lengthInBytes ?? 0) +
      (map.coarseAccepted?.lengthInBytes ?? 0);
}

class BcdDetectorFreeFullSceneScheduler {
  const BcdDetectorFreeFullSceneScheduler._();

  /// Converts a builder result into a stable, lightweight execution plan.
  /// Keys are derived from the builder's gray-free descriptors. Planning does
  /// not materialize even one Float32 gray stack; each solve-grid U8 plane was
  /// already digested once by the builder.
  static BcdDetectorFreeFullScenePlan buildAll({
    required String captureDigest,
    required String backendAbi,
    required BcdDetectorFreeJobBuildSet buildSet,
    int maximumDepthJobPixels = _defaultMaximumDepthJobPixels,
  }) {
    if (captureDigest.trim().isEmpty ||
        backendAbi.trim().isEmpty ||
        maximumDepthJobPixels <= 0) {
      throw ArgumentError('invalid detector-free full-scene identity');
    }
    final references = <BcdDetectorFreeScheduledReference>[];
    for (final plan in buildSet.plans) {
      final jobs = <_ScheduledDepthJob>[];
      for (var index = 0; index < plan.depthJobDescriptors.length; index++) {
        final descriptor = plan.depthJobDescriptors[index];
        _validateDescriptorBound(descriptor, maximumDepthJobPixels);
        jobs.add(
          _ScheduledDepthJob(
            reciprocalIndex: index == 0 ? null : index - 1,
            key: _descriptorKey(
              captureDigest: captureDigest,
              backendAbi: backendAbi,
              certifiedProduct: buildSet.certifiedProduct,
              descriptor: descriptor,
            ),
          ),
        );
      }
      references.add(
        BcdDetectorFreeScheduledReference._(
          referenceFrameId: plan.referenceFrameId,
          skipped: null,
          plan: plan,
          depthJobs: List.unmodifiable(jobs),
        ),
      );
    }
    for (final skipped in buildSet.skippedReferences) {
      references.add(
        BcdDetectorFreeScheduledReference._(
          referenceFrameId: skipped.frameId,
          skipped: skipped,
          plan: null,
          depthJobs: const [],
        ),
      );
    }
    references.sort((left, right) {
      final byId = left.referenceFrameId.compareTo(right.referenceFrameId);
      if (byId != 0) return byId;
      // A frame cannot normally be both ready and skipped; if malformed input
      // creates both, the explicit skip is reported first and remains visible.
      return (left.isSkipped ? 0 : 1).compareTo(right.isSkipped ? 0 : 1);
    });
    final planDigest = _fullScenePlanDigest(
      captureDigest: captureDigest,
      backendAbi: backendAbi,
      certifiedProduct: buildSet.certifiedProduct,
      references: references,
    );
    return BcdDetectorFreeFullScenePlan._(
      captureDigest: captureDigest,
      backendAbi: backendAbi,
      certifiedProduct: buildSet.certifiedProduct,
      planDigest: planDigest,
      references: List.unmodifiable(references),
      maximumDepthJobPixels: maximumDepthJobPixels,
    );
  }

  /// Serial product execution. A depth job is materialized, solved/reused, and
  /// released before the next job is materialized. Native errors are wrapped
  /// with the exact reference id and propagated; they never masquerade as a
  /// successful zero-birth result.
  static BcdDetectorFreeFullSceneExecution execute({
    required BcdDetectorFreeFullScenePlan plan,
    BcdDetectorFreeDepthRunner runner = const BcdFfiDetectorFreeDepthRunner(),
    int maximumCacheEntries = 64,
    int maximumCacheBytes = 4 * 1024 * 1024,
  }) {
    final futureUses = <String, int>{};
    for (final reference in plan.references) {
      for (final job in reference._depthJobs) {
        futureUses[job.key] = (futureUses[job.key] ?? 0) + 1;
      }
    }
    final cache = BcdDetectorFreeDepthCache(
      captureDigest: plan.captureDigest,
      backendAbi: plan.backendAbi,
      futureUses: futureUses,
      maximumEntries: maximumCacheEntries,
      maximumBytes: maximumCacheBytes,
      maximumDepthJobPixels: plan.maximumDepthJobPixels,
    );
    final outcomes = <BcdDetectorFreeReferenceOutcome>[];
    try {
      for (final reference in plan.references) {
        if (reference.isSkipped) {
          outcomes.add(
            BcdDetectorFreeReferenceOutcome.skipped(reference.skipped!),
          );
          continue;
        }
        try {
          outcomes.add(
            BcdDetectorFreeReferenceOutcome.completed(
              reference.referenceFrameId,
              _executeReference(
                scheduled: reference,
                captureDigest: plan.captureDigest,
                backendAbi: plan.backendAbi,
                certifiedProduct: plan.certifiedProduct,
                runner: runner,
                cache: cache,
                maximumDepthJobPixels: plan.maximumDepthJobPixels,
              ),
            ),
          );
        } catch (error, stackTrace) {
          throw BcdDetectorFreeScheduleException(
            referenceFrameId: reference.referenceFrameId,
            cause: error,
            stackTrace: stackTrace,
          );
        }
      }
      return BcdDetectorFreeFullSceneExecution(
        outcomes: List.unmodifiable(outcomes),
        cacheStats: cache.stats,
      );
    } finally {
      cache.dispose();
    }
  }

  static BcdDetectorFreeBirthResult _executeReference({
    required BcdDetectorFreeScheduledReference scheduled,
    required String captureDigest,
    required String backendAbi,
    required bool certifiedProduct,
    required BcdDetectorFreeDepthRunner runner,
    required BcdDetectorFreeDepthCache cache,
    required int maximumDepthJobPixels,
  }) {
    final plan = scheduled._plan!;
    final maps = <BcdDetectorFreeDepthMap>[];
    final templates = <_DepthJobTemplate>[];
    for (final descriptor in scheduled._depthJobs) {
      final jobDescriptor = descriptor.reciprocalIndex == null
          ? plan.primaryDescriptor
          : plan.reciprocalDescriptors[descriptor.reciprocalIndex!];
      final currentKey = _descriptorKey(
        captureDigest: captureDigest,
        backendAbi: backendAbi,
        certifiedProduct: certifiedProduct,
        descriptor: jobDescriptor,
      );
      if (currentKey != descriptor.key) {
        throw StateError('detector-free job changed after planning');
      }
      templates.add(_DepthJobTemplate.fromDescriptor(jobDescriptor));
      maps.add(
        cache.acquireLazy(
          key: descriptor.key,
          imageWidth: jobDescriptor.options.imageWidth,
          imageHeight: jobDescriptor.options.imageHeight,
          load: () {
            final job = descriptor.reciprocalIndex == null
                ? plan.materializePrimaryDepthJob()
                : plan.materializeReciprocalDepthJob(
                    descriptor.reciprocalIndex!,
                  );
            _validateBound(job, maximumDepthJobPixels);
            return runner.runDepth(job);
          },
        ),
      );
      // [job] is not retained. The next loop iteration owns the only packed
      // Float32 gray stack; templates retain options/projections only.
    }

    // The current coordinator accepts job-shaped validation inputs. Reuse one
    // finite zero buffer per exact gray length while a precomputed runner
    // supplies the already-solved maps. This keeps the gate unchanged without
    // recreating the real primary+reciprocal image stacks.
    final zeroGrayByLength = <int, Float32List>{};
    final proxyJobs = <BcdDetectorFreeDepthJob>[];
    for (final template in templates) {
      proxyJobs.add(template.proxy(zeroGrayByLength));
    }
    final precomputed = _PrecomputedDepthRunner(
      delegate: runner,
      mapsByJob:
          Map<BcdDetectorFreeDepthJob, BcdDetectorFreeDepthMap>.identity()
            ..addEntries([
              for (var index = 0; index < proxyJobs.length; index++)
                MapEntry(proxyJobs[index], maps[index]),
            ]),
    );
    final metadata = plan.metadata;
    return BcdFinalizeCoordinator.runAndGateDetectorFreeCandidates(
      request: BcdDetectorFreeFinalizeRequest(
        sparseXyz: metadata.metricSparseXyz,
        primary: proxyJobs.first,
        reciprocals: List.unmodifiable(proxyJobs.skip(1)),
        referenceRgb: metadata.referenceRgb,
        worldToReferenceProjection3x4: metadata.worldToReferenceProjection3x4,
        referenceToReciprocalProjections:
            metadata.referenceToReciprocalProjections,
        reciprocalCameraCentersInReference:
            metadata.reciprocalCameraCentersInReference,
        floorValue: metadata.floorValue,
        selectedFloor: metadata.selectedFloor,
        certifiedWalls: metadata.certifiedWalls,
        reciprocalOptions: metadata.reciprocalOptions,
        localManifoldOptions: metadata.localManifoldOptions,
      ),
      runner: precomputed,
    );
  }

  /// Bounded concurrency contract for isolate-backed workers. Product defaults
  /// to the serial [execute] path; callers may opt into at most four isolated
  /// reference workers after measuring device memory. Results retain input
  /// order and the first error is propagated.
  static Future<List<T>> executeBounded<T>({
    required List<BcdDetectorFreeScheduledReference> items,
    required int maximumConcurrentReferences,
    required Future<T> Function(BcdDetectorFreeScheduledReference item) execute,
  }) async {
    if (maximumConcurrentReferences <= 0 || maximumConcurrentReferences > 4) {
      throw ArgumentError('invalid detector-free reference concurrency');
    }
    if (items.isEmpty) return List<T>.unmodifiable(const []);
    final results = List<T?>.filled(items.length, null);
    var nextIndex = 0;
    Object? firstError;
    StackTrace? firstStack;

    Future<void> worker() async {
      while (firstError == null) {
        final index = nextIndex++;
        if (index >= items.length) {
          return;
        }
        try {
          results[index] = await execute(items[index]);
        } catch (error, stackTrace) {
          firstError ??= error;
          firstStack ??= stackTrace;
        }
      }
    }

    await Future.wait([
      for (
        var index = 0;
        index < maximumConcurrentReferences && index < items.length;
        index++
      )
        worker(),
    ]);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStack!);
    }
    return List<T>.unmodifiable(results.cast<T>());
  }

  static void _validateBound(
    BcdDetectorFreeDepthJob job,
    int maximumDepthJobPixels,
  ) {
    final options = job.options;
    options.validate();
    job.refineOptions?.validate();
    final pixels = job.options.imageWidth * job.options.imageHeight;
    if (pixels > maximumDepthJobPixels ||
        options.imageWidth > 8192 ||
        options.imageHeight > 8192 ||
        options.depthCount > 64 ||
        options.patchN > 5 ||
        options.nccMin < 0 ||
        options.exclusionRadiusSamples >= options.depthCount ||
        job.grayFrames.length != pixels * (options.sourceCount + 1) ||
        job.sourceProjections.length != options.sourceCount * 12 ||
        job.grayFrames.any((value) => !value.isFinite) ||
        job.sourceProjections.any((value) => !value.isFinite)) {
      throw StateError(
        'builder emitted malformed or oversized '
        '${job.options.imageWidth}x${job.options.imageHeight} depth job; '
        'scheduler bound is $maximumDepthJobPixels pixels',
      );
    }
  }

  static void _validateDescriptorBound(
    BcdDetectorFreeDepthJobDescriptor descriptor,
    int maximumDepthJobPixels,
  ) {
    final options = descriptor.options;
    options.validate();
    descriptor.refineOptions?.validate();
    final pixels = options.imageWidth * options.imageHeight;
    if (pixels > maximumDepthJobPixels ||
        descriptor.sourceFrameIds.length != options.sourceCount ||
        descriptor.grayPlaneDigests.length != options.sourceCount + 1 ||
        descriptor.grayPlaneDigests.any((digest) => digest.isEmpty) ||
        descriptor.sourceProjections.length != options.sourceCount * 12 ||
        descriptor.sourceProjections.any((value) => !value.isFinite) ||
        descriptor.canonicalDigest.isEmpty) {
      throw StateError(
        'builder planned malformed or oversized ${options.imageWidth}x'
        '${options.imageHeight} depth job; scheduler bound is '
        '$maximumDepthJobPixels pixels',
      );
    }
  }
}

class _ScheduledDepthJob {
  const _ScheduledDepthJob({required this.reciprocalIndex, required this.key});

  final int? reciprocalIndex;
  final String key;
}

class _DepthJobTemplate {
  const _DepthJobTemplate({
    required this.options,
    required this.sourceProjections,
    required this.aggregation,
    required this.refineOptions,
  });

  factory _DepthJobTemplate.fromDescriptor(
    BcdDetectorFreeDepthJobDescriptor descriptor,
  ) => _DepthJobTemplate(
    options: descriptor.options,
    sourceProjections: Float32List.fromList(descriptor.sourceProjections),
    aggregation: descriptor.aggregation,
    refineOptions: descriptor.refineOptions,
  );

  final DetectorFreeDepthOptions options;
  final Float32List sourceProjections;
  final DetectorFreeViewAggregation aggregation;
  final DetectorFreeRefineOptions? refineOptions;

  BcdDetectorFreeDepthJob proxy(Map<int, Float32List> zeroGrayByLength) {
    final length =
        options.imageWidth * options.imageHeight * (options.sourceCount + 1);
    return BcdDetectorFreeDepthJob(
      options: options,
      grayFrames: zeroGrayByLength.putIfAbsent(
        length,
        () => Float32List(length),
      ),
      sourceProjections: sourceProjections,
      aggregation: aggregation,
      refineOptions: refineOptions,
    );
  }
}

class _PrecomputedDepthRunner implements BcdDetectorFreeDepthRunner {
  const _PrecomputedDepthRunner({
    required this.delegate,
    required this.mapsByJob,
  });

  final BcdDetectorFreeDepthRunner delegate;
  final Map<BcdDetectorFreeDepthJob, BcdDetectorFreeDepthMap> mapsByJob;

  @override
  BcdDetectorFreeDepthMap runDepth(BcdDetectorFreeDepthJob job) {
    final map = mapsByJob[job];
    if (map == null) {
      throw StateError('missing precomputed detector-free depth');
    }
    return map;
  }

  @override
  DetectorFreeReciprocalBirthResult filterReciprocal(
    BcdDetectorFreeReciprocalInput input,
  ) => delegate.filterReciprocal(input);
}

String _descriptorKey({
  required String captureDigest,
  required String backendAbi,
  required bool certifiedProduct,
  required BcdDetectorFreeDepthJobDescriptor descriptor,
}) {
  return sha256
      .convert(
        utf8.encode(
          'pocketworld-d-depth-cache-v1\u0000$captureDigest\u0000'
          '$backendAbi\u0000${certifiedProduct ? 'certified' : 'experimental'}'
          '\u0000${descriptor.canonicalDigest}',
        ),
      )
      .toString();
}

String _fullScenePlanDigest({
  required String captureDigest,
  required String backendAbi,
  required bool certifiedProduct,
  required List<BcdDetectorFreeScheduledReference> references,
}) => sha256
    .convert(
      utf8.encode(
        <String>[
          'pocketworld-d-full-scene-plan-v1',
          captureDigest,
          backendAbi,
          certifiedProduct ? 'certified' : 'experimental',
          for (final reference in references)
            reference.isSkipped
                ? 'skip:${reference.referenceFrameId}:'
                      '${reference.skipped!.reason.index}'
                : 'ready:${reference.referenceFrameId}:'
                      '${reference.depthJobKeys.join(',')}',
        ].join('\u0000'),
      ),
    )
    .toString();
