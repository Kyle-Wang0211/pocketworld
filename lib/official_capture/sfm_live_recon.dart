// sfm_live_recon.dart — capture-time streaming SfM orchestration.
//
// Owns the SINGLE serial background queue that carries every aether_sfm_*
// call (hard rule: no SfM ABI call may ever run on the UI isolate — add_frame
// is ~0.5-0.7 s on an A16 and finalize_async's synchronous phase is
// minutes-scale). The queue is a dedicated long-lived worker isolate; the
// Dart isolate event loop serializes commands naturally because every
// handler is a blocking native call.
//
// Dataflow:
//   ARCapturePage shutter → CaptureSession.captureSinglePhoto →
//   OfficialHighResReconstructionInput (4032×3024 JPEG path + same-frame
//   intrinsics/extrinsic) → [this facade: CamFromWorld conversion + queue]
//   → worker isolate → pwofficial_add_jpeg_frame
//   finish → finalize() → worker runs aether_sfm_finalize_async (phase 1
//   blocks in-worker) → LOCAL_READY snapshot event → worker polls
//   finalize_status until REFINED/ERROR → refined snapshot event.
//
// Backpressure (capture never waits for SfM, and NOTHING is ever dropped):
// when the worker already has kSfmFeedMaxInFlight add_frame calls unconsumed,
// the keyframe's already-persisted canonical JPEG PATH is queued (RAM stays
// flat no matter how deep the queue grows). The pump feeds queued files in arrival
// order as slots free; finalize is DEFERRED until the queue fully drains, so
// every offered frame reaches the reconstruction (finalize frame count ==
// captured frame count). Backpressure acts only on the background CONSUMER
// (when the worker takes its next frame); it never propagates back to the
// shutter. 07-12 签决:快门彻底不限流 + 队列不丢帧 + 不降质。Pure queue
// predicates live in sfm_feed_queue.dart (host-tested by
// tool/sfm_feed_queue_check.dart).

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart' as vm;

import '../official_aether_sfm_ffi.dart';
import '../official_util/device_log.dart';
import '../reconstruction_lease.dart';
import 'gravity_align.dart';
import 'live_sfm_publish_policy.dart';
import 'official_highres_reconstruction_input.dart';
import 'photo_archive_coordinator.dart';
import 'photo_archive_runtime.dart';
import 'pw_telemetry.dart';
import 'sfm_feed_queue.dart';
import 'telemetry_writer.dart';
import 'true_parallax.dart';

/// [AR-EVERY-FRAME 2026-08-04] 实验臂,默认关(env
/// OFFICIAL_AETHER_AR_EVERY_FRAME=1)。开启后:每个被接受、且已有 live_recon
/// 点的帧,把当前 previewTracked(实时局部BA点云)以 source='streaming_local_ba'
/// 推给 AR,让点云每帧可见生长,而不是只在稀疏的全局BA检查点(20帧起+1.40×
/// 增长,300帧约刷新~8次)才刷新。host 前提已证:previewTracked 每帧存在且
/// 单调增长(evidence/ar-display-decouple-premise-v1.md)。
///
/// 关键:这是**叠加**,不改动既有全局BA检查点逻辑——globalRefine 仍在拍摄期
/// 跑并发布 'streaming_global_ba'(用户签决:保留拍摄期全局BA以预热 finalize、
/// 缩短拍完等待)。本臂只让**显示**不再被全局BA门控。AR 侧 400ms 合并节流
/// (_pushCoverageCloud)兜住每帧推的传输成本,正是 eaf8706 动效延迟的既有防线。
/// 🔴 [ROOT-CAUSE FIX 2026-08-05] 曾用 `Platform.environment[...] == '1'` 读
/// native setenv 设的 env——**不可靠**:C 的 getenv() 读活 environ 能看到 setenv,
/// 但 Dart 的 Platform.environment 是**进程启动快照**,看不到启动后 setenv 的值
/// (设备实测:主 isolate 读 == false,导致每帧推送整条从不触发,连炸两次真机测试)。
/// 所有 C 侧 OFFICIAL_AETHER_* flag 正常正是因为走 getenv;Dart 侧走 Platform.
/// environment 的 flag(本臂 + scale-anchor)都踩这个坑。
/// ⚠️scale-anchor(line ~1440,同机制)很可能也一直静默关着——待单独核实。
///
/// 实验 build 里改用**编译期常量**,彻底绕开 env 时机问题。开=true / 关=false
/// 各重建一次(实验臂本就每次装机决定开关,不需要运行时可切)。仍经 boot 消息
/// 传给 worker isolate(worker 读不到主 isolate 的顶层常量也无妨,常量已内联)。
const bool _arEveryFrameEnabled = true;

// [SPRINT-RACE 2026-07-26] matcher capture-active atomic, read side (see
// pwofficial_gpu_match.mm aether_gpu_match_get_capture_active).
typedef _CaptureActiveC = ffi.Int32 Function();
typedef _CaptureActiveDart = int Function();

/// One reconstruction snapshot (LOCAL_READY or REFINED). Always the FULL
/// point set — render-side thinning is allowed, data-side never.
class SfmLiveSnapshot {
  const SfmLiveSnapshot({
    required this.xyz,
    required this.rgb,
    required this.posesPacked,
    required this.summary,
    required this.refined,
    required this.obsOffsets,
    required this.obsFrameIds,
    required this.obsXY,
    this.gravityAlignQuatWxyz,
    this.posesPackedRawColmap,
    this.scaleAnchorFactor,
  });

  /// 3 floats per point.
  final Float32List xyz;

  /// 3 bytes per point; may be all zeros (on-device extract_colors is off) —
  /// renderers must fall back to a uniform tint / height ramp, NOT treat
  /// black as failure.
  final Uint8List rgb;

  /// Per-point track observations (COLMAP-faithful colorizer input): point
  /// i's observations are obsFrameIds/obsXY[j] for
  /// obsOffsets[i] <= j < obsOffsets[i+1]; obsXY holds 2 floats per obs in
  /// fed-frame pixel coords. Track membership is a visibility proof — the
  /// colorizer samples each point's OWN detection frames at these keypoint
  /// coords (reprojecting into globally-picked frames sampled occluder
  /// colors: the striped/washed-color bug).
  final Int32List obsOffsets;
  final Int32List obsFrameIds;
  final Float32List obsXY;

  /// 9 doubles per frame: [frameId, registered, qw,qx,qy,qz, tx,ty,tz]
  /// (CamFromWorld — invert before drawing a camera trajectory).
  ///
  /// [GRAV-CONSIST 2026-07-28] When [gravityAlignQuatWxyz] is non-null these
  /// poses are in the SAME gravity-aligned world as [xyz] — the whole model
  /// transforms together (COLMAP `Reconstruction::Transform` semantics; the
  /// industry has zero precedent for rotating points without poses — COLMAP /
  /// AliceVision `applyTransform` / nerfstudio all move the model as one).
  final Float64List posesPacked;

  /// [GRAV-CONSIST 2026-07-28] The applied world rotation R_w as quaternion
  /// [w,x,y,z]: maps raw-COLMAP world → gravity world (+Y up), points as
  /// x' = R_w·x, poses as C' = C∘R_w⁻¹ (rotation-only; translations
  /// unchanged). Null = no alignment applied (posesPacked is raw COLMAP and
  /// posesPackedRawColmap is null). Recorded following nerfstudio's
  /// dataparser_transforms.json precedent so artifacts stay invertible.
  final List<double>? gravityAlignQuatWxyz;

  /// [GRAV-CONSIST 2026-07-28] The untransformed CamFromWorld poses (same
  /// packing), kept as an EXPLICIT raw-COLMAP truth for host parity
  /// cross-checks — a float inverse rotation is not bit-exact, so raw truth
  /// must be carried, not recomputed. Null when no alignment was applied.
  final Float64List? posesPackedRawColmap;

  /// [SCALE-ANCHOR 2026-07-28] 应用到本快照的米制尺度锚定因子(x'=s·x,
  /// t'=s·t;详见 gravity_align.dart scaleAnchorFactor)。null = 臂关闭或
  /// 估计失败(未缩放)。posesPackedRawColmap 不含此缩放(raw 真值)。
  final double? scaleAnchorFactor;

  /// {solve_ms, n_registered, n_points3d, reproj_px, rc, result} from the
  /// finalize phase that produced this snapshot (LOCAL summary for both).
  final Map<String, dynamic> summary;

  final bool refined;

  int get pointCount => xyz.length ~/ 3;
  int get poseCount => posesPacked.length ~/ 9;
  int get registeredCount {
    var n = 0;
    for (var i = 0; i < posesPacked.length; i += 9) {
      if (posesPacked[i + 1] != 0) n++;
    }
    return n;
  }

  /// 信号2【断连帧列表】:未注册(没连进重建)的帧 id,按 frameId 升序。
  /// 数据源 = posesPacked 里已有的 per-frame registered bit(零 ABI 改动,
  /// 与 [registeredCount] 同一来源)。注意:流式 preview 快照的 posesPacked
  /// 为空(worker 对 preview 发空 poses),此时返回空列表——本信号只在
  /// LOCAL_READY / REFINED 快照上有意义。
  List<int> get unregisteredFrameIds {
    final ids = <int>[];
    for (var i = 0; i < posesPacked.length; i += 9) {
      if (posesPacked[i + 1] == 0) ids.add(posesPacked[i].toInt());
    }
    ids.sort();
    return ids;
  }

  /// 信号2【断连区段】:把未注册帧按 frameId 序归并成连续区段,供 UI 提示
  /// "这一段没连上,在 prevRegisteredId 和 nextRegisteredId 之间补拍"
  /// (RS 式引导)。prev/next 为 null 表示区段贴着拍摄开头/结尾,那一侧
  /// 没有已注册邻帧。posesPacked 为空(preview 快照)时返回空列表。
  List<SfmDisconnectedSegment> get disconnectedSegments =>
      disconnectedSegmentsFromPoses(posesPacked);
}

/// 断连区段归并(纯函数,契约同 [SfmLiveSnapshot.disconnectedSegments])。
/// 顶层暴露是给拍摄期【guidance】遥测用的:拍摄期只有合成连通性
/// posesPacked([frameId, registered] 两位有效),没有完整快照对象。
List<SfmDisconnectedSegment> disconnectedSegmentsFromPoses(
  Float64List posesPacked,
) {
  final poseCount = posesPacked.length ~/ 9;
  final frames = List<({int id, bool reg})>.generate(poseCount, (k) {
    final o = k * 9;
    return (id: posesPacked[o].toInt(), reg: posesPacked[o + 1] != 0);
  })..sort((a, b) => a.id.compareTo(b.id));
  final segs = <SfmDisconnectedSegment>[];
  int? prevRegistered;
  var i = 0;
  while (i < frames.length) {
    if (frames[i].reg) {
      prevRegistered = frames[i].id;
      i++;
      continue;
    }
    final start = i;
    while (i < frames.length && !frames[i].reg) {
      i++;
    }
    segs.add((
      firstId: frames[start].id,
      lastId: frames[i - 1].id,
      count: i - start,
      prevRegisteredId: prevRegistered,
      nextRegisteredId: i < frames.length ? frames[i].id : null,
    ));
  }
  return segs;
}

/// 信号2 的区段载体:[firstId..lastId] 是一段(按 frameId 序)连续的未注册
/// 帧,count 为帧数;prev/nextRegisteredId 是两侧最近的已注册帧 id
/// (null = 区段贴拍摄边界)。UI 文案示例:"在 prevRegisteredId 和
/// nextRegisteredId 对应的拍摄位置之间补拍"。
typedef SfmDisconnectedSegment = ({
  int firstId,
  int lastId,
  int count,
  int? prevRegisteredId,
  int? nextRegisteredId,
});

// [增量D 2026-07-28] filterFinalSpatialTwoViewPoints(时间远距 spatial 2-view
// 删点器,官方栈零调用的死代码)与其 keepIdx 契约已删——它是
// ghostSpatialKeepIdx 的唯一生产者,鬼层 L1/L2 链 07-20 E25 签决停用后
// 整条管道无消费者。复活走 git 历史。

/// Facade lifecycle events, delivered on the UI isolate.
sealed class SfmLiveEvent {
  const SfmLiveEvent();
}

/// A keyframe finished add_frame in the worker.
class SfmLiveFrameFed extends SfmLiveEvent {
  const SfmLiveFrameFed({
    required this.seq,
    required this.frameId,
    required this.elapsedMs,
    required this.result,
    required this.jpegPath,
  });
  final int seq;
  final int frameId; // -1 when result != ok
  final int elapsedMs;
  final String result;
  final String? jpegPath;
}

/// A keyframe was spooled to disk because the worker is busy — it WILL be
/// fed as soon as the worker frees up (research tier: nothing is ever
/// dropped; the queue is disk-backed so memory stays flat).
class SfmLiveFrameQueued extends SfmLiveEvent {
  const SfmLiveFrameQueued(this.seq, this.queueDepth);
  final int seq;
  final int queueDepth;
}

/// Instant rough preview cloud (ARKit-pose triangulation, built during capture)
/// emitted the moment finalize is requested — for the immediate region selector,
/// BEFORE the minutes-scale authoritative finalize. Throwaway; ARKit-world xyz,
/// no color/poses/tracks.
class SfmLivePreview extends SfmLiveEvent {
  const SfmLivePreview(this.snapshot);
  final SfmLiveSnapshot snapshot;
}

/// 拍摄期实时连通性(AR 照片卡片边框状态机的数据源):worker 每喂完一帧
/// (节流后)读 live recon 的 track 观测,把"哪些已喂帧连进了重建"打包成
/// SfmLiveSnapshot.posesPacked 同款 9-double/帧数组发上来。注意这是
/// **合成 poses**:只有 [frameId, registered] 两位有效(registered=该帧
/// 在 live recon 里有 ≥1 个 track 观测),四元数/平移全 0——绝不能拿去
/// 画相机轨迹或做 gravity 对齐(全 0 四元数会被 _gravityAlign 的
/// norm 门自然跳过,这是刻意的)。轻量:~90 帧 <7KB。
class SfmLiveConnectivity extends SfmLiveEvent {
  const SfmLiveConnectivity(this.posesPacked);

  /// 契约同 [SfmLiveSnapshot.posesPacked](9 double/帧),但为合成值。
  final Float64List posesPacked;
}

/// 拍摄期真实三角化角(route B,低视差引导的真值信号):worker 节流
/// (≥3.5s)对流式 preview 云逐点算"track 观测相机中心对点的最大成对
/// 夹角"(true_parallax.trueParallaxAggregate,相机中心=喂帧 ARKit
/// CamFromWorld,与 preview 点同一 gravity 世界系),聚合成:
///   ① [framesPacked] 帧级中位数 → photo_card_state 判黄真值;
///   ② [voxelKeys]/[voxelDeg] 体素级中位数 → CaptureCoverageCloud
///      .applyTrueParallax(压黄逻辑改用真值,视锥近似只兜底)。
/// 轻量:~90 帧 <1.5KB + 体素对 ~12B/体素(数千体素 ≈ 数十 KB)。
class SfmLiveTrueParallax extends SfmLiveEvent {
  const SfmLiveTrueParallax({
    required this.framesPacked,
    required this.voxelKeys,
    required this.voxelDeg,
    required this.computeMs,
    required this.sampledPoints,
  });

  /// [frameId, 该帧观测点真实三角化角中位数(度)] ×2/帧,frameId 升序。
  final Float64List framesPacked;

  /// 体素对(key = coverageVoxelKeyFor @ kCoverageVoxelSizeM,逐下标配对)。
  final Int64List voxelKeys;
  final Float32List voxelDeg;

