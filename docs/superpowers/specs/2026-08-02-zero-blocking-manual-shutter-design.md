# Zero-blocking manual shutter design

Date: 2026-08-02

## Goal

The manual capture UI must accept every valid shutter tap immediately. The
shutter stays visually enabled while previous 12 MP captures and reconstruction
work are pending. Heavy work may queue in the background, but the Flutter UI
must not wait for it and must not silently drop taps.

This change is independent of the C++ `tail-cache/dirty-epoch` work. That work
reduces reconstruction-tail growth. This design changes only capture admission,
12 MP request serialization, and capture-bar file lookup behavior.

## Non-negotiable production invariants

1. Every successful project photo remains a canonical 4032x3024 JPEG under the
   capture's `photos_highres` directory.
2. Reconstruction, color sampling, texturing, album display, future retraining,
   and export continue to consume the persisted high-resolution files.
3. This change does not replace the current JPEG with a preview frame, RAW/DNG,
   or a lower-resolution stream image, and does not change JPEG quality.
4. Each accepted high-resolution image, camera pose, intrinsics, and capture
   timestamp continue to come from one returned ARKit `ARFrame` transaction.
5. At most one ARKit high-resolution request and one high-resolution raw pixel
   buffer may be in flight. Apple documents that a second request may fail while
   the previous request is still active.
6. Queue memory contains capture tickets and paths, not `Uint8List` image bytes,
   decoded images, `CVPixelBuffer` objects, or 12 MP pixel copies.
7. The existing 300-photo hard limit remains. The limit counts verified photos,
   the in-flight ticket, and queued tickets together, so rapid tapping cannot
   oversubscribe the capture.
8. The C++ tail-cache implementation and its files are out of scope.

## Current failure

The page sets `_capturing = true` for the entire native 12 MP transaction,
returns immediately from later taps while `_capturing` is true, and visually
dims the shutter through the `busy` property. The page then awaits
`highResolutionCompletion` before clearing `_capturing`. Therefore the UI
advertises a disabled state and silently drops every tap received during the
first transaction.

The capture-bar builder also iterates all project-photo paths and performs
`existsSync` and `lastModifiedSync` calls on each rebuild. That synchronous O(N)
disk scan is independent of SfM and can increasingly block the Flutter isolate
as the capture grows.

## Selected architecture: Dart FIFO capture-ticket queue

### Admission

The UI tap callback performs only a synchronous O(1) admission operation:

1. Confirm the capture session is accepting tickets.
2. Check `verified + in-flight + queued < 300`.
3. Allocate a monotonically increasing ticket ID and record the tap timestamp.
4. Append the ticket to a FIFO.
5. Schedule the queue pump if it is idle.
6. Return without awaiting camera capture, JPEG encoding, file I/O, SfM, or UI
   reconstruction work.

The button does not receive a capture-busy visual state. It remains white and
tappable while the FIFO is nonempty. It may become disabled only when the
session is not ready, finalization has frozen admission, or the 300-ticket
budget is exhausted.

### Queue pump

One Dart worker drains the FIFO serially. For each ticket it calls the existing
`CaptureSession.captureSinglePhoto()` path and waits until the verified 12 MP
transaction completes before starting the next ticket. The existing native
ARKit executor and JPEG encoder remain unchanged.

The worker records both:

- `tap_timestamp`: when Flutter accepted the user's tap;
- `capture_timestamp`: when ARKit produced the high-resolution frame.

When input is faster than sensor throughput these values differ. The pipeline
must use the returned capture timestamp and returned pose with the image; it
must never claim that a later exposure occurred at the earlier tap pose.

An individual capture retries a bounded six times inside its queue slot. A
permanent camera failure becomes an explicit ticket fault rather than hanging
Finish forever. During a normal foreground take, retry state never disables
the button or blocks Flutter from admitting more tickets.

### Persistence and memory

Before a ticket runs, it owns only small metadata. When its 12 MP request
completes, the existing native path encodes and writes the canonical JPEG. The
album and SfM then receive the verified file path, as today. Completed JPEGs
remain on disk and are available to reconstruction and texturing for the whole
project lifecycle.

