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

Normal decisions obey only the 250 ms duplicate debounce; a fixed one-second
interval has no upstream photogrammetric basis. Selection is driven by motion,
geometry, and overlap. Overlap safety may bypass a stretched soft/hard pressure
interval, but not the 250 ms floor. Existing frame/time/tracking/blur guards and
the existing shutter queue remain authoritative.
