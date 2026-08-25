## ADDED Requirements

### Requirement: Motion roles remain geometrically distinct

The selector SHALL classify effective transverse/vertical parallax, radial
scale change, and rotation-only motion separately. Radial and rotation-only
captures SHALL NOT advance the formal geometry baseline.

#### Scenario: User turns in place and then steps sideways

- **WHEN** a 12° rotation-only frame is captured and later the camera translates
- **THEN** the rotation frame is retained as coverage
- **AND** the later frame is tested against the prior formal geometry baseline

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
