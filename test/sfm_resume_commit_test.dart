import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/capture_session.dart';
import 'package:pocketworld_flutter/capture/manual_capture_ledger.dart';
import 'package:pocketworld_flutter/capture/sfm_feed_queue.dart';
import 'package:pocketworld_flutter/capture/sfm_live_recon.dart';
import 'package:pocketworld_flutter/capture/sfm_resume.dart';
import 'package:pocketworld_flutter/capture/sparse_ply.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory captureDir;
  late File userPhoto;

  setUp(() async {
    captureDir = await Directory.systemTemp.createTemp('sfm-resume-commit-');
    final photos = Directory('${captureDir.path}/photos_highres');
    await photos.create();
    userPhoto = File('${photos.path}/tap-1.jpg');
    await userPhoto.writeAsBytes(<int>[1, 2, 3, 4], flush: true);
  });

  tearDown(() async {
    if (await captureDir.exists()) {
      await captureDir.delete(recursive: true);
    }
  });

  test('detached final artifact is committed before recon disposal', () async {
    await _seedRegistrationGateEvidence(captureDir.path, userPhoto);
    final recon = _FakeRecon(commitSucceeds: true, captureDir: captureDir.path);

    final committed = await startDetachedSfmFinalize(
      captureDir: captureDir.path,
      recon: recon,
    );

    expect(committed, isTrue);
    expect(File('${captureDir.path}/sfm_sparse.ply').existsSync(), isTrue);
    expect(
      File('${captureDir.path}/sfm_sparse_meta.json').existsSync(),
      isTrue,
    );
    expect(recon.calls, <String>['finalize', 'commit', 'dispose']);
    expect(await userPhoto.exists(), isTrue);
  });

  test(
    'active detached owner blocks inspection and single resume before open',
    () async {
      await _seedRegistrationGateEvidence(captureDir.path, userPhoto);
      final barrier = Completer<void>();
      final recon = _FakeRecon(
        commitSucceeds: true,
        captureDir: captureDir.path,
        finalizeBarrier: barrier,
      );
      final detached = startDetachedSfmFinalize(
        captureDir: captureDir.path,
        recon: recon,
      );
      while (!recon.calls.contains('finalize')) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      final inspection = await inspectSfmRecoveryInputs(captureDir.path);

      expect(inspection.canExplicitlyResume, isFalse);
      expect(
        inspection.reason,
        'capture_reconstruction_owned:detached_finalize',
      );
      expect(await resumeSingleCapture(captureDir.path), isFalse);
      expect(recon.calls, <String>['finalize']);

      barrier.complete();
      expect(await detached, isTrue);
      expect(recon.calls, <String>['finalize', 'commit', 'dispose']);
    },
  );

  test(
    'inspection reads an active queue owner without a second open',
    () async {
      final queueDirectory = Directory(
        '${captureDir.path}/sfm_live.db.sfm-feed',
      );
      final queue = await SfmDurableFeedQueue.open(queueDirectory);
      addTearDown(queue.close);
      await queue.enqueueGray(
        grayBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
        metadata: const <String, Object?>{'captureJobId': 'owned-job'},
      );

      final inspection = await inspectSfmRecoveryInputs(captureDir.path);

      expect(inspection.hasDurableState, isTrue);
      expect(inspection.canExplicitlyResume, isFalse);
      expect(inspection.reason, 'durable_queue_process_owned:spool=1:fed=0');
      expect(queue.spoolDepth, 1, reason: 'the live owner remains usable');
    },
  );

  test(
    'old durable history cannot fabricate a clean deletion rebuild',
    () async {
      await _seedDeletedRegistrationGateEvidence(
        captureDir.path,
        activeJpeg: userPhoto,
      );
      final recon = _FakeRecon(
        commitSucceeds: true,
        captureDir: captureDir.path,
        snapshot: _snapshotForNativeImage(1),
      );

      expect(
        await startDetachedSfmFinalize(
          captureDir: captureDir.path,
          recon: recon,
        ),
        isFalse,
      );

      final persisted = await loadPersistedManualCaptureEvidence(
        captureDir.path,
      );
      expect(persisted.ledger.rebuildRequired, isTrue);
      expect(
        persisted.ledger.currentReconstructionEpochId,
        'epoch-before-delete',
      );
      expect(persisted.ledger.job('job-deleted')?.userDeleted, isTrue);
      expect(File('${captureDir.path}/sfm_sparse.ply').existsSync(), isFalse);
      expect(await userPhoto.exists(), isTrue);
    },
  );

  test(
    'durable active-only replay publishes a new epoch after user deletion',
    () async {
      await _seedDeletedRegistrationGateEvidence(
        captureDir.path,
        activeJpeg: userPhoto,
      );
      final queueDirectory = Directory(
        '${captureDir.path}/sfm_live.db.sfm-feed',
      );
      final queue = await SfmDurableFeedQueue.open(queueDirectory);
      expect(
        await queue.prepareActiveJobsForFreshNativeReplay(const <String>{
          'job-active',
        }),
        isTrue,
      );
      final claim = await queue.claimNext();
      expect(claim?.frame.metadata['captureJobId'], 'job-active');
      expect(
        await queue.acknowledge(
          frameId: claim!.frame.id,
          nativeOk: true,
          fedMeta: <String, Object?>{
            ...claim.frame.metadata,
            'nativeFrameId': 0,
          },
        ),
        SfmFeedAckDisposition.removeAfterSuccess,
      );
      await queue.close();
      final recon = _FakeRecon(
        commitSucceeds: true,
        captureDir: captureDir.path,
        snapshot: _snapshotForNativeImage(0),
      );

      expect(
        await startDetachedSfmFinalize(
          captureDir: captureDir.path,
          recon: recon,
        ),
        isTrue,
      );

      final persisted = await loadPersistedManualCaptureEvidence(
        captureDir.path,
      );
      expect(persisted.ledger.rebuildRequired, isFalse);
      expect(persisted.ledger.currentJobToNativeImageId, <String, String>{
        'job-active': '0',
      });
      expect(
        persisted.ledger.currentReconstructionEpochId,
        contains('-rebuild-prepersist-'),
      );
      expect(persisted.ledger.job('job-deleted')?.userDeleted, isTrue);
      expect(await userPhoto.exists(), isTrue);
    },
  );

  test('durable purge refusal fails explicitly and retains photos', () async {
    await _seedRegistrationGateEvidence(captureDir.path, userPhoto);
    final recon = _FakeRecon(
      commitSucceeds: false,
      captureDir: captureDir.path,
    );

    final committed = await startDetachedSfmFinalize(
      captureDir: captureDir.path,
      recon: recon,
    );

    expect(committed, isFalse);
    expect(recon.calls, <String>['finalize', 'commit', 'dispose']);
    expect(File('${captureDir.path}/sfm_sparse.ply').existsSync(), isTrue);
    expect(
      File('${captureDir.path}/sfm_sparse_meta.json').existsSync(),
      isTrue,
    );
    expect(await userPhoto.exists(), isTrue);
  });

  test(
    'missing registration evidence blocks before sparse persistence',
    () async {
      final recon = _FakeRecon(
        commitSucceeds: true,
        captureDir: captureDir.path,
      );

      final committed = await startDetachedSfmFinalize(
        captureDir: captureDir.path,
        recon: recon,
      );

      expect(committed, isFalse);
      expect(recon.calls, <String>['finalize', 'dispose']);
      expect(File('${captureDir.path}/sfm_sparse.ply').existsSync(), isFalse);
      expect(
        File('${captureDir.path}/sfm_sparse_meta.json').existsSync(),
        isFalse,
      );
      expect(await userPhoto.exists(), isTrue);
    },
  );

  test('PLY without metadata is scheduled for reconstruction', () async {
    await File(
      '${captureDir.path}/sfm_sparse.ply',
    ).writeAsBytes(<int>[1, 2, 3], flush: true);

    final inspection = await inspectSfmFinalArtifact(captureDir.path);

    expect(inspection.state, SfmFinalArtifactRecoveryState.needsRebuild);
    expect(inspection.receipt, isNull);
    expect(await userPhoto.exists(), isTrue);
  });

  test('truncated PLY is scheduled for reconstruction', () async {
    await persistSparseSnapshot(
      captureDir: captureDir.path,
      snapshot: _snapshot,
      rgb: Uint8List.fromList(<int>[20, 30, 40]),
    );
    final ply = File('${captureDir.path}/sfm_sparse.ply');
    final bytes = await ply.readAsBytes();
    await ply.writeAsBytes(bytes.sublist(0, bytes.length - 1), flush: true);

    final inspection = await inspectSfmFinalArtifact(captureDir.path);

    expect(inspection.state, SfmFinalArtifactRecoveryState.needsRebuild);
    expect(inspection.receipt, isNull);
    expect(await userPhoto.exists(), isTrue);
  });

  test('corrupt metadata is scheduled for reconstruction', () async {
    await persistSparseSnapshot(
      captureDir: captureDir.path,
      snapshot: _snapshot,
      rgb: Uint8List.fromList(<int>[20, 30, 40]),
    );
    await File(
      '${captureDir.path}/sfm_sparse_meta.json',
    ).writeAsString('{"schema":"wrong"}', flush: true);

    final inspection = await inspectSfmFinalArtifact(captureDir.path);

    expect(inspection.state, SfmFinalArtifactRecoveryState.needsRebuild);
    expect(inspection.receipt, isNull);
    expect(await userPhoto.exists(), isTrue);
  });

  test(
    'forced regeneration discards corrupt sparse state before solve',
    () async {
      await persistSparseSnapshot(
        captureDir: captureDir.path,
        snapshot: _snapshot,
        rgb: Uint8List.fromList(<int>[20, 30, 40]),
      );
      await File(
        '${captureDir.path}/sfm_sparse_meta.json',
      ).writeAsString('{"schema":"wrong"}', flush: true);

      final prepared = await prepareSfmFinalArtifactForResume(
        captureDir.path,
        forceRegenerate: true,
      );

      expect(prepared.state, SfmFinalArtifactRecoveryState.needsRebuild);
      expect(prepared.error, isNull);
      expect(File('${captureDir.path}/sfm_sparse.ply').existsSync(), isFalse);
      expect(
        File('${captureDir.path}/sfm_sparse_meta.json').existsSync(),
        isFalse,
      );
      expect(await userPhoto.exists(), isTrue);
    },
  );

  test('valid local-only pair remains scheduled for refinement', () async {
    final local = SfmLiveSnapshot(
      xyz: _snapshot.xyz,
      rgb: _snapshot.rgb,
      posesPacked: _snapshot.posesPacked,
      summary: _snapshot.summary,
      refined: false,
      obsOffsets: _snapshot.obsOffsets,
      obsFrameIds: _snapshot.obsFrameIds,
      obsXY: _snapshot.obsXY,
    );
    await persistSparseSnapshot(
      captureDir: captureDir.path,
      snapshot: local,
      rgb: Uint8List.fromList(<int>[20, 30, 40]),
    );

    final inspection = await inspectSfmFinalArtifact(captureDir.path);

    expect(inspection.state, SfmFinalArtifactRecoveryState.needsRebuild);
    expect(inspection.receipt?.refined, isFalse);
    expect(await userPhoto.exists(), isTrue);
  });

  test(
    'commit refusal remains sweep-visible and retries without rebuild',
    () async {
      await _seedRegistrationGateEvidence(captureDir.path, userPhoto);
      final firstRecon = _FakeRecon(
        commitSucceeds: false,
        captureDir: captureDir.path,
      );
      expect(
        await startDetachedSfmFinalize(
          captureDir: captureDir.path,
          recon: firstRecon,
        ),
        isFalse,
      );

      final pending = await inspectSfmFinalArtifact(captureDir.path);
      expect(pending.state, SfmFinalArtifactRecoveryState.needsDurableCommit);
      expect(pending.receipt, isNotNull);

      final retryRecon = _FakeRecon(
        commitSucceeds: true,
        captureDir: captureDir.path,
      );
      expect(
        await retryPersistedSfmFinalArtifactCommit(
          captureDir: captureDir.path,
          recon: retryRecon,
        ),
        isTrue,
      );
      final complete = await inspectSfmFinalArtifact(captureDir.path);
      expect(complete.state, SfmFinalArtifactRecoveryState.complete);
      expect(retryRecon.calls, <String>['commit']);
      expect(await userPhoto.exists(), isTrue);
    },
  );

  test(
    'commit-only restart without exact registration receipt cannot purge',
    () async {
      await _seedRegistrationGateEvidence(captureDir.path, userPhoto);
      final firstRecon = _FakeRecon(
        commitSucceeds: false,
        captureDir: captureDir.path,
      );
      expect(
        await startDetachedSfmFinalize(
          captureDir: captureDir.path,
          recon: firstRecon,
        ),
        isFalse,
      );
      final registrationReceipt = File(
        '${captureDir.path}/sfm_registration_publish_receipt.json',
      );
      expect(await registrationReceipt.exists(), isTrue);
      await registrationReceipt.delete();

      final retryRecon = _FakeRecon(
        commitSucceeds: true,
        captureDir: captureDir.path,
      );
      expect(
        await retryPersistedSfmFinalArtifactCommit(
          captureDir: captureDir.path,
          recon: retryRecon,
        ),
        isFalse,
      );
      expect(retryRecon.calls, isEmpty);
      expect(
        (await inspectSfmFinalArtifact(captureDir.path)).state,
        SfmFinalArtifactRecoveryState.needsDurableCommit,
      );
      final queue = await SfmDurableFeedQueue.open(
        Directory('${captureDir.path}/sfm_live.db.sfm-feed'),
      );
      expect(queue.fedCount, 1);
      expect(queue.finalArtifactCommitted, isFalse);
      await queue.close();
      expect(await userPhoto.exists(), isTrue);
    },
  );

  test('a committed marker cannot bless a newer sparse generation', () async {
    await _seedRegistrationGateEvidence(captureDir.path, userPhoto);
    final recon = _FakeRecon(commitSucceeds: true, captureDir: captureDir.path);
    expect(
      await startDetachedSfmFinalize(captureDir: captureDir.path, recon: recon),
      isTrue,
    );
    final first = await inspectSfmFinalArtifact(captureDir.path);
    expect(first.state, SfmFinalArtifactRecoveryState.complete);

    final replacement = await persistSparseSnapshot(
      captureDir: captureDir.path,
      snapshot: _snapshot,
      rgb: Uint8List.fromList(<int>[50, 60, 70]),
      allowRefinedReplacement: true,
    );
    expect(replacement.artifactId, isNot(first.receipt!.artifactId));

    final current = await inspectSfmFinalArtifact(captureDir.path);
    expect(current.state, SfmFinalArtifactRecoveryState.needsRebuild);
    expect(current.receipt?.artifactId, replacement.artifactId);
    expect(await userPhoto.exists(), isTrue);
  });

  test(
    'normal single-capture resume short-circuits a complete artifact',
    () async {
      await _seedRegistrationGateEvidence(captureDir.path, userPhoto);
      final recon = _FakeRecon(
        commitSucceeds: true,
        captureDir: captureDir.path,
      );
      expect(
        await startDetachedSfmFinalize(
          captureDir: captureDir.path,
          recon: recon,
        ),
        isTrue,
      );
      expect(File('${captureDir.path}/sfm_live.db').existsSync(), isFalse);

      expect(await resumeSingleCapture(captureDir.path), isTrue);
      expect(await userPhoto.exists(), isTrue);
    },
  );

  test(
    'user tombstone invalidates an otherwise committed sparse artifact',
    () async {
      await _seedRegistrationGateEvidence(captureDir.path, userPhoto);
      final recon = _FakeRecon(
        commitSucceeds: true,
        captureDir: captureDir.path,
      );
      expect(
        await startDetachedSfmFinalize(
          captureDir: captureDir.path,
          recon: recon,
        ),
        isTrue,
      );
      final persisted = await loadPersistedManualCaptureEvidence(
        captureDir.path,
      );
      final tombstoned = persisted.ledger
          .reduce(ManualCaptureEvent.userDeletionRequested('job-0'))
          .reduce(
            ManualCaptureEvent.writersQuiesced(
              'job-0',
              evidenceToken: 'writers-quiesced-job-0',
            ),
          )
          .reduce(ManualCaptureEvent.userDeleted('job-0'));
      await File(
        '${captureDir.path}/manual_capture_registration_ledger.json',
      ).writeAsString(
        jsonEncode(<String, Object?>{
          'schema_version': 1,
          'events': tombstoned.events.map((event) => event.toJson()).toList(),
          'job_to_jpeg_path': persisted.jobToJpegPath,
        }),
        flush: true,
      );

      final inspection = await inspectSfmFinalArtifact(captureDir.path);

      expect(inspection.state, SfmFinalArtifactRecoveryState.needsRebuild);
      expect(inspection.receipt, isNotNull);
      expect(tombstoned.rebuildRequired, isTrue);
      expect(await userPhoto.exists(), isTrue);
    },
  );

  test(
    'historical PLY-only directory resolves after container UUID change',
    () async {
      const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
      final historical = Directory('${captureDir.path}/captures/cap_history');
      await historical.create(recursive: true);
      await File(
        '${historical.path}/sfm_sparse.ply',
      ).writeAsBytes(<int>[1], flush: true);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathProvider, (_) async => captureDir.path);
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(pathProvider, null);
      });

      expect(
        await resolveExistingCaptureDir('/old/container/cap_history'),
        historical.path,
      );
      expect(
        await resolveRecoverableCaptureDir('/old/container/cap_history'),
        isNull,
        reason: 'viewable history must not be mislabeled as rebuildable',
      );
    },
  );

  test(
    'committed manual-v2 bundle without DB becomes durable recoverable input',
    () async {
      final bundle = await _writeManualV2Bundle(
        Directory('${captureDir.path}/photos_highres'),
        index: 77,
      );
      expect(File('${captureDir.path}/sfm_live.db').existsSync(), isFalse);

      final inputs = await inspectSfmRecoveryInputs(captureDir.path);

      expect(inputs.hasDurableState, isTrue);
      expect(inputs.canExplicitlyResume, isTrue);
      expect(inputs.reason, 'recovered_committed_manual_v2_bundle');
      expect(
        await resolveRecoverableCaptureDir(captureDir.path),
        captureDir.path,
        reason: 'repeat inspection must reuse queue ownership idempotently',
      );
      expect(await bundle.gray.exists(), isFalse);
      expect(await bundle.jpeg.exists(), isTrue);
      expect(await bundle.sidecar.exists(), isTrue);

      final queue = await SfmDurableFeedQueue.open(
        Directory('${captureDir.path}/sfm_live.db.sfm-feed'),
      );
      expect(queue.spoolDepth, 1);
      expect(queue.blocked, isFalse);
      expect(queue.pendingFrames.single.metadata['captureJobId'], 'job-77');
      expect(queue.pendingFrames.single.metadata['frameId'], 'tap-77');
      expect(queue.pendingFrames.single.metadata['fx'], 50);
      expect(queue.pendingFrames.single.metadata['fy'], 50.5);
      expect(
        queue.pendingFrames.single.metadata['arkitQuatWxyz'],
        hasLength(4),
      );
      expect(
        queue.pendingFrames.single.metadata['arkitCameraCenterWorld'],
        hasLength(3),
      );
      await queue.close();
      expect(await userPhoto.exists(), isTrue);
    },
  );

  test(
    'cold recovery retains native commit evidence before moving orphan gray',
    () async {
      final bundle = await _writeManualV2Bundle(
        Directory('${captureDir.path}/photos_highres'),
        index: 79,
      );
      const platform = MethodChannel('aether_arkit');
      var listCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platform, (call) async {
            expect(call.method, 'listManualCaptureV2Jobs');
            expect(
              (call.arguments as Map)['captureDirectory'],
              captureDir.path,
            );
            expect(
              await bundle.gray.exists(),
              isTrue,
              reason: 'native enumeration must precede orphan queue adoption',
            );
            listCalls++;
            final jpegHash = sha256
                .convert(await bundle.jpeg.readAsBytes())
                .toString();
            final sidecarHash = sha256
                .convert(await bundle.sidecar.readAsBytes())
                .toString();
            final grayHash = sha256
                .convert(await bundle.gray.readAsBytes())
                .toString();
            return <String, Object?>{
              'schema_version': 'aether_manual_capture_v2_reconcile_v1',
              'capture_directory': captureDir.path,
              'jobs': <Object?>[
                <String, Object?>{
                  'capture_job_id': 'job-79',
                  'status': 'committed',
                  'jpeg_path': bundle.jpeg.absolute.path,
                  'metadata_path': bundle.sidecar.absolute.path,
                  'sfm_gray_path': bundle.gray.absolute.path,
                  'frame_identity': 'frame-79',
                  'snapshot_identity': 'snapshot-79',
                  'intent_durable': true,
                  'commit_marker_present': true,
                  'capture_commit_receipt_present': true,
                  'artifact_receipts': <Object?>[
                    <String, Object?>{
                      'kind': 'jpeg',
                      'path': bundle.jpeg.absolute.path,
                      'bytes': await bundle.jpeg.length(),
                      'sha256': jpegHash,
                    },
                    <String, Object?>{
                      'kind': 'metadata',
                      'path': bundle.sidecar.absolute.path,
                      'bytes': await bundle.sidecar.length(),
                      'sha256': sidecarHash,
                    },
                    <String, Object?>{
                      'kind': 'sfm_gray',
                      'path': bundle.gray.absolute.path,
                      'bytes': await bundle.gray.length(),
                      'sha256': grayHash,
                    },
                  ],
                },
              ],
            };
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(platform, null);
      });

      final inputs = await inspectSfmRecoveryInputs(captureDir.path);

      expect(listCalls, 1);
      expect(inputs.canExplicitlyResume, isTrue);
      expect(await bundle.gray.exists(), isFalse);
      final evidence = await loadPersistedManualCaptureEvidence(
        captureDir.path,
      );
      expect(
        evidence.ledger.job('job-79')?.stage,
        ManualCaptureStage.sfmQueued,
      );
      expect(evidence.jobToJpegPath['job-79'], bundle.jpeg.absolute.path);
      expect(await bundle.jpeg.exists(), isTrue);
      expect(await bundle.sidecar.exists(), isTrue);
    },
  );

  test(
    'native failed job remains visible and cannot masquerade as no input',
    () async {
      const platform = MethodChannel('aether_arkit');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platform, (call) async {
            expect(call.method, 'listManualCaptureV2Jobs');
            return <String, Object?>{
              'schema_version': 'aether_manual_capture_v2_reconcile_v1',
              'capture_directory': captureDir.path,
              'jobs': <Object?>[
                <String, Object?>{
                  'capture_job_id': 'job-failed',
                  'status': 'failed',
                  'jpeg_path': '${captureDir.path}/photos_highres/failed.jpg',
                  'metadata_path':
                      '${captureDir.path}/photos_highres/failed.json',
                  'sfm_gray_path':
                      '${captureDir.path}/photos_highres/failed.sfm-gray',
                  'frame_identity': 'frame-failed',
                  'snapshot_identity': 'snapshot-failed',
                  'error_code': 'disk-full',
                  'message': 'native artifact transaction failed',
                  'recoverable': true,
                  'intent_durable': true,
                  'commit_marker_present': false,
                  'capture_commit_receipt_present': false,
                  'artifact_receipts': <Object?>[],
                },
              ],
            };
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(platform, null);
      });

      final inputs = await inspectSfmRecoveryInputs(captureDir.path);

      expect(inputs.hasDurableState, isTrue);
      expect(inputs.canExplicitlyResume, isFalse);
      expect(inputs.reason, 'native_manual_jobs_failed:job-failed:disk-full');
      final persisted = await loadPersistedManualCaptureEvidence(
        captureDir.path,
      );
      final failedJob = persisted.ledger.job('job-failed');
      expect(failedJob, isNotNull);
      expect(failedJob!.stage, ManualCaptureStage.attempted);
      expect(failedJob.blockers.values.single.code, 'disk-full');
      expect(
        persisted.jobToJpegPath['job-failed'],
        '${captureDir.path}/photos_highres/failed.jpg',
      );
      expect(await userPhoto.exists(), isTrue);
    },
  );

  test(
    'tombstoned native failure cannot block remaining active replay',
    () async {
      await _seedDeletedRegistrationGateEvidence(
        captureDir.path,
        activeJpeg: userPhoto,
      );
      final deletedStem = '${captureDir.path}/photos_highres/deleted';
      final deletedRemainders = <File>[
        File('$deletedStem.json'),
        File('$deletedStem.sfm-gray'),
        File('$deletedStem.manual-v2-committed.json'),
        File('${captureDir.path}/previews/deleted.jpg'),
      ];
      await deletedRemainders.last.parent.create(recursive: true);
      await deletedRemainders[0].writeAsString(
        jsonEncode(<String, Object?>{
          'manual_capture_schema': 'aether_manual_capture_v2_durable_v2',
          'capture_job_id': 'job-deleted',
        }),
        flush: true,
      );
      for (final remainder in deletedRemainders.skip(1)) {
        await remainder.writeAsBytes(<int>[7, 7, 7], flush: true);
      }
      const platform = MethodChannel('aether_arkit');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platform, (call) async {
            expect(call.method, 'listManualCaptureV2Jobs');
            for (final remainder in deletedRemainders) {
              expect(
                await remainder.exists(),
                isFalse,
                reason: 'persisted tombstone cleanup must precede native list',
              );
            }
            return <String, Object?>{
              'schema_version': 'aether_manual_capture_v2_reconcile_v1',
              'capture_directory': captureDir.path,
              'jobs': <Object?>[
                <String, Object?>{
                  'capture_job_id': 'job-deleted',
                  'status': 'failed',
                  'jpeg_path': '${captureDir.path}/photos_highres/deleted.jpg',
                  'metadata_path':
                      '${captureDir.path}/photos_highres/deleted.json',
                  'sfm_gray_path':
                      '${captureDir.path}/photos_highres/deleted.sfm-gray',
                  'frame_identity': 'frame-deleted',
                  'snapshot_identity': 'snapshot-deleted',
                  'error_code': 'final-artifact-missing',
                  'message': 'user deleted the committed artifact bundle',
                  'recoverable': false,
                  'intent_durable': true,
                  'commit_marker_present': true,
                  'capture_commit_receipt_present': true,
                  'artifact_receipts': <Object?>[],
                },
              ],
            };
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(platform, null);
      });

      final inputs = await inspectSfmRecoveryInputs(captureDir.path);

      expect(inputs.hasDurableState, isTrue);
      expect(inputs.canExplicitlyResume, isTrue);
      expect(inputs.reason, 'verified_durable_queue');
      final persisted = await loadPersistedManualCaptureEvidence(
        captureDir.path,
      );
      expect(persisted.ledger.job('job-deleted')?.userDeleted, isTrue);
      expect(persisted.ledger.job('job-deleted')?.blockers, isEmpty);
      expect(persisted.ledger.job('job-active')?.userDeleted, isFalse);
      for (final remainder in deletedRemainders) {
        expect(
          await remainder.exists(),
          isFalse,
          reason: 'cold cleanup must finish the persisted tombstone',
        );
      }
      final queueDirectory = Directory(
        '${captureDir.path}/sfm_live.db.sfm-feed',
      );
      final queue = await SfmDurableFeedQueue.open(queueDirectory);
      final deletedRecord = queue.fedRecords.singleWhere(
        (record) => record.fedMeta['captureJobId'] == 'job-deleted',
      );
      expect(
        await File('${queueDirectory.path}/${deletedRecord.id}.gray').exists(),
        isTrue,
        reason: 'user-source cleanup must retain queue-owned replay gray',
      );
      await queue.close();
      expect(await userPhoto.exists(), isTrue);
    },
  );

  test(
    'cold terminal reconciliation completes an interrupted user deletion',
    () async {
      await _seedDeletedRegistrationGateEvidence(
        captureDir.path,
        activeJpeg: userPhoto,
        completeDeletion: false,
      );
      final deletedStem = '${captureDir.path}/photos_highres/deleted';
      final deletedSources = <File>[
        File('$deletedStem.jpg'),
        File('$deletedStem.json'),
        File('$deletedStem.sfm-gray'),
        File('$deletedStem.manual-v2-committed.json'),
        File('${captureDir.path}/previews/deleted.jpg'),
      ];
      await deletedSources.last.parent.create(recursive: true);
      for (final source in deletedSources.skip(1)) {
        await source.writeAsBytes(<int>[8, 8, 8], flush: true);
      }
      const platform = MethodChannel('aether_arkit');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(platform, (call) async {
            expect(call.method, 'listManualCaptureV2Jobs');
            for (final source in deletedSources) {
              expect(
                await source.exists(),
                isTrue,
                reason: 'a request alone cannot delete before native terminal',
              );
            }
            return <String, Object?>{
              'schema_version': 'aether_manual_capture_v2_reconcile_v1',
              'capture_directory': captureDir.path,
              'jobs': <Object?>[
                <String, Object?>{
                  'capture_job_id': 'job-deleted',
                  'status': 'failed',
                  'jpeg_path': '$deletedStem.jpg',
                  'metadata_path': '$deletedStem.json',
                  'sfm_gray_path': '$deletedStem.sfm-gray',
                  'frame_identity': 'frame-deleted',
                  'snapshot_identity': 'snapshot-deleted',
                  'error_code': 'capture-cancelled-after-request',
                  'message': 'native writer is terminal after process restart',
                  'recoverable': false,
                  'intent_durable': true,
                  'commit_marker_present': false,
                  'capture_commit_receipt_present': false,
                  'artifact_receipts': <Object?>[],
                },
              ],
            };
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(platform, null);
      });

      final inputs = await inspectSfmRecoveryInputs(captureDir.path);

      expect(inputs.canExplicitlyResume, isTrue);
      expect(inputs.reason, 'verified_durable_queue');
      final persisted = await loadPersistedManualCaptureEvidence(
        captureDir.path,
      );
      final deleted = persisted.ledger.job('job-deleted');
      expect(deleted?.deletionRequested, isTrue);
      expect(deleted?.writersQuiesced, isTrue);
      expect(deleted?.userDeleted, isTrue);
      expect(persisted.ledger.rebuildRequired, isTrue);
      for (final source in deletedSources) {
        expect(await source.exists(), isFalse);
      }
      final queueDirectory = Directory(
        '${captureDir.path}/sfm_live.db.sfm-feed',
      );
      final queue = await SfmDurableFeedQueue.open(queueDirectory);
      final deletedRecord = queue.fedRecords.singleWhere(
        (record) => record.fedMeta['captureJobId'] == 'job-deleted',
      );
      expect(
        await File('${queueDirectory.path}/${deletedRecord.id}.gray').exists(),
        isTrue,
      );
      await queue.close();
      expect(await userPhoto.exists(), isTrue);
    },
  );

  test('failed-only persisted job remains durable blocking state', () async {
    const jobId = 'job-pre-snapshot';
    final missingJpeg =
        '${captureDir.path}/photos_highres/pre-snapshot-failed.jpg';
    final ledger = const ManualCaptureLedger.empty()
        .reduce(
          ManualCaptureEvent.attempted(
            captureJobId: jobId,
            identityToken: missingJpeg,
          ),
        )
        .reduce(
          ManualCaptureEvent.blocked(
            jobId,
            blockerId: 'native-terminal-failure:camera-write-failed',
            code: 'camera-write-failed',
            message: 'No camera snapshot was persisted.',
          ),
        );
    await File(
      '${captureDir.path}/manual_capture_registration_ledger.json',
    ).writeAsString(
      jsonEncode(<String, Object?>{
        'schema_version': 1,
        'events': ledger.events.map((event) => event.toJson()).toList(),
        'job_to_jpeg_path': <String, String>{jobId: missingJpeg},
      }),
      flush: true,
    );

    final inputs = await inspectSfmRecoveryInputs(captureDir.path);

    expect(inputs.hasDurableState, isTrue);
    expect(inputs.canExplicitlyResume, isFalse);
    expect(
      inputs.reason,
      'manual_capture_ledger_without_replay:'
      'job-pre-snapshot:attempted:camera-write-failed',
    );
    expect(await userPhoto.exists(), isTrue);
  });

  test('retained DB still adopts source orphan after queued frames', () async {
    final photos = Directory('${captureDir.path}/photos_highres');
    final first = await _writeManualV2Bundle(photos, index: 75);
    final queueDirectory = Directory('${captureDir.path}/sfm_live.db.sfm-feed');
    var queue = await SfmDurableFeedQueue.open(queueDirectory);
    expect(
      (await queue.recoverCommittedCaptureSourcesAfterWriterQuiescence(
        photos,
        writersQuiesced: true,
      )).blocked,
      isFalse,
    );
    await queue.close();
    expect(await first.gray.exists(), isFalse);

    await File('${captureDir.path}/sfm_live.db').writeAsBytes(<int>[1]);
    final second = await _writeManualV2Bundle(photos, index: 76);

    final inputs = await inspectSfmRecoveryInputs(captureDir.path);

    expect(inputs.hasDurableState, isTrue);
    expect(inputs.canExplicitlyResume, isTrue);
    expect(inputs.reason, 'recovered_committed_manual_v2_bundle');
    expect(await second.gray.exists(), isFalse);
    expect(await first.jpeg.exists(), isTrue);
    expect(await first.sidecar.exists(), isTrue);
    expect(await second.jpeg.exists(), isTrue);
    expect(await second.sidecar.exists(), isTrue);
    queue = await SfmDurableFeedQueue.open(queueDirectory);
    expect(queue.spoolDepth, 2);
    expect(
      queue.pendingFrames.map((frame) => frame.metadata['captureJobId']),
      orderedEquals(<String>['job-75', 'job-76']),
    );
    await queue.close();
    expect(await userPhoto.exists(), isTrue);
  });

  test('orphan missing camera evidence is durably blocked', () async {
    final bundle = await _writeManualV2Bundle(
      Directory('${captureDir.path}/photos_highres'),
      index: 78,
    );
    final sidecar =
        jsonDecode(await bundle.sidecar.readAsString()) as Map<String, dynamic>;
    sidecar.remove('intrinsics_fxfycxcy');
    await bundle.sidecar.writeAsString(jsonEncode(sidecar), flush: true);

    final inputs = await inspectSfmRecoveryInputs(captureDir.path);

    expect(inputs.hasDurableState, isTrue);
    expect(inputs.canExplicitlyResume, isFalse);
    expect(inputs.reason, startsWith('recovery_evidence_blocked:'));
    expect(await resolveRecoverableCaptureDir(captureDir.path), isNull);
    expect(await bundle.gray.exists(), isTrue);
    expect(await bundle.jpeg.exists(), isTrue);
    expect(await bundle.sidecar.exists(), isTrue);
    final queue = await SfmDurableFeedQueue.open(
      Directory('${captureDir.path}/sfm_live.db.sfm-feed'),
    );
    expect(queue.spoolDepth, 0);
    expect(queue.blockReason?.kind, SfmFeedBlockKind.replayIncomplete);
    await queue.close();
    expect(await userPhoto.exists(), isTrue);
  });

  test('bare queue gray is durable but never explicitly recoverable', () async {
    final feed = Directory('${captureDir.path}/sfm_live.db.sfm-feed');
    await feed.create();
    await File('${feed.path}/frame-000.gray').writeAsBytes(<int>[1]);

    final inputs = await inspectSfmRecoveryInputs(captureDir.path);

    expect(inputs.hasDurableState, isTrue);
    expect(inputs.canExplicitlyResume, isFalse);
    expect(inputs.reason, startsWith('recovery_evidence_blocked:'));
    expect(await resolveRecoverableCaptureDir(captureDir.path), isNull);
    expect(File('${feed.path}/frame-000.gray').existsSync(), isTrue);
    expect(await userPhoto.exists(), isTrue);
  });

  test(
    'durable replay state is fail-closed but accepts completed cleanup',
    () async {
      expect(await hasSfmDurableReplayState(captureDir.path), isFalse);
      final feed = Directory('${captureDir.path}/sfm_live.db.sfm-feed');
      await feed.create();
      final gray = File('${feed.path}/frame-000.gray');
      await gray.writeAsBytes(<int>[1], flush: true);
      expect(await hasSfmDurableReplayState(captureDir.path), isTrue);

      await gray.delete();
      final manifest = File('${feed.path}/sfm_feed_manifest.json');
      await manifest.writeAsString(
        jsonEncode(<String, Object?>{
          'schemaVersion': 3,
          'generation': 4,
          'nextSequence': 1,
          'pending': <Object?>[],
          'fed': <Object?>[
            <String, Object?>{'id': 'frame-000'},
          ],
          'nativeReplayRequired': false,
          'finalArtifactCommitted': true,
          'replayPurgePending': false,
        }),
        flush: true,
      );
      expect(await hasSfmDurableReplayState(captureDir.path), isFalse);

      await manifest.writeAsString('{broken', flush: true);
      expect(await hasSfmDurableReplayState(captureDir.path), isTrue);
    },
  );

  test(
    'schema 1 and 2 stale fed rows adopt an exact refined artifact',
    () async {
      for (final schema in <int>[1, 2]) {
        final legacy = Directory('${captureDir.path}/legacy-$schema');
        await legacy.create();
        await File('${legacy.path}/sfm_live.db').writeAsBytes(<int>[1]);
        await persistSparseSnapshot(
          captureDir: legacy.path,
          snapshot: _snapshot,
          rgb: Uint8List.fromList(<int>[20, 30, 40]),
        );
        await _writeLegacyFeedManifest(legacy.path, schemaVersion: schema);

        // This is the real UI call order: replay inspection happens before
        // final-artifact inspection. It must migrate, not hide, the capture.
        expect(await hasSfmDurableReplayState(legacy.path), isFalse);
        final inspection = await inspectSfmFinalArtifact(legacy.path);
        expect(inspection.state, SfmFinalArtifactRecoveryState.complete);

        final migrated =
            jsonDecode(
                  await File(
                    '${legacy.path}/sfm_live.db.sfm-feed/sfm_feed_manifest.json',
                  ).readAsString(),
                )
                as Map<String, dynamic>;
        expect(migrated['schemaVersion'], 3);
        expect(migrated['finalArtifactCommitted'], isTrue);
        expect(migrated['replayPurgePending'], isFalse);
        expect(File('${legacy.path}/sfm_live.db').existsSync(), isTrue);
      }
      expect(await userPhoto.exists(), isTrue);
    },
  );

  test('legacy stale fed rows without an artifact remain fail-closed', () async {
    await File('${captureDir.path}/sfm_live.db').writeAsBytes(<int>[1]);
    await _writeLegacyFeedManifest(captureDir.path, schemaVersion: 2);

    expect(await hasSfmDurableReplayState(captureDir.path), isTrue);
    final inspection = await inspectSfmFinalArtifact(captureDir.path);
    expect(inspection.state, SfmFinalArtifactRecoveryState.needsRebuild);
    final unchanged =
        jsonDecode(
              await File(
                '${captureDir.path}/sfm_live.db.sfm-feed/sfm_feed_manifest.json',
              ).readAsString(),
            )
            as Map<String, dynamic>;
    expect(unchanged['schemaVersion'], 2);
    expect(await userPhoto.exists(), isTrue);
  });

  test('partial legacy replay cleanup resumes after exact verification', () async {
    await File('${captureDir.path}/sfm_live.db').writeAsBytes(<int>[1]);
    await persistSparseSnapshot(
      captureDir: captureDir.path,
      snapshot: _snapshot,
      rgb: Uint8List.fromList(<int>[20, 30, 40]),
    );
    await _writeLegacyFeedManifest(
      captureDir.path,
      schemaVersion: 2,
      firstPayloadPresent: true,
    );

    expect(await hasSfmDurableReplayState(captureDir.path), isFalse);
    final inspection = await inspectSfmFinalArtifact(captureDir.path);
    expect(inspection.state, SfmFinalArtifactRecoveryState.complete);
    final migrated =
        jsonDecode(
              await File(
                '${captureDir.path}/sfm_live.db.sfm-feed/sfm_feed_manifest.json',
              ).readAsString(),
            )
            as Map<String, dynamic>;
    expect(migrated['schemaVersion'], 3);
    expect(migrated['finalArtifactCommitted'], isTrue);
    expect(migrated['replayPurgePending'], isFalse);
    expect(
      File(
        '${captureDir.path}/sfm_live.db.sfm-feed/frame-00000000000000000000.gray',
      ).existsSync(),
      isFalse,
    );
    expect(
      File(
        '${captureDir.path}/sfm_live.db.sfm-feed/frame-00000000000000000000.json',
      ).existsSync(),
      isFalse,
    );
    expect(await userPhoto.exists(), isTrue);
  });

  test(
    'modern markerless refined artifact without DB or replay stays uncommitted',
    () async {
      await persistSparseSnapshot(
        captureDir: captureDir.path,
        snapshot: _snapshot,
        rgb: Uint8List.fromList(<int>[20, 30, 40]),
      );
      expect(File('${captureDir.path}/sfm_live.db').existsSync(), isFalse);
      expect(
        Directory('${captureDir.path}/sfm_live.db.sfm-feed').existsSync(),
        isFalse,
      );

      final inspection = await inspectSfmFinalArtifact(captureDir.path);

      expect(inspection.state, SfmFinalArtifactRecoveryState.needsRebuild);
      expect(await hasSfmDurableReplayState(captureDir.path), isFalse);
      expect(
        File('${captureDir.path}/sfm_final_artifact_commit.json').existsSync(),
        isFalse,
      );
      expect(await userPhoto.exists(), isTrue);
    },
  );

  test(
    'legacy PLY metadata pair without DB or replay becomes viewable complete',
    () async {
      await persistSparseSnapshot(
        captureDir: captureDir.path,
        snapshot: _snapshot,
        rgb: Uint8List.fromList(<int>[20, 30, 40]),
      );
      await _downgradeSparsePairToLegacy(captureDir.path);

      final inspection = await inspectSfmFinalArtifact(captureDir.path);

      expect(inspection.state, SfmFinalArtifactRecoveryState.complete);
      expect(inspection.receipt?.artifactId, startsWith('legacy-'));
      expect(await hasSfmDurableReplayState(captureDir.path), isFalse);
      final marker =
          jsonDecode(
                await File(
                  '${captureDir.path}/sfm_final_artifact_commit.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      expect(marker['phase'], 'committed');
      expect(marker['artifact_id'], inspection.receipt?.artifactId);
      expect(await userPhoto.exists(), isTrue);
    },
  );
}

Future<void> _downgradeSparsePairToLegacy(String captureDir) async {
  final ply = File('$captureDir/sfm_sparse.ply');
  final meta = File('$captureDir/sfm_sparse_meta.json');
  final bytes = await ply.readAsBytes();
  final headerMarker = utf8.encode('end_header\n');
  final headerStart = _findByteSequence(bytes, headerMarker);
  if (headerStart < 0) throw StateError('test PLY header marker missing');
  final headerEnd = headerStart + headerMarker.length;
  final header = utf8.decode(bytes.sublist(0, headerEnd));
  final legacyHeader = header.replaceFirst(
    RegExp(r'comment artifact_id [^\n]+\n'),
    '',
  );
  await ply.writeAsBytes(<int>[
    ...utf8.encode(legacyHeader),
    ...bytes.sublist(headerEnd),
  ], flush: true);
  final decoded = jsonDecode(await meta.readAsString()) as Map<String, dynamic>;
  decoded.remove('artifact_id');
  decoded.remove('ply_bytes');
  decoded.remove('ply_sha256');
  decoded.remove('vertex_stride');
  await meta.writeAsString(jsonEncode(decoded), flush: true);
  await File('$captureDir/sfm_sparse_commit.json').delete();
}

int _findByteSequence(List<int> haystack, List<int> needle) {
  for (var i = 0; i <= haystack.length - needle.length; i++) {
    var matches = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matches = false;
        break;
      }
    }
    if (matches) return i;
  }
  return -1;
}

