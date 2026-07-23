import 'dart:math' as math;

enum AetherDa3WindowingMode {
  officialStreamingSequential,
  sphericalPoseGraphPatches,
}

final class AetherDa3ModelSpec {
  const AetherDa3ModelSpec({
    required this.id,
    required this.license,
    required this.mobileTag,
    required this.resourceName,
    required this.windowSize,
    this.inputWidth,
    this.inputHeight,
    this.inputSizeStatus = 'not_locked_by_policy',
    this.commercialSafe = true,
  });

  final String id;
  final String license;
  final String mobileTag;
  final String resourceName;
  final int windowSize;
  final int? inputWidth;
  final int? inputHeight;
  final String inputSizeStatus;
  final bool commercialSafe;

  Map<String, Object?> toJson() => {
        'id': id,
        'license': license,
        'mobileTag': mobileTag,
        'resourceName': resourceName,
        'windowSize': windowSize,
        if (inputWidth != null) 'inputWidth': inputWidth,
        if (inputHeight != null) 'inputHeight': inputHeight,
        'inputSizeStatus': inputSizeStatus,
        'commercialSafe': commercialSafe,
      };
}

final class AetherModelPolicy {
  const AetherModelPolicy();

  static const da3BaseK35_476x742 = AetherDa3ModelSpec(
    id: 'DA3-BASE',
    license: 'Apache-2.0',
    mobileTag: 'da3:base:k35:476x742:active',
    resourceName: 'DA3BASE_476x742_N35_pose',
    windowSize: 35,
    inputWidth: 742,
    inputHeight: 476,
    inputSizeStatus: 'locked_da3_base_k35_476x742_benchmark_2026_05_25',
  );

  static const _blockedFragments = <String>[
    'DA3-LARGE',
    'DA3-GIANT',
    'DA3NESTED',
    'DA3-LARGE-1.1',
    'DA3LARGE',
  ];

  AetherDa3ModelSpec resolveDa3Model({
    String? requestedModel,
    String tier = 'high',
  }) {
    final requested = requestedModel?.trim();
    if (requested != null && requested.isNotEmpty) {
      final upper = requested.toUpperCase();
      for (final fragment in _blockedFragments) {
        if (upper.contains(fragment)) {
          throw ArgumentError.value(
            requestedModel,
            'requestedModel',
            'non-commercial DA3 model is not allowed in the product path',
          );
        }
      }
    }
    return da3BaseK35_476x742;
  }

  Map<String, Object?> buildLicenseReport({String tier = 'high'}) {
    final model = resolveDa3Model(tier: tier);
    return {
      'schemaVersion': 'aether_model_policy_v1',
      'status': 'pass',
      'tier': tier,
      'selectedDepthModel': model.toJson(),
      'blockedFamilies': _blockedFragments,
      'rule':
          'Apache-2.0/MIT/BSD only in the local product path; DA3-BASE input is locked to K35@476x742 after the 2026-05-25 benchmark seal',
    };
  }

  Map<String, Object?> buildDa3RuntimeContract({String tier = 'high'}) {
    final model = resolveDa3Model(tier: tier);
    final inputLocked = model.inputWidth != null && model.inputHeight != null;
    return {
      'schemaVersion': 'aether_da3_runtime_contract_v1',
      'owner': 'Flutter/Dart pipeline policy',
      'seal': {
        'date': '2026-05-25',
        'configuration': 'K35@476x742',
        'reason': 'best DA3-BASE geometry after rectangular K/resolution sweep',
      },
      'model': {
        'id': model.id,
        'resourceName': model.resourceName,
        'windowSize': model.windowSize,
        if (model.inputWidth != null) 'inputWidth': model.inputWidth,
        if (model.inputHeight != null) 'inputHeight': model.inputHeight,
        'inputSizeLocked': inputLocked,
        'inputSizeStatus': model.inputSizeStatus,
      },
      'runtimeBoundary': {
        'flutterOwns': [
          'commercial model selection',
          'K-window selection and padding',
          'locked DA3 input dimensions',
          'photos_depth fixed-size cache generation',
          'output naming contract',
          'downstream geometry/highlight handoff',
          'visual loop retrieval executor contract',
          'dense Sim3 geometry verification gate',
        ],
        'nativeAdapterOwns': [
          'platform model loading',
          'fixed-size image decode into the locked tensor',
          'CoreML or platform inference',
          'binary tensor writes',
        ],
      },
      'preprocess': {
        'imageLayout': '1,K,3,H,W',
        'colorSpace': 'sRGB',
        'resize':
            inputLocked ? 'dart_photos_depth_direct_stretch' : 'runtime_policy',
        'normalization': 'imagenet_rgb',
        if (model.inputWidth != null) 'inputWidth': model.inputWidth,
        if (model.inputHeight != null) 'inputHeight': model.inputHeight,
      },
      'inputs': {
        'framesField': 'frames',
        'imagePathField': 'imagePath',
        'cameraTransformField': 'cameraTransform',
        'intrinsicsField': 'intrinsics',
      },
      'outputs': {
        'relativeDepthDir': 'relative_depth',
        'confidenceDir': 'confidence',
        'predPoseDir': 'pred_pose',
        'depthFormat': 'float32_le',
        'confidenceFormat': 'float32_le',
        'poseFormat': 'float32_le',
        'frameIndexFields': [
          'relativeDepthPath',
          'confidencePath',
          'predExtrinsicsPath',
          'predIntrinsicsPath',
        ],
      },
      'geometryTruthGate': {
        'visualLoopRetrievalExecutor': {
          'name': 'VisualLoopRetrievalExecutor',
          'status': 'abstract_pluggable_backend',
          'productionLicenseRule': 'Apache-2.0/MIT/BSD or owned code only',
          'researchBackendsAllowedOnMacOnly': ['SALAD/DINOv2-SALAD'],
          'acceptanceRole':
              'propose non-adjacent loop candidates; never accept geometry by itself',
        },
        'denseSim3Verifier': {
          'name': 'DenseSim3Verifier',
          'status': 'required_for_tree_bridges_and_loop_edges',
          'method': 'sampled_dense_depth_sim3_alignment',
          'inputs': [
            'relativeDepthPath',
            'confidencePath',
            'predExtrinsicsPath',
            'predIntrinsicsPath',
            'bridgeFrameIDs',
          ],
          'acceptanceRole':
              'the geometry truth gate for joining DA3 windows into one scan graph',
        },
      },
      'realDeviceAudit': {
        'reportPath': 'stages/depth/da3_real_device_audit.json',
        'requiredAfterCapture': true,
        'checks': [
          'sealed DA3-BASE K35@476x742 resource',
          'K-window 35-slot padding and half-window bridge overlap',
          'visual retrieval remains a pluggable commercial-safe executor',
          'dense Sim3 bridge/loop verification report is present',
          'native telemetry preserves load/infer/RSS/CPU fields when available',
        ],
      },
      'downstreamConsumers': {
        'pointcloud': 'depth_index.json frames[] depth/conf + predicted pose',
        'mesh': 'stages/pointcloud/pointcloud.ply from DA3 geometry',
        'texture': 'texture_plan.json consumes locked DA3 geometry',
        'highlight':
            'highlightPolicy combines DA3 geometry with material reflective risk',
      },
    };
  }
}

