# Profile, Following, Reporting, and Blocking Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver author profiles, follow/unfollow, My Following, user reporting with optional private evidence, and enforceable first-party blocking, then verify and install through the production-device preservation runbook.

**Architecture:** A new `SocialProfileRepository` isolates Supabase reads/writes from Flutter pages. `VaultPage` navigates to `UserProfilePage`; Me embeds the same social summary and opens `FollowingListPage`. SQL migrations own count/block invariants, while the existing upload broker and admin-reports function are extended for private report evidence and account-target review.

**Tech Stack:** Flutter/Dart 3.13, Supabase/Postgres RLS, Supabase Edge Functions/Deno, `file_picker` 8.3.7, existing `image` package, Flutter widget tests, Deno tests, iOS Release build.

**Workspace rule:** Work in the current feature branch and preserve the full dirty product tree. Do not reset, clean, stage-all, commit, or touch capture/VIO/algorithm files. The user did not request commits.

---

### Task 1: Turn the old author-filter contract into the new profile-navigation contract

**Files:**
- Modify: `test/community_home_restructure_test.dart`
- Modify: `lib/ui/vault_page.dart`

- [ ] **Step 1: Write the failing contract test**

Replace the D7 reverse assertion with assertions that require the route and forbid the filter state:

```dart
test('D7:点作者进入个人主页', () {
  expect(code, contains('UserProfilePage('));
  expect(code, contains('userId: work.userId'));
  expect(code, isNot(contains('_authorFilterId = work.userId')));
  expect(code, isNot(contains('_AuthorFilterBar(')));
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/community_home_restructure_test.dart`

Expected: FAIL because `UserProfilePage` is not yet referenced and the old author filter remains.

- [ ] **Step 3: Implement the minimal navigation**

Import `community/user_profile_page.dart`, push `UserProfilePage(userId: work.userId, seedWork: work)`, remove author-filter state/rendering, and keep all search/topic-card behavior unchanged.

- [ ] **Step 4: Verify GREEN**

Run: `flutter test test/community_home_restructure_test.dart`

Expected: all tests pass.

### Task 2: Add immutable social models and a testable repository

**Files:**
- Create: `lib/community/social_profile_models.dart`
- Create: `lib/community/social_profile_repository.dart`
- Create: `test/social_profile_models_test.dart`
- Create: `test/social_profile_repository_contract_test.dart`

- [ ] **Step 1: Write failing model tests**

Cover null handles, integer coercion, public work count, report reason codes, sensitive-evidence policy, 500-character detail validation, and three-image limit.

```dart
test('minor sexual reports disable user-supplied evidence', () {
  expect(UserReportReason.minorSafety.allowsEvidenceUpload, isFalse);
  expect(UserReportReason.sexualContent.allowsEvidenceUpload, isFalse);
});
```

- [ ] **Step 2: Verify RED**

Run: `flutter test test/social_profile_models_test.dart`

Expected: FAIL because the models do not exist.

- [ ] **Step 3: Implement models and repository interface**

The public interface must be exactly:

```dart
abstract interface class SocialProfileRepository {
  String? get currentUserId;
  Future<SocialProfile> fetchProfile(String userId);
  Future<List<SocialProfile>> fetchFollowing(String userId);
  Future<void> follow(String userId);
  Future<void> unfollow(String userId);
  Future<void> block(String userId);
  Future<void> unblock(String userId);
  Future<List<SocialProfile>> fetchBlockedUsers();
  Future<UserReportResult> reportUser(UserReportDraft draft);
}
```

Implement `SupabaseSocialProfileRepository` with explicit profile fields. `fetchFollowing` calls the narrow `get_my_following` RPC so private profiles already followed remain visible without a one-request-per-row pattern or a broad profile-policy relaxation.

- [ ] **Step 4: Add source-contract tests for query invariants**

Require both-direction block-aware follow errors to remain surfaced, require `target_type: user`, and require `detail` trimming before insert.

- [ ] **Step 5: Verify GREEN**

Run: `flutter test test/social_profile_models_test.dart test/social_profile_repository_contract_test.dart`

Expected: all tests pass.

### Task 3: Harden the database and redefine works_count

**Files:**
- Create: `supabase/migrations/20260829010000_social_profile_follow_safety.sql`
- Create: `test/social_profile_migration_contract_test.dart`

- [ ] **Step 1: Write the failing migration contract**

Assert the migration drops/recreates the follow insert policy, checks blocks in both directions, adds authenticated-only `get_my_following` with fixed caller identity and bounded pagination, backfills published/public/moderation-`ok`/non-deleted counts, and handles work insert/delete/update transitions.

- [ ] **Step 2: Verify RED**

Run: `flutter test test/social_profile_migration_contract_test.dart`

Expected: FAIL because the migration is absent.

- [ ] **Step 3: Implement the migration**

The new follow policy must reject either block direction. Replace `bump_profile_works_count` so its delta is computed from:

