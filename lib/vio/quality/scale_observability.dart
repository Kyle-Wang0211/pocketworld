// scale_observability.dart — 米制尺度可观测性(条目 11)。纯 Dart,零 Flutter 依赖。
//
// ── 为什么存在 ────────────────────────────────────────────────────────────
// 我们上 VIO 的唯一商业理由是**米制尺度**。单目 + IMU 的尺度只能从加速度计
// 的二次积分里来;当运动接近**匀速**时,加速度计对尺度**结构性失明**。
// NAVER LABS 产品文档(엘리베이터/에스컬레이터/무빙워크 등 등속도 운동 환경)
// 直接点名了这个失效模式;日文一手实测给了可操作判据:
//
//     基线长 / 物距 ≥ 0.3   →   173 cm 量成 172.6 cm(<1%)
//     基线长 / 物距 < 0.3   →   173 cm 量成 136 cm(21% 偏差)
//
// 🔴 而「手持匀速平移绕物体走」正是我们采集引导主动鼓励的动作,也是加速度计
//    信噪比最低的运动。ZUPT 只覆盖「静止」侧,对「匀速」侧零覆盖。
//
// ── 两条判据是**独立**的,谁也推不出谁 ──────────────────────────────────
// 任务要求「阈值要能从 0.3 推导出来,或者说明为什么推不出来」。答案是**推不
// 出来**,而且有反例证明:
//
//   反例(就是 NAVER 点名的那个场景):人站在无摩擦水平自动步道上,离墙 2 m,
//   1 秒内被匀速送出 0.6 m。基线/物距 = 0.6/2 = 0.3,**判据一满足**;而整段
//   运动加速度恒为零,加速度计只有噪声和零偏,**尺度完全不可观**。
//
// 所以:
//   判据一(视觉/几何):baseline/depth ≥ 0.3  —— 保证「有视差可三角化」,
//     即尺度的**方向**与结构可解;这是 0.3 这个数字的全部内容。
//   判据二(惯性):加速度的**交流分量**要足够大 —— 保证尺度的**量值**可解。
//     0.3 对它一个字都没说,必须独立推导(见下)。
// 两条**都是必要条件**,任何一条不满足都不许报绝对尺寸。
//
// ── 判据二的推导:Fisher 信息,而不是拍脑袋的方差阈值 ────────────────────
// 窗口内把世界系线加速度(已去重力)建模为
//
//     f(t) = s · α(t) + b + n(t),   n ~ N(0, σ_a² I) 逐轴独立白噪声
//
// 其中 α(t) 是视觉给出的**未定尺度**加速度形状(up-to-scale),s 是待估尺度,
// b 是加速度计零偏(窗口内当常数)。这是一个把 f 回归到 [α(t), 1] 上的线性
// 模型,s 的 Fisher 信息为
//
//     I(s) = (1/σ_a²) · Σ_t ‖α(t) − ᾱ‖²  =  (1/(s²σ_a²)) · Σ_t ‖a_ac(t)‖²
//
// (ᾱ 被减掉正是因为 b 是未知讨厌参数 —— 常数分量全部被零偏吃掉,一点尺度信
// 息都不剩。这就是「匀速 ⇒ 不可观」的数学形式,不是经验规则。)于是
//
//     σ_s / s  =  σ_a / sqrt(N · trace(Cov[a_ac]))            ……(★)
//
// N = 窗口样本数,trace(Cov) = 三轴方差之和。**阈值因此不是加速度方差的绝对
// 值,而是目标相对尺度误差**:令 (★) ≤ [ScaleObservabilityConfig
// .targetRelativeScaleSigma](默认 0.01 = 进 1%,与我们的新 KPI 同口径),
// 反解出该窗口需要的最小交流 RMS。窗口越长、噪声越小,门槛自动放松 —— 不需要
// 任何手调常数。
//
// 两个必须做对的细节:
//   1. 测得的方差里含噪声本身,会把 trace 抬高 3σ_a²。必须扣掉。带限之后
//      各 bin 样本数 m_i 不一定相等,所以用**精确的加权形式**而不是等权近似:
//
//        S      = Σ_i m_i ‖a_i − ā_w‖²,   ā_w = Σ m_i a_i / Σ m_i
//        E[S_noise] = 3 (K−1) σ_a²        (K = bin 数;逐轴 Var(n_i)=σ_a²/m_i,
//                                          去加权均值恰好吃掉 1 个自由度)
//        S_signal   = max(0, S − 3(K−1)σ_a²)
//        σ_s/s      = σ_a / sqrt(S_signal)
//
//      m_i≡1(不带限)时它退化成 σ_a/sqrt(N·trace_signal),与推导一致。
//
//      ⚠️ 这一项到底管什么,必须说准(2026-08-23 实测更正 —— 本文件上一版在
//      这里写的是「负向对照就是拿这条钉的」,**是overclaim**:把扣除项整个删掉
//      重跑,全部单测照样全绿)。真实情况:
//        · 它**不是**挡住匀速段的那件东西。带限之后纯噪声给出的
//          σ_s/s = 1/sqrt(3K)(K = bin 数),要压到 target=0.01 需要
//          K ≥ 3333 个 bin ≈ 30 Hz 下 111 秒。任何现实窗口(默认 2 s)里,
//          噪声地板本来就够不着门 —— 挡住匀速段的是 Fisher 判据本身。
//        · 它管的是**无偏**:纯噪声段扣除后 acRms = 0.0030 m/s²,不扣是
//          0.0113 m/s²(σ_a=0.02、2 s、300 Hz 实测)。差 3.8 倍。acRms 与
//          σ_s/s 要喂给引导进度条和遥测,有偏就会系统性高报激励。
//        · 以及保证极限行为:激励精确为零时 S_signal 归零 ⇒ σ_s/s = +∞。
//      钉这一项的单测是 `噪声扣除让 acRms 无偏`(断言纯噪声段 acRms < 0.3σ_a),
//      删掉扣除项它会红 —— 而 verdict 类的断言不会红。
//   2. 输入必须是**世界系、已去重力**的线加速度。若用机体系原始比力,原地
//      转手机会让方差爆表却零平移激励 —— 纯旋转会被误判为「激励充足」。
//      iOS 侧数据源:CMDeviceMotion.userAcceleration(已去重力)经
//      CMDeviceMotion.attitude 旋到参考系;本仓 lib/capture/fusion_ahrs.dart
//      与 gravity_align.dart 已有同一套姿态。
//   3. 🔴 **视觉带限**(2026-08-23 修正,推翻本文件上一版的无带限实现)。
//      (★) 隐含假设「加速度计里的每一份交流能量都能被视觉那一侧对上」。
//      不成立:α(t) 只在位姿采样率上存在。高于视觉 Nyquist 的成分(手抖、
//      快门/风扇振动、走路脚跟冲击的高频尾巴)会把 trace 抬得很高,却**一点
//      尺度信息都不提供** —— 这会让判据在最需要它保守的时候变得乐观。
//      修正:先把加速度按**位姿采样间隔**做箱平均(bin average)再算 (★)。
//      · 对带内信号这是**恒等变换**:箱内平均 m 个样本使噪声降到 σ/√m、
//        bin 数降到 N/m,(★) 的分子分母同比抵消 ⇒ 结论逐位不变。
//        单测 `band-limit is a no-op for in-band excitation` 钉这条。
//      · 对带外信号箱平均把它抹平 ⇒ σ_s/s → ∞ ⇒ 正确地判 constantVelocity。
//        单测 `band-limit rejects out-of-band vibration` 钉这条,并**同时
//        断言无带限版本会被骗过** —— 这就是这次修正的负向对照。
//      · 箱平均在视觉 Nyquist 处衰减 sinc(0.5)=0.637(比理想低通更狠),
//        误差方向是「少报激励 ⇒ 更容易拒绝报绝对尺寸」,与 fail-safe 同向。
//
// ── σ_a 不给默认值 ──────────────────────────────────────────────────────
// (★) 里 σ_a 是**该喂入速率下**的逐轴白噪声标准差。任何我编的数字都会静默
// 毒化整条判据,所以 [ScaleObservabilityConfig.accelNoiseSigmaMps2] 是
// **必填**,并提供 [estimateAccelNoiseSigmaMps2] 从一段静止录制里直接测出来
// (真机上把手机放桌上录 5 s 即可)。这条也正好对齐「离线 batch 标 IMU 内参」
// 的路线。
//
// ── 与既有尺子的关系(不新造尺子)──────────────────────────────────────
// 本仓已有真值视差尺子 lib/capture/true_parallax.dart(逐点三角化角)与覆盖云
// 的 parallaxMinDeg = 5° 压黄门。基线/物距与三角化角是同一几何的两种记法:
//
//     b/d = 2·tan(θ/2)      θ = 2·atan((b/d)/2)
//
// 见 [baselineOverDepthFromTriangulationDeg] / [triangulationDegFromBaselineOverDepth]。
// 🔴 换算出来的结论很硬:**b/d ≥ 0.30 等价于 θ ≥ 17.06°,而覆盖云现行的 5°
//    门只等价于 b/d ≈ 0.087**。也就是说,一个体素在覆盖云里已经判绿(视差达
//    标、可以三角化出几何),距离「可以报绝对尺寸」还差 3.4 倍基线。既有尺子
//    照用,但**不能拿它当尺度可观测性的证据**。

