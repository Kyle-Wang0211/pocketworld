# Change: Add a bounded xrslam shadow and staged authority gates

## Why

The repository contains an xrslam VIO foundation, but running it synchronously
from ARKit/CoreMotion callbacks can delay the production capture path, and
diagnostic counters do not yet prove what was accepted, dropped, completed, or
cancelled. More importantly, having a pose available is not evidence that it is
safe to replace ARKit. The next step must therefore be an observation-only,
bounded shadow with auditable lifecycle and promotion boundaries.

## What changes

- Put all xrslam C-API calls on one serial core queue behind an ownership-safe
  256-item ring. Atomically reserve generation admission, a ring item, and one
  of 30 camera-retention slots before retaining any ARFrame/CVPixelBuffer beyond
  its callback; allow at most one scheduled drain closure and never wait in a
  production sensor callback.
- Define one serialized lifecycle for create, run, stop, and destroy, including
  idempotent start/stop and accounting for work cancelled during shutdown.
  `slamStop` itself returns exactly one immutable terminal receipt for the old
  generation, even when an authorized immediate restart follows.
- Isolate sessions by epoch and persist stamped run identity plus real
  per-sensor and work-item counters with mechanical conservation checks. Each
  callback performs one O(1), nonblocking admit-or-drop transaction against a
  coherent ledger. Stop publishes one immutable `generationCloseMarker` before
  callback quiescence and carries that exact marker into the terminal receipt.
- Put every portable policy and algorithm in Dart. Native platform code is
  limited to raw sensor/time/tracking/intrinsics/pose-status transport,
  bounded ownership/lifecycle/accounting, platform normalization/downsampling,
  and serialized calls through the xrslam C ABI.
- Make Dart select the independent raw accelerometer and gyroscope rates, the
  acceleration-unit scale, and the pixel downsample factor; consume bounded
  raw observations; validate rejection partitions and terminal conservation;
  derive clock midpoint/uncertainty, run/pose/initialization/quality/SE(3)/
  residual semantics; and persist aggregates only.
- Make Dart join or suppress its in-flight snapshot poll before stopping,
  consume the returned terminal receipt exactly once, and distinguish a
  resumable temporary suspension from an explicit shutdown which revokes the
  native resume authorization and configuration.
- Keep every xrslam output diagnostic-only. ARKit remains the sole authority for
  capture selection, shutter decisions, SfM inputs, rendering, and persistence.
- Preserve the upstream AR-demo map-frame invariant across platform
  relocalization: Dart freezes the logical world at subject lock, maps later
  poses/points into it, and sends the inverse display transform to native code
  that only applies the matrix.
- Keep the XRSLAM core closed until Dart accepts the exact session/epoch/
  generation timebase contract. Measurement-only clock/IMU transport may run
  before acceptance; XRSLAM image/IMU work may not.
- Make `slamStop` return the exact receipt produced at the serialized
  `XRSLAMDestroy` boundary. A stopped-looking flag or reconstructed Swift
  snapshot is not a receipt. Production capture/AR teardown only initiates this
  diagnostic stop and never waits for it; terminal receipt/error delivery
  continues on the shadow lifecycle.
- Keep the production matcher capture-active flag under its single Dart
  capture-lifecycle owner. XRSLAM native callbacks and shutdown paths never
  write it.
- Define sequential evidence gates for any future ARKit-to-xrslam promotion;
  no gate in this change authorizes a direct switch.

## Non-goals

- No production pose-source switch.
- No xrslam input to the automatic-capture classifier or any other product
  decision consumer.
- No native evidence pacing, default sampling policy, timestamp fallback,
  run-valid/tracking-usability/timebase-drift decision, pose semantic class,
  SE(3), residual, quality, or promotion decision.
- No device installation or production-bundle mutation in this change.
- No claim that one iPhone, host replay, simulator, or one platform establishes
  a cross-device production default.

## Acceptance

- Camera callbacks reserve bounded ownership before retaining platform image
  state and never wait for xrslam, downsampling, diagnostics I/O, start, or stop.
  A rejected offer retains neither an ARFrame nor a CVPixelBuffer.
- Ring occupancy never exceeds 256 work items, accepted camera retention never
  exceeds 30 reserved slots, and the dispatch queue has at most one pending
  drain closure.
- Each sensor satisfies `attempted=accepted+rejected`; each admitted work item
  satisfies the declared terminal conservation equation, including after stop.
- Both requested raw-IMU rates, the acceleration-unit scale, and every portable
  evidence decision originate in Dart; missing or invalid native timestamps are
  rejected rather than synthesized, paired, or resampled.
- Exactly one terminal snapshot is delivered after asynchronous stop. It says
  `lifecycle=stopped`, `backlog=0`, and `inFlight=0`, and retains no raw absolute
  pose or raw observation payload after Dart has produced aggregate evidence.
- The terminal envelope contains the exact nested Destroy receipt plus the
  matching `generationCloseMarker`; missing, synthesized, or cross-generation
  values produce a typed invalid terminal.
- XRSLAM stop, worker failure, or Destroy failure never delays production camera
  stop, draft persistence, route navigation, or other teardown completion.
- Native exports raw facts only, not intervals, means, duty cycle, acceleration
  norms, or other portable reductions; Dart also validates all finite camera
  intrinsics and positive integral image dimensions.
- Clock transport is the raw three-read sandwich
  `uptimeBefore/monotonic/uptimeAfter`; midpoint, width, uncertainty, drift, and
  acceptance are Dart computations. The bound schemas are
  `pw.vio.timebase-raw/5`, `pw.vio.timebase-remeasure-raw/1`,
  `pw.vio.shadow-run-input-descriptor/4`, and `pw.vio.shadow-native/7`.
- Final Dart `runValid` is possible only from a terminal receipt with an exact
  rejection-reason schema, complete identities, and an acceptable same-
  generation timebase/domain verdict.
- Before that verdict is accepted, XRSLAM create, camera push, IMU push, and
  `RunOneFrame` counts are all zero.
- Dart computes the exact rigid lock/current-anchor correction and native code
  only applies its inverse to the cloud; native has no correction threshold,
  smoothing, classification, or fallback.
- The physical-phone regression uses sequential XRSLAM OFF and ON arms from one
  frozen product source. The shadow enable flag is the only variable; both arms
  require zero post-lock production `limited_initializing` transitions, and ON
  additionally requires accepted pre-start timebase and terminal receipts.
- Required app/source/Dart/native/xrslam/config identities are present and none
  equals `UNSTAMPED`. Native host identity is its stable Mach-O `LC_UUID`, while
  referenced framework/library identities remain exact content hashes.
- `decisionConsumers=0` for every accepted shadow run and ARKit remains
  the recorded production authority.
- Production promotion remains blocked until sequential gates include
  preregistered physical-device evidence on both iOS and Android and at least
  two distinct device models on each platform.
