import 'package:flutter/material.dart';

import '../../community/social_profile_models.dart';
import '../../community/social_profile_repository.dart';
import '../../l10n/app_localizations.dart';
import '../design_system.dart';
import 'user_profile_page.dart';

typedef FollowingProfileBuilder = Widget Function(SocialProfile profile);

class FollowingListPage extends StatefulWidget {
  const FollowingListPage({
    super.key,
    required this.userId,
    required this.repository,
    this.profileBuilder,
  });

  final String userId;
  final SocialProfileRepository repository;
  final FollowingProfileBuilder? profileBuilder;

  @override
  State<FollowingListPage> createState() => _FollowingListPageState();
}

class _FollowingListPageState extends State<FollowingListPage> {
  List<SocialProfile>? _profiles;
  Object? _error;
  final Set<String> _inFlight = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final profiles = await widget.repository.fetchFollowing(widget.userId);
      if (!mounted) return;
      setState(() => _profiles = profiles);
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    }
  }

  Future<void> _toggle(SocialProfile profile) async {
    if (!_inFlight.add(profile.id)) return;
    setState(() {});
    try {
      if (profile.isFollowing) {
        await widget.repository.unfollow(profile.id);
      } else {
        await widget.repository.follow(profile.id);
      }
      if (!mounted) return;
      setState(() {
        _profiles = [
          for (final row in _profiles!)
            if (row.id == profile.id)
              row.copyWith(isFollowing: !profile.isFollowing)
            else
              row,
        ];
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppL10n.of(context).socialActionFailed)),
      );
    } finally {
      _inFlight.remove(profile.id);
      if (mounted) setState(() {});
    }
  }

  void _open(SocialProfile profile) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            widget.profileBuilder?.call(profile) ??
            UserProfilePage(userId: profile.id, repository: widget.repository),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Scaffold(
      backgroundColor: AetherColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: AetherColors.bgCanvas,
        surfaceTintColor: Colors.transparent,
        title: Text(l.socialFollowingTitle),
      ),
      body: _buildBody(l),
    );
  }

  Widget _buildBody(AppL10n l) {
    final profiles = _profiles;
    if (profiles == null && _error == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (profiles == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(l.socialFollowingLoadFailed),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: Text(l.communityRetry)),
          ],
        ),
      );
    }
    if (profiles.isEmpty) {
      return Center(
        child: Text(l.socialFollowingEmpty, style: AetherTextStyles.bodySm),
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      color: AetherColors.primary,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: profiles.length,
        separatorBuilder: (_, _) =>
            const Divider(height: 1, indent: 80, color: AetherColors.border),
        itemBuilder: (context, index) {
          final profile = profiles[index];
          return ListTile(
            key: Key('following-row-${profile.id}'),
            onTap: () => _open(profile),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 8,
            ),
            leading: CircleAvatar(
              radius: 24,
              backgroundColor: AetherColors.bgElevated,
              backgroundImage: profile.avatarUrl == null
                  ? null
                  : NetworkImage(profile.avatarUrl!),
              child: profile.avatarUrl == null
                  ? Text(profile.displayName.characters.first)
                  : null,
            ),
            title: Text(profile.displayName, style: AetherTextStyles.h3),
            subtitle: profile.handle == null
                ? null
                : Text('@${profile.handle}', style: AetherTextStyles.bodySm),
            trailing: profile.isFollowing
                ? OutlinedButton(
                    onPressed: _inFlight.contains(profile.id)
                        ? null
                        : () => _toggle(profile),
                    child: Text(l.socialFollowing),
                  )
                : FilledButton(
                    onPressed: _inFlight.contains(profile.id)
                        ? null
                        : () => _toggle(profile),
                    style: FilledButton.styleFrom(
                      backgroundColor: AetherColors.primary,
                      foregroundColor: Colors.white,
                    ),
                    child: Text(l.socialFollow),
                  ),
          );
        },
      ),
    );
  }
}
