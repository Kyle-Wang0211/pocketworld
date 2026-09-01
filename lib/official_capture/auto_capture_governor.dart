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
import 'continuous_feature_tracks.dart' show FrameTrackEvidence;
import '../official_quality/frame_quality_constants.dart';
import 'shutter_backpressure_gate.dart' show ShutterPace;

/// 单次自动采集的时间上限(秒)。依据两条独立吻合:Scaniverse 官方
/// 每次扫描硬上限 5 分钟；它与照片间隔是独立的热天花板。
const double kAutoCaptureTimeLimitSec = 300.0;

enum AutoCaptureDecision {
  fire,
  skipNotMoved,
  skipPaced,

  /// A spatial candidate arrived on a pose-only tick. Auto capture waits for
  /// the next cross-platform grayscale sample instead of guessing from VIO.
  skipNoVisualEvidence,

  /// The current 16×16 grayscale signature is too similar to the last photo
  /// that actually entered the shutter queue (Aether3D threshold: 0.92).
  skipRedundant,

  /// 运动已够格开火，但当前画面未通过 Aether3D 的原版帧级清晰度硬门。
  ///
  /// 判据逐字复用 [FrameQualityConstants.blurThresholdLaplacian] (=200)：
  /// 128×128 灰度缩略图由平台桥搬运，Laplacian variance 在 Dart 统一计算。
  /// AliceVision 的段内相对锐度只用于候选排序，不能当作客观模糊硬门；
  /// Apple Object Capture 的 movingTooFast 同样会暂停自动拍摄而非超时放行。
  skipBlurry,
  skipTracking,
  skipCapped,
  skipTimeLimit,
}

/// 正常档只保留防重复触发的 250 ms 去抖，不把秒数冒充摄影测量参数。
/// RealityScan 与 Polycam 的公开口径都是“按检测到的运动拍”；Meshroom 的
/// 视频关键帧窗口也按帧数而非固定秒数表达。是否值得拍由几何/重叠决定，
/// 真实吞吐上限继续交给现役 ShutterPace 背压。
const double kAutoCaptureNormalIntervalSec = 0.25;

/// 所有角色共同守住的 250 ms 防连击地板。队列压力与热态只记遥测，
/// 不得改变这个值；否则是用后台吞吐能力代替摄影测量取帧判定。
const double kAutoCaptureSafetyDebounceSec = 0.25;

/// thermal 桶(ProcessInfo 四档:0 nominal · 1 fair · 2 serious · 3 critical;
/// **<0 = 未知,按冷处理** —— 与 `shutterPaceNext` 的降级口径逐字相同)。
/// 阈值 2 与既有的 `kPaceSoftQueueHot`(那里的"热"也是 `thermalState >= 2`)
/// 同源,不新造分界。
const int kAutoCaptureThermalSerious = 2;
const int kAutoCaptureThermalCritical = 3;

/// 四类运动判据的唯一决策门。
AutoCaptureDecision autoCaptureDecideMotion({
  required bool trackingNormal,
  required int capturedCount,
  required double elapsedSec,
  required double sinceLastTickSec,
  required double tickIntervalSec,
  required AutoCaptureMotionMetrics motion,
  required double? visualSimilarity,
  FrameTrackEvidence? trackEvidence,
  bool trackEvidenceRequired = false,
  bool smartSelectionMotionReady = false,
  bool blurry = false,
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
  if (sinceLastTickSec < tickIntervalSec) {
    return AutoCaptureDecision.skipPaced;
  }
  if (trackEvidenceRequired) {
    if (trackEvidence == null) {
      return AutoCaptureDecision.skipNoVisualEvidence;
    }
    if (!trackEvidence.comparable) {
      return AutoCaptureDecision.skipNoVisualEvidence;
    }
    if (!smartSelectionMotionReady) {
      return AutoCaptureDecision.skipRedundant;
    }
  } else {
    // Compatibility path for old fixtures/platforms that have not yet attached
    // the exact gray source. Production iOS attaches it, so block-mean
    // similarity cannot independently authorize a shutter there.
    if (visualSimilarity == null) {
      return AutoCaptureDecision.skipNoVisualEvidence;
    }
    if (visualSimilarity > FrameQualityConstants.maxFrameSimilarity) {
      return AutoCaptureDecision.skipRedundant;
    }
  }

  // 糊片对 SfM 没有可恢复的特征价值；空间覆盖不能把质量硬门绕开。
  // 基准仍停在上一张真实照片，待下一份清晰视觉样本继续判断。
  if (blurry) return AutoCaptureDecision.skipBlurry;
  return AutoCaptureDecision.fire;
}

/// 自动拍两次开火之间只保留 250 ms 防连击地板。
///
/// [pace] 和 [thermalState] 刻意保留在函数签名中，以免破坏现有遥测接线；
/// 但它们只描述后台队列/设备状态，不是画面是否有新几何信息的证据。
/// 同行关键帧选择用共视、真实特征匹配、视差和清晰度；队列深度不参与。
double autoCaptureTickIntervalSec({
  required ShutterPace pace,
  required int thermalState,
}) {
  return kAutoCaptureSafetyDebounceSec;
}
