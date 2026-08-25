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
import 'dart:ui' as ui;
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../auth/auth_scope.dart';
import '../capture/sfm_resume.dart';
import '../l10n/app_localizations.dart';
import '../me/draft_card_action.dart';
import '../me/scan_record_store.dart';
import '../official_capture/sfm_resume.dart' as official_sfm_resume;
import 'capture/sfm_resume_wait_page.dart';
import 'capture/sparse_cloud_viewer_page.dart';
import 'design_system.dart';
import 'home_view_model.dart';
import 'me/my_work_detail_page.dart';
import 'me_settings_page.dart';
import 'me_stats_view_model.dart';
import 'scan_record.dart';
import 'scan_record_cell.dart';
import 'sparse_thumbnail.dart';

/// 草稿胶囊的续跑升格:store 只认 activeReconstructionCaptureDir(拍摄页
/// 那条腿),等待页的断点续跑它不知道 —— 那段时间 PLY 还没出,badgeOf 会给
/// "未完成"。这里升格成"生成中"。
///
/// [2026-08-08 用户实机指认] 留在续跑等待页等到点云生成、返回草稿页,卡片
/// 仍是"未完成"+照片封面。升格顺带让 anyGenerating 变 true ⇒ 2 秒轮询开
/// ⇒ PLY 落盘后草稿页自己会刷成"完成"并补上点云封面(提前返回也覆盖)。
ScanProcessingBadge draftBadgeWithResume(
  ScanProcessingBadge base, {
  required bool resumeInFlight,
}) => base == ScanProcessingBadge.unfinished && resumeInFlight
    ? ScanProcessingBadge.generating
    : base;

String sparsePlyFileNameForPipeline(CapturePipelineKind kind) {
  switch (kind) {
    case CapturePipelineKind.self:
      return 'sfm_sparse.ply';
    case CapturePipelineKind.official:
      return 'official_sfm_sparse.ply';
  }
}

String sfmDatabaseFileNameForPipeline(CapturePipelineKind kind) {
  switch (kind) {
    case CapturePipelineKind.self:
      return 'sfm_live.db';
    case CapturePipelineKind.official:
      return 'official_sfm_live.db';
  }
}

bool pipelineOwnsActiveReconstruction({
  required CapturePipelineKind recordPipelineKind,
  required CapturePipelineKind activePipelineKind,
}) {
  return recordPipelineKind == activePipelineKind;
}

bool recordOwnsActiveReconstruction({
  required String? recordCaptureDir,
  required CapturePipelineKind recordPipelineKind,
  required String? activeCaptureDir,
  required CapturePipelineKind activePipelineKind,
}) {
  if (!pipelineOwnsActiveReconstruction(
    recordPipelineKind: recordPipelineKind,
    activePipelineKind: activePipelineKind,
  )) {
    return false;
  }
  final record = _normalizedCaptureDir(recordCaptureDir);
  final active = _normalizedCaptureDir(activeCaptureDir);
  return record != null && active != null && record == active;
}

String? _normalizedCaptureDir(String? path) {
  if (path == null) return null;
  var normalized = path.trim();
  while (normalized.length > 1 && normalized.endsWith('/')) {
    normalized = normalized.substring(0, normalized.length - 1);
  }
  return normalized.isEmpty ? null : normalized;
}

/// Dispatches a sparse-cloud viewer without allowing either implementation to
/// fall back to the other pipeline. Returns whether a route was opened.
Future<bool> dispatchSparseCloudViewerForPipeline({
  required CapturePipelineKind pipelineKind,
  required Future<void> Function() openSelf,
  Future<void> Function()? openOfficial,
}) async {
  switch (pipelineKind) {
    case CapturePipelineKind.self:
      await openSelf();
      return true;
    case CapturePipelineKind.official:
      final route = openOfficial;
      if (route == null) return false;
      await route();
      return true;
  }
}

typedef OfficialScanResumeRoute =
    Future<void> Function(
      BuildContext context,
      ScanRecord record,
      String captureDir, {
      required bool regenerate,
    });

