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
//   * VINS-Mono's normalized parallax and under-20 rule are reproduced with
//     distinct names. They may keep an already-spatially-qualified real-time
//     candidate alive, but never replace the product's geometry gate.
//   * Tracks are propagated frame-to-frame, while displacement remains measured
//     against the last photo that actually entered the shutter queue.
//   * VINS-Mono returns true when fewer than 20 tracks survive. Treating that
//     case as a duplicate reverses the upstream keyframe decision.

import 'dart:math' as math;
import 'dart:typed_data';

import 'vins_fundamental_ransac.dart';

const double kOfficialNormalizedTrackDisplacement = 10.0 / 460.0;
const int kOfficialMinimumCommonTracks = 20;

/// A photographic constant we ADOPTED, not an algorithm we replicate.
///
/// Source of the number: AliceVision's keyframe selector defaults
/// `pxDisplacement` to 10.0 (`software/utils/main_keyframeSelection.cpp`) and
/// turns it into an absolute bar with
/// `pxDisplacement * std::min(_frameWidth, _frameHeight) / 100.0`
/// (`aliceVision/keyframe/KeyframeSelector.cpp`), i.e. ten percent of the
/// image's short edge. That much, and only that much, is borrowed.
///
/// We do NOT implement AliceVision's Smart Selection, and claiming to would be
/// a maintenance debt we never intend to pay: it is an OFFLINE selector over an
/// already-recorded video. It splits the sequence by ACCUMULATED optical flow,
/// then looks BACK inside each subsequence to pick the sharpest, most central
/// frame, and if the subsequence count misses [minOutFrames] it RE-RUNS with a
/// different step. None of that is available to a causal shutter, and a frame
/// it declines to select still sits on disk, so its bar carries no data loss.
/// Ours is one online, irreversible decision per photo.
///
/// Do not "sync this with upstream". The only upstream obligation here is that
/// the number 10 traces to the two files named above.
const double kOfficialCaptureMotionStepFraction = 0.10;

/// Bar for [FrameTrackEvidence.isCaptureNoveltyVerified], in the SAME
/// normalized (per-axis focal) units as `medianNormalizedDisplacement`.
///
/// Why not a raw pixel count: the tracker measures on a square grid produced by
/// squashing a 4:3 frame, so grid pixels are anisotropic — identical real motion
/// reads 4/3 larger vertically than horizontally. The previous bar
/// (`gridSide * 0.10`) therefore demanded 10.0% of the short edge for vertical
/// motion but 13.3% for horizontal. Measured on device 2026-08-30: 8 of 22
/// discarded photos were horizontal motion penalised by exactly that skew.
///
/// Normalized displacement already divides each axis by its own focal, so it is
/// isotropic AND independent of the downsample. Converting the bar into that
/// space is exact and needs no new input, because the original dimensions
/// cancel: `focalX_grid = f * gridWidth / widthOriginal`, hence
/// `gridWidth / focalX_grid == widthOriginal / f`. Taking the min over both
/// axes therefore reproduces `0.10 * min(widthOriginal, heightOriginal) / f`
/// without assuming square pixels or which edge is the short one.
double kOfficialCaptureNoveltyThreshold({
  required int gridWidth,
  required int gridHeight,
  required double focalXPixels,
  required double focalYPixels,
}) {
  if (!focalXPixels.isFinite ||
      !focalYPixels.isFinite ||
      focalXPixels <= 0 ||
      focalYPixels <= 0 ||
      gridWidth <= 0 ||
      gridHeight <= 0) {
    return double.nan;
  }
  return kOfficialCaptureMotionStepFraction *
      math.min(gridWidth / focalXPixels, gridHeight / focalYPixels);
}

class FrameTrackEvidence {
  const FrameTrackEvidence({
    required this.seedTrackCount,
    required this.commonTrackCount,
    required this.commonTrackFraction,
    required this.medianPixelDisplacement,
    required this.medianNormalizedDisplacement,
    this.medianStepPixelDisplacement = double.nan,
    required this.captureNoveltyThresholdNormalized,
    this.vinsTrackedCount = -1,
    this.vinsActiveTrackCount = -1,
    this.vinsReplenishedTrackCount = 0,
    this.vinsLongestTrackAge = 0,
    this.vinsMeanStepNormalizedParallax = double.nan,
    this.vinsGeometricInputCount = 0,
    this.vinsGeometricInlierCount = 0,
    this.vinsClaheApplied = false,
    this.vinsOccupiedGridFraction = double.nan,
  });

