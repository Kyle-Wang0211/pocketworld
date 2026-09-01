import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/accepted_photo_record_store.dart';
import 'package:pocketworld_flutter/official_capture/accepted_photo_transaction.dart';
import 'package:pocketworld_flutter/official_capture/project_photo_album.dart';

void main() {
  late Directory temporaryDirectory;
  late File jpeg;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'accepted-photo-ledger-',
    );
    jpeg = File('${temporaryDirectory.path}/photos_highres/photo.jpg');
    await jpeg.parent.create(recursive: true);
    await jpeg.writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9], flush: true);
  });

  tearDown(() async {
    if (await temporaryDirectory.exists()) {
      await temporaryDirectory.delete(recursive: true);
    }
  });

  test('canonical projection schema names every authoritative consumer', () {
    expect(AcceptedPhotoProjection.values.map((value) => value.name), <String>[
      'album',
      'actualPhotoGate',
      'capture',
      'geometry',
      'coverage',
      'archive',
      'sfmInput',
      'controller',
    ]);
  });

  test(
    'publishes one immutable record with temp flush and atomic rename',
    () async {
      final store = await AcceptedPhotoRecordStore.open(temporaryDirectory);
      final record = _record(jpeg.path);

      final first = await store.publish(record, canPublish: () => true);
      final duplicate = await store.publish(record, canPublish: () => true);

      expect(first.status, AcceptedPhotoPublishStatus.published);
      expect(duplicate.status, AcceptedPhotoPublishStatus.alreadyPublished);
      expect(store.snapshot, <AcceptedPhotoRecord>[record]);
      expect(File(store.recordPath(record.transactionId)).existsSync(), isTrue);
      expect(
        temporaryDirectory
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.tmp')),
        isEmpty,
      );

      final conflicting = record.copyWith(frameId: 'different-frame');
      await expectLater(
        store.publish(conflicting, canPublish: () => true),
        throwsA(isA<AcceptedPhotoRecordConflict>()),
      );
      expect(store.snapshot, <AcceptedPhotoRecord>[record]);
    },
  );

  test(
    'a sealed generation aborts before publication and leaves no record',
    () async {
      final store = await AcceptedPhotoRecordStore.open(temporaryDirectory);
      final record = _record(jpeg.path);

      final result = await store.publish(record, canPublish: () => false);

      expect(result.status, AcceptedPhotoPublishStatus.aborted);
      expect(store.snapshot, isEmpty);
      expect(
        File(store.recordPath(record.transactionId)).existsSync(),
        isFalse,
      );
      expect(
        temporaryDirectory
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.tmp')),
        isEmpty,
      );
    },
  );

  test(
    'projection failure persists typed debt and replay is idempotent',
    () async {
      var store = await AcceptedPhotoRecordStore.open(temporaryDirectory);
      final record = _record(jpeg.path);
      await store.publish(record, canPublish: () => true);

      final failed = await store.project(
        transactionId: record.transactionId,
        projection: AcceptedPhotoProjection.coverage,
        apply: (_) => throw const AcceptedPhotoProjectionException(
          code: 'coverage_unavailable',
          message: 'coverage owner is not attached',
        ),
      );

      expect(failed.status, AcceptedPhotoProjectionStatus.deferred);
      expect(store.snapshot, <AcceptedPhotoRecord>[record]);
      expect(store.debtSnapshot, hasLength(1));
      expect(
        store.debtSnapshot.single.projection,
        AcceptedPhotoProjection.coverage,
      );
      expect(store.debtSnapshot.single.code, 'coverage_unavailable');

      store = await AcceptedPhotoRecordStore.open(temporaryDirectory);
      expect(store.snapshot, <AcceptedPhotoRecord>[record]);
      expect(store.debtSnapshot, hasLength(1));

      var replayCalls = 0;
      final replay = await store.replay(
        handlers: <AcceptedPhotoProjection, AcceptedPhotoProjectionHandler>{
          AcceptedPhotoProjection.coverage: (_) => replayCalls++,
        },
      );
      final replayAgain = await store.replay(
        handlers: <AcceptedPhotoProjection, AcceptedPhotoProjectionHandler>{
          AcceptedPhotoProjection.coverage: (_) => replayCalls++,
        },
      );

      expect(replay.applied, 1);
      expect(replay.remaining, 0);
      expect(replayAgain.applied, 0);
      expect(replayCalls, 1);
      expect(store.debtSnapshot, isEmpty);
      expect(
        await store.isProjectionComplete(
          record.transactionId,
          AcceptedPhotoProjection.coverage,
        ),
        isTrue,
      );
    },
  );

  test(
    'project album consumes canonical records and cannot admit a file',
    () async {
      final store = await AcceptedPhotoRecordStore.open(temporaryDirectory);
      final album = OfficialProjectPhotoAlbum();
      addTearDown(album.dispose);

      expect(
        album.commitVerified(
          jpegPath: jpeg.path,
          captureTimestamp: 1.25,
          imageWidth: 4032,
          imageHeight: 3024,
        ),
        isFalse,
        reason: 'a JPEG without a durable record is not project membership',
      );

      final record = _record(jpeg.path);
      await store.publish(record, canPublish: () => true);

      expect(album.count, 1);
      expect(album.paths, <String>[jpeg.path]);
      expect(
        album.commitVerified(
          jpegPath: jpeg.path,
          captureTimestamp: record.captureTimestamp,
          imageWidth: record.imageWidth,
          imageHeight: record.imageHeight,
        ),
        isTrue,
        reason: 'compatibility API only confirms existing canonical membership',
      );
      expect(album.count, 1);
      expect(album.remove(jpeg.path), isFalse);
      expect(album.count, 1);
    },
  );

  test(
    'durable tombstone precedes removal and prevents resurrection',
    () async {
      var store = await AcceptedPhotoRecordStore.open(temporaryDirectory);
      final album = OfficialProjectPhotoAlbum();
      addTearDown(album.dispose);
      final record = _record(jpeg.path);
      await store.publish(record, canPublish: () => true);

      expect(await store.tombstone(record.transactionId), isTrue);
      expect(
        File(store.tombstonePath(record.transactionId)).existsSync(),
        isTrue,
      );
      expect(store.snapshot, isEmpty);
      expect(album.count, 0);

      store = await AcceptedPhotoRecordStore.open(temporaryDirectory);
      expect(store.snapshot, isEmpty);
      expect(
        (await store.publish(record, canPublish: () => true)).status,
        AcceptedPhotoPublishStatus.aborted,
        reason: 'a deleted transaction may never regain membership',
      );
      expect(await store.tombstone(record.transactionId), isFalse);
    },
  );
}

