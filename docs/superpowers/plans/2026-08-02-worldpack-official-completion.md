# WorldPack Official Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. The user explicitly prohibited subagents, so execution is inline in the primary session.

**Goal:** Complete the missing official OpenZL, ALP and WebGraph strict-lossless benchmarks and combine same-scope winners into a fully accounted WorldPack benchmark from minimum unit through the complete frozen capture.

**Architecture:** A Python orchestration layer freezes inputs, launches pinned native official-codec adapters, validates every decoded byte and emits compact JSON evidence. C++ adapters call unmodified OpenZL and ALP official APIs; a Rust adapter calls the pinned official WebGraph crate. WorldPack is an experiment-only append-only chunk container that selects the smallest verified member codec and always retains a ZPAQ fallback.

**Tech Stack:** Python 3.11 + uv/pytest, SQLite, C++17/CMake, OpenZL 0.2.0, ALP pinned commit, Rust 1.95 + WebGraph 0.6.1, ZPAQ 7.15 method 5, DVC 3.67.1, MLflow 3.14.0.

---

### Task 1: Freeze the experiment contract and input identity

**Files:**
- Create: `experiments/worldpack_official_completion/experiment-contract.yaml`
- Create: `experiments/worldpack_official_completion/input-manifest.yaml`
- Create: `experiments/worldpack_official_completion/pyproject.toml`
- Create: `experiments/worldpack_official_completion/dvc.yaml`
- Create: `experiments/worldpack_official_completion/tests/test_contract.py`
- Create: `test/worldpack_official_completion_contract_test.dart`

- [ ] **Step 1: Write failing contract tests**

The tests assert the frozen SQLite/PLY hashes, exact upstream revisions, OpenZL parser + ACE + clustering modes, ALP bit-equality gate, WebGraph full-file accounting, WorldPack minimum/100 MB/full stages, and forbidden production/phone operations.

- [ ] **Step 2: Run tests and verify RED**

Run: `flutter test --no-pub test/worldpack_official_completion_contract_test.dart`

Expected: FAIL because the experiment contract and runner do not exist.

- [ ] **Step 3: Add the minimal frozen contract and manifest**

The contract records HEAD `b504ee9`, source database identity, PLY identity, capture path, codec revisions, fixed seeds, parameter grids, complete-byte metric, exactness gates and stop rules. The input manifest is generated from a read-only walk and contains ordered relative path, byte length and SHA-256 entries.

- [ ] **Step 4: Generate the repository-local Python lock**

Run: `uv lock --project experiments/worldpack_official_completion`

Expected: `uv.lock` resolves only the declared orchestration/test dependencies.

- [ ] **Step 5: Run tests and verify GREEN**

Run: `flutter test --no-pub test/worldpack_official_completion_contract_test.dart`

Expected: PASS.

- [ ] **Step 6: Commit only Task 1 files**

Use `git add` with the six explicit paths and `git commit --only -F <message-file> -- <same paths>` so pre-existing staged DVC files remain outside the commit.

### Task 2: Build a common exact-input extractor and baseline adapter

**Files:**
- Create: `experiments/worldpack_official_completion/prepare_inputs.py`
- Create: `experiments/worldpack_official_completion/exact_io.py`
- Create: `experiments/worldpack_official_completion/tests/test_prepare_inputs.py`
- Create: `tool/worldpack_zpaq_adapter.cpp`
- Create: `tool/worldpack_zpaq_adapter_test.cpp`
- Create: `tool/run_worldpack_zpaq_adapter_tests.sh`

- [ ] **Step 1: Write RED tests for typed extraction**

The fixture creates a miniature COLMAP SQLite with descriptors, keypoints, matches and two-view geometry. Tests require deterministic descriptor roots/residuals, raw IEEE keypoint columns, ordered graph arcs, reversible typed metadata and unchanged source SHA.

- [ ] **Step 2: Run and verify RED**

Run: `uv run --project experiments/worldpack_official_completion pytest experiments/worldpack_official_completion/tests/test_prepare_inputs.py -q`

Expected: FAIL because `prepare_inputs.py` and `exact_io.py` are absent.

- [ ] **Step 3: Implement the minimum extractor**

Implement read-only SQLite extraction, canonical binary framing and inverse reconstruction helpers. Every frame carries type, count, element width, original ordinal, length and SHA-256.

- [ ] **Step 4: Write and run RED native ZPAQ tests**

Run: `tool/run_worldpack_zpaq_adapter_tests.sh`

Expected: compile or link FAIL before the adapter exists.

- [ ] **Step 5: Implement the pinned ZPAQ same-input baseline**

The adapter exposes file compress/decompress with method 5, writes no hidden sidecar, and returns status, elapsed time and complete archive bytes.

- [ ] **Step 6: Run GREEN tests**

Run: `uv run --project experiments/worldpack_official_completion pytest experiments/worldpack_official_completion/tests/test_prepare_inputs.py -q`

Run: `tool/run_worldpack_zpaq_adapter_tests.sh`

