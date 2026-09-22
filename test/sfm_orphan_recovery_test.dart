import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/sfm_feed_queue.dart';
import 'package:pocketworld_flutter/capture/sfm_orphan_recovery.dart';

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sfm-orphans-');
  });

  tearDown(() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  });

  test(
    'recovers only a fully committed, path-bound manual-v2 bundle',
    () async {
      final files = await _writeBundle(directory, index: 7, timestamp: 12.5);

      final scan = await scanCommittedSfmOrphans(directory);

      expect(scan.blocks, isEmpty);
      expect(scan.committedOrphans, hasLength(1));
      final item = scan.committedOrphans.single;
      expect(item.captureJobId, 'job-7');
      expect(item.frameId, 'tap-7');
      expect(item.expectedGrayBytes, 12);
      expect(item.intrinsicFxFyCxCy, <double>[100, 101, 2, 1.5]);
      expect(item.extrinsic4x4, hasLength(16));
      expect(
        item.toDurableQueueMetadata(),
        containsPair('captureJobId', 'job-7'),
      );
      expect(await files.gray.exists(), isTrue);
      expect(await files.jpeg.exists(), isTrue);
      expect(await files.sidecar.exists(), isTrue);
    },
  );

  test('durable-v2 requires and verifies the exact commit receipt', () async {
    final files = await _writeDurableV2Bundle(
      directory,
      index: 100,
      timestamp: 100,
    );

    final scan = await scanCommittedSfmOrphans(directory);

    expect(scan.blocks, isEmpty);
    final item = scan.committedOrphans.single;
    expect(item.manualCaptureSchema, 'aether_manual_capture_v2_durable_v2');
    expect(item.captureJobId, 'job-100');
    expect(item.frameId, 'tap-100');
    expect(item.snapshotIdentity, 'snapshot-100');
    expect(item.durableCommitMarkerFile?.path, files.marker?.path);
    expect(item.artifactSha256.keys, <String>{'jpeg', 'metadata', 'sfm_gray'});
    expect(
      item.toDurableQueueMetadata()['durableCommitMarkerPath'],
      files.marker?.absolute.path,
    );
  });

  test('durable-v2 hash mismatch blocks committed evidence', () async {
    final files = await _writeDurableV2Bundle(
      directory,
      index: 101,
      timestamp: 101,
    );
    await files.gray.writeAsBytes(List<int>.filled(12, 0xee), flush: true);

    final scan = await scanCommittedSfmOrphans(directory);

    expect(scan.committedOrphans, isEmpty);
    expect(scan.blocks.single.kind, SfmOrphanRecoveryBlockKind.invalidEvidence);
    expect(scan.blocks.single.message, contains('SHA-256 mismatch'));
  });

  test('durable-v2 wrong receipt job is rejected', () async {
    final files = await _writeDurableV2Bundle(
      directory,
      index: 102,
      timestamp: 102,
    );
    final marker = jsonDecode(await files.marker!.readAsString()) as Map;
    marker['captureJobID'] = 'job-other';
    await files.marker!.writeAsString(jsonEncode(marker), flush: true);

    final scan = await scanCommittedSfmOrphans(directory);

    expect(scan.committedOrphans, isEmpty);
    expect(scan.blocks.single.kind, SfmOrphanRecoveryBlockKind.invalidEvidence);
    expect(scan.blocks.single.message, contains('another job'));
  });

  test(
    'durable-v2 partial publication is left to Swift reconciliation',
    () async {
      await _writeDurableV2Bundle(
        directory,
        index: 103,
        timestamp: 103,
        writeMarker: false,
      );

      final scan = await scanCommittedSfmOrphans(directory);

      expect(scan.committedOrphans, isEmpty);
      expect(scan.blocks, isEmpty);
    },
  );

  test(
    'durable-v2 recovery survives queue reopen without re-adoption',
    () async {
      final files = await _writeDurableV2Bundle(
        directory,
        index: 104,
        timestamp: 104,
      );
      final queueDirectory = Directory('${directory.path}/v2.sfm-feed');
      var queue = await SfmDurableFeedQueue.open(queueDirectory);
      final first = await queue
          .recoverCommittedCaptureSourcesAfterWriterQuiescence(
            directory,
            writersQuiesced: true,
          );
      expect(first.committedOrphans, hasLength(1));
      expect(queue.spoolDepth, 1);
      await queue.close();

      queue = await SfmDurableFeedQueue.open(queueDirectory);
      final second = await queue
          .recoverCommittedCaptureSourcesAfterWriterQuiescence(
            directory,
            writersQuiesced: true,
          );
      expect(second.committedOrphans, isEmpty);
      expect(second.blocks, isEmpty);
      expect(queue.spoolDepth, 1);
      expect(await files.jpeg.exists(), isTrue);
      expect(await files.sidecar.exists(), isTrue);
      expect(await files.marker!.exists(), isTrue);
      await queue.close();
    },
  );

  test(
    'cold open bridges native commit before descriptor into durable FIFO',
    () async {
      final files = await _writeBundle(directory, index: 9, timestamp: 9);
      final queueDirectory = Directory(
        '${directory.path}/sfm_live.db.sfm-feed',
      );

      // Crash boundary: native three-file bundle exists, queue directory and
      // descriptor do not. Cold recovery discovers the committed intent.
      var queue = await SfmDurableFeedQueue.open(queueDirectory);
      final scan = await queue
          .recoverCommittedCaptureSourcesAfterWriterQuiescence(
            directory,
            writersQuiesced: true,
          );
      expect(scan.blocks, isEmpty);
      expect(scan.committedOrphans.single.captureJobId, 'job-9');
      final frame = queue.pendingFrames.single;
      await queue.close();

      expect(await files.gray.exists(), isFalse);
      expect(
        await files.jpeg.exists(),
        isTrue,
        reason: 'user photo is retained',
      );
      expect(await files.sidecar.exists(), isTrue);
      expect(await frame.descriptorFile.exists(), isTrue);

      queue = await SfmDurableFeedQueue.open(queueDirectory);
      expect(queue.spoolDepth, 1);
      expect(queue.pendingFrames.single.metadata['captureJobId'], 'job-9');
      expect(queue.pendingFrames.single.metadata['frameId'], 'tap-9');
      expect((await queue.claimNext())?.grayBytes, hasLength(12));
      await queue.close();

      final afterMove = await scanCommittedSfmOrphans(
        directory,
        queueOwnedJpegPaths: <String>{files.jpeg.absolute.path},
      );
      expect(afterMove.committedOrphans, isEmpty);
      expect(afterMove.blocks, isEmpty);
    },
  );

  test('live writer activity cannot invoke cold orphan recovery', () async {
    await _writeBundle(directory, index: 10, timestamp: 10);
    final queue = await SfmDurableFeedQueue.open(
      Directory('${directory.path}/sfm_live.db.sfm-feed'),
    );

    await expectLater(
      queue.recoverCommittedCaptureSourcesAfterWriterQuiescence(
        directory,
        writersQuiesced: false,
      ),
      throwsStateError,
    );
    expect(queue.spoolDepth, 0);
    expect(queue.blocked, isFalse);
    await queue.close();
  });

  test('queued prefix plus committed orphan suffix preserves FIFO', () async {
    final first = await _writeBundle(directory, index: 30, timestamp: 30);
    final second = await _writeBundle(directory, index: 31, timestamp: 31);
    final firstEvidence = (await scanCommittedSfmOrphans(
      directory,
    )).committedOrphans.first;
    final queue = await SfmDurableFeedQueue.open(
      Directory('${directory.path}/sfm_live.db.sfm-feed'),
    );
    await queue.enqueueGrayFile(
      sourceGrayFile: firstEvidence.grayFile,
      expectedByteLength: firstEvidence.expectedGrayBytes,
      metadata: firstEvidence.toDurableQueueMetadata(),
    );

    final recovered = await queue
        .recoverCommittedCaptureSourcesAfterWriterQuiescence(
          directory,
          writersQuiesced: true,
        );

    expect(recovered.blocks, isEmpty);
    expect(recovered.committedOrphans.single.captureJobId, 'job-31');
    expect(
      queue.pendingFrames.map((frame) => frame.metadata['captureJobId']),
      orderedEquals(<String>['job-30', 'job-31']),
    );
    expect(await first.jpeg.exists(), isTrue);
    expect(await second.jpeg.exists(), isTrue);
    expect(await first.sidecar.exists(), isTrue);
    expect(await second.sidecar.exists(), isTrue);
    await queue.close();
  });

  test('cold recovery durably blocks incomplete evidence', () async {
    final files = await _writeBundle(directory, index: 11, timestamp: 11);
    await files.jpeg.delete();
    final queueDirectory = Directory('${directory.path}/sfm_live.db.sfm-feed');
    var queue = await SfmDurableFeedQueue.open(queueDirectory);

    final scan = await queue
        .recoverCommittedCaptureSourcesAfterWriterQuiescence(
          directory,
          writersQuiesced: true,
        );
    expect(scan.blocks, hasLength(1));
    expect(queue.blockReason?.kind, SfmFeedBlockKind.replayIncomplete);
    await queue.close();

    queue = await SfmDurableFeedQueue.open(queueDirectory);
    expect(queue.blockReason?.kind, SfmFeedBlockKind.replayIncomplete);
    expect(queue.spoolDepth, 0);

    // A later cold retry may observe restored evidence. Only this scanner's
    // own path-bound block is cleared; the frame then enters the FIFO once.
    await files.jpeg.writeAsBytes(<int>[0xff, 0xd8, 11], flush: true);
    final retry = await queue
        .recoverCommittedCaptureSourcesAfterWriterQuiescence(
          directory,
          writersQuiesced: true,
        );
    expect(retry.blocks, isEmpty);
    expect(retry.committedOrphans, hasLength(1));
    expect(queue.blocked, isFalse);
    expect(queue.spoolDepth, 1);
    await queue.close();

    queue = await SfmDurableFeedQueue.open(queueDirectory);
    expect(queue.blocked, isFalse);
    expect(queue.spoolDepth, 1);
    await queue.close();
  });

  test('gray without sidecar blocks instead of guessing camera data', () async {
    await File('${directory.path}/bare.sfm-gray').writeAsBytes(<int>[1]);

    final scan = await scanCommittedSfmOrphans(directory);

    expect(scan.committedOrphans, isEmpty);
    expect(scan.blocks.single.kind, SfmOrphanRecoveryBlockKind.missingSidecar);
  });

  test(
    'sidecar before gray is a durable incomplete intent and blocks',
    () async {
      final files = await _writeBundle(directory, index: 1, timestamp: 1);
      await files.gray.delete();
      await files.jpeg.delete();

      final scan = await scanCommittedSfmOrphans(directory);

      expect(scan.committedOrphans, isEmpty);
      expect(
        scan.blocks.single.kind,
        SfmOrphanRecoveryBlockKind.incompleteNativeCommit,
      );
      expect(scan.blocks.single.captureJobId, 'job-1');
    },
  );

  test('gray and sidecar without final JPEG commit marker block', () async {
    final files = await _writeBundle(directory, index: 2, timestamp: 2);
    await files.jpeg.delete();

    final scan = await scanCommittedSfmOrphans(directory);

    expect(scan.committedOrphans, isEmpty);
    expect(
      scan.blocks.single.kind,
      SfmOrphanRecoveryBlockKind.incompleteNativeCommit,
    );
  });

  test('missing pose or K never becomes a recoverable frame', () async {
    final missingK = await _writeBundle(directory, index: 3, timestamp: 3);
    final kJson = jsonDecode(await missingK.sidecar.readAsString()) as Map;
    kJson.remove('intrinsics_fxfycxcy');
    await missingK.sidecar.writeAsString(jsonEncode(kJson), flush: true);

    final missingPose = await _writeBundle(directory, index: 4, timestamp: 4);
    final poseJson =
        jsonDecode(await missingPose.sidecar.readAsString()) as Map;
    poseJson.remove('extrinsic');
    await missingPose.sidecar.writeAsString(jsonEncode(poseJson), flush: true);

    final scan = await scanCommittedSfmOrphans(directory);

    expect(scan.committedOrphans, isEmpty);
    expect(scan.blocks, hasLength(2));
    expect(
      scan.blocks.map((block) => block.kind),
      everyElement(SfmOrphanRecoveryBlockKind.invalidEvidence),
    );
  });

  test('one capture job cannot recover as two different frames', () async {
    await _writeBundle(directory, index: 20, timestamp: 20);
    final second = await _writeBundle(directory, index: 21, timestamp: 21);
    final decoded = jsonDecode(await second.sidecar.readAsString()) as Map;
    decoded['capture_job_id'] = 'job-20';
    await second.sidecar.writeAsString(jsonEncode(decoded), flush: true);

    final scan = await scanCommittedSfmOrphans(directory);

    expect(scan.committedOrphans, isEmpty);
    expect(scan.blocks, hasLength(2));
    expect(
      scan.blocks.map((block) => block.kind),
      everyElement(SfmOrphanRecoveryBlockKind.duplicateIdentity),
    );
  });

  test('finite but non-rigid pose evidence is rejected', () async {
    final files = await _writeBundle(directory, index: 22, timestamp: 22);
    final decoded = jsonDecode(await files.sidecar.readAsString()) as Map;
    final extrinsic = (decoded['extrinsic'] as List).cast<num>();
    extrinsic[0] = 2;
    decoded['extrinsic'] = extrinsic;
    await files.sidecar.writeAsString(jsonEncode(decoded), flush: true);

    final scan = await scanCommittedSfmOrphans(directory);

    expect(scan.committedOrphans, isEmpty);
    expect(scan.blocks.single.kind, SfmOrphanRecoveryBlockKind.invalidEvidence);
  });

  test(
    'path substitution is rejected and user photos remain untouched',
    () async {
      final files = await _writeBundle(directory, index: 5, timestamp: 5);
      final decoded = jsonDecode(await files.sidecar.readAsString()) as Map;
      decoded['sfm_gray_path'] = '${directory.path}/other.sfm-gray';
      await files.sidecar.writeAsString(jsonEncode(decoded), flush: true);
      final jpegBefore = await files.jpeg.readAsBytes();

      final scan = await scanCommittedSfmOrphans(directory);

      expect(scan.committedOrphans, isEmpty);
      expect(
        scan.blocks.single.kind,
        SfmOrphanRecoveryBlockKind.invalidEvidence,
      );
      expect(await files.jpeg.readAsBytes(), jpegBefore);
      expect(await files.gray.exists(), isTrue);
    },
  );

  test('1000 committed captures recover in timestamp FIFO order', () async {
    for (var index = 0; index < 1000; index++) {
      await _writeBundle(
        directory,
        index: index,
        timestamp: (999 - index).toDouble(),
      );
    }

    final scan = await scanCommittedSfmOrphans(directory);

    expect(scan.blocks, isEmpty);
    expect(scan.committedOrphans, hasLength(1000));
    expect(
      scan.committedOrphans.map((item) => item.timestamp),
      orderedEquals(List<double>.generate(1000, (index) => index.toDouble())),
    );
  });

  test('repeated reopen scan is identity-idempotent and read-only', () async {
    for (var index = 0; index < 8; index++) {
      await _writeBundle(directory, index: index, timestamp: index.toDouble());
    }

    final first = await scanCommittedSfmOrphans(directory);
    final second = await scanCommittedSfmOrphans(directory);

    expect(
      second.committedOrphans.map((item) => item.captureJobId),
      orderedEquals(
        first.committedOrphans.map((item) => item.captureJobId).toList(),
      ),
    );
    expect(await directory.list().where((entity) => entity is File).length, 24);
  });

  test('unrelated JSON is ignored', () async {
    await File(
      '${directory.path}/album.json',
    ).writeAsString('{"kind":"photo_bundle"}', flush: true);

    final scan = await scanCommittedSfmOrphans(directory);

    expect(scan.committedOrphans, isEmpty);
    expect(scan.blocks, isEmpty);
  });
}

