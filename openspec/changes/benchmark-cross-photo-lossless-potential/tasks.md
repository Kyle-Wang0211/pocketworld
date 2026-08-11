## 1. Freeze experiment identity

- [x] 1.1 Record app revision, dirty-worktree identity, tool versions, metrics,
      thresholds, stop rules, and artifact locations.
- [x] 1.2 Record the ordered 37-JPEG manifest and all JPEG/pose/PLY hashes.
- [x] 1.3 Create repository-local uv, DVC, MLflow, and ce-optimize identities.

## 2. Exact JPEG coefficient TDD

- [x] 2.1 Write a failing test for coefficient extraction and exact JPEG
      reconstruction.
- [x] 2.2 Implement the minimum libjpeg-turbo coefficient container.
- [x] 2.3 Verify all 37 source JPEGs round-trip byte-for-byte.
- [x] 2.4 Add corruption, truncation, and deterministic-output tests.

## 3. SfM predictor TDD

- [x] 3.1 Write failing synthetic tests for pose projection, block voting,
      component scaling, and deterministic fallback.
- [x] 3.2 Implement PLY/pose loading and target-to-reference block maps.
- [x] 3.3 Write failing tests for anchor/residual token round trips.
- [x] 3.4 Implement independent group-size-4 and group-size-8 archives.

## 4. Immutable measurement

- [x] 4.1 Measure exact JXL effort-10 baseline bytes.
- [x] 4.2 Run group-size-4, persist and verify its result immediately.
- [x] 4.3 Run group-size-8, persist and verify its result immediately.
- [x] 4.4 Run fixed-seed random-access and corruption audits.
- [x] 4.5 Log parameters, metrics, artifacts, and verdict in local MLflow.

## 5. Stop decision

- [x] 5.1 Require zero exactness failures and real geometry coverage.
- [x] 5.2 Return `reject-before-phone` if both ratios are below 2.165x.
- [x] 5.3 Build no phone bundle unless a verified arm reaches 2.165x.
- [x] 5.4 Delete large temporary outputs and retain only hashes and metrics.
