import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_codec.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_manifest.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_policy.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_transaction.dart';

void main() {
  late Directory captureDir;
  late Directory highresDir;

  setUp(() async {
    captureDir = await Directory.systemTemp.createTemp('pw_archive_tx_');
    highresDir = Directory('${captureDir.path}/photos_highres');
    await highresDir.create(recursive: true);
    await PhotoArchivePolicy.writeForNewCapture(captureDir);
  });

  tearDown(() async {
    if (await captureDir.exists()) {
      await captureDir.delete(recursive: true);
    }
  });

  Future<void> writeBundle(List<Object?> frames) {
    return File('${captureDir.path}/official_photo_bundle.json').writeAsString(
      jsonEncode({
        'schemaVersion': 'aether_photo_bundle_v1',
        'photosHighresDir': 'photos_highres',
        'frames': frames,
      }),
      flush: true,
    );
  }

  test('selects only safe manifest-referenced high-resolution JPEGs', () async {
    final outside = File('${captureDir.parent.path}/outside.jpg');
    await outside.writeAsBytes([9, 9, 9]);
    addTearDown(() async {
      if (await outside.exists()) await outside.delete();
    });
    await File(
      '${highresDir.path}/kept.jpg',
    ).writeAsBytes(List<int>.filled(4096, 7));
    await File(
      '${highresDir.path}/orphan.jpg',
    ).writeAsBytes(List<int>.filled(4096, 8));
    await Directory('${captureDir.path}/previews').create();
    await File(
      '${captureDir.path}/previews/preview.jpg',
    ).writeAsBytes(List<int>.filled(4096, 6));
    await writeBundle([
      {'highresFilename': 'kept.jpg', 'previewFilename': 'preview.jpg'},
      {'highresFilename': 'kept.jpg'},
      {'highresFilename': '../outside.jpg'},
      {'highresFilename': '/tmp/absolute.jpg'},
      {'highresFilename': r'nested\escape.jpg'},
      {'highresFilename': 'not-jpeg.png'},
      'not-a-frame',
    ]);

    final candidates = await PhotoArchiveManifest.loadCandidateNames(
      captureDir,
    );

    expect(candidates, ['kept.jpg']);
    expect(await outside.readAsBytes(), [9, 9, 9]);
  });

  test('commits smaller exact archive before deleting source', () async {
    final original = Uint8List.fromList(List<int>.filled(8192, 42));
    final source = File('${highresDir.path}/frame.jpg');
    await source.writeAsBytes(original, flush: true);
    await writeBundle([
      {'highresFilename': 'frame.jpg'},
    ]);
    final codec = _ZlibTestCodec();

    final result = await PhotoArchiveTransaction(
      codec: codec,
    ).archiveCapture(captureDir);

    expect(result.archivedNames, ['frame.jpg']);
    expect(await source.exists(), isFalse);
    final archive = File('${source.path}.jxl');
    expect(await archive.exists(), isTrue);
    expect(await archive.length(), lessThan(original.length));
    final reconstructed = File('${captureDir.path}/roundtrip.jpg');
    await codec.reconstructJpeg(
      sourceJxl: archive,
      destinationJpeg: reconstructed,
    );
    expect(await reconstructed.readAsBytes(), original);

    final manifest = await PhotoArchiveManifest.read(captureDir);
    final entry = manifest!.entries['frame.jpg'];
    expect(entry, isNotNull);
    expect(entry!.status, PhotoArchiveEntryStatus.verified);
    expect(entry.sourceBytes, original.length);
    expect(entry.archiveBytes, await archive.length());
    expect(entry.sourceSha256, isNotEmpty);
    expect(entry.archiveSha256, isNotEmpty);
  });

  test(
    'byte mismatch retains source and publishes no verified entry',
    () async {
      final source = File('${highresDir.path}/mismatch.jpg');
      final original = List<int>.filled(4096, 1);
      await source.writeAsBytes(original);
      await writeBundle([
        {'highresFilename': 'mismatch.jpg'},
      ]);

      final result = await PhotoArchiveTransaction(
        codec: _MismatchTestCodec(),
      ).archiveCapture(captureDir);

      expect(result.failedNames, ['mismatch.jpg']);
      expect(await source.readAsBytes(), original);
      expect(await File('${source.path}.jxl').exists(), isFalse);
      expect(await File('${source.path}.jxl.tmp').exists(), isFalse);
      expect(await File('${source.path}.verify.tmp').exists(), isFalse);
      expect(await PhotoArchiveManifest.read(captureDir), isNull);
    },
  );

  test('codec failure retains source and remains retryable', () async {
    final source = File('${highresDir.path}/failure.jpg');
    final original = List<int>.filled(4096, 3);
    await source.writeAsBytes(original);
    await writeBundle([
      {'highresFilename': 'failure.jpg'},
    ]);

    final result = await PhotoArchiveTransaction(
      codec: _FailingTestCodec(),
    ).archiveCapture(captureDir);

    expect(result.failedNames, ['failure.jpg']);
    expect(await source.readAsBytes(), original);
    expect(await File('${source.path}.jxl').exists(), isFalse);
  });

  test('non-smaller exact archive keeps the JPEG', () async {
    final source = File('${highresDir.path}/larger.jpg');
    final original = List<int>.generate(256, (index) => index);
    await source.writeAsBytes(original);
    await writeBundle([
      {'highresFilename': 'larger.jpg'},
    ]);

    final result = await PhotoArchiveTransaction(
      codec: _LargerExactTestCodec(),
    ).archiveCapture(captureDir);

    expect(result.skippedNames, ['larger.jpg']);
    expect(await source.readAsBytes(), original);
    expect(await File('${source.path}.jxl').exists(), isFalse);
    expect(await PhotoArchiveManifest.read(captureDir), isNull);
  });

  test(
    'restart reconciles crash after manifest commit without data loss',
    () async {
      final source = File('${highresDir.path}/crash.jpg');
      final original = List<int>.filled(8192, 5);
      await source.writeAsBytes(original);
      await writeBundle([
        {'highresFilename': 'crash.jpg'},
      ]);

      final first = await PhotoArchiveTransaction(
        codec: _ZlibTestCodec(),
        afterManifestCommitted: (_) async {
          throw StateError('simulated process stop');
        },
      ).archiveCapture(captureDir);

      expect(first.failedNames, ['crash.jpg']);
      expect(await source.readAsBytes(), original);
      expect(await File('${source.path}.jxl').exists(), isTrue);
      expect(
        (await PhotoArchiveManifest.read(
          captureDir,
        ))!.entries['crash.jpg']!.status,
        PhotoArchiveEntryStatus.verified,
      );

      final second = await PhotoArchiveTransaction(
        codec: _ZlibTestCodec(),
      ).archiveCapture(captureDir);

      expect(second.archivedNames, ['crash.jpg']);
      expect(await source.exists(), isFalse);
      expect(await File('${source.path}.jxl').exists(), isTrue);
    },
  );
}

