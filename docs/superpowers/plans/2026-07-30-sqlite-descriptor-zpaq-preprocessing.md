# SQLite Descriptor ZPAQ Preprocessing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans
> to implement this plan task-by-task. The user explicitly prohibited subagents,
> so execution stays in the primary session. Steps use checkbox (`- [ ]`) syntax
> for tracking.

**Goal:** Build and rigorously test a portable, reversible SQLite descriptors
preprocessor that can improve ZPAQ method-5 compression while restoring the
original database byte-for-byte.

**Architecture:** A read-only SQLite connection validates the known
`descriptors` schema and root page. A bounded raw-page parser walks its table
b-tree and overflow chains, then applies a same-length transform only to BLOB
payload spans in a copied output file. A separate benchmark compresses the
transformed copy with the existing pinned libzpaq bridge, restores it, applies
the inverse, and enforces exact hashes and bytes.

**Tech Stack:** C++17, SQLite C API, official libzpaq 7.15 method 5, XCTest/host
smoke tests, shell measurement harness, DVC 3.67.1, MLflow 3.14.0, uv 0.11.14,
OpenSpec 1.6.0.

---

### Task 1: Freeze experiment identity

**Files:**

- Create: `experiments/sqlite_descriptor_zpaq/experiment-contract.yaml`
- Create: `experiments/sqlite_descriptor_zpaq/input-manifest.yaml`
- Create: `experiments/sqlite_descriptor_zpaq/pyproject.toml`
- Create: `experiments/sqlite_descriptor_zpaq/uv.lock`
- Create: `experiments/sqlite_descriptor_zpaq/dvc.yaml`
- Create: `.context/compound-engineering/ce-optimize/sqlite-descriptor-zpaq/spec.yaml`

- [ ] **Step 1: Record immutable inputs and thresholds**

Write all five source path/length/SHA-256 triples, app/native/ZPAQ revisions,
tool lock identity, page/schema constraints, correctness gates, the 10%
compression threshold, three-repeat rule, and host-versus-phone evidence roles.

- [ ] **Step 2: Create the repository-local tool lock**

Run:

```bash
cd experiments/sqlite_descriptor_zpaq
uv lock --offline
```

Expected: `uv.lock` resolves exactly DVC 3.67.1 and MLflow 3.14.0 without a
network fetch.

- [ ] **Step 3: Register DVC input identity and local MLflow storage**

Initialize DVC only under `experiments/sqlite_descriptor_zpaq`, record the five
external immutable dependencies in `dvc.yaml`, and configure MLflow artifacts
under ignored `.context/compound-engineering/ce-optimize/sqlite-descriptor-zpaq/`.
Do not copy private database bytes into Git.

- [ ] **Step 4: Validate OpenSpec and the optimization spec**

Run:

```bash
openspec validate add-sqlite-descriptor-zpaq-preprocessing --strict
```

Expected: validation succeeds.

### Task 2: First RED/GREEN transpose round trip

**Files:**

- Create: `ios/Runner/pw_sqlite_descriptor_transform.h`
- Create: `ios/Runner/pw_sqlite_descriptor_transform.cpp`
- Create: `ios/RunnerTests/PWSqliteDescriptorTransformSmoke.cpp`
- Create: `tool/run_sqlite_descriptor_transform_tests.sh`

- [ ] **Step 1: Write the failing fixture test**

The test creates a 4096-byte-page SQLite database with the exact five-column
descriptors schema, inserts deterministic `rows × 128` BLOBs large enough to use
overflow pages, and calls:

```cpp
pw_sqlite_descriptor_transform_file(
    source_path, transformed_path, PW_SQLITE_DESCRIPTOR_TRANSPOSE, false,
    nullptr);
pw_sqlite_descriptor_transform_file(
    transformed_path, restored_path, PW_SQLITE_DESCRIPTOR_TRANSPOSE, true,
    nullptr);
```

It requires the source hash/bytes to remain unchanged, the transformed bytes to
differ, the restored bytes to equal the source, and both transformed/restored
files to pass `PRAGMA integrity_check`.

- [ ] **Step 2: Run and verify RED**

Run:

```bash
bash tool/run_sqlite_descriptor_transform_tests.sh
```

Expected: compilation fails because
`ios/Runner/pw_sqlite_descriptor_transform.h` does not yet exist.

- [ ] **Step 3: Implement minimal validated parser and transpose**

Implement status/error APIs, source-to-output copy, SQLite schema/root lookup,
bounded table-b-tree traversal, record serial-type parsing, overflow span
collection, `rows × 128` transpose/inverse, durable output sync, and incomplete
output cleanup.

- [ ] **Step 4: Run and verify GREEN**

Run the same command.

Expected: `PW_SQLITE_DESCRIPTOR_TRANSFORM_TEST_OK` with byte equality true.

### Task 3: Add XOR and delta through TDD

**Files:**

- Modify: `ios/RunnerTests/PWSqliteDescriptorTransformSmoke.cpp`
- Modify: `ios/Runner/pw_sqlite_descriptor_transform.cpp`

- [ ] **Step 1: Add failing XOR and delta round trips**

Loop over:

```cpp
PW_SQLITE_DESCRIPTOR_TRANSPOSE
PW_SQLITE_DESCRIPTOR_TRANSPOSE_XOR
PW_SQLITE_DESCRIPTOR_TRANSPOSE_DELTA
```

Require deterministic forward hashes, different transformed bytes, exact
inverse bytes, and source immutability.

