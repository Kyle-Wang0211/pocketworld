// Cross-platform visual novelty evidence for automatic capture.
//
// The platform bridge supplies only a small grayscale image. All corner
// selection, pyramidal Lucas-Kanade tracking and normalized motion policy live
// here so iOS and Android execute the same decision code.
//
// Algorithm contract:
//   * Shi-Tomasi corners use the OpenCV goodFeaturesToTrack defaults that
//     matter here: qualityLevel=.01 and minDistance=7.
//   * Tracks use coarse-to-fine Lucas-Kanade refinement.
//   * VINS-Mono's normalized parallax remains diagnostic estimator evidence.
//     It is not, by itself, authorization to press a consumer shutter.
//   * Tracks are propagated frame-to-frame, while displacement remains measured
//     against the last photo that actually entered the shutter queue.
//   * VINS-Mono's under-20 rule is exposed as diagnostic evidence only. That
//     rule manages its estimator window; track loss is not photo novelty.

import 'dart:math' as math;
import 'dart:typed_data';

const double kOfficialNormalizedTrackDisplacement = 10.0 / 460.0;
const int kOfficialMinimumCommonTracks = 20;

class FrameTrackEvidence {
  const FrameTrackEvidence({
    required this.seedTrackCount,
    required this.commonTrackCount,
    required this.commonTrackFraction,
    required this.medianPixelDisplacement,
    required this.medianNormalizedDisplacement,
    required this.meanNormalizedDisplacement,
    this.medianStepPixelDisplacement = double.nan,
  });

  final int seedTrackCount;
  final int commonTrackCount;
  final double commonTrackFraction;
  final double medianPixelDisplacement;
  final double medianNormalizedDisplacement;

  /// 上游 VINS-Mono 判决用的量。feature_manager.cpp,逐字:
  ///
  ///     parallax_sum += compensatedParallax2(it_per_id, frame_count);
  ///     parallax_num++;
  ///     ...
  ///     return parallax_sum / parallax_num >= MIN_PARALLAX;
  ///
  /// 是**算术均值**,不是中位数。而 compensatedParallax2 返回的就是
  /// `sqrt(du*du + dv*dv)`(归一化像平面坐标,已除深度)—— 与本文件的
  /// `sqrt((dx/fx)^2 + (dy/fy)^2)` 是同一个量。
  ///
  /// 2026-09-01 之前这里用的是中位数,那是自研:上游没有任何一家这么做,
  /// 而且代码里没写理由。中位数抗离群点(LK 配错会产生凭空的大位移),但
  /// 「可能更适合我们」不是复刻,是自研。已改回均值。
  /// [medianNormalizedDisplacement] 保留为证据,便于事后对照两者的分歧。
  final double meanNormalizedDisplacement;
  final double medianStepPixelDisplacement;

  bool get comparable =>
      commonTrackCount >= kOfficialMinimumCommonTracks &&
      meanNormalizedDisplacement.isFinite;

  bool get hasEnoughNovelty =>
      comparable &&
      meanNormalizedDisplacement >= kOfficialNormalizedTrackDisplacement;

  /// Mirrors VINS-Mono FeatureManager::addFeatureCheckParallax(): a healthy
  /// tracked reference dropping below 20 shared observations is a keyframe
  /// condition. Requiring a once-healthy seed keeps featureless images from
  /// being mislabeled as new views.
  bool get lostTrackedOverlap =>
      seedTrackCount >= kOfficialMinimumCommonTracks &&
      commonTrackCount < kOfficialMinimumCommonTracks;

  bool get isKeyframeCandidate => hasEnoughNovelty;
}

class _Point {
  const _Point(this.x, this.y);
  final double x;
  final double y;
}

class _CornerScore {
  const _CornerScore(this.point, this.score);
  final _Point point;
  final double score;
}

class _GrayLevel {
  const _GrayLevel(this.data, this.width, this.height);
  final Float64List data;
  final int width;
  final int height;
}

class _ContinuousTrack {
  const _ContinuousTrack({required this.anchor, required this.current});

  final _Point anchor;
  final _Point current;
}

/// Stateful VINS/XRSLAM-style frame-to-frame LK propagation.
///
/// [setReference] is called only after a real photo enters the queue. Each
/// [advance] tracks those same feature identities from the immediately
/// preceding preview sample, while reporting cumulative parallax from the
/// accepted-photo anchor. This prevents a large viewpoint change from forcing
/// one impossible LK jump back to an increasingly old photo.
class ContinuousFeatureTracks {
  _GrayLevel? _previous;
  List<_ContinuousTrack> _tracks = const <_ContinuousTrack>[];
  int _referenceSeedCount = 0;
  int _width = 0;
  int _height = 0;

