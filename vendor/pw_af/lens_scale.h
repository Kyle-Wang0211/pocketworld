// pw_af —— 内部统一标度 ↔ 各端镜头单位的换算。**只做换算,不调任何平台 API。**
//
// ┌─ 出处 ───────────────────────────────────────────────────────────────────┐
// │ PwAfPwl 沿用 libcamera 的 `cfg_.map` 形状:                              │
// │   src/ipa/rpi/controller/rpi/af.h:118  `libcamera::ipa::Pwl map;`        │
// │        /* converts dioptres -> lens driver position */                   │
// │   src/ipa/rpi/controller/rpi/af.cpp:889-904 `setLensPosition()` 里的      │
// │        `*hwpos = cfg_.map.eval(fsmooth_)`                                 │
// │   src/ipa/libipa/pwl.cpp:206-239 `Pwl::eval` / `Pwl::findSpan` 的语义     │
// │   三个文件的文件头 SPDX 都是 BSD-2-Clause,Copyright Raspberry Pi Ltd。   │
// │   默认 map(af.cpp:159-165)= [0.0 → 445, 15.0 → 925],imx708.json         │
// │   `rpi.af.map` = [0.0, 445, 15.0, 925]。                                 │
// │ 许可与完整文本见 vendor/pw_af/LICENSE.libcamera-BSD-2-Clause。           │
// │ 四端接口矩阵见判决书 §4(每一条都核过官方文档原文)。                    │
// └──────────────────────────────────────────────────────────────────────────┘
//
// 【内部统一标度】屈光度式(1/m),**大 = 近、0 = 无穷远**,与 libcamera 一致
// (af.h:85-86)。判决书 §4「对我们的三条后果」之一:单位三套、方向两套 ⇒
// 算法内部必须用一个统一标度,四端各写一个薄换算。
//
// 【四端语义(判决书 §4 表 B,官方文档原文)】
//  iOS AVFoundation `lensPosition` : 0…1 归一化,**0.0 = 最近、1.0 = 最远**
//        原文 "0.0 being the shortest distance at which the lens can focus and
//        1.0 the furthest. Note that 1.0 doesn't represent focus at infinity."
//        ⇒ 与内部标度**方向相反**,map 的 y 随 x 递减。
//  HarmonyOS `ManualFocus.setFocusDistance` : 0…1 归一化,**0.0 = 最近、
//        1.0 = 最远**,原文 "0.0 indicates the shortest achievable focus
//        distance and 1.0 indicates the longest focus distance"。与 iOS 同向。
//  Android camera2 `LENS_FOCUS_DISTANCE` : **屈光度 1/m**,**0.0f = 无穷远**,
//        越大越近,钳到 [0, LENS_INFO_MINIMUM_FOCUS_DISTANCE]。
//        ⇒ **与内部标度同向同量纲**,四端里唯一一个恒等映射。
//  Web W3C Image Capture `focusDistance` : "usually represents distance in
//        **meters**" ⇒ 与内部标度是倒数关系,不是分段线性(见偏离 L2)。
//
// 【对上游 / 判决书的偏离】
//  L1 `PwAfPwl::Eval` 照上游 pwl.cpp:206-239 在端点段上**外推**(上游同样不钳
//     x)。但各端换算的最后一步一律钳到该端的合法区间 platformMin/platformMax,
//     防止外推吐出平台会抛异常的值(iOS 对不支持的 lensPosition 直接抛)。
//  L2 Web 的「米」是内部标度的**倒数**,不是分段线性 ⇒ 不走 Pwl,走闭式
//     m = 1/D(D ≤ kInfinityEpsilon 时返回 platformMax 当「无穷远」)。
//     硬塞进 Pwl 只能采样近似,不如闭式诚实。
//  L3 🔴 iOS / 鸿蒙的默认 map 是**两点线性占位,不是标定**。Apple 明文:
//     lensPosition "doesn't correspond to an exact physical distance, nor does
//     it represent a consistent focus distance from device to device"
//     (判决书 §4 表 G);鸿蒙连标定说明都没有。判决书 §5.3 也写明
//     「lensPosition ↔ 物理距离的标定曲线:未找到任何发表数据」。
//     ⇒ 这两端的 map **必须逐机型在台架上标**,`PwAfMakeIosScale` 只是给出
//     形状与方向正确的起点。状态机本身不依赖这条曲线(它在归一化标度上爬山,
//     不需要知道物理距离),标不准只影响步长的物理含义,不影响能否收敛。

