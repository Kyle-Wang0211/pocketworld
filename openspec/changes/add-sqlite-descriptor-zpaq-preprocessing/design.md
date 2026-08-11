## Context

The active app revision at design freeze is
`ffc204a3086bfe667c42c455641b995ee67137de`; the shared dirty-diff SHA-256 is
`a7ad3f62e80f0d8944e1a10186790eea31abc2849b97fd45992c3fa559eb79aa`.
The official reconstruction source is
`/Users/kaidongwang/Developer/Aether3D-cross` at
`b930ab185135dfbd172aef7c2bbeed67ef315f75`, using the vendored COLMAP
`3.14.0.dev0` SQLite schema. ZPAQ remains the pinned official libzpaq 7.15
revision
`e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418`,
method 5.

The five immutable input databases are identified by SHA-256 in
`experiments/sqlite_descriptor_zpaq/input-manifest.yaml`. They range from about
50 MB to 227 MB, use 4096-byte pages, pass `PRAGMA integrity_check`, and have no
freelist pages. Each `descriptors.data` value is exactly `rows × 128` bytes.

## Goals / Non-Goals

**Goals:**

- Improve ZPAQ compression by reversible, same-length reordering of descriptor
  bytes.
- Restore the exact original SQLite file, not merely an equivalent database.
- Leave the source file unchanged throughout encode and verification.
- Fail closed on unknown schemas, malformed pages, invalid overflow chains,
  cancellation, or any reconstruction mismatch.
- Produce portable C++ suitable for iOS and other SQLite-capable targets.

**Non-Goals:**

- Quantization, descriptor recomputation, row removal, SQL export/import,
  `VACUUM`, or canonical database rebuild.
- Changing the currently shipped raw-ZPAQ policy during the experiment.
- Selecting a production winner from host-only results.
- Automatically processing historical projects or touching phone originals.

## Decisions

### Transform only a temporary byte-identical copy

The encoder copies the closed source database to a temporary output and applies
the transform there. It never opens the source for writing. Any parser or write
failure removes the incomplete output.

### Locate BLOB bytes through SQLite b-tree structure

The implementation validates the exact `descriptors` schema with a read-only
SQLite connection and obtains its root page. A portable raw-page reader then
walks table interior/leaf pages, parses record serial types, and follows
overflow chains. It constructs physical spans only for the fifth record field,
`descriptors.data`.

The parser validates page size, reserved bytes, page bounds, page types,
varints, local-payload calculations, row IDs, record sizes, BLOB serial types,
`cols == 128`, `length(data) == rows × cols`, and non-overlapping acyclic
overflow chains before writing any transformed byte.

### Compare the raw archive with the match-track candidate

- `raw`: existing database bytes, no preprocessing.
- `track_delta_v1`: use verified `two_view_geometries` matches to build a
  deterministic spanning forest over `(image_id, descriptor_row)` nodes. Keep
  every root and unmatched descriptor literal; store each child as the
  modulo-256 byte delta from its parent.

Every arm is same-length and deterministic. Decode applies the exact inverse.

### Hard correctness gates outrank compression

Every measured encode is immediately decoded. Acceptance requires:

- unchanged source length and SHA-256;
- restored length equality, byte equality, and SHA-256 equality;
- `PRAGMA integrity_check = ok`;
- identical transformed/archive hashes across deterministic repeats;
- rejection of corrupt/truncated inputs and archives;
- cancellation and injected I/O failures retain the source.

One mismatch blocks that transform regardless of its compression ratio.

### Host evidence is diagnostic; iPhone evidence selects

Host tests prove parser/transform behavior and reject broken candidates. They do
not select the production winner. Surviving arms run through the actual
portable native bridge on the physical iPhone using isolated copies. This local
preprocessing candidate may advance when every complete database archive is
smaller than raw ZPAQ over three repeats. The former 10% threshold remains only
for a substantially more invasive replacement of COLMAP's storage layer.

### Preserve archive compatibility

The current production v1 raw-ZPAQ archive remains readable. If a candidate is
later integrated, it receives a new explicit preprocessing identity in policy
and manifest data. A decoder never guesses whether preprocessing was applied.

## Test Matrix

1. Deterministic fixtures: empty descriptors, one row, partial rows, 8192 rows,
   multiple records, local/overflow boundaries, auto-vacuum on/off, and page
   sizes 512/1024/4096/65536.
2. Value distributions: zero, constant, ramp, repeated, real-looking RootSIFT,
   and high-entropy random.
3. Property runs: at least 1000 fixed seeds; forward then inverse must equal the
   original bytes.
4. Malformation: bad magic, invalid page size/type, truncated page, bad varint,
   out-of-range/looped/reused overflow page, wrong schema, non-128 columns, and
   length mismatch.
5. Transaction faults: cancellation before/during transform, output failure,
   truncated/bit-flipped ZPAQ, restart between phases, and duplicate
   source/archive reconciliation.
6. Real input preflight: one immutable complete database, raw and
   `track_delta_v1`, three complete encode/decode repeats. Broader device input
   coverage remains required before production integration.
7. Physical iPhone: actual bridge and cold-task scheduling, isolated fixture
   copies, cross-process restoration, SHA-256/byte/integrity checks, and resource
   diagnostics.

## Risks / Trade-offs

- A raw SQLite parser is security-sensitive → validate every offset and length,
  maintain explicit visited-page sets, reject unsupported layouts, and fuzz the
  parser before production use.
- ZPAQ may already model the data well → compare complete archives and retain
  the transform only when it produces a strict net byte reduction with no
  per-file regression.
- Preprocessing adds temporary I/O → stream or page-map one BLOB at a time and
  record peak RSS/temp bytes; performance is diagnostic, but OOM is a hard
  failure.
- SQLite layouts can evolve → exact schema/version checks and raw-ZPAQ fallback;
  never infer compatibility.

## Rollback

Delete or disable the experimental preprocessor and retain the existing
raw-ZPAQ v1 codec. No production archive or database requires the experimental
format until the separate integration gate is approved.
