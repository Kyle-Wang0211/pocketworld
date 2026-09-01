// Clean-room Dart port of the exact estimator shape used by VINS-Mono's
// FeatureTracker::rejectWithF(): OpenCV FM_RANSAC, seven-point minimal model,
// 0.99 confidence and symmetric epipolar-distance scoring.
//
// Upstream semantics:
//   VINS-Mono feature_tracker.cpp (pinned 90dabb5ec79946ae42fd2e1e91d4e69aabe1e25d)
//   OpenCV fundam.cpp / ptsetreg.cpp (BSD-3-Clause implementation)
//
// This file deliberately has no Flutter or platform dependency.

import 'dart:math' as math;

class VinsCorrespondence {
  const VinsCorrespondence({
    required this.firstX,
    required this.firstY,
    required this.secondX,
    required this.secondY,
  });

  final double firstX;
  final double firstY;
  final double secondX;
  final double secondY;
}

List<bool> vinsFundamentalRansacInlierMask(
  List<VinsCorrespondence> points, {
  double thresholdPixels = 1.0,
  double confidence = 0.99,
  int maximumIterations = 1000,
}) {
  if (points.length < 7 ||
      !thresholdPixels.isFinite ||
      thresholdPixels <= 0 ||
      !confidence.isFinite ||
      confidence <= 0 ||
      confidence >= 1 ||
      maximumIterations <= 0 ||
      points.any(
        (point) =>
            !point.firstX.isFinite ||
            !point.firstY.isFinite ||
            !point.secondX.isFinite ||
            !point.secondY.isFinite,
      )) {
    return List<bool>.filled(points.length, false, growable: false);
  }

  if (points.length == 7) {
    final models = _sevenPointFundamentalModels(points);
    return List<bool>.filled(points.length, models.isNotEmpty, growable: false);
  }
  // This is OpenCV findFundamentalMat's exact dispatch for FM_RANSAC: fewer
  // than 15 correspondences use its seven-point LMeDS registrator.
  if (points.length < 15) {
    return _leastMedianFundamentalMask(
      points,
      confidence: confidence,
      maximumIterations: maximumIterations,
    );
  }

  final random = _OpenCvRng();
  var iterationLimit = maximumIterations;
  var bestCount = 0;
  var bestMask = List<bool>.filled(points.length, false, growable: false);
  final thresholdSquared = thresholdPixels * thresholdPixels;

  for (var iteration = 0; iteration < iterationLimit; iteration++) {
    final sample = _sampleSeven(points, random);
    if (sample == null) {
      if (iteration == 0) {
        return List<bool>.filled(points.length, false, growable: false);
      }
      break;
    }
    final models = _sevenPointFundamentalModels(sample);
    for (final model in models) {
      final mask = <bool>[];
      var count = 0;
      for (final point in points) {
        final inlier =
            _symmetricEpipolarErrorSquared(point, model) <= thresholdSquared;
        mask.add(inlier);
        if (inlier) count++;
      }
      if (count > math.max(bestCount, 6)) {
        bestCount = count;
        bestMask = List<bool>.unmodifiable(mask);
        iterationLimit = _ransacIterationLimit(
          confidence: confidence,
          outlierRatio: (points.length - count) / points.length,
          modelPoints: 7,
          maximumIterations: iterationLimit,
        );
      }
    }
  }
  return bestMask;
}

