// pw_af —— 反差式自动对焦(CDAF)搜索状态机。
//
// ┌─ 出处 ───────────────────────────────────────────────────────────────────┐
// │ 逐段复刻 raspberrypi/libcamera 树莓派 IPA:                              │
// │   src/ipa/rpi/controller/rpi/af.cpp      (SPDX BSD-2-Clause)             │
// │   src/ipa/rpi/controller/rpi/af.h        (同)                            │
// │   src/ipa/rpi/controller/af_algorithm.h  (同,本文件的四个枚举照它的形状) │
// │   src/ipa/rpi/controller/af_status.h     (同,AfState / AfPauseState)     │
// │   Copyright (C) 2022-2023, Raspberry Pi Ltd                              │
// │ 许可依据与完整文本见 vendor/pw_af/LICENSE.libcamera-BSD-2-Clause。       │
// │ 快照 2026-09-23(af.cpp 共 970 行);注释里的 "af.cpp:NNN" 均指该快照。   │
// │ 调研判决书:docs/research/autofocus_algorithm_survey_20260922.md         │
// └──────────────────────────────────────────────────────────────────────────┘
//
// 【平台无关铁律】纯 C++17。不 include 任何 iOS / Android / 鸿蒙头文件,不依赖
// Dawn / Metal / OpenCV / libcamera。镜头由调用方注入:
//   输入 = 本帧的焦点度量值 + 帧序号(+ 可选的 ROI 平均亮度)
//   输出 = 下一步镜头位置(内部统一标度)/ 本轮是否结束 / 是否需要重对焦
// 内部统一标度 = 屈光度式(1/m),**大 = 近、0 = 无穷远**,与 libcamera 内部一致
// (af.h:85-86 `focusMin /* lower (far) limit in dioptres */`、
//             `focusMax /* upper (near) limit in dioptres */`)。
// 到各端单位(iOS/鸿蒙归一化 0=近;Android 屈光度 0=远;Web 米)的换算全部在
// lens_scale.{h,cpp},本文件一行平台单位都不认识。
//
// ┌─ 对上游的偏离(逐条,含理由)────────────────────────────────────────────┐
// │ D1  删 PDAF 全部通路:af.h:77 `ScanState::Pdaf`、af.h:144 `getPhase`、    │
// │     :147 `doPDAF`、:148 `earlyTerminationByPhase`、af.cpp:607-637 的      │
// │     Pdaf 分支、:683-686 的相位早停、`startAF():713-734` 的 PDAF 起手、    │
// │     参数 pdafGain/pdafSquelch/pdafFrames/dropoutFrames(af.h:99-103)与    │
// │     confEpsilon/confThresh/confClip(af.h:113-115)、成员 prevPhase_ /     │
// │     sameSignCount_ / dropCount_(af.h:176-178)。                          │
// │     理由:手机上没有树莓派那条 PDAF 硬件输入(判决书 §3.1),任务书指定删。│
// │ D2  删 IR 检测:af.h:146 `getAverageAndTestIr`、成员 irFlag_、参数        │
// │     checkForIR(af.h:117)。理由:我们没有这个判据的输入。                 │
// │ D3  焦点度量来源:上游 `getContrast():368-390` 从 ISP 硬件 focusRegions   │
// │     加权求和;我们由调用方每帧传入(focus_measure.h 的 Tenengrad)。       │
// │     这正是判决书 §6.1 所说的「libcamera 唯一缺的那一块」。               │
// │ D4  ScanState 去掉 Pdaf 后重编号 ⇒ 上游的序关系比较语义保持不变:        │
// │     `scanState_ < Coarse1`(af.cpp:638/937/953/957)上游覆盖              │
// │     {Idle,Trigger,Pdaf},我们覆盖 {Idle,Trigger};                        │
// │     `scanState_ >= Pdaf`(af.cpp:694)上游义为「非 Idle 且非 Trigger」,   │
// │     我们写成 `>= Coarse1`,集合逐一对应。                                │
// │ D5  场景变化判据:上游 af.cpp:643-650 是八项(对比度双向 + AWB R/G/B 各   │
// │     双向);我们保留对比度双向 + **单项亮度**双向 = 四项。理由:判决书    │
// │     §6.1「只把 AWB R/G/B 那三项换成我们能拿到的亮度统计」。调用方不给亮度 │
// │     时(hasSceneLuma=false)退化为只看对比度两项。                        │
// │ D6  统计延迟差一帧:上游把 `process()`(af.cpp:824-829,存本帧 FoM)与    │
// │     `prepare()`(:775-803,拿**上一帧**的 FoM 跑 doAF)分成两个回调 ——    │
// │     注释 af.cpp:766-773 明说那一帧是 ISP 延迟。我们一次 update() 里先存   │
// │     本帧 FoM 再跑 doAF ⇒ **吃本帧自己的 FoM**。理由:度量是我们自己在这一 │
// │     帧上算的,没有 ISP 那一帧延迟;等镜头整定仍由 stepFrames 承担。       │
// │ D7  Settle 收尾的去向:上游 af.cpp:674-678 在连续模式下回 Pdaf;我们没有   │
// │     Pdaf,一律回 Idle —— 等价于上游 `dropoutFrames == 0` 时的既有分支。   │
// │ D8  **近焦优先**(cfg.macroFirst):`startProgrammedScan():736-757` 的三   │
// │     分支起点选择,改成固定从 focusMax(最近端)起、步长取负(向远扫)、   │
// │     直接进 Coarse2(单向扫不反向)。配合 doScan():551 的「对比度跌破      │
// │     contrastRatio×max 即停」⇒ **首峰即停 ⇒ 天然取最近的峰**。            │
// │     判决书 §6.1 明写这是「参数与起点的选择,不是自研算法」。             │
// │     🔴 专利风险见判决书 §7(Samsung US 8,447,179 B2),上生产前需 FTO。   │
// │ D9  上游死分支不抄:af.cpp:566-569 的 `else if` 判定条件与 :559-562 完全   │
// │     相同,永远走不到。只抄活的那一支,运行行为逐位相同。                 │
// │ D10 macro 档 step_fine 由 0.25 重标为 0.175 屈光度(推算依据见           │
// │     af_scan.cpp `kMacroStepFine` 注释,**是推算不是实测**)。             │
// │ D11 `map`(内部标度 → 硬件位置)搬去 lens_scale.{h,cpp}。上游是           │
// │     af.h:118 `cfg_.map` + `setLensPosition():889-904` 的 `cfg_.map.eval`。│
// │     本状态机只在内部标度上跑,钳位边界用 cfg.lensMin/lensMax,对应上游的  │
// │     `cfg_.map.domain()`(af.cpp:885-886/895)。                            │
// │ D12 多窗口加权 `computeWeights():267-322` 不搬进状态机:我们的 ROI 是     │
// │     **一个**物体框,「把多个窗口按面积合并成权重图」没有输入。上游的默认  │
// │     窗口(中 1/2 宽 × 中 1/3 高,af.cpp:313-321)搬到                     │
// │     `PwAfDefaultRoi()`,作为拿不到主体框时的退路。                       │
// │ D13 日志:上游的 `LOG(RPiAf, ...)` 全删(要平台无关、零依赖)。          │
// │ D14 上游是 libcamera Algorithm 子类(read()/initialise()/switchMode()/    │
// │     prepare()/process() 五个回调);我们是一个自包含的类,参数用结构体    │
// │     直接构造,不解析 json、不注册到任何 Controller。                     │
// └──────────────────────────────────────────────────────────────────────────┘
//
// 【本刀不做】不接任何平台。iOS 宿主的接法(不在本刀内实现,仅记录):
//   - 读数:ios/Runner/PwCameraSlot.swift:323-395 `captureOutput(_:didOutput:)`
//     已逐帧拿到 CVPixelBuffer + PTS,在那里把 Y 平面交给 PwAfFocusMeasure();
//   - 驱动:PwCameraSlot.swift:237-241 的 `setFocusModeLocked(lensPosition:
//     completionHandler:)` 从「启动锁一次 0.835」改成「状态机每步调一次」,
//     completionHandler 的 CMTime 是四端里唯一的「镜头已到位」硬信号;
//   - 快门:PwCameraSlot.swift:707 `capturePhoto(requestId:)` 之前插一次
//     `TriggerScan()`,等 Focused/Failed/超时再拍,拍完 Pause(Deferred)。
//   Android / 鸿蒙 / Web 的接法见本刀报告。

