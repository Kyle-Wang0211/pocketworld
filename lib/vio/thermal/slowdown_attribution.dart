// slowdown_attribution.dart — 降频归因(纯 Dart)。
//
// ── 为什么这是最便宜也最重要的一步 ──────────────────────────────────────
// ComputerBase 实测:OnePlus 9 Pro 按 **App 包名** 决定给不给性能 ——
// Chrome 被测出根本没用到 Cortex-X1、频率被压到 2.0GHz 而非 2.41GHz。
// 后果:没进厂商白名单的新 App 拿到小核 + 降频 ⇒ VIO 掉帧 ⇒ 表现成
// "算法在某些机型上不收敛"。**但根因不在算法。**
// 没有这份归因,我们会花一周去调 RD-VIO 的参数,调的是一个不存在的问题。
//
// ── 判别原理 ────────────────────────────────────────────────────────────
// 三个互相独立的比值,同时看才能把三种慢分开:
//   1. cpuDuty = cpuMs / (wallMs * threads)
//      低 ⇒ 我们**没拿到 CPU**(被调度走了 / 核被抢) —— 平台问题。
//   2. nsPerUnitRatio = (当前每单位工作耗时) / (冷机基线每单位工作耗时)
//      高而 cpuDuty 正常 ⇒ 拿到了 CPU 但**跑得慢** = 频率被压 / 被丢到小核。
//   3. workRatio = 当前工作量 / 冷机基线工作量
//      高 ⇒ **算法自己在多干活**(特征更多、迭代更多)= 真的可能在发散。
// 只有 3 单独成立才指向算法。1 或 2 成立时,再怎么调算法参数都没用。
//
// 所有阈值都是**策略值**,不是实测出来的 —— 明早真机跑完 20 分钟曲线之后
// 才有资格重锚。它们全部可注入,就是为了重锚方便。

import 'thermal_tier.dart';

/// 一次 VIO 视觉更新的成本样本。
class FrameCost {
  const FrameCost({
    required this.frameId,
    required this.wallMs,
    required this.cpuMs,
    required this.workUnits,
    required this.tier,
    this.threads = 1,
    this.lastCpuIndex,
    this.onlineCpuCount,
    this.presentCpuCount,
  });

  final int frameId;

  /// 这次视觉更新的墙上耗时(毫秒)。
  final double wallMs;

  /// 这次视觉更新期间 VIO 工作线程消耗的 **CPU 时间**总和(毫秒)。
  /// iOS 用 thread_info(THREAD_BASIC_INFO) 差分;
  /// Android 用 `/proc/self/task/<tid>/stat` 的 utime+stime 差分。
  final double cpuMs;

  /// 工作量代理(如:被跟踪特征数,或 特征数 × 迭代数)。必须 > 0 才计入基线。
  final int workUnits;

  /// 采样时的热档位。基线只从 nominal 档采集。
  final ThermalTier tier;

  /// 参与这次更新的工作线程数(用于把 cpuDuty 归一化到 0..1)。
  final int threads;

  /// Android:线程最后一次运行在哪个核。
  final int? lastCpuIndex;

  final int? onlineCpuCount;
  final int? presentCpuCount;
}

/// 慢的归因。
enum SlowdownCause {
  /// 不慢。
  none,

  /// 没拿到 CPU:被调度走 / 被别的进程抢。
  cpuStarvation,

  /// 拿到了 CPU 但单位工作更慢:频率被压,或被丢到小核。
  clockThrottle,

  /// 算法自己在多干活 —— **只有这一档才值得去动算法**。
  workloadGrowth,

  /// 多个原因同时成立。
  mixed,

  /// 冷机基线还没建立,无法判别。
  unknown,
}

class SlowdownVerdict {
  const SlowdownVerdict({
    required this.frameId,
    required this.cause,
    required this.cpuDuty,
    required this.nsPerUnitRatio,
    required this.workRatio,
    required this.coreDemotionSuspected,
    required this.coresOfflined,
    required this.baselineEstablished,
  });

  final int frameId;
  final SlowdownCause cause;

  /// cpuMs / (wallMs * threads),0..1(可能因多线程测量误差略超 1)。
  final double? cpuDuty;
  final double? nsPerUnitRatio;
  final double? workRatio;

  /// 线程跑在小核簇上(Android)。这正是 ComputerBase 抓到的那个现象。
  final bool coreDemotionSuspected;

  /// 在线核数少于物理核数。
  final bool coresOfflined;

  final bool baselineEstablished;

  /// 归因是否**含**平台因素。只要平台掺了一脚,调算法参数就是白调,
  /// 所以 mixed 也算平台归因。
  bool get platformAttributed =>
      cause == SlowdownCause.cpuStarvation ||
      cause == SlowdownCause.clockThrottle ||
      cause == SlowdownCause.mixed;

  /// 只有这一种情况才值得去动算法。
  bool get onlyWorkload => cause == SlowdownCause.workloadGrowth;
}

/// cpuDuty 低于此值判为"没拿到 CPU"。
const double kDutyStarvationThreshold = 0.70;

/// 单位工作耗时超过冷机基线这个倍数,判为被降频。
const double kClockThrottleRatio = 1.25;

