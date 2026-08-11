# SQLite Track Delta Complete Archive Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> superpowers:executing-plans to implement this plan task-by-task. The user
> explicitly prohibited subagents, so execution stays in the primary session.
> Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure whether match-track descriptor delta preprocessing reduces a
complete SQLite ZPAQ archive while restoring the original database byte for
byte.

**Architecture:** A bounded native preprocessor reads COLMAP's verified
`two_view_geometries` matches, builds a deterministic spanning forest over
descriptor nodes, and replaces each non-root 128-byte descriptor with its
modulo-256 delta from its parent in a temporary byte-identical SQLite copy. The
benchmark compares ZPAQ method 5 on the original database and transformed copy,
then decodes and verifies both candidates for three deterministic repeats.

**Tech Stack:** C++17, SQLite C API, official libzpaq 7.15 method 5, shell
benchmark harness, SHA-256, OpenSpec.

---

### Task 1: Freeze the one-database preflight contract

**Files:**

- Create: `.context/compound-engineering/ce-optimize/sqlite-track-delta-complete-archive/spec.yaml`
- Create: `.context/compound-engineering/ce-optimize/sqlite-track-delta-complete-archive/experiment-log.yaml`
- Modify: `openspec/changes/add-sqlite-descriptor-zpaq-preprocessing/design.md`
- Modify: `openspec/changes/add-sqlite-descriptor-zpaq-preprocessing/specs/sqlite-descriptor-zpaq-preprocessing/spec.md`

- [ ] **Step 1: Register the immutable input**

Use the verified backup copy at:

```text
/private/tmp/pw_portable_sfm_update.6RQ6nt/before/Documents/captures_official/cap_1785512421333592/official_sfm_live.db
```

Require length `198983680`, SHA-256
`0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0`,
and `PRAGMA integrity_check = ok` before every run.

- [ ] **Step 2: Register the fixed acceptance rule**

Every arm must restore the source length, bytes, SHA-256 and SQLite integrity.
Run three repeats. The local transform advances when the complete transformed
archive is smaller than raw ZPAQ in every repeat; the old 10% threshold applies
only to an invasive COLMAP storage-layer redesign.

### Task 2: RED/GREEN deterministic track forest

**Files:**

- Modify: `ios/Runner/pw_sqlite_descriptor_transform.h`
- Modify: `ios/RunnerTests/PWSqliteDescriptorTransformSmoke.cpp`
- Modify: `ios/Runner/pw_sqlite_descriptor_transform.cpp`

- [ ] **Step 1: Write the failing exact round-trip test**

Add `PW_SQLITE_DESCRIPTOR_TRACK_DELTA = 4`, create a fixture with a valid
`two_view_geometries(pair_id,rows,cols,data,...)` table, and match descriptor
rows across two images. Require deterministic forward bytes, changed matched
descriptor bytes, unchanged roots/unmatched rows, exact inverse bytes, and
successful integrity checks.

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
bash tool/run_sqlite_descriptor_transform_tests.sh
```

Expected: track delta returns `PW_SQLITE_DESCRIPTOR_TRANSFORM_UNSUPPORTED`.

- [ ] **Step 3: Implement the minimal forest transform**

Decode COLMAP pair IDs with `2147483647`, validate `rows × 2 × sizeof(uint32)`
match BLOBs, discard out-of-range indices, sort edges deterministically, build
an acyclic spanning forest, and select the smallest `(image_id,row)` as each
component root. Encode and decode in parent-before-child order using:

```cpp
encoded[column] = static_cast<uint8_t>(child[column] - parent[column]);
decoded[column] = static_cast<uint8_t>(encoded[column] + parent[column]);
```

- [ ] **Step 4: Run the test and verify GREEN**

Expected: exact source/restored bytes and deterministic transformed output.

### Task 3: Build the complete-archive harness

**Files:**

- Create: `tool/sqlite_track_delta_complete_archive_bench.cpp`
- Create: `tool/run_sqlite_track_delta_complete_archive_bench.sh`

- [ ] **Step 1: Write the harness smoke contract**

The shell entry point must reject a wrong input length or SHA before copying,
compile only the pinned local sources, and emit one JSON record per completed
arm/repeat.

- [ ] **Step 2: Implement raw candidate**

Compress the untouched source with ZPAQ method 5, decompress to a temporary
database, then verify length, byte equality, SHA-256 and integrity.

- [ ] **Step 3: Implement track-delta candidate**

Transform a temporary copy, compress it with the same ZPAQ method 5, decompress,
apply the inverse transform, then run the same four exactness checks.

- [ ] **Step 4: Persist before deleting temporaries**

Write archive bytes, hashes, transform statistics, elapsed time, peak RSS and
peak temporary bytes to the experiment log, read the entry back, then delete
the large temporary files.

### Task 4: Three-repeat comparison

**Files:**

- Update: `.context/compound-engineering/ce-optimize/sqlite-track-delta-complete-archive/experiment-log.yaml`
- Create: `.context/compound-engineering/ce-optimize/sqlite-track-delta-complete-archive/strategy-digest.md`

- [ ] **Step 1: Run raw ZPAQ three times**

Require identical archive size and hash for all repeats.

- [ ] **Step 2: Run track delta plus ZPAQ three times**

Require identical transformed hash, archive size and archive hash for all
repeats.

- [ ] **Step 3: Calculate complete archive net gain**

```text
gain_fraction = (raw_archive_bytes - track_archive_bytes) / raw_archive_bytes
```

Advance only if `gain_fraction > 0` in all three repeats and all exactness gates
pass.

### Task 5: Verify scope and report

**Files:**

- Modify only the plan, OpenSpec, experimental native files, harness and local
  ignored experiment evidence named above.

- [ ] **Step 1: Run focused tests and strict OpenSpec validation**

```bash
bash tool/run_sqlite_descriptor_transform_tests.sh
openspec validate add-sqlite-descriptor-zpaq-preprocessing --strict
```

- [ ] **Step 2: Inspect the owned diff**

Confirm no unrelated shared-worktree path was edited or staged.

- [ ] **Step 3: Report the host-preflight verdict**

Report both complete archive byte counts, net percentage, all three exactness
repeats and remaining physical-iPhone gate. Do not modify production behavior
or install the app in this task.
