# Alignment Telemetry Stage Split Design

The authoritative specification is
`openspec/changes/split-alignment-telemetry-v1/`.

The approved design makes stage identity explicit. Streaming preview emits
`preview_skip(reason=already_arkit_gravity_metric)` because it is already in
ARKit gravity/metric space. `local_ready` and `refined` each emit a complete
`final_alignment_result`; refined is authoritative and local-ready is the
fallback candidate. Gravity and scale mathematics and all delivered model data
remain unchanged.
