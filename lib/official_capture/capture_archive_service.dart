/// CaptureArchiveService — PWVA 归档(生产集成 P1.1:收尾批量转码)
///
/// [2026-08-10 竞态根治] P1.0 的"帧落地即转"在真机上撞竞态:落地时刻
/// 路径上是占位/临时内容,最终 12MP JPEG 稍后才写入同一路径——早期归档
/// 的内容全部是模糊占位版(首帧拉普拉斯方差 ~19,真实照片 ~20000)。
/// 根治:改为 **photo bundle 写完后批量转码**——那一刻所有 JPEG 已是
/// 最终版、策展清单已定,竞态从构造上消灭;顺带只归档策展帧(不再超集),
/// 且拍摄期彻底零工作(效率问题构造性归零;流式版效率门 PASS 记录仍归档
/// 于 experiments/hevc_capture_ladder/results/)。
///
/// 自检(fail closed):归档完成后解码首帧计算拉普拉斯方差,低于阈值
/// (模糊占位指纹)则判归档失败并写 archive-error.json,绝不产出静默的
/// 垃圾归档。每帧索引记录源 JPEG 的 SHA-256,可与 photo archive
/// manifest 对账。
///
/// 失败隔离不变:任何错误只影响归档产物,绝不影响采集与管线。
/// 双写不变:JPEG/Lepton 主本不动,归档是并行副产品。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:pw_hevc/pwva.dart';
import 'package:pw_hevc/pwva_apple.dart';

class CaptureArchiveService {
  CaptureArchiveService._();
  static final CaptureArchiveService instance = CaptureArchiveService._();

  /// 功能开关,默认开。置 false 后完全无行为。
  static bool enabled = true;

  static const int _gop = 8;
  static const double _quality = 0.65;

  /// 首帧锐度自检阈值:真实照片 ~2 万,模糊占位 ~20。
  static const double _minLaplacianVariance = 500;

  /// P1.1 起帧落地不再触发编码(竞态根治);保留为无操作挂点,
  /// P2(相机像素直编)将重新启用。
  void enqueueHighresStill(String jpegPath, {double? triggerTimestamp}) {}

  /// 批量模式无进行中状态。
  void abandon() {}

  /// 兼容旧挂点签名:bundle 写完后由 capture_session 调用。
  /// 从最近一次 enqueue 无法推根目录(no-op),改由 archiveCapture(root)
  /// 显式驱动;此方法保留为无参兼容层,直接返回 null。
  Future<Map<String, Object?>?> finalizeArchive() async => null;

  /// 批量归档入口:photo bundle 已写完后,传采集根目录。
  Future<Map<String, Object?>?> archiveCapture(String captureRoot) async {
    if (!enabled || !(Platform.isIOS || Platform.isMacOS)) return null;
    try {
      final ready = ReceivePort();
      await Isolate.spawn(_batchArchiveIsolate, ready.sendPort);
      final port = await ready.first as SendPort;
      final reply = ReceivePort();
      port.send({'root': captureRoot, 'reply': reply.sendPort});
      final report = await reply.first
          .timeout(const Duration(minutes: 5)) as Map<String, Object?>?;
      return report;
    } catch (_) {
      return null;
    }
  }
}

// ---------------- isolate 侧 ----------------

Future<void> _batchArchiveIsolate(SendPort ready) async {
  final inbox = ReceivePort();
  ready.send(inbox.sendPort);
  final m = await inbox.first as Map;
  final root = m['root'] as String;
  final reply = m['reply'] as SendPort;
  final outDir = Directory('$root/photos_hevc');
  final started = DateTime.now();
  Map<String, Object?> report;
  try {
    report = await _archive(root, outDir);
  } catch (e, st) {
    report = {'status': 'failed', 'error': '$e'};
    try {
      outDir.createSync(recursive: true);
      File('${outDir.path}/archive-error.json').writeAsStringSync(jsonEncode({
        'schema': 'pw_capture_archive_error_v1',
        'error': '$e',
        'stack': '$st',
      }));
    } catch (_) {}
  }
  report['elapsed_s'] = DateTime.now().difference(started).inSeconds;
  try {
    File('${outDir.path}/archive-report.json')
        .writeAsStringSync(jsonEncode(report));
  } catch (_) {}
  reply.send(report);
  inbox.close();
}

