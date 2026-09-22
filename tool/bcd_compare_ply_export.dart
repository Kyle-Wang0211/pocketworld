// Exports one frozen B/C quality fixture as a deterministic true-colour PLY.
//
// The original sparse metric cloud is the exact byte prefix. RGB comes from
// the fixture's immutable NPZ, and structural RGB comes from native JPEG
// readback. This tool never recolours, downsamples, filters, or deletes points.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pocketworld_flutter/capture/bcd_finalize_coordinator.dart';
import 'package:pocketworld_flutter/capture/bcd_structural_quality_runner.dart';

const int _vertexStride = 15;

final class _NpyArray {
  const _NpyArray({
    required this.descriptor,
    required this.fortranOrder,
    required this.rows,
    required this.columns,
    required this.data,
  });

  final String descriptor;
  final bool fortranOrder;
  final int rows;
  final int columns;
  final Uint8List data;
}

Uint8List _readBytes(String path) => File(path).readAsBytesSync();

String _sha256Bytes(List<int> bytes) => sha256.convert(bytes).toString();

Float32List _float32FromLittleEndian(Uint8List bytes) {
  if (bytes.length % Float32List.bytesPerElement != 0) {
    throw FormatException('Float32 byte count is not divisible by four');
  }
  final data = ByteData.sublistView(bytes);
  final output = Float32List(bytes.length ~/ Float32List.bytesPerElement);
  for (var index = 0; index < output.length; index++) {
    output[index] = data.getFloat32(
      index * Float32List.bytesPerElement,
      Endian.little,
    );
    if (!output[index].isFinite) {
      throw FormatException('sparse XYZ contains a non-finite value');
    }
  }
  return output;
}

_NpyArray _decodeNpy(Uint8List bytes, String name) {
  const magic = <int>[0x93, 0x4e, 0x55, 0x4d, 0x50, 0x59];
  if (bytes.length < 10 ||
      [
        for (var index = 0; index < magic.length; index++) bytes[index],
      ].asMap().entries.any((entry) => entry.value != magic[entry.key])) {
    throw FormatException('$name is not a NPY array');
  }
  final major = bytes[6];
  final data = ByteData.sublistView(bytes);
  final headerLengthBytes = major == 1 ? 2 : 4;
  if (major != 1 && major != 2 && major != 3) {
    throw FormatException('$name uses unsupported NPY version $major');
  }
  final headerLength = headerLengthBytes == 2
      ? data.getUint16(8, Endian.little)
      : data.getUint32(8, Endian.little);
  final headerStart = 8 + headerLengthBytes;
  final payloadStart = headerStart + headerLength;
  if (payloadStart > bytes.length) {
    throw FormatException('$name has a truncated NPY header');
  }
  final header = ascii.decode(bytes.sublist(headerStart, payloadStart));
  final descriptor = RegExp(
    r'''['"]descr['"]\s*:\s*['"]([^'"]+)['"]''',
  ).firstMatch(header)?.group(1);
  final fortranToken = RegExp(
    r'''['"]fortran_order['"]\s*:\s*(True|False)''',
  ).firstMatch(header)?.group(1);
  final shapeMatch = RegExp(
    r'''['"]shape['"]\s*:\s*\(\s*([0-9]+)\s*,\s*([0-9]+)\s*,?\s*\)''',
  ).firstMatch(header);
  if (descriptor == null || fortranToken == null || shapeMatch == null) {
    throw FormatException('$name has an unsupported NPY header: $header');
  }
  return _NpyArray(
    descriptor: descriptor,
    fortranOrder: fortranToken == 'True',
    rows: int.parse(shapeMatch.group(1)!),
    columns: int.parse(shapeMatch.group(2)!),
    data: Uint8List.sublistView(bytes, payloadStart),
  );
}

Map<String, _NpyArray> _readMetricNpz(String path) {
  final archive = _decodeNpzZip(_readBytes(path));
  final output = <String, _NpyArray>{};
  for (final entry in archive.entries) {
    if (!entry.key.endsWith('.npy')) continue;
    output[entry.key] = _decodeNpy(entry.value, entry.key);
  }
  return output;
}

