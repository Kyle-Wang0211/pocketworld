/// pw_ply — 稀疏点云 PLY 的严格无损跨端压缩(纯 Dart,零原生依赖)
///
/// 无损定义:解压后与原 PLY 文件逐字节一致,长度一致,SHA-256 相同。
/// 每个 float32 的位模式原样保留——不量化、不改精度、不重排点序。
///
/// 方法(全部可逆):
///   1. 解析 PLY 头,把 AoS 顶点数据按属性拆成独立列(SoA);
///   2. 每列注册三种候选变换:原样 / 字节面转置 / 32 位逐点差分+字节面转置;
///   3. 每列每候选各压一次(deflate 9),取最小者,变换 ID 记入容器;
///   4. 结构不符合预期(ascii、未知属性、长度不符)时整体回落到
///      whole-file deflate——仍然严格无损,只是压缩率低。
///
/// 容器自带原文件 SHA-256,解压端强制校验,损坏 fail closed。
library pw_ply;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

const _magic = 'PWPL1';
const int _modeStructured = 0;
const int _modeRawFallback = 1;

const int _xformRaw = 0;
const int _xformByteTranspose = 1;
const int _xformDelta32Transpose = 2;

class PlyProperty {
  final String type;
  final String name;
  PlyProperty(this.type, this.name);
  int get width => switch (type) {
        'float' || 'float32' || 'int' || 'int32' || 'uint' || 'uint32' => 4,
        'double' || 'float64' => 8,
        'short' || 'ushort' || 'int16' || 'uint16' => 2,
        'char' || 'uchar' || 'int8' || 'uint8' => 1,
        _ => -1,
      };
}

class PlyHeader {
  final String text;
  final int vertexCount;
  final List<PlyProperty> properties;
  PlyHeader(this.text, this.vertexCount, this.properties);

  int get stride =>
      properties.fold(0, (sum, p) => p.width < 0 ? -1 << 30 : sum + p.width);

  /// 只处理最常见形态:binary_little_endian、单一 vertex 元素、定宽属性。
  /// 其余形态由调用方回落到 whole-file 模式。
  static PlyHeader? tryParse(Uint8List bytes) {
    const endMark = 'end_header\n';
    final probe = latin1.decode(
        bytes.sublist(0, bytes.length < 4096 ? bytes.length : 4096),
        allowInvalid: true);
    final end = probe.indexOf(endMark);
    if (end < 0) return null;
    final text = probe.substring(0, end + endMark.length);
    if (!text.startsWith('ply\n')) return null;
    if (!text.contains('format binary_little_endian 1.0')) return null;

    var vertexCount = -1;
    final properties = <PlyProperty>[];
    var elementCount = 0;
    for (final line in text.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts[0] == 'element') {
        elementCount++;
        if (parts[1] == 'vertex') vertexCount = int.parse(parts[2]);
      } else if (parts[0] == 'property') {
        if (parts[1] == 'list') return null; // 变长属性交给回落模式
        properties.add(PlyProperty(parts[1], parts[2]));
      }
    }
    if (elementCount != 1 || vertexCount < 0 || properties.isEmpty) return null;
    final header = PlyHeader(text, vertexCount, properties);
    if (header.stride <= 0) return null;
    return header;
  }
}

Uint8List _deflate(List<int> data) =>
    Uint8List.fromList(ZLibCodec(level: 9).encode(data));

Uint8List _inflate(List<int> data) =>
    Uint8List.fromList(zlib.decode(data));

/// 列数据 → 字节面转置:[b0 b1 b2 b3][b0 b1 b2 b3]… → [所有b0][所有b1]…
Uint8List _byteTranspose(Uint8List column, int width) {
  final n = column.length ~/ width;
  final out = Uint8List(column.length);
  for (var i = 0; i < n; i++) {
    for (var b = 0; b < width; b++) {
      out[b * n + i] = column[i * width + b];
    }
  }
  return out;
}

Uint8List _byteTransposeInverse(Uint8List planes, int width) {
  final n = planes.length ~/ width;
  final out = Uint8List(planes.length);
  for (var i = 0; i < n; i++) {
    for (var b = 0; b < width; b++) {
      out[i * width + b] = planes[b * n + i];
    }
  }
  return out;
}

/// 32 位无符号回绕差分(位模式域,对 float 同样可逆)。
Uint8List _delta32(Uint8List column) {
  final words = column.buffer.asUint32List(
      column.offsetInBytes, column.length ~/ 4);
  final out = Uint32List(words.length);
  var previous = 0;
  for (var i = 0; i < words.length; i++) {
    out[i] = (words[i] - previous) & 0xFFFFFFFF;
    previous = words[i];
  }
  return out.buffer.asUint8List();
}

Uint8List _delta32Inverse(Uint8List deltas) {
  final words = deltas.buffer.asUint32List(
      deltas.offsetInBytes, deltas.length ~/ 4);
  final out = Uint32List(words.length);
  var previous = 0;
  for (var i = 0; i < words.length; i++) {
    previous = (previous + words[i]) & 0xFFFFFFFF;
    out[i] = previous;
  }
  return out.buffer.asUint8List();
}

class _Stream {
  final int transform;
  final Uint8List compressed;
  _Stream(this.transform, this.compressed);
}