Future<_BundleFiles> _writeBundle(
  Directory directory, {
  required int index,
  required double timestamp,
}) async {
  final stem = '${directory.path}/capture-${index.toString().padLeft(4, '0')}';
  final gray = File('$stem.sfm-gray');
  final jpeg = File('$stem.jpg');
  final sidecar = File('$stem.json');
  await gray.writeAsBytes(List<int>.filled(12, index & 0xff), flush: true);
  await jpeg.writeAsBytes(<int>[0xff, 0xd8, index & 0xff], flush: true);
  await sidecar.writeAsString(
    jsonEncode(<String, Object?>{
      'version': 1,
      'manual_capture_schema': 'aether_manual_capture_v2_in_process_v1',
      'capture_job_id': 'job-$index',
      't': timestamp,
      'image_w': 8,
      'image_h': 6,
      'sfm_gray_path': gray.absolute.path,
      'sfm_gray_w': 4,
      'sfm_gray_h': 3,
      'intrinsics_fxfycxcy': <double>[100, 101, 2, 1.5],
      'extrinsic': <double>[
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
        index.toDouble(),
        0,
        0,
        1,
      ],
      'dart_save_contract': <String, Object?>{
        'frame_id': 'tap-$index',
        'jpeg_path': jpeg.absolute.path,
        'metadata_path': sidecar.absolute.path,
      },
    }),
    flush: true,
  );
  return _BundleFiles(gray: gray, jpeg: jpeg, sidecar: sidecar);
}

