// set-profile-name
// ---------------------------------------------------------------------
// display_name 与 handle 的**唯一**写入口。
//
// 为什么必须是唯一入口:
//   在此之前有两条路能写 profiles.display_name,而 feed 展示的正是这一列:
//     1. RLS 策略 profiles_update_self 允许客户端直接 UPDATE;
//     2. 更隐蔽的一条 —— auth.updateUser() 改自己的 user_metadata 是
//        Supabase Auth 的内置能力(RLS 关不掉),再由 20260510000000 的
//        SECURITY DEFINER 触发器自动同步进 profiles。
//   迁移 20260823010000 拆掉了 (2) 的触发器,并用列级守卫
//   guard_profile_identity_columns 挡住 (1),身份列自此只有 service_role 能改。
//
// 校验链(顺序不可调换,每一步都依赖前一步的输出):
//   display_name: RFC 8266 enforce → 字素簇长度 → 保留词 → 冷却 → 写库
//   handle:       normalizeHandle  → 保留词       → 冷却 → 写库(靠唯一索引定胜负)
//
//   🔑 保留词检查必须在归一化**之后**。先匹配后归一化的话,
//      全角 'Ａｄｍｉｎ' 与 'ad<ZWSP>min' 都能绕过整张表。
//      name_rules_test.ts 里有两条测试专门钉这个顺序。
//
// 唯一性:**不做"先 SELECT 查重名再 UPDATE"** —— 那是 TOCTOU 竞态,两个并发
//   请求会同时通过检查。正确做法是让 uq_profiles_handle_key 唯一索引定胜负,
//   捕获 23505 unique_violation 再翻译成用户可读的 handle_taken。
//
// 鉴权:用户 JWT(与 upload-finalize 同款),因此部署**不带** --no-verify-jwt:
//   supabase functions deploy set-profile-name --project-ref <REF>

import { createClient } from 'jsr:@supabase/supabase-js@2.112.3';
import { corsHeaders, jsonResponse, consumeRateLimit } from '../_shared/cors.ts';
import { enforce, graphemeLength, NicknameRejected } from '../_shared/precis_nickname.ts';
import { normalizeHandle, HandleRejected } from '../_shared/handle.ts';
import { checkReservedName } from '../_shared/reserved_names.ts';
import { cooldownLeft } from '../_shared/rename_cooldown.ts';

// 产品上限:字素簇计。Postgres 侧的 char_length<=200 只是防滥用的硬顶,
// 真正的产品规则在这里 —— 二者口径不同是有意的,见迁移文件注释。
const DISPLAY_NAME_MAX_GRAPHEMES = 20;

