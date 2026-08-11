# Live-cloud Drift Diagnostics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add four observation-only diagnostics that identify live-cloud drift causes, then safely update the existing production iPhone app without losing its data container.

**Architecture:** Swift persists ARKit anchor and actual SceneKit consumption; Dart assigns cross-boundary cloud generations; the Aether C++ core compares optimized and immutable ARKit camera centers. Signed app metadata and per-layer contract constants provide runtime identity, while the deployment ledger supplies binary hashes.

**Tech Stack:** Flutter/Dart, Swift/ARKit/SceneKit, C++17/COLMAP, JSONL telemetry, Xcode/devicectl.

---

### Task 1: Freeze and specify the change

**Files:**
- Create: `openspec/changes/add-live-cloud-drift-diagnostics-v1/*`
- Create: `docs/superpowers/specs/2026-08-10-live-cloud-drift-diagnostics-design.md`

- [ ] Record product HEAD, tracked/untracked content digests, target-file hashes,
      Aether HEAD/source hashes, Flutter/Xcode versions, and available disk.
- [ ] Verify the OpenSpec non-goals prohibit every reconstruction/display change.

### Task 2: Write failing diagnostic contract tests

**Files:**
- Create: `test/live_cloud_drift_diagnostics_test.dart`
- Modify: `ios/RunnerTests/RunnerTests.swift`
- Create or modify: `aether_cpp/official_pipeline/tests/live_cloud_diagnostics_v1_test.cc`

- [ ] Test the exact 0.05 m and 0.10 m severity boundaries.
- [ ] Test monotonic receive generations and stale-completion observation.
- [ ] Test component-wise median and p50/p90/max BA camera-center summaries.
- [ ] Add source-boundary assertions that generation metadata reaches Swift
      render consumption and all three build identities are present.
- [ ] Run each focused test and retain the expected missing-feature failure.

### Task 3: Implement Dart receive/send diagnostics

**Files:**
- Create: `lib/official_capture/live_cloud_diagnostics.dart`
- Modify: `lib/ui/official_capture/ar_capture_page.dart`

- [ ] Add a pure generation/identity helper sufficient for the failing Dart tests.
- [ ] Assign a generation before progressive ordering and log receive/completion.
- [ ] Add source/version/generation/count to `setCoveragePointCloud` without
      changing the chosen buffers or call ordering.
- [ ] Run the focused Dart test and confirm it passes.

### Task 4: Implement Swift anchor/render diagnostics

**Files:**
- Modify: `ios/Runner/OfficialAetherARKitPlugin.swift`
- Modify: `ios/Runner/Info.plist`
- Modify: `ios/RunnerTests/RunnerTests.swift`

- [ ] Store the full lock-time and previous logged anchor transforms.
- [ ] Persist relative translation/rotation at 1 Hz and severity transitions.
- [ ] Carry cloud metadata beside buffers under the existing lock and log only
      when the render loop consumes the dirty generation.
- [ ] Add the signed app diagnostics marker to Info.plist and session telemetry.
- [ ] Run the focused Swift/source contract tests and confirm they pass.

### Task 5: Implement native BA diagnostics

**Files:**
- Create: `aether_cpp/official_pipeline/src/live_cloud_diagnostics_v1.h`
- Modify: `aether_cpp/official_pipeline/src/official_aether_sfm_c.cc`
- Create: `aether_cpp/official_pipeline/tests/live_cloud_diagnostics_v1_test.cc`

- [ ] Implement a pure robust summary over camera-center delta vectors.
- [ ] After local BA, read optimized centers and immutable `FrameRecord` ARKit
      centers and append one best-effort JSONL event.
- [ ] Emit the native diagnostics contract identity once per session.
- [ ] Run the focused native test, build the iOS core, and verify the existing ABI.

### Task 6: Integrate and independently review

**Files:**
- Modify only the files named above plus regenerated native framework artifacts.

- [ ] Run focused Flutter tests, existing related capture tests, analyzer, native
      tests, framework boundary verification, and a local unsigned/simulator check.
- [ ] Inspect the complete diff and prove no coordinate/BA/matcher/render-selection
      branch changed.
- [ ] Give a fresh read-only reviewer the specification, diff, and test evidence;
      resolve every material finding and rerun verification.

### Task 7: Freeze, build, and verify the signed candidate

**Files:**
- Create under `/private/tmp`: isolated full-tree snapshot, build output, ledger.

- [ ] Recompute the source manifest and stop on unexplained drift.
- [ ] Map only the already pinned sibling `dist` and `Aether3D-cross` artifacts.
- [ ] Build with the existing Flutter/package cache and `--no-pub`, using a
      task-specific `XDG_CONFIG_HOME` and `/private/tmp` output.
- [ ] Verify bundle ID `com.kyle.PocketWorld`, deep signature, diagnostics marker,
      native ABI, and hashes of Runner/App.framework/PWOfficialSfm.

### Task 8: Protect data and update in place

**Files:**
- Create under `/private/tmp`: verified pre/post device manifests and logs.

- [ ] In one dedicated normal macOS Terminal window, check disk and resolve the
      production device/application identity without launching or mutating it.
- [ ] Copy `Documents` and `Library` separately, reconcile JSON device listings
      against every copied entry, hash every file, and stop unless complete.
- [ ] Run only `xcrun devicectl device install app <candidate>`; no uninstall.
- [ ] Re-copy `Documents` and `Library`; prove all pre-existing files are present
      and byte-identical except recorded `Library/SplashBoard/Snapshots/**`.
- [ ] Emit `UPDATE_COMPLETE` only after signature/install/data checks all pass.

### Task 9: Add native snapshot-drift diagnostics V2

**Files:**
- Modify: `../Aether3D-cross/aether_cpp/official_pipeline/src/live_cloud_diagnostics_v1.h`
- Modify: `../Aether3D-cross/aether_cpp/official_pipeline/src/official_aether_sfm_c.cc`
- Create: `../Aether3D-cross/aether_cpp/tests/sfm/live_cloud_snapshot_diagnostics_v2_test.cc`
- Create: `../Aether3D-cross/aether_cpp/tests/sfm/run_live_cloud_snapshot_diagnostics_v2_tests.sh`

- [x] Write and run failing tests for a known Sim3 with an outlier, degenerate
      camera geometry, exact-ID displacement, ID churn, and 5/10 cm counts.
- [x] Implement the pure robust Sim3 and same-ID displacement summaries.
- [x] Emit fail-open observation-only events after local BA and successful global BA.
- [x] Run focused native tests, build the iOS core, verify the existing public
      ABI, and verify both V2 event names are present in the binary.
