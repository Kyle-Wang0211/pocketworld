// texture_sufficiency.dart — 纹理充分性(条目 10)。纯 Dart,零 Flutter 依赖。
//
// ── 为什么存在 ────────────────────────────────────────────────────────────
// NAVER LABS:「특징이 부족한 환경(단색 벽면, 무늬 없는 바닥 등)을 지속적으로
// 바라보는 경우 6DOF 추정 과정에서 오류가 발생할 가능성이 높아집니다」。
// 🔴 白墙 / 无纹理地板正是我们 MVS 线反复吃亏的同一批场景(鬼墙战役)。现在
//    VIO 会在**更早的环节**再吃一次 —— 位姿本身错了,后面 MVS 再准也没用。
//
// ── 只看数量是不够的:数量与分布是两件事 ────────────────────────────────
// 「检出 80 个点」可以是均匀铺满整帧(健康),也可以是全挤在角落那张海报上
// (病态:整个白墙区域零约束,位姿绕光轴的自由度几乎不受约束)。所以指标是
// **数量 + 空间分布**两维。
//
// ── 🔴 2026-08-23:推翻本文件上一版的分布指标 ────────────────────────────
// 上一版写的是
//
//     spreadRatio = exp(H) / min(N, K),  K = 16×16 = 256 固定
//
// 并声称它「与点数解耦」。**它不是**,而且失明的方向正好是本模块存在的理由:
// 当 N ≤ K 时,分母 min(N,K) = N,而 N 个点只要**落在互不相同的格子里**就有
// exp(H) = N ⇒ spreadRatio = 1.0,**不管这些格子挤在画面的哪个角落**。
// 具体数字(用上一版自己的默认值 N=60、K=256):60 个点全部落在画面左上
// 1/4(8×8=64 个格子)⇒ exp(H) ≈ 45、分母 60 ⇒ spreadRatio ≈ 0.75 ⇒ 判
// **sufficient**。而它按自己文件头的推导应该给 φ ≈ 0.25 ⇒ 判 clustered。
// 3 倍的错,方向是**漏报**。test/vio_quality_texture_sufficiency_test.dart 里的
// group「🔴 推翻上一版」就是钉这条的:它把旧公式在测试里原样重算一遍,断言
// 旧读数 > 0.55(会判达标)而新读数 < 0.40 —— 这是本次推翻的负向对照。
//
// 病根有两层:
//   (a) 分母用 min(N,K) 把「点数不够多」和「分布不均匀」混成了一件事;
//   (b) 在 N < K 的区间,16×16 这个网格的分辨率**超出了样本量能支撑的上限**
//       —— 60 个样本估不出 256 格的分布,估出来的 H 只是在数「有几个点」。
//
// ── 新指标:等效面积占比 φ̂,直接反解,不做任何比值近似 ────────────────
// 定义:**若这 N 个点是均匀撒在画面的 φ 比例面积上,plug-in 熵的期望是多少?**
// 记这个函数为 E[H](N, φ·K)。观测到 H_obs 之后,反解
//
//     φ̂  =  argsolve_φ  E[H](N, φ·K) = H_obs                      ……(◆)
//
// φ̂ 就是 [TextureSample.effectiveAreaFraction]:「这堆点等效覆盖了画面的百分之
// 几」。它**按构造**与 N 解耦 —— 因为期望值本身是 N 的函数,有限样本偏差在分子
// 分母里被同一个 N 抵消。均匀铺满 ⇒ φ̂ → 1.0;挤在 1/4 画面 ⇒ φ̂ → 0.25,
// 无论 N 是 40 还是 4000。E[H] 用**精确的二项求和**(见 [expectedUniformEntropy]),
// 不是 Miller–Madow 之类的一阶近似 —— 那个近似在 N < K 时误差是数量级的
// (N=60、K=256:近似给 exp(H)=30.6,真值 ≈ 57),而 N < K 正是我们的工作区间。
//
// ── 网格分辨率随样本量走 ────────────────────────────────────────────────
// (◆) 修好了 (a),但 (b) 还在:K 固定 256 时 φ̂ 的分辨率下限是 1/256,而 60 个
// 点根本分辨不到那么细,反解会很扁。所以网格边长按样本量自适应:
//
//     side = clamp(round(sqrt(N / kPointsPerCellTarget)), 2, kTextureGridSideMax)
//
// kPointsPerCellTarget = 2.0(每格期望 2 个点)是直方图估计的常规工作点:太稀
// (<1)每格非 0 即 1、熵退化成数点数;太密(>>1)分辨率白白丢掉。
// **上限 kTextureGridSideMax 复用既有的 [kQualitySignatureSide] = 16**,与
// quality_compute.dart 的 16×16 novelty 签名同一张网格 —— 不新造尺子。
//
// ── 阈值 ────────────────────────────────────────────────────────────────
// [kMinEffectiveAreaFraction] = 0.25:等效覆盖不足画面 1/4 判聚簇。这不是调出来
// 的数,它就是「全挤在一个象限」这条肉眼判据的字面数学形式 —— 而 (◆) 让 φ̂ 的
// 单位真的是「画面面积比例」,所以 0.25 可以直接照字面读。
//
// ── 分辨率下限:测不出来的时候不许发合格证 ──────────────────────────────
// φ̂ 的取值下界是 1/K —— 所有点落进同一个格子就是它能表达的"最挤"。当网格被
// 样本量压得太粗、以致 1/K ≥ [TextureConfig.minEffectiveAreaFraction] 时,
// 这个指标**在物理上无法分辨达标与不达标**(N=8 ⇒ side=2 ⇒ K=4 ⇒ 下界正好
// 是 0.25,与门同值)。这种情况下不能因为「φ̂ 没低于门」就判达标 —— 那是拿
// 「测不出来」冒充「测过了,没问题」。[TextureSample.spreadResolvable] 为 false
// 时分布一律不算达标,方向与 fail-safe 一致。
// 影响面很小:side 要掉到 2 需要 N ≤ 12,那种帧的点数门本来就早就挂了。
// 单测 `白墙:点少且挤 ⇒ starved` 钉这条。
//
// 🔴 [kMinKeypointCountPlaceholder] 是**占位值,必须在真机上标定**,没有任何
//    推导依据 —— 它取决于 XRSLAM 的特征预算和实际分辨率,我编不出来。标定办法
//    写在交付说明的真机计划里。在标定完成前,调用方应显式传
//    [TextureConfig.minKeypointCount],不要吃默认值。
//
// ── 与既有尺子的关系(不新造尺子)──────────────────────────────────────
//   • 网格上限:复用 quality_compute.dart 的 [kQualitySignatureSide]。
//   • 图像侧低纹理判定:既有 GuidanceEngine 的 globalVariance <
//     FrameQualityConstants.minLocalVarianceForTexture(=10.0)软降级仍然有效,
//     本文件**不取代它** —— 它看的是像素,这里看的是 VIO 实际拿到的观测。两者
//     应当互相印证;真机上不一致就是标定没做对。
//   • 鬼墙/浮点侧:lib/capture/floater_filter.dart(孤点)与
//     lib/capture/true_parallax.dart(真值视差)是**点云事后**的尺子,
//     本文件是**帧内实时**的尺子,层次不同,不重复。

