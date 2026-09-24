// pw_af —— C ABI 门面的实现。出处、口径与偏离见 pw_af_c.h 的文件头。
//
// 本文件**不含任何对焦算法**:搜索在 af_scan.cpp、度量在 focus_measure.cpp、
// 单位换算在 lens_scale.cpp。这里只做三件事:
//   ① 把 C++ 对象藏进不透明指针;
//   ② 给跨线程调用加一把锁(相机回调线程 vs Dart isolate 线程);
//   ③ BGRA → 8 位灰度的 ROI 裁剪拷贝(ITU-R BT.601 亮度系数,见头文件)。

#include "pw_af_c.h"

#include <mutex>
#include <new>
#include <vector>

#include "af_scan.h"
#include "focus_measure.h"
#include "lens_scale.h"

namespace {

using pw_af::PwAfConfig;
using pw_af::PwAfFrame;
using pw_af::PwAfOutput;
using pw_af::PwAfRect;
using pw_af::PwAfScan;
using pw_af::PwLensScale;

// 枚举值一致性:C 侧写死的数字与 C++ enum class 的取值必须逐一相等。
// 任何一边改了顺序,这里就编不过 —— 比运行期再发现便宜。
static_assert(static_cast<int>(pw_af::PwAfRange::Normal) == PW_AF_RANGE_NORMAL, "");
static_assert(static_cast<int>(pw_af::PwAfRange::Macro) == PW_AF_RANGE_MACRO, "");
static_assert(static_cast<int>(pw_af::PwAfRange::Full) == PW_AF_RANGE_FULL, "");
static_assert(static_cast<int>(pw_af::PwAfSpeed::Normal) == PW_AF_SPEED_NORMAL, "");
static_assert(static_cast<int>(pw_af::PwAfSpeed::Fast) == PW_AF_SPEED_FAST, "");
static_assert(static_cast<int>(pw_af::PwAfMode::Manual) == PW_AF_MODE_MANUAL, "");
static_assert(static_cast<int>(pw_af::PwAfMode::Auto) == PW_AF_MODE_AUTO, "");
static_assert(static_cast<int>(pw_af::PwAfMode::Continuous) == PW_AF_MODE_CONTINUOUS, "");
static_assert(static_cast<int>(pw_af::PwAfPause::Immediate) == PW_AF_PAUSE_IMMEDIATE, "");
static_assert(static_cast<int>(pw_af::PwAfPause::Deferred) == PW_AF_PAUSE_DEFERRED, "");
static_assert(static_cast<int>(pw_af::PwAfPause::Resume) == PW_AF_PAUSE_RESUME, "");
static_assert(static_cast<int>(pw_af::PwAfState::Idle) == PW_AF_STATE_IDLE, "");
static_assert(static_cast<int>(pw_af::PwAfState::Scanning) == PW_AF_STATE_SCANNING, "");
static_assert(static_cast<int>(pw_af::PwAfState::Focused) == PW_AF_STATE_FOCUSED, "");
static_assert(static_cast<int>(pw_af::PwAfState::Failed) == PW_AF_STATE_FAILED, "");
static_assert(static_cast<int>(pw_af::PwFocusOperator::Tenengrad) == PW_AF_OP_TENENGRAD, "");
static_assert(static_cast<int>(pw_af::PwFocusOperator::SquaredGradient) ==
                  PW_AF_OP_SQUARED_GRADIENT, "");

bool InRange(int32_t v, int32_t lo, int32_t hi) { return v >= lo && v <= hi; }

pw_af::PwFocusOperator OperatorOf(int32_t op) {
  return op == PW_AF_OP_SQUARED_GRADIENT ? pw_af::PwFocusOperator::SquaredGradient
                                         : pw_af::PwFocusOperator::Tenengrad;
}

}  // namespace

// 不透明类型的真身。头文件里只有前向声明。
struct PwAfContext {
  std::mutex mu;
  PwAfConfig cfg = pw_af::PwAfDefaultConfig();
  PwAfScan scan{cfg};
  PwLensScale lens;
  pw_af::PwAfRange range = pw_af::PwAfRange::Macro;
  // BGRA→灰度的 ROI 复用缓冲。只按需长大,不逐帧分配。
  std::vector<uint8_t> grayScratch;
};

