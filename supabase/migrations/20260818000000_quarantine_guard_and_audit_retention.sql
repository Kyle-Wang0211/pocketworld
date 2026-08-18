-- 三件事:(1) 修好隔离桶的护栏 (2) 停掉 research 残留 (3) 给审计定留存期
--
-- 背景:一次对抗性审计(专门构造攻击来证伪前一批代码)发现,
-- 20260817020000 里那道"防止隔离桶被改公开"的断言查的是 pg_policies ——
-- 而真正能让桶公开的是 storage.buckets.public 布尔字段。一个 public=true
-- 的桶策略数为 0,会**顺利通过**那道断言。护栏查的东西和要防的东西对不上。
-- 这一点尤其讽刺,因为同一个文件的注释反复强调的正是"public 桶绕过 RLS"。

-- ── 1. 隔离桶:断言现状 + 持续防护 ──────────────────────────────────
do $$
declare
  v_public boolean;
begin
  select public into v_public from storage.buckets where id = 'quarantine';
  if v_public is null then
    raise exception 'quarantine bucket missing — takedown would silently no-op';
  end if;
  if v_public then
    raise exception
      'quarantine bucket is PUBLIC — every taken-down file is world-readable at its quarantine URL';
  end if;
end $$;

-- 断言只在 apply 时跑一次;真正的"未来护栏"需要是持续的。
-- 范围刻意收到最窄:只拦"把 quarantine 从私有翻成公开"这一个动作,
-- 不干预 Supabase 对其它桶的任何内部操作。
create or replace function public.guard_quarantine_stays_private()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.id = 'quarantine' and new.public is true then
    raise exception
      'refusing to make the quarantine bucket public: it holds taken-down content kept as evidence'
      using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_quarantine_stays_private on storage.buckets;
create trigger guard_quarantine_stays_private
before insert or update on storage.buckets
for each row execute function public.guard_quarantine_stays_private();

-- ── 2. research / 云端训练残留:schema 有、产品从不采集 ──────────────
-- 这四列的列注释写的是"用户是否同意把采集素材用于改进重建算法/AI 模型"。
-- 产品从不写它们(客户端零引用),隐私政策也不提。留着的唯一后果是:
-- 任何按 schema 自动生成的个人信息清单(GDPR ROPA / 个保法个人信息清单)
-- 都会把它们列成"已收集的同意记录" —— 声明与实际不符,是隐私审查里最容易
-- 暴雷的一类。删掉比解释便宜。
-- ⚠️ 实测发现:这不是"从未被采集"的空壳。删列前查生产库,唯一那行 profile 是
--   research_data_opt_in            = false
--   research_data_prompt_dismissed  = true      ← 非默认
--   research_data_opt_in_updated_at = 2026-06-23T05:24:31Z
-- 即 2026-06-23 这个功能真的跑过:用户看到过授权提示、**忽略**了它,并且
-- **从未同意**。删列会一并抹掉"用户曾拒绝"这个事实,所以先把现状留痕进
-- audit_logs 再删 —— 将来若需证明我们没拿过研究授权,证据还在。
do $$
declare r record;
begin
  -- 该列可能已在别处被删,所以整段包 exception。
  for r in
    select id, research_data_opt_in, research_data_prompt_dismissed,
           research_data_consent_version, research_data_opt_in_updated_at
    from public.profiles
    where research_data_opt_in is true
       or research_data_prompt_dismissed is true
       or research_data_opt_in_updated_at is not null
  loop
    insert into public.audit_logs (actor_id, action, target_type, target_id, metadata)
    values (
      null, 'system.research_consent_columns_dropped', 'user', r.id,
      jsonb_build_object(
        'reason', 'cloud training line removed 2026-07; columns never read by the product',
        'preserved_values', jsonb_build_object(
          'research_data_opt_in', r.research_data_opt_in,
          'research_data_prompt_dismissed', r.research_data_prompt_dismissed,
          'research_data_consent_version', r.research_data_consent_version,
          'research_data_opt_in_updated_at', r.research_data_opt_in_updated_at
        )
      )
    );
  end loop;
exception when undefined_column then
  null;
end $$;

alter table public.profiles
  drop column if exists research_data_opt_in,
  drop column if exists research_data_prompt_dismissed,
  drop column if exists research_data_consent_version,
  drop column if exists research_data_opt_in_updated_at;

-- 云端训练线已于 2026-07 整体删除(纯本地重建),这些 RPC 客户端零调用。
-- 它们还都只 grant 未 revoke,anon 也能调,目前仅因 auth.uid() 为 null
-- 而"碰巧安全" —— 碰巧安全不是设计安全。
drop function if exists public.request_scan_training(uuid, jsonb);
drop function if exists public.ack_scan_upload(uuid);
drop function if exists public.mark_scan_local_raw_deleted(uuid);
drop function if exists public.mark_scan_cloud_raw_deleted(uuid);

-- 该触发器会把 metadata->'research_consent' 写进 audit_logs。既然同意
-- 从不被采集,这条链路只会往审计里写空值;而"审计里出现 research_consent
-- 字段"本身就会误导任何读审计的人。
drop trigger if exists trg_audit_scan_lifecycle on public.scans;
drop trigger if exists audit_scan_lifecycle on public.scans;
drop function if exists public.audit_scan_lifecycle();

-- ── 3. audit_logs 留存期 ────────────────────────────────────────────
-- 此前无限期累积,且含 actor_id(uuid) + ip_address + user_agent。
-- GDPR/个保法允许为审计目的留存,但要求"不超过必要期限"并在隐私政策写明。
--
-- 分两档,因为两类记录的用途寿命不同:
--   • 合规/执法类(下架、删号、作者删帖) → 730 天。这些是将来要用来回答
--     "你们是否确实在 24 小时内移除了"以及应对申诉/法律主张的证据。
--   • 其余运营类 → 180 天。
-- ⚠️ 这两个数字是工程默认值,不是法务意见;隐私政策里写的期限必须与此一致,
-- 改这里就要同步改政策。
create or replace function public.purge_expired_audit_logs()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_deleted integer;
begin
  delete from public.audit_logs
  where created_at <
        now() - (case
          when action like 'admin.%'
            or action in ('user.account_deleted', 'work.deleted_by_author')
          then interval '730 days'
          else interval '180 days'
        end);
  get diagnostics v_deleted = row_count;
  return v_deleted;
end;
$$;

revoke execute on function public.purge_expired_audit_logs() from public, anon, authenticated;

do $$
begin
  perform cron.unschedule('purge-expired-audit-logs');
exception when others then
  null;
end $$;

select cron.schedule(
  'purge-expired-audit-logs',
  '30 4 * * *',                       -- 每日 04:30 UTC,避开使用高峰
  $$select public.purge_expired_audit_logs();$$
);
