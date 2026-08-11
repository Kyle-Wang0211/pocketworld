import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_codec.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_manifest.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_resolver.dart';

void main() {
  late Directory tempDir;
  late Directory captureDir;
  late Directory highresDir;
  late Directory cacheDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('pw_archive_resolver_');
    captureDir = Directory('${tempDir.path}/capture');
    highresDir = Directory('${captureDir.path}/photos_highres');
    cacheDir = Directory('${tempDir.path}/cache');
    await highresDir.create(recursive: true);
    await cacheDir.create();
    await File('${captureDir.path}/official_photo_bundle.json').writeAsString(
      jsonEncode({
        'schemaVersion': 'aether_photo_bundle_v1',
        'photosHighresDir': 'photos_highres',
        'frames': [
          {'highresFilename': 'frame.jpg'},
        ],
      }),
    );
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  test('returns canonical source without invoking codec', () async {
    final source = File('${highresDir.path}/frame.jpg');
    await source.writeAsBytes([1, 2, 3]);
    final codec = _CountingZlibCodec();

    final resolved = await PhotoArchiveResolver(codec: codec).resolveJpeg(
      captureDirectory: captureDir,
      highresFilename: 'frame.jpg',
      cacheDirectory: cacheDir,
    );

    expect(resolved?.path, source.path);
    expect(codec.reconstructCalls, 0);
  });

  test('materializes and verifies exact JPEG from committed archive', () async {
    final original = List<int>.filled(4096, 11);
    final source = File('${highresDir.path}/frame.jpg');
    await source.writeAsBytes(original);
    final archive = File('${source.path}.jxl');
    final codec = _CountingZlibCodec();
    await codec.encodeJpeg(sourceJpeg: source, destinationJxl: archive);
    final sourceDigest = sha256.convert(original).toString();
    final archiveBytes = await archive.readAsBytes();
    final manifest = PhotoArchiveManifest(
      entries: {
        'frame.jpg': PhotoArchiveEntry(
          sourceRelativePath: 'photos_highres/frame.jpg',
          sourceBytes: original.length,
          sourceSha256: sourceDigest,
          archiveRelativePath: 'photos_highres/frame.jpg.jxl',
          archiveBytes: archiveBytes.length,
          archiveSha256: sha256.convert(archiveBytes).toString(),
          status: PhotoArchiveEntryStatus.verified,
          verifiedAt: DateTime.now().toUtc().toIso8601String(),
        ),
      },
    );
    await manifest.writeAtomic(captureDir);
    await source.delete();

    final resolved = await PhotoArchiveResolver(codec: codec).resolveJpeg(
      captureDirectory: captureDir,
      highresFilename: 'frame.jpg',
      cacheDirectory: cacheDir,
    );

    expect(resolved, isNotNull);
    expect(await resolved!.readAsBytes(), original);
    expect(codec.reconstructCalls, 1);

    final second = await PhotoArchiveResolver(codec: codec).resolveJpeg(
      captureDirectory: captureDir,
      highresFilename: 'frame.jpg',
      cacheDirectory: cacheDir,
    );
    expect(second?.path, resolved.path);
    expect(codec.reconstructCalls, 1);
  });

  test('corrupt archive and unsafe request fail closed', () async {
    final archive = File('${highresDir.path}/frame.jpg.jxl');
    await archive.writeAsBytes([99, 98, 97]);
    final manifest = PhotoArchiveManifest(
      entries: {
        'frame.jpg': PhotoArchiveEntry(
          sourceRelativePath: 'photos_highres/frame.jpg',
          sourceBytes: 3,
          sourceSha256: sha256.convert([1, 2, 3]).toString(),
          archiveRelativePath: 'photos_highres/frame.jpg.jxl',
          archiveBytes: 3,
          archiveSha256: sha256.convert([0, 0, 0]).toString(),
          status: PhotoArchiveEntryStatus.verified,
          verifiedAt: DateTime.now().toUtc().toIso8601String(),
        ),
      },
    );
    await manifest.writeAtomic(captureDir);
    final codec = _CountingZlibCodec();
    final resolver = PhotoArchiveResolver(codec: codec);

    expect(
      await resolver.resolveJpeg(
        captureDirectory: captureDir,
        highresFilename: 'frame.jpg',
        cacheDirectory: cacheDir,
      ),
      isNull,
    );
    expect(
      await resolver.resolveJpeg(
        captureDirectory: captureDir,
        highresFilename: '../frame.jpg',
        cacheDirectory: cacheDir,
      ),
      isNull,
    );
    expect(codec.reconstructCalls, 0);
    expect(await cacheDir.list().isEmpty, isTrue);
  });
}

class _CountingZlibCodec implements PhotoArchiveCodec {
  int reconstructCalls = 0;

  @override
  bool get isSupported => true;

  @override
  Future<void> encodeJpeg({
    required File sourceJpeg,
    required File destinationJxl,
  }) async {
    await destinationJxl.writeAsBytes(
      ZLibCodec().encode(await sourceJpeg.readAsBytes()),
      flush: true,
    );
  }

  @override
  Future<void> reconstructJpeg({
    required File sourceJxl,
    required File destinationJpeg,
  }) async {
    reconstructCalls++;
    await destinationJpeg.writeAsBytes(
      ZLibCodec().decode(await sourceJxl.readAsBytes()),
      flush: true,
    );
  }

  @override
  void requestCancellation() {}
}
