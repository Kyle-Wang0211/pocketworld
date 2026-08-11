import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:pw_hevc/pw_sidecar.dart';

void main() {
  test('往返逐字节一致', () {
    final entries = [
      SidecarEntry('b/view_graph.json',
          Uint8List.fromList(utf8.encode('{"nodes":[1,2,3]}'))),
      SidecarEntry('a.json', Uint8List.fromList(List.generate(5000, (i) => i & 0xFF))),
      SidecarEntry('empty.json', Uint8List(0)),
    ];
    final packed = packSidecars(entries);
    final restored = unpackSidecars(packed);
    expect(restored.length, 3);
    expect(restored[0].path, 'a.json', reason: '字典序');
    for (final r in restored) {
      final src = entries.firstWhere((e) => e.path == r.path);
      expect(sha256.convert(r.bytes).toString(),
          sha256.convert(src.bytes).toString());
    }
  });

  test('打包可复现:乱序输入产生相同字节', () {
    final a = SidecarEntry('x.json', Uint8List.fromList([1, 2, 3]));
    final b = SidecarEntry('y.json', Uint8List.fromList([4, 5, 6]));
    expect(packSidecars([a, b]), packSidecars([b, a]));
  });

  test('损坏 fail closed', () {
    final packed = packSidecars(
        [SidecarEntry('f.json', Uint8List.fromList(List.filled(1000, 7)))]);
    // 翻 SHA 字段(必炸)与 deflate 载荷中部(必炸);
    // 注意翻 zlib 尾部 adler32 不算损坏——数据完好,容器 SHA 才是权威。
    final corruptSha = Uint8List.fromList(packed);
    corruptSha[5 + 4 + 4 + 6 + 4 + 3] ^= 0x01;
    expect(() => unpackSidecars(corruptSha), throwsA(anything));
    final corruptPayload = Uint8List.fromList(packed);
    corruptPayload[corruptPayload.length - 12] ^= 0x10;
    expect(() => unpackSidecars(corruptPayload), throwsA(anything));
  });

  test('utf8 路径(中文文件名)', () {
    final entries = [SidecarEntry('采集/视图图.json', Uint8List.fromList([9]))];
    expect(unpackSidecars(packSidecars(entries))[0].path, '采集/视图图.json');
  });
}
