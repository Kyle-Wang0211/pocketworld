// MePage — minimal "个人 / Me" tab.
//
// 2026-05-10: refactored into a strict 2-column equal-height grid
// (Polycam-style). Layout from top to bottom:
//   1. Header — gear (left) + "{displayName} 的方寸间" centered title.
//      Replaces the previous "方寸间" wordmark + separate ProfileCard
//      (email + edit pill). The username flows in via i18n placeholder
//      so only the surrounding "的方寸间" / "'s PocketWorld" swaps with
//      locale; the username itself is the raw account display name.
//   2. Projects / Drafts segmented control.
//      "项目"  = records with completed GLB artifact (hasCompletedArtifact).
//      "草稿"  = everything else: local-mov-pending, uploading, training,
//                packaging, failed, cancelled.
//   3. Strict GridView.count (crossAxisCount=2, fixed childAspectRatio)
//      so left and right columns end at the same Y for every row.
//      Each ScanRecordCell renders in `minimal: true` mode: thumbnail
//      + name + absolute datetime ("26-5-10 14:20") only. No caption,
//      no author handle, no pipeline-stage progress text — the
//      status badge still pins to the thumbnail's top-right.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart'
    show ValueListenable, visibleForTesting;
import 'package:flutter/material.dart';

import '../auth/auth_scope.dart';
import '../capture/sfm_resume.dart';
import '../capture/sparse_ply.dart';
import '../l10n/app_localizations.dart';
import '../me/draft_card_action.dart';
import '../me/scan_record_store.dart';
import 'capture/sfm_resume_wait_page.dart';
import 'capture/sparse_cloud_viewer_page.dart';
import 'design_system.dart';
import 'home_view_model.dart';
import 'me/my_work_detail_page.dart';
import 'me_settings_page.dart';
import 'me_stats_view_model.dart';
import 'scan_record.dart';
import 'scan_record_cell.dart';

/// Separates two independent truths which used to be collapsed into
/// `File(sfm_sparse.ply).existsSync()`:
///
/// * whether the sparse generation is safe to show;
/// * whether replay cleanup/commit is complete.
///
/// Modern captures may only open the exact committed refined generation,
/// regardless of whether their DB still exists. A structurally verified
/// historical PLY whose DB/queue has already been compacted remains viewable,
/// but can never authorize cleanup.
@visibleForTesting
bool isDraftSparseArtifactViewable({
  required SfmFinalArtifactInspection finalArtifact,
  required SparsePublicationViewInspection sparseView,
  required bool sfmDbExists,
  required bool hasReplayState,
}) {
  final committedRefined =
      sparseView.state == SparsePublicationViewState.committed &&
      sparseView.receipt?.refined == true;
  if (finalArtifact.state == SfmFinalArtifactRecoveryState.complete) {
    return committedRefined;
  }
  if (sfmDbExists || hasReplayState) return false;
  // A modern linked pair still requires its exact final commit marker. The
  // sole no-marker exception is a structurally verified historical PLY-only
  // artifact which predates metadata/commit/replay state entirely.
  return sparseView.state == SparsePublicationViewState.legacyPlyOnly;
}

@visibleForTesting
bool activeResumeBlocksDraftAction({
  required SfmResumeUiActivity activity,
  required DraftCardAction action,
}) =>
    activity == SfmResumeUiActivity.otherCapture &&
    action == DraftCardAction.offerResume;

@visibleForTesting
bool activeResumeBlocksLongPressAction({
  required SfmResumeUiActivity activity,
  required String? action,
}) =>
    activity == SfmResumeUiActivity.otherCapture && action == 'rebuild_sparse';

