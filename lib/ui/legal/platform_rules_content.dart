// 平台公约 / 管理规则的正文。
// =====================================================================
// 为什么需要这个文件(不是可选的产品文案,是两条法定义务):
//
//   《互联网用户账号信息管理规定》第六条:
//     "互联网信息服务提供者应当依照法律、行政法规和国家有关规定,制定和公开
//      互联网用户账号管理规则、平台公约,与互联网用户签订服务协议。"
//   《互联网信息服务深度合成管理规定》第八条同样要求制定并公开管理规则与平台公约。
//
//   注意"**公开**"二字:注册页原本只有一句纯文本"注册即表示你同意……"
//   (email_sign_in_view.dart,注释自陈 "Plain (not link) for now"),
//   点不开、也没有任何页面承载内容 —— 那不构成"公开"。
//
// ⚠️ 本文件写的是**产品当前的实际行为**,不是法律模板。每一条都能在代码里
//    找到对应实现(注释里标了出处)。这样做有两个理由:
//      1. 写实际行为不需要法律创作,写出来就是"管理规则";
//      2. 规则与实现分叉是最常见的合规事故 —— 改了实现忘了改公约,
//         公约就变成了一份不实陈述。把出处标在这里,改代码时才看得见。
//
// 🔴 服务协议(用户协议)与隐私政策是**另外两份文件**,涉及权利义务分配与
//    个人信息处理告知,需要法务准备,不在本文件范围内。见文末 TODO。

class RuleSection {
  final String title;
  final List<String> items;
  const RuleSection(this.title, this.items);
}

/// 中文版为准。产品主要面向中国大陆用户,且法定义务依据的是中文法条。
const List<RuleSection> kPlatformRulesZh = [
  RuleSection('一、账号与名称', [
    '昵称可以重复,ID 全站唯一 —— 这与微信、抖音、小红书的结构一致:昵称用来展示,ID 用来让别人找到你。',
    '昵称最多 20 个字,支持中文、英文与 emoji。首尾空格会被自动去除,中间连续空格会合并为一个。',
    'ID 由 2–32 个小写字母、数字、点或下划线组成,不能以点或下划线开头结尾,也不能出现连续的点或下划线。',
    '昵称与 ID 设置后 3 天内不能再次修改。',
    '不得使用可能被误认为平台官方身份的名称,包括但不限于"官方""客服""管理员""系统通知""小助手"及其英文对应词。',
    '名称中含有"中国""中华""中央""全国""国家"等内容,或涉及国旗、国徽、国歌、党旗、党徽的,将按国家有关规定从严核验。',
    '注册需要通过真实身份信息认证。未完成认证的账号无法发布内容。',
  ]),
  RuleSection('二、作品发布与审核', [
    '作品发布后进入审核状态,审核通过后才会出现在社区广场,在此之前对其他用户不可见。',
    '作品标题不超过 100 字,作品描述不超过 30 字。',
    '不得发布法律法规禁止的内容,包括危害国家安全、淫秽色情、暴力恐怖、虚假信息、侵犯他人权益等。',
    '拍摄涉及他人的场景并公开发布前,应当取得画面中他人的同意。',
    '作品的三维模型文件中包含生成方式标识 —— 这是《互联网信息服务深度合成管理规定》第十六条要求的技术措施,不影响你正常使用文件。',
  ]),
  RuleSection('三、违规处置', [
    '发现违规内容或行为时,平台可以采取以下措施:警示提醒、限期改正、限制账号功能、暂停使用、关闭账号。',
    '违规作品会被下架,其文件将从公开位置移出,已保存的链接同时失效。',
    '你可以随时删除自己的作品。正在审核中且从未公开过的作品同样可以删除。',
    '账号相关的操作会被记录,保存期限不少于 6 个月。',
  ]),
  RuleSection('四、举报与申诉', [
    '每个作品页面都提供举报入口,可选择垃圾信息、骚扰、仇恨言论、色情内容、暴力、侵权、虚假信息等理由。',
    '你也可以屏蔽某个用户,屏蔽后其作品不再出现在你的信息流中。',
    '对处置结果有异议的,可通过下方联系方式申诉。',
  ]),
  RuleSection('五、联系我们', [
    // 🔴 占位:Apple App Store Guideline 1.2 要求 "Published contact information
    //    so users can easily reach you",且必须在 App 内与商店页面**都**可达。
    //    只写在商店页面而 App 内没有,是常见的被拒点。上线前必须替换成真实邮箱。
    '邮箱:[待填写 —— 上线前必须替换为真实可达的联系邮箱]',
    '我们会在收到举报或申诉后尽快处理并反馈。',
  ]),
];

