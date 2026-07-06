// ARCapturePage — RealityScan-style MANUAL AR capture. Forked from the
// dome CapturePage (capture_page.dart) but with a fundamentally different
// capture model:
//
//   • No aim/lock crosshair flow. When the page mounts and ARKit is warm,
//     we silently start the session with `start(autoLock: true)`, which
//     internally runs `_lockOriginWhenReady` to anchor the world origin in
//     the background. No reticle, no "tap to aim" gesture.
//
//   • The center button is a plain shutter (white ring + 119×119 black
//     fill + white dot). EACH tap calls `session.captureSinglePhoto()` to
//     take exactly ONE still. Briefly disabled while the still saves.
//
//   • The blue forward arrow (_FinishCaptureButton) ends the capture and
//     persists the draft via the existing _finalizeRecording flow.
//
//   • Bottom-left affordance shows a THUMBNAIL of the most recent retained
//     photo with the live count overlaid; tapping pushes the full-screen
//     ARAlbumPage.
//
// Three structural regions over a full-bleed camera preview: top bar
// (X close, right), empty center (preview shows through), and the bottom
// HUD (shutter / recording panel).

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data' show Int32List, Float64List;

import 'package:flutter/foundation.dart'
    show compute, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:vector_math/vector_math_64.dart' show Quaternion, Vector3;

import '../../capture/capture_coverage_cloud.dart';
import '../../capture/capture_session.dart';
import '../../capture/sparse_ply.dart';
import '../../capture/dome/dome_target_points.dart';
import '../../capture/model_loader.dart';
import '../../capture/realtime_capture_preview.dart';
import '../../capture/sfm_live_recon.dart';
import '../../capture/ui/model_download_consent_dialog.dart';
import '../../capture/ui/model_download_dialog.dart';
import '../../dome/ar_pose.dart';
import '../../l10n/app_localizations.dart';
import '../../me/scan_record_store.dart';
import '../../pipeline/local_pipeline_runner.dart';
import '../../quality/guidance_engine.dart' show GuidanceSnapshot;
import '../../util/device_log.dart';
import '../scan_record.dart';
import 'ar_album_page.dart';
import 'sfm_preview_overlay.dart';

class ARCapturePage extends StatefulWidget {
  const ARCapturePage({super.key});

  @override
  State<ARCapturePage> createState() => _ARCapturePageState();
}

/// Shared MethodChannel for AetherARKitPlugin.
/// Native ARKit keeps continuous autofocus/exposure in charge during capture;
/// subject locking is an AR anchor operation, not a hardware lens lock.
const MethodChannel _arKitChannel = MethodChannel('aether_arkit');

/// FULL-RESOLUTION RGB pixels of a saved keyframe JPEG, in RAW SENSOR
/// (landscape) orientation — deliberately NO bakeOrientation, because the
/// SfM solver's keypoints/intrinsics live in sensor pixel coords and the
/// colorizer samples straight into them.
///
/// Full-res (not downscaled) to match COLMAP ExtractColorsForAllImages: it
/// reads the native image and bilinear-samples at the exact keypoint. A
/// downscale box-averages across the sharp color edges keypoints sit on
/// (red-blanket-vs-white-sheet boundary → muddy pink), which the native
/// pipeline never does.
class _SampledJpeg {
  const _SampledJpeg(this.rgb, this.w, this.h);
  final Uint8List rgb; // 3 bytes/pixel, row-major
  final int w;
  final int h;
}

_SampledJpeg? _decodeJpegForColorSampling(String sourcePath) {
  try {
    final decoded = img.decodeImage(File(sourcePath).readAsBytesSync());
    if (decoded == null) return null;
    final w = decoded.width, h = decoded.height;
    final out = Uint8List(w * h * 3);
    var o = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final p = decoded.getPixel(x, y);
        out[o++] = p.r.toInt();
        out[o++] = p.g.toInt();
        out[o++] = p.b.toInt();
      }
    }
    return _SampledJpeg(out, w, h);
  } catch (_) {
    return null;
  }
}

Uint8List? _buildCaptureCardThumbnailBytes(String sourcePath) {
  final decoded = img.decodeImage(File(sourcePath).readAsBytesSync());
  if (decoded == null) return null;

  var image = img.bakeOrientation(decoded);
  if (image.width > image.height) {
    image = img.copyRotate(image, angle: 90);
  }

  const maxEdge = 1024;
  final longEdge = math.max(image.width, image.height);
  if (longEdge > maxEdge) {
    image = img.copyResize(
      image,
      width: image.width >= image.height ? maxEdge : null,
      height: image.height > image.width ? maxEdge : null,
      interpolation: img.Interpolation.average,
    );
  }

  return Uint8List.fromList(img.encodeJpg(image, quality: 88));
}

