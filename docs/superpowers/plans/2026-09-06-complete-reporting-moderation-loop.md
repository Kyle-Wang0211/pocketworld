# Complete Reporting and Moderation Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship and deploy a backward-compatible two-tier reporting pipeline with safe evidence, deterministic review priority, reporter-visible outcomes and least-privilege moderator access.

**Architecture:** Flutter keeps reporting behind `SocialProfileRepository`, while one authenticated `submit-report` Edge Function creates both work-linked and account reports. PostgreSQL owns invariant validation, priority and safe projections; dedicated functions expose reporter history and moderator actions. Existing legacy work inserts remain temporarily compatible because the production iPhone is not updated in this task.

**Tech Stack:** Flutter/Dart 3.13, Supabase/PostgreSQL RLS, Supabase Edge Functions/Deno, private Storage buckets, Flutter widget/contract tests, Deno tests, local HTML moderation console.

**Workspace:** Work in `/Users/kaidongwang/Developer/pocketworld` on the current complete dirty product tree. Modify only reporting, localization, settings, Supabase and moderation-console files. Never reset, clean, stage-all, install the production iPhone app or touch its data container.

---

### Task 1: Define the two-tier reporting domain

**Files:**
- Modify: `test/social_profile_models_test.dart`
- Modify: `lib/community/social_profile_models.dart`

- [ ] Add failing tests requiring `ReportKind.standard` with a 50-grapheme limit, `ReportKind.rights` with a 500-grapheme limit, fixed reason-to-kind mapping, evidence types, and safe report-history parsing.
- [ ] Run `flutter test test/social_profile_models_test.dart` and confirm failures are caused by missing domain behavior.
- [ ] Implement `ReportKind`, `ReportEvidenceKind`, reason metadata, tier-aware `UserReportDraft` validation and immutable `ReportHistoryItem`.
- [ ] Re-run the model test and require zero failures.

### Task 2: Move all client reporting behind one repository boundary

**Files:**
- Modify: `test/social_profile_repository_behavior_test.dart`
- Modify: `test/social_profile_repository_contract_test.dart`
- Modify: `lib/community/social_profile_repository.dart`

- [ ] Add failing tests requiring `submit-report`, `kind`, typed evidence, `fetchMyReports`, no direct `reports` insert, and durable-report behavior when evidence upload partially fails.
- [ ] Run both repository tests and confirm the new assertions fail.
- [ ] Change `reportUser` to call `submit-report`; add evidence kind to upload bodies and `fetchMyReports()` through `my-reports`.
- [ ] Re-run both repository tests and require zero failures.

### Task 3: Build the two-tier report UI and reporter history

**Files:**
- Modify: `test/user_report_page_test.dart`
- Create: `test/report_history_page_test.dart`
- Create: `lib/ui/community/report_history_page.dart`
- Modify: `lib/ui/community/user_report_page.dart`
- Modify: `lib/ui/community/work_detail_page.dart`
- Modify: `lib/ui/me_settings_page.dart`
- Modify: `pubspec.yaml`
- Modify: `pubspec.lock`
- Modify: `ios/Runner/Info.plist`
- Modify: `lib/l10n/app_zh.arb`
- Modify: `lib/l10n/app_en.arb`
- Regenerate: `lib/l10n/app_localizations*.dart`

- [ ] Add failing widget tests for the standard/rights chooser, 50/500 counters, reason filtering, three images, sensitive evidence suppression, work-source binding and report-history states.
- [ ] Add a failing source contract proving `WorkDetailPage` no longer owns the legacy `_ReportSheet` or calls `CommunityService.reportWork`.
- [ ] Run the focused widget/contract tests and confirm expected failures.
- [ ] Exact-pin `image_picker: 1.2.3`, add the iOS photo-library usage string, and implement the chooser and shared detail step through an injected picker boundary so tests remain independent of native plugins.
- [ ] Route work reporting to `UserReportPage(targetUserId, sourceWorkId)` and add “我的举报” to settings.
- [ ] Regenerate localizations and rerun focused tests.

### Task 4: Add backward-compatible database invariants

**Files:**
- Create: `supabase/migrations/20260906010000_complete_reporting_moderation_loop.sql`
- Create: `test/reporting_moderation_migration_contract_test.dart`

- [ ] Write a failing SQL contract for report kind, 50/500 limits, self-work rejection, source ownership, priority/due time, duplicate lookup index, typed evidence, reporter-safe RPC and moderator roles.
- [ ] Run the contract test and confirm it fails because the migration is absent.
- [ ] Add an append-only migration that backfills historical rows, creates deterministic triggers and safe RPCs, grants only necessary execution, and preserves legacy authenticated work inserts during the rollout window.
- [ ] Rerun the SQL contract and existing migration contracts.

### Task 5: Implement authenticated submission and safe reporter history

**Files:**
- Create: `supabase/functions/submit-report/index.ts`
- Create: `supabase/functions/submit-report/validate.ts`
- Create: `supabase/functions/submit-report/validate_test.ts`
- Modify: `supabase/functions/report-evidence-upload/index.ts`
- Create: `supabase/functions/my-reports/index.ts`
- Modify: `test/user_report_backend_contract_test.dart`

- [ ] Add failing Deno and Dart contracts for tier/reason validation, limits, target/source validation, 24-hour duplicate suppression, typed evidence and reporter-safe fields.
- [ ] Run them and confirm expected failures.
- [ ] Implement the server-owned submit pipeline by preserving the existing sensitive-source copy sequence and returning an existing pending report for duplicate submissions.
- [ ] Implement authenticated `my-reports` with a narrow safe projection and no internal notes, paths or moderator identity.
- [ ] Rerun Deno and Dart contracts.

### Task 6: Replace reviewer service-secret access

**Files:**
- Create: `supabase/functions/_shared/moderator_auth.ts`
- Create: `supabase/functions/_shared/moderator_auth_test.ts`
- Modify: `supabase/functions/admin-reports/index.ts`
- Modify: `tool/moderation_console.html`
- Create: `test/moderation_console_contract_test.dart`

- [ ] Add failing tests for individual moderator JWT authentication, role enforcement, priority queue sorting, public feedback/internal note separation, audit attribution and absence of service-secret fields in the console.
- [ ] Run focused tests and confirm expected failures.
- [ ] Implement moderator authorization through `moderator_accounts`; retain service-secret authorization only as an owner break-glass path in the server function, never in the console.
- [ ] Add list, claim, review, needs-info and resolve actions with state-transition checks.
- [ ] Update the console to sign in with project URL, public anon key, email and password and to send the resulting user JWT.
- [ ] Rerun focused tests and parse the console JavaScript with Node.

### Task 7: Verify and deploy production Supabase

**Files:**
- Modify: `openspec/changes/complete-reporting-moderation-loop/tasks.md`
- Modify: `supabase/README.md`

- [ ] Run focused and full reporting Flutter tests, Deno tests, OpenSpec validation and static analysis.
- [ ] Record the current linked project ref, local/remote migration lists and function versions; export a schema-only backup plus affected-table data backup without exposing contents in logs.
- [ ] Run `supabase db push --linked` and deploy `submit-report`, `my-reports`, `report-evidence-upload` and `admin-reports` with the repository's current verified CLI.
- [ ] Verify the new migration and function versions remotely.
- [ ] Exercise unauthenticated rejection and authenticated reporter/moderator smoke paths without creating abusive real-user content. If no dedicated test account credentials exist, record authenticated live smoke as blocked rather than use the owner's daily account.
- [ ] Mark OpenSpec tasks accurately and commit only files owned by this change.
