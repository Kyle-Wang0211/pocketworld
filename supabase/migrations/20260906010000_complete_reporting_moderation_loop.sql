begin;

lock table public.reports in share row exclusive mode;

alter table public.reports
  add column if not exists kind text not null default 'standard',
  add column if not exists priority smallint,
  add column if not exists due_at timestamptz,
  add column if not exists reporter_feedback text,
  add column if not exists claimed_by uuid references auth.users(id) on delete set null,
  add column if not exists claimed_at timestamptz;

update public.reports
set kind = case
      when reason in ('impersonation', 'privacy_ip') then 'rights'
      else 'standard'
    end,
    priority = case reason
      when 'minor_safety' then 100
      when 'sexual_content' then 80
      when 'harassment_threat' then 80
      when 'privacy_ip' then 60
      when 'impersonation' then 60
      when 'violence_illegal' then 60
      else 40
    end,
    due_at = coalesce(due_at, created_at + case
      when reason in ('minor_safety', 'sexual_content', 'harassment_threat')
        then interval '24 hours'
      when reason in ('privacy_ip', 'impersonation', 'violence_illegal')
        then interval '72 hours'
      else interval '7 days'
    end);

alter table public.reports
  alter column priority set not null,
  alter column due_at set not null,
  drop constraint if exists reports_kind_check,
  add constraint reports_kind_check check (kind in ('standard', 'rights')),
  drop constraint if exists reports_kind_reason_check,
  add constraint reports_kind_reason_check check (
    (kind = 'rights' and reason in ('impersonation', 'privacy_ip'))
    or
    (kind = 'standard' and reason not in ('impersonation', 'privacy_ip'))
  ),
  drop constraint if exists reports_priority_check,
  add constraint reports_priority_check check (priority in (40, 60, 80, 100)),
  drop constraint if exists reports_reporter_feedback_check,
  add constraint reports_reporter_feedback_check
    check (reporter_feedback is null or char_length(reporter_feedback) <= 1000);

alter table public.reports drop constraint if exists reports_status_check;
alter table public.reports add constraint reports_status_check check (
  status in ('pending', 'in_review', 'needs_info', 'actioned', 'dismissed')
);

create or replace function public.prepare_report_fields()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  -- Keep old app builds compatible: they still send the three retired reason
  -- codes directly to PostgREST. Normalize before deriving the tier so the
  -- alphabetically ordered validation trigger sees the final values.
  NEW.reason := case NEW.reason
    when 'spam' then 'spam_fraud'
    when 'harassment' then 'harassment_threat'
    when 'copyright' then 'privacy_ip'
    else NEW.reason
  end;
  NEW.kind := case
    when NEW.reason in ('impersonation', 'privacy_ip') then 'rights'
    else 'standard'
  end;
  NEW.priority := case NEW.reason
    when 'minor_safety' then 100
    when 'sexual_content' then 80
    when 'harassment_threat' then 80
    when 'privacy_ip' then 60
    when 'impersonation' then 60
    when 'violence_illegal' then 60
    else 40
  end;
  -- SLA fields are server-owned; direct legacy clients cannot extend them.
  NEW.due_at := NEW.created_at + case
    when NEW.reason in ('minor_safety', 'sexual_content', 'harassment_threat')
      then interval '24 hours'
    when NEW.reason in ('privacy_ip', 'impersonation', 'violence_illegal')
      then interval '72 hours'
    else interval '7 days'
  end;
  return NEW;
end;
$$;

drop trigger if exists prepare_report_fields on public.reports;
drop trigger if exists a_prepare_report_fields on public.reports;
create trigger a_prepare_report_fields
before insert or update of reason, kind, priority, due_at
on public.reports
for each row execute function public.prepare_report_fields();

create or replace function public.enforce_report_detail_limit()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if NEW.detail is null then
    return NEW;
  end if;
  if NEW.kind = 'standard' and char_length(NEW.detail) > 50 then
    raise exception 'standard report detail exceeds 50 characters'
      using errcode = '22001';
  end if;
  if NEW.kind = 'rights' and char_length(NEW.detail) > 500 then
    raise exception 'rights complaint detail exceeds 500 characters'
      using errcode = '22001';
  end if;
  return NEW;
end;
$$;

drop trigger if exists enforce_report_detail_limit on public.reports;
create trigger enforce_report_detail_limit
before insert or update of detail, kind, reason
on public.reports
for each row execute function public.enforce_report_detail_limit();

