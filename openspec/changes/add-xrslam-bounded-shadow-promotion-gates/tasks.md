# Tasks

Implementation and test boxes remain unchecked until the frozen rework receives
independent acceptance. Physical-device evidence is a separate box and cannot
be inferred from source tests or a build.

- [ ] Freeze OpenXRLab `4beb1a942f33da9afbfae2d70e2c641cfc2bb675`
  plus RD-VIO v3 as the sole algorithmic authority and classify every local
  fork delta before it can enter the official-reproduction arm.
- [ ] Reproduce all source camera frames, independent 100 Hz raw accelerometer
  and gyroscope, and the actual meaning of `tracker_frequent: 3` (track every
  frame; detect/trigger every third frame), plus feature-tracker, frontend trigger,
  keyframe/subframe, R-frame compression, preintegration chaining, and pose
  convention without COLMAP/ORB/VINS/Kimera/ARKit-derived algorithmic rules.
- [ ] Export versioned official keyframe/subframe decisions and exact frame
  identities for shadow evidence; do not route an independently invented Dart
  geometry selector into production as an XRSLAM reproduction.
- [ ] Disable every algorithm-changing `manorajesh/xrslam` patch in the
  official-reproduction arm unless that behavior is present in the frozen
  OpenXRLab revision; retain build-only and observability-only deltas only after
  byte/diff review proves they do not change algorithm semantics.
- [ ] Make camera/IMU ingress loss-intolerant: split admission from snapshot and
  metrics locks, deliver every declared-cadence observation in timestamp order,
  and invalidate instead of adapting or silently selecting frames on overflow.
- [ ] Correct the XRSLAM `worldFromCamera` wire convention and prove the Dart
  SE(3) comparison with asymmetric non-identity transforms.
- [ ] Freeze the subject-anchor frame in Dart, normalize later camera/guidance
  geometry into it, and send only the inverse 4x4 display compensation to thin
  Swift/Kotlin executors; test translation and rotation relocalizations.
- [ ] Gate XRSLAM Create and all sensor admission on an accepted exact-generation
  Dart timebase verdict; prove all XRSLAM work counters remain zero before it.

- [ ] Put all shadow work in one 256-item ring; atomically reserve generation,
  ring, 30-slot camera retention, and grayscale ownership before retaining any
  ARFrame/CVPixelBuffer; schedule at most one drain closure; and give one serial
  `coreQueue` exclusive ownership of every xrslam C-API call.
- [ ] Implement the declared start, stop, drain, and destroy lifecycle with
  idempotent entry points and exactly-once resource release, including zeroed
  image scratch and cleared raw pose at terminal stop.
- [ ] Complete the declared upstream `XRSLAMDestroy` resource semantics by
  releasing the manager-owned Detail/config and prove its existing worker
  destructors return before the terminal receipt is frozen.
- [ ] Isolate sessions by epoch and make start/stop idempotent, asynchronous,
  and stale-work safe.
- [ ] Make `slamStop` directly return exactly one immutable old-generation
  terminal receipt; freeze it before any authorized restart and never fetch it
  through a later mutable snapshot.
- [ ] Close and join/suppress Dart's single-flight poll before stop, consume the
  returned terminal receipt exactly once for its generation, and prevent a late
  poll or immediate restart from overwriting it.
- [ ] Serialize Dart start/stop/start as one FIFO lifecycle transaction, pin the
  first identity-valid direct running generation, reject generic stopped-shaped
  maps, and clear raw-derived pose/quality/SE(3) state after terminal summary.
- [ ] Seal coherent per-generation callback facts through O(1), nonblocking
  admit-or-drop transactions so attempted/outcome/reason never straddle a stop;
  publish one immutable `generationCloseMarker` and carry it unchanged into the
  terminal envelope.
- [ ] Return the exact nested C++ transport Destroy receipt, including return
  code, acknowledgement, generation, and submission counters; reject any
  platform-synthesized or later-snapshot substitute.
- [ ] Decouple production teardown from diagnostic `slamStop`: worker crash,
  timeout, or Destroy failure emits a typed invalid terminal but cannot delay
  camera stop, matcher lifecycle, draft persistence, or route navigation.
- [ ] Separate temporary same-session suspension from explicit Dart shutdown;
  shutdown clears native resume authorization, desired state, and configuration
  so AR resume cannot resurrect the shadow.
