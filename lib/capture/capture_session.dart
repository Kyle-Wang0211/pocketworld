// CaptureSession — composes ARPoseProvider + GuidanceEngine +
// DomeCoverageMap into one start/stop unit driven entirely by the AR
// camera buffer. Single-source-of-truth for capture state.
//
// Why we DON'T use the Flutter `camera` plugin's image stream / video
// recording: ARKit on iOS holds exclusive AVCaptureDevice access while
// ARWorldTrackingConfiguration is running. Trying to run a separate
// AVCaptureSession (which is what `camera.startImageStream` needs)
// produces `FigCaptureSourceRemote err=-17281` (server not responding)
// and the image stream silently dies — diagnosed live from a user's
// Xcode console log, see `[CaptureSession] _onCameraImage tick #1`
// only ever firing once. iOS Aether3D's
// `ObjectModeV2CaptureRecorder` reads everything off ARFrame's
// pixel buffer instead; we mirror that.
//
// Data flow:
//   AR backend (Swift ARSession on iOS / synthetic mock elsewhere)
//      │
//      │  per ARFrame, throttled to 6 Hz, native runs Laplacian +
//      │  brightness + signature on `ARFrame.capturedImage`'s Y
//      │  plane and packs it into the pose event.
//      ▼
//   PlatformARPoseProvider → ARPose with optional `quality` block
//      │
//      ▼
//   CaptureSession.poseStream
//      │
//      ├─ guidance.processVisualSample (UI counter + hint text)
//      └─ targetPoints.ingest (visual = data, 1:1: nearest-point
//                              routing → per-point ring buffer +
//                              5-gate v1 promotion → fires
//                              pointVisitedStream when promoted)
//
// Plan G W2 photos-on-disk arch (replaces deleted .mov writer
// 2026-05-16): native broadcast() stashes the latest ARFrame's pixel
// buffer + per-frame metadata in a short timestamp-addressable ring.
// When _onPoseTick admits a frame to a dome cell, we call native
// saveCurrentFrameAsJpeg(path, metadataPath, targetTimestamp) which
// encodes the closest ARFrame snapshot to
// `<photosDir>/cell_<i>_slot_<j>.jpg` + sibling .json. Diversity-
// eviction overwrites the slot's JPEG in place. Capture is fully local
// — no .mov, no cloud upload.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:aether_capture_services/aether_capture_services.dart';
import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:flutter/widgets.dart' show Offset;
import 'package:path_provider/path_provider.dart';

import '../dome/ar_pose.dart';
import '../dome/platform_pose_provider.dart';
import '../quality/frame_quality_constants.dart';
import '../quality/guidance_engine.dart';
import 'captured_photo_catalog.dart';
import 'dome/captured_frame_sample.dart';
import 'dome/dome_config.dart';
import 'dome/dome_target_points.dart';
import 'orientation_tracker.dart';
import 'photo_slot_naming.dart';
import 'pose_drift_tracker.dart';

class CaptureMotionSnapshot {
  final double angularVelocityRadPerSec;
  final double limitRadPerSec;
  final String? trackingStateName;
  final bool tooFast;

  const CaptureMotionSnapshot({
    required this.angularVelocityRadPerSec,
    required this.limitRadPerSec,
    required this.tooFast,
    this.trackingStateName,
  });
}

/// Durable owner for a committed manual-capture frame.
///
/// Returning `true` transfers the frame to a queue that will preserve it until
/// native reconstruction acknowledges it. `false` or an exception is a
/// terminal capture failure; accepted frames are never silently dropped.
typedef ManualSfmFrameSink = FutureOr<bool> Function(SfmFrameFeed feed);

/// Announces whether at least one accepted shutter job is still reserving or
/// publishing its frame-exact JPEG/sidecar/gray bundle.
typedef ManualCaptureActivitySink = void Function(bool active);

/// The three observable stages of one accepted shutter tap.
final class ManualPhotoCapture {
  const ManualPhotoCapture({
    required this.reservation,
    required this.committed,
    required this.completion,
  });

  /// Native snapshot-selection ACK. The shutter returns as soon as this exists.
  final ManualCaptureV2Ticket reservation;

  /// Native terminal publication result for JPEG, sidecar, and SfM gray.
  final Future<ManualCaptureV2Result> committed;

  /// Completes only after publication and durable SfM-queue ownership.
  final Future<void> completion;

  String get captureJobID => reservation.captureJobID;
  String get jpegPath => reservation.jpegPath;
}

/// Terminal failure for one already accepted manual-capture job.
final class ManualPhotoCaptureException implements Exception {
  const ManualPhotoCaptureException({
    required this.captureJobID,
    required this.code,
    required this.message,
    this.cause,
  });

  final String captureJobID;
  final String code;
  final String message;
  final Object? cause;

  @override
  String toString() =>
      'ManualPhotoCaptureException($captureJobID, $code): $message';
}

/// Finish-barrier failure after all accepted jobs reached a terminal state.
final class CapturePhotoSaveBarrierException implements Exception {
  CapturePhotoSaveBarrierException(Iterable<ManualPhotoCaptureException> errors)
    : failures = List<ManualPhotoCaptureException>.unmodifiable(errors);

  final List<ManualPhotoCaptureException> failures;

  @override
  String toString() {
    final jobs = failures
        .map((failure) => '${failure.captureJobID}:${failure.code}')
        .join(', ');
    return 'CapturePhotoSaveBarrierException(${failures.length}): $jobs';
  }
}

class CaptureSession {
  final ARPoseProvider poseProvider;
  final GuidanceEngine guidance;

  /// Sole coverage signal — visual = data, 1:1. Each visible target
  /// point owns its own [RingBufferCell] with v1's strict 5-gate
  /// promotion. Replaced the old [DomeCoverageMap] (60-cell separate
  /// data layer) in v6 — see dome_target_points.dart header.
  final DomeTargetPoints targetPoints;

  /// Where on screen the user is asked to keep the subject. Default is
  /// dead-center because there's no on-screen target box yet.
  final Offset targetZoneAnchor;
  final TargetZoneMode targetZoneMode;

  /// Stream of pose updates the dome view subscribes to.
  Stream<ARPose> get poseStream => _poseCtrl.stream;

  /// Stream of GuidanceEngine snapshots — accepted-frame count, hint
  /// text, orbit-completion fraction.
  Stream<GuidanceSnapshot> get guidanceStream => _guidanceCtrl.stream;

  /// Physical hand-motion health while recording. The UI uses this to ask
  /// the user to slow down before the high-res still path starts falling
  /// behind or ARKit reports excessive motion.
  Stream<CaptureMotionSnapshot> get motionStream => _motionCtrl.stream;

  /// Frame-exact streaming-SfM feeds, one per successfully saved manual
  /// keyframe (gray + intrinsics + extrinsic of the SAME ARFrame the JPEG
  /// came from). The capture page forwards these to SfmLiveRecon; nobody
  /// listening simply means no live reconstruction — the JPEG bundle is
  /// untouched either way.
  Stream<SfmFrameFeed> get sfmFrameStream => _sfmFrameCtrl.stream;

  /// Bind the durable owner of every committed manual SfM frame.
  ///
  /// A frame committed before this binding waits here instead of being lost to
  /// broadcast-stream timing. Rebinding supports replacement of a failed
  /// reconstruction worker.
  void bindManualSfmFrameSink(ManualSfmFrameSink sink) {
    if (_disposed) {
      throw StateError('CaptureSession used after dispose');
    }
    _manualSfmFrameSink = sink;
    if (!_manualSfmSinkReady.isCompleted) {
      _manualSfmSinkReady.complete();
    }
  }

  /// Binds the foreground-priority gate used by the background recon worker.
  /// The current state is delivered immediately so late worker startup cannot
  /// miss publications that were already accepted.
  void bindManualCaptureActivitySink(ManualCaptureActivitySink sink) {
    if (_disposed) {
      throw StateError('CaptureSession used after dispose');
    }
    _manualCaptureActivitySink = sink;
    _notifyManualCaptureActivity(_manualCapturePublicationsInFlight > 0);
  }

  final StreamController<ARPose> _poseCtrl =
      StreamController<ARPose>.broadcast();
  final StreamController<GuidanceSnapshot> _guidanceCtrl =
      StreamController<GuidanceSnapshot>.broadcast();
  final StreamController<CaptureMotionSnapshot> _motionCtrl =
      StreamController<CaptureMotionSnapshot>.broadcast();
  final StreamController<SfmFrameFeed> _sfmFrameCtrl =
      StreamController<SfmFrameFeed>.broadcast();
  StreamSubscription<ARPose>? _poseSub;

  ARPose? _lastPose;

  /// True once `lockOrigin()` has succeeded.
  bool get hasLockedOrigin => _lastPose?.hasOrigin ?? false;

  // Monotonic clock starting from each `start()` so ring-buffer
  // timeSpread checks (excellentMinTimeSpreadSec) work consistently.
  final Stopwatch _clock = Stopwatch();

  /// Wall-clock instant at which the most recent `start()` fired.
  /// Paired with [_clock] so callers can convert a monotonic
  /// [CapturedFrameSample.timestamp] (seconds-since-start) into a
  /// `DateTime` for cross-referencing with wall-clock-stamped events
  /// like SAM mask captureTime. Null before the first start().
  DateTime? _recordingStartedAtWall;
  DateTime? get recordingStartedAt => _recordingStartedAtWall;

  int _frameSeq = 0;
  bool _attached = false;
  bool _started = false;
  bool _disposed = false;
  bool _loggedFirstPose = false;
  bool _loggedFirstHasOrigin = false;
  bool _loggedFirstQuality = false;

  // ── Hybrid ARKit + IMU pose state ────────────────────────────────────
  //
  // Why this exists: ARKit's visual SLAM falls into `.limited(...)` in
  // low-texture / thermal-throttled environments (wood floors, paper
  // bags, hot device). The original capture path treated `isTracking
  // == false` as "skip this frame" (CaptureSession._onPoseTick had
  // `if (!pose.isTracking) return`), which means a long limited window
  // produced ZERO ingested frames — user's "走一圈只点亮 6/118 个点"
  // bug was almost entirely this. The fix:
  //
  //   • Run an OrientationTracker (Madgwick AHRS over phone IMU) in
  //     parallel with ARKit, always-on while attached.
  //   • While ARKit is .normal, record the offset between ARKit's
  //     position-based azimuth/elevation and IMU's yaw/pitch.
  //   • While ARKit is .limited, dead-reckon az/el from IMU + offset.
  //
  // This is correct enough for the dome's coverage classification
  // (which only needs to bin frames into 11×variable rings) — IMU
  // drift over a 30-60 s scan is well under the bin width. It is NOT
  // good enough for reconstruction — but server-side VGGT solves pose
  // from images directly (see arxiv 2503.11651, model.forward(images)
  // takes no pose input), so the manifest ARKit pose was always
  // metadata-only. Each curated frame carries `pose_source` so the
  // server can log the IMU-vs-ARKit ratio.
  final OrientationTracker _orientation = OrientationTracker();
  bool _orientationStarted = false;