  /// worker 侧本次聚合耗时(ms,遥测【guidance】对数用)与采样点数。
  final int computeMs;
  final int sampledPoints;
}

/// Phase 1 of finalize done — local reconstruction is live.
class SfmLiveLocalReady extends SfmLiveEvent {
  const SfmLiveLocalReady(this.snapshot, this.finalizeMs);
  final SfmLiveSnapshot snapshot;
  final int finalizeMs;
}

/// finalize phase 1 (incremental register + local BA) just completed in the
/// worker; the background global BA (phase 2) is now running. Carries no
/// snapshot — it exists so the waiting page can advance its stage copy
/// ("整理帧数据" → "全局优化中") the moment the boundary is crossed.
/// Derived from the worker's finalize_phase1 telemetry line (zero protocol
/// additions; see the facade's 'telem' case).
class SfmLiveFinalizePhase1Done extends SfmLiveEvent {
  const SfmLiveFinalizePhase1Done();
}

/// Background global BA converged — refined model silently swapped in.
class SfmLiveRefined extends SfmLiveEvent {
  const SfmLiveRefined(this.snapshot, this.refineMs);
  final SfmLiveSnapshot snapshot;
  final int refineMs;
}

/// Terminal failure (create / finalize / background refine). The capture
/// bundle is unaffected —材料已保留, the post-capture pipeline still runs.
class SfmLiveFailed extends SfmLiveEvent {
  const SfmLiveFailed(this.stage, this.message);
  final String stage;
  final String message;
}

// [增量D 2026-07-28] SfmLiveArbitrateDone 事件已删:L1 仲裁链 07-20 E25
// 签决停用(鬼层终审:事后清算天花板钉死),入口早已不可达,本次把事件类/
// 发射点/FFI 绑定/ghostSpatialKeepIdx 管道一并清除。复活走 git 历史。

/// What the facade remembers about each successfully-fed keyframe — enough
/// for the preview to project reconstructed points back into the saved JPEG
/// and sample real colors. Dimensions and intrinsics are the original JPEG's.
class SfmFedFrameMeta {
  const SfmFedFrameMeta({
    required this.jpegPath,
    required this.imageW,
    required this.imageH,
    required this.grayW,
    required this.grayH,
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    this.captureTimestamp,
    this.arkitQuatWxyz,
    this.arkitTransTxyz,
    this.arkitCameraCenterWorld,
  });
  final String jpegPath;
  final int imageW;
  final int imageH;
  final int grayW;
  final int grayH;
  final double fx;
  final double fy;
  final double cx;
  final double cy;
  final double? captureTimestamp;

  /// ARKit CamFromWorld rotation [w,x,y,z] for this frame — ARKit ran with
  /// worldAlignment=.gravity, so its world Y axis is gravity-up. Pairing it
  /// with the solved COLMAP CamFromWorld lets the facade recover the rotation
  /// that stands the (gauge-arbitrary) reconstruction upright. Null when the
  /// frame's extrinsic was degraded at capture.
  final List<double>? arkitQuatWxyz;

  /// ARKit CamFromWorld translation [tx,ty,tz] paired with [arkitQuatWxyz].
  final List<double>? arkitTransTxyz;

  /// ARKit camera center in the gravity-aligned world frame, meters.
  final List<double>? arkitCameraCenterWorld;
}

/// One canonical JPEG waiting while the worker is busy. CaptureSession owns
/// the file, so the queue never rewrites or deletes it.
class _SpooledFrame {
  _SpooledFrame({
    required this.seq,
    required this.path,
    required this.w,
    required this.h,
    required this.captureTimestamp,
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    required this.quatWxyz,
    required this.trans,
  });
  final int seq;
  final String path;
  final int w;
  final int h;
  final double captureTimestamp;
  final double fx;
  final double fy;
  final double cx;
  final double cy;
  final Float64List? quatWxyz;
  final Float64List? trans;
}

/// Identifies the coordinate-space contract of a snapshot before alignment.
/// Preview points already come from ARKit in gravity-aligned metric space;
/// delivery snapshots come from COLMAP and need the final alignment path.
enum _AlignmentSnapshotStage { preview, localReady, refined }

/// Main-isolate handle to the streaming-SfM worker. Create per capture take
/// via [start]; feed via [offerFrame]; end via [finalize]; ALWAYS [dispose]
/// (joins the native background thread + drops the session sqlite db).
class SfmLiveRecon {
  // A ReceivePort is single-subscription and CLOSES on cancel, so the ONE
  // subscription opened in [start] (which also handled the handshake) is
  // handed over here — never listen twice on the same port.
  SfmLiveRecon._(
    this._toWorker,
    this._fromWorker,
    this._isolate,
    this._sub,
    this._dbPath,
    this._leaseOwner,
    this._photoArchiveActivityLease,
  );

  final SendPort _toWorker;
  final ReceivePort _fromWorker;
  final Isolate _isolate;
  final StreamSubscription<dynamic> _sub;
  final String _dbPath;
  final Object _leaseOwner;
  final PhotoArchiveActivityLease _photoArchiveActivityLease;

  final _events = StreamController<SfmLiveEvent>.broadcast();
  Stream<SfmLiveEvent> get events => _events.stream;

  int _seq = 0;
  int _liveCloudSourceReceiveSequence = 0;
  int _inFlight = 0; // frames sent to the worker but not yet acked
  int _fedOk = 0;
  bool _finalizeRequested = false; // finish tapped — no new frames accepted
  // [QUAD-PREPAY 2026-07-26] one idle prepay cmd in flight at a time.
  bool _prepayInFlight = false;
  // [THERMAL-DOWNSHIFT 2026-08-07] serious 档"喂一帧、歇一次"的奇偶闸
  // (见 _thermalAllowsFeedNow)。
  bool _thermalDropArmed = false;
  bool _finalizeSent = false; // finalize cmd actually dispatched to worker

  // [PREFETCH-AB] 同场分块交替 A/B 的块长(launch env;0=关=恒预取)。
  static final int _prefetchAbBlock = (() {
    final v = Platform.environment['OFFICIAL_AETHER_PREFETCH_AB_BLOCK'];
    return v == null ? 0 : (int.tryParse(v) ?? 0);
  })();
  static bool _prefetchAbArmB(int seq) =>
      _prefetchAbBlock <= 0 || ((seq ~/ _prefetchAbBlock) % 2 == 1);

  // ── [EXTRACT-DEBT REPAY 2026-08-09 用户铁律] 交付绝对无损 ─────────────
  // GPU 提取失败(errExtract,如热态 20s 超时 + OOM 闸拦下 CPU 兜底)的帧
  // **绝不永久丢弃**:记欠账,排空完成后、finalize 下发前,临时放开 CPU 兜底
  // 重喂补算(拍完等待期相机停/内存空/GPU 闲,没有拍摄期爆内存的土壤)。
  // 重喂走 100% 正常喂帧路径(_SpooledFrame + _pump)⇒ fed_frames.jsonl /
  // 取色映射 / 事件流 / 遥测全部沿用,零特殊分支。
  final List<SfmFedFrameMeta> _extractDebts = [];
  final Set<int> _debtRefeedSeqs = {};
  bool _debtCpuEnvSet = false;
  bool _pumping = false;
  bool _disposed = false;
  Completer<void>? _disposeAck;

  // Disk-backed keyframe queue (research tier: NOTHING is dropped — photos
  // and poses are all on disk anyway, so a busy worker just means the frame
  // waits its turn; finalize is deferred until the queue drains).
  final List<_SpooledFrame> _spool = <_SpooledFrame>[];

  // seq → meta while in flight; frameId → meta once the worker acks the
  // add_frame (frame ids come back with frame_done).
  final Map<int, SfmFedFrameMeta> _pendingMeta = <int, SfmFedFrameMeta>{};
  final Map<int, SfmFedFrameMeta> _fedMeta = <int, SfmFedFrameMeta>{};
  final Map<String, int> _nativeFrameIdByJpegPath = <String, int>{};
  final Map<String, Completer<bool>> _removeWhenFrameAcked =
      <String, Completer<bool>>{};
  final Map<int, Completer<bool>> _removeRequests = <int, Completer<bool>>{};
  int _nextRemoveRequestId = 0;

  // ── 遥测【frame】时间戳(epoch ms):seq → offer 到达 / 实际送 worker。
  // frame_done 时合成一行结构化 frame 事件后移除(既有回调顺手记,零阻塞)。
  final Map<int, int> _seqOfferMs = <int, int>{};
  final Map<int, int> _seqSentMs = <int, int>{};

  /// 遥测【queue_drain】:finalize() 被请求的时刻(epoch ms),到
  /// [_maybeSendFinalize] 真正下发的间隔 = 队列排空耗时。
  int _finalizeRequestMs = 0;

  /// 遥测【WAIT-BUDGET 2026-07-29】完成动作那一刻的**欠债深度**。
  ///
  /// 用户签决的约束是「可以忍受发热,不能忍受等待变长」,这把该量的东西从热
  /// 换成了吞吐:拍摄期的流式计算**只有跟得上快门时才是隐形的**,跟不上就一帧
  /// 一帧攒着,最后整批砸成"拍完之后干等"。`queue_drain.ms` 只说了排空花了多久,
  /// 没说**排的是多少帧** —— 而候选预算(K12 vs K30)影响的正是逐帧成本,所以
  /// 必须能把等待时间归因到"欠了几帧"上,否则 K30 的账算不清。
  int _finalizeBacklog = 0;
  int _finalizeInFlight = 0;

  /// Per-registered-frame sampling metadata, keyed by the solver's frameId
  /// (== SfmLiveSnapshot.posesPacked frame ids).
  Map<int, SfmFedFrameMeta> get fedFrameMeta => _fedMeta;

  /// Keyframes successfully added to the live reconstruction.
  int get fedCount => _fedOk;

  /// Keyframes parked on disk awaiting the worker.
  int get queuedCount => _spool.length;

  /// Frames not yet acknowledged by native SfM, including both disk-spooled
  /// frames and the at-most-two worker calls currently in flight.
  int get remainingCount => _spool.length + _inFlight;

  /// Every keyframe offered this take (fed + in-flight + queued).
  int get offeredCount => _seq;

  bool get finalizeStarted => _finalizeRequested;

  /// True when streaming SfM can run at all (physical iOS device with the
  /// native slice linked). On the simulator this returns false and callers
  /// hide the whole live-preview feature.
  static bool get isSupported => AetherSfm.isSupported;

  /// Spawns the worker. Returns null when unsupported or when the worker
  /// fails to come up — callers degrade by not showing the preview layer.
  /// Throws [ReconstructionLeaseBusyException] when either physical pipeline
  /// copy still owns the process-wide SfM worker; no cross-route fallback is
  /// attempted.
  static Future<SfmLiveRecon?> start({required String dbPath}) async {
    if (!isSupported) {
      DeviceLog.log('SfmLive', 'start: unsupported (simulator) — hidden');
      return null;
    }
    final leaseOwner = Object();
    reconstructionLease.acquire(
      owner: leaseOwner,
      pipeline: ReconstructionPipeline.official,
    );
    final photoArchiveActivityLease = photoArchiveCoordinator
        .beginReconstructionActivity(Directory(File(dbPath).parent.path));
    final fromWorker = ReceivePort();
    Isolate? isolate;
    StreamSubscription<dynamic>? sub;
    var handedOff = false;
    try {
      try {
        isolate = await Isolate.spawn(
          _sfmWorkerMain,
          // _arEveryFrameEnabled 在此(主 isolate)读——env 在主 isolate 才有效。
          _SfmWorkerBootstrap(
            fromWorker.sendPort,
            dbPath,
            _arEveryFrameEnabled,
          ),
          debugName: 'official_sfm_live_recon',
          errorsAreFatal: true,
        );
      } catch (e) {
        DeviceLog.log('SfmLive', 'worker spawn FAILED: $e');
        return null;
      }

      // ONE subscription for the port's whole life: first message is the
      // handshake SendPort, everything after routes to the live handler.
      // (ReceivePort is single-subscription and closes on cancel — a second
      // listen() throws; this exact mistake shipped once and silently killed
      // the feature in release.)
      final handshake = Completer<SendPort?>();
      SfmLiveRecon? recon;
      sub = fromWorker.listen((msg) {
        if (!handshake.isCompleted) {
          handshake.complete(msg is SendPort ? msg : null);
          return;
        }
        recon?._onWorkerMessage(msg);
      });
      SendPort? port;
      try {
        port = await handshake.future.timeout(
          const Duration(seconds: 10),
          onTimeout: () => null,
        );
      } catch (_) {
        port = null;
      }
      if (port == null) {
        DeviceLog.log('SfmLive', 'worker handshake FAILED/timeout — disabled');
        return null;
      }
      recon = SfmLiveRecon._(
        port,
        fromWorker,
        isolate,
        sub,
        dbPath,
        leaseOwner,
        photoArchiveActivityLease,
      );
      handedOff = true;
      DeviceLog.log('SfmLive', 'worker up (db=$dbPath)');
      return recon;
    } catch (e, st) {
      DeviceLog.log('SfmLive', 'worker startup FAILED: $e\n$st');
      return null;
    } finally {
      if (!handedOff) {
        try {
          await sub?.cancel();
        } catch (_) {
          // Cleanup continues below so a failed start cannot leak the lease.
        }
        try {
          fromWorker.close();
          isolate?.kill(priority: Isolate.immediate);
        } finally {
          reconstructionLease.release(leaseOwner);
          await photoArchiveActivityLease.close();
        }
      }
    }
  }

  /// Offers one validated 12MP JPEG to the official reconstruction. Only the
  /// path and same-frame calibration cross Dart; decoded pixels do not.
  bool offerFrame(OfficialHighResReconstructionInput feed) {
    if (_disposed || _finalizeRequested) return false;
    if (feed.intrinsics.length < 4 ||
        feed.imageWidth != OfficialHighResReconstructionInput.requiredWidth ||
        feed.imageHeight != OfficialHighResReconstructionInput.requiredHeight ||
        !File(feed.jpegPath).existsSync()) {
      return false;
    }
    final seq = ++_seq;
    _seqOfferMs[seq] = DateTime.now().millisecondsSinceEpoch; // 遥测【frame】
    final fx = feed.intrinsics[0];
    final fy = feed.intrinsics[1];
    final cx = feed.intrinsics[2];
    final cy = feed.intrinsics[3];

    // ARKit extrinsic is column-major camera-to-world; the ABI wants the
    // CamFromWorld (world→camera) prior. Native uses it for the ARKit-world live
    // preview/local-BA path; authoritative finalize still estimates its own SfM
    // camera poses from image matches.
    Float64List? quatWxyz;
    Float64List? trans;
    List<double>? cameraCenterWorld;
    if (feed.cameraTransform.length == 16) {
      final c2w = vm.Matrix4.fromList(feed.cameraTransform);
      final cWorld = c2w.getTranslation();
      final rW2c = c2w.getRotation()..transpose();
      final tW2c = rW2c.transform(-cWorld);
      final q = vm.Quaternion.fromRotation(rW2c)..normalize();
      quatWxyz = Float64List.fromList([q.w, q.x, q.y, q.z]);
      trans = Float64List.fromList([tW2c.x, tW2c.y, tW2c.z]);
      cameraCenterWorld = [cWorld.x, cWorld.y, cWorld.z];
    }

    _pendingMeta[seq] = SfmFedFrameMeta(
      jpegPath: feed.jpegPath,
      imageW: feed.imageWidth,
      imageH: feed.imageHeight,
      grayW: feed.imageWidth,
      grayH: feed.imageHeight,
      fx: fx,
      fy: fy,
      cx: cx,
      cy: cy,
      captureTimestamp: feed.captureTimestamp,
      arkitQuatWxyz: quatWxyz?.toList(), // ARKit CamFromWorld (gravity frame)
      arkitTransTxyz: trans?.toList(),
      arkitCameraCenterWorld: cameraCenterWorld,
    );

    // [THERMAL-DOWNSHIFT 2026-08-07] 直发路径同样过热闸(短路求值:要 spool
    // 时不消耗奇偶);被闸下的帧走 spool,排空期回填,交付数据零损失。
    if (!sfmFeedShouldSpool(inFlight: _inFlight, spoolDepth: _spool.length) &&
        _thermalAllowsFeedNow()) {
      _sendJpegFrameCmd(
        seq,
        feed.jpegPath,
        feed.imageWidth,
        feed.imageHeight,
        feed.captureTimestamp,
        fx,
        fy,
        cx,
        cy,
        quatWxyz,
        trans,
      );
    } else {
      _spool.add(
        _SpooledFrame(
          seq: seq,
          path: feed.jpegPath,
          w: feed.imageWidth,
          h: feed.imageHeight,
          captureTimestamp: feed.captureTimestamp,
          fx: fx,
          fy: fy,
          cx: cx,
          cy: cy,
          quatWxyz: quatWxyz,
          trans: trans,
        ),
      );
      _events.add(SfmLiveFrameQueued(seq, _spool.length));
      DeviceLog.log(
        'SfmLive',
        'frame#$seq queued (inFlight=$_inFlight, depth=${_spool.length})',
      );
    }
    // [THERMAL-DOWNSHIFT 2026-08-07] critical 下 spool 会在 inFlight==0 时积
    // 压(旧不变式"spool>0 ⇒ inFlight>0"被热闸打破,frame_done 泵不会来)。
    // 每次新 offer 补踢一脚泵;泵内逐轮重查热档,过热时立即 break,零多喂。
    if (_spool.isNotEmpty && _inFlight == 0) unawaited(_pump());
    return true;
  }

