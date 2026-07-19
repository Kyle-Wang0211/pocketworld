// MeSettingsPage — pushed from MePage's gear icon. Holds the secondary
// account chrome (notifications, privacy, language, about, sign-out)
// that we don't want crowding the home Me tab.
//
// Notification / privacy trailing values come from MeStatsViewModel,
// which loads from public.notification_settings and public.profiles.

import 'package:flutter/material.dart';

import '../auth/auth_models.dart';
import '../auth/auth_scope.dart';
import '../i18n/locale_notifier.dart';
import '../l10n/app_localizations.dart';
import 'design_system.dart';
import 'me_stats_view_model.dart';

class MeSettingsPage extends StatelessWidget {
  final MeStatsViewModel stats;

  const MeSettingsPage({super.key, required this.stats});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    // Subscribe to AuthScope so the Display Name row re-renders when
    // CurrentUser.updateDisplayName() fires notifyListeners after a
    // successful update. AuthScope extends InheritedNotifier so this
    // .of() call participates in the standard inherited-widget rebuild
    // dance — no manual AnimatedBuilder needed.
    final currentUser = AuthScope.of(context);
    final user = currentUser.signedInUser;
    return Scaffold(
      backgroundColor: AetherColors.bg,
      appBar: AppBar(
        backgroundColor: AetherColors.bg,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        iconTheme: const IconThemeData(color: AetherColors.textPrimary),
        title: Text(l.meSettingsTitle, style: AetherTextStyles.h2),
      ),
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AetherSpacing.lg,
            AetherSpacing.md,
            AetherSpacing.lg,
            140,
          ),
          children: [
            AnimatedBuilder(
              animation: stats,
              builder: (_, _) => _SettingsSection(stats: stats, user: user),
            ),
            const SizedBox(height: AetherSpacing.xl),
            const _SignOutButton(),
          ],
        ),
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  final MeStatsViewModel stats;
  final AuthenticatedUser? user;

  const _SettingsSection({required this.stats, required this.user});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final localeNotifier = LocaleScope.of(context);
    final isZh = localeNotifier.isChinese;
    final notifEnabled = stats.notificationsEnabled;
    final notificationsTrailing = notifEnabled == null
        ? l.meSettingNotConfigured
        : (notifEnabled ? l.meNotificationsOn : l.meNotificationsOff);
    final isPrivate = stats.isPrivate;
    final privacyTrailing = isPrivate == null
        ? l.meSettingNotConfigured
        : (isPrivate ? l.mePrivacyPrivate : l.mePrivacyPublic);
    final rows = <_SettingsRowSpec>[
      _SettingsRowSpec(
        icon: Icons.person_outline_rounded,
        title: l.meDisplayName,
        trailing: _displayNameTrailing(user),
        onTap: () => _showDisplayNameDialog(context, user),
      ),
      _SettingsRowSpec(
        icon: Icons.notifications_none_rounded,
        title: l.meNotifications,
        trailing: notificationsTrailing,
        onTap: null,
      ),
      _SettingsRowSpec(
        icon: Icons.lock_outline_rounded,
        title: l.mePrivacy,
        trailing: privacyTrailing,
        onTap: null,
      ),
      _SettingsRowSpec(
        icon: Icons.language_rounded,
        title: l.meLanguage,
        trailing: isZh ? l.meLanguageZh : l.meLanguageEn,
        onTap: () => _showLanguageDialog(context, localeNotifier),
      ),
      _SettingsRowSpec(
        icon: Icons.info_outline_rounded,
        title: l.meAbout,
        trailing: 'v6.4e · Phase 6',
        onTap: null,
      ),
    ];
    return Container(
      decoration: BoxDecoration(
        color: AetherColors.bgCanvas,
        borderRadius: BorderRadius.circular(AetherRadii.xl),
        border: Border.all(color: AetherColors.border),
      ),
      child: Column(
        children: [
          for (int i = 0; i < rows.length; i++) ...[
            _SettingsRow(spec: rows[i]),
            if (i < rows.length - 1)
              const Padding(
                padding: EdgeInsets.only(left: AetherSpacing.lg + 32),
                child: Divider(height: 1, color: AetherColors.border),
              ),
          ],
        ],
      ),
    );
  }

  static Future<void> _showLanguageDialog(
    BuildContext context,
    LocaleNotifier notifier,
  ) async {
    final l = AppL10n.of(context);
    final selected = await showDialog<_LangChoice>(
      context: context,
      builder: (ctx) {
        final current = notifier.isChinese ? _LangChoice.zh : _LangChoice.en;
        return AlertDialog(
          backgroundColor: AetherColors.bgCanvas,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AetherRadii.lg),
          ),
          title: Text(l.languageDialogTitle, style: AetherTextStyles.h2),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final choice in _LangChoice.values)
                RadioListTile<_LangChoice>(
                  title: Text(_choiceLabel(choice, l)),
                  value: choice,
                  groupValue: current,
                  onChanged: (v) => Navigator.of(ctx).pop(v),
                  activeColor: AetherColors.primary,
                  contentPadding: EdgeInsets.zero,
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(l.commonCancel),
            ),
          ],
        );
      },
    );
    if (selected == null) return;
    switch (selected) {
      case _LangChoice.zh:
        await notifier.set(const Locale('zh'));
      case _LangChoice.en:
        await notifier.set(const Locale('en'));
    }
  }

  static String _choiceLabel(_LangChoice c, AppL10n l) {
    switch (c) {
      case _LangChoice.zh:
        return l.languageDialogChinese;
      case _LangChoice.en:
        return l.languageDialogEnglish;
    }
  }

  /// Trailing text for the "Display Name" row.
  /// Falls back through displayName → email local-part → phone → "—"
  /// so the row never shows an empty trailing.
  static String _displayNameTrailing(AuthenticatedUser? user) {
    final n = user?.displayName?.trim();
    if (n != null && n.isNotEmpty) return n;
    final email = user?.email;
    if (email != null && email.contains('@')) {
      final local = email.split('@').first.trim();
      if (local.isNotEmpty) return local;
    }
    final phone = user?.phone;
    if (phone != null && phone.isNotEmpty) return phone;
    return '—';
  }

  /// Dialog: edit the display name. Persists via CurrentUser →
  /// AuthService.updateDisplayName → Supabase user_metadata. On success,
  /// CurrentUser fires notifyListeners and this page rebuilds with the
  /// new value (via AuthScope inheritance in MeSettingsPage.build).
  static Future<void> _showDisplayNameDialog(
    BuildContext context,
    AuthenticatedUser? user,
  ) async {
    final l = AppL10n.of(context);
    final currentUser = AuthScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final currentName = user?.displayName?.trim() ?? '';
    final controller = TextEditingController(text: currentName);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AetherColors.bgCanvas,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AetherRadii.lg),
        ),
        title: Text(l.meDisplayNameDialogTitle, style: AetherTextStyles.h2),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          decoration: InputDecoration(
            hintText: l.meDisplayNameDialogHint,
            border: const OutlineInputBorder(),
            counterText: '',
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: Text(l.meActionSave),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty || newName == currentName) return;
    final ok = await currentUser.updateDisplayName(newName);
    if (ok) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.meDisplayNameUpdated),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      final err = currentUser.lastError?.message ?? 'error';
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.meDisplayNameUpdateFailed(err)),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }
}