import 'dart:math' as math;
import 'dart:typed_data';

import '../../quality/quality_compute.dart' show kQualitySignatureSide;

/// 分布网格边长上限。复用既有 16×16 novelty 签名网格。
const int kTextureGridSideMax = kQualitySignatureSide;

/// 每格期望点数。见文件头「网格分辨率随样本量走」。
const double kPointsPerCellTarget = 2.0;

/// 聚簇门:等效覆盖 < 画面 1/4 判聚簇。见文件头推导。
const double kMinEffectiveAreaFraction = 0.25;

/// 🔴 占位值,**必须真机标定**。见文件头。
const int kMinKeypointCountPlaceholder = 60;

enum TextureVerdict {
  /// 数量与分布都达标。
  sufficient,

  /// 点够多但挤成一堆(海报 / 门框 / 插座)。
  clustered,

  /// 点太少(白墙、无纹理地板)。
  sparse,

  /// 又少又挤 —— 最坏。
  starved,
}

/// 按样本量选网格边长。见文件头。
int adaptiveGridSide(
  int n, {
  int maxSide = kTextureGridSideMax,
  double pointsPerCell = kPointsPerCellTarget,
}) {
  if (n < 2 || pointsPerCell <= 0) return 2;
  final s = math.sqrt(n / pointsPerCell).round();
  if (s < 2) return 2;
  if (s > maxSide) return maxSide;
  return s;
}

