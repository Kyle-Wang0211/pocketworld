import 'dart:convert';
import 'dart:io';

/// Pre-SAP uncertainty benchmark contract.
///
/// This is intentionally not a depth-fusion contract. DA3 remains the geometry
/// spine; MoGe is evaluated only as an auxiliary signal that may help SAP decide
/// which patches to trust, downweight, or reject.
final class PreSapUncertaintyBenchmarkSpec {
  const PreSapUncertaintyBenchmarkSpec({
    required this.benchmarkID,
    required this.mode,
    required this.da3DepthIndexPath,
    required this.patchPolicy,
    required this.routes,
    required this.metrics,
    required this.qualityGate,
    this.captureID,
    this.datasetID,
    this.groundTruthManifestPath,
    this.proxyManifestPath,
    this.mogeSpec,
    this.trainingHead = const UncertaintyHeadSpec.lightweight(),
    this.notes = const <String>[],
  });

  final String benchmarkID;
  final String? captureID;
  final String? datasetID;

  /// `ground_truth` for GT datasets, `real_capture_proxy` for phone captures.
  final String mode;
  final String da3DepthIndexPath;
  final String? groundTruthManifestPath;
  final String? proxyManifestPath;
  final PatchPolicySpec patchPolicy;
  final List<UncertaintyRouteSpec> routes;
  final MogeAuxiliarySignalSpec? mogeSpec;
  final UncertaintyHeadSpec trainingHead;
  final List<UncertaintyMetricSpec> metrics;
  final BenchmarkQualityGateSpec qualityGate;
  final List<String> notes;

  Map<String, Object?> toJson() => {
    'schema_version': 'aether_pre_sap_uncertainty_benchmark_spec_v1',
    'benchmark_id': benchmarkID,
    if (captureID != null) 'capture_id': captureID,
    if (datasetID != null) 'dataset_id': datasetID,
    'mode': mode,
    'da3_depth_index_path': da3DepthIndexPath,
    if (groundTruthManifestPath != null)
      'ground_truth_manifest_path': groundTruthManifestPath,
    if (proxyManifestPath != null) 'proxy_manifest_path': proxyManifestPath,
    'patch_policy': patchPolicy.toJson(),
    'routes': [for (final route in routes) route.toJson()],
    if (mogeSpec != null) 'moge_auxiliary_signal_spec': mogeSpec!.toJson(),
    'training_head': trainingHead.toJson(),
    'metrics': [for (final metric in metrics) metric.toJson()],
    'quality_gate': qualityGate.toJson(),
    'notes': notes,
    'hard_rules': const [
      'do_not_fuse_moge_depth_before_this_benchmark_passes',
      'da3_depth_pose_intrinsics_remain_primary_geometry_spine',
      'moge_outputs_are_shadow_signals_for_uncertainty_only',
      'sap_may_consume_scores_only_after_report_quality_gate_passes',
    ],
    'algorithm_executor_boundary': _preSapBoundaryJson(),
  };

  static PreSapUncertaintyBenchmarkSpec groundTruthDefault({
    required String benchmarkID,
    required String da3DepthIndexPath,
    required String groundTruthManifestPath,
    String? datasetID,
  }) {
    return PreSapUncertaintyBenchmarkSpec(
      benchmarkID: benchmarkID,
      datasetID: datasetID,
      mode: 'ground_truth',
      da3DepthIndexPath: da3DepthIndexPath,
      groundTruthManifestPath: groundTruthManifestPath,
      patchPolicy: const PatchPolicySpec.defaultDensePatch(),
      routes: const [
        UncertaintyRouteSpec.da3Only(),
        UncertaintyRouteSpec.da3PlusMoge(),
      ],
      mogeSpec: const MogeAuxiliarySignalSpec.productionCandidate(),
      metrics: const [
        UncertaintyMetricSpec.badPatchAuroc(),
        UncertaintyMetricSpec.badPatchAuprc(),
        UncertaintyMetricSpec.ece(),
        UncertaintyMetricSpec.brier(),
        UncertaintyMetricSpec.errorAtCoverage(),
        UncertaintyMetricSpec.coverageAtFixedError(),
      ],
      qualityGate: const BenchmarkQualityGateSpec.defaultPreSapGate(),
      notes: const [
        'GT mode labels patches from true DA3 error; the model under test only predicts uncertainty.',
      ],
    );
  }

