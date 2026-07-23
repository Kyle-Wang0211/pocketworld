/// Capture-time publication policy for the independent official route.
///
/// Registration/local refinement continues for every accepted frame. The AR
/// overlay only changes after a successful whole-component global BA:
/// first at 20 frames, then whenever registered cameras or reconstructed
/// points have grown by at least 40% from the same last published version.
/// This is one unified OR trigger, matching COLMAP's video-oriented 1.40
/// global-BA growth rule. A successful publish resets both baselines together;
/// there is no independent fixed-frame checkpoint clock.
const int kOfficialMinimumCaptureFrames = 20;
const double kOfficialGlobalBaGrowthRatio = 1.40;

bool officialCaptureCanFinish({required int acceptedFrameCount}) =>
    acceptedFrameCount >= kOfficialMinimumCaptureFrames;

class OfficialLiveSfmPublishPolicy {
  int _publishedRegisteredFrames = 0;
  int _publishedPointCount = 0;
  int _version = 0;

  int get version => _version;
  int get publishedRegisteredFrames => _publishedRegisteredFrames;
  int get publishedPointCount => _publishedPointCount;

  bool shouldRunGlobalBa({
    required int registeredFrames,
    required int pointCount,
  }) {
    if (registeredFrames < kOfficialMinimumCaptureFrames || pointCount <= 0) {
      return false;
    }
    if (_version == 0) return true;

    return registeredFrames >=
            _publishedRegisteredFrames * kOfficialGlobalBaGrowthRatio ||
        pointCount >= _publishedPointCount * kOfficialGlobalBaGrowthRatio;
  }

  /// Commit only after native global BA and snapshot extraction both succeed.
  /// A failed attempt deliberately leaves the thresholds unchanged so the next
  /// accepted frame retries instead of silently freezing an old cloud.
  void markGlobalBaPublished({
    required int registeredFrames,
    required int pointCount,
  }) {
    if (registeredFrames < kOfficialMinimumCaptureFrames || pointCount <= 0) {
      throw ArgumentError(
        'A stable official cloud requires 20 frames and points',
      );
    }
    _publishedRegisteredFrames = registeredFrames;
    _publishedPointCount = pointCount;
    _version++;
  }
}
