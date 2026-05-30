import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

abstract class VisualLoopRetrievalExecutor {
  const VisualLoopRetrievalExecutor();

  Future<VisualLoopRetrievalReport> retrieve(
    VisualLoopRetrievalRequest request,
  );
}

final class VisualLoopRetrievalRequest {
  const VisualLoopRetrievalRequest({
    required this.captureDir,
    required this.depthOutputDir,
    required this.kWindowGraph,
    required this.windowReports,
  });

  final Directory captureDir;
  final Directory depthOutputDir;
  final Map<String, Object?> kWindowGraph;
  final List<Map<String, Object?>> windowReports;
}

final class VisualLoopRetrievalReport {
  const VisualLoopRetrievalReport({
    required this.status,
    required this.executor,
    required this.policy,
    required this.candidates,
  });

  final String status;
  final String executor;
  final Map<String, Object?> policy;
  final List<Map<String, Object?>> candidates;

  Map<String, Object?> toJson() => {
    'schema_version': 'aether_visual_loop_retrieval_report_v1',
    'status': status,
    'executor': executor,
    'policy': policy,
    'candidates': candidates,
    'candidate_count': candidates.length,
  };
}

final class ContractOnlyVisualLoopRetrievalExecutor
    extends VisualLoopRetrievalExecutor {
  const ContractOnlyVisualLoopRetrievalExecutor();

  @override
  Future<VisualLoopRetrievalReport> retrieve(
    VisualLoopRetrievalRequest request,
  ) async {
    final candidates = [
      for (final candidate in _maps(request.kWindowGraph['loop_candidates']))
        {
          'sourceWindowID': _asString(candidate['sourceWindowID']),
          'targetWindowID': _asString(candidate['targetWindowID']),
          'status': 'waiting_for_descriptor_backend',
          'poseGraphCrossScore': _nullableDouble(
            candidate['poseGraphCrossScore'],
          ),
          'sharedFrameIDs': _strings(candidate['sharedFrameIDs']),
          'reason':
              'VisualLoopRetrievalExecutor is intentionally abstract; production must use a commercial-safe descriptor backend',
        }..removeWhere((_, value) => value == null),
    ];

    return VisualLoopRetrievalReport(
      status: 'not_configured',
      executor: 'VisualLoopRetrievalExecutor',
      policy: const {
        'descriptorBackend': 'pluggable',
        'productionLicenseRule': 'Apache-2.0/MIT/BSD or owned code only',
        'blockedBundledBackends': ['GPL-3.0 SALAD reference implementation'],
        'researchOnlyBackends': ['SALAD/DINOv2-SALAD on Mac benchmark path'],
        'acceptanceRule':
            'visual retrieval may propose loop candidates, but dense Sim3 must verify every accepted loop edge',
      },
      candidates: candidates,
    );
  }
}

abstract class DenseSim3Verifier {
  const DenseSim3Verifier();

  Future<DenseSim3VerificationReport> verify(
    DenseSim3VerificationRequest request,
  );
}

final class DenseSim3VerificationRequest {
  const DenseSim3VerificationRequest({
    required this.captureDir,
    required this.depthOutputDir,
    required this.kWindowGraph,
    required this.windowReports,
    required this.visualLoopRetrievalReport,
  });

  final Directory captureDir;
  final Directory depthOutputDir;
  final Map<String, Object?> kWindowGraph;
  final List<Map<String, Object?>> windowReports;
  final Map<String, Object?> visualLoopRetrievalReport;
}

final class DenseSim3VerificationReport {
  const DenseSim3VerificationReport({
    required this.status,
    required this.method,
    required this.bridgeEdges,
    required this.loopEdges,
    required this.streamingAlignment,
    required this.counts,
    required this.thresholds,
    required this.performance,
  });

  final String status;
  final String method;
  final List<Map<String, Object?>> bridgeEdges;
  final List<Map<String, Object?>> loopEdges;
  final Map<String, Object?> streamingAlignment;
  final Map<String, Object?> counts;
  final Map<String, Object?> thresholds;
  final Map<String, Object?> performance;

  Map<String, Object?> toJson() => {
    'schema_version': 'aether_dense_sim3_verification_report_v1',
    'status': status,
    'method': method,
    'thresholds': thresholds,
    'performance': performance,
    'counts': counts,
    'bridge_edges': bridgeEdges,
    'loop_edges': loopEdges,
    'streaming_alignment': streamingAlignment,
  };
}

final class DartDenseSim3Verifier extends DenseSim3Verifier {
  const DartDenseSim3Verifier({
    this.maxPointsPerFrame = 2048,
    this.minSharedFrames = 3,
    this.minPointCount = 96,
    this.confidenceThresholdRatio = 0.10,
    this.huberDelta = 0.10,
    this.robustMaxIters = 5,
    this.inlierThresholdRatio = 0.10,
  });

  final int maxPointsPerFrame;
  final int minSharedFrames;
  final int minPointCount;
  final double confidenceThresholdRatio;
  final double huberDelta;
  final int robustMaxIters;
  final double inlierThresholdRatio;