Future<({File gray, File jpeg, File sidecar})> _writeManualV2Bundle(
  Directory directory, {
  required int index,
}) async {
  await directory.create(recursive: true);
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
      't': index.toDouble(),
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
  return (gray: gray, jpeg: jpeg, sidecar: sidecar);
}

Future<void> _seedRegistrationGateEvidence(String captureDir, File jpeg) async {
  const jobId = 'job-0';
  var ledger = const ManualCaptureLedger.empty();
  ledger = ledger
      .reduce(
        ManualCaptureEvent.attempted(
          captureJobId: jobId,
          identityToken: jpeg.absolute.path,
        ),
      )
      .reduce(ManualCaptureEvent.accepted(jobId))
      .reduce(ManualCaptureEvent.photoCommitted(jobId));
  await File(
    '$captureDir/manual_capture_registration_ledger.json',
  ).writeAsString(
    jsonEncode(<String, Object?>{
      'schema_version': 1,
      'events': ledger.events.map((event) => event.toJson()).toList(),
      'job_to_jpeg_path': <String, String>{jobId: jpeg.absolute.path},
    }),
    flush: true,
  );

  final queue = await SfmDurableFeedQueue.open(
    Directory('$captureDir/sfm_live.db.sfm-feed'),
  );
  final metadata = <String, Object?>{
    'captureJobId': jobId,
    'jpegPath': jpeg.absolute.path,
  };
  final frame = await queue.enqueueGray(
    grayBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
    metadata: metadata,
  );
  expect((await queue.claimNext())?.frame.id, frame.id);
  expect(
    await queue.acknowledge(
      frameId: frame.id,
      nativeOk: true,
      fedMeta: <String, Object?>{...metadata, 'nativeFrameId': 0},
    ),
    SfmFeedAckDisposition.removeAfterSuccess,
  );
  await queue.close();
}

