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
      // VINS 的收尾过滤,feature_tracker.cpp inBorder() 逐字(BORDER_SIZE=1):
      //     return BORDER_SIZE <= img_x && img_x < COL - BORDER_SIZE && ...
      // 上游跟踪完调 reduceVector(status) 把出画点剔掉。现在采样是
      // REFLECT_101,飘出画面的点会继续"跟着"反射出来的幻影纹理 —— 必须
      // 在这里按上游剔除。
      final rx = point.x.round();
      final ry = point.y.round();
      if (rx < 1 || rx >= width - 1 || ry < 1 || ry >= height - 1) continue;
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
    final rx = tracked.x.round();
    final ry = tracked.y.round();
    final insideBorder =
        rx >= 1 && rx < width - 1 && ry >= 1 && ry < height - 1;
    if (displacement.isFinite && normalized.isFinite && insideBorder) {
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

/// 逐层 LK。层间语义照 OpenCV lkpyramid.cpp(2026-09-02 回源逐字核对):
/// 边界与退化失败**只在第 0 层(最细层)判死**;粗层失败只是跳过该层的
/// 精化,把现有估计传给下一层 ——
///
///     if( level == 0 ) { status[ptidx] = false; ... } continue;
///
/// 此前本端口在**任何**层失败都直接判死整个点。128×128 图的顶层只有
/// 32×32,窗口检查把离边 20px(全分辨率)内的角点全部误杀 —— 可跟踪面积
/// 只剩 (88/128)² ≈ 47%,与真实照片 1px 平移实测 60% 存活率、以及抹平边缘
/// 后回升到 83% 的对照相互印证。
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
      finestLevel: level == 0,
    );
    if (refined == null) {
      if (level == 0) return null;
      continue; // 粗层失败:估计原样传下去(OpenCV 的 continue 语义)
    }
    estimate = refined;
  }
  return estimate;
}

/// 单层 LK 精化。与 OpenCV lkpyramid.cpp 对齐的四处(均已回源逐字核对):
///
///   * 采样带 BORDER_REFLECT_101 —— OpenCV 的金字塔每层按 winSize 用
///     REFLECT_101 填充(buildOpticalFlowPyramid 默认
///     `pyrBorder = BORDER_REFLECT_101`,copyMakeBorder 按 winSize 双侧),
///     所以贴边窗口是合法读;在读取时做反射与预填充在 LK 读得到的范围内
///     等价。旧实现要求窗口完全在图内,是误杀主凶。
///   * 「界外」只指**完全**飞出填充区:
///     `iprevPt.x < -winSize.width || iprevPt.x >= derivI.cols || ...`
///   * **没有位移上限**:OpenCV 对 |nextPt - prevPt| 没有任何 cap。
///     旧实现的 `dx.abs() > radius` 判拒是自加的,已删。
///   * 终止:`delta.ddot(delta) <= criteria.epsilon`(ε=0.01,比的是
///     **平方范数**,即 |δ| ≤ 0.1 —— 旧实现按 |δ| ≤ 0.01 收敛,严了 10 倍,
///     30 步内常常收不完);外加振荡早停:
///     `|δ+δ_prev| < 0.01 → nextPts[ptidx] -= delta*0.5f; break;`
///
/// 失败(界外/退化)时:[finestLevel] 为真返回 null(= OpenCV 的
/// status=false),否则返回未精化的 [initial](= OpenCV 粗层的 continue)。
_Point? _trackOneLevel(
  _GrayLevel previous,
  _GrayLevel current,
  _Point source,
  _Point initial, {
  required bool finestLevel,
}) {
  const radius = 4;
  const window = 2 * radius + 1;
  const maximumIterations = 30;
  const epsilon = 0.01;
  const minimumEigenvalue = 1e-4;
  var x = initial.x;
  var y = initial.y;
  var previousDx = 0.0;
  var previousDy = 0.0;

  _Point? fail() => finestLevel ? null : initial;

  bool completelyOff(_GrayLevel level, double px, double py) =>
      px < -window ||
      px >= level.width + window ||
      py < -window ||
      py >= level.height + window;

  if (completelyOff(previous, source.x, source.y)) return fail();
  for (var iteration = 0; iteration < maximumIterations; iteration++) {
    if (completelyOff(current, x, y)) return fail();
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
      return fail();
    }
    final dx = (gyy * bx - gxy * by) / determinant;
    final dy = (-gxy * bx + gxx * by) / determinant;
    if (!dx.isFinite || !dy.isFinite) return fail();
    x += dx;
    y += dy;
    if (dx * dx + dy * dy <= epsilon) break;
    if (iteration > 0 &&
        (dx + previousDx).abs() < 0.01 &&
        (dy + previousDy).abs() < 0.01) {
      x -= dx * 0.5;
      y -= dy * 0.5;
      break;
    }
    previousDx = dx;
    previousDy = dy;
  }
  return _Point(x, y);
}

/// BORDER_REFLECT_101 折返(gfedcb|abcdefgh|gfedcba)—— OpenCV 金字塔填充
/// 的默认边界模式。读取时反射与预填充在 LK 能读到的范围内逐值等价。
int _reflect101(int coordinate, int length) {
  var value = coordinate;
  if (length == 1) return 0;
  while (value < 0 || value >= length) {
    if (value < 0) value = -value;
    if (value >= length) value = 2 * length - value - 2;
  }
  return value;
}

double _sample(_GrayLevel level, double x, double y) {
  final x0 = x.floor();
  final y0 = y.floor();
  final fx = x - x0;
  final fy = y - y0;
  final xa = _reflect101(x0, level.width);
  final xb = _reflect101(x0 + 1, level.width);
  final ya = _reflect101(y0, level.height);
  final yb = _reflect101(y0 + 1, level.height);
  final top =
      level.data[ya * level.width + xa] * (1 - fx) +
      level.data[ya * level.width + xb] * fx;
  final bottom =
      level.data[yb * level.width + xa] * (1 - fx) +
      level.data[yb * level.width + xb] * fx;
  return top * (1 - fy) + bottom * fy;
}