int32_t PwAfDefaultRoiC(int32_t width, int32_t height, PwAfRectC *out) {
  if (out == nullptr) return PW_AF_ERR_INVALID_ARGUMENT;
  const PwAfRect r = pw_af::PwAfDefaultRoi(static_cast<int>(width),
                                           static_cast<int>(height));
  out->x = r.x;
  out->y = r.y;
  out->width = r.width;
  out->height = r.height;
  return (r.width > 0 && r.height > 0) ? PW_AF_OK : PW_AF_ERR_INVALID_ARGUMENT;
}

PwAfContext *PwAfCreate(int32_t range, double near_dioptre,
                        double far_dioptre) {
  if (!InRange(range, PW_AF_RANGE_NORMAL, PW_AF_RANGE_FULL)) return nullptr;
  PwAfContext *ctx = new (std::nothrow) PwAfContext();
  if (ctx == nullptr) return nullptr;
  ctx->range = static_cast<pw_af::PwAfRange>(range);
  ctx->scan.SetRange(ctx->range);
  const pw_af::PwAfRangeParams &rp = ctx->cfg.ranges[range];
  // 0/0 = 用该 range 自己的区间。near = focusMax(大=近)、far = focusMin。
  const double nearD = (near_dioptre > 0.0) ? near_dioptre : rp.focusMax;
  const double farD = (far_dioptre > 0.0) ? far_dioptre : rp.focusMin;
  ctx->lens = pw_af::PwAfMakeIosScale(nearD, farD);
  return ctx;
}

void PwAfDestroy(PwAfContext *ctx) { delete ctx; }

// ——— 度量 ———

int32_t PwAfMeasureGray(PwAfContext *ctx, const uint8_t *gray, int32_t width,
                        int32_t height, int32_t stride, const PwAfRectC *roi,
                        int32_t op, double *measure_out, double *luma_out) {
  (void)ctx;  // 灰度路不需要 scratch;保留形参是为了与 Bgra 版同形。
  if (gray == nullptr || roi == nullptr || measure_out == nullptr) {
    return PW_AF_ERR_INVALID_ARGUMENT;
  }
  if (width <= 0 || height <= 0 || stride < width) {
    return PW_AF_ERR_INVALID_ARGUMENT;
  }
  PwAfRect r;
  r.x = roi->x;
  r.y = roi->y;
  r.width = roi->width;
  r.height = roi->height;
  double luma = 0.0;
  const double m = pw_af::PwAfFocusMeasure(gray, width, height, stride, r,
                                           OperatorOf(op), &luma);
  *measure_out = m;
  if (luma_out != nullptr) *luma_out = luma;
  return PW_AF_OK;
}

