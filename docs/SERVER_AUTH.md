# Server-side Auth — Direct JWKS Verification of Supabase JWT

**Audience**: whoever maintains the API at `api.aether-3d.com`.

**Goal**: drop the existing `Bearer {apiKey}` static-token auth and verify
the client's Supabase session JWT directly via Supabase's public JWKS
endpoint. Zero shared secrets, zero Edge Function indirection, the
control plane learns the real Supabase user ID for every request.

This document is the patch the PocketWorld Flutter client expects on
the server. The Flutter side already sends
`Authorization: Bearer <supabase_jwt>` for every `/v1/mobile-jobs` and
`/v1/jobs/{id}` request — see `lib/upload/aether_api_client.dart` and
`lib/ui/capture/capture_page.dart::_uploader`.

---

## 1. Why JWKS direct verification

| Approach | Latency overhead | Trust model | Ship time |
|---|---|---|---|
| Edge Function token swap | +50–200 ms / req | Edge Fn holds master key, fan-in bottleneck | days |
| **JWKS direct (this doc)** | **0** | **Server verifies signature with Supabase's public key** | **hours** |
| OIDC federation | 0 | Standards-compliant, requires OIDC server | weeks |

For a polling-heavy workload (`GET /v1/jobs/{id}` once every few seconds
during reconstruction) the per-request overhead matters. JWKS direct
gives the same trust guarantees as the Edge Function path with no extra
hop.

## 2. Where Supabase publishes its JWKS

Every Supabase project exposes its JWT signing keys at:

```
https://<PROJECT_REF>.supabase.co/auth/v1/jwks
```

`PROJECT_REF` is the lowercase ID in the project's Supabase dashboard
URL. The PocketWorld client reads it from `--dart-define=SUPABASE_URL=...`
at build time (`lib/main.dart`); ask whoever runs the deployment for the
exact URL or pull it from `1Password / vault`.

Sample response (truncated):

```json
{
  "keys": [
    {
      "kty": "RSA",
      "kid": "abc123...",
      "n": "...",
      "e": "AQAB",
      "alg": "RS256",
      "use": "sig"
    }
  ]
}
```

Cache this for ~12 hours. Refresh on `kid` miss (rare — Supabase rolls
keys ~yearly).

## 3. Required Python deps (FastAPI version)

```toml
# pyproject.toml or requirements.txt — additions only
pyjwt[crypto] = ">=2.8.0"
httpx        = ">=0.27.0"
```

`pyjwt` does the actual JWT decode + RS256 signature check; `httpx`
fetches the JWKS over HTTP (any HTTP client works, this one's stdlib-
friendly).

## 4. Paste-ready middleware

```python
# app/auth/supabase_jwt.py
"""JWT-based auth middleware for the control plane.

Replaces the legacy `Bearer <static_api_key>` check. Each incoming
request must carry an Authorization header with a Supabase session JWT;
we verify the signature against Supabase's JWKS and inject the decoded
claims into request.state so route handlers can read user_id."""
from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Optional

import httpx
import jwt
from fastapi import HTTPException, Request, status
from jwt import PyJWKClient

# ─── Config ─────────────────────────────────────────────────────────────
# Set these via env in your deployment (do NOT commit real values).
import os
SUPABASE_PROJECT_URL = os.environ["SUPABASE_PROJECT_URL"]   # e.g. https://abcd.supabase.co
SUPABASE_JWT_AUDIENCE = os.environ.get("SUPABASE_JWT_AUDIENCE", "authenticated")
JWKS_CACHE_SECONDS    = int(os.environ.get("SUPABASE_JWKS_CACHE_SECONDS", "43200"))  # 12h
JWKS_URL              = f"{SUPABASE_PROJECT_URL.rstrip('/')}/auth/v1/jwks"

# PyJWKClient handles fetching + caching the JWKS for us. It also rolls
# over to a fresh fetch if we hit it with an unknown `kid`, which is
# Supabase's rotation behavior.
_jwk_client = PyJWKClient(JWKS_URL, cache_keys=True, lifespan=JWKS_CACHE_SECONDS)


@dataclass(frozen=True)
class AuthedUser:
    """Subset of the JWT claims the control plane actually uses."""
    user_id: str       # Supabase auth.users.id (UUID string)
    email: Optional[str]
    role: str          # usually "authenticated"
    raw_claims: dict   # full payload for handlers that need more


class AuthError(HTTPException):
    def __init__(self, code: str, detail: str | None = None):
        super().__init__(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"code": code, "detail": detail or code},
            headers={"WWW-Authenticate": "Bearer"},
        )


def verify_supabase_jwt(token: str) -> AuthedUser:
    """Validate a Supabase session JWT. Returns AuthedUser or raises
    AuthError. Pure function — call from wherever your framework hands
    you the raw bearer token (FastAPI dep, Flask before_request, ASGI
    middleware, etc.)."""
    try:
        signing_key = _jwk_client.get_signing_key_from_jwt(token).key
        payload = jwt.decode(
            token,
            signing_key,
            algorithms=["RS256", "ES256"],   # Supabase uses RS256; ES256 future-proofing
            audience=SUPABASE_JWT_AUDIENCE,  # default "authenticated"
            options={"require": ["exp", "iat", "sub"]},
        )
    except jwt.ExpiredSignatureError:
        raise AuthError("token_expired")
    except jwt.InvalidAudienceError:
        raise AuthError("bad_audience")
    except jwt.InvalidSignatureError:
        raise AuthError("bad_signature")
    except jwt.PyJWTError as e:
        raise AuthError("jwt_invalid", str(e))

    sub = payload.get("sub")
    if not sub:
        raise AuthError("missing_sub")

    return AuthedUser(
        user_id=sub,
        email=payload.get("email"),
        role=payload.get("role", "authenticated"),
        raw_claims=payload,
    )


# ─── FastAPI integration ───────────────────────────────────────────────
# Use this as a dependency on every protected route.
from fastapi import Depends, Header

async def require_user(
    authorization: str | None = Header(default=None, alias="Authorization"),
) -> AuthedUser:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise AuthError("missing_bearer")
    token = authorization[len("bearer "):].strip()
    return verify_supabase_jwt(token)


# Example route — replace your existing /v1/mobile-jobs handler with this:
#
#   from fastapi import APIRouter
#   router = APIRouter()
#
#   @router.post("/v1/mobile-jobs")
#   async def create_mobile_job(
#       body: CreateMobileJobRequest,
#       user: AuthedUser = Depends(require_user),
#   ):
#       # user.user_id is the Supabase auth.users.id — store this on the
#       # job record so worker_id can later filter by owner.
#       job = await broker.create_job(owner_id=user.user_id, **body.dict())
#       return job
```

