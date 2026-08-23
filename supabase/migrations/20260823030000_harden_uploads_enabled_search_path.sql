-- 收紧 public.uploads_enabled() 的 search_path 到空
-- =====================================================================
-- 20260823020000 建这个函数时写的是 `set search_path = app, public`。
-- Supabase 官方 RLS 指南要求的是:
--   "Set search_path = '' on every security definer function and
--    schema-qualify the names inside it. Without a pinned search_path,
--    a caller can point an unqualified name at their own object and run it
--    with the function owner's privileges."
--
-- 本函数的函数体本来就是全限定的(`app.switch_on(...)`),所以此刻并不存在
-- 可利用的路径。改成空 search_path 是把"当前碰巧安全"变成"结构上安全":
-- 以后任何人把函数体里的名字改成不限定的写法,都会直接报错而不是静默地
-- 沿着 search_path 找到别的对象。
--
-- ⚠️ 关于它为什么仍然留在 public schema:
--   同一份指南还说"never create a security definer function in a schema
--   listed under Exposed schemas"。但 PostgREST 默认只暴露 public,
--   Edge Function 通过 supabase-js 的 .rpc() 也只能调到 public —— 放进
--   app schema 就调不到了。折中是留在 public 但**撤掉所有客户端角色的
--   EXECUTE**(20260823020000 已做,实测 grantee 只剩 service_role 与 postgres)。
--   这一层是本函数不可被客户端触达的真正依据,不要在后续迁移里把它加回来。
create or replace function public.uploads_enabled()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$ select app.switch_on('uploads') $$;

-- create or replace 会保留原有的 ACL,但显式重申一遍,避免将来有人
-- 用不带 revoke 的方式重建这个函数时把权限放宽回默认。
revoke all on function public.uploads_enabled() from public, anon, authenticated;
grant execute on function public.uploads_enabled() to service_role;
