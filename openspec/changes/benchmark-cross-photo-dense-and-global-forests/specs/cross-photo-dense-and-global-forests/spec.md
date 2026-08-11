## ADDED Requirements

### Requirement: Every performance arm uses the same complete photo input

The benchmark SHALL use all 25 ordered JPEGs and SHALL NOT stop a performance
arm early because it misses a compression-ratio target.

#### Scenario: An arm is not smaller than JXL

- **WHEN** a performance arm remains exact but exceeds the complete JXL baseline
- **THEN** it SHALL finish all 25 photos and record the complete size
- **AND** it SHALL not replace the existing photo research baseline.

### Requirement: Every persisted byte is counted

Complete archive size SHALL include roots, headers, manifests, models, flow
grids, selectors, parent maps, residuals, and entropy-coded payloads.

#### Scenario: A predictor needs metadata

- **WHEN** decoding requires a flow vector, selector, parent ID, table, or model
- **THEN** that byte SHALL be inside the measured archive.

### Requirement: Exact JPEG restoration is non-negotiable

Every decoded JPEG SHALL match its source length, bytes, and SHA-256 value.

#### Scenario: One JPEG differs

- **WHEN** any reconstructed JPEG differs by one byte
- **THEN** the whole arm SHALL be rejected regardless of archive size.

### Requirement: Arm A uses bounded dense-flow prediction

Arm A SHALL store a compact flow grid and local selector sufficient to derive
every predicted parent DCT block, while keeping each group at most eight frames.

#### Scenario: A local prediction is out of range

- **WHEN** no 5x5-neighborhood candidate lies inside the parent component
- **THEN** the block SHALL be stored literally and decoded exactly.

### Requirement: Arm B uses earlier global block parents

Arm B SHALL select only blocks from earlier frames in the same group and SHALL
store every content-dependent parent reference.

#### Scenario: A parent map is decoded

- **WHEN** the decoder reads a non-root block parent
- **THEN** the parent frame SHALL already be decoded
- **AND** an out-of-range or forward reference SHALL fail closed.

### Requirement: Arm C must pass commercial-use and reproducibility gates

Arm C SHALL NOT execute or become a candidate without explicit code and model
permission, a fixed revision, and a runnable exact decoder.

#### Scenario: Official code has no license

- **WHEN** the official repository contains no license grant
- **THEN** C SHALL be recorded as `blocked-license`
- **AND** the absence of a size result SHALL not be described as algorithmic
  failure.

### Requirement: Host results do not authorize production

A host winner MAY become the photo research baseline but SHALL keep production
promotion false until physical-iPhone validation passes.

#### Scenario: A host arm wins

- **WHEN** A or B is exact and strictly smaller than the current baseline
- **THEN** it SHALL be labelled research-only
- **AND** no production or phone installation command SHALL run.

### Requirement: Later candidates use complete micro-to-full admission

Every later cross-photo candidate SHALL first benchmark a complete two-photo
archive and SHALL NOT advance unless it is strictly smaller than the equivalent
complete exact-JXL baseline while passing every exactness and corruption gate.

#### Scenario: Two-photo candidate does not win

- **WHEN** the complete root, child, side information, manifest, and protection
  bytes are not strictly smaller than the two-photo JXL baseline
- **THEN** the candidate SHALL stop without an eight-photo or 100-MiB run.

#### Scenario: Candidate advances through every gate

- **WHEN** the two-photo complete archive is strictly smaller and exact
- **THEN** one eight-photo complete group MAY run
- **AND WHEN** that group is also strictly smaller and exact
- **THEN** the approximately-100-MiB full benchmark MAY run.
