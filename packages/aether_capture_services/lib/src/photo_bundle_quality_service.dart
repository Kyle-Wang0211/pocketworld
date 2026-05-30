import 'dart:math' as math;
import 'dart:typed_data';

final class PhotoBundleStillQualityPolicy {
  const PhotoBundleStillQualityPolicy({
    this.minLaplacianVariance = 200.0,
    this.minMeanLuma = 60.0,
    this.maxMeanLuma = 200.0,
    this.maxUnderexposedRatio = 0.35,
    this.maxOverexposedRatio = 0.20,
  });

  final double minLaplacianVariance;
  final double minMeanLuma;
  final double maxMeanLuma;
  final double maxUnderexposedRatio;
  final double maxOverexposedRatio;

  Map<String, Object?> toJson() => {
        'minLaplacianVariance': minLaplacianVariance,
        'minMeanLuma': minMeanLuma,
        'maxMeanLuma': maxMeanLuma,
        'maxUnderexposedRatio': maxUnderexposedRatio,
        'maxOverexposedRatio': maxOverexposedRatio,
      };
}

final class PhotoBundleStillQuality {
  const PhotoBundleStillQuality({
    required this.accepted,
    required this.score,
    required this.laplacianVariance,
    required this.meanLuma,
    required this.underexposedRatio,
    required this.overexposedRatio,
    required this.textureCellRatio,
    required this.rejectReasons,
    this.tenengradMean = 0,
    this.sobelMean = 0,
    this.localContrast = 0,
    this.saturationRatio = 0,
    this.centerRoiLaplacianVariance = 0,
    this.centerRoiTenengrad = 0,
    this.centerRoiContrast = 0,
    this.multiscaleSharpness = 0,
    this.viewGraphWeight = 0,
    this.kWindowWeight = 0,
    this.textureBestViewWeight = 0,
    this.qualityPlaneWidth = 0,
    this.qualityPlaneHeight = 0,
  });

  final bool accepted;
  final double score;
  final double laplacianVariance;
  final double meanLuma;
  final double underexposedRatio;
  final double overexposedRatio;
  final double textureCellRatio;
  final List<String> rejectReasons;
  final double tenengradMean;
  final double sobelMean;
  final double localContrast;
  final double saturationRatio;
  final double centerRoiLaplacianVariance;
  final double centerRoiTenengrad;
  final double centerRoiContrast;
  final double multiscaleSharpness;
  final double viewGraphWeight;
  final double kWindowWeight;
  final double textureBestViewWeight;
  final int qualityPlaneWidth;
  final int qualityPlaneHeight;

  Map<String, Object?> toJson() => {
        'accepted': accepted,
        'score': score,
        'laplacianVariance': laplacianVariance,
        'meanLuma': meanLuma,
        'underexposedRatio': underexposedRatio,
        'overexposedRatio': overexposedRatio,
        'textureCellRatio': textureCellRatio,
        'tenengradMean': tenengradMean,
        'sobelMean': sobelMean,
        'localContrast': localContrast,
        'saturationRatio': saturationRatio,
        'centerRoiLaplacianVariance': centerRoiLaplacianVariance,
        'centerRoiTenengrad': centerRoiTenengrad,
        'centerRoiContrast': centerRoiContrast,
        'multiscaleSharpness': multiscaleSharpness,
        'viewGraphWeight': viewGraphWeight,
        'kWindowWeight': kWindowWeight,
        'textureBestViewWeight': textureBestViewWeight,
        'qualityPlaneWidth': qualityPlaneWidth,
        'qualityPlaneHeight': qualityPlaneHeight,
        'downstreamWeights': {
          'viewGraph': viewGraphWeight,
          'kWindow': kWindowWeight,
          'textureBestView': textureBestViewWeight,
        },
        'rejectReasons': rejectReasons,
      };
}

final class PhotoBundleQualityService {
  const PhotoBundleQualityService();

