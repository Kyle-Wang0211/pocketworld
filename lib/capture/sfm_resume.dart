// The RECOVERY leg of the "a capture always ends up with a sparse cloud"
// guarantee.
//
// During capture, every keyframe's keypoints + matches are written into
// <captureDir>/sfm_live.db. The live finalize turns that into
// <captureDir>/sfm_sparse.ply. But finalize is minutes-scale and can be killed
// mid-flight — the user backgrounds the app, or a hot/large capture gets jetsam
// -ed under memory+thermal pressure — leaving a db but no PLY (the draft can't
// open its cloud). The in-session iOS-26 umbrella protects the FIRST attempt;
// this recovery helper is the safety net for when even that loses: an explicit
// user recovery action can find captures with a db but no PLY and re-run
// finalize STRAIGHT FROM THE DB
// (no frames needed — aether_sfm_create opens the existing db, RunIncremental
// reads keypoints/matches from it), on a now-cooler device, one at a time,
// under the umbrella. Idempotent + best-effort: a retry that still fails is left
// for the next launch, so output is guaranteed as long as the app runs again —
// it never depends on the user's capture timing or the device staying cool.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../me/scan_record_store.dart';
import '../util/device_log.dart';
import 'representative_color.dart';
import 'sfm_live_recon.dart';
import 'sparse_ply.dart';

const MethodChannel _arKitChannel = MethodChannel('aether_arkit');

bool _sweeping = false;
final Set<String> _detachedFinalizing = <String>{};

/// Continue a just-finished live capture after the capture page exits.
///
/// The UI contract is deliberately simple: saving the draft is the foreground
/// completion condition; SfM drains its queued frames and writes only the final
/// refined sparse cloud in the background. No LOCAL/preview cloud is persisted
/// as the user-visible result.
void startDetachedSfmFinalize({
  required String captureDir,
  required SfmLiveRecon recon,
  Iterable<String> keepJpegPaths = const <String>[],
}) {
  if (!_detachedFinalizing.add(captureDir)) {
    DeviceLog.log('SfmResume', 'detached already running for $captureDir');
    unawaited(recon.dispose());
    return;
  }
  unawaited(_runDetachedFinalize(captureDir, recon, keepJpegPaths.toSet()));
}

/// Scans drafts for captures that have an SfM db but no persisted sparse cloud
/// and re-runs finalize for each. This must only be called from an explicit user
/// recovery action. BGContinuedProcessingTaskRequest may not be submitted just
/// because the app launched; doing so creates unsolicited Dynamic Island jobs.
Future<void> resumeIncompleteCaptures() async {
  if (_sweeping) return;
  _sweeping = true;
  try {
    await ScanRecordStore.instance.ensureLoaded();
    final records = ScanRecordStore.instance.records;
    final docs = (await getApplicationDocumentsDirectory()).path;
    DeviceLog.log(
      'SfmResume',
      'sweep start: ${records.length} records | docs=$docs',
    );
    final pending = <String>[];
    for (final r in records) {
      var dir = r.captureDir;
      if (dir == null || dir.isEmpty) continue;
      // Robust against a changed app-container UUID: if the stored absolute
      // path is stale, rebuild it under the CURRENT documents dir by its
      // capture-dir name (which equals the record id).
      if (!File('$dir/sfm_live.db').existsSync()) {
        final rebuilt = '$docs/captures/${dir.split('/').last}';
        if (File('$rebuilt/sfm_live.db').existsSync()) dir = rebuilt;
      }
      final hasDb = File('$dir/sfm_live.db').existsSync();
      final hasPly = File('$dir/sfm_sparse.ply').existsSync();
      DeviceLog.log(
        'SfmResume',
        '  ${dir.split('/').last}: db=$hasDb ply=$hasPly',
      );
      if (hasDb && !hasPly && !_detachedFinalizing.contains(dir)) {
        pending.add(dir);
      }
    }
    DeviceLog.log(
      'SfmResume',
      'sweep: ${pending.length} capture(s) to recover',
    );
    for (final dir in pending) {
      await _resumeOne(dir);
    }
  } catch (e, st) {
    DeviceLog.log('SfmResume', 'sweep error: $e\n$st');
  } finally {
    _sweeping = false;
  }
}

