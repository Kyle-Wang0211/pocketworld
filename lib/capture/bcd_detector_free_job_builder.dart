// Deterministic, bounded-memory product planning for detector-free (D)
// finalize.
//
// Geometry comes exclusively from BcdFinalizeInputBundle: its sparse cloud and
// solved cameras have already been transformed by the accepted Sim(3) bridge
// into one metric gravity-world gauge. Raw AR poses, LiDAR, and sceneDepth are
// never consumed here. Planning retains uint8 image assets only; one depth job
// is materialized at a time so a multi-reference capture cannot expand into
// dozens of simultaneous float32 image copies.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:image/image.dart' as image;

import '../detector_free_depth_ffi.dart';
import '../structural_planesweep_ffi.dart';
import 'bcd_finalize_coordinator.dart';
import 'bcd_finalize_input_builder.dart';

const double _minimumMetricDepthM = 0.05;
const double _minimumGeneratedDepthM = 0.050001;

enum BcdDetectorFreeSkipReason {
  missingGrayBytes,
  unverifiedPhotometricProvenance,
  missingReferenceRgb,
  incompatibleImageGrid,
  insufficientPoseOverlap,
  insufficientSparseDepthSupport,
}

enum BcdDetectorFreePhotometricProvenance {
  /// JPEG decoded once, RGB area-resized to the research solve grid, then gray
  /// derived from that exact resized RGB plane.
  jpegRgbArea,

  /// Durable SfM gray fallback. Geometry is valid, but photometric parity with
  /// the JPEG-based research harness has not been established, so it may only
  /// serve as a source and never as an RGB reference.
  durableGrayAreaUnverified,
}

/// One small solve-grid asset. Full-resolution decode buffers are not retained.
class BcdDetectorFreeSolveAsset {
  const BcdDetectorFreeSolveAsset({
    required this.frameId,
    required this.width,
    required this.height,
    required this.gray,
    required this.grayDigest,
    required this.provenance,
    this.rgb,
    this.rgbDigest,
  });

  final int frameId;
  final int width;
  final int height;
  final Uint8List gray;
  final Uint8List? rgb;
  final String grayDigest;
  final String? rgbDigest;
  final BcdDetectorFreePhotometricProvenance provenance;
}

/// Streaming capture-asset boundary. Implementations must release any decoded
/// full-resolution image before returning the small solve-grid result.
abstract interface class BcdDetectorFreeAssetReader {
  BcdDetectorFreeSolveAsset? readSolveAsset(
    BcdFinalizeRegisteredFrameInput input, {
    required int width,
    required int height,
  });
}

/// Portable Dart fallback reader: prefer JPEG-derived RGB+gray, with a
/// clearly-labelled durable-gray source-only fallback. Product orchestration
/// must inject its bounded native preprocessor explicitly; this implementation
/// is retained for host verification and platforms lacking that backend. It
/// never retains full-resolution bytes and reuses one image Pixel object.
class BcdDetectorFreeFileAssetReader implements BcdDetectorFreeAssetReader {
  const BcdDetectorFreeFileAssetReader();

  @override
  BcdDetectorFreeSolveAsset? readSolveAsset(
    BcdFinalizeRegisteredFrameInput input, {
    required int width,
    required int height,
  }) {
    final frame = input.cameraFrame;
    try {
      final encoded = File(frame.jpegPath).readAsBytesSync();
      final decoded = image.decodeImage(encoded);
      if (decoded != null && decoded.width >= 1 && decoded.height >= 1) {
        final rgb = _resizeDecodedRgbArea(decoded, width, height);
        final gray = _rgbToResearchGray(rgb);
        return BcdDetectorFreeSolveAsset(
          frameId: frame.frameId,
          width: width,
          height: height,
          gray: gray,
          rgb: rgb,
          grayDigest: sha256.convert(gray).toString(),
          rgbDigest: sha256.convert(rgb).toString(),
          provenance: BcdDetectorFreePhotometricProvenance.jpegRgbArea,
        );
      }
    } on FileSystemException {
      // Fall through to the durable gray source-only route.
    } on FormatException {
      // Fall through to the durable gray source-only route.
    } on image.ImageException {
      // A corrupt JPEG degrades this frame to unverified gray-only support;
      // it must never abort B/C or the remaining D references.
    } on RangeError {
      // Some truncated formats fail while the decoder probes their header.
      // Treat that identically to an ImageException and use durable gray.
    }
    try {
      final sourceGray = File(input.grayPath).readAsBytesSync();
      if (sourceGray.length != frame.grayWidth * frame.grayHeight) return null;
      final gray = _resizeAreaU8(
        sourceGray,
        sourceWidth: frame.grayWidth,
        sourceHeight: frame.grayHeight,
        targetWidth: width,
        targetHeight: height,
        channels: 1,
      );
      return BcdDetectorFreeSolveAsset(
        frameId: frame.frameId,
        width: width,
        height: height,
        gray: gray,
        grayDigest: sha256.convert(gray).toString(),
        provenance:
            BcdDetectorFreePhotometricProvenance.durableGrayAreaUnverified,
      );
    } on FileSystemException {
      return null;
    }
  }
}

/// A reference that was deliberately not scheduled. This is not a successful
/// zero-birth result: product telemetry can distinguish "D had no work" from
/// "D ran and proved no births".
class BcdDetectorFreeSkippedReference {
  const BcdDetectorFreeSkippedReference({
    required this.frameId,
    required this.reason,
    required this.detail,
  });

  final int frameId;
  final BcdDetectorFreeSkipReason reason;
  final String detail;
}

/// Capture-independent selection and depth-sweep policy.
class BcdDetectorFreeJobBuilderOptions {
  const BcdDetectorFreeJobBuilderOptions.certified()
    : certifiedProduct = true,
      solveWidth = 128,
      solveHeight = 72,
      minimumSourceViews = 4,
      maximumSourceViews = 7,
      minimumBaselineM = 0.08,
      maximumBaselineM = 0.75,
      targetBaselineM = 0.25,
      maximumForwardAngleDeg = 45,
      depthCount = 48,
      fixedDepthMinimumM = 0.8,
      fixedDepthMaximumM = 4.3,
      depthLowerQuantile = 0.01,
      depthUpperQuantile = 0.99,
      depthRangePaddingFraction = 0.03,
      minimumSparseDepthSamples = 8,
      maxTileWidth = 128,
      maxTileHeight = 72,
      patchN = 5,
      exclusionRadiusSamples = 2,
      minimumStdU8 = 6,
      nccMin = 0.75,
      uniqueDepthMargin = 0.03,
      aggregation = DetectorFreeViewAggregation.topMinimum,
      refineOptions = null,
      reciprocalOptions = const DetectorFreeReciprocalOptions(
        minimumReciprocalViews: 2,
        minimumParallaxDeg: 8,
      ),
      localManifoldOptions = const LocalManifoldBirthOptions();