final class PhotoBundlePipelinePolicyService {
  const PhotoBundlePipelinePolicyService({
    this.modelPolicy = const AetherModelPolicy(),
  });

  final AetherModelPolicy modelPolicy;

  Map<String, Object?> buildKWindowPlan(
    Map<String, Object?> manifest,
    Map<String, Object?> viewGraph, {
    String tier = 'high',
    int? windowSize,
    int? maxWindows,
    int? targetBridgeOverlap,
    AetherDa3WindowingMode windowingMode =
        AetherDa3WindowingMode.officialStreamingSequential,
  }) {
    final model = modelPolicy.resolveDa3Model(tier: tier);
    final frames = _frames(manifest);
    final nodes = _maps(viewGraph['nodes']);
    final edges = _maps(viewGraph['edges'])
      ..sort((a, b) => _asDouble(b['score']).compareTo(_asDouble(a['score'])));
    final requestedWindowSize = windowSize ?? model.windowSize;
    final defaultBridgeOverlap =
        requestedWindowSize <= 2 ? 0 : (requestedWindowSize / 2).ceil();
    final requestedBridgeOverlap = targetBridgeOverlap ?? defaultBridgeOverlap;
    if (requestedBridgeOverlap < 0 ||
        requestedBridgeOverlap >= requestedWindowSize) {
      throw ArgumentError.value(
        targetBridgeOverlap,
        'targetBridgeOverlap',
        'must be >= 0 and smaller than windowSize',
      );
    }
    final resolvedBridgeOverlap =
        requestedWindowSize <= 2 ? 0 : requestedBridgeOverlap;
    final selectionMode = resolvedBridgeOverlap == defaultBridgeOverlap
        ? 'spherical_pose_graph_half_overlap_bridge_v1'
        : 'spherical_pose_graph_configurable_overlap_bridge_v1';
    final stepEquivalent = math.max(
      1,
      requestedWindowSize - resolvedBridgeOverlap,
    );
    final nodeByID = <String, Map<String, Object?>>{
      for (final node in nodes) _asString(node['id']): node,
    };
    final frameByID = <String, Map<String, Object?>>{
      for (final frame in frames) _asString(frame['id']): frame,
    };
    final adjacency = <String, List<_WindowEdge>>{};
    for (final edge in edges) {
      final source = _asString(edge['sourceID']);
      final target = _asString(edge['targetID']);
      if (source.isEmpty || target.isEmpty) continue;
      final score = _asDouble(edge['score']);
      adjacency
          .putIfAbsent(source, () => <_WindowEdge>[])
          .add(_WindowEdge(otherID: target, score: score, raw: edge));
      adjacency
          .putIfAbsent(target, () => <_WindowEdge>[])
          .add(_WindowEdge(otherID: source, score: score, raw: edge));
    }
    for (final list in adjacency.values) {
      list.sort((a, b) => b.score.compareTo(a.score));
    }

    if (windowingMode == AetherDa3WindowingMode.officialStreamingSequential) {
      return _buildOfficialSequentialKWindowPlan(
        model: model,
        frames: frames,
        adjacency: adjacency,
        requestedWindowSize: requestedWindowSize,
        defaultBridgeOverlap: defaultBridgeOverlap,
        resolvedBridgeOverlap: resolvedBridgeOverlap,
        stepEquivalent: stepEquivalent,
        maxWindows: maxWindows,
        targetBridgeOverlap: targetBridgeOverlap,
      );
    }

    final seedIDs = <String>{
      ...frameByID.keys.where((id) => id.isNotEmpty),
      ...nodeByID.keys.where((id) => id.isNotEmpty),
    }.toList()
      ..sort((a, b) {
        final fa = frameByID[a];
        final fb = frameByID[b];
        final qa = _qualityScore(fa);
        final qb = _qualityScore(fb);
        final ca = _asDouble(nodeByID[a]?['graphConnectivity']);
        final cb = _asDouble(nodeByID[b]?['graphConnectivity']);
        return (qb + cb * 0.25).compareTo(qa + ca * 0.25);
      });

    final windows = <Map<String, Object?>>[];
    final bridgeGraph = <Map<String, Object?>>[];
    final globallyCovered = <String>{};
    final defaultWindowCount = seedIDs.isEmpty
        ? 0
        : (seedIDs.length <= requestedWindowSize
            ? 1
            : 1 +
                ((seedIDs.length - requestedWindowSize + stepEquivalent - 1) ~/
                    stepEquivalent));
    final windowLimit = maxWindows ?? seedIDs.length;

    while (windows.length < windowLimit &&
        seedIDs.any((id) => !globallyCovered.contains(id))) {
      final seed = seedIDs.firstWhere((id) => !globallyCovered.contains(id));
      final parent = _bestParentWindow(
        seedID: seed,
        windows: windows,
        adjacency: adjacency,
      );
      final bridge = parent == null
          ? <String>[]
          : _selectBridgeFrames(
              seedID: seed,
              parentWindow: parent,
              adjacency: adjacency,
              frameByID: frameByID,
              targetCount: math.min(
                resolvedBridgeOverlap,
                requestedWindowSize - 1,
              ),
            );
      final core = _expandGraphPatch(
        seedID: seed,
        adjacency: adjacency,
        seedIDs: seedIDs,
        frameByID: frameByID,
        excludedIDs: bridge.toSet(),
        targetCount: math.max(1, requestedWindowSize - bridge.length),
        globallyCovered: globallyCovered,
      );
      final selected = <String>[
        ...bridge,
        for (final id in core)
          if (!bridge.contains(id)) id,
      ];
      final uniqueCount = selected.length;
      if (selected.isNotEmpty) {
        var padCursor = 0;
        while (selected.length < requestedWindowSize) {
          selected.add(selected[padCursor % uniqueCount]);
          padCursor += 1;
        }
      }
      final uniqueFrameIDs = selected.toSet().toList(growable: false);
      if (uniqueFrameIDs.isEmpty) break;
      globallyCovered.addAll(uniqueFrameIDs);
      final windowID = 'window_${windows.length.toString().padLeft(3, '0')}';
      final parentID = _asString(parent?['id']);
      windows.add({
        'id': windowID,
        'modelTag': model.mobileTag,
        'modelResourceName': model.resourceName,
        'selectionMode': selectionMode,
        'frameIDs': selected,
        'uniqueFrameIDs': uniqueFrameIDs,
        'coreFrameIDs': core,
        'bridgeFrameIDs': bridge,
        'seedFrameID': seed,
        if (parentID.isNotEmpty) 'parentWindowID': parentID,
        'frameCount': selected.length,
        'uniqueFrameCount': uniqueCount,
        'coreFrameCount': core.length,
        'bridgeFrameCount': bridge.length,
        'bridgeTargetFrameCount': resolvedBridgeOverlap,
        'bridgeRule': parent == null
            ? 'root_window_no_parent'
            : (resolvedBridgeOverlap == defaultBridgeOverlap
                ? 'half_window_overlap_from_parent_window'
                : 'configurable_overlap_from_parent_window'),
        'bridgeValidation': parent == null
            ? {
                'status': 'root',
                'reason': 'first local graph patch establishes the root frame',
              }
            : {
                'status': 'candidate_requires_downstream_verification',
                'arPosePrior': 'passed_pose_graph_parent_selection',
                'visualRetrieval': {
                  'status': 'not_required_for_tree_bridge',
                  'executor': 'VisualLoopRetrievalExecutor',
                  'descriptorBackend': 'pluggable_for_loop_edges_only',
                },
                'geometryVerification': {
                  'status': 'pending',
                  'method': 'dense_sim3_alignment',
                  'consumeSharedFrames': true,
                },
              },
        'paddedToWindowSize': selected.length > uniqueCount,
        if (model.inputHeight != null) 'inputHeight': model.inputHeight,
        if (model.inputWidth != null) 'inputWidth': model.inputWidth,
      });
      if (parentID.isNotEmpty) {
        bridgeGraph.add({
          'sourceWindowID': parentID,
          'targetWindowID': windowID,
          'kind': 'tree_bridge',
          'bridgeFrameIDs': bridge,
          'bridgeFrameCount': bridge.length,
          'status': 'pending_dense_sim3_verification',
          'alignMethod': 'dense_sim3',
        });
      }
    }

    final loopCandidates = _buildLoopCandidates(
      windows: windows,
      adjacency: adjacency,
      bridgeGraph: bridgeGraph,
      targetBridgeOverlap: resolvedBridgeOverlap,
    );
    final uncoveredFrameIDs = [
      for (final id in seedIDs)
        if (!globallyCovered.contains(id)) id,
    ];

    return {
      'schemaVersion': 'aether_da3_k_windows_v1',
      'sourceManifest': 'official_photo_bundle.json',
      'sourceViewGraph': 'view_graph.json',
      'model': model.toJson(),
      'windowSize': requestedWindowSize,
      'windowingPolicy': {
        'kind': 'spherical_pose_graph_local_patches_v1',
        'temporalOrderRole': 'tie_breaker_only_not_topology',
        'officialReference':
            'DA3-Streaming/VGGT-Long half-chunk overlap; adapted from temporal chunks to spherical pose graph patches',
        'defaultBridgeOverlap': defaultBridgeOverlap,
        'targetBridgeOverlap': resolvedBridgeOverlap,
        'overlapOverrideActive': targetBridgeOverlap != null,
        'stepEquivalent': stepEquivalent,
        'estimatedWindowCount': defaultWindowCount,
        'hardWindowLimit': maxWindows,
        'coverageRule':
            'continue adding graph patches until every valid frame is covered unless maxWindows is explicitly set',
        'rootSelection': 'highest_quality_connected_uncovered_frame',
        'nonRootSelection':
            'choose uncovered seed, attach to strongest existing graph patch, reserve bridge frames from parent, fill local core from pose graph',
      },
      'loopClosurePolicy': {
        'candidateSources': [
          'spherical_cell_topology',
          'ar_pose_view_graph',
          'future_visual_retrieval',
        ],
        'visualRetrieval': {
          'requiredForAcceptance': true,
          'executor': 'VisualLoopRetrievalExecutor',
          'descriptorBackend': 'pluggable_commercial_safe',
          'macResearchBackendsAllowed': ['SALAD/DINOv2-SALAD'],
          'similarityThreshold': 0.85,
          'topK': 5,
        },
        'geometryVerification': {
          'requiredForAcceptance': true,
          'method': 'dense_sim3_alignment',
          'acceptOnlyAfterLowResidualAndEnoughOverlap': true,
        },
        'symmetryGuard':
            'AR pose and spherical topology filter visual look-alikes before dense Sim3; no loop edge is accepted by image similarity alone',
      },
      'inputSizeLocked': model.inputWidth != null && model.inputHeight != null,
      if (model.inputHeight != null) 'inputHeight': model.inputHeight,
      if (model.inputWidth != null) 'inputWidth': model.inputWidth,
      'bridgeGraph': bridgeGraph,
      'loopCandidates': loopCandidates,
      'uncoveredFrameIDs': uncoveredFrameIDs,
      'uncoveredFrameCount': uncoveredFrameIDs.length,
      'windowCount': windows.length,
      'windows': windows,
    };
  }

