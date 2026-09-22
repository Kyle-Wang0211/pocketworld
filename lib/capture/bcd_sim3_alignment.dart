// Deterministic metric Sim(3) bridge for B/C/D finalize.
//
// Refined sparse XYZ is rotated (but not translated or scaled) from COLMAP's
// arbitrary reconstruction gauge into the AR gravity gauge. posesPacked stays
// in the original COLMAP gauge. This module derives solved camera centres from
// those poses, applies the exact same gravity rotation used for sparse XYZ,
// and robustly aligns them to the durable metric AR camera centres.

import 'dart:math' as math;
import 'dart:typed_data';

import 'bcd_finalize_coordinator.dart';
import 'gravity_align.dart';
import 'sfm_live_recon.dart';

final class BcdSim3ResidualStatistics {
  const BcdSim3ResidualStatistics({
    required this.pairCount,
    required this.inlierCount,
    required this.rmse,
    required this.median,
    required this.p90,
    required this.maximum,
    required this.inlierThreshold,
    required this.hypothesisCount,
  });

  final int pairCount;
  final int inlierCount;
  final double rmse;
  final double median;
  final double p90;
  final double maximum;
  final double inlierThreshold;
  final int hypothesisCount;

  int get rejectedCount => pairCount - inlierCount;
}

/// `X_ar = scale * rotation * X_snapshot + translation`.
///
/// Lists are immutable and [rotation] is row-major 3x3. Every transform method
/// allocates a new result; source snapshot and birth buffers are never edited.
final class BcdSim3Alignment {
  BcdSim3Alignment._({
    required this.scale,
    required List<double> rotation,
    required List<double> translation,
    required List<int> pairedFrameIds,
    required this.residuals,
  }) : rotation = List<double>.unmodifiable(rotation),
       translation = List<double>.unmodifiable(translation),
       pairedFrameIds = List<int>.unmodifiable(pairedFrameIds);

  final double scale;
  final List<double> rotation;
  final List<double> translation;
  final List<int> pairedFrameIds;
  final BcdSim3ResidualStatistics residuals;

  List<double> forwardPoint(List<double> point) {
    _validatePoint(point, 'snapshot point');
    final rotated = _rotate(rotation, point);
    final transformed = <double>[
      scale * rotated[0] + translation[0],
      scale * rotated[1] + translation[1],
      scale * rotated[2] + translation[2],
    ];
    _validateTransformedPoint(transformed, 'forward metric point');
    return transformed;
  }

  List<double> inversePoint(List<double> point) {
    _validatePoint(point, 'AR point');
    final x = (point[0] - translation[0]) / scale;
    final y = (point[1] - translation[1]) / scale;
    final z = (point[2] - translation[2]) / scale;
    // R^-1 = R^T.
    final transformed = <double>[
      rotation[0] * x + rotation[3] * y + rotation[6] * z,
      rotation[1] * x + rotation[4] * y + rotation[7] * z,
      rotation[2] * x + rotation[5] * y + rotation[8] * z,
    ];
    _validateTransformedPoint(transformed, 'inverse snapshot point');
    return transformed;
  }

  Float32List forwardPoints(Float32List snapshotXyz) =>
      _transformPoints(snapshotXyz, forwardPoint, 'snapshot XYZ');

  Float32List inversePoints(Float32List arXyz) =>
      _transformPoints(arXyz, inversePoint, 'AR XYZ');

  /// Converts B/C/D births produced in metric AR coordinates back into the
  /// snapshot gauge expected by append-only publication. RGB is copied too, so
  /// neither the birth nor the original sparse cloud can be mutated by aliasing.
  BcdPointCloud inverseBirthCloud(BcdPointCloud arBirth) {
    if (arBirth.xyz.length % 3 != 0 ||
        arBirth.rgb.length != arBirth.xyz.length) {
      throw ArgumentError('birth XYZ/RGB dimensions do not match');
    }
    return BcdPointCloud(
      xyz: inversePoints(arBirth.xyz),
      rgb: Uint8List.fromList(arBirth.rgb),
    );
  }

