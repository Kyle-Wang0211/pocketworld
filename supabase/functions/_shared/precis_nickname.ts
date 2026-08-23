// PRECIS Nickname Profile — RFC 8266 的实现
// =====================================================================
// 为什么是这份 RFC 而不是别的:
//   RFC 8266 的标题就是《Preparation, Enforcement, and Comparison of
//   Internationalized Strings Representing **Nicknames**》,Abstract 第一句
//   写的是 "nicknames, display names, or petnames" —— 与 profiles.display_name
//   逐字对应。Proposed Standard(2017-10),废止 RFC 7700,截至查证之日
//   无 Obsoleted by / Updated by,现行有效。
//
//   ⚠️ 不要用 RFC 8265(Usernames):它基于 IdentifierClass,**禁止空格**、
//   用 NFC 而非 NFKC,是给 @handle 那一轨用的,不是给中文昵称用的。
//   本仓若将来加唯一 handle 列,那一列才走 8265 UsernameCaseMapped。
//
// 三个操作(RFC 8266 §2.2/§2.3/§2.4),必须分清:
//   preparation  — 只检查码点是否属于 FreeformClass
//   enforcement  — Additional Mapping + Normalization。**存储/展示用这个**
//   comparison   — Additional Mapping + Case Mapping + Normalization。**查重用这个**
//
// 🔑 RFC §2.3 有一句 SHOULD 决定了本模块的形状:
//   "An entity SHOULD apply the Case Mapping Rule only during comparison."
//   ⇒ 不要把用户的大小写洗掉再存。存 enforce() 的结果,另存 compareKey()
//     的结果做查重键。两列,不是一列。
//
// 🔑 RFC §2.4 定义"两个昵称算不算同一个":
//   "The two strings are to be considered equivalent if and only if they are
//    an exact octet-for-octet match (sometimes called 'bit-string identity')"
//   ⇒ 查重 = 对 compareKey() 的输出做等值比较/建唯一索引,不需要任何模糊匹配。
//
// ⚠️ 与 RFC 的两处已知偏离,已在下方各自标注:
//   (1) preparation 的 FreeformClass 判定是**保守近似**,不是完整实现;
//   (2) emoji 的 ZWJ / 变体选择符按 RFC 应被 FreeformClass 拒绝
//       (RFC 8266 全文未提 emoji),本模块给了开关,默认放行 —— 这是偏离。

/** RFC 8266 §2.4 的比较顺序常量,仅用于文档化,勿改。 */
export const RFC8266_COMPARISON_ORDER = [
  'additional-mapping',
  'case-mapping',
  'normalization',
] as const;

export type NicknameError =
  | 'empty_after_enforcement'  // §2.3 的 MUST:归一化后不得为零长度
  | 'not_idempotent'           // §2.1:反复应用 3 次仍不收敛 ⇒ 必须拒绝
  | 'control_character'
  | 'unassigned_or_surrogate'
  | 'ignorable_character';

export class NicknameRejected extends Error {
  constructor(readonly reason: NicknameError) {
    super(`nickname rejected: ${reason}`);
  }
}

export interface PrepareOptions {
  /**
   * 是否放行 Default_Ignorable_Code_Point(含 ZWJ U+200D 与变体选择符 U+FE0F)。
   *
   * 严格按 RFC 8266,FreeformClass 排除 ignorable ⇒ 应为 false,
   * 但那样 👨‍👩‍👧 这类 ZWJ emoji 序列与 ❤️ 都会被拒。
   * 默认 true = **有意偏离 RFC**,以容纳 emoji 昵称。
   * 若产品决定不支持 emoji 昵称,把这里改成 false 即回到严格 RFC 行为。
   */
  allowEmojiJoiners?: boolean;
}

const DEFAULT_OPTS: Required<PrepareOptions> = { allowEmojiJoiners: true };

// ── Additional Mapping Rule(RFC 8266 §2.1)────────────────────────────
// 原文三条,逐条实现,顺序即 RFC 给出的顺序:
//   (a) "Map any instances of non-ASCII space to SPACE (U+0020)"
//       RFC 限定为 general category Zs ⇒ \p{Zs} 去掉 U+0020 本身。
//   (b) "Remove any instances of the ASCII space character at the beginning
//        or end of a nickname"                    例:'stpeter ' → 'stpeter'
//   (c) "Map interior sequences of more than one ASCII space character to a
//        single ASCII space character"            例:'St  Peter' → 'St Peter'
function additionalMapping(s: string): string {
  return s
    .replace(/\p{Zs}/gu, (ch) => (ch === ' ' ? ch : ' ')) // (a)
    .replace(/^ +| +$/g, '')                              // (b)
    .replace(/ {2,}/g, ' ');                              // (c)
}

