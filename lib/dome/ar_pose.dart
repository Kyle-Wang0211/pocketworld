// Cross-platform AR pose abstraction.
//
// Design rule: business logic (dome view, coverage map, guidance
// engine) depends on this interface ONLY. Per-platform AR backends
// (ARKit, ARCore, HarmonyOS XR Engine, WebXR) implement it behind
// a MethodChannel. This keeps the Dart side 100% portable.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

/// Thin cross-platform preview point emitted by native AR executors.
///
/// This is capture-time guidance data only. The point position comes
/// from platform VIO feature points (ARKit rawFeaturePoints / ARCore
/// PointCloud equivalents), optionally color-sampled from the current
/// camera frame. It is not DA3 geometry truth and must not be consumed
/// by the reconstruction pipeline as metric depth.
class ARPreviewPoint {
  final Vector3 position;
  final int r;
  final int g;
  final int b;
  final double confidence;

  const ARPreviewPoint({
    required this.position,
    required this.r,
    required this.g,
    required this.b,
    required this.confidence,
  });
}

/// Camera pose at one AR frame. All values in world space with the
/// scene's origin at the captured object's approximate center (set by
/// `lockOrigin` once the user has framed the subject).
class ARPose {
  /// Camera position in world space, meters.
  final Vector3 position;

  /// Camera orientation (unit quaternion). `rotate(Vector3(0, 0, -1))`
  /// is the camera's forward axis — ARKit / ARCore convention.
  final Quaternion orientation;

  /// Position-based azimuth in radians, relative to `worldYaw`.
  /// Equals `atan2(rel.z, rel.x) - worldYaw` where
  /// `rel = position - worldOrigin`. Zero means "at the lock pose".
  final double azimuth;

  /// Position-based elevation in radians. Equals
  /// `atan2(rel.y, max(horizDist, 0.001))`. Positive = camera is
  /// above the world origin's horizontal plane.
  final double elevation;

  /// Tracking state. Dome UI hides guidance when not tracking.
  final bool isTracking;

  /// Native AR runtime's tracking-state classification, mirrored as a
  /// string so the Dart layer doesn't carry per-platform enums. Values:
  ///
  ///   "normal", "not_available",
  ///   "limited_initializing", "limited_relocalizing",
  ///   "limited_excessive_motion", "limited_insufficient_features",
  ///   "limited_unknown"
  ///
  /// Set by `AetherARKitPlugin` (iOS) verbatim of `ARCamera.TrackingState`.
  /// Mock providers (Web, HarmonyOS, simulator) pass `"normal"` because
  /// they have no real tracker. Null when the underlying provider hasn't
  /// supplied a value yet — `PoseDriftTracker` treats null as `"normal"`
  /// to avoid mis-attributing diagnostic time to the mock path.
  ///
  /// Used purely for Tier 1 pose-drift aggregation in
  /// [PoseDriftTracker]; nothing in the live UI consumes it (dome cell
  /// colors already convey real-time AR health).
  final String? trackingStateName;

  /// Wall-clock timestamp (seconds since app start, ARFrame timeline)
  /// used by smoothing / time-spread checks.
  final double timestamp;

  /// True iff `lockOrigin` has been called and the world reference
  /// frame is established. Before lock, `azimuth` / `elevation` are
  /// zero placeholders.
  final bool hasOrigin;

  /// World origin (the captured object's approximate center). Zero
  /// vector before lock.
  final Vector3 worldOrigin;

  /// Camera's bearing at lock time. Zero before lock.
  final double worldYaw;

  /// 16-float column-major 4×4 camera-to-world transform from the
  /// underlying AR runtime. Goes straight into curated.json's
  /// `arkit_extrinsic_4x4` field. Empty if the backend doesn't
  /// supply it (mock path).
  final List<double> extrinsic4x4;

  /// Camera intrinsics `[fx, fy, cx, cy]`. Same target field as
  /// extrinsic — populated when the backend has them.
  final List<double> intrinsicFxFyCxCy;

  /// Camera image dimensions backing [intrinsicFxFyCxCy]. Zero when the
  /// backend does not expose a real camera frame.
  final int imageWidth;
  final int imageHeight;

