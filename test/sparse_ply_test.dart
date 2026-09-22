import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/sfm_live_recon.dart';
import 'package:pocketworld_flutter/capture/sparse_ply.dart';

void main() {
  late Directory captureDir;

  setUp(() async {
    captureDir = await Directory.systemTemp.createTemp('sparse-ply-');
  });

  tearDown(() async {
    if (await captureDir.exists()) {
      await captureDir.delete(recursive: true);
    }
  });

  test('publishes a flushed, self-consistent PLY and metadata pair', () async {
    final receipt = await persistSparseSnapshot(
      captureDir: captureDir.path,
      snapshot: _snapshot(refined: false),
      rgb: Uint8List.fromList(<int>[10, 20, 30, 40, 50, 60]),
    );

    final ply = File('${captureDir.path}/sfm_sparse.ply');
    final meta = File('${captureDir.path}/sfm_sparse_meta.json');
    expect(await ply.exists(), isTrue);
    expect(await meta.exists(), isTrue);
    final decoded =
        jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
    expect(decoded['schema'], 'pw_sfm_sparse_meta_v1');
    expect(decoded['n_points'], 2);
    expect(decoded['refined'], isFalse);
    expect(decoded['ply_bytes'], await ply.length());
    expect(decoded['ply_sha256'], hasLength(64));
    expect(decoded['artifact_id'], isNotEmpty);
    final marker =
        jsonDecode(
              await File(
                '${captureDir.path}/sfm_sparse_commit.json',
              ).readAsString(),
            )
            as Map<String, dynamic>;
    expect(marker['artifact_id'], receipt.artifactId);
    final verified = await verifyPersistedSparseSnapshot(
      captureDir: captureDir.path,
      expectedReceipt: receipt,
    );
    expect(verified.plySha256, receipt.plySha256);
    expect(_transactionFiles(captureDir), isEmpty);
  });

  test(
    'verification compares every field of the caller write receipt',
    () async {
      final receipt = await persistSparseSnapshot(
        captureDir: captureDir.path,
        snapshot: _snapshot(refined: true),
        rgb: Uint8List(6),
      );
      final wrongPlyHash = SparsePersistReceipt(
        artifactId: receipt.artifactId,
        pointCount: receipt.pointCount,
        refined: receipt.refined,
        plyBytes: receipt.plyBytes,
        plySha256: _flipHex(receipt.plySha256),
        metaBytes: receipt.metaBytes,
        metaSha256: receipt.metaSha256,
      );
      final wrongMetaHash = SparsePersistReceipt(
        artifactId: receipt.artifactId,
        pointCount: receipt.pointCount,
        refined: receipt.refined,
        plyBytes: receipt.plyBytes,
        plySha256: receipt.plySha256,
        metaBytes: receipt.metaBytes,
        metaSha256: _flipHex(receipt.metaSha256),
      );

      for (final forged in <SparsePersistReceipt>[
        wrongPlyHash,
        wrongMetaHash,
      ]) {
        await expectLater(
          verifyPersistedSparseSnapshot(
            captureDir: captureDir.path,
            expectedReceipt: forged,
          ),
          throwsA(isA<StateError>()),
        );
      }
    },
  );

  test('same-length PLY tamper cannot satisfy the original receipt', () async {
    final receipt = await persistSparseSnapshot(
      captureDir: captureDir.path,
      snapshot: _snapshot(refined: true),
      rgb: Uint8List(6),
    );
    final ply = File('${captureDir.path}/sfm_sparse.ply');
    final bytes = await ply.readAsBytes();
    bytes[bytes.length - 1] ^= 1;
    await ply.writeAsBytes(bytes, flush: true);

    await expectLater(
      verifyPersistedSparseSnapshot(
        captureDir: captureDir.path,
        expectedReceipt: receipt,
      ),
      throwsA(isA<StateError>()),
    );
    expect(await ply.length(), receipt.plyBytes);
  });

  test(
    'same-length metadata tamper cannot satisfy the original receipt',
    () async {
      final receipt = await persistSparseSnapshot(
        captureDir: captureDir.path,
        snapshot: _snapshot(refined: true),
        rgb: Uint8List(6),
      );
      final meta = File('${captureDir.path}/sfm_sparse_meta.json');
      final bytes = await meta.readAsBytes();
      final marker = utf8.encode('"result":"OK"');
      final offset = _findBytes(bytes, marker);
      expect(offset, isNonNegative);
      bytes[offset + marker.length - 2] = 'X'.codeUnitAt(0);
      await meta.writeAsBytes(bytes, flush: true);

      await expectLater(
        verifyPersistedSparseSnapshot(
          captureDir: captureDir.path,
          expectedReceipt: receipt,
        ),
        throwsA(isA<StateError>()),
      );
      expect(await meta.length(), receipt.metaBytes);
    },
  );

  test('receipt from another capture cannot authorize this artifact', () async {
    final receipt = await persistSparseSnapshot(
      captureDir: captureDir.path,
      snapshot: _snapshot(refined: true),
      rgb: Uint8List(6),
    );
    final other = await Directory.systemTemp.createTemp('sparse-ply-other-');
    try {
      final otherReceipt = await persistSparseSnapshot(
        captureDir: other.path,
        snapshot: _snapshot(refined: true, xOffset: 100),
        rgb: Uint8List(6),
      );
      expect(otherReceipt.artifactId, isNot(receipt.artifactId));
      await expectLater(
        verifyPersistedSparseSnapshot(
          captureDir: captureDir.path,
          expectedReceipt: otherReceipt,
        ),
        throwsA(isA<StateError>()),
      );
    } finally {
      await other.delete(recursive: true);
    }
  });

  test('write failure is observable and leaves no final artifact', () async {
    final notDirectory = File('${captureDir.path}/not-a-directory');
    await notDirectory.writeAsString('sentinel', flush: true);

    await expectLater(
      persistSparseSnapshot(
        captureDir: notDirectory.path,
        snapshot: _snapshot(refined: true),
        rgb: Uint8List(6),
      ),
      throwsA(isA<FileSystemException>()),
    );

    expect(await notDirectory.readAsString(), 'sentinel');
    expect(File('${notDirectory.path}/sfm_sparse.ply').existsSync(), isFalse);
    expect(
      File('${notDirectory.path}/sfm_sparse_meta.json').existsSync(),
      isFalse,
    );
  });

  test(
    'partial pre-existing artifact is rejected without overwriting it',
    () async {
      final ply = File('${captureDir.path}/sfm_sparse.ply');
      await ply.writeAsString('original-partial', flush: true);

      await expectLater(
        persistSparseSnapshot(
          captureDir: captureDir.path,
          snapshot: _snapshot(refined: true),
          rgb: Uint8List(6),
        ),
        throwsA(isA<StateError>()),
      );

      expect(await ply.readAsString(), 'original-partial');
      expect(
        File('${captureDir.path}/sfm_sparse_meta.json').existsSync(),
        isFalse,
      );
      expect(_transactionFiles(captureDir), isEmpty);
    },
  );

  test(
    'metadata mismatch blocks refinement and preserves the old pair',
    () async {
      final ply = File('${captureDir.path}/sfm_sparse.ply');
      final meta = File('${captureDir.path}/sfm_sparse_meta.json');
      await persistSparseSnapshot(
        captureDir: captureDir.path,
        snapshot: _snapshot(refined: false),
        rgb: Uint8List(6),
      );
      final oldPly = await ply.readAsBytes();
      final decoded =
          jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
      // Keep artifact id/count/PLY hash intact: the commit marker must still
      // detect tampering in poses/summary metadata bytes themselves.
      decoded['summary'] = <String, Object?>{'result': 'tampered'};
      final badMeta = jsonEncode(decoded);
      await meta.writeAsString(badMeta, flush: true);

      await expectLater(
        persistSparseSnapshot(
          captureDir: captureDir.path,
          snapshot: _snapshot(refined: true),
          rgb: Uint8List(6),
        ),
        throwsA(isA<StateError>()),
      );

      expect(await ply.readAsBytes(), oldPly);
      expect(await meta.readAsString(), badMeta);
    },
  );

  test('only an unrefined valid pair may be replaced by refinement', () async {
    await persistSparseSnapshot(
      captureDir: captureDir.path,
      snapshot: _snapshot(refined: false),
      rgb: Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6]),
    );
    final oldPly = await File(
      '${captureDir.path}/sfm_sparse.ply',
    ).readAsBytes();

    await persistSparseSnapshot(
      captureDir: captureDir.path,
      snapshot: _snapshot(refined: true, xOffset: 10),
      rgb: Uint8List.fromList(<int>[6, 5, 4, 3, 2, 1]),
    );

    final ply = File('${captureDir.path}/sfm_sparse.ply');
    final meta = File('${captureDir.path}/sfm_sparse_meta.json');
    expect(await ply.readAsBytes(), isNot(oldPly));
    final decoded =
        jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
    expect(decoded['refined'], isTrue);

    final refinedPly = await ply.readAsBytes();
    final refinedMeta = await meta.readAsString();
    await expectLater(
      persistSparseSnapshot(
        captureDir: captureDir.path,
        snapshot: _snapshot(refined: true, xOffset: 20),
        rgb: Uint8List(6),
      ),
      throwsA(isA<StateError>()),
    );
    expect(await ply.readAsBytes(), refinedPly);
    expect(await meta.readAsString(), refinedMeta);

    final regenerated = await persistSparseSnapshot(
      captureDir: captureDir.path,
      snapshot: _snapshot(refined: true, xOffset: 20),
      rgb: Uint8List(6),
      allowRefinedReplacement: true,
    );
    expect(regenerated.refined, isTrue);
    expect(regenerated.artifactId, isNot(decoded['artifact_id']));
  });

  test('commit marker recovers a crash between the two path renames', () async {
    final receipt = await persistSparseSnapshot(
      captureDir: captureDir.path,
      snapshot: _snapshot(refined: false),
      rgb: Uint8List(6),
    );
    final ply = File('${captureDir.path}/sfm_sparse.ply');
    final meta = File('${captureDir.path}/sfm_sparse_meta.json');
    final oldPly = await ply.readAsBytes();
    final oldMeta = await meta.readAsString();
    await ply.rename('${captureDir.path}/.sfm_sparse_previous.ply');
    await meta.rename('${captureDir.path}/.sfm_sparse_previous_meta.json');
    await ply.writeAsString('partial-new-generation', flush: true);
    await File('${captureDir.path}/.sfm_sparse_transaction.json').writeAsString(
      jsonEncode(<String, Object?>{
        'schema': 'pw_sfm_sparse_transaction_v1',
        'new_artifact_id': 'interrupted-new-id',
        'had_previous': true,
        'previous_artifact_id': receipt.artifactId,
      }),
      flush: true,
    );

    final recovered = await recoverSparsePublication(
      captureDir: captureDir.path,
    );

    expect(recovered?.artifactId, receipt.artifactId);
    expect(await ply.readAsBytes(), oldPly);
    expect(await meta.readAsString(), oldMeta);
    expect(_transactionFiles(captureDir), isEmpty);
  });

  test('commit marker recovers when only the old PLY rename landed', () async {
    final receipt = await persistSparseSnapshot(
      captureDir: captureDir.path,
      snapshot: _snapshot(refined: false),
      rgb: Uint8List(6),
    );
    final ply = File('${captureDir.path}/sfm_sparse.ply');
    final meta = File('${captureDir.path}/sfm_sparse_meta.json');
    final oldPly = await ply.readAsBytes();
    final oldMeta = await meta.readAsString();
    await ply.rename('${captureDir.path}/.sfm_sparse_previous.ply');
    await File('${captureDir.path}/.sfm_sparse_transaction.json').writeAsString(
      jsonEncode(<String, Object?>{
        'schema': 'pw_sfm_sparse_transaction_v1',
        'new_artifact_id': 'interrupted-before-meta-rename',
        'had_previous': true,
        'previous_artifact_id': receipt.artifactId,
      }),
      flush: true,
    );

    final recovered = await recoverSparsePublication(
      captureDir: captureDir.path,
    );

    expect(recovered?.artifactId, receipt.artifactId);
    expect(await ply.readAsBytes(), oldPly);
    expect(await meta.readAsString(), oldMeta);
    expect(_transactionFiles(captureDir), isEmpty);
  });

  test('discard invalid publication cannot delete a valid commit', () async {
    await persistSparseSnapshot(
      captureDir: captureDir.path,
      snapshot: _snapshot(refined: true),
      rgb: Uint8List(6),
    );
    await expectLater(
      discardInvalidSparsePublication(captureDir: captureDir.path),
      throwsA(isA<StateError>()),
    );
    expect(File('${captureDir.path}/sfm_sparse.ply').existsSync(), isTrue);
    expect(
      File('${captureDir.path}/sfm_sparse_commit.json').existsSync(),
      isTrue,
    );
  });

  test('discard invalid publication removes only sparse retry state', () async {
    final photo = File('${captureDir.path}/user-photo.jpg');
    final gray = File('${captureDir.path}/replay.gray');
    await photo.writeAsBytes(<int>[1, 2, 3], flush: true);
    await gray.writeAsBytes(<int>[4, 5, 6], flush: true);
    await File(
      '${captureDir.path}/sfm_sparse.ply',
    ).writeAsString('partial', flush: true);

    await discardInvalidSparsePublication(captureDir: captureDir.path);

    expect(File('${captureDir.path}/sfm_sparse.ply').existsSync(), isFalse);
    expect(await photo.readAsBytes(), <int>[1, 2, 3]);
    expect(await gray.readAsBytes(), <int>[4, 5, 6]);
  });

  test(
    'recovery queues behind an in-flight publication for the same capture',
    () async {
      final publishing = persistSparseSnapshot(
        captureDir: captureDir.path,
        snapshot: _snapshot(refined: true),
        rgb: Uint8List(6),
      );
      // The lock is registered synchronously, before the writer's first await.
      final recovering = recoverSparsePublication(captureDir: captureDir.path);

      final receipt = await publishing;
      final recovered = await recovering;

      expect(recovered?.artifactId, receipt.artifactId);
      expect(recovered?.metaSha256, receipt.metaSha256);
      expect(_transactionFiles(captureDir), isEmpty);
    },
  );

  test('new linked pair without commit marker is never promoted', () async {
    await persistSparseSnapshot(
      captureDir: captureDir.path,
      snapshot: _snapshot(refined: true),
      rgb: Uint8List(6),
    );
    await File('${captureDir.path}/sfm_sparse_commit.json').delete();

    await expectLater(
      recoverSparsePublication(captureDir: captureDir.path),
      throwsA(isA<StateError>()),
    );
  });

  test(
    'structurally valid PLY-only legacy artifact remains viewable',
    () async {
      await persistSparseSnapshot(
        captureDir: captureDir.path,
        snapshot: _snapshot(refined: true),
        rgb: Uint8List(6),
      );
      await File('${captureDir.path}/sfm_sparse_meta.json').delete();
      await File('${captureDir.path}/sfm_sparse_commit.json').delete();

      final inspection = await inspectSparsePublicationForViewing(
        captureDir: captureDir.path,
      );

      expect(inspection.state, SparsePublicationViewState.legacyPlyOnly);
      expect(inspection.pointCount, 2);
      expect(inspection.receipt, isNull);
    },
  );

  test('legacy pre-marker pair is pinned once without rewriting it', () async {
    await persistSparseSnapshot(
      captureDir: captureDir.path,
      snapshot: _snapshot(refined: false),
      rgb: Uint8List(6),
    );
    final ply = File('${captureDir.path}/sfm_sparse.ply');
    final meta = File('${captureDir.path}/sfm_sparse_meta.json');
    final bytes = await ply.readAsBytes();
    final headerEnd = _findBytes(bytes, utf8.encode('end_header\n')) + 11;
    final header = utf8.decode(bytes.sublist(0, headerEnd));
    final legacyHeader = header.replaceFirst(
      RegExp(r'comment artifact_id [^\n]+\n'),
      '',
    );
    await ply.writeAsBytes(<int>[
      ...utf8.encode(legacyHeader),
      ...bytes.sublist(headerEnd),
    ], flush: true);
    final decoded =
        jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
    decoded.remove('artifact_id');
    decoded.remove('ply_bytes');
    decoded.remove('ply_sha256');
    decoded.remove('vertex_stride');
    await meta.writeAsString(jsonEncode(decoded), flush: true);
    await File('${captureDir.path}/sfm_sparse_commit.json').delete();

    final recovered = await recoverSparsePublication(
      captureDir: captureDir.path,
    );

    expect(recovered?.artifactId, startsWith('legacy-'));
    expect(recovered?.pointCount, 2);
    expect(
      File('${captureDir.path}/sfm_sparse_commit.json').existsSync(),
      isTrue,
    );
  });

  test('invalid buffers fail before any file is created', () async {
    await expectLater(
      persistSparseSnapshot(
        captureDir: captureDir.path,
        snapshot: SfmLiveSnapshot(
          xyz: Float32List.fromList(<double>[1, 2, double.nan]),
          rgb: Uint8List(3),
          posesPacked: Float64List(0),
          summary: const <String, dynamic>{},
          refined: true,
          obsOffsets: Int32List(0),
          obsFrameIds: Int32List(0),
          obsXY: Float32List(0),
        ),
        rgb: Uint8List(3),
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(captureDir.listSync(), isEmpty);
  });
}

Iterable<FileSystemEntity> _transactionFiles(Directory directory) => directory
    .listSync()
    .where((entry) => entry.uri.pathSegments.last.startsWith('.sfm_sparse_'));

int _findBytes(List<int> haystack, List<int> needle) {
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var matches = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matches = false;
        break;
      }
    }
    if (matches) return i;
  }
  return -1;
}

String _flipHex(String value) =>
    '${value[0] == '0' ? '1' : '0'}${value.substring(1)}';

SfmLiveSnapshot _snapshot({required bool refined, double xOffset = 0}) =>
    SfmLiveSnapshot(
      xyz: Float32List.fromList(<double>[1 + xOffset, 2, 3, 4 + xOffset, 5, 6]),
      rgb: Uint8List(6),
      posesPacked: Float64List.fromList(<double>[
        7,
        1,
        1,
        0,
        0,
        0,
        0.1,
        0.2,
        0.3,
      ]),
      summary: const <String, dynamic>{'result': 'OK'},
      refined: refined,
      obsOffsets: Int32List.fromList(<int>[0, 2, 4]),
      obsFrameIds: Int32List.fromList(<int>[7, 8, 7, 9]),
      obsXY: Float32List(8),
    );