  @override
  Future<DenseSim3VerificationReport> verify(
    DenseSim3VerificationRequest request,
  ) async {
    final stopwatch = Stopwatch()..start();
    final tensorCache = _FloatTensorCache();
    final windowsByID = <String, Map<String, Object?>>{
      for (final window in request.windowReports)
        _asString(window['windowID']): window,
    }..removeWhere((key, _) => key.isEmpty);

    final bridgeEdges = <Map<String, Object?>>[];
    for (final edge in _maps(request.kWindowGraph['bridge_graph'])) {
      bridgeEdges.add(
        await _verifyWindowPair(
          request: request,
          windowsByID: windowsByID,
          sourceWindowID: _asString(edge['sourceWindowID']),
          targetWindowID: _asString(edge['targetWindowID']),
          kind: _asString(edge['kind'], fallback: 'tree_bridge'),
          requestedSharedFrameIDs: _strings(edge['bridgeFrameIDs']),
          visualStatus: 'not_required_for_tree_bridge',
          tensorCache: tensorCache,
        ),
      );
    }

    final loopEdges = <Map<String, Object?>>[];
    final visualAcceptedPairs = _visualAcceptedPairs(
      request.visualLoopRetrievalReport,
    );
    for (final candidate in _maps(request.kWindowGraph['loop_candidates'])) {
      final sourceWindowID = _asString(candidate['sourceWindowID']);
      final targetWindowID = _asString(candidate['targetWindowID']);
      final pairKey = _pairKey(sourceWindowID, targetWindowID);
      if (!visualAcceptedPairs.contains(pairKey)) {
        loopEdges.add({
          'sourceWindowID': sourceWindowID,
          'targetWindowID': targetWindowID,
          'kind': 'loop_candidate',
          'status': 'waiting_for_visual_retrieval',
          'visualStatus': 'not_accepted',
          'reason':
              'loop edges are not sent to dense Sim3 until a commercial-safe visual retrieval backend proposes the pair',
          'sharedFrameIDs': _strings(candidate['sharedFrameIDs']),
        });
        continue;
      }
      loopEdges.add(
        await _verifyWindowPair(
          request: request,
          windowsByID: windowsByID,
          sourceWindowID: sourceWindowID,
          targetWindowID: targetWindowID,
          kind: 'loop_candidate',
          requestedSharedFrameIDs: _strings(candidate['sharedFrameIDs']),
          visualStatus: 'accepted',
          tensorCache: tensorCache,
        ),
      );
    }

    final acceptedBridge = bridgeEdges
        .where((edge) => edge['status'] == 'accepted')
        .length;
    final rejectedBridge = bridgeEdges
        .where((edge) => edge['status'] == 'rejected')
        .length;
    final inconclusiveBridge = bridgeEdges
        .where((edge) => edge['status'] == 'inconclusive')
        .length;
    final pendingBridge = bridgeEdges
        .where((edge) => edge['status'] == 'pending')
        .length;
    final status = rejectedBridge > 0
        ? 'failed'
        : (inconclusiveBridge + pendingBridge > 0 ? 'inconclusive' : 'passed');
    final streamingAlignment = _buildStreamingAlignment(
      request: request,
      windowsByID: windowsByID,
      bridgeEdges: bridgeEdges,
      loopEdges: loopEdges,
    );

    return DenseSim3VerificationReport(
      status: status,
      method: 'official_streaming_weighted_point_map_sim3_dart_v1',
      thresholds: {
        'minSharedFrames': minSharedFrames,
        'minPointCount': minPointCount,
        'confidenceThresholdRatio': confidenceThresholdRatio,
        'huberDelta': huberDelta,
        'robustMaxIters': robustMaxIters,
        'inlierThresholdRatio': inlierThresholdRatio,
        'maxPointsPerFrame': maxPointsPerFrame,
        'acceptanceRule':
            'DA3-Streaming-style tree bridges are accepted when a finite confidence-weighted robust Sim3 can be estimated from enough overlapping point-map samples; residuals are diagnostics, not a hard official rejection threshold.',
      },
      performance: {
        'elapsedMs': stopwatch.elapsedMilliseconds,
        'tensorReadMode':
            'lazy_little_endian_float32_cache_official_style_point_map_sampling',
        'fullTensorListMaterialization': false,
        ...tensorCache.toJson(),
      },
      streamingAlignment: streamingAlignment,
      counts: {
        'bridge_total': bridgeEdges.length,
        'bridge_accepted': acceptedBridge,
        'bridge_rejected': rejectedBridge,
        'bridge_inconclusive': inconclusiveBridge,
        'bridge_pending': pendingBridge,
        'loop_total': loopEdges.length,
        'loop_waiting_visual_retrieval': loopEdges
            .where((edge) => edge['status'] == 'waiting_for_visual_retrieval')
            .length,
      },
      bridgeEdges: bridgeEdges,
      loopEdges: loopEdges,
    );
  }

