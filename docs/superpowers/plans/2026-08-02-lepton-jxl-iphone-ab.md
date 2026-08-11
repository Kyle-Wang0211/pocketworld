# Lepton/JXL Physical-iPhone A/B Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. The user explicitly prohibited subagents, so execution stays in the current session.

**Goal:** Build official Rust Lepton 0.5.8 into an independent iOS ARM64 benchmark, compare it with production JXL effort 10 on one frozen JPEG on the physical iPhone, and promote Lepton for future projects only if it is strictly smaller and both round trips are byte-exact.

**Architecture:** A locked Rust `staticlib` is a thin file-oriented C ABI over the official `lepton_jpeg` crate. A dedicated Flutter/Dart entrypoint runs both codecs inside an independently signed bundle and writes an auditable JSON result. The production archive path remains untouched until the physical-phone result passes; a passing result enables a codec-aware v2 policy/manifest while retaining the legacy JXL reader.

**Tech Stack:** Dart/Flutter, Dart FFI, Rust/Cargo, official `lepton_jpeg` 0.5.8, libjxl 0.12.0 effort 10, Xcode 26.2/iPhoneOS 26.2, CoreDevice, SHA-256.

---

## File structure

- Create `native/lepton_jpeg_ffi/Cargo.toml`: locked static-library package and exact official dependency.
- Create `native/lepton_jpeg_ffi/src/lib.rs`: file-oriented C ABI; no codec algorithm changes.
- Create `native/lepton_jpeg_ffi/include/pw_lepton_bridge.h`: stable ABI declarations.
- Create `native/lepton_jpeg_ffi/Cargo.lock`: generated locked dependency graph.
- Create `lib/official_capture/lepton_jxl_benchmark_gate.dart`: pure immutable-input and strict-winner predicates.
- Create `lib/official_capture/lepton_photo_archive_ffi_codec.dart`: Dart bindings and `PhotoArchiveCodec` adapter.
- Create `lib/lepton_jxl_benchmark_main.dart`: independent benchmark UI/runner/result writer.
- Create `tool/build_lepton_ios.sh`: task-local Rust target build and identity checks.
- Create `tool/run_lepton_jxl_iphone_bench.sh`: isolated unsigned build, signing, install, input copy, launch, result collection, and verdict validation.
- Create `test/lepton_jxl_benchmark_contract_test.dart`: guard bundle separation, official settings, fixed input, exactness, and strict winner.
- Create `experiments/lepton_jxl_iphone/experiment-contract.yaml`: preregistered immutable experiment contract.
- Create `experiments/lepton_jxl_iphone/evidence.json`: build/device/result evidence written after the run.
- Conditionally modify `lib/official_capture/photo_archive_codec.dart`, `photo_archive_policy.dart`, `photo_archive_manifest.dart`, `photo_archive_transaction.dart`, `photo_archive_resolver.dart`, `photo_archive_runtime.dart`, `photo_archive_coordinator.dart`, `sfm_resume.dart`, their focused tests, `ios/Runner.xcodeproj/project.pbxproj`, and `pubspec.yaml` only after a passing phone result.

### Task 1: Freeze the benchmark contract

**Files:**
- Create: `experiments/lepton_jxl_iphone/experiment-contract.yaml`
- Create: `test/lepton_jxl_benchmark_contract_test.dart`

- [ ] **Step 1: Write the failing contract test**

The test must require these literal invariants before implementation exists:

```dart
expect(runner, contains('com.kyle.PocketWorld.LeptonBench'));
expect(runner, isNot(contains('device uninstall app')));
expect(runner, isNot(contains('--domain-identifier com.kyle.PocketWorld')));
expect(entrypoint, contains('2725495'));
expect(entrypoint, contains('a1cb8de1d3b91edbb7e05233c7930200c46e04554c3651153e267e5abd262138'));
expect(native, contains('EnabledFeatures::compat_lepton_vector_write()'));
expect(native, contains('EnabledFeatures::compat_lepton_vector_read()'));
expect(native, contains('DEFAULT_THREAD_POOL'));
expect(runner, contains('--no-pub'));
expect(runner, contains('lepton_archive_bytes < jxl_archive_bytes'));
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
flutter test test/lepton_jxl_benchmark_contract_test.dart
```

Expected: failure because the benchmark files do not exist.

- [ ] **Step 3: Add the experiment contract**

Record exact source bytes/SHA, Lepton/JXL revisions and settings, repository
HEAD plus dirty-diff hash, toolchain and device identities, one-run stop rule,
exactness metrics, strict-size threshold, artifacts, and the rule that host or
simulator results cannot promote production.

### Task 2: Implement and lock the official Lepton static library

**Files:**
- Create: `native/lepton_jpeg_ffi/Cargo.toml`
- Create: `native/lepton_jpeg_ffi/Cargo.lock`
- Create: `native/lepton_jpeg_ffi/src/lib.rs`
- Create: `native/lepton_jpeg_ffi/include/pw_lepton_bridge.h`
- Create: `tool/build_lepton_ios.sh`

- [ ] **Step 1: Declare the exact official dependency**