  const BcdDetectorFreeJobBuilderOptions.experimental({
    this.solveWidth = 128,
    this.solveHeight = 72,
    this.minimumSourceViews = 4,
    this.maximumSourceViews = 7,
    this.minimumBaselineM = 0.08,
    this.maximumBaselineM = 0.75,
    this.targetBaselineM = 0.25,
    this.maximumForwardAngleDeg = 45,
    this.depthCount = 48,
    this.fixedDepthMinimumM,
    this.fixedDepthMaximumM,
    this.depthLowerQuantile = 0.01,
    this.depthUpperQuantile = 0.99,
    this.depthRangePaddingFraction = 0.03,
    this.minimumSparseDepthSamples = 8,
    this.maxTileWidth = 128,
    this.maxTileHeight = 72,
    this.patchN = 5,
    this.exclusionRadiusSamples = 2,
    this.minimumStdU8 = 6,
    this.nccMin = 0.75,
    this.uniqueDepthMargin = 0.03,
    this.aggregation = DetectorFreeViewAggregation.topMinimum,
    this.refineOptions,
    this.reciprocalOptions = const DetectorFreeReciprocalOptions(),
    this.localManifoldOptions = const LocalManifoldBirthOptions(),
  }) : certifiedProduct = false;

  final bool certifiedProduct;
  final int solveWidth;
  final int solveHeight;
  final int minimumSourceViews;
  final int maximumSourceViews;
  final double minimumBaselineM;
  final double maximumBaselineM;
  final double targetBaselineM;
  final double maximumForwardAngleDeg;
  final int depthCount;
  final double? fixedDepthMinimumM;
  final double? fixedDepthMaximumM;
  final double depthLowerQuantile;
  final double depthUpperQuantile;
  final double depthRangePaddingFraction;
  final int minimumSparseDepthSamples;
  final int maxTileWidth;
  final int maxTileHeight;
  final int patchN;
  final int exclusionRadiusSamples;
  final double minimumStdU8;
  final double nccMin;
  final double uniqueDepthMargin;
  final DetectorFreeViewAggregation aggregation;
  final DetectorFreeRefineOptions? refineOptions;
  final DetectorFreeReciprocalOptions reciprocalOptions;
  final LocalManifoldBirthOptions localManifoldOptions;

  void validate() {
    if (solveWidth < 3 ||
        solveHeight < 3 ||
        solveWidth > 8192 ||
        solveHeight > 8192 ||
        minimumSourceViews <= 0 ||
        maximumSourceViews < minimumSourceViews ||
        maximumSourceViews > 8 ||
        !minimumBaselineM.isFinite ||
        minimumBaselineM <= 0 ||
        !maximumBaselineM.isFinite ||
        maximumBaselineM < minimumBaselineM ||
        !targetBaselineM.isFinite ||
        targetBaselineM < minimumBaselineM ||
        targetBaselineM > maximumBaselineM ||
        !maximumForwardAngleDeg.isFinite ||
        maximumForwardAngleDeg <= 0 ||
        maximumForwardAngleDeg > 180 ||
        depthCount < 2 ||
        depthCount > 64 ||
        (fixedDepthMinimumM == null) != (fixedDepthMaximumM == null) ||
        (fixedDepthMinimumM != null &&
            (!fixedDepthMinimumM!.isFinite ||
                !fixedDepthMaximumM!.isFinite ||
                fixedDepthMinimumM! <= _minimumMetricDepthM ||
                fixedDepthMaximumM! <= fixedDepthMinimumM!)) ||
        !depthLowerQuantile.isFinite ||
        !depthUpperQuantile.isFinite ||
        depthLowerQuantile < 0 ||
        depthUpperQuantile > 1 ||
        depthLowerQuantile >= depthUpperQuantile ||
        !depthRangePaddingFraction.isFinite ||
        depthRangePaddingFraction < 0 ||
        minimumSparseDepthSamples < 2 ||
        maxTileWidth <= 0 ||
        maxTileHeight <= 0 ||
        patchN < 1 ||
        patchN > 5 ||
        patchN.isEven ||
        exclusionRadiusSamples < 0 ||
        exclusionRadiusSamples >= depthCount ||
        !minimumStdU8.isFinite ||
        minimumStdU8 <= 0 ||
        !nccMin.isFinite ||
        nccMin < 0 ||
        nccMin > 1 ||
        !uniqueDepthMargin.isFinite ||
        uniqueDepthMargin < 0 ||
        uniqueDepthMargin > 2) {
      throw ArgumentError('invalid detector-free job-builder options');
    }
    refineOptions?.validate();
    reciprocalOptions.validate(maximumSourceViews);
    if (certifiedProduct &&
        (solveWidth != 128 ||
            solveHeight != 72 ||
            minimumSourceViews != 4 ||
            depthCount != 48 ||
            fixedDepthMinimumM != 0.8 ||
            fixedDepthMaximumM != 4.3 ||
            aggregation != DetectorFreeViewAggregation.topMinimum ||
            refineOptions != null ||
            reciprocalOptions.minimumReciprocalViews != 2 ||
            reciprocalOptions.minimumParallaxDeg != 8)) {
      throw StateError('certified detector-free policy was modified');
    }
  }
}

/// Lightweight request fields shared by a reference's sequential depth jobs.
/// Buffers are in metric Sim(3) space and are never derived from raw AR poses.
class BcdDetectorFreeFinalizeMetadata {
  const BcdDetectorFreeFinalizeMetadata({
    required this.metricSparseXyz,
    required this.referenceRgb,
    required this.worldToReferenceProjection3x4,
    required this.referenceToReciprocalProjections,
    required this.reciprocalCameraCentersInReference,
    required this.floorValue,
    required this.selectedFloor,
    required this.certifiedWalls,
    required this.reciprocalOptions,
    required this.localManifoldOptions,
  });

  /// Shared immutable capture buffer owned by BcdFinalizeInputBundle.
  final Float32List metricSparseXyz;

  /// Shared immutable uint8 RGB plane at the detector-free grid size.
  final Uint8List referenceRgb;
  final Float32List worldToReferenceProjection3x4;
  final Float32List referenceToReciprocalProjections;
  final Float32List reciprocalCameraCentersInReference;
  final double floorValue;
  final StructuralFloorDomain selectedFloor;
  final List<StructuralWall> certifiedWalls;
  final DetectorFreeReciprocalOptions reciprocalOptions;
  final LocalManifoldBirthOptions localManifoldOptions;
}

/// Backend-independent, gray-free identity for one depth solve. The canonical
/// digest covers ordered solve-plane digests, K, projections, sweep policy and
/// refinement policy, so schedulers never materialize float images just to
/// derive a cache key.
class BcdDetectorFreeDepthJobDescriptor {
  BcdDetectorFreeDepthJobDescriptor._({
    required this.referenceFrameId,
    required List<int> sourceFrameIds,
    required List<String> grayPlaneDigests,
    required bool certifiedProduct,
    required this.options,
    required List<double> sourceProjections,
    required this.aggregation,
    required this.refineOptions,
  }) : sourceFrameIds = List<int>.unmodifiable(sourceFrameIds),
       grayPlaneDigests = List<String>.unmodifiable(grayPlaneDigests),
       sourceProjections = List<double>.unmodifiable(sourceProjections),
       canonicalDigest = _descriptorDigest(
         referenceFrameId: referenceFrameId,
         sourceFrameIds: sourceFrameIds,
         grayPlaneDigests: grayPlaneDigests,
         certifiedProduct: certifiedProduct,
         options: options,
         sourceProjections: sourceProjections,
         aggregation: aggregation,
         refineOptions: refineOptions,
       );

  final int referenceFrameId;
  final List<int> sourceFrameIds;
  final List<String> grayPlaneDigests;
  final DetectorFreeDepthOptions options;
  final List<double> sourceProjections;
  final DetectorFreeViewAggregation aggregation;
  final DetectorFreeRefineOptions? refineOptions;
  final String canonicalDigest;
}

