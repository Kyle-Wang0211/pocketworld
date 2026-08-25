# PTOL Phone A/B and Upright MAGSAC Consensus Design

## Objective

Run a physical-iPhone production A/B for global Ceres
`parameter_tolerance=0` versus the Ceres 2.2.0 default `1e-8`, then build a
separate, default-off experiment that keeps PocketWorld's current
gravity-constrained upright three-point model and changes only the robust
consensus layer to an OpenCV 5.0.0 MAGSAC-compatible score, termination rule,
and local-optimization pass. GC-RANSAC is outside this work.

The two packages must never share one result or candidate build. The PTOL
verdict must be recorded before any MAGSAC candidate is allowed onto the phone.

## Frozen production identity

- Device class: physical iPhone 14 Pro (`iPhone15,2`).
- Production bundle: `com.kyle.PocketWorld`, build 32.
- Installed-candidate source artifact:
  `/private/tmp/pw-splash-solving-20260825T043900Z/flutter-build/ios/iphoneos/Runner.app`.
- `PWOfficialSfm` SHA-256:
  `bd1220f12b84b6de06319bda28e2902d375b59b9150d3dd947bc1d04afc34062`.
- Dart AOT (`App.framework/App`) SHA-256:
  `0eaad9ff7442d9cbcb5b8c65854de3d31ca0146737ca6b6a745abd8deb5f9a49`.
- Runner SHA-256:
  `a62c7ee440e6d7f574e5f49bafc41cf5188cfae587861a7d73de843223bf2005`.
- Both arms keep AR-every-frame enabled because it is part of the installed
  production state.

Before the first device write, a fresh Documents and Library backup must be
copied and hash-verified. The fresh phone copy of every selected input must
match the frozen hashes below. A mismatch stops the run and creates a new run
identity; it is never silently accepted as the same experiment.

## Package A: global PTOL physical-phone A/B

### Approaches considered

1. **Existing build, environment file, existing reconstruction gate.** Push a
   read-modify-write `official_env.json`, restart the app, and trigger
   `pw_b1_gate_request.json` for the same capture. Compare only the gate's
   `rebuild_full` result; the pruned result is not an experimental replicate.
   This requires no rebuild or installation and is suitable for a direction
   screen, but it does not persist a per-arm PLY or final post-BA cost.
2. **Separate PTOL benchmark bundle using the production pipeline.** Build
   `com.kyle.PocketWorld.PtolBench` from the frozen current product snapshot,
   link the exact registered `PWOfficialSfm`, copy the frozen capture into its
   separate container, and run one arm per fresh identical input copy. This can
   persist full PLY and quality artifacts without touching the production app
   container.
3. **Recapture a scene for each arm.** This uses the normal UI but violates the
   same-input requirement and confounds camera motion, exposure, temperature,
   and capture scheduling.

The selected approach is staged: Approach 1 first, strictly labeled a
mechanical direction screen. If `1e-8` does not beat twice the A/A noise floor,
the lever stops without building anything. If it is promising, Approach 2 runs
the complete physical-phone quality A/B. An in-place production app update is
not part of either stage.

### Frozen input

The first input is the completed 136-frame capture
`cap_1787545807521946`, selected because its prior production finalize spent
about 50.8 seconds and therefore has enough global-BA work to expose a useful
PTOL effect.

- `official_sfm_live.db.zpaq` SHA-256:
  `9114ec5e078f1730fe4f399789e26994bd26cbaacecb4f6c19f3c3120f2fc3f4`.
- `official_sfm_live.db.arkit_pose_v1` SHA-256:
  `d4f6d3c079cf9993cee9dceb7b5e3445ac990f1f2626986b95acbdcb35b615c1`.
- `official_database_archive.json` SHA-256:
  `3e0757b9f3ae3a9e69c087c9a2f7c5d7c0ad0fc47f2e59531634ba8d19874f7e`.
- Frozen delivered reference: 136 registered images, 78,832 delivered points,
  raw reconstruction reprojection error 1.2334 px.

The gate materializes the archive and copies it under
`Documents/pw_b1_gate/<capture-id>/`; it never modifies the source capture.

### Arms and ordering

- A: `OFFICIAL_AETHER_GLOBAL_PTOL` absent or empty, which preserves the
  production `parameter_tolerance=0.0` path.
