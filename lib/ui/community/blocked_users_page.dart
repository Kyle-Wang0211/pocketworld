import 'package:flutter/material.dart';

import '../../community/social_profile_models.dart';
import '../../community/social_profile_repository.dart';
import '../../l10n/app_localizations.dart';
import '../design_system.dart';

class BlockedUsersPage extends StatefulWidget {
  const BlockedUsersPage({super.key, required this.repository});

  final SocialProfileRepository repository;

  @override
  State<BlockedUsersPage> createState() => _BlockedUsersPageState();
}

class _BlockedUsersPageState extends State<BlockedUsersPage> {
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
      final profiles = await widget.repository.fetchBlockedUsers();
      if (!mounted) return;
      setState(() => _profiles = profiles);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _profiles = null;
        _error = error;
      });
    }
  }

  Future<void> _unblock(SocialProfile profile) async {
    final l = AppL10n.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.unblockTitle),
        content: Text(l.unblockBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l.unblockAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !_inFlight.add(profile.id)) return;
    setState(() {});
    try {
      await widget.repository.unblock(profile.id);
      if (!mounted) return;
      setState(() {
        _profiles = [
          for (final row in _profiles!)
            if (row.id != profile.id) row,
        ];
      });
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.unblockFailed)));
    } finally {
      _inFlight.remove(profile.id);
      if (mounted) setState(() {});
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
        title: Text(l.blockedUsersTitle),
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
            Text(l.blockedUsersLoadFailed),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: Text(l.communityRetry)),
          ],
        ),
      );
    }
    if (profiles.isEmpty) {
      return Center(
        child: Text(l.blockedUsersEmpty, style: AetherTextStyles.bodySm),
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
                  ? Text(profile.displayName.characters.firstOrNull ?? '?')
                  : null,
            ),
            title: Text(profile.displayName, style: AetherTextStyles.h3),
            subtitle: profile.handle == null
                ? null
                : Text('@${profile.handle}', style: AetherTextStyles.bodySm),
            trailing: OutlinedButton(
              key: Key('unblock-${profile.id}'),
              onPressed: _inFlight.contains(profile.id)
                  ? null
                  : () => _unblock(profile),
              child: Text(l.unblockAction),
            ),
          );
        },
      ),
    );
  }
}
