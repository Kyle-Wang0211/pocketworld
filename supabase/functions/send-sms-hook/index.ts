// send-sms-hook —— Supabase Auth 的 "Send SMS" Hook,把 OTP 交给阿里云短信发出去。
// ---------------------------------------------------------------------
// 为什么用 Hook 而不是扩展我们自建的 signup-start/verify:
//   Supabase 内置的 SMS provider 只有 Twilio / MessageBird / Vonage / TextLocal,
//   **没有阿里云**。但官方给了 Send SMS Hook 这个扩展点:GoTrue 需要发短信时
//   POST 到你指定的 endpoint,你只负责"把这条短信发出去"。
//
//   这样分工的好处(相对于自己造一套 OTP 流程):
//     · OTP 的**生成、校验、过期、重发限流**全部由 GoTrue 管,不是我们写
//     · 手机号落在 `auth.users.phone` 这个**标准字段**上,迁移时随 dump 走
//     · 换 provider(或将来迁到自建 GoTrue)时,只有这一个文件要动
//
// 合规依据:《互联网用户账号信息管理规定》第九条与《深度合成规定》第九条都要求
//   "基于**移动电话号码**、身份证件号码或者统一社会信用代码等方式的真实身份信息认证",
//   并且"用户不提供真实身份信息的,不得为其提供相关服务"。
//   ⚠️ 邮箱**不在**这个列举里 —— 当前的邮箱注册不满足第九条,这正是本文件存在的原因。
//   三种方式里手机号也是最便宜的:短信约 0.03–0.05 元/条,身份证二要素核验要 0.5–1 元/次。
//
// ⚠️⚠️ 【尚未接通,需要配置才能工作】部署后还要做三件事:
//   1. 开通阿里云短信服务,申请**签名**与**验证码模板**(模板里要有 ${code} 变量)
//   2. 给本函数配置 4 个 secret:
//        ALIYUN_ACCESS_KEY_ID / ALIYUN_ACCESS_KEY_SECRET
//        ALIYUN_SMS_SIGN_NAME / ALIYUN_SMS_TEMPLATE_CODE
//   3. 在 Supabase Dashboard → Authentication → Hooks 里启用 "Send SMS hook",
//      指向本函数,并把生成的 secret 配成本函数的 SEND_SMS_HOOK_SECRET
//   在第 3 步完成前,GoTrue 不会调用本函数;在第 1、2 步完成前,本函数会返回 500。
//
// ⚠️ 部署必须带 --no-verify-jwt:调用方是 GoTrue 自己,它用 Standard Webhooks
//    签名而不是用户 JWT。带 JWT 校验的话请求会被网关先拦掉,函数根本收不到。
//      supabase functions deploy send-sms-hook --no-verify-jwt --project-ref <REF>

import { Webhook } from 'https://esm.sh/standardwebhooks@1.0.0';

const ENDPOINT = 'https://dysmsapi.aliyuncs.com/';

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return json({ error: { http_code: 405, message: 'method_not_allowed' } }, 405);
  }

  const hookSecret = Deno.env.get('SEND_SMS_HOOK_SECRET');
  if (!hookSecret) {
    // fail-closed:没有 secret 就无法验签,宁可发不出去也不能给未验证的请求发短信
    // —— 短信是要花钱的,一个开放的发信端点等于替别人付费。
    return json({ error: { http_code: 500, message: 'hook_secret_not_configured' } }, 500);
  }

  const raw = await req.text();
  let phone: string;
  let otp: string;
  try {
    // 官方约定:secret 形如 `v1,whsec_<base64>`,验签时要去掉前缀。
    const wh = new Webhook(hookSecret.replace('v1,whsec_', ''));
    const { user, sms } = wh.verify(raw, Object.fromEntries(req.headers)) as {
      user: { phone: string };
      sms: { otp: string };
    };
    phone = user.phone;
    otp = sms.otp;
  } catch (e) {
    return json({ error: { http_code: 401, message: `bad_signature: ${e}` } }, 401);
  }

  const keyId = Deno.env.get('ALIYUN_ACCESS_KEY_ID');
  const keySecret = Deno.env.get('ALIYUN_ACCESS_KEY_SECRET');
  const signName = Deno.env.get('ALIYUN_SMS_SIGN_NAME');
  const templateCode = Deno.env.get('ALIYUN_SMS_TEMPLATE_CODE');
  if (!keyId || !keySecret || !signName || !templateCode) {
    return json({ error: { http_code: 500, message: 'aliyun_sms_not_configured' } }, 500);
  }

  // GoTrue 给的 phone 不带 +,阿里云国内短信要的是不带国家码的 11 位号码。
  // 这里只剥离 +86 / 86 前缀;其它国家码原样传,由阿里云去拒(我们不做国际短信)。
  const national = phone.replace(/^\+?86/, '');

  try {
    const url = await signedUrl(
      {
        Action: 'SendSms',
        Version: '2017-05-25',
        PhoneNumbers: national,
        SignName: signName,
        TemplateCode: templateCode,
        TemplateParam: JSON.stringify({ code: otp }),
      },
      keyId,
      keySecret,
    );
    const res = await fetch(url);
    const body = await res.json();
    // 阿里云用 body.Code 表达成败,HTTP 200 不代表发送成功。
    if (body?.Code !== 'OK') {
      return json(
        { error: { http_code: 502, message: `aliyun_rejected: ${body?.Code} ${body?.Message ?? ''}` } },
        502,
      );
    }
  } catch (e) {
    return json({ error: { http_code: 502, message: `aliyun_request_failed: ${e}` } }, 502);
  }

  // 官方:空响应 + 200 即视为成功。
  return json({}, 200);
});

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

