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
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'dart:math' as math;
import 'dart:typed_data' show Int32List, Float32List, Float64List, Uint8List;

import 'package:flutter/foundation.dart'
    show compute, defaultTargetPlatform, TargetPlatform, ValueListenable;

import '../../official_capture/dense_stage.dart';

import 'package:flutter/cupertino.dart'
    show
        CupertinoActionSheet,
        CupertinoActionSheetAction,
        showCupertinoModalPopup;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:vector_math/vector_math_64.dart' show Quaternion, Vector3;

import '../../point_cloud_display/progressive_octree_order.dart';
import '../../official_capture/auto_capture_controller.dart';
import '../../official_capture/auto_capture_geometry.dart'
    show medianDepthFromCloudXyz;
import '../../official_capture/auto_capture_governor.dart';
import '../../official_capture/auto_capture_mode.dart';
import '../../official_capture/auto_capture_telemetry.dart';
import '../../official_capture/capture_coverage_cloud.dart';
import '../../official_capture/capture_session.dart';
import '../../official_capture/colorize_pipeline.dart';
import '../../official_capture/database_archive_policy.dart';
import '../../official_capture/sqlite_db_health.dart';
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
import '../../eta/eta_prior_log.dart';
import '../../eta/pipeline_eta.dart';
import '../../dense/dense_live_cloud.dart';
import '../../dense/dense_stage_progress.dart';
import '../../point_cloud_lod/dense_lod_cache.dart';
import '../../official_capture/transient_preview_cleanup.dart';
import '../../official_capture/dome/dome_target_points.dart';
import '../../official_capture/realtime_capture_preview.dart';
import '../../official_capture/map_frame_alignment.dart';
import '../../official_capture/map_keyframe_evidence.dart';
import '../../official_capture/sfm_live_recon.dart';
import '../../official_capture/sfm_resume.dart' as sfm_resume;
import '../../official_dome/ar_pose.dart';
import '../../l10n/app_localizations.dart';
import '../../me/scan_record_store.dart';
import '../../official_quality/guidance_engine.dart' show GuidanceSnapshot;
import '../../official_util/device_log.dart';
import '../me_page.dart';
import '../reconstruction_draft_route_state.dart';
import '../reconstruction_route_release_gate.dart';
import '../scan_record.dart';
import 'ar_album_page.dart';
import 'capture_preview_rect.dart';
import '../../official_capture/capture_format.dart';
import '../../official_capture/selection_box.dart';
import 'selection_tools_layer.dart';
import 'sparse_cloud_view.dart'
    show
        CloudViewCamera,
        CloudViewController,
        PerspectiveStart,
        SparseCloudPainter,
        editingFrameOf;
import 'capture_pose_camera.dart';
import 'dense_wait_eta.dart';
import 'capture_exit_dialog.dart';
import 'official_gallery_routes.dart';
import 'sfm_preview_overlay.dart';
import 'sparse_cloud_viewer_page.dart' show SparseCloudData, loadReviewCloud;
import '../sparse_thumbnail.dart';
import '../../util/image_sanitize.dart';
import '../../vio/diagnostics/vio_diagnostics_recorder.dart';
import '../../vio/diagnostics/vio_shadow_switch.dart';

/// 一次快门入队的三种结果。手动与自动**共用同一条入队路径**,但对"没入队"
/// 的反馈不同:手动到上限要弹对话框,自动模式绝不弹(每个 tick 撞一次会
/// 刷屏)。把两者的差别收在这个返回值里,守卫就只需要写一份。
enum _ShutterAdmission { admitted, blocked, budgetExhausted }

class OfficialARCapturePage extends StatefulWidget {
  const OfficialARCapturePage({
    super.key,
    this.extendCaptureDir,
    this.reconstructOnlyCaptureDir,
    this.reviewCaptureDir,
  }) : assert(
         (extendCaptureDir == null ? 0 : 1) +
                 (reconstructOnlyCaptureDir == null ? 0 : 1) +
                 (reviewCaptureDir == null ? 0 : 1) <=
             1,
         '补拍、「只重建」、「查看」是三种进入方式,不能同时给',
       );

  /// [2026-09-08 追加拍摄] 非空 = 往这个已有项目里补拍:复用它的 capture 目录、
  /// 照片编号接着排、目录绝不删。留空 = 原来的"新建一次拍摄",行为一字未动。
  ///
  /// 跨会话的坐标系**不靠任何厂商 AR SDK 接续**(ARWorldMap / Cloud Anchors /
  /// AR Engine 三端不一致,且后者要云端 —— 已整条作废)。新照片喂的是本次会话
  /// 自己的位姿,而该位姿只进一次性预览云:最终解算自己估 CamFromWorld
  /// (official_aether_sfm_c.cc:10596),重力方向跨会话恒定
  /// (mandatory_arkit_gravity_v1.h:25,ARKit .gravity 世界恒 +Y 朝天)。
  /// 老新两批照片由 SfM 按图像重新对齐 —— 复刻 RealityScan 的做法。
  final String? extendCaptureDir;

  /// [2026-09-11 用户裁决]「只重建」模式:**不开相机**,进来就跑重建,用与正常
  /// 拍摄收尾**完全同一张**浮层显示进度与结果。
  ///
  /// 起因:作品页「开始训练」原本进的是 SfmResumeWaitPage —— 一张只有转圈和
  /// 一行字的黑页,和收尾那套(进度 → 点云 → 选区 → 完成)完全两套东西。
  /// 用户:「点击开始训练那就跟平时拍摄完进入的页面一样不就行了吗」。
  ///
  /// 实现上只需要两件事:initState 里**跳过 _initCamera**,并且一上来就把
  /// `_sfmPhase` 点亮 —— SfmPreviewOverlay 是 Stack 最顶层且"owns navigation",
  /// 点亮之后它就盖住整屏,下面的相机预览层从第一帧起就没露过面。
  final String? reconstructOnlyCaptureDir;

  /// [SAME-PAGE 2026-09-15 用户签决「从个人页再点进项目也走这同一个页面」]
  /// 查看模式:不开相机、不重建,把盘上的稀疏点云装进和拍完一模一样的页
  /// (编辑 / 下一步 / 保存草稿)。稠密在跑时页面照常接它的进度(见 dense 接线)。
  final String? reviewCaptureDir;

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

  String? _initError;
  bool _initializing = true;

  // Dome rotation target — driven by the AR pose stream's
  // position-based azimuth / elevation. Pre-lock both stay 0; once
  // the user taps to lock the world origin (Phase 5) the AR pose
  // populates them.
  bool _recording = false;
  bool _lockInProgress = false;
  bool _finalizingRecording = false;
  bool _finishTapInProgress = false;
  bool _finishCancellationRequested = false;
  bool _finishDrainFailed = false;
  bool _closeTapInProgress = false;
  bool _discardingCapture = false;
  bool _cameraResumeFailed = false;
  bool _maximumPhotosDialogOpen = false;
  String? _captureQueueFailureText;

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
    mapEvidenceProvider: _mapEvidenceFor,
    // [2026-09-07 stella_vslam] mapper_is_skipping_localBA = 工作线程还有帧
    // 排队/在途;is_paused/pause_is_requested = 快门队列不接受。
    mapperAcceptingProvider: () => _shutterQueue.accepting,
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
  /// 上游判据三个量的地图口径来源(map_keyframe_evidence.dart)。
  /// 只在拍摄期流式快照上更新,见那处的同一道闸。
  final MapKeyframeEvidenceSource _mapEvidenceSource =
      MapKeyframeEvidenceSource();

  /// 每 tick 取一次数。取不到就返回 null —— 控制器据此退回现役 LK 口径。
  ///
  /// 参考帧 = **最后一张喂进重建的照片**(上游的 last_inserted_keyfrm /
  /// ref_keyfrm 在我们这里就是它)。内参与画幅取那张照片的 —— 判据问的是
  /// 「从现在这个位置拍一张,能看到几个路标」,所以用照片的成像参数才对口径;
  /// 预览分辨率不参与(用户 2026-09-11:"预览的像素不重要")。
  StellaMapEvidence? _mapEvidenceFor(ARPose pose) {
    if (!_mapEvidenceSource.hasSnapshot) return null;
    final recon = _sfmRecon;
    if (recon == null) return null;
    int? refId;
    SfmFedFrameMeta? refMeta;
    recon.fedFrameMeta.forEach((id, meta) {
      if (refId == null || id > refId!) {
        refId = id;
        refMeta = meta;
      }
    });
    final id = refId;
    final meta = refMeta;
    if (id == null || meta == null) return null;
    final q = meta.arkitQuatWxyz;
    final t = meta.arkitTransTxyz;
    if (q == null || q.length < 4 || t == null || t.length < 3) return null;
    // 当前预览帧的 ARKit 位姿 → CamFromWorld(与上游同约定)。
    // pose.orientation 是 world-from-camera,pose.position 是相机中心。
    final rotWc = rotationFromQuatWxyz(
      pose.orientation.w,
      pose.orientation.x,
      pose.orientation.y,
      pose.orientation.z,
    );
    final rotCw = <double>[
      rotWc[0], rotWc[3], rotWc[6],
      rotWc[1], rotWc[4], rotWc[7],
      rotWc[2], rotWc[5], rotWc[8],
    ];
    final p = pose.position;
    final transCw = <double>[
      -(rotCw[0] * p.x + rotCw[1] * p.y + rotCw[2] * p.z),
      -(rotCw[3] * p.x + rotCw[4] * p.y + rotCw[5] * p.z),
      -(rotCw[6] * p.x + rotCw[7] * p.y + rotCw[8] * p.z),
    ];
    return _mapEvidenceSource.evidenceFor(
      refFrameId: id,
      arkitRefPose: CamFromWorldPose(
        rotCw: rotationFromQuatWxyz(q[0], q[1], q[2], q[3]),
        transCw: <double>[t[0], t[1], t[2]],
      ),
      arkitCurrentPose: CamFromWorldPose(rotCw: rotCw, transCw: transCw),
      fx: meta.fx,
      fy: meta.fy,
      cx: meta.cx,
      cy: meta.cy,
      imageWidth: meta.imageW.toDouble(),
      imageHeight: meta.imageH.toDouble(),
    );
  }

