// The RECOVERY leg of the "a capture always ends up with a sparse cloud"
// guarantee.
//
// During capture, every keyframe's keypoints + matches are written into
// <captureDir>/official_sfm_live.db. The live finalize turns that into
// <captureDir>/official_sfm_sparse.ply. But finalize is minutes-scale and can be killed
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
import '../official_util/device_log.dart';
import 'colorize_pipeline.dart';
import 'floater_filter.dart';
import 'representative_color.dart';
import 'sfm_live_recon.dart';
import 'sparse_ply.dart';
import 'telemetry_writer.dart';

const MethodChannel _arKitChannel = MethodChannel('pocketworld_official_arkit');

bool _sweeping = false;
final Set<String> _detachedFinalizing = <String>{};

/// 修2c【断点续跑入口】进行中的单 capture 恢复:captureDir → 完成 future。
/// 同卡重复点击/重进等待页时直接挂到同一个 future 上 —— 绝不为同一个
/// capture 起第二个 worker(与等待页重入契约同精神)。
final Map<String, Future<bool>> _resumeInFlight = <String, Future<bool>>{};

/// [resumeSingleCapture] 是否正在为 [captureDir] 跑。
bool isResumeInFlight(String captureDir) =>
    _resumeInFlight.containsKey(captureDir);

/// 把 record 存的 captureDir 解析成**当前**磁盘上可恢复的目录:app 容器
/// UUID 在重装/迁移后会变,存的绝对路径可能已失效 —— 按目录名(= record
/// id)在当前 Documents/captures_official 下重建。找不到 official_sfm_live.db 时返回 null
/// (无可恢复数据)。与 [resumeIncompleteCaptures] 的 sweep 同一逻辑。
Future<String?> resolveRecoverableCaptureDir(String recordCaptureDir) async {
  if (recordCaptureDir.isEmpty) return null;
  if (File('$recordCaptureDir/official_sfm_live.db').existsSync()) {
    return recordCaptureDir;
  }
  try {
    final docs = (await getApplicationDocumentsDirectory()).path;
    final rebuilt =
        '$docs/captures_official/${recordCaptureDir.split('/').last}';
    if (File('$rebuilt/official_sfm_live.db').existsSync()) return rebuilt;
  } catch (_) {}
  return null;
}

/// 用户显式确认后的单 capture 断点续跑(修2c:草稿卡 → "继续重建"):
/// 从保留的 official_sfm_live.db 重跑 finalize → 取色 → 持久化 PLY,全程灵动岛
/// umbrella 保护(用户主动触发,符合"不凭空创建"契约)。返回"最终
/// official_sfm_sparse.ply 是否已在磁盘上"。幂等:同目录并发调用共享同一 future。
Future<bool> resumeSingleCapture(String captureDir) {
  final existing = _resumeInFlight[captureDir];
  if (existing != null) return existing;
  final completer = Completer<bool>();
  _resumeInFlight[captureDir] = completer.future;
  () async {
    try {
      // 等待页在场、用户盯着进度 —— 给完整 Cauchy phase2 留足余量,
      // 别沿用 sweep 的 8 分钟保守上限把 BA 中途掐死。
      await _resumeOne(captureDir, timeout: const Duration(minutes: 25));
    } catch (e) {
      DeviceLog.log('SfmResume', 'single resume error $captureDir: $e');
    } finally {
      _resumeInFlight.remove(captureDir);
      completer.complete(
        File('$captureDir/official_sfm_sparse.ply').existsSync(),
      );
    }
  }();
  return completer.future;
}

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
      if (!File('$dir/official_sfm_live.db').existsSync()) {
        final rebuilt = '$docs/captures_official/${dir.split('/').last}';
        if (File('$rebuilt/official_sfm_live.db').existsSync()) dir = rebuilt;
      }
      final hasDb = File('$dir/official_sfm_live.db').existsSync();
      final hasPly = File('$dir/official_sfm_sparse.ply').existsSync();
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

