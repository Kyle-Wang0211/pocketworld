# PocketWorld 安全审计（2026-08-17 晚，四路并行）

覆盖：认证链路与 Edge Functions / 数据库 RLS 越权与提权 / FFI 内存安全与远程配置 /
密钥泄漏与 iOS 配置。所有结论均带 文件:行号 证据，未改动任何文件。

---

## 🔴 P0 — 账号接管（既有代码，非今日引入）

**OTP 尝试上限是读-改-写竞态，5 次上限形同虚设。**
`password-reset-verify/index.ts:74` 用 SELECT 快照判上限，`:81` 用旧值 `pending.attempts + 1`
写回（last-write-wins，无 FOR UPDATE、无原子自增、无事务）。N 个并发请求全读到
attempts=0、全过门、互相覆盖 ⇒ 每轮只消耗 1 次配额却获得 N 次猜测。
`signup-verify/index.ts:72,79-82` 同款写法。

放大因素：
- `-start` 端点公开无鉴权（README:259-265 记录用 `--no-verify-jwt` 部署），零速率限制，
  且 upsert 把 attempts 重置为 0 ⇒ 可无限重开轮次
- OTP 空间仅 900,000（6 位 `Math.random`）
- CORS `*` 且不校验 Content-Type ⇒ `text/plain` 发 JSON 属 CORS 简单请求，
  第三方网页可静默驱动访客浏览器用真实住宅 IP 分布式发起

**实际后果：匿名攻击者可暴破任意已注册账号的密码重置 OTP，实现账号接管。**
修法：`update ... set attempts = attempts + 1 where email = $1 and attempts < 5 returning attempts`
用返回行数判断（PostgREST 单请求单事务，需走 RPC），并给 `-start` 加 per-email/per-IP 冷却。

⚠️ README:264 声称"per-email rate limits via pending_* tables"——**这句话是假的**，
grep 确认 start 侧无任何冷却判断，attempts 只在 verify 侧递增、被 start 清零。

## 🟠 P1 — 账号枚举（两条独立通道）

- 通道 A：`signup-start/index.ts:80` 已注册返回 409、未注册返回 200 ⇒ 赤裸裸的枚举 oracle
- 通道 B：`password-reset-start/index.ts:75-80` 不存在即刻返回、存在则要等
  Resend HTTPS 往返（`:124-131`）⇒ 数百 ms 时延差。代码注释声称
  "Indistinguishable from the success path"，**时序上不成立**

为 P0 的暴破提供精准靶子列表。

---

## 🔴 我今天写的内容治理有三个真实缺陷（已亲自逐条核实）

### 缺陷 1：下架对文件完全无效
只改了 `works` 自己的 `works_select_visible`，未动任何关联表。仍用旧谓词
（`w.visibility='public' or w.user_id=auth.uid()`，不含 moderation_status/deleted_at）的有七处：

| 策略 | 位置 | 泄露 |
|---|---|---|
| **`work_versions_select_visible`** | engagement.sql:258-271 | **`model_storage_path`（:246）⇒ 拼 public URL 直接下载** |
| `comments_select_visible` | core_business.sql:296-307 | 评论正文 + 作者 uid |
| `work_likes_select_visible` | engagement.sql:27-38 | 点赞者名单 |
| `comment_likes_select_visible` | engagement.sql:130-147 | 评论点赞者 |
| `work_tags_select_visible` | discovery.sql:58-69 | 标签 |
| `collection_works_select_visible` | moderation.sql:162-178 | 仍在他人收藏夹 |
| `works_select_public`(storage) | storage_buckets.sql:117-126 | 只匹配 visibility='public' |

⚠️ 我在 `20260817000000:12-15` 的注释里写"残留风险仅限于提前保存过 URL 的人"——**错误，
应收回**：work_versions 让 anon 在下架**之后**仍能查出路径。且 `admin_set_work_moderation`
不改 `visibility`（`:91-97`），所以即便把 works 桶改回 private，storage 策略照样放行。
`comments_insert_self`（core_business.sql:310-322）同样用旧谓词 ⇒ 还能给已下架作品发新评论。

