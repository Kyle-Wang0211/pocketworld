// pw_af 镜头标度换算单测。判据全部来自判决书 §4 的四端接口矩阵(官方文档原文)。

#include "lens_scale.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <iostream>

namespace {

using pw_af::PwAfFromPlatform;
using pw_af::PwAfMakeAndroidScale;
using pw_af::PwAfMakeHarmonyScale;
using pw_af::PwAfMakeIosScale;
using pw_af::PwAfMakeWebScale;
using pw_af::PwAfPwl;
using pw_af::PwAfToPlatform;
using pw_af::PwLensScale;
using pw_af::PwLensUnit;

void Check(bool condition, const char* expression, int line) {
  if (!condition) {
    std::cerr << "CHECK failed at line " << line << ": " << expression << '\n';
    std::exit(1);
  }
}

#define CHECK(expression) Check((expression), #expression, __LINE__)

bool Near(double a, double b, double tol = 1e-9) {
  return std::abs(a - b) <= tol;
}

// ———————————————————————————————————————————————————————————————————————
// 1. PwAfPwl:插值 / 外推 / 定义域,对照 pwl.cpp:206-239 与上游默认 map。
// ———————————————————————————————————————————————————————————————————————
void TestPwlMatchesUpstreamDefaultMap() {
  // 上游默认 map(af.cpp:159-165)= imx708.json "map": [0.0, 445, 15.0, 925]。
  PwAfPwl map;
  CHECK(map.Append(0.0, 445.0));
  CHECK(map.Append(15.0, 925.0));
  CHECK(!map.Append(15.0, 999.0));  // x 必须严格递增

  CHECK(Near(map.DomainStart(), 0.0));
  CHECK(Near(map.DomainEnd(), 15.0));
  CHECK(Near(map.Eval(0.0), 445.0));
  CHECK(Near(map.Eval(15.0), 925.0));
  CHECK(Near(map.Eval(7.5), 685.0));  // 中点
  // 定义域外沿端点段外推(与上游 Pwl::eval 同,偏离 L1)。
  CHECK(Near(map.Eval(-1.0), 445.0 - 32.0));
  CHECK(Near(map.Eval(16.0), 925.0 + 32.0));
  // ClampToDomain 对应 af.cpp:895 的 domain().clamp()。
  CHECK(Near(map.ClampToDomain(-1.0), 0.0));
  CHECK(Near(map.ClampToDomain(16.0), 15.0));

  // 反查。
  CHECK(Near(map.EvalInverse(685.0), 7.5));
  CHECK(Near(map.EvalInverse(445.0), 0.0));
  CHECK(Near(map.EvalInverse(925.0), 15.0));

  // 递减的 y 也要能反查(iOS 的 map 就是递减的)。
  PwAfPwl dec;
  dec.Append(3.0, 1.0);
  dec.Append(15.0, 0.0);
  CHECK(Near(dec.Eval(9.0), 0.5));
  CHECK(Near(dec.EvalInverse(0.5), 9.0));
  std::printf("  [Pwl] 上游默认 map [0→445, 15→925] 插值/外推/反查全对\n");
}

// ———————————————————————————————————————————————————————————————————————
// 2. iOS:0.0 = 最近、1.0 = 最远 ⇒ 方向必须与内部标度相反。
// ———————————————————————————————————————————————————————————————————————
void TestIosDirectionIsInverted() {
  // macro 档区间:近 15 屈光度(6.7 cm)、远 3 屈光度(33 cm)。
  const PwLensScale s = PwAfMakeIosScale(15.0, 3.0);
  CHECK(s.unit == PwLensUnit::IosNormalized);
  CHECK(Near(s.internalMin, 3.0) && Near(s.internalMax, 15.0));

  const double atNear = PwAfToPlatform(s, 15.0);  // 最近
  const double atFar = PwAfToPlatform(s, 3.0);    // 最远
  const double atMid = PwAfToPlatform(s, 9.0);
  CHECK(Near(atNear, 0.0));   // Apple: 0.0 = shortest distance
  CHECK(Near(atFar, 1.0));    // Apple: 1.0 = furthest
  CHECK(Near(atMid, 0.5));
  CHECK(atNear < atMid && atMid < atFar);  // 越近 ⇒ lensPosition 越小

  // 🔴 判决书 §4 后果三:现状零 ARKit 臂锁的 lensPosition = 0.835
  //    (PwCameraSlot.swift:237-241)**偏在远端**。
  //    这里只能验这一条**与标定无关**的事实:0.835 在归一化行程上离
  //    「最远」(1.0)比离「最近」(0.0)近得多。
  // 🔴 **不能**把 0.835 换算成厘米 —— Apple 明文 "doesn't correspond to an
  //    exact physical distance, nor does it represent a consistent focus
  //    distance from device to device"(判决书 §4 表 G),而本文件的 map 是
  //    占位不是标定(偏离 L3)。任何「0.835 ≈ N 厘米」的说法都是没有依据的。
  const double kLocked = 0.835;
  CHECK(kLocked > 0.5);                        // 落在行程的远半边
  CHECK((1.0 - kLocked) < kLocked / 4.0);      // 离远端比离近端近 4 倍以上
  std::printf("  [iOS] 近端 15D→%.3f、中点 9D→%.3f、远端 3D→%.3f;"
              "现状锁的 %.3f 在归一化行程上距远端 %.3f、距近端 %.3f ⇒ 偏远端"
              "(🔴 不可换算成距离)\n",
              atNear, atMid, atFar, kLocked, 1.0 - kLocked, kLocked);

  // 钳位:超出内部区间的值不许吐出 [0,1] 之外的东西(偏离 L1)。
  CHECK(Near(PwAfToPlatform(s, 99.0), 0.0));
  CHECK(Near(PwAfToPlatform(s, -99.0), 1.0));

  // 往返。
  for (double d = 3.0; d <= 15.0; d += 1.5) {
    CHECK(Near(PwAfFromPlatform(s, PwAfToPlatform(s, d)), d, 1e-9));
  }
}

// ———————————————————————————————————————————————————————————————————————
// 3. 鸿蒙:与 iOS 同向同区间,只是 unit 不同。
// ———————————————————————————————————————————————————————————————————————
void TestHarmonySameDirectionAsIos() {
  const PwLensScale ios = PwAfMakeIosScale(15.0, 3.0);
  const PwLensScale oh = PwAfMakeHarmonyScale(15.0, 3.0);
  CHECK(oh.unit == PwLensUnit::HarmonyNormalized);
  for (double d = 3.0; d <= 15.0; d += 1.0) {
    CHECK(Near(PwAfToPlatform(oh, d), PwAfToPlatform(ios, d)));
  }
  CHECK(Near(PwAfToPlatform(oh, 15.0), 0.0));  // 0.0 = shortest achievable
  CHECK(Near(PwAfToPlatform(oh, 3.0), 1.0));   // 1.0 = longest
  std::printf("  [鸿蒙] 与 iOS 逐点相同(0.0=最近、1.0=最远)\n");
}

// ———————————————————————————————————————————————————————————————————————
// 4. Android:恒等(屈光度、0.0f = 无穷远),四端里唯一同向同量纲的。
// ———————————————————————————————————————————————————————————————————————
void TestAndroidIsIdentity() {
  // LENS_INFO_MINIMUM_FOCUS_DISTANCE = 10 屈光度(最近 10 cm)。
  const PwLensScale s = PwAfMakeAndroidScale(10.0);
  CHECK(s.unit == PwLensUnit::AndroidDioptre);
  for (double d = 0.0; d <= 10.0; d += 1.0) {
    CHECK(Near(PwAfToPlatform(s, d), d));
    CHECK(Near(PwAfFromPlatform(s, d), d));
  }
  CHECK(Near(PwAfToPlatform(s, 0.0), 0.0));    // 0.0f = 无穷远
  CHECK(Near(PwAfToPlatform(s, 99.0), 10.0));  // 钳到 minimumFocusDistance

  // LEGACY / 定焦机型:minimumFocusDistance = 0 ⇒ 只能对无穷远。
  const PwLensScale fixed = PwAfMakeAndroidScale(0.0);
  CHECK(Near(PwAfToPlatform(fixed, 8.0), 0.0));
  std::printf("  [Android] 恒等映射;定焦机型(min=0)恒吐 0.0 = 无穷远\n");
}

// ———————————————————————————————————————————————————————————————————————
// 5. Web:米 = 1/屈光度(闭式,偏离 L2)。
// ———————————————————————————————————————————————————————————————————————
void TestWebIsReciprocalMetres() {
  // 能力表 {min: 0.05 m, max: 10 m}。
  const PwLensScale s = PwAfMakeWebScale(0.05, 10.0);
  CHECK(s.unit == PwLensUnit::WebMetres);
  CHECK(Near(s.internalMin, 0.1));   // 1/10 m
  CHECK(Near(s.internalMax, 20.0));  // 1/0.05 m

  CHECK(Near(PwAfToPlatform(s, 5.0), 0.2));    // 5 屈光度 = 20 cm
  CHECK(Near(PwAfToPlatform(s, 10.0), 0.1));   // 10 屈光度 = 10 cm
  CHECK(Near(PwAfToPlatform(s, 20.0), 0.05));  // 近端
  CHECK(Near(PwAfFromPlatform(s, 0.2), 5.0));

  // 往返。
  for (double d = 0.5; d <= 20.0; d += 0.5) {
    CHECK(Near(PwAfFromPlatform(s, PwAfToPlatform(s, d)), d, 1e-9));
  }
  std::printf("  [Web] 5D→%.3f m、10D→%.3f m(闭式倒数,不走 Pwl)\n",
              PwAfToPlatform(s, 5.0), PwAfToPlatform(s, 10.0));
}

// ———————————————————————————————————————————————————————————————————————
// 6. 跨端一致性:同一个内部标度在四端吐出的**物理含义**必须一致。
//    判据:用各端自己的定义把平台值换算回物距,四端应当对上。
// ———————————————————————————————————————————————————————————————————————
void TestSameInternalScaleMeansSameDistanceAcrossPlatforms() {
  const double kInternal = 5.0;  // 5 屈光度 = 20 cm,用户口径的正中间

  const PwLensScale ios = PwAfMakeIosScale(15.0, 3.0);
  const PwLensScale oh = PwAfMakeHarmonyScale(15.0, 3.0);
  const PwLensScale android = PwAfMakeAndroidScale(15.0);
  const PwLensScale web = PwAfMakeWebScale(1.0 / 15.0, 1.0 / 3.0);

  // Android 与 Web 有物理定义,可以直接验物距。
  CHECK(Near(1.0 / PwAfToPlatform(android, kInternal), 0.2));
  CHECK(Near(PwAfToPlatform(web, kInternal), 0.2));

  // iOS / 鸿蒙只有归一化值 —— 🔴 Apple 明文说它不对应确切物理距离,
  // 所以这里只能验「反算回内部标度是同一个数」(往返一致),不能验物距。
  CHECK(Near(PwAfFromPlatform(ios, PwAfToPlatform(ios, kInternal)), kInternal));
  CHECK(Near(PwAfFromPlatform(oh, PwAfToPlatform(oh, kInternal)), kInternal));

  std::printf("  [跨端] 内部 5.0 屈光度(20 cm) ⇒ iOS %.4f / 鸿蒙 %.4f / "
              "Android %.2f D / Web %.3f m\n",
              PwAfToPlatform(ios, kInternal), PwAfToPlatform(oh, kInternal),
              PwAfToPlatform(android, kInternal),
              PwAfToPlatform(web, kInternal));
}

}  // namespace

int main() {
  std::printf("pw_af_lens_scale_test\n");
  TestPwlMatchesUpstreamDefaultMap();
  TestIosDirectionIsInverted();
  TestHarmonySameDirectionAsIos();
  TestAndroidIsIdentity();
  TestWebIsReciprocalMetres();
  TestSameInternalScaleMeansSameDistanceAcrossPlatforms();
  std::printf("pw_af_lens_scale_test: ALL PASS\n");
  return 0;
}
