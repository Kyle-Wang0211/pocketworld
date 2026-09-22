import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/manual_capture_ledger.dart';
import 'package:pocketworld_flutter/capture/sfm_feed_queue.dart';
import 'package:pocketworld_flutter/capture/sfm_live_recon.dart';
import 'package:pocketworld_flutter/capture/sfm_registration_publish_gate.dart';

void main() {
  group('100% registration publish gate', () {
    test('allows exact durable, ledger, and refined-pose bijection', () async {
      final fixture = await _fixture(const [7, 11]);
      addTearDown(fixture.dispose);

      final decision = evaluateSfmRegistrationPublishGate(
        durableQueue: fixture.queue,
        ledger: fixture.ledger,
        finalRegistration: fixture.observation,
        snapshot: _snapshot(const [(7, true), (11, true)]),
      );

      expect(decision.canPublish, isTrue);
      expect(decision.acceptedCount, 2);
      expect(decision.durableAcceptedHighWatermark, 2);
      expect(decision.ledgerNativeImageIds, {7, 11});
      expect(decision.durableNativeImageIds, {7, 11});
      expect(decision.snapshotNativeImageIds, {7, 11});
      expect(decision.requireCanPublish, returnsNormally);
    });

    test('refuses a partial registration without deleting evidence', () async {
      final fixture = await _fixture(const [7, 11]);
      addTearDown(fixture.dispose);

      final decision = evaluateSfmRegistrationPublishGate(
        durableQueue: fixture.queue,
        ledger: fixture.ledger,
        finalRegistration: fixture.observation,
        snapshot: _snapshot(const [(7, true), (11, false)]),
      );

      expect(decision.canPublish, isFalse);
      expect(
        decision.failures.map((failure) => failure.code),
        contains(
          SfmRegistrationPublishFailureCode.snapshotContainsUnregisteredFrame,
        ),
      );
      expect(fixture.queue.nextSequence, 2);
      expect(fixture.queue.fedCount, 2);
      expect(() => decision.requireCanPublish(), throwsStateError);
    });

    test('refuses a missing final pose ID', () async {
      final fixture = await _fixture(const [7, 11]);
      addTearDown(fixture.dispose);

      final decision = evaluateSfmRegistrationPublishGate(
        durableQueue: fixture.queue,
        ledger: fixture.ledger,
        finalRegistration: fixture.observation,
        snapshot: _snapshot(const [(7, true)]),
      );

      expect(decision.canPublish, isFalse);
      expect(
        decision.failures.map((failure) => failure.code),
        containsAll(<SfmRegistrationPublishFailureCode>{
          SfmRegistrationPublishFailureCode.snapshotRegisteredCountMismatch,
          SfmRegistrationPublishFailureCode.nativeImageIdSetMismatch,
        }),
      );
    });

    test('uses the reopened manifest as the accepted denominator', () async {
      final fixture = await _fixture(const [3, 8], keepQueueOpen: false);
      addTearDown(fixture.dispose);
      final reopened = await SfmDurableFeedQueue.open(fixture.spoolDirectory);
      fixture.queue = reopened;

      final decision = evaluateSfmRegistrationPublishGate(
        durableQueue: reopened,
        ledger: fixture.ledger,
        finalRegistration: fixture.observation,
        snapshot: _snapshot(const [(3, true), (8, true)]),
      );

      expect(decision.canPublish, isTrue);
      expect(reopened.nextSequence, 2);
      expect(reopened.fedRecords.map((record) => record.sequence), [0, 1]);
    });

    test('refuses a vacuous zero-frame artifact', () async {
      final temp = await Directory.systemTemp.createTemp('sfm-reg-zero-');
      final queue = await SfmDurableFeedQueue.open(
        Directory('${temp.path}/spool'),
      );
      addTearDown(() async {
        await queue.close();
        await temp.delete(recursive: true);
      });
      const ledger = ManualCaptureLedger.empty();
      final observation = FinalRegistrationObservation(
        artifactIdentity: 'ply:sha256:zero',
        evidenceToken: 'receipt:sha256:zero',
        reconstructionEpochId: 'epoch-zero',
        jobToNativeImageId: const {},
      );

      final decision = evaluateSfmRegistrationPublishGate(
        durableQueue: queue,
        ledger: ledger,
        finalRegistration: observation,
        snapshot: _snapshot(const []),
      );

      expect(decision.canPublish, isFalse);
      expect(
        decision.failures.map((failure) => failure.code),
        contains(SfmRegistrationPublishFailureCode.noAcceptedFrames),
      );
    });

    test('refuses duplicate durable ACKs for one active job', () async {
      final fixture = await _fixture(
        const [7, 7],
        ledgerNativeIds: const [7],
        durableJobIds: const ['job-0', 'job-0'],
      );
      addTearDown(fixture.dispose);

      final decision = evaluateSfmRegistrationPublishGate(
        durableQueue: fixture.queue,
        ledger: fixture.ledger,
        finalRegistration: fixture.observation,
        snapshot: _snapshot(const [(7, true), (11, true)]),
      );

      expect(decision.canPublish, isFalse);
      expect(
        decision.failures.map((failure) => failure.code),
        contains(
          SfmRegistrationPublishFailureCode.durableCaptureJobIdDuplicate,
        ),
      );
    });

    test('refuses missing durable captureJobId', () async {
      final fixture = await _fixture(
        const [7],
        ledgerNativeIds: const [7],
        durableJobIds: const [null],
      );
      addTearDown(fixture.dispose);

      final decision = evaluateSfmRegistrationPublishGate(
        durableQueue: fixture.queue,
        ledger: fixture.ledger,
        finalRegistration: fixture.observation,
        snapshot: _snapshot(const [(7, true)]),
      );

      expect(decision.canPublish, isFalse);
      expect(
        decision.failures.map((failure) => failure.code),
        contains(SfmRegistrationPublishFailureCode.durableCaptureJobIdInvalid),
      );
    });

    test(
      'refuses swapped per-job native IDs even when the set matches',
      () async {
        final fixture = await _fixture(
          const [11, 7],
          ledgerNativeIds: const [7, 11],
        );
        addTearDown(fixture.dispose);

        final decision = evaluateSfmRegistrationPublishGate(
          durableQueue: fixture.queue,
          ledger: fixture.ledger,
          finalRegistration: fixture.observation,
          snapshot: _snapshot(const [(7, true), (11, true)]),
        );

        expect(decision.canPublish, isFalse);
        expect(
          decision.failures.map((failure) => failure.code),
          contains(SfmRegistrationPublishFailureCode.durableJobMappingMismatch),
        );
        expect(decision.ledgerNativeImageIds, decision.snapshotNativeImageIds);
      },
    );

    test('refuses duplicate IDs in final pose rows', () async {
      final fixture = await _fixture(const [7, 11]);
      addTearDown(fixture.dispose);

      final decision = evaluateSfmRegistrationPublishGate(
        durableQueue: fixture.queue,
        ledger: fixture.ledger,
        finalRegistration: fixture.observation,
        snapshot: _snapshot(const [(7, true), (7, true)]),
      );

      expect(decision.canPublish, isFalse);
      expect(
        decision.failures.map((failure) => failure.code),
        contains(
          SfmRegistrationPublishFailureCode.snapshotNativeImageIdDuplicate,
        ),
      );
    });

    test(
      'refuses incomplete ledger stages even when counts happen to match',
      () async {
        final fixture = await _fixture(const [7]);
        addTearDown(fixture.dispose);
        final incomplete = const ManualCaptureLedger.empty()
            .reduce(
              ManualCaptureEvent.attempted(
                captureJobId: 'job-0',
                identityToken: 'identity-0',
              ),
            )
            .reduce(ManualCaptureEvent.accepted('job-0'));

        final decision = evaluateSfmRegistrationPublishGate(
          durableQueue: fixture.queue,
          ledger: incomplete,
          finalRegistration: fixture.observation,
          snapshot: _snapshot(const [(7, true)]),
        );

        expect(decision.canPublish, isFalse);
        expect(
          decision.failures.map((failure) => failure.code),
          contains(SfmRegistrationPublishFailureCode.ledgerClosureIncomplete),
        );
      },
    );

    test(
      'allows a user tombstone only after exact clean rebuild evidence',
      () async {
        var ledger = _registeredLedger(const {'job-a': 7, 'job-b': 11});
        ledger = _userDelete(ledger, 'job-a').reduce(
          ManualCaptureEvent.reconstructionRebuilt(
            reconstructionEpochId: 'epoch-rebuild',
            artifactIdentity: 'ply:sha256:after-delete',
            evidenceToken: 'rebuild:sha256:after-delete',
            jobToNativeImageId: const {'job-b': '21'},
          ),
        );
        final observation = FinalRegistrationObservation(
          artifactIdentity: 'ply:sha256:after-delete',
          evidenceToken: 'receipt:sha256:after-delete',
          reconstructionEpochId: 'epoch-rebuild',
          jobToNativeImageId: const {'job-b': '21'},
        );
        final fixture = await _customFixture(
          durableRecords: const [
            (jobId: 'job-a', nativeId: 7),
            (jobId: 'job-b', nativeId: 21),
          ],
          ledger: ledger,
          observation: observation,
        );
        addTearDown(fixture.dispose);
        await _retainOnlyActiveFedRows(fixture, const {'job-b'});

        final decision = evaluateSfmRegistrationPublishGate(
          durableQueue: fixture.queue,
          ledger: ledger,
          finalRegistration: observation,
          snapshot: _snapshot(const [(21, true)]),
        );

        expect(decision.canPublish, isTrue);
        expect(decision.acceptedCount, 1);
        expect(decision.durableAcceptedHighWatermark, 2);
        expect(decision.durableJobToNativeImageId, {'job-b': 21});
      },
    );

    test(
      'historical sequence high-water mark may exceed active jobs',
      () async {
        var ledger = _registeredLedger(const {
          'job-a': 7,
          'job-b': 11,
          'job-c': 13,
        });
        ledger = _userDelete(_userDelete(ledger, 'job-a'), 'job-c').reduce(
          ManualCaptureEvent.reconstructionRebuilt(
            reconstructionEpochId: 'epoch-rebuild',
            artifactIdentity: 'ply:sha256:only-b',
            evidenceToken: 'rebuild:sha256:only-b',
            jobToNativeImageId: const {'job-b': '31'},
          ),
        );
        final observation = FinalRegistrationObservation(
          artifactIdentity: 'ply:sha256:only-b',
          evidenceToken: 'receipt:sha256:only-b',
          reconstructionEpochId: 'epoch-rebuild',
          jobToNativeImageId: const {'job-b': '31'},
        );
        final fixture = await _customFixture(
          durableRecords: const [
            (jobId: 'job-a', nativeId: 7),
            (jobId: 'job-b', nativeId: 31),
            (jobId: 'job-c', nativeId: 13),
          ],
          ledger: ledger,
          observation: observation,
        );
        addTearDown(fixture.dispose);
        await _retainOnlyActiveFedRows(fixture, const {'job-b'});

        final decision = evaluateSfmRegistrationPublishGate(
          durableQueue: fixture.queue,
          ledger: ledger,
          finalRegistration: observation,
          snapshot: _snapshot(const [(31, true)]),
        );

        expect(decision.canPublish, isTrue);
        expect(decision.acceptedCount, 1);
        expect(decision.durableAcceptedHighWatermark, 3);
        expect(decision.durableFedCount, 1);
      },
    );

    test(
      'clean rebuild cannot authorize a historical deleted fed row',
      () async {
        var ledger = _registeredLedger(const {'job-a': 7, 'job-b': 11});
        ledger = _userDelete(ledger, 'job-a').reduce(
          ManualCaptureEvent.reconstructionRebuilt(
            reconstructionEpochId: 'epoch-rebuild',
            artifactIdentity: 'ply:sha256:active-only',
            evidenceToken: 'rebuild:sha256:active-only',
            jobToNativeImageId: const {'job-b': '21'},
          ),
        );
        final observation = FinalRegistrationObservation(
          artifactIdentity: 'ply:sha256:active-only',
          evidenceToken: 'receipt:sha256:active-only',
          reconstructionEpochId: 'epoch-rebuild',
          jobToNativeImageId: const {'job-b': '21'},
        );
        final fixture = await _customFixture(
          durableRecords: const [
            (jobId: 'job-a', nativeId: 7),
            (jobId: 'job-b', nativeId: 21),
          ],
          ledger: ledger,
          observation: observation,
        );
        addTearDown(fixture.dispose);

        final decision = evaluateSfmRegistrationPublishGate(
          durableQueue: fixture.queue,
          ledger: ledger,
          finalRegistration: observation,
          snapshot: _snapshot(const [(21, true)]),
        );

        expect(decision.canPublish, isFalse);
        expect(
          decision.failures.map((failure) => failure.code),
          containsAll(<SfmRegistrationPublishFailureCode>{
            SfmRegistrationPublishFailureCode.durableAcceptedCountMismatch,
            SfmRegistrationPublishFailureCode.durableJobMappingMismatch,
          }),
        );
      },
    );

    test('forged rebuild cannot keep a user-deleted job active', () {
      final pendingRebuild = _userDelete(
        _registeredLedger(const {'job-a': 7, 'job-b': 11}),
        'job-a',
      );

      expect(
        () => pendingRebuild.reduce(
          ManualCaptureEvent.reconstructionRebuilt(
            reconstructionEpochId: 'epoch-forged',
            artifactIdentity: 'ply:sha256:forged',
            evidenceToken: 'rebuild:sha256:forged',
            jobToNativeImageId: const {'job-a': '7', 'job-b': '21'},
          ),
        ),
        throwsA(isA<ManualCaptureLedgerViolation>()),
      );
    });

    test('user deletion before clean rebuild remains fail-closed', () async {
      final ledger = _userDelete(
        _registeredLedger(const {'job-a': 7, 'job-b': 11}),
        'job-a',
      );
      final observation = FinalRegistrationObservation(
        artifactIdentity: 'ply:sha256:stale-before-rebuild',
        evidenceToken: 'receipt:sha256:stale-before-rebuild',
        reconstructionEpochId: 'epoch-final',
        jobToNativeImageId: const {'job-b': '11'},
      );
      final fixture = await _customFixture(
        durableRecords: const [
          (jobId: 'job-a', nativeId: 7),
          (jobId: 'job-b', nativeId: 11),
        ],
        ledger: ledger,
        observation: observation,
      );
      addTearDown(fixture.dispose);

      final decision = evaluateSfmRegistrationPublishGate(
        durableQueue: fixture.queue,
        ledger: ledger,
        finalRegistration: observation,
        snapshot: _snapshot(const [(11, true)]),
      );

      expect(decision.canPublish, isFalse);
      expect(
        decision.failures.map((failure) => failure.code),
        contains(SfmRegistrationPublishFailureCode.ledgerClosureIncomplete),
      );
    });
  });
}