  void clear() {
    _previous = null;
    _tracks = const <_ContinuousTrack>[];
    _referenceSeedCount = 0;
    _width = 0;
    _height = 0;
  }

  bool setReference({
    required Uint8List gray,
    required int width,
    required int height,
  }) {
    if (!_validGray(gray, width, height)) {
      clear();
      return false;
    }
    final level = _toLevel(gray, width, height);
    final seeds = _goodFeaturesToTrack(level);
    _previous = level;
    _tracks = <_ContinuousTrack>[
      for (final seed in seeds) _ContinuousTrack(anchor: seed, current: seed),
    ];
    _referenceSeedCount = seeds.length;
    _width = width;
    _height = height;
    return true;
  }

  FrameTrackEvidence? advance({
    required Uint8List gray,
    required int width,
    required int height,
    required double focalXPixels,
    required double focalYPixels,
  }) {
    final previous = _previous;
    if (previous == null ||
        width != _width ||
        height != _height ||
        !_validGray(gray, width, height) ||
        !focalXPixels.isFinite ||
        !focalYPixels.isFinite ||
        focalXPixels <= 0 ||
        focalYPixels <= 0) {
      return null;
    }

    final current = _toLevel(gray, width, height);
    final previousPyramid = _pyramid(previous, levels: 3);
    final currentPyramid = _pyramid(current, levels: 3);
    final survivors = <_ContinuousTrack>[];
    final displacements = <double>[];
    final normalizedDisplacements = <double>[];
    final stepDisplacements = <double>[];
    for (final track in _tracks) {
      final point = _trackPyramidal(
        previousPyramid,
        currentPyramid,
        track.current,
      );
      if (point == null) continue;
      final dx = point.x - track.anchor.x;
      final dy = point.y - track.anchor.y;
      final stepDx = point.x - track.current.x;
      final stepDy = point.y - track.current.y;
      final displacement = math.sqrt(dx * dx + dy * dy);
      final stepDisplacement = math.sqrt(stepDx * stepDx + stepDy * stepDy);
      final normalized = math.sqrt(
        (dx / focalXPixels) * (dx / focalXPixels) +
            (dy / focalYPixels) * (dy / focalYPixels),
      );
      if (!displacement.isFinite ||
          !stepDisplacement.isFinite ||
          !normalized.isFinite) {
        continue;
      }
      survivors.add(_ContinuousTrack(anchor: track.anchor, current: point));
      displacements.add(displacement);
      normalizedDisplacements.add(normalized);
      stepDisplacements.add(stepDisplacement);
    }

    _previous = current;
    _tracks = survivors;
    displacements.sort();
    normalizedDisplacements.sort();
    stepDisplacements.sort();
    final common = survivors.length;
    return FrameTrackEvidence(
      seedTrackCount: _referenceSeedCount,
      commonTrackCount: common,
      commonTrackFraction: _referenceSeedCount == 0
          ? 0
          : common / _referenceSeedCount,
      medianPixelDisplacement: _median(displacements),
      medianNormalizedDisplacement: _median(normalizedDisplacements),
      meanNormalizedDisplacement: _mean(normalizedDisplacements),
      medianStepPixelDisplacement: _median(stepDisplacements),
    );
  }

  static bool _validGray(Uint8List gray, int width, int height) =>
      width >= 32 && height >= 32 && gray.length == width * height;

  /// 上游 VINS-Mono 的判决量:`parallax_sum / parallax_num`(算术均值)。
  static double _mean(List<double> values) => values.isEmpty
      ? double.nan
      : values.reduce((a, b) => a + b) / values.length;

  static double _median(List<double> sorted) {
    if (sorted.isEmpty) return double.nan;
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[middle]
        : (sorted[middle - 1] + sorted[middle]) * 0.5;
  }
}

