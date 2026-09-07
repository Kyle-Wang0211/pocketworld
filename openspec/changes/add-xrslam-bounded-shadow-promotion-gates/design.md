# Design

## Frozen canonical algorithm

The only algorithmic authority for this change is OpenXRLab XRSLAM upstream
commit `4beb1a942f33da9afbfae2d70e2c641cfc2bb675` together with the RD-VIO v3
method implemented by that revision.  The local `manorajesh/xrslam` revision
`d052dc3793da25d938ccad009586d5469f8a24b9` is a transport/build candidate,
not the definition of official behavior: each of its eight additional commits
must be classified as build-only, observability-only, optional depth work, or
algorithm-changing before it can be present in a faithful arm.  An
algorithm-changing fork patch is disabled in the official-reproduction arm
unless the same behavior exists in the frozen upstream revision.

Faithful reproduction means preserving the upstream image/IMU input contract,
configuration, feature tracking, IMU-PARSAC, frontend trigger cadence,
keyframe/subframe classification, delayed triangulation, R-frame compression,
preintegration chaining, and pose convention.  COLMAP, ORB-SLAM, VINS,
Kimera, AliceVision, ARKit, queue depth, mapper load, thermal state, and a
wall-clock capture interval must not add or replace an XRSLAM algorithmic
decision in this arm.

The upstream iOS visualizer's 30 Hz camera is an example-device setting, not a
core XRSLAM subsampling rule. The faithful baseline delivers every source
camera frame and both 100 Hz raw-IMU streams in timestamp order. Upstream
`tracker_frequent: 3` means every frame is tracked while new-point detection
and the frontend trigger run every third frame; it must never be implemented
as an input-frame dropper. Platform adapters may make delivery nonblocking and
bounded, but they must not alter XRSLAM's mathematics or silently select a
different observation. Any adapter loss invalidates the run; it never
authorizes a queue-pressure-dependent capture or tracking policy.

The production photo selector must not reinterpret an independently invented
Dart geometry score as an official XRSLAM keyframe.  A later authority stage
may consume only a versioned, directly exported upstream keyframe/subframe
decision and its frame identity, after the shadow reproduction is valid.  Until
then ARKit remains production authority and the XRSLAM result remains shadow
evidence.

## Authority boundary

This change is shadow stage S1. ARKit continues to produce the authoritative
pose used by the selector, shutter, SfM, live rendering, saved sidecars, and
user-visible state. xrslam may emit only diagnostics into its isolated report.
The xrslam snapshot reports `authority=shadow` and `decisionConsumers=0`;
neither field transfers production authority. Any attempted product read of an
xrslam pose is a contract violation, not a fallback or a partial promotion.
XRSLAM also has no matcher-lifecycle authority: native callbacks, stop, crash,
and late delivery never write or infer the production matcher capture-active
flag, whose only writer is the Dart capture-lifecycle coordinator.

## Official map-frame semantics and platform relocalization

The frozen upstream iOS demo stores virtual-object poses in XRSLAM's map frame
and renders by moving the camera in that same frame. It does not let an external
platform world reset move an already-created object. PocketWorld preserves that
invariant without adding a tracker or estimator: at subject lock Dart stores
the raw rigid transform `W_lock_from_A` of the subject anchor. For every later
raw anchor transform `W_now_from_A`, Dart computes
`W_lock_from_W_now = W_lock_from_A * inverse(W_now_from_A)`. Dart applies this
exact transform to camera poses and raw platform-world guidance points. It sends
the inverse `W_now_from_W_lock` as the cloud display compensation.

Swift and Kotlin transport raw platform camera/anchor matrices and apply the
single 4x4 display matrix supplied by Dart. They do not detect relocalization,
choose a threshold, smooth a correction, classify severity, or recompute the
transform. Invalid/non-rigid input fails closed in Dart. This is coordinate
adaptation around the frozen XRSLAM algorithm, not an XRSLAM core modification.

## Dart/platform/XRSLAM boundary