final class _Fixture {
  _Fixture({
    required this.temp,
    required this.spoolDirectory,
    required this.queue,
    required this.ledger,
    required this.observation,
  });

  final Directory temp;
  final Directory spoolDirectory;
  SfmDurableFeedQueue queue;
  final ManualCaptureLedger ledger;
  final FinalRegistrationObservation observation;

  Future<void> dispose() async {
    await queue.close();
    if (await temp.exists()) await temp.delete(recursive: true);
  }
}

Future<_Fixture> _fixture(
  List<int> durableNativeIds, {
  List<int>? ledgerNativeIds,
  List<String?>? durableJobIds,
  bool keepQueueOpen = true,
}) async {
  final mappedIds = ledgerNativeIds ?? durableNativeIds;
  final jobMap = <String, int>{
    for (var i = 0; i < mappedIds.length; i++) 'job-$i': mappedIds[i],
  };
  final ledger = _registeredLedger(jobMap);
  final observation = FinalRegistrationObservation(
    artifactIdentity: 'ply:sha256:final-artifact',
    evidenceToken: 'receipt:sha256:final-artifact',
    reconstructionEpochId: 'epoch-final',
    jobToNativeImageId: jobMap.map(
      (jobId, nativeId) => MapEntry(jobId, nativeId.toString()),
    ),
  );
  final fixture = await _customFixture(
    durableRecords: <({String? jobId, int nativeId})>[
      for (var i = 0; i < durableNativeIds.length; i++)
        (
          jobId: durableJobIds == null ? 'job-$i' : durableJobIds[i],
          nativeId: durableNativeIds[i],
        ),
    ],
    ledger: ledger,
    observation: observation,
  );
  if (!keepQueueOpen) await fixture.queue.close();
  return fixture;
}