Future<void> _seedDeletedRegistrationGateEvidence(
  String captureDir, {
  required File activeJpeg,
  bool completeDeletion = true,
}) async {
  final deletedJpeg = File('$captureDir/photos_highres/deleted.jpg');
  await deletedJpeg.writeAsBytes(<int>[9, 9, 9], flush: true);
  var ledger = const ManualCaptureLedger.empty();
  for (final entry in <({String jobId, File jpeg, int nativeId})>[
    (jobId: 'job-deleted', jpeg: deletedJpeg, nativeId: 0),
    (jobId: 'job-active', jpeg: activeJpeg, nativeId: 1),
  ]) {
    ledger = ledger
        .reduce(
          ManualCaptureEvent.attempted(
            captureJobId: entry.jobId,
            identityToken: entry.jpeg.absolute.path,
          ),
        )
        .reduce(ManualCaptureEvent.accepted(entry.jobId))
        .reduce(ManualCaptureEvent.photoCommitted(entry.jobId))
        .reduce(ManualCaptureEvent.sfmQueued(entry.jobId))
        .reduce(ManualCaptureEvent.sfmIngested(entry.jobId))
        .reduce(
          ManualCaptureEvent.registered(
            entry.jobId,
            reconstructionEpochId: 'epoch-before-delete',
            nativeImageId: '${entry.nativeId}',
            mappingEvidenceToken: 'mapping-${entry.jobId}',
          ),
        );
  }
  ledger = ledger.reduce(
    ManualCaptureEvent.userDeletionRequested('job-deleted'),
  );
  if (completeDeletion) {
    ledger = ledger
        .reduce(
          ManualCaptureEvent.writersQuiesced(
            'job-deleted',
            evidenceToken: 'writers-quiesced-job-deleted',
          ),
        )
        .reduce(ManualCaptureEvent.userDeleted('job-deleted'));
  }
  await File(
    '$captureDir/manual_capture_registration_ledger.json',
  ).writeAsString(
    jsonEncode(<String, Object?>{
      'schema_version': 1,
      'events': ledger.events.map((event) => event.toJson()).toList(),
      'job_to_jpeg_path': <String, String>{
        'job-deleted': deletedJpeg.absolute.path,
        'job-active': activeJpeg.absolute.path,
      },
    }),
    flush: true,
  );

  final queue = await SfmDurableFeedQueue.open(
    Directory('$captureDir/sfm_live.db.sfm-feed'),
  );
  for (final entry in <({String jobId, File jpeg, int nativeId})>[
    (jobId: 'job-deleted', jpeg: deletedJpeg, nativeId: 0),
    (jobId: 'job-active', jpeg: activeJpeg, nativeId: 1),
  ]) {
    final metadata = <String, Object?>{
      'captureJobId': entry.jobId,
      'jpegPath': entry.jpeg.absolute.path,
    };
    final frame = await queue.enqueueGray(
      grayBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
      metadata: metadata,
    );
    expect((await queue.claimNext())?.frame.id, frame.id);
    expect(
      await queue.acknowledge(
        frameId: frame.id,
        nativeOk: true,
        fedMeta: <String, Object?>{
          ...metadata,
          'nativeFrameId': entry.nativeId,
        },
      ),
      SfmFeedAckDisposition.removeAfterSuccess,
    );
  }
  await queue.close();
  if (completeDeletion) await deletedJpeg.delete();
}

