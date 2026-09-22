// OfficialARCapturePage — RealityScan-style MANUAL AR capture. Forked from the
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
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data' show Int32List, Float32List, Float64List, Uint8List;

import 'package:flutter/foundation.dart'
    show compute, defaultTargetPlatform, TargetPlatform;
import '../../official_capture/dense_stage.dart';
import 'package:flutter/cupertino.dart'
    show
        CupertinoActionSheet,
        CupertinoActionSheetAction,
        showCupertinoModalPopup;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:vector_math/vector_math_64.dart'
    show Matrix4, Quaternion, Vector3;

import '../../vio/pose/vio_ar_pose_provider.dart';
import '../../vio/pose/vio_pose_source_switch.dart';
import '../../vio/quality/pose_confidence.dart';
import '../../point_cloud_display/progressive_octree_order.dart';
import '../../official_capture/auto_capture_controller.dart';
import '../../official_capture/auto_capture_failure_visibility.dart';
import '../../official_capture/auto_capture_geometry.dart'
    show
        AutoCaptureGeometryFrame,
        AutoCaptureIntrinsics,
        medianDepthFromCloudXyz;
import '../../official_capture/auto_capture_governor.dart';
import '../../official_capture/auto_capture_mode.dart';
import '../../official_capture/auto_capture_telemetry.dart';
import '../../official_capture/accepted_photo_transaction.dart';
import '../../official_capture/accepted_photo_record_store.dart';
import '../../official_capture/capture_coverage_cloud.dart';
import '../../official_capture/capture_finish_coordinator.dart';
import '../../official_capture/capture_session.dart';
import '../../official_capture/colorize_pipeline.dart';
import '../../official_capture/live_sfm_publish_policy.dart';
import '../../official_capture/live_cloud_diagnostics.dart';
import '../../official_capture/manual_capture_queue.dart';
import '../../official_capture/official_highres_reconstruction_input.dart';
import '../../official_capture/parallax_banner_gate.dart';
import '../../official_capture/photo_card_state.dart';
import '../../official_capture/project_photo_album.dart';
import '../../official_aether_sfm_ffi.dart'
    show
        AetherMatchFlags,
        AetherEnvFile; // [YIELD-FPS-LINK] + [RS-CORRECT-COLORS]
import '../../official_capture/pw_telemetry.dart';
import '../../official_capture/multiband_color.dart';
import '../../official_capture/representative_color.dart';
import '../../official_capture/shutter_backpressure_gate.dart';
import '../../official_capture/sparse_ply.dart';
import '../../official_capture/telemetry_writer.dart';
import '../../official_capture/transient_preview_cleanup.dart';
import '../../official_capture/dome/dome_target_points.dart';
import '../../official_capture/realtime_capture_preview.dart';
import '../../official_capture/sfm_live_recon.dart';
import '../../official_capture/sfm_recon_lifecycle.dart';
import '../../official_dome/ar_pose.dart';
import '../../l10n/app_localizations.dart';
import '../../me/scan_record_store.dart';
import '../../official_util/device_log.dart';
import '../draft_capture_shell.dart';
import '../me_page.dart';
import '../reconstruction_draft_route_state.dart';
import '../reconstruction_route_release_gate.dart';
import '../scan_record.dart';
import 'ar_album_page.dart';
import 'capture_preview_rect.dart';
import '../../official_capture/selection_box.dart';
import 'selection_tools_layer.dart';
import 'sparse_cloud_view.dart'
    show
        CloudViewCamera,
        CloudViewController,
        SparseCloudPainter,
        editingFrameOf;
import 'capture_exit_dialog.dart';
import 'official_gallery_routes.dart';
import 'sfm_preview_overlay.dart';
import '../sparse_thumbnail.dart';
import '../../util/image_sanitize.dart';
import '../../vio/diagnostics/vio_diagnostics_recorder.dart';
import '../../vio/diagnostics/vio_shadow_switch.dart';

/// 一次快门入队的三种结果。手动与自动**共用同一条入队路径**,但对"没入队"
/// 的反馈不同:手动到上限要弹对话框,自动模式绝不弹(每个 tick 撞一次会
/// 刷屏)。把两者的差别收在这个返回值里,守卫就只需要写一份。
enum _ShutterAdmission { admitted, busyNotAdmitted, closed, budgetExhausted }

enum _CommittedCaptureExit { reconstruct, saveDraft, discard }

final class _PendingFinishTerminal {
  const _PendingFinishTerminal({
    required this.attempt,
    required this.success,
    required this.stage,
    this.error,
    this.stackTrace,
  });

  final CaptureFinishAttempt attempt;
  final bool success;
  final String stage;
  final Object? error;
  final StackTrace? stackTrace;
}

class OfficialARCapturePage extends StatefulWidget {
  const OfficialARCapturePage({super.key});

  @override
  State<OfficialARCapturePage> createState() => _OfficialARCapturePageState();
}

/// Shared MethodChannel for AetherARKitPlugin.
/// Native ARKit keeps continuous autofocus/exposure in charge during capture;
/// subject locking is an AR anchor operation, not a hardware lens lock.
const MethodChannel _arKitChannel = MethodChannel('pocketworld_official_arkit');

// On-device colorize decode moved to native ImageIO downscale (see
// _decodeJpegNative + AetherARKitPlugin decodeJpegForColor). Pure-Dart
// full-res decode (img.decodeImage over 4K × N frames) was the "white cloud"
// regression — 1.5-4 s/frame on a throttled A16, never finished. Full-res
// stays host-regen-only.

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

  // EXIF 剥离:实测确认元数据会穿过 resize/rotate 链路(见
  // util/image_sanitize.dart 与 test/image_sanitize_test.dart)。
  return encodeSanitizedJpg(image, quality: 88);
}

