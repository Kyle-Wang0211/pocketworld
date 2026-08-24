# PocketWorld backend (Supabase)

Auth flow + database schema + Edge Functions + Storage buckets for the
PocketWorld Flutter app. This README is the one place documenting the
architectural decisions that aren't obvious from reading any single
file.

If you're a future contributor (or future-you in 3 months) trying to
understand why something is the way it is — start here.

---

## Table of contents

1. [Architecture at a glance](#architecture-at-a-glance)
2. [Auth flow](#auth-flow)
3. [RLS philosophy](#rls-philosophy)
4. [Schema overview (26 tables)](#schema-overview)
5. [Storage buckets (4)](#storage-buckets)
6. [Edge Functions (14)](#edge-functions)
7. [pg_cron jobs](#pg_cron-jobs)
8. [Deployment](#deployment)
9. [Migrating off Supabase](#migrating-off-supabase)
10. [Open work](#open-work)

---

## Architecture at a glance

```
┌────────────────────────────────────────────────────────────────┐
│                    Flutter app (iOS / Android)                  │
│   • lib/auth/       — CurrentUser ChangeNotifier + AuthService │
│   • lib/ui/auth/    — Sign in / Sign up / OTP / Reset password │
│   • supabase_flutter SDK 2.8.x                                  │
└─────────────────────────────┬──────────────────────────────────┘
                              │ HTTPS (anon key for SDK,
                              │        no auth for our Edge Fns)
                              ▼
┌────────────────────────────────────────────────────────────────┐
│            Supabase project (Pro tier, US East)                 │
│   • Postgres 15            (8 GB cap on Pro)                    │
│   • GoTrue Auth            (issues JWT sessions)                │
│   • Storage                (4 buckets, 100 GB Pro cap)          │
│   • Edge Functions (Deno)  (4 functions, 2M invocations/mo)     │
│   • pg_cron                (cleanup expired pending rows)       │
└────────────────────────────────────────────────────────────────┘
```

Two non-default decisions that shape everything else:

1. **Strict-confirmation signup** — we don't call `auth.signUp` from the
   client. Instead, our `signup-start` Edge Function holds the signup
   in a `pending_signups` table (with hashed OTP) and only calls
   `admin.createUser` after the OTP is verified. This avoids "ghost"
   `auth.users` rows that block re-signup, and lets us localize the
   OTP email per-user via metadata.

2. **Strict-OTP password reset** — same pattern, different table
   (`pending_password_resets`). Replaces `auth.resetPasswordForEmail`
   so we get the same i18n control over the recovery email and we
   don't leak SMTP errors back to the client.

Everything else (RLS, triggers, cached counts) is straight Supabase
+ standard Postgres.

---

## Auth flow

### Sign-up

```
  1. User types email + password in EmailSignUpView
  2. Dart → POST /functions/v1/signup-start
                { email, password, display_name?, locale }
  3. signup-start:
     a. listUsers + filter — refuse if email is already in auth.users
        (returns 409 account_already_exists)
     b. Generate 6-digit OTP, sha256 hash, upsert pending_signups
     c. Send OTP via Resend API (zh or en template)
     d. Return 200 ok
  4. Dart catches via EmailVerificationPending(email, password)
     → push OtpVerificationView (carries password forward)
  5. User types 6-digit OTP → POST /functions/v1/signup-verify
                                   { email, otp }
  6. signup-verify:
     a. Look up pending_signups, validate OTP hash, attempts < 5
     b. admin.createUser(email_confirm: true, ...)  ← real auth.users
     c. The on_auth_user_created trigger auto-creates:
          - public.profiles row
          - public.notification_settings row
     d. Delete pending_signups row
     e. Return 200 ok
  7. Dart calls signInWithPassword(email, password) → real session
  8. CurrentUser._state = signedIn → AuthGate routes to HomeScreen
```

Why pass password forward in `EmailVerificationPending`:
admin.createUser returns no session. The client has to do a normal
signInWithPassword to obtain one. The only way to do that without
making the user retype is to keep the password in memory across
the OTP screen. That's what `EmailVerificationPending(email, password)`
exists for.

### Password reset

Symmetric flow, separate tables/functions:

```
  1. EmailSignInView "忘记密码?" → push ResetPasswordView
  2. Step 1: enter email
     → Dart → POST /functions/v1/password-reset-start
                  { email, locale }
     → signup-start emails OTP (or silently 200 if email not registered)
  3. Step 2: enter OTP + new password (same page)
     → Dart → POST /functions/v1/password-reset-verify
                  { email, otp, new_password }
     → admin.updateUserById to rotate password
     → Dart calls signInWithPassword → session
     → CurrentUser._state = signedIn → HomeScreen
```

### Bilingual emails

Both Edge Functions accept a `locale` parameter (`'zh'` or `'en'`) and
pick the email body accordingly. The client passes the current
`LocaleNotifier.locale.languageCode`. Supabase's built-in email
templates aren't used for signup/reset — too restrictive for i18n.

The remaining built-in template — "Confirm signup" via Auth → Email
Templates — is rendered when our `admin.createUser` runs (which has
`email_confirm: true`, so it doesn't actually send a real-confirmation
email; the template still exists but is dead).

### iOS Keychain autofill

`AutofillGroup` wraps each form. Email fields use
`AutofillHints.username`, password fields use `AutofillHints.password`
or `AutofillHints.newPassword`. On successful submit we call
`TextInput.finishAutofillContext()` so iOS shows "Save Password to
Keychain". For autocorrect/suggestions to be off (otherwise iOS won't
recognize the field as a password), `AuthField` forces these off when
`isSecure || keyboard == email`.

### Session persistence (30-day idle)

Supabase Flutter SDK persists sessions automatically (SharedPreferences
on Android, Keychain-backed on iOS). On app start, `CurrentUser.bootstrap`
calls `_service.currentUser()` which reads `_client.auth.currentSession`.
On top of that, `CurrentUser` tracks a 30-day "idle since last activity"
timestamp; if exceeded, force-signout regardless of token validity.

---

## RLS philosophy

Every table has RLS enabled, and **public tables follow this layered
pattern**:

```
  SELECT  : own row OR a "visible to others" predicate (e.g.
            visibility = 'public')
  INSERT  : authenticated, with check (user_id = auth.uid())
  UPDATE  : owner only (using = with check)
  DELETE  : owner only (or controlled cascade)
```

Internal-only tables (`audit_logs`) have RLS enabled but **zero
policies** — meaning no client (anon or authenticated) can read/write,
only `service_role` (used by Edge Functions and the SQL Editor) can.

Cached counts (`profiles.works_count`, `works.likes_count`,
`tags.works_count`, etc.) are maintained by `SECURITY DEFINER`
triggers so they update even when the trigger-firing client wouldn't
have UPDATE rights on the count column.

The `'followers'` value in `works.visibility` and similar CHECK
constraints is kept in the schema as a forward-compat slot. Until the
followers UI ships, the RLS treats it like `'private'`. When the UI is
ready, do `alter policy works_select_visible ... using (
  visibility = 'public' OR auth.uid() = user_id OR
  (visibility = 'followers' AND exists (select 1 from public.follows ...))
)`.

---

## Schema overview

26 tables across 7 logical migrations:

| Migration                       | Tables                                                                 |
|---------------------------------|------------------------------------------------------------------------|
| 020000_core_business            | profiles, projects, scans, works, comments                             |
| 020001_engagement               | work_likes, work_bookmarks, comment_likes, work_views, work_versions   |
| 020002_social_graph             | follows, blocks                                                        |
| 020003_discovery                | tags, work_tags, mentions                                              |
| 020004_communications           | notifications, notification_settings, conversations, conversation_members, messages, live_sessions, live_participants |
| 020005_moderation               | reports, audit_logs, collections, collection_works                     |
| 030000_auto_init_user_profile   | (just trigger + backfill, no new tables)                               |

Plus 2 earlier migrations for the auth flow:

| Migration                       | Tables                                                                 |
|---------------------------------|------------------------------------------------------------------------|
| 000000_pending_signups          | pending_signups                                                        |
| 010000_pending_password_resets  | pending_password_resets                                                |

Total: 28 tables in `public`.

### Key relationships

```
auth.users (Supabase)
  ├── profiles            (1:1, FK to auth.users.id)
  ├── notification_settings (1:1, FK to auth.users.id)
  ├── projects            (1:N)
  ├── scans               (1:N)         scans.project_id → projects (nullable)
  ├── works               (1:N)         works.scan_id → scans (nullable)
  │                                     works.project_id → projects (nullable)
  │   ├── comments        (1:N)
  │   │   ├── comment_likes
  │   │   └── (parent_id) for threading
  │   ├── work_likes
  │   ├── work_bookmarks
  │   ├── work_views
  │   ├── work_versions
  │   └── work_tags ──→ tags (M:N)
  ├── follows             (M:N self-ref via follower_id / followee_id)
  ├── blocks              (M:N self-ref)
  ├── notifications       (recipient_id)
  ├── conversations / conversation_members / messages
  └── live_sessions / live_participants
```

`audit_logs` is intentionally not FK-linked (rows survive user
deletion).

---

## Storage buckets

| Bucket       | Public read | File size limit | Allowed mimes                                | Path convention                  |
|--------------|-------------|-----------------|----------------------------------------------|----------------------------------|
| avatars      | yes         | 5 MB            | image/jpeg, png, webp, heic                  | `{user_id}/...`                  |
| thumbnails   | yes         | 10 MB           | image/jpeg, png, webp                        | `{user_id}/...`                  |
| works        | conditional | 500 MB          | model/gltf-binary, application/octet-stream  | `{user_id}/{work_id}.{format}`   |
| scans        | private     | 2 GB            | (any)                                        | `{user_id}/{scan_id}/...`        |

Path convention enforced by RLS: `(storage.foldername(name))[1] = auth.uid()::text`
ensures only the owner can write. For `works`, the SELECT policy
additionally checks `public.works.visibility = 'public'` so anonymous
users can read public work files but not private ones.

---

## Edge Functions

### Auth functions (public)

These four are reachable by anonymous users (someone signing up has no
session yet), so they cannot require a user JWT.

**Deployment flag — read this before redeploying.** They were originally
deployed with `--no-verify-jwt`, which allows a request carrying *no*
`Authorization` header at all. As of 2026-08-18 they were redeployed
**without** that flag, so the platform now rejects header-less requests
before they reach the function.

This is a tightening, not a break, and it was verified rather than
assumed: the app calls them through `supabase_flutter`, whose
`functions.invoke()` always attaches the publishable key, and the signup
path was tested end-to-end after the change (`{"ok":true}`, 200). The
function's own auth logic is unaffected either way.

⚠️ Consequence: a bare `curl` with no `Authorization` header now gets
`401 UNAUTHORIZED_NO_AUTH_HEADER` from the platform. Pass
`-H "Authorization: Bearer <publishable key>"` when testing by hand. To
restore the older, looser behaviour, redeploy with `--no-verify-jwt`.

| Function              | Purpose                                                                                         |
|-----------------------|-------------------------------------------------------------------------------------------------|
| signup-start          | Begin a strict-confirmation signup. Refuses if email exists, otherwise upserts pending_signups + emails OTP |
| signup-verify         | Validate OTP, call admin.createUser with email_confirm:true, delete pending row                 |
| password-reset-start  | Same pattern for password reset (silent on missing email for security)                          |
| password-reset-verify | Validate OTP, admin.updateUserById to set new password, delete pending row                      |

### Rate limiting — corrected 2026-08-18

An earlier version of this section claimed these endpoints had
"per-email rate limits via `pending_*` tables". **That was never true.**
The `pending_*` tables only ever carried an `attempts` counter that the
*verify* side incremented, while the *start* side reset it to 0 — there
was no cooldown anywhere, and the endpoints could be called without
limit.

What exists now (migration `20260817010000`):

- `edge_rate_limits` table + `consume_rate_limit(key, limit, window)`, a
  fixed-window counter implemented as a single atomic upsert.
- signup / password-reset **start**: 3 per email per 15 min, 20 per IP
  per hour. A throttled call returns a response **identical to the happy
  path** — returning a distinguishable error would turn the limiter into
  an account-enumeration oracle.
- OTP attempt caps are enforced by `consume_*_otp_attempt`, which spends
  the quota **before** comparing the hash, so a correct guess and a wrong
  guess cost the same. (The previous read-then-write counter could be
  defeated by issuing attempts concurrently.)

All limiters are fail-open: if the limiter itself errors, the request
proceeds. A broken limiter must not be what stops someone from signing
up — and since it is one atomic upsert, "broken" implies the database is
already in trouble.

### Server-side functions (service_role or user JWT)

| Function            | Auth                    | Purpose                                                        |
|---------------------|-------------------------|----------------------------------------------------------------|
| storage-sign-upload | user JWT                | Mints one-shot signed upload tokens after ownership checks      |
| delete-account      | user JWT, or service_role + `target_user_id` | Real account deletion (Guideline 5.1.1(v)) — enumerates every storage object *before* the `auth.users` cascade, since the cascade destroys the paths |
| delete-work         | user JWT                | Author removes their own published work, files included. Refuses while the work is under moderation |
| admin-moderate-work | service_role **only**   | Takedown/restore. Moves assets into the private `quarantine` bucket — deleting the DB row is not enough because a public bucket bypasses RLS, and storage objects cannot be deleted from SQL |

`admin-moderate-work` **must** be deployed with `--no-verify-jwt` so the
service_role key arrives as a plain bearer token instead of being
pre-validated as a user JWT.

### Dependency pinning

All functions import `jsr:@supabase/supabase-js@2.112.3` — a full
version, never a bare `@2`. `@2` is a semver *range*: it re-resolves on
every deploy, which makes deploys non-reproducible and leaves a window
for a compromised upstream release. `tool/verify_supply_chain.sh`
enforces this and checks the version is identical across functions.

### Required secrets

Set in **Edge Functions → Secrets** in the Supabase dashboard, never
in chat / git:

| Secret                     | Used by                | Where to get                          |
|----------------------------|------------------------|---------------------------------------|
| SUPABASE_URL               | all four               | auto-populated                        |
| SUPABASE_SERVICE_ROLE_KEY  | all four               | auto-populated                        |
| RESEND_API_KEY             | -start functions       | https://resend.com/api-keys           |
| PW_EMAIL_FROM (optional)   | -start functions       | defaults to `PocketWorld <noreply@pocketworld.io>` |

`RESEND_API_KEY` is **not** the same place as Auth → Email → SMTP
Settings (those are separate paths). Both use the same Resend key
value, but there are two storage locations and you must update both
when rotating.

---

## pg_cron jobs

Scheduled in migration files via `cron.schedule(...)`. Inspect:
`SELECT jobid, schedule, jobname FROM cron.job ORDER BY jobid;`

| Job name                                  | Schedule       | What it does                                                  |
|-------------------------------------------|----------------|---------------------------------------------------------------|
| cleanup-expired-pending-signups           | every 5 min    | DELETE FROM pending_signups WHERE expires_at < now()          |
| cleanup-expired-pending-password-resets   | every 5 min    | DELETE FROM pending_password_resets WHERE expires_at < now()  |

Each is idempotent and self-recreating — re-running the migration
unschedule + reschedules without duplicating.

---

## Deployment

### From scratch (a brand-new Supabase project)

```bash
# 1. Install Supabase CLI (Homebrew if your Xcode CLT is current,
#    or manual binary download from github.com/supabase/cli/releases)
brew install supabase/tap/supabase

# 2. Login + link
supabase login           # opens browser OAuth
supabase link --project-ref <YOUR_PROJECT_REF>

# 3. Apply all migrations atomically
cd pocketworld_flutter
supabase db push

# 4. Deploy Edge Functions — ALL FOURTEEN.
#    An earlier version of this list had only the four auth functions, which
#    silently produced a project whose thumbnail upload path 404s.
#
#    2026-08-23: the list had drifted again and was WORSE than that — it said
#    "ALL EIGHT" while the repo carried ten functions. The two missing ones
#    were upload-finalize and set-profile-name, and both fail *silently*:
#      · upload-finalize missing  ⇒ client uploads land in `staging` and are
#        never promoted; the invoke fails non-2xx and (before the 2026-08-23
#        fix) the client swallowed it as "network error, please retry", so the
#        user re-uploads tens of MB forever with no diagnosable symptom.
#      · set-profile-name missing ⇒ display-name changes fail; since migration
#        20260823010000 there is NO other write path to profiles.display_name,
#        so renaming is simply dead.
#    Keep this list in sync with `ls supabase/functions/` (minus _shared).
supabase functions deploy signup-start          --project-ref <REF>
supabase functions deploy signup-verify         --project-ref <REF>
supabase functions deploy password-reset-start  --project-ref <REF>
supabase functions deploy password-reset-verify --project-ref <REF>
supabase functions deploy storage-sign-upload   --project-ref <REF>
supabase functions deploy delete-account        --project-ref <REF>
supabase functions deploy delete-work           --project-ref <REF>
supabase functions deploy upload-finalize       --project-ref <REF>
supabase functions deploy set-profile-name      --project-ref <REF>

# admin-moderate-work is the one function that REQUIRES --no-verify-jwt:
# it authenticates by comparing the bearer token against the service_role
# key itself, so the token must reach the function unvalidated rather than
# being pre-checked as a user JWT.
supabase functions deploy admin-moderate-work   --no-verify-jwt --project-ref <REF>

# admin-approve-work 是"先审后发"的放行端(under_review → ok + 补 published_at)。
# 与 admin-moderate-work 同样按 service secret 鉴权,所以同样需要 --no-verify-jwt。
supabase functions deploy admin-approve-work    --no-verify-jwt --project-ref <REF>

# admin-reports 是举报的**受理端**(第九条)。在它之前 reports 表有行、App 里
# 有举报入口,但**没有任何路径读它** —— 举报等于扔进黑洞。
# 同样按 service secret 鉴权,同样需要 --no-verify-jwt。
supabase functions deploy admin-reports         --no-verify-jwt --project-ref <REF>

# report-region 写 profiles.last_region(第十二条 IP 属地)。普通用户 JWT 鉴权,
# 不需要 --no-verify-jwt。
supabase functions deploy report-region         --project-ref <REF>

# send-sms-hook 是 Supabase 的 **Send SMS Hook**,由 GoTrue 服务端回调,
# 带的是 Standard Webhooks 签名而不是用户 JWT ⇒ 必须 --no-verify-jwt,
# 否则平台会在函数拿到请求前就把它 401 掉。
#   ⚠️ 部署完还要在 Dashboard → Authentication → Hooks 里把它设为 Send SMS Hook,
#      并配 4 个 secret(见下面「阿里云短信」一节)。不配 = 手机号登录发不出短信。
supabase functions deploy send-sms-hook         --no-verify-jwt --project-ref <REF>

# 4b. 调用管理端(admin-*)需要 **service secret**,不是 CLI 给的 service_role JWT。
#     2026-08-23 实测:本项目 Edge Function env 里的 SUPABASE_SERVICE_ROLE_KEY
#     已经是 41 字符的新格式 secret(sb_secret_*),而
#     `supabase projects api-keys` 返回的 service_role 是 219 字符的 legacy JWT
#     —— 两者不是同一个值,拿后者去调管理端一律 403。
#     CLI 对那个 secret 是 masked 的(--output json 里 masked=true),拿不到全文。
#     取法:Dashboard → Project Settings → API Keys → Secret keys → 复制 `default`。
#     (函数侧已同时接受两种,见 supabase/functions/_shared/admin_auth.ts。)

# 5. Set RESEND_API_KEY secret via dashboard (NOT via CLI / chat)
#    https://supabase.com/dashboard/project/<REF>/functions/secrets

# 6. Verify
supabase db push --dry-run     # should print "Remote database is up to date"
supabase functions list        # should show 11 ACTIVE
supabase db advisors --type security --linked   # triage before going live

# 7. Supply chain. CI does run this now (.github/workflows/security.yml,
#    job `edge-deps-integrity`, which since 2026-08-23 also runs
#    `deno test` over supabase/functions). Running it by hand before
#    shipping is still worthwhile — CI only covers what is committed.
zsh ../tool/verify_supply_chain.sh
```

### Incremental migration (adding a new feature)

1. Write a new SQL file in `supabase/migrations/<UTC_TIMESTAMP>_<name>.sql`
2. `supabase db push` — applies only the new file
3. If the migration adds a new Edge Function, deploy it **without**
   `--no-verify-jwt`. That flag is not the default it once looked like: it
   lets a request with no `Authorization` header at all reach your code.
   Only add it when the function authenticates by inspecting the raw bearer
   token itself — today that is `admin-moderate-work` alone, which compares
   the token against the service_role key.

   ```bash
   supabase functions deploy <name> --project-ref <REF>
   ```

4. If the function imports a new dependency, pin the **full** version
   (`jsr:@supabase/supabase-js@2.112.3`, never `@2`) and run
   `zsh tool/verify_supply_chain.sh`.

---

## Migrating off Supabase

The schema is portable Postgres. The Supabase-specific bindings are
isolated and tagged with `[PORTABLE]` comments. To move to self-hosted
Postgres / Tencent CDB / Aliyun RDS:

```
$ grep -rn "\[PORTABLE\]" supabase/migrations/ | wc -l
   80+
```

Each `[PORTABLE]` marker is one of three things:

1. **`auth.users(id)` references** — Supabase's auth schema. On migration:
   - Set up your new auth provider, ideally one that issues JWTs with a
     `sub` claim equal to a UUID per user.
   - Mirror auth.users (or its replacement) under whatever schema your
     new stack uses.
   - Replace each `references auth.users(id)` with `references <new>.users(id)`.
   - Preserve UUIDs across the dump/restore so downstream FKs survive.

2. **`auth.uid()` calls inside RLS policies** — Supabase helper that
   reads the `sub` claim from the JWT. On self-hosted, replace with:
   ```sql
   create or replace function public.current_user_id()
   returns uuid as $$
     select coalesce(
       current_setting('request.jwt.claims', true)::jsonb->>'sub',
       null
     )::uuid;
   $$ language sql stable;
   ```
   Then `sed -i 's/auth\.uid()/public.current_user_id()/g'` across all
   policy definitions.

3. **`storage.objects` policies** — Supabase Storage's table. On
   migration to S3 / Aliyun OSS / Tencent COS:
   - The path convention `{user_id}/{...}` translates 1:1 to bucket
     prefixes.
   - Re-implement the equivalent prefix-based policies in the new
     provider's policy DSL (AWS IAM, OSS RAM, COS CAM).
   - Update the Flutter Storage SDK calls (or write a thin abstraction
     around bucket operations now to ease the future swap).

Edge Functions need a full rewrite for whatever serverless platform
the new stack uses (AWS Lambda, Aliyun Function Compute, Cloudflare
Workers). The TypeScript logic itself is portable; only the
`createClient(...)` import and env-reading lines change.

`pg_cron` is built into all major managed Postgres offerings (Tencent
CDB, AWS RDS, Aliyun RDS via extension) so the cleanup jobs port
without changes.

---

## Open work

These are intentional v1 trade-offs flagged for future iterations:

| Item                                          | Why deferred                                                           |
|-----------------------------------------------|------------------------------------------------------------------------|
| `visibility = 'followers'` policy logic       | Followers UI not yet built; treated as private until then              |
| Audit log fan-out from Edge Functions         | Tables exist, but no Edge Function writes to them yet                  |
| Account switching (multiple sessions)         | v1 keeps single-session; multi-session is a P2 feature                 |
| `analytics_events` table                      | Skipped for v1 — add when product analytics is needed (separate from audit_logs) |
| LCC2 / `.spz` Gaussian Splat support in app   | Schema accepts these formats in `works.format`, but app upload pipeline needs work |
| Reports admin tooling                         | Reports table exists but no admin UI; review via SQL Editor for now    |

---

## Quick reference

```bash
# Run a one-off SQL query against the live DB (read-only sanity check)
supabase db query --linked "select count(*) from public.works"

# See all pending migrations (dry run)
supabase db push --dry-run

# Tail a function's logs
# (no CLI command yet — open in dashboard)
# https://supabase.com/dashboard/project/<REF>/functions/<name>/logs

# Inspect cron jobs
supabase db query --linked "select jobid, schedule, jobname from cron.job"
```


---

## 待配置项(代码已就绪,等外部配置)

这两块的**代码、schema、UI 都已经写完并合入**,但要真正生效还需要在
Supabase Dashboard / 阿里云控制台做配置,或者跑一次数据导入。
在配置完成之前,它们的表现是**优雅降级**而不是报错:短信发不出去、
属地那一行显示"未知"。两者都不会阻断任何已有功能。

### 1. 阿里云短信(手机号登录)

法条:《互联网用户账号信息管理规定》第九条要求真实身份认证"基于**移动电话
号码**、身份证件号码或者统一社会信用代码等方式",**邮箱不在这个列举里**,
而且"用户不提供真实身份信息的,不得为其提供相关服务"。所以手机号登录不是
可选项。

已就绪:

| 层 | 位置 | 状态 |
|----|------|------|
| 服务层 | `lib/auth/supabase_auth_service.dart:66` `SignInRequestPhone` → `verifyOTP(type: OtpType.sms)`;`:180` `signInWithOtp(phone:)` | ✅ 早已写好 |
| UI | `lib/ui/auth/phone_sign_in_view.dart` | ✅ 已 l10n 化(此前 8 处硬编码中文,因为这一页从未被接入过) |
| 入口 | `lib/ui/auth/auth_root_view.dart` "用手机号登录" | ✅ 2026-08-24 接上 |
| 短信通道 | `supabase/functions/send-sms-hook/index.ts` | ⚠️ 已写完并通过 `deno check`,但**从未真正发过一条短信** |

还需要你做(按顺序):

1. **阿里云**:开通短信服务 → 申请签名 → 申请模板(内容形如
   `您的验证码是 ${code},5 分钟内有效。`)→ 建一个只有
   `AliyunDysmsFullAccess` 的 RAM 子账号拿 AccessKey。
   签名和模板都要审核,**通常 1-2 个工作日**,别排在提交前一天。
2. **Supabase Dashboard → Authentication → Providers**:启用 Phone。
3. **Dashboard → Authentication → Hooks**:把 Send SMS Hook 指向
   `https://<REF>.supabase.co/functions/v1/send-sms-hook`,复制它生成的
   `v1,whsec_...` 密钥。
4. **Edge Functions → Secrets** 配 4 个:
   `SEND_SMS_HOOK_SECRET`(上一步那个 whsec)、`ALIYUN_ACCESS_KEY_ID`、
   `ALIYUN_ACCESS_KEY_SECRET`、`ALIYUN_SMS_SIGN_NAME`、`ALIYUN_SMS_TEMPLATE_CODE`。
   🔴 `SEND_SMS_HOOK_SECRET` 缺失时函数 **fail-closed**(拒绝所有请求)——
   一个不验签的短信端点等于把发短信的能力开放给任何人,那是直接的资金损失。

⚠️ 第一次真机联调若拿到 `SignatureDoesNotMatch`,按这个顺序查(RPC V2 签名
最常踩的四个坑,`index.ts` 顶部也抄了一份):
① `AccessKeySecret` 后面那个**尾随 `&`** 有没有丢;
② 参数是否按**字典序**排序后再拼;
③ 百分号编码是否把 `+`→`%20`、`*`→`%2A`、`%7E`→`~` 三处都换了;
④ `SignatureNonce` 是否每次都新生成。

### 2. IP 属地库导入

法条:《互联网用户账号信息管理规定》第十二条 —— "应当在互联网用户账号信息
页面展示合理范围内的……IP 地址归属地信息"。

已就绪:

| 层 | 位置 | 状态 |
|----|------|------|
| Schema | 迁移 `20260824000000_ip_region.sql`:`ip_region_ranges` 表 + `resolve_ip_region()` + `works.publish_region` + `profiles.last_region` | ✅ |
| 写入(内容) | `upload-finalize` 发布时写 `publish_region` | ✅ |
| 写入(账号) | `report-region` Edge Function 写 `profiles.last_region` | ✅ |
| 读取 | `community_service` → `FeedWork.publishRegion`;`MeStatsViewModel.lastRegion` | ✅ |
| 展示 | 作品卡片 `post_card.dart`;账号信息页 `me_settings_page.dart` | ✅ |
| **IP 库数据** | `public.ip_region_ranges` | ⚠️ **空表** —— 导入前所有属地都是 null |

还需要你做:

```bash
# 先只生成 CSV 看一眼(不联库)
node tool/import_ip2region.mjs --csv-only

# 真正导入(会先清空整张表再全量重建)
SUPABASE_URL=https://<REF>.supabase.co \
SUPABASE_SERVICE_ROLE_KEY=<service secret> \
node tool/import_ip2region.mjs
```

磁盘预算(Supabase 免费档只有 500MB):

| 范围 | 区间数 | CSV | 表+索引估算 |
|------|--------|-----|-------------|
| 仅 IPv4(`--skip-v6`) | 518,282 | 18.4 MB | ~45 MB |
| IPv4 + IPv6(默认) | 1,189,014 | 62.2 MB | ~140 MB |

🔴 建议**不要**用 `--skip-v6`。中国移动网络的 IPv6 占比已经很高,只导 IPv4
等于对一大批真实用户显示不出属地 —— 那正是第十二条要求展示的那一项。

数据源是 ip2region(Apache-2.0,可商用)。区间边界会随上游版本变动,
增量合并没有意义,所以脚本是**全量重建**;想更新就整个重跑一次。

⚠️ **迁到阿里云时必须单独验一件事**:属地的可信度完全建立在
`x-forwarded-for` 的第一项上。自建网关(SLB / Nginx)必须配
`proxy_set_header X-Forwarded-For $remote_addr`(**覆写**),
而不是 `$proxy_add_x_forwarded_for`(追加)—— 后者会把客户端自己塞的值
留在第一位,属地就能被任意伪造,这个展示也就等于没做。
细节见 `supabase/functions/_shared/client_region.ts` 的注释。


---

## 审核台(tool/moderation_console.html)

先审后发的**人这一端**。双击那个 html 用浏览器打开即可,`file://` 就行 ——
Edge Function 的 CORS 是 `Allow-Origin: *`,不需要起服务器。

### 🔴 为什么它不是 App 里的一个页面

`admin-approve-work` / `admin-moderate-work` / `admin-reports` 三个端都用
**service secret** 鉴权,那把钥匙绕过所有 RLS,能读写整个数据库。
放进 Flutter 客户端 = 把数据库钥匙发给每一个用户 —— 哪怕藏在隐藏入口后面,
App 二进制里的字符串是能被 dump 出来的。审核台必须留在你自己的机器上。

### 🔴 密钥从哪来 —— CLI 给不了

`supabase projects api-keys` 返回的 `sb_secret_*` 是**打过码的**:
2026-08-24 实测,它是 `sb_secret_hk1s-` 后面跟 26 个 U+00B7 中点(共 41 字符、
67 字节)。`masked` 字段现在**不出现**在 JSON 里,所以按字段判断会以为它没打码
—— 要看值本身。CLI 的 219 字符 legacy service_role JWT 能通过平台网关、
但过不了 `isAdminRequest`(本项目环境里的 `SUPABASE_SERVICE_ROLE_KEY`
已经是新格式 secret),实测返回 `{"error":"forbidden"}`。

⇒ 真正的密钥只能从 Dashboard 拿:
**Project Settings → API Keys → Secret keys → 复制 `default`**

密钥只存这个标签页的 `sessionStorage`,关掉就没了。
**不要把它写进那个 html —— 那个文件是进 git 的。**

### 两个队列

| Tab | 数据源 | 动作 |
|-----|--------|------|
| 待审队列 | `admin-approve-work` `{action:'list'}` | 通过 → `approve`;驳回 → `admin-moderate-work` `status:'removed'` |
| 举报队列 | `admin-reports` `{action:'list'}` | 下架并结案(两次调用);驳回举报 → `resolve` `status:'dismissed'` |

驳回和驳回举报都**强制要求写理由** —— 它进 `audit_logs`,是第九条"受理"义务的
证据,也是作者申诉时的依据。

「下架并结案」刻意是**两次调用**而不是一个原子操作:下架会搬文件、可能部分
失败,和结案绑在一个事务里只会产生"结案了但文件没搬走"这种没人发现的中间态。
顺序是先下架(会动文件的那一步),成功了再结案。

### ⚠️ 已知局限

审核台只给一张**缩略图**加一个模型下载链接。审的是 3D 内容,单一视角的缩略图
不足以判断整个点云里有什么 —— 拿不准的必须下载下来用查看器打开。
在浏览器里内联渲染 PLY 是下一步的事,不要因为"有缩略图了"就当成看过了。

### 验证状态

已验证:三个端都能部署;错 secret → 403;legacy JWT → 403(证明鉴权确实在拦);
`decorate()` / `attachTargets()` 里的每一条查询都用探针数据在生产库跑通
(列名、`profiles` 的 `in` 查询、两个桶的签名 URL 各自成功,探针已删干净)。

⚠️ **未验证**:带正确 secret 的完整端到端调用 —— 那个 secret 只在 Dashboard 里,
我拿不到。你第一次打开审核台粘贴密钥的那一刻就是这个测试。
如果 403,先看上面「密钥从哪来」那一节,别去改代码。


---

## 上线门槛(法务侧)—— 2026-08-24 定稿隐私政策/用户协议时立此清单

隐私政策与用户协议的**正文已完成**(lib/ui/legal/,契约测试
test/legal_docs_public_test.dart 钉住占位符与法定必备内容)。
但正文里若干句子为真的**前提**是下面这些事完成 —— 完成前两份文件不得生效,
App 不得提交:

| # | 门槛 | 现状 | 为什么挡发布 |
|---|------|------|--------------|
| 1 | 四个占位符替换(公司名/注册地/邮箱/生效日期) | 占位中 | 等公司注册;作品授权条款已于 2026-08-24 定稿(版权归作者+运营/推介/内部科研许可+对外仅匿名化) |
| 2 | Supabase → 阿里云迁移完成 | 未开始 | 政策写"存储于中华人民共和国境内"——迁移前这句是假的 |
| 3 | 邮件服务商换境内(现 Resend 在美国) | 未换 | 邮箱发往境外 = 个人信息出境;政策已把邮件服务商留为占位 |
| 4 | 首启同意弹窗(隐私政策摘要 + 同意/不同意,不默认勾选) | ❌ 无 | 《认定方法》一(2):首次运行未通过弹窗提示 = 违规;2026-04 网信办通报 33 款里 15 款栽在这条 |
| 5 | 注册页勾选框(不默认勾选)+ 年龄声明(14 周岁) | ❌ 只有默示文案 | PIPL 14 条自愿明确同意;14+ 门槛没有拦截手段就只是一句话 |
| 6 | 同意前零网络请求 | 未验证 | 认定方法三(1):征得同意前收集(IP 随首个请求到达服务端)即违规 |
| 7 | 未成年人模式三件套(时间/权限/消费管理) | ❌ 无 | 产品拍板 14+(允许 14-18 未成年人)⇒《未成年人网络保护条例》对网络社交服务的模式义务被触发;《移动互联网未成年人模式建设指南》原文尚未核读,需专项 |
| 8 | 首次发布"公开确认"弹窗(作品/昵称/属地将公开 + 单独确认) | ❌ 无 | PIPL 25 条:公开个人信息须单独同意;政策第一章已按"发布时您已知悉"写,产品要兑现这个节点 |
| 9 | 隐私政策 URL(ASC 必填)| 无域名 | 等域名 + ICP;URL 内容 = App 内同一份正文 |
| 10 | 手机号短信链路配通(阿里云签名/模板) | 代码就绪等配置 | 政策把手机号写成唯一必要信息、实名依据 —— 短信发不出去这些全是空话 |

⚠️ 追加触发器(2026-08-24 授权条款定稿时立):**云端存储功能上线** = 新增
功能 ⇒ ①安全评估变更报送;②隐私政策更新(当前只写了已发布作品的研究
用途,云储内容的研究使用要在该功能的告知里补);③云储上传流程的同意页
必须显著提示研究用途 —— 协议第六章第 3 款已覆盖云储,但告知义务在功能
上线时才算履行。

维护规矩:政策写的是**实际行为**。改保留期(audit_logs 180/730 天)、加收集项、
接任何 SDK,先改代码旁边的这两份正文,契约测试会把最容易漏的钉住。
