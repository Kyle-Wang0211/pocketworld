// eta_prior_log.dart — the role of Ninja's `.ninja_log` for our pipeline stages: the last run's duration per
// stage on this device. ninja.cc L356-367 (ParsePreviousElapsedTimes): an edge's prior is the log entry's
// `end_time - start_time`, and -1 when the log has no entry. Our "edges" are a stage's units (frames/views),
// so a stage's per-unit prior is the recorded `ms ~/ units`; no record ⇒ [kNoPrevElapsed].
//
// One JSON object, one entry per stage id: {"sparse.refine": {"units": 21, "ms": 3837}, ...}. Written after a
// job finishes, read when the next job is planned. Nothing else is stored here (no thermal keys, no history
// beyond the last run — that is exactly Ninja's scope).
import 'dart:convert';
import 'dart:io';

import 'ninja_progress_prediction.dart';

class EtaPriorLog {
  EtaPriorLog(this.file);

  final File file;
  final Map<String, ({int units, int ms})> _entries = {};

  Map<String, ({int units, int ms})> get entries => Map.unmodifiable(_entries);

  Future<void> load() async {
    _entries.clear();
    try {
      if (!await file.exists()) return;
      final raw = jsonDecode(await file.readAsString());
      if (raw is! Map) return;
      for (final e in raw.entries) {
        final v = e.value;
        if (v is! Map) continue;
        final units = v['units'], ms = v['ms'];
        if (units is int && ms is int) {
          _entries[e.key.toString()] = (units: units, ms: ms);
        }
      }
    } catch (_) {
      // A corrupt log is the same as no log: every stage starts unpredictable.
      _entries.clear();
    }
  }

  /// `prev_elapsed_time_millis` for one unit of [stageId]; -1 when unknown.
  int priorUnitMs(String stageId) {
    final e = _entries[stageId];
    if (e == null || e.units <= 0) return kNoPrevElapsed;
    return (e.ms / e.units).round();
  }

  void record(String stageId, {required int units, required int ms}) {
    if (units <= 0 || ms < 0) return;
    _entries[stageId] = (units: units, ms: ms);
  }

  Future<void> save() async {
    final out = <String, Object?>{
      for (final e in _entries.entries)
        e.key: {'units': e.value.units, 'ms': e.value.ms},
    };
    await file.parent.create(recursive: true);
    await file.writeAsString(jsonEncode(out), flush: true);
  }
}
