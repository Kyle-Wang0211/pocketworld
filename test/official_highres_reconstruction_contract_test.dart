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
    'official shutter stays locked until its 12MP transaction completes',
    () {
      final session = File(
        'lib/official_capture/capture_session.dart',
      ).readAsStringSync();
      final page = File(
        'lib/ui/official_capture/ar_capture_page.dart',
      ).readAsStringSync();

      expect(session, contains('highResolutionCompletion'));
      expect(page, contains('await capture.highResolutionCompletion'));
      expect(page, isNot(contains('高分辨率相机正在拍摄，本次未拍摄，请重拍')));
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
