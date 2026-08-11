# Change: Split preview and final alignment telemetry

## Why

The existing `gravity_skip` event is emitted for both the streaming preview and
delivery snapshots. Streaming preview poses are intentionally synthetic and the
preview cloud is already in ARKit gravity/metric space, so that skip is a
successful no-op. Treating it as a delivery failure caused a false report that
gravity and scale alignment had not run.

## What changes

- Emit `preview_skip` only for streaming preview snapshots, with
  `reason=already_arkit_gravity_metric`.
- Emit `final_alignment_result` for every `local_ready` and `refined` delivery
  snapshot, whether alignment succeeds or is skipped.
- Record gravity and scale status, diagnostic counts, applied quaternion,
  applied scale factor, and explicit failure reasons.
- Mark `refined` as authoritative and `local_ready` as its fallback candidate.
- Remove the ambiguous `gravity_skip` and `scale_anchor_skip` events.

## Non-goals

- No change to gravity-alignment or scale-anchor mathematics.
- No change to point, pose, color, capture, matcher, or reconstruction output.
- No activation of `canonical_exact_8192_v1` or any speed experiment.

## Acceptance

- Preview produces `preview_skip` and never a final-result event.
- `local_ready` and `refined` each produce `final_alignment_result`.
- A successful final result records `gravity_status=applied` and either
  `scale_status=applied` or `scale_status=disabled`.
- A fail-open delivery records `skipped` plus the existing diagnostic reason.
- `refined` has `authority=authoritative`; `local_ready` has
  `authority=fallback_candidate`.
- Existing gravity/scale numerical tests remain unchanged and passing.
