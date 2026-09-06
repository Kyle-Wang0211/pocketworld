# Design

The detailed approved design is recorded in `docs/superpowers/specs/2026-09-06-complete-reporting-moderation-loop-design.md`.

The central decision is to make the server the only report creator. Flutter supplies intent and evidence, while PostgreSQL and Edge Functions derive identity, validate target relationships, assign queue priority and expose separate reporter and moderator projections. A repository interface contains current Supabase-specific calls so a future Alibaba Cloud adapter can replace authentication, storage and function transport without changing pages or report policy.

Deployment remains backward compatible with installed clients. Legacy reason codes are normalized server-side, old work inserts remain accepted during the rollout window, and direct authenticated inserts are revoked only after the compatibility function is live and verified.