- B: `OFFICIAL_AETHER_GLOBAL_PTOL="1e-8"`, the Ceres 2.2.0 default.
- Required order: `A B A B`, followed by `B A` only when the first four runs are
  inconclusive under the registered noise floor.
- Each arm starts from an app restart so `official_env.json` is applied before
  any native call. The device log must contain the matching `EnvFile applied`
  receipt for B and must show no positive global PTOL for A.
- Runs are serial. No capture, VIO experiment, archive job, or other
  reconstruction may overlap them.

The shared environment file is always updated by reading the phone copy,
changing only `OFFICIAL_AETHER_GLOBAL_PTOL`, and writing the merged JSON back.
After the run, that key is restored to its exact pre-run state. The source
capture and all pre-existing Documents and Library files must remain
byte-identical; new gate artifacts are copied to the experiment ledger and
then may be removed only after their hashes are recorded.

### Measurements

Primary speed metric:

- paired percentage change in `rebuild_full.refine_ms`, ranked by the median of
  the paired A/B changes.

Required supporting metrics:

- `rebuild_full.elapsed_ms`;
- `official_finalize_segments.json`: `stage1_ms`, `stage2_ms`, `total_ms`,
  stage-1 rounds and stage-2 round budget;
- every `ba_rounds` record in the measurement time window: solve time,
  iterations, termination code, Jacobian, linear-solver, residual,
  preprocessor, minimizer, and postprocessor time;
- successful/unsuccessful solve counts and `NO_CONVERGENCE` rate;
- registered image count, delivered point count, raw `n_points3d`, reprojection
  error, track length, return code, and result string;
- device thermal state before and after each arm, when available from existing
  telemetry; missing thermal evidence invalidates a speed comparison rather
  than being guessed.

Stage-0 validity gates are evaluated before speed:

- every run succeeds with the same registered-image count;
- no new reconstruction failure, missing stage, non-finite metric, or mixed
  arm receipt;
- phase-1 reprojection and delivered-point differences must remain inside the
  measured A/A noise floor; point count alone can never approve the candidate;
- the current gate does not emit a PLY or final post-BA cost/reprojection, so
  Stage 0 can establish only a timing/mechanical direction and cannot approve
  quality or a shipping default.

### Stage-1 separate-bundle quality A/B

Stage 1 runs only after a promising Stage-0 verdict. The signed bundle
identifier is `com.kyle.PocketWorld.PtolBench`; it has its own app-data
container and never reads or writes `com.kyle.PocketWorld` at runtime. Its
native framework must match the registered `PWOfficialSfm` SHA-256, and both
arms must have byte-identical app, Dart AOT, input, and configuration except for
the effective PTOL value.

For every arm, the harness copies the same frozen materialized DB and pose
sidecar into a new run directory, invokes the production `SfmLiveRecon` resume
and finalize path, and persists the refined snapshot as PLY plus the raw
summary, final cost/reprojection when exposed by the native summary, BA rounds,
finalize segments, environment receipt, and input/output hashes. ABAB ordering
and physical-device thermal evidence remain mandatory.

The full quality gate requires identical registration-chain completeness,
reprojection inside the A/A noise floor, no new failure, preserved PLYs, and
side-by-side visual inspection in the product's established order: floating
outliers/ghost layers, coverage bands, roughness, then point count. A successful
Stage 1 still records a candidate; it does not change the shipping default.

### Stopping rules

- Stop invalid if input hashes, app identity, environment receipt, or
  reconstruction exclusivity cannot be proved.
- Stop negative if B fails a required quality gate or its speed improvement is
  below twice the paired A/A noise floor.
- Stop promising after Stage 0 if B clears its validity gates and exceeds the
  noise floor; then run Stage 1 rather than promoting it.
- Stop candidate after Stage 1 only if the complete numeric and visual gates
  pass. A separate user decision is required to change the shipping default.
- Never sweep `1e-7` or `1e-6` in this run. Those are independent ablations,
  not the Ceres-default reproduction.

## Package B: upright-model MAGSAC consensus experiment

### Model boundary

The following behavior is immutable:

- gravity normalization;
- PoseLib `relpose_upright_3pt` minimal solver;
- three-correspondence sample size;
- normalized-ray construction and squared Sampson residual;
- homography/planar classification as a separate COLMAP path;
- deterministic seed and match ordering;
- current status mapping, watermark handling, and `TwoViewGeometry` output.

The experiment may replace only hypothesis scoring, trial termination, and the
post-selection local-optimization/refinement stage inside the upright-pose
branch. It must not call generic `findEssentialMat`, change the minimal model,
or alter the homography branch in its first iteration.

### Approaches considered

1. **Adapter around the current upright solver (selected).** Define a small
   consensus interface over generated upright poses and Sampson residuals.
   Keep the incumbent inlier-count implementation and add a default-off
   OpenCV-5.0.0-derived MAGSAC implementation behind the same interface.
2. **Embed OpenCV USAC wholesale.** This preserves upstream machinery but its
   estimator interfaces and generic E/F models do not accept the current
   gravity-constrained PoseLib solver without a broad adapter and dependency
   expansion.
3. **Use generic OpenCV `findEssentialMat(..., USAC_MAGSAC)`.** This changes
   both the geometric model and the consensus method and is rejected.

Approach 1 is selected. Source provenance must identify the exact OpenCV 5.0.0
files and copied equations. Any intentional deviation must be named in the
experiment artifact rather than described as exact upstream behavior.

### Components

- `upright_relative_pose_v1` remains the public production entry point and
  keeps incumbent behavior as the default.
- A focused consensus component receives candidate poses and residuals. Its
  incumbent mode reproduces the current inlier-count/tie-break logic exactly.
- Its experimental mode implements the OpenCV 5.0.0 MAGSAC quality score,
  termination estimate, MAGSAC weight function, and local optimization using
  the same constants and ordering as the pinned source wherever the upright
  model permits it.
- A C-layer environment arm selects the experiment; absence is exact incumbent
  behavior. No Swift default is allowed.
- Telemetry records arm, trials, score, inlier count, local-optimization count,
  termination reason, and per-pair wall time.

### Test strategy

Tests are written before production code and must first fail for the missing
experimental behavior.

- incumbent golden tests: identical seed, status, pose, inlier indices,
  `num_trials`, and edge-case validation;
- OpenCV provenance vectors: fixed residual arrays compared with values
  generated from the pinned OpenCV 5.0.0 implementation;
- deterministic repeat tests for both arms;
- model-boundary tests proving both arms invoke the upright three-point solver
  and never the generic essential-matrix estimator;
- local-optimization tests for too-few-inlier, all-inlier, high-outlier, and
  threshold-boundary cases;
- end-to-end same-match host replay as diagnostic evidence only;
- no phone installation until host tests, license/notice audit, binary-symbol
  audit, and an independent read-only review pass.

### Acceptance and stop conditions

- Default mode is byte-for-byte incumbent at its externally visible outputs on
  the registered fixtures.
- The experiment is deterministic under the frozen seed and ordered matches.
- The first MAGSAC host comparison is diagnostic; it cannot select a production
  winner.
- A phone candidate is considered only if host evidence shows that the adapter
  actually changes consensus behavior, preserves registration-chain
  completeness on all fixtures, and has a credible path to at least 2% total
  capture-period improvement.
- Any visible degradation, broken chain, license/notice conflict, generic-model
  substitution, or inability to isolate the consensus layer stops the arm.
- GC-RANSAC, spatial neighborhoods, and graph-cut energy terms are explicitly
  excluded.

## Data and evidence flow

Every measurement is written to a versioned experiment directory before the
next arm runs. The record includes app/framework hashes, exact input hashes,
effective environment, arm order, timestamps, device/OS identity, thermal
evidence, raw pulled files, parsed metrics, deviations, and verdict. Failed and
invalid runs are retained. Host diagnostics and phone acceptance are labeled
separately and never combined into one speed claim.

## User and device safety

No uninstall command is permitted. Package A Stage 0 performs no app
installation; Stage 1 installs only `com.kyle.PocketWorld.PtolBench` and never
targets the production bundle or container. Any future Package B device update
must use a separate test bundle or the
production incremental-update runbook, with a fresh verified container backup,
exact current dirty-source manifest, byte-identical Dart AOT control/candidate
proof, valid deep signature, and explicit user authorization immediately before
the device install command.
