// pipeline_eta.dart — the wait countdown for a multi-stage on-device job (sparse finalize today; dense and
// mesh plug in with their own stages).
//
// Composition of cited pieces, nothing invented:
//  · Work model: each stage is N units of work (frames / views / one write); a unit is Ninja's "edge". The
//    per-unit prior comes from this device's last run of the same stage ([EtaPriorLog] = `.ninja_log`) — the
//    per-unit-cost model is also Parallax's α·(N−K) (Morton et al., ICDE 2010, §3).
//  · Prediction: [NinjaProgressPrediction] verbatim (priors until 15 s / 5 % done, dropped when ≥10× off;
//    unknown units take the running average; "?" until at least one unit has a known runtime).
//  · Display policy (user decision 2026-09-15): "计算中…" until the first prediction exists, then ONE coarse
//    label that never changes — "不到一分钟" or "约 N 分钟", N = minutes rounded UP (Kontur design guide:
//    round the remaining time up; https://guides.kontur.ru/components/progress-indicators/progress-bar/).
//  · Ruler (product acceptance): the label is a promise. Late by more than 10 % of the label's upper bound
//    fails (Komatsu, Xie, Yamada, CHI 2024: waits up to 10 % longer than the announced countdown are still
//    perceived as nominal, DOI 10.1145/3613904.3641942); finishing before the label's lower bound also fails
//    (user: "早了或者晚了就是不合格"). Every job records its verdict so the pass rate is measurable.
//
// Sequential-stage accounting: units finish in event order; a batch of k units reported at once shares the
// interval since the previous event evenly (the sum of edge times equals the wall interval, which is what
// Ninja's cpu_time_millis_ sums).
import 'eta_prior_log.dart';
import 'ninja_progress_prediction.dart';

class EtaStage {
  const EtaStage(this.id, this.units);
  final String id;
  final int units;
}

/// The committed coarse label. [minutes] == 0 means "under a minute".
class EtaLabel {
  const EtaLabel(this.minutes);
  final int minutes;

  static EtaLabel bucket(double etaSec) =>
      etaSec < 60 ? const EtaLabel(0) : EtaLabel((etaSec / 60).ceil());

  double get lowerBoundSec => minutes == 0 ? 0 : (minutes - 1) * 60.0;
  double get upperBoundSec => minutes == 0 ? 60 : minutes * 60.0;

  @override
  bool operator ==(Object other) =>
      other is EtaLabel && other.minutes == minutes;
  @override
  int get hashCode => minutes;
  @override
  String toString() =>
      minutes == 0 ? 'EtaLabel(<1 min)' : 'EtaLabel(~$minutes min)';
}

enum EtaVerdict { ok, early, late, uncommitted }

class EtaRulerResult {
  const EtaRulerResult({
    required this.verdict,
    required this.label,
    required this.committedEtaSec,
    required this.actualSec,
    required this.totalSec,
  });
  final EtaVerdict verdict;
  final EtaLabel? label;
  final double? committedEtaSec;

  /// Wall seconds from the commit to the finish (null when never committed).
  final double? actualSec;
  final double totalSec;
  bool get pass => verdict == EtaVerdict.ok;

  Map<String, Object?> toTelemetry() => {
    'verdict': verdict.name,
    'label_min': label?.minutes,
    'committed_eta_s': committedEtaSec,
    'actual_s': actualSec,
    'total_s': totalSec,
  };
}

/// Komatsu et al. CHI 2024: +10 % is below the perceptual threshold.
const double kEtaLateToleranceFraction = 0.10;

class PipelineEta {
  PipelineEta({
    required List<EtaStage> stages,
    required EtaPriorLog priors,
    required this.startMs,
  }) : _stages = List.of(stages),
       _priors = priors {
    for (final s in _stages) {
      final prior = priors.priorUnitMs(s.id);
      _priorUnitMs[s.id] = prior;
      _done[s.id] = 0;
      for (var i = 0; i < s.units; i++) {
        _ninja.edgeAddedToPlan(prior);
      }
    }
    _lastEndMs = startMs;
  }

  final List<EtaStage> _stages;
  final EtaPriorLog _priors;
  final int startMs;
  final _ninja = NinjaProgressPrediction();
  final Map<String, int> _priorUnitMs = {};
  final Map<String, int> _done = {};
  final Map<String, int> _stageStartMs = {};
  final Map<String, int> _stageEndMs = {};
  int _lastEndMs = 0;

  EtaLabel? _committed;
  int? _committedAtMs;
  double? _committedEtaSec;
  bool _finished = false;

  List<EtaStage> get stages => _stages;
  EtaLabel? get committed => _committed;
  int? get committedAtMs => _committedAtMs;
  double? get committedEtaSec => _committedEtaSec;
  bool get finished => _finished;
  int unitsDone(String stageId) => _done[stageId] ?? 0;