🔴 **调研推翻的更深假设（2026-08-17 存储调研）**：上面这句"把 works 桶改回 private 就好"
以及"迁签名 URL 能让下架变真"**都是错的**。Supabase 官方 Smart CDN 文档原文：
"Revoking or expiring a token does not purge its CDN cache entry"，且缓存过的响应
"can continue to be served for the same signed URL until the CDN cache duration expires,
even if the token in that URL has already expired"。**唯一的硬撤销是删除或改名对象**
（"Deleting the object invalidates all cached entries for that object across all tokens"，
传播最多 60 秒，且不影响浏览器缓存）。
⇒ 结论：**`admin_set_work_moderation` 必须同时删除或改名 storage 对象**，否则无论桶是
public 还是 private、无论有没有签名 URL，下架在 CDN 层都是假的。这是下架功能真正闭环
的必要条件，当前仍未实现。
⇒ 附带成本事实：签名 URL 使每个 token 成为独立 cache key，首次必 MISS；uncached egress
$0.09/GB vs cached $0.03/GB（两个配额独立）⇒ 不缓存签名 URL 本身的话，1–500MB 作品
按 3 倍单价计费。可落地缓解＝"每 (path, 时间窗) 只签一次并把 token 存表复用"
（Supabase 的 createSignedUrl 只收时长不收绝对过期时刻，无法像 AWS SigV4 冻结时钟）。
出处：supabase.com/docs/guides/storage/cdn/smart-cdn、
supabase.com/docs/guides/platform/manage-your-usage/egress

### 缺陷 2：作者可 DELETE + INSERT 复活被下架作品
guard 触发器只挂 `before update`（`20260817000000:69-71`），而 `works_delete_own`
（core_business.sql:237-239）与 `works_insert_own`（:228-230）对 owner 全开。
删行再插一行指向同一个从未被删除的 storage 对象即复活，几秒完成。
同时证伪我写的 "Row is kept for audit/appeal"。

### 缺陷 3：新加的 record_work_view RPC 可被绕过，刷量零成本
旧策略 `work_views_insert`（engagement.sql:213-218）从未撤销，**anon 可直接 INSERT，
根本不用走我的 RPC** ⇒ RPC 里的可见性检查（`20260817001000:27-39`）是可选的。
更致命：`view_bucket`（engagement.sql:190）只有 DEFAULT、无任何 CHECK/策略约束，
而去重唯一索引含该列（:195）⇒ 攻击者自带百万个互异 timestamp 批量插入，
索引永不冲突，`bump_work_views_count`（:223-236，SECURITY DEFINER）每行无条件 +1。
**任意作品浏览数可被零成本、零账号刷到任意数字。**
修法：删掉 `work_views_insert` 策略（客户端唯一调用点已是 RPC，
community_service.dart:176-183），RPC 内显式写 `view_bucket = date_trunc('hour', now())`。

### 缺陷 4：guard 函数漏设 search_path（Supabase 官方 advisor 抓到）
`supabase db advisors --type security --linked` 明确报
`public.guard_work_moderation_columns has a role mutable search_path`。
我给 `admin_set_work_moderation` 和 `record_work_view` 都写了 `set search_path = public`，
唯独漏了这个触发器函数。它是 SECURITY INVOKER（以调用者权限跑）所以危害有限，
但属于同一份代码里的不一致疏漏，应补齐。

### ✅ 官方 advisor 交叉验证的结论（43 条告警全量分析）
- **我的 revoke 确实生效**：`admin_set_work_moderation` **未出现**在 advisor 的
  `anon_security_definer_function_executable`（20 条）与
  `authenticated_security_definer_function_executable`（20 条）任何一条里
  ⇒ anon/authenticated 都调不到它。认证审计那一路判断正确。
  ⚠️ 但 service_role 能否调用**仍未实证**（advisor 不覆盖该维度，本机无 psql、
  service_role key 只在 Edge Function 环境里）。最稳做法是补一句幂等的
  `grant execute on function admin_set_work_moderation(uuid,text,text) to service_role;`
