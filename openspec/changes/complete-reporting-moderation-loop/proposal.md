# Change: Complete reporting and moderation loop

## Why

PocketWorld currently has two inconsistent reporting paths. Work reports bypass the authenticated Edge Function and cannot attach evidence, while account reports allow 500 characters for every reason and have no user-visible result history. The moderation console also requires a service-role secret, which is unsafe for outsourced reviewers.

## What Changes

- Introduce separate standard reports (50 characters) and rights complaints (500 characters).
- Route work and account reporting through one authenticated server-owned pipeline.
- Add source validation, self-report rejection, rate limiting, duplicate suppression, deterministic priority and due times.
- Add private evidence metadata, sensitive source preservation and safe report history.
- Replace service-role-secret reviewer access with role-bound moderator authentication.
- Keep the client behind a repository boundary for future Alibaba Cloud migration.

## Impact

- Affected spec: `social-reporting-moderation`
- Affected clients: Flutter community work/profile/settings UI
- Affected backend: PostgreSQL migrations, report submission/evidence/admin Edge Functions
- Affected operations: moderation console and production Supabase deployment
