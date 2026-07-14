## Context

At baseline `1626543`, `CaptureSession.captureSinglePhoto()` calls
`DomeTargetPoints.forceAdmit()` and then awaits
`ARPoseProvider.saveCurrentFrame()`.  The iOS method does select a timestamped
`ARFrame` before dispatching to its serial JPEG queue, but the Flutter method
does not complete until JPEG, JSON sidecar, and optional SfM gray extraction are
finished.  Normal finish snapshots the current future list, waits at most eight
seconds, removes those futures even on timeout, and continues.  User discard has
the same timeout-shaped race with a still-running native writer.

There are additional denominator losses after the save.  A nil native gray is
treated as a successful photo with no SfM input; `SfmLiveRecon.offerFrame()` can
reject malformed input; a spool read error removes the queue entry; non-OK
`add_frame` results remove pending metadata; and finalization is gated by queue
emptiness rather than ID closure.  Separately, the coverage ring may evict an old
sample and `retainOnlyCuratedPhotos()` later deletes every non-curated JPEG and
sidecar automatically.  The album and bundle manifest use that curated ring,
not an append-only capture ledger.

The current native thermal K12→K6 switch is already enabled on iOS.  It reduces
candidate matching, but cap52 evidence shows that it did not prevent sustained-
heat GPU failures.  The background consumer therefore needs a durable pause and
recovery path; changing K alone is not a no-drop proof.

## Goals / Non-Goals

**Goals:**

- Make the shutter wait only for a small native snapshot-reservation
  acknowledgement, never for JPEG encoding or SfM.
- Give every tap accepted while recording a stable job ID and retain its state
  until it is registered or explicitly deleted by the user.
- Keep coverage/curation as ranking metadata without allowing it to own or
  delete the raw capture set.
- Make normal finish an ID-set closure gate with no timeout-based continuation.
- Keep SfM input durable across worker backlog, thermal pause, recoverable
  process failure, and a fresh-DB rebuild.
- Bound RAM independently of queue depth by spilling work to local disk and by
  allowing thermal policy to pause only the background consumer.
- Produce host-verifiable state-machine evidence tonight and defer all ARKit,
  Metal, thermal, jetsam, and final-registration acceptance to a physical
  iPhone 14 Pro run.

**Non-Goals:**

- Guarantee that an arbitrary blank or physically unregistrable image becomes
  geometrically registered.  Instead, such a frame remains an explicit blocker
  and the product must not call the reconstruction complete.
- Change reconstruction geometry, matcher thresholds, COLMAP/Ceres versions,
  or enable incremental global BA.
- Add Web capture or any cloud fallback.
- Automatically delete raw photos to control storage.  Storage pressure is a
  visible preflight/runtime error; it is not permission to shrink the set.

## Decisions

### 1. Use one append-only frame ledger outside the coverage ring

Each valid shutter invocation creates a `capture_job_id` before asynchronous
work.  The capture ledger is the source of truth for the album, bundle manifest,
finish denominator, deletion, and recovery.  A coverage-cell slot stores only a
reference used for guidance/ranking.  Evicting or replacing that reference never
removes the capture job or its files.

The ledger records these distinct states:

1. `tap_recorded`: Dart accepted the user action and assigned immutable paths.
2. `snapshot_reserved`: the platform owns the matching camera snapshot (or a
   durable raw staging copy) and has returned an acknowledgement.
3. `photo_committed`: JPEG, sidecar, frame-exact SfM input, and a commit marker
   are complete and hash-verified.
4. `sfm_queued`: the committed input is present in the durable FIFO ledger.
5. `sfm_ingested`: native `add_frame` succeeded and the job→image mapping is
   persisted.
6. `registered`: final output contains the mapped image ID.
7. `user_deleted`: an explicit user operation tombstoned the job and removed it
   from the active denominator.

Any error is attached to its current state.  It is not converted into success,
removed from the denominator, or hidden by a count.  A pre-snapshot failure is
still a recorded tap failure; finish remains blocked until the user retries or
explicitly deletes that job.

Alternative rejected: continuing to use `DomeTargetPoints.retainedJpegPaths`.
Its bounded per-cell ring necessarily loses ownership of older manual captures.

### 2. Split snapshot reservation from asynchronous completion

The platform interface returns a `ManualCaptureTicket` after it has selected the
timestamped snapshot and registered the native job.  The ticket carries paths,
job ID, snapshot timestamp, and a completion future/stream.  The UI releases its
shutter busy state at this acknowledgement and adds the AR photo card only after
`photo_committed`.

On iOS this is a two-part MethodChannel protocol: enqueue/reserve returns once;
await/query returns the eventual committed result and is safe if completion won
the race.  The native executor owns no coverage or deletion policy.

The platform must not maintain an unbounded queue of retained 4K pixel buffers.
If its measured in-memory reservation budget would be exceeded, it spills the
snapshot to a private local staging file rather than rejecting or dropping it.
The exact spill threshold is device-qualified; failure to reserve disk is a
visible blocking job error.

