// Dart port of App/Auth/PhoneSignInView.swift.
//
// Two-step flow:
//   1) country code + national number → provider issues verificationID
//   2) enter 6-digit code → sign in / sign up
//
// [PHONE-AUTH 2026-08-23] 这一页此前从未被接入(原注释:"Not surfaced by
// AuthRootView today"),所以里面的文案一直是硬编码中文。现已接上 —— 依据是
// 《互联网用户账号信息管理规定》第九条:真实身份认证必须"基于**移动电话号码**、
// 身份证件号码或者统一社会信用代码等方式",**邮箱不在这个列举里**,
// 而且"用户不提供真实身份信息的,不得为其提供相关服务"。
//
// ⚠️ 服务端已完备(signInWithOtp + verifyOTP,注册路径一次成型),但要真正发出
//    短信还需要:①Dashboard 启用 Phone provider ②配置 Send SMS Hook 指向
//    supabase/functions/send-sms-hook ③给该函数配阿里云短信的 4 个 secret。

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../auth/auth_models.dart';
import '../../auth/current_user.dart';
import '../design_system.dart';
import '../../l10n/app_localizations.dart';
import '../legal/legal_doc_links_row.dart';
import 'auth_shared_widgets.dart';

enum PhoneIntent { signIn, signUp }

class PhoneSignInView extends StatefulWidget {
  final CurrentUser currentUser;
  final PhoneIntent intent;

  const PhoneSignInView({
    super.key,
    required this.currentUser,
    required this.intent,
  });

  @override
  State<PhoneSignInView> createState() => _PhoneSignInViewState();
}

class _PhoneSignInViewState extends State<PhoneSignInView> {
  final _countryCode = TextEditingController(text: '+86');
  final _nationalNumber = TextEditingController();
  final _displayName = TextEditingController();
  final _code = TextEditingController();

  PhoneVerificationChallenge? _challenge;

  @override
  void dispose() {
    _countryCode.dispose();
    _nationalNumber.dispose();
    _displayName.dispose();
    _code.dispose();
    super.dispose();
  }

  String get _e164 {
    final cc = _countryCode.text.replaceAll(RegExp(r'[^0-9]'), '');
    final number = _nationalNumber.text.replaceAll(RegExp(r'[^0-9]'), '');
    if (cc.isEmpty || number.isEmpty) return '';
    return '+$cc$number';
  }

  bool get _canStart =>
      _e164.isNotEmpty &&
      _nationalNumber.text.replaceAll(RegExp(r'[^0-9]'), '').length >= 6;

  Future<void> _startVerification() async {
    final result = await widget.currentUser.startPhoneVerification(_e164);
    if (!mounted) return;
    setState(() => _challenge = result);
  }

  Future<void> _submitCode() async {
    final ch = _challenge;
    if (ch == null) return;
    switch (widget.intent) {
      case PhoneIntent.signIn:
        await widget.currentUser.signIn(
          SignInRequest.phone(
            phoneNumber: ch.phoneNumber,
            verificationID: ch.verificationID,
            code: _code.text,
          ),
        );
      case PhoneIntent.signUp:
        await widget.currentUser.signUp(
          SignUpRequest.phone(
            phoneNumber: ch.phoneNumber,
            verificationID: ch.verificationID,
            code: _code.text,
            displayName: _displayName.text.trim().isEmpty
                ? null
                : _displayName.text.trim(),
          ),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    final working = widget.currentUser.isPerformingAuthAction;
    if (_challenge != null) {
      return _codeEntryStep(l, working);
    }
    return _phoneEntryStep(l, working);
  }

  Widget _phoneEntryStep(AppL10n l, bool working) {
    return Column(
      children: [
        Row(
          children: [
            AuthField(
              title: '+86',
              controller: _countryCode,
              keyboard: AuthFieldKeyboard.phone,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9+]')),
              ],
              width: 84,
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(width: AetherSpacing.sm),
            Expanded(
              child: AuthField(
                title: l.authPhoneNumberHint,
                controller: _nationalNumber,
                keyboard: AuthFieldKeyboard.phone,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                ],
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        if (widget.intent == PhoneIntent.signUp) ...[
          const SizedBox(height: AetherSpacing.md),
          AuthField(
            title: l.authPhoneDisplayNameHint,
            controller: _displayName,
          ),
        ],
        const SizedBox(height: AetherSpacing.lg),
        AuthPrimaryButton(
          title: l.authPhoneSendCode,
          isWorking: working,
          isEnabled: _canStart,
          onTap: _startVerification,
        ),
        const SizedBox(height: AetherSpacing.md),
        // [LEGAL-DOCS 2026-08-24] 手机号注册与邮箱注册是并列的注册路径,
        // 法律文件的可达性必须两条路径都有。
        LegalDocLinksRow(prefix: l.authTermsAcceptancePrefix),
        const SizedBox(height: AetherSpacing.md),
        Text(
          l.authPhoneWillSend(_e164.isEmpty ? l.authPhoneYourNumber : _e164),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 12,
            color: AetherColors.textTertiary,
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _codeEntryStep(AppL10n l, bool working) {
    final ch = _challenge!;
    return Column(
      children: [
        Text(
          l.authPhoneCodeSentTo(ch.phoneNumber),
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 14,
            color: AetherColors.textSecondary,
          ),
        ),
        const SizedBox(height: AetherSpacing.md),
        AuthField(
          title: l.authPhoneCodeHint,
          controller: _code,
          keyboard: AuthFieldKeyboard.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          onChanged: (_) => setState(() {}),
          textInputAction: TextInputAction.done,
        ),
        const SizedBox(height: AetherSpacing.lg),
        AuthPrimaryButton(
          title: widget.intent == PhoneIntent.signIn ? l.authPhoneSubmitSignIn : l.authPhoneSubmitSignUp,
          isWorking: working,
          isEnabled: _code.text.length >= 6,
          onTap: _submitCode,
        ),
        const SizedBox(height: AetherSpacing.md),
        GestureDetector(
          onTap: working
              ? null
              : () => setState(() {
                    _challenge = null;
                    _code.clear();
                  }),
          child: Text(
            l.authPhoneChangeNumber,
            style: const TextStyle(
              fontSize: 14,
              color: AetherColors.textSecondary,
              decoration: TextDecoration.underline,
              decorationColor: AetherColors.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}
