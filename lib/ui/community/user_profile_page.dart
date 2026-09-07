import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../community/community_service.dart';
import '../../community/feed_models.dart';
import '../../community/social_profile_models.dart';
import '../../community/social_profile_repository.dart';
import '../../l10n/app_localizations.dart';
import '../design_system.dart';
import 'profile_work_grid.dart';
import 'user_report_page.dart';

typedef ProfileWorksLoader = Future<List<FeedWork>> Function(String userId);

enum _ProfileAction { report, block }

class UserProfilePage extends StatefulWidget {
  final String userId;
  final FeedWork? seedWork;
  final SocialProfileRepository? repository;
  final CommunityService? communityService;
  final ProfileWorksLoader? worksLoader;
  final VoidCallback? onReportRequested;

  const UserProfilePage({
    super.key,
    required this.userId,
    this.seedWork,
    this.repository,
    this.communityService,
    this.worksLoader,
    this.onReportRequested,
  });

  @override
  State<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends State<UserProfilePage> {
  late final SocialProfileRepository _repository;
  CommunityService? _communityService;
  late final ProfileWorksLoader _worksLoader;

  SocialProfile? _profile;
  List<FeedWork> _works = const [];
  Object? _loadError;
  bool _relationshipInFlight = false;

  bool get _isMine => _repository.currentUserId == widget.userId;

  @override
  void initState() {
    super.initState();
    final needsClient = widget.repository == null || widget.worksLoader == null;
    final client = needsClient ? Supabase.instance.client : null;
    _repository =
        widget.repository ?? SupabaseSocialProfileRepository(client: client!);
    _communityService =
        widget.communityService ??
        (widget.worksLoader == null ? CommunityService(client: client) : null);
    _worksLoader =
        widget.worksLoader ??
        (userId) => _communityService!.fetchPublicFeed(
          authorUserId: userId,
          limit: 100,
        );
    _load();
  }

  Future<void> _load() async {
    setState(() => _loadError = null);
    try {
      final results = await Future.wait<Object>([
        _repository.fetchProfile(widget.userId),
        _worksLoader(widget.userId),
      ]);
      if (!mounted) return;
      setState(() {
        _profile = results[0] as SocialProfile;
        _works = results[1] as List<FeedWork>;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loadError = error);
    }
  }

  Future<void> _toggleFollow() async {
    final profile = _profile;
    if (profile == null || _relationshipInFlight) return;
    setState(() => _relationshipInFlight = true);
    try {
      if (profile.isFollowing) {
        await _repository.unfollow(profile.id);
      } else {
        await _repository.follow(profile.id);
      }
      if (!mounted) return;
      setState(() {
        _profile = profile.copyWith(
          isFollowing: !profile.isFollowing,
          followersCount:
              (profile.followersCount + (profile.isFollowing ? -1 : 1)).clamp(
                0,
                1 << 31,
              ),
        );
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).socialActionFailed)),
      );
    } finally {
      if (mounted) setState(() => _relationshipInFlight = false);
    }
  }