```sql
(published_at is not null and visibility = 'public' and moderation_status = 'ok' and deleted_at is null)
```

Backfill every profile using an aggregate over works before replacing the triggers.

- [ ] **Step 4: Verify GREEN and lint SQL**

Run: `flutter test test/social_profile_migration_contract_test.dart`

Run when the local Supabase stack is available: `supabase db lint --local --level warning`

Expected: contract passes; SQL lint reports no new errors. If no local stack is running, record that as an unavailable check rather than pretending it passed.

### Task 4: Build and test the approved user profile

**Files:**
- Create: `lib/ui/community/user_profile_page.dart`
- Create: `lib/ui/community/profile_work_grid.dart`
- Create: `test/user_profile_page_test.dart`
- Modify: `lib/l10n/app_zh.arb`
- Modify: `lib/l10n/app_en.arb`

- [ ] **Step 1: Write failing widget tests**

Use an in-memory `FakeSocialProfileRepository` and assert:

```dart
expect(find.text('@lin.mo · 上海'), findsOneWidget);
expect(find.text('公开作品'), findsNothing);
expect(find.text('关注'), findsOneWidget);
expect(find.byKey(const Key('profile-overflow')), findsOneWidget);
```

Also assert the back row contains no handle/name and that tapping follow updates the button and counts after the fake completes.

- [ ] **Step 2: Verify RED**

Run: `flutter test test/user_profile_page_test.dart`

Expected: FAIL because the page is absent.

- [ ] **Step 3: Implement the page**

Use a small `PopupMenuButton` anchored in the top-right. The direct grid starts after the counts row with no heading. Load only the selected user's public works through the existing `CommunityService`, and route grid taps to `WorkDetailPage`.

- [ ] **Step 4: Verify GREEN**

Run: `flutter test test/user_profile_page_test.dart test/community_home_restructure_test.dart`

Expected: all tests pass.

### Task 5: Add Me social summary and My Following

**Files:**
- Create: `lib/ui/community/following_list_page.dart`
- Create: `test/following_list_page_test.dart`
- Modify: `lib/ui/me_page.dart`
- Create: `test/me_social_summary_contract_test.dart`

- [ ] **Step 1: Write failing tests**

Require the Me page to fetch the signed-in profile, render works/followers/following, open “我的关注”, show an empty state, navigate from a row, and allow unfollow without removing unrelated rows.

- [ ] **Step 2: Verify RED**

Run: `flutter test test/following_list_page_test.dart test/me_social_summary_contract_test.dart`

Expected: FAIL because the summary/list do not exist.

- [ ] **Step 3: Implement summary and list**

Inject a repository into `MePage` with a production default. Keep the current local scan grid intact below the social header. Use stable product error copy and retry controls.

- [ ] **Step 4: Verify GREEN**

Run: `flutter test test/following_list_page_test.dart test/me_social_summary_contract_test.dart`

Expected: all tests pass.

### Task 6: Add the approved user-report flow and evidence sanitization

**Files:**
- Modify: `pubspec.yaml`
- Modify: `pubspec.lock`
- Create: `lib/community/report_evidence_processor.dart`
- Create: `lib/ui/community/user_report_page.dart`
- Create: `test/report_evidence_processor_test.dart`
- Create: `test/user_report_page_test.dart`
- Modify: `lib/l10n/app_zh.arb`
- Modify: `lib/l10n/app_en.arb`

- [ ] **Step 1: Exact-pin the previously resolved picker offline**

Add `file_picker: 8.3.7`, then run `flutter pub get --offline`.

Expected: lock resolves to 8.3.7 without network access.

- [ ] **Step 2: Write failing evidence tests**

Generate fixture images with EXIF-like metadata, overlong dimensions, and invalid bytes. Require re-encoding, maximum 2048 dimension, supported JPEG/PNG output, 5 MiB cap, three-file cap, and fail-closed invalid decoding.

- [ ] **Step 3: Verify RED**

Run: `flutter test test/report_evidence_processor_test.dart test/user_report_page_test.dart`

Expected: FAIL because the processor/page are absent.

- [ ] **Step 4: Implement processor and two-step report UI**

Render nine reasons on the first screen. The second screen renders a 500-character field, source-work chip when present, conditional picker, up to three removable previews, and a submit button. Sensitive reasons never invoke the picker.

- [ ] **Step 5: Verify GREEN**

Run: `flutter test test/report_evidence_processor_test.dart test/user_report_page_test.dart`

Expected: all tests pass.

### Task 7: Add private evidence storage and manual-review support

**Files:**
- Create: `supabase/migrations/20260829020000_user_report_evidence.sql`
- Create: `supabase/functions/report-evidence-upload/validate.ts`
- Create: `supabase/functions/report-evidence-upload/validate_test.ts`
- Create: `supabase/functions/report-evidence-upload/index.ts`
- Modify: `supabase/functions/admin-reports/index.ts`
- Modify: `tool/moderation_console.html`
- Create: `test/user_report_backend_contract_test.dart`

