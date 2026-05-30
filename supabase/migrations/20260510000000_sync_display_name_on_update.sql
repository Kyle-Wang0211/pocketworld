-- Mirror auth.users.raw_user_meta_data.display_name into
-- public.profiles.display_name on UPDATE.
--
-- Background:
--   • The existing on_auth_user_created trigger (20260429030000) only
--     handles INSERT on auth.users — it bootstraps the initial
--     profiles row at signup, but never updates it again.
--   • Phase 4 (2026-05-10) added an in-app "edit display name" surface
--     that calls auth.updateUser(...) to rotate raw_user_meta_data.
--     Without this trigger, public.profiles.display_name stays frozen
--     at the signup value forever, which the community feed
--     (CommunityService.fetchPublicFeed JOINs works → profiles) reads
--     as the author handle on every published work. Net effect: user
--     renames themselves, every old published work still shows the
--     old name — breaks the mental model "my new name shows
--     everywhere".
--   • The Flutter client mirrors profiles.display_name explicitly
--     after auth.updateUser succeeds
--     (SupabaseAuthService.updateDisplayName) as a fast-path. This
--     trigger is the server-side backup for any client that uses
--     auth.updateUser without the mirror call (web build, admin
--     tools, future cross-platform native clients).

create or replace function public.handle_user_display_name_update()
returns trigger
security definer
set search_path = public
as $$
declare
  new_display text;
begin
  -- Only react when raw_user_meta_data actually changed. Email /
  -- phone / password rotations also fire AFTER UPDATE on auth.users
  -- and we don't want to thrash profiles for those.
  if new.raw_user_meta_data is distinct from old.raw_user_meta_data then
    new_display := coalesce(
      nullif(new.raw_user_meta_data->>'display_name', ''),
      split_part(new.email, '@', 1)
    );
    update public.profiles
      set display_name = new_display
      where id = new.id
        and display_name is distinct from new_display;
  end if;
  return new;
end;
$$ language plpgsql;

drop trigger if exists on_auth_user_metadata_updated on auth.users;
create trigger on_auth_user_metadata_updated
  after update on auth.users
  for each row execute function public.handle_user_display_name_update();

-- One-time backfill: any profile whose display_name is out of sync
-- with the canonical auth.users metadata gets resynced now.
-- Idempotent — the WHERE catches only the rows that actually need
-- updating, so re-running this migration is a no-op.
update public.profiles p
   set display_name = coalesce(
     nullif(u.raw_user_meta_data->>'display_name', ''),
     split_part(u.email, '@', 1)
   )
  from auth.users u
 where p.id = u.id
   and p.display_name is distinct from coalesce(
         nullif(u.raw_user_meta_data->>'display_name', ''),
         split_part(u.email, '@', 1)
       );
