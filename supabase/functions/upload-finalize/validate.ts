// upload-finalize 的**纯校验规则**,从 index.ts 抽出来单独成文件。
//
// 为什么必须抽出来:index.ts 顶层是 `Deno.serve(...)`,import 它就会启动
// HTTP 服务。于是 validate_test.ts 里的 `import { validate } from './index.ts'`
// 会让 deno test 直接报
//   "This error was not caught from a test and caused the test runner to fail
//    on the referenced module ... top-level code"
// —— 换句话说,那 12 个用例**从来没有真正跑过**,不只是 CI 不跑,本地也跑不了。
// (文件头写的 `deno test --allow-none` 也不是合法的 Deno 权限标志。)
//
// 规则本身一个字没改,这是纯搬家。搬完 index.ts 从这里 import。

export type Verdict = { ok: true; kind: string } | { ok: false; reason: string };
// ── 校验规则 ─────────────────────────────────────────────────────────
// 与客户端 lib/util/file_signature.dart **同一套规则**,刻意保持一致:
// 客户端那份挡误操作,这份是强制点。两端标准不一致会造成"客户端说行、
// 服务端说不行"的困惑,反之则是安全洞。
export function validate(head: Uint8Array, size: number, path: string): Verdict {
  if (head.length < 4) return { ok: false, reason: 'too_short' };

  // ② 可执行体特征优先判 —— 命中即拒,不再往下看。
  if (startsWith(head, [0x4d, 0x5a])) return { ok: false, reason: 'exe_mz' };
  if (startsWith(head, [0x7f, 0x45, 0x4c, 0x46])) return { ok: false, reason: 'exe_elf' };
  if (startsWith(head, [0x23, 0x21])) return { ok: false, reason: 'shebang' };
  if (startsWith(head, [0x50, 0x4b, 0x03, 0x04])) return { ok: false, reason: 'zip' };
  if (startsWith(head, [0xca, 0xfe, 0xba, 0xbe])) return { ok: false, reason: 'macho_fat' };

  const ext = path.toLowerCase().slice(path.lastIndexOf('.') + 1);

  // ① 正向白名单:只放行明确认识的类型。
  if (ext === 'ply') {
    if (!startsWithAscii(head, 'ply')) return { ok: false, reason: 'not_ply' };
    return { ok: true, kind: 'ply' };
  }

  if (ext === 'glb') {
    if (!startsWithAscii(head, 'glTF')) return { ok: false, reason: 'not_glb' };
    // ③ 容器自洽性:GLB 头第 8-11 字节是小端 uint32 总长,必须等于实际大小。
    // 这是挡 polyglot 的那一道 —— 光看魔数挡不住"合法头 + 尾部附加载荷"。
    if (head.length >= 12 && size > 0) {
      const declared = head[8] | (head[9] << 8) | (head[10] << 16) | (head[11] << 24);
      if (declared >>> 0 !== size) {
        return { ok: false, reason: `glb_length_mismatch:${declared >>> 0}!=${size}` };
      }
    }
    return { ok: true, kind: 'glb' };
  }

  // 未知后缀一律拒绝,而不是放行。
  return { ok: false, reason: `unsupported_ext:${ext}` };
}

function startsWith(b: Uint8Array, magic: number[]): boolean {
  if (b.length < magic.length) return false;
  return magic.every((m, i) => b[i] === m);
}

function startsWithAscii(b: Uint8Array, s: string): boolean {
  if (b.length < s.length) return false;
  for (let i = 0; i < s.length; i++) {
    if (b[i] !== s.charCodeAt(i)) return false;
  }
  return true;
}