class _ARCapturePageState extends State<ARCapturePage>
    with WidgetsBindingObserver {
  final DomeTargetPoints _targetPoints = DomeTargetPoints();
  final RealtimeCapturePreviewModel _previewModel =
      RealtimeCapturePreviewModel();
  CaptureSession? _session;
  StreamSubscription<ARPose>? _poseSub;

  String? _initError;
  bool _initializing = true;

  // Dome rotation target — driven by the AR pose stream's
  // position-based azimuth / elevation. Pre-lock both stay 0; once
  // the user taps to lock the world origin (Phase 5) the AR pose
  // populates them.
  bool _recording = false;
  bool _lockInProgress = false;
  bool _finalizingRecording = false;

  /// True while a single manual still is being saved (shutter disabled).
  bool _capturing = false;

  // ─── Capture-time streaming SfM (live sparse reconstruction) ──────
  // Worker handle + event plumbing. All heavy calls live in the worker
  // isolate (see sfm_live_recon.dart); this page only routes keyframe
  // feeds in and snapshots out. Null on the simulator (feature hidden).
  SfmLiveRecon? _sfmRecon;
  StreamSubscription<SfmFrameFeed>? _sfmFeedSub;
  StreamSubscription<SfmLiveEvent>? _sfmEventSub;

  /// Non-null while the post-capture preview overlay is showing.
  SfmPreviewPhase? _sfmPhase;
  SfmLiveSnapshot? _sfmSnapshot;
  String? _sfmErrorText;
  int _sfmFed = 0;
  int _sfmQueued = 0;

  /// The finish flow wants to pop to Drafts, but the preview overlay owns
  /// the exit while it's up — set, then honoured by [_onSfmPreviewDone].
  bool _sfmPendingPop = false;

  // ─── RS-style capture-coverage cloud (Dart-owned policy) ──────────
  // Empty until the first committed shutter; every photo frustum-marks the
  // VIO voxel cloud and the covered points render red→yellow→green by how
  // many photos saw them. Policy lives in capture_coverage_cloud.dart
  // (cross-platform); native only displays what we push.
  final CaptureCoverageCloud _coverageCloud = CaptureCoverageCloud();
  StreamSubscription<SfmFrameFeed>? _coverageFeedSub;

  /// 3-state UX: idle → aim → recording.
  /// idle:      user has not started anything; tap → enter aim.
  /// aim:       crosshair shown center, tap → trigger lockOrigin AT
  ///            user's current aim direction. If lock succeeds, enter
  ///            recording. If fails, stay in aim with hint text.
  /// recording: video + dome live; tap → stop + upload.
  /// Replaces the legacy auto-lock UX where tapping record kicked off
  /// `_lockOriginWhenReady` retry loop in the background. User
  /// feedback: should be a deliberate "I'm aiming at the subject NOW"
  /// gesture, not a magic auto-lock.
  bool _isAiming = false;

  /// ARKit warm-up gate. False only while the native AR session is still
  /// proving that it can deliver frames. Once the pose stream is alive we
  /// let the user enter aim mode; if ARKit is temporarily `.limited`,
  /// lockOrigin will show the actionable retry hint instead of trapping the
  /// user behind "Initializing AR..." forever.
  ///
  /// Why this exists: on a thermally pressured device (e.g. user came
  /// from a home page that rendered spz models for a few minutes), if
  /// the user taps lock-subject the moment they hit the capture page,
  /// ARKit's visual SLAM is still warming up + may immediately drop to
  /// .notAvailable / .limited(initializing) for 1-2 s under
  /// `ARWorldTrackingTechnique resource constraints [33]`. The dome
  /// then freezes that whole time, which reads as "卡了几秒灰色". By
  /// The old version required 1.5 s of perfectly continuous
  /// `trackingState == .normal`. In real rooms, especially close-up desk
  /// shots with blur / low texture, ARKit can flicker normal↔limited for
  /// many seconds even though the camera preview and pose stream are usable.
  /// That read as a hard freeze. We now open the gate on first healthy pose
  /// or after a short bounded fallback once the session is attached.
  bool _arWarmupComplete = false;
  Timer? _warmupFallbackTimer;
  int _warmupPoseEvents = 0;
  static const Duration _warmupFallbackDuration = Duration(milliseconds: 1800);

  // Pose-stream diagnostic — verifies events arrive at expected rate and
  // quality reports come at the throttled 6 Hz from the Swift side. Flip
  // `_kDiagLog` to false once the dome is debugged.
  static const bool _kDiagLog = true;
  final Stopwatch _diagPoseClock = Stopwatch()..start();
  int _diagPoseEvents = 0;
  int _diagQualityEvents = 0;

  /// DA3 mlpackage readiness is checked before capture starts.
  /// Downloaded once per app lifetime (NSBundleResourceRequest is sticky).
  DateTime? _lastArSessionResumeAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 吃鸡 mode: do NOT auto-fetch on capture page mount. First check the
    // cache; if model isn't there, prompt the user with a consent dialog
    // and only start the ODR download if they explicitly tap 下载. This
    // matches user-stated UX (2026-05-20) — App Store install bundle is
    // ~80 MB; ML stack only downloads when user wants to create.
    _initCamera();
    // Defer consent dialog until after frame mounts (showDialog needs a
    // valid widget tree). Fire-and-forget — _checkModelStatusAndPrompt
    // owns navigation back if user declines.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _checkModelStatusAndPrompt(),
    );
  }

  /// Cache-first model readiness check with consent dialog gating.
  ///
  /// Flow:
  ///   1. Check ModelLoader.localPathIfCached(tier) — fast, no network
  ///   2a. Cached → capture flow proceeds normally
  ///   2b. Not cached → show ModelDownloadConsentDialog
  ///       3a. User taps 稍后 → Navigator.pop, exit capture page
  ///       3b. User taps 下载 → call _ensureModelDownloaded (kicks off ODR)
  Future<void> _checkModelStatusAndPrompt() async {
    try {
      final tier = await ModelLoader.instance.deviceTier();
      if (!mounted) return;

      // Fast path: already cached
      final cached = await ModelLoader.instance.localPathIfCached(tier);
      if (cached != null) {
        if (!mounted) return;
        if (_kDiagLog) {
          // ignore: avoid_print
          print(
            '[CapturePage] model already cached for ${tier.wireName}: $cached',
          );
        }
        return;
      }

      // Slow path — show consent dialog. User explicit "下载" choice.
      if (!mounted) return;
      final consented = await showModelDownloadConsentDialog(
        context,
        tier: tier,
      );
      if (!mounted) return;
      if (!consented) {
        // User tapped 稍后 — exit capture page back to wherever they came from.
        if (_kDiagLog) {
          // ignore: avoid_print
          print('[CapturePage] user declined model download — exiting capture');
        }
        Navigator.of(context).pop();
        return;
      }

      // User consented — start ODR fetch with progress UI.
      await _ensureModelDownloaded();
    } catch (e) {
      if (_kDiagLog) {
        // ignore: avoid_print
        print('[CapturePage] _checkModelStatusAndPrompt FAILED: $e');
      }
    }
  }

  /// Trigger the actual ODR download. Called only AFTER user consents via
  /// ModelDownloadConsentDialog; ModelDownloadDialog owns progress UI.
  Future<void> _ensureModelDownloaded() async {
    try {
      if (_kDiagLog) {
        // ignore: avoid_print
        print(
          '[CapturePage] user consented — triggering NSBundleResourceRequest',
        );
      }
      final result = await ModelDownloadDialog.run(context);
      if (!mounted) return;
      if (result == null) {
        Navigator.of(context).pop();
        return;
      }
      if (_kDiagLog) {
        // ignore: avoid_print
        print(
          '[CapturePage] model ready: ${result.localPath} '
          '(wasAlreadyCached=${result.wasAlreadyCached})',
        );
      }
    } catch (e) {
      if (_kDiagLog) {
        // ignore: avoid_print
        print('[CapturePage] _ensureModelDownloaded FAILED: $e');
      }
    }
  }

  Future<void> _initCamera() async {
    // ARKit takes exclusive control of the back camera while the AR
    // session is running, so we DON'T initialize a Flutter `camera`
    // plugin CameraController in parallel — that produces
    // FigCaptureSourceRemote err=-17281 (camera service not
    // responding) and breaks both paths. The capture page operates
    // off the AR pose stream alone; native side reads pixel buffers
    // from `ARFrame.capturedImage` for the Laplacian / signature
    // pipeline.
    //
    // We call `session.attach()` here to start the ARSession as soon
    // as the page mounts. lockOrigin needs `tracking == .normal`,
    // which can take ~1-2 s after ARKit cold-start; by warming up
    // before the user taps Record, the lock fires against a stable
    // baseline pose instead of whatever angle ARKit happens to have
    // mid-warm-up while the user is still moving the phone.
    try {
      final session = CaptureSession(targetPoints: _targetPoints);
      _poseSub = session.poseStream.listen((p) {
        if (!mounted) return;
        _diagPoseEvents++;
        if (p.quality != null) _diagQualityEvents++;
        if (_diagPoseClock.elapsedMilliseconds >= 5000) {
          final secs = _diagPoseClock.elapsedMilliseconds / 1000;
          if (_kDiagLog) {
            // ignore: avoid_print
            print(
              '[CapturePage] 5s pose stream: '
              '$_diagPoseEvents events '
              '(${(_diagPoseEvents / secs).toStringAsFixed(1)} Hz), '
              '$_diagQualityEvents quality '
              '(${(_diagQualityEvents / secs).toStringAsFixed(1)} Hz), '
              'hasOrigin=${p.hasOrigin}',
            );
          }
          _diagPoseEvents = 0;
          _diagQualityEvents = 0;
          _diagPoseClock.reset();
          _diagPoseClock.start();
        }
        _previewModel.updateFromPose(
          p,
          photoCount: _targetPoints.retainedJpegPaths.length,
        );
        // Coverage-cloud position upkeep — never lights points up by itself
        // (only markCapture at each shutter does).
        _coverageCloud.ingestPose(p);
        _checkArWarmup(p);
      });
      await session.attach();
      if (!mounted) {
        await session.dispose();
        return;
      }
      setState(() {
        _session = session;
        _initializing = false;
      });
      _armArWarmupFallback();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _initError = AppL10n.of(context).captureInitFailed('$e');
        _initializing = false;
      });
    }
  }

  /// Open the idle gate once AR has demonstrably started. We prefer a real
  /// `.normal` pose, but after a few pose events we also allow limited
  /// tracking through so the user can aim and get a concrete lock failure
  /// hint rather than a permanent initializer.
  void _checkArWarmup(ARPose pose) {
    if (_arWarmupComplete) return;
    _warmupPoseEvents += 1;
    if (pose.isTracking) {
      _markArWarmupComplete('tracking=normal');
      return;
    }
    if (_warmupPoseEvents >= 6) {
      _markArWarmupComplete(
        'pose stream active, tracking=${pose.trackingStateName ?? 'unknown'}',
      );
    }
  }

  void _armArWarmupFallback() {
    _warmupFallbackTimer?.cancel();
    _warmupFallbackTimer = Timer(_warmupFallbackDuration, () {
      if (!mounted || _arWarmupComplete || _session == null) return;
      _markArWarmupComplete('attached timeout fallback');
    });
  }

  void _markArWarmupComplete(String reason) {
    if (_arWarmupComplete) return;
    _warmupFallbackTimer?.cancel();
    _warmupFallbackTimer = null;
    if (_kDiagLog) {
      // ignore: avoid_print
      print('[CapturePage] AR warmup complete: $reason; enabling aim');
    }
    if (mounted) {
      setState(() {
        _arWarmupComplete = true;
      });
      // RealityScan-style manual capture: as soon as ARKit is warm, silently
      // start the session (auto-lock origin in the background, no aim UI).
      unawaited(_startManualCapture());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_session == null) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // TRUE background — release the camera so the OS doesn't kill us, but do
      // NOT finalize: keep the in-progress capture (session stays `_started`,
      // photos intact) so the album survives a background round-trip.
      // `inactive` is TRANSIENT (screenshot, control center, notification) and
      // must NOT release/finalize, or the album resets on a screenshot.
      _pauseArForBackground();
    } else if (state == AppLifecycleState.resumed) {
      _restartArSessionAfterResume();
    }
  }

  Future<void> _pauseArForBackground() async {
    // Release only the camera; leave the Dart CaptureSession started and its
    // retained photos untouched so resume continues the same capture.
    try {
      await _arKitChannel.invokeMethod<void>('stopSession');
    } catch (_) {}
  }

  Future<void> _restartArSessionAfterResume() async {
    final now = DateTime.now();
    final last = _lastArSessionResumeAt;
    if (last != null && now.difference(last).inMilliseconds < 1200) {
      return;
    }
    _lastArSessionResumeAt = now;
    try {
      // resume:true → native keeps the world map + photo-card anchors (no
      // resetTracking / removeExistingAnchors) so the AR cards survive.
      await _arKitChannel.invokeMethod<void>('startSession', {'resume': true});
      if (!mounted) return;
      if (_recording) {
        // Continue the SAME capture (session still _started, photos intact).
        // Just re-lock the origin in the resumed world frame so new taps keep
        // saving. Do NOT reset preview/warmup — that path wipes the album.
        final s = _session;
        if (s != null) unawaited(s.lockOrigin(distanceMeters: 1.0));
        return;
      }
      setState(() {
        _arWarmupComplete = false;
        _warmupPoseEvents = 0;
      });
      _armArWarmupFallback();
      if (_kDiagLog) {
        // ignore: avoid_print
        print('[CapturePage] ARSession restarted after app resume');
      }
    } catch (e) {
      if (_kDiagLog) {
        // ignore: avoid_print
        print('[CapturePage] ARSession resume restart skipped: $e');
      }
    }
  }

  Future<void> _stopRecordingIfRunning() async {
    if (!_recording) return;
    await _finalizeRecording(navigateToDrafts: false, showSparseHint: false);
  }

  Future<void> _onCloseTap() async {
    if (_finalizingRecording || _lockInProgress) return;
    if (!_recording) {
      if (mounted) Navigator.of(context).maybePop(false);
      return;
    }

    final discard = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('退出拍摄？'),
        content: const Text('这次拍摄的素材会被丢弃，不会进入草稿。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('继续拍摄'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('退出并丢弃'),
          ),
        ],
      ),
    );
    if (!mounted || discard != true) return;

    final session = _session;
    if (session != null) {
      await session.discardCurrentCapture();
    }
    if (!mounted) return;
    setState(() {
      _recording = false;
      _isAiming = false;
      _lockInProgress = false;
    });
    _previewModel.reset();
    Navigator.of(context).pop(false);
  }

  Future<void> _onCenterTap() async {
    final session = _session;
    if (session == null) return;

    if (_recording) {
      await _finalizeRecording(navigateToDrafts: true, showSparseHint: true);
      return;
    }

    if (_isAiming) {
      if (_lockInProgress) return;
      setState(() {
        _lockInProgress = true;
      });
      // AIM → try LOCK at user's current aim direction.
      // Single-shot (no retry loop). Failure leaves user in aim with
      // a hint snackbar so they can re-aim and retry.
      // 1.0 m: matches the typical "stand 1-1.5 m from a chair / bag /
      // small object" capture distance. iOS Aether3D's original 0.5 m
      // assumed close-up handheld figurines; PocketWorld users tend to
      // shoot floor-level objects at arm's length+, so the smaller
      // value put the world origin in the air in front of (rather than
      // ON) the subject, shrinking the dome's azimuth span.
      final result = await session.lockOrigin(distanceMeters: 1.0);
      if (!mounted) return;
      if (result == null) {
        setState(() {
          _lockInProgress = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppL10n.of(context).captureLockFailedHint),
            behavior: SnackBarBehavior.floating,
          ),
        );
        return;
      }
      // Lock succeeded; proceed to recording (skip auto-retry loop).
      try {
        await session.start(autoLock: false);
        if (!mounted) return;
        _previewModel.reset();
        setState(() {
          _isAiming = false;
          _recording = true;
          _lockInProgress = false;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _lockInProgress = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              AppL10n.of(context).captureRecordingStartFailed('$e'),
            ),
          ),
        );
      }
      return;
    }

    // IDLE → enter AIM. Show crosshair, wait for the user to actively
    // aim at the subject and tap again to lock. No auto-anchor.
    // Gated by [_arWarmupComplete] — onTap on the parent button is
    // already null when warmup hasn't completed, but defensively
    // double-check so a programmatic tap can't slip past the gate.
    if (!_arWarmupComplete) return;
    setState(() {
      _isAiming = true;
      _lockInProgress = false;
    });
  }

  /// RealityScan-style manual capture: silently start the session once ARKit
  /// is warm (auto-lock the world origin in the background, no aim crosshair),
  /// then each shutter tap takes exactly one photo. Idempotent.
  Future<void> _startManualCapture() async {
    final session = _session;
    if (session == null || _recording || !mounted) return;
    try {
      await session.start(autoLock: true, manualCapture: true);
      if (!mounted) return;
      // Fresh take → clear any anchored AR cards left from a previous session.
      try {
        await _arKitChannel.invokeMethod<void>('clearPhotoCards');
      } catch (_) {}
      // T6: turn on the live sparse coverage cloud for this take (RS-style —
      // ARKit feature points, world-anchored, coloured by coverage).
      try {
        await _arKitChannel.invokeMethod<void>(
          'setFeaturePointsVisible', <String, dynamic>{'visible': true});
      } catch (_) {}
      _previewModel.reset();
      // Fresh take → empty coverage cloud (0 photos ⇒ 0 dots on screen).
      _coverageCloud.reset();
      unawaited(_pushCoverageCloud());
      _coverageFeedSub ??=
          session.sfmFrameStream.listen(_onCoverageKeyframe);
      setState(() {
        _recording = true;
        _isAiming = false;
        _lockInProgress = false;
      });
      // Capture-time streaming SfM: spawn the worker and route keyframe
      // feeds to it. Fully off the critical path — a failed start just
      // means no live preview (the JPEG bundle is unaffected).
      unawaited(_startSfmLiveRecon(session));
    } catch (e) {
      // ignore: avoid_print
      print('[ARCapturePage] manual capture start failed: $e');
    }
  }

  /// Per committed shutter: frustum-mark the coverage cloud with the
  /// frame-exact pose+intrinsics (the same SfmFrameFeed that drives
  /// streaming SfM — but fully independent of the SfM worker, so the
  /// coverage UX works even where on-device SfM is unavailable).
  void _onCoverageKeyframe(SfmFrameFeed feed) {
    _coverageCloud.markCapture(feed);
    unawaited(_pushCoverageCloud());
  }

  /// Ships the current coverage state to the native dumb renderer.
  Future<void> _pushCoverageCloud() async {
    final packed = _coverageCloud.packed();
    try {
      await _arKitChannel.invokeMethod<void>(
        'setCoveragePointCloud',
        <String, dynamic>{'xyz': packed.xyz, 'rgb': packed.rgb},
      );
    } catch (_) {
      // Display-only channel — never let it disturb capture.
    }
  }

  /// Spawns the streaming-SfM worker for this take and wires the keyframe
  /// feed. No-op on the simulator ([SfmLiveRecon.isSupported] == false) so
  /// the whole live-preview feature is hidden there. Never throws into the
  /// zone — a failed start only costs the live preview, never the capture.
  Future<void> _startSfmLiveRecon(CaptureSession session) async {
    try {
      if (_sfmRecon != null) return;
      if (!SfmLiveRecon.isSupported) {
        DeviceLog.log('ARCapturePage', 'sfm: unsupported — preview hidden');
        return;
      }
      final captureDir = session.captureDir;
      if (captureDir == null) {
        DeviceLog.log('ARCapturePage', 'sfm: no captureDir — not started');
        return;
      }
      final recon =
          await SfmLiveRecon.start(dbPath: '$captureDir/sfm_live.db');
      if (recon == null) return; // reason already file-logged by start()
      if (!mounted || !_recording) {
        DeviceLog.log('ARCapturePage', 'sfm: page gone before worker up');
        unawaited(recon.dispose());
        return;
      }
      _sfmRecon = recon;
      _sfmFeedSub = session.sfmFrameStream.listen(recon.offerFrame);
      _sfmEventSub = recon.events.listen(_onSfmEvent);
      if (mounted) setState(() {}); // surface the feed chip immediately
      DeviceLog.log('ARCapturePage', 'sfm: live recon wired');
    } catch (e, st) {
      DeviceLog.log('ARCapturePage', 'sfm: start FAILED: $e\n$st');
    }
  }

  void _onSfmEvent(SfmLiveEvent event) {
    if (!mounted) return;
    setState(() {
      switch (event) {
        case SfmLiveFrameFed():
          _sfmFed = _sfmRecon?.fedCount ?? _sfmFed;
          _sfmQueued = _sfmRecon?.queuedCount ?? _sfmQueued;
        case SfmLiveFrameQueued():
          _sfmQueued = _sfmRecon?.queuedCount ?? _sfmQueued;
        case SfmLiveLocalReady(:final snapshot):
          _sfmSnapshot = snapshot;
          if (_sfmPhase == SfmPreviewPhase.generating) {
            _sfmPhase = SfmPreviewPhase.localReady;
          }
        case SfmLiveRefined(:final snapshot):
          // Silent swap-in: same overlay, new points, small "精修完成" badge.
          _sfmSnapshot = snapshot;
          if (_sfmPhase == SfmPreviewPhase.localReady ||
              _sfmPhase == SfmPreviewPhase.generating) {
            _sfmPhase = SfmPreviewPhase.refined;
          }
        case SfmLiveFailed(:final stage, :final message):
          // During capture (overlay hidden) a per-frame failure is log-only;
          // once the preview is up, a finalize/refine failure surfaces the
          // non-blocking "已保留素材" state. A REFINE failure after
          // LOCAL_READY keeps the perfectly usable local preview instead.
          if (_sfmPhase == SfmPreviewPhase.generating) {
            _sfmPhase = SfmPreviewPhase.error;
            _sfmErrorText = '$stage: $message';
          }
      }
    });
    // Real-color pass: on-device extract_colors is off, so snapshots arrive
    // colorless — sample the registered keyframes' JPEGs instead. Runs after
    // the cloud is already visible (progressive enhancement).
    switch (event) {
      case SfmLiveLocalReady(:final snapshot):
      case SfmLiveRefined(:final snapshot):
        unawaited(_colorizeSnapshot(snapshot));
      default:
        break;
    }
  }

  /// Samples real point colors the COLMAP way (extract_colors parity): each
  /// point is sampled ONLY in the frames of its own track, at the keypoint
  /// coordinates where it was actually detected, then averaged. Track
  /// membership is a visibility proof, so occlusion cannot contaminate the
  /// color. (The previous approach — reprojecting every point into 3
  /// globally-picked frames — sampled whatever OCCLUDED the point there:
  /// points on the red blanket turned white behind the bedding silhouette,
  /// producing the striped/washed clouds.) Data-side rgb only — geometry
  /// untouched. Skips silently when superseded by a newer snapshot.
  Future<void> _colorizeSnapshot(SfmLiveSnapshot snap) async {
    final recon = _sfmRecon;
    if (recon == null || snap.pointCount == 0) return;
    final n = snap.pointCount;
    final offs = snap.obsOffsets;
    final fids = snap.obsFrameIds;
    final oxy = snap.obsXY;
    if (fids.isEmpty || offs.length != n + 1) return; // no track data

    // Group observations by frame so every JPEG decodes exactly once.
    // byFrame[frameId] = flat [pointIndex, kpX, kpY, ...] triples.
    final byFrame = <int, List<double>>{};
    for (var i = 0; i < n; i++) {
      for (var j = offs[i]; j < offs[i + 1]; j++) {
        final f = fids[j];
        if (!recon.fedFrameMeta.containsKey(f)) continue;
        (byFrame[f] ??= <double>[])
          ..add(i.toDouble())
          ..add(oxy[j * 2])
          ..add(oxy[j * 2 + 1]);
      }
    }
    if (byFrame.isEmpty) return;

    // Float accumulators — COLMAP sums bilinear-interpolated float samples,
    // then rounds the mean (reconstruction.cc:1112).
    final sumR = Float64List(n), sumG = Float64List(n), sumB = Float64List(n);
    final hits = Int32List(n);
    for (final entry in byFrame.entries) {
      final meta = recon.fedFrameMeta[entry.key]!;
      final sj = await compute(
        _decodeJpegForColorSampling,
        meta.jpegPath,
        debugLabel: 'sfm_color_decode',
      );
      if (sj == null) continue;
      if (!mounted || !identical(_sfmSnapshot, snap)) return; // superseded
      // Keypoint coords live in fed-gray pixel space; the JPEG shares the
      // same sensor orientation, only the scale differs (usually 1:1).
      final scaleX = sj.w / meta.grayW, scaleY = sj.h / meta.grayH;
      final tri = entry.value;
      for (var k = 0; k < tri.length; k += 3) {
        final i = tri[k].toInt();
        // COLMAP samples at xy - 0.5 (upper-left pixel center = (0.5,0.5)),
        // bilinear, out-of-bounds skipped — Bitmap::InterpolateBilinear.
        final fx = tri[k + 1] * scaleX - 0.5;
        final fy = tri[k + 2] * scaleY - 0.5;
        final x0 = fx.floor(), y0 = fy.floor();
        final x1 = x0 + 1, y1 = y0 + 1;
        if (x0 < 0 || y0 < 0 || x1 >= sj.w || y1 >= sj.h) continue;
        final dx = fx - x0, dy = fy - y0;
        final w00 = (1 - dx) * (1 - dy), w01 = dx * (1 - dy);
        final w10 = (1 - dx) * dy, w11 = dx * dy;
        final o00 = (y0 * sj.w + x0) * 3, o01 = (y0 * sj.w + x1) * 3;
        final o10 = (y1 * sj.w + x0) * 3, o11 = (y1 * sj.w + x1) * 3;
        final rgbP = sj.rgb;
        sumR[i] += w00 * rgbP[o00] +
            w01 * rgbP[o01] +
            w10 * rgbP[o10] +
            w11 * rgbP[o11];
        sumG[i] += w00 * rgbP[o00 + 1] +
            w01 * rgbP[o01 + 1] +
            w10 * rgbP[o10 + 1] +
            w11 * rgbP[o11 + 1];
        sumB[i] += w00 * rgbP[o00 + 2] +
            w01 * rgbP[o01 + 2] +
            w10 * rgbP[o10 + 2] +
            w11 * rgbP[o11 + 2];
        hits[i]++;
      }
    }
    if (!mounted || !identical(_sfmSnapshot, snap)) return;

    final rgb = Uint8List(n * 3);
    for (var i = 0; i < n; i++) {
      final h = hits[i];
      if (h > 0) {
        rgb[i * 3] = (sumR[i] / h).round().clamp(0, 255);
        rgb[i * 3 + 1] = (sumG[i] / h).round().clamp(0, 255);
        rgb[i * 3 + 2] = (sumB[i] / h).round().clamp(0, 255);
      } else {
        // Track frames unavailable (meta evicted / decode failed) — keep a
        // readable light gray, never black.
        rgb[i * 3] = 185;
        rgb[i * 3 + 1] = 185;
        rgb[i * 3 + 2] = 190;
      }
    }
    setState(() {
      _sfmSnapshot = SfmLiveSnapshot(
        xyz: snap.xyz,
        rgb: rgb,
        posesPacked: snap.posesPacked,
        summary: snap.summary,
        refined: snap.refined,
        obsOffsets: snap.obsOffsets,
        obsFrameIds: snap.obsFrameIds,
        obsXY: snap.obsXY,
      );
    });
    // 每次拍摄的进度必须留档:真彩全量点云 + 元数据写进 captureDir(与草稿
    // 素材同生命周期;REFINED 快照会覆盖 LOCAL 版)。
    final captureDir = _session?.captureDir;
    if (captureDir != null) {
      unawaited(persistSparseSnapshot(
        captureDir: captureDir,
        snapshot: snap,
        rgb: rgb,
      ));
    }
  }

  /// "完成" on the preview overlay: tear the worker down (frees the native
  /// session + sqlite db) and run the exit the finish flow deferred.
  void _onSfmPreviewDone() {
    final recon = _sfmRecon;
    _sfmRecon = null;
    _sfmFeedSub?.cancel();
    _sfmFeedSub = null;
    _sfmEventSub?.cancel();
    _sfmEventSub = null;
    if (recon != null) unawaited(recon.dispose());
    if (!mounted) return;
    setState(() => _sfmPhase = null);
    if (_sfmPendingPop) {
      _sfmPendingPop = false;
      Navigator.of(context).pop(true);
    }
  }

  /// Shutter tap → capture exactly ONE high-res still (RealityScan manual).
  Future<void> _onShutterTap() async {
    final session = _session;
    if (session == null || !_recording || _capturing) return;
    setState(() => _capturing = true);
    try {
      final jpegPath = await session.captureSinglePhoto();
      if (jpegPath != null && mounted) {
        // Anchor a native, world-stable AR card at the capture pose (no drift).
        // Best-effort: a card failure must never fail the capture itself.
        try {
          await _arKitChannel.invokeMethod<void>(
            'addPhotoCard',
            <String, dynamic>{'jpegPath': jpegPath},
          );
        } catch (e) {
          // ignore: avoid_print
          print('[ARCapturePage] addPhotoCard failed: $e');
        }
      }
    } finally {
      if (mounted) setState(() => _capturing = false);
    }
  }

  /// Open the full-screen, time-ordered photo album.
  void _openAlbum() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ARAlbumPage(
          targetPoints: _targetPoints,
          onDelete: _deleteRetainedPhoto,
        ),
      ),
    );
  }

  /// Persist the just-recorded capture as a DRAFT scan.
  ///
  /// The Drafts card is the user-facing handle for the raw capture bundle:
  /// `scan_records.json` points back to `<captureDir>/photos_highres/`, and
  /// `<captureDir>/photo_bundle.json` is the source-of-truth manifest for
  /// local DA3 / preflight / texture derivation.
  Future<void> _finalizeRecording({
    required bool navigateToDrafts,
    required bool showSparseHint,
  }) async {
    final session = _session;
    if (session == null || _finalizingRecording) return;
    _finalizingRecording = true;
    try {
      // RECORDING → STOP. The high-res stills are written incrementally
      // under `<captureDir>/photos_highres/`; stop freezes curation and
      // writes the shared photo_bundle contract.
      await session.stop();
      // T6: tear down the live sparse cloud when the take ends.
      try {
        await _arKitChannel.invokeMethod<void>(
          'setFeaturePointsVisible', <String, dynamic>{'visible': false});
      } catch (_) {}
      if (mounted) {
        setState(() {
          _recording = false;
          _isAiming = false;
          _lockInProgress = false;
        });
      }
      await session.waitForPendingPhotoSaves();
      // Streaming SfM: every keyframe feed has been offered by now (the
      // pending-saves barrier guarantees it), so kick the two-phase
      // finalize. Phase 1 runs in the worker WHILE we do the curation +
      // draft disk work below; the preview overlay appears immediately
      // with its "正在生成预览…" state. Fewer than 2 fed frames can't
      // reconstruct — tear down silently and keep the classic exit.
      // Every offered frame counts — the disk queue guarantees they all
      // reach the reconstruction before finalize runs.
      final recon = _sfmRecon;
      final sfmPreviewing = recon != null && recon.offeredCount >= 2;
      DeviceLog.log(
          'ARCapturePage',
          'finish: sfm fed=${recon?.fedCount ?? -1} '
          'queued=${recon?.queuedCount ?? -1} preview=$sfmPreviewing');
      if (sfmPreviewing) {
        await _sfmFeedSub?.cancel();
        _sfmFeedSub = null;
        recon.finalize();
        if (mounted) {
          setState(() => _sfmPhase = SfmPreviewPhase.generating);
        }
      } else if (recon != null) {
        _onSfmPreviewDone(); // silent teardown, no overlay
      }
      final curated = _targetPoints.curateForUpload(framesPerPoint: 5);
      if (curated.isEmpty) {
        if (mounted && showSparseHint) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppL10n.of(context).captureMaterialTooSparseHint),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
        if (navigateToDrafts && mounted) {
          _exitToDrafts();
        }
        return;
      }
      await session.retainOnlyCuratedPhotos(curated);
      await _persistDraft(
        curatedFrames: curated,
        showSnackBar: mounted && showSparseHint,
      );
      // Pop with `true` as a signal to AetherAppShell that it should
      // switch the active tab to Me Drafts (the user just created a
      // scan and expects to see it sitting in their drafts list).
      if (navigateToDrafts && mounted) {
        _exitToDrafts();
      }
    } finally {
      _finalizingRecording = false;
    }
  }

  /// Exit to Drafts — unless the live-reconstruction preview overlay is up,
  /// in which case the user leaves via its "完成" button and the pop is
  /// deferred to [_onSfmPreviewDone].
  void _exitToDrafts() {
    if (_sfmPhase != null) {
      _sfmPendingPop = true;
      return;
    }
    Navigator.of(context).pop(true);
  }

  Future<void> _persistDraft({
    required List<CuratedFrame> curatedFrames,
    required bool showSnackBar,
  }) async {
    final session = _session;
    if (session == null) return;
    final dir = session.photosHighresDir ?? session.photosDir;
    final photoCount = _targetPoints.retainedJpegPaths.length;
    final captureDirPath = session.captureDir;
    if (dir == null || captureDirPath == null || photoCount == 0) {
      if (mounted && showSnackBar) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppL10n.of(context).captureMaterialTooSparseHint),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }
    final photosDir = Directory(dir);
    final captureDir = Directory(captureDirPath);
    final captureSegments = captureDir.uri.pathSegments
        .where((s) => s.isNotEmpty)
        .toList();
    final captureId = captureSegments.isNotEmpty
        ? captureSegments.last
        : 'cap_${DateTime.now().microsecondsSinceEpoch}';
    final createdAt = DateTime.now();
    final store = ScanRecordStore.instance;
    await store.ensureLoaded();

    String? thumbnailPath;
    final firstPhoto =
        _targetPoints.retainedJpegPaths
            .where((p) => File(p).existsSync())
            .toList(growable: false)
          ..sort();
    if (firstPhoto.isNotEmpty) {
      final thumbnail = await store.thumbnailFileFor(captureId);
      final sourcePath = _cardThumbnailSourceFor(firstPhoto.first);
      try {
        await thumbnail.parent.create(recursive: true);
        final wroteThumbnail = await _writeCardThumbnail(
          sourcePath: sourcePath,
          destination: thumbnail,
        );
        if (wroteThumbnail) {
          thumbnailPath = thumbnail.path;
        } else {
          await File(sourcePath).copy(thumbnail.path);
          thumbnailPath = thumbnail.path;
        }
      } on FileSystemException {
        thumbnailPath = sourcePath;
      }
    }

    final manifestFile = await session.writePhotoBundleManifest(curatedFrames);
    if (manifestFile == null || !manifestFile.existsSync()) return;
    final record = ScanRecord(
      id: captureId,
      name: '未命名(${store.records.length + 1})',
      createdAt: createdAt,
      preferredCaptureMode: CaptureMode.local,
      thumbnailPath: thumbnailPath,
      captureDir: captureDir.path,
      photosDir: photosDir.path,
      captureManifestPath: manifestFile.path,
      photoCount: photoCount,
      cloudUploadStatus: ScanCloudUploadStatus.localPending,
      localRawRetainedForDebug: true,
    );
    await store.addOrUpdate(record);
    unawaited(_runLocalPipeline(record));
    if (mounted && showSnackBar) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已保存本地素材：$photoCount 张有效照片，正在生成本地派生产物'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  String _cardThumbnailSourceFor(String highresPath) {
    final previewPath = highresPath.replaceFirst(
      '/photos_highres/',
      '/previews/',
    );
    if (previewPath != highresPath && File(previewPath).existsSync()) {
      return previewPath;
    }
    return highresPath;
  }

  Future<void> _deleteRetainedPhoto(String path) async {
    final keep = _targetPoints.retainedJpegPaths.toSet()..remove(path);
    _targetPoints.retainOnlyJpegPaths(keep);
    final previewPath = path.replaceFirst('/photos_highres/', '/previews/');
    final sidecarPath = path.endsWith('.jpg')
        ? '${path.substring(0, path.length - 4)}.json'
        : '$path.json';
    for (final candidate in <String>{path, previewPath, sidecarPath}) {
      try {
        final file = File(candidate);
        if (await file.exists()) {
          await file.delete();
        }
      } on FileSystemException {
        // Best-effort UI deletion. The final retainOnlyCuratedPhotos call
        // also prunes unselected files before writing the manifest.
      }
    }
    if (mounted) setState(() {});
  }

  Future<bool> _writeCardThumbnail({
    required String sourcePath,
    required File destination,
  }) async {
    try {
      final bytes = await compute(
        _buildCaptureCardThumbnailBytes,
        sourcePath,
        debugLabel: 'capture-card-thumbnail',
      );
      if (bytes == null) return false;
      await destination.writeAsBytes(bytes, flush: true);
      return true;
    } catch (e) {
      debugPrint('[CapturePage] card thumbnail bake failed: $e');
      return false;
    }
  }

  Future<void> _runLocalPipeline(ScanRecord record) async {
    final captureDirPath = record.captureDir;
    if (captureDirPath == null) {
      return;
    }

    final store = ScanRecordStore.instance;
    await store.addOrUpdate(
      (store.byId(record.id) ?? record).copyWith(
        cloudUploadStatus: ScanCloudUploadStatus.processing,
        clearCloudUploadFailureMessage: true,
        localRawRetainedForDebug: true,
      ),
    );

    final runner = LocalPipelineRunner(captureDir: Directory(captureDirPath));
    final sub = runner.stream.listen((event) {
      debugPrint('[CapturePage] local pipeline $event');
    });
    try {
      await runner.run();
      final output = File('$captureDirPath/stages/compress/output.glb');
      await store.addOrUpdate(
        (store.byId(record.id) ?? record).copyWith(
          cloudUploadStatus: ScanCloudUploadStatus.completed,
          artifactPath: output.existsSync() ? output.path : null,
          clearCloudUploadFailureMessage: true,
          localRawRetainedForDebug: true,
        ),
      );
    } catch (e, st) {
      debugPrint(
        '[CapturePage] local pipeline failed for ${record.id}: $e\n$st',
      );
      await store.addOrUpdate(
        (store.byId(record.id) ?? record).copyWith(
          cloudUploadStatus: ScanCloudUploadStatus.failed,
          cloudUploadFailureMessage: _shortUploadError(e),
          localRawRetainedForDebug: true,
        ),
      );
    } finally {
      await sub.cancel();
    }
  }

  String _shortUploadError(Object error) {
    final text = error.toString();
    if (text.length <= 240) return text;
    return text.substring(0, 240);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _warmupFallbackTimer?.cancel();
    _poseSub?.cancel();
    // Streaming-SfM teardown: frees the native session (joins the background
    // BA thread, drops the sqlite db) off this isolate — page dispose never
    // blocks. Re-entering capture creates a fresh session + worker.
    _coverageFeedSub?.cancel();
    _sfmFeedSub?.cancel();
    _sfmEventSub?.cancel();
    final sfmRecon = _sfmRecon;
    _sfmRecon = null;
    if (sfmRecon != null) unawaited(sfmRecon.dispose());
    _session?.dispose();
    _previewModel.dispose();
    _targetPoints.dispose();
    super.dispose();
  }

  // ─── Layout ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Camera preview / init / error placeholder.
          Positioned.fill(child: _buildPreviewLayer()),

          // ─── Live-SfM feed counter (top-left, recording only): fed vs
          // backpressure-dropped keyframes. Dropped frames simply skip the
          // live reconstruction — never an error, so the chip stays quiet
          // gray. Hidden entirely when the worker isn't running (simulator).
          if (_recording && _sfmRecon != null)
            Positioned(
              top: 0,
              left: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 0, 0),
                  child: _SfmFeedChip(fed: _sfmFed, queued: _sfmQueued),
                ),
              ),
            ),

          // ─── Top bar: just the X close button (right).
          // Tracking dot was previously rendered dead-center here, but
          // it sat right under iOS's Dynamic Island (visually colliding
          // with the system camera-in-use indicator) and the abstract
          // green/red/white color carried no clear meaning to the user.
          // The IdleHintPill + preview minimap + bottom button cover the same
          // information already, so this dot was pure noise. Removed.
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: SizedBox(
                  height: 38,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: _CloseButton(onTap: _onCloseTap),
                  ),
                ),
              ),
            ),
          ),

          // ─── Aim mode overlay: center crosshair + hint text.
          // Only rendered while `_isAiming` is true (between idle and
          // recording). User actively aligns the crosshair on the
          // subject and taps the bottom button to lock origin.
          if (_isAiming)
            const Positioned.fill(child: IgnorePointer(child: _AimOverlay())),

          // ─── Plan G W2 P3 transient hint toast (recording only).
          // Surfaces blur / dark / bright GuidanceEngine hard-reject
          // signals as a 3 s fading pill below the close button. The
          // long-form `hintText` already drives the IdleHintPill, but
          // those wordy lines are easy to miss mid-orbit; this toast
          // is glanceable + transient. Only the 2 conditions the user
          // can actually act on (light + 手抖) — occupancy/soft-reject
          // bubbles up via the existing dome cell coloring instead.
          if (_recording && _session != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(top: 60),
                  child: Center(
                    child: _HardRejectToast(stream: _session!.guidanceStream),
                  ),
                ),
              ),
            ),

          // Photo cards are now rendered NATIVELY as world-anchored SceneKit
          // quads (see AetherARKitPlugin addPhotoCard) — stable, no drift. The
          // old Flutter 2D-projected `_PhotoPositionOverlay` is removed.

          if (_recording && _session != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(top: 104),
                  child: Center(
                    child: _MotionSpeedToast(stream: _session!.motionStream),
                  ),
                ),
              ),
            ),

          // RealityScan-style: the manual capture bar is shown as soon as the
          // AR session exists — no "initializing AR" stage and no big dome
          // button. The shutter is simply disabled (dimmed) until the silent
          // auto-lock has the session recording.
          if (_session != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: _ManualCaptureBar(
                  targetPoints: _targetPoints,
                  ready: _recording,
                  capturing: _capturing,
                  finishing: _finalizingRecording,
                  onShutter: _onShutterTap,
                  onOpenAlbum: _openAlbum,
                  onFinish: _finalizingRecording
                      ? null
                      : () => _finalizeRecording(
                          navigateToDrafts: true,
                          showSparseHint: true,
                        ),
                ),
              ),
            ),

          // ─── Capture-time reconstruction preview (topmost). Appears the
          // moment finish kicks finalize ("正在生成预览…"), turns interactive
          // at LOCAL_READY, silently swaps the refined cloud in at REFINED,
          // and NEVER blocks the user: its 完成 button runs the deferred
          // exit-to-drafts; ERROR keeps素材 and exits the same way.
          if (_sfmPhase != null)
            SfmPreviewOverlay(
              phase: _sfmPhase!,
              snapshot: _sfmSnapshot,
              errorText: _sfmErrorText,
              progressText: _sfmQueued > 0
                  ? '已处理 $_sfmFed · 队列 $_sfmQueued'
                  : '已处理 $_sfmFed 帧',
              onDone: _onSfmPreviewDone,
            ),
        ],
      ),
    );
  }

  Widget _buildPreviewLayer() {
    if (_initializing) {
      return const ColoredBox(
        color: Color(0xFF111113),
        child: Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white70),
            ),
          ),
        ),
      );
    }
    if (_initError != null) {
      return ColoredBox(
        color: const Color(0xFF111113),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              _initError!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ),
        ),
      );
    }
    // iOS: live ARKit camera feed via UiKitView wrapping ARSCNView
    // attached to the same ARSession the plugin owns. Verbatim port of
    // ObjectModeV2ARKitPreview.swift which uses the same ARSCNView
    // strategy. Other platforms fall back to a dark backdrop until a
    // platform-specific preview is wired (Android ARCore / HarmonyOS).
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return const UiKitView(
        viewType: 'aether_arkit_preview',
        creationParams: <String, dynamic>{},
        creationParamsCodec: StandardMessageCodec(),
      );
    }
    return const ColoredBox(color: Color(0xFF111113));
  }
}

