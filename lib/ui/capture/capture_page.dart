// CapturePage v4 — minimalist layout (timer + valid-keyframes badge
// removed per user feedback; both UI and the bookkeeping behind them).
// Three structural regions over a full-bleed camera preview:
//
//   Top bar     38×38 X close button (right) + 8×8 tracking-state dot
//               (center). padding 16 horiz / 14 top.
//
//   Center      empty — camera preview shows through.
//
//   Bottom HUD  140×140 captureButtonOrDome dead-centered at the
//               bottom. Nothing else competes for attention.
//               padding 18 horiz / 18 bottom.
//
//   captureButtonOrDome: not-recording → 140×140 white ring + 119×119
//               black fill + central indicator. Recording → same
//               140×140 ring with the live dome inside; the whole thing
//               is the tap target that ends the capture.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart'
    show compute, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../../capture/capture_session.dart';
import '../../capture/dome/dome_target_points.dart';
import '../../capture/model_loader.dart';
import '../../capture/ui/model_download_consent_dialog.dart';
import '../../capture/ui/model_download_dialog.dart';
import '../../dome/ar_pose.dart';
import '../../l10n/app_localizations.dart';
import '../../me/scan_record_store.dart';
import '../../pipeline/local_pipeline_runner.dart';
import '../../quality/guidance_engine.dart' show GuidanceSnapshot;
import '../scan_record.dart';
import 'dome_view.dart';

class CapturePage extends StatefulWidget {
  const CapturePage({super.key});

  @override
  State<CapturePage> createState() => _CapturePageState();
}

/// Shared MethodChannel for AetherARKitPlugin.
/// Native ARKit keeps continuous autofocus/exposure in charge during capture;
/// subject locking is an AR anchor operation, not a hardware lens lock.
const MethodChannel _arKitChannel = MethodChannel('aether_arkit');

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

class _CapturePageState extends State<CapturePage> with WidgetsBindingObserver {
  final DomeTargetPoints _targetPoints = DomeTargetPoints();
  CaptureSession? _session;
  StreamSubscription<ARPose>? _poseSub;

  String? _initError;
  bool _initializing = true;

  // Dome rotation target — driven by the AR pose stream's
  // position-based azimuth / elevation. Pre-lock both stay 0; once
  // the user taps to lock the world origin (Phase 5) the AR pose
  // populates them.
  double _yaw = 0;
  double _pitch = 0;
  bool _isTracking = true;
  bool _hasLockedOrigin = false;

