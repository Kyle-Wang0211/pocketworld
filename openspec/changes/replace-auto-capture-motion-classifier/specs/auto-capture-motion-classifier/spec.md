## ADDED Requirements

### Requirement: Motion roles remain geometrically distinct

The selector SHALL classify effective transverse/vertical parallax, radial
scale change, and rotation-only motion separately. Radial and rotation-only
captures SHALL NOT advance the formal geometry baseline.

The first healthy pose after the user starts automatic capture SHALL request a
real startup anchor through the shared single-flight 12 MP executor before
motion classification begins. The startup anchor SHALL be accounted separately
from the four motion roles. A busy or rejected request SHALL NOT establish a
capture or geometry baseline and SHALL be retried no faster than the common
250 ms floor.

#### Scenario: Automatic capture starts with healthy tracking

- **WHEN** the user starts automatic capture and a normalized healthy pose arrives
- **THEN** that pose requests one startup-anchor photo immediately
- **AND** later motion is measured from a successfully admitted photograph
- **AND** the anchor does not increment any of the four motion-role fire counts

#### Scenario: Startup-anchor admission is busy or rejected

- **WHEN** the shared single-flight executor reports `busy-not-admitted` or
  rejects the startup anchor
- **THEN** no phantom baseline is created
- **AND** no pending ticket or delayed camera request is retained
- **AND** the controller retries on a later healthy pose after the debounce floor

#### Scenario: User turns in place and then steps sideways

- **WHEN** a 12° rotation-only frame is captured and later the camera translates
- **THEN** the rotation frame is retained as coverage
- **AND** the later frame is tested against the prior formal geometry baseline

### Requirement: Fire roles are mutually exclusive and count conserving

Session telemetry maps SHALL retain the stable schema keys `geometry`,
`radialBridge`, `rotationCoverage`, and `overlapSafety`. `overlapSafety` is a
warning predicate only and its selected and fired counts SHALL remain zero. A decision
with no selected candidate SHALL increment a separate `no_candidate` scalar.
Telemetry SHALL count the actual predicate and decision events and SHALL NOT
infer roles later from sampled distances or angles.

#### Scenario: A session closes normally

- **WHEN** the terminal telemetry snapshot is written
- **THEN** `decisions` equals `no_candidate` plus the sum of the four selected
  role counts
- **AND** each role's selected count equals its fired count plus all of its
  blocked-reason counts
- **AND** the sum of the four fired counts and the sum of the four
  `fire_role_counts` both equal `decision_counts.fire`
- **AND** `fire_admitted + fire_busy_not_admitted` equals
  `decision_counts.fire`
- **AND** no candidate, selected, blocked, fired, or fire-role map contains a
  fifth or unclassified role bucket

#### Scenario: No motion predicate is eligible

- **WHEN** a decision has no selected formal role
- **THEN** `no_candidate` increments exactly once
- **AND** no formal selected-role counter increments

### Requirement: Role collisions use deterministic precedence

The selector SHALL resolve simultaneous shutter eligibility in this order:
`geometry`, `rotationCoverage`, then `radialBridge`. Overlap safety SHALL be
reported independently and SHALL NOT take shutter precedence.

#### Scenario: Rotation and radial thresholds collide

- **WHEN** a low-parallax frame crosses both the 12° rotation threshold and
  the 1.2× radial depth-scale threshold without crossing overlap safety or
  formal geometry
- **THEN** the selected role is `rotationCoverage`
- **AND** the frame does not advance the formal geometry baseline

### Requirement: Overlap is focal-length and direction aware

The selector SHALL project the active target with runtime intrinsics and combine
horizontal and vertical overlap multiplicatively. It SHALL NOT use a fixed
`0.28 * depth` trigger.

#### Scenario: User moves diagonally

- **WHEN** the projected-target continuity estimate reaches 70%
- **THEN** no photo is requested from that estimate alone
- **AND** the UI may request that the user slow down

### Requirement: Selection is cross-platform

Selection SHALL be implemented in pure Dart over the shared pose/intrinsics/
health contract and the shared 128×128 grayscale sample. Platform-private
quality enums and Apple capture algorithms SHALL NOT select or classify a frame.

#### Scenario: The same source frame reaches different platforms

