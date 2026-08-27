## ADDED Requirements

### Requirement: Motion roles remain geometrically distinct

The selector SHALL classify effective transverse/vertical parallax, radial
scale change, and rotation-only motion separately. Radial and rotation-only
captures SHALL NOT advance the formal geometry baseline.

The first healthy pose after the user starts automatic capture SHALL be
admitted through the existing shutter queue as a real startup anchor before
motion classification begins. The startup anchor SHALL be accounted separately
from the four motion roles. A rejected anchor SHALL NOT establish a capture or
geometry baseline and SHALL be retried no faster than the common 250 ms floor.

#### Scenario: Automatic capture starts with healthy tracking

- **WHEN** the user starts automatic capture and a normalized healthy pose arrives
- **THEN** that pose requests one startup-anchor photo immediately
- **AND** later motion is measured from a successfully admitted photograph
- **AND** the anchor does not increment any of the four motion-role fire counts

#### Scenario: Startup-anchor admission is rejected

- **WHEN** the shared shutter queue rejects the startup anchor
- **THEN** no phantom baseline is created
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
- **AND** `fire_enqueued + fire_enqueue_failed` equals
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

### Requirement: Visual redundancy is a hard shutter gate

Every spatial shutter candidate SHALL carry the exact 128×128 grayscale source,
its source timestamp, and intrinsics scaled into that source. Dart SHALL track
Shi-Tomasi/Lucas-Kanade feature identities frame-to-frame from the last photo
successfully admitted to the shared shutter queue and compare their cumulative
focal-normalized median displacement to `10/460`. In accordance with
VINS-Mono's keyframe rule, a once-healthy reference that falls below 20 common
tracks SHALL become a keyframe candidate instead of waiting forever; a
reference that never had 20 tracks SHALL remain underconstrained. The legacy
16×16 block-mean signature MAY remain a compatibility/diagnostic signal, but
SHALL NOT independently authorize a production shutter when the exact source
contract is present. Failed admission SHALL NOT advance either visual baseline.
For automatic captures, the native 12 MP completion SHALL additionally return
its own 128×128 grayscale evidence and scaled intrinsics. The same normalized
track gate SHALL compare that actually returned still with the last automatic
12 MP still accepted into the album/SfM path. A rejected returned still SHALL
not enter the album, SfM stream, target-point coverage, or actual-still baseline.
Manual shutter transactions SHALL remain deliberate captures and SHALL NOT be
classified by this automatic-selection gate.

#### Scenario: A spatial candidate repeats the last admitted image

- **WHEN** at least 20 common tracks exist and focal-normalized median motion is
  below `10/460`
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
- **THEN** the frame is a keyframe candidate rather than
  `skipNoVisualEvidence`
- **AND** it fires only if the independent clarity gate also passes

#### Scenario: An old geometry anchor and the last actual photo disagree

- **WHEN** the old geometry anchor satisfies formal geometry but the current
  source remains below the normalized track-motion boundary relative to the
  last successfully admitted photo
- **THEN** the frame remains a candidate and no shutter request is made
- **AND** the old geometry baseline remains available for later coverage and
  triangulation calculations

#### Scenario: Sensor latency returns a duplicate automatic still

- **WHEN** the candidate gate requested an automatic shutter but the 12 MP
  completion remains below `10/460` relative to the last accepted actual still
- **THEN** that completion is rejected before album, SfM, and coverage admission
- **AND** a bounded retry requests a fresh 12 MP frame without advancing either
  actual-still baseline

#### Scenario: Portable track health is unavailable

- **WHEN** no backend-neutral track retention value is available
- **THEN** the selector uses the normal 12° geometry threshold
- **AND** it does not infer a quality tier from an ARKit-only field

### Requirement: Cadence cannot replace geometric selection

Normal automatic photos SHALL be selected by motion/geometry plus visual
novelty after the 250 ms duplicate debounce floor, not by a fixed one-second
timer. An overlap warning SHALL NOT bypass soft/hard backpressure, visual
redundancy, or sharpness deferral. Queue pressure and device thermal state SHALL
remain telemetry only and SHALL NOT lengthen the automatic-capture interval.

#### Scenario: Fast motion crosses the overlap line

- **WHEN** the overlap warning is active but no spatial role is eligible
- **THEN** no special capture bypass occurs

#### Scenario: Queue or thermal state changes

- **WHEN** the pressure label or thermal bucket changes
- **THEN** the minimum automatic-capture interval remains the 250 ms debounce floor
- **AND** the values remain available in telemetry