int32_t PwAfMeasureBgra(PwAfContext *ctx, const uint8_t *bgra, int32_t width,
                        int32_t height, int32_t stride, const PwAfRectC *roi,
                        int32_t op, double *measure_out, double *luma_out) {
  if (ctx == nullptr || bgra == nullptr || roi == nullptr ||
      measure_out == nullptr) {
    return PW_AF_ERR_INVALID_ARGUMENT;
  }
  if (width <= 0 || height <= 0 || stride < width * 4) {
    return PW_AF_ERR_INVALID_ARGUMENT;
  }

  // ── 口径:**与灰度路逐位相同**,不是近似 ────────────────────────────
  // `PwAfFocusMeasure` 在整图上算时,ROI 边缘那一圈像素的 3×3 Sobel 会用到
  // ROI **外面**的邻居。所以这里不能只裁 ROI —— 裁 ROI 会让那一圈少了邻居。
  // 做法:裁 ROI **外扩 1 像素**(与图像边界求交),ROI 在裁出来的小图里用
  // 局部坐标表达。这样 `PwAfClampRoi` 的行为与整图一致(ROI 贴到图像边时两
  // 条路同样被图像边界挡住),度量逐位相等 —— 有单测钉住。
  int rx0 = roi->x < 0 ? 0 : roi->x;
  int ry0 = roi->y < 0 ? 0 : roi->y;
  int rx1 = roi->x + roi->width;
  int ry1 = roi->y + roi->height;
  if (rx1 > width) rx1 = width;
  if (ry1 > height) ry1 = height;
  if (rx0 >= rx1 || ry0 >= ry1) {
    *measure_out = 0.0;
    if (luma_out != nullptr) *luma_out = 0.0;
    return PW_AF_ERR_NO_PIXELS;
  }
  const int cx0 = (rx0 > 0) ? rx0 - 1 : 0;
  const int cy0 = (ry0 > 0) ? ry0 - 1 : 0;
  const int cx1 = (rx1 < width) ? rx1 + 1 : width;
  const int cy1 = (ry1 < height) ? ry1 + 1 : height;
  const int cw = cx1 - cx0;
  const int ch = cy1 - cy0;

  std::lock_guard<std::mutex> lock(ctx->mu);
  const size_t need = static_cast<size_t>(cw) * static_cast<size_t>(ch);
  if (ctx->grayScratch.size() < need) ctx->grayScratch.resize(need);
  uint8_t *dst = ctx->grayScratch.data();

  // ITU-R BT.601 亮度系数(见 pw_af_c.h 的文件头)。定点化:
  //   Y = (77·R + 150·G + 29·B + 128) >> 8
  // 77/256 = 0.3008、150/256 = 0.5859、29/256 = 0.1133 —— OpenCV
  // `cvtColor(COLOR_BGRA2GRAY)` 的 R2Y/G2Y/B2Y 缩到 8 位就是这三个数。
  // **整数运算** ⇒ 逐位可复现,不受 `-ffp-contract` 影响(这个代码库为
  // 1 ULP 的像素差栽过)。灰度三通道相等时该式恒等回原值:
  //   (77v + 150v + 29v + 128) >> 8 = (256v + 128) >> 8 = v。
  for (int y = 0; y < ch; ++y) {
    const uint8_t *src = bgra + static_cast<size_t>(cy0 + y) *
                                    static_cast<size_t>(stride) +
                         static_cast<size_t>(cx0) * 4u;
    uint8_t *row = dst + static_cast<size_t>(y) * static_cast<size_t>(cw);
    for (int x = 0; x < cw; ++x) {
      const uint32_t b = src[0];
      const uint32_t g = src[1];
      const uint32_t r = src[2];
      row[x] = static_cast<uint8_t>((77u * r + 150u * g + 29u * b + 128u) >> 8);
      src += 4;
    }
  }

  PwAfRect local;
  local.x = rx0 - cx0;
  local.y = ry0 - cy0;
  local.width = rx1 - rx0;
  local.height = ry1 - ry0;
  double luma = 0.0;
  const double m = pw_af::PwAfFocusMeasure(dst, cw, ch, cw, local,
                                           OperatorOf(op), &luma);
  *measure_out = m;
  if (luma_out != nullptr) *luma_out = luma;
  return PW_AF_OK;
}

// ——— 状态机 ———

int32_t PwAfSetRange(PwAfContext *ctx, int32_t range) {
  if (ctx == nullptr || !InRange(range, PW_AF_RANGE_NORMAL, PW_AF_RANGE_FULL)) {
    return PW_AF_ERR_INVALID_ARGUMENT;
  }
  std::lock_guard<std::mutex> lock(ctx->mu);
  ctx->range = static_cast<pw_af::PwAfRange>(range);
  ctx->scan.SetRange(ctx->range);
  return PW_AF_OK;
}

int32_t PwAfSetSpeed(PwAfContext *ctx, int32_t speed) {
  if (ctx == nullptr || !InRange(speed, PW_AF_SPEED_NORMAL, PW_AF_SPEED_FAST)) {
    return PW_AF_ERR_INVALID_ARGUMENT;
  }
  std::lock_guard<std::mutex> lock(ctx->mu);
  ctx->scan.SetSpeed(static_cast<pw_af::PwAfSpeed>(speed));
  return PW_AF_OK;
}

