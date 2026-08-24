# Full-resolution A/B/C Dense PLY Comparison Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Generate the missing rolling-global-live C dense point cloud from cap41, align it independently to A, and publish an A/B/C three-pane page that renders every real dense point with the already-approved interactions.

**Architecture:** Preserve the existing cap41 A/B artifacts. Run one host replay with the real production-core rolling-BA gate, derive C from that replay's pre-finalize `live_end`, reuse the exact A/B CasDiffMVS conversion/inference/fusion chain, calculate a new C-to-A Umeyama transform, then reuse the existing float32 `.pos` / uint8 `.col` full-resolution WebGL path. Add only small orchestration, validation, provenance, and A/B/C page-configuration code; do not invent rendering or interaction logic.

**Tech Stack:** C++ replay executable, COLMAP binary models, Python 3.11, NumPy, pycolmap, PyTorch/MPS, CasDiffMVS, stdlib `unittest`, WebGL 1, local `http.server`, in-app Browser.

---

## Frozen contract

Experiment root:

```text
/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820
```

Arms:

- A: existing `dense_A.ply`, finish-time stage-1/stage-2 refined model.
- B: existing `aligned_B.ply`, current `live_end`, rolling global BA disabled.
- C: new `aligned_C.ply`, new `live_end`, `OFFICIAL_AETHER_INCREMENTAL_GLOBAL_BA=1` and telemetry-proven incremental solves.

Immutable A/B hashes:

```text
dense_A.ply    9d0c1cc5cbad53805db1a9868a52785fd12d7c0b0c6fff3ae145a96bfaec7d27
dense_B.ply    be0f6213b39ba81aa9ef3aa348ca3b79b4e6df216c87ffbc71b6f46e96b2419b
aligned_B.ply  6845a8870c8ff41ffeb9c13281c1394a782df93ea85686db08ca4aea1f40be68
```

Fixed 98-frame input manifest:

```text
dense_ab_inputs/index_to_name.json
SHA-256 d5f719ba2cb9de13822183564d674f927966d9a10a0c69e9ee222e99c6e9ea2d
```

No active Git repository exists at the workspace root. Do not initialize one and do not run Git in `aether_cpp`. Replace commit checkpoints below with file hashes and test logs.

## Task 1: Create the C-pipeline validation harness

**Files:**

- Create: `_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/tools/c_pipeline.py`
- Create: `_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/tests/test_c_pipeline.py`
- Create: `_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/PREREG.md`

### Step 1: Write failing tests

Use stdlib `unittest` and tiny temporary fixtures. Tests must cover:

1. `read_images_raw()` preserves each retained COLMAP image record byte-for-byte and reorders it to the frozen manifest.
2. `prepare_dense_input()` rejects a missing manifest frame instead of shrinking the intersection.
3. `inspect_ply()` accepts only binary little-endian `float x/y/z + uchar red/green/blue`, and enforces `file_size == header_bytes + 15*N`.
4. `umeyama()` recovers a known positive-scale rigid similarity and rejects a degenerate point set.
5. `align_ply()` preserves all RGB bytes exactly and writes every input vertex.
6. `verify_replay_log()` requires at least one exact `[aether_sfm] incremental global BA #` record, `STREAMED fed=101 missing_pose=0`, and no `incremental global BA skipped`.

Run and confirm the initial import failure:

```bash
/usr/bin/perl -e 'alarm 30; exec @ARGV' -- /Users/kaidongwang/.venv/pocketworld/bin/python -m unittest discover -s /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/tests -p 'test_c_pipeline.py' -v
```

Expected: FAIL because `c_pipeline.py` does not yet exist.

### Step 2: Implement the smallest passing module

`c_pipeline.py` exposes these CLI subcommands:

```text
prepare --src-model --index-manifest --photo-map --photos --out --report
verify-replay --log --live-end --json
align --ref-model --src-model --input-ply --output-ply --json
verify-ply --ply
manifest --root --out
```

Implementation requirements:

- Copy `read_images_raw`, camera parsing, and record-preserving write logic from `dense_ab_inputs/filter_models.py`; parameterize all paths.
- Read image names from `index_to_name.json` in numeric key order. Require exactly keys `00000000` through `00000097` and exactly 98 unique names.
- Never compute a fresh intersection. Missing source images or photos are fatal.
- Before opening any critical input, use `os.stat` plus `st_flags & stat.UF_DATALESS` when available; reject `dataless`.
- `prepare` writes `input/sparse/{cameras.bin,images.bin,points3D.bin}`, 98 image symlinks, and a JSON report containing ordered names and hashes.
- `verify-replay` matches the production-core log line, not merely the stale bench summary.
- `align` loads named camera centers through pycolmap, uses the full A/C name intersection, requires at least the frozen 98 dense names, records full `scale`, `R`, `t`, `det_R`, matched names, and p50/p90/max residuals.
- PLY reads and writes must stream or memmap the 15-byte payload; no sampling.
- JSON uses sorted keys and indent 2. Hash inputs and outputs with chunked SHA-256.

### Step 3: Run tests to green

```bash
/usr/bin/perl -e 'alarm 60; exec @ARGV' -- /Users/kaidongwang/.venv/pocketworld/bin/python -m unittest discover -s /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/tests -p 'test_c_pipeline.py' -v
```

Expected: all tests PASS.

### Step 4: Freeze tool identity

```bash
/usr/bin/perl -e 'alarm 20; exec @ARGV' -- /usr/bin/shasum -a 256 /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/tools/c_pipeline.py /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/tests/test_c_pipeline.py
```

Save output to `rolling_global_ba_C/tool_hashes.txt` through `apply_patch` or the manifest subcommand; never use shell redirection to author source files.

## Task 2: Preflight immutable inputs and disk

**Files:**

- Create: `_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/preflight.json`

### Step 1: Check residency and free space

Run `ls -lO` on every explicit input: replay executable, DB, fed-frame JSONL, 98 photos, checkpoint, dense scripts, A/B PLYs, and frame manifests. Stop if a critical input is `dataless` or if available space is below 8 GiB. Do not inspect the known dataless `official_sfm_live.db.arkit_pose_v1`; it is not an input.

```bash
/usr/bin/perl -e 'alarm 20; exec @ARGV' -- /bin/df -g /Users/kaidongwang/Documents/progecttwo
```

### Step 2: Hash frozen inputs

Record at least these expected identities in `preflight.json`:

```text
official_replay_bench_exe  bc6e5eb4531b055b071bd20b93ee6a0e0b9cdf74f7798c57a08cc28497604909
official_sfm_live.db       e29fc9fbc01da00af64473eff29e5a7b3013e03254a6777ac318d4892408619d
fed_frames.jsonl           5589258362e65c0654ddfa06c9f16dd64c3a59731e4d91dc5afb5ce960158360
checkpoint                 46a0b8941c4ca76859fce597255dc5da6f09e81f40ac34c5e165cddeba37392f
colmap_input.py            acad2a24abf1ed9de46d6aa55bf04fed559b6aabcc603f41127c8b9ce9a7ba69
run_arm_lever.py           593113e569e97d9c238a3ef5a02c7b3d05866d701d77730aaaba3b1c394b8416
fuse_arm.py                13fb753b65fc81f40583400489c2e5d4dcfb744f8e810abfd0fee683276c790f
export_bins.py             9752c7bae83a57ac08bf6e536031aaeb5989b25681086a99cd623bc08921ea8d
```

Stop on any drift before running the expensive stages.

## Task 3: Replay cap41 with rolling global BA enabled

**Files:**

- Create: `_host_experiments/live_vs_refined_20260820/replay_C.log`
- Create: `_host_experiments/live_vs_refined_20260820/replay_C_out/`
- Create: `_host_experiments/live_vs_refined_20260820/dumps_C/live_end/`
- Create: `_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/replay_verification.json`

### Step 1: Refuse accidental overwrite

Before creating outputs, require that `replay_C_out`, `dumps_C`, and `replay_C.log` do not exist. If any exists, inspect and resume only when its provenance matches; never delete or overwrite it automatically.

After those absence checks, explicitly create `replay_C_out` and `dumps_C`;
the replay executable creates `session.db` but does not create its parent.
Capture each long stage with a no-PTY runner that opens the raw log with
exclusive creation, arms the hard timeout, then `exec`s the listed argv. The
runner records argv, the allowlisted Aether environment, elapsed time, exit
status, and log hash beside the raw log. The first exploratory C replay used
`script(1)` instead; that deviation is retained and its terminal controls must
be normalized for telemetry parsing rather than silently rewriting the raw log.

### Step 2: Run the replay with a hard timeout

The unprefixed variable is set only so the bench's stale header is readable. The prefixed variable is the actual production-core gate.

