import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/official_highres_reconstruction_input.dart';

void main() {
  const transform = <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
  const intrinsics = <double>[3000, 3000, 2016, 1512];

  test('binds transaction identity and three explicitly named poses', () {
    final requestPose = List<double>.of(transform)..[12] = 1;
    final evidencePose = List<double>.of(transform)..[12] = 2;
    final cardPose = List<double>.of(transform)..[12] = 3;

    final result = OfficialHighResReconstructionInput.validate(
      expectedTransactionId: 'tx-7',
      transactionId: 'tx-7',
      jpegPath: '/capture/photos_highres/tx-7.jpg',
      imageWidth: 4032,
      imageHeight: 3024,
      triggerTimestamp: 10,
      captureTimestamp: 10.8,
      requestPose: requestPose,
      evidencePose: evidencePose,
      cardPose: cardPose,
      intrinsics: intrinsics,
    );

    expect(result.isAccepted, isTrue);
    expect(result.input!.transactionId, 'tx-7');
    expect(result.input!.requestPose, requestPose);
    expect(result.input!.evidencePose, evidencePose);
    expect(result.input!.cardPose, cardPose);

    final wrongIdentity = OfficialHighResReconstructionInput.validate(
      expectedTransactionId: 'tx-7',
      transactionId: 'tx-other',
      jpegPath: '/capture/photos_highres/tx-7.jpg',
      imageWidth: 4032,
      imageHeight: 3024,
      triggerTimestamp: 10,
      captureTimestamp: 10.8,
      requestPose: requestPose,
      evidencePose: evidencePose,
      cardPose: cardPose,
      intrinsics: intrinsics,
    );
    expect(
      wrongIdentity.failure,
      OfficialHighResInputFailure.transactionMismatch,
    );
  });

  test(
    'accepted automatic input preserves a defensive copy of actual gray',
    () {
      final gray = Uint8List(128 * 128)..[17] = 93;
      final result = OfficialHighResReconstructionInput.validate(
        jpegPath: '/capture/photos_highres/auto-1.jpg',
        imageWidth: 4032,
        imageHeight: 3024,
        triggerTimestamp: 1,
        captureTimestamp: 1.4,
        cameraTransform: transform,
        intrinsics: intrinsics,
        gray128: gray,
      );

      expect(result.input!.gray128![17], 93);
      gray[17] = 0;
      expect(result.input!.gray128![17], 93);
    },
  );

  test(
    'accepts a transaction-bound 4032x3024 JPEG with same-frame AR data',
    () {
      final result = OfficialHighResReconstructionInput.validate(
        jpegPath: '/capture/photos_highres/tap-1.jpg',
        imageWidth: 4032,
        imageHeight: 3024,
        triggerTimestamp: 10,
        // ARKit's 12 MP sensor path commonly returns 0.25-1.23 seconds after
        // the request on the target iPhone. The MethodChannel request and its
        // single native completion bind the frame to this tap; hardware
        // latency is audit data, not a rejection reason.
        captureTimestamp: 11.23,
        cameraTransform: transform,
        intrinsics: intrinsics,
      );

      expect(result.isAccepted, isTrue);
      expect(result.input!.jpegPath, endsWith('.jpg'));
      expect(result.input!.imageWidth, 4032);
      expect(result.input!.imageHeight, 3024);
      expect(result.input!.timestampDeltaSeconds, closeTo(1.23, 1e-9));
    },
  );

  test('rejects preview resolution instead of silently feeding it', () {
    final result = OfficialHighResReconstructionInput.validate(
      jpegPath: '/capture/previews/tap-1.jpg',
      imageWidth: 1920,
      imageHeight: 1440,
      triggerTimestamp: 10,
      captureTimestamp: 10.02,
      cameraTransform: transform,
      intrinsics: intrinsics,
    );

    expect(result.isAccepted, isFalse);
    expect(result.failure, OfficialHighResInputFailure.unexpectedDimensions);
  });

  test('accepts the single native completion even after sensor latency', () {
    final result = OfficialHighResReconstructionInput.validate(
      jpegPath: '/capture/photos_highres/tap-2.jpg',
      imageWidth: 4032,
      imageHeight: 3024,
      triggerTimestamp: 20,
      captureTimestamp: 21.5,
      cameraTransform: transform,
      intrinsics: intrinsics,
    );

    expect(result.isAccepted, isTrue);
    expect(result.input!.timestampDeltaSeconds, closeTo(1.5, 1e-9));
  });

  test(
    'accepts ARKit clock phase skew on the transaction-bound completion',
    () {
      final result = OfficialHighResReconstructionInput.validate(
        jpegPath: '/capture/photos_highres/tap-negative.jpg',
        imageWidth: 4032,
        imageHeight: 3024,
        triggerTimestamp: 20,
        captureTimestamp: 19.999,
        cameraTransform: transform,
        intrinsics: intrinsics,
      );

      expect(result.isAccepted, isTrue);
      expect(result.input!.timestampDeltaSeconds, closeTo(0.001, 1e-9));
    },
  );

  test('rejects non-finite request or capture timestamps', () {
    final invalidRequest = OfficialHighResReconstructionInput.validate(
      jpegPath: '/capture/photos_highres/tap-invalid-request.jpg',
      imageWidth: 4032,
      imageHeight: 3024,
      triggerTimestamp: double.nan,
      captureTimestamp: 20,
      cameraTransform: transform,
      intrinsics: intrinsics,
    );
    final invalidCapture = OfficialHighResReconstructionInput.validate(
      jpegPath: '/capture/photos_highres/tap-invalid-capture.jpg',
      imageWidth: 4032,
      imageHeight: 3024,
      triggerTimestamp: 20,
      captureTimestamp: double.infinity,
      cameraTransform: transform,
      intrinsics: intrinsics,
    );

    expect(invalidRequest.failure, OfficialHighResInputFailure.outOfSync);
    expect(invalidCapture.failure, OfficialHighResInputFailure.outOfSync);
  });

  test('rejects missing same-frame pose or intrinsics', () {
    final missingPose = OfficialHighResReconstructionInput.validate(
      jpegPath: '/capture/photos_highres/tap-3.jpg',
      imageWidth: 4032,
      imageHeight: 3024,
      triggerTimestamp: 30,
      captureTimestamp: 30.01,
      cameraTransform: const <double>[],
      intrinsics: intrinsics,
    );
    final missingIntrinsics = OfficialHighResReconstructionInput.validate(
      jpegPath: '/capture/photos_highres/tap-4.jpg',
      imageWidth: 4032,
      imageHeight: 3024,
      triggerTimestamp: 40,
      captureTimestamp: 40.01,
      cameraTransform: transform,
      intrinsics: const <double>[],
    );

    expect(missingPose.failure, OfficialHighResInputFailure.missingPose);
    expect(
      missingIntrinsics.failure,
      OfficialHighResInputFailure.missingIntrinsics,
    );
  });

  test('official pipeline consumes a JPEG path at the native SfM boundary', () {
    final ffi = File('lib/official_aether_sfm_ffi.dart').readAsStringSync();
    final live = File(
      'lib/official_capture/sfm_live_recon.dart',
    ).readAsStringSync();
    final jpegInput = File(
      'vendor/official_sfm/src/pwofficial_jpeg_decode.mm',
    ).readAsStringSync();

    expect(ffi, contains('pwofficial_add_jpeg_frame'));
    expect(ffi, contains('addJpegFrame'));
    expect(ffi, contains('required double captureTimestamp'));
    expect(live, contains("'cmd': 'jpeg_frame'"));
    expect(live, contains('session!.addJpegFrame('));
    expect(jpegInput, contains('pwofficial_add_jpeg_frame'));
    expect(jpegInput, contains('width != 4032 || height != 3024'));
    expect(jpegInput, isNot(contains('CGContextTranslateCTM')));
    expect(jpegInput, isNot(contains('CGContextScaleCTM')));
    expect(jpegInput, isNot(contains('CGAffineTransformScale')));
    expect(jpegInput, isNot(contains('histogram')));
  });

  test('official manual capture has no 2 second queue or preview fallback', () {
    final source = File(
      'lib/official_capture/capture_session.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('maxTimestampDelta: 2.0')));
    expect(source, contains('OfficialHighResReconstructionInput.validate('));
    expect(source, contains('OfficialHighResInputFailure.captureFailed'));
    expect(source, isNot(contains('sfmFeed.withJpegPath(jpegPath)')));
    expect(source, isNot(contains('stillFuture.timeout(')));
    expect(source, contains('includeSfmFeed: false'));
    expect(source, contains('deriveAuxiliary: automaticSelection'));
    expect(source, contains('_automaticActualPhotoGate.evaluate('));
    expect(source, contains('if (automaticSelection)'));
    expect(source, contains('bool automaticSelection = false'));
  });

  test(
    'official shutter admits immediately while one 12MP transaction drains',
    () {
      final session = File(
        'lib/official_capture/capture_session.dart',
      ).readAsStringSync();
      final page = File(
        'lib/ui/official_capture/ar_capture_page.dart',
      ).readAsStringSync();

      expect(session, contains('highResolutionCompletion'));
      expect(page, contains('ManualCaptureQueue'));
      expect(page, contains('_shutterQueue.enqueue('));
      expect(page, contains('Future<void> _executeShutterTicket('));
      expect(page, contains('await capture.highResolutionCompletion'));
      expect(page, isNot(contains('if (_capturing) return;')));
      expect(page, isNot(contains('setState(() => _capturing = true)')));
      expect(page, isNot(contains('setState(() => _capturing = false)')));
      expect(page, isNot(contains('高分辨率相机正在拍摄，本次未拍摄，请重拍')));
    },
  );

  test('every admitted shutter owns exactly one native high-res request', () {
    final session = File(
      'lib/official_capture/capture_session.dart',
    ).readAsStringSync();

    expect(session, contains('const maxAttempts = 1;'));
    expect(session, contains('attempt < maxAttempts'));
    expect(session, isNot(contains('_manualHighResMaxAttempts')));
    expect(session, contains('transactionId: transaction.id'));
    expect(session, contains('cardTexturePath: previewJpegPath'));
    expect(session, contains('suspendManualCaptureTransactions'));
    expect(session, contains('resumeManualCaptureTransactions'));
    expect(session, contains('await _waitForManualCaptureResume()'));
    expect(
      session,
      contains(
        'Future<OfficialHighResReconstructionInput> '
        '_captureOfficialHighResInput',
      ),
    );
  });

  test('automatic 12MP receipt is two-phase and rejected files are silent', () {
    final session = File(
      'lib/official_capture/capture_session.dart',
    ).readAsStringSync();
    final page = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();

    final evaluate = session.indexOf('_automaticActualPhotoGate.evaluate(');
    final publish = session.indexOf(
      'await _commitCanonicalAcceptedPhoto(',
      evaluate,
    );
    final receipt = page.indexOf('session.commitAutomaticActualPhoto(input)');
    final controllerStart = page.indexOf(
      'void _applyCanonicalPhotoController(AcceptedPhotoRecord record)',
    );
    final controllerEnd = page.indexOf(
      'void _sampleStarvedBanner()',
      controllerStart,
    );
    final controller = page.substring(controllerStart, controllerEnd);
    expect(evaluate, greaterThanOrEqualTo(0));
    expect(publish, greaterThan(evaluate));
    expect(receipt, greaterThanOrEqualTo(0));
    expect(controller, contains('_autoCapture.resolveAutomaticStill('));
    expect(controller, contains('record.transactionId'));
    expect(
      controller.indexOf('_automaticControllerReceiptTransactions.add('),
      greaterThan(controller.indexOf('_autoCapture.resolveAutomaticStill(')),
      reason: 'the automatic baseline receipt is recorded only after resolve',
    );
    expect(
      controller.lastIndexOf('_controllerProjectedTransactions.add('),
      greaterThan(controller.indexOf('_sampleStarvedBanner();')),
      reason: 'a retry must not skip controller side effects after a throw',
    );
    expect(session, contains('canonicalPhotoCommitStream'));
    expect(page, contains('session.projectCanonicalPhoto('));
    expect(session, contains('_deleteAutomaticCandidateArtifacts('));
    expect(page, contains('await _deleteRejectedAutomaticCandidate(capture)'));
    expect(page, contains('rejected private candidate'));
    expect(page, isNot(contains('有一张高分辨率照片未完成（任务')));
  });

  test(
    'automatic project ledger commits before every downstream side effect',
    () {
      final session = File(
        'lib/official_capture/capture_session.dart',
      ).readAsStringSync();
      final page = File(
        'lib/ui/official_capture/ar_capture_page.dart',
      ).readAsStringSync();

      final executeStart = page.indexOf('Future<void> _executeShutterTicket(');
      final executeEnd = page.indexOf(
        'void _onShutterTicketError(',
        executeStart,
      );
      final execute = page.substring(executeStart, executeEnd);
      final album = execute.indexOf('await _projectCanonicalPhoto(');
      final receipt = execute.indexOf(
        'session.commitAutomaticActualPhoto(input)',
      );
      expect(album, greaterThanOrEqualTo(0));
      expect(receipt, greaterThan(album));

      final commitStart = session.indexOf(
        'Future<bool> _commitCanonicalAcceptedPhoto(',
      );
      final commitEnd = session.indexOf(
        'Future<void> _fanOutCanonicalRecord(',
        commitStart,
      );
      final commit = session.substring(commitStart, commitEnd);
      expect(commit, contains('await store.publish('));
      expect(commit, contains('_photoTransactions.acceptData(transaction)'));
      expect(commit, contains('_canonicalPhotoCommitCtrl.add(record)'));
      expect(commit, contains('await _fanOutCanonicalRecord(record)'));
    },
  );

  test('committed finish hides capture and stops inputs before draining', () {
    final page = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final finalizeStart = page.indexOf('Future<void> _commitCaptureExit({');
    final finalizeEnd = page.indexOf(
      'Future<void> _continueCommittedReconstruction(',
      finalizeStart,
    );
    final finalizeSource = page.substring(finalizeStart, finalizeEnd);
    final finishStart = page.indexOf('Future<void> _onFinishTap()');
    final finishEnd = page.indexOf(
      'Future<void> _finalizeRecording({',
      finishStart,
    );
    final finishSource = page.substring(finishStart, finishEnd);

    expect(page, contains('_finishCoordinator.shouldShowOpaqueOverlay'));
    expect(page, contains('_finishCoordinator.captureRootTombstoned'));
    expect(
      page,
      contains('phase: _sfmPhase ?? SfmPreviewPhase.generating'),
      reason:
          'the existing black reconstruction page must cover AR immediately; '
          'its visibility cannot wait for the reconstruction phase',
    );

    final firstFinalizeAwait = finalizeSource.indexOf('await ');
    final commit = finalizeSource.indexOf('_finishCoordinator.beginFinish');
    final sealSession = finalizeSource.indexOf(
      'session.sealCaptureAdmission()',
    );
    final hideCapture = finalizeSource.indexOf('_recording = false;');
    expect(commit, greaterThanOrEqualTo(0));
    expect(sealSession, greaterThanOrEqualTo(0));
    expect(hideCapture, greaterThanOrEqualTo(0));
    expect(
      commit,
      lessThan(firstFinalizeAwait),
      reason: 'the black page owner must commit before any asynchronous wait',
    );
    expect(
      sealSession,
      lessThan(firstFinalizeAwait),
      reason: 'pose and shutter admission seal synchronously',
    );
    expect(
      hideCapture,
      lessThan(firstFinalizeAwait),
      reason: 'the capture UI must close in the same synchronous state commit',
    );
    expect(
      finalizeSource.indexOf('await _shutterQueue.freezeAndDrain()'),
      lessThan(finalizeSource.indexOf('await session.stopCameraTransport()')),
      reason:
          'the active 12 MP evidence must become terminal before AR/SceneKit '
          'is stopped; Finish suppresses presentation instead of waiting for it',
    );
    expect(
      finalizeSource,
      contains('_suppressActivePhotoPresentationForFinish'),
    );
    expect(
      finalizeSource.indexOf('await session.stopCameraTransport()'),
      lessThan(finalizeSource.indexOf('session.stop()')),
      reason:
          'camera teardown must not wait on manifest or reconstruction work',
    );
    expect(finalizeSource, contains('_stopVioShadowInBackground()'));
    expect(finalizeSource, isNot(contains('await _stopVioShadowForCapture()')));
    expect(
      page,
      contains('projectPhotos.count + shutterQueue.outstandingCount == 0'),
    );
    expect(page, contains('_shutterQueue.cancelPending()'));
    expect(page, isNot(contains('_finishDrainFailed')));
    expect(finishSource, isNot(contains('_shutterQueue.freezeAndDrain()')));
    final errorStart = page.indexOf('void _onShutterTicketError(');
    final errorEnd = page.indexOf('void _openAlbum()', errorStart);
    final errorSource = page.substring(errorStart, errorEnd);
    expect(errorSource, isNot(contains('_captureQueueFailureText =')));
    expect(
      errorSource,
      isNot(contains('automaticShutterFailureIsUserVisible(error.failure)')),
    );
    expect(errorSource, contains('rejected private candidate'));
  });

  test('Finish owns the Dart presentation terminal before native cleanup', () {
    final page = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final start = page.indexOf(
      'Future<void> _suppressActivePhotoPresentationForFinish()',
    );
    final end = page.indexOf('Future<void> _discardPhotoFeedback(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final helper = page.substring(start, end);

    final dartTerminal = helper.indexOf(
      'AcceptedPhotoPresentationOutcome.suppressed',
    );
    final nativeAwait = helper.indexOf('await _suppressPhotoPresentation(');
    expect(dartTerminal, greaterThanOrEqualTo(0));
    expect(nativeAwait, greaterThan(dartTerminal));
  });

  test('pending tickets never dim the white shutter or block safe exit', () {
    final page = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final shutterStart = page.indexOf('class _ShutterButton');
    final shutterEnd = page.indexOf('class _FinishArrowButton', shutterStart);
    final shutterSource = page.substring(shutterStart, shutterEnd);
    final closeStart = page.indexOf('Future<void> _onCloseTap()');
    final closeEnd = page.indexOf('Future<void> _onCenterTap()', closeStart);
    final closeSource = page.substring(closeStart, closeEnd);
    final commitStart = page.indexOf('Future<void> _commitCaptureExit({');
    final commitEnd = page.indexOf(
      'Future<void> _continueCommittedReconstruction(',
      commitStart,
    );
    final commitSource = page.substring(commitStart, commitEnd);

    expect(shutterSource, contains('color: Colors.white'));
    expect(shutterSource, isNot(contains('busy')));
    expect(shutterSource, isNot(contains('Colors.white70')));
    expect(closeSource, contains('_commitCaptureExit('));
    expect(closeSource, isNot(contains('_shutterQueue.cancelPending()')));
    expect(closeSource, isNot(contains('session.stop()')));
    expect(closeSource, isNot(contains('session.discardCurrentCapture()')));
    expect(
      commitSource.indexOf('await _shutterQueue.freezeAndDrain()'),
      lessThan(commitSource.indexOf('await session.stopCameraTransport()')),
      reason:
          'every exit settles the admitted ticket before stopping the camera',
    );
    expect(
      commitSource.indexOf('await _shutterQueue.freezeAndDrain()'),
      lessThan(commitSource.indexOf('await session.discardCurrentCapture()')),
      reason:
          'the active native high-resolution transaction must release its '
          'file before discard recursively deletes the capture directory',
    );
    expect(
      commitSource.indexOf('await _shutterQueue.freezeAndDrain()'),
      lessThan(commitSource.indexOf('_persistDraft(showSnackBar: false)')),
      reason: 'save-and-exit must settle the active ticket before persistence',
    );
  });

  test('zero accepted photos bypass the exit dialog and reuse safe discard', () {
    final page = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final closeStart = page.indexOf('Future<void> _onCloseTap()');
    final closeEnd = page.indexOf('Future<void> _onCenterTap()', closeStart);
    final closeSource = page.substring(closeStart, closeEnd);

    final acceptedPredicate = closeSource.indexOf('final hasAcceptedPhotos =');
    final dialog = closeSource.indexOf('showCaptureExitDialog(context)');

    expect(closeSource, isNot(contains('_stopAutoCapture();')));
    expect(dialog, greaterThan(acceptedPredicate));
    expect(
      closeSource,
      contains('_projectPhotos.count + _shutterQueue.outstandingCount > 0'),
      reason:
          'queued or in-flight shutters must prevent a false zero-photo exit',
    );
    expect(
      closeSource,
      contains(': CaptureExitChoice.discardExit;'),
      reason:
          'true zero must skip the dialog and enter the existing discard path',
    );
    expect(
      closeSource.indexOf('_commitCaptureExit('),
      greaterThan(dialog),
      reason:
          'zero-photo bypass must retain the existing safe teardown sequence',
    );
  });

  test('background suspends 12MP work and resume explicitly releases it', () {
    final page = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final pauseStart = page.indexOf('Future<void> _pauseArForBackground()');
    final pauseEnd = page.indexOf(
      'Future<void> _restartArSessionAfterResume()',
      pauseStart,
    );
    final resumeEnd = page.indexOf(
      'Future<void> _stopRecordingIfRunning()',
      pauseEnd,
    );
    final pauseSource = page.substring(pauseStart, pauseEnd);
    final resumeSource = page.substring(pauseEnd, resumeEnd);

    expect(pauseSource, contains('await session.suspendCameraTransport()'));
    expect(pauseSource, isNot(contains("invokeMethod<void>('stopSession')")));
    expect(resumeSource, contains('await _session?.resumeCameraTransport()'));
    expect(resumeSource, isNot(contains("invokeMethod<void>('startSession'")));
    expect(resumeSource, contains('failSuspendedManualCaptureTransactions(e)'));
    expect(resumeSource, contains('_shutterQueue.cancelPending()'));
    expect(resumeSource, contains('_cameraResumeFailed = true'));
    expect(resumeSource, contains('_cameraResumeFailed = false'));
    expect(resumeSource, contains('_shutterQueue.resume()'));
  });

  test('page disposal releases the active 12MP ticket before its session', () {
    final page = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final helperStart = page.indexOf(
      'Future<void> _disposeCaptureResourcesAfterQueueDrain(',
    );
    final helperEnd = page.indexOf('@override\n  void dispose()', helperStart);
    final helper = page.substring(helperStart, helperEnd);
    final disposeStart = helperEnd;
    final disposeEnd = page.indexOf('// ─── Layout', disposeStart);
    final disposeSource = page.substring(disposeStart, disposeEnd);

    expect(helper, contains('await session?.stop()'));
    expect(helper, contains('await shutterQueue.freezeAndDrain()'));
    expect(
      helper.indexOf('await shutterQueue.freezeAndDrain()'),
      lessThan(helper.indexOf('shutterQueue.dispose()')),
    );
    expect(
      helper.indexOf('shutterQueue.dispose()'),
      lessThan(helper.indexOf('await session?.dispose()')),
    );
    expect(disposeSource, contains('shutterQueue.cancelPending()'));
    expect(
      disposeSource,
      contains(
        '_disposeCaptureResourcesAfterQueueDrain(shutterQueue, session)',
      ),
    );
    expect(disposeSource, isNot(contains('_shutterQueue.dispose()')));
    expect(disposeSource, isNot(contains('_session?.dispose()')));
  });

  test('P0 confirmation gates are non-mutating until commit', () {
    final page = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final finishStart = page.indexOf('Future<void> _onFinishTap()');
    final finishEnd = page.indexOf(
      'Future<void> _commitCaptureExit({',
      finishStart,
    );
    final closeStart = page.indexOf('Future<void> _onCloseTap()');
    final closeEnd = page.indexOf('Future<void> _onCenterTap()', closeStart);
    expect(finishStart, greaterThanOrEqualTo(0));
    expect(finishEnd, greaterThan(finishStart));
    final finishSource = page.substring(finishStart, finishEnd);
    final closeSource = page.substring(closeStart, closeEnd);
    final closeDialog = closeSource.indexOf('showCaptureExitDialog(context)');
    final closeCommit = closeSource.indexOf('_commitCaptureExit(');

    expect(finishSource, isNot(contains('_stopAutoCapture()')));
    expect(finishSource, isNot(contains('_shutterQueue.freezeAndDrain()')));
    expect(finishSource, isNot(contains('_shutterQueue.cancelPending()')));
    expect(finishSource, isNot(contains('_setMatcherCaptureActive(false)')));
    expect(closeDialog, greaterThanOrEqualTo(0));
    expect(closeCommit, greaterThan(closeDialog));
    expect(
      closeSource.substring(0, closeCommit),
      isNot(contains('_stopAutoCapture()')),
    );
    expect(
      closeSource.substring(0, closeCommit),
      isNot(contains('_shutterQueue.freezeAndDrain()')),
    );
  });

  test('P0 committed exits share one synchronous tombstone boundary', () {
    final page = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final commitStart = page.indexOf('Future<void> _commitCaptureExit({');
    final commitEnd = page.indexOf(
      'Future<void> _continueCommittedReconstruction(',
      commitStart,
    );
    expect(commitStart, greaterThanOrEqualTo(0));
    expect(commitEnd, greaterThan(commitStart));
    final commitSource = page.substring(commitStart, commitEnd);
    final firstAwait = commitSource.indexOf('await ');

    for (final synchronousEffect in <String>[
      '_finishCoordinator.beginFinish',
      'session.sealCaptureAdmission()',
      '_stopAutoCapture()',
      '_shutterQueue.cancelPending()',
      '_setMatcherCaptureActive(false)',
      '_recording = false',
    ]) {
      final position = commitSource.indexOf(synchronousEffect);
      expect(position, greaterThanOrEqualTo(0), reason: synchronousEffect);
      expect(position, lessThan(firstAwait), reason: synchronousEffect);
    }
    expect(commitSource, contains('await _shutterQueue.freezeAndDrain()'));
    expect(commitSource, contains('await session.stopCameraTransport()'));
    expect(commitSource, contains('_stopVioShadowInBackground()'));
    expect(commitSource, isNot(contains('await _stopVioShadowForCapture()')));
  });

  test('P0 close save and discard have no lifecycle bypass', () {
    final page = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final closeStart = page.indexOf('Future<void> _onCloseTap()');
    final closeEnd = page.indexOf('Future<void> _onCenterTap()', closeStart);
    final closeSource = page.substring(closeStart, closeEnd);
    final commitStart = page.indexOf('Future<void> _commitCaptureExit({');
    final commitEnd = page.indexOf(
      'Future<void> _continueCommittedReconstruction(',
      commitStart,
    );
    final commitSource = page.substring(commitStart, commitEnd);

    expect(RegExp(r'_commitCaptureExit\(').allMatches(closeSource).length, 1);
    expect(closeSource, contains('CaptureExitChoice.saveExit'));
    expect(closeSource, contains('CaptureExitChoice.discardExit'));
    expect(closeSource, isNot(contains('stopCameraTransport()')));
    expect(closeSource, isNot(contains('_persistDraft(')));
    expect(closeSource, isNot(contains('discardCurrentCapture()')));
    expect(closeSource, isNot(contains('Navigator.of(context).pop')));
    expect(commitSource, contains('_persistDraft(showSnackBar: false)'));
    expect(commitSource, contains('session.discardCurrentCapture'));
  });

  test('P0 coordinator owns UI authority and terminal writes', () {
    final page = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();

    expect(page, isNot(contains('bool _finalizingRecording')));
    expect(page, isNot(contains('bool _finishTapInProgress')));
    expect(page, isNot(contains('bool _finishCancellationRequested')));
    expect(page, isNot(contains('bool _closeTapInProgress')));
    expect(page, isNot(contains('bool _discardingCapture')));
    expect(page, contains('_finishCoordinator.captureRootTombstoned'));
    expect(
      RegExp(r'_finishCoordinator\.completeSuccess\(').allMatches(page).length,
      1,
    );
    expect(
      RegExp(r'_finishCoordinator\.completeError\(').allMatches(page).length,
      1,
    );
    expect(page, contains('bool _resolveFinishTerminal('));
  });

  test('P0 terminal colorize is bounded and cannot wedge processing', () {
    final page = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final start = page.indexOf('Future<void> _runColorizeSnapshot(');
    final end = page.indexOf('Future<bool> _colorizeSnapshot(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = page.substring(start, end);

    expect(body, contains('_finishCoordinator.runProcessingStep('));
    expect(body, contains("stage: 'colorizeAndPersist'"));
    expect(body, contains('_showFinishCoordinatorFailure(attempt)'));
  });

  test('P0 stale reconstruction callbacks cannot affect a committed close', () {
    final page = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final start = page.indexOf('void _onSfmEvent(');
    final end = page.indexOf('Future<void> _runColorizeSnapshot(', start);
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = page.substring(start, end);

    expect(page, contains('(event) => _onSfmEvent(recon, event)'));
    expect(
      body,
      contains('if (!identical(source, _sfmRecon) || !mounted) return;'),
    );
    expect(body, contains('_onSfmTerminal('));
    expect(body, contains('SfmTerminalFailure('));
  });

  test('P0 raw draft settles before reconstruction terminal work starts', () {
    final page = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final start = page.indexOf(
      'Future<void> _continueCommittedReconstruction(',
    );
    final end = page.indexOf(
      'void _releaseReconstructionAfterCommittedClose(',
      start,
    );
    expect(start, greaterThanOrEqualTo(0));
    expect(end, greaterThan(start));
    final body = page.substring(start, end);

    expect(
      body.indexOf("stage: 'persistDraft'"),
      lessThan(body.indexOf('recon.finalize()')),
    );
    expect(
      body.indexOf('_flushDeferredFinishTerminal()'),
      lessThan(body.indexOf('recon.finalize()')),
    );
  });

  test(
    'canonical membership must tombstone before user deletion side effects',
    () {
      final page = File(
        'lib/ui/official_capture/ar_capture_page.dart',
      ).readAsStringSync();
      final start = page.indexOf('Future<void> _deleteProjectPhoto(');
      final end = page.indexOf('Future<bool> _writeCardThumbnail(', start);
      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));
      final body = page.substring(start, end);

      final tombstone = body.indexOf(
        'await session.tombstoneCanonicalPhoto(path)',
      );
      expect(tombstone, greaterThanOrEqualTo(0));
      expect(
        tombstone,
        lessThan(body.indexOf('await recon.removePhoto(path)')),
      );
      expect(tombstone, lessThan(body.indexOf('await file.delete()')));
      expect(body, contains('reconRemovalFailed = !removed;'));
      expect(
        body.indexOf('_photoCardStateSent.remove(path)'),
        lessThan(body.indexOf('if (reconRemovalFailed && mounted)')),
        reason:
            'canonical deletion cleanup must survive a worker withdrawal miss',
      );
    },
  );

  test('official native route locks preview size and transaction sync', () {
    final source = File(
      'ios/Runner/OfficialAetherARKitPlugin.swift',
    ).readAsStringSync();

    expect(source, contains('Int(\$0.imageResolution.width) == 1920'));
    expect(source, contains('Int(\$0.imageResolution.height) == 1440'));
    expect(
      source,
      contains('\$0.isRecommendedForHighResolutionFrameCapturing'),
    );
    expect(
      source,
      contains('guard let requestFrame = session.currentFrame else'),
    );
    expect(
      source,
      contains('let requestFrameTimestamp = requestFrame.timestamp'),
    );
    // The staged card still binds to the request frame — both its geometry and,
    // now, its texture. The stage call no longer takes an ARCamera, so the
    // binding is pinned on the values passed rather than on the ARKit type.
    expect(source, contains('worldFromCamera: requestFrame.camera.transform'));
    expect(source, contains('sourcePixelBuffer: requestFrame.capturedImage'));
    expect(
      source,
      isNot(contains('requestToCaptureDelta <= maxTimestampDelta')),
    );
    expect(source, contains('imageWidth == 4032, imageHeight == 3024'));
    expect(source, contains('removePhotoCard'));
    expect(source, contains('log("highres_capture"'));
    expect(source, contains('error.localizedDescription'));

    final format = File(
      'lib/official_capture/capture_format.dart',
    ).readAsStringSync();
    expect(format, contains("const String pwVideoFormat = 'hires43';"));
    expect(format, isNot(contains('String.fromEnvironment')));
  });

  test('a malformed 12MP camera is dropped, never re-acquired', () {
    final native = File(
      'ios/Runner/OfficialAetherARKitPlugin.swift',
    ).readAsStringSync();
    final visibility = File(
      'lib/official_capture/auto_capture_failure_visibility.dart',
    ).readAsStringSync();

    // A retry was written here on 2026-08-31 and removed once the question was
    // researched. OpenVINS, ORB-SLAM3, VINS-Mono/Fusion, COLMAP, openMVG and
    // AliceVision all drop a bad measurement and continue; not one re-acquires
    // it. ROS REP-117 assigns NaN the MEANING "erroneous detection". Apple's own
    // Object Capture sample answers .invalidSample with a bare `continue`.
    expect(native, isNot(contains('metadataRetriesLeft')));
    expect(native, isNot(contains('requestHighResolutionFrame')));
    expect(
      native,
      contains('DO NOT add a retry here'),
      reason: 'the verdict must stay where the next person will look for it',
    );

    // The drop is recorded, and recorded ONLY. REP-117's consumer is downstream
    // code that would otherwise mistake absence for non-attempt; this log line
    // is that consumer. The person holding the phone is not — they are not
    // counting shutters and have no action to take, since auto-capture already
    // recovers on its own.
    expect(
      native,
      contains('photo_feedback_retracted'),
      reason: 'a spent shutter that yielded nothing must leave a record',
    );
    expect(
      native,
      isNot(contains('style: .light')),
      reason: 'no second haptic vocabulary for one shutter in six hundred',
    );
    expect(
      'impactOccurred'.allMatches(native).length,
      1,
      reason: 'exactly one haptic exists, and it is the shutter',
    );
    expect(native, contains('UIImpactFeedbackGenerator(style: .heavy)'));

    // Allowlist, never a denylist. photo_feedback_cleared fires once per
    // in-flight card when the session is torn down or resumed; if it ever
    // retracted, pressing stop would deliver a burst of haptics.
    final setStart = native.indexOf(
      'photoFeedbackRetractionCodes: Set<String> = [',
    );
    expect(setStart, greaterThanOrEqualTo(0));
    final setEnd = native.indexOf(']', setStart);
    final codes = native.substring(setStart, setEnd);
    expect(codes, contains('"photo_feedback_capture_failed"'));
    expect(codes, isNot(contains('photo_feedback_cleared')));
    expect(codes, isNot(contains('photo_feedback_not_rendered')));

    // Only a card that actually reached its first frame spent anything.
    final guard = native.indexOf('if transaction.rendered,');
    expect(guard, greaterThanOrEqualTo(0));
    expect(guard, lessThan(native.indexOf('photo_feedback_retracted')));

    // And none of this reopens the older rule: an automatic candidate failure
    // is still never a user task failure.
    expect(
      visibility,
      contains('bool automaticShutterFailureIsUserVisible(\n'
          '  OfficialHighResInputFailure failure,\n'
          ') => false;'),
    );
  });

  test('every way a photo card can stay black leaves a retrievable record', () {
    // Comment lines are stripped before matching. A predicate that can be
    // satisfied by the prose next to the code proves nothing: the first draft
    // of this test passed with the anchor_rendered CALL deleted, because the
    // comment above it still contained the string.
    final native = File(
      'ios/Runner/OfficialAetherARKitPlugin.swift',
    ).readAsStringSync()
        .split('\n')
        .where((line) => !line.trimLeft().startsWith('//'))
        .join('\n');

    // NSLog reaches the system log, which needs root and a connected Mac to
    // pull, so in the field it is write-only: `PHOTOCARD` appears zero times in
    // official_pw_device_log.txt even for the 19 cards that rendered correctly
    // on 2026-08-31. Native telemetry is the only Swift channel a devicectl
    // pull can recover, so every exit that abandons a card must use it.
    for (final reason in <String>[
      'node_replaced',
      'spec_missing',
      'disk_decode_failed',
      'spec_snapshot_missing_at_didadd',
    ]) {
      expect(
        native,
        contains('"reason": "$reason"'),
        reason: '$reason must be attributable after the fact',
      );
    }

    // Reaching the renderer at all is itself the discriminator: a staged card
    // with no anchor_rendered failed BEFORE the texture path, not inside it.
    expect(native, contains('photo_feedback_anchor_rendered'));
    expect(native, contains('photo_feedback_texture_ready'));

    // Observation must not have become behaviour. Each abandoning exit still
    // clears its retry entry and returns, exactly as the single combined guard
    // it replaced did.
    final abandon = 'photo_feedback_texture_abandoned'.allMatches(native).length;
    expect(
      abandon,
      4,
      reason: 'the four reasons share one event name: three call sites in the '
          'texture loader (node_replaced, spec_missing, disk_decode_failed) '
          'and one in didAdd (spec_snapshot_missing_at_didadd)',
    );
  });

  test('a capability can never be switched off in silence', () {
    // Four times on 2026-08-31 a bug came down to the same shape: a failure
    // path that returns or swallows while only the success path is recorded.
    // The worst was the thermal throttle — built 2026-07-11, wired, and dead
    // for a whole session behind `catch (_) {}`, while the device sat at
    // thermal serious and world tracking was lost six times. Fixing each
    // instance as it surfaced was not working; this pins the class.
    String codeOf(String path) => File(path)
        .readAsStringSync()
        .split('\n')
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');

    final worker = codeOf('lib/official_capture/sfm_live_recon.dart');

    // The unified channel exists and is latched per capability.
    expect(worker, contains('void reportDegraded(String capability'));
    expect(worker, contains('if (!degradedCapabilities.add(capability)) return;'));
    // It reaches BOTH retrievable channels: the device log and telemetry.
    expect(worker, contains("wlog('DEGRADED"));
    expect(worker, contains("telem('sfm_capability_degraded'"));

    // Every capability whose silent loss changes runtime behaviour is wired.
    for (final capability in <String>[
      'thermal_throttle_set_state',
      // Both ways the throttle can die must be distinguishable: the call
      // throwing, and the branch never being entered because there was no
      // usable thermal sample. Reporting only the first leaves the second
      // looking identical to "the throttle ran and found nothing to do".
      'thermal_throttle_no_sample',
      'thermal_throttle_stats',
      'prefetch',
    ]) {
      // Matched on the quoted capability alone, not on call syntax: the
      // first draft of this test pinned `reportDegraded('name'` and went red
      // the moment a call wrapped across lines. Comments are already stripped
      // above, so a bare quoted name cannot be satisfied by prose.
      expect(
        worker,
        contains("'$capability'"),
        reason: '$capability must not be able to fail silently',
      );
    }

    // A budget, not a ban. The survivors are teardown and diagnostics, whose
    // failure disables nothing that is still running. Raising this number
    // means a new silent swallow was added — justify it or route it through
    // reportDegraded.
    final silent = worker.split('\n').where((l) => l.contains('catch (_) {}')).length;
    expect(
      silent,
      lessThanOrEqualTo(4),
      reason: 'silent catches in the SfM worker must not grow past the '
          'four teardown/diagnostic survivors',
    );
  });
}
