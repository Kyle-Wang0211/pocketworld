-- 四项加固,全部 PostgreSQL 原生(迁到阿里云 RDS 可原样搬走)
--
-- 依据:PostgreSQL 官方 CREATE FUNCTION 文档对 SECURITY DEFINER 的原文警告 ——
-- "Particularly important in this regard is the temporary-table schema, which is
--  searched first by default, and is normally writable by anyone. A secure
--  arrangement can be obtained by forcing the temporary schema to be searched
--  last. To do this, write pg_temp as the last entry in search_path."

-- ── 1. 所有 SECURITY DEFINER 函数:把 pg_temp 钉到 search_path 末尾 ────
-- 我此前给这些函数写的是 `set search_path = public` —— 看起来锁了,其实没有:
-- pg_temp 未被列出时**默认排在最前**(官方原文:"If it is not listed in the
-- path then it is searched first, even before pg_catalog")。于是任何能建临时表
-- 的角色(默认 PUBLIC 就有 TEMP 权限)都可以建一张同名临时表来遮蔽 public 里的
-- 真表,让 definer 函数在攻击者构造的数据上执行。
-- record_work_view 是 grant 给 anon 的 ⇒ 这条对它是可实际利用的:建一张临时
-- works 表即可骗过其中的可见性判断去刷浏览量。
do $$
declare
  r record;
  v_cnt int := 0;
begin
  for r in
    select p.oid,
           n.nspname,
           p.proname,
           pg_get_function_identity_arguments(p.oid) as args
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where p.prosecdef
      and n.nspname in ('public', 'app')
      -- 已经安全的两种写法跳过:空 search_path,或已以 pg_temp 结尾
      and not exists (
        select 1 from unnest(coalesce(p.proconfig, array[]::text[])) c
        where c = 'search_path=' or c like '%pg_temp'
      )
  loop
    execute format('alter function %I.%I(%s) set search_path = public, pg_temp',
                   r.nspname, r.proname, r.args);
    v_cnt := v_cnt + 1;
  end loop;
  raise notice 'pinned pg_temp last on % security definer functions', v_cnt;
end $$;

-- ── 2. RLS 策略:把 app.current_user_id() 包进 (select ...) ────────────
-- Supabase 官方性能基准:未包裹时函数**每行**求值一次,包裹后规划器提升为
-- InitPlan、每条语句只算一次。官方给的数字是 179ms → 9ms(自定义函数一档更夸张,
-- 11,000ms → 7ms)。上一个迁移做抽象时是原样文本替换,继承了原策略"未包裹"的写法,
-- 所以性能问题一直都在(它本来就在,不是抽象引入的),这里一并修掉。
do $$
declare
  r record;
  v_using text;
  v_check text;
  v_roles text;
  v_sql text;
  v_cnt int := 0;
begin
  for r in
    select n.nspname as schema_name, c.relname as table_name,
           pol.polname as policy_name, pol.polcmd as cmd,
           pg_get_expr(pol.polqual, pol.polrelid) as using_expr,
           pg_get_expr(pol.polwithcheck, pol.polrelid) as check_expr,
           array(select rolname from pg_roles where oid = any(pol.polroles)) as roles
    from pg_policy pol
    join pg_class c on c.oid = pol.polrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname in ('public','storage')
      and (pg_get_expr(pol.polqual, pol.polrelid) like '%app.current_user_id()%'
        or pg_get_expr(pol.polwithcheck, pol.polrelid) like '%app.current_user_id()%')
  loop
    -- 只替换裸调用;已经是 (select app.current_user_id()) 的不再重复包裹
    v_using := replace(coalesce(r.using_expr,''),
                       '( SELECT app.current_user_id() AS current_user_id)',
                       '__ALREADY__');
    v_using := replace(v_using, 'app.current_user_id()', '(select app.current_user_id())');
    v_using := replace(v_using, '__ALREADY__',
                       '( SELECT app.current_user_id() AS current_user_id)');

    v_check := replace(coalesce(r.check_expr,''),
                       '( SELECT app.current_user_id() AS current_user_id)',
                       '__ALREADY__');
    v_check := replace(v_check, 'app.current_user_id()', '(select app.current_user_id())');
    v_check := replace(v_check, '__ALREADY__',
                       '( SELECT app.current_user_id() AS current_user_id)');

    v_roles := array_to_string(array(select quote_ident(x) from unnest(r.roles) x), ', ');
    if v_roles = '' then v_roles := 'public'; end if;

    execute format('drop policy %I on %I.%I', r.policy_name, r.schema_name, r.table_name);
    v_sql := format('create policy %I on %I.%I for %s to %s',
      r.policy_name, r.schema_name, r.table_name,
      case r.cmd when 'r' then 'select' when 'a' then 'insert'
                 when 'w' then 'update' when 'd' then 'delete' else 'all' end,
      v_roles);
    if r.using_expr is not null then v_sql := v_sql || format(' using (%s)', v_using); end if;
    if r.check_expr is not null then v_sql := v_sql || format(' with check (%s)', v_check); end if;
    execute v_sql;
    v_cnt := v_cnt + 1;
  end loop;
  raise notice 'wrapped app.current_user_id() in InitPlan for % policies', v_cnt;
end $$;

-- ── 3. 默认权限收口:让"新表忘了开 RLS"不再等于"数据公开" ──────────────
-- Supabase 新建表会自动 grant 给 anon/authenticated/service_role,于是安全性
-- 完全押在"记得开 RLS"这一件事上 —— CVE-2025-48757(Lovable,CVSS 9.3)整类事故
-- 的成因正是如此。收口之后新表连 grant 都没有,RLS 忘没忘都进不来:
-- 把模型从"默认暴露、靠记性收敛"改成"默认关闭、显式开放"。
-- 已存在的表不受影响(default privileges 只作用于将来创建的对象)。
alter default privileges for role postgres in schema public
  revoke select, insert, update, delete on tables from anon, authenticated;

-- ── 4. service_role 语句超时 ─────────────────────────────────────────
-- Supabase 默认:anon 3s、authenticated 8s、**service_role 无限制**。
-- 我那几个服务端函数都以 service_role 跑,一条失控查询可以一直占着连接。
alter role service_role set statement_timeout = '30s';

-- 验证
do $$
declare v_bad int;
begin
  select count(*) into v_bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where p.prosecdef and n.nspname in ('public','app')
    and not exists (
      select 1 from unnest(coalesce(p.proconfig, array[]::text[])) c
      where c = 'search_path=' or c like '%pg_temp');
  if v_bad > 0 then
    raise exception '% security definer functions still lack a pg_temp-terminated search_path', v_bad;
  end if;
  raise notice 'verified: all security definer functions have a safe search_path';
end $$;
