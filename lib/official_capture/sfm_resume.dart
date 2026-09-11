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

import 'package:flutter/foundation.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../me/scan_record_store.dart';
import '../official_util/device_log.dart';
import 'archived_photo_rebuild.dart';
import 'colorize_pipeline.dart';
import 'database_archive_resolver.dart';
import 'photo_archive_coordinator.dart';
import 'photo_archive_resolver.dart';
import 'photo_archive_runtime.dart';
import 'pwva_master.dart';
import 'representative_color.dart';
import 'sfm_live_recon.dart';
import 'sparse_ply.dart';

const MethodChannel _arKitChannel = MethodChannel('pocketworld_official_arkit');

bool _sweeping = false;
final Set<String> _detachedFinalizing = <String>{};

/// 修2c【断点续跑入口】进行中的单 capture 恢复:captureDir → 完成 future。
/// 同卡重复点击/重进等待页时直接挂到同一个 future 上 —— 绝不为同一个
/// capture 起第二个 worker(与等待页重入契约同精神)。
final Map<String, Future<bool>> _resumeInFlight = <String, Future<bool>>{};

/// 「从存档照片重建」的在飞表(与 [_resumeInFlight] 同精神:同一个 capture
/// 永远只有一条在跑)。它比 [_resumeInFlight] 多存一层结果,因为调用方要拿到
/// 逐张的接收/拒绝账,不是一个 bool。
final Map<String, Future<ArchivedRebuildResult>> _rebuildInFlight =
    <String, Future<ArchivedRebuildResult>>{};

/// [resumeSingleCapture] 是否正在为 [captureDir] 跑。
bool isResumeInFlight(String captureDir) =>
    _resumeInFlight.containsKey(captureDir);

/// 按**目录名**(= record id)判断是否有续跑在飞。
///
/// [2026-08-08 用户实机指认"回到草稿页仍显示照片封面和'未完成'"] 草稿页要在
/// 续跑期间把胶囊显示成"生成中",但 record 里存的 captureDir 可能是旧容器的
/// 绝对路径(容器 UUID 会变),精确匹配 [isResumeInFlight] 会漏 —— 与
/// ScanRecordStore._sameDir 同理,按最后一段目录名比。
bool isResumeInFlightForDirName(String dirName) {
  if (dirName.isEmpty) return false;
  return _resumeInFlight.keys.any(
    (d) => d.split('/').where((e) => e.isNotEmpty).last == dirName,
  );
}

/// 测试注入:把 [captureDir] 标记为在飞/落地(生产代码绝不调用)。
@visibleForTesting
void debugSetResumeInFlight(String captureDir, {required bool inFlight}) {
  if (inFlight) {
    _resumeInFlight[captureDir] = Future<bool>.value(true);
  } else {
    _resumeInFlight.remove(captureDir);
  }
}

