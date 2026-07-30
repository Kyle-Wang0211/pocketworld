# Official Archive Background Processing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Do not dispatch subagents for this plan because the user explicitly requires single-agent execution.

**Goal:** Make the existing official JPEG XL/ZPAQ cold archive queue resumable through iOS `BGProcessingTask`, with durable audit state and no reduction in full byte-exact photo retention.

**Architecture:** Compatible policy markers plus unfinished source/archive/manifest state remain the only durable queue authority. Dart retains all archive policy and transaction ownership; a dedicated Swift bridge only schedules and owns the iOS background task lifetime. A JSONL journal plus atomic JSON snapshot exposes progress without participating in deletion authorization.

**Tech Stack:** Dart/Flutter, `MethodChannel`, iOS BackgroundTasks/Swift, libjxl 0.12.0 effort 10, ZPAQ 7.15 method 5, Flutter tests, OpenSpec.

---

### Task 1: Durable audit store

**Files:**
- Create: `lib/official_capture/archive_audit_store.dart`
- Create: `test/archive_audit_store_test.dart`
- Modify: `openspec/changes/add-official-archive-background-processing/tasks.md`

- [ ] **Step 1: Write the failing audit persistence tests**

Test a real temporary Documents directory. Record two events, assert two valid
JSONL rows, assert `official_archive_status.json` contains the latest global
and per-capture event, then construct a second store and prove it preserves
previous capture state.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```bash
flutter test --no-pub test/archive_audit_store_test.dart
```

Expected: compilation failure because `OfficialArchiveAuditStore` does not yet
exist.

- [ ] **Step 3: Implement the minimal filesystem-backed store**

Define immutable `ArchiveAuditEvent` values with schema, UTC timestamp, event,
trigger, optional capture ID, and JSON-safe details. Serialize writes through
one future chain, append each event with `flush: true`, load the existing status
snapshot once, and atomically replace the status file through a sibling `.tmp`.

- [ ] **Step 4: Run the focused test and verify GREEN**

Run the command from Step 2. Expected: all audit tests pass and no temporary
status file remains.

### Task 2: Coordinator background contract

**Files:**
- Create: `lib/official_capture/archive_background_scheduler.dart`
- Modify: `lib/official_capture/photo_archive_coordinator.dart`
- Modify: `test/photo_archive_coordinator_test.dart`
- Modify: `openspec/changes/add-official-archive-background-processing/tasks.md`

- [ ] **Step 1: Write failing scheduling and interruption tests**

Add tests proving:

```dart
await coordinator.noteArtifactsPersisted(capture);
expect(scheduler.scheduleCount, 1);
expect(scheduler.cancelCount, 1); // drained
```

and a two-photo test whose first encode calls
`coordinator.requestSystemInterruption()`. Assert the first JPEG is committed,
the second original remains, `hasPendingWork` is true, and a later discovery
archives the second JPEG exactly.

- [ ] **Step 2: Run the coordinator test and verify RED**

```bash
flutter test --no-pub test/photo_archive_coordinator_test.dart
```

Expected: failures for the missing scheduler port, interruption method, and
pending-work result.

- [ ] **Step 3: Implement scheduler injection and interruption generations**

Add an `ArchiveBackgroundScheduler` interface with no-op default. Schedule
before pumping newly completed work. Capture the current interruption
generation per pump and include it in every JPEG next-file and ZPAQ continuation
gate. Increment the generation and request ZPAQ cancellation on system
expiration. Cancel the queued system request only after the in-memory queue
drains.

- [ ] **Step 4: Verify GREEN**

Run the command from Step 2. Expected: all existing and new coordinator tests
pass.

- [ ] **Step 5: Add RED tests for failed-work retry**

Use a codec that fails its first encode and succeeds later. Assert the first
pump stops without deleting the JPEG, reports pending work, and does not retry
inside the same pump; a later discovery succeeds.

- [ ] **Step 6: Implement one-opportunity retry semantics and audit events**

Requeue and stop on failed/interrupted photo or database results. Do not requeue
intentional non-smaller skips. Record enqueue, scan, capture start/result,
interruption, retry, and drain through the injected real audit store; suppress
audit I/O errors without altering transaction decisions.

- [ ] **Step 7: Verify GREEN**

Run the coordinator and audit tests together:

```bash
flutter test --no-pub test/archive_audit_store_test.dart test/photo_archive_coordinator_test.dart
```

Expected: all tests pass.

### Task 3: Dart MethodChannel background entry

**Files:**
- Create: `lib/official_capture/archive_background_runtime.dart`
- Create: `test/archive_background_runtime_test.dart`
- Modify: `lib/official_capture/photo_archive_runtime.dart`
- Modify: `lib/main.dart`
- Modify: `test/photo_archive_lifecycle_contract_test.dart`
- Modify: `openspec/changes/add-official-archive-background-processing/tasks.md`

- [ ] **Step 1: Write failing runtime tests**

Use Flutter’s test binary messenger at the platform boundary. Assert
`initialize()` installs the Dart handler before invoking native `ready`; native
`runColdArchive` discovers a real marked temporary capture and returns
`success` plus `workRemaining`; native `cancelColdArchive` interrupts the
coordinator without deleting an uncommitted original.

