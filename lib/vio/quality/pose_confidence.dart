// pose_confidence.dart —— 把 `lib/vio/quality/` 已有的几条判据**汇总成一个
// 可以跟位姿一起往上送的值**。
//
// ══ 它不做什么(先说清,免得被当成新算法)═══════════════════════════════════
// 本文件**不计算任何新的质量量**。纹理、尺度可观测性、初始化窗口三条判据
// 全部已经在同目录下实现完毕(`texture_sufficiency.dart` /
// `scale_observability.dart` / `initialization_window.dart`),各自都有
// 文件头写明出处与已发表依据。本文件只做两件事:
//   ① 把它们的结论装进一个值类型,好让 `ARPoseProvider` 那一层带出来;
//   ② 写死一个**产品容差**,并把「能不能报绝对尺寸」这个二值结论落到它上面。
// 「禁止一切自研」—— 所以这里没有公式,只有搬运和一次比较。
//
// ══ 🔴 那个 5% 是**产品决策**,不是实测值、不是标准值 ═══════════════════════
// [kPwEstimatedDimensionToleranceRelative] = 0.05。
//
// 出处:**产品决策,2026-09-22**。不是从任何论文或标准里读来的数。
// 它对应的是「估算型」这一档产品定位 —— 明说「这是估算,不能用于下料和验收」。
// 决策时摆在桌上的三个候选是 ±1% / ±3% / ±5%(容差调研报告 §6),对照:
//   · RICS《Measured surveys》Band E(净面积/估价测量)= ±50 mm(2σ),
//     在 4 m 上约 1.25% —— **比 5% 严**,我们这一档够不到它;
//   · USIBD C120 LOA20(最常用的 as-built 文档档)= 15 mm–5 cm(2σ);
//   · 带 LiDAR、由 Apple 亲自调优的 RoomPlan 在一个具体房间上也跑出过
//     5.7% 的尺寸误差 ⇒ 5% 量级不是单目独有的失败,是这一整类消费级
//     房间扫描产品的现实表现。
// 🔴 **不要**把这个常量当作「我们的精度是 5%」的证据。它是**允许上限**:
//    超过它就不许报绝对尺寸,低于它也**不**等于实测达标。
//    我们自己测到的 VIO 尺度偏差是 4.13%(09-19 共享录制回放),
//    同场四段跨度 0.73%–10.80% —— 也就是说**单场之内就能越线**,
//    这正是需要一个逐会话判据而不是一个固定承诺的原因。
//
// ══ 与 `ScaleObservabilityConfig.targetRelativeScaleSigma` 的关系 ══════════
// 那个字段默认 0.01,是**滑窗内相对尺度标准差的目标**,口径是 1σ 的统计量;
// 本文件的 5% 是**对外承诺的容差上限**,口径是产品。两者不是一个东西,
// 所以本文件**没有**去改那个默认值 —— 改它会动既有单测和既有行为。

import '../pose/vio_pose_source.dart';
import 'initialization_window.dart';
import 'scale_observability.dart';
import 'texture_sufficiency.dart';

/// 产品容差:估算型真实尺寸的相对误差上限。
///
/// 🔴 **来源 = 产品决策(2026-09-22)**,不是发表值、不是标准值。详见文件头。
const double kPwEstimatedDimensionToleranceRelative = 0.05;

/// 这一帧的位姿到底能拿来干什么。逐档从弱到强,**只升不跳**。
enum VioPoseTrustTier {
  /// 什么都不能做。引擎没出位姿,或位姿几何非法。
  none,

  /// 只有朝向可用(静止起步的 3DOF 兜底)。不能做任何位移相关的判断。
  orientationOnly,

  /// 位姿可用,但**不许报绝对尺寸** —— 尺度可观测性没达标,
  /// 或还在初始化窗口里。预览可以,交付不行。
  poseOnly,

  /// 位姿可用且尺度可观测性达标 ⇒ 可以报绝对尺寸(在
  /// [kPwEstimatedDimensionToleranceRelative] 这一档的意义上)。
  metric,
}

/// 一帧的可信度汇总。**纯数据**,没有任何方法会再去算什么。
class VioPoseConfidence {
  const VioPoseConfidence({
    required this.tier,
    required this.poseStage,
    required this.scaleVerdict,
    required this.initPhase,
    required this.textureVerdict,
    required this.relativeScaleSigma,
    required this.baselineOverDepth,
    required this.mayReportAbsoluteDimensions,
    required this.toleranceRelative,
  });

  /// 什么都没有时的取值。`ARPoseProvider` 在第一帧之前交出它,
  /// 这样消费方永远拿得到一个**非 null** 的可信度。
  static const VioPoseConfidence unknown = VioPoseConfidence(
    tier: VioPoseTrustTier.none,
    poseStage: VioPoseStage.none,
    scaleVerdict: ScaleObservabilityVerdict.insufficientData,
    initPhase: VioInitPhase.bootstrapping,
    textureVerdict: null,
    relativeScaleSigma: double.infinity,
    baselineOverDepth: null,
    mayReportAbsoluteDimensions: false,
    toleranceRelative: kPwEstimatedDimensionToleranceRelative,
  );