// ─── Top bar widgets ───────────────────────────────────────────────────

/// Plan G W2 P3: 3 s fading toast that surfaces GuidanceEngine HARD
/// reject signals (blur / dark / bright) to the user mid-recording.
/// Subscribes to [CaptureSession.guidanceStream] and re-arms its fade
/// timer on every non-null `hardRejectKind` snapshot, so a continuous
/// blur run keeps the toast pinned visible. Auto-fades 3 s after the
/// last bad frame.
class _HardRejectToast extends StatefulWidget {
  final Stream<GuidanceSnapshot> stream;
  const _HardRejectToast({required this.stream});

  @override
  State<_HardRejectToast> createState() => _HardRejectToastState();
}

class _HardRejectToastState extends State<_HardRejectToast> {
  StreamSubscription<GuidanceSnapshot>? _sub;
  Timer? _fadeTimer;
  String? _shownKind;

  @override
  void initState() {
    super.initState();
    _sub = widget.stream.listen(_onSnapshot);
  }

  void _onSnapshot(GuidanceSnapshot snap) {
    final kind = snap.hardRejectKind;
    if (kind == null) return;
    if (!mounted) return;
    setState(() => _shownKind = kind);
    _fadeTimer?.cancel();
    _fadeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _shownKind = null);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _fadeTimer?.cancel();
    super.dispose();
  }

  ({String text, IconData icon}) _content(String kind) {
    switch (kind) {
      case 'blur':
        return (text: '手抖了，稳一稳手', icon: Icons.vibration);
      case 'dark':
        return (text: '光线太暗，找亮一些的地方', icon: Icons.brightness_low);
      case 'bright':
        return (text: '光线太强，避开直射光', icon: Icons.wb_sunny_outlined);
      default:
        return (text: '', icon: Icons.warning_amber_rounded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final kind = _shownKind;
    final visible = kind != null;
    final pickedKind = kind ?? 'blur'; // placeholder when fading out
    final content = _content(pickedKind);
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 250),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(content.icon, color: Colors.white, size: 18),
              const SizedBox(width: 8),
              Text(
                content.text,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MotionSpeedToast extends StatefulWidget {
  final Stream<CaptureMotionSnapshot> stream;
  const _MotionSpeedToast({required this.stream});

  @override
  State<_MotionSpeedToast> createState() => _MotionSpeedToastState();
}

class _MotionSpeedToastState extends State<_MotionSpeedToast> {
  StreamSubscription<CaptureMotionSnapshot>? _sub;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _sub = widget.stream.listen(_onMotion);
  }

  void _onMotion(CaptureMotionSnapshot snap) {
    if (!mounted || _visible == snap.tooFast) return;
    setState(() => _visible = snap.tooFast);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 180),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFFE9583F).withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.22),
                blurRadius: 14,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.speed_rounded, color: Colors.white, size: 18),
              SizedBox(width: 8),
              Text(
                '移动太快，慢一点',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhotoPositionOverlay extends StatelessWidget {
  final RealtimeCapturePreviewModel model;
  final DomeTargetPoints targetPoints;

  const _PhotoPositionOverlay({
    required this.model,
    required this.targetPoints,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: model,
      builder: (_, _) {
        final pose = model.lastPose;
        if (pose == null || model.cameraSamples.isEmpty) {
          return const SizedBox.expand();
        }
        final photoPaths =
            targetPoints.retainedJpegPaths
                .where((p) => File(p).existsSync())
                .toList(growable: false)
              ..sort();
        return LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            final visibleCards = <_ProjectedPhotoCard>[];
            for (final sample in model.cameraSamples.reversed.take(90)) {
              final projected = _projectCameraSampleToScreen(
                sample.position,
                pose: pose,
                size: size,
              );
              if (projected == null) continue;
              final pathIndex = sample.photoCount - 1;
              visibleCards.add(
                _ProjectedPhotoCard(
                  sample: sample,
                  offset: projected.offset,
                  depth: projected.depth,
                  path: pathIndex >= 0 && pathIndex < photoPaths.length
                      ? photoPaths[pathIndex]
                      : null,
                ),
              );
            }
            visibleCards.sort((a, b) => b.depth.compareTo(a.depth));
            return Stack(
              children: [
                for (final card in visibleCards)
                  Positioned(
                    left: card.offset.dx - card.width / 2,
                    top: card.offset.dy - card.height / 2,
                    child: _PhotoPositionCard(
                      path: card.path,
                      width: card.width,
                      height: card.height,
                      opacity: card.opacity,
                      rotation: _cameraYawFromOrientation(
                        card.sample.orientation,
                      ),
                      sfmConfirmed: card.sample.sfmConfirmed,
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class _ProjectedPhotoCard {
  final CapturePreviewCameraSample sample;
  final Offset offset;
  final double depth;
  final String? path;

  const _ProjectedPhotoCard({
    required this.sample,
    required this.offset,
    required this.depth,
    required this.path,
  });

  double get width => (34 - depth * 2.1).clamp(18.0, 32.0).toDouble();
  double get height => width * 1.34;
  double get opacity => (0.92 - depth * 0.045).clamp(0.46, 0.88).toDouble();
}

class _ScreenProjection {
  final Offset offset;
  final double depth;

  const _ScreenProjection({required this.offset, required this.depth});
}

_ScreenProjection? _projectCameraSampleToScreen(
  Vector3 worldPosition, {
  required ARPose pose,
  required Size size,
}) {
  final invOrientation = pose.orientation.conjugated();
  final rel = worldPosition - pose.position;
  final cam = invOrientation.rotated(rel);
  final depth = -cam.z;
  if (depth <= 0.12 || depth > 12.0) return null;
  final focal = size.shortestSide * 0.72;
  final sx = size.width / 2 + (cam.x / depth) * focal;
  final sy = size.height / 2 - (cam.y / depth) * focal;
  if (sx < -60 || sx > size.width + 60 || sy < -80 || sy > size.height + 80) {
    return null;
  }
  return _ScreenProjection(offset: Offset(sx, sy), depth: depth);
}

double _cameraYawFromOrientation(Quaternion orientation) {
  final forward = orientation.rotated(Vector3(0, 0, -1));
  return math.atan2(forward.x, forward.z);
}

class _PhotoPositionCard extends StatelessWidget {
  final String? path;
  final double width;
  final double height;
  final double opacity;
  final double rotation;

  /// Border color signal: false → BLACK (just captured, not yet
  /// reconstructed), true → WHITE (backend SfM has confirmed it). Always
  /// false for now — the SfM hookup is deferred.
  final bool sfmConfirmed;

  const _PhotoPositionCard({
    required this.path,
    required this.width,
    required this.height,
    required this.opacity,
    required this.rotation,
    required this.sfmConfirmed,
  });

  @override
  Widget build(BuildContext context) {
    final imagePath = path;
    return Opacity(
      opacity: opacity,
      child: Transform.rotate(
        angle: rotation * 0.18,
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.20),
            border: Border.all(
              color: sfmConfirmed ? Colors.white : Colors.black,
              width: 1.6,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.32),
                blurRadius: 8,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: imagePath == null
              ? Icon(
                  Icons.photo_outlined,
                  size: width * 0.48,
                  color: Colors.white.withValues(alpha: 0.75),
                )
              : Image.file(File(imagePath), fit: BoxFit.cover),
        ),
      ),
    );
  }
}

/// RealityScan-style bottom capture bar: latest-photo album thumbnail (left),
/// center shutter (one tap = one photo), and a blue finish arrow (right).
/// Rebuilds on every [targetPoints] change so the count + thumbnail stay live.
class _ManualCaptureBar extends StatelessWidget {
  const _ManualCaptureBar({
    required this.targetPoints,
    required this.ready,
    required this.capturing,
    required this.finishing,
    required this.onShutter,
    required this.onOpenAlbum,
    required this.onFinish,
  });

  final DomeTargetPoints targetPoints;
  final bool ready;
  final bool capturing;
  final bool finishing;
  final VoidCallback onShutter;
  final VoidCallback onOpenAlbum;
  final VoidCallback? onFinish;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: targetPoints,
      builder: (context, _) {
        final paths = targetPoints.retainedJpegPaths
            .where((p) => File(p).existsSync())
            .toList(growable: false);
        // Newest photo (by mtime) for the album thumbnail.
        String? latest;
        var latestAt = DateTime.fromMillisecondsSinceEpoch(0);
        for (final p in paths) {
          try {
            final m = File(p).lastModifiedSync();
            if (m.isAfter(latestAt)) {
              latestAt = m;
              latest = p;
            }
          } on FileSystemException {
            // skip unreadable file
          }
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Row(
            children: [
              SizedBox(
                width: 72,
                child: _AlbumThumbButton(
                  latestPath: latest,
                  count: paths.length,
                  onTap: onOpenAlbum,
                ),
              ),
              Expanded(
                child: Center(
                  child: _ShutterButton(
                    busy: capturing,
                    enabled: ready,
                    onTap: (ready && !capturing) ? onShutter : null,
                  ),
                ),
              ),
              SizedBox(
                width: 72,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _FinishArrowButton(
                    busy: finishing,
                    onTap: paths.isEmpty ? null : onFinish,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _AlbumThumbButton extends StatelessWidget {
  const _AlbumThumbButton({
    required this.latestPath,
    required this.count,
    required this.onTap,
  });

  final String? latestPath;
  final int count;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.44),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.5),
            width: 1.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (latestPath != null)
              Image.file(File(latestPath!), fit: BoxFit.cover)
            else
              const Icon(
                Icons.photo_library_outlined,
                color: Colors.white,
                size: 22,
              ),
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                color: Colors.black.withValues(alpha: 0.55),
                child: Text(
                  '$count',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({
    required this.busy,
    required this.onTap,
    this.enabled = true,
  });

  final bool busy;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.4,
      child: GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 76,
        height: 76,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 4),
        ),
        child: Padding(
          padding: const EdgeInsets.all(5),
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: busy ? Colors.white54 : Colors.white,
            ),
            child: busy
                ? const Padding(
                    padding: EdgeInsets.all(20),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        Colors.black54,
                      ),
                    ),
                  )
                : null,
          ),
        ),
      ),
      ),
    );
  }
}

class _FinishArrowButton extends StatelessWidget {
  const _FinishArrowButton({required this.busy, required this.onTap});

  final bool busy;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !busy;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: enabled
              ? const Color(0xFF2F97FF)
              : const Color(0xFF2F97FF).withValues(alpha: 0.4),
        ),
        child: busy
            ? const Padding(
                padding: EdgeInsets.all(16),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : const Icon(
                Icons.arrow_forward_rounded,
                color: Colors.white,
                size: 28,
              ),
      ),
    );
  }
}

