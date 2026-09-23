// native_dense_stage_launcher.dart — the real DenseStageLauncher: gathers what the capture already has on disk
// (refined poses, sidecar intrinsics, fed-frame photo names, sparse PLY), materialises archived photos, and runs
// the on-device dense job (PWDense.framework: CasDiffMVS on ORT-WebGPU + the official fusion) on a worker isolate.
//
// Constraints inherited from dense_stage.dart: pure local; delivery is the full cloud of what was selected, never
// downsampled. A selection box is passed to C unchanged: frames that see no sparse point inside it are skipped and
// only fused points inside it are delivered ("未被选中的部分就不用进入稠密点云").
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;

import '../official_capture/dense_stage.dart';
import '../official_capture/photo_archive_resolver.dart';
import '../official_capture/photo_archive_runtime.dart' show photoArchiveCodec, photoArchiveCodecsByName;
import '../official_capture/sfm_resume.dart' show loadFedFrameMeta;
import '../official_util/device_log.dart' as official_device_log;
import '../ui/official_capture/sparse_cloud_viewer_page.dart' show loadSparsePly;
import 'dense_live_cloud.dart';
import 'dense_stage_progress.dart';
import 'pw_dense_ffi.dart';

const String kDensePlyFileName = 'official_dense.ply';
const String kDenseWorkDirName = 'dense_work';

/// How many archived frames are materialised at once in [_gather]. Each one owns its own PwvaReader and, on
/// Apple, its own VideoToolbox session inside its own worker isolate, so they are independent; 3 keeps the
/// decoders busy without piling up full-resolution NV12 buffers.
const int kDenseGatherConcurrency = 3;

/// Where one frame's pixels come from.
/// * [plain] — the original JPEG is still on disk (fresh capture): unchanged v1 behaviour.
/// * [nv12] — PWVA master frame decoded straight to a raw NV12 file for `pwdense_run3` (no JPEG round trip).
/// * [jpegMaterialised] — the old path: Lepton archive, or a PWVA frame on a framework without `pwdense_run3`.
enum DenseFrameSource { plain, nv12, jpegMaterialised }

typedef DenseNv12Resolver =
    Future<({File file, int width, int height})?> Function(String highresFilename);
typedef DenseJpegResolver = Future<File?> Function(String highresFilename);

/// The one branch in [NativeDenseStageLauncher._gather] that decides where a frame's pixels come from, pulled
/// out as a pure function (both IO paths injected) so test/dense can pin every case without a capture on disk.
/// Returns null when the frame cannot be restored at all — the caller turns that into a StateError.
Future<({DenseFrameSource source, String path, int width, int height})?> resolveDenseFrameSource({
  required String highresFilename,
  required String plainJpegPath,
  required bool plainExists,
  required bool hasRun3,
  required DenseNv12Resolver resolveNv12,
  required DenseJpegResolver resolveJpeg,
}) async {
  if (plainExists) {
    return (source: DenseFrameSource.plain, path: plainJpegPath, width: 0, height: 0);
  }
  // NV12 only helps when the framework can consume it; without run3 the raw file has nowhere to go.
  if (hasRun3) {
    final n = await resolveNv12(highresFilename);
    if (n != null) {
      return (source: DenseFrameSource.nv12, path: n.file.path, width: n.width, height: n.height);
    }
  }
  final j = await resolveJpeg(highresFilename);
  if (j == null) return null;
  return (source: DenseFrameSource.jpegMaterialised, path: j.path, width: 0, height: 0);
}

/// Bounded-concurrency map that keeps the input order: [limit] workers pull from one shared cursor and write
/// their result back into the slot they took.
Future<List<T>> mapBoundedConcurrent<S, T>(
  List<S> items,
  int limit,
  Future<T> Function(S item) body,
) async {
  if (items.isEmpty) return <T>[];
  final out = List<T?>.filled(items.length, null);
  var cursor = 0;
  Future<void> worker() async {
    while (true) {
      final i = cursor++;
      if (i >= items.length) return;
      out[i] = await body(items[i]);
    }
  }

  final workers = limit < items.length ? limit : items.length;
  await Future.wait(List<Future<void>>.generate(workers < 1 ? 1 : workers, (_) => worker()));
  return List<T>.from(out);
}

