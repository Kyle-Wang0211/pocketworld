-- record_work_view RPC + the two missing feed indexes.
--
-- Why the RPC: the client-side upsert against work_views could never
-- work — uq_work_views_dedup is an *expression* index
-- (work_id, coalesce(viewer_id::text,'anon'), view_bucket) and
-- PostgREST's on_conflict parameter only accepts plain column lists,
-- so every upsert was rejected with 400 before reaching the table,
-- then swallowed by the client's catch — works.views_count never
-- moved. Server-side ON CONFLICT DO NOTHING with no conflict target
-- matches against ANY unique index, expression indexes included, so a
-- SECURITY DEFINER RPC is the smallest correct fix.
--
-- Depends on: 20260429020001_engagement.sql (work_views + count trigger)
--             20260817000000_works_moderation_takedown.sql (moderation columns)

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

  -- view_bucket defaults to date_trunc('hour', now()); the expression
  -- unique index dedups (work, viewer-or-anon, hour) and the AFTER
  -- INSERT trigger bumps works.views_count only when a row lands.
  insert into public.work_views (work_id, viewer_id)
  values (p_work_id, auth.uid())
  on conflict do nothing;

  select views_count into v_views from public.works where id = p_work_id;
  return v_views;
end;
$$;

comment on function public.record_work_view(uuid) is
  'Deduped view bump for a work; returns fresh views_count, or null when the work is not visible to the caller.';

grant execute on function public.record_work_view(uuid) to authenticated, anon;

-- FeedSort.hot orders by (likes_count desc, published_at desc) over
-- public published works; until now only published_at had a partial
-- index, so the hot tab was a full scan + sort.
create index if not exists idx_works_hot
  on public.works (likes_count desc, published_at desc)
  where visibility = 'public' and published_at is not null;

-- storage_buckets works policies join on
-- works.model_storage_path = storage.objects.name; without this every
-- object ACL check seq-scans works.
create index if not exists idx_works_model_storage_path
  on public.works (model_storage_path);
