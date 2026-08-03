# Joint Semantic WorldPack v2 Design

## Objective

Replace the current member-by-member cold archive experiment with one exact,
typed project archive that can exploit relationships among photographs, camera
poses, SfM tracks, descriptors, matches, point clouds, and metadata. The first
implementation remains host-only and experiment-only. It does not modify the
production bundle, source capture, or phone.

The immutable complete-project baseline is the already recorded
`471,146,040`-byte projection for the original `638,645,632`-byte mixed project.
The baseline artifact is referenced by hash and is not recomputed.

## Non-negotiable preservation boundary

- Every archived JPEG must restore to the original JPEG byte sequence and
  original SHA-256, not merely identical pixels.
- Every descriptor byte, keypoint/pose IEEE bit pattern, match identity,
  ordering relation, sparse/final point-cloud byte, and retained metadata byte
  must survive exactly.
- Future projects may treat the typed semantic archive as the source of truth.
  A materialized COLMAP SQLite database must contain identical logical values,
  types, counts, and order and must produce identical pipeline output; SQLite
  page allocation and write history are not archived as data.
- Existing projects are never rewritten by this experiment.
- Every persisted model, prediction edge, permutation, index, checksum,
  schema, and reconstruction sidecar counts toward candidate size.
- Corruption, missing dependencies, incompatible schema revisions, or failed
  hashes must fail closed before data is exposed.

## Why the current WorldPack is not this design

The current WorldPack is a sound transaction envelope, but it selects a codec
for each existing file independently. It does not share geometry or prediction
state across photo, descriptor, and graph members. The complete run therefore
proves framing and exact restoration, not a joint statistical model.

PWA2 was the first logical SQLite attempt, but its recorded implementation
predicted only 224,119 of 1,251,246 descriptors and retained 944,506 unmatched
literals. It did not combine the later full similarity forest, WebGraph winner,
and Pcodec numerical winners in one complete logical archive.

The earlier cross-photo A/B implemented dense-flow and FAISS forest variants
with ZPAQ. It did not reproduce the 2016 photo-collection method's complete
feature-domain global prediction structure, hybrid disparity compensation, and
adaptive frequency-domain residual coding. Its loss cannot reject that paper.

## Architecture

### 1. Semantic project schema

WorldPack v2 stores versioned logical streams instead of opaque source files:

- exact JPEG header/marker reconstruction streams;
- quantized JPEG DCT coefficient roots, predictions, residuals, and selectors;
- capture order, ARKit intrinsics/extrinsics, SfM registered poses, sparse
  projections, and photo prediction graph;
- descriptor roots, full similarity-forest residuals, and parent map;
- keypoint, camera, image, and pose typed columns;
- match/two-view graph plus original row/order mapping;
- sparse and final point-cloud exact typed streams plus original file framing;
- project policy, names, timestamps, and remaining small-file bytes.

The schema owns stable logical IDs. SQLite, JPEG, and PLY files are materialized
views when a consumer requires the legacy format.

### 2. Cross-photo exact JPEG model

The first photo subproject follows the published structure, not the old forest
prototype:

1. Parse each supported baseline JPEG into original marker/header bytes,
   quantization/Huffman configuration, restart state, and quantized DCT blocks.
2. Build a bounded-depth directed prediction tree using a frozen feature cost.
   Capture order, ARKit/SfM pose distance, shared tracks, and sparse visibility
   may break ties or constrain candidate edges, but every rule is fixed before
   measuring encoded size.
3. Generate both global and local disparity-compensated predictions. The
   prediction is only a reversible aid; the exact target quantized coefficient
   residual is always persisted.
4. Choose intra or inter frequency prediction per registered block using only a
   deterministic predeclared cost. Store the selector and all reconstruction
   state.
5. Entropy-code homogeneous streams. OpenZL custom tensor graphs may be tested
   only after the prediction transform is fixed; ZPAQ remains the exact fallback.

No claim of a faithful 2016 reproduction is permitted until a method map ties
every implemented stage and parameter to the full paper or author artifact.
The available 2014 precursor and 2015 SfM paper are supporting evidence, not a
substitute for missing 2016 details.

### 3. Semantic database model

