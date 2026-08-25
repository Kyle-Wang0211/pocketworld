# Design

`EstimateUprightRelativePoseV1` continues to own input validation, gravity and
bearing normalization, deterministic sampling, and PoseLib's upright
three-point hypothesis generation. A focused consensus component receives each
hypothesis and its ordered squared Sampson residuals.

The incumbent implementation retains count-first, error-sum tie-breaking and
the current dynamic trial bound. The experiment adds the pinned OpenCV 5.0.0
MAGSAC quality, termination, weighting, and local-optimization behavior where
the upright model supplies the necessary estimator operations. Any model-level
operation that OpenCV performs but the upright solver cannot faithfully expose
is recorded as an explicit deviation and blocks claims of exact reproduction.

An environment selector at the C++ layer enables the experiment. Its absence
preserves incumbent behavior. The separate homography pass is untouched. The
implementation first lands with tests and host diagnostic replay only; no
shipping default or device bundle changes in this change.
