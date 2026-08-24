// 隐私政策与用户协议的"已公开且没带着占位符上线"契约测试。
//
// 三层钉子:
//   1. 占位符必须在 —— 五个占位(公司名/注册地/邮箱/生效日期/作品授权)
//      被替换前这些测试是绿的;真要上线时,替换后按各条 reason 里的说明
//      改写断言,不许直接删测试。
//   2. 法定必备内容必须在 —— PIPL 17 条四要素、认定方法的时限承诺、
//      属地展示告知、14 周岁门槛、处置阶梯。少一样就是文本被误删。
//   3. 入口必须接着 —— 注册两条路径 + 设置页。公开 = 能看到,
//      文件存在但没有入口不构成公开。
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/legal/privacy_policy_content.dart';
import 'package:pocketworld_flutter/ui/legal/user_agreement_content.dart';

String _code(String p) => File(p)
    .readAsStringSync()
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  final privacy = kPrivacyPolicyZh.expand((s) => s.paragraphs).toList();
  final agreement = kUserAgreementZh.expand((s) => s.paragraphs).toList();
  final privacyAll = privacy.map((p) => p.text).join();
  final agreementAll = agreement.map((p) => p.text).join();

  group('占位符 —— 上线前必须替换,替换后改写断言而不是删掉', () {
    test('公司名称占位(两份文件都要)', () {
      expect(privacyAll, contains('公司名称待注册后填写'));
      expect(agreementAll, contains('公司名称待注册后填写'),
          reason: '若已填真实公司名,把本断言改成两份文件公司名一致的断言');
    });
    test('注册地占位(隐私政策联系章 + 协议管辖条款)', () {
      expect(privacyAll, contains('公司注册地待定后填写'));
      expect(agreementAll, contains('公司注册地待定后填写'),
          reason: '若已填,改成断言管辖条款包含具体城市名');
    });
    test('联系邮箱占位 —— 与平台公约页同一口径"待填写"', () {
      expect(privacyAll, contains('待填写'));
      expect(agreementAll, contains('待填写'),
          reason: '若已填,改成断言邮箱格式且三份文件(含平台公约)是同一个邮箱');
    });
    test('生效日期占位', () {
      expect(kPrivacyPolicyEffectiveDate, contains('待上线前填写'));
      expect(kUserAgreementEffectiveDate, contains('待上线前填写'),
          reason: '⚠️ 生效前提:Supabase→阿里云迁移完成(境内存储那句话才为真)、'
              '邮件服务商换境内、首启同意弹窗落地 —— 见 supabase/README.md 上线门槛');
    });
    test('🔴 作品授权条款占位 —— 产品负责人明确要求专项讨论后定稿', () {
      expect(agreementAll, contains('作品授权条款待定稿'),
          reason: '定稿后:删除占位段,写入定稿条款(必须 emphasized),'
              '并把本断言改成断言许可范围关键词(存储/分发/展示)存在');
    });
  });

  group('法定必备内容', () {
    test('PIPL 17 条四要素:主体/期限/权利/联系方式', () {
      expect(privacyAll, contains('保存期限'));
      expect(privacyAll, contains('15 个工作日'));
      expect(privacyAll, contains('撤回'));
      expect(privacyAll, contains('注销'));
      expect(privacyAll, contains('邮箱'));
    });
    test('属地展示告知 + 双用途一并告知(目的限定)', () {
      expect(privacyAll, contains('IP 属地'));
      expect(privacyAll, contains('省'));
      // 5.1.2(ii)/PIPL:同一 IP 的审计与属地展示两个用途必须同时写明
      expect(privacyAll, contains('审计'));
    });
    test('删除的法定兜底句(47 条二款) + 审计日志期限与代码一致', () {
      expect(privacyAll, contains('停止除存储和采取必要安全保护措施之外的处理'));
      // 20260818000000 迁移:一般 180 天 / 重大 730 天。改代码必须回来改政策。
      expect(privacyAll, contains('180 天'));
      expect(privacyAll, contains('730 天'));
    });
    test('14 周岁门槛(两份文件口径一致)', () {
      expect(privacyAll, contains('14 周岁'));
      expect(agreementAll, contains('14 周岁'));
      expect(privacyAll, contains('不满 14 周岁'));
    });
    test('协议:处置阶梯(账号规定 17 条"依约"的合同依据)', () {
      for (final m in ['警示提醒', '限期改正', '限制账号功能', '暂停使用', '关闭账号', '禁止重新注册']) {
        expect(agreementAll, contains(m), reason: '处置手段缺: $m');
      }
      expect(agreementAll, contains('申诉'));
    });
    test('协议:修改公示 7 日 + 无"最终解释权"红线', () {
      expect(agreementAll, contains('7 日'));
      expect(agreementAll, isNot(contains('最终解释权')),
          reason: '消保法 26 条/民法典 497 条的无效条款,也是格式条款执法最常见靶子');
    });
    test('深度合成显著提示(第八条)必须是加粗段', () {
      final hit = agreement.where((p) => p.text.contains('深度合成') && p.emphasized);
      expect(hit, isNotEmpty, reason: '第八条要求"以显著方式提示"——不加粗不算显著');
    });
    test('民法典 496 条:免责/限责/管辖条款必须加粗', () {
      bool anyEmph(String kw) =>
          agreement.any((p) => p.text.contains(kw) && p.emphasized);
      expect(anyEmph('不承担责任'), isTrue, reason: '免责条款没有加粗');
      expect(anyEmph('赔偿责任总额'), isTrue, reason: '限责条款没有加粗');
      expect(anyEmph('人民法院'), isTrue, reason: '管辖条款没有加粗');
    });
  });

  group('入口 —— 少一个就不算公开', () {
    test('设置页两份文件入口', () {
      final code = _code('lib/ui/me_settings_page.dart');
      expect(code, contains('PrivacyPolicyPage.open'));
      expect(code, contains('UserAgreementPage.open'));
    });
    test('邮箱注册页与手机号注册页都有三链接行', () {
      expect(_code('lib/ui/auth/email_sign_in_view.dart'),
          contains('LegalDocLinksRow'));
      expect(_code('lib/ui/auth/phone_sign_in_view.dart'),
          contains('LegalDocLinksRow'));
    });
  });

  group('xcprivacy 与政策口径一致', () {
    test('七类收集项都已申报,常量拼写与官方一致', () {
      final xc = File('ios/Runner/PrivacyInfo.xcprivacy').readAsStringSync();
      for (final c in [
        'NSPrivacyCollectedDataTypeEmailAddress',
        'NSPrivacyCollectedDataTypePhoneNumber',
        'NSPrivacyCollectedDataTypeUserID',
        'NSPrivacyCollectedDataTypeCoarseLocation',
        'NSPrivacyCollectedDataTypeEnvironmentScanning',
        'NSPrivacyCollectedDataTypeProductInteraction',
        'NSPrivacyCollectedDataTypeOtherUserContent',
      ]) {
        expect(xc, contains('<string>$c</string>'), reason: '缺申报: $c');
      }
      // 源照片不上传 + 无头像上传 ⇒ 不得申报 Photos(申报了反而失实)
      expect(xc, isNot(contains('NSPrivacyCollectedDataTypePhotosorVideos')),
          reason: '若上线了头像照片上传,先改隐私政策再来申报这一项');
      // ⚠️ 第一版谓词写成了"<true/> 后面跟 Tracking 键",匹配到的其实是
      //    上一行 Linked=true —— 判据匹配错对象。正确判据:每个 Tracking
      //    键的**值**都必须是 false。
      final trackingValues = RegExp(
        r'NSPrivacyCollectedDataTypeTracking</key>\s*<(true|false)/>',
      ).allMatches(xc).map((m) => m.group(1)).toList();
      expect(trackingValues, isNotEmpty);
      expect(trackingValues.every((v) => v == 'false'), isTrue,
          reason: '任何一项 Tracking=true 都意味着要走 ATT,本产品不追踪');
    });
  });
}