String _descriptorDigest({
  required int referenceFrameId,
  required List<int> sourceFrameIds,
  required List<String> grayPlaneDigests,
  required bool certifiedProduct,
  required DetectorFreeDepthOptions options,
  required List<double> sourceProjections,
  required DetectorFreeViewAggregation aggregation,
  required DetectorFreeRefineOptions? refineOptions,
}) {
  final canonical = <String, Object?>{
    // Product provenance is part of cache identity. An experimental run with
    // numerically identical knobs must never reuse a certified result.
    'certified_product': certifiedProduct,
    'reference_frame_id': referenceFrameId,
    'source_frame_ids': sourceFrameIds,
    'gray_plane_digests': grayPlaneDigests,
    'image_width': options.imageWidth,
    'image_height': options.imageHeight,
    'max_tile_width': options.maxTileWidth,
    'max_tile_height': options.maxTileHeight,
    'depth_count': options.depthCount,
    'source_count': options.sourceCount,
    'patch_n': options.patchN,
    'minimum_views': options.minimumViews,
    'exclusion_radius_samples': options.exclusionRadiusSamples,
    'minimum_std_u8': options.minimumStdU8,
    'ncc_min': options.nccMin,
    'unique_depth_margin': options.uniqueDepthMargin,
    'inverse_depth_first': options.inverseDepthFirst,
    'inverse_depth_step': options.inverseDepthStep,
    'reference_inverse_k': options.referenceInverseK,
    'source_projections': sourceProjections,
    'aggregation': aggregation.index,
    'refine': refineOptions == null
        ? null
        : <String, Object>{
            'fine_depth_count': refineOptions.fineDepthCount,
            'coarse_step_span': refineOptions.coarseStepSpan,
            'uniqueness_absolute_m': refineOptions.uniquenessAbsoluteM,
            'uniqueness_relative': refineOptions.uniquenessRelative,
          },
  };
  return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
}

/// One deterministic reference plan. It contains no float32 gray image.
///
/// The executor must materialize, run, and release [materializePrimaryDepthJob]
/// before doing the same for each reciprocal index. Holding all returned jobs
/// simultaneously recreates the memory spike this boundary is designed to
/// prevent.
class BcdDetectorFreeReferencePlan {
  BcdDetectorFreeReferencePlan._({
    required this.referenceFrameId,
    required List<int> sourceFrameIds,
    required Map<int, List<int>> reciprocalSupportFrameIds,
    required this.metadata,
    required this.peakGrayFloatValues,
    required this.eagerRequestGrayFloatValues,
    required this.primaryDescriptor,
    required List<BcdDetectorFreeDepthJobDescriptor> reciprocalDescriptors,
    required _FrameGeometry reference,
    required List<_FrameGeometry> sources,
    required Map<int, List<_FrameGeometry>> reciprocalSupports,
    required _SolveGrayCache grayCache,
  }) : sourceFrameIds = List<int>.unmodifiable(sourceFrameIds),
       reciprocalSupportFrameIds = Map<int, List<int>>.unmodifiable({
         for (final entry in reciprocalSupportFrameIds.entries)
           entry.key: List<int>.unmodifiable(entry.value),
       }),
       _reference = reference,
       _sources = List<_FrameGeometry>.unmodifiable(sources),
       _reciprocalSupports = Map<int, List<_FrameGeometry>>.unmodifiable({
         for (final entry in reciprocalSupports.entries)
           entry.key: List<_FrameGeometry>.unmodifiable(entry.value),
       }),
       reciprocalDescriptors =
           List<BcdDetectorFreeDepthJobDescriptor>.unmodifiable(
             reciprocalDescriptors,
           ),
       _grayCache = grayCache;

  final int referenceFrameId;
  final List<int> sourceFrameIds;
  final Map<int, List<int>> reciprocalSupportFrameIds;
  final BcdDetectorFreeFinalizeMetadata metadata;

  /// Peak gray float values when the plan is executed one job at a time.
  final int peakGrayFloatValues;

  /// Diagnostic only: values that an eager primary+all-reciprocal request
  /// would allocate. No such request is constructed by this class.
  final int eagerRequestGrayFloatValues;
  final BcdDetectorFreeDepthJobDescriptor primaryDescriptor;
  final List<BcdDetectorFreeDepthJobDescriptor> reciprocalDescriptors;

  final _FrameGeometry _reference;
  final List<_FrameGeometry> _sources;
  final Map<int, List<_FrameGeometry>> _reciprocalSupports;
  final _SolveGrayCache _grayCache;

  int get reciprocalCount => _sources.length;
  List<BcdDetectorFreeDepthJobDescriptor> get depthJobDescriptors =>
      <BcdDetectorFreeDepthJobDescriptor>[
        primaryDescriptor,
        ...reciprocalDescriptors,
      ];

  BcdDetectorFreeDepthJob materializePrimaryDepthJob() =>
      BcdDetectorFreeJobBuilder._materializeDepthJob(
        reference: _reference,
        sources: _sources,
        descriptor: primaryDescriptor,
        grayCache: _grayCache,
      );

  BcdDetectorFreeDepthJob materializeReciprocalDepthJob(int index) {
    if (index < 0 || index >= _sources.length) {
      throw RangeError.index(index, _sources, 'index');
    }
    final reference = _sources[index];
    return BcdDetectorFreeJobBuilder._materializeDepthJob(
      reference: reference,
      sources: _reciprocalSupports[reference.frameId]!,
      descriptor: reciprocalDescriptors[index],
      grayCache: _grayCache,
    );
  }
}

/// All schedulable references plus explicit per-reference skips.
class BcdDetectorFreeJobBuildSet {
  BcdDetectorFreeJobBuildSet._({
    required List<BcdDetectorFreeReferencePlan> plans,
    required List<BcdDetectorFreeSkippedReference> skippedReferences,
    required this.certifiedProduct,
    required this.depthRangeEvaluationCount,
    required _SolveGrayCache grayCache,
  }) : plans = List<BcdDetectorFreeReferencePlan>.unmodifiable(plans),
       skippedReferences = List<BcdDetectorFreeSkippedReference>.unmodifiable(
         skippedReferences,
       ),
       _grayCache = grayCache;

  final List<BcdDetectorFreeReferencePlan> plans;
  final List<BcdDetectorFreeSkippedReference> skippedReferences;

  /// True only for the private [BcdDetectorFreeJobBuilder.buildAll] route.
  /// No public constructor can mint certified provenance.
  final bool certifiedProduct;

  /// Proves depth-range sorting is memoized once per evaluated frame id.
  final int depthRangeEvaluationCount;
  final _SolveGrayCache _grayCache;

  bool get hasWork => plans.isNotEmpty;
  int get graySourceConversionCount => _grayCache.sourceConversions;
  int get cachedGrayFloatValueCount => _grayCache.cachedFloatValues;
  int get materializedJobGrayFloatValueCount =>
      _grayCache.materializedJobFloatValues;
}

class BcdDetectorFreeJobBuilder {
  BcdDetectorFreeJobBuilder._();

