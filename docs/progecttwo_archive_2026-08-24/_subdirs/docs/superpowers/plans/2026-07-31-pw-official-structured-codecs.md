# PocketWorld Official Structured Codecs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure complete, strictly reversible Blosc2/B2ND and Parquet/Arrow representations against the frozen 50 MB ZPAQ baseline.

**Architecture:** A diagnostic-only Python harness reads the existing canonical logical dataset, maps the heavy COLMAP tables to typed arrays, delegates compression to unmodified official libraries, reconstructs the logical dataset, and persists a compact evidence record. Large inputs and outputs remain temporary and are deleted after verification.

**Tech Stack:** Python 3.11, uv offline lock, PyArrow 24.0.0, C-Blosc2 3.2.3 C API, SQLite, unittest.

---

### Task 1: Freeze the extended experiment

**Files:**
- Modify: `openspec/changes/benchmark-pw-compact-sfm-a/specs/pw-compact-sfm-a/spec.md`
- Modify: `experiments/pw_compact_sfm_a/experiment-contract.yaml`
- Create: `experiments/pw_official_structured_codecs/pyproject.toml`
- Create: `experiments/pw_official_structured_codecs/uv.lock`

- [ ] Record exact candidate versions, complete-byte accounting, forbidden lossy filters and the 27,349,412-byte gate.
- [ ] Materialize PyArrow 24.0.0 from the existing uv cache with network disabled.
- [ ] Record the wheel SHA-256 and Arrow runtime versions.

### Task 2: Prove the Parquet adapter contract by TDD

**Files:**
- Create: `experiments/pw_official_structured_codecs/tests/test_parquet_codec.py`
- Create: `experiments/pw_official_structured_codecs/pwcodecs/parquet_codec.py`
- Create: `experiments/pw_official_structured_codecs/pwcodecs/layout.py`

- [ ] Write a fixture test that imports `ParquetCodec`, encodes the existing pathological COLMAP fixture, decodes it, and requires equality plus logical SHA equality.
- [ ] Run the test and verify it fails because the adapter does not exist.
- [ ] Implement the smallest typed mapping using fixed-size-binary descriptors, bit-preserving NumPy float32 views, uint32 match columns, and a canonical manifest.
- [ ] Enable BYTE_STREAM_SPLIT for supported fixed-size-binary/float columns and DELTA_BINARY_PACKED for match integer columns; fail closed if requested encodings are absent from file metadata.
- [ ] Run the focused test and the pre-existing PWCSFMA suite.

### Task 3: Prove the Blosc2 adapter contract by TDD

**Files:**
- Create: `experiments/pw_official_structured_codecs/tests/test_blosc2_codec.py`
- Create: `experiments/pw_official_structured_codecs/pwcodecs/blosc2_codec.py`

- [ ] Freeze and inspect the real C-Blosc2 3.2.3 artifact; do not substitute another implementation.
- [ ] Write a fixture test requiring each declared reversible filter arm to round-trip the pathological fixture and reject every forbidden filter ID.
- [ ] Run the test and verify it fails before the adapter exists.
- [ ] Implement the minimal ctypes/C helper against the official B2ND/schunk API.
- [ ] Run the focused test and record the library runtime version.

### Task 4: Run the frozen host screen

**Files:**
- Create: `experiments/pw_official_structured_codecs/run_host_screen.py`
- Create: `experiments/pw_official_structured_codecs/tests/test_host_screen.py`
- Create: `experiments/pw_official_structured_codecs/results/host-screen-cap_1785297411166420.json`
- Create: `experiments/pw_official_structured_codecs/results/strategy-digest.md`

- [ ] Write a failing runner test requiring input length/SHA checks, complete file-byte accounting, exact decode, atomic result persistence and the registered stop verdict.
- [ ] Implement the runner and make the test pass.
- [ ] Obtain a read-only temporary copy of the exact phone input and verify its SHA before testing.
- [ ] Run Parquet and every available Blosc2 arm once; stop immediately on exactness failure.
- [ ] Compare every complete candidate against 30,388,236 bytes and apply the 27,349,412-byte continuation threshold.
- [ ] Persist package identities, commands, timings, peak RSS, archive sizes, checksums, exactness and verdict.

### Task 5: Verify and clean up

**Files:**
- Modify: `experiments/pw_official_structured_codecs/results/strategy-digest.md`

- [ ] Run all new tests and the existing PWCSFMA tests from a clean command.
- [ ] Re-read the result JSON and independently recompute its SHA-256.
- [ ] Remove the temporary database copy, candidate files, extracted libraries and virtual environment.
- [ ] Confirm only compact source, lock, JSON and Markdown evidence remain.

This aggregate workspace has no Git root, so the plan does not authorize a commit. No PocketWorld production repository or device container is modified.