  // Plan H'' 2026-05-17: SamLoop / EdgeTAM removed. PocketWorld now follows
  // industry default (Polycam / KIRI / Scaniverse / Luma): include-scene GLB,
  // no in-pipeline mask. BiRefNet lite is retained in the build as a future
  // "一键抠出主体物" tool in the GLB editor (W6+), not invoked here.

  // ── Tier 1 pose-drift health aggregator ──────────────────────────────
  //
  // Listens to the RAW provider trackingStateName (NOT the post-hybrid
  // resolved pose), counts time per bucket + transitions. Snapshot is
  // pulled at stop time and embedded in curated.json so the worker
  // can log/diagnose bad scans post-hoc. Purely diagnostic — no UI
  // surface (dome cell colors already convey real-time AR health).
  final PoseDriftTracker _driftTracker = PoseDriftTracker();

  /// `true` once we've ever seen ARKit `.normal` after the world origin
  /// was locked. Until then the IMU-vs-ARKit offset is undefined and we
  /// fall back to the legacy "skip frame" behaviour rather than
  /// dead-reckon from a meaningless anchor.
  bool _hybridAnchored = false;
  double _arkitImuOffsetAz = 0;
  double _arkitImuOffsetEl = 0;

  /// Last pose's source after hybrid resolution. Sampled into each
  /// CapturedFrameSample so the curator can split the manifest into
  /// arkit-pose vs imu-pose buckets.
  String _lastPoseSource = 'arkit';

  /// When true (RealityScan-style manual capture), [_onPoseTick] skips the
  /// motion/dome auto-ingest + auto-save path; photos are taken only via
  /// [captureSinglePhoto]. Set per-session by [start].
  bool _manualCaptureMode = false;
  // Diagnostics
  int _diagArkitPoses = 0;
  int _diagImuPoses = 0;
  double? _originSettleStartedAtSec;

  // ── IMU→ARKit transition delta-compensation ramp ─────────────────────
  //
  // The first hybrid implementation hard-switched az/el back to the raw
  // ARKit value the moment ARKit returned to .normal. That produced a
  // visible jump on the dome whenever the IMU dead-reckoning had drifted
  // off the ARKit ground truth (which is the common case — IMU is meant
  // to be a coarser substitute, not a perfect tracker). User feedback
  // was unambiguous: "球的角度完全不能发生变化".
  //
  // Continuity proof for the ARKit→IMU direction (no ramp needed):
  //   t=k:   displayed = arkit.az_old
  //          offset    = arkit.az_old - imu.yaw_old           (just refreshed)
  //   t=k+1: tracking dropped → estimated = imu.yaw_new + offset
  //                            = imu.yaw_new + arkit.az_old - imu.yaw_old
  //                            = arkit.az_old + Δimu.yaw  (~0 over 30 ms)
  //          ≈ arkit.az_old → continuous ✓
  //
  // The IMU→ARKit direction is where the jump is. Fix:
  //   • At the moment ARKit recovers, compute
  //         Δ = arkit.az_real − imu_estimated_az_last
  //         (this is the gap that would have caused the jump)
  //   • For the next 600 ms output
  //         az = arkit.az_real − Δ × (1 − t)
  //     where t ramps from 0 (equal to imu_estimated, i.e. the displayed
  //     value at t=k) to 1 (full ARKit). Smooth Hermite t² ⋅ (3 − 2t)
  //     instead of linear so the start and end have zero derivative —
  //     keeps even the rate-of-change continuous.
  //
  // Same logic mirrored for elevation.
  static const Duration _imuToArkitRampDuration = Duration(milliseconds: 600);
  double _switchDeltaAz = 0;
  double _switchDeltaEl = 0;
  DateTime? _switchTransitionStart;

  /// Read-only access to the live audit summary the GuidanceEngine
  /// keeps. Uploaded with the curated manifest at stop time.
  GuidanceAuditSummary get auditSummary => guidance.auditSummary;

  /// Snapshot of pose-drift health since the most recent
  /// [start]/[reset]. Embedded in curated.json so the worker can
  /// diagnose bad scans post-hoc. Safe to call at any time;
  /// [PoseDriftTracker.snapshot] internally closes out the in-flight
  /// bucket so a mid-session call returns "what's been observed so
  /// far". The capture page calls this right before persisting the
  /// manifest at stop-recording.
  PoseDriftReport get poseDriftReport => _driftTracker.snapshot();

  /// Plan G W2 photos-on-disk arch (replaces the deleted .mov writer
  /// 2026-05-16): absolute path to the directory holding cell-admitted
  /// JPEGs and per-photo metadata for this capture session. One file
  /// pair per admitted frame:
  ///
  ///   `<photosDir>/cell_<i>_slot_<j>_<frameId>.jpg`
  ///   `<photosDir>/cell_<i>_slot_<j>_<frameId>.json`
  ///
  /// [2026-07-11 色彩污染修复] 文件名带 frameId,重拍/驱逐同一槽位落
  /// **新文件**而不是同名覆盖:SfM colorize 与 resume 按 fed jsonl 的
  /// jpegPath 取色,覆盖会让先喂入的帧被陈旧内容染色(cap47 16% 点污染)。
  /// 被覆盖度缓存驱逐的旧文件仍是用户照片，必须永久保留；驱逐只影响
  /// 覆盖提示的轻量内存样本，不影响相册、草稿、SfM 或本地重建清单。
  ///
  /// Null until [start] runs; the directory is recreated empty on each
  /// fresh capture session. W3 DA3 inference (待实现) iterates `*.jpg`
  /// here directly — Plan G is fully local, no .mov, no cloud upload.
  String? get photosDir => _photosDir;
  String? _photosDir;
  String? get captureDir => _captureDir;
  String? _captureDir;
  String? get photosHighresDir => _photosHighresDir;
  String? _photosHighresDir;
  String? get previewsDir => _previewsDir;
  String? _previewsDir;
  final ValueNotifier<List<String>> _capturedPhotos =
      ValueNotifier<List<String>>(const <String>[]);

  /// Live, user-owned photo inventory for the current take. Unlike
  /// `targetPoints.retainedJpegPaths`, this list is never reduced by ring-buffer
  /// eviction or reconstruction curation.
  ValueListenable<List<String>> get capturedPhotos => _capturedPhotos;
  List<String> get capturedPhotoPaths => _capturedPhotos.value;

  final List<Future<void>> _pendingPhotoSaves = <Future<void>>[];
  final Map<String, ManualPhotoCaptureException> _manualPhotoFailures =
      <String, ManualPhotoCaptureException>{};
  ManualSfmFrameSink? _manualSfmFrameSink;
  ManualCaptureActivitySink? _manualCaptureActivitySink;
  final Completer<void> _manualSfmSinkReady = Completer<void>();
  Future<void> _manualSfmHandoffTail = Future<void>.value();
  int _manualCapturePublicationsInFlight = 0;
  int _pendingPhotoSaveCount = 0;
  double _lastHighResStillTriggerSec = double.negativeInfinity;
  static const int _maxPendingPhotoSaves = 2;
  static const Duration _minHighResStillInterval = Duration(milliseconds: 250);
  static const int _minScaleAlignAnchorsForPersistedFrame = 8;
  double _photoSaveHealthWindowStartSec = 0;
  int _photoSaveStarted = 0;
  int _photoSaveCompleted = 0;
  int _photoSaveBackpressureSkips = 0;
  int _photoSaveIntervalSkips = 0;
  double _photoSaveLatencyMsSum = 0;
  double _photoSaveLatencyMsMax = 0;
  double _lastMotionEmitSec = double.negativeInfinity;
  bool _lastMotionTooFast = false;
  static const Duration _motionEmitInterval = Duration(milliseconds: 150);
  final PhotoBundleQualityService _photoQuality =
      const PhotoBundleQualityService();
  final PhotoBundleManifestService _photoBundleManifest =
      const PhotoBundleManifestService();
  final Map<String, HighResolutionStillCapture> _stillByPath =
      <String, HighResolutionStillCapture>{};
  final Map<String, PhotoBundleStillQuality> _qualityByPath =
      <String, PhotoBundleStillQuality>{};
  final Map<String, CapturedFrameSample> _sampleByPath =
      <String, CapturedFrameSample>{};

  /// Rebuild the user-owned photo inventory from its durable local source.
  /// Call after the pending-save barrier before persisting a draft.
  Future<List<String>> reconcileCapturedPhotosFromDisk() async {
    final path = _photosHighresDir ?? _photosDir;
    final discovered = path == null
        ? const <String>[]
        : await discoverCapturedPhotoPaths(Directory(path));
    if (!_disposed) _capturedPhotos.value = discovered;
    return discovered;
  }

  /// Updates the live inventory after an explicit user deletion. This only
  /// changes the in-memory view; the caller owns the requested disk deletion.
  void forgetCapturedPhoto(String jpegPath) {
    if (_disposed || !_capturedPhotos.value.contains(jpegPath)) return;
    _capturedPhotos.value = List<String>.unmodifiable(
      _capturedPhotos.value.where((path) => path != jpegPath),
    );
  }

  Future<void> _recordCapturedPhotoIfPresent(String jpegPath) async {
    if (_disposed || _capturedPhotos.value.contains(jpegPath)) return;
    final jpeg = File(jpegPath);
    try {
      if (!await jpeg.exists() || await jpeg.length() <= 0) return;
    } on FileSystemException {
      return;
    }
    if (_disposed || _capturedPhotos.value.contains(jpegPath)) return;
    _capturedPhotos.value = List<String>.unmodifiable(<String>[
      ..._capturedPhotos.value,
      jpegPath,
    ]);
  }

