## ADDED Requirements

### Requirement: Every shutter attempt has immutable identity and explicit acceptance
While a manual capture is active, the system SHALL assign every shutter attempt
an immutable `capture_job_id` before asynchronous work and SHALL count the job as
accepted only after the platform confirms ownership of the exact camera
snapshot.  A failed attempt SHALL remain visible and SHALL NOT silently vanish.

#### Scenario: Snapshot reservation succeeds
- **WHEN** the user taps the enabled shutter and native selects the matching camera snapshot
- **THEN** the system returns a ticket without waiting for JPEG encoding or reconstruction and records the job as accepted

#### Scenario: Snapshot reservation fails
- **WHEN** the user taps the enabled shutter but native cannot reserve a valid snapshot
- **THEN** the attempted job remains an explicit blocking failure and is not reported as a saved photo

### Requirement: Frame lifecycle is monotonic and auditable
The system SHALL record separate, monotonic states for attempted, accepted,
photo committed, SfM queued, SfM ingested, registered, and user deleted.  It
SHALL reject a state transition that skips required evidence or changes identity.

#### Scenario: Completion arrives out of order
- **WHEN** several accepted jobs complete native work in a different order from their taps
- **THEN** every result updates only its immutable job ID and no cell-slot replacement can redirect it to another frame

#### Scenario: Duplicate completion is received
- **WHEN** recovery or a platform callback reports the same valid transition twice
- **THEN** the ledger treats it idempotently and preserves exactly one lifecycle for the job

### Requirement: Photo publication is recoverable and fail closed
The system SHALL publish each JPEG, sidecar, frame-exact SfM input, and commit
record through private staging with unique no-overwrite final paths.  A job SHALL
be photo-committed only after all required bytes and hashes are verified.

#### Scenario: Process stops between file writes
- **WHEN** execution stops after one or more staged/final files exist but before the commit record is durable
- **THEN** restart recovery either completes the same verified job or exposes it as pending/failed and never calls the partial pair committed

#### Scenario: Final path already exists
- **WHEN** publication encounters an existing final path for another identity
- **THEN** the system preserves the existing file, blocks the new job, and never overwrites or aliases either identity

### Requirement: Raw capture ownership is append-only until user deletion
Coverage ranking and curation SHALL NOT delete, hide from the raw album, or
remove from the raw manifest any committed active job.  The system SHALL NOT
automatically prune raw JPEGs or sidecars.

#### Scenario: Coverage ring replaces a sample
- **WHEN** a cell is full and a new accepted frame replaces its coverage sample
- **THEN** the older capture remains in the append-only ledger, raw album, raw manifest, and active registration denominator

#### Scenario: Curation selects a subset
- **WHEN** a downstream view or quality report selects preferred frames
- **THEN** the selection is stored as metadata and all unselected raw captures remain intact

### Requirement: Finish cannot cross an unresolved frame
Normal finish SHALL stop new attempts and SHALL wait without timeout-based
continuation for every in-progress reservation and writer.  It SHALL compare
exact job-ID sets before declaring the capture complete.

#### Scenario: Finish occurs during encoding
- **WHEN** the user taps Finish while one or more accepted jobs are still encoding or publishing
- **THEN** the UI remains pending and no manifest finalization, camera teardown that invalidates a reservation, or reconstruction completion bypasses those jobs

#### Scenario: A job has failed
- **WHEN** any active attempted or accepted job is in a blocking failure state
- **THEN** the capture remains a recoverable draft with the exact job ID and error and is not labeled complete

### Requirement: Only explicit user deletion removes a capture
The system SHALL require an explicit user action to tombstone and remove a
single frame or whole capture.  It SHALL quiesce all relevant writers before
deleting bytes and SHALL invalidate derived reconstruction containing the job.

#### Scenario: User deletes an ingested frame
- **WHEN** the user confirms deletion of a job already present in the SfM database
- **THEN** the system records a tombstone, removes the raw bytes only after writers quiesce, and rebuilds derived reconstruction from the remaining active jobs before delivery

#### Scenario: User discards while a writer is pending
- **WHEN** the user explicitly discards the take while native publication is still running
- **THEN** deletion waits for a cancellation/quiescence handshake and no later callback can recreate the deleted directory

### Requirement: Ordinary navigation is not deletion
Leaving, backgrounding, disposing UI state, or losing a reconstruction worker
SHALL preserve the capture ledger, staged data, and durable queue unless the user
explicitly chose deletion.

#### Scenario: Capture page is backgrounded
- **WHEN** the app moves to background with pending or committed jobs
- **THEN** the jobs remain recoverable and no dispose path interprets the lifecycle event as discard