  final int seedTrackCount;
  final int commonTrackCount;
  final double commonTrackFraction;
  final double medianPixelDisplacement;
  final double medianNormalizedDisplacement;
  final double medianStepPixelDisplacement;
  /// Bar this evidence must clear to count as a new viewpoint, already in
  /// normalized units. Computed by kOfficialCaptureNoveltyThreshold at the one
  /// place that holds the focals; see that function for why it is not a pixel
  /// count. NaN when the focals were unusable, which fails closed.
  final double captureNoveltyThresholdNormalized;

  /// VINS-Mono front-end receipt after LK, border rejection and its
  /// long-track-first MIN_DIST mask, before newly detected points are added.
  /// A negative value means an older caller did not provide this receipt.
  final int vinsTrackedCount;

  /// Track population after goodFeaturesToTrack replenishment.
  final int vinsActiveTrackCount;
  final int vinsReplenishedTrackCount;
  final int vinsLongestTrackAge;

  /// VINS FeatureManager uses the arithmetic mean (not the median) of
  /// normalized parallax shared by the two relevant frames.
  final double vinsMeanStepNormalizedParallax;
  final int vinsGeometricInputCount;
  final int vinsGeometricInlierCount;
  final bool vinsClaheApplied;
  final double vinsOccupiedGridFraction;

  double get vinsGeometricInlierFraction => vinsGeometricInputCount == 0
      ? double.nan
      : vinsGeometricInlierCount / vinsGeometricInputCount;

  bool get comparable =>
      commonTrackCount >= kOfficialMinimumCommonTracks &&
      medianNormalizedDisplacement.isFinite;

  bool get hasEnoughNovelty =>
      comparable &&
      medianNormalizedDisplacement >= kOfficialNormalizedTrackDisplacement;

  /// Mirrors VINS-Mono `FeatureManager::addFeatureCheckParallax()`, whose first
  /// guard is `if (frame_count < 2 || last_track_num < 20) return true;` — a
  /// healthy tracked reference dropping below 20 shared observations is a
  /// keyframe condition. The literal 20 is upstream's.
  ///
  /// The `seedTrackCount >= 20` half is OURS and must stay. Upstream does not
  /// need it because its reference is a sliding window that always moves on;
  /// ours is a single sticky baseline that advances only on an accepted photo.
  /// Without the guard, one featureless photo becomes the permanent reference,
  /// every later photo scores `common < 20` against it, and the gate never
  /// recovers — observed on device 2026-08-27 as 28 consecutive rejections that
  /// ran to the end of the session.
  ///
  /// Two structural divergences that cannot be closed without a sliding window,
  /// recorded so nobody reads this as a faithful port: upstream's
  /// `last_track_num` counts the current image against EVERY track in the
  /// window, not against one reference photo; and its parallax is measured
  /// between frames `count-2` and `count-1`, not against the newest frame.
  bool get lostTrackedOverlap =>
      seedTrackCount >= kOfficialMinimumCommonTracks &&
      commonTrackCount < kOfficialMinimumCommonTracks;

  bool get isVinsEstimatorKeyframeCandidate {
    final tracked = vinsTrackedCount >= 0 ? vinsTrackedCount : commonTrackCount;
    final meanParallax = vinsMeanStepNormalizedParallax.isFinite
        ? vinsMeanStepNormalizedParallax
        : medianNormalizedDisplacement;
    return (seedTrackCount >= kOfficialMinimumCommonTracks &&
            tracked < kOfficialMinimumCommonTracks) ||
        (tracked >= kOfficialMinimumCommonTracks &&
            meanParallax.isFinite &&
            meanParallax >= kOfficialNormalizedTrackDisplacement);
  }

  /// Photographic novelty relative to the last accepted actual photo. The
  /// VINS estimator threshold is intentionally not used as this shutter scale.
  bool get isCaptureNoveltyVerified =>
      comparable &&
      captureNoveltyThresholdNormalized.isFinite &&
      captureNoveltyThresholdNormalized > 0 &&
      medianNormalizedDisplacement >= captureNoveltyThresholdNormalized;
}

class _Point {
  const _Point(this.x, this.y);
  final double x;
  final double y;
}

class _CornerScore {
  const _CornerScore(this.point, this.score, this.linearIndex);
  final _Point point;
  final double score;
  final int linearIndex;
}

class _GrayLevel {
  const _GrayLevel(this.data, this.width, this.height);
  final Float64List data;
  final int width;
  final int height;
}

