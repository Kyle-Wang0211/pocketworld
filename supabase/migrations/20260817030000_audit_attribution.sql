-- Make moderation actions attributable.
--
-- 20260817000000 hard-coded `actor_id => null` in
-- admin_set_work_moderation with the comment "admin action via
-- service_role; no auth.uid() in that context". That is true, but it left
-- the audit trail unable to answer the question it exists for: it records
-- that a work was taken down and why, but not by whom, from where, or with
-- what tool. For a takedown
-- log that may have to substantiate "we removed this within 24 hours",
-- that is the part most likely to be asked about.
--
-- audit_logs already had `ip_address inet` and `user_agent text` columns
-- that none of the new functions were filling in. This wires them up.
--
-- HONEST LIMITATION: the service_role key is a bearer secret, not an
-- identity — it cannot tell one holder from another. `p_operator` is
-- self-declared by the caller and therefore NOT non-repudiable; it
-- distinguishes tooling ("verify-script", "admin-cli") and, once an
-- in-app admin console exists, should be replaced by a real admin user id
-- in p_actor. What IS objective here is the IP and user agent.

-- The signature changes, so a plain CREATE OR REPLACE would create an
-- overload and leave the old 3-arg version in place still writing nulls.
-- Drop it explicitly; grants are re-applied below.
drop function if exists public.admin_set_work_moderation(uuid, text, text);

create or replace function public.admin_set_work_moderation(
  p_work_id uuid,
  p_status text,
  p_reason text default null,
  p_actor uuid default null,
  p_operator text default null,
  p_ip text default null,
  p_user_agent text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ip inet;
begin
  if p_status not in ('ok', 'under_review', 'removed') then
    raise exception 'invalid moderation status: %', p_status;
  end if;

  -- x-forwarded-for can carry a list, and a malformed value must not take
  -- the whole takedown down with it — attribution is strictly less
  -- important than the action succeeding.
  begin
    v_ip := split_part(coalesce(p_ip, ''), ',', 1)::inet;
  exception when others then
    v_ip := null;
  end;

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

  insert into public.audit_logs (
    actor_id, action, target_type, target_id, metadata, ip_address, user_agent
  )
  values (
    p_actor,
    'admin.work_moderation_set',
    'work',
    p_work_id,
    jsonb_build_object(
      'status', p_status,
      'reason', p_reason,
      -- Self-declared; see the honest-limitation note above.
      'operator', p_operator,
      'actor_kind', case when p_actor is null then 'service_role' else 'user' end
    ),
    v_ip,
    left(coalesce(p_user_agent, ''), 500)
  );
end;
$$;

comment on function public.admin_set_work_moderation(uuid, text, text, uuid, text, text, text) is
  'Admin takedown/restore for a work. service_role only; audit-logged with IP/UA. p_operator is self-declared and not non-repudiable.';

-- Re-apply the access rules the DROP removed. Same posture as
-- 20260817000000 + the service_role grant added in 20260817011000.
revoke execute on function
  public.admin_set_work_moderation(uuid, text, text, uuid, text, text, text)
  from public, anon, authenticated;
grant execute on function
  public.admin_set_work_moderation(uuid, text, text, uuid, text, text, text)
  to service_role;

-- Guard: prove the old 3-arg overload is really gone, so we can't end up
-- with two callable versions where one silently writes null actors.
do $$
declare
  v_count int;
begin
  select count(*) into v_count
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'admin_set_work_moderation';
  if v_count <> 1 then
    raise exception
      'expected exactly 1 admin_set_work_moderation, found % (an overload would keep writing null actor_id)',
      v_count;
  end if;
end $$;