Map<String, Uint8List> _decodeNpzZip(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final files = <String, Uint8List>{};
  var offset = 0;
  while (offset + 4 <= bytes.length) {
    final signature = data.getUint32(offset, Endian.little);
    if (signature == 0x02014b50 || signature == 0x06054b50) break;
    if (signature != 0x04034b50 || offset + 30 > bytes.length) {
      throw FormatException('metric NPZ has an invalid ZIP local header');
    }
    final flags = data.getUint16(offset + 6, Endian.little);
    final compression = data.getUint16(offset + 8, Endian.little);
    final expectedCrc = data.getUint32(offset + 14, Endian.little);
    final compressed32 = data.getUint32(offset + 18, Endian.little);
    final uncompressed32 = data.getUint32(offset + 22, Endian.little);
    final nameLength = data.getUint16(offset + 26, Endian.little);
    final extraLength = data.getUint16(offset + 28, Endian.little);
    if (flags & 0x0008 != 0) {
      throw FormatException('metric NPZ uses an unsupported data descriptor');
    }
    final nameStart = offset + 30;
    final extraStart = nameStart + nameLength;
    final payloadStart = extraStart + extraLength;
    if (payloadStart > bytes.length) {
      throw FormatException('metric NPZ local header is truncated');
    }
    final name = utf8.decode(bytes.sublist(nameStart, extraStart));
    var compressedSize = compressed32;
    var uncompressedSize = uncompressed32;
    if (compressed32 == 0xffffffff || uncompressed32 == 0xffffffff) {
      var cursor = extraStart;
      final extraEnd = extraStart + extraLength;
      var foundZip64 = false;
      while (cursor + 4 <= extraEnd) {
        final id = data.getUint16(cursor, Endian.little);
        final length = data.getUint16(cursor + 2, Endian.little);
        cursor += 4;
        if (cursor + length > extraEnd) {
          throw FormatException('metric NPZ ZIP extra field is truncated');
        }
        if (id == 0x0001) {
          var zip64 = cursor;
          if (uncompressed32 == 0xffffffff) {
            uncompressedSize = data.getUint64(zip64, Endian.little);
            zip64 += 8;
          }
          if (compressed32 == 0xffffffff) {
            compressedSize = data.getUint64(zip64, Endian.little);
          }
          foundZip64 = true;
          break;
        }
        cursor += length;
      }
      if (!foundZip64) {
        throw FormatException('metric NPZ ZIP64 sizes are absent');
      }
    }
    final payloadEnd = payloadStart + compressedSize;
    if (compressedSize < 0 ||
        uncompressedSize < 0 ||
        payloadEnd > bytes.length) {
      throw FormatException('metric NPZ compressed payload is truncated');
    }
    final compressed = bytes.sublist(payloadStart, payloadEnd);
    final decoded = switch (compression) {
      0 => Uint8List.fromList(compressed),
      8 => Uint8List.fromList(ZLibDecoder(raw: true).convert(compressed)),
      _ => throw FormatException(
        'metric NPZ uses unsupported ZIP compression $compression',
      ),
    };
    if (decoded.length != uncompressedSize || _crc32(decoded) != expectedCrc) {
      throw StateError('metric NPZ failed ZIP length/CRC verification: $name');
    }
    if (files.containsKey(name)) {
      throw StateError('metric NPZ contains a duplicate member: $name');
    }
    files[name] = decoded;
    offset = payloadEnd;
  }
  if (files.isEmpty) throw FormatException('metric NPZ contains no files');
  return files;
}

int _crc32(Uint8List bytes) {
  var crc = 0xffffffff;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xedb88320 : crc >> 1;
    }
  }
  return (crc ^ 0xffffffff) & 0xffffffff;
}

int _arrayOffset(_NpyArray array, int row, int column, int elementBytes) =>
    (array.fortranOrder
        ? column * array.rows + row
        : row * array.columns + column) *
    elementBytes;

Uint8List _validateAndReadRgb({
  required Map scene,
  required Uint8List sparseXyzBytes,
}) {
  final source = scene['sparse_xyz_source'] as Map;
  final npzPath = source['path'] as String;
  final npzBytes = _readBytes(npzPath);
  if (_sha256Bytes(npzBytes) != source['sha256']) {
    throw StateError('metric NPZ hash differs from the frozen manifest');
  }
  if (_sha256Bytes(sparseXyzBytes) != source['raw_sha256']) {
    throw StateError('sparse XYZ hash differs from the frozen manifest');
  }
  final arrays = _readMetricNpz(npzPath);
  final xyz = arrays['xyz.npy'];
  final rgb = arrays['rgb.npy'];
  final pointCount = sparseXyzBytes.length ~/ 12;
  if (xyz == null ||
      rgb == null ||
      xyz.descriptor != '<f4' ||
      rgb.descriptor != '|u1' ||
      xyz.rows != pointCount ||
      rgb.rows != pointCount ||
      xyz.columns != 3 ||
      rgb.columns != 3 ||
      xyz.data.length != pointCount * 3 * 4 ||
      rgb.data.length != pointCount * 3 ||
      source['point_count'] != pointCount) {
    throw StateError('metric NPZ XYZ/RGB layout differs from the manifest');
  }
  for (var point = 0; point < pointCount; point++) {
    for (var axis = 0; axis < 3; axis++) {
      final expected = (point * 3 + axis) * 4;
      final actual = _arrayOffset(xyz, point, axis, 4);
      for (var byte = 0; byte < 4; byte++) {
        if (sparseXyzBytes[expected + byte] != xyz.data[actual + byte]) {
          throw StateError(
            'metric NPZ XYZ order differs at point=$point axis=$axis',
          );
        }
      }
    }
  }
  final output = Uint8List(pointCount * 3);
  for (var point = 0; point < pointCount; point++) {
    for (var axis = 0; axis < 3; axis++) {
      output[point * 3 + axis] = rgb.data[_arrayOffset(rgb, point, axis, 1)];
    }
  }
  return output;
}