For non-FastAPI servers (Flask / aiohttp / Django), call
`verify_supabase_jwt(token)` from your framework's
`before_request`/middleware hook and put the `AuthedUser` on the request
context.

## 5. Migration plan

The existing iOS Aether3D client also sends `Authorization: Bearer ...`
with a static API key. After this middleware ships, those requests will
fail with `401 token_expired` (or similar) because the static key isn't
a JWT.

Two options:

**(a) Hard cutover (recommended if iOS app is < 1k installs):**
Roll out the new middleware + ship updated iOS app on the same day.
Old clients fail loudly, get nudged to update.

**(b) Side-by-side (safer if you have committed users on the old app):**
Keep accepting the static API key for a transition period. Both checks
in the same dependency:

```python
async def require_user_or_legacy(
    authorization: str | None = Header(default=None, alias="Authorization"),
) -> AuthedUser:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise AuthError("missing_bearer")
    token = authorization[len("bearer "):].strip()
    # Legacy: static API key path. Set LEGACY_API_KEY in env; remove
    # this whole block once iOS rolls past version X.
    if token == os.environ.get("LEGACY_API_KEY"):
        return AuthedUser(
            user_id="legacy_ios_client",
            email=None,
            role="authenticated",
            raw_claims={"legacy": True},
        )
    return verify_supabase_jwt(token)
```

Drop the legacy block + env var when the old iOS app's install base is
below threshold.

## 6. Testing

```bash
# 1) Get a JWT — easiest way is from the Flutter app's debug log
#    (lib/main.dart prints it on auth state change), or the Supabase
#    dashboard > Authentication > Users > pick a user > "Generate JWT".

JWT=eyJhbGc...

# 2) Hit the API — should now succeed
curl -i https://api.aether-3d.com/v1/jobs/test-job-123 \
  -H "Authorization: Bearer $JWT"

# Expected: 404 (job doesn't exist) — this means auth PASSED.
# Without the header you'd get 401 missing_bearer; with a bad JWT,
# 401 bad_signature.

# 3) Check user identity propagates: create a job, verify the job's
#    owner_id matches your Supabase user UUID.
```

## 7. Rollback

If the middleware ships and breaks production:

```python
# Temporary kill switch — set DISABLE_JWT_AUTH=1 in env
if os.environ.get("DISABLE_JWT_AUTH") == "1":
    return AuthedUser(user_id="anonymous", email=None, role="anon", raw_claims={})
```

Don't leave this in past the same-day fix.

## 8. Open issues / future work

- **Token refresh**: Supabase tokens are short-lived (~1 hour). Flutter's
  `supabase_flutter` auto-refreshes silently; long-running uploads
  (multi-minute) might span a refresh boundary. v2 client work: for
  uploads > 30 minutes, re-fetch the token before each presigned-URL
  PUT. (Not an issue for typical < 50 MB scans.)
- **Custom claims**: Once you want server-side enforcement of plan
  tier / quota, register a Supabase
  [`access_token_hook`](https://supabase.com/docs/guides/auth/auth-hooks/custom-access-token-hook)
  to embed `aether_quota_remaining` etc. directly in the JWT, then
  read from `user.raw_claims` here.
- **Worker-side identity**: The worker (vast.ai sidecar) currently auths
  to the broker via worker registration token, which is unrelated to
  this user JWT and stays as-is.
