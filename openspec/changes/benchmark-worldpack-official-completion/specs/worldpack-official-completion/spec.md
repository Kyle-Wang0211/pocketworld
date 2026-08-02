## ADDED Requirements

### Requirement: Official workflows are exercised beyond prior subsets

The experiment SHALL run OpenZL 0.2.0 with a typed structure parser, completed ACE training, and completed clustering plus ACE training; official ALP on homogeneous real floating-point columns; and official WebGraph Rust on real graph streams.

#### Scenario: A prior subset is not mislabeled as complete

- **WHEN** an official family has untested parser, trainer, clustering, graph, or fallback behavior required by the registered workflow
- **THEN** the result SHALL remain `partial`
- **AND** it SHALL NOT declare the family defeated.

### Requirement: Every candidate is strictly reversible

Each candidate SHALL restore the original ordered bytes, length and SHA-256 and SHALL reject deterministic corruption before its size can be ranked.

#### Scenario: Floating-point data round trips

- **WHEN** ALP decodes keypoint or pose columns
- **THEN** every IEEE float bit pattern SHALL match the source
- **AND** no float conversion, truncation, normalization or NaN canonicalization is permitted.

#### Scenario: Graph data round trips

- **WHEN** WebGraph or Elias–Fano decodes graph members
- **THEN** node identities, edge direction, edge multiplicity and original ordered adjacency SHALL be recoverable exactly.

### Requirement: Complete persisted size is the only size metric

The measured size SHALL include codec frames, trained models, tables, mappings, sidecars, indexes, manifests, checksums and the container envelope required by an independent decoder.

#### Scenario: A trained compressor is ranked

- **WHEN** a model or serialized compressor is required during decode
- **THEN** all its persisted bytes SHALL be included in the candidate size.

### Requirement: Expansion follows registered gates

Each backend SHALL begin on the smallest complete typed unit. A mode MAY expand only after strict exactness passes and it is strictly smaller than the same-input current baseline.

#### Scenario: A mode loses the minimum unit

- **WHEN** a valid exact candidate is equal to or larger than its baseline
- **THEN** that exact mode SHALL stop before a larger run
- **AND** the result SHALL reject only that mode and input.

### Requirement: WorldPack covers a complete frozen project

WorldPack SHALL persist all authoritative photos, SQLite data, graph data, PLY, metadata, codec dependencies and indexes from the frozen capture, using the smallest eligible exact codec per member.

#### Scenario: Complete project restoration

- **WHEN** the complete WorldPack is decoded
- **THEN** every original logical file SHALL match its registered length and SHA-256
- **AND** SQLite SHALL pass `PRAGMA integrity_check`
- **AND** random chunk reads SHALL not require decoding unrelated members.

### Requirement: The experiment cannot affect production

The change SHALL NOT modify production archive behavior, access the production phone, build or install the App, or promote a host result to production.

#### Scenario: A host candidate wins

- **WHEN** any minimum, expanded member, or complete WorldPack host result is smaller than its baseline
- **THEN** the result SHALL remain research-only
- **AND** no production source, bundle, phone container, or installation state SHALL change.