  Future<void> _handleAction(_ProfileAction action) async {
    switch (action) {
      case _ProfileAction.report:
        final callback = widget.onReportRequested;
        if (callback != null) {
          callback();
        } else {
          final result = await Navigator.of(context).push<UserReportResult>(
            MaterialPageRoute<UserReportResult>(
              builder: (_) => UserReportPage(
                targetUserId: widget.userId,
                sourceWorkId: widget.seedWork?.id,
                repository: _repository,
              ),
            ),
          );
          if (!mounted || result == null) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                result.failedEvidenceCount == 0
                    ? AppL10n.of(context).reportUserSubmitted
                    : AppL10n.of(context).reportSubmittedPartial,
              ),
            ),
          );
        }
      case _ProfileAction.block:
        await _confirmBlock();
    }
  }

  Future<void> _confirmBlock() async {
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.profileBlockTitle),
        content: Text(l.profileBlockBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: TextButton.styleFrom(foregroundColor: AetherColors.danger),
            child: Text(l.profileBlockConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await _repository.block(widget.userId);
      if (!mounted) return;
      Navigator.of(context).maybePop();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.profileBlockFailed)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      backgroundColor: AetherColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: AetherColors.bgCanvas,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        title: null,
        leading: IconButton(
          tooltip: l.profileBack,
          onPressed: () => Navigator.of(context).maybePop(),
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 22),
        ),
        actions: [
          if (!_isMine)
            PopupMenuButton<_ProfileAction>(
              key: const Key('profile-overflow'),
              tooltip: l.profileMore,
              position: PopupMenuPosition.under,
              offset: const Offset(0, 4),
              constraints: const BoxConstraints(minWidth: 156),
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.more_horiz, size: 20),
              onSelected: _handleAction,
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: _ProfileAction.report,
                  child: Text(l.profileReportUser),
                ),
                PopupMenuItem(
                  value: _ProfileAction.block,
                  child: Text(
                    l.profileBlockUser,
                    style: const TextStyle(color: AetherColors.danger),
                  ),
                ),
              ],
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _buildBody(l),
    );
  }

  Widget _buildBody(AppL10n l) {
    final profile = _profile;
    if (profile == null && _loadError == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (profile == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.profileLoadFailed),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: Text(l.communityRetry)),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: _load,
      color: AetherColors.primary,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    _ProfileAvatar(profile: profile),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(profile.displayName, style: AetherTextStyles.h1),
                          const SizedBox(height: 8),
                          Text(
                            _identityLine(profile),
                            style: AetherTextStyles.bodySm,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                if (profile.bio != null) ...[
                  const SizedBox(height: 24),
                  Text(profile.bio!, style: AetherTextStyles.body),
                ],
                if (!_isMine) ...[
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: profile.isFollowing
                        ? OutlinedButton(
                            key: const Key('profile-follow-button'),
                            onPressed: _relationshipInFlight
                                ? null
                                : _toggleFollow,
                            child: Text(l.socialFollowing),
                          )
                        : FilledButton(
                            key: const Key('profile-follow-button'),
                            onPressed: _relationshipInFlight
                                ? null
                                : _toggleFollow,
                            style: FilledButton.styleFrom(
                              backgroundColor: AetherColors.primary,
                              foregroundColor: Colors.white,
                            ),
                            child: Text(l.socialFollow),
                          ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1, color: AetherColors.border),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 20),
            child: Row(
              children: [
                _ProfileCount(
                  value: profile.publicWorksCount,
                  label: l.socialWorks,
                ),
                _ProfileCount(
                  value: profile.followersCount,
                  label: l.socialFollowers,
                ),
                _ProfileCount(
                  value: profile.followingCount,
                  label: l.socialFollow,
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AetherColors.border),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 100),
            child: ProfileWorkGrid(works: _works, service: _communityService),
          ),
        ],
      ),
    );
  }

  String _identityLine(SocialProfile profile) {
    final parts = <String>[
      if (profile.handle != null) '@${profile.handle}',
      if (profile.lastRegion != null) profile.lastRegion!,
    ];
    return parts.join(' · ');
  }
}

class _ProfileAvatar extends StatelessWidget {
  const _ProfileAvatar({required this.profile});

  final SocialProfile profile;

  @override
  Widget build(BuildContext context) {
    final avatarUrl = profile.avatarUrl;
    return CircleAvatar(
      radius: 48,
      backgroundColor: AetherColors.bgElevated,
      backgroundImage: avatarUrl == null ? null : NetworkImage(avatarUrl),
      child: avatarUrl == null
          ? Text(
              profile.displayName.characters.first,
              style: AetherTextStyles.h1,
            )
          : null,
    );
  }
}

class _ProfileCount extends StatelessWidget {
  const _ProfileCount({required this.value, required this.label});

  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text('$value', style: AetherTextStyles.h2),
          const SizedBox(height: 8),
          Text(label, style: AetherTextStyles.bodySm),
        ],
      ),
    );
  }
}
