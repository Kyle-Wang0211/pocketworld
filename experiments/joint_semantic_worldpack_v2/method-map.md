# Microsoft JPEG Collection Codec Fidelity Map

Audit date: 2026-08-03 (Asia/Shanghai)

Target claim under audit: a faithful reproduction of the 2016 Microsoft/IEEE
TIP paper *Lossless Compression of JPEG Coded Photo Collections*, not merely a
codec inspired by its abstract or by the authors' earlier papers.

## Terminal verdict

The public evidence is sufficient to reproduce the high-level pipeline, but it
is not sufficient to implement the 2016 bit-exact method faithfully. The full
2016 paper and an author-owned reference implementation were not found in the
publicly accessible sources audited here. Several decision-critical algorithms,
parameters, tie breakers, fixed-point rules, and bitstream definitions therefore
remain unknown.

This blocks the label `faithful 2016 reproduction`. It does not block an
independently specified PocketWorld semantic-photo codec, provided every
substitution is declared and the result is benchmarked as a new implementation
rather than attributed to the paper.

## Stage-by-stage map

### feature-domain prediction structure

- Publicly supported: the 2014 precursor constructs a directed prediction graph
  using the average distance of matched SIFT descriptors, derives a spanning
  prediction structure, and uses a depth-first traversal. It discusses limiting
  prediction depth for random access.
- Missing for the 2016 target: the complete objective, candidate-pruning rules,
  graph constraints, deterministic tie breaking, and any changes responsible
  for the jump from the precursor's reported savings to the 2016 result.
- Status: `blocked_missing_detail`.

### global disparity compensation

- Publicly supported: the precursor describes geometric homography, photometric
  transformation, and warping; its SfM extension describes camera calibration,
  pose projection, and a homography fallback.
- Missing for the 2016 target: the exact optimizer, photometric model, robust
  estimation thresholds, interpolation and edge rules, precision, signaling,
  and rate-selection procedure.
- Status: `blocked_missing_detail`.

### local disparity compensation

- Publicly supported: the precursor states that block motion compensation is
  combined with the global transform. The SfM extension also selects among
  several prediction modes.
- Missing for the 2016 target: block partitioning, search ranges, search order,
  cost function, sub-pixel precision, interpolation, border handling, motion
  vector prediction, tie breaking, and exact syntax.
- Status: `blocked_missing_detail`.

### frequency-domain adaptive prediction

- Publicly supported: a compensated prediction is transformed and quantized in
  the JPEG DCT domain, then subtracted from the original quantized target DCT
  coefficients. Storing the exact coefficient residual permits lossless image
  reconstruction.
- Missing for the 2016 target: the adaptive predictor's complete mode set,
  neighborhood/context definition, training or selection rule, scan ordering,
  coefficient representation, rate cost, precision, and syntax.
- Status: `blocked_missing_detail`.

### context-adaptive entropy coding

- Publicly supported: the 2015 SfM extension names CABAC for residual coding;
  the 2016 abstract says advanced context-adaptive entropy coding is used.
- Missing for the 2016 target: context definitions, initialization, update
  rules, bypass decisions, binarization, termination, byte alignment, and an
  authoritative bitstream implementation. CABAC/HEVC-related deployment also
  requires a separate patent and commercial-use assessment.
- Status: `blocked_missing_detail`.

### exact JPEG binary reconstruction

- Publicly supported: earlier papers state that original JPEG Huffman data can
  be recovered, and PocketWorld's existing coefficient-framing tools can verify
  restoration of a frozen input JPEG byte for byte.
- Declared substitution: PocketWorld's local JPEG framing is not an official
  Microsoft bitstream implementation. It may establish the required product
  invariant (restored JPEG SHA-256 equality), but it cannot establish fidelity
  to the unpublished 2016 format.
- Status: `faithful_with_declared_substitution` for the losslessness boundary,
  not for the 2016 file format.

## What may proceed

The following independently specified work is not blocked by the missing 2016
details:

1. A PocketWorld-owned, versioned photo-prediction format using capture order,
   ARKit/SfM poses, and sparse geometry.
2. Exact JPEG coefficient residuals plus preservation of every original JPEG
   byte needed for SHA-256-identical reconstruction.
3. Full descriptor similarity forest, WebGraph match streams, Pcodec integer
   streams, and ALP/ZPAQ lossless floating-point stream selection.
4. Interruptible, chunk-verified WorldPack storage and cross-project content
   addressing.

Every such experiment must be labeled `declared independent implementation`.
The paper's reported 31% is a research target, not a predicted or promised
PocketWorld result.

## Production gate

No photo codec from this audit may enter production unless all of the following
are independently demonstrated:

- every original JPEG is reconstructed byte for byte and has the same SHA-256;
- random access restores only the bounded dependency set declared by the index;
- interruption and resume preserve committed chunks and never delete the last
  verified copy;
- an exact source/dependency/patent/license review returns an admissible
  commercial-use verdict;
- a physical-iPhone production benchmark passes the pre-registered product
  thresholds.