  Future<File?> writePhotoBundleManifest(List<CuratedFrame> curated) async {
    final root = _captureDir;
    if (root == null) return null;
    final curatedByPath = <String, CuratedFrame>{
      for (final frame in curated)
        if (frame.sample.jpegPath != null) frame.sample.jpegPath!: frame,
    };
    final capturedPaths = await reconcileCapturedPhotosFromDisk();
    final frames = <PhotoBundleFrameDraft>[];
    for (final path in capturedPaths) {
      final curatedFrame = curatedByPath[path];
      final sample = _sampleByPath[path] ?? curatedFrame?.sample;
      final still = _stillByPath[path];
      final quality =
          _qualityByPath[path] ??
          (sample == null
              ? const PhotoBundleStillQuality(
                  accepted: true,
                  score: 0,
                  laplacianVariance: 0,
                  meanLuma: 0,
                  underexposedRatio: 0,
                  overexposedRatio: 0,
                  textureCellRatio: 0,
                  rejectReasons: <String>[],
                )
              : _qualityFromSample(sample));
      Map<dynamic, dynamic> metadata = const <dynamic, dynamic>{};
      try {
        final sidecarPath = path.replaceFirst(RegExp(r'\.[^.]+$'), '.json');
        final decoded = jsonDecode(await File(sidecarPath).readAsString());
        if (decoded is Map) metadata = decoded;
      } catch (_) {}
      final contractRaw = metadata['dart_save_contract'];
      final contract = contractRaw is Map
          ? contractRaw
          : const <dynamic, dynamic>{};
      final highresFilename = _basename(path);
      final derivedPreviewPath = path.replaceFirst(
        '/photos_highres/',
        '/previews/',
      );
      final previewPath =
          still?.previewPath ??
          (File(derivedPreviewPath).existsSync() ? derivedPreviewPath : null);
      final sidecarTimestamp = _jsonDouble(metadata['t'], double.nan);
      final triggerTimestamp = _jsonDouble(
        contract['target_timestamp'],
        sample?.timestamp ?? (sidecarTimestamp.isFinite ? sidecarTimestamp : 0),
      );
      final frameID =
          sample?.frameId ??
          _jsonString(contract['frame_id']) ??
          highresFilename.replaceFirst(RegExp(r'\.[^.]+$'), '');
      frames.add(
        PhotoBundleFrameDraft(
          id: frameID,
          highresFilename: highresFilename,
          previewFilename: previewPath == null
              ? highresFilename
              : _basename(previewPath),
          timestamp:
              still?.timestamp ??
              (sidecarTimestamp.isFinite
                  ? sidecarTimestamp
                  : sample?.timestamp ?? 0),
          triggerTimestamp: triggerTimestamp,
          azimuth: sample?.azimuth ?? 0,
          elevation: sample?.elevation ?? 0,
          captureKind:
              still?.captureKind ??
              (_jsonString(metadata['manual_capture_schema']) == null
                  ? 'arkit_frame_snapshot'
                  : 'manual_capture_v2'),
          poseSyncQuality: still?.poseSyncQuality ?? 'ar_session_frame',
          imageWidth: still?.imageWidth ?? _jsonInt(metadata['image_w']),
          imageHeight: still?.imageHeight ?? _jsonInt(metadata['image_h']),
          quality: quality,
          cameraTransform:
              still?.cameraTransform ??
              sample?.cameraExtrinsic4x4 ??
              _jsonDoubleList(metadata['extrinsic']),
          intrinsics:
              still?.intrinsics ??
              sample?.cameraIntrinsicFxFyCxCy ??
              _jsonDoubleList(metadata['intrinsics_fxfycxcy']),
          cameraRadiusM: sample?.cameraRadiusM,
          radiusShellID: curatedFrame == null
              ? null
              : '${curatedFrame.radiusShellId}',
          poseSource: sample?.poseSource ?? 'arkit',
          focusStable: sample?.focusStable,
          trackingState:
              still?.trackingStateName ??
              sample?.trackingStateName ??
              _jsonString(
                metadata['trackingStateName'] ?? metadata['tracking_state'],
              ),
          cellID:
              _jsonString(contract['cell_id']) ??
              (curatedFrame == null
                  ? null
                  : '${curatedFrame.azBin}:${curatedFrame.elBin}'),
        ),
      );
    }
    await _photoBundleManifest.writeManifest(
      bundleDirectory: Directory(root),
      frames: frames,
      sourceKind: 'flutter_high_res_still',
      extra: const <String, Object?>{
        'processingTier': 'high',
        'photoBundleOwner': 'flutter_dart',
      },
    );
    return File('$root/photo_bundle.json');
  }

  PhotoBundleStillQuality _qualityFromSample(CapturedFrameSample sample) {
    final blurScore = ((sample.sharpness - 200.0) / 700.0)
        .clamp(0.0, 1.0)
        .toDouble();
    final exposureScore = sample.exposureScore.clamp(0.0, 1.0).toDouble();
    final textureScore = sample.subjectFootprintRatio
        .clamp(0.0, 1.0)
        .toDouble();
    final score =
        (0.50 * blurScore + 0.35 * exposureScore + 0.15 * textureScore)
            .clamp(0.0, 1.0)
            .toDouble();
    return PhotoBundleStillQuality(
      accepted: true,
      score: score,
      laplacianVariance: sample.sharpness,
      meanLuma: sample.meanBrightness,
      underexposedRatio: sample.meanBrightness < 60 ? 1 : 0,
      overexposedRatio: sample.meanBrightness > 200 ? 1 : 0,
      textureCellRatio: sample.subjectFootprintRatio,
      rejectReasons: const <String>[],
    );
  }

  PhotoBundleStillQuality _evaluateReturnedStill(
    HighResolutionStillCapture still,
    CapturedFrameSample sample,
  ) {
    final gray1024 = still.gray1024;
    if (gray1024 != null && gray1024.length == 1024 * 1024) {
      return _photoQuality.evaluateLumaPlane(
        luma: gray1024,
        width: 1024,
        height: 1024,
        rowStride: 1024,
      );
    }
    final gray = still.gray128;
    if (gray != null && gray.length == 128 * 128) {
      return _photoQuality.evaluateLumaPlane(
        luma: gray,
        width: 128,
        height: 128,
        rowStride: 128,
      );
    }
    return _qualityFromSample(sample);
  }

  static String _basename(String path) {
    return path.split(Platform.pathSeparator).last;
  }

  CaptureSession({
    ARPoseProvider? poseProvider,
    GuidanceEngine? guidance,
    DomeTargetPoints? targetPoints,
    DomePointConfig pointConfig = DomePointConfig.defaults,
    this.targetZoneAnchor = const Offset(0.5, 0.5),
    this.targetZoneMode = TargetZoneMode.subject,
  }) : poseProvider = poseProvider ?? PlatformARPoseProvider(),
       guidance = guidance ?? GuidanceEngine(),
       targetPoints = targetPoints ?? DomeTargetPoints(config: pointConfig) {
    this.guidance.onUpdate = (snap) {
      if (!_guidanceCtrl.isClosed) _guidanceCtrl.add(snap);
    };
  }

  bool get isRunning => _started;
  bool get isAttached => _attached;

  /// Pre-warm the AR session: start the platform pose provider so
  /// ARKit's tracking can settle into `.normal` while the user frames
  /// the subject. Does NOT begin recording — `_onPoseTick` ignores
  /// events until `start()` flips `_started = true`. Idempotent.
  ///
  /// Why this is split from `start()`: lockOrigin needs `tracking ==
  /// .normal` to succeed. If we cold-start ARKit on Record tap, the
  /// retry loop fires lockOrigin during the warm-up window — the user
  /// was visibly moving the phone while ARKit raced to `.normal`,
  /// so the captured worldYaw was meaningless. Pre-warming on page
  /// open lets tracking stabilize so the lock baseline reflects the
  /// pose the user actually wanted to anchor to.
  Future<void> attach() async {
    if (_disposed) {
      throw StateError('CaptureSession used after dispose');
    }
    if (_attached) return;
    _attached = true;

    // Start the IMU stream alongside ARKit. OrientationTracker is safe
    // to start even when sensor APIs aren't available (sensors_plus
    // streams just stay silent on simulator/web) — `current.yaw/pitch`
    // will sit at 0 and the hybrid path will degrade to the legacy
    // "skip ARKit-limited frames" behaviour.
    if (!_orientationStarted) {
      _orientation.start();
      _orientationStarted = true;
    }

    _poseSub = poseProvider.start().listen((rawPose) {
      // Feed the RAW pose to the drift tracker BEFORE hybrid
      // resolution. The drift tracker wants the underlying ARKit
      // truth (limited_excessive_motion, etc.), not the hybrid
      // resolver's "I forced isTracking back to true" output —
      // otherwise the diagnostic would always read "100% healthy"
      // because IMU dead-reckoning paints over the underlying issue.
      // Only feed events while a recording is active; the warm-up
      // period before `start()` doesn't count toward session health.
      if (_started) {
        _driftTracker.onPose(rawPose);
      }

      if (!_loggedFirstPose) {
        _loggedFirstPose = true;
        // ignore: avoid_print
        print(
          '[CaptureSession] first ARPose received '
          '(isTracking=${rawPose.isTracking}, '
          'hasOrigin=${rawPose.hasOrigin})',
        );
      }
      if (!_loggedFirstHasOrigin && rawPose.hasOrigin) {
        _loggedFirstHasOrigin = true;
        // ignore: avoid_print
        print(
          '[CaptureSession] first ARPose with hasOrigin=true — '
          'dome ingest path now active',
        );
      }
      if (!_loggedFirstQuality && rawPose.quality != null) {
        _loggedFirstQuality = true;
        // ignore: avoid_print
        print(
          '[CaptureSession] first quality block received '
          '(sharp=${rawPose.quality!.sharpness.toStringAsFixed(0)}, '
          'brightness=${rawPose.quality!.meanBrightness.toStringAsFixed(0)})',
        );
      }

      // Resolve hybrid pose. Subscribers (dome view, ingest pipeline)
      // see the resolved pose, never the raw ARPose. The raw pose can
      // still be inspected via `lastRawArkitPose` if a future caller
      // wants to surface "ARKit is limited" specifically.
      final p = _resolveHybridPose(rawPose);
      _lastPose = p;
      if (!_poseCtrl.isClosed) _poseCtrl.add(p);
      _emitMotionSnapshot(p);
      _onPoseTick(p);
    });
  }

