// handle(唯一标识)的规则。与 display_name(可重复展示名)是两轨,别混。
// =====================================================================
// 为什么 handle 限制成纯 ASCII 而 display_name 不限:
//
//   RFC 8265 的 UsernameCaseMapped profile 基于 IdentifierClass,理论上允许
//   Unicode。但 Discord 2023-05-03 的公告把唯一 username 收窄到
//   "lowercase characters (a-z), numbers (0-9) and two special characters
//    (period and underscore)",微信号同样是纯英文(字母开头)。
//
//   照抄这个收窄不是偷懒,它让三个问题**一次性消失**:
//     · 同形字冒充(西里尔 а 冒充拉丁 a)—— 字符集里根本没有西里尔
//     · 大小写折叠的边界字符(İ / ß / ς 在不同实现下行为不一致)—— 强制小写 ASCII
//     · UTS #39 confusables 检测 —— 不需要引入 confusables.txt 与它的 Unicode 版本依赖
//
//   代价是中文用户的 handle 只能是英文。这与微信号一致,是有先例的取舍。
//   真正给中文用户看的是 display_name,那一轨走 RFC 8266,中文/emoji 都放行。
//
// ⚠️ 与 display_name 的分工:
//     handle       唯一、可改但有冷却、用于"找得到人"
//     display_name 可重复、随时可改(仍受冷却)、用于展示
//   RFC 8266 §1.1 明确:昵称不是身份,"authentication and authorization
//   decisions MUST be made on the basis of the thing's identity, not its
//   nickname" ⇒ 这两列都**永远不做**鉴权判据,RLS 一律继续用 user id。

export type HandleError =
  | 'too_short'
  | 'too_long'
  | 'bad_charset'
  | 'bad_edge'        // 首尾不能是 . 或 _
  | 'repeated_punct'  // 不能出现连续的标点
  | 'looks_like_file'; // 形如 xxx.json / xxx.png

export class HandleRejected extends Error {
  constructor(readonly reason: HandleError) {
    super(`handle rejected: ${reason}`);
  }
}

// Discord 口径。改这两个数之前先想清楚:已存在的 handle 不会被追溯校验。
export const HANDLE_MIN = 2;
export const HANDLE_MAX = 32;

// Discourse 的 UsernameValidator 会拦"看起来像文件名"的后缀,理由是它们与
// 路由/静态资源冲突。本产品的 handle 目前不进 URL(Flutter 客户端),但 web 版
// 一旦出现就会进,届时补规则比迁移存量 handle 便宜得多 —— 所以现在就拦。
const FILE_SUFFIXES = [
  'json', 'png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'html', 'htm',
  'js', 'css', 'xml', 'txt', 'pdf', 'zip', 'rss', 'atom',
];

/**
 * 规范化并校验 handle。返回的就是**入库值**(已小写)。
 *
 * 注意这里没有 enforcement/comparison 之分 —— 因为规范化后 handle 本身就是
 * 小写 ASCII,存储值与比较值相同。这正是把字符集收窄到 ASCII 换来的简化:
 * display_name 那边需要两列(见 precis_nickname.ts),handle 只需要一列。
 */
export function normalizeHandle(input: string): string {
  const h = input.trim().toLowerCase();

  if (h.length < HANDLE_MIN) throw new HandleRejected('too_short');
  if (h.length > HANDLE_MAX) throw new HandleRejected('too_long');
  if (!/^[a-z0-9._]+$/.test(h)) throw new HandleRejected('bad_charset');
  if (/^[._]|[._]$/.test(h)) throw new HandleRejected('bad_edge');
  if (/[._]{2,}/.test(h)) throw new HandleRejected('repeated_punct');

  const lastDot = h.lastIndexOf('.');
  if (lastDot > 0 && FILE_SUFFIXES.includes(h.slice(lastDot + 1))) {
    throw new HandleRejected('looks_like_file');
  }
  return h;
}

/** 不抛异常的版本,给客户端做输入即时提示用。 */
export function handleError(input: string): HandleError | null {
  try {
    normalizeHandle(input);
    return null;
  } catch (e) {
    return e instanceof HandleRejected ? e.reason : null;
  }
}
