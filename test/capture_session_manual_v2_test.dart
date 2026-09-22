import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture/capture_session.dart';
import 'package:pocketworld_flutter/capture/dome/dome_target_points.dart';
import 'package:pocketworld_flutter/capture/manual_capture_ledger.dart';
import 'package:pocketworld_flutter/capture/sfm_feed_queue.dart';
import 'package:pocketworld_flutter/capture/sfm_live_recon.dart';
import 'package:pocketworld_flutter/capture/sfm_registration_publish_gate.dart';
import 'package:pocketworld_flutter/dome/ar_pose.dart';
import 'package:vector_math/vector_math_64.dart';

const _gray4Sha256 =
    '9f64a747e1b97f131fabb6b447296c9b6f0201e79fb3c5356e6c77e89b6a806a';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  const sensorsMethodChannel = MethodChannel(
    'dev.fluttercommunity.plus/sensors/method',
  );

  late Directory documentsDirectory;
  late _ManualV2PoseProvider provider;
  late CaptureSession session;

  setUp(() async {
    documentsDirectory = await Directory.systemTemp.createTemp(
      'capture-session-manual-v2-',
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProviderChannel,
          (_) async => documentsDirectory.path,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sensorsMethodChannel, (_) async => null);

    provider = _ManualV2PoseProvider();
    session = CaptureSession(poseProvider: provider);
    await session.start(autoLock: false, manualCapture: true);
    provider.emitPose();
    await Future<void>.delayed(Duration.zero);
  });

  tearDown(() async {
    await session.dispose();
    await provider.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(sensorsMethodChannel, null);
    if (await documentsDirectory.exists()) {
      await documentsDirectory.delete(recursive: true);
    }
  });

  test(
    'reserve returns before commit and a late durable sink loses no frame',
    () async {
      final capture = await session.captureSinglePhoto();

      expect(capture, isNotNull);
      expect(provider.terminal.isCompleted, isFalse);
      expect(capture!.reservation.status, 'snapshot_reserved');
      final acceptedEvidence = await loadPersistedManualCaptureEvidence(
        session.captureDir!,
      );
      expect(
        acceptedEvidence.ledger.job(capture.captureJobID)!.stage,
        ManualCaptureStage.accepted,
      );
      expect(
        acceptedEvidence.jobToJpegPath[capture.captureJobID],
        File(capture.jpegPath).absolute.path,
      );
      expect(
        session.targetPoints.retainedJpegPaths,
        isEmpty,
        reason: 'A reservation must not publish an album/curation entry.',
      );
      expect(session.capturedPhotoPaths, isEmpty);

      await provider.completeCommitted();
      final committed = await capture.committed;
      expect(committed.committed, isTrue);
      expect(File(committed.jpegPath).existsSync(), isTrue);
      expect(
        session.targetPoints.retainedJpegPaths,
        contains(committed.jpegPath),
        reason: 'The admitted slot must publish its JPEG after native commit.',
      );
      expect(
        session.capturedPhotoPaths,
        contains(committed.jpegPath),
        reason: 'The user-owned inventory publishes only after native commit.',
      );
      expect(
        await session.reconcileCapturedPhotosFromDisk(),
        contains(committed.jpegPath),
      );

      var completionFinished = false;
      capture.completion.whenComplete(() => completionFinished = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        completionFinished,
        isFalse,
        reason: 'A committed frame must wait until a durable sink is bound.',
      );

      final offered = <SfmFrameFeed>[];
      session.bindManualSfmFrameSink((feed) {
        offered.add(feed);
        return true;
      });
      await capture.completion;

      expect(offered, hasLength(1));
      expect(offered.single.captureJobId, capture.captureJobID);
      expect(offered.single.jpegPath, committed.jpegPath);
      expect(offered.single.gray, isEmpty);
      expect(offered.single.grayFilePath, committed.sfmGrayPath);
      expect(
        await File(offered.single.grayFilePath!).readAsBytes(),
        hasLength(4),
      );
      final queuedEvidence = await loadPersistedManualCaptureEvidence(
        session.captureDir!,
      );
      expect(
        queuedEvidence.ledger.job(capture.captureJobID)!.stage,
        ManualCaptureStage.sfmQueued,
      );
    },
  );

  test(
    'pending barrier has no timeout escape before accepted job completes',
    () async {
      session.bindManualSfmFrameSink((_) => true);
      final capture = await session.captureSinglePhoto();
      expect(capture, isNotNull);

      var barrierFinished = false;
      final barrier = session
          .waitForPendingPhotoSaves(timeout: Duration.zero)
          .whenComplete(() => barrierFinished = true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(barrierFinished, isFalse);

      await provider.completeCommitted();
      await barrier;
      expect(barrierFinished, isTrue);
    },
  );

  test(
    'disk inventory hides pre-marker JPEG but admits exact durable receipt',
    () async {
      final capture = await session.captureSinglePhoto();
      expect(capture, isNotNull);
      await File(capture!.jpegPath).writeAsBytes(const <int>[9], flush: true);

      expect(await session.reconcileCapturedPhotosFromDisk(), isEmpty);
      final hiddenManifest = await session.writePhotoBundleManifest(
        const <CuratedFrame>[],
      );
      final hiddenDocument =
          jsonDecode(await hiddenManifest!.readAsString()) as Map;
      expect(hiddenDocument['frames'], isEmpty);

      await _writeExactDurableV2Receipt(
        capture: capture,
        frameID: provider.request!.saveSpec.frameID,
      );
      expect(
        await session.reconcileCapturedPhotosFromDisk(),
        contains(capture.jpegPath),
      );

      session.bindManualSfmFrameSink((_) => true);
      await provider.completeCommitted();
      await capture.completion;
      final gray = File(capture.reservation.sfmGrayPath);
      if (await gray.exists()) await gray.delete();
      expect(
        await session.reconcileCapturedPhotosFromDisk(),
        contains(capture.jpegPath),
        reason:
            'Transferred gray does not hide a ledger-proven committed photo.',
      );
    },
  );

  test('activity observer failure never fails an accepted photo', () async {
    session.bindManualSfmFrameSink((_) => true);
    session.bindManualCaptureActivitySink((_) {
      throw StateError('diagnostic observer failed');
    });

    final capture = await session.captureSinglePhoto();
    expect(capture, isNotNull);
    await provider.completeCommitted();
    expect((await capture!.committed).committed, isTrue);
    await capture.completion;
  });

  test(
    'missing gray and durable queue rejection are explicit failures',
    () async {
      session.bindManualSfmFrameSink((_) => false);
      final rejected = await session.captureSinglePhoto();
      expect(rejected, isNotNull);
      final rejectedCompletion = expectLater(
        rejected!.completion,
        throwsA(isA<ManualPhotoCaptureException>()),
      );
      await provider.completeCommitted();
      expect((await rejected.committed).committed, isTrue);
      await rejectedCompletion;
      await expectLater(
        session.waitForPendingPhotoSaves(),
        throwsA(isA<CapturePhotoSaveBarrierException>()),
      );

      await session.dispose();
      await provider.close();

      provider = _ManualV2PoseProvider();
      session = CaptureSession(poseProvider: provider);
      await session.start(autoLock: false, manualCapture: true);
      provider.emitPose();
      await Future<void>.delayed(Duration.zero);
      session.bindManualSfmFrameSink((_) => true);

      final missingGray = await session.captureSinglePhoto();
      expect(missingGray, isNotNull);
      final missingGrayCompletion = expectLater(
        missingGray!.completion,
        throwsA(isA<ManualPhotoCaptureException>()),
      );
      await provider.completeCommitted(writeGray: false);
      await missingGrayCompletion;
      await expectLater(
        session.waitForPendingPhotoSaves(),
        throwsA(isA<CapturePhotoSaveBarrierException>()),
      );
    },
  );

  test('reservation failure is durable attempted+blocked evidence', () async {
    provider.reserveFailure = StateError('native intent fsync failed');

    await expectLater(
      session.captureSinglePhoto(),
      throwsA(
        isA<ManualPhotoCaptureException>().having(
          (error) => error.code,
          'code',
          'snapshot_reservation_failed',
        ),
      ),
    );

    final evidence = await loadPersistedManualCaptureEvidence(
      session.captureDir!,
    );
    expect(evidence.ledger.jobs, hasLength(1));
    final job = evidence.ledger.jobs.values.single;
    expect(job.stage, ManualCaptureStage.attempted);
    expect(job.blocked, isTrue);
    expect(job.blockers.values.single.code, 'snapshot_reservation_failed');

    // A second cold read must replay `blocked`, not reject the event schema.
    final reopened = await loadPersistedManualCaptureEvidence(
      session.captureDir!,
    );
    expect(reopened.ledger.jobs.values.single.blocked, isTrue);
    await expectLater(
      session.waitForPendingPhotoSaves(),
      throwsA(isA<CapturePhotoSaveBarrierException>()),
    );
  });

  test('missing pose is an exact pre-reservation finalize blocker', () async {
    await session.dispose();
    await provider.close();
    provider = _ManualV2PoseProvider();
    session = CaptureSession(poseProvider: provider);
    await session.start(autoLock: false, manualCapture: true);

    await expectLater(
      session.captureSinglePhoto(),
      throwsA(
        isA<ManualPhotoCaptureException>().having(
          (error) => error.code,
          'code',
          'manual_capture_pose_unavailable',
        ),
      ),
    );
    await expectLater(
      session.waitForPendingPhotoSaves(),
      throwsA(isA<CapturePhotoSaveBarrierException>()),
    );

    final evidence = await loadPersistedManualCaptureEvidence(
      session.captureDir!,
    );
    expect(evidence.ledger.jobs, hasLength(1));
    final job = evidence.ledger.jobs.values.single;
    expect(job.stage, ManualCaptureStage.attempted);
    expect(job.blocked, isTrue);
    expect(job.blockers.values.single.code, 'manual_capture_pose_unavailable');
    expect(provider.request, isNull);
  });

  test('capture directory setup failure blocks the active take', () async {
    await session.dispose();
    await provider.close();
    final invalidDocumentsRoot = File(
      '${documentsDirectory.path}/not-a-directory',
    );
    await invalidDocumentsRoot.writeAsString('file');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          pathProviderChannel,
          (_) async => invalidDocumentsRoot.path,
        );

    provider = _ManualV2PoseProvider();
    session = CaptureSession(poseProvider: provider);
    await session.start(autoLock: false, manualCapture: true);
    provider.emitPose();
    await Future<void>.delayed(Duration.zero);

    await expectLater(
      session.captureSinglePhoto(),
      throwsA(
        isA<ManualPhotoCaptureException>().having(
          (error) => error.code,
          'code',
          'manual_capture_directory_unavailable',
        ),
      ),
    );
    await expectLater(
      session.waitForPendingPhotoSaves(),
      throwsA(isA<CapturePhotoSaveBarrierException>()),
    );
    expect(session.captureDir, isNull);
    expect(provider.request, isNull);
  });

  test('unsupported manual provider remains a finalize blocker', () async {
    await session.dispose();
    final unsupported = _NoManualPoseProvider();
    addTearDown(unsupported.close);
    session = CaptureSession(poseProvider: unsupported);
    await session.start(autoLock: false, manualCapture: true);
    unsupported.emitPose();
    await Future<void>.delayed(Duration.zero);
    final root = Directory(session.captureDir!);

    await expectLater(
      session.captureSinglePhoto(),
      throwsA(
        isA<ManualPhotoCaptureException>().having(
          (error) => error.code,
          'code',
          'manual_capture_v2_unsupported',
        ),
      ),
    );
    await expectLater(
      session.waitForPendingPhotoSaves(),
      throwsA(isA<CapturePhotoSaveBarrierException>()),
    );
    await session.discardCurrentCapture();
    expect(root.existsSync(), isFalse);
  });

  test(
    'invalid reservation waits for native settlement before discard',
    () async {
      provider.invalidReservation = true;
      final root = Directory(session.captureDir!);

      await expectLater(
        session.captureSinglePhoto(),
        throwsA(
          isA<ManualPhotoCaptureException>().having(
            (error) => error.code,
            'code',
            'invalid_snapshot_reservation',
          ),
        ),
      );
      var discarded = false;
      final discard = session.discardCurrentCapture().whenComplete(
        () => discarded = true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(discarded, isFalse);

      await provider.completeCommitted();
      await discard.timeout(const Duration(seconds: 2));
      expect(root.existsSync(), isFalse);
      expect(provider.discardObservedTerminal, isTrue);
    },
  );

  test(
    'mismatched native job is isolated and both identities quiesce',
    () async {
      provider.invalidCaptureJobID = 'native-wrong-job';

      await expectLater(
        session.captureSinglePhoto(),
        throwsA(
          isA<ManualPhotoCaptureException>().having(
            (error) => error.code,
            'code',
            'invalid_snapshot_reservation',
          ),
        ),
      );
      var barrierFinished = false;
      final barrier = session.waitForPendingPhotoSaves().whenComplete(
        () => barrierFinished = true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(barrierFinished, isFalse);
      expect(provider.awaitedJobIDs, contains('native-wrong-job'));
      expect(provider.awaitedJobIDs, contains(provider.request!.captureJobID));

      await provider.completeCommitted();
      await expectLater(
        barrier,
        throwsA(isA<CapturePhotoSaveBarrierException>()),
      );
    },
  );

  test(
    'first ledger failure remains an exact finalize blocker until discard',
    () async {
      final root = Directory(session.captureDir!);
      final ledgerPath = '${root.path}/manual_capture_registration_ledger.json';
      Directory(ledgerPath).createSync();

      await expectLater(
        session.captureSinglePhoto(),
        throwsA(
          isA<ManualPhotoCaptureException>().having(
            (error) => error.code,
            'code',
            'manual_ledger_write_failed',
          ),
        ),
      );

      expect(
        provider.request,
        isNull,
        reason: 'Native reserve must not start.',
      );
      expect(session.unpersistedManualAttemptPaths, hasLength(1));
      expect(
        session.unpersistedManualAttemptPaths.values.single,
        endsWith('.jpg'),
      );
      final unpersistedPath =
          session.unpersistedManualAttemptPaths.values.single;
      await File(unpersistedPath).writeAsBytes(const <int>[1], flush: true);
      expect(
        await session.reconcileCapturedPhotosFromDisk(),
        isNot(contains(unpersistedPath)),
      );
      await expectLater(
        session.waitForPendingPhotoSaves(),
        throwsA(isA<CapturePhotoSaveBarrierException>()),
      );

      await session.discardCurrentCapture();
      expect(root.existsSync(), isFalse);
      expect(session.unpersistedManualAttemptPaths, isEmpty);
    },
  );

  test(
    'accepted ledger failure still holds discard until native settles',
    () async {
      late String attemptedLedgerDocument;
      late String ledgerPath;
      provider.onReserved = (_) {
        ledgerPath =
            '${session.captureDir!}/manual_capture_registration_ledger.json';
        final ledgerFile = File(ledgerPath);
        attemptedLedgerDocument = ledgerFile.readAsStringSync();
        ledgerFile.deleteSync();
        Directory(ledgerPath).createSync();
      };

      await expectLater(
        session.captureSinglePhoto(),
        throwsA(
          isA<ManualPhotoCaptureException>().having(
            (error) => error.code,
            'code',
            'manual_ledger_write_failed',
          ),
        ),
      );
      final root = Directory(session.captureDir!);
      var discardFinished = false;
      final discard = session.discardCurrentCapture().whenComplete(
        () => discardFinished = true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        discardFinished,
        isFalse,
        reason:
            'Native owns a reserved writer even though Dart acceptance failed.',
      );

      Directory(ledgerPath).deleteSync();
      File(ledgerPath).writeAsStringSync(attemptedLedgerDocument, flush: true);
      await provider.completeCommitted();
      await discard.timeout(const Duration(seconds: 2));

      expect(root.existsSync(), isFalse);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(
        root.existsSync(),
        isFalse,
        reason: 'A settled native writer cannot recreate the discarded take.',
      );
    },
  );

  test('user deletion tombstones queued frame and survives restart', () async {
    session.bindManualSfmFrameSink((_) => true);
    final capture = await session.captureSinglePhoto();
    expect(capture, isNotNull);
    await provider.completeCommitted();
    await capture!.completion;
    expect(File(capture.jpegPath).existsSync(), isTrue);

    await session.deleteCapturedPhotoByUser(capture.jpegPath);

    expect(File(capture.jpegPath).existsSync(), isFalse);
    expect(
      session.manualCaptureLedger.job(capture.captureJobID)!.userDeleted,
      isTrue,
    );
    expect(session.manualCaptureLedger.rebuildRequired, isTrue);
    final reopened = await loadPersistedManualCaptureEvidence(
      session.captureDir!,
    );
    expect(reopened.ledger.job(capture.captureJobID)!.userDeleted, isTrue);
    expect(reopened.ledger.rebuildRequired, isTrue);

    // Simulate a process/I/O failure after the durable tombstone but before
    // authorized bytes were removed. A retry must perform cleanup only; it
    // must not append a second taint/tombstone or resurrect the job.
    final eventCount = session.manualCaptureLedger.events.length;
    final stem = capture.jpegPath.substring(0, capture.jpegPath.length - 4);
    await File(capture.jpegPath).writeAsBytes(const <int>[9], flush: true);
    await File('$stem.json').writeAsString('{}', flush: true);
    await File('$stem.sfm-gray').writeAsBytes(const <int>[8], flush: true);
    await File(
      '$stem.manual-v2-committed.json',
    ).writeAsString('{}', flush: true);

    await session.deleteCapturedPhotoByUser(capture.jpegPath);

    expect(session.manualCaptureLedger.events, hasLength(eventCount));
    expect(File(capture.jpegPath).existsSync(), isFalse);
    expect(File('$stem.json').existsSync(), isFalse);
    expect(File('$stem.sfm-gray').existsSync(), isFalse);
    expect(File('$stem.manual-v2-committed.json').existsSync(), isFalse);
  });

  test(
    'cold deletion request waits for exact native terminal then completes once',
    () async {
      session.bindManualSfmFrameSink((_) => true);
      final capture = await session.captureSinglePhoto();
      await provider.completeCommitted();
      await capture!.completion;

      final ledgerFile = File(
        '${session.captureDir!}/manual_capture_registration_ledger.json',
      );
      final document = Map<String, Object?>.from(
        jsonDecode(await ledgerFile.readAsString()) as Map,
      );
      final events = List<Object?>.from(document['events']! as List)
        ..add(
          ManualCaptureEvent.userDeletionRequested(
            capture.captureJobID,
          ).toJson(),
        );
      document['events'] = events;
      await ledgerFile.writeAsString(jsonEncode(document), flush: true);

      ManualCaptureV2RecoveryJob nativeWithStatus(String status) =>
          ManualCaptureV2RecoveryJob(
            captureJobID: capture.captureJobID,
            status: status,
            jpegPath: capture.jpegPath,
            metadataPath: capture.reservation.metadataPath,
            sfmGrayPath: capture.reservation.sfmGrayPath,
            frameIdentity: 'tap-cold-delete',
            snapshotIdentity: 'snapshot-cold-delete',
            intentDurable: true,
            commitMarkerPresent: status == 'committed',
            captureCommitReceiptPresent: status == 'committed',
            artifactReceipts: const <ManualCaptureV2ArtifactReceipt>[],
          );

      final before = await loadPersistedManualCaptureEvidence(
        session.captureDir!,
      );
      expect(
        before.ledger.job(capture.captureJobID)!.deletionRequested,
        isTrue,
      );
      expect(before.ledger.job(capture.captureJobID)!.userDeleted, isFalse);

      await expectLater(
        completePersistedManualDeletionRequestsAfterColdNativeReconciliation(
          captureDir: session.captureDir!,
          nativeJobs: <ManualCaptureV2RecoveryJob>[
            nativeWithStatus('raw_spill_pending'),
          ],
        ),
        throwsA(isA<StateError>()),
      );
      final afterPending = await loadPersistedManualCaptureEvidence(
        session.captureDir!,
      );
      expect(
        afterPending.ledger.events,
        hasLength(before.ledger.events.length),
      );
      expect(
        afterPending.ledger.job(capture.captureJobID)!.userDeleted,
        isFalse,
      );

      await expectLater(
        completePersistedManualDeletionRequestsAfterColdNativeReconciliation(
          captureDir: session.captureDir!,
          nativeJobs: const <ManualCaptureV2RecoveryJob>[],
        ),
        throwsA(isA<StateError>()),
      );
      final committedNative = nativeWithStatus('committed');
      await expectLater(
        completePersistedManualDeletionRequestsAfterColdNativeReconciliation(
          captureDir: session.captureDir!,
          nativeJobs: <ManualCaptureV2RecoveryJob>[
            committedNative,
            committedNative,
          ],
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        (await loadPersistedManualCaptureEvidence(
          session.captureDir!,
        )).ledger.events,
        hasLength(before.ledger.events.length),
      );

      final completed =
          await completePersistedManualDeletionRequestsAfterColdNativeReconciliation(
            captureDir: session.captureDir!,
            nativeJobs: <ManualCaptureV2RecoveryJob>[committedNative],
          );
      final deleted = completed.ledger.job(capture.captureJobID)!;
      expect(deleted.writersQuiesced, isTrue);
      expect(deleted.userDeleted, isTrue);
      expect(completed.ledger.rebuildRequired, isTrue);
      final completedEventCount = completed.ledger.events.length;

      final repeated =
          await completePersistedManualDeletionRequestsAfterColdNativeReconciliation(
            captureDir: session.captureDir!,
            nativeJobs: <ManualCaptureV2RecoveryJob>[
              nativeWithStatus('committed'),
            ],
          );
      expect(repeated.ledger.events, hasLength(completedEventCount));
      expect(File(capture.jpegPath).existsSync(), isTrue);
    },
  );

  test('explicit whole-take discard waits through failed completion', () async {
    session.bindManualSfmFrameSink((_) => false);
    final capture = await session.captureSinglePhoto();
    final failed = expectLater(
      capture!.completion,
      throwsA(isA<ManualPhotoCaptureException>()),
    );
    await provider.completeCommitted();
    await failed;
    final root = Directory(session.captureDir!);
    expect(root.existsSync(), isTrue);

    await session.discardCurrentCapture();

    expect(root.existsSync(), isFalse);
    expect(provider.discardCalls, 1);
    expect(provider.discardObservedTerminal, isTrue);
    expect(provider.discardObservedRoot, isTrue);
  });

  test(
    'discard preserves exact retry state until native and root cleanup succeed',
    () async {
      await session.dispose();
      await provider.close();
      provider = _ManualV2PoseProvider();
      var rootDeleteFails = true;
      session = CaptureSession(
        poseProvider: provider,
        discardDirectoryDeleter: (directory) async {
          if (rootDeleteFails) {
            throw FileSystemException('injected recursive delete failure');
          }
          await directory.delete(recursive: true);
        },
      );
      await session.start(autoLock: false, manualCapture: true);
      provider.emitPose();
      await Future<void>.delayed(Duration.zero);
      session.bindManualSfmFrameSink((_) => true);
      final capture = await session.captureSinglePhoto();
      await provider.completeCommitted();
      await capture!.completion;
      final root = Directory(session.captureDir!);

      provider.discardFailure = StateError('native private cleanup failed');
      await expectLater(
        session.discardCurrentCapture(),
        throwsA(isA<StateError>()),
      );
      expect(root.existsSync(), isTrue);
      expect(session.captureDir, root.path);
      expect(session.capturedPhotoPaths, isNotEmpty);

      provider.discardFailure = null;
      await expectLater(
        session.discardCurrentCapture(),
        throwsA(isA<FileSystemException>()),
      );
      expect(root.existsSync(), isTrue);
      expect(session.captureDir, root.path);
      expect(session.capturedPhotoPaths, isNotEmpty);

      rootDeleteFails = false;
      await session.discardCurrentCapture();
      expect(root.existsSync(), isFalse);
      expect(session.captureDir, isNull);
      expect(provider.discardCalls, 3);
      expect(provider.discardObservedTerminal, isTrue);
      expect(provider.discardObservedRoot, isTrue);
    },
  );

  test(
    'cold native commit plus exact queue ACK recovers unknown Dart job',
    () async {
      final captureDir = Directory('${documentsDirectory.path}/cold-cap');
      await captureDir.create(recursive: true);
      final jpeg = '${captureDir.path}/photos_highres/tap-1.jpg';
      final metadata = '${captureDir.path}/photos_highres/tap-1.json';
      final gray = '${captureDir.path}/photos_highres/tap-1.sfm-gray';
      final queue = await SfmDurableFeedQueue.open(
        Directory('${captureDir.path}/sfm_live.db.sfm-feed'),
      );
      addTearDown(queue.close);
      await File(gray).parent.create(recursive: true);
      await File(gray).writeAsBytes(const <int>[1, 2, 3, 4], flush: true);
      await queue.enqueueGrayFile(
        sourceGrayFile: File(gray),
        expectedByteLength: 4,
        metadata: <String, Object?>{
          'captureJobId': 'cold-job-1',
          'jpegPath': jpeg,
          'sfmGraySha256': _gray4Sha256,
        },
      );
      final claim = await queue.claimNext();
      await queue.acknowledge(
        frameId: claim!.frame.id,
        nativeOk: true,
        fedMeta: <String, Object?>{
          ...claim.frame.metadata,
          'nativeFrameId': 17,
        },
      );
      final native = ManualCaptureV2RecoveryJob(
        captureJobID: 'cold-job-1',
        status: 'committed',
        jpegPath: jpeg,
        metadataPath: metadata,
        sfmGrayPath: gray,
        frameIdentity: 'tap-1',
        snapshotIdentity: 'snapshot-cold-1',
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
            path: metadata,
            byteLength: 4,
            sha256: ''.padLeft(64, 'b'),
          ),
          ManualCaptureV2ArtifactReceipt(
            kind: 'sfm_gray',
            path: gray,
            byteLength: 4,
            sha256: _gray4Sha256,
          ),
        ],
      );

      final wrongGrayReceipt = ManualCaptureV2RecoveryJob(
        captureJobID: native.captureJobID,
        status: native.status,
        jpegPath: native.jpegPath,
        metadataPath: native.metadataPath,
        sfmGrayPath: native.sfmGrayPath,
        frameIdentity: native.frameIdentity,
        snapshotIdentity: native.snapshotIdentity,
        intentDurable: native.intentDurable,
        commitMarkerPresent: native.commitMarkerPresent,
        captureCommitReceiptPresent: native.captureCommitReceiptPresent,
        artifactReceipts: <ManualCaptureV2ArtifactReceipt>[
          ...native.artifactReceipts.where(
            (receipt) => receipt.kind != 'sfm_gray',
          ),
          ManualCaptureV2ArtifactReceipt(
            kind: 'sfm_gray',
            path: gray,
            byteLength: 4,
            sha256: ''.padLeft(64, 'd'),
          ),
        ],
      );
      final refused = await reconcilePersistedManualCaptureJobsFromNative(
        captureDir: captureDir.path,
        durableQueue: queue,
        nativeJobs: <ManualCaptureV2RecoveryJob>[wrongGrayReceipt],
      );
      expect(
        refused.ledger.job('cold-job-1'),
        isNull,
        reason: 'Job/JPEG equality cannot substitute for exact gray receipt.',
      );

      final repaired = await reconcilePersistedManualCaptureJobsFromNative(
        captureDir: captureDir.path,
        durableQueue: queue,
        nativeJobs: <ManualCaptureV2RecoveryJob>[native],
      );
      expect(
        repaired.ledger.job('cold-job-1')!.stage,
        ManualCaptureStage.sfmIngested,
      );

      final snapshot = SfmLiveSnapshot(
        xyz: Float32List(0),
        rgb: Uint8List(0),
        posesPacked: Float64List.fromList(<double>[17, 1, 1, 0, 0, 0, 0, 0, 0]),
        summary: const <String, Object?>{},
        refined: true,
        obsOffsets: Int32List.fromList(const <int>[0]),
        obsFrameIds: Int32List(0),
        obsXY: Float32List(0),
      );
      final finalEvidence = await reconcilePersistedManualFinalRegistration(
        captureDir: captureDir.path,
        durableQueue: queue,
        snapshot: snapshot,
        artifactIdentity: 'cold-final-artifact',
        evidenceToken: 'cold-final-evidence',
      );
      final decision = evaluateSfmRegistrationPublishGate(
        durableQueue: queue,
        ledger: finalEvidence.ledger,
        finalRegistration: finalEvidence.finalRegistration,
        snapshot: snapshot,
      );
      expect(decision.canPublish, isTrue);
      expect(finalEvidence.ledger.currentJobToNativeImageId, {
        'cold-job-1': '17',
      });
    },
  );

  test(
    'cold native failure is persisted on its exact job with diagnostic code',
    () async {
      final captureDir = Directory('${documentsDirectory.path}/failed-cap');
      await captureDir.create(recursive: true);
      final jpeg = '${captureDir.path}/photos_highres/tap-failed.jpg';
      final native = ManualCaptureV2RecoveryJob.fromPlatformReply(
        <String, Object?>{
          'capture_job_id': 'cold-job-failed',
          'status': 'failed',
          'jpeg_path': jpeg,
          'metadata_path': '${captureDir.path}/photos_highres/tap-failed.json',
          'sfm_gray_path':
              '${captureDir.path}/photos_highres/tap-failed.sfm-gray',
          'frame_identity': 'tap-failed',
          'snapshot_identity': 'snapshot-failed',
          'intent_durable': true,
          'commit_marker_present': false,
          'capture_commit_receipt_present': false,
          'artifact_receipts': <Object?>[],
          'error_code': 'manual_capture_encode_failed',
          'message': 'JPEG encoder rejected the snapshot',
          'recoverable': false,
        },
      );

      final repaired = await persistNativeManualCaptureFailures(
        captureDir: captureDir.path,
        nativeJobs: <ManualCaptureV2RecoveryJob>[native],
      );

      final failedJob = repaired.ledger.job('cold-job-failed')!;
      expect(failedJob.stage, ManualCaptureStage.attempted);
      expect(repaired.jobToJpegPath['cold-job-failed'], jpeg);
      expect(failedJob.blockers, hasLength(1));
      expect(
        failedJob.blockers.values.single.code,
        'manual_capture_encode_failed',
      );
      expect(
        failedJob.blockers.values.single.message,
        contains('capture_job_id=cold-job-failed'),
      );
      expect(failedJob.blockers.values.single.message, contains('false'));
      expect(
        Directory('${captureDir.path}/sfm_live.db.sfm-feed').existsSync(),
        isFalse,
        reason: 'A pre-ACK failure must not fabricate queue state.',
      );

      final reopened = await loadPersistedManualCaptureEvidence(
        captureDir.path,
      );
      expect(
        reopened.ledger.job('cold-job-failed')!.blockers.values.single.code,
        'manual_capture_encode_failed',
      );
    },
  );

  test(
    'overlapping taps keep isolated jobs through out-of-order commits',
    () async {
      await session.dispose();
      await provider.close();

      final concurrentProvider = _ConcurrentManualV2PoseProvider();
      addTearDown(concurrentProvider.close);
      session = CaptureSession(poseProvider: concurrentProvider);
      await session.start(autoLock: false, manualCapture: true);
      concurrentProvider.emitPose();
      await Future<void>.delayed(Duration.zero);

      final offered = <SfmFrameFeed>[];
      session.bindManualSfmFrameSink((feed) {
        offered.add(feed);
        return true;
      });

      final captures = (await Future.wait(<Future<ManualPhotoCapture?>>[
        session.captureSinglePhoto(),
        session.captureSinglePhoto(),
        session.captureSinglePhoto(),
      ])).whereType<ManualPhotoCapture>().toList(growable: false);

      expect(captures, hasLength(3));
      final jobIDs = captures
          .map((capture) => capture.reservation.captureJobID)
          .toList(growable: false);
      expect(jobIDs.toSet(), hasLength(3));

      await concurrentProvider.completeCommitted(jobIDs[2]);
      await concurrentProvider.completeCommitted(jobIDs[0]);
      await concurrentProvider.completeCommitted(jobIDs[1]);
      await Future.wait(captures.map((capture) => capture.completion));
      await session.waitForPendingPhotoSaves();

      expect(offered, hasLength(3));
      expect(offered.map((feed) => feed.jpegPath).toSet(), hasLength(3));
      expect(session.capturedPhotoPaths.toSet(), hasLength(3));
      expect(
        offered.map((feed) => feed.jpegPath).toSet(),
        session.capturedPhotoPaths.toSet(),
      );
    },
  );

  test(
    'manual publications hold foreground priority until every job terminates',
    () async {
      await session.dispose();
      await provider.close();

      final concurrentProvider = _ConcurrentManualV2PoseProvider();
      addTearDown(concurrentProvider.close);
      session = CaptureSession(poseProvider: concurrentProvider);
      await session.start(autoLock: false, manualCapture: true);
      concurrentProvider.emitPose();
      await Future<void>.delayed(Duration.zero);

      final activity = <bool>[];
      session.bindManualCaptureActivitySink(activity.add);
      session.bindManualSfmFrameSink((_) => true);

      final captures = (await Future.wait(<Future<ManualPhotoCapture?>>[
        session.captureSinglePhoto(),
        session.captureSinglePhoto(),
        session.captureSinglePhoto(),
      ])).whereType<ManualPhotoCapture>().toList(growable: false);
      final jobIDs = captures
          .map((capture) => capture.captureJobID)
          .toList(growable: false);

      expect(activity, <bool>[false, true]);
      await concurrentProvider.completeCommitted(jobIDs[2]);
      await captures.singleWhere((c) => c.captureJobID == jobIDs[2]).committed;
      expect(activity, <bool>[false, true]);
      await concurrentProvider.completeCommitted(jobIDs[0]);
      await captures.singleWhere((c) => c.captureJobID == jobIDs[0]).committed;
      expect(activity, <bool>[false, true]);
      await concurrentProvider.completeCommitted(jobIDs[1]);
      await captures.singleWhere((c) => c.captureJobID == jobIDs[1]).committed;
      expect(activity, <bool>[false, true, false]);

      await Future.wait(captures.map((capture) => capture.completion));
    },
  );
}

