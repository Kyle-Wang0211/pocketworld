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

import 'package:official_capture_services/official_capture_services.dart';
import 'package:flutter/widgets.dart' show Offset;
import 'package:path_provider/path_provider.dart';

import '../official_dome/ar_pose.dart';
import '../official_dome/platform_pose_provider.dart';
import '../official_quality/frame_quality_constants.dart';
import '../official_quality/guidance_engine.dart';
import 'dome/captured_frame_sample.dart';
import 'dome/dome_config.dart';
import 'dome/dome_target_points.dart';
import 'database_archive_policy.dart';
import 'orientation_tracker.dart';
import 'official_actual_photo_gate.dart';
import 'official_highres_reconstruction_input.dart';
import 'photo_archive_coordinator.dart';
import 'photo_archive_policy.dart';
import 'photo_archive_runtime.dart';
import 'capture_archive_service.dart';
import 'photo_slot_naming.dart';
import 'telemetry_writer.dart';
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

class OfficialHighResCaptureFailureEvent {
  const OfficialHighResCaptureFailureEvent({
    required this.frameId,
    required this.evidenceJpegPath,
    required this.failure,
  });

  final String frameId;
  final String evidenceJpegPath;
  final OfficialHighResInputFailure failure;
}

class OfficialManualCaptureResult {
  const OfficialManualCaptureResult({
    required this.previewJpegPath,
    required this.evidenceJpegPath,
    required this.highResolutionCompletion,
  });

  final String previewJpegPath;
  final String evidenceJpegPath;
  final Future<OfficialHighResReconstructionInput> highResolutionCompletion;
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

  /// Strictly validated 4032×3024 JPEG inputs for the official recon worker.
  Stream<OfficialHighResReconstructionInput> get sfmFrameStream =>
      _sfmFrameCtrl.stream;

  /// Explicit failures for taps that could not produce canonical 12MP input.
  Stream<OfficialHighResCaptureFailureEvent> get highResFailureStream =>
      _highResFailureCtrl.stream;

  final StreamController<ARPose> _poseCtrl =
      StreamController<ARPose>.broadcast();
  final StreamController<GuidanceSnapshot> _guidanceCtrl =
      StreamController<GuidanceSnapshot>.broadcast();
  final StreamController<CaptureMotionSnapshot> _motionCtrl =
      StreamController<CaptureMotionSnapshot>.broadcast();
  final StreamController<OfficialHighResReconstructionInput> _sfmFrameCtrl =
      StreamController<OfficialHighResReconstructionInput>.broadcast();
  final StreamController<OfficialHighResCaptureFailureEvent>
  _highResFailureCtrl =
      StreamController<OfficialHighResCaptureFailureEvent>.broadcast();
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

  /// 一张票据 = 至多一次原生取图 = 至多一声快门。2026-09-02 由 6 改 1:
  /// 票内重试会造出「快门声 > 相册张数」(实测 26 声/21 张),违反用户铁律
  /// 「选中、拍摄、震动、相框必须一致」。Apple Object Capture 同样从不对
  /// 单次选择重拍。拍失败(原生错误/坏内参)= 本票据作废,治理器按自己的
  /// 判据重新选帧 —— 那是新的一次「选中」,有自己的一声快门,1:1 仍成立。
  static const int _manualHighResMaxAttempts = 1;
  bool _manualCaptureSuspended = false;
  Completer<void>? _manualCaptureResumeCompleter;
  Object? _manualCaptureResumeFailure;
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
  /// 被驱逐帧的旧文件由 colorize 之后的 deferred prune
  /// (retainOnlyCuratedPhotos)统一清理,磁盘不会无限增长。
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
  PhotoArchiveActivityLease? _photoArchiveCaptureLease;
  final List<Future<void>> _pendingPhotoSaves = <Future<void>>[];
  int _pendingPhotoSaveCount = 0;

  // ── 12MP 静照(2026-07-19 甲案落地第一步,纯 Dart 编排)────────────────
  // 每次快门在即时 4K 之外并行落一张 4:3 12MP 静照(`<photoBase>_hr.jpg`),
  // RS 对齐的高清素材;失败退化为仅 4K,不重试、不阻塞快门。in-flight 守卫
  // 防止连拍堆叠相机重配(API 每次捕获会短暂重配相机——tracking 抖动+热,
  // 真机热定价在设备批验收)。
  int _hiresStillStarted = 0;
  int _hiresStillOk = 0;
  int _hiresStillFailed = 0;
  // [E25 2026-07-20] 目标:每次快门都有 _hr(用户要求 100% 覆盖,与 1440p 主图
  // 齐平)。基线只有 ~40%(实测 7/17、11/29),而**真实死因当时没有记录**——
  // 我曾推断是 0.18s 时间戳闸,但那是猜的,没有任何错误码在案。所以这一版
  // 在放开两道门的同时,把每次失败的 native 错误码原样记下来,下次一看便知。
  int _hiresStillDropped = 0;
  bool _highResCaptureInFlight = false;