Future<_Fixture> _customFixture({
  required List<({String? jobId, int nativeId})> durableRecords,
  required ManualCaptureLedger ledger,
  required FinalRegistrationObservation observation,
}) async {
  final temp = await Directory.systemTemp.createTemp('sfm-reg-gate-');
  final spool = Directory('${temp.path}/spool');
  final queue = await SfmDurableFeedQueue.open(spool);
  for (final record in durableRecords) {
    final metadata = <String, Object?>{
      'test': true,
      if (record.jobId != null) 'captureJobId': record.jobId,
    };
    await queue.enqueueGray(
      grayBytes: Uint8List.fromList(const [1, 2, 3, 4]),
      metadata: metadata,
    );
    final claim = await queue.claimNext();
    expect(claim, isNotNull);
    final disposition = await queue.acknowledge(
      frameId: claim!.frame.id,
      nativeOk: true,
      fedMeta: <String, Object?>{...metadata, 'nativeFrameId': record.nativeId},
    );
    expect(disposition, SfmFeedAckDisposition.removeAfterSuccess);
  }
  return _Fixture(
    temp: temp,
    spoolDirectory: spool,
    queue: queue,
    ledger: ledger,
    observation: observation,
  );
}

Future<void> _retainOnlyActiveFedRows(
  _Fixture fixture,
  Set<String> activeJobIds,
) async {
  expect(
    await fixture.queue.prepareActiveJobsForFreshNativeReplay(activeJobIds),
    isTrue,
  );
  while (fixture.queue.pendingFrames.isNotEmpty) {
    final claim = await fixture.queue.claimNext();
    expect(claim, isNotNull);
    final jobId = claim!.frame.metadata['captureJobId']! as String;
    final nativeId = int.parse(fixture.observation.jobToNativeImageId[jobId]!);
    expect(
      await fixture.queue.acknowledge(
        frameId: claim.frame.id,
        nativeOk: true,
        fedMeta: <String, Object?>{
          ...claim.frame.metadata,
          'nativeFrameId': nativeId,
        },
      ),
      SfmFeedAckDisposition.removeAfterSuccess,
    );
  }
}

