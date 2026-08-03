## 1. Freeze evidence and scope

- [ ] 1.1 Record the exact 2016/2015 method map, accessible source hashes,
      implementation gaps, license components, and commercial-use verdict.
- [ ] 1.2 Freeze the current repository identity, dirty-diff hash, original
      project manifest, saved baseline artifact hash, selection rule, metrics,
      and stop conditions.
- [ ] 1.3 Validate this OpenSpec change strictly.

## 2. Minimum joint-unit TDD

- [ ] 2.1 Add RED tests for deterministic pair selection and complete input
      identity.
- [ ] 2.2 Implement a read-only extractor for two exact JPEGs and their pose,
      track, match, descriptor, and sparse-point slice.
- [ ] 2.3 Add RED tests for exact JPEG coefficient/header round trips and
      unsupported-input rejection.
- [ ] 2.4 Implement versioned exact JPEG logical framing using the existing
      libjpeg coefficient boundary.
- [ ] 2.5 Add RED tests for feature-cost tree state, global/local compensation,
      frequency selectors, and exact residual inversion.
- [ ] 2.6 Implement only the prediction stages supported by the method map;
      mark and stop on missing fidelity details.

## 3. Complete byte accounting

- [ ] 3.1 Add RED tests requiring models, graph edges, selectors, mappings,
      indexes, manifests, and checksums in persisted size.
- [ ] 3.2 Implement the minimum WorldPack v2 dependency group and fail-closed
      reader.
- [ ] 3.3 Restore both JPEGs and all semantic records; compare byte/SHA/bit/order
      identity and reject registered corruptions.

## 4. Execute and decide

- [ ] 4.1 Reference the saved incumbent bytes without executing its encoder.
- [ ] 4.2 Run the candidate exactly once after focused tests pass.
- [ ] 4.3 Stop and retain evidence if the candidate is not strictly smaller.
- [ ] 4.4 If it wins, create a separate eight-photo expansion plan; do not run a
      complete project or access the phone in this change.

## 5. Verification

- [ ] 5.1 Run focused tests, strict OpenSpec validation, manifest verification,
      and deterministic result checks.
- [ ] 5.2 Inspect only owned files and report evidence, deviations, and verdict.
