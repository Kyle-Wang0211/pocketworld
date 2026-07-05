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
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../auth/auth_scope.dart';
import '../capture/cloud_capture_raw_retention_service.dart';
import '../capture/cloud_capture_training_service.dart';
import '../i18n/locale_notifier.dart';
import '../l10n/app_localizations.dart';
import '../me/scan_record_store.dart';
import '../pipeline/local_pipeline_runner.dart';
import '../privacy/research_consent_service.dart';
import 'design_system.dart';
import 'home_view_model.dart';
import 'me/my_work_detail_page.dart';
import 'me_settings_page.dart';
import 'me_stats_view_model.dart';
import 'research_consent_dialog.dart';
import 'scan_record.dart';
import 'scan_record_cell.dart';

class MePage extends StatefulWidget {
  const MePage({super.key, this.showDraftsSignal});

  final ValueListenable<int>? showDraftsSignal;

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
  bool _showProjects = true;

  @override
  void initState() {
    super.initState();
    widget.showDraftsSignal?.addListener(_showDraftsFromSignal);
    _stats.load();
    // Plan G W2 全本地 (2026-05-16): no cloud → local sync, drafts list
    // shows only what `ScanRecordStore` has on disk.
  }

  @override
  void didUpdateWidget(covariant MePage oldWidget) {
    super.didUpdateWidget(oldWidget);
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
                _MyWorksSection(showProjects: _showProjects),
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

  const _MyWorksSection({required this.showProjects});

  @override
  State<_MyWorksSection> createState() => _MyWorksSectionState();
}

class _MyWorksSectionState extends State<_MyWorksSection> {
  final HomeViewModel _vm = HomeViewModel();

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
            onTap: () => _onTap(r),
            onLongPress: () => _showRecordActions(r),
          ),
      ],
    );
  }

  void _onTap(ScanRecord record) {
    // Plan G W2 全本地 (2026-05-16): the detail page only renders when
    // there's a viewable artifact (artifactPath != null). Without
    // jobStatus we can't distinguish "in-progress" from "no GLB yet"
    // — both cases show the same hint and skip the detail push.
    if (record.artifactPath == null) {
      final l = AppL10n.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(l.meTapHintInProgress),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MyWorkDetailPage(recordId: record.id),
      ),
    );
  }

  /// Long-press handler — opens a bottom sheet with train / rename / delete.
  /// Drafts can explicitly enter the cloud worker queue from here; upload
  /// acknowledgement alone is just "raw safely reached cloud".
  Future<void> _showRecordActions(ScanRecord record) async {
    final l = AppL10n.of(context);
    final copy = _MeActionCopy.of(context);
    final busy =
        record.cloudUploadStatus == ScanCloudUploadStatus.queued ||
        record.cloudUploadStatus == ScanCloudUploadStatus.processing;
    final canRequestTraining =
        !busy &&
        record.cloudRawDeletedAt == null &&
        (record.cloudScanId != null || !record.hasCompletedArtifact);
    final canDeleteCloudRaw =
        record.cloudScanId != null &&
        record.cloudRawDeletedAt == null &&
        record.cloudUploadStatus != ScanCloudUploadStatus.queued &&
        record.cloudUploadStatus != ScanCloudUploadStatus.processing;
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
            if (canRequestTraining)
              ListTile(
                leading: const Icon(Icons.play_arrow_rounded),
                title: Text(copy.startTraining),
                onTap: () => Navigator.of(ctx).pop('train'),
              ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: Text(l.meActionRename),
              onTap: () => Navigator.of(ctx).pop('rename'),
            ),
            if (canDeleteCloudRaw)
              ListTile(
                leading: const Icon(Icons.cloud_off_outlined),
                title: Text(copy.deleteCloudRaw),
                onTap: () => Navigator.of(ctx).pop('delete_cloud_raw'),
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
    if (action == 'train') {
      await _startTraining(record);
    } else if (action == 'rename') {
      await _renameRecord(record);
    } else if (action == 'delete_cloud_raw') {
      await _confirmAndDeleteCloudRaw(record);
    } else if (action == 'delete') {
      await _confirmAndDelete(record);
    }
  }

  Future<void> _startTraining(ScanRecord record) async {
    final copy = _MeActionCopy.of(context);
    final messenger = ScaffoldMessenger.of(context);
    if (record.cloudUploadStatus == ScanCloudUploadStatus.queued ||
        record.cloudUploadStatus == ScanCloudUploadStatus.processing) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(copy.alreadyQueued),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (record.cloudRawDeletedAt != null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(copy.cloudRawDeleted),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (record.cloudUploadStatus == ScanCloudUploadStatus.failed &&
        record.cloudScanId == null) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(copy.uploadFailed),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    if (record.cloudScanId == null ||
        !_hasCloudRawReadyForTraining(record.cloudUploadStatus)) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(copy.waitForUpload),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final consentService = ResearchConsentService.instance;
    ResearchConsentSnapshot consent;
    if (await consentService.shouldPromptForTraining()) {
      if (!mounted) return;
      final decision = await showResearchConsentDialog(context);
      if (decision == null) return;
      consent = await consentService.savePromptDecision(decision);
    } else {
      consent = await consentService.load(refreshRemote: false);
    }

    try {
      await CloudCaptureTrainingService().requestTraining(
        record: record,
        researchConsent: consent,
      );
      await ScanRecordStore.instance.addOrUpdate(
        record.copyWith(
          cloudUploadStatus: ScanCloudUploadStatus.queued,
          clearCloudUploadFailureMessage: true,
        ),
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(copy.queued),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(copy.queueFailed(_shortTrainingError(e))),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  bool _hasCloudRawReadyForTraining(ScanCloudUploadStatus status) {
    switch (status) {
      case ScanCloudUploadStatus.acknowledged:
      case ScanCloudUploadStatus.completed:
      case ScanCloudUploadStatus.failed:
        return true;
      case ScanCloudUploadStatus.none:
      case ScanCloudUploadStatus.localPending:
      case ScanCloudUploadStatus.uploading:
      case ScanCloudUploadStatus.uploaded:
      case ScanCloudUploadStatus.queued:
      case ScanCloudUploadStatus.processing:
        return false;
    }
  }

  Future<void> _runLocalDa3(ScanRecord record) async {
    final copy = _MeActionCopy.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final captureDirPath = record.captureDir;
    if (captureDirPath == null || captureDirPath.trim().isEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(copy.localDa3NoBundle),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }
    final captureDir = Directory(captureDirPath);
    if (!captureDir.existsSync() ||
        !File('${captureDir.path}/photo_bundle.json').existsSync()) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(copy.localDa3NoBundle),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final runState = ValueNotifier<_LocalDa3RunState>(
      _LocalDa3RunState.running(
        title: copy.localDa3Preparing,
        detail: copy.localDa3PreparingDetail,
        debugText: _localDa3DebugText(
          captureDir: captureDir,
          status: 'preparing',
          raw: copy.localDa3PreparingDetail,
        ),
      ),
    );
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => _LocalDa3ProgressDialog(
          state: runState,
          closeLabel: copy.localDa3Close,
        ),
      ).whenComplete(runState.dispose),
    );
    await Future<void>.delayed(const Duration(milliseconds: 120));

    final depthDir = Directory('${captureDir.path}/stages/depth');
    if (depthDir.existsSync()) {
      await depthDir.delete(recursive: true);
    }
    await depthDir.create(recursive: true);
    final runLogFile = File('${depthDir.path}/local_da3_run_log.jsonl');
    await _appendLocalDa3RunLog(
      runLogFile,
      _localDa3LogEntry(
        captureDir: captureDir,
        status: 'preparing',
        raw: copy.localDa3PreparingDetail,
      ),
    );

    await ScanRecordStore.instance.addOrUpdate(
      record.copyWith(
        cloudUploadStatus: ScanCloudUploadStatus.processing,
        clearCloudUploadFailureMessage: true,
        localRawRetainedForDebug: true,
      ),
    );
    runState.value = _LocalDa3RunState.running(
      title: copy.localDa3Running,
      detail: copy.localDa3Started,
      debugText: _localDa3DebugText(
        captureDir: captureDir,
        logFile: runLogFile,
        status: 'started',
        raw: copy.localDa3Started,
      ),
    );

    final runner = LocalPipelineRunner(
      captureDir: captureDir,
      stages: const [DepthStage()],
    );
    final errors = <PipelineErrorEvent>[];
    final sub = runner.stream.listen((event) {
      debugPrint('[MePage] local DA3 $event');
      final logEntry = _localDa3LogEntry(
        captureDir: captureDir,
        logFile: runLogFile,
        event: event,
      );
      unawaited(_appendLocalDa3RunLog(runLogFile, logEntry));
      if (event is PipelineErrorEvent) errors.add(event);
      if (event is PipelineProgressEvent) {
        runState.value = _LocalDa3RunState.running(
          title: copy.localDa3Running,
          detail: _localDa3ProgressDetail(event.progress),
          progress: event.progress.stageFraction.clamp(0.0, 1.0).toDouble(),
          debugText: _localDa3DebugText(
            captureDir: captureDir,
            logFile: runLogFile,
            event: event,
          ),
        );
      }
    });

    try {
      await runner.run();
      if (errors.isNotEmpty) {
        final message = errors.last.error.message;
        await ScanRecordStore.instance.addOrUpdate(
          record.copyWith(
            cloudUploadStatus: ScanCloudUploadStatus.failed,
            cloudUploadFailureMessage: message,
            localRawRetainedForDebug: true,
          ),
        );
        runState.value = _LocalDa3RunState.failure(
          title: copy.localDa3FailedTitle,
          detail: copy.localDa3Failed(_shortTrainingError(message)),
          debugText: _localDa3DebugText(
            captureDir: captureDir,
            logFile: runLogFile,
            status: 'failed',
            raw: message,
          ),
        );
        return;
      }

      final depthIndexFile = File('${depthDir.path}/depth_index.json');
      final depthIndex = depthIndexFile.existsSync()
          ? jsonDecode(depthIndexFile.readAsStringSync())
          : const <String, Object?>{};
      final counts = depthIndex is Map
          ? _DepthStageCounts.fromJson(depthIndex.cast<String, Object?>())
          : const _DepthStageCounts();
      await ScanRecordStore.instance.addOrUpdate(
        record.copyWith(
          cloudUploadStatus: ScanCloudUploadStatus.localPending,
          clearCloudUploadFailureMessage: true,
          localRawRetainedForDebug: true,
        ),
      );
      runState.value = _LocalDa3RunState.success(
        title: copy.localDa3DoneTitle,
        detail: copy.localDa3Done(counts.summary),
        debugText: _localDa3DebugText(
          captureDir: captureDir,
          logFile: runLogFile,
          status: 'success',
          raw: counts.summary,
        ),
      );
    } catch (e) {
      await ScanRecordStore.instance.addOrUpdate(
        record.copyWith(
          cloudUploadStatus: ScanCloudUploadStatus.failed,
          cloudUploadFailureMessage: '$e',
          localRawRetainedForDebug: true,
        ),
      );
      runState.value = _LocalDa3RunState.failure(
        title: copy.localDa3FailedTitle,
        detail: copy.localDa3Failed(_shortTrainingError(e)),
        debugText: _localDa3DebugText(
          captureDir: captureDir,
          logFile: runLogFile,
          status: 'threw',
          raw: '$e',
        ),
      );
    } finally {
      await sub.cancel();
      await runner.dispose();
    }
  }

  String _localDa3ProgressDetail(PipelineProgress progress) {
    final pct = (progress.stageFraction * 100).clamp(0, 100).round();
    final detail = progress.detail ?? pipelineStageName(progress.stage);
    if (detail == 'deriving photo bundle sidecars') {
      return '正在生成 COLMAP / view graph / DA3 input（大图处理，可能需要 1-3 分钟）';
    }
    if (detail.startsWith('photo bundle ')) {
      final match = RegExp(
        r'^photo bundle (\w+): (\d+) frames, (\d+) graph edges, (\d+) COLMAP images$',
      ).firstMatch(detail);
      if (match != null) {
        return '素材衍生${match.group(1) == 'pass' ? '完成' : match.group(1)}：${match.group(2)} 帧，${match.group(3)} 条图边，${match.group(4)} 张 COLMAP 图';
      }
      return '素材衍生：$detail';
    }
    if (detail.startsWith('da3 ')) {
      final parts = detail.split(' ');
      if (parts.length >= 4 && parts.last == 'running') {
        return '正在运行 DA3 window ${parts[1]}';
      }
      return '正在运行 $detail · $pct%';
    }
    if (detail == 'done') {
      return '正在写入 Stage 1 结果';
    }
    return '$detail · $pct%';
  }

  Future<void> _appendLocalDa3RunLog(
    File file,
    Map<String, Object?> entry,
  ) async {
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${jsonEncode(entry)}\n',
      mode: FileMode.append,
      flush: true,
    );
  }

  Map<String, Object?> _localDa3LogEntry({
    required Directory captureDir,
    File? logFile,
    PipelineEvent? event,
    String? status,
    String? raw,
  }) {
    final entry = <String, Object?>{
      'time_utc': DateTime.now().toUtc().toIso8601String(),
      'capture': _pathBasename(captureDir.path),
      'capture_dir': captureDir.path,
      if (logFile != null) 'log_path': logFile.path,
    };
    if (status != null) entry['status'] = status;
    if (raw != null) entry['raw'] = raw;
    if (event is PipelineProgressEvent) {
      final progress = event.progress;
      entry.addAll({
        'event_type': 'progress',
        'stage': pipelineStageName(progress.stage),
        'stage_fraction': progress.stageFraction,
        'overall_fraction': progress.overallFraction,
        'event_elapsed_ms': progress.elapsed.inMilliseconds,
        'detail': progress.detail,
        'raw': progress.toString(),
      });
    } else if (event is PipelineErrorEvent) {
      entry.addAll({
        'event_type': 'error',
        'stage': pipelineStageName(event.error.stage),
        'code': event.error.code,
        'message': event.error.message,
        'retryable': event.error.isRetryable,
        'raw': event.toString(),
      });
    } else if (event is PipelineCompletedEvent) {
      entry.addAll({
        'event_type': 'completed',
        'output_glb': event.outputGlb.path,
        'total_elapsed_ms': event.totalElapsed.inMilliseconds,
        'raw': event.toString(),
      });
    } else if (event != null) {
      entry.addAll({
        'event_type': event.runtimeType.toString(),
        'raw': '$event',
      });
    }
    return entry;
  }

  String _localDa3DebugText({
    required Directory captureDir,
    File? logFile,
    PipelineEvent? event,
    String? status,
    String? raw,
  }) {
    final entry = _localDa3LogEntry(
      captureDir: captureDir,
      logFile: logFile,
      event: event,
      status: status,
      raw: raw,
    );
    final lines = <String>[
      'capture=${entry['capture']}',
      if (logFile != null) 'log=stages/depth/${_pathBasename(logFile.path)}',
      if (entry['status'] != null) 'status=${entry['status']}',
      if (entry['event_type'] != null) 'event=${entry['event_type']}',
      if (entry['stage'] != null) 'stage=${entry['stage']}',
      if (entry['stage_fraction'] != null)
        'stage_fraction=${_fixed3(entry['stage_fraction'])}',
      if (entry['overall_fraction'] != null)
        'overall_fraction=${_fixed3(entry['overall_fraction'])}',
      if (entry['event_elapsed_ms'] != null)
        'event_elapsed_ms=${entry['event_elapsed_ms']}',
      if (entry['detail'] != null) 'detail=${entry['detail']}',
      if (entry['code'] != null) 'code=${entry['code']}',
      if (entry['message'] != null) 'message=${entry['message']}',
      if (entry['raw'] != null) 'raw=${entry['raw']}',
    ];
    return lines.join('\n');
  }

  String _pathBasename(String path) {
    final parts = path.split('/');
    for (var i = parts.length - 1; i >= 0; i--) {
      if (parts[i].isNotEmpty) return parts[i];
    }
    return path;
  }

  String _fixed3(Object? value) {
    if (value is num) return value.toStringAsFixed(3);
    return '$value';
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

  Future<void> _confirmAndDeleteCloudRaw(ScanRecord record) async {
    final copy = _MeActionCopy.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(copy.deleteCloudRawTitle),
        content: Text(copy.deleteCloudRawContent(record.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(AppL10n.of(context).meActionCancel),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AetherColors.danger),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(copy.deleteCloudRaw),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      final deletedAt = await CloudCaptureRawRetentionService().deleteCloudRaw(
        record,
      );
      await ScanRecordStore.instance.addOrUpdate(
        record.copyWith(cloudRawDeletedAt: deletedAt ?? DateTime.now().toUtc()),
      );
      messenger.showSnackBar(
        SnackBar(
          content: Text(copy.deleteCloudRawDone),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(copy.deleteCloudRawFailed(_shortTrainingError(e))),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  String _shortTrainingError(Object error) {
    final text = error.toString();
    if (text.length <= 180) return text;
    return text.substring(0, 180);
  }
}

class _DepthStageCounts {
  final int completed;
  final int pending;
  final int failed;
  final int windows;

  const _DepthStageCounts({
    this.completed = 0,
    this.pending = 0,
    this.failed = 0,
    this.windows = 0,
  });

  factory _DepthStageCounts.fromJson(Map<String, Object?> json) {
    return _DepthStageCounts(
      completed: _intValue(json['completed_count']),
      pending: _intValue(json['pending_count']),
      failed: _intValue(json['failed_count']),
      windows: _intValue(json['window_count']),
    );
  }

  String get summary {
    final base = 'completed=$completed pending=$pending failed=$failed';
    return windows > 0 ? '$base windows=$windows' : base;
  }

  static int _intValue(Object? value) {
    if (value is num) return value.toInt();
    return 0;
  }
}

enum _LocalDa3RunPhase { running, success, failure }

class _LocalDa3RunState {
  const _LocalDa3RunState({
    required this.phase,
    required this.title,
    required this.detail,
    required this.debugText,
    this.progress,
  });

  final _LocalDa3RunPhase phase;
  final String title;
  final String detail;
  final String debugText;
  final double? progress;

  bool get isTerminal => phase != _LocalDa3RunPhase.running;

  factory _LocalDa3RunState.running({
    required String title,
    required String detail,
    required String debugText,
    double? progress,
  }) {
    return _LocalDa3RunState(
      phase: _LocalDa3RunPhase.running,
      title: title,
      detail: detail,
      debugText: debugText,
      progress: progress,
    );
  }

  factory _LocalDa3RunState.success({
    required String title,
    required String detail,
    required String debugText,
  }) {
    return _LocalDa3RunState(
      phase: _LocalDa3RunPhase.success,
      title: title,
      detail: detail,
      debugText: debugText,
      progress: 1,
    );
  }

  factory _LocalDa3RunState.failure({
    required String title,
    required String detail,
    required String debugText,
  }) {
    return _LocalDa3RunState(
      phase: _LocalDa3RunPhase.failure,
      title: title,
      detail: detail,
      debugText: debugText,
      progress: 1,
    );
  }
}

class _LocalDa3ProgressDialog extends StatefulWidget {
  final ValueListenable<_LocalDa3RunState> state;
  final String closeLabel;

  const _LocalDa3ProgressDialog({
    required this.state,
    required this.closeLabel,
  });

  @override
  State<_LocalDa3ProgressDialog> createState() =>
      _LocalDa3ProgressDialogState();
}

class _LocalDa3ProgressDialogState extends State<_LocalDa3ProgressDialog> {
  final DateTime _startedAt = DateTime.now();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !widget.state.value.isTerminal) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<_LocalDa3RunState>(
      valueListenable: widget.state,
      builder: (context, value, _) {
        final color = value.phase == _LocalDa3RunPhase.failure
            ? AetherColors.danger
            : AetherColors.primary;
        final elapsedSeconds = DateTime.now().difference(_startedAt).inSeconds;
        return PopScope(
          canPop: value.isTerminal,
          child: AlertDialog(
            title: Text(value.title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(
                  value: value.progress,
                  color: color,
                  backgroundColor: AetherColors.border,
                ),
                const SizedBox(height: 16),
                Text(
                  value.detail,
                  style: AetherTextStyles.caption.copyWith(
                    color: AetherColors.textSecondary,
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AetherColors.textPrimary.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    value.debugText,
                    style: const TextStyle(
                      fontFamily: 'Menlo',
                      fontSize: 10.5,
                      height: 1.28,
                      color: AetherColors.textSecondary,
                    ),
                  ),
                ),
                if (!value.isTerminal) ...[
                  const SizedBox(height: 8),
                  Text(
                    '已运行 ${elapsedSeconds}s',
                    style: AetherTextStyles.caption.copyWith(
                      color: AetherColors.textTertiary,
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              if (value.isTerminal)
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(widget.closeLabel),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _MeActionCopy {
  final String startTraining;
  final String runLocalDa3;
  final String localDa3Preparing;
  final String localDa3PreparingDetail;
  final String localDa3Running;
  final String localDa3Started;
  final String localDa3NoBundle;
  final String localDa3Close;
  final String localDa3DoneTitle;
  final String localDa3FailedTitle;
  final String Function(String) localDa3Done;
  final String Function(String) localDa3Failed;
  final String alreadyQueued;
  final String uploadFailed;
  final String waitForUpload;
  final String cloudRawDeleted;
  final String queued;
  final String Function(String) queueFailed;
  final String deleteCloudRaw;
  final String deleteCloudRawTitle;
  final String Function(String) deleteCloudRawContent;
  final String deleteCloudRawDone;
  final String Function(String) deleteCloudRawFailed;

  const _MeActionCopy({
    required this.startTraining,
    required this.runLocalDa3,
    required this.localDa3Preparing,
    required this.localDa3PreparingDetail,
    required this.localDa3Running,
    required this.localDa3Started,
    required this.localDa3NoBundle,
    required this.localDa3Close,
    required this.localDa3DoneTitle,
    required this.localDa3FailedTitle,
    required this.localDa3Done,
    required this.localDa3Failed,
    required this.alreadyQueued,
    required this.uploadFailed,
    required this.waitForUpload,
    required this.cloudRawDeleted,
    required this.queued,
    required this.queueFailed,
    required this.deleteCloudRaw,
    required this.deleteCloudRawTitle,
    required this.deleteCloudRawContent,
    required this.deleteCloudRawDone,
    required this.deleteCloudRawFailed,
  });

  static _MeActionCopy of(BuildContext context) {
    final zh = LocaleScope.of(context).isChinese;
    if (zh) {
      return _MeActionCopy(
        startTraining: '开始训练',
        runLocalDa3: '运行 Stage 1 DA3-BASE',
        localDa3Preparing: '准备运行 Stage 1',
        localDa3PreparingDetail: '正在打开本地 photo bundle',
        localDa3Running: '正在运行 Stage 1 DA3-BASE',
        localDa3Started: '开始运行 Stage 1 DA3-BASE',
        localDa3NoBundle: '没有找到本地 photo bundle',
        localDa3Close: '知道了',
        localDa3DoneTitle: 'Stage 1 完成',
        localDa3FailedTitle: 'Stage 1 失败',
        localDa3Done: (summary) => 'Stage 1 完成：$summary',
        localDa3Failed: (e) => 'Stage 1 失败：$e',
        alreadyQueued: '这条任务已经在训练队列中',
        uploadFailed: '素材上传失败，请等待自动重试或重新拍摄',
        waitForUpload: '素材还在上传或等待云端确认，稍后再开始训练',
        cloudRawDeleted: '云端原始素材已删除，无法重新训练',
        queued: '已加入训练队列',
        queueFailed: (e) => '开始训练失败：$e',
        deleteCloudRaw: '删除云端原始素材',
        deleteCloudRawTitle: '删除云端原始素材？',
        deleteCloudRawContent: (name) =>
            '删除「$name」的 4K 原始帧和拍摄 JSON 后，这次拍摄将不能再用高性能电脑或更高质量算法重新训练。已生成的模型不会被删除。',
        deleteCloudRawDone: '云端原始素材已删除',
        deleteCloudRawFailed: (e) => '删除云端原始素材失败：$e',
      );
    }
    return _MeActionCopy(
      startTraining: 'Start training',
      runLocalDa3: 'Run Stage 1 DA3-BASE',
      localDa3Preparing: 'Preparing Stage 1',
      localDa3PreparingDetail: 'Opening the local photo bundle',
      localDa3Running: 'Running Stage 1 DA3-BASE',
      localDa3Started: 'Started Stage 1 DA3-BASE',
      localDa3NoBundle: 'No local photo bundle found',
      localDa3Close: 'Done',
      localDa3DoneTitle: 'Stage 1 Finished',
      localDa3FailedTitle: 'Stage 1 Failed',
      localDa3Done: (summary) => 'Stage 1 finished: $summary',
      localDa3Failed: (e) => 'Stage 1 failed: $e',
      alreadyQueued: 'This draft is already queued',
      uploadFailed: 'Upload failed. Wait for retry or capture again.',
      waitForUpload:
          'The raw capture is still uploading or waiting for cloud ack.',
      cloudRawDeleted:
          'Cloud raw assets were deleted; retraining is unavailable.',
      queued: 'Added to training queue',
      queueFailed: (e) => 'Could not start training: $e',
      deleteCloudRaw: 'Delete cloud raw assets',
      deleteCloudRawTitle: 'Delete cloud raw assets?',
      deleteCloudRawContent: (name) =>
          'Deleting the 4K frames and capture JSON for "$name" means this capture cannot be retrained later on a desktop or higher-quality worker. Existing models are kept.',
      deleteCloudRawDone: 'Cloud raw assets deleted',
      deleteCloudRawFailed: (e) => 'Could not delete cloud raw assets: $e',
    );
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