int32_t PwAfSetMode(PwAfContext *ctx, int32_t mode) {
  if (ctx == nullptr || !InRange(mode, PW_AF_MODE_MANUAL, PW_AF_MODE_CONTINUOUS)) {
    return PW_AF_ERR_INVALID_ARGUMENT;
  }
  std::lock_guard<std::mutex> lock(ctx->mu);
  ctx->scan.SetMode(static_cast<pw_af::PwAfMode>(mode));
  return PW_AF_OK;
}

int32_t PwAfTriggerScan(PwAfContext *ctx) {
  if (ctx == nullptr) return PW_AF_ERR_INVALID_ARGUMENT;
  std::lock_guard<std::mutex> lock(ctx->mu);
  ctx->scan.TriggerScan();
  return PW_AF_OK;
}

int32_t PwAfCancelScan(PwAfContext *ctx) {
  if (ctx == nullptr) return PW_AF_ERR_INVALID_ARGUMENT;
  std::lock_guard<std::mutex> lock(ctx->mu);
  ctx->scan.CancelScan();
  return PW_AF_OK;
}

int32_t PwAfPause(PwAfContext *ctx, int32_t pause) {
  if (ctx == nullptr ||
      !InRange(pause, PW_AF_PAUSE_IMMEDIATE, PW_AF_PAUSE_RESUME)) {
    return PW_AF_ERR_INVALID_ARGUMENT;
  }
  std::lock_guard<std::mutex> lock(ctx->mu);
  ctx->scan.Pause(static_cast<pw_af::PwAfPause>(pause));
  return PW_AF_OK;
}

int32_t PwAfNotifyModeSwitch(PwAfContext *ctx) {
  if (ctx == nullptr) return PW_AF_ERR_INVALID_ARGUMENT;
  std::lock_guard<std::mutex> lock(ctx->mu);
  ctx->scan.NotifyModeSwitch();
  return PW_AF_OK;
}

int32_t PwAfUpdate(PwAfContext *ctx, uint64_t frame_index, double focus_measure,
                   double mean_luma, int32_t has_luma, PwAfSampleC *out) {
  if (ctx == nullptr || out == nullptr) return PW_AF_ERR_INVALID_ARGUMENT;
  PwAfFrame f;
  f.frameIndex = frame_index;
  f.focusMeasure = focus_measure;
  f.sceneLuma = mean_luma;
  f.hasSceneLuma = has_luma != 0;

  std::lock_guard<std::mutex> lock(ctx->mu);
  const PwAfOutput o = ctx->scan.Update(f);
  out->lens_internal = o.lensTarget;
  out->lens_platform =
      o.lensValid ? pw_af::PwAfToPlatform(ctx->lens, o.lensTarget) : 0.0;
  out->lens_valid = o.lensValid ? 1 : 0;
  out->lens_move_requested = o.lensMoveRequested ? 1 : 0;
  out->state = static_cast<int32_t>(o.state);
  out->pause_state = static_cast<int32_t>(o.pauseState);
  out->scan_finished = o.scanFinished ? 1 : 0;
  out->retrigger_requested = o.retriggerRequested ? 1 : 0;
  out->frames_to_wait = o.framesToWait;
  out->samples_consumed = o.samplesConsumed;
  out->focus_measure = focus_measure;
  out->mean_luma = mean_luma;
  return PW_AF_OK;
}

double PwAfLensToPlatform(PwAfContext *ctx, double internal_scale) {
  if (ctx == nullptr) return 0.0;
  std::lock_guard<std::mutex> lock(ctx->mu);
  return pw_af::PwAfToPlatform(ctx->lens, internal_scale);
}

double PwAfLensFromPlatform(PwAfContext *ctx, double platform_value) {
  if (ctx == nullptr) return 0.0;
  std::lock_guard<std::mutex> lock(ctx->mu);
  return pw_af::PwAfFromPlatform(ctx->lens, platform_value);
}

int32_t PwAfDefaultLensPlatform(PwAfContext *ctx, double *out) {
  if (ctx == nullptr || out == nullptr) return PW_AF_ERR_INVALID_ARGUMENT;
  std::lock_guard<std::mutex> lock(ctx->mu);
  const double internal =
      ctx->cfg.ranges[static_cast<int>(ctx->range)].focusDefault;
  *out = pw_af::PwAfToPlatform(ctx->lens, internal);
  return PW_AF_OK;
}
