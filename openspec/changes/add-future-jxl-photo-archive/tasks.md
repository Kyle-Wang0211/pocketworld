## 1. Contract and policy

- [x] 1.1 Add failing Dart tests for future-only policy markers, malformed marker rejection, lifecycle gates, and manifest-only candidate selection
- [x] 1.2 Implement versioned policy and archive-manifest models with safe path parsing and atomic JSON writes

## 2. Lossless transaction

- [x] 2.1 Add failing tests for exact reconstruction, mismatch, codec failure, non-smaller output, crash boundaries, and idempotent retry
- [x] 2.2 Implement sequential per-file archive transactions with source deletion last
- [x] 2.3 Add failing tests and implementation for exact cached JPEG materialization from a committed archive

## 3. Production lifecycle

- [x] 3.1 Add failing lifecycle contract tests for creation-time marking, PLY notification, reconstruction release, foreground pause, and startup recovery
- [x] 3.2 Connect capture creation, sparse persistence, reconstruction start/dispose, and app startup to the Dart archive coordinator

## 4. Native JPEG XL

- [x] 4.1 Import the pinned libjxl 0.12.0 headers, static libraries, bridge source, and upstream notices from the verified benchmark bundle
- [x] 4.2 Add a file-oriented FFI adapter and iOS Runner linking while preserving unsupported-platform fail-closed behavior
- [x] 4.3 Verify native JPEG-to-JXL-to-byte-identical-JPEG fixture round trips and record the exact linked revisions
- [x] 4.4 Select effort 10 from the physical-iPhone 100 MB size-first
      benchmark and guard the production Dart default with a failing-first test

## 5. Verification

- [x] 5.1 Run focused archive tests, full Flutter tests, static analysis, and OpenSpec validation
- [x] 5.2 Build the iOS app locally with the pinned toolchain and `--no-pub`, inspect its bundle/signature inputs and measure binary-size impact without installing it on the production phone
- [x] 5.3 Review the integrated diff for legacy-capture safety, source-deletion ordering, licensing evidence, and production-bundle invariant compliance

## 6. Transient AR previews

- [x] 6.1 Add failing tests proving future manifests omit preview requirements,
      validation/repair/transport do not recreate them, and cleanup preserves
      high-resolution photos and the independent thumbnail
- [x] 6.2 Make official preview fields optional for legacy reads but absent
      from newly written durable bundles
- [x] 6.3 Delete the future capture preview directory after durable draft
      persistence and retry cleanup only through marker-gated cold discovery
- [x] 6.4 Run focused service/lifecycle tests, full Flutter tests, analysis,
      OpenSpec validation, and the unsigned iPhoneOS release build
