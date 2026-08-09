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
import 'package:vector_math/vector_math_64.dart' show Quaternion, Vector3;

import '../../point_cloud_display/progressive_octree_order.dart';
import '../../official_capture/capture_coverage_cloud.dart';
import '../../official_capture/capture_session.dart';
import '../../official_capture/colorize_pipeline.dart';
import '../../official_capture/live_sfm_publish_policy.dart';
import '../../official_capture/manual_capture_queue.dart';
import '../../official_capture/official_highres_reconstruction_input.dart';
import '../../official_capture/parallax_banner_gate.dart';
import '../../official_capture/photo_card_state.dart';
import '../../official_capture/project_photo_album.dart';
import '../../official_capture/pw_telemetry.dart';
import '../../official_capture/representative_color.dart';
import '../../official_capture/shutter_backpressure_gate.dart';
import '../../official_capture/sparse_ply.dart';
import '../../official_capture/telemetry_writer.dart';
import '../../official_capture/transient_preview_cleanup.dart';
import '../../official_capture/dome/dome_target_points.dart';
import '../../official_capture/realtime_capture_preview.dart';
import '../../official_capture/sfm_live_recon.dart';
import '../../official_dome/ar_pose.dart';
import '../../l10n/app_localizations.dart';
import '../../me/scan_record_store.dart';
import '../../official_quality/guidance_engine.dart' show GuidanceSnapshot;
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

  return Uint8List.fromList(img.encodeJpg(image, quality: 88));
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
      // [2026-08-09 用户签决,附截图] 黑白弹窗 + 滑轴:左=退出并保存照片,
      // 右=退出并不保存照片;第二行"继续拍摄";点弹窗外自动返回拍摄。
      final choice = await showCaptureExitDialog(context);
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
      _engineDraftCloud = null;
      _engineDraftLastBuildMs = 0;
      // Fresh take → 卡片边框状态机归零(native 卡片已由 clearPhotoCards
      // 清掉,这里清 Dart 侧差量缓存与连通性数据)。
      _photoCardStateSent.clear();
      _photoCaptureEpochMs.clear();
      _failedEvidenceJpegPaths.clear();
      _sfmLatestPoses = Float64List(0);
      _trueFrameParallaxDeg.clear();
      _frameBelowEnterStreak.clear();
      _trueParallaxComputeMs = -1;
      // 补强1:starved 横幅门与覆盖云同时机归零(下方 setState 会重建)。
      _starvedBannerGate.reset();
      _starvedBannerVisible = false;
      // force:新一轮拍摄的归零推送必须落到 native,不能被去重门挡掉。
      unawaited(_pushCoverageCloud(force: true));
      _coverageFeedSub ??= session.sfmFrameStream.listen(_onCoverageKeyframe);
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

  Future<void> _pushCoverageCloud({bool force = false}) async {
    // [ENGINE-DRAFT] 优先级:SfM 云(配对草稿/正式)> 引擎草稿 > 空。
    final packed =
        _officialSfmArCloud ??
        _engineDraftCloud ??
        CoverageCloudPacked(Float32List(0), Uint8List(0));
    if (!force && identical(packed, _pushedArCloud)) return;
    _pushedArCloud = packed;
    try {
      await _arKitChannel.invokeMethod<void>(
        'setCoveragePointCloud',
        <String, dynamic>{'xyz': packed.xyz, 'rgb': packed.rgb},
      );
    } catch (_) {
      // Display-only channel — never let it disturb capture. Forget the
      // payload so the next push retries instead of de-duplicating against a
      // send that never landed.
      _pushedArCloud = null;
    }
  }

  /// Atomically replaces the AR overlay with a globally refined official SfM
  /// snapshot. This is display-only: no point is removed or rewritten in the
  /// reconstruction or final PLY.
  Future<void> _publishOfficialSfmCloudToAr(SfmLiveSnapshot snapshot) async {
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
        if (_projectPhotos.count < 1) _engineDraftCloud = null;
        _engineDraftLastBuildMs = 0;
        await _pushCoverageCloud(force: true);
      }
      return;
    }
    // [2026-08-09 用户签决] 拍摄期 AR live 云**全白**,不再按质量分绿/黄/红。
    // 原先每个点按 track 长度过 kCaptureQualityRamp 上色(2=红 3=橙 4=黄绿
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
    if (!_recording) return;
    _officialSfmArCloud = CoverageCloudPacked(
      displayCloud.xyz,
      displayCloud.rgb,
    );
    await _pushCoverageCloud();
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
    setState(() {
      _sfmStarting = false;
      _sfmStartFailureText = '点云重建未能启动（$detail）。请退出后重试；此次拍摄不会保存。';
    });
  }

  /// Spawns the required streaming-SfM worker for this take and wires the
  /// keyframe feed. Startup is fail-closed: unsupported devices, missing
  /// capture storage, lease contention (reported as a null worker), and thrown
  /// errors all leave a persistent page error with capture/save disabled.
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

  void _onSfmEvent(SfmLiveEvent event) {
    if (!mounted) return;
    if (event is SfmLivePreview &&
        (event.snapshot.summary['source'] == 'streaming_global_ba' ||
            event.snapshot.summary['source'] == 'streaming_local_ba_live')) {
      // [AR-EVERY-FRAME 2026-08-04] 两种拍摄期流式 source 都路由到 AR overlay
      // 并 return:检查点的 'streaming_global_ba'(既有,~8次),以及每帧的
      // 'streaming_local_ba_live'(实验臂,默认关时永不发出)。**必须在此 return**,
      // 否则会落进下方 colorize 路径,而那里 'streaming_local_ba'(注意无 _live)
      // 被当作拍完的终态云会提前弹浮层。'_live' 后缀正是为避开该撞名。
      final snapshot = event.snapshot;
      if (snapshot.posesPacked.isNotEmpty) {
        _sfmLatestPoses = snapshot.posesPacked;
        _refreshPhotoCardStates();
      }
      unawaited(_publishOfficialSfmCloudToAr(snapshot));
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
        case SfmLiveFailed(:final stage, :final message):
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
    // 遥测【colorize】取色统计(归约处顺手算,几乎零成本):每点样本数
    // 直方图 [1,2,3-4,5-8,9+]、样本对代表色的均方差(混色嫌疑信号)。
    final obsHist = List<int>.filled(5, 0);
    final rmsList = <double>[];
    var rmsGt40 = 0;
    for (var i = 0; i < n; i++) {
      // 代表色归约:选亮度中位的真实观测样本,不合成新颜色。
      if (samples.selectInto(i, rgb)) {
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

  void _scheduleDraftTerminalExitIfNeeded() {
    final terminal =
        _sfmPhase == SfmPreviewPhase.refined ||
        _sfmPhase == SfmPreviewPhase.error;
    if (_draftTerminalExitScheduled ||
        !shouldAutoExitReconstructionDrafts(
          showingDrafts: _showDraftsWhileReconstructing,
          reconstructionTerminal: terminal,
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
      )) {
        return;
      }
      _sfmPendingPop = true;
      unawaited(_onSfmPreviewDone());
    });
  }

  /// O(1) UI admission only. Camera, JPEG, disk, and SfM work are serialized
  /// by [_shutterQueue] after this callback has already returned.
  void _onShutterTap() {
    if (_session == null || !_sfmCaptureReady || !_shutterQueue.accepting) {
      return;
    }
    final ticket = _shutterQueue.enqueue(verifiedCount: _projectPhotos.count);
    if (ticket == null) {
      unawaited(_showMaximumPhotosDialog());
    }
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
    final capture = await session.captureSinglePhoto();
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
      'verified_at_start': _projectPhotos.count,
      'outstanding_at_start': _shutterQueue.outstandingCount,
    });
    if (mounted &&
        !_failedEvidenceJpegPaths.contains(capture.evidenceJpegPath)) {
      unawaited(
        _arKitChannel
            .invokeMethod<void>('addPhotoCard', <String, dynamic>{
              'textureJpegPath': capture.previewJpegPath,
              'evidenceJpegPath': capture.evidenceJpegPath,
            })
            .catchError((Object e) {
              // ignore: avoid_print
              print('[OfficialARCapturePage] addPhotoCard failed: $e');
            }),
      );
    }
    final input = await capture.highResolutionCompletion;
    _recomputeShutterPace();
    TelemetryWriter.instance.event('shutter', {
      'ticket_id': ticket.id,
      'tap_timestamp_us': ticket.tapTimestampMicros,
      'queue_wait_us': queueWaitMicros,
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
    setState(() => _finishTapInProgress = true);
    try {
      await _shutterQueue.freezeAndDrain();
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
    _stopGuidanceTelemetry(); // 拍摄结束,【guidance】采样停止
    try {
      await _shutterQueue.freezeAndDrain();
      // RECORDING → STOP. The high-res stills are written incrementally
      // under `<captureDir>/photos_highres/`; stop freezes curation and
      // writes the shared photo_bundle contract.
      await session.stop();
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
      try {
        await _arKitChannel.invokeMethod<void>('stopSession');
        DeviceLog.log(
          'OfficialARCapturePage',
          'finish: ARSession stopped (camera off)',
        );
      } catch (_) {}
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
      DeviceLog.log(
        'OfficialARCapturePage',
        'finish: sfm fed=${recon?.fedCount ?? -1} '
            'remaining=${recon?.remainingCount ?? -1} preview=$sfmPreviewing',
      );
      if (sfmPreviewing) {
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
      canPop: _sfmPhase == null,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop || _sfmPhase == null) return;
        if (!_showDraftsWhileReconstructing) _showDraftsDuringReconstruction();
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
          initialShowDrafts: true,
          activeReconstructionCaptureDir: _session?.captureDir,
          activeReconstructionPipelineKind: CapturePipelineKind.official,
          onActiveReconstructionTap: _showReconstructionProgress,
          onActiveReconstructionDelete: _permanentlyDeleteActiveReconstruction,
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
                      onShutter: _onShutterTap,
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

          // ─── Post-capture final reconstruction (topmost). It owns navigation
          // until the queue drains and the final colored sparse cloud lands.
          if (_sfmPhase != null)
            SfmPreviewOverlay(
              phase: _sfmPhase!,
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
              onBack: () => unawaited(_onSfmPreviewBack()),
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
    required this.onShutter,
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
  final VoidCallback onShutter;
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
              SizedBox(
                width: 72,
                child: _AlbumThumbButton(
                  latestPath: latest,
                  count: projectPhotos.count,
                  processed: processedCount,
                  onTap: onOpenAlbum,
                ),
              ),
              Expanded(
                child: Center(
                  child: _ShutterButton(
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
                ),
              ),
              SizedBox(
                width: 72,
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
            borderRadius: BorderRadius.circular(14),
            // [RS-RING] 原 0.5α 静态白边即进度环的"轨道";实心白弧压其上。
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.5),
              width: 1.5,
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
      const Radius.circular(14),
    );
    final path = Path()..addRRect(rrect);
    final metric = path.computeMetrics().first;
    final total = metric.length;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round
      ..color = Colors.white;
    if (progress >= 1) {
      canvas.drawPath(path, paint);
      return;
    }
    // addRRect 的路径起点在左上圆角后的顶边起点;把起笔挪到顶边正中,
    // 环从 12 点方向顺时针生长(与 RS 一致)。
    final start = (size.width / 2 - 14).clamp(0.0, total);
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
      fontSize: 15,
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
    final bigSize = count >= 100 ? 19.0 : 22.0;
    final bigStyle = style.copyWith(fontSize: bigSize, height: 1.0);
    final smallStyle = style.copyWith(fontSize: 10, height: 1.0);
    final bigTp = TextPainter(
      text: TextSpan(text: '$count', style: bigStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    final smallTp = TextPainter(
      text: TextSpan(text: '$kOfficialMaximumCaptureFrames', style: smallStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    const slashLen = 24.0;
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth, h = c.maxHeight;
        // 分子锚在 (7,5),分母锚在 right:6/bottom:4(与 Positioned 一致)。
        final bigBR = Offset(7 + bigTp.width, 5 + bigTp.height);
        final smallTL = Offset(w - 6 - smallTp.width, h - 4 - smallTp.height);
        final mid = Offset(
          (bigBR.dx + smallTL.dx) / 2,
          (bigBR.dy + smallTL.dy) / 2,
        );
        return Stack(
          children: [
            Positioned(left: 7, top: 5, child: Text('$count', style: bigStyle)),
            // 斜杠:竖线顺时针转 45° = "/",中心 = 两数字近角连线中点。
            Positioned(
              left: mid.dx - 0.75,
              top: mid.dy - slashLen / 2,
              child: Transform.rotate(
                angle: math.pi / 4,
                child: Container(
                  width: 1.5,
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
              right: 6,
              bottom: 4,
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