class _ContinuousTrack {
  const _ContinuousTrack({
    required this.id,
    required this.age,
    required this.previous,
    required this.current,
    this.captureAnchor,
  });

  final int id;
  final int age;
  final _Point previous;
  final _Point current;
  final _Point? captureAnchor;
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
  int _nextTrackId = 0;

  void clear() {
    _previous = null;
    _tracks = const <_ContinuousTrack>[];
    _referenceSeedCount = 0;
    _width = 0;
    _height = 0;
    _nextTrackId = 0;
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
    final level = _toLevel(
      vinsClaheGray(gray, width: width, height: height),
      width,
      height,
    );
    final seeds = _goodFeaturesToTrack(level);
    _previous = level;
    _tracks = <_ContinuousTrack>[
      for (final seed in seeds)
        _ContinuousTrack(
          id: _nextTrackId++,
          age: 1,
          previous: seed,
          current: seed,
          captureAnchor: seed,
        ),
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
    required double principalXPixels,
    required double principalYPixels,
  }) {
    final previous = _previous;
    if (previous == null ||
        width != _width ||
        height != _height ||
        !_validGray(gray, width, height) ||
        !focalXPixels.isFinite ||
        !focalYPixels.isFinite ||
        !principalXPixels.isFinite ||
        !principalYPixels.isFinite ||
        focalXPixels <= 0 ||
        focalYPixels <= 0 ||
        principalXPixels < 0 ||
        principalYPixels < 0 ||
        principalXPixels > width ||
        principalYPixels > height) {
      return null;
    }

    final current = _toLevel(
      vinsClaheGray(gray, width: width, height: height),
      width,
      height,
    );
    // OpenCV receives maxLevel=3, then stops before a level whose dimensions
    // cannot contain the 21x21 LK window. At 128x128 this yields 128/64/32.
    final previousPyramid = _pyramid(previous, levels: 3);
    final currentPyramid = _pyramid(current, levels: 3);
    final tracked = <_ContinuousTrack>[];
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
      final anchor = track.captureAnchor;
      final stepDx = point.x - track.current.x;
      final stepDy = point.y - track.current.y;
      final stepDisplacement = math.sqrt(stepDx * stepDx + stepDy * stepDy);
      if (!stepDisplacement.isFinite) {
        continue;
      }
      tracked.add(
        _ContinuousTrack(
          id: track.id,
          age: track.age + 1,
          previous: track.current,
          current: point,
          captureAnchor: anchor,
        ),
      );
    }

    final geometricInputCount = tracked.length;
    final geometricInliers = _rejectWithVinsFundamentalMatrix(
      tracked,
      width: width,
      height: height,
      focalXPixels: focalXPixels,
      focalYPixels: focalYPixels,
      principalXPixels: principalXPixels,
      principalYPixels: principalYPixels,
    );
    final minimumDistance = math.min(width, height) * (30.0 / 480.0);
    final survivors = _retainLongTracks(geometricInliers, minimumDistance);
    for (final track in survivors) {
      final stepDx = track.current.x - track.previous.x;
      final stepDy = track.current.y - track.previous.y;
      final stepDisplacement = math.sqrt(stepDx * stepDx + stepDy * stepDy);
      stepDisplacements.add(stepDisplacement);
      final anchor = track.captureAnchor;
      if (anchor == null) continue;
      final dx = track.current.x - anchor.x;
      final dy = track.current.y - anchor.y;
      final displacement = math.sqrt(dx * dx + dy * dy);
      final normalized = math.sqrt(
        (dx / focalXPixels) * (dx / focalXPixels) +
            (dy / focalYPixels) * (dy / focalYPixels),
      );
      if (!displacement.isFinite || !normalized.isFinite) continue;
      displacements.add(displacement);
      normalizedDisplacements.add(normalized);
    }

    final stepNormalized = <double>[
      for (final track in survivors)
        math.sqrt(
          ((track.current.x - track.previous.x) / focalXPixels) *
                  ((track.current.x - track.previous.x) / focalXPixels) +
              ((track.current.y - track.previous.y) / focalYPixels) *
                  ((track.current.y - track.previous.y) / focalYPixels),
        ),
    ]..removeWhere((value) => !value.isFinite);
    final replenishment = _goodFeaturesToTrack(
      current,
      maximumCorners: math.max(0, 150 - survivors.length),
      minimumDistance: minimumDistance,
      forbidden: <_Point>[for (final track in survivors) track.current],
    );
    final active = <_ContinuousTrack>[
      ...survivors,
      for (final point in replenishment)
        _ContinuousTrack(
          id: _nextTrackId++,
          age: 1,
          previous: point,
          current: point,
        ),
    ];

