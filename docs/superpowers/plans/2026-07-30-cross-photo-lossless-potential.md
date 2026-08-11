# Cross-Photo Lossless Potential Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans
> to implement this plan task-by-task. The user explicitly requires inline
> execution by the primary agent and forbids subagents for this work.

**Goal:** Build and run one isolated 100 MiB SfM-guided JPEG collection
experiment that either reaches 2.165x with byte-exact restoration or stops the
direction before any phone bundle.

**Architecture:** A host-only libjpeg-turbo tool extracts exact JPEG headers and
quantized DCT coefficients. A Python/Numpy estimator predicts target coefficient
blocks using the real sparse PLY and registered SfM poses, stores independent
groups of 4 or 8, compresses them with XZ preset 9 extreme, restores every
source JPEG, and persists measurements to DVC/MLflow/ce-optimize state.

**Tech Stack:** C++17, libjpeg-turbo 3.1.4.1 coefficient API, Python 3.11,
Numpy 2.4.6, XZ 5.8.3, JPEG XL 0.11.2, unittest, uv, DVC, MLflow, OpenSpec.

---

### Task 1: Reproducible experiment identity

**Files:**
- Create: `experiments/cross_photo_lossless_potential/input-manifest.yaml`
- Create: `experiments/cross_photo_lossless_potential/experiment-contract.yaml`
- Create: `experiments/cross_photo_lossless_potential/pyproject.toml`
- Create: `experiments/cross_photo_lossless_potential/uv.lock`
- Create: `experiments/cross_photo_lossless_potential/dvc.yaml`
- Create: `experiments/cross_photo_lossless_potential/dvc.lock`
- Create: `.context/compound-engineering/ce-optimize/cross-photo-lossless-potential/spec.yaml`

- [ ] **Step 1: Verify the immutable manifest**

Run:

```bash
cd /Users/kaidongwang/Developer/pocketworld
python3 experiments/cross_photo_lossless_potential/verify_inputs.py
```

Expected before implementation: failure because `verify_inputs.py` does not
exist.

- [ ] **Step 2: Lock the Python environment and DVC identity**

Run:

```bash
cd /Users/kaidongwang/Developer/pocketworld/experiments/cross_photo_lossless_potential
uv lock
dvc repro
```

Expected: a repository-local `uv.lock` and `dvc.lock` with the external inputs
recorded but no input bytes copied into Git.

### Task 2: Exact JPEG coefficient round trip

**Files:**
- Create: `experiments/cross_photo_lossless_potential/jpeg_coeff_tool.cpp`
- Create: `experiments/cross_photo_lossless_potential/tests/test_cross_photo_estimator.py`
- Create: `experiments/cross_photo_lossless_potential/run_tests.sh`

- [ ] **Step 1: Write the failing exactness test**

The test invokes:

```python
subprocess.run([tool, "extract", source, coefficient_file], check=True)
subprocess.run([tool, "restore", coefficient_file, restored], check=True)
self.assertEqual(source.read_bytes(), restored.read_bytes())
```

- [ ] **Step 2: Run RED**

Run:

```bash
cd /Users/kaidongwang/Developer/pocketworld/experiments/cross_photo_lossless_potential
./run_tests.sh
```

Expected: FAIL because `jpeg_coeff_tool.cpp` or its coefficient commands are
missing.

- [ ] **Step 3: Implement the minimum coefficient container**

Implement `extract` with `jpeg_read_coefficients`, preserving the exact prefix
through SOS, component metadata, restart interval, and natural-order
coefficients. Implement `restore` with `jpeg_write_coefficients`, then assemble
the preserved prefix, regenerated scan, and EOI.

- [ ] **Step 4: Run GREEN and exact real-sample sweep**

Run:

```bash
cd /Users/kaidongwang/Developer/pocketworld/experiments/cross_photo_lossless_potential
./run_tests.sh
```

Expected: all unit tests pass and the registered real JPEG fixture is
byte-identical.

### Task 3: SfM predictor and reversible group format

