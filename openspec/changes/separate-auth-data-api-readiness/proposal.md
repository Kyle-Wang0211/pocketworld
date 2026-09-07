# Change: Separate auth readiness from PostgREST readiness

## Why

Supabase can report a restored/refreshed authenticated session while PostgREST
briefly rejects that same JWT as issued in the future (`PGRST303`). Treating
those states as identical exposes a raw backend exception on the community home
screen and makes a manual Retry appear necessary.

## What changes

- Keep authentication state authoritative and unchanged.
- Add a shared Dart data-API readiness gate around the first feed request.
- Retry only the exact transient future-issued-JWT error with the same token;
  never mint another JWT to solve clock skew.
- Reset data readiness on token refresh or sign-out.
- Keep the feed loading during the bounded transient window and show stable
  product copy for persistent failures.