import 'dart:collection';
import 'dart:math' as math;

/// 已验证判据:基线长 / 物距的下限。来源是日文一手实测(≥0.3 时 173 cm 量成
/// 172.6 cm;<0.3 时量成 136 cm)。这是本文件里**唯一**一个外部实测常数。
const double kMinBaselineOverDepth = 0.30;

/// b/d → 三角化角(度)。b/d = 2·tan(θ/2)。
double triangulationDegFromBaselineOverDepth(double ratio) =>
    2.0 * math.atan(ratio / 2.0) * 180.0 / math.pi;

/// 三角化角(度)→ b/d。与 lib/capture/true_parallax.dart 的 voxelDeg 换算共用。
double baselineOverDepthFromTriangulationDeg(double deg) =>
    2.0 * math.tan(deg * math.pi / 180.0 / 2.0);

/// [kMinBaselineOverDepth] 在覆盖云 voxelDeg 口径下的等价角(≈17.06°)。
/// 拿它和 CaptureCoverageCloud.parallaxMinDeg(5°)对照,就知道「判绿」离
/// 「可报尺寸」还有多远。
final double kMinBaselineOverDepthAsTriangulationDeg =
    triangulationDegFromBaselineOverDepth(kMinBaselineOverDepth);

/// 单窗口结论。
enum ScaleObservabilityVerdict {
  /// 样本不足以给结论(会话刚开始 / 位姿或深度缺席)。**不等于失败**,
  /// 但同样不许报绝对尺寸。
  insufficientData,

