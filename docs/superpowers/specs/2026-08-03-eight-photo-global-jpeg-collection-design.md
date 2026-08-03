# Eight-photo global JPEG collection design

## Decision

Continue the collection-level semantic archive after the rejected two-photo
predictor. The rejected result only falsified the registered
`single-parent homography + radius-two coefficient-block search + flat ZPAQ`
candidate. It did not exercise collection-wide parent selection, photometric
prediction, multiple spatial predictors, or typed frequency streams.

The next candidate is one fixed eight-photo unit. It is a declared PocketWorld
independent implementation informed by the accessible 2014/2015 precursor
papers and the public 2024 FDBM abstract. It must never be described as a
faithful implementation of the inaccessible 2016 Microsoft or 2024 FDBM
bitstreams.

## Frozen input and reference

- Capture: `cap_1785512421333592`.
- Photos: capture ordinals 0 through 7, selected before inspecting candidate
  output size.
- All eight photos have registered SfM poses.
- Their complete undirected relationship graph has all 28 edges and 11,546
  verified matches.
- Original JPEG bytes: 22,635,503.
- Saved incumbent JXL bytes: 18,453,828. The JXL encoder must not run.
- A 31% reduction from the original JPEG collection is 15,618,497 bytes. This
  is a research target from the Microsoft paper, not an acceptance promise.

## Candidate architecture

### Global feature graph

Build a deterministic maximum spanning tree over all 28 verified relationships.
The edge score is the verified match count, followed by lower median matched
descriptor distance, then image IDs. Choose the root with maximum verified-edge
centrality, then lower incumbent JXL bytes and image ID. Orient the tree away
from the root. Candidate output size is never an input to graph selection.

### Hybrid exact DCT prediction

For every child block, form deterministic candidate parent locations from:

1. global homography estimated from verified keypoint correspondences;
2. local sparse-geometry displacement interpolation from verified matches;
3. a bounded low-frequency coefficient search around those two locations;
4. intra fallback using already reconstructed left/top child blocks;
5. zero prediction.

Fit fixed-point per-component/per-frequency affine predictors on graph-edge
correspondences. Select the block predictor using a low-frequency cost, then
select inter/intra/zero per frequency with a deterministic complete residual
cost and stable tie break. Persist graph edges, fixed-point models, modes,
motion deltas, headers, indexes, checksums, and exact signed coefficient
residuals. The decoder performs only integer/fixed-point operations and adds
the residual to recover every original quantized DCT coefficient.

### Typed frequency entropy streams

Do not send one flat interleaved `int32` buffer to ZPAQ. Split exact values into
independently framed streams: luma/chroma DC, luma/chroma low AC, luma/chroma
high AC, modes, motion deltas, graph/model/header metadata. Residuals use signed
zigzag varints with zero-run tokens. Every stream is compressed by the same
pinned ZPAQ 7.15 method 5 backend so this run measures structure, not a backend
change. Raw fallback is allowed per stream and counted.

### Exactness and access

The root remains its already verified JXL member. Every child must be restored
to the exact original JPEG byte sequence and SHA-256. The archive stores one
eight-photo dependency group; random read of any member may decode at most the
root-to-member path, bounded at eight photos. Corruption in every stream class
must fail closed.

## Execution rule

Unit tests use synthetic coefficient blocks and never encode the frozen real
photos. Once tests and OpenSpec validation pass, run the real eight-photo
candidate exactly once. Do not rerun the saved JXL baseline or the rejected
two-photo candidate. Production and phone execution remain forbidden.

The candidate is accepted as the new photo-local research baseline if and only
if it is strictly smaller than 18,453,828 bytes and all exactness, dependency,
source-hash, and corruption checks pass. Reaching 15,618,497 bytes is reported
separately as the paper-derived target.

