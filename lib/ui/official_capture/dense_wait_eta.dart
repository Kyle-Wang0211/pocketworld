// dense_wait_eta.dart — the dense stage's wait countdown, kept OUTSIDE the page so a re-entered page shows
// the label that was committed when the job started (commit-once, user decision 2026-09-15).
//
// Feeds lib/eta's PipelineEta from the global `denseStageProgress` notifier (lib/dense): the phases the
// native pipeline reports — session, images, infer, fuse — become Ninja stages whose unit counts are the
// phase totals (corrected the moment each phase starts, see PipelineEta.setUnits). Priors come from the same
// per-device log as the sparse stages. The ruler verdict goes to telemetry + the device log when the job ends.
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../../dense/dense_stage_progress.dart';
import '../../eta/eta_prior_log.dart';
import '../../eta/pipeline_eta.dart';
import '../../official_capture/telemetry_writer.dart';
import '../../official_util/device_log.dart';

const String kDenseEtaPriorLogName = 'official_eta_prior_log.json';

class DenseWaitEta {
  DenseWaitEta._();
  static final DenseWaitEta instance = DenseWaitEta._();

  /// The committed label (or null = "计算中…") for the capture dir currently running/finished.
  final ValueNotifier<EtaLabel?> label = ValueNotifier<EtaLabel?>(null);

  String? _captureDir;
  PipelineEta? _eta;
  EtaPriorLog? _priors;
  bool _attached = false;
  Timer? _ticker;
  Future<EtaPriorLog>? _priorsLoading;

  /// Idempotent: start observing the dense progress notifier.
  void ensureAttached() {
    if (_attached) return;
    _attached = true;
    denseStageProgress.addListener(_onProgress);
    _onProgress();
  }

  PipelineEta? get current => _eta;

  Future<EtaPriorLog> _loadPriors() => _priorsLoading ??= () async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final log = EtaPriorLog(File('${docs.path}/$kDenseEtaPriorLogName'));
      await log.load();
      return log;
    } catch (e) {
      DeviceLog.log('DenseWaitEta', 'prior log unavailable: $e');
      return EtaPriorLog(
        File('${Directory.systemTemp.path}/$kDenseEtaPriorLogName'),
      );
    }
  }();

  void _onProgress() {
    final p = denseStageProgress.value;
    if (p == null) return;
    if (p.captureDir != _captureDir) {
      // a new job: forget the previous one (its verdict was already recorded)
      _captureDir = p.captureDir;
      _eta = null;
      label.value = null;
      _priorsLoading = null;
      if (p.state == DenseStageState.running) unawaited(_plan(p));
    }
    final eta = _eta;
    if (eta == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    switch (p.state) {
      case DenseStageState.running:
        if (p.total > 0 && _stageIdFor(p.phase) != null) {
          final id = _stageIdFor(p.phase)!;
          eta.setUnits(
            id,
            p.total,
          ); // the phase's real total, known at its start
          eta.markUnits(id, p.done, now);
          // the earlier phases are complete once a later phase reports
          for (final s in eta.stages) {
            if (s.id == id) break;
            eta.markStageDone(s.id, now);
          }
        }
        label.value ??= eta.labelAt(now);
      case DenseStageState.done:
      case DenseStageState.failed:
        _finish(ok: p.state == DenseStageState.done);
    }
  }

  static String? _stageIdFor(String phase) => switch (phase) {
    'session' => 'dense.session',
    'images' => 'dense.images',
    'infer' => 'dense.infer',
    'fuse' => 'dense.fuse',
    _ => null,
  };

  Future<void> _plan(DenseStageProgress p) async {
    final startMs =
        p.startedAt?.millisecondsSinceEpoch ??
        DateTime.now().millisecondsSinceEpoch;
    final priors = await _loadPriors();
    if (denseStageProgress.value?.captureDir != p.captureDir || _eta != null)
      return;
    _priors = priors;
    // unit counts are corrected per phase as they start (setUnits); 1 is the placeholder
    _eta = PipelineEta(
      stages: const [
        EtaStage('dense.session', 1),
        EtaStage('dense.images', 1),
        EtaStage('dense.infer', 1),
        EtaStage('dense.fuse', 1),
      ],
      priors: priors,
      startMs: startMs,
    );
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (t) {
      final eta = _eta;
      if (eta == null || eta.finished) {
        t.cancel();
        return;
      }
      label.value ??= eta.labelAt(DateTime.now().millisecondsSinceEpoch);
    });
    _onProgress();
  }

  void _finish({required bool ok}) {
    final eta = _eta;
    if (eta == null || eta.finished) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final s in eta.stages) {
      eta.markStageDone(s.id, now);
    }
    final r = eta.finish(now);
    _ticker?.cancel();
    TelemetryWriter.instance.event('eta_ruler', {
      ...r.toTelemetry(),
      'job': 'dense',
      'ok': ok,
    });
    DeviceLog.log(
      'DenseWaitEta',
      'eta ruler: ${r.verdict.name} label=${r.label} committed=${r.committedEtaSec?.toStringAsFixed(1)}s '
          'actual=${r.actualSec?.toStringAsFixed(1)}s total=${r.totalSec.toStringAsFixed(1)}s',
    );
    if (ok) {
      unawaited(
        _priors?.save().catchError((Object e) {
          DeviceLog.log('DenseWaitEta', 'prior log save failed: $e');
        }),
      );
    }
  }
}
