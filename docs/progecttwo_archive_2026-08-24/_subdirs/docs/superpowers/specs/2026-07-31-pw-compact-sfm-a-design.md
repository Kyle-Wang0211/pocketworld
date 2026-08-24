# PocketWorld Compact SfM A — Design

## Decision

Future projects may use a new compact file as the canonical original for SfM
features, matches, geometry, and sparse tracks. Losslessness applies to every
logical value and its bit representation, not to the physical page layout of a
temporary COLMAP SQLite database.

Historical projects remain on the existing raw-SQLite ZPAQ format and must
still restore their original `.db` bytes and SHA-256.

## Immutable experiment identity

- PocketWorld inspected revision: `6362d38` with a shared dirty worktree.
- Official reconstruction source recorded by the existing experiment:
  `/Users/kaidongwang/Developer/Aether3D-cross` at
  `b930ab185135dfbd172aef7c2bbeed67ef315f75`.
- COLMAP schema: vendored `3.14.0.dev0`.
- Compression baseline: pinned libzpaq 7.15 method 5.
- Frozen inputs: the five database path/length/SHA-256 records already listed
  in
  `/Users/kaidongwang/Developer/pocketworld/experiments/sqlite_descriptor_zpaq/input-manifest.yaml`.
- First bounded diagnostic input:
  `cap_1785297411166420`, 50,008,064 bytes,
  SHA-256
  `d71b3c54843ae3b25cb2269e723a0c33612a4a2bade08ff97f85a6108ce0bfe7`.

## Observed storage composition

Across the five frozen databases (889,085,952 bytes):

- descriptors: 77.78%;
- keypoints: 14.61%;
- raw matches: 3.90%;
- two-view geometry: 3.61%;
- SQLite structure and small metadata: less than 1%.

In the bounded input, every two-view correspondence is present in the raw
match table. The two-view table can therefore preserve its exact row sequence
as references into raw matches plus literal exceptions, instead of duplicating
all `(uint32, uint32)` pairs.

The current sparse PLY is already binary little-endian and uses exactly 15
bytes per point (`float32 xyz + uint8 rgb`). It is not part of the first
admission experiment because it is small and cannot materially change the
whole-project result. A later format can preserve its exact point records and
track graph in separate chunks.

## Canonical container

The experiment format is `PWCSFMA1`. It is deterministic and little-endian.
It contains:

1. a fixed header with version, flags, section count, and manifest digest;
2. an uncompressed bounded index for random lookup;
3. independently compressed chunks;
4. a footer containing the logical dataset SHA-256 and index SHA-256.

Every integer uses an explicitly sized unsigned or signed representation.
Every floating value is stored as its original IEEE-754 bits. No quantization,
float narrowing, rounding, coordinate change, row deletion, or match pruning
is permitted.

### Feature chunks

One feature chunk covers at most eight images:

- an image directory stores image ID, keypoint count, descriptor type and
  payload offsets;
- keypoints are split by column, then byte-shuffled by the four bytes of each
  `float32`;
- descriptors are transposed from feature-major `N × 128` to 128 dimension
  streams;
- the original per-image row order is explicit and must be restored exactly.

XOR and modulo-delta descriptor predictors are not in the first candidate.
The bounded real sample measured worse zero-order entropy for both than raw
descriptor bytes.

### Match chunks

One match chunk covers at most 256 image pairs:

- pair IDs remain explicit;
- raw match rows retain their original order;
- each `uint32` endpoint is encoded with signed delta plus varint;
- two-view rows are encoded as occurrence-aware references to raw match rows;
- any row that cannot be referenced is encoded literally;
- geometry configuration and all F/E/H/qvec/tvec BLOB bytes retain type,
  nullness, length, order, and exact contents.

### Metadata

All small COLMAP tables are serialized in schema-defined primary-key order.
SQLite storage details such as page numbers, free lists, padding, change
counters, and B-tree shape are not canonical data.

## Read and restore behavior

- `read_features(image_id)` decompresses at most the one feature chunk that
  owns the image.
- `read_pair(pair_id)` decompresses at most the one match chunk that owns the
  pair.
- A deterministic exporter can materialize a valid COLMAP SQLite database.
  Logical values and row order must match the source; the SQLite file SHA-256
  is intentionally not part of A.
- Production integration is not authorized by this experiment. If the format
  passes, a separate change will integrate direct/lazy reads so resuming a
  pipeline does not wait for whole-database decompression.

## Hard admission gates

Host results can reject a candidate but cannot approve it. Approval requires
the physical iPhone and the actual portable core.

1. Source files remain unchanged.
2. Every decoded integer, BLOB, null, row count, row order, and IEEE-754 bit is
   identical.
3. Dataset logical SHA-256 is identical.
4. Random image and pair reads return exact values without full archive
   decompression.
5. A materialized SQLite database passes `PRAGMA integrity_check`.
6. Baseline and candidate production-finalize runs use isolated copies of the
   same capture and produce identical declared pipeline outputs.
7. Every real database is no larger than raw ZPAQ method 5.
8. Median candidate bytes across the frozen inputs and three iPhone repeats
   are at least 10% below raw ZPAQ method 5.
9. Any exactness, corruption, cancellation, or ordering failure rejects the
   format regardless of size.

## Stop conditions

- Stop before making a phone bundle if the bounded 50 MB host diagnostic
  cannot beat the raw-ZPAQ archive by 10%.
- Stop the full input sweep if any file regresses or any exactness check fails.
- Do not modify production archive policy, manifests, bundle identifiers, or
  phone production data before all gates pass.

## Implementation boundary

The codec core is portable C++17 because it performs bounded raw binary
transforms and must be identical on iOS and future non-Apple targets. Dart will
own later production scheduling, policy, audit state, and transactions. Swift
is not required for the codec.

