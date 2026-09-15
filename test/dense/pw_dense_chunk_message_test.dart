// pw_dense_chunk_message_test.dart — the worker isolate sends chunks and progress over ONE port, so the decode
// must be exact: a chunk message round-trips its bytes, and anything else (progress, junk) decodes to null and
// is left to the progress path.
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/dense/pw_dense_ffi.dart';

Object _chunkMessage(int frameIndex, List<double> xyz, List<int> rgb) => <Object>[
      'chunk',
      frameIndex,
      TransferableTypedData.fromList(<TypedData>[Float32List.fromList(xyz)]),
      TransferableTypedData.fromList(<TypedData>[Uint8List.fromList(rgb)]),
    ];

void main() {
  test('a chunk message round-trips frame index, xyz and rgb', () {
    final c = decodePwDenseChunkMessage(_chunkMessage(
      12,
      <double>[1, 2, 3, -4, 5.5, 6],
      <int>[10, 20, 30, 40, 50, 60],
    ))!;
    expect(c.frameIndex, 12);
    expect(c.pointCount, 2);
    expect(c.xyz, Float32List.fromList(<double>[1, 2, 3, -4, 5.5, 6]));
    expect(c.rgb, Uint8List.fromList(<int>[10, 20, 30, 40, 50, 60]));
  });

  test('an empty chunk decodes to zero points, not to null', () {
    final c = decodePwDenseChunkMessage(_chunkMessage(0, const <double>[], const <int>[]))!;
    expect(c.pointCount, 0);
    expect(c.xyz, isEmpty);
    expect(c.rgb, isEmpty);
  });

  test('progress messages and junk are not chunks', () {
    expect(decodePwDenseChunkMessage(<Object>['fuse', 3, 12]), isNull); // the existing [phase, done, total]
    expect(decodePwDenseChunkMessage(<Object>['chunk', 1, 2]), isNull); // wrong arity
    expect(decodePwDenseChunkMessage(<Object>['chunk', 1, 2, 3]), isNull); // payloads not transferable
    expect(decodePwDenseChunkMessage(<Object>['done', 0, 0, 0]), isNull); // right arity, wrong tag
    expect(decodePwDenseChunkMessage('chunk'), isNull);
    expect(decodePwDenseChunkMessage(null), isNull);
  });
}
