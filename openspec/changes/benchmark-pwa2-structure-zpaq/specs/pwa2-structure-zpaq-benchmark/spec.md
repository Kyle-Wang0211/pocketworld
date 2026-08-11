## ADDED Requirements

### Requirement: Complete logical preservation

The PWA2 benchmark SHALL preserve every table, column, SQLite storage class,
value byte, BLOB byte, row count, and primary-key order from the supported
COLMAP database while leaving the source file unchanged.

#### Scenario: Complete logical round trip

- **WHEN** a supported database is packed, compressed, decompressed, and read
- **THEN** its canonical logical SHA-256 SHALL equal the source logical SHA-256
- **AND** every table cell and ordered row SHALL compare equal
- **AND** a materialized database SHALL pass `PRAGMA integrity_check`

### Requirement: Structure-only B arm

The first PWA2 arm SHALL separate descriptor roots, track residuals, unmatched
literals, keypoint columns, and match columns while using only the pinned ZPAQ
7.15 method 5 backend.

#### Scenario: No codec-variable contamination

- **WHEN** Arm B is measured
- **THEN** it SHALL NOT use OpenZL, Pcodec, Blosc2, numeric truncation,
  quantization, learned models, or any lossy filter

### Requirement: Bounded deterministic members

PWA2 SHALL persist independently verifiable bounded members with stable IDs,
record ranges, lengths, hashes, codec identity, and offsets.

#### Scenario: Random descriptor read

- **WHEN** the reader requests the first, middle, or last descriptor
- **THEN** it SHALL reconstruct the exact 128 bytes without decompressing the
  complete database archive

#### Scenario: Corrupt member

- **WHEN** a member hash, bound, dependency, or length is invalid
- **THEN** the reader SHALL fail closed without returning partial data

### Requirement: Complete measured size gate

The benchmark SHALL include schema, metadata, topology, order maps, index,
checksums, and compressed payloads in the Arm B byte count.

#### Scenario: Host candidate misses the gate

- **WHEN** valid Arm B bytes exceed 111,961,726
- **THEN** no phone bundle SHALL be built or installed
- **AND** the result SHALL identify structure coverage and the next parent or
  track-coverage hypothesis

#### Scenario: Host candidate passes the gate

- **WHEN** valid Arm B bytes are at most 111,961,726
- **THEN** it MAY proceed to a separate physical-iPhone benchmark task
- **AND** production behavior SHALL remain unchanged
