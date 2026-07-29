import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_codec.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_manifest.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_policy.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_transaction.dart';

void main() {
  late Directory captureDir;

  setUp(() async {
    captureDir = await Directory.systemTemp.createTemp('pw_db_archive_tx_');
  });

  tearDown(() async {
    if (await captureDir.exists()) {
      await captureDir.delete(recursive: true);
    }
  });

  Future<File> writeReadyDatabase(List<int> bytes) async {
    await DatabaseArchivePolicy.writeForNewCapture(captureDir);
    await File(
      '${captureDir.path}/official_sfm_sparse.ply',
    ).writeAsBytes(<int>[1], flush: true);
    await File(
      '${captureDir.path}/official_sfm_sparse_meta.json',
    ).writeAsString('{"n_points":1}', flush: true);
    final source = File(
      '${captureDir.path}/${DatabaseArchivePolicy.sourceFileName}',
    );
    await source.writeAsBytes(bytes, flush: true);
    return source;
  }

  test('commits smaller exact archive before deleting source', () async {
    final original = Uint8List.fromList(List<int>.filled(8192, 42));
    final source = await writeReadyDatabase(original);
    final codec = _ZlibTestDatabaseCodec();

    final result = await DatabaseArchiveTransaction(
      codec: codec,
    ).archiveCapture(captureDir);

    expect(result.archived, isTrue);
    expect(result.failed, isFalse);
    expect(await source.exists(), isFalse);
    final archive = File('${source.path}.zpaq');
    expect(await archive.exists(), isTrue);
    expect(await archive.length(), lessThan(original.length));
    final reconstructed = File('${captureDir.path}/roundtrip.db');
    await codec.decompress(
      sourceArchive: archive,
      destinationDatabase: reconstructed,
    );
    expect(await reconstructed.readAsBytes(), original);
    final manifest = await DatabaseArchiveManifest.read(captureDir);
    expect(manifest?.sourceBytes, original.length);
    expect(manifest?.archiveBytes, await archive.length());
    expect(manifest?.sourceSha256, hasLength(64));
    expect(manifest?.archiveSha256, hasLength(64));
  });

  test('byte mismatch retains source and publishes no manifest', () async {
    final original = List<int>.filled(4096, 7);
    final source = await writeReadyDatabase(original);

    final result = await DatabaseArchiveTransaction(
      codec: _MismatchingDatabaseCodec(),
    ).archiveCapture(captureDir);

    expect(result.failed, isTrue);
    expect(await source.readAsBytes(), original);
    expect(await File('${source.path}.zpaq').exists(), isFalse);
    expect(await File('${source.path}.zpaq.tmp').exists(), isFalse);
    expect(await File('${source.path}.verify.tmp').exists(), isFalse);
    expect(await DatabaseArchiveManifest.read(captureDir), isNull);
  });

  test('codec failure retains source and remains retryable', () async {
    final original = List<int>.filled(4096, 8);
    final source = await writeReadyDatabase(original);

    final result = await DatabaseArchiveTransaction(
      codec: _FailingDatabaseCodec(),
    ).archiveCapture(captureDir);

    expect(result.failed, isTrue);
    expect(await source.readAsBytes(), original);
    expect(await File('${source.path}.zpaq').exists(), isFalse);

    final retried = await DatabaseArchiveTransaction(
      codec: _ZlibTestDatabaseCodec(),
    ).archiveCapture(captureDir);
    expect(retried.archived, isTrue);
  });

  test('non-smaller exact archive keeps the database', () async {
    final original = List<int>.generate(256, (index) => index);
    final source = await writeReadyDatabase(original);

    final result = await DatabaseArchiveTransaction(
      codec: _LargerExactDatabaseCodec(),
    ).archiveCapture(captureDir);

    expect(result.skipped, isTrue);
    expect(await source.readAsBytes(), original);
    expect(await File('${source.path}.zpaq').exists(), isFalse);
    expect(await DatabaseArchiveManifest.read(captureDir), isNull);
  });

  for (final suffix in const <String>['-wal', '-shm', '-journal']) {
    test(
      'SQLite $suffix sidecar postpones archive without codec work',
      () async {
        final source = await writeReadyDatabase(List<int>.filled(4096, 9));
        await File('${source.path}$suffix').writeAsBytes(<int>[1], flush: true);
        final codec = _CountingDatabaseCodec();

        final result = await DatabaseArchiveTransaction(
          codec: codec,
        ).archiveCapture(captureDir);

        expect(result.skipped, isTrue);
        expect(codec.compressCalls, 0);
        expect(await source.exists(), isTrue);
      },
    );
  }

  test('closed continuation gate retains source without codec work', () async {
    final source = await writeReadyDatabase(List<int>.filled(4096, 10));
    final codec = _CountingDatabaseCodec();

    final result = await DatabaseArchiveTransaction(
      codec: codec,
      canContinue: () => false,
    ).archiveCapture(captureDir);

    expect(result.interrupted, isTrue);
    expect(codec.compressCalls, 0);
    expect(await source.exists(), isTrue);
    expect(await DatabaseArchiveManifest.read(captureDir), isNull);
  });

  test(
    'native cancellation retains source and is reported interrupted',
    () async {
      final source = await writeReadyDatabase(List<int>.filled(4096, 11));

      final result = await DatabaseArchiveTransaction(
        codec: _CancelledDatabaseCodec(),
      ).archiveCapture(captureDir);

      expect(result.interrupted, isTrue);
      expect(result.failed, isFalse);
      expect(await source.exists(), isTrue);
      expect(await File('${source.path}.zpaq.tmp').exists(), isFalse);
    },
  );

  test('restart reconciles crash after manifest commit', () async {
    final original = List<int>.filled(8192, 12);
    final source = await writeReadyDatabase(original);

    final first = await DatabaseArchiveTransaction(
      codec: _ZlibTestDatabaseCodec(),
      afterManifestCommitted: (_) async {
        throw StateError('simulated process stop');
      },
    ).archiveCapture(captureDir);

    expect(first.failed, isTrue);
    expect(await source.readAsBytes(), original);
    expect(await File('${source.path}.zpaq').exists(), isTrue);
    expect(await DatabaseArchiveManifest.read(captureDir), isNotNull);

    final second = await DatabaseArchiveTransaction(
      codec: _ZlibTestDatabaseCodec(),
    ).archiveCapture(captureDir);

    expect(second.archived, isTrue);
    expect(await source.exists(), isFalse);
  });

  test('changed restored database replaces stale archive safely', () async {
    final source = await writeReadyDatabase(List<int>.filled(8192, 13));
    final codec = _ZlibTestDatabaseCodec();
    final first = await DatabaseArchiveTransaction(
      codec: codec,
    ).archiveCapture(captureDir);
    expect(first.archived, isTrue);

    await codec.decompress(
      sourceArchive: File('${source.path}.zpaq'),
      destinationDatabase: source,
    );
    final changed = List<int>.filled(8192, 14);
    await source.writeAsBytes(changed, flush: true);

    final second = await DatabaseArchiveTransaction(
      codec: codec,
    ).archiveCapture(captureDir);

    expect(second.archived, isTrue);
    expect(await source.exists(), isFalse);
    final restored = File('${captureDir.path}/changed-restored.db');
    await codec.decompress(
      sourceArchive: File('${source.path}.zpaq'),
      destinationDatabase: restored,
    );
    expect(await restored.readAsBytes(), changed);
  });

  test('missing final artifact keeps marked database unchanged', () async {
    final source = await writeReadyDatabase(List<int>.filled(4096, 15));
    await File('${captureDir.path}/official_sfm_sparse_meta.json').delete();
    final codec = _CountingDatabaseCodec();

    final result = await DatabaseArchiveTransaction(
      codec: codec,
    ).archiveCapture(captureDir);

    expect(result.skipped, isTrue);
    expect(codec.compressCalls, 0);
    expect(await source.exists(), isTrue);
  });
}

