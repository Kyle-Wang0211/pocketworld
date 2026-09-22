# Design

Maintain two baselines: the last successfully captured frame for overlap,
radial-scale, and cadence bookkeeping, and the last formal geometry frame for
effective parallax. A rotation-only or radial capture updates the capture
baseline but not the geometry baseline. A later translated frame is therefore
measured against a real geometry observation and can pair with the saved
coverage candidate.

Project the active target into both frames with each frame's runtime intrinsics.
Combined overlap is `(1-dx/W)*(1-dy/H)`. At or below 70%, emit overlap safety.
At the active target, exact camera-center angle is the effective horizontal or
vertical baseline; use 10°, 12°, or 15° for weak, normal, or strong portable
track health. Below 1.5° stable parallax, a 12° view-axis turn is rotation-only.
If neither geometry nor rotation applies, a 1.2× depth-scale change is a radial
bridge.

Evaluate the four eligibility predicates independently, then select exactly one
fire role with fixed precedence: overlap safety, geometry, rotation coverage,
then radial bridge. The ordering preserves the existing safety and formal
geometry authority while making rotation win the only ambiguous non-geometry
collision: a low-parallax frame that crosses both the 12° turn threshold and
the 1.2× depth-scale threshold is rotation coverage, not radial bridge.

Session candidate, selected, blocked, and fired maps expose exactly four role
keys: `geometry`, `radialBridge`, `rotationCoverage`, and `overlapSafety`.
`none` is not a fifth role: a decision with no selected candidate increments the
separate scalar `no_candidate`. Multiple candidate predicates may be true, so
masked-by-priority counts are retained, but every decision selects at most one
formal role.

The terminal snapshot must satisfy
`decisions = no_candidate + sum(selected_by_role)`. For every formal role,
`selected = fired + sum(blocked_by_reason)`. It must also satisfy
`decision_counts.fire = sum(fired_by_role) = sum(fire_role_counts)` and
`decision_counts.fire = fire_enqueued + fire_enqueue_failed`. Counters are
incremented at the actual predicate, decision, and enqueue-outcome boundaries,
never reconstructed later from sampled geometry.

Normal decisions obey only the 250 ms duplicate debounce; a fixed one-second
interval has no upstream photogrammetric basis. Selection is driven by motion,
geometry, and overlap. Overlap safety may bypass a stretched soft/hard pressure
interval, but not the 250 ms floor. Existing frame/time/tracking/blur guards and
the existing shutter queue remain authoritative.