```bash
/usr/bin/perl -e 'alarm 300; exec @ARGV' -- /usr/bin/env OFFICIAL_AETHER_INCREMENTAL_GLOBAL_BA=1 AETHER_INCREMENTAL_GLOBAL_BA=1 OFFICIAL_AETHER_LIVE_POSE_DUMP=/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/dumps_C OFFICIAL_AETHER_LIVE_POSE_DUMP_EVERY=0 /Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/build-host-fullbench/official_replay_bench_exe /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_lba_three_arms_20260810/input/cap_1786414194441541/official_sfm_live.db /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_lba_three_arms_20260810/input/cap_1786414194441541/official_sfm_fed_frames.jsonl /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/replay_C_out --k=12 --max-frames=0
```

Capture stdout/stderr to `replay_C.log` using the process runner, not a shell pipeline.

### Step 3: Enforce telemetry gates

```bash
/usr/bin/perl -e 'alarm 30; exec @ARGV' -- /Users/kaidongwang/.venv/pocketworld/bin/python /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/tools/c_pipeline.py verify-replay --log /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/replay_C.log --live-end /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/dumps_C/live_end --json /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/replay_verification.json
```

Expected: at least one incremental solve, `fed=101`, `missing_pose=0`, all three `live_end` COLMAP bins nonempty, and zero skipped incremental BA lines. Otherwise stop; never substitute `replay_C_out`, which is the later refined model.

## Task 4: Build the fixed 98-frame C dense input

**Files:**

- Create: `_host_experiments/live_vs_refined_20260820/work_C_dense/input/`
- Create: `_host_experiments/live_vs_refined_20260820/dense_c_prepare_report.json`

### Step 1: Prepare fixed input

```bash
/usr/bin/perl -e 'alarm 60; exec @ARGV' -- /Users/kaidongwang/.venv/pocketworld/bin/python /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/tools/c_pipeline.py prepare --src-model /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/dumps_C/live_end --index-manifest /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/dense_ab_inputs/index_to_name.json --photo-map /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/dense_ab_inputs/frame_to_photo.json --photos /Users/kaidongwang/Documents/progecttwo/_host_experiments/phone_cap_20260811/photos_jpg --out /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/work_C_dense/input --report /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/dense_c_prepare_report.json
```

Expected: 98 ordered records and 98 resident image symlinks; frozen manifest hash unchanged.

### Step 2: Convert with the existing official input generator

```bash
/usr/bin/perl -e 'alarm 300; exec @ARGV' -- /Users/kaidongwang/.venv/pocketworld/bin/python /Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/diffmvs/colmap_input.py --input_folder /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/work_C_dense/input --output_folder /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/work_C_dense/mvs --num_src_images 10
```

Capture output to `colmap_input_C.log`. Require pair-file count 98 and exactly 98 camera/image records.

## Task 5: Run the exact A/B inference and fusion chain for C

**Files:**

- Create: `_host_experiments/live_vs_refined_20260820/work_C_dense/out/`
- Create: `_host_experiments/live_vs_refined_20260820/dense_C.ply`
- Create: `_host_experiments/live_vs_refined_20260820/infer_C.log`
- Create: `_host_experiments/live_vs_refined_20260820/fuse_C.log`

### Step 1: Run deterministic MPS inference

```bash
/usr/bin/perl -e 'alarm 600; exec @ARGV' -- /Users/kaidongwang/.venv/pocketworld/bin/python /Users/kaidongwang/Documents/progecttwo/_artifacts/lever1_source_reform_20260818/run_arm_lever.py --mvs_in /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/work_C_dense/mvs --out /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/work_C_dense/out --ckpt /Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/experiments/casdiffmvs_blendmvg_scratch_2026-08-16/ckpts/casdiffmvs_C_long_ep31.ckpt --num_view 10 --max_w 768 --max_h 576 --noise_seed 20260818
```

Capture output to `infer_C.log`. Require MPS, 98 frames, 768x576, `num_view=10`, and all depth/confidence outputs. MPS remains serial.

### Step 2: Run the unchanged official fusion wrapper

```bash
/usr/bin/perl -e 'alarm 600; exec @ARGV' -- /usr/bin/env DIFFMVS_REPO=/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/diffmvs /Users/kaidongwang/.venv/pocketworld/bin/python /Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/experiments/mvs_pose_ablation_2026-08-18/tools/fuse_arm.py --pair_folder /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/work_C_dense/mvs --out_folder /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/work_C_dense/out --ply /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/dense_C.ply
```

