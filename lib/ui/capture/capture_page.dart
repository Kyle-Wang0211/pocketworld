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
import 'package:vector_math/vector_math_64.dart' show Quaternion, Vector3;

import '../../capture/capture_session.dart';
import '../../capture/dome/dome_target_points.dart';
import '../../capture/realtime_capture_preview.dart';
import '../../dome/ar_pose.dart';
import '../../l10n/app_localizations.dart';
import '../../me/scan_record_store.dart';
import '../../quality/guidance_engine.dart' show GuidanceSnapshot;
import '../scan_record.dart';

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

  DateTime? _lastArSessionResumeAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Reconstruction is on-device streaming SfM + server-side recon on upload;
    // no local model download gate. Install bundle stays ~80 MB.
    _initCamera();
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
        if (navigateToDrafts && mounted) {
          Navigator.of(context).pop(true);
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
      final thumbnail = await store.thumbnailFileFor(
        captureId,
        pipelineKind: CapturePipelineKind.self,
      );
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
      name: nextUntitledScanName(store.records.map((r) => r.name)),
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
    // Draft stays at localPending for the uploader; reconstruction is
    // streaming SfM on-device + server-side recon after upload.
    if (mounted && showSnackBar) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已保存本地素材：$photoCount 张有效照片'),
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

  List<String> _retainedPhotoPaths() {
    final paths = _targetPoints.retainedJpegPaths
        .where((p) => File(p).existsSync())
        .toList(growable: false);
    paths.sort();
    return paths;
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

  Future<void> _openPhotoTray() async {
    if (!_recording) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF111113),
      barrierColor: Colors.black.withValues(alpha: 0.38),
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            final paths = _retainedPhotoPaths();
            return SafeArea(
              top: false,
              child: SizedBox(
                height: MediaQuery.of(ctx).size.height * 0.68,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 14, 12, 10),
                      child: Row(
                        children: [
                          Text(
                            '已收集 ${paths.length} 张',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            onPressed: () => Navigator.of(ctx).pop(),
                            icon: const Icon(
                              Icons.close_rounded,
                              color: Colors.white,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: paths.isEmpty
                          ? const Center(
                              child: Text(
                                '继续拍摄以收集照片',
                                style: TextStyle(
                                  color: Colors.white60,
                                  fontSize: 14,
                                ),
                              ),
                            )
                          : GridView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 0, 16, 18),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 3,
                                    crossAxisSpacing: 10,
                                    mainAxisSpacing: 10,
                                  ),
                              itemCount: paths.length,
                              itemBuilder: (ctx, index) {
                                final path = paths[index];
                                return _PhotoGridTile(
                                  index: index,
                                  path: path,
                                  onOpen: () => _openSinglePhoto(path),
                                  onDelete: () async {
                                    await _deleteRetainedPhoto(path);
                                    setSheetState(() {});
                                  },
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _openSinglePhoto(String path) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.88),
      builder: (ctx) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 4,
                child: Center(
                  child: Image.file(File(path), fit: BoxFit.contain),
                ),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: SafeArea(
                child: IconButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  icon: const Icon(Icons.close_rounded, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _warmupFallbackTimer?.cancel();
    _poseSub?.cancel();
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

          if (_recording)
            Positioned.fill(
              child: IgnorePointer(
                child: _PhotoPositionOverlay(
                  model: _previewModel,
                  targetPoints: _targetPoints,
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

          if (_recording)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: _RecordingBottomPanel(
                  model: _previewModel,
                  targetPoints: _targetPoints,
                  onOpenPhotos: _openPhotoTray,
                  onFinish: _finalizingRecording
                      ? null
                      : () => _finalizeRecording(
                          navigateToDrafts: true,
                          showSparseHint: true,
                        ),
                ),
              ),
            ),

          if (!_recording)
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
                      aiming: _isAiming,
                      lockInProgress: _lockInProgress,
                      // Disabled in idle until ARKit has settled (see
                      // [_arWarmupComplete] doc). aim stage bypasses the
                      // warmup gate — once we're past idle, the session is
                      // already live and we don't want a mid-take tracking
                      // blip to disable the lock button.
                      enabled:
                          _session != null && (_isAiming || _arWarmupComplete),
                      onTap:
                          _session == null || (!_isAiming && !_arWarmupComplete)
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

  const _PhotoPositionCard({
    required this.path,
    required this.width,
    required this.height,
    required this.opacity,
    required this.rotation,
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
            border: Border.all(color: Colors.white, width: 1.4),
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

class _RecordingBottomPanel extends StatelessWidget {
  final RealtimeCapturePreviewModel model;
  final DomeTargetPoints targetPoints;
  final VoidCallback onOpenPhotos;
  final VoidCallback? onFinish;

  const _RecordingBottomPanel({
    required this.model,
    required this.targetPoints,
    required this.onOpenPhotos,
    required this.onFinish,
  });

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final panelHeight = (media.size.height * 0.20)
        .clamp(136.0, 184.0)
        .toDouble();
    return Container(
      height: panelHeight,
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.82),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.10)),
        ),
      ),
      child: AnimatedBuilder(
        animation: model,
        builder: (_, _) {
          final photoCount = targetPoints.retainedJpegPaths.length;
          return Row(
            children: [
              _PhotoTrayButton(photoCount: photoCount, onTap: onOpenPhotos),
              const SizedBox(width: 12),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(18),
                  child: _DraftPointCloudMiniMap(model: model),
                ),
              ),
              const SizedBox(width: 12),
              _FinishCaptureButton(onTap: onFinish),
            ],
          );
        },
      ),
    );
  }
}

class _DraftPointCloudMiniMap extends StatelessWidget {
  final RealtimeCapturePreviewModel model;

  const _DraftPointCloudMiniMap({required this.model});

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DraftPointCloudMiniMapPainter(
        voxels: model.voxels,
        cameras: model.cameraSamples,
        pose: model.lastPose,
        phase: model.phase,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _DraftPointCloudMiniMapPainter extends CustomPainter {
  final List<CapturePreviewVoxel> voxels;
  final List<CapturePreviewCameraSample> cameras;
  final ARPose? pose;
  final CapturePreviewPhase phase;

  _DraftPointCloudMiniMapPainter({
    required this.voxels,
    required this.cameras,
    required this.pose,
    required this.phase,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final bg = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF171A20), Color(0xFF07080A)],
      ).createShader(rect);
    canvas.drawRect(rect, bg);

    final camera = pose;
    if (camera == null) {
      _paintMiniMapLabel(canvas, size, '建立空间');
      return;
    }

    final origin = camera.position;
    final yaw = _cameraYaw(camera);
    final metersRadius = _rectMiniMapMetersRadius(origin);
    final scale =
        math.min(size.width, size.height) *
        0.46 /
        metersRadius.clamp(1.4, 10.0).toDouble();
    final center = Offset(size.width / 2, size.height / 2);
    final pointPaint = Paint()..style = PaintingStyle.fill;

    var painted = 0;
    for (final voxel in voxels) {
      if (painted >= 2200) break;
      final p = _projectTopDown(
        voxel.position,
        origin: origin,
        yaw: yaw,
        center: center,
        scale: scale,
      );
      if (!rect.inflate(-6).contains(p)) continue;
      pointPaint.color = Color.fromARGB(255, voxel.r, voxel.g, voxel.b)
          .withValues(
            alpha: (0.26 + voxel.confidence * 0.46)
                .clamp(0.24, 0.74)
                .toDouble(),
          );
      canvas.drawCircle(p, 1.7, pointPaint);
      painted += 1;
    }

    final photoPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = Colors.white.withValues(alpha: 0.76);
    for (final sample in cameras.reversed.take(120)) {
      final p = _projectTopDown(
        sample.position,
        origin: origin,
        yaw: yaw,
        center: center,
        scale: scale,
      );
      if (!rect.inflate(-6).contains(p)) continue;
      canvas.save();
      canvas.translate(p.dx, p.dy);
      canvas.rotate(
        (_cameraYawFromOrientation(sample.orientation) - yaw) * 0.38,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset.zero, width: 7, height: 10),
          const Radius.circular(1.2),
        ),
        photoPaint,
      );
      canvas.restore();
    }

    final arrowPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.white.withValues(alpha: 0.92);
    final arrow = Path()
      ..moveTo(center.dx, center.dy - 12)
      ..lineTo(center.dx - 8, center.dy + 8)
      ..lineTo(center.dx + 8, center.dy + 8)
      ..close();
    canvas.drawPath(arrow, arrowPaint);
    _paintMiniMapLabel(canvas, size, phase.shortLabel);
  }

  double _rectMiniMapMetersRadius(Vector3 origin) {
    var maxDistance = 1.8;
    for (final voxel in voxels.take(2200)) {
      final dx = voxel.position.x - origin.x;
      final dz = voxel.position.z - origin.z;
      maxDistance = math.max(maxDistance, math.sqrt(dx * dx + dz * dz));
    }
    return maxDistance.clamp(1.8, 10.0);
  }

  void _paintMiniMapLabel(Canvas canvas, Size size, String text) {
    final labelPainter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.62),
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 24);
    labelPainter.paint(canvas, Offset(12, 9));
  }

  @override
  bool shouldRepaint(covariant _DraftPointCloudMiniMapPainter oldDelegate) {
    return oldDelegate.voxels != voxels ||
        oldDelegate.cameras != cameras ||
        oldDelegate.pose != pose ||
        oldDelegate.phase != phase;
  }
}

