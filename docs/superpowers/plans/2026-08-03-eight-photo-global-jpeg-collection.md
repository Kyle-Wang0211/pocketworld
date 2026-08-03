# Eight-photo Global JPEG Collection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Measure one strict-lossless eight-photo collection codec using a global feature tree, hybrid DCT prediction, and typed ZPAQ streams without rerunning saved JXL.

**Architecture:** A read-only extractor freezes the first eight archived photos and their complete COLMAP relationship graph. A deterministic codec predicts exact JPEG coefficients along a maximum spanning tree, splits residuals and side information into typed streams, and stores a versioned checksummed dependency group whose decoder restores original JPEG bytes.

**Tech Stack:** Python 3.11, NumPy, SQLite, pytest, PyYAML, existing libjpeg coefficient tool, pinned ZPAQ 7.15 method 5, DVC, MLflow, OpenSpec.

---

### Task 1: Freeze the experiment

**Files:**
- Create: `experiments/eight_photo_global_jpeg_collection/input-manifest.yaml`
- Create: `experiments/eight_photo_global_jpeg_collection/experiment-contract.yaml`
- Create: `experiments/eight_photo_global_jpeg_collection/evidence.json`
- Create: `experiments/eight_photo_global_jpeg_collection/pyproject.toml`

- [ ] **Step 1: Record immutable identities**

Write the eight photo names, original/JXL byte counts and SHA-256 values, all
context-file hashes, repository identity, 28-edge graph summary, unchanged
18,453,828-byte reference, 15,618,497-byte research target, and candidate run
count of one.

- [ ] **Step 2: Record claim boundaries**

Set `faithful_microsoft_2016: false`, `faithful_fdbm_2024: false`,
`phone_access: false`, and `production_changes: false`; name every declared
substitution and source URL.

- [ ] **Step 3: Validate OpenSpec**

Run: `openspec validate benchmark-eight-photo-global-jpeg-collection --strict`

Expected: `Change 'benchmark-eight-photo-global-jpeg-collection' is valid`.

- [ ] **Step 4: Commit only owned documentation**

Run explicit `git add` paths followed by `git commit --only` for the new design,
plan, OpenSpec, and experiment metadata. Do not include existing staged files.

### Task 2: Extract the collection graph with TDD

**Files:**
- Create: `experiments/eight_photo_global_jpeg_collection/tests/test_collection_slice.py`
- Create: `experiments/eight_photo_global_jpeg_collection/collection_slice.py`

- [ ] **Step 1: Write the failing graph test**

```python
def test_maximum_tree_uses_every_node_once():
    edges = [Edge(0, 1, 9, 3), Edge(1, 2, 8, 2), Edge(0, 2, 1, 1)]
    tree = maximum_feature_tree((0, 1, 2), edges, {0: 30, 1: 20, 2: 10})
    assert tree.root == 1
    assert {(edge.parent, edge.child) for edge in tree.edges} == {(1, 0), (1, 2)}
```

- [ ] **Step 2: Verify RED**

Run: `uv run pytest tests/test_collection_slice.py -q`

Expected: FAIL because `collection_slice` does not exist.

- [ ] **Step 3: Implement deterministic extraction and Kruskal tree**

Implement immutable `Photo`, `Edge`, `CollectionSlice`, and `PredictionTree`
records, frozen ordinal selection, SQLite immutable reads, descriptor-distance
tie breaking, and deterministic tree orientation.

- [ ] **Step 4: Verify GREEN**

Run: `uv run pytest tests/test_collection_slice.py -q`

Expected: all graph tests pass without reading or encoding real JPEG payloads.

### Task 3: Implement exact hybrid coefficient prediction with TDD

**Files:**
- Create: `experiments/eight_photo_global_jpeg_collection/tests/test_hybrid_predictor.py`
- Create: `experiments/eight_photo_global_jpeg_collection/hybrid_predictor.py`

- [ ] **Step 1: Write failing exact inversion tests**

```python
def test_residual_restores_every_coefficient_bit():
    parent = np.array([[3, -2, 0, 7], [4, -1, 2, 8]], dtype=np.int16)
    child = np.array([[4, -2, 1, 6], [5, 0, 2, 9]], dtype=np.int16)
    encoded = encode_component(parent, child, synthetic_geometry())
    restored = decode_component(parent, encoded)
    assert restored.dtype == np.int16
    assert restored.tobytes() == child.tobytes()
```

Add separate tests for stable ties, fixed-point affine rounding, local motion,
left/top intra modes, and overflow rejection.

- [ ] **Step 2: Verify RED**