Capture output to `fuse_C.log`. This reuses geo>=3, pixel 1.0, relative depth 0.01, and photo `[0.3,0.5,0.5]` from `fuse_arm.py`; do not reimplement them.

### Step 3: Verify the native C PLY

```bash
/usr/bin/perl -e 'alarm 120; exec @ARGV' -- /Users/kaidongwang/.venv/pocketworld/bin/python /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/tools/c_pipeline.py verify-ply --ply /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/dense_C.ply
```

Expected: binary little-endian, 15 bytes/vertex, true RGB payload, and a real count read from the header. Never prefill a guessed C count.

## Task 6: Align C independently to A

**Files:**

- Create: `_host_experiments/live_vs_refined_20260820/work_C/sparse/0` symlink to `dumps_C/live_end`
- Create: `_host_experiments/live_vs_refined_20260820/aligned_C.ply`
- Create: `_host_experiments/live_vs_refined_20260820/gauge_c_to_a.json`

### Step 1: Create the explicit C model entry

Use Python `os.symlink` from the orchestration script after checking the destination does not exist. Do not delete or replace an existing path.

### Step 2: Compute and apply C-to-A Umeyama

```bash
/usr/bin/perl -e 'alarm 240; exec @ARGV' -- /Users/kaidongwang/.venv/pocketworld/bin/python /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/tools/c_pipeline.py align --ref-model /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/work_A/sparse/0 --src-model /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/dumps_C/live_end --input-ply /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/dense_C.ply --output-ply /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/aligned_C.ply --json /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/gauge_c_to_a.json
```

Require positive finite scale, finite R/t, `det(R)` approximately +1, at least
99 matched named camera centers including all 98 dense names, identical
input/output vertex counts, and byte-identical RGB streams. Before inspecting
C residuals, preregister these gross invalid-convention gates: scale in
`[0.95, 1.05]`, residual p50 `<=0.05m`, p90 `<=0.10m`, max `<=0.50m`.
Record every name/residual pair as well as summaries. These are alignment
validity gates, not dense-quality claims.

## Task 7: Parameterize the existing full-resolution page for A/B/C

**Files:**

- Create: `_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/tools/build_page_abc_fullres.py`
- Create: `_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/tests/test_fullres_viewer.py`
- Read unchanged: `/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/experiments/mvs_pose_ablation_2026-08-18/tools/build_page_fullres.py`

### Step 1: Write failing viewer tests

Create tiny `dense_A.ply`, `aligned_B.ply`, and `aligned_C.ply` fixtures with distinct counts and RGB. Run the real `export_bins.py`, then the new builder. Assert:

- meta keys are exactly A/B/C in that order;
- `.pos == 12*N` and `.col == 3*N` for every arm;
- all source position and RGB records survive exactly;
- HTML order is A then B then C and uses `repeat(3,1fr)`;
- the page fetches `.pos`/`.col` and calls `gl.drawArrays(gl.POINTS,0,v.n)`;
- the copied shared camera, left-rotate, right-pan, wheel-zoom, point-slider, circular shader, and depth-test code remain present;
- P16k/P8k/P16kH, `Math.random`, voxel/sampling/LOD code are absent.

```bash
/usr/bin/perl -e 'alarm 60; exec @ARGV' -- /Users/kaidongwang/.venv/pocketworld/bin/python -m unittest discover -s /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/tests -p 'test_fullres_viewer.py' -v
```

Expected: FAIL because the A/B/C builder does not exist.

### Step 2: Implement only the A/B/C data plan

Import `TPL` from the pinned existing `build_page_fullres.py` by absolute file path with `importlib.util`. Do not copy or edit its shader, camera, mouse, wheel, slider, loading, or draw-loop code.

Substitute exactly this plan:

```python
plan = [
    ("A — refined", "A", "cap41 · 98-frame intersection · finish-time stage-1/stage-2 iterative global BA"),
    ("B — current live", "B", "cap41 · live_end · capture-time local BA · rolling global BA disabled"),
    ("C — rolling-global live", "C", "cap41 · live_end replay · OFFICIAL_AETHER_INCREMENTAL_GLOBAL_BA=1 · incremental solve telemetry verified"),
]
```

Use A's `med` and `radius` as the shared initial view. Read actual counts from `meta.json`; never hardcode C count or quality claims. Link the adjacent provenance manifest as plain factual text only; add no interaction.

### Step 3: Run both test suites

```bash
/usr/bin/perl -e 'alarm 120; exec @ARGV' -- /Users/kaidongwang/.venv/pocketworld/bin/python -m unittest discover -s /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/tests -p 'test_*.py' -v
```

