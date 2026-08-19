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
/// [centerShift] 是 `normalizedCenterShift` 的**已解包**结果:
/// 几何层拿不到可用内参时返回 null(spec §7),调用方须按"上限判据不可评估"
/// 降级,即传 **0.0**(任何 < [kAutoCaptureMaxCenterShift] 的值等效),
/// 于是只剩下限判据 R1 决定。**绝不可把 null 翻译成 `double.infinity`** ——
/// 那等于把"不知道"编码成"马上开火"。目标真跑到相机背后时几何层返回的
/// +inf 才是"确实越过了上限",照直传即可。
AutoCaptureDecision autoCaptureDecide({
  required bool trackingNormal,
  required int capturedCount,
  required double elapsedSec,
  required double sinceLastTickSec,
  required double tickIntervalSec,
  required double parallaxDeg,
  required double turnDeg,
  required double centerShift,
}) {
  if (capturedCount >= kOfficialMaximumCaptureFrames) {
    return AutoCaptureDecision.skipCapped;
  }
  if (elapsedSec >= kAutoCaptureTimeLimitSec) {
    return AutoCaptureDecision.skipTimeLimit;
  }
  if (!trackingNormal) return AutoCaptureDecision.skipTracking;
  if (centerShift >= kAutoCaptureMaxCenterShift) {
    return AutoCaptureDecision.fire;
  }
  if (sinceLastTickSec < tickIntervalSec) return AutoCaptureDecision.skipPaced;
  if (parallaxDeg >= kAutoCaptureParallaxMinDeg ||
      turnDeg >= kAutoCaptureTurnMinDeg) {
    return AutoCaptureDecision.fire;
  }
  return AutoCaptureDecision.skipNotMoved;
}