- `record_work_view` 被标为 anon+authenticated 可执行的 definer 函数——**这是有意设计**
  （匿名访客也要计浏览数），非缺陷，但需知晓
- **20 个 SECURITY DEFINER 函数对 anon 全部可调**，包括所有 `bump_*` 计数触发器函数
  （它们经 `/rest/v1/rpc/bump_work_likes_count` 直接暴露在 REST API 上）以及四个
  云训残留 RPC。这印证了"碰巧安全≠设计安全"的判断——官方工具直接把它们列为 WARN
- **`auth_leaked_password_protection` 未启用**：Supabase 可对接 HaveIBeenPwned
  拦截已泄露密码，目前关着。这是 Dashboard 一键开关，零成本收益

### 今天代码中写对了的部分（经核实）
- `admin_set_work_moderation` 的 `revoke ... from public, anon, authenticated`
  （`:116-117`）覆盖了 PG 的 GRANT TO PUBLIC 默认与 Supabase bootstrap 的
  default privileges，剩余授权只有 postgres/service_role，**这条写对了**
- guard 触发器是 SECURITY INVOKER（未写 definer）**是正确的**——若哪天有人给它加
  definer，current_user 会变成 owner，守卫将永久静默失效（建议加注释锁死）
- 9 个 bump_* definer 触发器虽以 owner 身份 UPDATE works（guard 判 false 放行），
  但只写计数列、不碰 moderation 列，当前无实际绕过

---

## 🟠 P1 — 纯远程可达：社区作品下载无大小上限（OOM/DoS）

`glb_cache.dart:28-37` 的 Dio 无 `maxContentLength`；`:123-127` 全量读进内存；
`sparse_cloud_viewer_page.dart:35` PLY `readAsBytesSync()` 无上限。
**触发是自动的**：滚到 feed 卡片即经 `live_model_view.dart:395` →
`glb_asset_cache.dart:68-75` 下载 + `loadGltfFromBuffer` 进 Filament/cgltf。
任何能发布作品的账号上传超大/畸形文件 ⇒ 刷到该卡片的用户 OOM 或 native 解析器崩溃。
`works.format` 也来自 DB 行，可声称 ply 却投喂任意字节。

⚠️ **勘误（2026-08-17 调研查证后）**：本节原写"修法：Dio 加 maxContentLength"——**错误，Dio
没有这个选项**（`maxContentLength` 是 axios 的概念，`BaseOptions` 全部属性里无此字段，
见 pub.dev/documentation/dio/latest/dio/BaseOptions-class.html）。真正可行的守卫是
`ResponseType.stream` + 逐块累计字节 + 超限 `CancelToken.cancel()`，或直接用
`dio.download()` 落盘并在 `onReceiveProgress` 里中断。预检 Content-Length 只是省流量的
优化（chunked 编码可绕过），**流式计数才是安全边界**。
另：`flutter_cache_manager`(MIT) 只有对象数与时效上限、无字节上限与哈希校验，
解决不了这个问题；pub.dev 上**不存在** PLY 流式解析包，且 native 侧 `cgltf_parse_file`
与 thermion 的 `loadGltfFromBuffer` 本身要求完整文件 ⇒ 可达的最优不是"流式解析"，
而是"**有上限地直接落盘 + 把路径喂给 native**"（峰值内存从 ~2× 降到 ~1×）。
最便宜的第一道闸其实在服务端：`works` 桶 file_size_limit 现为 **500MB**，而实际稀疏
点云仅约 1.4MB —— 官方 scaling 文档明文推荐"在桶级别设最大文件尺寸"作最外层闸。

## 🟠 P1 — 密码明文落库

