-- app.current_user_id():把 RLS 策略与 Supabase 专有的 auth.uid() 解耦
--
-- 动因(迁移可移植性):RLS 本身是 PostgreSQL 9.5+ 的标准功能,阿里云 RDS
-- PostgreSQL 等托管服务原样支持 —— 表结构、索引、约束、触发器、plpgsql、
-- 角色授权全都能搬走。但 `auth.uid()` 是 GoTrue(Supabase 专有)注入的,
-- 换后端时它不存在。
--
-- 当前全库 **136 处 auth.uid()、95 条策略、17 个迁移文件**。若保持现状,
-- 换后端那天要逐条改 136 处策略谓词 —— 那是一场手术,且每改错一条就是
-- 一个静默的越权漏洞。现在加一层间接,换后端只需重写这一个函数体。
--
-- 为什么不手改 17 个迁移文件:迁移文件是历史,改它们不会影响已经建好的策略;
-- 真正要改的是**库里当前生效的策略定义**。所以这里从 pg_policies 读出现行
-- 定义、做文本替换后原样重建 —— 保留每条策略的 cmd/roles/using/with check,
-- 不靠人手抄写。整个迁移在单事务内,任何一步失败则全部回滚。

create schema if not exists app;

-- STABLE 而非 IMMUTABLE:它依赖当前请求的 JWT claim(session 级设置),
-- 同一事务内稳定但跨事务会变。IMMUTABLE 会让规划器错误地缓存结果。
-- 不用 SECURITY DEFINER:定义者权限对读取 session 变量没有帮助,
-- 反而会掩盖调用者身份。
-- search_path 显式锁定,避免被 search_path 劫持(所有引用都用全限定名)。
create or replace function app.current_user_id()
returns uuid
language sql
stable
set search_path = ''
as $$
  -- 迁移到非 Supabase 后端时,**只需要改这一行**。
  -- 例如自建 JWT 网关:
  --   select nullif(current_setting('request.jwt.claims', true)::jsonb->>'sub','')::uuid
  select auth.uid()
$$;

comment on function app.current_user_id() is
  'Portable indirection over the auth backend. RLS policies must call this, never auth.uid() directly — swapping backends should touch only this function body.';

-- anon/authenticated 必须能执行它,否则所有策略在求值时报权限错误 = 全库拒绝访问。
grant usage on schema app to anon, authenticated, service_role;
grant execute on function app.current_user_id() to anon, authenticated, service_role;

-- ── 安全网:重写前把每条策略的现行定义原样存下来 ──────────────────────
-- 重写 95 条策略是高风险操作:改错一条 = 一个静默的越权漏洞,而且 RLS 出错
-- 通常不会报错,只会悄悄多放行或多拒绝。事务回滚能防"迁移失败",防不了
-- "迁移成功但语义变了"。所以留一份可人工比对/恢复的快照。
create table if not exists public.rls_policy_snapshot (
  id bigserial primary key,
  taken_at timestamptz not null default now(),
  reason text not null,
  schema_name text not null,
  table_name text not null,
  policy_name text not null,
  cmd char(1) not null,
  roles text[] not null,
  using_expr text,
  check_expr text
);
alter table public.rls_policy_snapshot enable row level security;
-- 零策略 = 仅 service_role 可读(它记录的是全部授权逻辑,不能对客户端开放)。

insert into public.rls_policy_snapshot
  (reason, schema_name, table_name, policy_name, cmd, roles, using_expr, check_expr)
select 'before app.current_user_id() abstraction (20260818010000)',
       n.nspname, c.relname, pol.polname, pol.polcmd,
       array(select rolname from pg_roles where oid = any(pol.polroles)),
       pg_get_expr(pol.polqual, pol.polrelid),
       pg_get_expr(pol.polwithcheck, pol.polrelid)
from pg_policy pol
join pg_class c on c.oid = pol.polrelid
join pg_namespace n on n.oid = c.relnamespace
where n.nspname in ('public', 'storage');

-- ── 把现行策略里的 auth.uid() 换成 app.current_user_id() ──────────────
do $$
declare
  r record;
  v_using text;
  v_check text;
  v_roles text;
  v_sql text;
  v_rewritten int := 0;
begin
  for r in
    select n.nspname  as schema_name,
           c.relname  as table_name,
           pol.polname as policy_name,
           pol.polcmd  as cmd,
           pg_get_expr(pol.polqual, pol.polrelid)      as using_expr,
           pg_get_expr(pol.polwithcheck, pol.polrelid) as check_expr,
           array(select rolname from pg_roles where oid = any(pol.polroles)) as roles
    from pg_policy pol
    join pg_class c on c.oid = pol.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    -- storage.objects 的策略同样受影响,一并处理
    where n.nspname in ('public', 'storage')
      and (pg_get_expr(pol.polqual, pol.polrelid) like '%auth.uid()%'
        or pg_get_expr(pol.polwithcheck, pol.polrelid) like '%auth.uid()%')
  loop
    v_using := replace(coalesce(r.using_expr, ''), 'auth.uid()', 'app.current_user_id()');
    v_check := replace(coalesce(r.check_expr, ''), 'auth.uid()', 'app.current_user_id()');
    v_roles := array_to_string(
      array(select quote_ident(x) from unnest(r.roles) x), ', ');
    if v_roles = '' then v_roles := 'public'; end if;

    v_sql := format('drop policy %I on %I.%I',
                    r.policy_name, r.schema_name, r.table_name);
    execute v_sql;

    v_sql := format('create policy %I on %I.%I for %s to %s',
      r.policy_name, r.schema_name, r.table_name,
      case r.cmd when 'r' then 'select' when 'a' then 'insert'
                 when 'w' then 'update' when 'd' then 'delete'
                 else 'all' end,
      v_roles);
    if r.using_expr is not null then
      v_sql := v_sql || format(' using (%s)', v_using);
    end if;
    if r.check_expr is not null then
      v_sql := v_sql || format(' with check (%s)', v_check);
    end if;
    execute v_sql;
    v_rewritten := v_rewritten + 1;
  end loop;

  raise notice 'rewrote % policies to app.current_user_id()', v_rewritten;
end $$;

-- ── 验证:不允许"跑完了但没换干净" ────────────────────────────────────
do $$
declare
  v_left int;
  v_new  int;
begin
  select count(*) into v_left
  from pg_policy pol
  join pg_class c on c.oid = pol.polrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public','storage')
    and (pg_get_expr(pol.polqual, pol.polrelid) like '%auth.uid()%'
      or pg_get_expr(pol.polwithcheck, pol.polrelid) like '%auth.uid()%');

  select count(*) into v_new
  from pg_policy pol
  join pg_class c on c.oid = pol.polrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public','storage')
    and (pg_get_expr(pol.polqual, pol.polrelid) like '%current_user_id()%'
      or pg_get_expr(pol.polwithcheck, pol.polrelid) like '%current_user_id()%');

  if v_left > 0 then
    raise exception 'still % policies referencing auth.uid() directly', v_left;
  end if;
  if v_new = 0 then
    raise exception 'no policy references app.current_user_id() — the rewrite did nothing';
  end if;
  raise notice 'verified: 0 direct auth.uid(), % policies on app.current_user_id()', v_new;
end $$;
