# A/B1 Solver-Pose Smoke Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` and preserve the frozen inputs. Do not edit the product or native core.

**Goal:** Execute a host A/B1 smoke that compares the current known-pose restore/refine path with the current pure-visual mapper on byte-identical copies of one 60-frame database.

**Architecture:** A small experiment-local C++ executable links the already-built `pwofficial_core`. It exposes two modes only: `known-pose` calls `create → finalize`, while `visual` calls `aether_sfm_run(db, "", ...)`; both export a raw COLMAP model and print one machine-readable result line. A shell contract test owns input isolation and gates.

**Tech Stack:** C++17, existing C ABI, SQLite read-only preflight, CMake-produced static archive, shell contract test, COLMAP 4.1.1 model tools.

---

### Task 1: Freeze the corrected contract

**Files:**
- Create: `contract-amendment-01.yaml`
- Preserve: `experiment-contract.yaml`
- Preserve: `input-manifest.yaml`

- [ ] Hash the original contract and verify it is `c0e9e37b24a835a74abaf254f2d532d74c071af6e5cd8c1c41e4d030c44ea625`.
- [ ] Record both v1 blockers without overwriting v1.
- [ ] Freeze the v2 arm definitions, gates, interpretation limits, and stop conditions.

### Task 2: Write and observe the failing CLI contract test

**Files:**
- Create: `tests/test_pose_solver_ab_contract.sh`

- [ ] The test must reject a missing executable, a bad initial DB hash, a B1 sidecar, nonzero pose-prior rows, fewer than 48 B1 registrations, any gravity hit, or missing COLMAP model files.
- [ ] Run before the runner exists:

```bash
tests/test_pose_solver_ab_contract.sh \
  work/build/official_pose_solver_ab_runner \
  work/input/official_sfm_live.db \
  work/test-red
```

Expected: nonzero exit with `runner is not executable`.

### Task 3: Implement the minimal host-only runner

**Files:**
- Create: `tools/official_pose_solver_ab_runner.cc`

- [ ] Accept exactly `known-pose|visual`, DB path, output directory, and minimum registered count.
- [ ] Open SQLite read-only for preflight; print counts for images, keypoints, descriptors, TVG, and pose priors.
- [ ] In `known-pose`, require `<db>.arkit_pose_v1`, call `aether_sfm_create`, then synchronous `aether_sfm_finalize`.
- [ ] In `visual`, forbid the sidecar, require zero pose-prior rows, clear position/gravity registries, then call `aether_sfm_run(db, "", ...)`.
- [ ] Count registered images using `aether_sfm_get_poses`, collect raw diagnostics with `aether_sfm_final_diag`, verify visual gravity hits remain zero, and dump the raw model with `aether_sfm_debug_dump_model`.
- [ ] Return nonzero for API failure, under-threshold registration, missing points, leakage, or model-dump failure.

### Task 4: Build without changing native source

**Files:**
- Create build outputs only under `work/build/`.
- Read existing objects from `build-host-fullbench/`.

- [ ] Rebuild `pwofficial_core` and `official_gpu_match_host_obj` from the frozen shared source.
- [ ] Compile the runner with the exact include/definition set from `official_replay_bench_exe`.
- [ ] Link the runner against `libpwofficial_core.a`, the existing official host matcher object, preclamp object, SHA object, Metal, Foundation, Ceres, glog, and SQLite.
- [ ] Freeze runner source and executable SHA-256; recheck official core SHA-256 is unchanged.

### Task 5: Make the contract test green

- [ ] Copy the exact pre-prune DB into `work/input/official_sfm_live_full.db` without opening the source writable.
- [ ] Verify DB SHA `6b7ec9ed765645e95c95df69d304c4e73321b0eac538e223463851fc9c5dcaf2`, 60 complete 128-column descriptor rows, and `PRAGMA integrity_check=ok` through an immutable URI.
- [ ] Run the visual contract test on a fresh DB copy.
- [ ] Require `registered_images>=48`, `raw_points3d>0`, `gravity_hits=0`, and readable nonempty model files.

### Task 6: Execute A/B1 and compare

- [ ] Materialize four unique run directories with byte-identical DB copies.
- [ ] Add the frozen sidecar only to A directories; assert it is absent from B1 directories.
- [ ] Run `A1 → B1_1`; only if both pass, run `B1_2 → A2` in fresh processes.
- [ ] Run COLMAP `model_analyzer` on every model.
- [ ] Run COLMAP `model_comparer` B1→A as a diagnostic Sim(3) comparison; do not use its default 0.1 threshold as a preregistered gate.
- [ ] Append each run identity, command, hashes, metrics, artifacts, deviations, and verdict to `results/experiment-log.ndjson`.
- [ ] Report strict conclusions only within the v2 scope; defer end-to-end B2/B3 and strict device slowdown.
