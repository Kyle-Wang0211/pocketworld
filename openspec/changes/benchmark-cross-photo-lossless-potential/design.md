## Context

The immutable sample is the first 37 frames in
`cap_1785155296535863/official_photo_bundle.json`, totaling 105,908,333 bytes.
It includes original 4032x3024 JPEGs, ordered ARKit metadata, registered SfM
poses, and a binary little-endian sparse PLY. The sample predates automatic
archive policy marking; four newer backup projects already contain 519 JXL
archives and no source JPEGs.

The production threshold is not inferred from this sample. It is pre-registered
from the measured future-project composition: a photo archive ratio of 2.165x
is necessary for a 2x whole-project ratio when SQLite remains at 1.668x.

## Goals

- Produce an actual reversible prototype archive, not a pixel-only proxy.
- Restore all 37 JPEG files byte-for-byte and verify SHA-256.
- Bound one-photo random access to one independent group of at most 4 or 8.
- Use real SfM geometry to generate prediction candidates.
- Reject the direction immediately when both group sizes miss 2.165x.

## Non-Goals

- No production integration or phone installation.
- No quality loss, coefficient quantization, JPEG re-encoding substitution, or
  deletion of source files.
- No claim that a host winner is a production winner.
- No attempt to optimize compression time after the ratio gate fails.

## Architecture

### Exact JPEG coefficient representation

A small C++ host tool uses the pinned host libjpeg-turbo coefficient API to
extract:

- the exact original byte prefix through the SOS header;
- image/component dimensions and sampling factors;
- restart interval;
- quantized DCT coefficients in component block order.

For reconstruction, the tool parses the preserved header to initialize the
JPEG compressor, writes the archived coefficient arrays with the original
restart interval, extracts the regenerated entropy scan, and concatenates the
preserved original prefix, regenerated scan, and EOI. Every output is compared
against the immutable source bytes and SHA-256.

### SfM-guided prediction

For each target frame, the estimator projects sparse PLY vertices into the
target and preceding reference frame using registered SfM world-to-camera
poses and per-frame intrinsics. Projected correspondences vote for a reference
DCT block for each target block. Uncovered blocks use a deterministic same-grid
fallback. Component sampling factors scale the luma mapping for chroma blocks.

The first image in each group is an anchor. Later coefficient arrays are stored
as signed residuals from the selected reference blocks. Headers and residuals
are encoded with deterministic zero-run/zig-zag tokens and compressed with XZ
5.8.3 preset 9 extreme. Group archives are independent.

### Random access

A fixed-seed random-access audit selects requested frame indices. The decoder
opens exactly one group archive, reconstructs at most the configured group
size, and verifies the requested original hash. No preceding group may be
opened.

## Metrics

Primary:

- `photo_ratio = source_jpeg_bytes / group_archive_bytes`

Hard gates:

- exactly 37 ordered files and 105,908,333 source bytes;
- all immutable input hashes unchanged;
- all reconstructed lengths, bytes, and SHA-256 values equal;
- no group contains more than 4 or 8 photos for its arm;
- every random access opens exactly one group;
- real registered poses and sparse PLY projections are consumed;
- archive decoding is deterministic and corruption fails closed.

Diagnostics:

- JXL effort-10 exact baseline bytes;
- group archive bytes;
- projection and mapped-block coverage;
- compression/decompression elapsed time;
- peak RSS and peak temporary bytes.

## Decisions

- A host ratio below 2.165x rejects the direction; host evidence can never
  approve production.
- A host ratio at or above 2.165x only authorizes an independent physical-phone
  bundle. Phone admission later requires no more than 3% full-pipeline time
  regression and no UI stall above 100 ms.
- The experiment keeps hashes, manifests, metrics, and logs. Large temporary
  coefficient and archive files are deleted after verification.