- **WHEN** iOS or Android delivers a 128×128 grayscale source with its camera
  timestamp and scaled intrinsics
- **THEN** the same Dart feature tracker and admission predicate run on both
  platforms
- **AND** Swift/Kotlin do not classify novelty or choose a capture role

#### Scenario: Dart authorizes a high-resolution camera request

- **WHEN** Dart authorizes one single-flight camera transaction
- **THEN** Dart assigns one opaque `transactionId` that every request, data, and
  presentation continuation consumes exactly once
- **AND** the platform stamps `requestPose` at authorization, `evidencePose` from
  the returned high-resolution image, and `cardPose` from the transform actually
  used to place the card
- **AND** no field is transported as an ambiguous unlabeled `pose`
- **AND** native code does not decide whether the candidate is sharp, novel, or
  accepted
- **AND** `dataOutcome` alone controls the atomic canonical-record publication
- **AND** `presentationOutcome` independently reports `presented`, `suppressed`,
  or `failed` without changing data membership

#### Scenario: A late presentation callback repeats

- **WHEN** a render, timeout, or platform callback repeats after either terminal
  outcome has already completed for its `transactionId`
- **THEN** the duplicate is ignored
- **AND** it cannot replay the anchor or haptic, change data membership, or
  complete a result belonging to another transaction

### Requirement: Visual redundancy is a hard shutter gate

Every spatial shutter candidate SHALL carry the exact 128×128 grayscale source,
its source timestamp, and intrinsics scaled into that source. Dart SHALL track
Shi-Tomasi/Lucas-Kanade feature identities frame-to-frame from the last photo
successfully committed to the project/SfM transaction and require median
displacement of at least 10% of the preview short edge. VINS-Mono's `10/460`
mean compensated parallax and under-20 keyframe conditions SHALL be recorded as
estimator receipts. They SHALL NOT replace spatial geometry, objective quality,
or the 10% photographic boundary while at least 20 accepted-photo tracks remain.
If a reference originally had at least 20 tracks but fewer than 20 remain, an
official VINS keyframe receipt MAY keep an already-spatially-qualified candidate
live so capture cannot deadlock on an obsolete photo anchor. The legacy 16×16
block-mean signature MAY remain a compatibility/diagnostic signal, but SHALL
NOT authorize a production shutter. Failed admission SHALL NOT advance either
visual baseline.
For automatic captures, the native 12 MP completion SHALL additionally return
its own 128×128 grayscale evidence and scaled intrinsics. The same photographic
track gate SHALL compare that actually returned still with the last automatic
12 MP still accepted into the album and durable SfM-input path. A rejected
returned still SHALL not enter the album, durable SfM-input ledger/spool,
target-point coverage, or actual-still baseline.
Manual shutter transactions SHALL remain deliberate captures and SHALL NOT be
classified by this automatic-selection gate.

#### Scenario: A spatial candidate repeats the last admitted image

- **WHEN** at least 20 common tracks exist and median motion is below 10% of the
  preview short edge
- **THEN** the decision is `skipRedundant`
- **AND** no shutter request is made

#### Scenario: A pose tick has no current grayscale sample

- **WHEN** a spatial role is eligible but its reference never had 20 tracks, or
  its gray-source receipt is missing, stale, or out of order
- **THEN** the decision is `skipNoVisualEvidence`
- **AND** the controller waits for a later grayscale-bearing pose

#### Scenario: A healthy track set falls below 20

- **WHEN** a spatial role is eligible and frame-to-frame propagation leaves
  fewer than 20 identities from a reference that originally had at least 20
- **THEN** VINS estimator telemetry marks a keyframe candidate
- **AND** that receipt keeps the already-spatially-qualified candidate live
- **AND** it still cannot bypass blur, exposure, the single-flight guard, or the
  returned 12 MP actual-photo gate

#### Scenario: Comparable tracks show only estimator-scale motion

- **WHEN** at least 20 accepted-photo tracks remain and VINS mean parallax
  reaches `10/460` but median photographic displacement remains below 10% of
  the preview short edge
- **THEN** the decision is `skipRedundant`
- **AND** the estimator receipt does not authorize a camera shutter

#### Scenario: An old geometry anchor and the last actual photo disagree

- **WHEN** the old geometry anchor satisfies formal geometry but the current
  source remains below the normalized track-motion boundary relative to the
  last successfully admitted photo
