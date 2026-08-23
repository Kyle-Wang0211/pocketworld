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

  // ── kill switch ─────────────────────────────────────────────────────
  // 🔴 为什么必须在这里显式查:收口后 works 的 INSERT 由 service_role 执行,
  //    而 service_role **绕过 RLS** ⇒ kill_switch_works_write
  //    (RESTRICTIVE, for insert to authenticated)对这条新路径完全不生效。
  //    不补这一查,等于把运营手里的刹车拆了 —— 关掉 'uploads' 开关将不再能
  //    阻止新作品创建。
  //
  // ⚠️ 与 consumeRateLimit 相反,这里 **fail-closed**:查不到开关状态就当作
  //    关闭。限流器故障不该让人发不了作品,但"刹车状态未知"必须停车。
  {
    const { data: enabled, error: swErr } = await admin.rpc('uploads_enabled');
    if (swErr || enabled !== true) {
      return jsonResponse({
        error: 'uploads_disabled',
        message: '上传功能暂时关闭,请稍后再试。',
      }, 503);
    }
  }

  // ── 内容字段 ────────────────────────────────────────────────────────
  // 收口后 works 行由本函数创建,所以标题/描述从这里进来并在这里校验。
  // 其余字段(user_id / model_storage_path / file_size_bytes / format)
  // **一律由服务端自己算**,不接受客户端提供 —— 客户端连伪造的机会都没有。
  //
  // 上下限与 DB CHECK 保持一致:title 1..100、description <= 30
  // (20260823000000 把 description 从 5000 收到 30)。这里先拦是为了给出
  // 可读的拒绝理由,而不是让 23514 从数据库里冒出来。
  // 旧客户端(收口前的版本)根本不发 title —— 它自己 INSERT works。
  // 把这种情况与"标题写得不合法"分开报,否则线上会看到一堆 invalid_title,
  // 而真正的原因是装了旧包。旧客户端此刻已经无路可走:迁移 20260823020000
  // 撤了 works_insert_own,它的直写也会被 RLS 拒。
  if (body.title === undefined) {
    return jsonResponse({
      error: 'stale_client',
      message: '请更新 App 后再发布。',
    }, 426); // 426 Upgrade Required
  }
  const title = typeof body.title === 'string' ? body.title.trim() : '';
  if (title.length < 1 || title.length > 100) {
    return jsonResponse({ error: 'invalid_title', reason: 'length' }, 422);
  }
  const rawDesc = typeof body.description === 'string' ? body.description.trim() : '';
  if (rawDesc.length > 30) {
    return jsonResponse({ error: 'invalid_description', reason: 'too_long', max: 30 }, 422);
  }
  const description = rawDesc.length > 0 ? rawDesc : null;
  const visibility = body.visibility === 'private' ? 'private' : 'public';

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

  // 目标路径由**服务端**决定,不接受客户端指定 —— 否则等于把公开桶的写入
  // 位置交还给客户端,前面的隔离就白做了。沿用内容寻址的既有约定。
  const targetPath = stagingPath;

  // ── 建 works 行(先于搬文件)─────────────────────────────────────────
  // 顺序为什么是"先建行、后搬文件",与直觉相反:
  //   通常的担心是"行先出现会在 feed 里生成指向缺失文件的卡片"。但这里落库的
  //   是 moderation_status='under_review' + published_at=null 的行,它被**三层**
  //   挡住,任何人都看不见:
  //     · works_select_visible 要求 visibility='public' AND moderation_status='ok'
  //     · feed 查询带 .not('published_at','is',null)(挡住作者自己)
  //     · storage 的 works_select_public 策略 JOIN works 检查 moderation_status='ok'
  //       ⇒ 连公开桶里的字节都读不到
  //   反过来"先搬后建"才是危险的:INSERT 失败时对象已经在公开桶、staging 已被
  //   搬空,既回不去也没有行指向它 —— 孤儿对象,而 delete-work 只按 works 行删,
  //   没有任何清扫路径能发现它。
  //
  // 🔴 moderation_status 必须**显式**写 'under_review'。该列的 default 是 'ok'
  //    (20260817000000),漏写就是默认放行 —— 这是最容易犯的静默安全洞。
  //    published_at 同理留 null,由审核通过那一刻再补写。
  const workRow = {
    user_id: user.id,
    title,
    description,
    format: verdict.kind,
    model_storage_path: targetPath,
    file_size_bytes: actualSize,
    visibility,
    moderation_status: 'under_review',
    published_at: null,
  };

  let workId: string | null = null;
  // 区分"本次新建"与"23505 回读到的既有行":move 失败要回滚时,只能删前者。
  // 回读到的那行可能对应一次历史上成功的发布,删掉就是误伤。
  let createdNow = false;
  const { data: inserted, error: insErr } = await admin
    .from('works')
    .insert(workRow)
    .select('id')
    .single();

  if (insErr) {
    // 幂等靠 uq_works_user_model_path 唯一索引裁决,而**不是**先 SELECT 再
    // INSERT —— 后者是 TOCTOU 竞态,两个并发请求会同时通过检查。
    if ((insErr as { code?: string }).code === '23505') {
      const { data: existing } = await admin
        .from('works')
        .select('id')
        .eq('user_id', user.id)
        .eq('model_storage_path', workRow.model_storage_path)
        .maybeSingle();
      workId = (existing?.id as string | undefined) ?? null;
      if (!workId) {
        return jsonResponse({ error: 'insert_conflict_unresolved' }, 500);
      }
    } else {
      return jsonResponse({ error: 'insert_failed', detail: insErr.message }, 500);
    }
  } else {
    workId = inserted.id as string;
    createdNow = true;
  }

  // ── 提升进公开桶 ──────────────────────────────────────────────────
  const { error: moveErr } = await admin.storage
    .from(STAGING)
    .move(stagingPath, targetPath, { destinationBucket: 'works' });

  if (moveErr) {
    const msg = moveErr.message ?? String(moveErr);
    // 幂等:重复调用时对象已在 works,视为成功而非失败。
    // ⚠️ 这个分支也必须带上 work_id 与 moderation_status:它是重试路径,
    //    漏带会让客户端把"已存在"当成没有审核状态,进而误判为放行。
    if (/exists|duplicate/i.test(msg)) {
      return jsonResponse({
        ok: true,
        path: targetPath,
        already: true,
        work_id: workId,
        moderation_status: 'under_review',
      });
    }
    // 回滚:文件没能进公开桶,那行就不该留下。只删本次新建的。
    // service_role 执行 delete ⇒ current_user='service_role' ⇒
    // guard_work_moderation_delete 不触发(它只拦 anon/authenticated),
    // 所以 under_review 的行在这里删得掉。
    if (createdNow && workId) {
      const { error: rbErr } = await admin.from('works').delete().eq('id', workId);
      if (rbErr) {
        console.error('[upload-finalize] rollback delete failed:', rbErr.message);
      }
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
    metadata: { path: targetPath, kind: verdict.kind, size: actualSize, work_id: workId },
  });

  return jsonResponse({
    ok: true,
    path: targetPath,
    kind: verdict.kind,
    work_id: workId,
    // 客户端据此提示"审核中"。作品此刻对任何人都不可见 —— 包括作者自己的
    // feed(published_at=null 被 .not('published_at','is',null) 挡住)。
    moderation_status: 'under_review',
  });
});

function firstIp(raw: string | null): string | null {
  if (!raw) return null;
  const first = raw.split(',')[0]?.trim();
  return first && first.length > 0 ? first : null;
}