FrameTrackEvidence trackFrameNovelty({
  required Uint8List previousGray,
  required Uint8List currentGray,
  required int width,
  required int height,
  required double focalXPixels,
  required double focalYPixels,
}) {
  final expected = width * height;
  if (width < 32 ||
      height < 32 ||
      previousGray.length != expected ||
      currentGray.length != expected ||
      !focalXPixels.isFinite ||
      !focalYPixels.isFinite ||
      focalXPixels <= 0 ||
      focalYPixels <= 0) {
    return const FrameTrackEvidence(
      seedTrackCount: 0,
      commonTrackCount: 0,
      commonTrackFraction: 0,
      medianPixelDisplacement: double.nan,
      medianNormalizedDisplacement: double.nan,
      meanNormalizedDisplacement: double.nan,
    );
  }

  final previous = _toLevel(previousGray, width, height);
  final current = _toLevel(currentGray, width, height);
  final seeds = _goodFeaturesToTrack(previous);
  if (seeds.isEmpty) {
    return const FrameTrackEvidence(
      seedTrackCount: 0,
      commonTrackCount: 0,
      commonTrackFraction: 0,
      medianPixelDisplacement: double.nan,
      medianNormalizedDisplacement: double.nan,
      meanNormalizedDisplacement: double.nan,
    );
  }

  final previousPyramid = _pyramid(previous, levels: 3);
  final currentPyramid = _pyramid(current, levels: 3);
  final displacements = <double>[];
  final normalizedDisplacements = <double>[];
  for (final seed in seeds) {
    final tracked = _trackPyramidal(previousPyramid, currentPyramid, seed);
    if (tracked == null) continue;
    final dx = tracked.x - seed.x;
    final dy = tracked.y - seed.y;
    final displacement = math.sqrt(dx * dx + dy * dy);
    final normalized = math.sqrt(
      (dx / focalXPixels) * (dx / focalXPixels) +
          (dy / focalYPixels) * (dy / focalYPixels),
    );
    if (displacement.isFinite && normalized.isFinite) {
      displacements.add(displacement);
      normalizedDisplacements.add(normalized);
    }
  }
  displacements.sort();
  normalizedDisplacements.sort();
  final common = displacements.length;
  final median = common == 0
      ? double.nan
      : common.isOdd
      ? displacements[common ~/ 2]
      : (displacements[common ~/ 2 - 1] + displacements[common ~/ 2]) * 0.5;
  final normalizedMean = common == 0
      ? double.nan
      : normalizedDisplacements.reduce((a, b) => a + b) / common;
  final normalizedMedian = common == 0
      ? double.nan
      : common.isOdd
      ? normalizedDisplacements[common ~/ 2]
      : (normalizedDisplacements[common ~/ 2 - 1] +
                normalizedDisplacements[common ~/ 2]) *
            0.5;
  return FrameTrackEvidence(
    seedTrackCount: seeds.length,
    commonTrackCount: common,
    commonTrackFraction: common / seeds.length,
    medianPixelDisplacement: median,
    medianNormalizedDisplacement: normalizedMedian,
    meanNormalizedDisplacement: normalizedMean,
    medianStepPixelDisplacement: median,
  );
}

_GrayLevel _toLevel(Uint8List bytes, int width, int height) {
  final data = Float64List(bytes.length);
  for (var i = 0; i < bytes.length; i++) {
    data[i] = bytes[i].toDouble();
  }
  return _GrayLevel(data, width, height);
}

List<_GrayLevel> _pyramid(_GrayLevel base, {required int levels}) {
  final result = <_GrayLevel>[base];
  while (result.length < levels) {
    final source = result.last;
    if (source.width < 32 || source.height < 32) break;
    final width = source.width ~/ 2;
    final height = source.height ~/ 2;
    final data = Float64List(width * height);
    for (var y = 0; y < height; y++) {
      final sy = y * 2;
      for (var x = 0; x < width; x++) {
        final sx = x * 2;
        final i0 = sy * source.width + sx;
        data[y * width + x] =
            (source.data[i0] +
                source.data[i0 + 1] +
                source.data[i0 + source.width] +
                source.data[i0 + source.width + 1]) *
            0.25;
      }
    }
    result.add(_GrayLevel(data, width, height));
  }
  return result;
}

List<_Point> _goodFeaturesToTrack(_GrayLevel image) {
  const blockRadius = 2;
  const border = blockRadius + 2;
  const qualityLevel = 0.01;
  const minimumDistance = 7.0;
  const maximumCorners = 160;
  final candidates = <_CornerScore>[];
  var maximumScore = 0.0;

  for (var y = border; y < image.height - border; y += 2) {
    for (var x = border; x < image.width - border; x += 2) {
      var a = 0.0;
      var b = 0.0;
      var c = 0.0;
      for (var wy = -blockRadius; wy <= blockRadius; wy++) {
        for (var wx = -blockRadius; wx <= blockRadius; wx++) {
          final px = x + wx;
          final py = y + wy;
          final gx =
              (image.data[py * image.width + px + 1] -
                  image.data[py * image.width + px - 1]) *
              0.5;
          final gy =
              (image.data[(py + 1) * image.width + px] -
                  image.data[(py - 1) * image.width + px]) *
              0.5;
          a += gx * gx;
          b += gx * gy;
          c += gy * gy;
        }
      }
      final trace = a + c;
      final discriminant = math.sqrt(
        math.max(0, (a - c) * (a - c) + 4 * b * b),
      );
      final score = (trace - discriminant) * 0.5;
      if (score > 0) {
        candidates.add(_CornerScore(_Point(x.toDouble(), y.toDouble()), score));
        if (score > maximumScore) maximumScore = score;
      }
    }
  }
  if (maximumScore <= 0) return const <_Point>[];

  final threshold = maximumScore * qualityLevel;
  candidates.removeWhere((candidate) => candidate.score < threshold);
  candidates.sort((a, b) => b.score.compareTo(a.score));
  final selected = <_Point>[];
  final minimumDistanceSquared = minimumDistance * minimumDistance;
  for (final candidate in candidates) {
    var farEnough = true;
    for (final point in selected) {
      final dx = point.x - candidate.point.x;
      final dy = point.y - candidate.point.y;
      if (dx * dx + dy * dy < minimumDistanceSquared) {
        farEnough = false;
        break;
      }
    }
    if (!farEnough) continue;
    selected.add(candidate.point);
    if (selected.length == maximumCorners) break;
  }
  return selected;
}

