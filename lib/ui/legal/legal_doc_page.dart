// 法律文本页 —— 隐私政策与用户协议共用一个渲染器。
// =====================================================================
// 与 PlatformRulesPage 的差异只有两处,都不是审美:
//   1. emphasized 段落加粗渲染 —— 民法典第四百九十六条对重大利害关系条款的
//      显著提示义务(详见 legal_doc_model.dart 头注),渲染层不落实,
//      内容层标了也白标。
//   2. 头部展示版本号与生效日期 —— PIPL 第十四条"哪个版本被同意过"的
//      证明链一环;历史版本承诺也写进了两份文本的正文里。
//
// 语言:正文仅中文(拍板决定)。英文界面下同样显示中文正文,
// 页面顶部给一句英文说明"本文件以中文为准"。
import 'package:flutter/material.dart';

import '../design_system.dart';
import '../../i18n/locale_notifier.dart';
import 'legal_doc_model.dart';
import 'privacy_policy_content.dart';
import 'user_agreement_content.dart';

class LegalDocPage extends StatelessWidget {
  final String title;
  final String version;
  final String effectiveDate;
  final List<LegalSection> sections;

  const LegalDocPage({
    super.key,
    required this.title,
    required this.version,
    required this.effectiveDate,
    required this.sections,
  });

  @override
  Widget build(BuildContext context) {
    final isZh = LocaleScope.of(context).isChinese;
    return Scaffold(
      backgroundColor: AetherColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: AetherColors.bgCanvas,
        elevation: 0,
        title: Text(title, style: AetherTextStyles.h2),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            AetherSpacing.lg,
            AetherSpacing.md,
            AetherSpacing.lg,
            AetherSpacing.xxl,
          ),
          children: [
            Text(
              '版本 $version · 生效日期 $effectiveDate',
              style: const TextStyle(
                fontSize: 12,
                color: AetherColors.textTertiary,
                height: 1.6,
              ),
            ),
            if (!isZh)
              const Padding(
                padding: EdgeInsets.only(top: AetherSpacing.xs),
                child: Text(
                  'This document is written in Chinese and the Chinese '
                  'version prevails.',
                  style: TextStyle(
                    fontSize: 12,
                    color: AetherColors.textTertiary,
                    height: 1.6,
                  ),
                ),
              ),
            const SizedBox(height: AetherSpacing.lg),
            for (final section in sections) ...[
              Padding(
                padding: const EdgeInsets.only(
                  top: AetherSpacing.lg,
                  bottom: AetherSpacing.sm,
                ),
                child: Text(
                  section.title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AetherColors.textPrimary,
                    height: 1.5,
                  ),
                ),
              ),
              for (final p in section.paragraphs)
                Padding(
                  padding: const EdgeInsets.only(bottom: AetherSpacing.sm),
                  child: Text(
                    p.text,
                    style: TextStyle(
                      fontSize: 13,
                      height: 1.8,
                      color: AetherColors.textPrimary,
                      // 民法典 496 条的显著提示义务落在这一行。
                      fontWeight: p.emphasized
                          ? FontWeight.w700
                          : FontWeight.w400,
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 隐私政策页。三处入口:注册页(邮箱/手机号)、设置页。
class PrivacyPolicyPage extends StatelessWidget {
  const PrivacyPolicyPage({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const PrivacyPolicyPage()));

  @override
  Widget build(BuildContext context) => const LegalDocPage(
    title: '方寸间隐私政策',
    version: kPrivacyPolicyVersion,
    effectiveDate: kPrivacyPolicyEffectiveDate,
    sections: kPrivacyPolicyZh,
  );
}

/// 用户协议页。入口同上。
class UserAgreementPage extends StatelessWidget {
  const UserAgreementPage({super.key});

  static Future<void> open(BuildContext context) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const UserAgreementPage()));

  @override
  Widget build(BuildContext context) => const LegalDocPage(
    title: '方寸间用户协议',
    version: kUserAgreementVersion,
    effectiveDate: kUserAgreementEffectiveDate,
    sections: kUserAgreementZh,
  );
}