class NativeDenseStageLauncher implements DenseStageLauncher {
  NativeDenseStageLauncher() : _ffi = PwDenseFfi.tryResolve();

  final PwDenseFfi? _ffi;
  bool _running = false;

  @override
  bool get isAvailable => _ffi != null;

  @override
  Future<DenseStageResult> start(DenseStageRequest request) async {
    if (_ffi == null) {
      return DenseStageResult(DenseStageStatus.unavailable, message: PwDenseFfi.lastError);
    }
    if (_running) {
      return const DenseStageResult(DenseStageStatus.failed, message: '稠密处理已在进行中,请等它完成');
    }
    final _Inputs inputs;
    try {
      inputs = await _gather(request);
    } catch (e) {
      official_device_log.DeviceLog.log('DenseStage', 'gather failed: $e');
      return DenseStageResult(DenseStageStatus.failed, message: '稠密输入不完整: $e');
    }
    _running = true;
    // The display copy of the progressive chunks. Its stride comes from the number of reference frames the job
    // is about to run, which is exactly what _gather just assembled.
    final live = DenseLiveCloud(framesPlanned: inputs.frames.length);
    denseStageProgress.value = DenseStageProgress(
        captureDir: request.captureDir, state: DenseStageState.running, phase: 'session', startedAt: DateTime.now(), live: live);
    unawaited(_runJob(request, inputs, live));
    final note = request.selection != null ? '(只处理选区内)' : '(整朵云)';
    return DenseStageResult(DenseStageStatus.started, message: '稠密处理已开始$note');
  }