Future<void> _writeExactDurableV2Receipt({
  required ManualPhotoCapture capture,
  required String frameID,
}) async {
  final jpeg = File(capture.jpegPath);
  final sidecar = File(capture.reservation.metadataPath);
  final gray = File(capture.reservation.sfmGrayPath);
  final stem = sidecar.path.substring(0, sidecar.path.length - '.json'.length);
  final marker = File('$stem.manual-v2-committed.json');
  const snapshotIdentity = 'snapshot-live-visibility';
  await jpeg.writeAsBytes(const <int>[1, 2, 3], flush: true);
  await gray.writeAsBytes(const <int>[1, 2, 3, 4], flush: true);
  await sidecar.writeAsString(
    jsonEncode(<String, Object?>{
      'version': 1,
      'manual_capture_schema': 'aether_manual_capture_v2_durable_v2',
      'capture_job_id': capture.captureJobID,
      'frame_identity': frameID,
      'snapshot_identity': snapshotIdentity,
      'durable_commit_marker_path': marker.absolute.path,
      't': 42.0,
      'image_w': 4,
      'image_h': 4,
      'sfm_gray_path': gray.absolute.path,
      'sfm_gray_w': 2,
      'sfm_gray_h': 2,
      'intrinsics_fxfycxcy': <double>[100, 100, 2, 2],
      'extrinsic': <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1],
      'dart_save_contract': <String, Object?>{
        'frame_id': frameID,
        'jpeg_path': jpeg.absolute.path,
        'metadata_path': sidecar.absolute.path,
      },
    }),
    flush: true,
  );
  Future<Map<String, Object?>> receipt(String kind, File file) async =>
      <String, Object?>{
        'kind': kind,
        'finalPath': file.absolute.path,
        'byteLength': await file.length(),
        'sha256': sha256.convert(await file.readAsBytes()).toString(),
      };
  await marker.writeAsString(
    jsonEncode(<String, Object?>{
      'schemaVersion': 1,
      'captureJobID': capture.captureJobID,
      'snapshotIdentity': snapshotIdentity,
      'preparedSha256': ''.padLeft(64, 'a'),
      'committedUnixMicros': 1,
      'artifacts': <Object?>[
        await receipt('jpeg', jpeg),
        await receipt('metadata', sidecar),
        await receipt('sfm_gray', gray),
      ],
    }),
    flush: true,
  );
}

