// clock_offset_estimator.dart — 两个时钟之间偏置的**测量**(不是假设)。纯 Dart。
//
// 两种测量姿势,对应两种能拿到的数据:
//
//  A) **单向投递**(相机帧 / IMU 回调):只能在样本**送达**时读参考钟。
//     ⇒ [ClockOffsetEstimator](min-filter)。
//
//  B) **双向夹逼**(Android 侧同一线程里连续读两个钟;iOS 侧同理):可以把
//     被测钟夹在参考钟的两次读数之间。
//     ⇒ [bracketOffset](Cristian 算法),能给出**硬上下界**。
//
// ── A 的推导:为什么是 min 而不是均值/中位数 ────────────────────────────
// 模型:样本在物理时刻被打上 src 域的戳 t_src,经过投递延迟 d ≥ 0 之后我们才
// 在 ref 域读到 t_ref:
//
//     t_ref[i] = t_src[i] + θ + d[i],   d[i] ≥ 0,   θ = 待求偏置
//
// 令 δ[i] = t_ref[i] − t_src[i] = θ + d[i]。因为 d 是**单边非负**的讨厌变量:
//   • mean(δ) = θ + E[d]        —— 偏高 E[d],且 E[d] 随系统负载变化 ⇒ 不稳
//   • median(δ) = θ + median(d) —— 同样偏高,只是没那么容易被离群值带跑
//   • min(δ)  = θ + min(d)      —— 偏高 min(d),而 min(d) 随样本数**单调趋于
//                                  d 的下确界**(通常就是硬件/驱动的固定延迟)
// 所以 min 是唯一一个偏差随 n 收敛的估计。这就是 NTP/PTP 的 min-filter,也是
// 本估计器的做法。返回的 θ̂ = min(δ) 是真 θ 的**上界**。
//
// 🔴 一个必须做对的细节:min 必须取在**滑动时间窗**上,不能取在全历史上。
//    全历史的 min 在存在漂移时是单调不增的,永远追不上漂移;而我们正是要用
//    连续两个窗的 min 之差来测漂移。窗长由 [windowSpanSeconds] 定。
//
// ── 不确定度与漂移 ──────────────────────────────────────────────────────
// jitter := p50(δ) − min(δ),给出 d 的散布量级,即 θ̂ 的偏差量级。
// 漂移:用**同一估计器**在相隔 Δt 的两个窗上的 θ̂ 之差 / Δt。它的噪声地板是
// jitter/Δt。所以 [ClockOffsetEstimate.driftIsSignificant] 用的是
// |drift| > jitter/Δt,而不是一个手调的 ppm 阈值 —— 这条判据可证伪。
//
// ── B 的推导:Cristian 夹逼 ─────────────────────────────────────────────
// 同一线程连续读:ref=a → src=m → ref=c(a ≤ c)。被测钟的读数 m 发生在
// [a, c] 之间的某一物理时刻,于是
//
//     θ = ref − src  ∈  [a − m,  c − m]
//
// 取中点 θ̂ = (a + c)/2 − m,**硬上界**误差 = (c − a)/2。这是一个真正的
// 区间,不是统计估计;(c−a) 就是读取开销,通常是几百纳秒到几微秒。
// 用途:Android 的 nanoTime ↔ elapsedRealtimeNanos 偏置(= 累计休眠时长)
// 可以被夹到微秒级,远好于 min-filter。

import 'dart:math' as math;

import 'timebase_contract.dart';

/// Cristian 双向夹逼的结果。
class BracketedOffset {
  const BracketedOffset({
    required this.offsetSeconds,
    required this.halfWidthSeconds,
    required this.refMidpointSeconds,
  });

  /// θ̂ 使得 ref ≈ src + θ̂。
  final double offsetSeconds;

  /// **硬**误差界:|θ − θ̂| ≤ halfWidthSeconds。
  final double halfWidthSeconds;

  /// 本次夹逼在参考钟上的中点时刻(用于算漂移)。
  final double refMidpointSeconds;

  double get lowerBound => offsetSeconds - halfWidthSeconds;
  double get upperBound => offsetSeconds + halfWidthSeconds;