- **THEN** the frame remains a candidate and no shutter request is made
- **AND** the old geometry baseline remains available for later coverage and
  triangulation calculations

#### Scenario: Sensor latency returns a duplicate automatic still

- **WHEN** the candidate gate requested an automatic shutter but the 12 MP
  completion remains below 10% of the 128×128 short edge relative to the last
  accepted actual still
- **THEN** that completion is rejected before album, SfM, and coverage admission
- **AND** no timer-driven retry occurs; the selector waits for a later clear,
  sufficiently novel preview candidate without advancing either baseline

#### Scenario: A returned still loses a once-healthy accepted-photo track set

- **WHEN** the admitted preview already satisfied spatial geometry and its VINS
  liveness receipt, the returned still is objectively clear, and fewer than 20
  identities remain from an actual-photo reference that originally had at
  least 20
- **THEN** the returned still is accepted as the terminal replacement keyframe
- **AND** all baselines advance only after its atomic album and durable
  SfM-input commit succeeds

### Requirement: Official shutter admission is single-flight and backlog-free

Manual and automatic capture SHALL share one single-flight 12 MP executor.
Admission SHALL either start the transaction immediately or return
`busy-not-admitted`; neither mode SHALL retain a pending ticket, tap, pose, or
delayed camera request. This requirement SHALL supersede any earlier official-
route pending-FIFO or `ManualCaptureQueue` admission requirement, specifically
the `zero-blocking-manual-shutter-v1` immediate loss-aware admission contract.

#### Scenario: Automatic capture is restarted while a 12 MP transaction is active

- **WHEN** the user stops and restarts automatic capture before an already
  admitted automatic 12 MP transaction returns its terminal receipt
- **THEN** no second automatic 12 MP transaction is admitted concurrently
- **AND** no pending FIFO entry is created while the executor is busy
- **AND** the old receipt releases the active transaction without advancing any
  capture, geometry, or visual baseline in the restarted run
- **AND** the next healthy pose may then request the restarted run's anchor

#### Scenario: Another shutter transaction is already active

- **WHEN** a manual tap or automatic candidate arrives while the shared 12 MP
  executor already owns an active transaction
- **THEN** admission returns `busy-not-admitted`
- **AND** neither mode appends a pending FIFO entry or retains a delayed request
- **AND** manual capture receives immediate busy feedback while automatic
  capture emits no false shutter/presentation feedback
- **AND** later preview evidence is evaluated again after the executor is free

#### Scenario: Portable track health is unavailable

- **WHEN** no backend-neutral track retention value is available
- **THEN** the selector uses the normal 12° geometry threshold
- **AND** it does not infer a quality tier from an ARKit-only field

### Requirement: Cadence cannot replace geometric selection

Normal automatic photos SHALL be selected by motion/geometry plus visual
novelty after the 250 ms duplicate debounce floor, not by a fixed one-second
timer. An overlap warning SHALL NOT bypass soft/hard backpressure, visual
redundancy, or sharpness deferral. Executor-busy and device thermal state SHALL
remain telemetry only and SHALL NOT lengthen the automatic-capture interval.

#### Scenario: Fast motion crosses the overlap line

- **WHEN** the overlap warning is active but no spatial role is eligible
- **THEN** no special capture bypass occurs

#### Scenario: Executor or thermal state changes

- **WHEN** the executor-busy label or thermal bucket changes
- **THEN** the minimum automatic-capture interval remains the 250 ms debounce floor
- **AND** the values remain available in telemetry

### Requirement: Finish confirmation is non-mutating until commit

Before every Finish confirmation gate accepts, the system SHALL NOT stop
automatic selection, seal shutter admission, cancel an intent, change matcher
state, stop camera/pose input, or hide the capture surface. Once all gates
accept, one synchronous commit SHALL make the opaque processing surface visible,
tombstone the capture root, and seal new capture admission before the first
asynchronous wait. This requirement SHALL replace
`zero-blocking-manual-shutter-v1`'s Finish freeze/drain behavior wherever that
behavior would run before confirmation commits.

#### Scenario: A Finish gate asks the user to continue capture

- **WHEN** the minimum-photo or coverage gate does not accept Finish, or the user
  chooses Continue