class _ManualV2PoseProvider
    implements
        ARPoseProvider,
        ManualCaptureV2Provider,
        ManualCaptureV2DiscardProvider {
  final StreamController<ARPose> _poses = StreamController<ARPose>.broadcast();
  final Completer<ManualCaptureV2Result> terminal =
      Completer<ManualCaptureV2Result>();

  ManualCaptureV2Request? request;
  Object? reserveFailure;
  bool invalidReservation = false;
  String? invalidCaptureJobID;
  final List<String> awaitedJobIDs = <String>[];
  void Function(ManualCaptureV2Request request)? onReserved;
  int discardCalls = 0;
  bool discardObservedTerminal = false;
  bool discardObservedRoot = false;
  Object? discardFailure;
  ARPose? _lastPose;

  void emitPose() {
    final pose = ARPose(
      position: Vector3(0, 0, 1),
      orientation: Quaternion.identity(),
      azimuth: 0,
      elevation: 0,
      isTracking: true,
      timestamp: 42,
      hasOrigin: true,
      worldOrigin: Vector3.zero(),
      worldYaw: 0,
      extrinsic4x4: const <double>[
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
        1,
        1,
      ],
      intrinsicFxFyCxCy: const <double>[100, 100, 2, 2],
      imageWidth: 4,
      imageHeight: 4,
      trackingStateName: 'normal',
    );
    _lastPose = pose;
    _poses.add(pose);
  }

  Future<void> completeCommitted({bool writeGray = true}) async {
    final active = request!;
    await File(active.saveSpec.jpegPath).writeAsBytes(const <int>[1, 2, 3]);
    await File(active.saveSpec.metadataPath).writeAsString('{}');
    if (writeGray) {
      await File(active.sfmGrayPath).writeAsBytes(const <int>[1, 2, 3, 4]);
    }
    terminal.complete(
      ManualCaptureV2Result(
        captureJobID: active.captureJobID,
        status: 'committed',
        jpegPath: active.saveSpec.jpegPath,
        metadataPath: active.saveSpec.metadataPath,
        sfmGrayPath: active.sfmGrayPath,
        sfmGrayWidth: 2,
        sfmGrayHeight: 2,
        sfmGrayByteLength: 4,
        sfmGraySha256: _gray4Sha256,
        timestamp: 42,
        imageWidth: 4,
        imageHeight: 4,
        intrinsicFxFyCxCy: const <double>[100, 100, 2, 2],
        extrinsic4x4: const <double>[
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
          1,
          1,
        ],
      ),
    );
  }

  Future<void> close() async {
    await _poses.close();
  }

  @override
  ARPose? get lastPose => _lastPose;

  @override
  Stream<ARPose> start() => _poses.stream;

  @override
  Future<ManualCaptureV2Ticket> reserveManualCaptureV2(
    ManualCaptureV2Request request,
  ) async {
    final failure = reserveFailure;
    if (failure != null) throw failure;
    this.request = request;
    onReserved?.call(request);
    return ManualCaptureV2Ticket(
      captureJobID: invalidCaptureJobID ?? request.captureJobID,
      status: 'snapshot_reserved',
      snapshotTimestamp: 42,
      jpegPath: invalidReservation
          ? '${request.saveSpec.jpegPath}.wrong'
          : request.saveSpec.jpegPath,
      metadataPath: request.saveSpec.metadataPath,
      sfmGrayPath: request.sfmGrayPath,
    );
  }

  @override
  Future<ManualCaptureV2Result> awaitManualCaptureV2(String captureJobID) {
    awaitedJobIDs.add(captureJobID);
    return terminal.future;
  }

  @override
  Future<ManualCaptureV2DiscardReceipt> discardManualCaptureV2Jobs(
    String captureDirectory,
  ) async {
    discardCalls += 1;
    discardObservedTerminal = request == null || terminal.isCompleted;
    discardObservedRoot = Directory(captureDirectory).existsSync();
    final failure = discardFailure;
    if (failure != null) throw failure;
    return ManualCaptureV2DiscardReceipt(
      captureDirectory: captureDirectory,
      discardedJobIds: request == null
          ? const <String>[]
          : <String>[request!.captureJobID],
      releasedRawBytes: 0,
      backlogMetrics: const <String, Object?>{'raw_bytes': 0},
    );
  }

  @override
  Future<ARLockResult?> lockOrigin({double distanceMeters = 1.0}) async => null;

  @override
  Future<bool> saveCurrentFrameAsJpeg({
    required String jpegPath,
    required String metadataPath,
    double? targetTimestamp,
    double maxTimestampDelta = 0.18,
    double quality = 0.9,
  }) async => false;

  @override
  Future<ARFrameSaveResult> saveCurrentFrame(ARFrameSaveSpec spec) async =>
      ARFrameSaveResult(spec: spec, status: 'unsupported');

  @override
  Future<HighResolutionStillCapture?> captureHighResolutionStill({
    required String highresPath,
    required String previewPath,
    double? triggerTimestamp,
    double quality = 0.92,
    ARFrameSaveSpec? saveSpec,
  }) async => null;

  @override
  Future<void> stop() async {}
}

