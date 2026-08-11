// PWVA 主本接管(P2 去 JPEG 化)全链路测试 — 真 VideoToolbox 编解码。
// 运行:PW_HEVC_NATIVE_DIR=packages/pw_hevc/native flutter test test/pwva_master_transaction_test.dart
// (dylib 由 packages/pw_hevc/tool/build_macos_dylibs.sh 产出;缺失则整组 skip)
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_codec.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_resolver.dart';
import 'package:pocketworld_flutter/official_capture/pwva_master.dart';
import 'package:pw_hevc/pwva.dart';
import 'package:pw_hevc/pwva_apple.dart';

const _w = 192;
const _h = 128;
const _frames = 12; // 1.5 个 GOP

bool get _nativeReady {
  final dir = Platform.environment['PW_HEVC_NATIVE_DIR'];
  return dir != null && File('$dir/libpw_vt_encoder.dylib').existsSync();
}

/// 合成一张有梯度纹理的 NV12 帧并落成 JPEG(经生产同款 C 编码器)。
void _writeTestJpeg(String path, int seed) {
  final y = Uint8List(_w * _h);
  for (var r = 0; r < _h; r++) {
    for (var c = 0; c < _w; c++) {
      y[r * _w + c] = (r * 2 + c * 3 + seed * 17) & 0xff;
    }
  }
  final uv = Uint8List(_w * _h ~/ 2);
  for (var i = 0; i < uv.length; i += 2) {
    uv[i] = (96 + seed * 5) & 0xff;
    uv[i + 1] = (160 + seed * 7) & 0xff;
  }
  writeNv12JpegFile(y, uv, width: _w, height: _h, path: path, quality: 0.9);
}

