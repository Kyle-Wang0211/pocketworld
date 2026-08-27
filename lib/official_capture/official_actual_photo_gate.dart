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
    evidence.isKeyframeCandidate;

/// Final fail-closed gate over the image that the native 12 MP transaction
/// actually returned. Candidate-frame admission remains responsible for
/// coverage and responsiveness; this gate prevents a delayed duplicate or
/// degraded still from entering the album, SfM, or coverage state.
class OfficialActualPhotoGate {
  Uint8List? _lastAcceptedGray128;
  double? _lastAcceptedFocalX;
  double? _lastAcceptedFocalY;
  int _acceptedCount = 0;

  int get acceptedCount => _acceptedCount;

  void reset() {
    _lastAcceptedGray128 = null;
    _lastAcceptedFocalX = null;
    _lastAcceptedFocalY = null;
    _acceptedCount = 0;
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
        intrinsics.length < 2 ||
        !intrinsics[0].isFinite ||
        !intrinsics[1].isFinite ||
        intrinsics[0] <= 0 ||
        intrinsics[1] <= 0) {
      return const OfficialActualPhotoGateResult(
        OfficialActualPhotoDecision.rejectMissingEvidence,
      );
    }

    final focalX = intrinsics[0] * 128.0 / imageWidth;
    final focalY = intrinsics[1] * 128.0 / imageHeight;
    final previous = _lastAcceptedGray128;
    if (previous == null) {
      _commit(gray128, focalX, focalY);
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
    );
    if (!officialActualPhotoTrackAccepted(evidence)) {
      return OfficialActualPhotoGateResult(
        OfficialActualPhotoDecision.rejectDuplicate,
        trackEvidence: evidence,
      );
    }
    _commit(gray128, focalX, focalY);
    return OfficialActualPhotoGateResult(
      OfficialActualPhotoDecision.accept,
      trackEvidence: evidence,
    );
  }

  void _commit(Uint8List gray128, double focalX, double focalY) {
    _lastAcceptedGray128 = Uint8List.fromList(gray128);
    _lastAcceptedFocalX = focalX;
    _lastAcceptedFocalY = focalY;
    _acceptedCount += 1;
  }
}
