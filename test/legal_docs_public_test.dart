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
      expect(
        agreementAll,
        contains('公司名称待注册后填写'),
        reason: '若已填真实公司名,把本断言改成两份文件公司名一致的断言',
      );
    });
    test('注册地占位(隐私政策联系章 + 协议管辖条款)', () {
      expect(privacyAll, contains('公司注册地待定后填写'));
      expect(
        agreementAll,
        contains('公司注册地待定后填写'),
        reason: '若已填,改成断言管辖条款包含具体城市名',
      );
    });
    test('联系邮箱占位 —— 与平台公约页同一口径"待填写"', () {
      expect(privacyAll, contains('待填写'));
      expect(
        agreementAll,
        contains('待填写'),
        reason: '若已填,改成断言邮箱格式且三份文件(含平台公约)是同一个邮箱',
      );
    });
    test('生效日期占位', () {
      expect(kPrivacyPolicyEffectiveDate, contains('待上线前填写'));
      expect(
        kUserAgreementEffectiveDate,
        contains('待上线前填写'),
        reason:
            '⚠️ 生效前提:Supabase→阿里云迁移完成(境内存储那句话才为真)、'
            '邮件服务商换境内、首启同意弹窗落地 —— 见 supabase/README.md 上线门槛',
      );
    });
    test('✅ 作品授权条款已定稿(2026-08-24 拍板),关键要素齐全且加粗', () {
      expect(agreementAll, isNot(contains('待定稿')));
      // 四项拍板逐一钉住:版权归作者已在 6.2;这里钉许可条款的要素
      for (final kw in [
        '非独家', // 许可性质(抖音 10.3 同款措辞)
        '信息网络传播权', // 权项式列举(著作权法权项制,复刻抖音结构)
        '科学研究', // 研究用途(深度合成14条/生成式AI办法7条(三)的同意载体)
        '训练', // 模型训练明示(比三家同行都进一步 —— 我们管线含扩散模型)
        '各类人工智能算法与模型', // 属写宽:研究领域不点名(三家同行均如此)
        '日后开发', // 未来技术伞(小红书句式)
        '云端存储', // 范围含未来云储(拍板②)
        '匿名化', // 对外边界(拍板③)
        '单独同意', // 可识别形式对外的前提
        '主动申请删除账号', // "注销"的定义内嵌(2026-08-24 追问后补)
        '已训练完成的模型不受影响', // 删除的物理现实,不写就与删除承诺打架
        '撤回本款维权授权', // 维权授权复刻抖音 10.4 但加撤回权
      ]) {
        expect(agreementAll, contains(kw), reason: '授权条款缺要素: $kw');
      }
      // 🔴 小红书式"不可撤销"是明确不复刻的红线(与第 5 款删除终止矛盾,
      //    且被消费者权益媒体点名批评过)
      expect(agreementAll, isNot(contains('不可撤销')));
      // 权利许可条款必须加粗(民法典 496 条)
      expect(
        agreement.any((p) => p.text.contains('非独家') && p.emphasized),
        isTrue,
        reason: '许可条款没有加粗',
      );
      // 隐私政策侧的研究用途告知也必须在且加粗(两文件口径一致)
      expect(
        privacy.any((p) => p.text.contains('科学研究') && p.emphasized),
        isTrue,
        reason: '隐私政策缺研究用途的显著告知',
      );
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
      expect(
        agreementAll,
        isNot(contains('最终解释权')),
        reason: '消保法 26 条/民法典 497 条的无效条款,也是格式条款执法最常见靶子',
      );
    });
    test('深度合成显著提示(第八条)必须是加粗段', () {
      final hit = agreement.where(
        (p) => p.text.contains('深度合成') && p.emphasized,
      );
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

  group('同行缺口回填(2026-08-24 四家逐字清查)', () {
    test('协议:此前完全缺失的条款已补', () {
      for (final kw in [
        '视为送达', // 通知送达(微博10章/抖音15.2)—— 此前整个缺失
        '垃圾信息', // 商业垃圾/营销信息禁令(微博4.6/抖音4.6)
        '视为您本人的行为', // 账号项下行为归属(微博1.2.2/B站2.2)
        '临时冻结', // 被盗处理(微博4.7/抖音3.6)
        '保证或背书', // 审核不构成背书(抖音14.4 先审后发适配)
        '误差、缺失或失真', // AI 局限(抖音14.8适配)
        '算法与模型参数', // 衍生数据归属(抖音10.6 收窄适配,排除内容本身)
        '注意周围环境与自身及他人安全', // 拍摄安全(本产品特有)
        '间接性、后果性、惩罚性', // 间接损失排除(抖音14.7)
        '大陆地区用户提供', // 服务地域(中美合规定案:上中国区)
      ]) {
        expect(agreementAll, contains(kw), reason: '缺口回填丢失: $kw');
      }
    });
    test('统计(自建埋点)三处口径一致:政策/开关/清单', () {
      expect(privacyAll, contains('产品改进与统计分析'));
      expect(privacyAll, contains('帮助改进产品'));
      expect(privacyAll, contains('统计事件 180 天'));
      expect(privacyAll, contains('不经任何第三方统计组件'));
      final xc = File('ios/Runner/PrivacyInfo.xcprivacy').readAsStringSync();
      expect(xc, contains('NSPrivacyCollectedDataTypeCrashData'));
      expect(xc, contains('NSPrivacyCollectedDataTypePurposeAnalytics'));
      expect(_code('lib/ui/me_settings_page.dart'), contains('setEnabled'));
    });

    test('政策:Cookie/本地存储与无间接获取', () {
      expect(privacyAll, contains('不使用 Cookie'));
      expect(privacyAll, contains('不从任何第三方间接获取'));
      // 交叉引用修复:联系方式在第九章,不许再写成第八章
      expect(privacyAll, isNot(contains('第八章的联系方式')));
      expect(privacyAll, isNot(contains('第八章联系方式')));
    });
    test('明确不抄的同行条款没被抄进来', () {
      // 微博1.3(禁止用户自行授权第三方使用自己的内容,2017年被全网批评)
      expect(agreementAll, isNot(contains('不得自行授权任何第三方')));
      // 微博3.4/抖音3.12(闲置回收)、B站2.9(无需通知收回账号)
      expect(agreementAll, isNot(contains('未实际使用')));
      expect(agreementAll, isNot(contains('收回账号')));
    });
  });

  group('入口 —— 少一个就不算公开', () {
    test('设置页两份文件入口', () {
      final code = _code('lib/ui/me_settings_page.dart');
      expect(code, contains('PrivacyPolicyPage.open'));
      expect(code, contains('UserAgreementPage.open'));
    });
    test('邮箱注册页与手机号注册页都有三链接行', () {
      expect(
        _code('lib/ui/auth/email_sign_in_view.dart'),
        contains('LegalDocLinksRow'),
      );
      expect(
        _code('lib/ui/auth/phone_sign_in_view.dart'),
        contains('LegalDocLinksRow'),
      );
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
      expect(
        xc,
        isNot(contains('NSPrivacyCollectedDataTypePhotosorVideos')),
        reason: '若上线了头像照片上传,先改隐私政策再来申报这一项',
      );
      // ⚠️ 第一版谓词写成了"<true/> 后面跟 Tracking 键",匹配到的其实是
      //    上一行 Linked=true —— 判据匹配错对象。正确判据:每个 Tracking
      //    键的**值**都必须是 false。
      final trackingValues = RegExp(
        r'NSPrivacyCollectedDataTypeTracking</key>\s*<(true|false)/>',
      ).allMatches(xc).map((m) => m.group(1)).toList();
      expect(trackingValues, isNotEmpty);
      expect(
        trackingValues.every((v) => v == 'false'),
        isTrue,
        reason: '任何一项 Tracking=true 都意味着要走 ATT,本产品不追踪',
      );
    });
  });
}
