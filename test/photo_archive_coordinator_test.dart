import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/archive_audit_store.dart';
import 'package:pocketworld_flutter/official_capture/archive_background_scheduler.dart';
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

  test(
    'production gate remains active until every pipeline lease closes',
    () async {
      final capture = await createCompleteCapture('multi-lease', marked: true);
      final coordinator = PhotoArchiveCoordinator(
        codec: _ZlibCoordinatorCodec(),
      );

      final recording = coordinator.beginCaptureActivity();
      final reconstruction = coordinator.beginReconstructionActivity(capture);

      expect(coordinator.isProductionPipelineActive, isTrue);
      expect(coordinator.activeProductionPipelineCount, 2);

      await recording.close();
      expect(coordinator.isProductionPipelineActive, isTrue);
      expect(coordinator.activeProductionPipelineCount, 1);

      await reconstruction.close();
      expect(coordinator.isProductionPipelineActive, isFalse);
      expect(coordinator.activeProductionPipelineCount, 0);
    },
  );

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

  test('schedules durable background work and cancels after drain', () async {
    final capture = await createCompleteCapture('scheduled', marked: true);
    final scheduler = _RecordingArchiveBackgroundScheduler();
    final coordinator = PhotoArchiveCoordinator(
      codec: _ZlibCoordinatorCodec(),
      backgroundScheduler: scheduler,
    );

    await coordinator.noteArtifactsPersisted(capture);

    expect(scheduler.scheduleCount, 1);
    expect(scheduler.cancelCount, 1);
    expect(coordinator.hasPendingWork, isFalse);
    expect(
      await File('${capture.path}/photos_highres/frame.jpg').exists(),
      isFalse,
    );
  });

  test('system interruption pauses after one file and later resumes', () async {
    final capture = await createCompleteCapture(
      'background-expired',
      marked: true,
      photos: const ['one.jpg', 'two.jpg'],
    );
    final scheduler = _RecordingArchiveBackgroundScheduler();
    late PhotoArchiveCoordinator coordinator;
    var encodeCount = 0;
    final codec = _ZlibCoordinatorCodec(
      afterEncode: () {
        encodeCount++;
        if (encodeCount == 1) {
          coordinator.requestSystemInterruption();
        }
      },
    );
    coordinator = PhotoArchiveCoordinator(
      codec: codec,
      backgroundScheduler: scheduler,
    );

    await coordinator.noteArtifactsPersisted(capture);

    final first = File('${capture.path}/photos_highres/one.jpg');
    final second = File('${capture.path}/photos_highres/two.jpg');
    expect(await first.exists(), isFalse);
    expect(await second.exists(), isTrue);
    expect(coordinator.hasPendingWork, isTrue);
    expect(encodeCount, 1);

    await coordinator.discoverUnderDocuments(documentsDir);

    expect(await second.exists(), isFalse);
    expect(encodeCount, 2);
    expect(coordinator.hasPendingWork, isFalse);
    expect(
      ZLibCodec().decode(await File('${first.path}.jxl').readAsBytes()),
      List<int>.filled(8192, 1),
    );
    expect(
      ZLibCodec().decode(await File('${second.path}.jxl').readAsBytes()),
      List<int>.filled(8192, 2),
    );
  });

  test('failed work stops current pump and retries later', () async {
    final capture = await createCompleteCapture('retry', marked: true);
    final scheduler = _RecordingArchiveBackgroundScheduler();
    final codec = _FailOnceCoordinatorCodec();
    final coordinator = PhotoArchiveCoordinator(
      codec: codec,
      backgroundScheduler: scheduler,
    );

    await coordinator.noteArtifactsPersisted(capture);

    final source = File('${capture.path}/photos_highres/frame.jpg');
    expect(await source.exists(), isTrue);
    expect(await File('${source.path}.jxl').exists(), isFalse);
    expect(codec.encodeCount, 1);
    expect(coordinator.hasPendingWork, isTrue);

    await coordinator.discoverUnderDocuments(documentsDir);

    expect(codec.encodeCount, 2);
    expect(await source.exists(), isFalse);
    expect(await File('${source.path}.jxl').exists(), isTrue);
    expect(coordinator.hasPendingWork, isFalse);
  });

  test('records enqueue capture result and queue drain audit events', () async {
    final capture = await createCompleteCapture('audited', marked: true);
    final auditStore = OfficialArchiveAuditStore(
      documentsDirectory: () async => documentsDir,
    );
    final coordinator = PhotoArchiveCoordinator(
      codec: _ZlibCoordinatorCodec(),
      auditStore: auditStore,
    );

    await coordinator.noteArtifactsPersisted(capture);

    final rows = await File(
      '${documentsDir.path}/official_archive_audit.jsonl',
    ).readAsLines();
    final events = rows
        .map((row) => jsonDecode(row) as Map<String, Object?>)
        .toList(growable: false);
    expect(
      events.map((event) => event['event']),
      containsAllInOrder(const <String>[
        'capture_enqueued',
        'capture_started',
        'capture_completed',
        'queue_drained',
      ]),
    );
    final completed = events.firstWhere(
      (event) => event['event'] == 'capture_completed',
    );
    expect(completed['capture_id'], 'audited');
    expect(completed['details'], containsPair('photos_archived', 1));
    expect(completed['details'], containsPair('work_remaining', false));
  });

  test('audit storage failure never blocks a verified archive', () async {
    final capture = await createCompleteCapture(
      'audit-unavailable',
      marked: true,
    );
    final auditStore = OfficialArchiveAuditStore(
      documentsDirectory: () async =>
          throw const FileSystemException('audit unavailable'),
    );
    final coordinator = PhotoArchiveCoordinator(
      codec: _ZlibCoordinatorCodec(),
      auditStore: auditStore,
    );

    await coordinator.noteArtifactsPersisted(capture);

    final source = File('${capture.path}/photos_highres/frame.jpg');
    expect(await source.exists(), isFalse);
    expect(await File('${source.path}.jxl').exists(), isTrue);
    expect(coordinator.hasPendingWork, isFalse);
  });
}

class _RecordingArchiveBackgroundScheduler
    implements ArchiveBackgroundScheduler {
  int scheduleCount = 0;
  int cancelCount = 0;

  @override
  Future<void> cancelScheduled() async {
    cancelCount++;
  }

  @override
  Future<void> schedule() async {
    scheduleCount++;
  }
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

class _FailOnceCoordinatorCodec implements PhotoArchiveCodec {
  int encodeCount = 0;

  @override
  bool get isSupported => true;

  @override
  Future<void> encodeJpeg({
    required File sourceJpeg,
    required File destinationJxl,
  }) async {
    encodeCount++;
    if (encodeCount == 1) {
      throw const FileSystemException('intentional first encode failure');
    }
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