  /// Builds every deterministic reference plan from the metric Sim(3) bundle.
  /// Missing optional image support produces [skippedReferences], never a fake
  /// successful zero-birth result and never a failure of B/C finalize.
  static BcdDetectorFreeJobBuildSet buildAll({
    required BcdFinalizeInputBundle bundle,
    required BcdDetectorFreeAssetReader assetReader,
    required double floorValue,
    required StructuralFloorDomain selectedFloor,
    required List<StructuralWall> certifiedWalls,
  }) => _buildAll(
    bundle: bundle,
    assetReader: assetReader,
    floorValue: floorValue,
    selectedFloor: selectedFloor,
    certifiedWalls: certifiedWalls,
    options: const BcdDetectorFreeJobBuilderOptions.certified(),
  );

  /// Explicit research/diagnostic entry point. Product code calls [buildAll],
  /// whose certificate-frozen policy cannot accept an override.
  static BcdDetectorFreeJobBuildSet buildAllExperimental({
    required BcdFinalizeInputBundle bundle,
    required BcdDetectorFreeAssetReader assetReader,
    required double floorValue,
    required StructuralFloorDomain selectedFloor,
    required List<StructuralWall> certifiedWalls,
    required BcdDetectorFreeJobBuilderOptions options,
  }) {
    if (options.certifiedProduct) {
      throw ArgumentError('certified policy belongs to buildAll');
    }
    return _buildAll(
      bundle: bundle,
      assetReader: assetReader,
      floorValue: floorValue,
      selectedFloor: selectedFloor,
      certifiedWalls: certifiedWalls,
      options: options,
    );
  }

  static BcdDetectorFreeJobBuildSet _buildAll({
    required BcdFinalizeInputBundle bundle,
    required BcdDetectorFreeAssetReader assetReader,
    required double floorValue,
    required StructuralFloorDomain selectedFloor,
    required List<StructuralWall> certifiedWalls,
    required BcdDetectorFreeJobBuilderOptions options,
  }) {
    options.validate();
    if (!floorValue.isFinite) {
      throw ArgumentError('detector-free floor value is malformed');
    }
    final sparseXyz = bundle.metricSparseXyz;
    if (sparseXyz.isEmpty ||
        sparseXyz.length % 3 != 0 ||
        sparseXyz.any((value) => !value.isFinite)) {
      throw ArgumentError('metric detector-free sparse XYZ is malformed');
    }

    final skipped = <BcdDetectorFreeSkippedReference>[];
    final byId = <int, _FrameAsset>{};
    for (final input in bundle.registeredFrameInputs) {
      final frameId = input.cameraFrame.frameId;
      if (byId.containsKey(frameId)) {
        throw ArgumentError(
          'metric detector-free bundle duplicates frame $frameId',
        );
      }
      final solveAsset = assetReader.readSolveAsset(
        input,
        width: options.solveWidth,
        height: options.solveHeight,
      );
      if (solveAsset == null) {
        skipped.add(
          BcdDetectorFreeSkippedReference(
            frameId: frameId,
            reason: BcdDetectorFreeSkipReason.missingGrayBytes,
            detail: 'registered frame has no in-memory gray payload',
          ),
        );
        continue;
      }
      if (solveAsset.width != options.solveWidth ||
          solveAsset.height != options.solveHeight) {
        throw ArgumentError(
          'asset reader returned ${solveAsset.width}x${solveAsset.height}; '
          'expected ${options.solveWidth}x${options.solveHeight}',
        );
      }
      if (options.certifiedProduct &&
          solveAsset.provenance !=
              BcdDetectorFreePhotometricProvenance.jpegRgbArea) {
        skipped.add(
          BcdDetectorFreeSkippedReference(
            frameId: frameId,
            reason: BcdDetectorFreeSkipReason.unverifiedPhotometricProvenance,
            detail: 'certified D requires JPEG-derived same-source RGB+gray',
          ),
        );
        continue;
      }
      final asset = _FrameAsset(registeredInput: input, solve: solveAsset);
      _validateAsset(asset);
      byId[frameId] = asset;
    }

    final groups = <String, List<_FrameGeometry>>{};
    for (final asset in byId.values) {
      final geometry = _FrameGeometry.fromMetricAsset(asset, options);
      final key = '${geometry.width}x${geometry.height}';
      groups.putIfAbsent(key, () => <_FrameGeometry>[]).add(geometry);
    }
    for (final group in groups.values) {
      group.sort((left, right) => left.frameId.compareTo(right.frameId));
    }

    final depthRangeByFrameId = <int, _DepthRange?>{};
    var depthRangeEvaluationCount = 0;
    _DepthRange? depthRange(_FrameGeometry frame) {
      if (depthRangeByFrameId.containsKey(frame.frameId)) {
        return depthRangeByFrameId[frame.frameId];
      }
      depthRangeEvaluationCount++;
      final value = _depthRange(frame, sparseXyz, options);
      depthRangeByFrameId[frame.frameId] = value;
      return value;
    }

    final grayCache = _SolveGrayCache(options.solveWidth, options.solveHeight);
    final draftPlans = <_ReferencePlan>[];
    final orderedFrames = byId.values.toList()
      ..sort(
        (left, right) => left.frame.frameId.compareTo(right.frame.frameId),
      );
    for (final asset in orderedFrames) {
      final reference = _FrameGeometry.fromMetricAsset(asset, options);
      if (asset.solve.rgb == null ||
          asset.solve.provenance !=
              BcdDetectorFreePhotometricProvenance.jpegRgbArea) {
        skipped.add(
          BcdDetectorFreeSkippedReference(
            frameId: reference.frameId,
            reason: BcdDetectorFreeSkipReason.missingReferenceRgb,
            detail: 'frame remains a source but cannot be a D reference',
          ),
        );
        continue;
      }
      final group = groups['${reference.width}x${reference.height}']!;
      if (group.length < options.minimumSourceViews + 1) {
        skipped.add(
          BcdDetectorFreeSkippedReference(
            frameId: reference.frameId,
            reason: BcdDetectorFreeSkipReason.incompatibleImageGrid,
            detail:
                'fewer than ${options.minimumSourceViews} sources share '
                'the reference gray grid',
          ),
        );
        continue;
      }
      final referenceRange = depthRange(reference);
      if (referenceRange == null) {
        skipped.add(
          BcdDetectorFreeSkippedReference(
            frameId: reference.frameId,
            reason: BcdDetectorFreeSkipReason.insufficientSparseDepthSupport,
            detail: 'too few metric sparse points project into the reference',
          ),
        );
        continue;
      }

      // The certified generator freezes the primary top 4..7 before it proves
      // reciprocal support. If any selected primary cannot be proved, the
      // complete reference is ineligible; replacing it with a lower-ranked
      // candidate would schedule a reference that the formal four-capture
      // certificate never evaluated. Experimental planning may still explore
      // that replacement policy explicitly.
      final rankedCandidates = _rankSources(
        group: group,
        reference: reference,
        excludedFrameIds: <int>{reference.frameId},
        options: options,
      );
      final candidatesToProve = options.certifiedProduct
          ? rankedCandidates.take(options.maximumSourceViews)
          : rankedCandidates;
      final sources = <_FrameGeometry>[];
      final reciprocalSupports = <int, List<_FrameGeometry>>{};
      final reciprocalRanges = <int, _DepthRange>{};
      String? certifiedFailure;
      for (final reciprocal in candidatesToProve) {
        final reciprocalRange = depthRange(reciprocal);
        if (reciprocalRange == null) {
          if (options.certifiedProduct) {
            certifiedFailure =
                'selected source ${reciprocal.frameId} has no fixed-depth proof';
            break;
          }
          continue;
        }
        final independent = _rankSources(
          group: group,
          reference: reciprocal,
          excludedFrameIds: <int>{reference.frameId, reciprocal.frameId},
          options: options,
        );
        if (independent.length < options.minimumSourceViews) {
          if (options.certifiedProduct) {
            certifiedFailure =
                'selected source ${reciprocal.frameId} has only '
                '${independent.length}/${options.minimumSourceViews} '
                'independent supports';
            break;
          }
          continue;
        }
        final support = independent.take(options.maximumSourceViews).toList();
        sources.add(reciprocal);
        reciprocalSupports[reciprocal.frameId] = support;
        reciprocalRanges[reciprocal.frameId] = reciprocalRange;
        if (sources.length == options.maximumSourceViews) break;
      }
      if (certifiedFailure != null ||
          sources.length < options.minimumSourceViews ||
          sources.length < options.reciprocalOptions.minimumReciprocalViews) {
        skipped.add(
          BcdDetectorFreeSkippedReference(
            frameId: reference.frameId,
            reason: BcdDetectorFreeSkipReason.insufficientPoseOverlap,
            detail:
                certifiedFailure ??
                'independent reciprocal sources '
                    '${sources.length}/${options.minimumSourceViews}',
          ),
        );
        continue;
      }
      draftPlans.add(
        _ReferencePlan(
          reference: reference,
          sources: sources,
          reciprocalSupports: reciprocalSupports,
          referenceDepthRange: referenceRange,
          reciprocalDepthRanges: reciprocalRanges,
        ),
      );
    }

    draftPlans.sort((left, right) {
      final bySources = right.sources.length.compareTo(left.sources.length);
      if (bySources != 0) return bySources;
      final byMedoid = left.medoidCost.compareTo(right.medoidCost);
      if (byMedoid != 0) return byMedoid;
      return left.reference.frameId.compareTo(right.reference.frameId);
    });
    skipped.sort((left, right) {
      final byId = left.frameId.compareTo(right.frameId);
      if (byId != 0) return byId;
      return left.reason.index.compareTo(right.reason.index);
    });

    final plans = <BcdDetectorFreeReferencePlan>[];
    for (final draft in draftPlans) {
      final referenceToReciprocal = Float32List(draft.sources.length * 12);
      final reciprocalCenters = Float32List(draft.sources.length * 3);
      for (var index = 0; index < draft.sources.length; index++) {
        final reciprocal = draft.sources[index];
        referenceToReciprocal.setRange(
          index * 12,
          (index + 1) * 12,
          _projectionFromReference(draft.reference, reciprocal),
        );
        reciprocalCenters.setRange(
          index * 3,
          (index + 1) * 3,
          draft.reference.worldToCamera(reciprocal.cameraCenter),
        );
      }
      final primaryValues =
          draft.reference.width *
          draft.reference.height *
          (draft.sources.length + 1);
      var eagerValues = primaryValues;
      var peakValues = primaryValues;
      for (final reciprocal in draft.sources) {
        final values =
            reciprocal.width *
            reciprocal.height *
            (draft.reciprocalSupports[reciprocal.frameId]!.length + 1);
        eagerValues += values;
        peakValues = math.max(peakValues, values);
      }
      final primaryDescriptor = _makeDescriptor(
        reference: draft.reference,
        sources: draft.sources,
        depthRange: draft.referenceDepthRange,
        options: options,
      );
      final reciprocalDescriptors = <BcdDetectorFreeDepthJobDescriptor>[
        for (final reciprocal in draft.sources)
          _makeDescriptor(
            reference: reciprocal,
            sources: draft.reciprocalSupports[reciprocal.frameId]!,
            depthRange: draft.reciprocalDepthRanges[reciprocal.frameId]!,
            options: options,
          ),
      ];
      plans.add(
        BcdDetectorFreeReferencePlan._(
          referenceFrameId: draft.reference.frameId,
          sourceFrameIds: <int>[
            for (final source in draft.sources) source.frameId,
          ],
          reciprocalSupportFrameIds: <int, List<int>>{
            for (final entry in draft.reciprocalSupports.entries)
              entry.key: <int>[
                for (final support in entry.value) support.frameId,
              ],
          },
          metadata: BcdDetectorFreeFinalizeMetadata(
            metricSparseXyz: sparseXyz,
            referenceRgb: draft.reference.asset.solve.rgb!,
            worldToReferenceProjection3x4: Float32List.fromList(
              draft.reference.worldProjection,
            ),
            referenceToReciprocalProjections: referenceToReciprocal,
            reciprocalCameraCentersInReference: reciprocalCenters,
            floorValue: floorValue,
            selectedFloor: selectedFloor,
            certifiedWalls: List<StructuralWall>.unmodifiable(certifiedWalls),
            reciprocalOptions: options.reciprocalOptions,
            localManifoldOptions: options.localManifoldOptions,
          ),
          peakGrayFloatValues: peakValues,
          eagerRequestGrayFloatValues: eagerValues,
          primaryDescriptor: primaryDescriptor,
          reciprocalDescriptors: reciprocalDescriptors,
          reference: draft.reference,
          sources: draft.sources,
          reciprocalSupports: draft.reciprocalSupports,
          grayCache: grayCache,
        ),
      );
    }
    return BcdDetectorFreeJobBuildSet._(
      plans: plans,
      skippedReferences: skipped,
      certifiedProduct: options.certifiedProduct,
      depthRangeEvaluationCount: depthRangeEvaluationCount,
      grayCache: grayCache,
    );
  }

