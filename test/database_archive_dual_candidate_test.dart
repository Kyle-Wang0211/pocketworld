import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_codec.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_manifest.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_policy.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_preprocessor.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_resolver.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_transaction.dart';

void main() {
  late Directory captureDirectory;

  setUp(() async {
    captureDirectory = await Directory.systemTemp.createTemp(
      'pw_db_dual_candidate_',
    );
  });

  tearDown(() async {
    if (await captureDirectory.exists()) {
      await captureDirectory.delete(recursive: true);
    }
  });

  Future<File> writeReadyDatabase(List<int> bytes) async {
    await DatabaseArchivePolicy.writeForNewCapture(captureDirectory);
    await File(
      '${captureDirectory.path}/official_sfm_sparse.ply',
    ).writeAsBytes(<int>[1], flush: true);
    await File(
      '${captureDirectory.path}/official_sfm_sparse_meta.json',
    ).writeAsString('{"n_points":1}', flush: true);
    final source = File(
      '${captureDirectory.path}/${DatabaseArchivePolicy.sourceFileName}',
    );
    await source.writeAsBytes(bytes, flush: true);
    return source;
  }

  test(
    'publishes the smaller independently verified track candidate',
    () async {
      final original = List<int>.filled(8192, 0x11);
      final source = await writeReadyDatabase(original);
      final codec = _SizedExactCodec(rawPadding: 200, trackPadding: 20);
      final preprocessor = _XorPreprocessor();

      final result = await DatabaseArchiveTransaction(
        codec: codec,
        preprocessor: preprocessor,
      ).archiveCapture(captureDirectory);

      expect(result.archived, isTrue);
      expect(await source.exists(), isFalse);
      final manifest = await DatabaseArchiveManifest.read(captureDirectory);
      expect(manifest?.preprocess, DatabaseArchivePreprocess.trackDeltaV1);
      expect(manifest?.rawArchiveBytes, isNotNull);
      expect(manifest?.trackArchiveBytes, isNotNull);
      expect(manifest!.trackArchiveBytes!, lessThan(manifest.rawArchiveBytes!));
      expect(manifest.archiveBytes, manifest.trackArchiveBytes);
      expect(preprocessor.forwardCalls, 1);
      expect(preprocessor.inverseCalls, 1);
      expect(await File('${source.path}.raw.zpaq.tmp').exists(), isFalse);
      expect(await File('${source.path}.track.db.tmp').exists(), isFalse);
      expect(await File('${source.path}.track.zpaq.tmp').exists(), isFalse);
    },
  );

  test(
    'raw wins an exact size tie without requiring track restoration',
    () async {
      final original = List<int>.filled(8192, 0x11);
      await writeReadyDatabase(original);
      final preprocessor = _XorPreprocessor();

      final result = await DatabaseArchiveTransaction(
        codec: _SizedExactCodec(rawPadding: 40, trackPadding: 40),
        preprocessor: preprocessor,
      ).archiveCapture(captureDirectory);

      expect(result.archived, isTrue);
      final manifest = await DatabaseArchiveManifest.read(captureDirectory);
      expect(manifest?.preprocess, DatabaseArchivePreprocess.rawV1);
      expect(manifest?.rawArchiveBytes, manifest?.trackArchiveBytes);
    },
  );

  test('track failure falls back to verified raw candidate', () async {
    final original = List<int>.filled(8192, 0x11);
    await writeReadyDatabase(original);

    final result = await DatabaseArchiveTransaction(
      codec: _SizedExactCodec(rawPadding: 40, trackPadding: 10),
      preprocessor: _FailingPreprocessor(),
    ).archiveCapture(captureDirectory);

    expect(result.archived, isTrue);
    final manifest = await DatabaseArchiveManifest.read(captureDirectory);
    expect(manifest?.preprocess, DatabaseArchivePreprocess.rawV1);
    expect(manifest?.rawArchiveBytes, manifest?.archiveBytes);
    expect(manifest?.trackArchiveBytes, isNull);
  });

  test(
    'inexact track inverse is rejected even when its archive is smaller',
    () async {
      final original = List<int>.filled(8192, 0x11);
      await writeReadyDatabase(original);

      final result = await DatabaseArchiveTransaction(
        codec: _SizedExactCodec(rawPadding: 200, trackPadding: 10),
        preprocessor: _InexactInversePreprocessor(),
      ).archiveCapture(captureDirectory);

      expect(result.archived, isTrue);
      final manifest = await DatabaseArchiveManifest.read(captureDirectory);
      expect(manifest?.preprocess, DatabaseArchivePreprocess.rawV1);
      expect(manifest?.trackArchiveBytes, isNull);
    },
  );

  test(
    'resolver inverse-transforms track archive before publishing source',
    () async {
      final original = List<int>.filled(8192, 0x11);
      final source = await writeReadyDatabase(original);
      final codec = _SizedExactCodec(rawPadding: 200, trackPadding: 20);
      final preprocessor = _XorPreprocessor();
      final archived = await DatabaseArchiveTransaction(
        codec: codec,
        preprocessor: preprocessor,
      ).archiveCapture(captureDirectory);
      expect(archived.archived, isTrue);
      expect(await source.exists(), isFalse);

      final resolved = await DatabaseArchiveResolver(
        codec: codec,
        preprocessor: preprocessor,
      ).resolveDatabase(captureDirectory);

      expect(resolved, isNotNull);
      expect(await resolved!.readAsBytes(), original);
      expect(preprocessor.inverseCalls, 2);
      expect(await File('${source.path}.preprocessed.tmp').exists(), isFalse);
    },
  );

  test('legacy v1 manifest is read as raw preprocessing', () async {
    await File(
      '${captureDirectory.path}/${DatabaseArchiveManifest.fileName}',
    ).writeAsString(
      jsonEncode(<String, Object?>{
        'schema': DatabaseArchiveManifest.schemaV1,
        'source_file': DatabaseArchivePolicy.sourceFileName,
        'archive_file': DatabaseArchiveManifest.archiveFileName,
        'codec': DatabaseArchivePolicy.codecName,
        'version': DatabaseArchivePolicy.version715,
        'revision': DatabaseArchivePolicy.pinnedRevision,
        'method': DatabaseArchivePolicy.method5,
        'source_bytes': 10,
        'source_sha256': 'a' * 64,
        'archive_bytes': 5,
        'archive_sha256': 'b' * 64,
        'verified_at': '2026-08-01T00:00:00.000Z',
      }),
      flush: true,
    );

    final manifest = await DatabaseArchiveManifest.read(captureDirectory);

    expect(manifest, isNotNull);
    expect(manifest?.preprocess, DatabaseArchivePreprocess.rawV1);
    expect(manifest?.rawArchiveBytes, 5);
    expect(manifest?.trackArchiveBytes, isNull);
  });
}

