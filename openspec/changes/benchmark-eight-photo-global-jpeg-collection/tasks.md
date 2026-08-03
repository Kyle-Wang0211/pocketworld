## 1. Freeze

- [x] 1.1 Record the eight-photo manifest, all hashes, saved reference bytes,
      graph statistics, repository identity, metrics, and one-run stop rules.
- [x] 1.2 Record method evidence, implementation substitutions, and commercial
      licensing limitations.
- [x] 1.3 Validate this OpenSpec change strictly.

## 2. TDD

- [ ] 2.1 Add RED tests for fixed eight-photo selection and complete 28-edge
      graph extraction.
- [ ] 2.2 Implement read-only collection extraction and deterministic graph
      construction.
- [ ] 2.3 Add RED tests for hybrid predictor modes, fixed-point affine models,
      typed frequency streams, and exact inversion.
- [ ] 2.4 Implement the smallest deterministic codec satisfying those tests.
- [ ] 2.5 Add RED tests for complete byte accounting, bounded dependency paths,
      exact JPEG restoration, and fail-closed corruption handling.
- [ ] 2.6 Implement the versioned archive and one-shot runner.

## 3. Execute once

- [ ] 3.1 Verify tests and manifests without encoding any real candidate.
- [ ] 3.2 Reference 18,453,828 saved JXL bytes; never run the JXL encoder.
- [ ] 3.3 Run the frozen real eight-photo candidate exactly once.
- [ ] 3.4 Preserve result, artifact identity, per-stream accounting, exactness,
      resource metrics, and verdict.

## 4. Verify

- [ ] 4.1 Re-run focused tests without rerunning the real benchmark.
- [ ] 4.2 Validate OpenSpec and DVC/MLflow evidence identities.
- [ ] 4.3 Inspect only owned files and report whether saved JXL and the 31%
      paper-derived target were reached.
