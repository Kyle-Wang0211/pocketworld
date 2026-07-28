## Context

The official production route writes 4032×3024 JPEGs under
`captures_official/<captureId>/photos_highres/`. Those files remain live inputs
for album curation, streaming SfM, recovery colorization, and final PLY
persistence. Deleting or transforming them earlier would race the production
pipeline.

The standalone physical-iPhone benchmark established that pinned libjxl 0.12.0
can wrap the capture JPEG bitstream in JPEG XL and later reconstruct the exact
original file bytes. The 169-image sample reconstructed 169/169 files exactly
and reduced 700,159,883 bytes to 572,966,080 bytes. This result selects the
codec but does not relax the production invariants: old captures are immutable,
the daily-use bundle is never replaced for test convenience, and every
production archive commit must independently prove byte identity.

## Goals / Non-Goals

**Goals:**

- Make only captures created after this feature eligible for automatic archival.
- Run archival only after PLY/meta persistence and reconstruction release.
- Preserve the original JPEG byte stream exactly, including metadata and
  container layout, not merely decoded pixels.
- Make each file transaction crash-safe and resumable.
- Keep capture and reconstruction responsive by processing one file at a time
  and pausing background work while foreground capture/reconstruction is active.
- Keep archive format portable and codec policy in Dart while using libjxl's
  native C++ implementation for the compression primitive.

**Non-Goals:**

- Migrating, scanning by date, or rewriting any capture without the new policy
  marker.
- Compressing preview JPEGs, scan thumbnails, PLY files, databases, sidecars,
  or unreferenced files.
- Lossy image transcoding, decoded-pixel-only equality, or cloud deletion.
- Installing this change on the production iPhone as part of local
  implementation.
- Selecting a point-cloud codec in this change.

## Decisions

### Eligibility is an explicit creation-time capability

`CaptureSession` creates `official_photo_archive_policy.json` together with a
new capture directory. The marker contains a schema version, codec, lossless
mode, and pinned libjxl revision. The coordinator rejects a directory when the
marker is missing, unknown, malformed, or incompatible.

This is preferred to timestamps, build-number inference, or filename patterns:
those alternatives could silently reclassify an old capture. Deleting the
marker disables future work without modifying the photos.

### The archive starts at a cold lifecycle boundary

Three independent facts gate work:

1. the marked capture has `official_photo_bundle.json`;
2. `official_sfm_sparse.ply` and `official_sfm_sparse_meta.json` both exist;
3. the in-process reconstruction handle for that directory has been released.

`persistSparseSnapshot` informs the coordinator after persistence returns;
`SfmLiveRecon.dispose` informs it only after isolate/native teardown and lease
release. The coordinator rechecks files instead of trusting notifications.
After a process restart, the absence of an in-process owner counts as released,
and a startup scan considers only marked directories.

Starting a capture or reconstruction raises a global activity gate. Archive
work is sequential and checks the gate between files. Existing in-flight work
finishes its one file transaction, then pauses.

### Dart owns policy; a C ABI owns the libjxl primitive

Dart parses manifests, chooses candidates, orders work, computes/compares
bytes, commits metadata, handles recovery, and resolves sources. A portable
Objective-C++/C++ translation unit exports a file-oriented C ABI around pinned
libjxl 0.12.0. It uses JPEG reconstruction mode; it does not decode/re-encode
pixels and contains no Swift compression algorithm.

The current production bridge is linked into the iOS Runner. The archive format
and libjxl implementation are cross-platform; additional platform build wiring
can reuse the same C ABI without changing stored data.

### Candidate membership comes only from the authoritative bundle

Only normalized basenames in the `frames[*].highresFilename` fields of
`official_photo_bundle.json` are candidates. Paths containing separators,
escaping the `photos_highres` directory, duplicates, or non-JPEG extensions
are rejected. Preview filenames and directory glob results never become
candidates.

### Each JPEG uses a conservative atomic transaction

For source `x.jpg`, the coordinator:

1. computes the source length and SHA-256;
2. writes `x.jpg.jxl.tmp`;
3. reconstructs to `x.jpg.verify.tmp`;
4. streams an exact byte comparison against `x.jpg`;
5. rejects the result if it is not smaller;
6. atomically renames the temporary archive to `x.jpg.jxl`;
7. atomically rewrites `official_photo_archive.json` with verified lengths,
   hashes, codec revision, and state;
8. deletes `x.jpg` last and then removes the verification temporary.

Any exception before the durable manifest commit keeps the source. If a crash
occurs after manifest commit but before source deletion, restart verifies the
committed archive again and then completes deletion. Orphan `.tmp` files are
safe to remove because a canonical source or committed archive remains.

The manifest is separate from `official_photo_bundle.json`: the latter remains
the immutable capture membership record and older readers do not see a schema
mutation.

### Exact materialization is a first-class read path

The resolver first returns a canonical JPEG if present. Otherwise it requires a
verified manifest entry, reconstructs the JXL to an application cache
temporary, validates the declared byte length and SHA-256, and atomically
publishes the cached JPEG. Corruption fails closed; the resolver never returns
unverified bytes.

## Risks / Trade-offs

- **[Native binary size]** → Record final archive/framework size during the
  release build; use dead stripping and only the required libjxl static
  components.
- **[Peak memory and thermal pressure]** → Use file-oriented calls, one image at
  a time, release native objects after every call, and pause between files while
  foreground capture/reconstruction is active.
- **[Crash between commit steps]** → Keep deletion last, use same-directory
  atomic renames, and make restart reconciliation idempotent.
- **[A future reader opens deleted JPEG paths directly]** → Provide the resolver
  now and require future archive-aware features to use it; current archival
  begins only after all existing consumers have released the capture.
- **[A JXL is larger for an unusual source]** → Keep the JPEG and record a
  skipped result; storage never regresses.
- **[License or patent uncertainty]** → Ship upstream license/notice texts and
  retain the exact revision inventory. The engineering evidence is not legal
  advice and a formal distribution audit remains a release gate.

## Migration Plan

1. Land policy/transaction tests and Dart coordinator behind the creation-time
   marker.
2. Link the pinned, previously benchmarked libjxl artifacts and bridge.
3. Validate host transaction fixtures and an unsigned/local iOS build without
   installing on the daily-use phone.
4. Before any later production update, follow the repository's verified backup
   and in-place update runbook.
5. Rollback by disabling marker creation and archive scheduling. Existing
   verified JXL archives remain resolvable; old and unmarked captures remain
   unchanged.

## Open Questions

- The unsigned integrated iPhoneOS Runner is 88,039,856 bytes. Against the
  same-revision local Runner built immediately before this change
  (82,943,232 bytes), the provisional executable delta is +5,096,624 bytes
  (+6.145%). The app bundle's allocated-size delta is +1,272 KiB. A signed
  distribution archive comparison remains the release-gate measurement because
  code signatures and packaging differ from this local build.
- Android linking is outside this iOS production-path change, but must reuse the
  same file format, policy schema, and byte-verification contract if added.