  Future<Map<String, Object?>> _verifyWindowPair({
    required DenseSim3VerificationRequest request,
    required Map<String, Map<String, Object?>> windowsByID,
    required String sourceWindowID,
    required String targetWindowID,
    required String kind,
    required List<String> requestedSharedFrameIDs,
    required String visualStatus,
    required _FloatTensorCache tensorCache,
  }) async {
    final edgeStopwatch = Stopwatch()..start();
    final sourceWindow = windowsByID[sourceWindowID];
    final targetWindow = windowsByID[targetWindowID];
    if (sourceWindow == null || targetWindow == null) {
      return {
        'sourceWindowID': sourceWindowID,
        'targetWindowID': targetWindowID,
        'kind': kind,
        'status': 'pending',
        'visualStatus': visualStatus,
        'reason': 'missing window report for one side of the edge',
      };
    }

    final sourceFrames = _framesByID(sourceWindow);
    final targetFrames = _framesByID(targetWindow);
    final sharedFrameIDs = requestedSharedFrameIDs.isNotEmpty
        ? requestedSharedFrameIDs
        : sourceFrames.keys
              .toSet()
              .intersection(targetFrames.keys.toSet())
              .toList(growable: false);
    final pairs = <_PointPair>[];
    final usedFrames = <String>[];
    final issues = <String>[];

    for (final frameID in sharedFrameIDs) {
      final sourceFrame = sourceFrames[frameID];
      final targetFrame = targetFrames[frameID];
      if (sourceFrame == null || targetFrame == null) {
        issues.add('shared frame $frameID missing from a window report');
        continue;
      }
      final before = pairs.length;
      try {
        pairs.addAll(
          await _sampleDensePairs(
            depthOutputDir: request.depthOutputDir,
            sourceFrame: sourceFrame,
            targetFrame: targetFrame,
            tensorCache: tensorCache,
          ),
        );
      } on Object catch (e) {
        issues.add('shared frame $frameID skipped: $e');
      }
      if (pairs.length > before) usedFrames.add(frameID);
    }

    if (usedFrames.length < minSharedFrames || pairs.length < minPointCount) {
      return {
        'sourceWindowID': sourceWindowID,
        'targetWindowID': targetWindowID,
        'kind': kind,
        'status': 'inconclusive',
        'visualStatus': visualStatus,
        'method': 'official_streaming_weighted_point_map_sim3_dart_v1',
        'reason':
            'not enough shared dense geometry to estimate a reliable Sim3',
        'requestedSharedFrameIDs': sharedFrameIDs,
        'usedSharedFrameIDs': usedFrames,
        'usedSharedFrameCount': usedFrames.length,
        'pointCount': pairs.length,
        'elapsedMs': edgeStopwatch.elapsedMilliseconds,
        'issues': issues,
      };
    }

    final sim3 = _estimateSim3(pairs);
    final accepted = sim3.isFiniteEstimate;
    return {
      'sourceWindowID': sourceWindowID,
      'targetWindowID': targetWindowID,
      'kind': kind,
      'status': accepted ? 'accepted' : 'rejected',
      'visualStatus': visualStatus,
      'method': 'official_streaming_weighted_point_map_sim3_dart_v1',
      'officialBasis':
          'Depth-Anything-3 da3_streaming aligns adjacent chunks by depth+intrinsics+w2c-extrinsics point maps, confidence weighting, and robust Sim3; this Dart verifier mirrors that contract with bounded sampling for mobile logs.',
      'transformDirection': 'target_window_to_source_window',
      'requestedSharedFrameIDs': sharedFrameIDs,
      'usedSharedFrameIDs': usedFrames,
      'usedSharedFrameCount': usedFrames.length,
      'pointCount': pairs.length,
      'elapsedMs': edgeStopwatch.elapsedMilliseconds,
      'sim3': sim3.toJson(),
      'issues': issues,
    };
  }