  /// 转得多、走得少 —— 基线远不够。引导语与 [parallaxStarved] 不同
  /// (「别原地转,横着走两步」),所以单独成一档。
  pureRotation,

  /// 基线/物距 < 0.3。三角化本身就弱。
  parallaxStarved,

  /// 🔴 视差够了但加速度交流分量不够 —— 电梯 / 自动步道 / 匀速推车 / 匀速
  /// 横移。这一档最危险:几何看着健康,尺度是错的,而且**没有任何视觉
  /// 症状**。
  constantVelocity,

  /// 两条判据同时满足。只有这一档为交付层的绝对尺寸背书。
  sufficient,
}

/// 一次评估的完整结论 + 引导信号。
class ScaleObservabilitySample {
  const ScaleObservabilitySample({
    required this.tSec,
    required this.verdict,
    required this.parallaxOk,
    required this.excitationOk,
    required this.baselineMeters,
    required this.medianDepthMeters,
    required this.baselineOverDepth,
    required this.relativeScaleSigma,
    required this.acRmsMps2,
    required this.imuSamples,
    required this.windowSeconds,
    required this.rotationSpanDeg,
    required this.excitationBins,
    required this.bandLimitBinSeconds,
  });

  /// 窗口末端时间戳(秒,与喂入的时基同源)。
  final double tSec;
  final ScaleObservabilityVerdict verdict;

