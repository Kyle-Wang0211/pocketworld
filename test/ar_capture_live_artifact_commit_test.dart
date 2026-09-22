import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/capture_session.dart';
import 'package:pocketworld_flutter/capture/sfm_feed_queue.dart';
import 'package:pocketworld_flutter/capture/sfm_live_recon.dart';
import 'package:pocketworld_flutter/capture/sfm_registration_publish_gate.dart';
import 'package:pocketworld_flutter/capture/sfm_resume.dart';
import 'package:pocketworld_flutter/capture/sparse_ply.dart';
import 'package:pocketworld_flutter/dome/ar_pose.dart';
import 'package:pocketworld_flutter/ui/capture/ar_capture_page.dart';

const _gray4Sha256 =
    '9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory captureDir;
  late File userPhoto;
  late SfmDurableFeedQueue durableQueue;

  setUp(() async {
    captureDir = await Directory.systemTemp.createTemp('live-artifact-commit-');
    final photos = Directory('${captureDir.path}/photos_highres');
    await photos.create();
    userPhoto = File('${photos.path}/tap-1.jpg');
    await userPhoto.writeAsBytes(<int>[7, 8, 9], flush: true);
    durableQueue = await SfmDurableFeedQueue.open(
      Directory('${captureDir.path}/sfm_live.db.sfm-feed'),
    );
  });

  tearDown(() async {
    await durableQueue.close();
    if (await captureDir.exists()) {
      await captureDir.delete(recursive: true);
    }
  });

  test(
    'refined live publication is persist then prepared purge committed',
    () async {
      final order = <String>[];
      final recon = _MarkerInspectingRecon(
        captureDir: captureDir.path,
        purgeSucceeds: true,
        order: order,
        durableQueue: durableQueue,
      );

      final result = await persistAndCommitLiveSparseArtifact(
        refined: true,
        expectedPointCount: _refined.pointCount,
        persist: () async {
          order.add('persist');
          return persistSparseSnapshot(
            captureDir: captureDir.path,
            snapshot: _refined,
            rgb: Uint8List.fromList(<int>[20, 30, 40]),
          );
        },
        requireBeforeCommit: (receipt) => _persistValidGateReceipt(
          captureDir: captureDir.path,
          queue: durableQueue,
          receipt: receipt,
        ),
        commit: (receipt) async {
          final committed = await commitPersistedSfmFinalArtifact(
            captureDir: captureDir.path,
            recon: recon,
            receipt: receipt,
          );
          final marker =
              jsonDecode(
                    await File(
                      '${captureDir.path}/sfm_final_artifact_commit.json',
                    ).readAsString(),
                  )
                  as Map<String, dynamic>;
          expect(marker['phase'], 'committed');
          order.add('committed');
          return committed;
        },
      );

      order.add('ui_complete');
      expect(result.finalArtifactCommitted, isTrue);
      expect(order, <String>[
        'persist',
        'prepared',
        'purge',
        'committed',
        'ui_complete',
      ]);
      expect(
        (await inspectSfmFinalArtifact(captureDir.path)).state,
        SfmFinalArtifactRecoveryState.complete,
      );
      expect(await userPhoto.readAsBytes(), <int>[7, 8, 9]);
    },
  );

  test('local publication persists but never commits or purges', () async {
    final order = <String>[];
    var commitCalled = false;
    final local = _withRefined(false);

    final result = await persistAndCommitLiveSparseArtifact(
      refined: false,
      expectedPointCount: local.pointCount,
      persist: () async {
        order.add('persist');
        return persistSparseSnapshot(
          captureDir: captureDir.path,
          snapshot: local,
          rgb: Uint8List.fromList(<int>[20, 30, 40]),
        );
      },
      commit: (_) async {
        commitCalled = true;
        return true;
      },
    );

    expect(result.finalArtifactCommitted, isFalse);
    expect(commitCalled, isFalse);
    expect(order, <String>['persist']);
    expect(
      (await inspectSfmFinalArtifact(captureDir.path)).state,
      SfmFinalArtifactRecoveryState.needsRebuild,
    );
    expect(await userPhoto.readAsBytes(), <int>[7, 8, 9]);
  });

  test(
    'persist failure never calls commit and preserves the user photo',
    () async {
      var commitCalled = false;

      await expectLater(
        persistAndCommitLiveSparseArtifact(
          refined: true,
          expectedPointCount: _refined.pointCount,
          persist: () async => throw FileSystemException('disk write failed'),
          commit: (_) async {
            commitCalled = true;
            return true;
          },
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(commitCalled, isFalse);
      expect(await userPhoto.readAsBytes(), <int>[7, 8, 9]);
      expect(
        File('${captureDir.path}/sfm_final_artifact_commit.json').existsSync(),
        isFalse,
      );
    },
  );

  test(
    'purge refusal stays retryable and cannot reach UI completion',
    () async {
      final firstOrder = <String>[];
      final refusingRecon = _MarkerInspectingRecon(
        captureDir: captureDir.path,
        purgeSucceeds: false,
        order: firstOrder,
        durableQueue: durableQueue,
      );
      var uiCompleted = false;

      await expectLater(
        persistAndCommitLiveSparseArtifact(
          refined: true,
          expectedPointCount: _refined.pointCount,
          persist: () async {
            firstOrder.add('persist');
            return persistSparseSnapshot(
              captureDir: captureDir.path,
              snapshot: _refined,
              rgb: Uint8List.fromList(<int>[20, 30, 40]),
            );
          },
          requireBeforeCommit: (receipt) => _persistValidGateReceipt(
            captureDir: captureDir.path,
            queue: durableQueue,
            receipt: receipt,
          ),
          commit: (receipt) => commitPersistedSfmFinalArtifact(
            captureDir: captureDir.path,
            recon: refusingRecon,
            receipt: receipt,
          ),
        ).then((_) => uiCompleted = true),
        throwsStateError,
      );

      expect(uiCompleted, isFalse);
      expect(firstOrder, <String>['persist', 'prepared', 'purge']);
      expect(
        (await inspectSfmFinalArtifact(captureDir.path)).state,
        SfmFinalArtifactRecoveryState.needsDurableCommit,
      );
      expect(await userPhoto.readAsBytes(), <int>[7, 8, 9]);

      // A later process/session can finish the prepared transaction without
      // rewriting the PLY or touching the user's photo.
      final retryOrder = <String>[];
      final retryRecon = _MarkerInspectingRecon(
        captureDir: captureDir.path,
        purgeSucceeds: true,
        order: retryOrder,
        durableQueue: durableQueue,
      );
      expect(
        await retryPersistedSfmFinalArtifactCommit(
          captureDir: captureDir.path,
          recon: retryRecon,
        ),
        isTrue,
      );
      expect(retryOrder, <String>['prepared', 'purge']);
      final committedMarker =
          jsonDecode(
                await File(
                  '${captureDir.path}/sfm_final_artifact_commit.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      expect(committedMarker['phase'], 'committed');
      expect(
        (await inspectSfmFinalArtifact(captureDir.path)).state,
        SfmFinalArtifactRecoveryState.complete,
      );
      expect(await userPhoto.readAsBytes(), <int>[7, 8, 9]);
    },
  );

  test('receipt mismatch fails before durable commit', () async {
    var commitCalled = false;
    final local = _withRefined(false);
    final localReceipt = await persistSparseSnapshot(
      captureDir: captureDir.path,
      snapshot: local,
      rgb: Uint8List.fromList(<int>[20, 30, 40]),
    );

    await expectLater(
      persistAndCommitLiveSparseArtifact(
        refined: true,
        expectedPointCount: _refined.pointCount,
        persist: () async => localReceipt,
        commit: (_) async {
          commitCalled = true;
          return true;
        },
      ),
      throwsStateError,
    );
    expect(commitCalled, isFalse);
    expect(await userPhoto.readAsBytes(), <int>[7, 8, 9]);
  });

  test('late queue mutation invalidates post-persist gate receipt', () async {
    final receipt = await persistSparseSnapshot(
      captureDir: captureDir.path,
      snapshot: _refined,
      rgb: Uint8List.fromList(<int>[20, 30, 40]),
    );
    await _persistValidGateReceipt(
      captureDir: captureDir.path,
      queue: durableQueue,
      receipt: receipt,
    );
    await durableQueue.enqueueGray(
      grayBytes: Uint8List.fromList(const <int>[9, 9, 9, 9]),
      metadata: <String, Object?>{
        'captureJobId': 'late-job',
        'jpegPath': '${captureDir.path}/photos_highres/late.jpg',
      },
    );
    final recon = _MarkerInspectingRecon(
      captureDir: captureDir.path,
      purgeSucceeds: true,
      order: <String>[],
      durableQueue: durableQueue,
    );

    expect(
      await commitPersistedSfmFinalArtifact(
        captureDir: captureDir.path,
        recon: recon,
        receipt: receipt,
      ),
      isFalse,
    );
    expect(
      File('${captureDir.path}/sfm_final_artifact_commit.json').existsSync(),
      isFalse,
    );
    expect(await userPhoto.readAsBytes(), <int>[7, 8, 9]);
  });

  test('zero-photo ledger work still qualifies for a recovery draft', () {
    expect(
      shouldPersistLocalCaptureDraft(
        photoCount: 0,
        persistedManualJobCount: 1,
        unpersistedAttemptCount: 0,
      ),
      isTrue,
    );
    expect(
      shouldPersistLocalCaptureDraft(
        photoCount: 0,
        persistedManualJobCount: 0,
        unpersistedAttemptCount: 1,
      ),
      isTrue,
    );
    expect(
      shouldPersistLocalCaptureDraft(
        photoCount: 0,
        persistedManualJobCount: 0,
        unpersistedAttemptCount: 0,
      ),
      isFalse,
    );
  });

  test('photo barrier failure always diverts finish to recovery draft', () {
    expect(
      shouldDeferCaptureToRecoveryDraft(
        photoBarrierFailed: true,
        curatedFramesEmpty: false,
      ),
      isTrue,
    );
  });

  test('photo barrier recovery message preserves exact job diagnostics', () {
    final barrier =
        CapturePhotoSaveBarrierException(const <ManualPhotoCaptureException>[
          ManualPhotoCaptureException(
            captureJobID: 'cap-57-job-09',
            code: 'manual_capture_write_failed',
            message: 'JPEG commit receipt was not published',
          ),
        ]);

    expect(
      capturePhotoBarrierRecoveryMessage(barrier),
      'cap-57-job-09: manual_capture_write_failed: '
      'JPEG commit receipt was not published',
    );
  });
}

class _MarkerInspectingRecon implements SfmLiveRecon {
  _MarkerInspectingRecon({
    required this.captureDir,
    required this.purgeSucceeds,
    required this.order,
    required this.durableQueue,
  });

  final String captureDir;
  final bool purgeSucceeds;
  final List<String> order;
  final SfmDurableFeedQueue durableQueue;

  @override
  Future<T> withDurableRegistrationEvidence<T>(
    Future<T> Function(SfmDurableFeedQueue durableQueue) inspect,
  ) => inspect(durableQueue);

  @override
  Future<bool> markFinalArtifactCommitted() async {
    final marker = File('$captureDir/sfm_final_artifact_commit.json');
    final decoded =
        jsonDecode(await marker.readAsString()) as Map<String, dynamic>;
    expect(decoded['phase'], 'prepared');
    order.add('prepared');
    order.add('purge');
    return purgeSucceeds;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final SfmLiveSnapshot _refined = SfmLiveSnapshot(
  xyz: Float32List.fromList(<double>[1, 2, 3]),
  rgb: Uint8List(3),
  posesPacked: Float64List.fromList(<double>[7, 1, 1, 0, 0, 0, 0, 0, 0]),
  summary: const <String, dynamic>{'result': 'OK'},
  refined: true,
  obsOffsets: Int32List.fromList(<int>[0, 3]),
  obsFrameIds: Int32List.fromList(<int>[0, 1, 2]),
  obsXY: Float32List(6),
);

Future<void> _persistValidGateReceipt({
  required String captureDir,
  required SfmDurableFeedQueue queue,
  required SparsePersistReceipt receipt,
}) async {
  const jobId = 'live-test-job';
  final jpeg = '$captureDir/photos_highres/tap-1.jpg';
  if (queue.nextSequence == 0) {
    final stem = jpeg.substring(0, jpeg.length - 4);
    final gray = File('$stem.sfm-gray');
    await gray.writeAsBytes(const <int>[1, 2, 3, 4], flush: true);
    await queue.enqueueGrayFile(
      sourceGrayFile: gray,
      expectedByteLength: 4,
      metadata: <String, Object?>{
        'captureJobId': jobId,
        'jpegPath': jpeg,
        'sfmGraySha256': _gray4Sha256,
      },
    );
    final claim = await queue.claimNext();
    await queue.acknowledge(
      frameId: claim!.frame.id,
      nativeOk: true,
      fedMeta: <String, Object?>{...claim.frame.metadata, 'nativeFrameId': 7},
    );
    await reconcilePersistedManualCaptureJobsFromNative(
      captureDir: captureDir,
      durableQueue: queue,
      nativeJobs: <ManualCaptureV2RecoveryJob>[
        ManualCaptureV2RecoveryJob(
          captureJobID: jobId,
          status: 'committed',
          jpegPath: jpeg,
          metadataPath: '$stem.json',
          sfmGrayPath: '$stem.sfm-gray',
          frameIdentity: 'tap-1',
          snapshotIdentity: 'snapshot-live-test',
          intentDurable: true,
          commitMarkerPresent: true,
          captureCommitReceiptPresent: true,
          artifactReceipts: <ManualCaptureV2ArtifactReceipt>[
            ManualCaptureV2ArtifactReceipt(
              kind: 'jpeg',
              path: jpeg,
              byteLength: 3,
              sha256: ''.padLeft(64, 'a'),
            ),
            ManualCaptureV2ArtifactReceipt(
              kind: 'metadata',
              path: '$stem.json',
              byteLength: 3,
              sha256: ''.padLeft(64, 'b'),
            ),
            ManualCaptureV2ArtifactReceipt(
              kind: 'sfm_gray',
              path: '$stem.sfm-gray',
              byteLength: 4,
              sha256: _gray4Sha256,
            ),
          ],
        ),
      ],
    );
  }
  final evidence = await reconcilePersistedManualFinalRegistration(
    captureDir: captureDir,
    durableQueue: queue,
    snapshot: _refined,
    artifactIdentity: 'live-test-final-artifact',
    evidenceToken: 'live-test-final-evidence',
  );
  final decision = evaluateSfmRegistrationPublishGate(
    durableQueue: queue,
    ledger: evidence.ledger,
    finalRegistration: evidence.finalRegistration,
    snapshot: _refined,
  );
  await persistSfmRegistrationGateReceipt(
    captureDir: captureDir,
    sparseReceipt: receipt,
    decision: decision,
    ledger: evidence.ledger,
    durableQueue: queue,
  );
}

SfmLiveSnapshot _withRefined(bool refined) => SfmLiveSnapshot(
  xyz: _refined.xyz,
  rgb: _refined.rgb,
  posesPacked: _refined.posesPacked,
  summary: _refined.summary,
  refined: refined,
  obsOffsets: _refined.obsOffsets,
  obsFrameIds: _refined.obsFrameIds,
  obsXY: _refined.obsXY,
);
