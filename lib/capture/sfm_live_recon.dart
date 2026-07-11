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
//   SfmFrameFeed (frame-exact gray + intrinsics + extrinsic from native) →
//   [this facade: intrinsics rescale + CamFromWorld conversion + backpressure]
//   → worker isolate → aether_sfm_add_frame
//   finish → finalize() → worker runs aether_sfm_finalize_async (phase 1
//   blocks in-worker) → LOCAL_READY snapshot event → worker polls
//   finalize_status until REFINED/ERROR → refined snapshot event.
//
// Backpressure (capture never waits for SfM): if more than one add_frame is
// still unconsumed by the worker, new keyframes are DROPPED — a dropped
// frame simply doesn't join the live reconstruction; the saved JPEG still
// flows into the post-capture pipeline, so this is lossy only for the
// preview, never for the user's data.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart' as vm;

import '../aether_sfm_ffi.dart';
import '../dome/ar_pose.dart' show SfmFrameFeed;
import '../util/device_log.dart';
import 'gravity_align.dart';
import 'pw_telemetry.dart';
import 'telemetry_writer.dart';
import 'true_parallax.dart';

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
  final Float64List posesPacked;

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

/// Drops only points created exclusively by one time-far spatial pair.
///
/// A two-view point has no third-view depth confirmation. When its two frames
/// are farther apart than the normal temporal K window, it can only have come
/// from finish-time loop matching. Those points caused the observed long rays:
/// wrong correspondences can retain low reprojection error while triangulating
/// at extreme depth. Normal K12 two-view points and every 3+-view loop track are
/// preserved, so this is not a generic density/outlier filter.
({AetherSfmPointsTracked points, int removed}) filterFinalSpatialTwoViewPoints(
  AetherSfmPointsTracked input, {
  required int temporalK,
}) {
  final n = input.count;
  final offsets = input.obsOffsets;
  final frameIds = input.obsFrameIds;
  final obsXY = input.obsXY;
  if (n == 0 ||
      offsets.length != n + 1 ||
      obsXY.length != frameIds.length * 2) {
    return (points: input, removed: 0);
  }

  final keep = Uint8List(n);
  var keptPoints = 0;
  var keptObs = 0;
  for (var i = 0; i < n; i++) {
    final start = offsets[i];
    final end = offsets[i + 1];
    if (start < 0 || end < start || end > frameIds.length) {
      return (points: input, removed: 0);
    }
    final isUnsupportedSpatialTwoView =
        end - start == 2 &&
        (frameIds[start] - frameIds[start + 1]).abs() > temporalK;
    if (!isUnsupportedSpatialTwoView) {
      keep[i] = 1;
      keptPoints++;
      keptObs += end - start;
    }
  }
  final removed = n - keptPoints;
  if (removed == 0) return (points: input, removed: 0);

  final xyz = Float32List(keptPoints * 3);
  final rgb = Uint8List(keptPoints * 3);
  final compactOffsets = Int32List(keptPoints + 1);
  final compactFrameIds = Int32List(keptObs);
  final compactObsXY = Float32List(keptObs * 2);
  var pointOut = 0;
  var obsOut = 0;
  for (var i = 0; i < n; i++) {
    if (keep[i] == 0) continue;
    final srcPoint = i * 3;
    final dstPoint = pointOut * 3;
    xyz.setRange(dstPoint, dstPoint + 3, input.xyz, srcPoint);
    rgb.setRange(dstPoint, dstPoint + 3, input.rgb, srcPoint);
    compactOffsets[pointOut] = obsOut;
    for (var j = offsets[i]; j < offsets[i + 1]; j++) {
      compactFrameIds[obsOut] = frameIds[j];
      compactObsXY[obsOut * 2] = obsXY[j * 2];
      compactObsXY[obsOut * 2 + 1] = obsXY[j * 2 + 1];
      obsOut++;
    }
    pointOut++;
  }
  compactOffsets[keptPoints] = obsOut;
  return (
    points: AetherSfmPointsTracked(
      xyz,
      rgb,
      compactOffsets,
      compactFrameIds,
      compactObsXY,
    ),
    removed: removed,
  );
}

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
  });
  final int seq;
  final int frameId; // -1 when result != ok
  final int elapsedMs;
  final String result;
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

