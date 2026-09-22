import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:pocketworld_flutter/capture/bcd_detector_free_job_builder.dart';
import 'package:pocketworld_flutter/capture/bcd_finalize_coordinator.dart';
import 'package:pocketworld_flutter/capture/bcd_finalize_input_builder.dart';
import 'package:pocketworld_flutter/capture/sfm_live_recon.dart';
import 'package:pocketworld_flutter/detector_free_depth_ffi.dart';
import 'package:pocketworld_flutter/structural_planesweep_ffi.dart';

void main() {
  late Directory temporaryDirectory;

  const floor = StructuralFloorDomain(
    certified: true,
    normal: <double>[0, 1, 0],
    basisU: <double>[1, 0, 0],
    basisV: <double>[0, 0, 1],
    planeValue: 0,
    boundsU: <double>[-10, 10],
    boundsV: <double>[-10, 10],
  );
  const metricTranslation = <double>[3, -1, 0.5];
  const baseCenters = <int, List<double>>{
    30: <double>[0, 0, 0],
    10: <double>[0.1, 0, 0],
    20: <double>[0.2, 0.02, 0],
    40: <double>[0.3, 0, 0],
    50: <double>[0.4, 0, 0.02],
    60: <double>[0.5, 0.03, 0],
  };

  setUp(() {
    temporaryDirectory = Directory.systemTemp.createTempSync('bcd-d-jobs-');
  });

  tearDown(() {
    temporaryDirectory.deleteSync(recursive: true);
  });

  Float32List normalSparse() => Float32List.fromList(<double>[
    0.25,
    0,
    1.00,
    0.25,
    0,
    1.10,
    0.25,
    0,
    1.20,
    0.25,
    0,
    1.30,
    0.25,
    0,
    1.40,
    0.25,
    0,
    1.50,
    0.25,
    0,
    1.60,
    0.25,
    0,
    1.70,
  ]);

  ({
    BcdFinalizeInputBundle bundle,
    Map<int, Uint8List> gray,
    Map<int, Uint8List> rgb,
  })
  fixture({
    Map<int, List<double>> centers = baseCenters,
    Set<int>? rgbFrameIds,
    int grayWidth = 256,
    int grayHeight = 144,
    double? fx,
    double? fy,
    double? cx,
    double? cy,
    Map<int, double> fyByFrameId = const <int, double>{},
    Float32List? sparse,
    bool gradientReference = false,
    List<int>? poseOrder,
  }) {
    final orderedIds = poseOrder ?? centers.keys.toList().reversed.toList();
    final effectiveRgbFrameIds = rgbFrameIds ?? centers.keys.toSet();
    final gray = <int, Uint8List>{};
    final rgb = <int, Uint8List>{};
    final metadata = <int, SfmFedFrameMeta>{};
    final grayPaths = <int, String>{};
    final poses = <double>[];
    for (final frameId in orderedIds) {
      final center = centers[frameId]!;
      final pixels = grayWidth * grayHeight;
      final plane = Uint8List(pixels);
      if (gradientReference && frameId == 30) {
        for (var y = 0; y < grayHeight; y++) {
          for (var x = 0; x < grayWidth; x++) {
            plane[y * grayWidth + x] = (x + 10 * y).clamp(0, 255);
          }
        }
      } else {
        plane.fillRange(0, plane.length, frameId);
      }
      gray[frameId] = plane;
      if (effectiveRgbFrameIds.contains(frameId)) {
        final colors = Uint8List(pixels * 3);
        for (var pixel = 0; pixel < pixels; pixel++) {
          colors[pixel * 3] = frameId;
          colors[pixel * 3 + 1] = frameId + 1;
          colors[pixel * 3 + 2] = frameId + 2;
        }
        rgb[frameId] = colors;
      }
      final path = '${temporaryDirectory.path}/frame-$frameId.gray';
      File(path).writeAsBytesSync(plane, flush: true);
      grayPaths[frameId] = path;
      metadata[frameId] = SfmFedFrameMeta(
        jpegPath: '/capture/frame_$frameId.jpg',
        imageW: grayWidth,
        imageH: grayHeight,
        grayW: grayWidth,
        grayH: grayHeight,
        fx: fx ?? grayWidth / 2,
        fy: fyByFrameId[frameId] ?? fy ?? grayHeight.toDouble(),
        cx: cx ?? grayWidth / 2,
        cy: cy ?? grayHeight / 2,
        // qC * solved(identity) makes the recovered gravity rotation exactly I.
        arkitQuatWxyz: const <double>[0, 1, 0, 0],
        arkitCameraCenterWorld: <double>[
          center[0] + metricTranslation[0],
          center[1] + metricTranslation[1],
          center[2] + metricTranslation[2],
        ],
      );
      poses.addAll(<double>[
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
    }
    final sourceSparse = sparse ?? normalSparse();
    final snapshot = SfmLiveSnapshot(
      xyz: sourceSparse,
      rgb: Uint8List(sourceSparse.length),
      posesPacked: Float64List.fromList(poses),
      summary: const <String, dynamic>{},
      refined: true,
      obsOffsets: Int32List(sourceSparse.length ~/ 3 + 1),
      obsFrameIds: Int32List(0),
      obsXY: Float32List(0),
    );
    return (
      bundle: BcdFinalizeInputBuilder.build(
        snapshot: snapshot,
        fedFrameMeta: metadata,
        grayPathByFrameId: grayPaths,
      ),
      gray: gray,
      rgb: rgb,
    );
  }

  BcdDetectorFreeJobBuildSet build(
    ({
      BcdFinalizeInputBundle bundle,
      Map<int, Uint8List> gray,
      Map<int, Uint8List> rgb,
    })
    input, {
    BcdDetectorFreeJobBuilderOptions? options,
  }) {
    final reader = _FixtureAssetReader(input.gray, input.rgb);
    return options == null
        ? BcdDetectorFreeJobBuilder.buildAll(
            bundle: input.bundle,
            assetReader: reader,
            floorValue: 0,
            selectedFloor: floor,
            certifiedWalls: const <StructuralWall>[],
          )
        : BcdDetectorFreeJobBuilder.buildAllExperimental(
            bundle: input.bundle,
            assetReader: reader,
            floorValue: 0,
            selectedFloor: floor,
            certifiedWalls: const <StructuralWall>[],
            options: options,
          );
  }

  test('plans metric Sim3 geometry and materializes only one solve job', () {
    final input = fixture();
    final result = build(input);

    expect(result.certifiedProduct, isTrue);
    expect(result.plans, hasLength(baseCenters.length));
    expect(result.graySourceConversionCount, 0);
    expect(result.cachedGrayFloatValueCount, 0);
    final plan = result.plans.singleWhere(
      (item) => item.referenceFrameId == 30,
    );
    expect(plan.referenceFrameId, 30);
    expect(plan.sourceFrameIds, <int>[40, 20, 50, 60, 10]);
    expect(plan.depthJobDescriptors, hasLength(6));
    expect(plan.primaryDescriptor.referenceFrameId, 30);
    expect(plan.primaryDescriptor.sourceFrameIds, plan.sourceFrameIds);
    expect(plan.primaryDescriptor.grayPlaneDigests, hasLength(6));
    expect(plan.primaryDescriptor.canonicalDigest, hasLength(64));
    expect(plan.primaryDescriptor.options.imageWidth, 128);
    expect(plan.primaryDescriptor.options.imageHeight, 72);
    expect(plan.primaryDescriptor.options.depthCount, 48);
    expect(plan.primaryDescriptor.options.minimumViews, 4);
    expect(
      plan.primaryDescriptor.aggregation,
      DetectorFreeViewAggregation.topMinimum,
    );
    expect(plan.primaryDescriptor.refineOptions, isNull);
    expect(
      plan.primaryDescriptor.options.inverseDepthFirst,
      closeTo(1 / 4.3, 1e-7),
    );
    expect(
      _float32Bits(plan.primaryDescriptor.options.inverseDepthFirst),
      1047405497,
    );
    expect(
      _float32Bits(plan.primaryDescriptor.options.inverseDepthStep),
      1018254984,
      reason: 'formal numpy float32 linspace step must be bit-exact',
    );
    final lastNativeHypothesis = _float32(
      _float32(plan.primaryDescriptor.options.inverseDepthFirst) +
          _float32(
            _float32(plan.primaryDescriptor.options.inverseDepthStep) *
                _float32(47),
          ),
    );
    expect(
      _float32Bits(lastNativeHypothesis),
      1067450371,
      reason: 'C float reconstruction ends at the formal 1.2500004 value',
    );
    expect(plan.metadata.reciprocalOptions.minimumReciprocalViews, 2);
    expect(plan.metadata.reciprocalOptions.minimumParallaxDeg, 8);
    expect(
      identical(plan.metadata.metricSparseXyz, input.bundle.metricSparseXyz),
      isTrue,
    );
    expect(
      plan.metadata.metricSparseXyz,
      isNot(orderedEquals(normalSparse())),
      reason: 'D must consume Sim3 metric sparse, never raw snapshot sparse',
    );
    expect(
      plan.metadata.worldToReferenceProjection3x4,
      closeList(<double>[64, 0, 64, -224, 0, 72, 36, 54, 0, 0, 1, -0.5]),
    );
    expect(
      plan.metadata.referenceToReciprocalProjections.sublist(0, 12),
      closeList(<double>[64, 0, 64, -19.2, 0, 72, 36, 0, 0, 0, 1, 0]),
    );
    expect(
      plan.metadata.reciprocalCameraCentersInReference.sublist(0, 3),
      closeList(<double>[0.3, 0, 0]),
    );

    final primary = plan.materializePrimaryDepthJob();
    expect(primary.options.imageWidth, 128);
    expect(primary.options.imageHeight, 72);
    expect(
      primary.options.referenceInverseK,
      closeList(<double>[1 / 64, 0, -1, 0, 1 / 72, -0.5, 0, 0, 1]),
    );
    expect(primary.grayFrames.sublist(0, 128 * 72).toSet(), <double>{30});
    expect(primary.grayFrames.sublist(128 * 72, 2 * 128 * 72).toSet(), <double>{
      40,
    });
    expect(result.graySourceConversionCount, 6);
    expect(result.cachedGrayFloatValueCount, 6 * 128 * 72);
    expect(result.materializedJobGrayFloatValueCount, 6 * 128 * 72);

    final reciprocal = plan.materializeReciprocalDepthJob(0);
    expect(reciprocal.options.sourceCount, 4);
    expect(
      result.graySourceConversionCount,
      6,
      reason: 'reciprocal job reuses the shared solve-grid gray cache',
    );
    expect(result.materializedJobGrayFloatValueCount, (6 + 5) * 128 * 72);
  });

  test('file reader streams JPEG to small same-source RGB and gray', () {
    final source = image.Image(width: 16, height: 10);
    for (var y = 0; y < source.height; y++) {
      for (var x = 0; x < source.width; x++) {
        source.setPixelRgb(x, y, x * 8, y * 16, 40);
      }
    }
    final jpegPath = '${temporaryDirectory.path}/reader.jpg';
    File(jpegPath).writeAsBytesSync(image.encodeJpg(source, quality: 100));
    final grayPath = '${temporaryDirectory.path}/reader.gray';
    File(grayPath).writeAsBytesSync(Uint8List(16 * 10));
    final input = BcdFinalizeRegisteredFrameInput(
      cameraFrame: BcdRegisteredCameraFrame(
        frameId: 7,
        jpegPath: jpegPath,
        imageWidth: 16,
        imageHeight: 10,
        grayWidth: 16,
        grayHeight: 10,
        grayFx: 8,
        grayFy: 10,
        grayCx: 8,
        grayCy: 5,
        cameraFromWorldQuaternionWxyz: const <double>[0, 1, 0, 0],
        cameraFromWorldTranslation: const <double>[0, 0, 0],
      ),
      grayPath: grayPath,
    );

    final result = const BcdDetectorFreeFileAssetReader().readSolveAsset(
      input,
      width: 8,
      height: 5,
    )!;

    expect(result.rgb, hasLength(8 * 5 * 3));
    expect(result.gray, hasLength(8 * 5));
    expect(result.provenance, BcdDetectorFreePhotometricProvenance.jpegRgbArea);
    expect(result.grayDigest, sha256.convert(result.gray).toString());
    expect(result.rgbDigest, sha256.convert(result.rgb!).toString());

    File(jpegPath).writeAsBytesSync(const <int>[0xff, 0xd8, 0x00]);
    final fallback = const BcdDetectorFreeFileAssetReader().readSolveAsset(
      input,
      width: 8,
      height: 5,
    )!;
    expect(fallback.rgb, isNull);
    expect(
      fallback.provenance,
      BcdDetectorFreePhotometricProvenance.durableGrayAreaUnverified,
    );
    expect(fallback.gray, everyElement(0));
  });

  test('certified product excludes unverified durable-gray provenance', () {
    final input = fixture();
    final result = BcdDetectorFreeJobBuilder.buildAll(
      bundle: input.bundle,
      assetReader: _FixtureAssetReader(
        input.gray,
        input.rgb,
        provenance:
            BcdDetectorFreePhotometricProvenance.durableGrayAreaUnverified,
      ),
      floorValue: 0,
      selectedFloor: floor,
      certifiedWalls: const <StructuralWall>[],
    );

    expect(result.hasWork, isFalse);
    expect(result.plans, isEmpty);
    expect(result.skippedReferences, hasLength(baseCenters.length));
    expect(
      result.skippedReferences.map((skip) => skip.reason).toSet(),
      <BcdDetectorFreeSkipReason>{
        BcdDetectorFreeSkipReason.unverifiedPhotometricProvenance,
      },
    );
  });

  test('buildAll exposes every deterministic reference, not plans.first', () {
    final input = fixture(rgbFrameIds: baseCenters.keys.toSet());
    final first = build(input);
    final second = build(input);

    expect(first.plans, hasLength(baseCenters.length));
    expect(
      first.plans.map((plan) => plan.referenceFrameId),
      second.plans.map((plan) => plan.referenceFrameId),
    );
    expect(
      first.plans.expand(
        (plan) => plan.depthJobDescriptors.map(
          (descriptor) => descriptor.canonicalDigest,
        ),
      ),
      second.plans.expand(
        (plan) => plan.depthJobDescriptors.map(
          (descriptor) => descriptor.canonicalDigest,
        ),
      ),
    );
    expect(
      first.plans.map((plan) => plan.referenceFrameId).toSet(),
      baseCenters.keys.toSet(),
    );
    expect(first.graySourceConversionCount, 0);
    expect(first.depthRangeEvaluationCount, baseCenters.length);
  });

  test(
    'experimental build set cannot impersonate certified cache identity',
    () {
      final input = fixture();
      final certified = build(input);
      final experimental = build(
        input,
        options: const BcdDetectorFreeJobBuilderOptions.experimental(
          fixedDepthMinimumM: 0.8,
          fixedDepthMaximumM: 4.3,
          reciprocalOptions: DetectorFreeReciprocalOptions(
            minimumReciprocalViews: 2,
            minimumParallaxDeg: 8,
          ),
        ),
      );

      expect(certified.certifiedProduct, isTrue);
      expect(experimental.certifiedProduct, isFalse);
      final certifiedDescriptor = certified.plans
          .singleWhere((plan) => plan.referenceFrameId == 30)
          .primaryDescriptor;
      final experimentalDescriptor = experimental.plans
          .singleWhere((plan) => plan.referenceFrameId == 30)
          .primaryDescriptor;
      expect(
        experimentalDescriptor.sourceFrameIds,
        certifiedDescriptor.sourceFrameIds,
      );
      expect(
        experimentalDescriptor.grayPlaneDigests,
        certifiedDescriptor.grayPlaneDigests,
      );
      expect(
        experimentalDescriptor.canonicalDigest,
        isNot(certifiedDescriptor.canonicalDigest),
        reason: 'certified provenance is part of immutable descriptor identity',
      );
    },
  );

  test('full ranking replaces a top candidate that cannot solve depth', () {
    final centers = <int, List<double>>{
      ...baseCenters,
      70: const <double>[0, 0.25, 0],
    };
    final input = fixture(
      centers: centers,
      // frame 70 is pose-ranked near the target baseline, but its extreme fy
      // projects all sparse support outside the solve grid.
      fyByFrameId: const <int, double>{70: 4000},
    );
    final result = build(
      input,
      options: const BcdDetectorFreeJobBuilderOptions.experimental(
        minimumSourceViews: 4,
        maximumSourceViews: 4,
      ),
    );

    final reference = result.plans.singleWhere(
      (plan) => plan.referenceFrameId == 30,
    );
    expect(reference.sourceFrameIds, hasLength(4));
    expect(reference.sourceFrameIds, isNot(contains(70)));
  });

  test('certified policy never replaces a failed selected primary', () {
    final input = fixture(
      centers: const <int, List<double>>{
        30: <double>[0, 0, 0],
        // This is the exact target-baseline winner for frame 30, but all four
        // remaining candidates are farther than the reciprocal 0.75m gate.
        70: <double>[0.25, 0, 0],
        10: <double>[-0.50, 0.02, 0],
        20: <double>[-0.59, 0, 0.02],
        40: <double>[-0.68, 0.03, 0.01],
        50: <double>[-0.74, -0.02, 0.03],
      },
    );

    final result = build(input);

    expect(
      result.plans.map((plan) => plan.referenceFrameId),
      isNot(contains(30)),
    );
    expect(
      result.skippedReferences,
      contains(
        isA<BcdDetectorFreeSkippedReference>()
            .having((skip) => skip.frameId, 'frameId', 30)
            .having(
              (skip) => skip.reason,
              'reason',
              BcdDetectorFreeSkipReason.insufficientPoseOverlap,
            )
            .having(
              (skip) => skip.detail,
              'detail',
              contains('selected source 70'),
            ),
      ),
      reason: 'formal certified refs fail closed instead of source backfilling',
    );
  });

  test('certified fixed sweep does not require visible sparse samples', () {
    final input = fixture(
      sparse: Float32List.fromList(const <double>[1000, 1000, -1000]),
    );

    final result = build(input);

    expect(result.plans, hasLength(baseCenters.length));
    expect(
      result.skippedReferences.where(
        (skip) =>
            skip.reason ==
            BcdDetectorFreeSkipReason.insufficientSparseDepthSupport,
      ),
      isEmpty,
      reason: 'formal fixed 0.8-4.3m sweep has no sparse-visibility gate',
    );
    expect(result.depthRangeEvaluationCount, baseCenters.length);
  });

  test('support shortage is an explicit skip and never fake success', () {
    final input = fixture();
    input.gray.remove(40);
    input.gray.remove(50);
    final result = build(input);

    expect(result.hasWork, isFalse);
    expect(result.plans, isEmpty);
    expect(
      result.skippedReferences,
      contains(
        isA<BcdDetectorFreeSkippedReference>()
            .having((skip) => skip.frameId, 'frameId', 30)
            .having(
              (skip) => skip.reason,
              'reason',
              BcdDetectorFreeSkipReason.incompatibleImageGrid,
            ),
      ),
    );
    expect(result.graySourceConversionCount, 0);
  });

  test('native option bounds match FFI and accepted metric depth floor', () {
    final input = fixture();
    expect(
      () => BcdDetectorFreeJobBuilder.buildAllExperimental(
        bundle: input.bundle,
        assetReader: _FixtureAssetReader(input.gray, input.rgb),
        floorValue: 0,
        selectedFloor: floor,
        certifiedWalls: const <StructuralWall>[],
        options: const BcdDetectorFreeJobBuilderOptions.certified(),
      ),
      throwsArgumentError,
      reason: 'certified policy cannot enter through the experimental route',
    );
    final validEdge = build(
      input,
      options: const BcdDetectorFreeJobBuilderOptions.experimental(
        depthCount: 2,
        patchN: 1,
        exclusionRadiusSamples: 1,
      ),
    );
    expect(validEdge.plans, hasLength(baseCenters.length));
    expect(
      () => validEdge.plans
          .singleWhere((plan) => plan.referenceFrameId == 30)
          .materializePrimaryDepthJob(),
      returnsNormally,
    );

    for (final invalid in <BcdDetectorFreeJobBuilderOptions>[
      const BcdDetectorFreeJobBuilderOptions.experimental(depthCount: 1),
      const BcdDetectorFreeJobBuilderOptions.experimental(depthCount: 65),
      const BcdDetectorFreeJobBuilderOptions.experimental(patchN: 2),
      const BcdDetectorFreeJobBuilderOptions.experimental(patchN: 7),
      const BcdDetectorFreeJobBuilderOptions.experimental(nccMin: -0.01),
      const BcdDetectorFreeJobBuilderOptions.experimental(nccMin: 1.01),
      const BcdDetectorFreeJobBuilderOptions.experimental(
        uniqueDepthMargin: 2.01,
      ),
      const BcdDetectorFreeJobBuilderOptions.experimental(
        exclusionRadiusSamples: 48,
      ),
    ]) {
      expect(() => build(input, options: invalid), throwsArgumentError);
    }

    final tooNear = fixture(
      sparse: Float32List.fromList(<double>[
        0,
        0,
        0.040,
        0,
        0,
        0.041,
        0,
        0,
        0.042,
        0,
        0,
        0.043,
        0,
        0,
        0.044,
        0,
        0,
        0.045,
        0,
        0,
        0.046,
        0,
        0,
        0.047,
      ]),
    );
    final skipped = build(
      tooNear,
      options: const BcdDetectorFreeJobBuilderOptions.experimental(),
    );
    expect(skipped.hasWork, isFalse);
    expect(
      skipped.skippedReferences
          .singleWhere((skip) => skip.frameId == 30)
          .reason,
      BcdDetectorFreeSkipReason.insufficientSparseDepthSupport,
    );
  });

  test('non-16:9 area resize and independent K scales match research grid', () {
    final input = fixture(
      grayWidth: 200,
      grayHeight: 100,
      fx: 100,
      fy: 80,
      cx: 50,
      cy: 25,
      gradientReference: true,
    );
    final result = build(input);
    final job = result.plans
        .singleWhere((plan) => plan.referenceFrameId == 30)
        .materializePrimaryDepthJob();

    expect(job.options.imageWidth, 128);
    expect(job.options.imageHeight, 72);
    expect(
      job.options.referenceInverseK,
      closeList(<double>[1 / 64, 0, -0.5, 0, 1 / 57.6, -0.3125, 0, 0, 1]),
    );
    expect(job.grayFrames.first, 3);
  });

  test('128x72 lazy solve bounds 4K eager-float amplification', () {
    const sourceCounts = <int>[7, 7, 7, 7, 7, 7, 7, 7];
    final solveValues = BcdDetectorFreeJobBuilder.estimateGrayFloatValues(
      width: 128,
      height: 72,
      sourceCountsByJob: sourceCounts,
    );
    final accidental4kValues =
        BcdDetectorFreeJobBuilder.estimateGrayFloatValues(
          width: 4000,
          height: 3000,
          sourceCountsByJob: sourceCounts,
        );

    expect(solveValues, 8 * 8 * 128 * 72);
    expect(accidental4kValues, 8 * 8 * 4000 * 3000);
    expect(accidental4kValues / solveValues, greaterThan(1300));
    final input = fixture();
    final planned = build(input);
    expect(planned.graySourceConversionCount, 0);
    expect(planned.materializedJobGrayFloatValueCount, 0);
  });
}

Matcher closeList(List<double> expected, [double tolerance = 1e-5]) =>
    pairwiseCompare<num, double>(
      expected,
      (actual, wanted) => (actual - wanted).abs() <= tolerance,
      'values within $tolerance',
    );

double _float32(double value) => Float32List.fromList(<double>[value]).single;

int _float32Bits(double value) =>
    Uint32List.view(Float32List.fromList(<double>[value]).buffer).single;

class _FixtureAssetReader implements BcdDetectorFreeAssetReader {
  const _FixtureAssetReader(
    this.gray,
    this.rgb, {
    this.provenance = BcdDetectorFreePhotometricProvenance.jpegRgbArea,
  });

  final Map<int, Uint8List> gray;
  final Map<int, Uint8List> rgb;
  final BcdDetectorFreePhotometricProvenance provenance;

  @override
  BcdDetectorFreeSolveAsset? readSolveAsset(
    BcdFinalizeRegisteredFrameInput input, {
    required int width,
    required int height,
  }) {
    final frame = input.cameraFrame;
    final sourceGray = gray[frame.frameId];
    if (sourceGray == null) return null;
    final solveGray = _fixtureAreaResize(
      sourceGray,
      sourceWidth: frame.grayWidth,
      sourceHeight: frame.grayHeight,
      targetWidth: width,
      targetHeight: height,
      channels: 1,
    );
    final sourceRgb = rgb[frame.frameId];
    final solveRgb = sourceRgb == null
        ? null
        : _fixtureAreaResize(
            sourceRgb,
            sourceWidth: frame.grayWidth,
            sourceHeight: frame.grayHeight,
            targetWidth: width,
            targetHeight: height,
            channels: 3,
          );
    return BcdDetectorFreeSolveAsset(
      frameId: frame.frameId,
      width: width,
      height: height,
      gray: solveGray,
      rgb: solveRgb,
      grayDigest: sha256.convert(solveGray).toString(),
      rgbDigest: solveRgb == null ? null : sha256.convert(solveRgb).toString(),
      provenance: provenance,
    );
  }
}

Uint8List _fixtureAreaResize(
  Uint8List source, {
  required int sourceWidth,
  required int sourceHeight,
  required int targetWidth,
  required int targetHeight,
  required int channels,
}) {
  final output = Uint8List(targetWidth * targetHeight * channels);
  final scaleX = sourceWidth / targetWidth;
  final scaleY = sourceHeight / targetHeight;
  final normalization = scaleX * scaleY;
  for (var targetY = 0; targetY < targetHeight; targetY++) {
    final y0 = targetY * scaleY;
    final y1 = (targetY + 1) * scaleY;
    for (var targetX = 0; targetX < targetWidth; targetX++) {
      final x0 = targetX * scaleX;
      final x1 = (targetX + 1) * scaleX;
      for (var channel = 0; channel < channels; channel++) {
        var weighted = 0.0;
        for (var y = y0.floor(); y < math.min(sourceHeight, y1.ceil()); y++) {
          final wy = math.min(y1, y + 1.0) - math.max(y0, y.toDouble());
          for (var x = x0.floor(); x < math.min(sourceWidth, x1.ceil()); x++) {
            final wx = math.min(x1, x + 1.0) - math.max(x0, x.toDouble());
            weighted +=
                source[(y * sourceWidth + x) * channels + channel] * wx * wy;
          }
        }
        output[(targetY * targetWidth + targetX) * channels + channel] =
            (weighted / normalization).round().clamp(0, 255).toInt();
      }
    }
  }
  return output;
}