Future<void> _resumeOne(
  String captureDir, {
  Duration timeout = const Duration(minutes: 8),
}) async {
  SfmLiveRecon? recon;
  final done = Completer<void>();
  try {
    await _umbrella('beginReconUmbrella', captureDir);
    recon = await SfmLiveRecon.start(
      dbPath: '$captureDir/official_sfm_live.db',
    );
    if (recon == null) {
      DeviceLog.log('SfmResume', 'start unavailable for $captureDir');
      return;
    }
    // 与 live 主路径对齐【重力对齐】:resume 会话没喂过帧,facade 的
    // _fedMeta 为空 → _gravityAlign 会整段跳过(cnt<3),恢复出的点云
    // 歪着。先用拍摄期落盘的 official_sfm_fed_frames.jsonl(含每帧
    // arkitCamFromWorldQwxyz)回填,refined 快照就会走与 live 完全同一条
    // _gravityAlign 链。sidecar 缺失(极老草稿)时按时间戳序兜底,无
    // ARKit 四元数 → 对齐自然跳过(与今日行为一致,诚实降级)。
    final frameMeta = await _loadFrameMeta(captureDir);
    recon.seedFedMeta(frameMeta);
    DeviceLog.log(
      'SfmResume',
      'fed-meta seeded: ${frameMeta.length} frames, '
          'arkitQuat=${frameMeta.values.where((m) => m.arkitQuatWxyz != null).length}',
    );
    final sub = recon.events.listen((e) {
      switch (e) {
        case SfmLiveLocalReady(:final snapshot):
          DeviceLog.log(
            'SfmResume',
            'resume local ignored: ${snapshot.pointCount} pts',
          );
        case SfmLiveRefined(:final snapshot):
          // 与 detached 腿同构:persist 完成(取色+孤点过滤+PLY 落盘)才算
          // 完成 —— 原先 refined 一到就 complete,等待页/调用方在 PLY 尚未
          // 写完时就检查 existsSync,会把成功误报成失败(竞态)。
          unawaited(() async {
            try {
              await _persistColored(captureDir, snapshot, frameMeta: frameMeta);
            } catch (e) {
              DeviceLog.log('SfmResume', 'resume persist failed: $e');
            } finally {
              if (!done.isCompleted) done.complete();
            }
          }());
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
      timeout,
      onTimeout: () {
        DeviceLog.log('SfmResume', '$captureDir timed out (kept partial/none)');
      },
    );
    await sub.cancel();
    final ok = File('$captureDir/official_sfm_sparse.ply').existsSync();
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
Future<void> _persistColored(
  String captureDir,
  SfmLiveSnapshot snap, {
  Map<int, SfmFedFrameMeta>? frameMeta,
}) async {
  final n = snap.pointCount;
  if (n == 0) return;
  frameMeta ??= await _loadFrameMeta(captureDir);
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
    await _filterAndPersist(captureDir, snap, rgb);
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
  // representative_color.dart + colorize_pipeline.dart),保证冷恢复与
  // 现场取色逐点一致。07-12 并行两刀(jpegPath 去重 + 有界并行 3)随
  // 共享 pipeline 一并生效,输出逐位不变(顺序=byFrame 插入序)。
  final samples = RepresentativeColorSamples(obsCap);
  final jobs = <ColorizeFrameJob>[];
  for (final entry in byFrame.entries) {
    final meta = frameMeta[entry.key]!;
    jobs.add(
      ColorizeFrameJob(
        jpegPath: meta.jpegPath,
        grayW: meta.grayW,
        grayH: meta.grayH,
        tri: entry.value,
      ),
    );
  }
  await sampleColorsPipelined(
    jobs: jobs,
    samples: samples,
    decode: _decodeJpegNative,
    maxInFlight: 3,
  );

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
  await _filterAndPersist(captureDir, snap, rgb);
}

/// 与 live 主路径对齐【孤点过滤】:live 在 _colorizeSnapshot 尾部对交付
/// 点云跑保守 orphan filter(零近邻孤点删除,99 分位半径 ×1.2,≥3 观测
/// track 保护)后才持久化;resume 原先直接 persist,浮点全数落盘。这里
/// 用同一共享实现(floater_filter.dart)+ 同参数补齐:过滤 → 紧凑拷贝 →
/// persist(与 live 相同,持久化快照不再携带 obs 数组 —— 观测已被取色
/// 消费,过滤后的索引也不再对应)。
Future<void> _filterAndPersist(
  String captureDir,
  SfmLiveSnapshot snap,
  Uint8List rgb,
) async {
  final n = snap.pointCount;
  final flt = floaterKeepIndices(snap.xyz, obsOffsets: snap.obsOffsets);
  final keepIdx = flt.keep;
  final m = keepIdx.length;
  final removedF = n - m;
  final Float32List fxyz;
  final Uint8List frgb;
  if (removedF <= 0) {
    fxyz = snap.xyz;
    frgb = rgb;
  } else {
    final compact = compactXyzRgbByIndices(snap.xyz, rgb, keepIdx);
    fxyz = compact.xyz;
    frgb = compact.rgb;
  }
  DeviceLog.log(
    'Floater',
    'orphan-filter(resume): kept $m/$n removed=$removedF '
        '(${n == 0 ? "0.0" : (100 * removedF / n).toStringAsFixed(1)}%) | '
        'radius=${flt.radius.toStringAsExponential(2)} kMin=1 '
        'protectedStable=${flt.protectedStable} | ${flt.ms}ms',
  );
  TelemetryWriter.instance.event('floater', {
    'kept': m,
    'removed': removedF,
    'protected_stable': flt.protectedStable,
    'ms': flt.ms,
    'leg': 'resume',
  });
  final fsnap = SfmLiveSnapshot(
    xyz: fxyz,
    rgb: frgb,
    posesPacked: snap.posesPacked,
    summary: snap.summary,
    refined: snap.refined,
    obsOffsets: Int32List(0),
    obsFrameIds: Int32List(0),
    obsXY: Float32List(0),
  );
  await persistSparseSnapshot(
    captureDir: captureDir,
    snapshot: fsnap,
    rgb: frgb,
  );
}

Future<void> _prunePhotosAfterSparse(
  String captureDir,
  Set<String> keepJpegPaths,
) async {
  if (keepJpegPaths.isEmpty) return;
  // [E25 2026-07-20] 与 capture_session.retainOnlyCuratedPhotos 同修:连带
  // 保留 `<base>_hr.jpg`。这是 `_hr` 被删的**第二条**路径(detached finalize /
  // 断点续跑),只修 retainOnlyCuratedPhotos 会漏掉它。
  final keepNames = <String>{
    for (final path in keepJpegPaths) ...<String>[
      path.split('/').last,
      path.split('/').last.replaceFirst(RegExp(r'\.jpg$'), '_hr.jpg'),
    ],
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
/// in, PLUS(重力对齐)该帧的 ARKit CamFromWorld 四元数/平移(拍摄期
/// _persistFedMeta 落盘的 arkitCamFromWorldQwxyz/Txyz)。返回值直接是
/// [SfmFedFrameMeta],可原样回填 recon 的 fed-meta(seedFedMeta)——
/// resume 的取色与重力对齐由此与 live 共享同一数据形状。
/// 注意:sidecar 不含喂入内参(imageW/fx…),这些字段以 gray 尺寸/0 占位;
/// resume 链只消费 jpegPath/grayW/grayH/arkitQuatWxyz,占位字段无人读。
/// Prefers the exact `official_sfm_fed_frames.jsonl` sidecar written during capture;
/// falls back (for captures made before that existed, e.g. legacy drafts) to
/// the identity "SfM frame-id N == Nth shutter photo by capture timestamp",
/// which holds because frames are fed to SfM in tap order. Paths are rebuilt
/// under the CURRENT captureDir so a changed app-container UUID can't stale them.
Future<Map<int, SfmFedFrameMeta>> _loadFrameMeta(String captureDir) async {
  final photosDir = '$captureDir/photos_highres';
  final map = <int, SfmFedFrameMeta>{};

  List<double>? doubles(Object? v) => v is List
      ? v.map((e) => (e as num).toDouble()).toList(growable: false)
      : null;

  final sidecar = File('$captureDir/official_sfm_fed_frames.jsonl');
  if (sidecar.existsSync()) {
    try {
      for (final line in await sidecar.readAsLines()) {
        if (line.trim().isEmpty) continue;
        final m = jsonDecode(line) as Map<String, Object?>;
        final fid = m['frameId'] as int;
        final jpeg = '$photosDir/${(m['jpegPath'] as String).split('/').last}';
        final grayW = (m['grayW'] as num).toInt();
        final grayH = (m['grayH'] as num).toInt();
        map[fid] = SfmFedFrameMeta(
          jpegPath: jpeg,
          imageW: grayW, // 占位(sidecar 不含全分辨率;resume 链不读)
          imageH: grayH,
          grayW: grayW,
          grayH: grayH,
          fx: 0,
          fy: 0,
          cx: 0,
          cy: 0,
          arkitQuatWxyz: doubles(m['arkitCamFromWorldQwxyz']),
          arkitTransTxyz: doubles(m['arkitCamFromWorldTxyz']),
          arkitCameraCenterWorld: doubles(m['arkitCameraCenterWorld']),
        );
      }
    } catch (_) {}
    if (map.isNotEmpty) return map;
  }

  // Legacy fallback: order the per-frame JSONs by capture timestamp.
  // 无 ARKit 四元数 → 重力对齐自然跳过(cnt<3 门),行为与旧版一致。
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
    map[i] = SfmFedFrameMeta(
      jpegPath: rows[i].jpeg,
      imageW: rows[i].w,
      imageH: rows[i].h,
      grayW: rows[i].w,
      grayH: rows[i].h,
      fx: 0,
      fy: 0,
      cx: 0,
      cy: 0,
    );
  }
  return map;
}

/// Fast native JPEG decode (ImageIO at [kColorizeDecodeMaxPx] = 全分辨率,
/// raw sensor orientation) — the same channel the live colorizer uses.
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