class _XorPreprocessor implements DatabaseArchivePreprocessor {
  int forwardCalls = 0;
  int inverseCalls = 0;

  @override
  bool get isSupported => true;

  @override
  Future<void> transformTrackDelta({
    required File sourceDatabase,
    required File destinationDatabase,
  }) async {
    forwardCalls++;
    await _xor(sourceDatabase, destinationDatabase);
  }

  @override
  Future<void> restoreTrackDelta({
    required File sourceDatabase,
    required File destinationDatabase,
  }) async {
    inverseCalls++;
    await _xor(sourceDatabase, destinationDatabase);
  }

  Future<void> _xor(File source, File destination) async {
    final bytes = await source.readAsBytes();
    for (var index = 0; index < bytes.length; index++) {
      bytes[index] ^= 0xff;
    }
    await destination.writeAsBytes(bytes, flush: true);
  }

  @override
  void requestCancellation() {}
}

class _FailingPreprocessor extends _XorPreprocessor {
  @override
  Future<void> transformTrackDelta({
    required File sourceDatabase,
    required File destinationDatabase,
  }) {
    throw const FileSystemException('simulated transform failure');
  }
}

class _InexactInversePreprocessor extends _XorPreprocessor {
  @override
  Future<void> restoreTrackDelta({
    required File sourceDatabase,
    required File destinationDatabase,
  }) async {
    inverseCalls++;
    await destinationDatabase.writeAsBytes(
      await sourceDatabase.readAsBytes(),
      flush: true,
    );
  }
}

class _SizedExactCodec implements DatabaseArchiveCodec {
  _SizedExactCodec({required this.rawPadding, required this.trackPadding});

  final int rawPadding;
  final int trackPadding;

  @override
  bool get isSupported => true;

  @override
  Future<void> compress({
    required File sourceDatabase,
    required File destinationArchive,
  }) async {
    final source = await sourceDatabase.readAsBytes();
    final compressed = ZLibCodec(level: 9).encode(source);
    final padding = source.first == 0x11 ? rawPadding : trackPadding;
    final header = ByteData(4)..setUint32(0, compressed.length);
    await destinationArchive.writeAsBytes(<int>[
      ...header.buffer.asUint8List(),
      ...compressed,
      ...List<int>.filled(padding, 0),
    ], flush: true);
  }

  @override
  Future<void> decompress({
    required File sourceArchive,
    required File destinationDatabase,
  }) async {
    final archive = await sourceArchive.readAsBytes();
    final compressedLength = ByteData.sublistView(archive).getUint32(0);
    await destinationDatabase.writeAsBytes(
      ZLibCodec().decode(archive.sublist(4, 4 + compressedLength)),
      flush: true,
    );
  }

  @override
  void requestCancellation() {}
}