  Future<List<_PointPair>> _sampleDensePairs({
    required Directory depthOutputDir,
    required Map<String, Object?> sourceFrame,
    required Map<String, Object?> targetFrame,
    required _FloatTensorCache tensorCache,
  }) async {
    final width =
        _nullableInt(sourceFrame['depthWidth']) ??
        _nullableInt(targetFrame['depthWidth']) ??
        0;
    final height =
        _nullableInt(sourceFrame['depthHeight']) ??
        _nullableInt(targetFrame['depthHeight']) ??
        0;
    if (width <= 0 || height <= 0) {
      throw const FormatException('missing positive depthWidth/depthHeight');
    }

    final sourceDepth = await tensorCache.read(
      _resolveRelativeFile(depthOutputDir, sourceFrame['relativeDepthPath']),
    );
    final targetDepth = await tensorCache.read(
      _resolveRelativeFile(depthOutputDir, targetFrame['relativeDepthPath']),
    );
    final sourceConf = await tensorCache.read(
      _resolveRelativeFile(depthOutputDir, sourceFrame['confidencePath']),
    );
    final targetConf = await tensorCache.read(
      _resolveRelativeFile(depthOutputDir, targetFrame['confidencePath']),
    );
    final sourcePose = await tensorCache.readFloatList(
      _resolveRelativeFile(depthOutputDir, sourceFrame['predExtrinsicsPath']),
    );
    final targetPose = await tensorCache.readFloatList(
      _resolveRelativeFile(depthOutputDir, targetFrame['predExtrinsicsPath']),
    );
    final sourceIntrinsics = await tensorCache.readFloatList(
      _resolveRelativeFile(depthOutputDir, sourceFrame['predIntrinsicsPath']),
    );
    final targetIntrinsics = await tensorCache.readFloatList(
      _resolveRelativeFile(depthOutputDir, targetFrame['predIntrinsicsPath']),
    );

    final pixelCount = width * height;
    if (sourceDepth.length < pixelCount ||
        targetDepth.length < pixelCount ||
        sourceConf.length < pixelCount ||
        targetConf.length < pixelCount) {
      throw FormatException(
        'depth/conf tensor shorter than $width x $height pixels',
      );
    }
    final step = math.max(
      4,
      math.sqrt(pixelCount / math.max(1, maxPointsPerFrame)).floor(),
    );
    final sourceCamera = _CameraProjector(
      intrinsics: sourceIntrinsics,
      extrinsics: sourcePose,
    );
    final targetCamera = _CameraProjector(
      intrinsics: targetIntrinsics,
      extrinsics: targetPose,
    );
    final pairs = <_PointPair>[];
    final start = math.max(1, step ~/ 2);
    final sourceConfSamples = <double>[];
    final targetConfSamples = <double>[];
    for (var y = start; y < height; y += step) {
      for (var x = start; x < width; x += step) {
        final idx = y * width + x;
        final sourceC = sourceConf.floatAt(idx);
        final targetC = targetConf.floatAt(idx);
        if (sourceC.isFinite && sourceC > 0) sourceConfSamples.add(sourceC);
        if (targetC.isFinite && targetC > 0) targetConfSamples.add(targetC);
      }
    }
    final confidenceThreshold = math.max(
      1e-6,
      math.min(_median(sourceConfSamples), _median(targetConfSamples)) *
          confidenceThresholdRatio,
    );
    for (var y = start; y < height; y += step) {
      for (var x = start; x < width; x += step) {
        final idx = y * width + x;
        final sourceZ = sourceDepth.floatAt(idx);
        final targetZ = targetDepth.floatAt(idx);
        final sourceC = sourceConf.floatAt(idx);
        final targetC = targetConf.floatAt(idx);
        if (!_finitePositive(sourceZ) ||
            !_finitePositive(targetZ) ||
            !sourceC.isFinite ||
            !targetC.isFinite ||
            sourceC <= confidenceThreshold ||
            targetC <= confidenceThreshold) {
          continue;
        }
        pairs.add(
          _PointPair(
            source: sourceCamera.unprojectToWorld(x, y, sourceZ),
            target: targetCamera.unprojectToWorld(x, y, targetZ),
            weight: math.sqrt(sourceC * targetC),
          ),
        );
      }
    }
    return pairs;
  }

  _Sim3Estimate _estimateSim3(List<_PointPair> pairs) {
    var weights = [for (final pair in pairs) math.max(1e-9, pair.weight)];
    var estimate = _estimateWeightedSim3(pairs, weights);
    for (var i = 0; i < robustMaxIters; i += 1) {
      final residuals = _residuals(pairs, estimate);
      final robustWeights = <double>[];
      for (var j = 0; j < residuals.length; j += 1) {
        final residual = residuals[j];
        final huberWeight = residual <= huberDelta
            ? 1.0
            : huberDelta / math.max(residual, 1e-12);
        robustWeights.add(math.max(1e-12, pairs[j].weight * huberWeight));
      }
      final next = _estimateWeightedSim3(pairs, robustWeights);
      final change =
          (next.scale - estimate.scale).abs() +
          (next.translation - estimate.translation).norm;
      estimate = next;
      weights = robustWeights;
      if (change < 1e-9) break;
    }
    return _estimateWeightedSim3(pairs, weights);
  }

  _Sim3Estimate _estimateWeightedSim3(
    List<_PointPair> pairs,
    List<double> weights,
  ) {
    final totalWeight = weights.fold<double>(0, (sum, value) => sum + value);
    if (totalWeight <= 1e-12) {
      return _Sim3Estimate.invalid();
    }

    var sourceCentroid = _Vec3.zero();
    var targetCentroid = _Vec3.zero();
    for (var i = 0; i < pairs.length; i += 1) {
      final weight = weights[i] / totalWeight;
      sourceCentroid += pairs[i].source * weight;
      targetCentroid += pairs[i].target * weight;
    }

    var sxx = 0.0;
    var sxy = 0.0;
    var sxz = 0.0;
    var syx = 0.0;
    var syy = 0.0;
    var syz = 0.0;
    var szx = 0.0;
    var szy = 0.0;
    var szz = 0.0;
    var targetVariance = 0.0;
    var sourceVariance = 0.0;
    for (var i = 0; i < pairs.length; i += 1) {
      final pair = pairs[i];
      final weight = weights[i] / totalWeight;
      final p = pair.target - targetCentroid;
      final q = pair.source - sourceCentroid;
      sxx += weight * p.x * q.x;
      sxy += weight * p.x * q.y;
      sxz += weight * p.x * q.z;
      syx += weight * p.y * q.x;
      syy += weight * p.y * q.y;
      syz += weight * p.y * q.z;
      szx += weight * p.z * q.x;
      szy += weight * p.z * q.y;
      szz += weight * p.z * q.z;
      targetVariance += weight * p.dot(p);
      sourceVariance += weight * q.dot(q);
    }

    final rotation = _rotationFromCrossCovariance(
      sxx: sxx,
      sxy: sxy,
      sxz: sxz,
      syx: syx,
      syy: syy,
      syz: syz,
      szx: szx,
      szy: szy,
      szz: szz,
    );
    final scale = targetVariance <= 1e-12
        ? 1.0
        : math.sqrt(math.max(1e-12, sourceVariance / targetVariance));
    final translation =
        sourceCentroid - (rotation.transform(targetCentroid) * scale);

    final residuals = _residuals(
      pairs,
      _Sim3Estimate.raw(
        scale: scale,
        rotation: rotation,
        translation: translation,
      ),
    );
    residuals.sort();
    final rmse = math.sqrt(
      residuals.fold<double>(0, (sum, value) => sum + value * value) /
          math.max(1, residuals.length),
    );
    final p90Index = (residuals.length * 0.90)
        .floor()
        .clamp(0, residuals.length - 1)
        .toInt();
    final p90 = residuals[p90Index];
    final sceneScale = math.max(1e-9, math.sqrt(sourceVariance));
    final inlierThreshold = math.max(1e-6, sceneScale * inlierThresholdRatio);
    final inlierRatio =
        residuals.where((value) => value <= inlierThreshold).length /
        math.max(1, residuals.length);

    return _Sim3Estimate(
      scale: scale,
      rotation: rotation,
      translation: translation,
      rmse: rmse,
      p90: p90,
      normalizedRmse: rmse / sceneScale,
      normalizedP90: p90 / sceneScale,
      inlierRatio: inlierRatio,
      inlierThreshold: inlierThreshold,
      sceneScale: sceneScale,
    );
  }