```toml
[package]
name = "pw_lepton_jpeg_ffi"
version = "0.1.0"
edition = "2024"
publish = false

[lib]
crate-type = ["staticlib"]

[dependencies]
lepton_jpeg = "=0.5.8"
```

- [ ] **Step 2: Export a narrow, panic-safe C ABI**

The implementation opens buffered files, calls official
`encode_lepton`/`decode_lepton` with the official vector presets and
`DEFAULT_THREAD_POOL`, flushes output, returns stable integer statuses, and
exports version/revision strings. The ABI is:

```c
const char *pw_lepton_version(void);
const char *pw_lepton_revision(void);
const char *pw_lepton_error_message(int32_t status);
int32_t pw_lepton_encode_jpeg_file(const char *jpeg_path,
                                   const char *lepton_path,
                                   uint64_t *elapsed_microseconds);
int32_t pw_lepton_reconstruct_jpeg_file(const char *lepton_path,
                                        const char *jpeg_path,
                                        uint64_t *elapsed_microseconds);
```

- [ ] **Step 3: Generate and verify the lock**

Use task-local Cargo, then verify that package `lepton_jpeg 0.5.8` is present
and its downloaded `.cargo_vcs_info.json` identifies commit
`90fdc27828676892fbb41777cfcc6bad1e470516`.

- [ ] **Step 4: Build for iPhone ARM64**

`tool/build_lepton_ios.sh` creates task-local `RUSTUP_HOME`, `CARGO_HOME`, and
target directories under `/private/tmp`, installs only pinned Rust and
`aarch64-apple-ios`, runs `cargo build --release --locked
--target aarch64-apple-ios`, then checks:

```bash
lipo -info libpw_lepton_jpeg_ffi.a
nm -gU libpw_lepton_jpeg_ffi.a | grep _pw_lepton_encode_jpeg_file
nm -gU libpw_lepton_jpeg_ffi.a | grep _pw_lepton_reconstruct_jpeg_file
```

Expected: arm64 archive and both exported symbols.

- [ ] **Step 5: Run host wrapper smoke where supported**

Build the same wrapper for `aarch64-apple-darwin`, encode/decode the frozen
JPEG copy, and require `cmp` plus SHA equality. This verifies integration only
and is not a production selection result.

### Task 3: Implement Dart FFI and benchmark logic

**Files:**
- Create: `lib/official_capture/lepton_photo_archive_ffi_codec.dart`
- Create: `lib/lepton_jxl_benchmark_main.dart`
- Modify: `test/lepton_jxl_benchmark_contract_test.dart`

- [ ] **Step 1: Keep the contract test red for missing Dart fields**

Require the result keys `source_bytes`, `source_sha256`, `jxl`, `lepton`,
`archive_bytes`, `archive_sha256`, `restored_sha256`, `byte_equal`,
`encode_elapsed_us`, `decode_elapsed_us`, `winner`, and `production_eligible`.

- [ ] **Step 2: Add the Dart Lepton codec**

Load `DynamicLibrary.process()`, validate `pw_lepton_version()` is `0.5.8` and
revision is the pinned commit, invoke file functions inside `Isolate.run`, and
convert nonzero statuses into `StateError` without deleting authoritative
input.

- [ ] **Step 3: Add immutable input and exactness gates**

The benchmark checks length/SHA before encoding. For each arm it records
archive identity, restores with the same codec, streams SHA, and streams byte
comparison. It writes failed JSON on every exception and atomically publishes
the final JSON.

- [ ] **Step 4: Encode strict verdict logic**

```dart
final productionEligible =
    jxl.exact && lepton.exact && lepton.archiveBytes < jxl.archiveBytes;
```

Equal size is not eligible. Temporary outputs are confined to the independent
Documents directory and the frozen input is retained.

- [ ] **Step 5: Run focused tests and verify GREEN**

Run:

```bash
dart format lib/official_capture/lepton_photo_archive_ffi_codec.dart lib/lepton_jxl_benchmark_main.dart test/lepton_jxl_benchmark_contract_test.dart
flutter test test/lepton_jxl_benchmark_contract_test.dart
flutter analyze lib/official_capture/lepton_photo_archive_ffi_codec.dart lib/lepton_jxl_benchmark_main.dart test/lepton_jxl_benchmark_contract_test.dart
```

Expected: focused test and analysis pass.

### Task 4: Build, sign, and run the independent iPhone bundle

**Files:**
- Create: `tool/run_lepton_jxl_iphone_bench.sh`
- Modify: `test/lepton_jxl_benchmark_contract_test.dart`

- [ ] **Step 1: Add independent-package safety assertions**

The script must use `--no-pub`, task-local XDG/build/DerivedData directories,
`PRODUCT_BUNDLE_IDENTIFIER=com.kyle.PocketWorld.LeptonBench`, unsigned Xcode
build followed by explicit benchmark signing, `devicectl device install app`,
and only the benchmark app-data-container domain. It must contain no uninstall,
production bundle domain, or production launch.

- [ ] **Step 2: Build and inspect before signing**