    _previous = current;
    _tracks = active;
    displacements.sort();
    normalizedDisplacements.sort();
    stepDisplacements.sort();
    final common = displacements.length;
    return FrameTrackEvidence(
      seedTrackCount: _referenceSeedCount,
      commonTrackCount: common,
      commonTrackFraction: _referenceSeedCount == 0
          ? 0
          : common / _referenceSeedCount,
      medianPixelDisplacement: _median(displacements),
      medianNormalizedDisplacement: _median(normalizedDisplacements),
      medianStepPixelDisplacement: _median(stepDisplacements),
      captureNoveltyThresholdNormalized: kOfficialCaptureNoveltyThreshold(
        gridWidth: width,
        gridHeight: height,
        focalXPixels: focalXPixels,
        focalYPixels: focalYPixels,
      ),
      vinsTrackedCount: survivors.length,
      vinsActiveTrackCount: active.length,
      vinsReplenishedTrackCount: replenishment.length,
      vinsLongestTrackAge: active.fold<int>(
        0,
        (longest, track) => math.max(longest, track.age),
      ),
      vinsMeanStepNormalizedParallax: stepNormalized.isEmpty
          ? double.nan
          : stepNormalized.reduce((a, b) => a + b) / stepNormalized.length,
      vinsGeometricInputCount: geometricInputCount,
      vinsGeometricInlierCount: geometricInliers.length,
      vinsClaheApplied: true,
      vinsOccupiedGridFraction: _occupiedGridFraction(
        survivors,
        width: width,
        height: height,
      ),
    );
  }

  static bool _validGray(Uint8List gray, int width, int height) =>
      width >= 32 && height >= 32 && gray.length == width * height;

  static double _median(List<double> sorted) {
    if (sorted.isEmpty) return double.nan;
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[middle]
        : (sorted[middle - 1] + sorted[middle]) * 0.5;
  }
}

List<_ContinuousTrack> _rejectWithVinsFundamentalMatrix(
  List<_ContinuousTrack> tracks, {
  required int width,
  required int height,
  required double focalXPixels,
  required double focalYPixels,
  required double principalXPixels,
  required double principalYPixels,
}) {
  // VINS calls rejectWithF() from eight tracks onward. OpenCV dispatches
  // FM_RANSAC to seven-point RANSAC at 15+ and seven-point LMeDS at 8..14.
  if (tracks.length < 8) return tracks;
  const syntheticFocal = 460.0;
  final correspondences = <VinsCorrespondence>[];
  for (final track in tracks) {
    final first = vinsLiftProjectiveToSyntheticPixel(
      x: track.previous.x,
      y: track.previous.y,
      width: width,
      height: height,
      focalXPixels: focalXPixels,
      focalYPixels: focalYPixels,
      principalXPixels: principalXPixels,
      principalYPixels: principalYPixels,
      syntheticFocal: syntheticFocal,
    );
    final second = vinsLiftProjectiveToSyntheticPixel(
      x: track.current.x,
      y: track.current.y,
      width: width,
      height: height,
      focalXPixels: focalXPixels,
      focalYPixels: focalYPixels,
      principalXPixels: principalXPixels,
      principalYPixels: principalYPixels,
      syntheticFocal: syntheticFocal,
    );
    correspondences.add(
      VinsCorrespondence(
        firstX: first.$1,
        firstY: first.$2,
        secondX: second.$1,
        secondY: second.$2,
      ),
    );
  }
  final mask = vinsFundamentalRansacInlierMask(
    correspondences,
    thresholdPixels: 1.0,
    confidence: 0.99,
    maximumIterations: 1000,
  );
  return <_ContinuousTrack>[
    for (var index = 0; index < tracks.length; index++)
      if (mask[index]) tracks[index],
  ];
}

/// VINS `rejectWithF` first calls the camera model's `liftProjective`, divides
/// by z, then maps normalized coordinates to a synthetic 460-pixel focal plane
/// centred in the working image. The input here is already on the transported
/// pinhole image plane, so `liftProjective` is the inverse intrinsic matrix.
(double, double) vinsLiftProjectiveToSyntheticPixel({
  required double x,
  required double y,
  required int width,
  required int height,
  required double focalXPixels,
  required double focalYPixels,
  required double principalXPixels,
  required double principalYPixels,
  double syntheticFocal = 460.0,
}) => (
  (x - principalXPixels) * syntheticFocal / focalXPixels + width * 0.5,
  (y - principalYPixels) * syntheticFocal / focalYPixels + height * 0.5,
);

