// Per-frame sample fed to the coverage map.
//
// Ported from `ObjectModeV2CoverageMap.swift::CapturedFrameSample`. Carries
// only lightweight scalar metadata — no pixel buffer reference. Plan G W2
// 全本地 (2026-05-16) photos-on-disk arch: the actual image lives at
// `jpegPath` (cell-admitted JPEG on disk, written by AetherARKitPlugin's
// saveCurrentFrameAsJpeg when this sample's cell admitted it).
//
// Sources (which streams produce these fields) on iOS:
//   - timestamp, sharpness  → on-device FrameAnalyzer (Laplacian variance)
//   - azimuth, elevation    → ARKit camera transform projected onto unit sphere
//   - motionScore           → IMU gyro magnitude, normalized
//   - exposureScore         → AVFoundation exposure metering
//   - frameID               → "cap-N" stable id, lets the local W3 path
//                             match this metadata back to its JPEG
//   - cameraExtrinsic4x4    → ARKit camera→world matrix (also written to
//                             the per-photo .json sidecar by native so
//                             W3 stages can read independently)
//   - cameraIntrinsicFxFyCxCy → ARKit camera intrinsics (same)
//
// On Flutter we'll get the first two via sensor fusion + a Laplacian Dart
// port, and the AR-only fields (extrinsic / intrinsic) will stay null in
// the v1 sensor-only path.

class CapturedFrameSample {
  /// Wall-clock seconds (e.g. `Stopwatch().elapsedMicroseconds / 1e6` from a
  /// shared monotonic clock started when the recording began).
  final double timestamp;

  /// Camera azimuth around the locked world origin, radians.
  final double azimuth;

  /// Camera elevation above the equator, radians.
  final double elevation;

  /// Laplacian variance — bigger = sharper. Typical 100..2000 on iPhone.
  final double sharpness;

  /// Capture radius in meters: distance(camera, locked subject origin).
  /// This is the key signal for keeping pose-conditioned DA3 K-window frames
  /// inside the same view shell.
  final double cameraRadiusM;

  /// Approximate subject footprint in the frame. Uses a nominal object
  /// diameter until a real subject mask is available.
  final double subjectFootprintRatio;

  /// Multi-signal sharpness consensus. The first value is centered on
  /// the subject/crosshair; edge-block and subject/background checks
  /// catch the "background sharp, subject blurry" case.
  final double roiSharpness;
  final double multiScaleSharpness252;
  final double multiScaleSharpness512;
  final double edgeBlockSharpness;
  final double subjectVsBackgroundSharpnessDelta;
  final double sharpnessConsensus;

  /// Normalized motion ([0..1]). Lower = more stable hand. Computed from
  /// gyro rate magnitude.
  final double motionScore;

  /// Raw angular velocity magnitude in rad/s, sourced from
  /// [OrientationTracker]'s gyro magnitude (sqrt of gyroMagSqEMA).
  /// Distinct from `motionScore` (which is [0..1] normalized): we keep
  /// the physical unit so the ingest gate can match Aether3D iOS's
  /// `angularVelocityLimit = 2.0 rad/s` verbatim. Defaults to 0 so
  /// mock providers (Web / 鸿蒙) pass the gate without surgery.
  final double angularVelocityRadPerSec;

  /// Normalized exposure quality ([0..1]). 1 = perfect.
  final double exposureScore;

  /// Mean Y-channel luma over a downsampled crop of the frame, 0..255.
  /// Lets the ingest gate hard-reject too-dark (<60) and blown-out (>200)
  /// frames per Aether3D's `FrameQualityConstants`. Defaults to 128
  /// (mid-gray) so mock providers pass without surgery.
  final double meanBrightness;

  /// Native focus/exposure metadata. When unavailable, defaults are
  /// permissive so non-iOS backends do not get blocked.
  final bool focusStable;
  final bool isAdjustingFocus;
  final bool isAdjustingExposure;
  final double lensPosition;
  final double exposureTargetOffset;
  final String? trackingStateName;

  /// Stable identifier so the server can correlate this metadata row with a
  /// specific video frame later.
  final String frameId;

  /// camera→world 4×4 (row-major 16 floats). Null on the sensor-only path.
  final List<double>? cameraExtrinsic4x4;

  /// `[fx, fy, cx, cy]`. Null on the sensor-only path.
  final List<double>? cameraIntrinsicFxFyCxCy;

  /// Internal proxy for how useful this frame's sparse VIO anchors are
  /// likely to be for DA3 metric scale alignment. Computed natively
  /// from the current ARFrame's raw feature points and camera pose.
  final int scaleAlignAnchorCount;
  final double scaleAlignDepthSpanM;
  final double scaleAlignReliabilityPrior;

