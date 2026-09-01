/// 编码器旋钮真机探针(pw_encoder_probe)
///
/// 文件触发(与 b1_gate 同款,零 UI):启动时若存在
/// `Documents/pw_encoder_probe_request.json`,消费它并对指定 capture 的前 N
/// 帧做 A/B 编码,结果写 `Documents/pw_encoder_probe_report.json`。
///
/// 当前唯一探针:`MaximizePowerEfficiency` 开/关。该开关是 2026-08-10 为
/// **拍摄期**转码抢热余量而启用的(编码功耗挤压 GPU 匹配);P1.1 之后转码
/// 改为拍摄结束后的批量收尾,那个热竞争已不存在 —— 如果关掉它能在同一画质
/// 目标下少花字节,就是零质量代价的净收益。Mac 侧测不出来(M3 Pro 的编码器
/// 忽略该属性,实测两臂字节完全相同),必须真机。
///
/// **只读不写生产数据**:两臂码流写进 `Documents/pw_encoder_probe/`,
/// capture 目录一个字节不动。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pw_hevc/pwva.dart';
import 'package:pw_hevc/pwva_apple.dart';

Future<void> maybeRunEncoderProbe(String documentsPath) async {
  final request = File('$documentsPath/pw_encoder_probe_request.json');
  try {
    if (!await request.exists()) return;
  } catch (_) {
    return;
  }
  Map<String, dynamic> req;
  try {
    req = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
  } catch (_) {
    try {
      await request.delete();
    } catch (_) {}
    return;
  }
  try {
    await request.delete(); // 一次投放只跑一次
  } catch (_) {}

  final captureId = req['capture_id'] as String?;
  final frames = (req['frames'] as num?)?.toInt() ?? 40;
  if (captureId == null || captureId.isEmpty) return;

  final captureDir = Directory('$documentsPath/captures_official/$captureId');
  final workDir = Directory('$documentsPath/pw_encoder_probe');
  final report = File('$documentsPath/pw_encoder_probe_report.json');
  final result = <String, Object?>{
    'schema': 'pw_encoder_probe_report_v1',
    'capture_id': captureId,
    'knob': 'MaximizePowerEfficiency',
  };

  Future<void> flush(String stage) async {
    result['stage'] = stage;
    result['updated_at'] = DateTime.now().toUtc().toIso8601String();
    try {
      await report.writeAsString(jsonEncode(result));
    } catch (_) {}
  }

  await flush('starting');
  try {
    // 源帧取自**已归档的码流**:P2 之后 JPEG 原件已被主本接管删除,而且
    // 从码流解出的 NV12 对两臂是**完全相同的输入**,A/B 反而更干净
    // (排除了 JPEG 解码差异)。
    final hevcDir = Directory('${captureDir.path}/photos_hevc');
    final manifestFile = File('${hevcDir.path}/manifest.json');
    if (!await manifestFile.exists()) {
      await flush('archive_missing');
      return;
    }
    final man =
        jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
    final res = (man['resolution'] as String).split('x');
    final w = int.parse(res[0]), h = int.parse(res[1]);
    final total = man['frame_count'] as int;
    final n = frames < total ? frames : total;
    if (n < 8) {
      result['error'] = 'archive has only $total frames';
      await flush('insufficient_frames');
      return;
    }
    result['frames_used'] = n;
    result['resolution'] = '${w}x$h';

    if (await workDir.exists()) await workDir.delete(recursive: true);
    await workDir.create(recursive: true);

    // [2026-08-13] 单解码会话顺序解码 + 两臂编码器同时在场。
    // 前一版用 PwvaReader.readFrameNv12(i) 逐帧读:它为**每帧新建一个解码
    // 会话**(随机访问的设计),连续 60 次 12MP 创建/销毁把解码器压垮
    // (真机 OSStatus=-12911 解码器故障)。顺序场景本就该一个会话读到底,
    // 顺带把解码工作量减半,且两臂吃到的 NV12 逐位相同。
    final entries = File('${hevcDir.path}/photos.pwvi')
        .readAsLinesSync()
        .map((l) => PwvaIndexEntry.fromJson(jsonDecode(l)))
        .toList();
    final streamFile = File('${hevcDir.path}/photos.hevc').openSync();
    Uint8List readAu(PwvaIndexEntry e) {
      streamFile.setPositionSync(e.offset);
      return streamFile.readSync(e.length);
    }

    await flush('encoding_both_arms');
    final started = DateTime.now();
    final decoder = AppleHevcDecoder(
      width: w,
      height: h,
      keyframeAu: readAu(entries[0]),
    );
    final arms =
        <bool, ({Directory dir, AppleHevcEncoder enc, PwvaWriter wr})>{};
    for (final pe in <bool>[true, false]) {
      final dir = Directory('${workDir.path}/pe_${pe ? 'on' : 'off'}');
      await dir.create(recursive: true);
      final enc = AppleHevcEncoder(
        width: w,
        height: h,
        gop: 8,
        quality: 0.65,
        powerEfficient: pe,
      );
      arms[pe] = (
        dir: dir,
        enc: enc,
        wr: PwvaWriter(enc, dir, width: w, height: h, gop: 8),
      );
    }
    try {
      final y = Uint8List(w * h);
      final uv = Uint8List(w * h ~/ 2);
      for (var i = 0; i < n; i++) {
        decoder.decodeAu(readAu(entries[i]), y, uv);
        for (final pe in <bool>[true, false]) {
          final a = arms[pe]!;
          a.wr.addEncodedFrame(
            a.enc.encodeNv12(y, uv, ptsMs: i * 300, durationMs: 300),
            source: 'frame_$i',
          );
        }
      }
    } finally {
      decoder.dispose();
      streamFile.closeSync();
    }
    for (final pe in <bool>[true, false]) {
      final a = arms[pe]!;
      await a.wr.finalize(captureId: captureId, extra: 'encoder_probe');
      result['pe_${pe ? 'on' : 'off'}'] = {
        'stream_bytes': await File('${a.dir.path}/photos.hevc').length(),
      };
    }
    result['elapsed_ms'] = DateTime.now().difference(started).inMilliseconds;

    final on = (result['pe_on'] as Map)['stream_bytes'] as int;
    final off = (result['pe_off'] as Map)['stream_bytes'] as int;
    result['delta_bytes'] = off - on;
    result['delta_pct'] = ((off - on) / on * 100).toStringAsFixed(2);
    await flush('done');
  } catch (e, st) {
    result['error'] = '$e';
    result['stack'] = '$st';
    await flush('exception');
  }
}
