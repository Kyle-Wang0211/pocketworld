/// PWSC1 容器:把 N 个小文件拼成一个字节流,供单文件编解码器(产品 ZPAQ)
/// 处理。**格式的唯一职责是可逆**,不做任何变换 —— 内容逐字节原样落在
/// 容器里,所以"解压回来逐字节等于源文件"是可以直接对账的。
///
/// 布局(小端):
///   magic  8B  'PWSC1\0\0\0'
///   count  u32
///   × count: pathLen u16 | path(UTF-8) | contentLen u32 | content
///
/// 条目按 path 升序写入,保证同一批文件每次生成的容器逐字节相同(幂等,
/// 也让"清单里的 container_sha256"是个稳定的判据)。
library;

import 'dart:convert';
import 'dart:typed_data';

const List<int> _magic = <int>[0x50, 0x57, 0x53, 0x43, 0x31, 0, 0, 0];

class AuxContainerEntry {
  const AuxContainerEntry({required this.relativePath, required this.bytes});

  final String relativePath;
  final Uint8List bytes;
}

class AuxContainerFormatException implements Exception {
  const AuxContainerFormatException(this.message);
  final String message;
  @override
  String toString() => 'AuxContainerFormatException: $message';
}

Uint8List encodeAuxContainer(List<AuxContainerEntry> entries) {
  final sorted = <AuxContainerEntry>[...entries]
    ..sort((left, right) => left.relativePath.compareTo(right.relativePath));
  final encodedPaths = <Uint8List>[
    for (final entry in sorted)
      Uint8List.fromList(utf8.encode(entry.relativePath)),
  ];
  var total = _magic.length + 4;
  for (var index = 0; index < sorted.length; index++) {
    total += 2 + encodedPaths[index].length + 4 + sorted[index].bytes.length;
  }
  final out = Uint8List(total);
  final view = ByteData.view(out.buffer);
  out.setRange(0, _magic.length, _magic);
  var offset = _magic.length;
  view.setUint32(offset, sorted.length, Endian.little);
  offset += 4;
  for (var index = 0; index < sorted.length; index++) {
    final path = encodedPaths[index];
    final content = sorted[index].bytes;
    if (path.length > 0xffff) {
      throw const AuxContainerFormatException('path too long');
    }
    view.setUint16(offset, path.length, Endian.little);
    offset += 2;
    out.setRange(offset, offset + path.length, path);
    offset += path.length;
    view.setUint32(offset, content.length, Endian.little);
    offset += 4;
    out.setRange(offset, offset + content.length, content);
    offset += content.length;
  }
  return out;
}

List<AuxContainerEntry> decodeAuxContainer(Uint8List raw) {
  if (raw.length < _magic.length + 4) {
    throw const AuxContainerFormatException('truncated header');
  }
  for (var index = 0; index < _magic.length; index++) {
    if (raw[index] != _magic[index]) {
      throw const AuxContainerFormatException('bad magic');
    }
  }
  final view = ByteData.view(raw.buffer, raw.offsetInBytes, raw.length);
  var offset = _magic.length;
  final count = view.getUint32(offset, Endian.little);
  offset += 4;
  final entries = <AuxContainerEntry>[];
  for (var index = 0; index < count; index++) {
    if (offset + 2 > raw.length) {
      throw const AuxContainerFormatException('truncated path length');
    }
    final pathLength = view.getUint16(offset, Endian.little);
    offset += 2;
    if (offset + pathLength + 4 > raw.length) {
      throw const AuxContainerFormatException('truncated path');
    }
    final path = utf8.decode(raw.sublist(offset, offset + pathLength));
    offset += pathLength;
    final contentLength = view.getUint32(offset, Endian.little);
    offset += 4;
    if (offset + contentLength > raw.length) {
      throw const AuxContainerFormatException('truncated content');
    }
    entries.add(
      AuxContainerEntry(
        relativePath: path,
        bytes: Uint8List.sublistView(raw, offset, offset + contentLength),
      ),
    );
    offset += contentLength;
  }
  if (offset != raw.length) {
    throw const AuxContainerFormatException('trailing bytes');
  }
  return entries;
}