  /// Lightweight capture-time proxy for how well sparse VIO points can
  /// constrain DA3 metric scale alignment. This is internal ranking
  /// metadata, not user-facing state.
  final int scaleAlignAnchorCount;
  final double scaleAlignDepthSpanM;
  final double scaleAlignReliabilityPrior;

  /// Hardware focus/exposure metadata when the platform exposes it.
  /// These are internal capture-quality signals; the user should see
  /// guidance, not camera jargon.
  final bool isAdjustingFocus;
  final bool isAdjustingExposure;
  final double lensPosition;
  final double exposureTargetOffset;

  /// Per-frame quality report — Laplacian variance + brightness +
  /// signature, derived in pure Dart from the 128×128 Y-plane thumbnail
  /// the native AR plugin ships at 6 Hz (matching iOS Aether3D's
  /// `visualSampleInterval = 1.0 / 6.0`). The math itself lives in
  /// `lib/quality/quality_compute.dart` so all four target platforms
  /// (iOS, Android, Web, HarmonyOS) share one implementation — each
  /// platform's native bridge only has to produce the gray128 blob
  /// out of its respective YUV camera buffer.
  ///
  /// ARKit on iOS holds exclusive camera access while the AR session
  /// is running, so the Flutter `camera` plugin can't deliver an image
  /// stream in parallel — that's why this path exists in the first
  /// place. Null on pre-quality frames or when running on the
  /// synthetic mock.
  final FrameQualityReport? quality;

  /// Throttled raw AR preview points for the RealityScan-style capture
  /// UI. Native owns only the platform read + optional pixel sampling;
  /// Dart owns all voxel hashing, quality coloring, minimap, and policy.
  final List<ARPreviewPoint> previewPoints;

  const ARPose({
    required this.position,
    required this.orientation,
    required this.azimuth,
    required this.elevation,
    required this.isTracking,
    required this.timestamp,
    required this.hasOrigin,
    required this.worldOrigin,
    required this.worldYaw,
    required this.extrinsic4x4,
    required this.intrinsicFxFyCxCy,
    this.imageWidth = 0,
    this.imageHeight = 0,
    this.scaleAlignAnchorCount = 0,
    this.scaleAlignDepthSpanM = 0.0,
    this.scaleAlignReliabilityPrior = 0.0,
    this.isAdjustingFocus = false,
    this.isAdjustingExposure = false,
    this.lensPosition = 0.0,
    this.exposureTargetOffset = 0.0,
    this.quality,
    this.trackingStateName,
    this.previewPoints = const <ARPreviewPoint>[],
  });

  /// Override a subset of fields. Used by [CaptureSession] to build a
  /// "hybrid" effective pose — when ARKit is in `.limited(...)` but IMU
  /// dead-reckoning is anchored, the session substitutes the IMU-derived
  /// az/el and flips `isTracking` back to true so downstream consumers
  /// (dome ingest, dome view) keep operating instead of freezing. The
  /// raw ARKit values stay accessible by listening to the underlying
  /// provider directly; CaptureSession's `poseStream` emits the hybrid.
  ARPose copyWith({double? azimuth, double? elevation, bool? isTracking}) {
    return ARPose(
      position: position,
      orientation: orientation,
      azimuth: azimuth ?? this.azimuth,
      elevation: elevation ?? this.elevation,
      isTracking: isTracking ?? this.isTracking,
      timestamp: timestamp,
      hasOrigin: hasOrigin,
      worldOrigin: worldOrigin,
      worldYaw: worldYaw,
      extrinsic4x4: extrinsic4x4,
      intrinsicFxFyCxCy: intrinsicFxFyCxCy,
      imageWidth: imageWidth,
      imageHeight: imageHeight,
      scaleAlignAnchorCount: scaleAlignAnchorCount,
      scaleAlignDepthSpanM: scaleAlignDepthSpanM,
      scaleAlignReliabilityPrior: scaleAlignReliabilityPrior,
      isAdjustingFocus: isAdjustingFocus,
      isAdjustingExposure: isAdjustingExposure,
      lensPosition: lensPosition,
      exposureTargetOffset: exposureTargetOffset,
      quality: quality,
      previewPoints: previewPoints,
      // Note: deliberately NOT remapping `trackingStateName` from the
      // hybrid `isTracking` boolean. The string is the raw native AR
      // signal from the provider; CaptureSession's IMU-substituted
      // pose still carries the underlying ARKit reason so the drift
      // tracker correctly attributes the degraded window to its
      // root cause (e.g. limited_excessive_motion) rather than to the
      // hybrid resolver's "I forced isTracking back to true" output.
      trackingStateName: trackingStateName,
    );
  }

