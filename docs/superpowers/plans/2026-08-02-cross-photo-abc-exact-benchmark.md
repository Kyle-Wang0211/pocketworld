# Cross-Photo A/B/C Exact Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans
> to implement this plan task-by-task. The user explicitly prohibited subagents,
> so execution remains inline in the shared checkout.

**Goal:** Run complete 25-photo exact-JPEG benchmarks for dense-flow local DCT
prediction, global Faiss DCT prediction, and a commercially gated official
learned/shared-context candidate.

**Architecture:** Reuse the verified JPEG coefficient extractor and frozen
107,649,656-byte manifest. A new Python group codec owns versioned payloads,
exact residuals, manifests, verification, and orchestration. Small C++ helpers
provide OpenCV flow, Faiss neighbor search, and pinned ZPAQ file coding; none is
linked into PocketWorld.

**Tech Stack:** Python 3.11 + NumPy, C++17, libjpeg-turbo, OpenCV 4.13.0,
Faiss Python 1.14.2, JPEG XL 0.11.2, libzpaq 7.15, DVC, MLflow, OpenSpec.

---

### Task 1: Freeze the reproducible experiment

**Files:**
- Create: `experiments/cross_photo_abc/experiment-contract.yaml`
- Create: `experiments/cross_photo_abc/input-manifest.yaml`
- Create: `experiments/cross_photo_abc/tests/test_cross_photo_group_codec.py`
- Create: `test/cross_photo_abc_contract_test.dart`

- [ ] Write contract tests asserting 25 inputs, 107,649,656 source bytes,
  88,409,901 JXL member bytes, group size eight, no early ratio stop, all side
  bytes counted, and no Flutter/device commands.
- [ ] Run the focused tests and observe failure because the new files/API do
  not exist.

### Task 2: Implement common exact payload primitives

**Files:**
- Create: `experiments/cross_photo_abc/cross_photo_group_codec.py`
- Create: `tool/zpaq_file_tool.cpp`
- Create: `tool/run_zpaq_file_tool_tests.sh`

- [ ] Implement and test unsigned varints, modulo-65536 residual encode/decode,
  versioned SHA-protected group payloads, group manifests, and fail-closed
  parsing.
- [ ] Implement a benchmark-only `compress|decompress` CLI over the existing
  pinned ZPAQ bridge and test exact file round-trip plus corruption rejection.

### Task 3: Implement arm A

**Files:**
- Create: `tool/cross_photo_dense_flow.cpp`
- Create: `tool/cross_photo_dense_flow_test.cpp`
- Create: `tool/run_cross_photo_dense_flow_tests.sh`
- Create: `experiments/cross_photo_abc/run_arm_a.py`

- [ ] Test deterministic grid serialization, bounds, and target-to-parent flow
  direction on translated synthetic images.
- [ ] Implement DIS flow at quarter scale, a 64-pixel grid, bilinear lookup,
  and local radius-two selector evaluation over exact DCT blocks.
- [ ] Encode all groups, ZPAQ every child payload, restore all 25 JPEGs, verify
  every byte/SHA, and save `results/arm-a.json`.

### Task 4: Implement arm B

**Files:**
- Create: `tool/cross_photo_faiss_forest.cpp`
- Create: `tool/cross_photo_faiss_forest_test.cpp`
- Create: `tool/run_cross_photo_faiss_forest_tests.sh`
- Create: `experiments/cross_photo_abc/run_arm_b.py`

- [ ] Test that all selected block parents belong to earlier frames and parent
  maps reject forward/truncated references.
- [ ] Implement group/component-local IndexIVFFlat construction and exact
  modulo-65536 residual output.
- [ ] Encode all groups, restore all 25 JPEGs, verify every byte/SHA, and save
  `results/arm-b.json`.

### Task 5: Gate arm C and select the winner

**Files:**
- Create: `experiments/cross_photo_abc/arm-c-audit.json`
- Create: `experiments/cross_photo_abc/record_mlflow.py`
- Create: `experiments/cross_photo_abc/evidence.json`

- [ ] Record ROMP revision `dbc2616a841debfa1df99b30ab66cb200345e974`,
  missing LICENSE evidence, CVPR implementation/model availability, and the
  resulting commercial verdict.
- [ ] If and only if C passes, run the same 25-photo exact benchmark including
  model/table bytes; otherwise persist `blocked-license` without executing it.
- [ ] Compare A/B/C to the complete JXL baseline, log parameters/metrics/artifacts in
  MLflow, validate OpenSpec, run focused tests, delete large scratch files, and
  report the new photo and estimated complete-project optimum.