  List<double> _residuals(List<_PointPair> pairs, _Sim3Estimate sim3) {
    return [
      for (final pair in pairs)
        (sim3.rotation.transform(pair.target) * sim3.scale +
                sim3.translation -
                pair.source)
            .norm,
    ];
  }

  Map<String, Object?> _buildStreamingAlignment({
    required DenseSim3VerificationRequest request,
    required Map<String, Map<String, Object?>> windowsByID,
    required List<Map<String, Object?>> bridgeEdges,
    required List<Map<String, Object?>> loopEdges,
  }) {
    final windowIDs = windowsByID.keys.toList(growable: false)..sort();
    final acceptedBridgeEdges = [
      for (final edge in bridgeEdges)
        if (_asString(edge['status']) == 'accepted') edge,
    ];
    final acceptedLoopEdges = [
      for (final edge in loopEdges)
        if (_asString(edge['status']) == 'accepted') edge,
    ];
    final incomingTargets = {
      for (final edge in acceptedBridgeEdges) _asString(edge['targetWindowID']),
    }..remove('');
    final rootWindowIDs = [
      for (final id in windowIDs)
        if (!incomingTargets.contains(id)) id,
    ];
    if (rootWindowIDs.isEmpty && windowIDs.isNotEmpty) {
      rootWindowIDs.add(windowIDs.first);
    }

    final transforms = <String, _Sim3Transform>{};
    final transformSource = <String, String>{};
    for (final rootID in rootWindowIDs) {
      transforms[rootID] = _Sim3Transform.identity();
      transformSource[rootID] = 'root_identity';
    }

    final pending = acceptedBridgeEdges.toList(growable: true);
    var changed = true;
    while (changed && pending.isNotEmpty) {
      changed = false;
      for (var i = pending.length - 1; i >= 0; i -= 1) {
        final edge = pending[i];
        final sourceWindowID = _asString(edge['sourceWindowID']);
        final targetWindowID = _asString(edge['targetWindowID']);
        final sourceToRoot = transforms[sourceWindowID];
        final targetToSource = _Sim3Transform.fromJson(edge['sim3']);
        if (sourceToRoot == null || targetToSource == null) continue;

        transforms[targetWindowID] = sourceToRoot.compose(targetToSource);
        transformSource[targetWindowID] =
            'bridge:$sourceWindowID->$targetWindowID';
        pending.removeAt(i);
        changed = true;
      }
    }

    final unalignedWindowIDs = [
      for (final id in windowIDs)
        if (!transforms.containsKey(id)) id,
    ];
    final rejectedBridgeCount = bridgeEdges
        .where((edge) => _asString(edge['status']) == 'rejected')
        .length;
    final inconclusiveBridgeCount = bridgeEdges
        .where((edge) => _asString(edge['status']) == 'inconclusive')
        .length;
    final pendingBridgeCount = bridgeEdges
        .where((edge) => _asString(edge['status']) == 'pending')
        .length;
    final status =
        unalignedWindowIDs.isEmpty &&
            rejectedBridgeCount == 0 &&
            inconclusiveBridgeCount == 0 &&
            pendingBridgeCount == 0
        ? 'ready_for_downstream_application'
        : 'incomplete';

    return {
      'schema_version': 'aether_da3_streaming_alignment_v1',
      'status': status,
      'officialBasis':
          'Depth-Anything-3 da3_streaming accumulates adjacent chunk Sim3 transforms with accumulate_sim3_transforms, then applies the cumulative transform to later chunk point maps and camera poses.',
      'localAdaptation':
          'The official temporal chunk chain is applied to our DA3 K-window bridge tree: every accepted bridge transform maps target_window_to_source_window, then transforms are composed to produce window_to_root Sim3.',
      'transformDirection': 'window_to_root_window',
      'rootWindowIDs': rootWindowIDs,
      'windowCount': windowIDs.length,
      'alignedWindowCount': transforms.length,
      'unalignedWindowIDs': unalignedWindowIDs,
      'bridgeTransformDirection': 'target_window_to_source_window',
      'acceptedBridgeCount': acceptedBridgeEdges.length,
      'acceptedLoopConstraintCount': acceptedLoopEdges.length,
      'loopOptimizer': {
        'officialReference':
            'DA3-Streaming runs Sim3LoopOptimizer only after visual loop retrieval proposes loop edges and dense Sim3 estimates loop constraints.',
        'status': acceptedLoopEdges.isEmpty
            ? 'not_run_no_dense_verified_loop_constraints'
            : 'pending_flutter_port',
        'acceptedLoopConstraintCount': acceptedLoopEdges.length,
      },
      'downstreamApplication': {
        'status': 'reported_for_pointcloud_mesh_consumers',
        'requiredRule':
            'Downstream point cloud, mesh, texture, and highlight geometry must consume window_to_root_sim3 before mixing outputs from different DA3 windows.',
      },
      'windowTransforms': [
        for (final id in windowIDs)
          {
            'windowID': id,
            'status': transforms.containsKey(id) ? 'aligned' : 'unaligned',
            'source': transformSource[id],
            if (transforms[id] != null) 'sim3': transforms[id]!.toJson(),
          }..removeWhere((_, value) => value == null),
      ],
      'unconsumedAcceptedBridgeEdges': [
        for (final edge in pending)
          {
            'sourceWindowID': _asString(edge['sourceWindowID']),
            'targetWindowID': _asString(edge['targetWindowID']),
            'reason': 'source window has no path to a root transform',
          },
      ],
    };
  }
}