  static PreSapUncertaintyBenchmarkSpec realCaptureProxyDefault({
    required String benchmarkID,
    required String captureID,
    required String da3DepthIndexPath,
    required String proxyManifestPath,
  }) {
    return PreSapUncertaintyBenchmarkSpec(
      benchmarkID: benchmarkID,
      captureID: captureID,
      mode: 'real_capture_proxy',
      da3DepthIndexPath: da3DepthIndexPath,
      proxyManifestPath: proxyManifestPath,
      patchPolicy: const PatchPolicySpec.defaultDensePatch(),
      routes: const [
        UncertaintyRouteSpec.da3Only(),
        UncertaintyRouteSpec.da3PlusMoge(),
      ],
      mogeSpec: const MogeAuxiliarySignalSpec.productionCandidate(),
      metrics: const [
        UncertaintyMetricSpec.reprojectionDepthResidual(),
        UncertaintyMetricSpec.reprojectionP90(),
        UncertaintyMetricSpec.normalCrossViewAngularResidual(),
        UncertaintyMetricSpec.invalidMaskHitRate(),
        UncertaintyMetricSpec.disagreementReprojectionCorrelation(),
      ],
      qualityGate: const BenchmarkQualityGateSpec.defaultPreSapGate(),
      notes: const [
        'Proxy mode never claims absolute geometry truth; it only tests cross-view consistency and uncertainty usefulness.',
      ],
    );
  }
}

final class PatchPolicySpec {
  const PatchPolicySpec({
    required this.patchSizePx,
    required this.stridePx,
    required this.edgeBandPx,
    required this.minValidPixelRatio,
    required this.sampling,
  });

  const PatchPolicySpec.defaultDensePatch()
    : patchSizePx = 32,
      stridePx = 16,
      edgeBandPx = 4,
      minValidPixelRatio = 0.55,
      sampling = const {
        'mode': 'dense_grid',
        'coordinate_space': 'da3_input_resolution',
        'aggregate': 'median_then_p90',
      };

  final int patchSizePx;
  final int stridePx;
  final int edgeBandPx;
  final double minValidPixelRatio;
  final Map<String, Object?> sampling;

  Map<String, Object?> toJson() => {
    'patch_size_px': patchSizePx,
    'stride_px': stridePx,
    'edge_band_px': edgeBandPx,
    'min_valid_pixel_ratio': minValidPixelRatio,
    'sampling': sampling,
  };
}

final class UncertaintyRouteSpec {
  const UncertaintyRouteSpec({
    required this.id,
    required this.name,
    required this.features,
  });

  const UncertaintyRouteSpec.da3Only()
    : id = 'da3_only',
      name = 'DA3 only',
      features = const [
        'da3_depth',
        'da3_conf',
        'da3_pose_intrinsics',
        'ar_scale_pose_residual',
        'rgb_depth_edge_alignment',
      ];

  const UncertaintyRouteSpec.da3PlusMoge()
    : id = 'da3_plus_moge',
      name = 'DA3 + MoGe',
      features = const [
        'da3_depth',
        'da3_conf',
        'da3_pose_intrinsics',
        'ar_scale_pose_residual',
        'rgb_depth_edge_alignment',
        'moge_depth',
        'moge_normal',
        'moge_valid_mask',
        'da3_moge_depth_residual',
        'da3_normal_moge_normal_residual',
      ];

  final String id;
  final String name;
  final List<String> features;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'features': features,
  };
}

final class MogeAuxiliarySignalSpec {
  const MogeAuxiliarySignalSpec({
    required this.modelID,
    required this.modelVariant,
    required this.signals,
    required this.numTokens,
    required this.inputLongEdgeSweep,
    required this.preserveAspectRatio,
    required this.nativeExecutorRole,
    required this.dartOwnedPolicy,
  });

  const MogeAuxiliarySignalSpec.productionCandidate()
    : modelID = 'moge_2',
      modelVariant = 'vitl_normal',
      signals = const ['depth', 'normal', 'valid_mask', 'confidence'],
      numTokens = 1800,
      inputLongEdgeSweep = const [1024, 1536, 2048, 3072],
      preserveAspectRatio = true,
      nativeExecutorRole =
          'run_moge_forward_and_write_raw_depth_normal_mask_artifacts',
      dartOwnedPolicy = const {
        'depth_role': 'shadow_residual_only',
        'normal_role': 'surface_and_edge_uncertainty_signal',
        'valid_mask_role': 'candidate_bad_patch_signal',
        'scale_rule': 'align_moge_to_da3_per_frame_or_patch_before_residuals',
        'forbidden_before_gate_passes': [
          'replace_da3_depth',
          'overwrite_da3_pose',
          'change_da3_window_alignment',
        ],
      };

  final String modelID;
  final String modelVariant;
  final List<String> signals;
  final int numTokens;
  final List<int> inputLongEdgeSweep;
  final bool preserveAspectRatio;
  final String nativeExecutorRole;
  final Map<String, Object?> dartOwnedPolicy;

