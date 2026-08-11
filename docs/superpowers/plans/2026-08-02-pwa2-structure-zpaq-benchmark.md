# PWA2 Structure + ZPAQ Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans
> to implement this plan task-by-task. The user explicitly prohibited
> subagents, so execution stays inline. Steps use checkbox (`- [ ]`) syntax for
> tracking.

**Goal:** Build and run the benchmark-only PWA2 Arm B against the frozen
124,401,918-byte track-delta ZPAQ baseline.

**Architecture:** A new standalone C++17 library reads the supported COLMAP
SQLite schema into deterministic logical streams, separates descriptor
roots/residuals/literals and exact numeric columns into bounded members, and
reconstructs/query-compares all values. A separate harness compresses every
member with the existing pinned ZPAQ bridge and includes all framing/index
bytes in the result.

**Tech Stack:** C++17, SQLite C API, existing PocketWorld ZPAQ 7.15 bridge,
SHA-256, shell, OpenSpec, DVC, MLflow metadata, physical iPhone only after the
host size gate.

---

### Task 1: Freeze and validate the experiment contract

**Files:**

- Create: `openspec/changes/benchmark-pwa2-structure-zpaq/**`
- Create: `experiments/pwa2_structure_zpaq/experiment-contract.yaml`
- Create: `experiments/pwa2_structure_zpaq/input-manifest.yaml`
- Create: `experiments/pwa2_structure_zpaq/dvc.yaml`
- Create: `experiments/pwa2_structure_zpaq/pyproject.toml`
- Generate: `experiments/pwa2_structure_zpaq/uv.lock`

- [ ] **Step 1: Validate input identity**

Run `stat`, SHA-256, and immutable SQLite integrity against the exact values in
the contract. Expected: 198,983,680 bytes, the frozen SHA, and `ok`.

- [ ] **Step 2: Validate OpenSpec RED/GREEN documentation gate**

Run `openspec validate benchmark-pwa2-structure-zpaq --strict`. Expected: pass.

- [ ] **Step 3: Generate and freeze the Python environment**

Run `uv lock` inside the experiment directory. Expected: a deterministic lock
containing DVC 3.67.1 and MLflow 3.14.0.

### Task 2: RED/GREEN exact logical framing

**Files:**

- Create: `tool/pwa2_sqlite_logical_archive.h`
- Create: `tool/pwa2_sqlite_logical_archive_test.cpp`
- Create: `tool/run_pwa2_sqlite_logical_archive_tests.sh`
- Create: `tool/pwa2_sqlite_logical_archive.cpp`

- [ ] **Step 1: Write a failing fixture test**

The test creates all supported COLMAP tables, including empty tables, mixed
SQLite storage classes, BLOBs, and deterministic primary-key order. It calls:

```cpp
pw::pwa2::PackDatabase(source, raw_members, options, &stats);
pw::pwa2::VerifyDatabase(source, raw_members, &verification);
pw::pwa2::MaterializeDatabase(raw_members, restored);
```

Require deterministic member bytes, canonical logical equality, every table
covered, and `PRAGMA integrity_check = ok`.

- [ ] **Step 2: Run RED**

Run `bash tool/run_pwa2_sqlite_logical_archive_tests.sh`. Expected: compile
failure because the implementation API does not yet exist.

- [ ] **Step 3: Implement the minimal typed-row and member framing**

Use fixed little-endian integers, length-prefixed UTF-8/schema bytes, explicit
SQLite storage-class tags, member IDs, record ranges, lengths, and SHA-256.
Reject duplicate IDs, overlap, truncation, unsupported schema, and bad hashes.

- [ ] **Step 4: Run GREEN**

Run the focused test. Expected: all fixture rows and materialized contents pass.

### Task 3: RED/GREEN structured computer-vision streams

**Files:**

- Modify: `tool/pwa2_sqlite_logical_archive_test.cpp`
- Modify: `tool/pwa2_sqlite_logical_archive.cpp`

- [ ] **Step 1: Add failing descriptor tests**

Create components containing a root, multi-depth children, a cycle candidate,
and unmatched rows. Require separate root/residual/literal members, modulo-256
round trip, deterministic topology, and exact first/middle/last random reads.

- [ ] **Step 2: Run RED**

Expected: structured member expectations fail while generic framing remains
green.

- [ ] **Step 3: Implement deterministic forest and 128-lane blocks**

Decode pair IDs with 2,147,483,647; validate every `rows*2*sizeof(uint32_t)`
BLOB; sort edges; use DSU; traverse parent-before-child; group at most 32,768
records per lane-major block; store roots and `(child,parent)` topology.

- [ ] **Step 4: Add and implement exact keypoint/match column tests**

Require float32 bit patterns and both match uint32 columns to survive exact
column/byte-plane grouping without numeric conversion.

- [ ] **Step 5: Run GREEN and corruption tests**

Flip a payload byte and remove a parent dependency. Expected: both fail closed;
uncorrupted fixture passes.

### Task 4: RED/GREEN pinned ZPAQ member container

**Files:**

- Create: `tool/pwa2_structure_zpaq_bench.cpp`
- Create: `tool/run_pwa2_structure_zpaq_bench.sh`
- Create: `test/pwa2_structure_zpaq_benchmark_contract_test.dart`

- [ ] **Step 1: Write the failing shell/Dart contract test**

Require the harness to reject wrong input identity, reject any codec/method
other than the frozen ZPAQ identity, include manifest/index bytes, verify every
decompressed member, and emit the pre-registered gate verdict.

- [ ] **Step 2: Run RED**

Run the focused Dart contract test. Expected: missing harness/contract markers.

- [ ] **Step 3: Implement minimal member compression**

For every raw member, call the existing `pw_zpaq_compress_file(..., 5, ...)`,
immediately decompress and SHA-verify it, then append the compressed payload and
its fixed index entry to one PWA2 file. Persist metrics before removing large
temporaries.

- [ ] **Step 4: Run GREEN**

Run native fixture tests and the Dart contract test. Expected: all pass.

### Task 5: Execute the frozen real-data run

**Files:**

- Create: `experiments/pwa2_structure_zpaq/results/2026-08-02-pwa2-structure-zpaq.yaml`

- [ ] **Step 1: Recheck immutable identity immediately before execution**

Expected: length/SHA/integrity match the contract; abort otherwise.

- [ ] **Step 2: Run one deterministic Arm B pass**

Record complete bytes, hashes, elapsed time, peak RSS/temp, member count,
forest coverage, random-read member count, and every exactness gate. Log the
same run identity and metrics to a local MLflow file store.

- [ ] **Step 3: Apply the frozen stop rule**

At most 111,961,726 bytes plus all exactness gates means host pass and a future
independent-phone task. Any larger valid output means host size rejection and
no phone build/install.

### Task 6: Verify scope and report

**Files:** Only the new spec, experiment, tool, test, and result paths above.

- [ ] **Step 1: Run focused native/Dart/OpenSpec tests**

- [ ] **Step 2: Run DVC status and verify MLflow/result identities**

- [ ] **Step 3: Inspect owned files and confirm no production path changed**

- [ ] **Step 4: Report exact A/B bytes and the evidence-backed next decision**