/// E[H_plugin]:N 个点均匀撒进 [kCells] 个等概率格子时,plug-in 熵(自然对数)
/// 的**期望**。[kCells] 允许非整数 —— (◆) 的反解需要它在 φ 上连续。
///
///     E[H] = −K · E[(X/N)·ln(X/N)],  X ~ Binomial(N, 1/K)
///
/// 用二项 pmf 的递推逐项精确求和(pmf(x+1) = pmf(x)·(N−x)/(x+1)·p/q)。因为
/// 网格是自适应的,N·p ≈ [kPointsPerCellTarget] ≈ 2,pmf(0) = q^N ≈ e^−2,
/// 不存在下溢;只有在网格被 maxSide 夹住、N 又极大时 N·p 才会变大,那一档
/// 走一阶渐近 ln K − (K−1)/(2N)(该区间它已经足够准)。
double expectedUniformEntropy(int n, double kCells) {
  if (n < 1 || kCells <= 1.0) return 0.0;
  final p = 1.0 / kCells;
  final np = n * p;
  if (np >= 30.0) {
    final h = math.log(kCells) - (kCells - 1.0) / (2.0 * n);
    return h > 0 ? h : 0.0;
  }
  final q = 1.0 - p;
  final ratio = p / q;
  var pmf = math.pow(q, n).toDouble();
  var acc = 0.0;
  for (var x = 0; x <= n; x++) {
    if (x > 0) {
      final frac = x / n;
      acc += pmf * frac * math.log(frac);
    }
    if (x > np && pmf < 1e-17) break;
    pmf *= ratio * (n - x) / (x + 1);
  }
  final h = -kCells * acc;
  return h > 0 ? h : 0.0;
}

