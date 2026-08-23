// RFC 8266 PRECIS Nickname Profile 实现的测试。
// 跑:deno test supabase/functions/_shared/precis_nickname_test.ts
//
// 铁律:不可见字符一律用 String.fromCodePoint(0x...) 构造,绝不直接粘进源码。
// 粘进去的 NBSP / ZWJ / 零宽空格,下一个读代码的人看不出那里有东西,
// 改坏了也发现不了 —— 而这份测试的全部意义就是盯住这些看不见的东西。
//
// CI 目前**不跑** deno test(.github/workflows/security.yml 只有 deno cache),
// 这份测试在 CI 里是装饰。要它真正生效,必须给 security.yml 加 deno test step。
// 版本 specifier 与 upload-finalize/validate_test.ts 保持逐字一致。
// tool/edge-deps.lock 按 specifier 字符串锁,写 '@1' 而不是 '@1.0.19'
// 会被 CI 的 `deno cache --frozen` 判为 lockfile out of date 而直接挂。
import { assertEquals, assertThrows } from 'jsr:@std/assert@1.0.19';
import {
  enforce,
  compareKey,
  equivalent,
  graphemeLength,
  NicknameRejected,
} from './precis_nickname.ts';

const cp = String.fromCodePoint;

const NBSP = cp(0x00a0);          // NO-BREAK SPACE (Zs)
const IDEO_SPACE = cp(0x3000);    // IDEOGRAPHIC SPACE (Zs) —— 中文输入法常见
const EM_SPACE = cp(0x2003);      // EM SPACE (Zs)
const ZWJ = cp(0x200d);           // ZERO WIDTH JOINER —— emoji 序列需要
const VS16 = cp(0xfe0f);          // VARIATION SELECTOR-16 —— emoji 呈现需要
const ZWSP = cp(0x200b);          // ZERO WIDTH SPACE —— 无正当昵称用途
const BOM = cp(0xfeff);           // ZERO WIDTH NO-BREAK SPACE / BOM
const CTRL = cp(0x0001);          // 控制字符 (Cc)
const COMBINING_DOT = cp(0x0307); // COMBINING DOT ABOVE
const HEART = cp(0x2764);
const MAN = cp(0x1f468);
const WOMAN = cp(0x1f469);
const GIRL = cp(0x1f467);
const FAMILY = MAN + ZWJ + WOMAN + ZWJ + GIRL;

// ── RFC 8266 §2.1 原文给出的两个例子,逐字当测试用 ────────────────────
Deno.test("RFC 原文例(b): 'stpeter ' 去尾部空格", () => {
  assertEquals(enforce('stpeter '), 'stpeter');
});

Deno.test("RFC 原文例(c): 'St  Peter' 内部双空格折叠为一个", () => {
  assertEquals(enforce('St  Peter'), 'St Peter');
});

// ── Additional Mapping (a):非 ASCII 空格 → U+0020 ────────────────────
Deno.test('非 ASCII 空格全部映射为 U+0020', () => {
  assertEquals(enforce(NBSP + '张三' + NBSP), '张三');
  assertEquals(enforce('张' + IDEO_SPACE + '三'), '张 三');
  assertEquals(enforce('张' + EM_SPACE + EM_SPACE + '三'), '张 三');
});

// ── Normalization: NFKC ───────────────────────────────────────────────
Deno.test('NFKC 折叠全角/兼容字符 —— 中文场景真正需要的那一条', () => {
  assertEquals(enforce('ＡＢＣ'), 'ABC');
  assertEquals(enforce('Ａｄｍｉｎ'), 'Admin'); // 全角冒充,归一化后现形
  assertEquals(enforce('①'), '1');
  assertEquals(enforce('㈱'), '(株)');
});

// ── Enforcement vs Comparison ─────────────────────────────────────────
Deno.test('§2.3 SHOULD:enforcement 保留大小写,comparison 才折叠', () => {
  assertEquals(enforce('StPeter'), 'StPeter');
  assertEquals(compareKey('StPeter'), 'stpeter');
  assertEquals(compareKey('STPETER'), 'stpeter');
});

Deno.test('§2.4 equivalent:大小写/空格/全角差异都算同一个昵称', () => {
  assertEquals(equivalent('StPeter', 'stpeter'), true);
  assertEquals(equivalent('St  Peter', 'st peter'), true);
  assertEquals(equivalent('ＡＢＣ', 'abc'), true);
  assertEquals(equivalent('张三', '李四'), false);
});

// ── §2.3 的 MUST:归一化后不得为零长度 ────────────────────────────────
Deno.test('MUST 非零长度 —— 纯空格必须被拒(长度校验必须在归一化之后)', () => {
  assertThrows(() => enforce(''), NicknameRejected);
  assertThrows(() => enforce('   '), NicknameRejected);
  assertThrows(() => enforce(IDEO_SPACE + IDEO_SPACE), NicknameRejected);
  assertThrows(() => enforce(NBSP), NicknameRejected);
});