// ── Preparation(RFC 8266 §2.2)────────────────────────────────────────
// 完整的 FreeformClass 判定需要 Unicode 属性全表(RFC 8264 §4.3),这里做
// **保守近似**:拒绝明确有害的几类,放行其余。近似的方向是"宁可放行",
// 因为真正的安全边界在下游的敏感词/保留词层,不在这里。
export function prepare(input: string, opts: PrepareOptions = {}): void {
  const o = { ...DEFAULT_OPTS, ...opts };
  // 控制字符(Cc)与代理/未分配/私用区:任何情况下都不该出现在昵称里
  if (/\p{Cc}/u.test(input)) throw new NicknameRejected('control_character');
  if (/[\p{Cs}\p{Co}\p{Cn}]/u.test(input)) {
    throw new NicknameRejected('unassigned_or_surrogate');
  }
  // Default_Ignorable 整类里,只有 ZWJ(U+200D)与变体选择符(U+FE00..U+FE0F)
  // 是 emoji 真正需要的。其余(U+200B ZWSP、U+200C ZWNJ、U+2060 WJ、U+FEFF BOM…)
  // 没有正当昵称用途,却可以插进任意位置来:
  //   - 绕过保留词/敏感词匹配('ad<ZWSP>min' 匹配不到 'admin')
  //   - 制造视觉完全相同但字节不同的昵称
  // 所以放行 emoji ≠ 放行整个 ignorable 类。这里按码点白名单放行。
  const ignorable = input.match(/\p{Default_Ignorable_Code_Point}/gu) ?? [];
  for (const ch of ignorable) {
    const cp = ch.codePointAt(0)!;
    const isEmojiJoiner = cp === 0x200d || (cp >= 0xfe00 && cp <= 0xfe0f);
    if (!isEmojiJoiner || !o.allowEmojiJoiners) {
      throw new NicknameRejected('ignorable_character');
    }
  }
}

// ── §2.1 的收敛要求(这条最容易抄漏)────────────────────────────────────
// RFC 8266 §2.1 原文要求:**反复应用规则直到输出字符串稳定**;若在首次应用之后
// 再重复 3 次仍未稳定,实现者 MUST 终止并**拒绝**该输入。
//
// 为什么必须有这个循环 —— RFC §3 的例 8 就是活例子:
//   输入 ϔ (U+03D4 GREEK UPSILON WITH DIARESIS AND HOOK SYMBOL)
//   第 1 遍:toLowerCase 不变 → NFKC 得 Ϋ (U+03AB,**大写**)
//   第 2 遍:toLowerCase 得 ϋ (U+03CB,小写) → NFKC 不变 ⇒ 收敛
//   RFC §3 表格里给的期望值正是 U+03CB —— 也就是**跑到稳定之后**的值。
//   只跑一遍会停在 U+03AB,与官方示例表对不上。
//   (2026-08-23:本实现最初就是单次应用,是拿 RFC §3 的 10 个官方向量对拍
//    才发现漏了这条 —— 9 passed / 1 failed,失败的正是例 8。)
//
// 拒绝不收敛的输入也有安全价值:同一个字符串在不同实现、不同 Unicode 版本下
// 可能收敛到不同结果,放行它等于放行一个"看谁先算"的歧义标识。
function untilStable(input: string, step: (x: string) => string): string {
  let cur = step(input);
  for (let i = 0; i < 3; i++) {
    const next = step(cur);
    if (next === cur) return cur;
    cur = next;
  }
  throw new NicknameRejected('not_idempotent');
}

// ── Enforcement(RFC 8266 §2.3)────────────────────────────────────────
// 顺序:1 Additional Mapping → 2 Normalization(NFKC)。**不折大小写**。
// 末尾那条 MUST:"the entity MUST ensure that the nickname is not zero bytes
// in length" —— 注意它在归一化**之后**,所以长度校验也必须在这之后做,
// 否则 '   '(纯空格)会先通过 char_length>=1 再变成空串。
export function enforce(input: string, opts: PrepareOptions = {}): string {
  prepare(input, opts);
  const out = untilStable(input, (x) => additionalMapping(x).normalize('NFKC'));
  if (out.length === 0) throw new NicknameRejected('empty_after_enforcement');
  return out;
}

// ── Comparison(RFC 8266 §2.4)─────────────────────────────────────────
// 顺序:1 Additional Mapping → 2 Case Mapping → 3 Normalization。
// ⚠️ toLowerCase() 在 NFKC **之前**,这是 RFC 写死的顺序,不要图省事调换。
export function compareKey(input: string, opts: PrepareOptions = {}): string {
  prepare(input, opts);
  const out = untilStable(
    input,
    (x) => additionalMapping(x).toLowerCase().normalize('NFKC'),
  );
  if (out.length === 0) throw new NicknameRejected('empty_after_enforcement');
  return out;
}

/** RFC 8266 §2.4:当且仅当两串的 comparison 输出逐字节相同才算同一个昵称。 */
export function equivalent(a: string, b: string, opts: PrepareOptions = {}): boolean {
  return compareKey(a, opts) === compareKey(b, opts);
}

// ── 长度:按字素簇计,不按码点 ──────────────────────────────────────
// RFC 8266 / UTS #39 都不规定长度。但 char_length()/String.length 数的是
// 码点(JS 里甚至是 UTF-16 code unit),一个中文字=1,一个 ZWJ 家庭 emoji=7+,
// 同一个上限对不同用户宽严差好几倍。Discourse 的做法是按 grapheme cluster
// 计数(UAX #29),这里照抄。
const SEGMENTER = new Intl.Segmenter(undefined, { granularity: 'grapheme' });
export function graphemeLength(s: string): number {
  let n = 0;
  for (const _ of SEGMENTER.segment(s)) n++;
  return n;
}
