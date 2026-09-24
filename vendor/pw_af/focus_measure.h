// pw_af —— 焦点度量(focus measure)。
//
// ┌─ 为什么这个文件不是从 libcamera 抄的 ───────────────────────────────────┐
// │ 判决书 §6.1:「没有一个可商用仓能整段抄……最接近的是 libcamera RPi,      │
// │ **差的正好是一个函数** getContrast() —— 它的 FoM 来自树莓派 ISP 硬件统计,│
// │ 手机上没有这条硬件通路。」本文件就是补那一块。                          │
// └──────────────────────────────────────────────────────────────────────────┘
//
// 【算子选择的发表依据(不是自研)】
//  - Mir, Xu, van Beek 2014, Proc. SPIE 9023 90230I, doi:10.1117/12.2042350
//    在 **4,303 张 Canon 550D 实拍照片 / 25 个焦点栈 / >30 种度量** 上评测:
//    **Brenner 与 squared gradient(一阶导)最优 = 100 / 99 / 0.00**
//    (precision / recall / MAE);3×3 Sobel/Prewitt/Scharr 次之 98 / 97 / 0.02;
//    直方图 / 方差 / Vollath 很差。并明确:一阶导**方向要选全**,只算竖向
//    Brenner 会掉到 91 / 90 / 0.23 ⇒ 本文件两个算子都是双向的。
//  - Pertuz, Puig, Garcia 2013, Pattern Recognition 46(5):1415-1432,
//    doi:10.1016/j.patcog.2012.11.011,评 36 个算子,方向一致
//    (梯度/拉普拉斯系在正常成像条件下最优)。
//  - 公式对照(仅对照定义,未复制其 MATLAB 代码):Pertuz 的 `fmeasure.m`
//    (MATLAB FileExchange #27314,BSD-3)`TENG`(:188)=
//    `Gx.^2 + Gy.^2` 的 ROI 内均值,Gx/Gy 为 3×3 Sobel;`GRAT`(:102)为
//    一阶差分族。Micro-Manager `ImgSharpnessAnalysis.java:261-281`
//    `computeTenengrad`(BSD-3)是同一式。
//    本文件是按公式独立写的 C++,不含上述任何一方的源码。
//
// 【对判决书的偏离(本刀自定,理由在此)】
//  F1 判决书 §6.1 写的是「接到 GPU 前端已有的 sobel dx/dy 纹理上做窗口归约」
//     (pw_gpu_frontend.cpp:58/120、pw_gpufe_wgsl.h:13 k_sobel_dxdy)。
//     本刀**不走那条**,第一刀做纯 C++。理由两条:
//       (a) 那条链是 research_only 血统,且**只有 iOS 有 Dawn 链** ——
//           Android / 鸿蒙 / Web 上没有,违反「一套管线服务所有手机」;
//       (b) 先量出纯 C++ 的耗时,再决定要不要上 GPU,比先上 GPU 再回退便宜。
//     ⇒ 单测里直接量 1920×1440 全图与典型 ROI 的 µs(见 tests/,判据交用户)。
//     🔴 这意味着「GPU 归约与读回的延迟」这一项本刀没有数据,stepFrames 的
//        台架重标(判决书 §7)仍然欠着。
//  F2 归一化:上游 getContrast()(af.cpp:382)返回的是**加权平均**
//     (sumWc / weights.sum),所以本文件也返回 ROI 内的**均值**而不是总和 ——
//     ROI 尺寸变化(主体框会随距离变)时度量的量纲不跟着变,状态机跨帧比较
//     才有意义。
//  F3 不用现有的 lib/quality/quality_compute.dart 的 Laplacian 方差驱动镜头:
//     判决书 §6.1 —— 它算在 128×128 缩略图、6 Hz,分辨率与节奏都不够。
//     它原样留作**验收尺子**(判决书 §6.3),两者互不替代。
//
// 【平台无关铁律】纯 C++17,零依赖,输入是灰度图指针 + stride + ROI 矩形。
// iOS 的 Y 平面(CVPixelBuffer plane 0)、Android 的 YUV_420_888 Y 平面、
// 鸿蒙与 Web 的灰度缓冲都能直接喂,本文件不认识任何一端。

#ifndef POCKETWORLD_PW_AF_FOCUS_MEASURE_H_
#define POCKETWORLD_PW_AF_FOCUS_MEASURE_H_

#include <cstddef>
#include <cstdint>

namespace pw_af {

// 像素坐标矩形,原点左上。
struct PwAfRect {
  int x = 0;
  int y = 0;
  int width = 0;
  int height = 0;
};

enum class PwFocusOperator : int {
  // Tenengrad:3×3 Sobel 的平方模,ROI 内取均值。
  // Pertuz fmeasure.m `TENG`(:188);Mir 2014 的 Sobel 档 98 / 97 / 0.02。
  Tenengrad = 0,

  // Squared gradient:双向一阶差分的平方和,ROI 内取均值。
  // Mir 2014 评测里的最优档之一(squared gradient 99 / 0.00)。
  // 比 Tenengrad 便宜(每像素 2 次减法 vs 6 次乘加),抗噪弱一些。
  SquaredGradient,
};

// 上游 af.cpp:313-321 的默认 AF 窗口 —— 原注释:
//   "Default AF window is the middle 1/2 width of the middle 1/3 height"
// 拿不到主体框时的退路(af_scan.h 的 D12)。
// 🔴 判决书 §2.4:文献里**没有一篇**验证过「中心加权 vs 最近主体 vs 主体检测
//    框」在 10–30 cm 小物体上的优劣,学界基准多数直接取 ROI = 整幅图 ⇒
//    我们的 ROI 策略没有发表依据背书,必须靠台架 A/B 自证。
PwAfRect PwAfDefaultRoi(int width, int height);

// 把 roi 与图像边界求交,并留出算子需要的边界余量;返回是否还有可算的像素。
bool PwAfClampRoi(const PwAfRect& roi, int width, int height,
                  PwFocusOperator op, PwAfRect* out);

// 计算 ROI 内的焦点度量。越大越清晰。
//   gray   : 8 位灰度图起始地址(不得为 null)
//   width  : 图像宽(像素)
//   height : 图像高(像素)
//   stride : 行间距(字节),必须 >= width
//   roi    : 评价窗;会与图像边界求交
//   op     : 算子
//   meanLumaOut : 非 null 时,顺带回填同一 ROI 的平均亮度(0–255)。
//                 给 af_scan 的场景变化判据用(af_scan.h 的 D5),同一趟遍历
//                 算完,不用再扫一遍。
// ROI 内没有可算像素时返回 0.0(并把 meanLumaOut 置 0)。
double PwAfFocusMeasure(const uint8_t* gray, int width, int height, int stride,
                        const PwAfRect& roi, PwFocusOperator op,
                        double* meanLumaOut);

}  // namespace pw_af

#endif  // POCKETWORLD_PW_AF_FOCUS_MEASURE_H_
