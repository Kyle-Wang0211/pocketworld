## ADDED Requirements

### Requirement: collection-wide parent selection

The experiment SHALL build a deterministic graph from all 28 verified
relationships among the frozen first eight photos and SHALL NOT use candidate
compressed size when selecting the root or parent edges.

#### Scenario: graph selection

- **WHEN** the frozen relationship data is loaded
- **THEN** all eight nodes and 28 edges are present
- **AND** one deterministic seven-edge rooted tree is produced

### Requirement: exact hybrid prediction

Every non-root JPEG SHALL be represented by deterministic prediction state and
exact signed coefficient residuals sufficient to restore every original JPEG
byte and SHA-256 value.

#### Scenario: exact restoration

- **WHEN** the candidate archive is decoded
- **THEN** all eight restored JPEG byte sequences equal their frozen sources
- **AND** all eight SHA-256 values match

### Requirement: complete candidate accounting

The measured candidate size SHALL include the root payload, residual streams,
graph, models, modes, motion deltas, headers, indexes, manifests, and checksums.

#### Scenario: compare with saved reference

- **WHEN** the one candidate run completes
- **THEN** its complete persisted bytes are compared with 18,453,828
- **AND** the JXL reference encoder was not executed
- **AND** 15,618,497 is reported only as a paper-derived target

### Requirement: one real execution

Synthetic tests SHALL precede exactly one encoding of the frozen eight-photo
candidate. Production and phone execution SHALL remain out of scope.

#### Scenario: stop control

- **WHEN** the real candidate result is recorded
- **THEN** no automatic repeat, baseline rerun, full-project run, or phone run
  occurs

