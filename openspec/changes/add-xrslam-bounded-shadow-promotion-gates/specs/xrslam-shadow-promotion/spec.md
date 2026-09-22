## ADDED Requirements

### Requirement: xrslam shadow work is bounded and asynchronous

The system SHALL place shadow work in one ownership-safe fixed ring of 256 work
items, retain at most two camera buffers, and schedule at most one drain closure.
One serial `coreQueue` SHALL exclusively execute every xrslam C-API call.
Ingress SHALL NOT block, grow, or silently evict prior work. Each callback SHALL
complete one coherent O(1) admit-or-drop accounting transaction against its
generation; attempted, outcome, and rejection reason SHALL NOT be exposed as a
partially updated fact set. Stop SHALL seal those facts immutably.

#### Scenario: Camera admission cannot proceed immediately

- **WHEN** the ring is full, two camera buffers are already retained, or the
  admission lock is contended when an ARKit frame is offered
- **THEN** the production callback returns without waiting for xrslam,
  downsampling, or diagnostic I/O
- **AND** the new frame is rejected exactly once with its real reason
- **AND** ring occupancy remains at most 256 and retained camera count remains
  at most two

#### Scenario: The ring is full when a raw IMU sample arrives

- **WHEN** one raw accelerometer or raw gyroscope item is independently offered
- **THEN** that callback rejects its item without creating an unbounded
  dispatch backlog
- **AND** only that sensor records the attempted and rejected sample
- **AND** native does not synthesize, pair, or resample the other sensor

#### Scenario: The drain is already scheduled

- **WHEN** another work item is admitted before the current drain finishes
- **THEN** the item enters the fixed ring
- **AND** no second drain closure is added to the dispatch queue

#### Scenario: A callback races generation sealing

- **WHEN** a camera, accelerometer, or gyroscope callback overlaps stop sealing
  its generation
- **THEN** the offered event is wholly admitted or rejected and accounted in
  that old generation, or wholly rejected against the closed generation
- **AND** its attempted, accepted/rejected outcome, and exact reason appear in
  one coherent fact set
- **AND** the callback does not wait and cannot mutate the sealed receipt

#### Scenario: xrslam is slow or faults

- **WHEN** shadow processing exceeds the sensor cadence or returns an error
- **THEN** only shadow backlog, drop, or failure counters change
- **AND** ARKit capture selection, shutter, SfM, rendering, and persistence
  continue through their existing authority path

#### Scenario: Any xrslam operation is requested

- **WHEN** create, push, run, snapshot, health, pose, or destroy is needed
- **THEN** that native call executes on the same serial `coreQueue`
- **AND** no other thread calls xrslam concurrently

### Requirement: Portable policy and evidence algorithms live in Dart

Every policy or algorithm that can be shared by iOS and Android SHALL execute
in Dart. Dart SHALL explicitly select independent raw accelerometer and
gyroscope sampling rates, the acceleration-unit scale, and the integer pixel
downsample factor and SHALL consume a bounded, versioned stream of raw
observations and native outcome facts. Dart SHALL validate rejection
partitions and terminal conservation and
SHALL derive run validity, tracking usability, timebase drift, pose status and
initialization, quality, SE(3) alignment, residuals, and promotion evidence.

Native platform code SHALL be limited to raw sensor/time/tracking/intrinsics/
pose-status transport, bounded buffer ownership and lifecycle/accounting,
platform representation normalization or pixel downsampling, and serialized
xrslam C-ABI calls. Representation normalization SHALL NOT include cadence,
quality, usability, semantic pose classification, or promotion policy.

Native code SHALL NOT pace or subsample evidence, choose a default sampling,
unit-scale, pairing, resampling, or image-scale policy, decide `runValid`,
decide tracking usability, infer timebase drift,
derive a pose semantic class, compute SE(3) alignment or residual/quality
metrics, or make a promotion decision. It SHALL NOT synthesize a timestamp
fallback. Dart SHALL persist aggregate evidence only; neither layer SHALL
persist raw sensor observations or an absolute pose history for S1 evidence.