  double? _liveCloudMedianDepthFor(ARPose pose) {
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

  /// 低重叠警告的可见 UI 状态。单列出来参与 setState 节流，否则连续的
  /// skipNotMoved 会把“请减速”变化误判成无变化而永远不刷新到屏幕。
  bool _autoPromptSlowDown = false;

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

  /// Live reconstruction is part of the capture contract, not an optional
  /// preview. Until its worker owns the shared lease, both capture controls
  /// stay disabled. A startup failure remains visible until this take exits.
  bool _sfmStarting = false;
  String? _sfmStartFailureText;

  bool get _sfmCaptureReady =>
      _recording &&
      !_sfmStarting &&
      _sfmStartFailureText == null &&
      _sfmRecon != null;

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

  /// Colored LOCAL (phase-1) snapshot held back from display: we only reveal
  /// the cleaner REFINED (phase-2) cloud, but keep this so a REFINE failure
  /// still shows a usable colored cloud instead of an error (采集必出点云).
  SfmLiveSnapshot? _pendingLocalColored;

  /// [LIVE-WAIT 2026-09-15] Interim, uncoloured (all-white, same as the AR
  /// layer during capture) cloud shown from the finish tap until the refined
  /// cloud lands: the last streaming snapshot at the tap, then every
  /// drain-time / phase-1 preview the worker publishes. Never colorized,
  /// never persisted; `_sfmSnapshot` (refined) takes precedence on screen.
  SfmLiveSnapshot? _sfmLiveSnapshot;

  /// [LIVE-WAIT] The rig start that reproduces the ARKit camera at the tap
  /// (capture_pose_camera.dart); null = default framing.
  PerspectiveStart? _sfmPerspectiveStart;

  /// [DENSE-SAME-PAGE 2026-09-15] Display wrapper of the growing dense cloud
  /// (lib/dense DenseLiveCloud, review budget); rebuilt only when its buffers
  /// change identity. The sparse `_sfmSnapshot` stays the editing/next source.
  SfmLiveSnapshot? _denseDisplay;
  Float32List? _denseDisplayKey;

  /// Dense PLY already on disk when the page is entered in review mode (shown
  /// instead of the sparse cloud; dense is then "done" for this project).
  SfmLiveSnapshot? _denseReviewSnapshot;

  /// [LOD v3 2026-09-24] The finished dense cloud's octree (built on the phone by
  /// DenseLodCache into Library/Caches/lod/<作品标识>/ after official_dense.ply lands, or
  /// found valid on re-entry). While it is not ready — building, failed, or not asked for —
  /// the same view keeps drawing the flat 1 M display copy.
  ValueListenable<DenseLodState>? _denseLod;
  String? _denseLodPly;

  void _watchDenseLod(String densePly) {
    if (_denseLodPly == densePly && _denseLod != null) return;
    _denseLod?.removeListener(_onDenseLod);
    _denseLodPly = densePly;
    _denseLod = DenseLodCache.instance.watch(densePly)..addListener(_onDenseLod);
    DeviceLog.log('OfficialARCapturePage', 'dense LOD: ${_denseLod!.value}');
  }

  void _onDenseLod() {
    final s = _denseLod?.value;
    if (s != null) DeviceLog.log('OfficialARCapturePage', 'dense LOD: $s');
    if (mounted) setState(() {});
  }

  /// The octree to hand the view: only while the finished dense cloud is what is on screen.
  String? get _lodOctreeDirOnScreen {
    final s = _denseLod?.value;
    if (s == null || s.phase != DenseLodPhase.ready) return null;
    if (_denseRunningHere || !_denseDoneHere) return null;
    return s.octreeDir;
  }

  /// [LIVE-WAIT] Wait countdown of the sparse job (lib/eta: Ninja prediction +
  /// commit-once coarse label). Planned when the wait page goes up, finished
  /// after the PLY is persisted; the prior log lives in the app documents dir.
  PipelineEta? _sparseEta;
  EtaPriorLog? _etaPriors;
  int _etaDrainFedBase = 0;

  /// L2 渲染门可见性(ghost_view_filter.dart),与 [_sfmSnapshot] /
  /// [_pendingLocalColored] 的点序逐位对齐;null = 全显示。RENDER-ONLY:
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
  bool _sfmPendingPop = false;

  /// The waiting UI can be folded into Drafts without popping this route.
  /// Keeping the route mounted is what keeps the worker, queue and final
  /// snapshot alive for a later task-card tap.
  bool _showDraftsWhileReconstructing = false;
  bool _draftRecordActionInProgress = false;
  bool _draftTerminalExitScheduled = false;
  final ReconstructionRouteReleaseGate _routeReleaseGate =
      ReconstructionRouteReleaseGate();

  /// Capture directory used as the idempotency key for the one iOS continued-
  /// processing task protecting this user-triggered final reconstruction.
  String? _reconUmbrellaJobID;

  // ─── RS-style capture-coverage cloud (Dart-owned policy) ──────────
  // Empty until the first committed shutter; every photo frustum-marks the
  // VIO voxel cloud and the covered points render red→yellow→green by how
  // many photos saw them. Policy lives in capture_coverage_cloud.dart
  // (cross-platform); native only displays what we push.
  final CaptureCoverageCloud _coverageCloud = CaptureCoverageCloud();
  StreamSubscription<OfficialHighResReconstructionInput>? _coverageFeedSub;

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
    // [DENSE-SAME-PAGE] the dense stage reports through a global notifier; this
    // page follows it for its own project (running → cloud grows, done → 完成).
    denseStageProgress.addListener(_onDenseProgress);
    DenseWaitEta.instance.label.addListener(_onDenseProgress);
    DenseWaitEta.instance.ensureAttached();
    _shutterQueue = ManualCaptureQueue(
      maxTickets: kOfficialMaximumCaptureFrames,
      execute: _executeShutterTicket,
      onError: _onShutterTicketError,
    );
    WidgetsBinding.instance.addObserver(this);
    // 原生侧「这一张已经拍下」的信号(见 _handleNativeCall)。三端规矩:
    // 反馈发在拍下那一刻,不发在处理完成那一刻。
    _arKitChannel.setMethodCallHandler(_handleNativeCall);
    // Capture reconstruction runs on-device via streaming SfM (see
    // _startSfmLiveRecon) plus server-side recon on upload — no local model
    // download gate. The App Store install bundle stays small (~80 MB).
    final review = widget.reviewCaptureDir;
    if (review != null) {
      _initializing = false;
      _sfmPhase = SfmPreviewPhase.generating; // cover page while the PLY loads
      unawaited(_enterReviewMode(review));
      return;
    }
    final reconstructOnly = widget.reconstructOnlyCaptureDir;
    if (reconstructOnly != null) {
      // 只重建:绝不碰相机/ARKit。浮层立刻点亮,盖住整屏。
      _initializing = false;
      _sfmPhase = SfmPreviewPhase.generating;
      _sfmFinalizeStage = 0;
      _sfmStageStartMs = DateTime.now().millisecondsSinceEpoch;
      _startSfmStageTicker();
      unawaited(_runReconstructOnly(reconstructOnly));
      return;
    }
    _initCamera();
  }