@visibleForTesting
DraftCardAction draftCardActionForVerifiedArtifact({
  required String? recordCaptureDir,
  required bool hasArtifact,
  required SfmFinalArtifactInspection finalArtifact,
  required SparsePublicationViewInspection sparseView,
  required bool sfmDbExists,
  required bool hasReplayState,
  required bool canExplicitlyResume,
  required String? activeReconstructionCaptureDir,
  required bool hasActiveReconstructionCallback,
}) => draftCardActionFor(
  recordCaptureDir: recordCaptureDir,
  hasArtifact: hasArtifact,
  sparsePlyExists: isDraftSparseArtifactViewable(
    finalArtifact: finalArtifact,
    sparseView: sparseView,
    sfmDbExists: sfmDbExists,
    hasReplayState: hasReplayState,
  ),
  sfmDbExists: sfmDbExists || canExplicitlyResume,
  activeReconstructionCaptureDir: activeReconstructionCaptureDir,
  hasActiveReconstructionCallback: hasActiveReconstructionCallback,
);

class _DraftArtifactDiskState {
  const _DraftArtifactDiskState({
    required this.finalArtifact,
    required this.sparseView,
    required this.sfmDbExists,
    required this.hasReplayState,
    required this.canExplicitlyResume,
  });

  final SfmFinalArtifactInspection finalArtifact;
  final SparsePublicationViewInspection sparseView;
  final bool sfmDbExists;
  final bool hasReplayState;
  final bool canExplicitlyResume;
}

Future<_DraftArtifactDiskState> _inspectDraftArtifactState(
  String captureDir,
) async {
  final sfmDbExists = File('$captureDir/sfm_live.db').existsSync();
  // One structured cold-recovery inspection owns DB, manifest and committed
  // manual-v2 orphan validation. It may adopt a fully verified orphan into the
  // queue; bare gray/incomplete sidecars remain durable but non-resumable.
  final recoveryInputs = await inspectSfmRecoveryInputs(captureDir);
  final hasReplayState = recoveryInputs.hasDurableState;
  final finalArtifact = await inspectSfmFinalArtifact(captureDir);
  final receipt = finalArtifact.receipt;
  final SparsePublicationViewInspection sparseView;
  if (receipt != null) {
    // Reuse the exact receipt already verified by final-artifact inspection.
    // Do not re-run sparse recovery for the same tap.
    sparseView = SparsePublicationViewInspection(
      state: SparsePublicationViewState.committed,
      receipt: receipt,
      pointCount: receipt.pointCount,
    );
  } else if (!sfmDbExists && !hasReplayState) {
    // Only the historical no-DB/no-queue branch needs the independent,
    // read-only PLY-only structural validator.
    sparseView = await inspectSparsePublicationForViewing(
      captureDir: captureDir,
    );
  } else {
    sparseView = const SparsePublicationViewInspection(
      state: SparsePublicationViewState.none,
    );
  }
  return _DraftArtifactDiskState(
    finalArtifact: finalArtifact,
    sparseView: sparseView,
    sfmDbExists: sfmDbExists,
    hasReplayState: hasReplayState,
    canExplicitlyResume: recoveryInputs.canExplicitlyResume,
  );
}

@visibleForTesting
SfmResumeWaitPage sfmResumeWaitPageForDraft({
  required String captureDir,
  required String title,
  required bool regenerate,
  Future<bool>? attachedFuture,
  bool attachOnly = false,
}) => SfmResumeWaitPage(
  captureDir: captureDir,
  title: title,
  forceRegenerate: regenerate,
  attachedFuture: attachedFuture,
  attachOnly: attachOnly,
);

@visibleForTesting
class DraftCardActionGuard {
  final Set<String> _busy = <String>{};

  bool isBusy(String key) => _busy.contains(key);

  Future<bool> run(String key, Future<void> Function() action) async {
    if (!_busy.add(key)) return false;
    try {
      await action();
      return true;
    } finally {
      _busy.remove(key);
    }
  }
}

class MePage extends StatefulWidget {
  const MePage({
    super.key,
    this.showDraftsSignal,
    this.initialShowDrafts = false,
    this.activeReconstructionCaptureDir,
    this.onActiveReconstructionTap,
  });

  final ValueListenable<int>? showDraftsSignal;
  final bool initialShowDrafts;

  /// When MePage is temporarily shown above a still-running capture route,
  /// tapping that draft must reveal the existing reconstruction instead of
  /// opening a partial PLY or starting any new work.
  final String? activeReconstructionCaptureDir;
  final VoidCallback? onActiveReconstructionTap;

  @override
  State<MePage> createState() => _MePageState();
}