  /// Hybrid pose resolution. Returns either:
  ///   • [raw] verbatim — ARKit `.normal`, or pre-lock, or
  ///     post-lock-but-pre-anchor ARKit limited (no IMU offset to apply
  ///     yet, so we leave isTracking=false and the legacy gate skips).
  ///   • A copy with IMU-derived az/el and isTracking=true — ARKit was
  ///     `.limited(...)` but we have a recent ARKit-normal anchor for
  ///     the offset.
  ///
  /// Side effects: refreshes `_arkitImuOffsetAz/El` whenever ARKit is
  /// healthy, and updates `_lastPoseSource` for ingest tagging.
  ARPose _resolveHybridPose(ARPose raw) {
    if (!raw.hasOrigin) {
      // Pre-lock: there's no world frame to compare against; the dome
      // ingest pipeline already filters on hasOrigin so the source tag
      // doesn't matter.
      _lastPoseSource = 'arkit';
      return raw;
    }

    if (raw.isTracking) {
      // ARKit healthy.
      final imu = _orientation.current;

      // ── Detect IMU→ARKit transition; arm the delta-compensation ramp
      // BEFORE refreshing offset, so the "imu_estimated_az_last" we
      // compute uses the offset that produced the previous frame's
      // displayed value (continuity at t=k vs t=k+1).
      if (_lastPoseSource == 'imu' && _hybridAnchored) {
        final imuEstimatedAz = imu.yaw + _arkitImuOffsetAz;
        final imuEstimatedEl = imu.pitch + _arkitImuOffsetEl;
        _switchDeltaAz = raw.azimuth - imuEstimatedAz;
        _switchDeltaEl = raw.elevation - imuEstimatedEl;
        _switchTransitionStart = DateTime.now();
        // ignore: avoid_print
        print(
          '[CaptureSession] IMU→ARKit transition: '
          'Δaz=${_switchDeltaAz.toStringAsFixed(3)} '
          'Δel=${_switchDeltaEl.toStringAsFixed(3)} — '
          'will ramp over ${_imuToArkitRampDuration.inMilliseconds}ms',
        );
      }

      // Refresh offset (always do this in steady-state ARKit; future
      // ARKit→IMU transitions need the most recent offset).
      _arkitImuOffsetAz = raw.azimuth - imu.yaw;
      _arkitImuOffsetEl = raw.elevation - imu.pitch;
      if (!_hybridAnchored) {
        _hybridAnchored = true;
        // ignore: avoid_print
        print(
          '[CaptureSession] hybrid anchor established — '
          'IMU dead-reckoning ready as fallback '
          '(arkit.az=${raw.azimuth.toStringAsFixed(2)} '
          'imu.yaw=${imu.yaw.toStringAsFixed(2)})',
        );
      }
      _lastPoseSource = 'arkit';
      _diagArkitPoses++;

      // ── Apply delta-compensation ramp if we're in the post-transition
      // window. Smoothstep (Hermite) interpolation t² × (3 − 2t) so the
      // velocity at t=0 and t=1 is zero — no derivative discontinuity.
      if (_switchTransitionStart != null) {
        final elapsedMs = DateTime.now()
            .difference(_switchTransitionStart!)
            .inMilliseconds;
        final tLin = (elapsedMs / _imuToArkitRampDuration.inMilliseconds).clamp(
          0.0,
          1.0,
        );
        if (tLin >= 1.0) {
          // Ramp complete — snap to direct ARKit values for the rest of
          // this normal window.
          _switchTransitionStart = null;
          _switchDeltaAz = 0;
          _switchDeltaEl = 0;
          return raw;
        }
        final t = tLin * tLin * (3.0 - 2.0 * tLin); // smoothstep
        final adjAz = raw.azimuth - _switchDeltaAz * (1.0 - t);
        final adjEl = raw.elevation - _switchDeltaEl * (1.0 - t);
        return raw.copyWith(azimuth: adjAz, elevation: adjEl);
      }

      return raw;
    }

    // ARKit .limited(...) — substitute IMU dead-reckoning if anchored.
    if (_hybridAnchored) {
      // If we were mid-ramp from a previous IMU→ARKit transition and
      // ARKit drops again immediately, abandon the ramp — use the
      // current (possibly stale) offset for continuity rather than
      // bouncing back to a half-rampped value.
      _switchTransitionStart = null;
      _switchDeltaAz = 0;
      _switchDeltaEl = 0;

      final imu = _orientation.current;
      _lastPoseSource = 'imu';
      _diagImuPoses++;
      return raw.copyWith(
        azimuth: imu.yaw + _arkitImuOffsetAz,
        elevation: imu.pitch + _arkitImuOffsetEl,
        // Flip back to "tracking" so downstream consumers (dome view,
        // ingest pipeline) treat the IMU pose as usable. The raw value
        // is preserved on the underlying provider for callers that
        // really want to know ARKit is unhappy.
        isTracking: true,
      );
    }

    // Post-lock, ARKit limited, no IMU anchor yet — pass through with
    // isTracking=false. _onPoseTick still has its legacy gate to skip.
    _lastPoseSource = 'arkit';
    return raw;
  }

  /// Begin a new capture. Resets target points + clock and kicks off
  /// the native video recording.
  ///
  /// **autoLock**:
  ///   - `true` (default, legacy behavior): also kicks off the
  ///     `_lockOriginWhenReady` retry loop. Used when the caller wants
  ///     "tap record → everything happens automatically".
  ///   - `false` (v6+ aim-then-lock UX): caller is responsible for
  ///     invoking [lockOrigin] explicitly (typically when the user
  ///     taps a "lock" button after aiming the crosshair). Without
  ///     this, target points never see any frame with `hasOrigin`.
  Future<void> start({bool autoLock = true, bool manualCapture = false}) async {
    if (_disposed) {
      throw StateError('CaptureSession used after dispose');
    }
    if (_started) return;
    if (!_attached) await attach();

    targetPoints.reset();
    guidance.beginRecording();
    _driftTracker.reset();
    _frameSeq = 0;
    _manualCaptureMode = manualCapture;
    _pendingPhotoSaves.clear();
    _manualPhotoFailures.clear();
    _manualSfmHandoffTail = Future<void>.value();
    _manualCapturePublicationsInFlight = 0;
    _notifyManualCaptureActivity(false);
    _pendingPhotoSaveCount = 0;
    _lastHighResStillTriggerSec = double.negativeInfinity;
    _resetPhotoSaveHealth();
    _lastMotionEmitSec = double.negativeInfinity;
    _lastMotionTooFast = false;
    _stillByPath.clear();
    _qualityByPath.clear();
    _sampleByPath.clear();
    _capturedPhotos.value = const <String>[];
    _diagArkitPoses = 0;
    _diagImuPoses = 0;
    _originSettleStartedAtSec = null;
    // Plan G W2 photos-on-disk: prepare a fresh directory for this
    // capture's cell-admitted JPEGs. Wiped + recreated each start so a
    // stale prior session can't leak into the new cells.
    await _setupPhotosDirectory();
    // Clear hybrid anchor: a new recording means a new world origin
    // is about to be locked, so any IMU↔ARKit offset learned from
    // the previous session is stale.
    _hybridAnchored = false;
    _arkitImuOffsetAz = 0;
    _arkitImuOffsetEl = 0;
    _orientation.resetOrigin();
    _clock
      ..reset()
      ..start();
    _recordingStartedAtWall = DateTime.now();

    // Phase B SAM loop: clear last session's masks, install the
    // Plan H'' 2026-05-17: SamLoop removed. GLB pipeline is include-scene
    // by default (industry convention). Subject extraction is a future
    // post-export tool, not part of capture-during runtime.

    _started = true;

    if (autoLock) {
      unawaited(_lockOriginWhenReady(distanceMeters: 1.0));
    }
  }

