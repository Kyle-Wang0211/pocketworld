import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/sfm_feed_queue.dart';
import 'package:pocketworld_flutter/capture/sfm_thermal_scheduler.dart';

void main() {
  test('background queue has exactly one outstanding native work item', () {
    expect(kSfmFeedMaxInFlight, 1);
  });

  group('durable queue acknowledgement', () {
    test('only an OK native acknowledgement removes the durable head', () {
      expect(
        sfmFeedAckDisposition(nativeOk: true),
        SfmFeedAckDisposition.removeAfterSuccess,
      );
      expect(
        sfmFeedAckDisposition(nativeOk: false),
        SfmFeedAckDisposition.retainAndBlock,
      );
    });

    test('a retained failed head prevents finalize after in-flight drains', () {
      expect(
        sfmFeedCanSendFinalize(
          finalizeRequested: true,
          finalizeSent: false,
          spoolDepth: 1,
          inFlight: 0,
          queueBlocked: true,
        ),
        isFalse,
      );
      expect(
        sfmFeedCanSendFinalize(
          finalizeRequested: true,
          finalizeSent: false,
          spoolDepth: 0,
          inFlight: 0,
          queueBlocked: true,
        ),
        isFalse,
      );
    });
  });

  test(
    'thermal pause leaves the FIFO head waiting instead of dequeuing it',
    () {
      final decision = decideSfmBackgroundSchedule(
        input: const SfmBackgroundScheduleInput(
          thermalState: 3,
          recentGpuResultCode: null,
          consecutiveGpuFailures: 0,
          queueDepth: 1,
          inFlight: 0,
          cooldownRemaining: Duration.zero,
          finalizeRequested: true,
        ),
      );

      expect(decision.pause, isTrue);
      expect(
        sfmFeedCanPumpNext(
          inFlight: 0,
          spoolDepth: 1,
          consumerPaused: decision.pause,
        ),
        isFalse,
      );
    },
  );

  group('SfmDurableFeedQueue disk contract', () {
    late Directory directory;
    SfmDurableFeedQueue? queue;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('sfm-durable-queue-');
    });

    tearDown(() async {
      await queue?.close();
      if (await directory.exists()) await directory.delete(recursive: true);
    });

    test(
      'moves a committed gray into durable ownership without a copy',
      () async {
        final sourceDirectory = Directory('${directory.path}/photos_highres');
        await sourceDirectory.create();
        final source = File('${sourceDirectory.path}/job.sfm-gray');
        await source.writeAsBytes(<int>[4, 3, 2, 1], flush: true);

        queue = await SfmDurableFeedQueue.open(
          Directory('${directory.path}/sfm_live.db.sfm-feed'),
        );
        final frame = await queue!.enqueueGrayFile(
          sourceGrayFile: source,
          expectedByteLength: 4,
          metadata: const <String, Object?>{'captureJobId': 'move-job'},
        );

        expect(await source.exists(), isFalse);
        expect(
          await frame.grayFile.readAsBytes(),
          orderedEquals(<int>[4, 3, 2, 1]),
        );
        expect(queue!.spoolDepth, 1);
        await queue!.close();

        // Simulate a crash after the recovery descriptor landed but before the
        // source→spool ownership rename became visible.
        await frame.grayFile.rename(source.path);

        queue = await SfmDurableFeedQueue.open(
          Directory('${directory.path}/sfm_live.db.sfm-feed'),
        );
        expect(await source.exists(), isFalse);
        final claim = await queue!.claimNext();
        expect(claim?.frame.id, frame.id);
        expect(claim?.grayBytes, orderedEquals(<int>[4, 3, 2, 1]));
      },
    );

    test('reopens pending frames and claims them in capture order', () async {
      queue = await SfmDurableFeedQueue.open(directory);
      final frames = <SfmFeedDurableFrame>[];
      for (var index = 0; index < 8; index++) {
        frames.add(
          await queue!.enqueueGray(
            grayBytes: Uint8List.fromList(<int>[index, index + 1]),
            metadata: <String, Object?>{'captureJobId': 'job-$index'},
          ),
        );
      }
      expect(
        frames.map((frame) => frame.sequence),
        orderedEquals(List.generate(8, (i) => i)),
      );
      expect(queue!.spoolDepth, 8);
      expect(
        await File('${directory.path}/$kSfmFeedManifestFileName').exists(),
        isTrue,
      );
      await queue!.close();

      queue = await SfmDurableFeedQueue.open(directory);
      expect(
        queue!.pendingFrames.map((frame) => frame.sequence),
        orderedEquals(List.generate(8, (i) => i)),
      );
      final first = await queue!.claimNext();
      expect(first?.frame.id, frames[0].id);
      expect(
        await queue!.claimNext(),
        isNull,
        reason: 'only one native call may be outstanding',
      );

      expect(
        await queue!.acknowledge(
          frameId: first!.frame.id,
          nativeOk: true,
          fedMeta: const <String, Object?>{'nativeFrameId': 21},
        ),
        SfmFeedAckDisposition.removeAfterSuccess,
      );
      final second = await queue!.claimNext();
      expect(second?.frame.id, frames[1].id);
      expect(
        await queue!.acknowledge(
          frameId: second!.frame.id,
          nativeOk: true,
          fedMeta: const <String, Object?>{'nativeFrameId': 22},
        ),
        SfmFeedAckDisposition.removeAfterSuccess,
      );
      final third = await queue!.claimNext();
      expect(third?.frame.id, frames[2].id);
    });

    test(
      'non-OK ACK and missing gray survive reopen and block finalize',
      () async {
        queue = await SfmDurableFeedQueue.open(directory);
        final frame = await queue!.enqueueGray(
          grayBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
          metadata: const <String, Object?>{'captureJobId': 'failed-job'},
        );
        expect((await queue!.claimNext())?.frame.id, frame.id);
        expect(
          await queue!.acknowledge(frameId: frame.id, nativeOk: false),
          SfmFeedAckDisposition.retainAndBlock,
        );
        expect(queue!.spoolDepth, 1);
        expect(queue!.blocked, isTrue);
        expect(
          queue!.canSendFinalize(
            finalizeRequested: true,
            finalizeSent: false,
            inFlight: 0,
          ),
          isFalse,
        );
        await queue!.close();

        queue = await SfmDurableFeedQueue.open(directory);
        expect(queue!.spoolDepth, 1);
        expect(queue!.blockReason?.kind, SfmFeedBlockKind.nativeNonOk);
        expect(await queue!.claimNext(), isNull);
        expect(await queue!.clearBlockForRetry(), isTrue);
        expect((await queue!.claimNext())?.frame.id, frame.id);
        await queue!.close();
        await frame.grayFile.delete();

        queue = await SfmDurableFeedQueue.open(directory);
        expect(queue!.blocked, isTrue);
        expect(queue!.blockReason?.kind, SfmFeedBlockKind.grayReadFailed);
        expect(queue!.spoolDepth, 1);
      },
    );

    test(
      'an OK ACK atomically persists fed metadata and retains replay bytes',
      () async {
        queue = await SfmDurableFeedQueue.open(directory);
        final frame = await queue!.enqueueGray(
          grayBytes: Uint8List.fromList(<int>[9, 8, 7]),
          metadata: const <String, Object?>{'captureJobId': 'ok-job'},
        );
        expect((await queue!.claimNext())?.frame.id, frame.id);
        expect(
          await queue!.acknowledge(
            frameId: frame.id,
            nativeOk: true,
            fedMeta: const <String, Object?>{'nativeFrameId': 41},
          ),
          SfmFeedAckDisposition.removeAfterSuccess,
        );
        expect(queue!.spoolDepth, 0);
        expect(queue!.fedCount, 1);
        expect(await frame.grayFile.exists(), isTrue);
        expect(await frame.descriptorFile.exists(), isTrue);

        final manifest =
            jsonDecode(
                  await File(
                    '${directory.path}/$kSfmFeedManifestFileName',
                  ).readAsString(),
                )
                as Map<String, dynamic>;
        expect(manifest['pending'], isEmpty);
        expect((manifest['fed'] as List).single['id'], frame.id);
        expect(
          (manifest['fed'] as List).single['fedMeta']['nativeFrameId'],
          41,
        );
        expect(
          (manifest['fed'] as List).single['fedMeta']['sfmGraySha256'],
          frame.metadata['sfmGraySha256'],
        );
        await queue!.close();

        queue = await SfmDurableFeedQueue.open(directory);
        expect(queue!.spoolDepth, 0);
        expect(queue!.fedCount, 1);
        expect(await frame.grayFile.exists(), isTrue);
        expect(await frame.descriptorFile.exists(), isTrue);
        expect(
          await queue!.acknowledge(frameId: frame.id, nativeOk: true),
          SfmFeedAckDisposition.removeAfterSuccess,
          reason: 'retrying an already committed OK ACK is idempotent',
        );
        expect(await queue!.verifyFedReplayPayloadsForFinalCommit(), isTrue);
        expect(await queue!.purgeReplayPayloadsAfterFinalArtifact(), isTrue);
        expect(await frame.grayFile.exists(), isFalse);
        expect(await frame.descriptorFile.exists(), isFalse);
        expect(queue!.finalArtifactCommitted, isTrue);
        expect(queue!.replayPurgePending, isFalse);
      },
    );

    test(
      'final commit verification blocks post-ACK same-length corruption',
      () async {
        final original = Uint8List.fromList(<int>[3, 6, 9, 12]);
        queue = await SfmDurableFeedQueue.open(directory);
        final frame = await queue!.enqueueGray(
          grayBytes: original,
          metadata: const <String, Object?>{
            'captureJobId': 'final-integrity-job',
            'grayW': 2,
            'grayH': 2,
          },
        );
        expect((await queue!.claimNext())?.frame.id, frame.id);
        expect(
          await queue!.acknowledge(
            frameId: frame.id,
            nativeOk: true,
            fedMeta: const <String, Object?>{
              'captureJobId': 'final-integrity-job',
              'nativeFrameId': 1,
              'grayW': 2,
              'grayH': 2,
            },
          ),
          SfmFeedAckDisposition.removeAfterSuccess,
        );
        final descriptor = Map<String, dynamic>.from(
          jsonDecode(await frame.descriptorFile.readAsString()) as Map,
        );
        (descriptor['metadata'] as Map).remove('sfmGraySha256');
        await frame.descriptorFile.writeAsString(
          jsonEncode(descriptor),
          flush: true,
        );
        await frame.grayFile.writeAsBytes(<int>[12, 9, 6, 3], flush: true);

        expect(await queue!.verifyFedReplayPayloadsForFinalCommit(), isFalse);
        expect(queue!.fedCount, 1);
        expect(queue!.blockReason?.kind, SfmFeedBlockKind.replayIncomplete);
        expect(queue!.blockReason?.frameId, frame.id);
        expect(await queue!.purgeReplayPayloadsAfterFinalArtifact(), isFalse);
        expect(await frame.grayFile.exists(), isTrue);
        expect(await frame.descriptorFile.exists(), isTrue);
        await queue!.close();

        queue = await SfmDurableFeedQueue.open(directory);
        expect(queue!.fedCount, 1);
        expect(queue!.blockReason?.kind, SfmFeedBlockKind.replayIncomplete);
        expect(await frame.grayFile.exists(), isTrue);
      },
    );

    test(
      'crash before artifact receipt persists deletes nothing and retries',
      () async {
        final userFiles = await _writeUserPhotoAndSidecar(directory);
        queue = await SfmDurableFeedQueue.open(
          directory,
          faultInjector: (point, _) {
            if (point ==
                SfmFeedQueueFaultPoint.beforeFinalArtifactCommitPersist) {
              throw StateError('injected before receipt publish');
            }
          },
        );
        final frames = await _enqueueAndAck(queue!, 2);

        await expectLater(
          queue!.purgeReplayPayloadsAfterFinalArtifact(),
          throwsStateError,
        );
        expect(queue!.finalArtifactCommitted, isFalse);
        expect(queue!.replayPurgePending, isFalse);
        for (final frame in frames) {
          expect(await frame.grayFile.exists(), isTrue);
          expect(await frame.descriptorFile.exists(), isTrue);
        }
        await _expectUserFilesUntouched(userFiles);
        await queue!.close();

        queue = await SfmDurableFeedQueue.open(directory);
        expect(await queue!.purgeReplayPayloadsAfterFinalArtifact(), isTrue);
        expect(queue!.finalArtifactCommitted, isTrue);
        expect(queue!.replayPurgePending, isFalse);
        await _expectReplayPayloadsAbsent(frames);
        await _expectUserFilesUntouched(userFiles);
      },
    );

    test(
      'receipt survives crash after half cleanup and reopen resumes purge',
      () async {
        final userFiles = await _writeUserPhotoAndSidecar(directory);
        queue = await SfmDurableFeedQueue.open(
          directory,
          faultInjector: (point, processedPayloads) {
            if (point == SfmFeedQueueFaultPoint.afterReplayPayloadDelete &&
                processedPayloads == 2) {
              throw StateError('injected after half cleanup');
            }
          },
        );
        final frames = await _enqueueAndAck(queue!, 2);

        await expectLater(
          queue!.purgeReplayPayloadsAfterFinalArtifact(),
          throwsStateError,
        );
        expect(queue!.finalArtifactCommitted, isTrue);
        expect(queue!.replayPurgePending, isTrue);
        expect(await frames.first.grayFile.exists(), isFalse);
        expect(await frames.first.descriptorFile.exists(), isFalse);
        expect(await frames.last.grayFile.exists(), isTrue);
        expect(await frames.last.descriptorFile.exists(), isTrue);
        await _expectUserFilesUntouched(userFiles);
        await queue!.close();

        queue = await SfmDurableFeedQueue.open(directory);
        expect(queue!.finalArtifactCommitted, isTrue);
        expect(queue!.replayPurgePending, isTrue);
        expect(await queue!.purgeReplayPayloadsAfterFinalArtifact(), isTrue);
        expect(await queue!.purgeReplayPayloadsAfterFinalArtifact(), isTrue);
        expect(queue!.replayPurgePending, isFalse);
        await _expectReplayPayloadsAbsent(frames);
        await _expectUserFilesUntouched(userFiles);
      },
    );

    test(
      'all payloads gone with pending marker completes idempotently on reopen',
      () async {
        final userFiles = await _writeUserPhotoAndSidecar(directory);
        queue = await SfmDurableFeedQueue.open(
          directory,
          faultInjector: (point, _) {
            if (point ==
                SfmFeedQueueFaultPoint.beforeReplayPurgeCompletePersist) {
              throw StateError('injected before purge completion publish');
            }
          },
        );
        final frames = await _enqueueAndAck(queue!, 3);

        await expectLater(
          queue!.purgeReplayPayloadsAfterFinalArtifact(),
          throwsStateError,
        );
        expect(queue!.finalArtifactCommitted, isTrue);
        expect(queue!.replayPurgePending, isTrue);
        await _expectReplayPayloadsAbsent(frames);
        await _expectUserFilesUntouched(userFiles);
        await queue!.close();

        queue = await SfmDurableFeedQueue.open(directory);
        expect(queue!.replayPurgePending, isTrue);
        expect(await queue!.purgeReplayPayloadsAfterFinalArtifact(), isTrue);
        expect(queue!.replayPurgePending, isFalse);
        expect(await queue!.purgeReplayPayloadsAfterFinalArtifact(), isTrue);
        await expectLater(
          queue!.enqueueGray(grayBytes: Uint8List.fromList(<int>[9])),
          throwsStateError,
        );
        await _expectReplayPayloadsAbsent(frames);
        await _expectUserFilesUntouched(userFiles);
      },
    );

    for (final legacySchema in const <int>[1, 2]) {
      test(
        'adopts intact schema $legacySchema final state into receipt transaction',
        () async {
          final userFiles = await _writeUserPhotoAndSidecar(directory);
          queue = await SfmDurableFeedQueue.open(directory);
          final frames = await _enqueueAndAck(queue!, 2);
          await queue!.close();
          await _downgradeManifest(directory, legacySchema);

          queue = await SfmDurableFeedQueue.open(directory);
          expect(queue!.requiresLegacyFinalArtifactAdoption, isTrue);
          expect(
            await queue!.purgeReplayPayloadsAfterFinalArtifact(),
            isFalse,
            reason:
                'legacy cleanup requires the explicit verified-artifact API',
          );
          expect(await queue!.adoptLegacyFinalArtifact(), isTrue);
          expect(queue!.requiresLegacyFinalArtifactAdoption, isFalse);
          expect(queue!.finalArtifactCommitted, isTrue);
          expect(queue!.replayPurgePending, isFalse);
          await _expectReplayPayloadsAbsent(frames);
          await _expectUserFilesUntouched(userFiles);

          final manifest = await _readManifest(directory);
          expect(manifest['schemaVersion'], 3);
          expect(manifest['finalArtifactCommitted'], isTrue);
          expect(manifest['replayPurgePending'], isFalse);
          await queue!.close();

          queue = await SfmDurableFeedQueue.open(directory);
          expect(queue!.finalArtifactCommitted, isTrue);
          expect(queue!.replayPurgePending, isFalse);
          expect(await queue!.purgeReplayPayloadsAfterFinalArtifact(), isTrue);
          await _expectUserFilesUntouched(userFiles);
        },
      );
    }

    test(
      'adopts uniformly absent legacy payloads left by old successful purge',
      () async {
        final userFiles = await _writeUserPhotoAndSidecar(directory);
        queue = await SfmDurableFeedQueue.open(directory);
        final frames = await _enqueueAndAck(queue!, 3);
        await queue!.close();
        await _expectAndDeleteReplayPayloads(frames);
        await _downgradeManifest(directory, 2);

        queue = await SfmDurableFeedQueue.open(directory);
        expect(queue!.requiresLegacyFinalArtifactAdoption, isTrue);
        expect(await queue!.adoptLegacyFinalArtifact(), isTrue);
        expect(queue!.finalArtifactCommitted, isTrue);
        expect(queue!.replayPurgePending, isFalse);
        await _expectReplayPayloadsAbsent(frames);
        await _expectUserFilesUntouched(userFiles);
      },
    );

    test(
      'legacy adoption receipts and finishes a partial gray cleanup',
      () async {
        final userFiles = await _writeUserPhotoAndSidecar(directory);
        queue = await SfmDurableFeedQueue.open(directory);
        final frames = await _enqueueAndAck(queue!, 2);
        await queue!.close();
        await frames.first.grayFile.delete();
        await _downgradeManifest(directory, 2);

        queue = await SfmDurableFeedQueue.open(directory);
        expect(await queue!.adoptLegacyFinalArtifact(), isTrue);
        expect(queue!.finalArtifactCommitted, isTrue);
        expect(queue!.replayPurgePending, isFalse);
        await _expectReplayPayloadsAbsent(frames);
        await _expectUserFilesUntouched(userFiles);
      },
    );

    test(
      'legacy adoption finishes mixed rows and stale descriptor remnants',
      () async {
        final userFiles = await _writeUserPhotoAndSidecar(directory);
        queue = await SfmDurableFeedQueue.open(directory);
        final frames = await _enqueueAndAck(queue!, 3);
        await queue!.close();
        await frames.first.grayFile.delete();
        await frames.first.descriptorFile.delete();
        await frames[1].descriptorFile.writeAsString('not-json', flush: true);
        await _downgradeManifest(directory, 1);

        queue = await SfmDurableFeedQueue.open(directory);
        expect(await queue!.adoptLegacyFinalArtifact(), isTrue);
        expect(queue!.finalArtifactCommitted, isTrue);
        await _expectReplayPayloadsAbsent(frames);
        await _expectUserFilesUntouched(userFiles);
      },
    );

    test('legacy adoption removes a corrupt stale fed descriptor', () async {
      final userFiles = await _writeUserPhotoAndSidecar(directory);
      queue = await SfmDurableFeedQueue.open(directory);
      final frames = await _enqueueAndAck(queue!, 1);
      await queue!.close();
      await frames.single.descriptorFile.writeAsString(
        '{"id":"wrong"}',
        flush: true,
      );
      await _downgradeManifest(directory, 2);

      queue = await SfmDurableFeedQueue.open(directory);
      expect(await queue!.adoptLegacyFinalArtifact(), isTrue);
      expect(queue!.finalArtifactCommitted, isTrue);
      await _expectReplayPayloadsAbsent(frames);
      await _expectUserFilesUntouched(userFiles);
    });

    test('legacy pending/non-OK state cannot adopt a final artifact', () async {
      final userFiles = await _writeUserPhotoAndSidecar(directory);
      queue = await SfmDurableFeedQueue.open(directory);
      final frame = await queue!.enqueueGray(
        grayBytes: Uint8List.fromList(<int>[8, 6, 4, 2]),
      );
      expect((await queue!.claimNext())?.frame.id, frame.id);
      expect(
        await queue!.acknowledge(frameId: frame.id, nativeOk: false),
        SfmFeedAckDisposition.retainAndBlock,
      );
      await queue!.close();
      await _downgradeManifest(directory, 2);

      queue = await SfmDurableFeedQueue.open(directory);
      expect(queue!.spoolDepth, 1);
      expect(queue!.blockReason?.kind, SfmFeedBlockKind.nativeNonOk);
      expect(await queue!.adoptLegacyFinalArtifact(), isFalse);
      expect(queue!.finalArtifactCommitted, isFalse);
      expect(await frame.grayFile.exists(), isTrue);
      expect(await frame.descriptorFile.exists(), isTrue);
      await _expectUserFilesUntouched(userFiles);
    });

    test(
      'legacy receipt survives half cleanup and schema3 reopen resumes it',
      () async {
        final userFiles = await _writeUserPhotoAndSidecar(directory);
        queue = await SfmDurableFeedQueue.open(directory);
        final frames = await _enqueueAndAck(queue!, 2);
        await queue!.close();
        await _downgradeManifest(directory, 2);

        queue = await SfmDurableFeedQueue.open(
          directory,
          faultInjector: (point, processedPayloads) {
            if (point == SfmFeedQueueFaultPoint.afterReplayPayloadDelete &&
                processedPayloads == 2) {
              throw StateError('injected legacy half cleanup');
            }
          },
        );
        await expectLater(queue!.adoptLegacyFinalArtifact(), throwsStateError);
        expect(queue!.requiresLegacyFinalArtifactAdoption, isFalse);
        expect(queue!.finalArtifactCommitted, isTrue);
        expect(queue!.replayPurgePending, isTrue);
        await queue!.close();

        queue = await SfmDurableFeedQueue.open(directory);
        expect(queue!.finalArtifactCommitted, isTrue);
        expect(queue!.replayPurgePending, isTrue);
        expect(await queue!.purgeReplayPayloadsAfterFinalArtifact(), isTrue);
        await _expectReplayPayloadsAbsent(frames);
        await _expectUserFilesUntouched(userFiles);
      },
    );

    test('committed schema3 queue cannot persist a later block', () async {
      queue = await SfmDurableFeedQueue.open(directory);
      final frames = await _enqueueAndAck(queue!, 1);
      expect(await queue!.purgeReplayPayloadsAfterFinalArtifact(), isTrue);
      final manifest = File('${directory.path}/$kSfmFeedManifestFileName');
      final before = await manifest.readAsBytes();

      await expectLater(
        queue!.retainAndBlock(
          const SfmFeedBlock(
            kind: SfmFeedBlockKind.workerDied,
            message: 'invalid terminal mutation',
          ),
        ),
        throwsStateError,
      );
      expect(await manifest.readAsBytes(), orderedEquals(before));
      expect(queue!.blocked, isFalse);
      await _expectReplayPayloadsAbsent(frames);
      await queue!.close();

      queue = await SfmDurableFeedQueue.open(directory);
      expect(queue!.finalArtifactCommitted, isTrue);
      expect(queue!.blocked, isFalse);
    });

    test(
      'pending and durable worker failure still refuse artifact commit',
      () async {
        final userFiles = await _writeUserPhotoAndSidecar(directory);
        queue = await SfmDurableFeedQueue.open(directory);
        final frame = await queue!.enqueueGray(
          grayBytes: Uint8List.fromList(<int>[1, 3, 5]),
        );
        await queue!.retainAndBlock(
          const SfmFeedBlock(
            kind: SfmFeedBlockKind.workerDied,
            message: 'injected worker exit',
          ),
        );

        expect(await queue!.purgeReplayPayloadsAfterFinalArtifact(), isFalse);
        expect(queue!.finalArtifactCommitted, isFalse);
        expect(queue!.replayPurgePending, isFalse);
        expect(await frame.grayFile.exists(), isTrue);
        expect(await frame.descriptorFile.exists(), isTrue);
        await _expectUserFilesUntouched(userFiles);
      },
    );

    test(
      'restart rewinds fed plus pending frames for a fresh native DB replay',
      () async {
        queue = await SfmDurableFeedQueue.open(directory);
        final first = await queue!.enqueueGray(
          grayBytes: Uint8List.fromList(<int>[1]),
          metadata: const <String, Object?>{'captureJobId': 'job-0'},
        );
        final second = await queue!.enqueueGray(
          grayBytes: Uint8List.fromList(<int>[2]),
          metadata: const <String, Object?>{'captureJobId': 'job-1'},
        );
        expect((await queue!.claimNext())?.frame.id, first.id);
        expect(
          await queue!.acknowledge(
            frameId: first.id,
            nativeOk: true,
            fedMeta: const <String, Object?>{
              'captureJobId': 'job-0',
              'nativeFrameId': 0,
            },
          ),
          SfmFeedAckDisposition.removeAfterSuccess,
        );
        await queue!.retainAndBlock(
          const SfmFeedBlock(
            kind: SfmFeedBlockKind.workerDied,
            message: 'process died before second ACK',
          ),
        );
        await queue!.close();

        queue = await SfmDurableFeedQueue.open(directory);
        expect(await queue!.prepareAllForFreshNativeReplay(), isTrue);
        expect(queue!.nativeReplayRequired, isTrue);
        expect(queue!.fedCount, 0);
        expect(
          queue!.pendingFrames.map((frame) => frame.sequence),
          orderedEquals(<int>[0, 1]),
        );
        expect(queue!.blocked, isFalse);
        expect((await queue!.claimNext())?.frame.id, first.id);
        expect(await queue!.claimNext(), isNull);
        expect(
          await queue!.acknowledge(
            frameId: first.id,
            nativeOk: true,
            fedMeta: const <String, Object?>{'nativeFrameId': 0},
          ),
          SfmFeedAckDisposition.removeAfterSuccess,
        );
        expect(queue!.nativeReplayRequired, isTrue);
        expect((await queue!.claimNext())?.frame.id, second.id);
        expect(
          await queue!.acknowledge(
            frameId: second.id,
            nativeOk: true,
            fedMeta: const <String, Object?>{'nativeFrameId': 1},
          ),
          SfmFeedAckDisposition.removeAfterSuccess,
        );
        expect(queue!.nativeReplayRequired, isFalse);
      },
    );

    test(
      'forced fresh replay rewinds a complete fed-only queue after DB loss',
      () async {
        final userFiles = await _writeUserPhotoAndSidecar(directory);
        queue = await SfmDurableFeedQueue.open(directory);
        final frames = await _enqueueAndAck(queue!, 3);
        expect(queue!.spoolDepth, 0);
        expect(queue!.fedCount, 3);

        expect(await queue!.prepareAllForFreshNativeReplay(), isTrue);
        expect(queue!.spoolDepth, 0);
        expect(queue!.fedCount, 3);
        expect(await queue!.prepareAllForForcedFreshNativeReplay(), isTrue);
        expect(queue!.nativeReplayRequired, isTrue);
        expect(queue!.fedCount, 0);
        expect(
          queue!.pendingFrames.map((frame) => frame.id),
          orderedEquals(frames.map((frame) => frame.id)),
        );
        await queue!.close();

        queue = await SfmDurableFeedQueue.open(directory);
        expect(queue!.nativeReplayRequired, isTrue);
        expect(
          queue!.pendingFrames.map((frame) => frame.sequence),
          orderedEquals(<int>[0, 1, 2]),
        );
        await _expectUserFilesUntouched(userFiles);
      },
    );

    test(
      'forced fed-only replay fails closed when a replay gray is missing',
      () async {
        final userFiles = await _writeUserPhotoAndSidecar(directory);
        queue = await SfmDurableFeedQueue.open(directory);
        final frames = await _enqueueAndAck(queue!, 2);
        await frames.first.grayFile.delete();

        expect(await queue!.prepareAllForForcedFreshNativeReplay(), isFalse);
        expect(queue!.spoolDepth, 0);
        expect(queue!.fedCount, 2);
        expect(queue!.nativeReplayRequired, isFalse);
        expect(queue!.blockReason?.kind, SfmFeedBlockKind.replayIncomplete);
        expect(await frames.last.grayFile.exists(), isTrue);
        expect(await frames.last.descriptorFile.exists(), isTrue);
        await _expectUserFilesUntouched(userFiles);
        await queue!.close();

        queue = await SfmDurableFeedQueue.open(directory);
        expect(queue!.fedCount, 2);
        expect(queue!.blockReason?.kind, SfmFeedBlockKind.replayIncomplete);
      },
    );

    test('forced fed-only replay blocks same-length gray corruption', () async {
      final original = Uint8List.fromList(<int>[1, 2, 3, 4]);
      queue = await SfmDurableFeedQueue.open(directory);
      final frame = await queue!.enqueueGray(
        grayBytes: original,
        metadata: <String, Object?>{
          'captureJobId': 'hashed-job',
          'sfmGraySha256': sha256.convert(original).toString(),
        },
      );
      expect((await queue!.claimNext())?.frame.id, frame.id);
      expect(
        await queue!.acknowledge(
          frameId: frame.id,
          nativeOk: true,
          fedMeta: <String, Object?>{...frame.metadata, 'nativeFrameId': 1},
        ),
        SfmFeedAckDisposition.removeAfterSuccess,
      );
      final descriptor = Map<String, dynamic>.from(
        jsonDecode(await frame.descriptorFile.readAsString()) as Map,
      );
      (descriptor['metadata'] as Map).remove('sfmGraySha256');
      await frame.descriptorFile.writeAsString(
        jsonEncode(descriptor),
        flush: true,
      );
      await frame.grayFile.writeAsBytes(<int>[4, 3, 2, 1], flush: true);

      expect(await queue!.prepareAllForForcedFreshNativeReplay(), isFalse);
      expect(queue!.spoolDepth, 0);
      expect(queue!.fedCount, 1);
      expect(queue!.nativeReplayRequired, isFalse);
      expect(queue!.blockReason?.kind, SfmFeedBlockKind.replayIncomplete);
      expect(queue!.blockReason?.frameId, frame.id);
      await queue!.close();

      queue = await SfmDurableFeedQueue.open(directory);
      expect(queue!.fedCount, 1);
      expect(queue!.blockReason?.kind, SfmFeedBlockKind.replayIncomplete);
      expect(await frame.grayFile.exists(), isTrue);
    });

    test('ordinary claim blocks same-length gray corruption', () async {
      final original = Uint8List.fromList(<int>[9, 8, 7, 6]);
      queue = await SfmDurableFeedQueue.open(directory);
      final frame = await queue!.enqueueGray(
        grayBytes: original,
        metadata: <String, Object?>{
          'captureJobId': 'pending-hashed-job',
          'sfmGraySha256': sha256.convert(original).toString(),
        },
      );
      await frame.grayFile.writeAsBytes(<int>[6, 7, 8, 9], flush: true);

      expect(await queue!.claimNext(), isNull);
      expect(queue!.spoolDepth, 1);
      expect(queue!.blockReason?.kind, SfmFeedBlockKind.grayReadFailed);
      expect(queue!.blockReason?.frameId, frame.id);
      await queue!.close();

      queue = await SfmDurableFeedQueue.open(directory);
      expect(queue!.spoolDepth, 1);
      expect(queue!.blockReason?.kind, SfmFeedBlockKind.grayReadFailed);
    });

    test(
      'claim preserves descriptor digest when a legacy manifest lacks it',
      () async {
        final original = Uint8List.fromList(<int>[11, 22, 33, 44]);
        queue = await SfmDurableFeedQueue.open(directory);
        final frame = await queue!.enqueueGray(
          grayBytes: original,
          metadata: const <String, Object?>{
            'captureJobId': 'descriptor-hashed-job',
          },
        );
        await queue!.close();
        final manifestFile = File(
          '${directory.path}/$kSfmFeedManifestFileName',
        );
        final manifest = await _readManifest(directory);
        final pending = (manifest['pending'] as List).single as Map;
        (pending['metadata'] as Map).remove('sfmGraySha256');
        await manifestFile.writeAsString(jsonEncode(manifest), flush: true);
        await frame.grayFile.writeAsBytes(<int>[44, 33, 22, 11], flush: true);

        queue = await SfmDurableFeedQueue.open(directory);
        expect(await queue!.claimNext(), isNull);
        expect(queue!.spoolDepth, 1);
        expect(queue!.blockReason?.kind, SfmFeedBlockKind.grayReadFailed);
        expect(queue!.blockReason?.frameId, frame.id);
      },
    );

    test(
      'full replay preserves descriptor digest when pending manifest lacks it',
      () async {
        final original = Uint8List.fromList(<int>[12, 24, 36, 48]);
        queue = await SfmDurableFeedQueue.open(directory);
        final frame = await queue!.enqueueGray(
          grayBytes: original,
          metadata: const <String, Object?>{
            'captureJobId': 'pending-descriptor-hashed-job',
          },
        );
        await queue!.close();
        final manifestFile = File(
          '${directory.path}/$kSfmFeedManifestFileName',
        );
        final manifest = await _readManifest(directory);
        final pending = (manifest['pending'] as List).single as Map;
        (pending['metadata'] as Map).remove('sfmGraySha256');
        await manifestFile.writeAsString(jsonEncode(manifest), flush: true);
        await frame.grayFile.writeAsBytes(<int>[48, 36, 24, 12], flush: true);

        queue = await SfmDurableFeedQueue.open(directory);
        expect(await queue!.prepareAllForFreshNativeReplay(), isFalse);
        expect(queue!.spoolDepth, 1);
        expect(queue!.nativeReplayRequired, isFalse);
        expect(queue!.blockReason?.kind, SfmFeedBlockKind.replayIncomplete);
        expect(queue!.blockReason?.frameId, frame.id);
      },
    );

    test('legacy hashless pending claim durably records its digest', () async {
      final original = Uint8List.fromList(<int>[10, 20, 30, 40]);
      queue = await SfmDurableFeedQueue.open(directory);
      final frame = await queue!.enqueueGray(
        grayBytes: original,
        metadata: const <String, Object?>{'captureJobId': 'legacy-job'},
      );
      await queue!.close();

      final manifestFile = File('${directory.path}/$kSfmFeedManifestFileName');
      final manifest = await _readManifest(directory);
      final pending = (manifest['pending'] as List).single as Map;
      (pending['metadata'] as Map).remove('sfmGraySha256');
      await manifestFile.writeAsString(jsonEncode(manifest), flush: true);
      final descriptor = Map<String, dynamic>.from(
        jsonDecode(await frame.descriptorFile.readAsString()) as Map,
      );
      (descriptor['metadata'] as Map).remove('sfmGraySha256');
      await frame.descriptorFile.writeAsString(
        jsonEncode(descriptor),
        flush: true,
      );

      queue = await SfmDurableFeedQueue.open(directory);
      final claim = await queue!.claimNext();
      expect(claim?.frame.id, frame.id);
      final expectedDigest = sha256.convert(original).toString();
      expect(claim?.frame.metadata['sfmGraySha256'], expectedDigest);
      final migratedManifest = await _readManifest(directory);
      final migratedPending =
          (migratedManifest['pending'] as List).single as Map;
      expect(
        (migratedPending['metadata'] as Map)['sfmGraySha256'],
        expectedDigest,
      );
      final migratedDescriptor =
          jsonDecode(await frame.descriptorFile.readAsString()) as Map;
      expect(
        (migratedDescriptor['metadata'] as Map)['sfmGraySha256'],
        expectedDigest,
      );
    });

    test(
      'committed final artifact can never be forced back to replay',
      () async {
        queue = await SfmDurableFeedQueue.open(directory);
        await _enqueueAndAck(queue!, 1);
        expect(await queue!.purgeReplayPayloadsAfterFinalArtifact(), isTrue);
        final manifest = File('${directory.path}/$kSfmFeedManifestFileName');
        final before = await manifest.readAsBytes();

        expect(await queue!.prepareAllForForcedFreshNativeReplay(), isFalse);
        expect(await manifest.readAsBytes(), orderedEquals(before));
        expect(queue!.finalArtifactCommitted, isTrue);
        expect(queue!.spoolDepth, 0);
      },
    );

    test('fresh native replay rotates an existing DB exactly once', () async {
      final db = File('${directory.path}/sfm_live.db');
      await db.writeAsBytes(<int>[1, 2, 3], flush: true);
      await prepareSfmNativeDbForFreshReplay(db.path);
      expect(await db.exists(), isFalse);
      final backup = File('${db.path}.pre-replay');
      expect(await backup.readAsBytes(), orderedEquals(<int>[1, 2, 3]));

      await db.writeAsBytes(<int>[4, 5], flush: true);
      await prepareSfmNativeDbForFreshReplay(db.path);
      expect(await db.exists(), isFalse);
      expect(
        await backup.readAsBytes(),
        orderedEquals(<int>[1, 2, 3]),
        reason: 'the first complete source DB remains the recovery backup',
      );
      await purgeSfmNativeReplayBackup(db.path);
      expect(await backup.exists(), isFalse);
    });

    test(
      'an ACK for a frame never claimed by native cannot consume it',
      () async {
        queue = await SfmDurableFeedQueue.open(directory);
        final frame = await queue!.enqueueGray(
          grayBytes: Uint8List.fromList(<int>[5]),
        );
        expect(
          await queue!.acknowledge(frameId: frame.id, nativeOk: true),
          SfmFeedAckDisposition.retainAndBlock,
        );
        expect(queue!.spoolDepth, 1);
        expect(
          queue!.blockReason?.kind,
          SfmFeedBlockKind.invalidAcknowledgement,
        );
        expect(await frame.grayFile.exists(), isTrue);
      },
    );

    test(
      'replays descriptor committed before a lost manifest publish',
      () async {
        queue = await SfmDurableFeedQueue.open(directory);
        final frame = await queue!.enqueueGray(
          grayBytes: Uint8List.fromList(<int>[6, 7]),
          metadata: const <String, Object?>{'captureJobId': 'replay-job'},
        );
        await queue!.close();
        await File('${directory.path}/$kSfmFeedManifestFileName').delete();

        queue = await SfmDurableFeedQueue.open(directory);
        expect(queue!.spoolDepth, 1);
        expect(queue!.pendingFrames.single.id, frame.id);
        expect(
          queue!.pendingFrames.single.metadata['captureJobId'],
          'replay-job',
        );
        expect(
          (await queue!.claimNext())?.grayBytes,
          orderedEquals(<int>[6, 7]),
        );
      },
    );

    test('unexpected worker death is fail-closed across reopen', () async {
      queue = await SfmDurableFeedQueue.open(directory);
      await queue!.enqueueGray(grayBytes: Uint8List.fromList(<int>[4, 2]));
      await queue!.retainAndBlock(
        const SfmFeedBlock(
          kind: SfmFeedBlockKind.workerDied,
          message: 'isolate exited before ACK',
        ),
      );
      expect(queue!.blocked, isTrue);
      expect(
        queue!.canSendFinalize(
          finalizeRequested: true,
          finalizeSent: false,
          inFlight: 0,
        ),
        isFalse,
      );
      await queue!.close();

      queue = await SfmDurableFeedQueue.open(directory);
      expect(queue!.blockReason?.kind, SfmFeedBlockKind.workerDied);
      expect(queue!.spoolDepth, 1);
      expect(await queue!.claimNext(), isNull);
    });

    test(
      'active-job replay excludes deleted jobs and survives reopen',
      () async {
        queue = await SfmDurableFeedQueue.open(directory);
        final frames = <SfmFeedDurableFrame>[];
        for (final job in <String>['job-a', 'job-b']) {
          final frame = await queue!.enqueueGray(
            grayBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
            metadata: <String, Object?>{
              'captureJobId': job,
              'grayW': 2,
              'grayH': 2,
            },
          );
          frames.add(frame);
          expect((await queue!.claimNext())?.frame.id, frame.id);
          expect(
            await queue!.acknowledge(
              frameId: frame.id,
              nativeOk: true,
              fedMeta: <String, Object?>{
                'captureJobId': job,
                'nativeFrameId': frames.length,
                'grayW': 2,
                'grayH': 2,
              },
            ),
            SfmFeedAckDisposition.removeAfterSuccess,
          );
        }
        final frameC = await queue!.enqueueGray(
          grayBytes: Uint8List.fromList(<int>[5, 6, 7, 8]),
          metadata: const <String, Object?>{
            'captureJobId': 'job-c',
            'grayW': 2,
            'grayH': 2,
          },
        );
        frames.add(frameC);

        expect(
          await queue!.prepareActiveJobsForFreshNativeReplay(const <String>{
            'job-a',
            'job-c',
          }),
          isTrue,
        );
        expect(queue!.fedCount, 0);
        expect(queue!.nativeReplayRequired, isTrue);
        expect(
          queue!.pendingFrames.map((frame) => frame.metadata['captureJobId']),
          orderedEquals(<String>['job-a', 'job-c']),
        );
        final excludedMarker = File(
          '${directory.path}/${frames[1].id}.excluded.json',
        );
        expect(await excludedMarker.exists(), isTrue);
        await queue!.close();

        queue = await SfmDurableFeedQueue.open(directory);
        expect(
          queue!.pendingFrames.map((frame) => frame.metadata['captureJobId']),
          orderedEquals(<String>['job-a', 'job-c']),
          reason: 'excluded descriptor must not resurrect on cold open',
        );
        for (final frame in queue!.pendingFrames.toList()) {
          expect((await queue!.claimNext())?.frame.id, frame.id);
          expect(
            await queue!.acknowledge(
              frameId: frame.id,
              nativeOk: true,
              fedMeta: <String, Object?>{
                ...frame.metadata,
                'nativeFrameId': frame.sequence,
              },
            ),
            SfmFeedAckDisposition.removeAfterSuccess,
          );
        }
        expect(await queue!.purgeReplayPayloadsAfterFinalArtifact(), isTrue);
        expect(await frames[1].grayFile.exists(), isFalse);
        expect(await frames[1].descriptorFile.exists(), isFalse);
        expect(await excludedMarker.exists(), isFalse);
      },
    );

    test(
      'failed active-job replay leaves the manifest generation unchanged',
      () async {
        queue = await SfmDurableFeedQueue.open(directory);
        final active = await queue!.enqueueGray(
          grayBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
          metadata: const <String, Object?>{
            'captureJobId': 'active-job',
            'grayW': 2,
            'grayH': 2,
          },
        );
        await queue!.enqueueGray(
          grayBytes: Uint8List.fromList(<int>[5, 6, 7, 8]),
          metadata: const <String, Object?>{
            'captureJobId': 'excluded-job',
            'grayW': 2,
            'grayH': 2,
          },
        );
        final manifest = File('${directory.path}/$kSfmFeedManifestFileName');
        final before = await manifest.readAsBytes();
        await active.grayFile.delete();

        expect(
          await queue!.prepareActiveJobsForFreshNativeReplay(const <String>{
            'active-job',
          }),
          isFalse,
        );
        expect(await manifest.readAsBytes(), orderedEquals(before));
        expect(queue!.spoolDepth, 2);
        expect(
          await File(
            '${directory.path}/frame-00000000000000000001.excluded.json',
          ).exists(),
          isFalse,
        );
      },
    );

    test('active-job replay blocks same-length gray corruption', () async {
      queue = await SfmDurableFeedQueue.open(directory);
      final original = Uint8List.fromList(<int>[1, 3, 5, 7]);
      final active = await queue!.enqueueGray(
        grayBytes: original,
        metadata: <String, Object?>{
          'captureJobId': 'active-job',
          'grayW': 2,
          'grayH': 2,
          'sfmGraySha256': sha256.convert(original).toString(),
        },
      );
      expect((await queue!.claimNext())?.frame.id, active.id);
      expect(
        await queue!.acknowledge(
          frameId: active.id,
          nativeOk: true,
          fedMeta: <String, Object?>{...active.metadata, 'nativeFrameId': 1},
        ),
        SfmFeedAckDisposition.removeAfterSuccess,
      );
      await queue!.enqueueGray(
        grayBytes: Uint8List.fromList(<int>[2, 4, 6, 8]),
        metadata: const <String, Object?>{
          'captureJobId': 'deleted-job',
          'grayW': 2,
          'grayH': 2,
        },
      );
      final descriptor = Map<String, dynamic>.from(
        jsonDecode(await active.descriptorFile.readAsString()) as Map,
      );
      (descriptor['metadata'] as Map).remove('sfmGraySha256');
      await active.descriptorFile.writeAsString(
        jsonEncode(descriptor),
        flush: true,
      );
      await active.grayFile.writeAsBytes(<int>[7, 5, 3, 1], flush: true);

      expect(
        await queue!.prepareActiveJobsForFreshNativeReplay(const <String>{
          'active-job',
        }),
        isFalse,
      );
      expect(queue!.spoolDepth, 1);
      expect(queue!.fedCount, 1);
      expect(queue!.nativeReplayRequired, isFalse);
      expect(queue!.blockReason?.kind, SfmFeedBlockKind.replayIncomplete);
      expect(queue!.blockReason?.frameId, active.id);
      await queue!.close();

      queue = await SfmDurableFeedQueue.open(directory);
      expect(queue!.spoolDepth, 1);
      expect(queue!.fedCount, 1);
      expect(queue!.blockReason?.kind, SfmFeedBlockKind.replayIncomplete);
    });

    test(
      'active-subset manifest fault leaves old membership authoritative',
      () async {
        queue = await SfmDurableFeedQueue.open(
          directory,
          faultInjector: (point, _) {
            if (point ==
                SfmFeedQueueFaultPoint.beforeActiveSubsetManifestPersist) {
              throw StateError('injected active manifest failure');
            }
          },
        );
        for (final job in <String>['keep-job', 'delete-job']) {
          await queue!.enqueueGray(
            grayBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
            metadata: <String, Object?>{
              'captureJobId': job,
              'grayW': 2,
              'grayH': 2,
            },
          );
        }

        expect(
          await queue!.prepareActiveJobsForFreshNativeReplay(const <String>{
            'keep-job',
          }),
          isFalse,
        );
        expect(queue!.spoolDepth, 2);
        await queue!.close();

        queue = await SfmDurableFeedQueue.open(directory);
        expect(
          queue!.pendingFrames.map((frame) => frame.metadata['captureJobId']),
          orderedEquals(<String>['keep-job', 'delete-job']),
          reason: 'pre-commit tombstone cannot override the old manifest',
        );
      },
    );

    test(
      'conflicting replay exclusion marker fails cold open closed',
      () async {
        queue = await SfmDurableFeedQueue.open(directory);
        for (final job in <String>['keep-job', 'delete-job']) {
          await queue!.enqueueGray(
            grayBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
            metadata: <String, Object?>{
              'captureJobId': job,
              'grayW': 2,
              'grayH': 2,
            },
          );
        }
        expect(
          await queue!.prepareActiveJobsForFreshNativeReplay(const <String>{
            'keep-job',
          }),
          isTrue,
        );
        await queue!.close();
        final marker = File(
          '${directory.path}/frame-00000000000000000001.excluded.json',
        );
        final decoded = jsonDecode(await marker.readAsString()) as Map;
        decoded['captureJobId'] = 'wrong-job';
        await marker.writeAsString(jsonEncode(decoded), flush: true);

        await expectLater(
          SfmDurableFeedQueue.open(directory),
          throwsA(isA<FormatException>()),
        );
      },
    );

    test(
      'one canonical spool has exactly one process owner and a read snapshot',
      () async {
        queue = await SfmDurableFeedQueue.open(directory);
        await queue!.enqueueGray(
          grayBytes: Uint8List.fromList(<int>[1, 2, 3]),
          metadata: const <String, Object?>{'captureJobId': 'owner-job'},
        );

        final snapshot = await SfmDurableFeedQueue.processOwnerSnapshot(
          Directory('${directory.path}/../${directory.path.split('/').last}'),
        );
        expect(snapshot, isNotNull);
        expect(snapshot!.ownerOpening, isFalse);
        expect(snapshot.spoolDepth, 1);
        await expectLater(
          SfmDurableFeedQueue.open(directory),
          throwsA(
            isA<StateError>().having(
              (error) => '$error',
              'message',
              contains('already has a process owner'),
            ),
          ),
        );

        await queue!.close();
        queue = await SfmDurableFeedQueue.open(directory);
        expect(queue!.spoolDepth, 1);
      },
    );

    test('external process lock is respected before ownership opens', () async {
      await directory.create(recursive: true);
      final lockPath = '${directory.path}/.sfm_feed_manifest.lock';
      final helper = File('${directory.path}/external_lock_helper.dart');
      await helper.writeAsString('''
import 'dart:io';
Future<void> main(List<String> args) async {
  final lock = await File(args.single).open(mode: FileMode.append);
  await lock.lock(FileLock.exclusive);
  stdout.writeln('LOCKED');
  await stdin.first;
  await lock.unlock();
  await lock.close();
}
''', flush: true);
      final process = await Process.start('dart', <String>[
        helper.path,
        lockPath,
      ]);
      final locked = await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .timeout(const Duration(seconds: 10));
      expect(locked, 'LOCKED');

      await expectLater(
        SfmDurableFeedQueue.open(directory),
        throwsA(isA<FileSystemException>()),
      );
      expect(
        await SfmDurableFeedQueue.processOwnerSnapshot(directory),
        isNull,
        reason: 'a refused external lock must release the process reservation',
      );

      process.stdin.writeln('release');
      await process.stdin.close();
      expect(await process.exitCode, 0);
      queue = await SfmDurableFeedQueue.open(
        directory,
      ).timeout(const Duration(seconds: 10));
      expect(
        (await SfmDurableFeedQueue.processOwnerSnapshot(directory)),
        isNotNull,
      );
    });

    test('another isolate cannot become a second spool owner', () async {
      queue = await SfmDurableFeedQueue.open(directory);

      final resultPort = ReceivePort();
      await Isolate.spawn<(String, SendPort)>(_tryOpenQueueInIsolate, (
        directory.path,
        resultPort.sendPort,
      ));
      final result = await resultPort.first as String;
      resultPort.close();

      expect(result, startsWith('rejected:'));
      expect(
        (await SfmDurableFeedQueue.processOwnerSnapshot(
          directory,
        ))?.ownerOpening,
        isFalse,
      );
    });
  });
}

