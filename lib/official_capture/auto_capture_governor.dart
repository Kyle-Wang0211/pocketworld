// auto_capture_governor.dart — 自动采集的决策谓词(纯函数,零 Flutter 依赖)。
//
// 设计见 docs/superpowers/specs/2026-08-19-auto-capture-design.md。
// 几何量由 auto_capture_geometry.dart 算好后传进来;编排在
// auto_capture_controller.dart。本文件不持有任何状态。
//
// 生产入口只有 [autoCaptureDecideMotion]：距离、固定 0.28×深度和“位移 OR
// 转角”旧判据已经删除，避免迁移完成后被误接回去。

import 'live_sfm_publish_policy.dart' show kOfficialMaximumCaptureFrames;
import 'auto_capture_geometry.dart' show AutoCaptureMotionMetrics;
import 'shutter_backpressure_gate.dart' show ShutterPace;

/// 单次自动采集的时间上限(秒)。依据两条独立吻合:Scaniverse 官方
/// 每次扫描硬上限 5 分钟；它与照片间隔是独立的热天花板。
const double kAutoCaptureTimeLimitSec = 300.0;

enum AutoCaptureDecision {
  fire,
  skipNotMoved,
  skipPaced,

  /// 运动已够格开火,但**当前画面比本段的典型锐度糊**——缓一拍,等下一个
  /// 更锐的瞬间再拍。
  ///
  /// 〔2026-08-25,抄单第 2 项,跨端版〕判据 = 当前锐度 < **本段锐度中位**:
  ///   · 锐度来自 FrameQualityReport(128 灰度缩略图上的纯 Dart Laplacian,
  ///     设计初衷就是"四端一份实现",iOS/Android/Web/HarmonyOS 同一段代码
  ///     —— 见 ar_pose.dart 该字段的注释原文);**不用任何平台私有信号**;
  ///   · "本段" = 距上一次开火以来 —— 正是 AliceVision KeyframeSelection
  ///     的 subsequence 概念(两个关键帧之间),它的择优也是段内**相对**排序、
  ///     无绝对阈值(源码注释在案),中位数是本仓一贯的稳健尺;
  ///   · Apple ObjectCaptureSession 同语义:"automatically select image
  ///     shots with **good sharpness**, clarity, and exposure";
  ///   · 我们的 12MP 主图是开火瞬间才拍的,没有事后可挑的 12MP 流(高分
  ///     静照是一次性请求,连拍的热/时间成本不可行)——但**判断**只需要
  ///     缩略图流,所以"事后挑流"翻译成"事前缓到段内下一个达标瞬间",
  ///     用户视角仍是实时拍摄。
  /// 缓拍上限 [kAutoCaptureBlurDeferMaxSec]:覆盖(无损铁律)压过锐度,
  /// 一直糊就照拍,绝不为锐度丢覆盖。
  skipBlurry,
  skipTracking,
  skipCapped,
  skipTimeLimit,
}

/// 画质缓拍的上限(秒)。复用去抖地板的量级(0.25s,3DSeen 先例)而非新造
/// 数:缓拍语义上就是"再等一拍",一拍的长度系统里已有定义。
const double kAutoCaptureBlurDeferMaxSec = 0.25;

/// 正常档只保留防重复触发的 250 ms 去抖，不把秒数冒充摄影测量参数。
/// RealityScan 与 Polycam 的公开口径都是“按检测到的运动拍”；Meshroom 的
/// 视频关键帧窗口也按帧数而非固定秒数表达。是否值得拍由几何/重叠决定，
/// 真实吞吐上限继续交给现役 ShutterPace 背压。
const double kAutoCaptureNormalIntervalSec = 0.25;

/// 所有角色共同守住的 250 ms 防连击地板；重叠安全帧只绕过 soft/hard
/// 背压的加长节奏，不能绕过这条地板。
const double kAutoCaptureSafetyDebounceSec = 0.25;

/// thermal 桶(ProcessInfo 四档:0 nominal · 1 fair · 2 serious · 3 critical;
/// **<0 = 未知,按冷处理** —— 与 `shutterPaceNext` 的降级口径逐字相同)。
/// 阈值 2 与既有的 `kPaceSoftQueueHot`(那里的"热"也是 `thermalState >= 2`)
/// 同源,不新造分界。
const int kAutoCaptureThermalSerious = 2;
const int kAutoCaptureThermalCritical = 3;

double _paceIntervalSec(ShutterPace pace) {
  switch (pace) {
    case ShutterPace.normal:
      return kAutoCaptureNormalIntervalSec;
    case ShutterPace.soft:
      return 2.0;
    case ShutterPace.hard:
      return 3.0;
  }
}

/// 四类运动判据的唯一决策门。
AutoCaptureDecision autoCaptureDecideMotion({
  required bool trackingNormal,
  required int capturedCount,
  required double elapsedSec,
  required double sinceLastTickSec,
  required double tickIntervalSec,
  required AutoCaptureMotionMetrics motion,
  bool blurry = false,
  double blurDeferredSec = 0,
}) {
  if (capturedCount >= kOfficialMaximumCaptureFrames) {
    return AutoCaptureDecision.skipCapped;
  }
  if (elapsedSec >= kAutoCaptureTimeLimitSec) {
    return AutoCaptureDecision.skipTimeLimit;
  }
  if (!trackingNormal) return AutoCaptureDecision.skipTracking;
  if (!motion.shouldCapture) return AutoCaptureDecision.skipNotMoved;

  if (sinceLastTickSec < kAutoCaptureSafetyDebounceSec) {
    return AutoCaptureDecision.skipPaced;
  }
  if (!motion.isOverlapSafety && sinceLastTickSec < tickIntervalSec) {
    return AutoCaptureDecision.skipPaced;
  }

  // 覆盖即将断开时不能为了等清晰帧而丢掉连接；其它三类仍可在 250 ms 内
  // 等待段内更锐的一帧。
  if (!motion.isOverlapSafety &&
      blurry &&
      blurDeferredSec < kAutoCaptureBlurDeferMaxSec) {
    return AutoCaptureDecision.skipBlurry;
  }
  return AutoCaptureDecision.fire;
}

/// 自动拍两次开火之间的最小间隔(秒)= **背压档位**与**热态下限**取更长的。
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
/// 不存在,而自动拍本身就是热源(12MP 静照 + 喂帧)。
///
/// 不去改 `shutter_backpressure_gate.dart` 的理由:那是**手动快门也在用**的
/// 既有生产代码,它的输出直接写进 `shutter_pace` 遥测;在那里加一条热态分支
/// 会连手动采集的遥测口径一起改掉。所以分工是:`shutterPaceNext` 继续只回答
/// "队列有多堵"(两条路共用),热态对**间隔**的影响收在这一个自动拍独有的
/// 函数里。
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
