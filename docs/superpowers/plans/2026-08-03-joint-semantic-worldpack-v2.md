# Joint Semantic WorldPack v2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task. The user explicitly prohibited subagent delegation for this work.

**Goal:** Build and measure one exact two-photo cross-modal WorldPack v2 dependency group that faithfully implements every publicly recoverable stage of the published JPEG-collection method and stops rather than inventing missing stages.

**Architecture:** A read-only extractor selects one deterministic adjacent pair from the frozen complete capture and exposes exact JPEG coefficients plus shared pose, track, match, descriptor, and sparse-point context. A versioned predictor produces a root, global/local compensated prediction state, exact DCT residuals, frequency selectors, and integrity metadata. The incumbent photo bytes come from already persisted verified per-photo artifacts; unchanged shared semantic streams cancel from the minimum comparison and are never duplicated. The candidate must restore both original JPEG files byte-for-byte and be strictly smaller before an eight-photo plan is allowed.

**Tech Stack:** Python 3.11/uv test harness, C++17/libjpeg coefficient bridge, NumPy/OpenCV for deterministic host diagnostics, pinned ZPAQ 7.15 fallback, OpenSpec, DVC input identity, MLflow result metadata.

---

## File map

- Create `experiments/joint_semantic_worldpack_v2/experiment-contract.yaml`: frozen input, method, metrics, gates, and stop rules.
- Create `experiments/joint_semantic_worldpack_v2/input-manifest.yaml`: exact selected pair and all referenced context hashes.
- Create `experiments/joint_semantic_worldpack_v2/method-map.md`: equation/stage-to-code fidelity ledger and commercial-use boundary.
- Create `experiments/joint_semantic_worldpack_v2/evidence.json`: immutable upstream and local artifact evidence.
- Create `experiments/joint_semantic_worldpack_v2/semantic_slice.py`: read-only deterministic pair/context extraction.
- Create `experiments/joint_semantic_worldpack_v2/jpeg_collection_model.py`: prediction tree, compensation state, frequency selectors, and exact residual inversion.
- Create `experiments/joint_semantic_worldpack_v2/joint_group.py`: versioned framing, hashes, dependency validation, and byte accounting.
- Create `experiments/joint_semantic_worldpack_v2/run_minimum.py`: one-shot candidate runner referencing saved incumbent bytes.
- Create `experiments/joint_semantic_worldpack_v2/tests/`: focused unit, corruption, contract, and result tests.
- Reuse without modifying `experiments/cross_photo_lossless_potential/jpeg_coeff_tool.cpp` for exact JPEG coefficient extraction/restoration.
- Reuse without modifying `tool/zpaq_file_tool.cpp` and the pinned vendored ZPAQ source.

### Task 1: Freeze the published-method fidelity boundary

**Files:**
- Create: `experiments/joint_semantic_worldpack_v2/method-map.md`
- Create: `experiments/joint_semantic_worldpack_v2/evidence.json`
- Test: `experiments/joint_semantic_worldpack_v2/tests/test_method_map.py`

- [ ] **Step 1: Write the failing completeness test**

```python
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_method_map_names_every_required_stage_and_fidelity_status():
    text = (ROOT / "method-map.md").read_text(encoding="utf-8")
    for stage in (
        "feature-domain prediction structure",
        "global disparity compensation",
        "local disparity compensation",
        "frequency-domain adaptive prediction",
        "context-adaptive entropy coding",
        "exact JPEG binary reconstruction",
    ):
        assert stage in text
    assert "UNRESOLVED" not in text
```

- [ ] **Step 2: Run the test and confirm RED**

Run:

```bash
cd /Users/kaidongwang/Developer/pocketworld
python3 -m pytest experiments/joint_semantic_worldpack_v2/tests/test_method_map.py -q
```

Expected: FAIL because `method-map.md` does not exist.

- [ ] **Step 3: Write the evidence-backed method map**

For every listed stage record: publication/revision, section/equation/figure,
required inputs, deterministic output, decoder inverse, disclosed parameter,
code availability, dependency/license identity, and one status from
`faithful`, `faithful_with_declared_substitution`, or `blocked_missing_detail`.
The completeness test must accept `blocked_missing_detail` as a completed audit
state but the experiment contract must prohibit encoding through that stage.

The 2014 author manuscript may explain the precursor stages; it must be labeled
as a precursor. The 2016 TIP result and the 2015 SfM extension retain separate
identities. Do not copy more publication text than required to map the method.

