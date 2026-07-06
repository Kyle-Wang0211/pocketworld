// sfm_preview_overlay.dart — capture-time sparse-cloud preview layer.
//
// Shown on the AR capture page the moment streaming SfM's finalize phase 1
// lands (LOCAL_READY). When the background global BA converges the refined
// snapshot is swapped in silently — no interruption, just a small
// "精修完成" badge. Rendering/controls are the shared SparseCloudView
// (sparse_cloud_view.dart), identical to the drafts 查看点云 page.

import 'package:flutter/material.dart';

import '../../capture/sfm_live_recon.dart';
import 'sparse_cloud_view.dart';

/// Preview lifecycle the capture page drives.
enum SfmPreviewPhase {
  /// finalize_async phase 1 (register + local BA) is running in the worker.
  generating,

  /// Local model live; background global BA still refining.
  localReady,

  /// Refined model swapped in.
  refined,

  /// Reconstruction failed — capture material is untouched and kept.
  error,
}

class SfmPreviewOverlay extends StatelessWidget {
  const SfmPreviewOverlay({
    super.key,
    required this.phase,
    required this.snapshot,
    required this.onDone,
    this.errorText,
    this.progressText,
  });

  final SfmPreviewPhase phase;
  final SfmLiveSnapshot? snapshot;
  final VoidCallback onDone;
  final String? errorText;

  /// Shown under the generating spinner (e.g. "已处理 12 · 队列 8" while the
  /// disk queue drains before finalize).
  final String? progressText;

  @override
  Widget build(BuildContext context) {
    final snap = snapshot;
    final hasCloud = snap != null && snap.pointCount > 0;
    return Positioned.fill(
      child: Container(
        color: const Color(0xE6000000),
        child: Stack(
          children: [
            if (hasCloud)
              Positioned.fill(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 96),
                  child: SparseCloudView(
                    // Snapshot identity changes on refined swap-in / after
                    // colorization → keyed so the view state survives while
                    // the painter picks up the new buffers.
                    key: const ValueKey('capture_preview_cloud'),
                    xyz: snap.xyz,
                    rgb: snap.rgb,
                  ),
                ),
              ),
            // ── status chip (top center)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.only(top: 14),
                  child: Center(child: _statusChip()),
                ),
              ),
            ),
            // ── generating spinner (center, before any snapshot exists)
            if (phase == SfmPreviewPhase.generating)
              Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 30,
                      height: 30,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      '正在生成预览…',
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                    if (progressText != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        progressText!,
                        style: const TextStyle(
                            color: Colors.white38, fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
            if (phase == SfmPreviewPhase.error)
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 40),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.cloud_off_rounded,
                          color: Colors.white38, size: 40),
                      const SizedBox(height: 14),
                      const Text(
                        '本次未能重建，已保留素材',
                        style: TextStyle(color: Colors.white, fontSize: 15),
                      ),
                      if (errorText != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          errorText!,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: Colors.white38, fontSize: 11),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            // ── done button (bottom; controls live inside SparseCloudView)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Center(
                    child: GestureDetector(
                      onTap: onDone,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 44, vertical: 13),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(26),
                        ),
                        child: const Text(
                          '完成',
                          style: TextStyle(
                            color: Colors.black,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusChip() {
    final String text;
    final IconData? icon;
    switch (phase) {
      case SfmPreviewPhase.generating:
        text = '实时重建';
        icon = null;
      case SfmPreviewPhase.localReady:
        text = '预览 · ${snapshot?.pointCount ?? 0} 点 · 精修中…';
        icon = null;
      case SfmPreviewPhase.refined:
        text = '精修完成 · ${snapshot?.pointCount ?? 0} 点';
        icon = Icons.check_circle_rounded;
      case SfmPreviewPhase.error:
        text = '实时重建';
        icon = null;
    }
    return Container(
      constraints: const BoxConstraints(maxWidth: 340),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xB31C1C1E),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, color: const Color(0xFF6EE7A0), size: 15),
            const SizedBox(width: 6),
          ],
          Text(
            text,
            style: const TextStyle(color: Colors.white, fontSize: 12.5),
          ),
        ],
      ),
    );
  }
}