  /// Withdraws one user-selected project photo from every live-SfM state.
  ///
  /// A queued photo is removed before it reaches native. An in-flight photo
  /// waits for its add-frame acknowledgement and is then de-registered. A
  /// frame already in COLMAP is removed through the existing native
  /// ObservationManager/database path. Analysis status never calls this
  /// method; the only caller is the explicit album delete action.
  Future<bool> removePhoto(String jpegPath) async {
    if (_disposed || _finalizeRequested || jpegPath.isEmpty) return false;

    final queuedIndex = _spool.indexWhere((entry) => entry.path == jpegPath);
    if (queuedIndex >= 0) {
      final entry = _spool.removeAt(queuedIndex);
      _pendingMeta.remove(entry.seq);
      _seqOfferMs.remove(entry.seq);
      _seqSentMs.remove(entry.seq);
      _events.add(SfmLiveFrameQueued(entry.seq, _spool.length));
      DeviceLog.log('SfmLive', 'user removed queued frame#${entry.seq}');
      return true;
    }

    final nativeFrameId = _nativeFrameIdByJpegPath[jpegPath];
    if (nativeFrameId != null) {
      return _requestNativeFrameRemoval(nativeFrameId);
    }

    final isInFlight = _pendingMeta.values.any(
      (meta) => meta.jpegPath == jpegPath,
    );
    if (isInFlight) {
      final existing = _removeWhenFrameAcked[jpegPath];
      if (existing != null) return existing.future;
      final completer = Completer<bool>();
      _removeWhenFrameAcked[jpegPath] = completer;
      return completer.future;
    }

    // The ledger can be notified before the reconstruction stream listener.
    // In that narrow window the photo has no SfM contribution, so deletion is
    // already complete from the solver's perspective.
    return true;
  }

  Future<bool> _requestNativeFrameRemoval(int frameId) async {
    final requestId = ++_nextRemoveRequestId;
    final completer = Completer<bool>();
    _removeRequests[requestId] = completer;
    _toWorker.send(<String, Object?>{
      'cmd': 'remove_frame',
      'requestId': requestId,
      'frameId': frameId,
    });
    try {
      return await completer.future.timeout(const Duration(seconds: 30));
    } on TimeoutException {
      _removeRequests.remove(requestId);
      return false;
    }
  }

  void _sendJpegFrameCmd(
    int seq,
    String jpegPath,
    int w,
    int h,
    double captureTimestamp,
    double fx,
    double fy,
    double cx,
    double cy,
    Float64List? q,
    Float64List? t,
  ) {
    _inFlight++;
    _seqSentMs[seq] = DateTime.now().millisecondsSinceEpoch; // 遥测【frame】
    _toWorker.send(<String, Object?>{
      'cmd': 'jpeg_frame',
      'seq': seq,
      'jpegPath': jpegPath,
      'w': w,
      'h': h,
      'captureTimestamp': captureTimestamp,
      'fx': fx,
      'fy': fy,
      'cx': cx,
      'cy': cy,
      'q': q,
      't': t,
    });
  }

  /// [THERMAL-DOWNSHIFT 2026-08-07] 拍摄期热前瞻降频:喂帧前的热档决策。
  ///
  /// 依据 Apple ProcessInfo.ThermalState 官方建议
  /// (developer.apple.com/documentation/foundation/processinfo/thermalstate):
  ///   - `.serious`:"Reduce usage of the CPU, GPU, and I/O" —— 拍摄期每喂
  ///     1 帧丢 1 次喂帧机会(工作量减半);被"丢"的帧**不删除**,留在
  ///     `_spool` 里等排空期按拍摄序回填(finalize 后转 FIFO,见 _pump 的
  ///     [C2-BACKPRESSURE] 取帧逻辑),交付数据零损失;
  ///   - `.critical`:"reduce work to the minimum level needed" —— 拍摄期
  ///     全部不喂只排队,排空期(_finalizeRequested)不受影响照常喂。
  /// 与 C2 latest-first 共存:本闸只决定"这一轮泵不泵",不改取帧顺序;
  /// 进度条口径零改动(queuedCount/remainingCount 只看长度)。
  /// 注意:本方法带奇偶副作用(_thermalDropArmed),每个喂帧决策点只许调一次。
  bool _thermalAllowsFeedNow() {
    if (_finalizeRequested) return true; // 排空期不丢
    final thermal = PwTelemetry.sample()?.thermalState ?? -1;
    if (thermal >= 3) return false; // critical:只排队
    if (thermal == 2) {
      // serious:喂一帧、歇一次(1:1 隔帧)。
      if (_thermalDropArmed) {
        _thermalDropArmed = false;
        return false;
      }
      _thermalDropArmed = true;
      return true;
    }
    _thermalDropArmed = false; // nominal/fair:闸复位,全速
    return true;
  }

  /// Feeds spooled frames whenever the worker has room; sends the deferred
  /// finalize once everything drained. Single-flight (re-entry guarded).
  Future<void> _pump() async {
    if (_pumping || _disposed) return;
    _pumping = true;
    try {
      while (!_disposed &&
          sfmFeedCanPumpNext(inFlight: _inFlight, spoolDepth: _spool.length)) {
        // [THERMAL-DOWNSHIFT 2026-08-07] 拍摄期热闸:serious 隔帧、critical
        // 停喂(帧留在 spool,排空期回填;排空期本闸恒放行)。break 而非
        // continue —— "歇一次"的语义是这一轮不喂,下一次 frame_done/offer
        // 再泵时重新决策。
        if (!_finalizeRequested && !_thermalAllowsFeedNow()) break;
        // [C2-BACKPRESSURE 2026-08-06 用户签决] 拍摄期 latest-first,排空期
        // FIFO。拍摄期取 _spool 最新一帧优先喂(live 点云跟手,预览永远反映
        // 刚拍到的视角);finalize 请求后(_finalizeRequested)转为取最旧一帧,
        // 按拍摄序回填,与既有排空行为一致。设计依据:
        //   1. 乱序喂帧 A/B 四指标实证安全——注册帧零差、点数 +0.44%、
        //      重投影误差 +1.25%、轨迹长度无损;
        //   2. 空间配对(spatial pairing)不吃喂入顺序,配对集由几何决定;
        //   3. 进度条口径零改动——queuedCount/remainingCount 只看长度,
        //      不看顺序;本改动不丢帧,深度无上限保持,只改处理顺序;
        //   4. AVCapture 的 alwaysDiscardsLateVideoFrames 同向:实时管线
        //      标准做法就是最新优先。
        // 取帧即出队(removeLast/removeAt(0)),不在 await 之后再按索引删,
        // 避免挂起期间新帧 append 使尾部索引漂移。
        // 回滚 = 本处与下方出队两处改回 `_spool.first` / `_spool.removeAt(0)`
        // 的旧形态(严格 FIFO)。
        final entry = _finalizeRequested
            ? _spool.removeAt(0)
            : _spool.removeLast();
        try {
          if (!await File(entry.path).exists()) {
            throw FileSystemException('canonical JPEG missing', entry.path);
          }
          // [EXTRACT-PREFETCH 2026-08-09] 队列里还有下一帧(=堵车,提取在
          // 关键路径上)→ 先把它的路径发给 worker 预取(解码+提取搬到专属
          // 线程,与本帧的匹配并行)。消息序:prefetch 先于 frame,worker
          // 按序处理。env 关时 native no-op,零成本。
          // [PREFETCH-AB 2026-08-09 用户:"不可能跑两遍"] 同场分块交替:
          // OFFICIAL_AETHER_PREFETCH_AB_BLOCK=<n>(launch env)时按 seq 每
          // n 帧翻相位,奇相位块才发预取 ⇒ 一场之内 A(无预取)/B(预取)
          // 交替,同场景同热漂;frame_split 的 pf 命中位标注真实臂。未设=
          // 恒发(生产形态)。跨帧状态刀不能逐帧翻,分块是它的合法交替粒度。
          if (_spool.isNotEmpty && _prefetchAbArmB(entry.seq)) {
            final next = _finalizeRequested ? _spool.first : _spool.last;
            _toWorker.send(<String, Object?>{
              'cmd': 'prefetch',
              'path': next.path,
            });
          }
          _sendJpegFrameCmd(
            entry.seq,
            entry.path,
            entry.w,
            entry.h,
            entry.captureTimestamp,
            entry.fx,
            entry.fy,
            entry.cx,
            entry.cy,
            entry.quatWxyz,
            entry.trans,
          );
        } catch (e) {
          // Unreadable spill — skip this frame rather than stall the queue.
          // ([C2-BACKPRESSURE] entry 已在取帧处出队,此处无需再删。)
          final meta = _pendingMeta.remove(entry.seq);
          _seqOfferMs.remove(entry.seq);
          _seqSentMs.remove(entry.seq);
          _events.add(
            SfmLiveFrameFed(
              seq: entry.seq,
              frameId: -1,
              elapsedMs: 0,
              result: 'missingJpeg',
              jpegPath: meta?.jpegPath ?? entry.path,
            ),
          );
          DeviceLog.log('SfmLive', 'spool #${entry.seq} unreadable: $e');
        }
      }
    } finally {
      _pumping = false;
    }
    _maybeSendFinalize();
  }

  void _maybeSendFinalize() {
    if (_disposed ||
        !sfmFeedCanSendFinalize(
          finalizeRequested: _finalizeRequested,
          finalizeSent: _finalizeSent,
          spoolDepth: _spool.length,
          inFlight: _inFlight,
        )) {
      return;
    }
    // [EXTRACT-DEBT REPAY] 排空完成、finalize 未下发 —— 先还提取欠账。
    // 还账帧重新入 spool 走正常泵;它们的 frame_done 会再次驱动到这里,
    // 欠账清零后才真正下发 finalize。
    if (_extractDebts.isNotEmpty) {
      _repayExtractDebts();
      return;
    }
    if (_debtCpuEnvSet) {
      AetherProcessEnv.unset('OFFICIAL_AETHER_EXTRACT_CPU_FALLBACK');
      _debtCpuEnvSet = false;
    }
    _finalizeSent = true;
    DeviceLog.log('SfmLive', 'queue drained → finalize dispatched');
    // 遥测【finalize/queue_drain】:完成动作 → 队列排空 → finalize 下发。
    TelemetryWriter.instance.event('queue_drain', {
      'ms': _finalizeRequestMs > 0
          ? DateTime.now().millisecondsSinceEpoch - _finalizeRequestMs
          : 0,
      'offered': _seq,
      'fed': _fedOk,
      // [WAIT-BUDGET 2026-07-29] 完成动作那一刻欠了多少帧(见 _finalizeBacklog)。
      // backlog=0 ⇒ 流式跟上了快门,拍摄期成本对用户完全隐形;backlog>0 ⇒ 这
      // 些帧的处理时间就是用户多等的秒数,且 ms/backlog = 每欠一帧的实际代价。
      'backlog': _finalizeBacklog,
      'in_flight': _finalizeInFlight,
    });
    _toWorker.send(const <String, Object?>{'cmd': 'finalize'});
  }

  /// [EXTRACT-DEBT REPAY 2026-08-09] 把欠账帧按拍摄序重新入 spool 补算。
  /// 临时放开 native 的 CPU 兜底闸(拍完等待期安全;finalize 下发前恢复)。
  /// 单次重试:重喂 seq 记入 _debtRefeedSeqs,再失败不三喂、大声上报。
  void _repayExtractDebts() {
    final debts = List<SfmFedFrameMeta>.of(_extractDebts);
    _extractDebts.clear();
    if (!_debtCpuEnvSet) {
      AetherProcessEnv.set('OFFICIAL_AETHER_EXTRACT_CPU_FALLBACK', '1');
      _debtCpuEnvSet = true;
    }
    for (final m in debts) {
      final seq = ++_seq;
      _seqOfferMs[seq] = DateTime.now().millisecondsSinceEpoch;
      _debtRefeedSeqs.add(seq);
      _pendingMeta[seq] = m;
      _spool.add(
        _SpooledFrame(
          seq: seq,
          path: m.jpegPath,
          w: m.imageW,
          h: m.imageH,
          captureTimestamp: m.captureTimestamp ?? 0.0,
          fx: m.fx,
          fy: m.fy,
          cx: m.cx,
          cy: m.cy,
          quatWxyz: m.arkitQuatWxyz != null
              ? Float64List.fromList(m.arkitQuatWxyz!)
              : null,
          trans: m.arkitTransTxyz != null
              ? Float64List.fromList(m.arkitTransTxyz!)
              : null,
        ),
      );
    }
    DeviceLog.log(
      'SfmLive',
      'extract-debt repay: refeeding ${debts.length} frame(s) '
          'with CPU fallback temporarily enabled',
    );
    TelemetryWriter.instance.event('extract_debt_repay', {'n': debts.length});
    unawaited(_pump());
  }

  /// [QUAD-PREPAY 2026-07-26, signed] Drive the capture-idle official
  /// quadratic prepay: only when the frame queue is truly empty (no spooled
  /// frames, nothing in flight), capture still running, and no prepay cmd
  /// already outstanding. The worker answers with repay_done{n}; n>0 chains
  /// the next tick, so idle stretches drain the due-pair queue while a new
  /// frame's cmd always preempts (FIFO ahead of the next repay cmd). Budget
  /// 2 pairs/tick keeps the worst-case added shutter latency to one small
  /// matcher call (~a few hundred ms hot).
  void _maybePrepay() {
    if (_disposed || _finalizeRequested || _prepayInFlight) return;
    if (_spool.isNotEmpty || _inFlight > 0) return;
    _prepayInFlight = true;
    _toWorker.send(const <String, Object?>{'cmd': 'repay', 'budget': 2});
  }

