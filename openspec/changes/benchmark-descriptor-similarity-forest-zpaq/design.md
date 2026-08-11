# Design: Full descriptor similarity forest + identical ZPAQ

## Frozen comparison

The immutable source is the 198,983,680-byte SQLite database with SHA-256
`0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0`.
Both arms use official libzpaq 7.15 method 5 at revision SHA-256
`e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418`.
The prior production-scope research baseline is 124,401,918 bytes, but the
primary clean comparison is the two arms produced by this experiment because
both include the same container header.

## Common container

The uncompressed benchmark container is:

1. a fixed versioned header;
2. the transformed SQLite file, whose length is unchanged;
3. a sidecar byte stream.

Arm A has an empty sidecar because the verified-track parent forest can be
reconstructed from unchanged `two_view_geometries`. Arm B stores every backward
parent distance as an unsigned varint. The sidecar is part of the same ZPAQ
input, so parent metadata can never be omitted from the size result.

## Arm B forest

Descriptors retain their global `(image_id, row)` order and all 128 `uint8`
values. Faiss `IndexIVFFlat` is encoder-only. It is trained with a deterministic
uniform sample and queried in ordinal blocks. A block is queried only against
descriptors already added to the index, so every chosen parent ordinal is
strictly smaller than its child ordinal and the result is a DAG/forest.

Frozen Faiss parameters:

- metric: squared L2 over 128 exact `uint8` values converted to `float32`;
- seed: `20260802`;
- coarse clusters (`nlist`): 2048;
- probed clusters (`nprobe`): 32;
- query block: 8192 descriptors;
- training sample: at most 131,072 uniformly spaced descriptors;
- nearest candidate count: 1.

The initial block remains literal. Every later descriptor receives the nearest
available earlier parent. This deliberately measures maximum prediction
coverage, not a hand-tuned parent rejection heuristic.

## Reversible residual

Forward transformation processes children in descending ordinal order and
stores `(child - parent) mod 256` independently in every byte lane. Inverse
transformation processes children in ascending ordinal order and restores
`(residual + restored_parent) mod 256`. No value is quantized or rounded.

## Acceptance and stopping rules

One complete run per arm is sufficient for this structural question; do not
start automatic repeat rounds. Stop immediately on any source mutation,
container error, malformed parent map, byte mismatch, SHA-256 mismatch, or
failed `PRAGMA integrity_check`.

Per the user's current research-baseline rule, B becomes the same-scope local
baseline if and only if its complete ZPAQ archive is strictly smaller than A
and every correctness gate passes. Host evidence cannot promote the algorithm
to production; a later physical-iPhone production-pipeline test is required.

## Dependency boundary

The benchmark uses the already installed Homebrew Faiss 1.14.0 library
(MIT-licensed, dylib SHA-256
`cbd11b958ff233d4cc1dc0fe010890b4677ef81c2e0a039ff4567d365946e473`).
Faiss is not linked into the app and is not required by the decoder.