  EtaStage? _stage(String id) {
    for (final s in _stages) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Corrects a stage's unit count before any of its units finished (a stage's
  /// real total is often only known when it starts). Ninja's plan is mutable in
  /// exactly this way (EdgeAddedToPlan / EdgeRemovedFromPlan, status_printer.cc
  /// L91-116); a committed label is never revisited.
  void setUnits(String stageId, int units) {
    if (_finished || units < 0) return;
    final idx = _stages.indexWhere((s) => s.id == stageId);
    if (idx < 0 || (_done[stageId] ?? 0) > 0) return;
    final cur = _stages[idx].units;
    if (cur == units) return;
    final prior = _priorUnitMs[stageId]!;
    if (units > cur) {
      for (var i = cur; i < units; i++) {
        _ninja.edgeAddedToPlan(prior);
      }
    } else {
      for (var i = units; i < cur; i++) {
        _ninja.edgeRemovedFromPlan(prior);
      }
    }
    _stages[idx] = EtaStage(stageId, units);
  }

  /// Cumulative units finished for [stageId] as of [nowMs]. Idempotent for repeated counts.
  void markUnits(String stageId, int doneUnits, int nowMs) {
    if (_finished) return;
    final s = _stage(stageId);
    if (s == null) return;
    final prev = _done[stageId]!;
    final target = doneUnits.clamp(0, s.units);
    final k = target - prev;
    if (k <= 0) return;
    if (nowMs < _lastEndMs) nowMs = _lastEndMs;
    _stageStartMs.putIfAbsent(stageId, () => _lastEndMs);
    final span = nowMs - _lastEndMs;
    final prior = _priorUnitMs[stageId]!;
    for (var i = 0; i < k; i++) {
      final a = _lastEndMs + (span * i) ~/ k;
      final b = _lastEndMs + (span * (i + 1)) ~/ k;
      _ninja.buildEdgeFinished(prior, a - startMs, b - startMs);
    }
    _lastEndMs = nowMs;
    _done[stageId] = target;
    if (target == s.units) _stageEndMs[stageId] = nowMs;
  }

  void markStageDone(String stageId, int nowMs) {
    final s = _stage(stageId);
    if (s == null) return;
    if (s.units == 0) {
      _stageStartMs.putIfAbsent(stageId, () => _lastEndMs);
      _stageEndMs[stageId] = nowMs;
      return;
    }
    markUnits(stageId, s.units, nowMs);
  }

  /// Ninja's %E at [nowMs] (BuildEdgeStarted sets time_millis_ = now for the running edge). null = "?".
  double? etaSeconds(int nowMs) {
    if (_finished) return 0;
    _ninja.buildEdgeStarted(
      (nowMs < _lastEndMs ? _lastEndMs : nowMs) - startMs,
    );
    final eta = _ninja.etaSeconds();
    _ninja
        .runningEdges--; // undo the bookkeeping of the pseudo-start (Ninja counts it per real edge)
    _ninja.startedEdges--;
    return eta;
  }

  /// "计算中…" (null) until the first prediction; from then on the same label, forever.
  EtaLabel? labelAt(int nowMs) {
    if (_committed != null) return _committed;
    final eta = etaSeconds(nowMs);
    if (eta == null) return null;
    _committed = EtaLabel.bucket(eta);
    _committedAtMs = nowMs;
    _committedEtaSec = eta;
    return _committed;
  }

  /// Job done: records each stage's actual duration into the prior log (Ninja writes its log after the build)
  /// and returns the ruler verdict for the committed label.
  EtaRulerResult finish(int nowMs) {
    _finished = true;
    for (final s in _stages) {
      final a = _stageStartMs[s.id], b = _stageEndMs[s.id];
      if (a == null || b == null || s.units <= 0) continue;
      _priors.record(s.id, units: s.units, ms: b - a);
    }
    final totalSec = (nowMs - startMs) / 1e3;
    final label = _committed;
    if (label == null) {
      return EtaRulerResult(
        verdict: EtaVerdict.uncommitted,
        label: null,
        committedEtaSec: null,
        actualSec: null,
        totalSec: totalSec,
      );
    }
    final actual = (nowMs - _committedAtMs!) / 1e3;
    final EtaVerdict v;
    if (actual < label.lowerBoundSec) {
      v = EtaVerdict.early;
    } else if (actual > label.upperBoundSec * (1 + kEtaLateToleranceFraction)) {
      v = EtaVerdict.late;
    } else {
      v = EtaVerdict.ok;
    }
    return EtaRulerResult(
      verdict: v,
      label: label,
      committedEtaSec: _committedEtaSec,
      actualSec: actual,
      totalSec: totalSec,
    );
  }
}