  Map<String, Object?> toJson() => {
    'model_id': modelID,
    'model_variant': modelVariant,
    'signals': signals,
    'num_tokens': numTokens,
    'input_long_edge_sweep': inputLongEdgeSweep,
    'preserve_aspect_ratio': preserveAspectRatio,
    'native_executor_role': nativeExecutorRole,
    'dart_owned_policy': dartOwnedPolicy,
  };
}

final class UncertaintyHeadSpec {
  const UncertaintyHeadSpec({
    required this.allowedHeads,
    required this.defaultHead,
    required this.role,
  });

  const UncertaintyHeadSpec.lightweight()
    : allowedHeads = const ['logistic_regression', 'xgboost', 'random_forest'],
      defaultHead = 'logistic_regression',
      role =
          'benchmark_only_shadow_sap_uncertainty_predictor_not_production_sap';

  final List<String> allowedHeads;
  final String defaultHead;
  final String role;

  Map<String, Object?> toJson() => {
    'allowed_heads': allowedHeads,
    'default_head': defaultHead,
    'role': role,
  };
}

final class UncertaintyMetricSpec {
  const UncertaintyMetricSpec({
    required this.id,
    required this.label,
    required this.direction,
    required this.meaning,
  });

  const UncertaintyMetricSpec.badPatchAuroc()
    : id = 'bad_patch_auroc',
      label = 'bad patch AUROC',
      direction = 'higher_is_better',
      meaning = 'Can the route separate DA3-bad patches from good patches?';

  const UncertaintyMetricSpec.badPatchAuprc()
    : id = 'bad_patch_auprc',
      label = 'bad patch AUPRC',
      direction = 'higher_is_better',
      meaning =
          'Sensitive metric when bad patches are sparse; measures bad-patch retrieval quality.';

  const UncertaintyMetricSpec.ece()
    : id = 'ece',
      label = 'ECE',
      direction = 'lower_is_better',
      meaning = 'Calibration error of predicted uncertainty/confidence.';

  const UncertaintyMetricSpec.brier()
    : id = 'brier',
      label = 'Brier',
      direction = 'lower_is_better',
      meaning = 'Probability calibration and sharpness for bad-patch labels.';

  const UncertaintyMetricSpec.errorAtCoverage()
    : id = 'error_at_80pct_coverage',
      label = 'Error@80% coverage',
      direction = 'lower_is_better',
      meaning =
          'True error after keeping the most trusted 80 percent of patches.';

  const UncertaintyMetricSpec.coverageAtFixedError()
    : id = 'coverage_at_fixed_error',
      label = 'Coverage@fixed error',
      direction = 'higher_is_better',
      meaning = 'How much surface can be kept under a fixed error threshold.';

  const UncertaintyMetricSpec.reprojectionDepthResidual()
    : id = 'multiview_reprojection_depth_residual',
      label = 'multi-view reprojection depth residual',
      direction = 'lower_is_better',
      meaning =
          'AR-pose reprojection consistency of depth between neighboring views.';

  const UncertaintyMetricSpec.reprojectionP90()
    : id = 'reprojection_p90',
      label = 'reprojection p90',
      direction = 'lower_is_better',
      meaning = 'Tail residual; catches bad regions hidden by mean metrics.';

  const UncertaintyMetricSpec.normalCrossViewAngularResidual()
    : id = 'normal_cross_view_angular_residual',
      label = 'normal cross-view angular residual',
      direction = 'lower_is_better',
      meaning = 'Whether normals remain consistent after cross-view transport.';

  const UncertaintyMetricSpec.invalidMaskHitRate()
    : id = 'invalid_mask_hit_rate',
      label = 'invalid mask hit rate',
      direction = 'higher_is_better',
      meaning = 'Whether MoGe valid mask covers high-residual proxy regions.';

  const UncertaintyMetricSpec.disagreementReprojectionCorrelation()
    : id = 'da3_moge_disagreement_reprojection_error_correlation',
      label = 'DA3-MoGe disagreement vs reprojection error correlation',
      direction = 'higher_is_better',
      meaning =
          'Whether DA3/MoGe disagreement actually predicts unreliable areas.';

  final String id;
  final String label;
  final String direction;
  final String meaning;

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'direction': direction,
    'meaning': meaning,
  };
}

final class BenchmarkQualityGateSpec {
  const BenchmarkQualityGateSpec({
    required this.primaryComparison,
    required this.requiredWins,
    required this.mustNotRegress,
    required this.decisionRule,
  });

