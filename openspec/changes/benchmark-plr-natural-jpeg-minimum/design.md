# Design: Official PLR natural-photo minimum gate

## Context

The frozen source is `photos_highres/official_tap-2019.jpg` from capture
`cap_1785512421333592`: 2,725,495 bytes with SHA-256
`a1cb8de1d3b91edbb7e05233c7930200c46e04554c3651153e267e5abd262138`.
The saved same-input JXL effort-10 result is 2,215,345 bytes and restored the
source exactly on the physical iPhone.

The official PLR repository is frozen at commit
`8a65e4d0d3daa9292e40df0541e8f43fcaada2d7`, tree
`67796f3cfc8ef558d3b2287fcf315a8731ae1f14`. Public-source inspection is a
mandatory gate because training a rate model does not prove that a deployable
exact-JPEG codec exists.

## Decisions

### Audit before training

The official public route must provide all of the following without a local
algorithm repair: a checkpoint or reproducible training path, a callable
entropy encode/decode path, serialization of every returned entropy string and
shape, ingestion of original JPEG coefficients and metadata, and reconstruction
of the original JPEG file bytes. Missing any item stops the run as
`official_codec_incomplete`; it is not recorded as a compression loss.

### Do not substitute an estimated rate

Forward-pass likelihood or `bpp_loss` is diagnostic only. It must not be
compared with JXL's actual file size. Only a persisted archive measured with
`stat` and successfully decoded by the official path is eligible.

### Count the model honestly

If the public codec gate passes, report both:

- `standalone_effective_bytes = stream + container + exact_jpeg_side_data + model`
- `project_effective_bytes = stream + container + exact_jpeg_side_data + ceil(model / 141)`

The denominator 141 is fixed from the known source capture before seeing PLR
results. The saved 2,215,345-byte JXL file is the strict comparison threshold.
The standalone and 141-photo-amortized figures remain separate; neither may be
silently omitted.

### Preserve the minimum-unit funnel

There is one JPEG and one terminal run. No 100 MB corpus, cross-photo condition,
complete project, phone bundle, or production edit is allowed until exactness
passes and the registered effective metric is strictly smaller than JXL.

## Preflight finding

The frozen public revision fails the official-codec gate before training:

- the official training entry invokes only `model(...)`, logs `bpp_loss`, and
  saves PyTorch checkpoints; it never invokes `compress` or `decompress`;
- its selected `PNGFolder_Trans` path reads decoded pixels and creates synthetic
  DCT coefficients with `torchjpeg.codec.quantize_at_quality`, rather than
  preserving an arbitrary input JPEG's marker/header/metadata bytes;
- the selected model constructs `Gaussian_Y` and `Gaussian_CbCr`, while its
  public `compress/decompress` methods refer to multiple different, undefined
  attributes;
- the training entry explicitly selects `TransJPEGRecompression422`, whose
  forward path comments out Cb/Cr entropy modeling and returns
  `bpp_likelihoods_cbcr == 0`; even its likelihood estimate is therefore not a
  complete JPEG rate;
- the undefined codec members are not merely misspelled Transformer members:
  they belong to the older MLCC-style implementation in `sensetime.py`. The
  PLR Transformer forward API needs target coefficients, context and masks,
  while its inherited compress/decompress blocks supply context alone. A
  target-aware sequential entropy traversal is missing;
- no official checkpoint, release asset, `jpegio.write`, whole-JPEG serializer,
  or byte/SHA restoration check exists in the frozen repository.

Therefore installing PyTorch or training on natural images cannot produce the
required official PLR archive. Repairing the missing codec would be a new
PocketWorld implementation, not a faithful run of the official release.

## Community and adjacent implementation audit

The repository history contains no deleted completion: after the initial public
commit, upstream deleted only issue templates and five plot scripts. As of
2026-08-03 the repository is less than three weeks old and has zero forks,
issues, and releases, so no public community patch exists yet.

Community reverse engineering of PackJPG and discussions around JXL, Brunsli,
Lepton and libjpeg-turbo consistently split exact JPEG recompression into two
layers: preserve/reconstruct the JPEG container and original entropy-coder
choices, while a specialized model encodes the quantized DCT coefficients.
Decoding pixels and writing a new JPEG is not sufficient.

The most relevant recent cross-photo clue is the 2024 PCS method "Lossless JPEG
Recompression for Similar Images via Frequency Domain Block Matching". Its
authors also filed pending Chinese patent CN117857794A. The disclosed route
uses a 3x3 frequency-domain block search, optimizes the tradeoff between motion
direction continuity and residual magnitude, selectively deltas only the first
N zigzag coefficients, and sends the streams through Brunsli/Brotli. The patent
reports 37% reduction from JPEG and 17% improvement over a single Brunsli route
on its pedestrian-image dataset. This is a useful architecture clue but not
commercially reusable code, and its pending claims require patent review before
a faithful product implementation.

Newer 2025-2026 papers report learned decomposition or joint
spatial/transform-domain predictions, including 31.54% on Kodak for PLLR, but
no discoverable public source or checkpoints were found. They remain research
leads, not runnable official candidates.

## Minimum diagnostics

Three real PocketWorld camera JPEGs were parsed without changing production.
Each has exactly 1,501 bytes of non-scan data when raw marker bytes, quantization
and Huffman tables, restart markers and trailing data are conservatively counted
as reconstruction side data. That is only 0.0482%-0.0539% of each source. Exact
JPEG reconstruction overhead is therefore not what blocks PLR on this capture;
the absent complete DCT entropy stream is.

A separate two-photo diagnostic used adjacent 4224x2376 captures 0.319 seconds
apart. It implemented only the disclosed 3x3 block search and first-N exact DCT
residual, with 4-bit directions, then compared both arms under the same Zstd-22
backend. Search improved every residual over same-position prediction, proving
that block selection carries signal, but the simplified candidate was still
2.20%-14.46% larger than coding the target coefficients directly. This does not
reject the 2024 method: it demonstrates that the omitted tolerance optimization
and Brunsli coefficient contexts are material and that "residual plus a generic
codec" is not a faithful reproduction.

## Status

`preflight_rejected_official_codec_incomplete`. Production and the saved JXL
baseline remain unchanged. Any next implementation is explicitly a new
PLR-derived completion or a licensed/reimplemented 2024-style candidate, not an
official PLR run.