List<_ContinuousTrack> _retainLongTracks(
  List<_ContinuousTrack> tracks,
  double minimumDistance,
) {
  final ordered = List<_ContinuousTrack>.of(tracks)
    ..sort((a, b) {
      final byAge = b.age.compareTo(a.age);
      return byAge != 0 ? byAge : a.id.compareTo(b.id);
    });
  final selected = <_ContinuousTrack>[];
  final minimumDistanceSquared = minimumDistance * minimumDistance;
  for (final candidate in ordered) {
    var allowed = true;
    for (final existing in selected) {
      final dx = existing.current.x - candidate.current.x;
      final dy = existing.current.y - candidate.current.y;
      if (dx * dx + dy * dy < minimumDistanceSquared) {
        allowed = false;
        break;
      }
    }
    if (allowed) selected.add(candidate);
  }
  return selected;
}

FrameTrackEvidence trackFrameNovelty({
  required Uint8List previousGray,
  required Uint8List currentGray,
  required int width,
  required int height,
  required double focalXPixels,
  required double focalYPixels,
  required double principalXPixels,
  required double principalYPixels,
}) {
  final expected = width * height;
  if (width < 32 ||
      height < 32 ||
      previousGray.length != expected ||
      currentGray.length != expected ||
      !focalXPixels.isFinite ||
      !focalYPixels.isFinite ||
      !principalXPixels.isFinite ||
      !principalYPixels.isFinite ||
      focalXPixels <= 0 ||
      focalYPixels <= 0 ||
      principalXPixels < 0 ||
      principalYPixels < 0 ||
      principalXPixels > width ||
      principalYPixels > height) {
    // The bar is derived from the focals, so unusable focals leave it
    // unknowable. NaN, not a guess: isCaptureNoveltyVerified fails closed.
    return const FrameTrackEvidence(
      seedTrackCount: 0,
      commonTrackCount: 0,
      commonTrackFraction: 0,
      medianPixelDisplacement: double.nan,
      medianNormalizedDisplacement: double.nan,
      captureNoveltyThresholdNormalized: double.nan,
    );
  }

  final previous = _toLevel(
    vinsClaheGray(previousGray, width: width, height: height),
    width,
    height,
  );
  final current = _toLevel(
    vinsClaheGray(currentGray, width: width, height: height),
    width,
    height,
  );
  final seeds = _goodFeaturesToTrack(previous);
  if (seeds.isEmpty) {
    // No seed features, so there is nothing to compare — but the focals are
    // valid here, so report the real bar rather than a second NaN.
    return FrameTrackEvidence(
      seedTrackCount: 0,
      commonTrackCount: 0,
      commonTrackFraction: 0,
      medianPixelDisplacement: double.nan,
      medianNormalizedDisplacement: double.nan,
      captureNoveltyThresholdNormalized: kOfficialCaptureNoveltyThreshold(
        gridWidth: width,
        gridHeight: height,
        focalXPixels: focalXPixels,
        focalYPixels: focalYPixels,
      ),
    );
  }

  final previousPyramid = _pyramid(previous, levels: 3);
  final currentPyramid = _pyramid(current, levels: 3);
  final trackedPairs = <_ContinuousTrack>[];
  for (var index = 0; index < seeds.length; index++) {
    final seed = seeds[index];
    final trackedPoint = _trackPyramidal(previousPyramid, currentPyramid, seed);
    if (trackedPoint == null) continue;
    trackedPairs.add(
      _ContinuousTrack(
        id: index,
        age: 2,
        previous: seed,
        current: trackedPoint,
        captureAnchor: seed,
      ),
    );
  }
  final geometricInliers = _rejectWithVinsFundamentalMatrix(
    trackedPairs,
    width: width,
    height: height,
    focalXPixels: focalXPixels,
    focalYPixels: focalYPixels,
    principalXPixels: principalXPixels,
    principalYPixels: principalYPixels,
  );
  final displacements = <double>[];
  final normalizedDisplacements = <double>[];
  for (final track in geometricInliers) {
    final dx = track.current.x - track.previous.x;
    final dy = track.current.y - track.previous.y;
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
    medianStepPixelDisplacement: median,
    captureNoveltyThresholdNormalized: kOfficialCaptureNoveltyThreshold(
      gridWidth: width,
      gridHeight: height,
      focalXPixels: focalXPixels,
      focalYPixels: focalYPixels,
    ),
    vinsTrackedCount: common,
    vinsActiveTrackCount: common,
    vinsLongestTrackAge: common == 0 ? 0 : 2,
    vinsMeanStepNormalizedParallax: normalizedDisplacements.isEmpty
        ? double.nan
        : normalizedDisplacements.reduce((a, b) => a + b) /
              normalizedDisplacements.length,
    vinsGeometricInputCount: trackedPairs.length,
    vinsGeometricInlierCount: geometricInliers.length,
    vinsClaheApplied: true,
    vinsOccupiedGridFraction: _occupiedGridFraction(
      geometricInliers,
      width: width,
      height: height,
    ),
  );
}