ManualCaptureLedger _registeredLedger(Map<String, int> jobToNativeId) {
  var ledger = const ManualCaptureLedger.empty();
  var index = 0;
  for (final entry in jobToNativeId.entries) {
    ledger = ledger
        .reduce(
          ManualCaptureEvent.attempted(
            captureJobId: entry.key,
            identityToken: 'identity-${entry.key}',
          ),
        )
        .reduce(ManualCaptureEvent.accepted(entry.key))
        .reduce(ManualCaptureEvent.photoCommitted(entry.key))
        .reduce(ManualCaptureEvent.sfmQueued(entry.key))
        .reduce(ManualCaptureEvent.sfmIngested(entry.key))
        .reduce(
          ManualCaptureEvent.registered(
            entry.key,
            reconstructionEpochId: 'epoch-final',
            nativeImageId: entry.value.toString(),
            mappingEvidenceToken: 'mapping-proof-${index++}',
          ),
        );
  }
  return ledger;
}

ManualCaptureLedger _userDelete(ManualCaptureLedger ledger, String jobId) =>
    ledger
        .reduce(ManualCaptureEvent.userDeletionRequested(jobId))
        .reduce(
          ManualCaptureEvent.writersQuiesced(
            jobId,
            evidenceToken: 'writers-quiesced-$jobId',
          ),
        )
        .reduce(ManualCaptureEvent.userDeleted(jobId));

SfmLiveSnapshot _snapshot(List<(int, bool)> poses, {bool refined = true}) {
  final packed = Float64List(poses.length * 9);
  for (var i = 0; i < poses.length; i++) {
    final offset = i * 9;
    packed[offset] = poses[i].$1.toDouble();
    packed[offset + 1] = poses[i].$2 ? 1 : 0;
    packed[offset + 2] = 1; // qw
  }
  return SfmLiveSnapshot(
    xyz: Float32List(0),
    rgb: Uint8List(0),
    posesPacked: packed,
    summary: const <String, Object?>{},
    refined: refined,
    obsOffsets: Int32List.fromList(const [0]),
    obsFrameIds: Int32List(0),
    obsXY: Float32List(0),
  );
}
