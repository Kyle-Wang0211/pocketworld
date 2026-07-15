import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/sfm_feed_queue.dart';
import 'package:pocketworld_flutter/capture/sfm_thermal_scheduler.dart';

void main() {
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
      final second = await queue!.claimNext();
      expect(first?.frame.id, frames[0].id);
      expect(second?.frame.id, frames[1].id);
      expect(
        await queue!.claimNext(),
        isNull,
        reason: 'only two native calls may be in flight',
      );

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
        expect(await queue!.purgeReplayPayloadsAfterFinalArtifact(), isTrue);
        expect(await frame.grayFile.exists(), isFalse);
        expect(await frame.descriptorFile.exists(), isFalse);
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
        expect((await queue!.claimNext())?.frame.id, second.id);
        expect(
          await queue!.acknowledge(
            frameId: first.id,
            nativeOk: true,
            fedMeta: const <String, Object?>{'nativeFrameId': 0},
          ),
          SfmFeedAckDisposition.removeAfterSuccess,
        );
        expect(queue!.nativeReplayRequired, isTrue);
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
  });
}