  Map<String, Object?> buildPreflightPlan(
    Map<String, Object?> manifest,
    Map<String, Object?> viewGraph,
  ) {
    return {
      'schemaVersion': 'aether_pointcloud_preflight_plan_v1',
      'sourceManifest': 'official_photo_bundle.json',
      'sourceViewGraph': 'view_graph.json',
      'frameCount': _frames(manifest).length,
      'viewGraphEdges': _asInt(viewGraph['edgeCount']),
      'owner': 'Flutter/Dart policy + native numeric writers',
      'nativeKernels': [
        'confidence_filter',
        'depth_unproject',
        'official_reservoir_sample',
        'binary_little_endian_ply_write',
      ],
      'outputs': [
        'stages/pointcloud/pointcloud.ply',
        'stages/pointcloud/official_pointcloud_report.json',
        'stages/pointcloud/camera_poses.txt',
        'stages/pointcloud/intrinsic.txt',
      ],
      'policy': {
        'mode': 'official_da3_streaming_npz_downstream_baseline',
        'officialReference':
            'Depth-Anything-3 results_output/frame_*.npz + npz_output_process.py/save_confident_pointcloud_batch',
        'consumeDa3WindowGraph': true,
        'da3WindowGraphPath': 'da3_k_windows.json',
        'officialFrameSelection':
            'consume windows[].officialSaveSlotIndices / officialCoreFrameIDs; overlap slots are alignment-only',
        'confidenceMode': 'official_da3_streaming_conf_minus_one',
        'confThresholdCoef': 0.5,
        'confThresholdCoefSource':
            'npz_output_process.py CLI default; DA3-Streaming Pointcloud_Save config uses 0.75 for full-chunk pcd export',
        'sampleRatio': 0.015,
        'depthInputMode': 'relativeDepthPath_only',
        'metricDepthPathPolicy':
            'ignored until product metric-alignment layer; not consumed by official baseline',
        'productCleanupPolicy':
            'disabled_until_official_parity_is_proven; no voxel/TSDF/surfel/statistical pruning in this baseline',
        'visualLoopRetrievalReportPath':
            'stages/depth/visual_loop_retrieval_report.json',
        'denseSim3VerificationReportPath':
            'stages/depth/dense_sim3_verification_report.json',
        'bridgeAlignmentMethod': 'dense_sim3',
        'acceptLoopEdgesOnlyAfterGeometryVerification': true,
        'acceptTreeBridgeEdgesOnlyAfterGeometryVerification': true,
      },
    };
  }

