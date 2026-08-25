// imu_timing_probe.dart — IMU 时序**当场量**(Blocker 04 任务 2 的测量部分)。
// 纯 Dart,零 Flutter 依赖。
//
// ── 为什么要测而不是问 ──────────────────────────────────────────────────
// 两端都没有「返回实际采样率」的 API:
//   Android: registerListener(l, s, samplingPeriodUs, maxReportLatencyUs) 的
//            samplingPeriodUs 只是**建议**;Android 12(API 31)起所有 sensor 被硬压到
//            200Hz,除非应用持有 HIGH_SAMPLING_RATE_SENSORS。没有 API 返回达成率。
//   iOS:     CMMotionManager.deviceMotionUpdateInterval 同样是请求值,
//            实际下发速率只能从 CMDeviceMotion.timestamp 反推。
// 所以速率、抖动、成簇与否,全部从时间戳反推。
//
// ── 两个时钟,两个问题 ──────────────────────────────────────────────────
// 每个样本带两个戳:
//   sampleTsNs   —— 传感器说「这一帧数据是那一刻采的」(Android SensorEvent.timestamp;
//                   iOS CMDeviceMotion.timestamp)。**这是给 VIO 用的那个。**
//   deliveryTsNs —— 回调里当场读的宿主时钟(Android elapsedRealtimeNanos();
//                   iOS ProcessInfo.processInfo.systemUptime)。**这是暴露成簇的那个。**
//
// 硬件 batching 下 sampleTs 仍然近似等间隔,成簇**只在 deliveryTs 上看得见**:
// 一簇样本几乎同时到达(Δ≈0),簇与簇之间空一个 batch 周期。
// ⇒ 速率/抖动看 sampleTs;成簇看 deliveryTs。**两条线不能混**。
//
// ── 成簇怎么判:Otsu 分割 + 三条物理判据 ─────────────────────────────────
// 对 deliveryTs 的一阶差分 d,先用 **Otsu 法**(最大化类间方差,遍历全部分割点,
// 确定性、无随机初始化、O(n log n))切成低簇/高簇。Otsu 只负责**找分界**,
// 不负责下结论 —— 任何单峰分布都能被硬切成两半,所以判据必须是物理的:
//
//   C1  低簇质量 ≥ [kMinBurstMassFraction]      —— 簇内间隔要占相当比例,否则是噪声
//   C2  低簇中位 ≤ [kBurstIntraFraction] × 采样周期 —— 簇内几乎同时到达
//   C3  高簇中位 ≥ [kBurstGapFactor]  × 采样周期 —— 簇间确实空开了
//
// 三条**同时**成立才判成簇。少任何一条都会把「均匀到达但有点抖」误判成 batching。
// 阈值出处:
//   C2 = 0.25 —— 一簇里 k≥2 个样本同时交付,理想 Δ=0;留 1/4 周期给回调开销。
//   C3 = 1.5  —— 🔴 这里有一个必须算清楚的边界。簇长为 k 时,簇间交付间隔是
//                    gap = k·T − (k−1)·δ        (δ = 簇内交付间隔,δ ≪ T)
//                即**严格小于** k·T。所以「≥ 2T」这条看似自然的门限,恰好把
//                **最小的可观测簇 k=2**(gap = 2T − δ)排除在外 —— 差的就是那个 δ。
//                无簇时 gap = 1·T,最小簇 k=2 时 gap → 2T⁻。取两者中点 1.5T 才是
//                能同时分开这两种情况的门限。这不是放宽,是把边界算对。
//                (单测 “簇长 2 也能检出” 就是钉这一条的;门限设回 2.0 立刻变红。)
//   C1 = 0.20 —— 平均簇长 = 1/(1−p)(p 为簇内间隔占比);p=0.20 ⇒ 平均 1.25 个/簇,
//                已经是「能观测到的最小成簇」。再低就没有统计意义。
//
// 派生量 [ImuTimingFacts.estimatedBurstSize] = 1/(1−p) 直接给出平均每簇几个样本。
//
// ── 抖动:相对 MAD,不是标准差 ──────────────────────────────────────────
// 一次挂起、一次丢块就能把标准差顶到任意大,而真实周期纹丝未动。用
// MAD(d)/median(d)(相对中位绝对偏差),对 <50% 的污染完全免疫。
//
// ── 与 android_ready/dart/pw_android_capture/lib/src/sensor_delivery_monitor.dart
//    的关系(**不重复造尺子**)────────────────────────────────────────────
// 那个文件是 Android 专用的、基于阈值的 batchedFraction 观察器,输出 DeliveryReport。
// 本文件是**跨端**的、基于 Otsu 的分布分析,两端共用同一条判定链。
// 主会话如果决定在 Android 上只留一个:把 DeliveryReport 的字段直接填进
// [ImuTimingFacts](medianPeriodNs→medianSamplePeriodNs、batchedFraction→burstMassFraction、
// maxGapNs→maxSampleGapNs、flags.batched→clustered),判定层完全不需要改。
//
// ── 铁律 ────────────────────────────────────────────────────────────────
// 本文件是**纯观察者**:不丢样本、不重排、不改写。offeredCount 恒等于 sampleCount,
// 单测里当不变量断言。异常只抬旗,由上层决定。

