begin;

-- Social profile launch hardening: bilateral block enforcement, caller-bound
-- social-list RPCs, and public-visible works_count semantics.
--
-- Depends on:
--   20260429020000_core_business.sql
--   20260429020002_social_graph.sql
--   20260817000000_works_moderation_takedown.sql
--   20260818010000_app_auth_abstraction.sql

-- The old policy checked only whether the followee had blocked the follower.
-- A blocker could therefore re-follow someone they had blocked. Enforce both
-- directions and clean up any rows created through that gap before relocking.
-- Lock in the same blocks -> follows order used by cascade_block_unfollow so
-- no old-policy insert can race between cleanup and policy replacement.
lock table public.blocks in share row exclusive mode;
lock table public.follows in share row exclusive mode;

delete from public.follows f
using public.blocks b
where (b.blocker_id = f.follower_id and b.blocked_id = f.followee_id)
   or (b.blocker_id = f.followee_id and b.blocked_id = f.follower_id);

-- RLS on blocks intentionally hides "who blocked me" rows. A follows policy
-- that queries blocks directly would therefore miss the reverse direction.
-- This boolean helper bypasses that RLS without returning block rows, and
-- fixes the follower identity to the authenticated caller.
create or replace function app.can_current_user_follow(p_followee_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app.current_user_id() is not null
     and app.current_user_id() <> p_followee_id
     and not exists (
       select 1
       from public.blocks b
       where (b.blocker_id = app.current_user_id()
              and b.blocked_id = p_followee_id)
          or (b.blocker_id = p_followee_id
              and b.blocked_id = app.current_user_id())
     )
$$;

revoke all on function app.can_current_user_follow(uuid) from public, anon;
grant execute on function app.can_current_user_follow(uuid) to authenticated;

-- Serialize follow and block writes for the same unordered user pair. Without
-- this shared transaction lock, concurrent INSERTs can each miss the other's
-- uncommitted row and commit an impossible block+follow state.
create or replace function app.lock_social_pair(p_left uuid, p_right uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform pg_advisory_xact_lock(
    hashtextextended(
      least(p_left::text, p_right::text) || ':' ||
      greatest(p_left::text, p_right::text),
      0
    )
  );
end;
$$;

create or replace function public.guard_follow_against_block()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.lock_social_pair(NEW.follower_id, NEW.followee_id);
  if exists (
    select 1 from public.blocks b
    where (b.blocker_id = NEW.follower_id and b.blocked_id = NEW.followee_id)
       or (b.blocker_id = NEW.followee_id and b.blocked_id = NEW.follower_id)
  ) then
    raise exception 'cannot follow across a block' using errcode = '23514';
  end if;
  return NEW;
end;
$$;

create or replace function public.lock_block_social_pair()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform app.lock_social_pair(NEW.blocker_id, NEW.blocked_id);
  return NEW;
end;
$$;

drop trigger if exists social_follow_guard_ins on public.follows;
create trigger social_follow_guard_ins
before insert on public.follows
for each row execute function public.guard_follow_against_block();

drop trigger if exists social_block_lock_ins on public.blocks;
create trigger social_block_lock_ins
before insert on public.blocks
for each row execute function public.lock_block_social_pair();

revoke all on function app.lock_social_pair(uuid, uuid) from public;
revoke all on function public.guard_follow_against_block() from public;
revoke all on function public.lock_block_social_pair() from public;

drop policy if exists follows_insert_self on public.follows;
create policy follows_insert_self on public.follows
  for insert to authenticated
  with check (
    (select app.current_user_id()) = follower_id
    and app.can_current_user_follow(followee_id)
  );

-- A narrow SECURITY DEFINER projection is intentional: the caller can see a
-- private profile only when they already have the corresponding follow row.
-- It does not weaken profiles_select_public for arbitrary profile reads.
create or replace function public.get_my_following(
  p_limit integer default 1000,
  p_before_followed_at timestamptz default null,
  p_before_user_id uuid default null
)
returns table (
  id uuid,
  display_name text,
  handle text,
  avatar_url text,
  bio text,
  last_region text,
  followers_count integer,
  following_count integer,
  works_count integer,
  is_following boolean,
  is_blocked_by_viewer boolean,
  followed_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_viewer uuid;
  v_limit integer;
begin
  v_viewer := app.current_user_id();
  if v_viewer is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  p_limit := coalesce(p_limit, 1000);
  v_limit := least(greatest(p_limit, 1), 1000);

  return query
  select p.id,
         p.display_name,
         p.handle,
         p.avatar_url,
         p.bio,
         p.last_region,
         p.followers_count,
         p.following_count,
         p.works_count,
         true as is_following,
         false as is_blocked_by_viewer,
         f.created_at as followed_at
  from public.follows f
  join public.profiles p on p.id = f.followee_id
  where f.follower_id = v_viewer
    and (
      p_before_followed_at is null
      or (
        p_before_user_id is not null
        and (f.created_at, f.followee_id)
              < (p_before_followed_at, p_before_user_id)
      )
    )
  order by f.created_at desc, f.followee_id desc
  limit v_limit;
end;
$$;

revoke all on function public.get_my_following(integer, timestamptz, uuid)
  from public, anon;
grant execute on function public.get_my_following(integer, timestamptz, uuid)
  to authenticated;

-- The management list reveals only blocks owned by the caller. It never
-- exposes accounts that have blocked the caller.
create or replace function public.get_my_blocked_users(
  p_limit integer default 1000,
  p_before_blocked_at timestamptz default null,
  p_before_user_id uuid default null
)
returns table (
  id uuid,
  display_name text,
  handle text,
  avatar_url text,
  bio text,
  last_region text,
  followers_count integer,
  following_count integer,
  works_count integer,
  is_following boolean,
  is_blocked_by_viewer boolean,
  blocked_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_viewer uuid;
  v_limit integer;
begin
  v_viewer := app.current_user_id();
  if v_viewer is null then
    raise exception 'authentication required' using errcode = '42501';
  end if;

  p_limit := coalesce(p_limit, 1000);
  v_limit := least(greatest(p_limit, 1), 1000);

  return query
  select p.id,
         p.display_name,
         p.handle,
         p.avatar_url,
         p.bio,
         p.last_region,
         p.followers_count,
         p.following_count,
         p.works_count,
         false as is_following,
         true as is_blocked_by_viewer,
         b.created_at as blocked_at
  from public.blocks b
  join public.profiles p on p.id = b.blocked_id
  where b.blocker_id = v_viewer
    and (
      p_before_blocked_at is null
      or (
        p_before_user_id is not null
        and (b.created_at, b.blocked_id)
              < (p_before_blocked_at, p_before_user_id)
      )
    )
  order by b.created_at desc, b.blocked_id desc
  limit v_limit;
end;
$$;

revoke all on function public.get_my_blocked_users(integer, timestamptz, uuid)
  from public, anon;
grant execute on function public.get_my_blocked_users(integer, timestamptz, uuid)
  to authenticated;

-- Suppress both sides of a block at the row-visibility boundary without ever
-- returning reverse-direction block rows to the client. Keeping this helper in
-- the non-exposed app schema prevents a "who blocked me" RPC oracle.
create or replace function app.can_current_user_view_account(p_user_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select app.current_user_id() is null
      or app.current_user_id() = p_user_id
      or not exists (
        select 1
        from public.blocks b
        where (b.blocker_id = app.current_user_id()
               and b.blocked_id = p_user_id)
           or (b.blocker_id = p_user_id
               and b.blocked_id = app.current_user_id())
      )
$$;

revoke all on function app.can_current_user_view_account(uuid) from public;
grant execute on function app.can_current_user_view_account(uuid)
  to anon, authenticated;

-- One caller-bound profile projection keeps an already-followed private account
-- navigable from My Following. Direct profiles RLS remains narrow, and blocks
-- still suppress the row in both directions.
create or replace function public.get_social_profile(p_user_id uuid)
returns table (
  id uuid,
  display_name text,
  handle text,
  avatar_url text,
  bio text,
  last_region text,
  followers_count integer,
  following_count integer,
  works_count integer,
  is_following boolean,
  is_blocked_by_viewer boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_viewer uuid;
begin
  v_viewer := app.current_user_id();

  return query
  select p.id,
         p.display_name,
         p.handle,
         p.avatar_url,
         p.bio,
         p.last_region,
         p.followers_count,
         p.following_count,
         p.works_count,
         exists (
           select 1 from public.follows f
           where f.follower_id = v_viewer and f.followee_id = p.id
         ) as is_following,
         exists (
           select 1 from public.blocks b
           where b.blocker_id = v_viewer and b.blocked_id = p.id
         ) as is_blocked_by_viewer
  from public.profiles p
  where p.id = p_user_id
    and app.can_current_user_view_account(p.id)
    and (
      not p.is_private
      or v_viewer = p.id
      or exists (
        select 1 from public.follows f
        where f.follower_id = v_viewer and f.followee_id = p.id
      )
    );
end;
$$;

revoke all on function public.get_social_profile(uuid) from public;
grant execute on function public.get_social_profile(uuid)
  to anon, authenticated;

drop policy if exists profiles_select_public on public.profiles;
create policy profiles_select_public on public.profiles
  for select to anon, authenticated
  using (
    (not is_private or app.current_user_id() = id)
    and app.can_current_user_view_account(id)
  );

drop policy if exists works_select_visible on public.works;
create policy works_select_visible on public.works
  for select to anon, authenticated
  using (
    app.current_user_id() = user_id
    or (
      visibility = 'public'
      and moderation_status = 'ok'
      and deleted_at is null
      and app.can_current_user_view_account(user_id)
    )
  );

-- DDL and the backfill share one migration transaction. Hold writes while the
-- trigger definition and cached profile counts move to the new meaning.
lock table public.works in share row exclusive mode;
lock table public.profiles in share row exclusive mode;

create or replace function public.bump_profile_works_count()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  old_counted boolean := false;
  new_counted boolean := false;
  delta integer;
begin
  if TG_OP <> 'INSERT' then
    old_counted := (
      OLD.published_at is not null
      and OLD.visibility = 'public'
      and OLD.moderation_status = 'ok'
      and OLD.deleted_at is null
    );
  end if;

  if TG_OP <> 'DELETE' then
    new_counted := (
      NEW.published_at is not null
      and NEW.visibility = 'public'
      and NEW.moderation_status = 'ok'
      and NEW.deleted_at is null
    );
  end if;

  if TG_OP = 'INSERT' then
    if new_counted then
      update public.profiles
         set works_count = works_count + 1
       where id = NEW.user_id;
    end if;
  elsif TG_OP = 'DELETE' then
    if old_counted then
      update public.profiles
         set works_count = greatest(0, works_count - 1)
       where id = OLD.user_id;
    end if;
  elsif OLD.user_id = NEW.user_id then
    delta := new_counted::integer - old_counted::integer;
    if delta <> 0 then
      update public.profiles
         set works_count = greatest(0, works_count + delta)
       where id = NEW.user_id;
    end if;
  else
    if old_counted then
      update public.profiles
         set works_count = greatest(0, works_count - 1)
       where id = OLD.user_id;
    end if;
    if new_counted then
      update public.profiles
         set works_count = works_count + 1
       where id = NEW.user_id;
    end if;
  end if;

  return null;
end;
$$;

drop trigger if exists bump_profile_works_count_ins on public.works;
drop trigger if exists bump_profile_works_count_del on public.works;
drop trigger if exists bump_profile_works_count_upd on public.works;

create trigger bump_profile_works_count_ins
after insert on public.works
for each row execute function public.bump_profile_works_count();

create trigger bump_profile_works_count_del
after delete on public.works
for each row execute function public.bump_profile_works_count();

create trigger bump_profile_works_count_upd
after update of user_id, published_at, visibility, moderation_status, deleted_at
on public.works
for each row execute function public.bump_profile_works_count();

with public_counts as (
  select w.user_id, count(*)::integer as works_count
  from public.works w
  where w.published_at is not null
    and w.visibility = 'public'
    and w.moderation_status = 'ok'
    and w.deleted_at is null
  group by w.user_id
)
update public.profiles p
set works_count = coalesce(c.works_count, 0)
from (
  select p0.id, pc.works_count
  from public.profiles p0
  left join public_counts pc on pc.user_id = p0.id
) c
where c.id = p.id;

commit;
