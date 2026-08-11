@TestOn('mac-os')
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:pw_hevc/pwva.dart';
import 'package:pw_hevc/pwva_apple.dart';

Uint8List patternY(int w, int h, int seed) {
  final y = Uint8List(w * h);
  for (var r = 0; r < h; r++) {
    for (var c = 0; c < w; c++) {
      y[r * w + c] = (r + c + seed * 17) & 0xFF;
    }
  }
  return y;
}

void main() {
  test('端到端:流式写入 → 随机访问读回,GOP 边界正确', () async {
    const w = 640, h = 360, gop = 4, frames = 10;
    final dir = Directory.systemTemp.createTempSync('pwva_test');
    final writer = PwvaWriter(
        AppleHevcEncoder(width: w, height: h, gop: gop, quality: 0.8),
        dir, width: w, height: h, gop: gop);
    final uv = Uint8List(w * h ~/ 2)..fillRange(0, w * h ~/ 2, 128);
    for (var i = 0; i < frames; i++) {
      writer.addFrameNv12(patternY(w, h, i), uv, source: 'f$i');
    }
    await writer.finalize(captureId: 'test');

    final reader = PwvaReader(dir,
        (keyAu) => AppleHevcDecoder(width: w, height: h, keyframeAu: keyAu));
    expect(reader.frameCount, frames);
    // GOP=4 ⇒ 帧 0/4/8 是关键帧
    expect(reader.entries[0].keyframe, isTrue);
    expect(reader.entries[4].keyframe, isTrue);
    expect(reader.entries[5].keyframe, isFalse);

    final r6 = reader.readFrameNv12(6);
    expect(r6.decodedAus, 3, reason: '帧6 应只解 4..6 共 3 个 AU');
    final r4 = reader.readFrameNv12(4);
    expect(r4.decodedAus, 1);
    // 有损编码,验证内容近似(与源图样均差 < 8)
    final src = patternY(w, h, 6);
    var err = 0;
    for (var i = 0; i < src.length; i++) {
      err += (src[i] - r6.y[i]).abs();
    }
    expect(err / src.length, lessThan(8.0));
    dir.deleteSync(recursive: true);
  });

  test('断点安全:截断的归档前缀仍可读', () {
    const w = 640, h = 360;
    final dir = Directory.systemTemp.createTempSync('pwva_trunc');
    final writer = PwvaWriter(
        AppleHevcEncoder(width: w, height: h, gop: 4, quality: 0.8),
        dir, width: w, height: h, gop: 4);
    final uv = Uint8List(w * h ~/ 2)..fillRange(0, w * h ~/ 2, 128);
    for (var i = 0; i < 6; i++) {
      writer.addFrameNv12(patternY(w, h, i), uv);
    }
    // 模拟中断:不 finalize,手写最小 manifest(恢复流程职责)
    File('${dir.path}/manifest.json').writeAsStringSync(
        '{"schema":"pw_video_archive_v1","resolution":"${w}x$h"}');
    final reader = PwvaReader(dir,
        (keyAu) => AppleHevcDecoder(width: w, height: h, keyframeAu: keyAu));
    expect(reader.frameCount, 6);
    expect(reader.readFrameNv12(5).decodedAus, 2);
    dir.deleteSync(recursive: true);
  });
}