import 'dart:math' as math;

/// 一个 IMU 样本的两个时间戳。字段与 android_ready 的 SensorSample 一一对应。
class ImuArrival {
  const ImuArrival({required this.sampleTsNs, required this.deliveryTsNs});

  /// 传感器报的采样瞬间。
  final int sampleTsNs;

  /// 回调里当场读的宿主时钟。
  final int deliveryTsNs;
}

enum ImuTimingFlag {
  /// 成簇上报(硬件 batching)。
  clustered,

  /// 簇内时间戳完全等距 —— HAL 伪造的,逐样本 dt 不是实测数据。
  syntheticTimestamps,

  /// 采样时间戳倒流。绝不丢弃,一律上报。
  backwardsTimestamp,

  /// 出现远大于标称周期的空洞:上游丢样本或系统挂起。
  gap,

  /// 样本太少,统计量不可信。
  insufficientSamples,
}

/// 量出来的 IMU 时序事实。
class ImuTimingFacts {
  const ImuTimingFacts({
    required this.sampleCount,
    required this.medianSamplePeriodNs,
    required this.relativeJitter,
    required this.burstMassFraction,
    required this.maxSampleGapNs,
    required this.flags,
  });

  const ImuTimingFacts.unmeasured()
      : sampleCount = 0,
        medianSamplePeriodNs = null,
        relativeJitter = null,
        burstMassFraction = 0.0,
        maxSampleGapNs = null,
        flags = const <ImuTimingFlag>{};

  final int sampleCount;

  /// 采样时间戳一阶差分的**中位数**。
  final int? medianSamplePeriodNs;

  /// MAD(d)/median(d)。0 = 完美等间隔。
  final double? relativeJitter;

  /// 交付间隔里落在低簇的比例 p。
  final double burstMassFraction;

  final int? maxSampleGapNs;

  final Set<ImuTimingFlag> flags;

  bool get isMeasured =>
      sampleCount >= kMinSamplesForTiming &&
      medianSamplePeriodNs != null &&
      medianSamplePeriodNs! > 0;

  /// 实测速率。没有任何 API 能返回它。
  double? get hz => isMeasured ? 1e9 / medianSamplePeriodNs! : null;

  bool get clustered => flags.contains(ImuTimingFlag.clustered);

  /// 平均每簇几个样本 = 1/(1−p)。p→1 时封顶,避免除零。
  double get estimatedBurstSize {
    if (!clustered) return 1.0;
    final double p = burstMassFraction.clamp(0.0, 0.999);
    return 1.0 / (1.0 - p);
  }