class _OfficialARCapturePageState extends State<OfficialARCapturePage>
    with WidgetsBindingObserver {
  final DomeTargetPoints _targetPoints = DomeTargetPoints();
  final OfficialProjectPhotoAlbum _projectPhotos = OfficialProjectPhotoAlbum();
  final RealtimeCapturePreviewModel _previewModel =
      RealtimeCapturePreviewModel();
  late final ManualCaptureQueue _shutterQueue;
  CaptureSession? _session;
  StreamSubscription<ARPose>? _poseSub;

  // ── [pw 2026-09-22] VIO 消费层(默认关闭)────────────────────────────────
  // `PwVioPoseSourceSwitch` 默认 arkit ⇒ 这两个字段在出货包里恒为 null,
  // 下面所有读它们的地方都是 no-op。
  VioArPoseProvider? _vioPoseProvider;
  StreamSubscription<VioPoseConfidence>? _vioConfidenceSub;

  /// 自研臂最近一帧的可信度。ARKit 路径下恒为 null。
  /// 🔴 **只读诊断**,不驱动任何 UI —— UX 由用户定,本次不碰文案/布局。
  VioPoseConfidence? _vioConfidence;

  String? _initError;
  bool _initializing = true;

  // Dome rotation target — driven by the AR pose stream's
  // position-based azimuth / elevation. Pre-lock both stay 0; once
  // the user taps to lock the world origin (Phase 5) the AR pose
  // populates them.
  bool _recording = false;
  bool _lockInProgress = false;
  final CaptureFinishCoordinator _finishCoordinator = CaptureFinishCoordinator(
    stageTimeout: const Duration(seconds: 20),
  );
  // This prevents two modal confirmation stacks. It never participates in
  // capture admission or rendering, so dismissing a dialog is state-neutral.
  bool _confirmationDialogOpen = false;
  bool _finishDraftPersisted = false;
  _PendingFinishTerminal? _pendingFinishTerminal;
  bool _cameraResumeFailed = false;
  bool _maximumPhotosDialogOpen = false;
  String? _captureQueueFailureText;
  String? _activePhotoFeedbackTransactionId;
  String? _activePhotoFeedbackEvidencePath;
  final Map<String, String> _photoTransactionIdsByEvidencePath =
      <String, String>{};
  final Map<String, AutomaticStillTicket> _automaticTicketByTransaction =
      <String, AutomaticStillTicket>{};
  final Set<String> _automaticControllerReceiptTransactions = <String>{};
  final Set<String> _controllerProjectedTransactions = <String>{};

  // ─── 自动采集(auto capture)────────────────────────────────────────
  // **判定逻辑一行都不在本文件**:几何在 auto_capture_geometry.dart、判据在
  // auto_capture_governor.dart、状态编排在 auto_capture_controller.dart、
  // 表示层映射在 auto_capture_mode.dart。这里只有接线 —— 模式、启停、生命
  // 周期,以及把 controller 挂到**已有的** pose 订阅上。
  // 设计见 docs/superpowers/specs/2026-08-19-auto-capture-design.md。

  /// [SIGNED D9 2026-08-19] **默认自动**。用户调研原话:没有 C 端用户愿意
  /// 点几十上百次快门;RealityScan 官方默认亦为 auto-capture enabled。
  /// ⚠️ 默认自动 **≠ 一进页面就开拍** —— 仍需用户点一次录制键(spec §7/§8.1)。
  OfficialCaptureMode _captureMode = OfficialCaptureMode.auto;

  late final AutoCaptureController _autoCapture = AutoCaptureController(
    onStartAnchor: _onAutoCaptureStartAnchor,
    onFire: _onAutoCaptureFire,
    paceProvider: () => _shutterPace,
    capturedCountProvider: _autoCaptureAcceptedFrameCount,
    // spec §7「热态 critical 只拉长间隔、不停止」。取的是 _recomputeShutterPace
    // 已经采好的那一份,不新起采样(见 _lastThermalState 的注释)。
    thermalStateProvider: () => _lastThermalState,
    // 只给无锁定目标的极端冷启动兜底使用；纯 SfM、四端同口径，不再把
    // iOS centerRayDepthM/raycast 接进自动选帧。
    liveDepthProvider: _liveCloudMedianDepthFor,
  );

  /// 最新一份**拍摄期流式**快照的点云(与 ARKit 同一重力世界系;带重力
  /// 旋转的 finalize 快照不进来 —— 那时自动拍早已结束)。开火位移阈值的
  /// 场景缩放只吃它,绝不吃 ARKit rawFeaturePoints(2026-08-24 定罪,见
  /// auto_capture_governor.dart 文件头)。
  Float32List? _liveCloudXyz;

  /// [_liveCloudMedianDepthFor] 的 1Hz 记忆化(场景中位深度秒级不突变,而 pose 流
  /// 是 20–60Hz —— 逐帧对几千点取中位数纯属浪费)。
  double? _liveSfmDepthMemo;
  Float32List? _liveSfmDepthMemoCloud;
  double _liveSfmDepthMemoAtSec = -1e9;

  /// 第一级:活体 SfM 云的中位深度。快照没到 / 点太少时返回 null。
  double? _liveCloudMedianDepthFor(ARPose pose) {
    if (!_liveReconReady) return null;
    final xyz = _liveCloudXyz;
    if (xyz == null) return null;
    if (identical(xyz, _liveSfmDepthMemoCloud) &&
        pose.timestamp - _liveSfmDepthMemoAtSec < 1.0) {
      return _liveSfmDepthMemo;
    }
    final forward = cameraForwardInWorld(pose.orientation);
    _liveSfmDepthMemo = medianDepthFromCloudXyz(
      xyz: xyz,
      cameraPosition: pose.position,
      forward: forward,
    );
    _liveSfmDepthMemoCloud = xyz;
    _liveSfmDepthMemoAtSec = pose.timestamp;
    return _liveSfmDepthMemo;
  }

  /// 自动采集的遥测聚合(spec §11 的待实测项)。**在内存里聚合**,按 5 秒
  /// 取一份累计快照走 [_emitAutoTelemetry] 落进既有的 JSONL —— pose 流
  /// 20–60 Hz,逐判定落盘就是 60 行/秒。判定逻辑一行都不在它里面。
  final AutoCaptureTelemetry _autoTelemetry = AutoCaptureTelemetry();

  /// controller 对**最近一帧**的判定,只用来驱动指示器的视觉状态。
  /// ⚠️ 绝不拿它反推"在不在跑":停机时 onPose 返回的就是 skipNotMoved,
  /// 与"你还没动够"逐字相同(见 [autoCaptureIndicatorFor] 的注释)。
  AutoCaptureDecision _lastAutoDecision = AutoCaptureDecision.skipNotMoved;

  /// 上一次已反映到 UI 的 `_autoCapture.isRunning`,**只用于**判断要不要
  /// setState —— pose 流是 20–60 Hz,每帧无条件 setState 会把整页重建成热源。
  bool _autoRunningLastSeen = false;

  /// 用户点了录制键、但还没等到下一帧 pose。
  ///
  /// 起跑帧**必须**是 pose 回调里的那一帧本身,不能用缓存的"最近一帧":
  /// `start()` 把 `pose.timestamp` 记成本轮起点,而 ARPose.timestamp 是
  /// ARFrame 时间轴(CACurrentMediaTime),与本页别处用的 DateTime.now()
  /// 根本不是一个纪元。缓存帧若因丢跟踪/暂停而陈旧,起点就落在过去,
  /// 5 分钟上限会被立刻判超。代价只是至多晚一帧(17–50 ms)起跑。
  bool _autoStartPending = false;

  /// 节流用,单位秒,取自 ARFrame 时钟(与 controller 同一条)。
  /// 本页别处的 DateTime.now() 是另一个纪元,混进来只会静默算错。
  double _autoIdleProbeLastSec = -1;

  /// 每落一帧 +1,驱动录制键脉冲一次(spec §8:落帧脉冲,不出文案)。
  int _autoFirePulseToken = 0;

  /// 每次**用户主动**切到自动模式 +1,居中浮出一条 [kAutoCaptureOnToastText]
  /// (RS 的 "Auto Capture On")。进页面时的默认自动不算 —— 那不是一次切换。
  int _autoModeToastToken = 0;

  // ─── Capture-time streaming SfM (live sparse reconstruction) ──────
  // Worker handle + event plumbing. All heavy calls live in the worker
  // isolate (see sfm_live_recon.dart); this page only routes keyframe
  // feeds in and snapshots out. Null on the simulator (feature hidden).
  SfmLiveRecon? _sfmRecon;
  StreamSubscription<OfficialHighResReconstructionInput>? _sfmFeedSub;
  StreamSubscription<SfmLiveEvent>? _sfmEventSub;
  StreamSubscription<OfficialHighResCaptureFailureEvent>? _highResFailureSub;
  final List<OfficialHighResReconstructionInput> _pendingSfmInputs =
      <OfficialHighResReconstructionInput>[];

  /// Live reconstruction health is deliberately separate from camera
  /// admission. The worker may degrade or restart without revoking a valid
  /// 12 MP capture session or trapping the user on the capture route.
  bool _sfmStarting = false;
  String? _sfmStartFailureText;
  SfmTerminalGate _sfmProcessingTerminalGate = SfmTerminalGate();

  bool get _captureAdmissionOpen =>
      _finishCoordinator.captureAdmissionOpen &&
      _recording &&
      !_cameraResumeFailed;

  bool get _finishAllowed =>
      _finishCoordinator.captureAdmissionOpen && _recording && _session != null;

  bool get _liveReconReady =>
      !_sfmStarting && _sfmStartFailureText == null && _sfmRecon != null;

  /// Non-null while the post-capture preview overlay is showing.
  SfmPreviewPhase? _sfmPhase;

  /// The COLORED cloud shown in the overlay. Set only after colorization
  /// completes, so the user never sees a gray-then-color flash — geometry and
  /// true color land together.
  SfmLiveSnapshot? _sfmSnapshot;

  /// The latest colorless snapshot handed to the colorizer. Colorization keys
  /// its supersession + display off this (not `_sfmSnapshot`, which is the
  /// already-colored result), so a stale colorize pass can't clobber a newer one.
  SfmLiveSnapshot? _colorizeTarget;

  /// L2 渲染门可见性(ghost_view_filter.dart),与 [_sfmSnapshot] /
  /// 终态快照的点序逐位对齐;null = 全显示。RENDER-ONLY:
  /// 只喂 SfmPreviewOverlay → SparseCloudView,persist/导出永远看不到。

  String? _sfmErrorText;
  int _sfmFed = 0;
  int _sfmQueued = 0;

  // ─── 修1【等待页阶段透明化】────────────────────────────────────────
  // 队列清空后后台还有 4 个分钟级阶段(真机实测 phase1 就要 ~113s),
  // 旧文案"帧队列已清空 · 正在生成最终点云"让用户以为卡死。这里按真实
  // 事件推进阶段文案并每秒刷新已耗时。只驱动 progressText,不改等待页
  // 结构/返回/完成逻辑。
  // 0 = 未进入阶段流(队列还在排空);1 = phase1 整理帧数据(finalize
  // 已下发→SfmLiveFinalizePhase1Done);2 = phase2 后台全局优化(→
  // refined 快照);3 = 提取色彩(colorize);4 = 保存点云(persist)。
  int _sfmFinalizeStage = 0;

  /// 当前阶段的起始时刻(epoch ms),等待页显示"已 Xs"用。
  int _sfmStageStartMs = 0;

  /// 等待页计秒刷新(1s)。只在 generating 阶段运行,terminal 即停。
  Timer? _sfmStageTicker;

  /// The finish flow wants to pop to Drafts, but the preview overlay owns
  /// the exit while it's up — set, then honoured by [_onSfmPreviewDone].

  /// The waiting UI can be folded into Drafts without popping this route.
  /// Keeping the route mounted is what keeps the worker, queue and final
  /// snapshot alive for a later task-card tap.
  bool _showDraftsWhileReconstructing = false;
  bool _draftRecordActionInProgress = false;
  bool _draftTerminalExitScheduled = false;
  final ReconstructionRouteReleaseGate _routeReleaseGate =
      ReconstructionRouteReleaseGate();
  Future<void>? _sfmReleaseFuture;

  /// Capture directory used as the idempotency key for the one iOS continued-
  /// processing task protecting this user-triggered final reconstruction.
  String? _reconUmbrellaJobID;

  // ─── RS-style capture-coverage cloud (Dart-owned policy) ──────────
  // Empty until the first committed shutter; every photo frustum-marks the
  // VIO voxel cloud and the covered points render red→yellow→green by how
  // many photos saw them. Policy lives in capture_coverage_cloud.dart
  // (cross-platform); native only displays what we push.
  final CaptureCoverageCloud _coverageCloud = CaptureCoverageCloud();
  StreamSubscription<AcceptedPhotoRecord>? _canonicalPhotoCommitSub;

  /// The last globally-BA-refined official SfM cloud published to AR.
  /// Capture coverage voxels remain a private guidance signal; the native
  /// renderer receives nothing before V20 and only stable SfM versions after.
  CoverageCloudPacked? _officialSfmArCloud;
  LiveCloudTelemetryTag? _officialSfmDiagnosticTag;
  final LiveCloudTelemetrySequencer _liveCloudTelemetry =
      LiveCloudTelemetrySequencer();

  // ─── [ENGINE-DRAFT 2026-08-09 用户签"第1张就要出云"] ─────────────────
  // 引擎草稿云:第 1 张快门后、SfM 云(配对草稿/正式)到达前,把 ARKit VIO
  // 特征点的 voxel 累积(_previewModel,已有取色与多尺度 hash)推给同一条
  // setCoveragePointCloud 显示通道。纯显示层:一个点都不进重建。快门前零
  // 显示(用户签);SfM 云一到,_pushCoverageCloud 的优先级自动让位。
  CoverageCloudPacked? _engineDraftCloud;
  int _engineDraftLastBuildMs = 0;
  static const int _engineDraftMinObservations = 3; // v0 配方:≥3 次晋升
  static const int _engineDraftMaxPoints = 20000;
  static const int _engineDraftThrottleMs = 500;

  // ── [ADAPTIVE-FPS 2026-08-10 用户签] 取景帧率热自适应(跨端策略层)──
  // 苹果自带热降帧要等到真热才动;这里更早出手:fair 持续 ≥10s → 30fps,
  // 回 nominal 持续 ≥30s → 回 60fps(滞回防抖)。取景流不进重建(重建只吃
  // 快门 12MP 静照),纯功耗刀,目标=把 serious(帧税 3.5×)推得更远。
  // 执行器各端一个薄调用(iOS=setPreviewFps 会话内调帧间隔,跟踪不断;
  // Android ARCore/鸿蒙待接,能力差异实测申报)。
  // env OFFICIAL_AETHER_ADAPTIVE_FPS=0(launch)可关。
  static final bool _adaptiveFpsEnabled =
      Platform.environment['OFFICIAL_AETHER_ADAPTIVE_FPS'] != '0';
  Timer? _adaptiveFpsTimer;
  int _adaptiveFpsCurrent = 60;
  int _adaptiveHotSinceMs = 0;
  int _adaptiveCoolSinceMs = 0;
  bool _matcherCaptureActive = false;

  /// The page-level camera lifecycle is the sole production writer of the
  /// native matcher yield flag. Reconstruction and native AR adapters may
  /// observe this boundary, but cannot change it independently.
  void _setMatcherCaptureActive(bool active) {
    if (_matcherCaptureActive == active) return;
    _matcherCaptureActive = active;
    AetherMatchFlags.setCaptureActive(active);
  }

  void _adaptiveFpsTick() {
    if (!_adaptiveFpsEnabled) return;
    final tel = PwTelemetry.sample();
    if (tel == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final hot = tel.thermalState >= 1; // fair 即算热(比苹果更早)
    if (hot) {
      _adaptiveCoolSinceMs = 0;
      _adaptiveHotSinceMs = _adaptiveHotSinceMs == 0
          ? now
          : _adaptiveHotSinceMs;
      if (_adaptiveFpsCurrent != 30 && now - _adaptiveHotSinceMs >= 10000) {
        _adaptiveSetFps(30, tel.thermalState);
      }
    } else {
      _adaptiveHotSinceMs = 0;
      _adaptiveCoolSinceMs = _adaptiveCoolSinceMs == 0
          ? now
          : _adaptiveCoolSinceMs;
      if (_adaptiveFpsCurrent != 60 && now - _adaptiveCoolSinceMs >= 30000) {
        _adaptiveSetFps(60, tel.thermalState);
      }
    }
  }

  void _adaptiveSetFps(int fps, int thermal) {
    _adaptiveFpsCurrent = fps;
    // [YIELD-FPS-LINK] 匹配器让路档随帧率联动(30fps=让路减半)。
    AetherMatchFlags.setPreviewFps30(fps <= 30);
    DeviceLog.log(
      'OfficialARCapturePage',
      'adaptive-fps: → ${fps}fps (thermal=$thermal)',
    );
    unawaited(
      _arKitChannel
          .invokeMethod<bool>('setPreviewFps', {'fps': fps})
          .then((ok) {
            if (ok != true) {
              DeviceLog.log(
                'OfficialARCapturePage',
                'adaptive-fps: 执行器拒绝 fps=$fps(能力申报)',
              );
            }
            return null;
          })
          .catchError((_) => null),
    );
  }

  // ── [AF-SELFHEAL 2026-08-10 用户签] 失焦死锁自愈(无 UI 零操作)─────
  // 病灶:糊掉的低纹理画面无相位信号无反差梯度 → 连续 AF 收不到失焦证据
  // 不触发扫描(健身房实测 10s+)。判定(跨端同式,各端只执行 focusNudge):
  // 持续糊 ≥1.8s(sharpnessConsensus<100,6Hz 画质样本)且相机基本静止
  // (500ms 窗口 <6cm/<6°)且距上次 ≥5s → 踢一脚中心单次对焦。
  int _afBlurSinceMs = 0;
  int _afLastNudgeMs = 0;
  Vector3? _afPrevPos;
  Quaternion? _afPrevOrient;
  int _afPrevPoseMs = 0;

  void _afSelfHealCheck(ARPose p) {
    final now = DateTime.now().millisecondsSinceEpoch;
    bool stationary = false;
    final prevPos = _afPrevPos;
    final prevOri = _afPrevOrient;
    if (prevPos != null && prevOri != null && now - _afPrevPoseMs <= 900) {
      final moved = (p.position - prevPos).length;
      final dot =
          (p.orientation.w * prevOri.w +
                  p.orientation.x * prevOri.x +
                  p.orientation.y * prevOri.y +
                  p.orientation.z * prevOri.z)
              .abs()
              .clamp(0.0, 1.0);
      final angle = 2 * math.acos(dot);
      stationary = moved < 0.06 && angle < 0.10;
    }
    if (now - _afPrevPoseMs > 400) {
      _afPrevPos = p.position.clone();
      _afPrevOrient = Quaternion.copy(p.orientation);
      _afPrevPoseMs = now;
    }
    final q = p.quality;
    if (q == null) return;
    final blurred = q.sharpnessConsensus < 100.0;
    if (!blurred) {
      _afBlurSinceMs = 0;
      return;
    }
    if (!stationary) return; // 移动中的糊是运动模糊,不踢
    _afBlurSinceMs = _afBlurSinceMs == 0 ? now : _afBlurSinceMs;
    if (now - _afBlurSinceMs >= 1800 && now - _afLastNudgeMs >= 5000) {
      _afLastNudgeMs = now;
      _afBlurSinceMs = 0;
      DeviceLog.log(
        'OfficialARCapturePage',
        'af-selfheal: nudge fired '
            '(sharpC=${q.sharpnessConsensus.toStringAsFixed(0)})',
      );
      unawaited(
        _arKitChannel
            .invokeMethod<bool>('focusNudge')
            .then((_) => null)
            .catchError((_) => null),
      );
    }
  }

  void _maybePushEngineDraft() {
    if (!_recording || _projectPhotos.count < 1) return;
    final sfm = _officialSfmArCloud;
    if (sfm != null && sfm.xyz.isNotEmpty) return; // SfM 云已接管显示
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _engineDraftLastBuildMs < _engineDraftThrottleMs) return;
    _engineDraftLastBuildMs = nowMs;
    // voxels getter 已按 observations 降序 —— 截断即"最稳的前 N 个"。
    final voxels = _previewModel.voxels;
    var n = 0;
    for (final v in voxels) {
      if (v.observations >= _engineDraftMinObservations) n++;
      if (n >= _engineDraftMaxPoints) break;
    }
    if (n == 0) return;
    final xyz = Float32List(n * 3);
    final rgb = Uint8List(n * 3);
    var i = 0;
    for (final v in voxels) {
      if (v.observations < _engineDraftMinObservations) continue;
      final base = i * 3;
      xyz[base] = v.position.x;
      xyz[base + 1] = v.position.y;
      xyz[base + 2] = v.position.z;
      // [2026-08-09 用户签决"全部都是白色"] 草稿云原取体素真彩(相机采样均值),
      // 与 SfM 云统一改白 —— 不然开头几秒彩色、SfM 云一到全白,肉眼一跳。
      rgb[base] = 255;
      rgb[base + 1] = 255;
      rgb[base + 2] = 255;
      i++;
      if (i >= n) break;
    }
    _engineDraftCloud = CoverageCloudPacked(xyz, rgb);
    _scheduleCoveragePush();
  }

  // ─── "拍摄角度不足"实时横幅(补强1,真值口径)───────────────────────
  // starvedTrue(观测达标但真实三角化角低于 parallaxMinDeg=5° 的体素数,
  // 2026-07-11 阈值校准 8°→5°)持续 ≥20 → 顶部
  // 非阻塞横幅提示绕行补拍;回落 <10(滞回)自动隐藏。去抖/滞回状态机在
  // parallax_banner_gate.dart(纯 Dart,tool/parallax_banner_check.dart
  // 断言);采样**不加新计时器**,挂在既有的 markCapture 回调
  // (_onCoverageKeyframe)与 SfmLiveTrueParallax 事件上。
  final StarvedParallaxBannerGate _starvedBannerGate =
      StarvedParallaxBannerGate();
  bool _starvedBannerVisible = false;

  // ─── 拥塞遥测标签(07-12 签决:快门彻底不限流)──────────────────────
  // 快门永不因队列深度/thermal 被阻挡——积压走 sfm_live_recon 的磁盘 spool
  // 队列(不丢帧、不爆内存),热保护由 native 热调速器透明承担。这里只保留
  // 一个**纯观测**标签(shutter_backpressure_gate.shutterPaceNext:队列 +
  // thermal → normal/soft/hard 三级),转换时记一行 `shutter_pace` 遥测便于
  // 事后画积压曲线;绝不 gate 快门、不置灰、不弹横幅。
  ShutterPace _shutterPace = ShutterPace.normal;

  /// 最近一次采到的 thermal 桶(0 nominal · 1 fair · 2 serious · 3 critical;
  /// **-1 = 未知**,与 `_recomputeShutterPace` 里的降级口径同源)。
  ///
  /// 只喂**自动拍**的 tick 间隔(spec §7「热态 critical 只拉长间隔、不停止」,
  /// 兑现在 `autoCaptureTickIntervalSec`)。手动快门一个字节不受影响 ——
  /// 07-12 签决的「快门彻底不限流」不变。
  ///
  /// 为什么缓存而不是每个 pose 现采:`PwTelemetry.sample()` 是一次 FFI +
  /// 三个 native 指针的分配/释放,而 pose 流是 20–60 Hz;
  /// [_recomputeShutterPace] 本来就在每次高清照落地与每次 SfM 队列事件上
  /// 采一次(自动拍跑起来至少 1 Hz),而机温是分钟级的量,这个刷新率足够。
  int _lastThermalState = -1;

  /// 遥测【WAIT-BUDGET 2026-07-29】上一次快门的 epoch ms。
  ///
  /// 用户签决「可忍受发热,不可忍受等待变长」后,**快门间隔是整笔账的分母**:
  /// 流式 SfM 的逐帧成本(host 实测 A=760ms/帧、候选 K30 臂=1144ms/帧)只有
  /// 低于用户实际的按快门间隔时才对用户隐形。这个分母我们**从来没量过**,
  /// 没有它就无法判断 K30 的 +384ms/帧 是被完全吸收还是变成欠债。
  /// `shutter` 事件本身带 `t`,理论上可事后差分,但失败/被拒的快门不写事件,
  /// 差分会把它们静默算成"用户拍得慢",故记成一等字段。
  int _lastShutterMs = 0;

  // ─── AR 照片卡片四态边框(黑/白/红/黄,判定全在 Dart)──────────────
  // 状态机在 photo_card_state.dart;native(AetherARKitPlugin 的
  // setPhotoCardStates)只收 jpegPath→channelValue 做哑渲染。事件驱动:
  // SfmLiveConnectivity(拍摄期合成连通性)/ finalize 快照(真值)/
  // markCapture(视差中位数变化)三处触发差量刷新,不轮询。

  /// 最新一份 posesPacked。拍摄期 = worker 的合成连通性(只有
  /// [frameId, registered] 有效);finalize 快照到达后 = COLMAP 真值。
  Float64List _sfmLatestPoses = Float64List(0);

  /// Route B(真实三角化角):worker 的 SfmLiveTrueParallax 事件带来的
  /// "frameId → 该帧观测点真实三角化角中位数(度)"。判黄**只用真值**
  /// (photo_card_state.frameLowParallaxTrue):真值未到达的已注册帧保持
  /// 黑(处理中),视锥近似已彻底退出卡片判定(白→黄反序修复);4°/6°
  /// 滞回消黄白抖动。合并式 upsert:本次没被采样到的帧保留旧值。
  final Map<int, double> _trueFrameParallaxDeg = <int, double>{};

  /// 白态粘性(防动态污染):frameId → 连续低于白→黄 enter 阈(4°)的
  /// 真值**采样**次数(photo_card_state.frameBelowEnterStreak 维护,只在
  /// SfmLiveTrueParallax 采样到达时更新 —— 状态机刷新不计数,否则同一份
  /// 陈旧采样会被重复计数)。已白帧需连续 2 次采样跌破 enter 阈才转黄,
  /// 消"点云长大时一批新低视差点瞬间拉低中位"的单次抖动。
  final Map<int, int> _frameBelowEnterStreak = <int, int>{};

  /// Route B:最近一次 worker 真实视差聚合耗时(ms;-1=尚未到达)。
  /// 遥测【guidance】行随行携带,便于真机对 SLA 直接对数。
  int _trueParallaxComputeMs = -1;

  /// 已推送给 native 的每卡状态(jpegPath → channelValue),差量推送用。
  final Map<String, int> _photoCardStateSent = <String, int>{};

  // ─── 遥测(真机验收显微镜,telemetry_official_dart.jsonl)───────────
  /// 【tracking】上一次见到的 ARKit trackingStateName —— 变化才记一行。
  String? _telemLastTrackingState;

  /// 【card】jpegPath → 拍摄时刻(epoch ms):卡片状态变化行回填
  /// "距拍摄延迟"。_onCoverageKeyframe(每次快门的既有回调)顺手记。
  final Map<String, int> _photoCaptureEpochMs = <String, int>{};
  final Set<String> _failedEvidenceJpegPaths = <String>{};

  /// 【guidance】5s 节流采样定时器(拍摄中运行,完成/退出即停)。
  Timer? _guidanceTelemetryTimer;

  /// 覆盖云推送合并节流(65k 提额,2026-07-11):满载 packed+编码
  /// ≈975KB/次,快门与真值注入同秒到达时 leading edge 立即推、400ms
  /// 窗口内的后续变更合并成一次 trailing 推。
  Timer? _coveragePushTimer;
  bool _coveragePushPending = false;

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
    _shutterQueue = ManualCaptureQueue(
      maxTickets: kOfficialMaximumCaptureFrames,
      execute: _executeShutterTicket,
      onError: _onShutterTicketError,
    );
    WidgetsBinding.instance.addObserver(this);
    // Capture reconstruction runs on-device via streaming SfM (see
    // _startSfmLiveRecon) plus server-side recon on upload — no local model
    // download gate. The App Store install bundle stays small (~80 MB).
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
      // [pw 2026-09-22] VIO 消费层接线点。
      //
      // 🔴 `PwVioPoseSourceSwitch.current` 默认是 `arkit` ⇒ `poseProvider`
      //    传 `null` ⇒ `CaptureSession` 内部照旧 `PlatformARPoseProvider()`。
      //    也就是说**出货包里这一行与之前逐位等价**(而且 iOS 的
      //    `--dart-define` 到不了 xcconfig 链,见
      //    `lib/vio/pose/vio_pose_source_switch.dart` 文件头 ——
      //    这个开关在出货 iOS 上物理上就打不开)。
      //
      // 🔴 铁律:「没全面持平/超越 ARKit 之前绝不上生产」。这里接的是
      //    **契约与管线**,不是换生产位姿源。ON 这条臂目前连喂料都不通
      //    (ARKit 独占相机),见 `vio_ar_pose_provider.dart` 的「已知缺口」。
      final vioProvider = PwVioPoseSourceSwitch.isSelfVio
          ? VioArPoseProvider()
          : null;
      _vioPoseProvider = vioProvider;
      // 可信度与位姿一起带出来。ARKit 路径下 vioProvider == null ⇒ 不订阅。
      _vioConfidenceSub = vioProvider?.confidenceStream.listen((c) {
        if (!mounted) return;
        final previous = _vioConfidence;
        _vioConfidence = c;
        // 只在档位变化时打一行 —— 整场通常 < 10 行。
        // 🔴 不 setState、不进 UI:UX 由用户定,本次只接契约。
        if (previous?.tier != c.tier ||
            previous?.mayReportAbsoluteDimensions !=
                c.mayReportAbsoluteDimensions) {
          debugPrint('[vio-consume] confidence → $c');
        }
      });
      final session = CaptureSession(
        targetPoints: _targetPoints,
        poseProvider: vioProvider,
      );
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
        _previewModel.updateFromPose(p, photoCount: _projectPhotos.count);
        // [AF-SELFHEAL] 失焦死锁自愈判定(取景与拍摄全程生效)。
        _afSelfHealCheck(p);
        // [ENGINE-DRAFT] 第 1 张后、SfM 云到达前的引擎草稿推送(内部自带
        // 节流与让位判断,SfM 云接管后是纯 no-op)。
        _maybePushEngineDraft();
        // Coverage-cloud position upkeep — never lights points up by itself
        // (only markCapture at each shutter does).
        _coverageCloud.ingestPose(p);
        // 遥测【tracking】:ARKit tracking state 变化事件(既有 pose 流顺手
        // 记,只在字符串变化时写一行 —— 正常拍摄整场 <10 行)。
        final tsName = p.trackingStateName;
        if (tsName != null && tsName != _telemLastTrackingState) {
          TelemetryWriter.instance.event('tracking', {
            'state': tsName,
            'prev': _telemLastTrackingState,
          });
          _telemLastTrackingState = tsName;
        }
        _checkArWarmup(p);
        // ─── 自动采集(spec §5.4)。**唯一**的驱动源就是这条 pose 流。
        // 不新起 Timer:elapsedSec / sinceLastTickSec 都是 ARPose.timestamp
        // 的差(ARFrame 时间轴 = CACurrentMediaTime,自开机秒数),而本页
        // 别处用的是 DateTime.now().microsecondsSinceEpoch —— 两个纪元混用
        // 什么都不会抛,只会把 tick 与时间上限的时钟静默算错。
        _driveAutoCapture(p);
      });
      await session.attach();
      // [ADAPTIVE-FPS] 策略时钟(5s 轮询,页面生命周期内)。
      _adaptiveFpsTimer ??= Timer.periodic(
        const Duration(seconds: 5),
        (_) => _adaptiveFpsTick(),
      );
      // 遥测【resource】:拍摄页进入 → 通知 Swift 起 10s 资源采样
      // (thermal/footprint/电池/CPU/SceneKit FPS →
      // telemetry_official_native.jsonl)。
      try {
        await _arKitChannel.invokeMethod<void>('telemetryCaptureBegin');
      } catch (_) {}
      if (!mounted) {
        await session.dispose();
        return;
      }
      setState(() {
        _session = session;
        _initializing = false;
      });
      // The pose stream is subscribed before attach completes. A healthy pose
      // can therefore win the race, mark warmup complete, and attempt manual
      // startup while `_session` is still null. Retry from the other side of
      // the rendezvous once the attached session has been published; otherwise
      // the fallback sees warmup=true and the shutter stays disabled forever.
      if (_arWarmupComplete) {
        unawaited(_startManualCapture());
      } else {
        _armArWarmupFallback();
      }
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
    // BGContinuedProcessingTask's system card foregrounds the app but does not
    // expose a distinct Dart tap callback. While this route owns an active job,
    // any foreground return restores its waiting page. The in-app draft card
    // below provides the exact same transition without backgrounding.
    if (state == AppLifecycleState.resumed &&
        _sfmPhase != null &&
        _showDraftsWhileReconstructing &&
        !_draftRecordActionInProgress &&
        mounted) {
      setState(() => _showDraftsWhileReconstructing = false);
    }
    if (_session == null) return;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      // TRUE background — release the camera so the OS doesn't kill us, but do
      // NOT finalize: keep the in-progress capture (session stays `_started`,
      // photos intact) so the album survives a background round-trip.
      // `inactive` is TRANSIENT (screenshot, control center, notification) and
      // must NOT release/finalize, or the album resets on a screenshot.
      //
      // 自动拍在这里**停止,而不是暂停**(spec §7)。下面 resumed 分支走的
      // _restartArSessionAfterResume → native startSession{'resume': true} →
      // session.run(configuration),ARKit **可能重定位世界原点**;一个活过
      // 后台的基准帧此后指向的是一个不再存在的坐标系,回来第一帧就会拿垃圾
      // 开火。resumed 分支**刻意不自动重开** —— 由用户再点一次录制键。
      _stopAutoCapture();
      _pauseArForBackground();
    } else if (state == AppLifecycleState.resumed) {
      // Only re-open the camera if a capture is still ACTIVE. Once the finish
      // flow stopped the camera for the SfM preview/finalize (camera off to
      // free GPU/memory for the solve), a background round-trip must NOT
      // reopen it — the preview overlay has no use for the camera.
      if (_captureAdmissionOpen && _sfmPhase == null) {
        _restartArSessionAfterResume();
      }
    }
  }

  Future<void> _pauseArForBackground() async {
    // Release only the camera; leave the Dart CaptureSession started and its
    // retained photos untouched so resume continues the same capture.
    final session = _session;
    if (session == null) return;
    try {
      await session.suspendCameraTransport();
      _setMatcherCaptureActive(false);
    } catch (_) {}
  }

  Future<void> _restartArSessionAfterResume() async {
    final now = DateTime.now();
    final last = _lastArSessionResumeAt;
    if (last != null &&
        now.difference(last).inMilliseconds < 1200 &&
        !(_session?.manualCaptureTransactionsSuspended ?? false)) {
      return;
    }
    _lastArSessionResumeAt = now;
    try {
      // The provider keeps the logical world and native anchors while its
      // platform transport resumes.
      await _session?.resumeCameraTransport();
      _setMatcherCaptureActive(true);
      _cameraResumeFailed = false;
      if (_captureAdmissionOpen && !_shutterQueue.accepting) {
        _shutterQueue.resume();
      }
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
      _shutterQueue.cancelPending();
      _session?.failSuspendedManualCaptureTransactions(e);
      _cameraResumeFailed = true;
      if (mounted) {
        setState(() {
          _captureQueueFailureText = '相机恢复失败；已停止等待中的拍摄，请重试或退出。';
        });
      }
      if (_kDiagLog) {
        // ignore: avoid_print
        print('[CapturePage] ARSession resume restart skipped: $e');
      }
    }
  }

  Future<void> _stopRecordingIfRunning() async {
    if (!_recording) return;
    await _finalizeRecording(navigateToDrafts: true, showSparseHint: false);
  }

  Future<void> _onCloseTap() async {
    if (_lockInProgress || _confirmationDialogOpen) return;
    if (!_finishCoordinator.captureAdmissionOpen) return;
    if (!_recording) {
      if (mounted) Navigator.of(context).maybePop(false);
      return;
    }

    _confirmationDialogOpen = true;
    try {
      // [2026-08-22 用户签决] 黑白弹窗 + 开关:"是否保存照片,方便下次补拍"
      // 的小开关(默认开=绿=保存,关=红=不保存)+ "确定"/"取消" 两颗按钮。
      // (取代 2026-08-09 那版滑轴 —— 见 capture_exit_dialog.dart 文件头。)
      // 返回值语义不变:saveExit / discardExit / null=回拍摄。
      // Confirmation is deliberately non-mutating. Auto capture, the current
      // ticket, matcher state, and camera all remain exactly as they were if
      // the user cancels.
      final hasAcceptedPhotos =
          _projectPhotos.count + _shutterQueue.outstandingCount > 0;
      final choice = hasAcceptedPhotos
          ? await showCaptureExitDialog(context)
          : CaptureExitChoice.discardExit;
      if (!mounted || choice == null) return;
      await _commitCaptureExit(
        disposition: choice == CaptureExitChoice.saveExit
            ? _CommittedCaptureExit.saveDraft
            : _CommittedCaptureExit.discard,
        navigateToDrafts: choice == CaptureExitChoice.saveExit,
        showSparseHint: false,
      );
    } finally {
      _confirmationDialogOpen = false;
    }
  }

  Future<void> _onCenterTap() async {
    final session = _session;
    if (session == null) return;

    if (_recording) {
      await _onFinishTap();
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
        _startVioShadowForCapture();
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
      _startVioShadowForCapture();
      if (!mounted) return;
      // Fresh take → clear any anchored AR cards left from a previous session.
      try {
        await _arKitChannel.invokeMethod<void>('clearPhotoCards');
      } catch (_) {}
      // T6: turn on the live sparse coverage cloud for this take (RS-style —
      // ARKit feature points, world-anchored, coloured by coverage)。尊重
      // 用户显示开关:开关关着就保持隐藏(数据照常计算)。
      try {
        await _arKitChannel.invokeMethod<void>(
          'setFeaturePointsVisible',
          <String, dynamic>{'visible': _coverageDotsVisible},
        );
      } catch (_) {}
      _previewModel.reset();
      _projectPhotos.clear();
      _captureQueueFailureText = null;
      _cameraResumeFailed = false;
      // Fresh take → empty coverage cloud (0 photos ⇒ 0 dots on screen).
      _coverageCloud.reset();
      _officialSfmArCloud = null;
      _officialSfmDiagnosticTag = null;
      _engineDraftCloud = null;
      _engineDraftLastBuildMs = 0;
      // Fresh take → 卡片边框状态机归零(native 卡片已由 clearPhotoCards
      // 清掉,这里清 Dart 侧差量缓存与连通性数据)。
      _photoCardStateSent.clear();
      _photoCaptureEpochMs.clear();
      _failedEvidenceJpegPaths.clear();
      _automaticTicketByTransaction.clear();
      _automaticControllerReceiptTransactions.clear();
      _controllerProjectedTransactions.clear();
      _sfmLatestPoses = Float64List(0);
      // Fresh take → 上一场的活体云深度不许被下一场继承(换场景了)。
      _liveCloudXyz = null;
      _liveSfmDepthMemo = null;
      _liveSfmDepthMemoCloud = null;
      _trueFrameParallaxDeg.clear();
      _frameBelowEnterStreak.clear();
      _trueParallaxComputeMs = -1;
      // 补强1:starved 横幅门与覆盖云同时机归零(下方 setState 会重建)。
      _starvedBannerGate.reset();
      _starvedBannerVisible = false;
      TelemetryWriter.instance.event('live_cloud_diag_build_v1', {
        'contract': liveCloudDiagnosticContractId,
        'dart_build_id': liveCloudDiagnosticDartBuildId,
        'product_manifest_source': liveCloudDiagnosticProductManifestSource,
        'observation_only': true,
      });
      // force:新一轮拍摄的归零推送必须落到 native,不能被去重门挡掉。
      unawaited(_pushCoverageCloud(force: true));
      _canonicalPhotoCommitSub ??= session.canonicalPhotoCommitStream.listen(
        (record) => unawaited(_projectCanonicalPhoto(session, record)),
      );
      unawaited(
        session.replayCanonicalPhotoProjections(
          handlers: <AcceptedPhotoProjection, AcceptedPhotoProjectionHandler>{
            AcceptedPhotoProjection.controller: _applyCanonicalPhotoController,
          },
        ),
      );
      // [SPRINT-FIX + YIELD-FPS-LINK] 新一轮拍摄:框架内匹配器旗复位。
      _setMatcherCaptureActive(true);
      AetherMatchFlags.setPreviewFps30(_adaptiveFpsCurrent <= 30);
      _sfmProcessingTerminalGate = SfmTerminalGate();
      setState(() {
        _recording = true;
        _sfmStarting = true;
        _sfmStartFailureText = null;
        _isAiming = false;
        _lockInProgress = false;
      });
      // [2026-07-27 UI 签决] 开拍即弹的"20 张"入场提示已删除 —— 每次进
      // 拍摄都挡一次取景框、说的又是用户还没到的事。同一句提示改在真正
      // 相关的时刻出现:不足 20 张点完成时的 _onFinishTap 对话框。
      _startGuidanceTelemetry();
      // Capture-time streaming SfM is required for a valid product take.
      // Await only worker startup (not reconstruction); controls remain
      // disabled while the native lease/session is being acquired.
      await _startSfmLiveRecon(session);
    } catch (e) {
      // ignore: avoid_print
      print('[OfficialARCapturePage] manual capture start failed: $e');
    }
  }

  void _startVioShadowForCapture() {
    if (!kVioShadowEnabled) {
      DeviceLog.log('VioDiag', 'PW_VIO_SHADOW=off ⇒ 本场影子 VIO 不启动（单变量对照组）');
      return;
    }
    unawaited(() async {
      try {
        await VioDiagnosticsRecorder.instance.start();
        DeviceLog.log('VioDiag', 'capture shadow lifecycle started');
      } catch (e) {
        DeviceLog.log('VioDiag', 'capture shadow start failed: $e');
      }
    }());
  }

  Future<void> _stopVioShadowForCapture() async {
    if (!kVioShadowEnabled) return;
    await VioDiagnosticsRecorder.instance.stop();
    DeviceLog.log('VioDiag', 'capture shadow terminal receipt flushed');
  }

  void _stopVioShadowInBackground() {
    unawaited(
      _stopVioShadowForCapture().catchError((Object error, StackTrace stack) {
        DeviceLog.log(
          'VioDiag',
          'capture shadow terminal cleanup failed: $error\n$stack',
        );
      }),
    );
  }

  Future<void> _projectCanonicalPhoto(
    CaptureSession session,
    AcceptedPhotoRecord record,
  ) async {
    try {
      final result = await session.projectCanonicalPhoto(
        transactionId: record.transactionId,
        projection: AcceptedPhotoProjection.controller,
        apply: _applyCanonicalPhotoController,
      );
      if (result.status != AcceptedPhotoProjectionStatus.deferred) return;
      DeviceLog.log(
        'OfficialARCapturePage',
        'canonical controller projection deferred '
            'transaction=${record.transactionId} code=${result.debt?.code}',
      );
    } catch (error, stackTrace) {
      // Stream delivery is intentionally unawaited. Keep its failure contained;
      // the canonical owner retains the durable record for replay.
      DeviceLog.log(
        'OfficialARCapturePage',
        'canonical controller projection callback failed '
            'transaction=${record.transactionId}: $error\n$stackTrace',
      );
    }
  }

  /// Page-owned projection of an already durable canonical membership row.
  /// This can never admit a JPEG; [projectCanonicalPhoto] stores its typed
  /// receipt/debt under the same transaction id.
  void _applyCanonicalPhotoController(AcceptedPhotoRecord record) {
    if (_controllerProjectedTransactions.contains(record.transactionId)) {
      return;
    }
    if (!_projectPhotos.applyCanonicalRecord(record)) {
      throw const AcceptedPhotoProjectionException(
        code: 'album_projection_missing',
        message: 'canonical record is absent from the album registry',
      );
    }
    if (record.automaticSelection &&
        !_automaticControllerReceiptTransactions.contains(
          record.transactionId,
        )) {
      final ticket = _automaticTicketByTransaction[record.transactionId];
      final grayBase64 = record.gray128Base64;
      if (ticket == null || grayBase64 == null) {
        throw const AcceptedPhotoProjectionException(
          code: 'automatic_controller_receipt_missing',
          message:
              'automatic canonical record has no matching controller receipt',
        );
      }
      final gray = Uint8List.fromList(base64Decode(grayBase64));
      final worldFromCamera = Matrix4.fromList(record.evidencePose);
      final acceptedStill = AcceptedAutomaticStill(
        frame: AutoCaptureGeometryFrame(
          camera: worldFromCamera.getTranslation(),
          orientation: Quaternion.fromRotation(worldFromCamera.getRotation()),
          intrinsics: AutoCaptureIntrinsics(
            fx: record.intrinsics[0],
            fy: record.intrinsics[1],
            cx: record.intrinsics[2],
            cy: record.intrinsics[3],
            imageWidth: record.imageWidth,
            imageHeight: record.imageHeight,
          ),
        ),
        captureTimestamp: record.captureTimestamp,
        gray128: gray,
      );
      if (!_autoCapture.resolveAutomaticStill(
        ticket: ticket,
        accepted: true,
        acceptedStill: acceptedStill,
      )) {
        throw const AcceptedPhotoProjectionException(
          code: 'automatic_controller_receipt_stale',
          message: 'automatic controller rejected the canonical transaction',
        );
      }
      _automaticControllerReceiptTransactions.add(record.transactionId);
      _automaticTicketByTransaction.remove(record.transactionId);
    }
    if (_finishCoordinator.captureRootTombstoned) {
      _controllerProjectedTransactions.add(record.transactionId);
      return;
    }
    final feed = SfmFrameFeed(
      gray: Uint8List(0),
      grayW: record.imageWidth,
      grayH: record.imageHeight,
      imageW: record.imageWidth,
      imageH: record.imageHeight,
      intrinsicFxFyCxCy: record.intrinsics,
      extrinsic4x4: record.cameraTransform,
      timestamp: record.captureTimestamp,
      jpegPath: record.jpegPath,
    );
    // 遥测【card】:记下每张照片的拍摄时刻(epoch ms),卡片状态变化行
    // 用它算"距拍摄延迟"。既有回调顺手记,零额外调用。
    final jp = feed.jpegPath;
    if (jp != null) {
      _photoCaptureEpochMs[jp] = DateTime.now().millisecondsSinceEpoch;
    }
    // 只在覆盖真的变化时才重打包+推送(markCapture 返回 false = 视锥
    // 没罩住任何体素,payload 没变);推送走 400ms 合并节流。
    if (_coverageCloud.markCapture(feed)) {
      _scheduleCoveragePush();
    }
    // 新照片刷新了体素 maxParallaxDeg → 已注册帧的黄/白可能翻转
    // (黄=低视差,补拍换角度后转白)。差量推送,无变化零开销。
    _refreshPhotoCardStates();
    _sampleStarvedBanner();
    _controllerProjectedTransactions.add(record.transactionId);
  }

  /// 补强1:starved 横幅采样。挂在既有回调上(markCapture 后 +
  /// SfmLiveTrueParallax 到达后),不新增计时器。只在可见性真的翻转时
  /// setState —— SfmLiveTrueParallax 处理路径刻意不 rebuild,这里保持
  /// 同样的克制(翻转是稀有事件)。
  void _sampleStarvedBanner() {
    if (!_recording) return;
    // 真值口径:coverageStats().starvedTrue(观测达标 + 真实三角化角
    // < parallaxMinDeg=5°),与【guidance】遥测的 starved_true 字段同源同义。
    final visible = _starvedBannerGate.onSample(
      _coverageCloud.coverageStats().starvedTrue,
    );
    if (visible != _starvedBannerVisible && mounted) {
      setState(() => _starvedBannerVisible = visible);
    }
  }

  /// 拥塞遥测标签采样(**纯观测,不阻挡快门**):队列深度(SfM facade 的
  /// remainingCount,与 `_sfmQueued` 同源)+ thermal 桶(pw_telemetry FFI,
  /// 微秒级)→ shutterPaceNext 得出新标签。挂在既有 SfM 队列事件与快门点按
  /// 上,零新增计时器;只在标签真的翻转时记一行 `shutter_pace` 遥测(翻转
  /// 是稀有事件)。[inSetState] = 调用点已在 setState 回调内,此时只改字段,
  /// rebuild 由外层 setState 完成,不嵌套(标签本身不改变任何可见 UI)。
  void _recomputeShutterPace({bool inSetState = false}) {
    final queue = _sfmRecon?.remainingCount ?? 0;
    final thermal = PwTelemetry.sample()?.thermalState ?? -1;
    // ⚠️ 记在**早退之前**:档位没翻转时这个函数就 return 了,而热态自己
    // 是会变的 —— 记在后面等于只在档位翻转的那几帧更新机温。
    // 这一行对手动快门是纯 no-op(没有任何手动路径读它)。
    _lastThermalState = thermal;
    final next = shutterPaceNext(
      previous: _shutterPace,
      queueDepth: queue,
      thermalState: thermal,
    );
    if (next == _shutterPace) return;
    final prev = _shutterPace;
    _shutterPace = next;
    TelemetryWriter.instance.event('shutter_pace', {
      'from': prev.name,
      'to': next.name,
      'queue': queue,
      'thermal': thermal,
    });
    DeviceLog.log(
      'OfficialARCapturePage',
      'shutter pace ${prev.name}→${next.name} (queue=$queue thermal=$thermal)',
    );
    if (!inSetState && mounted) setState(() {});
  }

  // ─── RS 复刻:快门上方两个独立显示开关(2026-07-19 用户规格)──────────
  // 都是 display-only:关闭只隐藏,不删照片/AR 锚点/拍摄记录/SfM 数据;
  // 拍照、覆盖率计算、点云更新、质量判断、重建全部照常;两开关相互独立。
  bool _photoCardsVisible = true; // 左:AR 照片卡片(照片图标)
  bool _coverageDotsVisible = true; // 右:彩色覆盖点(3×3 九点图标,恒黄)

  Future<void> _togglePhotoCards() async {
    setState(() => _photoCardsVisible = !_photoCardsVisible);
    try {
      await _arKitChannel.invokeMethod<void>(
        'setPhotoCardsVisible',
        <String, dynamic>{'visible': _photoCardsVisible},
      );
    } catch (_) {
      // Display-only channel — never let it disturb capture.
    }
  }

  Future<void> _toggleCoverageDots() async {
    setState(() => _coverageDotsVisible = !_coverageDotsVisible);
    try {
      await _arKitChannel.invokeMethod<void>(
        'setFeaturePointsVisible',
        <String, dynamic>{'visible': _coverageDotsVisible},
      );
    } catch (_) {}
    if (_coverageDotsVisible) {
      // 隐藏期 native 丢弃推送防旧云;重开必须立刻补推当前全量状态——
      // 用户规格:显示最新计算结果,不能等用户再拍一张才恢复。
      // force:native 侧已丢弃过,内容没变也必须重推。
      await _pushCoverageCloud(force: true);
    }
  }

  /// Ships the latest stable official SfM version to the native dumb renderer.
  /// Before the first successful 20-frame global BA this intentionally sends
  /// an empty cloud, even though private capture-guidance voxels already exist.
  /// The exact payload last handed to native, so an unchanged cloud is never
  /// re-marshalled. [AR-PERF 2026-07-26] eaf8706 repointed this from the
  /// capped coverage-voxel cloud (~188 pts/photo, 65k ceiling) to the uncapped
  /// official SfM cloud (~1.3k pts/frame): at 126 frames that is ~170k points,
  /// and every display-toggle / coverage-dot tap re-sent the identical buffer
  /// across the method channel. Copying that per push is what made the capture
  /// UI feel laggy late in a long take. The cloud object is replaced wholesale
  /// on each publish, so identity is a sound change test.
  CoverageCloudPacked? _pushedArCloud;

  Future<void> _pushCoverageCloud({
    bool force = false,
    LiveCloudTelemetryTag? diagnosticTag,
  }) async {
    // [ENGINE-DRAFT] 优先级:SfM 云(配对草稿/正式)> 引擎草稿 > 空。
    final packed =
        _officialSfmArCloud ??
        _engineDraftCloud ??
        CoverageCloudPacked(Float32List(0), Uint8List(0));
    if (!force && identical(packed, _pushedArCloud)) return;
    _pushedArCloud = packed;
    var tag = diagnosticTag;
    if (tag == null &&
        _officialSfmArCloud != null &&
        identical(packed, _officialSfmArCloud)) {
      tag = _officialSfmDiagnosticTag;
    }
    if (tag == null) {
      final now = DateTime.now().millisecondsSinceEpoch;
      tag = _liveCloudTelemetry
          .receive(
            source:
                _engineDraftCloud != null &&
                    identical(packed, _engineDraftCloud)
                ? 'engine_draft'
                : 'empty',
            publishVersion: 0,
            pointCount: packed.xyz.length ~/ 3,
            receiveEpochMs: now,
          )
          .withComputeDone(now);
      TelemetryWriter.instance.event('live_cloud_receive_v1', tag.baseFields);
    }
    final channel = _liveCloudTelemetry.channelSend(
      tag,
      channelSendEpochMs: DateTime.now().millisecondsSinceEpoch,
    );
    TelemetryWriter.instance.event(
      'live_cloud_channel_send_v1',
      channel.fields,
    );
    try {
      await _arKitChannel
          .invokeMethod<void>('setCoveragePointCloud', <String, dynamic>{
            'xyz': packed.xyz,
            'rgb': packed.rgb,
            ...tag.channelArguments(channelPushSequence: channel.pushSequence),
          });
      TelemetryWriter.instance.event('live_cloud_channel_ack_v1', {
        ...channel.fields,
        'channel_ack_t': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {
      TelemetryWriter.instance.event('live_cloud_channel_error_v1', {
        ...channel.fields,
        'channel_error_t': DateTime.now().millisecondsSinceEpoch,
      });
      // Display-only channel — never let it disturb capture. Forget the
      // payload so the next push retries instead of de-duplicating against a
      // send that never landed.
      _pushedArCloud = null;
    }
  }

  /// Atomically replaces the AR overlay with a globally refined official SfM
  /// snapshot. This is display-only: no point is removed or rewritten in the
  /// reconstruction or final PLY.
  Future<void> _publishOfficialSfmCloudToAr(
    SfmLiveSnapshot snapshot,
    LiveCloudTelemetryTag receiveTag,
  ) async {
    // [AR-EVERY-FRAME 2026-08-04] 接受两种拍摄期流式 source:检查点的
    // 'streaming_global_ba'(既有),以及每帧的 'streaming_local_ba_live'(实验臂
    // OFFICIAL_AETHER_AR_EVERY_FRAME=1 时才由生产端发出)。env 关时后者永不
    // 到达,故此处放开对现状零影响(逐字节复现)。注意用 '_live' 后缀,
    // 与 finish-time 终态云的 'streaming_local_ba' 严格区分。两种都是
    // display-only,不删改重建或最终 PLY。
    final source = snapshot.summary['source'];
    if (!_recording ||
        (source != 'streaming_global_ba' &&
            source != 'streaming_local_ba_live')) {
      return;
    }
    if (snapshot.pointCount <= 0) {
      // [ENGINE-DRAFT 2026-08-09] 删照片把 live 模型删空(3→2→1)时,worker
      // 的 frame_removed 推送会带 0 点 —— 此前这里直接 return,屏幕会留着
      // 删除前的旧云。现在:清掉 SfM 云占位,让 _pushCoverageCloud 落回
      // 引擎草稿(还有照片时)或空(全删光)。
      if (snapshot.summary['frame_removed'] != null) {
        _officialSfmArCloud = null;
        _officialSfmDiagnosticTag = null;
        if (_projectPhotos.count < 1) _engineDraftCloud = null;
        _engineDraftLastBuildMs = 0;
        await _pushCoverageCloud(force: true);
      }
      return;
    }
    // [2026-08-09 用户签决] 拍摄期 AR live 云**全白**,不再按质量分绿/黄/红。
    // 原先每个点按 track 长度过质量色标上色(2=红 3=橙 4=黄绿
    // [2026-08-23] 该色标模块(capture_quality_ramp.dart)已整体删除 ——
    // 08-09 全白签决后它零调用点,且出货配置下最大单步 133 > 它要取代的
    // 旧硬阈值 128。契约见 test/live_cloud_all_white_test.dart。
    // ≥5=绿),用户裁掉:"不用根据颜色区分状态"。ramp 本体与它的引导横幅
    // ("对黄色区域…",挂的是覆盖体素统计,另一套系统)不在本刀范围。
    final rgb = Uint8List(snapshot.pointCount * 3);
    rgb.fillRange(0, rgb.length, 255);
    // Potree-style hierarchy ordering is computed on a worker isolate. This is
    // display-only: the source SfM snapshot and final PLY stay intact.
    final displayCloud = await compute(buildProgressivePointCloud, (
      xyz: snapshot.xyz,
      rgb: rgb,
    ), debugLabel: 'capture_progressive_octree_order');
    final computeDoneAt = DateTime.now().millisecondsSinceEpoch;
    TelemetryWriter.instance.event(
      'live_cloud_compute_done_v1',
      _liveCloudTelemetry.computeDoneFields(
        receiveTag,
        computeDoneEpochMs: computeDoneAt,
      ),
    );
    if (!_recording) return;
    final completedTag = receiveTag.withComputeDone(computeDoneAt);
    _officialSfmArCloud = CoverageCloudPacked(
      displayCloud.xyz,
      displayCloud.rgb,
    );
    _officialSfmDiagnosticTag = completedTag;
    await _pushCoverageCloud(diagnosticTag: completedTag);
  }

  /// 覆盖云推送合并节流:首次调用立即推(引导反馈不加延迟),400ms 窗口
  /// 内的后续变更合并为窗口结束时的一次 trailing 推(推的永远是当时的
  /// 最新状态,不会丢末尾更新)。65k 满载单次 payload ≈975KB —— 快门
  /// (~0.4Hz)与真值注入(~0.3Hz)撞在同一秒时从两次推缩成一次。
  void _scheduleCoveragePush() {
    if (_coveragePushTimer != null) {
      _coveragePushPending = true;
      return;
    }
    unawaited(_pushCoverageCloud());
    _coveragePushTimer = Timer(const Duration(milliseconds: 400), () {
      _coveragePushTimer = null;
      if (_coveragePushPending) {
        _coveragePushPending = false;
        _scheduleCoveragePush();
      }
    });
  }

  /// 四态边框状态机刷新(判定纯 Dart,见 photo_card_state.dart):对每个
  /// 已喂 SfM 的帧算 黑(未处理)/白(已注册)/黄(已注册但低视差)/
  /// 红(断联),与上次推送差量对比,只把变化的 jpegPath→state 推给
  /// native 哑渲染器。没喂过 SfM 的照片不推——native 默认黑,语义一致。
  void _refreshPhotoCardStates() {
    final recon = _sfmRecon;
    if (recon == null) return;
    final diff = <String, int>{};
    recon.fedFrameMeta.forEach((frameId, meta) {
      // 白→黄反序修复:判黄只用真值(SfmLiveTrueParallax)。真值未到达
      // → frameLowParallaxTrue 返回 null → 已注册帧保持黑(处理中),
      // 视锥近似不再参与卡片判定(覆盖云体素级的真值优先+近似兜底不受
      // 影响)。滞回 4°/6°:上次白/黄裁决从已推送状态恢复,消 1↔3 抖动;
      // 白→黄另加粘性(连续 2 次采样 <4°,计数在 SfmLiveTrueParallax
      // 到达处维护,这里只读)。
      final prev = _photoCardStateSent[meta.jpegPath];
      final state = photoCardSfmState(
        frameId: frameId,
        posesPacked: _sfmLatestPoses,
        lowParallax: frameLowParallaxTrue(
          trueMedianDeg: _trueFrameParallaxDeg[frameId],
          wasLowParallax: prev == PhotoCardSfmState.lowParallax.channelValue
              ? true
              : prev == PhotoCardSfmState.registered.channelValue
              ? false
              : null,
          belowEnterStreak: _frameBelowEnterStreak[frameId] ?? 0,
        ),
      );
      _projectPhotos.updateAnalysisState(meta.jpegPath, state);
      final st = state.channelValue;
      if (_photoCardStateSent[meta.jpegPath] != st) {
        diff[meta.jpegPath] = st;
      }
    });
    if (diff.isEmpty) return;
    // 遥测【card】:每次状态变化一行(旧态→新态 + 距拍摄延迟)。差量处
    // 数据都在手上;必须在 addAll 覆盖前读旧态。
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    diff.forEach((jpeg, next) {
      final capturedAt = _photoCaptureEpochMs[jpeg];
      TelemetryWriter.instance.event('card', {
        'jpeg': jpeg.split('/').last,
        'old': _photoCardStateSent[jpeg],
        'new': next,
        if (capturedAt != null) 'since_capture_ms': nowMs - capturedAt,
      });
    });
    _photoCardStateSent.addAll(diff);
    unawaited(_pushPhotoCardStates(diff));
  }

  /// Consecutive native add_frame faults. A single throw is noise (one lost
  /// frame, the next one usually lands); a RUN of them means the worker is
  /// broken and every further shutter tap is wasted, which is the state one
  /// device take spent 25 frames in while the UI blamed the user's coverage.
  int _sfmInternalFailureStreak = 0;
  static const int _kSfmInternalFailureWarnStreak = 3;

  void _noteSfmInternalFailure(String reason) {
    _sfmInternalFailureStreak++;
    DeviceLog.log(
      'OfficialARCapturePage',
      'sfm internal fault #$_sfmInternalFailureStreak ($reason) — '
          'frame not fed; NOT a coverage problem',
    );
    if (_sfmInternalFailureStreak < _kSfmInternalFailureWarnStreak) return;
    _sfmProcessingTerminalGate.fail(
      kind: SfmTerminalFailureKind.deliveryFailed,
      stage: 'live_delivery',
      message: reason,
    );
    const text = '实时点云暂不可用；高分辨率照片仍会正常保存并在结束后处理。';
    if (_sfmStartFailureText == text || !mounted) return;
    setState(() => _sfmStartFailureText = text);
  }

  void _markPhotoDisconnected(String jpegPath, String reason) {
    const state = PhotoCardSfmState.disconnected;
    _projectPhotos.updateAnalysisState(jpegPath, state);
    if (_photoCardStateSent[jpegPath] == state.channelValue) return;
    _photoCardStateSent[jpegPath] = state.channelValue;
    DeviceLog.log(
      'OfficialARCapturePage',
      'photo retained but marked disconnected: '
          '${jpegPath.split('/').last} ($reason)',
    );
    unawaited(
      _pushPhotoCardStates(<String, int>{jpegPath: state.channelValue}),
    );
  }

  /// 遥测【guidance】:拍摄期 5s 节流采样 —— 断连区段摘要(合成连通性
  /// posesPacked)+ 覆盖云红黄绿体素计数 + 视差饥饿体素数。全部只读
  /// 现有状态(coverageStats/disconnectedSegmentsFromPoses),不碰引导逻辑。
  void _startGuidanceTelemetry() {
    _guidanceTelemetryTimer?.cancel();
    _guidanceTelemetryTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_recording) return;
      try {
        final cov = _coverageCloud.coverageStats();
        final segs = disconnectedSegmentsFromPoses(_sfmLatestPoses);
        var disconnectedFrames = 0;
        for (final s in segs) {
          disconnectedFrames += s.count;
        }
        TelemetryWriter.instance.event('guidance', {
          'covered': cov.covered,
          'red': cov.red,
          'yellow': cov.yellow,
          'green': cov.green,
          'parallax_capped': cov.parallaxCapped,
          'parallax_starved': _coverageCloud.parallaxStarvedVoxelCount,
          // Route B 真值对数字段:starved_true = 观测达标但真实三角化角
          // < parallaxMinDeg(5°,2026-07-11 校准)的体素(route A 同口径
          // 上次只报 1/5997);true_lt8/true_vox 字段名沿革自旧锚 8°,现
          // 口径 = <5°(历史对数:最终云点级 <8° 占比实锤 40.3%);
          // true_frame_lp = 真值判黄的帧数;true_ms = worker 聚合耗时。
          'starved_true': cov.starvedTrue,
          'true_vox': cov.trueVoxels,
          'true_lt8': cov.trueLt8,
          'true_frame_lp': _trueFrameParallaxDeg.values
              .where((d) => d < _coverageCloud.parallaxMinDeg)
              .length,
          'true_ms': _trueParallaxComputeMs,
          // 案②修复对数:容量淘汰累计(>0 = 摸到 16000 安全阀;淘汰序已
          // 保证新区必胜,这里只留观测量)。
          'evicted': _coverageCloud.evictedTotal,
          'captures': _coverageCloud.capturesMarked,
          'fed': _sfmFed,
          'queued': _sfmQueued,
          'n_disconnected_frames': disconnectedFrames,
          'n_segments': segs.length,
          // 区段摘要(封顶 8 段防刷行):[firstId,lastId,count]。
          'segments': [
            for (final s in segs.take(8)) [s.firstId, s.lastId, s.count],
          ],
        });
      } catch (_) {
        // 遥测绝不伤害拍摄。
      }
    });
  }

  void _stopGuidanceTelemetry() {
    _guidanceTelemetryTimer?.cancel();
    _guidanceTelemetryTimer = null;
  }

  /// 把状态差量交给 native(AetherARKitPlugin `setPhotoCardStates`)。
  Future<void> _pushPhotoCardStates(Map<String, int> diff) async {
    try {
      await _arKitChannel.invokeMethod<void>(
        'setPhotoCardStates',
        <String, dynamic>{'states': diff},
      );
    } catch (_) {
      // Display-only channel — never let it disturb capture.
    }
  }

  void _markSfmStartFailure(String detail) {
    final failure = _sfmProcessingTerminalGate.fail(
      kind: SfmTerminalFailureKind.startupFailed,
      stage: 'startup',
      message: detail,
    );
    if (failure == null) return;
    DeviceLog.log(
      'OfficialARCapturePage',
      'sfm: typed terminal ${failure.kind.name}/${failure.stage}: '
          '${failure.message}',
    );
    if (!mounted) return;
    setState(() {
      _sfmStarting = false;
      _sfmStartFailureText = '实时点云未启动（$detail）；照片仍会正常保存。';
    });
  }

  /// Spawns the required streaming-SfM worker for this take and wires the
  /// keyframe feed. Startup is fail-closed: unsupported devices, missing
  /// capture storage, lease contention (reported as a null worker), and thrown
  /// errors degrade only the optional live reconstruction path. Camera
  /// capture and draft persistence remain independently available.
  Future<void> _startSfmLiveRecon(CaptureSession session) async {
    // Subscribe before the first await. The instant first shutter is allowed
    // while the worker starts, so accepted photos must be buffered rather than
    // disappearing in the startup gap between CaptureSession and SfM.
    _sfmFeedSub ??= session.sfmFrameStream.listen((input) {
      final recon = _sfmRecon;
      if (recon == null) {
        _pendingSfmInputs.add(input);
      } else {
        recon.offerFrame(input);
      }
    });
    try {
      if (_sfmRecon != null) {
        if (mounted) setState(() => _sfmStarting = false);
        return;
      }
      if (!SfmLiveRecon.isSupported) {
        _markSfmStartFailure('当前设备不支持本地点云重建');
        return;
      }
      final captureDir = session.captureDir;
      if (captureDir == null) {
        _markSfmStartFailure('拍摄目录不可用');
        return;
      }
      final recon = await SfmLiveRecon.start(
        dbPath: '$captureDir/official_sfm_live.db',
      );
      if (recon == null) {
        _markSfmStartFailure('重建资源正被占用或启动失败');
        return;
      }
      if (!mounted || !_recording) {
        DeviceLog.log(
          'OfficialARCapturePage',
          'sfm: page gone before worker up',
        );
        unawaited(recon.dispose());
        return;
      }
      _sfmRecon = recon;
      for (final input in _pendingSfmInputs) {
        recon.offerFrame(input);
      }
      _pendingSfmInputs.clear();
      _sfmEventSub = recon.events.listen((event) => _onSfmEvent(recon, event));
      unawaited(
        recon.completion.then((failure) => _onSfmTerminal(recon, failure)),
      );
      _highResFailureSub ??= session.highResFailureStream.listen(
        _onHighResCaptureFailure,
      );
      if (mounted) {
        setState(() => _sfmStarting = false); // enable controls + feed chip
      }
      DeviceLog.log('OfficialARCapturePage', 'sfm: live recon wired');
    } catch (e, st) {
      DeviceLog.log('OfficialARCapturePage', 'sfm: start FAILED: $e\n$st');
      _markSfmStartFailure('重建服务启动异常');
    }
  }

  bool _resolveFinishTerminal({
    required CaptureFinishAttempt attempt,
    required bool success,
    required String stage,
    Object? error,
    StackTrace? stackTrace,
    bool deferUntilDraftPersisted = false,
  }) {
    if (attempt.generation != _finishCoordinator.currentGeneration) {
      return false;
    }
    if (deferUntilDraftPersisted &&
        !_finishDraftPersisted &&
        _finishCoordinator.terminalOutcome == null) {
      final request = _PendingFinishTerminal(
        attempt: attempt,
        success: success,
        stage: stage,
        error: error,
        stackTrace: stackTrace,
      );
      final pending = _pendingFinishTerminal;
      if (pending == null || (!success && pending.success)) {
        _pendingFinishTerminal = request;
      }
      return false;
    }
    final resolved = success
        ? _finishCoordinator.completeSuccess(attempt)
        : _finishCoordinator.completeError(
            attempt,
            stage: stage,
            error: error ?? StateError(stage),
            stackTrace: stackTrace,
          );
    if (resolved && !success) {
      _colorizeTarget = null;
      unawaited(_endReconUmbrella());
      _showFinishCoordinatorFailure(attempt);
    }
    return resolved;
  }

  bool _flushDeferredFinishTerminal() {
    _finishDraftPersisted = true;
    final pending = _pendingFinishTerminal;
    _pendingFinishTerminal = null;
    if (pending == null) return false;
    return _resolveFinishTerminal(
      attempt: pending.attempt,
      success: pending.success,
      stage: pending.stage,
      error: pending.error,
      stackTrace: pending.stackTrace,
    );
  }

  void _onSfmTerminal(SfmLiveRecon source, SfmTerminalFailure? failure) {
    if (!identical(source, _sfmRecon) || failure == null) return;
    final typedFailure = _sfmProcessingTerminalGate.fail(
      kind: failure.kind,
      stage: failure.stage,
      message: failure.message,
    );
    if (typedFailure == null) return;
    DeviceLog.log(
      'OfficialARCapturePage',
      'sfm: terminal ${typedFailure.kind.name}/${typedFailure.stage}',
    );
    final phase = _finishCoordinator.phase;
    if (phase == CaptureFinishPhase.processing ||
        phase == CaptureFinishPhase.cameraStopped ||
        phase == CaptureFinishPhase.drainingActiveTicket ||
        phase == CaptureFinishPhase.committing) {
      final attempt = CaptureFinishAttempt(
        _finishCoordinator.currentGeneration,
      );
      _resolveFinishTerminal(
        attempt: attempt,
        success: false,
        stage: 'sfm_${typedFailure.stage}',
        error: typedFailure,
        deferUntilDraftPersisted: true,
      );
      return;
    }
    if (!mounted || !_recording) return;
    setState(() {
      _sfmStarting = false;
      _sfmStartFailureText = '实时点云已停止；照片仍会正常保存。';
    });
  }

  void _onHighResCaptureFailure(OfficialHighResCaptureFailureEvent event) {
    if (!mounted) return;
    if (event.automaticSelection &&
        !automaticShutterFailureIsUserVisible(event.failure)) {
      return;
    }
    final message = switch (event.failure) {
      OfficialHighResInputFailure.unexpectedDimensions =>
        '高分辨率照片不是 4032×3024，本张未进入重建，请重拍',
      OfficialHighResInputFailure.outOfSync => '高分辨率照片与点击时刻不同步，本张未进入重建，请重拍',
      OfficialHighResInputFailure.missingPose ||
      OfficialHighResInputFailure.missingIntrinsics =>
        '本张 ARKit 相机数据不完整，未进入重建，请重拍',
      OfficialHighResInputFailure.transactionMismatch =>
        '高分辨率照片事务与快门不匹配，本张未进入重建，请重拍',
      OfficialHighResInputFailure.captureFailed ||
      OfficialHighResInputFailure.captureTimedOut ||
      OfficialHighResInputFailure.missingJpeg => '高分辨率照片拍摄失败，本张未进入重建，请重拍',
      OfficialHighResInputFailure.actualStillMissingEvidence =>
        '高分辨率照片缺少实际图像校验，本张未进入重建，请重拍',
      OfficialHighResInputFailure.actualStillQualityRejected =>
        '高分辨率照片不够清晰，本张未进入重建，请重拍',
      OfficialHighResInputFailure.actualStillDuplicate =>
        '高分辨率照片与上一张重复，本张未进入重建，请继续移动',
    };
    _markPhotoCardFailed(event.evidenceJpegPath, event.transactionId, message);
  }

  void _markPhotoCardFailed(
    String evidenceJpegPath,
    String transactionId,
    String message,
  ) {
    _failedEvidenceJpegPaths.add(evidenceJpegPath);
    _photoTransactionIdsByEvidencePath[evidenceJpegPath] = transactionId;
    unawaited(
      _removePhotoCard(
        transactionId: transactionId,
        evidenceJpegPath: evidenceJpegPath,
      ),
    );
    DeviceLog.log(
      'OfficialARCapturePage',
      'high-resolution candidate rejected silently: $message',
    );
  }

  /// 修1:推进等待页阶段(单调递增,重复/回退调用被忽略),重置该阶段的
  /// 计秒起点。事件驱动,不轮询 worker。
  void _advanceSfmStage(int stage) {
    if (stage <= _sfmFinalizeStage) return;
    _sfmFinalizeStage = stage;
    _sfmStageStartMs = DateTime.now().millisecondsSinceEpoch;
    if (mounted && _sfmPhase != null) setState(() {});
  }

  /// 修1:等待页计秒 ticker。generating 期间每秒 setState 刷新"已 Xs";
  /// 离开 generating 自停(refined/error/完成都会停)。
  void _startSfmStageTicker() {
    _sfmStageTicker?.cancel();
    _sfmStageTicker = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted || _sfmPhase != SfmPreviewPhase.generating) {
        t.cancel();
        if (identical(_sfmStageTicker, t)) _sfmStageTicker = null;
        return;
      }
      if (_sfmFinalizeStage > 0 && _sfmQueued == 0) setState(() {});
    });
  }

  void _stopSfmStageTicker() {
    _sfmStageTicker?.cancel();
    _sfmStageTicker = null;
    _sfmFinalizeStage = 0;
    _sfmStageStartMs = 0;
  }

  /// 修1:队列清空后的阶段文案(带该阶段已耗时)。阶段事件尚未到达时
  /// 保底沿用旧文案,绝不显示空白。
  ///
  /// 阶段 2 细分(2026-07-11 案③顺带,46 号 155s 无子进度):native 的
  /// finalize_segments 只在结束后落盘、worker 阶段 2 内无中途事件,所以
  /// 这里做文案层轮换 —— enrich 补匹配与 stage1 全局 BA 本来就是并行跑
  /// (finalize 三重优化定案),12s 轮换两句都是真话;真实子进度事件
  /// 以后有了再接,不过度工程。已用时显示保留。
  String _sfmStageProgressText(BuildContext context) {
    final l = AppL10n.of(context);
    if (_sfmFinalizeStage <= 0) return l.sfmQueueDrainedFinal;
    final secs = _sfmStageStartMs > 0
        ? ((DateTime.now().millisecondsSinceEpoch - _sfmStageStartMs) / 1000)
              .floor()
        : 0;
    final elapsed = secs < 60
        ? l.sfmElapsedSec(secs)
        : l.sfmElapsedMinSec(secs ~/ 60, secs % 60);
    return switch (_sfmFinalizeStage) {
      1 => l.sfmStage1(elapsed),
      2 => (secs ~/ 12).isEven ? l.sfmStage2a(elapsed) : l.sfmStage2b(elapsed),
      3 => l.sfmStage3(elapsed),
      _ => l.sfmStage4(elapsed),
    };
  }

  void _onSfmEvent(SfmLiveRecon source, SfmLiveEvent event) {
    if (!identical(source, _sfmRecon) || !mounted) return;
    if (event is SfmLivePreview &&
        (event.snapshot.summary['source'] == 'streaming_global_ba' ||
            event.snapshot.summary['source'] == 'streaming_local_ba_live')) {
      // [AR-EVERY-FRAME 2026-08-04] 两种拍摄期流式 source 都路由到 AR overlay
      // 并 return:检查点的 'streaming_global_ba'(既有,~8次),以及每帧的
      // 'streaming_local_ba_live'(实验臂,默认关时永不发出)。**必须在此 return**,
      // 否则会落进下方 colorize 路径,而那里 'streaming_local_ba'(注意无 _live)
      // 被当作拍完的终态云会提前弹浮层。'_live' 后缀正是为避开该撞名。
      final snapshot = event.snapshot;
      final source = snapshot.summary['source'] as String;
      final receiveTag = _liveCloudTelemetry.receive(
        source: source,
        publishVersion:
            (snapshot.summary['publish_version'] as num?)?.toInt() ?? 0,
        pointCount: snapshot.pointCount,
        receiveEpochMs: DateTime.now().millisecondsSinceEpoch,
        sourceReceiveSequence:
            (snapshot.summary['diag_source_receive_seq'] as num?)?.toInt(),
      );
      TelemetryWriter.instance.event(
        'live_cloud_receive_v1',
        receiveTag.baseFields,
      );
      if (snapshot.posesPacked.isNotEmpty) {
        _sfmLatestPoses = snapshot.posesPacked;
        _refreshPhotoCardStates();
      }
      // 自动拍位移阈值的场景深度输入(2026-08-24 二拍验证补修):拍摄期的
      // 流式快照**只走这条早退分支**,下方 colorize switch 里的同款钩子在
      // 拍摄期根本执行不到 —— 未命名(7) 整场 fire_live_depth_m 为空就是
      // 这么来的。流式云与 ARKit 同一世界系(posesPacked 为合成零四元数
      // ⇒ _gravityAlign 恒 no-op ⇒ quat 为 null),守卫条件与下方同款。
      if (snapshot.gravityAlignQuatWxyz == null && snapshot.xyz.isNotEmpty) {
        _liveCloudXyz = snapshot.xyz;
      }
      unawaited(_publishOfficialSfmCloudToAr(snapshot, receiveTag));
      return;
    }
    // 卡片边框连通性(黑→白/红):native 渲染,Flutter 无需 rebuild —
    // 不进 setState,处理完直接返回。
    if (event is SfmLiveConnectivity) {
      _sfmLatestPoses = event.posesPacked;
      _refreshPhotoCardStates();
      return;
    }
    // Route B 真实三角化角到达:①帧级中位数合并进判黄真值表 ②体素级
    // 真值注入覆盖云(压黄逻辑改用真值)→ 卡片与覆盖云都可能变色。
    // 全部 native 哑渲染,无需 rebuild —— 不进 setState,处理完直接返回。
    if (event is SfmLiveTrueParallax) {
      final fp = event.framesPacked;
      for (var i = 0; i + 1 < fp.length; i += 2) {
        final fid = fp[i].toInt();
        final deg = fp[i + 1];
        _trueFrameParallaxDeg[fid] = deg;
        // 白态粘性计数:只在真值采样到达处更新(连续 <4° 采样次数;
        // ≥4° 清零)。_refreshPhotoCardStates 只读,不重复计数。
        _frameBelowEnterStreak[fid] = frameBelowEnterStreak(
          sampleDeg: deg,
          prevStreak: _frameBelowEnterStreak[fid] ?? 0,
        );
      }
      _coverageCloud.applyTrueParallax(event.voxelKeys, event.voxelDeg);
      _trueParallaxComputeMs = event.computeMs;
      _refreshPhotoCardStates();
      _scheduleCoveragePush(); // 真值可能翻体素颜色 → 合并节流推送

      // 补强1:真值刚注入 → starved 计数可能变化,顺路采样(去抖/滞回
      // 在 gate 内;只在横幅翻转时才 setState,不破坏本分支"不 rebuild"
      // 的克制)。
      _sampleStarvedBanner();
      return;
    }
    if (event is SfmLiveFrameFed && event.result == 'ok') {
      // A frame landed: the worker is healthy again, so a past isolated throw
      // must not accumulate toward the fault banner.
      _sfmInternalFailureStreak = 0;
    }
    if (event is SfmLiveFrameFed &&
        event.result != 'ok' &&
        event.jpegPath != null) {
      // [MONITORING 2026-07-26] Not every failure is a coverage problem.
      //   errNotRegistered = COLMAP looked at the frame and declined to
      //     register it. Upstream treats an unregistered image as a normal
      //     outcome, and "shoot again near the red cards" is genuinely the
      //     fix — keep the red disconnected state.
      //   errInternal      = the native call THREW; the frame never entered
      //     the reconstruction at all (frameId == -1). Reshooting cannot help
      //     — it hits the same fault. Painting it red told the user to do
      //     useless work AND disguised a real bug as a capture problem: one
      //     device take lost 25 consecutive frames this way and it read as
      //     "you didn't shoot well enough". Leave the card in its pending
      //     state (black = SfM has not processed it, which is exactly true)
      //     and surface the fault as a fault.
      if (event.result == 'errInternal') {
        _noteSfmInternalFailure(event.result);
      } else {
        _markPhotoDisconnected(event.jpegPath!, event.result);
      }
    }
    setState(() {
      switch (event) {
        case SfmLiveConnectivity():
        case SfmLiveTrueParallax():
          break; // 已在上方早退处理(不触发 rebuild)
        case SfmLiveFrameFed():
          _sfmFed = _sfmRecon?.fedCount ?? _sfmFed;
          _sfmQueued = _sfmRecon?.remainingCount ?? _sfmQueued;
          // 拥塞遥测标签:队列深度刚变,重估标签(纯观测,已在 setState 内)。
          _recomputeShutterPace(inSetState: true);
          // 修1:等待页上队列刚排空 → finalize 即将/已经下发,进入
          // 阶段 1(整理帧数据/phase1)。已在 setState 内,直接改字段。
          if (_sfmPhase == SfmPreviewPhase.generating &&
              _sfmQueued == 0 &&
              _sfmFinalizeStage == 0) {
            _sfmFinalizeStage = 1;
            _sfmStageStartMs = DateTime.now().millisecondsSinceEpoch;
          }
        case SfmLiveFrameQueued():
          _sfmQueued = _sfmRecon?.remainingCount ?? _sfmQueued;
          // 拥塞遥测标签:入队即重估(队列上行沿是标签的主要触发,纯观测)。
          _recomputeShutterPace(inSetState: true);
        case SfmLiveFinalizePhase1Done():
          // 修1:phase1 完成 → 阶段 2(后台全局 BA,分钟级)。
          if (_sfmPhase == SfmPreviewPhase.generating &&
              _sfmFinalizeStage < 2) {
            _sfmFinalizeStage = 2;
            _sfmStageStartMs = DateTime.now().millisecondsSinceEpoch;
            // 案④:灵动岛真实进度锚点 1 —— phase1 完成 = 10%。
            unawaited(_pushReconProgress(0.10, '全局优化中'));
          }
        case SfmLivePreview():
        case SfmLiveLocalReady():
        case SfmLiveRefined():
          // Display + phase advance are DEFERRED to the colorize pass below:
          // the cloud is only shown once it's fully colored (geometry + true
          // color together, no gray flash). The overlay keeps showing the
          // generating spinner / the previous colored cloud until then. The
          // streaming-preview cloud is now track-annotated, so it colorizes on
          // the SAME path — it is the ONLY cloud shown (global BA deferred).
          break;
        case SfmLiveFailed():
          // Display-only event. SfmLiveRecon.completion supplies the terminal
          // failure after raw-draft persistence has settled.
          if (_sfmPhase == SfmPreviewPhase.generating) {
            _sfmPhase = SfmPreviewPhase.error;
            _sfmErrorText = '处理未完成，已保留全部照片。请稍后从草稿重试。';
          }
      }
    });
    // Events own presentation only; they never write the finish terminal.
    switch (event) {
      case SfmLiveFailed(:final stage, :final message, :final kind):
        _onSfmTerminal(
          source,
          SfmTerminalFailure(kind: kind, stage: stage, message: message),
        );
        unawaited(_endReconUmbrella());
      default:
        break;
    }
    // Real-color pass: on-device extract_colors is off, so snapshots arrive
    // colorless — sample the registered keyframes' JPEGs. The COLORED result is
    // what gets shown (see _colorizeSnapshot's tail) so geometry + color appear
    // together. `_colorizeTarget` marks the newest pass so a stale one bails.
    switch (event) {
      case SfmLivePreview(:final snapshot):
      case SfmLiveLocalReady(:final snapshot):
      case SfmLiveRefined(:final snapshot):
        // 卡片边框终态刷新:快照的 posesPacked 是注册真值(finalize 为
        // COLMAP registered 位;流式 preview 为合成连通性),覆盖拍摄期
        // 的实时判定。空 poses(异常路径)不回退已有状态。
        if (snapshot.posesPacked.isNotEmpty) {
          _sfmLatestPoses = snapshot.posesPacked;
          _refreshPhotoCardStates();
        }
        // 拍摄期流式快照(未做重力旋转 ⇒ 与 ARKit 同一世界系)→ 更新
        // 自动拍位移阈值的场景深度输入。带旋转的 finalize 快照不进:
        // 坐标系已不同,且那时自动拍早已结束。
        if (snapshot.gravityAlignQuatWxyz == null && snapshot.xyz.isNotEmpty) {
          _liveCloudXyz = snapshot.xyz;
        }
        // 修1:finalize 快照到达 → 阶段 3(提取色彩)。拍摄期的流式
        // preview(_sfmPhase == null)不进阶段流。
        if (_sfmPhase == SfmPreviewPhase.generating) {
          _advanceSfmStage(3);
          // 案④:灵动岛真实进度锚点 2 —— RefineGlobalBA 全段完 = 75%
          // (46 号 segments 实测:该段占总等待 96%,合成爬行在段内兜底)。
          unawaited(_pushReconProgress(0.75, '提取色彩中'));
        }
        _colorizeTarget = snapshot;
        unawaited(_runColorizeSnapshot(snapshot));
      default:
        break;
    }
  }

  Future<void> _runColorizeSnapshot(SfmLiveSnapshot snapshot) async {
    final expectsTerminal =
        snapshot.summary['terminal'] == true ||
        snapshot.summary['source'] == 'streaming_global_ba' ||
        snapshot.refined;
    final attempt = CaptureFinishAttempt(_finishCoordinator.currentGeneration);
    var completed = false;
    final processed = await _finishCoordinator.runProcessingStep(
      attempt: attempt,
      stage: 'colorizeAndPersist',
      operation: () async {
        completed = await _colorizeSnapshot(snapshot);
      },
    );
    if (!processed) {
      if (_finishCoordinator.phase == CaptureFinishPhase.error) {
        _showFinishCoordinatorFailure(attempt);
      }
      return;
    }
    if (!identical(_colorizeTarget, snapshot)) return;
    if (expectsTerminal && !completed) {
      _resolveFinishTerminal(
        attempt: attempt,
        success: false,
        stage: 'colorizeAndPersist',
        error: StateError(
          'terminal point cloud did not produce a persisted PLY',
        ),
        deferUntilDraftPersisted: true,
      );
      return;
    }
    if (completed) {
      _resolveFinishTerminal(
        attempt: attempt,
        success: true,
        stage: 'colorizeAndPersist',
        deferUntilDraftPersisted: true,
      );
    }
  }

  // [增量D 2026-07-28] 此处原挂着一段 BIT5/L1 仲裁重算的孤儿注释(所述
  // 函数早已随 E25 停用删除)——注释一并清理,勿被其误导。
  Future<bool> _colorizeSnapshot(SfmLiveSnapshot snap) async {
    final recon = _sfmRecon;
    if (recon == null || snap.pointCount == 0) return false;
    final isTerminalColorize =
        snap.summary['terminal'] == true ||
        snap.summary['source'] == 'streaming_global_ba' ||
        snap.refined;
    final n = snap.pointCount;
    final offs = snap.obsOffsets;
    final fids = snap.obsFrameIds;
    final oxy = snap.obsXY;
    if (fids.isEmpty || offs.length != n + 1) return false; // no track data

    // Group observations by frame so every JPEG decodes exactly once.
    // byFrame[frameId] = flat [pointIndex, kpX, kpY, ...] triples.
    // obsCap 顺带统计每点有效观测数,作为样本池的预分配容量。
    final byFrame = <int, List<double>>{};
    final obsCap = Int32List(n);
    for (var i = 0; i < n; i++) {
      for (var j = offs[i]; j < offs[i + 1]; j++) {
        final f = fids[j];
        if (!recon.fedFrameMeta.containsKey(f)) continue;
        obsCap[i]++;
        (byFrame[f] ??= <double>[])
          ..add(i.toDouble())
          ..add(oxy[j * 2])
          ..add(oxy[j * 2 + 1]);
      }
    }
    if (byFrame.isEmpty) return false;

    final sw = Stopwatch()..start();
    // 代表色样本池:收集每点全部双线性观测样本,归约时选亮度中位的真实样本
    // (不再算术平均——白床单混入个别红观测会被平均成粉,见
    // representative_color.dart)。
    final samples = RepresentativeColorSamples(obsCap);
    // 取色解码 pipeline(colorize_pipeline.dart,07-12 提速两刀,输出逐位
    // 一致,tool/colorize_parallel_check.dart 有串行对拍断言):
    //   ① 按 jpegPath 去重共享解码(槽位重拍历史同文件只解一次);
    //   ② 有界并行 3 + 单 consumer 严格按 byFrame 插入序采样(与旧逐帧
    //      串行同序)。cap47 遥测:6.8s ≈ 121×56ms 串行解码受限 → 预期 ~2s。
    // native 侧配套:colorizeQueue 已改并发队列(Dart 窗口=唯一 in-flight
    // 上限,3×1280px RGB ≈ 11MB)。每帧解码仍走 native ImageIO downscale
    // (1280px 长边,30-80ms;纯 Dart 全分辨率解码 1.5-4s 是"白点云"旧根因)。
    // 取消哨兵与旧逐帧检查同语义:被新快照取代立刻停。
    // NOTE: no !mounted bail here — even if the user tapped 完成 and the page
    // popped, we finish + PERSIST so the draft PLY carries color.
    final jobs = <ColorizeFrameJob>[];
    for (final entry in byFrame.entries) {
      final meta = recon.fedFrameMeta[entry.key]!;
      jobs.add(
        ColorizeFrameJob(
          jpegPath: meta.jpegPath,
          grayW: meta.grayW,
          grayH: meta.grayH,
          tri: entry.value,
        ),
      );
    }
    // [COLORIZE-PAR 2026-07-26, signed] 6→3 回退:par=6 在
    // cap_1785078141726265 实测 14.4s,反而慢于 par=3 的 12.6s
    // (cap_1785070530166049)——瓶颈在硬件解码器吞吐/热降频,3→6 无收益。
    // par=3 与串行的逐位一致对拍见 tool/colorize_parallel_check.dart。
    const colorizePar = 3;
    final dstats = await sampleColorsPipelined(
      jobs: jobs,
      samples: samples,
      decode: _decodeJpegNative,
      maxInFlight: colorizePar,
      isCancelled: () => !identical(_colorizeTarget, snap),
    );
    final decoded = dstats.framesSampled;
    final decodeFail = dstats.decodeFail;
    // 遥测【colorize】:每次真实 native 解码耗时(去重后 unique 次数;
    // 中位数定位 ImageIO 慢帧/热降频)。
    final decodeMsList = dstats.decodeMs;
    if (!identical(_colorizeTarget, snap)) {
      return false; // superseded during decode/sampling
    }

    final rgb = Uint8List(n * 3);
    var colored = 0;
    var gainMs = 0;
    // [RS-CORRECT-COLORS 2026-08-14] 复刻 RealityScan 的 `Correct colors`:
    // 先估每帧三通道增益(用已采到的样本,零额外解码),再在**校正后**的
    // 亮度上选代表样本。不校正时"两个观测取更暗的那个"有 81% 的概率取到的
    // 是"自动曝光收得更紧的那一帧"而非"没吃到高光的角度"(s4 实测),
    // 相邻点因此各挑各的帧 ⇒ 整片云出斑块。
    // 档位(official_env.json,Dart 直读;Platform.environment 读不到 setenv):
    //   0/缺省 = 关,逐位等同旧实现;1 = 只用于选择;2 = 同时应用到输出(RS 忠实形态)
    final ccMode = AetherEnvFile.intOf('OFFICIAL_AETHER_COLOR_CORRECT', 0);
    FrameColorGains? gains;
    if (ccMode > 0 && jobs.isNotEmpty) {
      final gsw = Stopwatch()..start();
      gains = samples.estimateFrameGains(jobs.length);
      gsw.stop();
      gainMs = gsw.elapsedMilliseconds;
    }
    // [RS-MULTIBAND 2026-08-14] 复刻 RS 的 Multi-band 顶点上色:低频(颜色/
    // 亮度)在邻域内线性融合 → 协调;高频(细节)仍来自单一真实观测 → 不糊。
    // 只改 RGB,不增删/修补任何点(遵守"Dart 阶段不得 delete/repair/enrich"
    // 的既有铁律)。默认关。
    final mbMode = AetherEnvFile.intOf('OFFICIAL_AETHER_COLOR_MULTIBAND', 0);
    var mbMs = 0;
    if (mbMode > 0) {
      final msw = Stopwatch()..start();
      final selF = Float32List(n * 3);
      final linF = Float32List(n * 3);
      for (var i = 0; i < n; i++) {
        if (!samples.selectIntoFloat(
          i,
          selF,
          gains: gains,
          applyToOutput: ccMode >= 2,
        )) {
          selF[i * 3] = 185;
          selF[i * 3 + 1] = 185;
          selF[i * 3 + 2] = 190;
        }
        if (!samples.meanIntoFloat(i, linF, gains: gains)) {
          linF[i * 3] = selF[i * 3];
          linF[i * 3 + 1] = selF[i * 3 + 1];
          linF[i * 3 + 2] = selF[i * 3 + 2];
        }
      }
      final blended = multiBandBlend(
        xyz: snap.xyz,
        selected: selF,
        linear: linF,
      );
      rgb.setAll(0, blended);
      msw.stop();
      mbMs = msw.elapsedMilliseconds;
    }
    final obsHist = List<int>.filled(5, 0);
    final rmsList = <double>[];
    var rmsGt40 = 0;
    for (var i = 0; i < n; i++) {
      // 代表色归约:选亮度中位的真实观测样本,不合成新颜色。
      // multi-band 已写好 rgb 时,这里只补统计,不覆盖颜色。
      if (mbMode > 0
          ? samples.hitCount(i) > 0
          : samples.selectInto(
              i,
              rgb,
              gains: gains,
              applyToOutput: ccMode >= 2,
            )) {
        colored++;
        final hc = samples.hitCount(i);
        obsHist[obsHistBucket(hc)]++;
        if (hc >= 2) {
          final rms = samples.rmsDeviation(
            i,
            rgb[i * 3],
            rgb[i * 3 + 1],
            rgb[i * 3 + 2],
          );
          rmsList.add(rms);
          if (rms > 40) rmsGt40++;
        }
      } else {
        // Track frames unavailable (decode failed) — readable light gray.
        rgb[i * 3] = 185;
        rgb[i * 3 + 1] = 185;
        rgb[i * 3 + 2] = 190;
      }
    }
    sw.stop();
    DeviceLog.log(
      'Colorize',
      '${snap.refined ? "refined" : "local"} done in ${sw.elapsedMilliseconds}ms: '
          'colored $colored/$n (${(100 * colored / n).round()}%) | '
          'frames decoded=$decoded fail=$decodeFail '
          'unique=${dstats.uniqueDecodes} par=$colorizePar',
    );
    // 遥测【colorize】一行汇总(排序两个小数组,~几 ms,等待页后台)。
    try {
      decodeMsList.sort();
      rmsList.sort();
      double r1(double? v) => v == null ? 0 : (v * 10).round() / 10;
      TelemetryWriter.instance.event('colorize', {
        'refined': snap.refined,
        'total_ms': sw.elapsedMilliseconds,
        'frames': byFrame.length,
        'decoded': decoded,
        'decode_fail': decodeFail,
        // [RS-CORRECT-COLORS] 档位与实测增益跨度;cc_mode=0 时后三项恒为
        // 默认值,可据此确认"这一场没开校正"。
        'cc_mode': ccMode,
        'cc_ms': gainMs,
        'cc_gain_lo': gains?.span[0],
        'cc_gain_hi': gains?.span[1],
        'cc_banned': gains?.bannedCount,
        'mb_mode': mbMode,
        'mb_ms': mbMs,
        // 07-12 并行化新增:真实 native 解码次数(按 jpegPath 去重)与
        // 并行窗口;frames-decode_unique = 去重省下的解码次数。
        'decode_unique': dstats.uniqueDecodes,
        'decode_par': 3,
        'decode_ms_p50': r1(percentileSorted(decodeMsList, 0.50)),
        'decode_ms_p90': r1(percentileSorted(decodeMsList, 0.90)),
        'decode_ms_max': decodeMsList.isEmpty ? 0 : decodeMsList.last.round(),
        // [E25] 实际解码尺寸 + 配置上限 —— 证明"全分辨率取色"是否真生效。
        'decode_w': _colorizeDecodeW,
        'decode_h': _colorizeDecodeH,
        'decode_max_px_cfg': kColorizeDecodeMaxPx,
        'points': n,
        'colored': colored,
        'no_obs': n - colored, // 无可用观测(解码失败/track 帧缺失)→ 灰点
        'obs_hist': obsHist, // [1, 2, 3-4, 5-8, 9+]
        'var_n': rmsList.length,
        'var_p50': r1(percentileSorted(rmsList, 0.50)),
        'var_p90': r1(percentileSorted(rmsList, 0.90)),
        'var_gt40': rmsGt40, // 混色嫌疑点数(均方差 > 40 灰阶)
      });
    } catch (_) {}
    // [E25-D 2026-07-20] L2 渲染门已删除 —— 交付即显示,不再计算/落盘
    // ghost_view_mask.bin。原块(97 行)在此计算 band15∧¬rescued 可见性、
    // 把 native ghost_mask.bin 重排到交付点序、并发 ghost_view_filter 遥测。
    // The official endpoint snapshot is reused unchanged for BOTH persistence
    // and display. Colorization may add RGB, but no Dart stage may delete,
    // repair, or enrich a point after COLMAP's final BA/filtering.
    final fsnap = SfmLiveSnapshot(
      xyz: snap.xyz,
      rgb: rgb,
      posesPacked: snap.posesPacked,
      summary: snap.summary,
      refined: snap.refined,
      obsOffsets: Int32List(0),
      obsFrameIds: Int32List(0),
      obsXY: Float32List(0),
    );
    // PERSIST FIRST: the completion button must mean that the final colored PLY
    // is actually on disk, not merely queued for a later asynchronous write.
    // 修1:进入阶段 4(保存点云)。
    if (_sfmPhase == SfmPreviewPhase.generating &&
        identical(_colorizeTarget, snap)) {
      _advanceSfmStage(4);
      // 案④:灵动岛真实进度锚点 3 —— 取色完成、开始落盘 = 85%。
      unawaited(_pushReconProgress(0.85, '保存点云中'));
    }
    final captureDir = _session?.captureDir;
    if (captureDir == null && isTerminalColorize) {
      throw StateError('terminal point cloud has no capture directory');
    }
    var terminalPersisted = false;
    if (captureDir != null && identical(_colorizeTarget, snap)) {
      final psw = Stopwatch()..start();
      var persistOk = false;
      try {
        await persistSparseSnapshot(
          captureDir: captureDir,
          snapshot: fsnap,
          rgb: rgb,
        );
        persistOk = true;
        terminalPersisted = isTerminalColorize;
        // [2026-08-08 用户实机指认] "点云诞生出来的那一刻就删除封面照片然后立刻
        // 替换成点云截图" —— 草稿卡片的封面在这里就画好,而不是等回到草稿页轮询
        // 补图(那会让卡片先显示照片、几秒后肉眼跳变一下)。
        //
        // unawaited 是刻意的:上面那句注释说明了 persist 必须先完成才让"完成"
        // 按钮出现,画封面不能再往这条路上加延迟。用户此刻还在预览页看结果,
        // 等他点"完成"再走到草稿页,封面早就在盘上了。万一没赶上(立刻点完成),
        // 草稿页的懒补图仍是兜底。
        unawaited(
          writeSparseThumbFrom(
            captureDir: captureDir,
            xyz: fsnap.xyz,
            rgb: rgb,
          ),
        );
        // [E25-D 2026-07-20] 原在此把交付点序的 ghost_view_mask.bin 与 PLY
        // 一起落盘(供草稿查看页对齐渲染门)。L2 已删,不再产该 sidecar。
      } catch (e, stackTrace) {
        DeviceLog.log(
          'OfficialARCapturePage',
          'final sparse persist failed: $e',
        );
        Error.throwWithStackTrace(e, stackTrace);
      }
      psw.stop();
      // 遥测【persist】:PLY+meta 落盘耗时与字节数("完成"按钮的前置)。
      try {
        int fileLen(String p) {
          try {
            return File(p).lengthSync();
          } catch (_) {
            return -1;
          }
        }

        TelemetryWriter.instance.event('persist', {
          'ok': persistOk,
          'ms': psw.elapsedMilliseconds,
          'n_pts': fsnap.pointCount,
          'refined': fsnap.refined,
          'ply_bytes': fileLen('$captureDir/official_sfm_sparse.ply'),
          'meta_bytes': fileLen('$captureDir/official_sfm_sparse_meta.json'),
        });
      } catch (_) {}
      // 案④:灵动岛真实进度锚点 4 —— PLY 已在盘上 = 95%
      // (100% 仍只由 endReconUmbrella 置,语义 = "完成"按钮可见)。
      if (persistOk) {
        unawaited(_pushReconProgress(0.95, '即将完成'));
      }
    }
    // Display only if still mounted + current. THIS is where the cloud first
    // becomes visible — fully colored — and the phase advances in lock-step, so
    // the overlay shows the spinner until the colored cloud is ready (no gray).
    if (mounted && identical(_colorizeTarget, snap)) {
      // Show the orphan-FILTERED cloud (same buffers persisted above); it only
      // reads xyz+rgb and the obs arrays were already dropped in fsnap. (mem audit)
      final display = fsnap;
      // Streaming local-BA is now the terminal finish-time cloud: it matches the
      // older good captures' delivery path and avoids a post-finish pure global
      // BA wait/overwrite. `streaming_global_ba` remains accepted for old builds
      // or explicit experiments. The resume/cold-finalize path still emits a
      // noisier phase-1 `local_ready` that we defer for its `refined` follow-up.
      final src = snap.summary['source'];
      final isStreamingPreview =
          src == 'streaming_local_ba' || src == 'streaming_global_ba';
      if (snap.refined || isStreamingPreview) {
        // Reveal the clean terminal cloud (streaming preview, or REFINED phase-2).
        setState(() {
          _sfmSnapshot = display;
          _sfmPhase = SfmPreviewPhase.refined;
        });
        // [2026-08-24] 终态点云在这里第一次呈现给用户 —— 预览页真的在屏幕上
        // (没退到草稿视图)就算"看过",草稿卡右上角的绿"完成"胶囊不再出现。
        // 退到草稿视图时终态会走自动退出,用户没看到点云,不标。
        if (!_showDraftsWhileReconstructing && captureDir != null) {
          unawaited(
            ScanRecordStore.instance.markResultViewedByCaptureDir(captureDir),
          );
        }
      }
    }
    if (isTerminalColorize && identical(_colorizeTarget, snap)) {
      if (snap.refined) unawaited(_endReconUmbrella());
    }
    return isTerminalColorize &&
        terminalPersisted &&
        identical(_colorizeTarget, snap);
  }

  /// Fast native JPEG decode for colorization — ImageIO decode at
  /// [kColorizeDecodeMaxPx] (= 全分辨率,见该常量的出处注释), raw sensor
  /// orientation (no EXIF transform), 3 B/px top-down.
  /// Returns null on any failure.
  int _colorizeDecodeW = 0;
  int _colorizeDecodeH = 0;
  int _colorizeDecodeMaxArea = 0;

  Future<({Uint8List rgb, int w, int h})?> _decodeJpegNative(
    String jpegPath,
  ) async {
    try {
      final res = await _arKitChannel.invokeMethod<Map<Object?, Object?>>(
        'decodeJpegForColor',
        {'jpegPath': jpegPath, 'maxPx': kColorizeDecodeMaxPx},
      );
      if (res == null) return null;
      final w = res['w'] as int?, h = res['h'] as int?;
      // [E25 遥测] 记住实际解码尺寸 —— 上一轮改成全分辨率后拿不出任何证据
      // 证明它生效(耗时几乎没变,因为 1280 本就不落 DCT 整除档、旧版也是
      // 全解再缩)。把尺寸打进 colorize 事件,下次一读便知。
      if (w != null && h != null && w * h > _colorizeDecodeMaxArea) {
        _colorizeDecodeMaxArea = w * h;
        _colorizeDecodeW = w;
        _colorizeDecodeH = h;
      }
      final rgb = res['rgb'] as Uint8List?;
      if (w == null || h == null || rgb == null || w <= 0 || h <= 0) {
        return null;
      }
      if (rgb.length < w * h * 3) {
        _noteColorizeDecodeFail('short_buffer');
        return null;
      }
      return (rgb: rgb, w: w, h: h);
    } catch (e) {
      // [E25 2026-07-20] 原本是 `catch (_) { return null; }` —— 把 native 抛的
      // 错误码整个吞掉,结果 colorize 遥测只能报 decode_fail=N,**永远查不出
      // 为什么**(2026-07-20 未命名7 出现 decode_fail=1,死因不可知)。
      // native 侧的码是有意义的:ar_decode_failed=文件打不开(被删/未写完)、
      // ar_decode_empty=尺寸为 0、ar_decode_bad_args=缺参数。记下来。
      _noteColorizeDecodeFail(e is PlatformException ? e.code : 'exception');
      return null;
    }
  }

  /// 取色解码失败原因计数,随 colorize 事件一起落遥测。
  final Map<String, int> _colorizeDecodeFailReasons = <String, int>{};
  void _noteColorizeDecodeFail(String code) {
    _colorizeDecodeFailReasons[code] =
        (_colorizeDecodeFailReasons[code] ?? 0) + 1;
  }

  /// Arm the iOS-26 continuation task only for an actual user-triggered finish.
  /// The capture directory is also the native idempotency key, so rebuilds or
  /// duplicate callbacks cannot create another Dynamic Island task.
  Future<void> _beginReconUmbrella(String captureDir) async {
    if (_reconUmbrellaJobID == captureDir) return;
    _reconUmbrellaJobID = captureDir;
    try {
      await _arKitChannel.invokeMethod<void>(
        'beginReconUmbrella',
        <String, Object?>{'jobId': captureDir},
      );
    } catch (_) {
      if (_reconUmbrellaJobID == captureDir) {
        _reconUmbrellaJobID = null;
      }
    }
  }

  /// Idempotent teardown after the final colored point cloud (or an error).
  Future<void> _endReconUmbrella() async {
    final jobID = _reconUmbrellaJobID;
    if (jobID == null) return;
    _reconUmbrellaJobID = null;
    try {
      await _arKitChannel.invokeMethod<void>(
        'endReconUmbrella',
        <String, Object?>{'jobId': jobID},
      );
    } catch (_) {}
  }

  /// 案④【灵动岛真实进度】:finalize 阶段边界把真实进度推给
  /// ReconUmbrella(Swift 侧与合成爬行曲线取 max,严格单调不回退;
  /// 100% 仍只由 endReconUmbrella 置)。锚点(46 号 segments 实测比例):
  /// phase1 done→0.10 / refined(RefineGlobalBA 全段完)→0.75 /
  /// colorize 完→0.85 / persist 落盘→0.95。阶段之间由 Swift 合成爬行
  /// 兜底递增(iOS 30s 看门狗保险)。伞未武装时静默 no-op。
  /// 遥测【island】:每次推送记 {p, stage}(t 由 TelemetryWriter 自加),
  /// 下次对账"岛显示 vs 真实进度"不再靠代码+时间轴反推。
  Future<void> _pushReconProgress(double fraction, String subtitle) async {
    if (_reconUmbrellaJobID == null) return;
    TelemetryWriter.instance.event('island', {
      'p': fraction,
      'stage': subtitle,
    });
    try {
      await _arKitChannel.invokeMethod<void>(
        'setReconProgress',
        <String, Object?>{'fraction': fraction, 'subtitle': subtitle},
      );
    } catch (_) {
      // Display-only channel — never let it disturb the finalize.
    }
  }

  /// "完成" on the preview overlay: tear the worker down (frees the native
  /// session + sqlite db) and run the exit the finish flow deferred.
  Future<void> _releaseLiveReconstructionResources() {
    return _sfmReleaseFuture ??= _releaseLiveReconstructionResourcesOnce();
  }

  Future<void> _releaseLiveReconstructionResourcesOnce() async {
    // The root FAB must not become enabled until dispose releases the
    // process-wide reconstruction lease.
    await _endReconUmbrella();
    _stopSfmStageTicker();
    final recon = _sfmRecon;
    final feedSub = _sfmFeedSub;
    final eventSub = _sfmEventSub;
    final failureSub = _highResFailureSub;
    await feedSub?.cancel();
    await eventSub?.cancel();
    await failureSub?.cancel();
    if (recon != null) await recon.dispose();
    if (identical(_sfmRecon, recon)) _sfmRecon = null;
    if (identical(_sfmFeedSub, feedSub)) _sfmFeedSub = null;
    if (identical(_sfmEventSub, eventSub)) _sfmEventSub = null;
    if (identical(_highResFailureSub, failureSub)) _highResFailureSub = null;
    _pendingSfmInputs.clear();
  }

  Future<void> _onSfmPreviewDone() async {
    if (_sfmPhase != SfmPreviewPhase.refined &&
        _sfmPhase != SfmPreviewPhase.error) {
      return;
    }
    if (_finishCoordinator.terminalOutcome == null) return;
    try {
      await _routeReleaseGate.release(
        releaseResources: () => _releaseLiveReconstructionResources().timeout(
          const Duration(seconds: 20),
        ),
        revealRoot: () {
          if (!mounted) return;
          final attempt = CaptureFinishAttempt(
            _finishCoordinator.currentGeneration,
          );
          if (!_finishCoordinator.beginExit(attempt)) return;
          final showDrafts =
              _finishCoordinator.exitIntent !=
              CaptureFinishExitIntent.discardCapture;
          Navigator.of(context).pop(showDrafts);
          _finishCoordinator.markExited(attempt);
        },
      );
    } on TimeoutException {
      _sfmReleaseFuture = null;
      if (!mounted) return;
      setState(() {
        _sfmPhase = SfmPreviewPhase.error;
        _sfmErrorText = '资源仍在安全释放，请稍后再试。照片已保留。';
      });
    } catch (error, stackTrace) {
      _sfmReleaseFuture = null;
      DeviceLog.log(
        'OfficialARCapturePage',
        'reconstruction release failed: $error\n$stackTrace',
      );
      if (!mounted) return;
      setState(() {
        _sfmPhase = SfmPreviewPhase.error;
        _sfmErrorText = '资源释放未完成，请稍后重试。照片已保留。';
      });
    }
  }

  /// [选区 2026-07-27] 等待页"下一步"→ 选区页。返回 'save_draft'(签决:
  /// 选区页返回不回等待页)→ 走与"保存草稿"完全同一的退出链路。
  /// 预览相机(骰子经 ValueListenable 跟随,不触发整页重建)。
  final ValueNotifier<CloudViewCamera?> _sfmPreviewCamera = ValueNotifier(null);
  final CloudViewController _sfmCloudController = CloudViewController();

  /// [2026-07-28 用户签决] "预览跟编辑就是一个页面":不再 push 选区页,
  /// 点"下一步"只把工具层叠到同一个预览视图上,相机原地不动。
  bool _sfmEditing = false;
  SelectionBox? _sfmBox;

  /// [SEL-DISCARD 2026-07-30 用户签决] 退到草稿页时问"编辑记录是否保存"。
  ///
  /// [2026-08-03 修正] 拖框只更新内存预览；正式选区记录只在用户点"完成"
  /// 后提交。取消或关闭放弃动作单都不能提前保存。基线回写仍保留，用于清理
  /// 旧版本可能已经提前落盘的记录。
  ///
  /// 基线在**第一次修改之前**抓取(而不是进编辑态时),因为用户可能进出编辑态
  /// 多次而一次都没动过框 —— 那种情况不该弹窗。null = 本次会话从未改过。
  SelectionBox? _sfmBoxBaseline;
  bool _sfmBoxBaselineWasAbsent = false;

  /// 底部"下一步":把这一份点云交给后续处理。
  ///
  /// 选区只在用户**真的**选过时才带上 —— 没选区就传 null 表示"处理整朵云"。
  Future<void> _startDenseStage() async {
    final dir = _session?.captureDir;
    final snap = _sfmSnapshot;
    if (dir == null || snap == null) return;
    final r = await denseStageLauncher.start(
      DenseStageRequest(
        captureDir: dir,
        sparsePlyPath: '$dir/official_sfm_sparse.ply',
        pointCount: snap.pointCount,
        selection: _sfmSelectionApplied ? _sfmBox : null,
      ),
    );
    if (!mounted || r.status == DenseStageStatus.started) return;
    final l = AppL10n.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(r.message ?? l.denseStageUnavailable)),
    );
  }

  Future<void> _enterSfmEditing() async {
    if (_sfmPhase != SfmPreviewPhase.refined) return;
    final snap = _sfmSnapshot;
    final dir = _session?.captureDir;
    if (snap == null || dir == null || snap.pointCount == 0) return;
    final fit = SparseCloudPainter.fitOf(snap.xyz);
    final loaded = await SelectionBox.loadFrom(dir);
    final sane =
        loaded != null &&
        loaded.isSaneFor(
          fitCx: fit.cx,
          fitCy: fit.cy,
          fitCz: fit.cz,
          fitRadius: fit.radius,
        );
    final frame = editingFrameOf(snap.xyz);
    final box = sane
        ? loaded
        : SelectionBox.initialSquareFace(
            cx: frame.center[0],
            cy: frame.center[1],
            cz: frame.center[2],
            halfExtent: math.max(frame.hx, math.max(frame.hy, frame.hz)),
          );
    if (!mounted) return;
    setState(() {
      _sfmEditEntryBox = box;
      _sfmEditEntryApplied = _sfmSelectionApplied;
      _sfmSelectionApplied = sane;
      _sfmBox = box;
      _sfmEditing = true;
    });
  }

  void _onSfmBoxChanged(SelectionBox b) {
    final previousApplied = _sfmSelectionApplied;
    // [SEL-DISCARD] 第一次修改时抓基线(见 _sfmBoxBaseline 的注释:必须是
    // "改之前"而不是"进编辑态时",否则进出而未改也会被判成脏)。
    if (_sfmBoxBaseline == null && !_sfmBoxBaselineWasAbsent) {
      final prev = _sfmBox;
      if (prev != null && !prev.sameAs(b)) {
        _sfmBoxBaseline = prev;
        // 初次打开时用于显示的兜底框不是正式选区。必须把“盘上原本没有
        // 选区”与框几何一起冻结，否则退页点“不保存”会反而写入兜底框。
        _sfmBoxBaselineWasAbsent = !previousApplied;
      } else if (prev == null) {
        _sfmBoxBaselineWasAbsent = true;
      }
    }
    // 用户动手改了框 ⇒ 从此这就是"他的选区",浏览态开始按它裁剪。
    _sfmSelectionApplied = true;
    setState(() => _sfmBox = b);
  }

  /// "恢复原始框大小":按当前点云重算初始框。
  void _resetSfmBoxSize() {
    final snap = _sfmSnapshot;
    if (snap == null) return;
    final frame = editingFrameOf(snap.xyz);
    _onSfmBoxChanged(
      SelectionBox.initialSquareFace(
        cx: frame.center[0],
        cy: frame.center[1],
        cz: frame.center[2],
        halfExtent: math.max(frame.hx, math.max(frame.hy, frame.hz)),
      ),
    );
  }

  /// 用户**真的**选过区吗 —— 没选过时预览呈现原始点云,不能拿按 AABB 算出来的
  /// 兜底框去裁(initialFor 留边距,会悄悄切掉外圈的点)。
  bool _sfmSelectionApplied = false;

  /// 进编辑态那一刻的框 —— "不保存"回滚到这里。
  SelectionBox? _sfmEditEntryBox;
  bool _sfmEditEntryApplied = false;

  /// 右上"完成":提交本次编辑,不问。
  ///
  /// [2026-07-30 用户签决"直接学苹果的相册"] 确认的负担只压在破坏性的那一侧。
  Future<void> _exitSfmEditing() async {
    final dir = _session?.captureDir;
    final b = _sfmBox;
    if (dir == null || b == null) return;
    await _persistSfmBox(b, dir, applied: _sfmSelectionApplied);
    if (!mounted) return;
    setState(() {
      _sfmEditing = false;
      _sfmBoxBaseline = null; // 已表态,下次修改重新抓基线
      _sfmBoxBaselineWasAbsent = false;
    });
  }

  /// 左上"取消":放弃本次编辑。没改过直接回浏览态;改过则弹苹果那张动作单,
  /// 点其它地方消失并留在编辑页。
  ///
  /// "放弃"是**真回滚**；编辑期只改内存，入口状态写回同时兼容清理旧版本
  /// 可能遗留的提前落盘记录。
  Future<void> _cancelSfmEditing() async {
    final dir = _session?.captureDir;
    final entry = _sfmEditEntryBox;
    final b = _sfmBox;
    if (dir == null) return;
    final dirty = entry != null && b != null && !b.sameAs(entry);

    if (dirty) {
      final confirmed = await showCupertinoModalPopup<bool>(
        context: context,
        builder: (ctx) => CupertinoActionSheet(
          title: Text(AppL10n.of(ctx).selectionDiscardTitle),
          actions: [
            CupertinoActionSheetAction(
              isDestructiveAction: true,
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(AppL10n.of(ctx).selectionDiscardConfirm),
            ),
          ],
        ),
      );
      if (confirmed != true) return; // 点了动作单以外的地方 ⇒ 留在编辑页
    }

    final finalBox = entry ?? b;
    final finalApplied = entry != null
        ? _sfmEditEntryApplied
        : _sfmSelectionApplied;
    if (finalBox != null) {
      await _persistSfmBox(finalBox, dir, applied: finalApplied);
    }
    if (!mounted) return;
    setState(() {
      _sfmEditing = false;
      if (finalBox != null) _sfmBox = finalBox;
      _sfmSelectionApplied = finalApplied;
      _sfmBoxBaseline = null;
      _sfmBoxBaselineWasAbsent = false;
    });
  }

  /// 落盘;[applied] 为假表示"用户没有选区",此时删掉文件而不是留一个兜底的
  /// 全域框冒充选区。
  Future<void> _persistSfmBox(
    SelectionBox box,
    String dir, {
    required bool applied,
  }) async {
    if (applied) {
      await box.saveTo(dir);
      return;
    }
    try {
      final f = File('$dir/$kSelectionBoxFileName');
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }

  /// [SEL-DISCARD 2026-07-30 用户签决] 退到草稿页前问"编辑记录是否保存"。
  ///
  /// 只在本次会话真的改过框时才问 —— 进出编辑态而没动过框不该被打断。
  /// "不保存"回滚到基线并写盘；显式回写兼容旧版本可能留下的提前落盘记录。
  /// 返回 true = 可以离开。
  Future<bool> _confirmLeaveWithSelectionEdits() async {
    final baseline = _sfmBoxBaseline;
    if (baseline == null) return true; // 没改过 → 直接走
    final l = AppL10n.of(context);
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(l.sfmSelectionSaveTitle),
        content: Text(l.sfmSelectionSaveBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: Text(l.sfmSelectionSaveCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('discard'),
            child: Text(l.sfmSelectionSaveDiscard),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('keep'),
            child: Text(l.sfmSelectionSaveKeep),
          ),
        ],
      ),
    );
    if (choice == null || choice == 'cancel') return false;
    final dir = _session?.captureDir;
    if (choice == 'discard') {
      // 回滚到编辑前的正式状态。若当时盘上没有选区，删除旧版本可能提前
      // 写入的记录；不能把仅用于显示的兜底框冒充成用户保存的选区。
      if (dir != null) {
        await _persistSfmBox(baseline, dir, applied: !_sfmBoxBaselineWasAbsent);
      }
      if (mounted) {
        setState(() {
          _sfmBox = baseline;
          _sfmSelectionApplied = !_sfmBoxBaselineWasAbsent;
        });
      }
    } else if (dir != null && _sfmBox != null) {
      await _persistSfmBox(_sfmBox!, dir, applied: _sfmSelectionApplied);
    }
    _sfmBoxBaseline = null; // 本次编辑已裁决,下次修改重新抓基线
    _sfmBoxBaselineWasAbsent = false;
    TelemetryWriter.instance.event('selection_leave', {
      'choice': choice,
      'was_editing': _sfmEditing,
    });
    return true;
  }

  /// 返回草稿页的统一入口 —— 先过选区保存裁决,再让草稿层显现。
  Future<void> _onSfmPreviewBack() async {
    if (!await _confirmLeaveWithSelectionEdits()) return;
    if (!mounted) return;
    _showDraftsDuringReconstruction();
  }

  Future<void> _permanentlyDeleteActiveReconstruction(ScanRecord record) async {
    if (!recordOwnsActiveReconstruction(
      recordCaptureDir: record.captureDir,
      recordPipelineKind: record.pipelineKind,
      activeCaptureDir: _session?.captureDir,
      activePipelineKind: CapturePipelineKind.official,
    )) {
      return;
    }
    final released = await _routeReleaseGate.release(
      releaseResources: () async {
        await _releaseLiveReconstructionResources();
        final session = _session;
        _session = null;
        await session?.dispose();
      },
      revealRoot: () {},
    );
    if (!released) return;

    await ScanRecordStore.instance.delete(record.id);
    if (mounted) Navigator.of(context).pop(true);
  }

  /// Reveal Drafts without disposing the capture route or touching SfM.
  void _showDraftsDuringReconstruction() {
    if (_sfmPhase == null || _showDraftsWhileReconstructing) return;
    setState(() => _showDraftsWhileReconstructing = true);
  }

  /// Called only by the matching active draft card.
  void _showReconstructionProgress() {
    if (_sfmPhase == null || !_showDraftsWhileReconstructing) return;
    setState(() => _showDraftsWhileReconstructing = false);
  }

  void _setDraftRecordActionInProgress(bool active) {
    if (!mounted || _draftRecordActionInProgress == active) return;
    setState(() => _draftRecordActionInProgress = active);
  }

  void _scheduleDraftTerminalExitIfNeeded() {
    final terminal =
        _sfmPhase == SfmPreviewPhase.refined ||
        _sfmPhase == SfmPreviewPhase.error;
    if (_draftTerminalExitScheduled ||
        !shouldAutoExitReconstructionDrafts(
          showingDrafts: _showDraftsWhileReconstructing,
          reconstructionTerminal: terminal,
          recordActionInProgress: _draftRecordActionInProgress,
        )) {
      return;
    }
    _draftTerminalExitScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _draftTerminalExitScheduled = false;
      if (!mounted) return;
      final stillTerminal =
          _sfmPhase == SfmPreviewPhase.refined ||
          _sfmPhase == SfmPreviewPhase.error;
      if (!shouldAutoExitReconstructionDrafts(
        showingDrafts: _showDraftsWhileReconstructing,
        reconstructionTerminal: stillTerminal,
        recordActionInProgress: _draftRecordActionInProgress,
      )) {
        return;
      }
      unawaited(_onSfmPreviewDone());
    });
  }

  // ─── 自动采集接线 ──────────────────────────────────────────────────
  // 只有接线。任何"要不要拍"的判断都在 auto_capture_governor.dart。

  /// 自动拍看到的"已拍张数"。
  ///
  /// 必须与队列的 admission 口径**逐字一致**:ManualCaptureQueue 收人的条件
  /// 是 `verifiedCount + outstandingCount < 300`(manual_capture_queue.dart),
  /// 而 governor 停在 `capturedCount >= 300`。只报 `_projectPhotos.count`
  /// 会少算在途票(一秒一张时常有 1–3 张),两边就永远对不上 —— controller
  /// 等不到那个该让它停的数,只会每帧撞一次已经关上的门。
  /// 与 [_ManualCaptureBar] 里 officialCaptureCanShoot 用的是同一个表达式。
  int _autoCaptureAcceptedFrameCount() =>
      _projectPhotos.count + _shutterQueue.outstandingCount;

  /// 能不能起跑。前三条与手动快门的置灰判据同源(自动拍走的就是同一条入队
  /// 路径,它不该在手动快门已被判死时还能开火);第四条是"AR 会话在,pose
  /// 确实在流"—— 退后台时我们已经把自动拍停掉了,所以这一条足够。
  bool get _autoCaptureCanStart => autoCaptureCanStart(
    captureReady: _captureAdmissionOpen,
    queueAccepting: _shutterQueue.accepting,
    withinFrameBudget: officialCaptureCanShoot(
      acceptedFrameCount: _autoCaptureAcceptedFrameCount(),
    ),
    posesFlowing: _session != null,
  );

  /// 把一帧 pose 喂给 controller,并把结果映射成 UI 状态。
  ///
  /// **判定一行都不在这里** —— 全在 AutoCaptureController / Governor。
  void _driveAutoCapture(ARPose pose) {
    if (_captureMode != OfficialCaptureMode.auto) {
      // 模式已经切走,挂起的起跑作废 —— 否则切回自动时会莫名其妙自己开拍。
      _autoStartPending = false;
      return;
    }
    if (_autoStartPending) {
      _autoStartPending = false;
      // 用**这一帧**起跑,不用缓存的"最近一帧":见 _autoStartPending 的注释。
      _startAutoCapture(pose);
      return; // 起跑帧只播种,不判定。
    }
    if (!_autoCapture.isRunning) {
      // 观测。这是这条链上的第二个静默出口:遥测 recordDecision 在它**之后**,
      // 所以治理器没起来时 auto_capture 一条都采不到,现象与"起来了但一直
      // 不开火"在日志上**完全同形**。2026-08-31 那场就卡在这个歧义里。
      //
      // 每帧都会走到(30–60 Hz),所以按 5 秒节流,时钟取 pose.timestamp
      // ——与 controller 同一条 ARFrame 时间轴。本页的时钟纪律由
      // auto_capture_page_wiring_test 守着,它连注释里提到别的时钟来源都
      // 不放过(本注释第一版就是这么被判红的),那样很好:这条判据宁可
      // 误伤也不该漏。纯观测,不改变这条 return。
      if (_autoIdleProbeLastSec < 0 ||
          pose.timestamp - _autoIdleProbeLastSec >= 5.0) {
        _autoIdleProbeLastSec = pose.timestamp;
        TelemetryWriter.instance.event('auto_capture_idle', {
          'reason': 'controller_not_running',
          'mode': _captureMode.name,
          'pending': _autoStartPending,
          'can_start': _autoCaptureCanStart,
          'accepted_frame_count': _autoCaptureAcceptedFrameCount(),
          't_sec': pose.timestamp,
        });
      }
      return;
    }
    // 开火钩子在 onPose **内部**同步跑完,并且只在**真的入队成功**时把这个
    // 令牌 +1(见 _onAutoCaptureFire)。所以前后一比就知道这一帧到底落没落。
    final pulseBefore = _autoFirePulseToken;
    final decision = _autoCapture.onPose(pose);
    // 遥测【auto_capture】:**每个**判定都记(spec §11)。
    //
    // ⚠️ 位置必须在下面那条提前 return **之前**:稳定态判定
    // (skipPaced / skipNotMoved)占绝大多数,而它们正好全都走那条 return
    // ——记在后面等于一条都采不到,偏偏 skipNotMoved 的占比正是这套遥测
    // 存在的理由(spec §9 差异1:视差下限到底有没有用)。
    //
    // 时钟用 pose.timestamp(ARFrame 时间轴,与 controller 同一条);
    // 档位用 _shutterPace —— 与 controller 的 paceProvider **同一个字段**,
    // 换个来源就会与 governor 实际用的 tick 间隔对不上。
    _autoTelemetry.recordDecision(
      decision,
      tSec: pose.timestamp,
      pace: _shutterPace,
      // 与 controller 的 thermalStateProvider **同一个字段** —— fire_before_tick
      // 用的间隔必须与 governor 实际用的逐位相同,否则热机时会算漏。
      thermalState: _lastThermalState,
      // 开火那一刻的位移/阈值/转角/活体深度 —— 见 recordDecision 里的理由。
      // 全部取自 controller 判定时用的那份状态(或其同帧记忆化),不重算:
      // 重算 = 又造一个可能与判定不一致的数。
      movedM: _autoCapture.lastMovedM,
      fireDistM: _autoCapture.lastFireDistM,
      turnDeg: _autoCapture.lastTurnDeg,
      // 锐度缓拍门疗效对(开火帧锐度 vs 段中位),取自 controller 判定
      // 时的同一份状态,不重算。
      sharpness: _autoCapture.lastSharpness,
      segMedianSharpness: _autoCapture.lastSegmentMedianSharpness,
      motion: _autoCapture.lastMotionMetrics,
      motionRole: _autoCapture.lastMotionRole,
      geometryParallaxDeg: _autoCapture.lastGeometryParallaxDeg,
      overlapFraction: _autoCapture.lastOverlapFraction,
      depthScaleRatio: _autoCapture.lastDepthScaleRatio,
      visualSimilarity: _autoCapture.lastVisualSimilarity,
      trackCommonCount: _autoCapture.lastTrackEvidence?.commonTrackCount,
      trackCommonFraction: _autoCapture.lastTrackEvidence?.commonTrackFraction,
      trackMedianNormalizedDisplacement:
          _autoCapture.lastTrackEvidence?.medianNormalizedDisplacement,
      trackMedianStepPixelDisplacement:
          _autoCapture.lastTrackEvidence?.medianStepPixelDisplacement,
      vinsTrackedCount: _autoCapture.lastTrackEvidence?.vinsTrackedCount,
      vinsActiveTrackCount:
          _autoCapture.lastTrackEvidence?.vinsActiveTrackCount,
      vinsReplenishedTrackCount:
          _autoCapture.lastTrackEvidence?.vinsReplenishedTrackCount,
      vinsLongestTrackAge: _autoCapture.lastTrackEvidence?.vinsLongestTrackAge,
      vinsMeanStepNormalizedParallax:
          _autoCapture.lastTrackEvidence?.vinsMeanStepNormalizedParallax,
      vinsGeometricInputCount:
          _autoCapture.lastTrackEvidence?.vinsGeometricInputCount,
      vinsGeometricInlierCount:
          _autoCapture.lastTrackEvidence?.vinsGeometricInlierCount,
      vinsGeometricInlierFraction:
          _autoCapture.lastTrackEvidence?.vinsGeometricInlierFraction,
      vinsOccupiedGridFraction:
          _autoCapture.lastTrackEvidence?.vinsOccupiedGridFraction,
      vinsClaheApplied: _autoCapture.lastTrackEvidence?.vinsClaheApplied,
      visualSourceAgeSec: _autoCapture.lastVisualSourceAgeSec,
    );
    // isRunning 由 true 翻 false = controller 自停(撞 300 张或 5 分钟)。
    // 这里读的是 isRunning 而不是 decision:停机后 onPose 恒返回
    // skipNotMoved,与"你还没动够"逐字相同(见 autoCaptureIndicatorFor)。
    final running = _autoCapture.isRunning;
    if (running) {
      _emitAutoTelemetry(_autoTelemetry.snapshotIfDue(pose.timestamp));
    } else {
      // 自停这条路**不经过** _stopAutoCapture(它开头就 `if (!isRunning)
      // return;`)。不在这里收口,恰恰是最该被记下来的那两种收场
      //(撞 300 张 / 撞 5 分钟上限)一行都写不出来。
      _emitAutoTelemetry(_autoTelemetry.recordSessionEnd());
    }
    // ⚠️ 判据是「令牌变了 = **真的落了一帧**」,不是 `decision == fire`
    // 〔2026-08-19 评审改正〕。两处理由:
    //   ① 开火 ≠ 拍成(spec §7,遥测层正是为此把 fire_admitted /
    //      fire_busy_not_admitted 分开记);拿 fire 当"落帧"会在 busy 时
    //      给用户一个**假的正反馈** —— 红键脉冲一下、N/300 一动不动,
    //      而自动模式下那颗红键的脉冲是"到底拍上没有"的唯一反馈。
    //   ② `fired == true` 会跳过这条短路。入队持续失败时(SfM 内部故障)
    //      判定会连着好几帧是 fire,于是这个 4800 行的页面被每帧重建一次
    //      —— 正是这段注释自己要避免的那个热源。
    final landed = _autoFirePulseToken != pulseBefore;
    if (!landed &&
        decision == _lastAutoDecision &&
        running == _autoRunningLastSeen) {
      // pose 流是 20–60 Hz。没有任何变化时不重建整页 —— 每帧 setState
      // 会把这个 4800 行的页面变成一个热源。
      return;
    }
    _lastAutoDecision = decision;
    _autoRunningLastSeen = running;
    if (mounted) setState(() {});
  }

  /// 自动采集遥测的**唯一**落盘出口:走既有的 TelemetryWriter →
  /// App 容器 `Documents/telemetry_official_dart.jsonl`,与 frame /
  /// queue_drain / shutter_pace 同一个文件,真机拔线跑完 `devicectl copy`
  /// 一次拉走。**不另起遥测通道**(多一条出口就多一处会漏采的地方),
  /// 也不 print —— print 只到 stdout,拔线测试后根本取不回来。
  ///
  /// [snap] 为 null 意为"这一刻没有该写的行"(没到 5 秒节流点,或会话
  /// 根本没开着)—— 节流与幂等都收在 AutoCaptureTelemetry 里,这里只负责写。
  void _emitAutoTelemetry(Map<String, Object>? snap) {
    if (snap == null) return;
    TelemetryWriter.instance.event('auto_capture', snap);
  }

  void _startAutoCapture(ARPose seed) {
    if (_autoCapture.isRunning) return;
    // 遥测起点取**起跑那一帧**的 ARFrame 时间戳(与 controller.start(seed)
    // 收到的是同一个 pose)。本页别处用的 DateTime.now() 是另一个纪元,
    // 混进来什么都不会抛,只会把时长与节流一起静默算错。
    _autoTelemetry.recordSessionStart(seed.timestamp);
    _lastAutoDecision = AutoCaptureDecision.skipNotMoved;
    // start() 会同步尝试首张锚点入队；队列 admission 不能藏在 setState 回调里。
    _autoCapture.start(seed);
    _autoRunningLastSeen = _autoCapture.isRunning;
    if (mounted) setState(() {});
  }

  void _stopAutoCapture() {
    _autoStartPending = false;
    if (!_autoCapture.isRunning) return;
    _autoCapture.stop();
    // 用户停 / 切模式 / 退后台 / 完成 —— 这一轮到此为止,写终态行。
    _emitAutoTelemetry(_autoTelemetry.recordSessionEnd());
    _autoRunningLastSeen = false;
    if (mounted) setState(() {});
  }

  void _setCaptureMode(OfficialCaptureMode mode) {
    if (_captureMode == mode) return;
    // 切走自动 ⇒ 自动拍立即停。**已拍帧全部保留**、队列继续消化
    // (spec §7 第一条:切模式是 UI 行为,不该动数据)。
    if (mode != OfficialCaptureMode.auto) _stopAutoCapture();
    setState(() {
      _captureMode = mode;
      // 切到自动**不开拍**(spec §7 / §8.1),只浮一条提示说明模式变了。
      if (mode == OfficialCaptureMode.auto) _autoModeToastToken++;
    });
  }

  void _toggleAutoRun() {
    // 观测。这条链上此前**一个埋点都没有**:模式、这次点击、四个起跑条件的
    // 各自取值、以及"起跑被拦下"这件事本身,日志里全都查不到。2026-08-31
    // 有一场自动拍从头到尾没开火,只能证明「治理器没在跑」,证明不了「为什么」
    // ——四个条件合成一个布尔,`if (!_autoCaptureCanStart) return;` 静默吃掉
    // 了原因。记录**每个条件各自的值**,不是记那个合成布尔,否则下次仍然只
    // 知道"没起来"。纯观测,不改变任何一条判定。
    final captureReady = _captureAdmissionOpen;
    final queueAccepting = _shutterQueue.accepting;
    final withinFrameBudget = officialCaptureCanShoot(
      acceptedFrameCount: _autoCaptureAcceptedFrameCount(),
    );
    final posesFlowing = _session != null;
    final canStart = autoCaptureCanStart(
      captureReady: captureReady,
      queueAccepting: queueAccepting,
      withinFrameBudget: withinFrameBudget,
      posesFlowing: posesFlowing,
    );
    final String action;
    if (_autoStartPending) {
      action = 'cancel_pending';
    } else if (_autoCapture.isRunning) {
      action = 'stop';
    } else if (!canStart) {
      action = 'blocked';
    } else {
      action = 'arm';
    }
    TelemetryWriter.instance.event('auto_capture_toggle', {
      'action': action,
      'mode': _captureMode.name,
      'capture_ready': captureReady,
      'queue_accepting': queueAccepting,
      'within_frame_budget': withinFrameBudget,
      'poses_flowing': posesFlowing,
      'can_start': canStart,
      'was_running': _autoCapture.isRunning,
      'was_pending': _autoStartPending,
      'accepted_frame_count': _autoCaptureAcceptedFrameCount(),
    });

    if (_autoStartPending) {
      // 起跑还没落到帧上,再点一下就是取消。
      setState(() => _autoStartPending = false);
      return;
    }
    if (_autoCapture.isRunning) {
      _stopAutoCapture();
      return;
    }
    if (!_autoCaptureCanStart) return;
    // 这里**不**直接 start():起跑帧必须是 pose 回调里的那一帧本身,
    // 见 _autoStartPending 的注释。代价至多一帧(17–50 ms)。
    setState(() => _autoStartPending = true);
  }

  /// 自动拍的触发口。**返回 true = 真的入队成功** —— controller 据此决定
  /// 要不要把基准帧推到这一帧上。报假的 true 会把基准帧钉在一个**根本没有
  /// 照片**的位置上,此后位移闸系统性欠触发,正是 T3 要防的那件事。
  ///
  /// 与 [_onShutterTap] 的唯一区别:到 300 张时**不弹对话框** —— 自动模式
  /// 每个 tick 撞一次,弹窗会刷屏。到顶由 controller 自停(它的
  /// capturedCountProvider 与队列同口径,见 [_autoCaptureAcceptedFrameCount])。
  ///
  /// **契约:绝不抛。** 异常穿出去会打断整条 pose 回调(覆盖云、预警横幅、
  /// 暖机判定都挂在上面)。入队路径里有平台通道与磁盘工作,不能假设它永远
  /// 干净,所以一律按"没入队"处理 —— 基准帧因此不动,下一 tick 自然重试。
  bool _onAutoCaptureStartAnchor(AutomaticStillTicket automaticStillTicket) {
    try {
      final enqueued = _enqueueShutterCapture(
        automaticSelection: true,
        automaticStillTicket: automaticStillTicket,
      );
      _autoTelemetry.recordStartAnchorOutcome(enqueued: enqueued);
      return enqueued;
    } catch (e) {
      _autoTelemetry.recordStartAnchorOutcome(enqueued: false);
      DeviceLog.log(
        'OfficialARCapturePage',
        'auto capture start anchor enqueue failed: $e',
      );
      return false;
    }
  }

  bool _onAutoCaptureFire(AutomaticStillTicket automaticStillTicket) {
    try {
      final enqueued = _enqueueShutterCapture(
        automaticSelection: true,
        automaticStillTicket: automaticStillTicket,
      );
      // spec §7「入队失败 ⇒ 基准帧不更新 + **记遥测**」。这里是全链路唯一
      // 拿得到真实入队结果的地方 —— 判定层只知道"开了一枪"。
      _autoTelemetry.recordFireOutcome(admitted: enqueued);
      // spec §8「**落帧**时 → 指示器脉冲一次」。脉冲与 fire_admitted 在
      // **同一处**记账,屏幕与遥测因此不可能说两套话
      //〔2026-08-19 评审改正:此前脉冲挂在 `decision == fire` 上,
      // 入队失败也照样脉冲〕。
      return enqueued;
    } catch (e) {
      _autoTelemetry.recordFireOutcome(admitted: false);
      DeviceLog.log('OfficialARCapturePage', 'auto capture enqueue failed: $e');
      return false;
    }
  }

  /// O(1) UI admission only. Camera, JPEG, disk, and SfM work are serialized
  /// by [_shutterQueue] after this callback has already returned.
  void _onShutterTap() {
    switch (_admitShutterCapture()) {
      case _ShutterAdmission.budgetExhausted:
        unawaited(_showMaximumPhotosDialog());
        break;
      case _ShutterAdmission.busyNotAdmitted:
        _showManualShutterBusyFeedback();
        break;
      case _ShutterAdmission.admitted || _ShutterAdmission.closed:
        break;
    }
  }

  /// 快门的**唯一**入队路径:手动 tap 与自动拍都走这里。
  ///
  /// 三道守卫与 300 张上限判据因此只有一份。给自动拍抄第二份守卫迟早会漏掉
  /// 其中一条 —— 尤其是 `_shutterQueue.accepting`,它只在收尾流程
  /// (freezeAndDrain / cancelPending)期间为 false,平时测不出来。
  _ShutterAdmission _admitShutterCapture({
    bool automaticSelection = false,
    AutomaticStillTicket? automaticStillTicket,
  }) {
    if (_session == null ||
        !_captureAdmissionOpen ||
        !_shutterQueue.accepting) {
      return _ShutterAdmission.closed;
    }
    // High-resolution capture is a shared real-time single-flight
    // transaction. A second manual tap or automatic selection while the one
    // native request is active is not admitted and therefore cannot become a
    // stale FIFO ticket. Busy is not the 300-photo budget condition.
    if (_shutterQueue.outstandingCount > 0) {
      return _ShutterAdmission.busyNotAdmitted;
    }
    if (_projectPhotos.count >= kOfficialMaximumCaptureFrames) {
      return _ShutterAdmission.budgetExhausted;
    }
    final ticket = _shutterQueue.enqueue(
      verifiedCount: _projectPhotos.count,
      automaticSelection: automaticSelection,
      automaticStillTicket: automaticStillTicket,
    );
    if (ticket == null) return _ShutterAdmission.busyNotAdmitted;
    return _ShutterAdmission.admitted;
  }

  /// [_admitShutterCapture] 的布尔视图,给 [AutoCaptureController.onFire]。
  bool _enqueueShutterCapture({
    bool automaticSelection = false,
    AutomaticStillTicket? automaticStillTicket,
  }) =>
      _admitShutterCapture(
        automaticSelection: automaticSelection,
        automaticStillTicket: automaticStillTicket,
      ) ==
      _ShutterAdmission.admitted;

  void _showManualShutterBusyFeedback() {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('上一张照片正在保存，请稍候'),
          behavior: SnackBarBehavior.floating,
          duration: Duration(milliseconds: 900),
        ),
      );
  }

  Future<void> _showMaximumPhotosDialog() async {
    if (!mounted || _maximumPhotosDialogOpen) return;
    _maximumPhotosDialogOpen = true;
    try {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          key: const ValueKey<String>('official-maximum-photos-dialog'),
          title: const Text('已达 $kOfficialMaximumCaptureFrames 张上限'),
          content: const Text(
            '单次任务最多拍摄 $kOfficialMaximumCaptureFrames 张照片。\n'
            '点击右下角箭头结束拍摄并开始重建。',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('好'),
            ),
          ],
        ),
      );
    } finally {
      _maximumPhotosDialogOpen = false;
    }
  }

  /// Serial executor for one admitted shutter ticket. This preserves the
  /// production native transaction and canonical 4032x3024 on-disk JPEG.
  Future<void> _executeShutterTicket(ManualCaptureTicket ticket) async {
    final session = _session;
    if (session == null) {
      throw StateError('accepted shutter ticket has no capture session');
    }
    final queueWaitMicros =
        DateTime.now().microsecondsSinceEpoch - ticket.tapTimestampMicros;
    final tapMs = ticket.tapTimestampMicros ~/ 1000;
    final gapMs = _lastShutterMs > 0 ? tapMs - _lastShutterMs : -1;
    _lastShutterMs = tapMs;
    final shutterSw = Stopwatch()..start();
    final capture = await session.captureSinglePhoto(
      automaticSelection: ticket.automaticSelection,
    );
    if (capture == null) {
      throw StateError('accepted shutter ticket could not start');
    }
    DeviceLog.log(
      'OfficialARCapturePage',
      'shutter ticket=${ticket.id} queue_wait_us=$queueWaitMicros '
          'capture_start_wait_ms=${shutterSw.elapsedMilliseconds} '
          'sfmPhase=$_sfmPhase',
    );
    TelemetryWriter.instance.event('shutter_admit', {
      'ticket_id': ticket.id,
      'tap_timestamp_us': ticket.tapTimestampMicros,
      'queue_wait_us': queueWaitMicros,
      'automatic_selection': ticket.automaticSelection,
      'verified_at_start': _projectPhotos.count,
      'outstanding_at_start': _shutterQueue.outstandingCount,
    });
    _activePhotoFeedbackTransactionId = capture.transactionId;
    _activePhotoFeedbackEvidencePath = capture.evidenceJpegPath;
    _photoTransactionIdsByEvidencePath[capture.evidenceJpegPath] =
        capture.transactionId;
    if (ticket.automaticSelection) {
      _automaticTicketByTransaction[capture.transactionId] =
          ticket.automaticStillTicket!;
    }
    try {
      late final OfficialHighResReconstructionInput input;
      try {
        input = await capture.highResolutionCompletion;
      } catch (_) {
        await _discardPhotoFeedback(
          capture.evidenceJpegPath,
          transactionId: capture.transactionId,
        );
        if (ticket.automaticSelection) {
          await _deleteRejectedAutomaticCandidate(capture);
        }
        rethrow;
      }
      AcceptedPhotoRecord? canonicalRecord;
      for (final record in session.canonicalPhotoSnapshot) {
        if (record.transactionId == capture.transactionId) {
          canonicalRecord = record;
          break;
        }
      }
      if (canonicalRecord == null) {
        throw StateError(
          '12MP completion returned without a canonical membership record',
        );
      }
      await _projectCanonicalPhoto(session, canonicalRecord);
      if (ticket.automaticSelection) {
        if (!session.commitAutomaticActualPhoto(input)) {
          throw const OfficialHighResCaptureException(
            OfficialHighResInputFailure.captureFailed,
            message:
                'canonical automatic still failed its compatibility receipt',
          );
        }
        _autoTelemetry.recordAutomaticStillReceipt(
          accepted: true,
          reason: 'accepted',
        );
      }
      if (!mounted ||
          _failedEvidenceJpegPaths.contains(capture.evidenceJpegPath)) {
        await _discardPhotoFeedback(
          capture.evidenceJpegPath,
          transactionId: capture.transactionId,
        );
        throw StateError('accepted 12MP photo cannot publish capture feedback');
      }
      // Both manual and automatic capture converge here. Native holds this
      // method-channel result until the exact high-res pose card has participated
      // in a rendered SceneKit frame; it emits the haptic in that same completion.
      // A private candidate rejected above never reaches this transaction.
      await _commitAcceptedPhotoFeedback(capture, input);
      if (ticket.automaticSelection) {
        _autoFirePulseToken++;
      }
      _recomputeShutterPace();
      TelemetryWriter.instance.event('shutter', {
        'ticket_id': ticket.id,
        'tap_timestamp_us': ticket.tapTimestampMicros,
        'queue_wait_us': queueWaitMicros,
        'automatic_selection': ticket.automaticSelection,
        'wait_ms': shutterSw.elapsedMilliseconds,
        'gap_ms': gapMs,
        'transaction_ms': shutterSw.elapsedMilliseconds,
        'capture_timestamp': input.captureTimestamp,
        'phase': _sfmPhase?.name,
        'jpeg': capture.evidenceJpegPath.split('/').last,
      });
    } finally {
      if (capture.transaction.dataOutcome !=
          AcceptedPhotoDataOutcome.accepted) {
        _automaticTicketByTransaction.remove(capture.transactionId);
      }
      if (_activePhotoFeedbackTransactionId == capture.transactionId) {
        _activePhotoFeedbackTransactionId = null;
        _activePhotoFeedbackEvidencePath = null;
      }
    }
  }

  Future<bool> _commitAcceptedPhotoFeedback(
    OfficialManualCaptureResult capture,
    OfficialHighResReconstructionInput input,
  ) async {
    if (!mounted ||
        input.jpegPath != capture.evidenceJpegPath ||
        _failedEvidenceJpegPaths.contains(input.jpegPath)) {
      await _discardPhotoFeedback(
        capture.evidenceJpegPath,
        transactionId: capture.transactionId,
      );
      return false;
    }
    if (!_finishCoordinator.captureAdmissionOpen) {
      final outcome = await _suppressPhotoPresentation(
        transactionId: capture.transactionId,
        evidenceJpegPath: input.jpegPath,
      );
      _session?.resolvePhotoPresentation(capture.transaction, outcome);
      return outcome != AcceptedPhotoPresentationOutcome.failed;
    }
    try {
      final receipt = await _arKitChannel.invokeMapMethod<String, dynamic>(
        'commitAcceptedPhotoFeedback',
        <String, dynamic>{
          'transactionId': capture.transactionId,
          'evidenceJpegPath': input.jpegPath,
        },
      );
      final outcome = acceptedPhotoPresentationOutcomeFromReceipt(receipt);
      _session?.resolvePhotoPresentation(capture.transaction, outcome);
      if (outcome == AcceptedPhotoPresentationOutcome.failed) {
        DeviceLog.log(
          'OfficialARCapturePage',
          'photo data accepted; presentation receipt failed '
              'transaction=${capture.transactionId}',
        );
      }
      return outcome != AcceptedPhotoPresentationOutcome.failed;
    } catch (error, stackTrace) {
      _session?.resolvePhotoPresentation(
        capture.transaction,
        AcceptedPhotoPresentationOutcome.failed,
      );
      DeviceLog.log(
        'OfficialARCapturePage',
        'commitAcceptedPhotoFeedback failed: $error\n$stackTrace',
      );
      return false;
    }
  }

  Future<AcceptedPhotoPresentationOutcome> _suppressPhotoPresentation({
    required String transactionId,
    required String evidenceJpegPath,
  }) async {
    try {
      final receipt = await _arKitChannel.invokeMapMethod<String, dynamic>(
        'suppressPhotoFeedbackPresentation',
        <String, dynamic>{
          'transactionId': transactionId,
          'evidenceJpegPath': evidenceJpegPath,
        },
      );
      return acceptedPhotoPresentationOutcomeFromReceipt(receipt);
    } catch (error, stackTrace) {
      DeviceLog.log(
        'OfficialARCapturePage',
        'suppressPhotoFeedbackPresentation failed: $error\n$stackTrace',
      );
      return AcceptedPhotoPresentationOutcome.failed;
    }
  }

  Future<void> _suppressActivePhotoPresentationForFinish() async {
    final active = _session?.activePhotoTransaction;
    final transactionId =
        active?.transactionId ?? _activePhotoFeedbackTransactionId;
    final evidenceJpegPath =
        active?.evidenceJpegPath ?? _activePhotoFeedbackEvidencePath;
    if (transactionId == null || evidenceJpegPath == null) return;
    if (active != null) {
      _session?.resolvePhotoPresentation(
        active.transaction,
        AcceptedPhotoPresentationOutcome.suppressed,
      );
    }
    final nativeOutcome = await _suppressPhotoPresentation(
      transactionId: transactionId,
      evidenceJpegPath: evidenceJpegPath,
    );
    if (nativeOutcome != AcceptedPhotoPresentationOutcome.suppressed) {
      DeviceLog.log(
        'OfficialARCapturePage',
        'native Finish suppression receipt was ${nativeOutcome.name} '
            'transaction=$transactionId',
      );
    }
  }

  Future<void> _discardPhotoFeedback(
    String evidenceJpegPath, {
    String? transactionId,
  }) async {
    try {
      await _arKitChannel
          .invokeMethod<void>('discardPhotoFeedback', <String, dynamic>{
            if (transactionId != null) 'transactionId': transactionId,
            'evidenceJpegPath': evidenceJpegPath,
          });
    } catch (error) {
      DeviceLog.log(
        'OfficialARCapturePage',
        'discardPhotoFeedback failed: $error',
      );
    }
  }

  Future<void> _removePhotoCard({
    required String transactionId,
    required String evidenceJpegPath,
  }) async {
    try {
      await _arKitChannel.invokeMethod<void>(
        'removePhotoCard',
        <String, dynamic>{
          'transactionId': transactionId,
          'evidenceJpegPath': evidenceJpegPath,
        },
      );
    } catch (error) {
      DeviceLog.log('OfficialARCapturePage', 'removePhotoCard failed: $error');
    }
  }

  void _onShutterTicketError(
    ManualCaptureTicket ticket,
    Object error,
    StackTrace stackTrace,
  ) {
    if (ticket.automaticSelection) {
      _autoTelemetry.recordAutomaticStillReceipt(
        accepted: false,
        reason: error is OfficialHighResCaptureException
            ? error.failure.name
            : error.runtimeType.toString(),
      );
      final rejectedInput = error is OfficialHighResCaptureException
          ? error.rejectedInput
          : null;
      final rejectedGray = rejectedInput?.gray128;
      _autoCapture.resolveAutomaticStill(
        ticket: ticket.automaticStillTicket!,
        accepted: false,
        rejectedStill:
            rejectedInput == null ||
                rejectedGray == null ||
                rejectedGray.length != 128 * 128
            ? null
            : RejectedAutomaticStillEvidence(
                gray128: rejectedGray,
                intrinsics: AutoCaptureIntrinsics(
                  fx: rejectedInput.intrinsics[0],
                  fy: rejectedInput.intrinsics[1],
                  cx: rejectedInput.intrinsics[2],
                  cy: rejectedInput.intrinsics[3],
                  imageWidth: rejectedInput.imageWidth,
                  imageHeight: rejectedInput.imageHeight,
                ),
              ),
      );
    }
    DeviceLog.log(
      'OfficialARCapturePage',
      'shutter ticket=${ticket.id} FAILED: $error\n$stackTrace',
    );
    TelemetryWriter.instance.event('shutter_error', {
      'ticket_id': ticket.id,
      'tap_timestamp_us': ticket.tapTimestampMicros,
      'error': '$error',
    });
    // A rejected private candidate is not a user-visible task failure. It
    // advances no photo/SfM/baseline ledger and the next eligible frame may
    // try again after the single-flight receipt releases.
  }

  Future<void> _deleteRejectedAutomaticCandidate(
    OfficialManualCaptureResult capture,
  ) async {
    final evidence = capture.evidenceJpegPath;
    final preview = capture.previewJpegPath;
    final dot = evidence.lastIndexOf('.');
    final stem = dot < 0 ? evidence : evidence.substring(0, dot);
    final paths = <String>{
      evidence,
      preview,
      '$stem.json',
      '${preview.substring(0, preview.lastIndexOf('.'))}.json',
      '${preview.substring(0, preview.lastIndexOf(Platform.pathSeparator) + 1)}'
          '${stem.split(Platform.pathSeparator).last}_highres_preview.jpg',
    };
    for (final path in paths) {
      try {
        final file = File(path);
        if (await file.exists()) await file.delete();
      } catch (error) {
        TelemetryWriter.instance.event('automatic_candidate_cleanup', {
          'file': path.split(Platform.pathSeparator).last,
          'outcome': 'delete_failed',
          'error': '$error',
        });
      }
    }
  }

  /// Open the full-screen, time-ordered photo album.
  void _openAlbum() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ARAlbumPage(
          projectPhotos: _projectPhotos,
          onDelete: _deleteProjectPhoto,
        ),
      ),
    );
  }

  /// 补强2:完成按钮的前置把关(真值口径,与横幅同一 starved 计数)。
  /// **占比口径**:starved_true / true_vox > [kParallaxStarvedFinishRatio]
  /// (40%)才弹(starvedFinishGateShouldPrompt;绝对数 >20 已废——大
  /// 场景体素基数大必超,每次完成必弹;true_vox==0 真值未到达不拦)。
  /// 文案定性 + 教动作,不报体素数(抄 RS:数字吓人且不可执行)。
  /// 非破坏性确认门:【继续拍摄】关弹窗回拍摄(什么都不发生),
  /// 【仍要完成】走原 [_finalizeRecording] 流程 —— 原逻辑一个字不改,
  /// 弹窗只是前置门。每次点完成都记一行 finish_gate 遥测
  /// (starved/true_vox + 用户选择;未触发门 = pass)。
  Future<void> _onFinishTap() async {
    if (!_finishAllowed || _confirmationDialogOpen) return;
    // Confirmation gates run before the commit boundary. Until they all pass,
    // no pending work is cancelled, no camera is stopped, and the user can
    // return to the exact same capture session.
    _confirmationDialogOpen = true;
    try {
      final acceptedFrameCount = _projectPhotos.count;
      if (!mounted || !_finishAllowed) return;
      if (!officialCaptureCanFinish(acceptedFrameCount: acceptedFrameCount)) {
        final remaining = kOfficialMinimumCaptureFrames - acceptedFrameCount;
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            key: const ValueKey<String>('official-minimum-photos-dialog'),
            title: const Text('至少拍摄20张照片'),
            content: Text(
              '要结束任务，必须至少拍摄20张照片。\n'
              '当前已完成 $acceptedFrameCount 张，还需要 $remaining 张。\n'
              '尽量从更多不同角度拍摄照片，'
              '完成20张并分析后，点云会覆盖显示在物体上。',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('继续拍摄'),
              ),
            ],
          ),
        );
        return;
      }
      final cov = _coverageCloud.coverageStats();
      if (starvedFinishGateShouldPrompt(
        starvedTrue: cov.starvedTrue,
        trueVoxels: cov.trueVoxels,
      )) {
        final finishAnyway = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            title: const Text('拍摄角度可能不足'),
            content: const Text(
              '仍有较多区域拍摄角度不足，可能出现分层。\n'
              '对黄色区域：横移一大步，或走近一半再拍。',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('继续拍摄'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('仍要完成'),
              ),
            ],
          ),
        );
        TelemetryWriter.instance.event('finish_gate', {
          'starved': cov.starvedTrue,
          'true_vox': cov.trueVoxels,
          'choice': finishAnyway == true ? 'finish_anyway' : 'continue_capture',
        });
        if (finishAnyway != true || !mounted) return;
      } else {
        TelemetryWriter.instance.event('finish_gate', {
          'starved': cov.starvedTrue,
          'true_vox': cov.trueVoxels,
          'choice': 'pass',
        });
      }
      await _finalizeRecording(navigateToDrafts: true, showSparseHint: true);
    } finally {
      _confirmationDialogOpen = false;
    }
  }

  /// Persist the just-recorded capture as a DRAFT scan.
  ///
  /// The Drafts card is the user-facing handle for the raw capture bundle:
  /// `scan_records.json` points back to `<captureDir>/photos_highres/`, and
  /// `<captureDir>/official_photo_bundle.json` is the source-of-truth manifest for
  /// local DA3 / preflight / texture derivation.
  Future<void> _finalizeRecording({
    required bool navigateToDrafts,
    required bool showSparseHint,
  }) async {
    await _commitCaptureExit(
      disposition: _CommittedCaptureExit.reconstruct,
      navigateToDrafts: navigateToDrafts,
      showSparseHint: showSparseHint,
    );
  }

  Future<void> _commitCaptureExit({
    required _CommittedCaptureExit disposition,
    required bool navigateToDrafts,
    required bool showSparseHint,
  }) async {
    final session = _session;
    if (session == null) return;
    final finishAttempt = _finishCoordinator.beginFinish(
      exitIntent: disposition == _CommittedCaptureExit.discard
          ? CaptureFinishExitIntent.discardCapture
          : navigateToDrafts
          ? CaptureFinishExitIntent.popToDrafts
          : CaptureFinishExitIntent.remainOnRoute,
    );
    if (finishAttempt == null) return;

    final recon = _sfmRecon;
    final captureDirAtCommit = session.captureDir;
    _finishDraftPersisted = false;
    _pendingFinishTerminal = null;
    if (mounted) {
      setState(() {
        _recording = false;
        _isAiming = false;
        _lockInProgress = false;
        _sfmSnapshot = null;
        _colorizeTarget = null;
        _sfmErrorText = null;
        _showDraftsWhileReconstructing = false;
      });
    }
    try {
      session.sealCaptureAdmission();
      _shutterQueue.cancelPending();
      _stopAutoCapture();
      _stopGuidanceTelemetry();
      _setMatcherCaptureActive(false);
      if (disposition == _CommittedCaptureExit.reconstruct) {
        recon?.notifyFinishCommitted();
      } else {
        _sfmRecon = null;
      }
    } catch (error, stackTrace) {
      _resolveFinishTerminal(
        attempt: finishAttempt,
        success: false,
        stage: 'synchronousCommit',
        error: error,
        stackTrace: stackTrace,
      );
      return;
    }

    try {
      final enteredProcessing = await _finishCoordinator
          .orchestrateToProcessing(
            attempt: finishAttempt,
            drainActiveTicket: () async {
              await _suppressActivePhotoPresentationForFinish();
              await _shutterQueue.freezeAndDrain();
              await session.waitForPendingPhotoSaves();
              for (final record in session.canonicalPhotoSnapshot) {
                await _projectCanonicalPhoto(session, record);
              }
            },
            stopCamera: () async {
              try {
                await _arKitChannel.invokeMethod<void>(
                  'setFeaturePointsVisible',
                  <String, dynamic>{'visible': false},
                );
              } catch (_) {}
              await session.stopCameraTransport();
            },
            beginProcessing: () async {
              _stopVioShadowInBackground();
              await session.stop();
              await _highResFailureSub?.cancel();
              _highResFailureSub = null;
            },
          );
      if (!enteredProcessing) {
        _showFinishCoordinatorFailure(finishAttempt);
        return;
      }

      if (disposition != _CommittedCaptureExit.reconstruct) {
        _releaseReconstructionAfterCommittedClose(recon);
        final processed = await _finishCoordinator.runProcessingStep(
          attempt: finishAttempt,
          stage: disposition == _CommittedCaptureExit.saveDraft
              ? 'persistCloseDraft'
              : 'discardCapture',
          operation: () async {
            if (disposition == _CommittedCaptureExit.saveDraft) {
              if (!await _persistDraft(showSnackBar: false)) {
                throw StateError('close-save draft was not persisted');
              }
              return;
            }
            await session.discardCurrentCapture();
            if (captureDirAtCommit != null &&
                await Directory(captureDirAtCommit).exists()) {
              throw StateError('discarded capture directory still exists');
            }
          },
        );
        if (!processed) {
          _showFinishCoordinatorFailure(finishAttempt);
          return;
        }
        _finishDraftPersisted = true;
        if (_resolveFinishTerminal(
          attempt: finishAttempt,
          success: true,
          stage: disposition == _CommittedCaptureExit.saveDraft
              ? 'persistCloseDraft'
              : 'discardCapture',
        )) {
          _exitCommittedCaptureRoute(
            finishAttempt,
            showDrafts: disposition == _CommittedCaptureExit.saveDraft,
          );
        }
        return;
      }

      await _continueCommittedReconstruction(
        session: session,
        recon: recon,
        finishAttempt: finishAttempt,
        navigateToDrafts: navigateToDrafts,
        showSparseHint: showSparseHint,
      );
    } catch (error, stackTrace) {
      if (_finishCoordinator.terminalOutcome == null) {
        _resolveFinishTerminal(
          attempt: finishAttempt,
          success: false,
          stage: 'finishPipeline',
          error: error,
          stackTrace: stackTrace,
        );
      } else {
        _showFinishCoordinatorFailure(finishAttempt);
      }
    }
  }

  Future<void> _continueCommittedReconstruction({
    required CaptureSession session,
    required SfmLiveRecon? recon,
    required CaptureFinishAttempt finishAttempt,
    required bool navigateToDrafts,
    required bool showSparseHint,
  }) async {
    if (_projectPhotos.count == 0) {
      _releaseReconstructionAfterCommittedClose(recon);
      _resolveFinishTerminal(
        attempt: finishAttempt,
        success: false,
        stage: 'verifiedPhotoLedger',
        error: StateError('no verified high-resolution photos to persist'),
      );
      return;
    }

    final sfmPreviewing = recon != null && recon.offeredCount >= 2;
    final captureDirForSfm = session.captureDir;
    // The canonical raw bundle is the recovery boundary. Settle it before
    // finalize can emit completion/events or colorization can time out, so a
    // reconstruction terminal can never prevent the draft from being saved.
    final persisted = await _finishCoordinator.runProcessingStep(
      attempt: finishAttempt,
      stage: 'persistDraft',
      operation: () async {
        if (!await _persistDraft(showSnackBar: mounted && showSparseHint)) {
          throw StateError('capture draft was not persisted');
        }
      },
    );
    if (!persisted) {
      _showFinishCoordinatorFailure(finishAttempt);
      return;
    }
    _flushDeferredFinishTerminal();
    if (_finishCoordinator.phase == CaptureFinishPhase.error) return;

    if (sfmPreviewing) {
      final prepared = await _finishCoordinator.runProcessingStep(
        attempt: finishAttempt,
        stage: 'startReconstruction',
        operation: () async {
          await _sfmFeedSub?.cancel();
          _sfmFeedSub = null;
          if (mounted) {
            setState(() {
              _sfmFed = recon.fedCount;
              _sfmQueued = recon.remainingCount;
              _sfmSnapshot = null;
              _colorizeTarget = null;
              _sfmErrorText = null;
              _sfmPhase = SfmPreviewPhase.generating;
              _showDraftsWhileReconstructing = false;
              _sfmFinalizeStage = recon.remainingCount == 0 ? 1 : 0;
              _sfmStageStartMs = DateTime.now().millisecondsSinceEpoch;
            });
            _startSfmStageTicker();
          }
          if (captureDirForSfm != null) {
            await _beginReconUmbrella(captureDirForSfm);
          }
          recon.finalize();
        },
      );
      if (!prepared) {
        _showFinishCoordinatorFailure(finishAttempt);
        return;
      }
    } else {
      _sfmRecon = null;
      _releaseReconstructionAfterCommittedClose(recon);
    }
    if (!sfmPreviewing) {
      final failure =
          _sfmProcessingTerminalGate.failure ??
          _sfmProcessingTerminalGate.fail(
            kind: SfmTerminalFailureKind.deliveryFailed,
            stage: 'preview_unavailable',
            message:
                'capture persisted but final reconstruction could not start',
          )!;
      _resolveFinishTerminal(
        attempt: finishAttempt,
        success: false,
        stage: 'sfm_${failure.stage}',
        error: failure,
      );
      return;
    }
    if (navigateToDrafts && mounted) _exitToDrafts();
  }

  void _releaseReconstructionAfterCommittedClose(SfmLiveRecon? recon) {
    final feedSub = _sfmFeedSub;
    final eventSub = _sfmEventSub;
    _sfmFeedSub = null;
    _sfmEventSub = null;
    _pendingSfmInputs.clear();
    unawaited(() async {
      await feedSub?.cancel();
      await eventSub?.cancel();
      if (recon != null) await recon.dispose();
    }());
  }

  void _exitCommittedCaptureRoute(
    CaptureFinishAttempt attempt, {
    required bool showDrafts,
  }) {
    if (!mounted || !_finishCoordinator.beginExit(attempt)) return;
    Navigator.of(context).pop(showDrafts);
    _finishCoordinator.markExited(attempt);
  }

  void _showFinishCoordinatorFailure(CaptureFinishAttempt attempt) {
    if (!mounted ||
        attempt.generation != _finishCoordinator.currentGeneration) {
      return;
    }
    final failure = _finishCoordinator.failure;
    DeviceLog.log(
      'OfficialARCapturePage',
      'finish terminal error stage=${failure?.stage ?? 'unknown'} '
          'timeout=${failure?.timedOut ?? false} error=${failure?.error}',
    );
    for (final cleanup in _finishCoordinator.cleanupFailures) {
      DeviceLog.log(
        'OfficialARCapturePage',
        'finish cleanup error stage=${cleanup.stage} '
            'timeout=${cleanup.timedOut} error=${cleanup.error}',
      );
    }
    setState(() {
      _colorizeTarget = null;
      _sfmPhase = SfmPreviewPhase.error;
      _sfmErrorText = '处理未完成，已保留全部照片。请稍后从草稿重试。';
      _showDraftsWhileReconstructing = false;
    });
  }

  /// Exit to Drafts — unless the live-reconstruction preview overlay is up,
  /// in which case the user leaves via its "完成" button and the pop is
  /// deferred to [_onSfmPreviewDone].
  void _exitToDrafts() {
    if (_sfmPhase != null) return;
    Navigator.of(context).pop(true);
  }

  Future<bool> _persistDraft({required bool showSnackBar}) async {
    final session = _session;
    if (session == null) return false;
    final dir = session.photosHighresDir ?? session.photosDir;
    final photoCount = _projectPhotos.count;
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
      return false;
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
        _projectPhotos.paths
            .where((p) => File(p).existsSync())
            .toList(growable: false)
          ..sort();
    if (firstPhoto.isNotEmpty) {
      final thumbnail = await store.thumbnailFileFor(
        captureId,
        pipelineKind: CapturePipelineKind.official,
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
        thumbnailPath = null;
      }
    }

    final manifestFile = await session.writeProjectPhotoBundleManifest(
      _projectPhotos.paths,
    );
    if (manifestFile == null || !manifestFile.existsSync()) return false;
    final record = ScanRecord(
      id: captureId,
      name: nextUntitledScanName(store.records.map((r) => r.name)),
      createdAt: createdAt,
      pipelineKind: CapturePipelineKind.official,
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
    unawaited(removeTransientCapturePreviews(captureDir));
    // Reconstruction happens two ways, both independent of any local mesh
    // pipeline: the streaming SfM preview (already running) and server-side
    // recon once the draft uploads. The draft stays at localPending for the
    // uploader to pick up.
    if (mounted && showSnackBar) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('已保存本地素材：$photoCount 张有效照片'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
    return true;
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

  Future<void> _deleteProjectPhoto(String path) async {
    // The canonical owner flushes the tombstone before removing the record,
    // files, or in-memory projections. No UI-local mutation may precede it.
    final session = _session;
    final deletedRecord = session == null
        ? null
        : await session.tombstoneCanonicalPhoto(path);
    if (deletedRecord == null) {
      if (mounted) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            const SnackBar(
              content: Text('照片暂时无法安全删除，请稍后重试'),
              behavior: SnackBarBehavior.floating,
            ),
          );
      }
      return;
    }
    final recon = _sfmRecon;
    int? removedFrameId;
    var reconRemovalFailed = false;
    if (recon != null) {
      for (final entry in recon.fedFrameMeta.entries) {
        if (entry.value.jpegPath == path) {
          removedFrameId = entry.key;
          break;
        }
      }
      final removed = await recon.removePhoto(path);
      reconRemovalFailed = !removed;
    }
    _photoCardStateSent.remove(path);
    _photoCaptureEpochMs.remove(path);
    _failedEvidenceJpegPaths.remove(path);
    if (removedFrameId != null) {
      _trueFrameParallaxDeg.remove(removedFrameId);
      _frameBelowEnterStreak.remove(removedFrameId);
    }
    final keep = _targetPoints.retainedJpegPaths.toSet()..remove(path);
    _targetPoints.retainOnlyJpegPaths(keep);
    final transactionId =
        _photoTransactionIdsByEvidencePath.remove(path) ??
        deletedRecord.transactionId;
    unawaited(
      _removePhotoCard(transactionId: transactionId, evidenceJpegPath: path),
    );
    final previewPath = path.replaceFirst('/photos_highres/', '/previews/');
    final sidecarPath = path.endsWith('.jpg')
        ? '${path.substring(0, path.length - 4)}.json'
        : '$path.json';
    // [E25 2026-07-20] 连带删掉 12MP 静照及其 sidecar。此前 `_hr` 反正会在
    // 点"完成"时被策展清理全删,漏删无所谓;现在 `_hr` 要长期留存(它是纹理
    // 素材源),不跟着删就会变成永久孤儿文件(每个约 4MB)。
    final hrPath = path.replaceFirst(RegExp(r'\.jpg$'), '_hr.jpg');
    final hrSidecarPath = path.replaceFirst(RegExp(r'\.jpg$'), '_hr.json');
    for (final candidate in <String>{
      path,
      previewPath,
      sidecarPath,
      hrPath,
      hrSidecarPath,
    }) {
      try {
        final file = File(candidate);
        if (await file.exists()) {
          await file.delete();
        }
      } on FileSystemException {
        // Best-effort UI deletion; the authoritative ledger has already been
        // updated so the count cannot resurrect on a widget rebuild.
      }
    }
    if (mounted) setState(() {});
    if (reconRemovalFailed && mounted) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(
            content: Text('照片已删除；重建工作器未确认撤回，完成时将以项目清单为准'),
            behavior: SnackBarBehavior.floating,
          ),
        );
    }
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

  Future<void> _disposeCaptureResourcesAfterQueueDrain(
    ManualCaptureQueue shutterQueue,
    CaptureSession? session,
  ) async {
    await shutterQueue.freezeAndDrain();
    await session?.stopCameraTransport();
    await session?.stop();
    shutterQueue.dispose();
    await session?.dispose();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_endReconUmbrella());
    _stopGuidanceTelemetry();
    // 遥测【resource】:拍摄页退出 → 停 Swift 侧 10s 资源采样。
    unawaited(
      _arKitChannel
          .invokeMethod<void>('telemetryCaptureEnd')
          .then<void>((_) {}, onError: (Object _) {}),
    );
    _warmupFallbackTimer?.cancel();
    _sfmStageTicker?.cancel();
    _coveragePushTimer?.cancel();
    _poseSub?.cancel();
    _vioConfidenceSub?.cancel();
    unawaited(_vioPoseProvider?.dispose() ?? Future<void>.value());
    // Streaming-SfM teardown: frees the native session (joins the background
    // BA thread, drops the sqlite db) off this isolate — page dispose never
    // blocks. Re-entering capture creates a fresh session + worker.
    _canonicalPhotoCommitSub?.cancel();
    _sfmFeedSub?.cancel();
    _sfmEventSub?.cancel();
    _highResFailureSub?.cancel();
    final shutterQueue = _shutterQueue;
    final session = _session;
    _session = null;
    // 自动拍与快门队列同生共死:队列一停收,它就只剩空转。
    // 关页面时把还开着的那一轮收口 —— 幂等,已经收过就什么都不写。
    _emitAutoTelemetry(_autoTelemetry.recordSessionEnd());
    _autoCapture.stop();
    shutterQueue.cancelPending();
    _setMatcherCaptureActive(false);
    VioDiagnosticsRecorder.instance.stopInBackground();
    unawaited(_disposeCaptureResourcesAfterQueueDrain(shutterQueue, session));
    final sfmRecon = _sfmRecon;
    _sfmRecon = null;
    _pendingSfmInputs.clear();
    if (sfmRecon != null) unawaited(sfmRecon.dispose());
    _adaptiveFpsTimer?.cancel(); // [ADAPTIVE-FPS]
    _previewModel.dispose();
    _projectPhotos.dispose();
    _targetPoints.dispose();
    // Evict the full-res capture bitmaps decoded for the album/thumbnails so
    // they don't linger in the global imageCache into the community/me tabs.
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    super.dispose();
  }

  // ─── Layout ─────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // 修2【任务卡重入回归根因】:本 route 是普通 MaterialPageRoute,iOS
    // 边缘右滑(或任何 maybePop)可以在重建等待期把整个 capture route
    // pop 掉 → State.dispose() → recon.dispose() 排队 → phase-1 一结束
    // worker 就被销毁(真机日志 21:00:02 "local_ready withheld" 下一行
    // 即 "dispose: freeing session")。这违反契约:返回草稿不得销毁
    // capture route / SfM worker;同任务卡必须能回原等待页。
    // 修法:重建进行中(_sfmPhase != null)禁止隐式 pop;把返回手势
    // 折叠成"显示草稿"(与等待页左上角返回按钮同一语义)。显式的
    // Navigator.pop(_exitToDrafts/_onSfmPreviewDone)不受 canPop 影响。
    return PopScope(
      canPop: !_recording && _finishCoordinator.canPop && _sfmPhase == null,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        if (_recording) {
          unawaited(_onCloseTap());
          return;
        }
        final terminal =
            _sfmPhase == SfmPreviewPhase.refined ||
            _sfmPhase == SfmPreviewPhase.error;
        if (terminal) unawaited(_onSfmPreviewBack());
      },
      child: _buildRouteBody(context),
    );
  }

  Widget _buildRouteBody(BuildContext context) {
    _scheduleDraftTerminalExitIfNeeded();
    if (_showDraftsWhileReconstructing && _sfmPhase != null) {
      return DraftCaptureShell(
        blockedMessage: '当前任务正在重建',
        onCaptureTap: _showReconstructionProgress,
        child: MePage(
          activeReconstructionCaptureDir: _session?.captureDir,
          activeReconstructionPipelineKind: CapturePipelineKind.official,
          onActiveReconstructionTap: _showReconstructionProgress,
          onActiveReconstructionDelete: _permanentlyDeleteActiveReconstruction,
          onRecordActionActivityChanged: _setDraftRecordActionInProgress,
          officialResumeRoute: pushOfficialResumeRoute,
          officialViewerRoute: pushOfficialViewerRoute,
        ),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Camera preview / init / error placeholder.
          Positioned.fill(
            child: _finishCoordinator.captureRootTombstoned
                ? const ColoredBox(color: Colors.black)
                : _buildPreviewLayer(),
          ),

          // ─── Top bar: subtle route marker + X close button (right).
          // Tracking dot was previously rendered dead-center here, but
          // it sat right under iOS's Dynamic Island (visually colliding
          // with the system camera-in-use indicator) and the abstract
          // green/red/white color carried no clear meaning to the user.
          // The IdleHintPill + preview minimap + bottom button cover the same
          // information already, so this dot was pure noise. Removed.
          if (!_finishCoordinator.captureRootTombstoned)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                  child: SizedBox(
                    height: 38,
                    // [2026-07-27 UI 签决]"官方"路由徽章已删除:线上只剩这一条
                    // 采集路由(另一条 lib/ui/capture/ar_capture_page.dart 早已
                    // 不存在),标签对用户零信息量,只是占着取景框右上角。
                    // [2026-08-10 用户签决,附截图] 右上角"×"改为左上角"<",
                    // 功能保持不变(仍走 _onCloseTap 的退出弹窗)。
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: [_CloseButton(onTap: _onCloseTap)],
                    ),
                  ),
                ),
              ),
            ),

          // ─── [spec §8.1] 顶部说明条(按 RealityScan 实机截图复刻)。
          //
          // **瞬态**,不是常驻:只在进采集页与切换模式时露一次,3 秒后自动
          // 淡出。[2026-07-27 UI 签决] 删掉入场提示的理由正是"每次进拍摄都
          // 挡一次取景框",并要求下面四档横幅**回到各自的固定档位**;一条
          // 常驻文案会把这两条一起推翻。所以四档一格没动(66/60/104/148/192),
          // 本条与硬拒 toast 共用第 60 档 —— 它排在 Stack 里更靠前,真撞上时
          // 警告盖在它上面,由警告赢。
          if (!_finishCoordinator.captureRootTombstoned &&
              _session != null &&
              _sfmPhase == null)
            Positioned(
              top: 0,
              left: 16,
              right: 16,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(top: 60),
                  child: Center(child: _CaptureModeTopHint(mode: _captureMode)),
                ),
              ),
            ),

          // Only a camera-transport failure may cover the capture UI. Live
          // reconstruction degradation is recorded for the processing state
          // and never blocks a valid high-resolution capture.
          if (_captureQueueFailureText != null)
            Positioned(
              top: 0,
              left: 16,
              right: 16,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(top: 66),
                  child: Container(
                    key: const ValueKey<String>(
                      'capture-transport-failure-banner-official',
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xE6A52828),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.white24),
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.error_outline_rounded,
                          color: Colors.white,
                          size: 22,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _captureQueueFailureText!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

          // ─── [2026-07-27 UI 签决] 开拍即弹的"20 张"入场提示已删除。
          // 它每次进拍摄都占掉取景框顶部一大条,内容又是用户此刻做不了的事。
          // 同一句话搬到 _onFinishTap 的"至少拍摄20张照片"对话框——只在真
          // 需要时出现。下面几档顶部横幅(硬拒/移速/starved/未连接)因此回到
          // 各自的固定档位,不再有让位入场提示的偏移。

          // ─── Aim mode overlay: center crosshair + hint text.
          // Only rendered while `_isAiming` is true (between idle and
          // recording). User actively aligns the crosshair on the
          // subject and taps the bottom button to lock origin.
          // 准星盒改用取景矩形(CapturePreviewRect)而不是整屏:画面挪位置
          // 之后,按整屏定位的准星会离画面中心更远。注意准星图形本身刻意带
          // Alignment(0, -0.10) 的上偏(下方要留出提示条),所以这里只是把
          // 偏移的基准换成画面本身,并非"与画面同心"——真正的锁定射线走的是
          // 相机光轴(native lockOrigin),落在画面正中心,准星仍偏上约 4%。
          // ⚠️ 这个分支目前是死代码:_isAiming 唯一的赋值点 _onCenterTap 全仓
          // 无人调用(analyzer 的 unused_element 警告即是),HEAD 亦然。
          if (_isAiming)
            const Positioned.fill(
              child: IgnorePointer(
                child: CapturePreviewRect(child: _AimOverlay()),
              ),
            ),

          // Photo cards are now rendered NATIVELY as world-anchored SceneKit
          // quads (see AetherARKitPlugin addPhotoCard) — stable, no drift. The
          // old Flutter 2D-projected `_PhotoPositionOverlay` is removed.
          // Quality, motion, parallax and connectivity remain algorithm and
          // telemetry evidence. They intentionally render no capture-time
          // warning: private candidate rejection and background SfM health
          // must not ask the user to compensate for pipeline latency.

          // ─── 07-12 签决(彻底不限流):快门配速横幅已撤除。曾经在拥塞时
          // 弹「照片处理中,请稍候再拍」——那与「快门永不阻挡」矛盾(等于劝
          // 用户别拍)。热保护改由 native 热调速器透明承担;拥塞只记遥测。

          // RealityScan-style: the manual capture bar is shown as soon as the
          // AR session exists — no "initializing AR" stage and no big dome
          // button. The shutter is simply disabled (dimmed) until the silent
          // auto-lock has the session recording.
          // Hidden once the preview overlay is up: it replaces the whole
          // capture UI (a clean switch, not a translucent cover) so nothing
          // leaks through the bottom and there's no illusion of still capturing.
          if (!_finishCoordinator.captureRootTombstoned &&
              _session != null &&
              _sfmPhase == null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // [spec §8.1] 快门上方的提示行(RS 同款)。自动模式**开拍
                    // 之后换成停止语义** —— 否则那颗红键跑起来以后,没有任何
                    // 地方告诉用户它现在是"停"。它浮在取景画面底部之上,不进
                    // 常驻控件条的高度账(capture_preview_rect 的三个常量一个
                    // 没动),所以取景矩形的几何守门测试不受影响。
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Center(
                        child: IgnorePointer(
                          child: _IdleHintPill(
                            text: autoCaptureShutterHintText(
                              mode: _captureMode,
                              running: _autoCapture.isRunning,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 快门上方的两个显示开关(左:AR 照片卡片;右:覆盖点)。
                    // [2026-07-27 UI 签决] 收起功能(chevron)已删除:预览改为
                    // 在这条控件条上方(见 CapturePreviewRect),完整 4:3 画面
                    // 不再被面板压住,所以没有任何需要临时收起的理由 —— 面板与
                    // 快门条从此常驻同屏。这里的尺寸一律取自 capture_preview_rect
                    // 的常量,不写字面量(常量与真实高度脱钩过一次,见该文件)。
                    // [UI-3] 底色从 0xE6(90% 半透明)改成全不透明:半透明会
                    // 让画面从面板顶部透出来,用户看到的就是"画面和灰底重叠"。
                    // 画面底边现在也不再贴着这个灰底,而是隔着一个
                    // captureSeparatorGap。
                    Container(
                      width: double.infinity,
                      color: const Color(0xFF1C1C20),
                      padding: const EdgeInsets.symmetric(
                        vertical: kCaptureIconPanelPadV,
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _DisplayToggleButton(
                            onTap: _togglePhotoCards,
                            child: Icon(
                              Icons.photo_outlined,
                              size: 26,
                              color: _photoCardsVisible
                                  ? const Color(0xFFF5B821)
                                  : Colors.white54,
                            ),
                          ),
                          const SizedBox(width: 96),
                          _DisplayToggleButton(
                            onTap: _toggleCoverageDots,
                            child: _NineDotIcon(
                              color: _coverageDotsVisible
                                  ? const Color(0xFFF5B821)
                                  : Colors.white54,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // [UI-3] 灰底面板与快门圆之间的确定间隔 —— 之前快门圆
                    // 顶边正好抵在面板下边缘,看着像"灰底压住快门"。
                    // 与画面↔面板用的是同一个间距,空间不够时一起让掉。
                    SizedBox(
                      height: captureSeparatorGap(
                        screen: MediaQuery.sizeOf(context),
                        safeTop: MediaQuery.paddingOf(context).top,
                        safeBottom: MediaQuery.paddingOf(context).bottom,
                      ),
                    ),
                    _ManualCaptureBar(
                      projectPhotos: _projectPhotos,
                      shutterQueue: _shutterQueue,
                      processedCount: _sfmFed,
                      // 07-12 签决:快门彻底不限流 —— 只要在录制就永远可拍,
                      // 绝不因队列深度/热态置灰(积压走磁盘 spool 队列,不回压快门)。
                      ready: _captureAdmissionOpen,
                      finishing: !_finishCoordinator.captureAdmissionOpen,
                      mode: _captureMode,
                      // ⚠️ 运行态取自 controller 本身,**不从最近一帧的判定
                      // 反推** —— 停机时 onPose 返回的就是 skipNotMoved,与
                      // "你还没动够"逐字相同,照返回值画会永远显示"在等你动"。
                      autoRunning: _autoCapture.isRunning,
                      autoIndicator: autoCaptureIndicatorFor(
                        running: _autoCapture.isRunning,
                        decision: _lastAutoDecision,
                      ),
                      autoPulseToken: _autoFirePulseToken,
                      onShutter: _onShutterTap,
                      onToggleMode: () => _setCaptureMode(
                        _captureMode == OfficialCaptureMode.auto
                            ? OfficialCaptureMode.manual
                            : OfficialCaptureMode.auto,
                      ),
                      onToggleAutoRun: _toggleAutoRun,
                      onOpenAlbum: _openAlbum,
                      // 补强2:完成前先过 starved 把关门(_onFinishTap),
                      // 通过后才走原 _finalizeRecording,原流程一个字不改。
                      onFinish: _finishAllowed ? _onFinishTap : null,
                    ),
                  ],
                ),
              ),
            ),

          // [spec §8.1] 切到自动模式时居中浮出的短提示(RS 的 "Auto Capture
          // On")。只在**用户主动切换**时出现 —— 进页面时的默认自动不算一次
          // 切换,那会变成每次进采集页都弹一下的噪音。
          if (!_finishCoordinator.captureRootTombstoned &&
              _session != null &&
              _sfmPhase == null)
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: _AutoCaptureOnToast(token: _autoModeToastToken),
                ),
              ),
            ),

          // Capture exit and reconstruction readiness are separate states.
          // The opaque post-capture page takes ownership synchronously when
          // Finish commits; `_sfmPhase` may arrive later without exposing AR.
          if (_finishCoordinator.shouldShowOpaqueOverlay || _sfmPhase != null)
            SfmPreviewOverlay(
              phase: _sfmPhase ?? SfmPreviewPhase.generating,
              snapshot: _sfmSnapshot,
              errorText: _sfmErrorText,
              // [2026-08-09 用户签决] 进度口径=用户视角:"已完成 x/N 帧",
              // N=本场实拍照片数。补算/重喂是内部机制,不暴露 —— 欠账帧
              // 补算完成时 fed 自然爬到 N,用户只看到计数在涨。
              progressText: _sfmQueued > 0
                  ? AppL10n.of(context).sfmProgressFedQueued(
                      math.min(_sfmFed, _projectPhotos.count),
                      _projectPhotos.count,
                    )
                  : _sfmStageProgressText(context),
              onCameraChanged: (c) => _sfmPreviewCamera.value = c,
              editing: _sfmEditing,
              // 编辑态要框(画手柄);浏览态只在用户真选过区时才裁剪,否则
              // 呈现原始点云。
              selectionBox: (_sfmEditing || _sfmSelectionApplied)
                  ? _sfmBox
                  : null,
              onBoxChanged: _onSfmBoxChanged,
              cloudController: _sfmCloudController,
              toolsOverlay: _sfmEditing && _sfmBox != null
                  ? SelectionToolsLayer(
                      box: _sfmBox!,
                      onBoxChanged: _onSfmBoxChanged,
                      camera: _sfmPreviewCamera,
                      controller: _sfmCloudController,
                      onExit: () => unawaited(_exitSfmEditing()),
                      onCancel: () => unawaited(_cancelSfmEditing()),
                      onResetBoxSize: _resetSfmBoxSize,
                    )
                  : null,
              // [SEL-DISCARD 2026-07-30] 退到草稿前先裁决未保存的选区编辑。
              onBack:
                  _sfmPhase == SfmPreviewPhase.refined ||
                      _sfmPhase == SfmPreviewPhase.error
                  ? () => unawaited(_onSfmPreviewBack())
                  : null,
              onDone: () => unawaited(_onSfmPreviewDone()),
              // [2026-07-31 用户签决] 底部"下一步" = 启动后续处理;进选区
              // 编辑归右上角那个可选入口。
              onNext:
                  _sfmSnapshot != null &&
                      _sfmSnapshot!.pointCount > 0 &&
                      denseStageLauncher.isAvailable
                  ? () => unawaited(_startDenseStage())
                  : null,
              // [SEL-ENTRY 2026-07-30] 右上角"选区编辑":选区是可选动作,不点
              // 就直接保存草稿。与底部"下一步"共用同一个进入函数,所以两个
              // 入口不会产生两种状态。编辑态的出口("保存"/"返回")归
              // SelectionToolsLayer,这里不再出按钮。
              onEnterEditing:
                  _sfmSnapshot != null && _sfmSnapshot!.pointCount > 0
                  ? _enterSfmEditing
                  : null,
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
      // [WYSIWYG 2026-07-19] 预览 letterbox 成照片画幅(photo43=3:4),黑边
      // 顶底,显示完整 4:3 画面 —— 所见即所得。native 卡片几何按同一 3:4
      // 视口算(AetherARKitPlugin videoFormatMode==hires43 分支),两者对齐。
      return const ColoredBox(
        color: Color(0xFF000000),
        child: CapturePreviewRect(
          child: UiKitView(
            viewType: 'pocketworld_official_arkit_preview',
            creationParams: <String, dynamic>{},
            creationParamsCodec: StandardMessageCodec(),
          ),
        ),
      );
    }
    return const ColoredBox(color: Color(0xFF111113));
  }
}

// ─── Top bar widgets ───────────────────────────────────────────────────

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
  final rel = worldPosition - pose.position;
  final cam = worldVectorToCamera(pose.orientation, rel);
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
  final forward = cameraForwardInWorld(orientation);
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
              : Image.file(File(imagePath), fit: BoxFit.cover, cacheWidth: 120),
        ),
      ),
    );
  }
}

