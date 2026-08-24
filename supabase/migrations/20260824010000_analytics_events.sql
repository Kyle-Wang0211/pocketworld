-- 第一方统计事件表(自建埋点)
-- =====================================================================
-- 产品拍板(2026-08-24):自建埋点,不接任何第三方统计 SDK。
-- 结构复刻 Aptabase(MIT,开源隐私优先 App 统计)的服务端最小模型:
--   事件名 + 会话 + 属性 JSON + 系统信息,批量写入。
-- 隐私边界(与隐私政策第一章(五)逐句对齐,改一边必改另一边):
--   · 只在登录后收集(登录墙即同意门);
--   · 不存 IP、不存设备指纹;设备信息只有 OS 版本与 App 版本;
--   · 保存 180 天,到期自动删除(与审计日志一般档一致);
--   · 注销账号 ⇒ user_id 置空(on delete set null)= 匿名化,与 work_views 同款。

create table if not exists public.analytics_events (
  id bigint generated always as identity primary key,
  -- 注销即匿名化:行保留(聚合统计仍有意义),身份关联断开。
  user_id uuid references auth.users(id) on delete set null,  -- [PORTABLE]
  session_id text not null check (char_length(session_id) <= 64),
  event text not null check (char_length(event) <= 64),
  props jsonb not null default '{}'::jsonb,
  app_version text check (char_length(app_version) <= 32),
  os_version text check (char_length(os_version) <= 64),
  client_ts timestamptz,
  created_at timestamptz not null default now(),
  -- props 是客户端可控输入,4KB 硬顶防灌爆。
  constraint analytics_props_size check (pg_column_size(props) <= 4096)
);

comment on table public.analytics_events is
  '第一方统计事件(自建埋点,零第三方SDK)。保留180天;注销后user_id置空=匿名化。'
  '隐私政策第一章(五)与本表逐句对齐。';

alter table public.analytics_events enable row level security;

-- 只许本人插入自己的事件;任何客户端不可读/改/删(不建对应策略)。
-- 读取只归 service_role(将来做分析看板也走服务端)。
create policy analytics_insert_self on public.analytics_events
  for insert to authenticated
  with check (user_id = auth.uid());  -- [PORTABLE]

revoke all on public.analytics_events from anon;
grant insert on public.analytics_events to authenticated;

-- 查询/清扫用索引:清扫按 created_at,分析按 (event, created_at)。
create index if not exists idx_analytics_created on public.analytics_events (created_at);
create index if not exists idx_analytics_event_created on public.analytics_events (event, created_at);

-- 180 天到期自动删除。与 20260818000000 的审计日志清扫同一套 pg_cron 模式。
create or replace function public.purge_expired_analytics_events()
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.analytics_events
  where created_at < now() - interval '180 days';
$$;
revoke all on function public.purge_expired_analytics_events() from public, anon, authenticated;

do $do$
begin
  if not exists (select 1 from cron.job where jobname = 'purge-analytics-events') then
    perform cron.schedule(
      'purge-analytics-events',
      '45 4 * * *',  -- 每日 04:45 UTC,错开审计日志清扫的 04:30
      'select public.purge_expired_analytics_events()'
    );
  end if;
end
$do$;
