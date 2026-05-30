// Dart mirror of FrameQualityConstants from
// `Core/Support/Constants/FrameQualityConstants.swift` in the iOS
// Aether3D codebase. Values here are VERBATIM — change them only if
// the iOS source changes (and ideally update both at the same time).
//
// Last alignment: 2026-04-30 against
// Core/Support/Constants/FrameQualityConstants.swift HEAD.
// Reference values shown in the iOS source comments come from V2.10
// METHODOLOGY tightening (PR #5 in the constitution patch series).

class FrameQualityConstants {
  FrameQualityConstants._();

  /// Laplacian-variance threshold below which a frame is marked blurry
  /// → hard reject in GuidanceEngine.
  static const double blurThresholdLaplacian = 200.0;

  /// Mean-brightness threshold below which a frame is considered dark
  /// (hard reject for the object-mode-V2 pipeline).
  static const double darkThresholdBrightness = 60.0;

  /// Mean-brightness threshold above which a frame is considered
  /// blown-out (hard reject).
  static const double brightThresholdBrightness = 200.0;

  /// Maximum byte-level signature similarity before a frame is
  /// downgraded as "redundant" (too similar to the last accepted
  /// frame). Used by `_maximumSimilarity` for `subject` mode.
  static const double maxFrameSimilarity = 0.92;

  /// Floor for similarity in `group` mode after the iOS 0.04 step-down.
  /// `_maximumSimilarity(.group) = max(minFrameSimilarity,
  /// maxFrameSimilarity - 0.04)`.
  static const double minFrameSimilarity = 0.50;

  /// Minimum global variance under which the target texture is
  /// considered too flat for reliable SfM tracking — soft downgrade.
  /// (iOS upper-cases the constant name; we follow Dart conventions
  /// but spell it out below for grep parity.)
  static const double minLocalVarianceForTexture = 10.0;

  /// Inherited from the native ORB pipeline — minimum feature count per
  /// frame before SfM is viable. Used by the broker `pipelineAuditFields`
  /// payload so the cloud can cross-check the client's local audit.
  /// Values verbatim from iOS `FrameQualityConstants.swift` lines 17-18.
  static const int minOrbFeaturesForSfm = 500;
  static const int warnOrbFeaturesForSfm = 800;
}

/// Target-zone mode — affects acceptance threshold for the target zone
/// occupancy / similarity gates. Verbatim of iOS
/// `ObjectModeV2TargetZoneMode`. Raw values are stable string IDs so
/// they can appear in the broker audit payload without translation.
enum TargetZoneMode {
  /// Single subject filling roughly the centered 24%×28% of the frame.
  /// Tighter zone, stricter occupancy required.
  subject('subject'),

  /// Multi-object / scene mode — wider 38%×34% zone, looser occupancy
  /// gate, slightly lower max similarity (so the engine doesn't reject
  /// frames that look alike when several subjects fill the same area).
  group('group');

  const TargetZoneMode(this.rawValue);
  final String rawValue;
}
