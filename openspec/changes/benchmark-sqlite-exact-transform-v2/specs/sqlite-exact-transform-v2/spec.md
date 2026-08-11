## ADDED Requirements

### Requirement: Page-preserving exact transform

The benchmark SHALL transform only mapped BLOB payload bytes in an isolated
SQLite copy and SHALL preserve every untargeted source byte.

#### Scenario: Complete v2 round trip

- **WHEN** a supported COLMAP database is transformed and inverse-transformed
- **THEN** the restored file SHALL equal the source in length, every byte and
  SHA-256
- **AND** `PRAGMA integrity_check` SHALL return `ok`
- **AND** the source SHALL remain unchanged

### Requirement: Versioned composition order

`exact_transform_v2` SHALL apply descriptor track delta before keypoint and
match transforms, and SHALL reverse the operations in the exact opposite order.

#### Scenario: Descriptor inverse uses original matches

- **WHEN** inverse transformation begins
- **THEN** two-view match indices SHALL be restored before descriptor track
  inverse processing
- **AND** transformed match indices SHALL never be used to reconstruct tracks

### Requirement: Deterministic fail-closed behavior

The transform SHALL produce the same transformed bytes for the same input and
SHALL reject incompatible schemas, dimensions, lengths, page mappings or
cancellation without publishing an output.

#### Scenario: Unsupported numeric BLOB

- **WHEN** rows, columns or BLOB length do not match the frozen table contract
- **THEN** the v2 candidate SHALL fail
- **AND** existing raw and track candidates SHALL remain unaffected

### Requirement: Benchmark-only admission gate

The host benchmark SHALL compare the exact v2 archive against the frozen
124,401,918-byte `track_delta_v1` archive and SHALL not modify production
selection behavior.

#### Scenario: Host candidate is not smaller

- **WHEN** the valid v2 archive is greater than or equal to 124,401,918 bytes
- **THEN** the experiment SHALL stop before building or installing a phone
  bundle

#### Scenario: Host candidate is smaller

- **WHEN** the valid v2 archive is strictly smaller than 124,401,918 bytes
- **THEN** one run MAY proceed in bundle
  `com.kyle.PocketWorld.ArchiveBench`
- **AND** the production bundle SHALL remain untouched
