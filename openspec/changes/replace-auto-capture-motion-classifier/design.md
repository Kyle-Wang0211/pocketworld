# Design

Maintain two baselines: the last successfully captured frame for overlap,
radial-scale, and cadence bookkeeping, and the last formal geometry frame for
effective parallax. A rotation-only or radial capture updates the capture
baseline but not the geometry baseline. A later translated frame is therefore
measured against a real geometry observation and can pair with the saved
coverage candidate.

Project the active target into both frames with each frame's runtime intrinsics.
Combined overlap is `(1-dx/W)*(1-dy/H)`. At or below 70%, emit a continuity
warning only; this single-target projection is not shared-feature overlap and
cannot request a photo.
At the active target, exact camera-center angle is the effective horizontal or
vertical baseline; use 10°, 12°, or 15° for weak, normal, or strong portable
track health. Below 1.5° stable parallax, a 12° view-axis turn is rotation-only.
If neither geometry nor rotation applies, a 1.2× depth-scale change is a radial
bridge. The value is the rounded `1/sqrt(0.70)` scale change that preserves 70%
area overlap for a centered target; it is not borrowed from an ORB-SLAM image
pyramid.

Evaluate the four predicates independently, then select exactly one shutter
role with fixed precedence: geometry, rotation coverage, then radial bridge.
Overlap safety remains an independent warning predicate. Rotation wins the only
ambiguous non-geometry collision: a low-parallax frame that crosses both the
12° turn threshold and the 1.2× depth-scale threshold is rotation coverage,
not radial bridge.

Session candidate, selected, blocked, and fired maps expose exactly four role
keys: `geometry`, `radialBridge`, `rotationCoverage`, and `overlapSafety`.
The last key is retained for schema compatibility but is never selected or
fired.
`none` is not a fifth role: a decision with no selected candidate increments the
separate scalar `no_candidate`. Multiple candidate predicates may be true, so
masked-by-priority counts are retained, but every decision selects at most one
formal role.

The terminal snapshot must satisfy
`decisions = no_candidate + sum(selected_by_role)`. For every formal role,
`selected = fired + sum(blocked_by_reason)`. It must also satisfy
`decision_counts.fire = sum(fired_by_role) = sum(fire_role_counts)` and
`decision_counts.fire = fire_admitted + fire_busy_not_admitted`. Counters are
incremented at the actual predicate, decision, and enqueue-outcome boundaries,
never reconstructed later from sampled geometry.

Normal decisions obey the 250 ms duplicate debounce; a fixed one-second
interval has no upstream photogrammetric basis. The first startup anchor remains
immediate. Comparable post-anchor frames require displacement relative to the
last accepted actual photograph to reach 10% of the preview short edge. The
VINS-Mono under-20 condition and `10/460` mean compensated parallax are retained
as estimator receipts. They cannot replace spatial geometry, blur, exposure, or
the comparable-photo 10% gate. When a once-healthy accepted-photo anchor falls
below 20 common identities, however, the controller must not deadlock forever:
an official VINS keyframe receipt may keep an already-spatially-qualified
candidate live. The returned 12 MP still then provides the terminal quality and
actual-photo receipt before any baseline advances. A spatially useful, visually
verified and objectively clear frame may fire immediately regardless of wall-
clock speed or queue load.
The official route has one shared single-flight 12 MP executor and no pending
manual or automatic shutter FIFO. Admission either starts one transaction now or
returns `busy-not-admitted` without retaining a ticket, tap, pose, or future
camera request. Manual capture exposes that busy result immediately; automatic
capture records it and reevaluates later preview evidence. This requirement
supersedes the `zero-blocking-manual-shutter-v1` `ManualCaptureQueue` pending-
FIFO admission and Finish freeze/drain contract for the official route. The
older change's canonical-original requirement remains compatible; its delayed
ticket ownership does not. A terminal receipt from a transaction admitted by an
older automatic run cannot advance a restarted run's baselines.

The returned high-resolution still is checked against the last accepted actual
photo. The sole membership authority is one immutable Dart-owned
`AcceptedPhotoRecord`, keyed by `transactionId` in a durable ledger. The data
commit first stages the canonical JPEG/evidence and then atomically publishes
exactly one record containing the actual-photo, capture, geometry, coverage,
archive, durable SfM-input, and controller metadata. No published record means
the photo was not accepted. Project album, coverage, archive queue, durable SfM
spool, and controller baselines are replayable projections of that record, not
independent sources of truth. A projection failure becomes typed replay debt; it
cannot partially redefine membership or roll an accepted `dataOutcome` back.
Live-worker acknowledgement is outside the commit, so a draft can replay the
durable input when that worker is unavailable. Any canonical pre-publication
failure publishes no record and advances no projection. An automatic still
receives one camera transaction: quality, duplicate, missing-evidence, or
canonical-commit rejection waits for new preview evidence instead of blindly
retrying 80–350 ms later. Manual and automatic transactions share the same
single-flight admission rule; mode changes do not create a backlog.

