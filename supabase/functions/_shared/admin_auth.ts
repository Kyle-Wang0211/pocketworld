// 管理端鉴权:调用方必须持有本项目的 service secret。
// =====================================================================
// 为什么单独成文件:admin-moderate-work 与 admin-approve-work 用同一套判据。
// 分散在两处 = 迟早分叉,而这是安全关键路径 —— 一处修好另一处还开着,
// 比两处都坏更危险(会误以为已经修完)。
//
// ⚠️ 2026-08-23 实测发现的坑,必读:
//   本项目 Edge Function 环境里的 `SUPABASE_SERVICE_ROLE_KEY` **已经是 41 字符
//   的新格式 secret(sb_secret_*)**,不是 `supabase projects api-keys` 返回的
//   那个 219 字符 legacy JWT —— 尽管官方迁移文档写的是"legacy 值保持不变"。
//   后果:任何拿 CLI 里那个 service_role JWT 去调管理端的请求一律 403。
//   admin-moderate-work 此前就是这个状态,**它的下架功能一直调不通**,
//   只是从来没人真正调过所以没被发现。
//
//   `supabase projects api-keys --output json` 里,只有这个 secret 的
//   `masked=true` —— CLI 不给全文。要拿它必须去 Dashboard:
//     Project Settings → API Keys → Secret keys → 复制 `default`
//
// 官方对 SUPABASE_SECRET_KEYS 的读法(docs 原文):
//   `JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS')!)['default']`
//   —— 它是一个按名字索引的 JSON 对象,不是字符串或数组。

/** 收集本环境所有可接受的管理端 secret(新旧体系都收)。 */
export function acceptedAdminSecrets(): string[] {
  const out: string[] = [];
  const legacy = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (legacy) out.push(legacy);
  try {
    const named = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') ?? '{}');
    for (const v of Object.values(named)) {
      if (typeof v === 'string' && v.length > 0) out.push(v);
    }
  } catch {
    // 环境里没有 SECRET_KEYS 或不是 JSON —— 退回只认 SERVICE_ROLE_KEY。
    // 这不是错误:自托管或旧项目本来就可能没有新体系的变量。
  }
  return out;
}

/**
 * 校验 Authorization: Bearer <secret>。
 *
 * ⚠️ 循环里**不短路** —— 即便已经匹配上也把剩下的比完,让耗时不随
 *    "第几个匹配"变化。timingSafeEqual 本身已是定长比较。
 */
export function isAdminRequest(req: Request): boolean {
  const bearer = (req.headers.get('Authorization') ?? '')
    .replace(/^Bearer\s+/i, '')
    .trim();
  if (!bearer) return false;
  let ok = false;
  for (const k of acceptedAdminSecrets()) {
    if (timingSafeEqual(bearer, k)) ok = true;
  }
  return ok;
}

export function timingSafeEqual(a: string, b: string): boolean {
  const enc = new TextEncoder();
  const ab = enc.encode(a);
  const bb = enc.encode(b);
  let diff = ab.length ^ bb.length;
  const n = Math.max(ab.length, bb.length);
  for (let i = 0; i < n; i++) {
    diff |= (ab[i] ?? 0) ^ (bb[i] ?? 0);
  }
  return diff === 0;
}