Future<void> _tryOpenQueueInIsolate((String, SendPort) message) async {
  try {
    final queue = await SfmDurableFeedQueue.open(Directory(message.$1));
    await queue.close();
    message.$2.send('opened');
  } catch (error) {
    message.$2.send('rejected:${error.runtimeType}');
  }
}

Future<List<SfmFeedDurableFrame>> _enqueueAndAck(
  SfmDurableFeedQueue queue,
  int count,
) async {
  final frames = <SfmFeedDurableFrame>[];
  for (var index = 0; index < count; index++) {
    final frame = await queue.enqueueGray(
      grayBytes: Uint8List.fromList(<int>[index, index + 1, index + 2]),
      metadata: <String, Object?>{'captureJobId': 'commit-$index'},
    );
    frames.add(frame);
    expect((await queue.claimNext())?.frame.id, frame.id);
    expect(
      await queue.acknowledge(
        frameId: frame.id,
        nativeOk: true,
        fedMeta: <String, Object?>{'nativeFrameId': index},
      ),
      SfmFeedAckDisposition.removeAfterSuccess,
    );
  }
  return frames;
}

Future<List<File>> _writeUserPhotoAndSidecar(Directory queueDirectory) async {
  final photos = Directory('${queueDirectory.path}/photos_highres');
  await photos.create(recursive: true);
  final jpeg = File('${photos.path}/tap-0001.jpg');
  final sidecar = File('${photos.path}/tap-0001.ar.json');
  await jpeg.writeAsBytes(<int>[0xff, 0xd8, 0xff, 0xd9], flush: true);
  await sidecar.writeAsString('{"captureJobId":"user-photo"}', flush: true);
  return <File>[jpeg, sidecar];
}

