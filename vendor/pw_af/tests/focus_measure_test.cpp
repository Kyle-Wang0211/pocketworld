// pw_af 焦点度量单测 + 耗时测量。
//
// 耗时那一段要在 Release / -O2 下跑才有意义(本机 CMakeLists 默认让调用方传
// CMAKE_BUILD_TYPE)。打印的数字是**本机 macOS arm64 的 CPU 耗时**,不是手机上
// 的耗时 —— 它只回答「纯 C++ 这条路到底贵不贵、要不要上 GPU」这一个问题
// (focus_measure.h 的偏离 F1)。

#include "focus_measure.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <vector>

namespace {

using pw_af::PwAfClampRoi;
using pw_af::PwAfDefaultRoi;
using pw_af::PwAfFocusMeasure;
using pw_af::PwAfRect;
using pw_af::PwFocusOperator;

void Check(bool condition, const char* expression, int line) {
  if (!condition) {
    std::cerr << "CHECK failed at line " << line << ": " << expression << '\n';
    std::exit(1);
  }
}

#define CHECK(expression) Check((expression), #expression, __LINE__)

struct Image {
  int width = 0;
  int height = 0;
  int stride = 0;
  std::vector<uint8_t> data;

  Image(int w, int h) : width(w), height(h), stride(w), data(
      static_cast<size_t>(w) * static_cast<size_t>(h), 0) {}

