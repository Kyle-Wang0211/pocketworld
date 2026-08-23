// IP 属地(《互联网用户账号信息管理规定》第十二条)—— 服务端解析
// =====================================================================
// 第十二条:"互联网信息服务提供者应当在互联网用户账号信息页面展示合理范围内的
//           互联网用户账号的互联网协议(IP)地址归属地信息。"
//
// 🔴 这件事**只能在服务端做**。客户端上报属地 = 属地可伪造 = 这个展示失去
//    全部意义。所以:IP 从请求头取,属地由 DB 函数判定,两列都被
//    guard_profile_identity_columns 挡住不让客户端写(迁移 20260824000000)。
//
// 🔴 也**不能**把 IP 本身落到 works/profiles 上。落地的只有省/国家这一级
//    展示串。IP 只在 audit_logs 里留(那是安全审计的合法必要),
//    《个人信息保护法》第六条"最小必要"。

/// x-forwarded-for 是一条链,第一项是原始客户端。
/// 解析不出来返回 null —— 属地拿不到从来不是错误,只是不展示。
///
/// ⚠️ 这个头是**可伪造**的(客户端可以自己塞一个 x-forwarded-for)。
///    Supabase 的边缘网关会在转发时**覆写/追加**真实来源,所以第一项在
///    我们这条链路上是可信的;换到自建网关(阿里云 SLB/Nginx)后,必须确认
///    网关配置的是 `proxy_set_header X-Forwarded-For $remote_addr`
///    (覆写)而不是 `$proxy_add_x_forwarded_for`(追加)—— 否则第一项
///    就是攻击者自己写的,属地可被任意伪造。迁移时这条要单独验。
export function firstIp(raw: string | null): string | null {
  if (!raw) return null;
  const first = raw.split(',')[0]?.trim();
  return first && first.length > 0 ? first : null;
}

/// 请求 → 属地展示串(如 '广东' / '美国'),拿不到返回 null。
///
/// 绝不抛异常:属地是**装饰性**信息,它的失败不该让发布或登录失败。
/// (与 uploads_enabled 那个 kill switch 的 fail-CLOSED 相反 —— 那个是刹车,
///  这个不是。判据:失败时用户看到的是"少一行小字"还是"没有约束的写入"。)
export async function resolveClientRegion(
  // deno-lint-ignore no-explicit-any
  admin: any,
  req: Request,
): Promise<string | null> {
  const ip = firstIp(req.headers.get('x-forwarded-for'));
  if (!ip) return null;
  try {
    const { data, error } = await admin.rpc('resolve_ip_region', { p_ip: ip });
    if (error) {
      // 最常见的原因:IP 库还没导入(表是空的)。那不是异常,是"还没配"。
      console.warn('resolve_ip_region failed:', error.message);
      return null;
    }
    return typeof data === 'string' && data.length > 0 ? data : null;
  } catch (e) {
    console.warn('resolve_ip_region threw:', String(e));
    return null;
  }
}