  /// 每种失败原因的次数,key = native 错误码(210 无 session / 211 无帧 /
  /// 212 时间戳超差 / 213 内存刹车 / other)。
  final Map<String, int> _hiresStillFailReasons = <String, int>{};

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
  final OfficialActualPhotoGate _automaticActualPhotoGate =
      OfficialActualPhotoGate();
  final PhotoBundleManifestService _photoBundleManifest =
      const PhotoBundleManifestService();
  final Map<String, HighResolutionStillCapture> _stillByPath =
      <String, HighResolutionStillCapture>{};
  final Map<String, PhotoBundleStillQuality> _qualityByPath =
      <String, PhotoBundleStillQuality>{};
  final Map<String, CapturedFrameSample> _sampleByPath =
      <String, CapturedFrameSample>{};

  /// Delete cell-slot photos that lost final curation and clear their
  /// in-memory paths. The ring buffers keep up to 12 candidates while
  /// recording; the reconstruction handoff should see only the selected
  /// ~5 per point.
  Future<void> retainOnlyCuratedPhotos(List<CuratedFrame> curated) async {
    final dirPath = _photosDir;
    if (dirPath == null) return;
    // [E25 2026-07-20] 连带保留策展帧的 12MP 静照 `<base>_hr.jpg`(及其
    // sidecar)。此前 keep 只含主图路径,`_hr` 一律被当作"未策展"删除 ——
    // 实测:15 次快门全部成功产出 _hr(遥测 outcome=ok ×15),但点"完成"
    // 后 photos_highres 里 _hr 为 0,而 previews/ 下的 `_hr_preview.jpg`
    // 全在(该目录不被本函数遍历),正是被这里删掉的铁证。
    // _hr 是后续纹理的素材源,必须随它对应的主图一起留下。
    final keep = <String>{
      for (final c in curated)
        if (c.sample.jpegPath != null) ...<String>[
          c.sample.jpegPath!,
          c.sample.jpegPath!.replaceFirst(RegExp(r'\.jpg$'), '_hr.jpg'),
        ],
    };
    if (keep.isEmpty) return;

    final dir = Directory(dirPath);
    if (await dir.exists()) {
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final path = entity.path;
        if (!path.endsWith('.jpg') && !path.endsWith('.json')) continue;
        final jpgPath = path.endsWith('.json')
            ? '${path.substring(0, path.length - '.json'.length)}.jpg'
            : path;
        if (!keep.contains(jpgPath)) {
          try {
            await entity.delete();
          } on FileSystemException {
            // Best effort: a late native encode may still be finishing.
          }
        }
      }
    }
    targetPoints.retainOnlyJpegPaths(keep);
  }

  Future<File?> writePhotoBundleManifest(List<CuratedFrame> curated) async {
    final root = _captureDir;
    if (root == null) return null;
    final frames = <PhotoBundleFrameDraft>[];
    for (final curatedFrame in curated) {
      final sample = curatedFrame.sample;
      final path = sample.jpegPath;
      if (path == null || !File(path).existsSync()) continue;
      frames.add(
        _photoBundleFrameDraft(
          sample: sample,
          path: path,
          radiusShellId: '${curatedFrame.radiusShellId}',
          cellId: '${curatedFrame.azBin}:${curatedFrame.elBin}',
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
    // PWVA 批量归档(P1.1):bundle 已写完,所有 JPEG 已最终化,此刻转码无竞态。
    // [2026-08-10] fire-and-forget:85 帧实测转码 27s,不许串行阻塞"完成"
    // 路径(拍完等待预算 ≤30s 已被 finalize BA 吃满)。归档在独立 isolate
    // 跑完写 archive-report;中途 app 被杀=无 report=master 不接管,零风险。
    unawaited(CaptureArchiveService.instance.archiveCapture(root));
    return File('$root/official_photo_bundle.json');
  }

  /// Writes the official route's authoritative manifest from the user's photo
  /// album, not from internal coverage curation or current SfM registration.
  ///
  /// Every path here has already passed the same-frame 4032×3024 JPEG + ARKit
  /// metadata contract. Pending/disconnected/low-parallax states deliberately
  /// do not affect membership. A path disappears only after the user explicitly
  /// removes it from the project album.
  Future<File?> writeProjectPhotoBundleManifest(
    List<String> projectPhotoPaths,
  ) async {
    final root = _captureDir;
    if (root == null) return null;
    final frames = <PhotoBundleFrameDraft>[];
    for (var index = 0; index < projectPhotoPaths.length; index++) {
      final path = projectPhotoPaths[index];
      if (!File(path).existsSync()) continue;
      final sample = _sampleByPath[path];
      final still = _stillByPath[path];
      if (sample == null || still == null) continue;
      frames.add(
        _photoBundleFrameDraft(
          sample: sample,
          path: path,
          radiusShellId: 'project',
          cellId: 'project:$index',
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
        'selectionPolicy': 'all_user_retained_project_photos',
      },
    );
    // PWVA 批量归档(P1.1,本路径的 manifest 写入器);fire-and-forget 同上。
    unawaited(CaptureArchiveService.instance.archiveCapture(root));
    return File('$root/official_photo_bundle.json');
  }

  PhotoBundleFrameDraft _photoBundleFrameDraft({
    required CapturedFrameSample sample,
    required String path,
    required String radiusShellId,
    required String cellId,
  }) {
    final still = _stillByPath[path];
    final quality = _qualityByPath[path] ?? _qualityFromSample(sample);
    final highresFilename = _basename(path);
    return PhotoBundleFrameDraft(
      id: sample.frameId,
      highresFilename: highresFilename,
      timestamp: still?.timestamp ?? sample.timestamp,
      triggerTimestamp: sample.timestamp,
      azimuth: sample.azimuth,
      elevation: sample.elevation,
      captureKind: still?.captureKind ?? 'arkit_high_res_still',
      poseSyncQuality: still?.poseSyncQuality ?? 'ar_session_high_res_frame',
      imageWidth: still?.imageWidth ?? 0,
      imageHeight: still?.imageHeight ?? 0,
      quality: quality,
      cameraTransform:
          still?.cameraTransform ?? sample.cameraExtrinsic4x4 ?? const [],
      intrinsics:
          still?.intrinsics ?? sample.cameraIntrinsicFxFyCxCy ?? const [],
      cameraRadiusM: sample.cameraRadiusM,
      radiusShellID: radiusShellId,
      poseSource: sample.poseSource,
      focusStable: sample.focusStable,
      trackingState: still?.trackingStateName ?? sample.trackingStateName,
      cellID: cellId,
    );
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
  bool get manualCaptureTransactionsSuspended => _manualCaptureSuspended;

  /// Prevent a queued manual ticket from issuing another native 12MP request
  /// while ARKit is stopped in the background. The active request is allowed
  /// to unwind; its ticket waits here and resumes in FIFO order later.
  void suspendManualCaptureTransactions() {
    if (_disposed || _manualCaptureSuspended) return;
    _manualCaptureSuspended = true;
    _manualCaptureResumeFailure = null;
    _manualCaptureResumeCompleter = Completer<void>();
  }

  void resumeManualCaptureTransactions() {
    _manualCaptureResumeFailure = null;
    if (!_manualCaptureSuspended) return;
    _manualCaptureSuspended = false;
    final completer = _manualCaptureResumeCompleter;
    _manualCaptureResumeCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  void failSuspendedManualCaptureTransactions(Object error) {
    _manualCaptureResumeFailure = error;
    _manualCaptureSuspended = false;
    final completer = _manualCaptureResumeCompleter;
    _manualCaptureResumeCompleter = null;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  Future<void> _waitForManualCaptureResume() async {
    while (_manualCaptureSuspended && _started && !_disposed) {
      final completer = _manualCaptureResumeCompleter ??= Completer<void>();
      await completer.future;
    }
    final failure = _manualCaptureResumeFailure;
    if (failure != null) {
      _manualCaptureResumeFailure = null;
      throw StateError(
        'ARKit resume failed while a shutter ticket waited: $failure',
      );
    }
  }

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

    try {
      if (poseProvider case final PlatformARPoseProvider platformProvider) {
        await platformProvider.ensureStarted();
      }
    } catch (_) {
      await _poseSub?.cancel();
      _poseSub = null;
      _attached = false;
      rethrow;
    }
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
    _photoArchiveCaptureLease = photoArchiveCoordinator.beginCaptureActivity();

    targetPoints.reset();
    guidance.beginRecording();
    _driftTracker.reset();
    _frameSeq = 0;
    _manualCaptureMode = manualCapture;
    _pendingPhotoSaves.clear();
    _pendingPhotoSaveCount = 0;
    _lastHighResStillTriggerSec = double.negativeInfinity;
    _resetPhotoSaveHealth();
    _lastMotionEmitSec = double.negativeInfinity;
    _lastMotionTooFast = false;
    _stillByPath.clear();
    _qualityByPath.clear();
    _sampleByPath.clear();
    _automaticActualPhotoGate.reset();
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

  /// Build (or wipe + recreate) `<docs>/captures_official/<captureId>/photos/`
  /// for this session's cell-admitted JPEGs. Call once per [start];
  /// the resulting path is exposed via [photosDir].
  Future<void> _setupPhotosDirectory() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final captureId = 'cap_${DateTime.now().microsecondsSinceEpoch}';
      final root = Directory('${docs.path}/captures_official/$captureId');
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
      final highres = Directory('${root.path}/photos_highres');
      final previews = Directory('${root.path}/previews');
      await highres.create(recursive: true);
      await previews.create(recursive: true);
      await PhotoArchivePolicy.writeForNewCapture(root);
      await DatabaseArchivePolicy.writeForNewCapture(root);
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
    resumeManualCaptureTransactions();
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
    final archiveLease = _photoArchiveCaptureLease;
    _photoArchiveCaptureLease = null;
    if (archiveLease != null) unawaited(archiveLease.close());
  }

  Future<void> waitForPendingPhotoSaves({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    final pending = _pendingPhotoSaves.toList(growable: false);
    if (pending.isEmpty) return;
    try {
      await Future.wait(pending).timeout(timeout);
    } on TimeoutException {
      // ignore: avoid_print
      print(
        '[CaptureSession] waitForPendingPhotoSaves timed out after '
        '${timeout.inMilliseconds}ms; continuing with files already written',
      );
    } catch (error) {
      // A bounded manual 12MP transaction reports its own explicit failure.
      // Teardown must still release bookkeeping and may then delete/discard
      // the bundle; never let an already-reported save error strand the page.
      // ignore: avoid_print
      print(
        '[CaptureSession] pending photo save failed during teardown: $error',
      );
    } finally {
      _pendingPhotoSaves.removeWhere((f) => pending.contains(f));
    }
  }

  /// Stop the in-flight take and discard its local photo bundle directory.
  ///
  /// This is intentionally separate from [stop] + `writePhotoBundleManifest`:
  /// the capture-page X button uses it for "退出并丢弃", so no
  /// `official_photo_bundle.json` is written and no Draft/ScanRecord is created.
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
    resumeManualCaptureTransactions();
    final archiveLease = _photoArchiveCaptureLease;
    _photoArchiveCaptureLease = null;
    if (archiveLease != null) unawaited(archiveLease.close());
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
    if (!_highResFailureCtrl.isClosed) await _highResFailureCtrl.close();
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
      // 中招,16% 点污染)。旧文件仍被 fed jsonl 引用,不能即时删——由
      // 既有的 deferred prune(colorize 之后 retainOnlyCuratedPhotos)
      // 统一收尾。frameId 目录内唯一(start() 重建目录 + _frameSeq 归零)。
      final photoBase = photoSlotBaseName(
        cellIdx: admit.cellIdx,
        slotIdx: admit.slotIdx,
        frameId: sample.frameId,
      );
      final jpegPath = '$_photosDir/$photoBase.jpg';
      final previewPath = '${_previewsDir ?? _photosDir}/$photoBase.jpg';
      final metadataPath = '$_photosDir/$photoBase.json';
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
                // PWVA 采集期归档(独立 isolate,采集线程只做一次 send)。
                CaptureArchiveService.instance.enqueueHighresStill(
                  jpegPath,
                  triggerTimestamp: sample.timestamp,
                );
                targetPoints.stampJpegPath(
                  cellIdx: admit.cellIdx,
                  slotIdx: admit.slotIdx,
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
                // PWVA 采集期归档(fallback 路径)。
                CaptureArchiveService.instance.enqueueHighresStill(
                  jpegPath,
                  triggerTimestamp: sample.timestamp,
                );
              }
              _qualityByPath[jpegPath] = _qualityFromSample(sample);
              targetPoints.stampJpegPath(
                cellIdx: admit.cellIdx,
                slotIdx: admit.slotIdx,
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
          .whenComplete(() {
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

  /// Manually capture exactly ONE high-resolution still at the current
  /// frame/pose — the RealityScan-style per-tap shutter. Bypasses the
  /// motion/dome auto-admit gates via [DomeTargetPoints.forceAdmit] so the
  /// user, not a gate, decides when to shoot. Returns the immediate 1920×1440
  /// card texture path plus the canonical 4032×3024 evidence path. High-res
  /// success/failure is reported asynchronously and never falls back.
  ///
  /// Only meaningful when the session was started with `manualCapture: true`.
  Future<OfficialManualCaptureResult?> captureSinglePhoto({
    bool automaticSelection = false,
  }) async {
    if (!_started || _disposed) return null;
    final pose = _lastPose;
    final photosDir = _photosDir;
    if (pose == null || photosDir == null) return null;
    // MANUAL capture is a deliberate user action: NEVER silently drop a tap.
    // We still record the best ARKit extrinsic/intrinsic WHEN AVAILABLE (for the
    // pipeline), but if the origin isn't locked yet or tracking has degraded to
    // IMU dead-reckoning, we proceed anyway and save the JPEG to the album with
    // best-effort (possibly null) pose. Downstream filters on pose quality later.
    final extrinsic =
        _lastPoseSource == 'arkit' &&
            pose.extrinsic4x4.isNotEmpty &&
            pose.extrinsic4x4.length == 16
        ? pose.extrinsic4x4
        : null;
    final intrinsic =
        _lastPoseSource == 'arkit' &&
            pose.intrinsicFxFyCxCy.isNotEmpty &&
            pose.intrinsicFxFyCxCy.length >= 4
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
      // Force-admit path bypasses the sharpness gate, but a high nominal
      // value keeps the ring buffer's high-water state sane.
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

    // Coverage is committed only after the canonical 12 MP input passes every
    // validation gate. A failed high-resolution shot must not light a cell or
    // evict an earlier valid sample.
    final photoBase = 'official_${sample.frameId}';
    final evidenceJpegPath = '$photosDir/$photoBase.jpg';
    final evidenceMetadataPath = '$photosDir/$photoBase.json';
    final previewDir = _previewsDir ?? photosDir;
    final previewJpegPath = '$previewDir/$photoBase.jpg';
    final previewMetadataPath = '$previewDir/$photoBase.json';
    final evidenceSaveSpec = ARFrameSaveSpec(
      frameID: sample.frameId,
      cellIndex: -1,
      slotIndex: -1,
      jpegPath: evidenceJpegPath,
      metadataPath: evidenceMetadataPath,
      targetTimestamp: pose.timestamp,
      quality: 0.92,
      includeSfmFeed: false,
    );
    final previewSaveSpec = ARFrameSaveSpec(
      frameID: sample.frameId,
      cellIndex: -1,
      slotIndex: -1,
      jpegPath: previewJpegPath,
      metadataPath: previewMetadataPath,
      targetTimestamp: pose.timestamp,
      quality: 0.92,
      includeSfmFeed: false,
    );

    // Start the 12MP request first, at tap time. The preview save below is a
    // separate 1920×1440 display path and is never eligible for SfM.
    final highResFuture = _captureOfficialHighResInput(
      sample: sample,
      evidenceSaveSpec: evidenceSaveSpec,
      previewPath: '$previewDir/${photoBase}_highres_preview.jpg',
      automaticSelection: automaticSelection,
    );
    _pendingPhotoSaves.add(highResFuture);
    unawaited(highResFuture);

    _pendingPhotoSaveCount += 1;
    final previewFuture = () async {
      try {
        final previewSave = await poseProvider.saveCurrentFrame(
          previewSaveSpec,
        );
        if (!previewSave.saved || !await File(previewJpegPath).exists()) {
          // ignore: avoid_print
          print(
            '[CaptureSession] manual preview NOT saved: $previewJpegPath '
            '${previewSave.status} ${previewSave.message ?? ''}',
          );
        }
      } catch (e, st) {
        // ignore: avoid_print
        print('[CaptureSession] manual preview save failed: $e\n$st');
      } finally {
        _pendingPhotoSaveCount = math.max(0, _pendingPhotoSaveCount - 1);
      }
    }();
    _pendingPhotoSaves.add(previewFuture);
    unawaited(previewFuture);

    // The native card anchor is created immediately at shutter pose and its
    // renderer retries the preview texture until this background save lands.
    return OfficialManualCaptureResult(
      previewJpegPath: previewJpegPath,
      evidenceJpegPath: evidenceJpegPath,
      highResolutionCompletion: highResFuture,
    );
  }

  Future<OfficialHighResReconstructionInput> _captureOfficialHighResInput({
    required CapturedFrameSample sample,
    required ARFrameSaveSpec evidenceSaveSpec,
    required String previewPath,
    bool automaticSelection = false,
  }) async {
    if (_highResCaptureInFlight) {
      _hiresStillDropped++;
      throw StateError(
        'A verified 12MP shutter transaction is already in flight',
      );
    }
    _highResCaptureInFlight = true;
    var attempt = 0;
    var lastFailure = OfficialHighResInputFailure.captureFailed;
    try {
      while (_started && !_disposed && attempt < _manualHighResMaxAttempts) {
        await _waitForManualCaptureResume();
        if (!_started || _disposed) break;
        attempt++;
        _hiresStillStarted++;
        final sw = Stopwatch()..start();
        var outcome = 'ok';
        OfficialHighResInputFailure failure =
            OfficialHighResInputFailure.captureFailed;
        try {
          // Every retry is a new direct ARKit
          // captureHighResolutionFrame transaction. It never reuses a queued
          // preview frame: the accepted JPEG, pose, intrinsics, and timestamp
          // all come from that one returned high-resolution ARFrame.
          final still = await poseProvider.captureHighResolutionStill(
            highresPath: evidenceSaveSpec.jpegPath,
            previewPath: previewPath,
            triggerTimestamp: evidenceSaveSpec.targetTimestamp,
            saveSpec: evidenceSaveSpec,
            deriveAuxiliary: automaticSelection,
          );
          if (still == null) {
            failure = OfficialHighResInputFailure.captureFailed;
          } else {
            final validation = OfficialHighResReconstructionInput.validate(
              jpegPath: still.highresPath,
              imageWidth: still.imageWidth,
              imageHeight: still.imageHeight,
              triggerTimestamp: still.requestTimestamp,
              captureTimestamp: still.timestamp,
              cameraTransform: still.cameraTransform,
              intrinsics: still.intrinsics,
            );
            if (!validation.isAccepted ||
                !await File(still.highresPath).exists()) {
              failure =
                  validation.failure ?? OfficialHighResInputFailure.missingJpeg;
            } else {
              final input = validation.input!;
              final actualQuality = _evaluateReturnedStill(still, sample);
              if (automaticSelection) {
                final actualGate = _automaticActualPhotoGate.evaluate(
                  gray128: still.gray128,
                  imageWidth: still.imageWidth,
                  imageHeight: still.imageHeight,
                  intrinsics: still.intrinsics,
                  qualityAccepted: actualQuality.accepted,
                );
                TelemetryWriter.instance.event('actual_photo_gate', {
                  'decision': actualGate.decision.name,
                  'capture_timestamp': still.timestamp,
                  'request_timestamp': still.requestTimestamp,
                  'actual_track_common':
                      actualGate.trackEvidence?.commonTrackCount,
                  'actual_track_common_fraction':
                      actualGate.trackEvidence?.commonTrackFraction,
                  // 判决用的是均值(上游 VINS 口径);中位数一并记下,便于事后
                  // 对照两者何时分歧、分歧是否跨过阈值线。
                  'actual_track_mean_normalized':
                      actualGate.trackEvidence?.meanNormalizedDisplacement,
                  'actual_track_median_normalized':
                      actualGate.trackEvidence?.medianNormalizedDisplacement,
                  'actual_laplacian_variance': actualQuality.laplacianVariance,
                  'actual_quality_reasons': actualQuality.rejectReasons,
                  // 保留但未验证新颖 —— 用来对账「快门数 = 成片数」。
                  'retained_as_non_novel':
                      actualGate.decision ==
                      OfficialActualPhotoDecision.rejectDuplicate,
                });
                // 重复判决**不是**丢弃判决。上游 VINS 的
                // FeatureManager::addFeatureCheckParallax() 返回这个布尔是用来
                // 选边缘化策略的,它的 false 分支(MARGIN_SECOND_NEW)仍然保留
                // 新帧,只是把被挤掉那帧的 IMU 前推合并。把这个布尔接到删除
                // 路径上,是本次复刻偏离上游的地方,也把一个无损开关变成了
                // 有损开关。
                //
                // 实测 2026-09-01(build-75,08-27 基线):一次会话 23 次快门
                // 触发了 45 次 12MP 原生取图,`rejectDuplicate` 25 次,只活下来
                // 20 张 —— 违反「交付绝对无损」。改回保留之后,同一次快门只做
                // 一次取图(重试消失),每张成本只会更低。
                //
                // 判据基线不受影响:OfficialActualPhotoGate.evaluate() 只在
                // accept 分支调 _commit,rejectDuplicate 本来就不推进基线。
                // 这一点是这一刀成立的前提 —— 基线若被非新颖照片推进,慢速平移
                // 会永远攒不够位移。
                // 2026-09-02 扩展:rejectQuality 也保留。Apple Object Capture
                // 的文档化架构是**拍前选帧、绝不拍后销毁**:
                //   .environmentLowLight: "Auto-capture still proceeds but
                //    reconstruction quality may suffer."
                // 极暗的"停"由治理器的 skipTooDark 预闸负责(拍都不拍),
                // 拍下来的一律入库。实测(build-86,ISO 2500):一场 5 张
                // blur_laplacian 160–195 对阈值 200 的"擦线糊"被销毁并重拍,
                // 用户听到 26 声快门、相册只有 21 张 —— 违反「选中/拍摄/震动/
                // 相框必须 1:1」。质量理由照记(actual_quality_reasons),
                // 基线照旧只被 accept 推进。
                final retainedAsNonNovel =
                    actualGate.decision ==
                        OfficialActualPhotoDecision.rejectDuplicate ||
                    actualGate.decision ==
                        OfficialActualPhotoDecision.rejectQuality;
                if (!actualGate.accepted && !retainedAsNonNovel) {
                  failure = switch (actualGate.decision) {
                    OfficialActualPhotoDecision.rejectMissingEvidence =>
                      OfficialHighResInputFailure.actualStillMissingEvidence,
                    OfficialActualPhotoDecision.rejectQuality =>
                      OfficialHighResInputFailure.actualStillQualityRejected,
                    OfficialActualPhotoDecision.rejectDuplicate =>
                      OfficialHighResInputFailure.actualStillDuplicate,
                    OfficialActualPhotoDecision.accept =>
                      OfficialHighResInputFailure.captureFailed,
                  };
                } else {
                  _hiresStillOk++;
                  _stillByPath[input.jpegPath] = still;
                  // PWVA 采集期归档(official tap 路径,当前生产主路)。
                  CaptureArchiveService.instance.enqueueHighresStill(
                    input.jpegPath,
                    triggerTimestamp: still.requestTimestamp,
                  );
                  _qualityByPath[input.jpegPath] = actualQuality;
                  _sampleByPath[input.jpegPath] = sample.withJpegPath(
                    input.jpegPath,
                  );
                  final admit = targetPoints.forceAdmit(sample);
                  if (admit != null) {
                    targetPoints.stampJpegPath(
                      cellIdx: admit.cellIdx,
                      slotIdx: admit.slotIdx,
                      jpegPath: input.jpegPath,
                    );
                  }
                  if (!_sfmFrameCtrl.isClosed) {
                    _sfmFrameCtrl.add(input);
                  }
                  TelemetryWriter.instance.event('hires_still', {
                    'outcome': outcome,
                    'attempt': attempt,
                    'ms': sw.elapsedMilliseconds,
                    'queue_depth': 0,
                    'started': _hiresStillStarted,
                    'ok': _hiresStillOk,
                    'failed': _hiresStillFailed,
                    'dropped': _hiresStillDropped,
                  });
                  return input;
                }
              } else {
                _hiresStillOk++;
                _stillByPath[input.jpegPath] = still;
                CaptureArchiveService.instance.enqueueHighresStill(
                  input.jpegPath,
                  triggerTimestamp: still.requestTimestamp,
                );
                _qualityByPath[input.jpegPath] = actualQuality;
                _sampleByPath[input.jpegPath] = sample.withJpegPath(
                  input.jpegPath,
                );
                final admit = targetPoints.forceAdmit(sample);
                if (admit != null) {
                  targetPoints.stampJpegPath(
                    cellIdx: admit.cellIdx,
                    slotIdx: admit.slotIdx,
                    jpegPath: input.jpegPath,
                  );
                }
                if (!_sfmFrameCtrl.isClosed) _sfmFrameCtrl.add(input);
                TelemetryWriter.instance.event('hires_still', {
                  'outcome': outcome,
                  'attempt': attempt,
                  'ms': sw.elapsedMilliseconds,
                  'queue_depth': 0,
                  'started': _hiresStillStarted,
                  'ok': _hiresStillOk,
                  'failed': _hiresStillFailed,
                  'dropped': _hiresStillDropped,
                });
                return input;
              }
            }
          }
        } catch (_) {
          failure = OfficialHighResInputFailure.captureFailed;
        }

        if (_manualCaptureSuspended) {
          // Backgrounding can make the native in-flight request fail. It is
          // not a real retry attempt: hold this same ticket until ARKit has
          // successfully resumed, without churning the stopped camera.
          attempt--;
          await _waitForManualCaptureResume();
          continue;
        }

        _hiresStillFailed++;
        lastFailure = failure;
        outcome = '${failure.name}_retry';
        _noteStillFailure(failure.name);
        TelemetryWriter.instance.event('hires_still', {
          'outcome': outcome,
          'attempt': attempt,
          'ms': sw.elapsedMilliseconds,
          'queue_depth': 0,
          'started': _hiresStillStarted,
          'ok': _hiresStillOk,
          'failed': _hiresStillFailed,
          'dropped': _hiresStillDropped,
        });
        // Retry a fresh ARKit 12MP frame after a short recovery yield. The
        // bound prevents Finish from hanging forever on a permanently failed
        // camera; the page reports the failed ticket and continues safely.
        await Future<void>.delayed(
          Duration(milliseconds: math.min(350, 80 + (attempt - 1) * 40)),
        );
      }

      // Surface cancellation/exhaustion so callers cannot mistake it for a
      // verified photo. Queue admission remains exact; failure is explicit.
      _reportHighResFailure(
        sample.frameId,
        evidenceSaveSpec.jpegPath,
        lastFailure,
      );
      throw StateError(
        _started && !_disposed
            ? '12MP shutter transaction failed after '
                  '$_manualHighResMaxAttempts attempts'
            : '12MP shutter transaction cancelled before success',
      );
    } finally {
      _highResCaptureInFlight = false;
    }
  }

  void _reportHighResFailure(
    String frameId,
    String evidenceJpegPath,
    OfficialHighResInputFailure failure,
  ) {
    TelemetryWriter.instance.event('official_highres_failure', {
      'frame_id': frameId,
      'jpeg': evidenceJpegPath.split('/').last,
      'failure': failure.name,
      'fallback_used': false,
    });
    if (!_highResFailureCtrl.isClosed) {
      _highResFailureCtrl.add(
        OfficialHighResCaptureFailureEvent(
          frameId: frameId,
          evidenceJpegPath: evidenceJpegPath,
          failure: failure,
        ),
      );
    }
  }

  /// 记一次静照失败的原因码 —— 上一轮就是因为没记,只能靠猜死因。
  void _noteStillFailure(String code) {
    _hiresStillFailReasons[code] = (_hiresStillFailReasons[code] ?? 0) + 1;
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
        requestTimestamp: sample.timestamp,
        timestamp: _jsonDouble(decoded['t'], sample.timestamp),
        timestampDelta: double.infinity,
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
    // [E25] 同一份计数进遥测 JSONL —— print() 只到 stdout,拔线测试后取不回来,
    // 违反"日志写文件、退出后再看"的规矩。上一轮我加的 hires 计数器就因此
    // 完全无法回收,只能靠猜死因。
    TelemetryWriter.instance.event('photo_save_health', {
      'pending': _pendingPhotoSaveCount,
      'started': _photoSaveStarted,
      'completed': _photoSaveCompleted,
      'hires_started': _hiresStillStarted,
      'hires_ok': _hiresStillOk,
      'hires_failed': _hiresStillFailed,
      'hires_dropped': _hiresStillDropped,
      'hires_queue_depth': _highResCaptureInFlight ? 1 : 0,
      'hires_fail_reasons': Map<String, int>.from(_hiresStillFailReasons),
    });
    // ignore: avoid_print
    print(
      '[CaptureSession] photo save health: '
      'pending=$_pendingPhotoSaveCount '
      'started=$_photoSaveStarted '
      'completed=$_photoSaveCompleted '
      'backpressureSkips=$_photoSaveBackpressureSkips '
      'intervalSkips=$_photoSaveIntervalSkips '
      'avgMs=${avgLatencyMs.toStringAsFixed(0)} '
      'maxMs=${_photoSaveLatencyMsMax.toStringAsFixed(0)} '
      'hiresStarted=$_hiresStillStarted '
      'hiresOk=$_hiresStillOk '
      'hiresFailed=$_hiresStillFailed '
      'hiresDropped=$_hiresStillDropped '
      'hiresFailReasons=$_hiresStillFailReasons',
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
