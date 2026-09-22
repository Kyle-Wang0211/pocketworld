// Pure input assembly for the B/C/D post-capture finalize pipeline.
//
// The refined SfM snapshot owns registration. Its delivered XYZ has already
// been rotated into the AR gravity world, while posesPacked intentionally stays
// in COLMAP gauge. The durable fed-frame metadata therefore owns both the
// frame-exact image calibration and the matching AR CamFromWorld geometry.

import 'dart:collection';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'bcd_finalize_coordinator.dart';
import 'bcd_sim3_alignment.dart';
import 'gravity_align.dart';
import 'sfm_live_recon.dart';

class BcdFinalizeRegisteredFrameInput {
  const BcdFinalizeRegisteredFrameInput({
    required this.cameraFrame,
    required this.grayPath,
  });

  final BcdRegisteredCameraFrame cameraFrame;
  final String grayPath;
}

/// Immutable, deterministically ordered image input for B/C/D finalize.
///
/// [registeredViews] is the positive-depth coordinator request consumed by B.
/// [registeredFrameInputs] retains the frame-exact gray path required by D or
/// by a later cross-platform image decoder. No method in this type deletes,
/// rewrites, or filters sparse points.
class BcdFinalizeInputBundle {
  BcdFinalizeInputBundle._({
    required List<BcdFinalizeRegisteredFrameInput> registeredFrameInputs,
    required List<BcdPlaneSweepView> registeredViews,
    required this.metricSparseXyz,
    required Float64List metricSolvedPosesPacked,
    required this.sim3,
  }) : registeredFrameInputs = List.unmodifiable(registeredFrameInputs),
       registeredViews = List.unmodifiable(registeredViews),
       registeredFrames = List.unmodifiable(
         registeredFrameInputs.map((input) => input.cameraFrame),
       ),
       metricSolvedPosesPacked = Float64List.fromList(metricSolvedPosesPacked),
       grayPathByFrameId = UnmodifiableMapView({
         for (final input in registeredFrameInputs)
           input.cameraFrame.frameId: input.grayPath,
       });

  final List<BcdFinalizeRegisteredFrameInput> registeredFrameInputs;
  final List<BcdRegisteredCameraFrame> registeredFrames;
  final List<BcdPlaneSweepView> registeredViews;
  final Map<int, String> grayPathByFrameId;

  /// A copy of the original sparse XYZ transformed into metric AR gravity
  /// coordinates. B/C/D must consume this buffer; the snapshot buffer remains
  /// byte-identical for append-only publication.
  final Float32List metricSparseXyz;

  /// Registered solved CamFromWorld rows in metric positive-depth/COLMAP
  /// convention: `[frameId, 1, qw,qx,qy,qz, tx,ty,tz]`. This preserves the BA
  /// cameras after the same Sim(3) used for [metricSparseXyz].
  final Float64List metricSolvedPosesPacked;

  /// Bidirectional snapshot-gravity ↔ metric-AR similarity. New point births
  /// are transformed back through [metricBirthToSnapshot] before publication.
  final BcdSim3Alignment sim3;

  Float32List metricPointsToSnapshot(Float32List metricXyz) =>
      sim3.inversePoints(metricXyz);

  BcdPointCloud metricBirthToSnapshot(BcdPointCloud metricBirth) =>
      sim3.inverseBirthCloud(metricBirth);
}

class BcdFinalizeInputBuilder {
  BcdFinalizeInputBuilder._();

