// pw_af —— **C ABI 门面**。给 Swift(`@_cdecl` 那一侧)与将来的 Android JNI /
// 鸿蒙 NAPI 用;C++ 类型一个都不暴露。
//
// ┌─ 形状抄哪儿 ─────────────────────────────────────────────────────────────┐
// │ vendor/xrslam/transport/PwXrslamTransportCore.h —— 同一个仓里已经立过的   │
// │ 规矩:`extern "C"` + 不透明指针 + 扁平 POD 结构体 + `int32_t` 返回码,     │
// │ 负数是失败码。本文件逐条照它,不另立风格。                                │
// └──────────────────────────────────────────────────────────────────────────┘
//
// 【本文件不是从 libcamera 抄的】af_scan / focus_measure / lens_scale 三件的
// 出处与许可见它们各自的文件头(libcamera BSD-2 + Pertuz/Mir 的公式)。本文件
// 只是把它们包成 C,**不含任何算法**,唯一一处像素运算是 BGRA→灰度(见下)。
//
// ┌─ 🔴 为什么会有 BGRA 这一档(不是自研,是被 iOS 的既有取舍逼的)──────────┐
// │ `ios/Runner/PwCameraSlot.swift` 的 `out.videoSettings` **钉死 32BGRA**,   │
// │ 理由写在那个文件头:Filament 的 Metal 后端只接 32BGRA 与 420f,而只有     │
// │ 32BGRA 是真零拷贝。所以这条链上**拿不到 Y 平面**,只有 BGRA。            │
// │ 转换式用 ITU-R BT.601 的亮度系数 Y = 0.299R + 0.587G + 0.114B ——          │
// │ 就是 OpenCV `cvtColor(COLOR_BGRA2GRAY)` 用的那一条,不是我挑的权重。      │
// │ 🔴 它与「Y 平面直取」不逐位相同(视频范围/全范围、色度上采样都不同)。    │
// │    三臂**全部走同一个函数**,所以三臂之间可比;跨设备/跨管线不可比。      │
// │ 只转 ROI **外扩 1 像素**那一块(整帧 1920×1440 的 1/6),缓冲由 context   │
// │ 持有并复用;外扩是为了让度量与「整图 + ROI」那条路**逐位相同**(单测钉)。│
// └──────────────────────────────────────────────────────────────────────────┘

#ifndef POCKETWORLD_PW_AF_PW_AF_C_H_
#define POCKETWORLD_PW_AF_PW_AF_C_H_

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ——— 返回码。与 PwXrslamTransportCore.h 的 PWXrslamTransportStatus 同风格 ———
typedef enum PwAfStatus {
  PW_AF_OK = 0,
  PW_AF_ERR_INVALID_ARGUMENT = -1,
  PW_AF_ERR_NO_PIXELS = -2,  // ROI 与图像求交后没有可算的像素
} PwAfStatus;

// ——— 枚举的 C 镜像。值与 af_scan.h / focus_measure.h 的 enum class 逐一对应,
//     由 pw_af_c.cpp 里的 static_assert 钉住(改一边不改另一边会编不过)。———
typedef enum PwAfRangeC {
  PW_AF_RANGE_NORMAL = 0,
  PW_AF_RANGE_MACRO = 1,
  PW_AF_RANGE_FULL = 2,
} PwAfRangeC;

typedef enum PwAfSpeedC {
  PW_AF_SPEED_NORMAL = 0,
  PW_AF_SPEED_FAST = 1,
} PwAfSpeedC;

typedef enum PwAfModeC {
  PW_AF_MODE_MANUAL = 0,
  PW_AF_MODE_AUTO = 1,
  PW_AF_MODE_CONTINUOUS = 2,
} PwAfModeC;

typedef enum PwAfPauseModeC {
  PW_AF_PAUSE_IMMEDIATE = 0,
  PW_AF_PAUSE_DEFERRED = 1,
  PW_AF_PAUSE_RESUME = 2,
} PwAfPauseModeC;

typedef enum PwAfStateC {
  PW_AF_STATE_IDLE = 0,
  PW_AF_STATE_SCANNING = 1,
  PW_AF_STATE_FOCUSED = 2,
  PW_AF_STATE_FAILED = 3,
} PwAfStateC;

typedef enum PwAfOperatorC {
  PW_AF_OP_TENENGRAD = 0,
  PW_AF_OP_SQUARED_GRADIENT = 1,
} PwAfOperatorC;