double _occupiedGridFraction(
  List<_ContinuousTrack> tracks, {
  required int width,
  required int height,
}) {
  if (tracks.isEmpty || width <= 0 || height <= 0) return 0;
  const columns = 4;
  const rows = 4;
  final occupied = <int>{};
  for (final track in tracks) {
    final column = (track.current.x * columns / width).floor().clamp(
      0,
      columns - 1,
    );
    final row = (track.current.y * rows / height).floor().clamp(0, rows - 1);
    occupied.add(row * columns + column);
  }
  return occupied.length / (columns * rows);
}

/// Byte-for-byte port of the OpenCV CLAHE configuration enabled by the pinned
/// VINS-Mono EuRoC front end: clipLimit=3.0 and tileGridSize=8x8.
Uint8List vinsClaheGray(
  Uint8List gray, {
  required int width,
  required int height,
}) {
  const tilesX = 8;
  const tilesY = 8;
  const histogramSize = 256;
  if (width < tilesX || height < tilesY || gray.length != width * height) {
    return Uint8List.fromList(gray);
  }

  int reflect101(int coordinate, int length) {
    var value = coordinate;
    while (value >= length) {
      value = 2 * length - value - 2;
    }
    return value;
  }

  final extendedWidth = width % tilesX == 0
      ? width
      : width + tilesX - width % tilesX;
  final extendedHeight = height % tilesY == 0
      ? height
      : height + tilesY - height % tilesY;
  final tileWidth = extendedWidth ~/ tilesX;
  final tileHeight = extendedHeight ~/ tilesY;
  final tileArea = tileWidth * tileHeight;
  final clipLimit = math.max((3.0 * tileArea / histogramSize).toInt(), 1);
  final lutScale = (histogramSize - 1) / tileArea;
  final luts = List<Uint8List>.generate(
    tilesX * tilesY,
    (_) => Uint8List(histogramSize),
  );

  int sourceAt(int x, int y) =>
      gray[reflect101(y, height) * width + reflect101(x, width)];
  int saturatingRound(double value) => value <= 0
      ? 0
      : value >= 255
      ? 255
      : (value + 0.5).floor();

  for (var tileY = 0; tileY < tilesY; tileY++) {
    for (var tileX = 0; tileX < tilesX; tileX++) {
      final histogram = List<int>.filled(histogramSize, 0);
      for (var y = 0; y < tileHeight; y++) {
        final sourceY = tileY * tileHeight + y;
        for (var x = 0; x < tileWidth; x++) {
          histogram[sourceAt(tileX * tileWidth + x, sourceY)]++;
        }
      }
      var clipped = 0;
      for (var index = 0; index < histogramSize; index++) {
        if (histogram[index] <= clipLimit) continue;
        clipped += histogram[index] - clipLimit;
        histogram[index] = clipLimit;
      }
      final redistributed = clipped ~/ histogramSize;
      var residual = clipped - redistributed * histogramSize;
      for (var index = 0; index < histogramSize; index++) {
        histogram[index] += redistributed;
      }
      if (residual != 0) {
        final residualStep = math.max(histogramSize ~/ residual, 1);
        for (
          var index = 0;
          index < histogramSize && residual > 0;
          index += residualStep, residual--
        ) {
          histogram[index]++;
        }
      }
      var sum = 0;
      final lut = luts[tileY * tilesX + tileX];
      for (var index = 0; index < histogramSize; index++) {
        sum += histogram[index];
        lut[index] = saturatingRound(sum * lutScale);
      }
    }
  }

  final output = Uint8List(width * height);
  for (var y = 0; y < height; y++) {
    final tileYFloat = y / tileHeight - 0.5;
    final unclampedTileY1 = tileYFloat.floor();
    final tileY2 = math.min(unclampedTileY1 + 1, tilesY - 1);
    final tileY1 = math.max(unclampedTileY1, 0);
    final yWeight = tileYFloat - unclampedTileY1;
    final inverseYWeight = 1 - yWeight;
    for (var x = 0; x < width; x++) {
      final tileXFloat = x / tileWidth - 0.5;
      final unclampedTileX1 = tileXFloat.floor();
      final tileX2 = math.min(unclampedTileX1 + 1, tilesX - 1);
      final tileX1 = math.max(unclampedTileX1, 0);
      final xWeight = tileXFloat - unclampedTileX1;
      final inverseXWeight = 1 - xWeight;
      final value = gray[y * width + x];
      final top =
          luts[tileY1 * tilesX + tileX1][value] * inverseXWeight +
          luts[tileY1 * tilesX + tileX2][value] * xWeight;
      final bottom =
          luts[tileY2 * tilesX + tileX1][value] * inverseXWeight +
          luts[tileY2 * tilesX + tileX2][value] * xWeight;
      output[y * width + x] = saturatingRound(
        top * inverseYWeight + bottom * yWeight,
      );
    }
  }
  return output;
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

List<_Point> _goodFeaturesToTrack(
  _GrayLevel image, {
  int maximumCorners = 150,
  double minimumDistance = -1,
  List<_Point> forbidden = const <_Point>[],
}) {
  // OpenCV goodFeaturesToTrack defaults used by VINS: Sobel 3x3,
  // blockSize=3, qualityLevel=.01 and 3x3 local-maximum suppression.
  const qualityLevel = 0.01;
  if (maximumCorners <= 0) return const <_Point>[];
  final effectiveMinimumDistance = minimumDistance > 0
      ? minimumDistance
      : math.min(image.width, image.height) * (30.0 / 480.0);
  final scoreImage = _opencvMinimumEigenvalueImage(image);
  var maximumScore = 0.0;
  for (final score in scoreImage) {
    if (score > maximumScore) maximumScore = score;
  }
  if (maximumScore <= 0) return const <_Point>[];
  final threshold = maximumScore * qualityLevel;
  final candidates = <_CornerScore>[];
  for (var y = 1; y < image.height - 1; y++) {
    for (var x = 1; x < image.width - 1; x++) {
      final index = y * image.width + x;
      final score = scoreImage[index];
      if (score <= threshold) continue;
      var localMaximum = score;
      for (var dy = -1; dy <= 1; dy++) {
        for (var dx = -1; dx <= 1; dx++) {
          localMaximum = math.max(
            localMaximum,
            scoreImage[(y + dy) * image.width + x + dx],
          );
        }
      }
      if (score == localMaximum) {
        candidates.add(
          _CornerScore(_Point(x.toDouble(), y.toDouble()), score, index),
        );
      }
    }
  }
  candidates.sort((a, b) {
    final scoreOrder = b.score.compareTo(a.score);
    return scoreOrder != 0
        ? scoreOrder
        : b.linearIndex.compareTo(a.linearIndex);
  });
  final selected = <_Point>[];
  final minimumDistanceSquared =
      effectiveMinimumDistance * effectiveMinimumDistance;
  for (final candidate in candidates) {
    var farEnough = true;
    for (final point in forbidden) {
      final dx = point.x - candidate.point.x;
      final dy = point.y - candidate.point.y;
      if (dx * dx + dy * dy < minimumDistanceSquared) {
        farEnough = false;
        break;
      }
    }
    if (!farEnough) continue;
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

Float32List _opencvMinimumEigenvalueImage(_GrayLevel image) {
  const sobelScale = 1.0 / (4 * 3 * 255);
  final dx = Float32List(image.width * image.height);
  final dy = Float32List(image.width * image.height);
  double pixel(int x, int y) {
    int reflect101(int coordinate, int length) {
      var value = coordinate;
      while (value < 0 || value >= length) {
        value = value < 0 ? -value : 2 * length - value - 2;
      }
      return value;
    }

    return image.data[reflect101(y, image.height) * image.width +
        reflect101(x, image.width)];
  }

  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final index = y * image.width + x;
      dx[index] =
          (-pixel(x - 1, y - 1) +
              pixel(x + 1, y - 1) -
              2 * pixel(x - 1, y) +
              2 * pixel(x + 1, y) -
              pixel(x - 1, y + 1) +
              pixel(x + 1, y + 1)) *
          sobelScale;
      dy[index] =
          (-pixel(x - 1, y - 1) -
              2 * pixel(x, y - 1) -
              pixel(x + 1, y - 1) +
              pixel(x - 1, y + 1) +
              2 * pixel(x, y + 1) +
              pixel(x + 1, y + 1)) *
          sobelScale;
    }
  }
  final covarianceA = Float32List(image.width * image.height);
  final covarianceB = Float32List(image.width * image.height);
  final covarianceC = Float32List(image.width * image.height);
  for (var index = 0; index < dx.length; index++) {
    covarianceA[index] = dx[index] * dx[index];
    covarianceB[index] = dx[index] * dy[index];
    covarianceC[index] = dy[index] * dy[index];
  }
  final filteredA = Float32List(image.width * image.height);
  final filteredB = Float32List(image.width * image.height);
  final filteredC = Float32List(image.width * image.height);
  int reflect101(int coordinate, int length) {
    var value = coordinate;
    while (value < 0 || value >= length) {
      value = value < 0 ? -value : 2 * length - value - 2;
    }
    return value;
  }

  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      var a = 0.0;
      var b = 0.0;
      var c = 0.0;
      for (var wy = -1; wy <= 1; wy++) {
        final yy = reflect101(y + wy, image.height);
        for (var wx = -1; wx <= 1; wx++) {
          final xx = reflect101(x + wx, image.width);
          final index = yy * image.width + xx;
          a += covarianceA[index];
          b += covarianceB[index];
          c += covarianceC[index];
        }
      }
      final index = y * image.width + x;
      filteredA[index] = a;
      filteredB[index] = b;
      filteredC[index] = c;
    }
  }
  final output = Float32List(image.width * image.height);
  for (var index = 0; index < output.length; index++) {
    final a = filteredA[index];
    final b = filteredB[index];
    final c = filteredC[index];
    final halfA = a * 0.5;
    final halfC = c * 0.5;
    output[index] =
        halfA + halfC - math.sqrt((halfA - halfC) * (halfA - halfC) + b * b);
  }
  return output;
}

