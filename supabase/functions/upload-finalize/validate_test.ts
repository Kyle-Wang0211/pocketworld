// upload-finalize 的判定逻辑单测。
//
// 这是**服务端强制点**的核心,必须逐条覆盖伪装场景 —— 客户端那份
// (lib/util/file_signature.dart)只挡误操作,这份挡攻击者。
//
// 跑:deno test --allow-none supabase/functions/upload-finalize/validate_test.ts

import { assertEquals } from 'jsr:@std/assert@1';
import { validate } from './index.ts';

const b = (...n: number[]) => new Uint8Array(n);
const ascii = (s: string, pad = 0) =>
  new Uint8Array([...new TextEncoder().encode(s), ...new Array(pad).fill(0)]);

/// 构造一个头部自洽的 GLB:magic 'glTF' + version + 小端 uint32 总长
function glb(totalLen: number): Uint8Array {
  const u = new Uint8Array(16);
  u.set(new TextEncoder().encode('glTF'), 0);
  u[4] = 2;
  new DataView(u.buffer).setUint32(8, totalLen, true);
  return u;
}

Deno.test('放行:合法 PLY', () => {
  const v = validate(ascii('ply\nformat binary_little_endian 1.0\n'), 999, 'u/h.ply');
  assertEquals(v.ok, true);
});

Deno.test('放行:GLB 且声明长度与实际大小一致', () => {
  const v = validate(glb(1024), 1024, 'u/m.glb');
  assertEquals(v.ok, true);
});

Deno.test('🔑 拒绝:GLB 声明长度与实际不符(polyglot/尾部附加载荷)', () => {
  // 魔数完全合法,只有长度对不上 —— 这正是单看魔数挡不住的那一类。
  const v = validate(glb(1024), 999999, 'u/m.glb');
  assertEquals(v.ok, false);
  if (!v.ok) assertEquals(v.reason.startsWith('glb_length_mismatch'), true);
});

Deno.test('拒绝:Windows PE 伪装成 .ply', () => {
  const v = validate(b(0x4d, 0x5a, 0x90, 0x00), 4096, 'u/x.ply');
  assertEquals(v.ok, false);
  if (!v.ok) assertEquals(v.reason, 'exe_mz');
});

Deno.test('拒绝:Linux ELF 伪装成 .glb', () => {
  const v = validate(b(0x7f, 0x45, 0x4c, 0x46, 2, 1, 1, 0), 4096, 'u/x.glb');
  assertEquals(v.ok, false);
  if (!v.ok) assertEquals(v.reason, 'exe_elf');
});

Deno.test('拒绝:shell 脚本', () => {
  const v = validate(ascii('#!/bin/sh\nrm -rf /'), 100, 'u/x.ply');
  assertEquals(v.ok, false);
  if (!v.ok) assertEquals(v.reason, 'shebang');
});

Deno.test('拒绝:ZIP(GLB 是容器,zip 炸弹向量)', () => {
  const v = validate(b(0x50, 0x4b, 0x03, 0x04), 100, 'u/x.glb');
  assertEquals(v.ok, false);
  if (!v.ok) assertEquals(v.reason, 'zip');
});

Deno.test('拒绝:HTML 伪装成 .ply(XSS 向量)', () => {
  const v = validate(ascii('<html><script>alert(1)</script>'), 100, 'u/x.ply');
  assertEquals(v.ok, false);
  if (!v.ok) assertEquals(v.reason, 'not_ply');
});

Deno.test('🔑 拒绝:带 XML 序言的 SVG —— 正向白名单才拦得住', () => {
  // 核查实测:file-type 对这种输入返回**定义值**(application/xml),
  // 所以"探测到 undefined 才拒绝"的写法会恰好放行它。
  // 正向白名单不受影响:.ply 只认 'ply' 开头。
  const v = validate(
    ascii('<?xml version="1.0"?>\n<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>'),
    200, 'u/x.ply');
  assertEquals(v.ok, false);
});

Deno.test('拒绝:未知后缀,即便内容合法', () => {
  const v = validate(ascii('ply\nformat'), 100, 'u/x.exe');
  assertEquals(v.ok, false);
  if (!v.ok) assertEquals(v.reason.startsWith('unsupported_ext'), true);
});

Deno.test('拒绝:过短内容', () => {
  assertEquals(validate(b(0x70), 1, 'u/x.ply').ok, false);
});

Deno.test('size=0 时跳过长度校验(元数据缺失不应误杀合法文件)', () => {
  assertEquals(validate(glb(1024), 0, 'u/m.glb').ok, true);
});
