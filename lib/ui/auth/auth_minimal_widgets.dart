// Shared widgets for the Ultra-Minimal auth design.
//
// Three pages use this aesthetic — sign in (AuthRootView), sign up
// (EmailSignUpPage), and reset password (ResetPasswordView). Originally
// each page defined private copies; consolidated here so a future tweak
// to the design tokens (font, letter-spacing, underline color) lands in
// one place.
//
// Visual conventions:
//   • English copy renders ALL-CAPS via .toUpperCase() at render time.
//     Chinese is unaffected — letter-spacing applies to both.
//   • No filled buttons; the primary CTA is bold caps text + arrow.
//   • Inputs are underline-only (no surrounding card / fill).
//   • Top bar = optional leading widget · centered wordmark · 中/EN
//     toggle. Wordmark is geometrically centered via Stack so the
//     centering doesn't drift when leading / trailing widths change.

import 'package:flutter/material.dart';

import '../../i18n/locale_notifier.dart';
import '../../l10n/app_localizations.dart';
import '../design_system.dart';

// =====================================================================
// Top bar — [optional leading] · wordmark · 中/EN
// =====================================================================
class AuthTopBar extends StatelessWidget {
  /// Widget rendered top-left. Typically a back-chevron IconButton on
  /// pushed sub-pages; null on the root sign-in page.
  final Widget? leading;

  const AuthTopBar({super.key, this.leading});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AetherSpacing.lg,
        AetherSpacing.md,
        AetherSpacing.lg,
        AetherSpacing.md,
      ),
      child: SizedBox(
        height: 28,
        child: Stack(
          children: [
            // Wordmark — geometrically centered regardless of what
            // floats on either side.
            Center(
              child: Text(
                l.appBrand.toUpperCase(),
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 4,
                  color: AetherColors.textPrimary,
                ),
              ),
            ),
            if (leading != null)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: Center(child: leading!),
              ),
            const Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: Center(child: CompactLanguageToggle()),
            ),
          ],
        ),
      ),
    );
  }
}

/// Convenience back-chevron suitable for `AuthTopBar.leading`.
class AuthTopBarBack extends StatelessWidget {
  const AuthTopBarBack({super.key});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => Navigator.of(context).maybePop(),
      child: const Padding(
        padding: EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Icon(
          Icons.chevron_left_rounded,
          size: 22,
          color: AetherColors.textPrimary,
        ),
      ),
    );
  }
}

// =====================================================================
// Compact "中 · EN" language toggle.
// Active option in textPrimary; inactive in textTertiary.
// =====================================================================
class CompactLanguageToggle extends StatelessWidget {
  const CompactLanguageToggle({super.key});