  /// Convenience factory used by test mocks / synthetic providers
  /// that don't have a real lock origin. Computes az/el from the
  /// camera's forward axis (NOT position).
  static ARPose fromForwardAxis({
    required Vector3 position,
    required Quaternion orientation,
    required double timestamp,
    bool isTracking = true,
  }) {
    final forward = orientation.rotated(Vector3(0, 0, -1));
    final azimuth = math.atan2(forward.x, forward.z);
    final elevation = math.asin(forward.y.clamp(-1.0, 1.0));
    return ARPose(
      position: position,
      orientation: orientation,
      azimuth: azimuth,
      elevation: elevation,
      isTracking: isTracking,
      timestamp: timestamp,
      hasOrigin: false,
      worldOrigin: Vector3.zero(),
      worldYaw: 0,
      extrinsic4x4: const <double>[],
      intrinsicFxFyCxCy: const <double>[],
      // Synthetic / test factory — there is no real AR runtime, so the
      // best the drift tracker can do is "treat as healthy". Matches
      // the mock provider convention.
      trackingStateName: isTracking ? 'normal' : null,
    );
  }
}

/// Result of a successful `lockOrigin` call. Surfaced so the UI can
/// transition from "frame the subject" overlay → "you're locked,
/// orbit now" overlay without waiting for the next pose event.
class ARLockResult {
  final Vector3 worldOrigin;
  final double worldYaw;
  const ARLockResult({required this.worldOrigin, required this.worldYaw});
}

/// Per-frame quality numbers derived from the 128×128 Y-plane
/// thumbnail the AR plugin produces at 6 Hz. Math lives in
/// `lib/quality/quality_compute.dart` (pure Dart, shared across
/// iOS/Android/Web/HarmonyOS); this struct is the result type.
class FrameQualityReport {
  /// Laplacian variance (bigger = sharper).
  final double sharpness;

  /// Sharpness measured in the center region where the subject/crosshair
  /// should live. This is the capture-critical number.
  final double roiSharpness;

  /// Two center-crop sharpness probes used as a cheap multi-scale
  /// consensus until platform bridges ship true 252/512 crops.
  final double multiScaleSharpness252;
  final double multiScaleSharpness512;

  /// Sharpness averaged only over edge-rich blocks. Flat walls and
  /// smooth blown-out regions score low even if global noise is high.
  final double edgeBlockSharpness;

  /// Background/corner sharpness. Used to catch frames where the
  /// background is crisp but the subject/center is out of focus.
  final double backgroundSharpness;

  /// `roiSharpness - backgroundSharpness`.
  final double subjectVsBackgroundSharpnessDelta;

  /// Conservative min/average blend of the sharpness probes in [0..inf].
  final double sharpnessConsensus;

  /// Mean luma 0..255 across the 128² downsample.
  final double meanBrightness;

  /// Pixel-intensity variance across the 128² downsample. Drives the
  /// GuidanceEngine's low-texture (flat-wall) soft downgrade.
  final double globalVariance;

  /// `signatureSide` × `signatureSide` block-mean grayscale thumbnail.
  /// Used by GuidanceEngine for byte-by-byte novelty / similarity.
  final Uint8List signature;
  final int signatureWidth;
  final int signatureHeight;

  const FrameQualityReport({
    required this.sharpness,
    required this.roiSharpness,
    required this.multiScaleSharpness252,
    required this.multiScaleSharpness512,
    required this.edgeBlockSharpness,
    required this.backgroundSharpness,
    required this.subjectVsBackgroundSharpnessDelta,
    required this.sharpnessConsensus,
    required this.meanBrightness,
    required this.globalVariance,
    required this.signature,
    required this.signatureWidth,
    required this.signatureHeight,
  });
}