  Map<String, Object?> buildTexturePlan(
    Map<String, Object?> manifest,
    Map<String, Object?> viewGraph, {
    String tier = 'high',
  }) {
    final highTier = tier == 'high';
    return {
      'schemaVersion': 'aether_texture_plan_v1',
      'sourceManifest': 'official_photo_bundle.json',
      'sourceViewGraph': 'view_graph.json',
      'frameCount': _frames(manifest).length,
      'viewGraphEdges': _asInt(viewGraph['edgeCount']),
      'atlasSize': highTier ? 8192 : 4096,
      'defaultAtlasSize': 4096,
      'hqAtlasSize': 8192,
      'owner': 'Flutter/Dart policy + native OSS tools',
      'tools': [
        {'name': 'xatlas', 'license': 'MIT', 'role': 'uv_unwrap'},
        {
          'name': 'texrecon',
          'license': 'BSD-style/GPL-free build required',
          'role': 'multi_view_bake'
        },
        {'name': 'gltfpack', 'license': 'MIT', 'role': 'glb_pack_meshopt'},
        {
          'name': 'basis_universal',
          'license': 'Apache-2.0',
          'role': 'ktx2_texture_compress'
        },
      ],
      'cameraWeighting': {
        'preferHighStillQuality': true,
        'stillQualityField': 'quality.textureBestViewWeight',
        'preferLowIncidenceAngle': true,
        'preferConnectedViewGraph': true,
        'penalizeReflectiveRisk': true,
      },
      'geometryInput': {
        'stage': 'depth',
        'depthIndex': 'stages/depth/depth_index.json',
        'depthMeta': 'stages/depth/depth_meta.jsonl',
        'da3WindowGraph': 'da3_k_windows.json',
        'denseSim3Verification':
            'stages/depth/dense_sim3_verification_report.json',
        'visualLoopRetrieval': 'stages/depth/visual_loop_retrieval_report.json',
        'modelResourceName':
            modelPolicy.resolveDa3Model(tier: tier).resourceName,
        'role':
            'locked DA3 pose/depth geometry used by texture and highlight/specular handling',
      },
      'highlightPolicy': {
        'consumeDa3Geometry': true,
        'consumeMaterialReflectiveRisk': true,
        'reflectiveRiskSource': 'MaterialClassifier.p_reflective',
        'geometrySource':
            'DA3-BASE K35@476x742 depth/confidence/predicted pose',
      },
    };
  }

