## Why

Per-photo JPEG XL recompression is byte-exact but saved only 18.369% on 519
production iPhone JPEGs. With future transient previews removed and the
existing SQLite ZPAQ ratio held at 1.668x, the photo payload must reach at least
2.165x for the whole project to reach 2x. A bounded feasibility experiment is
needed before investing in a production cross-photo codec.

## What Changes

- Add an isolated, host-only experiment for the first consecutive 100 MiB of a
  verified production-device backup.
- Extract quantized JPEG DCT coefficients while preserving each original JPEG
  header and restart interval.
- Compare independent groups of 4 and 8 photos using real SfM poses and the
  project sparse point cloud to predict coefficient blocks.
- Reconstruct every JPEG and require byte equality and SHA-256 equality.
- Measure actual archive bytes, random-access decode amplification, elapsed
  time, peak memory, pose coverage, and immutable-input hashes.
- Stop the direction if neither group size reaches 2.165x.

## Capabilities

### New Capabilities

- `cross-photo-lossless-potential`: reproducible host rejection gate for an
  SfM-guided, byte-exact JPEG collection archive.

### Modified Capabilities

- None. Production JPEG XL, ZPAQ, background scheduling, and deletion behavior
  remain unchanged.

## Impact

- New files are confined to `experiments/cross_photo_lossless_potential`,
  OpenSpec, and the implementation plan.
- The experiment reads only an immutable local backup copy and writes outputs
  only below a temporary directory and ignored experiment state.
- No phone container access, App installation, production-code edit, or native
  product rebuild is authorized by this change.
