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
import 'dense_stage_progress.dart';
import 'pw_dense_ffi.dart';

const String kDensePlyFileName = 'official_dense.ply';
const String kDenseWorkDirName = 'dense_work';

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
    denseStageProgress.value = DenseStageProgress(captureDir: request.captureDir, state: DenseStageState.running, phase: 'session', startedAt: DateTime.now());
    unawaited(_runJob(request, inputs));
    final note = request.selection != null ? '(只处理选区内)' : '(整朵云)';
    return DenseStageResult(DenseStageStatus.started, message: '稠密处理已开始$note');
  }

  Future<void> _runJob(DenseStageRequest request, _Inputs inputs) async {
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
    final frames = <PwDenseFrame>[];
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
      // photo: the plain JPEG if still present, else materialised from the Lepton / PWVA archive
      String jpegPath = fm.jpegPath;
      if (!File(jpegPath).existsSync()) {
        final f = await resolver.resolveJpeg(captureDirectory: Directory(dir), highresFilename: base, cacheDirectory: cacheDir);
        if (f == null) throw StateError('frame $fid 的照片 $base 无法还原');
        jpegPath = f.path;
      }
      frames.add(PwDenseFrame(frameId: fid, fx: k[0], fy: k[1], cx: k[2], cy: k[3], imageW: iw, imageH: ih, qWxyz: q, t: t, jpegPath: jpegPath));
    }
    if (frames.isEmpty) throw StateError('没有已注册的位姿');
    final cloud = loadSparsePly(request.sparsePlyPath);
    if (cloud == null || cloud.count == 0) throw StateError('稀疏点云读不出来');
    return _Inputs(frames, cloud.xyz);
  }
}

final class _Inputs {
  const _Inputs(this.frames, this.pointsXyz);
  final List<PwDenseFrame> frames;
  final List<double> pointsXyz;
}
