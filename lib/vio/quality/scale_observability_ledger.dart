// scale_observability_ledger.dart — 会话级尺度可观测性台账 + 交付层闸门。
//
// ── 产品级约定(这是本文件存在的全部理由)────────────────────────────────
//   交付层**只有在** [ScaleObservabilityReport.mayReportAbsoluteDimensions]
//   为 true 时才允许把重建结果标注成绝对尺寸(「这面墙 3.2 m」)。false 时
//   照样交付几何、照样交付点云,只是**不许标数字**。
//
// ── 铁律对齐 ──────────────────────────────────────────────────────────
//   「交付绝对无损,永久缺帧绝对禁止,fail-safe 只许推迟不许丢数据」
//   ⇒ 本台账**只打标,不过滤**。它没有任何 API 能删帧、跳帧或丢点。
//     [degradedIntervals] 是给交付层/离线管线读的**注释**,不是黑名单。
//     单测 `ledger never drops frames` 就是钉这一条的。
//
// ── 为什么阈值分两类,以及哪些是「政策」不是「物理」──────────────────────
//   物理侧(scale_observability.dart 里推导过的)决定**单窗口**是否
//   sufficient。会话侧「多少个 sufficient 窗口才算够」是**产品政策**,推不出
//   来,所以这里全部显式命名为 policy 并给默认值,不假装是推导结果:
//     minSufficientSeconds = 1.0   至少要有一段连续 1 s 的可观测窗口
//     minSufficientRatio   = 0.15  且全程至少 15% 的时间是可观测的
//   两条**同时**满足才放行。前者保证「尺度至少被观测过一次」,后者防止一整
//   段电梯里只有起步那一下的抖动被当成证据。

import 'scale_observability.dart';

/// 一段连续同结论的时间区间(供交付层/离线管线打标)。
class ScaleObservabilityInterval {
  const ScaleObservabilityInterval(this.startSec, this.endSec, this.verdict);
  final double startSec;
  final double endSec;
  final ScaleObservabilityVerdict verdict;
  double get durationSec => endSec - startSec;

  @override
  String toString() =>
      '[${startSec.toStringAsFixed(2)}..${endSec.toStringAsFixed(2)}] ${verdict.name}';
}

/// 会话级快照。
class ScaleObservabilityReport {
  const ScaleObservabilityReport({
    required this.totalSeconds,
    required this.sufficientSeconds,
    required this.longestSufficientRunSeconds,
    required this.constantVelocitySeconds,
    required this.pureRotationSeconds,
    required this.parallaxStarvedSeconds,
    required this.intervals,
    required this.mayReportAbsoluteDimensions,
    required this.bestBaselineOverDepth,
    required this.bestRelativeScaleSigma,
  });

  final double totalSeconds;
  final double sufficientSeconds;
  final double longestSufficientRunSeconds;
  final double constantVelocitySeconds;
  final double pureRotationSeconds;
  final double parallaxStarvedSeconds;

  /// 全部区间,时间升序,同结论已合并。**注释,不是黑名单**。
  final List<ScaleObservabilityInterval> intervals;

  /// 🔑 交付层唯一需要读的字段。
  final bool mayReportAbsoluteDimensions;

  /// 全程见过的最好 b/d(给诊断和引导用)。
  final double bestBaselineOverDepth;

  /// 全程见过的最小 σ_s/s(即最好的一次尺度可观测性)。
  final double bestRelativeScaleSigma;

  double get sufficientRatio =>
      totalSeconds > 0 ? sufficientSeconds / totalSeconds : 0.0;

  /// 只有 constantVelocity 的时间段是「几何健康但尺度错」的隐蔽危险段。
  /// >0 时即使 [mayReportAbsoluteDimensions] 为 true 也值得在诊断里挂旗。
  bool get hasHiddenConstantVelocityRisk => constantVelocitySeconds > 0;

