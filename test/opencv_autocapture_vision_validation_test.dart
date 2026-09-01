import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/opencv_autocapture_vision.dart';

void main() {
  const identity = OpenCvAutoCaptureIdentity(
    captureProductId: 'iphone14pro-wide-v1',
    calibrationId: 'calibration-sha256-a',
  );

  OpenCvAutoCaptureFrame validFrame() => const OpenCvAutoCaptureFrame(
    identity: identity,
    timestampNs: 123,
    width: 4,
    height: 3,
    rowStrideBytes: 4,
    intrinsics3x3: <double>[100, 0, 2, 0, 100, 1.5, 0, 0, 1],
    distortion: <double>[0.1, -0.02, 0, 0],
    rectificationH3x3: <double>[1, 0, 0, 0, 1, 0, 0, 0, 1],
    cropX: 0,
    cropY: 0,
    cropWidth: 4,
    cropHeight: 3,
  );

  test('frame validation accepts only exact identity and bounded metadata', () {
    expect(
      validFrame().validationFailure(expectedIdentity: identity),
      isNull,
    );
    expect(
      validFrame().validationFailure(
        expectedIdentity: const OpenCvAutoCaptureIdentity(
          captureProductId: 'iphone14pro-ultrawide-v1',
          calibrationId: 'calibration-sha256-a',
        ),
      ),
      OpenCvAutoCaptureValidationFailure.captureProductMismatch,
    );
    expect(
      validFrame().validationFailure(
        expectedIdentity: const OpenCvAutoCaptureIdentity(
          captureProductId: 'iphone14pro-wide-v1',
          calibrationId: 'unknown',
        ),
      ),
      OpenCvAutoCaptureValidationFailure.calibrationMismatch,
    );
  });

  test('unknown identities and invalid crop fail closed before FFI', () {
    final unknown = validFrame().copyWith(
      identity: const OpenCvAutoCaptureIdentity(
        captureProductId: '',
        calibrationId: '',
      ),
    );
    expect(
      unknown.validationFailure(expectedIdentity: identity),
      OpenCvAutoCaptureValidationFailure.unknownIdentity,
    );

    final badCrop = validFrame().copyWith(cropX: 3, cropWidth: 2);
    expect(
      badCrop.validationFailure(expectedIdentity: identity),
      OpenCvAutoCaptureValidationFailure.invalidCrop,
    );
  });

  test('non-finite camera metadata fails closed', () {
    final badK = validFrame().copyWith(
      intrinsics3x3: <double>[double.nan, 0, 2, 0, 100, 1.5, 0, 0, 1],
    );
    expect(
      badK.validationFailure(expectedIdentity: identity),
      OpenCvAutoCaptureValidationFailure.invalidCalibration,
    );
  });
}