#ifndef POCKETWORLD_PW_AF_AF_SCAN_H_
#define POCKETWORLD_PW_AF_AF_SCAN_H_

#include <cstdint>
#include <vector>

namespace pw_af {

// af_algorithm.h:42-45。
enum class PwAfRange : int {
  Normal = 0,
  Macro,
  Full,
  Max,
};

// af_algorithm.h:47-49。
enum class PwAfSpeed : int {
  Normal = 0,
  Fast,
  Max,
};

// af_algorithm.h:51-53。
enum class PwAfMode : int {
  Manual = 0,
  Auto,
  Continuous,
};

// af_algorithm.h:55-57。
enum class PwAfPause : int {
  Immediate = 0,
  Deferred,
  Resume,
};

// af_status.h:16-21。
enum class PwAfState : int {
  Idle = 0,
  Scanning,
  Focused,
  Failed,
};

// af_status.h:23-27。
enum class PwAfPauseState : int {
  Running = 0,
  Pausing,
  Paused,
};

// af.h:84-91 `RangeDependentParams`。全部是内部统一标度(屈光度式,大=近)。
struct PwAfRangeParams {
  double focusMin = 0.0;      // 远端(小)限;af.h:85
  double focusMax = 12.0;     // 近端(大)限;af.h:86
  double focusDefault = 1.0;  // 默认位("超焦距");af.h:87