  /// 两次夹逼是否**不相交** ⇒ 偏置确实变了(例如设备休眠过一次)。
  /// 相交则无法区分「没变」和「变了但小于读取开销」,按没变处理。
  bool isDisjointFrom(BracketedOffset other) =>
      upperBound < other.lowerBound || other.upperBound < lowerBound;

  @override
  String toString() =>
      'BracketedOffset(${offsetSeconds.toStringAsFixed(9)}s ± '
      '${(halfWidthSeconds * 1e6).toStringAsFixed(3)}us @ $refMidpointSeconds)';
}

/// Cristian 夹逼。[refBefore]/[refAfter] 是参考钟在读被测钟 [srcMid] **前后**
/// 的两次读数,单位秒,必须来自同一线程且中间不做别的事。
///
/// [refAfter] < [refBefore] 会抛 —— 参考钟必须单调,否则这次测量无意义
/// (fail-closed:宁可让调用方看到异常,也不返回一个悄悄错掉的偏置)。
BracketedOffset bracketOffset({
  required double refBefore,
  required double srcMid,
  required double refAfter,
}) {
  if (refAfter < refBefore) {
    throw ArgumentError(
      'reference clock went backwards during bracket: '
      '$refBefore -> $refAfter (non-monotonic reference clock is unusable)',
    );
  }
  final double mid = (refBefore + refAfter) / 2.0;
  return BracketedOffset(
    offsetSeconds: mid - srcMid,
    halfWidthSeconds: (refAfter - refBefore) / 2.0,
    refMidpointSeconds: mid,
  );
}

/// 一条 (src, ref) 观测。
class _Obs {
  const _Obs(this.refSeconds, this.delta);
  final double refSeconds;
  final double delta;
}

/// 单向投递场景下的偏置估计器(min-filter + 滑窗漂移)。
///
/// 用法:每收到一个样本就 [add]。[estimate] 在样本数不足 [minSamples] 时返回
/// null —— **不足就是不足**,不返回一个凑数的值(fail-closed)。
class ClockOffsetEstimator {
  ClockOffsetEstimator({
    this.windowSpanSeconds = 4.0,
    this.minSamples = 16,
    this.maxSamples = 2048,
  })  : assert(windowSpanSeconds > 0),
        assert(minSamples >= 2),
        assert(maxSamples >= minSamples);

  /// 滑动窗长(参考钟秒)。窗内取 min。
  final double windowSpanSeconds;

  /// 出结果所需的最小样本数。
  final int minSamples;

  /// 环形上限,防止低速流下无限增长。
  final int maxSamples;

  final List<_Obs> _window = <_Obs>[];

  /// 会话内第一个**成熟**窗的估计,用作漂移基准。
  double? _anchorOffset;
  double? _anchorRef;
  double _anchorJitter = 0.0;

  int _totalAdded = 0;
  int get totalAdded => _totalAdded;

  /// 加入一条观测。[srcSeconds] 是被测钟的戳,[refSeconds] 是**收到它的那一刻**
  /// 参考钟的读数。
  void add({required double srcSeconds, required double refSeconds}) {
    _totalAdded++;
    _window.add(_Obs(refSeconds, refSeconds - srcSeconds));
    _trim(refSeconds);
  }

  void _trim(double nowRef) {
    final double cutoff = nowRef - windowSpanSeconds;
    // 时间窗裁剪。观测按 ref 递增加入,所以从头删即可。
    int drop = 0;
    while (drop < _window.length && _window[drop].refSeconds < cutoff) {
      drop++;
    }
    // 永远保留至少 minSamples 条,否则低帧率流会被裁到出不了结果。
    final int keepAtLeast = minSamples;
    if (_window.length - drop < keepAtLeast) {
      drop = math.max(0, _window.length - keepAtLeast);
    }
    if (drop > 0) _window.removeRange(0, drop);
    if (_window.length > maxSamples) {
      _window.removeRange(0, _window.length - maxSamples);
    }
  }

  /// 清空(域切换 / 检测到时钟重置后调用)。
  void reset() {
    _window.clear();
    _anchorOffset = null;
    _anchorRef = null;
    _anchorJitter = 0.0;
  }