/// RS 复刻显示开关的按钮壳:44×44 点击区,纯显示层,无任何业务副作用。
class _DisplayToggleButton extends StatelessWidget {
  const _DisplayToggleButton({required this.onTap, required this.child});

  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: kCaptureToggleButtonSize,
        height: kCaptureToggleButtonSize,
        child: Center(child: child),
      ),
    );
  }
}

/// 3×3 九点图标(覆盖点显示开关)。规格(2026-07-19):图标恒定单色——
/// 开=全黄、关=灰;绝不出现绿色圆点(不映射实时覆盖色)。
class _NineDotIcon extends StatelessWidget {
  const _NineDotIcon({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(24, 24),
      painter: _NineDotPainter(color),
    );
  }
}

class _NineDotPainter extends CustomPainter {
  const _NineDotPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final step = size.width / 3;
    final r = step * 0.30;
    for (var row = 0; row < 3; row++) {
      for (var col = 0; col < 3; col++) {
        canvas.drawCircle(
          Offset(step * (col + 0.5), step * (row + 0.5)),
          r,
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_NineDotPainter oldDelegate) => oldDelegate.color != color;
}

/// RealityScan-style bottom capture bar: latest-photo album thumbnail (left),
/// center shutter (one tap = one photo), and a blue finish arrow (right).
/// Rebuilds on every [targetPoints] change so the count + thumbnail stay live.
class _ManualCaptureBar extends StatelessWidget {
  const _ManualCaptureBar({
    required this.projectPhotos,
    required this.shutterQueue,
    required this.processedCount,
    required this.ready,
    required this.finishing,
    required this.mode,
    required this.autoRunning,
    required this.autoIndicator,
    required this.autoPulseToken,
    required this.onShutter,
    required this.onToggleMode,
    required this.onToggleAutoRun,
    required this.onOpenAlbum,
    required this.onFinish,
  });

  final OfficialProjectPhotoAlbum projectPhotos;
  final ManualCaptureQueue shutterQueue;

  /// [RS-RING 2026-08-06 用户签决] SfM 已处理完的帧数(页面 `_sfmFed`,每个
  /// SfmLiveFrameFed 事件 setState 实时刷新)。相册缩略图外圈的白色进度环
  /// = processedCount / count:拍新照分母涨环回退,处理跟上环前进,转满一圈
  /// = 全部处理完成。复刻 RS 的相册进度环(RS 蓝,我们白)。
  final int processedCount;
  final bool ready;
  final bool finishing;

  /// [spec §8.1] 手动 = 白快门;自动 = 红录制键。两态共用同一排,只换中间
  /// 那一颗 —— **自动模式下没有第二颗手动快门**(RS 同款):要手动补拍就
  /// 切回手动模式。
  final OfficialCaptureMode mode;
  final bool autoRunning;
  final AutoCaptureIndicator autoIndicator;

  /// 每落一帧 +1,驱动录制键脉冲一次。
  final int autoPulseToken;
  final VoidCallback onShutter;
  final VoidCallback onToggleMode;
  final VoidCallback onToggleAutoRun;
  final VoidCallback onOpenAlbum;
  final VoidCallback? onFinish;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[projectPhotos, shutterQueue]),
      builder: (context, _) {
        // [SIGNED 2026-07-27] 300 张预算用尽 → 快门置灰(与相册徽章的
        // 琥珀态、_onShutterTap 的兜底同源)。
        final canShoot = officialCaptureCanShoot(
          acceptedFrameCount:
              projectPhotos.count + shutterQueue.outstandingCount,
        );
        final latest = projectPhotos.latestPath;
        return Padding(
          // [2026-07-27 UI-2 签决] 底部内边距 24→0:相册/快门/完成整排向下
          // 平移 24pt,贴到 SafeArea 上沿 —— 刘海机由 SafeArea 让开的 34pt
          // 兜着,按钮不进 Home 手势区。⚠️ Home 键机型(SE 2/3)的
          // padding.bottom 是 0,SafeArea 让开的也是 0,所以那类机型要靠
          // captureShutterRowBottomPadding 补一个最小外边距,否则快门圆会贴
          // 死屏幕物理底边。
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            captureShutterRowBottomPadding(
              MediaQuery.paddingOf(context).bottom,
            ),
          ),
          child: Row(
            children: [
              // ⚠️ 槽是 SizedBox 给的**紧**宽度约束,徽章自己的 Container
              // 逃不掉(BoxConstraints.enforce 会把 48 顶回槽宽)—— 少这层
              // Align,徽章就会被拉成槽宽 × kCaptureAlbumThumbSize 的扁矩形。
              // 右端的完成键一直有这层 Align,相册这边是漏的。
              SizedBox(
                width: kCaptureShutterRowSideSlot,
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: _AlbumThumbButton(
                    latestPath: latest,
                    count: projectPhotos.count,
                    processed: processedCount,
                    onTap: onOpenAlbum,
                  ),
                ),
              ),
              // [spec §8.1] 模式 toggle 坐在相册与快门**之间**(RS 同款)。
              // FittedBox 兜底:iPhone SE Display Zoom(320pt)这类声明支持
              // 的窄机型上宁可整体缩一点,也不许 RenderFlex 溢出。
              // ⚠️ 兜底只该在 320pt 那一档生效:胶囊加宽到
              // kCaptureModeToggleWidth 后,14 Pro(393)剩 78.5、
              // SE 2/3(375)剩 69.5,两台都装得下 68 —— 高度因此仍是实打实
              // 的 44,没被 scaleDown 顺手压矮。这条余量是靠把两端槽位从写死
              // 的 72 收到 kCaptureShutterRowSideSlot 让出来的。
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: _CaptureModeToggle(
                        mode: mode,
                        // 采集中也允许切走(spec §7 第一条):切模式是 UI
                        // 行为,已拍帧全保留、队列继续消化。只有收尾流程里
                        // 才锁住 —— 那时整条采集已经在关门了。
                        onTap: finishing ? null : onToggleMode,
                      ),
                    ),
                  ),
                ),
              ),
              if (mode == OfficialCaptureMode.auto)
                _AutoRecordButton(
                  // 在跑时**恒可点**:哪怕预算刚好用尽、队列刚好停收,
                  // 用户也必须能按停(autoCaptureRecordButtonEnabled)。
                  enabled: autoCaptureRecordButtonEnabled(
                    running: autoRunning,
                    canStart: ready && shutterQueue.accepting && canShoot,
                  ),
                  running: autoRunning,
                  indicator: autoIndicator,
                  pulseToken: autoPulseToken,
                  onTap: onToggleAutoRun,
                )
              else
                _ShutterButton(
                  // [SIGNED 2026-07-27] 300 张上限:唯一置灰理由(与
                  // _onShutterTap 的兜底同源 officialCaptureCanShoot)。
                  // 07-12 的"快门永不因队列/热态置灰"铁律不受影响 ——
                  // 这不是限流,是任务预算用尽。
                  enabled: ready && shutterQueue.accepting && canShoot,
                  // 在途/排队期间继续接收点击；只有 admission 已冻结、会话
                  // 未就绪或预算用尽才禁用。
                  onTap: ready && shutterQueue.accepting && canShoot
                      ? onShutter
                      : null,
                ),
              // 与左侧 toggle 槽对称的留白 —— 两个等权 Expanded 才能让快门
              // 停在整排的正中,而不是被 toggle 顶偏。
              const Expanded(child: SizedBox.shrink()),
              SizedBox(
                width: kCaptureShutterRowSideSlot,
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _FinishArrowButton(
                    // 2026-07-25 回退 eaf8706 的 capturing 门:「完成」必须随时
                    // 可点。快门期间置灰+转圈是多余的 —— _finalizeRecording 本来
                    // 就会等齐所有已点击快门、仍在队列/处理中的照片再收尾,
                    // 按钮层再拦一道只会让 UX 出现本不该有的加载态。
                    busy: finishing,
                    onTap:
                        projectPhotos.count + shutterQueue.outstandingCount == 0
                        ? null
                        : onFinish,
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
    required this.processed,
    required this.onTap,
  });

  final String? latestPath;
  final int count;

  /// SfM 已处理帧数;`processed/count` 驱动外圈白色进度环([RS-RING])。
  final int processed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // [RS-RING 2026-08-06] 分母是"当前已拍",不是 300 上限 —— 拍新照环回退、
    // 处理追上环闭合,与 RS 的语义一致(转满一圈 = 目前拍的全处理完)。
    final double progress = count <= 0
        ? 0.0
        : (processed / count).clamp(0.0, 1.0);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: CustomPaint(
        foregroundPainter: _AlbumRingPainter(progress: progress),
        child: Container(
          width: kCaptureAlbumThumbSize,
          height: kCaptureAlbumThumbSize,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.44),
            // [2026-08-21 等比缩小] 圆角/描边都乘 kCaptureAlbumThumbScale,
            // 不是照抄原来的 14 / 1.5 —— 缩了外框不缩圆角,方框会变成药丸。
            borderRadius: BorderRadius.circular(kCaptureAlbumThumbRadius),
            // [RS-RING] 原 0.5α 静态白边即进度环的"轨道";实心白弧压其上。
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.5),
              width: 1.5 * kCaptureAlbumThumbScale,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          // [2026-08-10 用户签决,附手绘] 相册缩略图照片撤下,徽章只显示计数:
          // 左上**大**分子(已拍帧数)+ 斜杠 + 右下**小** 300。取代 07-27 的
          // "照片上压竖排分数"。点击仍开相册,进度环照旧。
          child: _AlbumCountFraction(count: count),
        ),
      ),
    );
  }
}

