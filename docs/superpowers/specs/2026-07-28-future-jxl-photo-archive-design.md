# Future-Capture Byte-Lossless JPEG XL Archive Design
## Outcome

Only official captures created after this feature carry an archive capability.
After their final PLY is safely persisted and reconstruction resources are
released, the app automatically replaces each eligible high-resolution JPEG
with a smaller JPEG XL archive only after reconstructing and proving the exact
original JPEG bytes.

## Product invariants

- Existing captures never receive a marker and are never scanned as migration
  candidates.
- “Lossless” means original-file byte identity, not visual or decoded-pixel
  identity.
- JPEG remains until JXL, verification, and durable manifest commit all succeed.
- Archive work never enters the live capture/SfM/colorization critical path.
- The authoritative photo bundle determines membership; orphan files are
  excluded.
- The 1920×1440 AR preview JPEGs are transient capture UI assets. After the
  independent draft thumbnail and project record are durable, the project
  preview directory is deleted instead of archived.
- Dart owns policy and transactions. Pinned libjxl C++ owns the codec primitive.
- The format is cross-platform; no Apple-only codec is introduced.

## Lifecycle

```text
new capture directory
  -> write compatible policy marker
  -> capture JPEGs and authoritative photo manifest
  -> copy one independent draft thumbnail
  -> persist the draft record
  -> delete transient previews/
  -> live/recovery SfM consumes JPEGs
  -> persist non-empty PLY + sparse metadata
  -> dispose reconstruction worker/native session
  -> sequential archive coordinator
  -> exact-JPEG resolver for later consumers
```

Both lifecycle events are hints; the coordinator always rechecks the durable
files. On restart, it scans only marker-bearing directories and treats the lack
of an in-process owner as released.

## Per-file transaction

```text
x.jpg
  -> x.jpg.jxl.tmp
  -> x.jpg.verify.tmp (JPEG reconstructed from JXL)
  -> stream exact byte comparison + SHA-256
  -> reject if JXL is not smaller
  -> rename JXL temp to x.jpg.jxl
  -> atomically commit official_photo_archive.json
  -> delete x.jpg last
```

This ordering leaves either the original JPEG, or a committed and independently
verified archive, at every crash boundary.

## Stored metadata

`official_photo_archive_policy.json` is the immutable eligibility gate. It
declares schema `pw_photo_archive_policy_v1`, codec `jpeg-xl`, mode
`jpeg-reconstruction`, and the pinned libjxl revision.

`official_photo_archive.json` is mutable transaction state. Each entry retains:

- source relative path, exact length, and SHA-256;
- archive relative path, length, and SHA-256;
- codec/revision and verification status;
- committed timestamp and non-destructive skip/error state when applicable.

`official_photo_bundle.json` is not rewritten and remains capture membership
truth. Future manifests do not declare `previewsDir` or per-frame
`previewFilename`; validation, repair, and transport treat previews as absent
from the durable bundle contract.

## Failure behavior

Malformed markers/manifests, unsafe paths, missing final artifacts, native
errors, byte mismatch, larger archives, or digest mismatch all fail closed.
They preserve the original JPEG and never publish an archive as verified.

Preview cleanup is best effort immediately after the durable draft record is
written and is retried by the marker-gated cold archive coordinator. Cleanup
targets only `<capture>/previews`; it never deletes `photos_highres`, the
independent `scans_official/<captureId>.jpg` thumbnail, or an unmarked capture.
