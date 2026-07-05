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
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart' as vm;

import '../aether_sfm_ffi.dart';
import '../dome/ar_pose.dart' show SfmFrameFeed;
import '../util/device_log.dart';

/// One reconstruction snapshot (LOCAL_READY or REFINED). Always the FULL
/// point set — render-side thinning is allowed, data-side never.
class SfmLiveSnapshot {
  const SfmLiveSnapshot({
    required this.xyz,
    required this.rgb,
    required this.posesPacked,
    required this.summary,
    required this.refined,
  });

  /// 3 floats per point.
  final Float32List xyz;

  /// 3 bytes per point; may be all zeros (on-device extract_colors is off) —
  /// renderers must fall back to a uniform tint / height ramp, NOT treat
  /// black as failure.
  final Uint8List rgb;

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

/// A keyframe was dropped by backpressure (queue depth > 1). Not an error.
class SfmLiveFrameDropped extends SfmLiveEvent {
  const SfmLiveFrameDropped(this.seq);
  final int seq;
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

/// Main-isolate handle to the streaming-SfM worker. Create per capture take
/// via [start]; feed via [offerFrame]; end via [finalize]; ALWAYS [dispose]
/// (joins the native background thread + drops the session sqlite db).
class SfmLiveRecon {
  // A ReceivePort is single-subscription and CLOSES on cancel, so the ONE
  // subscription opened in [start] (which also handled the handshake) is
  // handed over here — never listen twice on the same port.
  SfmLiveRecon._(this._toWorker, this._fromWorker, this._isolate, this._sub);

  final SendPort _toWorker;
  final ReceivePort _fromWorker;
  final Isolate _isolate;
  final StreamSubscription<dynamic> _sub;

  final _events = StreamController<SfmLiveEvent>.broadcast();
  Stream<SfmLiveEvent> get events => _events.stream;

  int _seq = 0;
  int _inFlight = 0; // frames sent to the worker but not yet acked
  int _fedOk = 0;
  int _dropped = 0;
  bool _finalizeSent = false;
  bool _disposed = false;
  Completer<void>? _disposeAck;

  /// Keyframes successfully added to the live reconstruction.
  int get fedCount => _fedOk;

  /// Keyframes dropped by backpressure.
  int get droppedCount => _dropped;

  bool get finalizeStarted => _finalizeSent;

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
      port = await handshake.future
          .timeout(const Duration(seconds: 10), onTimeout: () => null);
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
    recon = SfmLiveRecon._(port, fromWorker, isolate, sub);
    DeviceLog.log('SfmLive', 'worker up (db=$dbPath)');
    return recon;
  }

  /// Offers one keyframe to the live reconstruction. Returns false when the
  /// frame was dropped (backpressure: >1 frame already queued behind the
  /// one executing) or the feed lacks what add_frame needs. NEVER blocks.
  bool offerFrame(SfmFrameFeed feed) {
    if (_disposed || _finalizeSent) return false;
    final seq = ++_seq;
    // Backpressure rule from the integration contract: with add_frame at
    // ~0.6 s/frame, allow 1 executing + 1 queued; anything beyond drops.
    if (_inFlight >= 2) {
      _dropped++;
      _events.add(SfmLiveFrameDropped(seq));
      DeviceLog.log('SfmLive',
          'frame#$seq DROPPED (inFlight=$_inFlight, dropped=$_dropped)');
      return false;
    }
    if (feed.intrinsicFxFyCxCy.length < 4 || feed.imageW <= 0) {
      return false;
    }
    // Uniform intrinsics rescale full-res → gray resolution (the native
    // extract preserves aspect, so one factor serves fx/fy/cx/cy).
    final s = feed.grayW / feed.imageW;
    final fx = feed.intrinsicFxFyCxCy[0] * s;
    final fy = feed.intrinsicFxFyCxCy[1] * s;
    final cx = feed.intrinsicFxFyCxCy[2] * s;
    final cy = feed.intrinsicFxFyCxCy[3] * s;

    // ARKit extrinsic is column-major camera-to-world; the ABI wants the
    // CamFromWorld (world→camera) prior. v1 stores it unused, but we pass a
    // correct value so the follow-up solver version can turn it on.
    Float64List? quatWxyz;
    Float64List? trans;
    if (feed.extrinsic4x4.length == 16) {
      final c2w = vm.Matrix4.fromList(feed.extrinsic4x4);
      final rW2c = c2w.getRotation()..transpose();
      final tW2c = rW2c.transform(-c2w.getTranslation());
      final q = vm.Quaternion.fromRotation(rW2c)..normalize();
      quatWxyz = Float64List.fromList([q.w, q.x, q.y, q.z]);
      trans = Float64List.fromList([tW2c.x, tW2c.y, tW2c.z]);
    }

    _inFlight++;
    _toWorker.send(<String, Object?>{
      'cmd': 'frame',
      'seq': seq,
      'gray': feed.gray,
      'w': feed.grayW,
      'h': feed.grayH,
      'fx': fx,
      'fy': fy,
      'cx': cx,
      'cy': cy,
      'q': quatWxyz,
      't': trans,
    });
    return true;
  }

