## Why

Future PocketWorld captures keep many full-resolution JPEG source frames after reconstruction, creating material local and cloud storage cost. The app needs an automatic archive path that preserves every original JPEG byte exactly while making legacy captures permanently ineligible for migration.

## What Changes

- Mark only captures created by the new build with a durable, versioned photo-archive policy file.
- After the final sparse PLY and metadata are durable and reconstruction resources are released, archive only manifest-referenced high-resolution JPEGs to JPEG XL in sequential background work.
- Verify every candidate by reconstructing the JPEG and comparing its bytes with the source before committing the archive and deleting the source.
- Keep the JPEG when encoding fails, verification fails, the archive is not smaller, required artifacts are missing, or capture/reconstruction work is active.
- Persist an atomic archive manifest so interrupted work can safely resume for marked future captures.
- Provide a resolver that returns an existing JPEG or materializes an exact JPEG from its verified JPEG XL archive for future consumers.
- Treat 1920×1440 AR-card previews as temporary capture UI files: copy one
  independent draft thumbnail, remove previews from the durable photo-bundle
  contract, and delete the future capture's preview directory after draft
  persistence with marker-gated cold retry.
- Leave independent thumbnails, unreferenced files, all existing captures, and the production iPhone data container untouched.

## Capabilities

### New Capabilities

- `future-photo-archive`: Eligibility, lifecycle gates, byte-exact JPEG XL transactions, crash recovery, and exact JPEG materialization for future captures.

### Modified Capabilities

None.

## Impact

- Dart capture lifecycle, archive coordination, manifest handling, transient
  preview cleanup, photo-bundle validation/transport, and tests.
- A small C/C++ FFI bridge backed by pinned libjxl 0.12.0 native artifacts; no Swift compression algorithm.
- iOS Runner linking and third-party license notices.
- New capture directories gain policy/archive metadata; existing directory schemas remain readable and are never migrated automatically.
- JPEG XL is a cross-platform open codec, while this change wires the current production iOS capture path first.
