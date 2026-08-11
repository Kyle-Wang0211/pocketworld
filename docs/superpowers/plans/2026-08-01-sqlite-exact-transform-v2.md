# SQLite Exact Transform V2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:executing-plans to implement this plan task-by-task. The user
> prohibited subagents, so execution remains in the primary session. Steps use
> checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and benchmark a deterministic page-preserving reversible SQLite
transform that combines descriptor track delta, keypoint byte-plane XOR, and
match-index delta before ZPAQ method 5.

**Architecture:** The existing native SQLite page parser gains generic BLOB
location support for the three additional COLMAP tables. A new transform enum
composes the existing descriptor transform with the new reversible numeric
transforms. The existing independent benchmark path receives a third arm but
production manifest and selection code remain unchanged.

**Tech Stack:** C++17, SQLite3, Dart/Flutter, Dart FFI, official ZPAQ 7.15 method
5, OpenSpec, physical iPhone A16.

---

### Task 1: Freeze the experiment contract

**Files:**

- Create: `openspec/changes/benchmark-sqlite-exact-transform-v2/proposal.md`
- Create: `openspec/changes/benchmark-sqlite-exact-transform-v2/design.md`
- Create: `openspec/changes/benchmark-sqlite-exact-transform-v2/tasks.md`
- Create: `openspec/changes/benchmark-sqlite-exact-transform-v2/specs/sqlite-exact-transform-v2/spec.md`
- Create: `experiments/sqlite_descriptor_zpaq/exact-transform-v2-contract.yaml`

- [ ] Record the immutable input SHA/length, existing raw and track baselines,
      exactness gates, one-pass stop rule, hardware, pinned ZPAQ identity, and
      result paths.
- [ ] Run strict OpenSpec validation and confirm the new change is valid.

### Task 2: RED native exactness tests

**Files:**

- Modify: `ios/RunnerTests/PWSqliteDescriptorTransformSmoke.cpp`

- [ ] Extend the synthetic fixture with overflow-page keypoints, matches, and
      two-view BLOBs whose values exercise uint32 wraparound and every float32
      byte lane.
- [ ] Require transform enum `PW_SQLITE_EXACT_TRANSFORM_V2`, deterministic
      forward output, changed bytes in every targeted table, byte-exact inverse,
      equal forward/inverse statistics, integrity `ok`, and source immutability.
- [ ] Run `tool/run_sqlite_descriptor_transform_tests.sh` and verify compilation
      fails because the v2 ABI and statistics do not exist yet.

### Task 3: GREEN native transform

**Files:**

- Modify: `ios/Runner/pw_sqlite_descriptor_transform.h`
- Modify: `ios/Runner/pw_sqlite_descriptor_transform.cpp`

- [ ] Add v2 enum and per-table record/byte counters without changing existing
      enum values or ABI fields.
- [ ] Generalize physical BLOB mapping for fixed COLMAP schemas while rejecting
      incompatible record headers, duplicate rows, invalid overflow chains, and
      rows/cols/length mismatches.
- [ ] Implement keypoint byte-plane XOR and two-column uint32 delta with exact
      inverse and cooperative cancellation.
- [ ] Compose the forward/inverse order defined in the design and run the native
      suite to GREEN.

### Task 4: RED/GREEN benchmark arm

**Files:**

- Modify: `tool/sqlite_track_delta_complete_archive_bench.cpp`
- Modify: `tool/run_sqlite_track_delta_complete_archive_bench.sh`
- Modify: `lib/database_archive_benchmark_main.dart`
- Modify: `tool/run_sqlite_dual_candidate_iphone_bench.sh`
- Modify: `test/database_archive_benchmark_contract_test.dart`

- [ ] First add contract assertions requiring `exact_transform_v2`, a three-arm
      size report, one repeat, exact source restoration, and a host early-stop
      against `124401918`; run the focused Dart test and observe RED.
- [ ] Add the v2 arm to the host native harness and independent iPhone
      benchmark without modifying production transaction selection.
- [ ] Run the focused Dart contract test and native suite to GREEN.

### Task 5: Host feasibility

**Files:**

- Create only a small result YAML under
  `experiments/sqlite_descriptor_zpaq/results/`; all large outputs stay under
  `/private/tmp` and are deleted after verification.

- [ ] Recheck input length, SHA-256 and immutable SQLite integrity.
- [ ] Run one v2 transform/ZPAQ/restore pass, plus the deterministic transform
      repeat required by the native test.
- [ ] Verify source unchanged, byte equality, SHA equality, integrity `ok`, and
      no temporary leak.
- [ ] Stop if archive bytes are greater than or equal to `124401918`; do not
      build or install a phone bundle in that case.

### Task 6: Conditional physical-iPhone benchmark

**Files:** no production App files beyond the benchmark paths above.

- [ ] Only after the host size gate passes, build the alternate Flutter entry
      point with `--no-pub` and bundle ID
      `com.kyle.PocketWorld.ArchiveBench`.
- [ ] Verify signature, bundle ID and required native symbol before installing
      the independent bundle.
- [ ] Copy only the immutable fixture into that bundle, run one pass, retrieve
      the JSON result, and verify exactness, archive size, peak RSS and cleanup.
- [ ] Never uninstall, install, update or read `com.kyle.PocketWorld`.

### Task 7: Verification and recommendation

**Files:** only paths listed above.

- [ ] Format only owned Dart files.
- [ ] Run native smoke, focused Flutter tests, strict OpenSpec validation,
      `flutter analyze lib/ test/`, and full `flutter test` if the benchmark
      path changed production-compiled sources.
- [ ] Inspect only owned diffs; never use `git add -A`, `git add -u`,
      `commit -a`, reset, checkout, stash or global formatting.
- [ ] Report HEAD, exact input identity, all three archive sizes, exactness,
      physical bundle identity if run, and an explicit `accept` or `reject`
      decision for future production integration.