Swift SHALL export raw timestamps, scalar facts, sums, counts, return codes, and
bounded queue/lifecycle outcomes only. It SHALL NOT derive intervals, means,
duty cycle, acceleration norms or means, or another portable reduction. Dart
SHALL validate camera intrinsics before use: every scalar is finite, focal
lengths are positive, principal point is inside the declared image, and width
and height are finite positive integers.

#### Scenario: A shadow session requests raw IMU input

- **WHEN** a shadow session is configured
- **THEN** Dart supplies explicit raw accelerometer Hz, raw gyroscope Hz, and
  acceleration-unit scale to the native platform layer
- **AND** native applies those exact values mechanically and echoes them in the
  direct start identity
- **AND** each sensor keeps its own callback, timestamp, work item, and ledger
- **AND** native does not use fused device motion, pair samples, or resample one
  stream onto the other
- **AND** a missing or invalid value fails closed instead of selecting a native
  default

#### Scenario: A raw clock sandwich is transported

- **WHEN** native samples the uptime/monotonic relationship at start or
  remeasurement
- **THEN** Swift exports only ordered `uptimeBefore`, `monotonic`, and
  `uptimeAfter` raw values with exact session, epoch, and generation stamps
- **AND** Dart computes midpoint, width, uncertainty, drift, domain
  compatibility, and acceptance
- **AND** the exact schemas are `pw.vio.timebase-raw/5` and
  `pw.vio.timebase-remeasure-raw/1`

#### Scenario: A bounded raw timebase batch is delivered

- **WHEN** Dart polls a `/5` timebase source ledger
- **THEN** native returns one bounded raw batch and atomically drains that batch
  after counting it as delivered
- **AND** cumulative `accepted = delivered + dropped`,
  `attempted = accepted + rejected`, and current batch-count equations hold
- **AND** an already delivered prior batch does not later become an overwrite
- **AND** Dart rejects any true dropped or rejected sample
- **AND** an empty terminal batch may reuse only a loss-free clock-base fact
  from the exact same session, epoch, and native generation

#### Scenario: A shadow session requests pixel conversion

- **WHEN** Dart configures an xrslam image input
- **THEN** Dart supplies the integer downsample factor, scales the matching
  intrinsics, and binds both to the input identity
- **AND** native validates and applies that exact deterministic conversion
- **AND** a missing or invalid factor fails closed instead of selecting a
  native default
- **AND** any native echo is an applied-value receipt, never Dart's policy source

#### Scenario: A source timestamp is unusable

- **WHEN** a camera, accelerometer, or gyroscope observation has a missing,
  non-finite, or
  clock-contract-invalid timestamp
- **THEN** native records and transports the actual rejection fact
- **AND** native does not replace it with wall time, monotonic time, a previous
  timestamp, or an expected-cadence timestamp
- **AND** Dart includes the rejection in its partition and run-validity checks

#### Scenario: Portable evidence is evaluated

- **WHEN** tracking, clock, pose, initialization, quality, alignment, residual,
  or promotion evidence is needed
- **THEN** native transports only the bounded raw observations, raw statuses,
  and outcome facts required by the declared schema
- **AND** Dart computes the portable result
- **AND** an equivalent Android input can execute the same Dart logic without
  reproducing an iOS Swift algorithm

#### Scenario: Pixel input requires platform conversion

- **WHEN** a platform pixel buffer must be normalized or downsampled before an
  xrslam C-ABI call
- **THEN** native may perform the declared deterministic representation
  conversion off the production callback stack
- **AND** native does not use that conversion to choose evidence cadence,
  tracking usability, quality, or promotion status

#### Scenario: Evidence is persisted

- **WHEN** Dart finishes processing a bounded observation batch or the terminal
  snapshot
- **THEN** persistence contains only aggregate counters, metrics, identities,
  validity reasons, and gate status
- **AND** no raw sensor observation or absolute pose history is persisted

#### Scenario: Raw native facts need a portable reduction

- **WHEN** interval, latency/runtime mean, duty cycle, acceleration norm/mean,
  tracking quality, or another portable aggregate is required
- **THEN** Swift exports only the required raw timestamp, sum, count, or status
- **AND** Dart computes and validates the reduction

#### Scenario: A capability timestamp ring loses samples

- **WHEN** a fixed-capacity native capability ring reports overwritten samples
  or inconsistent attempted, retained, overwritten, or capacity accounting
