-- Kill switches — 攻击进行中时的止血阀
-- =====================================================================
-- 为什么在数据库层而不是 Edge Function 层:
--
--   模型上传是**直传**。publish_service.dart:173 直接调
--   `storage.from('works').uploadBinary(...)`,注释写明 "Direct owner-write
--   to the works bucket"。也就是说这条路径**根本不经过任何 Edge Function**。
--   开关若做在函数层,直传路径能整个绕过它 —— 那就是个假开关。
--   RLS 在数据库层求值,直传也躲不掉。
--
-- 为什么是 RESTRICTIVE:
--
--   Postgres 对同一命令的多条 PERMISSIVE 策略取 **OR**。再加一条 PERMISSIVE
--   策略只会**放宽**权限,永远收不紧。RESTRICTIVE 策略与其余策略取 **AND**,
--   这是唯一能"在不重写现有 75 条策略的前提下,一行 SQL 关掉整条写路径"的机制。
--
-- 为什么可移植(L2 通用防御的一部分):
--   纯 Postgres 语义 —— 表 + STABLE 函数 + RESTRICTIVE 策略。不依赖 Supabase
--   的任何专有能力。国内版只要也是 Postgres,这个文件原样能跑。

-- ── 开关表 ────────────────────────────────────────────────────────
create table if not exists app.switches (
  key         text primary key,
  enabled     boolean     not null default true,
  reason      text,
  updated_at  timestamptz not null default now(),
  updated_by  text
);

comment on table app.switches is
  '紧急止血阀。enabled=false 即关闭对应能力。只有 service_role 可写 —— '
  '客户端连读都不需要,策略通过 SECURITY DEFINER 函数读取。';

alter table app.switches enable row level security;
-- 不建任何 PERMISSIVE 策略 ⇒ anon/authenticated 既不能读也不能写。
-- service_role 绕过 RLS,故运维侧仍可读写。

insert into app.switches (key, enabled, reason) values
  ('uploads',      true, '关闭后:禁止新建/更新作品与版本(含直传路径的元数据落库)'),
  ('publishing',   true, '关闭后:禁止新作品进入 feed(已发布的不受影响)'),
  ('social_write', true, '关闭后:禁止评论/点赞/关注 —— spam 洪水时用'),
  ('storage_write',true, '关闭后:禁止一切新对象写入 works/thumbnails 桶')
on conflict (key) do nothing;

-- ── 读取函数 ──────────────────────────────────────────────────────
-- STABLE:同一语句内只求值一次(配合下面策略里的 (select ...) 包裹,
-- 规划器会把它提升成 InitPlan,而不是每行调一次)。
--
-- fail-OPEN(开关缺失时返回 true = 放行):这是刻意的。开关表本身出问题
-- 不应该让整个 app 停摆 —— 那等于我亲手造了一个单点故障。开关的用途是
-- "我主动按下去止血",不是"默认拦截"。
create or replace function app.switch_on(p_key text)
returns boolean
language sql
stable
security definer
set search_path = app, public, pg_temp
as $$
  select coalesce((select s.enabled from app.switches s where s.key = p_key), true);
$$;

revoke all on function app.switch_on(text) from public;
grant execute on function app.switch_on(text) to anon, authenticated, service_role;

-- ── RESTRICTIVE 策略:挂在写路径上 ─────────────────────────────────
-- 每条都用 (select app.switch_on(...)) 包裹,理由同 20260818020000:
-- 未包裹时函数**每行**求值一次,包裹后提升为 InitPlan、每条语句只算一次。

-- 作品:新建与更新(直传的元数据必须落这张表,所以这里关上,直传就没有意义)
create policy kill_switch_works_write on public.works
  as restrictive
  for insert to authenticated
  with check ((select app.switch_on('uploads')));

create policy kill_switch_works_update on public.works
  as restrictive
  for update to authenticated
  using ((select app.switch_on('uploads')))
  with check ((select app.switch_on('uploads')));

create policy kill_switch_work_versions_write on public.work_versions
  as restrictive
  for insert to authenticated
  with check ((select app.switch_on('uploads')));

-- 社交写入:spam 洪水时单独关,不影响作品发布
create policy kill_switch_comments_write on public.comments
  as restrictive
  for insert to authenticated
  with check ((select app.switch_on('social_write')));

create policy kill_switch_work_likes_write on public.work_likes
  as restrictive
  for insert to authenticated
  with check ((select app.switch_on('social_write')));

create policy kill_switch_follows_write on public.follows
  as restrictive
  for insert to authenticated
  with check ((select app.switch_on('social_write')));

-- 存储对象:直传的最后一道。works/thumbnails 两个桶。
-- scans 桶不挂 —— 那是用户自己的采集原始数据,关掉会丢用户正在拍的东西,
-- 违反"交付绝对无损、fail-safe 只许推迟不许丢数据"。
create policy kill_switch_storage_write on storage.objects
  as restrictive
  for insert to authenticated
  with check (
    bucket_id not in ('works', 'thumbnails')
    or (select app.switch_on('storage_write'))
  );

-- ── 运维入口 ──────────────────────────────────────────────────────
-- 只有 service_role 能调。刻意不做成"管理员用户可调" —— 目前没有 admin
-- 概念,而按下这个开关的影响是全站级的,门开得越窄越好。
create or replace function app.set_switch(
  p_key     text,
  p_enabled boolean,
  p_reason  text default null,
  p_by      text default null
)
returns app.switches
language plpgsql
security definer
set search_path = app, public, pg_temp
as $$
declare
  v_row app.switches;
begin
  if current_user <> 'service_role' then
    raise exception 'set_switch requires service_role';
  end if;

  insert into app.switches (key, enabled, reason, updated_at, updated_by)
  values (p_key, p_enabled, p_reason, now(), p_by)
  on conflict (key) do update
    set enabled    = excluded.enabled,
        reason     = coalesce(excluded.reason, app.switches.reason),
        updated_at = now(),
        updated_by = excluded.updated_by
  returning * into v_row;

  -- 按下止血阀本身必须留痕 —— 事后要能回答"谁在什么时候关的、为什么"。
  insert into public.audit_logs (actor_id, action, target_type, target_id, metadata)
  values (
    null,
    case when p_enabled then 'admin.switch_enabled' else 'admin.switch_disabled' end,
    'switch',
    null,
    jsonb_build_object('key', p_key, 'enabled', p_enabled,
                       'reason', p_reason, 'by', p_by)
  );

  return v_row;
end;
$$;

revoke all on function app.set_switch(text, boolean, text, text) from public;
grant execute on function app.set_switch(text, boolean, text, text) to service_role;
