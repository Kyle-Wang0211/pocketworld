import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_codec.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_policy.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_resolver.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_transaction.dart';

void main() {
  late Directory captureDir;
  late _ZlibResolverCodec codec;

  setUp(() async {
    captureDir = await Directory.systemTemp.createTemp(
      'pw_db_archive_resolver_',
    );
    codec = _ZlibResolverCodec();
  });

  tearDown(() async {
    if (await captureDir.exists()) {
      await captureDir.delete(recursive: true);
    }
  });

  Future<void> createArchiveOnlyFixture(List<int> original) async {
    await DatabaseArchivePolicy.writeForNewCapture(captureDir);
    await File(
      '${captureDir.path}/official_sfm_sparse.ply',
    ).writeAsBytes(<int>[1], flush: true);
    await File(
      '${captureDir.path}/official_sfm_sparse_meta.json',
    ).writeAsString('{"n_points":1}', flush: true);
    final raw = File(
      '${captureDir.path}/${DatabaseArchivePolicy.sourceFileName}',
    );
    await raw.writeAsBytes(original, flush: true);
    final result = await DatabaseArchiveTransaction(
      codec: codec,
    ).archiveCapture(captureDir);
    expect(result.archived, isTrue);
    expect(await raw.exists(), isFalse);
  }

  test('raw historical database is recoverable without a marker', () async {
    final raw = File(
      '${captureDir.path}/${DatabaseArchivePolicy.sourceFileName}',
    );
    await raw.writeAsBytes(<int>[1, 2, 3], flush: true);
    final resolver = DatabaseArchiveResolver(codec: codec);

    expect(await resolver.isRecoverable(captureDir), isTrue);
    expect((await resolver.resolveDatabase(captureDir))?.path, raw.path);
  });

  test('valid archive-only project restores exact raw bytes', () async {
    final original = List<int>.filled(8192, 31);
    await createArchiveOnlyFixture(original);
    final resolver = DatabaseArchiveResolver(codec: codec);

    expect(await resolver.isRecoverable(captureDir), isTrue);
    final restored = await resolver.resolveDatabase(captureDir);

    expect(restored, isNotNull);
    expect(await restored!.readAsBytes(), original);
    expect(await File('${restored.path}.zpaq').exists(), isTrue);
    expect(await File('${restored.path}.verify.tmp').exists(), isFalse);
  });

  test('corrupt archive is neither recoverable nor materialized', () async {
    await createArchiveOnlyFixture(List<int>.filled(8192, 32));
    final archive = File(
      '${captureDir.path}/${DatabaseArchivePolicy.sourceFileName}.zpaq',
    );
    final bytes = await archive.readAsBytes();
    bytes[bytes.length - 1] ^= 1;
    await archive.writeAsBytes(bytes, flush: true);
    final resolver = DatabaseArchiveResolver(codec: codec);

    expect(await resolver.isRecoverable(captureDir), isFalse);
    expect(await resolver.resolveDatabase(captureDir), isNull);
    expect(
      await File(
        '${captureDir.path}/${DatabaseArchivePolicy.sourceFileName}',
      ).exists(),
      isFalse,
    );
  });

  test('wrong decompressed SHA leaves no raw or temporary database', () async {
    await createArchiveOnlyFixture(List<int>.filled(8192, 33));
    final resolver = DatabaseArchiveResolver(
      codec: _MismatchingResolverCodec(),
    );
    final raw = File(
      '${captureDir.path}/${DatabaseArchivePolicy.sourceFileName}',
    );

    expect(await resolver.isRecoverable(captureDir), isTrue);
    expect(await resolver.resolveDatabase(captureDir), isNull);
    expect(await raw.exists(), isFalse);
    expect(await File('${raw.path}.verify.tmp').exists(), isFalse);
  });

  test(
    'unsupported platform preserves a valid archive without restoring',
    () async {
      await createArchiveOnlyFixture(List<int>.filled(8192, 34));
      final resolver = DatabaseArchiveResolver(
        codec: _UnsupportedResolverCodec(),
      );

      expect(await resolver.isRecoverable(captureDir), isFalse);
      expect(await resolver.resolveDatabase(captureDir), isNull);
      expect(
        await File(
          '${captureDir.path}/${DatabaseArchivePolicy.sourceFileName}.zpaq',
        ).exists(),
        isTrue,
      );
    },
  );
}

class _ZlibResolverCodec implements DatabaseArchiveCodec {
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

class _MismatchingResolverCodec extends _ZlibResolverCodec {
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

class _UnsupportedResolverCodec extends _ZlibResolverCodec {
  @override
  bool get isSupported => false;
}