  final VioPoseTrustTier tier;

  /// `VioPoseSource` 交出的档位(tracked / lastKnown / orientationOnly / none)。
  final VioPoseStage poseStage;

  /// 尺度可观测性判据的结论。null 从不出现 —— 无样本时是 `insufficientData`。
  final ScaleObservabilityVerdict scaleVerdict;

  /// 初始化窗口的阶段。
  final VioInitPhase initPhase;

  /// 纹理判据。`null` = 这一帧没有关键点信息可判(VIO 没报)。
  final TextureVerdict? textureVerdict;

  /// 窗口内相对尺度标准差(1σ)。无样本 = `double.infinity`。
  final double relativeScaleSigma;

  /// 基线/物距。无样本 = null。
  final double? baselineOverDepth;

  /// 能不能对外报绝对尺寸。
  ///
  /// 🔴 判据是 `scaleVerdict == sufficient && initPhase == converged`,
  /// **不是**拿 [relativeScaleSigma] 去跟 [toleranceRelative] 比 ——
  /// σ 是窗口内的统计离散度,它小**不代表**没有系统性尺度偏差
  /// (我们实测的 4.13% 全局偏差就是一个跨帧一致的系统偏差,σ 对它无感)。
  /// 这一条是 09-20 那次「拿均值的标准误当误差棒」栽过的坑的直接后果。
  final bool mayReportAbsoluteDimensions;

  /// 这一档产品承诺的相对容差。恒等于
  /// [kPwEstimatedDimensionToleranceRelative];做成字段是为了让回执里
  /// 记下**当时**用的是哪个数,而不是读代码去猜。
  final double toleranceRelative;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema_version': 'pw.vio.pose_confidence/1',
    'tier': tier.name,
    'pose_stage': poseStage.name,
    'scale_verdict': scaleVerdict.name,
    'init_phase': initPhase.name,
    'texture_verdict': textureVerdict?.name,
    'relative_scale_sigma': relativeScaleSigma.isFinite
        ? relativeScaleSigma
        : null,
    'baseline_over_depth': baselineOverDepth,
    'may_report_absolute_dimensions': mayReportAbsoluteDimensions,
    'tolerance_relative': toleranceRelative,
    'tolerance_provenance': 'product_decision_2026_09_22',
  };

  @override
  String toString() =>
      'VioPoseConfidence(${tier.name}, stage=${poseStage.name}, '
      'scale=${scaleVerdict.name}, init=${initPhase.name}, '
      'metric=${mayReportAbsoluteDimensions ? 'yes' : 'no'})';
}

/// 把三条既有判据 + 位姿档位汇总成一帧的可信度。
///
/// 纯函数,没有状态 —— 调用方负责持有 `ScaleObservabilityLedger` 之类的
/// 有状态对象并把它们的**结论**传进来。
VioPoseConfidence summarizeVioPoseConfidence({
  required VioPoseStage poseStage,
  ScaleObservabilitySample? scale,
  VioFrameDisposition? disposition,
  TextureSample? texture,
}) {
  final ScaleObservabilityVerdict verdict =
      scale?.verdict ?? ScaleObservabilityVerdict.insufficientData;
  final VioInitPhase phase = disposition?.phase ?? VioInitPhase.bootstrapping;
  final bool metricOk =
      verdict == ScaleObservabilityVerdict.sufficient &&
      phase == VioInitPhase.converged;

  final VioPoseTrustTier tier;
  switch (poseStage) {
    case VioPoseStage.none:
      tier = VioPoseTrustTier.none;
    case VioPoseStage.orientationOnly:
      tier = VioPoseTrustTier.orientationOnly;
    case VioPoseStage.lastKnown:
      // 🔴 lastKnown 交出的是**最后已知**位置,规范明说它 VALID 但不 TRACKED。
      //    拿它报尺寸是错的,所以无论尺度判据多漂亮都封顶在 poseOnly。
      tier = VioPoseTrustTier.poseOnly;
    case VioPoseStage.tracking:
      tier = metricOk ? VioPoseTrustTier.metric : VioPoseTrustTier.poseOnly;
  }

  return VioPoseConfidence(
    tier: tier,
    poseStage: poseStage,
    scaleVerdict: verdict,
    initPhase: phase,
    textureVerdict: texture?.verdict,
    relativeScaleSigma: scale?.relativeScaleSigma ?? double.infinity,
    baselineOverDepth: scale?.baselineOverDepth,
    mayReportAbsoluteDimensions:
        tier == VioPoseTrustTier.metric && metricOk,
    toleranceRelative: kPwEstimatedDimensionToleranceRelative,
  );
}
