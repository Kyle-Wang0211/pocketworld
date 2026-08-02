## 1. Freeze the experiment

- [ ] 1.1 Record repository revision/diff hash, official Lepton identity,
  Cargo lock, Apple toolchain, iPhone identity, frozen JPEG length/SHA, metrics,
  thresholds, and stopping rules.
- [ ] 1.2 Add contract tests that reject the production bundle ID, wrong input,
  missing exactness fields, non-official Lepton settings, and non-strict wins.

## 2. Build official Lepton for iOS ARM64

- [ ] 2.1 Add a locked staticlib wrapper around official `lepton_jpeg` 0.5.8
  using its official vector write/read presets and default thread pool.
- [ ] 2.2 Install the pinned Rust toolchain only in a task-local temporary
  directory and build `aarch64-apple-ios` without changing global Rust.
- [ ] 2.3 Verify source/package identity, licenses, archive architecture, and
  exported C ABI symbols.

## 3. Implement the independent benchmark

- [ ] 3.1 Add Dart FFI bindings and unit/contract tests.
- [ ] 3.2 Add the Dart benchmark entrypoint and tests for wrong input, exactness,
  JSON schema, cleanup, and strict winner selection.
- [ ] 3.3 Add the isolated build/sign/install/run script and tests proving it
  uses `com.kyle.PocketWorld.LeptonBench`, `--no-pub`, a separate container,
  no production access, and no uninstall.

## 4. Run on the physical iPhone

- [ ] 4.1 Build and sign the independent ARM64 bundle; verify bundle identity,
  signature, marker, ABI symbols, and binary hashes.
- [ ] 4.2 Copy only the frozen JPEG into the benchmark container, launch once,
  collect the JSON, and verify both official round trips.
- [ ] 4.3 Persist the measured artifact sizes, hashes, timings, exactness results,
  environment identity, and pass/fail verdict.

## 5. Conditional production promotion

- [ ] 5.1 If and only if the phone verdict passes, add a Lepton codec identity
  for future captures while retaining legacy JXL policy/manifest reading.
- [ ] 5.2 TDD the Lepton production transaction, resolver dispatch, source-last
  deletion, production gate, interruption/safe-boundary behavior, and rollback.
- [ ] 5.3 Vendor the rebuilt ARM64 native archive and complete LICENSE/NOTICE
  packaging; explicitly record that native recompilation is required.
- [ ] 5.4 Run focused tests, full analyze/test gates, fetch/log/status checks,
  and only then commit the production change by explicitly named files.

## 6. Stop condition

- [ ] 6.1 If either decoder is not exact, input identity differs, or Lepton is
  not strictly smaller on the phone, record the failure and leave production
  JXL unchanged.