final class _Sim3Transform {
  const _Sim3Transform({
    required this.scale,
    required this.rotation,
    required this.translation,
  });

  factory _Sim3Transform.identity() => const _Sim3Transform(
    scale: 1,
    rotation: _Mat3([1, 0, 0, 0, 1, 0, 0, 0, 1]),
    translation: _Vec3.zero(),
  );

  final double scale;
  final _Mat3 rotation;
  final _Vec3 translation;

  _Sim3Transform compose(_Sim3Transform childToThis) {
    final rotationComposed = _matMul(rotation, childToThis.rotation);
    final translationComposed =
        rotation.transform(childToThis.translation) * scale + translation;
    return _Sim3Transform(
      scale: scale * childToThis.scale,
      rotation: rotationComposed,
      translation: translationComposed,
    );
  }

  Map<String, Object?> toJson() => {
    'scale': scale,
    'rotationRowMajor3x3': rotation.m,
    'translation': translation.toJson(),
    'matrixRowMajor4x4': [
      rotation.m[0] * scale,
      rotation.m[1] * scale,
      rotation.m[2] * scale,
      translation.x,
      rotation.m[3] * scale,
      rotation.m[4] * scale,
      rotation.m[5] * scale,
      translation.y,
      rotation.m[6] * scale,
      rotation.m[7] * scale,
      rotation.m[8] * scale,
      translation.z,
      0,
      0,
      0,
      1,
    ],
  };

  static _Sim3Transform? fromJson(Object? value) {
    if (value is! Map) return null;
    final map = value.cast<String, Object?>();
    final scale = _nullableDouble(map['scale']);
    final rotation = _doubleList(map['rotationRowMajor3x3']);
    final translation = _doubleList(map['translation']);
    if (scale == null ||
        rotation.length != 9 ||
        translation.length != 3 ||
        !scale.isFinite ||
        rotation.any((value) => !value.isFinite) ||
        translation.any((value) => !value.isFinite)) {
      return null;
    }
    return _Sim3Transform(
      scale: scale,
      rotation: _Mat3(rotation),
      translation: _Vec3(translation[0], translation[1], translation[2]),
    );
  }
}

final class _CameraProjector {
  _CameraProjector({
    required List<double> intrinsics,
    required List<double> extrinsics,
  }) : fx = _safeFocal(intrinsics, 0),
       fy = _safeFocal(intrinsics, 4),
       cx = intrinsics.length > 2 ? intrinsics[2] : 0.0,
       cy = intrinsics.length > 5 ? intrinsics[5] : 0.0,
       pose = _Pose3x4(extrinsics);

  final double fx;
  final double fy;
  final double cx;
  final double cy;
  final _Pose3x4 pose;

  _Vec3 unprojectToWorld(int x, int y, double depth) {
    final px = (x.toDouble() - cx) / fx * depth;
    final py = (y.toDouble() - cy) / fy * depth;
    return pose.cameraToWorld(_Vec3(px, py, depth));
  }

  static double _safeFocal(List<double> values, int index) {
    if (values.length > index && values[index].abs() > 1e-9) {
      return values[index];
    }
    return 1.0;
  }
}

final class _Pose3x4 {
  _Pose3x4(List<double> values)
    : m = values.length >= 12
          ? values.take(12).toList(growable: false)
          : const <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0];

  final List<double> m;

  _Vec3 cameraToWorld(_Vec3 p) => _Vec3(
    m[0] * p.x + m[4] * p.y + m[8] * p.z - _dotRowTranslation(0),
    m[1] * p.x + m[5] * p.y + m[9] * p.z - _dotRowTranslation(1),
    m[2] * p.x + m[6] * p.y + m[10] * p.z - _dotRowTranslation(2),
  );

  double _dotRowTranslation(int worldAxis) =>
      m[worldAxis] * m[3] + m[4 + worldAxis] * m[7] + m[8 + worldAxis] * m[11];
}

