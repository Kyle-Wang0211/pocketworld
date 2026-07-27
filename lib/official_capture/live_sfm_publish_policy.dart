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

/// [SIGNED 2026-07-27] 采集张数硬上限 —— 单次任务支持 20-300 张(RS 同款
/// 分子/分母口径,相册按钮上直接显示 N/300)。上限是产品承诺也是工程边界:
/// 端上重建的时间/内存曲线按这个范围验证,超出即无保障,故在**快门入口**
/// 硬卡死,而不是靠提示劝阻。
const int kOfficialMaximumCaptureFrames = 300;

bool officialCaptureCanFinish({required int acceptedFrameCount}) =>
    acceptedFrameCount >= kOfficialMinimumCaptureFrames;

/// 快门是否还能再拍(达到上限即 false;唯一判据,UI 与逻辑同源)。
bool officialCaptureCanShoot({required int acceptedFrameCount}) =>
    acceptedFrameCount < kOfficialMaximumCaptureFrames;

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