Expected: both PASS with byte and SHA equality.

### Task 3: Complete OpenZL parser, ACE and clustering-plus-ACE

**Files:**
- Create: `tool/worldpack_openzl_adapter.cpp`
- Create: `tool/worldpack_openzl_adapter_test.cpp`
- Create: `tool/run_worldpack_openzl_adapter_tests.sh`
- Create: `experiments/worldpack_official_completion/openzl_profile.yaml`
- Create: `experiments/worldpack_official_completion/tests/test_openzl_result.py`

- [ ] **Step 1: Write RED tests for required official modes**

Tests reject a result unless it identifies OpenZL `3dceb648...`, a typed parser, disjoint train/test chunks, completed ACE, completed clustering + ACE, serialized decoder dependency bytes, corruption rejection and same-input ZPAQ bytes.

- [ ] **Step 2: Verify RED**

Run: `uv run --project experiments/worldpack_official_completion pytest experiments/worldpack_official_completion/tests/test_openzl_result.py -q`

Expected: FAIL because no official complete result exists.

- [ ] **Step 3: Implement the official adapter without modifying upstream**

Register typed roots, residuals and parent streams with OpenZL; run the official trainer with no max-time cutoff; serialize the configured compressor; decode using only persisted decoder dependencies. Build from a clean pinned source directory under `/private/tmp`.

- [ ] **Step 4: Run adapter unit tests**

Run: `tool/run_worldpack_openzl_adapter_tests.sh`

Expected: PASS for typed parsing, official decode, byte equality and deterministic corruption rejection.

- [ ] **Step 5: Run the registered minimum benchmark once per arm**

Run: `uv run --project experiments/worldpack_official_completion python experiments/worldpack_official_completion/run_benchmark.py --stage openzl-minimum`

Expected: a compact result JSON containing complete bytes for untrained parser, ACE, clustering + ACE and ZPAQ.

- [ ] **Step 6: Expand only an exact strict winner**

Run: `uv run --project experiments/worldpack_official_completion python experiments/worldpack_official_completion/run_benchmark.py --stage openzl-full-descriptors`

Expected: the runner executes only when a minimum OpenZL arm is strictly smaller; otherwise it records `stopped-minimum-size` without claiming OpenZL family failure.

### Task 4: Complete official ALP on real float columns

**Files:**
- Create: `tool/worldpack_alp_adapter.cpp`
- Create: `tool/worldpack_alp_adapter_test.cpp`
- Create: `tool/run_worldpack_alp_adapter_tests.sh`
- Create: `experiments/worldpack_official_completion/tests/test_alp_result.py`

- [ ] **Step 1: Write RED special-value and result tests**

Tests cover positive/negative zero, infinities, representative NaN payload bit patterns, real float32 keypoints, column order, complete framing bytes and two same-input ZPAQ baselines.

- [ ] **Step 2: Verify RED**

Run: `tool/run_worldpack_alp_adapter_tests.sh`

Expected: compile FAIL before the adapter exists.

- [ ] **Step 3: Implement official ALP encode/decode calls**

Use the pinned official headers and generated schemes without changing ALP source. Move source values through integer bit copies, include exceptions and metadata, and reconstruct original row-major bytes.

- [ ] **Step 4: Run GREEN native tests**

Run: `tool/run_worldpack_alp_adapter_tests.sh`

Expected: PASS with every float bit and complete original frame identical.

- [ ] **Step 5: Run minimum and eligible full-column stages**

Run: `uv run --project experiments/worldpack_official_completion python experiments/worldpack_official_completion/run_benchmark.py --stage alp-minimum`

Run: `uv run --project experiments/worldpack_official_completion python experiments/worldpack_official_completion/run_benchmark.py --stage alp-full-columns`

Expected: full columns run only for an exact minimum winner; both results state the narrow scope.

### Task 5: Complete official WebGraph and clean Elias–Fano graph streams

**Files:**
- Create: `tool/worldpack_webgraph_adapter/Cargo.toml`
- Create: `tool/worldpack_webgraph_adapter/Cargo.lock`
- Create: `tool/worldpack_webgraph_adapter/src/main.rs`
- Create: `tool/worldpack_webgraph_adapter/tests/roundtrip.rs`
- Create: `experiments/worldpack_official_completion/tests/test_webgraph_result.py`

- [ ] **Step 1: Write RED Rust round-trip tests**

Tests require duplicate/directed arcs, empty nodes, original adjacency order mapping, `.graph`, `.properties`, `.ef` and every mapping byte, random access to first/middle/last nodes, and corruption rejection.

- [ ] **Step 2: Verify RED**

Run: `cargo test --manifest-path tool/worldpack_webgraph_adapter/Cargo.toml --locked`

Expected: FAIL because the adapter is absent.

- [ ] **Step 3: Implement the pinned official WebGraph adapter**