  /// Joins registration bits from [snapshot] with exact durable frame data.
  ///
  /// [grayPathByFrameId] comes from the durable SfM manifest/replay owner. It
  /// is explicit because [SfmFedFrameMeta] deliberately contains sampling
  /// geometry rather than queue-file ownership. Legacy resume metadata used
  /// zero intrinsics as placeholders; such captures fail here instead of
  /// silently projecting B/C/D evidence through an invalid camera matrix.
  ///
  /// A refined snapshot delivered by [SfmLiveRecon] has XYZ in a rotated but
  /// still arbitrary-scale/translation gravity gauge. This builder estimates a
  /// full metric Sim(3) from solved camera centres to durable AR centres, then
  /// transforms both XYZ and solved CamFromWorld poses into that same gauge.
  /// Raw AR camera poses are never used as the final projection cameras.
  static BcdFinalizeInputBundle build({
    required SfmLiveSnapshot snapshot,
    required Map<int, SfmFedFrameMeta> fedFrameMeta,
    required Map<int, String> grayPathByFrameId,
  }) {
    if (!snapshot.refined) {
      throw StateError('B/C/D finalize requires a refined SfM snapshot');
    }
    if (snapshot.xyz.isEmpty ||
        snapshot.xyz.length % 3 != 0 ||
        snapshot.xyz.any((value) => !value.isFinite)) {
      throw ArgumentError('refined sparse XYZ is empty or malformed');
    }
    final poses = snapshot.posesPacked;
    if (poses.isEmpty || poses.length % 9 != 0) {
      throw ArgumentError(
        'SfM pose snapshot is empty or has an invalid stride',
      );
    }

    final registeredFrameIds = <int>[];
    final seenFrameIds = <int>{};
    final poseOffsetByFrameId = <int, int>{};
    for (var offset = 0; offset < poses.length; offset += 9) {
      final rawFrameId = poses[offset];
      final rawRegistered = poses[offset + 1];
      if (!rawFrameId.isFinite ||
          rawFrameId < 0 ||
          rawFrameId != rawFrameId.truncateToDouble() ||
          !rawRegistered.isFinite ||
          (rawRegistered != 0 && rawRegistered != 1)) {
        throw ArgumentError('SfM pose row is malformed at offset $offset');
      }
      final frameId = rawFrameId.toInt();
      if (!seenFrameIds.add(frameId)) {
        throw ArgumentError('SfM pose snapshot duplicates frame $frameId');
      }
      if (rawRegistered == 1) {
        registeredFrameIds.add(frameId);
        poseOffsetByFrameId[frameId] = offset;
      }
    }
    if (registeredFrameIds.isEmpty) {
      throw StateError('B/C/D finalize has no registered SfM frames');
    }
    registeredFrameIds.sort();

    for (final frameId in registeredFrameIds) {
      final meta = fedFrameMeta[frameId];
      if (meta == null) {
        throw StateError('registered frame $frameId has no fed-frame metadata');
      }
      _validateFedMeta(frameId, meta);
      final grayPath = grayPathByFrameId[frameId];
      if (grayPath == null || grayPath.trim().isEmpty) {
        throw StateError('registered frame $frameId has no durable gray path');
      }
      _validateGrayAsset(frameId, grayPath, meta.grayW * meta.grayH);
    }

    final sim3 = const BcdSim3AlignmentEstimator().estimate(
      posesPacked: poses,
      fedFrameMeta: fedFrameMeta,
    );
    _validateSim3(sim3);
    final gravityRotation = _recoverGravityRotation(poses, fedFrameMeta);
    final rawToMetricRotation = _multiply3x3(sim3.rotation, gravityRotation);
    final metricSparseXyz = sim3.forwardPoints(snapshot.xyz);

    final inputs = <BcdFinalizeRegisteredFrameInput>[];
    final metricSolvedPoses = <double>[];
    for (final frameId in registeredFrameIds) {
      final meta = fedFrameMeta[frameId]!;
      final grayPath = grayPathByFrameId[frameId]!;
      final poseOffset = poseOffsetByFrameId[frameId]!;
      final solvedRotation = _rotationFromQuaternion([
        poses[poseOffset + 2],
        poses[poseOffset + 3],
        poses[poseOffset + 4],
        poses[poseOffset + 5],
      ]);
      final metricPositiveRotation = _multiply3x3(
        solvedRotation,
        _transpose3x3(rawToMetricRotation),
      );
      final rotatedOrigin = _rotate3x3(
        metricPositiveRotation,
        sim3.translation,
      );
      final metricPositiveTranslation = <double>[
        sim3.scale * poses[poseOffset + 6] - rotatedOrigin[0],
        sim3.scale * poses[poseOffset + 7] - rotatedOrigin[1],
        sim3.scale * poses[poseOffset + 8] - rotatedOrigin[2],
      ];
      final metricPositiveQuaternion = _quaternionFromRotation(
        metricPositiveRotation,
      );
      metricSolvedPoses.addAll(<double>[
        frameId.toDouble(),
        1,
        ...metricPositiveQuaternion,
        ...metricPositiveTranslation,
      ]);
      // BcdRegisteredCameraFrame is OpenGL/AR (+Y up, -Z forward), while the
      // solved pose above is COLMAP/CV (+Y down, +Z forward). Coordinator later
      // applies this same self-inverse C=diag(1,-1,-1) to build K[R|t], so store
      // C*[Rcv|tcv] here exactly once rather than double-flipping projection.
      final metricOpenGlRotation = <double>[
        metricPositiveRotation[0],
        metricPositiveRotation[1],
        metricPositiveRotation[2],
        -metricPositiveRotation[3],
        -metricPositiveRotation[4],
        -metricPositiveRotation[5],
        -metricPositiveRotation[6],
        -metricPositiveRotation[7],
        -metricPositiveRotation[8],
      ];
      final metricOpenGlTranslation = <double>[
        metricPositiveTranslation[0],
        -metricPositiveTranslation[1],
        -metricPositiveTranslation[2],
      ];
      final metricQuaternion = _quaternionFromRotation(metricOpenGlRotation);
      inputs.add(
        BcdFinalizeRegisteredFrameInput(
          cameraFrame: BcdRegisteredCameraFrame(
            frameId: frameId,
            jpegPath: meta.jpegPath,
            imageWidth: meta.imageW,
            imageHeight: meta.imageH,
            grayWidth: meta.grayW,
            grayHeight: meta.grayH,
            grayFx: meta.fx,
            grayFy: meta.fy,
            grayCx: meta.cx,
            grayCy: meta.cy,
            cameraFromWorldQuaternionWxyz: List.unmodifiable(metricQuaternion),
            cameraFromWorldTranslation: List.unmodifiable(
              metricOpenGlTranslation,
            ),
          ),
          grayPath: grayPath,
        ),
      );
    }

    final frames = [for (final input in inputs) input.cameraFrame];
    final views = BcdFinalizeCoordinator.buildRegisteredPlaneSweepViews(frames);
    return BcdFinalizeInputBundle._(
      registeredFrameInputs: inputs,
      registeredViews: views,
      metricSparseXyz: metricSparseXyz,
      metricSolvedPosesPacked: Float64List.fromList(metricSolvedPoses),
      sim3: sim3,
    );
  }