create or replace function public.reject_self_or_mismatched_report()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  w public.works%rowtype;
begin
  if NEW.target_type = 'user' and NEW.target_id = NEW.reporter_id then
    raise exception 'cannot report yourself' using errcode = '23514';
  end if;

  if NEW.target_type = 'work' then
    select * into w from public.works where id = NEW.target_id;
    if not found then
      raise exception 'reported work does not exist' using errcode = '23503';
    end if;
    if w.user_id = NEW.reporter_id then
      raise exception 'cannot report your own work' using errcode = '23514';
    end if;
  end if;

  if NEW.target_type = 'user' and NEW.source_work_id is not null then
    select * into w from public.works where id = NEW.source_work_id;
    if not found or w.user_id <> NEW.target_id then
      raise exception 'source work does not belong to reported user'
        using errcode = '23514';
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists reject_self_or_mismatched_report on public.reports;
create trigger reject_self_or_mismatched_report
before insert or update of reporter_id, target_type, target_id, source_work_id
on public.reports
for each row execute function public.reject_self_or_mismatched_report();

alter table public.report_evidence
  add column if not exists evidence_kind text not null default 'context';
alter table public.report_evidence
  drop constraint if exists report_evidence_kind_check,
  add constraint report_evidence_kind_check check (
    evidence_kind in ('context', 'identity', 'ownership', 'authorization', 'other')
  );

create table if not exists public.moderator_accounts (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role text not null check (role in ('reviewer', 'lead')),
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table public.moderator_accounts enable row level security;
revoke all on public.moderator_accounts from anon, authenticated;

create table if not exists public.report_moderation_events (
  id bigserial primary key,
  report_id bigint not null references public.reports(id) on delete cascade,
  moderator_id uuid references auth.users(id) on delete set null,
  from_status text,
  to_status text not null check (
    to_status in ('pending', 'in_review', 'needs_info', 'actioned', 'dismissed')
  ),
  reporter_feedback text check (
    reporter_feedback is null or char_length(reporter_feedback) <= 1000
  ),
  internal_notes text check (
    internal_notes is null or char_length(internal_notes) <= 2000
  ),
  created_at timestamptz not null default now()
);
alter table public.report_moderation_events enable row level security;
revoke all on public.report_moderation_events from anon, authenticated;

drop policy if exists reports_select_self on public.reports;
revoke select on public.reports from authenticated;

drop policy if exists reports_insert_self on public.reports;
drop policy if exists reports_insert_legacy_work on public.reports;
create policy reports_insert_legacy_work on public.reports
  for insert to authenticated
  with check (
    app.current_user_id() = reporter_id
    and target_type = 'work'
    and status = 'pending'
    and admin_notes is null
    and reporter_feedback is null
    and resolved_by is null
    and resolved_at is null
    and claimed_by is null
    and claimed_at is null
  );

create or replace function public.get_my_reports(p_limit integer default 100)
returns table(
  id bigint,
  kind text,
  reason text,
  status text,
  reporter_feedback text,
  source_work_title text,
  created_at timestamptz,
  due_at timestamptz,
  resolved_at timestamptz,
  is_overdue boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    r.id,
    r.kind,
    r.reason,
    r.status,
    r.reporter_feedback,
    nullif(r.source_work_snapshot ->> 'title', ''),
    r.created_at,
    r.due_at,
    r.resolved_at,
    r.status in ('pending', 'in_review') and r.due_at < now()
  from public.reports r
  where r.reporter_id = app.current_user_id()
  order by r.created_at desc
  limit least(greatest(coalesce(p_limit, 100), 1), 200)
$$;

revoke all on function public.get_my_reports(integer) from public, anon;
grant execute on function public.get_my_reports(integer) to authenticated;

create index if not exists idx_reports_moderation_queue
  on public.reports(priority desc, due_at asc, created_at asc)
  where status in ('pending', 'in_review');
-- Query support for the 24-hour duplicate check in submit-report.
create index if not exists idx_reports_duplicate_window
  on public.reports(reporter_id, target_id, source_work_id, reason, created_at desc);
create index if not exists idx_report_moderation_events_report
  on public.report_moderation_events(report_id, created_at desc);

revoke all on function public.prepare_report_fields() from public;
revoke all on function public.enforce_report_detail_limit() from public;
revoke all on function public.reject_self_or_mismatched_report() from public;

commit;