- [ ] Limit native platform code to raw sensor/time/tracking/intrinsics/
  pose-status transport, bounded buffer/lifecycle/accounting, platform
  normalization/downsampling, and serialized xrslam C-ABI calls.
- [ ] Make Dart explicitly select independent raw accelerometer/gyroscope Hz,
  acceleration scale, and integer pixel downsample factor; remove every native
  default sampling/unit-scale/pairing/resampling/image-scale policy, evidence
  pacer, and synthesized timestamp fallback.
- [ ] Deliver a bounded, versioned native fact stream to Dart and have Dart
  compute run validity, tracking usability, timebase drift, pose status and
  initialization, quality, SE(3) alignment, residuals, and promotion evidence.
- [ ] Feed independent raw accelerometer and gyroscope callbacks/timestamps;
  never use fused device motion, pair the streams, or resample one onto the
  other.
- [ ] Export raw Swift timestamps/sums/counts and ordered clock sandwiches only;
  move midpoint/width/uncertainty/drift, interval, mean, duty,
  acceleration-norm, and every other portable reduction to Dart, including
  finite/range/integer validation of `CameraIntrinsics`.
- [ ] Bind `pw.vio.timebase-raw/5`,
  `pw.vio.timebase-remeasure-raw/1`,
  `pw.vio.shadow-run-input-descriptor/4`, and `pw.vio.shadow-native/7` to the
  exact session/epoch/generation and start/stop receipts.
- [ ] Drain each bounded `/5` raw timebase batch after delivery while preserving
  cumulative delivery/drop/rejection conservation; reject true loss and permit
  same-generation Dart carry-forward only for an empty loss-free terminal batch.
- [ ] Bound capability timestamp rings with attempted/retained/overwritten/
  capacity receipts, fail closed on loss, and compute interval, median, and
  nearest-rank p95 in Dart.
- [ ] Emit real per-sensor attempted/accepted/rejected partitions and work-item
  terminal counters, then validate both conservation equations in Dart.
- [ ] Emit exactly one immutable snapshot after asynchronous stop with
  `lifecycle=stopped`, `backlog=0`, `inFlight=0`, and no retained raw absolute
  pose or raw observation payload.
- [ ] Stamp app/source/Dart/native/xrslam/config identities, use final Mach-O
  `LC_UUID` for native-host identity, retain exact framework/library hashes,
  and reject `UNSTAMPED`, missing, or contradictory receipts.
- [ ] Run identity stamping after all bundle-mutating target phases and, after
  the activity idle gate, immediately revalidate frozen source/native/app-tree,
  signing, UUID, artifact, and embedded-stamp identities before one install.
- [ ] Make final Dart `runValid` require the direct stopped terminal receipt,
  zero backlog/in-flight, exact top-level and nested reason schemas, conserved
  facts, complete identities, and an acceptable same-generation timebase/domain
  verdict.
- [ ] Keep ARKit as production authority and enforce xrslam
  `authority=shadow` with `decisionConsumers=0` at the integration boundary.
- [ ] Prohibit every XRSLAM callback and lifecycle path from writing the matcher
  capture-active flag; prove the single Dart capture-lifecycle owner remains the
  only writer across start, stop, crash, and late callbacks.
- [ ] Keep asynchronous CoreMotion starts alive until delivery/error and report
  raw-IMU, stale-intent, feeder, and direct-receipt failures distinctly.
- [ ] Add deterministic tests for capacity overflow, callback nonblocking
  behavior, start/stop races, cancellation, faults, rejection-partition and
  terminal conservation, stop/restart receipt isolation, poll/stop joining,
  explicit-shutdown resurrection prevention, pre-retention admission,
  generation-close-marker races, exact Destroy receipt identity, nonblocking
  production teardown, sealed-generation facts, unknown top-level reasons,
  identity rules, intrinsics, one terminal snapshot, forbidden matcher writes,
  forbidden native reductions/decisions, and forbidden product consumption.
- [ ] Collect S1 physical-iPhone shadow evidence without changing or installing
  over the production bundle.
- [ ] Run sequential physical-phone XRSLAM OFF/ON arms from one frozen product
  manifest; both require zero post-lock `limited_initializing` transitions and
  ON also requires pre-start timebase and terminal destroy receipts.
- [ ] Keep S2-S4 blocked until their preceding gate passes and each stage has a
  separately accepted experiment/OpenSpec contract.