Future<void> _runDetachedFinalize(
  String captureDir,
  SfmLiveRecon recon,
  Set<String> keepJpegPaths,
) async {
  StreamSubscription<SfmLiveEvent>? sub;
  final done = Completer<void>();
  try {
    await _umbrella('beginReconUmbrella', captureDir);
    sub = recon.events.listen((e) {
      switch (e) {
        case SfmLiveLocalReady(:final snapshot):
          DeviceLog.log(
            'SfmResume',
            'detached local ignored: ${snapshot.pointCount} pts',
          );
        case SfmLiveRefined(:final snapshot):
          unawaited(() async {
            try {
              await _persistColored(captureDir, snapshot);
              await _prunePhotosAfterSparse(captureDir, keepJpegPaths);
            } catch (e) {
              DeviceLog.log('SfmResume', 'detached persist failed: $e');
            } finally {
              if (!done.isCompleted) done.complete();
            }
          }());
        case SfmLiveFailed(:final stage, :final message):
          DeviceLog.log(
            'SfmResume',
            'detached failed for $captureDir: $stage $message',
          );
          if (!done.isCompleted) done.complete();
        default:
          break;
      }
    });
    DeviceLog.log(
      'SfmResume',
      'detached finalize start: $captureDir keep=${keepJpegPaths.length}',
    );
    recon.finalize();
    await done.future.timeout(
      const Duration(minutes: 12),
      onTimeout: () {
        DeviceLog.log('SfmResume', 'detached timed out for $captureDir');
      },
    );
  } catch (e) {
    DeviceLog.log('SfmResume', 'detached error $captureDir: $e');
  } finally {
    await sub?.cancel();
    await recon.dispose();
    await _umbrella('endReconUmbrella', captureDir);
    _detachedFinalizing.remove(captureDir);
  }
}

Future<void> _resumeOne(String captureDir) async {
  SfmLiveRecon? recon;
  final done = Completer<void>();
  try {
    await _umbrella('beginReconUmbrella', captureDir);
    recon = await SfmLiveRecon.start(dbPath: '$captureDir/sfm_live.db');
    if (recon == null) {
      DeviceLog.log('SfmResume', 'start unavailable for $captureDir');
      return;
    }
    final sub = recon.events.listen((e) {
      switch (e) {
        case SfmLiveLocalReady(:final snapshot):
          DeviceLog.log(
            'SfmResume',
            'resume local ignored: ${snapshot.pointCount} pts',
          );
        case SfmLiveRefined(:final snapshot):
          unawaited(_persistColored(captureDir, snapshot));
          if (!done.isCompleted) done.complete();
        case SfmLiveFailed(:final stage, :final message):
          DeviceLog.log(
            'SfmResume',
            'resume $captureDir failed: $stage $message',
          );
          if (!done.isCompleted) done.complete();
        default:
          break;
      }
    });
    recon.resumeFromDb();
    // Bound the wait so one stubborn capture can't stall the whole sweep. We do
    // not persist LOCAL as the final user-visible cloud; a failed refine leaves
    // the db for a later retry.
    await done.future.timeout(
      const Duration(minutes: 8),
      onTimeout: () {
        DeviceLog.log('SfmResume', '$captureDir timed out (kept partial/none)');
      },
    );
    await sub.cancel();
    final ok = File('$captureDir/sfm_sparse.ply').existsSync();
    DeviceLog.log('SfmResume', 'recovered $captureDir → ply=$ok');
  } catch (e) {
    DeviceLog.log('SfmResume', 'resume error $captureDir: $e');
  } finally {
    if (recon != null) await recon.dispose();
    await _umbrella('endReconUmbrella', captureDir);
  }
}