/// 压缩。永远成功,永远无损;结构不匹配只影响压缩率。
Uint8List compressPly(Uint8List original) {
  final digest = sha256.convert(original).bytes;
  final header = PlyHeader.tryParse(original);

  final builder = BytesBuilder();
  builder.add(ascii.encode(_magic));

  if (header != null) {
    final headerBytes = ascii.encode(header.text).length;
    final stride = header.stride;
    final dataLength = header.vertexCount * stride;
    if (headerBytes + dataLength <= original.length) {
      final streams = <_Stream>[];
      var offset = headerBytes;
      var fieldOffset = 0;
      for (final property in header.properties) {
        final width = property.width;
        final column = Uint8List(header.vertexCount * width);
        for (var i = 0; i < header.vertexCount; i++) {
          final src = offset + i * stride + fieldOffset;
          column.setRange(i * width, (i + 1) * width, original, src);
        }
        fieldOffset += width;

        final candidates = <int, Uint8List>{
          _xformRaw: column,
          if (width > 1) _xformByteTranspose: _byteTranspose(column, width),
          if (width == 4)
            _xformDelta32Transpose: _byteTranspose(_delta32(column), 4),
        };
        int bestId = _xformRaw;
        Uint8List? best;
        candidates.forEach((id, data) {
          final packed = _deflate(data);
          if (best == null || packed.length < best!.length) {
            best = packed;
            bestId = id;
          }
        });
        streams.add(_Stream(bestId, best!));
      }
      final trailer = original.sublist(headerBytes + dataLength);

      builder.addByte(_modeStructured);
      final headerComp = _deflate(ascii.encode(header.text));
      _writeU32(builder, headerComp.length);
      builder.add(headerComp);
      _writeU32(builder, original.length);
      builder.add(digest);
      builder.addByte(streams.length);
      for (final s in streams) {
        builder.addByte(s.transform);
        _writeU32(builder, s.compressed.length);
        builder.add(s.compressed);
      }
      final trailerComp = _deflate(trailer);
      _writeU32(builder, trailerComp.length);
      builder.add(trailerComp);
      return builder.toBytes();
    }
  }

  builder.addByte(_modeRawFallback);
  _writeU32(builder, original.length);
  builder.add(digest);
  final whole = _deflate(original);
  _writeU32(builder, whole.length);
  builder.add(whole);
  return builder.toBytes();
}

/// 解压。SHA-256 或长度不符即抛异常(fail closed),绝不吐出可疑字节。
Uint8List decompressPly(Uint8List archive) {
  var pos = 0;
  Uint8List take(int n) {
    final out = Uint8List.sublistView(archive, pos, pos + n);
    pos += n;
    return out;
  }

  if (ascii.decode(take(5)) != _magic) {
    throw const FormatException('bad magic');
  }
  final mode = take(1)[0];

  late Uint8List restored;
  late Uint8List expectedDigest;
  if (mode == _modeRawFallback) {
    final originalLength = _readU32(take(4));
    expectedDigest = take(32);
    final compLen = _readU32(take(4));
    restored = _inflate(take(compLen));
    if (restored.length != originalLength) {
      throw const FormatException('length mismatch');
    }
  } else if (mode == _modeStructured) {
    final headerCompLen = _readU32(take(4));
    final headerText = ascii.decode(_inflate(take(headerCompLen)));
    final originalLength = _readU32(take(4));
    expectedDigest = take(32);
    final header = PlyHeader.tryParse(
        Uint8List.fromList(ascii.encode(headerText)))!;
    final streamCount = take(1)[0];
    if (streamCount != header.properties.length) {
      throw const FormatException('stream count mismatch');
    }
    final columns = <Uint8List>[];
    for (final property in header.properties) {
      final transform = take(1)[0];
      final compLen = _readU32(take(4));
      var column = _inflate(take(compLen));
      column = switch (transform) {
        _xformRaw => column,
        _xformByteTranspose =>
          _byteTransposeInverse(column, property.width),
        _xformDelta32Transpose =>
          _delta32Inverse(_byteTransposeInverse(column, 4)),
        _ => throw const FormatException('unknown transform'),
      };
      columns.add(column);
    }
    final trailerCompLen = _readU32(take(4));
    final trailer = _inflate(take(trailerCompLen));

    final stride = header.stride;
    final data = Uint8List(header.vertexCount * stride);
    var fieldOffset = 0;
    for (var p = 0; p < header.properties.length; p++) {
      final width = header.properties[p].width;
      final column = columns[p];
      for (var i = 0; i < header.vertexCount; i++) {
        data.setRange(i * stride + fieldOffset,
            i * stride + fieldOffset + width, column, i * width);
      }
      fieldOffset += width;
    }
    final out = BytesBuilder()
      ..add(ascii.encode(headerText))
      ..add(data)
      ..add(trailer);
    restored = out.toBytes();
    if (restored.length != originalLength) {
      throw const FormatException('length mismatch');
    }
  } else {
    throw const FormatException('unknown mode');
  }

  final actual = sha256.convert(restored).bytes;
  for (var i = 0; i < 32; i++) {
    if (actual[i] != expectedDigest[i]) {
      throw const FormatException('sha256 mismatch — refusing to emit bytes');
    }
  }
  return restored;
}

void _writeU32(BytesBuilder b, int v) =>
    b.add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);

int _readU32(Uint8List b) => b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24);