- [ ] **Step 2: Verify RED**

```bash
flutter test --no-pub test/archive_background_runtime_test.dart test/photo_archive_lifecycle_contract_test.dart
```

Expected: compilation/contract failures because the runtime and startup wiring
do not exist.

- [ ] **Step 3: Implement the Dart controller and scheduler adapter**

Use channel `pocketworld_official_archive_background`. Dart-to-native methods
are `ready`, `schedule`, and `cancelScheduled`. Native-to-Dart methods are
`runColdArchive` and `cancelColdArchive`. Resolve Documents lazily, reuse the
global official coordinator, and return only JSON-safe result maps.

- [ ] **Step 4: Initialize before startup discovery and verify GREEN**

Await runtime initialization after Flutter binding initialization. Keep normal
post-frame discovery. Run the Step 2 command; expected: all tests pass.

### Task 4: Native BGProcessingTask bridge

**Files:**
- Create: `ios/Runner/OfficialArchiveBackgroundTask.swift`
- Modify: `ios/Runner/AppDelegate.swift`
- Modify: `ios/Runner/Info.plist`
- Modify: `ios/Runner.xcodeproj/project.pbxproj`
- Create: `test/archive_background_ios_contract_test.dart`
- Modify: `openspec/changes/add-official-archive-background-processing/tasks.md`

- [ ] **Step 1: Write the failing native contract test**

Assert the source and project contain:

```text
com.kyle.PocketWorld.official.archive
BGProcessingTaskRequest
requiresExternalPower = false
requiresNetworkConnectivity = false
task.expirationHandler
runColdArchive
cancelColdArchive
setTaskCompleted
OfficialArchiveBackgroundTask.shared.register
OfficialArchiveBackgroundTask.swift in Sources
```

Also assert the task identifier is present in
`BGTaskSchedulerPermittedIdentifiers`.

- [ ] **Step 2: Verify RED**

```bash
flutter test --no-pub test/archive_background_ios_contract_test.dart
```

Expected: failure because the Swift bridge and identifier do not exist.

- [ ] **Step 3: Implement minimal Swift scheduling**

Register the handler before `didFinishLaunching` returns. Hold a task that
arrives before Dart `ready`. Submit one no-network/no-power request on
`schedule`. Invoke `runColdArchive` when both the task and Dart are ready.
Expiration invokes `cancelColdArchive`; the run result controls completion and
resubmission when `workRemaining` is true.

- [ ] **Step 4: Add Xcode membership and verify GREEN**

Add the new Swift file to the Runner group and Sources phase, add the permitted
identifier, then run the Step 2 command. Expected: all contract tests pass.

### Task 5: Repository verification and in-place device update

**Files:**
- Modify only task files listed above.

- [ ] **Step 1: Format only owned Dart paths**

```bash
dart format \
  lib/official_capture/archive_audit_store.dart \
  lib/official_capture/archive_background_scheduler.dart \
  lib/official_capture/archive_background_runtime.dart \
  lib/official_capture/photo_archive_coordinator.dart \
  lib/official_capture/photo_archive_runtime.dart \
  lib/main.dart \
  test/archive_audit_store_test.dart \
  test/archive_background_runtime_test.dart \
  test/archive_background_ios_contract_test.dart \
  test/photo_archive_coordinator_test.dart \
  test/photo_archive_lifecycle_contract_test.dart
```

- [ ] **Step 2: Run focused and full verification**

```bash
flutter test --no-pub \
  test/archive_audit_store_test.dart \
  test/archive_background_runtime_test.dart \
  test/archive_background_ios_contract_test.dart \
  test/photo_archive_coordinator_test.dart \
  test/photo_archive_lifecycle_contract_test.dart \
  test/photo_archive_transaction_test.dart \
  test/database_archive_transaction_test.dart
flutter analyze --no-pub lib/ test/
flutter test --no-pub
openspec validate add-official-archive-background-processing --strict
```

Expected: focused/full tests pass; analyzer remains at exactly the current
12-warning legacy baseline with no new diagnostic in owned files; OpenSpec is
strict-valid.

- [ ] **Step 3: Inspect and commit only owned files**

Use explicit `git add` paths only. Never use `git add -A`, `git add -u`,
`commit -a`, stash, reset, checkout, or repository-wide formatting. Declare in
the commit message that Swift/Xcode native scheduling changed but no `.a`
rebuild is required.

- [ ] **Step 4: Reconcile remote and build**

Fetch origin, compare `origin/main` and `HEAD`, integrate without touching
others’ dirty work, then build signed Release with the pinned SDK and
`--no-pub`. Verify the exact bundle ID, deep signature, background identifier,
existing JXL/ZPAQ ABI symbols, and build marker.

- [ ] **Step 5: Back up, update in place, and audit preservation**

Copy Documents and Library separately through the app-data-container domain,
hash every file, and verify the backup before install. Install only with
`devicectl device install app`; never uninstall. Launch with
`--terminate-existing`, copy Documents/Library back, and prove every
pre-existing file remains byte-identical except allowed SplashBoard snapshots.
Report `UPDATE_COMPLETE` and installed HEAD.