**Files:**
- Create: `experiments/cross_photo_lossless_potential/cross_photo_estimator.py`
- Modify: `experiments/cross_photo_lossless_potential/tests/test_cross_photo_estimator.py`

- [ ] **Step 1: Write failing projection and token tests**

Tests shall require:

```python
self.assertEqual(project_point(identity_pose, intrinsics, (0, 0, 2)), (cx, cy))
self.assertEqual(decode_tokens(encode_tokens(coefficients)), coefficients)
self.assertLessEqual(max(len(group) for group in make_groups(range(37), 4)), 4)
self.assertLessEqual(max(len(group) for group in make_groups(range(37), 8)), 8)
```

- [ ] **Step 2: Run RED**

Run `./run_tests.sh`.

Expected: FAIL because projection, tokens, and groups are not implemented.

- [ ] **Step 3: Implement geometry and reversible residuals**

Parse the binary PLY, SfM pose JSON, bundle intrinsics, and coefficient
containers. Build deterministic target-to-reference block maps, encode anchors
and signed residuals with zero-run/zig-zag tokens, and decode them exactly.

- [ ] **Step 4: Run GREEN**

Run `./run_tests.sh`.

Expected: all synthetic and one-real-file tests pass.

### Task 4: Immutable benchmark harness

**Files:**
- Create: `experiments/cross_photo_lossless_potential/verify_inputs.py`
- Create: `experiments/cross_photo_lossless_potential/run_benchmark.py`
- Create: `experiments/cross_photo_lossless_potential/run_benchmark.sh`
- Create: `experiments/cross_photo_lossless_potential/record_mlflow.py`

- [ ] **Step 1: Write failing harness-contract tests**

Require JSON keys:

```python
required = {
    "photo_ratio",
    "exactness_failures",
    "input_hash_failures",
    "valid_sparse_projections",
    "random_access_group_overflow",
    "archive_bytes",
}
```

- [ ] **Step 2: Run RED**

Run `./run_tests.sh`.

Expected: FAIL because the benchmark harness is absent.

- [ ] **Step 3: Implement the measurement**

The harness validates all hashes, creates exact JXL effort-10 baselines, runs
group sizes 4 and 8 serially, verifies every restoration, performs fixed-seed
random access and corruption checks, emits one JSON object per arm, and removes
large temporary output through a managed temporary directory.

- [ ] **Step 4: Run targeted verification**

Run:

```bash
cd /Users/kaidongwang/Developer/pocketworld/experiments/cross_photo_lossless_potential
./run_tests.sh
python3 verify_inputs.py
```

Expected: tests pass and input failures equal zero.

### Task 5: Run once and stop

**Files:**
- Create: `.context/compound-engineering/ce-optimize/cross-photo-lossless-potential/experiment-log.yaml`
- Create: `.context/compound-engineering/ce-optimize/cross-photo-lossless-potential/strategy-digest.md`
- Create: `.context/compound-engineering/ce-optimize/cross-photo-lossless-potential/results/*.yaml`

- [ ] **Step 1: Record JXL baseline**

Run `./run_benchmark.sh`; persist and re-read the baseline before group arms.

- [ ] **Step 2: Record group 4 immediately**

Write its result marker, append it to the experiment log, re-read the log, and
verify the iteration is present before starting group 8.

- [ ] **Step 3: Record group 8 immediately**

Apply the same write/read checkpoint.

- [ ] **Step 4: Apply the hard stop**

If both exact verified ratios are below 2.165x, write
`verdict: reject-before-phone`; otherwise write
`verdict: eligible-for-independent-phone-bundle`. Do not build or install any
bundle in this task.

- [ ] **Step 5: Fresh verification**

Run:

```bash
cd /Users/kaidongwang/Developer/pocketworld
openspec validate benchmark-cross-photo-lossless-potential --strict
cd experiments/cross_photo_lossless_potential
./run_tests.sh
python3 verify_inputs.py
```

Expected: OpenSpec valid, all tests pass, zero input/hash failures, and only
small manifests, hashes, logs, and metrics remain.