  /// Ends the capture. New frames are refused from this moment; the worker
  /// finishes the disk queue first, then runs finalize_async (phase 1
  /// blocks in-worker; LOCAL_READY and REFINED/ERROR arrive via [events]).
  void finalize() {
    if (_disposed || _finalizeRequested) return;
    _finalizeRequested = true;
    // [SPRINT-FIX] 完成即翻框架内匹配器的 capture_active(排空+enrich 不再
    // 给已停相机让路;旧 silgen 只翻了旧栈副本 —— 07-26 起的哑旗)。
    AetherMatchFlags.setCaptureActive(false);
    _finalizeRequestMs = DateTime.now().millisecondsSinceEpoch; // 遥测
    // 遥测【WAIT-BUDGET】欠债快照必须在这一刻取:_pump() 一旦跑起来 _spool
    // 就开始缩,到 _maybeSendFinalize 时永远是 0。
    _finalizeBacklog = _spool.length;
    _finalizeInFlight = _inFlight;
    if (_spool.isNotEmpty || _inFlight > 0) {
      DeviceLog.log(
        'SfmLive',
        'finalize deferred: inFlight=$_inFlight queued=${_spool.length}',
      );
      // [SPRINT-MODE 2026-07-26] Tell the worker immediately so the drain
      // frames skip interim preview BAs (measured 9.5s of wasted wall time
      // between the finish tap and REFINED on cap_1785070530166049).
      _toWorker.send(const <String, Object?>{'cmd': 'finish_pending'});
      unawaited(_pump());
      return;
    }
    _maybeSendFinalize();
  }

  /// RECOVERY: reconstruct from the existing sqlite db WITHOUT feeding any
  /// frames — the worker opens the retained db and runs finalize_async over it.
  /// Used to retry a capture whose live finalize was interrupted. LOCAL_READY /
  /// REFINED / ERROR arrive via [events] exactly like a normal finalize.
  /// [imageWidth]/[imageHeight] seed the session options only; the reconstruction
  /// reads its geometry from the db, so a nominal capture resolution is fine.
  void resumeFromDb({int imageWidth = 3840, int imageHeight = 2160}) {
    if (_disposed || _finalizeRequested) return;
    _finalizeRequested = true;
    _finalizeSent = true;
    _toWorker.send(<String, Object?>{
      'cmd': 'resume',
      'w': imageWidth,
      'h': imageHeight,
    });
  }

  /// RECOVERY 配套:断点续跑的会话没喂过任何帧,_fedMeta 天然为空 ——
  /// _gravityAlign 找不到 ARKit 四元数会整段跳过(cnt<3),恢复出的点云
  /// 就歪着(41 号 capture 真机实锤)。resume 侧在 resumeFromDb() 之前用
  /// 拍摄期落盘的 official_sfm_fed_frames.jsonl(含 arkitCamFromWorldQwxyz)回填,
  /// 让 refined 事件走与 live 完全同一条 _gravityAlign 调用链。
  void seedFedMeta(Map<int, SfmFedFrameMeta> meta) {
    _fedMeta.addAll(meta);
  }

  /// Persist the SfM-frame-id → color-JPEG mapping (+ the gray dims the
  /// keypoints live in) as a jsonl sidecar next to the db. A later resume reads
  /// it to colorize the recovered cloud with TRUE per-point photo color — the
  /// exact same track-observation sampling the live colorizer does — instead of
  /// having to guess the mapping from disk. One tiny append per registered
  /// frame; best-effort (colorize has a timestamp-order fallback if absent).
  void _persistFedMeta(int frameId, SfmFedFrameMeta m) {
    try {
      final dir = File(_dbPath).parent.path;
      final meta = <String, Object?>{
        'frameId': frameId,
        'jpegPath': m.jpegPath,
        'grayW': m.grayW,
        'grayH': m.grayH,
        if (m.captureTimestamp != null) 'captureTimestamp': m.captureTimestamp,
      };
      if (m.arkitQuatWxyz != null &&
          m.arkitTransTxyz != null &&
          m.arkitCameraCenterWorld != null) {
        meta.addAll(<String, Object?>{
          // [07-28 勘误] 旧标签让外部分析误以为已做 COLMAP 相机系翻转;
          // 实际存的是 ARKit 相机轴约定的 CamFromWorld(C=diag(1,-1,-1)
          // **未**应用——gravity align 公式 R_w=R_ark^T·C·R_col 自带 C,
          // 吃的就是 raw)。标签改为显式声明,数据一字未动。
          'arkitPoseConvention':
              'worldAlignment.gravity; CamFromWorld inverted from ARKit '
              'cameraToWorld, in ARKit CAMERA AXES (COLMAP C=diag(1,-1,-1) '
              'flip NOT applied); plus camera center in world',
          'arkitCamFromWorldQwxyz': m.arkitQuatWxyz,
          'arkitCamFromWorldTxyz': m.arkitTransTxyz,
          'arkitCameraCenterWorld': m.arkitCameraCenterWorld,
        });
      }
      final line = '${jsonEncode(meta)}\n';
      File('$dir/official_sfm_fed_frames.jsonl')
          .writeAsStringSync(line, mode: FileMode.append, flush: false);
    } catch (_) {}
  }