class HighResolutionStillCapture {
  const HighResolutionStillCapture({
    required this.highresPath,
    required this.previewPath,
    required this.timestamp,
    required this.imageWidth,
    required this.imageHeight,
    required this.cameraTransform,
    required this.intrinsics,
    this.gray128,
    this.gray1024,
    this.captureKind = 'arkit_high_res_still',
    this.poseSyncQuality = 'ar_session_high_res_frame',
    this.trackingStateName,
  });

  final String highresPath;
  final String previewPath;
  final double timestamp;
  final int imageWidth;
  final int imageHeight;
  final List<double> cameraTransform;
  final List<double> intrinsics;
  final Uint8List? gray128;
  final Uint8List? gray1024;
  final String captureKind;
  final String poseSyncQuality;
  final String? trackingStateName;
}

class ARFrameSaveSpec {
  const ARFrameSaveSpec({
    required this.frameID,
    required this.cellIndex,
    required this.slotIndex,
    required this.jpegPath,
    required this.metadataPath,
    this.targetTimestamp,
    this.maxTimestampDelta = 0.18,
    this.quality = 0.9,
    this.schemaVersion = 'aether_arkit_frame_save_spec_v1',
    this.metadataSchemaVersion = 1,
    this.owner = 'Flutter/Dart CaptureSession',
  });

  final String schemaVersion;
  final int metadataSchemaVersion;
  final String owner;
  final String frameID;
  final int cellIndex;
  final int slotIndex;
  final String jpegPath;
  final String metadataPath;
  final double? targetTimestamp;
  final double maxTimestampDelta;
  final double quality;

  String get cellID => '$cellIndex:$slotIndex';

  Map<String, Object?> toJson() => {
    'schema_version': schemaVersion,
    'metadata_schema_version': metadataSchemaVersion,
    'owner': owner,
    'frame_id': frameID,
    'cell_index': cellIndex,
    'slot_index': slotIndex,
    'cell_id': cellID,
    'jpeg_path': jpegPath,
    'metadata_path': metadataPath,
    if (targetTimestamp != null) 'target_timestamp': targetTimestamp,
    'max_timestamp_delta': maxTimestampDelta,
    'jpeg_quality': quality,
    'algorithm_executor_boundary': {
      'schemaVersion': 'aether_algorithm_executor_boundary_v1',
      'hardRule':
          'Dart sealed spec -> thin executor -> Dart report/audit -> next stage',
      'policyOwner': 'Flutter/Dart',
      'executorRole': 'thin_executor_only',
      'dartOwns': [
        'which frames are saved',
        'cell and slot naming',
        'metadata schema version',
        'quality gates and coverage logic',
        'photo bundle handoff',
      ],
      'executorOwns': [
        'ARSession frame access',
        'camera pixel buffer read',
        'JPEG encoding',
        'intrinsics/extrinsics read',
        'tracking state read',
        'rawFeaturePoints / sparse VIO anchor read',
      ],
      'executorMustNotOwn': [
        'coverage acceptance',
        'cell slot routing',
        'photo bundle manifest schema',
        'quality pass/fail decisions',
      ],
    },
  };

  Map<String, Object?> toMethodArgs() => {
    'jpegPath': jpegPath,
    'metadataPath': metadataPath,
    'quality': quality,
    'maxTimestampDelta': maxTimestampDelta,
    if (targetTimestamp != null) 'targetTimestamp': targetTimestamp,
    'metadataSchemaVersion': metadataSchemaVersion,
    'dartSaveContract': toJson(),
  };
}

/// Frame-exact streaming-SfM feed extracted natively alongside the JPEG save:
/// an aspect-preserving grayscale of the SAME ARFrame snapshot plus that
/// frame's intrinsics/extrinsic. This is the input contract for
/// `aether_sfm_add_frame` (row-major top-down 8-bit gray, CGImage
/// convention). Intrinsics are in FULL-resolution pixels ([imageW]x[imageH]);
/// scale them by `grayW / imageW` (uniform — the native extract preserves
/// aspect) before feeding SfM.
class SfmFrameFeed {
  const SfmFrameFeed({
    required this.gray,
    required this.grayW,
    required this.grayH,
    required this.imageW,
    required this.imageH,
    required this.intrinsicFxFyCxCy,
    required this.extrinsic4x4,
    required this.timestamp,
  });