  @override
  Widget build(BuildContext context) {
    final notifier = LocaleScope.of(context);
    final isZh = notifier.isChinese;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => notifier.set(isZh ? const Locale('en') : const Locale('zh')),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AetherSpacing.sm,
          vertical: 4,
        ),
        child: RichText(
          text: TextSpan(
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.5,
            ),
            children: [
              TextSpan(
                text: '中',
                style: TextStyle(
                  color: isZh
                      ? AetherColors.textPrimary
                      : AetherColors.textTertiary,
                ),
              ),
              const TextSpan(
                text: ' · ',
                style: TextStyle(
                  color: AetherColors.textTertiary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              TextSpan(
                text: 'EN',
                style: TextStyle(
                  color: !isZh
                      ? AetherColors.textPrimary
                      : AetherColors.textTertiary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// =====================================================================
// Heading + (optional) subtitle. Both rendered ALL-CAPS for English
// (no-op for Chinese) with letter-spacing applied across both scripts.
//
// Pass subtitle=null to render just the title — used by reset password
// step 1 where the title alone ("RESET PASSWORD") is self-explanatory.
// =====================================================================
class AuthHeading extends StatelessWidget {
  final String title;
  final String? subtitle;
  const AuthHeading({super.key, required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          title.toUpperCase(),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 36,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.5,
            color: AetherColors.textPrimary,
            height: 1.05,
          ),
        ),
        if (subtitle != null) ...[
          const SizedBox(height: AetherSpacing.sm),
          Text(
            subtitle!.toUpperCase(),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 3,
              color: AetherColors.textTertiary,
            ),
          ),
        ],
      ],
    );
  }
}

// =====================================================================
// Underline-only input. Caps + letter-spaced label above; TextField
// below with a hairline bottom underline (focused = primary 1.5 px).
//
// iOS Keychain heuristic: secure / email fields must have autocorrect
// + suggestions OFF, otherwise iOS doesn't recognise them as
// credential fields and won't offer to save / fill.
// =====================================================================
class LabeledField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool isSecure;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final Iterable<String>? autofillHints;
  final void Function(String)? onChanged;
  final void Function(String)? onSubmitted;

  const LabeledField({
    super.key,
    required this.label,
    required this.controller,
    this.focusNode,
    this.isSecure = false,
    this.keyboardType,
    this.textInputAction,
    this.autofillHints,
    this.onChanged,
    this.onSubmitted,
  });

  @override
  Widget build(BuildContext context) {
    final isEmail = keyboardType == TextInputType.emailAddress;
    final disableInputAssist = isSecure || isEmail;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 2.5,
            color: AetherColors.textTertiary,
          ),
        ),
        const SizedBox(height: 4),
        TextField(
          controller: controller,
          focusNode: focusNode,
          obscureText: isSecure,
          keyboardType: keyboardType,
          textInputAction: textInputAction,
          autofillHints: autofillHints,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
          autocorrect: !disableInputAssist,
          enableSuggestions: !disableInputAssist,
          textCapitalization: TextCapitalization.none,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w500,
            color: AetherColors.textPrimary,
          ),
          decoration: const InputDecoration(
            isDense: true,
            contentPadding: EdgeInsets.symmetric(vertical: 10),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AetherColors.border, width: 1),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(
                color: AetherColors.textPrimary,
                width: 1.5,
              ),
            ),
            disabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: AetherColors.border, width: 1),
            ),
            border: UnderlineInputBorder(
              borderSide: BorderSide(color: AetherColors.border, width: 1),
            ),
          ),
        ),
      ],
    );
  }
}

// =====================================================================
// Primary CTA — bold caps text + right arrow, no filled background.
// Disabled state grays out; working state replaces text with a small
// spinner so the form's busy state is still visible.
// =====================================================================
class MinimalCta extends StatelessWidget {
  final String title;
  final bool enabled;
  final bool working;
  final VoidCallback onTap;

  const MinimalCta({
    super.key,
    required this.title,
    required this.enabled,
    required this.working,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color =
        enabled ? AetherColors.textPrimary : AetherColors.textTertiary;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 36,
        child: Center(
          child: working
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      AetherColors.textPrimary,
                    ),
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      title.toUpperCase(),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 3,
                        color: color,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Icon(Icons.arrow_forward_rounded, size: 18, color: color),
                  ],
                ),
        ),
      ),
    );
  }
}

// =====================================================================
// Tertiary text link — two emphasis levels.
//   medium = secondary copy ("REQUEST NEW ACCESS"-weight)
//   faint  = tertiary copy ("FORGOT PASSWORD"-weight)
// Trailing "?" / "？" stripped at render time so the upper-cased link
// reads as a label, not a question.
// =====================================================================
enum MinimalLinkEmphasis { medium, faint }

class MinimalLink extends StatelessWidget {
  final String title;
  final MinimalLinkEmphasis emphasis;
  final VoidCallback? onTap;

  const MinimalLink({
    super.key,
    required this.title,
    required this.emphasis,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = emphasis == MinimalLinkEmphasis.medium
        ? AetherColors.textSecondary
        : AetherColors.textTertiary;
    final fontSize = emphasis == MinimalLinkEmphasis.medium ? 12.0 : 11.0;
    final letterSpacing = emphasis == MinimalLinkEmphasis.medium ? 2.5 : 2.0;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        height: 28,
        child: Center(
          child: Text(
            title.toUpperCase().replaceAll('?', '').replaceAll('？', ''),
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              letterSpacing: letterSpacing,
              color: onTap == null
                  ? AetherColors.textTertiary.withValues(alpha: 0.6)
                  : color,
            ),
          ),
        ),
      ),
    );
  }
}