/// Colorize a recovered cloud to FULL FIDELITY — the same track-observation
/// sampling the live colorizer uses (each point sampled only in the frames of
/// its own track, full-res bilinear at xy-0.5, 归约取亮度中位的真实观测代表色
/// ——不算术平均,见 representative_color.dart), then persist. True color is a baseline of the
/// sparse cloud, not an enhancement; a recovered draft looks identical to one
/// finalized live.
Future<void> _persistColored(String captureDir, SfmLiveSnapshot snap) async {
  final n = snap.pointCount;
  if (n == 0) return;
  final frameMeta = await _loadFrameMeta(captureDir);
  final offs = snap.obsOffsets;
  final fids = snap.obsFrameIds;
  final oxy = snap.obsXY;
  final rgb = Uint8List(n * 3);

  if (frameMeta.isEmpty || fids.isEmpty || offs.length != n + 1) {
    // No color source found (photos missing). Never leave a recovered cloud
    // unpersisted — neutral gray so at least the structure is viewable.
    for (var i = 0; i < n; i++) {
      rgb[i * 3] = 185;
      rgb[i * 3 + 1] = 185;
      rgb[i * 3 + 2] = 190;
    }
    DeviceLog.log(
      'SfmResume',
      'colorize: no photo source for $captureDir → gray',
    );
    await persistSparseSnapshot(
      captureDir: captureDir,
      snapshot: snap,
      rgb: rgb,
    );
    return;
  }

  // Group observations by frame so every JPEG decodes exactly once.
  // obsCap 顺带统计每点有效观测数,作为样本池的预分配容量。
  final byFrame = <int, List<double>>{};
  final obsCap = Int32List(n);
  for (var i = 0; i < n; i++) {
    for (var j = offs[i]; j < offs[i + 1]; j++) {
      final f = fids[j];
      if (!frameMeta.containsKey(f)) continue;
      obsCap[i]++;
      (byFrame[f] ??= <double>[])
        ..add(i.toDouble())
        ..add(oxy[j * 2])
        ..add(oxy[j * 2 + 1]);
    }
  }

  // 代表色样本池:与 live 侧 _colorizeSnapshot 完全同构(共享
  // representative_color.dart),保证冷恢复与现场取色逐点一致。
  final samples = RepresentativeColorSamples(obsCap);
  for (final entry in byFrame.entries) {
    final meta = frameMeta[entry.key]!;
    final sj = await _decodeJpegNative(meta.jpegPath);
    if (sj == null) continue;
    final scaleX = sj.w / meta.grayW, scaleY = sj.h / meta.grayH;
    final rgbP = sj.rgb;
    final jw = sj.w, jh = sj.h;
    final tri = entry.value;
    for (var k = 0; k < tri.length; k += 3) {
      final i = tri[k].toInt();
      // COLMAP samples at xy - 0.5 (pixel-center convention), bilinear,
      // out-of-bounds skipped.
      final fx = tri[k + 1] * scaleX - 0.5;
      final fy = tri[k + 2] * scaleY - 0.5;
      final x0 = fx.floor(), y0 = fy.floor();
      final x1 = x0 + 1, y1 = y0 + 1;
      if (x0 < 0 || y0 < 0 || x1 >= jw || y1 >= jh) continue;
      final dx = fx - x0, dy = fy - y0;
      final w00 = (1 - dx) * (1 - dy), w01 = dx * (1 - dy);
      final w10 = (1 - dx) * dy, w11 = dx * dy;
      final o00 = (y0 * jw + x0) * 3, o01 = (y0 * jw + x1) * 3;
      final o10 = (y1 * jw + x0) * 3, o11 = (y1 * jw + x1) * 3;
      samples.add(
        i,
        w00 * rgbP[o00] + w01 * rgbP[o01] + w10 * rgbP[o10] + w11 * rgbP[o11],
        w00 * rgbP[o00 + 1] +
            w01 * rgbP[o01 + 1] +
            w10 * rgbP[o10 + 1] +
            w11 * rgbP[o11 + 1],
        w00 * rgbP[o00 + 2] +
            w01 * rgbP[o01 + 2] +
            w10 * rgbP[o10 + 2] +
            w11 * rgbP[o11 + 2],
      );
    }
  }

  var colored = 0;
  for (var i = 0; i < n; i++) {
    // 代表色归约:选亮度中位的真实观测样本,不合成新颜色。
    if (samples.selectInto(i, rgb)) {
      colored++;
    } else {
      rgb[i * 3] = 185;
      rgb[i * 3 + 1] = 185;
      rgb[i * 3 + 2] = 190;
    }
  }
  DeviceLog.log(
    'SfmResume',
    'colorized ${snap.refined ? "refined" : "local"}: $colored/$n pts '
        'from ${byFrame.length} frames (${frameMeta.length} mapped)',
  );
  await persistSparseSnapshot(captureDir: captureDir, snapshot: snap, rgb: rgb);
}