- [ ] **Step 4: Adjust the test to reject only unclassified stages**

```python
import json


def test_every_stage_has_a_terminal_fidelity_status():
    evidence = json.loads((ROOT / "evidence.json").read_text())
    allowed = {
        "faithful",
        "faithful_with_declared_substitution",
        "blocked_missing_detail",
    }
    assert set(evidence["method_stages"]) == {
        "feature_prediction",
        "global_compensation",
        "local_compensation",
        "frequency_prediction",
        "entropy_coding",
        "jpeg_binary_reconstruction",
    }
    assert all(stage["status"] in allowed for stage in evidence["method_stages"].values())
```

- [ ] **Step 5: Run the method-map test GREEN**

Run the Step 2 command. Expected: `2 passed`.

- [ ] **Step 6: Stop if the transform is not reproducible or commercially admissible**

If a required prediction or inverse stage is `blocked_missing_detail`, write an
evidence-only result with `benchmark_status: blocked_fidelity`; do not implement
a heuristic under the paper's name. If only the entropy coder is blocked, a
declared ZPAQ substitution may proceed as an ablation, never as a faithful
bitstream reproduction.

- [ ] **Step 7: Commit only Task 1 files**

```bash
git add experiments/joint_semantic_worldpack_v2/method-map.md \
  experiments/joint_semantic_worldpack_v2/evidence.json \
  experiments/joint_semantic_worldpack_v2/tests/test_method_map.py
git commit -m "docs(compression): freeze joint archive method fidelity"
```

### Task 2: Freeze the minimum joint-unit contract and immutable input

**Files:**
- Create: `experiments/joint_semantic_worldpack_v2/experiment-contract.yaml`
- Create: `experiments/joint_semantic_worldpack_v2/input-manifest.yaml`
- Create: `experiments/joint_semantic_worldpack_v2/pyproject.toml`
- Create: `experiments/joint_semantic_worldpack_v2/uv.lock`
- Test: `experiments/joint_semantic_worldpack_v2/tests/test_contract.py`

- [ ] **Step 1: Write the RED contract test**

```python
from pathlib import Path
import yaml


ROOT = Path(__file__).resolve().parents[1]


def test_contract_never_reruns_saved_complete_baseline():
    contract = yaml.safe_load((ROOT / "experiment-contract.yaml").read_text())
    assert contract["baseline"]["original_source_bytes"] == 638_645_632
    assert contract["baseline"]["complete_persisted_bytes"] == 471_146_040
    assert contract["baseline"]["execution"] == "forbidden_reference_only"
    assert contract["scope"] == "host_only_two_photo_joint_unit"
    assert contract["phone_access"] is False
    assert contract["production_changes"] is False
```

- [ ] **Step 2: Run RED**

Run:

```bash
cd /Users/kaidongwang/Developer/pocketworld
python3 -m pytest experiments/joint_semantic_worldpack_v2/tests/test_contract.py -q
```

Expected: FAIL because the contract is absent.

- [ ] **Step 3: Freeze repository and input identities**

Record the current HEAD, a deterministic hash of the shared dirty diff without
altering it, capture `cap_1785512421333592`, the complete manifest SHA-256,
original JPEG archive manifest SHA-256, SQLite/PLY/pose hashes, pinned tool
revisions, seed `20260803`, and the selection rule:

```text
walk official_photo_bundle capture order; choose the first adjacent pair for
which both images have registered SfM poses and at least one verified two-view
match row; never inspect candidate compressed size during selection
```

The selected photo entries record original JPEG length/SHA, current verified
incumbent artifact length/SHA, frame IDs, and every referenced context file SHA.

- [ ] **Step 4: Register exact metrics and stop rules**

Primary metric is candidate photo dependency-group bytes versus the already
persisted incumbent bytes for the same root and child. Shared semantic streams
that already exist in both arms cancel; any new candidate-only selector,
mapping, model, or geometry representation counts. Gates require both JPEG
byte/SHA equality, all referenced semantic values equal, dependency-bounded
random reads, corruption rejection, and source unchanged.

- [ ] **Step 5: Run contract tests GREEN and verify the manifest against disk**

Expected: focused tests pass and every listed input length/SHA matches without
writing under the frozen capture root.

- [ ] **Step 6: Commit only Task 2 files**

