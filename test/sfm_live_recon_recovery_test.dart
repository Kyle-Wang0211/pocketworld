import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/sfm_feed_queue.dart';
import 'package:pocketworld_flutter/capture/sfm_live_recon.dart';

void main() {
  group('SfM fed metadata recovery', () {
    test('schema v2 requires and preserves real gray calibration', () {
      final record = SfmFedFrameSidecarRecord.fromJson(<String, Object?>{
        'schemaVersion': 2,
        'frameId': 7,
        'jpegPath': '/old/container/photos_highres/tap-7.jpg',
        'imageW': 4032,
        'imageH': 3024,
        'grayW': 1008,
        'grayH': 756,
        'fx': 801.25,
        'fy': 802.5,
        'cx': 504.0,
        'cy': 378.0,
      }, jpegDirectory: '/new/container/photos_highres');

      expect(record.frameId, 7);
      expect(record.meta.jpegPath, '/new/container/photos_highres/tap-7.jpg');
      expect(record.meta.hasGrayIntrinsics, isTrue);
      expect(record.meta.fx, 801.25);
      expect(
        () => SfmFedFrameSidecarRecord.fromJson(<String, Object?>{
          'schemaVersion': 2,
          'frameId': 8,
          'jpegPath': 'tap-8.jpg',
          'grayW': 1008,
          'grayH': 756,
        }),
        throwsFormatException,
      );
    });

    test('legacy row is readable but never advertises zero K', () {
      final record = SfmFedFrameSidecarRecord.fromJson(<String, Object?>{
        'frameId': 2,
        'jpegPath': 'tap-2.jpg',
        'grayW': 1008,
        'grayH': 756,
      });

      expect(record.meta.hasGrayIntrinsics, isFalse);
      expect(record.meta.imageW, -1);
      expect(record.meta.fx.isNaN, isTrue);
      expect(record.meta.fy.isNaN, isTrue);
      expect(record.meta.cx.isNaN, isTrue);
      expect(record.meta.cy.isNaN, isTrue);
    });
  });

  test(
    'resume replay predicate and command order cover the full truth table',
    () {
      for (var mask = 0; mask < 16; mask++) {
        final spool = mask & 1;
        final inFlight = (mask >> 1) & 1;
        final fedMeta = (mask >> 2) & 1;
        final nativeReplay = mask & 8 != 0;
        final mustDrain = mask != 0;

        expect(
          sfmResumeMustDrainReplay(
            spoolDepth: spool,
            inFlight: inFlight,
            fedMetaCommitsInFlight: fedMeta,
            nativeReplayRequired: nativeReplay,
          ),
          mustDrain,
          reason: 'truth-table mask=$mask',
        );
        expect(
          sfmResumeRecoveryCommands(
            spoolDepth: spool,
            inFlight: inFlight,
            fedMetaCommitsInFlight: fedMeta,
            nativeReplayRequired: nativeReplay,
          ),
          mustDrain
              ? const <SfmResumeRecoveryCommand>[
                  SfmResumeRecoveryCommand.drainReplay,
                  SfmResumeRecoveryCommand.finalize,
                ]
              : const <SfmResumeRecoveryCommand>[
                  SfmResumeRecoveryCommand.resumeExistingDb,
                ],
          reason: 'command-order mask=$mask',
        );
      }
    },
  );

  test('verified worker death clears only for an intact existing DB', () {
    expect(
      sfmRecoveredWorkerDeathCanResume(
        isWorkerDied: true,
        spoolDepth: 0,
        nativeReplayRequired: false,
        durableInputsVerified: true,
      ),
      isTrue,
    );

    for (final rejected in <({bool died, int spool, bool replay, bool ok})>[
      (died: false, spool: 0, replay: false, ok: true),
      (died: true, spool: 1, replay: false, ok: true),
      (died: true, spool: 0, replay: true, ok: true),
      (died: true, spool: 0, replay: false, ok: false),
    ]) {
      expect(
        sfmRecoveredWorkerDeathCanResume(
          isWorkerDied: rejected.died,
          spoolDepth: rejected.spool,
          nativeReplayRequired: rejected.replay,
          durableInputsVerified: rejected.ok,
        ),
        isFalse,
      );
    }
  });

  test('add-frame exception plus worker error emits one failure', () {
    final gate = SfmLiveFailureOnceGate();
    final events = <SfmLiveFailed?>[
      gate.accept('add_frame', 'frame_done(exception)'),
      gate.accept('add_frame', 'worker error for the same exception'),
    ].whereType<SfmLiveFailed>().toList(growable: false);

    expect(events, hasLength(1));
    expect(events.single.stage, 'add_frame');
    expect(events.single.message, 'frame_done(exception)');
  });

  test('durable artifact receipt bypasses replay input revalidation', () {
    expect(
      sfmFinalArtifactCleanupRoute(finalArtifactCommitted: false),
      SfmFinalArtifactCleanupRoute.verifyInputsThenAuthorize,
      reason: 'before receipt every sidecar and gray must still be verified',
    );
    expect(
      sfmFinalArtifactCleanupRoute(finalArtifactCommitted: true),
      SfmFinalArtifactCleanupRoute.continueAuthorizedPurge,
      reason:
          'after receipt missing gray is expected idempotent purge progress',
    );
  });

  test(
    'consumer failure still admits later exact jobs to durable spool',
    () async {
      expect(
        sfmDurableOfferCanPersist(
          cleanupOnly: false,
          disposed: false,
          finalizeRequested: false,
          finalArtifactCommitted: false,
        ),
        isTrue,
      );
      final root = await Directory.systemTemp.createTemp(
        'sfm-later-after-failure-',
      );
      addTearDown(() => root.delete(recursive: true));
      var queue = await SfmDurableFeedQueue.open(root);
      await queue.retainAndBlock(
        const SfmFeedBlock(
          kind: SfmFeedBlockKind.workerDied,
          message: 'first native consumer failed',
          frameId: 'earlier-job',
        ),
      );
      final later = await queue.enqueueGray(
        grayBytes: Uint8List.fromList(const <int>[1, 2, 3, 4]),
        metadata: const <String, Object?>{
          'captureJobId': 'later-committed-job',
          'grayW': 2,
          'grayH': 2,
        },
      );
      expect(queue.blocked, isTrue);
      expect(queue.pendingFrames.map((frame) => frame.id), contains(later.id));
      expect(
        sfmDurableEnqueueOwnsFrame(
          frameId: later.id,
          visibleBlock: queue.blockReason,
        ),
        isTrue,
      );

      final invalidSource = File('${root.path}/short-source.sfm-gray');
      await invalidSource.writeAsBytes(const <int>[7, 8, 9], flush: true);
      final failedCurrent = await queue.enqueueGrayFile(
        sourceGrayFile: invalidSource,
        expectedByteLength: 4,
        metadata: const <String, Object?>{
          'captureJobId': 'must-not-be-owned',
          'grayW': 2,
          'grayH': 2,
        },
      );
      expect(queue.blockReason?.frameId, failedCurrent.id);
      expect(
        sfmDurableEnqueueOwnsFrame(
          frameId: failedCurrent.id,
          visibleBlock: queue.blockReason,
        ),
        isFalse,
      );
      await queue.close();

      queue = await SfmDurableFeedQueue.open(root);
      addTearDown(queue.close);
      final reopened = queue.pendingFrames.singleWhere(
        (frame) => frame.id == later.id,
      );
      expect(reopened.metadata['captureJobId'], 'later-committed-job');
      expect(queue.blockReason?.kind, SfmFeedBlockKind.workerDied);
      expect(
        queue.pendingFrames.any(
          (frame) => frame.metadata['captureJobId'] == 'must-not-be-owned',
        ),
        isFalse,
      );
      expect(await invalidSource.exists(), isTrue);
    },
  );

  test('final receipt force rebuild starts only with a verified DB', () {
    expect(
      sfmFinalReceiptStartRoute(
        finalArtifactCommitted: true,
        forceRebuildFromRetainedDb: false,
        retainedDbRecoverable: true,
      ),
      SfmFinalReceiptStartRoute.cleanupOnly,
    );
    expect(
      sfmFinalReceiptStartRoute(
        finalArtifactCommitted: true,
        forceRebuildFromRetainedDb: true,
        retainedDbRecoverable: false,
      ),
      SfmFinalReceiptStartRoute.refuseInvalidRebuild,
    );
    expect(
      sfmFinalReceiptStartRoute(
        finalArtifactCommitted: true,
        forceRebuildFromRetainedDb: true,
        retainedDbRecoverable: true,
      ),
      SfmFinalReceiptStartRoute.startVerifiedRebuildWorker,
      reason: 'a verified force rebuild must not degrade to cleanup-only',
    );
    expect(
      sfmFinalReceiptStartRoute(
        finalArtifactCommitted: false,
        forceRebuildFromRetainedDb: true,
        retainedDbRecoverable: false,
      ),
      SfmFinalReceiptStartRoute.normalStart,
      reason: 'the force flag has no meaning without a committed receipt',
    );
  });

  test(
    'worker-death DB validation rejects truncated and corrupt SQLite',
    () async {
      final directory = await Directory.systemTemp.createTemp('sfm-db-check-');
      addTearDown(() => directory.delete(recursive: true));
      final valid = '${directory.path}/valid.db';
      final created = await Process.run('/usr/bin/sqlite3', <String>[
        valid,
        'CREATE TABLE cameras(camera_id INTEGER PRIMARY KEY);'
            'CREATE TABLE images(image_id INTEGER PRIMARY KEY);'
            'CREATE TABLE keypoints(image_id INTEGER PRIMARY KEY, data BLOB);'
            'CREATE TABLE descriptors(image_id INTEGER PRIMARY KEY, data BLOB);',
      ]);
      expect(created.exitCode, 0, reason: '${created.stderr}');
      expect(await sfmNativeDbLooksRecoverable(valid), isTrue);

      final truncated = File('${directory.path}/truncated.db');
      await truncated.writeAsBytes(<int>[0x53, 0x51, 0x4c, 0x69, 0x74, 0x65]);
      expect(await sfmNativeDbLooksRecoverable(truncated.path), isFalse);

      final corrupt = File('${directory.path}/corrupt.db');
      await corrupt.writeAsBytes(List<int>.filled(4096, 0x7f));
      expect(await sfmNativeDbLooksRecoverable(corrupt.path), isFalse);

      final wrongSchema = '${directory.path}/wrong-schema.db';
      final wrongCreated = await Process.run('/usr/bin/sqlite3', <String>[
        wrongSchema,
        'CREATE TABLE unrelated(id INTEGER PRIMARY KEY);',
      ]);
      expect(wrongCreated.exitCode, 0, reason: '${wrongCreated.stderr}');
      expect(await sfmNativeDbLooksRecoverable(wrongSchema), isFalse);
    },
  );

  group('fed-only cold native DB recovery', () {
    Future<List<SfmFeedDurableFrame>> makeFedOnly(
      SfmDurableFeedQueue queue,
      int count,
    ) async {
      final frames = <SfmFeedDurableFrame>[];
      for (var i = 0; i < count; i++) {
        final frame = await queue.enqueueGray(
          grayBytes: Uint8List.fromList(<int>[i + 1, i + 2]),
          metadata: <String, Object?>{'captureJobId': 'job-$i'},
        );
        frames.add(frame);
        expect((await queue.claimNext())?.frame.id, frame.id);
        expect(
          await queue.acknowledge(
            frameId: frame.id,
            nativeOk: true,
            fedMeta: <String, Object?>{
              'captureJobId': 'job-$i',
              'nativeFrameId': i,
            },
          ),
          SfmFeedAckDisposition.removeAfterSuccess,
        );
      }
      expect(queue.spoolDepth, 0);
      expect(queue.fedCount, count);
      expect(queue.blocked, isFalse);
      return frames;
    }

    test(
      'no-block missing DB forces all fed frames into fresh replay',
      () async {
        final root = await Directory.systemTemp.createTemp('sfm-fed-nodb-');
        addTearDown(() => root.delete(recursive: true));
        final dbPath = '${root.path}/sfm_live.db';
        final queue = await SfmDurableFeedQueue.open(
          Directory('$dbPath.sfm-feed'),
        );
        addTearDown(queue.close);
        final frames = await makeFedOnly(queue, 3);

        expect(
          await sfmPrepareDurableNativeReplayIfNeeded(
            durableQueue: queue,
            dbPath: dbPath,
          ),
          SfmNativeReplayPreparation.freshReplayPrepared,
        );
        expect(queue.fedCount, 0);
        expect(queue.nativeReplayRequired, isTrue);
        expect(
          queue.pendingFrames.map((frame) => frame.id),
          orderedEquals(frames.map((frame) => frame.id)),
        );
        expect(await File(dbPath).exists(), isFalse);
        expect(queue.blocked, isFalse);
      },
    );

    test('no-block corrupt DB is rotated before fed replay', () async {
      final root = await Directory.systemTemp.createTemp('sfm-fed-corrupt-');
      addTearDown(() => root.delete(recursive: true));
      final dbPath = '${root.path}/sfm_live.db';
      final queue = await SfmDurableFeedQueue.open(
        Directory('$dbPath.sfm-feed'),
      );
      addTearDown(queue.close);
      await makeFedOnly(queue, 2);
      final corrupt = List<int>.filled(4096, 0x6a);
      await File(dbPath).writeAsBytes(corrupt, flush: true);

      expect(
        await sfmPrepareDurableNativeReplayIfNeeded(
          durableQueue: queue,
          dbPath: dbPath,
        ),
        SfmNativeReplayPreparation.freshReplayPrepared,
      );
      expect(await File(dbPath).exists(), isFalse);
      expect(
        await File('$dbPath.pre-replay').readAsBytes(),
        orderedEquals(corrupt),
      );
      expect(queue.spoolDepth, 2);
      expect(queue.nativeReplayRequired, isTrue);
      expect(queue.blocked, isFalse);
    });

    test('missing fed payload fails closed without rotating DB', () async {
      final root = await Directory.systemTemp.createTemp('sfm-fed-missing-');
      addTearDown(() => root.delete(recursive: true));
      final dbPath = '${root.path}/sfm_live.db';
      final queue = await SfmDurableFeedQueue.open(
        Directory('$dbPath.sfm-feed'),
      );
      addTearDown(queue.close);
      final frames = await makeFedOnly(queue, 2);
      await frames.first.grayFile.delete();

      expect(
        await sfmPrepareDurableNativeReplayIfNeeded(
          durableQueue: queue,
          dbPath: dbPath,
        ),
        SfmNativeReplayPreparation.failedClosed,
      );
      expect(queue.fedCount, 2);
      expect(queue.spoolDepth, 0);
      expect(queue.nativeReplayRequired, isFalse);
      expect(queue.blockReason?.kind, SfmFeedBlockKind.replayIncomplete);
      expect(await File('$dbPath.pre-replay').exists(), isFalse);
    });

    test('final receipt never falls back to fed replay', () async {
      final root = await Directory.systemTemp.createTemp('sfm-fed-final-');
      addTearDown(() => root.delete(recursive: true));
      final dbPath = '${root.path}/sfm_live.db';
      final queue = await SfmDurableFeedQueue.open(
        Directory('$dbPath.sfm-feed'),
      );
      addTearDown(queue.close);
      await makeFedOnly(queue, 1);
      expect(await queue.purgeReplayPayloadsAfterFinalArtifact(), isTrue);

      expect(
        await sfmPrepareDurableNativeReplayIfNeeded(
          durableQueue: queue,
          dbPath: dbPath,
        ),
        SfmNativeReplayPreparation.finalArtifactOwnsState,
      );
      expect(queue.finalArtifactCommitted, isTrue);
      expect(queue.spoolDepth, 0);
      expect(queue.nativeReplayRequired, isFalse);
    });
  });

  test(
    'receipt cleanup reopens twice without worker or illegal block',
    () async {
      final capture = await Directory.systemTemp.createTemp(
        'sfm-receipt-live-',
      );
      addTearDown(() => capture.delete(recursive: true));
      final dbPath = '${capture.path}/sfm_live.db';
      final queueDirectory = Directory('$dbPath.sfm-feed');

      var queue = await SfmDurableFeedQueue.open(
        queueDirectory,
        faultInjector: (point, processedPayloads) {
          if (point == SfmFeedQueueFaultPoint.afterReplayPayloadDelete &&
              processedPayloads == 1) {
            throw StateError('injected after receipt and first delete');
          }
        },
      );
      final frame = await queue.enqueueGray(
        grayBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
      );
      expect(await queue.claimNext(), isNotNull);
      expect(
        await queue.acknowledge(
          frameId: frame.id,
          nativeOk: true,
          fedMeta: const <String, Object?>{'nativeFrameId': 0},
        ),
        SfmFeedAckDisposition.removeAfterSuccess,
      );
      await expectLater(
        queue.purgeReplayPayloadsAfterFinalArtifact(),
        throwsStateError,
      );
      expect(queue.finalArtifactCommitted, isTrue);
      expect(queue.replayPurgePending, isTrue);
      expect(queue.blocked, isFalse);
      await queue.close();

      final first = await SfmLiveRecon.start(dbPath: dbPath);
      expect(first, isNotNull);
      expect(first!.isFinalArtifactCleanupOnly, isTrue);
      expect(first.authorizedPurgeError, isNull);
      expect(await first.markFinalArtifactCommitted(), isTrue);
      await first.dispose();

      queue = await SfmDurableFeedQueue.open(queueDirectory);
      expect(queue.finalArtifactCommitted, isTrue);
      expect(queue.replayPurgePending, isFalse);
      expect(queue.blocked, isFalse);
      expect(await frame.grayFile.exists(), isFalse);
      await queue.close();

      final second = await SfmLiveRecon.start(dbPath: dbPath);
      expect(second, isNotNull);
      expect(second!.isFinalArtifactCleanupOnly, isTrue);
      expect(await second.markFinalArtifactCommitted(), isTrue);
      await second.dispose();

      await File(dbPath).writeAsBytes(List<int>.filled(4096, 0x41));
      final refusedRebuild = await SfmLiveRecon.start(
        dbPath: dbPath,
        forceRebuildFromRetainedDb: true,
      );
      expect(
        refusedRebuild,
        isNull,
        reason:
            'a committed receipt cannot make a corrupt retained DB solvable',
      );

      queue = await SfmDurableFeedQueue.open(queueDirectory);
      expect(queue.finalArtifactCommitted, isTrue);
      expect(queue.replayPurgePending, isFalse);
      expect(queue.blocked, isFalse);
      await queue.close();
    },
  );
}