/// Tiny top-left chip while recording: keyframes fed to the live SfM plus
/// how many are parked in the disk queue (nothing is dropped — queued
/// frames are fed as the worker frees up). Informational only.
class _SfmFeedChip extends StatelessWidget {
  const _SfmFeedChip({required this.fed, required this.queued});

  final int fed;
  final int queued;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0x8C1C1C1E),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.grain_rounded, color: Colors.white54, size: 13),
          const SizedBox(width: 5),
          Text(
            queued > 0 ? '$fed 帧 · 队列 $queued' : '$fed 帧',
            style: const TextStyle(color: Colors.white70, fontSize: 11.5),
          ),
        ],
      ),
    );
  }
}

class _CloseButton extends StatelessWidget {
  final VoidCallback onTap;
  const _CloseButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.35),
          shape: BoxShape.circle,
        ),
        alignment: Alignment.center,
        child: Icon(
          Icons.close_rounded,
          size: 17,
          color: Colors.white.withValues(alpha: 0.9),
        ),
      ),
    );
  }
}

// ─── Aim mode overlay ──────────────────────────────────────────────────
//
// Rendered while the user is in aim mode (between idle and recording).
// White center crosshair (open circle, no fill) + small hint text.
// IgnorePointer wrapper at the call site so the bottom record button
// still receives taps; this overlay is purely visual.
class _AimOverlay extends StatelessWidget {
  const _AimOverlay();

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Center aim guide. Deliberately not a filled ball or full ring:
        // users read that as "subject already locked". Four brackets
        // communicate "align here, then confirm with the bottom button".
        Align(
          alignment: const Alignment(0, -0.10),
          child: SizedBox(
            width: 78,
            height: 78,
            child: CustomPaint(
              painter: _AimReticlePainter(
                color: Colors.white.withValues(alpha: 0.9),
              ),
            ),
          ),
        ),
        // Hint text below the crosshair.
        Align(
          alignment: const Alignment(0, 0.10),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              AppL10n.of(context).captureAimHint,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.9),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _AimReticlePainter extends CustomPainter {
  final Color color;
  const _AimReticlePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round;
    const inset = 4.0;
    const len = 20.0;
    final left = inset;
    final top = inset;
    final right = size.width - inset;
    final bottom = size.height - inset;

    canvas.drawLine(Offset(left, top), Offset(left + len, top), paint);
    canvas.drawLine(Offset(left, top), Offset(left, top + len), paint);
    canvas.drawLine(Offset(right, top), Offset(right - len, top), paint);
    canvas.drawLine(Offset(right, top), Offset(right, top + len), paint);
    canvas.drawLine(Offset(left, bottom), Offset(left + len, bottom), paint);
    canvas.drawLine(Offset(left, bottom), Offset(left, bottom - len), paint);
    canvas.drawLine(Offset(right, bottom), Offset(right - len, bottom), paint);
    canvas.drawLine(Offset(right, bottom), Offset(right, bottom - len), paint);

    final dotPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(size.width / 2, size.height / 2), 2.4, dotPaint);
  }

  @override
  bool shouldRepaint(covariant _AimReticlePainter oldDelegate) {
    return oldDelegate.color != color;
  }
}