  // 【D15 偏离】上游的 step_fine 只挂在 speeds 上(af.h:95),与 range 无关。
  // 我们给 range 加一个覆盖,因为细扫步长的正确量纲是「当地景深」,而景深是
  // **物距区间(range)**的属性,不是速度档的属性(推算见 af_scan.cpp 的
  // kMacroStepFine)。<= 0 表示不覆盖,用 speeds 里的值。
  // 覆盖**不会**推翻 fast 档 step_fine = 0.0 的「跳过细扫」语义。
  double stepFineOverride = -1.0;
};

// af.h:93-108 `SpeedDependentParams`,已删 D1 列出的 PDAF 五项。
struct PwAfSpeedParams {
  double stepCoarse = 1.0;      // af.h:94;粗扫步长(屈光度)
  double stepFine = 0.25;       // af.h:95;细扫步长(屈光度)
  double contrastRatio = 0.75;  // af.h:96;扫描终止与成败判据的比值
  double retriggerRatio = 0.75; // af.h:97;重触发的对比度/亮度比值
  uint32_t retriggerDelay = 10; // af.h:98;重触发前要稳定的帧数
  double maxSlew = 2.0;         // af.h:101;每帧镜头最大移动量
  uint32_t stepFrames = 4;      // af.h:104;每步之间跳过的帧数
};

// af.h:110-123 `CfgParams`,已删 PDAF 三项(conf*)与 checkForIR(D1/D2),
// map 搬去 lens_scale(D11)。
struct PwAfConfig {
  PwAfRangeParams ranges[static_cast<int>(PwAfRange::Max)];
  PwAfSpeedParams speeds[static_cast<int>(PwAfSpeed::Max)];
  uint32_t skipFrames = 5;  // af.h:116;启动/模式切换后跳过的帧数

  // D11:对应上游 `cfg_.map.domain()`(af.cpp:885-886),手动定位的钳位边界。
  // 默认取上游默认 map 的定义域 [0.0, 15.0](af.cpp:159-162)。
  double lensMin = 0.0;
  double lensMax = 15.0;

  // D8:近焦优先。true = 每次程序扫描固定从 focusMax(最近)向远单向扫,
  // 首峰即停。用户口径:被拍物体是 10–30 cm 的小物体,近焦优先。
  bool macroFirst = true;
};

// 依 imx708.json 的 `rpi.af` 段构造默认参数(ranges.normal/macro、
// speeds.normal/fast),macro 档的 step_fine 按 D10 重标。
PwAfConfig PwAfDefaultConfig();

// 每帧喂给状态机的输入。
struct PwAfFrame {
  // 帧序号。状态机自身用的是「被消费的采样次数」而不是它;它只用于调用方
  // 对账与输出回放(sidecar 里可以画 lens(t))。必须单调不减。
  uint64_t frameIndex = 0;

  // 本帧 ROI 内的焦点度量值(见 focus_measure.h)。越大越清晰。
  // 对应上游 af.cpp:827 的 `prevContrast_ = getContrast(...)`(D3)。
  double focusMeasure = 0.0;

  // D5:ROI 内平均亮度,替代上游的 AWB R/G/B 三项,只参与场景变化判据。
  double sceneLuma = 0.0;
  bool hasSceneLuma = false;
};

// 每帧从状态机拿到的输出。
struct PwAfOutput {
  // 本帧应下发给镜头的位置,内部统一标度(屈光度式,大=近)。
  // 对应上游 af.cpp:819 `status.lensSetting = cfg_.map.eval(fsmooth_)` 里的
  // fsmooth_ ——「经过 maxSlew 限速之后」的平滑值,不是 ftarget_。
  double lensTarget = 0.0;
  bool lensValid = false;        // 上游 `initted_`;false 时 lensTarget 无意义
  bool lensMoveRequested = false;// 相对上一帧下发值有变化

  PwAfState state = PwAfState::Idle;             // af.cpp:813-818
  PwAfPauseState pauseState = PwAfPauseState::Running;  // af.cpp:807-811

  // 本轮是否结束:Settle 判决(af.cpp:668-682)在本帧落下 ⇒ true。
  // 此时 state 已是 Focused 或 Failed。
  bool scanFinished = false;

  // 本帧因场景变化触发了重扫(af.cpp:656-657 的 startProgrammedScan)。
  bool retriggerRequested = false;