- Apply `similarity_forest_v1` coverage to all descriptors, then store roots,
  residual byte lanes, and backward parents as separate bounded streams.
- Store matches and two-view geometries as the verified WebGraph representation
  plus exact table, duplicate, direction, and order mappings.
- Store compatible integer streams with the pinned Pcodec candidate when it is
  smaller than the same stream's ZPAQ result.
- Store float streams with the smaller exact ALP or ZPAQ representation. No
  truncation, quantization, NaN normalization, or float-width change is allowed.
- Materialize a fresh SQLite database and compare every typed ordered cell and
  downstream pipeline result. Exact legacy SQLite file SHA is not a requirement
  for future-format projects.

### 4. WorldPack v2 transaction layer

The outer file remains append-only and chunk indexed. Each committed chunk has
a schema/transform/codec identity, logical range, dependency list, original and
payload lengths, SHA-256 values, and CRC. Dependencies point only backward.
Random reads may decode a bounded dependency group, never the complete project.
Background work commits at chunk boundaries and can resume after interruption.

### 5. Repository-wide content addressing

After the single-project format wins, immutable WorldPack chunks may be stored
by plaintext SHA-256 and referenced from multiple projects. Content-defined
chunking is evaluated only on streams whose boundaries are not already semantic.
Deduplication is measured separately as physical repository storage; it must not
be reported as a better single-project compression ratio.

## Staged validation

### Stage 0: fidelity and commercial gate

Create a method map for the 2016 JPEG-collection paper and the 2015 SfM
extension. Freeze accessible source identity, equations, omitted implementation
details, code availability, codec dependencies, patent signals, and commercial
status. If the method cannot be faithfully and commercially implemented, mark
the exact missing components and do not disguise an approximation as the paper.

### Stage 1: minimum joint unit

Use the first deterministic eligible pair of adjacent original JPEGs from
capture `cap_1785512421333592`, together with their capture metadata, registered
poses, shared descriptor tracks, match edges, and visible sparse points. The
selection rule is frozen before encoding and cannot select the best-compressing
pair.

Compare only:

- saved per-photo exact winners plus saved semantic database bytes for the same
  logical slice;
- the complete joint candidate including root, residuals, selectors, graph,
  pose/track state, indexes, manifest, and checksums.

The joint candidate must be strictly smaller and pass all exactness gates before
expanding. A losing minimum unit is retained as evidence and stops that precise
configuration, not the whole architecture family.

### Stage 2: eight-photo dependency group

Run one predetermined eight-photo group. Verify independent random restoration
of four and eight photos, exact semantic database reads, dependency bounds,
corruption rejection, and peak memory. Do not rerun the saved baseline.

### Stage 3: complete frozen project

Run the candidate once on the full original project manifest. Compare complete
persisted bytes with `471,146,040`. Report both the original-input ratio and the
already-JXL-intermediate ratio, with the original-input ratio designated as the
product metric. Host evidence cannot promote production.

### Stage 4: physical iPhone production gate

Only a host winner receives an isolated benchmark bundle. The physical iPhone
must run the real production pipeline and meet exactness, random-read, UI stall,
memory, background interruption, and total pipeline-time gates before any
production change is proposed.

## Failure interpretation

- A codec loss rejects only that codec on the registered stream.
- A two-photo loss rejects only the registered prediction configuration.
- A missing full-paper detail blocks a fidelity claim; it does not prove the
  published method ineffective.
- Container overhead and sidecars are never hidden.
- Cross-project deduplication and single-project compression remain separate
  metrics and denominators.

## Authoritative references

- Hao Wu et al., *Lossless Compression of JPEG Coded Photo Collections*, IEEE
  TIP 2016, DOI `10.1109/TIP.2016.2551366`.
- Hao Wu et al., *Incremental SfM Based Lossless Compression of JPEG Coded
  Photo Album*, VCIP 2015.
- OpenZL official structured/tensor compression guidance:
  <https://openzl.org/getting-started/using-openzl/>.
- MCAP indexed chunk model: <https://mcap.dev/spec>.
- Parquet exact typed encodings:
  <https://parquet.apache.org/docs/file-format/data-pages/encodings/>.
- restic content-addressed repository design:
  <https://github.com/restic/restic/blob/master/doc/design.rst>.
