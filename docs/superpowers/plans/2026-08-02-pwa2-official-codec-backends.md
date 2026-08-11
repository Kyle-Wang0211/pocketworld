# PWA2 Official Codec Backends Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Benchmark pinned official OpenZL, Pcodec, and C-Blosc2 backends on the same exact PWA2 logical archive.

**Architecture:** A host-only adapter packs the frozen SQLite into deterministic PWA2 members, offers each compatible payload to a pinned official codec, retains the smallest byte-exact candidate against ZPAQ, writes a fully measured indexed container, then decodes and reuses PWA2 logical verification. Upstream sources and build products remain temporary and are identified by release commit and license hash.

**Tech Stack:** C++17, SQLite, CommonCrypto SHA-256, ZPAQ 7.15, OpenZL v0.2.0, Pcodec v1.0.2 Rust C ABI, C-Blosc2 v3.3.0, Bash, Dart contract tests, OpenSpec, DVC, MLflow.

---

### Task 1: Freeze the experiment

**Files:**
- Create: `openspec/changes/benchmark-pwa2-official-codec-backends/`
- Create: `experiments/pwa2_official_codec_backends/experiment-contract.yaml`
- Create: `experiments/pwa2_official_codec_backends/input-manifest.yaml`

- [ ] Record input, baseline, gate, upstream revisions, license hashes, hardware,
      complete-byte accounting, exactness gates, and stop rules.
- [ ] Run `openspec validate benchmark-pwa2-official-codec-backends --strict`;
      expect `Change ... is valid`.
- [ ] Verify the immutable input size, SHA-256, and SQLite integrity before any
      codec build.

### Task 2: Add the backend contract test first

**Files:**
- Create: `test/pwa2_official_codec_backends_contract_test.dart`
- Create: `tool/pwa2_official_codec_backend_test.cpp`
- Create: `tool/run_pwa2_official_codec_backend_tests.sh`

- [ ] Write a Dart test that requires all three pinned revisions, exact license
      hashes, ZPAQ fallback, complete index accounting, lossy-filter rejection,
      no production/phone references, and one-run stop behavior.
- [ ] Run the Dart test before creating the runner; expect failure because
      `tool/run_pwa2_official_codec_backends_bench.sh` does not exist.
- [ ] Write a native fixture that calls the wished-for codec interface for
      `u8`, `u32`, and `f32` sequences, requires exact bytes after decode, then
      flips one payload byte and requires rejection.
- [ ] Run it before implementing the interface; expect link/compile failure for
      missing backend functions.

### Task 3: Build and verify pinned upstreams

**Files:**
- Create: `tool/run_pwa2_official_codec_backends_bench.sh`

- [ ] Clone each exact release into a fresh `/private/tmp` directory and reject
      any HEAD or license hash mismatch.
- [ ] Initialize only OpenZL's pinned submodules and compile its release CLI and
      numeric example; run one official example round-trip.
- [ ] Install a pinned Rust toolchain under `/private/tmp` if the host Cargo is
      unusable, then build Pcodec `pco_c` with `Cargo.lock`; run its C test.
- [ ] Build C-Blosc2 with only lossless built-in codecs required by the arm and
      run its frame round-trip test.

### Task 4: Implement the common exact backend interface

**Files:**
- Create: `tool/pwa2_official_codec_backend.h`
- Create: `tool/pwa2_official_codec_backend.cpp`
- Modify: `tool/pwa2_official_codec_backend_test.cpp`

- [ ] Implement `Encode`, `Decode`, codec identity, parameter serialization,
      expansion guard, and SHA-verified decode for ZPAQ, Pcodec, OpenZL, and
      C-Blosc2 adapters.
- [ ] Expose only the upstream-supported data types. Reject unsupported widths
      instead of reinterpretation or quantization.
- [ ] Run the native fixture and focused Dart contract until green.

### Task 5: Implement complete PWA2 candidate accounting

**Files:**
- Create: `tool/pwa2_official_codec_backends_bench.cpp`
- Modify: `tool/run_pwa2_official_codec_backends_bench.sh`

- [ ] Pack the frozen source with `pwa2_sqlite_logical_archive` and parse only
      the documented exact PWA2 block formats.
- [ ] For each arm, offer compatible streams to its candidate codecs and ZPAQ,
      decode every candidate immediately, and choose the smallest exact bytes.
- [ ] Write one indexed container whose metadata and checksums are included in
      the final size; reopen it and reject bounds, codec, or checksum errors.
- [ ] Fully decode selected members, call `VerifyDatabase`, materialize SQLite,
      compare logical contents, test first/middle/last descriptors, run
      `PRAGMA integrity_check`, and rehash the unchanged source.

### Task 6: Run the staged benchmark once

**Files:**
- Create: `experiments/pwa2_official_codec_backends/results/*.json`

- [ ] Run one real descriptor, keypoint, and match member through each backend;
      skip only a backend that expands every compatible sample.
- [ ] Run each remaining complete arm exactly once on the frozen input.
- [ ] Record complete bytes, per-codec selected bytes/counts, exactness flags,
      elapsed time, RSS, temporary bytes, source/container hashes, and verdict.

### Task 7: Final verification and evidence

**Files:**
- Create: `experiments/pwa2_official_codec_backends/dvc.yaml`
- Create: `experiments/pwa2_official_codec_backends/dvc.lock`
- Create: `experiments/pwa2_official_codec_backends/mlflow.db`

- [ ] Run focused native tests, Dart contract tests, strict OpenSpec validation,
      DVC input status, deterministic result-schema checks, and inspect only
      newly owned files.
- [ ] Log one MLflow run per valid/blocked arm without duplicating the result
      JSON as a second metric authority.
- [ ] Stop before all phone work unless an arm is at most `111,961,726` bytes.