Alternative rejected: calling the existing future without awaiting it.  That
shortens UI latency but provides neither an acceptance acknowledgement nor
crash/recovery state and leaves all current timeout/drop paths intact.

### 3. Publish a frame as a recoverable transaction

Native writes unique files under a private per-job staging directory.  It writes
and flushes the JPEG, sidecar, frame-exact SfM gray/input, and a job record with
their sizes and hashes.  It then publishes unique final paths without overwrite
and writes the commit marker last.  The staging record is removed only after the
marker exists.

On restart, a missing marker plus a staging record is not ignored.  Recovery
finishes publication when all staged/final bytes match or reports the exact
blocking job.  It never deletes another job or guesses that a lone JPEG is a
complete frame.

Alternative rejected: direct writes to final `.jpg`/`.json` paths.  A process
death can expose a partial file or only half of the pair with no recoverable
transaction identity.

### 4. Make all SfM inputs durable before offering them

The optional in-memory `sfm_gray` reply is no longer the only copy.  A committed
job contains a durable frame-exact SfM input path and metadata.  The FIFO holds
job IDs/paths, not large byte arrays.  A queue item is retained until native
ingestion is acknowledged and its mapping is persisted.

A spool read error freezes that item as failed; it does not remove it.  An
`add_frame` error does not advance the item.  Because `AddFrameFeaturesImpl` can
partially mutate SQLite before an internal exception, retries after an ambiguous
native error use a fresh database replayed from the complete durable FIFO rather
than assuming the old database is idempotent.  No finalization command is sent
while a job is missing, failed, or ambiguously ingested.

### 5. Gate completion by exact ID closure, not queue emptiness

Finish first prevents new taps, then waits for all enqueue and commit jobs with
no lossy timeout.  It stops the camera only after native snapshot writers are
quiescent.  It then drains/rebuilds SfM and compares exact active job IDs across
the capture ledger, committed inputs, ingested image mapping, and registered
output.  Completion requires set equality, not merely equal counts.

If any set differs, the capture remains a recoverable draft with a precise list
of job IDs and stages.  The final model is not labeled complete.  This is the
only honest interpretation of the 100% registration requirement for difficult
imagery.

### 6. User deletion is explicit, audited, and reconstruction-invalidating

`retainOnlyCuratedPhotos()` and deferred automatic prune are removed from the
manual-capture route.  Curation writes selection metadata only.  Per-photo and
whole-capture deletion first quiesce relevant writers, append a user-deletion
tombstone, and then remove bytes.  Deleting an already-ingested job invalidates
the current reconstruction database and requires a rebuild from the remaining
active jobs so deleted imagery cannot survive in derived output.

There is no timeout that continues deletion while a native writer may recreate
the path.

### 7. Thermal policy controls only background consumption

Accepted frames always enter the durable queue.  The scheduler may reduce
in-flight work, insert a cooldown, or pause at critical thermal state or after a
Metal command-buffer failure.  It resumes from the same FIFO after recovery or
after capture stops and the camera is released.  Existing K12→K6 remains an
independent matching-load reduction, not the no-drop mechanism.

Host code exposes a pure scheduling predicate/state machine.  Phone evidence
selects any pacing constants; tonight's host work must not invent a successful
thermal verdict.

## Risks / Trade-offs

- **Raw storage grows because automatic prune is removed.** → Show available
  space before/during capture, retain all bytes, and let only the user delete.
- **Fast taps can retain several 4K snapshots.** → Use a measured in-memory
  budget and local raw spill; record queue depth and footprint on device.
- **Small synchronous reservation work may still be perceptible.** → Keep JPEG,
  gray conversion, hashing, and SfM off the acknowledgement path; qualify ack
  latency separately from commit latency on A16.
- **A job can be physically unregistrable.** → Preserve it and block the 100%
  completion claim with exact evidence; never silently change the denominator.
- **Fresh-DB replay increases finish time after a failure.** → Prefer correctness
  and recoverability over a fast partial result; expose progress to the user.
- **Legacy capture directories lack the new ledger.** → Treat them as legacy
  read-only evidence and never synthesize 100% closure without proof.

## Migration Plan

1. Add pure Dart ledger, queue, finish-gate, deletion, and thermal scheduler
   types with failing-first tests.
2. Add the platform ticket protocol and native staged-publication/recovery path,
   retaining the old method only as a compatibility adapter.
3. Integrate manual UI, album, manifest, and live SfM with the ledger; disable
   automatic prune for new manual sessions.
4. Run host tests/static checks and package an evidence checklist without
   installing to a phone.
5. In the morning, install only after review and run the physical-device matrix.
   Keep the branch unmerged and the old binary available until all phone gates
   pass.  Rollback is the prior binary; captured v2 directories remain readable
   and must never be destructively downgraded.

## Open Questions

- What measured A16 reservation-memory ceiling triggers raw staging spill?
- What sustained-thermal pacing curve gives zero Metal failures without
  needlessly delaying post-capture drain?  This requires the morning phone run.
- Should a user be allowed to leave the capture page while a blocking job is
  unresolved, or only save a recoverable draft and leave?  Either behavior must
  preserve all bytes and exact job state.
