-- Capture audit logging.
--
-- The audit log is internal-only (RLS enabled with no client policies).
-- This trigger records the capture lifecycle from the database side so
-- phone, desktop, and worker updates all leave the same trail.

alter table public.audit_logs
  drop constraint if exists audit_logs_target_type_check;

alter table public.audit_logs
  add constraint audit_logs_target_type_check
  check (
    target_type in (
      'user',
      'work',
      'comment',
      'project',
      'report',
      'system',
      'scan',
      'storage',
      'worker'
    )
  );

create or replace function public.audit_scan_lifecycle()
returns trigger
security definer
set search_path = public
as $$
declare
  v_actor uuid := coalesce(auth.uid(), new.user_id);
  v_actor_kind text := case
    when auth.uid() is null then 'service_role_or_worker'
    else 'user'
  end;
  v_base jsonb := jsonb_build_object(
    'actor_kind', v_actor_kind,
    'user_id', new.user_id,
    'scan_id', new.id,
    'old_status', old.status,
    'new_status', new.status
  );
begin
  if old.status is distinct from new.status then
    insert into public.audit_logs (
      actor_id,
      action,
      target_type,
      target_id,
      metadata
    )
    values (
      v_actor,
      'scan.status_changed',
      'scan',
      new.id,
      v_base
    );
  end if;

  if old.upload_acknowledged_at is distinct from new.upload_acknowledged_at
     and new.upload_acknowledged_at is not null then
    insert into public.audit_logs (
      actor_id,
      action,
      target_type,
      target_id,
      metadata
    )
    values (
      v_actor,
      'scan.upload_acknowledged',
      'scan',
      new.id,
      v_base || jsonb_build_object(
        'upload_acknowledged_at', new.upload_acknowledged_at,
        'uploaded_object_count',
          new.metadata#>>'{upload_ack,uploaded_object_count}',
        'checksum_confirmed',
          new.metadata#>>'{upload_ack,checksum_confirmed}'
      )
    );
  end if;

  if old.local_raw_deleted_at is distinct from new.local_raw_deleted_at
     and new.local_raw_deleted_at is not null then
    insert into public.audit_logs (
      actor_id,
      action,
      target_type,
      target_id,
      metadata
    )
    values (
      v_actor,
      'scan.local_raw_deleted',
      'scan',
      new.id,
      v_base || jsonb_build_object(
        'local_raw_deleted_at', new.local_raw_deleted_at
      )
    );
  end if;

  if old.cloud_raw_deleted_at is distinct from new.cloud_raw_deleted_at
     and new.cloud_raw_deleted_at is not null then
    insert into public.audit_logs (
      actor_id,
      action,
      target_type,
      target_id,
      metadata
    )
    values (
      v_actor,
      'scan.cloud_raw_deleted',
      'scan',
      new.id,
      v_base || jsonb_build_object(
        'cloud_raw_deleted_at', new.cloud_raw_deleted_at,
        'delete_mode', new.metadata#>>'{cloud_raw_cleanup,mode}'
      )
    );
  end if;

  if old.metadata->'training_requested'
     is distinct from new.metadata->'training_requested'
     and new.metadata ? 'training_requested' then
    insert into public.audit_logs (
      actor_id,
      action,
      target_type,
      target_id,
      metadata
    )
    values (
      v_actor,
      'scan.training_requested',
      'scan',
      new.id,
      v_base || jsonb_build_object(
        'training_requested', new.metadata->'training_requested',
        'research_consent', new.metadata->'research_consent'
      )
    );
  end if;

  if old.work_id is distinct from new.work_id and new.work_id is not null then
    insert into public.audit_logs (
      actor_id,
      action,
      target_type,
      target_id,
      metadata
    )
    values (
      v_actor,
      'scan.work_attached',
      'scan',
      new.id,
      v_base || jsonb_build_object('work_id', new.work_id)
    );
  end if;

  return new;
end;
$$ language plpgsql;

drop trigger if exists trg_audit_scan_lifecycle on public.scans;

create trigger trg_audit_scan_lifecycle
after update on public.scans
for each row
execute function public.audit_scan_lifecycle();
