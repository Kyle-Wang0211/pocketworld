## ADDED Requirements

### Requirement: Every committed active frame has a durable SfM queue item
The system SHALL create a replayable disk-backed SfM queue item for every
photo-committed, non-deleted job before offering it to a worker.  Worker
subscription timing SHALL NOT change the queued ID set.

#### Scenario: Worker starts after the first photo commits
- **WHEN** one or more jobs commit before the live reconstruction worker or listener is ready
- **THEN** the worker discovers and ingests those jobs from the durable queue in capture order

#### Scenario: Frame-exact gray extraction is unavailable
- **WHEN** native cannot produce the required SfM input for an otherwise committed photo
- **THEN** the job remains blocking or uses a deterministic, recorded regeneration path and is never marked queued or ingested without valid input

### Requirement: Queue entries survive all consumption failures
The system SHALL retain an item until successful native ingestion and persisted
job-to-image mapping.  A write, read, decode, worker, or native error SHALL NOT
remove the item or its recovery input.

#### Scenario: Queue file cannot be read
- **WHEN** the consumer cannot read or verify the queue head
- **THEN** it freezes that job as an explicit failure, preserves the item, and prevents finalization from passing it

#### Scenario: Native add-frame returns non-OK
- **WHEN** native ingestion returns any result other than success
- **THEN** the item and metadata remain recoverable and the system does not count it ingested

### Requirement: Ambiguous database failure triggers clean replay
When a native error may have partially mutated the reconstruction database, the
system SHALL treat that database as tainted and SHALL rebuild a new database from
the immutable active queue rather than blindly retrying the same frame in place.

#### Scenario: Failure occurs after partial database writes
- **WHEN** native reports an internal or unknown error after ingestion began
- **THEN** the system retains all queue inputs and starts or schedules a clean ordered replay before any completion claim

### Requirement: Thermal control never changes the capture denominator
Thermal policy SHALL affect only background reconstruction consumption.  It MAY
reduce in-flight work, cool down, or pause, but SHALL NOT reject an accepted
shutter, delete a queue item, lower image resolution, or skip a frame.

#### Scenario: Device enters serious thermal state
- **WHEN** the platform reports serious heat while the user continues capturing
- **THEN** accepted frames continue to commit to disk and background SfM may pace or pause without changing their order or expected registration set

#### Scenario: Device enters critical state or Metal fails
- **WHEN** thermal state is critical or a command-buffer failure is observed
- **THEN** the consumer preserves the full queue, enters an explicit paused/recovery state, and resumes or rebuilds without a silent loss

### Requirement: Registration completion uses exact set equality
The system SHALL define the expected registration set as all accepted,
photo-committed jobs not explicitly user-deleted.  It SHALL declare completion
only when the committed, queued, ingested, and final registered job-ID sets are
identical to that expected set.

#### Scenario: Final output omits one frame
- **WHEN** final reconstruction registers all but one expected job
- **THEN** registration is reported below 100%, the exact missing ID is retained, and the capture remains blocked/retryable

#### Scenario: All active frames register
- **WHEN** every expected job has a persisted native image mapping and appears in final registered output
- **THEN** the system reports 100% registration with the exact matching ID sets and may complete the reconstruction

### Requirement: Thermal and closure evidence is persisted
The system SHALL retain effective configuration, job-state events, queue depth,
memory footprint, thermal state, GPU result codes, timings, active/registered ID
sets, and artifact hashes needed to reproduce the qualification result.

#### Scenario: Physical-device qualification completes
- **WHEN** an iPhone 14 Pro test run reaches a terminal result
- **THEN** its evidence bundle identifies the app/code revision and contains sufficient data to verify every acceptance and thermal gate without relying on chat claims
