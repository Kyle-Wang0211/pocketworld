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
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../auth/auth_scope.dart';
import '../capture/sfm_resume.dart';
import '../community/social_profile_models.dart';
import '../community/social_profile_repository.dart';
import '../l10n/app_localizations.dart';
import '../me/draft_card_action.dart';
import '../me/scan_record_store.dart';
import '../me/train_gate.dart';
import '../official_capture/database_archive_policy.dart';
import '../official_capture/live_sfm_publish_policy.dart';
import '../official_capture/sfm_resume.dart' as official_sfm_resume;
import '../official_capture/sqlite_db_health.dart';
import '../official_util/device_log.dart';
import 'capture/sfm_resume_wait_page.dart';
import 'capture/sparse_cloud_viewer_page.dart';
import 'community/following_list_page.dart';
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

/// [2026-09-08 追加拍摄] 往已有项目补拍。返回是否真的补了照片。
typedef OfficialExtendCaptureRoute =
    Future<bool> Function(
      BuildContext context,
      ScanRecord record,
      String captureDir,
    );

/// [2026-09-08] db 已损坏时的恢复路:把存档照片重新喂一遍。
typedef OfficialRebuildFromPhotosRoute =
    Future<void> Function(
      BuildContext context,
      ScanRecord record,
      String captureDir, {
      required int photoCount,
    });

typedef ActiveReconstructionDelete = Future<void> Function(ScanRecord record);

class MePage extends StatefulWidget {
  const MePage({
    super.key,
    this.showDraftsSignal,
    this.activeReconstructionCaptureDir,
    this.activeReconstructionPipelineKind = CapturePipelineKind.self,
    this.onActiveReconstructionTap,
    this.onActiveReconstructionDelete,
    this.onRecordActionActivityChanged,
    this.officialResumeRoute,
    this.officialRebuildFromPhotosRoute,
    this.officialViewerRoute,
    this.officialExtendRoute,
    this.socialProfileRepository,
  });

  final ValueListenable<int>? showDraftsSignal;

  /// When MePage is temporarily shown above a still-running capture route,
  /// tapping that draft must reveal the existing reconstruction instead of
  /// opening a partial PLY or starting any new work.
  final String? activeReconstructionCaptureDir;
  final CapturePipelineKind activeReconstructionPipelineKind;
  final VoidCallback? onActiveReconstructionTap;
  final ActiveReconstructionDelete? onActiveReconstructionDelete;

  /// Keeps a temporary Drafts owner mounted while its long-press sheet and
  /// any follow-up rename/delete dialog are active. Without this handshake a
  /// reconstruction that becomes terminal behind the sheet can replace this
  /// widget, leaving a visually live but functionally orphaned modal route.
  final ValueChanged<bool>? onRecordActionActivityChanged;

  /// Injection point for the physically separate official resume page.
  /// Until that page is installed, official records never fall back to the
  /// self-developed `SfmResumeWaitPage`.
  final OfficialScanResumeRoute? officialResumeRoute;
  final OfficialRebuildFromPhotosRoute? officialRebuildFromPhotosRoute;
  final OfficialScanViewerRoute? officialViewerRoute;

  /// 补拍入口。未注入时「拍摄更多照片」只提示,绝不静默失败。
  final OfficialExtendCaptureRoute? officialExtendRoute;
  final SocialProfileRepository? socialProfileRepository;

  @override
  State<MePage> createState() => _MePageState();
}