Dart owns cross-platform orchestration, the frozen upstream configuration,
input identities, receipts, comparison math, and promotion gates.  It must not
port, approximate, or replace an XRSLAM tracking, robust-estimation,
keyframe/subframe, triangulation, or sliding-window decision.  Those algorithms
remain in the frozen cross-platform C++ core.  Dart explicitly selects the
official reproduction's independent raw accelerometer and gyroscope rates,
source-camera contract, acceleration scale, and declared pixel conversion; consumes a
bounded versioned stream of raw observations and native outcome facts;
validates conservation; and derives only external evidence such as run
validity, timebase compatibility, SE(3) comparison, and promotion status. Dart
persists only aggregate evidence and identities, never raw sensor observations
or an absolute pose history.

Native platform code is deliberately mechanical. It may acquire and transport
independent raw accelerometer and gyroscope timestamps and values, raw platform
tracking state/reason,
intrinsics, and raw xrslam pose/status; normalize platform representation or
downsample pixels; enforce bounded buffer ownership and lifecycle/accounting;
and serialize calls through the xrslam C ABI. A native platform layer may apply
the two sensor rates, acceleration scale, and deterministic integer pixel
conversion explicitly selected by Dart, but it has no fallback or default
sampling, unit-scale, pairing, resampling, or image-scale policy of its own.
Native may echo the applied values as an outcome receipt; Dart never reads
those echoes as the source of policy.

On iOS, the frozen upstream sample delivers both `Camera.swift` and
`Motion.swift` callbacks through one serial queue. The product SHALL preserve
that single ordered ingress before the bounded native admission layer, but it
uses a dedicated serial dispatch queue rather than Flutter's UI/main queue;
CoreMotion receives a single-operation `OperationQueue` backed by that same
serial dispatch queue.
This is a transport-only adaptation required because the production app also
runs a high-resolution shutter transaction on the main path; Build 51 device
evidence showed a 3.501-second first-shutter transaction and a 2.719-second
AR-frame gap after the whole ARSession delegate was moved to main. At the
comparison wire boundary, the raw XRSLAM pose SHALL use the upstream sample's exact SceneKit adapter: position
`(-py,-px,-pz)` and quaternion `(-qy,-qx,-qz,qw)`. This is a mechanical
platform-coordinate conversion only; Dart continues to own world alignment,
residuals, validity, and promotion.

The pixel loop stays beside the native `CVPixelBuffer` to avoid copying a full
luma plane through Flutter. Dart nevertheless owns the complete versioned
operation identity: factor plus `box-nxn-half-up-v1` kernel/rounding formula.
Swift only validates that supported ID, applies it mechanically, and echoes it
in direct and terminal receipts; missing, unknown, or inconsistent IDs fail
closed.

Clock transport is likewise raw. Swift exports only each ordered
`uptimeBefore/monotonic/uptimeAfter` sandwich plus exact session, epoch, and
generation stamps. Dart computes midpoint, sandwich width, uncertainty, drift,
clock-domain compatibility, and the final acceptance verdict. The exact wire
contracts are `pw.vio.timebase-raw/5`,
`pw.vio.timebase-remeasure-raw/1`,
`pw.vio.shadow-run-input-descriptor/4`, and `pw.vio.shadow-native/7`.

Each `/5` source ledger carries cumulative attempted/accepted/rejected,
delivered, and dropped counts plus one bounded drained batch. Native drains the
512-item batch after each Dart poll; it never treats an already delivered sample
as loss. Dart rejects any true overwrite or rejection, validates the cumulative
delivery equation, and may carry a same-session/same-generation clock-base fact
across an empty terminal batch only when the terminal cumulative ledger remains
loss-free.

The native fact wire may contain raw timestamps, scalar samples, exact sums,
counts, return codes, and queue/lifecycle outcomes. Capability sampling uses
fixed-capacity raw timestamp rings with attempted, retained, overwritten, and
capacity accounting; Dart fails closed on loss before reducing the samples. It
does not contain a
derived frame interval, interval/latency/runtime mean, duty cycle, acceleration
norm or mean, or another portable reduction. Dart validates camera intrinsics:
all scalar values must be finite, focal lengths positive, principal point
within the declared image, and width/height finite positive integers before the
configuration can be used.