// ── Preparation ───────────────────────────────────────────────────────
Deno.test('控制字符被拒', () => {
  assertThrows(() => enforce('张' + CTRL + '三'), NicknameRejected);
  assertThrows(() => enforce('张\n三'), NicknameRejected);
});

Deno.test('零宽空格被拒 —— 即使放行 emoji 也不放行它(可绕过保留词匹配)', () => {
  assertThrows(() => enforce('ad' + ZWSP + 'min'), NicknameRejected);
  assertThrows(() => enforce('张' + ZWSP + '三'), NicknameRejected);
  assertThrows(() => enforce(BOM + '张三'), NicknameRejected);
});

Deno.test('emoji 的 ZWJ / 变体选择符默认放行(对 RFC 的有意偏离)', () => {
  assertEquals(enforce(HEART + VS16).length > 0, true);
  assertEquals(enforce(FAMILY).length > 0, true);
});

Deno.test('allowEmojiJoiners:false 回到严格 RFC 行为', () => {
  const strict = { allowEmojiJoiners: false };
  assertThrows(() => enforce(HEART + VS16, strict), NicknameRejected);
  assertThrows(() => enforce(FAMILY, strict), NicknameRejected);
});

// ── 中文场景不被误伤 ──────────────────────────────────────────────────
Deno.test('中文昵称原样通过', () => {
  assertEquals(enforce('张三'), '张三');
  assertEquals(enforce('新娘的妈妈'), '新娘的妈妈');
  assertEquals(enforce('小王 和 小李'), '小王 和 小李');
  assertEquals(enforce('Amy的婚礼'), 'Amy的婚礼');
});

// ── 长度:字素簇 vs 码点 ──────────────────────────────────────────────
Deno.test('graphemeLength 按字素簇计,揭示 char_length 的口径问题', () => {
  assertEquals(graphemeLength('张三'), 2);
  assertEquals(graphemeLength('abc'), 3);
  assertEquals(graphemeLength(FAMILY), 1);
  assertEquals(FAMILY.length, 8); // ← char_length(1,50) 口径失真的证据
});

// ── 大小写疑难字符:钉住 JS 侧实际行为,供跨实现对拍 ────────────────────
// 验证层指出 Postgres lower() 与 RFC 的 Unicode toLowerCase() 在这几个字符上
// 可能不一致。这里不断言"应该等于什么",而是把 JS 侧结果钉下来:
// 将来若把折叠挪到 DB 侧,拿这几条对拍就能立刻发现分歧。
Deno.test('大小写疑难字符:钉住 JS 侧行为供跨实现对拍', () => {
  assertEquals(compareKey(cp(0x0130)), 'i' + COMBINING_DOT); // İ
  assertEquals(compareKey(cp(0x00df)), cp(0x00df));          // ß 不展开成 ss
  assertEquals(compareKey(cp(0x03a3)), cp(0x03c3));          // Σ -> σ
  assertEquals(compareKey(cp(0x03c2)), cp(0x03c2));          // final sigma 不归并
  assertEquals(equivalent(cp(0x03a3), cp(0x03c2)), false);
});

// ── RFC 8266 §3 的 10 个官方示例向量 ────────────────────────────────
// 这是规范自带的一致性测试集,比任何自造用例都权威。
//
// 🔑 它抓到了本实现最初的一个真缺陷:§2.1 要求"反复应用规则直到输出稳定,
//    首次之后再 3 次仍不稳定则拒绝",而第一版是**单次应用** ——
//    对拍结果 9 passed / 1 failed,失败的正是 RFC 自己标注有幂等性问题的例 8。
//    补上收敛循环后 10/10。教训:自造用例只能证明"我以为的"是对的。
Deno.test('RFC 8266 §3 官方示例向量(10 条)', () => {
  const c = String.fromCodePoint;
  const vectors: Array<[string, string, string]> = [
    ['Foo', 'foo', '#1'],
    ['foo', 'foo', '#2'],
    ['Foo Bar', 'foo bar', '#3'],
    ['foo bar', 'foo bar', '#4'],
    [c(0x03a3), c(0x03c3), '#5 Sigma -> sigma'],
    [c(0x03c3), c(0x03c3), '#6 sigma -> sigma'],
    [c(0x03c2), c(0x03c2), '#7 final sigma 不归并'],
    [c(0x03d4), c(0x03cb), '#8 需要收敛循环才能得到此值'],
    [c(0x221e), c(0x221e), '#9 INFINITY 原样'],
    ['Richard ' + c(0x2163), 'richard iv', '#10 罗马数字 NFKC'],
  ];
  for (const [input, want, label] of vectors) {
    assertEquals(compareKey(input), want, label);
  }
});

Deno.test('§2.1 收敛:comparison 的输出再跑一次必须不变', () => {
  const c = String.fromCodePoint;
  for (const s of ['Foo Bar', c(0x03d4), c(0x03a3), 'Richard ' + c(0x2163), '张三']) {
    const once = compareKey(s);
    assertEquals(compareKey(once), once, `不幂等: ${JSON.stringify(s)}`);
  }
});