  /// Memory-model helper used by product scheduling and large-grid tests.
  static int estimateGrayFloatValues({
    required int width,
    required int height,
    required List<int> sourceCountsByJob,
  }) {
    if (width < 3 ||
        height < 3 ||
        width > 8192 ||
        height > 8192 ||
        sourceCountsByJob.isEmpty ||
        sourceCountsByJob.any((count) => count < 1 || count > 8)) {
      throw ArgumentError('invalid detector-free memory estimate');
    }
    return sourceCountsByJob.fold<int>(
      0,
      (sum, count) => sum + width * height * (count + 1),
    );
  }

  static void _validateAsset(_FrameAsset asset) {
    final frame = asset.frame;
    final q = frame.cameraFromWorldQuaternionWxyz;
    final t = frame.cameraFromWorldTranslation;
    if (frame.frameId < 0 ||
        frame.grayWidth < 3 ||
        frame.grayHeight < 3 ||
        frame.grayWidth > 8192 ||
        frame.grayHeight > 8192 ||
        !frame.grayFx.isFinite ||
        !frame.grayFy.isFinite ||
        !frame.grayCx.isFinite ||
        !frame.grayCy.isFinite ||
        frame.grayFx <= 0 ||
        frame.grayFy <= 0 ||
        q.length != 4 ||
        t.length != 3 ||
        q.any((value) => !value.isFinite) ||
        t.any((value) => !value.isFinite) ||
        q.fold<double>(0, (sum, value) => sum + value * value) <= 1e-24) {
      throw ArgumentError(
        'metric detector-free frame ${frame.frameId} is malformed',
      );
    }
    final pixels = asset.solve.width * asset.solve.height;
    if (asset.solve.frameId != frame.frameId ||
        asset.solve.width < 3 ||
        asset.solve.height < 3 ||
        asset.solve.width > 8192 ||
        asset.solve.height > 8192 ||
        asset.solve.gray.length != pixels ||
        asset.solve.grayDigest.isEmpty ||
        (asset.solve.rgb != null && asset.solve.rgb!.length != pixels * 3) ||
        (asset.solve.rgb != null && asset.solve.rgbDigest == null)) {
      throw ArgumentError(
        'detector-free frame ${frame.frameId} byte dimensions do not match',
      );
    }
  }

