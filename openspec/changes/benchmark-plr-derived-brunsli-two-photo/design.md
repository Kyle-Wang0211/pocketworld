# Design: PLR-derived Brunsli two-photo Phase 0/1

## Frozen identities

The pair is `cell_85_slot_4.jpg` followed by `cell_85_slot_5.jpg`, with sizes
2,995,750 and 3,112,949 bytes and SHA-256 values
`ac91faba107c41f891dbce7128f0ecc8e66cb451892e231479d8bf8b738e4be6`
and `73ec448d66a2242f5d8a07d3531d9018f604d3a67b219a5689901734fce83e4e`.
The formal project count is 141 and the approved self-contained range is
93–300 photos.

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