  const BenchmarkQualityGateSpec.defaultPreSapGate()
    : primaryComparison = 'da3_plus_moge_vs_da3_only',
      requiredWins = const [
        'bad_patch_auroc',
        'bad_patch_auprc',
        'error_at_80pct_coverage',
      ],
      mustNotRegress = const [
        'multiview_reprojection_depth_residual',
        'reprojection_p90',
        'normal_cross_view_angular_residual',
      ],
      decisionRule =
          'MoGe may enter SAP only if it improves uncertainty ranking/calibration without introducing cross-view conflict.';

  final String primaryComparison;
  final List<String> requiredWins;
  final List<String> mustNotRegress;
  final String decisionRule;

  Map<String, Object?> toJson() => {
    'primary_comparison': primaryComparison,
    'required_wins': requiredWins,
    'must_not_regress': mustNotRegress,
    'decision_rule': decisionRule,
  };
}

final class PreSapUncertaintyBenchmarkReport {
  const PreSapUncertaintyBenchmarkReport({
    required this.status,
    required this.specPath,
    required this.routeReports,
    required this.comparison,
    required this.qualityGate,
    required this.artifacts,
    this.message,
  });

  final String status;
  final String specPath;
  final List<Map<String, Object?>> routeReports;
  final Map<String, Object?> comparison;
  final Map<String, Object?> qualityGate;
  final Map<String, Object?> artifacts;
  final String? message;

  Map<String, Object?> toJson() => {
    'schema_version': 'aether_pre_sap_uncertainty_benchmark_report_v1',
    'status': status,
    'spec_path': specPath,
    if (message != null) 'message': message,
    'route_reports': routeReports,
    'comparison': comparison,
    'quality_gate': qualityGate,
    'artifacts': artifacts,
    'algorithm_executor_boundary': _preSapBoundaryJson(),
  };
}

abstract class PreSapUncertaintyBenchmarkExecutor {
  const PreSapUncertaintyBenchmarkExecutor();

  Future<PreSapUncertaintyBenchmarkReport> run(
    PreSapUncertaintyBenchmarkSpec spec,
    Directory outputDir,
  );
}

/// Contract-only executor for early pipeline wiring and real-device audits.
///
/// A Mac research executor can later replace this and fill in metrics from
/// Python/XGBoost/CUDA, but the policy, features, and pass/fail rule stay here.
final class ContractOnlyPreSapUncertaintyBenchmarkExecutor
    extends PreSapUncertaintyBenchmarkExecutor {
  const ContractOnlyPreSapUncertaintyBenchmarkExecutor();

  @override
  Future<PreSapUncertaintyBenchmarkReport> run(
    PreSapUncertaintyBenchmarkSpec spec,
    Directory outputDir,
  ) async {
    await outputDir.create(recursive: true);
    const specFileName = 'pre_sap_uncertainty_spec.json';
    final report = PreSapUncertaintyBenchmarkReport(
      status: 'contract_only',
      specPath: specFileName,
      message:
          'Benchmark executor is not configured; this report fixes the Dart-owned SAP uncertainty contract.',
      routeReports: [
        for (final route in spec.routes)
          {
            'route_id': route.id,
            'status': 'waiting_for_metric_executor',
            'features': route.features,
          },
      ],
      comparison: const {
        'primary': 'da3_plus_moge_vs_da3_only',
        'status': 'not_run',
      },
      qualityGate: {
        ...spec.qualityGate.toJson(),
        'status': 'not_run_contract_only',
      },
      artifacts: const {
        'patch_table': 'patch_features.parquet',
        'route_metrics': 'route_metrics.json',
        'calibration_curve': 'calibration_curve.json',
      },
    );
    await File('${outputDir.path}/$specFileName').writeAsString(
      const JsonEncoder.withIndent('  ').convert(spec.toJson()),
      flush: true,
    );
    await File(
      '${outputDir.path}/pre_sap_uncertainty_report.json',
    ).writeAsString(
      const JsonEncoder.withIndent('  ').convert(report.toJson()),
      flush: true,
    );
    return report;
  }
}

Map<String, Object?> _preSapBoundaryJson() => const {
  'rule': 'Dart sealed spec -> thin executor -> Dart report/audit -> SAP',
  'dart_owns': [
    'DA3-only vs DA3+MoGe route definition',
    'patch sampling policy',
    'feature list and names',
    'MoGe auxiliary signal role',
    'metric selection',
    'quality gate for SAP consumption',
    'artifact naming',
  ],
  'executor_owns': [
    'MoGe forward pass',
    'raw depth/normal/mask writes',
    'patch feature extraction kernels',
    'lightweight benchmark head fitting',
    'metric computation bytes',
  ],
  'executor_must_not_own': [
    'whether MoGe replaces DA3 depth',
    'whether SAP consumes a route',
    'bad-patch threshold policy',
    'coverage target',
    'downstream handoff',
  ],
};
