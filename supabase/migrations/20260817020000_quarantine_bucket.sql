-- Quarantine bucket for taken-down content.
--
-- Why a separate bucket instead of a path prefix inside `works`:
-- the `works` bucket is public (20260429040000), and a public bucket
-- BYPASSES RLS entirely for /object/public/ reads — Supabase docs:
-- a public bucket "effectively bypasses access controls for both
-- retrieving and serving files". So moving an object to a prefix inside
-- the same bucket would leave it publicly downloadable. Only a private
-- bucket with NO policies is actually sealed (service_role only).
--
-- This also corrects a wrong assumption in 20260817011000: that
-- tightening the `works_select_public` storage policy would stop a
-- removed work's file from resolving. It does not — that policy is
-- never consulted on the public read path. The file has to physically
-- leave the public bucket. That is what admin-moderate-work does.
--
-- Retention: files are kept here rather than deleted so an appeal can
-- restore them (DSA Art.17 requires a statement of reasons; Santa Clara
-- Principles expect a real appeal path). Nothing expires them
-- automatically — deliberate, so a wrong takedown is always reversible.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('quarantine', 'quarantine', false, null, null)
on conflict (id) do nothing;

-- RLS is already enabled on storage.objects globally. We deliberately
-- create NO policies for bucket_id = 'quarantine', which means no anon
-- and no authenticated role can select/insert/update/delete here.
-- service_role bypasses RLS, so only the moderation Edge Function
-- (and the SQL editor) can touch quarantined files.
--
-- Guard against a future migration accidentally opening it up: assert
-- that nothing grants access to this bucket.
do $$
declare
  v_open_policies int;
begin
  select count(*) into v_open_policies
  from pg_policies
  where schemaname = 'storage'
    and tablename = 'objects'
    and qual ilike '%quarantine%';
  if v_open_policies > 0 then
    raise exception
      'quarantine bucket must have no storage.objects policies (found %)',
      v_open_policies;
  end if;
end $$;

-- NOTE (cannot be a table COMMENT — migration role does not own
-- storage.buckets): `works` and `thumbnails` are public => RLS is
-- bypassed on /object/public/ reads. Takedown therefore requires
-- physically moving objects to the private `quarantine` bucket, not
-- just tightening policies. Enforced by the admin-moderate-work
-- Edge Function.
