// admin-reports
// ---------------------------------------------------------------------
// 举报的**受理端**。
//
// 在此之前:`reports` 表自 20260429020005 就存在,App 里的举报入口
// (community_service.dart 的 `from('reports').insert`)也早就有了 ——
// 但**没有任何一条路径读它**。举报写进去之后没有任何人、任何界面看得到,
// 等于扔进黑洞。
//
// 《网络信息内容生态治理规定》第九条要求的是"建立健全用户注册、账号管理、
// 信息发布审核、……**举报受理**……等制度"。受理是有动作要求的:
// 光有入口不算受理,得能看见、能处置、能留痕。
//
// 职责边界(别和另外两个管理端混):
//   admin-reports        举报队列的**读**与**结案**。不改作品状态。
//   admin-approve-work   待审作品放行(under_review → ok)。只翻 DB。
//   admin-moderate-work  下架/恢复(会搬文件进出 quarantine 桶)。
// 结案时要不要顺手下架,由调用方决定并**分两次调用** —— 合成一个原子操作
// 听起来更好,但下架会动文件、可能部分失败,把它和结案绑在一个事务里
// 只会产生"结案了但文件没搬走"这种没人能发现的中间态。
//
// Auth: service_role only(与另外两个管理端同款)。因此部署必须带
//   supabase functions deploy admin-reports --no-verify-jwt --project-ref <REF>

import { createClient } from 'jsr:@supabase/supabase-js@2.112.3';
import { corsHeaders, jsonResponse } from '../_shared/cors.ts';
import { isAdminRequest } from '../_shared/admin_auth.ts';

/// 20260429020005 的 check 约束就是这四个值,写死以便早拒。
const RESOLVABLE = ['actioned', 'dismissed'] as const;
const LISTABLE = ['pending', 'in_review', 'actioned', 'dismissed'] as const;

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

  // ── list ────────────────────────────────────────────────────────────
  // 默认只列 pending。按 created_at **正序** = 先来先办,与待审队列同一条
  // 规矩 —— 举报队列按倒序排会让最早的投诉永远沉在底部。
  if (action === 'list') {
    const status = typeof body.status === 'string' ? body.status : 'pending';
    if (!(LISTABLE as readonly string[]).includes(status)) {
      return jsonResponse({ error: 'invalid_status', allowed: LISTABLE }, 400);
    }
    const { data, error } = await admin
      .from('reports')
      .select(
        'id, reporter_id, target_type, target_id, reason, detail, ' +
        'status, admin_notes, resolved_at, created_at',
      )
      .eq('status', status)
      .order('created_at', { ascending: true })
      .limit(200);
    if (error) {
      return jsonResponse({ error: 'list_failed', detail: error.message }, 500);
    }
    const rows = (data ?? []) as unknown as Record<string, unknown>[];
    return jsonResponse({
      ok: true,
      reports: await attachTargets(admin, rows),
      count: rows.length,
    });
  }

  // ── resolve ─────────────────────────────────────────────────────────
  if (action !== 'resolve') {
    return jsonResponse({ error: 'unknown_action', allowed: ['list', 'resolve'] }, 400);
  }

  const reportId = Number(body.report_id);
  if (!Number.isInteger(reportId) || reportId <= 0) {
    return jsonResponse({ error: 'invalid_report_id' }, 400);
  }
  const status = typeof body.status === 'string' ? body.status.trim() : '';
  if (!(RESOLVABLE as readonly string[]).includes(status)) {
    return jsonResponse({ error: 'invalid_status', allowed: RESOLVABLE }, 400);
  }
  const notes = typeof body.admin_notes === 'string'
    ? body.admin_notes.trim().slice(0, 2000) || null
    : null;

  // 🔑 幂等 + 防覆盖:WHERE 里带 `status in ('pending','in_review')`。
  //    已结案的举报再调一次匹配不到行 ⇒ **不会重写 resolved_at**,
  //    也不会把别人的结论悄悄改掉。写在 WHERE 里而不是先查后改,避开 TOCTOU
  //    —— 与 admin-approve-work 同一条规矩。
  //
  // ⚠️ resolved_by 只能是 null:它是 `references auth.users(id)`,而 service_role
  //    调用没有对应的 auth 用户,填任何值都会撞外键。"谁处置的"记在 audit_logs
  //    的 operator 里,不放这一列。
  const { data: updated, error: updErr } = await admin
    .from('reports')
    .update({
      status,
      admin_notes: notes,
      resolved_at: new Date().toISOString(),
    })
    .eq('id', reportId)
    .in('status', ['pending', 'in_review'])
    .select('id, status, target_type, target_id, reason, resolved_at')
    .maybeSingle();

  if (updErr) {
    return jsonResponse({ error: 'resolve_failed', detail: updErr.message }, 500);
  }
  if (!updated) {
    const { data: cur } = await admin
      .from('reports')
      .select('id, status, resolved_at')
      .eq('id', reportId)
      .maybeSingle();
    if (!cur) return jsonResponse({ error: 'report_not_found' }, 404);
    return jsonResponse({
      ok: true,
      already: true,
      message: '该举报已结案,未做任何改动。',
      current: cur,
    });
  }

  // 审计。⚠️ 读取并记录 error 而不是丢弃 —— supabase-js 的 insert 失败返回
  // error 而不抛异常,丢掉返回值等于让证据链挂在一条静默路径上。
  // 举报处置结果是第九条"受理"义务的证据,必须留痕。
  const operator = typeof body.operator === 'string'
    ? body.operator.trim().slice(0, 120) || null
    : null;
  const { error: auditErr } = await admin.from('audit_logs').insert({
    actor_id: null, // service_role 调用,没有对应的 auth 用户
    action: `admin.report_${status}`,
    target_type: 'report',
    target_id: null, // reports.id 是 bigserial,而这一列是 uuid
    ip_address: firstIp(req.headers.get('x-forwarded-for')),
    user_agent: (req.headers.get('user-agent') ?? '').slice(0, 500) || null,
    metadata: {
      report_id: reportId,
      reason: updated.reason,
      reported_target_type: updated.target_type,
      reported_target_id: updated.target_id,
      admin_notes: notes,
      operator,
    },
  });
  if (auditErr) {
    console.error('[admin-reports] audit insert failed:', auditErr.message);
  }

  return jsonResponse({
    ok: true,
    report_id: reportId,
    status: updated.status,
    resolved_at: updated.resolved_at,
  });
});


