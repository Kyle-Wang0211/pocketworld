import 'dart:math' as math;

enum RawXrslamPoseClassification {
  valid,
  initializing,
  trackingFailed,
  degenerate,
  malformed,
}

/// Shared Dart interpretation of the official XRSLAM raw state + pose bytes.
/// Native adapters only report that both void C calls completed.
RawXrslamPoseClassification classifyRawXrslamPose(Map<String, Object?> wire) {
  if (wire['rawStateCallCompleted'] != true ||
      wire['rawCameraPoseCallCompleted'] != true) {
    return RawXrslamPoseClassification.malformed;
  }
  final int? state = _integer(wire['rawXrslamState']);
  if (state == 0) return RawXrslamPoseClassification.initializing;
  if (state == 2) return RawXrslamPoseClassification.trackingFailed;
  if (state != 1) return RawXrslamPoseClassification.malformed;
  if (_finiteDouble(wire['xrslamPoseTimestamp']) == null) {
    return RawXrslamPoseClassification.degenerate;
  }
  final _RigidTransform? pose = _RigidTransform.fromQuaternionTranslation(
    wire['xrslamWorldFromCamera'],
  );
  return pose == null
      ? RawXrslamPoseClassification.degenerate
      : RawXrslamPoseClassification.valid;
}

/// Privacy-safe aggregate produced by the cross-platform Dart comparator.
///
/// The authority boundary is code, not input data: native wire values cannot
/// promote XRSLAM or add a decision consumer.
class VioShadowComparisonSummary {
  const VioShadowComparisonSummary({
    required this.schemaValid,
    required this.nativeOfferedCount,
    required this.nativeDroppedCount,
    required this.alignmentInitialized,
    required this.pairCount,
    required this.acceptedPairCount,
    required this.sampleCount,
    required this.referenceTrackingRejectedCount,
    required this.timestampInvalidCount,
    required this.timestampMismatchCount,
    required this.malformedPairCount,
    required this.translationRmseM,
    required this.translationMaxM,
    required this.rotationRmseDeg,
    required this.rotationMaxDeg,
  });

  const VioShadowComparisonSummary.empty()
    : schemaValid = false,
      nativeOfferedCount = 0,
      nativeDroppedCount = 0,
      alignmentInitialized = false,
      pairCount = 0,
      acceptedPairCount = 0,
      sampleCount = 0,
      referenceTrackingRejectedCount = 0,
      timestampInvalidCount = 0,
      timestampMismatchCount = 0,
      malformedPairCount = 0,
      translationRmseM = -1,
      translationMaxM = -1,
      rotationRmseDeg = -1,
      rotationMaxDeg = -1;

  String get authority => 'shadow';
  int get decisionConsumers => 0;
  String get alignmentMethod => 'first-valid-pair-se3';

  final bool schemaValid;
  final int nativeOfferedCount;
  final int nativeDroppedCount;
  final bool alignmentInitialized;
  final int pairCount;
  final int acceptedPairCount;

  /// Residual samples exclude the first accepted pair because it defines the
  /// alignment and would otherwise contribute a tautological zero.
  final int sampleCount;
  final int referenceTrackingRejectedCount;
  final int timestampInvalidCount;
  final int timestampMismatchCount;
  final int malformedPairCount;
  final double translationRmseM;
  final double translationMaxM;
  final double rotationRmseDeg;
  final double rotationMaxDeg;

  double get validPairRate =>
      nativeOfferedCount == 0 ? 0 : acceptedPairCount / nativeOfferedCount;
  double get deliveryRate => nativeOfferedCount == 0
      ? 0
      : (nativeOfferedCount - nativeDroppedCount) / nativeOfferedCount;

  Map<String, Object?> toJson() => <String, Object?>{
    'authority': authority,
    'decisionConsumers': decisionConsumers,
    'alignmentMethod': alignmentMethod,
    'schemaValid': schemaValid,
    'nativeOfferedCount': nativeOfferedCount,
    'nativeDroppedCount': nativeDroppedCount,
    'deliveryRate': deliveryRate,
    'alignmentInitialized': alignmentInitialized,
    'pairCount': pairCount,
    'acceptedPairCount': acceptedPairCount,
    'validPairRate': validPairRate,
    'sampleCount': sampleCount,
    'referenceTrackingRejectedCount': referenceTrackingRejectedCount,
    'timestampInvalidCount': timestampInvalidCount,
    'timestampMismatchCount': timestampMismatchCount,
    'malformedPairCount': malformedPairCount,
    'alignedTranslationRmseM': translationRmseM,
    'alignedTranslationMaxM': translationMaxM,
    'alignedRotationRmseDeg': rotationRmseDeg,
    'alignedRotationMaxDeg': rotationMaxDeg,
  };
}