List<bool> _leastMedianFundamentalMask(
  List<VinsCorrespondence> points, {
  required double confidence,
  required int maximumIterations,
}) {
  final random = _OpenCvRng();
  var iterations = _ransacIterationLimit(
    confidence: confidence,
    outlierRatio: 0.45,
    modelPoints: 7,
    maximumIterations: maximumIterations,
  );
  iterations = math.max(iterations, 3);
  List<double>? bestModel;
  var minimumMedian = double.infinity;
  for (var iteration = 0; iteration < iterations; iteration++) {
    final sample = _sampleSeven(points, random);
    if (sample == null) break;
    for (final model in _sevenPointFundamentalModels(sample)) {
      final errors = <double>[
        for (final point in points)
          _symmetricEpipolarErrorSquared(point, model),
      ]..sort();
      final median = errors[errors.length ~/ 2];
      if (median < minimumMedian) {
        minimumMedian = median;
        bestModel = model;
      }
    }
  }
  if (bestModel == null || !minimumMedian.isFinite) {
    return List<bool>.filled(points.length, false, growable: false);
  }
  final sigma = math.max(
    2.5 *
        1.4826 *
        (1 + 5 / (points.length - 7)) *
        math.sqrt(math.max(0, minimumMedian)),
    0.001,
  );
  final thresholdSquared = sigma * sigma;
  final mask = <bool>[
    for (final point in points)
      _symmetricEpipolarErrorSquared(point, bestModel) <= thresholdSquared,
  ];
  return mask.where((value) => value).length >= 7
      ? List<bool>.unmodifiable(mask)
      : List<bool>.filled(points.length, false, growable: false);
}

class _OpenCvRng {
  static const int _mask64 = 0xffffffffffffffff;
  static const int _mask32 = 0xffffffff;
  int _state = _mask64;

  int nextInt(int upperExclusive) {
    final low = _state & _mask32;
    final high = (_state >> 32) & _mask32;
    _state = (low * 4164903690 + high) & _mask64;
    return (_state & _mask32) % upperExclusive;
  }
}

List<VinsCorrespondence>? _sampleSeven(
  List<VinsCorrespondence> points,
  _OpenCvRng random,
) {
  for (var attempt = 0; attempt < 10000; attempt++) {
    final indices = <int>[];
    while (indices.length < 7) {
      final candidate = random.nextInt(points.length);
      if (!indices.contains(candidate)) indices.add(candidate);
    }
    final sample = <VinsCorrespondence>[
      for (final index in indices) points[index],
    ];
    if (!_hasCollinearPoints(sample, first: true) &&
        !_hasCollinearPoints(sample, first: false)) {
      return sample;
    }
  }
  return null;
}

bool _hasCollinearPoints(
  List<VinsCorrespondence> points, {
  required bool first,
}) {
  const floatEpsilon = 1.1920928955078125e-7;
  for (var i = 2; i < points.length; i++) {
    final ix = first ? points[i].firstX : points[i].secondX;
    final iy = first ? points[i].firstY : points[i].secondY;
    for (var j = 0; j < i; j++) {
      final jx = first ? points[j].firstX : points[j].secondX;
      final jy = first ? points[j].firstY : points[j].secondY;
      final dx1 = jx - ix;
      final dy1 = jy - iy;
      for (var k = 0; k < j; k++) {
        final kx = first ? points[k].firstX : points[k].secondX;
        final ky = first ? points[k].firstY : points[k].secondY;
        final dx2 = kx - ix;
        final dy2 = ky - iy;
        if ((dx2 * dy1 - dy2 * dx1).abs() <=
            floatEpsilon * (dx1.abs() + dy1.abs() + dx2.abs() + dy2.abs())) {
          return true;
        }
      }
    }
  }
  return false;
}

