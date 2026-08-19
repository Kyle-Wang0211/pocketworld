// auto_capture_governor.dart — 自动采集的决策谓词(纯函数,零 Flutter 依赖)。
//
// 设计见 docs/superpowers/specs/2026-08-19-auto-capture-design.md。
// 几何量由 auto_capture_geometry.dart 算好后传进来;编排在
// auto_capture_controller.dart。本文件不持有任何状态。

import 'live_sfm_publish_policy.dart' show kOfficialMaximumCaptureFrames;
import 'shutter_backpressure_gate.dart' show ShutterPace;

/// 视差下限(度)。与 capture_coverage_cloud.dart 的 `parallaxMinDeg`
/// **同源同值** —— 那个值 2026-07-11 真机标定过,这里不新造常数。
const double kAutoCaptureParallaxMinDeg = 5.0;

/// 视线转角下限(度)。⚠️ 无外部依据(RS / Polycam / KIRI / Apple 均未公开
/// 自动拍阈值),这是比视差门放宽一倍取的保守起点,**必须真机标定**。
const double kAutoCaptureTurnMinDeg = 10.0;

/// 归一化中心偏移上限。0.30 ⇔ 与基准帧重叠 70%。
/// 依据:KIRI 官方 70%、Polycam Object Mode 70–75%、RealityScan >60%。
const double kAutoCaptureMaxCenterShift = 0.30;

/// 单次自动采集的时间上限(秒)。依据两条独立吻合:Scaniverse 官方
/// 每次扫描硬上限 5 分钟;且 1 张/秒 × 300 张 = 5 分钟。
const double kAutoCaptureTimeLimitSec = 300.0;

enum AutoCaptureDecision {
  fire,
  skipNotMoved,
  skipPaced,
  skipTracking,
  skipCapped,
  skipTimeLimit,
}

/// tick 间隔随背压分级拉长。**只作用于自动拍** —— 手动快门"无论多热、
/// 队列多深都立即可拍"那条铁律不受影响。
Duration autoCaptureTickInterval(ShutterPace pace) {
  switch (pace) {
    case ShutterPace.normal:
      return const Duration(seconds: 1);
    case ShutterPace.soft:
      return const Duration(seconds: 2);
    case ShutterPace.hard:
      return const Duration(seconds: 3);
  }
}

/// 判定顺序即优先级,不可随意调换:
///   张数上限 > 时间上限 > tracking > 重叠上限(R2) > tick 闸 > 位移下限(R1)
///
/// 重叠上限排在 tick 闸**之前**,是因为它治的是"走得快,1 秒已跨过重叠下限"
/// —— 那种情况按 1s 节奏拍会拍出 RealityScan 官方警告的断裂组件。
///
/// [centerShift] 直接收 `normalizedCenterShift` 的返回值,**不必解包**:
/// null 意为"上限判据求不出来"(内参/画幅不可用,spec §7),此时跳过 R2、
/// 只用下限判据决定;`double.infinity` 意为"确定越过了上限"(目标已跑到
/// 相机背后),立刻拍。T1 刻意把这两件事分成两个值,这一层就得原样守住 ——
/// 把"不知道"折成"马上开火"正是那条裁定要防的事。
AutoCaptureDecision autoCaptureDecide({
  required bool trackingNormal,
  required int capturedCount,
  required double elapsedSec,
  required double sinceLastTickSec,
  required double tickIntervalSec,
  required double parallaxDeg,
  required double turnDeg,
  required double? centerShift,
}) {
  if (capturedCount >= kOfficialMaximumCaptureFrames) {
    return AutoCaptureDecision.skipCapped;
  }
  if (elapsedSec >= kAutoCaptureTimeLimitSec) {
    return AutoCaptureDecision.skipTimeLimit;
  }
  if (!trackingNormal) return AutoCaptureDecision.skipTracking;
  // null = 上限判据无法求值(内参/画幅不可用,见 spec §7)。此时**跳过** R2,
  // 只用下限判据决定 —— 绝不能当成"立刻拍"。+inf 与 null 是刻意区分的两件事:
  // +inf 意为"确定越过上限"(目标已跑到相机背后),null 意为"不知道"。
  // 把"不知道"编码成"马上开火"正是这道判断存在的理由。
  final shift = centerShift;
  if (shift != null && shift >= kAutoCaptureMaxCenterShift) {
    return AutoCaptureDecision.fire;
  }
  if (sinceLastTickSec < tickIntervalSec) return AutoCaptureDecision.skipPaced;
  if (parallaxDeg >= kAutoCaptureParallaxMinDeg ||
      turnDeg >= kAutoCaptureTurnMinDeg) {
    return AutoCaptureDecision.fire;
  }
  return AutoCaptureDecision.skipNotMoved;
}