final class _Mat3 {
  const _Mat3(this.m);

  final List<double> m;

  _Vec3 transform(_Vec3 p) => _Vec3(
    m[0] * p.x + m[1] * p.y + m[2] * p.z,
    m[3] * p.x + m[4] * p.y + m[5] * p.z,
    m[6] * p.x + m[7] * p.y + m[8] * p.z,
  );
}

final class _Vec3 {
  const _Vec3(this.x, this.y, this.z);
  const _Vec3.zero() : x = 0, y = 0, z = 0;

  final double x;
  final double y;
  final double z;

  _Vec3 operator +(_Vec3 other) => _Vec3(x + other.x, y + other.y, z + other.z);
  _Vec3 operator -(_Vec3 other) => _Vec3(x - other.x, y - other.y, z - other.z);
  _Vec3 operator *(double scalar) => _Vec3(x * scalar, y * scalar, z * scalar);
  _Vec3 operator /(double scalar) => _Vec3(x / scalar, y / scalar, z / scalar);

  double dot(_Vec3 other) => x * other.x + y * other.y + z * other.z;

  double get norm => math.sqrt(dot(this));

  List<double> toJson() => [x, y, z];
}

final class _PointPair {
  const _PointPair({
    required this.source,
    required this.target,
    required this.weight,
  });

  final _Vec3 source;
  final _Vec3 target;
  final double weight;
}

final class _Sim3Estimate {
  const _Sim3Estimate({
    required this.scale,
    required this.rotation,
    required this.translation,
    required this.rmse,
    required this.p90,
    required this.normalizedRmse,
    required this.normalizedP90,
    required this.inlierRatio,
    required this.inlierThreshold,
    required this.sceneScale,
  });

  const _Sim3Estimate.raw({
    required this.scale,
    required this.rotation,
    required this.translation,
  }) : rmse = 0,
       p90 = 0,
       normalizedRmse = 0,
       normalizedP90 = 0,
       inlierRatio = 0,
       inlierThreshold = 0,
       sceneScale = 0;

  _Sim3Estimate.invalid()
    : scale = double.nan,
      rotation = const _Mat3([
        double.nan,
        double.nan,
        double.nan,
        double.nan,
        double.nan,
        double.nan,
        double.nan,
        double.nan,
        double.nan,
      ]),
      translation = const _Vec3(double.nan, double.nan, double.nan),
      rmse = double.nan,
      p90 = double.nan,
      normalizedRmse = double.nan,
      normalizedP90 = double.nan,
      inlierRatio = 0,
      inlierThreshold = double.nan,
      sceneScale = double.nan;

  final double scale;
  final _Mat3 rotation;
  final _Vec3 translation;
  final double rmse;
  final double p90;
  final double normalizedRmse;
  final double normalizedP90;
  final double inlierRatio;
  final double inlierThreshold;
  final double sceneScale;

  bool get isFiniteEstimate =>
      scale.isFinite &&
      rotation.m.every((value) => value.isFinite) &&
      translation.x.isFinite &&
      translation.y.isFinite &&
      translation.z.isFinite &&
      rmse.isFinite &&
      p90.isFinite;

  Map<String, Object?> toJson() => {
    'scale': scale,
    'rotationRowMajor3x3': rotation.m,
    'translation': translation.toJson(),
    'matrixRowMajor4x4': [
      rotation.m[0] * scale,
      rotation.m[1] * scale,
      rotation.m[2] * scale,
      translation.x,
      rotation.m[3] * scale,
      rotation.m[4] * scale,
      rotation.m[5] * scale,
      translation.y,
      rotation.m[6] * scale,
      rotation.m[7] * scale,
      rotation.m[8] * scale,
      translation.z,
      0,
      0,
      0,
      1,
    ],
    'rmse': rmse,
    'p90': p90,
    'normalizedRmse': normalizedRmse,
    'normalizedP90': normalizedP90,
    'inlierRatio': inlierRatio,
    'inlierThreshold': inlierThreshold,
    'sceneScale': sceneScale,
  };
}

_Mat3 _rotationFromCrossCovariance({
  required double sxx,
  required double sxy,
  required double sxz,
  required double syx,
  required double syy,
  required double syz,
  required double szx,
  required double szy,
  required double szz,
}) {
  final trace = sxx + syy + szz;
  final n = <double>[
    trace,
    syz - szy,
    szx - sxz,
    sxy - syx,
    syz - szy,
    sxx - syy - szz,
    sxy + syx,
    szx + sxz,
    szx - sxz,
    sxy + syx,
    -sxx + syy - szz,
    syz + szy,
    sxy - syx,
    szx + sxz,
    syz + szy,
    -sxx - syy + szz,
  ];
  var q = <double>[1, 0, 0, 0];
  for (var i = 0; i < 48; i += 1) {
    final next = <double>[
      n[0] * q[0] + n[1] * q[1] + n[2] * q[2] + n[3] * q[3],
      n[4] * q[0] + n[5] * q[1] + n[6] * q[2] + n[7] * q[3],
      n[8] * q[0] + n[9] * q[1] + n[10] * q[2] + n[11] * q[3],
      n[12] * q[0] + n[13] * q[1] + n[14] * q[2] + n[15] * q[3],
    ];
    final norm = math.sqrt(next.fold<double>(0, (sum, v) => sum + v * v));
    if (norm <= 1e-12) break;
    q = [for (final value in next) value / norm];
  }
  return _quaternionToRotation(q);
}