class _NoManualPoseProvider implements ARPoseProvider {
  final _ManualV2PoseProvider _delegate = _ManualV2PoseProvider();

  void emitPose() => _delegate.emitPose();
  Future<void> close() => _delegate.close();

  @override
  ARPose? get lastPose => _delegate.lastPose;

  @override
  Stream<ARPose> start() => _delegate.start();

  @override
  Future<ARLockResult?> lockOrigin({double distanceMeters = 1.0}) =>
      _delegate.lockOrigin(distanceMeters: distanceMeters);

  @override
  Future<bool> saveCurrentFrameAsJpeg({
    required String jpegPath,
    required String metadataPath,
    double? targetTimestamp,
    double maxTimestampDelta = 0.18,
    double quality = 0.9,
  }) => _delegate.saveCurrentFrameAsJpeg(
    jpegPath: jpegPath,
    metadataPath: metadataPath,
    targetTimestamp: targetTimestamp,
    maxTimestampDelta: maxTimestampDelta,
    quality: quality,
  );

  @override
  Future<ARFrameSaveResult> saveCurrentFrame(ARFrameSaveSpec spec) =>
      _delegate.saveCurrentFrame(spec);

  @override
  Future<HighResolutionStillCapture?> captureHighResolutionStill({
    required String highresPath,
    required String previewPath,
    double? triggerTimestamp,
    double quality = 0.92,
    ARFrameSaveSpec? saveSpec,
  }) => _delegate.captureHighResolutionStill(
    highresPath: highresPath,
    previewPath: previewPath,
    triggerTimestamp: triggerTimestamp,
    quality: quality,
    saveSpec: saveSpec,
  );

