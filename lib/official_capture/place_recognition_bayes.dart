// 似然归一化 + 贝叶斯滤波 —— RTAB-Map 的复刻,把 `Rtabmap/LoopThr = 0.11`
// 变成**它本来适用的那个门**。
//
// 为什么需要这一层(2026-09-10 未命名(5) 真机定罪):
// 我先前只复刻到"TF-IDF 似然 + 共享词比例",然后拿 stella 的
// `almost_all_lms_are_tracked = 0.9` 去卡它 —— **两个量的取值分布根本不在一个
// 量级**。实测:同一场里距离 0.23 m / 朝向 5.5° / 间隔 8.5 s 的真实重访有 17 对,
// 而共享词比例中位 3.7%、最高只有 **20.8%**,离 90% 差 4.3 倍,判据一次都没
// 开火过。信号是有的(最高比中位高 5.6 倍),错的是门的位置。
//
// 🔴 这是"阈值必须连**适用范围**一起搬"那条规矩的现场:0.9 是给「地图路标
// 跟踪」定的,不是给「词袋检索的共享词比例」定的。修法不是去调那个数,而是
// **把 RTAB-Map 那条链补完**,让它自己的 0.11 可用 —— 整条链出自同一家源,
// 我一个阈值都不用定。
//
// 源(BSD-3,均已回源逐字核对):
//   `Rtabmap::adjustLikelihood`            Rtabmap.cpp:5725
//   `PredictionModel::addNeighborProb`     bayes/PredictionModel.cpp:108
//   `PredictionModel::normalize`           bayes/PredictionModel.cpp:126
//   `PredictionModel::fillVirtualPlaceColumn` bayes/PredictionModel.cpp:200
//   `BayesFilter::computePosterior`        BayesFilter.cpp:150
// 常数(rtabmap_Parameters.h):
//   `Bayes/PredictionLC` · `Bayes/VirtualPlacePriorThr 0.9` ·
//   `Rtabmap/LoopThr 0.11` · `Rtabmap/VirtualPlaceLikelihoodRatio 0`

import 'dart:math' as math;

/// `Bayes/PredictionLC` 默认值,逐字。
/// 语义(参数表原文):`{VirtualPlaceProb, LoopClosureProb, NeighborLvl1, ...}`
/// —— 第一个是"移动到一个没去过的新地方"的概率,第二个是"留在同一地点",
/// 之后依次是图上第 1、2、… 层邻居。Gaussian-like,sigma=1.6。
const List<double> kBayesPredictionLC = <double>[
  0.1,
  0.36,
  0.30,
  0.16,
  0.062,
  0.0151,
  0.00255,
  0.000324,
  2.5e-05,
  1e-06,
  4.8e-08,
  1.2e-09,
  1.9e-11,
  2.2e-13,
  1.7e-15,
  8.5e-18,
  2.9e-20,
  6.9e-23,
];

/// `Bayes/VirtualPlacePriorThr` 默认 0.9。
const double kBayesVirtualPlacePrior = 0.9;

/// `Rtabmap/LoopThr` 默认 0.11 —— **贝叶斯后验**的门,不是原始似然的门。
const double kRtabmapLoopThreshold = 0.11;

