// 平台公约页 —— 承载 platform_rules_content.dart 的正文。
//
// 第六条要求的是"制定**和公开**"。在此之前注册页只有一句纯文本
// "注册即表示你同意……",点不开也没有内容页 —— 那不构成公开。
// 这一页 + 注册页的可点链接 + 设置页入口,三处一起才算把"公开"做到。
import 'package:flutter/material.dart';

import '../design_system.dart';
import '../../i18n/locale_notifier.dart';
import 'platform_rules_content.dart';

class PlatformRulesPage extends StatelessWidget {
  const PlatformRulesPage({super.key});

  /// 统一的打开方式,三个入口都走它,避免各处各写一遍 MaterialPageRoute。
  static Future<void> open(BuildContext context) => Navigator.of(
    context,
  ).push(MaterialPageRoute<void>(builder: (_) => const PlatformRulesPage()));

  @override
  Widget build(BuildContext context) {
    // 中文版为准:法定义务依据的是中文法条,英文版仅为便利。
    final isZh = LocaleScope.of(context).isChinese;
    final sections = isZh ? kPlatformRulesZh : kPlatformRulesEn;
    return Scaffold(
      backgroundColor: AetherColors.bgCanvas,
      appBar: AppBar(
        backgroundColor: AetherColors.bgCanvas,
        elevation: 0,
        title: Text(
          isZh ? '平台公约' : 'Platform Rules',
          style: AetherTextStyles.h2,
        ),
      ),
      body: SafeArea(
        child: ListView.builder(
          padding: const EdgeInsets.fromLTRB(
            AetherSpacing.lg,
            AetherSpacing.md,
            AetherSpacing.lg,
            AetherSpacing.xxl,
          ),
          itemCount: sections.length + 1,
          itemBuilder: (context, i) {
            if (i == sections.length) {
              return Padding(
                padding: const EdgeInsets.only(top: AetherSpacing.xl),
                child: Text(
                  isZh
                      ? '本公约描述的是产品当前的实际规则。规则调整时本页同步更新。'
                      : 'These rules describe how the product actually behaves today, '
                            'and are updated when behaviour changes. '
                            'In case of any discrepancy, the Chinese version prevails.',
                  style: const TextStyle(
                    fontSize: 12,
                    height: 1.6,
                    color: AetherColors.textTertiary,
                  ),
                ),
              );
            }
            final s = sections[i];
            return Padding(
              padding: const EdgeInsets.only(bottom: AetherSpacing.xl),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: AetherColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: AetherSpacing.sm),
                  for (final item in s.items)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 7, right: 8),
                            child: SizedBox(
                              width: 3,
                              height: 3,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: AetherColors.textTertiary,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              item,
                              style: const TextStyle(
                                fontSize: 13,
                                height: 1.7,
                                color: AetherColors.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
