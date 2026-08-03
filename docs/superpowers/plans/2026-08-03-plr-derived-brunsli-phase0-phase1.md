# PLR-Derived Brunsli Phase 0/1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> **Execution choice for this task:** The user explicitly requires inline execution without subagents. Use `executing-plans` in the current shared dirty tree, preserve every unrelated change, and commit only explicit paths owned by this plan.

**Goal:** Produce a reproducible Mac-only Phase 0/1 experiment that freezes all identities and accounting rules, verifies the two immutable JPEG inputs, and proves that unmodified pinned Brunsli can separate exact-JPEG reconstruction state from a separately stored coefficient payload and restore both source JPEGs byte for byte.

**Architecture:** A small Python package owns contracts, SHA-256 input verification, model-storage accounting, break-even math, and result JSON. A standalone C++ command links the pinned Brunsli source and uses its internal section serializer to store signature/header/internals/metadata/quantization without DC/AC sections; coefficients are stored in a separately checksummed little-endian payload. Phase 0 records a raw provisional model upper bound and reserves final model/CDF evidence for the trained artifact; Phase 1 must pass before any neural training plan starts.

**Tech Stack:** Python 3.11, `uv`, pytest, PyYAML, DVC, MLflow, C++17, CMake, Google Brunsli v0.1, CommonCrypto SHA-256, Zstandard 1.5.7, ZPAQ 7.15.

---

### Task 1: Freeze the executable contract and close documentation drift

**Files:**
- Modify: `docs/superpowers/specs/2026-08-03-plr-derived-brunsli-two-photo-design.md`
- Modify: `docs/research/2026-08-03-shared-model-accounting-scale-revision.md`
- Create: `openspec/changes/benchmark-plr-derived-brunsli-two-photo/proposal.md`
- Create: `openspec/changes/benchmark-plr-derived-brunsli-two-photo/design.md`
- Create: `openspec/changes/benchmark-plr-derived-brunsli-two-photo/specs/plr-derived-brunsli-two-photo/spec.md`
- Create: `openspec/changes/benchmark-plr-derived-brunsli-two-photo/tasks.md`

- [ ] **Step 1: Record the provisional/final model timing rule**

Write the following normative split into both durable documents:

```text
provisional_model_raw_upper_bound_bytes = complete raw bytes of the frozen,
untrained deployment artifact; untrained Zstd/ZPAQ sizes are diagnostic only.
final_M = minimum complete persisted bytes from the unchanged raw/Zstd/ZPAQ
candidate set rerun on the final trained deployment artifact before Phase 4.
Only final_M may enter the terminal comparison.
```

- [ ] **Step 2: Align terminal states and the reachable-loss product branch**

Require `blocked_upstream_exact_container` in both documents. State that
`loser_at_141_but_reachable_within_scope2` does not authorize automatic
production codec switching; that policy requires a separate product contract.

- [ ] **Step 3: Write the OpenSpec requirements**

The new spec must contain executable scenarios for these exact requirements:

```markdown
### Requirement: Frozen source and upstream identities
### Requirement: Provisional and final model accounting are distinct
### Requirement: Fixed exact model-storage candidates
### Requirement: Scope-2 break-even reachability
### Requirement: Brunsli exact-container fallback is unmodified and bounded
### Requirement: Coefficients and reconstruction state are physically separate
### Requirement: Both source JPEG files restore byte for byte
### Requirement: Corrupt or incomplete payloads fail closed
### Requirement: Phase 1 success does not authorize training, phone, or production
```

- [ ] **Step 4: Validate OpenSpec**

Run:

```bash
openspec validate benchmark-plr-derived-brunsli-two-photo
```

Expected: the change is valid with zero errors.

- [ ] **Step 5: Commit the documentation unit**