/// Incremental, cross-platform SE(3) comparator for ARKit/ARCore vs XRSLAM.
///
/// `consumeSnapshot` is deliberately the only raw-wire entry point. It parses
/// each pair into temporary rigid transforms, updates scalar aggregates, then
/// drops the pair. No absolute pose or matrix is exposed by [summary].
class VioShadowSe3ComparisonAccumulator {
  VioShadowSe3ComparisonAccumulator({
    this.timestampToleranceSeconds = 1.0 / 120.0,
  }) : assert(timestampToleranceSeconds >= 0);

  final double timestampToleranceSeconds;

  int? _sessionGeneration;
  int? _lastSequence;
  int _nativeOfferedCount = 0;
  int _nativeDroppedCount = 0;
  bool _nativeLedgerSeen = false;
  bool _nativeLedgerConsistent = true;
  _RigidTransform? _referenceFromXrslam;
  int _pairCount = 0;
  int _acceptedPairCount = 0;
  int _sampleCount = 0;
  int _referenceTrackingRejectedCount = 0;
  int _timestampInvalidCount = 0;
  int _timestampMismatchCount = 0;
  int _malformedPairCount = 0;
  double _translationSquaredSum = 0;
  double _translationMaxM = 0;
  double _rotationSquaredSumDeg = 0;
  double _rotationMaxDeg = 0;

  void reset() {
    _sessionGeneration = null;
    _resetAggregates();
  }

  void _resetAggregates() {
    _lastSequence = null;
    _nativeOfferedCount = 0;
    _nativeDroppedCount = 0;
    _nativeLedgerSeen = false;
    _nativeLedgerConsistent = true;
    _referenceFromXrslam = null;
    _pairCount = 0;
    _acceptedPairCount = 0;
    _sampleCount = 0;
    _referenceTrackingRejectedCount = 0;
    _timestampInvalidCount = 0;
    _timestampMismatchCount = 0;
    _malformedPairCount = 0;
    _translationSquaredSum = 0;
    _translationMaxM = 0;
    _rotationSquaredSumDeg = 0;
    _rotationMaxDeg = 0;
  }

