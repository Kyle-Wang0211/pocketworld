## ADDED Requirements

### Requirement: The benchmark isolates parent-coverage structure

The benchmark SHALL use the same immutable SQLite input, common container, and
pinned ZPAQ 7.15 method 5 backend for both arms. Arm A SHALL use the existing
verified-track parent forest. Arm B SHALL change only the descriptor parent
forest and the metadata required to decode it.

#### Scenario: Parent metadata is counted

- **WHEN** arm B chooses content-dependent descriptor parents
- **THEN** every required parent identifier SHALL be stored in the compressed
  container
- **AND** the reported B archive size SHALL include that metadata.

### Requirement: The similarity forest is acyclic and full-coverage

Every non-root descriptor chosen by arm B SHALL reference a strictly earlier
global descriptor ordinal. After the initial configured root block, every
descriptor SHALL have one parent unless the search index reports no candidate,
which SHALL fail the experiment rather than silently changing the policy.

#### Scenario: A forest is decoded

- **WHEN** the sidecar is decoded
- **THEN** its node count SHALL equal the descriptor count
- **AND** every non-root parent SHALL be in range and earlier than its child.

### Requirement: Exact restoration is mandatory

The benchmark SHALL preserve every SQLite byte. It SHALL reject an arm unless
the source remains unchanged and the restored database has the original length,
identical bytes, identical SHA-256, and `PRAGMA integrity_check = ok`.

#### Scenario: Arm B passes

- **WHEN** arm B completes compression and decompression
- **THEN** the parent sidecar SHALL be decoded
- **AND** modulo-256 residuals SHALL be inverted in topological order
- **AND** all exactness gates SHALL pass before size is compared.

### Requirement: Host evidence cannot promote production

The result SHALL be labelled host research evidence. A smaller arm B MAY become
the same-scope research baseline, but SHALL NOT be integrated into the app or
selected for production without a later physical-iPhone production-pipeline
validation.

#### Scenario: Host arm B is smaller

- **WHEN** arm B is strictly smaller and every host exactness gate passes
- **THEN** it MAY be recorded as the local research baseline
- **AND** `production_promoted` SHALL remain false until physical-iPhone
  production-pipeline validation passes.