  /// Ends the capture: after the already-queued frames are consumed the
  /// worker runs finalize_async (phase 1 blocks in-worker; LOCAL_READY and
  /// REFINED/ERROR arrive via [events]).
  void finalize() {
    if (_disposed || _finalizeSent) return;
    _finalizeSent = true;
    _toWorker.send(const <String, Object?>{'cmd': 'finalize'});
  }

  /// Frees the native session (joins the background BA thread, drops the
  /// sqlite db) and tears the isolate down. Safe to call more than once.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
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
        _events.add(SfmLiveFrameFed(
          seq: msg['seq'] as int,
          frameId: msg['frameId'] as int,
          elapsedMs: msg['ms'] as int,
          result: msg['result'] as String,
        ));
      case 'local_ready':
        _events.add(SfmLiveLocalReady(
          _snapshotFromMsg(msg, refined: false),
          msg['ms'] as int,
        ));
      case 'refined':
        _events.add(SfmLiveRefined(
          _snapshotFromMsg(msg, refined: true),
          msg['ms'] as int,
        ));
      case 'error':
        _events.add(SfmLiveFailed(
          msg['stage'] as String? ?? 'unknown',
          msg['message'] as String? ?? 'unknown',
        ));
      case 'disposed':
        _disposeAck?.complete();
    }
  }

  static SfmLiveSnapshot _snapshotFromMsg(Map msg, {required bool refined}) {
    return SfmLiveSnapshot(
      xyz: msg['xyz'] as Float32List? ?? Float32List(0),
      rgb: msg['rgb'] as Uint8List? ?? Uint8List(0),
      posesPacked: msg['poses'] as Float64List? ?? Float64List(0),
      summary: (msg['summary'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{},
      refined: refined,
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

  void wlog(String line) {
    boot.reply.send(<String, Object?>{'evt': 'log', 'line': line});
  }

  void sendSnapshot(String evt, Map<String, dynamic> summary, int ms) {
    final s = session;
    if (s == null) return;
    final points = s.pointsPacked();
    final poses = s.posesPacked();
    wlog('$evt: points=${points.count} poses=${poses.length ~/ 9} '
        'ms=$ms summary=$summary');
    boot.reply.send(<String, Object?>{
      'evt': evt,
      'xyz': points.xyz,
      'rgb': points.rgb,
      'poses': poses,
      'summary': summary,
      'ms': ms,
    });
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
            );
            wlog('session created (${w}x$h, db=${boot.dbPath})');
            // DIAGNOSTIC TAP (errNotRegistered investigation): dump the
            // first gray frame as a viewable PGM next to the db, plus the
            // exact intrinsics fed — settles the "is the gray content /
            // calibration sane?" question with one capture round.
            try {
              final pgm = File(
                  '${File(boot.dbPath).parent.path}/sfm_debug_frame0.pgm');
              final header = 'P5\n$w $h\n255\n'.codeUnits;
              pgm.writeAsBytesSync(
                  [...header, ...(msg['gray'] as Uint8List)]);
              wlog('debug: frame0 PGM dumped (${pgm.path}) '
                  'fx=${msg['fx']} fy=${msg['fy']} '
                  'cx=${msg['cx']} cy=${msg['cy']}');
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
          wlog('add_frame seq=${msg['seq']} frameId=${r.frameId} '
              'rc=${r.result.name} ms=${sw.elapsedMilliseconds} (${w}x$h)');
          boot.reply.send(<String, Object?>{
            'evt': 'frame_done',
            'seq': msg['seq'],
            'frameId': r.frameId,
            'ms': sw.elapsedMilliseconds,
            'result': r.result.name,
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
      case 'finalize':
        final s = session;
        if (s == null) {
          fail('finalize', 'no frames were fed — nothing to reconstruct');
          break;
        }
        final sw = Stopwatch()..start();
        try {
          // Phase 1 (blocking here, minutes-scale): incremental register +
          // local BA. On OK the LOCAL model is immediately readable.
          wlog('finalize_async phase-1 starting…');
          final summary = s.finalizeAsync();
          sw.stop();
          if (summary['result'] != 'ok') {
            // DIAGNOSTIC TAP: preserve the accumulated sqlite db before the
            // session drops it, so keypoint/match/two-view-geometry counts
            // can be inspected off-device (sqlite3) to see where the chain
            // broke. Copied as .debug — the pipeline never reads it.
            try {
              final db = File(boot.dbPath);
              if (db.existsSync()) {
                db.copySync('${boot.dbPath}.debug');
                wlog('debug: db preserved at ${boot.dbPath}.debug '
                    '(${db.lengthSync()} bytes)');
              }
            } catch (e) {
              wlog('debug: db preserve failed: $e');
            }
            fail('finalize',
                '${summary['result']} (rc=${summary['rc']}) $summary');
            break;
          }
          sendSnapshot('local_ready', summary, sw.elapsedMilliseconds);
          // Phase 2 runs on the session's own native thread; poll the
          // lock-free status flag until it lands.
          refineStart = DateTime.now().millisecondsSinceEpoch;
          pollTimer = Timer.periodic(const Duration(milliseconds: 700), (t) {
            final st = s.finalizeStatus();
            if (st == AetherSfmFinalizeStatus.refined) {
              t.cancel();
              final ms =
                  DateTime.now().millisecondsSinceEpoch - refineStart;
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