Expected: all tests PASS.

## Task 8: Export every A/B/C point and build the page

**Files:**

- Create: `_host_experiments/live_vs_refined_20260820/fullres_abc/bin/{A,B,C}.{pos,col}`
- Create: `_host_experiments/live_vs_refined_20260820/fullres_abc/bin/meta.json`
- Create: `_host_experiments/live_vs_refined_20260820/fullres_abc/index.html`
- Create: `_host_experiments/live_vs_refined_20260820/fullres_abc/manifest.json`

### Step 1: Export with the unchanged zero-sampling exporter

```bash
/usr/bin/perl -e 'alarm 900; exec @ARGV' -- /Users/kaidongwang/.venv/pocketworld/bin/python /Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/experiments/mvs_pose_ablation_2026-08-18/tools/export_bins.py --dir /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820 --out /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/fullres_abc/bin --ref A --arms A,B,C
```

Do not call `subsample_for_page.py`.

Expected exact A/B sizes:

```text
A.pos 173142756 bytes    A.col 43285689 bytes    N=14428563
B.pos 169761372 bytes    B.col 42440343 bytes    N=14146781
```

C sizes must equal `12*N_C` and `3*N_C`, where `N_C` is read from `aligned_C.ply`. Require total exported records equal total PLY vertices.

### Step 2: Generate the page, then finalize the manifest

```bash
/usr/bin/perl -e 'alarm 60; exec @ARGV' -- /Users/kaidongwang/.venv/pocketworld/bin/python /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/tools/build_page_abc_fullres.py --out /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/fullres_abc --ref A --manifest /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/fullres_abc/manifest.json
```

The builder does not need the manifest contents to render; it emits a stable
link to `manifest.json`. After `index.html` exists, run the manifest command.
Its implementation uses an explicit artifact allowlist only (never `rglob`),
validates all six bin byte lengths against observed PLY/meta counts, includes
the final page hash, and excludes only the manifest's own hash.

```bash
/usr/bin/perl -e 'alarm 180; exec @ARGV' -- /Users/kaidongwang/.venv/pocketworld/bin/python /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/tools/c_pipeline.py manifest --root /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820 --out /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/fullres_abc/manifest.json
```

## Task 9: Deterministic and browser verification

**Files:**

- Create: `_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/final_verification.json`
- Create: `_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/BROWSER_QA.md`

### Step 1: Re-run all deterministic tests and hashes

```bash
/usr/bin/perl -e 'alarm 180; exec @ARGV' -- /Users/kaidongwang/.venv/pocketworld/bin/python -m unittest discover -s /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/rolling_global_ba_C/tests -p 'test_*.py' -v
```

Rehash A/B and require their three frozen hashes remain unchanged. Verify C replay telemetry, all PLY lengths/properties, C-to-A RGB preservation, all six viewer-bin lengths, and A/B/C displayed counts.

### Step 2: Serve locally

```bash
/usr/bin/perl -e 'alarm 14400; exec @ARGV' -- /Users/kaidongwang/.venv/pocketworld/bin/python -m http.server 8732 --bind 127.0.0.1 --directory /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/fullres_abc
```

Open `http://127.0.0.1:8732/` in the in-app Browser.

### Step 3: Browser acceptance

Require:

- HTTP 200 for index, meta, and six bins;
- three equal-width WebGL canvases in A/B/C order;
- zero console errors, failed requests, or lost WebGL contexts;
- each pane's displayed count equals PLY header, meta, and GPU draw count;
- dark background, true RGB, circular points, depth testing;
- left drag rotates all three, right drag pans all three, wheel zooms all three, slider changes all three point sizes;
- overall room view and known floor-collapse region are both visually inspectable.

Save screenshots and factual QA notes. The user remains the visual judge; do not label C better/worse without their judgment.

## Task 10: Independent read-only review and handoff

Give a fresh reviewer only the approved design, this plan, source hashes, integrated diff/artifacts, test log, replay telemetry, manifests, and browser evidence. Require review of:

- C lineage truly ends at `dumps_C/live_end`;
- real rolling-global solves fired;
- fixed 98-frame parity and dense parameters;
- independent C-to-A gauge and RGB preservation;
- no point sampling anywhere;
- renderer/interaction core unchanged;
- no A/B mutation or unsupported quality claim.

Root adjudicates findings, reruns affected checks, and issues the final accept/rework decision.
