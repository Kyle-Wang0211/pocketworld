/// SfmDbRegen — B1 全配方化的再生驱动
///
/// 从照片主本(PWVA 码流,经 [PhotoArchiveResolver] 物化)+ 逐帧 sidecar
/// (photos_highres/`<name>`.json:t/extrinsic/intrinsics_fxfycxcy)重放生产
/// 流式 SfM,重造 official_sfm_live.db。走的就是拍摄期同一条路:
/// [SfmLiveRecon.start] → [SfmLiveRecon.offerFrame] × N → finalize →
/// REFINED(含 finish-time db enrichment)。产物是语义等价的 COLMAP DB
/// (位级不可能:P2 后源 JPEG 像素已被 HEVC 主本替代,见 B1 签决文档)。
///
/// 本驱动绝不触碰 capture 目录内的既有产物:输出 db 写在 [targetDbPath]
/// (调用方决定落点);official_sfm_sparse.ply 不会被覆盖(persist 链只在
/// UI resume 流程里由调用方显式触发)。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'official_highres_reconstruction_input.dart';
import 'photo_archive_ffi_codec.dart';
import 'photo_archive_manifest.dart';
import 'photo_archive_resolver.dart';
import 'lepton_photo_archive_ffi_codec.dart';
import 'sfm_live_recon.dart';

class SfmDbRegenReport {
  const SfmDbRegenReport({
    required this.ok,
    required this.stage,
    this.framesFed = 0,
    this.framesTotal = 0,
    this.summary,
    this.error,
    this.elapsedMs = 0,
  });

  final bool ok;
  final String stage;
  final int framesFed;
  final int framesTotal;
  final Map<String, Object?>? summary;
  final String? error;
  final int elapsedMs;

  Map<String, Object?> toJson() => {
        'ok': ok,
        'stage': stage,
        'frames_fed': framesFed,
        'frames_total': framesTotal,
        if (summary != null) 'summary': summary,
        if (error != null) 'error': error,
        'elapsed_ms': elapsedMs,
      };
}

class SfmDbRegen {
  /// 与拍摄期一致的 refined 等待上限(finalize 双段 BA + enrichment)。
  static const Duration _refinedTimeout = Duration(minutes: 20);

  /// 重放一个 capture,把再生 db 写到 [targetDbPath]。
  /// [materializeCache] 存放 PWVA/Lepton 物化出的 JPEG,调用方负责清理。
  static Future<SfmDbRegenReport> regenerate({
    required Directory captureDirectory,
    required String targetDbPath,
    required Directory materializeCache,
  }) async {
    final started = DateTime.now();
    SfmDbRegenReport fail(String stage, String error, [int fed = 0, int total = 0]) =>
        SfmDbRegenReport(
          ok: false,
          stage: stage,
          error: error,
          framesFed: fed,
          framesTotal: total,
          elapsedMs: DateTime.now().difference(started).inMilliseconds,
        );

    final candidates =
        await PhotoArchiveManifest.loadCandidateNames(captureDirectory);
    if (candidates.isEmpty) return fail('candidates', 'empty candidate list');

    // 逐帧组装喂入包:sidecar 元数据 + 物化 JPEG。全部就绪才开跑
    // (中途缺帧=白烧一半算力,先验证再开火)。
    final resolver = PhotoArchiveResolver(
      codec: LeptonFfiPhotoArchiveCodec(),
      codecsByName: {
        'lepton': LeptonFfiPhotoArchiveCodec(),
        'jpeg-xl': JxlFfiPhotoArchiveCodec(),
      },
    );
    final feeds = <({String jpegPath, Map<String, dynamic> sidecar})>[];
    for (final name in candidates) {
      final sidecarFile = File(
          '${captureDirectory.path}/photos_highres/${name.replaceAll(RegExp(r'\.jpe?g$'), '.json')}');
      if (!await sidecarFile.exists()) {
        return fail('sidecar', 'missing sidecar for $name');
      }
      Map<String, dynamic> sidecar;
      try {
        sidecar = jsonDecode(await sidecarFile.readAsString())
            as Map<String, dynamic>;
      } catch (e) {
        return fail('sidecar', 'bad sidecar for $name: $e');
      }
      final jpeg = await resolver.resolveJpeg(
        captureDirectory: captureDirectory,
        highresFilename: name,
        cacheDirectory: materializeCache,
      );
      if (jpeg == null) return fail('materialize', 'cannot resolve $name');
      feeds.add((jpegPath: jpeg.path, sidecar: sidecar));
    }

    // 输出 db 落在临时名,成功才 rename 到位(不留半成品)。
    final tmpDb = File('$targetDbPath.regen.tmp');
    if (await tmpDb.exists()) await tmpDb.delete();
    final recon = await SfmLiveRecon.start(dbPath: tmpDb.path);
    if (recon == null) {
      return fail('session', 'SfmLiveRecon.start failed (lease busy?)');
    }

    var fed = 0;
    try {
      final refined = Completer<Map<String, Object?>?>();
      final sub = recon.events.listen((event) {
        if (event is SfmLiveRefined && !refined.isCompleted) {
          refined.complete(<String, Object?>{
            'n_points': event.snapshot.xyz.length ~/ 3,
            'n_registered': event.snapshot.registeredCount,
            'summary': event.snapshot.summary,
            'refine_ms': event.refineMs,
          });
        } else if (event is SfmLiveFailed && !refined.isCompleted) {
          refined.complete(null);
        }
      });
      try {
        for (final f in feeds) {
          final sc = f.sidecar;
          final validation = OfficialHighResReconstructionInput.validate(
            jpegPath: f.jpegPath,
            imageWidth: (sc['image_w'] as num).toInt(),
            imageHeight: (sc['image_h'] as num).toInt(),
            triggerTimestamp: (sc['t'] as num).toDouble(),
            captureTimestamp: (sc['t'] as num).toDouble(),
            cameraTransform:
                (sc['extrinsic'] as List).cast<num>().map((v) => v.toDouble()).toList(),
            intrinsics: (sc['intrinsics_fxfycxcy'] as List)
                .cast<num>()
                .map((v) => v.toDouble())
                .toList(),
          );
          final input = validation.input;
          if (input == null) {
            return fail('validate',
                'input rejected: ${validation.failure}', fed, feeds.length);
          }
          if (!recon.offerFrame(input)) {
            return fail('feed', 'offerFrame rejected', fed, feeds.length);
          }
          fed++;
        }
        recon.finalize();
        final summary = await refined.future.timeout(_refinedTimeout,
            onTimeout: () => null);
        if (summary == null) {
          return fail('finalize', 'refined not reached', fed, feeds.length);
        }
        await recon.dispose();
        if (!await tmpDb.exists() || await tmpDb.length() == 0) {
          return fail('db', 'regen db missing/empty', fed, feeds.length);
        }
        final target = File(targetDbPath);
        if (await target.exists()) await target.delete();
        await tmpDb.rename(target.path);
        return SfmDbRegenReport(
          ok: true,
          stage: 'done',
          framesFed: fed,
          framesTotal: feeds.length,
          summary: summary,
          elapsedMs: DateTime.now().difference(started).inMilliseconds,
        );
      } finally {
        await sub.cancel();
      }
    } catch (e) {
      return fail('exception', '$e', fed, feeds.length);
    } finally {
      // dispose 幂等;异常路径也必须释放 lease 与 isolate。
      try {
        await recon.dispose();
      } catch (_) {}
      try {
        if (await tmpDb.exists()) await tmpDb.delete();
      } catch (_) {}
    }
  }
}
