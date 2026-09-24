// pw_af —— CDAF 搜索状态机的实现。出处、许可与「对上游的偏离」逐条见 af_scan.h。
// 每个函数上方标注它复刻的 af.cpp 行号区段(2026-09-23 快照,共 970 行)。

#include "af_scan.h"

#include <algorithm>
#include <cmath>

namespace pw_af {
namespace {

// ——— macro 档 step_fine 的重标(af_scan.h 的 D10)———
//
// 上游 imx708.json `rpi.af.speeds.normal.step_fine = 0.25` 屈光度。
// 判决书 §5.3 指出它在 20 cm 处对应 ±1 cm 的物距变化,**比景深还粗**。
//
// 推算(**由发表参数计算,不是实测**;参数取自判决书 §5.3:
//   f = 6.86 mm —— 🔴 iPhone 主摄真实焦距的 EXIF 惯例值,Apple 规格页只发布
//                  35 mm 等效 24 mm,不发布真实焦距。这是本推算最弱的一环。
//   N = 1.78    —— Apple 规格页
//   c = 2.44 µm —— 2 像元 @48MP,判决书 §5.3 表格最严的那一列)
//
// 薄透镜景深:near/far = s·f² / (f² ± N·c·(s−f))。
// 在 s = 200 mm 处:near = 196.50 mm、far = 203.63 mm ⇒ 景深 7.13 mm
//   —— 与判决书 §5.3 表格的 7.1 mm 对上。
// 换成屈光度:D_near = 1/0.19650 = 5.0891、D_far = 1/0.20363 = 4.9109
//   ⇒ 景深的屈光度宽度 ΔD = 0.178。
// 同法在最松的那一列(c = 8.24 µm):景深 24.17 mm ⇒ ΔD = 0.602。
//
// 🔑 这个 ΔD 近似与物距无关:s ≫ f 时景深 ≈ 2·N·c·s²/f²,而 ds/dD = s²,
//    两个 s² 约掉 ⇒ ΔD ≈ 2·N·c/f² = 2×1.78×2.44e-3 mm / (6.86 mm)² = 0.185。
//    所以同一个 step_fine 在 10 cm 与 33 cm 两端都与当地景深同量级,
//    不需要按距离分档。
//
// 取 0.175 —— 略小于最严那一列的 0.178,保证一个细扫步长**绝不跨过**最严判据
// 下的整个景深;三点细扫(af.cpp:550)跨度 2×0.175 = 0.35 屈光度 ≈ 2 倍景深,
// 正好把峰夹在中间给 findPeak():502-533 的抛物线拟合用。
// 对照:上游 0.25 在 20 cm 处 = 0.25/5² m = 10.0 mm,而景深只有 7.13 mm;
//       本值 0.175 在 20 cm 处 = 7.0 mm。
constexpr double kMacroStepFine = 0.175;

}  // namespace

// imx708.json `rpi.af` 段逐键搬运;macro.step_fine 按 D10 重标。
PwAfConfig PwAfDefaultConfig() {
  PwAfConfig cfg;

  // "ranges": { "normal": { "min": 0.0, "max": 12.0, "default": 1.0 } }
  PwAfRangeParams normal;
  normal.focusMin = 0.0;
  normal.focusMax = 12.0;
  normal.focusDefault = 1.0;

  // "ranges": { "macro": { "min": 3.0, "max": 15.0, "default": 4.0 } }
  // 3–15 屈光度 = 33 cm–6.7 cm,覆盖用户口径的 10–30 cm(判决书 §6.1)。
  PwAfRangeParams macro;
  macro.focusMin = 3.0;
  macro.focusMax = 15.0;
  macro.focusDefault = 4.0;  // 25 cm
  macro.stepFineOverride = kMacroStepFine;  // D10 / D15,推算见上方注释

  // af.cpp:117-121:full = normal 与 macro 的并集,default 取 normal 的。
  PwAfRangeParams full;
  full.focusMin = std::min(normal.focusMin, macro.focusMin);
  full.focusMax = std::max(normal.focusMax, macro.focusMax);
  full.focusDefault = normal.focusDefault;

  cfg.ranges[static_cast<int>(PwAfRange::Normal)] = normal;
  cfg.ranges[static_cast<int>(PwAfRange::Macro)] = macro;
  cfg.ranges[static_cast<int>(PwAfRange::Full)] = full;

  // "speeds": { "normal": { ... } };PDAF 五项已删(D1)。
  PwAfSpeedParams speedNormal;
  speedNormal.stepCoarse = 1.0;
  speedNormal.stepFine = 0.25;
  speedNormal.contrastRatio = 0.75;
  speedNormal.retriggerRatio = 0.8;
  speedNormal.retriggerDelay = 10;
  speedNormal.maxSlew = 1.5;
  speedNormal.stepFrames = 5;

  // "speeds": { "fast": { ... } };上游 fast 的 step_fine 是 0.0(不做细扫)。
  PwAfSpeedParams speedFast;
  speedFast.stepCoarse = 1.25;
  speedFast.stepFine = 0.0;
  speedFast.contrastRatio = 0.75;
  speedFast.retriggerRatio = 0.8;
  speedFast.retriggerDelay = 8;
  speedFast.maxSlew = 2.0;
  speedFast.stepFrames = 4;

  cfg.speeds[static_cast<int>(PwAfSpeed::Normal)] = speedNormal;
  cfg.speeds[static_cast<int>(PwAfSpeed::Fast)] = speedFast;

  cfg.skipFrames = 5;  // "skip_frames": 5

  // "map": [0.0, 445, 15.0, 925] 的定义域;值域(硬件位置)在 lens_scale(D11)。
  cfg.lensMin = 0.0;
  cfg.lensMax = 15.0;

  cfg.macroFirst = true;  // D8
  return cfg;
}

PwAfScan::PwAfScan(const PwAfConfig& cfg) : cfg_(cfg) {
  scanData_.reserve(32);  // af.cpp:217
}

// D15:range 级 step_fine 覆盖。fast 档 step_fine = 0.0 的语义是「这个速度档
// 不做细扫」(imx708.json speeds.fast.step_fine = 0.0),那是速度档的决定,
// range 的覆盖不许推翻它。
double PwAfScan::StepFine() const {
  const double base = Speed().stepFine;
  if (base <= 0.0) {
    return base;
  }
  const double ov = Range().stepFineOverride;
  return ov > 0.0 ? ov : base;
}

// ——— af.cpp:502-533 `Af::findPeak` ———
// 取最高点与它两侧的邻点(位于扫描端点时取同侧),抛物线拟合求最佳镜头位置。
// 上游注释:"Adapted from awb.cpp: interpolateQaudaratic()"。
double PwAfScan::FindPeak(size_t i) const {
  double f = scanData_[i].focus;

  if (scanData_.size() >= 3) {
    if (i == 0) {
      i++;  // af.cpp:514-515
    } else if (i + 1 >= scanData_.size()) {
      i--;  // af.cpp:516-517
    }

    const double abx = scanData_[i - 1].focus - scanData_[i].focus;
    const double aby = scanData_[i - 1].contrast - scanData_[i].contrast;
    const double cbx = scanData_[i + 1].focus - scanData_[i].focus;
    const double cby = scanData_[i + 1].contrast - scanData_[i].contrast;
    const double denom = 2.0 * (aby * cbx - cby * abx);
    // af.cpp:524 —— 分母不够大或符号不对就不用拟合,直接取样本点。
    if (std::abs(denom) >= (1.0 / 64.0) && denom * abx > 0.0) {
      f = (aby * cbx * cbx - cby * abx * abx) / denom;
      f = std::clamp(f, std::min(abx, cbx), std::max(abx, cbx));
      f += scanData_[i].focus;
    }
  }

  return f;
}

// ——— af.cpp:535-586 `Af::doScan` ———
// 记录本步的 {位置, 对比度};判断是否该结束这一段扫描;安排下一步。
void PwAfScan::DoScan(double contrast) {
  samplesConsumed_++;

  // af.cpp:538-546
  if (scanData_.empty() || contrast > scanMaxContrast_) {
    scanMaxContrast_ = contrast;
    scanMaxIndex_ = scanData_.size();
    // af.cpp:541-542:粗扫期间把「峰处的场景亮度」记下来作为重触发的基准。
    if (scanState_ != ScanState::Fine) {
      oldSceneAverage_ = prevAverage_;
    }
  }
  if (contrast < scanMinContrast_) {
    scanMinContrast_ = contrast;
  }
  scanData_.push_back(ScanRecord{ftarget_, contrast});

  // af.cpp:548-551 —— 四个终止条件:撞上界 / 撞下界 / 细扫已 3 点 /
  // 对比度跌破 contrastRatio × 本段最大值(这一条就是「首峰即停」)。
  if ((scanStep_ >= 0.0 && ftarget_ >= Range().focusMax) ||
      (scanStep_ <= 0.0 && ftarget_ <= Range().focusMin) ||
      (scanState_ == ScanState::Fine && scanData_.size() >= 3) ||
      contrast < Speed().contrastRatio * scanMaxContrast_) {
    const double pk = FindPeak(scanMaxIndex_);
    // af.cpp:553-558 原注释:
    //   一段扫描结束(撞界或对比度掉下来)。若这是第一次粗扫且没把峰夹住,
    //   反向;若这是细扫或没定义细扫步长,就结束;否则反向开始细扫。
    if (scanState_ == ScanState::Coarse1 &&
        scanData_[0].contrast >= Speed().contrastRatio * scanMaxContrast_) {
      // af.cpp:559-562
      scanStep_ = -scanStep_;
      scanState_ = ScanState::Coarse2;
    } else if (scanState_ == ScanState::Fine || StepFine() <= 0.0) {
      // af.cpp:563-565
      ftarget_ = pk;
      scanState_ = ScanState::Settle;
    } else if (scanStep_ >= 0.0) {
      // af.cpp:570-574。(af.cpp:566-569 的 else-if 与 :559 同条件,是死分支,
      //  按 D9 不抄。)
      ftarget_ = std::min(pk + StepFine(), Range().focusMax);
      scanStep_ = -StepFine();
      scanState_ = ScanState::Fine;
    } else {
      // af.cpp:575-580
      ftarget_ = std::max(pk - StepFine(), Range().focusMin);
      scanStep_ = StepFine();
      scanState_ = ScanState::Fine;
    }
    scanData_.clear();  // af.cpp:581
  } else {
    ftarget_ += scanStep_;  // af.cpp:583
  }

  // af.cpp:585 —— 位置没动就不用等;动了就等 stepFrames 帧让镜头整定。
  stepCount_ = (ftarget_ == fsmooth_) ? 0 : Speed().stepFrames;
}

// ——— af.cpp:588-690 `Af::doAF`,已删 PDAF 与相位早停(D1)———
void PwAfScan::DoAf(double contrast) {
  // af.cpp:590-595 —— 启动与模式切换后跳帧。
  if (skipCount_ > 0) {
    skipCount_--;
    return;
  }

  // af.cpp:604-605
  if (mode_ == PwAfMode::Manual) {
    return;
  }

  if (scanState_ < ScanState::Coarse1 && mode_ == PwAfMode::Continuous) {
    // af.cpp:638-657 —— 连续模式、不在扫描中:等场景变化,变完还要稳一段。
    // D5:上游八项(对比度双向 + AWB R/G/B 各双向)在这里是四项
    // (对比度双向 + 单项亮度双向);没有亮度输入时只剩对比度两项。
    const double ratio = Speed().retriggerRatio;
    bool changed = contrast + 1.0 < ratio * oldSceneContrast_ ||
                   oldSceneContrast_ + 1.0 < ratio * contrast;
    if (!changed && haveAverage_) {
      changed = prevAverage_ + 1.0 < ratio * oldSceneAverage_ ||
                oldSceneAverage_ + 1.0 < ratio * prevAverage_;
    }
    if (changed) {
      // af.cpp:651-653
      oldSceneContrast_ = contrast;
      oldSceneAverage_ = prevAverage_;
      sceneChangeCount_ = 1;
    } else if (sceneChangeCount_ != 0) {
      sceneChangeCount_++;  // af.cpp:654-655
    }
    if (sceneChangeCount_ >= Speed().retriggerDelay) {
      // af.cpp:656-657 —— 「变了、而且又停下来了」才重扫,这是防振荡的承重墙。
      retriggeredThisFrame_ = true;
      StartProgrammedScan();
    }
  } else if (scanState_ >= ScanState::Coarse1 && fsmooth_ == ftarget_) {
    // af.cpp:658-689 —— CDAF 扫描序列。每步之间留出整定时间,末尾留 settle。
    if (stepCount_ > 0) {
      stepCount_--;  // af.cpp:666-667
    } else if (scanState_ == ScanState::Settle) {
      // af.cpp:668-682 —— 稳定判据:峰够尖(既够高、谷也够低)才算 Focused,
      // 否则老实报 Failed,不硬报成功。
      if (prevContrast_ >= Speed().contrastRatio * scanMaxContrast_ &&
          scanMinContrast_ <= Speed().contrastRatio * scanMaxContrast_) {
        reportState_ = PwAfState::Focused;
      } else {
        reportState_ = PwAfState::Failed;
      }
      // af.cpp:674-678:上游在连续模式下回 Pdaf;我们没有 Pdaf,一律回 Idle
      // (D7,等价于上游 dropoutFrames == 0 的既有分支)。
      scanState_ = ScanState::Idle;
      sceneChangeCount_ = 0;
      oldSceneContrast_ = std::max(scanMaxContrast_, prevContrast_);
      scanData_.clear();
      scanFinishedThisFrame_ = true;
    } else {
      // af.cpp:688(:683-686 的相位早停按 D1 删)
      DoScan(contrast);
    }
  }
}

// ——— af.cpp:692-711 `Af::updateLensPosition` ———
void PwAfScan::UpdateLensPosition() {
  // af.cpp:694-698。D4:上游写的是 `>= ScanState::Pdaf`,语义为「非 Idle 且非
  // Trigger」,去掉 Pdaf 后等价于 `>= Coarse1`。
  if (scanState_ >= ScanState::Coarse1) {
    ftarget_ = std::clamp(ftarget_, Range().focusMin, Range().focusMax);
  }

  if (initted_) {
    // af.cpp:701-704 —— 已知位置:每帧移动量受 maxSlew 限制。
    fsmooth_ = std::clamp(ftarget_, fsmooth_ - Speed().maxSlew,
                          fsmooth_ + Speed().maxSlew);
  } else {
    // af.cpp:705-710 —— 未知位置:直接到位,但补一段跳帧延迟。
    fsmooth_ = ftarget_;
    initted_ = true;
    skipCount_ = cfg_.skipFrames;
  }
}

// ——— af.cpp:713-734 `Af::startAF` ———
// 上游在这里二选一:调参允许就走 PDAF 闭环,否则走程序扫描。我们没有 PDAF
// (D1)⇒ 只剩 af.cpp:730-733 的 else 分支。
void PwAfScan::StartAf() {
  StartProgrammedScan();
  UpdateLensPosition();
}

// ——— af.cpp:736-757 `Af::startProgrammedScan` ———
void PwAfScan::StartProgrammedScan() {
  if (cfg_.macroFirst) {
    // 【D8 近焦优先】固定从 focusMax(最近端)起、步长取负(向远扫)、
    // 直接进 Coarse2(单向扫,不走 :559-562 的反向分支)。
    // 配合 DoScan 的 af.cpp:551「对比度跌破 contrastRatio×max 即停」
    // ⇒ 首峰即停 ⇒ 多峰时天然取最近的那个峰。
    // 判决书 §6.1:这是「参数与起点的选择,不是自研算法」。
    ftarget_ = Range().focusMax;
    scanStep_ = -Speed().stepCoarse;
    scanState_ = ScanState::Coarse2;
  } else if (!initted_ || mode_ != PwAfMode::Continuous ||
             fsmooth_ <= Range().focusMin + 2.0 * Speed().stepCoarse) {
    // af.cpp:738-742 —— 当前靠远端(或还没初始化):从远端起向近扫。
    ftarget_ = Range().focusMin;
    scanStep_ = Speed().stepCoarse;
    scanState_ = ScanState::Coarse2;
  } else if (fsmooth_ >= Range().focusMax - 2.0 * Speed().stepCoarse) {
    // af.cpp:743-746 —— 当前靠近端:从近端起向远扫。
    ftarget_ = Range().focusMax;
    scanStep_ = -Speed().stepCoarse;
    scanState_ = ScanState::Coarse2;
  } else {
    // af.cpp:747-750 —— 居中:从当前位置先向远扫,峰没被夹住再反向。
    scanStep_ = -Speed().stepCoarse;
    scanState_ = ScanState::Coarse1;
  }
  scanMaxContrast_ = 0.0;     // af.cpp:751
  scanMinContrast_ = 1.0e9;   // af.cpp:752
  scanMaxIndex_ = 0;          // af.cpp:753
  scanData_.clear();          // af.cpp:754
  stepCount_ = Speed().stepFrames;      // af.cpp:755
  reportState_ = PwAfState::Scanning;   // af.cpp:756
}

// ——— af.cpp:759-764 `Af::goIdle` ———
void PwAfScan::GoIdle() {
  scanState_ = ScanState::Idle;
  reportState_ = PwAfState::Idle;
  scanData_.clear();
}

// ——— af.cpp:775-829 的 `prepare()` + `process()` 合成一次调用(D6)———
PwAfOutput PwAfScan::Update(const PwAfFrame& frame) {
  scanFinishedThisFrame_ = false;
  retriggeredThisFrame_ = false;

  // process() 那一半:af.cpp:827-828。上游从 ISP 统计算 getContrast 与 AWB
  // 均值;我们直接收调用方算好的度量与亮度(D3/D5)。
  prevContrast_ = frame.focusMeasure;
  if (frame.hasSceneLuma) {
    prevAverage_ = frame.sceneLuma;
    haveAverage_ = true;
  }

  // prepare() 那一半:af.cpp:777-792。
  if (scanState_ == ScanState::Trigger) {
    StartAf();
  }
  if (initted_) {
    DoAf(prevContrast_);
    UpdateLensPosition();
  }

  // af.cpp:805-821 —— 组装上报状态。
  PwAfOutput out;
  if (pauseFlag_) {
    out.pauseState = (scanState_ == ScanState::Idle) ? PwAfPauseState::Paused
                                                     : PwAfPauseState::Pausing;
  } else {
    out.pauseState = PwAfPauseState::Running;
  }

  if (mode_ == PwAfMode::Auto && scanState_ != ScanState::Idle) {
    out.state = PwAfState::Scanning;
  } else if (mode_ == PwAfMode::Manual) {
    out.state = PwAfState::Idle;
  } else {
    out.state = reportState_;
  }

  out.lensValid = initted_;
  out.lensTarget = fsmooth_;
  out.lensMoveRequested =
      initted_ && (!haveEmittedLens_ || lastEmittedLens_ != fsmooth_);
  if (initted_) {
    lastEmittedLens_ = fsmooth_;
    haveEmittedLens_ = true;
  }
  out.scanFinished = scanFinishedThisFrame_;
  out.retriggerRequested = retriggeredThisFrame_;
  out.framesToWait = stepCount_;
  out.samplesConsumed = samplesConsumed_;
  (void)frame.frameIndex;  // 仅供调用方对账,状态机不消费它
  return out;
}

// ——— af.cpp:833-838 `Af::setRange` ———
void PwAfScan::SetRange(PwAfRange r) {
  if (r < PwAfRange::Max) {
    range_ = r;
  }
}

// ——— af.cpp:840-849 `Af::setSpeed`,PDAF 的 stepCount 修正按 D1 删 ———
void PwAfScan::SetSpeed(PwAfSpeed s) {
  if (s < PwAfSpeed::Max) {
    speed_ = s;
  }
}

// ——— af.cpp:929-940 `Af::setMode` ———
void PwAfScan::SetMode(PwAfMode mode) {
  if (mode_ != mode) {
    mode_ = mode;
    pauseFlag_ = false;
    if (mode == PwAfMode::Continuous) {
      scanState_ = ScanState::Trigger;
    } else if (mode != PwAfMode::Auto || scanState_ < ScanState::Coarse1) {
      GoIdle();
    }
  }
}

// ——— af.cpp:922-927 `Af::triggerScan` ———
// 「快门瞬间对焦」= SetMode(Auto) + TriggerScan()。
void PwAfScan::TriggerScan() {
  if (mode_ == PwAfMode::Auto && scanState_ == ScanState::Idle) {
    scanState_ = ScanState::Trigger;
  }
}

// ——— af.cpp:915-920 `Af::cancelScan` ———
void PwAfScan::CancelScan() {
  if (mode_ == PwAfMode::Auto) {
    GoIdle();
  }
}

// ——— af.cpp:947-963 `Af::pause` ———
// 「拍照时冻结镜头」= Pause(Deferred)(扫完再停)。
void PwAfScan::Pause(PwAfPause pause) {
  if (mode_ == PwAfMode::Continuous) {
    if (pause == PwAfPause::Resume && pauseFlag_) {
      pauseFlag_ = false;
      if (scanState_ < ScanState::Coarse1) {
        scanState_ = ScanState::Trigger;
      }
    } else if (pause != PwAfPause::Resume && !pauseFlag_) {
      pauseFlag_ = true;
      if (pause == PwAfPause::Immediate || scanState_ < ScanState::Coarse1) {
        scanState_ = ScanState::Idle;
        scanData_.clear();
      }
    }
  }
}

// ——— af.cpp:889-904 `Af::setLensPosition` ———
// D11:上游钳到 `cfg_.map.domain()`,我们钳到 cfg_.lensMin/lensMax
// (平台单位的换算在 lens_scale)。
bool PwAfScan::SetLensPosition(double internalScale, bool force) {
  bool changed = false;
  if (mode_ == PwAfMode::Manual || force) {
    ftarget_ = std::clamp(internalScale, cfg_.lensMin, cfg_.lensMax);
    changed = !(initted_ && fsmooth_ == ftarget_);
    UpdateLensPosition();
  }
  return changed;
}

// ——— af.cpp:906-913 `Af::getLensPosition` ———
bool PwAfScan::GetLensPosition(double* out) const {
  if (!initted_) {
    return false;
  }
  if (out != nullptr) {
    *out = fsmooth_;
  }
  return true;
}

// ——— af.cpp:877-880 `Af::getDefaultLensPosition` ———
double PwAfScan::GetDefaultLensPosition() const {
  return cfg_.ranges[static_cast<int>(PwAfRange::Normal)].focusDefault;
}

// ——— af.cpp:882-887 `Af::getLensLimits` ———
// 上游原注释:"Limits for manual focus are set by map, not by ranges"。
void PwAfScan::GetLensLimits(double* min, double* max) const {
  if (min != nullptr) {
    *min = cfg_.lensMin;
  }
  if (max != nullptr) {
    *max = cfg_.lensMax;
  }
}

// ——— af.cpp:239-265 `Af::switchMode` 的非 libcamera 部分(D12)———
void PwAfScan::NotifyModeSwitch() {
  // af.cpp:255-263:扫描中途换模式就重启扫描,因为统计口径变了。
  if (scanState_ >= ScanState::Coarse1 && scanState_ < ScanState::Settle) {
    StartProgrammedScan();
    UpdateLensPosition();
  }
  skipCount_ = cfg_.skipFrames;  // af.cpp:264
}

}  // namespace pw_af
