import 'dart:math' as math;

import 'captured_frame_sample.dart';
import 'dome_cell_state.dart';

class ViewGraphFrameCandidate {
  final CapturedFrameSample sample;
  final int pointIndex;
  final int azIndex;
  final int elIndex;
  final DomeCellState state;
  final List<int> neighborPointIndices;
  final double neighborSupport;

  const ViewGraphFrameCandidate({
    required this.sample,
    required this.pointIndex,
    required this.azIndex,
    required this.elIndex,
    required this.state,
    required this.neighborPointIndices,
    required this.neighborSupport,
  });
}

class ViewGraphSelection {
  final ViewGraphFrameCandidate candidate;
  final double score;
  final int radiusShellId;
  final double graphConnectivity;
  final double matchabilityScore;
  final List<String> da3NeighborFrameIds;

  const ViewGraphSelection({
    required this.candidate,
    required this.score,
    required this.radiusShellId,
    required this.graphConnectivity,
    required this.matchabilityScore,
    required this.da3NeighborFrameIds,
  });
}

class SessionViewGraphCurator {
  final int totalBudget;
  final int baseFramesPerPoint;
  final int softCapPerPoint;
  final int hardCapPerPoint;

  const SessionViewGraphCurator({
    this.totalBudget = 590,
    this.baseFramesPerPoint = 5,
    this.softCapPerPoint = 12,
    this.hardCapPerPoint = 20,
  });

  List<ViewGraphSelection> select(List<ViewGraphFrameCandidate> candidates) {
    if (candidates.isEmpty || totalBudget <= 0) {
      return const <ViewGraphSelection>[];
    }
    final shellIds = _assignRadiusShells(candidates);
    final nodes = <_Node>[
      for (var i = 0; i < candidates.length; i++)
        _Node(candidate: candidates[i], index: i, radiusShellId: shellIds[i]),
    ];
    final edges = _buildEdges(nodes);
    final byPoint = <int, List<_Node>>{};
    for (final node in nodes) {
      byPoint.putIfAbsent(node.candidate.pointIndex, () => <_Node>[]).add(node);
    }

    final selected = <_Node>[];
    final selectedIds = <String>{};
    final selectedPerPoint = <int, int>{};

    for (final group in byPoint.values) {
      group.sort((a, b) => _scoreOf(b, edges).compareTo(_scoreOf(a, edges)));
      final preferred = group.where((n) => n.radiusShellId >= 0).toList();
      final pool = preferred.isEmpty ? group : preferred;
      final take = math.min(baseFramesPerPoint, pool.length);
      final chosen = _greedyDiverse(pool, take, edges);
      for (final node in chosen) {
        if (selected.length >= totalBudget) break;
        _addSelected(node, selected, selectedIds, selectedPerPoint);
      }
    }

    final remaining = nodes.where((n) => !selectedIds.contains(n.id)).toList()
      ..sort((a, b) => _scoreOf(b, edges).compareTo(_scoreOf(a, edges)));
    for (final node in remaining) {
      if (selected.length >= totalBudget) break;
      final point = node.candidate.pointIndex;
      final cap = node.radiusShellId >= 0
          ? softCapPerPoint
          : baseFramesPerPoint;
      if ((selectedPerPoint[point] ?? 0) >= math.min(cap, hardCapPerPoint)) {
        continue;
      }
      _addSelected(node, selected, selectedIds, selectedPerPoint);
    }

    selected.sort((a, b) => _scoreOf(b, edges).compareTo(_scoreOf(a, edges)));
    final selectedSet = selected.map((n) => n.index).toSet();
    final nodeByIndex = {for (final node in nodes) node.index: node};
    return [
      for (final node in selected)
        ViewGraphSelection(
          candidate: node.candidate,
          score: _scoreOf(node, edges),
          radiusShellId: node.radiusShellId,
          graphConnectivity: _connectivityOf(node, edges),
          matchabilityScore: _matchabilityOf(node, edges),
          da3NeighborFrameIds: _topNeighborFrameIds(
            node,
            edges,
            selectedSet,
            nodeByIndex,
          ),
        ),
    ];
  }

  List<_Node> _greedyDiverse(
    List<_Node> pool,
    int take,
    Map<int, List<_Edge>> edges,
  ) {
    final remaining = pool.toList();
    final chosen = <_Node>[];
    while (remaining.isNotEmpty && chosen.length < take) {
      var bestIdx = 0;
      var bestScore = double.negativeInfinity;
      for (var i = 0; i < remaining.length; i++) {
        final node = remaining[i];
        final score =
            _scoreOf(node, edges) * 0.78 +
            _angularNoveltyScore(node, chosen) * 0.16 +
            _radiusNoveltyScore(node, chosen) * 0.06;
        if (score > bestScore) {
          bestScore = score;
          bestIdx = i;
        }
      }
      chosen.add(remaining.removeAt(bestIdx));
    }
    return chosen;
  }

