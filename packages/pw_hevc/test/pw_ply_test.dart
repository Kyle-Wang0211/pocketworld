import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:pw_hevc/pw_ply.dart';

Uint8List syntheticPly(int n, {String format = 'binary_little_endian'}) {
  final header = 'ply\nformat $format 1.0\nelement vertex $n\n'
      'property float x\nproperty float y\nproperty float z\n'
      'property uchar red\nproperty uchar green\nproperty uchar blue\n'
      'end_header\n';
  final data = BytesBuilder()..add(ascii.encode(header));
  final bd = ByteData(15);
  for (var i = 0; i < n; i++) {
    bd.setFloat32(0, i * 0.5, Endian.little);
    bd.setFloat32(4, i * -1.25, Endian.little);
    bd.setFloat32(8, 1000.0 + i, Endian.little);
    bd.setUint8(12, i & 0xFF);
    bd.setUint8(13, (i * 7) & 0xFF);
    bd.setUint8(14, 200);
    data.add(bd.buffer.asUint8List().sublist(0, 15));
  }
  return data.toBytes();
}

void roundTrip(Uint8List original) {
  final packed = compressPly(original);
  final restored = decompressPly(packed);
  expect(restored.length, original.length);
  expect(sha256.convert(restored).toString(),
      sha256.convert(original).toString());
}

void main() {
  test('结构化路径逐字节往返', () => roundTrip(syntheticPly(1000)));

  test('单点与零点边界', () {
    roundTrip(syntheticPly(1));
    roundTrip(syntheticPly(0));
  });

  test('ascii 格式走回落模式且无损', () {
    final original = Uint8List.fromList(
        ascii.encode('ply\nformat ascii 1.0\nelement vertex 1\n'
            'property float x\nend_header\n0.5\n'));
    final packed = compressPly(original);
    expect(packed[5], 1, reason: '应为 raw-fallback 模式');
    roundTrip(original);
  });

  test('带尾部字节仍无损', () {
    final withTrailer = BytesBuilder()
      ..add(syntheticPly(10))
      ..add([1, 2, 3, 4, 5]);
    roundTrip(withTrailer.toBytes());
  });

  test('list 属性走回落模式', () {
    final original = Uint8List.fromList(ascii.encode(
        'ply\nformat binary_little_endian 1.0\nelement face 0\n'
        'property list uchar int vertex_indices\nend_header\n'));
    final packed = compressPly(original);
    expect(packed[5], 1);
    roundTrip(original);
  });

  test('载荷位翻转 fail closed', () {
    final packed = compressPly(syntheticPly(500));
    final corrupted = Uint8List.fromList(packed);
    corrupted[corrupted.length - 10] ^= 0x40;
    expect(() => decompressPly(corrupted), throwsA(anything));
  });

  test('SHA 段位翻转 fail closed', () {
    final packed = compressPly(syntheticPly(500));
    final corrupted = Uint8List.fromList(packed);
    corrupted[20] ^= 0x01; // sha256 区域内
    expect(() => decompressPly(corrupted),
        throwsA(isA<FormatException>()));
  });

  test('截断 fail closed', () {
    final packed = compressPly(syntheticPly(500));
    expect(
        () => decompressPly(
            Uint8List.sublistView(packed, 0, packed.length ~/ 2)),
        throwsA(anything));
  });

  test('float 位模式极值原样保留(NaN/Inf/-0.0/denormal)', () {
    final header = 'ply\nformat binary_little_endian 1.0\n'
        'element vertex 4\nproperty float x\nend_header\n';
    final data = BytesBuilder()..add(ascii.encode(header));
    for (final bits in [0x7FC00001, 0x7F800000, 0x80000000, 0x00000001]) {
      final bd = ByteData(4)..setUint32(0, bits, Endian.little);
      data.add(bd.buffer.asUint8List());
    }
    roundTrip(data.toBytes());
  });
}