  /// 判据一(视觉/几何):baseline/depth ≥ [kMinBaselineOverDepth]。
  final bool parallaxOk;

  /// 判据二(惯性 Fisher):σ_s/s ≤ 目标。
  final bool excitationOk;

  /// 窗口内相机中心集合的**直径**(弦长,不是路径长)。绕物体走一整圈回到
  /// 原点,弦长口径给 2R(正确 —— 参与三角化的是弦),路径长会给 2πR(错)。
  /// 单位 = 地图单位;若尺度本身还没定,它与 [medianDepthMeters] 同比例缩放,
  /// 因此 [baselineOverDepth] **仍然可信**(比值是尺度不变量)。
  final double baselineMeters;

  /// 窗口内 landmark 深度中位数的中位数(地图单位)。
  final double medianDepthMeters;

  /// 判据一的量值。缺深度或深度非正 → null。
  final double? baselineOverDepth;

  /// (★) 的结果:相对尺度标准差 σ_s/s。匀速段 → [double.infinity]。
  final double relativeScaleSigma;

  /// 扣掉噪声后的交流加速度 RMS(m/s²)。匀速段 → 0。
  final double acRmsMps2;

  final int imuSamples;
  final double windowSeconds;

  /// 窗口内姿态转过的总角度(度)。调用方不喂则为 0。
  final double rotationSpanDeg;

  /// 视觉带限后参与 (★) 的 bin 数 K。未带限时等于 [imuSamples]。
  final int excitationBins;

  /// 箱平均的箱宽(秒)= 实测位姿采样间隔。0 = 本窗口未带限(位姿不足两条,
  /// 此时结论必为 insufficientData,不会放行)。
  final double bandLimitBinSeconds;

  /// 判据一进度 0..1(给 UI 画「还差多少」,不是档位、不是滑杆)。
  double get parallaxProgress01 {
    final r = baselineOverDepth;
    if (r == null || !r.isFinite || r <= 0) return 0.0;
    return math.min(1.0, r / kMinBaselineOverDepth);
  }

  /// 判据二进度 0..1。σ 越小越好,所以是 target/σ。
  double excitationProgress01(double targetRelativeScaleSigma) {
    if (!relativeScaleSigma.isFinite || relativeScaleSigma <= 0) {
      return relativeScaleSigma <= 0 ? 1.0 : 0.0;
    }
    return math.min(1.0, targetRelativeScaleSigma / relativeScaleSigma);
  }

  /// 还需要多横移多少(地图单位)才能满足判据一。已满足 → 0。
  double get neededExtraBaselineMeters {
    if (medianDepthMeters <= 0 || !medianDepthMeters.isFinite) return 0.0;
    final need = kMinBaselineOverDepth * medianDepthMeters - baselineMeters;
    return need > 0 ? need : 0.0;
  }

  @override
  String toString() =>
      'ScaleObservabilitySample(${verdict.name}, b/d=${baselineOverDepth?.toStringAsFixed(3)}, '
      'sigma_s/s=$relativeScaleSigma, acRms=${acRmsMps2.toStringAsFixed(4)}, N=$imuSamples)';
}