/// 给每条举报补上"被举报的到底是什么"。
///
/// 没有它,审核台上只有一个 uuid 和一个 reason —— 无法判断该不该处置,
/// 那样的"受理"是走过场。
///
/// 目前只解 target_type='work'。comment / user / project 三类原样返回:
/// 评论和私信在冷启动阶段没开放,project 不是公开对象。等它们开放时
/// 在这里加分支,而不是现在写一堆解不出东西的代码。
async function attachTargets(
  // deno-lint-ignore no-explicit-any
  admin: any,
  rows: Record<string, unknown>[],
): Promise<Record<string, unknown>[]> {
  if (rows.length === 0) return [];

  const workIds = [
    ...new Set(
      rows.filter((r) => r.target_type === 'work').map((r) => r.target_id as string),
    ),
  ];
  const works = new Map<string, Record<string, unknown>>();
  if (workIds.length > 0) {
    const { data } = await admin
      .from('works')
      .select(
        'id, user_id, title, description, format, visibility, ' +
        'moderation_status, published_at, publish_region, ' +
        'model_storage_path, thumbnail_storage_path, deleted_at',
      )
      .in('id', workIds);
    for (const w of (data ?? []) as Record<string, unknown>[]) {
      works.set(w.id as string, w);
    }
  }

  // 作者 + 举报人的可读身份。两边都查,一次 in。
  const people = [
    ...new Set([
      ...rows.map((r) => r.reporter_id as string),
      ...[...works.values()].map((w) => w.user_id as string),
    ].filter(Boolean)),
  ];
  const byId = new Map<string, Record<string, unknown>>();
  if (people.length > 0) {
    const { data } = await admin
      .from('profiles')
      .select('id, display_name, handle')
      .in('id', people);
    for (const p of (data ?? []) as Record<string, unknown>[]) {
      byId.set(p.id as string, p);
    }
  }

  // 🔴 必须**服务端签名**,而且这里的理由比待审队列更硬:被举报的作品很可能
  // 已经是 removed 状态,那时 admin-moderate-work 已经把模型**和缩略图**
  // 一起搬进了 quarantine 桶(私有、无策略)—— 原路径上什么都没有了。
  // 而"已经下架了但举报还没结案"恰恰是最需要看一眼的情形。
  // 签名走 service_role,是这时唯一还能看见证据的方式。
  //
  // ⚠️ 注意签的是**原桶原路径**。作品若已下架,这次签名会失败并返回 null
  //    —— 那不是 bug,是文件确实已经不在那里了。要看已下架作品的原件,
  //    得去 quarantine 桶按 `{work_id}/{source_bucket}/{original_path}` 找。
  const sign = async (bucket: string, path: unknown): Promise<string | null> => {
    if (typeof path !== 'string' || path.length === 0) return null;
    try {
      const { data, error } = await admin.storage
        .from(bucket)
        .createSignedUrl(path, 3600);
      if (error) return null;
      return data?.signedUrl ?? null;
    } catch {
      return null;
    }
  };

  return await Promise.all(rows.map(async (r) => {
    const reporter = byId.get(r.reporter_id as string);
    const w = r.target_type === 'work'
      ? works.get(r.target_id as string)
      : undefined;
    const author = w ? byId.get(w.user_id as string) : undefined;
    return {
      ...r,
      reporter_handle: reporter?.handle ?? null,
      reporter_display_name: reporter?.display_name ?? null,
      target: w
        ? {
          ...w,
          author_handle: author?.handle ?? null,
          author_display_name: author?.display_name ?? null,
          thumb_url: await sign('thumbnails', w.thumbnail_storage_path),
          model_url: await sign('works', w.model_storage_path),
        }
        : null,
    };
  }));
}

/// x-forwarded-for may be a comma-separated chain; the first entry is the
/// original client.
function firstIp(raw: string | null): string | null {
  if (!raw) return null;
  const first = raw.split(',')[0]?.trim();
  return first && first.length > 0 ? first : null;
}
