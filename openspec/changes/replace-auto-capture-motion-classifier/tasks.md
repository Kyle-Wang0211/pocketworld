# Tasks

- [x] Add failing pure-Dart tests for horizontal, vertical, radial, rotation,
  diagonal-overlap, and unavailable-health cases.
- [x] Implement projection, motion decomposition, overlap, and adaptive angle
  selection in the geometry layer.
- [x] Add role-aware governor decisions and motion-driven normal cadence.
- [x] Maintain separate capture and geometry baselines in the controller.
- [x] Extend classifier-role telemetry at the existing predicate and decision
  boundaries.
- [x] Make rotation coverage win a simultaneous rotation/radial eligibility
  collision while keeping overlap safety warning-only.
- [x] Preserve exactly four role keys while replacing queue-derived
  `fire_enqueued/fire_enqueue_failed` outcomes with single-flight
  `fire_admitted/fire_busy_not_admitted` conservation.
- [x] Add collision and count-conservation regression tests.
- [x] Route the real startup anchor through the shared single-flight executor,
  keep it outside the four-role ledger, and retry busy/rejected admission without
  a pending ticket or phantom baseline.
- [x] Require exact current grayscale/intrinsics and continuous feature-track
  evidence at the real shutter, while keeping the legacy 0.92 signature
  diagnostic-only and preserving visual baselines across failed admissions.
- [x] Replace `zero-blocking-manual-shutter-v1` pending manual admission and all
  automatic shutter FIFOs on the official route with one shared single-flight
  executor whose busy result is not admitted or retained, while stale active
  receipts cannot advance a restarted run.
- [x] Make Finish confirmation gates non-mutating; only the accepted commit may
  synchronously expose the opaque surface, tombstone capture, and seal admission.
- [x] Let an active high-resolution transaction reach bounded data terminal and
  rendered-or-explicitly-suppressed presentation terminal before stopping AR.
- [x] Introduce one exactly-once `transactionId`, separately stamp
  `requestPose`, `evidencePose`, and `cardPose`, and implement independent
  `dataOutcome` and `presentationOutcome` terminals.
- [x] Implement one durable immutable accepted-photo record keyed by
  `transactionId` as the atomic membership source of truth; make album,
  actual-photo, capture, geometry, coverage, archive, SfM input, and controller
  state idempotent replayable projections; keep live-worker acknowledgement
  outside that commit and add pre-publication/projection-fault tests.
- [x] Remove live-SfM readiness/health from shutter and Finish authority; convert
  startup failure, worker crash, and worker error into one typed processing
  terminal that preserves draft saving.
- [x] Give one Dart capture-lifecycle coordinator exclusive matcher-flag write
  ownership and reject native, worker, XRSLAM, or rebuild writes.
- [x] Tombstone the capture root after committed Finish so app back, gesture
  back, and system pop can reveal only Drafts/processing, never capture UI.
- [x] Prevent accepted-photo track exhaustion from deadlocking capture by using
  the official VINS keyframe receipt only after spatial geometry qualifies,
  while preserving the 10% gate for comparable photo anchors.
- [x] Add executable coordinator/widget/native lifecycle tests for non-mutating
  Finish gates, exact opaque transition, active high-resolution Finish,
  exception paths, worker crash, transaction idempotency, and back/system pop;
  then run focused Flutter tests and static analysis.
- [x] Leave phone installation blocked until the production update runbook is
  separately authorized and completed.

## Completion evidence (2026-08-29)

- The production auto-capture matrix covers 30 related Flutter test files and
  392 tests; the full matrix exits successfully.
- Task-scoped Dart analysis exits successfully with no errors. Existing unused
  warnings and null-aware style infos remain outside this change's behavior.
- Full-repository `flutter analyze --no-pub` remains non-zero because the
  separate untracked `opencv_autocapture_vision_validation_test.dart` imports a
  missing, production-unreferenced Dart wrapper. Independent review classified
  that orphaned work as outside these 11 production lifecycle tasks.
- Fresh-context read-only architecture review first found one Finish drain
  teardown defect. After TDD repair, a second fresh-context review accepted the
  frozen fix with P0 = 0 and P1 = 0: drain throw/timeout still stops camera and
  terminalizes session resources, preserves accepted data, cancels pending
  data, suppresses presentation before native cleanup, and never reveals the
  capture root again.
- No device build, installation, launch, or Basalt/XRSLAM bench was performed.
