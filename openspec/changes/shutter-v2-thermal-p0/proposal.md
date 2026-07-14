## Why

The current manual shutter waits for native JPEG and sidecar completion before
returning, while several later failure paths can time out, skip, or discard a
frame without preventing finalization.  This couples tap latency to storage and
still does not satisfy the stronger product rule that every accepted tap must
remain accounted for through final registration, especially under sustained
thermal pressure.

## What Changes

- A manual tap receives an immediate, durable identity before asynchronous
  encoding or reconstruction work begins; UI responsiveness no longer waits for
  JPEG encoding, sidecar writing, grayscale extraction, or SfM.
- The capture pipeline records separate states for tap acceptance, native
  snapshot selection, durable photo/sidecar commit, durable SfM queueing, native
  ingestion, and final registration.
- Normal finish waits without a lossy timeout until every accepted frame is
  either fully closed through registration or exposed as a blocking error.
- User-initiated discard remains the only path allowed to delete capture bytes,
  and it waits for writers to quiesce before deletion.
- SfM input is disk-backed before background processing.  Read, extraction, GPU,
  or worker failures cannot silently remove a queue entry or let finalization
  continue with a smaller denominator.
- Sustained heat defers or paces background SfM consumption while preserving the
  full-resolution queue.  Thermal policy never disables the shutter and never
  reduces the accepted-frame denominator.
- Host tests prove the state machine, queue/finalize gates, and failure semantics;
  a separate iPhone 14 Pro qualification proves latency, durability, thermal
  stability, and `accepted == durable == ingested == registered` on device.

Non-goals for this change are COLMAP 4.1.0 migration, Ceres 2.2 submodule
migration, incremental-global-BA enablement, plane-sweep, detector-free model
selection, cloud removal WIP, and Web capture.  Web remains viewer-only.  No
phone-only acceptance item may be declared complete from host or simulator
evidence.

## Capabilities

### New Capabilities

- `lossless-manual-capture`: Immediate shutter acknowledgement with a complete,
  recoverable per-frame lifecycle and explicit finish/discard semantics.
- `thermal-safe-sfm-queue`: Disk-backed, no-drop SfM ingestion and registration
  closure whose background pacing is safe under sustained thermal pressure.

### Modified Capabilities

None.  This repository had no prior OpenSpec capability baseline.

## Impact

- Dart capture policy and UI: `lib/capture/capture_session.dart`,
  `lib/dome/ar_pose.dart`, `lib/dome/platform_pose_provider.dart`,
  `lib/capture/sfm_live_recon.dart`, `lib/capture/sfm_feed_queue.dart`, and both
  capture pages.
- iOS thin executor: `ios/Runner/AetherARKitPlugin.swift` for immediate snapshot
  acknowledgement, atomic staged writes, and completion/recovery reporting.
- Tests: pure Dart state-machine/scheduler tests, Flutter integration tests with
  a fake provider, Swift file-publication tests where host-testable, and a
  deferred physical-device matrix.
- Persistent capture data gains an append-only per-frame ledger and recoverable
  staging state.  Existing capture directories remain readable; migration must
  be additive and fail closed.
- No new network service, commercial model, or third-party runtime dependency is
  introduced.