- **THEN** the capture mode, active transaction, executor admission state,
  matcher state, and visible capture surface remain exactly as before the tap
- **AND** no capture intent has been cancelled or silently discarded

#### Scenario: Finish is committed while one 12 MP request is active

- **WHEN** the user confirms Finish with one previously admitted request active
- **THEN** Flutter hides the capture surface before its first asynchronous wait
- **AND** new capture admission, automatic selection, and pose ingestion are
  sealed immediately
- **AND** the active request first reaches a bounded `dataOutcome`
- **AND** its `presentationOutcome` is either already `presented` or is explicitly
  completed as `suppressed`, releasing every native result/render callback
- **AND** only after both outcomes are terminal may AR/camera stop
- **AND** the processing page remains opaque throughout

### Requirement: Data and presentation outcomes are independent

The authoritative data transaction SHALL stage canonical artifacts and then
atomically publish exactly one immutable accepted-photo record, keyed by
`transactionId`, through one Dart owner. That record SHALL be the sole source of
membership truth for album, actual-photo, capture, geometry, coverage, archive,
durable SfM-input ledger/spool, and controller state. Those consumers SHALL be
replayable projections and SHALL NOT decide membership independently.
Live-worker acknowledgement SHALL NOT be part of the commit. Presentation SHALL
have its own exactly-once terminal outcome and SHALL NOT roll data membership
backward or forward.

#### Scenario: Finish suppresses an unrendered accepted card

- **WHEN** accepted high-resolution evidence reaches `dataOutcome=accepted` but
  committed Finish cannot wait for a future first render
- **THEN** presentation completes once as `suppressed`
- **AND** the accepted data remains in every authoritative consumer
- **AND** no timeout or late render callback changes either terminal outcome

#### Scenario: Canonical publication fails

- **WHEN** artifact staging, canonical-record validation, or atomic publication
  fails before the accepted-photo record becomes visible
- **THEN** `dataOutcome` is rejected
- **AND** no authoritative record or consumer projection appears
- **AND** presentation is removed or suppressed without replay

#### Scenario: A derived projection fails after canonical publication

- **WHEN** the accepted-photo record is durably visible but album rendering,
  coverage, archive, SfM-input delivery, or controller projection fails
- **THEN** `dataOutcome` remains accepted
- **AND** the failure is recorded as typed replay debt against the same
  `transactionId`
- **AND** replay cannot create a second authoritative record or duplicate any
  already-applied projection

### Requirement: Live SfM health has no capture authority

Live SfM readiness, health, queue depth, worker lifetime, and terminal status
SHALL NOT enable or disable shutter admission and SHALL NOT accept or reject
Finish. Accepted canonical evidence SHALL remain draft-saveable independently
of live reconstruction.

#### Scenario: The live SfM worker fails before or during processing

- **WHEN** worker startup fails, the worker crashes, or it emits a typed terminal
  processing error
- **THEN** capture admission and Finish policy do not read that health as an
  authority signal
- **AND** one typed processing terminal is shown on the opaque surface
- **AND** the user can save accepted evidence as a draft for later reconstruction

### Requirement: Dart exclusively owns matcher capture lifecycle

One Dart capture-lifecycle coordinator SHALL be the only writer of the matcher
capture-active flag. Native AR callbacks, live-SfM workers, XRSLAM callbacks, and
widget rebuilds SHALL NOT write or infer that flag.

#### Scenario: Capture commits Finish while diagnostic workers are still alive

- **WHEN** the Dart coordinator transitions from capture to committed processing
- **THEN** it writes the matcher flag exactly once for that lifecycle transition
- **AND** later native stop, worker failure, or diagnostic callbacks cannot
  overwrite it

### Requirement: Committed processing cannot reveal the capture root

After Finish commits, the old capture route SHALL remain tombstoned. Back,
gesture-back, and system-pop actions MAY reveal Drafts or another processing-task
surface, but SHALL NOT reveal or reactivate the camera root.

#### Scenario: The user backs out while processing is active or failed

- **WHEN** the opaque processing surface receives app back, gesture back, or a
  system pop before or after a typed terminal error
- **THEN** navigation resolves to Drafts or the processing task surface
- **AND** no capture control, camera preview, or capture input becomes visible or
  active again