  /// Expected transient wire schema:
  ///
  /// ```text
  /// poseObservations: [
  ///   {
  ///     seq: int,
  ///     sensorTimestamp: double,
  ///     xrslamPoseTimestamp: double,
  ///     referenceTrackingState: raw platform enum string,
  ///     referenceTrackingReason: raw platform reason string,
  ///     referenceWorldFromCamera: 16 finite doubles (column-major),
  ///     xrslamWorldFromCamera: {qx,qy,qz,qw,tx,ty,tz: double}
  ///   }
  /// ]
  /// ```
  ///
  /// A repeated native snapshot is safe: monotonically increasing `seq`
  /// values are consumed once. A changed `sessionGeneration` resets alignment
  /// and aggregates before consuming the new session.
  void consumeSnapshot(Map<String, Object?> wire) {
    final int? generation = _integer(wire['sessionGeneration']);
    if (generation == null || generation < 0) return;
    if (_sessionGeneration != null && generation < _sessionGeneration!) {
      // Async polling may deliver an old response after a newer generation.
      // It must not roll alignment or counters backwards.
      return;
    }
    if (_sessionGeneration == null || generation > _sessionGeneration!) {
      _resetAggregates();
    }
    _sessionGeneration = generation;

    final int? offered = _integer(wire['poseObservationsOffered']);
    final int? dropped = _integer(wire['poseObservationsDropped']);
    if (offered == null || offered < 0 || dropped == null || dropped < 0) {
      _nativeLedgerConsistent = false;
    } else {
      _nativeLedgerSeen = true;
      if (offered < _nativeOfferedCount ||
          dropped < _nativeDroppedCount ||
          dropped > offered) {
        _nativeLedgerConsistent = false;
      } else {
        _nativeOfferedCount = offered;
        _nativeDroppedCount = dropped;
      }
    }

    final Object? rawPairs = wire['poseObservations'];
    if (rawPairs is! List) return;

    // Snapshot rings may repeat old entries. Sort only temporary map references
    // so an out-of-order platform payload cannot make an unseen lower seq look
    // stale. Nothing from this list is retained after the method returns.
    final List<_SequencedWirePair> candidates = <_SequencedWirePair>[];
    for (final Object? raw in rawPairs) {
      final Map<String, Object?>? map = _stringMap(raw);
      if (map == null) continue;
      final int? seq = _integer(map['seq']);
      if (seq == null || (_lastSequence != null && seq <= _lastSequence!)) {
        continue;
      }
      candidates.add(_SequencedWirePair(seq, map));
    }
    candidates.sort(
      (_SequencedWirePair a, _SequencedWirePair b) => a.seq.compareTo(b.seq),
    );

    for (final _SequencedWirePair candidate in candidates) {
      if (_lastSequence != null && candidate.seq <= _lastSequence!) continue;
      _lastSequence = candidate.seq;
      _pairCount++;

      final RawXrslamPoseClassification poseClass = classifyRawXrslamPose(
        candidate.wire,
      );
      if (poseClass == RawXrslamPoseClassification.malformed) {
        _malformedPairCount++;
        continue;
      }
      if (poseClass == RawXrslamPoseClassification.degenerate) {
        if (_finiteDouble(candidate.wire['xrslamPoseTimestamp']) == null) {
          _timestampInvalidCount++;
        } else {
          _malformedPairCount++;
        }
        continue;
      }
      if (poseClass != RawXrslamPoseClassification.valid) continue;

      final Object? referenceTrackingState =
          candidate.wire['referenceTrackingState'];
      final Object? referenceTrackingReason =
          candidate.wire['referenceTrackingReason'];
      if (referenceTrackingState is! String ||
          referenceTrackingReason is! String ||
          !_validTrackingFact(
            state: referenceTrackingState,
            reason: referenceTrackingReason,
          )) {
        _malformedPairCount++;
        continue;
      }
      // Shared Dart policy: only the raw platform `normal` state is usable as
      // a reference. Swift/Android glue merely serializes its native enum.
      if (referenceTrackingState != 'normal') {
        _referenceTrackingRejectedCount++;
        continue;
      }

      final double? sensorTimestamp = _finiteDouble(
        candidate.wire['sensorTimestamp'],
      );
      final double? poseTimestamp = _finiteDouble(
        candidate.wire['xrslamPoseTimestamp'],
      );
      if (sensorTimestamp == null || poseTimestamp == null) {
        _timestampInvalidCount++;
        continue;
      }
      if ((sensorTimestamp - poseTimestamp).abs() > timestampToleranceSeconds) {
        _timestampMismatchCount++;
        continue;
      }

      final _RigidTransform? referenceWorldFromCamera =
          _RigidTransform.fromColumnMajor4x4(
            candidate.wire['referenceWorldFromCamera'],
          );
      final _RigidTransform? xrslamWorldFromCamera =
          _RigidTransform.fromQuaternionTranslation(
            candidate.wire['xrslamWorldFromCamera'],
          );
      if (referenceWorldFromCamera == null || xrslamWorldFromCamera == null) {
        _malformedPairCount++;
        continue;
      }

      _acceptedPairCount++;
      if (_referenceFromXrslam == null) {
        // XRSLAMGetCameraPose returns T_xr_cam (camera pose in XRSLAM world).
        // Align worlds once: T_ref_xr = T_ref_cam * inverse(T_xr_cam).
        _referenceFromXrslam = referenceWorldFromCamera.multiply(
          xrslamWorldFromCamera.inverse(),
        );
        continue;
      }

      final _RigidTransform predictedReferenceWorldFromCamera =
          _referenceFromXrslam!.multiply(xrslamWorldFromCamera);
      final double translationError = referenceWorldFromCamera
          .translationDistanceTo(predictedReferenceWorldFromCamera);
      final double rotationErrorDeg = referenceWorldFromCamera
          .rotationDistanceDegreesTo(predictedReferenceWorldFromCamera);
      if (!translationError.isFinite || !rotationErrorDeg.isFinite) {
        // This is defensive; validated rigid transforms should never reach it.
        _acceptedPairCount--;
        _malformedPairCount++;
        continue;
      }
      _sampleCount++;
      _translationSquaredSum += translationError * translationError;
      _translationMaxM = math.max(_translationMaxM, translationError);
      _rotationSquaredSumDeg += rotationErrorDeg * rotationErrorDeg;
      _rotationMaxDeg = math.max(_rotationMaxDeg, rotationErrorDeg);
    }
  }