  uint8_t& At(int x, int y) {
    return data[static_cast<size_t>(y) * stride + x];
  }
  const uint8_t* Ptr() const { return data.data(); }
};

// 在 rect 内画黑白竖条纹(条宽 period/2)—— 一个有确定边缘密度的测试图案。
void DrawStripes(Image* img, const PwAfRect& rect, int period, uint8_t lo,
                 uint8_t hi) {
  for (int y = rect.y; y < rect.y + rect.height; ++y) {
    if (y < 0 || y >= img->height) continue;
    for (int x = rect.x; x < rect.x + rect.width; ++x) {
      if (x < 0 || x >= img->width) continue;
      img->At(x, y) = ((x / (period / 2)) % 2 == 0) ? lo : hi;
    }
  }
}

// 可分离的盒式模糊,radius 次数越大越糊。radius = 0 时原样返回。
Image BoxBlur(const Image& src, int radius) {
  Image out(src.width, src.height);
  out.data = src.data;
  if (radius <= 0) {
    return out;
  }
  Image tmp(src.width, src.height);
  // 横向
  for (int y = 0; y < src.height; ++y) {
    for (int x = 0; x < src.width; ++x) {
      int sum = 0, n = 0;
      for (int k = -radius; k <= radius; ++k) {
        const int xx = x + k;
        if (xx < 0 || xx >= src.width) continue;
        sum += out.data[static_cast<size_t>(y) * out.stride + xx];
        n++;
      }
      tmp.data[static_cast<size_t>(y) * tmp.stride + x] =
          static_cast<uint8_t>(sum / n);
    }
  }
  // 纵向
  for (int y = 0; y < src.height; ++y) {
    for (int x = 0; x < src.width; ++x) {
      int sum = 0, n = 0;
      for (int k = -radius; k <= radius; ++k) {
        const int yy = y + k;
        if (yy < 0 || yy >= src.height) continue;
        sum += tmp.data[static_cast<size_t>(yy) * tmp.stride + x];
        n++;
      }
      out.data[static_cast<size_t>(y) * out.stride + x] =
          static_cast<uint8_t>(sum / n);
    }
  }
  return out;
}

// ———————————————————————————————————————————————————————————————————————
// 1. 模糊阶梯:度量必须随模糊单调下降(两个算子都要)。
// ———————————————————————————————————————————————————————————————————————
void TestMeasureDecreasesMonotonicallyWithBlur() {
  const int kW = 640, kH = 480;
  Image sharp(kW, kH);
  DrawStripes(&sharp, PwAfRect{0, 0, kW, kH}, 16, 20, 235);

  const PwAfRect roi = PwAfDefaultRoi(kW, kH);
  const PwFocusOperator ops[] = {PwFocusOperator::Tenengrad,
                                 PwFocusOperator::SquaredGradient};
  const char* names[] = {"Tenengrad", "SquaredGradient"};

  for (int o = 0; o < 2; ++o) {
    double previous = 1e300;
    std::printf("  [模糊阶梯·%s] ", names[o]);
    for (int radius = 0; radius <= 5; ++radius) {
      const Image blurred = BoxBlur(sharp, radius);
      const double m = PwAfFocusMeasure(blurred.Ptr(), kW, kH, blurred.stride,
                                        roi, ops[o], nullptr);
      std::printf("r=%d:%.0f ", radius, m);
      CHECK(m < previous);  // 严格单调下降
      previous = m;
    }
    std::printf("\n");
  }
}

// ———————————————————————————————————————————————————————————————————————
// 2. ROI 只看框内:框外放一个高对比干扰物,度量不许被带偏。
//    (判决书 §2.4 / §6.3 的 ROI 策略必须能自证。)
// ———————————————————————————————————————————————————————————————————————
void TestRoiIgnoresOutsideDistractor() {
  const int kW = 640, kH = 480;
  const PwAfRect roi{200, 180, 160, 120};  // 画面中央偏左的"被拍物体"框

  // 只在 ROI 内画一个中等对比的物体,其余全灰。
  Image base(kW, kH);
  for (auto& p : base.data) p = 128;
  DrawStripes(&base, roi, 16, 90, 166);

  const double before = PwAfFocusMeasure(base.Ptr(), kW, kH, base.stride, roi,
                                         PwFocusOperator::Tenengrad, nullptr);

  // 在 ROI **外面**放一个极高对比的干扰物(黑白 2 像素条纹,满幅值)。
  // 条宽用 2 px 不用 1 px —— 见下面 TestSobelNyquistBlindSpot:1 px 条纹正好
  // 落在 3×3 Sobel 的盲区上,当不了"强干扰物"。
  Image withDistractor = base;
  DrawStripes(&withDistractor, PwAfRect{420, 60, 200, 360}, 4, 0, 255);

  const double after =
      PwAfFocusMeasure(withDistractor.Ptr(), kW, kH, withDistractor.stride, roi,
                       PwFocusOperator::Tenengrad, nullptr);
  CHECK(before == after);  // 逐位相同 —— 框外的东西一个像素都没进来

  // 阴性对照:同一张图按**全画面**算,干扰物会把度量拉高一大截 ⇒ 证明
  // 「ROI 起作用了」不是因为干扰物本身不够强。
  const PwAfRect full{0, 0, kW, kH};
  const double fullBefore = PwAfFocusMeasure(
      base.Ptr(), kW, kH, base.stride, full, PwFocusOperator::Tenengrad,
      nullptr);
  const double fullAfter = PwAfFocusMeasure(
      withDistractor.Ptr(), kW, kH, withDistractor.stride, full,
      PwFocusOperator::Tenengrad, nullptr);
  CHECK(fullAfter > fullBefore * 5.0);

  std::printf("  [ROI 隔离] 框内度量 %.1f → %.1f(逐位不变);"
              "同图全画面 %.1f → %.1f(被干扰物拉高 %.1f 倍)\n",
              before, after, fullBefore, fullAfter, fullAfter / fullBefore);
}

// ———————————————————————————————————————————————————————————————————————
// 2b. 🔴 已知局限:3×3 Sobel 在奈奎斯特频率(1 像素条纹)上是**盲**的 ——
//     gx 取的是 x−1 与 x+1,两者同奇偶 ⇒ 逐像素交替的图案 gx 恒为 0。
//     后果:一个对得**极准**、细节正好落在 1 px 周期上的画面,Tenengrad 反而
//     读得低。本测试把这条钉死,免得日后当成 bug 去"修"。
//     SquaredGradient 用的是相邻差分,没有这个盲区 ⇒ 两个算子互为补充。
//     🔴 这条是本刀发现的**算子性质**,不是判决书里的结论;它对
//        「拍高频纹理小物体」这一档的影响未验证,留给台架。
// ———————————————————————————————————————————————————————————————————————
void TestSobelNyquistBlindSpot() {
  const int kW = 256, kH = 256;
  const PwAfRect full{0, 0, kW, kH};

  Image nyquist(kW, kH);   // 1 px 条纹(周期 2)
  DrawStripes(&nyquist, full, 2, 0, 255);
  Image twoPx(kW, kH);     // 2 px 条纹(周期 4)
  DrawStripes(&twoPx, full, 4, 0, 255);

  const double tenNyq = PwAfFocusMeasure(nyquist.Ptr(), kW, kH, nyquist.stride,
                                         full, PwFocusOperator::Tenengrad,
                                         nullptr);
  const double tenTwo = PwAfFocusMeasure(twoPx.Ptr(), kW, kH, twoPx.stride,
                                         full, PwFocusOperator::Tenengrad,
                                         nullptr);
  const double sqNyq = PwAfFocusMeasure(nyquist.Ptr(), kW, kH, nyquist.stride,
                                        full, PwFocusOperator::SquaredGradient,
                                        nullptr);
  const double sqTwo = PwAfFocusMeasure(twoPx.Ptr(), kW, kH, twoPx.stride, full,
                                        PwFocusOperator::SquaredGradient,
                                        nullptr);

  // Tenengrad:同样满幅值,1 px 条纹反而远低于 2 px 条纹。
  CHECK(tenNyq < tenTwo * 0.5);
  // SquaredGradient:1 px 条纹是它的**最高**频,不低于 2 px。
  CHECK(sqNyq >= sqTwo);
  std::printf("  [Sobel 奈奎斯特盲区] Tenengrad 1px=%.0f < 2px=%.0f;"
              " SquaredGradient 1px=%.0f >= 2px=%.0f\n",
              tenNyq, tenTwo, sqNyq, sqTwo);
}

// ———————————————————————————————————————————————————————————————————————
// 3. 默认 ROI = 上游 af.cpp:313-321 的「中 1/2 宽 × 中 1/3 高」。
// ———————————————————————————————————————————————————————————————————————
void TestDefaultRoiMatchesUpstreamShape() {
  const PwAfRect r = PwAfDefaultRoi(1920, 1440);
  CHECK(r.x == 480 && r.width == 960);   // 中 1/2 宽
  CHECK(r.y == 480 && r.height == 480);  // 中 1/3 高
  std::printf("  [默认 ROI] %dx%d @ (%d,%d) —— 中 1/2 宽 × 中 1/3 高\n",
              r.width, r.height, r.x, r.y);
}

// ———————————————————————————————————————————————————————————————————————
// 4. 边界与退化输入。
// ———————————————————————————————————————————————————————————————————————
void TestBoundsAndDegenerateInputs() {
  const int kW = 64, kH = 48;
  Image img(kW, kH);
  DrawStripes(&img, PwAfRect{0, 0, kW, kH}, 8, 0, 255);

  // null / 非法尺寸 / stride 太小 ⇒ 0.0,不崩。
  CHECK(PwAfFocusMeasure(nullptr, kW, kH, kW, PwAfRect{0, 0, kW, kH},
                         PwFocusOperator::Tenengrad, nullptr) == 0.0);
  CHECK(PwAfFocusMeasure(img.Ptr(), 0, kH, kW, PwAfRect{0, 0, kW, kH},
                         PwFocusOperator::Tenengrad, nullptr) == 0.0);
  CHECK(PwAfFocusMeasure(img.Ptr(), kW, kH, kW - 1, PwAfRect{0, 0, kW, kH},
                         PwFocusOperator::Tenengrad, nullptr) == 0.0);

  // ROI 完全在画外 ⇒ 0.0。
  CHECK(PwAfFocusMeasure(img.Ptr(), kW, kH, kW, PwAfRect{1000, 1000, 10, 10},
                         PwFocusOperator::Tenengrad, nullptr) == 0.0);

  // ROI 跨界会被裁到画内,且留出算子余量。
  PwAfRect clamped;
  CHECK(PwAfClampRoi(PwAfRect{-10, -10, kW + 40, kH + 40}, kW, kH,
                     PwFocusOperator::Tenengrad, &clamped));
  CHECK(clamped.x == 1 && clamped.y == 1);
  CHECK(clamped.width == kW - 2 && clamped.height == kH - 2);

  // meanLuma 回填正确:全 200 的图,ROI 均值就是 200。
  Image flat(kW, kH);
  for (auto& p : flat.data) p = 200;
  double luma = -1.0;
  const double m = PwAfFocusMeasure(flat.Ptr(), kW, kH, kW,
                                    PwAfRect{0, 0, kW, kH},
                                    PwFocusOperator::Tenengrad, &luma);
  CHECK(m == 0.0);       // 全平 ⇒ 梯度为零
  CHECK(luma == 200.0);
  std::printf("  [边界] null/非法尺寸/画外 ROI 全返 0;裁剪与 meanLuma 正确\n");
}

// ———————————————————————————————————————————————————————————————————————
// 5. 耗时:1920×1440 全图 与 典型 ROI。给「要不要上 GPU」留数据(偏离 F1)。
// ———————————————————————————————————————————————————————————————————————
void TestTimingFullFrameAndRoi() {
  const int kW = 1920, kH = 1440;  // 判决书口径的喂料尺寸
  Image img(kW, kH);
  // 用伪随机纹理,避免编译器对规则图案做出不真实的优化。
  uint32_t seed = 0xA5A5A5A5u;
  for (auto& p : img.data) {
    seed = seed * 1664525u + 1013904223u;
    p = static_cast<uint8_t>(seed >> 24);
  }

  struct Case {
    const char* name;
    PwAfRect roi;
  };
  const PwAfRect fullRoi{0, 0, kW, kH};
  const PwAfRect defaultRoi = PwAfDefaultRoi(kW, kH);          // 960×480
  const PwAfRect subjectRoi{760, 560, 400, 320};               // 典型主体框
  const Case cases[] = {
      {"全图 1920x1440", fullRoi},
      {"默认窗 960x480 (中1/2宽×中1/3高)", defaultRoi},
      {"典型主体框 400x320", subjectRoi},
  };
  const PwFocusOperator ops[] = {PwFocusOperator::Tenengrad,
                                 PwFocusOperator::SquaredGradient};
  const char* opNames[] = {"Tenengrad", "SquaredGradient"};

  std::printf("  [耗时] 本机 CPU 单线程,每项取 %d 次的中位数;"
              "🔴 不是手机上的耗时\n", 9);
  for (int o = 0; o < 2; ++o) {
    for (const Case& c : cases) {
      std::vector<double> us;
      double sink = 0.0;
      for (int rep = 0; rep < 9; ++rep) {
        const auto t0 = std::chrono::steady_clock::now();
        sink += PwAfFocusMeasure(img.Ptr(), kW, kH, img.stride, c.roi, ops[o],
                                 nullptr);
        const auto t1 = std::chrono::steady_clock::now();
        us.push_back(
            std::chrono::duration<double, std::micro>(t1 - t0).count());
      }
      std::sort(us.begin(), us.end());
      const double median = us[us.size() / 2];
      const int64_t pixels =
          static_cast<int64_t>(c.roi.width) * c.roi.height;
      std::printf("    %-15s %-38s %8.1f us  (%.2f ns/px)\n", opNames[o],
                  c.name, median,
                  median * 1000.0 / static_cast<double>(pixels));
      CHECK(sink >= 0.0);  // 防止整段被优化掉
    }
  }
}

}  // namespace

int main() {
  std::printf("pw_af_focus_measure_test\n");
  TestMeasureDecreasesMonotonicallyWithBlur();
  TestRoiIgnoresOutsideDistractor();
  TestSobelNyquistBlindSpot();
  TestDefaultRoiMatchesUpstreamShape();
  TestBoundsAndDegenerateInputs();
  TestTimingFullFrameAndRoi();
  std::printf("pw_af_focus_measure_test: ALL PASS\n");
  return 0;
}