/// (◆) 的反解:给定观测熵,求等效面积占比 φ̂ ∈ (0, 1]。
/// E[H](N, φ·K) 在 φ 上单调递增,二分即可。
double effectiveAreaFractionFromEntropy({
  required double observedEntropy,
  required int keypointCount,
  required int gridCells,
}) {
  if (keypointCount < 1 || gridCells < 1) return 0.0;
  if (gridCells == 1) return 1.0;
  final hUniform = expectedUniformEntropy(keypointCount, gridCells.toDouble());
  if (hUniform <= 0) return 1.0;
  if (observedEntropy >= hUniform) return 1.0;
  if (observedEntropy <= 0) return 1.0 / gridCells;
  var lo = 1.0 / gridCells;
  var hi = 1.0;
  for (var i = 0; i < 48; i++) {
    final mid = 0.5 * (lo + hi);
    final h = expectedUniformEntropy(keypointCount, mid * gridCells);
    if (h < observedEntropy) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return 0.5 * (lo + hi);
}

class TextureSample {
  const TextureSample({
    required this.keypointCount,
    required this.gridSide,
    required this.occupiedCells,
    required this.entropyNats,
    required this.effectiveCells,
    required this.effectiveAreaFraction,
    required this.spreadResolvable,
    required this.verdict,
  });

  /// 落在画面内的**有效**点数(越界点已丢弃)。
  final int keypointCount;

  /// 本帧实际使用的自适应网格边长。
  final int gridSide;

  /// 实际被占用的格子数(整数,诊断用)。
  final int occupiedCells;

  /// plug-in 熵 H(自然对数)。诊断用。
  final double entropyNats;

  /// 困惑度 exp(H) —— 「等效占用了几个格子」。诊断用。
  final double effectiveCells;

  /// 🔑 (◆) 反解出的等效面积占比 φ̂ ∈ (0,1]。判聚簇看这个。
  /// 与点数解耦,单位是「画面面积比例」,可以照字面读。
  final double effectiveAreaFraction;

  /// 本帧的网格是否细到足以分辨 [TextureConfig.minEffectiveAreaFraction]。
  /// false ⇒ φ̂ 的下界已经压到门上,分布**测不出来**,一律不算达标。见文件头。
  final bool spreadResolvable;

  final TextureVerdict verdict;

  bool get isSufficient => verdict == TextureVerdict.sufficient;

  /// 分布进度 0..1(给 UI 画「还差多少」,不是档位、不是滑杆)。
  double distributionProgress01(double minFraction) {
    if (minFraction <= 0) return 1.0;
    final v = effectiveAreaFraction / minFraction;
    return v > 1.0 ? 1.0 : (v < 0 ? 0.0 : v);
  }

  /// 数量进度 0..1。
  double countProgress01(int minCount) {
    if (minCount <= 0) return 1.0;
    final v = keypointCount / minCount;
    return v > 1.0 ? 1.0 : v;
  }

  @override
  String toString() =>
      'TextureSample(${verdict.name}, n=$keypointCount, side=$gridSide, '
      'phi=${effectiveAreaFraction.toStringAsFixed(3)})';
}

class TextureConfig {
  const TextureConfig({
    this.minKeypointCount = kMinKeypointCountPlaceholder,
    this.minEffectiveAreaFraction = kMinEffectiveAreaFraction,
    this.maxGridSide = kTextureGridSideMax,
    this.pointsPerCell = kPointsPerCellTarget,
  }) : assert(maxGridSide >= 2),
       assert(pointsPerCell > 0);

  final int minKeypointCount;
  final double minEffectiveAreaFraction;
  final int maxGridSide;
  final double pointsPerCell;
}

/// 从**特征点像素坐标**算纹理充分性。不需要图像本身 —— 输入直接来自 VIO 的
/// 健康信息(XRSLAM 侧的 tracked feature 列表)。
///
/// [xy] 是扁平 [x0,y0,x1,y1,...] 像素坐标(左上原点)。越界 / 非有限点直接丢弃
/// (VIO 偶尔会报出边缘外的预测点),丢弃后计入 [TextureSample.keypointCount]
/// 的是**有效**点数。
TextureSample evaluateTextureSufficiency({
  required Float32List xy,
  required int imageWidth,
  required int imageHeight,
  TextureConfig config = const TextureConfig(),
}) {
  // 第一遍:筛出有效点,决定自适应网格。
  final m = xy.length ~/ 2;
  var n = 0;
  if (imageWidth > 0 && imageHeight > 0) {
    for (var i = 0; i < m; i++) {
      final x = xy[i * 2], y = xy[i * 2 + 1];
      if (!x.isFinite || !y.isFinite) continue;
      if (x < 0 || y < 0 || x >= imageWidth || y >= imageHeight) continue;
      n++;
    }
  }

  if (n == 0) {
    return const TextureSample(
      keypointCount: 0,
      gridSide: 0,
      occupiedCells: 0,
      entropyNats: 0.0,
      effectiveCells: 0.0,
      effectiveAreaFraction: 0.0,
      spreadResolvable: false,
      verdict: TextureVerdict.starved,
    );
  }

  final side = adaptiveGridSide(
    n,
    maxSide: config.maxGridSide,
    pointsPerCell: config.pointsPerCell,
  );
  final k = side * side;
  final hist = Int32List(k);

  // 第二遍:直方图。
  for (var i = 0; i < m; i++) {
    final x = xy[i * 2], y = xy[i * 2 + 1];
    if (!x.isFinite || !y.isFinite) continue;
    if (x < 0 || y < 0 || x >= imageWidth || y >= imageHeight) continue;
    var cx = (x * side / imageWidth).floor();
    var cy = (y * side / imageHeight).floor();
    if (cx >= side) cx = side - 1;
    if (cy >= side) cy = side - 1;
    hist[cy * side + cx]++;
  }

  var h = 0.0;
  var occupied = 0;
  for (var i = 0; i < k; i++) {
    final c = hist[i];
    if (c == 0) continue;
    occupied++;
    final p = c / n;
    h -= p * math.log(p);
  }

  final phi = effectiveAreaFractionFromEntropy(
    observedEntropy: h,
    keypointCount: n,
    gridCells: k,
  );

  final countOk = n >= config.minKeypointCount;
  // 网格太粗 ⇒ φ̂ 的下界 1/k 已经够不到门 ⇒ 分辨不了,不发合格证。
  final spreadResolvable = (1.0 / k) < config.minEffectiveAreaFraction;
  final spreadOk = spreadResolvable && phi >= config.minEffectiveAreaFraction;
  final TextureVerdict verdict;
  if (countOk && spreadOk) {
    verdict = TextureVerdict.sufficient;
  } else if (!countOk && !spreadOk) {
    verdict = TextureVerdict.starved;
  } else if (countOk) {
    verdict = TextureVerdict.clustered;
  } else {
    verdict = TextureVerdict.sparse;
  }

  return TextureSample(
    keypointCount: n,
    gridSide: side,
    occupiedCells: occupied,
    entropyNats: h,
    effectiveCells: math.exp(h),
    effectiveAreaFraction: phi,
    spreadResolvable: spreadResolvable,
    verdict: verdict,
  );
}