  /// Where this frame's az/el came from. One of:
  ///   • `'arkit'` — ARKit `trackingState == .normal`, position-based
  ///     azimuth/elevation projected onto the unit sphere. Authoritative.
  ///   • `'imu'`   — ARKit was in `.limited(...)`, so we substituted
  ///     IMU-derived yaw + pitch with an offset anchored to the last
  ///     ARKit-normal sample. Coarser; the server treats these frames
  ///     as guidance metadata, not as ground-truth pose for the
  ///     reconstruction (VGGT solves pose from images independently —
  ///     see `arxiv 2503.11651`).
  /// `pose_source` is forwarded into per-photo metadata (`.json` next
  /// to the JPEG) so consumers can log/sanity-check the IMU-vs-ARKit
  /// ratio per scan.
  final String poseSource;

  /// Plan G W2 photos-on-disk arch: absolute path to the JPEG saved
  /// when this sample was admitted to its cell slot, or `null` if no
  /// JPEG was written (mock provider, native save failure, or warm-up
  /// before the photos directory was set up). The path follows the
  /// `<photosDir>/cell_<cellIdx>_slot_<slotIdx>.jpg` convention so
  /// diversity-eviction overwrites the previous slot's JPEG in-place.
  final String? jpegPath;

  const CapturedFrameSample({
    required this.timestamp,
    required this.azimuth,
    required this.elevation,
    required this.sharpness,
    required this.motionScore,
    required this.exposureScore,
    required this.frameId,
    this.cameraRadiusM = 0.0,
    this.subjectFootprintRatio = 0.0,
    this.roiSharpness = 0.0,
    this.multiScaleSharpness252 = 0.0,
    this.multiScaleSharpness512 = 0.0,
    this.edgeBlockSharpness = 0.0,
    this.subjectVsBackgroundSharpnessDelta = 0.0,
    this.sharpnessConsensus = 0.0,
    this.cameraExtrinsic4x4,
    this.cameraIntrinsicFxFyCxCy,
    this.scaleAlignAnchorCount = 0,
    this.scaleAlignDepthSpanM = 0.0,
    this.scaleAlignReliabilityPrior = 0.0,
    this.poseSource = 'arkit',
    this.angularVelocityRadPerSec = 0.0,
    this.meanBrightness = 128.0,
    this.focusStable = true,
    this.isAdjustingFocus = false,
    this.isAdjustingExposure = false,
    this.lensPosition = 0.0,
    this.exposureTargetOffset = 0.0,
    this.trackingStateName,
    this.jpegPath,
  });

  /// Used after dome admission to stamp the saved JPEG path back onto
  /// the sample held by the ring buffer slot. Returns a copy with all
  /// fields preserved + `jpegPath` overridden.
  CapturedFrameSample withJpegPath(String? newJpegPath) {
    return CapturedFrameSample(
      timestamp: timestamp,
      azimuth: azimuth,
      elevation: elevation,
      sharpness: sharpness,
      motionScore: motionScore,
      exposureScore: exposureScore,
      frameId: frameId,
      cameraRadiusM: cameraRadiusM,
      subjectFootprintRatio: subjectFootprintRatio,
      roiSharpness: roiSharpness,
      multiScaleSharpness252: multiScaleSharpness252,
      multiScaleSharpness512: multiScaleSharpness512,
      edgeBlockSharpness: edgeBlockSharpness,
      subjectVsBackgroundSharpnessDelta: subjectVsBackgroundSharpnessDelta,
      sharpnessConsensus: sharpnessConsensus,
      cameraExtrinsic4x4: cameraExtrinsic4x4,
      cameraIntrinsicFxFyCxCy: cameraIntrinsicFxFyCxCy,
      scaleAlignAnchorCount: scaleAlignAnchorCount,
      scaleAlignDepthSpanM: scaleAlignDepthSpanM,
      scaleAlignReliabilityPrior: scaleAlignReliabilityPrior,
      poseSource: poseSource,
      angularVelocityRadPerSec: angularVelocityRadPerSec,
      meanBrightness: meanBrightness,
      focusStable: focusStable,
      isAdjustingFocus: isAdjustingFocus,
      isAdjustingExposure: isAdjustingExposure,
      lensPosition: lensPosition,
      exposureTargetOffset: exposureTargetOffset,
      trackingStateName: trackingStateName,
      jpegPath: newJpegPath,
    );
  }
}