  static Float32List _transformPoints(
    Float32List source,
    List<double> Function(List<double>) transform,
    String label,
  ) {
    if (source.length % 3 != 0) {
      throw ArgumentError('$label length must be divisible by three');
    }
    final output = Float32List(source.length);
    for (var offset = 0; offset < source.length; offset += 3) {
      final point = transform(<double>[
        source[offset],
        source[offset + 1],
        source[offset + 2],
      ]);
      output[offset] = point[0];
      output[offset + 1] = point[1];
      output[offset + 2] = point[2];
      if (!output[offset].isFinite ||
          !output[offset + 1].isFinite ||
          !output[offset + 2].isFinite) {
        throw StateError(
          '$label transform overflows Float32 at point ${offset ~/ 3}',
        );
      }
    }
    return output;
  }
}

final class BcdSim3AlignmentEstimator {
  const BcdSim3AlignmentEstimator({
    this.maximumHypotheses = hardMaximumHypotheses,
  });

  static const int hardMaximumHypotheses = 128;

  final int maximumHypotheses;

  BcdSim3Alignment estimate({
    required Float64List posesPacked,
    required Map<int, SfmFedFrameMeta> fedFrameMeta,
  }) {
    if (posesPacked.isEmpty || posesPacked.length % 9 != 0) {
      throw ArgumentError('posesPacked is empty or has an invalid stride');
    }
    if (maximumHypotheses < 1 || maximumHypotheses > hardMaximumHypotheses) {
      throw ArgumentError.value(maximumHypotheses, 'maximumHypotheses');
    }

    final poseRows = <_PoseRow>[];
    final frameIds = <int>{};
    for (var offset = 0; offset < posesPacked.length; offset += 9) {
      final rawId = posesPacked[offset];
      final registered = posesPacked[offset + 1];
      if (!rawId.isFinite ||
          rawId < 0 ||
          rawId != rawId.truncateToDouble() ||
          !registered.isFinite ||
          (registered != 0 && registered != 1)) {
        throw ArgumentError('malformed pose row at offset $offset');
      }
      final frameId = rawId.toInt();
      if (!frameIds.add(frameId)) {
        throw ArgumentError('duplicate pose frame $frameId');
      }
      if (registered == 0) continue;
      final quaternion = <double>[
        posesPacked[offset + 2],
        posesPacked[offset + 3],
        posesPacked[offset + 4],
        posesPacked[offset + 5],
      ];
      final translation = <double>[
        posesPacked[offset + 6],
        posesPacked[offset + 7],
        posesPacked[offset + 8],
      ];
      if (!_allFinite(quaternion) || !_allFinite(translation)) {
        throw ArgumentError('non-finite registered pose for frame $frameId');
      }
      final rotation = _rotationFromQuaternion(quaternion);
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
      poseRows.add(_PoseRow(frameId, center));
    }
    poseRows.sort((a, b) => a.frameId.compareTo(b.frameId));
    if (poseRows.length < 3) {
      throw StateError('Sim(3) needs at least three registered solved poses');
    }

    final gravityRotation = gravityAlignmentRotationRowMajor(
      posesPacked: posesPacked,
      arkitQuatWxyzOf: (frameId) => fedFrameMeta[frameId]?.arkitQuatWxyz,
    );
    if (gravityRotation == null) {
      throw StateError('cannot recover the snapshot gravity rotation');
    }

    final pairs = <_PointPair>[];
    for (var index = 0; index < poseRows.length; index++) {
      final frameId = poseRows[index].frameId;
      final target = fedFrameMeta[frameId]?.arkitCameraCenterWorld;
      if (target == null) continue;
      _validatePoint(target, 'AR camera center for frame $frameId');
      pairs.add(
        _PointPair(
          frameId,
          _rotate(gravityRotation, poseRows[index].center),
          List<double>.from(target),
        ),
      );
    }
    if (pairs.length < 3) {
      throw StateError(
        'Sim(3) needs at least three paired metric AR camera centres',
      );
    }
    _requireNonDegenerate(pairs);

    final seedSelection = _selectRobustSeed(pairs);
    final seed = seedSelection.model;
    final seedResiduals = _residuals(pairs, seed);
    final threshold = _robustThreshold(seedResiduals);
    var inliers = <_PointPair>[
      for (var index = 0; index < pairs.length; index++)
        if (seedResiduals[index] <= threshold) pairs[index],
    ];
    if (inliers.length < 3) {
      throw StateError('robust Sim(3) retained fewer than three inliers');
    }
    _requireNonDegenerate(inliers);

    var model = _fit(inliers);
    // Two deterministic Huber refinements retain real metric noise without
    // giving a surviving high residual the same leverage as a central pair.
    for (var iteration = 0; iteration < 2; iteration++) {
      final residuals = _residuals(inliers, model);
      final delta = math.max(_robustThreshold(residuals), 1e-7);
      final weights = <double>[
        for (final residual in residuals)
          residual <= delta ? 1.0 : delta / residual,
      ];
      model = _fit(inliers, weights: weights);
    }

    final finalResiduals = _residuals(pairs, model);
    final finalThreshold = _robustThreshold(finalResiduals);
    inliers = <_PointPair>[
      for (var index = 0; index < pairs.length; index++)
        if (finalResiduals[index] <= finalThreshold) pairs[index],
    ];
    if (inliers.length >= 3 && _isNonDegenerate(inliers)) {
      model = _fit(inliers);
    }
    final residuals = _residuals(pairs, model);
    final acceptedThreshold = _robustThreshold(residuals);
    final accepted = residuals.where((r) => r <= acceptedThreshold).length;
    final sorted = List<double>.from(residuals)..sort();
    final squared = residuals.fold<double>(0, (sum, r) => sum + r * r);
    final stats = BcdSim3ResidualStatistics(
      pairCount: pairs.length,
      inlierCount: accepted,
      rmse: math.sqrt(squared / residuals.length),
      median: _quantileSorted(sorted, 0.5),
      p90: _quantileSorted(sorted, 0.9),
      maximum: sorted.last,
      inlierThreshold: acceptedThreshold,
      hypothesisCount: seedSelection.hypothesisCount,
    );
    if (!model.scale.isFinite ||
        model.scale <= 0 ||
        !_allFinite(model.rotation) ||
        !_allFinite(model.translation) ||
        !stats.rmse.isFinite) {
      throw StateError(
        'Sim(3) solution is non-finite or has non-positive scale',
      );
    }
    return BcdSim3Alignment._(
      scale: model.scale,
      rotation: model.rotation,
      translation: model.translation,
      pairedFrameIds: pairs.map((pair) => pair.frameId).toList(),
      residuals: stats,
    );
  }

