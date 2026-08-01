## ADDED Requirements

### Requirement: Independently verified dual candidates

For every eligible future official SQLite database, the archiver SHALL attempt
`raw_v1` and, when supported, `track_delta_v1`. It SHALL decode each candidate
through its complete inverse path and require source length, SHA-256, and byte
equality before the candidate becomes selectable.

#### Scenario: Track candidate is smaller and exact

- **WHEN** both candidates exactly restore the source and `track_delta_v1` is
  smaller
- **THEN** only the track candidate SHALL be published
- **AND** the manifest SHALL record `track_delta_v1`

#### Scenario: Track candidate fails or is not smaller

- **WHEN** track preprocessing, compression, inverse restoration, or exactness
  fails, or its verified archive is not smaller than raw
- **THEN** the verified raw candidate SHALL remain eligible
- **AND** the source database SHALL remain untouched until the selected
  candidate is committed

### Requirement: Versioned exact restoration

The resolver SHALL accept existing v1 manifests as `raw_v1` and new v2
manifests with an explicit preprocessing version. It SHALL never expose a
preprocessed SQLite database to consumers.

#### Scenario: Resolve track-delta archive

- **WHEN** a valid v2 manifest records `track_delta_v1`
- **THEN** the resolver SHALL ZPAQ-decode, inverse-transform, verify the original
  length and SHA-256, and atomically publish the exact original database

### Requirement: Source-last transaction and bounded temporaries

The archiver SHALL publish one archive and its manifest before deleting the
source. All unselected and intermediate candidate files SHALL be removed after
selection or interruption.

#### Scenario: Production work starts during candidate generation

- **WHEN** capture or reconstruction activity closes the continuation gate
- **THEN** native preprocessing and ZPAQ SHALL receive cancellation
- **AND** the transaction SHALL retain the source and remain retryable

### Requirement: Independent physical-iPhone admission

The implementation SHALL be exercised by a bundle with identifier
`com.kyle.PocketWorld.ArchiveBench` and an independent app data container. The
production bundle and its data SHALL not be installed, updated, or accessed by
this benchmark.

#### Scenario: Three-round device verification

- **WHEN** the immutable real database is run three times on the physical iPhone
- **THEN** every round SHALL report exact source recovery, SQLite integrity,
  deterministic archive sizes, the same selected preprocessing version, and no
  leaked candidate temporary files
