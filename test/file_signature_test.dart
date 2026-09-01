// magic bytes 判定规则。
//
// 重点在**伪装场景**:一个 .ply 文件里装的是 PNG/可执行体,声明与内容不符。
// 这才是这套规则存在的理由 —— 扩展名与 Content-Type 都是攻击者可控的声明。

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/util/file_signature.dart';

Uint8List _bytes(List<int> b) => Uint8List.fromList(b);
Uint8List _ascii(String s, {int pad = 0}) =>
    Uint8List.fromList([...s.codeUnits, ...List.filled(pad, 0)]);

final _png = _bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0]);
final _jpeg = _bytes([0xFF, 0xD8, 0xFF, 0xE0, 0, 0, 0, 0]);
final _elf = _bytes([0x7F, 0x45, 0x4C, 0x46, 2, 1, 1, 0]); // Linux 可执行体
final _mzExe = _bytes([0x4D, 0x5A, 0x90, 0x00, 0, 0, 0, 0]); // Windows PE

void main() {
  group('正确识别各格式', () {
    test(
      'PLY',
      () => expect(
        detectAssetKind(_ascii('ply\nformat ascii 1.0')),
        AssetKind.ply,
      ),
    );
    test(
      'GLB',
      () => expect(detectAssetKind(_ascii('glTF', pad: 8)), AssetKind.glb),
    );
    test('JPEG', () => expect(detectAssetKind(_jpeg), AssetKind.jpeg));
    test('PNG', () => expect(detectAssetKind(_png), AssetKind.png));
  });

  group('不认识的内容一律返回 null(默认拒绝)', () {
    test('Linux 可执行体', () => expect(detectAssetKind(_elf), isNull));
    test('Windows PE', () => expect(detectAssetKind(_mzExe), isNull));
    test(
      'HTML',
      () => expect(detectAssetKind(_ascii('<html><script>')), isNull),
    );
    test('空内容', () => expect(detectAssetKind(_bytes([])), isNull));
    test('短于任何签名', () => expect(detectAssetKind(_bytes([0xFF])), isNull));
  });

  group('🔑 伪装检测 —— 这才是重点', () {
    test('PNG 伪装成 .ply 被识破', () {
      expect(matchesDeclaredExtension(_png, 'uid/abc123.ply'), isFalse);
    });

    test('可执行体伪装成 .glb 被识破', () {
      expect(matchesDeclaredExtension(_mzExe, 'uid/model.glb'), isFalse);
    });

    test('HTML 伪装成 .jpg 被识破(XSS/钓鱼向量)', () {
      expect(
        matchesDeclaredExtension(
          _ascii('<html><script>x</script>'),
          'uid/w.jpg',
        ),
        isFalse,
      );
    });

    test('名副其实的文件通过', () {
      expect(
        matchesDeclaredExtension(_ascii('ply\nformat'), 'uid/h.ply'),
        isTrue,
      );
      expect(matchesDeclaredExtension(_jpeg, 'uid/w.jpeg'), isTrue);
      expect(matchesDeclaredExtension(_png, 'uid/w.png'), isTrue);
    });
  });

  group('扩展名解析', () {
    test('大小写不敏感', () {
      expect(kindForExtension('a/B.PLY'), AssetKind.ply);
      expect(kindForExtension('a/B.JPEG'), AssetKind.jpeg);
    });

    test('无后缀 / 空后缀 / 未知后缀 一律 null', () {
      expect(kindForExtension('uid/noext'), isNull);
      expect(kindForExtension('uid/trailing.'), isNull);
      expect(kindForExtension('uid/x.exe'), isNull);
      expect(kindForExtension('uid/x.html'), isNull);
    });

    test('未知后缀 ⇒ matchesDeclaredExtension 为 false,即便内容合法', () {
      // 内容是合法 PNG,但声明成 .exe ⇒ 仍然拒绝。
      expect(matchesDeclaredExtension(_png, 'uid/x.exe'), isFalse);
    });
  });

  test('探测所需字节数足够覆盖最长签名(PNG 的 8 字节)', () {
    expect(kSignatureProbeBytes >= 8, isTrue);
    // 只给前 kSignatureProbeBytes 字节也应判定成功 —— 服务端 Range 请求
    // 只取头部就够,不必为校验下载整个模型。
    final head = Uint8List.fromList(_png.take(kSignatureProbeBytes).toList());
    expect(detectAssetKind(head), AssetKind.png);
  });
}
