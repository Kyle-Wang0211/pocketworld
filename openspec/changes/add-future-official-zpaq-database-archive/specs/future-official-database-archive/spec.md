## ADDED Requirements

### Requirement: Official future-only database eligibility

The system SHALL archive `official_sfm_live.db` only when a compatible database
policy marker was written while a new official capture directory was created.
The system MUST NOT infer eligibility from the photo-archive marker, timestamps,
directory names, completeness, or existing files.

#### Scenario: New official capture

- **WHEN** an archive-capable build creates a new official capture directory
- **THEN** it writes the compatible database policy before publishing that directory

#### Scenario: Historical official capture already has a photo marker

- **WHEN** startup discovers an official capture with a photo policy but no database policy
- **THEN** photo work may continue but every database file remains unchanged

#### Scenario: Self-developed or malformed candidate

- **WHEN** data is under `captures/` or the database marker is missing, malformed, or incompatible
- **THEN** no database archive, manifest, deletion, or restore file is created

### Requirement: Cold SQLite lifecycle gate

The system SHALL start database archive work only after non-empty official final
PLY and metadata exist, reconstruction has released the project, the native
codec is supported, and no SQLite WAL, SHM, or journal sidecar exists.

#### Scenario: SQLite is still live

- **WHEN** any `official_sfm_live.db-wal`, `official_sfm_live.db-shm`, or `official_sfm_live.db-journal` sidecar exists
- **THEN** the system retains the database and postpones archival

#### Scenario: Foreground activity starts

- **WHEN** official capture or reconstruction activity begins during database compression or verification
- **THEN** the system requests cooperative cancellation, retains the raw database, and retries only after a later cold opportunity

#### Scenario: Eligible project after restart

- **WHEN** startup discovers a marked project with durable final artifacts, no in-process owner, and a clean closed database
- **THEN** the sequential official cold coordinator resumes idempotent database reconciliation

### Requirement: Byte-exact ZPAQ method-5 transaction

For each eligible database, the system SHALL use pinned ZPAQ 7.15 method 5 and
MUST decompress the candidate archive before publication. The decompressed file
MUST match the source length, SHA-256, and every byte.

#### Scenario: Exact smaller archive

- **WHEN** compression and decompression succeed, restored bytes match exactly, and the archive is smaller
- **THEN** the system atomically commits the archive and verified manifest before deleting the database

#### Scenario: Mismatch, codec failure, or interruption

- **WHEN** any codec operation fails, cancellation is requested, or restored data differs
- **THEN** temporary files are removed and the original database remains unchanged

#### Scenario: Archive is not smaller

- **WHEN** a byte-exact archive is equal to or larger than the database
- **THEN** the system discards the archive and retains the database

### Requirement: Crash-safe database state

The system SHALL preserve at least one complete recoverable representation
across every commit boundary and SHALL remove the raw database last.

#### Scenario: Crash before manifest commit

- **WHEN** the process stops with only temporary output or a newly published archive
- **THEN** the raw database remains and restart may safely recompress it

#### Scenario: Crash after manifest commit

- **WHEN** the process stops after the verified manifest is durable but before raw deletion
- **THEN** restart revalidates archive and source identities before completing deletion

#### Scenario: Restored database changed

- **WHEN** a retained archive/manifest describes an older database and recovery has changed the raw database SHA-256
- **THEN** the system verifies and commits a new archive before deleting the changed raw database

### Requirement: Verified recovery materialization

The official recovery path SHALL treat an existing raw database as authoritative.
When only an archive exists, it SHALL validate policy, manifest, archive
length/SHA-256, native identity, restored length/SHA-256, and atomic publication
before passing the path to SQLite.

#### Scenario: Historical raw database

- **WHEN** an official project has a raw database but no database policy
- **THEN** existing recovery continues to use that raw database

#### Scenario: Valid archive-only project

- **WHEN** a marked project has no raw database and its committed archive passes all checks
- **THEN** recovery publishes the exact raw database, retains the archive snapshot, and starts official SfM

#### Scenario: Corrupt archive-only project

- **WHEN** the archive or restored bytes fail any declared length or SHA-256 check
- **THEN** the project is not reported as recoverable and SQLite is never opened on those bytes

### Requirement: Portable pinned native codec

The implementation SHALL use the exact official libzpaq 7.15 source revision
selected by the physical-iPhone benchmark behind a platform-neutral Dart
contract. It MUST NOT substitute an Apple-only compression format or API.

#### Scenario: iOS production build

- **WHEN** Runner is built
- **THEN** it compiles the pinned portable source, retains the required C ABI symbols, embeds an explicit build marker, and ships the upstream license

#### Scenario: Unsupported platform

- **WHEN** the Dart codec cannot load the exact native version and revision
- **THEN** it reports unsupported and all source databases remain unchanged