class _MePageState extends State<MePage> {
  // Lives on the parent so MeSettingsPage receives the same instance and
  // doesn't have to re-fetch profiles / notification_settings every time
  // it's pushed.
  final MeStatsViewModel _stats = MeStatsViewModel();
  SocialProfileRepository? _socialRepository;
  SocialProfile? _socialProfile;
  String? _socialProfileUserId;
  Object? _socialProfileError;
  bool _socialProfileLoading = false;

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
      MaterialPageRoute<void>(
        builder: (_) => MeSettingsPage(
          stats: _stats,
          socialRepository: _socialProfileRepository(),
        ),
      ),
    );
  }

  Future<void> _onRefresh() async {
    // Plan G W2 全本地: no cloud sync. Pull-to-refresh just re-reads
    // the local store stats so a draft created since last view shows up.
    await Future.wait<void>([
      _stats.load(),
      if (_socialProfileUserId != null)
        _loadSocialProfile(_socialProfileUserId!),
    ]);
  }

  SocialProfileRepository _socialProfileRepository() {
    return _socialRepository ??=
        widget.socialProfileRepository ??
        SupabaseSocialProfileRepository(client: Supabase.instance.client);
  }

  Future<void> _loadSocialProfile(String userId) async {
    if (_socialProfileLoading) return;
    setState(() {
      _socialProfileLoading = true;
      _socialProfileError = null;
      _socialProfileUserId = userId;
    });
    try {
      final profile = await _socialProfileRepository().fetchProfile(userId);
      if (!mounted || _socialProfileUserId != userId) return;
      setState(() => _socialProfile = profile);
    } catch (error) {
      if (!mounted || _socialProfileUserId != userId) return;
      setState(() => _socialProfileError = error);
    } finally {
      if (mounted && _socialProfileUserId == userId) {
        setState(() => _socialProfileLoading = false);
      }
    }
  }

  Future<void> _openFollowing(String userId) async {
    final repository = _socialProfileRepository();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            FollowingListPage(userId: userId, repository: repository),
      ),
    );
    if (mounted) await _loadSocialProfile(userId);
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
    final socialUserId = user.id.rawValue;
    if (_socialProfileUserId != socialUserId && !_socialProfileLoading) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _loadSocialProfile(socialUserId);
      });
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
                _MeSocialSummary(
                  profile: _socialProfile,
                  loading: _socialProfileLoading,
                  hasError: _socialProfileError != null,
                  onRetry: () => _loadSocialProfile(socialUserId),
                  onFollowingTap: () => _openFollowing(socialUserId),
                ),
                const SizedBox(height: AetherSpacing.xl),
                _MyWorksSection(
                  activeReconstructionCaptureDir:
                      widget.activeReconstructionCaptureDir,
                  activeReconstructionPipelineKind:
                      widget.activeReconstructionPipelineKind,
                  onActiveReconstructionTap: widget.onActiveReconstructionTap,
                  onActiveReconstructionDelete:
                      widget.onActiveReconstructionDelete,
                  onRecordActionActivityChanged:
                      widget.onRecordActionActivityChanged,
                  officialResumeRoute: widget.officialResumeRoute,
                  officialRebuildFromPhotosRoute:
                      widget.officialRebuildFromPhotosRoute,
                  officialExtendRoute: widget.officialExtendRoute,
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

class _MeSocialSummary extends StatelessWidget {
  const _MeSocialSummary({
    required this.profile,
    required this.loading,
    required this.hasError,
    required this.onRetry,
    required this.onFollowingTap,
  });

  final SocialProfile? profile;
  final bool loading;
  final bool hasError;
  final VoidCallback onRetry;
  final VoidCallback onFollowingTap;

  @override
  Widget build(BuildContext context) {
    final value = profile;
    if (value == null && loading) {
      return const SizedBox(
        height: 104,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (value == null && hasError) {
      return Container(
        padding: const EdgeInsets.all(AetherSpacing.lg),
        decoration: BoxDecoration(
          color: AetherColors.bgCanvas,
          borderRadius: BorderRadius.circular(AetherRadii.md),
        ),
        child: Row(
          children: [
            Expanded(child: Text(AppL10n.of(context).meSocialLoadFailed)),
            TextButton(
              onPressed: onRetry,
              child: Text(AppL10n.of(context).communityRetry),
            ),
          ],
        ),
      );
    }
    if (value == null) return const SizedBox.shrink();

    final identity = <String>[
      if (value.handle != null) '@${value.handle}',
      if (value.lastRegion != null) value.lastRegion!,
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.all(AetherSpacing.lg),
      decoration: BoxDecoration(
        color: AetherColors.bgCanvas,
        borderRadius: BorderRadius.circular(AetherRadii.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value.displayName, style: AetherTextStyles.h2),
          if (identity.isNotEmpty) ...[
            const SizedBox(height: AetherSpacing.xs),
            Text(identity, style: AetherTextStyles.bodySm),
          ],
          const SizedBox(height: AetherSpacing.lg),
          Row(
            children: [
              _MeSocialCount(
                value: value.publicWorksCount,
                label: AppL10n.of(context).socialWorks,
              ),
              _MeSocialCount(
                value: value.followersCount,
                label: AppL10n.of(context).socialFollowers,
              ),
              _MeSocialCount(
                value: value.followingCount,
                label: AppL10n.of(context).socialFollow,
                onTap: onFollowingTap,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MeSocialCount extends StatelessWidget {
  const _MeSocialCount({required this.value, required this.label, this.onTap});

  final int value;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AetherRadii.sm),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: AetherSpacing.sm),
          child: Column(
            children: [
              Text('$value', style: AetherTextStyles.h3),
              const SizedBox(height: AetherSpacing.xs),
              Text(label, style: AetherTextStyles.bodySm),
            ],
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
  final ValueChanged<bool>? onRecordActionActivityChanged;
  final OfficialScanResumeRoute? officialResumeRoute;
  final OfficialRebuildFromPhotosRoute? officialRebuildFromPhotosRoute;
  final OfficialScanViewerRoute? officialViewerRoute;
  final OfficialExtendCaptureRoute? officialExtendRoute;

  const _MyWorksSection({
    this.activeReconstructionCaptureDir,
    this.activeReconstructionPipelineKind = CapturePipelineKind.self,
    this.onActiveReconstructionTap,
    this.onActiveReconstructionDelete,
    this.onRecordActionActivityChanged,
    this.officialResumeRoute,
    this.officialRebuildFromPhotosRoute,
    this.officialViewerRoute,
    this.officialExtendRoute,
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

  /// 上一帧哪些卡片还在"生成中" —— 用来做**边沿触发**:只在
  /// 「生成中 → 不再生成中」那**一次**响,不是每次 build 都响,也不是
  /// 每 2 秒轮询都响。
  ///
  /// [2026-09-10 用户令] "在任务完成那一瞬间可以加一个强震动的效果"。
  /// 用 `heavyImpact` —— 与快门那一次同一种(ar_capture_page 的
  /// `_triggerShutterHaptic`),全仓不引入第二种强度口径。
  Set<String> _generatingIds = <String>{};

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

  /// 任务完成那一瞬间的强震动。**绝不抛** —— 震动失败不该打断作品页的刷新
  /// (静默出口那条规矩的反面:失败要留痕,但不能穿出去)。
  void _triggerCompletionHaptic() {
    unawaited(
      HapticFeedback.heavyImpact().catchError((
        Object error,
        StackTrace stackTrace,
      ) {
        DeviceLog.log('MePage', 'completion haptic failed: $error');
      }),
    );
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
    final nowGenerating = <String>{
      for (final e in badges.entries)
        if (e.value == ScanProcessingBadge.generating) e.key,
    };
    // 完成 = 上一帧在生成中、这一帧不在了。**只认这一次边沿**;
    // 卡片被删掉也会离开这个集合,所以要求它此刻仍在列表里。
    final justFinished = _generatingIds
        .difference(nowGenerating)
        .where((id) => badges.containsKey(id))
        .toList();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncPolling(anyGenerating);
      if (justFinished.isNotEmpty) _triggerCompletionHaptic();
    });
    _generatingIds = nowGenerating;
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

  /// Long-press handler — 未完成的卡片给「开始训练 / 拍摄更多照片 / 改名 /
  /// 删除」四栏;已经出过点云的卡片保留原来的「查看点云 / 重新重建点云 /
  /// 改名 / 删除」(对它们"开始训练"不是待办而是重跑)。
  ///
  /// [2026-09-07 用户签决] 20 张的判定此前**全 app 只有一处** —— 拍摄页
  /// 「结束任务」按钮上的 [officialCaptureCanFinish]。而"未完成"卡片按定义
  /// 就是没走那条出口的(闪退/被杀/中途退出 → 孤儿恢复捡回来,恢复门槛只有
  /// `photos.isEmpty`,1 张也会变成一张卡)。异常路径绕过唯一的闸、作品页
  /// 又不复查 ⇒ 不足 20 张照样能开始重建。这里补上复查。
  ///
  /// 阈值**不复制**:直接调用拍摄页那同一个 [officialCaptureCanFinish]。
  /// 常数只有 [kOfficialMinimumCaptureFrames] 一处定义,两个入口同源,
  /// 将来改 20 不会漏掉其中一边。
  Future<void> _showRecordActions(ScanRecord record) async {
    widget.onRecordActionActivityChanged?.call(true);
    try {
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
      // [2026-09-08] db 在 ≠ db 能开。拍摄被杀留下的是个 4096 字节的残骸
      // (头声称 3025 页、文件只有 1 页 ⇒ sqlite 报 malformed),而
      // _resolveRecoverableCaptureDir 只回答"文件在不在" —— 于是「开始训练」
      // 一路走到 native 才炸成 errDb,用户看到红弹窗而不是一句人话。
      // 这里先用结构性判据看一眼(只读 100 字节 + 一次 stat)。
      final dbHealth = rebuildDir == null
          ? null
          : sqliteDatabaseUsable(
              File('$rebuildDir/${DatabaseArchivePolicy.sourceFileName}'),
            );
      final dbUsable = rebuildDir != null && (dbHealth?.usable ?? false);
      // [2026-09-11] db 打得开 ≠ db 里装着全部照片。未命名(8) 补拍之后那个 db
      // 头完全自洽(3032 页对 3032 页),但只装了 6 张,盘上有 26 张 —— 只问
      // "打不开吗"会把它送去续跑,交付一朵缺 20 张素材的云,而且每次都"成功"。
      final coverage = rebuildDir == null
          ? null
          : official_sfm_resume.projectCoverage(rebuildDir);
      final dbCoversAllPhotos = coverage?.covered ?? false;
      final photoCount = await _countCapturePhotos(record);
      if (!mounted) return;
      // 判定提纯为纯函数(train_gate.dart),阈值同源于拍摄页的
      // officialCaptureCanFinish —— 本文件里没有 20 这个数字。
      final trainGate = trainGateFor(
        photoCount: photoCount,
        hasResumableData: dbUsable,
        // db 坏了不是死路:存档照片还在就能重喂(Mac 台架已验同一批照片
        // 12/12 注册)。所以这里只问"还有没有照片可喂"。
        canRebuildFromPhotos:
            rebuildDir != null &&
            official_sfm_resume.archivedPhotoCount(rebuildDir) > 0,
        anotherReconstructionActive:
            widget.activeReconstructionCaptureDir != null,
      );
      final trainRoute = trainRouteFor(
        hasResumableData: dbUsable,
        dbCoversAllPhotos: dbCoversAllPhotos,
      );
      final trainEnabled = trainGate == TrainGate.ready;
      if (coverage != null && !coverage.covered) {
        DeviceLog.log(
          'MePage',
          'db 覆盖不全 for ${record.id}: ${coverage.reason} '
              '(盘上 ${coverage.photosOnDisk} 张 / 账本 ${coverage.fedDistinct} 张)'
              ' → route=$trainRoute',
        );
      }
      if (dbHealth != null && !dbHealth.usable) {
        DeviceLog.log(
          'MePage',
          'db unusable for ${record.id}: ${dbHealth.reason} '
              '→ route=$trainRoute photos=$photoCount',
        );
      }
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
              // [2026-09-08 用户裁决] 已出点云的卡片**只给「改名 / 删除」**:
              //   ·「重新重建点云」删 —— 点云已经在那儿了,重跑是给自己找事;
              //   ·「查看点云」删 —— 点卡片本来就直接开点云查看器
              //     (draft_card_action 的 openSparseCloud),菜单里再放一个是重复;
              //   · 补拍也不给 —— 只有"未完成"的项目才需要补拍。
              if (!canViewSparse) ...[
                // 置灰的项**仍然可点** —— 点击是唯一能问出"为什么点不动"的
                // 动作,所以它必须有回答(居中 3 秒提示),而不是吞掉。
                ListTile(
                  leading: Icon(
                    Icons.auto_awesome_rounded,
                    color: trainEnabled
                        ? AetherColors.textPrimary
                        : AetherColors.textTertiary,
                  ),
                  title: Text(
                    '开始训练',
                    style: TextStyle(
                      color: trainEnabled
                          ? AetherColors.textPrimary
                          : AetherColors.textTertiary,
                    ),
                  ),
                  onTap: () => Navigator.of(
                    ctx,
                  ).pop(trainEnabled ? 'rebuild_sparse' : 'train_blocked'),
                ),
                ListTile(
                  leading: const Icon(Icons.add_a_photo_outlined),
                  title: const Text('拍摄更多照片'),
                  onTap: () => Navigator.of(ctx).pop('capture_more'),
                ),
              ],
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
      if (action == 'rebuild_sparse' && rebuildDir != null) {
        switch (trainRoute) {
          case TrainRoute.resumeFromDb:
            await _offerResume(record, rebuildDir, regenerate: canViewSparse);
          case TrainRoute.rebuildFromArchivedPhotos:
            // 每个不可用分支都要说清原因 —— 不做成点了没反应的死按钮。
            final route = widget.officialRebuildFromPhotosRoute;
            if (record.pipelineKind != CapturePipelineKind.official) {
              _showCenterToast('这个项目不是官方管线拍的，\n无法从照片重建。');
            } else if (route == null) {
              _showCenterToast('从照片重建的入口没有接上。');
            } else {
              await route(context, record, rebuildDir, photoCount: photoCount);
              _refreshAfterResumeReturn();
            }
        }
      } else if (action == 'train_blocked') {
        _showCenterToast(_trainBlockedReason(trainGate, photoCount));
      } else if (action == 'capture_more') {
        // [2026-09-08 追加拍摄] 复刻 RealityScan:新照片丢进同一个项目,坐标系
        // 由 SfM 按图像重新对齐,不碰任何厂商 AR SDK。补完之后点「开始训练」
        // 走现有 resume —— worker 的 resume 分支本来就是照整个 db 重建的
        // (sfm_live_recon.dart:2295),新老照片自然一起。
        //
        // 每个不可用分支都必须说清原因,不做成点了没反应的死按钮。
        final extendRoute = widget.officialExtendRoute;
        if (record.pipelineKind != CapturePipelineKind.official) {
          _showCenterToast('这个项目不是官方管线拍的，\n暂不支持补拍。');
        } else if (extendRoute == null) {
          _showCenterToast('补拍入口没有接上。');
        } else if (widget.activeReconstructionCaptureDir != null) {
          _showCenterToast('另一个项目正在重建中。\n等它完成后再补拍。');
        } else if (rebuildDir == null) {
          _showCenterToast('找不到这次拍摄的重建数据，\n无法补拍。');
        } else {
          final added = await extendRoute(context, record, rebuildDir);
          if (added && mounted) {
            setState(() {});
            unawaited(_ensureCloudThumbs());
          }
        }
      } else if (action == 'rename') {
        await _renameRecord(record);
      } else if (action == 'delete') {
        await _confirmAndDelete(record);
      }
    } finally {
      widget.onRecordActionActivityChanged?.call(false);
    }
  }

  /// 这次拍摄实际留在盘上的照片张数 —— 「开始训练」置灰与否的唯一判据。
  ///
  /// 以磁盘为准而不是 `record.photoCount`:后者是保存那一刻的快照,用户之后
  /// 删过照片("照片删了,数据也必须删了")它就偏大,偏大意味着闸会放行一个
  /// 其实不足 20 张的项目。photoCount 只在没有 photosDir 的旧记录上兜底。
  ///
  /// 只数 JPEG、不要求 `.json` 伴生文件:孤儿恢复要伴生文件是因为它要重建
  /// manifest(需要位姿),而这里问的是"拍了几张"。把伴生文件写进判据,一个
  /// sidecar 丢失就会把张数静默算成 0、整个菜单错误置灰。
  static Future<int> _countCapturePhotos(ScanRecord record) async {
    final dirPath = record.photosDir;
    if (dirPath == null || dirPath.isEmpty) return record.photoCount ?? 0;
    final dir = Directory(dirPath);
    if (!await dir.exists()) return record.photoCount ?? 0;
    var n = 0;
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final path = entity.path.toLowerCase();
      if (path.endsWith('.jpg') || path.endsWith('.jpeg')) n++;
    }
    return n;
  }

  /// 「开始训练」为什么点不动 —— 每个 blocked 各说各的。
  /// 绝不合并成一句笼统的"暂时不可用":用户下一步该做什么完全取决于是哪一个。
  static String _trainBlockedReason(TrainGate gate, int photoCount) =>
      switch (gate) {
        TrainGate.ready => '',
        TrainGate.blockedNeedMorePhotos =>
          '要开始训练，必须至少拍摄 $kOfficialMinimumCaptureFrames 张照片。\n'
              '这次拍摄只有 $photoCount 张，还需要 '
              '${photosStillNeededToTrain(photoCount)} 张。\n'
              '请继续拍摄补足。',
        TrainGate.blockedAnotherReconstruction =>
          '另一个项目正在重建中。\n同时只能跑一个，等它完成后再来。',
        TrainGate.blockedNoResumableData => '这次拍摄的重建数据已损坏，照片也不在了，\n无法重建。',
      };

  /// 屏幕正中的 3 秒提示。
  ///
  /// 用 Overlay 而不是 SnackBar:SnackBar 贴底、会被底部 tab bar 压住,而这条
  /// 提示是"你为什么点不动"的回答,必须落在视线中心(用户签决)。
  void _showCenterToast(String message) {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => IgnorePointer(
        child: Center(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 40),
            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 18),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.82),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                height: 1.5,
              ),
            ),
          ),
        ),
      ),
    );
    overlay.insert(entry);
    Timer(const Duration(seconds: 3), () {
      if (entry.mounted) entry.remove();
    });
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