  /// Frees the native session (joins the background BA thread, drops the
  /// sqlite db) and tears the isolate down. Safe to call more than once.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Queue entries reference canonical capture evidence; never delete them.
    _spool.clear();
    final ack = _disposeAck = Completer<void>();
    try {
      _toWorker.send(const <String, Object?>{'cmd': 'dispose'});
      // aether_sfm_free may legitimately block while joining a running
      // global-BA thread; give it generous room before force-killing.
      await ack.future.timeout(const Duration(seconds: 120));
    } catch (_) {
      // Timeout/port death — fall through to kill.
    } finally {
      try {
        await _sub.cancel();
      } catch (_) {
        // Continue deterministic termination and lease release.
      }
      _fromWorker.close();
      _isolate.kill(priority: Isolate.immediate);
      try {
        await _events.close();
      } finally {
        reconstructionLease.release(_leaseOwner);
        unawaited(_photoArchiveActivityLease.close());
      }
    }
  }

  void _onWorkerMessage(dynamic msg) {
    if (msg is! Map) return;
    switch (msg['evt']) {
      case 'log':
        // Worker isolates must not touch DeviceLog (path cache lives on the
        // main isolate) — they forward lines here instead.
        DeviceLog.log('SfmLive.worker', msg['line'] as String? ?? '');
      case 'telem':
        // Worker 遥测汇聚:worker isolate 不持有文件 sink,结构化事件经
        // 本 reply port 汇到主 isolate 的单写手(行完整性由单 sink 保证)。
        {
          final data = msg['data'];
          TelemetryWriter.instance.event(msg['type'] as String? ?? 'worker', {
            'iso': 'worker',
            if (data is Map)
              ...data.map((k, v) => MapEntry(k.toString(), v as Object?)),
          });
          // 修1【等待页阶段透明化】:phase-1 完成的遥测行同时就是 UI 的
          // 阶段边界(此后 worker 只在 refined/error 时才再发事件,中间是
          // 分钟级的后台全局 BA)——转发一个轻量事件给等待页推进文案。
          if (msg['type'] == 'finalize_phase1') {
            _events.add(const SfmLiveFinalizePhase1Done());
          }
        }
      case 'frame_done':
        _inFlight = _inFlight > 0 ? _inFlight - 1 : 0;
        final ok = msg['result'] == 'ok';
        final seq = msg['seq'] as int;
        final frameId = msg['frameId'] as int;
        final meta = _pendingMeta.remove(seq);
        final removeAfterAck = meta == null
            ? null
            : _removeWhenFrameAcked.remove(meta.jpegPath);
        if (meta != null && frameId >= 0) {
          _nativeFrameIdByJpegPath[meta.jpegPath] = frameId;
        }
        if (ok && removeAfterAck == null) _fedOk++;
        if (removeAfterAck != null) {
          if (frameId >= 0) {
            unawaited(
              _requestNativeFrameRemoval(frameId).then((removed) {
                if (!removeAfterAck.isCompleted) {
                  removeAfterAck.complete(removed);
                }
              }),
            );
          } else if (!removeAfterAck.isCompleted) {
            // The frame never entered native SfM, so there is no contribution
            // to withdraw even though the add-frame result itself failed.
            removeAfterAck.complete(true);
          }
        } else if (ok && meta != null && frameId >= 0) {
          _fedMeta[frameId] = meta;
          _persistFedMeta(frameId, meta);
        }
        // [EXTRACT-DEBT REPAY] 提取失败的帧记欠账(照片在盘上、pose 在 meta
        // 里,什么都不缺,只是晚算)。正被删除的帧(removeAfterAck)不欠;
        // 补喂仍失败的帧(_debtRefeedSeqs)不再入账 —— 单次重试,失败大声上报。
        if (msg['result'] == 'errExtract' && meta != null) {
          if (_debtRefeedSeqs.remove(seq)) {
            DeviceLog.log(
              'SfmLive',
              'extract-debt REPAY FAILED (CPU fallback also failed): '
                  '${meta.jpegPath.split('/').last} — frame missing from '
                  'delivery, ESCALATE',
            );
            TelemetryWriter.instance.event('extract_debt_repay_failed', {
              'jpeg': meta.jpegPath.split('/').last,
            });
          } else if (removeAfterAck == null) {
            _extractDebts.add(meta);
            DeviceLog.log(
              'SfmLive',
              'extract-debt recorded (#${_extractDebts.length}): '
                  '${meta.jpegPath.split('/').last} — repay before finalize',
            );
            TelemetryWriter.instance.event('extract_debt_recorded', {
              'jpeg': meta.jpegPath.split('/').last,
              'debts': _extractDebts.length,
            });
          }
        } else {
          _debtRefeedSeqs.remove(seq);
        }
        // Consolidated per-frame telemetry: timing (worker) + queue state
        // (facade owns the disk spool) + memory/thermal (worker peak sample).
        // One grep-able line — `[TELEM]` — for the whole capture profile.
        final ms = msg['ms'] as int;
        final memMb = msg['memMb'] as double?;
        final peakMb = msg['peakMb'] as double?;
        final thermal = msg['thermal'] as int?;
        final thermalName = switch (thermal) {
          0 => 'nominal',
          1 => 'fair',
          2 => 'serious',
          3 => 'critical',
          _ => '?',
        };
        DeviceLog.log(
          'TELEM',
          'frame#$seq fid=$frameId ${ok ? 'ok' : msg['result']} '
              'proc=${ms}ms | queue=${_spool.length} inflight=$_inFlight '
              'offered=$_seq fed=$_fedOk | '
              'mem=${memMb?.toStringAsFixed(0) ?? '?'}MB '
              'peak=${peakMb?.toStringAsFixed(0) ?? '?'}MB '
              'thermal=$thermalName',
        );
        // ── 遥测【frame】结构化行:worker 已算好的字段(计时/提取/匹配/
        // 内存/热)+ facade 独有的队列态与时间戳,汇成一行 JSONL。
        // 全部数据都在手上,零重复计算。
        {
          final offerMs = _seqOfferMs.remove(seq);
          final sentMs = _seqSentMs.remove(seq);
          final extractMs = msg['extractMs'] as double?;
          TelemetryWriter.instance.event('frame', {
            'seq': seq,
            'fid': frameId,
            'result': msg['result'],
            if (meta != null) 'jpeg': meta.jpegPath.split('/').last,
            't_offer': ?offerMs,
            't_fed': ?sentMs,
            if (offerMs != null && sentMs != null)
              'spool_wait_ms': sentMs - offerMs,
            'proc_ms': ms,
            'queue': _spool.length,
            'inflight': _inFlight,
            'offered': _seq,
            'fed': _fedOk,
            if (extractMs != null) 'extract_ms': extractMs.round(),
            // ②【标签修准 2026-07-11】原 'cpu_suspect' 是误诊:>2000ms 只说明
            // 提取慢(热降频下 GPU 提取本身就能超 2s,45 号实锤),并不能
            // 证明走了 CPU 回退——native 没有显式回退标志,别再把慢当路径。
            if (extractMs != null)
              'extract_path': extractMs > 2000 ? 'slow_extract' : 'gpu',
            if (msg['matchMs'] != null)
              'match_ms': (msg['matchMs'] as double).round(),
            if (msg['nCand'] != null) 'n_cand': msg['nCand'],
            if (msg['gpuPairs'] != null) 'gpu_pairs': msg['gpuPairs'],
            if (msg['cpuPairs'] != null) 'cpu_pairs': msg['cpuPairs'],
            // ④【热调速器】累计被降档帧数(native 计数器;缺省=旧 .a)。
            if (msg['throttledCum'] != null)
              'throttled_cum': msg['throttledCum'],
            if (msg['growAcc'] != null) 'grow_acc_cum': msg['growAcc'],
            if (msg['growRej'] != null) 'grow_rej_cum': msg['growRej'],
            if (msg['tvgPairs'] != null) 'tvg_pairs_cum': msg['tvgPairs'],
            if (msg['rawPairs'] != null) 'raw_pairs_cum': msg['rawPairs'],
            if (memMb != null) 'mem_mb': memMb.round(),
            if (peakMb != null) 'peak_mb': peakMb.round(),
            'thermal': ?thermal,
          });
        }
        _events.add(
          SfmLiveFrameFed(
            seq: seq,
            frameId: frameId,
            elapsedMs: ms,
            result: msg['result'] as String,
            jpegPath: meta?.jpegPath,
          ),
        );
        // Worker slot freed — feed the next spooled frame (and dispatch the
        // deferred finalize once everything drained).
        unawaited(_pump());
        // [QUAD-PREPAY 2026-07-26, signed] Queue empty → spend the idle gap
        // prepaying official quadratic pairs so finish-time debt → 0.
        _maybePrepay();
      case 'repay_done':
        _prepayInFlight = false;
        // Chain while native reports work remained AND we are still idle —
        // a newly arriving frame naturally preempts (its cmd is FIFO-ahead
        // of the next repay cmd, and _maybePrepay refuses while busy).
        if (((msg['n'] as int?) ?? 0) > 0) _maybePrepay();
      case 'frame_removed':
        final requestId = msg['requestId'] as int;
        final frameId = msg['frameId'] as int;
        final removed = msg['ok'] == true;
        if (removed) {
          final hadFrame = _fedMeta.remove(frameId) != null;
          if (hadFrame && _fedOk > 0) _fedOk--;
          _nativeFrameIdByJpegPath.removeWhere(
            (_, mappedFrameId) => mappedFrameId == frameId,
          );
        }
        final completer = _removeRequests.remove(requestId);
        if (completer != null && !completer.isCompleted) {
          completer.complete(removed);
        }
        DeviceLog.log(
          'SfmLive',
          'user remove frameId=$frameId ok=$removed stats=${msg['stats']}',
        );
      case 'preview':
        // Preview xyz is already in ARKit's gravity-aligned metric world. It
        // shares the payload shape with local_ready but not its coordinate-space
        // contract, so final alignment must not be run a second time.
        final snapshot = _gravityAlign(
          _snapshotFromMsg(msg, refined: false),
          stage: _AlignmentSnapshotStage.preview,
        );
        final sourceReceiveSeq = ++_liveCloudSourceReceiveSequence;
        final sourceReceiveAt = DateTime.now().millisecondsSinceEpoch;
        snapshot.summary['diag_source_receive_seq'] = sourceReceiveSeq;
        snapshot.summary['diag_source_receive_t'] = sourceReceiveAt;
        final source = snapshot.summary['source']?.toString() ?? 'unknown';
        final publishVersion =
            (snapshot.summary['publish_version'] as num?)?.toInt() ?? 0;
        TelemetryWriter.instance.event('live_cloud_source_receive_v2', {
          'contract': 'PW_LIVE_CLOUD_DIAG_RUNTIME_V2_20260810',
          'source_receive_seq': sourceReceiveSeq,
          'source_receive_t': sourceReceiveAt,
          'source': source,
          'publish_version': publishVersion,
          'points': snapshot.pointCount,
          'observation_only': true,
        });
        DeviceLog.log(
          'LIVE_CLOUD_DIAG_V2',
          'source_receive seq=$sourceReceiveSeq source=$source '
              'version=$publishVersion points=${snapshot.pointCount}',
        );
        _events.add(SfmLivePreview(snapshot));
      case 'live_poses':
        // 拍摄期逐帧连通性(合成 posesPacked,契约见 SfmLiveConnectivity)。
        _events.add(
          SfmLiveConnectivity(msg['poses'] as Float64List? ?? Float64List(0)),
        );
      case 'live_parallax':
        // 拍摄期真实三角化角(route B,契约见 SfmLiveTrueParallax)。
        _events.add(
          SfmLiveTrueParallax(
            framesPacked: msg['frames'] as Float64List? ?? Float64List(0),
            voxelKeys: msg['voxKeys'] as Int64List? ?? Int64List(0),
            voxelDeg: msg['voxDeg'] as Float32List? ?? Float32List(0),
            computeMs: msg['ms'] as int? ?? -1,
            sampledPoints: msg['sampled'] as int? ?? 0,
          ),
        );
      case 'local_ready':
        // [WAIT-BUDGET 2026-07-29] finalize 墙钟落遥测。此前这个数只进 Dart
        // 事件(等待页文案用),没有落盘 —— 而它是「用户等待」的第二个分量
        // (第一个是 queue_drain 的欠债排空)。host 上这个数在同一 fixture 的
        // 两次重跑间摆动 36.3s↔66.3s(83%),所以判决只能来自真机多次采集。
        TelemetryWriter.instance.event('finalize_wall', {
          'phase': 'local_ready',
          'ms': msg['ms'] as int? ?? -1,
        });
        _events.add(
          SfmLiveLocalReady(
            _gravityAlign(
              _snapshotFromMsg(msg, refined: false),
              stage: _AlignmentSnapshotStage.localReady,
            ),
            msg['ms'] as int,
          ),
        );
      case 'refined':
        TelemetryWriter.instance.event('finalize_wall', {
          'phase': 'refined',
          'ms': msg['ms'] as int? ?? -1,
        });
        _events.add(
          SfmLiveRefined(
            _gravityAlign(
              _snapshotFromMsg(msg, refined: true),
              stage: _AlignmentSnapshotStage.refined,
            ),
            msg['ms'] as int,
          ),
        );
      // [增量D 2026-07-28] 鬼层 L1/L2 链的最后残件(arbitrate_done 处理器 +
      // SfmLiveArbitrateDone 事件 + FFI 绑定)已删。链本体 07-20 E25 用户
      // 签决停用(四重理由:违认证铁律/parity 参考丢失/rescue 位零消费者/
      // 全网无先例;实测每采集烧 10.7s 产出没人读的位)。复活走 git 历史。
      case 'error':
        // 遥测【finalize/error】:终态失败一行(stage=add_frame/finalize/refine)。
        TelemetryWriter.instance.event('sfm_error', {
          'stage': msg['stage'],
          'message': '${msg['message']}',
        });
        _events.add(
          SfmLiveFailed(
            msg['stage'] as String? ?? 'unknown',
            msg['message'] as String? ?? 'unknown',
          ),
        );
      case 'disposed':
        _disposeAck?.complete();
    }
  }

  /// Rotates the reconstruction upright using the ARKit gravity frame.
  ///
  /// COLMAP's world gauge is arbitrary — the cloud comes out tilted at a
  /// random orientation. ARKit ran with worldAlignment=.gravity (world Y =
  /// up), and we fed its CamFromWorld per frame. For each registered frame,
  ///   R_w = R_ark^T · C · R_col
  /// is the rotation that carries COLMAP world → ARKit (gravity) world; the
  /// per-frame estimates cluster tightly (same rigid alignment), so a naive
  /// sign-aligned quaternion mean is robust. We rotate every point by the
  /// mean R_w so the floor is horizontal and +Y is up — the viewer then needs
  /// no arbitrary default tilt. Points only (poses left as COLMAP; nothing
  /// downstream pairs them with the aligned points). Falls back to the
  /// original cloud when fewer than 3 registered frames carry an ARKit quat.
  ///
  /// 数学与门限在 gravity_align.dart(逐字提出的纯函数,live 与断点续跑
  /// 共用同一实现;tool/gravity_align_check.dart 有纯 Dart VM 断言)。
  SfmLiveSnapshot _gravityAlign(
    SfmLiveSnapshot snap, {
    required _AlignmentSnapshotStage stage,
  }) {
    if (stage == _AlignmentSnapshotStage.preview) {
      TelemetryWriter.instance.event('preview_skip', {
        'schema_version': 1,
        'phase': 'preview',
        'reason': 'already_arkit_gravity_metric',
        'gravity_status': 'not_required',
        'scale_status': 'not_required',
        'n_points': snap.pointCount,
      });
      return snap;
    }

    final stageTelemetry = stage == _AlignmentSnapshotStage.refined
        ? <String, Object?>{'phase': 'refined', 'authority': 'authoritative'}
        : <String, Object?>{
            'phase': 'local_ready',
            'authority': 'fallback_candidate',
          };

    void emitFinalAlignmentResult({
      required String gravityStatus,
      required String? gravityReason,
      required List<double>? gravityQuatWxyz,
      required String scaleStatus,
      required String? scaleReason,
      required double? scaleFactor,
      required GravityAlignDiagV1 gravityDiag,
      ScaleAnchorDiagV1? scaleDiag,
    }) {
      TelemetryWriter.instance.event('final_alignment_result', {
        'schema_version': 1,
        ...stageTelemetry,
        'gravity_status': gravityStatus,
        'gravity_reason': gravityReason,
        'gravity_quat_wxyz': gravityQuatWxyz,
        'registered_frames': gravityDiag.registeredFrames,
        'frames_with_arkit_quat': gravityDiag.framesWithArkitQuat,
        'required_frames': gravityDiag.requiredFrames,
        'scale_status': scaleStatus,
        'scale_reason': scaleReason,
        'scale_factor': scaleFactor,
        'scale_registered_frames': scaleDiag?.registeredFrames,
        'scale_pairs_with_arkit_center': scaleDiag?.pairsWithArkitCenter,
        'scale_usable_ratios': scaleDiag?.usableRatios,
        'scale_required_pairs': scaleDiag?.requiredPairs,
        'scale_rejected_factor': scaleDiag?.rejectedFactor,
        'fed_meta_size': _fedMeta.length,
        'n_points': snap.pointCount,
      });
    }

    // [GRAV-CONSIST 2026-07-28] 整模型一致变换:点与位姿吃同一个 R_w
    // (COLMAP Reconstruction::Transform 语义;此前只转点、posesPacked 留
    // raw,形成"混合帧工件对",行业查无先例)。raw 位姿以显式字段保留
    // (host parity 复核需要逐位真值,浮点逆旋转不保逐位),R_w 本体也
    // 随快照落盘(nerfstudio dataparser_transforms.json 先例)。
    // [GRAV-DIAG 2026-07-30] 重力对齐是 fail-open 的 —— 拿不到 R_w 就原样交付。
    // 这一点保留(歪的云胜过没有云),但**静默**去掉:用户在编辑页用肉眼发现
    // 点云是歪的,而日志里一个字都没有,只能事后翻 meta 的
    // gravity_align_quat_wxyz 是否为 null。现在跳过即上报,含成因与计数。
    final diag = GravityAlignDiagV1();
    final q = gravityAlignQuatWxyz(
      posesPacked: snap.posesPacked,
      arkitQuatWxyzOf: (frameId) => _fedMeta[frameId]?.arkitQuatWxyz,
      diag: diag,
    );
    if (q == null || snap.xyz.isEmpty) {
      // xyz 为空是合法空结果(0 特征帧),不是重力故障 —— 分开标注,免得把
      // 空重建计成对齐失败。
      final reason = snap.xyz.isEmpty
          ? 'empty_cloud'
          : (diag.skipReason ?? 'unknown');
      emitFinalAlignmentResult(
        gravityStatus: 'skipped',
        gravityReason: reason,
        gravityQuatWxyz: null,
        scaleStatus: 'skipped',
        scaleReason: 'gravity_not_applied',
        scaleFactor: null,
        gravityDiag: diag,
      );
      DeviceLog.log(
        'SfmLive',
        'gravity align SKIPPED (reason=$reason '
            'registered=${diag.registeredFrames} '
            'withArkitQuat=${diag.framesWithArkitQuat}/${diag.requiredFrames} '
            'fedMeta=${_fedMeta.length} refined=${snap.refined}) '
            '→ delivering UNALIGNED cloud',
      );
      return snap;
    }
    // [SCALE-ANCHOR 2026-07-28] 实验臂,默认关(env OFFICIAL_AETHER_SCALE_
    // ANCHOR=1 开):把交付模型的 gauge 尺度锚回 ARKit 米制(±4% 系统性
    // 滑移,裁决见 gravity_align.dart 的 scaleAnchorFactor 注释)。相似
    // 变换保持全部重投影残差 —— 质量零扰动,只改坐标刻度。fail-open:
    // 估计失败即不缩放。
    // [SCALE-DIAG 2026-07-30] 同 GRAV-DIAG 的动机,但这一条更要紧:SCALE-ANCHOR
    // 是**生产开启**的臂,它的五个 fail-open 分支此前全部静默 —— 交付物的尺度
    // 可能压根没锚回米制,而没有任何信号。其中 scale_out_of_band 不是"数据不够"
    // 而是"量到了却拒绝施加",所以被拒的 s 必须一起上报。
    final scaleDiag = _scaleAnchorEnabled ? ScaleAnchorDiagV1() : null;
    final double? s = _scaleAnchorEnabled
        ? scaleAnchorFactor(
            posesPacked: snap.posesPacked,
            arkitCenterWorldOf: (frameId) =>
                _fedMeta[frameId]?.arkitCameraCenterWorld,
            diag: scaleDiag,
          )
        : null;
    if (scaleDiag != null && s == null) {
      DeviceLog.log(
        'SfmLive',
        'scale anchor SKIPPED (reason=${scaleDiag.skipReason} '
            'registered=${scaleDiag.registeredFrames} '
            'pairs=${scaleDiag.pairsWithArkitCenter}/${scaleDiag.requiredPairs} '
            'ratios=${scaleDiag.usableRatios} '
            'rejected_s=${scaleDiag.rejectedFactor?.toStringAsFixed(4) ?? '-'}) '
            '→ delivering UNSCALED (raw BA gauge)',
      );
    }
    emitFinalAlignmentResult(
      gravityStatus: 'applied',
      gravityReason: null,
      gravityQuatWxyz: q,
      scaleStatus: !_scaleAnchorEnabled
          ? 'disabled'
          : (s != null ? 'applied' : 'skipped'),
      scaleReason: !_scaleAnchorEnabled
          ? 'feature_disabled'
          : (s == null ? (scaleDiag?.skipReason ?? 'unknown') : null),
      scaleFactor: s,
      gravityDiag: diag,
      scaleDiag: scaleDiag,
    );
    var xyz = rotatePointsByQuatWxyz(snap.xyz, q);
    var poses = gravityAlignedPosesPacked(snap.posesPacked, q);
    if (s != null) {
      xyz = scaleAnchoredPoints(xyz, s);
      poses = scaleAnchoredPosesPacked(poses, s);
    }
    return SfmLiveSnapshot(
      xyz: xyz,
      rgb: snap.rgb,
      posesPacked: poses,
      summary: snap.summary,
      refined: snap.refined,
      obsOffsets: snap.obsOffsets,
      obsFrameIds: snap.obsFrameIds,
      obsXY: snap.obsXY,
      gravityAlignQuatWxyz: q,
      posesPackedRawColmap: snap.posesPacked,
      scaleAnchorFactor: s,
    );
  }

  /// [SCALE-ANCHOR] 默认关;插件 setenv 后进程内可见。static final:
  /// 每次采集会话读一次即可(env 在进程生命周期内不变)。
  static final bool _scaleAnchorEnabled =
      Platform.environment['OFFICIAL_AETHER_SCALE_ANCHOR'] == '1';

  static SfmLiveSnapshot _snapshotFromMsg(Map msg, {required bool refined}) {
    return SfmLiveSnapshot(
      xyz: msg['xyz'] as Float32List? ?? Float32List(0),
      rgb: msg['rgb'] as Uint8List? ?? Uint8List(0),
      posesPacked: msg['poses'] as Float64List? ?? Float64List(0),
      summary:
          (msg['summary'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
      refined: refined,
      obsOffsets: msg['obsOffsets'] as Int32List? ?? Int32List(1),
      obsFrameIds: msg['obsFrameIds'] as Int32List? ?? Int32List(0),
      obsXY: msg['obsXY'] as Float32List? ?? Float32List(0),
    );
  }
}

// ─── worker isolate ──────────────────────────────────────────────────

class _SfmWorkerBootstrap {
  const _SfmWorkerBootstrap(this.reply, this.dbPath, this.arEveryFrame);
  final SendPort reply;
  final String dbPath;
  // [AR-EVERY-FRAME 2026-08-05 ROOT-CAUSE FIX] 必须经 boot 消息传入,不能让
  // worker 直接读 env:worker 是 Isolate.spawn 出来的独立 isolate,其
  // Platform.environment **读不到** 主 isolate 里 native setenv 设的值(实测:
  // scale-anchor 在 _gravityAlign=主 isolate 读所以生效,而本 flag 曾在 worker
  // 读恒为 false,导致每帧推送整条从不触发)。env 只在主 isolate 有效,故在
  // spawn 处(主 isolate)读好、随 boot 传进来。
  final bool arEveryFrame;
}

void _sfmWorkerMain(_SfmWorkerBootstrap boot) {
  final cmds = ReceivePort();
  boot.reply.send(cmds.sendPort);
  // [AR-EVERY-FRAME 观测] 让 flag 的到达值在设备日志可见——上一版正是这条
  // 通路断了(worker 读 env 恒 false)而无声失败。下次真机测试 grep 此行即可确认。
  boot.reply.send(<String, Object?>{
    'evt': 'log',
    'line': 'worker up: arEveryFrame=${boot.arEveryFrame}',
  });

  AetherSfmStreamSession? session;
  Timer? pollTimer;
  var refineStart = 0;
  var disposed = false;
  // [SPRINT-MODE 2026-07-26, signed] finish tapped → the drain frames still
  // feed (their matches/observations are delivery data), but the periodic
  // streaming-global-BA PREVIEW publishes stop: the user is on the
  // processing screen, and cap_1785070530166049 measured a 9.5s preview BA
  // running after the finish tap — pure wasted wall time before REFINED.
  // Finalize's own stage-1/stage-2 refinement redoes this work to its own
  // convergence criteria, so skipping interim preview BAs sheds no data.
  var finishPending = false;
  // [SPRINT-RACE 2026-07-26, signed] The finish_pending message travels the
  // same FIFO as frame events, so a finish tapped while a frame event is
  // mid-flight cannot flip the flag in time to stop THAT event's preview BA
  // (cap4 lost 9.5s exactly this way). Swift flips the matcher's
  // gCaptureActive atomic synchronously in stopSession — an FFI read closes
  // the window. Unresolvable symbol → assume active (legacy behaviour).
  _CaptureActiveDart? captureActiveFn;
  var captureActiveResolved = false;
  bool nativeCaptureActive() {
    if (!captureActiveResolved) {
      captureActiveResolved = true;
      try {
        captureActiveFn = ffi.DynamicLibrary.process()
            .lookupFunction<_CaptureActiveC, _CaptureActiveDart>(
              'aether_gpu_match_get_capture_active',
            );
      } catch (_) {
        // Symbol absent (host tests / old binary) — gate stays message-only.
      }
    }
    final fn = captureActiveFn;
    return fn == null || fn() != 0;
  }

  // True session high-water footprint — the public TASK_VM_INFO layout has no
  // historical peak field, so we take a running max of the instantaneous
  // sample taken right after each heavy native call.
  var peakMb = 0.0;
  // 已成功喂入的 frameId(卡片边框连通性的全集)+ 连通性事件节流时钟。
  final fedIds = <int>[];
  final publishPolicy = OfficialLiveSfmPublishPolicy();
  var lastConnectivityMs = 0;
  // Route B(真实三角化角):已喂帧的 ARKit 相机中心(gravity 世界系,
  // 与 previewTracked 的点同一世界 —— 流式云在 ARKit 世界三角化)+
  // 真实视差聚合的独立节流时钟(3.5s,比连通性 1.2s 慢:previewTracked
  // 拷贝复用连通性那一份,聚合本身才是本节流管的增量成本)。
  final frameCenters = <int, List<double>>{};
  var lastTrueParallaxMs = 0;

  void wlog(String line) {
    boot.reply.send(<String, Object?>{'evt': 'log', 'line': line});
  }

  /// 遥测:worker 侧结构化事件经 reply port 汇聚到主 isolate 的
  /// TelemetryWriter 单写手(见 facade 的 'telem' case)。发送即完成,
  /// 不等写盘 —— worker 的重算路径零阻塞。
  void telem(String type, Map<String, Object?> data) {
    boot.reply.send(<String, Object?>{
      'evt': 'telem',
      'type': type,
      'data': data,
    });
  }

  /// 连通性合成 poses(契约见 SfmLiveConnectivity):[obsFrameIds] 里出现
  /// 过的已喂帧 = 已连通(registered=1,该帧在 live recon 有 ≥1 个 track
  /// 观测),其余已喂帧 = 断联(registered=0)。四元数/平移全 0 ——
  /// _gravityAlign 的 norm 门会自然跳过它们(刻意:流式云已在 ARKit
  /// gravity 世界,绝不能再旋转)。
  Float64List connectivityPosesFrom(Int32List obsFrameIds) {
    if (fedIds.isEmpty) return Float64List(0);
    final connected = <int>{};
    for (final f in obsFrameIds) {
      connected.add(f);
    }
    final out = Float64List(fedIds.length * 9);
    for (var i = 0; i < fedIds.length; i++) {
      out[i * 9] = fedIds[i].toDouble();
      out[i * 9 + 1] = connected.contains(fedIds[i]) ? 1 : 0;
    }
    return out;
  }

  /// Packs + sends a full track-annotated snapshot (points + per-point track
  /// observations → the colorizer input). When [preview] is true it reads the
  /// LIVE streaming local-BA reconstruction (`previewTracked`) instead of the
  /// finalize output (`pointsTracked`). Returns false — sending nothing — when
  /// the requested reconstruction is empty; for a preview that means the session
  /// has no live_recon (a resumed-from-db session), so the caller falls through
  /// to the cold finalize.
  bool sendSnapshot(
    String evt,
    Map<String, dynamic> summary,
    int ms, {
    bool preview = false,
    AetherSfmPointsTracked? prefetched,
  }) {
    final s = session;
    if (s == null) return false;
    // [AR-EVERY-FRAME] prefetched reuses a points object the caller already
    // pulled this frame (beforeGlobal), avoiding a second full previewTracked
    // copy. Default null ⇒ byte-exact prior behaviour.
    final points =
        prefetched ?? (preview ? s.previewTracked() : s.pointsTracked());
    // [REMOVE-REFRESH 2026-08-09] frame_removed 来源豁免空云拦截:删除到空时
    // 必须把"空"推出去,否则 AR 永远显示删除前的旧云。其余来源维持原语义。
    if (preview && points.count == 0 && !summary.containsKey('frame_removed')) {
      return false; // no live_recon → fall back
    }
    final deliveredSummary = Map<String, dynamic>.from(summary);
    if (!preview) {
      final detail = s.streamStats();
      deliveredSummary['temporal_detail_created'] =
          detail.temporalDetailCreated;
      deliveredSummary['temporal_detail_grown'] = detail.temporalDetailGrown;
      wlog(
        'temporal-detail: pairs=${detail.temporalDetailPairs} '
        'inliers=${detail.temporalDetailMatches} '
        'created=${detail.temporalDetailCreated} '
        'grown=${detail.temporalDetailGrown} | reject '
        'cheirality=${detail.temporalDetailRejectCheirality} '
        'reproj=${detail.temporalDetailRejectReproj} '
        'tri-angle=${detail.temporalDetailRejectTriAngle} '
        'conflicts=${detail.temporalDetailConflicts}',
      );
      // Production ships the exact COLMAP endpoint: final global BA followed by
      // COLMAP's own filtering. No Dart point deletion is allowed here.
      deliveredSummary['spatial_two_view_filtered'] = 0;
      deliveredSummary['delivered_points'] = points.count;
      wlog(
        'official-endpoint: delivered=${points.count} '
        'after native final BA/filtering; Dart filtering disabled',
      );
      // 遥测【finalize/snapshot】:交付快照的点/观测/过滤/细节恢复计数
      // (数据已在手上,顺手记)。
      telem('finalize_snapshot', {
        'evt': evt,
        'points_delivered': points.count,
        'obs': points.obsCount,
        'spatial_two_view_filtered': 0,
        'temporal_detail_created': detail.temporalDetailCreated,
        'temporal_detail_grown': detail.temporalDetailGrown,
        'temporal_detail_pairs': detail.temporalDetailPairs,
        'temporal_detail_inliers': detail.temporalDetailMatches,
        'ms': ms,
      });
    }
    // posesPacked() reads the FINALIZE recon (s->recon), which is empty until the
    // deferred global BA runs — so for the streaming preview it carries nothing
    // useful (and would exercise get_poses' not-registered path). Preview
    // snapshots instead carry the SYNTHETIC connectivity poses(只有
    // [frameId, registered] 有效,四元数全 0,契约见 SfmLiveConnectivity)
    // — the zero quats keep _gravityAlign a no-op, which is REQUIRED: the
    // streaming cloud is already in ARKit gravity-world (points triangulated
    // in ARKit world, the windowed BA gauge pinned to ARKit-world points) and
    // must not be rotated again.
    final poses = preview
        ? connectivityPosesFrom(points.obsFrameIds)
        : s.posesPacked();
    wlog(
      '$evt: points=${points.count} obs=${points.obsCount} '
      'poses=${poses.length ~/ 9} ms=$ms summary=$deliveredSummary',
    );
    if (preview) {
      final st = s.streamStats();
      final cand = s.candidateStats();
      final tvgPct = (st.tvgPairs + st.rawPairs) > 0
          ? (100 * st.tvgPairs / (st.tvgPairs + st.rawPairs)).round()
          : 0;
      wlog(
        'stream-stats: tvg-inlier pairs=${st.tvgPairs} raw-fallback=${st.rawPairs} '
        '($tvgPct% verified) | grow accept=${st.growAccepted} '
        'reject=${st.growRejected} | filtered reproj=${st.reprojFiltered} '
        'tri-angle=${st.triFiltered} | candidates '
        'spatial-first=${cand.spatialFirstPairs} '
        'temporal-fallback=${cand.temporalFallbackPairs}',
      );
      wlog(
        'stream-gates: grow reject cheirality=${st.growRejectCheirality} '
        'reproj=${st.growRejectReproj} | create reject '
        'cheirality=${st.createRejectCheirality} '
        'tri-angle=${st.createRejectTriAngle} '
        'reproj=${st.createRejectReproj} | assigned same=${st.alreadyAssigned} '
        'merge-needed=${st.mergeNeeded} accepted=${st.mergeAccepted} '
        'rejected=${st.mergeRejected} | spatial considered='
        '${st.spatialConsidered} attempted=${st.spatialAttempted} '
        'written=${st.spatialWritten} inliers=${st.spatialInliers}',
      );
      wlog(
        'spatial-loop: anchors=${st.spatialAnchorPassed}/'
        '${st.spatialAnchorAttempted} regions=${st.spatialRegionsConfirmed} '
        'expand-attempted=${st.spatialExpandedAttempted} guided='
        '${st.spatialGuidedPairs}/${st.spatialGuidedInliers}candidates '
        'quadratic=${st.spatialQuadraticWritten}/'
        '${st.spatialQuadraticAttempted} budget-skipped='
        '${st.spatialBudgetSkipped}',
      );
    }
    boot.reply.send(<String, Object?>{
      'evt': evt,
      'xyz': points.xyz,
      'rgb': points.rgb,
      'poses': poses,
      'obsOffsets': points.obsOffsets,
      'obsFrameIds': points.obsFrameIds,
      'obsXY': points.obsXY,
      'summary': deliveredSummary,
      'ms': ms,
    });
    return true;
  }

  void fail(String stage, Object message) {
    wlog('ERROR at $stage: $message');
    boot.reply.send(<String, Object?>{
      'evt': 'error',
      'stage': stage,
      'message': '$message',
    });
  }

  cmds.listen((dynamic msg) {
    if (msg is! Map || disposed) return;
    switch (msg['cmd']) {
      case 'jpeg_frame':
        final sw = Stopwatch()..start();
        final w = msg['w'] as int;
        final h = msg['h'] as int;
        try {
          // Lazy create: the session's image_width/height must equal the fed
          // gray dimensions, which are only known at the first keyframe.
          if (session == null) {
            session = AetherSfmStreamSession.create(
              boot.dbPath,
              imageWidth: w,
              imageHeight: h,
              // A/B (2026-07-08): tried 12288 to keep the ~10k raw keypoints
              // peak=0.004 finds, but on the 4K gray it made per-frame extract
              // heavy enough that the SfM worker couldn't keep up — the feed
              // queue exploded (32 deep) and the heavy extract starved the
              // photo-capture path (shutter unresponsive, frame count stuck).
              // Reverted to 8192: 0.004 + 8192 was the balanced config (49k
              // points, sheet filled, capture kept pace).
              //
              // [R3 2026-09-03] 8192 → 13312:密度对齐 COLMAP 默认搭配。上游默认
              // {max_image_size=3200, max_num_features=8192} 是成对的;我们喂
              // 12MP 全幅(4032px,面积 ×1.59)却只给 8192 名额 ⇒ 特征密度仅
              // 上游的 63%,整个 octave 0(最细尺度)被裁没,每对 verified 中位
              // 仅 136-146(预算的 2%)。13312 = 8192×1.625 把密度还原到上游
              // 在其默认分辨率下的水平;分辨率一像素不动。主机重建层审计
              // (两场×10 rep):点数 +6.7~9.4%,浮点/孤立占比持平或降,无任何
              // 超噪声劣化(docs/handoffs/2026-09-02-recon-lossless-audit.md)。
              // 上面那次 07-08 的 12288 回滚是 4K 灰度 + CPU 提取时代;现在是
              // GPU 提取 + COLMAP 对齐的配对。真机否决项(预注册):单张 min
              // 不升、队列 max ≤1、热态不升、漂移 0。
              maxFeatures: 13312,
            );
            wlog('session created (${w}x$h, db=${boot.dbPath})');
          }
          // ④【热调速器 2026-07-11】喂帧前把当前 thermal 桶推给 native:
          // serious/critical 时 add_frame 把 live 匹配候选窗 12→6,给相机/
          // 系统让 GPU(45 号相机冻结根因 = thermal serious 下 GPU 持续满载
          // → Metal 丢 command buffer → ARSession 停摆)。被降档的帧由
          // finalize 补匹配恢复全窗口拓扑 —— 交付质量不变,只是配速。
          final telPre = PwTelemetry.sample();
          if (telPre != null && telPre.thermalState >= 0) {
            try {
              session!.setThermalState(telPre.thermalState);
            } catch (_) {} // 旧 .a 无此符号时静默跳过(throttle 保持关闭)
          }
          final r = session!.addJpegFrame(
            msg['jpegPath'] as String,
            captureTimestamp: msg['captureTimestamp'] as double,
            fx: msg['fx'] as double,
            fy: msg['fy'] as double,
            cx: msg['cx'] as double,
            cy: msg['cy'] as double,
            quatWxyz: (msg['q'] as Float64List?)?.toList(),
            translation: (msg['t'] as Float64List?)?.toList(),
          );
          sw.stop();
          // Sample telemetry HERE — right after add_frame, at the per-frame
          // memory peak (extract + match + triangulate all just ran). Pure
          // FFI, safe from this worker isolate.
          final tel = PwTelemetry.sample();
          if (tel != null && tel.physFootprintMb > peakMb) {
            peakMb = tel.physFootprintMb;
          }
          // Per-frame breakdown: locates a perf regression precisely —
          // extract=Xms (>2000 ⇒ GPU extractor fell back to CPU),
          // match=Yms over N candidates (cpu>0 ⇒ GPU matcher fell back).
          final dbg = session!.debugLast();
          // 遥测【frame】:累计 grow/tvg 计数(纯原生计数器读,微秒级)——
          // 与 dbg 一起塞进 frame_done,由 facade 汇成结构化行。
          var growAcc = -1, growRej = -1, tvgPairs = -1, rawPairs = -1;
          try {
            final stCum = session!.streamStats();
            growAcc = stCum.growAccepted;
            growRej = stCum.growRejected;
            tvgPairs = stCum.tvgPairs;
            rawPairs = stCum.rawPairs;
          } catch (_) {}
          // ④【热调速器】累计被降档帧数(纯计数器读;旧 .a 无符号 → -1)。
          var throttledCum = -1;
          try {
            throttledCum = session!.thermalThrottledFrames();
          } catch (_) {}
          wlog(
            'add_frame seq=${msg['seq']} frameId=${r.frameId} '
            'rc=${r.result.name} ms=${sw.elapsedMilliseconds} (${w}x$h) | '
            'extract=${dbg.extractMs.toStringAsFixed(0)}ms '
            'match=${dbg.matchMs.toStringAsFixed(0)}ms '
            'cand=${dbg.nCand} gpuM=${dbg.gpuMatches} cpuM=${dbg.cpuMatches}'
            '${tel != null ? ' | mem=${tel.physFootprintMb.toStringAsFixed(0)}MB '
                      'peak=${peakMb.toStringAsFixed(0)}MB '
                      'thermal=${tel.thermalName}' : ''}',
          );
          boot.reply.send(<String, Object?>{
            'evt': 'frame_done',
            'seq': msg['seq'],
            'frameId': r.frameId,
            'ms': sw.elapsedMilliseconds,
            'result': r.result.name,
            'memMb': tel?.physFootprintMb,
            'peakMb': tel != null ? peakMb : null,
            'thermal': tel?.thermalState,
            // 遥测【frame】附加字段(dbg + 累计计数,facade 组行)。
            'extractMs': dbg.extractMs,
            'matchMs': dbg.matchMs,
            'nCand': dbg.nCand,
            'gpuPairs': dbg.gpuMatches,
            'cpuPairs': dbg.cpuMatches,
            if (growAcc >= 0) 'growAcc': growAcc,
            if (growRej >= 0) 'growRej': growRej,
            if (tvgPairs >= 0) 'tvgPairs': tvgPairs,
            if (rawPairs >= 0) 'rawPairs': rawPairs,
            if (throttledCum >= 0) 'throttledCum': throttledCum,
          });
          // AR 照片卡片边框连通性(黑/白/红的数据源):喂入成功后节流发
          // 一份合成 poses。自带 try/catch —— 绝不允许它把异常抛进外层
          // catch(那会重复发 frame_done,facade 的 inFlight 会被双扣)。
          if (r.result == AetherSfmResult.ok && r.frameId >= 0) {
            fedIds.add(r.frameId);
            // Route B:记录该帧的 ARKit 相机中心(CamFromWorld → C=-Rᵀt,
            // gravity 世界系)。降级 extrinsic(q/t 为 null)→ 该帧不参与
            // 三角化角计算,点级聚合自动跳过它。
            {
              final q = msg['q'] as Float64List?;
              final t = msg['t'] as Float64List?;
              if (q != null && t != null) {
                final c = cameraCenterFromCamFromWorld(q, t);
                if (c != null) frameCenters[r.frameId] = c;
              }
            }
            // RS-style outer schedule, official reconstruction underneath:
            // publish nothing before 20 registered frames; then publish only
            // after a successful whole-component global BA. Later stable
            // versions advance when registered cameras or points grow 40%.
            // This call stays inside the single worker event: it is a serial
            // checkpoint after the accepted frame, so later captured photos can
            // spool without overlapping this BA or starving the shutter.
            try {
              // [SPRINT-MODE] No preview BA once finish is pending — see the
              // finishPending declaration for the measured rationale.
              // [SPRINT-RACE] Also consult the native capture-active atomic:
              // it flips synchronously with the AR session stop, closing the
              // in-flight-event race the message-driven flag cannot cover.
              final beforeGlobal = (finishPending || !nativeCaptureActive())
                  ? null
                  : session!.previewTracked();
              // [AR-EVERY-FRAME 2026-08-04] 默认关。开启后:每个被接受、且已有
              // live_recon 点的帧,直接把这份已在手的 previewTracked 推给 AR,
              // 让点云每帧可见生长,而不是只在下面的全局BA检查点刷新。复用
              // beforeGlobal(不再二次拷贝);source='streaming_local_ba' 区别于
              // 检查点的 'streaming_global_ba'。不改动下方全局BA逻辑(保留)。
              // AR 侧 400ms 合并节流兜住传输成本(eaf8706 动效延迟的既有防线)。
              if (boot.arEveryFrame &&
                  beforeGlobal != null &&
                  beforeGlobal.count > 0) {
                sendSnapshot(
                  'preview',
                  <String, dynamic>{
                    // 独立 source 名,避免与 finish-time 终态云复用的
                    // 'streaming_local_ba' 撞名(那条在 colorize 路径里被当作
                    // 拍完的终态云会提前弹浮层)。'_live' 专指拍摄期每帧推送。
                    'source': 'streaming_local_ba_live',
                    'terminal': false,
                    'publish_version': publishPolicy.version,
                    'n_registered': fedIds.length,
                    'n_points3d': beforeGlobal.count,
                  },
                  0,
                  preview: true,
                  prefetched: beforeGlobal,
                );
              }
              if (beforeGlobal != null &&
                  publishPolicy.shouldRunGlobalBa(
                    registeredFrames: fedIds.length,
                    pointCount: beforeGlobal.count,
                  )) {
                final globalSw = Stopwatch()..start();
                final globalResult = session!.globalRefine();
                globalSw.stop();
                if (globalResult == AetherSfmResult.ok) {
                  final refined = session!.previewTracked();
                  final nextVersion = publishPolicy.version + 1;
                  final delivered = sendSnapshot(
                    'preview',
                    <String, dynamic>{
                      'source': 'streaming_global_ba',
                      'terminal': false,
                      'publish_version': nextVersion,
                      'n_registered': fedIds.length,
                      'n_points3d': refined.count,
                    },
                    globalSw.elapsedMilliseconds,
                    preview: true,
                  );
                  if (delivered && refined.count > 0) {
                    publishPolicy.markGlobalBaPublished(
                      registeredFrames: fedIds.length,
                      pointCount: refined.count,
                    );
                    telem('live_global_publish', {
                      'version': publishPolicy.version,
                      'registered': fedIds.length,
                      'points': refined.count,
                      'ms': globalSw.elapsedMilliseconds,
                    });
                  }
                } else {
                  wlog(
                    'live-global-ba: rc=${globalResult.name}; '
                    'stable cloud unchanged',
                  );
                }
              }
            } catch (e) {
              // Fail closed for publication: keep the previous stable cloud
              // and retry on the next accepted frame.
              wlog('live-global-ba failed (non-fatal): $e');
            }
            final nowMs = DateTime.now().millisecondsSinceEpoch;
            if (nowMs - lastConnectivityMs >= 1200) {
              lastConnectivityMs = nowMs;
              try {
                final csw = Stopwatch()..start();
                // previewTracked 是全量拷贝(点+观测)——只取这一次,
                // 连通性与真实视差聚合共用同一份。点数为 0(live recon
                // 还没配上)→ 两路信号都不发,卡片保持"黑=未处理"。
                final pts = session!.previewTracked();
                final cp = pts.count > 0
                    ? connectivityPosesFrom(pts.obsFrameIds)
                    : Float64List(0);
                var conn = 0;
                for (var i = 1; i < cp.length; i += 9) {
                  if (cp[i] != 0) conn++;
                }
                if (cp.isNotEmpty) {
                  boot.reply.send(<String, Object?>{
                    'evt': 'live_poses',
                    'poses': cp,
                  });
                }
                wlog(
                  'live-poses: frames=${cp.length ~/ 9} connected=$conn '
                  'ms=${csw.elapsedMilliseconds}',
                );
                // Route B:真实三角化角聚合(独立 3.5s 节流,别拖帧 SLA;
                // 聚合是纯 Dart O(sampled×15) —— 耗时必记日志对数)。
                if (pts.count > 0 &&
                    frameCenters.length >= 2 &&
                    nowMs - lastTrueParallaxMs >= 3500) {
                  lastTrueParallaxMs = nowMs;
                  final psw = Stopwatch()..start();
                  final agg = trueParallaxAggregate(
                    xyz: pts.xyz,
                    obsOffsets: pts.obsOffsets,
                    obsFrameIds: pts.obsFrameIds,
                    centersByFrame: frameCenters,
                  );
                  psw.stop();
                  if (agg != null) {
                    boot.reply.send(<String, Object?>{
                      'evt': 'live_parallax',
                      'frames': agg.framesPacked,
                      'voxKeys': agg.voxelKeys,
                      'voxDeg': agg.voxelDeg,
                      'ms': psw.elapsedMilliseconds,
                      'sampled': agg.sampledPoints,
                    });
                  }
                  wlog(
                    'true-parallax: pts=${pts.count} '
                    'sampled=${agg?.sampledPoints ?? 0} '
                    'stride=${agg?.stride ?? 0} '
                    'frames=${(agg?.framesPacked.length ?? 0) ~/ 2} '
                    'vox=${agg?.voxelKeys.length ?? 0} '
                    'ms=${psw.elapsedMilliseconds}',
                  );
                }
              } catch (e) {
                wlog('live-poses failed (non-fatal): $e');
              }
            }
          }
        } catch (e) {
          sw.stop();
          boot.reply.send(<String, Object?>{
            'evt': 'frame_done',
            'seq': msg['seq'],
            'frameId': -1,
            'ms': sw.elapsedMilliseconds,
            'result': 'exception',
          });
          fail('add_frame', e);
        }
      case 'remove_frame':
        final requestId = msg['requestId'] as int;
        final frameId = msg['frameId'] as int;
        Map<String, dynamic>? stats;
        var removed = session == null;
        try {
          if (session != null) {
            stats = session!.removeFrame(frameId);
            removed = stats != null;
          }
          if (removed) {
            fedIds.remove(frameId);
            frameCenters.remove(frameId);
            if (session != null) {
              final tracked = session!.previewTracked();
              final poses = tracked.count > 0
                  ? connectivityPosesFrom(tracked.obsFrameIds)
                  : Float64List(0);
              boot.reply.send(<String, Object?>{
                'evt': 'live_poses',
                'poses': poses,
              });
              // [REMOVE-REFRESH 2026-08-09 生产缺陷修复] 用户删掉刚拍的照片,
              // AR 里它的点云纹丝不动 —— native remove_frame 早已把观测和
              // 孤儿点从 live_recon 删干净(DeRegisterFrame),但这里只推了
              // live_poses(位姿),从没把删除后的点云推给 AR;预览快照又只在
              // add_frame 末尾刷新,删的是最后一张时就永远停在删除前的画面。
              // 修复 = 删除成功后立刻用同一条 'preview' 通道把手上这份
              // previewTracked(已是删除后的新云)推出去;点数为 0(全部删光)
              // 也要推,否则"删到空"永远显示旧云。
              sendSnapshot(
                'preview',
                <String, dynamic>{
                  'source': 'streaming_local_ba_live',
                  'terminal': false,
                  'n_registered': fedIds.length,
                  'n_points3d': tracked.count,
                  'frame_removed': frameId,
                },
                0,
                preview: true,
                prefetched: tracked,
              );
            }
          }
        } catch (e) {
          removed = false;
          wlog('remove-frame failed frameId=$frameId: $e');
        }
        boot.reply.send(<String, Object?>{
          'evt': 'frame_removed',
          'requestId': requestId,
          'frameId': frameId,
          'ok': removed,
          'stats': stats,
        });
      case 'prefetch':
        // [EXTRACT-PREFETCH 2026-08-09] 堵车时 facade 在派发当前帧之前发来
        // "下一帧"的路径:壳层解码(同一 helper)后交 native 专属提取线程,
        // 与当前帧的匹配/局部BA 并行。env 关时 native 秒退,纯 no-op;
        // 猜错下一帧(latest-first 抢跑)由 FNV 摘要挡住,只浪费一次后台
        // 提取,正确性无关。任何异常吞掉 —— 预取永远不许影响喂帧。
        if (session != null) {
          try {
            final prc = session!.prefetchJpegFrame(msg['path'] as String);
            if (prc == 0) {
              wlog(
                'prefetch queued: ${(msg['path'] as String).split('/').last}',
              );
            }
          } catch (_) {} // 旧 framework 无符号 → 静默跳过
        }
      case 'finish_pending':
        // [SPRINT-MODE] Finish tapped while frames are still draining: keep
        // feeding (delivery data), stop interim preview BAs (wasted wall
        // time before REFINED — see finishPending declaration).
        finishPending = true;
      case 'repay':
        // [QUAD-PREPAY 2026-07-26, signed] Capture-idle official quadratic
        // prepay: the facade only sends this when the frame queue is empty,
        // so the matcher works through the (i, i+2^k) long-range pairs the
        // finalize pass would otherwise have to run at finish time. Native
        // returns matcher invocations consumed (0 = nothing due); the facade
        // chains while >0 and still idle. Never runs once finish is pending
        // (finalize's own pass sprints through the remainder).
        var repaid = 0;
        if (!finishPending && session != null) {
          try {
            repaid = session!.liveRepay(maxPairs: (msg['budget'] as int?) ?? 2);
          } catch (e) {
            wlog('quad-prepay failed (non-fatal): $e');
          }
        }
        boot.reply.send(<String, Object?>{'evt': 'repay_done', 'n': repaid});
      case 'resume':
        // Resume an interrupted finalize from the retained sqlite db (no new
        // frames fed). aether_sfm_create opens the existing db; finalizeAsync's
        // RunIncremental reads keypoints/matches straight from it (image_path
        // empty → all state comes from the db). This is the recovery leg of the
        // "always produces output" guarantee: any capture whose finalize was
        // killed (thermal / backgrounded / jetsam) gets retried on a later,
        // cooler launch until a PLY lands.
        if (session == null) {
          try {
            // 配置与 live 采集会话逐项对齐(上面 'frame' case 的 create:
            // 8192 features + 默认 K=researchKNeighbors=12)。resume 不喂帧,
            // maxFeatures 本身无感;但 k_neighbors 会进 native 的
            // s->options.k_neighbors,是 RestoreTemporalDetail /
            // AddSpatialRevisitMatches 的 gap 窗口 —— 旧值 live tier(2048/K6)
            // 是历史遗留错配,一旦 native 支持从 db 重建 frames,K6 会把
            // temporal-detail 的补密窗口砍半。
            session = AetherSfmStreamSession.create(
              boot.dbPath,
              imageWidth: (msg['w'] as int?) ?? 3840,
              imageHeight: (msg['h'] as int?) ?? 2160,
              maxFeatures: AetherSfmStreamSession.researchMaxFeatures,
              kNeighbors: AetherSfmStreamSession.researchKNeighbors,
            );
            wlog('resume: session opened on existing db (${boot.dbPath})');
          } catch (e) {
            fail('resume', 'create-from-db failed: $e');
            break;
          }
        }
        continue finalizeCase;
      finalizeCase:
      case 'finalize':
        final s = session;
        if (s == null) {
          fail('finalize', 'no frames were fed — nothing to reconstruct');
          break;
        }
        // [S3.5 恢复 2026-07-11] 不做两阶段预览:phase-1 不再从 db 全量重跑
        // (native 直接复用拍摄期 live recon,秒级),refined(唯一用户可见
        // 成果)完成即走 colorize→persist→展示,全程不再扣留。resume 路径
        // (无内存 live recon)在 native 内自动回退 db 全量重跑,此处无感。
        wlog(
          'finalize requested: queue already drained; phase-1 reuses the live '
          'recon (S3.5), refined is delivered the moment it lands',
        );
        final sw = Stopwatch()..start();
        try {
          // Phase 1 (blocking here): finish-time db enrichment (spatial
          // revisit + starved re-match) + live-recon handoff. The heavy
          // global BA runs in phase 2 on the native thread.
          final telBefore = PwTelemetry.sample();
          if (telBefore != null && telBefore.physFootprintMb > peakMb) {
            peakMb = telBefore.physFootprintMb;
          }
          wlog(
            'finalize_async phase-1 starting…'
            '${telBefore != null ? ' | $telBefore' : ''}',
          );
          final summary = s.finalizeAsync();
          sw.stop();
          final telAfter = PwTelemetry.sample();
          if (telAfter != null && telAfter.physFootprintMb > peakMb) {
            peakMb = telAfter.physFootprintMb;
          }
          wlog(
            'finalize_async phase-1 done in ${sw.elapsedMilliseconds}ms'
            '${telAfter != null ? ' | ${telAfter.physFootprintMb.toStringAsFixed(0)}MB '
                      'peak=${peakMb.toStringAsFixed(0)}MB '
                      'thermal=${telAfter.thermalName}' : ''}',
          );
          // 遥测【finalize/phase1】:wall + native summary(out_json 现有
          // 字段)+ 配置回显。loss/solver/迭代参数 native out_json 没有,
          // 从 aether_sfm_c.cc 的 RunIncremental 生产配置回显,标注
          // source=config_echo 以别于 native 实测。
          telem('finalize_phase1', {
            'wall_ms': sw.elapsedMilliseconds,
            'solve_ms': summary['solve_ms'],
            'n_registered': summary['n_registered'],
            'n_points3d': summary['n_points3d'],
            'reproj_px': summary['reproj_px'],
            'track_len': summary['track_len'],
            'rc': summary['rc'],
            'result': summary['result'],
            if (telAfter != null) 'mem_mb': telAfter.physFootprintMb.round(),
            if (telAfter != null) 'peak_mb': peakMb.round(),
            if (telAfter != null) 'thermal': telAfter.thermalState,
            'loss_local': 'cauchy@1.0',
            'liter': 15,
            'lnum': 6,
            'defer_global_ba': true,
            // native 回报 phase1=live_reuse 时,phase-1 只是 db 补匹配 +
            // live recon 深拷贝(S3.5);缺省(resume)= db 全量重跑。
            'phase1': summary['phase1'] ?? 'db_rerun',
            'source': 'config_echo',
          });
          final st = s.streamStats();
          final tvgPct = (st.tvgPairs + st.rawPairs) > 0
              ? (100 * st.tvgPairs / (st.tvgPairs + st.rawPairs)).round()
              : 0;
          wlog(
            'stream-stats: tvg-inlier pairs=${st.tvgPairs} '
            'raw-fallback=${st.rawPairs} ($tvgPct% verified) | '
            'grow accept=${st.growAccepted} reject=${st.growRejected} | '
            'filtered reproj=${st.reprojFiltered} tri-angle=${st.triFiltered}',
          );
          wlog(
            'stream-gates: grow reject cheirality=${st.growRejectCheirality} '
            'reproj=${st.growRejectReproj} | create reject '
            'cheirality=${st.createRejectCheirality} '
            'tri-angle=${st.createRejectTriAngle} '
            'reproj=${st.createRejectReproj} | assigned same='
            '${st.alreadyAssigned} merge-needed=${st.mergeNeeded} '
            'accepted=${st.mergeAccepted} rejected=${st.mergeRejected} | '
            'spatial considered=${st.spatialConsidered} '
            'attempted=${st.spatialAttempted} written=${st.spatialWritten} '
            'inliers=${st.spatialInliers}',
          );
          wlog(
            'spatial-loop: anchors=${st.spatialAnchorPassed}/'
            '${st.spatialAnchorAttempted} '
            'regions=${st.spatialRegionsConfirmed} expand-attempted='
            '${st.spatialExpandedAttempted} guided=${st.spatialGuidedPairs}/'
            '${st.spatialGuidedInliers}candidates quadratic='
            '${st.spatialQuadraticWritten}/'
            '${st.spatialQuadraticAttempted} budget-skipped='
            '${st.spatialBudgetSkipped}',
          );
          if (summary['result'] != 'ok') {
            // DIAGNOSTIC TAP: preserve the accumulated sqlite db before the
            // session drops it, so keypoint/match/two-view-geometry counts
            // can be inspected off-device (sqlite3) to see where the chain
            // broke. Copied as .debug — the pipeline never reads it.
            try {
              final db = File(boot.dbPath);
              if (db.existsSync()) {
                db.copySync('${boot.dbPath}.debug');
                wlog(
                  'debug: db preserved at ${boot.dbPath}.debug '
                  '(${db.lengthSync()} bytes)',
                );
              }
            } catch (e) {
              wlog('debug: db preserve failed: $e');
            }
            fail(
              'finalize',
              '${summary['result']} (rc=${summary['rc']}) $summary',
            );
            break;
          }
          wlog(
            'phase-1 done (${summary['phase1'] ?? 'db_rerun'}); refined snapshot '
            'will be delivered immediately on completion',
          );
          // Phase 2 runs on the session's own native thread; poll the
          // lock-free status flag until it lands. 250 ms(原 700 ms):
          // refined 是唯一用户可见成果,轮询间隔直接计入交付延迟;读的是
          // 无锁 atomic,加频无成本。
          refineStart = DateTime.now().millisecondsSinceEpoch;
          pollTimer = Timer.periodic(const Duration(milliseconds: 250), (t) {
            final st = s.finalizeStatus();
            if (st == AetherSfmFinalizeStatus.refined) {
              t.cancel();
              final ms = DateTime.now().millisecondsSinceEpoch - refineStart;
              // 遥测【finalize/segments】(cap44 观测盲区修复):native
              // RefineGlobalBA 把 phase-2 内部分段(cache_pre/enrich/stage1/
              // stage2/temporal ms + 补匹配计数 + ceres 实测 solver_used/
              // mixed/threads)写进 run_dir/official_finalize_segments.json(stderr
              // 双写照旧,但拔线 detached 全丢)——REFINED 后读回转发进
              // telemetry_official_dart.jsonl。文件在 status 翻 REFINED 前原子落盘,
              // 此处读不到 = 走了 fallback 全量重跑(native 会先删旧文件)。
              Map<String, dynamic>? segs;
              try {
                final segFile = File(
                  '${File(boot.dbPath).parent.path}/official_finalize_segments.json',
                );
                if (segFile.existsSync()) {
                  segs = jsonDecode(
                    segFile.readAsStringSync(),
                  ) as Map<String, dynamic>;
                }
              } catch (e) {
                wlog('finalize segments read failed (non-fatal): $e');
              }
              final telP2 = PwTelemetry.sample();
              if (segs != null) {
                telem('finalize_segments', {
                  ...segs,
                  if (telP2 != null) 'thermal': telP2.thermalState,
                  if (telP2 != null) 'mem_mb': telP2.physFootprintMb.round(),
                });
              } else {
                wlog(
                  'official_finalize_segments.json missing — phase 2 likely took the '
                  'db-rerun fallback (segments telemetry unavailable)',
                );
              }
              // 遥测【finalize/phase2】:后台全局 BA wall + 配置回显。
              // ⚠️ [PHASE2-CONFIG-ECHO 2026-08-12] 这里原先把 gftol/gref/giter
              // 写成**硬编码字面量**却标 source=config_echo:gref 停在早已改成
              // 3 的旧值 5,gftol 更是无视 env 覆盖恒报 1e-6 —— 08-11 夜里核验
              // BA-FTOL 旋钮时,它差点让"env 其实已生效"被误判成"没生效"。
              // 现在三个值全部由 native 在**所有 env 覆盖与 AB 选臂之后**落进
              // segments,Dart 只透传;segments 缺失(旧包/db-rerun 回退)时
              // 字段直接不出,绝不再编造。
              telem('finalize_phase2', {
                'wall_ms': ms,
                'loss_global': 'cauchy@1.0',
                'solver': 'dense_schur_override',
                'source': 'native_segments',
                if (telP2 != null) 'mem_mb': telP2.physFootprintMb.round(),
                if (telP2 != null) 'thermal': telP2.thermalState,
                if (segs != null) ...{
                  'cache_pre_ms': segs['cache_pre_ms'],
                  'enrich_ms': segs['enrich_ms'],
                  'stage1_ms': segs['stage1_ms'],
                  'stage1_rounds': segs['stage1_rounds'],
                  'stage1_state': segs['stage1_state'],
                  'stage2_ms': segs['stage2_ms'],
                  'stage2_rounds_budget': segs['stage2_rounds_budget'],
                  'temporal_ms': segs['temporal_ms'],
                  'total_native_ms': segs['total_ms'],
                  'solver_used': segs['solver_used'],
                  'sparse_backend': segs['sparse_backend'],
                  // phase-2 全局 BA 真实生效配置(native 落盘,非字面量)。
                  // ftol_ab_arm:-1=逐场交替关闭,0=base 臂,1=变体臂。
                  'gftol': segs['gftol_used'],
                  'gref': segs['gref_used'],
                  'giter': segs['giter_used'],
                  'ftol_ab_arm': segs['ftol_ab_arm'],
                  'mixed': segs['mixed'],
                  'threads': segs['threads'],
                },
              });
              // 遥测【match_fail_stats】:采集期 GPU matcher 失败 rc 桶 +
              // finalize 补匹配计数(rematch_* 在 enrichment 线程填,REFINED
              // 后才最终)。cap44 链路补全:符号在 archive 里但从未导出。
              try {
                final mf = s.matchFailStats();
                telem('match_fail_stats', {
                  'gpu_fail_total': mf.gpuFailTotal,
                  'gpu_fail_by_rc': mf.gpuFailByRc,
                  'gpu_fail_max_streak': mf.gpuFailMaxStreak,
                  'rematch_starved_frames': mf.rematchStarvedFrames,
                  'rematch_candidates': mf.rematchCandidates,
                  'rematch_attempted': mf.rematchAttempted,
                  'rematch_written': mf.rematchWritten,
                  'rematch_inliers': mf.rematchInliers,
                  'rematch_failed': mf.rematchFailed,
                });
              } catch (e) {
                wlog('match_fail_stats telemetry failed (non-fatal): $e');
              }
              // 遥测【repair_stats】(P1 finalize 提速包对账):空闲还债
              // repay 域(calls/attempted/written=还上的对/inliers/failed/
              // thermal_rejects)+ rc=7 退避重试 + enrich 时间预算截停。
              // 与 match_fail_stats 同契约:REFINED 后读才最终;旧 .a 无
              // pwofficial_repair_stats 符号 → 抛进 catch,非致命。
              try {
                final rs = s.repairStats();
                telem('repair_stats', {
                  'repay_calls': rs.repayCalls,
                  'repay_attempted': rs.repayAttempted,
                  'repay_written': rs.repayWritten,
                  'repay_inliers': rs.repayInliers,
                  'repay_failed': rs.repayFailed,
                  'repay_skipped_thermal': rs.repaySkippedThermal,
                  'gpu_retry_attempts': rs.gpuRetryAttempts,
                  'gpu_retry_recovered': rs.gpuRetryRecovered,
                  'enrich_budget_stopped': rs.enrichBudgetStopped,
                });
              } catch (e) {
                wlog('repair_stats telemetry failed (non-fatal): $e');
              }
              sendSnapshot('refined', summary, ms);
              // 遥测【geom】几何自检:点级三角化角分布(worker 后台线程,
              // 不卡 UI;>1 万点自动跨步采样)。
              try {
                final g = _triAngleTelemetry(
                  s.pointsTracked(),
                  s.posesPacked(),
                );
                if (g != null) {
                  telem('geom', {
                    ...g,
                    'reproj_px': summary['reproj_px'],
                    'track_len': summary['track_len'],
                  });
                }
              } catch (e) {
                wlog('geom telemetry failed (non-fatal): $e');
              }
            } else if (st == AetherSfmFinalizeStatus.error) {
              t.cancel();
              fail('refine', 'background global BA failed');
            }
          });
        } catch (e) {
          sw.stop();
          fail('finalize', e);
        }
      case 'dispose':
        disposed = true;
        pollTimer?.cancel();
        wlog('dispose: freeing session (joins bg BA thread)…');
        try {
          session?.dispose(); // joins the background BA thread
        } catch (_) {}
        session = null;
        boot.reply.send(const <String, Object?>{'evt': 'disposed'});
        cmds.close();
    }
  });
}

