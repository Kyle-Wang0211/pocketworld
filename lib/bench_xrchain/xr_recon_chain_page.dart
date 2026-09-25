// xr_recon_chain_page.dart —— 台架「XRSLAM → SfM 重建链」页(只进台架 com.kyle.arloopbench,生产不编)。
//
// ══ 链路(用户 2026-09-25 拍板,逐条)═════════════════════════════════════════════
//   ① 实时预览:XRSLAM 前端对外输出(VioArPoseProvider / ZeroArkitCameraPreview,与零 ARKit 探针页同一套)。
//   ② 照片:零 ARKit 采集路线 PwCameraSlot(AVCapturePhotoOutput,.speed,不开 OIS)拍 4:3 静态照,尺寸 = 平台默认
//      (合并)模式下的最大 4:3(PwCameraSlot.start 里 requestLargestFourByThreePhoto;本测试机 4032×3024)。
//   ③ 照片位姿:拍照时刻之前最近一个后端帧的**定稿**状态,用引擎官方 propagate_state_okvis2 外推到拍照时刻
//      (规则全在跨端 C++ 核心 vendor/xrslam/chain/PwXrReconChainCore.cpp,宿主胶水 ios/Runner/PwXrReconChain.swift)。
//   ④ 喂 SfM:生产 SfmLiveRecon.offerFrame(= pwofficial_add_jpeg_frame_v2(..., device_pose_trusted)),
//      可信标志来自链路核心(等不到定稿 / 外推 > 上限 / 拍照时刻不是 TRACKING_SUCCESS ⇒ 0,走核里上游
//      RegisterNextImage 证据门);收尾时还没定稿的照片取收尾窗口状态;交付尺度沿用核内 DEVICE-ALIGN-V1(Sim3)。
//      核不改。位姿口径换算见 xrchain_pose_convention.dart(照抄 prep_inputs.py)。
//   ⑤ td:台架默认 Δ = −5 ms(新积分器下本机旋转抖动判据扫出的最优点),启动参数 -PWXrslamTdExtraMs 覆盖;
//      叠进建会话时的 c(视频帧与照片同一个数)。🔴 只是台架实验设置,不写进任何产品规则。
//   ⑥ LiDAR / ARKit 不进这条链的任何位姿或重建路径(本页根本不起 ARKit)。
//
// ══ 启动参数(xcrun devicectl … -- <args>)═══════════════════════════════════════
//   -PWBenchPage xrchain              直开本页
//   -PWXrslamTdExtraMs <ms>           Δ(默认 -5)
//   -PWXrchainFinalTimeoutMs <ms>     等定稿超时(默认 3000;依据见 PwXrReconChainCore.h R4 与交付报告)
//   -PWXrchainMaxExtrapolationMs <ms> 外推长度上限(默认 100,用户定)
//
// ══ 落盘(拉回 Mac 用)═════════════════════════════════════════════════════════════
//   Documents/xrchain_run_<yyyyMMdd_HHmmss>/
//     run_manifest.json        配置、c 与 Δ、计数、照片尺寸选择、链路核心计数、SfM 结果摘要
//     chain_photos.jsonl       每张照片:PTS / 曝光 / t_photo / 位姿来源 / 等待 / 外推 / 可信及原因 / XRSLAM 位姿 /
//                              喂核用的 ARKit 口径位姿 / 喂核结果
//     sfm_live.db + official_sfm_fed_frames.jsonl + sfm_match_fail.jsonl(核与生产门面自己写)
//     sfm_refined_poses.csv / sfm_refined_points.ply(finalize 之后)
//   照片 JPEG 与 sidecar 在 PwCameraSlot 的 Documents/pw_photos/<id>.jpg(路径写进 chain_photos.jsonl)。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pocketworld_flutter/official_aether_sfm_ffi.dart' show AetherEnvFile;
import 'package:pocketworld_flutter/official_capture/official_highres_reconstruction_input.dart';
import 'package:pocketworld_flutter/official_capture/sfm_live_recon.dart';
import 'package:pocketworld_flutter/official_util/device_log.dart';

