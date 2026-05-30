-- Manual cloud raw retention.
--
-- Product rule:
--   The phone may delete local staging after checksum ack, but cloud raw
--   capture assets remain available for later high-tier / desktop reruns
--   until the user explicitly deletes them.

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

  if v_scan.cloud_raw_deleted_at is not null then
    raise exception 'scan_cloud_raw_deleted';
  end if;

  if v_scan.status in ('processing', 'training', 'packaging') then
    raise exception 'scan_already_processing:%', v_scan.status;
  end if;

  if v_scan.status not in (
    'uploaded_acknowledged',
    'queued',
    'artifact_ready',
    'completed',
    'failed',
    'cancelled'
  ) then
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
               'requested_by', auth.uid(),
               'rerun_from_status', v_scan.status
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
    'queued_at', v_now,
    'rerun_from_status', v_scan.status
  );
end;
$$ language plpgsql;

grant execute on function public.request_scan_training(uuid, jsonb)
  to authenticated;

create or replace function public.mark_scan_cloud_raw_deleted(p_scan_id uuid)
returns jsonb
security definer
set search_path = public
as $$
declare
  v_scan public.scans%rowtype;
  v_deleted_at timestamptz := now();
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

  if v_scan.status in ('queued', 'processing', 'training', 'packaging') then
    raise exception 'scan_busy_cannot_delete_raw:%', v_scan.status;
  end if;

  update public.scans
     set cloud_raw_deleted_at = v_deleted_at,
         metadata = jsonb_set(
           coalesce(metadata, '{}'::jsonb),
           '{cloud_raw_cleanup}',
           jsonb_build_object(
             'deleted_at', v_deleted_at,
             'deleted_by', auth.uid(),
             'mode', 'user_manual'
           ),
           true
         )
   where id = p_scan_id;

  return jsonb_build_object(
    'scan_id', p_scan_id,
    'cloud_raw_deleted_at', v_deleted_at
  );
end;
$$ language plpgsql;

grant execute on function public.mark_scan_cloud_raw_deleted(uuid)
  to authenticated;
