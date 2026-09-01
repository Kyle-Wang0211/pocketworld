import 'dart:typed_data';

import 'continuous_feature_tracks.dart';

enum OfficialActualPhotoDecision {
  accept,
  rejectMissingEvidence,
  rejectQuality,
  rejectDuplicate,
}

class OfficialActualPhotoGateResult {
  const OfficialActualPhotoGateResult(this.decision, {this.trackEvidence});

  final OfficialActualPhotoDecision decision;
  final FrameTrackEvidence? trackEvidence;

  bool get accepted => decision == OfficialActualPhotoDecision.accept;
}

bool officialActualPhotoTrackAccepted(FrameTrackEvidence evidence) =>
    evidence.isCaptureNoveltyVerified || evidence.lostTrackedOverlap;

/// Final fail-closed gate over the image that the native 12 MP transaction
/// actually returned. [evaluate] is deliberately side-effect free: the
/// caller must finish the album/SfM/coverage transaction and then invoke
/// [commitAccepted]. A rejected or downstream-failed candidate therefore
/// cannot advance the actual-photo baseline.
class OfficialActualPhotoGate {
  Uint8List? _lastAcceptedGray128;
  double? _lastAcceptedFocalX;
  double? _lastAcceptedFocalY;
  double? _lastAcceptedPrincipalX;
  double? _lastAcceptedPrincipalY;
  int _acceptedCount = 0;
  final Set<String> _acceptedTransactions = <String>{};

  int get acceptedCount => _acceptedCount;

  void reset() {
    _lastAcceptedGray128 = null;
    _lastAcceptedFocalX = null;
    _lastAcceptedFocalY = null;
    _lastAcceptedPrincipalX = null;
    _lastAcceptedPrincipalY = null;
    _acceptedCount = 0;
    _acceptedTransactions.clear();
  }

  OfficialActualPhotoGateResult evaluate({
    required Uint8List? gray128,
    required int imageWidth,
    required int imageHeight,
    required List<double> intrinsics,
    required bool qualityAccepted,
  }) {
    if (!qualityAccepted) {
      return const OfficialActualPhotoGateResult(
        OfficialActualPhotoDecision.rejectQuality,
      );
    }
    if (gray128 == null ||
        gray128.length != 128 * 128 ||
        imageWidth <= 0 ||
        imageHeight <= 0 ||
        intrinsics.length < 4 ||
        !intrinsics[0].isFinite ||
        !intrinsics[1].isFinite ||
        intrinsics[0] <= 0 ||
        intrinsics[1] <= 0 ||
        !intrinsics[2].isFinite ||
        !intrinsics[3].isFinite) {
      return const OfficialActualPhotoGateResult(
        OfficialActualPhotoDecision.rejectMissingEvidence,
      );
    }

    final focalX = intrinsics[0] * 128.0 / imageWidth;
    final focalY = intrinsics[1] * 128.0 / imageHeight;
    final principalX = intrinsics[2] * 128.0 / imageWidth;
    final principalY = intrinsics[3] * 128.0 / imageHeight;
    final previous = _lastAcceptedGray128;
    if (previous == null) {
      return const OfficialActualPhotoGateResult(
        OfficialActualPhotoDecision.accept,
      );
    }

    final evidence = trackFrameNovelty(
      previousGray: previous,
      currentGray: gray128,
      width: 128,
      height: 128,
      focalXPixels: ((_lastAcceptedFocalX ?? focalX) + focalX) * 0.5,
      focalYPixels: ((_lastAcceptedFocalY ?? focalY) + focalY) * 0.5,
      principalXPixels:
          ((_lastAcceptedPrincipalX ?? principalX) + principalX) * 0.5,
      principalYPixels:
          ((_lastAcceptedPrincipalY ?? principalY) + principalY) * 0.5,
    );
    if (!officialActualPhotoTrackAccepted(evidence)) {
      return OfficialActualPhotoGateResult(
        OfficialActualPhotoDecision.rejectDuplicate,
        trackEvidence: evidence,
      );
    }
    return OfficialActualPhotoGateResult(
      OfficialActualPhotoDecision.accept,
      trackEvidence: evidence,
    );
  }

  void commitAccepted({
    required String transactionId,
    required Uint8List gray128,
    required int imageWidth,
    required int imageHeight,
    required List<double> intrinsics,
  }) {
    if (gray128.length != 128 * 128 ||
        imageWidth <= 0 ||
        imageHeight <= 0 ||
        intrinsics.length < 4 ||
        !intrinsics[0].isFinite ||
        !intrinsics[1].isFinite ||
        intrinsics[0] <= 0 ||
        intrinsics[1] <= 0 ||
        !intrinsics[2].isFinite ||
        !intrinsics[3].isFinite) {
      throw ArgumentError('accepted still evidence is incomplete');
    }
    if (!_acceptedTransactions.add(transactionId)) return;
    final focalX = intrinsics[0] * 128.0 / imageWidth;
    final focalY = intrinsics[1] * 128.0 / imageHeight;
    final principalX = intrinsics[2] * 128.0 / imageWidth;
    final principalY = intrinsics[3] * 128.0 / imageHeight;
    _lastAcceptedGray128 = Uint8List.fromList(gray128);
    _lastAcceptedFocalX = focalX;
    _lastAcceptedFocalY = focalY;
    _lastAcceptedPrincipalX = principalX;
    _lastAcceptedPrincipalY = principalY;
    _acceptedCount += 1;
  }
}
