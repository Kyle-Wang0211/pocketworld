## 1. Policy and durable metadata

- [ ] 1.1 Add failing Dart tests for the independent future-only official database policy
- [ ] 1.2 Implement compatible policy parsing and atomic creation-time writes
- [ ] 1.3 Add failing manifest validation and atomic-write tests
- [ ] 1.4 Implement fixed-path, pinned-codec database manifests

## 2. Byte-exact transaction

- [ ] 2.1 Add failing tests for exact smaller archives, mismatch, failure, sidecars, and non-smaller output
- [ ] 2.2 Implement source-last ZPAQ transaction and streaming SHA-256/byte comparison
- [ ] 2.3 Add failing tests for crash reconciliation and changed restored databases
- [ ] 2.4 Implement idempotent reconciliation and cooperative interruption handling

## 3. Recovery

- [ ] 3.1 Add failing tests for raw-first, valid archive-only, corrupt archive, and atomic materialization
- [ ] 3.2 Implement the verified database resolver
- [ ] 3.3 Add failing lifecycle tests for official recoverability discovery and re-archive
- [ ] 3.4 Connect resolver and outer archive lease to official recovery only

## 4. Official cold lifecycle

- [ ] 4.1 Add failing coordinator tests for independent markers, ordering, activity gates, and startup discovery
- [ ] 4.2 Write the database marker during official capture creation
- [ ] 4.3 Run the database transaction after existing JPEG XL work in the official coordinator
- [ ] 4.4 Keep the retired self-developed pipeline unchanged

## 5. Native ZPAQ

- [ ] 5.1 Add failing Dart/Xcode contract tests for exact version, revision, method, symbols, and notices
- [ ] 5.2 Vendor the benchmarked libzpaq 7.15 source and license with recorded hashes
- [ ] 5.3 Implement the portable C bridge, background-isolate Dart FFI codec, and cooperative cancellation
- [ ] 5.4 Add and pass a native method-5 exact-file round-trip test

## 6. Verification and production update

- [ ] 6.1 Format only changed Dart files and run focused archive/recovery tests
- [ ] 6.2 Run full Flutter tests, static analysis, OpenSpec validation, and diff checks
- [ ] 6.3 Build iOS Release with pinned dependencies and `--no-pub`; verify build marker, ABI symbols, license, and bundle identity
- [ ] 6.4 Back up and hash the production container, perform only an in-place update, and report installed HEAD
- [ ] 6.5 Create an isolated new official project on the physical iPhone and prove archive/restoration SHA-256 identity without touching historical projects