Future<void> _prunePhotosAfterSparse(
  String captureDir,
  Set<String> keepJpegPaths,
) async {
  if (keepJpegPaths.isEmpty) return;
  final keepNames = <String>{
    for (final path in keepJpegPaths) path.split('/').last,
  };
  Future<void> pruneDir(String dirPath, {required bool sidecars}) async {
    final dir = Directory(dirPath);
    if (!await dir.exists()) return;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final path = entity.path;
      if (!path.endsWith('.jpg') && !(sidecars && path.endsWith('.json'))) {
        continue;
      }
      final name = path.split('/').last;
      final jpgName = name.endsWith('.json')
          ? '${name.substring(0, name.length - '.json'.length)}.jpg'
          : name;
      if (keepNames.contains(jpgName)) continue;
      try {
        await entity.delete();
      } on FileSystemException {
        // Best effort: a late filesystem reader may still have the file open.
      }
    }
  }

  await pruneDir('$captureDir/photos_highres', sidecars: true);
  await pruneDir('$captureDir/previews', sidecars: false);
  DeviceLog.log(
    'SfmResume',
    'post-sparse photo prune: kept=${keepNames.length} capture=$captureDir',
  );
}

/// Maps each SfM frame-id → its color photo + the gray dims its keypoints live
/// in. Prefers the exact `sfm_fed_frames.jsonl` sidecar written during capture;
/// falls back (for captures made before that existed, e.g. legacy drafts) to
/// the identity "SfM frame-id N == Nth shutter photo by capture timestamp",
/// which holds because frames are fed to SfM in tap order. Paths are rebuilt
/// under the CURRENT captureDir so a changed app-container UUID can't stale them.
Future<Map<int, ({String jpegPath, int grayW, int grayH})>> _loadFrameMeta(
  String captureDir,
) async {
  final photosDir = '$captureDir/photos_highres';
  final map = <int, ({String jpegPath, int grayW, int grayH})>{};

  final sidecar = File('$captureDir/sfm_fed_frames.jsonl');
  if (sidecar.existsSync()) {
    try {
      for (final line in await sidecar.readAsLines()) {
        if (line.trim().isEmpty) continue;
        final m = jsonDecode(line) as Map<String, Object?>;
        final fid = m['frameId'] as int;
        final jpeg = '$photosDir/${(m['jpegPath'] as String).split('/').last}';
        map[fid] = (
          jpegPath: jpeg,
          grayW: (m['grayW'] as num).toInt(),
          grayH: (m['grayH'] as num).toInt(),
        );
      }
    } catch (_) {}
    if (map.isNotEmpty) return map;
  }

  // Legacy fallback: order the per-frame JSONs by capture timestamp.
  final dir = Directory(photosDir);
  if (!dir.existsSync()) return map;
  final rows = <({double t, String jpeg, int w, int h})>[];
  for (final f in dir.listSync()) {
    if (!f.path.endsWith('.json')) continue;
    try {
      final j =
          jsonDecode(await File(f.path).readAsString()) as Map<String, Object?>;
      final t =
          (j['t'] as num?)?.toDouble() ??
          (j['save_target_t'] as num?)?.toDouble() ??
          0;
      final w = (j['image_w'] as num?)?.toInt() ?? 3840;
      final h = (j['image_h'] as num?)?.toInt() ?? 2160;
      final jpeg = f.path.replaceAll(RegExp(r'\.json$'), '.jpg');
      if (File(jpeg).existsSync()) rows.add((t: t, jpeg: jpeg, w: w, h: h));
    } catch (_) {}
  }
  rows.sort((a, b) => a.t.compareTo(b.t));
  for (var i = 0; i < rows.length; i++) {
    map[i] = (jpegPath: rows[i].jpeg, grayW: rows[i].w, grayH: rows[i].h);
  }
  return map;
}

/// Fast native JPEG decode (ImageIO downscale to 1280px, raw sensor
/// orientation) — the same channel the live colorizer uses.
Future<({Uint8List rgb, int w, int h})?> _decodeJpegNative(
  String jpegPath,
) async {
  try {
    final res = await _arKitChannel.invokeMethod<Map<Object?, Object?>>(
      'decodeJpegForColor',
      {'jpegPath': jpegPath, 'maxPx': 1280},
    );
    if (res == null) return null;
    final w = res['w'] as int?, h = res['h'] as int?;
    final rgb = res['rgb'] as Uint8List?;
    if (w == null || h == null || rgb == null || w <= 0 || h <= 0) return null;
    if (rgb.length < w * h * 3) return null;
    return (rgb: rgb, w: w, h: h);
  } catch (_) {
    return null;
  }
}

Future<void> _umbrella(String method, String captureDir) async {
  try {
    await _arKitChannel.invokeMethod<void>(method, <String, Object?>{
      'jobId': captureDir,
    });
  } catch (_) {}
}
