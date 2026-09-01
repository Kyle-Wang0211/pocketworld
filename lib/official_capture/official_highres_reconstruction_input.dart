import 'dart:typed_data';

enum OfficialHighResInputFailure {
  captureFailed,
  captureTimedOut,
  unexpectedDimensions,
  outOfSync,
  missingPose,
  missingIntrinsics,
  missingJpeg,
  actualStillMissingEvidence,
  actualStillQualityRejected,
  actualStillDuplicate,
  transactionMismatch,
}

/// Typed terminal receipt for a shutter ticket that was admitted but did not
/// produce an accepted reconstruction photo. Callers can log the exact
/// cross-platform failure enum instead of scraping a generic StateError.
class OfficialHighResCaptureException implements Exception {
  const OfficialHighResCaptureException(
    this.failure, {
    required this.message,
    this.rejectedInput,
  });

  final OfficialHighResInputFailure failure;
  final String message;
  final OfficialHighResReconstructionInput? rejectedInput;

  @override
  String toString() =>
      'OfficialHighResCaptureException(${failure.name}): $message';
}

class OfficialHighResInputValidation {
  const OfficialHighResInputValidation.accepted(this.input) : failure = null;

  const OfficialHighResInputValidation.rejected(this.failure) : input = null;

  final OfficialHighResReconstructionInput? input;
  final OfficialHighResInputFailure? failure;

  bool get isAccepted => input != null;
}

class OfficialHighResReconstructionInput {
  const OfficialHighResReconstructionInput._({
    required this.transactionId,
    required this.jpegPath,
    required this.imageWidth,
    required this.imageHeight,
    required this.triggerTimestamp,
    required this.captureTimestamp,
    required this.requestPose,
    required this.evidencePose,
    required this.cardPose,
    required this.intrinsics,
    required this.gray128,
  });

  static const int requiredWidth = 4032;
  static const int requiredHeight = 3024;

  final String transactionId;
  final String jpegPath;
  final int imageWidth;
  final int imageHeight;
  final double triggerTimestamp;
  final double captureTimestamp;
  final List<double> requestPose;
  final List<double> evidencePose;
  final List<double> cardPose;

  /// Compatibility view for consumers not yet migrated to the explicit
  /// evidence-pose name. New transaction code must use [evidencePose].
  List<double> get cameraTransform => evidencePose;
  final List<double> intrinsics;
  final Uint8List? gray128;

  double get timestampDeltaSeconds =>
      (captureTimestamp - triggerTimestamp).abs();

  static OfficialHighResInputValidation validate({
    String? expectedTransactionId,
    String? transactionId,
    required String jpegPath,
    required int imageWidth,
    required int imageHeight,
    required double triggerTimestamp,
    required double captureTimestamp,
    List<double>? requestPose,
    List<double>? evidencePose,
    List<double>? cardPose,
    List<double>? cameraTransform,
    required List<double> intrinsics,
    Uint8List? gray128,
  }) {
    final resolvedTransactionId = transactionId ?? expectedTransactionId ?? '';
    if (expectedTransactionId != null &&
        (expectedTransactionId.isEmpty ||
            resolvedTransactionId != expectedTransactionId)) {
      return const OfficialHighResInputValidation.rejected(
        OfficialHighResInputFailure.transactionMismatch,
      );
    }
    if (jpegPath.isEmpty ||
        !(jpegPath.toLowerCase().endsWith('.jpg') ||
            jpegPath.toLowerCase().endsWith('.jpeg'))) {
      return const OfficialHighResInputValidation.rejected(
        OfficialHighResInputFailure.missingJpeg,
      );
    }
    if (imageWidth != requiredWidth || imageHeight != requiredHeight) {
      return const OfficialHighResInputValidation.rejected(
        OfficialHighResInputFailure.unexpectedDimensions,
      );
    }
    // `captureHighResolutionFrame` completes the exact native request that
    // created this input, and image/pose/intrinsics/timestamp all come from
    // that one returned ARFrame. The request-to-frame delta is camera pipeline
    // latency (250 ms median and up to 1.23 s on the target iPhone), not a
    // measure of image/pose synchronization. Keep both clocks for audit, but
    // never reject a valid transaction merely because the sensor was slow.
    if (!triggerTimestamp.isFinite || !captureTimestamp.isFinite) {
      return const OfficialHighResInputValidation.rejected(
        OfficialHighResInputFailure.outOfSync,
      );
    }
    final resolvedEvidencePose = evidencePose ?? cameraTransform ?? const [];
    final resolvedRequestPose = requestPose ?? resolvedEvidencePose;
    final resolvedCardPose = cardPose ?? resolvedRequestPose;
    if (resolvedRequestPose.length != 16 ||
        resolvedRequestPose.any((value) => !value.isFinite) ||
        resolvedEvidencePose.length != 16 ||
        resolvedEvidencePose.any((value) => !value.isFinite) ||
        resolvedCardPose.length != 16 ||
        resolvedCardPose.any((value) => !value.isFinite)) {
      return const OfficialHighResInputValidation.rejected(
        OfficialHighResInputFailure.missingPose,
      );
    }
    if (intrinsics.length < 4 ||
        intrinsics.take(4).any((value) => !value.isFinite || value <= 0)) {
      return const OfficialHighResInputValidation.rejected(
        OfficialHighResInputFailure.missingIntrinsics,
      );
    }
    return OfficialHighResInputValidation.accepted(
      OfficialHighResReconstructionInput._(
        transactionId: resolvedTransactionId,
        jpegPath: jpegPath,
        imageWidth: imageWidth,
        imageHeight: imageHeight,
        triggerTimestamp: triggerTimestamp,
        captureTimestamp: captureTimestamp,
        requestPose: List<double>.unmodifiable(resolvedRequestPose),
        evidencePose: List<double>.unmodifiable(resolvedEvidencePose),
        cardPose: List<double>.unmodifiable(resolvedCardPose),
        intrinsics: List<double>.unmodifiable(intrinsics.take(4)),
        gray128: gray128 == null ? null : Uint8List.fromList(gray128),
      ),
    );
  }
}