import '../bench_unified/bench_unified_native.dart';
import '../official_dome/ar_pose.dart';
import '../vio/capture/camera_time_offset.dart';
import '../vio/capture/focus_self_heal.dart';
import '../vio/capture/zero_arkit_capture_runtime.dart';
import '../vio/ffi/pw_camera_photo_ffi.dart';
import '../vio/ffi/pw_focus_ffi.dart';
import '../vio/ffi/xrslam_live_ffi.dart' show XrslamLive;
import '../vio/pose/camera_projection.dart' show PinholeIntrinsics;
import '../vio/pose/camera_slot_ffi.dart' show PwCameraSlot;
import '../vio/pose/vio_ar_pose_provider.dart';
import '../vio/render/zero_arkit_camera_preview.dart';
import '../vio/render/zero_arkit_capture_probe_page.dart' show BenchZeroArkitPlatform, benchReadHwMachine;
import 'xrchain_native.dart';
import 'xrchain_pose_convention.dart';

const String kXrChainLogTag = '[xrchain]';
const String kXrChainManifestSchema = 'pw.bench.xr_recon_chain/1';

/// 台架默认 Δ(毫秒)。🔴 只是台架实验设置。
const double kXrChainDefaultTdExtraMs = -5;
const double kXrChainDefaultFinalTimeoutMs = 3000;
const double kXrChainDefaultMaxExtrapolationMs = 100;

/// 启动参数里取一个数;缺省 / 解析不了 ⇒ [fallback],并把来源如实带回。
({double value, String source}) xrChainNumberArg(Map<String, String> args, String key, double fallback) {
  final String? raw = args[key];
  if (raw == null || raw.trim().isEmpty) return (value: fallback, source: 'default');
  final double? v = double.tryParse(raw.trim());
  if (v == null || !v.isFinite) return (value: fallback, source: 'unparsable:$raw');
  return (value: v, source: 'launch_arg');
}

class XrReconChainPage extends StatefulWidget {
  const XrReconChainPage({super.key});

  @override
  State<XrReconChainPage> createState() => _XrReconChainPageState();
}

class _Shot {
  _Shot(this.id, this.requestedAtMs);
  final int id;
  final int requestedAtMs;
  int? captureRc;
  PwCapturedPhoto? photo;
  XrChainSubmit? submit;
  XrChainPhotoResult? result;
  String? fedResult;
  int? fedFrameId;
  String? focusPrepare;
  final Map<String, Object?> notes = <String, Object?>{};
}

class _XrReconChainPageState extends State<XrReconChainPage> {
  final BenchZeroArkitPlatform _platform = BenchZeroArkitPlatform();
  ZeroArkitCaptureRuntime? _runtime;
  VioArPoseProvider? _provider;
  StreamSubscription<ARPose>? _poseSub;
  SfmLiveRecon? _recon;
  StreamSubscription<SfmLiveEvent>? _reconSub;
  Timer? _pumpTimer;
  Directory? _runDir;
  IOSink? _photoLog;

  String _phase = '进页';
  String? _fatal;
  bool _running = false;
  bool _finishing = false;
  bool _finished = false;
  bool _shutterBusy = false;

  double _tdExtraMs = kXrChainDefaultTdExtraMs;
  double _timeoutMs = kXrChainDefaultFinalTimeoutMs;
  double _maxExtrapMs = kXrChainDefaultMaxExtrapolationMs;
  final Map<String, String> _argSources = <String, String>{};
  CameraTimeOffset? _cBase;
  CameraTimeOffset? _cApplied;
  String? _machine;
  List<String> _envApplied = <String>[];

  final List<_Shot> _shots = <_Shot>[];
  final Map<int, _Shot> _byId = <int, _Shot>{};
  /// 照片请求号。PwCameraSlot 按请求号落 Documents/pw_photos/{id}.jpg,每场从 1 起会覆盖上一场的照片 ⇒
  /// 基数取本页启动时的 epoch 秒 × 1000(每场唯一;≈1.8e12,在 double 精确整数范围内,链路结果摊平成 double 不丢位)。
  int _nextId = (DateTime.now().millisecondsSinceEpoch ~/ 1000) * 1000 + 1;
  int _poseFrames = 0;
  ARPose? _lastPose;
  PwFocusArm? _focusArm;
  FocusSelfHeal? _selfHeal;
  final Map<String, Object?> _sfmSummary = <String, Object?>{};
  final List<String> _sfmErrors = <String>[];
  Completer<SfmLiveRefined?>? _refined;
  String? _buildStamp;