class _ZlibTestCodec implements PhotoArchiveCodec {
  @override
  bool get isSupported => true;

  @override
  Future<void> encodeJpeg({
    required File sourceJpeg,
    required File destinationJxl,
  }) async {
    final encoded = ZLibCodec().encode(await sourceJpeg.readAsBytes());
    await destinationJxl.writeAsBytes(encoded, flush: true);
  }

  @override
  Future<void> reconstructJpeg({
    required File sourceJxl,
    required File destinationJpeg,
  }) async {
    final decoded = ZLibCodec().decode(await sourceJxl.readAsBytes());
    await destinationJpeg.writeAsBytes(decoded, flush: true);
  }
}

class _MismatchTestCodec extends _ZlibTestCodec {
  @override
  Future<void> reconstructJpeg({
    required File sourceJxl,
    required File destinationJpeg,
  }) async {
    await super.reconstructJpeg(
      sourceJxl: sourceJxl,
      destinationJpeg: destinationJpeg,
    );
    final bytes = await destinationJpeg.readAsBytes();
    bytes[bytes.length - 1] ^= 1;
    await destinationJpeg.writeAsBytes(bytes, flush: true);
  }
}

class _FailingTestCodec extends _ZlibTestCodec {
  @override
  Future<void> encodeJpeg({
    required File sourceJpeg,
    required File destinationJxl,
  }) {
    throw const FileSystemException('simulated codec failure');
  }
}

class _LargerExactTestCodec implements PhotoArchiveCodec {
  @override
  bool get isSupported => true;

  @override
  Future<void> encodeJpeg({
    required File sourceJpeg,
    required File destinationJxl,
  }) async {
    final source = await sourceJpeg.readAsBytes();
    await destinationJxl.writeAsBytes([0, ...source], flush: true);
  }

  @override
  Future<void> reconstructJpeg({
    required File sourceJxl,
    required File destinationJpeg,
  }) async {
    final archive = await sourceJxl.readAsBytes();
    await destinationJpeg.writeAsBytes(archive.sublist(1), flush: true);
  }
}
