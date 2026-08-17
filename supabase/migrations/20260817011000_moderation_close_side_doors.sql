-- Close the side doors left open by 20260817000000 (moderation takedown).
--
-- That migration added moderation_status/deleted_at and filtered them in
-- works_select_visible — but SEVEN other policies independently re-derive
-- "is this work public?" from `w.visibility = 'public'` alone, and none
-- of them were updated. Net effect: a "removed" work still leaked
-- everything through the satellites, and — via work_versions, which
-- carries model_storage_path — the FILE stayed downloadable. The note in
-- 20260817000000 claiming the residual risk was limited to "anyone who
-- saved the URL beforehand" was wrong; this migration retracts it.
--
-- INVARIANT (keep this list in sync — that is exactly what went wrong):
-- a work is publicly visible iff
--     visibility = 'public' AND moderation_status = 'ok' AND deleted_at IS NULL
-- The owner always sees their own rows in any state, so the app can show
-- "removed / under review" instead of silently vanishing the work.
-- Policies that encode this predicate:
--   1. works_select_visible                (20260817000000)
--   2. comments_select_visible             ← here
--   3. comments_insert_self                ← here
--   4. work_likes_select_visible           ← here
--   5. comment_likes_select_visible        ← here
--   6. work_versions_select_visible        ← here  (leaks storage path!)
--   7. work_tags_select_visible            ← here
--   8. collection_works_select_visible     ← here
--   9. storage.objects "works_select_public" ← here
--  10. record_work_view()                  (20260817001000, already correct)
--
-- Deliberately NOT changed: the works bucket stays public-read. Making
-- takedown airtight at the storage layer means moving to signed URLs,
-- which changes every read path in the app — its own migration.
-- What IS fixed here is that the storage policy now also requires a
-- clean moderation state, so a removed work's file stops resolving.
--
-- Depends on: 20260817000000_works_moderation_takedown.sql

-- ── 2. comments: read ────────────────────────────────────────────────
drop policy if exists comments_select_visible on public.comments;
create policy comments_select_visible on public.comments
  for select to anon, authenticated
  using (
    exists (
      select 1 from public.works w
      where w.id = comments.work_id
        and (
          (
            w.visibility = 'public'
            and w.moderation_status = 'ok'
            and w.deleted_at is null
          )
          or w.user_id = auth.uid()  -- [PORTABLE]
        )
    )
  );

-- ── 3. comments: insert (no new comments on a removed work) ──────────
drop policy if exists comments_insert_self on public.comments;
create policy comments_insert_self on public.comments
  for insert to authenticated
  with check (
    auth.uid() = user_id  -- [PORTABLE]
    and exists (
      select 1 from public.works w
      where w.id = comments.work_id
        and (
          (
            w.visibility = 'public'
            and w.moderation_status = 'ok'
            and w.deleted_at is null
          )
          or w.user_id = auth.uid()  -- [PORTABLE]
        )
    )
  );

-- ── 4. work_likes: read ──────────────────────────────────────────────
drop policy if exists work_likes_select_visible on public.work_likes;
create policy work_likes_select_visible on public.work_likes
  for select to anon, authenticated
  using (
    exists (
      select 1 from public.works w
      where w.id = work_likes.work_id
        and (
          (
            w.visibility = 'public'
            and w.moderation_status = 'ok'
            and w.deleted_at is null
          )
          or w.user_id = auth.uid()  -- [PORTABLE]
        )
    )
  );

-- ── 5. comment_likes: read (visibility recurses through comments) ────
drop policy if exists comment_likes_select_visible on public.comment_likes;
create policy comment_likes_select_visible on public.comment_likes
  for select to anon, authenticated
  using (
    exists (
      select 1 from public.comments c
      where c.id = comment_likes.comment_id
        and exists (
          select 1 from public.works w
          where w.id = c.work_id
            and (
              (
                w.visibility = 'public'
                and w.moderation_status = 'ok'
                and w.deleted_at is null
              )
              or w.user_id = auth.uid()  -- [PORTABLE]
            )
        )
    )
  );

