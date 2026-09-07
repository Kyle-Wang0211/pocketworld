# Tasks

- [x] Add failing Flutter model and widget tests for report tiers, evidence and history.
- [x] Add failing SQL and Deno contract tests for submission, priority and reporter-safe history.
- [x] Implement the reporting domain model and repository boundary.
- [x] Implement the unified work/profile report UI and system photo picker.
- [x] Implement report history and public-result feedback UI.
- [x] Add the backward-compatible reporting schema migration.
- [x] Implement unified submission, evidence and reporter-history functions.
- [x] Implement moderator roles and least-privilege moderation functions.
- [x] Update the moderation console to authenticate reviewers without a service secret.
- [x] Run Flutter, Deno, SQL and static verification.
- [x] Back up affected production Supabase state and deploy migrations/functions.
- [ ] Run production smoke tests with dedicated test accounts and record evidence. Blocked on a dedicated non-owner account; unauthenticated 401, schema, role and deployment smokes passed without creating content in the owner's daily account.
