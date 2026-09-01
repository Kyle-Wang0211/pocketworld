// WorkDetailPage — full-screen viewer for a single community work.
//
// Pushed when the user taps a card in the community feed.
//
// ── 2026-08-16 rewrite: point cloud, not GLB ─────────────────────────
//
// This page used to render through AetherCppCardDemo → SceneBridge →
// the aether_cpp scene renderer, because community works were GLB. The
// official capture route ships a sparse point cloud
// (official_sfm_sparse.ply), and the app already has a mature, shipped
// renderer for exactly that: SparseCloudView — the same widget behind
// the capture-time preview overlay and the drafts "查看点云" page. Using
// it here means a work looks identical whether you are looking at your
// own draft or someone else's published scan, and it inherits the point
// size / AgX / exposure controls and octree LOD that were tuned against
// our own clouds.
//
// We embed the VIEW, not SparseCloudViewerPage: that page carries the
// selection-box editing tools and persists a box to disk beside the PLY,
// which is meaningless (and wrong) for a visitor looking at someone
// else's work.
//
// Load path: modelStoragePath → public URL → GlbCache.fetchPath (two-tier
// URL→disk cache, already PLY-aware) → loadSparsePly in a `compute`
// isolate so parsing 100K+ points never blocks the frame.
//
// The Phase 6.4f.10 first-viewer ThumbBaker hook is gone: PublishService
// now uploads the local `official_sparse_thumb.png` at publish time, so
// a work has its thumbnail from the moment it appears in the feed.

import 'dart:async';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import '../../community/community_service.dart';
import '../../community/feed_models.dart';
import '../../community/glb_cache.dart';
import '../../community/thumb_baker.dart';
import '../../l10n/app_localizations.dart';
import '../design_system.dart';
import 'aether_cpp_card_demo.dart';
import 'viewer_impl.dart' show ViewerQuality, AetherCppViewerImpl;
import '../official_capture/auto_rotating_cloud_view.dart';
import '../official_capture/sparse_cloud_viewer_page.dart'
    show SparseCloudData, loadSparsePly;

/// [mesh] = GLB/mesh,走五月就跑通的 aether_cpp scene renderer(自带自转 +
/// bounds 驱动取景),它自己从 URL 加载,不经 loadSparsePly。
/// [ready] = 稀疏点云,走 SparseCloudView。
enum _CloudStatus { loading, ready, mesh, unsupported, failed }

class WorkDetailPage extends StatefulWidget {
  final FeedWork work;
  final CommunityService service;

  const WorkDetailPage({super.key, required this.work, required this.service});

  @override
  State<WorkDetailPage> createState() => _WorkDetailPageState();
}

class _WorkDetailPageState extends State<WorkDetailPage> {
  late int _viewsCount = widget.work.viewsCount;

  /// Report / block only make sense on someone else's work.
  bool get _isMine => widget.service.currentUserId == widget.work.userId;

