// MyWorkDetailPage — full-screen viewer for one of the user's OWN scans,
// plus the publish-to-community workflow.
//
// ── 2026-08-16 ───────────────────────────────────────────────────────
//
// (1) It shows the scan again. The page rendered `record.artifactPath`,
//     which only the GLB-import path ever sets — the official capture
//     route leaves `$captureDir/official_sfm_sparse.ply` and never
//     touches artifactPath, so every real scan fell through to the
//     "processing" placeholder forever. Sparse clouds now render through
//     SparseCloudView, the same widget behind the drafts viewer and the
//     community detail page. Imported GLBs keep the aether_cpp path.
//
// (2) Publish is live again. The bottom sheet was deleted in Plan G W2
//     (2026-05-16) along with the upload chain, leaving a confirm action
//     that only showed a "no cloud" snackbar. It now runs the restored
//     PublishService: sparse PLY → works bucket → public works row →
//     thumbnail, with the local record stamped with `cloudWorkId` on
//     success so the button can't publish the same scan twice.
//
// This page owns the store write; PublishService deliberately never
// touches ScanRecordStore.

import 'dart:async';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import '../../community/community_service.dart';
import '../../community/publish_service.dart';
import '../../l10n/app_localizations.dart';
import '../../me/scan_record_store.dart';
import '../../util/device_log.dart';
import '../community/aether_cpp_card_demo.dart';
import '../design_system.dart';
import '../official_capture/auto_rotating_cloud_view.dart';
import '../official_capture/sparse_cloud_viewer_page.dart'
    show SparseCloudData, loadSparsePly;
import '../scan_record.dart';

class MyWorkDetailPage extends StatefulWidget {
  final String recordId;

  const MyWorkDetailPage({super.key, required this.recordId});

  @override
  State<MyWorkDetailPage> createState() => _MyWorkDetailPageState();
}

class _MyWorkDetailPageState extends State<MyWorkDetailPage> {
  late final ScanRecordStore _store = ScanRecordStore.instance;
  StreamSubscription<List<ScanRecord>>? _sub;
  ScanRecord? _record;

  SparseCloudData? _cloud;
  bool _cloudLoading = false;
  String? _loadedPlyPath;

  bool _publishing = false;
  double _publishFraction = 0;

  /// Server-side moderation state for an already-published work.
  /// null = unknown / not published / lookup failed.
  String? _moderationStatus;

  @override
  void initState() {
    super.initState();
    _record = _store.byId(widget.recordId);
    _sub = _store.changes.listen((_) {
      final fresh = _store.byId(widget.recordId);
      if (mounted && fresh != null) {
        setState(() => _record = fresh);
        unawaited(_maybeLoadCloud());
      }
    });
    unawaited(_maybeLoadCloud());
    unawaited(_refreshModerationStatus());
  }