`pending_signups.password text not null`（20260429000000:22），
`signup-start/index.ts:102` 在 OTP 校验**之前**就写明文，`signup-verify:90` 读回。
进 WAL、进 PITR、进每日备份；`signup-verify:107` 的删除是 best-effort（返回值未检查），
cron 每 5 分钟才扫且只删已过期行。
修法：start 阶段根本不收密码，verify 时客户端重传（客户端本就持有，
supabase_auth_service.dart:123-136 的 EmailVerificationPending）。

## 🟡 P2

- **会话令牌明文存 SharedPreferences**：main.dart:194-206 未传自定义 localStorage，
  supabase_flutter 2.20.0 默认落 `Library/Preferences/<bundle>.plist` 明文 JSON，
  含长效 refresh_token，**不进 Keychain**；全仓无 flutter_secure_storage、
  无 setExcludedFromBackup ⇒ 未加密备份/越狱/取证可完整带走并离线冒充登录
- ~~**重置密码不吊销旧会话**~~ 🔴 **本条已撤销（2026-08-17 源码级查证推翻）**：
  GoTrue 自 2023-07-03（commit `b079c35`，最早 tag v2.79.0）起，
  `admin.updateUserById(password)` → `user.UpdatePassword(tx, nil)` →
  `Logout(tx, u.ID)` → `DELETE FROM sessions WHERE user_id = ?`，
  **已自动删除该用户全部 session**，代码路径无开关可关。
  commit 原文："When an admin changes a password for a user, the logout is also
  performed now."。官方 sessions 文档亦载用户改密会终止 session。
  ⇒ `password-reset-verify:110-113` **无需改动**；真实残留窗口仅为旧 access token
  的剩余寿命（默认 exp 3600s，官方："Access Tokens of revoked sessions remain valid
  until their expiry time"）。
  ⚠️ 附带纠正：GoTrue **不存在** `POST /admin/users/{id}/logout` 端点；
  `admin.signOut()` 参数是该用户的有效 JWT 而非 userId。
  ⚠️ Dart 的 `signOut()` 默认 `SignOutScope.local`（JS 默认 global），
  要全设备登出须显式传 `scope: SignOutScope.global`。
- **listUsers 只取第 1 页（perPage:1000）**：signup-start:71-74 /
  password-reset-start:60-63 / password-reset-verify:90-93。过 1000 用户后靠后用户
  **永久无法重置密码且无任何错误提示**；注册重复检查失效。定时炸弹，须在增长前改
  `getUserByEmail`
- **私信可自助闯入**：communications.sql:177-188 的 WITH CHECK 第一支
  `user_id = auth.uid()` 无会话归属条件 ⇒ 任何登录用户知道 conversation_id 即可
  把自己插成成员，读全部历史 + 发消息；且**没有任何策略能踢人**（:190-192 只允许删自己）
- **Documents 目录对外完全开放**：Info.plist:78-79 `UIFileSharingEnabled=true` +
  :38-39 `LSSupportsOpeningDocumentsInPlace=true` ⇒ Files app/Finder 可读写。
  这把 `official_env.json` 的 env 注入从"需要文件写入漏洞"降级为"任何有设备访问者
  都能落文件"；且 device_log/telemetry/全部捕获数据可被导出
- **env 注入无 key 白名单**：official_aether_sfm_ffi.dart:88 唯一校验是
  `startsWith('OFFICIAL_')`，无 key 白名单、无 value 校验。前缀过滤挡住了
  DYLD_INSERT_LIBRARIES 等高危键（**不是任意代码执行**），但 native 侧可能读
  Dart 从未引用的 OFFICIAL_ 键，若有取路径的键即可改 native 读写目标
- **开发钩子编进 release**：main.dart:161-173 无条件调 maybeRunB1Gate /
  maybeRunEncoderProbe，触发文件落 Documents（配合上条=可投放）⇒ 本地 CPU/GPU/电量 DoS
  （b1_gate_runner 会持 reconstructionLease 跑双臂重建）。**不是远程后门**：只读源数据、
  只在副本操作、无鉴权绕过、无外发
