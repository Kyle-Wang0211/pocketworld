// sfm_preview_overlay.dart — post-capture final sparse-cloud waiting layer.
//
// Shown immediately after the user taps finish. It first reports the disk-backed
// frame queue, then holds the user on the final-reconstruction state until the
// authoritative colored cloud is ready. Rendering uses the shared
// SparseCloudView, identical to the drafts 查看点云 page.

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

import '../../official_capture/sfm_live_recon.dart';
import '../../official_capture/selection_box.dart';
import 'sparse_cloud_view.dart';
import 'ruler_scrubber.dart';

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
    this.onEnterEditing,
    this.errorText,
    this.progressText,
    this.waitLabel,
    this.denseRunning = false,
    this.onCameraChanged,
    this.editing = false,
    this.selectionBox,
    this.onBoxChanged,
    this.cloudController,
    this.initialPerspective,
    this.toolsOverlay,
    this.lodOctreeDir,
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

  /// [SEL-ENTRY 2026-07-30] 右上角开关的两个方向。选区是**可选**的:不点就
  /// 直接保存草稿。编辑态该位置变成返回,进出同一个按钮。
  final VoidCallback? onEnterEditing;
  final String? errorText;

  /// Shown under the generating spinner while the disk queue drains and the
  /// final reconstruction runs.
  final String? progressText;

  /// 底部等待胶囊的文案(仅 `phase == generating` 时显示)。null = 倒计时估计
  /// 还不存在,胶囊改显 `AppL10n.of(context).etaCalculating`。
  final String? waitLabel;

  /// [DENSE-SAME-PAGE 2026-09-15] The dense stage is running for this project:
  /// the wait pill shows its countdown ([waitLabel]) and the bottom action
  /// buttons are hidden until it ends. The cloud on screen is whatever the
  /// caller passes as [snapshot] (the growing dense cloud, then the sparse one).
  final bool denseRunning;

  /// 预览相机快照上报 —— "下一步"进选区页时原样继承(用户签决:预览与
  /// 编辑是同一个页面,点下一步只是让工具显现)。
  final ValueChanged<CloudViewCamera>? onCameraChanged;

  /// [2026-07-28 用户签决] 预览与编辑是同一个页面:点"下一步"只是把工具层
  /// 叠上来 —— 同一个 SparseCloudView 实例、同一份相机,零跳变。
  final bool editing;
  final SelectionBox? selectionBox;
  final ValueChanged<SelectionBox>? onBoxChanged;
  final CloudViewController? cloudController;

  /// [LIVE-WAIT 2026-09-15] Capture-pose start for the cloud view (see
  /// SparseCloudView.initialPerspective); null = default framing.
  final PerspectiveStart? initialPerspective;
  final Widget? toolsOverlay;

  /// [LOD v3 2026-09-24] The finished dense cloud's octree while the dense cloud is on screen
  /// (DenseLodCache); null = the GPU viewer draws [snapshot]'s points. The view is the same
  /// SparseCloudView instance throughout (user: 「查看器要全程一致」).
  final String? lodOctreeDir;

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
                    // [LOD v3] one GPU viewer draws every stage of this page.
                    gpu: true,
                    octreeDir: lodOctreeDir,
                    onCameraChanged: onCameraChanged,
                    controller: cloudController,
                    initialPerspective: initialPerspective,
                    // [SEL-PREVIEW 2026-07-30] 浏览态**也要**拿到框:预览呈现
                    // 的就是选区后的范围(painter 侧 cullOutsideSelection 按
                    // editing 取反,浏览剔除 / 编辑染红)。此前这里在非编辑态
                    // 传 null,框在预览里完全不起作用。
                    selectionBox: selectionBox,
                    onBoxChanged: onBoxChanged,
                    liveBox: selectionBox == null ? null : () => selectionBox!,
                    editing: editing,
                    bottomGestureExclusion: editing ? 200 : 0,
                    // [2026-08-09 用户签决] 同 sparse_cloud_viewer_page:编辑态
                    // 点云只在滑轨上方出现。此处无收起状态入口,恒按展开几何。
                    bottomFade: editing
                        ? MediaQuery.of(context).padding.bottom +
                              kRulerHeight -
                              kRulerArcTop
                        : 0,
                    bottomFadeArcRadius: editing
                        ? rulerArcRadius(MediaQuery.of(context).size.width)
                        : 0,
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
                    tooltip: AppL10n.of(context).sfmBackToDrafts,
                    icon: const Icon(Icons.arrow_back_ios_new_rounded),
                    color: Colors.white,
                    iconSize: 22,
                  ),
                ),
              ),
            ),
            // ── [SEL-ENTRY 2026-07-30 用户签决] 右上角"选区编辑 ⇄ 返回"开关 ──
            //
            // 此前进选区只有底部那个"下一步"按钮,读起来像**必经的下一步**;
            // 用户要的是"选区是可选的":想选就点右上角进去,不想选直接保存草稿。
            //
            // 只在 refined 且真有云可编辑时出现(onEnterEditing 非 null 就是这个
            // 条件的载体);generating/error 态没有可选的东西,按钮不该占位。
            //
            // [2026-07-30] 编辑态**不**在这里出按钮:SelectionToolsLayer 自己
            // 就在右上角画"保存"、左上角画"返回",这里再画一个会和它重叠。
            if (phase == SfmPreviewPhase.refined &&
                !editing &&
                onEnterEditing != null)
              Positioned(
                top: 0,
                right: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(0, 8, 8, 0),
                    // [2026-07-30 用户签决] 右上角是**文字**不是图标。
                    child: TextButton(
                      key: const ValueKey('sfm_preview_enter_editing'),
                      onPressed: onEnterEditing,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        minimumSize: const Size(0, 48),
                      ),
                      child: Text(
                        AppL10n.of(context).sfmEditSelection,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            // ── generating spinner (center, before any snapshot exists)
            if (phase == SfmPreviewPhase.generating && !hasCloud)
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
                      Text(
                        AppL10n.of(context).sfmReconFailedKeptFrames,
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
            // ── wait pill (bottom center) while reconstruction runs. The only
            // status the page shows: "计算中…" until the countdown exists, then
            // the committed coarse label (see lib/eta/pipeline_eta.dart).
            if ((phase == SfmPreviewPhase.generating || denseRunning) && !editing)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                    child: Center(child: _waitPill(context)),
                  ),
                ),
              ),
            // No early escape while frames/finalize are running: the user asked
            // for the authoritative sparse result, not a background replacement.
            if (canFinish && !editing && !denseRunning)
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
                                  label: AppL10n.of(context).sfmSaveDraft,
                                  onTap: onDone,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                child: SfmBottomActionButton(
                                  label: AppL10n.of(context).sfmNext,
                                  onTap: onNext!,
                                ),
                              ),
                            ],
                          )
                        : Center(
                            child: SfmBottomActionButton(
                              label: AppL10n.of(context).sfmDone,
                              onTap: onDone,
                            ),
                          ),
                  ),
                ),
              ),
            if (toolsOverlay != null) Positioned.fill(child: toolsOverlay!),
          ],
        ),
      ),
    );
  }

  Widget _waitPill(BuildContext context) {
    final text = waitLabel ?? AppL10n.of(context).etaCalculating;
    return Container(
      key: const ValueKey('sfm_wait_pill'),
      constraints: const BoxConstraints(maxWidth: 340),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xB31C1C1E),
        borderRadius: BorderRadius.circular(22),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Colors.white, fontSize: 14),
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

  /// null = 禁用。看起来可点、点下去什么都不发生的按钮比灰按钮更糟。
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // [2026-07-28 用户签决] 全部实心白胶囊:此前"保存草稿"是深灰底描边款,
    // 黑底上观感像一块半透明背景片,用户点名删除 —— 按钮本体保留、实心。
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 13),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? Colors.white : const Color(0x3DFFFFFF),
          borderRadius: BorderRadius.circular(26),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: enabled ? Colors.black : const Color(0x8AFFFFFF),
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