/// What the facade remembers about each successfully-fed keyframe — enough
/// for the preview to project reconstructed points back into the saved JPEG
/// and sample real colors. Intrinsics here are at the FED gray resolution
/// (the same values the solver was given).
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

/// One keyframe parked on disk while the worker is busy. The gray bytes
/// live in the file (memory stays flat no matter how deep the queue gets);
/// [written] completes when the spill finished flushing.
class _SpooledFrame {
  _SpooledFrame({
    required this.seq,
    required this.path,
    required this.written,
    required this.w,
    required this.h,
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    required this.quatWxyz,
    required this.trans,
  });
  final int seq;
  final String path;
  final Future<void> written;
  final int w;
  final int h;
  final double fx;
  final double fy;
  final double cx;
  final double cy;
  final Float64List? quatWxyz;
  final Float64List? trans;
}

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
  );

  final SendPort _toWorker;
  final ReceivePort _fromWorker;
  final Isolate _isolate;
  final StreamSubscription<dynamic> _sub;
  final String _dbPath;

  final _events = StreamController<SfmLiveEvent>.broadcast();
  Stream<SfmLiveEvent> get events => _events.stream;

  int _seq = 0;
  int _inFlight = 0; // frames sent to the worker but not yet acked
  int _fedOk = 0;
  bool _finalizeRequested = false; // finish tapped — no new frames accepted
  bool _finalizeSent = false; // finalize cmd actually dispatched to worker
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

  // ── 遥测【frame】时间戳(epoch ms):seq → offer 到达 / 实际送 worker。
  // frame_done 时合成一行结构化 frame 事件后移除(既有回调顺手记,零阻塞)。
  final Map<int, int> _seqOfferMs = <int, int>{};
  final Map<int, int> _seqSentMs = <int, int>{};

  /// 遥测【queue_drain】:finalize() 被请求的时刻(epoch ms),到
  /// [_maybeSendFinalize] 真正下发的间隔 = 队列排空耗时。
  int _finalizeRequestMs = 0;

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
  static Future<SfmLiveRecon?> start({required String dbPath}) async {
    if (!isSupported) {
      DeviceLog.log('SfmLive', 'start: unsupported (simulator) — hidden');
      return null;
    }
    final fromWorker = ReceivePort();
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _sfmWorkerMain,
        _SfmWorkerBootstrap(fromWorker.sendPort, dbPath),
        debugName: 'sfm_live_recon',
        errorsAreFatal: true,
      );
    } catch (e) {
      fromWorker.close();
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
    final sub = fromWorker.listen((msg) {
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
      await sub.cancel();
      fromWorker.close();
      isolate.kill(priority: Isolate.immediate);
      return null;
    }
    recon = SfmLiveRecon._(port, fromWorker, isolate, sub, dbPath);
    DeviceLog.log('SfmLive', 'worker up (db=$dbPath)');
    return recon;
  }

  /// Offers one keyframe to the live reconstruction. NEVER blocks and NEVER
  /// drops: when the worker is busy the gray plane is spilled to disk and
  /// fed as soon as a slot frees (finalize waits for the queue to drain, so
  /// every offered frame reaches the reconstruction). Returns false only
  /// when the feed lacks what add_frame needs.
  bool offerFrame(SfmFrameFeed feed) {
    if (_disposed || _finalizeRequested) return false;
    if (feed.intrinsicFxFyCxCy.length < 4 || feed.imageW <= 0) {
      return false;
    }
    final seq = ++_seq;
    _seqOfferMs[seq] = DateTime.now().millisecondsSinceEpoch; // 遥测【frame】
    // Uniform intrinsics rescale full-res → gray resolution (the native
    // extract preserves aspect, so one factor serves fx/fy/cx/cy).
    final s = feed.grayW / feed.imageW;
    final fx = feed.intrinsicFxFyCxCy[0] * s;
    final fy = feed.intrinsicFxFyCxCy[1] * s;
    final cx = feed.intrinsicFxFyCxCy[2] * s;
    final cy = feed.intrinsicFxFyCxCy[3] * s;

    // ARKit extrinsic is column-major camera-to-world; the ABI wants the
    // CamFromWorld (world→camera) prior. Native uses it for the ARKit-world live
    // preview/local-BA path; authoritative finalize still estimates its own SfM
    // camera poses from image matches.
    Float64List? quatWxyz;
    Float64List? trans;
    List<double>? cameraCenterWorld;
    if (feed.extrinsic4x4.length == 16) {
      final c2w = vm.Matrix4.fromList(feed.extrinsic4x4);
      final cWorld = c2w.getTranslation();
      final rW2c = c2w.getRotation()..transpose();
      final tW2c = rW2c.transform(-cWorld);
      final q = vm.Quaternion.fromRotation(rW2c)..normalize();
      quatWxyz = Float64List.fromList([q.w, q.x, q.y, q.z]);
      trans = Float64List.fromList([tW2c.x, tW2c.y, tW2c.z]);
      cameraCenterWorld = [cWorld.x, cWorld.y, cWorld.z];
    }

    final jpegPath = feed.jpegPath;
    if (jpegPath != null) {
      _pendingMeta[seq] = SfmFedFrameMeta(
        jpegPath: jpegPath,
        imageW: feed.imageW,
        imageH: feed.imageH,
        grayW: feed.grayW,
        grayH: feed.grayH,
        fx: fx,
        fy: fy,
        cx: cx,
        cy: cy,
        arkitQuatWxyz: quatWxyz?.toList(), // ARKit CamFromWorld (gravity frame)
        arkitTransTxyz: trans?.toList(),
        arkitCameraCenterWorld: cameraCenterWorld,
      );
    }

    if (_inFlight < 2 && _spool.isEmpty) {
      // Worker has room — feed directly, zero disk traffic.
      _sendFrameCmd(
        seq,
        feed.gray,
        feed.grayW,
        feed.grayH,
        fx,
        fy,
        cx,
        cy,
        quatWxyz,
        trans,
      );
    } else {
      // Worker busy — park the gray plane on disk (full-res 4K ≈ 8.3 MB;
      // parking N frames costs disk, not RAM) and let the pump feed it in
      // arrival order. Entry is appended SYNCHRONOUSLY so ordering is
      // preserved even while the write is still flushing.
      final path = '$_dbPath.spool.$seq.gray';
      final written = File(path).writeAsBytes(feed.gray, flush: false);
      _spool.add(
        _SpooledFrame(
          seq: seq,
          path: path,
          written: written,
          w: feed.grayW,
          h: feed.grayH,
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
    return true;
  }

  void _sendFrameCmd(
    int seq,
    Uint8List gray,
    int w,
    int h,
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
      'cmd': 'frame',
      'seq': seq,
      'gray': gray,
      'w': w,
      'h': h,
      'fx': fx,
      'fy': fy,
      'cx': cx,
      'cy': cy,
      'q': q,
      't': t,
    });
  }

  /// Feeds spooled frames whenever the worker has room; sends the deferred
  /// finalize once everything drained. Single-flight (re-entry guarded).
  Future<void> _pump() async {
    if (_pumping || _disposed) return;
    _pumping = true;
    try {
      while (!_disposed && _inFlight < 2 && _spool.isNotEmpty) {
        final entry = _spool.first;
        try {
          await entry.written; // ensure the spill finished flushing
          final gray = await File(entry.path).readAsBytes();
          _spool.removeAt(0);
          unawaited(
            File(
              entry.path,
            ).delete().then<void>((_) {}, onError: (Object _) {}),
          );
          _sendFrameCmd(
            entry.seq,
            gray,
            entry.w,
            entry.h,
            entry.fx,
            entry.fy,
            entry.cx,
            entry.cy,
            entry.quatWxyz,
            entry.trans,
          );
        } catch (e) {
          // Unreadable spill — skip this frame rather than stall the queue.
          _spool.removeAt(0);
          _pendingMeta.remove(entry.seq);
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
        !_finalizeRequested ||
        _finalizeSent ||
        _spool.isNotEmpty ||
        _inFlight > 0) {
      return;
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
    });
    _toWorker.send(const <String, Object?>{'cmd': 'finalize'});
  }

  /// Ends the capture. New frames are refused from this moment; the worker
  /// finishes the disk queue first, then runs finalize_async (phase 1
  /// blocks in-worker; LOCAL_READY and REFINED/ERROR arrive via [events]).
  void finalize() {
    if (_disposed || _finalizeRequested) return;
    _finalizeRequested = true;
    _finalizeRequestMs = DateTime.now().millisecondsSinceEpoch; // 遥测
    if (_spool.isNotEmpty || _inFlight > 0) {
      DeviceLog.log(
        'SfmLive',
        'finalize deferred: inFlight=$_inFlight queued=${_spool.length}',
      );
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
  /// 拍摄期落盘的 sfm_fed_frames.jsonl(含 arkitCamFromWorldQwxyz)回填,
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
      };
      if (m.arkitQuatWxyz != null &&
          m.arkitTransTxyz != null &&
          m.arkitCameraCenterWorld != null) {
        meta.addAll(<String, Object?>{
          'arkitPoseConvention':
              'worldAlignment.gravity; cameraToWorld from ARKit, stored as CamFromWorld plus camera center',
          'arkitCamFromWorldQwxyz': m.arkitQuatWxyz,
          'arkitCamFromWorldTxyz': m.arkitTransTxyz,
          'arkitCameraCenterWorld': m.arkitCameraCenterWorld,
        });
      }
      final line = '${jsonEncode(meta)}\n';
      File(
        '$dir/sfm_fed_frames.jsonl',
      ).writeAsStringSync(line, mode: FileMode.append, flush: false);
    } catch (_) {}
  }

  /// Frees the native session (joins the background BA thread, drops the
  /// sqlite db) and tears the isolate down. Safe to call more than once.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Drop any undelivered spool files (page is going away).
    for (final entry in _spool) {
      unawaited(
        File(entry.path).delete().then<void>((_) {}, onError: (Object _) {}),
      );
    }
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
      await _sub.cancel();
      _fromWorker.close();
      _isolate.kill(priority: Isolate.immediate);
      await _events.close();
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
        if (ok) _fedOk++;
        final seq = msg['seq'] as int;
        final frameId = msg['frameId'] as int;
        final meta = _pendingMeta.remove(seq);
        if (ok && meta != null && frameId >= 0) {
          _fedMeta[frameId] = meta;
          _persistFedMeta(frameId, meta);
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
          ),
        );
        // Worker slot freed — feed the next spooled frame (and dispatch the
        // deferred finalize once everything drained).
        unawaited(_pump());
      case 'preview':
        // The streaming local-BA cloud, TRACK-ANNOTATED (same payload shape as
        // local_ready) so it colorizes + gravity-aligns identically to finalize.
        _events.add(
          SfmLivePreview(_gravityAlign(_snapshotFromMsg(msg, refined: false))),
        );
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
        _events.add(
          SfmLiveLocalReady(
            _gravityAlign(_snapshotFromMsg(msg, refined: false)),
            msg['ms'] as int,
          ),
        );
      case 'refined':
        _events.add(
          SfmLiveRefined(
            _gravityAlign(_snapshotFromMsg(msg, refined: true)),
            msg['ms'] as int,
          ),
        );
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
  SfmLiveSnapshot _gravityAlign(SfmLiveSnapshot snap) {
    final out = gravityAlignedPoints(
      xyz: snap.xyz,
      posesPacked: snap.posesPacked,
      arkitQuatWxyzOf: (frameId) => _fedMeta[frameId]?.arkitQuatWxyz,
    );
    if (out == null) return snap;
    return SfmLiveSnapshot(
      xyz: out,
      rgb: snap.rgb,
      posesPacked: snap.posesPacked,
      summary: snap.summary,
      refined: snap.refined,
      obsOffsets: snap.obsOffsets,
      obsFrameIds: snap.obsFrameIds,
      obsXY: snap.obsXY,
    );
  }

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
  const _SfmWorkerBootstrap(this.reply, this.dbPath);
  final SendPort reply;
  final String dbPath;
}