/// `Rtabmap::adjustLikelihood`(Rtabmap.cpp:5725)逐字。
///
/// 入参 [likelihood] 是 signatureId → 原始 TF-IDF 似然;返回的 map 里
/// **key −1 是虚拟地点**(「我在一个没去过的新地方」这个假设),与上游一致
/// (上游靠 std::map 的排序把它放在第一个)。
///
/// 默认 `VirtualPlaceLikelihoodRatio = 0`,所以走的是
/// `(value - (stdDev - epsilon)) / mean` 与虚拟地点 `mean/stdDev + 1` 那一支。
Map<int, double> adjustLikelihood(Map<int, double> likelihood) {
  final out = <int, double>{-1: 0.0, ...likelihood};
  if (likelihood.isEmpty) return out;

  // 上游:只统计非空值(忽略虚拟地点),且 likelihoodNullValuesIgnored = true
  // ⇒ 只取 > 0 的。
  final values = <double>[
    for (final v in likelihood.values)
      if (v > 0) v,
  ];
  final double mean = values.isEmpty
      ? 0.0
      : values.reduce((a, b) => a + b) / values.length;
  double variance = 0.0;
  if (values.length > 1) {
    for (final v in values) {
      variance += (v - mean) * (v - mean);
    }
    variance /= values.length - 1; // uVariance 用的是无偏估计
  }
  final double stdDev = math.sqrt(variance);

  const double epsilon = 0.0001;
  var max = 0.0;
  for (final id in likelihood.keys) {
    final double value = likelihood[id]!;
    var adjusted = 1.0;
    if (value > mean + stdDev) {
      if (mean != 0) adjusted = (value - (stdDev - epsilon)) / mean;
    }
    out[id] = adjusted;
    if (value > max) max = value;
  }

  if (stdDev > epsilon && max != 0) {
    out[-1] = mean / stdDev + 1.0;
  } else {
    out[-1] = 2.0; // 上游注释:2 * std dev
  }
  return out;
}

/// `PredictionModel` 的复刻。
///
/// 我们的"地点"= 已拍照片,图是一条**时间链**(第 k 张与第 k−1 / k+1 相邻),
/// 所以两张之间的图深度 = 序号之差 —— 正是上游
/// `getNeighborsId(id, maxDepth)` 在链状图上返回的东西。
class PlacePredictionModel {
  PlacePredictionModel({
    List<double>? values,
    this.virtualPlacePrior = kBayesVirtualPlacePrior,
  }) : values = values ?? kBayesPredictionLC {
    total = this.values.reduce((a, b) => a + b);
    epsilon = this.values.reduce(math.min);
  }

  final List<double> values;
  final double virtualPlacePrior;
  late final double total;
  late final double epsilon;

  /// 上游 `depth() = values_.size()-1`;values_[d+1] 对应图深度 d。
  int get maxDepth => values.length - 2;

  /// 建一列(某个地点的转移概率)。[index] 是这一列对应地点在 [ids] 里的下标。
  /// 返回长度 = ids.length + 1 的列,第 0 位是虚拟地点。
  List<double> buildColumn(List<int> ids, int index) {
    final size = ids.length + 1;
    final column = List<double>.filled(size, 0.0);

    // addNeighborProb:链状图上,深度 = 序号之差。
    var sum = 0.0;
    for (var j = 0; j < ids.length; j++) {
      final d = (j - index).abs();
      if (d > maxDepth) continue;
      column[j + 1] = values[d + 1];
      sum += column[j + 1];
    }

    // normalize(...) 逐字。
    if (sum < total - values[0]) {
      final delta = total - values[0] - sum;
      column[index + 1] += delta;
      sum += delta;
    }
    final allOther = total < 1 ? 1.0 - total : 0.0;
    if (allOther > 0 && size > 1) {
      final v = allOther / (size - 1);
      for (var j = 1; j < size; j++) {
        if (column[j] == 0) {
          column[j] = v;
          sum += v;
        }
      }
    }
    final maxNorm = 1 - values[0];
    if (sum < maxNorm - 0.0001 || sum > maxNorm + 0.0001) {
      for (var j = 1; j < size; j++) {
        column[j] *= maxNorm / sum;
        if (column[j] < epsilon) column[j] = 0.0;
      }
      sum = maxNorm;
    }
    column[0] = values[0];
    return column;
  }

  /// `fillVirtualPlaceColumn`(PredictionModel.cpp:200)逐字。
  List<double> buildVirtualPlaceColumn(int size) {
    final column = List<double>.filled(size, 0.0);
    if (size > 1) {
      column[0] = virtualPlacePrior;
      final v = (1.0 - virtualPlacePrior) / (size - 1);
      for (var j = 1; j < size; j++) {
        column[j] = v;
      }
    } else if (size > 0) {
      column[0] = 1;
    }
    return column;
  }
}