  static List<_FrameGeometry> _rankSources({
    required List<_FrameGeometry> group,
    required _FrameGeometry reference,
    required Set<int> excludedFrameIds,
    required BcdDetectorFreeJobBuilderOptions options,
  }) {
    final candidates = <({double score, _FrameGeometry geometry})>[];
    for (final candidate in group) {
      if (excludedFrameIds.contains(candidate.frameId)) continue;
      final dx = candidate.cameraCenter[0] - reference.cameraCenter[0];
      final dy = candidate.cameraCenter[1] - reference.cameraCenter[1];
      final dz = candidate.cameraCenter[2] - reference.cameraCenter[2];
      final baseline = math.sqrt(dx * dx + dy * dy + dz * dz);
      var cosine =
          reference.forwardWorld[0] * candidate.forwardWorld[0] +
          reference.forwardWorld[1] * candidate.forwardWorld[1] +
          reference.forwardWorld[2] * candidate.forwardWorld[2];
      cosine = cosine.clamp(-1.0, 1.0);
      final angle = math.acos(cosine) * 180 / math.pi;
      if (baseline < options.minimumBaselineM ||
          baseline > options.maximumBaselineM ||
          angle > options.maximumForwardAngleDeg) {
        continue;
      }
      final score =
          (math.log(baseline / options.targetBaselineM)).abs() +
          angle / options.maximumForwardAngleDeg;
      candidates.add((score: score, geometry: candidate));
    }
    candidates.sort((left, right) {
      final byScore = left.score.compareTo(right.score);
      if (byScore != 0) return byScore;
      return left.geometry.frameId.compareTo(right.geometry.frameId);
    });
    return <_FrameGeometry>[
      for (final candidate in candidates) candidate.geometry,
    ];
  }

  static BcdDetectorFreeDepthJobDescriptor _makeDescriptor({
    required _FrameGeometry reference,
    required List<_FrameGeometry> sources,
    required BcdDetectorFreeJobBuilderOptions options,
    required _DepthRange depthRange,
  }) {
    final inverseFirstExact = 1 / depthRange.maximumM;
    final inverseLastExact = 1 / depthRange.minimumM;
    final inverseStepExact =
        (inverseLastExact - inverseFirstExact) / (options.depthCount - 1);
    // The formal generator creates a float32 np.linspace and then passes the
    // float32 subtraction of its first two values to C. Recomputing the closed
    // form in double changes the certified step by four ULP for 0.8..4.3/48,
    // which changes every native depth hypothesis. Keep adaptive experiments
    // on their direct closed form; certified descriptors reproduce the frozen
    // float32 sequence exactly.
    final inverseFirst = options.certifiedProduct
        ? _float32(inverseFirstExact)
        : inverseFirstExact;
    final inverseStep = options.certifiedProduct
        ? _float32(
            _float32(inverseFirstExact + inverseStepExact) - inverseFirst,
          )
        : inverseStepExact;
    final projections = <double>[];
    for (final source in sources) {
      projections.addAll(_projectionFromReference(reference, source));
    }
    final depthOptions = DetectorFreeDepthOptions(
      imageWidth: reference.width,
      imageHeight: reference.height,
      maxTileWidth: math.min(options.maxTileWidth, reference.width),
      maxTileHeight: math.min(options.maxTileHeight, reference.height),
      depthCount: options.depthCount,
      sourceCount: sources.length,
      patchN: options.patchN,
      minimumViews: options.minimumSourceViews,
      exclusionRadiusSamples: options.exclusionRadiusSamples,
      minimumStdU8: options.minimumStdU8,
      nccMin: options.nccMin,
      uniqueDepthMargin: options.uniqueDepthMargin,
      inverseDepthFirst: inverseFirst,
      inverseDepthStep: inverseStep,
      referenceInverseK: List<double>.unmodifiable(<double>[
        1 / reference.fx,
        0,
        -reference.cx / reference.fx,
        0,
        1 / reference.fy,
        -reference.cy / reference.fy,
        0,
        0,
        1,
      ]),
    );
    depthOptions.validate();
    if (projections.any((value) => !value.isFinite)) {
      throw ArgumentError('detector-free projection is not finite float32');
    }
    return BcdDetectorFreeDepthJobDescriptor._(
      referenceFrameId: reference.frameId,
      sourceFrameIds: <int>[for (final source in sources) source.frameId],
      grayPlaneDigests: <String>[
        reference.asset.solve.grayDigest,
        for (final source in sources) source.asset.solve.grayDigest,
      ],
      certifiedProduct: options.certifiedProduct,
      options: depthOptions,
      sourceProjections: projections,
      aggregation: options.aggregation,
      refineOptions: options.refineOptions,
    );
  }

  static BcdDetectorFreeDepthJob _materializeDepthJob({
    required _FrameGeometry reference,
    required List<_FrameGeometry> sources,
    required BcdDetectorFreeDepthJobDescriptor descriptor,
    required _SolveGrayCache grayCache,
  }) {
    final grayFrames = Float32List(
      reference.width * reference.height * (sources.length + 1),
    );
    var offset = 0;
    for (final item in <_FrameGeometry>[reference, ...sources]) {
      final solvePlane = grayCache.plane(item.asset);
      grayFrames.setRange(offset, offset + solvePlane.length, solvePlane);
      offset += solvePlane.length;
    }
    grayCache.materializedJobFloatValues += grayFrames.length;
    final job = BcdDetectorFreeDepthJob(
      options: descriptor.options,
      grayFrames: grayFrames,
      sourceProjections: Float32List.fromList(descriptor.sourceProjections),
      aggregation: descriptor.aggregation,
      refineOptions: descriptor.refineOptions,
    );
    job.options.validate();
    if (job.sourceProjections.any((value) => !value.isFinite)) {
      throw ArgumentError('detector-free projection is not finite float32');
    }
    return job;
  }