Verify the built Info.plist bundle ID, explicit benchmark marker, ARM64 binary,
JXL ABI, Lepton ABI, and the absence of production memory entitlements.

- [ ] **Step 3: Sign and inspect after signing**

Embed the verified wildcard profile, rewrite benchmark entitlements, sign every
embedded dylib/framework and the app, then run `codesign --verify --deep
--strict`. Record app binary and static-library SHA-256.

- [ ] **Step 4: Install and run once on the physical iPhone**

Copy the frozen JPEG only to
`com.kyle.PocketWorld.LeptonBench/Documents/benchmark_input.jpg`, launch with
`--terminate-existing`, poll the independent result JSON, and stop after one
terminal result. Do not create a project or access the production container.

- [ ] **Step 5: Validate the returned JSON independently**

The host validator rechecks run ID, bundle ID, device identity, source identity,
both exactness arms, strict size comparison, and result schema before printing
`IPHONE_LEPTON_JXL_AB_OK`.

### Task 5: Decide and record the phone result

**Files:**
- Create: `experiments/lepton_jxl_iphone/results/2026-08-02-lepton-jxl-iphone-ab.json`
- Create: `experiments/lepton_jxl_iphone/evidence.json`
- Modify: `openspec/changes/benchmark-lepton-jxl-iphone-and-promote/tasks.md`

- [ ] **Step 1: Preserve immutable evidence**

Record ordered input identity, repo/diff identity, toolchain/lock hashes, native
and app hashes, phone identity, commands, codec outputs, exactness, timings,
deviations, and verdict. Preserve failed runs rather than overwriting them.

- [ ] **Step 2: Apply the stop rule**

If either exactness check fails or Lepton is not strictly smaller, mark the
change stopped, leave production JXL untouched, and do not execute Task 6.

### Task 6: Conditionally promote Lepton for future captures

**Files:**
- Modify only after Task 5 passes: `lib/official_capture/photo_archive_codec.dart`
- Modify only after Task 5 passes: `lib/official_capture/photo_archive_policy.dart`
- Modify only after Task 5 passes: `lib/official_capture/photo_archive_manifest.dart`
- Modify only after Task 5 passes: `lib/official_capture/photo_archive_transaction.dart`
- Modify only after Task 5 passes: `lib/official_capture/photo_archive_resolver.dart`
- Modify only after Task 5 passes: `lib/official_capture/photo_archive_runtime.dart`
- Modify only after Task 5 passes: `lib/official_capture/photo_archive_coordinator.dart`
- Modify only after Task 5 passes: `lib/official_capture/sfm_resume.dart`
- Modify focused tests matching the files above.
- Modify: `ios/Runner.xcodeproj/project.pbxproj`
- Modify: `pubspec.yaml`
- Create: `ios/Vendor/Lepton/lib/libpw_lepton_jpeg_ffi.a`
- Create: `ios/Vendor/Lepton/include/pw_lepton_bridge.h`
- Create: `ios/Vendor/Lepton/licenses/` with official and dependency notices.

- [ ] **Step 1: Write failing backward-compatibility and transaction tests**

Tests must prove new captures select Lepton, old v1 JXL markers remain readable,
each manifest records its codec/revision/extension, resolver dispatches to the
persisted codec, source deletion stays last, wrong-codec archives fail closed,
and production activity prevents publish/delete after a gate closes.

- [ ] **Step 2: Generalize codec metadata without rewriting legacy records**

Add codec ID, revision, and archive extension to the abstraction. Read v1 JXL
exactly as today. Write v2 Lepton only for new captures. Never reinterpret a
`.jxl` as Lepton or migrate an existing archive.

- [ ] **Step 3: Wire production to the verified Lepton static library**

Link and force-export the Lepton ABI, initialize the Lepton codec for new v2
work and retain JXL for v1 restore. Bundle all required LICENSE/NOTICE texts.

- [ ] **Step 4: Verify all behavioral gates**

Run focused tests, temporarily confirm the new guard tests fail against the old
behavior where practical, then run only-owned-file formatting, full
`flutter analyze lib/ test/`, and full `flutter test`. Analyze may retain only
the documented shared baseline; any added issue blocks promotion.

- [ ] **Step 5: Commit and push only owned files**

Inspect every diff, explicitly `git add` each owned path, use neither `git add
-A/-u` nor `commit -a`, fetch origin, compare `origin/main` and HEAD, and push
only after resolving a true remote lead without touching unrelated dirty work.

The native commit message must explicitly state that native recompilation and
vendoring occurred.

### Task 7: Completion verification

- [ ] **Step 1: Re-run deterministic verification**

Re-run the focused benchmark contract, OpenSpec strict validation, native ABI
checks, result validator, focused production tests if promoted, full analyze,
and full test suite.

- [ ] **Step 2: Report precise outcome**

Report source bytes, JXL bytes, Lepton bytes, delta and percentage, both restored
SHA values, byte-equality results, run/device/toolchain IDs, production decision,
changed file list, tests, commit hashes, and whether production native code was
rebuilt. Do not claim promotion if any gate lacks evidence.