/// 评估器配置。
class ScaleObservabilityConfig {
  const ScaleObservabilityConfig({
    required this.accelNoiseSigmaMps2,
    this.window = const Duration(milliseconds: 2000),
    this.targetRelativeScaleSigma = 0.01,
    this.minBaselineOverDepth = kMinBaselineOverDepth,
    this.minImuSamples = 20,
    this.maxImuSamples = 2048,
    this.maxPoseSamples = 512,
    this.maxDiameterProbes = 96,
    this.pureRotationSpanDeg = 30.0,
    this.bandLimitToPoseRate = true,
  }) : assert(
         accelNoiseSigmaMps2 > 0,
         'σ_a 必须实测,见 estimateAccelNoiseSigmaMps2',
       ),
       assert(targetRelativeScaleSigma > 0),
       assert(minImuSamples >= 2),
       assert(maxDiameterProbes >= 2);

  /// **必填**。逐轴加速度白噪声标准差(m/s²)@ 实际喂入速率。
  /// 用 [estimateAccelNoiseSigmaMps2] 从静止录制实测,不要猜。
  final double accelNoiseSigmaMps2;

  /// 滑动窗口长度。2 s 的取法:低于 1 s 时 √N 太小、判据抖;高于 ~3 s 时
  /// 「窗口内零偏是常数」的假设开始失效(温漂 −160 ppm/°C)。
  final Duration window;

  /// 目标相对尺度误差。0.01 = 进 1%,与我们对外的新 KPI 同口径。
  final double targetRelativeScaleSigma;

  final double minBaselineOverDepth;
  final int minImuSamples;
  final int maxImuSamples;
  final int maxPoseSamples;

  /// 直径计算前把位姿抽稀到的上限。抽稀只会低估基线(fail-safe 方向)。
  final int maxDiameterProbes;

  /// 窗口内转过这么多度还没走出基线 → 判 [ScaleObservabilityVerdict.pureRotation]。
  final double pureRotationSpanDeg;

  /// 是否把加速度带限到位姿采样率再算 (★)。**默认 true**,见文件头第 3 条。
  /// 置 false 只应出现在单测里(用来证明带限确实起了作用)。
  final bool bandLimitToPoseRate;
}

/// 从一段**静止**录制里实测 σ_a(逐轴白噪声标准差,m/s²)。
/// [linAccelXyz] 是世界系已去重力线加速度的扁平三元组序列。静止时理论均值为 0,
/// 这里仍按逐轴去均值算方差,以免慢漂把 σ_a 抬高。
double estimateAccelNoiseSigmaMps2(List<double> linAccelXyz) {
  final n = linAccelXyz.length ~/ 3;
  if (n < 2) return double.nan;
  final mean = List<double>.filled(3, 0.0);
  for (var i = 0; i < n; i++) {
    for (var a = 0; a < 3; a++) {
      mean[a] += linAccelXyz[i * 3 + a];
    }
  }
  for (var a = 0; a < 3; a++) {
    mean[a] /= n;
  }
  var acc = 0.0;
  for (var i = 0; i < n; i++) {
    for (var a = 0; a < 3; a++) {
      final d = linAccelXyz[i * 3 + a] - mean[a];
      acc += d * d;
    }
  }
  // 三轴合并:trace(Cov)/3,自由度 (n−1)。
  return math.sqrt(acc / (3.0 * (n - 1)));
}

/// 把 (★) 反解成「这个窗口至少需要多大的交流加速度 RMS」(m/s²)。
///
///     σ_s/s = σ_a / sqrt(N · acRms²)  ≤ target
///  ⇒  acRms ≥ σ_a / (target · sqrt(N))
///
/// 这就是**阈值从推导来、不是手调**的具体形式:窗口越长(N 越大)、传感器越
/// 好(σ_a 越小)、目标越松(target 越大),门槛自动下降。举个能对表的例子:
/// σ_a = 0.02 m/s²、100 Hz × 2 s ⇒ N = 200、target = 0.01 ⇒ 需要
/// acRms ≥ 0.02/(0.01·√200) = 0.1414 m/s²,即交流信号要有 √200/100 … 换句话
/// 说信噪比 acRms/σ_a ≥ 1/(target·√N) = 7.07 倍。
double requiredAcRmsMps2({
  required double accelNoiseSigmaMps2,
  required double targetRelativeScaleSigma,
  required int samples,
}) {
  if (samples < 1 ||
      targetRelativeScaleSigma <= 0 ||
      accelNoiseSigmaMps2 <= 0) {
    return double.infinity;
  }
  return accelNoiseSigmaMps2 /
      (targetRelativeScaleSigma * math.sqrt(samples.toDouble()));
}

