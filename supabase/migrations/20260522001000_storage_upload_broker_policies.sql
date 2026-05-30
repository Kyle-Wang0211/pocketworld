-- Storage upload broker hardening.
--
-- Raw capture frames and auto-generated thumbnails now use short-lived
-- upload credentials minted by the storage-sign-upload Edge Function.
-- Clients keep select/delete permissions where product flows need them,
-- but they can no longer directly insert/update objects in brokered
-- buckets or create signed-upload URLs for arbitrary owned paths.

drop policy if exists "scans_insert_self" on storage.objects;
drop policy if exists "scans_update_self" on storage.objects;

drop policy if exists "thumbnails_insert_self" on storage.objects;
drop policy if exists "thumbnails_update_self" on storage.objects;
