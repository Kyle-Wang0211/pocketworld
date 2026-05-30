-- Cloud-first capture product loop.
--
-- This migration tightens the raw-capture lifecycle into the product
-- contract the app now wants:
--   phone staging -> Storage upload -> server ack -> local raw delete
--   -> worker output -> cross-device artifact sync.
-- Cloud raw cleanup is a separate explicit user action so captures can
-- be regenerated later on higher-tier workers.
--
-- The existing scans/works tables remain the source of truth. We extend
-- scans.status instead of introducing a parallel job table so old rows
-- and current RLS policies keep working.

alter table public.scans
  drop constraint if exists scans_status_check;

alter table public.scans
  add constraint scans_status_check check (status in (
    'uploading',
    'pending',
    'uploaded_acknowledged',
    'queued',
    'processing',
    'training',
    'packaging',
    'artifact_ready',
    'completed',
    'failed',
    'cancelled'
  ));

alter table public.scans
  add column if not exists upload_acknowledged_at timestamptz,
  add column if not exists local_raw_deleted_at timestamptz,
  add column if not exists cloud_raw_deleted_at timestamptz,
  add column if not exists processing_started_at timestamptz,
  add column if not exists processing_completed_at timestamptz,
  add column if not exists work_id uuid references public.works(id) on delete set null;

create index if not exists idx_scans_cloud_worker_queue
  on public.scans(created_at)
  where status in ('uploaded_acknowledged', 'queued');

create index if not exists idx_scans_work_id on public.scans(work_id);

-- ---------------------------------------------------------------------
-- ack_scan_upload
--
-- Called by the authenticated phone after all frame JPG/JSON objects and
-- the cloud manifest have been uploaded. The function verifies that the
-- scan belongs to auth.uid(), that every object listed in
-- metadata.uploaded_objects exists in the private scans bucket, and that
-- the custom Storage metadata still carries the expected SHA256 when it
-- is available.
--
-- Supabase Storage has changed the custom metadata column shape across
-- versions. `to_jsonb(o)->'user_metadata'` works whether the column is
-- present or absent; older projects fall back to `metadata`.
-- ---------------------------------------------------------------------
create or replace function public.ack_scan_upload(p_scan_id uuid)
returns jsonb
security definer
set search_path = public, storage
as $$
declare
  v_scan public.scans%rowtype;
  v_objects jsonb;
  v_obj jsonb;
  v_path text;
  v_expected_sha text;
  v_actual_sha text;
  v_expected_bytes bigint;
  v_actual_bytes bigint;
  v_seen int := 0;
  v_checksum_confirmed boolean := true;
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
    raise exception 'scan_raw_manifest_missing';
  end if;

  v_objects := coalesce(v_scan.metadata->'uploaded_objects', '[]'::jsonb);
  if jsonb_typeof(v_objects) <> 'array' or jsonb_array_length(v_objects) = 0 then
    raise exception 'scan_uploaded_objects_missing';
  end if;

  for v_obj in select * from jsonb_array_elements(v_objects)
  loop
    v_seen := v_seen + 1;
    v_path := v_obj->>'storage_path';
    v_expected_sha := nullif(v_obj->>'sha256', '');
    v_expected_bytes := nullif(v_obj->>'bytes', '')::bigint;

    if v_path is null or v_path = '' then
      raise exception 'scan_uploaded_object_path_missing';
    end if;

    select
      coalesce(
        to_jsonb(o)->'user_metadata'->>'sha256',
        o.metadata->>'sha256',
        o.metadata#>>'{metadata,sha256}'
      ),
      coalesce(
        nullif(to_jsonb(o)->'user_metadata'->>'bytes', '')::bigint,
        nullif(o.metadata->>'bytes', '')::bigint,
        nullif(o.metadata#>>'{metadata,bytes}', '')::bigint,
        nullif(o.metadata->>'size', '')::bigint
      )
      into v_actual_sha, v_actual_bytes
      from storage.objects o
     where o.bucket_id = 'scans'
       and o.name = v_path;

    if not found then
      raise exception 'scan_uploaded_object_missing:%', v_path;
    end if;

    if v_expected_sha is not null then
      if v_actual_sha is null then
        v_checksum_confirmed := false;
      elsif v_actual_sha <> v_expected_sha then
        raise exception 'scan_uploaded_object_sha256_mismatch:%', v_path;
      end if;
    end if;

    if v_expected_bytes is not null
       and v_actual_bytes is not null
       and v_actual_bytes <> v_expected_bytes then
      raise exception 'scan_uploaded_object_size_mismatch:%', v_path;
    end if;
  end loop;

  update public.scans
     set status = 'uploaded_acknowledged',
         upload_acknowledged_at = now(),
         error_message = null,
         metadata = jsonb_set(
           coalesce(metadata, '{}'::jsonb),
           '{upload_ack}',
           jsonb_build_object(
             'acknowledged_at', now(),
             'uploaded_object_count', v_seen,
             'checksum_confirmed', v_checksum_confirmed,
             'cloud_manifest_storage_path', v_scan.raw_storage_path
           ),
           true
         )
   where id = p_scan_id;

  return jsonb_build_object(
    'scan_id', p_scan_id,
    'acknowledged', true,
    'uploaded_object_count', v_seen,
    'checksum_confirmed', v_checksum_confirmed,
    'cloud_manifest_storage_path', v_scan.raw_storage_path
  );
end;
$$ language plpgsql;

grant execute on function public.ack_scan_upload(uuid) to authenticated;

create or replace function public.mark_scan_local_raw_deleted(p_scan_id uuid)
returns jsonb
security definer
set search_path = public
as $$
declare
  v_deleted_at timestamptz := now();
begin
  update public.scans
     set local_raw_deleted_at = v_deleted_at,
         metadata = jsonb_set(
           coalesce(metadata, '{}'::jsonb),
           '{local_raw_cleanup}',
           jsonb_build_object('deleted_at', v_deleted_at),
           true
         )
   where id = p_scan_id
     and user_id = auth.uid();

  if not found then
    raise exception 'scan_not_found_or_not_owned';
  end if;

  return jsonb_build_object(
    'scan_id', p_scan_id,
    'local_raw_deleted_at', v_deleted_at
  );
end;
$$ language plpgsql;

grant execute on function public.mark_scan_local_raw_deleted(uuid) to authenticated;
