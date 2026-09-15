// dense_stage_progress.dart — the one observable the UI needs from the dense stage: which capture is being
// processed, what phase it is in, and where the PLY landed when it finished.
import 'package:flutter/foundation.dart';

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
  });
  final String captureDir;
  final DenseStageState state;
  final String phase;
  final int done, total;
  final String? outPly;
  final String? message;
  final int points;

  DenseStageProgress copyWith({DenseStageState? state, String? phase, int? done, int? total, String? outPly, String? message, int? points}) =>
      DenseStageProgress(
        captureDir: captureDir,
        state: state ?? this.state,
        phase: phase ?? this.phase,
        done: done ?? this.done,
        total: total ?? this.total,
        outPly: outPly ?? this.outPly,
        message: message ?? this.message,
        points: points ?? this.points,
      );

  /// Human phase label (zh) for the overlay.
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
}

/// Global, one job at a time (the stage is minutes long and memory-bound; two at once would jetsam).
final ValueNotifier<DenseStageProgress?> denseStageProgress = ValueNotifier<DenseStageProgress?>(null);