Native code must not pace or subsample camera evidence based on queue pressure,
thermal state, processing time, user motion, or the demo application's 30 Hz
setting. Native code must not otherwise pace evidence, decide `runValid`, classify
tracking usability, infer timebase drift, convert raw pose/status into semantic
pose classes, compute SE(3) alignment or residual/quality metrics, or make a
promotion decision. It must not invent a timestamp when one is missing,
non-finite, or outside the declared clock contract; it reports the rejection
fact instead. This division is part of S1 acceptance, so an iOS-only Swift
implementation of any portable rule is a contract violation even if its output
looks correct on one phone.

## Loss-intolerant asynchronous ingress

One explicit ring holds at most 256 xrslam work items. Before a camera callback
acquires any additional ownership of an `ARFrame` or `CVPixelBuffer`, one atomic
admission operation checks the open generation and reserves a ring item, one of
30 camera-retention permits, and one preallocated 640×480 grayscale pool slot.
If any reservation fails, the callback records one rejection and retains
nothing. An accepted camera item may retain only the image handle required for
off-callback conversion; it never retains the `ARFrame` object, and it releases
the platform image immediately after filling the reserved grayscale slot. An accelerometer
item owns one copied raw acceleration sample and timestamp; a gyroscope item
owns one copied raw angular-rate sample and its independent timestamp. Native
does not fuse, pair, or resample them. Camera retention has a separate hard
ceiling of 30 slots (one declared 30 Hz source-camera envelope) even when the
ring has room. The shared C++ box-N×N-half-up preparation function writes into
the caller-owned slot without allocating. The dispatch queue may have
at most one drain closure scheduled, so repeated callbacks cannot create an
unbounded closure backlog.

Admission must not use a contended try-lock as an input rejection policy. The
single sensor-ingress queue owns producer ordering; a short ledger publication
lock is never held across pixel conversion, pose serialization, snapshot I/O,
or XRSLAM execution. The adapter accepts every observation in
the declared source-camera / 100 Hz-per-raw-IMU reproduction contract in source
timestamp order.  It never replaces an older observation with a newer
"useful" frame and never uses backlog to choose an observation. Ring full,
retention exhaustion, or any admission contention is an explicitly recorded
transport failure that invalidates the reproduction. Admission never blocks a
production callback, grows without a fixed bound, or silently evicts work.
Retained slots and copied payloads are released exactly once after processing
or a terminal rejection.

Each callback completes one coherent admit-or-drop accounting transaction for
one generation. `attempted`, its accepted/rejected outcome, and its exact reason
cannot straddle separate mutable snapshots. Stop atomically closes admission and
publishes exactly one immutable `generationCloseMarker` containing the session,
epoch, generation, and final admitted sequence. An offer racing that marker is
either wholly admitted with an admission sequence at or before the marker, or
wholly rejected against the closed generation. The marker is copied unchanged
into the terminal envelope; no callback may append to or advance facts beyond
it. Lock-contention facts use an equivalent atomic per-generation path without
waiting.

One serial `coreQueue` exclusively owns every xrslam C-API call, including
create, sensor pushes, `RunOneFrame`, health/pose reads, and destroy.
Downsampling and xrslam calls never run on the ARKit callback stack. xrslam
delay or failure can change only raw shadow outcomes and drop counts that Dart
later evaluates; it cannot delay or fail the production ARKit path.

Stop seals new admission and gives every already-admitted item exactly one
terminal disposition before calling Destroy. Every pose produced before that
boundary is published live or included among the terminal envelope's unpolled
poses. The envelope also contains the unchanged `generationCloseMarker` and the
exact nested Destroy receipt returned by the shared C++ transport. Live and
terminal camera/run/accelerometer/gyroscope/rejection counters come from that
same transport ledger; Swift does not synthesize core health or reconstruct a
Destroy receipt from a later snapshot.

## Lifecycle

The state machine is `stopped -> starting -> running -> stopping -> stopped`.
Start and stop are idempotent asynchronous requests: submission never blocks a
sensor or UI callback, while their Futures complete from the serialized worker.
Only `coreQueue` creates or destroys the global xrslam instance. It enters
`running` only after real intrinsics/configuration and all required identity
stamps are available.