  /// Typed entry point for the queue-owned, native-acknowledged asset list.
  /// File size is still checked at this consumption boundary so a payload lost
  /// after manifest validation fails closed before any native B/C/D work.
  static BcdFinalizeInputBundle buildFromDurableFedFrames({
    required SfmLiveSnapshot snapshot,
    required List<SfmDurableFedFrameInput> durableFedFrames,
  }) {
    final meta = <int, SfmFedFrameMeta>{};
    final grayPaths = <int, String>{};
    for (final input in durableFedFrames) {
      if (meta.containsKey(input.frameId)) {
        throw ArgumentError(
          'durable finalize input duplicates frame ${input.frameId}',
        );
      }
      meta[input.frameId] = input.meta;
      grayPaths[input.frameId] = input.grayPath;
    }
    return build(
      snapshot: snapshot,
      fedFrameMeta: meta,
      grayPathByFrameId: grayPaths,
    );
  }

  static void _validateFedMeta(int frameId, SfmFedFrameMeta meta) {
    if (meta.jpegPath.trim().isEmpty ||
        meta.imageW <= 1 ||
        meta.imageH <= 1 ||
        meta.grayW <= 1 ||
        meta.grayH <= 1) {
      throw StateError('registered frame $frameId has invalid image metadata');
    }
    if (!meta.fx.isFinite ||
        !meta.fy.isFinite ||
        !meta.cx.isFinite ||
        !meta.cy.isFinite ||
        meta.fx <= 0 ||
        meta.fy <= 0) {
      throw StateError(
        'registered frame $frameId is missing usable gray intrinsics; '
        'legacy resume metadata cannot run B/C/D',
      );
    }
    final q = meta.arkitQuatWxyz;
    final center = meta.arkitCameraCenterWorld;
    if (q == null ||
        center == null ||
        q.length != 4 ||
        center.length != 3 ||
        q.any((value) => !value.isFinite) ||
        center.any((value) => !value.isFinite) ||
        q.fold<double>(0, (sum, value) => sum + value * value) <= 1e-24) {
      throw StateError(
        'registered frame $frameId has no usable AR rotation/metric center',
      );
    }
  }

  static void _validateGrayAsset(
    int frameId,
    String grayPath,
    int expectedBytes,
  ) {
    try {
      final file = File(grayPath);
      if (!file.existsSync()) {
        throw StateError(
          'registered frame $frameId durable gray payload is missing',
        );
      }
      final actualBytes = file.lengthSync();
      if (actualBytes != expectedBytes) {
        throw StateError(
          'registered frame $frameId gray payload has $actualBytes bytes; '
          'expected $expectedBytes',
        );
      }
    } on StateError {
      rethrow;
    } on FileSystemException catch (error) {
      throw StateError(
        'registered frame $frameId gray payload cannot be verified: '
        '${error.message}',
      );
    }
  }