- **profiles 间接泄露邮箱**：auto_init_user_profile.sql:29 用
  `split_part(email,'@',1)` 作默认 display_name，而 profiles_select_public 对 anon 全开
  ⇒ 未改过名的用户邮箱本地部分公开可读

## 🟢 P3 / 硬化

- `signup-start` upsert 覆盖 ⇒ 可作废他人正在进行的注册验证码（注册 DoS）
- `Math.random` OTP（signup-start:93）：当前**不可利用**（无 PRNG 输出暴露给攻击者），
  但 P0 修复后仍建议换 `crypto.getRandomValues`，成本极低
- `storage-sign-upload` 的 `thumbnailExtByContentType[ct]` 对象字面量查表会命中
  `Object.prototype.constructor`（归一化后仍全小写的原型键只此一个）⇒ 白名单不是白名单。
  实际危害仅畸形文件名。修法：`Object.create(null)` / `Object.hasOwn` / switch
- `createSignedUploadUrl(path)` 只绑 path，**不绑 content-type 与大小** ⇒ 函数里所有
  requireContentType/requireMaxBytes 都是君子协定，拿到 token 可传任意字节
  （scans 桶 allowed_mime_types 为 null、2GB 上限）
- `EXPIRES_IN_SECONDS=60` 是装饰性的：`:93` 单参调用根本没把 60 传进去，真实 TTL 是
  服务端固定值（历史约 2 小时）⇒ 审计日志与客户端记录**误导取证**
- `insertAuditLog` 用 try/catch 包 supabase-js 调用，但它不抛异常只返回 `{error}`
  ⇒ `:346` 的 console.warn 永不执行，审计写入失败 100% 静默
- 四个旧 RPC（ack_scan_upload / request_scan_training / mark_scan_*）只 grant 未 revoke
  ⇒ anon 也能调，目前靠 `auth.uid()` 为 NULL 侥幸安全（碰巧安全≠设计安全）
- `works_insert_self`(storage) 未被 broker 迁移撤销 + 桶 public + 500MB ⇒ 免费公网大文件托管
- `follows_select_all using (true)` ⇒ 私密账号的关注图完整泄露
- `mentions_insert_self` 不约束 mentioned_user_id ⇒ 可伪造对任意用户的 @提及驱动通知扇出
- `live_sessions_select` 对 anon 放行含 metadata jsonb 全表枚举
- release 日志打邮箱：main.dart:216-218 裸 `print` 含 `currentUser?.email` ⇒ 进 os_log，
  Console.app 可读（注释里"release 会吞掉 print"的认知不准确）
- `NSLocalNetworkUsageDescription` 用途串与实际不符（云端走公网 HTTPS 非 LAN），
  且未声明 NSBonjourServices ⇒ 权限过度声明/审核卫生问题
- 多处把内部错误原样回给调用者（`detail: String(e)`）⇒ 轻度信息泄露

---

## ✅ 明确核实为干净 / 攻击面不存在（不用管）

**密钥面**
- 客户端只有 publishable key（endpoint_config.dart:79），类型正确、本应公开
- 全仓无 service_role JWT、无 `sb_secret_`、无 AWS/GCP/R2 凭据、无私钥、无 .env 文件
- service_role 与 RESEND_API_KEY 仅在 Edge Function 内 `Deno.env.get` 读取，无硬编码回退
- 不记录 access_token/refresh_token 明文

**iOS 配置**
- ATS 未被放宽（无 NSAllowsArbitraryLoads），强制 HTTPS
- 隐私权限最小：仅 Camera + Motion + LocalNetwork，无相册/麦克风/定位/通讯录
- UIBackgroundModes 仅 fetch + processing，与 BGTaskScheduler 标识对应
- entitlements 最小：仅 increased-memory-limit + extended-virtual-addressing，
  无 keychain-access-groups / associated-domains / app-groups
