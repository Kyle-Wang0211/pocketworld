// Two-step password reset, OTP-based, Ultra-Minimal style.
//
// Replaces the legacy "click the link in your email" flow which doesn't
// survive on a mobile-only app. Mirrors the visual conventions of
// AuthRootView and EmailSignUpPage so the auth surface feels cohesive
// across all three pages.
//
// Step 1 — collect the email, fire CurrentUser.sendPasswordReset which
// hits the password-reset-start Edge Function. Email body renders
// 6-digit OTP via Resend (zh / en chosen at server side).
//
// Step 2 — show six OTP boxes plus a new-password field on the same
// page. Single submit calls resetPasswordWithOtp, which verifyOTPs +
// updates the password atomically. On success the user is signed in
// and AuthGate routes to HomeScreen.
//
// Resend: tappable after a 60 s cooldown, identical to the signup OTP
// page's behavior.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../auth/current_user.dart';
import '../../l10n/app_localizations.dart';
import '../design_system.dart';
import 'auth_minimal_widgets.dart';
import 'auth_shared_widgets.dart';

class ResetPasswordView extends StatefulWidget {
  final CurrentUser currentUser;

  const ResetPasswordView({super.key, required this.currentUser});

  @override
  State<ResetPasswordView> createState() => _ResetPasswordViewState();
}

enum _Step { enterEmail, enterOtpAndPassword }

class _ResetPasswordViewState extends State<ResetPasswordView>
    with SingleTickerProviderStateMixin {
  _Step _step = _Step.enterEmail;
  String _email = '';

  final _emailController = TextEditingController();
  final _otpController = TextEditingController();
  final _otpFocusNode = FocusNode();
  final _newPasswordController = TextEditingController();
  late final AnimationController _shake;

  Timer? _cooldownTimer;
  int _resendCooldownSec = 0;

  static const int _resendCooldownSeconds = 60;
  static const int _otpLength = 6;
  static const int _minPasswordLength = 8;

  @override
  void initState() {
    super.initState();
    _shake = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    );
    _otpFocusNode.addListener(_onExternalChanged);
    widget.currentUser.addListener(_onExternalChanged);
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _otpFocusNode.removeListener(_onExternalChanged);
    widget.currentUser.removeListener(_onExternalChanged);
    _emailController.dispose();
    _otpController.dispose();
    _otpFocusNode.dispose();
    _newPasswordController.dispose();
    _shake.dispose();
    super.dispose();
  }

  void _onExternalChanged() {
    if (!mounted) return;
    setState(() {});
  }

  String get _normalizedEmail => _emailController.text.trim().toLowerCase();

  bool get _step1CanSubmit => _normalizedEmail.contains('@');
  bool get _step2CanSubmit =>
      _otpController.text.length == _otpLength &&
      _newPasswordController.text.length >= _minPasswordLength;

  void _startCooldown() {
    _cooldownTimer?.cancel();
    setState(() => _resendCooldownSec = _resendCooldownSeconds);
    _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() {
        _resendCooldownSec--;
        if (_resendCooldownSec <= 0) {
          _resendCooldownSec = 0;
          t.cancel();
        }
      });
    });
  }

  Future<void> _sendOtp() async {
    if (!_step1CanSubmit) return;
    final ok = await widget.currentUser.sendPasswordReset(_normalizedEmail);
    if (!mounted) return;
    if (ok) {
      setState(() {
        _email = _normalizedEmail;
        _step = _Step.enterOtpAndPassword;
      });
      _startCooldown();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _otpFocusNode.requestFocus();
      });
    }
  }

  Future<void> _resendOtp() async {
    if (_resendCooldownSec > 0 || _email.isEmpty) return;
    final ok = await widget.currentUser.sendPasswordReset(_email);
    if (!mounted) return;
    if (ok) {
      _startCooldown();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(AppL10n.of(context).otpResendSent),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _confirmReset() async {
    if (!_step2CanSubmit || widget.currentUser.isPerformingAuthAction) {
      return;
    }
    final ok = await widget.currentUser.resetPasswordWithOtp(
      email: _email,
      token: _otpController.text.trim(),
      newPassword: _newPasswordController.text,
    );
    if (!mounted) return;
    if (ok) {
      // Tell iOS the new credential is committed so it offers to
      // update the Keychain entry for this email.
      TextInput.finishAutofillContext();
      Navigator.of(context).popUntil((r) => r.isFirst);
      return;
    }
    // Wrong OTP / weak password / etc — clear OTP, refocus, shake.
    _otpController.clear();
    _otpFocusNode.requestFocus();
    _shake.forward(from: 0);
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final working = widget.currentUser.isPerformingAuthAction;
    return Scaffold(
      backgroundColor: AetherColors.bgCanvas,
      body: SafeArea(
        child: AutofillGroup(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const AuthTopBar(leading: AuthTopBarBack()),
              Expanded(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  padding: const EdgeInsets.symmetric(
                    horizontal: AetherSpacing.xl,
                  ),
                  child: _step == _Step.enterEmail
                      ? _buildStep1(l, working)
                      : _buildStep2(l, working),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStep1(AppL10n l, bool working) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Top spacing tuned so the email field underline lines up with
        // the same field on sign-in / sign-up. The "RESET PASSWORD"
        // title wraps to two lines on phone widths whereas "SIGN IN"
        // is one — and we drop the subtitle here per design — so
        // 44 (vs the standard 80) compensates for the taller heading.
        const SizedBox(height: 44),
        AuthHeading(title: l.resetTitle),
        const SizedBox(height: 64),
        LabeledField(
          label: l.authEmailHint,
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.username],
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            if (_step1CanSubmit && !working) _sendOtp();
          },
        ),
        const SizedBox(height: 56),
        MinimalCta(
          title: l.resetSendCode,
          enabled: _step1CanSubmit && !working,
          working: working,
          onTap: _sendOtp,
        ),
        const SizedBox(height: AetherSpacing.xl),
      ],
    );
  }

  Widget _buildStep2(AppL10n l, bool working) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 56),
        AuthHeading(
          title: l.resetTitle,
          subtitle: l.resetSubtitleEnterCode(_email),
        ),
        const SizedBox(height: 48),
        OtpBoxRow(
          controller: _otpController,
          focusNode: _otpFocusNode,
          otpLength: _otpLength,
          shake: _shake,
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: AetherSpacing.xl),
        LabeledField(
          label: l.resetNewPasswordHint,
          controller: _newPasswordController,
          isSecure: true,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.newPassword],
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            if (_step2CanSubmit && !working) _confirmReset();
          },
        ),
        const SizedBox(height: 56),
        MinimalCta(
          title: l.resetConfirm,
          enabled: _step2CanSubmit && !working,
          working: working,
          onTap: _confirmReset,
        ),
        const SizedBox(height: AetherSpacing.xxl),
        MinimalLink(
          title: _resendCooldownSec > 0
              ? l.otpResendCooldown(_resendCooldownSec)
              : l.otpResend,
          emphasis: MinimalLinkEmphasis.faint,
          onTap: (_resendCooldownSec > 0 || working) ? null : _resendOtp,
        ),
        const SizedBox(height: AetherSpacing.xl),
      ],
    );
  }
}