  static void _validateSim3(BcdSim3Alignment alignment) {
    final residuals = alignment.residuals;
    final minimumInliers = math.max(3, (residuals.pairCount * 0.8).ceil());
    if (!alignment.scale.isFinite ||
        alignment.scale <= 0 ||
        residuals.pairCount < 3 ||
        residuals.inlierCount < minimumInliers ||
        !residuals.median.isFinite ||
        !residuals.inlierThreshold.isFinite ||
        !residuals.p90.isFinite ||
        !residuals.rmse.isFinite ||
        !residuals.maximum.isFinite ||
        residuals.median > 0.10 ||
        residuals.p90 > 0.18 ||
        residuals.rmse > 0.12 ||
        residuals.maximum > 0.30 ||
        residuals.inlierThreshold > 0.30) {
      throw StateError(
        'metric Sim(3) failed residual gate: '
        'pairs=${residuals.pairCount} inliers=${residuals.inlierCount} '
        'median=${residuals.median} '
        'p90=${residuals.p90} rmse=${residuals.rmse} '
        'max=${residuals.maximum} threshold=${residuals.inlierThreshold} '
        'scale=${alignment.scale}',
      );
    }
  }

  /// Uses the same exact-double SO(3) that generated snapshot XYZ.
  /// Float32-rotated basis inference is forbidden because its rounded columns
  /// are not exactly SO(3) and change camera projection when orthogonalized.
  static List<double> _recoverGravityRotation(
    Float64List poses,
    Map<int, SfmFedFrameMeta> meta,
  ) {
    final rotation = gravityAlignmentRotationRowMajor(
      posesPacked: poses,
      arkitQuatWxyzOf: (frameId) => meta[frameId]?.arkitQuatWxyz,
    );
    if (rotation == null) {
      throw StateError('cannot recover the snapshot gravity rotation');
    }
    return rotation;
  }

  static List<double> _rotationFromQuaternion(List<double> q) {
    if (q.length != 4 || q.any((value) => !value.isFinite)) {
      throw ArgumentError('solved CamFromWorld quaternion is malformed');
    }
    final norm = math.sqrt(q.fold<double>(0, (sum, v) => sum + v * v));
    if (!(norm > 1e-12)) {
      throw ArgumentError('solved CamFromWorld quaternion is degenerate');
    }
    final w = q[0] / norm;
    final x = q[1] / norm;
    final y = q[2] / norm;
    final z = q[3] / norm;
    return <double>[
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
  }

  static List<double> _quaternionFromRotation(List<double> r) {
    if (r.length != 9 || r.any((value) => !value.isFinite)) {
      throw ArgumentError('metric CamFromWorld rotation is malformed');
    }
    final trace = r[0] + r[4] + r[8];
    late double w, x, y, z;
    if (trace > 0) {
      final s = math.sqrt(trace + 1) * 2;
      w = 0.25 * s;
      x = (r[7] - r[5]) / s;
      y = (r[2] - r[6]) / s;
      z = (r[3] - r[1]) / s;
    } else if (r[0] > r[4] && r[0] > r[8]) {
      final s = math.sqrt(1 + r[0] - r[4] - r[8]) * 2;
      w = (r[7] - r[5]) / s;
      x = 0.25 * s;
      y = (r[1] + r[3]) / s;
      z = (r[2] + r[6]) / s;
    } else if (r[4] > r[8]) {
      final s = math.sqrt(1 + r[4] - r[0] - r[8]) * 2;
      w = (r[2] - r[6]) / s;
      x = (r[1] + r[3]) / s;
      y = 0.25 * s;
      z = (r[5] + r[7]) / s;
    } else {
      final s = math.sqrt(1 + r[8] - r[0] - r[4]) * 2;
      w = (r[3] - r[1]) / s;
      x = (r[2] + r[6]) / s;
      y = (r[5] + r[7]) / s;
      z = 0.25 * s;
    }
    final norm = math.sqrt(w * w + x * x + y * y + z * z);
    if (!norm.isFinite || !(norm > 1e-12)) {
      throw StateError('metric CamFromWorld quaternion is degenerate');
    }
    final sign = w < 0 ? -1.0 : 1.0;
    return <double>[
      sign * w / norm,
      sign * x / norm,
      sign * y / norm,
      sign * z / norm,
    ];
  }

  static List<double> _multiply3x3(List<double> a, List<double> b) => <double>[
    for (var row = 0; row < 3; row++)
      for (var column = 0; column < 3; column++)
        a[row * 3] * b[column] +
            a[row * 3 + 1] * b[3 + column] +
            a[row * 3 + 2] * b[6 + column],
  ];

  static List<double> _transpose3x3(List<double> matrix) => <double>[
    matrix[0],
    matrix[3],
    matrix[6],
    matrix[1],
    matrix[4],
    matrix[7],
    matrix[2],
    matrix[5],
    matrix[8],
  ];

  static List<double> _rotate3x3(List<double> r, List<double> point) =>
      <double>[
        r[0] * point[0] + r[1] * point[1] + r[2] * point[2],
        r[3] * point[0] + r[4] * point[1] + r[5] * point[2],
        r[6] * point[0] + r[7] * point[1] + r[8] * point[2],
      ];
}