```bash
git add experiments/joint_semantic_worldpack_v2/experiment-contract.yaml \
  experiments/joint_semantic_worldpack_v2/input-manifest.yaml \
  experiments/joint_semantic_worldpack_v2/pyproject.toml \
  experiments/joint_semantic_worldpack_v2/uv.lock \
  experiments/joint_semantic_worldpack_v2/tests/test_contract.py
git commit -m "test(compression): freeze joint archive minimum input"
```

### Task 3: Extract an exact cross-modal semantic slice

**Files:**
- Create: `experiments/joint_semantic_worldpack_v2/semantic_slice.py`
- Test: `experiments/joint_semantic_worldpack_v2/tests/test_semantic_slice.py`

- [ ] **Step 1: Write RED selection and identity tests**

```python
def test_selected_pair_is_deterministic_and_has_shared_geometry(frozen_capture):
    first = extract_minimum_slice(frozen_capture)
    second = extract_minimum_slice(frozen_capture)
    assert first.identity_sha256 == second.identity_sha256
    assert first.child.capture_ordinal == first.root.capture_ordinal + 1
    assert first.verified_match_count > 0
    assert first.shared_sparse_point_count > 0


def test_slice_carries_exact_training_values(frozen_capture):
    value = extract_minimum_slice(frozen_capture)
    assert all(len(descriptor) == 128 for descriptor in value.descriptors)
    assert value.logical_roundtrip_sha256() == value.identity_sha256
```

- [ ] **Step 2: Run RED**

Expected: import or symbol failure for `extract_minimum_slice`.

- [ ] **Step 3: Implement immutable dataclasses and readers**

Expose focused types:

```python
@dataclass(frozen=True)
class ExactPhoto:
    capture_ordinal: int
    frame_id: int
    name: str
    jpeg_path: Path
    jpeg_bytes: int
    jpeg_sha256: str
    incumbent_bytes: int
    incumbent_sha256: str


@dataclass(frozen=True)
class SemanticSlice:
    root: ExactPhoto
    child: ExactPhoto
    arkit_intrinsics_bits: tuple[int, ...]
    arkit_extrinsics_bits: tuple[int, ...]
    sfm_pose_bits: tuple[int, ...]
    descriptors: tuple[bytes, ...]
    match_records: tuple[tuple[int, int], ...]
    sparse_points_bits: tuple[tuple[int, int, int], ...]
    identity_sha256: str
```

Use read-only SQLite queries with explicit `ORDER BY`. Reconstruct archived JXL
members into task scratch, verify against the original JPEG manifest, and never
write into the capture.

- [ ] **Step 4: Run semantic-slice tests GREEN**

Expected: deterministic selection, positive verified geometry, exact logical
hash, and source root unchanged.

- [ ] **Step 5: Commit Task 3 files explicitly**

```bash
git add experiments/joint_semantic_worldpack_v2/semantic_slice.py \
  experiments/joint_semantic_worldpack_v2/tests/test_semantic_slice.py
git commit -m "test(compression): extract exact joint semantic slice"
```

### Task 4: Prove exact JPEG logical framing before prediction

**Files:**
- Create: `experiments/joint_semantic_worldpack_v2/jpeg_exact.py`
- Test: `experiments/joint_semantic_worldpack_v2/tests/test_jpeg_exact.py`
- Reuse: `experiments/cross_photo_lossless_potential/jpeg_coeff_tool.cpp`

- [ ] **Step 1: Write RED round-trip and rejection tests**

```python
def test_both_frozen_jpegs_restore_byte_for_byte(minimum_slice, jpeg_tool):
    for photo in (minimum_slice.root, minimum_slice.child):
        logical = extract_exact_jpeg(photo.jpeg_path, jpeg_tool)
        restored = restore_exact_jpeg(logical, jpeg_tool)
        assert restored == photo.jpeg_path.read_bytes()
        assert sha256(restored).hexdigest() == photo.jpeg_sha256


def test_truncated_or_progressive_unsupported_input_fails_closed(jpeg_tool):
    with pytest.raises(ExactJpegError):
        extract_exact_jpeg_bytes(b"\xff\xd8\xff", jpeg_tool)
```

- [ ] **Step 2: Run RED**

Expected: missing `jpeg_exact` module.

- [ ] **Step 3: Implement a narrow wrapper around the existing coefficient tool**

The wrapper records header/marker bytes, restart interval, component block
shapes, quantized `int16[block,64]` coefficients, source length, source SHA, and
tool hash. It validates the serialized logical frame by immediately restoring
through the same coefficient boundary. Unsupported JPEG processes fail closed;
there is no pixel decode/re-encode fallback.

- [ ] **Step 4: Run exact-JPEG tests GREEN**