AliceVision's upstream implementation first computes scores for the complete
input sequence, closes motion subsequences, and then selects a historical frame
from each subsequence. A real-time 12 MP transaction cannot return to a past
preview. The offline selector and its causal 0.5×..1.5× approximation therefore
have no production controller or shutter authority. The 10%-of-short-edge scale
is retained only as an explicit photographic-spacing parameter, not as a claim
of full AliceVision replication. Projected-overlap warnings, VINS estimator
receipts, objective blur/exposure gates, actual-photo verification, and the
single-flight guard remain separate and cannot silently override one another.

The VINS visual front end is a clean-room Dart reproduction of the pinned
upstream semantics: CLAHE 3.0/8×8, Shi-Tomasi replenishment to 150, pyramidal LK
21×21/maxLevel=3/30 iterations/0.01 epsilon, final border rejection,
long-track-first `MIN_DIST=30/480`, and fundamental-matrix rejection with the
OpenCV 7-point RANSAC/LMeDS dispatch. The exact frame pinhole matrix
`fx,fy,cx,cy` is transported with each 128×128 grayscale sample; Dart must not
invent a centred principal point. ARKit documents that this matrix applies to
the corresponding `capturedImage` image plane. Other platforms must provide the
same pinhole-coordinate contract or rectify before transport; platform-specific
camera algorithms do not enter the Dart decision layer.

The visual shutter receipt is split at the platform boundary without moving any
selection policy into native code. Dart remains the sole owner of candidate
selection, quality/duplicate acceptance, deletion, and every baseline. It
creates one opaque `transactionId` at admission and every request, data, and
presentation continuation must consume that identity exactly once. Three poses
are always named rather than transported as an ambiguous `pose`:

- `requestPose` is the camera pose at Dart authorization and high-resolution
  request submission.
- `evidencePose` is the exact returned high-resolution image-time pose used by
  reconstruction evidence and metadata.
- `cardPose` is the transform actually used to place the visible photo card. It
  may be derived from `requestPose`, but it remains a separately named and
  stamped fact.

The transaction has two independent terminals. `dataOutcome` decides whether
the canonical record is atomically published. `presentationOutcome`
reports `presented`, `suppressed`, or `failed` for the card/haptic operation and
never decides album, durable SfM-input, coverage, or baseline membership. A data
rejection suppresses/removes its private presentation. Conversely, an accepted
data outcome remains accepted if presentation must be suppressed during
committed Finish or if a derived projection needs replay. Duplicate native
callbacks, timeouts, or late render callbacks cannot complete either terminal
twice, replay the anchor/haptic, or mutate a different transaction.

Finish has explicit pre-commit and post-commit phases. Before the minimum-photo,
coverage, and user-confirmation gates all accept, the handler may inspect state
but must not stop automatic selection, seal the executor, cancel a capture
intent, change matcher state, or hide capture UI. Choosing Continue returns to
the exact prior capture state. The Finish commit then performs one synchronous
state transition that makes the opaque processing surface visible, tombstones
the capture root, and seals all new capture admission before the first await.

After commit, an already-active high-resolution transaction is allowed to reach
its bounded `dataOutcome`. Its presentation must also be terminal: an already
rendered card reports `presented`; otherwise the coordinator explicitly reports
`suppressed` and releases every pending native result/render callback. Only then
may AR/camera stop. CaptureSession input, automatic selection, and pose ingress
remain sealed throughout. Shadow VIO shutdown is asynchronous diagnostic cleanup
and may not delay AR stop, draft persistence, navigation, or production teardown.

Live SfM is a downstream processing consumer, not a capture-health authority.
Worker startup failure, crash, or typed processing error cannot disable the
shutter, reject Finish, or discard accepted canonical evidence. It produces one
typed terminal processing state, after which the user can save the evidence as
a draft and retry reconstruction later. Processing readiness changes content on
the already-opaque surface; it never controls whether capture UI disappears.

The committed processing route is terminal relative to the capture root. App
back, gesture back, and system pop may fold processing into Drafts or another
processing task surface, but cannot reveal or reactivate the underlying camera
route. One Dart capture-lifecycle coordinator is also the exclusive writer of
the matcher capture-active flag: it sets the flag from capture start/committed
stop state, and native AR lifecycle callbacks, SfM workers, XRSLAM callbacks,
and UI rebuilds may only observe it.
