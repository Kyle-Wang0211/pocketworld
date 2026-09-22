// pw_af —— 内部统一标度 ↔ 各端镜头单位的换算实现。出处与偏离见 lens_scale.h。

#include "lens_scale.h"

#include <algorithm>
#include <cmath>

namespace pw_af {
namespace {

// 屈光度小于这个值就当「无穷远」,避免 Web 的 1/D 除零。
// 0.01 屈光度 = 100 m,远在任何手机镜头的超焦距之外
// (判决书 §5.3:超焦距 3.2–10.8 m)。
constexpr double kInfinityEpsilon = 0.01;

}  // namespace

bool PwAfPwl::Append(double x, double y) {
  if (!points_.empty() && x <= points_.back().first) {
    return false;
  }
  points_.emplace_back(x, y);
  return true;
}

// pwl.cpp:222-239 `Pwl::findSpan` —— 上游原注释:"Pwls are generally small,
// so linear search may well be faster than binary"。我们的表只有 2 个点。
int PwAfPwl::FindSpan(double x) const {
  const int lastSpan = static_cast<int>(points_.size()) - 2;
  int span = std::max(0, std::min(lastSpan, lastSpan / 2));
  while (span < lastSpan && x >= points_[span + 1].first) {
    span++;
  }
  while (span > 0 && x < points_[span].first) {
    span--;
  }
  return span;
}

// pwl.cpp:206-220 `Pwl::eval`。
double PwAfPwl::Eval(double x) const {
  if (points_.empty()) {
    return 0.0;
  }
  if (points_.size() == 1) {
    return points_[0].second;  // pwl.cpp:214-215
  }
  const int i = FindSpan(x);
  const double x0 = points_[i].first;
  const double y0 = points_[i].second;
  const double x1 = points_[i + 1].first;
  const double y1 = points_[i + 1].second;
  // pwl.cpp:217-219。x 在定义域外时这里是沿端点段外推(偏离 L1)。
  return y0 + (x - x0) * (y1 - y0) / (x1 - x0);
}

double PwAfPwl::EvalInverse(double y) const {
  if (points_.empty()) {
    return 0.0;
  }
  if (points_.size() == 1) {
    return points_[0].first;
  }
  for (std::size_t i = 0; i + 1 < points_.size(); ++i) {
    const double y0 = points_[i].second;
    const double y1 = points_[i + 1].second;
    const double lo = std::min(y0, y1);
    const double hi = std::max(y0, y1);
    if (y >= lo && y <= hi) {
      if (y0 == y1) {
        return points_[i].first;  // 平段:取左端点
      }
      const double t = (y - y0) / (y1 - y0);
      return points_[i].first +
             t * (points_[i + 1].first - points_[i].first);
    }
  }
  // 落在值域外:钳到 y 更近的那个端点(值域可能递增也可能递减)。
  const double yFront = points_.front().second;
  const double yBack = points_.back().second;
  return std::abs(y - yFront) <= std::abs(y - yBack) ? points_.front().first
                                                     : points_.back().first;
}

double PwAfPwl::DomainStart() const {
  return points_.empty() ? 0.0 : points_.front().first;
}

double PwAfPwl::DomainEnd() const {
  return points_.empty() ? 0.0 : points_.back().first;
}

double PwAfPwl::ClampToDomain(double x) const {
  if (points_.empty()) {
    return x;
  }
  return std::clamp(x, DomainStart(), DomainEnd());
}

double PwAfToPlatform(const PwLensScale& scale, double internalScale) {
  const double d =
      std::clamp(internalScale, scale.internalMin, scale.internalMax);

  double platform;
  if (scale.unit == PwLensUnit::WebMetres) {
    // 偏离 L2:闭式倒数,不走 Pwl。
    platform = (d <= kInfinityEpsilon) ? scale.platformMax : (1.0 / d);
  } else {
    platform = scale.map.Eval(d);
  }
  // 偏离 L1:最后一步一律钳到平台合法区间。
  return std::clamp(platform, std::min(scale.platformMin, scale.platformMax),
                    std::max(scale.platformMin, scale.platformMax));
}

double PwAfFromPlatform(const PwLensScale& scale, double platformValue) {
  const double p =
      std::clamp(platformValue, std::min(scale.platformMin, scale.platformMax),
                 std::max(scale.platformMin, scale.platformMax));

  double internal;
  if (scale.unit == PwLensUnit::WebMetres) {
    internal = (p <= 0.0) ? scale.internalMax : (1.0 / p);
  } else {
    internal = scale.map.EvalInverse(p);
  }
  return std::clamp(internal, scale.internalMin, scale.internalMax);
}

// iOS:0.0 = 最近、1.0 = 最远 ⇒ y 随 x(屈光度)递减。
// 🔴 两点线性占位,不是标定(偏离 L3)。
PwLensScale PwAfMakeIosScale(double nearDioptre, double farDioptre) {
  PwLensScale s;
  s.unit = PwLensUnit::IosNormalized;
  s.internalMin = std::min(nearDioptre, farDioptre);
  s.internalMax = std::max(nearDioptre, farDioptre);
  s.platformMin = 0.0;
  s.platformMax = 1.0;
  // x 必须递增:先放远端(屈光度小 → lensPosition 1.0),再放近端(→ 0.0)。
  s.map.Append(s.internalMin, 1.0);
  s.map.Append(s.internalMax, 0.0);
  return s;
}

// 鸿蒙:官方文档与 iOS 同向同区间(0.0 = shortest, 1.0 = longest)。
// 🔴 同样是占位(偏离 L3)。
// 🔴 可用性红线(判决书 §4):ManualFocus 在 API 12–20 是系统接口
//    (错误码 202 Not System Application),API 24 / HarmonyOS 6.1.1 起才开放;
//    且只混入 PhotoSession,VideoSession 不含 ⇒ 鸿蒙上「视频流持续对焦」
//    文档上就是堵的,只能做「拍照会话里对焦」。
PwLensScale PwAfMakeHarmonyScale(double nearDioptre, double farDioptre) {
  PwLensScale s = PwAfMakeIosScale(nearDioptre, farDioptre);
  s.unit = PwLensUnit::HarmonyNormalized;
  return s;
}

// Android:恒等。LENS_FOCUS_DISTANCE 就是屈光度、0.0f 就是无穷远。
// 🔴 标定等级看 LENS_INFO_FOCUS_DISTANCE_CALIBRATION:UNCALIBRATED 档
//    「do not correspond to any physical units」,只有 0.0f 仍保证是最远
//    (判决书 §4 表 G)⇒ 恒等映射在 UNCALIBRATED 上只保方向不保刻度。
PwLensScale PwAfMakeAndroidScale(double minFocusDistanceDioptres) {
  PwLensScale s;
  s.unit = PwLensUnit::AndroidDioptre;
  const double maxD = std::max(0.0, minFocusDistanceDioptres);
  s.internalMin = 0.0;
  s.internalMax = maxD;
  s.platformMin = 0.0;
  s.platformMax = maxD;
  s.map.Append(0.0, 0.0);
  if (maxD > 0.0) {
    s.map.Append(maxD, maxD);
  }
  return s;
}

// Web:米 = 1/屈光度(偏离 L2)。
// 🔴 可用性红线(判决书 §4):focusDistance 只有 Chromium 实现(Chrome 76+);
//    WebKit 的 IDL 里只存在于 FIXME 注释 ⇒ Safari / iOS Safari 不支持;
//    Firefox 的 webidl 里没有这两个成员 ⇒ Web 端软件对焦只能在 Chrome 上做。
PwLensScale PwAfMakeWebScale(double minMetres, double maxMetres) {
  PwLensScale s;
  s.unit = PwLensUnit::WebMetres;
  s.platformMin = std::min(minMetres, maxMetres);
  s.platformMax = std::max(minMetres, maxMetres);
  // 米 → 屈光度是反序:最小的米 = 最大的屈光度。
  s.internalMin = (s.platformMax > 0.0) ? (1.0 / s.platformMax) : 0.0;
  s.internalMax = (s.platformMin > 0.0) ? (1.0 / s.platformMin) : 0.0;
  return s;
}

}  // namespace pw_af