typedef OfficialScanViewerRoute =
    Future<void> Function(
      BuildContext context,
      ScanRecord record,
      String plyPath,
    );

typedef ActiveReconstructionDelete = Future<void> Function(ScanRecord record);

class MePage extends StatefulWidget {
  const MePage({
    super.key,
    this.showDraftsSignal,
    this.activeReconstructionCaptureDir,
    this.activeReconstructionPipelineKind = CapturePipelineKind.self,
    this.onActiveReconstructionTap,
    this.onActiveReconstructionDelete,
    this.officialResumeRoute,
    this.officialViewerRoute,
  });

  final ValueListenable<int>? showDraftsSignal;

  /// When MePage is temporarily shown above a still-running capture route,
  /// tapping that draft must reveal the existing reconstruction instead of
  /// opening a partial PLY or starting any new work.
  final String? activeReconstructionCaptureDir;
  final CapturePipelineKind activeReconstructionPipelineKind;
  final VoidCallback? onActiveReconstructionTap;
  final ActiveReconstructionDelete? onActiveReconstructionDelete;

  /// Injection point for the physically separate official resume page.
  /// Until that page is installed, official records never fall back to the
  /// self-developed `SfmResumeWaitPage`.
  final OfficialScanResumeRoute? officialResumeRoute;
  final OfficialScanViewerRoute? officialViewerRoute;

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
    if (!mounted) return;
    // [2026-08-10 用户实机指认"回到草稿页显示未完成,再点进一次才变完成"]
    // 信号 = "刚从拍摄流程回来"。此前"已在草稿页"这条路早退不 setState,
    // 于是屏幕停在 finalize 开始时(PLY 还没写)算出的那次红胶囊上 ——
    // pop 之后没有任何 build,statSync 再也没被问过;而根草稿页拿不到
    // activeReconstructionCaptureDir ⇒ anyGenerating=false ⇒ 2 秒轮询也
    // 不开,没有兜底。点卡片的 markResultViewed 恰是唯一会 _emit 的动作,
    // 这就是"再点一次才变完成"的全部机制。修:无论在哪个 tab,信号一到
    // 就空刷 —— badge 现场重算,PLY 在(用户看完点云才回)即刻转绿。
    // [2026-08-10 分页删除后] 不再有 tab 可切,信号的唯一作用就是这次重算。
    setState(() {});
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
                const SizedBox(height: AetherSpacing.lg),
                _MyWorksSection(
                  activeReconstructionCaptureDir:
                      widget.activeReconstructionCaptureDir,
                  activeReconstructionPipelineKind:
                      widget.activeReconstructionPipelineKind,
                  onActiveReconstructionTap: widget.onActiveReconstructionTap,
                  onActiveReconstructionDelete:
                      widget.onActiveReconstructionDelete,
                  officialResumeRoute: widget.officialResumeRoute,
                  officialViewerRoute: widget.officialViewerRoute,
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
class _MyWorksSection extends StatefulWidget {
  final String? activeReconstructionCaptureDir;
  final CapturePipelineKind activeReconstructionPipelineKind;
  final VoidCallback? onActiveReconstructionTap;
  final ActiveReconstructionDelete? onActiveReconstructionDelete;
  final OfficialScanResumeRoute? officialResumeRoute;
  final OfficialScanViewerRoute? officialViewerRoute;

  const _MyWorksSection({
    this.activeReconstructionCaptureDir,
    this.activeReconstructionPipelineKind = CapturePipelineKind.self,
    this.onActiveReconstructionTap,
    this.onActiveReconstructionDelete,
    this.officialResumeRoute,
    this.officialViewerRoute,
  });

  @override
  State<_MyWorksSection> createState() => _MyWorksSectionState();
}

class _MyWorksSectionState extends State<_MyWorksSection>
    with WidgetsBindingObserver {
  final HomeViewModel _vm = HomeViewModel();

  /// "生成中"卡片的轮询。
  ///
  /// [2026-08-06 用户签决] "用户停留在草稿页……训练完成了,卡片就变成完成"。
  /// 完成信号是 PLY 落盘 —— 那是文件系统事件,不经过 ScanRecordStore,所以
  /// store.changes 不会通知我们。只在**有卡片正在生成时**才开表,全都生成完就
  /// 自己停,避免常驻定时器。
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _vm.addListener(_rebuild);
    _vm.loadRecords();
    // 老数据一次性视为"已看过",否则功能一上线历史草稿会同时冒出"完成"胶囊。
    unawaited(ScanRecordStore.instance.migrateExistingSparseAsViewed());
    unawaited(_ensureCloudThumbs());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    _vm.removeListener(_rebuild);
    _vm.dispose();
    super.dispose();
  }

  /// 切后台再回来:立刻重算一次(生成可能在后台完成了)。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _rebuild();
  }