bool _sameStringSet(Object? rawExpected, List<String> actual) {
  if (rawExpected is! List || rawExpected.length != actual.length) {
    return false;
  }
  final expected = rawExpected.cast<String>().toSet();
  final observed = actual.toSet();
  return expected.length == rawExpected.length &&
      observed.length == actual.length &&
      expected.containsAll(observed);
}

int _pointCount(List<BcdStructuralBirthResult> births) =>
    births.fold<int>(0, (sum, birth) => sum + birth.cloud.pointCount);

Uint8List _encodePly({
  required String capture,
  required Uint8List sparseXyzBytes,
  required Uint8List sparseRgb,
  required List<BcdStructuralBirthResult> births,
}) {
  final originalPoints = sparseXyzBytes.length ~/ 12;
  final birthPoints = _pointCount(births);
  final totalPoints = originalPoints + birthPoints;
  final header = utf8.encode(
    'ply\n'
    'format binary_little_endian 1.0\n'
    'comment PocketWorld $capture true-color B/C comparison export\n'
    'comment sparse RGB copied from immutable metric NPZ; birth RGB copied from native JPEG readback\n'
    'comment no pseudocolor no filtering no downsampling\n'
    'element vertex $totalPoints\n'
    'property float x\n'
    'property float y\n'
    'property float z\n'
    'property uchar red\n'
    'property uchar green\n'
    'property uchar blue\n'
    'end_header\n',
  );
  final output = Uint8List(header.length + totalPoints * _vertexStride);
  output.setRange(0, header.length, header);
  var bodyOffset = header.length;
  for (var point = 0; point < originalPoints; point++) {
    output.setRange(bodyOffset, bodyOffset + 12, sparseXyzBytes, point * 12);
    output.setRange(bodyOffset + 12, bodyOffset + 15, sparseRgb, point * 3);
    bodyOffset += _vertexStride;
  }
  for (final birth in births) {
    if (birth.cloud.xyz.length != birth.cloud.rgb.length ||
        birth.cloud.xyz.length % 3 != 0 ||
        birth.cloud.xyz.any((value) => !value.isFinite)) {
      throw StateError('structural birth cloud is malformed');
    }
    final xyzBytes = birth.cloud.xyz.buffer.asUint8List(
      birth.cloud.xyz.offsetInBytes,
      birth.cloud.xyz.lengthInBytes,
    );
    for (var point = 0; point < birth.cloud.pointCount; point++) {
      output.setRange(bodyOffset, bodyOffset + 12, xyzBytes, point * 12);
      output.setRange(
        bodyOffset + 12,
        bodyOffset + 15,
        birth.cloud.rgb,
        point * 3,
      );
      bodyOffset += _vertexStride;
    }
  }
  if (bodyOffset != output.length) {
    throw StateError('PLY encoder did not fill the exact output buffer');
  }
  return output;
}

int _plyBodyOffset(Uint8List ply) {
  final marker = utf8.encode('end_header\n');
  for (var offset = 0; offset <= ply.length - marker.length; offset++) {
    var matches = true;
    for (var index = 0; index < marker.length; index++) {
      if (ply[offset + index] != marker[index]) {
        matches = false;
        break;
      }
    }
    if (matches) return offset + marker.length;
  }
  throw FormatException('PLY end_header marker is absent');
}