  /// The local record only knows "I was published once" (`cloudWorkId`).
  /// It cannot know the work was later taken down, so without this the
  /// author sees "已发布" while the work is invisible to everyone else.
  /// Best-effort: failure leaves the plain published state.
  Future<void> _refreshModerationStatus() async {
    final workId = _record?.cloudWorkId;
    if (workId == null) return;
    final status = await CommunityService().fetchMyWorkModerationStatus(workId);
    if (!mounted || status == null) return;
    setState(() => _moderationStatus = status);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  /// Parse the local PLY once per path. Runs in a `compute` isolate —
  /// 100K+ points must never be parsed on the frame thread.
  Future<void> _maybeLoadCloud() async {
    final r = _record;
    if (r == null || _cloudLoading) return;
    final ply = PublishService.sparsePlyFor(r);
    if (ply == null || ply.path == _loadedPlyPath) return;
    setState(() => _cloudLoading = true);
    try {
      final cloud = await compute(loadSparsePly, ply.path);
      if (!mounted) return;
      setState(() {
        _cloud = cloud;
        _loadedPlyPath = ply.path;
      });
    } catch (e) {
      debugPrint('[MyWorkDetailPage] cloud load failed: $e');
    } finally {
      if (mounted) setState(() => _cloudLoading = false);
    }
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _startPublish(ScanRecord r) async {
    // Resolved before the first await — every message below is emitted
    // after one, and reaching back through `context` there is exactly
    // what use_build_context_synchronously guards against.
    final l = AppL10n.of(context);
    final form = await showModalBottomSheet<_PublishFormResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _PublishForm(defaultTitle: r.name),
    );
    if (form == null || !mounted) return;

    setState(() {
      _publishing = true;
      _publishFraction = 0;
    });
    // 发布链全程留痕。[2026-08-17 实机踩到] feed 里迟迟没有 PLY 作品,而这条
    // 链上一行日志都没有 —— "用户没去发布"和"用户发布失败了"在设备日志里
    // 长得一模一样,只能靠反查数据库区分。
    DeviceLog.log('Publish', '开始发布:${r.id} "${form.title}"');
    try {
      final result = await PublishService().publish(
        record: r,
        title: form.title,
        description: form.description,
        onProgress: (p) {
          if (mounted) setState(() => _publishFraction = p.fraction);
        },
      );
      DeviceLog.log('Publish', '✅ 发布成功:workId=${result.workId} '
          '(format=ply,社区 feed 的 live 卡只认它)');
      // Stamp the local record so the button flips to "已发布" and the
      // same scan can't be published twice. PublishService never writes
      // to the store — that is this page's job.
      await _store.addOrUpdate(r.copyWith(cloudWorkId: result.workId));
      _snack(l.publishSuccess);
    } on PublishException catch (e) {
      DeviceLog.log('Publish', '🔴 发布失败(PublishException):$e');
      _snack(_messageFor(l, e));
    } catch (e) {
      DeviceLog.log('Publish', '🔴 发布失败(未预期):$e');
      _snack('${l.publishErrGeneric}: $e');
    } finally {
      if (mounted) setState(() => _publishing = false);
    }
  }

  String _messageFor(AppL10n l, PublishException e) {
    switch (e.message) {
      case 'signed out':
        return l.publishErrSignedOut;
      case 'already published':
        return l.publishErrAlreadyPublished;
    }
    switch (e.phase) {
      case 'reading':
        return '${l.publishErrReading}: ${e.message}';
      case 'rejected':
        return '${l.publishErrRejected}(${e.message})';
      case 'too_large':
        // e.message 形如 "62.4MB / 50MB",附在文案后面,让用户看到具体数字
        // 而不只是"太大了"。
        return '${l.publishErrTooLarge}(${e.message})';
      case 'uploading':
        return l.publishErrUploading;
      case 'inserting':
        return l.publishErrInserting;
    }
    return '${l.publishErrGeneric}: ${e.message}';
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final r = _record;
    if (r == null) {
      return Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(backgroundColor: Colors.white, elevation: 0),
        body: Center(child: Text(l.meDetailRecordNotFound)),
      );
    }
    final hasCloud = _cloud != null;
    // Black behind a point cloud, white behind the legacy GLB viewer —
    // matches the drafts viewer and the community detail page.
    final dark = hasCloud;
    final fg = dark ? Colors.white : AetherColors.textPrimary;

    return Scaffold(
      backgroundColor: dark ? Colors.black : Colors.white,
      appBar: AppBar(
        backgroundColor: dark ? Colors.black : Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: Icon(Icons.chevron_left_rounded, color: fg),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: Text(
          r.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: fg,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                Expanded(child: _buildBody(r)),
                _PublishBar(
                  record: r,
                  canPublish: PublishService.sparsePlyFor(r) != null,
                  busy: _publishing,
                  onPublish: () => _startPublish(r),
                  moderationStatus: _moderationStatus,
                ),
              ],
            ),
            if (_publishing)
              _PublishOverlay(fraction: _publishFraction),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(ScanRecord r) {
    final cloud = _cloud;
    if (cloud != null) {
      return AutoRotatingCloudView(
        xyz: cloud.xyz,
        rgb: cloud.rgb,
        logTag: '我的作品',
      );
    }
    if (_cloudLoading) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    // Legacy path — a GLB brought in through ImportGlbCoordinator, which
    // is the only thing that sets artifactPath.
    final url = r.artifactPath;
    if (url != null) {
      return AetherCppCardDemo(
        key: ValueKey('mywork-aether-${r.id}'),
        modelUrl: url,
        interactive: true,
      );
    }
    return const _RunningState();
  }
}

/// Bottom action bar. Disabled (with a reason) until there is something
/// publishable, and permanently "已发布" once `cloudWorkId` is stamped.
/// Non-actionable bottom bar for a work whose server-side state takes the
/// publish action away (removed / under review). Same footprint as
/// [_PublishBar] so the page layout doesn't shift.
class _StatusBar extends StatelessWidget {
  final String label;
  final String? hint;
  final Color color;

  const _StatusBar({required this.label, required this.hint, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        AetherSpacing.lg,
        AetherSpacing.md,
        AetherSpacing.lg,
        AetherSpacing.lg,
      ),
      color: Colors.black,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 48,
            decoration: BoxDecoration(
              color: Colors.white10,
              borderRadius: BorderRadius.circular(AetherRadii.md),
              border: Border.all(color: color),
            ),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
          if (hint != null) ...[
            const SizedBox(height: AetherSpacing.sm),
            Text(
              hint!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                height: 1.4,
                color: Colors.white70,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _PublishBar extends StatelessWidget {
  final ScanRecord record;
  final bool canPublish;
  final bool busy;
  final VoidCallback onPublish;

  /// Server truth for an already-published work: 'ok' | 'under_review' |
  /// 'removed'. null when unknown — in that case we fall back to the
  /// plain "published" label rather than guessing.
  final String? moderationStatus;

  const _PublishBar({
    required this.record,
    required this.canPublish,
    required this.busy,
    required this.onPublish,
    this.moderationStatus,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final published = record.cloudWorkId != null;

    // A removed work must say so. Showing "已发布" while the work is
    // invisible to everyone else is the confusing state this fixes, and
    // the hint line tells the author how to appeal — which is also what
    // DSA Art.17 expects a takedown notice to carry.
    if (published && moderationStatus == 'removed') {
      return _StatusBar(
        label: l.publishModerationRemoved,
        hint: l.publishModerationRemovedHint,
        color: AetherColors.danger,
      );
    }
    if (published && moderationStatus == 'under_review') {
      return _StatusBar(
        label: l.publishModerationUnderReview,
        hint: null,
        color: AetherColors.textSecondary,
      );
    }

    final String label;
    final VoidCallback? action;
    if (published) {
      label = l.publishAlreadyDone;
      action = null;
    } else if (!canPublish) {
      label = l.publishNotReady;
      action = null;
    } else {
      label = l.publishAction;
      action = busy ? null : onPublish;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(
        AetherSpacing.lg,
        AetherSpacing.md,
        AetherSpacing.lg,
        AetherSpacing.lg,
      ),
      color: Colors.black,
      child: SizedBox(
        height: 48,
        child: FilledButton(
          onPressed: action,
          style: FilledButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: Colors.black,
            disabledBackgroundColor: Colors.white24,
            disabledForegroundColor: Colors.white54,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AetherRadii.md),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                published
                    ? Icons.check_circle_rounded
                    : Icons.ios_share_rounded,
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PublishFormResult {
  final String title;
  final String? description;
  const _PublishFormResult(this.title, this.description);
}

/// Title + description sheet. Mirrors the DB CHECK constraints
/// (title 1..100, description ≤5000) so a bad payload is stopped here
/// rather than after burning an upload.
class _PublishForm extends StatefulWidget {
  final String defaultTitle;
  const _PublishForm({required this.defaultTitle});

  @override
  State<_PublishForm> createState() => _PublishFormState();
}

class _PublishFormState extends State<_PublishForm> {
  late final TextEditingController _title = TextEditingController(
    text: widget.defaultTitle,
  );
  final TextEditingController _desc = TextEditingController();

  @override
  void dispose() {
    _title.dispose();
    _desc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
    final titleOk = _title.text.trim().isNotEmpty;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        padding: const EdgeInsets.fromLTRB(
          AetherSpacing.lg,
          AetherSpacing.md,
          AetherSpacing.lg,
          AetherSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AetherColors.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: AetherSpacing.lg),
            Text(
              l.publishAction,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AetherColors.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              l.publishSheetSubtitle,
              style: const TextStyle(
                fontSize: 13,
                color: AetherColors.textSecondary,
              ),
            ),
            const SizedBox(height: AetherSpacing.lg),
            TextField(
              controller: _title,
              maxLength: 100,
              autofocus: true,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                labelText: l.publishFieldTitle,
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AetherSpacing.sm),
            TextField(
              controller: _desc,
              maxLength: 5000,
              maxLines: 3,
              minLines: 2,
              decoration: InputDecoration(
                labelText: l.publishFieldDescription,
                border: const OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: AetherSpacing.md),
            SizedBox(
              width: double.infinity,
              height: 46,
              child: FilledButton(
                onPressed: titleOk
                    ? () => Navigator.of(context).pop(
                        _PublishFormResult(
                          _title.text.trim(),
                          _desc.text.trim().isEmpty ? null : _desc.text.trim(),
                        ),
                      )
                    : null,
                child: Text(l.publishConfirm),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Modal progress. Blocks interaction so the record cannot change under
/// an in-flight publish.
class _PublishOverlay extends StatelessWidget {
  final double fraction;
  const _PublishOverlay({required this.fraction});


  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black54,
        child: Center(
          child: Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(AetherRadii.lg),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 120,
                  child: LinearProgressIndicator(
                    value: fraction <= 0 ? null : fraction,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '${AppL10n.of(context).publishInProgress} '
                  '${(fraction * 100).clamp(0, 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                    fontSize: 13,
                    color: AetherColors.textSecondary,
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

class _RunningState extends StatelessWidget {
  const _RunningState();

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 26,
            height: 26,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(height: AetherSpacing.md),
          Text(l.meDetailRunningProcessing, style: AetherTextStyles.bodySm),
        ],
      ),
    );
  }
}
