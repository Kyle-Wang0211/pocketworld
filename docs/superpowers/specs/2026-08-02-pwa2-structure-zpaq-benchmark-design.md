# PWA2 Structure + ZPAQ Benchmark Design

## Goal

Measure the net size of a complete, future-project logical archive for the
frozen COLMAP SQLite database while changing only the data organization. Arm A
remains the frozen `track_delta_v1 + ZPAQ 7.15 method 5` result. Arm B uses the
same ZPAQ implementation and method on PWA2 logical chunks.

Arm B advances only when its complete persisted bytes are at most
`111,961,726`, every logical SQLite value is exact, row order is recoverable,
random record reads work from bounded chunks, and a materialized database has
the same query-visible contents. Host execution can reject but cannot admit
production.

## Exactness boundary

The source SQLite remains read-only and unchanged. Arm B is a future canonical
data format, so it does not preserve SQLite page placement, freelist bytes,
B-tree construction history, or the source database file SHA after
materialization. It preserves:

- every SQLite table, column, storage class, integer value, text byte, and BLOB;
- every descriptor byte, keypoint/camera/pose floating-point bit pattern, match
  pair, table row count, and primary-key order;
- all schema SQL required to materialize an equivalent database;
- a canonical logical SHA-256 before compression and after restoration.

The benchmark must not omit a table because it is empty or believed to be
regenerable.

## PWA2 layout

The experiment writes an append-only container made of independently compressed
members. Every member has a fixed identifier, uncompressed length, compressed
length, logical record range, SHA-256, codec identity, and payload offset. The
index itself is included in the measured bytes.

Large streams are split into blocks of at most 32,768 descriptor records. A
single descriptor record is reconstructed from its bounded parent dependency
chain and the corresponding class blocks rather than by decompressing the whole
database. The benchmark records the exact number of data members touched.

### Descriptor streams

The track forest uses exactly the existing deterministic verified-match
contract for the first B run. Nodes are `(image_id, descriptor_row)` in stable
global order. Forest roots are the minimum node in each component. Edges are
sorted deterministically and accepted by a disjoint set; residual traversal is
parent-before-child.

PWA2 stores three disjoint value streams:

- component roots as literal `uint8[128]`;
- child residuals as modulo-256 deltas from their recorded parent;
- descriptors not present in the forest as literal `uint8[128]`.

Each block is byte-lane-major: all dimension-0 bytes, then dimension-1, through
dimension-127. Topology stores root node IDs and `(child,parent)` pairs; all
unlisted nodes are unmatched literals. Metadata stores each image's descriptor
type, rows, columns, and global-node base.

### Other streams

Keypoints preserve every float32 bit and are grouped by column and byte plane.
Matches and verified two-view pairs preserve each uint32 and are grouped by
column and byte plane. Remaining table metadata and BLOBs use a deterministic
typed-row encoding. The first B arm does not add XOR, numeric delta, OpenZL,
Pcodec, Blosc2, or a learned model.

## Verification

Fixture tests must demonstrate RED before implementation, then prove:

- deterministic pack bytes;
- exact unpacked logical SHA and per-cell equality;
- exact descriptor reconstruction with roots, residuals, and unmatched rows;
- bounded random reads across the first, middle, and last blocks;
- malformed length, missing dependency, checksum corruption, and unsupported
  schema fail closed;
- the materialized SQLite passes `PRAGMA integrity_check` and a canonical
  table-content comparison.

The real run records source identity, Git/dirty-diff identity, ZPAQ identity,
ordered input manifest, block configuration, archive bytes, elapsed time, peak
RSS, peak temporary bytes, logical hashes, coverage counts, deviations, and
the pre-registered verdict.

## Stop rules

- Any exactness, determinism, checksum, source-mutation, or table-coverage
  failure rejects B immediately.
- B greater than `111,961,726` bytes remains a research result and does not
  enter a phone bundle.
- If B is smaller than the gate, the next task is an independent physical
  iPhone bundle using the same frozen input and production mobile pipeline.
- No production Dart, Swift, native archive selection, capture, or training
  code changes in this benchmark.