  Map<String, Object?> buildTransportManifest(Map<String, Object?> manifest) {
    return {
      'schemaVersion': 'aether_bundle_transport_v1',
      'container': 'tar.zst',
      'integrityHash': 'BLAKE3',
      'sourceManifest': 'official_photo_bundle.json',
      'semanticPayload': 'unpacked directory + manifest is the algorithm input',
      'requiredEntries': [
        'official_photo_bundle.json',
        _asString(manifest['photosHighresDir'], fallback: 'photos_highres'),
        _asString(manifest['previewsDir'], fallback: 'previews'),
        'colmap/sparse/0/cameras.txt',
        'colmap/sparse/0/images.txt',
        'colmap/sparse/0/points3D.txt',
        'photos_depth',
        'da3_input_manifest.json',
        'view_graph.json',
        'bundle_validation.json',
      ],
      'rule': 'never masquerade a directory as .mov',
    };
  }

  Map<String, Object?> buildPolicyBundle(
    Map<String, Object?> manifest,
    Map<String, Object?> viewGraph, {
    String tier = 'high',
    AetherDa3WindowingMode windowingMode =
        AetherDa3WindowingMode.officialStreamingSequential,
  }) {
    return {
      'schemaVersion': 'aether_local_policy_bundle_v1',
      'modelPolicy': modelPolicy.buildLicenseReport(tier: tier),
      'da3RuntimeContract': modelPolicy.buildDa3RuntimeContract(tier: tier),
      'kWindows': buildKWindowPlan(
        manifest,
        viewGraph,
        tier: tier,
        windowingMode: windowingMode,
      ),
      'preflight': buildPreflightPlan(manifest, viewGraph),
      'texture': buildTexturePlan(manifest, viewGraph, tier: tier),
      'transport': buildTransportManifest(manifest),
    };
  }

