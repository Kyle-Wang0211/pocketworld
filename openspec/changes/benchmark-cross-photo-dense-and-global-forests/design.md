# Design: Cross-photo A/B/C exact JPEG benchmark

## Frozen input and baseline

The original temporary 37-photo input was removed by system cleanup before this
experiment began. Use the next immutable production-backup prefix instead: 25
consecutive exact-JPEG JXL members whose restored JPEGs total 107,649,656 bytes.
Their existing verified JXL members total 88,409,901 bytes. The runner SHALL
independently restore and hash every JPEG before either candidate begins.

Every arm runs the complete input. The former 2.165x early-stop threshold is
retired. Any candidate strictly smaller than the JXL baseline with zero
exactness failures becomes the photo research baseline.

## Common group archive

Frames remain in capture order and are divided into groups of at most eight.
Each group is independently decodable. The first JPEG is stored as exact JXL;
later JPEGs store their original JPEG header/side information, parent metadata,
and modulo-65536 `int16` DCT residuals. A versioned manifest records ordered
names, lengths, SHA-256 values, member offsets, codec identity, and group root.
All non-root payloads use the same pinned ZPAQ 7.15 method 5 backend.

Decode reconstructs the root JPEG, extracts its exact quantized DCT blocks,
decodes children in parent order, recreates each original JPEG bitstream using
the already verified coefficient tool, and enforces length, byte comparison,
and SHA-256 equality.

## Arm A: dense-flow local forest

For each non-root frame, select one earlier frame in its group using the real
capture pose/SfM metadata and capture order. OpenCV DIS dense optical flow runs
on downscaled luma pixels from target to parent. Store a compact quantized flow
grid, not a full-resolution flow field.

For each DCT block, derive the predicted parent coordinate from the grid and
evaluate the 5x5 integer-block neighborhood. Store one selector byte and the
exact modulo-65536 coefficient residual. The selector and flow grid are part of
the compressed payload. Blocks without an in-range candidate remain literal.

Frozen parameters: group size 8, image scale 0.25, flow-grid spacing 64 source
pixels, local radius 2 blocks, DIS preset medium. OpenCV 4.13.0_5 is
Apache-2.0 and encoder-only.

## Arm B: Faiss global DCT forest

Within each group and JPEG component, query every non-root block against all
blocks of earlier decoded frames. Faiss `IndexIVFFlat` uses squared L2 on the
64 exact quantized DCT coefficients converted to float only for neighbor
selection. Store the selected earlier block as a backward varint plus the exact
modulo-65536 residual. Approximate search can affect size but never data.

Frozen parameters: group size 8, dimension 64, seed 20260802, nlist 2048 or the
largest valid lower value, nprobe 32, training sample at most 131,072 blocks,
one nearest parent. The installed official Faiss Python binding is 1.14.2, MIT,
and encoder-only; its native module SHA-256 is frozen in the experiment contract.

## Arm C: official learned/shared-context implementation

The intended candidate is official ROMP lossless mode or a faithful official
implementation of the CVPR 2022 learned exact-JPEG model. It must provide a
fixed revision, model/table identity, exact decoder, complete archive bytes,
and explicit commercial-use permission for code and model weights.

ROMP HEAD `dbc2616a841debfa1df99b30ab66cb200345e974` currently has no LICENSE
file, and the CVPR paper page states author copyright but exposes no licensed
production implementation. Therefore C is `blocked-license` unless stronger
primary evidence is found. A blocked C is a completed gate result, not a
compression failure and not permission to reimplement the paper ad hoc.

## Hard gates

- Source JPEG hashes unchanged.
- All 25 restored lengths, bytes, and SHA-256 values identical.
- Group random read decodes at most eight JPEGs.
- Parent references point only to earlier frames/blocks in the same group.
- Corrupt manifest, map, residual, or archive fails closed.
- Complete persisted size includes every model/table/sidecar byte.
- Host winners remain research-only pending physical-iPhone validation.

## Mandatory admission funnel for later candidates

The full A/B run showed that predictor-distance improvements can lose after
JPEG coefficient expansion and side information are counted. Every later
cross-photo candidate SHALL therefore start with the smallest meaningful
complete archive: two consecutive JPEGs consisting of one exact-JXL root, one
predicted child, all side information, the manifest, and corruption protection.
It advances only when this complete two-photo archive is strictly smaller than
the two-photo JXL baseline while passing every exactness gate.

Only a passing two-photo candidate may run one complete eight-photo group. Only
a passing eight-photo group may run the approximately-100-MiB workload. A
candidate stops permanently at the first size-gate failure; theoretical bounds,
coverage, coefficient distance, or payload-only size cannot promote it.
