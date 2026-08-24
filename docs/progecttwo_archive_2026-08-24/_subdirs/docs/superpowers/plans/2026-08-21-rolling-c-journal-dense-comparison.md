# Rolling-C Journal Dense Comparison Implementation Plan

> **Execution workflow:** test-driven implementation with a fresh implementer, specification review, code-quality review, then root-owned real experiment and independent final acceptance. This workspace explicitly forbids Git operations for this research chain, so no branch, worktree, commit, or push is part of this plan.

**Goal:** Using the same frozen cap41 capture, compute the dense point cloud that a real streaming product would deliver when each reference frame's depth is inferred once from its capture-time rolling-C snapshot, then all cached depths are re-fused with the final rolling-C poses. Publish a full-resolution, synchronized three-pane comparison of `A_refined`, `C_batch`, and `C_journal` so the user can choose by eye.

**Definitions:**

- `A_refined`: existing finish-time refined global-BA dense result.
- `C_batch`: existing rolling-C `live_end` dense result where all 98 frames were inferred after capture from final pose/range/source inputs.
- `C_journal`: new result where each of the same 98 frames is inferred exactly once from its preregistered capture-time snapshot, while final fusion uses the same final rolling-C camera files and pair list as `C_batch`.

`C_journal` is the production-shaped arm. Sparse SfM is only the internal provider of pose, depth range, and source-view inputs; every compared artifact is a dense PLY.

**Invariant:** This is one immutable capture processed three ways. No recapture, frame substitution, display sampling, output overwrite, or per-result tuning is permitted.

---

## Frozen task contract

### Immutable inputs

- Exact original replay DB main file: `/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_lba_three_arms_20260810/runs_gra3/base/db.db`, SHA-256 `e29fc9fbc01da00af64473eff29e5a7b3013e03254a6777ac318d4892408619d`.
- Fed-frame journal: `/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_lba_three_arms_20260810/input/cap_1786414194441541/official_sfm_fed_frames.jsonl`, 101 lines, SHA-256 `5589258362e65c0654ddfa06c9f16dd64c3a59731e4d91dc5afb5ce960158360`.
- Ordered 98-frame manifest SHA-256 `d5f719ba2cb9de13822183564d674f927966d9a10a0c69e9ee222e99c6e9ea2d`.
- Frozen photo map SHA-256 `7d3c9b03a4f4eb028ac58878099a97ff87034ae4afa7cabc9a7b3a02e17546cc`.
- Checkpoint SHA-256 `46a0b8941c4ca76859fce597255dc5da6f09e81f40ac34c5e165cddeba37392f`.
- Existing A PLY: 14,428,563 points, SHA-256 `9d0c1cc5cbad53805db1a9868a52785fd12d7c0b0c6fff3ae145a96bfaec7d27`.
- Existing aligned `C_batch` PLY: 13,504,105 points, SHA-256 `26370338c628e379ff3ceee347f801d17e4772101a1eb14f422eb6c5f8005354`.
- Existing rolling-C final dense input and fusion directories under `work_C_dense` are immutable comparison inputs.

Only the resident DB main file is copied. Its dataless WAL/SHM/ARKit sidecars are never read or copied.

### Acceptance thresholds and stop conditions