  Map<String, String> toTelemetry() => <String, String>{
    'vio_scale_total_s': totalSeconds.toStringAsFixed(2),
    'vio_scale_sufficient_s': sufficientSeconds.toStringAsFixed(2),
    'vio_scale_sufficient_ratio': sufficientRatio.toStringAsFixed(3),
    'vio_scale_longest_sufficient_s': longestSufficientRunSeconds
        .toStringAsFixed(2),
    'vio_scale_const_velocity_s': constantVelocitySeconds.toStringAsFixed(2),
    'vio_scale_pure_rotation_s': pureRotationSeconds.toStringAsFixed(2),
    'vio_scale_parallax_starved_s': parallaxStarvedSeconds.toStringAsFixed(2),
    'vio_scale_best_bd': bestBaselineOverDepth.toStringAsFixed(3),
    'vio_scale_best_sigma': bestRelativeScaleSigma.isFinite
        ? bestRelativeScaleSigma.toStringAsExponential(2)
        : 'inf',
    'vio_scale_may_report_dims': mayReportAbsoluteDimensions ? '1' : '0',
  };
}

/// 台账政策(**产品政策,不是物理推导** —— 见文件头)。
class ScaleObservabilityPolicy {
  const ScaleObservabilityPolicy({
    this.minSufficientSeconds = 1.0,
    this.minSufficientRatio = 0.15,
  });
  final double minSufficientSeconds;
  final double minSufficientRatio;
}

/// 逐窗口喂入,产出会话级结论。纯累加,无 IO,无计时器。
class ScaleObservabilityLedger {
  ScaleObservabilityLedger({this.policy = const ScaleObservabilityPolicy()});

  final ScaleObservabilityPolicy policy;

  final List<ScaleObservabilityInterval> _intervals =
      <ScaleObservabilityInterval>[];
  double? _lastT;
  ScaleObservabilityVerdict? _openVerdict;
  double _openStart = 0.0;
  double _bestBd = 0.0;
  double _bestSigma = double.infinity;

  /// 台账观察到的帧数。**只计数,永不据此丢帧** —— 见文件头铁律段。
  int _observed = 0;
  int get observedSamples => _observed;

  void add(ScaleObservabilitySample s) {
    _observed++;
    final bd = s.baselineOverDepth;
    if (bd != null && bd.isFinite && bd > _bestBd) _bestBd = bd;
    if (s.relativeScaleSigma.isFinite && s.relativeScaleSigma < _bestSigma) {
      _bestSigma = s.relativeScaleSigma;
    }

    final t = s.tSec;
    if (_openVerdict == null) {
      _openVerdict = s.verdict;
      _openStart = t;
      _lastT = t;
      return;
    }
    if (s.verdict != _openVerdict) {
      _intervals.add(ScaleObservabilityInterval(_openStart, t, _openVerdict!));
      _openVerdict = s.verdict;
      _openStart = t;
    }
    _lastT = t;
  }

  /// 生成快照。不改变内部状态 —— 可以在会话中途反复调。
  ScaleObservabilityReport report({double? nowSec}) {
    final end = nowSec ?? _lastT ?? 0.0;
    final all = List<ScaleObservabilityInterval>.from(_intervals);
    if (_openVerdict != null && end > _openStart) {
      all.add(ScaleObservabilityInterval(_openStart, end, _openVerdict!));
    }
    var total = 0.0, suf = 0.0, cv = 0.0, pr = 0.0, ps = 0.0, longest = 0.0;
    for (final iv in all) {
      final d = iv.durationSec;
      if (d <= 0) continue;
      total += d;
      switch (iv.verdict) {
        case ScaleObservabilityVerdict.sufficient:
          suf += d;
          if (d > longest) longest = d;
        case ScaleObservabilityVerdict.constantVelocity:
          cv += d;
        case ScaleObservabilityVerdict.pureRotation:
          pr += d;
        case ScaleObservabilityVerdict.parallaxStarved:
          ps += d;
        case ScaleObservabilityVerdict.insufficientData:
          break;
      }
    }
    final ratio = total > 0 ? suf / total : 0.0;
    final ok =
        longest >= policy.minSufficientSeconds &&
        ratio >= policy.minSufficientRatio;
    return ScaleObservabilityReport(
      totalSeconds: total,
      sufficientSeconds: suf,
      longestSufficientRunSeconds: longest,
      constantVelocitySeconds: cv,
      pureRotationSeconds: pr,
      parallaxStarvedSeconds: ps,
      intervals: List<ScaleObservabilityInterval>.unmodifiable(all),
      mayReportAbsoluteDimensions: ok,
      bestBaselineOverDepth: _bestBd,
      bestRelativeScaleSigma: _bestSigma,
    );
  }

  void reset() {
    _intervals.clear();
    _lastT = null;
    _openVerdict = null;
    _openStart = 0.0;
    _bestBd = 0.0;
    _bestSigma = double.infinity;
    _observed = 0;
  }
}
