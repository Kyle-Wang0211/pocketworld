// auto_capture_governor.dart — 自动采集的决策谓词(纯函数,零 Flutter 依赖)。
//
// 设计见 docs/superpowers/specs/2026-08-19-auto-capture-design.md。
// 几何量由 auto_capture_geometry.dart 算好后传进来;编排在
// auto_capture_controller.dart。本文件不持有任何状态。

import 'live_sfm_publish_policy.dart' show kOfficialMaximumCaptureFrames;
import 'shutter_backpressure_gate.dart' show ShutterPace;
import 'true_parallax.dart' show kCaptureParallaxMinDeg;

/// 视差下限(度)。与 `CaptureCoverageCloud.parallaxMinDeg` **同源同值** ——
/// 那个值 2026-07-11 真机标定过,这里不新造常数。
///
/// 〔2026-08-19 评审改正〕此前这一行是一个各自写死的 `5.0`,而注释已经在
/// 宣称"同源同值"—— 两个数今天相等,但没有任何东西保证下一次重标定会同时
/// 改到两处。现在两边都引 [kCaptureParallaxMinDeg],那句话才是代码保证的事实。
const double kAutoCaptureParallaxMinDeg = kCaptureParallaxMinDeg;

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

/// thermal 桶(ProcessInfo 四档:0 nominal · 1 fair · 2 serious · 3 critical;
/// **<0 = 未知,按冷处理** —— 与 `shutterPaceNext` 的降级口径逐字相同)。
/// 阈值 2 与既有的 `kPaceSoftQueueHot`(那里的"热"也是 `thermalState >= 2`)
/// 同源,不新造分界。
const int kAutoCaptureThermalSerious = 2;
const int kAutoCaptureThermalCritical = 3;

double _paceIntervalSec(ShutterPace pace) {
  switch (pace) {
    case ShutterPace.normal:
      return 1.0;
    case ShutterPace.soft:
      return 2.0;
    case ShutterPace.hard:
      return 3.0;
  }
}

/// 自动拍的 tick 间隔(秒)= **背压档位**与**热态下限**取更长的那个。
/// **只作用于自动拍** —— 手动快门"无论多热、队列多深都立即可拍"那条铁律
/// 不受影响。
///
/// 返回**秒**而不是 Duration:两个调用点(controller、telemetry)拿到 Duration
/// 后做的第一件事都是 `.inMilliseconds / 1000.0` 拆回秒,而 governor 自己的
/// 参数就叫 `tickIntervalSec`、类型就是 double;自动拍刻意不起 Timer(时钟一律
/// 取 ARPose.timestamp),没有任何消费者需要 Duration。
///
/// ### 为什么热态在这里查,而不是去改 `shutterPaceNext`〔2026-08-19 评审改正〕
///
/// spec §7 写的是「热态 critical **只拉长间隔**、不停止」,但 tick 间隔此前
/// 唯一的输入是 [ShutterPace],而 `shutterPaceNext` 对热态的全部处理只是把
/// soft 的**队列**阈值从 6 降到 4(`kPaceSoftQueueHot`)。队列浅的时候 ——
/// 自动拍的常态 —— **任何热档都不会改变 pace**,于是那条承诺在实现里根本
/// 不存在,而自动拍本身就是热源(1 Hz 的 12MP 静照 + 喂帧)。
///
/// 不去改 `shutter_backpressure_gate.dart` 的理由:那是**手动快门也在用**的
/// 既有生产代码,它的输出直接写进 `shutter_pace` 遥测;在那里加一条热态分支
/// 会连手动采集的遥测口径一起改掉,而本次改动的范围只有自动拍。
/// 所以分工是:`shutterPaceNext` 继续只回答"队列有多堵"(两条路共用),
/// 热态对**间隔**的影响收在这一个自动拍独有的函数里。
double autoCaptureTickIntervalSec({
  required ShutterPace pace,
  required int thermalState,
}) {
  final byPace = _paceIntervalSec(pace);
  // 热态下限:serious ⇒ 至少 soft 档,critical ⇒ 至少 hard 档。
  // 档位不新造数字,直接取 soft / hard 那两档的间隔。
  final double byThermal;
  if (thermalState >= kAutoCaptureThermalCritical) {
    byThermal = _paceIntervalSec(ShutterPace.hard);
  } else if (thermalState >= kAutoCaptureThermalSerious) {
    byThermal = _paceIntervalSec(ShutterPace.soft);
  } else {
    byThermal = 0.0;
  }
  return byPace > byThermal ? byPace : byThermal;
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