Depend on the exact `webgraph-rs` commit, select the Apache-2.0 license option, run the registered BVGraph flag grid, build Elias–Fano offsets, and emit a JSON inventory of every persisted file. A separate clean Elias–Fano stream covers monotone offsets and neighbor IDs.

- [ ] **Step 4: Run GREEN Rust tests**

Run with a task-local `DYLD_LIBRARY_PATH` compatibility directory so the broken global Cargo/libgit2 link is not modified.

Expected: all adapter tests PASS.

- [ ] **Step 5: Run minimum and eligible full-graph stages**

Run: `uv run --project experiments/worldpack_official_completion python experiments/worldpack_official_completion/run_benchmark.py --stage webgraph-minimum`

Run: `uv run --project experiments/worldpack_official_completion python experiments/worldpack_official_completion/run_benchmark.py --stage webgraph-full`

Expected: full graph runs only for an exact strict minimum winner.

### Task 6: Implement WorldPack framing with TDD

**Files:**
- Create: `experiments/worldpack_official_completion/worldpack.py`
- Create: `experiments/worldpack_official_completion/tests/test_worldpack.py`
- Create: `experiments/worldpack_official_completion/tests/test_worldpack_corruption.py`

- [ ] **Step 1: Write RED container tests**

Tests specify the fixed header, append-only chunk header, earlier-only dependencies, codec identity, original/compressed lengths and hashes, atomic footer index, duplicate content references, bounded random read and fail-closed corruption behavior.

- [ ] **Step 2: Verify RED**

Run: `uv run --project experiments/worldpack_official_completion pytest experiments/worldpack_official_completion/tests/test_worldpack.py experiments/worldpack_official_completion/tests/test_worldpack_corruption.py -q`

Expected: FAIL because `worldpack.py` is absent.

- [ ] **Step 3: Implement the minimum writer/reader**

The writer accepts only already verified member artifacts, appends immutable chunks, fsyncs before footer publication, and records complete bytes. The reader validates bounds, dependency direction, hashes and codec identities before returning data.

- [ ] **Step 4: Verify GREEN**

Run the two focused pytest files again.

Expected: PASS, including every corruption vector.

### Task 7: Run minimum, 100 MB and complete WorldPack benchmarks

**Files:**
- Create: `experiments/worldpack_official_completion/run_benchmark.py`
- Create: `experiments/worldpack_official_completion/results/minimum.json`
- Create: `experiments/worldpack_official_completion/results/approximately-100mb.json`
- Create: `experiments/worldpack_official_completion/results/complete-project.json`
- Create: `experiments/worldpack_official_completion/evidence.json`

- [ ] **Step 1: Add RED result-schema tests**

Tests require ordered input identity, all source bytes, all archive bytes, per-member winner/fallback reason, exact restoration, SQLite integrity, random reads, peak RSS/temp bytes, command and environment identities.

- [ ] **Step 2: Run the minimum mixed stage**

Run: `uv run --project experiments/worldpack_official_completion python experiments/worldpack_official_completion/run_benchmark.py --stage worldpack-minimum`

Expected: exact restoration of one photo, one descriptor/keypoint/graph group, one PLY and metadata.

- [ ] **Step 3: Run the approximately 100 MB prefix**

Run: `uv run --project experiments/worldpack_official_completion python experiments/worldpack_official_completion/run_benchmark.py --stage worldpack-100mb`

Expected: exact restoration and a result containing the actual ordered input bytes; no nominal-size substitution.

- [ ] **Step 4: Run the complete frozen capture**

Run: `uv run --project experiments/worldpack_official_completion python experiments/worldpack_official_completion/run_benchmark.py --stage worldpack-complete`

Expected: every manifest file restored, every SHA equal, SQLite integrity `ok`, bounded random reads and complete persisted byte count.

- [ ] **Step 5: Persist compact evidence and delete only task-owned scratch**

Keep contracts, locks, result JSON, commands and hashes. Remove task-owned `/private/tmp/pw_worldpack_*` sources, build trees and large archives only after evidence references their immutable upstream commits and result hashes.

### Task 8: Final verification and evidence-only commit

**Files:**
- Modify: `openspec/changes/benchmark-worldpack-official-completion/tasks.md`
- Modify: `experiments/compression_fidelity_audit/inventory.json`
- Modify: `docs/research/2026-08-02-compression-official-fidelity-audit.md`

- [ ] **Step 1: Run deterministic verification**

Run focused pytest, native C++ tests, Rust tests, `flutter test --no-pub test/worldpack_official_completion_contract_test.dart`, `openspec validate benchmark-worldpack-official-completion`, `dvc status`, JSON parsing and `git diff --check` only on owned paths.

- [ ] **Step 2: Update classification from evidence**

Mark each route `faithful_official`, `faithful_subset`, `blocked`, or `failed-specific-mode` using the narrowest supported conclusion. WorldPack is `validated_internal`, never an official reproduction.

- [ ] **Step 3: Commit only owned implementation and evidence files**

Use explicit `git add` paths and `git commit --only -F`; do not stage, unstage, format, reset, stash or clean unrelated work.
