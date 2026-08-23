// upload-finalize
// ----------------------------------------------------------------------
// 两阶段上传的第二阶段:校验 staging 里的对象,通过则提升进公开桶。
//
// 这个函数是**直传架构下唯一真正的服务端强制点**。
//
// 为什么客户端校验不够(这也是本函数存在的全部理由):
//   客户端校验挡不住攻击者 —— 他直接改客户端。真正起作用的是这条不变量:
//   **客户端只被授权写永不公开的 staging 桶,公开桶的写权限只有 service_role
//   持有**。客户端能决定的只有"要不要调本函数";它决定不了字节落在哪个桶
//   (路径签在上传 token 里)。跳过本函数的后果是对象静静躺在私有桶里,
//   永远拿不到公开 URL —— 而攻击者的目的正是公开,所以跳过校验收益为零。
//
// 🔑 为什么用 HTTP Range 只读头部,而不是把文件拉下来:
//   Edge Function 官方限额是 **256MB 内存 / 2s CPU**。我们的 PLY 是几十到
//   几百 MB —— 256MB 装不下,2s 也跑不完一次全量哈希。所以"只读头部"不是
//   性能优化,是**唯一可行解**。
//   已在本项目实测确认可行:对 42,977,928 字节的对象请求 `Range: bytes=0-15`,
//   返回 `HTTP 206` + `content-range: bytes 0-15/42977928`,内容正是 `glTF`。
//
// 校验做三件事,单靠任何一件都不够:
//   ① 魔数白名单 —— **正向白名单,不是"未知则放行"**。这一条是被实测教训的:
//      有人推荐"探测返回 undefined 就拒绝",但带 XML 序言的恶意 SVG 会探测出
//      一个**定义值**,照那个逻辑恰好被放行。只放行明确认识的类型才安全。
//   ② 可执行体特征 —— MZ / ELF / shebang / PK,挡"伪装成 .ply 的可执行文件"
//      这类把我们当免费恶意软件 CDN 的滥用。
//   ③ 容器自洽性 —— GLB 头里声明的总长必须等于对象实际大小。OWASP 对魔数
//      校验附有明确警告:"This should not be used on its own, as bypassing it
//      is pretty common and easy"。单看前几字节挡不住 polyglot(前缀是合法
//      PLY 头、尾部附加 payload);把"声明长度 == 实际大小"一起验才挡得住。
//      PLY/GLB 恰好都能精确推算,这是 3D 格式相对图片的优势。
//
// 失败处置:move 进 quarantine 而不是直接删除 —— 保留取证副本,与
// admin-moderate-work 的下架逻辑一致。

import { createClient } from 'jsr:@supabase/supabase-js@2.112.3';
import { corsHeaders, jsonResponse, consumeRateLimit } from '../_shared/cors.ts';
import { validate } from './validate.ts';

const STAGING = 'staging';
const QUARANTINE = 'quarantine';

