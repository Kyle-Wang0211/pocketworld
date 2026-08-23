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
import 'legal/platform_rules_page.dart';

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
            const SizedBox(height: AetherSpacing.md),
            const _DeleteAccountButton(),
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
        icon: Icons.alternate_email_rounded,
        title: l.meHandle,
        trailing: stats.handle ?? l.meHandleNotSet,
        onTap: () => _showHandleDialog(context, stats),
      ),
      // [IP-REGION 2026-08-24]《互联网用户账号信息管理规定》第十二条:
      // "应当在互联网用户账号信息页面展示……IP 地址归属地信息"。
      // 这一行**不可点、不可改** —— 属地是服务端事实,不是用户偏好。
      // 未解析出时显示占位而非隐藏:法条要求"应当展示",藏起来会让人
      // 以为我们没做。(作品卡片上则相反,少一行小字不会有这个误解。)
      _SettingsRowSpec(
        icon: Icons.location_on_outlined,
        title: l.meIpRegion,
        trailing: stats.lastRegion ?? l.meIpRegionUnknown,
        onTap: null,
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
      // [RULES-PUBLIC 2026-08-23] 网信办令第10号第六条与《深度合成规定》第八条
      // 都要求"制定**和公开**"管理规则与平台公约。此前只有注册页一句不可点的
      // 纯文本,没有任何页面承载内容 —— 那不构成"公开"。
      _SettingsRowSpec(
        icon: Icons.gavel_rounded,
        title: l.mePlatformRules,
        trailing: '',
        onTap: () => PlatformRulesPage.open(context),
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

  /// Dialog: 设置唯一 handle。
  ///
  /// 与昵称对话框的三点不同,每一点都有来由:
  ///   · maxLength 32 —— Discord 口径;昵称是 20 个**字素簇**(在服务端按
  ///     UAX #29 判),这里是 32 个 ASCII 字符,两条规则本来就不同源。
  ///   · 多一条说明(meHandleDialogNote)—— handle 唯一且有 3 天冷却,
  ///     不先说清楚,用户会在提交后才发现改不回来。
  ///   · 成功后调 stats.refresh() —— handle 不在 AuthenticatedUser 上
  ///     (它存 public.profiles,不是 auth metadata),所以 CurrentUser 的
  ///     notifyListeners 刷不出新值,必须显式回读。
  ///
  /// 客户端**不做**唯一性预检:那需要一个查询接口,既多一个限流面和 handle
  /// 枚举面,又躲不开 TOCTOU(查完到提交之间别人可能抢注)。唯一性由
  /// uq_profiles_handle_key 索引裁决,冲突以 409 handle_taken 回来。
  static Future<void> _showHandleDialog(
    BuildContext context,
    MeStatsViewModel stats,
  ) async {
    final l = AppL10n.of(context);
    final currentUser = AuthScope.read(context);
    final messenger = ScaffoldMessenger.of(context);
    final current = stats.handle ?? '';
    final controller = TextEditingController(text: current);
    final next = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AetherColors.bgCanvas,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AetherRadii.lg),
        ),
        title: Text(l.meHandleDialogTitle, style: AetherTextStyles.h2),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              maxLength: 32,
              autocorrect: false,
              enableSuggestions: false,
              textCapitalization: TextCapitalization.none,
              decoration: InputDecoration(
                hintText: l.meHandleDialogHint,
                border: const OutlineInputBorder(),
                counterText: '',
              ),
              onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
            ),
            const SizedBox(height: AetherSpacing.sm),
            Text(
              l.meHandleDialogNote,
              style: const TextStyle(
                fontSize: 12,
                color: AetherColors.textSecondary,
              ),
            ),
          ],
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
    if (next == null || next.isEmpty || next == current) return;
    final ok = await currentUser.updateHandle(next);
    if (ok) {
      await stats.refresh();
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.meHandleUpdated),
          behavior: SnackBarBehavior.floating,
        ),
      );
    } else {
      final err = currentUser.lastError?.message ?? 'error';
      messenger.showSnackBar(
        SnackBar(
          content: Text(l.meHandleUpdateFailed(err)),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
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
          // 20 = 服务端 DISPLAY_NAME_MAX_GRAPHEMES。⚠️ 口径不同:这里数的是
          // UTF-16 code unit,服务端数的是**字素簇**。一个 ZWJ emoji 在这里
          // 算 8、在服务端算 1 ⇒ 客户端更严。这是有意的保守方向:客户端拦下
          // 的一定会被服务端接受,反过来则会出现"输得下却被拒"。
          maxLength: 20,
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

/// App Store Guideline 5.1.1(v): an app that supports account creation
/// "must also offer account deletion within the app". Apple is explicit
/// that a deactivate-only flow does not satisfy this, and that apps
/// outside highly-regulated industries must not make people "make a phone
/// call, send an email, or go through other support flows" — so the
/// contact address on this same page does NOT cover this requirement.
/// That is why this is a real in-app button, not a mailto link.
///
/// Styled a step heavier than sign-out (filled, not outlined) because it
/// is irreversible: it removes the account, every published work, and all
/// cloud assets. Local captures on this device are untouched, which the
/// dialog says explicitly so nobody deletes their account fearing they
/// will lose their scans.
class _DeleteAccountButton extends StatefulWidget {
  const _DeleteAccountButton();

  @override
  State<_DeleteAccountButton> createState() => _DeleteAccountButtonState();
}

class _DeleteAccountButtonState extends State<_DeleteAccountButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return GestureDetector(
      onTap: _busy
          ? null
          : () async {
              final currentUser = AuthScope.read(context);
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (_) => AlertDialog(
                  backgroundColor: AetherColors.bgCanvas,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AetherRadii.lg),
                  ),
                  title: Text(
                    l.meDeleteAccountDialogTitle,
                    style: AetherTextStyles.h2,
                  ),
                  content: Text(
                    l.meDeleteAccountDialogBody,
                    style: AetherTextStyles.body,
                  ),
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
                        l.meDeleteAccountConfirm,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ),
                  ],
                ),
              );
              if (confirmed != true) return;
              if (!context.mounted) return;

              setState(() => _busy = true);
              final ok = await currentUser.deleteAccount();
              if (!context.mounted) return;
              setState(() => _busy = false);

              if (!ok) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l.meDeleteAccountFailed)),
                );
                return;
              }
              // Same trap as sign-out: deleteAccount() flips CurrentUser
              // to SignedOut so _AuthGate swaps the root body, but this
              // page was pushed on top of HomeScreen and Navigator routes
              // survive that swap. Without popping back to the root the
              // user is left staring at a settings page floating over a
              // dead stack.
              Navigator.of(
                context,
                rootNavigator: true,
              ).popUntil((route) => route.isFirst);
            },
      child: Container(
        height: 52,
        decoration: BoxDecoration(
          color: _busy ? AetherColors.danger.withValues(alpha: 0.5)
                       : AetherColors.danger,
          borderRadius: BorderRadius.circular(AetherRadii.lg),
        ),
        alignment: Alignment.center,
        child: _busy
            ? const SizedBox(
                height: 18,
                width: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : Text(
                l.meDeleteAccount,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
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