_Mat3 _quaternionToRotation(List<double> q) {
  final w = q[0];
  final x = q[1];
  final y = q[2];
  final z = q[3];
  return _Mat3([
    1 - 2 * (y * y + z * z),
    2 * (x * y - z * w),
    2 * (x * z + y * w),
    2 * (x * y + z * w),
    1 - 2 * (x * x + z * z),
    2 * (y * z - x * w),
    2 * (x * z - y * w),
    2 * (y * z + x * w),
    1 - 2 * (x * x + y * y),
  ]);
}

_Mat3 _matMul(_Mat3 a, _Mat3 b) {
  final out = List<double>.filled(9, 0);
  for (var row = 0; row < 3; row += 1) {
    for (var col = 0; col < 3; col += 1) {
      out[row * 3 + col] =
          a.m[row * 3] * b.m[col] +
          a.m[row * 3 + 1] * b.m[3 + col] +
          a.m[row * 3 + 2] * b.m[6 + col];
    }
  }
  return _Mat3(out);
}

final class _FloatTensorCache {
  final _cache = <String, _FloatTensor>{};
  int hits = 0;
  int misses = 0;
  int bytesRead = 0;

  Future<_FloatTensor> read(File file) async {
    final path = file.path;
    final cached = _cache[path];
    if (cached != null) {
      hits += 1;
      return cached;
    }
    if (!file.existsSync()) {
      throw FileSystemException('missing float tensor', path);
    }
    final bytes = await file.readAsBytes();
    if (bytes.lengthInBytes % 4 != 0) {
      throw FormatException(
        'float tensor byte length is not divisible by 4: $path',
      );
    }
    final tensor = _FloatTensor(bytes);
    _cache[path] = tensor;
    misses += 1;
    bytesRead += bytes.lengthInBytes;
    return tensor;
  }

  Future<List<double>> readFloatList(File file) async {
    final tensor = await read(file);
    return [for (var i = 0; i < tensor.length; i += 1) tensor.floatAt(i)];
  }

  Map<String, Object?> toJson() => {
    'tensorCacheEntries': _cache.length,
    'tensorCacheHits': hits,
    'tensorCacheMisses': misses,
    'tensorBytesRead': bytesRead,
    'tensorMegabytesRead': bytesRead / (1024 * 1024),
  };
}

final class _FloatTensor {
  _FloatTensor(this.bytes) : data = ByteData.sublistView(bytes);

  final Uint8List bytes;
  final ByteData data;

  int get length => bytes.lengthInBytes ~/ 4;

  double floatAt(int index) => data.getFloat32(index * 4, Endian.little);
}

File _resolveRelativeFile(Directory root, Object? relativePath) {
  final path = _asString(relativePath);
  if (path.isEmpty) {
    throw const FormatException('missing relative tensor path');
  }
  if (path.startsWith('/')) return File(path);
  return File('${root.path}${Platform.pathSeparator}$path');
}

Map<String, Map<String, Object?>> _framesByID(Map<String, Object?> window) {
  final frames = <String, Map<String, Object?>>{};
  for (final frame in _maps(window['frames'])) {
    final id = _asString(frame['frameID']);
    if (id.isEmpty) continue;
    frames.putIfAbsent(id, () => frame);
  }
  return frames;
}

Set<String> _visualAcceptedPairs(Map<String, Object?> report) {
  return {
    for (final candidate in _maps(report['candidates']))
      if (_asString(candidate['status']) == 'accepted')
        _pairKey(
          _asString(candidate['sourceWindowID']),
          _asString(candidate['targetWindowID']),
        ),
  };
}

String _pairKey(String a, String b) {
  return a.compareTo(b) <= 0 ? '$a::$b' : '$b::$a';
}

bool _finitePositive(double value) => value.isFinite && value > 0;

double _median(List<double> values) {
  if (values.isEmpty) return 0;
  values.sort();
  final middle = values.length ~/ 2;
  if (values.length.isOdd) return values[middle];
  return (values[middle - 1] + values[middle]) / 2;
}

List<Map<String, Object?>> _maps(Object? value) {
  if (value is! List) return const <Map<String, Object?>>[];
  return [
    for (final item in value)
      if (item is Map) item.cast<String, Object?>(),
  ];
}

List<String> _strings(Object? value) {
  if (value is! List) return const <String>[];
  return [
    for (final item in value)
      if (item != null && item.toString().isNotEmpty) item.toString(),
  ];
}

List<double> _doubleList(Object? value) {
  if (value is! List) return const <double>[];
  return [
    for (final item in value)
      if (_nullableDouble(item) != null) _nullableDouble(item)!,
  ];
}

String _asString(Object? value, {String fallback = ''}) {
  if (value == null) return fallback;
  final text = value.toString();
  return text.isEmpty ? fallback : text;
}

int? _nullableInt(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '');
}

double? _nullableDouble(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '');
}