// ── 阿里云 RPC 风格 V2 签名(HMAC-SHA1)────────────────────────────────
// 步骤按官方文档:
//   1. 除 Signature 外的全部参数按**参数名字典序**排序
//   2. 每个 key/value 按 RFC3986 做 percent encode
//   3. stringToSign = HTTPMethod + "&" + pctEncode("/") + "&" + pctEncode(canonicalQuery)
//   4. signature = Base64(HMAC_SHA1(AccessKeySecret + "&", stringToSign))
// ⚠️ 第 4 步 key 末尾那个 "&" 不是笔误,是阿里云 V2 签名的规定,漏了必然验签失败。
// ⚠️ SignatureNonce 必须每次不同,用于防重放。
//
// ⚠️⚠️ 【未验证】这里实现的是 **RPC V2 签名(HMAC-SHA1)**。阿里云近年推出了
//   ACS3-HMAC-SHA256 新签名方式,官方也建议"通过 SDK 调用,SDK 已封装签名机制",
//   但 Deno 没有官方 SDK,所以只能自己签。V2 目前仍被 SendSms 接受(老 API 普遍在用),
//   **但我没有实际发过一条短信来验证**。
//   若首次联调返回 `SignatureDoesNotMatch`,按这个顺序排查:
//     1. pct() 的字符集(! ' ( ) * 与 ~ 的处理)
//     2. HMAC key 末尾那个 "&" 有没有漏
//     3. Timestamp 格式(必须是 UTC 的 ISO8601,秒级,不带毫秒)
//     4. 以上都对还失败 ⇒ 改用 ACS3-HMAC-SHA256 重写本函数的签名部分
async function signedUrl(
  params: Record<string, string>,
  keyId: string,
  keySecret: string,
): Promise<string> {
  const all: Record<string, string> = {
    ...params,
    Format: 'JSON',
    AccessKeyId: keyId,
    SignatureMethod: 'HMAC-SHA1',
    SignatureVersion: '1.0',
    SignatureNonce: crypto.randomUUID(),
    Timestamp: new Date().toISOString().replace(/\.\d{3}/, ''),
  };

  const canonical = Object.keys(all)
    .sort()
    .map((k) => `${pct(k)}=${pct(all[k])}`)
    .join('&');

  const stringToSign = `GET&${pct('/')}&${pct(canonical)}`;

  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(`${keySecret}&`),
    { name: 'HMAC', hash: 'SHA-1' },
    false,
    ['sign'],
  );
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(stringToSign));
  const signature = btoa(String.fromCharCode(...new Uint8Array(sig)));

  return `${ENDPOINT}?Signature=${pct(signature)}&${canonical}`;
}

/// RFC3986 的 percent encode。encodeURIComponent 不编码 ! ' ( ) *,
/// 且把空格编成 %20 之外的差异要手工补 —— 这几个字符在签名里出现一次就整体失败。
function pct(s: string): string {
  return encodeURIComponent(s)
    .replace(/[!'()*]/g, (c) => '%' + c.charCodeAt(0).toString(16).toUpperCase())
    .replace(/%7E/g, '~');
}