- Replay must reproduce the exact four rolling BA events at registered counts 25/50/75/100, `fed=101`, `missing_pose=0`, no skip, and the frozen `live_end` binary hashes. The production implementation reads `OFFICIAL_AETHER_INCREMENTAL_GLOBAL_BA`; the replay bench/log historically names `AETHER_INCREMENTAL_GLOBAL_BA`. Both are set to `1`, but only the prefixed spelling is treated as the functional gate.
- Exactly ten inference epochs are used: `reg00020` through `reg00100`, then `live_end`; epoch cohorts total 98 and cover global dense IDs 0–97 exactly once.
- Snapshot selection is the historical M=10 rule made exact for this replay: `feed_ordinal = actual_frame_id + 1`; use snapshot `ceil((feed_ordinal + 10)/10)*10`, capped at `live_end`. The rolling dumps are exact actual-frame prefixes, so the epoch is not recomputed from the filtered dense ID.
- Before conversion, every snapshot is restricted to the names that are both present in that actual-frame prefix and in the immutable ordered 98-name dense manifest. The filtered records are written in final manifest order, and a checked local-ID↔global-dense-ID map must be the identity. Every cohort retains its snapshot-derived ref pose, depth range, ordered top-10 sources, checkpoint, fixed seed `20260818 + global_dense_id`, and official output format.
- Every ref must emit one depth PFM, three confidence PFMs, and one image. Missing/duplicate IDs stop the run.
- Final `journal_out/cams` must be byte-identical to existing final `C_batch` cams; final fusion `pair_folder` must be the existing final `C_batch` pair list. Frozen epoch cams/pairs remain provenance only.
- `dense_C_journal.ply` must pass the existing strict PLY verifier. The exact existing C-to-A similarity, derived from the same rolling-C `live_end`, is applied; it is not refit to the journal cloud.
- Viewer uses every vertex of all three PLYs. No random, uniform, voxel, quantized, LOD, or display-time sampling.
- The pinned legacy fusion, alignment, bin exporter, and page-template tools may overwrite their direct destinations. They therefore run only inside invocation-unique, previously nonexistent staging directories. Root verifies each staged artifact, then publishes it by atomic no-clobber promotion with an ownership-qualified JSON commit marker. A failed invocation removes only its own staged inode/tree; it never calls a pinned overwrite-capable tool on a canonical path.
- The experiment has no invented quality pass/fail threshold. It reports existing descriptive meters and gives the user the synchronized full-resolution page for the requested visual choice.
- Abort before the next expensive stage if any identity, cohort, source-count, file-count, disk-free (`<8 GiB`), or resident-file gate fails. Never shrink the frame set or silently lower `num_view`.

### Ownership

- Implementer may write only:
  - `_host_experiments/live_vs_refined_20260820/journal_C/tools/journal_pipeline.py`
  - `_host_experiments/live_vs_refined_20260820/journal_C/tests/test_journal_pipeline.py`
- Root owns the preregistration, plan, real experiment outputs, logs, reports, alignment, viewer generation, server, and final integration.
- Reviewers are read-only.

---

## Task 1: Freeze the preregistration and implement the journal assembler (TDD)

**Files:**

- Create: `_host_experiments/live_vs_refined_20260820/journal_C/PREREG.md`
- Test: `_host_experiments/live_vs_refined_20260820/journal_C/tests/test_journal_pipeline.py`
- Implement: `_host_experiments/live_vs_refined_20260820/journal_C/tools/journal_pipeline.py`

### Required command surface

The tool exposes small, composable, no-overwrite subcommands:

1. `preflight`: validate hashes, resident inputs, free disk, and absent output targets; write a canonical JSON report atomically.
2. `verify-replay`: parse the captured replay log, validate exact event sequence and final model hashes, validate exactly the expected dump directories and prefix frame sets, and write canonical JSON.
3. `assemble-epochs`: read the immutable manifest/photo map and rolling dumps; create ten sparse prefix inputs, run-independent cohort pair files, `freeze_map.json`, and provenance reports while preserving global dense IDs.
4. `assemble-journal-out`: verify all 98 cohort inference products, install their depth/conf products into one output tree, and install final C cams/images as byte-identical no-overwrite copies or links with a coherence report.
5. `verify-journal-out`: re-open every published artifact and verify ID coverage, hashes/counts, final-cam identity, final-pair identity, and absence of partial files.

### TDD sequence

1. Write synthetic COLMAP binary fixtures and tests for the exact M=10 cohort mapping. Run the focused test and observe failure because the tool is absent.
2. Implement only the mapping and binary record filtering needed to pass.
3. Add failing tests for duplicate/missing frame IDs, non-prefix snapshots, unexpected dump names, existing output paths, dataless inputs, and low disk.
4. Implement strict validation and atomic no-clobber publication.
5. Add failing tests proving that final cams/pair come from `C_batch` while frozen cams/pair remain provenance, that every depth/conf ID appears exactly once, and that a partial inference cannot publish a coherent report.
6. Implement output assembly and re-open verification.
7. Run the complete test file under `-W error` with both the project Python and Homebrew Python, then `py_compile`.

**Acceptance command:**

