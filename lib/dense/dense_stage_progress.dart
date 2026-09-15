// dense_stage_progress.dart — the one observable the UI needs from the dense stage: which capture is being
// processed, what phase it is in, when it started, and where the PLY landed when it finished.
import 'package:flutter/foundation.dart';

import 'dense_live_cloud.dart';

enum DenseStageState { running, done, failed }

final class DenseStageProgress {
  const DenseStageProgress({
    required this.captureDir,
    required this.state,
    this.phase = '',
    this.done = 0,
    this.total = 0,
    this.outPly,
    this.message,
    this.points = 0,
    this.startedAt,
    this.finishedAt,
    this.live,
  });
  final String captureDir;
  final DenseStageState state;
  final String phase;
  final int done, total;
  final String? outPly;

  /// Short, user-facing (≤ ~90 chars). The full error goes to the device log, never to the screen.
  final String? message;
  final int points;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  /// The display copy growing chunk by chunk while the job runs (PWDense v2). Null on a v1 framework, before the
  /// first chunk, and on the terminal states — once the PLY is on disk the viewer reads that instead.
  final DenseLiveCloud? live;

  DenseStageProgress copyWith({
    DenseStageState? state,
    String? phase,
    int? done,
    int? total,
    String? outPly,
    String? message,
    int? points,
    DateTime? startedAt,
    DateTime? finishedAt,
    DenseLiveCloud? live,
  }) =>
      DenseStageProgress(
        captureDir: captureDir,
        state: state ?? this.state,
        phase: phase ?? this.phase,
        done: done ?? this.done,
        total: total ?? this.total,
        outPly: outPly ?? this.outPly,
        message: message ?? this.message,
        points: points ?? this.points,
        startedAt: startedAt ?? this.startedAt,
        finishedAt: finishedAt ?? this.finishedAt,
        live: live ?? this.live,
      );

  /// Phase label (zh) for the status line.
  String get label {
    switch (phase) {
      case 'session':
        return '选视图 / 深度范围';
      case 'images':
        return '解码照片 $done/$total';
      case 'infer':
        return '推理深度 $done/$total';
      case 'fuse':
        return '融合 $done/$total';
      case 'done':
        return '完成';
      default:
        return phase;
    }
  }

  /// 0..1 over the whole job: the phases are weighted by their measured cost on the phone (session ≈ 6 s,
  /// images ≈ 0.07 s each, inference ≈ 2 s each, fusion ≈ 0.15 s per frame) — inference dominates.
  double? get fraction {
    if (state == DenseStageState.done) return 1;
    if (total <= 0) return null;
    final double start, end;
    switch (phase) {
      case 'session':
        start = 0.0; end = 0.02;
      case 'images':
        start = 0.02; end = 0.05;
      case 'infer':
        start = 0.05; end = 0.95;
      case 'fuse':
        start = 0.95; end = 1.0;
      default:
        return null;
    }
    // exact at both ends (done=0 -> start, done=total -> end), so phase boundaries never overlap
    return (start * (total - done) + end * done) / total;
  }

  Duration elapsed([DateTime? now]) {
    final s = startedAt;
    if (s == null) return Duration.zero;
    return (finishedAt ?? now ?? DateTime.now()).difference(s);
  }

  /// First line of an exception text, capped, for the screen.
  static String shorten(Object error, {int max = 90}) {
    var s = error.toString().split('\n').first.trim();
    final arrow = s.indexOf(' <- ');
    if (arrow > 0) s = s.substring(0, arrow);
    return s.length > max ? '${s.substring(0, max)}…' : s;
  }
}

String formatDenseDuration(Duration d) {
  final s = d.inSeconds;
  if (s < 60) return '$s 秒';
  final m = s ~/ 60, r = s % 60;
  if (m < 60) return '$m 分 $r 秒';
  return '${m ~/ 60} 小时 ${m % 60} 分';
}

/// Global, one job at a time (the stage is minutes long and memory-bound; two at once would jetsam).
final ValueNotifier<DenseStageProgress?> denseStageProgress = ValueNotifier<DenseStageProgress?>(null);