  static Map<String, Object?> _buildOfficialSequentialKWindowPlan({
    required AetherDa3ModelSpec model,
    required List<Map<String, Object?>> frames,
    required Map<String, List<_WindowEdge>> adjacency,
    required int requestedWindowSize,
    required int defaultBridgeOverlap,
    required int resolvedBridgeOverlap,
    required int stepEquivalent,
    required int? maxWindows,
    required int? targetBridgeOverlap,
  }) {
    final ordered = _officialFrameOrder(frames);
    final orderedFrameIDs = [
      for (final entry in ordered)
        if (_asString(entry.value['id']).isNotEmpty)
          _asString(entry.value['id']),
    ];
    final chunkRanges = <_ChunkRange>[];
    if (orderedFrameIDs.isNotEmpty) {
      if (orderedFrameIDs.length <= requestedWindowSize) {
        chunkRanges.add(_ChunkRange(0, orderedFrameIDs.length));
      } else {
        final numChunks = (orderedFrameIDs.length -
                resolvedBridgeOverlap +
                stepEquivalent -
                1) ~/
            stepEquivalent;
        for (var i = 0; i < numChunks; i += 1) {
          final start = i * stepEquivalent;
          final end =
              math.min(start + requestedWindowSize, orderedFrameIDs.length);
          if (start < end) chunkRanges.add(_ChunkRange(start, end));
        }
      }
    }

    final limitedRanges = maxWindows == null
        ? chunkRanges
        : chunkRanges.take(maxWindows).toList(growable: false);
    final windows = <Map<String, Object?>>[];
    final bridgeGraph = <Map<String, Object?>>[];
    final coveredFrameIDs = <String>{};
    final officialSavedFrameIDs = <String>[];

    for (var chunkIdx = 0; chunkIdx < limitedRanges.length; chunkIdx += 1) {
      final range = limitedRanges[chunkIdx];
      final realFrameIDs = orderedFrameIDs.sublist(range.start, range.end);
      if (realFrameIDs.isEmpty) continue;
      final selected = realFrameIDs.toList(growable: true);
      var padCursor = 0;
      while (selected.length < requestedWindowSize) {
        selected.add(realFrameIDs[padCursor % realFrameIDs.length]);
        padCursor += 1;
      }

      final isOnlyWindow = limitedRanges.length == 1;
      final isLastWindow = chunkIdx == limitedRanges.length - 1;
      final saveEnd = isOnlyWindow || isLastWindow
          ? realFrameIDs.length
          : math.max(0, realFrameIDs.length - resolvedBridgeOverlap);
      final saveSlotIndices = [
        for (var slot = 0; slot < saveEnd; slot += 1) slot,
      ];
      final officialCoreFrameIDs = [
        for (final slot in saveSlotIndices) realFrameIDs[slot],
      ];
      coveredFrameIDs.addAll(realFrameIDs);
      officialSavedFrameIDs.addAll(officialCoreFrameIDs);

      final windowID = 'window_${windows.length.toString().padLeft(3, '0')}';
      final parentID = chunkIdx == 0
          ? ''
          : 'window_${(windows.length - 1).toString().padLeft(3, '0')}';
      final bridgeFrameIDs = chunkIdx == 0
          ? const <String>[]
          : realFrameIDs
              .take(math.min(resolvedBridgeOverlap, realFrameIDs.length))
              .toList(growable: false);

      windows.add({
        'id': windowID,
        'modelTag': model.mobileTag,
        'modelResourceName': model.resourceName,
        'selectionMode':
            'official_streaming_strict_sequential_coreml_padded_v1',
        'frameIDs': selected,
        'uniqueFrameIDs': realFrameIDs,
        'coreFrameIDs': officialCoreFrameIDs,
        'officialCoreFrameIDs': officialCoreFrameIDs,
        'officialSaveSlotIndices': saveSlotIndices,
        'bridgeFrameIDs': bridgeFrameIDs,
        'seedFrameID': realFrameIDs.first,
        if (parentID.isNotEmpty) 'parentWindowID': parentID,
        'frameCount': selected.length,
        'uniqueFrameCount': realFrameIDs.length,
        'coreFrameCount': officialCoreFrameIDs.length,
        'officialCoreFrameCount': officialCoreFrameIDs.length,
        'bridgeFrameCount': bridgeFrameIDs.length,
        'bridgeTargetFrameCount': resolvedBridgeOverlap,
        'chunkStartIndex': range.start,
        'chunkEndExclusive': range.end,
        'stepEquivalent': stepEquivalent,
        'bridgeRule': chunkIdx == 0
            ? 'root_window_no_parent'
            : 'official_adjacent_overlap_from_previous_chunk',
        'bridgeValidation': chunkIdx == 0
            ? {
                'status': 'root',
                'reason':
                    'first strict temporal chunk establishes the root frame',
              }
            : {
                'status': 'candidate_requires_downstream_verification',
                'officialBasis':
                    'DA3-Streaming aligns adjacent chunks with dense Sim3 over overlap point maps',
                'geometryVerification': {
                  'status': 'pending',
                  'method': 'dense_sim3_alignment',
                  'consumeSharedFrames': true,
                },
              },
        'officialSaveRule': isOnlyWindow
            ? 'single_chunk_save_all_real_slots'
            : (isLastWindow
                ? 'last_chunk_save_all_remaining_slots'
                : 'non_last_chunk_save_first_step_slots'),
        'paddedToWindowSize': selected.length > realFrameIDs.length,
        if (model.inputHeight != null) 'inputHeight': model.inputHeight,
        if (model.inputWidth != null) 'inputWidth': model.inputWidth,
      });

      if (parentID.isNotEmpty) {
        bridgeGraph.add({
          'sourceWindowID': parentID,
          'targetWindowID': windowID,
          'kind': 'official_adjacent_chunk_bridge',
          'bridgeFrameIDs': bridgeFrameIDs,
          'bridgeFrameCount': bridgeFrameIDs.length,
          'status': 'pending_dense_sim3_verification',
          'alignMethod': 'dense_sim3',
          'officialBasis':
              'Depth-Anything-3 da3_streaming aligns previous[-overlap:] to current[:overlap]',
        });
      }
    }

    final loopCandidates = _buildLoopCandidates(
      windows: windows,
      adjacency: adjacency,
      bridgeGraph: bridgeGraph,
      targetBridgeOverlap: resolvedBridgeOverlap,
    );
    final uncoveredFrameIDs = [
      for (final id in orderedFrameIDs)
        if (!coveredFrameIDs.contains(id)) id,
    ];
    final duplicateOfficialSaves =
        officialSavedFrameIDs.length - officialSavedFrameIDs.toSet().length;

    return {
      'schemaVersion': 'aether_da3_k_windows_v1',
      'sourceManifest': 'official_photo_bundle.json',
      'sourceViewGraph': 'view_graph.json',
      'model': model.toJson(),
      'windowSize': requestedWindowSize,
      'windowingPolicy': {
        'kind': 'official_streaming_strict_sequential_v1',
        'temporalOrderRole': 'primary_topology',
        'officialReference':
            'Depth-Anything-3 da3_streaming.get_chunk_indices + save_depth_conf_result/save_camera_poses',
        'mobileAdaptation':
            'official chunk_size reduced to sealed K35; fixed CoreML slots are padded, but padding and overlap slots are excluded from officialCoreFrameIDs',
        'defaultBridgeOverlap': defaultBridgeOverlap,
        'targetBridgeOverlap': resolvedBridgeOverlap,
        'overlapOverrideActive': targetBridgeOverlap != null,
        'stepEquivalent': stepEquivalent,
        'estimatedWindowCount': chunkRanges.length,
        'hardWindowLimit': maxWindows,
        'coverageRule':
            'strict temporal sliding windows cover frames in timestamp/manifest order',
        'saveRule':
            'non-last chunks save only first stepEquivalent slots; last chunk saves remaining real slots; single short chunk saves all real slots',
        'rootSelection': 'first temporal frame',
        'nonRootSelection': 'next official sliding-window chunk',
        'officialSavedFrameCount': officialSavedFrameIDs.length,
        'officialSavedDuplicateFrameCount': duplicateOfficialSaves,
      },
      'loopClosurePolicy': {
        'candidateSources': [
          'future_visual_retrieval',
          'ar_pose_view_graph',
        ],
        'visualRetrieval': {
          'requiredForAcceptance': true,
          'executor': 'VisualLoopRetrievalExecutor',
          'descriptorBackend': 'pluggable_commercial_safe',
          'macResearchBackendsAllowed': ['SALAD/DINOv2-SALAD'],
          'similarityThreshold': 0.85,
          'topK': 5,
        },
        'geometryVerification': {
          'requiredForAcceptance': true,
          'method': 'dense_sim3_alignment',
          'acceptOnlyAfterLowResidualAndEnoughOverlap': true,
        },
        'symmetryGuard':
            'visual retrieval may propose loop edges, but dense Sim3 must verify every accepted loop edge; no loop edge is accepted by image similarity alone',
      },
      'inputSizeLocked': model.inputWidth != null && model.inputHeight != null,
      if (model.inputHeight != null) 'inputHeight': model.inputHeight,
      if (model.inputWidth != null) 'inputWidth': model.inputWidth,
      'bridgeGraph': bridgeGraph,
      'loopCandidates': loopCandidates,
      'uncoveredFrameIDs': uncoveredFrameIDs,
      'uncoveredFrameCount': uncoveredFrameIDs.length,
      'windowCount': windows.length,
      'windows': windows,
    };
  }