  static _DepthRange? _depthRange(
    _FrameGeometry reference,
    Float32List sparseXyz,
    BcdDetectorFreeJobBuilderOptions options,
  ) {
    // The product certificate uses one fixed inverse-depth sweep for every
    // geometrically eligible reference. Sparse visibility is not a formal
    // prerequisite there (cap41 includes certified references with 0..7
    // visible sparse samples). Sparse quantiles and their minimum sample gate
    // belong only to the adaptive experimental policy.
    if (options.fixedDepthMinimumM != null) {
      return _DepthRange(
        minimumM: options.fixedDepthMinimumM!,
        maximumM: options.fixedDepthMaximumM!,
      );
    }
    final depths = <double>[];
    for (var index = 0; index < sparseXyz.length; index += 3) {
      final camera = reference.worldToCamera(<double>[
        sparseXyz[index],
        sparseXyz[index + 1],
        sparseXyz[index + 2],
      ]);
      final depth = camera[2];
      if (!depth.isFinite || depth <= _minimumMetricDepthM) continue;
      final u = reference.fx * camera[0] / depth + reference.cx;
      final v = reference.fy * camera[1] / depth + reference.cy;
      if (u.isFinite &&
          v.isFinite &&
          u >= 0 &&
          u < reference.width &&
          v >= 0 &&
          v < reference.height) {
        depths.add(depth);
      }
    }
    if (depths.length < options.minimumSparseDepthSamples) return null;
    depths.sort();
    final low = _quantile(depths, options.depthLowerQuantile);
    final high = _quantile(depths, options.depthUpperQuantile);
    if (!low.isFinite ||
        !high.isFinite ||
        low <= _minimumMetricDepthM ||
        high < low) {
      return null;
    }
    final observedSpan = high - low;
    final minimumSpan = math.max(high * 0.02, 0.02);
    final span = math.max(observedSpan, minimumSpan);
    final padding = span * options.depthRangePaddingFraction;
    final minimum = math.max(_minimumGeneratedDepthM, low - padding);
    final maximum = high + padding;
    if (!(maximum > minimum)) return null;
    return _DepthRange(minimumM: minimum, maximumM: maximum);
  }

  static double _quantile(List<double> sorted, double quantile) {
    final position = quantile * (sorted.length - 1);
    final lower = position.floor();
    final upper = position.ceil();
    if (lower == upper) return sorted[lower];
    final fraction = position - lower;
    return sorted[lower] * (1 - fraction) + sorted[upper] * fraction;
  }

  static double _float32(double value) {
    final storage = Float32List(1);
    storage[0] = value;
    return storage[0];
  }

  static Float32List _projectionFromReference(
    _FrameGeometry reference,
    _FrameGeometry source,
  ) {
    final relativeRotation = List<double>.filled(9, 0);
    for (var row = 0; row < 3; row++) {
      for (var column = 0; column < 3; column++) {
        relativeRotation[row * 3 + column] =
            source.rotation[row * 3] * reference.rotation[column * 3] +
            source.rotation[row * 3 + 1] * reference.rotation[column * 3 + 1] +
            source.rotation[row * 3 + 2] * reference.rotation[column * 3 + 2];
      }
    }
    final relativeTranslation = <double>[
      source.translation[0] -
          (relativeRotation[0] * reference.translation[0] +
              relativeRotation[1] * reference.translation[1] +
              relativeRotation[2] * reference.translation[2]),
      source.translation[1] -
          (relativeRotation[3] * reference.translation[0] +
              relativeRotation[4] * reference.translation[1] +
              relativeRotation[5] * reference.translation[2]),
      source.translation[2] -
          (relativeRotation[6] * reference.translation[0] +
              relativeRotation[7] * reference.translation[1] +
              relativeRotation[8] * reference.translation[2]),
    ];
    return Float32List.fromList(<double>[
      source.fx * relativeRotation[0] + source.cx * relativeRotation[6],
      source.fx * relativeRotation[1] + source.cx * relativeRotation[7],
      source.fx * relativeRotation[2] + source.cx * relativeRotation[8],
      source.fx * relativeTranslation[0] + source.cx * relativeTranslation[2],
      source.fy * relativeRotation[3] + source.cy * relativeRotation[6],
      source.fy * relativeRotation[4] + source.cy * relativeRotation[7],
      source.fy * relativeRotation[5] + source.cy * relativeRotation[8],
      source.fy * relativeTranslation[1] + source.cy * relativeTranslation[2],
      relativeRotation[6],
      relativeRotation[7],
      relativeRotation[8],
      relativeTranslation[2],
    ]);
  }
}

class _FrameAsset {
  const _FrameAsset({required this.registeredInput, required this.solve});

  final BcdFinalizeRegisteredFrameInput registeredInput;
  final BcdDetectorFreeSolveAsset solve;
  BcdRegisteredCameraFrame get frame => registeredInput.cameraFrame;
}

/// Exact pixel-area averaging for unsigned image planes. For downsampling this
/// is the same footprint used by OpenCV INTER_AREA in the research harness;
/// the weighted result is rounded back to uint8 before the native float32
/// upload, matching the harness's uint8 resize boundary.
Uint8List _resizeAreaU8(
  Uint8List source, {
  required int sourceWidth,
  required int sourceHeight,
  required int targetWidth,
  required int targetHeight,
  required int channels,
}) {
  if (sourceWidth < 1 ||
      sourceHeight < 1 ||
      targetWidth < 1 ||
      targetHeight < 1 ||
      channels < 1 ||
      source.length != sourceWidth * sourceHeight * channels) {
    throw ArgumentError('invalid area-resize dimensions');
  }
  if (sourceWidth == targetWidth && sourceHeight == targetHeight) {
    return Uint8List.fromList(source);
  }
  final output = Uint8List(targetWidth * targetHeight * channels);
  final scaleX = sourceWidth / targetWidth;
  final scaleY = sourceHeight / targetHeight;
  final normalization = scaleX * scaleY;
  for (var targetY = 0; targetY < targetHeight; targetY++) {
    final sourceY0 = targetY * scaleY;
    final sourceY1 = (targetY + 1) * scaleY;
    final firstY = sourceY0.floor();
    final lastY = math.min(sourceHeight, sourceY1.ceil());
    for (var targetX = 0; targetX < targetWidth; targetX++) {
      final sourceX0 = targetX * scaleX;
      final sourceX1 = (targetX + 1) * scaleX;
      final firstX = sourceX0.floor();
      final lastX = math.min(sourceWidth, sourceX1.ceil());
      for (var channel = 0; channel < channels; channel++) {
        var weighted = 0.0;
        for (var sourceY = firstY; sourceY < lastY; sourceY++) {
          final weightY =
              math.min(sourceY1, sourceY + 1.0) -
              math.max(sourceY0, sourceY.toDouble());
          if (!(weightY > 0)) continue;
          for (var sourceX = firstX; sourceX < lastX; sourceX++) {
            final weightX =
                math.min(sourceX1, sourceX + 1.0) -
                math.max(sourceX0, sourceX.toDouble());
            if (!(weightX > 0)) continue;
            final sourceIndex =
                (sourceY * sourceWidth + sourceX) * channels + channel;
            weighted += source[sourceIndex] * weightX * weightY;
          }
        }
        final value = (weighted / normalization).round().clamp(0, 255).toInt();
        output[(targetY * targetWidth + targetX) * channels + channel] = value;
      }
    }
  }
  return output;
}

