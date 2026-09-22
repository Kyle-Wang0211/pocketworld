import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/sfm_feed_queue.dart';
import 'package:pocketworld_flutter/me/scan_record_store.dart';
import 'package:pocketworld_flutter/ui/scan_record.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  late Directory documents;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp(
      'scan-record-zero-photo-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (_) async => documents.path);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    if (await documents.exists()) await documents.delete(recursive: true);
  });

  test(
    'ACK, attempt, and failed-only zero-photo captures survive cold start',
    () async {
      final ack = await _writeLedgerCapture(
        documents: documents,
        captureId: 'cap_zero_photo_ack',
        jobId: 'job-ack',
        events: <String>['attempted', 'accepted'],
      );
      final attempted = await _writeLedgerCapture(
        documents: documents,
        captureId: 'cap_zero_photo_attempt',
        jobId: 'job-attempt',
        events: <String>['attempted'],
      );
      // A native failure journal may be the only durable identity left when
      // the photos directory was never created and the JPEG mapping was not
      // committed. Dropping this directory makes the failed shutter attempt
      // impossible to inspect or explicitly discard after restart.
      final failed = await _writeLedgerCapture(
        documents: documents,
        captureId: 'cap_zero_photo_failed',
        jobId: 'job-failed',
        events: <String>['blocked'],
        createPhotosDirectory: false,
        includeJpegMapping: false,
      );
      final prepared = await _writeDurableLedgerCapture(
        documents: documents,
        captureId: 'cap_prepared_without_marker',
        jobId: 'job-prepared',
        writeMarker: false,
      );
      final committed = await _writeDurableLedgerCapture(
        documents: documents,
        captureId: 'cap_exact_committed_bundle',
        jobId: 'job-committed',
        writeMarker: true,
      );
      // Queue adoption is allowed to move gray before Dart promotes the
      // accepted ledger to photoCommitted. The sealed photo receipt remains
      // sufficient to show the user's committed JPEG.
      await committed.gray.delete();
      final tampered = await _writeDurableLedgerCapture(
        documents: documents,
        captureId: 'cap_tampered_committed_bundle',
        jobId: 'job-tampered',
        writeMarker: true,
      );
      await tampered.jpeg.writeAsBytes(<int>[1], mode: FileMode.append);

      await ScanRecordStore.instance.ensureLoaded();

      for (final expected in <_LedgerCapture>[ack, attempted, failed]) {
        final record = ScanRecordStore.instance.byId(expected.captureId);
        expect(record, isNotNull, reason: expected.captureId);
        expect(record!.photoCount, 0, reason: expected.captureId);
        expect(record.thumbnailPath, isNull, reason: expected.captureId);
        expect(record.captureDir, expected.capture.path);
        expect(record.photosDir, expected.photos.path);
        final manifest = File(record.captureManifestPath!);
        expect(manifest.existsSync(), isTrue, reason: expected.captureId);
        final decoded = jsonDecode(await manifest.readAsString()) as Map;
        expect(decoded['photo_count'], 0);
        expect(decoded['frames'], isEmpty);
      }
      final preparedRecord = ScanRecordStore.instance.byId(prepared.captureId);
      expect(preparedRecord, isNotNull);
      expect(preparedRecord!.photoCount, 0);
      expect(preparedRecord.thumbnailPath, isNull);
      expect(prepared.jpeg.existsSync(), isTrue);

      final committedRecord = ScanRecordStore.instance.byId(
        committed.captureId,
      );
      expect(committedRecord, isNotNull);
      expect(committedRecord!.photoCount, 1);
      expect(committedRecord.thumbnailPath, isNotNull);
      expect(File(committedRecord.thumbnailPath!).existsSync(), isTrue);

      final tamperedRecord = ScanRecordStore.instance.byId(tampered.captureId);
      expect(tamperedRecord, isNotNull);
      expect(tamperedRecord!.photoCount, 0);
      expect(tamperedRecord.thumbnailPath, isNull);

      final persisted =
          jsonDecode(
                await File(
                  '${documents.path}/scan_records.json',
                ).readAsString(),
              )
              as List;
      expect(
        persisted.map((raw) => (raw as Map)['id']),
        containsAll(<String>[
          ack.captureId,
          attempted.captureId,
          failed.captureId,
        ]),
      );

      final capturesRoot = Directory('${documents.path}/captures');
      Future<void> expectUnsafePathRejected(ScanRecord record) async {
        await ScanRecordStore.instance.addOrUpdate(record);
        var pathCleanupCalled = false;
        await expectLater(
          ScanRecordStore.instance.delete(
            record.id,
            coordinatedCleanup: (_) async {
              pathCleanupCalled = true;
            },
          ),
          throwsA(isA<StateError>()),
        );
        expect(pathCleanupCalled, isFalse);
        expect(ScanRecordStore.instance.byId(record.id), isNotNull);
      }

      await expectUnsafePathRejected(
        ScanRecord(
          id: 'cap_parent_alias',
          name: 'parent alias',
          createdAt: DateTime.now(),
          captureDir: capturesRoot.path,
        ),
      );
      await expectUnsafePathRejected(
        ScanRecord(
          id: 'cap_wrong_capture',
          name: 'wrong capture',
          createdAt: DateTime.now(),
          captureDir: ack.capture.path,
        ),
      );
      final outside = Directory('${documents.path}/outside-capture');
      await outside.create();
      await expectUnsafePathRejected(
        ScanRecord(
          id: '../outside-capture',
          name: 'traversal',
          createdAt: DateTime.now(),
          captureDir: outside.path,
        ),
      );
      final symlink = Link('${capturesRoot.path}/cap_symlink_escape');
      await symlink.create(outside.path);
      await expectUnsafePathRejected(
        ScanRecord(
          id: 'cap_symlink_escape',
          name: 'symlink escape',
          createdAt: DateTime.now(),
          captureDir: symlink.path,
        ),
      );
      expect(capturesRoot.existsSync(), isTrue);
      expect(ack.capture.existsSync(), isTrue);
      expect(outside.existsSync(), isTrue);

      final queue = await SfmDurableFeedQueue.open(
        Directory('${failed.capture.path}/sfm_live.db.sfm-feed'),
      );
      var cleanupCalled = false;
      await expectLater(
        ScanRecordStore.instance.delete(
          failed.captureId,
          coordinatedCleanup: (_) async {
            cleanupCalled = true;
          },
        ),
        throwsA(isA<StateError>()),
      );
      expect(cleanupCalled, isFalse);
      expect(ScanRecordStore.instance.byId(failed.captureId), isNotNull);
      await queue.close();

      await expectLater(
        ScanRecordStore.instance.delete(
          failed.captureId,
          coordinatedCleanup: (_) async {
            throw const FileSystemException('directory still busy');
          },
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(ScanRecordStore.instance.byId(failed.captureId), isNotNull);
      expect(failed.capture.existsSync(), isTrue);

      await expectLater(
        ScanRecordStore.instance.delete(
          failed.captureId,
          coordinatedCleanup: (directory) => directory.delete(recursive: true),
          recordIndexWriter: (index, records) async {
            throw const FileSystemException('scan record index is read-only');
          },
        ),
        throwsA(isA<FileSystemException>()),
      );
      expect(ScanRecordStore.instance.byId(failed.captureId), isNotNull);
      expect(failed.capture.existsSync(), isFalse);

      await ScanRecordStore.instance.delete(
        failed.captureId,
        coordinatedCleanup: (directory) => directory.delete(recursive: true),
      );
      expect(ScanRecordStore.instance.byId(failed.captureId), isNull);
      expect(failed.capture.existsSync(), isFalse);
    },
  );
}

Future<_LedgerCapture> _writeLedgerCapture({
  required Directory documents,
  required String captureId,
  required String jobId,
  required List<String> events,
  bool createPhotosDirectory = true,
  bool includeJpegMapping = true,
}) async {
  final capture = Directory('${documents.path}/captures/$captureId');
  final photos = Directory('${capture.path}/photos_highres');
  if (createPhotosDirectory) {
    await photos.create(recursive: true);
  } else {
    await capture.create(recursive: true);
  }
  final jpegPath = '${photos.path}/$jobId.jpg';
  await File(
    '${capture.path}/manual_capture_registration_ledger.json',
  ).writeAsString(
    jsonEncode(<String, Object?>{
      'schema_version': 1,
      'events': <Object?>[
        for (final event in events)
          <String, Object?>{
            'schema_version': 1,
            'event': event,
            'capture_job_id': jobId,
            if (event == 'attempted') 'identity_token': jpegPath,
            if (event == 'blocked') ...<String, Object?>{
              'blocker_id': 'blocker-$jobId',
              'blocker_code': 'native_commit_failed',
              'blocker_message': 'native writer failed before JPEG commit',
            },
          },
      ],
      if (includeJpegMapping)
        'job_to_jpeg_path': <String, String>{jobId: jpegPath},
    }),
    flush: true,
  );
  return _LedgerCapture(captureId: captureId, capture: capture, photos: photos);
}

class _LedgerCapture {
  const _LedgerCapture({
    required this.captureId,
    required this.capture,
    required this.photos,
  });

  final String captureId;
  final Directory capture;
  final Directory photos;
}

Future<_DurableLedgerCapture> _writeDurableLedgerCapture({
  required Directory documents,
  required String captureId,
  required String jobId,
  required bool writeMarker,
}) async {
  final capture = Directory('${documents.path}/captures/$captureId');
  final photos = Directory('${capture.path}/photos_highres');
  await photos.create(recursive: true);
  final stem = '${photos.path}/$jobId';
  final jpeg = File('$stem.jpg');
  final sidecar = File('$stem.json');
  final gray = File('$stem.sfm-gray');
  final marker = File('$stem.manual-v2-committed.json');
  await jpeg.writeAsBytes(<int>[0xff, 0xd8, 7, 0xff, 0xd9], flush: true);
  await gray.writeAsBytes(List<int>.filled(12, 7), flush: true);
  await sidecar.writeAsString(
    jsonEncode(<String, Object?>{
      'version': 1,
      'manual_capture_schema': 'aether_manual_capture_v2_durable_v2',
      'capture_job_id': jobId,
      'frame_identity': jobId,
      'snapshot_identity': 'snapshot-$jobId',
      'durable_commit_marker_path': marker.absolute.path,
      't': 1.0,
      'image_w': 8,
      'image_h': 6,
      'sfm_gray_path': gray.absolute.path,
      'sfm_gray_w': 4,
      'sfm_gray_h': 3,
      'intrinsics_fxfycxcy': <double>[100, 101, 2, 1.5],
      'extrinsic': <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
      'dart_save_contract': <String, Object?>{
        'frame_id': jobId,
        'jpeg_path': jpeg.absolute.path,
        'metadata_path': sidecar.absolute.path,
      },
    }),
    flush: true,
  );
  if (writeMarker) {
    Future<Map<String, Object?>> artifact(String kind, File file) async =>
        <String, Object?>{
          'kind': kind,
          'finalPath': file.absolute.path,
          'byteLength': await file.length(),
          'sha256': (await sha256.bind(file.openRead()).first).toString(),
        };
    await marker.writeAsString(
      jsonEncode(<String, Object?>{
        'schemaVersion': 1,
        'captureJobID': jobId,
        'snapshotIdentity': 'snapshot-$jobId',
        'preparedSha256': sha256.convert(utf8.encode(jobId)).toString(),
        'artifacts': <Object?>[
          await artifact('jpeg', jpeg),
          await artifact('metadata', sidecar),
          await artifact('sfm_gray', gray),
        ],
        'committedUnixMicros': 1720000000000000,
      }),
      flush: true,
    );
  }
  await File(
    '${capture.path}/manual_capture_registration_ledger.json',
  ).writeAsString(
    jsonEncode(<String, Object?>{
      'schema_version': 1,
      'events': <Object?>[
        <String, Object?>{
          'schema_version': 1,
          'event': 'attempted',
          'capture_job_id': jobId,
          'identity_token': jpeg.absolute.path,
        },
        <String, Object?>{
          'schema_version': 1,
          'event': 'accepted',
          'capture_job_id': jobId,
        },
      ],
      'job_to_jpeg_path': <String, String>{jobId: jpeg.absolute.path},
    }),
    flush: true,
  );
  return _DurableLedgerCapture(
    captureId: captureId,
    capture: capture,
    photos: photos,
    jpeg: jpeg,
    gray: gray,
  );
}

final class _DurableLedgerCapture extends _LedgerCapture {
  const _DurableLedgerCapture({
    required super.captureId,
    required super.capture,
    required super.photos,
    required this.jpeg,
    required this.gray,
  });

  final File jpeg;
  final File gray;
}