  void _addSelected(
    _Node node,
    List<_Node> selected,
    Set<String> selectedIds,
    Map<int, int> selectedPerPoint,
  ) {
    selected.add(node);
    selectedIds.add(node.id);
    selectedPerPoint[node.candidate.pointIndex] =
        (selectedPerPoint[node.candidate.pointIndex] ?? 0) + 1;
  }

  List<int> _assignRadiusShells(List<ViewGraphFrameCandidate> candidates) {
    final logR = <double>[];
    for (final c in candidates) {
      final r = c.sample.cameraRadiusM;
      if (r.isFinite && r > 0.05) logR.add(math.log(r));
    }
    if (logR.length < 4) {
      return List<int>.filled(candidates.length, 0, growable: false);
    }
    logR.sort();
    final median = _medianSorted(logR);
    final deviations = logR.map((v) => (v - median).abs()).toList()..sort();
    final mad = _medianSorted(deviations);
    final tolerance = math.min(
      math.log(2.0),
      math.max(math.log(1.45), mad * 2.5),
    );

    final shellIds = List<int>.filled(candidates.length, -1, growable: false);
    final secondaryBuckets = <int, List<int>>{};
    for (var i = 0; i < candidates.length; i++) {
      final r = candidates[i].sample.cameraRadiusM;
      if (!r.isFinite || r <= 0.05) {
        shellIds[i] = 0;
        continue;
      }
      final lr = math.log(r);
      if ((lr - median).abs() <= tolerance) {
        shellIds[i] = 0;
      } else {
        final bucket = ((lr - median) / math.log(1.35)).round();
        secondaryBuckets.putIfAbsent(bucket, () => <int>[]).add(i);
      }
    }

    var nextShell = 1;
    for (final bucket in secondaryBuckets.values) {
      final pointCount = bucket
          .map((i) => candidates[i].pointIndex)
          .toSet()
          .length;
      if (bucket.length >= 8 && pointCount >= 3) {
        for (final i in bucket) {
          shellIds[i] = nextShell;
        }
        nextShell++;
      }
    }
    return shellIds;
  }

