## 1. Policy and durable metadata

- [x] 1.1 Add failing Dart tests for the independent future-only official database policy
- [x] 1.2 Implement compatible policy parsing and atomic creation-time writes
- [x] 1.3 Add failing manifest validation and atomic-write tests
- [x] 1.4 Implement fixed-path, pinned-codec database manifests

## 2. Byte-exact transaction

- [x] 2.1 Add failing tests for exact smaller archives, mismatch, failure, sidecars, and non-smaller output
- [x] 2.2 Implement source-last ZPAQ transaction and streaming SHA-256/byte comparison
- [x] 2.3 Add failing tests for crash reconciliation and changed restored databases
- [x] 2.4 Implement idempotent reconciliation and cooperative interruption handling

## 3. Recovery

- [x] 3.1 Add failing tests for raw-first, valid archive-only, corrupt archive, and atomic materialization
- [x] 3.2 Implement the verified database resolver
- [x] 3.3 Add failing lifecycle tests for official recoverability discovery and re-archive
- [x] 3.4 Connect resolver and outer archive lease to official recovery only

## 4. Official cold lifecycle

- [x] 4.1 Add failing coordinator tests for independent markers, ordering, activity gates, and startup discovery
- [x] 4.2 Write the database marker during official capture creation
- [x] 4.3 Run the database transaction after existing JPEG XL work in the official coordinator
- [x] 4.4 Keep the retired self-developed pipeline unchanged

## 5. Native ZPAQ

- [x] 5.1 Add failing Dart/Xcode contract tests for exact version, revision, method, symbols, and notices
- [x] 5.2 Vendor the benchmarked libzpaq 7.15 source and license with recorded hashes
- [x] 5.3 Implement the portable C bridge, background-isolate Dart FFI codec, and cooperative cancellation
- [x] 5.4 Add and pass a native method-5 exact-file round-trip test

Native verification used the production bridge and exact vendored source in a
standalone method-5 smoke executable: 1,048,576 source bytes restored
byte-for-byte from a 401-byte deterministic fixture archive. The same sources
compiled to iPhoneOS arm64 objects with all eight exported ABI symbols. The
Runner simulator XCTest command remains blocked before test execution by the
repository's existing Thermion native-asset simulator hook; it did not fail
inside the ZPAQ test.

## 6. Verification and production update

- [x] 6.1 Format only changed Dart files and run focused archive/recovery tests
- [x] 6.2 Run full Flutter tests, static analysis, OpenSpec validation, and diff checks
- [x] 6.3 Build iOS Release with pinned dependencies and `--no-pub`; verify build marker, ABI symbols, license, and bundle identity
- [x] 6.4 Back up and hash the production container, perform only an in-place update, and report installed HEAD
- [ ] 6.5 Create an isolated new official project on the physical iPhone and prove archive/restoration SHA-256 identity without touching historical projects

Repository verification completed with 325 Flutter tests passing, no analyzer
issues in the files owned by this change, valid strict OpenSpec, and a clean
diff check. Full-repository analysis still reports 15 pre-existing
warning/info diagnostics outside the owned archive files. The signed in-place
production update completed at
`a8479053d833fc7d4602bf376e672d48a9088ef0`; every pre-update Documents and
non-SplashBoard Library file remained byte-identical.