({
  bool sparseXyzExact,
  bool sparseRgbExact,
  bool birthXyzExact,
  bool birthRgbExact,
  int uniqueColours,
  int nonGrayPoints,
})
_verifyPly({
  required Uint8List ply,
  required Uint8List sparseXyzBytes,
  required Uint8List sparseRgb,
  required List<BcdStructuralBirthResult> births,
}) {
  final bodyOffset = _plyBodyOffset(ply);
  final originalPoints = sparseRgb.length ~/ 3;
  final totalPoints = originalPoints + _pointCount(births);
  if (ply.length - bodyOffset != totalPoints * _vertexStride) {
    throw StateError('PLY body length does not match its full point count');
  }
  var sparseXyzExact = true;
  var sparseRgbExact = true;
  for (var point = 0; point < originalPoints; point++) {
    final target = bodyOffset + point * _vertexStride;
    for (var byte = 0; byte < 12; byte++) {
      sparseXyzExact =
          sparseXyzExact &&
          ply[target + byte] == sparseXyzBytes[point * 12 + byte];
    }
    for (var byte = 0; byte < 3; byte++) {
      sparseRgbExact =
          sparseRgbExact &&
          ply[target + 12 + byte] == sparseRgb[point * 3 + byte];
    }
  }
  var birthXyzExact = true;
  var birthRgbExact = true;
  var outputPoint = originalPoints;
  for (final birth in births) {
    final xyzBytes = birth.cloud.xyz.buffer.asUint8List(
      birth.cloud.xyz.offsetInBytes,
      birth.cloud.xyz.lengthInBytes,
    );
    for (var point = 0; point < birth.cloud.pointCount; point++) {
      final target = bodyOffset + outputPoint * _vertexStride;
      for (var byte = 0; byte < 12; byte++) {
        birthXyzExact =
            birthXyzExact && ply[target + byte] == xyzBytes[point * 12 + byte];
      }
      for (var byte = 0; byte < 3; byte++) {
        birthRgbExact =
            birthRgbExact &&
            ply[target + 12 + byte] == birth.cloud.rgb[point * 3 + byte];
      }
      outputPoint++;
    }
  }
  final colours = <int>{};
  var nonGrayPoints = 0;
  for (var point = 0; point < totalPoints; point++) {
    final offset = bodyOffset + point * _vertexStride + 12;
    final red = ply[offset];
    final green = ply[offset + 1];
    final blue = ply[offset + 2];
    colours.add((red << 16) | (green << 8) | blue);
    if (red != green || green != blue) nonGrayPoints++;
  }
  if (!sparseXyzExact ||
      !sparseRgbExact ||
      !birthXyzExact ||
      !birthRgbExact ||
      colours.length < 2 ||
      nonGrayPoints == 0) {
    throw StateError('true-colour PLY exact-copy verification failed');
  }
  return (
    sparseXyzExact: sparseXyzExact,
    sparseRgbExact: sparseRgbExact,
    birthXyzExact: birthXyzExact,
    birthRgbExact: birthRgbExact,
    uniqueColours: colours.length,
    nonGrayPoints: nonGrayPoints,
  );
}

void _writeAtomically(String path, Uint8List bytes) {
  final output = File(path)..parent.createSync(recursive: true);
  final temporary = File('$path.tmp.$pid');
  try {
    temporary.writeAsBytesSync(bytes, flush: true);
    temporary.renameSync(output.path);
  } finally {
    if (temporary.existsSync()) temporary.deleteSync();
  }
}

