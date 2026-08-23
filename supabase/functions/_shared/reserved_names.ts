// 保留词表 —— 昵称与 handle 的名称层拦截。
// =====================================================================
// 本文件是本次调研里**唯一一个"全世界没有现成方案"**的部分。
//
// 查过的现成表,以及为什么都不够用:
//   · The Big Username Blocklist(MIT,542 条):6 类全是路由/权限词
//     (root/null/faq/delete),且**明确不含粗俗词**。它假设 username 会进 URL;
//     本产品的 handle 目前不进 URL,所以这 542 条对我们价值有限。将来做 web 版
//     再引入不迟,引入方式见 FILE_SUFFIXES 之外的补充点。
//   · Discourse / Flarum / NodeBB:默认保留表只有 20 词量级,且全是英文路由词。
//   · konsheng/Sensitive-lexicon(MIT,6万+):**通用**中文敏感词,可做下游的
//     内容审核层,但它不含"冒充平台身份"这一类。
//   · funNLP(82k★)与 textfilter:**license 为 null = 保留全部权利**,
//     中国大陆商用产品不可引入。别被星数骗了。
//
// 所以下面的中文部分是自建的。判据不是我的口味,是两条法条:
//
//   《互联网用户账号信息管理规定》(网信办令第10号)
//   第十条后半段:"对账号信息中含有'中国'、'中华'、'中央'、'全国'、'国家'等
//     内容,或者含有党旗、党徽、国旗、国歌、国徽等党和国家象征和标志的,
//     应当依照法律、行政法规和国家有关规定**从严核验**。"
//     ⇒ 注意条文说的是"从严核验",不是"一律禁止"。所以这类单列一档。
//   第八条:禁止假冒仿冒党政军机关、新闻媒体;禁止"名不副实、夸大其词等
//     可能使公众受骗"的内容。⇒ 冒充平台身份的词属于这一档,直接拒。
//
// ⚠️ 匹配必须发生在**归一化之后**。这不是优化,是正确性前提:
//     · precis_nickname.enforce() 已把全角 'Ａｄｍｉｎ' 折成 'Admin'
//     · prepare() 已拒掉零宽空格,否则 'ad<ZWSP>min' 匹配不到 'admin'
//   先匹配后归一化 = 这张表可以被任意绕过。

export type NameVerdict =
  | { ok: true }
  | { ok: false; kind: 'impersonation'; term: string }
  | { ok: false; kind: 'strict_review'; term: string };

// ── 第一档:冒充平台/官方身份 ⇒ 直接拒 ────────────────────────────────
// 判据是第八条的"假冒、仿冒"与"名不副实、夸大其词等可能使公众受骗"。
// 内容安全 API 拦不住这一类 —— 它不知道本平台谁是官方。
const IMPERSONATION_ZH = [
  '官方', '客服', '管理员', '管理者', '系统通知', '系统消息', '系统公告',
  '平台公告', '平台通知', '小助手', '小秘书', '客服中心', '官方认证',
  '认证中心', '审核员', '审核中心', '运营团队', '官方团队', '内部员工',
];

const IMPERSONATION_EN = [
  'admin', 'administrator', 'moderator', 'official', 'support',
  'staff', 'system', 'root', 'superuser', 'sysadmin', 'help',
  'helpdesk', 'security', 'noreply', 'no-reply', 'webmaster',
];

// ── 第二档:法定从严核验 ⇒ 冷启动阶段同样拒,但错误码不同 ───────────────
// 第十条要求的是"从严核验"而非禁止。有人工审核队列之后,这一档应改为
// 进队列人工判断(UTS #39 把这种处理叫 'soft no':让用户申诉而不是硬拒),
// 而不是像现在这样直接拒。**改的时候只改这一档的处置,不要把词删掉。**
const STRICT_REVIEW_ZH = [
  '中国', '中华', '中央', '全国', '国家', '国务院', '党中央',
  '国旗', '国徽', '国歌', '党旗', '党徽',
  '人民日报', '新华社', '央视', '中央电视台', '共青团', '解放军',
];

/**
 * 检查一个**已归一化**的名称。
 *
 * @param normalized display_name 必须传 precis_nickname.enforce() 的输出;
 *                   handle 必须传 handle.normalizeHandle() 的输出。
 *                   传原始输入 = 这张表形同虚设,见文件头说明。
 */
export function checkReservedName(normalized: string): NameVerdict {
  const lower = normalized.toLowerCase();

  for (const term of IMPERSONATION_ZH) {
    if (normalized.includes(term)) {
      return { ok: false, kind: 'impersonation', term };
    }
  }
  for (const term of IMPERSONATION_EN) {
    if (lower.includes(term)) {
      return { ok: false, kind: 'impersonation', term };
    }
  }
  for (const term of STRICT_REVIEW_ZH) {
    if (normalized.includes(term)) {
      return { ok: false, kind: 'strict_review', term };
    }
  }
  return { ok: true };
}

/** 供测试与运维查看当前词表规模,不参与匹配逻辑。 */
export const RESERVED_COUNTS = {
  impersonationZh: IMPERSONATION_ZH.length,
  impersonationEn: IMPERSONATION_EN.length,
  strictReviewZh: STRICT_REVIEW_ZH.length,
};