  /// 「只重建」模式的入口:db 还能用且装着全部照片就照 db 续跑(快,特征
  /// 不用重提);否则整项目全量重喂。判据与作品页长按菜单**同一对纯函数**
  /// (sqlite_db_health / projectCoverageFrom),不另立标准。
  Future<void> _runReconstructOnly(String captureDir) async {
    final health = sqliteDatabaseUsable(
      File('$captureDir/${DatabaseArchivePolicy.sourceFileName}'),
    );
    final coverage = sfm_resume.projectCoverage(captureDir);
    DeviceLog.log(
      'OfficialARCapturePage',
      'reconstruct-only $captureDir: db=${health.usable ? "可用" : health.reason} '
          '覆盖=${coverage.covered ? "齐" : coverage.reason} '
          '(盘上 ${coverage.photosOnDisk} / 账本 ${coverage.fedDistinct})',
    );
    if (health.usable && coverage.covered) {
      final recon = await SfmLiveRecon.start(
        dbPath: '$captureDir/official_sfm_live.db',
      );
      if (recon != null) {
        _sfmRecon = recon;
        _sfmEventSub = recon.events.listen(_onSfmEvent);
        // 续跑会话没喂过帧 ⇒ _fedMeta 为空 ⇒ 重力对齐会整段跳过、云是歪的。
        // 先用拍摄期落盘的 fed_frames.jsonl 回填,与 sfm_resume 的续跑腿同处理。
        final fedMeta = await sfm_resume.loadFedFrameMeta(captureDir);
        recon.seedFedMeta(fedMeta);
        await _beginReconUmbrella(captureDir);
        recon.resumeFromDb();
        unawaited(
          _beginSparseEta(recon: recon, drainUnits: 0, frames: fedMeta.length),
        );
        DeviceLog.log('OfficialARCapturePage', 'reconstruct-only: 照 db 续跑');
        return;
      }
      DeviceLog.log(
        'OfficialARCapturePage',
        'reconstruct-only: 续跑会话起不来,改走全量重喂',
      );
    }
    await _startArchivedRefeed(captureDir, liveFedCount: 0);
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
      if (_recording && _sfmPhase == null) {
        _restartArSessionAfterResume();
      }
    }
  }

  Future<void> _pauseArForBackground() async {
    // Release only the camera; leave the Dart CaptureSession started and its
    // retained photos untouched so resume continues the same capture.
    final session = _session;
    session?.suspendManualCaptureTransactions();
    try {
      await _arKitChannel.invokeMethod<void>('stopSession');
    } catch (_) {
      session?.resumeManualCaptureTransactions();
    }
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
      // resume:true → native keeps the world map + photo-card anchors (no
      // resetTracking / removeExistingAnchors) so the AR cards survive.
      await _arKitChannel.invokeMethod<void>('startSession', {'resume': true});
      _cameraResumeFailed = false;
      _session?.resumeManualCaptureTransactions();
      if (_recording &&
          !_finishTapInProgress &&
          !_closeTapInProgress &&
          !_shutterQueue.accepting) {
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
    await _finalizeRecording(navigateToDrafts: false, showSparseHint: false);
  }

  Future<void> _onCloseTap() async {
    if (_finalizingRecording ||
        _lockInProgress ||
        _closeTapInProgress ||
        _discardingCapture) {
      return;
    }
    if (!_recording) {
      if (mounted) Navigator.of(context).maybePop(false);
      return;
    }

    if (_finishTapInProgress) _finishCancellationRequested = true;
    _closeTapInProgress = true;
    try {
      // [2026-08-22 用户签决] 黑白弹窗 + 开关:"是否保存照片,方便下次补拍"
      // 的小开关(默认开=绿=保存,关=红=不保存)+ "确定"/"取消" 两颗按钮。
      // (取代 2026-08-09 那版滑轴 —— 见 capture_exit_dialog.dart 文件头。)
      // 返回值语义不变:saveExit / discardExit / null=回拍摄。
      // 弹窗是模态的:不先停,自动拍会在弹窗背后继续落帧。
      _stopAutoCapture();
      final hasAcceptedPhotos =
          _projectPhotos.count + _shutterQueue.outstandingCount > 0;
      final choice = hasAcceptedPhotos
          ? await showCaptureExitDialog(context)
          : CaptureExitChoice.discardExit;
      if (!mounted || choice == null) return;

      if (choice == CaptureExitChoice.saveExit) {
        // 退出并保存:与"完成"同一条落草稿链路,但**不启动重建** ——
        // 照片与增量 db 原样留在盘上,草稿显示"未完成",点卡片可断点续跑。
        // 无损:不 cancelPending,先把在途快门全部落地。
        _discardingCapture = true;
        final session = _session;
        await _shutterQueue.freezeAndDrain();
        if (session != null) {
          await session.stop();
          await _stopVioShadowForCapture();
          await session.waitForPendingPhotoSaves();
        }
        final recon = _sfmRecon;
        if (recon != null) {
          _sfmRecon = null;
          await _sfmFeedSub?.cancel();
          _sfmFeedSub = null;
          await _sfmEventSub?.cancel();
          _sfmEventSub = null;
          unawaited(recon.dispose());
        }
        await _persistDraft(showSnackBar: false);
        if (!mounted) return;
        setState(() {
          _recording = false;
          _isAiming = false;
          _lockInProgress = false;
        });
        _previewModel.reset();
        // pop(true) = 提示外壳切到"我的草稿"(与完成路径同语义)。
        Navigator.of(context).pop(true);
        return;
      }

      _discardingCapture = true;
      _shutterQueue.cancelPending();
      final session = _session;
      if (session != null) await session.stop();
      await _stopVioShadowForCapture();
      await _shutterQueue.freezeAndDrain();
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
    } finally {
      _discardingCapture = false;
      _closeTapInProgress = false;
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
        await session.start(
          autoLock: false,
          extendCaptureDir: widget.extendCaptureDir,
        );
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
  /// 补拍时把上一次已落盘的照片装回相册。非补拍(extendCaptureDir 为空)直接
  /// 返回,原行为一字未动。
  ///
  /// 失败必须留痕:目录读不动就记一条设备日志 —— 静默装 0 张会让完成闸把
  /// 「还差几张」算错,而用户无从察觉。
  Future<void> _adoptExistingProjectPhotos(CaptureSession session) async {
    final extendDir = widget.extendCaptureDir;
    if (extendDir == null || extendDir.trim().isEmpty) return;
    final dirPath = session.photosHighresDir ?? session.photosDir;
    if (dirPath == null) {
      DeviceLog.log(
        'OfficialARCapturePage',
        'extend: no photos dir — album starts empty, 完成闸会按本次会话计数',
      );
      return;
    }
    try {
      final dir = Directory(dirPath);
      if (!await dir.exists()) return;
      final jpegs = <String>[];
      await for (final e in dir.list(followLinks: false)) {
        if (e is! File) continue;
        final lower = e.path.toLowerCase();
        if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
          jpegs.add(e.path);
        }
      }
      final adopted = _projectPhotos.adoptExisting(jpegs);
      DeviceLog.log(
        'OfficialARCapturePage',
        'extend: adopted $adopted existing photos into the album '
            '(project now ${_projectPhotos.count})',
      );
    } on FileSystemException catch (e) {
      DeviceLog.log(
        'OfficialARCapturePage',
        'extend: adopt existing photos FAILED: $e',
      );
    }
  }

  Future<void> _startManualCapture() async {
    final session = _session;
    if (session == null || _recording || !mounted) return;
    try {
      await session.start(
        autoLock: true,
        manualCapture: true,
        extendCaptureDir: widget.extendCaptureDir,
      );
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
      // [2026-09-08 补拍] 相册计数是"**这个项目**有多少张",不是"这次会话拍了
      // 多少张"。它同时喂着 N/300 显示、「至少 20 张」完成闸、300 张上限 ——
      // 只算本次会话,一个已有 10 张的项目补拍时会显示 20/300,用户以为还得
      // 再拍满 20 张。所以先把上一次已落盘的照片装回来。
      await _adoptExistingProjectPhotos(session);
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
      _coverageFeedSub ??= session.sfmFrameStream.listen(_onCoverageKeyframe);
      // [SPRINT-FIX + YIELD-FPS-LINK] 新一轮拍摄:框架内匹配器旗复位。
      AetherMatchFlags.setCaptureActive(true);
      AetherMatchFlags.setPreviewFps30(_adaptiveFpsCurrent <= 30);
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

  /// Per committed shutter: frustum-mark the coverage cloud with the
  /// frame-exact pose+intrinsics (the same SfmFrameFeed that drives
  /// streaming SfM — but fully independent of the SfM worker, so the
  /// coverage UX works even where on-device SfM is unavailable).
  void _onCoverageKeyframe(OfficialHighResReconstructionInput input) {
    final committed = _projectPhotos.commitVerified(
      jpegPath: input.jpegPath,
      captureTimestamp: input.captureTimestamp,
      imageWidth: input.imageWidth,
      imageHeight: input.imageHeight,
    );
    if (!committed) {
      DeviceLog.log(
        'OfficialARCapturePage',
        'verified project photo was not committed: ${input.jpegPath}',
      );
      return;
    }
    final feed = SfmFrameFeed(
      gray: Uint8List(0),
      grayW: input.imageWidth,
      grayH: input.imageHeight,
      imageW: input.imageWidth,
      imageH: input.imageHeight,
      intrinsicFxFyCxCy: input.intrinsics,
      extrinsic4x4: input.cameraTransform,
      timestamp: input.captureTimestamp,
      jpegPath: input.jpegPath,
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
    const text =
        '点云重建服务出错，最近的照片没有进入重建。'
        '照片已保留，但继续拍摄不会改善——请结束本次拍摄后重试。';
    if (_sfmStartFailureText == text || !mounted) return;
    // ⚠️ 这一句翻的是 `_sfmCaptureReady`,而它一假,`_admitShutterCapture`
    // 就**恒**被拒 —— 自动拍从此每次开火都入队失败。基准帧按设计不动,
    // 于是它会一路空转到 5 分钟上限才停,期间一张都拍不出来。
    // 与其余四条会让入队失效的路径(退后台 / 退出弹窗 / 完成 / finalize)
    // 同源:让入队失效的人负责停自动拍。
    // (幂等:_stopAutoCapture 开头就 `if (!isRunning) return;`。)
    _stopAutoCapture();
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
    DeviceLog.log('OfficialARCapturePage', 'sfm: startup blocked: $detail');
    if (!mounted) return;
    // 与 _noteSfmInternalFailure 同源:凡是翻 _sfmCaptureReady 的地方都要停
    // 自动拍,否则它会对着一扇永远关着的门每 tick 撞一次。
    _stopAutoCapture();
    setState(() {
      _sfmStarting = false;
      _sfmStartFailureText = '点云重建未能启动（$detail）。请退出后重试；此次拍摄不会保存。';
    });
  }

  /// Spawns the required streaming-SfM worker for this take and wires the
  /// keyframe feed. Startup is fail-closed: unsupported devices, missing
  /// capture storage, lease contention (reported as a null worker), and thrown
  /// errors all leave a persistent page error with capture/save disabled.
  /// 整项目**全量重喂**:扫 photos_highres → 按帧序号排 → 用**本页自己的**
  /// SfmLiveRecon 喂进去 → finalize。之后的浮层/事件/取色/持久化/「完成」
  /// 全部走与正常拍摄收尾同一条路 —— 本方法只负责把那条路点着。
  ///
  /// 两个调用方:
  ///  · 补拍收尾(_finishRecording 的 extendingProject 分支);
  ///  · 「开始训练」的无相机重建模式(widget.reconstructOnlyCaptureDir)。
  /// 抽成一处是因为两边的正确性要求逐字相同 —— 分两份写必然漂。
  Future<void> _startArchivedRefeed(
    String captureDir, {
    required int liveFedCount,
  }) async {
    final plan = await sfm_resume.planArchivedRefeed(captureDir);
    DeviceLog.log(
      'OfficialARCapturePage',
      'refeed: 本场喂了 $liveFedCount 张;整项目重喂 jpg=${plan.photosFound} '
          'accepted=${plan.ordered.length} rejected=${plan.rejections.length}',
    );
    for (final r in plan.rejections) {
      DeviceLog.log('OfficialARCapturePage', 'refeed reject: $r');
    }

    SfmLiveRecon? refeed;
    if (plan.ordered.isNotEmpty) {
      // 旧 db 整组改名挪开(**绝不删**):新会话帧号从 0 重数,不挪必撞
      // images.name 的 UNIQUE,核自己的注释说那会废掉整场。
      final moved = await sfm_resume.sidelineDatabaseForFreshSession(captureDir);
      DeviceLog.log(
        'OfficialARCapturePage',
        'refeed: sidelined → ${moved.isEmpty ? "(nothing)" : moved.join(",")}',
      );
      refeed = await SfmLiveRecon.start(
        dbPath: '$captureDir/official_sfm_live.db',
      );
    }
    if (refeed == null) {
      // 诚实收场:浮层撤掉,不假装在跑。素材全在盘上,用户可以从作品页
      // 再点一次「开始训练」(覆盖度判据会把它送回全量重喂)。
      final why = plan.ordered.isEmpty
          ? '没有一张可用的存档照片(共 ${plan.photosFound} 张)'
          : '重建会话起不来(资源被占用?)';
      DeviceLog.log('OfficialARCapturePage', 'refeed 放弃:$why');
      if (mounted) {
        setState(() {
          _sfmErrorText = why;
          _sfmPhase = SfmPreviewPhase.generating;
          _sfmFinalizeStage = 0;
          _showDraftsWhileReconstructing = false;
        });
      }
      _stopSfmStageTicker();
      return;
    }

    _sfmRecon = refeed;
    _sfmEventSub = refeed.events.listen(_onSfmEvent);
    var fed = 0;
    for (final parse in plan.ordered) {
      if (refeed.offerFrame(parse.input!)) {
        fed++;
      } else {
        DeviceLog.log(
          'OfficialARCapturePage',
          'refeed: 会话拒收 ${parse.jpegPath.split('/').last}',
        );
      }
    }
    DeviceLog.log(
      'OfficialARCapturePage',
      'refeed: fed=$fed/${plan.ordered.length} → finalize',
    );
    if (mounted) {
      final r = refeed;
      setState(() {
        _sfmFed = r.fedCount;
        _sfmQueued = r.remainingCount;
        _sfmSnapshot = null;
        _sfmLiveSnapshot = null; // no live cloud on the refeed path
        _sfmPerspectiveStart = null;
        _colorizeTarget = null;
        _pendingLocalColored = null;
        _sfmErrorText = null;
        _sfmPhase = SfmPreviewPhase.generating;
        _showDraftsWhileReconstructing = false;
        _sfmFinalizeStage = r.remainingCount == 0 ? 1 : 0;
        _sfmStageStartMs = DateTime.now().millisecondsSinceEpoch;
      });
      _startSfmStageTicker();
    }
    await _beginReconUmbrella(captureDir);
    unawaited(
      _beginSparseEta(
        recon: refeed,
        drainUnits: refeed.remainingCount,
        frames: plan.ordered.length,
      ),
    );
    refeed.finalize();
  }

  Future<void> _startSfmLiveRecon(CaptureSession session) async {
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
      // [2026-09-11 补拍撞名] 补拍复用同一个 captureDir,而新会话的帧号是
      // **每会话从 0 重数**的(`official_aether_sfm_c.cc:9266`
      // `frame_id = s->frames.size()`),写进 db 的名字 `frame_%06d.jpg` 会撞上
      // `images.name` 的 UNIQUE 约束。核自己的注释(同文件 9278 行)写着这种
      // 撞名"bricks the whole live capture" —— 不是废一帧,是这一场之后**每一帧**
      // 都废。所以补拍开场先把旧 db 整组改名挪开(**绝不删**),让这一场在一个
      // 干净的库上跑。
      //
      // 挪走的那份不是损失:这一场结束时走的是**整项目全量重喂**
      // (见 _finishRecording 的补拍分支),重建只认 photos_highres 里的照片,
      // 不认旧 db。旧 db 留在盘上带 `.dead-<ts>` 后缀,随时可查。
      if (widget.extendCaptureDir != null) {
        final moved = await sfm_resume.sidelineDatabaseForFreshSession(
          captureDir,
        );
        DeviceLog.log(
          'OfficialARCapturePage',
          'extend: sidelined old db before fresh session → '
              '${moved.isEmpty ? "(nothing to move)" : moved.join(",")}',
        );
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
      _sfmFeedSub = session.sfmFrameStream.listen(recon.offerFrame);
      _sfmEventSub = recon.events.listen(_onSfmEvent);
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

  void _onHighResCaptureFailure(OfficialHighResCaptureFailureEvent event) {
    if (!mounted) return;
    final message = switch (event.failure) {
      OfficialHighResInputFailure.unexpectedDimensions =>
        '高分辨率照片不是 4032×3024，本张未进入重建，请重拍',
      OfficialHighResInputFailure.outOfSync => '高分辨率照片与点击时刻不同步，本张未进入重建，请重拍',
      OfficialHighResInputFailure.missingPose ||
      OfficialHighResInputFailure.missingIntrinsics =>
        '本张 ARKit 相机数据不完整，未进入重建，请重拍',
      OfficialHighResInputFailure.captureFailed ||
      OfficialHighResInputFailure.missingJpeg => '高分辨率照片拍摄失败，本张未进入重建，请重拍',
      OfficialHighResInputFailure.actualStillMissingEvidence =>
        '高分辨率照片缺少实际图像校验，本张未进入重建，请重拍',
      OfficialHighResInputFailure.actualStillQualityRejected =>
        '高分辨率照片不够清晰，本张未进入重建，请重拍',
      OfficialHighResInputFailure.actualStillDuplicate =>
        '高分辨率照片与上一张重复，本张未进入重建，请继续移动',
    };
    _markPhotoCardFailed(event.evidenceJpegPath, message);
  }

  void _markPhotoCardFailed(String evidenceJpegPath, String message) {
    _failedEvidenceJpegPaths.add(evidenceJpegPath);
    unawaited(
      _arKitChannel
          .invokeMethod<void>('removePhotoCard', <String, dynamic>{
            'evidenceJpegPath': evidenceJpegPath,
          })
          .catchError((Object _) {}),
    );
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
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
      // [LIVE-WAIT] the countdown commits itself on the tick (never in build).
      _sparseEta?.labelAt(DateTime.now().millisecondsSinceEpoch);
      setState(() {});
    });
  }

  // ── [LIVE-WAIT 2026-09-15] wait countdown + interim white cloud ──────────

  /// All-white display copy of a worker snapshot (the AR layer's 2026-08-09
  /// "拍摄期 AR live 云全白" rule, see _publishOfficialSfmCloudToAr). Track
  /// arrays are dropped: this copy is display-only and never colorized.
  static Uint8List? _whiteRgbCache;
  static SfmLiveSnapshot _whiteSnapshot(Float32List xyz) {
    // one all-white buffer per length (a drain-time preview arrives per fed
    // frame; the painter keys its colour cache on xyz identity, not rgb)
    var rgb = _whiteRgbCache;
    if (rgb == null || rgb.length != xyz.length) {
      rgb = Uint8List(xyz.length)..fillRange(0, xyz.length, 255);
      _whiteRgbCache = rgb;
    }
    return SfmLiveSnapshot(
      xyz: xyz,
      rgb: rgb,
      posesPacked: Float64List(0),
      summary: const <String, dynamic>{'source': 'live_white'},
      refined: false,
      obsOffsets: Int32List(0),
      obsFrameIds: Int32List(0),
      obsXY: Float32List(0),
    );
  }

  /// The capture camera at this instant, as the cloud view's start: the AR
  /// image sits in the CapturePreviewRect (full width, 3:4, below the safe
  /// top) and the overlay's cloud view shares the screen's top-left origin.
  PerspectiveStart? _perspectiveStartAtTap(Float32List xyz) {
    final pose = _previewModel.lastPose;
    if (pose == null || !mounted) return null;
    if (pose.imageWidth <= pose.imageHeight || pose.intrinsicFxFyCxCy.length != 4) {
      DeviceLog.log(
        'OfficialARCapturePage',
        'perspective start skipped: image ${pose.imageWidth}x${pose.imageHeight}',
      );
      return null;
    }
    final screen = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final w = screen.width;
    final rect = Rect.fromLTWH(
      0,
      capturePreviewTop(
        screen: screen,
        safeTop: safe.top,
        safeBottom: safe.bottom,
      ),
      w,
      w / pwPreviewAspect,
    );
    final pin = capturePinholeFromPose(
      extrinsic4x4: pose.extrinsic4x4,
      intrinsicFxFyCxCy: pose.intrinsicFxFyCxCy,
      imageWidth: pose.imageWidth,
      imageHeight: pose.imageHeight,
      viewport: rect,
    );
    if (pin == null) return null;
    final start = capturePoseToRig(pin: pin, xyz: xyz, viewport: rect);
    DeviceLog.log(
      'OfficialARCapturePage',
      'perspective start: ${start == null ? "none (no point in front)" : "f=${start.f.toStringAsFixed(1)} o=(${start.ox.toStringAsFixed(1)},${start.oy.toStringAsFixed(1)}) camDist=${start.camDist.toStringAsFixed(3)} ypr=(${start.yaw.toStringAsFixed(3)},${start.pitch.toStringAsFixed(3)},${start.roll.toStringAsFixed(3)})"} '
          'rect=$rect img=${pose.imageWidth}x${pose.imageHeight} k=${pose.intrinsicFxFyCxCy.map((v) => v.toStringAsFixed(1)).join(",")}',
    );
    return start;
  }

  /// The project directory this page is about: the live capture session's, or
  /// the one handed in by the reconstruct-only / review entry. Every persist,
  /// selection-box and dense-stage path must use THIS (the reconstruct-only
  /// page has no CaptureSession, so `_pageCaptureDir` was null there).
  String? get _pageCaptureDir =>
      _session?.captureDir ??
      widget.reconstructOnlyCaptureDir ??
      widget.reviewCaptureDir;

  /// [SAME-PAGE 2026-09-15] Gallery re-entry: load the persisted sparse cloud
  /// (review budget, same loader as the old viewer page) into the finished
  /// wait-page state. Missing/empty PLY ⇒ the error state (material kept).
  Future<void> _enterReviewMode(String dir) async {
    final ply = '$dir/official_sfm_sparse.ply';
    SparseCloudData? cloud;
    try {
      cloud = await compute(loadReviewCloud, ply, debugLabel: 'review_load_sparse');
    } catch (e) {
      DeviceLog.log('OfficialARCapturePage', 'review load failed: $e');
    }
    // dense already produced for this project ⇒ show it (dev convenience; the
    // user's deliverable is the mesh, see 2026-09-15 decision on the budget).
    SparseCloudData? dense;
    final densePly = '$dir/official_dense.ply';
    if (File(densePly).existsSync()) {
      // [LOD v3] a valid tree is used at once; otherwise the 1 M copy shows while it is built.
      _watchDenseLod(densePly);
      try {
        dense = await compute(loadReviewCloud, densePly, debugLabel: 'review_load_dense');
      } catch (e) {
        DeviceLog.log('OfficialARCapturePage', 'review dense load failed: $e');
      }
    }
    if (!mounted) return;
    final c = cloud;
    final d = dense;
    setState(() {
      if (d != null && d.count > 0) {
        _denseReviewSnapshot = SfmLiveSnapshot(
          xyz: d.xyz,
          rgb: d.rgb,
          posesPacked: Float64List(0),
          summary: const <String, dynamic>{'source': 'dense_review'},
          refined: true,
          obsOffsets: Int32List(0),
          obsFrameIds: Int32List(0),
          obsXY: Float32List(0),
        );
      }
      if (c == null || c.count == 0) {
        _sfmPhase = SfmPreviewPhase.error;
        _sfmErrorText = '未找到点云';
      } else {
        _sfmSnapshot = SfmLiveSnapshot(
          xyz: c.xyz,
          rgb: c.rgb,
          posesPacked: Float64List(0),
          summary: const <String, dynamic>{'source': 'review'},
          refined: true,
          obsOffsets: Int32List(0),
          obsFrameIds: Int32List(0),
          obsXY: Float32List(0),
        );
        _sfmPhase = SfmPreviewPhase.refined;
      }
      // "保存草稿" / 完成 on this page pops the route (nothing to reveal).
      _sfmPendingPop = true;
    });
    DeviceLog.log(
      'OfficialARCapturePage',
      'review mode: $dir → ${c == null ? "no cloud" : "${c.count} pts (file ${c.sourceCount})"}',
    );
  }

  static const String _kEtaPriorLogName = 'official_eta_prior_log.json';

  /// Plans the sparse-job countdown. Units = frames per stage (Parallax's
  /// per-unit cost model), priors = this device's last run (Ninja's log).
  /// [drainUnits] = frames still to be fed by the worker at this moment.
  Future<void> _beginSparseEta({
    required SfmLiveRecon recon,
    required int drainUnits,
    required int frames,
  }) async {
    final startMs = DateTime.now().millisecondsSinceEpoch;
    _etaDrainFedBase = recon.fedCount; // latched now, before any await
    _sparseEta = null;
    _etaRefineRoundBase = 0;
    _etaRefineLastStage = 0;
    _etaRefineRoundsSeen = 0;
    _etaRefineMaxIter = 0;
    _etaRefineSwitched = false;
    EtaPriorLog priors;
    try {
      final docs = await getApplicationDocumentsDirectory();
      priors = EtaPriorLog(File('${docs.path}/$_kEtaPriorLogName'));
      await priors.load();
    } catch (e) {
      DeviceLog.log('OfficialARCapturePage', 'eta prior log unavailable: $e');
      priors = EtaPriorLog(
        File('${Directory.systemTemp.path}/$_kEtaPriorLogName'),
      );
    }
    if (!mounted || _sfmPhase != SfmPreviewPhase.generating) return;
    _etaPriors = priors;
    _sparseEta = PipelineEta(
      stages: [
        EtaStage('sparse.drain', drainUnits),
        EtaStage('sparse.phase1', frames),
        EtaStage('sparse.refine', frames),
        // [BA-ITER] real work units for the global BA (Ceres iterations); stays
        // 0 (inert) on engines without pwofficial_finalize_progress.
        const EtaStage('sparse.refine_iter', 0),
        EtaStage('sparse.colorize', frames),
        const EtaStage('sparse.persist', 1),
      ],
      priors: priors,
      startMs: startMs,
    );
    // Events that arrived while the log was loading: catch up on the drain.
    _sparseEta!.markUnits(
      'sparse.drain',
      recon.fedCount - _etaDrainFedBase,
      DateTime.now().millisecondsSinceEpoch,
    );
    DeviceLog.log(
      'OfficialARCapturePage',
      'eta planned: drain=$drainUnits frames=$frames priors='
          '${priors.entries.keys.join(",")}',
    );
  }

  // [BA-ITER 2026-09-16] Global-BA progress from the core (Ceres
  // IterationCallback, stage/round/iter/max_iter). The moment the first tuple
  // arrives the frame-guessed 'sparse.refine' stage is emptied and the real
  // iteration-counted stage takes its place: units = rounds seen × max_iter
  // (grows as rounds are discovered — Ninja EdgeAddedToPlan), done =
  // (round−1)·max_iter + iter. Stage-1 rounds then stage-2 rounds form one
  // sequence. Priors for the two stage ids never mix.
  int _etaRefineRoundBase = 0; // rounds completed in earlier stages
  int _etaRefineLastStage = 0;
  int _etaRefineRoundsSeen = 0;
  int _etaRefineMaxIter = 0;
  bool _etaRefineSwitched = false;

  void _etaRefineProgress(int stage, int round, int iter, int maxIter) {
    final eta = _sparseEta;
    if (eta == null || stage <= 0 || round <= 0 || maxIter <= 0) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (!_etaRefineSwitched) {
      _etaRefineSwitched = true;
      eta.setUnits('sparse.refine', 0); // the guess retires (no unit finished yet)
      _etaRefineMaxIter = maxIter;
    }
    if (stage != _etaRefineLastStage) {
      if (_etaRefineLastStage != 0) _etaRefineRoundBase = _etaRefineRoundsSeen;
      _etaRefineLastStage = stage;
    }
    final globalRound = _etaRefineRoundBase + round;
    if (globalRound > _etaRefineRoundsSeen) _etaRefineRoundsSeen = globalRound;
    final units = _etaRefineRoundsSeen * _etaRefineMaxIter;
    eta.setUnits('sparse.refine_iter', units);
    final done = ((globalRound - 1) * _etaRefineMaxIter + iter).clamp(0, units);
    eta.markUnits('sparse.refine_iter', done, now);
  }

  void _etaMark(String stageId, {int? units}) {
    final eta = _sparseEta;
    if (eta == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (units == null) {
      eta.markStageDone(stageId, now);
    } else {
      eta.markUnits(stageId, units, now);
    }
  }

  /// Job over: ruler verdict to telemetry + device log; priors saved only on
  /// success (a failed run must not become next run's prior).
  Future<void> _finishSparseEta({required bool ok}) async {
    final eta = _sparseEta;
    final priors = _etaPriors;
    _sparseEta = null;
    if (eta == null) return;
    final r = eta.finish(DateTime.now().millisecondsSinceEpoch);
    TelemetryWriter.instance.event('eta_ruler', {
      ...r.toTelemetry(),
      'job': 'sparse',
      'ok': ok,
    });
    DeviceLog.log(
      'OfficialARCapturePage',
      'eta ruler: ${r.verdict.name} label=${r.label} '
          'committed=${r.committedEtaSec?.toStringAsFixed(1)}s '
          'actual=${r.actualSec?.toStringAsFixed(1)}s '
          'total=${r.totalSec.toStringAsFixed(1)}s',
    );
    if (ok && priors != null) {
      try {
        await priors.save();
      } catch (e) {
        DeviceLog.log('OfficialARCapturePage', 'eta prior log save failed: $e');
      }
    }
  }

  // ── [DENSE-SAME-PAGE 2026-09-15] dense stage on this page ─────────────────

  void _onDenseProgress() {
    final p = denseStageProgress.value;
    if (p == null || p.captureDir != _pageCaptureDir) return;
    // [LOD v3] official_dense.ply has landed ⇒ build/verify its octree in the background.
    if (p.state == DenseStageState.done && p.outPly != null) _watchDenseLod(p.outPly!);
    if (mounted && _sfmPhase != null) setState(() {});
  }

  bool get _denseRunningHere {
    final p = denseStageProgress.value;
    return p != null &&
        p.captureDir == _pageCaptureDir &&
        p.state == DenseStageState.running;
  }

  bool get _denseDoneHere {
    if (_denseReviewSnapshot != null) return true;
    final p = denseStageProgress.value;
    return p != null &&
        p.captureDir == _pageCaptureDir &&
        p.state == DenseStageState.done;
  }

  /// The growing (or finished) dense cloud of THIS project, as a display
  /// snapshot; null while it has no points or when the job failed (the sparse
  /// cloud comes back and 下一步 offers a retry).
  SfmLiveSnapshot? _denseSnapshotFor(DenseStageProgress? p) {
    if (p == null || p.captureDir != _pageCaptureDir) return null;
    if (p.state == DenseStageState.failed) return null;
    final DenseLiveCloud? live = p.live;
    if (live == null || live.isEmpty) return null;
    if (identical(_denseDisplayKey, live.xyz) && _denseDisplay != null) {
      return _denseDisplay;
    }
    _denseDisplayKey = live.xyz;
    return _denseDisplay = SfmLiveSnapshot(
      xyz: live.xyz,
      rgb: live.rgb,
      posesPacked: Float64List(0),
      summary: const <String, dynamic>{'source': 'dense_live'},
      refined: true,
      obsOffsets: Int32List(0),
      obsFrameIds: Int32List(0),
      obsXY: Float32List(0),
    );
  }

  String? _denseWaitLabel(BuildContext context) {
    final label = DenseWaitEta.instance.label.value;
    if (label == null) return null;
    final l = AppL10n.of(context);
    return label.minutes == 0 ? l.etaUnderMinute : l.etaMinutes(label.minutes);
  }

  /// Bottom pill text: null ⇒ "计算中…" (the overlay's default).
  String? _sparseWaitLabel(BuildContext context) {
    final label = _sparseEta?.committed;
    if (label == null) return null;
    final l = AppL10n.of(context);
    return label.minutes == 0 ? l.etaUnderMinute : l.etaMinutes(label.minutes);
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

  void _onSfmEvent(SfmLiveEvent event) {
    if (!mounted) return;
    if (event is SfmLivePreview &&
        (event.snapshot.summary['source'] == 'streaming_global_ba' ||
            event.snapshot.summary['source'] == 'streaming_local_ba_live' ||
            event.snapshot.summary['source'] == 'finalize_local_live')) {
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
        // the photo cards are covered once the wait page is up
        if (_sfmPhase == null) _refreshPhotoCardStates();
      }
      // 自动拍位移阈值的场景深度输入(2026-08-24 二拍验证补修):拍摄期的
      // 流式快照**只走这条早退分支**,下方 colorize switch 里的同款钩子在
      // 拍摄期根本执行不到 —— 未命名(7) 整场 fire_live_depth_m 为空就是
      // 这么来的。流式云与 ARKit 同一世界系(posesPacked 为合成零四元数
      // ⇒ _gravityAlign 恒 no-op ⇒ quat 为 null),守卫条件与下方同款。
      if (snapshot.gravityAlignQuatWxyz == null && snapshot.xyz.isNotEmpty) {
        _liveCloudXyz = snapshot.xyz;
        // 🔴 [2026-09-11] 上游判据的地图口径数据源,**必须和 _liveCloudXyz
        // 贴在一起**。上面那段注释早就写明:拍摄期的流式快照只走这条早退
        // 分支,下方 colorize switch 里的同款钩子在拍摄期根本执行不到。
        // build 150 我只加在了下面那个够不到的分支里 ⇒ 整场
        // `evidence.ticks_map = 0`,地图口径一次都没接上(未命名(11) 实测)。
        // 与 _liveCloudXyz 同一道闸、同一处赋值,就不会再走散。
        _mapEvidenceSource.updateFromSnapshot(
          xyz: snapshot.xyz,
          obsOffsets: snapshot.obsOffsets,
          obsFrameIds: snapshot.obsFrameIds,
          posesPacked: snapshot.posesPacked,
        );
      }
      // [LIVE-WAIT 2026-09-15] After the finish tap the same streams (drain-time
      // per-frame previews, then the phase-1 cloud) feed the wait page as an
      // all-white interim cloud until the refined one lands. Display-only.
      if (_sfmPhase == SfmPreviewPhase.generating &&
          _sfmSnapshot == null &&
          snapshot.pointCount > 0) {
        setState(() => _sfmLiveSnapshot = _whiteSnapshot(snapshot.xyz));
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
      // [2026-09-08 实机定罪] `exception` 与 `errInternal` 是**同一类**:两者都是
      // 原生调用抛了、frameId == -1、帧根本没进重建,重拍无济于事。此前只认
      // errInternal,于是补拍撞上一个损坏 db 时,20 帧全走了上面那条"涂红"分支
      // —— 正是这段注释警告过的"把真 bug 伪装成拍摄问题",只不过换了个结果串。
      // 证据:该次会话每帧 `fid=-1` + `aether_sfm_create failed: errDb`,而
      // 设备日志里 `sfm internal fault` **0 次** ⇒ 这道闸被整个绕过。
      // 接进来之后,同样的故障在第 3 帧就会停下并告诉用户,而不是白拍 20 张。
      if (event.result == 'errInternal' || event.result == 'exception') {
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
          _etaMark('sparse.drain', units: _sfmFed - _etaDrainFedBase);
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
        case SfmLiveFinalizeProgress(
          :final stage,
          :final round,
          :final iter,
          :final maxIter,
        ):
          _etaRefineProgress(stage, round, iter, maxIter);
        case SfmLiveFinalizePhase1Done():
          _etaMark('sparse.phase1');
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
          if (event is SfmLiveRefined) {
            _etaMark('sparse.refine');
            _etaMark('sparse.refine_iter');
          }
          break;
        case SfmLiveFailed(:final stage, :final message):
          unawaited(_finishSparseEta(ok: false));
          // During capture (overlay hidden) a per-frame failure is log-only;
          // once the preview is up, a finalize/refine failure surfaces the
          // non-blocking "已保留素材" state. But a REFINE failure after
          // LOCAL_READY should reveal the perfectly usable colored LOCAL cloud
          // we held back (deferred display), NOT an error.
          if (_sfmPhase == SfmPreviewPhase.generating) {
            final localFallback = _pendingLocalColored;
            if (localFallback != null) {
              _sfmSnapshot = localFallback;
              _sfmPhase = SfmPreviewPhase.refined; // show the done chip + cloud
              _pendingLocalColored = null;
              // [2026-08-24] LOCAL 兜底云也是真呈现 —— 同 refined 主路径,
              // 在屏上就算"看过"(PLY 没落盘时 store 侧自然 no-op)。
              final viewedDir = _pageCaptureDir;
              if (!_showDraftsWhileReconstructing && viewedDir != null) {
                unawaited(
                  ScanRecordStore.instance.markResultViewedByCaptureDir(
                    viewedDir,
                  ),
                );
              }
            } else {
              _sfmPhase = SfmPreviewPhase.error;
              _sfmErrorText = '$stage: $message';
            }
          }
      }
    });
    // A failure is terminal immediately. On success the umbrella stays alive
    // through final colorization + PLY persistence and ends in
    // [_colorizeSnapshot], just before the completion button appears.
    switch (event) {
      case SfmLiveFailed():
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
          // [2026-09-11] 上游判据的地图口径数据源。**与上面同一道闸**:只吃
          // 未做重力旋转的拍摄期流式快照 —— 那时重建世界与 ARKit 同系
          // (这一条是上面那段注释里早就立好的纪律,这里照用,不另立)。
          // 每快照重建一次派生表,**不是每 tick**。
          _mapEvidenceSource.updateFromSnapshot(
            xyz: snapshot.xyz,
            obsOffsets: snapshot.obsOffsets,
            obsFrameIds: snapshot.obsFrameIds,
            posesPacked: snapshot.posesPacked,
          );
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
        unawaited(_colorizeSnapshot(snapshot));
      default:
        break;
    }
  }

  // [增量D 2026-07-28] 此处原挂着一段 BIT5/L1 仲裁重算的孤儿注释(所述
  // 函数早已随 E25 停用删除)——注释一并清理,勿被其误导。
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
    if (byFrame.isEmpty) return;

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
    if (identical(_colorizeTarget, snap)) _etaMark('sparse.colorize');
    final decoded = dstats.framesSampled;
    final decodeFail = dstats.decodeFail;
    // 遥测【colorize】:每次真实 native 解码耗时(去重后 unique 次数;
    // 中位数定位 ImageIO 慢帧/热降频)。
    final decodeMsList = dstats.decodeMs;
    if (!identical(_colorizeTarget, snap)) {
      return; // superseded during decode/sampling
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
    final captureDir = _pageCaptureDir;
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
      } catch (e) {
        DeviceLog.log(
          'OfficialARCapturePage',
          'final sparse persist failed: $e',
        );
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
      if (snap.refined) {
        _etaMark('sparse.persist');
        unawaited(_finishSparseEta(ok: persistOk));
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
          _pendingLocalColored = null;
        });
        // [2026-08-24] 终态点云在这里第一次呈现给用户 —— 预览页真的在屏幕上
        // (没退到草稿视图)就算"看过",草稿卡右上角的绿"完成"胶囊不再出现。
        // 退到草稿视图时终态会走自动退出,用户没看到点云,不标。
        if (!_showDraftsWhileReconstructing && captureDir != null) {
          unawaited(
            ScanRecordStore.instance.markResultViewedByCaptureDir(captureDir),
          );
        }
      } else {
        // Defer: do NOT show the noisier phase-1 (local) cloud — wait for the
        // refined one. Hold it as the refine-failure fallback; the generating
        // spinner ("实时重建") stays up as the finalize loading state.
        _pendingLocalColored = display;
      }
    }
    final isTerminalColorize =
        snap.summary['terminal'] == true ||
        snap.summary['source'] == 'streaming_global_ba' ||
        snap.refined;
    if (isTerminalColorize && identical(_colorizeTarget, snap)) {
      if (snap.refined) unawaited(_endReconUmbrella());
    }
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
  Future<void> _releaseLiveReconstructionResources() async {
    // The root FAB must not become enabled until dispose releases the
    // process-wide reconstruction lease.
    await _endReconUmbrella();
    _stopSfmStageTicker();
    final recon = _sfmRecon;
    final feedSub = _sfmFeedSub;
    final eventSub = _sfmEventSub;
    final failureSub = _highResFailureSub;
    _sfmRecon = null;
    _sfmFeedSub = null;
    _sfmEventSub = null;
    _highResFailureSub = null;
    await feedSub?.cancel();
    await eventSub?.cancel();
    await failureSub?.cancel();
    if (recon != null) await recon.dispose();
  }

  Future<void> _onSfmPreviewDone() async {
    if (_sfmPhase != SfmPreviewPhase.refined &&
        _sfmPhase != SfmPreviewPhase.error) {
      return;
    }
    await _routeReleaseGate.release(
      releaseResources: _releaseLiveReconstructionResources,
      revealRoot: () {
        if (!mounted) return;
        setState(() {
          _sfmPhase = null;
          _sfmLiveSnapshot = null;
          _sfmPerspectiveStart = null;
          _showDraftsWhileReconstructing = false;
        });
        if (_sfmPendingPop) {
          _sfmPendingPop = false;
          Navigator.of(context).pop(true);
        }
      },
    );
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
    final dir = _pageCaptureDir;
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
    final dir = _pageCaptureDir;
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
    final dir = _pageCaptureDir;
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
    final dir = _pageCaptureDir;
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
    final dir = _pageCaptureDir;
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
    if (widget.reviewCaptureDir != null) {
      Navigator.of(context).pop();
      return;
    }
    _showDraftsDuringReconstruction();
  }

  Future<void> _permanentlyDeleteActiveReconstruction(ScanRecord record) async {
    if (!recordOwnsActiveReconstruction(
      recordCaptureDir: record.captureDir,
      recordPipelineKind: record.pipelineKind,
      activeCaptureDir: _pageCaptureDir,
      activePipelineKind: CapturePipelineKind.official,
    )) {
      return;
    }
    final released = await _routeReleaseGate.release(
      releaseResources: () async {
        await _releaseLiveReconstructionResources();
        await _coverageFeedSub?.cancel();
        _coverageFeedSub = null;
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
      // [2026-09-11 用户令] 终态照常 pop 回**真**作品页 —— 用户要删掉的那个
      // "整屏刷新"是这条 route 的 pop **转场动画**,不是 pop 本身。转场已在
      // 推入处按 `reverseTransitionDuration: Duration.zero` 关掉(app_shell.dart),
      // 所以这里 pop 是零帧的:底下露出来的就是真作品页,卡片当场已是"已完成"
      // (badgeOf 只看 PLY 在不在盘上,PLY 在终态前就落了)。
      //
      // 🔴 build 142 曾改成"不 pop、页面钉在原地",代价是把采集 route 里那张
      // **临时**作品页变成常驻页 —— 它穿的是早已退役的 MeRootPage 那套壳
      // (右下角 "+" FAB、没有底部导航栏),用户一眼认出"这 UI 不是早删了吗"。
      // 连带三个缺陷:刚拍完那张卡点不动、拍摄按钮死键、没有返回图标出不去。
      // 不要再走回那条路。
      _triggerCompletionHaptic();
      _sfmPendingPop = true;
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
    captureReady: _sfmCaptureReady,
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
    if (!_autoCapture.isRunning) return;
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
    // [2026-09-07 未命名(22)] 遥测的不变量校验(开火必须带角色)抛过 35 次
    // 未捕获异常,把这一拍之后的统计/界面刷新全吞掉。遥测失败只记日志,
    // 绝不打断快门链;不变量本身由 governor 的契约测试守。
    try {
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
        trackCommonFraction:
            _autoCapture.lastTrackEvidence?.commonTrackFraction,
        trackMedianNormalizedDisplacement:
            _autoCapture.lastTrackEvidence?.medianNormalizedDisplacement,
        trackMedianStepPixelDisplacement:
            _autoCapture.lastTrackEvidence?.medianStepPixelDisplacement,
        segmentMotionPx: _autoCapture.lastSegmentMotionPx,
        segmentMotionThresholdPx: _autoCapture.segmentMotionThresholdPx,
        visualSourceAgeSec: _autoCapture.lastVisualSourceAgeSec,
        placeSignatureCount:
            _autoCapture.lastPlaceRecognitionScan?.signatureCount,
        placeWordCount: _autoCapture.lastPlaceRecognitionScan?.wordCount,
        placeDescribeMicros:
            _autoCapture.lastPlaceRecognitionScan?.describeMicros,
        placeQueryMicros: _autoCapture.lastPlaceRecognitionScan?.queryMicros,
        placeBestSharedWords:
            _autoCapture.lastPlaceRecognitionScan?.bestSharedWords,
        placeBestReferenceWords:
            _autoCapture.lastPlaceRecognitionScan?.bestReferenceWords,
        placePosteriorPermille: _autoCapture.lastLoopHypothesis == null
            ? null
            : (_autoCapture.lastLoopHypothesis!.bestPosterior * 1000).round(),
        placeLoopClosure: _autoCapture.lastLoopHypothesis?.isLoopClosure,
              evidenceSource: _autoCapture?.lastEvidenceSource,
        mapNumTrackedLms: _autoCapture?.lastMapEvidence?.numTrackedLms,
        mapNumReliableLms: _autoCapture?.lastMapEvidence?.numReliableLms,
        mapNumReliableLmsRef: _autoCapture?.lastMapEvidence?.numReliableLmsRef,
        mapLocalKeyframeCount:
            _autoCapture?.lastMapEvidence?.localKeyframeCount,
        mapLocalLandmarkCount:
            _autoCapture?.lastMapEvidence?.localLandmarkCount,
      );
      // 开火成因(VINS-Fusion 新旧比 vs AliceVision 流量段):一枪一账,
      // 只在成功开火后 controller 才留快照,读一次即清。
    } catch (e, st) {
      DeviceLog.log('OfficialARCapturePage', 'auto telemetry failed: $e\n$st');
    }
    final fireReason = _autoCapture.takeFireReason();
    if (fireReason != null) {
      _autoTelemetry.recordFireReason(
        segmentReady: fireReason.segmentReady,
        newFeatureBurst: fireReason.newFeatureBurst,
      );
    }
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
    //   ① 开火 ≠ 拍成(spec §7,遥测层正是为此把 fire_enqueued /
    //      fire_enqueue_failed 分开记);拿 fire 当"落帧"会在入队失败时
    //      给用户一个**假的正反馈** —— 红键脉冲一下、N/300 一动不动,
    //      而自动模式下那颗红键的脉冲是"到底拍上没有"的唯一反馈。
    //   ② `fired == true` 会跳过这条短路。入队持续失败时(SfM 内部故障)
    //      判定会连着好几帧是 fire,于是这个 4800 行的页面被每帧重建一次
    //      —— 正是这段注释自己要避免的那个热源。
    final landed = _autoFirePulseToken != pulseBefore;
    final promptSlowDown = _autoCapture.shouldPromptSlowDown;
    if (!landed &&
        decision == _lastAutoDecision &&
        running == _autoRunningLastSeen &&
        promptSlowDown == _autoPromptSlowDown) {
      // pose 流是 20–60 Hz。没有任何变化时不重建整页 —— 每帧 setState
      // 会把这个 4800 行的页面变成一个热源。
      return;
    }
    _lastAutoDecision = decision;
    _autoRunningLastSeen = running;
    _autoPromptSlowDown = promptSlowDown;
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
    _autoPromptSlowDown = false;
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
    _autoPromptSlowDown = false;
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

  /// 已经给过反馈的证据路径。早信号与完成路径都调 [_fireShutterFeedback],
  /// 由它保证**每张照片正好一次**震动 + 一个黑相框。
  final Set<String> _feedbackFiredEvidencePaths = <String>{};

  /// 原生 → Dart 的反向调用。目前只有一件事:`highResFrameCaptured`。
  ///
  /// **三端一致的规矩(各端官方文档,措辞几乎一样)**:反馈发在平台报告
  /// 「这一张已经拍下」的那一刻,绝不等我们自己的编码/落盘:
  ///   iOS       `AVCapturePhotoCaptureDelegate.photoOutput(_:willCapturePhotoFor:)`
  ///   Android   CameraX `ImageCapture.OnImageCapturedCallback.onCaptureStarted`
  ///             (底层 Camera2 `CameraCaptureSession.CaptureCallback.onCaptureStarted`)
  ///   HarmonyOS `photoOutput.on('captureStartWithInfo')`
  /// 策略(这个方法)三端共用;各端适配层只负责在自己那个回调上发事件。
  /// iOS 走 ARKit `captureHighResolutionFrame`,它没有 willCapture 那种更早的
  /// 挂点,所以本端绑在 ARFrame 到手那一刻 —— 是本端能拿到的最早且诚实的信号。
  Future<dynamic> _handleNativeCall(MethodCall call) async {
    if (call.method != 'highResFrameCaptured') return null;
    final args = call.arguments;
    if (args is! Map) return null;
    final evidence = args['evidenceJpegPath'] as String?;
    final preview = args['previewJpegPath'] as String?;
    if (evidence == null || preview == null) return null;
    _fireShutterFeedback(
      evidenceJpegPath: evidence,
      previewJpegPath: preview,
      source: 'captured_signal',
    );
    return null;
  }

  /// 震动 + 黑相框,**中间不隔任何 await**(用户底线:「拍照和给反馈必须同时
  /// 发生」)。按证据路径去重,所以早信号与完成路径的兜底加起来仍是每张一次。
  ///
  /// 诚实性:只在照片**物理上已经存在**之后调 —— 早信号是 ARFrame 到手,
  /// 兜底是事务返回。绝不在受理时刻调(2026-09-01「震了 30+ 次、相册只有
  /// 20 张」就是发在受理时刻)。此后若校验/落盘失败,`_markPhotoCardFailed`
  /// 会 removePhotoCard 并提示,把这一张撤掉。
  void _fireShutterFeedback({
    required String evidenceJpegPath,
    required String previewJpegPath,
    required String source,
  }) {
    if (!mounted) return;
    if (_failedEvidenceJpegPaths.contains(evidenceJpegPath)) return;
    if (!_feedbackFiredEvidencePaths.add(evidenceJpegPath)) return;
    _triggerShutterHaptic();
    // [2026-09-11 用户令]「在 native addPhotoCard 真正把相框挂进场景的那一刻
    // 补一条埋点」。这里把**震动这一刻**的墙钟交给 native,让它在卡片节点
    // 进场景那一行相减 —— 用户在意的就是这一段(震了→相框出现),而此前
    // 唯一能拿来估它的 `card` 埋点记的是相框**变色**,不是相框出现。
    // 🔴 墙钟(millisecondsSinceEpoch),native 侧用 Date() 同域相减;
    // 不能用 CACurrentMediaTime 那种 mach 单调钟(08-30 时钟域定罪)。
    // 取值在震动之后、通道调用之前,中间没有 await —— 「震动与相框之间
    // 不得有 await」那条底线不变。
    final feedbackEpochMs = DateTime.now().millisecondsSinceEpoch;
    unawaited(
      _arKitChannel
          .invokeMethod<void>('addPhotoCard', <String, dynamic>{
            'textureJpegPath': previewJpegPath,
            'evidenceJpegPath': evidenceJpegPath,
            'shutterFeedbackEpochMs': feedbackEpochMs,
          })
          .catchError((Object e) {
            // ignore: avoid_print
            print('[OfficialARCapturePage] addPhotoCard failed: $e');
          }),
    );
    TelemetryWriter.instance.event('shutter_feedback', {
      'source': source,
      'jpeg': evidenceJpegPath.split('/').last,
    });
  }

  /// [2026-09-10 用户令] "在任务完成那一瞬间可以加一个强震动的效果。"
  ///
  /// 发在**终态这一刻**,不是发在作品页看到卡片变色那一刻 —— 终态之后本
  /// route 立刻 pop,嵌入的那份 MePage 根本不会再 build 一次,靠它的徽章
  /// 边沿触发就永远不响。(me_page 里那份边沿触发仍留着,它管的是另一条路:
  /// 断点续跑在**真**作品页上跑完的那一次。)
  void _triggerCompletionHaptic() {
    unawaited(
      HapticFeedback.heavyImpact().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        DeviceLog.log(
          'OfficialARCapturePage',
          'completion haptic failed: $error',
        );
      }),
    );
  }

  void _triggerShutterHaptic() {
    unawaited(
      HapticFeedback.heavyImpact().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        DeviceLog.log('OfficialARCapturePage', 'shutter haptic failed: $error');
      }),
    );
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
  bool _onAutoCaptureStartAnchor() {
    try {
      final enqueued = _enqueueShutterCapture(automaticSelection: true);
      _autoTelemetry.recordStartAnchorOutcome(enqueued: enqueued);
      if (enqueued) _autoFirePulseToken++;
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

  bool _onAutoCaptureFire() {
    try {
      final enqueued = _enqueueShutterCapture(automaticSelection: true);
      // spec §7「入队失败 ⇒ 基准帧不更新 + **记遥测**」。这里是全链路唯一
      // 拿得到真实入队结果的地方 —— 判定层只知道"开了一枪"。
      _autoTelemetry.recordFireOutcome(enqueued: enqueued);
      // spec §8「**落帧**时 → 指示器脉冲一次」。脉冲与 fire_enqueued 在
      // **同一处**记账,屏幕与遥测因此不可能说两套话
      //〔2026-08-19 评审改正:此前脉冲挂在 `decision == fire` 上,
      // 入队失败也照样脉冲〕。
      if (enqueued) _autoFirePulseToken++;
      return enqueued;
    } catch (e) {
      _autoTelemetry.recordFireOutcome(enqueued: false);
      DeviceLog.log('OfficialARCapturePage', 'auto capture enqueue failed: $e');
      return false;
    }
  }

  /// O(1) UI admission only. Camera, JPEG, disk, and SfM work are serialized
  /// by [_shutterQueue] after this callback has already returned.
  void _onShutterTap() {
    if (_admitShutterCapture() == _ShutterAdmission.budgetExhausted) {
      unawaited(_showMaximumPhotosDialog());
    }
  }

  /// 快门的**唯一**入队路径:手动 tap 与自动拍都走这里。
  ///
  /// 三道守卫与 300 张上限判据因此只有一份。给自动拍抄第二份守卫迟早会漏掉
  /// 其中一条 —— 尤其是 `_shutterQueue.accepting`,它只在收尾流程
  /// (freezeAndDrain / cancelPending)期间为 false,平时测不出来。
  _ShutterAdmission _admitShutterCapture({bool automaticSelection = false}) {
    if (_session == null || !_sfmCaptureReady || !_shutterQueue.accepting) {
      return _ShutterAdmission.blocked;
    }
    final ticket = _shutterQueue.enqueue(
      verifiedCount: _projectPhotos.count,
      automaticSelection: automaticSelection,
    );
    if (ticket == null) return _ShutterAdmission.budgetExhausted;
    // 震动**不在这里**发。这里只是「受理」——照片还没拍,后面可能失败、可能被
    // 判为重复。2026-09-01 之前震动发在这一行,于是用户数到 30+ 次震动而相册
    // 只有 20 张(全历史 captureFailed 22 次 + 重复毁片 80 次,每一次都白震过)。
    //
    // 现在震动挪到 _executeShutterTicket 里挂 AR 相框的同一处:震一次 = 真有
    // 一张照片,而且震动与相框同时出现(用户底线:「拍照和给反馈必须同时发生」)。
    return _ShutterAdmission.admitted;
  }

  /// [_admitShutterCapture] 的布尔视图,给 [AutoCaptureController.onFire]。
  bool _enqueueShutterCapture({bool automaticSelection = false}) =>
      _admitShutterCapture(automaticSelection: automaticSelection) ==
      _ShutterAdmission.admitted;

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
    // ══ 反馈锚在「照片确认存在」那一刻 ══
    //
    // 时间线(build-76 实测 n=22):
    //   0ms     治理器判定开火
    //   +1ms    票据受理            ← 照片还不存在
    //   +255ms  原生 12MP 送达      ← 照片在这一刻才真正存在(物理地板,苹果的账)
    //   +304ms  事务完成(本行)     ← Dart 能拿到的最早诚实信号
    //
    // 震动与黑相框都放在这里,中间不隔任何 await —— 用户底线「拍照和给反馈必须
    // 同时发生」,且「照片都不知道有没有,那干嘛震动」。
    //
    // 为什么不是 +255ms:那需要原生多发一个「已送达」信号,属于苹果侧改动。
    // 项目规矩是能用 Dart 就用 Dart、跨端优先,而 49ms 感知不出来。
    //
    // 2026-09-01 教训:此前把两者前移到受理时刻(build 79),相框确实瞬时了,
    // 但震动又跑到照片存在之前 —— 那正是用户半个月前抓到的「震了 30+ 次、
    // 相册只有 20 张」。已撤回。
    final input = await capture.highResolutionCompletion;
    // [2026-09-06 抄对①] 照片真正拍成:把自动拍的基准/流量起点对齐到实拍
    // 瞬间(ARFrame 时间线 captureTimestamp),而不是快门请求时刻。
    _autoCapture.onCaptureCompleted(
      captureTimestampSec: input.captureTimestamp,
    );
    // 兜底:正常情况下反馈已由原生的「已经拍下」信号发过了(去重会挡在这里)。
    // 只有那个信号没到(通道异常等)才在这里补,保证不会有照片没反馈。
    _fireShutterFeedback(
      evidenceJpegPath: capture.evidenceJpegPath,
      previewJpegPath: capture.previewJpegPath,
      source: 'transaction_complete_fallback',
    );
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
  }

  void _onShutterTicketError(
    ManualCaptureTicket ticket,
    Object error,
    StackTrace stackTrace,
  ) {
    DeviceLog.log(
      'OfficialARCapturePage',
      'shutter ticket=${ticket.id} FAILED: $error\n$stackTrace',
    );
    _autoCapture.onCaptureFailed();
    TelemetryWriter.instance.event('shutter_error', {
      'ticket_id': ticket.id,
      'tap_timestamp_us': ticket.tapTimestampMicros,
      'error': '$error',
    });
    if (_finishTapInProgress) {
      _finishDrainFailed = true;
      _shutterQueue.cancelPending();
    }
    if (!mounted || _discardingCapture) return;
    setState(() {
      _captureQueueFailureText =
          '有一张高分辨率照片未完成（任务 ${ticket.id}）。'
          '已继续处理后续拍摄；你可以继续拍摄或退出重试。';
    });
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
    if (!_sfmCaptureReady ||
        _finalizingRecording ||
        _finishTapInProgress ||
        _closeTapInProgress ||
        _discardingCapture) {
      return;
    }
    _finishCancellationRequested = false;
    _finishDrainFailed = false;
    // 收尾第一件事就是停自动拍:下面 freezeAndDrain 之后队列不再收人,
    // 自动拍会每个 tick 撞一次关着的门(还撞不出任何反馈)。
    _stopAutoCapture();

    // [pw] 2026-08-24 真机报的 bug:点完成之后**还在继续拍**。
    //
    // 用户的观察字面上就是对的 —— 它确实还在拍,不是"在处理已拍的照片"。
    // 队列的入队方法只是排一张**票**,真正的 12MP 拍照发生在
    // `_pump()` 里(见 manual_capture_queue.dart)。所以 pending 的票
    // = **还没拍、但排着队要拍的照片**,
    // 而 `freezeAndDrain()` 会把它们**全部拍完**才返回。
    //
    // 为什么手动模式完全没有这个现象:手动是点一下拍一张,点完成时
    // `outstandingCount == 0`,`freezeAndDrain` 那句
    // `if (outstandingCount == 0) return Future.value();` 直接命中 ⇒ 秒结束。
    // 自动是 1 秒 1 张压着,而 pump 是串行的(`await _execute(ticket)`),
    // 单张只要慢过 1 秒队列就一直涨 ⇒ 点完成后要把那一摞全拍完。
    //
    // 丢掉未拍的票**不违反无损铁律**:无损管的是**已采集的数据**,而这些票
    // 一张照片都还没拍。用户按了结束还补拍,那不是无损,是没听指令。
    // 屏幕上的 N/300 读的是 `_projectPhotos.count`(已落盘张数),不含
    // outstanding ⇒ 计数不会倒退。
    //
    // `cancelPending() + freezeAndDrain()` 是本文件既有的「立即停」惯用法
    // (放弃拍摄那条路就是这么写的);而"保存并退出"那条刻意不 cancel,
    // 注释写着「无损:先把在途快门全部落地」—— 两者语义本来就该不同,
    // 完成键此前错用了后者。
    //
    // 在飞的那一张仍然等它落地(cancelPending 只清 _pending,不动 _active)。
    final cancelledTickets = _shutterQueue.pendingCount;
    _shutterQueue.cancelPending();
    if (cancelledTickets > 0) {
      // 丢了多少必须可见 —— 静默丢弃就又是一个静默失效。
      TelemetryWriter.instance.event('finish_cancel_pending', <String, Object>{
        'cancelled_tickets': cancelledTickets,
        'mode': _captureMode.name,
      });
      DeviceLog.log(
        'OfficialARCapturePage',
        'finish: 丢弃 $cancelledTickets 张未拍的排队票(模式 ${_captureMode.name})',
      );
    }
    setState(() => _finishTapInProgress = true);
    try {
      // 只等**在飞的那一张** —— 未拍的排队票在「完成」键那里已经
      // cancelPending() 掉了(见 finish_cancel_pending 遥测)。
      await _shutterQueue.freezeAndDrain();
      // 🔴 [2026-09-14 用户令]「摄像头一关,AR 算法强制停止」——
      // 手机烫,能结束的算法就得立刻结束,不许在后台空转。
      //
      // 这一行**从落盘屏障之后提到这里**。此刻在飞的最后一张 12MP 已经
      // 落地(上面那行等的就是它),相机再没有任何待交付的东西 ⇒ 可以停。
      //
      // 为什么不会丢帧(查过原生,不是推测):高清静照的 completion 里
      // `jpegEncodeQueue.async { ... pixelBuffer ... }` **闭包持有那个
      // CVPixelBuffer**(CF 类型,ARC 保留),编码与落盘跑在自己的队列上,
      // 与 ARSession 生死无关。下面的 waitForPendingPhotoSaves() 等的是
      // 那条队列,纯 CPU + 磁盘,不需要相机、不需要 VIO。
      //
      // stopSession() 停掉的是一整套热源(OfficialAetherARKitPlugin.swift):
      //   PwVioTimebase.suspendShadowPipeline() —— 影子 VIO 停
      //   arSession.pause()                      —— 4K 取景 + VIO + ARFrame 缓冲停
      //   PwARCameraLease.release()              —— 相机租约还回去
      //   aether_gpu_match_set_capture_active(0) —— 匹配器退出"拍摄期"降速档
      // 此前它排在所有 JPEG 编码之后:自动模式一场二十几张 12MP,那是好几秒
      // 的相机 + VIO 空转,正是"手机这么烫"的一部分。
      await _stopArSessionNow();
      if (!mounted ||
          _finishCancellationRequested ||
          _finishDrainFailed ||
          _discardingCapture ||
          !_recording) {
        return;
      }
      final acceptedFrameCount = _projectPhotos.count;
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
      if (mounted &&
          _recording &&
          !_discardingCapture &&
          !_cameraResumeFailed) {
        _shutterQueue.resume();
      }
      _finishCancellationRequested = false;
      if (mounted) setState(() => _finishTapInProgress = false);
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
    final session = _session;
    if (session == null || !_sfmCaptureReady) return;
    if (_finalizingRecording) return;
    _finalizingRecording = true;
    _stopAutoCapture();
    _stopGuidanceTelemetry(); // 拍摄结束,【guidance】采样停止
    // 🔴 [2026-09-14 用户令]「点完成拍摄的蓝色按键,摄像头必须立刻关闭,进入
    // 黑色背景的等待页面」。用户实机指认:**自动快门模式下没做到**。
    //
    // 两条快门路径走的是**同一个** _finalizeRecording,一行 mode 分支都没有 ——
    // 差别是**时延**:下面第一件事 `freezeAndDrain()` 要等**所有在飞的快门票
    // 拍完**(manual_capture_queue.dart:89-96,它等的是 outstandingCount 归零,
    // 不是丢弃),随后还有 waitForPendingPhotoSaves()。手动模式按完成时在飞
    // 通常 0–1 张,看着就是"立刻";自动模式一秒一张,在飞好几张 ⇒ 相机要多亮
    // 好几秒。此前那次「相机立刻关」的修正管的是**相对 finalize 的顺序**
    // (见下面 stopSession 处的注释),从来没有覆盖这段排空。
    //
    // 修法:**先盖页,再拆**。盖的就是 SfmPreviewOverlay(Stack 最顶层、
    // 整屏、owns navigation —— 见 230eecf)。底下的拆除顺序**一个字节不动**:
    // 在飞的 12MP 必须拍完才停 ARSession,否则就是永久缺帧(铁律)。
    // 不重建的那两条分支会把它清回 null(见下面两处 `_sfmPhase = null`),
    // 免得 _exitToDrafts 把 pop 永远挂起。
    if (mounted) {
      setState(() {
        _sfmPhase = SfmPreviewPhase.generating;
        _sfmFinalizeStage = 0;
        _sfmStageStartMs = DateTime.now().millisecondsSinceEpoch;
        // [LIVE-WAIT 2026-09-15] "关灯了,点云还在原地": the last streaming
        // cloud (ARKit world, all-white) is on screen from this very frame.
        final live = _liveCloudXyz;
        _sfmLiveSnapshot = live == null ? null : _whiteSnapshot(live);
        _sfmPerspectiveStart = live == null ? null : _perspectiveStartAtTap(live);
      });
      // The wait starts now (shutter drain + saves + finalize + colour).
      final reconAtTap = _sfmRecon;
      if (reconAtTap != null) {
        unawaited(
          _beginSparseEta(
            recon: reconAtTap,
            drainUnits: math.max(0, _projectPhotos.count - reconAtTap.fedCount),
            frames: _projectPhotos.count,
          ),
        );
      }
    }
    try {
      await _shutterQueue.freezeAndDrain();
      // 🔴 [2026-09-14 用户令]「摄像头一关,AR 算法强制停止」。
      // 在飞的最后一张 12MP 已经落地(上一行等的就是它)⇒ 相机再没有待交付
      // 的东西,立刻停。幂等:完成键那条路已经先停过一次,这里覆盖其余入口。
      // 安全依据见 [_stopArSessionNow] 的注释(编码队列持有 pixelBuffer,
      // 落盘与 ARSession 生死无关)。
      await _stopArSessionNow();
      // RECORDING → STOP. The high-res stills are written incrementally
      // under `<captureDir>/photos_highres/`; stop freezes curation and
      // writes the shared photo_bundle contract.
      await session.stop();
      await _stopVioShadowForCapture();
      // T6: tear down the live sparse cloud when the take ends.
      try {
        await _arKitChannel.invokeMethod<void>(
          'setFeaturePointsVisible',
          <String, dynamic>{'visible': false},
        );
      } catch (_) {}
      if (mounted) {
        setState(() {
          _recording = false;
          _isAiming = false;
          _lockInProgress = false;
        });
      }
      await session.waitForPendingPhotoSaves();
      await _highResFailureSub?.cancel();
      _highResFailureSub = null;
      // Capture is over — STOP THE CAMERA NOW, before the minutes-scale SfM
      // finalize. All keyframes are fed and every high-res still is on disk
      // (the barrier above guarantees it), so the ARSession (4K camera
      // capture + VIO + buffered ARFrames + ARSCNView GPU work) is pure
      // overhead from here — and it was competing with the finalize for
      // memory/GPU/thermal (mem ~950 MB, thermal=serious during solve).
      // pause() + clearing recentFrameSnapshots frees it all for CPU+GPU SfM.
      // 相机已在排空后立刻停过(见上面的 _stopArSessionNow)。这里保留一次
      // 幂等复核 —— 停两次是安全的(pause 幂等),而漏停一次就是几秒空转。
      await _stopArSessionNow();
      final recon = _sfmRecon;
      if (_projectPhotos.count == 0) {
        if (recon != null) {
          _sfmRecon = null;
          await _sfmFeedSub?.cancel();
          _sfmFeedSub = null;
          await _sfmEventSub?.cancel();
          _sfmEventSub = null;
          unawaited(recon.dispose());
        }
        // 零张照片 ⇒ 不重建,把开头盖上的等待页收回(同下面那条分支的理由)。
        if (mounted) setState(() => _sfmPhase = null);
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

      // Keep the post-capture waiting page alive until the authoritative final
      // sparse cloud lands. SfM remains asynchronous: the worker drains every
      // offered frame while this page merely renders queue progress, then runs
      // spatial loop matching + full finalize. We deliberately retain the event
      // subscription and session ownership here; detaching them would make the
      // page exit straight to Drafts and hide the queue/final result.
      final sfmPreviewing = recon != null && recon.offeredCount >= 2;
      final captureDirForSfm = session.captureDir;
      // [2026-09-11 用户裁决] 补拍**不交付这一场自己的云**。
      //
      // 定罪(未命名(8),26 张里 20 张颗粒无收):补拍只把老照片 adopt 进相册
      // (_adoptExistingProjectPhotos 只动 _projectPhotos),一帧都没喂给重建;
      // 而拍摄结束的 finalize 走的是 phase1=live_reuse —— 吃的是**本会话内存里**
      // 那个重建,里面只有新拍的几张。于是 n_registered=6、4538 点,而第一次拍摄
      // 当时屏幕上是 12808 点 / 14 帧。
      //
      // 改法:补拍结束后对**整个项目**全量重喂(rebuildFromArchivedPhotos),
      // 老照片 + 新照片一起进同一次重建 —— 这也正是 RealityScan 的做法
      // (新照片进同一个工程,整体按图像重新对齐),不是自创。
      //
      // 代价说清楚:新照片的特征会被提取两次(直播一次、重喂一次)。没有省掉
      // 它的干净办法 —— 直播会话的帧号从 0 重数,和老照片在同一个 db 里必然
      // 撞 `images.name`(所以开场才要 sideline)。正确性优先于这一次提取。
      final extendingProject =
          widget.extendCaptureDir != null && captureDirForSfm != null;
      DeviceLog.log(
        'OfficialARCapturePage',
        'finish: sfm fed=${recon?.fedCount ?? -1} '
            'remaining=${recon?.remainingCount ?? -1} preview=$sfmPreviewing',
      );
      if (extendingProject) {
        // [2026-09-11 用户裁决] 补拍收尾**走与正常拍摄结束完全同一条流程**。
        //
        // 上一版做成「弹回作品页 + 后台重喂」,用户点草稿卡进的是
        // SfmResumeWaitPage 那张单独的黑页 —— 那是「开始训练」的 UI,不是收尾的。
        // 用户指认后改成这样:重喂就在**本页**跑、用**本页自己的** SfmLiveRecon,
        // 于是浮层/事件/取色/持久化/「完成」按钮全部沿用原路,一行 UI 都不另写。
        //
        // 为什么仍要重喂而不是直接 finalize 本场:补拍只把老照片 adopt 进相册,
        // 一帧都没喂给重建;直接 finalize 交付的云只有新照片(未命名(8) 26 张
        // 里 20 张颗粒无收)。整项目重喂才是 RS 的做法。
        // 为什么不把老照片追加喂进**本场会话**:喂帧顺序要按帧序号升序,
        // 老照片排在新照片之后会让时序候选窗(k_neighbors)挑错邻居。
        await _sfmFeedSub?.cancel();
        _sfmFeedSub = null;
        await _sfmEventSub?.cancel();
        _sfmEventSub = null;
        _sfmRecon = null;
        final liveFed = recon?.fedCount ?? 0;
        if (recon != null) await recon.dispose();
        await _startArchivedRefeed(captureDirForSfm, liveFedCount: liveFed);
      } else if (sfmPreviewing) {
        await _sfmFeedSub?.cancel();
        _sfmFeedSub = null;
        if (mounted) {
          setState(() {
            _sfmFed = recon.fedCount;
            _sfmQueued = recon.remainingCount;
            _sfmSnapshot = null;
            _colorizeTarget = null;
            _pendingLocalColored = null;
            _sfmErrorText = null;
            _sfmPhase = SfmPreviewPhase.generating;
            _showDraftsWhileReconstructing = false;
            // 修1:队列已空则立即进入阶段 1;否则等 FrameFed 排空时进。
            _sfmFinalizeStage = recon.remainingCount == 0 ? 1 : 0;
            _sfmStageStartMs = DateTime.now().millisecondsSinceEpoch;
          });
          _startSfmStageTicker();
        }
        if (captureDirForSfm != null) {
          await _beginReconUmbrella(captureDirForSfm);
        }
        recon.finalize();
      } else if (recon != null) {
        _sfmRecon = null;
        await _sfmFeedSub?.cancel();
        _sfmFeedSub = null;
        await _sfmEventSub?.cancel();
        _sfmEventSub = null;
        unawaited(recon.dispose());
        // 这条路不重建 ⇒ 把开头盖上的等待页收回,否则 _exitToDrafts 会看到
        // _sfmPhase != null 而把 pop 永远挂起(那张页没有「完成」按钮可点)。
        if (mounted) setState(() => _sfmPhase = null);
      }
      // Every verified 12MP shutter is a project photo. Upload curation may
      // choose a subset for a later stage, but it must never delete photos from
      // the user-visible album or change its one authoritative count.
      await _persistDraft(showSnackBar: mounted && showSparseHint);
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

  /// 立刻停掉 ARSession(相机 + VIO + 影子管线 + 匹配器拍摄档)。
  /// 幂等:`arSession.pause()` 可以重复调用。
  bool _arSessionStopped = false;
  Future<void> _stopArSessionNow() async {
    if (_arSessionStopped) return;
    try {
      await _arKitChannel.invokeMethod<void>('stopSession');
      _arSessionStopped = true;
      DeviceLog.log(
        'OfficialARCapturePage',
        'finish: ARSession stopped (camera off, VIO off) —— 紧跟在飞快门落地之后',
      );
    } catch (_) {}
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

  /// 盘上实际的 JPEG 张数。补拍复用目录,本次会话的计数器只认自己拍的那些,
  /// 拿它当项目张数会少算掉上一次的。列不动时退回调用方给的值(诚实降级,
  /// 不静默记 0)。
  static Future<int> _photosOnDiskCount(
    Directory photosDir, {
    required int fallback,
  }) async {
    try {
      if (!await photosDir.exists()) return fallback;
      var n = 0;
      await for (final e in photosDir.list(followLinks: false)) {
        if (e is! File) continue;
        final path = e.path.toLowerCase();
        if (path.endsWith('.jpg') || path.endsWith('.jpeg')) n++;
      }
      return n > 0 ? n : fallback;
    } on FileSystemException {
      return fallback;
    }
  }

  Future<void> _persistDraft({required bool showSnackBar}) async {
    final session = _session;
    if (session == null) return;
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
    if (manifestFile == null || !manifestFile.existsSync()) return;
    // [2026-09-08 补拍] 补拍复用同一个 capture 目录 ⇒ captureId 相同 ⇒
    // addOrUpdate 覆盖原记录。此前无条件重取名字,用户看到的就是"原卡片没了、
    // 冒出一张未命名(N)" —— 项目的身份被一次补拍抹掉了。
    //
    // [用户裁决] **名字沿用,时间用新的**:名字是项目身份,补拍不该改;时间是
    // "最后动过它"的时刻,补了照片就该更新 —— 作品页按 createdAt 新→旧排序,
    // 刚补过的项目理应浮到最前面,而不是沉在原来的位置让用户找不着。
    final existing = store.records
        .where((r) => r.id == captureId)
        .cast<ScanRecord?>()
        .firstWhere((_) => true, orElse: () => null);
    final record = ScanRecord(
      id: captureId,
      name:
          existing?.name ??
          nextUntitledScanName(store.records.map((r) => r.name)),
      createdAt: createdAt,
      pipelineKind: CapturePipelineKind.official,
      preferredCaptureMode: CaptureMode.local,
      thumbnailPath: thumbnailPath,
      captureDir: captureDir.path,
      photosDir: photosDir.path,
      captureManifestPath: manifestFile.path,
      // 补拍时 _projectPhotos 只装本次会话的照片,直接写会把 30 张的项目
      // 记成 20 张 —— 卡片和张数闸都会读到假数。以盘上实际 JPEG 为准。
      photoCount: await _photosOnDiskCount(photosDir, fallback: photoCount),
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
    final recon = _sfmRecon;
    int? removedFrameId;
    if (recon != null) {
      for (final entry in recon.fedFrameMeta.entries) {
        if (entry.value.jpegPath == path) {
          removedFrameId = entry.key;
          break;
        }
      }
      final removed = await recon.removePhoto(path);
      if (!removed) {
        if (mounted) {
          ScaffoldMessenger.of(context)
            ..hideCurrentSnackBar()
            ..showSnackBar(
              const SnackBar(
                content: Text('照片暂时无法从重建中撤回，请稍后重试'),
                behavior: SnackBarBehavior.floating,
              ),
            );
        }
        return;
      }
    }
    _projectPhotos.remove(path);
    _photoCardStateSent.remove(path);
    _photoCaptureEpochMs.remove(path);
    _failedEvidenceJpegPaths.remove(path);
    if (removedFrameId != null) {
      _trueFrameParallaxDeg.remove(removedFrameId);
      _frameBelowEnterStreak.remove(removedFrameId);
    }
    final keep = _targetPoints.retainedJpegPaths.toSet()..remove(path);
    _targetPoints.retainOnlyJpegPaths(keep);
    unawaited(
      _arKitChannel
          .invokeMethod<void>('removePhotoCard', <String, dynamic>{
            'evidenceJpegPath': path,
          })
          .catchError((Object _) {}),
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
    await session?.stop();
    await shutterQueue.freezeAndDrain();
    shutterQueue.dispose();
    await session?.dispose();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _arKitChannel.setMethodCallHandler(null);
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
    // Streaming-SfM teardown: frees the native session (joins the background
    // BA thread, drops the sqlite db) off this isolate — page dispose never
    // blocks. Re-entering capture creates a fresh session + worker.
    _coverageFeedSub?.cancel();
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
    unawaited(_disposeCaptureResourcesAfterQueueDrain(shutterQueue, session));
    final sfmRecon = _sfmRecon;
    _sfmRecon = null;
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
    denseStageProgress.removeListener(_onDenseProgress);
    DenseWaitEta.instance.label.removeListener(_onDenseProgress);
    _denseLod?.removeListener(_onDenseLod);
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
    // [2026-09-10 用户令] **拍摄期取消右滑退出**:唯一的退出方式是左上角的
    // 返回图标。此前 canPop 只在重建期(_sfmPhase != null)为 false,拍摄期
    // 仍然放行 iOS 边缘右滑 —— 一次误触就把整条采集 route pop 掉。
    // 显式的 Navigator.pop(_exitToDrafts / _onSfmPreviewDone)**不受 canPop
    // 影响**,所以左上角返回照常工作,只是隐式手势不再能退出。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        // 重建期:把返回手势折叠成"显示草稿"(与等待页左上角返回同语义)。
        if (_sfmPhase != null) {
          if (!_showDraftsWhileReconstructing) {
            _showDraftsDuringReconstruction();
          }
          return;
        }
        // 拍摄期:什么都不做 —— 手势被吞掉,退出只能走左上角返回图标。
      },
      child: _buildRouteBody(context),
    );
  }

  Widget _buildRouteBody(BuildContext context) {
    _scheduleDraftTerminalExitIfNeeded();
    if (_showDraftsWhileReconstructing && _sfmPhase != null) {
      // 重建期临时给用户看的作品页。**裸 MePage,没有任何拍摄入口** ——
      // [2026-09-11 用户令]"直接删除这个 icon":那个右下角 "+" FAB 来自早已
      // 退役的 MeRootPage 的壳(DraftCaptureShell),真作品页用的是底部导航栏。
      // 重建期本来也不允许再起一次采集(原生 SfM 会话是进程唯一的),所以这里
      // 根本不该有拍摄按钮 —— 删掉它,连"当前任务正在重建"那句提示一起没了。
      // 回等待页看进度的入口在卡片上(onActiveReconstructionTap)。
      return MePage(
        activeReconstructionCaptureDir: _pageCaptureDir,
        activeReconstructionPipelineKind: CapturePipelineKind.official,
        onActiveReconstructionTap: _showReconstructionProgress,
        onActiveReconstructionDelete: _permanentlyDeleteActiveReconstruction,
        onRecordActionActivityChanged: _setDraftRecordActionInProgress,
        officialResumeRoute: pushOfficialResumeRoute,
        officialViewerRoute: pushOfficialViewerRoute,
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // Camera preview / init / error placeholder.
          Positioned.fill(child: _buildPreviewLayer()),

          // ─── Top bar: subtle route marker + X close button (right).
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
          if (_session != null && _sfmPhase == null)
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

          // A live-SfM worker is mandatory for this product route. Keep the
          // failure on screen (rather than a transient snackbar) and leave X
          // available so the user can discard the invalid take and retry.
          if (_sfmStartFailureText != null || _captureQueueFailureText != null)
            Positioned(
              top: 0,
              left: 16,
              right: 16,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(top: 66),
                  child: Container(
                    key: const ValueKey<String>(
                      'sfm-start-failure-banner-official',
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
                            _sfmStartFailureText ?? _captureQueueFailureText!,
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

          // ─── 补强1:"拍摄角度不足"实时横幅(真值 starved 口径)。
          // 非阻塞(IgnorePointer)、顶部第三档(60/104 已被硬拒/移速
          // toast 占用),不遮取景中心。可见性由 _starvedBannerGate 的
          // 去抖/滞回决定(tool/parallax_banner_check.dart 断言),采样
          // 挂在既有覆盖云/true-parallax 回调上,零新增计时器。
          if (_recording && _session != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(top: 148),
                  child: Center(
                    child: _ParallaxStarvedBanner(
                      visible: _starvedBannerVisible,
                    ),
                  ),
                ),
              ),
            ),

          // RealityScan-style unconnected-photo warning. The project ledger
          // owns the ratio, so pending analysis cannot masquerade as success
          // and no photo is removed merely because this banner is visible.
          if (_recording && _session != null)
            Positioned(
              top: 0,
              left: 18,
              right: 18,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(top: 192),
                  child: AnimatedBuilder(
                    animation: _projectPhotos,
                    builder: (context, _) => _DisconnectedPhotoBanner(
                      visible: _projectPhotos.shouldWarnDisconnected,
                      disconnected: _projectPhotos.disconnectedCount,
                      analyzed: _projectPhotos.analyzedCount,
                      onTap: _openAlbum,
                    ),
                  ),
                ),
              ),
            ),

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
          if (_session != null && _sfmPhase == null)
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
                              shouldPromptSlowDown: _autoPromptSlowDown,
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
                      ready: _sfmCaptureReady,
                      finishing: _finalizingRecording || _finishTapInProgress,
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
                      onFinish:
                          _sfmCaptureReady &&
                              !_finalizingRecording &&
                              !_finishTapInProgress
                          ? _onFinishTap
                          : null,
                    ),
                  ],
                ),
              ),
            ),

          // [spec §8.1] 切到自动模式时居中浮出的短提示(RS 的 "Auto Capture
          // On")。只在**用户主动切换**时出现 —— 进页面时的默认自动不算一次
          // 切换,那会变成每次进采集页都弹一下的噪音。
          if (_session != null && _sfmPhase == null)
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: _AutoCaptureOnToast(token: _autoModeToastToken),
                ),
              ),
            ),

          // [pw] 2026-08-24:这里曾经加过一个黑底转圈的「收尾遮罩」。**按同行调研撤掉了。**
          //
          // 调研五家(RealityScan / Polycam / Scaniverse / KIRI / Apple
          // ObjectCaptureSession)的结论:
          //   • 「点完成后弹一个黑底 spinner」**零家在做**,一份文档都没有;
          //   • Apple 自己的 GuidedCapture 示例在 `.finishing` 期间**保持相机
          //     视图**,直到 session 走到 `.completed` 才切重建页;
          //   • RealityScan 点「Next step」进的是**可交互的点云 Review 屏**,
          //     而且能「Take More Pictures」倒回去。
          //
          // 而遮罩存在的理由本来就是"drain 要花时间",那个理由已经被
          // `cancelPending()` 消掉了 —— 现在只等在飞的那一张,遮罩只会闪一下,
          // 闪一下的黑屏比不闪更难受。
          //
          // 真正对齐同行的方向是 RealityScan 那条:把上传/对齐前置到拍摄过程中
          // ("Images will start uploading the moment you begin capturing them"),
          // 结束时已经没有活要干,所以才能"点结束就真结束"。那是架构级改动。

          // ─── Post-capture final reconstruction (topmost). It owns navigation
          // until the queue drains and the final colored sparse cloud lands.
          if (_sfmPhase != null)
            SfmPreviewOverlay(
              phase: _sfmPhase!,
              snapshot:
                  _denseSnapshotFor(denseStageProgress.value) ??
                  _denseReviewSnapshot ??
                  _sfmSnapshot ??
                  _sfmLiveSnapshot,
              errorText: _sfmErrorText,
              denseRunning: _denseRunningHere,
              waitLabel: _denseRunningHere
                  ? _denseWaitLabel(context)
                  : _sparseWaitLabel(context),
              initialPerspective: _sfmPerspectiveStart,
              lodOctreeDir: _lodOctreeDirOnScreen,
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
              onBack: () => unawaited(_onSfmPreviewBack()),
              onDone: () => unawaited(_onSfmPreviewDone()),
              // [2026-07-31 用户签决] 底部"下一步" = 启动后续处理;进选区
              // 编辑归右上角那个可选入口。
              onNext:
                  !_denseRunningHere &&
                      !_denseDoneHere &&
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
                  !_denseRunningHere &&
                      !_denseDoneHere &&
                      _sfmSnapshot != null &&
                      _sfmSnapshot!.pointCount > 0
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

/// 补强1:"拍摄角度不足"实时横幅。样式与 [_HardRejectToast] 同款黑底
/// 圆角 pill(琥珀警示 icon 区分严重级),但生命周期不同:不自动淡出,
/// 可见性完全由页面状态 `_starvedBannerVisible`(StarvedParallaxBannerGate
/// 的去抖/滞回结论)驱动 —— 计数回落滞回线以下才隐藏。IgnorePointer
/// 保证永不挡快门/取景交互。
class _ParallaxStarvedBanner extends StatelessWidget {
  const _ParallaxStarvedBanner({required this.visible});
  final bool visible;

  @override
  Widget build(BuildContext context) {
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
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                color: Color(0xFFFFC53D),
                size: 18,
              ),
              SizedBox(width: 8),
              Text(
                '对黄色区域：横移一大步/蹲低举高，再拍一张',
                style: TextStyle(
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

class _DisconnectedPhotoBanner extends StatelessWidget {
  const _DisconnectedPhotoBanner({
    required this.visible,
    required this.disconnected,
    required this.analyzed,
    required this.onTap,
  });

  final bool visible;
  final int disconnected;
  final int analyzed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 250),
      child: IgnorePointer(
        ignoring: !visible,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: const Color(0xFFFF4D4F), width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: Color(0xFFFF5A5F),
                  size: 18,
                ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    '$disconnected/$analyzed 张照片未连接；'
                    '请在红色照片附近补拍连接画面',
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