  VioShadowComparisonSummary get summary => VioShadowComparisonSummary(
    schemaValid:
        _sessionGeneration != null &&
        _nativeLedgerSeen &&
        _nativeLedgerConsistent &&
        _nativeOfferedCount == _pairCount + _nativeDroppedCount,
    nativeOfferedCount: _nativeOfferedCount,
    nativeDroppedCount: _nativeDroppedCount,
    alignmentInitialized: _referenceFromXrslam != null,
    pairCount: _pairCount,
    acceptedPairCount: _acceptedPairCount,
    sampleCount: _sampleCount,
    referenceTrackingRejectedCount: _referenceTrackingRejectedCount,
    timestampInvalidCount: _timestampInvalidCount,
    timestampMismatchCount: _timestampMismatchCount,
    malformedPairCount: _malformedPairCount,
    translationRmseM: _sampleCount == 0
        ? -1
        : math.sqrt(_translationSquaredSum / _sampleCount),
    translationMaxM: _sampleCount == 0 ? -1 : _translationMaxM,
    rotationRmseDeg: _sampleCount == 0
        ? -1
        : math.sqrt(_rotationSquaredSumDeg / _sampleCount),
    rotationMaxDeg: _sampleCount == 0 ? -1 : _rotationMaxDeg,
  );

  /// Preserve the immutable aggregate while erasing the first-pair alignment,
  /// matrices, sequence cursor, and all per-run raw-derived counters.
  VioShadowComparisonSummary takeSummaryAndReset() {
    final VioShadowComparisonSummary result = summary;
    reset();
    return result;
  }
}

bool _validTrackingFact({required String state, required String reason}) {
  switch (state) {
    case 'normal':
    case 'notAvailable':
      return reason == 'none';
    case 'limited':
      return reason == 'initializing' ||
          reason == 'excessiveMotion' ||
          reason == 'insufficientFeatures' ||
          reason == 'relocalizing' ||
          reason == 'unknown';
    case 'unknown':
      return reason == 'unknown';
    default:
      return false;
  }
}

class _SequencedWirePair {
  const _SequencedWirePair(this.seq, this.wire);
  final int seq;
  final Map<String, Object?> wire;
}

Map<String, Object?>? _stringMap(Object? value) {
  if (value is! Map) return null;
  final Map<String, Object?> result = <String, Object?>{};
  for (final MapEntry<Object?, Object?> entry in value.entries) {
    if (entry.key is String) result[entry.key! as String] = entry.value;
  }
  return result;
}

int? _integer(Object? value) {
  if (value is! num || !value.isFinite) return null;
  final int integer = value.toInt();
  return value.toDouble() == integer.toDouble() ? integer : null;
}

double? _finiteDouble(Object? value) {
  if (value is! num) return null;
  final double result = value.toDouble();
  return result.isFinite ? result : null;
}

class _RigidTransform {
  const _RigidTransform(this.rotation, this.translation);

  /// Row-major 3x3 rotation.
  final List<double> rotation;
  final List<double> translation;

  static _RigidTransform? fromColumnMajor4x4(Object? raw) {
    if (raw is! List || raw.length != 16) return null;
    final List<double> m = <double>[];
    for (final Object? value in raw) {
      final double? finite = _finiteDouble(value);
      if (finite == null) return null;
      m.add(finite);
    }
    const double affineTolerance = 1e-6;
    if (m[3].abs() > affineTolerance ||
        m[7].abs() > affineTolerance ||
        m[11].abs() > affineTolerance ||
        (m[15] - 1).abs() > affineTolerance) {
      return null;
    }
    final List<double> rotation = <double>[
      m[0],
      m[4],
      m[8],
      m[1],
      m[5],
      m[9],
      m[2],
      m[6],
      m[10],
    ];
    if (!_isRotation(rotation)) return null;
    return _RigidTransform(rotation, <double>[m[12], m[13], m[14]]);
  }