  void _log(String s) {
    debugPrint('$kXrChainLogTag $s');
    DeviceLog.log('xrchain', s);
  }

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  Future<void> _boot() async {
    try {
      await DeviceLog.init();
      final Directory docs = await getApplicationDocumentsDirectory();
      final DateTime now = DateTime.now();
      String two(int v) => v.toString().padLeft(2, '0');
      final String stamp = '${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}';
      final Directory run = Directory('${docs.path}/xrchain_run_$stamp');
      await run.create(recursive: true);
      _runDir = run;
      _photoLog = File('${run.path}/chain_photos.jsonl').openWrite(mode: FileMode.append);

      // 启动参数(Δ / 超时 / 外推上限)。
      final Map<String, String> args = await BenchUnifiedNative.launchArgs();
      final td = xrChainNumberArg(args, 'PWXrslamTdExtraMs', kXrChainDefaultTdExtraMs);
      final to = xrChainNumberArg(args, 'PWXrchainFinalTimeoutMs', kXrChainDefaultFinalTimeoutMs);
      final mx = xrChainNumberArg(args, 'PWXrchainMaxExtrapolationMs', kXrChainDefaultMaxExtrapolationMs);
      _tdExtraMs = td.value;
      _timeoutMs = to.value;
      _maxExtrapMs = mx.value;
      _argSources
        ..['td_extra_ms'] = td.source
        ..['final_timeout_ms'] = to.source
        ..['max_extrapolation_ms'] = mx.source;

      // 核开关:生产 main() 的同一机制(Documents/official_env.json → setenv),必须在第一次用核之前。
      _envApplied = await AetherEnvFile.applyFrom(docs.path);

      // 机型 → c(camera_time_offset.dart 查表),再叠台架 Δ。
      _machine = benchReadHwMachine();
      final CameraTimeOffset c = resolveCameraTimeOffset(machine: _machine);
      _cBase = c;
      final CameraTimeOffset applied = CameraTimeOffset(
        seconds: c.seconds + _tdExtraMs / 1000.0,
        provenance: c.provenance,
        machine: c.machine,
        note: '${c.note};叠加台架 Δ=${_tdExtraMs.toStringAsFixed(2)} ms(${td.source},仅台架实验设置)',
      );
      _cApplied = applied;
      _log('run=${run.path} 机型=$_machine ${c.describe} Δ=${_tdExtraMs}ms(${td.source}) '
          '⇒ 交给传输层 ${(applied.seconds * 1000).toStringAsFixed(3)} ms;超时 ${_timeoutMs}ms(${to.source}) '
          '外推上限 ${_maxExtrapMs}ms(${mx.source});env=$_envApplied');

      // 对焦:与零 ARKit 探针页同一套(臂在起相机前读;自愈环判定四端同一份)。
      _focusArm = PwFocus.currentArm();
      _selfHeal = FocusSelfHeal(
        nudger: PwFocus.available
            ? const PwFocusFfiNudger()
            : const NoopFocusNudger('🔴 pw_camera_slot_focus_nudge 符号不在 ⇒ 只判不踢'),
      );

      final ZeroArkitCaptureRuntime runtime = ZeroArkitCaptureRuntime(
        platform: _platform,
        cameraTimeOffset: applied,
        machineIdentifier: _machine,
      );
      final VioArPoseProvider provider = VioArPoseProvider(runtime: runtime);
      _runtime = runtime;
      _provider = provider;

      if (!XrChainNative.available) throw StateError('pw_xrchain_* 符号不在(台架包没编进 PwXrReconChain.swift)');
      if (!PwCameraPhoto.available) throw StateError('pw_camera_slot_capture_photo 符号不在');

      // 相机先起(PwCameraSlot.start 里按规则预设照片尺寸),等第一帧内参。
      setState(() => _phase = '起相机');
      final int rc = _platform.startCamera(
        width: runtime.captureWidth,
        height: runtime.captureHeight,
        fps: runtime.fps,
        lensPosition: runtime.lensPosition,
      );
      _log('相机 rc=$rc 照片尺寸选择=${PwCameraSlot.lastPhotoDimsChoice}');
      if (rc != 0) throw StateError('相机起不来 rc=$rc');
      setState(() => _phase = '等第一帧内参');
      final Stopwatch sw = Stopwatch()..start();
      PinholeIntrinsics? k;
      while (mounted && sw.elapsed < const Duration(seconds: 5)) {
        k = _platform.intrinsics(imageWidth: runtime.captureWidth, imageHeight: runtime.captureHeight);
        if (k != null && k.isUsable) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      if (!mounted) return;

      // XRSLAM 会话(c + Δ 交给传输层)+ 前端位姿流(预览)。
      _poseSub = provider.start().listen(_onPose);
      final ZeroArkitStartResult? r = provider.runtimeStart;
      _buildStamp = XrslamLive.buildStamp();
      _log('会话 ok=${r?.ok} err=${r?.error} ${r?.cameraTimeOffset.describe} 引擎=$_buildStamp');
      if (r == null || !r.ok) throw StateError('XRSLAM 会话没起来:${r?.error}');

      // 链路核心:逐帧状态 + 50 ms 轮询。
      final int brc = XrChainNative.begin(
        timeoutSeconds: _timeoutMs / 1000.0,
        maxExtrapolationSeconds: _maxExtrapMs / 1000.0,
      );
      _log('链路核心 begin rc=$brc');

      // SfM:生产门面原样(worker isolate、磁盘队列、finalize、交付)。
      final SfmLiveRecon? recon = await SfmLiveRecon.start(dbPath: '${run.path}/sfm_live.db');
      if (recon == null) throw StateError('SfmLiveRecon.start 返回 null(模拟器 / worker 起不来)');
      _recon = recon;
      _reconSub = recon.events.listen(_onSfmEvent);

      _pumpTimer = Timer.periodic(const Duration(milliseconds: 50), (_) => _pump());
      setState(() {
        _running = true;
        _phase = '在跑:缓慢移动手机,状态变 tracking 后按「拍一张」';
      });
    } catch (e, st) {
      _fail('启动失败:$e');
      _log('$st');
    }
  }

  void _fail(String why) {
    _log('🔴 $why');
    if (!mounted) return;
    setState(() {
      _fatal = why;
      _phase = '失败';
    });
  }

  void _onPose(ARPose pose) {
    _poseFrames++;
    _lastPose = pose;
    final FocusSelfHeal? heal = _selfHeal;
    if (heal != null && !_shutterBusy && !_finishing) {
      final PwFocusState? fs = PwFocus.state();
      if (fs != null) {
        heal.onSample(
          nowMs: DateTime.now().millisecondsSinceEpoch,
          focusMeasure: fs.focusMeasure,
          isAdjustingFocus: fs.isAdjustingFocus,
          position: pose.position,
          orientation: pose.orientation,
        );
      }
    }
    if (_poseFrames % 6 == 0 && mounted) setState(() {});
  }

  /// 50 ms 一次:① 收照片结果 → 提交链路核心;② 收链路结果 → 喂 SfM。
  void _pump() {
    for (final PwCapturedPhoto p in PwCameraPhoto.drain()) {
      final _Shot? s = _byId[p.requestId];
      if (s == null) {
        _log('🔴 照片 #${p.requestId} 没有对应的快门记录,跳过');
        continue;
      }
      s.photo = p;
      final XrChainSubmit? sub = XrChainNative.submit(p.requestId, p.timestampSeconds, p.exposureSeconds);
      s.submit = sub;
      _log('照片 #${p.requestId} ${p.width}x${p.height} pts=${p.timestampSeconds.toStringAsFixed(6)} '
          'exp=${(p.exposureSeconds * 1000).toStringAsFixed(2)}ms ⇒ t_photo=${sub?.tPhoto.toStringAsFixed(6)} '
          '(+exp/2 ${((sub?.halfExposure ?? 0) * 1000).toStringAsFixed(3)}ms +c+Δ '
          '${((sub?.offset ?? 0) * 1000).toStringAsFixed(3)}ms) rc=${sub?.rc}');
    }
    for (final XrChainPhotoResult r in XrChainNative.takeAll()) {
      _onChainResult(r);
    }
  }

  void _onChainResult(XrChainPhotoResult r) {
    final _Shot? s = _byId[r.photoId];
    final PwCapturedPhoto? p = s?.photo;
    if (s == null || p == null) {
      _log('🔴 链路结果 #${r.photoId} 找不到照片');
      return;
    }
    s.result = r;
    final String tracker = xrChainTrackerStateName(trusted: r.trusted, reasonBits: r.reasonBits);
    // 没有位姿(拍照之前没有任何后端帧)时位姿给单位阵:核对不可信帧的位姿只随帧存档,不摆位、不对齐、
    // 不当先验(official_sfm_c.h DEVICE-POSE-TRUST-V1)。
    final List<double> transform = r.hasPose
        ? xrslamCameraPoseToArkitCameraTransform(r.cameraQxyzw, r.cameraCenter)
        : const <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
    s.notes['arkit_camera_transform'] = transform;
    s.notes['tracker_state_name'] = tracker;
    final OfficialHighResInputValidation v = OfficialHighResReconstructionInput.validate(
      jpegPath: p.path,
      imageWidth: p.width,
      imageHeight: p.height,
      triggerTimestamp: r.tPhoto,
      captureTimestamp: r.tPhoto,
      cameraTransform: transform,
      intrinsics: <double>[p.fx, p.fy, p.cx, p.cy],
      trackingStateName: tracker,
    );
    final SfmLiveRecon? recon = _recon;
    if (!v.isAccepted || recon == null) {
      s.fedResult = 'rejected:${v.failure?.name ?? 'no_recon'}';
    } else {
      final bool offered = recon.offerFrame(v.input!);
      s.fedResult = offered ? 'offered' : 'offer_refused';
    }
    _log('位姿 #${r.photoId} 来源=${kXrChainSourceNames[r.source]} 可信=${r.trusted ? 1 : 0} '
        '原因=${xrChainReasonNames(r.reasonBits)} 等待=${r.waitMs.toStringAsFixed(0)}ms '
        '外推=${(r.extrapolationSeconds * 1000).toStringAsFixed(1)}ms 外推状态=${r.propagateStatus} '
        '拍照时刻状态=${r.engineStateAtPhoto} ⇒ ${s.fedResult}');
    _writeShot(s);
    if (mounted) setState(() {});
  }

  void _writeShot(_Shot s) {
    final PwCapturedPhoto? p = s.photo;
    final XrChainPhotoResult? r = s.result;
    final XrChainSubmit? sub = s.submit;
    final Map<String, Object?> row = <String, Object?>{
      'request_id': s.id,
      'capture_rc': s.captureRc,
      'focus_prepare': s.focusPrepare,
      if (p != null) ...<String, Object?>{
        'jpeg': p.path,
        'sidecar': p.sidecarPath,
        'image_w': p.width,
        'image_h': p.height,
        'fxfycxcy': <double>[p.fx, p.fy, p.cx, p.cy],
        'photo_pts_s': p.timestampSeconds,
        'photo_exposure_s': p.exposureSeconds,
      },
      if (sub != null) ...<String, Object?>{
        't_photo_engine_s': sub.tPhoto,
        'half_exposure_applied_s': sub.halfExposure,
        'camera_time_offset_applied_s': sub.offset,
        'submitted_at_host_s': sub.now,
        'submit_rc': sub.rc,
      },
      if (r != null) ...<String, Object?>{
        'pose_source': kXrChainSourceNames[r.source],
        'device_pose_trusted': r.trusted,
        'untrusted_reasons': xrChainReasonNames(r.reasonBits),
        'engine_state_at_photo': r.engineStateAtPhoto,
        'backend_frame_t_s': r.tState,
        'backend_frame_id': r.frameId,
        'start_state_kind': r.stateKind,
        'extrapolation_ms': r.extrapolationSeconds * 1000,
        'propagate_status': r.propagateStatus,
        'propagated_t_s': r.propagatedT,
        'imu_samples': r.imuSamples,
        'wait_from_photo_ms': r.waitMs,
        'wait_from_submit_ms': r.submitToResolveMs,
        'has_pose': r.hasPose,
        'xrslam_camera_q_xyzw': r.cameraQxyzw,
        'xrslam_camera_center': r.cameraCenter,
        'xrslam_body_q_xyzw': r.bodyQxyzw,
        'xrslam_body_p': r.bodyP,
      },
      ...s.notes,
      'fed': s.fedResult,
      'sfm_frame_id': s.fedFrameId,
    };
    _photoLog?.writeln(jsonEncode(row));
  }

  void _onSfmEvent(SfmLiveEvent e) {
    if (e is SfmLiveFrameFed) {
      final _Shot? s = _shots.where((x) => x.photo?.path == e.jpegPath).firstOrNull;
      if (s != null) {
        s.fedFrameId = e.frameId;
        s.notes['sfm_add_frame_result'] = e.result;
        s.notes['sfm_add_frame_ms'] = e.elapsedMs;
      }
      _log('SfM 喂帧 seq=${e.seq} frameId=${e.frameId} ${e.result} ${e.elapsedMs}ms ${e.jpegPath}');
    } else if (e is SfmLiveRefined) {
      _refined?.complete(e);
    } else if (e is SfmLiveFailed) {
      _sfmErrors.add('${e.stage}: ${e.message}');
      _log('🔴 SfM 失败 ${e.stage}: ${e.message}');
      if (e.stage.contains('finalize') || e.stage.contains('refine')) _refined?.complete(null);
    }
  }

  Future<void> _shutter() async {
    if (!_running || _shutterBusy || _finishing) return;
    setState(() => _shutterBusy = true);
    final _Shot s = _Shot(_nextId++, DateTime.now().millisecondsSinceEpoch);
    _shots.add(s);
    _byId[s.id] = s;
    // 对焦准备:与探针页同一套(臂 A 不动镜头;B/C 各自上限在原生侧)。
    final Stopwatch fsw = Stopwatch()..start();
    PwFocusPrepareState? prepare = PwFocus.prepareBegin();
    if (prepare != null) {
      PwFocusPrepareState cur = prepare;
      while (mounted && !cur.isTerminal && fsw.elapsed < const Duration(seconds: 4)) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        cur = PwFocus.preparePoll() ?? PwFocusPrepareState.error;
      }
      prepare = cur;
    }
    s.focusPrepare = '${prepare?.label ?? 'symbol_missing'}/${fsw.elapsedMilliseconds}ms';
    s.captureRc = PwCameraPhoto.capture(s.id);
    PwFocus.prepareEnd();
    _log('快门 #${s.id} capture rc=${s.captureRc} 对焦=${s.focusPrepare} '
        '前端状态=${_lastPose?.trackingStateName} tracking=${_lastPose?.isTracking}');
    if (mounted) setState(() => _shutterBusy = false);
  }