Expected: both source files are byte-identical after restore and corrupt inputs
are rejected.

- [ ] **Step 5: Commit Task 4 files explicitly**

```bash
git add experiments/joint_semantic_worldpack_v2/jpeg_exact.py \
  experiments/joint_semantic_worldpack_v2/tests/test_jpeg_exact.py
git commit -m "test(compression): prove exact joint JPEG framing"
```

### Task 5: Implement only fidelity-approved prediction stages with TDD

**Files:**
- Create: `experiments/joint_semantic_worldpack_v2/jpeg_collection_model.py`
- Test: `experiments/joint_semantic_worldpack_v2/tests/test_jpeg_collection_model.py`

- [ ] **Step 1: Write RED inverse and determinism tests**

```python
def test_prediction_is_deterministic_and_exact(minimum_slice):
    first = encode_child(minimum_slice)
    second = encode_child(minimum_slice)
    assert first.canonical_bytes() == second.canonical_bytes()
    restored = decode_child(minimum_slice.root, first)
    assert restored == minimum_slice.child_exact_jpeg


def test_every_parent_is_backward_and_every_selector_is_bounded(encoded_child):
    assert encoded_child.parent_ordinal < encoded_child.child_ordinal
    assert set(encoded_child.frequency_selectors).issubset({0, 1})
    assert encoded_child.residual_count == encoded_child.target_coefficient_count
```

- [ ] **Step 2: Run RED**

Expected: missing `jpeg_collection_model` symbols.

- [ ] **Step 3: Implement the feature-domain parent record**

For two photos the root/child direction is fixed by capture order; compute and
persist the paper-mapped feature cost for audit. Use verified COLMAP matches and
exact keypoint/descriptor inputs. Do not choose direction based on compressed
bytes.

- [ ] **Step 4: Implement the approved global/local compensation state**

Use integer or explicitly specified fixed-point serialization for every fitted
parameter. Persist enough information to reproduce the exact coefficient
prediction on another decoder. Any host floating-point fitting happens only at
encode time; the decoder consumes the serialized deterministic representation.

- [ ] **Step 5: Implement frequency selectors and exact coefficient residuals**

For every target coefficient, reconstruct by checked integer addition:

```python
target = checked_int16(predicted + residual)
```

The selector cost is frozen before final size inspection. Header/marker bytes
remain separate exact streams. No quantized DCT coefficient is rounded,
discarded, or normalized.

- [ ] **Step 6: Run prediction tests GREEN**

Expected: deterministic candidate bytes, exact child coefficient/header
reconstruction, backward dependencies, and bounded selectors.

- [ ] **Step 7: Commit Task 5 files explicitly**

```bash
git add experiments/joint_semantic_worldpack_v2/jpeg_collection_model.py \
  experiments/joint_semantic_worldpack_v2/tests/test_jpeg_collection_model.py
git commit -m "test(compression): add exact collection prediction model"
```

### Task 6: Frame the complete minimum dependency group and reject corruption

**Files:**
- Create: `experiments/joint_semantic_worldpack_v2/joint_group.py`
- Test: `experiments/joint_semantic_worldpack_v2/tests/test_joint_group.py`

- [ ] **Step 1: Write RED complete-accounting tests**

```python
def test_complete_size_counts_every_decoder_dependency(group):
    assert group.complete_persisted_bytes == sum(
        member.header_bytes + member.payload_bytes for member in group.members
    ) + group.index_bytes + group.footer_bytes
    assert {m.kind for m in group.members} >= {
        "root_jpeg",
        "prediction_graph",
        "compensation_state",
        "frequency_selectors",
        "coefficient_residuals",
        "jpeg_side_information",
    }


@pytest.mark.parametrize("field", ["payload", "index", "dependency", "hash"])
def test_corruption_fails_before_output(valid_group_bytes, field):
    damaged = corrupt_registered_field(valid_group_bytes, field)
    with pytest.raises(JointGroupCorruption):
        JointGroupReader(damaged).read_photo(1)
```

- [ ] **Step 2: Run RED**

Expected: missing `joint_group` module.

- [ ] **Step 3: Implement immutable backward-only framing**

Use a new experiment magic/version, canonical little-endian integers, explicit
member kinds, logical ranges, transform/codec identity, original/payload SHA,
and CRC. The reader validates the entire dependency closure before returning a
JPEG. The first implementation may wrap each homogeneous payload in ZPAQ only
when ZPAQ is smaller than raw after all envelope bytes.