- [ ] **Step 2: Run and verify RED**

Expected: XOR/delta return unsupported-transform status.

- [ ] **Step 3: Implement minimal reversible predictors**

For each transposed dimension stream, leave the first byte literal. Encode
subsequent bytes as either `current ^ previous` or
`uint8_t(current - previous)`. Decode with XOR accumulation or modulo-256
addition.

- [ ] **Step 4: Run and verify GREEN**

Expected: all three transforms pass.

### Task 4: Structural/property/fault coverage

**Files:**

- Modify: `ios/RunnerTests/PWSqliteDescriptorTransformSmoke.cpp`
- Modify: `tool/run_sqlite_descriptor_transform_tests.sh`

- [ ] **Step 1: Add parameterized SQLite fixtures**

Cover page sizes 512/1024/4096/65536, auto-vacuum on/off, empty/single/multiple
records, local/overflow boundaries, 8192-row BLOBs, and zero/constant/ramp/
repeated/random value distributions.

- [ ] **Step 2: Add 1000 fixed-seed property cases**

Generate deterministic rows and bytes, run every transform forward/inverse, and
require exact byte equality.

- [ ] **Step 3: Add malformed and interruption cases**

Test bad magic/page size/page type/varint, truncation, wrong schema, wrong
columns/length, overflow page out of range/reuse/cycle, cancellation, and output
failure. Require failure status, no accepted output, and unchanged source.

- [ ] **Step 4: Run the full native test**

Expected: all cases pass with a printed case count and no leaked temporary files.

### Task 5: Immutable ZPAQ measurement harness

**Files:**

- Create: `tool/sqlite_descriptor_zpaq_bench.cpp`
- Create: `tool/run_sqlite_descriptor_zpaq_bench.sh`
- Create: `experiments/sqlite_descriptor_zpaq/record_result.py`

- [ ] **Step 1: Write benchmark contract test**

Extend `test/database_archive_ffi_contract_test.dart` to require all four arms,
source/transformed/archive/restored hashes, byte equality, SQLite integrity,
elapsed time, peak RSS, temp bytes, and JSON output.

- [ ] **Step 2: Run and verify RED**

Run:

```bash
flutter test test/database_archive_ffi_contract_test.dart
```

Expected: missing harness evidence fails.

- [ ] **Step 3: Implement the host diagnostic harness**

Compile the preprocessor with pinned libzpaq and SQLite. For one immutable input
and arm, copy/transform, ZPAQ encode/decode, inverse, verify exact bytes/hash and
integrity, emit one JSON object, and remove large temporaries after hashes and
metrics are persisted.

- [ ] **Step 4: Persist each result immediately**

Append the JSON result to the ce-optimize experiment log, write a per-run
`result.yaml`, verify both by rereading, and log parameters/metrics/artifact
hashes to the local MLflow experiment before starting the next run.

### Task 6: Baseline and real-database diagnostics

**Files:**

- Update: `.context/compound-engineering/ce-optimize/sqlite-descriptor-zpaq/experiment-log.yaml`
- Update: `.context/compound-engineering/ce-optimize/sqlite-descriptor-zpaq/strategy-digest.md`

- [ ] **Step 1: Measure raw ZPAQ baseline**

Run all five inputs through raw method 5, decode every archive, and persist
results before evaluating candidates.

- [ ] **Step 2: Run three transform arms**

Run transpose, XOR, and delta on all five inputs for three repeats. Do not use
host rankings as production selection.

- [ ] **Step 3: Verify deterministic identities**

Require each input/arm transformed hash and archive hash to match across the
three repeats. Any exactness or determinism failure rejects the arm.

- [ ] **Step 4: Write diagnostic summary**

Report bytes, ratios, delta versus raw, time, peak RSS, and temp bytes with
explicit `host-diagnostic-only` labeling.

### Task 7: Physical-iPhone candidate gate

**Files:**

- Create or modify only test-bundle wiring required to compile the same native
  preprocessor and pinned ZPAQ bridge.
- Do not modify production archive policy/manifest/transaction files.

- [ ] **Step 1: Build a separate test bundle**

Use a non-production bundle identifier and container. Never run `flutter drive`
against `com.kyle.PocketWorld`.

- [ ] **Step 2: Transfer one verified fixture copy at a time**

Verify fixture SHA-256 after transfer. The test bundle must have no entitlement
or path to the production app container.

- [ ] **Step 3: Run three repeats for every surviving arm/input**

Persist result records after each run and support process restart/resume.

- [ ] **Step 4: Exercise failure paths**

Bit-flip/truncate archives, interrupt at transform/ZPAQ/verify boundaries, and
restore after process termination. The source copy must always survive until
all exactness checks pass.

- [ ] **Step 5: Apply the production admission rule**

Accept only zero correctness failures, no input larger than raw ZPAQ, and at
least 10% lower median archive bytes. Otherwise retain raw ZPAQ unchanged.

### Task 8: Verification and decision

**Files:**

- Modify only this plan/OpenSpec task checklists and experiment evidence.

- [ ] **Step 1: Run scoped formatting and tests**

Run native tests, focused Flutter contracts, `flutter analyze lib/ test/`,
`flutter test`, and strict OpenSpec validation. Do not globally format files.

- [ ] **Step 2: Inspect owned diff and shared worktree**

Verify no unrelated dirty file was modified or staged.

- [ ] **Step 3: Present evidence-backed decision**

Either reject all preprocessing arms or propose a separate v2 production change.
Do not install a production behavior change from host evidence.
