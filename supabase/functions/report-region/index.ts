// report-region
// ----------------------------------------------------------------------
// 把调用者**当前**的 IP 属地写到 profiles.last_region,供账号信息页面展示。
//
// 法条:《互联网用户账号信息管理规定》(网信办令第10号)第十二条 ——
//   "应当在互联网用户账号信息页面展示合理范围内的……IP 地址归属地信息。"
//
// 为什么需要一个**专门的端点**:
//   客户端浏览 feed 时是直连 PostgREST 的,没有任何服务端跳板可以顺手取到
//   x-forwarded-for。works.publish_region 有 upload-finalize 这个天然落点,
//   但"账号页面的属地"没有 —— 只能给它一个自己的端点。
//   函数本体很小,这是它存在的全部理由。
//
// 🔴 请求体是**空的**,而且必须是空的。属地只从请求头判定。
//    任何"客户端上报自己在哪"的设计都等于属地可伪造,也就等于没做第十二条。
//
// 调用时机(客户端):登录成功后 + App 冷启动/回前台且距上次上报 > 6h。
//   业界(微博/抖音)的更新粒度也是"会话级",不是每次请求。
//
// FAIL POLICY: fail-open。属地是装饰性信息,拿不到就不展示;
//   它的失败绝不该阻断登录或使用。(与 uploads_enabled 那个 kill switch 的
//   fail-CLOSED 相反 —— 判据是"失败时用户看到的是少一行小字,还是一次
//   没有约束的写入"。)

import { createClient } from 'jsr:@supabase/supabase-js@2.112.3';
import { corsHeaders, jsonResponse, consumeRateLimit } from '../_shared/cors.ts';
import { resolveClientRegion } from '../_shared/client_region.ts';

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

  // 60/小时。客户端的正常节奏是每 6 小时一次,这个上限只用来兜住
  // 跑飞的重试循环。fail-open,与其它端点一致。
  const allowed = await consumeRateLimit(
    admin, `report-region:${user.id}`, 60, 3600);
  if (!allowed) return jsonResponse({ error: 'rate_limited' }, 429);

  const region = await resolveClientRegion(admin, req);

  // 🔴 解析不出来时**不要**把已有的属地擦成 null。
  //    一次走内网/IP 库没覆盖的请求,不该让账号页面上原本正确的属地消失。
  //    (这也是为什么这里是 update 而不是把 region 无条件写进去。)
  if (region === null) {
    return jsonResponse({ region: null, updated: false });
  }

  const { error: updErr } = await admin
    .from('profiles')
    .update({ last_region: region, last_region_at: new Date().toISOString() })
    .eq('id', user.id);

  if (updErr) {
    console.warn('report-region update failed:', updErr.message);
    return jsonResponse({ region, updated: false });
  }
  return jsonResponse({ region, updated: true });
});
