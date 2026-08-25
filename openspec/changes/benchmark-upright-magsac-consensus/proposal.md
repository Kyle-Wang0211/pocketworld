# Change: Benchmark MAGSAC consensus with the upright pose model

## Why

PocketWorld's production TVG combines a gravity-constrained upright
three-point pose model with a separate COLMAP homography classification. Calling
generic OpenCV essential-matrix estimation would change both the model and the
robust estimator. The experiment must isolate only the consensus layer.

## What changes

- Introduce a narrow consensus boundary around the existing upright-pose
  hypotheses and squared Sampson residuals.
- Keep the current deterministic inlier-count implementation as the default.
- Add a default-off OpenCV-5.0.0-derived MAGSAC score, termination rule, weight
  function, and local-optimization implementation.
- Add provenance fixtures, incumbent golden tests, deterministic tests, and
  model-boundary tests.
- Add arm-specific TVG telemetry for later same-input comparisons.

## Non-goals

- No generic `findEssentialMat` or generic five-point model.
- No change to PoseLib `relpose_upright_3pt`, gravity, match order, homography,
  watermark, or status mapping.
- No production-default change.
- No phone installation in the initial implementation phase.
- No GC-RANSAC, spatial-neighborhood graph, or graph-cut energy.

## Acceptance

- Default-arm public outputs reproduce the incumbent fixtures exactly.
- Both arms use the same upright minimal solver and residual definition.
- MAGSAC scoring and weights match pinned OpenCV 5.0.0 provenance vectors.
- Both arms are deterministic for the frozen seed and ordered matches.
- Host results are labeled diagnostic and cannot approve production.
- A future phone candidate requires successful tests, license/notice evidence,
  independent review, and separate device authorization.