  static Map<String, Object?>? _bestParentWindow({
    required String seedID,
    required List<Map<String, Object?>> windows,
    required Map<String, List<_WindowEdge>> adjacency,
  }) {
    if (windows.isEmpty) return null;
    Map<String, Object?>? best;
    var bestScore = double.negativeInfinity;
    for (final window in windows) {
      final frameIDs = _strings(window['uniqueFrameIDs']);
      if (frameIDs.isEmpty) continue;
      final score = _windowToSeedScore(
        seedID: seedID,
        windowFrameIDs: frameIDs,
        adjacency: adjacency,
      );
      if (score > bestScore) {
        bestScore = score;
        best = window;
      }
    }
    return best;
  }

  static List<String> _selectBridgeFrames({
    required String seedID,
    required Map<String, Object?> parentWindow,
    required Map<String, List<_WindowEdge>> adjacency,
    required Map<String, Map<String, Object?>> frameByID,
    required int targetCount,
  }) {
    if (targetCount <= 0) return const <String>[];
    final parentIDs = _strings(parentWindow['uniqueFrameIDs']);
    final ranked = parentIDs.toList()
      ..sort((a, b) {
        final sa = _frameBridgeScore(
          frameID: a,
          seedID: seedID,
          adjacency: adjacency,
          frameByID: frameByID,
        );
        final sb = _frameBridgeScore(
          frameID: b,
          seedID: seedID,
          adjacency: adjacency,
          frameByID: frameByID,
        );
        return sb.compareTo(sa);
      });
    return ranked.take(targetCount).toList(growable: false);
  }

  static List<String> _expandGraphPatch({
    required String seedID,
    required Map<String, List<_WindowEdge>> adjacency,
    required List<String> seedIDs,
    required Map<String, Map<String, Object?>> frameByID,
    required Set<String> excludedIDs,
    required int targetCount,
    required Set<String> globallyCovered,
  }) {
    if (targetCount <= 0 || seedID.isEmpty) return const <String>[];
    final selected = <String>[seedID];
    final used = <String>{seedID, ...excludedIDs};

    while (selected.length < targetCount) {
      String? bestID;
      var bestScore = double.negativeInfinity;
      for (final from in selected) {
        for (final edge in adjacency[from] ?? const <_WindowEdge>[]) {
          final id = edge.otherID;
          if (id.isEmpty || used.contains(id)) continue;
          final score = edge.score * 0.62 +
              _qualityScore(frameByID[id]) * 0.18 +
              (globallyCovered.contains(id) ? 0.0 : 0.15) +
              _sphericalNearScore(frameByID[seedID], frameByID[id]) * 0.05;
          if (score > bestScore) {
            bestScore = score;
            bestID = id;
          }
        }
      }
      if (bestID == null) break;
      selected.add(bestID);
      used.add(bestID);
    }

    if (selected.length < targetCount) {
      final fallback = seedIDs.where((id) => !used.contains(id)).toList()
        ..sort((a, b) {
          final sa = _qualityScore(frameByID[a]) * 0.45 +
              _sphericalNearScore(frameByID[seedID], frameByID[a]) * 0.35 +
              (globallyCovered.contains(a) ? 0.0 : 0.20);
          final sb = _qualityScore(frameByID[b]) * 0.45 +
              _sphericalNearScore(frameByID[seedID], frameByID[b]) * 0.35 +
              (globallyCovered.contains(b) ? 0.0 : 0.20);
          return sb.compareTo(sa);
        });
      for (final id in fallback) {
        if (selected.length >= targetCount) break;
        selected.add(id);
        used.add(id);
      }
    }

    return selected.take(targetCount).toList(growable: false);
  }

  static List<Map<String, Object?>> _buildLoopCandidates({
    required List<Map<String, Object?>> windows,
    required Map<String, List<_WindowEdge>> adjacency,
    required List<Map<String, Object?>> bridgeGraph,
    required int targetBridgeOverlap,
  }) {
    final treePairs = <String>{
      for (final edge in bridgeGraph)
        _windowPairKey(
          _asString(edge['sourceWindowID']),
          _asString(edge['targetWindowID']),
        ),
    };
    final candidates = <Map<String, Object?>>[];
    for (var i = 0; i < windows.length; i += 1) {
      for (var j = i + 1; j < windows.length; j += 1) {
        final aID = _asString(windows[i]['id']);
        final bID = _asString(windows[j]['id']);
        if (treePairs.contains(_windowPairKey(aID, bID))) continue;
        final aFrames = _strings(windows[i]['uniqueFrameIDs']);
        final bFrames = _strings(windows[j]['uniqueFrameIDs']);
        final shared = aFrames.toSet().intersection(bFrames.toSet()).toList()
          ..sort();
        final crossScore = _windowPairCrossScore(
          aFrameIDs: aFrames,
          bFrameIDs: bFrames,
          adjacency: adjacency,
        );
        final enoughShared =
            shared.length >= math.max(3, targetBridgeOverlap ~/ 2);
        if (!enoughShared && crossScore < 0.42) continue;
        candidates.add({
          'sourceWindowID': aID,
          'targetWindowID': bID,
          'sharedFrameIDs': shared,
          'sharedFrameCount': shared.length,
          'poseGraphCrossScore': crossScore,
          'status': 'pending_visual_retrieval_and_dense_sim3',
          'visualRetrieval': {
            'required': true,
            'executor': 'VisualLoopRetrievalExecutor',
            'descriptorBackend': 'pluggable_commercial_safe',
            'macResearchBackendsAllowed': ['SALAD/DINOv2-SALAD'],
            'similarityThreshold': 0.85,
          },
          'geometryVerification': {
            'required': true,
            'method': 'dense_sim3_alignment',
          },
        });
      }
    }
    candidates.sort(
      (a, b) => _asDouble(b['poseGraphCrossScore'])
          .compareTo(_asDouble(a['poseGraphCrossScore'])),
    );
    return candidates.take(32).toList(growable: false);
  }