Run: `uv run pytest tests/test_hybrid_predictor.py -q`

Expected: FAIL because the predictor API is missing.

- [ ] **Step 3: Implement minimal deterministic predictor**

Implement integer Q20 affine parameters, homography/local candidate locations,
bounded low-frequency search, five stable predictor modes, per-frequency choice,
signed int16 residuals, and exact checked inverse.

- [ ] **Step 4: Verify GREEN**

Run: `uv run pytest tests/test_hybrid_predictor.py -q`

Expected: all predictor tests pass and the restored byte buffer equals input.

### Task 4: Implement typed streams and archive with TDD

**Files:**
- Create: `experiments/eight_photo_global_jpeg_collection/tests/test_collection_archive.py`
- Create: `experiments/eight_photo_global_jpeg_collection/collection_archive.py`

- [ ] **Step 1: Write failing framing tests**

```python
def test_archive_counts_and_authenticates_every_stream(tmp_path):
    archive = build_archive(synthetic_group(), identity_codec)
    assert archive.persisted_bytes == len(archive.payload)
    assert set(archive.stream_sizes) == REQUIRED_STREAMS
    damaged = bytearray(archive.payload)
    damaged[-1] ^= 1
    with pytest.raises(ArchiveError, match="digest"):
        decode_archive(bytes(damaged), identity_codec)
```

- [ ] **Step 2: Verify RED**

Run: `uv run pytest tests/test_collection_archive.py -q`

Expected: FAIL because archive framing is missing.

- [ ] **Step 3: Implement versioned typed framing**

Implement zero-run/zigzag residual tokens, luma/chroma DC/low/high bands,
separate graph/model/mode/motion/header streams, per-stream raw fallback,
length tables, SHA-256 digests, dependency paths, and strict bounds checking.

- [ ] **Step 4: Verify GREEN**

Run: `uv run pytest tests/test_collection_archive.py -q`

Expected: framing, byte accounting, dependency, and corruption tests pass.

### Task 5: Implement and freeze the one-shot runner

**Files:**
- Create: `experiments/eight_photo_global_jpeg_collection/tests/test_run_once.py`
- Create: `experiments/eight_photo_global_jpeg_collection/run_once.py`
- Create: `experiments/eight_photo_global_jpeg_collection/dvc.yaml`

- [ ] **Step 1: Write the failing run-control test**

```python
def test_runner_refuses_a_second_real_result(tmp_path):
    marker = tmp_path / "result.json"
    marker.write_text("{}")
    with pytest.raises(RunControlError, match="already exists"):
        assert_real_run_available(marker)
```

- [ ] **Step 2: Verify RED**

Run: `uv run pytest tests/test_run_once.py -q`

Expected: FAIL because the one-shot guard is missing.

- [ ] **Step 3: Implement the runner**

Build the existing coefficient tool, restore each source JPEG only in task
scratch, reverify all hashes, encode in tree dependency order, run pinned ZPAQ
once per typed stream, decode all members, compare bytes/SHA, inject registered
corruptions, write result atomically, and log MLflow/DVC identities. Abort if a
result already exists.

- [ ] **Step 4: Verify all focused tests before real data**

Run: `uv run pytest -q`

Expected: all tests pass; no `results/eight-photo.json` exists.

### Task 6: Execute once and adjudicate

**Files:**
- Create: `experiments/eight_photo_global_jpeg_collection/results/eight-photo.json`
- Create: `experiments/eight_photo_global_jpeg_collection/results/eight-photo.pwjc.dvc`
- Modify: `openspec/changes/benchmark-eight-photo-global-jpeg-collection/tasks.md`

- [ ] **Step 1: Reverify the contract and source hashes**

Run: `uv run python run_once.py --preflight-only`

Expected: all identities match, saved JXL is referenced only, candidate runs 0.

- [ ] **Step 2: Run the real candidate once**

Run: `uv run python run_once.py`

Expected: one result containing complete persisted bytes, exactness for eight
JPEGs, per-stream sizes, graph, dependency bounds, corruption results, elapsed
time, peak RSS, and a saved-JXL/31%-target verdict.

- [ ] **Step 3: Verify without rerunning**

Run: `uv run pytest -q && openspec validate benchmark-eight-photo-global-jpeg-collection --strict && dvc status`

Expected: tests pass, OpenSpec valid, and DVC reports data and pipelines current.

- [ ] **Step 4: Commit only owned result files**

Use explicit paths with `git add` and `git commit --only`. Never include the six
pre-existing staged DVC files or any unrelated dirty production source.

