import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_codec.dart';
import 'package:pocketworld_flutter/official_capture/database_archive_policy.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_codec.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_coordinator.dart';
import 'package:pocketworld_flutter/official_capture/photo_archive_policy.dart';

void main() {
  late Directory documentsDir;

  setUp(() async {
    documentsDir = await Directory.systemTemp.createTemp(
      'pw_db_archive_coordinator_',
    );
  });

  tearDown(() async {
    if (await documentsDir.exists()) {
      await documentsDir.delete(recursive: true);
    }
  });

  Future<Directory> createReadyCapture(
    String name, {
    required bool photoMarked,
    required bool databaseMarked,
  }) async {
    final capture = Directory('${documentsDir.path}/captures_official/$name');
    final highres = Directory('${capture.path}/photos_highres');
    await highres.create(recursive: true);
    if (photoMarked) {
      await PhotoArchivePolicy.writeForNewCapture(capture);
    }
    if (databaseMarked) {
      await DatabaseArchivePolicy.writeForNewCapture(capture);
    }
    await File(
      '${highres.path}/frame.jpg',
    ).writeAsBytes(List<int>.filled(8192, 17), flush: true);
    await File('${capture.path}/official_photo_bundle.json').writeAsString(
      jsonEncode(<String, Object?>{
        'schemaVersion': 'aether_photo_bundle_v1',
        'photosHighresDir': 'photos_highres',
        'frames': <Object?>[
          <String, Object?>{'highresFilename': 'frame.jpg'},
        ],
      }),
      flush: true,
    );
    await File(
      '${capture.path}/official_sfm_sparse.ply',
    ).writeAsBytes(<int>[1], flush: true);
    await File(
      '${capture.path}/official_sfm_sparse_meta.json',
    ).writeAsString('{"n_points":1}', flush: true);
    await File(
      '${capture.path}/${DatabaseArchivePolicy.sourceFileName}',
    ).writeAsBytes(List<int>.filled(8192, 23), flush: true);
    return capture;
  }

  test('photo-only historical marker never archives the database', () async {
    final capture = await createReadyCapture(
      'photo-only',
      photoMarked: true,
      databaseMarked: false,
    );
    final databaseCodec = _RecordingDatabaseCodec();
    final coordinator = PhotoArchiveCoordinator(
      codec: _ZlibPhotoCodec(),
      databaseCodec: databaseCodec,
    );

    await coordinator.discoverUnderDocuments(documentsDir);

    expect(databaseCodec.compressCalls, 0);
    expect(
      await File(
        '${capture.path}/${DatabaseArchivePolicy.sourceFileName}',
      ).exists(),
      isTrue,
    );
    expect(
      await File(
        '${capture.path}/${DatabaseArchivePolicy.sourceFileName}.zpaq',
      ).exists(),
      isFalse,
    );
  });

  test('database transaction runs after photo archive work', () async {
    final capture = await createReadyCapture(
      'ordered',
      photoMarked: true,
      databaseMarked: true,
    );
    final order = <String>[];
    final coordinator = PhotoArchiveCoordinator(
      codec: _ZlibPhotoCodec(onEncode: () => order.add('photo')),
      databaseCodec: _RecordingDatabaseCodec(
        onCompress: () => order.add('database'),
      ),
    );

    await coordinator.noteArtifactsPersisted(capture);

    expect(order, <String>['photo', 'database']);
  });

  test(
    'foreground activity requests cancellation and waits for idle',
    () async {
      final capture = await createReadyCapture(
        'cancel',
        photoMarked: false,
        databaseMarked: true,
      );
      final databaseCodec = _BlockingDatabaseCodec();
      final coordinator = PhotoArchiveCoordinator(
        codec: _ZlibPhotoCodec(),
        databaseCodec: databaseCodec,
      );

      final archiveFuture = coordinator.noteArtifactsPersisted(capture);
      await databaseCodec.started.future;
      final lease = coordinator.beginCaptureActivity();
      await coordinator.waitForIdle();
      await archiveFuture;

      expect(databaseCodec.cancellationRequests, 1);
      expect(
        await File(
          '${capture.path}/${DatabaseArchivePolicy.sourceFileName}',
        ).exists(),
        isTrue,
      );

      await lease.close();

      expect(databaseCodec.compressCalls, 2);
      expect(
        await File(
          '${capture.path}/${DatabaseArchivePolicy.sourceFileName}.zpaq',
        ).exists(),
        isTrue,
      );
    },
  );

  test('startup discovers an independent database marker', () async {
    final capture = await createReadyCapture(
      'database-only',
      photoMarked: false,
      databaseMarked: true,
    );
    final coordinator = PhotoArchiveCoordinator(
      codec: _ZlibPhotoCodec(),
      databaseCodec: _RecordingDatabaseCodec(),
    );

    await coordinator.discoverUnderDocuments(documentsDir);

    expect(
      await File(
        '${capture.path}/${DatabaseArchivePolicy.sourceFileName}',
      ).exists(),
      isFalse,
    );
    expect(
      await File(
        '${capture.path}/${DatabaseArchivePolicy.sourceFileName}.zpaq',
      ).exists(),
      isTrue,
    );
  });
}

class _ZlibPhotoCodec implements PhotoArchiveCodec {
  _ZlibPhotoCodec({this.onEncode});

  final void Function()? onEncode;

  @override
  bool get isSupported => true;

  @override
  Future<void> encodeJpeg({
    required File sourceJpeg,
    required File destinationJxl,
  }) async {
    onEncode?.call();
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
    await destinationJpeg.writeAsBytes(
      ZLibCodec().decode(await sourceJxl.readAsBytes()),
      flush: true,
    );
  }
}

class _RecordingDatabaseCodec implements DatabaseArchiveCodec {
  _RecordingDatabaseCodec({this.onCompress});

  final void Function()? onCompress;
  int compressCalls = 0;

  @override
  bool get isSupported => true;

  @override
  Future<void> compress({
    required File sourceDatabase,
    required File destinationArchive,
  }) async {
    compressCalls++;
    onCompress?.call();
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

class _BlockingDatabaseCodec extends _RecordingDatabaseCodec {
  final Completer<void> started = Completer<void>();
  final Completer<void> _cancelled = Completer<void>();
  int cancellationRequests = 0;

  @override
  Future<void> compress({
    required File sourceDatabase,
    required File destinationArchive,
  }) async {
    compressCalls++;
    if (compressCalls == 1) {
      started.complete();
      await _cancelled.future;
      throw const DatabaseArchiveCancelled();
    }
    await destinationArchive.writeAsBytes(
      ZLibCodec().encode(await sourceDatabase.readAsBytes()),
      flush: true,
    );
  }

  @override
  void requestCancellation() {
    cancellationRequests++;
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}