Future<void> _writeLegacyFeedManifest(
  String captureDir, {
  required int schemaVersion,
  bool firstPayloadPresent = false,
}) async {
  final feed = Directory('$captureDir/sfm_live.db.sfm-feed');
  await feed.create();
  final fed = <Map<String, Object?>>[
    for (var sequence = 0; sequence < 2; sequence++)
      <String, Object?>{
        'id': 'frame-${sequence.toString().padLeft(20, '0')}',
        'sequence': sequence,
        'fedMeta': <String, Object?>{'frameId': sequence},
      },
  ];
  await File('${feed.path}/sfm_feed_manifest.json').writeAsString(
    jsonEncode(<String, Object?>{
      'schemaVersion': schemaVersion,
      'generation': 7,
      'nextSequence': 2,
      'pending': <Object?>[],
      'fed': fed,
      if (schemaVersion >= 2) 'nativeReplayRequired': false,
    }),
    flush: true,
  );
  if (!firstPayloadPresent) return;
  const id = 'frame-00000000000000000000';
  await File('${feed.path}/$id.gray').writeAsBytes(<int>[42], flush: true);
  await File('${feed.path}/$id.json').writeAsString(
    jsonEncode(<String, Object?>{
      'id': id,
      'sequence': 0,
      'grayFile': '$id.gray',
      'descriptorFile': '$id.json',
      'metadata': <String, Object?>{},
    }),
    flush: true,
  );
}