void _sfmWorkerMain(_SfmWorkerBootstrap boot) {
  final cmds = ReceivePort();
  boot.reply.send(cmds.sendPort);

  AetherSfmStreamSession? session;
  Timer? pollTimer;
  var refineStart = 0;
  var disposed = false;
  // ③【空闲还债 2026-07-11】上一帧 'frame' 命令处理结束的时刻(epoch ms;
  // 0 = 还没喂过帧)+ finalize 已开始标志(还债 tick 的两道闸)。
  var lastFrameProcEndMs = 0;
  var finalizing = false;
  Timer? idleRepayTimer;
  // True session high-water footprint — the public TASK_VM_INFO layout has no
  // historical peak field, so we take a running max of the instantaneous
  // sample taken right after each heavy native call.
  var peakMb = 0.0;
  // 已成功喂入的 frameId(卡片边框连通性的全集)+ 连通性事件节流时钟。
  final fedIds = <int>[];
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
    boot.reply.send(<String, Object?>{'evt': 'telem', 'type': type, 'data': data});
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
  }) {
    final s = session;
    if (s == null) return false;
    var points = preview ? s.previewTracked() : s.pointsTracked();
    if (preview && points.count == 0) return false; // no live_recon → fall back
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
      final filtered = filterFinalSpatialTwoViewPoints(
        points,
        temporalK: AetherSfmStreamSession.researchKNeighbors,
      );
      points = filtered.points;
      deliveredSummary['spatial_two_view_filtered'] = filtered.removed;
      deliveredSummary['delivered_points'] = points.count;
      wlog(
        'quality-filter: spatial-only two-view removed=${filtered.removed} '
        'kept=${points.count} temporalK='
        '${AetherSfmStreamSession.researchKNeighbors}',
      );
      // 遥测【finalize/snapshot】:交付快照的点/观测/过滤/细节恢复计数
      // (数据已在手上,顺手记)。
      telem('finalize_snapshot', {
        'evt': evt,
        'points_delivered': points.count,
        'obs': points.obsCount,
        'spatial_two_view_filtered': filtered.removed,
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

  // ③【空闲还债 2026-07-11】拍摄空档把饥饿帧(GPU matcher 失败/热降档)的
  // 缺失 temporal 匹配提前补上,免得欠债全堆给 finalize 在热透的 GPU 上还
  // (cap46:336 对欠债 ~410ms/对 = 137.9s enrich;拍摄期健康 GPU ~16ms/对)。
  // 调用点安全性:worker isolate 是单事件循环,timer 回调与 'frame'/'finalize'
  // 命令处理天然串行 —— 绝不与 add_frame 并发,恰好落在 add_frame 之间的
  // 空档;不阻塞喂帧(极端竞态下最多让下一帧多等一次 repay,≤4 对)。
  // "队列空"的判据:facade 在 _inFlight<2 时立即续帧,所以距上帧处理结束
  // >500ms 仍无新帧 = 磁盘 spool 已空、拍摄在歇。native 侧再兜两道底:
  // thermal>=2 直接拒绝(绝不给"造成欠债的那个状态"加 GPU 负载)、每对
  // 至多尝试一次;finalize 补匹配仍是安全网 —— 交付模型与不还债时一致,
  // 只是把债挪到了免费的空闲窗。
  idleRepayTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
    final s = session;
    if (s == null || disposed || finalizing || lastFrameProcEndMs == 0) return;
    if (DateTime.now().millisecondsSinceEpoch - lastFrameProcEndMs <= 500) {
      return;
    }
    try {
      // 还债前推一次新鲜 thermal:空闲期没有 add_frame 帮忙刷新,native 的
      // 拒绝门不能吃陈旧状态(setThermalState 走旧符号集,单独 guard)。
      final tel = PwTelemetry.sample();
      if (tel != null && tel.thermalState >= 0) {
        try {
          s.setThermalState(tel.thermalState);
        } catch (_) {}
      }
      final sw = Stopwatch()..start();
      final repaid = s.liveRepay(maxPairs: 4);
      sw.stop();
      if (repaid > 0) {
        wlog(
          'idle-repay: $repaid pair(s) repaid in ${sw.elapsedMilliseconds}ms'
          '${tel != null ? ' (thermal=${tel.thermalName})' : ''}',
        );
      }
    } catch (e) {
      // 旧 .a 无 pwsfm_live_repay 符号 → 首次调用即抛;停表,本次采集不再
      // 试(finalize 补匹配照旧兜底)。
      idleRepayTimer?.cancel();
      wlog('idle-repay unavailable — disabled for this session: $e');
    }
  });

  cmds.listen((dynamic msg) {
    if (msg is! Map || disposed) return;
    switch (msg['cmd']) {
      case 'frame':
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
              maxFeatures: 8192,
            );
            wlog('session created (${w}x$h, db=${boot.dbPath})');
            // DIAGNOSTIC TAP (errNotRegistered investigation): dump the
            // first gray frame as a viewable PGM next to the db, plus the
            // exact intrinsics fed — settles the "is the gray content /
            // calibration sane?" question with one capture round.
            try {
              final pgm = File(
                '${File(boot.dbPath).parent.path}/sfm_debug_frame0.pgm',
              );
              final header = 'P5\n$w $h\n255\n'.codeUnits;
              pgm.writeAsBytesSync([...header, ...(msg['gray'] as Uint8List)]);
              wlog(
                'debug: frame0 PGM dumped (${pgm.path}) '
                'fx=${msg['fx']} fy=${msg['fy']} '
                'cx=${msg['cx']} cy=${msg['cy']}',
              );
            } catch (e) {
              wlog('debug: PGM dump failed: $e');
            }
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
          final r = session!.addFrame(
            msg['gray'] as Uint8List,
            w,
            h,
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
        // ③【空闲还债】帧处理(成功或异常)结束时刻 —— 还债 tick 的
        // ">500ms 无新帧 = 空闲"判据锚点。
        lastFrameProcEndMs = DateTime.now().millisecondsSinceEpoch;
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
        // ③【空闲还债】finalize 开始即永久停掉还债 tick:enrich/全局 BA
        // 期间绝不追加 GPU 匹配负载,剩余欠债由 native 的 finalize
        // 补匹配(安全网)接管。
        finalizing = true;
        idleRepayTimer?.cancel();
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
            'lnum': 10,
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
              // mixed/threads)写进 run_dir/finalize_segments.json(stderr
              // 双写照旧,但拔线 detached 全丢)——REFINED 后读回转发进
              // telemetry_dart.jsonl。文件在 status 翻 REFINED 前原子落盘,
              // 此处读不到 = 走了 fallback 全量重跑(native 会先删旧文件)。
              Map<String, dynamic>? segs;
              try {
                final segFile = File(
                  '${File(boot.dbPath).parent.path}/finalize_segments.json',
                );
                if (segFile.existsSync()) {
                  segs =
                      jsonDecode(segFile.readAsStringSync())
                          as Map<String, dynamic>;
                }
              } catch (e) {
                wlog('finalize segments read failed (non-fatal): $e');
              }
              final telP2 = PwTelemetry.sample();
              if (segs != null) {
                telem('finalize_segments', {
                  ...segs,
                  if (telP2 != null) 'thermal': telP2.thermalState,
                  if (telP2 != null)
                    'mem_mb': telP2.physFootprintMb.round(),
                });
              } else {
                wlog(
                  'finalize_segments.json missing — phase 2 likely took the '
                  'db-rerun fallback (segments telemetry unavailable)',
                );
              }
              // 遥测【finalize/phase2】:后台全局 BA wall + 配置回显
              // (RefineGlobalBA 的 popts,native out_json 不回传这些,
              // source=config_echo;phase2 无独立 reproj 输出,最终
              // reproj 见 geom 事件的重算不可得 → 沿用 phase1 字段)。
              // wall 分段字段 + 实测 solver 从 segments 透传(native 实测,
              // 非 config_echo)。
              telem('finalize_phase2', {
                'wall_ms': ms,
                'loss_global': 'cauchy@1.0',
                'solver': 'dense_schur_override',
                'gftol': 1e-6,
                'gref': 5,
                'giter': 50,
                'source': 'config_echo',
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
              // pwsfm_repair_stats 符号 → 抛进 catch,非致命。
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
                final g = _triAngleTelemetry(s.pointsTracked(), s.posesPacked());
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
        idleRepayTimer?.cancel();
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
    for (var j = offs[i];
        j < offs[i + 1] && cams.length < maxObsPerPoint;
        j++) {
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
        final cosAng =
            ((ax * bx + ay * by + az * bz) / (an * bn)).clamp(-1.0, 1.0);
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
