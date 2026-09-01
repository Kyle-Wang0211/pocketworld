// parallax_banner_gate.dart — "拍摄角度不足"实时横幅的去抖/滞回门(纯 Dart)。
//
// 背景(引导反馈最后一公里):route B 真值视差已落地(true_parallax.dart →
// CaptureCoverageCloud.applyTrueParallax),但黄框/覆盖云都要求用户"看见
// 具体位置";用户实际痛点是拍的当下不知道"拍够没"。本门把
// CaptureCoverageCloud.coverageStats().starvedTrue(观测达标但真实三角化角
// <8° 的体素数 —— 真值口径,不用 route A 视锥近似)折叠成一个横幅开关:
//
//   显示:连续 [debounceSamples] 次采样 ≥ [showThreshold](去抖防单次尖峰
//         闪烁 —— 真值按 worker 节奏几秒一批到达,单批可能抖动);
//   隐藏:采样 < [hideThreshold] 立即隐藏(hide < show 的滞回带,防止
//         计数在阈值附近来回穿越时横幅闪烁)。
//
// 采样时机由调用方决定 —— 挂在既有的覆盖云刷新回调(markCapture 后)与
// SfmLiveTrueParallax 事件上,**不新增计时器**(ar_capture_page 的
// _sampleStarvedBanner)。本文件零 Flutter 依赖,tool/parallax_banner_check.dart
// 用纯 Dart VM 构造计数序列直接断言出现/隐藏时机。

/// 横幅显示门槛(体素数,≥ 判超):starvedTrue 持续超过它才提示补拍。
/// 只管横幅 —— 完成把关弹窗已改**占比口径**,见
/// [kParallaxStarvedFinishRatio] / [starvedFinishGateShouldPrompt]。
const int kParallaxStarvedShowThreshold = 20;

/// 横幅隐藏门槛(体素数,< 判回落)。与 [kParallaxStarvedShowThreshold]
/// 构成滞回带:10..19 区间内已显示的横幅保持、未显示的不触发。
const int kParallaxStarvedHideThreshold = 10;

/// 显示去抖:连续超阈值采样次数。
const int kParallaxStarvedDebounceSamples = 3;

/// 去抖 + 滞回状态机。[onSample] 喂入最新 starved 计数,返回横幅当前
/// 应否可见。无内部时钟 —— 节奏完全由调用方的采样节奏决定。
class StarvedParallaxBannerGate {
  StarvedParallaxBannerGate({
    this.showThreshold = kParallaxStarvedShowThreshold,
    this.hideThreshold = kParallaxStarvedHideThreshold,
    this.debounceSamples = kParallaxStarvedDebounceSamples,
  }) : assert(hideThreshold <= showThreshold, '滞回带要求 hide ≤ show'),
       assert(debounceSamples >= 1);

  final int showThreshold;
  final int hideThreshold;
  final int debounceSamples;

  int _consecutiveHigh = 0;
  bool _visible = false;

  /// 横幅当前应否可见(最近一次 [onSample] 的结论)。
  bool get visible => _visible;

  /// 喂入一次 starved 体素计数采样,返回更新后的可见性。
  bool onSample(int starvedCount) {
    if (_visible) {
      // 已显示:回落到滞回下界之下才隐藏;滞回带内保持,防闪烁。
      if (starvedCount < hideThreshold) {
        _visible = false;
        _consecutiveHigh = 0;
      }
    } else {
      // 未显示:连续 debounceSamples 次 ≥ showThreshold 才亮,单次尖峰
      // /中断都清零重计。
      if (starvedCount >= showThreshold) {
        _consecutiveHigh++;
        if (_consecutiveHigh >= debounceSamples) _visible = true;
      } else {
        _consecutiveHigh = 0;
      }
    }
    return _visible;
  }

  /// 新一轮拍摄归零(与 CaptureCoverageCloud.reset 同时机)。
  void reset() {
    _consecutiveHigh = 0;
    _visible = false;
  }
}

/// 完成把关弹窗的**占比**门槛:starved_true / true_vox 严格大于它才弹
/// (ar_capture_page._onFinishTap)。绝对数口径(>20)已废 —— 大场景
/// 体素基数大,绝对数必超导致"每次完成必弹"(真机实锤:1683/5997 ≈
/// 28%,健康程度尚可却被绝对数拦下);占比不随场景规模膨胀,<40% 不拦。
const double kParallaxStarvedFinishRatio = 0.40;

/// 完成把关判定(纯函数,tool/parallax_banner_check.dart 断言):
/// starved_true 占 true_vox(拿到真实三角化角的已覆盖体素数,
/// CaptureCoverageCloud.coverageStats)的比例严格大于 [ratio] 才弹。
/// [trueVoxels] == 0(真值未到达/极小场景)→ 不拦:没有真值证据就
/// 不阻拦用户完成(把关是提醒,不是惩罚证据缺失)。
bool starvedFinishGateShouldPrompt({
  required int starvedTrue,
  required int trueVoxels,
  double ratio = kParallaxStarvedFinishRatio,
}) => trueVoxels > 0 && starvedTrue > trueVoxels * ratio;
