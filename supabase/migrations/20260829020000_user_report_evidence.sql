begin;

-- Account-report launch: align the durable reason taxonomy, attach the
-- originating work when present, and add a private server-owned evidence path.
--
-- Depends on:
--   20260429020005_moderation.sql
--   20260829010000_social_profile_follow_safety.sql

lock table public.reports in share row exclusive mode;

alter table public.reports
  add column if not exists source_work_id uuid
    references public.works(id) on delete set null,
  add column if not exists source_work_snapshot jsonb,
  add column if not exists preservation_state text not null default 'not_required'
    check (preservation_state in (
      'not_required', 'pending', 'retrying', 'complete', 'partial', 'failed', 'released'
    )),
  add column if not exists preservation_attempts integer not null default 0
    check (preservation_attempts between 0 and 100),
  add column if not exists preservation_lease_until timestamptz;

-- Preserve historical reports while moving them to the launch taxonomy.
alter table public.reports drop constraint if exists reports_reason_check;
update public.reports
set reason = case reason
  when 'spam' then 'spam_fraud'
  when 'harassment' then 'harassment_threat'
  when 'hate_speech' then 'violence_illegal'
  when 'violence' then 'violence_illegal'
  when 'copyright' then 'privacy_ip'
  else reason
end
where reason in ('spam', 'harassment', 'hate_speech', 'violence', 'copyright');

alter table public.reports
  add constraint reports_reason_check check (reason in (
    'impersonation', 'harassment_threat', 'spam_fraud',
    'minor_safety', 'sexual_content', 'violence_illegal',
    'misinformation', 'privacy_ip', 'other'
  ));

-- Older released clients still submit the original work-report codes. Keep
-- them functional during rollout, but normalize every new row before the new
-- CHECK constraint is evaluated so the moderation queue has one taxonomy.
create or replace function public.normalize_legacy_report_reason()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  NEW.reason := case NEW.reason
    when 'spam' then 'spam_fraud'
    when 'harassment' then 'harassment_threat'
    when 'hate_speech' then 'violence_illegal'
    when 'violence' then 'violence_illegal'
    when 'copyright' then 'privacy_ip'
    else NEW.reason
  end;
  return NEW;
end;
$$;

drop trigger if exists normalize_legacy_report_reason on public.reports;
create trigger normalize_legacy_report_reason
before insert or update of reason on public.reports
for each row execute function public.normalize_legacy_report_reason();

alter table public.reports
  drop constraint if exists reports_no_self_user_report;

-- A column-scoped trigger rejects new self-reports without trapping historical
-- rows: admins can still update status/notes on an old bad row and close it.
create or replace function public.reject_self_user_report()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if NEW.target_type = 'user' and NEW.target_id = NEW.reporter_id then
    raise exception 'cannot report yourself' using errcode = '23514';
  end if;
  return NEW;
end;
$$;

drop trigger if exists reject_self_user_report on public.reports;
create trigger reject_self_user_report
before insert or update of reporter_id, target_type, target_id
on public.reports
for each row execute function public.reject_self_user_report();

-- Existing historical detail is retained. New or edited reports use the
-- product limit; the App also counts Unicode grapheme clusters before insert.
create or replace function public.enforce_report_detail_limit()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if NEW.detail is not null and char_length(NEW.detail) > 500 then
    raise exception 'report detail exceeds 500 characters'
      using errcode = '22001';
  end if;
  return NEW;
end;
$$;

drop trigger if exists enforce_report_detail_limit on public.reports;
create trigger enforce_report_detail_limit
before insert or update of detail on public.reports
for each row execute function public.enforce_report_detail_limit();