```bash
git add docs/superpowers/specs/2026-08-03-plr-derived-brunsli-two-photo-design.md \
  docs/research/2026-08-03-shared-model-accounting-scale-revision.md \
  docs/superpowers/plans/2026-08-03-plr-derived-brunsli-phase0-phase1.md \
  openspec/changes/benchmark-plr-derived-brunsli-two-photo/proposal.md \
  openspec/changes/benchmark-plr-derived-brunsli-two-photo/design.md \
  openspec/changes/benchmark-plr-derived-brunsli-two-photo/specs/plr-derived-brunsli-two-photo/spec.md \
  openspec/changes/benchmark-plr-derived-brunsli-two-photo/tasks.md
git commit --only \
  docs/superpowers/specs/2026-08-03-plr-derived-brunsli-two-photo-design.md \
  docs/research/2026-08-03-shared-model-accounting-scale-revision.md \
  docs/superpowers/plans/2026-08-03-plr-derived-brunsli-phase0-phase1.md \
  openspec/changes/benchmark-plr-derived-brunsli-two-photo/proposal.md \
  openspec/changes/benchmark-plr-derived-brunsli-two-photo/design.md \
  openspec/changes/benchmark-plr-derived-brunsli-two-photo/specs/plr-derived-brunsli-two-photo/spec.md \
  openspec/changes/benchmark-plr-derived-brunsli-two-photo/tasks.md \
  -m "docs(compression): freeze PLR-derived Phase 0 and 1"
```

The actual command must expand the seven paths; it must not use `git add -A`,
`git add -u`, or `commit -a`.

### Task 2: Create the reproducible experiment package and frozen identities

**Files:**
- Create: `experiments/plr_derived_brunsli_two_photo/pyproject.toml`
- Create: `experiments/plr_derived_brunsli_two_photo/uv.lock`
- Create: `experiments/plr_derived_brunsli_two_photo/experiment-contract.yaml`
- Create: `experiments/plr_derived_brunsli_two_photo/input-manifest.yaml`
- Create: `experiments/plr_derived_brunsli_two_photo/dvc.yaml`
- Create: `experiments/plr_derived_brunsli_two_photo/.dvc/config`
- Create: `experiments/plr_derived_brunsli_two_photo/.dvc/.gitignore`
- Create: `experiments/plr_derived_brunsli_two_photo/.dvcignore`
- Create: `experiments/plr_derived_brunsli_two_photo/pw_plr/__init__.py`
- Create: `experiments/plr_derived_brunsli_two_photo/tests/test_contract.py`

- [ ] **Step 1: Write the failing contract test**

Create `tests/test_contract.py` with assertions for the exact two filenames,
sizes, SHA-256 values, formal count 141, approved range 93–300, the three model
storage candidates, both Brunsli revisions, `baseline_state:
not_yet_measured`, and forbidden phone/production/full-project actions.

```python
from pathlib import Path
import yaml

ROOT = Path(__file__).resolve().parents[1]


def test_contract_freezes_all_decision_inputs() -> None:
    contract = yaml.safe_load((ROOT / "experiment-contract.yaml").read_text())
    assert contract["formal_project_photo_count"] == 141
    assert contract["approved_scope_photo_count"] == {"min": 93, "max": 300}
    assert contract["baseline"]["state"] == "not_yet_measured"
    assert contract["model_accounting"]["storage_candidates"] == [
        "raw",
        "zstd-1.5.7-level-22",
        "zpaq-7.15-method-5",
    ]
    assert contract["brunsli"]["primary_commit"] == "8a0e9b8ca2e3e089731c95a1da7ce8a3180e667c"
    assert contract["brunsli"]["fallback_commit"] == "c9128f43994c1ca830dd079777d85f16736d6ba7"
    assert contract["run_control"] == {
        "host": "macos-apple-silicon",
        "phone": "forbidden",
        "production": "forbidden",
        "full_project": "forbidden_before_two_photo_win",
        "subagents": "forbidden_by_user",
    }
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
cd experiments/plr_derived_brunsli_two_photo
uv run --no-project python -m pytest tests/test_contract.py -q
```

Expected: FAIL because the contract/package does not exist yet, not because of
a Python syntax error.

- [ ] **Step 3: Add the minimal package and immutable YAML files**

Use Python 3.11 with only `pytest>=8.4,<9` and `PyYAML>=6.0,<7` in the first
lock. Record repository HEAD `ee99c76` as the starting accepted design identity,
the two absolute source paths under
`device_captures/analysis_cap_1779777762841797/photos_highres/`, and the exact
source bytes/SHA values from the design. The contract must state that later
dirty-tree identity is recorded as a manifest rather than inferred from HEAD.

