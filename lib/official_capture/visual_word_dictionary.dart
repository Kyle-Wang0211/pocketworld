// 增量视觉词典 + 倒排索引 + TF-IDF 似然 —— RTAB-Map 的复刻。
//
// 用途:回答"当前这个视角,哪一张已拍照片覆盖过它"。这是**重定位**问题;
// 光流做不了(LK 没有「匹配对不对」的概念,跨大位移会收敛到垃圾并报成功)。
// 方案与出处见 docs/handoffs/PLACE_RECOGNITION_RTABMAP_PLAN.md。
//
// 源:RTAB-Map(BSD-3)。**不带预训练词表** —— `Kp/IncrementalDictionary=true`、
// `Kp/DictionaryPath=""`(rtabmap_Parameters.h:256,275),词典跑的时候自己长出来,
// 出货成本 0。对比 stella_vslam 要带 42.9 MB 的 ORB 词表。
//
// 抄来的常数(全部有出处):
//   Kp/NndrRatio        0.8   Lowe 比值,判"这个描述子是老词还是新词"
//   Kp/MaxFeatures      500   每帧特征上限
//   Kp/TfIdfLikelihoodUsed true
//
// **不抄** `Rtabmap/LoopThr = 0.11` —— 那是贝叶斯**后验**的门,不是原始似然的
// 门,直接拿来卡似然是移位前提。判决仍走我们已复刻的 stella
// `almost_all_lms_are_tracked`(比例 0.9),本文件只负责"哪张老照片最像"。

import 'dart:math' as math;
import 'dart:typed_data';

import 'orb_descriptor.dart';

/// `Kp/NndrRatio` 默认值(rtabmap_Parameters.h:265)。
const double kRtabmapNndrRatio = 0.8;

/// `Kp/MaxFeatures` 默认值(rtabmap_Parameters.h:262)。
const int kRtabmapMaxFeatures = 500;

/// `Mem/STMSize` 默认 **10**(rtabmap_Parameters.h:226)。
///
/// 🔴 这一层我一开始漏了,后果很具体:`Rtabmap::process` 里
/// `computeLikelihood(signature, signaturesToCompare)` 的候选来自
/// **`getWorkingMem()`,不是 STM** —— 一个地点要等 STM 满了才转进工作记忆
/// (`Memory.cpp:1588`)。**所以最近 10 个地点整个不参与回环判定。**
/// 它防的正是"紧邻的上一张永远看起来最像"这件结构性的事:
/// 2026-09-10 实测,单向前进、从不回头的轨迹上,不排除 STM 会判出
/// **113 次**回环(最高后验 0.641),全是误判。
const int kRtabmapStmSize = 10;

/// 一张已拍照片在词典里的身份 = 它的词袋。
class SignatureWords {
  SignatureWords(this.signatureId, this.wordCounts)
    : totalWordCount = wordCounts.values.fold<int>(0, (a, b) => a + b);

  final int signatureId;

  /// 词 id → 这张图里出现了几次(上游的 `nwi`)。
  final Map<int, int> wordCounts;

  /// 上游 `Memory::getNi()` —— 这张图的词总数。
  final int totalWordCount;
}

/// 增量视觉词典。近邻用**暴力汉明**:上游 `Kp/NNStrategy` 的菜单里就有
/// `Brute Force=3`,而我们一场最多几百张图、每张 ≤500 个描述子,暴力是精确的,
/// 不引入近似(FLANN LSH 是近似的,会让复刻多一层不可控)。
class VisualWordDictionary {
  final List<Uint8List> _wordDescriptors = <Uint8List>[];

  /// 倒排索引:词 id → {signatureId: 该词在该图里的出现次数}。
  final List<Map<int, int>> _wordReferences = <Map<int, int>>[];

  final Map<int, SignatureWords> _signatures = <int, SignatureWords>{};

  int get wordCount => _wordDescriptors.length;
  int get signatureCount => _signatures.length;
  Iterable<SignatureWords> get signatures => _signatures.values;

  /// `VWDictionary::addNewWords`(VWDictionary.cpp:1212-1259)逐字:
  ///
  ///     badDist = false
  ///     if fullResults 为空                       → badDist = true
  ///     else if fullResults.size() >= 2:
  ///         if dist[0] > nndrRatio * dist[1]      → badDist = true   // NNDR 拒绝
  ///     else                                      → badDist = true   // 候选不足 2 个
  ///     badDist ? 建新词 : 归到最近的老词
  ///
  /// 返回这批描述子各自落到的词 id。
  List<int> addNewWords(List<Uint8List> descriptors, int signatureId) {
    final ids = <int>[];
    for (final d in descriptors) {
      ids.add(_assignOrCreate(d));
    }
    final counts = <int, int>{};
    for (final id in ids) {
      counts[id] = (counts[id] ?? 0) + 1;
    }
    for (final e in counts.entries) {
      _wordReferences[e.key][signatureId] = e.value;
    }
    _signatures[signatureId] = SignatureWords(signatureId, counts);
    return ids;
  }