- **THEN** Dart rejects the timing evidence instead of reducing a truncated
  sample set
- **AND** interval, median, and nearest-rank p95 calculations remain in Dart

#### Scenario: Camera intrinsics arrive from a platform channel

- **WHEN** Dart receives focal length, principal point, width, and height
- **THEN** Dart rejects the intrinsics if any scalar is non-finite, a focal
  length is not positive, a principal point is outside the image, or a dimension
  is not a positive integer
- **AND** no native acceptance or coercion overrides that Dart verdict

### Requirement: The shadow lifecycle owns every resource exactly once

The xrslam state SHALL follow
`stopped -> starting -> running -> stopping -> stopped`, with faults converging
on `stopping`. Start and stop SHALL be idempotent asynchronous requests and
SHALL NOT block a sensor or UI callback. Stop SHALL close ingress, account for
queued work, serialize destroy after in-flight native work, and release every
retained input exactly once. Its asynchronous `slamStop` completion SHALL
atomically return exactly one immutable terminal receipt captured from the old
generation; it SHALL NOT require a later mutable `slamSnapshot` call. No xrslam
C-API call SHALL begin after destroy. Dart SHALL serialize start and stop as one
FIFO lifecycle transaction, pin the first identity-valid direct running
generation, and accept only the once-consumed direct-stop receipt for that same
generation. After forming the immutable summary, Dart SHALL clear raw-derived
pose, quality, and SE(3) accumulator state.

#### Scenario: Capture ends while work is queued

- **WHEN** the lifecycle enters `stopping`
- **THEN** submission returns without blocking while its asynchronous
  completion waits for the terminal receipt
- **AND** new input is counted as a stop rejection
- **AND** queued input receives a `droppedOnStop` or `terminalRejected` outcome
- **AND** exactly one immutable terminal snapshot is delivered after the
  lifecycle reaches `stopped`
- **AND** that snapshot reports `backlog=0` and `inFlight=0`
- **AND** retained image scratch is zeroed before release
- **AND** neither native state nor the snapshot retains a raw absolute pose,
  raw observation payload, or prior-generation scratch

#### Scenario: Stop is requested more than once

- **WHEN** capture completion, recorder stop, and backgrounding race
- **THEN** all requests converge on the same stop operation
- **AND** xrslam is destroyed at most once for that session

#### Scenario: Work from a prior session reaches the worker

- **WHEN** an item's epoch differs from the active session epoch
- **THEN** it is terminally rejected as stale
- **AND** it never enters the new xrslam instance

#### Scenario: Stop is followed by an authorized immediate restart

- **WHEN** a temporary suspension has authorized the same session to restart
  immediately after stop
- **THEN** native freezes the old-generation stopped receipt before beginning
  the new generation
- **AND** the direct `slamStop` completion returns that immutable old receipt
  exactly once
- **AND** new-generation state and counters cannot alter the receipt

#### Scenario: Dart stops while a snapshot poll is in flight

- **WHEN** Dart begins shutdown while a diagnostic poll is running or pending
- **THEN** Dart closes its single-flight poll gate and joins or suppresses that
  poll before invoking `slamStop`
- **AND** Dart consumes the returned terminal receipt exactly once for its
  matching generation
- **AND** no late poll or immediate restart can overwrite the terminal result

#### Scenario: Start and stop overlap in Dart

- **WHEN** a stop is requested while start awaits a platform result, or a new
  start is requested while stop is draining
- **THEN** the operations complete in FIFO order under one lifecycle state and
  generation token
- **AND** an older asynchronous continuation cannot start CoreMotion, a timer,
  or xrslam after the newer stop has completed

#### Scenario: A stopped-shaped snapshot was not returned by direct stop

- **WHEN** a generic poll map claims `state=stopped` with otherwise valid facts
- **THEN** Dart reports `runValid=false`
- **AND** only the direct `slamStop` completion, consumed once for the pinned
  running generation, may authorize terminal validity

#### Scenario: Dart explicitly shuts down the shadow

- **WHEN** Dart requests explicit recorder or shadow shutdown
- **THEN** native clears resume authorization, desired-run state, and retained
  configuration during the serialized stop