enum _LangChoice { zh, en }

class _SettingsRowSpec {
  final IconData icon;
  final String title;
  final String trailing;
  final VoidCallback? onTap;

  const _SettingsRowSpec({
    required this.icon,
    required this.title,
    required this.trailing,
    required this.onTap,
  });
}

class _SettingsRow extends StatelessWidget {
  final _SettingsRowSpec spec;

  const _SettingsRow({required this.spec});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: spec.onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AetherSpacing.lg,
          vertical: AetherSpacing.md + 2,
        ),
        child: Row(
          children: [
            Icon(spec.icon, size: 20, color: AetherColors.textPrimary),
            const SizedBox(width: AetherSpacing.md),
            Expanded(child: Text(spec.title, style: AetherTextStyles.body)),
            Text(spec.trailing, style: AetherTextStyles.caption),
            const SizedBox(width: AetherSpacing.xs),
            const Icon(
              Icons.chevron_right_rounded,
              color: AetherColors.textTertiary,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}

class _SignOutButton extends StatelessWidget {
  const _SignOutButton();

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return GestureDetector(
      onTap: () async {
        final currentUser = AuthScope.read(context);
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            backgroundColor: AetherColors.bgCanvas,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AetherRadii.lg),
            ),
            title: Text(l.meSignOut, style: AetherTextStyles.h2),
            content: const SizedBox.shrink(),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(l.commonCancel),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: TextButton.styleFrom(
                  foregroundColor: AetherColors.danger,
                ),
                child: Text(
                  l.commonOk,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          // ignore: avoid_print
          print('[SignOut] confirmed → calling signOut()');
          try {
            await currentUser.signOut();
            // ignore: avoid_print
            print('[SignOut] signOut() returned');
          } catch (e) {
            // ignore: avoid_print
            print('[SignOut] signOut() threw: $e');
          }
          // signOut() flips CurrentUser → SignedOut, which makes
          // _AuthGate swap the root body from HomeScreen to
          // AuthRootView. But this settings page was Navigator.push'd
          // on top of HomeScreen, and Navigator routes survive
          // root-body swaps — so the user just sees the settings page
          // sitting over a now-stale stack with the login page hidden
          // underneath. Pop everything we pushed back to the root
          // route so the swapped-in AuthRootView becomes visible.
          // `rootNavigator: true` ensures we hit the MaterialApp's
          // Navigator (where MeSettingsPage was pushed), not any
          // accidentally-nested one.
          if (!context.mounted) {
            // ignore: avoid_print
            print('[SignOut] context unmounted, cannot popUntil');
            return;
          }
          // ignore: avoid_print
          print('[SignOut] popping until first route');
          Navigator.of(
            context,
            rootNavigator: true,
          ).popUntil((route) => route.isFirst);
        }
      },
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: AetherColors.bgCanvas,
          borderRadius: BorderRadius.circular(AetherRadii.lg),
          border: Border.all(color: AetherColors.danger),
        ),
        alignment: Alignment.center,
        child: Text(
          l.meSignOut,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AetherColors.danger,
          ),
        ),
      ),
    );
  }
}