Future<_BundleFiles> _writeDurableV2Bundle(
  Directory directory, {
  required int index,
  required double timestamp,
  bool writeMarker = true,
}) async {
  final stem = '${directory.path}/durable-${index.toString().padLeft(4, '0')}';
  final gray = File('$stem.sfm-gray');
  final jpeg = File('$stem.jpg');
  final sidecar = File('$stem.json');
  final marker = File('$stem.manual-v2-committed.json');
  await gray.writeAsBytes(List<int>.filled(12, index & 0xff), flush: true);
  await jpeg.writeAsBytes(<int>[0xff, 0xd8, index & 0xff], flush: true);
  await sidecar.writeAsString(
    jsonEncode(<String, Object?>{
      'version': 1,
      'manual_capture_schema': 'aether_manual_capture_v2_durable_v2',
      'capture_job_id': 'job-$index',
      'frame_identity': 'tap-$index',
      'snapshot_identity': 'snapshot-$index',
      'durable_commit_marker_path': marker.absolute.path,
      't': timestamp,
      'image_w': 8,
      'image_h': 6,
      'sfm_gray_path': gray.absolute.path,
      'sfm_gray_w': 4,
      'sfm_gray_h': 3,
      'intrinsics_fxfycxcy': <double>[100, 101, 2, 1.5],
      'extrinsic': <double>[
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
        index.toDouble(),
        0,
        0,
        1,
      ],
      'dart_save_contract': <String, Object?>{
        'frame_id': 'tap-$index',
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
          'sha256': await _testSha256(file),
        };
    await marker.writeAsString(
      jsonEncode(<String, Object?>{
        'schemaVersion': 1,
        'captureJobID': 'job-$index',
        'snapshotIdentity': 'snapshot-$index',
        'preparedSha256': sha256
            .convert(utf8.encode('prepared-$index'))
            .toString(),
        'artifacts': <Object?>[
          await artifact('jpeg', jpeg),
          await artifact('metadata', sidecar),
          await artifact('sfm_gray', gray),
        ],
        'committedUnixMicros': 1720000000000000 + index,
      }),
      flush: true,
    );
  }
  return _BundleFiles(gray: gray, jpeg: jpeg, sidecar: sidecar, marker: marker);
}

Future<String> _testSha256(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();

final class _BundleFiles {
  const _BundleFiles({
    required this.gray,
    required this.jpeg,
    required this.sidecar,
    this.marker,
  });
  final File gray;
  final File jpeg;
  final File sidecar;
  final File? marker;
}
