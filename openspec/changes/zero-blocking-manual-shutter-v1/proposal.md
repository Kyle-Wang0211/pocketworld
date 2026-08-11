# Change: Make the manual shutter non-blocking and loss-aware

## Why

The production capture page currently rejects every tap while one 4032x3024
ARKit transaction is running and dims the shutter during that interval. This
makes the UI feel frozen and silently loses deliberate user input.

## What changes

- Admit valid taps synchronously into a metadata-only FIFO.
- Keep exactly one native high-resolution transaction in flight.
- Preserve the canonical 4032x3024 JPEG, same-frame pose, intrinsics, capture
  timestamp, album acknowledgement, and SfM path for every successful ticket.
- Remove synchronous full-album file scans from the capture bar.
- Freeze and drain accepted work before Finish; report bounded camera failures
  instead of hanging forever.
- Suspend an active FIFO ticket while ARKit is stopped in the background and
  resume that same ticket after ARKit resumes.
- On discard/dispose, stop retries, release the active file owner, then delete
  or dispose the capture resources.

## Non-goals

- No image downsampling, preview substitution, or quality/algorithm change.
- No change to native iOS, C++, matcher, reconstruction, or tail-cache code.
- No Android/HarmonyOS backend implementation in this change.
- No production-device install without a separately frozen P3 authorization.

## Acceptance

- 100 same-turn admissions are FIFO, unique, metadata-only, and execute with a
  maximum native concurrency of one.
- The tap callback contains no await, camera call, telemetry write, device log,
  or pace recomputation.
- Pending tickets never dim or disable the white shutter.
- `verified + outstanding` never exceeds the 300-photo cap.
- Finish drains successful accepted tickets; a permanently failing native
  transaction terminates after a bounded retry count, cancels unstarted Finish
  work, and surfaces a visible error.
- Backgrounding issues no repeated 12MP calls against a stopped ARSession.
- Discard cannot delete a directory before the active 12MP owner settles.
- Focused regression tests pass and no C/C++ or native files change.