  @override
  Future<void> stop() => _delegate.stop();
}

class _ConcurrentManualV2PoseProvider
    implements ARPoseProvider, ManualCaptureV2Provider {
  final StreamController<ARPose> _poses = StreamController<ARPose>.broadcast();
  final Map<String, ManualCaptureV2Request> _requests =
      <String, ManualCaptureV2Request>{};
  final Map<String, Completer<ManualCaptureV2Result>> _terminals =
      <String, Completer<ManualCaptureV2Result>>{};
  ARPose? _lastPose;

  void emitPose() {
    final pose = ARPose(
      position: Vector3(0, 0, 1),
      orientation: Quaternion.identity(),
      azimuth: 0,
      elevation: 0,
      isTracking: true,
      timestamp: 42,
      hasOrigin: true,
      worldOrigin: Vector3.zero(),
      worldYaw: 0,
      extrinsic4x4: const <double>[
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
        1,
        1,
      ],
      intrinsicFxFyCxCy: const <double>[100, 100, 2, 2],
      imageWidth: 4,
      imageHeight: 4,
      trackingStateName: 'normal',
    );
    _lastPose = pose;
    _poses.add(pose);
  }

  Future<void> completeCommitted(String captureJobID) async {
    final request = _requests[captureJobID]!;
    await File(request.saveSpec.jpegPath).writeAsBytes(const <int>[1, 2, 3]);
    await File(request.saveSpec.metadataPath).writeAsString('{}');
    await File(request.sfmGrayPath).writeAsBytes(const <int>[1, 2, 3, 4]);
    _terminals[captureJobID]!.complete(
      ManualCaptureV2Result(
        captureJobID: captureJobID,
        status: 'committed',
        jpegPath: request.saveSpec.jpegPath,
        metadataPath: request.saveSpec.metadataPath,
        sfmGrayPath: request.sfmGrayPath,
        sfmGrayWidth: 2,
        sfmGrayHeight: 2,
        sfmGrayByteLength: 4,
        sfmGraySha256: _gray4Sha256,
        timestamp: 42,
        imageWidth: 4,
        imageHeight: 4,
        intrinsicFxFyCxCy: const <double>[100, 100, 2, 2],
        extrinsic4x4: const <double>[
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
          1,
          1,
        ],
      ),
    );
  }

  Future<void> close() => _poses.close();

  @override
  ARPose? get lastPose => _lastPose;

  @override
  Stream<ARPose> start() => _poses.stream;

  @override
  Future<ManualCaptureV2Ticket> reserveManualCaptureV2(
    ManualCaptureV2Request request,
  ) async {
    if (_requests.containsKey(request.captureJobID)) {
      throw StateError('duplicate capture job ${request.captureJobID}');
    }
    _requests[request.captureJobID] = request;
    _terminals[request.captureJobID] = Completer<ManualCaptureV2Result>();
    return ManualCaptureV2Ticket(
      captureJobID: request.captureJobID,
      status: 'snapshot_reserved',
      snapshotTimestamp: 42,
      jpegPath: request.saveSpec.jpegPath,
      metadataPath: request.saveSpec.metadataPath,
      sfmGrayPath: request.sfmGrayPath,
    );
  }

  @override
  Future<ManualCaptureV2Result> awaitManualCaptureV2(String captureJobID) {
    final terminal = _terminals[captureJobID];
    if (terminal == null) throw StateError('unknown capture job $captureJobID');
    return terminal.future;
  }

  @override
  Future<ARLockResult?> lockOrigin({double distanceMeters = 1.0}) async => null;

  @override
  Future<bool> saveCurrentFrameAsJpeg({
    required String jpegPath,
    required String metadataPath,
    double? targetTimestamp,
    double maxTimestampDelta = 0.18,
    double quality = 0.9,
  }) async => false;

  @override
  Future<ARFrameSaveResult> saveCurrentFrame(ARFrameSaveSpec spec) async =>
      ARFrameSaveResult(spec: spec, status: 'unsupported');

  @override
  Future<HighResolutionStillCapture?> captureHighResolutionStill({
    required String highresPath,
    required String previewPath,
    double? triggerTimestamp,
    double quality = 0.92,
    ARFrameSaveSpec? saveSpec,
  }) async => null;

  @override
  Future<void> stop() async {}
}
