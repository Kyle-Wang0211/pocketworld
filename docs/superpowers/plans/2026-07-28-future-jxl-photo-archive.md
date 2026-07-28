# Future JPEG XL Photo Archive Implementation Plan
> Execute in the isolated worktree
> `/Users/kaidongwang/.config/superpowers/worktrees/pocketworld/jxl-future-project-archive`.
> Do not install on or alter the production iPhone bundle.

**Goal:** Automatically archive only future official-capture high-resolution
JPEGs as smaller JPEG XL files while retaining provable exact original JPEG
bytes and never migrating existing projects.

**Architecture:** Pure Dart policy, coordinator, manifest, transaction, and
resolver modules own all safety decisions. A file-oriented C ABI around pinned
libjxl 0.12.0 performs JPEG reconstruction encoding/decoding. Capture creation,
PLY persistence, reconstruction lifetime, and app startup emit idempotent
signals into one sequential coordinator.

**Stack:** Dart 3.11 / Flutter, `dart:io`, `package:crypto`, `dart:ffi`,
libjxl 0.12.0, iOS Objective-C++ bridge, XCTest/Flutter test.

## Task 1: Freeze future-only policy behavior

**Files:**

- Create: `test/photo_archive_policy_test.dart`
- Create: `lib/official_capture/photo_archive_policy.dart`

1. Write tests proving a compatible creation-time marker is eligible and
   missing/malformed/unknown markers are ineligible.
2. Run:
   `flutter test test/photo_archive_policy_test.dart`
   and confirm unresolved symbols or failed expectations.
3. Implement `PhotoArchivePolicy.createForNewCapture`,
   `PhotoArchivePolicy.readCompatible`, schema
   `pw_photo_archive_policy_v1`, codec `jpeg-xl`, mode
   `jpeg-reconstruction`, and pinned libjxl revision
   `a7a9c787341cf703dede03c2009fa460cae5e5df`.
4. Write the marker through a same-directory temporary plus rename and flush
   before the capture is exposed.
5. Re-run the focused test and commit after it passes.

## Task 2: Freeze candidate and transaction behavior

**Files:**

- Create: `test/photo_archive_transaction_test.dart`
- Create: `lib/official_capture/photo_archive_manifest.dart`
- Create: `lib/official_capture/photo_archive_codec.dart`
- Create: `lib/official_capture/photo_archive_transaction.dart`

1. Create a fake file-oriented codec for deterministic tests.
2. Add tests for:
   - only `frames[*].highresFilename` JPEG basenames are selected;
   - exact smaller reconstruction commits JXL, manifest, then removes JPEG;
   - mismatch, codec error, and equal/larger JXL retain JPEG;
   - temporary files are reconciled without losing the source;
   - a committed archive plus remaining source is independently verified
     before retry deletes the source.
3. Run:
   `flutter test test/photo_archive_transaction_test.dart`
   and confirm failure.
4. Implement safe bundle parsing, SHA-256 streaming, exact streaming byte
   comparison, sequential ordering, temporary paths, same-directory atomic
   rename, and manifest source/archive hashes.
5. Re-run the focused test until green.

## Task 3: Build the exact-JPEG resolver

**Files:**

- Create: `test/photo_archive_resolver_test.dart`
- Create: `lib/official_capture/photo_archive_resolver.dart`

1. Test source-first resolution, valid archive materialization, stale cached
   file repair, and corrupt/missing archive failure.
2. Confirm the focused test fails.
3. Implement cached reconstruction to a temporary path, verify declared
   length/SHA-256, and publish by atomic rename only after verification.
4. Re-run the focused test.

## Task 4: Connect the cold lifecycle

**Files:**

- Create: `test/photo_archive_lifecycle_test.dart`
- Create: `lib/official_capture/photo_archive_coordinator.dart`
- Modify: `lib/official_capture/capture_session.dart`
- Modify: `lib/official_capture/sparse_ply.dart`
- Modify: `lib/official_capture/sfm_live_recon.dart`
- Modify: `lib/main.dart`

1. Add source-contract and coordinator tests proving:
   - `_setupPhotosDirectory` writes the marker for a newly created capture;
   - missing PLY/meta/manifest or unreleased recon blocks work;
   - `persistSparseSnapshot` sends a durable-artifact hint;
   - `SfmLiveRecon.start` raises activity and `dispose` releases it and sends
     a release hint;
   - startup discovery filters by marker before scheduling;
   - foreground activity pauses between candidates.
2. Run the lifecycle test and confirm failure.
3. Implement a singleton coordinator with injected codec/root providers for
   tests, one queue, one active transaction, per-capture recon ownership, and
   global capture/reconstruction activity counters.