/// 把 record 存的 captureDir 解析成**当前**磁盘上可恢复的目录:app 容器
/// UUID 在重装/迁移后会变,存的绝对路径可能已失效 —— 按目录名(= record
/// id)在当前 Documents/captures_official 下重建。找不到 official_sfm_live.db 时返回 null
/// (无可恢复数据)。与 [resumeIncompleteCaptures] 的 sweep 同一逻辑。
Future<String?> resolveRecoverableCaptureDir(String recordCaptureDir) async {
  if (recordCaptureDir.isEmpty) return null;
  final resolver = DatabaseArchiveResolver(
    codec: databaseArchiveCodec,
    preprocessor: databaseArchivePreprocessor,
  );
  final direct = Directory(recordCaptureDir);
  if (await resolver.isRecoverable(direct)) return direct.path;
  try {
    final docs = (await getApplicationDocumentsDirectory()).path;
    final rebuilt = Directory(
      '$docs/captures_official/${recordCaptureDir.split('/').last}',
    );
    if (await resolver.isRecoverable(rebuilt)) return rebuilt.path;
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
    final databaseResolver = DatabaseArchiveResolver(
      codec: databaseArchiveCodec,
      preprocessor: databaseArchivePreprocessor,
    );
    for (final r in records) {
      var dir = r.captureDir;
      if (dir == null || dir.isEmpty) continue;
      // Robust against a changed app-container UUID: if the stored absolute
      // path is stale, rebuild it under the CURRENT documents dir by its
      // capture-dir name (which equals the record id).
      var hasDb = await databaseResolver.isRecoverable(Directory(dir));
      if (!hasDb) {
        final rebuilt = '$docs/captures_official/${dir.split('/').last}';
        if (await databaseResolver.isRecoverable(Directory(rebuilt))) {
          dir = rebuilt;
          hasDb = true;
        }
      }
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
  PhotoArchiveActivityLease? archiveLease;
  final done = Completer<void>();
  try {
    archiveLease = photoArchiveCoordinator.beginReconstructionActivity(
      Directory(captureDir),
    );
    await _umbrella('beginReconUmbrella', captureDir);
    final database = await DatabaseArchiveResolver(
      codec: databaseArchiveCodec,
      preprocessor: databaseArchivePreprocessor,
    ).resolveDatabase(Directory(captureDir));
    if (database == null) {
      DeviceLog.log(
        'SfmResume',
        'verified database unavailable for $captureDir',
      );
      return;
    }
    recon = await SfmLiveRecon.start(dbPath: database.path);
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
    final frameMeta = await loadFedFrameMeta(captureDir);
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
    await archiveLease?.close();
    await _clearMaterializedArchiveCache(captureDir);
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
  frameMeta ??= await loadFedFrameMeta(captureDir);
  frameMeta = await _materializeArchivedJpegs(captureDir, frameMeta);
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
    await _persistOfficialEndpoint(captureDir, snap, rgb);
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
  await _persistOfficialEndpoint(captureDir, snap, rgb);
}

/// Resume preserves the same official endpoint as the live route. Colorization
/// supplies RGB only; no Dart point deletion, repair, or enrichment is allowed
/// after COLMAP's final global BA and official filtering.
Future<void> _persistOfficialEndpoint(
  String captureDir,
  SfmLiveSnapshot snap,
  Uint8List rgb,
) async {
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
  await persistSparseSnapshot(
    captureDir: captureDir,
    snapshot: fsnap,
    rgb: rgb,
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
/// [2026-09-11] 改公开:「只重建」模式(采集页无相机档)续跑时同样要回填
/// fed-meta,否则 _gravityAlign 会整段跳过、恢复出的点云歪着(41 号 capture
/// 真机实锤)。两条腿共用这一处读取。
Future<Map<int, SfmFedFrameMeta>> loadFedFrameMeta(String captureDir) async {
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
  // PWVA 主本接管后源 JPEG 不在盘;master-manifest 覆盖 = 该帧可物化。
  final pwvaMastered = await PwvaMasterManifest.readNames(
    Directory(photosDir).parent,
  );
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
      if (File(jpeg).existsSync() ||
          File('$jpeg.jxl').existsSync() ||
          File('$jpeg.lep').existsSync() ||
          pwvaMastered.contains(jpeg.split('/').last)) {
        rows.add((t: t, jpeg: jpeg, w: w, h: h));
      }
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

/// Rehydrates only the JPEGs a later colorization pass will actually read.
///
/// Canonical sources are returned in place. Archive-only sources go through
/// the verified resolver and live in the application cache for the duration of
/// this explicit recovery run.
Future<Map<int, SfmFedFrameMeta>> _materializeArchivedJpegs(
  String captureDir,
  Map<int, SfmFedFrameMeta> frameMeta,
) async {
  if (frameMeta.isEmpty) return frameMeta;
  try {
    final captureDirectory = Directory(captureDir);
    final cacheDirectory = await _archiveRestoreCacheDirectory(captureDir);
    final resolver = PhotoArchiveResolver(
      codec: photoArchiveCodec,
      codecsByName: photoArchiveCodecsByName,
    );
    final resolvedByName = <String, String>{};
    for (final meta in frameMeta.values) {
      final name = meta.jpegPath.split('/').last;
      if (resolvedByName.containsKey(name)) continue;
      final resolved = await resolver.resolveJpeg(
        captureDirectory: captureDirectory,
        highresFilename: name,
        cacheDirectory: cacheDirectory,
      );
      if (resolved != null) resolvedByName[name] = resolved.path;
    }
    if (resolvedByName.isEmpty) return frameMeta;
    return frameMeta.map((frameId, meta) {
      final resolvedPath = resolvedByName[meta.jpegPath.split('/').last];
      if (resolvedPath == null || resolvedPath == meta.jpegPath) {
        return MapEntry(frameId, meta);
      }
      return MapEntry(
        frameId,
        SfmFedFrameMeta(
          jpegPath: resolvedPath,
          imageW: meta.imageW,
          imageH: meta.imageH,
          grayW: meta.grayW,
          grayH: meta.grayH,
          fx: meta.fx,
          fy: meta.fy,
          cx: meta.cx,
          cy: meta.cy,
          captureTimestamp: meta.captureTimestamp,
          arkitQuatWxyz: meta.arkitQuatWxyz,
          arkitTransTxyz: meta.arkitTransTxyz,
          arkitCameraCenterWorld: meta.arkitCameraCenterWorld,
        ),
      );
    });
  } catch (e) {
    DeviceLog.log(
      'SfmResume',
      'archive materialization unavailable for $captureDir: $e',
    );
    return frameMeta;
  }
}

Future<Directory> _archiveRestoreCacheDirectory(String captureDir) async {
  final temporary = await getTemporaryDirectory();
  final captureName = Directory(captureDir).uri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .last;
  return Directory('${temporary.path}/pocketworld_photo_archive/$captureName');
}

Future<void> _clearMaterializedArchiveCache(String captureDir) async {
  try {
    final cache = await _archiveRestoreCacheDirectory(captureDir);
    if (await cache.exists()) await cache.delete(recursive: true);
  } catch (_) {
    // Temporary materializations are safe for the OS cache to reclaim later.
  }
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

// ════════════════════════════════════════════════════════════════════════
// 「从存档照片重建」—— db 已经死透时的恢复路。
//
// [2026-09-08 实机定罪] 上面那条 resume 腿的前提是"db 里有东西"。拍摄被杀
// (闪退 / jetsam / 用户划掉)时这个前提不成立:流式核写进 sqlite 的东西还压在
// 一个没提交的长事务里,进程一死全没。三方对照:
//     跑完 finalize 的  db=41 MB, wal=0,  有 .work.tmp, 有 PLY
//     被杀的            db=4096(1 页), wal=32 KB, 无 .work.tmp, 无 PLY
// 那个 4096 字节的 db 单独拿出来也是 malformed,`sqlite3 .recover` 抢不出任何表。
// ⇒「开始训练」(resume)和「补拍」(复用 db 继续喂)都必然 errDb。
//
// **但原料没丢**:照片和每张的 ARKit 位姿/内参都完整留在 photos_highres/。
// 所以这条腿把存档照片重新喂一遍,走与拍摄期**完全同一条** offerFrame 路径。
//
// 已在 Mac 台架验过(archived_refeed_bench.mm,真机 cap_1788845271610360 的
// 12 张存档照片):fed=12/12、n_reg=12/12、14151 点、产出 db 25.6MB/wal=0
// —— 正是"跑完 finalize 的健康 db"的形状。

/// 一次「从存档照片重建」的结果。**逐项可见**:少救一张都要说得出是哪张、
/// 为什么 —— 静默出口是本项目的头号复发缺陷。
class ArchivedRebuildResult {
  const ArchivedRebuildResult({
    required this.photosFound,
    required this.accepted,
    required this.fed,
    required this.rejections,
    required this.plyWritten,
    this.failure,
  });

  /// photos_highres 下找到的 .jpg 张数。
  final int photosFound;

  /// 解析 + validate 通过、可以喂的张数。
  final int accepted;

  /// 真正被 offerFrame 收下的张数(与 [accepted] 的差值 = 被会话拒收的)。
  final int fed;

  /// 每条 "<文件名>: <原因>";accepted 之外的每一张都必然在这里出现一次。
  final List<String> rejections;

  /// 最终有没有写出 official_sfm_sparse.ply —— 这才是"救回来了"的判据。
  final bool plyWritten;

  /// 整条路失败的原因(照片目录不存在 / 会话起不来 / 超时…);成功时为 null。
  final String? failure;

  bool get ok => plyWritten;
}

/// `<captureDir>` 下的存档照片有没有多到值得走这条路。
///
/// 只数**盘上的 jpg**,不看 record 里的快照张数 —— 补拍之后 record 的
/// photoCount 会滞后(09-08 已因此把 30 张记成 20 张)。
int archivedPhotoCount(String captureDir) {
  try {
    final dir = Directory('$captureDir/photos_highres');
    if (!dir.existsSync()) return 0;
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.jpg'))
        .length;
  } catch (_) {
    return 0;
  }
}

/// 读盘判定 `<captureDir>` 的 db 覆盖度(纯判据在 archived_photo_rebuild.dart)。
///
/// 只读一个 jsonl + 列一次目录 —— 这条会在长按菜单弹出前跑,不能有可感知耗时。
/// 读不出账本时返回**覆盖不齐**:没有账本就等于没有"这个 db 里有谁"的证据,
/// 而这一侧判错的代价只是多跑一次重喂,反过来判错是交付一朵缺了大半素材的云。
ProjectCoverage projectCoverage(String captureDir) {
  final names = <String>[];
  try {
    final dir = Directory('$captureDir/photos_highres');
    if (dir.existsSync()) {
      for (final f in dir.listSync().whereType<File>()) {
        final n = f.path.split('/').last;
        if (n.toLowerCase().endsWith('.jpg')) names.add(n);
      }
    }
  } catch (_) {
    // 列不出目录 ⇒ 下面按"账本覆盖不了盘上的照片"处理。
  }
  var jsonl = '';
  try {
    final f = File('$captureDir/official_sfm_fed_frames.jsonl');
    if (f.existsSync()) jsonl = f.readAsStringSync();
  } catch (_) {
    jsonl = '';
  }
  return projectCoverageFrom(jpegNamesOnDisk: names, fedFramesJsonl: jsonl);
}

/// 把当前的 db 及其随从**改名**挪开(**绝不删**),让新会话能在原路径重新建库。
///
/// 必须整组一起挪:留下一个 stale `-wal` 会被 sqlite 当成新库的日志回放,
/// 那是比"打不开"更坏的结果。`official_sfm_fed_frames.jsonl` 也要挪 ——
/// 它按 frameId 追加,旧会话的 frameId 会和新会话的撞号,而取色正是按
/// frameId → jpegPath 找照片的(cap47 色彩污染就是同一类错配)。
///
/// [2026-09-11] 两个调用方,前提不同但动作完全一样,所以共用这一处:
///  · 全量重喂前 —— 那个 db 已经不可用(或覆盖不全);
///  · **补拍开场前** —— 那个 db 可能好好的,但新会话的帧号从 0 重数、
///    名字 `frame_%06d.jpg` 会撞上 `images.name` 的 UNIQUE 约束。核自己的
///    注释(`official_aether_sfm_c.cc:9278`)写着这种撞名会
///    "bricks the whole live capture" —— 不是废一帧,是这一场之后**每一帧**
///    都废。2026-09-08 用户报的「补拍 20 帧全是红框」多半就是这个。
///
/// 返回挪走的文件名列表,便于把"动过什么"落进日志。
Future<List<String>> sidelineDatabaseForFreshSession(String captureDir) async {
  final stamp = DateTime.now().millisecondsSinceEpoch;
  final moved = <String>[];
  const names = <String>[
    'official_sfm_live.db',
    'official_sfm_live.db-wal',
    'official_sfm_live.db-shm',
    'official_sfm_live.db.arkit_pose_v1',
    'official_sfm_fed_frames.jsonl',
  ];
  for (final n in names) {
    final f = File('$captureDir/$n');
    if (!f.existsSync()) continue;
    try {
      await f.rename('$captureDir/$n.dead-$stamp');
      moved.add(n);
    } catch (e) {
      DeviceLog.log('SfmResume', 'sideline failed for $n: $e');
    }
  }
  return moved;
}

/// 「这个项目要重喂哪些照片、按什么顺序」—— 扫盘 + 解析 + 排序,一处实现。
///
/// [2026-09-11] 抽出来是因为有了**第二个**调用方:补拍结束时,采集页要用
/// **它自己的** SfmLiveRecon 把这些照片喂进去,好让整条收尾走**与正常拍摄
/// 完全同一条**流程(同一个浮层、同一串事件、同一个持久化),而不是弹回作品页
/// 再进一张单独的等待页。两边共用这一个解析器,判据只有一处。
class ArchivedRefeedPlan {
  const ArchivedRefeedPlan({
    required this.photosFound,
    required this.ordered,
    required this.rejections,
  });

  /// photos_highres 下的 .jpg 张数。
  final int photosFound;

  /// 解析通过、已按帧序号排好的照片。
  final List<ArchivedPhotoParse> ordered;

  /// 每条 "<文件名>: <原因>";photosFound 减去 ordered 的每一张都在这里。
  final List<String> rejections;
}

Future<ArchivedRefeedPlan> planArchivedRefeed(String captureDir) async {
  final rejections = <String>[];
  final photosDir = Directory('$captureDir/photos_highres');
  if (!photosDir.existsSync()) {
    return ArchivedRefeedPlan(
      photosFound: 0,
      ordered: const <ArchivedPhotoParse>[],
      rejections: rejections,
    );
  }
  final jpegs =
      photosDir
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((p) => p.toLowerCase().endsWith('.jpg'))
          .toList()
        ..sort();
  final parses = <ArchivedPhotoParse>[];
  for (final jpeg in jpegs) {
    final sidecar = File('${jpeg.substring(0, jpeg.length - 4)}.json');
    if (!sidecar.existsSync()) {
      rejections.add('${jpeg.split('/').last}: 缺 sidecar .json');
      continue;
    }
    String text;
    try {
      text = await sidecar.readAsString();
    } catch (e) {
      rejections.add('${jpeg.split('/').last}: sidecar 读不出 ($e)');
      continue;
    }
    final p = parseArchivedPhoto(jpegPath: jpeg, sidecarJson: text);
    if (p.isAccepted) {
      parses.add(p);
    } else {
      rejections.add('${jpeg.split('/').last}: ${p.failure}');
    }
  }
  return ArchivedRefeedPlan(
    photosFound: jpegs.length,
    ordered: orderForRefeed(parses),
    rejections: rejections,
  );
}

/// 从 `<captureDir>/photos_highres` 的存档照片**重新喂帧**并重建点云。
///
/// 与 [resumeSingleCapture] 互斥:两者共用 `_resumeInFlight`,同一个 capture
/// 上永远只有一条重建在飞。
Future<ArchivedRebuildResult> rebuildFromArchivedPhotos(
  String captureDir, {
  Duration timeout = const Duration(minutes: 25),
}) {
  final existing = _rebuildInFlight[captureDir];
  if (existing != null) return existing;
  final completer = Completer<ArchivedRebuildResult>();
  _rebuildInFlight[captureDir] = completer.future;
  // 让草稿页/作品页的"重建中"判定同样盖住这条腿(它们查的是 _resumeInFlight)。
  _resumeInFlight[captureDir] = completer.future.then((r) => r.ok);
  () async {
    ArchivedRebuildResult result;
    try {
      result = await _rebuildFromArchivedPhotosOnce(captureDir, timeout);
    } catch (e, st) {
      DeviceLog.log('SfmResume', 'rebuild error $captureDir: $e\n$st');
      result = ArchivedRebuildResult(
        photosFound: 0,
        accepted: 0,
        fed: 0,
        rejections: const <String>[],
        plyWritten: File('$captureDir/official_sfm_sparse.ply').existsSync(),
        failure: '$e',
      );
    } finally {
      _rebuildInFlight.remove(captureDir);
      _resumeInFlight.remove(captureDir);
    }
    completer.complete(result);
  }();
  return completer.future;
}

Future<ArchivedRebuildResult> _rebuildFromArchivedPhotosOnce(
  String captureDir,
  Duration timeout,
) async {
  final plan = await planArchivedRefeed(captureDir);
  final rejections = List<String>.of(plan.rejections);
  final ordered = plan.ordered;
  DeviceLog.log(
    'SfmResume',
    'rebuild $captureDir: jpg=${plan.photosFound} accepted=${ordered.length} '
        'rejected=${rejections.length}',
  );
  if (ordered.isEmpty) {
    return ArchivedRebuildResult(
      photosFound: plan.photosFound,
      accepted: 0,
      fed: 0,
      rejections: rejections,
      plyWritten: false,
      failure: plan.photosFound == 0
          ? '照片目录为空或不存在:$captureDir/photos_highres'
          : '没有一张存档照片可用',
    );
  }

  SfmLiveRecon? recon;
  PhotoArchiveActivityLease? archiveLease;
  StreamSubscription<SfmLiveEvent>? sub;
  final done = Completer<void>();
  var fed = 0;
  String? failure;
  try {
    archiveLease = photoArchiveCoordinator.beginReconstructionActivity(
      Directory(captureDir),
    );
    await _umbrella('beginReconUmbrella', captureDir);

    final moved = await sidelineDatabaseForFreshSession(captureDir);
    DeviceLog.log('SfmResume', 'rebuild sidelined: ${moved.join(",")}');

    // 新会话在**原路径**重建库 —— 下游(resume sweep / 补拍 / 归档策略)全都
    // 按这个固定名字找 db,换个名字等于把这次重建的成果藏起来。
    recon = await SfmLiveRecon.start(
      dbPath: '$captureDir/official_sfm_live.db',
    );
    if (recon == null) {
      return ArchivedRebuildResult(
        photosFound: plan.photosFound,
        accepted: ordered.length,
        fed: 0,
        rejections: rejections,
        plyWritten: false,
        failure: '重建会话起不来(可能已有另一条重建在跑)',
      );
    }

    sub = recon.events.listen((e) {
      switch (e) {
        case SfmLiveLocalReady(:final snapshot):
          DeviceLog.log(
            'SfmResume',
            'rebuild local ignored: ${snapshot.pointCount} pts',
          );
        case SfmLiveRefined(:final snapshot):
          // 与另外两条腿同构:persist(取色 + 孤点过滤 + PLY 落盘)跑完才算完,
          // refined 一到就 complete 会让调用方在 PLY 没写完时误判失败。
          unawaited(() async {
            try {
              // 🔴 这里**不**跟着 detached 腿调 _prunePhotosAfterSparse:
              // 那条腿删的是刚拍完、db 健全时的冗余照片;而走到这条腿的项目,
              // 存档照片是它**仅剩**的恢复材料(db 已经死了)。删掉就再也没有
              // 第二次机会。两条腿看着对称,但前提相反。
              await _persistColored(captureDir, snapshot);
            } catch (e) {
              DeviceLog.log('SfmResume', 'rebuild persist failed: $e');
            } finally {
              if (!done.isCompleted) done.complete();
            }
          }());
        case SfmLiveFailed(:final stage, :final message):
          failure = '$stage $message';
          DeviceLog.log(
            'SfmResume',
            'rebuild $captureDir failed: $stage $message',
          );
          if (!done.isCompleted) done.complete();
        default:
          break;
      }
    });

    for (final p in ordered) {
      final input = p.input!;
      if (recon.offerFrame(input)) {
        fed++;
      } else {
        // 会话拒收(尺寸不符 / 文件不在 / 已请求 finalize)——必须留痕。
        rejections.add('${p.jpegPath.split('/').last}: 会话拒收(offerFrame)');
      }
    }
    DeviceLog.log('SfmResume', 'rebuild fed=$fed/${ordered.length}');
    if (fed == 0) {
      return ArchivedRebuildResult(
        photosFound: plan.photosFound,
        accepted: ordered.length,
        fed: 0,
        rejections: rejections,
        plyWritten: false,
        failure: '一张都没喂进去',
      );
    }

    recon.finalize();
    await done.future.timeout(
      timeout,
      onTimeout: () {
        failure = '超时(${timeout.inMinutes} 分钟)';
        DeviceLog.log('SfmResume', 'rebuild $captureDir timed out');
      },
    );
  } finally {
    await sub?.cancel();
    if (recon != null) await recon.dispose();
    await _umbrella('endReconUmbrella', captureDir);
    await archiveLease?.close();
    await _clearMaterializedArchiveCache(captureDir);
  }

  final ply = File('$captureDir/official_sfm_sparse.ply').existsSync();
  DeviceLog.log('SfmResume', 'rebuild $captureDir → ply=$ply fed=$fed');
  return ArchivedRebuildResult(
    photosFound: plan.photosFound,
    accepted: ordered.length,
    fed: fed,
    rejections: rejections,
    plyWritten: ply,
    failure: ply ? null : (failure ?? '重建没有产出点云'),
  );
}
