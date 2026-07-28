import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_codec.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_coordinator.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_policy.dart';

void main() {
  late Directory documentsDir;

  setUp(() async {
    documentsDir = await Directory.systemTemp.createTemp(
      'pw_archive_coordinator_',
    );
  });

  tearDown(() async {
    if (await documentsDir.exists()) {
      await documentsDir.delete(recursive: true);
    }
  });

  Future<Directory> createCompleteCapture(
    String name, {
    required bool marked,
    List<String> photos = const ['frame.jpg'],
  }) async {
    final capture = Directory('${documentsDir.path}/captures_official/$name');
    final highres = Directory('${capture.path}/photos_highres');
    final previews = Directory('${capture.path}/previews');
    await highres.create(recursive: true);
    await previews.create(recursive: true);
    await File('${previews.path}/preview.jpg').writeAsBytes([7, 8, 9]);
    if (marked) await PhotoArchivePolicy.writeForNewCapture(capture);
    for (var index = 0; index < photos.length; index++) {
      await File(
        '${highres.path}/${photos[index]}',
      ).writeAsBytes(List<int>.filled(8192, index + 1));
    }
    await File('${capture.path}/official_photo_bundle.json').writeAsString(
      jsonEncode({
        'schemaVersion': 'aether_photo_bundle_v1',
        'photosHighresDir': 'photos_highres',
        'frames': [
          for (final photo in photos) {'highresFilename': photo},
        ],
      }),
    );
    await File('${capture.path}/official_sfm_sparse.ply').writeAsBytes([1]);
    await File(
      '${capture.path}/official_sfm_sparse_meta.json',
    ).writeAsString('{"n_points":1}');
    return capture;
  }

  test('waits for reconstruction release after final artifacts', () async {
    final capture = await createCompleteCapture('future', marked: true);
    final coordinator = PhotoArchiveCoordinator(codec: _ZlibCoordinatorCodec());
    final recon = coordinator.beginReconstructionActivity(capture);

    await coordinator.noteArtifactsPersisted(capture);

    final source = File('${capture.path}/photos_highres/frame.jpg');
    expect(await source.exists(), isTrue);
    expect(await File('${source.path}.jxl').exists(), isFalse);

    await recon.close();

    expect(await source.exists(), isFalse);
    expect(await File('${source.path}.jxl').exists(), isTrue);
  });

  test('startup discovery never migrates an unmarked legacy capture', () async {
    final legacy = await createCompleteCapture('legacy', marked: false);
    final future = await createCompleteCapture('future', marked: true);
    final coordinator = PhotoArchiveCoordinator(codec: _ZlibCoordinatorCodec());

    await coordinator.discoverUnderDocuments(documentsDir);

    final legacySource = File('${legacy.path}/photos_highres/frame.jpg');
    final futureSource = File('${future.path}/photos_highres/frame.jpg');
    expect(await legacySource.exists(), isTrue);
    expect(await File('${legacySource.path}.jxl').exists(), isFalse);
    expect(await futureSource.exists(), isFalse);
    expect(await File('${futureSource.path}.jxl').exists(), isTrue);
    expect(await Directory('${legacy.path}/previews').exists(), isTrue);
    expect(await Directory('${future.path}/previews').exists(), isFalse);
  });

  test('foreground activity pauses between individual files', () async {
    final capture = await createCompleteCapture(
      'two-frames',
      marked: true,
      photos: const ['one.jpg', 'two.jpg'],
    );
    late PhotoArchiveCoordinator coordinator;
    PhotoArchiveActivityLease? foreground;
    var encodeCount = 0;
    final codec = _ZlibCoordinatorCodec(
      afterEncode: () {
        encodeCount++;
        if (encodeCount == 1) {
          foreground = coordinator.beginCaptureActivity();
        }
      },
    );
    coordinator = PhotoArchiveCoordinator(codec: codec);

    await coordinator.noteArtifactsPersisted(capture);

    expect(
      await File('${capture.path}/photos_highres/one.jpg').exists(),
      isFalse,
    );
    expect(
      await File('${capture.path}/photos_highres/two.jpg').exists(),
      isTrue,
    );
    expect(encodeCount, 1);

    await foreground!.close();

    expect(
      await File('${capture.path}/photos_highres/two.jpg').exists(),
      isFalse,
    );
    expect(encodeCount, 2);
  });

  test('missing final artifact keeps marked capture pending', () async {
    final capture = await createCompleteCapture('incomplete', marked: true);
    await File('${capture.path}/official_sfm_sparse_meta.json').delete();
    final coordinator = PhotoArchiveCoordinator(codec: _ZlibCoordinatorCodec());

    await coordinator.noteArtifactsPersisted(capture);

    expect(
      await File('${capture.path}/photos_highres/frame.jpg').exists(),
      isTrue,
    );
  });
}

class _ZlibCoordinatorCodec implements PhotoArchiveCodec {
  _ZlibCoordinatorCodec({this.afterEncode});

  final void Function()? afterEncode;

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
    afterEncode?.call();
  }

  @override
  Future<void> reconstructJpeg({
    required File sourceJxl,
    required File destinationJpeg,
  }) async {
    await destinationJpeg.writeAsBytes(
      ZLibCodec().decode(await sourceJxl.readAsBytes()),
      flush: true,
    );
  }
}