List<List<double>> _sevenPointFundamentalModels(
  List<VinsCorrespondence> points,
) {
  final normalized = _normalizeCorrespondences(points);
  if (normalized == null) return const <List<double>>[];
  final first = normalized.first;
  final second = normalized.second;
  final ata = List<List<double>>.generate(9, (_) => List<double>.filled(9, 0));
  for (var i = 0; i < 7; i++) {
    final x1 = first[i].$1;
    final y1 = first[i].$2;
    final x2 = second[i].$1;
    final y2 = second[i].$2;
    final row = <double>[x2 * x1, x2 * y1, x2, y2 * x1, y2 * y1, y2, x1, y1, 1];
    for (var r = 0; r < 9; r++) {
      for (var c = r; c < 9; c++) {
        ata[r][c] += row[r] * row[c];
        ata[c][r] = ata[r][c];
      }
    }
  }
  final eigen = _jacobiEigenSymmetric(ata);
  if (eigen == null) return const <List<double>>[];
  final order = List<int>.generate(9, (index) => index)
    ..sort((a, b) => eigen.values[a].compareTo(eigen.values[b]));
  final f2 = <double>[
    for (var row = 0; row < 9; row++) eigen.vectors[row][order[0]],
  ];
  final basis = <double>[
    for (var row = 0; row < 9; row++) eigen.vectors[row][order[1]] - f2[row],
  ];
  final polynomial = _determinantPolynomial(basis, f2);
  final roots = _realPolynomialRoots(polynomial);
  final models = <List<double>>[];
  for (final root in roots) {
    final normalizedModel = <double>[
      for (var i = 0; i < 9; i++) f2[i] + root * basis[i],
    ];
    var model = _multiply3x3(
      _transpose3x3(normalized.secondTransform),
      _multiply3x3(normalizedModel, normalized.firstTransform),
    );
    if (model[8].abs() > 1.1920928955078125e-7) {
      final scale = model[8];
      model = <double>[for (final value in model) value / scale];
    }
    if (model.every((value) => value.isFinite)) models.add(model);
  }
  return models;
}

class _NormalizedCorrespondences {
  const _NormalizedCorrespondences({
    required this.first,
    required this.second,
    required this.firstTransform,
    required this.secondTransform,
  });

  final List<(double, double)> first;
  final List<(double, double)> second;
  final List<double> firstTransform;
  final List<double> secondTransform;
}

_NormalizedCorrespondences? _normalizeCorrespondences(
  List<VinsCorrespondence> points,
) {
  var firstCenterX = 0.0;
  var firstCenterY = 0.0;
  var secondCenterX = 0.0;
  var secondCenterY = 0.0;
  for (final point in points) {
    firstCenterX += point.firstX;
    firstCenterY += point.firstY;
    secondCenterX += point.secondX;
    secondCenterY += point.secondY;
  }
  final count = points.length.toDouble();
  firstCenterX /= count;
  firstCenterY /= count;
  secondCenterX /= count;
  secondCenterY /= count;
  var firstMeanDistance = 0.0;
  var secondMeanDistance = 0.0;
  for (final point in points) {
    firstMeanDistance += math.sqrt(
      math.pow(point.firstX - firstCenterX, 2) +
          math.pow(point.firstY - firstCenterY, 2),
    );
    secondMeanDistance += math.sqrt(
      math.pow(point.secondX - secondCenterX, 2) +
          math.pow(point.secondY - secondCenterY, 2),
    );
  }
  firstMeanDistance /= count;
  secondMeanDistance /= count;
  if (firstMeanDistance < 1.1920928955078125e-7 ||
      secondMeanDistance < 1.1920928955078125e-7) {
    return null;
  }
  final firstScale = math.sqrt(2) / firstMeanDistance;
  final secondScale = math.sqrt(2) / secondMeanDistance;
  return _NormalizedCorrespondences(
    first: <(double, double)>[
      for (final point in points)
        (
          (point.firstX - firstCenterX) * firstScale,
          (point.firstY - firstCenterY) * firstScale,
        ),
    ],
    second: <(double, double)>[
      for (final point in points)
        (
          (point.secondX - secondCenterX) * secondScale,
          (point.secondY - secondCenterY) * secondScale,
        ),
    ],
    firstTransform: <double>[
      firstScale,
      0,
      -firstScale * firstCenterX,
      0,
      firstScale,
      -firstScale * firstCenterY,
      0,
      0,
      1,
    ],
    secondTransform: <double>[
      secondScale,
      0,
      -secondScale * secondCenterX,
      0,
      secondScale,
      -secondScale * secondCenterY,
      0,
      0,
      1,
    ],
  );
}

class _EigenResult {
  const _EigenResult(this.values, this.vectors);
  final List<double> values;
  final List<List<double>> vectors;
}