Future<void> _expectUserFilesUntouched(List<File> files) async {
  expect(
    await files[0].readAsBytes(),
    orderedEquals(<int>[0xff, 0xd8, 0xff, 0xd9]),
  );
  expect(await files[1].readAsString(), '{"captureJobId":"user-photo"}');
}

Future<void> _expectReplayPayloadsAbsent(
  List<SfmFeedDurableFrame> frames,
) async {
  for (final frame in frames) {
    expect(await frame.grayFile.exists(), isFalse);
    expect(await frame.descriptorFile.exists(), isFalse);
  }
}

Future<void> _expectAndDeleteReplayPayloads(
  List<SfmFeedDurableFrame> frames,
) async {
  for (final frame in frames) {
    expect(await frame.grayFile.exists(), isTrue);
    expect(await frame.descriptorFile.exists(), isTrue);
    await frame.grayFile.delete();
    await frame.descriptorFile.delete();
  }
}

Future<Map<String, dynamic>> _readManifest(Directory directory) async {
  return Map<String, dynamic>.from(
    jsonDecode(
          await File(
            '${directory.path}/$kSfmFeedManifestFileName',
          ).readAsString(),
        )
        as Map,
  );
}

Future<void> _downgradeManifest(Directory directory, int schema) async {
  final manifestFile = File('${directory.path}/$kSfmFeedManifestFileName');
  final manifest = await _readManifest(directory);
  manifest['schemaVersion'] = schema;
  manifest.remove('finalArtifactCommitted');
  manifest.remove('replayPurgePending');
  if (schema == 1) manifest.remove('nativeReplayRequired');
  await manifestFile.writeAsString(jsonEncode(manifest), flush: true);
}
