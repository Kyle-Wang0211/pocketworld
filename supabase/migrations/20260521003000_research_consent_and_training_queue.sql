-- Research-data consent + explicit training queue request.
--
-- Product rule:
--   Upload/ack only means "raw capture safely reached cloud".
--   Training starts only after the user explicitly requests it from Drafts.

alter table public.profiles
  add column if not exists research_data_opt_in boolean not null default false,
  add column if not exists research_data_prompt_dismissed boolean not null default false,
  add column if not exists research_data_consent_version int not null default 1,
  add column if not exists research_data_opt_in_updated_at timestamptz;

comment on column public.profiles.research_data_opt_in is
  'User opt-in for using capture materials to improve reconstruction algorithms / AI models.';
comment on column public.profiles.research_data_prompt_dismissed is
  'Whether the one-time training-start consent prompt should stay hidden for this user.';

create index if not exists idx_scans_worker_queue_queued
  on public.scans(created_at)
  where status = 'queued';

create or replace function public.request_scan_training(
  p_scan_id uuid,
  p_research_consent jsonb default '{}'::jsonb
)
returns jsonb
security definer
set search_path = public
as $$
declare
  v_scan public.scans%rowtype;
  v_now timestamptz := now();
begin
  select *
    into v_scan
    from public.scans
   where id = p_scan_id
     and user_id = auth.uid()
   for update;

  if not found then
    raise exception 'scan_not_found_or_not_owned';
  end if;

  if v_scan.raw_storage_path is null or v_scan.raw_storage_path = '' then
    raise exception 'scan_upload_not_acknowledged';
  end if;

  if v_scan.status not in ('uploaded_acknowledged', 'queued') then
    raise exception 'scan_not_ready_for_training:%', v_scan.status;
  end if;

  update public.scans
     set status = 'queued',
         error_message = null,
         metadata = jsonb_set(
           jsonb_set(
             coalesce(metadata, '{}'::jsonb),
             '{training_requested}',
             jsonb_build_object(
               'requested_at', v_now,
               'requested_by', auth.uid()
             ),
             true
           ),
           '{research_consent}',
           coalesce(p_research_consent, '{}'::jsonb),
           true
         )
   where id = p_scan_id;

  return jsonb_build_object(
    'scan_id', p_scan_id,
    'queued', true,
    'queued_at', v_now
  );
end;
$$ language plpgsql;

grant execute on function public.request_scan_training(uuid, jsonb)
  to authenticated;
