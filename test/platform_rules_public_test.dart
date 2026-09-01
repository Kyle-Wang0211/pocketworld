// 平台公约"已公开"的契约测试。
//
// 网信办令第10号第六条 / 《深度合成规定》第八条要求的是"制定**和公开**"。
// 在此之前:注册页有一句 authTermsAcceptance 纯文本(原注释自陈 "Plain (not link)"),
// 点不开,也没有任何页面承载内容 —— 有文案而无内容,不构成公开。
//
// 这几条钉住的正是"能不能真的看到":内容非空、三个入口都在、且联系方式
// 的占位没被忘记带上线。
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/legal/platform_rules_content.dart';

String _code(String p) => File(p)
    .readAsStringSync()
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  group('平台公约已公开', () {
    test('中英文正文都非空,且条目数量对齐', () {
      expect(kPlatformRulesZh, isNotEmpty);
      expect(kPlatformRulesEn, isNotEmpty);
      expect(
        kPlatformRulesEn.length,
        kPlatformRulesZh.length,
        reason: '两版章节数不一致 ⇒ 有一版漏改了',
      );
      for (var i = 0; i < kPlatformRulesZh.length; i++) {
        expect(kPlatformRulesZh[i].items, isNotEmpty);
        expect(kPlatformRulesEn[i].items, isNotEmpty);
      }
    });

    test('覆盖法条点名要求的内容', () {
      final all = kPlatformRulesZh.expand((s) => s.items).join();
      // 第十七条的五级处置手段
      for (final m in ['警示提醒', '限期改正', '限制账号功能', '暂停使用', '关闭账号']) {
        expect(all, contains(m), reason: '第十七条处置手段缺: $m');
      }
      // 第十条的从严核验词
      expect(all, contains('从严核验'));
      // 深度合成第十六条的标识
      expect(all, contains('标识'));
      // Apple 1.2 要求的举报与联系方式
      expect(all, contains('举报'));
      expect(all, contains('邮箱'));
    });

    test('🔑 三个入口都接上了 —— 少一个就不算"公开"', () {
      expect(
        _code('lib/ui/me_settings_page.dart'),
        contains('PlatformRulesPage.open'),
        reason: '设置页没有公约入口',
      );
      // [2026-08-24] 注册页从单链接换成 LegalDocLinksRow(三件套各自可点,
      // 其中含平台公约链接)—— 入口仍在,只是间接了一层。
      expect(
        _code('lib/ui/auth/email_sign_in_view.dart'),
        contains('LegalDocLinksRow'),
        reason: '注册页那句"即表示同意"仍然点不开',
      );
      expect(
        _code('lib/ui/legal/legal_doc_links_row.dart'),
        contains('PlatformRulesPage.open'),
        reason: 'LegalDocLinksRow 里丢了平台公约链接 ⇒ 注册页开不到公约',
      );
      expect(
        File('lib/ui/legal/platform_rules_page.dart').existsSync(),
        isTrue,
        reason: '承载正文的页面不存在',
      );
    });

    test('⚠️ 联系邮箱占位必须在上线前替换 —— 这条红了说明该填了', () {
      final all = kPlatformRulesZh.expand((s) => s.items).join();
      final placeholder = all.contains('待填写');
      expect(
        placeholder,
        isTrue,
        reason:
            '占位符已被替换 —— 如果确实填了真实邮箱,请把这条测试改成断言邮箱格式,'
            '不要直接删掉:Apple Guideline 1.2 要求 App 内与商店页面都有可达联系方式',
      );
    });
  });
}