  _SeedSelection _selectRobustSeed(List<_PointPair> pairs) {
    if (pairs.length == 3) {
      return _SeedSelection(model: _fit(pairs), hypothesisCount: 1);
    }
    _Sim3? best;
    var bestMedian = double.infinity;
    var bestTrimmed = double.infinity;
    var hypotheses = 0;

    void consider(int a, int b, int c) {
      if (hypotheses >= maximumHypotheses) return;
      final sample = <_PointPair>[pairs[a], pairs[b], pairs[c]];
      if (!_isNonDegenerate(sample)) return;
      hypotheses++;
      _Sim3 candidate;
      try {
        candidate = _fit(sample);
      } catch (_) {
        return;
      }
      final residuals = _residuals(pairs, candidate)..sort();
      final median = _quantileSorted(residuals, 0.5);
      final keep = math.max(3, (residuals.length * 0.75).ceil());
      final trimmed = residuals.take(keep).fold<double>(0, (a, b) => a + b);
      if (median < bestMedian - 1e-12 ||
          ((median - bestMedian).abs() <= 1e-12 && trimmed < bestTrimmed)) {
        best = candidate;
        bestMedian = median;
        bestTrimmed = trimmed;
      }
    }

    final n = pairs.length;
    if (n <= 16) {
      for (var a = 0; a < n - 2 && hypotheses < maximumHypotheses; a++) {
        for (var b = a + 1; b < n - 1 && hypotheses < maximumHypotheses; b++) {
          for (var c = b + 1; c < n && hypotheses < maximumHypotheses; c++) {
            consider(a, b, c);
          }
        }
      }
    } else {
      // A lexicographic prefix would over-sample the earliest frame and could
      // make every bounded hypothesis contain the same bad pose. Cover the
      // whole trajectory first, then fill the budget with a fixed-seed LCG.
      final seen = <String>{};
      void considerUnique(int a, int b, int c) {
        final indices = <int>[a, b, c]..sort();
        if (indices[0] == indices[1] || indices[1] == indices[2]) return;
        final key = '${indices[0]}:${indices[1]}:${indices[2]}';
        if (seen.add(key)) consider(indices[0], indices[1], indices[2]);
      }

      for (
        var index = 0;
        index < n && hypotheses < maximumHypotheses;
        index++
      ) {
        considerUnique(index, (index + n ~/ 3) % n, (index + 2 * n ~/ 3) % n);
        considerUnique(index, (index + 1) % n, (index + n ~/ 2) % n);
      }
      var state = 0x4d595df4;
      var attempts = 0;
      while (hypotheses < maximumHypotheses &&
          attempts < maximumHypotheses * 40) {
        int nextIndex() {
          state = (1664525 * state + 1013904223) & 0x7fffffff;
          return state % n;
        }

        considerUnique(nextIndex(), nextIndex(), nextIndex());
        attempts++;
      }
    }
    if (best == null) {
      throw StateError('no non-degenerate deterministic Sim(3) hypothesis');
    }
    return _SeedSelection(model: best!, hypothesisCount: hypotheses);
  }
}

