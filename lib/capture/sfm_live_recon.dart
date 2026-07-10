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
import 'pw_telemetry.dart';

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
  List<SfmDisconnectedSegment> get disconnectedSegments {
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

/// Phase 1 of finalize done — local reconstruction is live.
class SfmLiveLocalReady extends SfmLiveEvent {
  const SfmLiveLocalReady(this.snapshot, this.finalizeMs);
  final SfmLiveSnapshot snapshot;
  final int finalizeMs;
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
    _toWorker.send(const <String, Object?>{'cmd': 'finalize'});
  }

  /// Ends the capture. New frames are refused from this moment; the worker
  /// finishes the disk queue first, then runs finalize_async (phase 1
  /// blocks in-worker; LOCAL_READY and REFINED/ERROR arrive via [events]).
  void finalize() {
    if (_disposed || _finalizeRequested) return;
    _finalizeRequested = true;
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
  ///   R_w = R_ark^T · R_col
  /// is the rotation that carries COLMAP world → ARKit (gravity) world; the
  /// per-frame estimates cluster tightly (same rigid alignment), so a naive
  /// sign-aligned quaternion mean is robust. We rotate every point by the
  /// mean R_w so the floor is horizontal and +Y is up — the viewer then needs
  /// no arbitrary default tilt. Points only (poses left as COLMAP; nothing
  /// downstream pairs them with the aligned points). Falls back to the
  /// original cloud when fewer than 3 registered frames carry an ARKit quat.
  SfmLiveSnapshot _gravityAlign(SfmLiveSnapshot snap) {
    final poses = snap.posesPacked;
    if (snap.xyz.isEmpty || poses.isEmpty) return snap;

    // Hamilton product a*b (w,x,y,z).
    List<double> qmul(List<double> a, List<double> b) => [
      a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
      a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
      a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
      a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0],
    ];

    var aw = 0.0, ax = 0.0, ay = 0.0, az = 0.0;
    List<double>? ref;
    var cnt = 0;
    for (var i = 0; i < poses.length; i += 9) {
      if (poses[i + 1] == 0) continue; // unregistered
      final meta = _fedMeta[poses[i].toInt()];
      final aq = meta?.arkitQuatWxyz;
      if (aq == null || aq.length != 4) continue;
      final qCol = [poses[i + 2], poses[i + 3], poses[i + 4], poses[i + 5]];
      final qArkConj = [aq[0], -aq[1], -aq[2], -aq[3]]; // R_ark^T
      // C = diag(1,-1,-1): ARKit camera looks along -Z with +Y up; COLMAP
      // looks along +Z with +Y down. Without this fixed camera-convention
      // flip the per-frame R_w estimates scatter ~33° (validated on real
      // capture data); with it they cluster to <2°. C = 180° about X = qC.
      const qC = [0.0, 1.0, 0.0, 0.0];
      var qw = qmul(qArkConj, qmul(qC, qCol)); // R_w = R_ark^T · C · R_col
      final norm = math.sqrt(
        qw[0] * qw[0] + qw[1] * qw[1] + qw[2] * qw[2] + qw[3] * qw[3],
      );
      if (norm < 1e-9) continue;
      qw = [qw[0] / norm, qw[1] / norm, qw[2] / norm, qw[3] / norm];
      ref ??= qw;
      // Sign-align to the reference hemisphere before summing.
      final dot =
          qw[0] * ref[0] + qw[1] * ref[1] + qw[2] * ref[2] + qw[3] * ref[3];
      final s = dot < 0 ? -1.0 : 1.0;
      aw += s * qw[0];
      ax += s * qw[1];
      ay += s * qw[2];
      az += s * qw[3];
      cnt++;
    }
    if (cnt < 3) return snap; // not enough evidence — don't risk a bad tilt

    final an = math.sqrt(aw * aw + ax * ax + ay * ay + az * az);
    if (an < 1e-9) return snap;
    final w = aw / an, x = ax / an, y = ay / an, z = az / an;
    // Rotation matrix rows for the mean R_w.
    final r00 = 1 - 2 * (y * y + z * z),
        r01 = 2 * (x * y - z * w),
        r02 = 2 * (x * z + y * w);
    final r10 = 2 * (x * y + z * w),
        r11 = 1 - 2 * (x * x + z * z),
        r12 = 2 * (y * z - x * w);
    final r20 = 2 * (x * z - y * w),
        r21 = 2 * (y * z + x * w),
        r22 = 1 - 2 * (x * x + y * y);

    final src = snap.xyz;
    final out = Float32List(src.length);
    for (var i = 0; i < src.length; i += 3) {
      final px = src[i], py = src[i + 1], pz = src[i + 2];
      out[i] = r00 * px + r01 * py + r02 * pz;
      out[i + 1] = r10 * px + r11 * py + r12 * pz;
      out[i + 2] = r20 * px + r21 * py + r22 * pz;
    }
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
  // True session high-water footprint — the public TASK_VM_INFO layout has no
  // historical peak field, so we take a running max of the instantaneous
  // sample taken right after each heavy native call.
  var peakMb = 0.0;

  void wlog(String line) {
    boot.reply.send(<String, Object?>{'evt': 'log', 'line': line});
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
    }
    // posesPacked() reads the FINALIZE recon (s->recon), which is empty until the
    // deferred global BA runs — so for the streaming preview it carries nothing
    // useful (and would exercise get_poses' not-registered path). The streaming
    // cloud is already in ARKit gravity-world (points triangulated in ARKit world,
    // the windowed BA gauge pinned to ARKit-world points), so it needs no gravity
    // rotation → send empty poses and let _gravityAlign no-op.
    final poses = preview ? Float64List(0) : s.posesPacked();
    wlog(
      '$evt: points=${points.count} obs=${points.obsCount} '
      'poses=${poses.length ~/ 9} ms=$ms summary=$deliveredSummary',
    );
    if (preview) {
      final st = s.streamStats();
      final tvgPct = (st.tvgPairs + st.rawPairs) > 0
          ? (100 * st.tvgPairs / (st.tvgPairs + st.rawPairs)).round()
          : 0;
      wlog(
        'stream-stats: tvg-inlier pairs=${st.tvgPairs} raw-fallback=${st.rawPairs} '
        '($tvgPct% verified) | grow accept=${st.growAccepted} '
        'reject=${st.growRejected} | filtered reproj=${st.reprojFiltered} '
        'tri-angle=${st.triFiltered}',
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
          });
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
            session = AetherSfmStreamSession.create(
              boot.dbPath,
              imageWidth: (msg['w'] as int?) ?? 3840,
              imageHeight: (msg['h'] as int?) ?? 2160,
              maxFeatures: AetherSfmStreamSession.liveMaxFeatures,
              kNeighbors: AetherSfmStreamSession.liveKNeighbors,
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
        wlog(
          'finalize requested: queue already drained; running full async '
          'finalize and withholding LOCAL from the user-visible result',
        );
        final sw = Stopwatch()..start();
        try {
          // Phase 1 (blocking here, minutes-scale): incremental register +
          // local BA. On OK the LOCAL model is immediately readable.
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
          wlog('local_ready withheld; waiting for refined final snapshot');
          // Phase 2 runs on the session's own native thread; poll the
          // lock-free status flag until it lands.
          refineStart = DateTime.now().millisecondsSinceEpoch;
          pollTimer = Timer.periodic(const Duration(milliseconds: 700), (t) {
            final st = s.finalizeStatus();
            if (st == AetherSfmFinalizeStatus.refined) {
              t.cancel();
              final ms = DateTime.now().millisecondsSinceEpoch - refineStart;
              sendSnapshot('refined', summary, ms);
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
