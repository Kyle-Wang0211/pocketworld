# Design: PLR-derived Brunsli two-photo Phase 0/1

## Frozen identities

The pair is `cell_85_slot_4.jpg` followed by `cell_85_slot_5.jpg`, with sizes
2,995,750 and 3,112,949 bytes and SHA-256 values
`ac91faba107c41f891dbce7128f0ecc8e66cb451892e231479d8bf8b738e4be6`
and `73ec448d66a2242f5d8a07d3531d9018f604d3a67b219a5689901734fce83e4e`.
The formal project count is 96 because both frozen inputs belong to
`analysis_cap_1779777762841797`, whose `photos_highres` directory contains 96
registered lowercase `.jpg` files. The approved self-contained range remains
93–300 photos. The previous 141 count had no binding to the frozen pair and is
retired before any model training or terminal baseline measurement.

Brunsli primary source is v0.1 commit
`8a0e9b8ca2e3e089731c95a1da7ce8a3180e667c`. The sole fallback is the
pre-pinned master commit `c9128f43994c1ca830dd079777d85f16736d6ba7`.
Official PLR source identity remains
`8a65e4d0d3daa9292e40df0541e8f43fcaada2d7`, but the new encoder is named a
PLR-derived completion because missing codec behavior is implemented locally.

## Phase 0 model timing

Final trained weights do not exist in Phase 0. A frozen untrained architecture
therefore supplies only a provable raw-size upper bound when architecture,
precision, tensor shapes, metadata, and envelope guarantee the final raw
artifact has the same length. Compressed untrained weights are diagnostic; no
claim is made that they are a mathematical upper bound.

Immediately before the terminal Phase 4 comparison, raw, Zstd 1.5.7 level 22,
and ZPAQ 7.15 method 5 are rerun on the final deployment artifact. Every arm
must restore that artifact byte for byte. The smallest complete persisted
result is `final_M`, and only `final_M` enters formal accounting.

Precision conversion is a different concern. A converted representation may
be called decoder-equivalent only when its registered integer-CDF decision
trace is identical. Any changed decision makes it a separately frozen model
arm, even if that arm still restores JPEG data exactly.

## Pre-Phase-2 leakage and portability correction

Training, validation, model selection, and tuning exclude the complete
`analysis_cap_1779777762841797` capture. The byte-identical
`analysis_cap_1779777762841797_v2` duplicate is excluded as the same physical
scene. Their 96-file ordered content manifests are hashed before training. The
two formal JPEG inputs are copied byte for byte into an experiment-local DVC
output so the test archive no longer depends on the lifetime of another
repository.

The registered decoder schedule has 22 ordered network distribution stages per
photo: two hyperprior stages, two Cb/Cr checkerboard stages, nine Y1 frequency
groups, and nine Y2/Y3/Y4 frequency groups. The official sibling implementation
supplies the frozen frequency grouping `[28, 8, 7, 6, 5, 4, 3, 2, 1]` that the
selected Trans implementation references but does not initialize. More than 24
stages or any per-coefficient autoregression is `blocked_portability` before
training. Terminal CDF evidence runs on CPU with one thread and separate encoder
and decoder processes; their integer-CDF traces must match exactly.

## Exact container split

The adapter parses with Brunsli `ReadJpeg(JPEG_READ_ALL)`. It asks Brunsli's
section serializer to persist signature, header, JPEG internals, metadata, and
quantization while skipping histogram, DC, and AC sections. All component
coefficients are copied in their exact `int16_t` component/block/zigzag order
to a distinct payload.

Both payload envelopes include a format version, exact length, and SHA-256.
Restore verifies both envelopes before producing any public output, rebuilds
the Brunsli `JPEGData`, injects the separately decoded coefficients, and calls
Brunsli `WriteJpeg`. The final file is atomically published only after length,
byte comparison, and SHA-256 match the frozen source.

## Bounded fallback

The unmodified v0.1 adapter runs once on both frozen inputs. Only an upstream
parse or reconstruction failure authorizes the same test once on the frozen
master commit. No patch, cherry-pick, wrapper repair, or alternate JPEG is
allowed. Failure of both revisions yields
`blocked_upstream_exact_container`.

## Scope boundary

Phase 1 success proves only that exact container separation is possible. It
does not authorize model training, JXL/Lepton measurement, the terminal
candidate, a phone build, production edits, or automatic codec switching based
on project photo count. Each later boundary requires its own accepted plan.

## Phase 2 corpus and model freeze

Phase 2 uses original quantized JPEG coefficients, not the upstream training
script's synthetic quality-75 JPEG path. Every public input comes from the
official Open Images CVDF mirror, is joined to official CC BY 2.0 attribution
metadata, and must pass listing-size, listing-ETag, local SHA-256, complete-JPEG,
three-component, and exact 4:2:0 checks. The deterministic public target is
10,000 eligible images split 9,000/500/500. The existing 414-photo first-party
corpus remains grouped by capture cell, and the full frozen test capture and its
duplicate remain excluded from training, validation, model selection, and
tuning.

The public `TransJPEGRecompression422` is not treated as a complete official
codec: its forward path omits Cb/Cr rate and its codec path references undefined
modules. The experiment is therefore explicitly a `PLR-derived completion`.
It uses the same pinned repository's complete 22-stage
`EfficientJPEGRecompression` sibling, with the official default width
`N=192/M=288`, plus one pre-registered `N=96/M=144` scope-2 compact arm. The
only local entropy change is replacing the incomplete custom latent bridge with
the pinned mature CompressAI Gaussian conditional codec and integer-valued
means. Both arms use the identical corpus, schedule, seed, loss, and training
budget.

Arm and checkpoint selection is performed only on the validation split. Its
metric is validation entropy bytes plus the complete stored model cost scaled
to the frozen 96-photo scope. The frozen two-photo pair is never used for this
choice. This tests the real tradeoff between a wider predictor and its
self-contained model cost without imposing an arbitrary model-size ceiling.
Validation uses a fixed epoch-zero patch per image. Images with the same exact
32-block tile count are batched together; patch entropy is multiplied by that
tile count, and the model is charged in proportion to validation photo count
over 96. This is a registered selection estimator, not the terminal result.
Only the final full candidate bitstream can establish a win.

Training uses one deterministic exact 32-by-32-luma-block patch per image and
epoch, 100 epochs, batch size 64, Adam at `1e-4`, auxiliary Adam at `1e-3`, and
seed `20260803`. The Mac MPS backend is permitted only with the documented CPU
fallback for `erfc`; a smoke backward pass already established finite loss and
gradients. Final entropy coding, CDF trace comparison, and the terminal verdict
remain one-thread CPU work in separate encoder and decoder processes. MPS
training results cannot themselves establish exact decoding.
Each arm keeps an atomically replaceable resumable latest checkpoint, the best
validation checkpoint, and append-only metrics for every epoch. Keeping 200
nearly identical 80 MB epoch snapshots would consume the experiment disk
without adding reproducibility; the complete metric trail and resumable state
remain preserved.
