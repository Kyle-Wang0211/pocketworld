-- Make record_work_view() the only way to record a view.
--
-- 20260817001000 added the RPC (with a visibility check and hourly
-- dedup) but left the original direct-INSERT policy in place, so the RPC
-- was merely *an* option, not *the* option. Two things made the direct
-- path worse than useless:
--
--   • work_views_insert's WITH CHECK only constrained viewer_id. It never
--     checked whether the caller may see the work, so anyone could record
--     views on private or removed works.
--   • view_bucket is a plain client-writable column whose only guard is a
--     DEFAULT. The dedup unique index includes it, so a caller supplying
--     a million distinct timestamps never conflicts — and
--     bump_work_views_count increments works.views_count once per row.
--
-- Together: any anonymous caller could inflate any work's view count to
-- an arbitrary number, for free. Removing the policy closes it; the RPC
-- remains reachable by anon and authenticated (feed views are counted for
-- signed-out visitors too), but it enforces visibility and always writes
-- its own hour bucket.
--
-- Client impact: none. lib/community/community_service.dart's recordView
-- is the only writer and already calls the RPC.
--
-- Depends on: 20260817001000_record_view_rpc_and_feed_indexes.sql

drop policy if exists work_views_insert on public.work_views;

-- Pin the bucket server-side rather than trusting the column DEFAULT, so
-- the dedup key cannot be steered even if some future policy re-opens
-- direct inserts.
create or replace function public.record_work_view(p_work_id uuid)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_views integer;
begin
  -- Only count views on works the caller could actually open. Mirrors
  -- works_select_visible (public + clean moderation, or owner).
  if not exists (
    select 1 from public.works w
    where w.id = p_work_id
      and w.published_at is not null
      and (
        (w.visibility = 'public'
         and w.moderation_status = 'ok'
         and w.deleted_at is null)
        or w.user_id = auth.uid()  -- [PORTABLE]
      )
  ) then
    return null;
  end if;

  insert into public.work_views (work_id, viewer_id, view_bucket)
  values (p_work_id, auth.uid(), date_trunc('hour', now()))
  on conflict do nothing;

  select views_count into v_views from public.works where id = p_work_id;
  return v_views;
end;
$$;

comment on function public.record_work_view(uuid) is
  'Deduped view bump for a work; the only writer of work_views. Returns fresh views_count, or null when the work is not visible to the caller.';

grant execute on function public.record_work_view(uuid) to authenticated, anon;