  void _showMoreActions() {
    final l = AppL10n.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AetherColors.bgCanvas,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AetherRadii.xl),
        ),
      ),
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isMine)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded,
                    color: AetherColors.danger),
                title: Text(
                  l.workDeleteAction,
                  style: AetherTextStyles.body
                      .copyWith(color: AetherColors.danger),
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _confirmDelete();
                },
              )
            else ...[
              ListTile(
                leading: const Icon(Icons.flag_outlined,
                    color: AetherColors.textPrimary),
                title: Text(l.reportAction, style: AetherTextStyles.body),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _showReportSheet();
                },
              ),
              ListTile(
                leading:
                    const Icon(Icons.block_rounded, color: AetherColors.danger),
                title: Text(
                  l.blockAction,
                  style: AetherTextStyles.body
                      .copyWith(color: AetherColors.danger),
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _confirmBlock();
                },
              ),
            ],
            const SizedBox(height: AetherSpacing.sm),
          ],
        ),
      ),
    );
  }

  Future<void> _showReportSheet() async {
    final submitted = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: AetherColors.bgCanvas,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AetherRadii.xl),
        ),
      ),
      builder: (_) => _ReportSheet(
        service: widget.service,
        workId: widget.work.id,
      ),
    );
    if (submitted == true && mounted) {
      final l = AppL10n.of(context);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l.reportSubmitted)));
    }
  }

  /// "Immediately remove posts from the feed" — the extra requirement
  /// Apple adds to Guideline 1.2 for UGC apps. Deletes the row AND the
  /// storage objects server-side; deleting only the row would leave the
  /// file publicly downloadable (public bucket ⇒ RLS bypassed).
  Future<void> _confirmDelete() async {
    final l = AppL10n.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AetherColors.bgCanvas,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AetherRadii.lg),
        ),
        title: Text(l.workDeleteDialogTitle, style: AetherTextStyles.h2),
        content: Text(l.workDeleteDialogBody, style: AetherTextStyles.body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AetherColors.danger),
            child: Text(
              l.workDeleteConfirm,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.service.deleteMyWork(widget.work.id);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l.workDeleteDone)));
      // The work no longer exists; leave the page. The feed refetches on
      // its next load, and pull-to-refresh is right there.
      Navigator.of(context).maybePop();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l.workDeleteFailed)));
    }
  }

  Future<void> _confirmBlock() async {
    final l = AppL10n.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: AetherColors.bgCanvas,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AetherRadii.lg),
        ),
        title: Text(l.blockDialogTitle, style: AetherTextStyles.h2),
        content: Text(l.blockDialogBody, style: AetherTextStyles.body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AetherColors.danger),
            child: Text(
              l.blockConfirm,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await widget.service.blockUser(widget.work.userId);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l.blockDone)));
      // Leave the page: its author is now blocked, so keeping their work
      // on screen would contradict the action just taken. The feed
      // re-filters on its next load.
      Navigator.of(context).maybePop();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l.blockFailed)));
    }
  }

  /// 首访烘缩略图。[2026-08-17 用户签决"恢复 ThumbBaker,给那 3 个老作品补"]
  ///
  /// 这条链此前被删过,理由是"PublishService 发布时就上传缩略图"—— 但那只
  /// 覆盖**新发布**的作品。库里 6 个作品有 3 个(Toy Car / Damaged Helmet /
  /// scan 2026-05-04)是发布链上线前的老数据,永远等不到缩略图,不是焦点卡
  /// 时就只能显示灰渐变。
  ///
  /// 门槛在 ThumbBaker 内部:已有缩略图 / 本进程烘过 / 正在烘 / 未登录 /
  /// 不是作者(RLS 只让作者写)—— 任一命中都安静跳过。
  late final ThumbBaker _thumbBaker = ThumbBaker(service: widget.service);

  _CloudStatus _status = _CloudStatus.loading;
  SparseCloudData? _cloud;

  @override
  void initState() {
    super.initState();
    // Record a view as soon as the page mounts. The hour-bucket dedup
    // makes this safe to call unconditionally.
    unawaited(_recordView());
    unawaited(_loadCloud());
  }

  Future<void> _recordView() async {
    final updated = await widget.service.recordView(widget.work.id);
    if (!mounted || updated == null) return;
    if (updated != _viewsCount) setState(() => _viewsCount = updated);
  }

  Future<void> _loadCloud() async {
    final storagePath = widget.work.modelStoragePath;
    if (storagePath == null || storagePath.isEmpty) {
      if (mounted) setState(() => _status = _CloudStatus.failed);
      return;
    }
    // ── 格式分派 ────────────────────────────────────────────────────
    //
    // [2026-08-17 用户指认] "稀疏点云只是我的管线还没搭建完,最终产物就是
    // mesh" —— 所以 mesh 不是要淘汰的遗留格式,是**终态**。GLB 走
    // AetherCppCardDemo(五月写好、Phase 6.4b 已 SHIPPED 的 aether_cpp scene
    // renderer:isFocused 驱自转、bounds 驱取景、首帧淡入),点云走
    // SparseCloudView 这条过渡期的路。
    //
    // 此前这里对一切非 ply 直接判 unsupported,于是社区里现存的 mesh 作品全
    // 部只能看到"格式不支持"—— 而它们本来就是这条链天生要渲的东西。
    final format = widget.work.format.toLowerCase();
    if (format == 'glb' || format == 'gltf') {
      if (mounted) setState(() => _status = _CloudStatus.mesh);
      return;
    }
    if (format != 'ply') {
      if (mounted) setState(() => _status = _CloudStatus.unsupported);
      return;
    }
    try {
      final url = widget.service.modelUrlFor(storagePath);
      final localPath = await GlbCache.instance.fetchPath(url);
      final cloud = await compute(loadSparsePly, localPath);
      if (!mounted) return;
      setState(() {
        if (cloud == null || cloud.count == 0) {
          _status = _CloudStatus.failed;
        } else {
          _cloud = cloud;
          _status = _CloudStatus.ready;
        }
      });
    } catch (e) {
      debugPrint('[WorkDetailPage] cloud load failed: $e');
      if (mounted) setState(() => _status = _CloudStatus.failed);
    }
  }

  /// AetherCppCardDemo 的底层 viewer 把第一帧画进 IOSurface 后回调这里,
  /// 交给 ThumbBaker 去判门槛。
  void _onViewerReady(AetherCppViewerImpl viewer) {
    unawaited(_thumbBaker.maybeBake(work: widget.work, viewer: viewer));
  }

  Widget _buildBody() {
    final l = AppL10n.of(context);
    switch (_status) {
      case _CloudStatus.loading:
        return const Center(
          child: SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
          ),
        );
      case _CloudStatus.ready:
        final cloud = _cloud!;
        return AutoRotatingCloudView(
          xyz: cloud.xyz,
          rgb: cloud.rgb,
          // Visitors get the same look/feel controls as the drafts
          // viewer, but no editing affordances — `editing` stays false
          // and no selectionBox is threaded in, so nothing is ever
          // written back beside someone else's PLY.
          showControls: true,
          logTag: '社区详情',
        );
      case _CloudStatus.mesh:
        // 详情页 = 自转 + 可手势 + 全质量,三样都要。
        //
        // 五月这一页走的是 LiveModelView(thermion),因为当时
        // AetherCppCardDemo 还没落地 orbit 手势(它头注释里的 G5)。手势现在
        // 有了(interactive:true = 单指 orbit / 双指 pinch),但它和自转本来
        // 是被同一个开关绑死的 —— autoRotateUntilTouched 把这层绑定解开:
        // 打开就转,用户一上手就永久让位给手势。
        return AetherCppCardDemo(
          key: ValueKey('work-mesh-${widget.work.id}'),
          modelUrl: widget.service.modelUrlFor(widget.work.modelStoragePath!),
          isFocused: true,
          interactive: true,
          autoRotateUntilTouched: true,
          // 契约 kViewerSocialPolicyContract.detailQuality = 'full'。
          // interactive 模式本来就默认 full,这里显式写出来当锚 —— 免得哪天
          // 有人把 interactive 改掉,质量档跟着悄悄掉进 feed 档。
          quality: ViewerQuality.full,
          background: Colors.black,
          onViewerReady: _onViewerReady,
        );
      case _CloudStatus.unsupported:
        return _EmptyState(
          icon: Icons.view_in_ar_rounded,
          message: '${l.communityFormatUnsupported}'
              ' (${widget.work.format.toUpperCase()})',
        );
      case _CloudStatus.failed:
        return _EmptyState(
          icon: Icons.cloud_off_rounded,
          message: l.communityCloudLoadFailed,
          onRetry: () {
            setState(() => _status = _CloudStatus.loading);
            unawaited(_loadCloud());
          },
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    // Black, matching the drafts viewer and the sparse thumbnail — a
    // point cloud reads far better on black than on white.
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.chevron_left_rounded, color: Colors.white),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: [
          // Guideline 1.2 wants a report mechanism AND a way to block
          // abusive users; Apple's UGC rejection letters additionally ask
          // for a way for authors to immediately remove their own posts
          // from the feed. All three tables have existed since April but
          // had no client entry point — and this AppBar had no `actions:`
          // at all, so there was nowhere to put one.
          //
          // The menu contents flip by ownership: reporting or blocking
          // yourself is meaningless, and deleting someone else's work
          // isn't yours to do.
          IconButton(
            icon: const Icon(Icons.more_horiz_rounded, color: Colors.white),
            tooltip: AppL10n.of(context).workMoreActions,
            onPressed: _showMoreActions,
          ),
        ],
        title: Text(
          widget.work.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Colors.white,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(child: _buildBody()),
            _MetaRow(
              viewsCount: _viewsCount,
              likesCount: widget.work.likesCount,
              author: widget.work.authorDisplayName,
              description: widget.work.description,
            ),
          ],
        ),
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  final int viewsCount;
  final int likesCount;
  final String author;
  final String? description;

  const _MetaRow({
    required this.viewsCount,
    required this.likesCount,
    required this.author,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 18),
      decoration: const BoxDecoration(
        color: Colors.black,
        border: Border(top: BorderSide(color: Colors.white12, width: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  author,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              _CountChip(icon: Icons.remove_red_eye_outlined, value: viewsCount),
              const SizedBox(width: 12),
              _CountChip(icon: Icons.favorite_border_rounded, value: likesCount),
            ],
          ),
          if (description != null && description!.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              description!,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, color: Colors.white70),
            ),
          ],
        ],
      ),
    );
  }
}