final class _PoseRow {
  const _PoseRow(this.frameId, this.center);
  final int frameId;
  final List<double> center;
}

final class _PointPair {
  const _PointPair(this.frameId, this.source, this.target);
  final int frameId;
  final List<double> source;
  final List<double> target;
}

final class _Sim3 {
  const _Sim3(this.scale, this.rotation, this.translation);
  final double scale;
  final List<double> rotation;
  final List<double> translation;
}

final class _SeedSelection {
  const _SeedSelection({required this.model, required this.hypothesisCount});

  final _Sim3 model;
  final int hypothesisCount;
}

_Sim3 _fit(List<_PointPair> pairs, {List<double>? weights}) {
  if (pairs.length < 3 || (weights != null && weights.length != pairs.length)) {
    throw ArgumentError('invalid Sim(3) fit inputs');
  }
  final w = weights ?? List<double>.filled(pairs.length, 1);
  var total = 0.0;
  final sourceMean = <double>[0, 0, 0];
  final targetMean = <double>[0, 0, 0];
  for (var i = 0; i < pairs.length; i++) {
    final weight = w[i];
    if (!weight.isFinite || weight < 0) throw ArgumentError('invalid weight');
    total += weight;
    for (var axis = 0; axis < 3; axis++) {
      sourceMean[axis] += weight * pairs[i].source[axis];
      targetMean[axis] += weight * pairs[i].target[axis];
    }
  }
  if (!total.isFinite || total <= 1e-12) throw StateError('zero fit weight');
  for (var axis = 0; axis < 3; axis++) {
    sourceMean[axis] /= total;
    targetMean[axis] /= total;
  }

  final cross = List<double>.filled(9, 0);
  var sourceVariance = 0.0;
  for (var i = 0; i < pairs.length; i++) {
    final dx = <double>[
      pairs[i].source[0] - sourceMean[0],
      pairs[i].source[1] - sourceMean[1],
      pairs[i].source[2] - sourceMean[2],
    ];
    final dy = <double>[
      pairs[i].target[0] - targetMean[0],
      pairs[i].target[1] - targetMean[1],
      pairs[i].target[2] - targetMean[2],
    ];
    final weight = w[i];
    sourceVariance += weight * _dot(dx, dx);
    for (var row = 0; row < 3; row++) {
      for (var column = 0; column < 3; column++) {
        // Horn's matrix below consumes source * target^T.
        cross[row * 3 + column] += weight * dx[row] * dy[column];
      }
    }
  }
  if (!sourceVariance.isFinite || sourceVariance <= 1e-14) {
    throw StateError('source camera centres have zero spread');
  }

  final sxx = cross[0], sxy = cross[1], sxz = cross[2];
  final syx = cross[3], syy = cross[4], syz = cross[5];
  final szx = cross[6], szy = cross[7], szz = cross[8];
  final trace = sxx + syy + szz;
  final horn = <List<double>>[
    <double>[trace, syz - szy, szx - sxz, sxy - syx],
    <double>[syz - szy, sxx - syy - szz, sxy + syx, szx + sxz],
    <double>[szx - sxz, sxy + syx, -sxx + syy - szz, syz + szy],
    <double>[sxy - syx, szx + sxz, syz + szy, -sxx - syy + szz],
  ];
  final quaternion = _largestEigenvectorSymmetric4(horn);
  final rotation = _rotationFromQuaternion(quaternion);

  var numerator = 0.0;
  for (var i = 0; i < pairs.length; i++) {
    final dx = <double>[
      pairs[i].source[0] - sourceMean[0],
      pairs[i].source[1] - sourceMean[1],
      pairs[i].source[2] - sourceMean[2],
    ];
    final dy = <double>[
      pairs[i].target[0] - targetMean[0],
      pairs[i].target[1] - targetMean[1],
      pairs[i].target[2] - targetMean[2],
    ];
    numerator += w[i] * _dot(dy, _rotate(rotation, dx));
  }
  final scale = numerator / sourceVariance;
  if (!scale.isFinite || scale <= 0) {
    throw StateError('similarity fit produced a non-positive scale');
  }
  final rotatedMean = _rotate(rotation, sourceMean);
  final translation = <double>[
    targetMean[0] - scale * rotatedMean[0],
    targetMean[1] - scale * rotatedMean[1],
    targetMean[2] - scale * rotatedMean[2],
  ];
  return _Sim3(scale, rotation, translation);
}