- **无自定义 URL scheme ⇒ 无深链劫持面**（全仓无 CFBundleURLTypes、无 app_links/uni_links）
- **无 WebView / JS bridge**（WKWebView 已移除，现为 Thermion 纹理渲染）
- **无任何 analytics/crash SDK**（无 Sentry/Firebase/Crashlytics/Mixpanel/友盟等）
- **原生 iOS 代码零网络出口**（无 URLSession/dataTask），native 遥测只写本地 jsonl
- 无 bypass/backdoor/skip-verify/trustAllCerts 类 release 开关

**FFI 内存安全（official 绑定）— 规范，可归档为低风险**
- count-first + clamp：`:658-687`(poses)、`:1727-1750`(previewPoints)、`:1795-1830`(pointsPacked)
  均先取 count 再 `min(countPtr.value, n)` 写出，不会越界
- lib 拥有的缓冲由 lib 释放（`:709`、`:1824` 用 `_pointsFree`），不跨分配器 free
- try/finally 全覆盖，malloc/free 一一配对；AetherProcessEnv 也在 finally free
- 入参下溢有 Dart 侧兜底（`:1065` setRange 先抛 RangeError，不让 native 读未初始化内存）
- glb_norm FFI：calloc/free 配对、C 缓冲 copy-out 后立即 bufferFree、NativeCallable
  在 finally close()
- PLY 解析有 `body.length < n*15` 前置边界检查、头部扫描限定前 4096 字节

**被推翻的担忧（明确排除，不必处理）**
- ❌ "OTP 比对非常数时间可被时序枚举"——比对的是 SHA-256 哈希，要利用前缀时序泄漏
  等于求部分原像，**哈希化恰好中和了时序攻击**
- ❌ "JWT 伪造 / algorithm confusion / 过期绕过"——`getUser(jwt)` 走 GoTrue 服务端
  校验（非本地解 JWT），稳固
- ❌ "storage-sign-upload 路径 traversal / 跨用户覆盖 / 信任客户端 user_id"——
  `:141-143` 拒 `/`开头、`..`、`//`；路径强制前缀 `${userId}/${scanId}/` 或精确等于
  `${userId}/${workId}.${ext}`；userId 全取自 JWT，请求体无 user_id 字段。
  **这块是全仓做得最扎实的部分**
- ❌ "SQL 注入 / 邮件模板注入"——全走 supabase-js 参数化构造器，邮件只插服务端生成的
  纯数字 OTP、不渲染 email/display_name，收件人作 JSON 值传递（无头注入）
- ❌ "`evil-supabase.co` 能绕过 endpoint_config 白名单"——`endsWith('.supabase.co')`
  语义下正确拒绝（倒数第 12 字符是 `-` 非 `.`）。**真正的弱点是白名单钉的是整个共享
  PaaS 域**：`attacker-project.supabase.co` 能过。当前 configEndpoints 为空（休眠），
  启用前应收紧为精确项目 ref + 证书固定
- ❌ "GlbCache 缓存投毒"——键是 sha1(URL) 且每作品 URL 唯一，无跨用户投毒，
  代价仅同 URL 内容替换后命中旧缓存（陈旧非安全）

---

## 建议处理顺序

1. **立刻**：OTP 计数原子化 + `-start` 加 per-email/per-IP 冷却（堵账号接管）
2. **本周**：修我今天那三个缺陷——补全七张关联表谓词、删 `work_views_insert` 策略、
   下架时同时置 visibility=private 并处理 storage 对象、给 DELETE 也加守卫；
   `signup-start` 改静默 200 + 等时返回
3. **本迭代**：GlbCache 加大小上限；pending_signups 去明文密码；session 改 Keychain；
   listUsers 换 getUserByEmail；conversation_members 收紧；重置密码后吊销旧会话
4. **硬化**：`Object.create(null)`；四个旧 RPC 补 revoke；删 AUTH-DEBUG 邮箱打印；
   env 白名单；开发钩子排除出 release；评估关 UIFileSharingEnabled