class _FakeRecon implements SfmLiveRecon {
  _FakeRecon({
    required this.commitSucceeds,
    required this.captureDir,
    this.finalizeBarrier,
    SfmLiveSnapshot? snapshot,
  }) : snapshot = snapshot ?? _snapshot;

  final bool commitSucceeds;
  final String captureDir;
  final Completer<void>? finalizeBarrier;
  final SfmLiveSnapshot snapshot;
  final List<String> calls = <String>[];
  final StreamController<SfmLiveEvent> _events =
      StreamController<SfmLiveEvent>();

  @override
  Stream<SfmLiveEvent> get events => _events.stream;

  @override
  void finalize() {
    calls.add('finalize');
    scheduleMicrotask(() async {
      await finalizeBarrier?.future;
      _events.add(SfmLiveRefined(snapshot, 1));
    });
  }

  @override
  Future<bool> markFinalArtifactCommitted() async {
    calls.add('commit');
    if (!commitSucceeds) return false;
    final queue = await SfmDurableFeedQueue.open(
      Directory('$captureDir/sfm_live.db.sfm-feed'),
    );
    try {
      return await queue.purgeReplayPayloadsAfterFinalArtifact();
    } finally {
      await queue.close();
    }
  }

  @override
  Future<T> withDurableRegistrationEvidence<T>(
    Future<T> Function(SfmDurableFeedQueue durableQueue) inspect,
  ) async {
    final queue = await SfmDurableFeedQueue.open(
      Directory('$captureDir/sfm_live.db.sfm-feed'),
    );
    try {
      return await inspect(queue);
    } finally {
      await queue.close();
    }
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
    await _events.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final SfmLiveSnapshot _snapshot = SfmLiveSnapshot(
  xyz: Float32List.fromList(<double>[1, 2, 3]),
  rgb: Uint8List(3),
  posesPacked: Float64List.fromList(<double>[
    0, // native image ID
    1, // registered
    1, 0, 0, 0, // q(wxyz)
    0, 0, 0, // t(xyz)
  ]),
  summary: const <String, dynamic>{'result': 'OK'},
  refined: true,
  obsOffsets: Int32List.fromList(<int>[0, 3]),
  obsFrameIds: Int32List.fromList(<int>[0, 1, 2]),
  obsXY: Float32List(6),
);

SfmLiveSnapshot _snapshotForNativeImage(int nativeImageId) => SfmLiveSnapshot(
  xyz: _snapshot.xyz,
  rgb: _snapshot.rgb,
  posesPacked: Float64List.fromList(<double>[
    nativeImageId.toDouble(),
    1,
    1,
    0,
    0,
    0,
    0,
    0,
    0,
  ]),
  summary: _snapshot.summary,
  refined: true,
  obsOffsets: _snapshot.obsOffsets,
  obsFrameIds: _snapshot.obsFrameIds,
  obsXY: _snapshot.obsXY,
);
