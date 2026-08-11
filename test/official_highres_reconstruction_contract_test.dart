import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/official_highres_reconstruction_input.dart';

void main() {
  const transform = <double>[1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
  const intrinsics = <double>[3000, 3000, 2016, 1512];

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
    expect(source, contains('deriveAuxiliary: false'));
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

  test('official shutter transaction retries but cannot hang forever', () {
    final session = File(
      'lib/official_capture/capture_session.dart',
    ).readAsStringSync();

    expect(session, contains('_manualHighResMaxAttempts'));
    expect(session, contains('attempt < _manualHighResMaxAttempts'));
    expect(session, contains('return input;'));
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

  test('finish freezes and drains accepted shutter tickets before stop', () {
    final page = File(
      'lib/ui/official_capture/ar_capture_page.dart',
    ).readAsStringSync();
    final finalizeStart = page.indexOf('Future<void> _finalizeRecording({');
    final finalizeEnd = page.indexOf(
      'Future<void> _persistDraft(',
      finalizeStart,
    );
    final finalizeSource = page.substring(finalizeStart, finalizeEnd);
    final finishStart = page.indexOf('Future<void> _onFinishTap()');
    final finishEnd = page.indexOf(
      'Future<void> _finalizeRecording({',
      finishStart,
    );
    final finishSource = page.substring(finishStart, finishEnd);

    expect(page, isNot(contains('_capturing')));
    expect(page, contains('await _shutterQueue.freezeAndDrain()'));
    expect(
      finishSource.indexOf('await _shutterQueue.freezeAndDrain()'),
      lessThan(
        finishSource.indexOf('final acceptedFrameCount = _projectPhotos.count'),
      ),
    );
    expect(
      finalizeSource.indexOf('await _shutterQueue.freezeAndDrain()'),
      lessThan(finalizeSource.indexOf('await session.stop()')),
    );
    expect(page, contains('busy: finishing'));
    expect(
      page,
      contains('projectPhotos.count + shutterQueue.outstandingCount == 0'),
    );
    expect(page, contains('_shutterQueue.resume()'));
    expect(page, contains('_shutterQueue.cancelPending()'));
    expect(finishSource, contains('_finishDrainFailed = false'));
    expect(finishSource, contains('_finishDrainFailed ||'));
    expect(finishSource, contains('!_cameraResumeFailed'));
    final errorStart = page.indexOf('void _onShutterTicketError(');
    final errorEnd = page.indexOf('void _openAlbum()', errorStart);
    final errorSource = page.substring(errorStart, errorEnd);
    expect(errorSource, contains('if (_finishTapInProgress)'));
    expect(errorSource, contains('_finishDrainFailed = true'));
    expect(errorSource, contains('_shutterQueue.cancelPending()'));
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

    expect(shutterSource, contains('color: Colors.white'));
    expect(shutterSource, isNot(contains('busy')));
    expect(shutterSource, isNot(contains('Colors.white70')));
    expect(
      closeSource,
      isNot(
        contains(
          '_finalizingRecording || _finishTapInProgress || _lockInProgress',
        ),
      ),
    );
    expect(closeSource, contains('_finishCancellationRequested = true'));
    expect(closeSource, contains('_shutterQueue.cancelPending()'));
    expect(closeSource, contains('await session.stop()'));
    expect(closeSource, contains('await _shutterQueue.freezeAndDrain()'));
    expect(closeSource, contains('await session.discardCurrentCapture()'));
    expect(
      closeSource.indexOf('await session.stop()'),
      lessThan(closeSource.indexOf('await _shutterQueue.freezeAndDrain()')),
      reason:
          'discard must stop capture retries before waiting for the active '
          'native transaction to settle',
    );
    expect(
      closeSource.indexOf('await _shutterQueue.freezeAndDrain()'),
      lessThan(closeSource.indexOf('await session.discardCurrentCapture()')),
      reason:
          'the active native high-resolution transaction must release its '
          'file before discard recursively deletes the capture directory',
    );
    expect(closeSource, contains('_closeTapInProgress = false'));
    expect(
      closeSource.lastIndexOf('_closeTapInProgress = false'),
      greaterThan(closeSource.indexOf('await session.discardCurrentCapture()')),
      reason: 'close must stay single-flight until destructive teardown ends',
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

    expect(pauseSource, contains('suspendManualCaptureTransactions()'));
    expect(
      pauseSource.indexOf('suspendManualCaptureTransactions()'),
      lessThan(pauseSource.indexOf("invokeMethod<void>('stopSession')")),
    );
    expect(resumeSource, contains('resumeManualCaptureTransactions()'));
    expect(resumeSource, contains('failSuspendedManualCaptureTransactions(e)'));
    expect(resumeSource, contains('_shutterQueue.cancelPending()'));
    expect(resumeSource, contains('_cameraResumeFailed = true'));
    expect(resumeSource, contains('_cameraResumeFailed = false'));
    expect(resumeSource, contains('_shutterQueue.resume()'));
    expect(
      resumeSource.indexOf("invokeMethod<void>('startSession'"),
      lessThan(resumeSource.indexOf('resumeManualCaptureTransactions()')),
    );
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
      contains('requestFrameTimestamp = session.currentFrame?.timestamp'),
    );
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
}