/// 工作量超过冷机基线这个倍数,判为算法在多干活。
const double kWorkloadGrowthRatio = 1.50;

/// 建立基线所需的 nominal 档样本数。
const int kBaselineSamples = 30;

/// 从每核 `cpuinfo_max_freq` 识别小核簇:最大频率等于全场最小值的那些核。
/// 全部读不到 / 所有核同频(真正的同构 SoC)时返回空集 —— 空集意味着
/// "没有小核这个概念",不是"没被降级"。
Set<int> identifyLittleCluster(List<int?> cpuMaxFreqKhz) {
  final known = <int, int>{};
  for (var i = 0; i < cpuMaxFreqKhz.length; i++) {
    final v = cpuMaxFreqKhz[i];
    if (v != null && v > 0) known[i] = v;
  }
  if (known.isEmpty) return const <int>{};
  final freqs = known.values.toSet();
  if (freqs.length < 2) return const <int>{}; // 同构,无大小核之分
  final minFreq = freqs.reduce((a, b) => a < b ? a : b);
  return known.entries
      .where((e) => e.value == minFreq)
      .map((e) => e.key)
      .toSet();
}

class SlowdownAttributor {
  SlowdownAttributor({
    this.dutyStarvationThreshold = kDutyStarvationThreshold,
    this.clockThrottleRatio = kClockThrottleRatio,
    this.workloadGrowthRatio = kWorkloadGrowthRatio,
    this.baselineSamples = kBaselineSamples,
    Set<int> littleCluster = const <int>{},
  }) : _littleCluster = littleCluster;

  final double dutyStarvationThreshold;
  final double clockThrottleRatio;
  final double workloadGrowthRatio;
  final int baselineSamples;

  Set<int> _littleCluster;

  final List<double> _baselineNsPerUnit = <double>[];
  final List<double> _baselineWork = <double>[];
  double? _baselineNs;
  double? _baselineWorkUnits;

  bool get baselineEstablished => _baselineNs != null;
  double? get baselineNsPerUnit => _baselineNs;
  double? get baselineWorkUnits => _baselineWorkUnits;

  /// 小核簇来自 Android 上报的 cpuinfo_max_freq;iOS 上永远是空集。
  void setLittleCluster(Set<int> cluster) {
    _littleCluster = cluster;
  }

  SlowdownVerdict ingest(FrameCost c) {
    final duty = c.wallMs > 0 && c.threads > 0
        ? c.cpuMs / (c.wallMs * c.threads)
        : null;
    final nsPerUnit =
        c.workUnits > 0 ? (c.cpuMs * 1e6) / c.workUnits : null;

    // 只用冷机(nominal)且工作量有效的样本建基线。
    if (!baselineEstablished &&
        c.tier == ThermalTier.nominal &&
        nsPerUnit != null) {
      _baselineNsPerUnit.add(nsPerUnit);
      _baselineWork.add(c.workUnits.toDouble());
      if (_baselineNsPerUnit.length >= baselineSamples) {
        _baselineNs = _median(_baselineNsPerUnit);
        _baselineWorkUnits = _median(_baselineWork);
      }
    }

    final coreDemotion = c.lastCpuIndex != null &&
        _littleCluster.isNotEmpty &&
        _littleCluster.contains(c.lastCpuIndex);
    final offlined = c.onlineCpuCount != null &&
        c.presentCpuCount != null &&
        c.onlineCpuCount! < c.presentCpuCount!;

    final baseNs = _baselineNs;
    final baseWork = _baselineWorkUnits;
    if (baseNs == null || baseWork == null || baseWork <= 0) {
      return SlowdownVerdict(
        frameId: c.frameId,
        cause: SlowdownCause.unknown,
        cpuDuty: duty,
        nsPerUnitRatio: null,
        workRatio: null,
        coreDemotionSuspected: coreDemotion,
        coresOfflined: offlined,
        baselineEstablished: false,
      );
    }

    final nsRatio = nsPerUnit == null ? null : nsPerUnit / baseNs;
    final workRatio = c.workUnits / baseWork;

    final causes = <SlowdownCause>[];
    if (duty != null && duty < dutyStarvationThreshold) {
      causes.add(SlowdownCause.cpuStarvation);
    }
    if (nsRatio != null && nsRatio > clockThrottleRatio) {
      causes.add(SlowdownCause.clockThrottle);
    }
    if (workRatio > workloadGrowthRatio) {
      causes.add(SlowdownCause.workloadGrowth);
    }

    final SlowdownCause cause;
    if (causes.isEmpty) {
      cause = SlowdownCause.none;
    } else if (causes.length == 1) {
      cause = causes.first;
    } else {
      cause = SlowdownCause.mixed;
    }

    return SlowdownVerdict(
      frameId: c.frameId,
      cause: cause,
      cpuDuty: duty,
      nsPerUnitRatio: nsRatio,
      workRatio: workRatio,
      coreDemotionSuspected: coreDemotion,
      coresOfflined: offlined,
      baselineEstablished: true,
    );
  }

  static double _median(List<double> xs) {
    final s = List<double>.from(xs)..sort();
    final n = s.length;
    if (n == 0) return 0;
    return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2.0;
  }
}