_Point? _trackPyramidal(
  List<_GrayLevel> previous,
  List<_GrayLevel> current,
  _Point seed,
) {
  final top = math.min(previous.length, current.length) - 1;
  var estimate = _Point(seed.x / (1 << top), seed.y / (1 << top));
  for (var level = top; level >= 0; level--) {
    final scale = (1 << level).toDouble();
    final sourcePoint = _Point(seed.x / scale, seed.y / scale);
    if (level != top) estimate = _Point(estimate.x * 2, estimate.y * 2);
    final refined = _trackOneLevel(
      previous[level],
      current[level],
      sourcePoint,
      estimate,
    );
    if (refined == null) return null;
    estimate = refined;
  }
  return estimate;
}

_Point? _trackOneLevel(
  _GrayLevel previous,
  _GrayLevel current,
  _Point source,
  _Point initial,
) {
  const radius = 4;
  const maximumIterations = 30;
  const epsilonSquared = 0.01 * 0.01;
  const minimumEigenvalue = 1e-4;
  var x = initial.x;
  var y = initial.y;

  if (!_windowInside(previous, source.x, source.y, radius + 1)) return null;
  for (var iteration = 0; iteration < maximumIterations; iteration++) {
    if (!_windowInside(current, x, y, radius + 1)) return null;
    var gxx = 0.0;
    var gxy = 0.0;
    var gyy = 0.0;
    var bx = 0.0;
    var by = 0.0;
    var count = 0;
    for (var wy = -radius; wy <= radius; wy++) {
      for (var wx = -radius; wx <= radius; wx++) {
        final sx = source.x + wx;
        final sy = source.y + wy;
        final sourceValue = _sample(previous, sx, sy);
        final gx =
            (_sample(previous, sx + 1, sy) - _sample(previous, sx - 1, sy)) *
            0.5;
        final gy =
            (_sample(previous, sx, sy + 1) - _sample(previous, sx, sy - 1)) *
            0.5;
        final residual = sourceValue - _sample(current, x + wx, y + wy);
        gxx += gx * gx;
        gxy += gx * gy;
        gyy += gy * gy;
        bx += gx * residual;
        by += gy * residual;
        count++;
      }
    }
    final determinant = gxx * gyy - gxy * gxy;
    final trace = gxx + gyy;
    final minimumEigen =
        (trace -
            math.sqrt(math.max(0, (gxx - gyy) * (gxx - gyy) + 4 * gxy * gxy))) *
        0.5;
    if (determinant.abs() < 1e-9 || minimumEigen / count < minimumEigenvalue) {
      return null;
    }
    final dx = (gyy * bx - gxy * by) / determinant;
    final dy = (-gxy * bx + gxx * by) / determinant;
    if (!dx.isFinite ||
        !dy.isFinite ||
        dx.abs() > radius ||
        dy.abs() > radius) {
      return null;
    }
    x += dx;
    y += dy;
    if (dx * dx + dy * dy <= epsilonSquared) break;
  }
  return _Point(x, y);
}

bool _windowInside(_GrayLevel level, double x, double y, int radius) =>
    x - radius >= 0 &&
    y - radius >= 0 &&
    x + radius < level.width - 1 &&
    y + radius < level.height - 1;

double _sample(_GrayLevel level, double x, double y) {
  final x0 = x.floor();
  final y0 = y.floor();
  final x1 = x0 + 1;
  final y1 = y0 + 1;
  final fx = x - x0;
  final fy = y - y0;
  final top =
      level.data[y0 * level.width + x0] * (1 - fx) +
      level.data[y0 * level.width + x1] * fx;
  final bottom =
      level.data[y1 * level.width + x0] * (1 - fx) +
      level.data[y1 * level.width + x1] * fx;
  return top * (1 - fy) + bottom * fy;
}