void main() {
  if (!_nativeReady) {
    test('skipped: PW_HEVC_NATIVE_DIR 未指向 mac dylib', () {});
    return;
  }

  late Directory captureDir;
  late Directory highresDir;
  late Directory hevcDir;
  final names = List.generate(_frames, (i) => 'official_tap-$i.jpg');

  Future<void> buildCapture() async {
    for (var i = 0; i < _frames; i++) {
      _writeTestJpeg('${highresDir.path}/${names[i]}', i);
      await File('${highresDir.path}/official_tap-$i.json')
          .writeAsString(jsonEncode({'t': i * 0.3, 'image_w': _w, 'image_h': _h}));
    }
    await File('${captureDir.path}/official_photo_bundle.json').writeAsString(
      jsonEncode({
        'schemaVersion': 'aether_photo_bundle_v1',
        'photosHighresDir': 'photos_highres',
        'frames': [
          for (final n in names) {'highresFilename': n},
        ],
      }),
    );
    // P1.1 同构:批量转码 + 逐帧源 sha + finalize + report。
    final encoder =
        AppleHevcEncoder(width: _w, height: _h, gop: 8, quality: 0.65);
    final writer =
        PwvaWriter(encoder, hevcDir, width: _w, height: _h, gop: 8);
    for (var i = 0; i < _frames; i++) {
      final path = '${highresDir.path}/${names[i]}';
      final sha = sha256.convert(File(path).readAsBytesSync()).toString();
      final encoded =
          encoder.encodeJpegFile(path, ptsMs: i * 300, durationMs: 300);
      writer.addEncodedFrame(encoded, source: names[i], sourceSha256: sha);
    }
    await writer.finalize(captureId: 'cap_test', extra: 'test');
    await File('${hevcDir.path}/archive-report.json')
        .writeAsString(jsonEncode({'status': 'finalized', 'frames': _frames}));
  }

  setUp(() async {
    captureDir = await Directory.systemTemp.createTemp('pw_pwva_master_');
    highresDir = Directory('${captureDir.path}/photos_highres');
    hevcDir = Directory('${captureDir.path}/photos_hevc');
    await highresDir.create(recursive: true);
    await hevcDir.create(recursive: true);
    await buildCapture();
  });

  tearDown(() async {
    if (await captureDir.exists()) await captureDir.delete(recursive: true);
  });

  test('全验证通过才接管:删策展 JPEG,留 sidecar,写 master-manifest', () async {
    final result =
        await const PwvaMasterTransaction().masterCapture(captureDir);
    expect(result.applicable, isTrue);
    expect(result.masteredNames, names);
    expect(result.failedNames, isEmpty);
    expect(result.paused, isFalse);
    for (final n in names) {
      expect(File('${highresDir.path}/$n').existsSync(), isFalse);
      expect(
          File('${highresDir.path}/${n.replaceAll('.jpg', '.json')}')
              .existsSync(),
          isTrue);
    }
    final master = await PwvaMasterManifest.read(captureDir);
    expect(master, isNotNull);
    expect(master!.entries.length, _frames);
  });

  test('任一源 JPEG 被篡改 → 不适用,一个字节不删', () async {
    final victim = File('${highresDir.path}/${names[5]}');
    await victim.writeAsBytes(
        [...await victim.readAsBytes(), 0x00], flush: true);
    final result =
        await const PwvaMasterTransaction().masterCapture(captureDir);
    expect(result.applicable, isFalse);
    for (final n in names) {
      expect(File('${highresDir.path}/$n').existsSync(), isTrue);
    }
    expect(await PwvaMasterManifest.read(captureDir), isNull);
  });

  test('码流损坏 → 不适用,回落 Lepton 线', () async {
    final stream = File('${hevcDir.path}/photos.hevc');
    final bytes = await stream.readAsBytes();
    bytes[bytes.length ~/ 2] ^= 0xff;
    await stream.writeAsBytes(bytes, flush: true);
    final result =
        await const PwvaMasterTransaction().masterCapture(captureDir);
    expect(result.applicable, isFalse);
    for (final n in names) {
      expect(File('${highresDir.path}/$n').existsSync(), isTrue);
    }
  });

  test('reconcile:manifest 已提交后中断,重跑删净剩余已验证源', () async {
    await const PwvaMasterTransaction().masterCapture(captureDir);
    // 模拟"删到一半崩了":重建两个源(字节与 manifest 记录一致)。
    _writeTestJpeg('${highresDir.path}/${names[0]}', 0);
    _writeTestJpeg('${highresDir.path}/${names[1]}', 1);
    final again =
        await const PwvaMasterTransaction().masterCapture(captureDir);
    expect(again.applicable, isTrue);
    expect(again.failedNames, isEmpty);
    expect(File('${highresDir.path}/${names[0]}').existsSync(), isFalse);
    expect(File('${highresDir.path}/${names[1]}').existsSync(), isFalse);
  });

  test('reconcile:源与记录不符则绝不删,记 failed', () async {
    await const PwvaMasterTransaction().masterCapture(captureDir);
    final rogue = File('${highresDir.path}/${names[3]}');
    await rogue.writeAsBytes([1, 2, 3], flush: true);
    final again =
        await const PwvaMasterTransaction().masterCapture(captureDir);
    expect(again.failedNames, [names[3]]);
    expect(rogue.existsSync(), isTrue);
  });

  test('物化回退:resolver 从码流解出可用 JPEG,尺寸正确且像素合理', () async {
    await const PwvaMasterTransaction().masterCapture(captureDir);
    final cache = await Directory.systemTemp.createTemp('pw_pwva_cache_');
    addTearDown(() => cache.delete(recursive: true));
    const resolver = PhotoArchiveResolver(codec: _NeverCodec());
    final resolved = await resolver.resolveJpeg(
      captureDirectory: captureDir,
      highresFilename: names[7],
      cacheDirectory: cache,
    );
    expect(resolved, isNotNull);
    final size = probeJpegSize(resolved!.path);
    expect(size.width, _w);
    expect(size.height, _h);
    // 第二次命中缓存(同一文件)。
    final second = await resolver.resolveJpeg(
      captureDirectory: captureDir,
      highresFilename: names[7],
      cacheDirectory: cache,
    );
    expect(second!.path, resolved.path);
  });
}

class _NeverCodec implements PhotoArchiveCodec {
  const _NeverCodec();

  @override
  bool get isSupported => false;

  @override
  Future<void> encodeJpeg(
          {required File sourceJpeg, required File destinationJxl}) =>
      throw UnsupportedError('not used');

  @override
  Future<void> reconstructJpeg(
          {required File sourceJxl, required File destinationJpeg}) =>
      throw UnsupportedError('not used');

  @override
  void requestCancellation() {}
}