class _CountChip extends StatelessWidget {
  final IconData icon;
  final int value;
  const _CountChip({required this.icon, required this.value});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: Colors.white54),
        const SizedBox(width: 4),
        Text(
          '$value',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Colors.white54,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  final IconData icon;
  final String message;
  final VoidCallback? onRetry;

  const _EmptyState({required this.icon, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 56, color: Colors.white24),
          const SizedBox(height: AetherSpacing.md),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 13, color: Colors.white54),
          ),
          if (onRetry != null) ...[
            const SizedBox(height: AetherSpacing.md),
            TextButton(
              onPressed: onRetry,
              child: Text(AppL10n.of(context).communityRetry),
            ),
          ],
        ],
      ),
    );
  }
}

/// Report reasons must match the `reports.reason` CHECK constraint in
/// 20260429020005_moderation.sql exactly — a typo here becomes a silent
/// 400 at insert time.
const List<String> _kReportReasons = <String>[
  'spam',
  'harassment',
  'hate_speech',
  'sexual_content',
  'violence',
  'copyright',
  'misinformation',
  'other',
];

/// Bottom sheet implementing Guideline 1.2's "mechanism to report
/// offensive content". Pops `true` once the row is in, so the caller
/// shows the confirmation — the report must never fail silently, or the
/// user will assume it worked and we'll have lost a real complaint.
class _ReportSheet extends StatefulWidget {
  final CommunityService service;
  final String workId;

