# Alignment Telemetry Stage Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent preview no-ops from being reported as final gravity/scale alignment failures.

**Architecture:** Give every snapshot an explicit stage. Preview returns unchanged after one intentional `preview_skip`; delivery snapshots run the existing transforms and emit one complete `final_alignment_result` whose authority is encoded in the record.

**Tech Stack:** Dart, Flutter test, existing `TelemetryWriter`, OpenSpec.

---

### Task 1: Lock the stage-specific event contract

**Files:**
- Modify: `test/gravity_skip_diagnostics_test.dart`

- [ ] **Step 1: Replace the ambiguous source contract with failing expectations**

Require `preview_skip`, `already_arkit_gravity_metric`,
`final_alignment_result`, both authority values, and the absence of calls that
emit `gravity_skip` or `scale_anchor_skip`.

- [ ] **Step 2: Run the focused test and verify RED**

Run:

```sh
flutter test --no-pub test/gravity_skip_diagnostics_test.dart
```

Expected: FAIL because `preview_skip` and `final_alignment_result` do not yet
exist in `sfm_live_recon.dart`.

### Task 2: Add explicit stage identity and telemetry

**Files:**
- Modify: `lib/official_capture/sfm_live_recon.dart`

- [ ] **Step 1: Add a private stage enum**

```dart
enum _AlignmentSnapshotStage { preview, localReady, refined }
```

Pass the appropriate value from the `preview`, `local_ready`, and `refined`
message handlers into `_gravityAlign`.

- [ ] **Step 2: Implement the preview no-op record**

At the start of `_gravityAlign`, emit `preview_skip` with schema version 1,
`reason=already_arkit_gravity_metric`, and both statuses `not_required`, then
return the original snapshot.

- [ ] **Step 3: Implement the delivery result record**

Run the existing gravity and scale functions unchanged. Emit exactly one
`final_alignment_result` for both success and fail-open outcomes. Record phase,
authority, statuses, reasons, quaternion, scale factor, counts, metadata size,
and point count. Use `authoritative` for refined and `fallback_candidate` for
local-ready.

- [ ] **Step 4: Remove ambiguous event emissions**

Remove calls that emit `gravity_skip` and `scale_anchor_skip`; retain their
diagnostic fields inside the final-result record.

- [ ] **Step 5: Run the focused test and verify GREEN**

```sh
flutter test --no-pub test/gravity_skip_diagnostics_test.dart
```

Expected: all tests pass.

### Task 3: Regression verification

**Files:**
- Verify only; no additional production files.

- [ ] **Step 1: Run gravity mathematics checks**

```sh
dart run tool/gravity_align_check.dart
```

Expected: all checks pass.

- [ ] **Step 2: Run focused analyzer**

```sh
flutter analyze --no-pub \
  lib/official_capture/gravity_align.dart \
  lib/official_capture/sfm_live_recon.dart \
  test/gravity_skip_diagnostics_test.dart
```

Expected: no issues.

- [ ] **Step 3: Inspect the diff**

```sh
git diff --check
git diff -- lib/official_capture/sfm_live_recon.dart \
  test/gravity_skip_diagnostics_test.dart \
  openspec/changes/split-alignment-telemetry-v1 \
  docs/superpowers
```

Expected: telemetry and tests only; no gravity/scale math or product output
changes.