```bash
/usr/bin/perl -e 'alarm 180; exec @ARGV' -- \
  /Users/kaidongwang/.venv/pocketworld/bin/python -W error -m unittest discover \
  -s /Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C/tests \
  -p 'test_journal_pipeline.py' -v
```

Then repeat with `/opt/homebrew/bin/python3.11` and compile both owned Python files.

---

## Task 2: Reproduce rolling-C and publish periodic sparse snapshots

1. Create the fresh `journal_C` staging directories with explicit paths and no overwrites.
2. Copy only the exact resident `e29f…` DB main file to `replay_input/official_sfm_live.db`; rehash the copy before opening it.
3. Run `official_replay_bench_exe` under a 300-second hard timeout with:
   - `OFFICIAL_AETHER_INCREMENTAL_GLOBAL_BA=1` (the production `getenv` gate)
   - `AETHER_INCREMENTAL_GLOBAL_BA=1` (bench/log compatibility only)
   - `OFFICIAL_AETHER_LIVE_POSE_DUMP=<journal_C/dumps>`
   - `OFFICIAL_AETHER_LIVE_POSE_DUMP_EVERY=10`
   - `--k=12 --max-frames=0`
4. Capture stdout/stderr to a no-overwrite `replay.log`.
5. Run `verify-replay`; stop unless the normalized log, dump topology, 101-frame `live_end`, and final three binary hashes reproduce the frozen C evidence.

Execution note frozen 2026-08-21 16:47:31 +0800: attempt 1 proved the bench does not create `out_dir`; it exited before feeding frames and its log is retained. Because even that failed open changed the private SQLite copy's raw physical hash, retry quarantines that copy, makes a fresh verified `e29f…` copy, and uses distinct `*_attempt2` paths. The empty replay output directory is created before launch; no algorithm input or parameter changes.

Attempt-2 ruling before dense inference: the replay reproduced the exact event sequence and final statistics. Its final model differs from historical rolling-C only at multithreaded floating-point noise (camera-center max `2.708e-11` m, rotation max `2.415e-6` degrees, same-ID point max `5.824e-10` m). Dense assembly therefore uses attempt-2 periodic snapshots plus the byte-frozen historical `dumps_C/live_end`, preserving the exact existing `C_batch` final cameras/pair for final re-fusion.

Pre-inference causal fallback ruling (2026-08-21 17:22:25 +0800): global dense ID 38 has zero sparse anchors at its frozen `reg00060` state. Reuse the already-shipped research streaming rule, not a new recipe: `<8` anchors → `[0.3/s_al,4.0/s_al]`; no covisibility → nearest cameras past `0.06/s_al`. Frozen values are `s_al=0.9839283096870955`, range `[0.3049002626,4.0653368346]`, first nine sources `[37,39,36,35,40,8,46,9,0]`. The adapter must hash-pin the original converter and leave every non-empty path unchanged. Pair validation is aligned with the official loader (at least one positive non-self source; ten is an upper bound), because the prior nine-positive gate rejects valid existing `C_batch` records and was not part of the official algorithm.

Inference execution note: a first `reg00020` launch with extra `-W error` stopped before any output when PyTorch emitted its existing `torch.meshgrid` deprecation warning. Real inference removes only that development warning policy and otherwise preserves the frozen command.

Resource note after the first completed epoch: macOS performed a one-time 1,744.94-MiB encrypted-swap expansion while only 15.36 MiB of new pageouts occurred; after the model process exited, `memory_pressure -Q` reported 48% free and disk had 32.96 GB free. This operational-only threshold is transparently amended to accept that initial cold-page migration. All later epochs remain sequential and retain the 1-GiB per-epoch swap/pageout stops, plus a 25% memory-free and 8-GiB disk floor.

---

## Task 3: Generate frozen epoch inputs and infer all 98 journal depths

1. Run `assemble-epochs` and verify the fixed cohort table:

