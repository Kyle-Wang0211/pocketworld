## ADDED Requirements

### Requirement: Streaming preview reports an intentional alignment no-op

The production pipeline SHALL emit one `preview_skip` record for a streaming
preview snapshot and SHALL NOT run or report the final delivery alignment for
that snapshot. The record SHALL use
`reason=already_arkit_gravity_metric` because preview points are already in the
ARKit gravity-aligned metric coordinate system.

#### Scenario: Streaming preview is published

- **WHEN** the live reconstruction facade receives a `preview` snapshot
- **THEN** it emits `preview_skip` with `phase=preview`
- **AND** it records both gravity and scale as `not_required`
- **AND** it returns the preview snapshot unchanged
- **AND** it does not emit `final_alignment_result`

### Requirement: Every delivery snapshot reports its alignment result

The production pipeline SHALL emit exactly one `final_alignment_result` for
each `local_ready` or `refined` snapshot, including success and fail-open
outcomes. The result SHALL contain gravity and scale statuses and reasons, the
final quaternion and scale factor, valid-evidence counts, point count, and
metadata count.

#### Scenario: Refined alignment succeeds

- **WHEN** a `refined` snapshot has sufficient gravity and scale evidence
- **THEN** the result uses `authority=authoritative`
- **AND** it records the applied quaternion and scale factor
- **AND** it records both statuses as `applied`

#### Scenario: Local-ready result is available before refined

- **WHEN** a `local_ready` snapshot is aligned
- **THEN** the result uses `authority=fallback_candidate`
- **AND** a consumer treats it as the fallback only when no refined result is
  available

#### Scenario: Gravity evidence is insufficient

- **WHEN** final gravity alignment cannot be applied
- **THEN** the snapshot is delivered unchanged
- **AND** the result records `gravity_status=skipped` with the diagnostic reason
- **AND** it records `scale_status=skipped` with
  `scale_reason=gravity_not_applied`

#### Scenario: Scale anchoring is disabled

- **WHEN** gravity alignment succeeds and the scale-anchor feature is disabled
- **THEN** the result records `scale_status=disabled`
- **AND** it records `scale_reason=feature_disabled`

### Requirement: Legacy ambiguous skip events are retired

The production pipeline SHALL NOT emit `gravity_skip` or `scale_anchor_skip`
from the live preview or delivery alignment paths after the stage-specific
events are introduced.

#### Scenario: Any alignment stage completes

- **WHEN** preview, local-ready, or refined alignment handling completes
- **THEN** no legacy ambiguous skip event is emitted