  @override
  String toString() => 'ImuTimingFacts(n=$sampleCount, '
      '${hz?.toStringAsFixed(1) ?? "?"}Hz, '
      'jitter=${relativeJitter?.toStringAsFixed(3) ?? "?"}, '
      'burst=${estimatedBurstSize.toStringAsFixed(2)}, '
      'flags=${flags.map((f) => f.name).join("|")})';
}

/// 统计量可信所需的最小样本数。
/// 200Hz 下 = 1.0s;100Hz 下 = 2.0s。取 200 是因为 Otsu 要在两个簇里各有足够质量,
/// 且 C1=0.20 的最小簇(40 个间隔)才有统计意义。
const int kMinSamplesForTiming = 200;

/// C1:低簇质量下限。
const double kMinBurstMassFraction = 0.20;

/// C2:簇内间隔上限,以采样周期为单位。
const double kBurstIntraFraction = 0.25;

/// C3:簇间间隔下限,以采样周期为单位。
/// 1.5 = 「无簇(1·T)」与「最小簇 k=2(2·T⁻)」的中点。推导见文件头 C3。
const double kBurstGapFactor = 1.5;

/// 空洞判据:采样间隔超过标称周期这么多倍即抬 [ImuTimingFlag.gap]。
/// 3.0 = 连续丢掉 2 个样本 —— 单个样本的抖动到不了这里。
const double kGapFactor = 3.0;

/// 合成时间戳判据:低簇内部一阶差分的相对 MAD 低于此值即认为是 HAL 造的。
/// 真实硬件不可能把交付间隔做到 0.1% 以内。
const double kSyntheticJitterCeiling = 0.001;

class ImuTimingProbe {
  const ImuTimingProbe._();

  /// 分析一段样本。**纯函数,不持有状态,不修改入参。**
  static ImuTimingFacts analyze(List<ImuArrival> samples) {
    final int n = samples.length;
    if (n < kMinSamplesForTiming) {
      return ImuTimingFacts(
        sampleCount: n,
        medianSamplePeriodNs: null,
        relativeJitter: null,
        burstMassFraction: 0.0,
        maxSampleGapNs: null,
        flags: const <ImuTimingFlag>{ImuTimingFlag.insufficientSamples},
      );
    }

    final Set<ImuTimingFlag> flags = <ImuTimingFlag>{};

    // ── 采样侧:速率与抖动 ──────────────────────────────────────────
    final List<int> sampleDeltas = <int>[];
    for (int i = 1; i < n; i++) {
      final int d = samples[i].sampleTsNs - samples[i - 1].sampleTsNs;
      if (d < 0) flags.add(ImuTimingFlag.backwardsTimestamp);
      sampleDeltas.add(d);
    }
    // 倒流的样本**不丢**,只是不参与周期统计(否则中位数被负数污染)。
    final List<int> positiveSampleDeltas =
        sampleDeltas.where((int d) => d > 0).toList(growable: false);
    if (positiveSampleDeltas.isEmpty) {
      return ImuTimingFacts(
        sampleCount: n,
        medianSamplePeriodNs: null,
        relativeJitter: null,
        burstMassFraction: 0.0,
        maxSampleGapNs: null,
        flags: flags..add(ImuTimingFlag.insufficientSamples),
      );
    }

    final int medianPeriod = _median(positiveSampleDeltas);
    final double relJitter = medianPeriod > 0
        ? _medianAbsoluteDeviation(positiveSampleDeltas, medianPeriod) / medianPeriod
        : double.infinity;

    final int maxGap = positiveSampleDeltas.reduce(math.max);
    if (medianPeriod > 0 && maxGap > kGapFactor * medianPeriod) {
      flags.add(ImuTimingFlag.gap);
    }

    // ── 交付侧:成簇 ────────────────────────────────────────────────
    final List<int> deliveryDeltas = <int>[];
    for (int i = 1; i < n; i++) {
      final int d = samples[i].deliveryTsNs - samples[i - 1].deliveryTsNs;
      if (d >= 0) deliveryDeltas.add(d);
    }

    double burstMass = 0.0;
    if (deliveryDeltas.length >= kMinSamplesForTiming ~/ 2 && medianPeriod > 0) {
      final _Split split = _otsuSplit(deliveryDeltas);
      if (split.valid) {
        final List<int> low =
            deliveryDeltas.where((int d) => d <= split.threshold).toList(growable: false);
        final List<int> high =
            deliveryDeltas.where((int d) => d > split.threshold).toList(growable: false);
        if (low.isNotEmpty && high.isNotEmpty) {
          burstMass = low.length / deliveryDeltas.length;
          final int lowMedian = _median(low);
          final int highMedian = _median(high);

          final bool c1 = burstMass >= kMinBurstMassFraction;
          final bool c2 = lowMedian <= kBurstIntraFraction * medianPeriod;
          final bool c3 = highMedian >= kBurstGapFactor * medianPeriod;

          if (c1 && c2 && c3) {
            flags.add(ImuTimingFlag.clustered);
            // 簇内时间戳是不是 HAL 造的等距值?看**采样侧**在簇内的一致性:
            // 真实硬件的采样抖动不可能低于 0.1%。
            if (relJitter < kSyntheticJitterCeiling) {
              flags.add(ImuTimingFlag.syntheticTimestamps);
            }
          }
        }
      }
    }

    return ImuTimingFacts(
      sampleCount: n,
      medianSamplePeriodNs: medianPeriod,
      relativeJitter: relJitter,
      burstMassFraction: burstMass,
      maxSampleGapNs: maxGap,
      flags: flags,
    );
  }