void main(List<String> args) {
  if (args.length != 3) {
    stderr.writeln(
      'usage: dart run tool/bcd_compare_ply_export.dart '
      'MANIFEST CAPTURE OUTPUT.ply',
    );
    exitCode = 64;
    return;
  }
  final manifestBytes = _readBytes(args[0]);
  final manifest = jsonDecode(utf8.decode(manifestBytes)) as Map;
  final scene = (manifest['scenes'] as List).cast<Map>().firstWhere(
    (row) => row['capture'] == args[1],
    orElse: () => throw StateError('capture absent from manifest: ${args[1]}'),
  );
  final sparseXyzBytes = _readBytes(scene['sparse_xyz_f32'] as String);
  final sparseXyz = _float32FromLittleEndian(sparseXyzBytes);
  final sparseRgb = _validateAndReadRgb(
    scene: scene,
    sparseXyzBytes: sparseXyzBytes,
  );
  final views = <BcdPlaneSweepView>[
    for (final raw in (scene['views'] as List).cast<Map>())
      BcdPlaneSweepView(
        jpegPath: raw['jpeg_path'] as String,
        projection3x4: Float64List.fromList(
          (raw['projection_3x4'] as List)
              .cast<num>()
              .map((value) => value.toDouble())
              .toList(),
        ),
        cameraCenter: Float64List.fromList(
          (raw['camera_center'] as List)
              .cast<num>()
              .map((value) => value.toDouble())
              .toList(),
        ),
        width: raw['width'] as int,
        height: raw['height'] as int,
      ),
  ];
  final rawKnownFloor = scene['known_floor'];
  final knownFloor = rawKnownFloor is Map
      ? BcdKnownFloorPlane.fromSignedDistanceMetadata(
          normal: (rawKnownFloor['plane_n'] as List)
              .cast<num>()
              .map((value) => value.toDouble())
              .toList(),
          rawPlaneD: (rawKnownFloor['plane_d'] as num).toDouble(),
          sparseXyz: sparseXyz,
        )
      : null;
  final stopwatch = Stopwatch()..start();
  final result = const BcdStructuralQualityRunner().run(
    sparseXyz: sparseXyz,
    registeredViews: views,
    knownFloorPlane: knownFloor,
    onProgress: (stage, completed, total) => stdout.writeln(
      'BCD_EXPORT_PROGRESS capture=${args[1]} stage=$stage '
      '$completed/$total elapsed_ms=${stopwatch.elapsedMilliseconds}',
    ),
  );
  stopwatch.stop();
  final floorBirths = _pointCount(result.floorBirths);
  final wallBirths = _pointCount(result.wallBirths);
  final structuralBirths = _pointCount(result.structuralBirths);
  final expected = scene['expected'] as Map;
  final expectedExact =
      result.qualityPassed &&
      result.certifiedWalls.isNotEmpty &&
      result.floorDecision.winnerProposalIndex ==
          expected['floor_winner_proposal_index'] &&
      _sameStringSet(
        expected['wall_selected_candidate_ids'],
        result.wallDecision?.selectedCandidateIds ?? const <String>[],
      ) &&
      floorBirths == expected['floor_births'] &&
      wallBirths == expected['wall_births'] &&
      structuralBirths == expected['structural_birth_points'];
  if (!expectedExact) {
    throw StateError('B/C result differs from the frozen quality contract');
  }
  final ply = _encodePly(
    capture: args[1],
    sparseXyzBytes: sparseXyzBytes,
    sparseRgb: sparseRgb,
    births: result.structuralBirths,
  );
  _writeAtomically(args[2], ply);
  final persisted = _readBytes(args[2]);
  final verification = _verifyPly(
    ply: persisted,
    sparseXyzBytes: sparseXyzBytes,
    sparseRgb: sparseRgb,
    births: result.structuralBirths,
  );
  final output = <String, Object?>{
    'schema': 'pocketworld_truecolor_bc_compare_export_v1',
    'capture': args[1],
    'manifest_sha256': _sha256Bytes(manifestBytes),
    'metric_npz': (scene['sparse_xyz_source'] as Map)['path'],
    'output_ply': File(args[2]).absolute.path,
    'output_bytes': persisted.length,
    'output_sha256': _sha256Bytes(persisted),
    'format': 'binary_little_endian',
    'original_sparse_points': sparseXyz.length ~/ 3,
    'floor_birth_points': floorBirths,
    'wall_birth_points': wallBirths,
    'structural_birth_points': structuralBirths,
    'total_points': sparseXyz.length ~/ 3 + structuralBirths,
    'certified_wall_count': result.certifiedWalls.length,
    'quality_passed': result.qualityPassed,
    'expected_contract_exact': expectedExact,
    'sparse_prefix_xyz_exact': verification.sparseXyzExact,
    'sparse_prefix_rgb_exact': verification.sparseRgbExact,
    'structural_birth_xyz_exact': verification.birthXyzExact,
    'structural_birth_rgb_exact': verification.birthRgbExact,
    'rgb_bytes_present': (sparseXyz.length ~/ 3 + structuralBirths) * 3,
    'unique_rgb_colours': verification.uniqueColours,
    'non_gray_points': verification.nonGrayPoints,
    'pseudocolor_applied': false,
    'rgb_provenance': {
      'sparse': 'immutable_metric_npz_rgb_copy',
      'structural': 'native_jpeg_readback_rgb_copy',
    },
    'elapsed_ms': stopwatch.elapsedMilliseconds,
  };
  final metadataPath = args[2].endsWith('.ply')
      ? '${args[2].substring(0, args[2].length - 4)}.json'
      : '${args[2]}.json';
  _writeAtomically(
    metadataPath,
    Uint8List.fromList(
      utf8.encode('${const JsonEncoder.withIndent('  ').convert(output)}\n'),
    ),
  );
  stdout.writeln('BCD_EXPORT_RESULT=${jsonEncode(output)}');
}