#ifndef POCKETWORLD_PW_AF_LENS_SCALE_H_
#define POCKETWORLD_PW_AF_LENS_SCALE_H_

#include <cstddef>
#include <utility>
#include <vector>

namespace pw_af {

// 分段线性映射。形状照 libcamera `libcamera::ipa::Pwl`(af.h:118),
// 只保留 af.cpp 实际用到的三件事:append / eval / domain。
class PwAfPwl {
 public:
  // 控制点必须按 x 递增追加;x 不递增的点会被忽略并返回 false。
  bool Append(double x, double y);

  // pwl.cpp:206-239 的语义:定位 x 所在的段,线性插值;x 落在定义域外时沿
  // 端点段**外推**(与上游一致,见偏离 L1)。空表返回 0.0,单点返回该点的 y。
  double Eval(double x) const;

  // 反查:给定 y 求 x。要求 y 单调(递增或递减皆可);不单调时返回最先命中的
  // 那一段。y 落在值域外时钳到端点。空表返回 0.0。
  double EvalInverse(double y) const;

  double DomainStart() const;  // pwl.cpp / af.cpp:885
  double DomainEnd() const;    // pwl.cpp / af.cpp:886
  double ClampToDomain(double x) const;  // af.cpp:895 `domain().clamp()`

  bool Empty() const { return points_.empty(); }
  std::size_t Size() const { return points_.size(); }

 private:
  int FindSpan(double x) const;  // pwl.cpp:222-239
  std::vector<std::pair<double, double>> points_;
};

enum class PwLensUnit : int {
  IosNormalized = 0,   // AVCaptureDevice.lensPosition,0=最近 1=最远
  HarmonyNormalized,   // ManualFocus.setFocusDistance,0=最近 1=最远
  AndroidDioptre,      // CaptureRequest.LENS_FOCUS_DISTANCE,0=无穷远
  WebMetres,           // MediaTrackConstraints.focusDistance,米
};

struct PwLensScale {
  PwLensUnit unit = PwLensUnit::IosNormalized;

  // 内部标度(屈光度,大=近)→ 平台单位。unit == WebMetres 时不使用(L2)。
  PwAfPwl map;

  // 平台单位的合法区间,换算的最后一步钳到这里(L1)。
  double platformMin = 0.0;
  double platformMax = 1.0;

  // 内部标度的合法区间,与 PwAfConfig::lensMin/lensMax 对应。
  double internalMin = 0.0;
  double internalMax = 15.0;
};

// 内部标度 → 平台单位(先钳内部标度,再映射,再钳平台区间)。
double PwAfToPlatform(const PwLensScale& scale, double internalScale);

// 平台单位 → 内部标度(读回当前镜头位置时用:Android 逐帧有
// LENS_FOCUS_DISTANCE,iOS 有 lensPosition 的 KVO)。
double PwAfFromPlatform(const PwLensScale& scale, double platformValue);

// ——— 各端的默认 scale 工厂 ———
// nearDioptre / farDioptre 是该端镜头能覆盖的内部标度区间(大=近)。
// 用 PwAfDefaultConfig() 的 macro 档就是 (near=15.0, far=3.0)。

// 🔴 L3:两点线性占位,**不是标定**,必须逐机型在台架上重标。
// 方向:内部标度越大(越近)⇒ lensPosition 越小(越接近 0)。
PwLensScale PwAfMakeIosScale(double nearDioptre, double farDioptre);

// 🔴 L3 同上。鸿蒙与 iOS 同向同区间,只是 unit 不同(便于上层分流日志)。
PwLensScale PwAfMakeHarmonyScale(double nearDioptre, double farDioptre);

// Android 是恒等映射:同量纲(屈光度)、同方向(0=远)。
// minFocusDistanceDioptres 取 CameraCharacteristics.LENS_INFO_MINIMUM_
// FOCUS_DISTANCE(它本身就是屈光度);为 0 表示定焦/只能对无穷远(LEGACY)。
PwLensScale PwAfMakeAndroidScale(double minFocusDistanceDioptres);

// Web:闭式倒数(L2)。minMetres/maxMetres 取能力表 {min, max} 。
PwLensScale PwAfMakeWebScale(double minMetres, double maxMetres);

}  // namespace pw_af

#endif  // POCKETWORLD_PW_AF_LENS_SCALE_H_
