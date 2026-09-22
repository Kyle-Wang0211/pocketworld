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

Session candidate, selected, blocked, fired, and `fire_role_counts` maps SHALL
contain exactly `geometry`, `radialBridge`, `rotationCoverage`, and
`overlapSafety`. They SHALL NOT contain `none` or any fifth role. A decision
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

The selector SHALL resolve simultaneous eligibility in this order:
`overlapSafety`, `geometry`, `rotationCoverage`, then `radialBridge`.

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

- **WHEN** the product of horizontal and vertical overlap reaches 70%
- **THEN** an overlap-safety capture is requested immediately
- **AND** the UI may request that the user slow down

### Requirement: Selection is cross-platform

Selection SHALL be implemented in pure Dart over the shared pose/intrinsics/
health contract. Platform-private quality enums and Apple capture algorithms
SHALL NOT select or classify a frame.

#### Scenario: Portable track health is unavailable

- **WHEN** no backend-neutral track retention value is available
- **THEN** the selector uses the normal 12° geometry threshold
- **AND** it does not infer a quality tier from an ARKit-only field

### Requirement: Cadence cannot replace geometric selection

Normal automatic photos SHALL be selected by motion/geometry after the 250 ms
duplicate debounce floor, not by a fixed one-second timer. An overlap-safety
decision MAY bypass a longer soft/hard backpressure interval after that floor.

#### Scenario: Fast motion crosses the overlap line during stretched pacing

- **WHEN** overlap reaches 70% after at least 250 ms
- **THEN** the safety capture bypasses the stretched soft/hard interval
