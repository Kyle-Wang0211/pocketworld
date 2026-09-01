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

  /// Exact continuous-feature evidence proves insufficient novelty relative to
  /// the last accepted actual photo. A 16×16 block signature cannot authorize
  /// a camera shutter.
  skipRedundant,

  /// 运动已够格开火，但当前画面未通过 Aether3D 的原版帧级清晰度硬门。
  ///
  /// 判据逐字复用 [FrameQualityConstants.blurThresholdLaplacian] (=200)：
  /// 128×128 灰度缩略图由平台桥搬运，Laplacian variance 在 Dart 统一计算。
  /// 历史段内相对锐度不能当作客观模糊硬门，也不能超时放行。
  skipBlurry,

  /// The preview candidate is objectively under- or over-exposed according
  /// to the shared Aether3D 60..200 mean-luma hard gate.
  skipQuality,
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
  bool blurry = false,
  bool exposureRejected = false,
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
    final hasRealtimeKeyframeSupport =
        trackEvidence.lostTrackedOverlap &&
        trackEvidence.isVinsEstimatorKeyframeCandidate;
    if (!trackEvidence.isCaptureNoveltyVerified &&
        !hasRealtimeKeyframeSupport) {
      return trackEvidence.comparable
          ? AutoCaptureDecision.skipRedundant
          : AutoCaptureDecision.skipNoVisualEvidence;
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

  // 质量是**缓拍**，不是否决 —— 抄 AliceVision。
  //
  // 它的 `processSmart` 里锐度从不拒绝任何一帧：位移累积切出子段
  // (`KeyframeSelector.cpp`，`motionAcc >= step`)，每个子段**无条件**产出
  // 一帧，锐度只在段内决定“交哪一张”(Step 3，bestIndex)。RTAB-Map 更彻底，
  // 它的 `Parameters.h` 里根本没有任何 blur/quality 参数。三家上游没有一家
  // 把画质做成拒绝闸。
  //
  // 我们原来是硬拒绝：糊就不拍、基准不动、等下一份清晰样本。代价是**这一段
  // 可能一张照片都没有** —— 那正是 AliceVision 构造性排除的情况。
  //
  // 在线不能回头挑段内最锐的那张，所以改成：位移攒够后允许为等更锐的帧而缓
  // 拍，但一旦位移攒到下一个段边界([AutoCaptureMotion.segmentOverdue]，即
  // 2×门槛)就必须交出当前这一帧 —— 交一张糊的，也好过整段空着。
  if (blurry && !motion.segmentOverdue) return AutoCaptureDecision.skipBlurry;
  if (exposureRejected && !motion.segmentOverdue) {
    return AutoCaptureDecision.skipQuality;
  }
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
