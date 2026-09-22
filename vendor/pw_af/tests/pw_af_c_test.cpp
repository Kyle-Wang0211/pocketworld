// pw_af C ABI 门面的单测。风格与同目录另外三个一致(无框架 + CHECK 宏)。
//
// 这一份只测**门面自己新增的那点东西**,算法本身由另外三个测试覆盖:
//   ① 枚举值 C 镜像与 C++ enum class 一致(编译期 static_assert 在实现里,
//      这里再跑一遍运行期对照,免得有人只改头文件);
//   ② BGRA 路与灰度路**逐位相同** —— 这是三臂可比的前提(任务书「最上游
//      输入必须清晰」:度量口径三臂完全一致);
//   ③ 不透明指针的生命周期与空参防御;
//   ④ 状态机能从 C 侧驱起来:TriggerScan → Scanning → Focused。

#include "pw_af_c.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <iostream>
#include <vector>

#include "af_scan.h"
#include "focus_measure.h"

namespace {

void Check(bool condition, const char* expression, int line) {
  if (!condition) {
    std::cerr << "CHECK failed at line " << line << ": " << expression << '\n';
    std::exit(1);
  }
}

#define CHECK(expression) Check((expression), #expression, __LINE__)

// 确定性伪随机(不用 <random>,免得跨实现不同)。
uint32_t NextRand(uint32_t* s) {
  *s = *s * 1664525u + 1013904223u;
  return *s;
}

struct GrayImage {
  int width = 0;
  int height = 0;
  int stride = 0;
  std::vector<uint8_t> data;
};

GrayImage MakeNoisyGray(int width, int height, uint32_t seed) {
  GrayImage img;
  img.width = width;
  img.height = height;
  img.stride = width + 7;  // 刻意非紧凑,顺带测 stride
  img.data.assign(static_cast<size_t>(img.stride) * height, 0);
  uint32_t s = seed;
  for (int y = 0; y < height; ++y) {
    for (int x = 0; x < width; ++x) {
      img.data[static_cast<size_t>(y) * img.stride + x] =
          static_cast<uint8_t>(NextRand(&s) >> 24);
    }
  }
  return img;
}

// 把灰度图铺成 32BGRA(B=G=R=v)。定点式 (77v+150v+29v+128)>>8 == v,
// 所以转回来必须逐位相等 —— 这正是 ② 要钉的。
std::vector<uint8_t> GrayToBgra(const GrayImage& g, int* strideOut) {
  const int stride = g.width * 4 + 12;  // 同样刻意非紧凑
  *strideOut = stride;
  std::vector<uint8_t> out(static_cast<size_t>(stride) * g.height, 0);
  for (int y = 0; y < g.height; ++y) {
    for (int x = 0; x < g.width; ++x) {
      const uint8_t v = g.data[static_cast<size_t>(y) * g.stride + x];
      uint8_t* p = out.data() + static_cast<size_t>(y) * stride + x * 4;
      p[0] = v;  // B
      p[1] = v;  // G
      p[2] = v;  // R
      p[3] = 255;
    }
  }
  return out;
}

void TestEnumMirror() {
  CHECK(static_cast<int>(pw_af::PwAfRange::Macro) == PW_AF_RANGE_MACRO);
  CHECK(static_cast<int>(pw_af::PwAfMode::Continuous) == PW_AF_MODE_CONTINUOUS);
  CHECK(static_cast<int>(pw_af::PwAfState::Focused) == PW_AF_STATE_FOCUSED);
  CHECK(static_cast<int>(pw_af::PwAfState::Failed) == PW_AF_STATE_FAILED);
  CHECK(static_cast<int>(pw_af::PwAfPause::Deferred) == PW_AF_PAUSE_DEFERRED);
  CHECK(static_cast<int>(pw_af::PwFocusOperator::SquaredGradient) ==
        PW_AF_OP_SQUARED_GRADIENT);
}

void TestDefaultRoi() {
  PwAfRectC c{};
  CHECK(PwAfDefaultRoiC(1920, 1440, &c) == PW_AF_OK);
  const pw_af::PwAfRect cpp = pw_af::PwAfDefaultRoi(1920, 1440);
  CHECK(c.x == cpp.x && c.y == cpp.y);
  CHECK(c.width == cpp.width && c.height == cpp.height);
  // 上游默认窗:中 1/2 宽 × 中 1/3 高。
  CHECK(c.x == 480 && c.width == 960);
  CHECK(c.y == 480 && c.height == 480);
  CHECK(PwAfDefaultRoiC(0, 0, &c) == PW_AF_ERR_INVALID_ARGUMENT);
  CHECK(PwAfDefaultRoiC(1920, 1440, nullptr) == PW_AF_ERR_INVALID_ARGUMENT);
}

// ② 三臂可比的承重测试:同一张图,BGRA 路与灰度路必须给出**同一个 double**。
void TestBgraMatchesGrayBitExact() {
  PwAfContext* ctx = PwAfCreate(PW_AF_RANGE_MACRO, 0, 0);
  CHECK(ctx != nullptr);

  const GrayImage g = MakeNoisyGray(160, 120, 0x5EED1234u);
  int bgraStride = 0;
  const std::vector<uint8_t> bgra = GrayToBgra(g, &bgraStride);

  // 覆盖四种 ROI 位置:图心、贴左上角、贴右下角、超出边界。
  const PwAfRectC rois[] = {
      {40, 30, 80, 60},
      {0, 0, 50, 40},
      {110, 80, 50, 40},
      {-10, -10, 200, 200},
  };
  const int ops[] = {PW_AF_OP_TENENGRAD, PW_AF_OP_SQUARED_GRADIENT};

  for (const PwAfRectC& roi : rois) {
    for (int op : ops) {
      double mGray = -1, lGray = -1, mBgra = -1, lBgra = -1;
      const int32_t rcG =
          PwAfMeasureGray(ctx, g.data.data(), g.width, g.height, g.stride, &roi,
                          op, &mGray, &lGray);
      const int32_t rcB = PwAfMeasureBgra(ctx, bgra.data(), g.width, g.height,
                                          bgraStride, &roi, op, &mBgra, &lBgra);
      CHECK(rcG == PW_AF_OK);
      CHECK(rcB == PW_AF_OK);
      CHECK(mGray > 0.0);
      // 逐位 —— 不是「接近」。两条路都是整数累加后一次除法。
      CHECK(mBgra == mGray);
      CHECK(lBgra == lGray);
    }
  }

  // 空交集:ROI 完全在图外。
  const PwAfRectC outside{500, 500, 10, 10};
  double m = -1, l = -1;
  CHECK(PwAfMeasureBgra(ctx, bgra.data(), g.width, g.height, bgraStride,
                        &outside, PW_AF_OP_TENENGRAD, &m, &l) ==
        PW_AF_ERR_NO_PIXELS);
  CHECK(m == 0.0 && l == 0.0);

  PwAfDestroy(ctx);
}

void TestNullDefence() {
  double m = 0;
  CHECK(PwAfMeasureGray(nullptr, nullptr, 10, 10, 10, nullptr, 0, &m,
                        nullptr) == PW_AF_ERR_INVALID_ARGUMENT);
  CHECK(PwAfMeasureBgra(nullptr, nullptr, 10, 10, 40, nullptr, 0, &m,
                        nullptr) == PW_AF_ERR_INVALID_ARGUMENT);
  CHECK(PwAfSetRange(nullptr, PW_AF_RANGE_MACRO) == PW_AF_ERR_INVALID_ARGUMENT);
  CHECK(PwAfSetSpeed(nullptr, PW_AF_SPEED_NORMAL) == PW_AF_ERR_INVALID_ARGUMENT);
  CHECK(PwAfSetMode(nullptr, PW_AF_MODE_AUTO) == PW_AF_ERR_INVALID_ARGUMENT);
  CHECK(PwAfTriggerScan(nullptr) == PW_AF_ERR_INVALID_ARGUMENT);
  CHECK(PwAfCancelScan(nullptr) == PW_AF_ERR_INVALID_ARGUMENT);
  CHECK(PwAfPause(nullptr, PW_AF_PAUSE_RESUME) == PW_AF_ERR_INVALID_ARGUMENT);
  CHECK(PwAfNotifyModeSwitch(nullptr) == PW_AF_ERR_INVALID_ARGUMENT);
  CHECK(PwAfUpdate(nullptr, 0, 0, 0, 0, nullptr) == PW_AF_ERR_INVALID_ARGUMENT);
  CHECK(PwAfCreate(99, 0, 0) == nullptr);
  CHECK(PwAfCreate(-1, 0, 0) == nullptr);
  PwAfDestroy(nullptr);  // 不得崩
  double out = 0;
  CHECK(PwAfDefaultLensPlatform(nullptr, &out) == PW_AF_ERR_INVALID_ARGUMENT);
}

// ④ 从 C 侧把状态机驱到 Focused。度量用一条单峰曲线(与 af_scan_test 同形:
//    contrast 是镜位的函数),峰放在 macro 区间中部。
void TestDriveToFocusedFromC() {
  PwAfContext* ctx = PwAfCreate(PW_AF_RANGE_MACRO, 0, 0);
  CHECK(ctx != nullptr);
  CHECK(PwAfSetMode(ctx, PW_AF_MODE_AUTO) == PW_AF_OK);
  CHECK(PwAfTriggerScan(ctx) == PW_AF_OK);

  const double peak = 8.0;  // 屈光度 ⇒ 12.5 cm
  PwAfSampleC s{};
  double lens = 0.0;
  bool sawScanning = false;
  int32_t finalState = PW_AF_STATE_IDLE;
  for (uint64_t i = 0; i < 4000; ++i) {
    const double d = lens - peak;
    const double contrast = 1000.0 / (1.0 + d * d);
    CHECK(PwAfUpdate(ctx, i, contrast, 120.0, 1, &s) == PW_AF_OK);
    if (s.lens_valid) lens = s.lens_internal;
    if (s.state == PW_AF_STATE_SCANNING) sawScanning = true;
    if (s.scan_finished) {
      finalState = s.state;
      break;
    }
  }
  CHECK(sawScanning);
  CHECK(finalState == PW_AF_STATE_FOCUSED);
  // 落点要在峰附近一个细扫步长(macro 档 0.175 屈光度)的几倍以内。
  CHECK(lens > peak - 1.0 && lens < peak + 1.0);

  // 平台单位:iOS lensPosition 0 = 最近、1 = 最远 ⇒ 与内部标度**反向**。
  const double nearPos = PwAfLensToPlatform(ctx, 15.0);
  const double farPos = PwAfLensToPlatform(ctx, 3.0);
  CHECK(nearPos < farPos);
  CHECK(nearPos >= 0.0 && farPos <= 1.0);
  // 往返。
  CHECK(PwAfLensFromPlatform(ctx, nearPos) > PwAfLensFromPlatform(ctx, farPos));

  double defPos = -1;
  CHECK(PwAfDefaultLensPlatform(ctx, &defPos) == PW_AF_OK);
  CHECK(defPos >= 0.0 && defPos <= 1.0);

  PwAfDestroy(ctx);
}

}  // namespace

int main() {
  TestEnumMirror();
  TestDefaultRoi();
  TestBgraMatchesGrayBitExact();
  TestNullDefence();
  TestDriveToFocusedFromC();
  std::printf("pw_af_c_test OK\n");
  return 0;
}