  static _RigidTransform? fromQuaternionTranslation(Object? raw) {
    final Map<String, Object?>? pose = _stringMap(raw);
    if (pose == null) return null;
    final double? rawX = _finiteDouble(pose['qx']);
    final double? rawY = _finiteDouble(pose['qy']);
    final double? rawZ = _finiteDouble(pose['qz']);
    final double? rawW = _finiteDouble(pose['qw']);
    final double? tx = _finiteDouble(pose['tx']);
    final double? ty = _finiteDouble(pose['ty']);
    final double? tz = _finiteDouble(pose['tz']);
    if (rawX == null ||
        rawY == null ||
        rawZ == null ||
        rawW == null ||
        tx == null ||
        ty == null ||
        tz == null) {
      return null;
    }
    final double norm = math.sqrt(
      rawX * rawX + rawY * rawY + rawZ * rawZ + rawW * rawW,
    );
    if (!norm.isFinite || norm < 1e-12) return null;
    final double x = rawX / norm;
    final double y = rawY / norm;
    final double z = rawZ / norm;
    final double w = rawW / norm;
    final List<double> rotation = <double>[
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
    return _RigidTransform(rotation, <double>[tx, ty, tz]);
  }

  _RigidTransform multiply(_RigidTransform other) {
    final List<double> r = List<double>.filled(9, 0);
    for (int row = 0; row < 3; row++) {
      for (int col = 0; col < 3; col++) {
        for (int k = 0; k < 3; k++) {
          r[row * 3 + col] +=
              rotation[row * 3 + k] * other.rotation[k * 3 + col];
        }
      }
    }
    final List<double> rotatedTranslation = _rotate(other.translation);
    return _RigidTransform(r, <double>[
      rotatedTranslation[0] + translation[0],
      rotatedTranslation[1] + translation[1],
      rotatedTranslation[2] + translation[2],
    ]);
  }

  _RigidTransform inverse() {
    final List<double> transpose = <double>[
      rotation[0],
      rotation[3],
      rotation[6],
      rotation[1],
      rotation[4],
      rotation[7],
      rotation[2],
      rotation[5],
      rotation[8],
    ];
    final _RigidTransform rotationOnly = _RigidTransform(
      transpose,
      const <double>[0, 0, 0],
    );
    final List<double> inverseTranslation = rotationOnly._rotate(translation);
    return _RigidTransform(transpose, <double>[
      -inverseTranslation[0],
      -inverseTranslation[1],
      -inverseTranslation[2],
    ]);
  }

  List<double> _rotate(List<double> value) => <double>[
    rotation[0] * value[0] + rotation[1] * value[1] + rotation[2] * value[2],
    rotation[3] * value[0] + rotation[4] * value[1] + rotation[5] * value[2],
    rotation[6] * value[0] + rotation[7] * value[1] + rotation[8] * value[2],
  ];

  double translationDistanceTo(_RigidTransform other) {
    final double dx = translation[0] - other.translation[0];
    final double dy = translation[1] - other.translation[1];
    final double dz = translation[2] - other.translation[2];
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }

  double rotationDistanceDegreesTo(_RigidTransform other) {
    // trace(R_this^T * R_other) without allocating the relative matrix.
    double trace = 0;
    for (int row = 0; row < 3; row++) {
      for (int col = 0; col < 3; col++) {
        trace += rotation[row * 3 + col] * other.rotation[row * 3 + col];
      }
    }
    final double cosine = ((trace - 1) / 2).clamp(-1.0, 1.0);
    return math.acos(cosine) * 180 / math.pi;
  }
}

bool _isRotation(List<double> r) {
  const double tolerance = 1e-4;
  for (int row = 0; row < 3; row++) {
    double norm = 0;
    for (int col = 0; col < 3; col++) {
      norm += r[row * 3 + col] * r[row * 3 + col];
    }
    if ((norm - 1).abs() > tolerance) return false;
  }
  for (int a = 0; a < 3; a++) {
    for (int b = a + 1; b < 3; b++) {
      double dot = 0;
      for (int col = 0; col < 3; col++) {
        dot += r[a * 3 + col] * r[b * 3 + col];
      }
      if (dot.abs() > tolerance) return false;
    }
  }
  final double determinant =
      r[0] * (r[4] * r[8] - r[5] * r[7]) -
      r[1] * (r[3] * r[8] - r[5] * r[6]) +
      r[2] * (r[3] * r[7] - r[4] * r[6]);
  return (determinant - 1).abs() <= tolerance;
}
