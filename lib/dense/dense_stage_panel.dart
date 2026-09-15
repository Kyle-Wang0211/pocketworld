// dense_stage_panel.dart — the dense stage's status block for the sparse cloud viewer, in the preview overlay's
// own visual language (white70 spinner + line, white38 sub-line; sfm_preview_overlay.dart "generating").
//
// 🔴 ALWAYS a `Positioned` child, also when idle. The viewer's Stack is loose-fit with only Positioned children;
// a non-positioned placeholder collapses the whole page to 0×0 (build 159 black page).
// `test/dense/dense_stage_panel_test.dart` pins it.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import 'dense_stage_progress.dart';

/// Status block placed above the bottom action pill.
class DenseStagePanel extends StatefulWidget {
  const DenseStagePanel({super.key, required this.captureDir, required this.densePlyPath, required this.onView});

  final String captureDir;

  /// `<captureDir>/official_dense.ply` — shown as "查看" when it already exists and nothing is running.
  final String densePlyPath;
  final void Function(String plyPath) onView;

  @override
  State<DenseStagePanel> createState() => _DenseStagePanelState();
}

class _DenseStagePanelState extends State<DenseStagePanel> {
  Timer? _tick;
  bool _hasDense = false;

  @override
  void initState() {
    super.initState();
    _hasDense = _plyExists();
    denseStageProgress.addListener(_onProgress);
    _syncTimer();
  }

  @override
  void dispose() {
    denseStageProgress.removeListener(_onProgress);
    _tick?.cancel();
    super.dispose();
  }

  bool _plyExists() {
    try {
      return File(widget.densePlyPath).existsSync();
    } catch (_) {
      return false;
    }
  }

  void _onProgress() {
    if (!mounted) return;
    setState(() {
      _hasDense = _plyExists();
      _syncTimer();
    });
  }

  void _syncTimer() {
    final p = denseStageProgress.value;
    final running = p != null && p.captureDir == widget.captureDir && p.state == DenseStageState.running;
    if (running && _tick == null) {
      _tick = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); });
    } else if (!running) {
      _tick?.cancel();
      _tick = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = denseStageProgress.value;
    final mine = p != null && p.captureDir == widget.captureDir ? p : null;
    Widget? body;
    if (mine != null && mine.state == DenseStageState.running) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(width: 30, height: 30, child: CircularProgressIndicator(strokeWidth: 2.4, color: Colors.white70)),
          const SizedBox(height: 12),
          const Text('正在生成稠密点云…', style: TextStyle(color: Colors.white70, fontSize: 14)),
          const SizedBox(height: 6),
          Text('${mine.label} · 已用 ${formatDenseDuration(mine.elapsed())}', style: const TextStyle(color: Colors.white38, fontSize: 12)),
          const SizedBox(height: 10),
          SizedBox(
            width: 220,
            child: LinearProgressIndicator(
              value: mine.fraction,
              minHeight: 3,
              backgroundColor: const Color(0x33FFFFFF),
              color: Colors.white70,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ],
      );
    } else if (mine != null && mine.state == DenseStageState.done) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline, color: Colors.white70, size: 26),
          const SizedBox(height: 8),
          Text('稠密点云已生成 · ${mine.points} 点 · ${formatDenseDuration(mine.elapsed())}',
              style: const TextStyle(color: Colors.white70, fontSize: 14), textAlign: TextAlign.center),
        ],
      );
    } else if (mine != null && mine.state == DenseStageState.failed) {
      body = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: Colors.white70, size: 26),
            const SizedBox(height: 8),
            Text('稠密处理失败', style: const TextStyle(color: Colors.white70, fontSize: 14)),
            if (mine.message != null) ...[
              const SizedBox(height: 4),
              Text(mine.message!, style: const TextStyle(color: Colors.white38, fontSize: 12), textAlign: TextAlign.center, maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
          ],
        ),
      );
    } else if (_hasDense) {
      body = TextButton(
        onPressed: () => widget.onView(widget.densePlyPath),
        child: const Text('已有稠密点云 · 查看', style: TextStyle(color: Colors.white70, fontSize: 13)),
      );
    }
    if (body == null) {
      return const Positioned(left: 0, top: 0, width: 0, height: 0, child: SizedBox.shrink());   // idle: layout-neutral
    }
    return Positioned(
      left: 0,
      right: 0,
      bottom: 96,
      child: SafeArea(top: false, child: Center(child: body)),
    );
  }
}