  /// Build (or wipe + recreate) `<docs>/captures/<captureId>/photos/`
  /// for this session's cell-admitted JPEGs. Call once per [start];
  /// the resulting path is exposed via [photosDir].
  Future<void> _setupPhotosDirectory() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final captureId = 'cap_${DateTime.now().microsecondsSinceEpoch}';
      final root = Directory('${docs.path}/captures/$captureId');
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
      final highres = Directory('${root.path}/photos_highres');
      final previews = Directory('${root.path}/previews');
      await highres.create(recursive: true);
      await previews.create(recursive: true);
      _captureDir = root.path;
      _photosDir = highres.path;
      _photosHighresDir = highres.path;
      _previewsDir = previews.path;
      // ignore: avoid_print
      print('[CaptureSession] photo bundle dir: $_captureDir');
    } catch (e) {
      // ignore: avoid_print
      print('[CaptureSession] photos dir setup failed: $e');
      _captureDir = null;
      _photosDir = null;
      _photosHighresDir = null;
      _previewsDir = null;
    }
  }

  /// Place the world origin in front of the camera and capture
  /// worldYaw. Default 1.0 m matches the typical "stand 1-1.5 m from
  /// the subject" capture posture (chair, paper bag, figurine on a
  /// desk). iOS Aether3D's original 0.5 m was tuned for close-up
  /// handheld figurines; with the wider 1.0 m default + Swift-side
  /// raycast distance cap (1.5 m) the world origin ends up on the
  /// subject for the typical PocketWorld shoot.
  Future<ARLockResult?> lockOrigin({double distanceMeters = 1.0}) {
    return poseProvider.lockOrigin(distanceMeters: distanceMeters);
  }

  Future<void> _lockOriginWhenReady({required double distanceMeters}) async {
    // Keep retrying as long as recording is active and we haven't locked
    // yet. The previous 50-attempt (5 s) cap was a bug: in low-texture
    // scenes (transparent / reflective subjects, smooth desks) ARKit
    // takes >5 s to leave `.limited(initializing)`, and once we gave up,
    // recording continued forever with `hasOrigin=false` — no coverage
    // ingest, no dome rotation, blank dark grid for the rest of the take.
    // Now we wait for ARKit to be ready however long that takes; the
    // user's stop-recording tap is the actual upper bound.
    int attempts = 0;
    while (_started) {
      attempts++;
      final result = await poseProvider.lockOrigin(
        distanceMeters: distanceMeters,
      );
      if (result != null) {
        // ignore: avoid_print
        print(
          '[CaptureSession] lockOrigin SUCCESS on attempt $attempts '
          '(worldYaw=${result.worldYaw.toStringAsFixed(3)})',
        );
        return;
      }
      // Progress log at 1 s, 5 s, then once per 5 s — so the user (and
      // we, reading the trace) can see the loop is still alive without
      // spamming the console at 10 Hz.
      if (attempts == 10 || attempts == 50 || attempts % 50 == 0) {
        // ignore: avoid_print
        print(
          '[CaptureSession] lockOrigin still pending after $attempts '
          'attempts (${attempts * 100} ms) — ARKit tracking not yet '
          '.normal; will keep retrying',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    // Loop only exits when `_started` flips false — i.e., the user
    // stopped recording before ARKit ever stabilised.
    // ignore: avoid_print
    print(
      '[CaptureSession] lockOrigin abandoned: recording stopped after '
      '$attempts attempts before ARKit reached .normal tracking',
    );
  }

  /// End the recording window. Keeps the pose provider running so the
  /// user can tap Record again without paying ARKit's warm-up cost.
  /// Tear-down of the AR session happens in `dispose()` when the
  /// capture page is destroyed.
  Future<void> stop() async {
    if (!_started) return;
    _started = false;
    _clock.stop();
    guidance.endRecording();
    final imuRatio = (_diagArkitPoses + _diagImuPoses) == 0
        ? 0.0
        : _diagImuPoses / (_diagArkitPoses + _diagImuPoses);
    // ignore: avoid_print
    print(
      '[CaptureSession] hybrid pose stats this take: '
      'arkit=$_diagArkitPoses imu=$_diagImuPoses '
      '(${(imuRatio * 100).toStringAsFixed(1)}% IMU dead-reckoned)',
    );
    // Plan G W2 photos-on-disk: stop just freezes the dome state and
    // prints the retained-photo count. JPEGs were written incrementally
    // during _onPoseTick on each cell admit, with diversity-eviction
    // overwriting in place; the photos dir is the canonical output.
    final retained = targetPoints.retainedJpegPaths;
    // ignore: avoid_print
    print(
      '[CaptureSession] capture stopped: $_photosDir '
      '(${retained.length} cell-retained photos)',
    );
    _logPhotoSaveHealthIfNeeded(
      _clock.elapsedMicroseconds / 1000000.0,
      force: true,
    );

    // Plan H'' 2026-05-17: BiRefNet NO LONGER in main capture→GLB pipeline.
    // Industry convention (Polycam/KIRI/Scaniverse/Luma default OFF) is
    // include-scene GLB; user trims to subject in 二创 editor if desired.
    // Asymmetric error cost: extra geometry → delete (cheap); missing
    // geometry → reshoot (expensive). PocketWorld follows industry default.
    //
    // BiRefNet lite mlpackage + Wrapper + native runBiRefNetOnJpeg handler
    // are RETAINED in the build for a future "一键抠出主体物" tool in the
    // GLB editor (W6+). They are not invoked during capture-after flow.
  }

  Future<void> waitForPendingPhotoSaves({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    // Kept as a source-compatible named argument while callers migrate. It is
    // deliberately ignored: Finish must never pass an accepted job by timing
    // out. Loop so reservations published while the barrier is waiting are
    // included as well.
    while (_pendingPhotoSaves.isNotEmpty) {
      final pending = _pendingPhotoSaves.toList(growable: false);
      await Future.wait(pending);
      _pendingPhotoSaves.removeWhere(pending.contains);
    }

    if (_manualPhotoFailures.isNotEmpty) {
      throw CapturePhotoSaveBarrierException(_manualPhotoFailures.values);
    }
  }

  /// Stop the in-flight take and discard its local photo bundle directory.
  ///
  /// This is intentionally separate from [stop] + `writePhotoBundleManifest`:
  /// the capture-page X button uses it for "退出并丢弃", so no
  /// `photo_bundle.json` is written and no Draft/ScanRecord is created.
  Future<void> discardCurrentCapture({
    Duration pendingSaveTimeout = const Duration(seconds: 3),
  }) async {
    if (_started) {
      await stop();
    }
    await waitForPendingPhotoSaves(timeout: pendingSaveTimeout);

    final dirPath = _captureDir;
    targetPoints.reset();
    _pendingPhotoSaves.clear();
    _pendingPhotoSaveCount = 0;
    _lastHighResStillTriggerSec = double.negativeInfinity;
    _resetPhotoSaveHealth();
    _lastMotionEmitSec = double.negativeInfinity;
    _lastMotionTooFast = false;
    _stillByPath.clear();
    _qualityByPath.clear();
    _sampleByPath.clear();
    _capturedPhotos.value = const <String>[];
    _photosDir = null;
    _photosHighresDir = null;
    _previewsDir = null;
    _captureDir = null;

    if (dirPath == null) return;
    final dir = Directory(dirPath);
    if (!await dir.exists()) return;
    try {
      await dir.delete(recursive: true);
    } on FileSystemException catch (e) {
      // Best effort: a native high-res encode can still be closing its file.
      // No Draft record points at this directory, so failure here cannot make
      // discarded material visible to the user.
      // ignore: avoid_print
      print('[CaptureSession] discard delete skipped: ${e.message}');
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (_started) {
      _started = false;
      _clock.stop();
      guidance.endRecording();
    }
    await _poseSub?.cancel();
    _poseSub = null;
    if (_attached) {
      _attached = false;
      await poseProvider.stop();
    }
    if (_orientationStarted) {
      _orientation.dispose();
      _orientationStarted = false;
    }
    if (!_poseCtrl.isClosed) await _poseCtrl.close();
    if (!_guidanceCtrl.isClosed) await _guidanceCtrl.close();
    if (!_motionCtrl.isClosed) await _motionCtrl.close();
    if (!_sfmFrameCtrl.isClosed) await _sfmFrameCtrl.close();
    _capturedPhotos.dispose();
  }

  // ─── Per-pose ingest ────────────────────────────────────────────────

  void _emitMotionSnapshot(ARPose pose) {
    if (!_started || !pose.hasOrigin) return;
    final t = _clock.elapsedMicroseconds / 1e6;
    final limit = targetPoints.thresholds.maxAngularRateRadPerSec;
    final angular = _orientation.angularVelocityRadPerSec;
    final excessiveMotion =
        pose.trackingStateName == 'limited_excessive_motion';

    var tooFast = excessiveMotion || angular > limit;
    if (_lastMotionTooFast && !excessiveMotion) {
      // Hysteresis: once the warning is visible, keep it on until the
      // hand has clearly slowed down. This avoids a flickering pill near
      // the exact threshold.
      tooFast = angular > limit * 0.8;
    }

    final minIntervalSec = _motionEmitInterval.inMilliseconds / 1000.0;
    if (tooFast == _lastMotionTooFast &&
        t - _lastMotionEmitSec < minIntervalSec) {
      return;
    }
    _lastMotionTooFast = tooFast;
    _lastMotionEmitSec = t;
    if (!_motionCtrl.isClosed) {
      _motionCtrl.add(
        CaptureMotionSnapshot(
          angularVelocityRadPerSec: angular,
          limitRadPerSec: limit,
          trackingStateName: pose.trackingStateName,
          tooFast: tooFast,
        ),
      );
    }
  }

  /// Drive GuidanceEngine + DomeCoverageMap from each pose event that
  /// carries a quality block. Native side throttles those to 6 Hz so
  /// we get exactly one ingest per ~167 ms — same as iOS's
  /// `visualSampleInterval`.
  void _onPoseTick(ARPose pose) {
    if (!_started) return;
    final report = pose.quality;
    if (report == null) return; // throttled-out frame, no quality data
    if (!pose.hasOrigin) return;
    // NOTE: we do NOT bail on `!pose.isTracking` anymore. The hybrid
    // resolver in attach() flips isTracking back to true whenever IMU
    // dead-reckoning is anchored, so the only `isTracking=false` that
    // reaches us here is the post-lock-but-pre-anchor window where
    // ARKit is .limited AND we don't have a valid IMU offset yet — in
    // which case az/el are stale and we should still skip.
    if (!pose.isTracking) return;

    final t = _clock.elapsedMicroseconds / 1e6;
    _originSettleStartedAtSec ??= t;
    if (t - _originSettleStartedAtSec! <
        targetPoints.thresholds.originSettleSeconds) {
      return;
    }

    // GuidanceEngine — verbatim port of iOS Aether3D's multi-dim audit
    // (blur / dark / bright / occupancy / redundant / low-texture /
    // weak-quality / dynamic acceptance threshold / dark-adaptive
    // sharpness floor / 0.28 s throttle / first-frame special case).
    // Snapshot the acceptance count before/after so we can detect
    // "this exact frame was accepted" → use it to gate target_points.
    final beforeAccepted = guidance.snapshot.acceptedFrames;
    guidance.processVisualSample(
      VisualFrameSample(
        timestamp: t,
        signatureWidth: report.signatureWidth,
        signatureHeight: report.signatureHeight,
        signature: report.signature,
        laplacianVariance: report.sharpness,
        meanBrightness: report.meanBrightness,
        globalVariance: report.globalVariance,
      ),
      targetZoneAnchor: targetZoneAnchor,
      targetZoneMode: targetZoneMode,
    );
    final wasAccepted = guidance.snapshot.acceptedFrames > beforeAccepted;

    // TargetPoints — visual = data, 1:1. Ingest routes the frame to
    // the nearest target point; that point's own ring buffer +
    // 5-gate promotion will fire `pointVisitedStream` when the point
    // newly transitions to ok. `wasAccepted` is logged for diagnostic
    // (it's GuidanceEngine's verdict on whether this frame was
    // "accepted"; target_points uses its own simpler sharpness floor
    // so the two can disagree — a frame may be guidance-rejected but
    // sharp enough to be ingested into a buffer).
    _frameSeq++;
    if (_frameSeq == 1 || _frameSeq % 6 == 0) {
      // ignore: avoid_print
      print(
        '[CaptureSession] targetPoints.ingest #$_frameSeq '
        'az=${pose.azimuth.toStringAsFixed(2)} '
        'el=${pose.elevation.toStringAsFixed(2)} '
        'sharp=${report.sharpness.toStringAsFixed(0)} '
        'src=$_lastPoseSource '
        'accepted=$wasAccepted',
      );
    }
    // Manual (RealityScan-style) capture: the shutter — not a motion/dome
    // gate — decides when to shoot. Skip the auto-ingest + auto-save path
    // entirely; the live preview points + guidance toasts above still run.
    if (_manualCaptureMode) return;

    // motionScore: when ARKit is reporting we use the legacy default
    // (no IMU read on the ARKit path of iOS Aether3D either); when we're
    // dead-reckoning from IMU, the OrientationTracker has the gyro RMS
    // already computed and that's a strictly better signal — surface it
    // so the coverage map's motion-stability gate sees real data.
    final motionScore = _lastPoseSource == 'imu'
        ? _orientation.current.motionScore
        : 0.2;
    // ARKit extrinsic/intrinsic are meaningless when the pose source is
    // IMU-only (camera→world matrix would be from a frame ARKit had
    // already abandoned). Drop them so the manifest doesn't ship stale
    // pose data tagged as ARKit ground truth.
    final extrinsic = _lastPoseSource == 'arkit' && pose.extrinsic4x4.isNotEmpty
        ? pose.extrinsic4x4
        : null;
    final intrinsic =
        _lastPoseSource == 'arkit' && pose.intrinsicFxFyCxCy.isNotEmpty
        ? pose.intrinsicFxFyCxCy
        : null;
    final arMetadataReady =
        _lastPoseSource == 'arkit' &&
        pose.trackingStateName == 'normal' &&
        extrinsic != null &&
        extrinsic.length == 16 &&
        intrinsic != null &&
        intrinsic.length >= 4 &&
        pose.scaleAlignAnchorCount >= _minScaleAlignAnchorsForPersistedFrame;
    if (!arMetadataReady) {
      if (_frameSeq == 1 || _frameSeq % 6 == 0) {
        // ignore: avoid_print
        print(
          '[CaptureSession] skip persist: incomplete AR metric metadata '
          'src=$_lastPoseSource tracking=${pose.trackingStateName ?? 'null'} '
          'extrinsic=${extrinsic?.length ?? 0} '
          'intrinsics=${intrinsic?.length ?? 0} '
          'anchors=${pose.scaleAlignAnchorCount}',
        );
      }
      return;
    }
    final cameraRadiusM = pose.position.distanceTo(pose.worldOrigin);
    final exposureScore = _computeExposureScore(
      meanBrightness: report.meanBrightness,
      exposureTargetOffset: pose.exposureTargetOffset,
      isAdjustingExposure: pose.isAdjustingExposure,
    );
    final focusStable =
        !pose.isAdjustingFocus &&
        !pose.isAdjustingExposure &&
        pose.exposureTargetOffset.abs() < 1.25;
    final sample = CapturedFrameSample(
      timestamp: t,
      azimuth: pose.azimuth,
      elevation: pose.elevation,
      sharpness: report.sharpness,
      cameraRadiusM: cameraRadiusM,
      subjectFootprintRatio: _estimateSubjectFootprintRatio(
        pose,
        cameraRadiusM,
      ),
      roiSharpness: report.roiSharpness,
      multiScaleSharpness252: report.multiScaleSharpness252,
      multiScaleSharpness512: report.multiScaleSharpness512,
      edgeBlockSharpness: report.edgeBlockSharpness,
      subjectVsBackgroundSharpnessDelta:
          report.subjectVsBackgroundSharpnessDelta,
      sharpnessConsensus: report.sharpnessConsensus,
      motionScore: motionScore,
      // Forward physical-units gyro magnitude so the dome ingest gate
      // can hard-reject frames captured during > 2 rad/s hand wobble
      // (Aether3D iOS angularVelocityLimit). _orientation always has
      // an EMA-smoothed value once IMU events have started flowing;
      // before then, the default 0.0 in CapturedFrameSample passes.
      angularVelocityRadPerSec: _orientation.angularVelocityRadPerSec,
      // Mean luma 0..255. Same value `report.meanBrightness` carries to
      // logging — exposing it on the sample lets the dome ingest gate
      // hard-reject too-dark / blown-out frames (Aether3D iOS thresholds
      // 60 / 200) before they ever enter a cell buffer.
      meanBrightness: report.meanBrightness,
      exposureScore: exposureScore,
      frameId: 'cap-$_frameSeq',
      cameraExtrinsic4x4: extrinsic,
      cameraIntrinsicFxFyCxCy: intrinsic,
      scaleAlignAnchorCount: pose.scaleAlignAnchorCount,
      scaleAlignDepthSpanM: pose.scaleAlignDepthSpanM,
      scaleAlignReliabilityPrior: pose.scaleAlignReliabilityPrior,
      poseSource: _lastPoseSource,
      focusStable: focusStable,
      isAdjustingFocus: pose.isAdjustingFocus,
      isAdjustingExposure: pose.isAdjustingExposure,
      lensPosition: pose.lensPosition,
      exposureTargetOffset: pose.exposureTargetOffset,
      trackingStateName: pose.trackingStateName,
    );
    if (_photosDir == null) {
      return;
    }
    if (_pendingPhotoSaveCount >= _maxPendingPhotoSaves) {
      _photoSaveBackpressureSkips++;
      _logPhotoSaveHealthIfNeeded(t);
      return;
    }
    if (t - _lastHighResStillTriggerSec <
        _minHighResStillInterval.inMilliseconds / 1000.0) {
      _photoSaveIntervalSkips++;
      _logPhotoSaveHealthIfNeeded(t);
      return;
    }

    final admit = targetPoints.ingest(sample);

    // Plan H photo bundle: realtime AR frames only decide whether to
    // shoot; the retained material is a synchronized high-resolution
    // ARKit still when the platform supports it.
    if (admit != null) {
      _lastHighResStillTriggerSec = t;
      _pendingPhotoSaveCount += 1;
      _photoSaveStarted++;
      final saveStartedAt = DateTime.now();
      // [2026-07-11 色彩污染修复] 文件名带 frameId 后缀,重拍同槽位不再
      // 覆盖旧文件:colorize/resume 按 fed jsonl 的 jpegPath 取色,同名
      // 覆盖会让先喂入 SfM 的帧被"陈旧内容"染色(cap47 实测 25/121 帧
      // 中招,16% 点污染)。旧文件既被 fed jsonl 引用也是用户照片，永不
      // 自动删除。frameId 目录内唯一(start() 重建目录 + _frameSeq 归零)。
      final photoBase = photoSlotBaseName(
        cellIdx: admit.cellIdx,
        slotIdx: admit.slotIdx,
        frameId: sample.frameId,
      );
      final jpegPath = '$_photosDir/$photoBase.jpg';
      final previewPath = '${_previewsDir ?? _photosDir}/$photoBase.jpg';
      final metadataPath = '$_photosDir/$photoBase.json';
      _sampleByPath[jpegPath] = sample;
      final saveSpec = ARFrameSaveSpec(
        frameID: sample.frameId,
        cellIndex: admit.cellIdx,
        slotIndex: admit.slotIdx,
        jpegPath: jpegPath,
        metadataPath: metadataPath,
        targetTimestamp: pose.timestamp,
        quality: 0.92,
      );
      final saveFuture = poseProvider
          .captureHighResolutionStill(
            highresPath: jpegPath,
            previewPath: previewPath,
            triggerTimestamp: pose.timestamp,
            saveSpec: saveSpec,
          )
          .then<void>((still) async {
            if (still != null) {
              final quality = _evaluateReturnedStill(still, sample);
              if (quality.accepted) {
                var effectiveStill = still;
                if (!await _hasCompleteArFrameSidecar(metadataPath)) {
                  // High-res is the preferred path, but it is not allowed
                  // to promote a JPEG unless the sibling AR/VIO sidecar is
                  // complete. Fall back to the timestamp-matched ARFrame
                  // writer, which writes the same sealed sidecar contract.
                  // ignore: avoid_print
                  print(
                    '[CaptureSession] high-res still missing complete '
                    'AR sidecar; retry fallback frame save: $jpegPath',
                  );
                  final saveResult = await poseProvider.saveCurrentFrame(
                    saveSpec,
                  );
                  if (!saveResult.saved ||
                      !await _hasCompleteArFrameSidecar(metadataPath)) {
                    // ignore: avoid_print
                    print(
                      '[CaptureSession] photo not promoted: '
                      'complete AR sidecar unavailable after retry '
                      '${saveResult.status} ${saveResult.message ?? ''}',
                    );
                    return;
                  }
                  final fallbackStill = await _fallbackStillFromMetadata(
                    metadataPath: metadataPath,
                    highresPath: jpegPath,
                    previewPath: previewPath,
                    sample: sample,
                  );
                  if (fallbackStill == null) return;
                  effectiveStill = fallbackStill;
                }
                _stillByPath[jpegPath] = effectiveStill;
                _qualityByPath[jpegPath] = quality;
                targetPoints.stampJpegPathForFrame(
                  frameId: sample.frameId,
                  jpegPath: jpegPath,
                );
              } else {
                // ignore: avoid_print
                print(
                  '[CaptureSession] high-res still rejected: '
                  '${quality.rejectReasons.join(',')}',
                );
              }
              return;
            }
            final saveResult = await poseProvider.saveCurrentFrame(saveSpec);
            if (saveResult.saved &&
                await _hasCompleteArFrameSidecar(metadataPath)) {
              final fallbackStill = await _fallbackStillFromMetadata(
                metadataPath: metadataPath,
                highresPath: jpegPath,
                previewPath: previewPath,
                sample: sample,
              );
              if (fallbackStill != null) {
                _stillByPath[jpegPath] = fallbackStill;
              }
              _qualityByPath[jpegPath] = _qualityFromSample(sample);
              targetPoints.stampJpegPathForFrame(
                frameId: sample.frameId,
                jpegPath: jpegPath,
              );
            } else {
              // ignore: avoid_print
              print(
                '[CaptureSession] photo not promoted ${saveResult.status}: '
                '$jpegPath ${saveResult.message ?? ''}',
              );
            }
          })
          .catchError((Object e, StackTrace st) {
            // ignore: avoid_print
            print('[CaptureSession] photo save failed: $e\n$st');
          })
          .whenComplete(() async {
            await _recordCapturedPhotoIfPresent(jpegPath);
            final latencyMs =
                DateTime.now().difference(saveStartedAt).inMicroseconds /
                1000.0;
            _photoSaveCompleted++;
            _photoSaveLatencyMsSum += latencyMs;
            _photoSaveLatencyMsMax = math.max(
              _photoSaveLatencyMsMax,
              latencyMs,
            );
            _pendingPhotoSaveCount = math.max(0, _pendingPhotoSaveCount - 1);
            _logPhotoSaveHealthIfNeeded(_clock.elapsedMicroseconds / 1000000.0);
          });
      _pendingPhotoSaves.add(saveFuture);
      unawaited(saveFuture);
    }
  }

  /// Reserve exactly one current frame for the RealityScan-style shutter.
  ///
  /// The returned object is available as soon as native binds a snapshot to a
  /// job ID. JPEG/sidecar/gray publication and durable SfM handoff continue in
  /// [ManualPhotoCapture.committed] and [ManualPhotoCapture.completion].
  Future<ManualPhotoCapture?> captureSinglePhoto() async {
    if (!_started || _disposed) return null;
    final pose = _lastPose;
    final photosDir = _photosDir;
    if (pose == null || photosDir == null) return null;

    _beginManualCapturePublication();
    var publicationActivityOwnedByMethod = true;

    // Join the finish barrier before the first await. Therefore Finish cannot
    // race past a shutter that is currently waiting for native reservation.
    final reservationBarrier = Completer<void>();
    _pendingPhotoSaves.add(reservationBarrier.future);
    try {
      final extrinsic =
          _lastPoseSource == 'arkit' && pose.extrinsic4x4.length == 16
          ? pose.extrinsic4x4
          : null;
      final intrinsic =
          _lastPoseSource == 'arkit' && pose.intrinsicFxFyCxCy.length >= 4
          ? pose.intrinsicFxFyCxCy
          : null;

      _frameSeq++;
      final t = _clock.elapsedMicroseconds / 1e6;
      var cameraRadiusM = pose.position.distanceTo(pose.worldOrigin);
      if (!cameraRadiusM.isFinite || cameraRadiusM <= 0) cameraRadiusM = 1.0;
      final sample = CapturedFrameSample(
        timestamp: t,
        azimuth: pose.azimuth,
        elevation: pose.elevation,
        sharpness: 9999.0,
        motionScore: 0.0,
        exposureScore: 1.0,
        frameId: 'tap-$_frameSeq',
        cameraRadiusM: cameraRadiusM,
        cameraExtrinsic4x4: extrinsic,
        cameraIntrinsicFxFyCxCy: intrinsic,
        scaleAlignAnchorCount: pose.scaleAlignAnchorCount,
        scaleAlignDepthSpanM: pose.scaleAlignDepthSpanM,
        scaleAlignReliabilityPrior: pose.scaleAlignReliabilityPrior,
        poseSource: _lastPoseSource,
        trackingStateName: pose.trackingStateName,
      );

      final admit = targetPoints.forceAdmit(sample);
      if (admit == null) return null;

      final photoBase = photoSlotBaseName(
        cellIdx: admit.cellIdx,
        slotIdx: admit.slotIdx,
        frameId: sample.frameId,
      );
      final jpegPath = '$photosDir/$photoBase.jpg';
      final metadataPath = '$photosDir/$photoBase.json';
      final sfmGrayPath = '$photosDir/$photoBase.sfm-gray';
      _sampleByPath[jpegPath] = sample;
      final saveSpec = ARFrameSaveSpec(
        frameID: sample.frameId,
        cellIndex: admit.cellIdx,
        slotIndex: admit.slotIdx,
        jpegPath: jpegPath,
        metadataPath: metadataPath,
        targetTimestamp: pose.timestamp,
        quality: 0.92,
      );
      final captureRoot = _captureDir;
      final captureJobID = captureRoot == null
          ? '${DateTime.now().microsecondsSinceEpoch}-${sample.frameId}'
          : '${_basename(captureRoot)}-${sample.frameId}';
      final provider = poseProvider;
      if (provider is! ManualCaptureV2Provider) {
        throw ManualPhotoCaptureException(
          captureJobID: captureJobID,
          code: 'manual_capture_v2_unsupported',
          message: 'The active pose provider cannot reserve a manual frame.',
        );
      }
      final manualProvider = provider as ManualCaptureV2Provider;

      late final ManualCaptureV2Ticket reservation;
      try {
        reservation = await manualProvider.reserveManualCaptureV2(
          ManualCaptureV2Request(
            captureJobID: captureJobID,
            saveSpec: saveSpec,
            sfmGrayPath: sfmGrayPath,
          ),
        );
      } catch (error) {
        throw ManualPhotoCaptureException(
          captureJobID: captureJobID,
          code: 'snapshot_reservation_failed',
          message: 'Native snapshot reservation failed: $error',
          cause: error,
        );
      }

      _validateManualReservation(
        reservation,
        captureJobID: captureJobID,
        jpegPath: jpegPath,
        metadataPath: metadataPath,
        sfmGrayPath: sfmGrayPath,
      );

      final nativeCommitted = _awaitManualPhotoCommit(
        manualProvider,
        reservation,
        frameId: sample.frameId,
      );
      publicationActivityOwnedByMethod = false;
      final committed = nativeCommitted.whenComplete(
        _endManualCapturePublication,
      );
      // Serialize gray-file reads and durable handoff. Native publication is
      // already serial, but several Dart completion callbacks can otherwise
      // retain full gray planes concurrently while disk is slow or the device
      // is hot. A failed predecessor must not prevent the next accepted job
      // from reaching its own explicit terminal result.
      final predecessor = _manualSfmHandoffTail;
      final completion = committed.then<void>((terminal) async {
        try {
          await predecessor;
        } catch (_) {}
        await _completeManualPhoto(reservation, terminal);
      });
      _manualSfmHandoffTail = completion;
      _trackAcceptedManualPhoto(captureJobID, completion);
      return ManualPhotoCapture(
        reservation: reservation,
        committed: committed,
        completion: completion,
      );
    } finally {
      if (publicationActivityOwnedByMethod) {
        _endManualCapturePublication();
      }
      if (!reservationBarrier.isCompleted) {
        reservationBarrier.complete();
      }
    }
  }

  void _beginManualCapturePublication() {
    _manualCapturePublicationsInFlight += 1;
    if (_manualCapturePublicationsInFlight == 1) {
      _notifyManualCaptureActivity(true);
    }
  }

  void _endManualCapturePublication() {
    if (_manualCapturePublicationsInFlight <= 0) return;
    _manualCapturePublicationsInFlight -= 1;
    if (_manualCapturePublicationsInFlight == 0) {
      _notifyManualCaptureActivity(false);
    }
  }

  void _notifyManualCaptureActivity(bool active) {
    try {
      _manualCaptureActivitySink?.call(active);
    } catch (error, stackTrace) {
      // Scheduling is a performance hint. It must never change the durable
      // result of an already accepted photo.
      // ignore: avoid_print
      print(
        '[CaptureSession] manual capture activity observer failed: '
        '$error\n$stackTrace',
      );
    }
  }

  void _validateManualReservation(
    ManualCaptureV2Ticket reservation, {
    required String captureJobID,
    required String jpegPath,
    required String metadataPath,
    required String sfmGrayPath,
  }) {
    final valid =
        reservation.captureJobID == captureJobID &&
        reservation.status == 'snapshot_reserved' &&
        reservation.snapshotTimestamp.isFinite &&
        reservation.jpegPath == jpegPath &&
        reservation.metadataPath == metadataPath &&
        reservation.sfmGrayPath == sfmGrayPath;
    if (valid) return;
    throw ManualPhotoCaptureException(
      captureJobID: captureJobID,
      code: 'invalid_snapshot_reservation',
      message: 'Native reservation did not match the requested job and paths.',
    );
  }

  Future<ManualCaptureV2Result> _awaitManualPhotoCommit(
    ManualCaptureV2Provider provider,
    ManualCaptureV2Ticket reservation, {
    required String frameId,
  }) async {
    try {
      final terminal = await provider.awaitManualCaptureV2(
        reservation.captureJobID,
      );
      if (terminal.captureJobID != reservation.captureJobID ||
          terminal.jpegPath != reservation.jpegPath ||
          terminal.metadataPath != reservation.metadataPath ||
          terminal.sfmGrayPath != reservation.sfmGrayPath) {
        throw ManualPhotoCaptureException(
          captureJobID: reservation.captureJobID,
          code: 'manual_capture_result_mismatch',
          message: 'Native completion did not match its accepted reservation.',
        );
      }
      if (terminal.committed) {
        if (!await File(terminal.jpegPath).exists()) {
          throw ManualPhotoCaptureException(
            captureJobID: reservation.captureJobID,
            code: 'committed_jpeg_missing',
            message: 'Committed JPEG is missing: ${terminal.jpegPath}',
          );
        }
        if (await File(terminal.jpegPath).length() <= 0) {
          throw ManualPhotoCaptureException(
            captureJobID: reservation.captureJobID,
            code: 'committed_jpeg_empty',
            message: 'Committed JPEG is empty: ${terminal.jpegPath}',
          );
        }
        await _recordCapturedPhotoIfPresent(terminal.jpegPath);
        // forceAdmit creates the album/curation slot before native reservation,
        // but the user-visible path must not be published until native has
        // atomically committed the job. Without this stamp, every manual-v2
        // photo was saved on disk yet absent from retainedJpegPaths/manifests.
        final stamped = targetPoints.stampJpegPathForFrame(
          frameId: frameId,
          jpegPath: terminal.jpegPath,
        );
        if (!stamped) {
          // The JPEG remains user-owned on disk. It is simply no longer a
          // reconstruction candidate because a newer capture replaced this
          // frame before its asynchronous publication completed.
          // ignore: avoid_print
          print(
            '[CaptureSession] committed manual frame left curation buffer '
            'before stamp: job=${reservation.captureJobID} frame=$frameId',
          );
        }
      }
      return terminal;
    } on ManualPhotoCaptureException {
      rethrow;
    } catch (error) {
      throw ManualPhotoCaptureException(
        captureJobID: reservation.captureJobID,
        code: 'manual_capture_worker_failed',
        message: 'Native manual-capture worker failed: $error',
        cause: error,
      );
    }
  }

  Future<void> _completeManualPhoto(
    ManualCaptureV2Ticket reservation,
    ManualCaptureV2Result terminal,
  ) async {
    final captureJobID = reservation.captureJobID;
    if (!terminal.committed) {
      throw ManualPhotoCaptureException(
        captureJobID: captureJobID,
        code: terminal.errorCode ?? 'photo_commit_failed',
        message: terminal.message ?? 'Native photo publication failed.',
      );
    }

    if (!await File(terminal.jpegPath).exists()) {
      throw ManualPhotoCaptureException(
        captureJobID: captureJobID,
        code: 'committed_jpeg_missing',
        message: 'Committed JPEG is missing: ${terminal.jpegPath}',
      );
    }
    if (!await File(terminal.metadataPath).exists()) {
      throw ManualPhotoCaptureException(
        captureJobID: captureJobID,
        code: 'committed_sidecar_missing',
        message:
            'Committed metadata sidecar is missing: '
            '${terminal.metadataPath}',
      );
    }
    if (!terminal.registerable) {
      throw ManualPhotoCaptureException(
        captureJobID: captureJobID,
        code: 'sfm_gray_invalid',
        message: 'Committed result has no valid frame-exact gray dimensions.',
      );
    }

    final grayFile = File(terminal.sfmGrayPath);
    if (!await grayFile.exists()) {
      throw ManualPhotoCaptureException(
        captureJobID: captureJobID,
        code: 'sfm_gray_missing',
        message:
            'Committed frame-exact gray input is missing: '
            '${terminal.sfmGrayPath}',
      );
    }
    final gray = await grayFile.readAsBytes();
    final expectedGrayBytes = terminal.sfmGrayWidth * terminal.sfmGrayHeight;
    if (gray.length != expectedGrayBytes) {
      throw ManualPhotoCaptureException(
        captureJobID: captureJobID,
        code: 'sfm_gray_invalid',
        message:
            'Frame-exact gray has ${gray.length} bytes; '
            'expected $expectedGrayBytes.',
      );
    }

    final timestamp = terminal.timestamp;
    if (timestamp == null ||
        !timestamp.isFinite ||
        terminal.imageWidth <= 0 ||
        terminal.imageHeight <= 0 ||
        terminal.intrinsicFxFyCxCy.length < 4) {
      throw ManualPhotoCaptureException(
        captureJobID: captureJobID,
        code: 'sfm_metadata_invalid',
        message: 'Committed frame lacks valid SfM camera metadata.',
      );
    }

    final feed = SfmFrameFeed(
      gray: gray,
      grayW: terminal.sfmGrayWidth,
      grayH: terminal.sfmGrayHeight,
      imageW: terminal.imageWidth,
      imageH: terminal.imageHeight,
      intrinsicFxFyCxCy: terminal.intrinsicFxFyCxCy,
      extrinsic4x4: terminal.extrinsic4x4.length == 16
          ? terminal.extrinsic4x4
          : const <double>[],
      timestamp: timestamp,
      jpegPath: terminal.jpegPath,
    );

    final sink = await _waitForManualSfmFrameSink();
    late final bool queued;
    try {
      queued = await sink(feed);
    } catch (error) {
      throw ManualPhotoCaptureException(
        captureJobID: captureJobID,
        code: 'sfm_worker_failed',
        message: 'Durable SfM sink failed: $error',
        cause: error,
      );
    }
    if (!queued) {
      throw ManualPhotoCaptureException(
        captureJobID: captureJobID,
        code: 'sfm_queue_rejected',
        message: 'Durable SfM queue rejected the accepted frame.',
      );
    }

    // Compatibility/visualization only. Durable ownership above, not listener
    // timing, is the completion criterion.
    if (!_sfmFrameCtrl.isClosed) {
      _sfmFrameCtrl.add(feed);
    }
  }

  Future<ManualSfmFrameSink> _waitForManualSfmFrameSink() async {
    if (_manualSfmFrameSink == null) {
      await _manualSfmSinkReady.future;
    }
    return _manualSfmFrameSink!;
  }

  void _trackAcceptedManualPhoto(String captureJobID, Future<void> completion) {
    _pendingPhotoSaveCount += 1;
    final tracked = completion
        .then<void>((_) {})
        .catchError((Object error, StackTrace stackTrace) {
          _manualPhotoFailures[captureJobID] =
              error is ManualPhotoCaptureException
              ? error
              : ManualPhotoCaptureException(
                  captureJobID: captureJobID,
                  code: 'manual_capture_completion_failed',
                  message: '$error',
                  cause: error,
                );
        })
        .whenComplete(() {
          _pendingPhotoSaveCount = math.max(0, _pendingPhotoSaveCount - 1);
        });
    _pendingPhotoSaves.add(tracked);
  }

  Future<bool> _hasCompleteArFrameSidecar(String metadataPath) async {
    try {
      final metadataFile = File(metadataPath);
      if (!await metadataFile.exists()) return false;
      final decoded = jsonDecode(await metadataFile.readAsString());
      if (decoded is! Map) return false;
      return _isCompleteArFrameSidecar(decoded);
    } catch (_) {
      return false;
    }
  }

  static bool _isCompleteArFrameSidecar(Map<dynamic, dynamic> decoded) {
    final trackingState = _jsonString(
      decoded['trackingStateName'] ?? decoded['tracking_state'],
    );
    final premetrics = decoded['scale_align_premetrics'];
    final anchorDepthCount = premetrics is Map
        ? _jsonInt(premetrics['anchor_depth_count'])
        : 0;
    final anchors = decoded['anchors_world'];
    return _jsonDouble(decoded['t'], double.nan).isFinite &&
        _jsonInt(decoded['image_w']) > 0 &&
        _jsonInt(decoded['image_h']) > 0 &&
        _jsonDoubleList(decoded['extrinsic']).length == 16 &&
        _jsonDoubleList(decoded['intrinsics_fxfycxcy']).length >= 4 &&
        trackingState == 'normal' &&
        decoded['is_tracking'] == true &&
        anchors is List &&
        anchors.isNotEmpty &&
        anchorDepthCount >= _minScaleAlignAnchorsForPersistedFrame;
  }

  Future<HighResolutionStillCapture?> _fallbackStillFromMetadata({
    required String metadataPath,
    required String highresPath,
    required String previewPath,
    required CapturedFrameSample sample,
  }) async {
    try {
      final metadataFile = File(metadataPath);
      if (!await metadataFile.exists()) return null;
      final decoded = jsonDecode(await metadataFile.readAsString());
      if (decoded is! Map) return null;
      await _ensureFallbackPreviewFile(
        highresPath: highresPath,
        previewPath: previewPath,
      );
      return HighResolutionStillCapture(
        highresPath: highresPath,
        previewPath: previewPath,
        timestamp: _jsonDouble(decoded['t'], sample.timestamp),
        imageWidth: _jsonInt(decoded['image_w']),
        imageHeight: _jsonInt(decoded['image_h']),
        cameraTransform: _jsonDoubleList(decoded['extrinsic']),
        intrinsics: _jsonDoubleList(decoded['intrinsics_fxfycxcy']),
        captureKind: 'arkit_frame_fallback_jpeg',
        poseSyncQuality: 'nearest_ar_frame_snapshot',
        trackingStateName: _jsonString(
          decoded['trackingStateName'] ?? decoded['tracking_state'],
        ),
      );
    } catch (e) {
      // ignore: avoid_print
      print('[CaptureSession] fallback still metadata read failed: $e');
      return null;
    }
  }

  Future<void> _ensureFallbackPreviewFile({
    required String highresPath,
    required String previewPath,
  }) async {
    final previewFile = File(previewPath);
    if (await previewFile.exists()) return;
    final highresFile = File(highresPath);
    if (!await highresFile.exists()) return;
    await previewFile.parent.create(recursive: true);
    await highresFile.copy(previewPath);
  }

  static int _jsonInt(Object? value) {
    if (value is num) return value.toInt();
    return 0;
  }

  static double _jsonDouble(Object? value, double fallback) {
    if (value is num) return value.toDouble();
    return fallback;
  }

  static String? _jsonString(Object? value) {
    if (value is String && value.isNotEmpty) return value;
    return null;
  }

  static List<double> _jsonDoubleList(Object? value) {
    if (value is List) {
      return value.whereType<num>().map((v) => v.toDouble()).toList();
    }
    return const <double>[];
  }

  void _resetPhotoSaveHealth() {
    _photoSaveHealthWindowStartSec = 0;
    _photoSaveStarted = 0;
    _photoSaveCompleted = 0;
    _photoSaveBackpressureSkips = 0;
    _photoSaveIntervalSkips = 0;
    _photoSaveLatencyMsSum = 0;
    _photoSaveLatencyMsMax = 0;
  }

  void _logPhotoSaveHealthIfNeeded(double t, {bool force = false}) {
    if (!force && t - _photoSaveHealthWindowStartSec < 5.0) return;
    final hasEvents =
        _photoSaveStarted > 0 ||
        _photoSaveCompleted > 0 ||
        _photoSaveBackpressureSkips > 0 ||
        _photoSaveIntervalSkips > 0;
    if (!hasEvents) {
      _photoSaveHealthWindowStartSec = t;
      return;
    }
    final avgLatencyMs = _photoSaveCompleted == 0
        ? 0.0
        : _photoSaveLatencyMsSum / _photoSaveCompleted;
    // ignore: avoid_print
    print(
      '[CaptureSession] photo save health: '
      'pending=$_pendingPhotoSaveCount '
      'started=$_photoSaveStarted '
      'completed=$_photoSaveCompleted '
      'backpressureSkips=$_photoSaveBackpressureSkips '
      'intervalSkips=$_photoSaveIntervalSkips '
      'avgMs=${avgLatencyMs.toStringAsFixed(0)} '
      'maxMs=${_photoSaveLatencyMsMax.toStringAsFixed(0)}',
    );

    _photoSaveHealthWindowStartSec = t;
    _photoSaveStarted = 0;
    _photoSaveCompleted = 0;
    _photoSaveBackpressureSkips = 0;
    _photoSaveIntervalSkips = 0;
    _photoSaveLatencyMsSum = 0;
    _photoSaveLatencyMsMax = 0;
  }

  double _estimateSubjectFootprintRatio(ARPose pose, double cameraRadiusM) {
    if (!cameraRadiusM.isFinite ||
        cameraRadiusM <= 0.05 ||
        pose.intrinsicFxFyCxCy.length < 2 ||
        pose.imageWidth <= 0 ||
        pose.imageHeight <= 0) {
      return 0.0;
    }
    const nominalSubjectDiameterM = 0.5;
    final fx = pose.intrinsicFxFyCxCy[0].abs();
    final fy = pose.intrinsicFxFyCxCy[1].abs();
    final focal = fx > 0 && fy > 0 ? math.sqrt(fx * fy) : 0.0;
    if (focal <= 0) return 0.0;
    final diameterPx = focal * nominalSubjectDiameterM / cameraRadiusM;
    final areaPx = math.pi * math.pow(diameterPx * 0.5, 2).toDouble();
    return (areaPx / (pose.imageWidth * pose.imageHeight))
        .clamp(0.0, 1.0)
        .toDouble();
  }

  double _computeExposureScore({
    required double meanBrightness,
    required double exposureTargetOffset,
    required bool isAdjustingExposure,
  }) {
    final dark = FrameQualityConstants.darkThresholdBrightness;
    final bright = FrameQualityConstants.brightThresholdBrightness;
    final brightnessScore = meanBrightness < dark
        ? (meanBrightness / dark).clamp(0.0, 1.0).toDouble()
        : (meanBrightness > bright
              ? (1 - (meanBrightness - bright) / (255 - bright))
                    .clamp(0.0, 1.0)
                    .toDouble()
              : 1.0);
    final offsetScore = (1 - exposureTargetOffset.abs() / 1.25)
        .clamp(0.0, 1.0)
        .toDouble();
    final settlingPenalty = isAdjustingExposure ? 0.65 : 1.0;
    return ((0.72 * brightnessScore + 0.28 * offsetScore) * settlingPenalty)
        .clamp(0.0, 1.0)
        .toDouble();
  }
}
