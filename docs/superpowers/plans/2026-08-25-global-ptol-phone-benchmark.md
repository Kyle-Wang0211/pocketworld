# Global PTOL Physical-iPhone Benchmark Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to execute this plan.

**Goal:** Build and run a container-isolated physical-iPhone A/B/A/B mechanical screen of the existing native `OFFICIAL_AETHER_GLOBAL_PTOL` hook at `0` versus Ceres' official `1e-8` default, without changing or installing over the daily-use PocketWorld application. This frozen-database replay may nominate a later end-to-end phone candidate; it cannot approve a production value.

**Architecture:** A dedicated Flutter entrypoint runs four sequential reconstruction arms through the production `SfmLiveRecon` and registered `PWOfficialSfm` framework. The host runner copies one frozen archived capture into the separate `com.kyle.PocketWorld.PtolBench` container, launches the benchmark, pulls all JSON/PLY/native-segment artifacts, and validates input, bundle, framework, arm order, parameter values, and result completeness. Each arm starts from a byte-identical materialized SQLite database copy; only `OFFICIAL_AETHER_GLOBAL_PTOL` differs.

**Tech Stack:** Flutter 3.47.1 / Dart 3.13.1, iOS 26.2 SDK, `xcodebuild`, `codesign`, CoreDevice `devicectl`, production Dart SfM facade, `PWOfficialSfm.xcframework`, SHA-256 manifests, YAML experiment contract, MLflow file store for run metadata.

---

## Frozen contract

- Product repository: `/Users/kaidongwang/Developer/pocketworld`
- Starting revision: `a8b94ca0e35158c8aca7c2e3f66f11269fa385f6`
- Working branch: `codex/ptol-phone-ab-20260825`
- Device: iPhone 14 Pro, CoreDevice ID `1B290474-D354-5B4C-AAB0-0805AC5DC832`, UDID `00008120-00146C4A1AEBC01E`
- Production bundle that must not be mutated: `com.kyle.PocketWorld`
- Benchmark bundle: `com.kyle.PocketWorld.PtolBench`
- Input capture: `cap_1787545807521946`
- Input archive SHA-256: `9114ec5e078f1730fe4f399789e26994bd26cbaacecb4f6c19f3c3120f2fc3f4`
- Input archive manifest SHA-256: `3e0757b9f3ae3a9e69c087c9a2f7c5d7c0ad0fc47f2e59531634ba8d19874f7e`
- Pose sidecar SHA-256: `d4f6d3c079cf9993cee9dceb7b5e3445ac990f1f2626986b95acbdcb35b615c1`
- Materialized SQLite SHA-256: `f829c281aea6ed7956e3afb134959b663cf35cfee633956029c09d3b2af3290d`
- Required arm order and only changed variable: `A1:0`, `B1:1e-8`, `A2:0`, `B2:1e-8`
- Required native framework SHA-256: `bd1220f12b84b6de06319bda28e2902d375b59b9150d3dd947bc1d04afc34062`
- Seeds: native deterministic sampling as compiled; no seed override. The exact native framework hash is the seed-identity evidence.
- Hardware/backend: the named physical iPhone and production native reconstruction framework, resuming a frozen SQLite database with its production ARKit sidecar. Capture-time Metal feature extraction/matching is not rerun in this diagnostic replay.
- Pose-route boundary: the current product route is ARKit. The parallel XRSLAM/VIO work remains a shadow cross-platform route and is excluded from all four PTOL arms; the replay seeds only the frozen production ARKit sidecar.
- Stop immediately on wrong bundle ID, wrong device, input/hash mismatch, native framework mismatch, missing arm PLY, arm failure, or any command targeting `com.kyle.PocketWorld`.
- No uninstall command is permitted. No copy, launch, terminate, install, or container operation may target the production bundle.

## Pre-registered measurements and verdict

- Primary speed metric: per-arm wall-clock `elapsed_ms` from immediately before `SfmLiveRecon.start` until `SfmLiveRefined` or failure.
- Supporting speed metrics: `refine_ms`, snapshot `summary`, and per-arm `official_finalize_segments.json` when produced.
- Quality invariants: reconstruction succeeds; registered cameras equal control; delivered point count within ±1%; reported reprojection error does not regress by more than `0.01 px`; every arm emits a non-empty PLY and metadata JSON.
- Repeatability: compare A1/A2 and B1/B2; flag an arm family unstable if wall time differs by more than 10% or registered cameras differ.
- PTOL advances only to a later full end-to-end physical-phone candidate experiment if both B arms pass quality, B median wall time is strictly lower than A median, and the improvement exceeds the larger of 5% or the observed within-family noise. `production_eligible` remains false for this replay.
- Missing Ceres final cost is recorded as an instrumentation limitation, not invented or inferred. The experiment may reject PTOL; it may not claim complete numerical equivalence without that measurement.

## Task 1: Freeze the exact local source and input identities

**Files:**

- Runtime receipt: `/private/tmp/.../source-status.txt`
- Runtime receipt: `/private/tmp/.../unstaged.patch`
- Runtime receipt: `/private/tmp/.../staged.patch`
- Runtime receipt: `/private/tmp/.../source-content.sha256`
- Create: `experiments/global_ptol_phone_ab_20260825/candidate-identity.yaml`
- Create: `experiments/global_ptol_phone_ab_20260825/input-manifest.sha256`
- Create: `experiments/global_ptol_phone_ab_20260825/experiment-contract.yaml`