_EigenResult? _jacobiEigenSymmetric(List<List<double>> input) {
  final size = input.length;
  final matrix = <List<double>>[for (final row in input) List<double>.of(row)];
  final vectors = List<List<double>>.generate(
    size,
    (row) => List<double>.generate(size, (column) => row == column ? 1 : 0),
  );
  for (var iteration = 0; iteration < size * size * 64; iteration++) {
    var p = 0;
    var q = 1;
    var maximum = 0.0;
    for (var row = 0; row < size; row++) {
      for (var column = row + 1; column < size; column++) {
        final value = matrix[row][column].abs();
        if (value > maximum) {
          maximum = value;
          p = row;
          q = column;
        }
      }
    }
    if (maximum <= 1e-12) {
      return _EigenResult(<double>[
        for (var i = 0; i < size; i++) matrix[i][i],
      ], vectors);
    }
    final angle =
        0.5 * math.atan2(2 * matrix[p][q], matrix[q][q] - matrix[p][p]);
    final cosine = math.cos(angle);
    final sine = math.sin(angle);
    final app = matrix[p][p];
    final aqq = matrix[q][q];
    final apq = matrix[p][q];
    matrix[p][p] =
        cosine * cosine * app - 2 * sine * cosine * apq + sine * sine * aqq;
    matrix[q][q] =
        sine * sine * app + 2 * sine * cosine * apq + cosine * cosine * aqq;
    matrix[p][q] = 0;
    matrix[q][p] = 0;
    for (var index = 0; index < size; index++) {
      if (index == p || index == q) continue;
      final aip = matrix[index][p];
      final aiq = matrix[index][q];
      matrix[index][p] = cosine * aip - sine * aiq;
      matrix[p][index] = matrix[index][p];
      matrix[index][q] = sine * aip + cosine * aiq;
      matrix[q][index] = matrix[index][q];
    }
    for (var row = 0; row < size; row++) {
      final vip = vectors[row][p];
      final viq = vectors[row][q];
      vectors[row][p] = cosine * vip - sine * viq;
      vectors[row][q] = sine * vip + cosine * viq;
    }
  }
  return null;
}

List<double> _determinantPolynomial(List<double> direction, List<double> base) {
  List<double> linear(int index) => <double>[base[index], direction[index]];
  final positive = _polyAdd(
    _polyMul(
      linear(0),
      _polySub(_polyMul(linear(4), linear(8)), _polyMul(linear(5), linear(7))),
    ),
    _polyMul(
      linear(2),
      _polySub(_polyMul(linear(3), linear(7)), _polyMul(linear(4), linear(6))),
    ),
  );
  return _polySub(
    positive,
    _polyMul(
      linear(1),
      _polySub(_polyMul(linear(3), linear(8)), _polyMul(linear(5), linear(6))),
    ),
  );
}

List<double> _polyMul(List<double> a, List<double> b) {
  final result = List<double>.filled(a.length + b.length - 1, 0);
  for (var i = 0; i < a.length; i++) {
    for (var j = 0; j < b.length; j++) {
      result[i + j] += a[i] * b[j];
    }
  }
  return result;
}

List<double> _polyAdd(List<double> a, List<double> b) {
  final result = List<double>.filled(math.max(a.length, b.length), 0);
  for (var i = 0; i < result.length; i++) {
    result[i] = (i < a.length ? a[i] : 0) + (i < b.length ? b[i] : 0);
  }
  return result;
}

List<double> _polySub(List<double> a, List<double> b) {
  final result = List<double>.filled(math.max(a.length, b.length), 0);
  for (var i = 0; i < result.length; i++) {
    result[i] = (i < a.length ? a[i] : 0) - (i < b.length ? b[i] : 0);
  }
  return result;
}