/// 英文版为便利提供,与中文版不一致时**以中文版为准**。
/// (这是中国大陆产品的通行做法,因为法定义务依据的是中文法条。)
const List<RuleSection> kPlatformRulesEn = [
  RuleSection('1. Accounts and Names', [
    'Display names may repeat; your ID is unique across the platform. Display names are for showing, IDs are for being found.',
    'Display names allow up to 20 characters, including Chinese, English and emoji. Leading/trailing spaces are trimmed and internal runs of spaces are collapsed.',
    'IDs consist of 2-32 lowercase letters, digits, dots or underscores. They may not start or end with a dot/underscore, nor contain consecutive ones.',
    'A display name or ID cannot be changed again within 3 days of being set.',
    'Names that could be mistaken for official platform identities are not permitted, including "official", "support", "admin", "system" and their Chinese equivalents.',
    'Names containing national or party symbols are subject to stricter verification under applicable Chinese regulations.',
    'Registration requires real-identity verification. Unverified accounts cannot publish.',
  ]),
  RuleSection('2. Publishing and Review', [
    'Published works enter review and only appear in the community feed after approval. Until then they are not visible to others.',
    'Titles are limited to 100 characters; descriptions to 30.',
    'Content prohibited by law may not be published.',
    'Obtain consent from people appearing in a scene before publishing it publicly.',
    'Exported 3D model files carry a provenance marker, as required by Chinese regulations on deep synthesis services. It does not affect normal use of the file.',
  ]),
  RuleSection('3. Enforcement', [
    'Available measures: warning, required correction within a period, feature restriction, suspension, account closure.',
    'Violating works are taken down and their files removed from public storage; previously saved links stop working.',
    'You may delete your own work at any time, including work still under review that was never public.',
    'Account-related actions are logged and retained for at least 6 months.',
  ]),
  RuleSection('4. Reporting and Appeals', [
    'Every work page provides a reporting entry with categories including spam, harassment, hate speech, sexual content, violence, copyright and misinformation.',
    'You may also block a user; their works will no longer appear in your feed.',
    'To appeal an enforcement decision, use the contact below.',
  ]),
  RuleSection('5. Contact', [
    'Email: [TO BE FILLED — must be a real, reachable address before launch]',
    'We respond to reports and appeals as promptly as we can.',
  ]),
];

// ─────────────────────────────────────────────────────────────────────
// TODO(上线前必须补齐,这两份不在本文件范围内):
//   1. **服务协议/用户协议** —— 第六条要求"与互联网用户签订服务协议"。
//      涉及双方权利义务、内容授权、责任限制、争议解决,需要法务准备。
//   2. **隐私政策** —— 《个人信息保护法》要求的告知同意。本产品采集相机、
//      IMU、可能还有位置与相册,属高敏感采集面。
//      ⚠️ 网信办 2025-02-19 通报里,4 款 App 因"未公开收集使用规则"被
//      **直接下架、无整改期**(另 78 款"缺功能"类才给一个月)。
//      这一档没有"先警告"的缓冲,必须在首次上架前完成。
// ─────────────────────────────────────────────────────────────────────