Every start advances a session epoch and every admitted item carries that
epoch. Stop first closes admission for its epoch, so later callbacks are counted
as stop rejections. Request submission is nonblocking, but its asynchronous
completion is withheld until the terminal receipt is ready. On `coreQueue`,
queued items are processed or assigned an explicit dropped-on-stop/terminal-rejected outcome,
the in-flight call completes, xrslam is destroyed exactly once, retained inputs
are released, image scratch storage is zeroed before release, and transient raw
pose state is cleared. `slamStop` atomically completes with exactly one
immutable terminal receipt captured from that old generation after lifecycle
reaches `stopped`. It does not return `void` and require a later mutable
`slamSnapshot` read. The receipt reports `backlog=0` and `inFlight=0` and
contains no retained raw absolute pose or raw observation payload. Its nested
Destroy receipt is the exact transport return, including Destroy return code,
acknowledgement, lifecycle generation, and core submission counters; platform
code may envelope those facts but cannot recalculate or replace them.

An authorized immediate restart may begin only after the old receipt has been
frozen; it cannot alter the direct stop completion or its generation. On the
Dart side, start and stop are one FIFO asynchronous lifecycle transaction. One
single-flight poll gate is closed and any in-flight poll is joined or
suppressed before `slamStop`. Dart pins the first identity-valid direct running
generation, consumes the returned direct-stop receipt once for that same
generation, and rejects an otherwise stopped-shaped generic snapshot. Neither
a late poll nor a restarted generation may overwrite the terminal summary.
After the immutable summary is formed, Dart clears its raw-derived pose,
quality, and SE(3) accumulators before another session can start.

The Future returned by the diagnostic `slamStop` operation may wait for that
terminal receipt, but production teardown never awaits that Future. Capture
completion, camera stop, draft persistence, and navigation initiate the shadow
stop and continue independently. A worker crash, missing receipt, timeout, or
Destroy error closes the diagnostic generation with one typed invalid terminal;
it cannot hold the production camera, matcher flag, route, or persistence lease.
Resource cleanup may continue on the bounded shadow teardown path after product
teardown has completed.

Temporary suspension and explicit shutdown have different authority. A
temporary AR interruption may preserve permission to resume only the same
authorized shadow session and configuration. Explicit Dart shutdown clears the
native resume authorization, desired-run flag, and retained configuration, so
a later AR-session resume cannot resurrect xrslam without a new Dart start.
Backgrounding, capture completion, session failure, recorder stop, and explicit
shutdown still converge on the same resource-release path; only an explicitly
declared temporary suspension may retain same-session resume authorization. An
item from an older epoch is rejected as stale and can never enter a newer
instance.

XRSLAM start has a strict Dart-owned precondition: the exact session, epoch,
and native-generation timebase snapshot must already be accepted. Before that,
native may collect bounded raw clock and CoreMotion facts, but XRSLAM Create,
sensor admission, camera conversion, and `RunOneFrame` remain closed. This
reproduces upstream's premise that camera PTS and CoreMotion timestamps already
share a compatible monotonic domain instead of running on unverified data.

The declared upstream `XRSLAMDestroy` API is the shutdown boundary. The frozen
upstream body does not release its manager-owned `Detail`; the reproduction
carrier therefore completes that declared lifecycle by resetting the owner and
running the existing upstream `Detail` destructor, which stops its frontend and
feature-tracker workers. This is classified as lifecycle completion, not an
algorithm change. The direct receipt is accepted only after Destroy returns and
proves same-generation `created=false`, `state=stopped`, `backlog=0`,
`inFlight=0`, the unchanged close marker, and exact transport Destroy facts. A
missing or failed Destroy receipt invalidates shadow evidence but never converts
diagnostic cleanup into a production-teardown dependency.

## Physical-phone single-variable regression

The regression is sequential on the user's physical iPhone. Both arms use the
same frozen source manifest, production bundle/container, scene, ARKit
authority, capture settings, and logging. OFF disables only the XRSLAM shadow;
ON enables only the gated shadow. The primary regression criterion is zero
`limited_initializing` transitions after subject lock in both arms. ON is
invalid, not degraded, if timebase acceptance did not precede the first XRSLAM
create/push or the diagnostic evidence bundle did not eventually contain the
exact terminal Destroy receipt. Capture completion itself never waits for that
evidence.

## Real counters and identity

For each sensor `s` (`camera`, `accelerometer`, `gyroscope`), record monotonic
native fact counters at the real boundary. Dart consumes one coherent snapshot,
validates every rejection partition, and requires:

`attempted_s = accepted_s + rejected_s`

`accepted_s` means that the corresponding checked native push returned OK.
`rejected_s` is partitioned by local validation/contention, ring or camera
overflow, stop, stale epoch, and non-OK native return code. Accelerometer and
gyroscope callbacks, timestamps, work items, and ledgers remain independent;
neither sensor may synthesize an attempt or result for the other.

At the work-item boundary require:

`enqueueAccepted = processed + droppedOnStop + terminalRejected + backlog + inFlight`

The terminal stop receipt requires `backlog=0` and `inFlight=0`, reducing the
equation to processed, dropped-on-stop, and terminal-rejected outcomes. A local
or overflow rejection never increments `enqueueAccepted`; a non-OK native
return is a sensor rejection and a terminally rejected work item. Counters are
never inferred from the latest snapshot, timestamps, or expected cadence. Dart
marks a run invalid if a partition sum or terminal equation fails; native code
does not assign that validity itself.

Each session receipt contains a unique session ID, epoch, lifecycle transitions,
ring/camera capacities and drop policy, app version/build, product source manifest,
Dart AOT, native host/framework, xrslam library, effective xrslam config, and
input identities. The direct start receipt pins the exact generation, two raw
sensor rates, acceleration scale, pixel downsample factor, and input descriptor;
the terminal receipt must match them. Missing, empty, contradictory, or
`UNSTAMPED` required values make the run invalid and non-promotable.

The native host identity is the stable `LC_UUID` embedded in its final Mach-O.
It is not a SHA-256 of the signed executable, because embedding that digest in
the executable would create a self-referential identity. Official framework,
xrslam framework/library, configuration, and other external artifacts retain
their exact pinned content hashes.

Dart computes the only final `runValid` verdict. It can be true only for the
direct terminal receipt with `state=stopped`, zero backlog and in-flight work,
exact known top-level and nested rejection-reason schemas, complete mutually
consistent non-`UNSTAMPED` identities, conserved sensor/work ledgers, and a
Dart-derived timebase/domain verdict explicitly bound to the same generation.
Both raw accelerometer and raw gyroscope clocks must independently match the
camera clock domain, and every image/accelerometer/gyroscope stream must have
at least one checked native push accepted. A perfectly conserved empty run is
evidence of no work, not an accepted shadow run.
Any unknown top-level rejection key, missing reason, identity mismatch,
nonterminal snapshot, or cross-generation clock verdict fails closed.

Release identity stamping runs only after every framework/embed and other
bundle-mutating target phase and before Xcode's final app signing. After any
device-activity idle wait, the updater immediately rechecks the frozen source
and external-native manifests, complete signed app-tree manifest, bundle,
build, team, architecture and `LC_UUID`, code signature, artifact hashes, and
embedded stamps before its one in-place install command. A mismatch stops the
update.

## Sequential promotion gates

Promotion cannot skip a stage:

1. **S1 bounded observation shadow (this change).** ARKit is sole authority,
   xrslam has zero product decision consumers, identities are stamped, both
   counter layers conserve, and physical-phone production behavior shows no
   shadow-induced regression.
2. **S2 comparative evidence.** A separate accepted experiment contract pins
   metrics, thresholds, seeds, captures, exclusions, hardware, thermal state,
   and stopping rules before results are inspected. It runs on physical iOS and
   Android devices, with at least two distinct device models on each platform,
   spanning the registered focal-length, distance, texture, lighting, and motion
   matrix. Host and simulator evidence remains diagnostic only.
3. **S3 isolated candidate authority.** Only after S1 and S2 pass may a separate
   bundle route xrslam into duplicated product decisions. It uses no production
   container, retains ARKit as the paired control, and requires a new accepted
   OpenSpec change. It does not change the production bundle default.
4. **S4 reversible production canary and default review.** A separately
   approved, explicitly opt-in canary must prove fallback, lifecycle, quality,
   latency, thermal, and data-integrity gates on the same cross-platform/device
   matrix. Making xrslam the default requires another explicit approval after
   the canary; absence of evidence, a failed stage, or an invalid receipt leaves
   ARKit authoritative.
