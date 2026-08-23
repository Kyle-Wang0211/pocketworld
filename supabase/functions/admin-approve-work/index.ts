// admin-approve-work
// ---------------------------------------------------------------------
// "先审后发"的放行端。收口(20260823020000)之后,upload-finalize 以
// moderation_status='under_review' + published_at=null 建行,作品对任何人
// 都不可见 —— 但在此之前**没有任何路径能把它改回 'ok'**,发出去的作品会
// 永远停在待审。这个函数补的就是那一端。
//
// ── 为什么不复用 admin-moderate-work ─────────────────────────────────
// 那个函数的 status='ok' 走的是**"从 quarantine 恢复"**分支
// (from=quarantine, to=公开桶),它是给"曾被下架、文件已被搬走"的作品用的。
// 而待审作品的文件**本来就在 works 公开桶**(收口的建行顺序是先建行后 move),
// 拿它来放行会:从 quarantine move 失败 → not-found → 探测目的桶发现对象在
// → 判为 already moved → 纯 DB 翻转 + 一条语义错误的 `admin.work_assets_restored`
// 审计。功能上碰巧能用,记录却在说假话。
// 更要命的是:**它根本不写 published_at**,而那一列决定作品在 feed 里的位置。
//
// 职责边界:
//   放行(under_review → ok)      走本函数,只翻 DB,不动文件
//   驳回(under_review → removed) 仍走 admin-moderate-work,它会把文件搬进 quarantine
//
// Auth: service_role only(与 admin-moderate-work 同款,bearer 必须**就是**
// service_role key)。因此部署必须带 --no-verify-jwt:
//   supabase functions deploy admin-approve-work --no-verify-jwt --project-ref <REF>

import { createClient } from 'jsr:@supabase/supabase-js@2.112.3';
import { corsHeaders, jsonResponse } from '../_shared/cors.ts';
import { isAdminRequest } from '../_shared/admin_auth.ts';

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

  if (!isAdminRequest(req)) {
    return jsonResponse({ error: 'forbidden' }, 403);
  }

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false },
  });

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: 'invalid_json' }, 400);
  }

  const action = typeof body.action === 'string' ? body.action : 'list';

  // ── list:待审队列 ──────────────────────────────────────────────────
  // 按 created_at 正序 = 先来先审。冷启动期这就是全部的"审核后台"。
  if (action === 'list') {
    const { data, error } = await admin
      .from('works')
      .select('id, user_id, title, description, format, file_size_bytes, created_at')
      .eq('moderation_status', 'under_review')
      .is('published_at', null)
      .order('created_at', { ascending: true })
      .limit(100);
    if (error) {
      return jsonResponse({ error: 'list_failed', detail: error.message }, 500);
    }
    return jsonResponse({ ok: true, pending: data ?? [], count: data?.length ?? 0 });
  }

  if (action !== 'approve') {
    return jsonResponse({ error: 'unknown_action', allowed: ['list', 'approve'] }, 400);
  }

  const workId = typeof body.work_id === 'string' ? body.work_id.trim() : '';
  if (!workId) return jsonResponse({ error: 'missing_work_id' }, 400);

  // ── approve ─────────────────────────────────────────────────────────
  // 🔴 published_at 写的是**现在**(放行时刻),不是作品的提交时刻。
  //    这不是随手选的:feed 分页 2026-08-23 从 offset 改成了 keyset,游标是
  //    (published_at, id) 元组。
  //      · 写放行时刻 ⇒ 作品落在列表**顶部**,keyset 对"新内容插到顶部"免疫
  //        (那正是它取代 offset 的原因),没有用户会漏掉它。
  //      · 写提交时刻 ⇒ 作品带着几小时前的时间戳插到列表**中间**,而用户游标
  //        可能已经翻过那个位置 —— 这种情况下 keyset 与 offset **一样会漏**,
  //        且是静默的:作品对该用户永远不出现,作者却以为已经发出去了。
  //
  // 🔑 幂等:条件里带 `moderation_status='under_review'` 与 `published_at is null`。
  //    重复调用第二次匹配不到行 ⇒ **不会重写 published_at**。这条很关键 ——
  //    重写会让一件老作品突然跳到 feed 顶部,看起来像是重新发布了一次。
  //    条件写在 UPDATE 的 WHERE 里而不是先查后改,是为了避免 TOCTOU。
  const approvedAt = new Date().toISOString();
  const { data: updated, error: updErr } = await admin
    .from('works')
    .update({ moderation_status: 'ok', published_at: approvedAt })
    .eq('id', workId)
    .eq('moderation_status', 'under_review')
    .is('published_at', null)
    .select('id, title, user_id, published_at')
    .maybeSingle();

  if (updErr) {
    return jsonResponse({ error: 'approve_failed', detail: updErr.message }, 500);
  }

  if (!updated) {
    // 没匹配到行。分清三种情况再回话,否则运维只能看到一句"失败"。
    const { data: cur } = await admin
      .from('works')
      .select('id, moderation_status, published_at, deleted_at')
      .eq('id', workId)
      .maybeSingle();
    if (!cur) return jsonResponse({ error: 'work_not_found' }, 404);
    return jsonResponse({
      ok: true,
      already: true,
      message: '该作品不处于待审状态,未做任何改动。',
      current: cur,
    });
  }

  // 审计。⚠️ 这里刻意读取并记录 error 而不是丢弃 —— upload-finalize 里两处
  // audit_logs.insert 的返回值都被丢掉了(supabase-js 的 insert 失败返回 error
  // 而不抛异常 ⇒ 静默)。"谁在何时放行了什么"是第十条核验义务的证据链,
  // 不能挂在一条静默路径上。
  const { error: auditErr } = await admin.from('audit_logs').insert({
    actor_id: null, // service_role 调用,没有对应的 auth 用户
    action: 'admin.work_approved',
    target_type: 'work',
    target_id: workId,
    ip_address: firstIp(req.headers.get('x-forwarded-for')),
    user_agent: (req.headers.get('user-agent') ?? '').slice(0, 500) || null,
    metadata: {
      title: updated.title,
      author: updated.user_id,
      published_at: updated.published_at,
      note: 'published_at set to approval time, not submission time (keyset feed)',
    },
  });
  if (auditErr) {
    console.error('[admin-approve-work] audit insert failed:', auditErr.message);
  }

  return jsonResponse({ ok: true, work_id: workId, published_at: updated.published_at });
});


/// x-forwarded-for may be a comma-separated chain; the first entry is the
/// original client.
function firstIp(raw: string | null): string | null {
  if (!raw) return null;
  const first = raw.split(',')[0]?.trim();
  return first && first.length > 0 ? first : null;
}