  /// 逐个补齐点云缩略图。
  ///
  /// [2026-08-07 用户签决,学 Polycam] 卡片展示稀疏点云而不是照片。
  /// 🔴 **串行**且复用同一张 sprite:一屏 4-6 张卡、全量十几张,每张几十万点。
  /// 并行铺开会把 GPU 顶满,而这个 App 的热稳定是硬约束(拍摄链路因热压挂死过
  /// GPU)。每张画完 await 一帧让出主线程,滚动不卡。
  bool _thumbJobRunning = false;

  Future<void> _ensureCloudThumbs() async {
    if (_thumbJobRunning) return;
    _thumbJobRunning = true;
    ui.Image? sprite;
    try {
      await ScanRecordStore.instance.ensureLoaded();
      for (final r in List<ScanRecord>.from(ScanRecordStore.instance.records)) {
        if (!mounted) return;
        final dir = r.captureDir;
        if (dir == null) continue;
        final ply = '$dir/${sparsePlyFileNameForPipeline(r.pipelineKind)}';
        if (sparseThumbFresh(
          plyPath: ply,
          thumbPath: sparseThumbPathFor(dir),
        )) {
          continue;
        }
        sprite ??= await buildPointSprite();
        final made = await ensureSparseThumb(
          captureDir: dir,
          plyPath: ply,
          sprite: sprite,
        );
        if (!mounted) return;
        if (made != null) _rebuild(); // 画完一张就刷一张,不等全部
        // 让出一帧:滚动/手势优先于补图。
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
    } finally {
      sprite?.dispose();
      _thumbJobRunning = false;
    }
  }

  /// 有"生成中"就开表,没有就停 —— 每次 build 后调。
  void _syncPolling(bool anyGenerating) {
    if (anyGenerating) {
      _pollTimer ??= Timer.periodic(const Duration(seconds: 2), (_) {
        _rebuild();
        // 生成中的那些一旦出了 PLY,顺带把缩略图补上。
        unawaited(_ensureCloudThumbs());
      });
    } else {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    // _vm.loadRecords subscribes to ScanRecordStore.changes and notifies
    // us, so reading the store directly here stays in sync.
    // [2026-08-10 用户签决] "删除项目和草稿的分页,以后不管什么阶段的存档,
    // 都用卡片的形式放在一起,继续以现在的时间顺序排序。" —— 此前按
    // hasCompletedArtifact 二分成"项目/草稿"两页;现在单列表全量,顺序仍是
    // store 的 createdAt 新→旧。
    final mine = ScanRecordStore.instance.records;
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
    final store = ScanRecordStore.instance;
    final badges = {
      for (final r in mine)
        r.id: draftBadgeWithResume(
          store.badgeOf(
            r,
            // 只有 App 当前真的在重建的那个 capture 才算"生成中";其余没出 PLY 的
            // 一律"未完成"(闪退/被杀/中断,点卡片会弹"继续重建?")。
            activeReconstructionCaptureDir:
                widget.activeReconstructionCaptureDir,
          ),
          // 断点续跑在飞的也算"生成中" —— 按目录名比,record 存的绝对路径
          // 可能是旧容器的(见 isResumeInFlightForDirName)。
          resumeInFlight:
              r.captureDir != null &&
              _resumeInFlightForRecord(
                r.pipelineKind,
                r.captureDir!.split('/').where((e) => e.isNotEmpty).last,
              ),
        ),
    };
    // build 里不能直接 setState,轮询开关推到帧后。
    final anyGenerating = badges.values.contains(
      ScanProcessingBadge.generating,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncPolling(anyGenerating);
    });
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
            processingBadge: badges[r.id] ?? ScanProcessingBadge.none,
            onTap: () => _onTap(r),
            onLongPress: () => _showRecordActions(r),
          ),
      ],
    );
  }

  Future<void> _onTap(ScanRecord record) async {
    // [2026-08-06 用户签决] "第一次点击进项目卡片查看后退出,右上角的提示就消失
    // 了"。在这里标记而不是等退出回调 —— 点进去就算看过,而且退出路径有好几条
    // (返回手势/按钮/被系统杀),挂在入口最可靠。
    unawaited(ScanRecordStore.instance.markResultViewed(record));
    // 路由决策提纯为纯函数(draft_card_action.dart),契约由
    // tool/draft_reentry_check.dart 在纯 Dart VM 上穷举断言:
    //   • finalize 进行中点同一任务卡 → 回原等待页,绝不起第二个重建;
    //   • finalize 完成后点击 → 打开成品;
    //   • 重建被打断(有 sfm_live.db 无 PLY)→ 弹"继续重建"确认。
    // 这里只做文件探测与执行。
    final captureDir = record.captureDir;
    final sparsePlyPath = captureDir == null
        ? null
        : '$captureDir/${sparsePlyFileNameForPipeline(record.pipelineKind)}';
    final sparsePlyExists =
        sparsePlyPath != null && File(sparsePlyPath).existsSync();
    // 容器 UUID 变更兜底:按目录名在当前 Documents 下重找 sfm_live.db。
    final recoverableDir = await _resolveRecoverableCaptureDir(record);
    if (!mounted) return;
    final ownsActiveReconstruction = pipelineOwnsActiveReconstruction(
      recordPipelineKind: record.pipelineKind,
      activePipelineKind: widget.activeReconstructionPipelineKind,
    );
    final action = draftCardActionFor(
      recordCaptureDir: captureDir,
      hasArtifact: record.artifactPath != null,
      sparsePlyExists: sparsePlyExists,
      sfmDbExists: recoverableDir != null,
      // The native SfM session is process-global: an active reconstruction in
      // either route blocks starting a resume in the other route too. Keep the
      // route check only for the callback that reopens the owning wait page.
      activeReconstructionCaptureDir: widget.activeReconstructionCaptureDir,
      hasActiveReconstructionCallback:
          ownsActiveReconstruction && widget.onActiveReconstructionTap != null,
    );
    switch (action) {
      case DraftCardAction.reopenActiveReconstruction:
        // capture route 仍在本临时草稿视图之下 —— 回它的等待页看进度。
        widget.onActiveReconstructionTap?.call();
      case DraftCardAction.openWorkDetail:
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => MyWorkDetailPage(recordId: record.id),
          ),
        );
      case DraftCardAction.openSparseCloud:
        await _openSparseCloud(record, sparsePlyPath!);
      case DraftCardAction.offerResume:
        await _offerResume(record, recoverableDir!);
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
    if (record.pipelineKind == CapturePipelineKind.official) {
      final route = widget.officialResumeRoute;
      if (route == null) return;
      await route(context, record, recoverableDir, regenerate: regenerate);
      _refreshAfterResumeReturn();
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
      if (confirmed != true) return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            SfmResumeWaitPage(captureDir: recoverableDir, title: record.name),
      ),
    );
    _refreshAfterResumeReturn();
  }

  /// 两条管线各有一张 in-flight 表 —— 按 record 的管线查对应那张。
  static bool _resumeInFlightForRecord(CapturePipelineKind kind, String name) =>
      switch (kind) {
        CapturePipelineKind.self => isResumeInFlightForDirName(name),
        CapturePipelineKind.official =>
          official_sfm_resume.isResumeInFlightForDirName(name),
      };

  /// 从续跑等待页返回的那一刻立刻重算胶囊 + 补点云封面 —— 不等 2 秒轮询。
  /// [2026-08-08 用户实机指认] 等到点云生成才返回,卡片却还是照片 +"未完成"。
  void _refreshAfterResumeReturn() {
    if (!mounted) return;
    setState(() {});
    unawaited(_ensureCloudThumbs());
  }

  /// Long-press handler — opens a bottom sheet with train / rename / delete.
  /// Drafts can explicitly enter the cloud worker queue from here; upload
  /// acknowledgement alone is just "raw safely reached cloud".
  Future<void> _showRecordActions(ScanRecord record) async {
    final l = AppL10n.of(context);
    // 拍摄期落盘的稀疏点云(sfm_sparse.ply)存在时,提供 in-app 查看入口。
    final captureDir = record.captureDir;
    final sparsePlyPath = captureDir == null
        ? null
        : '$captureDir/${sparsePlyFileNameForPipeline(record.pipelineKind)}';
    final canViewSparse =
        sparsePlyPath != null && File(sparsePlyPath).existsSync();
    // 断点数据仍在(sfm_live.db 按契约保留)且当前没有别的重建在跑时,
    // 提供"重新重建点云"入口 —— 覆盖 PLY 已存在的场景(点击卡片只会打开
    // 查看器,永远到不了 offerResume 分支):恢复幂等,完成后覆盖旧 PLY。
    // 有活跃重建时不提供(双原生 SfM 会话会把内存/热推过真机上限,与
    // draft_card_action 的续跑门同一规矩)。
    final rebuildDir =
        widget.activeReconstructionCaptureDir == null && captureDir != null
        ? await _resolveRecoverableCaptureDir(record)
        : null;
    if (!mounted) return;
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
    if (action == 'view_sparse' && sparsePlyPath != null) {
      await _openSparseCloud(record, sparsePlyPath);
    } else if (action == 'rebuild_sparse' && rebuildDir != null) {
      await _offerResume(record, rebuildDir, regenerate: canViewSparse);
    } else if (action == 'rename') {
      await _renameRecord(record);
    } else if (action == 'delete') {
      await _confirmAndDelete(record);
    }
  }

  Future<void> _openSparseCloud(ScanRecord record, String plyPath) async {
    // [2026-08-24] 长按菜单"查看点云"不经过 _onTap,此前漏标"看过" ——
    // 打开查看器的动作本身就该算看过(与卡片点击入口同一契约,幂等)。
    unawaited(ScanRecordStore.instance.markResultViewed(record));
    final officialRoute = widget.officialViewerRoute;
    await dispatchSparseCloudViewerForPipeline(
      pipelineKind: record.pipelineKind,
      openSelf: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => SparseCloudViewerPage(
            plyPath: plyPath,
            title: record.name.isEmpty ? '稀疏点云' : record.name,
          ),
        ),
      ),
      openOfficial: officialRoute == null
          ? null
          : () => officialRoute(context, record, plyPath),
    );
    // [2026-08-10] 从查看器返回立刻重算胶囊 —— 与续跑路径的
    // _refreshAfterResumeReturn 同一纪律(此前查看器路径漏了这一刷)。
    if (mounted) setState(() {});
  }

  Future<String?> _resolveRecoverableCaptureDir(ScanRecord record) async {
    final captureDir = record.captureDir;
    if (captureDir == null || captureDir.isEmpty) return null;
    if (record.pipelineKind == CapturePipelineKind.self) {
      return resolveRecoverableCaptureDir(captureDir);
    }
    return official_sfm_resume.resolveRecoverableCaptureDir(captureDir);
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
    if (recordOwnsActiveReconstruction(
          recordCaptureDir: record.captureDir,
          recordPipelineKind: record.pipelineKind,
          activeCaptureDir: widget.activeReconstructionCaptureDir,
          activePipelineKind: widget.activeReconstructionPipelineKind,
        ) &&
        widget.onActiveReconstructionDelete != null) {
      await widget.onActiveReconstructionDelete!(record);
      return;
    }
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