  PhotoBundleStillQuality evaluateLumaPlane({
    required Uint8List luma,
    required int width,
    required int height,
    int? rowStride,
    PhotoBundleStillQualityPolicy policy =
        const PhotoBundleStillQualityPolicy(),
  }) {
    final stride = rowStride ?? width;
    if (width <= 8 ||
        height <= 8 ||
        stride < width ||
        luma.length < stride * height) {
      return const PhotoBundleStillQuality(
        accepted: false,
        score: 0,
        laplacianVariance: 0,
        meanLuma: 0,
        underexposedRatio: 1,
        overexposedRatio: 1,
        textureCellRatio: 0,
        rejectReasons: ['empty_luma_plane'],
      );
    }

    const sampleStep = 1;
    const cellCols = 12;
    const cellRows = 8;
    final activeTextureCells = List<bool>.filled(cellCols * cellRows, false);
    final localCells = List<_CellStats>.generate(
      16 * 12,
      (_) => _CellStats(),
    );
    final centerRoi = _RoiStats();
    var sum = 0.0;
    var underCount = 0;
    var overCount = 0;
    var saturatedCount = 0;
    var lapSum = 0.0;
    var lapSumSq = 0.0;
    var tenengradSum = 0.0;
    var sobelSum = 0.0;
    var sampleCount = 0;

    for (var y = sampleStep; y < height - sampleStep; y += sampleStep) {
      for (var x = sampleStep; x < width - sampleStep; x += sampleStep) {
        final lumaValue = luma[y * stride + x].toDouble();
        final up = luma[(y - 1) * stride + x].toDouble();
        final down = luma[(y + 1) * stride + x].toDouble();
        final left = luma[y * stride + (x - 1)].toDouble();
        final right = luma[y * stride + (x + 1)].toDouble();
        final upLeft = luma[(y - 1) * stride + (x - 1)].toDouble();
        final upRight = luma[(y - 1) * stride + (x + 1)].toDouble();
        final downLeft = luma[(y + 1) * stride + (x - 1)].toDouble();
        final downRight = luma[(y + 1) * stride + (x + 1)].toDouble();
        final lap = -4 * lumaValue + up + down + left + right;
        final grad = (right - left).abs() + (down - up).abs();
        final sobelX =
            -upLeft + upRight - 2 * left + 2 * right - downLeft + downRight;
        final sobelY =
            -upLeft - 2 * up - upRight + downLeft + 2 * down + downRight;
        final tenengrad = sobelX * sobelX + sobelY * sobelY;

        sum += lumaValue;
        lapSum += lap;
        lapSumSq += lap * lap;
        tenengradSum += tenengrad;
        sobelSum += math.sqrt(tenengrad);
        if (lumaValue <= 16) underCount += 1;
        if (lumaValue >= 245) overCount += 1;
        if (lumaValue <= 4 || lumaValue >= 251) saturatedCount += 1;
        if (grad >= 32) {
          final cx = (x * cellCols ~/ width).clamp(0, cellCols - 1).toInt();
          final cy = (y * cellRows ~/ height).clamp(0, cellRows - 1).toInt();
          activeTextureCells[cy * cellCols + cx] = true;
        }
        final lcX = (x * 16 ~/ width).clamp(0, 15).toInt();
        final lcY = (y * 12 ~/ height).clamp(0, 11).toInt();
        localCells[lcY * 16 + lcX].add(lumaValue);
        if (_insideCenterRoi(x, y, width, height)) {
          centerRoi.add(lumaValue, lap, tenengrad);
        }
        sampleCount += 1;
      }
    }

    if (sampleCount == 0) {
      return const PhotoBundleStillQuality(
        accepted: false,
        score: 0,
        laplacianVariance: 0,
        meanLuma: 0,
        underexposedRatio: 1,
        overexposedRatio: 1,
        textureCellRatio: 0,
        rejectReasons: ['no_quality_samples'],
      );
    }

    final count = sampleCount.toDouble();
    final meanLuma = sum / count;
    final lapMean = lapSum / count;
    final laplacianVariance =
        math.max(0.0, lapSumSq / count - lapMean * lapMean);
    final tenengradMean = tenengradSum / count;
    final sobelMean = sobelSum / count;
    final underRatio = underCount / count;
    final overRatio = overCount / count;
    final saturationRatio = saturatedCount / count;
    final textureCellRatio = activeTextureCells.where((value) => value).length /
        activeTextureCells.length;
    final localContrast = _meanNonZeroStdDev(localCells);
    final centerMetrics = centerRoi.finish();

    final rejectReasons = <String>[];
    if (laplacianVariance < policy.minLaplacianVariance) {
      rejectReasons.add('blur_laplacian');
    }
    if (meanLuma < policy.minMeanLuma) rejectReasons.add('mean_luma_dark');
    if (meanLuma > policy.maxMeanLuma) rejectReasons.add('mean_luma_bright');
    if (underRatio > policy.maxUnderexposedRatio) {
      rejectReasons.add('underexposed_ratio');
    }
    if (overRatio > policy.maxOverexposedRatio) {
      rejectReasons.add('overexposed_ratio');
    }

    final blurScore = _clamp01(
      (laplacianVariance - policy.minLaplacianVariance) /
          math.max(1.0, 900.0 - policy.minLaplacianVariance),
    );
    final midLumaDistance = (meanLuma - 128.0).abs() / 128.0;
    final exposureScore = _clamp01(
      1 - math.max(midLumaDistance, math.max(underRatio * 1.5, overRatio * 2)),
    );
    final textureScore = _clamp01(textureCellRatio / 0.35);
    final centerSharpScore = _clamp01(
      (centerMetrics.laplacianVariance - policy.minLaplacianVariance) /
          math.max(1.0, 900.0 - policy.minLaplacianVariance),
    );
    final contrastScore = _clamp01(localContrast / 42.0);
    final saturationScore = _clamp01(1 - saturationRatio / 0.16);
    final multiscaleSharpness = 0.50 * laplacianVariance +
        0.35 * centerMetrics.laplacianVariance +
        0.15 * centerSharpScore * 900.0;
    final score = _clamp01(
      0.38 * blurScore +
          0.26 * centerSharpScore +
          0.20 * exposureScore +
          0.10 * textureScore +
          0.06 * saturationScore,
    );
    final viewGraphWeight = _clamp01(
      0.42 * score +
          0.24 * textureScore +
          0.20 * centerSharpScore +
          0.14 * contrastScore,
    );
    final kWindowWeight = _clamp01(
      0.52 * score + 0.28 * centerSharpScore + 0.20 * textureScore,
    );
    final textureBestViewWeight = _clamp01(
      0.30 * centerSharpScore +
          0.24 * exposureScore +
          0.20 * contrastScore +
          0.16 * textureScore +
          0.10 * saturationScore,
    );

    return PhotoBundleStillQuality(
      accepted: rejectReasons.isEmpty,
      score: score,
      laplacianVariance: laplacianVariance,
      meanLuma: meanLuma,
      underexposedRatio: underRatio,
      overexposedRatio: overRatio,
      textureCellRatio: textureCellRatio,
      rejectReasons: List.unmodifiable(rejectReasons),
      tenengradMean: tenengradMean,
      sobelMean: sobelMean,
      localContrast: localContrast,
      saturationRatio: saturationRatio,
      centerRoiLaplacianVariance: centerMetrics.laplacianVariance,
      centerRoiTenengrad: centerMetrics.tenengradMean,
      centerRoiContrast: centerMetrics.stdDev,
      multiscaleSharpness: multiscaleSharpness,
      viewGraphWeight: viewGraphWeight,
      kWindowWeight: kWindowWeight,
      textureBestViewWeight: textureBestViewWeight,
      qualityPlaneWidth: width,
      qualityPlaneHeight: height,
    );
  }

