// 注册页脚部的法律文件链接行:《用户协议》《隐私政策》《平台公约》。
// =====================================================================
// 为什么是三个分开的链接而不是一句话指向一个页面:三件套(账号规定第六条/
// 生态治理规定第十五条/深度合成规定第八条)是并列的"制定和公开"义务,
// "你已同意 X、Y、Z"却只能看到其中一份,另外两份仍然不构成公开。
import 'package:flutter/material.dart';

import '../design_system.dart';
import '../../l10n/app_localizations.dart';
import 'legal_doc_page.dart';
import 'platform_rules_page.dart';

class LegalDocLinksRow extends StatelessWidget {
  final String prefix;
  const LegalDocLinksRow({super.key, required this.prefix});

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    const linkStyle = TextStyle(
      fontSize: 11,
      color: AetherColors.textSecondary,
      height: 1.5,
      letterSpacing: 0.3,
      decoration: TextDecoration.underline,
      decorationColor: AetherColors.textSecondary,
    );
    Widget link(String title, Future<void> Function(BuildContext) open) =>
        GestureDetector(
          onTap: () => open(context),
          behavior: HitTestBehavior.opaque,
          child: Text('《$title》', style: linkStyle),
        );
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 2,
      runSpacing: 2,
      children: [
        Text(
          prefix,
          style: const TextStyle(
            fontSize: 11,
            color: AetherColors.textSecondary,
            height: 1.5,
            letterSpacing: 0.3,
          ),
        ),
        link(l.legalUserAgreement, UserAgreementPage.open),
        link(l.legalPrivacyPolicy, PrivacyPolicyPage.open),
        link(l.mePlatformRules, PlatformRulesPage.open),
      ],
    );
  }
}