// 像素矩形,原点左上。focus_measure.h 的 PwAfRect 的 C 镜像。
typedef struct PwAfRectC {
  int32_t x;
  int32_t y;
  int32_t width;
  int32_t height;
} PwAfRectC;

// 一帧 Update 的输出。af_scan.h `PwAfOutput` 的扁平化 + 平台单位那一列。
typedef struct PwAfSampleC {
  double lens_internal;   // 内部标度(屈光度,大=近)
  double lens_platform;   // 换算到该端单位(iOS 就是 lensPosition 0…1)
  int32_t lens_valid;     // 0 = lens_* 无意义(状态机还没初始化)
  int32_t lens_move_requested;
  int32_t state;          // PwAfStateC
  int32_t pause_state;    // 0 Running / 1 Pausing / 2 Paused
  int32_t scan_finished;  // 本帧落下 Focused / Failed 判决
  int32_t retrigger_requested;
  uint32_t frames_to_wait;
  uint64_t samples_consumed;
  double focus_measure;   // 本帧喂进去的度量(原样回带,方便记流水)
  double mean_luma;       // 同一 ROI 的平均亮度 0–255
} PwAfSampleC;

typedef struct PwAfContext PwAfContext;

// ——— 无状态工具 ———

// focus_measure.h `PwAfDefaultRoi` —— 上游 af.cpp:313-321 的默认 AF 窗口
// (中间 1/2 宽 × 中间 1/3 高)。三臂共用的那个矩形就是它。
int32_t PwAfDefaultRoiC(int32_t width, int32_t height, PwAfRectC *out);

// ——— context ———
//
// near_dioptre / far_dioptre 是该端镜头覆盖的内部标度区间(大=近),用来建
// iOS 的 lensPosition 映射(lens_scale.h `PwAfMakeIosScale`,🔴 L3:两点线性
// **占位不是标定**,不可当物理距离用)。传 0/0 表示用所选 range 的 focusMax /
// focusMin。
//
// 🔴 三臂**都要**建 context:A/B 臂不驱动镜头,但必须用同一个函数算度量,
//    否则三臂的度量口径不一致就不可比(任务书「最上游输入必须清晰」)。
PwAfContext *PwAfCreate(int32_t range, double near_dioptre, double far_dioptre);
void PwAfDestroy(PwAfContext *ctx);

// ——— 度量(A/B/C 三臂共用)———
//
// gray : 8 位灰度,stride >= width。
// bgra : 32BGRA(B,G,R,A 字节序,与 kCVPixelFormatType_32BGRA 一致),
//        stride >= width*4;内部只转 ROI 那一块到 ctx 的复用缓冲。
// 两者都把同一 ROI 的平均亮度回填到 luma_out(可为 NULL)。
int32_t PwAfMeasureGray(PwAfContext *ctx, const uint8_t *gray, int32_t width,
                        int32_t height, int32_t stride, const PwAfRectC *roi,
                        int32_t op, double *measure_out, double *luma_out);
int32_t PwAfMeasureBgra(PwAfContext *ctx, const uint8_t *bgra, int32_t width,
                        int32_t height, int32_t stride, const PwAfRectC *roi,
                        int32_t op, double *measure_out, double *luma_out);

// ——— 状态机(只有 C 臂用)———
int32_t PwAfSetRange(PwAfContext *ctx, int32_t range);
int32_t PwAfSetSpeed(PwAfContext *ctx, int32_t speed);
int32_t PwAfSetMode(PwAfContext *ctx, int32_t mode);
int32_t PwAfTriggerScan(PwAfContext *ctx);
int32_t PwAfCancelScan(PwAfContext *ctx);
int32_t PwAfPause(PwAfContext *ctx, int32_t pause);
int32_t PwAfNotifyModeSwitch(PwAfContext *ctx);

// 每帧一次。focus_measure 由上面两个 Measure 之一算出。
// has_luma == 0 时场景变化判据退化为只看对比度两项(af_scan.h 的 D5)。
int32_t PwAfUpdate(PwAfContext *ctx, uint64_t frame_index, double focus_measure,
                   double mean_luma, int32_t has_luma, PwAfSampleC *out);

// 内部标度 ↔ 平台单位(iOS lensPosition)。
double PwAfLensToPlatform(PwAfContext *ctx, double internal_scale);
double PwAfLensFromPlatform(PwAfContext *ctx, double platform_value);

// 所选 range 的默认位("超焦距"),已换算到平台单位。
int32_t PwAfDefaultLensPlatform(PwAfContext *ctx, double *out);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // POCKETWORLD_PW_AF_PW_AF_C_H_
