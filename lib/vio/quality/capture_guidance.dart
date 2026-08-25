// capture_guidance.dart — 采集引导信号(条目 11 的第 4 条)。纯 Dart,零 Flutter。
//
// ── 这是引导,不是设置 ──────────────────────────────────────────────────
// 铁律:**禁止用户可见的质量滑杆/档位**。所以本文件产出的东西有两条硬约束:
//   1. 只描述**当前这一刻缺什么**,不描述「质量等级」。没有 low/medium/high,
//      没有星级,没有分数条。[CaptureGuidance.progress01] 是「离达标还差多少」
//      的进度,达标即消失 —— 它是任务进度,不是质量刻度。
//   2. 没有任何 setter。用户不能调它,UI 也不能拿它当开关。
// 单测 `guidance exposes no quality tier` 用穷举 enum 的方式钉第 1 条。
//
// ── 优先级:一次只说一句话 ──────────────────────────────────────────────
// 同时有三件事不对的时候,喊三句等于没喊。顺序按**因果链**排,不按严重程度:
//
//   initializing → 地图还没建起来,其余判据这时候全都不可信,先等
//   needTexture  → 纹理不够,位姿本身就是错的,后面全白搭(鬼墙同源场景)
//   spreadView   → 点全挤在一角,绕光轴的自由度没约束
//   translate    → 在原地转,基线为零
//   widerBaseline→ 走了但走得不够(b/d < 0.30)
//   breakCadence → 🔴 视差够了但加速度激励不够(电梯/自动步道/匀速滑移)
//   none
//
// [CaptureGuidanceCue.breakCadence] 排最后**不是因为它最不重要,恰恰相反** ——
// 它是唯一一个「画面看起来完全健康」的失效模式,所以只有在前面几条都清了之后
// 才轮得到它说话,否则它会被前面的噪声淹掉。它也是唯一一条会在
// [CaptureGuidance.blocksAbsoluteDimensions] 上留下痕迹却不影响几何交付的。

import 'initialization_window.dart';
import 'scale_observability.dart';
import 'texture_sufficiency.dart';

/// 引导语义。**不是质量档位** —— 见文件头。
enum CaptureGuidanceCue {
  /// 一切达标,不要显示任何东西。
  none,

  /// 地图还在初始化,这几秒的点只做视觉反馈。
  initializing,

  /// 纹理不够(白墙 / 无纹理地板)。
  needTexture,

  /// 点挤在一角,把镜头摆开一点。
  spreadView,

  /// 在原地转 —— 横着走,别只转。
  translate,

  /// 走了,但基线还不够(b/d < 0.30)。
  widerBaseline,

  /// 🔴 视差够了但加速度激励不够:匀速。「停一下再走」/「换个节奏」。
  breakCadence,
}

/// 一次引导结论。
class CaptureGuidance {
  const CaptureGuidance({
    required this.cue,
    required this.progress01,
    required this.neededExtraBaselineMeters,
    required this.cloudPreviewOnly,
    required this.blocksAbsoluteDimensions,
  });

  final CaptureGuidanceCue cue;

  /// 当前这一条 cue 的完成进度 0..1。[CaptureGuidanceCue.none] 时为 1.0。
  /// **任务进度,不是质量刻度** —— 达标即 cue 消失。
  final double progress01;

  /// 还需要横移多少(地图单位)才能满足 b/d ≥ 0.30。不适用时为 0。
  final double neededExtraBaselineMeters;

  /// 本帧实时点云是否只做视觉反馈(来自初始化闸门)。
  final bool cloudPreviewOnly;

  /// 本帧是否处在「不许报绝对尺寸」的状态。注意它与 [cloudPreviewOnly]
  /// **独立**:几何可交付 ≠ 尺寸可标。
  final bool blocksAbsoluteDimensions;

  @override
  String toString() =>
      'CaptureGuidance(${cue.name}, p=${progress01.toStringAsFixed(2)}, '
      'previewOnly=$cloudPreviewOnly, noDims=$blocksAbsoluteDimensions)';
}

/// 把纹理 / 尺度 / 初始化三路信号融成**一句**引导。纯函数,无状态。
///
/// [texture] 缺席按「不充分」算(fail-safe);[scale] 缺席按
/// [ScaleObservabilityVerdict.insufficientData] 算。
CaptureGuidance computeCaptureGuidance({
  required VioFrameDisposition disposition,
  TextureSample? texture,
  ScaleObservabilitySample? scale,
  TextureConfig textureConfig = const TextureConfig(),
  double targetRelativeScaleSigma = 0.01,
}) {
  final previewOnly = disposition.cloudPreviewOnly;
  final verdict = scale?.verdict ?? ScaleObservabilityVerdict.insufficientData;
  final blocksDims = verdict != ScaleObservabilityVerdict.sufficient;
  final needExtra = scale?.neededExtraBaselineMeters ?? 0.0;

  CaptureGuidance make(CaptureGuidanceCue cue, double p) => CaptureGuidance(
    cue: cue,
    progress01: p.isFinite ? p.clamp(0.0, 1.0) : 0.0,
    neededExtraBaselineMeters: needExtra,
    cloudPreviewOnly: previewOnly,
    blocksAbsoluteDimensions: blocksDims,
  );

  // 1. 初始化优先:此时其余判据都还不可信。
  if (disposition.phase != VioInitPhase.converged) {
    final streakP =
        disposition.texturedStreak /
        // 进度只是给 UI 看的,分母取政策值的等价物:streak 达标即 1.0。
        (disposition.texturedStreak > 0 ? disposition.texturedStreak : 1);
    return make(
      CaptureGuidanceCue.initializing,
      disposition.texturedStreak > 0 ? streakP.clamp(0.0, 0.99) : 0.0,
    );
  }

  // 2. 纹理数量 —— 位姿的地基。
  if (texture == null) {
    return make(CaptureGuidanceCue.needTexture, 0.0);
  }
  if (texture.verdict == TextureVerdict.starved ||
      texture.verdict == TextureVerdict.sparse) {
    return make(
      CaptureGuidanceCue.needTexture,
      texture.countProgress01(textureConfig.minKeypointCount),
    );
  }

  // 3. 纹理分布。
  if (texture.verdict == TextureVerdict.clustered) {
    return make(
      CaptureGuidanceCue.spreadView,
      texture.distributionProgress01(textureConfig.minEffectiveAreaFraction),
    );
  }

  // 4..6 尺度侧。
  switch (verdict) {
    case ScaleObservabilityVerdict.pureRotation:
      return make(CaptureGuidanceCue.translate, scale?.parallaxProgress01 ?? 0);
    case ScaleObservabilityVerdict.parallaxStarved:
      return make(
        CaptureGuidanceCue.widerBaseline,
        scale?.parallaxProgress01 ?? 0,
      );
    case ScaleObservabilityVerdict.constantVelocity:
      return make(
        CaptureGuidanceCue.breakCadence,
        scale?.excitationProgress01(targetRelativeScaleSigma) ?? 0,
      );
    case ScaleObservabilityVerdict.insufficientData:
      return make(CaptureGuidanceCue.widerBaseline, 0.0);
    case ScaleObservabilityVerdict.sufficient:
      return make(CaptureGuidanceCue.none, 1.0);
  }
}