Future<Map<String, Object?>> _archive(String root, Directory outDir) async {
  final bundleFile = File('$root/official_photo_bundle.json');
  final bundle =
      jsonDecode(await bundleFile.readAsString()) as Map<String, dynamic>;
  final frames = (bundle['frames'] as List).cast<Map<String, dynamic>>();
  if (frames.isEmpty) return {'status': 'empty', 'frames': 0};

  // 竞态期的旧残留归档一律清除重建。
  if (outDir.existsSync()) outDir.deleteSync(recursive: true);
  outDir.createSync(recursive: true);

  final first = '$root/photos_highres/${frames.first['highresFilename']}';
  final size = probeJpegSize(first);
  final encoder = AppleHevcEncoder(
      width: size.width,
      height: size.height,
      gop: CaptureArchiveService._gop,
      quality: CaptureArchiveService._quality);
  final writer = PwvaWriter(encoder, outDir,
      width: size.width, height: size.height, gop: CaptureArchiveService._gop);
  var done = 0;
  for (final f in frames) {
    final name = f['highresFilename'] as String;
    final path = '$root/photos_highres/$name';
    final sha = sha256.convert(await File(path).readAsBytes()).toString();
    final encoded =
        encoder.encodeJpegFile(path, ptsMs: done * 300, durationMs: 300);
    writer.addEncodedFrame(encoded,
        source: name,
        trigger: (f['triggerTimestamp'] as num?)?.toDouble(),
        sourceSha256: sha);
    done++;
  }
  await writer.finalize(
      captureId: root.split('/').last, extra: 'p1_1_finalize_batch_curated');

  // 锐度自检(fail closed):抽首/中/末三帧,全部低于阈值才判失败。
  // [2026-08-10 误杀修正] 单帧阈值把"用户第一张恰好糊"(cap_1786369569928171
  // 首帧方差 46,但 85/85 帧 SHA 与最终版 JPEG 逐帧相等)误杀;要防的是
  // P1.0 那种**全体**占位帧的系统性竞态,不是个别真实糊帧——改多数帧投票。
  final probes = <int>{0, done ~/ 2, done - 1}.toList()..sort();
  final sharpnessByFrame = <String, double>{};
  var maxSharpness = 0.0;
  for (final frame in probes) {
    final v = _frameLaplacian(outDir, size.width, size.height, frame);
    sharpnessByFrame['$frame'] = v;
    if (v > maxSharpness) maxSharpness = v;
  }
  if (maxSharpness < CaptureArchiveService._minLaplacianVariance) {
    File('${outDir.path}/archive-error.json').writeAsStringSync(jsonEncode({
      'schema': 'pw_capture_archive_error_v1',
      'error': 'sharpness_self_check_failed',
      'laplacian_by_frame': sharpnessByFrame,
      'threshold': CaptureArchiveService._minLaplacianVariance,
    }));
    return {
      'status': 'failed_sharpness_check',
      'frames': done,
      'laplacian_by_frame': sharpnessByFrame,
    };
  }
  final manifest =
      jsonDecode(File('${outDir.path}/manifest.json').readAsStringSync());
  return {
    'schema': 'pw_capture_archive_report_v1',
    'status': 'finalized',
    'frames': done,
    'stream_bytes': manifest['stream_bytes'],
    'stream_sha256': manifest['stream_sha256'],
    'laplacian_by_frame': sharpnessByFrame,
  };
}

double _frameLaplacian(Directory outDir, int w, int h, int frameIndex) {
  final reader = PwvaReader(
      outDir, (au) => AppleHevcDecoder(width: w, height: h, keyframeAu: au));
  final frame = reader.readFrameNv12(frameIndex);
  final y = frame.y;
  // 4 倍下采样网格,4032x3024 只需 ~76 万点。
  var sum = 0.0, sumSq = 0.0;
  var n = 0;
  for (var r = 4; r < h - 4; r += 4) {
    for (var c = 4; c < w - 4; c += 4) {
      final i = r * w + c;
      final lap = 4 * y[i] - y[i - w] - y[i + w] - y[i - 1] - y[i + 1];
      sum += lap;
      sumSq += lap * lap;
      n++;
    }
  }
  final mean = sum / n;
  return sumSq / n - mean * mean;
}
