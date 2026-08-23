// specifier 必须与 tool/edge-deps.lock 逐字一致。
import { assertEquals } from 'jsr:@std/assert@1.0.19';
import { cooldownLeft, RENAME_COOLDOWN_MS } from './rename_cooldown.ts';

const DAY = 24 * 60 * 60 * 1000;
const NOW = Date.parse('2026-08-23T12:00:00.000Z');

Deno.test('冷却期就是 Discourse 的 3 天默认值', () => {
  assertEquals(RENAME_COOLDOWN_MS, 3 * DAY);
});

Deno.test('首次设置不受冷却限制', () => {
  assertEquals(cooldownLeft(null, NOW), 0);
});

Deno.test('刚改完 ⇒ 还要等接近整个冷却期', () => {
  const justNow = new Date(NOW - 1000).toISOString();
  assertEquals(cooldownLeft(justNow, NOW), RENAME_COOLDOWN_MS - 1000);
});

Deno.test('冷却期内 ⇒ 返回剩余毫秒', () => {
  const oneDayAgo = new Date(NOW - DAY).toISOString();
  assertEquals(cooldownLeft(oneDayAgo, NOW), 2 * DAY);
});

Deno.test('刚好满 3 天 ⇒ 放行', () => {
  const exactly = new Date(NOW - 3 * DAY).toISOString();
  assertEquals(cooldownLeft(exactly, NOW), 0);
});

Deno.test('超过 3 天 ⇒ 放行', () => {
  const longAgo = new Date(NOW - 30 * DAY).toISOString();
  assertEquals(cooldownLeft(longAgo, NOW), 0);
});

Deno.test('脏时间戳按放行处理 —— 不能因一条坏数据把用户永久锁在旧名字上', () => {
  assertEquals(cooldownLeft('not-a-date', NOW), 0);
  assertEquals(cooldownLeft('', NOW), 0);
});