class _ImuSample {
  const _ImuSample(this.t, this.x, this.y, this.z);
  final double t, x, y, z;
}

class _Excitation {
  const _Excitation(
    this.bins,
    this.rawSamples,
    this.acRms,
    this.sigmaRel,
    this.binSeconds,
  );
  final int bins;
  final int rawSamples;
  final double acRms;
  final double sigmaRel;
  final double binSeconds;
}

class _PoseSample {
  const _PoseSample(this.t, this.x, this.y, this.z, this.depth, this.rotDeg);
  final double t, x, y, z, rotDeg;
  final double? depth;
}

/// 平移激励可观测性估计器。两条独立输入流(IMU 高频 / 位姿低频),同一时间窗。
///
/// 线程契约:纯计算、无计时器、无 IO;调用方决定喂入节奏(建议挂在既有的
/// 位姿回调上,**不新增计时器** —— 与 parallax_banner_gate.dart 同纪律)。
class ScaleObservabilityEstimator {
  ScaleObservabilityEstimator(this.config);

  final ScaleObservabilityConfig config;

  // ListQueue:removeFirst() 是 O(1)。原来的 List.removeAt(0) 每次驱逐都要
  // memmove 整个窗口 —— 100 Hz × 2048 上限下是白烧的热预算,而热稳定是硬约束。
  final ListQueue<_ImuSample> _imu = ListQueue<_ImuSample>();
  final ListQueue<_PoseSample> _pose = ListQueue<_PoseSample>();

  double get _windowSec => config.window.inMicroseconds / 1e6;

  /// 喂入一条世界系、**已去重力**的线加速度(m/s²)。[tSec] 单调递增。
  void addLinearAccel(double tSec, double x, double y, double z) {
    _imu.add(_ImuSample(tSec, x, y, z));
    _evict(tSec);
  }

  /// 喂入一条相机位姿采样。
  /// [x,y,z] = 相机中心(世界系;从 camFromWorld 恢复用
  /// lib/capture/true_parallax.dart 的 cameraCenterFromCamFromWorld)。
  /// [medianLandmarkDepth] = 本帧观测 landmark 的深度中位数(地图单位)。
  /// [rotationDeltaDeg] = 距上一次采样转过的角度(度),可选。
  void addPose(
    double tSec,
    double x,
    double y,
    double z, {
    double? medianLandmarkDepth,
    double rotationDeltaDeg = 0.0,
  }) {
    _pose.add(
      _PoseSample(tSec, x, y, z, medianLandmarkDepth, rotationDeltaDeg),
    );
    _evict(tSec);
  }

  void _evict(double now) {
    final cutoff = now - _windowSec;
    while (_imu.isNotEmpty &&
        (_imu.first.t < cutoff || _imu.length > config.maxImuSamples)) {
      _imu.removeFirst();
    }
    while (_pose.isNotEmpty &&
        (_pose.first.t < cutoff || _pose.length > config.maxPoseSamples)) {
      _pose.removeFirst();
    }
  }

  void reset() {
    _imu.clear();
    _pose.clear();
  }

