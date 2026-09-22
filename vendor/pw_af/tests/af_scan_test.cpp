// pw_af 状态机单测。合成一维「清晰度 vs 镜头位置」曲线,驱动一个理想镜头。
//
// 断言式测试,照 vendor/xrslam/transport/tests/transport_core_test.cpp 的现成
// 做法(那里也没有测试框架):CHECK 失败即打印行号并 std::exit(1)。
//
// 【镜头模型】每帧把状态机上一帧吐出的 lensTarget 当作本帧实际的镜头位置,
// 即「命令下发后下一帧就到位」。这不是对真实 VCM 的建模 —— 真实的整定延迟由
// 状态机自己的 step_frames(5 帧)吸收,本测试验的是状态机逻辑,不是执行器。
// 🔴 真实 VCM 的行程 / 整定时间 / 迟滞判决书 §5.1 标注「未核」,台架才有。

#include "af_scan.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <functional>
#include <iostream>
#include <vector>

namespace {

using pw_af::PwAfConfig;
using pw_af::PwAfDefaultConfig;
using pw_af::PwAfFrame;
using pw_af::PwAfMode;
using pw_af::PwAfOutput;
using pw_af::PwAfRange;
using pw_af::PwAfScan;
using pw_af::PwAfSpeed;
using pw_af::PwAfState;

void Check(bool condition, const char* expression, int line) {
  if (!condition) {
    std::cerr << "CHECK failed at line " << line << ": " << expression << '\n';
    std::exit(1);
  }
}

#define CHECK(expression) Check((expression), #expression, __LINE__)

using Curve = std::function<double(double)>;

// 单峰:base + amp·exp(−(d−centre)²/(2σ²))。
Curve Peak(double base, double amp, double centre, double sigma) {
  return [=](double d) {
    const double t = (d - centre) / sigma;
    return base + amp * std::exp(-0.5 * t * t);
  };
}

// 双峰。
Curve TwoPeaks(double base, double ampNear, double centreNear, double ampFar,
               double centreFar, double sigma) {
  return [=](double d) {
    const double a = (d - centreNear) / sigma;
    const double b = (d - centreFar) / sigma;
    return base + ampNear * std::exp(-0.5 * a * a) +
           ampFar * std::exp(-0.5 * b * b);
  };
}

struct Trace {
  PwAfState finalState = PwAfState::Idle;
  double finalLens = 0.0;
  uint64_t samples = 0;
  int retriggers = 0;
  int scanFinishes = 0;
  int firstFinishFrame = -1;
  std::vector<uint64_t> sampleFrames;   // samplesConsumed 递增发生在哪些帧
  std::vector<uint32_t> framesToWait;   // 逐帧的 framesToWait
};

// 跑 frames 帧;curveFor(frame) 给出该帧生效的清晰度曲线(可随帧变,用来做
// 场景变化)。startLens 是第一帧之前镜头所在的位置。
Trace Run(PwAfScan* af, const std::function<Curve(int)>& curveFor, int frames,
          double startLens, double luma = 128.0,
          const std::function<double(int)>& lumaFor = nullptr) {
  Trace t;
  double lens = startLens;
  uint64_t lastSamples = 0;
  for (int i = 0; i < frames; ++i) {
    const Curve c = curveFor(i);
    PwAfFrame f;
    f.frameIndex = static_cast<uint64_t>(i);
    f.focusMeasure = c(lens);
    f.sceneLuma = lumaFor ? lumaFor(i) : luma;
    f.hasSceneLuma = true;
    const PwAfOutput out = af->Update(f);

    if (out.samplesConsumed != lastSamples) {
      t.sampleFrames.push_back(static_cast<uint64_t>(i));
      lastSamples = out.samplesConsumed;
    }
    t.framesToWait.push_back(out.framesToWait);
    if (out.retriggerRequested) {
      t.retriggers++;
    }
    if (out.scanFinished) {
      t.scanFinishes++;
      if (t.firstFinishFrame < 0) {
        t.firstFinishFrame = i;
      }
    }
    if (out.lensValid) {
      lens = out.lensTarget;
    }
    t.finalState = out.state;
    t.finalLens = lens;
    t.samples = out.samplesConsumed;
  }
  return t;
}

PwAfConfig MacroConfig() {
  PwAfConfig cfg = PwAfDefaultConfig();
  return cfg;
}

// ———————————————————————————————————————————————————————————————————————
// 1. 单峰:收敛到峰,判 Focused。
// ———————————————————————————————————————————————————————————————————————
void TestSinglePeakConvergesToPeak() {
  PwAfScan af(MacroConfig());
  af.SetRange(PwAfRange::Macro);   // 3–15 屈光度 = 33–6.7 cm
  af.SetSpeed(PwAfSpeed::Normal);
  af.SetMode(PwAfMode::Auto);
  af.TriggerScan();                // 「快门瞬间对焦」的那条路径

  const Curve c = Peak(10.0, 100.0, 8.0, 0.7);  // 峰在 8 屈光度 = 12.5 cm
  const Trace t = Run(&af, [&](int) { return c; }, 400, 15.0);

  CHECK(t.finalState == PwAfState::Focused);
  // macro 档 step_fine 已按景深重标为 0.175(D10),收敛精度应在一个细步内。
  CHECK(std::abs(t.finalLens - 8.0) <= 0.175);
  CHECK(t.scanFinishes == 1);
  CHECK(t.samples > 0);
  std::printf("  [单峰] 收敛到 %.4f 屈光度(真值 8.0),用了 %llu 次采样、"
              "%d 帧落判\n",
              t.finalLens, static_cast<unsigned long long>(t.samples),
              t.firstFinishFrame);
}

// ———————————————————————————————————————————————————————————————————————
// 2. 双峰:近焦优先 ⇒ 取**最近**的峰,哪怕远处那个更高。
//    并给出阴性对照:关掉 macroFirst 就会落到远峰上 ⇒ 证明这条是承重的。
// ———————————————————————————————————————————————————————————————————————
void TestTwoPeaksPicksNearest() {
  // 近峰 8 屈光度(12.5 cm)幅值 100;远峰 4 屈光度(25 cm)幅值 140(更高)。
  const Curve c = TwoPeaks(10.0, 100.0, 8.0, 140.0, 4.0, 0.7);

  {
    PwAfConfig cfg = MacroConfig();
    CHECK(cfg.macroFirst);  // 默认就是近焦优先
    PwAfScan af(cfg);
    af.SetRange(PwAfRange::Macro);
    af.SetMode(PwAfMode::Auto);
    af.TriggerScan();
    const Trace t = Run(&af, [&](int) { return c; }, 400, 15.0);
    CHECK(t.finalState == PwAfState::Focused);
    CHECK(std::abs(t.finalLens - 8.0) <= 0.175);   // 取了近峰
    CHECK(std::abs(t.finalLens - 4.0) > 1.0);      // 没被更高的远峰带走
    std::printf("  [双峰·近焦优先] 落在 %.4f(近峰 8.0,远峰 4.0 更高)\n",
                t.finalLens);
  }

  {
    // 阴性对照:macroFirst = false ⇒ 退回上游的起点选择(未初始化 ⇒ 从
    // focusMin 也就是远端起、向近扫),首峰即停会先撞上远处那个峰。
    PwAfConfig cfg = MacroConfig();
    cfg.macroFirst = false;
    PwAfScan af(cfg);
    af.SetRange(PwAfRange::Macro);
    af.SetMode(PwAfMode::Auto);
    af.TriggerScan();
    const Trace t = Run(&af, [&](int) { return c; }, 400, 3.0);
    CHECK(t.finalState == PwAfState::Focused);
    CHECK(std::abs(t.finalLens - 4.0) <= 0.175);   // 落到了远峰
    std::printf("  [双峰·阴性对照 macroFirst=false] 落在 %.4f(远峰 4.0)"
                " ⇒ 近焦优先这一条是承重的\n",
                t.finalLens);
  }
}

// ———————————————————————————————————————————————————————————————————————
// 3. 噪声下不振荡:连续模式、静止场景,一次扫描之后不再重扫。
// ———————————————————————————————————————————————————————————————————————
void TestNoisyCurveDoesNotOscillate() {
  PwAfScan af(MacroConfig());
  af.SetRange(PwAfRange::Macro);
  af.SetMode(PwAfMode::Continuous);  // 进入连续模式即触发首扫(af.cpp:935-936)

  // 确定性伪噪声(LCG),幅度 ±3%,保证可复现。
  uint32_t seed = 0x1234567u;
  auto noisy = [&](double d) {
    seed = seed * 1664525u + 1013904223u;
    const double u = static_cast<double>(seed >> 8) / 16777216.0;  // [0,1)
    const double base = Peak(10.0, 100.0, 8.0, 0.7)(d);
    return base * (1.0 + 0.06 * (u - 0.5));
  };

  const Trace t = Run(&af, [&](int) { return Curve(noisy); }, 1500, 15.0);

  CHECK(t.finalState == PwAfState::Focused);
  CHECK(std::abs(t.finalLens - 8.0) <= 0.5);
  // 静止场景 1500 帧(@30 fps = 50 s)内不应有任何重扫。
  // 判决书 §6.3 的通用判据是「同一静止场景 60 s 内扫描次数 ≤ 1」。
  CHECK(t.retriggers == 0);
  CHECK(t.scanFinishes == 1);
  std::printf("  [噪声 ±3%%] 落在 %.4f,1500 帧内重扫 %d 次、完成扫描 %d 次\n",
              t.finalLens, t.retriggers, t.scanFinishes);
}

// ———————————————————————————————————————————————————————————————————————
// 4. 场景变化触发重扫,且 retrigger_delay 的帧数正确;
//    阴性对照:把 retrigger_delay 调成 0 就会不停重扫 ⇒ 这道门是承重的。
// ———————————————————————————————————————————————————————————————————————
void TestSceneChangeRetriggersAfterDelay() {
  const Curve before = Peak(10.0, 100.0, 8.0, 0.7);
  // 变化后整条曲线降到 40%:在当前镜位上对比度 110 → 44,
  // 跌破 retrigger_ratio 0.8 的门(af.cpp:643-644)。
  const Curve after = Peak(4.0, 40.0, 8.0, 0.7);
  const int kChangeFrame = 600;

  {
    PwAfScan af(MacroConfig());
    af.SetRange(PwAfRange::Macro);
    af.SetMode(PwAfMode::Continuous);

    int retriggerFrame = -1;
    double lens = 15.0;
    uint32_t delaySeen = 0;
    for (int i = 0; i < 900; ++i) {
      PwAfFrame f;
      f.frameIndex = static_cast<uint64_t>(i);
      f.focusMeasure = (i < kChangeFrame ? before : after)(lens);
      f.sceneLuma = 128.0;
      f.hasSceneLuma = true;
      const PwAfOutput out = af.Update(f);
      if (out.retriggerRequested && retriggerFrame < 0) {
        retriggerFrame = i;
      }
      if (out.lensValid) {
        lens = out.lensTarget;
      }
    }
    (void)delaySeen;
    CHECK(retriggerFrame >= 0);
    // 变化帧记为第 1 帧,retrigger_delay = 10 ⇒ 第 10 帧落下重扫
    // (af.cpp:651-657:变化帧置 count=1,其后每稳一帧 +1,>= delay 即重扫)。
    CHECK(retriggerFrame == kChangeFrame + 9);
    std::printf("  [场景变化] 第 %d 帧变化,第 %d 帧重扫(retrigger_delay=10,"
                "实测间隔 %d 帧)\n",
                kChangeFrame, retriggerFrame, retriggerFrame - kChangeFrame + 1);
  }

  {
    // 阴性对照:retrigger_delay = 0(判决书 §6.3 指定的对照)。
    PwAfConfig cfg = MacroConfig();
    for (int s = 0; s < static_cast<int>(PwAfSpeed::Max); ++s) {
      cfg.speeds[s].retriggerDelay = 0;
    }
    PwAfScan af(cfg);
    af.SetRange(PwAfRange::Macro);
    af.SetMode(PwAfMode::Continuous);
    const Trace t = Run(&af, [&](int) { return before; }, 900, 15.0);
    // 把门拆掉之后,静止场景也会被反复重扫。
    CHECK(t.retriggers >= 2);
    std::printf("  [阴性对照 retrigger_delay=0] 同一静止场景 900 帧重扫 %d 次"
                " ⇒ 这道门是承重的\n",
                t.retriggers);
  }
}

// ———————————————————————————————————————————————————————————————————————
// 5. step_frames 的等待模型:每消费一次度量之后,要等满 step_frames 帧。
// ———————————————————————————————————————————————————————————————————————
void TestStepFramesWaitModel() {
  PwAfConfig cfg = MacroConfig();
  const uint32_t stepFrames =
      cfg.speeds[static_cast<int>(PwAfSpeed::Normal)].stepFrames;
  CHECK(stepFrames == 5);  // imx708.json speeds.normal.step_frames

  PwAfScan af(cfg);
  af.SetRange(PwAfRange::Macro);
  af.SetMode(PwAfMode::Auto);
  af.TriggerScan();

  const Curve c = Peak(10.0, 100.0, 8.0, 0.7);
  const Trace t = Run(&af, [&](int) { return c; }, 400, 15.0);

  CHECK(t.sampleFrames.size() >= 6);
  // 首次采样:skip_frames(5)+ step_frames(5)之后,即第 10 帧。
  CHECK(t.sampleFrames[0] == static_cast<uint64_t>(cfg.skipFrames + stepFrames));
  // 粗扫期间每步间隔 = step_frames + 1(1 帧用来消费度量并下发新位置)。
  for (size_t i = 1; i < 6; ++i) {
    CHECK(t.sampleFrames[i] - t.sampleFrames[i - 1] ==
          static_cast<uint64_t>(stepFrames + 1));
  }
  // 消费度量那一帧吐出的 framesToWait 应等于 step_frames,随后逐帧递减到 0。
  const size_t k = static_cast<size_t>(t.sampleFrames[1]);
  CHECK(t.framesToWait[k] == stepFrames);
  for (uint32_t d = 1; d <= stepFrames; ++d) {
    CHECK(t.framesToWait[k + d] == stepFrames - d);
  }
  std::printf("  [step_frames] 首采样在第 %llu 帧,步间隔 %llu 帧,"
              "framesToWait 从 %u 递减到 0\n",
              static_cast<unsigned long long>(t.sampleFrames[0]),
              static_cast<unsigned long long>(t.sampleFrames[1] -
                                              t.sampleFrames[0]),
              stepFrames);
}

// ———————————————————————————————————————————————————————————————————————
// 6. 平坦场景(没有峰)老实报 Failed,不硬报成功(af.cpp:668-673)。
// ———————————————————————————————————————————————————————————————————————
void TestFlatSceneReportsFailed() {
  PwAfScan af(MacroConfig());
  af.SetRange(PwAfRange::Macro);
  af.SetMode(PwAfMode::Auto);
  af.TriggerScan();

  const Trace t = Run(&af, [](int) { return Curve([](double) { return 100.0; }); },
                      900, 15.0);
  CHECK(t.finalState == PwAfState::Failed);
  CHECK(t.scanFinishes == 1);
  std::printf("  [平坦场景] 判 Failed(峰不够尖就不报成功)\n");
}

// ———————————————————————————————————————————————————————————————————————
// 7. macro 档的 step_fine 覆盖生效(D10 / D15),且不推翻 fast 档的「不细扫」。
// ———————————————————————————————————————————————————————————————————————
void TestMacroStepFineOverride() {
  const PwAfConfig cfg = MacroConfig();
  const int macro = static_cast<int>(PwAfRange::Macro);
  const int normal = static_cast<int>(PwAfRange::Normal);
  CHECK(cfg.ranges[macro].stepFineOverride == 0.175);
  CHECK(cfg.ranges[normal].stepFineOverride < 0.0);  // normal 不覆盖
  CHECK(cfg.speeds[static_cast<int>(PwAfSpeed::Normal)].stepFine == 0.25);
  CHECK(cfg.speeds[static_cast<int>(PwAfSpeed::Fast)].stepFine == 0.0);

  // fast 档 + macro range:step_fine 仍应是 0(跳过细扫)⇒ 粗扫找到峰后
  // 直接 Settle,采样次数明显少于 normal 档。
  PwAfScan fast(cfg);
  fast.SetRange(PwAfRange::Macro);
  fast.SetSpeed(PwAfSpeed::Fast);
  fast.SetMode(PwAfMode::Auto);
  fast.TriggerScan();
  const Curve c = Peak(10.0, 100.0, 8.0, 0.7);
  const Trace tf = Run(&fast, [&](int) { return c; }, 400, 15.0);

  PwAfScan slow(cfg);
  slow.SetRange(PwAfRange::Macro);
  slow.SetSpeed(PwAfSpeed::Normal);
  slow.SetMode(PwAfMode::Auto);
  slow.TriggerScan();
  const Trace ts = Run(&slow, [&](int) { return c; }, 400, 15.0);

  CHECK(tf.samples < ts.samples);  // fast 少了 3 次细扫采样
  std::printf("  [step_fine 覆盖] macro=0.175(上游 0.25);"
              "fast 档仍不细扫(采样 %llu vs normal %llu)\n",
              static_cast<unsigned long long>(tf.samples),
              static_cast<unsigned long long>(ts.samples));
}

// ———————————————————————————————————————————————————————————————————————
// 8. 手动定位与限位(af.cpp:882-904),以及快门路径要用的 Pause。
// ———————————————————————————————————————————————————————————————————————
void TestManualPositionAndLimits() {
  PwAfScan af(MacroConfig());
  double lo = -1.0, hi = -1.0;
  af.GetLensLimits(&lo, &hi);
  CHECK(lo == 0.0 && hi == 15.0);  // 上游 map 的定义域 [0, 15]
  CHECK(af.GetDefaultLensPosition() == 1.0);  // ranges.normal.default

  double pos = 0.0;
  CHECK(!af.GetLensPosition(&pos));  // 未初始化

  CHECK(af.SetLensPosition(7.0));    // Manual 模式下生效
  CHECK(af.GetLensPosition(&pos));
  CHECK(pos == 7.0);

  // 超出定义域要钳位(af.cpp:895)。
  af.SetLensPosition(99.0);
  CHECK(af.GetLensPosition(&pos));
  // maxSlew 每帧 1.5 ⇒ 一次只走 1.5。
  CHECK(pos == 8.5);

  // Manual 模式下上报恒为 Idle(af.cpp:815-816)。
  PwAfFrame f;
  f.focusMeasure = 100.0;
  const PwAfOutput out = af.Update(f);
  CHECK(out.state == PwAfState::Idle);
  CHECK(out.lensValid);
  std::printf("  [手动定位] 限位 [%.1f, %.1f]、钳位与 maxSlew 均生效\n", lo, hi);
}

}  // namespace

int main() {
  std::printf("pw_af_scan_test\n");
  TestSinglePeakConvergesToPeak();
  TestTwoPeaksPicksNearest();
  TestNoisyCurveDoesNotOscillate();
  TestSceneChangeRetriggersAfterDelay();
  TestStepFramesWaitModel();
  TestFlatSceneReportsFailed();
  TestMacroStepFineOverride();
  TestManualPositionAndLimits();
  std::printf("pw_af_scan_test: ALL PASS\n");
  return 0;
}