-- ── 6. work_versions: read — THE important one ───────────────────────
-- work_versions.model_storage_path is the storage key. Leaving this on
-- the old predicate meant anon could still enumerate the path of a
-- removed work and fetch the file from the public bucket.
drop policy if exists work_versions_select_visible on public.work_versions;
create policy work_versions_select_visible on public.work_versions
  for select to anon, authenticated
  using (
    exists (
      select 1 from public.works w
      where w.id = work_versions.work_id
        and (
          (
            w.visibility = 'public'
            and w.moderation_status = 'ok'
            and w.deleted_at is null
          )
          or w.user_id = auth.uid()  -- [PORTABLE]
        )
    )
  );

-- ── 7. work_tags: read ───────────────────────────────────────────────
drop policy if exists work_tags_select_visible on public.work_tags;
create policy work_tags_select_visible on public.work_tags
  for select to anon, authenticated
  using (
    exists (
      select 1 from public.works w
      where w.id = work_tags.work_id
        and (
          (
            w.visibility = 'public'
            and w.moderation_status = 'ok'
            and w.deleted_at is null
          )
          or w.user_id = auth.uid()  -- [PORTABLE]
        )
    )
  );

-- ── 8. collection_works: read (collection AND work must be visible) ──
drop policy if exists collection_works_select_visible on public.collection_works;
create policy collection_works_select_visible on public.collection_works
  for select to anon, authenticated
  using (
    exists (
      select 1 from public.collections c
      where c.id = collection_works.collection_id
        and (c.visibility = 'public' or c.user_id = auth.uid())  -- [PORTABLE]
    )
    and exists (
      select 1 from public.works w
      where w.id = collection_works.work_id
        and (
          (
            w.visibility = 'public'
            and w.moderation_status = 'ok'
            and w.deleted_at is null
          )
          or w.user_id = auth.uid()  -- [PORTABLE]
        )
    )
  );

-- ── 9. storage.objects: the works bucket read policy ─────────────────
drop policy if exists "works_select_public" on storage.objects;
create policy "works_select_public"
  on storage.objects for select to anon, authenticated
  using (
    bucket_id = 'works'
    and exists (
      select 1 from public.works w
      where w.model_storage_path = storage.objects.name
        and w.visibility = 'public'
        and w.moderation_status = 'ok'
        and w.deleted_at is null
    )
  );

-- ── DELETE guard: a removed work cannot be erased by its owner ───────
-- The UPDATE guard alone was bypassable: works_delete_own let the owner
-- hard-delete the moderated row and re-INSERT a fresh one with
-- moderation_status='ok' pointing at the same, never-deleted storage
-- object — resurrecting the content in seconds, and destroying the audit
-- trail that 20260817000000 claimed to keep.
--
-- Scope note: this preserves the RECORD. It does not prevent the user
-- from uploading the same bytes again as a brand-new work; content-level
-- banning needs a hash blocklist, which is not implemented here.
create or replace function public.guard_work_moderation_delete()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if (old.moderation_status is distinct from 'ok' or old.deleted_at is not null)
     and current_user in ('anon', 'authenticated') then  -- [PORTABLE]
    raise exception 'moderated works cannot be deleted'
      using errcode = '42501';  -- insufficient_privilege
  end if;
  return old;
end;
$$;

drop trigger if exists guard_work_moderation_delete on public.works;
create trigger guard_work_moderation_delete
before delete on public.works
for each row execute function public.guard_work_moderation_delete();

-- ── fix: the UPDATE guard was missing search_path ────────────────────
-- Flagged by `supabase db advisors --type security` as
-- "function_search_path_mutable". The sibling functions in
-- 20260817000000 both set it; this one was an oversight.
-- It must stay SECURITY INVOKER: as DEFINER, current_user would become
-- the function owner and the role check below would never fire, silently
-- disabling the guard.
create or replace function public.guard_work_moderation_columns()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if (new.moderation_status is distinct from old.moderation_status
      or new.deleted_at is distinct from old.deleted_at)
     and current_user in ('anon', 'authenticated') then  -- [PORTABLE]
    raise exception 'moderation fields are admin-managed'
      using errcode = '42501';  -- insufficient_privilege
  end if;
  return new;
end;
$$;

-- ── ensure the admin RPC is actually callable by the admin path ──────
-- 20260817000000 revoked EXECUTE from public/anon/authenticated but never
-- granted it explicitly. Whether service_role retained it depends on the
-- project's default privileges; granting is idempotent and removes the
-- doubt. (Verified via advisors that anon/authenticated cannot call it.)
grant execute on function public.admin_set_work_moderation(uuid, text, text)
  to service_role;