  /// 只查不改 —— 查询帧不该把自己的词写进词典(否则它跟每张图都"共享"新词)。
  Map<int, int> quantizeQuery(List<Uint8List> descriptors) {
    final counts = <int, int>{};
    for (final d in descriptors) {
      final nn = _twoNearest(d);
      if (nn.length < 2) continue; // 上游同款:候选不足 2 个不算匹配
      if (nn[0].distance > kRtabmapNndrRatio * nn[1].distance) continue;
      counts[nn[0].wordId] = (counts[nn[0].wordId] ?? 0) + 1;
    }
    return counts;
  }

  int _assignOrCreate(Uint8List descriptor) {
    final nn = _twoNearest(descriptor);
    var badDist = nn.isEmpty;
    if (!badDist) {
      if (nn.length >= 2) {
        if (nn[0].distance > kRtabmapNndrRatio * nn[1].distance) {
          badDist = true;
        }
      } else {
        badDist = true;
      }
    }
    if (badDist) {
      _wordDescriptors.add(descriptor);
      _wordReferences.add(<int, int>{});
      return _wordDescriptors.length - 1;
    }
    return nn[0].wordId;
  }

  List<_Neighbour> _twoNearest(Uint8List d) {
    if (_wordDescriptors.isEmpty) return const <_Neighbour>[];
    var best = -1, bestD = 1 << 30, second = -1, secondD = 1 << 30;
    for (var i = 0; i < _wordDescriptors.length; i++) {
      // 只要"是不是进前二",比 secondD 还远的具体值不影响结果 ⇒ 提前收手。
      final dist = hammingDistanceBounded(d, _wordDescriptors[i], secondD);
      if (dist < bestD) {
        secondD = bestD;
        second = best;
        bestD = dist;
        best = i;
      } else if (dist < secondD) {
        secondD = dist;
        second = i;
      }
    }
    final out = <_Neighbour>[_Neighbour(best, bestD)];
    if (second >= 0) out.add(_Neighbour(second, secondD));
    return out;
  }

  /// `Memory::computeLikelihood` 的 TF-IDF 分支(Memory.cpp:2283)逐字:
  ///
  ///     nw     = 引用该词的地点数
  ///     logNnw = log10(N / nw)
  ///     若 logNnw != 0:  likelihood[j] += (nwi * logNnw) / ni
  ///
  /// 返回 signatureId → 似然。没有任何阈值 —— 取 argmax 是调用方的事。
  Map<int, double> computeLikelihood(Map<int, int> queryWordCounts) {
    final likelihood = <int, double>{
      for (final id in _signatures.keys) id: 0.0,
    };
    final n = _signatures.length;
    if (n == 0) return likelihood;
    for (final wordId in queryWordCounts.keys) {
      final refs = _wordReferences[wordId];
      final nw = refs.length;
      if (nw == 0) continue;
      final logNnw = _log10(n / nw);
      if (logNnw == 0) continue;
      for (final e in refs.entries) {
        final sig = _signatures[e.key];
        if (sig == null || sig.totalWordCount == 0) continue;
        likelihood[e.key] =
            (likelihood[e.key] ?? 0) + (e.value * logNnw) / sig.totalWordCount;
      }
    }
    return likelihood;
  }

  /// `Signature::compareTo` 的词袋分支(Signature.cpp)逐字:
  /// `similarity = 配对词数 / max(两边词数)`。这个**比例**与我们现役的
  /// `commonTrackCount / seedTrackCount` 同形状,所以能直接喂进 stella 的
  /// `almost_all_lms_are_tracked`,不必新增阈值。
  /// 返回 (共享词数, 参考图词数) —— 分别对应上游的
  /// `num_reliable_lms` 与 `num_reliable_lms_ref`。
  (int, int) sharedWordsWith(Map<int, int> queryWordCounts, int signatureId) {
    final sig = _signatures[signatureId];
    if (sig == null) return (0, 0);
    var shared = 0;
    for (final e in queryWordCounts.entries) {
      final inRef = sig.wordCounts[e.key];
      if (inRef != null) shared += math.min(e.value, inRef);
    }
    return (shared, sig.totalWordCount);
  }

  void clear() {
    _wordDescriptors.clear();
    _wordReferences.clear();
    _signatures.clear();
  }
}

double _log10(double v) => math.log(v) / math.ln10;

class _Neighbour {
  const _Neighbour(this.wordId, this.distance);
  final int wordId;
  final int distance;
}

/// 一次地点识别的结果 + 代价(留账给提速用)。
class PlaceRecognitionScan {
  const PlaceRecognitionScan({
    required this.signatureCount,
    required this.wordCount,
    required this.queryWordCount,
    required this.bestSignatureId,
    required this.bestSharedWords,
    required this.bestReferenceWords,
    required this.describeMicros,
    required this.queryMicros,
  });

  final int signatureCount;
  final int wordCount;
  final int queryWordCount;

  /// 共享词最多的那张已拍照片 = 上游的 `ref_keyfrm`;没有则 0。
  final int bestSignatureId;
  final int bestSharedWords;
  final int bestReferenceWords;

  final int describeMicros;
  final int queryMicros;

  bool get hasMatch => bestSignatureId > 0 && bestReferenceWords > 0;

  /// 与 stella `almost_all_lms_are_tracked` 同形状的比例。
  double get bestSharedRatio =>
      bestReferenceWords == 0 ? 0 : bestSharedWords / bestReferenceWords;
}