  bool _recording = false;
  bool _lockInProgress = false;
  bool _finalizingRecording = false;

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
        setState(() {
          // `- π/2` offset matches ObjectModeV2ARDomeCoordinator line 721:
          //   uiView.updateRotation(targetYaw: snap.currentAzimuth - .pi/2, …)
          // Keeps the user's current cell pinned to the dome's +Z (screen
          // center) under iOS's vertex convention.
          _yaw = p.azimuth - math.pi / 2;
          _pitch = p.elevation;
          _isTracking = p.isTracking;
          _hasLockedOrigin = p.hasOrigin;
        });
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
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_session == null) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // Backgrounded — release the camera/sensor stack so the OS
      // doesn't kill us for holding the camera while inactive.
      _stopRecordingIfRunning();
    } else if (state == AppLifecycleState.resumed) {
      _restartArSessionAfterResume();
    }
  }

  Future<void> _restartArSessionAfterResume() async {
    final now = DateTime.now();
    final last = _lastArSessionResumeAt;
    if (last != null && now.difference(last).inMilliseconds < 1200) {
      return;
    }
    _lastArSessionResumeAt = now;
    try {
      await _arKitChannel.invokeMethod<void>('startSession');
      if (!mounted || _recording) return;
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
      if (mounted) {
        setState(() {
          _recording = false;
          _isAiming = false;
          _lockInProgress = false;
        });
      }
      await session.waitForPendingPhotoSaves();
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
      if (navigateToDrafts && mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      }
    } finally {
      _finalizingRecording = false;
    }
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
    _session?.dispose();
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

          // ─── Top bar: just the X close button (right).
          // Tracking dot was previously rendered dead-center here, but
          // it sat right under iOS's Dynamic Island (visually colliding
          // with the system camera-in-use indicator) and the abstract
          // green/red/white color carried no clear meaning to the user.
          // The IdleHintPill + DomeView + bottom button cover the same
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

          // ─── Idle hint pill — sits just above the bottom button.
          // Shows "正在初始化 AR…" while ARKit is warming up, then
          // switches to the localized "tap to aim" prompt once the
          // warmup gate opens.
          // Hidden during aim (the crosshair has its own hint) and
          // recording (no idle prompt needed). The pill is purely
          // visual — IgnorePointer so the bottom button still owns
          // taps in this region.
          if (!_isAiming && !_recording && _session != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 200,
              child: IgnorePointer(
                child: Center(
                  child: _IdleHintPill(
                    text: _arWarmupComplete
                        ? AppL10n.of(context).captureReadyHint
                        : AppL10n.of(context).captureWarmupHint,
                  ),
                ),
              ),
            ),

          // ─── Bottom HUD: just the 140×140 dome/shutter, dead-centered.
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
                child: Center(
                  child: _CaptureButtonOrDome(
                    recording: _recording,
                    aiming: _isAiming,
                    lockInProgress: _lockInProgress,
                    // Disabled in idle until ARKit has settled (see
                    // [_arWarmupComplete] doc). aim/recording stages
                    // bypass the warmup gate — once we're past idle, the
                    // session is already live and we don't want a
                    // mid-take tracking blip to disable the stop button.
                    enabled:
                        _session != null &&
                        (_recording || _isAiming || _arWarmupComplete),
                    targetPoints: _targetPoints,
                    targetYaw: _yaw,
                    targetPitch: _pitch,
                    isTracking: _isTracking,
                    hasLockedOrigin: _hasLockedOrigin,
                    onTap:
                        _session == null ||
                            (!_recording && !_isAiming && !_arWarmupComplete)
                        ? null
                        : _onCenterTap,
                  ),
                ),
              ),
            ),
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
  final bool recording;

  /// True between user's first tap (entering aim mode) and the lock
  /// success that promotes to recording. Renders a checkmark instead
  /// of the white-dot shutter.
  final bool aiming;
  final bool lockInProgress;
  final bool enabled;
  final DomeTargetPoints targetPoints;
  final double targetYaw;
  final double targetPitch;
  final bool isTracking;
  final bool hasLockedOrigin;
  final VoidCallback? onTap;

  const _CaptureButtonOrDome({
    required this.recording,
    required this.aiming,
    required this.lockInProgress,
    required this.enabled,
    required this.targetPoints,
    required this.targetYaw,
    required this.targetPitch,
    required this.isTracking,
    required this.hasLockedOrigin,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final ring = SizedBox(
      width: 140,
      height: 140,
      child: CustomPaint(painter: _WhiteRingPainter()),
    );

    if (recording) {
      // Aether3D pattern: dome layer + ring layer + transparent tap layer
      // (avoids hit-test fights between the SCNView and the button).
      return SizedBox(
        width: 140,
        height: 140,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // Dome itself doesn't take pointers — the transparent tap
            // overlay above it does.
            IgnorePointer(
              child: ClipOval(
                child: SizedBox(
                  width: 140,
                  height: 140,
                  child: DomeView(
                    targetPoints: targetPoints,
                    targetYaw: targetYaw,
                    targetPitch: targetPitch,
                    trackingFrozen: !isTracking,
                    snapKey: hasLockedOrigin,
                  ),
                ),
              ),
            ),
            IgnorePointer(child: ring),
            GestureDetector(
              onTap: onTap,
              behavior: HitTestBehavior.opaque,
              child: const SizedBox(width: 140, height: 140),
            ),
          ],
        ),
      );
    }

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