-- A short-lived deletion claim closes the Storage/DB gap in delete-work. The
-- author must claim before deleting bytes; sensitive report submission locks
-- the same work row and refuses a live claim before it accepts the report.
create table if not exists public.work_deletion_claims (
  work_id uuid primary key references public.works(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);
alter table public.work_deletion_claims enable row level security;
revoke all on public.work_deletion_claims from anon, authenticated;

create or replace function public.claim_work_deletion(
  p_work_id uuid,
  p_user_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  w public.works%rowtype;
begin
  select * into w from public.works where id = p_work_id for update;
  if not found or w.user_id <> p_user_id
     or w.moderation_status <> 'ok' or w.deleted_at is not null then
    return false;
  end if;
  if exists (
    select 1 from public.reports r
    where r.source_work_id = p_work_id
      and r.target_type = 'user'
      and r.reason in ('minor_safety', 'sexual_content')
      and r.status in ('pending', 'in_review')
      and r.preservation_state not in ('complete', 'released')
  ) then
    return false;
  end if;
  insert into public.work_deletion_claims(work_id, user_id, expires_at)
  values (p_work_id, p_user_id, now() + interval '1 hour')
  on conflict (work_id) do update
    set user_id = excluded.user_id,
        expires_at = excluded.expires_at,
        created_at = now()
  where public.work_deletion_claims.expires_at <= now()
     or public.work_deletion_claims.user_id = excluded.user_id;
  return found;
end;
$$;

revoke all on function public.claim_work_deletion(uuid, uuid) from public, anon, authenticated;
grant execute on function public.claim_work_deletion(uuid, uuid) to service_role;

create or replace function public.claim_account_content_deletion(p_user_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform w.id
  from public.works w
  where w.user_id = p_user_id
  order by w.id
  for update;

  if exists (
    select 1 from public.reports r
    where r.target_type = 'user'
      and r.target_id = p_user_id
      and r.source_work_id is not null
      and r.reason in ('minor_safety', 'sexual_content')
      and r.status in ('pending', 'in_review')
      and r.preservation_state not in ('complete', 'released')
  ) then
    return false;
  end if;

  insert into public.work_deletion_claims(work_id, user_id, expires_at)
  select w.id, p_user_id, now() + interval '1 hour'
  from public.works w
  where w.user_id = p_user_id
  on conflict (work_id) do update
    set user_id = excluded.user_id,
        expires_at = excluded.expires_at,
        created_at = now()
  where public.work_deletion_claims.expires_at <= now()
     or public.work_deletion_claims.user_id = excluded.user_id;
  return true;
end;
$$;

revoke all on function public.claim_account_content_deletion(uuid)
  from public, anon, authenticated;
grant execute on function public.claim_account_content_deletion(uuid)
  to service_role;

create or replace function public.claim_report_preservation_retry(p_report_id bigint)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.reports
  set preservation_state = 'retrying',
      preservation_lease_until = now() + interval '10 minutes'
  where id = p_report_id
    and source_work_id is not null
    and reason in ('minor_safety', 'sexual_content')
    and status in ('pending', 'in_review')
    and (
      preservation_state in ('partial', 'failed')
      or (preservation_state = 'pending' and created_at < now() - interval '10 minutes')
      or (preservation_state = 'retrying' and preservation_lease_until < now())
    );
  return found;
end;
$$;

revoke all on function public.claim_report_preservation_retry(bigint)
  from public, anon, authenticated;
grant execute on function public.claim_report_preservation_retry(bigint)
  to service_role;

-- All published-asset deletion now goes through delete-work/delete-account so
-- it participates in the work/report claims above. Direct Storage DELETE could
-- otherwise erase bytes while the database row remained locked.
drop policy if exists "works_delete_self" on storage.objects;
drop policy if exists "thumbnails_delete_self" on storage.objects;
drop policy if exists works_no_client_delete on storage.objects;
create policy works_no_client_delete on storage.objects
  as restrictive for delete to authenticated
  using (bucket_id <> 'works');
drop policy if exists thumbnails_no_client_delete on storage.objects;
create policy thumbnails_no_client_delete on storage.objects
  as restrictive for delete to authenticated
  using (bucket_id <> 'thumbnails');

-- Never trust a client-supplied association between an account report and a
-- work. The work must belong to the reported account. Capture an immutable
-- moderation snapshot now so the review context survives later edits/deletion.
create or replace function public.enforce_user_report_source_work()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  w public.works%rowtype;
begin
  if NEW.target_type <> 'user' then
    NEW.source_work_id := null;
    NEW.source_work_snapshot := null;
    NEW.preservation_state := 'not_required';
    return NEW;
  end if;

  if NEW.source_work_id is null then
    NEW.source_work_snapshot := null;
    NEW.preservation_state := 'not_required';
    return NEW;
  end if;

  select * into w from public.works
  where id = NEW.source_work_id
  for key share;
  if not found or w.user_id <> NEW.target_id then
    raise exception 'source work does not belong to reported user'
      using errcode = '23514';
  end if;
  if exists (
    select 1 from public.work_deletion_claims c
    where c.work_id = NEW.source_work_id and c.expires_at > now()
  ) then
    raise exception 'source work deletion is in progress' using errcode = '55000';
  end if;

  NEW.source_work_snapshot := jsonb_build_object(
    'id', w.id,
    'user_id', w.user_id,
    'title', w.title,
    'description', w.description,
    'format', w.format,
    'visibility', w.visibility,
    'moderation_status', w.moderation_status,
    'published_at', w.published_at,
    'publish_region', w.publish_region,
    'model_storage_path', w.model_storage_path,
    'thumbnail_storage_path', w.thumbnail_storage_path,
    'preview_video_path', w.preview_video_path,
    'captured_at', now()
  );
  NEW.preservation_state := case
    when NEW.reason in ('minor_safety', 'sexual_content') then 'pending'
    else 'not_required'
  end;
  return NEW;
end;
$$;

drop trigger if exists enforce_user_report_source_work on public.reports;
create trigger enforce_user_report_source_work
before insert or update of target_type, target_id, source_work_id, reason
on public.reports
for each row execute function public.enforce_user_report_source_work();

create or replace function public.guard_work_delete_for_report_preservation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1 from public.reports r
    where r.source_work_id = OLD.id
      and r.target_type = 'user'
      and r.reason in ('minor_safety', 'sexual_content')
      and r.status in ('pending', 'in_review')
      and r.preservation_state not in ('complete', 'released')
  ) then
    raise exception 'work is held for report evidence preservation'
      using errcode = '55000';
  end if;
  return OLD;
end;
$$;

drop trigger if exists guard_work_delete_for_report_preservation on public.works;
create trigger guard_work_delete_for_report_preservation
before delete on public.works
for each row execute function public.guard_work_delete_for_report_preservation();

-- Tighten the client insert policy so a caller cannot report themselves.
drop policy if exists reports_insert_self on public.reports;
create policy reports_insert_self on public.reports
  for insert to authenticated
  with check (
    app.current_user_id() = reporter_id
    and target_type <> 'user'
    and (target_type <> 'user' or target_id <> reporter_id)
    and admin_notes is null
    and resolved_by is null
    and resolved_at is null
    and status = 'pending'
  );

create index if not exists idx_reports_source_work
  on public.reports(source_work_id) where source_work_id is not null;

-- Storage remains private. There are deliberately no storage.objects policies:
-- only the authenticated Edge Function's service-role client may write and only
-- the admin review function may mint a five-minute signed read URL.
insert into storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
)
values (
  'report-evidence', 'report-evidence', false, 5242880,
  array['image/jpeg', 'image/png']::text[]
)
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('report-source-evidence', 'report-source-evidence', false, null, null)
on conflict (id) do update set public = false;

create table if not exists public.report_source_assets (
  id uuid primary key default gen_random_uuid(),
  report_id bigint not null references public.reports(id) on delete cascade,
  reporter_id uuid not null references auth.users(id) on delete cascade,
  ordinal smallint not null check (ordinal between 0 and 2),
  source_bucket text not null,
  source_path text not null,
  storage_path text not null unique,
  byte_size bigint not null check (byte_size > 0),
  content_type text,
  created_at timestamptz not null default now(),
  unique (report_id, ordinal)
);

alter table public.report_source_assets enable row level security;
revoke all on public.report_source_assets from anon, authenticated;

create table if not exists public.report_evidence (
  id uuid primary key default gen_random_uuid(),
  report_id bigint not null references public.reports(id) on delete cascade,
  reporter_id uuid not null references auth.users(id) on delete cascade,
  ordinal smallint not null check (ordinal between 0 and 2),
  storage_path text not null unique check (char_length(storage_path) <= 500),
  content_type text not null check (content_type in ('image/jpeg', 'image/png')),
  byte_size integer not null check (byte_size between 1 and 5242880),
  width integer not null check (width between 1 and 2048),
  height integer not null check (height between 1 and 2048),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now(),
  unique (report_id, ordinal)
);

create index if not exists idx_report_evidence_report
  on public.report_evidence(report_id, ordinal);

alter table public.report_evidence enable row level security;

-- Empty authenticated policy set is intentional. service_role bypasses RLS.
revoke all on public.report_evidence from anon, authenticated;
revoke all on function public.enforce_report_detail_limit() from public;
revoke all on function public.normalize_legacy_report_reason() from public;
revoke all on function public.enforce_user_report_source_work() from public;
revoke all on function public.reject_self_user_report() from public;
revoke all on function public.guard_work_delete_for_report_preservation() from public;

commit;
