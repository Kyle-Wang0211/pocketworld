// dense_progress_bar.dart — the dense stage's progress/result strip for the sparse cloud viewer.
//
// 🔴 It is ALWAYS a `Positioned` child, also when idle. The viewer's Stack has the default loose fit and
// every other child is Positioned: a Stack with no non-positioned child takes the full constraints, but the
// moment one non-positioned child appears the Stack shrinks to that child — a `SizedBox.shrink()` made the
// whole page 0×0 (build 159, 2026-09-15 evening: black viewer). `test/dense/dense_progress_bar_test.dart`
// pins this.
import 'package:flutter/material.dart';

import 'dense_stage_progress.dart';

class DenseProgressBar extends StatelessWidget {
  const DenseProgressBar({super.key, required this.captureDir, required this.onView});

  /// Only progress belonging to this capture is shown.
  final String captureDir;

  /// Opens the finished dense PLY (the viewer decides how).
  final void Function(String plyPath) onView;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<DenseStageProgress?>(
      valueListenable: denseStageProgress,
      builder: (context, p, _) {
        if (p == null || p.captureDir != captureDir) {
          // idle: a zero-size POSITIONED child, invisible and layout-neutral
          return const Positioned(left: 0, top: 0, width: 0, height: 0, child: SizedBox.shrink());
        }
        final String text;
        Widget? action;
        switch (p.state) {
          case DenseStageState.running:
            text = '稠密处理中 · ${p.label}';
          case DenseStageState.done:
            text = p.message ?? '稠密点云完成';
            final ply = p.outPly;
            if (ply != null) {
              action = TextButton(onPressed: () => onView(ply), child: const Text('查看'));
            }
          case DenseStageState.failed:
            text = p.message ?? '稠密处理失败';
        }
        return Positioned(
          left: 12,
          right: 12,
          top: 8,
          child: SafeArea(
            bottom: false,
            child: Material(
              color: Colors.black.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    Expanded(child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 13))),
                    ?action,
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