class _MePageState extends State<MePage> {
  // Lives on the parent so MeSettingsPage receives the same instance and
  // doesn't have to re-fetch profiles / notification_settings every time
  // it's pushed.
  final MeStatsViewModel _stats = MeStatsViewModel();

  // Phase 6.4f.13.1 — direct handle to MePage's local ScaffoldMessenger.
  // Holding a GlobalKey to the local messenger lets us route SnackBars
  // to MePage's own Scaffold whose overlay disappears with the tab when
  // AppShell switches indices, rather than bleeding into other tabs via
  // MaterialApp's root messenger.
  final GlobalKey<ScaffoldMessengerState> _messengerKey =
      GlobalKey<ScaffoldMessengerState>();

  // true = show 项目 (completed GLB), false = show 草稿 (everything else).
  late bool _showProjects;

  @override
  void initState() {
    super.initState();
    _showProjects = !widget.initialShowDrafts;
    widget.showDraftsSignal?.addListener(_showDraftsFromSignal);
    _stats.load();
    // Plan G W2 全本地 (2026-05-16): no cloud → local sync, drafts list
    // shows only what `ScanRecordStore` has on disk.
  }

  @override
  void didUpdateWidget(covariant MePage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.initialShowDrafts &&
        widget.initialShowDrafts &&
        _showProjects) {
      _showProjects = false;
    }
    if (oldWidget.showDraftsSignal == widget.showDraftsSignal) return;
    oldWidget.showDraftsSignal?.removeListener(_showDraftsFromSignal);
    widget.showDraftsSignal?.addListener(_showDraftsFromSignal);
  }

  void _showDraftsFromSignal() {
    if (!mounted || !_showProjects) return;
    setState(() => _showProjects = false);
  }

  @override
  void dispose() {
    widget.showDraftsSignal?.removeListener(_showDraftsFromSignal);
    _stats.dispose();
    super.dispose();
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => MeSettingsPage(stats: _stats)),
    );
  }

  Future<void> _onRefresh() async {
    // Plan G W2 全本地: no cloud sync. Pull-to-refresh just re-reads
    // the local store stats so a draft created since last view shows up.
    await _stats.load();
  }

  @override
  Widget build(BuildContext context) {
    // 2026-04-28: defensive — in release builds, AuthScope.of's null assert
    // is stripped, so reading via the inherited widget directly + null
    // guard avoids tearing down the IndexedStack when AuthScope hasn't
    // been plumbed through yet.
    final scope = context.dependOnInheritedWidgetOfExactType<AuthScope>();
    final currentUser = scope?.notifier;
    final user = currentUser?.signedInUser;
    final l = AppL10n.of(context);
    if (user == null) {
      return Scaffold(
        backgroundColor: AetherColors.bg,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              l.splashRestoringSession,
              textAlign: TextAlign.center,
              style: AetherTextStyles.caption,
            ),
          ),
        ),
      );
    }
    return ScaffoldMessenger(
      key: _messengerKey,
      child: Scaffold(
        backgroundColor: AetherColors.bg,
        body: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: _onRefresh,
            color: AetherColors.primary,
            backgroundColor: AetherColors.bgCanvas,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(
                parent: BouncingScrollPhysics(),
              ),
              padding: const EdgeInsets.fromLTRB(
                AetherSpacing.lg,
                AetherSpacing.md,
                AetherSpacing.lg,
                140,
              ),
              children: [
                SizedBox(
                  height: 56,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      icon: const Icon(Icons.settings_outlined),
                      color: AetherColors.textPrimary,
                      tooltip: l.meSettingsTitle,
                      onPressed: _openSettings,
                    ),
                  ),
                ),
                const SizedBox(height: AetherSpacing.md),
                _ProjectsDraftsTab(
                  showProjects: _showProjects,
                  onSelect: (v) => setState(() => _showProjects = v),
                ),
                const SizedBox(height: AetherSpacing.lg),
                _MyWorksSection(
                  showProjects: _showProjects,
                  activeReconstructionCaptureDir:
                      widget.activeReconstructionCaptureDir,
                  onActiveReconstructionTap: widget.onActiveReconstructionTap,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Pill-shaped segmented control for 项目 / 草稿 tab swap.
class _ProjectsDraftsTab extends StatelessWidget {
  final bool showProjects;
  final ValueChanged<bool> onSelect;

  const _ProjectsDraftsTab({
    required this.showProjects,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: AetherColors.bgElevated,
        borderRadius: BorderRadius.circular(AetherRadii.pill),
        border: Border.all(color: AetherColors.border, width: 0.5),
      ),
      child: Row(
        children: [
          Expanded(
            child: _TabPill(
              label: l.meTabProjects,
              active: showProjects,
              onTap: () => onSelect(true),
            ),
          ),
          Expanded(
            child: _TabPill(
              label: l.meTabDrafts,
              active: !showProjects,
              onTap: () => onSelect(false),
            ),
          ),
        ],
      ),
    );
  }
}

class _TabPill extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _TabPill({
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: active ? AetherColors.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(AetherRadii.pill),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: active ? Colors.white : AetherColors.textPrimary,
          ),
        ),
      ),
    );
  }
}

