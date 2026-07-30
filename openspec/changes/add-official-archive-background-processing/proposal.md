## Why

The official JPEG XL and ZPAQ cold archive coordinator currently runs only
inside the active Flutter process. Its marker-based discovery is crash-safe,
but iOS may suspend the Dart isolate after the app enters the background, so a
large project is not guaranteed another execution opportunity until the user
opens the app again. The production archive also lacks a durable, queryable
record showing when discovery ran, which capture was processed, why work
paused, and whether more work remains.

All high-resolution photographs remain authoritative project inputs. Background
execution must not weaken the existing byte-exact JPEG reconstruction,
SHA-256, byte comparison, manifest-before-delete, or future-only marker gates.

## What Changes

- Register an iOS `BGProcessingTask` dedicated to official cold archive
  maintenance.
- Treat compatible creation-time markers plus unfinished source/manifest state
  as the durable queue; do not introduce a second mutable queue database.
- Schedule a system wake-up as soon as final official artifacts enqueue cold
  work, while continuing to process immediately whenever the app is active.
- On a system background launch, ask the existing Dart coordinator to discover
  and drain eligible work.
- On system expiration or foreground capture/reconstruction, cooperatively
  interrupt at existing safe transaction boundaries and reschedule remaining
  work.
- Persist an append-only JSONL audit journal and an atomic latest-status JSON
  snapshot under Documents.
- Preserve every high-resolution photo as either its exact original JPEG or a
  verified JPEG XL archive capable of reconstructing the exact original bytes.

## Capabilities

### New Capabilities

- `official-archive-background-processing`: durable marker-derived work,
  iOS background scheduling, cooperative interruption, retry, and queryable
  audit state for the official cold archive coordinator.

### Modified Capabilities

- `future-photo-archive`: background scheduling does not change full photo
  membership or byte-exact transaction semantics.
- `future-official-database-archive`: interrupted ZPAQ work remains retryable
  through the same system wake-up path.

## Impact

- New Dart background scheduler/controller and audit store.
- Existing official cold coordinator gains scheduling, interruption, retry,
  and audit hooks.
- New Swift `BGProcessingTask` bridge, Runner registration, permitted task
  identifier, and Xcode source entry.
- No migration of historical projects, no change under `captures/`, no photo
  deletion outside an existing verified transaction, and no native archive
  (`.a`) rebuild.