  // ── 内部工具 ────────────────────────────────────────────────────────

  static int _median(List<int> xs) {
    final List<int> s = List<int>.of(xs)..sort();
    final int m = s.length ~/ 2;
    return s.length.isOdd ? s[m] : ((s[m - 1] + s[m]) ~/ 2);
  }

  static double _medianAbsoluteDeviation(List<int> xs, int center) {
    final List<int> dev =
        xs.map((int x) => (x - center).abs()).toList(growable: false);
    return _median(dev).toDouble();
  }

  /// Otsu 一维阈值:遍历所有候选分割点,取类间方差最大者。
  ///
  /// 类间方差 σ_b²(t) = w0(t)·w1(t)·(μ0(t) − μ1(t))²
  /// 用前缀和 O(n) 扫完(排序 O(n log n) 是主项)。确定性,无初始化依赖 —— 这是
  /// 选它而不是 k-means 的原因:k-means 的结果依赖随机初值,单测会不稳定。
  static _Split _otsuSplit(List<int> xs) {
    if (xs.length < 4) return const _Split.invalid();
    final List<int> s = List<int>.of(xs)..sort();
    if (s.first == s.last) return const _Split.invalid(); // 全同值,没有分割可言

    final int n = s.length;
    final List<double> prefix = List<double>.filled(n + 1, 0.0);
    for (int i = 0; i < n; i++) {
      prefix[i + 1] = prefix[i] + s[i];
    }
    final double total = prefix[n];

    double best = -1.0;
    int bestIdx = -1;
    // i = 低簇元素个数,1..n-1
    for (int i = 1; i < n; i++) {
      if (s[i] == s[i - 1]) continue; // 不能在等值中间切
      final double w0 = i / n;
      final double w1 = 1.0 - w0;
      final double mu0 = prefix[i] / i;
      final double mu1 = (total - prefix[i]) / (n - i);
      final double diff = mu0 - mu1;
      final double between = w0 * w1 * diff * diff;
      if (between > best) {
        best = between;
        bestIdx = i;
      }
    }
    if (bestIdx <= 0) return const _Split.invalid();
    return _Split(threshold: s[bestIdx - 1], betweenClassVariance: best);
  }
}

class _Split {
  const _Split({required this.threshold, required this.betweenClassVariance})
      : valid = true;
  const _Split.invalid()
      : threshold = 0,
        betweenClassVariance = 0.0,
        valid = false;

  final int threshold;
  final double betweenClassVariance;
  final bool valid;
}
