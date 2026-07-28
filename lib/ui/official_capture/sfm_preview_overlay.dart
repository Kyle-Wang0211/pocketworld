// sfm_preview_overlay.dart — post-capture final sparse-cloud waiting layer.
//
// Shown immediately after the user taps finish. It first reports the disk-backed
// frame queue, then holds the user on the final-reconstruction state until the
// authoritative colored cloud is ready. Rendering uses the shared
// SparseCloudView, identical to the drafts 查看点云 page.

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../official_capture/sfm_live_recon.dart';
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
    required this.onBack,
    required this.onDone,
    this.onNext,
    this.errorText,
    this.progressText,
  });

  final SfmPreviewPhase phase;
  final SfmLiveSnapshot? snapshot;

  /// L2 渲染门可见性(ghost_view_filter.dart;与 [snapshot] 点序逐位对齐,
  /// null = 全显示)。RENDER-ONLY,只透传给 SparseCloudView。
  final VoidCallback onBack;
  final VoidCallback onDone;

  /// [选区 2026-07-27] refined 且非 null 时渲染"保存草稿|下一步"双按钮
  /// (下一步进选区页);error 或调用方未接选区入口时保持单"完成"。
  final VoidCallback? onNext;
  final String? errorText;

  /// Shown under the generating spinner while the disk queue drains and the
  /// final reconstruction runs.
  final String? progressText;

  @override
  Widget build(BuildContext context) {
    final snap = snapshot;
    final hasCloud = snap != null && snap.pointCount > 0;
    final canFinish =
        phase == SfmPreviewPhase.refined || phase == SfmPreviewPhase.error;
    return Positioned.fill(
      child: Container(
        // Fully opaque: the preview is a clean full-screen switch, not a
        // translucent cover — the capture UI behind must not bleed through.
        color: const Color(0xFF000000),
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
            // Leaving this screen only reveals Drafts. The capture route and
            // its reconstruction worker stay mounted so progress can be
            // reopened from the active task card.
            Positioned(
              top: 0,
              left: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 8, 0, 0),
                  child: IconButton(
                    key: const ValueKey('sfm_preview_back'),
                    onPressed: onBack,
                    tooltip: '返回草稿',
                    icon: const Icon(Icons.arrow_back_ios_new_rounded),
                    color: Colors.white,
                    iconSize: 22,
                  ),
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
                      '正在生成最终点云…',
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                    if (progressText != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        progressText!,
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 12,
                        ),
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
                      const Icon(
                        Icons.cloud_off_rounded,
                        color: Colors.white38,
                        size: 40,
                      ),
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
                            color: Colors.white38,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            // No early escape while frames/finalize are running: the user asked
            // for the authoritative sparse result, not a background replacement.
            if (canFinish)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                    // refined 且有下一步入口 → RS 同款双按钮;error(没云
                    // 没得选)或调用方未接选区 → 保持单"完成"。
                    child: phase == SfmPreviewPhase.refined && onNext != null
                        ? Row(
                            children: [
                              Expanded(
                                child: SfmBottomActionButton(
                                  label: '保存草稿',
                                  onTap: onDone,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: SfmBottomActionButton(
                                  label: '下一步',
                                  onTap: onNext!,
                                ),
                              ),
                            ],
                          )
                        : Center(
                            child: SfmBottomActionButton(
                              label: '完成',
                              onTap: onDone,
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
        text = '最终重建';
        icon = null;
      case SfmPreviewPhase.localReady:
        text = '重建中 · ${snapshot?.pointCount ?? 0} 点…';
        icon = null;
      case SfmPreviewPhase.refined:
        text = '重建完成 · ${snapshot?.pointCount ?? 0} 点';
        icon = Icons.check_circle_rounded;
      case SfmPreviewPhase.error:
        text = '重建结束';
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

/// 等待页/草稿查看器共用的底部动作按钮(保存草稿|下一步|完成 同款样式)。
/// [2026-07-27 增补] 草稿查看器复用同一形态 —— 两处必须同源,别再复制样式。
class SfmBottomActionButton extends StatelessWidget {
  const SfmBottomActionButton({
    super.key,
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // [2026-07-28 用户签决] 全部实心白胶囊:此前"保存草稿"是深灰底描边款,
    // 黑底上观感像一块半透明背景片,用户点名删除 —— 按钮本体保留、实心。
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(26),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.black,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