class _FinishCaptureButton extends StatelessWidget {
  final VoidCallback? onTap;

  const _FinishCaptureButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Opacity(
        opacity: onTap == null ? 0.55 : 1,
        child: Container(
          width: 64,
          height: 62,
          decoration: BoxDecoration(
            color: const Color(0xFF2CB8F0),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF2CB8F0).withValues(alpha: 0.28),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: const Icon(
            Icons.arrow_forward_rounded,
            color: Colors.black,
            size: 36,
          ),
        ),
      ),
    );
  }
}

class _PhotoTrayButton extends StatelessWidget {
  final int photoCount;
  final VoidCallback onTap;

  const _PhotoTrayButton({required this.photoCount, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 76,
        height: 62,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.44),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.16)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.photo_library_outlined,
              color: Colors.white,
              size: 21,
            ),
            const SizedBox(height: 2),
            Text(
              '$photoCount',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PhotoGridTile extends StatelessWidget {
  final int index;
  final String path;
  final VoidCallback onOpen;
  final VoidCallback onDelete;

  const _PhotoGridTile({
    required this.index,
    required this.path,
    required this.onOpen,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          onTap: onOpen,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.file(File(path), fit: BoxFit.cover),
          ),
        ),
        Positioned(
          left: 6,
          top: 6,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              '${index + 1}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        Positioned(
          right: 2,
          top: 2,
          child: IconButton(
            onPressed: onDelete,
            icon: const Icon(Icons.delete_outline_rounded, color: Colors.white),
            style: IconButton.styleFrom(
              backgroundColor: Colors.black.withValues(alpha: 0.42),
            ),
          ),
        ),
      ],
    );
  }
}

double _cameraYaw(ARPose? pose) {
  if (pose == null) return 0;
  final forward = pose.orientation.rotated(Vector3(0, 0, -1));
  return math.atan2(forward.x, forward.z);
}

Offset _projectTopDown(
  Vector3 position, {
  required Vector3 origin,
  required double yaw,
  required Offset center,
  required double scale,
}) {
  final dx = position.x - origin.x;
  final dz = position.z - origin.z;
  final cosYaw = math.cos(-yaw);
  final sinYaw = math.sin(-yaw);
  final rx = dx * cosYaw - dz * sinYaw;
  final rz = dx * sinYaw + dz * cosYaw;
  return Offset(center.dx + rx * scale, center.dy + rz * scale);
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