  static bool _insideCenterRoi(int x, int y, int width, int height) {
    return x >= width * 0.25 &&
        x <= width * 0.75 &&
        y >= height * 0.25 &&
        y <= height * 0.75;
  }

  static double _meanNonZeroStdDev(List<_CellStats> cells) {
    var sum = 0.0;
    var count = 0;
    for (final cell in cells) {
      final std = cell.stdDev;
      if (std <= 0) continue;
      sum += std;
      count += 1;
    }
    return count == 0 ? 0.0 : sum / count;
  }

  static double _clamp01(double value) => value.clamp(0.0, 1.0).toDouble();
}

final class _CellStats {
  var count = 0;
  var sum = 0.0;
  var sumSq = 0.0;

  void add(double value) {
    count += 1;
    sum += value;
    sumSq += value * value;
  }

  double get stdDev {
    if (count <= 1) return 0.0;
    final mean = sum / count;
    final variance = math.max(0.0, sumSq / count - mean * mean);
    return math.sqrt(variance);
  }
}

final class _RoiStats {
  var count = 0;
  var sum = 0.0;
  var sumSq = 0.0;
  var lapSum = 0.0;
  var lapSumSq = 0.0;
  var tenengradSum = 0.0;

  void add(double value, double laplacian, double tenengrad) {
    count += 1;
    sum += value;
    sumSq += value * value;
    lapSum += laplacian;
    lapSumSq += laplacian * laplacian;
    tenengradSum += tenengrad;
  }

  _RoiMetrics finish() {
    if (count == 0) {
      return const _RoiMetrics(
        laplacianVariance: 0,
        tenengradMean: 0,
        stdDev: 0,
      );
    }
    final mean = sum / count;
    final lapMean = lapSum / count;
    return _RoiMetrics(
      laplacianVariance: math.max(0.0, lapSumSq / count - lapMean * lapMean),
      tenengradMean: tenengradSum / count,
      stdDev: math.sqrt(math.max(0.0, sumSq / count - mean * mean)),
    );
  }
}

final class _RoiMetrics {
  const _RoiMetrics({
    required this.laplacianVariance,
    required this.tenengradMean,
    required this.stdDev,
  });

  final double laplacianVariance;
  final double tenengradMean;
  final double stdDev;
}