class _ZlibTestDatabaseCodec implements DatabaseArchiveCodec {
  @override
  bool get isSupported => true;

  @override
  Future<void> compress({
    required File sourceDatabase,
    required File destinationArchive,
  }) async {
    await destinationArchive.writeAsBytes(
      ZLibCodec().encode(await sourceDatabase.readAsBytes()),
      flush: true,
    );
  }

  @override
  Future<void> decompress({
    required File sourceArchive,
    required File destinationDatabase,
  }) async {
    await destinationDatabase.writeAsBytes(
      ZLibCodec().decode(await sourceArchive.readAsBytes()),
      flush: true,
    );
  }

  @override
  void requestCancellation() {}
}

class _MismatchingDatabaseCodec extends _ZlibTestDatabaseCodec {
  @override
  Future<void> decompress({
    required File sourceArchive,
    required File destinationDatabase,
  }) async {
    await super.decompress(
      sourceArchive: sourceArchive,
      destinationDatabase: destinationDatabase,
    );
    final bytes = await destinationDatabase.readAsBytes();
    bytes[bytes.length - 1] ^= 1;
    await destinationDatabase.writeAsBytes(bytes, flush: true);
  }
}

class _FailingDatabaseCodec extends _ZlibTestDatabaseCodec {
  @override
  Future<void> compress({
    required File sourceDatabase,
    required File destinationArchive,
  }) {
    throw const FileSystemException('simulated codec failure');
  }
}

class _CancelledDatabaseCodec extends _ZlibTestDatabaseCodec {
  @override
  Future<void> compress({
    required File sourceDatabase,
    required File destinationArchive,
  }) {
    throw const DatabaseArchiveCancelled();
  }
}

class _LargerExactDatabaseCodec implements DatabaseArchiveCodec {
  @override
  bool get isSupported => true;

  @override
  Future<void> compress({
    required File sourceDatabase,
    required File destinationArchive,
  }) async {
    await destinationArchive.writeAsBytes(<int>[
      0,
      ...await sourceDatabase.readAsBytes(),
    ], flush: true);
  }

  @override
  Future<void> decompress({
    required File sourceArchive,
    required File destinationDatabase,
  }) async {
    final archive = await sourceArchive.readAsBytes();
    await destinationDatabase.writeAsBytes(archive.sublist(1), flush: true);
  }

  @override
  void requestCancellation() {}
}

class _CountingDatabaseCodec extends _ZlibTestDatabaseCodec {
  int compressCalls = 0;

  @override
  Future<void> compress({
    required File sourceDatabase,
    required File destinationArchive,
  }) {
    compressCalls++;
    return super.compress(
      sourceDatabase: sourceDatabase,
      destinationArchive: destinationArchive,
    );
  }
}