  /// 当前窗口的结论。[nowSec] 缺省取最新样本时间。
  ScaleObservabilitySample evaluate({double? nowSec}) {
    final t =
        nowSec ??
        math.max(
          _imu.isEmpty ? double.negativeInfinity : _imu.last.t,
          _pose.isEmpty ? double.negativeInfinity : _pose.last.t,
        );
    final tOut = t.isFinite ? t : 0.0;

    // ── 判据二:Fisher(带视觉带限,见文件头第 3 条)────────────────
    final ex = _excitation();
    final n = ex.rawSamples;
    final sigmaRel = ex.sigmaRel;
    final acRms = ex.acRms;
    final excitationOk =
        n >= config.minImuSamples &&
        sigmaRel.isFinite &&
        sigmaRel <= config.targetRelativeScaleSigma;

    // ── 判据一:基线 / 物距 ───────────────────────────────────────────
    final baseline = _diameter();
    final depth = _medianDepth();
    double? ratio;
    if (depth != null && depth > 0 && depth.isFinite) {
      ratio = baseline / depth;
    }
    final parallaxOk = ratio != null && ratio >= config.minBaselineOverDepth;

    var rotSpan = 0.0;
    for (final p in _pose) {
      rotSpan += p.rotDeg;
    }

    // ── 归档 ─────────────────────────────────────────────────────────
    ScaleObservabilityVerdict verdict;
    if (_pose.length < 2 || ratio == null || n < config.minImuSamples) {
      verdict = ScaleObservabilityVerdict.insufficientData;
    } else if (parallaxOk && excitationOk) {
      verdict = ScaleObservabilityVerdict.sufficient;
    } else if (!parallaxOk && rotSpan >= config.pureRotationSpanDeg) {
      verdict = ScaleObservabilityVerdict.pureRotation;
    } else if (!parallaxOk) {
      verdict = ScaleObservabilityVerdict.parallaxStarved;
    } else {
      // 视差够、激励不够 —— 电梯 / 自动步道 / 匀速横移。
      verdict = ScaleObservabilityVerdict.constantVelocity;
    }

    return ScaleObservabilitySample(
      tSec: tOut,
      verdict: verdict,
      parallaxOk: parallaxOk,
      excitationOk: excitationOk,
      baselineMeters: baseline,
      medianDepthMeters: depth ?? 0.0,
      baselineOverDepth: ratio,
      relativeScaleSigma: sigmaRel,
      acRmsMps2: acRms,
      imuSamples: n,
      windowSeconds: _windowSec,
      rotationSpanDeg: rotSpan,
      excitationBins: ex.bins,
      bandLimitBinSeconds: ex.binSeconds,
    );
  }

  /// 位姿采样间隔的中位数(秒)。带限箱宽用它。位姿少于 2 条 → null。
  double? medianPoseIntervalSeconds() {
    if (_pose.length < 2) return null;
    final ts = <double>[];
    for (final p in _pose) {
      ts.add(p.t);
    }
    final d = <double>[];
    for (var i = 1; i < ts.length; i++) {
      final dt = ts[i] - ts[i - 1];
      if (dt > 0 && dt.isFinite) d.add(dt);
    }
    if (d.isEmpty) return null;
    d.sort();
    final mid = d.length ~/ 2;
    return d.length.isOdd ? d[mid] : 0.5 * (d[mid - 1] + d[mid]);
  }