  // 还要等几帧才读下一次度量(上游 stepCount_,af.cpp:585/666-667)。
  // 0 = 本帧的度量已被消费,下一帧会继续推进扫描。
  uint32_t framesToWait = 0;

  // 累计被 doScan 消费的采样次数;单测用它验证 step_frames 的等待模型。
  uint64_t samplesConsumed = 0;
};

class PwAfScan {
 public:
  explicit PwAfScan(const PwAfConfig& cfg);

  // ——— 控制面(af.cpp:833-849、:915-940、:947-963)———
  void SetRange(PwAfRange range);  // af.cpp:833-838
  void SetSpeed(PwAfSpeed speed);  // af.cpp:840-849(已删 PDAF 修正,D1)
  void SetMode(PwAfMode mode);     // af.cpp:929-940
  PwAfMode GetMode() const { return mode_; }  // af.cpp:942-945
  void TriggerScan();              // af.cpp:922-927
  void CancelScan();               // af.cpp:915-920
  void Pause(PwAfPause pause);     // af.cpp:947-963

  // af.cpp:889-904。仅在 Manual 模式(或 force)下生效;返回是否改变了位置。
  bool SetLensPosition(double internalScale, bool force = false);
  // af.cpp:906-913。未初始化时返回 false。
  bool GetLensPosition(double* out) const;
  // af.cpp:877-880 / :882-887。
  double GetDefaultLensPosition() const;
  void GetLensLimits(double* min, double* max) const;

  // af.cpp:239-265 `switchMode()` 的非 libcamera 部分:传感器模式/分辨率变了,
  // 扫描中就重启扫描,并跳过 skipFrames 帧。(D12:不含 statsRegion/权重图。)
  void NotifyModeSwitch();

  // 每帧调一次。内部次序 = process()(存本帧 FoM)→ prepare()(跑 doAF +
  // updateLensPosition)。见 D6。
  PwAfOutput Update(const PwAfFrame& frame);

 private:
  // af.h:74-82,已删 Pdaf(D1/D4)。
  enum class ScanState : int {
    Idle = 0,
    Trigger,
    Coarse1,
    Coarse2,
    Fine,
    Settle,
  };

  // af.h:125-130 `ScanRecord`,已删 phase/conf(D1)。
  struct ScanRecord {
    double focus;
    double contrast;
  };

  double FindPeak(size_t index) const;  // af.cpp:502-533
  void DoScan(double contrast);         // af.cpp:535-586
  void DoAf(double contrast);           // af.cpp:588-690
  void UpdateLensPosition();            // af.cpp:692-711
  void StartAf();                       // af.cpp:713-734
  void StartProgrammedScan();           // af.cpp:736-757
  void GoIdle();                        // af.cpp:759-764

  const PwAfRangeParams& Range() const {
    return cfg_.ranges[static_cast<int>(range_)];
  }
  const PwAfSpeedParams& Speed() const {
    return cfg_.speeds[static_cast<int>(speed_)];
  }
  // D15:range 级的 step_fine 覆盖;fast 档的 0.0(不做细扫)优先。
  double StepFine() const;

  // 配置与设定(af.h:157-168 的对应子集)。
  PwAfConfig cfg_;
  PwAfRange range_ = PwAfRange::Normal;
  PwAfSpeed speed_ = PwAfSpeed::Normal;
  PwAfMode mode_ = PwAfMode::Manual;
  bool pauseFlag_ = false;

  // 工作状态(af.h:170-183 的对应子集)。
  ScanState scanState_ = ScanState::Idle;
  bool initted_ = false;
  double ftarget_ = -1.0;
  double fsmooth_ = -1.0;
  double prevContrast_ = 0.0;
  double oldSceneContrast_ = 0.0;
  double prevAverage_ = 0.0;      // D5:单项亮度取代 prevAverage_[3]
  double oldSceneAverage_ = 0.0;  // D5:同上
  bool haveAverage_ = false;
  uint32_t skipCount_ = 0;
  uint32_t stepCount_ = 0;
  uint32_t sceneChangeCount_ = 0;
  size_t scanMaxIndex_ = 0;
  double scanMaxContrast_ = 0.0;
  double scanMinContrast_ = 1.0e9;
  double scanStep_ = 0.0;
  std::vector<ScanRecord> scanData_;
  PwAfState reportState_ = PwAfState::Idle;

  // 只服务输出结构,上游没有对应成员。
  double lastEmittedLens_ = 0.0;
  bool haveEmittedLens_ = false;
  bool scanFinishedThisFrame_ = false;
  bool retriggeredThisFrame_ = false;
  uint64_t samplesConsumed_ = 0;
};

}  // namespace pw_af

#endif  // POCKETWORLD_PW_AF_AF_SCAN_H_