- [ ] **Step 4: Lock and rerun GREEN**

Run:

```bash
cd experiments/plr_derived_brunsli_two_photo
uv lock
uv run pytest tests/test_contract.py -q
```

Expected: one passing test.

- [ ] **Step 5: Initialize experiment-local DVC without data upload**

Run:

```bash
cd experiments/plr_derived_brunsli_two_photo
dvc init --subdir --no-scm
```

Configure no remote. `dvc.yaml` must define local stages for input verification,
Phase 0 accounting, and Phase 1 exact-container output; large files remain
outside Git and are identified by hashes.

### Task 3: Implement model accounting and reachability with TDD

**Files:**
- Create: `experiments/plr_derived_brunsli_two_photo/pw_plr/model_accounting.py`
- Create: `experiments/plr_derived_brunsli_two_photo/tests/test_model_accounting.py`

- [ ] **Step 1: Write failing tests for exact integer accounting**

```python
from pw_plr.model_accounting import (
    choose_final_model_storage,
    evaluate_break_even,
    provisional_raw_upper_bound,
)


def test_provisional_upper_bound_uses_raw_not_untrained_compressed_size() -> None:
    assert provisional_raw_upper_bound(raw_complete_bytes=60_000_000,
                                       zstd_complete_bytes=58_000_000,
                                       zpaq_complete_bytes=57_000_000) == 60_000_000


def test_final_m_selects_smallest_exact_registered_candidate() -> None:
    result = choose_final_model_storage({
        "raw": (60_000_000, True),
        "zstd-1.5.7-level-22": (57_000_000, True),
        "zpaq-7.15-method-5": (55_000_000, True),
    })
    assert result.codec == "zpaq-7.15-method-5"
    assert result.complete_persisted_bytes == 55_000_000


def test_non_exact_model_storage_candidate_is_ineligible() -> None:
    result = choose_final_model_storage({
        "raw": (60_000_000, True),
        "zstd-1.5.7-level-22": (10_000_000, False),
        "zpaq-7.15-method-5": (55_000_000, True),
    })
    assert result.codec == "zpaq-7.15-method-5"


def test_break_even_is_verified_and_reachable_at_300() -> None:
    result = evaluate_break_even(jxl_bytes=1_000, stream_bytes=600,
                                 final_model_bytes=59_800,
                                 formal_photo_count=141,
                                 approved_max_photo_count=300)
    assert result.break_even_photo_count == 300
    assert result.reachable_under_approved_scope is True
    assert result.wins_at_formal_count is False
    assert result.verdict == "loser_at_141_but_reachable_within_scope2"


def test_break_even_above_300_is_an_unreachable_loss() -> None:
    result = evaluate_break_even(jxl_bytes=1_000, stream_bytes=600,
                                 final_model_bytes=60_000,
                                 formal_photo_count=141,
                                 approved_max_photo_count=299)
    assert result.break_even_photo_count == 301
    assert result.reachable_under_approved_scope is False
    assert result.verdict == "loser_at_141_break_even_unreachable_scope2"


def test_nonpositive_stream_headroom_can_never_be_rescued() -> None:
    result = evaluate_break_even(jxl_bytes=1_000, stream_bytes=1_000,
                                 final_model_bytes=1,
                                 formal_photo_count=141,
                                 approved_max_photo_count=300)
    assert result.break_even_photo_count is None
    assert result.verdict == "loser_stream_before_model_accounting"
```

- [ ] **Step 2: Run and verify RED**

Run `uv run pytest tests/test_model_accounting.py -q`.

Expected: import failure for missing `pw_plr.model_accounting`.

- [ ] **Step 3: Implement the minimal immutable result types and formulas**

Use integer ceiling division only:

```python
def ceil_div(numerator: int, denominator: int) -> int:
    if numerator < 0 or denominator <= 0:
        raise ValueError("ceil_div requires numerator >= 0 and denominator > 0")
    return (numerator + denominator - 1) // denominator


def provisional_raw_upper_bound(*, raw_complete_bytes: int,
                                zstd_complete_bytes: int,
                                zpaq_complete_bytes: int) -> int:
    del zstd_complete_bytes, zpaq_complete_bytes
    if raw_complete_bytes <= 0:
        raise ValueError("raw model artifact must be non-empty")
    return raw_complete_bytes
```

`evaluate_break_even` must implement `H = J - B`, the `H <= 0` and `H == 1`
edges, `ceil(2*M/(H-1))`, the `N-1`/`N` minimality checks, formal count 141,
and reachability at 300.

- [ ] **Step 4: Run GREEN and the full package tests**

Run:

```bash
uv run pytest tests/test_model_accounting.py -q
uv run pytest -q
```

Expected: all current tests pass.

### Task 4: Implement immutable input verification with TDD

**Files:**
- Create: `experiments/plr_derived_brunsli_two_photo/pw_plr/input_identity.py`
- Create: `experiments/plr_derived_brunsli_two_photo/tests/test_input_identity.py`
- Create: `experiments/plr_derived_brunsli_two_photo/run_verify_inputs.py`

- [ ] **Step 1: Write failing tests**

Tests must create temporary files and prove exact success, byte-length failure,
SHA mismatch, duplicate role rejection, and ordered-manifest preservation. The
public API is:

```python
verify_inputs(manifest_path: Path) -> tuple[VerifiedInput, ...]
```

`VerifiedInput` contains `role`, `path`, `bytes`, and `sha256`.

- [ ] **Step 2: Run and verify RED**

Run `uv run pytest tests/test_input_identity.py -q`.

Expected: import failure for missing `pw_plr.input_identity`.

- [ ] **Step 3: Implement streaming SHA-256 and fail-closed validation**

Read files in 1 MiB chunks. Reject missing files, non-files, duplicate roles,
nonpositive registered sizes, size mismatch, and hash mismatch. Never copy or
modify the source JPEG files.

- [ ] **Step 4: Run GREEN and verify the real frozen pair once**

Run:

```bash
uv run pytest tests/test_input_identity.py -q
uv run python run_verify_inputs.py \
  --manifest input-manifest.yaml \
  --output results/input-verification.json
```

Expected: two inputs in A/B order with exact sizes 2,995,750 and 3,112,949 and
the registered SHA-256 values.

### Task 5: Build the pinned Brunsli exact-container adapter with TDD

**Files:**
- Create: `experiments/plr_derived_brunsli_two_photo/native/CMakeLists.txt`
- Create: `experiments/plr_derived_brunsli_two_photo/native/brunsli_side_adapter.cc`
- Create: `experiments/plr_derived_brunsli_two_photo/scripts/fetch_build_brunsli.sh`
- Create: `experiments/plr_derived_brunsli_two_photo/pw_plr/brunsli_phase1.py`
- Create: `experiments/plr_derived_brunsli_two_photo/tests/test_brunsli_phase1.py`
- Create: `experiments/plr_derived_brunsli_two_photo/run_phase1.py`

- [ ] **Step 1: Write the failing Python integration test**

The test invokes an absent adapter with a generated tiny valid JPEG fixture and
asserts that `extract` creates two nonempty files, `restore` reproduces every
source byte, and truncated/bit-flipped side or coefficient payloads exit
nonzero without creating a restored JPEG.

Run `uv run pytest tests/test_brunsli_phase1.py -q`.

Expected: FAIL because the adapter binary is absent.

- [ ] **Step 2: Fetch and build only immutable upstream revisions**

`fetch_build_brunsli.sh` accepts `--revision v0.1` or `--revision master`, maps
them to the two frozen commit hashes, clones `https://github.com/google/brunsli`
under a scratch directory, initializes its exact submodules, verifies HEAD,
and configures with:

```bash
cmake -S "$source" -B "$build" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "$build" --target pw_brunsli_side_adapter -j 8
```

No upstream `.cc` or `.h` file may be edited.

- [ ] **Step 3: Implement the side/coefficient split**

The adapter must:

1. parse with `ReadJpeg(..., JPEG_READ_ALL, ...)`;
2. call `internal::enc::CalculateMeta`;
3. call `internal::enc::BrunsliSerialize` while skipping histogram, DC, and AC
   section tags;
4. write the resulting common Brunsli sections into a `PWBS1` envelope;
5. write all component `int16_t` coefficients in component/block/zigzag order
   into a separate `PWCF1` envelope;
6. store payload lengths and SHA-256 in both envelopes;
7. on restore, verify magic/version/length/SHA before exposing bytes;
8. parse the side stream with `internal::dec::ProcessJpeg`, require
   `BRUNSLI_NOT_ENOUGH_DATA`, call `PrepareMeta` and `WarmupMeta`, inject the
   exact coefficient counts, and call `WriteJpeg`;
9. write output to a temporary sibling and rename only after all checks pass.

The CMake target links `brunslienc-static`, `brunslidec-static`,
`brunslicommon-static`, and macOS CommonCrypto. It compiles only the new adapter
plus unmodified pinned upstream sources.

- [ ] **Step 4: Run the fixture integration test GREEN**

Run `uv run pytest tests/test_brunsli_phase1.py -q`.

Expected: exact fixture round-trip passes and all corruption arms fail closed.

- [ ] **Step 5: Run v0.1 exactly once on both frozen JPEGs**

Run:

```bash
uv run python run_phase1.py \
  --manifest input-manifest.yaml \
  --revision v0.1 \
  --output results/phase1-v0.1.json
```

Expected success: both restored lengths, byte comparisons, and SHA-256 values
match. If and only if this exact run fails because v0.1 cannot parse or restore
a frozen JPEG, run the same command once with `--revision master`; never patch
either upstream revision.

### Task 6: Persist evidence and stop before learned entropy work

**Files:**
- Create: `experiments/plr_derived_brunsli_two_photo/results/phase0-status.json`
- Create: `experiments/plr_derived_brunsli_two_photo/results/phase1-v0.1.json` or the pre-authorized master fallback result
- Create: `experiments/plr_derived_brunsli_two_photo/evidence.json`
- Modify: `openspec/changes/benchmark-plr-derived-brunsli-two-photo/tasks.md`

- [ ] **Step 1: Record complete evidence identities**

`evidence.json` must include repository HEAD plus tracked/staged/unstaged/untracked
manifest hashes, both input identities, upstream commits and license hashes,
compiler/CMake/macOS identities, command lines, adapter binary SHA-256, side and
coefficient sizes/hashes, restored hashes, corruption outcomes, deviations,
and the Phase 1 verdict.

- [ ] **Step 2: Register MLflow metadata without duplicating artifacts**

Create one experiment-local MLflow run with parameters and scalar byte metrics;
store paths/hashes to DVC-owned artifacts rather than copying binary payloads
into MLflow.

- [ ] **Step 3: Run deterministic verification**

Run:

```bash
cd experiments/plr_derived_brunsli_two_photo
uv run pytest -q
dvc repro
openspec validate benchmark-plr-derived-brunsli-two-photo
git diff --check -- \
  experiments/plr_derived_brunsli_two_photo \
  openspec/changes/benchmark-plr-derived-brunsli-two-photo \
  docs/superpowers/specs/2026-08-03-plr-derived-brunsli-two-photo-design.md \
  docs/research/2026-08-03-shared-model-accounting-scale-revision.md \
  docs/superpowers/plans/2026-08-03-plr-derived-brunsli-phase0-phase1.md
```

Expected: all tests pass, DVC stages are unchanged after reproduction,
OpenSpec is valid, and diff check is clean.

- [ ] **Step 4: Stop at the approved boundary**

Do not train a model, measure JXL, run Lepton, create a full candidate, access a
phone, edit production code, or run a complete project. A separate Phase 2/3
plan starts only after Phase 1 exactness and corruption evidence are accepted.

- [ ] **Step 5: Commit only this experiment's explicit files**

List every owned path explicitly with `git add`, inspect `git diff --cached`,
and use `git commit --only` with the same explicit path set. Shared staged files
outside this plan must remain staged and uncommitted.