// bio(第二十三条里的"简介")的产品上限,同样按字素簇计。
// 160 取 Twitter/X 的 bio 口径;Instagram 是 150,二者构成 150-160 的业界
// 共识区间,取宽松的那个。DB 侧 char_length<=2000 只是防滥用的硬顶。
const BIO_MAX_GRAPHEMES = 160;

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

  // 限流。⚠️ consumeRateLimit 是 **fail-open** 的(_shared/cors.ts 里注释明写),
  // 它挡的是滥用,不是安全边界 —— 真正的边界是下面每一条校验,那些必须 fail-closed。
  const allowed = await consumeRateLimit(admin, `setname:${user.id}`, 20, 3600);
  if (!allowed) {
    return jsonResponse(
      { error: 'rate_limited', message: '操作过于频繁,请稍后再试' },
      429,
    );
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: 'invalid_json' }, 400);
  }

  const wantDisplayName = typeof body.display_name === 'string';
  const wantHandle = typeof body.handle === 'string';
  const wantBio = typeof body.bio === 'string';
  if (!wantDisplayName && !wantHandle && !wantBio) {
    return jsonResponse({ error: 'nothing_to_update' }, 400);
  }

  const { data: profile, error: profErr } = await admin
    .from('profiles')
    .select('display_name, handle, bio, display_name_changed_at, handle_changed_at')
    .eq('id', user.id)
    .maybeSingle();
  if (profErr) {
    return jsonResponse({ error: 'profile_lookup_failed', detail: profErr.message }, 500);
  }
  if (!profile) return jsonResponse({ error: 'profile_not_found' }, 404);

  const now = Date.now();
  const patch: Record<string, unknown> = {};

  // ── display_name ────────────────────────────────────────────────────
  if (wantDisplayName) {
    const cool = cooldownLeft(profile.display_name_changed_at as string | null, now);
    if (cool > 0) {
      return jsonResponse(
        { error: 'cooldown', field: 'display_name', retry_after_ms: cool },
        429,
      );
    }
    let normalized: string;
    try {
      normalized = enforce(body.display_name as string);
    } catch (e) {
      const reason = e instanceof NicknameRejected ? e.reason : 'invalid';
      return jsonResponse({ error: 'invalid_display_name', reason }, 422);
    }
    if (graphemeLength(normalized) > DISPLAY_NAME_MAX_GRAPHEMES) {
      return jsonResponse(
        { error: 'invalid_display_name', reason: 'too_long', max: DISPLAY_NAME_MAX_GRAPHEMES },
        422,
      );
    }
    const reserved = checkReservedName(normalized);
    if (!reserved.ok) {
      return jsonResponse(
        { error: 'reserved_name', field: 'display_name', kind: reserved.kind, term: reserved.term },
        422,
      );
    }
    if (normalized !== profile.display_name) {
      patch.display_name = normalized;
      patch.display_name_changed_at = new Date(now).toISOString();
    }
  }

  // ── handle ──────────────────────────────────────────────────────────
  if (wantHandle) {
    const cool = cooldownLeft(profile.handle_changed_at as string | null, now);
    if (cool > 0) {
      return jsonResponse({ error: 'cooldown', field: 'handle', retry_after_ms: cool }, 429);
    }
    let normalized: string;
    try {
      normalized = normalizeHandle(body.handle as string);
    } catch (e) {
      const reason = e instanceof HandleRejected ? e.reason : 'invalid';
      return jsonResponse({ error: 'invalid_handle', reason }, 422);
    }
    const reserved = checkReservedName(normalized);
    if (!reserved.ok) {
      return jsonResponse(
        { error: 'reserved_name', field: 'handle', kind: reserved.kind, term: reserved.term },
        422,
      );
    }
    if (normalized !== profile.handle) {
      patch.handle = normalized;
      patch.handle_key = normalized;
      patch.handle_changed_at = new Date(now).toISOString();
    }
  }

  // ── bio(第二十三条的"简介")────────────────────────────────────────
  // 复用 display_name 那条 RFC 8266 链,不另写一套:
  //   · Additional Mapping 去首尾空格、折叠连续空格 —— 挡住用空格排版
  //   · NFKC —— 全角冒充在这里同样会现形
  //   · prepare() 拒控制字符与零宽字符 —— 否则 bio 是绕过保留词的最佳藏身处
  // 与昵称的唯二区别:上限 160 而非 20,且允许清空(空串 ⇒ null)。
  //
  // 不设改名冷却:bio 不是身份标识,Twitter / GitHub 都不限制其修改频率。
  // 第十五条的"适时核验存量"由改动本身触发的这条校验链承担。
  if (wantBio) {
    const raw = (body.bio as string).trim();
    if (raw.length === 0) {
      if (profile.bio !== null) patch.bio = null;
    } else {
      let normalized: string;
      try {
        normalized = enforce(raw);
      } catch (e) {
        const reason = e instanceof NicknameRejected ? e.reason : 'invalid';
        return jsonResponse({ error: 'invalid_bio', reason }, 422);
      }
      if (graphemeLength(normalized) > BIO_MAX_GRAPHEMES) {
        return jsonResponse(
          { error: 'invalid_bio', reason: 'too_long', max: BIO_MAX_GRAPHEMES },
          422,
        );
      }
      const reserved = checkReservedName(normalized);
      if (!reserved.ok) {
        return jsonResponse(
          { error: 'reserved_name', field: 'bio', kind: reserved.kind, term: reserved.term },
          422,
        );
      }
      if (normalized !== profile.bio) patch.bio = normalized;
    }
  }

  if (Object.keys(patch).length === 0) {
    return jsonResponse({ ok: true, unchanged: true });
  }

  const { error: updErr } = await admin
    .from('profiles')
    .update(patch)
    .eq('id', user.id);

  if (updErr) {
    // 23505 = unique_violation。唯一性由 uq_profiles_handle_key 索引裁决,
    // 而不是由上面的 SELECT 裁决 —— 后者存在 TOCTOU 竞态。
    if ((updErr as { code?: string }).code === '23505') {
      return jsonResponse({ error: 'handle_taken' }, 409);
    }
    return jsonResponse({ error: 'update_failed', detail: updErr.message }, 500);
  }

  // 同步 auth.users.raw_user_meta_data.display_name。
  //
  // 为什么还要写这一份:客户端的 AuthenticatedUser 是从 auth session 的
  // user_metadata 构造的(supabase_auth_service._wrap)。迁移 20260823010000
  // 拆掉了 auth.users -> profiles 的自动同步触发器,所以两边不会再自己对齐 ——
  // 必须由这里显式写。
  //
  // ⚠️ 顺序不可调换:先 profiles 后 auth。profiles 那一步可能因唯一约束(23505)
  //    失败;若先写 auth 再写 profiles,失败时 auth 里已经是新名字而 profiles
  //    还是旧的,feed 与个人页会显示两个不同的名字,且没有回滚路径。
  //
  // ⚠️ 这不是"又开了一条写入口":admin.auth.admin.updateUserById 只有
  //    service_role 能调。客户端自己调 auth.updateUser 仍然改得动
  //    user_metadata(那是 Supabase Auth 的内置能力,关不掉),但那已经**不再
  //    影响 profiles**,而 feed / 个人页读的是 profiles。换句话说,客户端能改
  //    的只是一份对外不可见的副本。
  if (typeof patch.display_name === 'string') {
    const { error: metaErr } = await admin.auth.admin.updateUserById(user.id, {
      user_metadata: { ...(user.user_metadata ?? {}), display_name: patch.display_name },
    });
    if (metaErr) {
      // 非致命:profiles 已经是权威值,feed 展示不受影响。记录以便排查。
      console.error('[set-profile-name] auth metadata sync failed:', metaErr.message);
    }
  }

  // 审计。⚠️ 这里的 error 被刻意读取并记录而不是丢弃 —— upload-finalize 里
  // 两处 audit_logs.insert 的返回值都被丢掉了(supabase-js 的 insert 失败
  // 返回 error 而不抛异常 ⇒ 静默)。"谁在何时把名字改成了什么"是第十条核验
  // 义务的证据链,不能挂在一条静默路径上。
  const { error: auditErr } = await admin.from('audit_logs').insert({
    actor_id: user.id,
    action: 'profile.name_changed',
    target_type: 'user',
    target_id: user.id,
    metadata: patch,
  });
  if (auditErr) {
    console.error('[set-profile-name] audit insert failed:', auditErr.message);
  }

  return jsonResponse({
    ok: true,
    display_name: patch.display_name ?? profile.display_name,
    handle: patch.handle ?? profile.handle,
    bio: 'bio' in patch ? patch.bio : profile.bio,
  });
});
