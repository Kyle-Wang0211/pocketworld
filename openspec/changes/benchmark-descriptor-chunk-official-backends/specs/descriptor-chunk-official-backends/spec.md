## ADDED Requirements

### Requirement: The experiment uses one complete minimum chunk

The benchmark SHALL process exactly 16,384 descriptors with 128 bytes per
descriptor. The first 8,192 descriptors SHALL be roots and the remaining 8,192
SHALL have valid strictly earlier parents produced by the frozen
`similarity_forest_v1` implementation.

#### Scenario: Input scope is enforced

- **WHEN** the benchmark begins
- **THEN** the raw descriptor bytes SHALL equal 2,097,152
- **AND** it SHALL reject a different count, dimension, source size, or source
  SHA-256.

### Requirement: Complete persisted bytes are compared

Each reported candidate size SHALL include the common archive envelope, the
complete codec frame, and every parent-sidecar byte required to decode the
chunk. It SHALL not count a payload-only projection as a result.

#### Scenario: A trained codec is measured

- **WHEN** OpenZL ACE emits a self-contained frame
- **THEN** decode SHALL succeed without the training-time compressor file
- **AND** the full self-contained frame SHALL be counted.

### Requirement: Only official reversible transforms are eligible

The new arms SHALL use the OpenZL 0.2.0 official `serial` raw-byte profile with
ACE and clustering disabled, and C-Blosc2 3.3.0 B2ND with SHUFFLE plus the
fixed BYTEDELTA filter ID 35 and Zstd. TRUNC_PREC, INT_TRUNC, NDMEAN, or any
other lossy transform SHALL be forbidden.

#### Scenario: B2ND fixed-width descriptors are decoded

- **WHEN** the logical two-dimensional array is represented as 16,384 fixed
  128-byte records so SHUFFLE and BYTEDELTA operate on descriptor lanes
- **AND** its cframe is deserialized and copied back to a contiguous buffer
- **THEN** all transformed descriptor bytes SHALL be identical.

### Requirement: Exactness precedes size

An arm SHALL be excluded unless decoded transformed bytes, decoded parent
metadata, inverse-reconstructed original bytes, and SHA-256 all match exactly.
A deterministic one-byte corruption SHALL also be rejected by codec validation
or the common SHA-256 gate.

#### Scenario: An exact arm completes

- **WHEN** all exactness and corruption gates pass
- **THEN** and only then MAY its complete persisted size enter the ranking.

### Requirement: The task cannot affect production

The task SHALL NOT edit production code, build or install the app, access the
phone, or run a 100 MB/full-database benchmark. A micro winner SHALL remain
host research evidence only.