  /// (★) 的实现。返回值全部是诊断量,判定在调用方。
  _Excitation _excitation() {
    final raw = _imu.toList(growable: false);
    final nRaw = raw.length;
    if (nRaw < 2) {
      return _Excitation(nRaw, nRaw, 0.0, double.infinity, 0.0);
    }

    // 箱平均到视觉能看见的时间尺度。位姿不足两条时 binSec=0(不带限),
    // 但那种情况 verdict 必然是 insufficientData,不会放行。
    var binSec = 0.0;
    if (config.bandLimitToPoseRate) {
      final dt = medianPoseIntervalSeconds();
      if (dt != null && dt > 0) binSec = dt;
    }

    // means[i] = 该 bin 的三轴均值;counts[i] = m_i。
    final List<double> mx = <double>[], my = <double>[], mz = <double>[];
    final List<int> counts = <int>[];
    if (binSec > 0) {
      final t0 = raw.first.t;
      var curIdx = -1;
      for (final s in raw) {
        final idx = ((s.t - t0) / binSec).floor();
        if (idx != curIdx) {
          curIdx = idx;
          mx.add(0.0);
          my.add(0.0);
          mz.add(0.0);
          counts.add(0);
        }
        final k = counts.length - 1;
        mx[k] += s.x;
        my[k] += s.y;
        mz[k] += s.z;
        counts[k] += 1;
      }
      for (var i = 0; i < counts.length; i++) {
        final m = counts[i].toDouble();
        mx[i] /= m;
        my[i] /= m;
        mz[i] /= m;
      }
    } else {
      for (final s in raw) {
        mx.add(s.x);
        my.add(s.y);
        mz.add(s.z);
        counts.add(1);
      }
    }

    final k = counts.length;
    if (k < 2) return _Excitation(k, nRaw, 0.0, double.infinity, binSec);

    var totalM = 0.0, wx = 0.0, wy = 0.0, wz = 0.0;
    for (var i = 0; i < k; i++) {
      final m = counts[i].toDouble();
      totalM += m;
      wx += m * mx[i];
      wy += m * my[i];
      wz += m * mz[i];
    }
    wx /= totalM;
    wy /= totalM;
    wz /= totalM;

    var s = 0.0;
    for (var i = 0; i < k; i++) {
      final m = counts[i].toDouble();
      final dx = mx[i] - wx, dy = my[i] - wy, dz = mz[i] - wz;
      s += m * (dx * dx + dy * dy + dz * dz);
    }

    final sa = config.accelNoiseSigmaMps2;
    final sSignal = math.max(0.0, s - 3.0 * (k - 1) * sa * sa);
    final acRms = totalM > 0 ? math.sqrt(sSignal / totalM) : 0.0;
    final sigmaRel = sSignal > 0 ? sa / math.sqrt(sSignal) : double.infinity;
    return _Excitation(k, nRaw, acRms, sigmaRel, binSec);
  }

  /// 相机中心集合的直径(最大两两距离)。
  ///
  /// 用**弦长**而不是路径长:绕物体走一圈回到原点,参与三角化的基线是弦
  /// (给 2R),路径长会给 2πR —— 那会让「原地绕一圈」冒充大基线。
  ///
  /// O(m²),但 m 先被 [ScaleObservabilityConfig.maxDiameterProbes] 均匀抽稀
  /// 到上限(2 s 窗口 @30 Hz 只有 60 个位姿,通常根本不触发)。抽稀**只会
  /// 低估**直径 —— 漏掉的点对不可能比留下的更远,所以误差方向是「少报基线
  /// ⇒ 更容易拒绝报绝对尺寸」,与 fail-safe 同向。
  double _diameter() {
    final all = _pose.toList(growable: false);
    if (all.length < 2) return 0.0;
    final List<_PoseSample> pts;
    if (all.length > config.maxDiameterProbes) {
      pts = <_PoseSample>[];
      final stride = all.length / config.maxDiameterProbes;
      for (var k = 0; k < config.maxDiameterProbes; k++) {
        pts.add(all[(k * stride).floor()]);
      }
      // 端点必须在里面:窗口首尾往往就是最远的一对。
      pts[0] = all.first;
      pts[pts.length - 1] = all.last;
    } else {
      pts = all;
    }
    final m = pts.length;
    var best = 0.0;
    for (var i = 0; i < m; i++) {
      final a = pts[i];
      for (var j = i + 1; j < m; j++) {
        final b = pts[j];
        final dx = a.x - b.x, dy = a.y - b.y, dz = a.z - b.z;
        final d2 = dx * dx + dy * dy + dz * dz;
        if (d2 > best) best = d2;
      }
    }
    return math.sqrt(best);
  }

  double? _medianDepth() {
    final ds = <double>[];
    for (final p in _pose) {
      final d = p.depth;
      if (d != null && d.isFinite && d > 0) ds.add(d);
    }
    if (ds.isEmpty) return null;
    ds.sort();
    final mid = ds.length ~/ 2;
    return ds.length.isOdd ? ds[mid] : 0.5 * (ds[mid - 1] + ds[mid]);
  }
}