/// 遥测【geom】几何自检(任务 E):点级三角化角分布。
///
/// 对每个采样点,取其 track 观测帧的相机中心(poses 是 COLMAP CamFromWorld
/// 真值,C = -Rᵀt;与 pointsTracked 的 xyz 同在 COLMAP 世界系,角度自洽),
/// 算"点→各相机"射线两两夹角的最大值 = 该点的三角化角。低角度(<8°)点
/// 是深度歧义壳("双墙")高危群 —— p10/p50/p90 + <8° 占比一并输出。
///
/// 成本护栏:>1 万点按跨步采样;每点最多取前 6 个有位姿的观测(O(k²) 封顶
/// 15 对)。在 worker isolate 的 finalize 后台跑,不碰 UI。合成 poses
/// (四元数全 0,流式预览)自然被 norm 门跳过 → 返回 null。
Map<String, Object?>? _triAngleTelemetry(
  AetherSfmPointsTracked points,
  Float64List poses,
) {
  final sw = Stopwatch()..start();
  final n = points.count;
  final offs = points.obsOffsets;
  final fids = points.obsFrameIds;
  if (n == 0 || poses.isEmpty || offs.length != n + 1) return null;

  // frameId → 相机中心(COLMAP 世界系)。C = -Rᵀ t。
  final centers = <int, List<double>>{};
  for (var i = 0; i + 8 < poses.length; i += 9) {
    if (poses[i + 1] == 0) continue; // 未注册
    final qw = poses[i + 2], qx = poses[i + 3];
    final qy = poses[i + 4], qz = poses[i + 5];
    final norm2 = qw * qw + qx * qx + qy * qy + qz * qz;
    if (norm2 < 1e-12) continue; // 合成 poses(流式预览)→ 无真值
    final s = 1.0 / norm2;
    final tx = poses[i + 6], ty = poses[i + 7], tz = poses[i + 8];
    final r00 = 1 - 2 * s * (qy * qy + qz * qz);
    final r01 = 2 * s * (qx * qy - qz * qw);
    final r02 = 2 * s * (qx * qz + qy * qw);
    final r10 = 2 * s * (qx * qy + qz * qw);
    final r11 = 1 - 2 * s * (qx * qx + qz * qz);
    final r12 = 2 * s * (qy * qz - qx * qw);
    final r20 = 2 * s * (qx * qz - qy * qw);
    final r21 = 2 * s * (qy * qz + qx * qw);
    final r22 = 1 - 2 * s * (qx * qx + qy * qy);
    centers[poses[i].toInt()] = [
      -(r00 * tx + r10 * ty + r20 * tz),
      -(r01 * tx + r11 * ty + r21 * tz),
      -(r02 * tx + r12 * ty + r22 * tz),
    ];
  }
  if (centers.length < 2) return null;

  const maxSample = 10000; // >2s 护栏:超过 1 万点跨步采样
  const maxObsPerPoint = 6; // O(k²) 封顶(≤15 对)
  final stride = n <= maxSample ? 1 : (n / maxSample).ceil();
  final angles = <double>[];
  var lt8 = 0;
  final cams = <List<double>>[];
  for (var i = 0; i < n; i += stride) {
    cams.clear();
    for (
      var j = offs[i];
      j < offs[i + 1] && cams.length < maxObsPerPoint;
      j++
    ) {
      final c = centers[fids[j]];
      if (c != null) cams.add(c);
    }
    if (cams.length < 2) continue;
    final px = points.xyz[i * 3];
    final py = points.xyz[i * 3 + 1];
    final pz = points.xyz[i * 3 + 2];
    var best = 0.0;
    for (var a = 0; a < cams.length; a++) {
      final ax = cams[a][0] - px, ay = cams[a][1] - py, az = cams[a][2] - pz;
      final an = math.sqrt(ax * ax + ay * ay + az * az);
      if (an < 1e-12) continue;
      for (var b = a + 1; b < cams.length; b++) {
        final bx = cams[b][0] - px, by = cams[b][1] - py, bz = cams[b][2] - pz;
        final bn = math.sqrt(bx * bx + by * by + bz * bz);
        if (bn < 1e-12) continue;
        final cosAng = ((ax * bx + ay * by + az * bz) / (an * bn)).clamp(
          -1.0,
          1.0,
        );
        final ang = math.acos(cosAng);
        if (ang > best) best = ang;
      }
    }
    final deg = best * 180.0 / math.pi;
    angles.add(deg);
    if (deg < 8.0) lt8++;
  }
  if (angles.isEmpty) return null;
  angles.sort();
  sw.stop();
  double r2(double? v) => v == null ? 0 : (v * 100).round() / 100;
  return <String, Object?>{
    'n_pts': n,
    'sampled': angles.length,
    'stride': stride,
    'tri_p10': r2(percentileSorted(angles, 0.10)),
    'tri_p50': r2(percentileSorted(angles, 0.50)),
    'tri_p90': r2(percentileSorted(angles, 0.90)),
    'tri_lt8_pct': (1000.0 * lt8 / angles.length).round() / 10,
    'ms': sw.elapsedMilliseconds,
  };
}