- **AND** a later AR-session resume cannot recreate or restart xrslam
- **AND** a future run requires a new explicit Dart start and configuration

#### Scenario: AR is only temporarily suspended

- **WHEN** an explicitly classified temporary interruption stops the worker
- **THEN** native may retain resume authorization only for the same authorized
  session and configuration
- **AND** that permission cannot survive an explicit Dart shutdown or authorize
  a different session

### Requirement: Shadow counters conserve actual events

For each of `camera`, `accelerometer`, and `gyroscope`, the report SHALL count
events at their real native boundaries. Native SHALL transport the coherent
fact snapshot and Dart SHALL validate each rejection partition and satisfy:

`attempted = accepted + rejected`

`accepted` SHALL mean the checked native push returned OK. `rejected` SHALL be
partitioned by local validation/contention, overflow, stop, stale epoch, and
non-OK native return. Both the top-level rejection map and every nested reason
map SHALL use the exact versioned key set; an unknown or missing key SHALL fail
validation rather than being ignored.

At the work-item boundary the report SHALL also satisfy:

`enqueueAccepted = processed + droppedOnStop + terminalRejected + backlog + inFlight`

The terminal receipt SHALL report `backlog=0` and `inFlight=0`.

#### Scenario: A terminal shadow receipt is validated

- **WHEN** the session has completed its asynchronous stop
- **THEN** `attempted=accepted+rejected` holds for all three sensors
- **AND** the terminal work-item conservation equation holds with zero backlog
  and zero in-flight work
- **AND** no count is synthesized from elapsed time, expected cadence, or a
  latest-value snapshot
- **AND** every top-level and nested rejection key is known and complete
- **AND** Dart, rather than native code, assigns the final run-validity result

### Requirement: Accepted shadow evidence is stamped

Every accepted shadow run SHALL identify its session, epoch, lifecycle,
ring/camera capacities, drop policy, app build, source manifest, Dart AOT,
native host/framework, xrslam library, effective config, and inputs. Native host
identity SHALL use the stable `LC_UUID` from the final Mach-O, not a
self-referential hash of its signed executable. Framework/library and other
external artifact identities SHALL remain their exact pinned content hashes.
Required identity values SHALL be present, mutually consistent, and SHALL NOT
equal `UNSTAMPED`.

The direct start receipt SHALL bind the exact session, epoch, generation,
independent requested raw-sensor rates, acceleration scale, pixel downsample
factor, versioned pixel-reduction formula, and
`pw.vio.shadow-run-input-descriptor/4` input identity. The matching native
receipt SHALL use `pw.vio.shadow-native/6`; the terminal receipt SHALL match the
same values exactly.

Raw CoreMotion producers start asynchronously. Native transport SHALL treat a
successful pair of start requests as pending delivery and SHALL NOT stop them
because `isAccelerometerActive` or `isGyroActive` has not changed synchronously.
An asynchronous producer error SHALL close the matching shadow generation.
Start-receipt failure reasons SHALL identify the failed boundary: a raw-IMU
startup failure SHALL NOT be reported as a stale lifecycle receipt.

#### Scenario: CoreMotion activation is not synchronous

- **WHEN** both raw sensors are available and their update requests are issued
- **THEN** the transport remains active while the first samples arrive
- **AND** a synchronous `isActive` observation cannot cancel the start

#### Scenario: The raw IMU producer cannot start

- **WHEN** the feeder starts but raw accelerometer or gyroscope transport fails
- **THEN** the direct receipt reports `raw-imu-start-failed`
- **AND** it does not report `stale-start-receipt`

The selected formula SHALL be `box-nxn-half-up-v1`: for every output pixel,
native transport sums the exact N×N source block and emits
`(sum + floor(N×N/2)) / (N×N)` using integer division. Dart SHALL select and
stamp this formula; native code SHALL reject missing or unknown formula IDs and
SHALL NOT substitute a kernel or rounding rule.

#### Scenario: A required identity is unstamped

- **WHEN** any required value is absent, empty, contradictory, or `UNSTAMPED`
- **THEN** xrslam does not enter an accepted running state
- **AND** the run cannot satisfy a promotion gate

#### Scenario: Native host and framework identities are checked

