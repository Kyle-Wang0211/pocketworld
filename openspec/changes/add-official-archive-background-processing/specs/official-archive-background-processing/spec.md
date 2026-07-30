## ADDED Requirements

### Requirement: Durable marker-derived cold queue

The system SHALL derive official cold archive work only from compatible
creation-time markers and current source/archive/manifest state. It MUST rescan
disk on every foreground, startup, or system-background entry.

#### Scenario: Final artifacts enqueue work

- **WHEN** a marked official capture commits non-empty final PLY and metadata
- **THEN** the coordinator immediately enqueues it in memory and requests a
  persistent iOS background-processing opportunity

#### Scenario: Process dies after enqueue

- **WHEN** the app process ends before cold work completes
- **THEN** the next disk discovery reconstructs the unfinished queue without
  relying on an in-memory or separately mutable queue record

#### Scenario: Historical project

- **WHEN** a project has no compatible creation-time archive marker
- **THEN** background discovery does not modify any photo, database, or manifest

### Requirement: iOS background maintenance

The system SHALL register a dedicated `BGProcessingTask` and SHALL route its
work through the existing Dart official archive coordinator.

#### Scenario: System grants background time

- **WHEN** iOS launches the permitted archive processing task
- **THEN** Dart rescans official captures and drains eligible work through the
  same byte-exact transactions used while the app is active

#### Scenario: Dart is not ready at native launch

- **WHEN** the native task handler fires before Dart installs its channel handler
- **THEN** native code retains the task reference and starts it only after Dart
  explicitly reports readiness

#### Scenario: System expiration

- **WHEN** iOS invokes the task expiration handler
- **THEN** Dart stops before the next JPEG, requests ZPAQ cancellation, retains
  every original whose transaction is not committed, and reports remaining work
  for a later scheduling opportunity

### Requirement: Full byte-exact photo retention

Background execution SHALL preserve every high-resolution filename in the
authoritative official photo bundle as an exact original JPEG representation.

#### Scenario: Smaller exact archive

- **WHEN** JPEG XL reconstructs the same length, SHA-256, and every source byte
- **THEN** the system may replace the JPEG with its committed JXL representation

#### Scenario: Mismatch, failure, interruption, or non-smaller output

- **WHEN** any exactness check fails, work is interrupted, or JXL is not smaller
- **THEN** the original JPEG remains and no lossy or selected-frame fallback is
  permitted

### Requirement: Queryable archive audit

The system SHALL persist schema-versioned archive audit history and an atomic
latest-status snapshot under the application Documents directory.

#### Scenario: Queue lifecycle

- **WHEN** work is enqueued, scanned, started, paused, retried, completed, or drained
- **THEN** the audit records the UTC timestamp, trigger, capture identifier when
  applicable, outcome, and whether work remains

#### Scenario: Audit storage failure

- **WHEN** the audit journal or status snapshot cannot be written
- **THEN** the archive transaction remains fail-closed and source deletion still
  depends exclusively on cryptographic and byte-equality proof

### Requirement: Background retries avoid tight loops

The system SHALL retry only failed or interrupted eligible work on a later
execution opportunity.

#### Scenario: Codec failure

- **WHEN** an eligible photo or database transaction fails
- **THEN** its capture remains marker-discoverable, the current pump stops, and a
  later background opportunity is requested

#### Scenario: Intentionally skipped candidate

- **WHEN** an exact archive is not smaller or a database still has live sidecars
- **THEN** the source remains and the coordinator does not spin continuously in
  the same execution opportunity