List<double> _largestEigenvectorSymmetric4(List<List<double>> source) {
  final matrix = <List<double>>[
    for (final row in source) List<double>.from(row),
  ];
  final vectors = <List<double>>[
    <double>[1, 0, 0, 0],
    <double>[0, 1, 0, 0],
    <double>[0, 0, 1, 0],
    <double>[0, 0, 0, 1],
  ];
  for (var iteration = 0; iteration < 80; iteration++) {
    var p = 0, q = 1;
    var largest = matrix[p][q].abs();
    for (var row = 0; row < 4; row++) {
      for (var column = row + 1; column < 4; column++) {
        final value = matrix[row][column].abs();
        if (value > largest) {
          largest = value;
          p = row;
          q = column;
        }
      }
    }
    if (largest <= 1e-15) break;
    final app = matrix[p][p], aqq = matrix[q][q], apq = matrix[p][q];
    final angle = 0.5 * math.atan2(2 * apq, aqq - app);
    final c = math.cos(angle), s = math.sin(angle);
    for (var k = 0; k < 4; k++) {
      if (k == p || k == q) continue;
      final mkp = matrix[k][p], mkq = matrix[k][q];
      matrix[k][p] = matrix[p][k] = c * mkp - s * mkq;
      matrix[k][q] = matrix[q][k] = s * mkp + c * mkq;
    }
    matrix[p][p] = c * c * app - 2 * s * c * apq + s * s * aqq;
    matrix[q][q] = s * s * app + 2 * s * c * apq + c * c * aqq;
    matrix[p][q] = matrix[q][p] = 0;
    for (var k = 0; k < 4; k++) {
      final vkp = vectors[k][p], vkq = vectors[k][q];
      vectors[k][p] = c * vkp - s * vkq;
      vectors[k][q] = s * vkp + c * vkq;
    }
  }
  var largestIndex = 0;
  for (var i = 1; i < 4; i++) {
    if (matrix[i][i] > matrix[largestIndex][largestIndex]) largestIndex = i;
  }
  var result = <double>[
    for (var row = 0; row < 4; row++) vectors[row][largestIndex],
  ];
  final norm = math.sqrt(_dot(result, result));
  if (!norm.isFinite || norm <= 1e-15) {
    throw StateError('invalid Horn eigenvector');
  }
  result = result.map((value) => value / norm).toList();
  final pivot = result.indexWhere((value) => value.abs() > 1e-12);
  if (pivot >= 0 && result[pivot] < 0) {
    result = result.map((value) => -value).toList();
  }
  return result;
}