  static double _windowToSeedScore({
    required String seedID,
    required List<String> windowFrameIDs,
    required Map<String, List<_WindowEdge>> adjacency,
  }) {
    var best = 0.0;
    final neighbors = adjacency[seedID] ?? const <_WindowEdge>[];
    for (final edge in neighbors) {
      if (windowFrameIDs.contains(edge.otherID)) {
        best = math.max(best, edge.score);
      }
    }
    return best;
  }

  static double _frameBridgeScore({
    required String frameID,
    required String seedID,
    required Map<String, List<_WindowEdge>> adjacency,
    required Map<String, Map<String, Object?>> frameByID,
  }) {
    var edgeScore = 0.0;
    for (final edge in adjacency[seedID] ?? const <_WindowEdge>[]) {
      if (edge.otherID == frameID) edgeScore = math.max(edgeScore, edge.score);
    }
    return edgeScore * 0.70 +
        _qualityScore(frameByID[frameID]) * 0.20 +
        _sphericalNearScore(frameByID[seedID], frameByID[frameID]) * 0.10;
  }

  static double _windowPairCrossScore({
    required List<String> aFrameIDs,
    required List<String> bFrameIDs,
    required Map<String, List<_WindowEdge>> adjacency,
  }) {
    if (aFrameIDs.isEmpty || bFrameIDs.isEmpty) return 0.0;
    final bSet = bFrameIDs.toSet();
    var bestSum = 0.0;
    var support = 0;
    for (final a in aFrameIDs) {
      var best = 0.0;
      for (final edge in adjacency[a] ?? const <_WindowEdge>[]) {
        if (bSet.contains(edge.otherID)) {
          best = math.max(best, edge.score);
        }
      }
      if (best > 0) {
        bestSum += best;
        support += 1;
      }
    }
    if (support == 0) return 0.0;
    return (bestSum / math.max(1, support)).clamp(0.0, 1.0).toDouble();
  }

  static double _sphericalNearScore(
    Map<String, Object?>? a,
    Map<String, Object?>? b,
  ) {
    if (a == null || b == null) return 0.0;
    final gap = _angularGapDeg(
      _asDouble(a['azimuth']),
      _asDouble(a['elevation']),
      _asDouble(b['azimuth']),
      _asDouble(b['elevation']),
    );
    if (!gap.isFinite) return 0.0;
    return (1.0 - gap / 80.0).clamp(0.0, 1.0).toDouble();
  }

  static double _angularGapDeg(
    double azimuthA,
    double elevationA,
    double azimuthB,
    double elevationB,
  ) {
    final aCosEl = math.cos(elevationA);
    final bCosEl = math.cos(elevationB);
    final dot = aCosEl * bCosEl * math.cos(azimuthA - azimuthB) +
        math.sin(elevationA) * math.sin(elevationB);
    return math.acos(dot.clamp(-1.0, 1.0).toDouble()) * 180.0 / math.pi;
  }

  static String _windowPairKey(String a, String b) {
    return a.compareTo(b) <= 0 ? '$a::$b' : '$b::$a';
  }

  static List<Map<String, Object?>> _frames(Map<String, Object?> manifest) {
    return _maps(manifest['frames']);
  }

  static List<MapEntry<int, Map<String, Object?>>> _officialFrameOrder(
    List<Map<String, Object?>> frames,
  ) {
    final indexed = [
      for (var i = 0; i < frames.length; i += 1) MapEntry(i, frames[i]),
    ];
    indexed.sort((a, b) {
      final ta = _temporalSortValue(a.value);
      final tb = _temporalSortValue(b.value);
      if (ta != null && tb != null && ta != tb) return ta.compareTo(tb);
      if (ta != null && tb == null) return -1;
      if (ta == null && tb != null) return 1;
      return a.key.compareTo(b.key);
    });
    return indexed;
  }

  static double? _temporalSortValue(Map<String, Object?> frame) {
    for (final key in const [
      'timestamp',
      'captureTimestamp',
      'triggerTimestamp',
      'createdAt',
    ]) {
      final value = frame[key];
      if (value is num && value.isFinite) return value.toDouble();
      if (value is String && value.isNotEmpty) {
        final parsedNumber = double.tryParse(value);
        if (parsedNumber != null && parsedNumber.isFinite) {
          return parsedNumber;
        }
        final parsedDate = DateTime.tryParse(value);
        if (parsedDate != null) {
          return parsedDate.microsecondsSinceEpoch / 1000000.0;
        }
      }
    }
    return null;
  }

  static List<Map<String, Object?>> _maps(Object? value) {
    if (value is! List) return <Map<String, Object?>>[];
    return value
        .whereType<Map>()
        .map((m) => m.cast<String, Object?>())
        .toList();
  }

  static List<String> _strings(Object? value) {
    if (value is! List) return const <String>[];
    return [
      for (final item in value)
        if (item != null && item.toString().isNotEmpty) item.toString(),
    ];
  }

  static double _qualityScore(Map<String, Object?>? frame) {
    if (frame == null) return 0;
    final quality = frame['quality'];
    if (quality is Map) {
      final q = quality.cast<String, Object?>();
      final direct = _asDouble(q['kWindowWeight']);
      if (direct > 0) return direct;
      final downstream = q['downstreamWeights'];
      if (downstream is Map) {
        final nested = _asDouble(downstream['kWindow']);
        if (nested > 0) return nested;
      }
      return _asDouble(q['score']);
    }
    return 0;
  }

  static String _asString(Object? value, {String fallback = ''}) {
    if (value is String && value.isNotEmpty) return value;
    return fallback;
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }

  static double _asDouble(Object? value) {
    if (value is num) return value.toDouble();
    return 0;
  }
}

final class _WindowEdge {
  const _WindowEdge({
    required this.otherID,
    required this.score,
    required this.raw,
  });

  final String otherID;
  final double score;
  final Map<String, Object?> raw;
}

final class _ChunkRange {
  const _ChunkRange(this.start, this.end);

  final int start;
  final int end;
}