The queue never holds image pixels. With 100 pending taps, memory therefore
grows with roughly 100 small ticket records, not 100 12 MP frames. The SfM
spool continues to store paths rather than image bytes.

### Finish, close, lifecycle, and failures

- **Finish:** atomically freezes new admission, drains every already accepted
  ticket, then calls the existing `session.stop()`, pending-save barrier, and
  SfM finalization. No accepted ticket may be omitted from finalization.
- **Insufficient-photo check:** final eligibility is evaluated after the
  accepted FIFO is drained, using verified project photos. Queued-but-not-yet-
  verified tickets are displayed as pending rather than counted as completed.
- **Discard:** freezes admission, cancels tickets that have not started, stops
  the current session through the existing discard path, and waits for the
  in-flight operation to release its file before deleting the capture bundle.
- **Page disposal/session loss:** closes admission, cancels pending tickets,
  and prevents callbacks from mutating a disposed widget.
- **Permanent camera failure:** remains visible as an explicit capture fault;
  it must not silently consume a ticket. Finish cancels work that has not
  started after the first permanent failure and preserves verified originals.
- **Background:** suspends the active transaction before ARKit stops. A failed
  ARKit resume explicitly fails the waiter and keeps admission closed; only a
  later successful ARKit resume may reopen the shutter queue.
- **Finish tapped twice:** only the first transition freezes/drains; later taps
  join or return from the same finalization future.

## Capture-bar O(N) removal

`OfficialProjectPhotoAlbum` maintains the latest verified photo path as album
state. `_ManualCaptureBar.build()` reads that cached value and the cached count;
it does not call `File.existsSync`, `File.lastModifiedSync`, sort paths, or scan
the full photo list. File validation remains at the one-time verified-commit
boundary, not in the frame-building path.

This is separate from reconstruction tail caching: it removes repeated UI-
isolate disk work, while C++ tail-cache/dirty-epoch changes the backend
`DatabaseCache` growth curve.

## Alternatives rejected

### Native Swift FIFO

A Swift queue could return a job ID immediately and serialize ARKit captures,
but it duplicates queue lifecycle, cancellation, and event plumbing in every
platform backend. The queue policy belongs in shared Dart; native code remains
a single-photo executor.

### Capture the current streaming ARFrame at tap time

This gives a closer exposure timestamp but changes the production input from
4032x3024 high-resolution capture to the lower-resolution AR stream. It also
risks retaining multiple pixel buffers. It violates quality and memory
invariants and is rejected.

## Tests and acceptance

Tests are written and observed failing before production changes.

1. One event-loop turn enqueues 100 taps; all 100 are accepted in order.
2. While ticket 1 is unresolved, ticket 2 is accepted rather than dropped.
3. The capture executor's maximum concurrent in-flight count is exactly one.
4. One hundred tickets produce 100 unique ordered IDs and output paths.
5. Ticket state contains no byte buffer or decoded-image field.
6. The shutter remains fully white and has a non-null tap handler while the
   queue contains 1 and 100 pending tickets.
7. The hard cap uses `verified + in-flight + queued`; it accepts ticket 300 and
   rejects ticket 301 without overshoot.
8. Finish freezes admission and calls session stop/finalization only after the
   accepted queue drains.
9. Discard cancels not-started tickets and does not leave a worker or callback
   mutating the disposed page.
10. Retry/failure does not block new UI admission and is surfaced explicitly.
11. Capture-bar build contains no synchronous full-list file scan.
12. Existing 4032x3024 validation, same-frame pose/intrinsics, on-disk JPEG,
    SfM path spool, album commit, and 300-photo contracts remain green.
13. Flutter analyzer and the focused capture regression suite pass with no new
    warnings or failures.
14. Physical-iPhone validation rapidly taps at least 20 times while moving,
    verifies no gray shutter/no dropped ticket, confirms one-at-a-time native
    capture, validates every produced JPEG and pose, and observes bounded
    memory. Device installation still requires its own exact P3 authorization.

## Acceptance semantics

This design guarantees immediate UI admission and eventual FIFO 12 MP capture.
It cannot guarantee that arbitrarily fast taps cause simultaneous physical
12 MP exposures. When taps outrun ARKit, later exposures occur later and use
their actual returned ARKit pose and timestamp.