  Future<void> _finish() async {
    if (_finishing || !_running) return;
    setState(() {
      _finishing = true;
      _phase = '收尾:等照片落盘';
    });
    // ① 等已按下的快门都出结果(照片落盘 + sidecar),上限 15 s。
    final Stopwatch sw = Stopwatch()..start();
    while (_shots.any((s) => s.captureRc == 0 && s.photo == null) && sw.elapsed < const Duration(seconds: 15)) {
      _pump();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    // ② 停相机(不再有新帧),等喂料 worker 与引擎 worker 排空 —— 收尾窗口必须是最终窗口。
    setState(() => _phase = '收尾:停相机、等引擎排空');
    _platform.stopCamera();
    XrChainDrainState? d;
    final Stopwatch dw = Stopwatch()..start();
    while (dw.elapsed < const Duration(seconds: 20)) {
      _pump();
      d = XrChainNative.drainState();
      if (d != null && d.drained) break;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _pump();
    final int closed = XrChainNative.close();
    _log('收尾:排空 ${dw.elapsedMilliseconds}ms 状态 live=${d?.liveFrames}/${d?.liveImu} engine=${d?.engineFrames} '
        '⇒ 收尾给出 $closed 张');
    _pump();
    final List<int> chainStats = XrChainNative.stats();
    XrChainNative.end();
    _pumpTimer?.cancel();
    await _poseSub?.cancel();
    await _provider?.stop(); // 销毁 XRSLAM 会话(外推已全部做完)
    // ③ SfM finalize → 交付。
    setState(() => _phase = '收尾:SfM finalize(可能几分钟,别切后台)');
    final SfmLiveRecon? recon = _recon;
    SfmLiveRefined? refined;
    if (recon != null) {
      _refined = Completer<SfmLiveRefined?>();
      recon.finalize();
      refined = await _refined!.future.timeout(const Duration(minutes: 20), onTimeout: () => null);
      if (refined != null) await _saveRefined(refined);
    }
    await _writeManifest(chainStats, closed, d, refined);
    await _photoLog?.flush();
    await _photoLog?.close();
    _photoLog = null;
    await recon?.dispose();
    _recon = null;
    if (!mounted) return;
    setState(() {
      _finished = true;
      _running = false;
      _phase = '完成:${_runDir?.path}';
    });
  }

  Future<void> _saveRefined(SfmLiveRefined e) async {
    final Directory? run = _runDir;
    if (run == null) return;
    final SfmLiveSnapshot s = e.snapshot;
    final StringBuffer poses = StringBuffer('frame_id,registered,qw,qx,qy,qz,tx,ty,tz,jpeg\n');
    final Map<int, String> jpegOf = <int, String>{
      for (final _Shot x in _shots)
        if (x.fedFrameId != null && x.photo != null) x.fedFrameId!: x.photo!.path,
    };
    for (int i = 0; i + 8 < s.posesPacked.length; i += 9) {
      final int fid = s.posesPacked[i].toInt();
      poses.writeln(<Object>[
        fid, s.posesPacked[i + 1].toInt(),
        for (int j = 2; j < 9; j++) s.posesPacked[i + j],
        jpegOf[fid] ?? '',
      ].join(','));
    }
    await File('${run.path}/sfm_refined_poses.csv').writeAsString(poses.toString());
    final int n = s.pointCount;
    final BytesBuilder ply = BytesBuilder();
    ply.add(utf8.encode('ply\nformat binary_little_endian 1.0\nelement vertex $n\n'
        'property float x\nproperty float y\nproperty float z\n'
        'property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n'));
    final ByteData row = ByteData(15);
    for (int i = 0; i < n; i++) {
      row.setFloat32(0, s.xyz[3 * i], Endian.little);
      row.setFloat32(4, s.xyz[3 * i + 1], Endian.little);
      row.setFloat32(8, s.xyz[3 * i + 2], Endian.little);
      row.setUint8(12, i * 3 + 2 < s.rgb.length ? s.rgb[3 * i] : 0);
      row.setUint8(13, i * 3 + 2 < s.rgb.length ? s.rgb[3 * i + 1] : 0);
      row.setUint8(14, i * 3 + 2 < s.rgb.length ? s.rgb[3 * i + 2] : 0);
      ply.add(row.buffer.asUint8List());
    }
    await File('${run.path}/sfm_refined_points.ply').writeAsBytes(ply.takeBytes());
    _sfmSummary
      ..['refine_ms'] = e.refineMs
      ..['points'] = n
      ..['frames'] = s.poseCount
      ..['registered'] = s.registeredCount
      ..['summary'] = s.summary
      ..['gravity_align_quat_wxyz'] = s.gravityAlignQuatWxyz;
    _log('SfM 交付:点 $n、帧 ${s.poseCount}、注册 ${s.registeredCount}、summary=${s.summary}');
  }

  Future<void> _writeManifest(List<int> chainStats, int closed, XrChainDrainState? d, SfmLiveRefined? refined) async {
    final Directory? run = _runDir;
    if (run == null) return;
    final List<XrChainPhotoResult> rs = <XrChainPhotoResult>[for (final _Shot s in _shots) if (s.result != null) s.result!];
    final Map<String, Object?> m = <String, Object?>{
      'schema': kXrChainManifestSchema,
      'bench_only': '🔴 台架(com.kyle.arloopbench)。生产 App 不含本页;LiDAR / ARKit 不进本链任何路径。',
      'machine': _machine,
      'camera_time_offset_base': _cBase?.toString(),
      'camera_time_offset_applied_s': _cApplied?.seconds,
      'td_extra_ms': _tdExtraMs,
      'td_extra_note': '仅台架实验设置(新积分器下本机旋转抖动判据最优点),不写进任何产品规则',
      'final_timeout_ms': _timeoutMs,
      'max_extrapolation_ms': _maxExtrapMs,
      'arg_sources': _argSources,
      'official_env_applied': _envApplied,
      'photo_dims_choice': PwCameraSlot.lastPhotoDimsChoice?.toString(),
      'focus_arm': _focusArm?.describe,
      'shots': _shots.length,
      'photos': _shots.where((s) => s.photo != null).length,
      'chain_results': rs.length,
      'trusted': rs.where((r) => r.trusted).length,
      'by_source': <String, int>{
        for (final MapEntry<int, String> e in kXrChainSourceNames.entries)
          e.value: rs.where((r) => r.source == e.key).length,
      },
      'wait_from_photo_ms': <double>[for (final r in rs) r.waitMs],
      'extrapolation_ms': <double>[for (final r in rs) r.extrapolationSeconds * 1000],
      'closed_at_finish': closed,
      'drain_at_finish': d == null
          ? null
          : <String, int>{
              'live_frames': d.liveFrames, 'live_imu': d.liveImu, 'engine_frames': d.engineFrames,
              'frames_noted': d.framesNoted, 'frames_skipped': d.framesSkipped,
            },
      'chain_core_stats': chainStats,
      'chain_core_stats_legend': 'frames,first,final,queue_dropped,submitted,resolved,FINAL,WINDOW_AT_CLOSE,TIMEOUT,'
          'NO_BACKEND,trusted,untrusted,window_rows_at_close,drain_calls',
      'sfm': _sfmSummary,
      'sfm_errors': _sfmErrors,
      'sfm_refined': refined != null,
      'engine_build_stamp': _buildStamp,
    };
    await File('${run.path}/run_manifest.json').writeAsString(const JsonEncoder.withIndent('  ').convert(m));
    _log('manifest ${run.path}/run_manifest.json');
  }

  @override
  void dispose() {
    _pumpTimer?.cancel();
    unawaited(_poseSub?.cancel());
    unawaited(_reconSub?.cancel());
    if (!_finished) {
      XrChainNative.end();
      unawaited(_provider?.stop());
      _platform.stopCamera();
      unawaited(_recon?.dispose());
      unawaited(_photoLog?.close());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ZeroArkitCaptureRuntime? runtime = _runtime;
    final VioArPoseProvider? provider = _provider;
    final List<XrChainPhotoResult> rs = <XrChainPhotoResult>[for (final _Shot s in _shots) if (s.result != null) s.result!];
    final int waiting = _shots.where((s) => s.photo != null && s.result == null).length;
    final List<String> lines = <String>[
      _phase,
      if (_fatal != null) '🔴 $_fatal',
      '前端:${_lastPose?.trackingStateName ?? '-'} 帧 $_poseFrames',
      '照片:按 ${_shots.length},落盘 ${_shots.where((s) => s.photo != null).length},等定稿 $waiting,'
          '已出位姿 ${rs.length}(可信 ${rs.where((r) => r.trusted).length})',
      'Δ=${_tdExtraMs}ms  超时 ${_timeoutMs.toStringAsFixed(0)}ms  外推上限 ${_maxExtrapMs.toStringAsFixed(0)}ms',
      if (rs.isNotEmpty)
        '最近:#${rs.last.photoId} ${kXrChainSourceNames[rs.last.source]} 可信=${rs.last.trusted ? 1 : 0} '
            '等 ${rs.last.waitMs.toStringAsFixed(0)}ms 外推 ${(rs.last.extrapolationSeconds * 1000).toStringAsFixed(0)}ms',
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('XRSLAM → SfM 重建链(台架)')),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(8),
              child: DefaultTextStyle(
                style: const TextStyle(fontSize: 12, color: Colors.black87),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: lines.map((String s) => Text(s)).toList(),
                ),
              ),
            ),
            Expanded(
              child: AspectRatio(
                aspectRatio: 3 / 4,
                child: (_running && runtime != null && provider != null)
                    ? ZeroArkitCameraPreview(
                        imageWidth: runtime.captureWidth,
                        imageHeight: runtime.captureHeight,
                        poseReader: () => provider.lastRendererPose,
                      )
                    : ColoredBox(
                        color: const Color(0xFF202020),
                        child: Center(
                          child: Text(_finished ? '已完成' : '预览未挂',
                              style: const TextStyle(color: Colors.white54)),
                        ),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: <Widget>[
                  FilledButton(
                    onPressed: (_running && !_shutterBusy && !_finishing) ? _shutter : null,
                    child: const Text('拍一张'),
                  ),
                  OutlinedButton(
                    onPressed: (_running && !_finishing) ? _finish : null,
                    child: const Text('完成'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