1. Record HEAD, complete status, binary staged/unstaged diffs, and SHA-256 for tracked plus relevant untracked files under the private run root. The local binary diff is about 30 MB, so it remains a runtime receipt rather than being duplicated into the product repository.
2. Hash the frozen capture archive, archive manifest, pose sidecar, and fed-frame sidecar.
3. Write the versioned experiment contract with the identities and thresholds above.
4. Validate YAML parsing and re-run every recorded hash. Include the experiment contract, thresholds, input manifest, and baseline source receipt in the content gate. Pin the self-referential runner and candidate identity receipt separately using literal SHA-256 values in the Terminal invocation.

## Task 2: Write the failing benchmark contract tests

**Files:**

- Create: `test/global_ptol_benchmark_contract_test.dart`
- Create: `lib/official_capture/global_ptol_benchmark_gate.dart`

1. Add a test that reads the host runner and entrypoint and requires the independent bundle ID, `--no-pub`, `CODE_SIGNING_ALLOWED=NO`, no uninstall, no production-bundle device command, exact four-arm order, exact PTOL values, exact frozen hashes, framework hash check, result pull, and final validation marker.
2. Add pure gate tests for immutable input identity, exact arm order, quality limits, repeatability, and the preregistered winner rule.
3. Run `flutter test test/global_ptol_benchmark_contract_test.dart` and capture the expected failure because the implementation files/functions do not exist yet.
4. Implement only the pure gate file and re-run the pure tests; runner/entrypoint contract checks must remain red until Task 3.

## Task 3: Implement the separate-bundle on-device A/B/A/B entrypoint

**Files:**

- Create: `lib/global_ptol_benchmark_main.dart`
- Modify: `lib/official_capture/global_ptol_benchmark_gate.dart`

1. Initialize a minimal Flutter status UI and write `global_ptol_benchmark_result.json` atomically throughout the run.
2. Verify the copied archive, archive manifest, pose sidecar, and their SHA-256 values before native code runs.
3. Materialize the source SQLite through the production `DatabaseArchiveResolver`; verify materialized bytes and SHA-256.
4. Create independent A1/B1/A2/B2 directories and copy the same SQLite and pose sidecar into each.
5. Immediately before each arm, call `AetherProcessEnv.unset('OFFICIAL_AETHER_GLOBAL_PTOL')` then set the exact arm value (`0` or `1e-8`).
6. Run production `SfmLiveRecon.start` plus `resumeFromDb(imageWidth: 4032, imageHeight: 3024)`, wait up to 25 minutes, and dispose the recon object before the next arm.
7. Persist every refined snapshot with `persistSparseSnapshot`, using the snapshot RGB buffer so every arm has a full geometry PLY and metadata.
8. Copy/record per-arm finalize-segment artifacts when available and write the effective value, elapsed time, refine time, registered cameras, point count, summary, PLY bytes, and PLY SHA-256.
9. Evaluate the preregistered gate only after all four arms complete. Always unset PTOL in `finally`.

## Task 4: Implement the host build/install/run/pull harness

**Files:**

- Create: `tool/run_global_ptol_phone_ab.sh`

1. Refuse any input directory whose three required hashes differ from the frozen contract.
2. Create all config, build, derived-data, and downloaded-artifact paths under `/private/tmp`.
3. Build the dedicated entrypoint with the already pinned Flutter SDK and `--no-pub`, then build unsigned with `xcodebuild`, setting only `PRODUCT_BUNDLE_IDENTIFIER=com.kyle.PocketWorld.PtolBench`.
4. Verify the actual bundle ID, arm64 slice, benchmark marker, exact embedded `PWOfficialSfm` binary SHA-256, and absence of production-only memory entitlements.
5. Sign nested frameworks and app with the already verified wildcard profile and identity; run `codesign --verify --deep --strict`.
6. Install only the benchmark app with `devicectl device install app`; copy only the frozen benchmark input to its app-data container; launch only its bundle ID.
7. Poll and pull the JSON result, all arm JSON/PLY/meta/segment artifacts, validate the run ID and gate, and print `IPHONE_GLOBAL_PTOL_AB_OK`, `..._NOT_ELIGIBLE`, or `..._FAILED`.
8. The script must contain no uninstall command and no `devicectl` operation whose target/domain identifier is `com.kyle.PocketWorld`.

## Task 5: Local verification and independent review

1. Run `dart format` on the new Dart files.
2. Run `flutter test test/global_ptol_benchmark_contract_test.dart`.
3. Run `flutter analyze` on the new Dart files and test.
4. Run `sh -n tool/run_global_ptol_phone_ab.sh` and a dry-run/static contract check.
5. Build the unsigned benchmark app locally and verify bundle ID, arm64, native framework hash, and target entrypoint.
6. Conduct a fresh spec-compliance review, then a separate code-quality/safety review. Resolve every important finding and rerun verification.

## Task 6: Physical-iPhone execution

1. Confirm the named paired device, battery/thermal suitability, free disk, pinned Flutter version, signing identity, and wildcard provisioning profile.
2. Execute the host runner in the user's normal macOS Terminal session.
3. Do not substitute a simulator, host replay, production bundle, older app, or different input after any failure.
4. Pull the complete result bundle and add a run receipt with source identity, app/framework hashes, command, device/backend, artifacts, deviations, and verdict.
5. Register the run metadata and metrics in the repository's existing MLflow file store; large PLYs remain external artifacts identified by SHA-256 unless a repository-local DVC experiment is explicitly initialized for this benchmark.

## Task 7: Adjudication

1. Recompute all input and output hashes.
2. Check each pre-registered quality threshold, repeatability condition, and speed threshold without changing them after viewing results.
3. Return one of: `advance PTOL=1e-8 to a production-candidate experiment`, `reject`, `invalid`, or `blocked`.
4. Do not install anything into `com.kyle.PocketWorld` as part of this plan. Production adoption requires a separate authorization and the full production backup/update runbook.
