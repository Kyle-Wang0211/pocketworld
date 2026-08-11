## Context

`PhotoArchiveCoordinator` already reconstructs pending work by scanning
`captures_official/` for compatible photo/database policy markers. Each
transaction independently proves final-artifact readiness, codec identity,
archive size, restored length, SHA-256, and byte equality. A manifest is
committed before the original file is removed, so process death cannot remove
the last recoverable representation.

The missing layer is execution opportunity. The startup scan is attached to
the first Flutter frame, and final PLY persistence enqueues work in memory, but
neither path owns an iOS background-processing grant. The existing
`OfficialReconUmbrella` is a user-triggered iOS 26 continued-processing task
for SfM and must remain separate from automatic cold maintenance.

## Goals / Non-Goals

**Goals:**

- Continue immediate foreground processing.
- Persist a system wake-up request after final artifacts enqueue work.
- Re-enter the same Dart coordinator from an iOS background launch.
- Stop safely on expiration and retry on a later system opportunity.
- Expose durable audit history and latest status without making audit writes a
  prerequisite for source safety.
- Retain every authoritative high-resolution photo byte-exactly.

**Non-Goals:**

- Selecting, deleting, downsampling, or lossy-transcoding source photos.
- Changing JPEG XL effort 10, ZPAQ 7.15 method 5, native codec revisions, or
  archive formats.
- Retrofitting historical unmarked projects.
- Running automatic cold maintenance through the user-visible reconstruction
  Dynamic Island task.
- Claiming that iOS guarantees a specific start time or uninterrupted runtime.

## Decisions

### Marker-derived state is the durable queue

Compatible creation-time policy markers identify allowed work. A raw source
without a committed manifest, or a committed manifest with a still-present
source, identifies unfinished reconciliation. This state survives process
death and container-preserving app updates, and it is already validated by the
transaction layer.

No separate queue database is introduced. `BGTaskScheduler` is a wake-up hint,
not a second authority. Every background entry rescans disk before acting.

### Dart retains orchestration ownership

Swift owns only iOS scheduling and task lifetime. A bidirectional
`MethodChannel` asks Dart to run discovery and reports expiration. Dart retains
all eligibility, ordering, transaction, hashing, deletion, and retry policy.
Other platforms can provide their own scheduler without changing stored data.

### Interruption is generation-based and cooperative

Each coordinator pump captures an interruption generation. System expiration
or acquisition of any production-pipeline lease closes the cold-work gate and
requests native JPEG XL and ZPAQ cancellation. Both portable codecs compare an
operation generation at native work checkpoints. A cancelled transaction
removes only uncommitted temporary output, retains its authoritative source, and
is requeued. Work restarts only after the final capture/reconstruction lease
closes. Intentionally non-smaller skips are not requeued in the same execution
opportunity, avoiding a tight retry loop.

### Audit has history and latest state

`Documents/official_archive_audit.jsonl` stores append-only schema-versioned
events. `Documents/official_archive_status.json` atomically stores the latest
global and per-capture states. Events cover enqueue, scan start/completion,
capture start/completion, interruption, retry requirement, and queue drain.

Audit failure is recorded to the release-visible device log when possible but
never authorizes deletion and never changes the transaction result. Per-file
photo/database manifests remain the authoritative cryptographic proof.

### iOS uses a dedicated BGProcessingTask

The identifier is `com.kyle.PocketWorld.official.archive`. It requires neither
network nor external power. Runner registers it before application launch
finishes. A pending native task waits until Dart installs its method handler,
then invokes `runColdArchive`. Its expiration handler invokes
`cancelColdArchive`; completion reports whether marker-derived work remains and
resubmits when needed.

The system may defer or interrupt work. Correctness therefore depends only on
the existing idempotent disk state, never on uninterrupted execution.

## Safety Invariants

1. Every high-resolution bundle member remains an original JPEG or a verified
   JXL that reconstructs the exact JPEG bytes.
2. No source deletion occurs before archive publication, manifest commit,
   restored length/SHA-256, and full byte comparison.
3. Background expiration preserves the source and removes uncommitted
   temporary output.
4. Historical captures without compatible markers remain untouched.
5. Audit and scheduling failures fail closed and leave source data intact.
6. The production iPhone is updated only in place after a verified Documents
   and Library backup.