- **WHEN** Dart validates a terminal receipt
- **THEN** native-host identity equals the `LC_UUID` of the final host Mach-O
- **AND** each declared framework or library identity equals its exact pinned
  content hash
- **AND** no signed-executable self-hash is accepted as the native-host stamp

#### Scenario: A production update is ready to install

- **WHEN** the signed Release candidate has passed the device-activity idle gate
- **THEN** identity stamping has run after every framework/embed and other
  bundle-mutating target phase and before final app signing
- **AND** the updater immediately rechecks frozen source and external-native
  manifests, the full signed app-tree manifest, bundle/build/team,
  architecture, `LC_UUID`, signature, artifact hashes, and embedded stamps
- **AND** any mismatch stops before the single in-place install command

### Requirement: Dart assigns final run validity from terminal evidence only

Dart SHALL be the sole owner of the final `runValid` verdict. It SHALL be true
only when the direct `slamStop` receipt is for the expected generation, reports
`state=stopped`, `backlog=0`, and `inFlight=0`, satisfies every sensor and work
conservation equation with exact rejection schemas, contains all required
mutually consistent non-`UNSTAMPED` identities, and carries an acceptable
timebase/domain verdict bound to that same generation. Both independent raw
accelerometer and raw gyroscope clock sources SHALL match the camera domain.
Every image, raw accelerometer, and raw gyroscope stream SHALL also contain at
least one accepted checked native push.
Every other input SHALL fail closed.

#### Scenario: A conserved run carried no sensor work

- **WHEN** a terminal receipt conserves every ledger but any image,
  accelerometer, or gyroscope accepted count is zero
- **THEN** Dart reports `runValid=false`

#### Scenario: Only one raw IMU clock matches the camera

- **WHEN** the accelerometer or gyroscope clock evidence is absent, lossy, or
  does not independently match the camera clock domain
- **THEN** Dart reports `runValid=false`
- **AND** native cannot replace that verdict with a shared or fused timestamp

#### Scenario: A running poll otherwise looks healthy

- **WHEN** a nonterminal snapshot has good counts, identities, and tracking
- **THEN** Dart still reports `runValid=false`
- **AND** only the direct stopped terminal receipt can produce a final true
  verdict

#### Scenario: A reason key or identity is unknown

- **WHEN** the terminal receipt has an unknown top-level rejection key, a
  missing nested reason, an incomplete identity, or any `UNSTAMPED` identity
- **THEN** Dart reports `runValid=false`

#### Scenario: The clock verdict belongs to another generation

- **WHEN** the timebase/domain verdict is absent, unacceptable, or stamped with
  a generation different from the terminal receipt
- **THEN** Dart reports `runValid=false`
- **AND** no prior or restarted generation can supply the missing verdict

### Requirement: ARKit remains the sole production authority

During S1, xrslam poses and health SHALL be diagnostic-only. Its snapshot SHALL
report `authority=shadow` and `decisionConsumers=0`; ARKit SHALL remain the sole
production pose authority.

#### Scenario: A product decision path requests an xrslam pose

- **WHEN** the automatic selector, shutter, SfM, renderer, sidecar writer, or
  other product consumer attempts to read shadow output
- **THEN** the boundary rejects the read and records a contract violation
- **AND** ARKit remains authoritative

### Requirement: ARKit-to-xrslam promotion is sequential

The project SHALL NOT switch production authority directly from ARKit to
xrslam. Promotion SHALL proceed through S1 bounded observation shadow, S2
preregistered comparative evidence, S3 isolated candidate authority, and S4
reversible production canary/default review. Each later stage SHALL require its
preceding stage to pass and a separately accepted contract.

#### Scenario: Evidence comes from only one phone or one platform

- **WHEN** a promotion decision lacks physical-device evidence from either iOS
  or Android, or includes fewer than two distinct device models on either
  platform
- **THEN** the promotion gate remains blocked
- **AND** host, simulator, or single-device results remain diagnostic only

#### Scenario: This change completes successfully

- **WHEN** every S1 invariant passes
- **THEN** xrslam remains an observation-only shadow with zero decision
  consumers
- **AND** ARKit remains the production authority until separately approved
  later stages pass
