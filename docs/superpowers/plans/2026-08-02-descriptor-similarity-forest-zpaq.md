# Descriptor Similarity Forest + ZPAQ A/B Implementation Plan

> Execute locally in the shared PocketWorld checkout. Do not create a worktree,
> spawn subagents, edit production behavior, stage files, commit, install the app,
> or touch the phone.

**Goal:** Measure the complete net archive impact of expanding descriptor
prediction from verified tracks to an almost-full similarity forest while
retaining exact SQLite byte restoration.

**Architecture:** Reuse the benchmark-only raw SQLite BLOB locator. A and B
write the same small container and use the same ZPAQ bridge. B builds an
ordinal-safe Faiss forest and appends a compact parent sidecar. Decode reverses
the residuals and verifies the original database.

**Tech Stack:** C++17, SQLite, CommonCrypto, official libzpaq 7.15, Homebrew
Faiss 1.14.0 (encoder only), shell runner, OpenSpec experiment record.

---

### Task 1: Lock contract and write failing tests

**Files:**
- Create: `experiments/descriptor_similarity_forest_zpaq/experiment-contract.yaml`
- Create: `experiments/descriptor_similarity_forest_zpaq/input-manifest.yaml`
- Create: `tool/descriptor_similarity_forest_test.cpp`

Run a compile before the implementation exists and require it to fail because
the forest API is missing.

### Task 2: Implement the pure forest codec

**Files:**
- Create: `tool/descriptor_similarity_forest.h`
- Create: `tool/descriptor_similarity_forest.cpp`
- Create: `tool/run_descriptor_similarity_forest_tests.sh`

Implement DAG validation, varint sidecar encode/decode, exact modulo-256
forward/inverse transforms, and Faiss `IndexIVFFlat` construction. Run the unit
tests until green.

### Task 3: Implement the exact complete-database A/B

**Files:**
- Create: `tool/sqlite_descriptor_similarity_forest_zpaq_bench.cpp`
- Create: `tool/run_sqlite_descriptor_similarity_forest_zpaq_bench.sh`
- Create: `test/descriptor_similarity_forest_zpaq_contract_test.dart`

Reuse benchmark-only SQLite page parsing, place both arms in the same container,
compress/decompress through the pinned ZPAQ bridge, and run all exactness gates.

### Task 4: Run one benchmark and preserve compact evidence

**Files:**
- Create: `experiments/descriptor_similarity_forest_zpaq/results/<run>.json`
- Create: `experiments/descriptor_similarity_forest_zpaq/evidence.json`

Run A once and B once. Do not repeat automatically. Persist byte counts,
coverage, sidecar bytes, elapsed time, peak RSS/temp bytes, hashes, parameters,
and the verdict. Delete transformed databases, archives, and build outputs after
their hashes and metrics are safely recorded.