Uint8List _resizeDecodedRgbArea(
  image.Image source,
  int targetWidth,
  int targetHeight,
) {
  final output = Uint8List(targetWidth * targetHeight * 3);
  final scaleX = source.width / targetWidth;
  final scaleY = source.height / targetHeight;
  final normalization = scaleX * scaleY;
  image.Pixel? reusablePixel;
  for (var targetY = 0; targetY < targetHeight; targetY++) {
    final sourceY0 = targetY * scaleY;
    final sourceY1 = (targetY + 1) * scaleY;
    final firstY = sourceY0.floor();
    final lastY = math.min(source.height, sourceY1.ceil());
    for (var targetX = 0; targetX < targetWidth; targetX++) {
      final sourceX0 = targetX * scaleX;
      final sourceX1 = (targetX + 1) * scaleX;
      final firstX = sourceX0.floor();
      final lastX = math.min(source.width, sourceX1.ceil());
      var red = 0.0;
      var green = 0.0;
      var blue = 0.0;
      for (var sourceY = firstY; sourceY < lastY; sourceY++) {
        final weightY =
            math.min(sourceY1, sourceY + 1.0) -
            math.max(sourceY0, sourceY.toDouble());
        if (!(weightY > 0)) continue;
        for (var sourceX = firstX; sourceX < lastX; sourceX++) {
          final weightX =
              math.min(sourceX1, sourceX + 1.0) -
              math.max(sourceX0, sourceX.toDouble());
          if (!(weightX > 0)) continue;
          final weight = weightX * weightY;
          final pixel = source.getPixel(sourceX, sourceY, reusablePixel);
          reusablePixel = pixel;
          red += pixel.r * weight;
          green += pixel.g * weight;
          blue += pixel.b * weight;
        }
      }
      final outputOffset = (targetY * targetWidth + targetX) * 3;
      output[outputOffset] = (red / normalization)
          .round()
          .clamp(0, 255)
          .toInt();
      output[outputOffset + 1] = (green / normalization)
          .round()
          .clamp(0, 255)
          .toInt();
      output[outputOffset + 2] = (blue / normalization)
          .round()
          .clamp(0, 255)
          .toInt();
    }
  }
  return output;
}

Uint8List _rgbToResearchGray(Uint8List rgb) {
  if (rgb.length % 3 != 0) {
    throw ArgumentError('RGB solve plane is malformed');
  }
  final gray = Uint8List(rgb.length ~/ 3);
  for (var index = 0; index < gray.length; index++) {
    final offset = index * 3;
    gray[index] =
        (0.299 * rgb[offset] +
                0.587 * rgb[offset + 1] +
                0.114 * rgb[offset + 2])
            .round()
            .clamp(0, 255)
            .toInt();
  }
  return gray;
}

class _SolveGrayCache {
  _SolveGrayCache(this.width, this.height);

  final int width;
  final int height;
  final Map<int, Float32List> _planes = <int, Float32List>{};
  int sourceConversions = 0;
  int cachedFloatValues = 0;
  int materializedJobFloatValues = 0;

  Float32List plane(_FrameAsset asset) {
    final cached = _planes[asset.frame.frameId];
    if (cached != null) return cached;
    if (asset.solve.width != width || asset.solve.height != height) {
      throw StateError('solve gray cache dimensions changed after planning');
    }
    final values = Float32List(asset.solve.gray.length);
    for (var index = 0; index < asset.solve.gray.length; index++) {
      values[index] = asset.solve.gray[index].toDouble();
    }
    _planes[asset.frame.frameId] = values;
    sourceConversions++;
    cachedFloatValues += values.length;
    return values;
  }
}

class _ReferencePlan {
  const _ReferencePlan({
    required this.reference,
    required this.sources,
    required this.reciprocalSupports,
    required this.referenceDepthRange,
    required this.reciprocalDepthRanges,
  });

  final _FrameGeometry reference;
  final List<_FrameGeometry> sources;
  final Map<int, List<_FrameGeometry>> reciprocalSupports;
  final _DepthRange referenceDepthRange;
  final Map<int, _DepthRange> reciprocalDepthRanges;

  double get medoidCost => sources.fold<double>(0, (sum, source) {
    final dx = source.cameraCenter[0] - reference.cameraCenter[0];
    final dy = source.cameraCenter[1] - reference.cameraCenter[1];
    final dz = source.cameraCenter[2] - reference.cameraCenter[2];
    return sum + math.sqrt(dx * dx + dy * dy + dz * dz);
  });
}

class _DepthRange {
  const _DepthRange({required this.minimumM, required this.maximumM});

  final double minimumM;
  final double maximumM;
}

class _FrameGeometry {
  const _FrameGeometry({
    required this.asset,
    required this.rotation,
    required this.translation,
    required this.cameraCenter,
    required this.forwardWorld,
    required this.worldProjection,
    required this.width,
    required this.height,
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
  });

  factory _FrameGeometry.fromMetricAsset(
    _FrameAsset asset,
    BcdDetectorFreeJobBuilderOptions options,
  ) {
    final frame = asset.frame;
    final q = frame.cameraFromWorldQuaternionWxyz;
    final norm = math.sqrt(q.fold<double>(0, (sum, item) => sum + item * item));
    final w = q[0] / norm;
    final x = q[1] / norm;
    final y = q[2] / norm;
    final z = q[3] / norm;
    final gl = <double>[
      1 - 2 * (y * y + z * z),
      2 * (x * y - z * w),
      2 * (x * z + y * w),
      2 * (x * y + z * w),
      1 - 2 * (x * x + z * z),
      2 * (y * z - x * w),
      2 * (x * z - y * w),
      2 * (y * z + x * w),
      1 - 2 * (x * x + y * y),
    ];
    final rotation = <double>[
      gl[0],
      gl[1],
      gl[2],
      -gl[3],
      -gl[4],
      -gl[5],
      -gl[6],
      -gl[7],
      -gl[8],
    ];
    final t = frame.cameraFromWorldTranslation;
    final translation = <double>[t[0], -t[1], -t[2]];
    final center = <double>[
      -(rotation[0] * translation[0] +
          rotation[3] * translation[1] +
          rotation[6] * translation[2]),
      -(rotation[1] * translation[0] +
          rotation[4] * translation[1] +
          rotation[7] * translation[2]),
      -(rotation[2] * translation[0] +
          rotation[5] * translation[1] +
          rotation[8] * translation[2]),
    ];
    final scaleX = options.solveWidth / frame.grayWidth;
    final scaleY = options.solveHeight / frame.grayHeight;
    final fx = frame.grayFx * scaleX;
    final fy = frame.grayFy * scaleY;
    final cx = frame.grayCx * scaleX;
    final cy = frame.grayCy * scaleY;
    return _FrameGeometry(
      asset: asset,
      rotation: rotation,
      translation: translation,
      cameraCenter: center,
      forwardWorld: <double>[rotation[6], rotation[7], rotation[8]],
      worldProjection: <double>[
        fx * rotation[0] + cx * rotation[6],
        fx * rotation[1] + cx * rotation[7],
        fx * rotation[2] + cx * rotation[8],
        fx * translation[0] + cx * translation[2],
        fy * rotation[3] + cy * rotation[6],
        fy * rotation[4] + cy * rotation[7],
        fy * rotation[5] + cy * rotation[8],
        fy * translation[1] + cy * translation[2],
        rotation[6],
        rotation[7],
        rotation[8],
        translation[2],
      ],
      width: options.solveWidth,
      height: options.solveHeight,
      fx: fx,
      fy: fy,
      cx: cx,
      cy: cy,
    );
  }

  final _FrameAsset asset;
  final List<double> rotation;
  final List<double> translation;
  final List<double> cameraCenter;
  final List<double> forwardWorld;
  final List<double> worldProjection;
  final int width;
  final int height;
  final double fx;
  final double fy;
  final double cx;
  final double cy;

  int get frameId => asset.frame.frameId;

  List<double> worldToCamera(List<double> point) => <double>[
    rotation[0] * point[0] +
        rotation[1] * point[1] +
        rotation[2] * point[2] +
        translation[0],
    rotation[3] * point[0] +
        rotation[4] * point[1] +
        rotation[5] * point[2] +
        translation[1],
    rotation[6] * point[0] +
        rotation[7] * point[1] +
        rotation[8] * point[2] +
        translation[2],
  ];
}