List<double> _realPolynomialRoots(List<double> coefficients) {
  const epsilon = 1e-12;
  final c0 = coefficients.isNotEmpty ? coefficients[0] : 0.0;
  final c1 = coefficients.length > 1 ? coefficients[1] : 0.0;
  final c2 = coefficients.length > 2 ? coefficients[2] : 0.0;
  final c3 = coefficients.length > 3 ? coefficients[3] : 0.0;
  if (c3.abs() <= epsilon) {
    if (c2.abs() <= epsilon) {
      return c1.abs() <= epsilon ? const <double>[] : <double>[-c0 / c1];
    }
    final discriminant = c1 * c1 - 4 * c2 * c0;
    if (discriminant < -epsilon) return const <double>[];
    if (discriminant.abs() <= epsilon) return <double>[-c1 / (2 * c2)];
    final root = math.sqrt(math.max(0, discriminant));
    return <double>[(-c1 + root) / (2 * c2), (-c1 - root) / (2 * c2)];
  }
  final a = c2 / c3;
  final b = c1 / c3;
  final c = c0 / c3;
  final p = b - a * a / 3;
  final q = 2 * a * a * a / 27 - a * b / 3 + c;
  final discriminant = q * q / 4 + p * p * p / 27;
  double cubeRoot(double value) => value >= 0
      ? math.pow(value, 1 / 3).toDouble()
      : -math.pow(-value, 1 / 3).toDouble();
  if (discriminant > epsilon) {
    final sqrtDiscriminant = math.sqrt(discriminant);
    return <double>[
      cubeRoot(-q / 2 + sqrtDiscriminant) +
          cubeRoot(-q / 2 - sqrtDiscriminant) -
          a / 3,
    ];
  }
  if (p.abs() <= epsilon && q.abs() <= epsilon) return <double>[-a / 3];
  final radius = 2 * math.sqrt(math.max(0, -p / 3));
  final denominator = math.sqrt(math.max(epsilon, -(p * p * p) / 27));
  final angle = math.acos((-q / 2 / denominator).clamp(-1.0, 1.0));
  return <double>[
    for (var k = 0; k < 3; k++)
      radius * math.cos((angle + 2 * math.pi * k) / 3) - a / 3,
  ];
}

double _symmetricEpipolarErrorSquared(
  VinsCorrespondence point,
  List<double> f,
) {
  var a = f[0] * point.firstX + f[1] * point.firstY + f[2];
  var b = f[3] * point.firstX + f[4] * point.firstY + f[5];
  var c = f[6] * point.firstX + f[7] * point.firstY + f[8];
  final d2 = point.secondX * a + point.secondY * b + c;
  final norm2 = a * a + b * b;
  a = f[0] * point.secondX + f[3] * point.secondY + f[6];
  b = f[1] * point.secondX + f[4] * point.secondY + f[7];
  c = f[2] * point.secondX + f[5] * point.secondY + f[8];
  final d1 = point.firstX * a + point.firstY * b + c;
  final norm1 = a * a + b * b;
  if (norm1 <= 1e-20 || norm2 <= 1e-20) return double.infinity;
  return math.max(d1 * d1 / norm1, d2 * d2 / norm2);
}

List<double> _multiply3x3(List<double> a, List<double> b) => <double>[
  for (var row = 0; row < 3; row++)
    for (var column = 0; column < 3; column++)
      a[row * 3] * b[column] +
          a[row * 3 + 1] * b[3 + column] +
          a[row * 3 + 2] * b[6 + column],
];

List<double> _transpose3x3(List<double> matrix) => <double>[
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

int _ransacIterationLimit({
  required double confidence,
  required double outlierRatio,
  required int modelPoints,
  required int maximumIterations,
}) {
  final p = confidence.clamp(0.0, 1.0);
  final ep = outlierRatio.clamp(0.0, 1.0);
  final numerator = math.log(math.max(1 - p, double.minPositive));
  final denominator = math.log(1 - math.pow(1 - ep, modelPoints));
  if (!denominator.isFinite || denominator >= 0) return maximumIterations;
  return math.min(maximumIterations, (numerator / denominator).round());
}