/// 只读这么多字节就够判定。GLB 头 12 字节 + 第一个 chunk 头 8 字节,
/// PLY 的 ASCII header 通常几百字节内结束。8KB 留足余量且远低于任何预算。
const PROBE_BYTES = 8192;


Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }
  if (req.method !== 'POST') {
    return jsonResponse({ error: 'method_not_allowed' }, 405);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceKey) {
    return jsonResponse({ error: 'server_misconfigured' }, 500);
  }
  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false },
  });

  const bearer = (req.headers.get('Authorization') ?? '')
    .replace(/^Bearer\s+/i, '')
    .trim();
  if (!bearer) return jsonResponse({ error: 'missing_authorization' }, 401);

  const { data: userData, error: userErr } = await admin.auth.getUser(bearer);
  const user = userData?.user;
  if (userErr || !user) return jsonResponse({ error: 'unauthorized' }, 401);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: 'invalid_json' }, 400);
  }

  const stagingPath = typeof body.staging_path === 'string'
    ? body.staging_path.trim()
    : '';
  if (!stagingPath) {
    return jsonResponse({ error: 'missing_staging_path' }, 400);
  }

  // 归属从**路径**判定,不信任请求体里的任何声明。这与 staging_insert_self
  // 策略同源:第一段必须是调用者的 uid。
  if (!stagingPath.startsWith(`${user.id}/`)) {
    return jsonResponse({ error: 'path_not_owned' }, 403);
  }
  if (stagingPath.includes('..') || stagingPath.includes('//')) {
    return jsonResponse({ error: 'invalid_path' }, 400);
  }

  // 限流:本函数会触发 Range 读 + 跨桶 move,都是有成本的操作。
  // 30/小时远高于任何真实发布节奏,又能给失控的客户端循环封顶。
  // fail-open,与其他端点一致 —— 限流器自身故障不该让人发不了作品。
  if (!await consumeRateLimit(admin, `finalize:${user.id}`, 30, 3600)) {
    return jsonResponse({
      error: 'rate_limited',
      message: '短时间内提交次数过多,请稍后再试。',
    }, 429);
  }

  // ── 取对象元数据(拿真实大小,用于容器自洽性校验) ──────────────────
  const dir = stagingPath.slice(0, stagingPath.lastIndexOf('/'));
  const base = stagingPath.slice(stagingPath.lastIndexOf('/') + 1);
  const { data: listed, error: listErr } = await admin.storage
    .from(STAGING)
    .list(dir, { search: base, limit: 1 });
  if (listErr) {
    return jsonResponse({ error: 'staging_lookup_failed', detail: listErr.message }, 500);
  }
  const entry = listed?.find((e) => e.name === base);
  if (!entry) {
    return jsonResponse({ error: 'staging_object_not_found' }, 404);
  }
  const actualSize = Number(
    (entry.metadata as Record<string, unknown> | null)?.size ?? 0,
  );

  // ── Range 只读头部 ────────────────────────────────────────────────
  // 用原始 fetch 带 Range 头,**不用 SDK 的 download()** —— 后者会把整个
  // 对象拉进内存,几百 MB 的 PLY 直接撞爆 256MB 限额,正是这里要避免的事。
  let head: Uint8Array;
  try {
    const res = await fetch(
      `${supabaseUrl}/storage/v1/object/${STAGING}/${
        stagingPath.split('/').map(encodeURIComponent).join('/')
      }`,
      {
        headers: {
          // apikey 与 Authorization **两个都要**。supabase-js SDK 会自动带上
          // apikey,手写 fetch 不会 —— 少了它 Storage 网关直接 400,而错误
          // 信息只说 "not_found",很容易误判成"对象不存在"或"RLS 拒绝"。
          apikey: serviceKey,
          Authorization: `Bearer ${serviceKey}`,
          Range: `bytes=0-${PROBE_BYTES - 1}`,
        },
      },
    );
    // 206 = 服务端履行了 Range(期望路径)。200 = 它忽略了 Range 返回全量,
    // 这时必须自己截断,否则大对象会把内存吃光。
    if (res.status !== 206 && res.status !== 200) {
      return jsonResponse({
        error: 'probe_failed',
        detail: `unexpected status ${res.status}`,
      }, 502);
    }
    const buf = await res.arrayBuffer();
    head = new Uint8Array(buf.byteLength > PROBE_BYTES
      ? buf.slice(0, PROBE_BYTES)
      : buf);
  } catch (e) {
    return jsonResponse({ error: 'probe_failed', detail: String(e) }, 502);
  }

  // ── 判定 ──────────────────────────────────────────────────────────
  const verdict = validate(head, actualSize, stagingPath);
  if (!verdict.ok) {
    // 搬进 quarantine 保留取证,而不是直接删 —— 与下架逻辑一致。
    const qPath = `rejected/${user.id}/${Date.now()}_${base}`;
    await admin.storage
      .from(STAGING)
      .move(stagingPath, qPath, { destinationBucket: QUARANTINE });

    await admin.from('audit_logs').insert({
      actor_id: user.id,
      action: 'upload.rejected_by_validation',
      target_type: 'storage',
      target_id: null,
      ip_address: firstIp(req.headers.get('x-forwarded-for')),
      user_agent: (req.headers.get('user-agent') ?? '').slice(0, 500) || null,
      metadata: {
        staging_path: stagingPath,
        quarantine_path: qPath,
        reason: verdict.reason,
        size: actualSize,
        head_hex: Array.from(head.slice(0, 16))
          .map((b) => b.toString(16).padStart(2, '0')).join(''),
      },
    });

    return jsonResponse({
      error: 'validation_failed',
      reason: verdict.reason,
      message: '文件内容未通过校验,已被拒绝。',
    }, 422);
  }

  // ── 提升进公开桶 ──────────────────────────────────────────────────
  // 目标路径由**服务端**决定,不接受客户端指定 —— 否则等于把公开桶的写入
  // 位置交还给客户端,前面的隔离就白做了。沿用内容寻址的既有约定。
  const targetPath = stagingPath;
  const { error: moveErr } = await admin.storage
    .from(STAGING)
    .move(stagingPath, targetPath, { destinationBucket: 'works' });

  if (moveErr) {
    const msg = moveErr.message ?? String(moveErr);
    // 幂等:重复调用时对象已在 works,视为成功而非失败。
    if (/exists|duplicate/i.test(msg)) {
      return jsonResponse({ ok: true, path: targetPath, already: true });
    }
    return jsonResponse({ error: 'promote_failed', detail: msg }, 502);
  }

  await admin.from('audit_logs').insert({
    actor_id: user.id,
    action: 'upload.promoted',
    target_type: 'storage',
    target_id: null,
    ip_address: firstIp(req.headers.get('x-forwarded-for')),
    user_agent: (req.headers.get('user-agent') ?? '').slice(0, 500) || null,
    metadata: { path: targetPath, kind: verdict.kind, size: actualSize },
  });

  return jsonResponse({ ok: true, path: targetPath, kind: verdict.kind });
});

function firstIp(raw: string | null): string | null {
  if (!raw) return null;
  const first = raw.split(',')[0]?.trim();
  return first && first.length > 0 ? first : null;
}