  const _ReportSheet({required this.service, required this.workId});

  @override
  State<_ReportSheet> createState() => _ReportSheetState();
}

class _ReportSheetState extends State<_ReportSheet> {
  String? _reason;
  final TextEditingController _detail = TextEditingController();
  bool _busy = false;

  @override
  void dispose() {
    _detail.dispose();
    super.dispose();
  }

  String _label(AppL10n l, String reason) => switch (reason) {
        'spam' => l.reportReasonSpam,
        'harassment' => l.reportReasonHarassment,
        'hate_speech' => l.reportReasonHateSpeech,
        'sexual_content' => l.reportReasonSexualContent,
        'violence' => l.reportReasonViolence,
        'copyright' => l.reportReasonCopyright,
        'misinformation' => l.reportReasonMisinformation,
        _ => l.reportReasonOther,
      };

  Future<void> _submit() async {
    final reason = _reason;
    if (reason == null || _busy) return;
    setState(() => _busy = true);
    try {
      await widget.service.reportWork(
        workId: widget.workId,
        reason: reason,
        detail: _detail.text,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = false);
      final l = AppL10n.of(context);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(l.reportFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    // Sheet sits above the keyboard when the detail field has focus.
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(AetherSpacing.lg),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l.reportSheetTitle, style: AetherTextStyles.h2),
                const SizedBox(height: AetherSpacing.xs),
                Text(
                  l.reportSheetSubtitle,
                  style: AetherTextStyles.bodySm
                      .copyWith(color: AetherColors.textSecondary),
                ),
                const SizedBox(height: AetherSpacing.md),
                for (final r in _kReportReasons)
                  InkWell(
                    onTap: _busy ? null : () => setState(() => _reason = r),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        vertical: AetherSpacing.sm,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            _reason == r
                                ? Icons.radio_button_checked_rounded
                                : Icons.radio_button_unchecked_rounded,
                            size: 20,
                            color: _reason == r
                                ? AetherColors.textPrimary
                                : AetherColors.textTertiary,
                          ),
                          const SizedBox(width: AetherSpacing.sm),
                          Expanded(
                            child: Text(_label(l, r),
                                style: AetherTextStyles.body),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: AetherSpacing.sm),
                TextField(
                  controller: _detail,
                  enabled: !_busy,
                  maxLines: 3,
                  // Schema caps detail at 2000 chars; enforce client-side
                  // so a long paste fails visibly here instead of as a
                  // CHECK violation on insert.
                  maxLength: 2000,
                  decoration: InputDecoration(
                    hintText: l.reportDetailHint,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AetherRadii.md),
                    ),
                  ),
                ),
                const SizedBox(height: AetherSpacing.sm),
                SizedBox(
                  height: 48,
                  child: FilledButton(
                    onPressed: (_reason == null || _busy) ? null : _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: AetherColors.danger,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AetherRadii.md),
                      ),
                    ),
                    child: _busy
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : Text(
                            l.reportSubmit,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