// Small dark pill with white text used as the idle-state hint above the
// bottom shutter button. Same look as the in-aim hint pill so the
// transition idle → aim feels like the text just changes, not the chrome.
class _IdleHintPill extends StatelessWidget {
  final String text;
  const _IdleHintPill({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.9),
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

// ─── Bottom HUD: 140×140 captureButtonOrDome ──────────────────────────

class _CaptureButtonOrDome extends StatelessWidget {
  /// True between user's first tap (entering aim mode) and the lock
  /// success that promotes to recording. Renders a checkmark instead
  /// of the white-dot shutter.
  final bool aiming;
  final bool lockInProgress;
  final bool enabled;
  final VoidCallback? onTap;

  const _CaptureButtonOrDome({
    required this.aiming,
    required this.lockInProgress,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ring = SizedBox(
      width: 140,
      height: 140,
      child: CustomPaint(painter: _WhiteRingPainter()),
    );

    // Idle and aim share the same pre-capture chrome (white ring +
    // 119×119 black fill); only the central indicator differs:
    //   • idle: 28×28 white dot (the classic shutter)
    //   • aim:  white check icon — "tap to lock and start"
    final Widget centerIndicator = lockInProgress
        ? const SizedBox(
            width: 34,
            height: 34,
            child: CircularProgressIndicator(
              strokeWidth: 3,
              color: Colors.white,
            ),
          )
        : aiming
        ? const Icon(Icons.check_rounded, size: 56, color: Colors.white)
        : Container(
            width: 28,
            height: 28,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          );

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: enabled ? 1.0 : 0.4,
        child: SizedBox(
          width: 140,
          height: 140,
          child: Stack(
            alignment: Alignment.center,
            children: [
              ring,
              Container(
                width: 119,
                height: 119,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                  shape: BoxShape.circle,
                ),
              ),
              centerIndicator,
            ],
          ),
        ),
      ),
    );
  }
}

class _WhiteRingPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..color = Colors.white;
    final r = (size.shortestSide - 4) / 2;
    canvas.drawCircle(size.center(Offset.zero), r, paint);
  }

  @override
  bool shouldRepaint(covariant _WhiteRingPainter oldDelegate) => false;
}