  Future<void> _runJob(DenseStageRequest request, _Inputs inputs, DenseLiveCloud live) async {
    final dir = request.captureDir;
    final outPly = '$dir/$kDensePlyFileName';
    final workDir = '$dir/$kDenseWorkDirName';
    final t0 = DateTime.now();
    final sel = request.selection;
    final box = sel == null
        ? null
        : PwDenseBox(cx: sel.cx, cy: sel.cy, cz: sel.cz, sx: sel.sx, sy: sel.sy, sz: sel.sz, rot: List<double>.from(sel.rot, growable: false));
    official_device_log.DeviceLog.log(
      'DenseStage',
      'start capture=$dir frames=${inputs.frames.length} points=${inputs.pointsXyz.length ~/ 3} '
      'abi=${_ffi?.abiVersion()} chunks=${_ffi?.hasChunkApi == true} run3=${_ffi?.hasRun3 == true} '
      'box=${box == null ? 'none' : '${box.cx.toStringAsFixed(3)},${box.cy.toStringAsFixed(3)},${box.cz.toStringAsFixed(3)} ${box.sx.toStringAsFixed(3)}x${box.sy.toStringAsFixed(3)}x${box.sz.toStringAsFixed(3)}'}',
    );
    try {
      final r = await runPwDenseJob(
        frames: inputs.frames,
        pointsXyz: inputs.pointsXyz,
        workDir: workDir,
        outPly: outPly,
        box: box,
        onProgress: (p) {
          final cur = denseStageProgress.value;
          if (cur == null || cur.captureDir != dir) return;
          denseStageProgress.value = cur.copyWith(phase: p.phase, done: p.done, total: p.total);
        },
        // v2 only: one fused reference frame. Nothing arrives on a v1 framework (pwdense_run, no chunks).
        onChunk: (c) {
          live.addChunk(frameIndex: c.frameIndex, xyz: c.xyz, rgb: c.rgb);
          if (live.frames % 10 == 1) {
            official_device_log.DeviceLog.log(
                'DenseStage', 'live chunk f=${c.frameIndex} n=${c.pointCount} total=${live.points}');
          }
          final cur = denseStageProgress.value;
          if (cur == null || cur.captureDir != dir) return;
          // same instance, new DenseStageProgress: the ValueNotifier only notifies on a new object
          denseStageProgress.value = cur.copyWith(live: live);
        },
      );
      final secs = DateTime.now().difference(t0).inMilliseconds / 1000.0;
      final s = r.stats;
      official_device_log.DeviceLog.log(
        'DenseStage',
        'end rc=${r.code} ${secs.toStringAsFixed(1)}s frames=${s.frames} selected=${s.framesSelected}${s.boxFallback ? '(fallback:all)' : ''} inferred=${s.inferred} images=${s.images} '
        'session=${s.sessionMs.toStringAsFixed(0)}ms images=${s.imagesMs.toStringAsFixed(0)}ms ort=${s.ortSessionMs.toStringAsFixed(0)}ms '
        'infer_med=${s.inferMsMedian.toStringAsFixed(1)}ms infer_total=${(s.inferMsTotal / 1000).toStringAsFixed(1)}s '
        'fuse=${s.fuseMs.toStringAsFixed(0)}ms points=${s.points} final=${(s.finalFrac * 100).toStringAsFixed(2)}% err="${s.error}"',
      );
      if (r.ok) {
        denseStageProgress.value = DenseStageProgress(
          captureDir: dir,
          state: DenseStageState.done,
          phase: 'done',
          outPly: outPly,
          points: s.points,
          startedAt: t0,
          finishedAt: DateTime.now(),
        );
      } else {
        denseStageProgress.value = DenseStageProgress(
          captureDir: dir,
          state: DenseStageState.failed,
          phase: 'failed',
          message: DenseStageProgress.shorten('rc=${r.code} ${s.error}'),
          startedAt: t0,
          finishedAt: DateTime.now(),
        );
      }
    } catch (e, st) {
      official_device_log.DeviceLog.log('DenseStage', 'exception: $e\n$st');
      denseStageProgress.value = DenseStageProgress(
        captureDir: dir,
        state: DenseStageState.failed,
        phase: 'failed',
        message: DenseStageProgress.shorten(e),
        startedAt: t0,
        finishedAt: DateTime.now(),
      );
    } finally {
      _running = false;
      // the depth pack is scratch (NF x ~7 MB); the PLY is the deliverable. Materialised photos likewise.
      try {
        final w = Directory(workDir);
        if (w.existsSync()) await w.delete(recursive: true);
      } catch (_) {}
      try {
        final captureName = Directory(dir).uri.pathSegments.where((x) => x.isNotEmpty).last;
        final c = Directory('${(await getTemporaryDirectory()).path}/pocketworld_dense_cache/$captureName');
        if (c.existsSync()) await c.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Assembles the pwdense inputs from the capture directory. No arithmetic here: every value is copied from
  /// the files the fixture builder (prep_phone_fixture.py) read on the host.
  Future<_Inputs> _gather(DenseStageRequest request) async {
    final tGather = DateTime.now();
    final dir = request.captureDir;
    final metaFile = File('$dir/official_sfm_sparse_meta.json');
    if (!metaFile.existsSync()) throw StateError('缺 official_sfm_sparse_meta.json');
    final meta = jsonDecode(await metaFile.readAsString()) as Map<String, Object?>;
    final posesRaw = (meta['poses'] as List?) ?? const [];
    final fed = await loadFedFrameMeta(dir);
    final resolver = PhotoArchiveResolver(codec: photoArchiveCodec, codecsByName: photoArchiveCodecsByName);
    // materialised archive photos go to the temp dir (like the resume path), never into the capture dir
    final captureName = Directory(dir).uri.pathSegments.where((x) => x.isNotEmpty).last;
    final cacheDir = Directory('${(await getTemporaryDirectory()).path}/pocketworld_dense_cache/$captureName');
    // Pass 1 (cheap, sequential, deterministic): poses + sidecar intrinsics, i.e. everything but the pixels.
    final pending = <_PendingFrame>[];
    for (final p in posesRaw) {
      final m = p as Map<String, Object?>;
      if (m['registered'] != true) continue;
      final fid = (m['frame_id'] as num).toInt();
      final q = (m['quat_wxyz'] as List).map((e) => (e as num).toDouble()).toList(growable: false);
      final t = (m['t'] as List).map((e) => (e as num).toDouble()).toList(growable: false);
      final fm = fed[fid];
      if (fm == null) throw StateError('frame $fid 没有喂入照片记录');
      final base = fm.jpegPath.split('/').last; // <name>.jpg under photos_highres
      final sidecar = File('$dir/photos_highres/${base.replaceFirst(RegExp(r'\.jpg$'), '.json')}');
      if (!sidecar.existsSync()) throw StateError('frame $fid 缺 sidecar ${sidecar.path.split('/').last}');
      final sc = jsonDecode(await sidecar.readAsString()) as Map<String, Object?>;
      final k = (sc['intrinsics_fxfycxcy'] as List).map((e) => (e as num).toDouble()).toList(growable: false);
      final iw = (sc['image_w'] as num).toDouble(), ih = (sc['image_h'] as num).toDouble();
      pending.add(_PendingFrame(frameId: fid, base: base, plainJpegPath: fm.jpegPath, q: q, t: t, k: k, imageW: iw, imageH: ih));
    }
    if (pending.isEmpty) throw StateError('没有已注册的位姿');

    // Pass 2: the pixels. Materialisation is per-frame independent (own PwvaReader / decoder session in its own
    // isolate), so it runs kDenseGatherConcurrency at a time; the pool preserves the frame order.
    final hasRun3 = _ffi?.hasRun3 == true;
    final decided = await mapBoundedConcurrent(pending, kDenseGatherConcurrency, (pf) async {
      return resolveDenseFrameSource(
        highresFilename: pf.base,
        plainJpegPath: pf.plainJpegPath,
        plainExists: File(pf.plainJpegPath).existsSync(),
        hasRun3: hasRun3,
        resolveNv12: (name) => resolver.resolveNv12(
            captureDirectory: Directory(dir), highresFilename: name, cacheDirectory: cacheDir),
        resolveJpeg: (name) => resolver.resolveJpeg(
            captureDirectory: Directory(dir), highresFilename: name, cacheDirectory: cacheDir),
      );
    });

    final frames = <PwDenseFrame>[];
    var plainCount = 0, nv12Count = 0, jpegCount = 0;
    for (var i = 0; i < pending.length; i++) {
      final pf = pending[i];
      final d = decided[i];
      if (d == null) throw StateError('frame ${pf.frameId} 的照片 ${pf.base} 无法还原');
      switch (d.source) {
        case DenseFrameSource.plain:
          plainCount++;
        case DenseFrameSource.nv12:
          nv12Count++;
        case DenseFrameSource.jpegMaterialised:
          jpegCount++;
      }
      final isNv12 = d.source == DenseFrameSource.nv12;
      frames.add(PwDenseFrame(
        frameId: pf.frameId,
        fx: pf.k[0],
        fy: pf.k[1],
        cx: pf.k[2],
        cy: pf.k[3],
        imageW: pf.imageW,
        imageH: pf.imageH,
        qWxyz: pf.q,
        t: pf.t,
        jpegPath: isNv12 ? '' : d.path,
        nv12Path: isNv12 ? d.path : null,
        nv12Width: isNv12 ? d.width : null,
        nv12Height: isNv12 ? d.height : null,
      ));
    }
    final cloud = loadSparsePly(request.sparsePlyPath);
    if (cloud == null || cloud.count == 0) throw StateError('稀疏点云读不出来');
    official_device_log.DeviceLog.log(
      'DenseStage',
      'gather ${DateTime.now().difference(tGather).inMilliseconds}ms frames=${frames.length} '
      'plain=$plainCount nv12=$nv12Count jpeg_materialised=$jpegCount',
    );
    return _Inputs(frames, cloud.xyz);
  }
}

/// One registered pose with its sidecar intrinsics, before the pixels have been materialised.
final class _PendingFrame {
  const _PendingFrame({
    required this.frameId,
    required this.base,
    required this.plainJpegPath,
    required this.q,
    required this.t,
    required this.k,
    required this.imageW,
    required this.imageH,
  });
  final int frameId;
  final String base; // <name>.jpg under photos_highres
  final String plainJpegPath;
  final List<double> q, t, k;
  final double imageW, imageH;
}

final class _Inputs {
  const _Inputs(this.frames, this.pointsXyz);
  final List<PwDenseFrame> frames;
  final List<double> pointsXyz;
}