List<(int, int)> vinsGoodFeaturesToTrack(
  Uint8List gray, {
  required int width,
  required int height,
  int maximumCorners = 150,
  double minimumDistance = -1,
}) {
  if (gray.length != width * height || width <= 0 || height <= 0) {
    return const <(int, int)>[];
  }
  return <(int, int)>[
    for (final point in _goodFeaturesToTrack(
      _toLevel(gray, width, height),
      maximumCorners: maximumCorners,
      minimumDistance: minimumDistance,
    ))
      (point.x.round(), point.y.round()),
  ];
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
  final base = current.first;
  return estimate.x >= 1 &&
          estimate.y >= 1 &&
          estimate.x < base.width - 1 &&
          estimate.y < base.height - 1
      ? estimate
      : null;
}

_Point? _trackOneLevel(
  _GrayLevel previous,
  _GrayLevel current,
  _Point source,
  _Point initial,
) {
  // VINS passes cv::Size(21,21) to calcOpticalFlowPyrLK.
  const radius = 10;
  const maximumIterations = 30;
  const epsilonSquared = 0.01 * 0.01;
  const minimumEigenvalue = 1e-4;
  var x = initial.x;
  var y = initial.y;

  for (var iteration = 0; iteration < maximumIterations; iteration++) {
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

double _sample(_GrayLevel level, double x, double y) {
  int reflect101(int coordinate, int length) {
    if (length <= 1) return 0;
    var value = coordinate;
    while (value < 0 || value >= length) {
      value = value < 0 ? -value : 2 * length - value - 2;
    }
    return value;
  }

  final rawX0 = x.floor();
  final rawY0 = y.floor();
  final x0 = reflect101(rawX0, level.width);
  final y0 = reflect101(rawY0, level.height);
  final x1 = reflect101(rawX0 + 1, level.width);
  final y1 = reflect101(rawY0 + 1, level.height);
  final fx = x - rawX0;
  final fy = y - rawY0;
  final top =
      level.data[y0 * level.width + x0] * (1 - fx) +
      level.data[y0 * level.width + x1] * fx;
  final bottom =
      level.data[y1 * level.width + x0] * (1 - fx) +
      level.data[y1 * level.width + x1] * fx;
  return top * (1 - fy) + bottom * fy;
}