AcceptedPhotoRecord _record(String jpegPath) => AcceptedPhotoRecord(
  transactionId: 'cap-1-g1-tap-1',
  generation: 1,
  frameId: 'tap-1',
  jpegPath: jpegPath,
  previewPath: '$jpegPath.preview.jpg',
  automaticSelection: true,
  imageWidth: 4032,
  imageHeight: 3024,
  triggerTimestamp: 1.2,
  captureTimestamp: 1.25,
  cameraTransform: const <double>[
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
    0,
    0,
    0,
    0,
    1,
  ],
  intrinsics: const <double>[2000, 2000, 2016, 1512],
  captureKind: 'arkit_high_res_still',
  poseSyncQuality: 'ar_session_high_res_frame',
  trackingStateName: 'normal',
  gray128Base64: null,
  sample: const <String, Object?>{
    'timestamp': 1.2,
    'azimuth': 0.1,
    'elevation': 0.2,
    'sharpness': 999,
    'motionScore': 0,
    'exposureScore': 1,
    'frameId': 'tap-1',
  },
  quality: const <String, Object?>{
    'accepted': true,
    'score': 1,
    'laplacianVariance': 999,
    'meanLuma': 128,
    'underexposedRatio': 0,
    'overexposedRatio': 0,
    'textureCellRatio': 1,
    'rejectReasons': <String>[],
  },
);
