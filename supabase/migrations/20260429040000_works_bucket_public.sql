-- Flip the works bucket from private to public so model_viewer_plus
-- (and any other client SDK that can't easily attach an Authorization
-- header) can fetch .glb files via a plain URL.
--
-- Why this is safe:
--   • The works TABLE has RLS that filters by visibility — private
--     works are never returned by the feed query, so their storage
--     paths are never exposed to clients.
--   • The only way to access a private work's .glb is to know its
--     storage path, which is `{user_id}/{filename}`. Brute-force
--     guessing requires the owner's user_id (a UUID) AND the original
--     filename — combinatorially infeasible.
--   • Polycam / Sketchfab / Smithsonian 3D etc. all use the same
--     public-bucket model.
--
-- If a user later marks a previously-public work as private, the .glb
-- file remains accessible if its URL is leaked. Future hardening: move
-- to signed URLs with short expiry. v1 trades that vs. shipping speed.

update storage.buckets set public = true where id = 'works';