- [ ] **Step 4: Run group tests GREEN**

Expected: exact accounting and all registered corruptions rejected.

- [ ] **Step 5: Commit Task 6 files explicitly**

```bash
git add experiments/joint_semantic_worldpack_v2/joint_group.py \
  experiments/joint_semantic_worldpack_v2/tests/test_joint_group.py
git commit -m "test(compression): frame exact joint dependency group"
```

### Task 7: Execute the candidate once and issue a scoped verdict

**Files:**
- Create: `experiments/joint_semantic_worldpack_v2/run_minimum.py`
- Create: `experiments/joint_semantic_worldpack_v2/results/minimum.json`
- Test: `experiments/joint_semantic_worldpack_v2/tests/test_result.py`

- [ ] **Step 1: Write the RED result-contract test**

```python
def test_result_is_exact_complete_and_does_not_execute_baseline(result):
    assert result["baseline_execution"] == "reference_only"
    assert result["source_jpeg_count"] == 2
    assert result["jpeg_byte_equal"] is True
    assert result["jpeg_sha256_equal"] is True
    assert result["semantic_bits_and_order_equal"] is True
    assert result["corruption_rejected"] is True
    assert result["candidate_complete_bytes"] > 0
    assert result["incumbent_complete_bytes"] > 0
    assert result["winner"] in {"incumbent", "joint_semantic_v2"}
```

- [ ] **Step 2: Run all focused tests before the benchmark**

Run:

```bash
cd /Users/kaidongwang/Developer/pocketworld
experiments/worldpack_official_completion/.venv/bin/python -m pytest \
  experiments/joint_semantic_worldpack_v2/tests -q
```

Expected: all non-result tests PASS and only the absent-result test FAILS.

- [ ] **Step 3: Run only the candidate once**

Run:

```bash
cd /Users/kaidongwang/Developer/pocketworld
experiments/worldpack_official_completion/.venv/bin/python \
  experiments/joint_semantic_worldpack_v2/run_minimum.py \
  --contract experiments/joint_semantic_worldpack_v2/experiment-contract.yaml \
  --output experiments/joint_semantic_worldpack_v2/results/minimum.json
```

Expected terminal marker: `JOINT_MINIMUM_COMPLETE`. The runner must refuse if a
result already exists unless an explicit diagnostic output path is supplied; it
must never invoke the incumbent encoder.

- [ ] **Step 4: Run all focused tests GREEN**

Expected: every focused test passes, both JPEGs restore exactly, semantic bits
and order match, corruption is rejected, and the result records complete bytes.

- [ ] **Step 5: Apply the preregistered decision**

If `candidate_complete_bytes < incumbent_complete_bytes`, record
`winner: joint_semantic_v2` and authorize only a new eight-photo design. If not,
record `winner: incumbent` and stop this registered configuration. Never infer
that every cross-photo collection method has failed.

- [ ] **Step 6: Commit only owned result and runner files**

```bash
git add experiments/joint_semantic_worldpack_v2/run_minimum.py \
  experiments/joint_semantic_worldpack_v2/results/minimum.json \
  experiments/joint_semantic_worldpack_v2/tests/test_result.py
git commit -m "test(compression): record joint semantic minimum verdict"
```

### Task 8: Final deterministic verification

**Files:**
- Verify only; no production files.

- [ ] **Step 1: Validate OpenSpec strictly**

```bash
cd /Users/kaidongwang/Developer/pocketworld
openspec validate benchmark-joint-semantic-worldpack-v2 --strict
```

Expected: valid.

- [ ] **Step 2: Run focused test suite twice without rerunning the benchmark**

The tests read the persisted result; they do not execute encoders. Both runs
must pass identically.

- [ ] **Step 3: Inspect repository scope**

```bash
git status --short
git diff --stat HEAD -- experiments/joint_semantic_worldpack_v2 \
  openspec/changes/benchmark-joint-semantic-worldpack-v2 \
  docs/superpowers/specs/2026-08-03-joint-semantic-worldpack-v2-design.md \
  docs/superpowers/plans/2026-08-03-joint-semantic-worldpack-v2.md
```

Confirm no production Dart, Swift, Objective-C++, vendor library, bundle, or
phone state was modified.

- [ ] **Step 4: Report the scoped result**

Report input hashes, exactness evidence, incumbent/candidate complete bytes,
winner, fidelity deviations, license status, peak RSS/temp, and the only next
authorized action. Do not convert the pair result into a projected complete-
project ratio.
