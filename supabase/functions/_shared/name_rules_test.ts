// handle 规则 + 保留词表的测试。
// 跑:deno test supabase/functions/_shared/name_rules_test.ts
//
// specifier 必须与 tool/edge-deps.lock 逐字一致(见 precis_nickname_test.ts 的说明)。
import { assertEquals, assertThrows } from 'jsr:@std/assert@1.0.19';
import { normalizeHandle, handleError, HandleRejected } from './handle.ts';
import { checkReservedName } from './reserved_names.ts';
import { enforce } from './precis_nickname.ts';

// ── handle:字符集与形状 ───────────────────────────────────────────────
Deno.test('handle 正常值通过并强制小写', () => {
  assertEquals(normalizeHandle('kyle'), 'kyle');
  assertEquals(normalizeHandle('Kyle'), 'kyle');
  assertEquals(normalizeHandle('  KyleW  '), 'kylew');
  assertEquals(normalizeHandle('kyle.wang'), 'kyle.wang');
  assertEquals(normalizeHandle('kyle_w'), 'kyle_w');
  assertEquals(normalizeHandle('a1'), 'a1');
});

Deno.test('handle 拒绝非 ASCII —— 同形字攻击在字符集层面就被排除', () => {
  assertEquals(handleError('张三'), 'bad_charset');
  assertEquals(handleError('kyle王'), 'bad_charset');
  // 西里尔 а(U+0430)冒充拉丁 a:字符集里根本没有它
  assertEquals(handleError('аdmin'), 'bad_charset');
  assertEquals(handleError('kyle-w'), 'bad_charset'); // 连字符不在集内
  assertEquals(handleError('kyle w'), 'bad_charset'); // 空格不在集内
});

Deno.test('handle 长度边界', () => {
  assertEquals(handleError('a'), 'too_short');
  assertEquals(handleError('ab'), null);
  assertEquals(handleError('a'.repeat(32)), null);
  assertEquals(handleError('a'.repeat(33)), 'too_long');
});

Deno.test('handle 首尾与连续标点', () => {
  assertEquals(handleError('.kyle'), 'bad_edge');
  assertEquals(handleError('kyle.'), 'bad_edge');
  assertEquals(handleError('_kyle'), 'bad_edge');
  assertEquals(handleError('kyle_'), 'bad_edge');
  assertEquals(handleError('ky..le'), 'repeated_punct');
  assertEquals(handleError('ky._le'), 'repeated_punct');
  assertEquals(handleError('ky.le_w'), null); // 分开的标点没问题
});

Deno.test('handle 拒绝形如文件名的后缀(为 web 版预留)', () => {
  assertEquals(handleError('avatar.png'), 'looks_like_file');
  assertEquals(handleError('config.json'), 'looks_like_file');
  assertEquals(handleError('kyle.wang'), null); // wang 不是文件后缀
});

Deno.test('normalizeHandle 抛的是 HandleRejected', () => {
  assertThrows(() => normalizeHandle('张三'), HandleRejected);
});

// ── 保留词:两档 ──────────────────────────────────────────────────────
Deno.test('第八条 假冒/仿冒 ⇒ impersonation,直接拒', () => {
  const a = checkReservedName('官方客服');
  assertEquals(a.ok, false);
  assertEquals(a.ok === false && a.kind, 'impersonation');

  const b = checkReservedName('admin');
  assertEquals(b.ok === false && b.kind, 'impersonation');

  // 包含即命中 —— "XX官方"这类也要挡
  assertEquals(checkReservedName('婚礼官方').ok, false);
  assertEquals(checkReservedName('MyAdminAccount').ok, false);
});

Deno.test('第十条 从严核验类 ⇒ strict_review(与直接拒区分开)', () => {
  const v = checkReservedName('中国摄影');
  assertEquals(v.ok, false);
  assertEquals(v.ok === false && v.kind, 'strict_review');
  assertEquals(v.ok === false && v.term, '中国');

  for (const t of ['中华', '中央', '全国', '国家', '国旗', '党徽', '新华社']) {
    assertEquals(checkReservedName(t + '测试').ok, false);
  }
});

Deno.test('普通中文昵称不被误伤', () => {
  assertEquals(checkReservedName('张三').ok, true);
  assertEquals(checkReservedName('新娘的妈妈').ok, true);
  assertEquals(checkReservedName('小王和小李的婚礼').ok, true);
  assertEquals(checkReservedName('Amy').ok, true);
});

// ── 🔑 顺序性质:归一化必须在匹配之前 ──────────────────────────────────
// 这一条是整张表能否生效的前提。顺序反了,表就形同虚设。
Deno.test('🔑 不归一化就匹配 = 全角可绕过;先 enforce 才拦得住', () => {
  const FULLWIDTH_ADMIN = 'Ａｄｍｉｎ'; // Ａｄｍｉｎ

  // 反面:直接检查原始输入 —— 漏掉
  assertEquals(checkReservedName(FULLWIDTH_ADMIN).ok, true);

  // 正面:先过 RFC 8266 enforce(NFKC 把全角折成半角)—— 拦住
  const normalized = enforce(FULLWIDTH_ADMIN);
  assertEquals(normalized, 'Admin');
  assertEquals(checkReservedName(normalized).ok, false);
});

Deno.test('🔑 零宽字符绕过已在 enforce 层被拒,不该指望保留词表兜底', () => {
  const ZWSP = String.fromCodePoint(0x200b);
  // 'ad<ZWSP>min' 对保留词表是不同的字符串 —— 表本身拦不住
  assertEquals(checkReservedName('ad' + ZWSP + 'min').ok, true);
  // 但 enforce 会先把它拒掉,所以这个输入根本走不到保留词检查
  assertThrows(() => enforce('ad' + ZWSP + 'min'));
});