List<double> _rotationFromQuaternion(List<double> quaternion) {
  if (quaternion.length != 4 || !_allFinite(quaternion)) {
    throw ArgumentError('quaternion must contain four finite values');
  }
  final norm = math.sqrt(_dot(quaternion, quaternion));
  if (!norm.isFinite || norm <= 1e-12) {
    throw ArgumentError('quaternion has zero norm');
  }
  final w = quaternion[0] / norm;
  final x = quaternion[1] / norm;
  final y = quaternion[2] / norm;
  final z = quaternion[3] / norm;
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

List<double> _rotate(List<double> rotation, List<double> point) => <double>[
  rotation[0] * point[0] + rotation[1] * point[1] + rotation[2] * point[2],
  rotation[3] * point[0] + rotation[4] * point[1] + rotation[5] * point[2],
  rotation[6] * point[0] + rotation[7] * point[1] + rotation[8] * point[2],
];

List<double> _residuals(List<_PointPair> pairs, _Sim3 model) => <double>[
  for (final pair in pairs)
    _distance(
      pair.target,
      (() {
        final rotated = _rotate(model.rotation, pair.source);
        return <double>[
          model.scale * rotated[0] + model.translation[0],
          model.scale * rotated[1] + model.translation[1],
          model.scale * rotated[2] + model.translation[2],
        ];
      })(),
    ),
];

double _robustThreshold(List<double> residuals) {
  final sorted = List<double>.from(residuals)..sort();
  final median = _quantileSorted(sorted, 0.5);
  final deviations = <double>[
    for (final value in residuals) (value - median).abs(),
  ]..sort();
  final mad = _quantileSorted(deviations, 0.5);
  return median + math.max(4.5 * 1.4826 * mad, 1e-5);
}

double _quantileSorted(List<double> sorted, double quantile) {
  if (sorted.isEmpty) throw ArgumentError('quantile input is empty');
  final position = (sorted.length - 1) * quantile;
  final lower = position.floor(), upper = position.ceil();
  if (lower == upper) return sorted[lower];
  final fraction = position - lower;
  return sorted[lower] * (1 - fraction) + sorted[upper] * fraction;
}

void _requireNonDegenerate(List<_PointPair> pairs) {
  if (!_isNonDegenerate(pairs)) {
    throw StateError('paired camera centres are collinear or have zero spread');
  }
}

bool _isNonDegenerate(List<_PointPair> pairs) =>
    _hasNonCollinearSpread(pairs.map((p) => p.source).toList()) &&
    _hasNonCollinearSpread(pairs.map((p) => p.target).toList());

bool _hasNonCollinearSpread(List<List<double>> points) {
  if (points.length < 3) return false;

  // Two farthest-point sweeps choose a stable, long baseline in O(n). A third
  // linear scan measures the maximum squared triangle area against it. Any
  // genuinely non-collinear set has a point off every selected non-zero line;
  // no all-triples enumeration is needed.
  const anchorIndex = 0;
  var firstIndex = anchorIndex;
  var farthestFromFirst = 0.0;
  for (var index = 1; index < points.length; index++) {
    final distance = _squaredDistance(points[anchorIndex], points[index]);
    if (distance > farthestFromFirst) {
      farthestFromFirst = distance;
      firstIndex = index;
    }
  }
  var secondIndex = firstIndex == 0 ? 1 : 0;
  var baselineSquared = _squaredDistance(
    points[firstIndex],
    points[secondIndex],
  );
  for (var index = 0; index < points.length; index++) {
    if (index == firstIndex) continue;
    final distance = _squaredDistance(points[firstIndex], points[index]);
    if (distance > baselineSquared) {
      baselineSquared = distance;
      secondIndex = index;
    }
  }
  if (baselineSquared <= 1e-14) return false;

  final baseline = <double>[
    points[secondIndex][0] - points[firstIndex][0],
    points[secondIndex][1] - points[firstIndex][1],
    points[secondIndex][2] - points[firstIndex][2],
  ];
  var maximumAreaSquared = 0.0;
  for (final point in points) {
    final offset = <double>[
      point[0] - points[firstIndex][0],
      point[1] - points[firstIndex][1],
      point[2] - points[firstIndex][2],
    ];
    final cross = <double>[
      baseline[1] * offset[2] - baseline[2] * offset[1],
      baseline[2] * offset[0] - baseline[0] * offset[2],
      baseline[0] * offset[1] - baseline[1] * offset[0],
    ];
    maximumAreaSquared = math.max(maximumAreaSquared, _dot(cross, cross));
  }
  return maximumAreaSquared > 1e-12 * baselineSquared * baselineSquared;
}

void _validatePoint(List<double> point, String label) {
  if (point.length != 3 || !_allFinite(point)) {
    throw ArgumentError('$label must contain three finite values');
  }
}

void _validateTransformedPoint(List<double> point, String label) {
  if (!_allFinite(point)) {
    throw StateError('$label contains a non-finite coordinate');
  }
}

bool _allFinite(List<double> values) => values.every((value) => value.isFinite);

double _dot(List<double> a, List<double> b) {
  var result = 0.0;
  for (var i = 0; i < a.length; i++) {
    result += a[i] * b[i];
  }
  return result;
}

double _distance(List<double> a, List<double> b) =>
    math.sqrt(_squaredDistance(a, b));

double _squaredDistance(List<double> a, List<double> b) {
  final x = a[0] - b[0], y = a[1] - b[1], z = a[2] - b[2];
  return x * x + y * y + z * z;
}
