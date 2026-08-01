# SQLite Dual-Candidate Production Archive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:executing-plans to implement this plan task-by-task. The user
> prohibited subagents, so execution remains in the primary session. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the smaller of exact raw-ZPAQ and exact
track-delta-plus-ZPAQ SQLite archives, then validate the production code path in
an independent physical-iPhone bundle.

**Architecture:** The Dart transaction owns candidate lifecycle and source-last
commit. A versioned preprocessor interface hides the iOS C++ transform; the
manifest selects the inverse path. A separate Flutter entrypoint reuses the same
transaction in an app with an independent bundle ID and container.

**Tech Stack:** Dart/Flutter, Dart FFI, C++17, SQLite3, libzpaq 7.15 method 5,
OpenSpec, CoreDevice.

---

### Task 1: RED selection and manifest tests

**Files:**

- Modify: `test/database_archive_transaction_test.dart`
- Modify: `test/database_archive_resolver_test.dart`
- Create: `test/database_archive_manifest_v2_test.dart`

- [ ] Write tests requiring the smaller exact candidate to win, raw fallback
      after a transform failure, raw tie-breaking, and source retention when
      both candidates fail.
- [ ] Write v1 compatibility and explicit v2 `track_delta_v1` serialization
      tests.
- [ ] Write a resolver test requiring inverse preprocessing before source SHA
      verification.
- [ ] Run the three focused files and confirm failures are caused by missing
      dual-candidate behavior.

### Task 2: GREEN Dart production transaction

**Files:**

- Create: `lib/official_capture/database_archive_preprocessor.dart`
- Modify: `lib/official_capture/database_archive_manifest.dart`
- Modify: `lib/official_capture/database_archive_transaction.dart`
- Modify: `lib/official_capture/database_archive_resolver.dart`

- [ ] Add `raw_v1` and `track_delta_v1` identifiers and a preprocessor protocol.
- [ ] Make v1 manifests read as raw and write new archives as schema v2 with
      selected preprocessing plus candidate audit sizes.
- [ ] Generate, fully restore, and verify each candidate independently; select
      minimum bytes with raw winning ties.
- [ ] Apply the manifest-selected inverse transform in reconciliation and
      resolver paths, then rerun focused tests to GREEN.

### Task 3: Native FFI and interruption

**Files:**

- Modify: `ios/Runner/pw_sqlite_descriptor_transform.h`
- Modify: `ios/Runner/pw_sqlite_descriptor_transform.cpp`
- Modify: `ios/Runner/pw_zpaq_bridge.cpp`
- Create: `lib/official_capture/database_archive_ffi_preprocessor.dart`
- Modify: `lib/official_capture/photo_archive_runtime.dart`
- Modify: `lib/official_capture/photo_archive_coordinator.dart`
- Modify: `test/database_archive_ffi_contract_test.dart`
- Modify: `test/database_archive_coordinator_test.dart`

- [ ] Add native cancellation generation/request functions and cancellable
      forward/inverse entrypoints, checking cancellation inside long loops.
- [ ] Bind them from a background Dart isolate and map cancellation to
      `DatabaseArchiveCancelled`.
- [ ] Wire the same preprocessor into transaction/resolver/coordinator and
      cancel it whenever production activity begins.
- [ ] Run native smoke and focused Dart tests to GREEN.

### Task 4: Independent benchmark bundle

**Files:**

- Create: `lib/database_archive_benchmark_main.dart`
- Create: `tool/run_sqlite_dual_candidate_iphone_bench.sh`
- Create: `test/database_archive_benchmark_contract_test.dart`

- [ ] Add a minimal benchmark UI/runner that reads
      `Documents/benchmark_input.db`, creates isolated ready-capture copies,
      runs the production transaction three times, restores each result, checks
      SQLite integrity through the native bridge, and atomically writes JSON.
- [ ] Build the alternate entrypoint with `--no-pub`, override the bundle ID to
      `com.kyle.PocketWorld.ArchiveBench`, verify the signed identifier, and
      install only that app.
- [ ] Copy the immutable fixture into the benchmark container, launch, wait for
      the JSON result, copy it back, and enforce all acceptance gates.

### Task 5: Final verification

**Files:** only the paths listed above plus OpenSpec and this plan.

- [ ] Run scoped `dart format` only on owned Dart files.
- [ ] Run native smoke, focused Flutter tests, strict OpenSpec validation,
      `flutter analyze lib/ test/`, and full `flutter test`.
- [ ] Inspect `git status`, `git diff` and staged paths without staging or
      reverting unrelated shared-worktree changes.
- [ ] Report the current HEAD, independent bundle ID, device result artifact,
      selected arm and exact archive sizes. Do not install the production app.