/// [RS-RING 2026-08-06] 相册缩略图外圈进度环:沿圆角矩形边框路径顺时针扫过
/// 的实心白弧,从顶边正中起笔。复刻 RS 的处理进度环呈现(RS 蓝我们白),
/// 用 PathMetric 沿现有 14 圆角边框走线,不另起圆形以免与方形缩略图打架。
class _AlbumRingPainter extends CustomPainter {
  const _AlbumRingPainter({required this.progress});

  /// 0..1;1 = 当前已拍全部处理完成(环闭合)。
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(kCaptureAlbumThumbRadius),
    );
    final path = Path()..addRRect(rrect);
    final metric = path.computeMetrics().first;
    final total = metric.length;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3 * kCaptureAlbumThumbScale
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;
    if (progress >= 1) {
      canvas.drawPath(path, paint);
      return;
    }
    // addRRect 的路径起点在左上圆角后的顶边起点;把起笔挪到顶边正中,
    // 环从 12 点方向顺时针生长(与 RS 一致)。
    final start = (size.width / 2 - kCaptureAlbumThumbRadius).clamp(0.0, total);
    final sweep = total * progress;
    final end = start + sweep;
    if (end <= total) {
      canvas.drawPath(metric.extractPath(start, end), paint);
    } else {
      canvas.drawPath(metric.extractPath(start, total), paint);
      canvas.drawPath(metric.extractPath(0, end - total), paint);
    }
  }

  @override
  bool shouldRepaint(_AlbumRingPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

/// RS 同款的堆叠分数:已拍张数 / 上限,压在缩略图正中,无底色。
class _AlbumCountFraction extends StatelessWidget {
  const _AlbumCountFraction({required this.count});

  final int count;

  static const List<Shadow> _shadows = <Shadow>[
    Shadow(color: Color(0xCC000000), blurRadius: 4, offset: Offset(0, 1)),
  ];

  @override
  Widget build(BuildContext context) {
    // 与快门置灰同源:拍满即转琥珀,不额外判断数字。
    final tint = officialCaptureCanShoot(acceptedFrameCount: count)
        ? Colors.white
        : const Color(0xFFFFC24D);
    final style = TextStyle(
      color: tint,
      fontSize: 15 * kCaptureAlbumThumbScale,
      height: 1.05,
      fontWeight: FontWeight.w700,
      shadows: _shadows,
    );
    // [2026-08-10 用户签决,附手绘] 斜杠分数版式:左上大分子 + 45° 斜杠 +
    // 右下小分母。分子随位数自适应字号(3 位数不撑破 60pt 徽章)。
    //
    // [2026-08-10 二稿] 斜杠恒 45°,且到两个数字的距离相等 —— 用 TextPainter
    // 实测两段文字的包围盒,把斜杠中心放在"分子右下角 ↔ 分母左上角"连线的
    // 中点上;位数变化(字宽变化)时自动保持等距,不靠写死坐标。
    //
    // [2026-08-21 等比缩小] 两级字号、斜杠、锚点内边距全部乘同一个
    // kCaptureAlbumThumbScale。分子 22→17.6(三位数 19→15.2)、分母 10→8:
    // 分子仍是徽章里最抢眼的那一段,分母作为次要信息在 Retina 上仍可读 ——
    // 这是"缩到还看得清"的下限,再往下(0.7 ⇒ 分母 7)就糊了。
    final bigSize = (count >= 100 ? 19.0 : 22.0) * kCaptureAlbumThumbScale;
    final bigStyle = style.copyWith(fontSize: bigSize, height: 1.0);
    final smallStyle = style.copyWith(
      fontSize: 10 * kCaptureAlbumThumbScale,
      height: 1.0,
    );
    final bigTp = TextPainter(
      text: TextSpan(text: '$count', style: bigStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    final smallTp = TextPainter(
      text: TextSpan(text: '$kOfficialMaximumCaptureFrames', style: smallStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    const slashLen = 24.0 * kCaptureAlbumThumbScale;
    // 分子/分母的锚点内边距也随比例走,否则小徽章里两个数字会往中间挤。
    const anchorBigL = 7.0 * kCaptureAlbumThumbScale;
    const anchorBigT = 5.0 * kCaptureAlbumThumbScale;
    const anchorSmallR = 6.0 * kCaptureAlbumThumbScale;
    const anchorSmallB = 4.0 * kCaptureAlbumThumbScale;
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth, h = c.maxHeight;
        // 分子锚在 (anchorBigL, anchorBigT),分母锚在
        // right:anchorSmallR / bottom:anchorSmallB(与 Positioned 一致)。
        final bigBR = Offset(
          anchorBigL + bigTp.width,
          anchorBigT + bigTp.height,
        );
        final smallTL = Offset(
          w - anchorSmallR - smallTp.width,
          h - anchorSmallB - smallTp.height,
        );
        final mid = Offset(
          (bigBR.dx + smallTL.dx) / 2,
          (bigBR.dy + smallTL.dy) / 2,
        );
        return Stack(
          children: [
            Positioned(
              left: anchorBigL,
              top: anchorBigT,
              child: Text('$count', style: bigStyle),
            ),
            // 斜杠:竖线顺时针转 45° = "/",中心 = 两数字近角连线中点。
            Positioned(
              left: mid.dx - 0.75 * kCaptureAlbumThumbScale,
              top: mid.dy - slashLen / 2,
              child: Transform.rotate(
                angle: math.pi / 4,
                child: Container(
                  width: 1.5 * kCaptureAlbumThumbScale,
                  height: slashLen,
                  decoration: BoxDecoration(
                    color: tint,
                    boxShadow: const [
                      BoxShadow(color: Color(0xCC000000), blurRadius: 4),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              right: anchorSmallR,
              bottom: anchorSmallB,
              child: Text('$kOfficialMaximumCaptureFrames', style: smallStyle),
            ),
          ],
        );
      },
    );
  }
}

class _ShutterButton extends StatelessWidget {
  const _ShutterButton({required this.onTap, this.enabled = true});

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
          // 快门是快门行里最高的子项 —— 行高即由它决定,见
          // kCaptureShutterRowHeight。
          width: kCaptureShutterDiameter,
          height: kCaptureShutterDiameter,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 4),
          ),
          child: Padding(
            padding: const EdgeInsets.all(5),
            // 队列忙碌不进入视觉状态：按钮只在会话未就绪、完成流程冻结
            // admission 或 300 张预算用尽时变灰；在途/排队期间恒为纯白。
            child: Container(
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
              ),
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
        width: kCaptureFinishButtonSize,
        height: kCaptureFinishButtonSize,
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
          // [2026-08-10 用户签决] "×"→"<"(与草稿等待页的返回箭头同款)。
          Icons.arrow_back_ios_new_rounded,
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

// ─── [spec §8.1] 自动采集的三件 UI:模式 toggle / 红录制键 / 开启提示 ──
//
// 三个类都放在文件**最末尾**,刻意避开 _ManualCaptureBar→_AlbumThumbButton
// 与 _ShutterButton→_FinishArrowButton 这两段被既有契约测试逐字盯着的区间
// (official_capture_frame_budget / manual_capture_bar_io /
// official_highres_reconstruction),免得新代码误闯进别人的守门里。

/// 手动 / 自动 模式切换键。RS 同款:快门**左侧**的一颗胶囊。
///
/// [2026-08-21 用户签决] 旧版是一颗 50×44 的单图标胶囊,点一下只换底色
/// (手动灰 / 自动蓝)—— 用户原话「现在只是单纯的点击后变色」:静止时它
/// 根本不说明"有两个模式",更不说明"另一个是什么"。现在是真正的分段开关:
/// 相机 / 摄像机两个图标并排常驻,一颗高亮滑块**滑**到当前那一侧。
///
/// 颜色语义没动:滑块在自动侧时是 RS 的蓝(0xFF0A84FF),手动侧是浅灰。
///
/// ⚠️ 图标是摄像机,但模式名刻意避开"录像" —— 见 [OfficialCaptureMode]。
class _CaptureModeToggle extends StatelessWidget {
  const _CaptureModeToggle({required this.mode, required this.onTap});

  final OfficialCaptureMode mode;

  /// null = 置灰不可点(只在收尾流程里)。
  final VoidCallback? onTap;

  /// 滑块的滑行动画。**沿用本页既有的那一档**(180ms / easeOut,红录制键
  /// 「圆 ↔ 圆角方」的形变用的就是它)—— 同一排控件的直接操作反馈是同一种
  /// 手感,不为这一颗另起一组数字。
  static const Duration _slideDuration = Duration(milliseconds: 180);
  static const Curve _slideCurve = Curves.easeOut;

  /// 滑块相对胶囊的内缩。半格宽 34 - 2×3 = 28,滑块中心因此正落在图标中心
  /// (左 17 / 右 51),不会差半格。
  static const double _knobInset = 3;
  static const double _knobHeight = kCaptureToggleButtonSize - _knobInset * 2;
  static const double _knobWidth = kCaptureModeToggleWidth / 2 - _knobInset * 2;

  @override
  Widget build(BuildContext context) {
    final auto = mode == OfficialCaptureMode.auto;
    return Opacity(
      opacity: onTap == null ? 0.4 : 1.0,
      child: GestureDetector(
        key: const ValueKey<String>('official-capture-mode-toggle'),
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          // 高度仍取既有的开关按钮常量:快门(76)仍是行内最高子项,
          // kCaptureShutterRowHeight 的不变式一寸没动。只有宽度变了。
          width: kCaptureModeToggleWidth,
          height: kCaptureToggleButtonSize,
          decoration: BoxDecoration(
            // 槽恒为半透明白;"当前是哪个模式"由滑块表达,不再靠整颗变色。
            color: const Color(0x38FFFFFF),
            borderRadius: BorderRadius.circular(kCaptureToggleButtonSize / 2),
          ),
          child: Stack(
            children: [
              // 高亮滑块:滑过去,不是瞬移。
              AnimatedAlign(
                duration: _slideDuration,
                curve: _slideCurve,
                alignment: auto ? Alignment.centerRight : Alignment.centerLeft,
                child: Padding(
                  padding: const EdgeInsets.all(_knobInset),
                  child: AnimatedContainer(
                    duration: _slideDuration,
                    curve: _slideCurve,
                    width: _knobWidth,
                    height: _knobHeight,
                    decoration: BoxDecoration(
                      color: auto
                          ? const Color(0xFF0A84FF) // RS 的蓝 = iOS system blue
                          : const Color(0x59FFFFFF),
                      borderRadius: BorderRadius.circular(_knobHeight / 2),
                    ),
                  ),
                ),
              ),
              // 两个图标常驻,压在滑块之上 —— 静止时也看得见"另一个模式"。
              Row(
                children: <Widget>[
                  _CaptureModeToggleIcon(
                    icon: Icons.photo_camera_rounded,
                    selected: !auto,
                  ),
                  _CaptureModeToggleIcon(
                    icon: Icons.videocam_rounded,
                    selected: auto,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 分段开关里的一枚图标。占半格宽,选中侧全白、未选中侧半透明 —— 淡入淡出
/// 与滑块同一档节奏,免得滑块已经到位了颜色还在原地跳。
class _CaptureModeToggleIcon extends StatelessWidget {
  const _CaptureModeToggleIcon({required this.icon, required this.selected});

  final IconData icon;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Center(
        child: AnimatedOpacity(
          duration: _CaptureModeToggle._slideDuration,
          curve: _CaptureModeToggle._slideCurve,
          opacity: selected ? 1.0 : 0.5,
          child: Icon(icon, size: 20, color: Colors.white),
        ),
      ),
    );
  }
}

/// 自动模式的红色录制键 —— 它**就是**开始/停止键(RS 同款),自动模式下
/// 没有另一颗手动快门。外形与 [_ShutterButton] 同尺寸同白环,只是芯是红的:
/// 未开拍 = 红圆,开拍中 = 红圆角方(录制→停止的通用语)。
///
/// 指示器(spec §8)全部走**视觉状态**,一个字的说教都不上:
///   · 落帧      → 白环向外脉冲一次([pulseToken] 每落一帧 +1)
///   · 位移不够  → 白环转暗、静止(表达"在等你动")
///   · 节奏拉长  → 不额外表达,脉冲之间自然变稀
class _AutoRecordButton extends StatefulWidget {
  const _AutoRecordButton({
    required this.enabled,
    required this.running,
    required this.indicator,
    required this.pulseToken,
    required this.onTap,
  });

  final bool enabled;
  final bool running;
  final AutoCaptureIndicator indicator;
  final int pulseToken;
  final VoidCallback onTap;

  @override
  State<_AutoRecordButton> createState() => _AutoRecordButtonState();
}

class _AutoRecordButtonState extends State<_AutoRecordButton>
    with SingleTickerProviderStateMixin {
  // ⚠️ 这是**纯显示**动画钟。它永远不回喂 AutoCaptureController ——
  // controller 的唯一时钟是 ARPose.timestamp(ARFrame 时间轴)。
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 420),
  );

  @override
  void didUpdateWidget(_AutoRecordButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulseToken != oldWidget.pulseToken) _pulse.forward(from: 0);
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final waiting = widget.indicator == AutoCaptureIndicator.waiting;
    final ringAlpha = waiting ? 0.38 : 1.0;
    const red = Color(0xFFFF3B30);
    // 白环 4 + 内缩 5,与 _ShutterButton 的芯同尺寸。
    const core = kCaptureShutterDiameter - 18;
    return Opacity(
      opacity: widget.enabled ? 1.0 : 0.4,
      child: GestureDetector(
        key: const ValueKey<String>('official-auto-capture-record-button'),
        onTap: widget.enabled ? widget.onTap : null,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: kCaptureShutterDiameter,
          height: kCaptureShutterDiameter,
          child: Stack(
            alignment: Alignment.center,
            children: [
              AnimatedBuilder(
                animation: _pulse,
                builder: (context, _) {
                  final t = _pulse.value;
                  if (t <= 0 || t >= 1) return const SizedBox.shrink();
                  final d = kCaptureShutterDiameter * (1 + 0.30 * t);
                  return Container(
                    width: d,
                    height: d,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: (1 - t) * 0.85),
                        width: 3,
                      ),
                    ),
                  );
                },
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: kCaptureShutterDiameter,
                height: kCaptureShutterDiameter,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: ringAlpha),
                    width: 4,
                  ),
                ),
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                width: widget.running ? 28 : core,
                height: widget.running ? 28 : core,
                decoration: BoxDecoration(
                  color: red,
                  borderRadius: BorderRadius.circular(
                    widget.running ? 6 : core / 2,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// [spec §8.1] 顶部说明条 —— **一次性**,不是常驻。
///
/// 露出时机只有两个:挂上(= 进采集页,本组件只在 AR 会话建起来后才存在)、
/// 以及 [mode] 变化(= 用户切了模式)。之后 3 秒自动淡出。
///
/// 为什么必须是瞬态:[2026-07-27 UI 签决] 删掉的那条入场提示,理由原文是
/// "每次进拍摄都挡一次取景框、说的又是用户还没到的事",并且要求下面四档
/// 横幅**回到各自的固定档位**。一条常驻文案会把这两条一起推翻。
///
/// 停留时长与 [_HardRejectToast] 同源(3 秒)——顶部这一档上的东西共用一个
/// 节奏,不新造常数。
class _CaptureModeTopHint extends StatefulWidget {
  const _CaptureModeTopHint({required this.mode});

  final OfficialCaptureMode mode;

  @override
  State<_CaptureModeTopHint> createState() => _CaptureModeTopHintState();
}

class _CaptureModeTopHintState extends State<_CaptureModeTopHint> {
  Timer? _fadeTimer;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    // 首帧就可见,不能在 initState 里 setState。
    _visible = true;
    _armDismiss();
  }

  @override
  void didUpdateWidget(_CaptureModeTopHint oldWidget) {
    super.didUpdateWidget(oldWidget);
    // ⚠️ 这个早退是必需的:父级每帧都可能重建(pose 流 20–60 Hz),没有它
    // 每次重建都会把提示重新点亮 —— 那就等于常驻,只是绕了个圈。
    if (widget.mode == oldWidget.mode) return;
    setState(() => _visible = true);
    _armDismiss();
  }

  void _armDismiss() {
    _fadeTimer?.cancel();
    _fadeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  void dispose() {
    _fadeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedOpacity(
        opacity: _visible ? 1.0 : 0.0,
        duration: const Duration(milliseconds: 250),
        child: _IdleHintPill(text: autoCaptureTopHintText(widget.mode)),
      ),
    );
  }
}

/// 切到自动模式时居中浮出的一条短提示(RS 的 "Auto Capture On")。
/// [token] 变一次就浮一次;进页面时的默认自动不算切换,所以 token 初值不触发。
class _AutoCaptureOnToast extends StatefulWidget {
  const _AutoCaptureOnToast({required this.token});

  final int token;

  @override
  State<_AutoCaptureOnToast> createState() => _AutoCaptureOnToastState();
}

class _AutoCaptureOnToastState extends State<_AutoCaptureOnToast> {
  Timer? _fadeTimer;
  bool _visible = false;

  @override
  void didUpdateWidget(_AutoCaptureOnToast oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.token == oldWidget.token) return;
    setState(() => _visible = true);
    _fadeTimer?.cancel();
    _fadeTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _visible = false);
    });
  }

  @override
  void dispose() {
    _fadeTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _visible ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 220),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.68),
          borderRadius: BorderRadius.circular(22),
        ),
        child: const Text(
          kAutoCaptureOnToastText,
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