  Map<int, List<_Edge>> _buildEdges(List<_Node> nodes) {
    final edges = <int, List<_Edge>>{
      for (final node in nodes) node.index: <_Edge>[],
    };
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        final score = _edgeScore(nodes[i], nodes[j]);
        if (score <= 0) continue;
        edges[i]!.add(_Edge(to: j, score: score));
        edges[j]!.add(_Edge(to: i, score: score));
      }
    }
    for (final list in edges.values) {
      list.sort((a, b) => b.score.compareTo(a.score));
    }
    return edges;
  }

  double _edgeScore(_Node a, _Node b) {
    final samePoint = a.candidate.pointIndex == b.candidate.pointIndex;
    final neighborPoint =
        a.candidate.neighborPointIndices.contains(b.candidate.pointIndex) ||
        b.candidate.neighborPointIndices.contains(a.candidate.pointIndex);
    final angularDeg = _angularDistanceDeg(a.sample, b.sample);
    if (!samePoint && !neighborPoint && angularDeg > 18.0) return 0.0;

    final radiusRatio = _radiusRatio(
      a.sample.cameraRadiusM,
      b.sample.cameraRadiusM,
    );
    final shellGap = (a.radiusShellId - b.radiusShellId).abs();
    if (a.radiusShellId < 0 || b.radiusShellId < 0) return 0.0;
    if (shellGap == 0 && radiusRatio > 1.55) return 0.0;
    if (shellGap == 1 && radiusRatio > 1.85) return 0.0;
    if (shellGap > 1) return 0.0;

    final angleScore = _sweetSpotScore(
      angularDeg,
      min: 2.0,
      ideal: 8.0,
      max: 20.0,
    );
    final radiusScore = radiusRatio <= 1.0
        ? 1.0
        : _clamp01(1.0 - (radiusRatio - 1.0) / 0.55);
    final timeScore = _clamp01(
      (a.sample.timestamp - b.sample.timestamp).abs() / 0.5,
    );
    final focusScore = (a.sample.focusStable && b.sample.focusStable)
        ? 1.0
        : 0.0;
    return angleScore * 0.42 +
        radiusScore * 0.25 +
        timeScore * 0.12 +
        focusScore * 0.12 +
        (neighborPoint ? 0.09 : 0.0);
  }

  double _scoreOf(_Node node, Map<int, List<_Edge>> edges) {
    final s = node.sample;
    final sharp = _effectiveSharpness(s);
    final sharpScore = _clamp01((sharp - 420.0) / 900.0);
    final edgeScore = _clamp01((s.edgeBlockSharpness - 180.0) / 700.0);
    final motionScore = 1.0 - _clamp01(s.motionScore);
    final exposureScore = _clamp01(s.exposureScore);
    final poseScore = s.poseSource == 'arkit' ? 1.0 : 0.35;
    final shellScore = node.radiusShellId >= 0 ? 1.0 : 0.05;
    final graphScore = _connectivityOf(node, edges);
    final radiusScore = s.cameraRadiusM > 0.05 ? 1.0 : 0.35;
    return sharpScore * 0.32 +
        edgeScore * 0.10 +
        motionScore * 0.12 +
        exposureScore * 0.08 +
        poseScore * 0.12 +
        shellScore * 0.12 +
        graphScore * 0.10 +
        radiusScore * 0.04;
  }

  double _connectivityOf(_Node node, Map<int, List<_Edge>> edges) {
    final list = edges[node.index] ?? const <_Edge>[];
    if (list.isEmpty) return 0.0;
    return _clamp01(
      list.take(4).fold<double>(0.0, (sum, e) => sum + e.score) / 2.5,
    );
  }

  double _matchabilityOf(_Node node, Map<int, List<_Edge>> edges) {
    final list = edges[node.index] ?? const <_Edge>[];
    if (list.isEmpty) return 0.0;
    return _clamp01(list.first.score);
  }

  double _angularNoveltyScore(_Node node, List<_Node> selected) {
    if (selected.isEmpty) return 1.0;
    var minDeg = double.infinity;
    for (final other in selected) {
      minDeg = math.min(minDeg, _angularDistanceDeg(node.sample, other.sample));
    }
    return _clamp01(minDeg / 5.0);
  }

  double _radiusNoveltyScore(_Node node, List<_Node> selected) {
    if (selected.isEmpty) return 1.0;
    var minLog = double.infinity;
    for (final other in selected) {
      if (node.sample.cameraRadiusM <= 0.05 ||
          other.sample.cameraRadiusM <= 0.05) {
        continue;
      }
      minLog = math.min(
        minLog,
        (math.log(node.sample.cameraRadiusM) -
                math.log(other.sample.cameraRadiusM))
            .abs(),
      );
    }
    if (minLog == double.infinity) return 0.0;
    return _clamp01(minLog / math.log(1.20));
  }

  List<String> _topNeighborFrameIds(
    _Node node,
    Map<int, List<_Edge>> edges,
    Set<int> selectedSet,
    Map<int, _Node> nodeByIndex,
  ) {
    final out = <String>[];
    for (final edge in edges[node.index] ?? const <_Edge>[]) {
      if (!selectedSet.contains(edge.to)) continue;
      out.add(nodeByIndex[edge.to]?.id ?? '');
      if (out.length == 2) break;
    }
    out.removeWhere((id) => id.isEmpty);
    return out;
  }

  static double _effectiveSharpness(CapturedFrameSample s) {
    if (s.sharpnessConsensus > 0) return s.sharpnessConsensus;
    if (s.roiSharpness > 0) return s.roiSharpness;
    return s.sharpness;
  }

  static double _radiusRatio(double a, double b) {
    if (!a.isFinite || !b.isFinite || a <= 0.05 || b <= 0.05) return 1.0;
    final hi = a > b ? a : b;
    final lo = a > b ? b : a;
    return hi / lo;
  }

  static double _sweetSpotScore(
    double value, {
    required double min,
    required double ideal,
    required double max,
  }) {
    if (value <= min || value >= max) return 0.0;
    if (value <= ideal) return _clamp01((value - min) / (ideal - min));
    return _clamp01(1.0 - (value - ideal) / (max - ideal));
  }

  static double _angularDistanceDeg(
    CapturedFrameSample a,
    CapturedFrameSample b,
  ) {
    final aCosEl = math.cos(a.elevation);
    final bCosEl = math.cos(b.elevation);
    final dot =
        aCosEl * bCosEl * math.cos(a.azimuth - b.azimuth) +
        math.sin(a.elevation) * math.sin(b.elevation);
    return math.acos(dot.clamp(-1.0, 1.0).toDouble()) * 180.0 / math.pi;
  }

  static double _medianSorted(List<double> sorted) {
    if (sorted.isEmpty) return 0.0;
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) * 0.5;
  }

  static double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);
}

class _Node {
  final ViewGraphFrameCandidate candidate;
  final int index;
  final int radiusShellId;

  const _Node({
    required this.candidate,
    required this.index,
    required this.radiusShellId,
  });

  CapturedFrameSample get sample => candidate.sample;
  String get id => sample.frameId;
}

class _Edge {
  final int to;
  final double score;

  const _Edge({required this.to, required this.score});
}