  /// Row-major top-down 8-bit grayscale, [grayW] x [grayH].
  final Uint8List gray;
  final int grayW;
  final int grayH;

  /// Full camera-image dimensions the intrinsics reference.
  final int imageW;
  final int imageH;

  /// ARKit [fx, fy, cx, cy] at full resolution.
  final List<double> intrinsicFxFyCxCy;

  /// Column-major 16-float camera-to-world transform (may be empty when
  /// tracking was degraded at capture time).
  final List<double> extrinsic4x4;

  /// ARFrame timestamp (CACurrentMediaTime seconds).
  final double timestamp;
}

class ARFrameSaveResult {
  const ARFrameSaveResult({
    required this.spec,
    required this.status,
    this.message,
    this.sfmFrame,
  });

  final ARFrameSaveSpec spec;
  final String status;
  final String? message;

  /// Streaming-SfM feed for this exact saved frame; null when the platform
  /// reply carried no grayscale (mock provider, degraded save, non-iOS).
  final SfmFrameFeed? sfmFrame;

  bool get saved => status == 'saved';

  Map<String, Object?> toJson() => {
    'schema_version': 'aether_arkit_frame_save_result_v1',
    'status': status,
    'spec': spec.toJson(),
    if (message != null) 'message': message,
  };
}

abstract class ARPoseProvider {
  /// Start receiving pose updates. Returns a stream that the dome view
  /// subscribes to. Safe to call multiple times — implementations
  /// should be idempotent.
  Stream<ARPose> start();

  /// Snapshot the camera's current pose, place the world origin
  /// `distanceMeters` ahead of the camera's optical axis, capture
  /// `worldYaw` as the bearing at this moment.
  ///
  /// Returns null if the AR session has no current frame to lock
  /// against. Caller should retry after the next pose event.
  Future<ARLockResult?> lockOrigin({double distanceMeters = 1.0});

  /// Plan G W2 photos-on-disk arch: encode the most-recent ARFrame as
  /// a JPEG to `jpegPath` and write per-photo metadata JSON (extrinsic,
  /// intrinsics, sparse anchors, timestamp) to `metadataPath`. Called
  /// by `CaptureSession._onPoseTick` whenever a dome cell admits a
  /// frame to a slot — eviction overwrites both files at the same path.
  ///
  /// `quality` is JPEG q-factor in 0..1 (default 0.9, visually lossless
  /// at 4K, ~700-900 KB per frame). Returns true on success; false if
  /// the platform doesn't support saving frames (mock provider) or the
  /// native encode/write failed.
  ///
  /// Replaces the older `startRecording` / `stopRecording` AVAssetWriter
  /// pipeline — Plan G is fully local, no .mov, no cloud upload.
  Future<bool> saveCurrentFrameAsJpeg({
    required String jpegPath,
    required String metadataPath,
    double? targetTimestamp,
    double maxTimestampDelta = 0.18,
    double quality = 0.9,
  });

  /// Sealed Dart-owned frame-save contract. Prefer this over
  /// [saveCurrentFrameAsJpeg] for new code.
  Future<ARFrameSaveResult> saveCurrentFrame(ARFrameSaveSpec spec);

  /// Capture a platform-native high-resolution still while preserving
  /// synchronized AR pose/intrinsics metadata. Implementations should
  /// write [highresPath] and [previewPath], then return the still ARFrame
  /// metadata. Native may also return a small luma thumbnail; Dart owns
  /// the quality decision.
  Future<HighResolutionStillCapture?> captureHighResolutionStill({
    required String highresPath,
    required String previewPath,
    double? triggerTimestamp,
    double quality = 0.92,
    ARFrameSaveSpec? saveSpec,
  });

  /// Stop the AR session. Does not dispose the provider; a subsequent
  /// `start()` call must work.
  Future<void> stop();

  /// Most recent pose synchronously accessible (null if not started yet).
  ARPose? get lastPose;
}