- [ ] **Step 1: Write failing Deno and repository contract tests**

Require caller-owned pending user report, bounded base64 input, decoded JPG/PNG magic, safe dimensions, absence of JPEG APP1/APP13 and PNG metadata chunks, 5 MiB per file, maximum three objects, server-generated paths, private bucket creation, user-target resolution, 5-minute signed URLs, and auditable resolution.

- [ ] **Step 2: Verify RED**

Run: `deno test supabase/functions/report-evidence-upload/validate_test.ts`

Run: `flutter test test/user_report_backend_contract_test.dart`

Expected: both fail because the evidence backend does not exist.

- [ ] **Step 3: Implement migration, broker validation, and admin attachment**

Create private bucket `report-evidence`, `report_evidence` metadata table, own-report RLS, and cascade deletion. Add an authenticated upload function that validates bytes and metadata server-side, generates random paths, writes the object, and inserts metadata. Extend `admin-reports` to resolve profile targets and produce short-lived evidence URLs. Update the console to show user identity, reason, detail, source work, image previews, and review/dismiss/actioned controls with required notes.

- [ ] **Step 4: Verify GREEN**

Run the two commands from Step 2.

Expected: all tests pass.

### Task 8: Add blocked-user management and enforce consistent UI semantics

**Files:**
- Create: `lib/ui/community/blocked_users_page.dart`
- Create: `test/blocked_users_page_test.dart`
- Modify: `lib/ui/me_settings_page.dart`
- Modify: `lib/community/community_service.dart`
- Modify: `test/feed_block_filter_test.dart`

- [ ] **Step 1: Write failing tests**

Require “已拉黑用户” in settings, unblock without refollow, both-direction feed suppression, and explicit copy limiting the guarantee to the current signed-in account.

- [ ] **Step 2: Verify RED**

Run: `flutter test test/blocked_users_page_test.dart test/feed_block_filter_test.dart`

Expected: FAIL because management and both-direction filtering are absent.

- [ ] **Step 3: Implement management and filtering**

Fetch both blocked-by-me and has-blocked-me identities for first-party suppression without exposing the latter in the UI. Keep unblock limited to rows owned by the current blocker.

- [ ] **Step 4: Verify GREEN**

Run the command from Step 2.

Expected: all tests pass.

### Task 9: Integrated verification, review, and production-device update

**Files:**
- Modify only files required by verified review findings.
- Create build/backup artifacts only under `/private/tmp` and the approved device-backup location.

- [ ] **Step 1: Format and run targeted checks**

Run:

```bash
dart format --output=none --set-exit-if-changed \
  lib/community lib/ui/community test
flutter test \
  test/community_home_restructure_test.dart \
  test/social_profile_models_test.dart \
  test/social_profile_repository_contract_test.dart \
  test/social_profile_migration_contract_test.dart \
  test/user_profile_page_test.dart \
  test/following_list_page_test.dart \
  test/me_social_summary_contract_test.dart \
  test/report_evidence_processor_test.dart \
  test/user_report_page_test.dart \
  test/user_report_backend_contract_test.dart \
  test/blocked_users_page_test.dart \
  test/feed_block_filter_test.dart
flutter analyze lib/community lib/ui/community lib/ui/me_page.dart lib/ui/me_settings_page.dart
deno test supabase/functions/report-evidence-upload/validate_test.ts
```

Expected: exit 0 with zero test failures and zero analyzer errors.

- [ ] **Step 2: Browser-test the approved flows**

Verify author navigation, follow/unfollow, My Following, anchored menu, nine reasons, text counter, normal image picker state, sensitive no-upload state, block confirmation, and unblock list. Capture screenshots for the evidence bundle.

- [ ] **Step 3: Run independent spec and code-quality review**

Give the reviewer the approved spec, current diff, commands, and outputs without persuasive history. Fix every important finding through a failing test first and re-review.

- [ ] **Step 4: Freeze build identity and build iOS Release**

Record HEAD plus a content manifest covering tracked, staged, modified, and relevant untracked product source. Build with the already pinned toolchain, task-specific `XDG_CONFIG_HOME`, output under `/private/tmp`, and `--no-pub`. Verify bundle ID `com.kyle.PocketWorld`, deep signature, runtime marker, and the required app identity.

- [ ] **Step 5: Back up and install without uninstalling**

In one normal macOS Terminal window, copy `Documents` and `Library` separately from the app-data-container, hash every file, and verify the backup. Install only with `devicectl device install app`; never run uninstall, reinstall, `flutter drive`, or a different bundle identifier.

- [ ] **Step 6: Post-install integrity verification**

Copy `Documents` and `Library` back from the phone and byte-compare every pre-existing file, excluding only `Library/SplashBoard/Snapshots/**`. Launch and manually verify the social flows. Report completion only after the terminal emits `UPDATE_COMPLETE` and all identity checks pass.
