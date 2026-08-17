-- Works moderation + takedown path.
--
-- Why now: reports existed with no enforcement half — nothing in the
-- schema could take a work down except the owner editing their own
-- visibility (works_update_own is owner-only), so "handling a report"
-- meant hand-editing rows in the SQL Editor with no audit trail. App
-- Store Guideline 1.2 requires a UGC platform to be able to remove
-- objectionable content; these two columns + one service_role RPC are
-- the minimum that makes that real.
--
-- Deliberately NOT here: owner-initiated soft delete (owner delete
-- stays a hard DELETE today), and the works-bucket public-read
-- weakness (a removed work's file stays fetchable by anyone who saved
-- the URL — fixing that means moving the bucket to signed URLs, which
-- is its own migration).
--
-- Depends on: 20260429020000_core_business.sql (works)
--             20260429020005_moderation.sql (audit_logs)

alter table public.works
  add column if not exists moderation_status text not null default 'ok'
    check (moderation_status in ('ok', 'under_review', 'removed')),
  add column if not exists deleted_at timestamptz;

comment on column public.works.moderation_status is
  'ok = visible; under_review = hidden from public feed pending review; removed = taken down by admin.';
comment on column public.works.deleted_at is
  'Set when moderation_status becomes removed. Row is kept for audit/appeal; hard DELETE stays owner-only.';

-- READ policy now requires a clean moderation state for the public
-- path. Owners keep seeing their own rows in ANY state so the app can
-- show "removed / under review" instead of silently vanishing the work.
drop policy if exists works_select_visible on public.works;
create policy works_select_visible on public.works
  for select to anon, authenticated
  using (
    (
      visibility = 'public'
      and moderation_status = 'ok'
      and deleted_at is null
    )
    or auth.uid() = user_id  -- [PORTABLE]
  );

-- Owners must not be able to flip moderation fields back themselves
-- (works_update_own allows updating any column). A trigger — not a
-- policy — because an RLS policy that subselects its own table
-- recurses, and WITH CHECK only sees the NEW row anyway. Client
-- traffic runs as anon/authenticated; the admin RPC below is SECURITY
-- DEFINER so inside it current_user is the function owner and the
-- guard lets it through. [PORTABLE]: off Supabase, swap the role list
-- for whatever your API connects as.
create or replace function public.guard_work_moderation_columns()
returns trigger
language plpgsql
as $$
begin
  if (new.moderation_status is distinct from old.moderation_status
      or new.deleted_at is distinct from old.deleted_at)
     and current_user in ('anon', 'authenticated') then
    raise exception 'moderation fields are admin-managed'
      using errcode = '42501';  -- insufficient_privilege
  end if;
  return new;
end;
$$;

drop trigger if exists guard_work_moderation_columns on public.works;
create trigger guard_work_moderation_columns
before update on public.works
for each row execute function public.guard_work_moderation_columns();

-- ── admin takedown RPC (service_role only) ───────────────────────────
-- Runs as definer, writes the audit trail in the same transaction.
-- Clients cannot call it: EXECUTE is revoked from anon/authenticated.
create or replace function public.admin_set_work_moderation(
  p_work_id uuid,
  p_status text,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_status not in ('ok', 'under_review', 'removed') then
    raise exception 'invalid moderation status: %', p_status;
  end if;

  update public.works
     set moderation_status = p_status,
         deleted_at = case
           when p_status = 'removed' then coalesce(deleted_at, now())
           else null
         end
   where id = p_work_id;
  if not found then
    raise exception 'work % not found', p_work_id;
  end if;

  insert into public.audit_logs (actor_id, action, target_type, target_id, metadata)
  values (
    null,  -- admin action via service_role; no auth.uid() in that context
    'admin.work_moderation_set',
    'work',
    p_work_id,
    jsonb_build_object('status', p_status, 'reason', p_reason)
  );
end;
$$;

comment on function public.admin_set_work_moderation(uuid, text, text) is
  'Admin takedown/restore for a work. service_role only; audit-logged. Usage: select admin_set_work_moderation(''<work-uuid>'', ''removed'', ''report #123'');';

revoke execute on function public.admin_set_work_moderation(uuid, text, text)
  from public, anon, authenticated;