4. Hook marker creation immediately after directory creation.
5. Hook PLY persistence after both final files are present.
6. Hook recon activity around successful start/dispose and trigger the capture
   directory after native/isolate/lease release.
7. Start a fire-and-forget marker-filtered recovery scan after Flutter binding
   initialization without delaying first paint.
8. Re-run lifecycle and all archive tests.

## Task 5: Integrate pinned libjxl

**Files:**

- Create: `ios/Vendor/JXL/**`
- Create: `ios/Runner/PWJxlBridge.h`
- Create: `ios/Runner/PWJxlBridge.mm`
- Create: `lib/official_capture/photo_archive_ffi_codec.dart`
- Modify: `ios/Runner.xcodeproj/project.pbxproj`
- Modify: `ios/Runner/Runner-Bridging-Header.h` only if required by the existing
  target
- Modify: `THIRD_PARTY_NOTICES.md` or the repository's existing equivalent

1. Copy exact headers/static libraries/notices from benchmark commit
   `efbf5f8c52e1f4981bcd30e2d963a05f57d524f1`; do not resolve or download a
   different dependency.
2. Adapt the proven bridge to file-to-file C calls. Preserve explicit JXL
   container use, `JXL_DEC_JPEG_RECONSTRUCTION | JXL_DEC_FULL_IMAGE`
   subscription, and finalize at `JXL_DEC_FULL_IMAGE`.
3. Bind functions with `DynamicLibrary.process()` on supported iOS and return an
   unsupported error elsewhere.
4. Link device and simulator slices conditionally in the Runner target and
   enable dead stripping.
5. Run native fixture round trips and compare SHA-256/length.

## Task 6: Verify without production deployment

1. Format changed Dart:
   `dart format lib/official_capture test`
2. Run focused suite:
   `flutter test test/photo_archive_policy_test.dart test/photo_archive_transaction_test.dart test/photo_archive_resolver_test.dart test/photo_archive_lifecycle_test.dart`
3. Run:
   `flutter analyze`
4. Run:
   `flutter test`
5. Validate specification:
   `/opt/homebrew/bin/openspec validate add-future-jxl-photo-archive`
6. Build with the repository-pinned SDK and no package resolution:
   `flutter build ios --release --no-codesign --no-pub`
7. Inspect linked architectures, exported C symbols, third-party notices,
   uncompressed/stripped bundle deltas, and the final diff.
8. Do not run `flutter drive`, uninstall, install, or any `devicectl` command
   against `com.kyle.PocketWorld`.

## Task 7: Retire durable AR previews

**Files:**

- Create: `lib/official_capture/transient_preview_cleanup.dart`
- Create: `test/official_photo_bundle_without_preview_test.dart`
- Create: `test/official_transient_preview_cleanup_test.dart`
- Modify: `lib/ui/official_capture/ar_capture_page.dart`
- Modify: `lib/official_capture/capture_session.dart`
- Modify: `lib/official_capture/photo_archive_coordinator.dart`
- Modify: `packages/official_capture_services/lib/src/photo_bundle_manifest_service.dart`
- Modify: `packages/official_capture_services/lib/src/photo_bundle_service.dart`
- Modify: `packages/official_capture_services/lib/src/photo_bundle_derivation_service.dart`
- Modify: `packages/official_capture_services/lib/src/photo_bundle_pipeline_policy_service.dart`

1. Write a failing test that builds a future official manifest and asserts it
   has neither `previewsDir` nor `previewFilename`.
2. Add failing validation, derivation, and transport assertions proving a
   high-resolution-only bundle passes without creating or requiring
   `previews/`.
3. Add a failing cleanup test with files under `photos_highres`, `previews`,
   and an external thumbnail. Assert only `previews` is deleted, and assert an
   incompatible/missing policy marker blocks cold retry cleanup.
4. Run:
   `flutter test test/official_photo_bundle_without_preview_test.dart
   test/official_transient_preview_cleanup_test.dart`
   and confirm failures are caused by the current durable-preview contract.
5. Make `PhotoBundleFrameDraft.previewFilename` and manifest `previewsDir`
   nullable. Omit both from new official manifests while retaining explicit
   legacy-preview validation and repair behavior when those fields exist.
6. Make transport entries conditional on an explicit non-empty
   `previewsDir`, and prevent asset repair from creating previews for manifests
   without the preview contract.
7. Add `removeTransientCapturePreviews`, scoped to the exact
   `<capture>/previews` directory. Call it only after
   `ScanRecordStore.addOrUpdate` completes, and retry from the existing cold
   coordinator only after it has accepted a compatible creation-time marker.
8. Re-run the focused test until green, then run all archive/lifecycle tests.
9. Format changed Dart, run targeted analysis, full `flutter test --no-pub`,
   OpenSpec validation, whitespace checks, and an unsigned iPhoneOS Release
   build without installation.