/// 一次贝叶斯更新的结果。
class LoopHypothesis {
  const LoopHypothesis({
    required this.bestSignatureId,
    required this.bestPosterior,
    required this.virtualPlacePosterior,
  });

  /// 后验最高的那张已拍照片(虚拟地点不算);没有则 0。
  final int bestSignatureId;
  final double bestPosterior;

  /// 「我在一个没去过的新地方」这个假设的后验。
  final double virtualPlacePosterior;

  /// `Rtabmap/LoopThr = 0.11` —— 上游用它卡的就是这个后验。
  bool get isLoopClosure =>
      bestSignatureId > 0 && bestPosterior > kRtabmapLoopThreshold;
}

/// `BayesFilter::computePosterior`(BayesFilter.cpp:150)逐字:
/// `posterior = likelihood ⊙ (Prediction × lastPosterior)`,再归一化。
/// 后验**跨 tick 保留**(递归贝叶斯,这正是它比单帧阈值稳的地方)。
class PlaceBayesFilter {
  PlaceBayesFilter({PlacePredictionModel? model})
    : _model = model ?? PlacePredictionModel();

  final PlacePredictionModel _model;
  List<int> _ids = const <int>[];
  List<double> _posterior = const <double>[];

  List<double> get posterior => List<double>.unmodifiable(_posterior);

  /// [rawLikelihood] = signatureId → 原始 TF-IDF 似然。
  LoopHypothesis update(Map<int, double> rawLikelihood) {
    final adjusted = adjustLikelihood(rawLikelihood);
    final ids = <int>[-1, ...rawLikelihood.keys.toList()..sort()];
    final size = ids.length;

    if (_ids.length != size || !_sameIds(ids)) {
      // 上游 updatePosterior:地点集合变了就重建,新地点取虚拟地点的先验。
      final old = <int, double>{
        for (var i = 0; i < _ids.length; i++) _ids[i]: _posterior[i],
      };
      _posterior = <double>[
        for (final id in ids) old[id] ?? (id == -1 ? 1.0 : 0.0),
      ];
      _ids = ids;
      final s = _posterior.reduce((a, b) => a + b);
      if (s > 0) {
        for (var i = 0; i < _posterior.length; i++) {
          _posterior[i] /= s;
        }
      } else {
        _posterior = <double>[
          for (var i = 0; i < size; i++) i == 0 ? 1.0 : 0.0,
        ];
      }
    }

    // STEP 1 —— prior = Prediction × lastPosterior。
    final prior = List<double>.filled(size, 0.0);
    for (var col = 0; col < size; col++) {
      final column = col == 0
          ? _model.buildVirtualPlaceColumn(size)
          : _model.buildColumn(ids.sublist(1), col - 1);
      final p = _posterior[col];
      if (p == 0) continue;
      for (var row = 0; row < size; row++) {
        prior[row] += column[row] * p;
      }
    }

    // STEP 2 —— 乘观测(似然),再归一化。
    var sum = 0.0;
    for (var i = 0; i < size; i++) {
      _posterior[i] = (adjusted[ids[i]] ?? 1.0) * prior[i];
      sum += _posterior[i];
    }
    if (sum != 0) {
      for (var i = 0; i < size; i++) {
        _posterior[i] /= sum;
      }
    }

    var bestId = 0;
    var best = 0.0;
    for (var i = 1; i < size; i++) {
      if (_posterior[i] > best) {
        best = _posterior[i];
        bestId = ids[i];
      }
    }
    return LoopHypothesis(
      bestSignatureId: bestId,
      bestPosterior: best,
      virtualPlacePosterior: _posterior[0],
    );
  }

  bool _sameIds(List<int> ids) {
    for (var i = 0; i < ids.length; i++) {
      if (_ids[i] != ids[i]) return false;
    }
    return true;
  }

  void clear() {
    _ids = const <int>[];
    _posterior = const <double>[];
  }
}