| Epoch | Global IDs | Actual frame IDs | Count |
|---|---|---|---:|
| reg00020 | 0–9 | 0–9 | 10 |
| reg00030 | 10–19 | 10–19 | 10 |
| reg00040 | 20–29 | 20–29 | 10 |
| reg00050 | 30–37 | 30–36,38 | 8 |
| reg00060 | 38–46 | 40,42–49 | 9 |
| reg00070 | 47–56 | 50–59 | 10 |
| reg00080 | 57–66 | 60–69 | 10 |
| reg00090 | 67–76 | 70–79 | 10 |
| reg00100 | 77–86 | 80–89 | 10 |
| live_end | 87–97 | 90–100 | 11 |

2. For each epoch, run the pinned `colmap_input.py --num_src_images 10` against the frozen manifest-restricted prefix model. Verify its emitted `000000NN` ID map against the stored global dense IDs before inference.
3. Create a separate fresh `mvs_cohort` provenance root with the prefix-sized MVS cams/images and a no-clobber cohort-filtered `pair.txt`. Keep the original conversion output immutable. The journal tool receives this root through `--epoch-mvs LABEL=PATH`.
4. Run pinned `run_arm_lever.py` sequentially with `mvs_cohort` as input and a distinct empty `out` directory, batch=1, MPS, 768×576, `num_view=10`, seed 20260818. The `out` tree must contain cohort-only cams/images/depth/conf and is passed as `--epoch-out LABEL=PATH`; it is never pre-seeded or overlaid on MVS inputs. Do not overlap model processes. A repeated model load is accepted because it reduces new runner code and does not alter outputs.
5. After every epoch, verify its expected global IDs and report progress. Record `vm_stat` and `sysctl vm.swapusage` immediately before and after each epoch; abort before the next epoch if pageouts increase by at least 65,536 16-KiB pages (1 GiB), swap used grows by at least 1 GiB, an output is missing, or a source count is silently reduced.
6. Run `assemble-journal-out` and `verify-journal-out` to form one 98-frame cache.

---

## Task 4: Re-fuse with final rolling-C geometry and align with the frozen transform

1. Create a fresh unique fusion staging directory and run the pinned official `fuse_arm.py` only against a PLY path inside that staging directory, with:
   - `pair_folder=work_C_dense/mvs` (final C pair list)
   - `out_folder=journal_C/journal_out` (journal depth/conf plus final C cams/images)
   - output `dense_C_journal.ply`
2. Strictly verify PLY schema, byte length, finite XYZ/RGB, exact point count, and SHA-256.
3. In a second fresh staging path, apply the already-frozen C-to-A Sim(3) from `gauge_c_to_a.json` to every journal vertex. Do not estimate another transform.
4. Verify RGB preservation, exact vertex-count preservation, and the transform identity in `aligned_C_journal_report.json`.
5. Record existing descriptive metrics using the already-established scripts/definitions; do not create a new scoring algorithm.

---

## Task 5: Publish and test the full-resolution visual comparison

1. Create a fresh invocation-unique staging directory containing aliases for:
   - `dense_A.ply`
   - `aligned_C_batch.ply`
   - `aligned_C_journal.ply`
2. Run pinned full-resolution `export_bins.py --ref A --arms A,C_batch,C_journal`.
3. Generate `index.html` from the already-accepted synchronized WebGL viewer, changing only the data plan and factual labels. The pane order is exactly `A_refined`, `C_batch`, `C_journal`. Export and page generation remain inside staging until the bin sizes, metadata, HTML, and manifest all verify; only then is the complete directory atomically promoted without replacement.
4. Validate bin sizes (`pos=N×12`, `col=N×3`), meta counts, PLY counts, fetch paths, draw counts, and absence of sampling tokens.
5. Serve the completed directory on `127.0.0.1:8732`, keeping the process alive independently of the build shell.
6. Use the real browser to verify HTTP 200, all six binary fetches, three WebGL contexts, synchronized rotate/pan/zoom/point-size controls, no console error/context loss, and visible clouds at the shared initial camera.
7. Ask the user to inspect overall room, floor/table boundary, bin rim, window frame, and right-wall floating layer and choose `C_batch` or `C_journal`.

---

## Task 6: Independent final acceptance

A fresh read-only reviewer receives this plan, the preregistration, file hashes, test output, replay normalized report, freeze map, inference/fusion logs, PLY reports, viewer manifest, and browser evidence. It must check:

- same single capture and exact 98-frame coverage;
- no use of old rolling-off dumps;
- correct frozen-epoch inference versus final-C fusion separation;
- no hidden recomputation or frame substitution;
- same C-to-A transform for both C arms;
- full-resolution viewer with copied interaction behavior;
- every claim supported by a fresh command/result.

Only the root agent may issue the final accept/rework/abort decision.

---

## Pinned executable, code, and environment identities

The real sparse replay may begin after preflight re-hashes all compute inputs and the reviewed `journal_pipeline.py`. The reviewed viewer-adapter hash is required before viewer generation and publication, but it does not gate replay or dense inference because it cannot affect any pose, depth, confidence, fusion, or PLY byte. This sequencing clarification was frozen at 2026-08-21 16:35:34 +0800, before the first real journal replay, after the earlier all-stages viewer gate was found to delay an independent computation.

The reviewed journal assembler is `/Users/kaidongwang/Documents/progecttwo/_host_experiments/live_vs_refined_20260820/journal_C/tools/journal_pipeline.py`, SHA-256 `ccb0c22b1ef9faa57d4e569530b5b32d54a840f84e671a34082333e6161dcc1e`; its tests are SHA-256 `b24972b09a5242465b90660a63d5ba9e35e6afc0aecdae586984982db46bb505`.

| Role | Absolute path | SHA-256 |
|---|---|---|
| replay executable | `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/third_party/glomap_vendor/build-host-fullbench/official_replay_bench_exe` | `bc6e5eb4531b055b071bd20b93ee6a0e0b9cdf74f7798c57a08cc28497604909` |
| COLMAP→MVS | `/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/diffmvs/colmap_input.py` | `acad2a24abf1ed9de46d6aa55bf04fed559b6aabcc603f41127c8b9ce9a7ba69` |
| fixed-noise runner | `/Users/kaidongwang/Documents/progecttwo/_artifacts/lever1_source_reform_20260818/run_arm_lever.py` | `593113e569e97d9c238a3ef5a02c7b3d05866d701d77730aaaba3b1c394b8416` |
| fusion wrapper | `/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/experiments/mvs_pose_ablation_2026-08-18/tools/fuse_arm.py` | `13fb753b65fc81f40583400489c2e5d4dcfb744f8e810abfd0fee683276c790f` |
| fusion implementation | `/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/tools/python/diffmvs/filter.py` | `c46efb40f15297c62ee8932cce8197bd7f360737c338e6de2d42c9bab52379cb` |
| gauge application | `/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/experiments/mvs_pose_ablation_2026-08-18/tools/apply_gauge.py` | `8061ae457ab4539867f97867ee0077dba86be82efd732245967540d2414d2151` |
| full-resolution exporter | `/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/experiments/mvs_pose_ablation_2026-08-18/tools/export_bins.py` | `9752c7bae83a57ac08bf6e536031aaeb5989b25681086a99cd623bc08921ea8d` |
| accepted WebGL template | `/Users/kaidongwang/Developer/Aether3D-cross/pocketworld_research_benchmarks/experiments/mvs_pose_ablation_2026-08-18/tools/build_page_fullres.py` | `d5f5c2c56246bbf29916887399e00a663de5cb22d290db2e0afc5ce553abaa07` |

The DiffMVS code-tree digest is `779532d356cc7693c37da44ae504368a6f1d705f9209c3414e49afccbee0eb10`, computed over 82 resident regular files and 105,275,058 bytes as length-delimited `(relative_path, content)` records, excluding `__pycache__`; any dataless member aborts the digest.

Runtime is `/Users/kaidongwang/.venv/pocketworld/bin/python`, CPython 3.11.15, real executable SHA-256 `831807be3d255aae0708810462ce0cde2467235f7daaa86e93d0ddc58b1a4101`, `pyvenv.cfg` SHA-256 `4f4b31c030c004fa8996587bc92b802d993c1a3e4e303db9e8a8c94baf8af59f`, and sorted `pip list --format=freeze` SHA-256 `68df4580c456527b47ea854530cbeadfcd445584898ab0db988303d086514301`. Effective core versions are torch 2.12.0, NumPy 1.26.4, OpenCV 4.11.0, and pycolmap 4.0.4; MPS must report both built and available. Import order remains the runner's `numpy → torch → cv2`.