/// Strict 2-column equal-height grid of the user's ScanRecords filtered
/// by 项目 / 草稿 tab state. Uses GridView.count with a fixed
/// childAspectRatio so left and right cells share the same Y bounds.
class _MyWorksSection extends StatefulWidget {
  final bool showProjects;
  final String? activeReconstructionCaptureDir;
  final VoidCallback? onActiveReconstructionTap;

  const _MyWorksSection({
    required this.showProjects,
    this.activeReconstructionCaptureDir,
    this.onActiveReconstructionTap,
  });

  @override
  State<_MyWorksSection> createState() => _MyWorksSectionState();
}

class _MyWorksSectionState extends State<_MyWorksSection> {
  final HomeViewModel _vm = HomeViewModel();
  final DraftCardActionGuard _cardActionGuard = DraftCardActionGuard();

  @override
  void initState() {
    super.initState();
    _vm.addListener(_rebuild);
    _vm.loadRecords();
  }

  @override
  void dispose() {
    _vm.removeListener(_rebuild);
    _vm.dispose();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    // _vm.loadRecords subscribes to ScanRecordStore.changes and notifies
    // us, so reading the store directly here stays in sync.
    final all = ScanRecordStore.instance.records;
    final mine = widget.showProjects
        ? all.where((r) => r.hasCompletedArtifact).toList()
        : all.where((r) => !r.hasCompletedArtifact).toList();
    if (mine.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: AetherSpacing.xl),
        child: Text(
          l.meMyWorksEmpty,
          textAlign: TextAlign.center,
          style: AetherTextStyles.bodySm,
        ),
      );
    }
    return GridView.count(
      crossAxisCount: 2,
      crossAxisSpacing: AetherSpacing.lg,
      mainAxisSpacing: AetherSpacing.lg,
      childAspectRatio: 0.62,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: [
        for (final r in mine)
          ScanRecordCell(
            record: r,
            subtitle: _formatAbsTime(r.createdAt),
            minimal: true,
            onTap: () => unawaited(
              _cardActionGuard.run(_cardActionKey(r), () => _onTap(r)),
            ),
            onLongPress: () => unawaited(
              _cardActionGuard.run(
                _cardActionKey(r),
                () => _showRecordActions(r),
              ),
            ),
          ),
      ],
    );
  }

  String _cardActionKey(ScanRecord record) =>
      record.captureDir?.trim().isNotEmpty == true
      ? record.captureDir!.trim()
      : record.id;

  void _showResumeBusy() {
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('另一项点云重建正在进行，完成后再试'),
          duration: Duration(seconds: 2),
        ),
      );
  }

  Future<void> _reopenActiveResume(ScanRecord record) async {
    // Snapshot before the asynchronous route push. The future may complete
    // and clear the global active slot before the page is built; the page must
    // still attach to this exact result, never start a new normal resume.
    final snapshot = activeSfmResumeSnapshotFor(record.captureDir);
    if (snapshot == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => sfmResumeWaitPageForDraft(
          captureDir: snapshot.captureDir,
          title: record.name,
          regenerate: snapshot.forceRegenerate,
          attachedFuture: snapshot.future,
          attachOnly: true,
        ),
      ),
    );
  }

  Future<void> _onTap(ScanRecord record) async {
    // 路由决策提纯为纯函数(draft_card_action.dart),契约由
    // tool/draft_reentry_check.dart 在纯 Dart VM 上穷举断言:
    //   • finalize 进行中点同一任务卡 → 回原等待页,绝不起第二个重建;
    //   • finalize 完成后点击 → 打开成品;
    //   • 重建被打断(有 sfm_live.db 无 PLY)→ 弹"继续重建"确认。
    // 这里只做 durable inspection 与执行。活动任务/GLB 不需要碰磁盘，
    // 先走快速优先级，避免一次点击对同一 sparse generation 重复检查。
    final captureDir = record.captureDir;
    switch (sfmResumeUiActivityFor(captureDir)) {
      case SfmResumeUiActivity.sameCapture:
        await _reopenActiveResume(record);
        return;
      case SfmResumeUiActivity.otherCapture:
        // Safe actions on another card (open/rename/delete) remain available.
        // Only a later resume/rebuild action is globally serialized.
        break;
      case SfmResumeUiActivity.none:
        break;
    }
    final fastAction = draftCardActionFor(
      recordCaptureDir: captureDir,
      hasArtifact: record.artifactPath != null,
      sparsePlyExists: false,
      sfmDbExists: false,
      activeReconstructionCaptureDir: widget.activeReconstructionCaptureDir,
      hasActiveReconstructionCallback: widget.onActiveReconstructionTap != null,
    );
    if (fastAction == DraftCardAction.reopenActiveReconstruction) {
      widget.onActiveReconstructionTap?.call();
      return;
    }
    if (fastAction == DraftCardAction.openWorkDetail) {
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => MyWorkDetailPage(recordId: record.id),
        ),
      );
      return;
    }
    if (captureDir == null) return;

    // Container UUID migration applies to finished historical PLY-only
    // captures too, not just captures which still retain sfm_live.db.
    final existingDir = await resolveExistingCaptureDir(captureDir);
    if (existingDir == null) return;
    final inspected = await _inspectDraftArtifactState(existingDir);
    if (!mounted) return;
    // Inspection is asynchronous; another route may have started a resume
    // while it was running. Re-check before any viewer/resume navigation.
    switch (sfmResumeUiActivityFor(existingDir)) {
      case SfmResumeUiActivity.sameCapture:
        await _reopenActiveResume(record);
        return;
      case SfmResumeUiActivity.otherCapture:
        break;
      case SfmResumeUiActivity.none:
        break;
    }
    final action = draftCardActionForVerifiedArtifact(
      recordCaptureDir: existingDir,
      hasArtifact: false,
      finalArtifact: inspected.finalArtifact,
      sparseView: inspected.sparseView,
      sfmDbExists: inspected.sfmDbExists,
      hasReplayState: inspected.hasReplayState,
      canExplicitlyResume: inspected.canExplicitlyResume,
      activeReconstructionCaptureDir: widget.activeReconstructionCaptureDir,
      hasActiveReconstructionCallback: widget.onActiveReconstructionTap != null,
    );
    if (activeResumeBlocksDraftAction(
      activity: sfmResumeUiActivityFor(existingDir),
      action: action,
    )) {
      _showResumeBusy();
      return;
    }
    switch (action) {
      case DraftCardAction.reopenActiveReconstruction:
        // capture route 仍在本临时草稿视图之下 —— 回它的等待页看进度。
        widget.onActiveReconstructionTap?.call();
      case DraftCardAction.openWorkDetail:
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => MyWorkDetailPage(recordId: record.id),
          ),
        );
      case DraftCardAction.openSparseCloud:
        if (!mounted) return;
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => SparseCloudViewerPage(
              plyPath: '$existingDir/sfm_sparse.ply',
              title: record.name.isEmpty ? '稀疏点云' : record.name,
            ),
          ),
        );
      case DraftCardAction.offerResume:
        await _offerResume(record, existingDir);
      case DraftCardAction.none:
        // 修3:原"正在生成 3D 模型,完成后会自动打开"底部弹窗已按用户
        // 要求删除。无成品且无可恢复数据时,点击不再有任何弹层。
        break;
    }
  }

  /// 修2c:重建被打断的草稿 → 用户确认后从 sfm_live.db 断点续跑。
  /// 已在续跑中(用户离开等待页后又点回来)则跳过确认,直接回等待页
  /// 挂到同一个恢复 future 上 —— 与"同任务卡回原等待页"契约同精神。
  ///
  /// [regenerate]=true 是长按菜单"重新重建点云"入口:sfm_sparse.ply 已
  /// 存在但用户想重跑(如旧版 resume 产物歪/浮点多)。恢复本身幂等 ——
  /// resumeSingleCapture 完成时覆盖旧 PLY;只有确认文案不同。
  Future<void> _offerResume(
    ScanRecord record,
    String recoverableDir, {
    bool regenerate = false,
  }) async {
    final initialActivity = sfmResumeUiActivityFor(recoverableDir);
    if (initialActivity == SfmResumeUiActivity.otherCapture) {
      _showResumeBusy();
      return;
    }
    if (initialActivity == SfmResumeUiActivity.sameCapture) {
      await _reopenActiveResume(record);
      return;
    }
    if (!isResumeInFlight(recoverableDir)) {
      final name = record.name.isEmpty ? '这次拍摄' : '「${record.name}」';
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(regenerate ? '重新重建？' : '继续重建？'),
          content: Text(
            regenerate
                ? '将用$name已保存的重建数据重新生成点云，完成后覆盖现有点云，无需重拍。'
                : '$name的点云还没有生成。拍摄数据已完整保存，可以从中断处继续重建，无需重拍。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(AppL10n.of(ctx).meActionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(regenerate ? '重新重建' : '继续重建'),
            ),
          ],
        ),
      );
      if (!mounted) return;
      if (confirmed != true) return;
    }
    final currentActivity = sfmResumeUiActivityFor(recoverableDir);
    if (currentActivity == SfmResumeUiActivity.otherCapture) {
      _showResumeBusy();
      return;
    }
    if (currentActivity == SfmResumeUiActivity.sameCapture) {
      await _reopenActiveResume(record);
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => sfmResumeWaitPageForDraft(
          captureDir: recoverableDir,
          title: record.name,
          regenerate: regenerate,
        ),
      ),
    );
  }

  /// Long-press handler for the local-only product route.
  Future<void> _showRecordActions(ScanRecord record) async {
    final l = AppL10n.of(context);
    switch (sfmResumeUiActivityFor(record.captureDir)) {
      case SfmResumeUiActivity.sameCapture:
        await _reopenActiveResume(record);
        return;
      case SfmResumeUiActivity.otherCapture:
        break;
      case SfmResumeUiActivity.none:
        break;
    }
    // 只给 verified final / verified legacy PLY 提供查看入口。单纯存在的
    // partial/unverified PLY 不再进入查看器。
    final captureDir = record.captureDir;
    final existingDir = captureDir == null
        ? null
        : await resolveExistingCaptureDir(captureDir);
    final inspected = existingDir == null
        ? const _DraftArtifactDiskState(
            finalArtifact: SfmFinalArtifactInspection(
              state: SfmFinalArtifactRecoveryState.needsRebuild,
            ),
            sparseView: SparsePublicationViewInspection(
              state: SparsePublicationViewState.none,
            ),
            sfmDbExists: false,
            hasReplayState: false,
            canExplicitlyResume: false,
          )
        : await _inspectDraftArtifactState(existingDir);
    if (!mounted) return;
    // Long-press inspection has the same race boundary as a tap.
    switch (sfmResumeUiActivityFor(existingDir)) {
      case SfmResumeUiActivity.sameCapture:
        await _reopenActiveResume(record);
        return;
      case SfmResumeUiActivity.otherCapture:
        break;
      case SfmResumeUiActivity.none:
        break;
    }
    if (!mounted) return;
    final canViewSparse = isDraftSparseArtifactViewable(
      finalArtifact: inspected.finalArtifact,
      sparseView: inspected.sparseView,
      sfmDbExists: inspected.sfmDbExists,
      hasReplayState: inspected.hasReplayState,
    );
    final sparsePlyPath = canViewSparse
        ? '${existingDir!}/sfm_sparse.ply'
        : null;
    // 断点数据仍在(sfm_live.db 按契约保留)且当前没有别的重建在跑时,
    // 提供"重新重建点云"入口 —— 覆盖 PLY 已存在的场景(点击卡片只会打开
    // 查看器,永远到不了 offerResume 分支):恢复幂等,完成后覆盖旧 PLY。
    // 有活跃重建时不提供(双原生 SfM 会话会把内存/热推过真机上限,与
    // draft_card_action 的续跑门同一规矩)。
    final rebuildDir =
        widget.activeReconstructionCaptureDir == null &&
            sfmResumeUiActivityFor(existingDir) == SfmResumeUiActivity.none &&
            inspected.canExplicitlyResume
        ? existingDir
        : null;
    final action = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AetherColors.bgCanvas,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canViewSparse)
              ListTile(
                leading: const Icon(Icons.grain_rounded),
                title: const Text('查看点云'),
                onTap: () => Navigator.of(ctx).pop('view_sparse'),
              ),
            if (rebuildDir != null)
              ListTile(
                leading: const Icon(Icons.restart_alt_rounded),
                title: Text(canViewSparse ? '重新重建点云' : '继续重建点云'),
                onTap: () => Navigator.of(ctx).pop('rebuild_sparse'),
              ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(l.meActionRename),
              onTap: () => Navigator.of(ctx).pop('rename'),
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline,
                color: AetherColors.danger,
              ),
              title: Text(
                l.meActionDelete,
                style: const TextStyle(color: AetherColors.danger),
              ),
              onTap: () => Navigator.of(ctx).pop('delete'),
            ),
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (sfmResumeUiActivityFor(existingDir)) {
      case SfmResumeUiActivity.sameCapture:
        await _reopenActiveResume(record);
        return;
      case SfmResumeUiActivity.otherCapture:
        if (activeResumeBlocksLongPressAction(
          activity: SfmResumeUiActivity.otherCapture,
          action: action,
        )) {
          _showResumeBusy();
          return;
        }
        break;
      case SfmResumeUiActivity.none:
        break;
    }
    if (!mounted) return;
    if (action == 'view_sparse' && sparsePlyPath != null) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SparseCloudViewerPage(
            plyPath: sparsePlyPath,
            title: record.name.isEmpty ? '稀疏点云' : record.name,
          ),
        ),
      );
    } else if (action == 'rebuild_sparse' && rebuildDir != null) {
      await _offerResume(record, rebuildDir, regenerate: canViewSparse);
    } else if (action == 'rename') {
      await _renameRecord(record);
    } else if (action == 'delete') {
      await _confirmAndDelete(record);
    }
  }

  Future<void> _renameRecord(ScanRecord record) async {
    final l = AppL10n.of(context);
    final controller = TextEditingController(text: record.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.meRenameDialogTitle),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            counterText: '',
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l.meActionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(l.meActionSave),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == record.name) return;
    await ScanRecordStore.instance.addOrUpdate(record.copyWith(name: newName));
  }

  Future<void> _confirmAndDelete(ScanRecord record) async {
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.meDeleteDialogTitle),
        content: Text(l.meDeleteDialogContent(record.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.meActionCancel),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AetherColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(l.meActionDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _vm.deleteRecord(record);
  }
}

/// Absolute timestamp formatter for the personal grid — "YY-M-D HH:MM".
/// Replaces the previous relative ("X 天前") formatter at the request
/// of the user: in a grid view, two cards with similar relative-time
/// strings are hard to tell apart at a glance.
String _formatAbsTime(DateTime t) {
  final local = t.toLocal();
  final yy = (local.year % 100).toString().padLeft(2, '0');
  final m = local.month.toString();
  final d = local.day.toString();
  final hh = local.hour.toString().padLeft(2, '0');
  final mm = local.minute.toString().padLeft(2, '0');
  return '$yy-$m-$d $hh:$mm';
}
