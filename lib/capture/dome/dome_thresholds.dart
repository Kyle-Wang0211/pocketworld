// Quality thresholds for promoting a cell from `weak` → `ok` → `excellent`.
//
// Ported verbatim from Aether3D's
// `ObjectModeV2CoverageMap.swift::DomeThresholds`. Tuning these is the
// difference between "user feels the dome lights up too easily" (too lax)
// and "user circles three times and nothing turns dark green" (too strict).
//
// The Aether3D defaults are a known-good starting point that's been tuned
// against real captures; do NOT casually re-derive them.

class DomeThresholds {
  /// Hard floor on Laplacian variance. Frames below this are dropped at
  /// `DomeCoverageMap.ingest`, before any cell sees them.
  final double minSharpness;

  /// Center/subject-region sharpness floor. This is intentionally close
  /// to [minSharpness] so a crisp background cannot hide a blurry subject.
  final double minRoiSharpness;

  /// Multi-signal consensus floor, derived from center crops at multiple
  /// scales. Conservative: all subject-scale probes need to agree.
  final double minSharpnessConsensus;

  /// Edge-rich-block sharpness floor. Used with ROI sharpness to reject
  /// smooth blown-out or textureless frames without punishing every
  /// valid low-texture object by itself.
  final double minEdgeBlockSharpness;

  /// Allow the subject ROI to be slightly softer than the background,
  /// but reject obvious "background crisp, subject out of focus" cases.
  final double minSubjectBackgroundSharpnessDelta;

  /// Ignore frames immediately after subject lock so autofocus/exposure
  /// and AR anchor pose have time to settle.
  final double originSettleSeconds;

  /// Live radius outlier clamp. This is deliberately loose; the stricter
  /// shell logic runs in post-capture curation.
  final double maxLiveRadiusRatio;

  /// Minimum frames in a cell's ring buffer before it can promote to
  /// `excellent`. (In `ok` only one or two frames is enough.)
  final int excellentMinFrames;

  /// Median sharpness of the buffer ≥ this for `excellent`.
  final double excellentMinSharpnessMedian;

  /// Azimuth spread (max − min, °) across the buffer ≥ this. Forces the
  /// user to actually MOVE around the object — not stand still and pile up
  /// frames at the same angle.
  final double excellentMinAzSpreadDeg;

  /// Wall-clock time between the oldest and newest frame in the buffer ≥
  /// this. Same intent as `excellentMinAzSpreadDeg` — prevents a 30 fps
  /// burst at one pose from masquerading as a thorough capture.
  final double excellentMinTimeSpreadSec;

  /// Worst per-frame motion score in the buffer ≤ this. (Motion score is
  /// the gyro-integrated rotational rate, normalized to [0, 1] where 1 is
  /// fast hand wobble.)
  final double excellentMaxMotion;

  /// Ring buffer capacity per cell. Diversity-driven eviction keeps the
  /// most novel frames; see `RingBufferCell.append`.
  ///
  /// Bumped from iOS Aether3D's 8 → 12. Under v6's 1:1 visual=data design,
  /// each visual point owns one ring-buffer cell of this capacity.
  ///
  /// Plan G W2 P5: curateForUpload now picks ~5 best frames per cell
  /// (118 cells × 5 = 590 target) for 3DGS noise-robustness — per-angle
  /// redundancy averages out independent DA3 / ARKit / sensor noise
  /// during Gaussian fit. 12 buffer slots leave headroom over the 5
  /// retained, so diversity-eviction has room to discard near-duplicates.
  final int maxFramesPerCell;

  /// Per-frame angular velocity hard reject (rad/s). Frames captured while
  /// the device's gyro magnitude exceeds this go straight to /dev/null —
  /// motion blur + ARKit pose error are too high to be useful, no matter
  /// what the dome cell says about coverage.
  ///
  /// Verbatim of `ObjectModeV2ARDomeCoordinator.swift` line 542:
  /// `angularVelocityLimit: Float = 2.0` (≈ 115 °/s, brisk but not violent).
  final double maxAngularRateRadPerSec;

  /// Per-frame brightness hard reject window (mean luma, 0..255). Frames
  /// outside [minBrightness, maxBrightness] are dropped at ingest:
  ///   < 60   → too dark (Laplacian goes noisy, VGGT depth confidence drops)
  ///   > 200  → blown out (saturated highlights kill texture gradient)
  ///
  /// Verbatim of iOS `FrameQualityConstants.swift` lines 9–10:
  /// `darkThresholdBrightness = 60.0`, `brightThresholdBrightness = 200.0`.
  final double minBrightness;
  final double maxBrightness;

  /// Per-frame elevation hard reject (degrees). Frames whose camera-to-
  /// subject elevation falls outside [-maxAbsElevationDeg, +maxAbsElevationDeg]
  /// are dropped — these point at the ceiling / under the table, far from
  /// any plausible object surface, and just contaminate the dome.
  ///
  /// Verbatim of iOS `ObjectModeV2CoverageMap.swift` line 144:
  /// `if elDeg < -75 || elDeg > 75 { return nil }`.
  final double maxAbsElevationDeg;

  const DomeThresholds({
    this.minSharpness = 500,
    this.minRoiSharpness = 450,
    this.minSharpnessConsensus = 420,
    this.minEdgeBlockSharpness = 220,
    this.minSubjectBackgroundSharpnessDelta = -350,
    this.originSettleSeconds = 0.75,
    this.maxLiveRadiusRatio = 3.0,
    this.excellentMinFrames = 2,
    this.excellentMinSharpnessMedian = 600,
    this.excellentMinAzSpreadDeg = 3,
    this.excellentMinTimeSpreadSec = 0.5,
    this.excellentMaxMotion = 0.50,
    this.maxFramesPerCell = 12,
    this.maxAngularRateRadPerSec = 2.0,
    this.minBrightness = 60,
    this.maxBrightness = 200,
    this.maxAbsElevationDeg = 75,
  });

  static const DomeThresholds defaults = DomeThresholds();
}
