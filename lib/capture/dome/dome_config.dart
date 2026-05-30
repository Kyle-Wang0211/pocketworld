// Single-file home for every tunable that affects the floating
// capture-guidance dome. Open this when you want to "make the dome
// track the phone more aggressively" / "use more (or fewer) target
// points" / "make the visit transition slower" — all numbers live here.
//
// Three groups, kept apart on purpose:
//   • [DomeThresholds]      — algorithm gates for the LEGACY 60-cell
//                             ring-buffer state machine. After the v3
//                             refactor these no longer drive the user-
//                             visible dome; they still control the
//                             internal upload curator (which frames get
//                             shipped to the cloud per cell).
//   • [DomeAnimationConfig] — orientation smoothing for the dome's
//                             rotation lerp.
//   • [DomePointConfig]     — target-point coverage system that REPLACED
//                             the cell state machine in the user UI.
//                             Open this to tune "how forgiving is the
//                             visit angle" / "how many points total".
//
// All three have a const `.defaults`. Pass a custom instance via the
// usual constructor argument to override a few numbers without
// restating the rest.

export 'dome_thresholds.dart';

/// Orientation smoothing for the dome's rotation lerp.
/// Pure UX — does NOT affect which frames get accepted as visits.
class DomeAnimationConfig {
  /// Low-pass smoothing factor for dome rotation lerp, in [0..1].
  /// **1.0 = no smoothing (dome follows pose 1:1).** Bumped from the
  /// iOS reference's 0.2 after user feedback "球转得慢" + the
  /// reasoning that ARKit's pose stream is already EKF-filtered, so
  /// adding our own low-pass introduces lag without meaningful noise
  /// reduction. If hand-held jitter shows through visibly when the
  /// user holds still, back off to 0.7-0.8 (still nearly imperceptible
  /// lag, filters the worst micro-shakes).
  final double smoothingAlpha;

  /// Per-tick smoothing delta below this is treated as converged: no
  /// orientation update, no repaint notify. Lets a stationary dome
  /// drop to 0 Hz paint instead of burning frames on imperceptible
  /// lerp deltas (any α produces non-zero deltas forever otherwise).
  final double smoothEpsilon;

  const DomeAnimationConfig({
    this.smoothingAlpha = 1.0,
    this.smoothEpsilon = 1e-4,
  });

  /// iOS-reference defaults — exactly what `ObjectModeV2DomeView.swift`
  /// uses in production. The starting point for any tuning experiment.
  static const DomeAnimationConfig defaults = DomeAnimationConfig();

  DomeAnimationConfig copyWith({
    double? smoothingAlpha,
    double? smoothEpsilon,
  }) {
    return DomeAnimationConfig(
      smoothingAlpha: smoothingAlpha ?? this.smoothingAlpha,
      smoothEpsilon: smoothEpsilon ?? this.smoothEpsilon,
    );
  }
}

/// Target-point coverage system — the user-visible "how much have I
/// captured" signal AND the data-quality layer underneath. v6: visual
/// = data, 1:1 mapping (each point owns its own RingBufferCell with
/// the same 5-gate strict promotion as iOS Aether3D v1).
///
/// Ring topology — **cosine-weighted azimuth count per ring**, so
/// equator is dense and poles collapse to a single point. No more
/// "18 dots crammed at the pole" waste.
///
/// Default config: 11 rings between -90° and +90° (18° step), with
/// per-ring az counts following `round(equatorAzCount × cos(elRad))`,
/// floored at 1 (so poles get exactly 1 point):
///
///   ring  el°  azCount
///   ─────────────────
///   0    -90°    1   ← nadir (south star)
///   1    -72°    6
///   2    -54°   11
///   3    -36°   15
///   4    -18°   17
///   5      0°   18   ← equator
///   6    +18°   17
///   7    +36°   15
///   8    +54°   11
///   9    +72°    6
///   10   +90°    1   ← zenith (north star)
///   ────────────────
///   total       118
///
/// Each point's RingBufferCell stores up to [DomeThresholds.maxFramesPerCell]
/// frames with diversity-driven eviction. Promotion (point → "visited")
/// runs the full 5-gate v1 check from `RingBufferCell.computeRawState`:
/// ≥3 frames + median sharpness ≥ 600 + az spread ≥ 3° + time spread
/// ≥ 0.5 s + max motion ≤ 0.5.
class DomePointConfig {
  /// Number of azimuth points at the equator (the densest ring).
  /// Higher latitudes get proportionally fewer points via
  /// `round(equatorAzCount × cos(elRad))`, floored at 1.
  final int equatorAzCount;

  /// Number of elevation rings between [minElevationDeg] and
  /// [maxElevationDeg], inclusive at both ends. Default 11 rings at
  /// 18° steps (-90, -72, -54, -36, -18, 0, +18, +36, +54, +72, +90).
  final int elCount;

  /// Bottom-most ring elevation in degrees. -90 = nadir (straight down).
  /// At ±90° the cosine-weighted azCount collapses to 1, giving a
  /// single pole point ("south star / north star") instead of N
  /// degenerate stacked points.
  final double minElevationDeg;
  /// Top-most ring elevation in degrees. +90 = zenith (straight up).
  final double maxElevationDeg;

  /// Visit transition animation duration. Newly-visited points
  /// interpolate dark(2.0px outlined) → bright white(2.5px solid)
  /// over this time. Pure UX, no semantic effect.
  final Duration visitFadeDuration;

  const DomePointConfig({
    this.equatorAzCount = 18,
    this.elCount = 11,
    this.minElevationDeg = -90,
    this.maxElevationDeg = 90,
    this.visitFadeDuration = const Duration(milliseconds: 300),
  });

  static const DomePointConfig defaults = DomePointConfig();

  DomePointConfig copyWith({
    int? equatorAzCount,
    int? elCount,
    double? minElevationDeg,
    double? maxElevationDeg,
    Duration? visitFadeDuration,
  }) {
    return DomePointConfig(
      equatorAzCount: equatorAzCount ?? this.equatorAzCount,
      elCount: elCount ?? this.elCount,
      minElevationDeg: minElevationDeg ?? this.minElevationDeg,
      maxElevationDeg: maxElevationDeg ?? this.maxElevationDeg,
      visitFadeDuration: visitFadeDuration ?? this.visitFadeDuration,
    );
  }
}