  /// 当前估计;样本不足返回 null。
  ClockOffsetEstimate? estimate() {
    if (_window.length < minSamples) return null;

    final List<double> deltas =
        _window.map((_Obs o) => o.delta).toList(growable: false)..sort();
    final double minDelta = deltas.first;
    final double p50 = deltas[deltas.length ~/ 2];
    final double jitter = p50 - minDelta;

    final double refFirst = _window.first.refSeconds;
    final double refLast = _window.last.refSeconds;
    final double span = refLast - refFirst;

    // 锚点:第一个成熟窗。之后不再更新,漂移是相对它算的。
    _anchorOffset ??= minDelta;
    _anchorRef ??= refLast;
    if (_anchorOffset == minDelta && _anchorJitter == 0.0) {
      _anchorJitter = jitter;
    }

    final double driftSpan = refLast - _anchorRef!;
    double driftPpm = 0.0;
    double driftUnc = double.infinity;
    if (driftSpan > 0) {
      driftPpm = (minDelta - _anchorOffset!) / driftSpan * 1e6;
      // 噪声地板:两端各自的 min-filter 偏差量级。
      driftUnc = (jitter + _anchorJitter) / driftSpan * 1e6;
    }

    return ClockOffsetEstimate(
      offsetSeconds: minDelta,
      sampleCount: _window.length,
      jitterSeconds: jitter,
      spanSeconds: span,
      driftPpm: driftPpm,
      driftPpmUncertainty: driftUnc,
    );
  }
}

/// 把 [BracketedOffset] 序列串成一条**周期重测**的时间线,并检测偏置跳变。
///
/// Android 用它盯 nanoTime↔elapsedRealtimeNanos:两者只在设备休眠时分叉,所以
/// 任何**区间不相交**的跳变都等价于「刚刚睡过一觉」,必须让已缓存的另一域时间
/// 戳全部重新换算。
class OffsetTracker {
  OffsetTracker({this.historyLimit = 64}) : assert(historyLimit >= 2);

  final int historyLimit;
  final List<BracketedOffset> _history = <BracketedOffset>[];

  /// 检测到的跳变次数(Android 上 = 观测到的休眠次数)。
  int jumpCount = 0;

  /// 最近一次跳变的幅度(秒)。
  double lastJumpSeconds = 0.0;

  BracketedOffset? get latest => _history.isEmpty ? null : _history.last;
  List<BracketedOffset> get history => List<BracketedOffset>.unmodifiable(_history);

  /// 记入一次重测。返回 true 表示**发生了跳变**(偏置区间与上一次不相交)。
  bool record(BracketedOffset o) {
    bool jumped = false;
    if (_history.isNotEmpty) {
      final BracketedOffset prev = _history.last;
      if (prev.isDisjointFrom(o)) {
        jumped = true;
        jumpCount++;
        lastJumpSeconds = o.offsetSeconds - prev.offsetSeconds;
      }
    }
    _history.add(o);
    if (_history.length > historyLimit) {
      _history.removeRange(0, _history.length - historyLimit);
    }
    return jumped;
  }

  /// 相对漂移(ppm)与其硬不确定度。区间夹逼给的是硬界,所以这里的不确定度
  /// 也是硬的:(halfWidth_a + halfWidth_b) / span。
  ClockOffsetEstimate? drift() {
    if (_history.length < 2) return null;
    final BracketedOffset a = _history.first;
    final BracketedOffset b = _history.last;
    final double span = b.refMidpointSeconds - a.refMidpointSeconds;
    if (span <= 0) return null;
    return ClockOffsetEstimate(
      offsetSeconds: b.offsetSeconds,
      sampleCount: _history.length,
      jitterSeconds: b.halfWidthSeconds,
      spanSeconds: span,
      driftPpm: (b.offsetSeconds - a.offsetSeconds) / span * 1e6,
      driftPpmUncertainty:
          (a.halfWidthSeconds + b.halfWidthSeconds) / span * 1e6,
    );
  }
}

/// 把一个原始时间戳按已测偏置换算到参考域。
///
/// 这是**唯一**允许做时间戳加减的地方 —— 其它模块只接受 [TimeDomain.pwNormalized]。
double applyOffset(double rawSeconds, double offsetSeconds) =>
    rawSeconds + offsetSeconds;
