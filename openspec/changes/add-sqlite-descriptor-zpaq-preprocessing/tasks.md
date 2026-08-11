## 1. Reproducible experiment contract

- [ ] 1.1 Record app/native/ZPAQ revisions, dirty-diff identity, input hashes,
      hardware, metrics, thresholds, stop rules, and artifact paths.
- [ ] 1.2 Initialize repository-local `uv.lock`, DVC input identity, and local
      MLflow tracking without copying private databases into Git.
- [ ] 1.3 Save and verify the approved ce-optimize hard-metric spec.

## 2. Reversible preprocessor TDD

- [ ] 2.1 Write a native fixture test that requires exact source immutability
      and transpose round trip.
- [ ] 2.2 Run the test and capture the expected RED failure.
- [ ] 2.3 Implement bounded SQLite header, b-tree, record, and overflow parsing.
- [ ] 2.4 Implement transpose inverse and pass the first fixture.
- [ ] 2.5 Add RED/GREEN tests for XOR and modulo-256 delta.

## 3. Structural and adversarial tests

- [ ] 3.1 Add page-size, overflow-boundary, schema, and distribution fixtures.
- [ ] 3.2 Run at least 1000 fixed-seed round trips for every transform.
- [ ] 3.3 Add malformed-page, overflow-cycle, truncation, and cancellation tests.
- [ ] 3.4 Require byte equality, SHA-256 equality, and SQLite integrity.

## 4. ZPAQ benchmark

- [ ] 4.1 Build one immutable measurement harness for raw/transpose/XOR/delta.
- [ ] 4.2 Measure a baseline and persist it before evaluating candidates.
- [ ] 4.3 Run all five real database copies and three repeats per surviving arm.
- [ ] 4.4 Append and verify each result in the experiment log and MLflow.

## 5. Physical iPhone verification

- [ ] 5.1 Build an independent test bundle that cannot access the production
      app container.
- [ ] 5.2 Run all surviving arms through the actual native bridge on isolated
      fixture copies.
- [ ] 5.3 Verify cross-process restore, corruption rejection, cancellation, and
      exact SHA-256/byte/integrity results.
- [ ] 5.4 Admit a candidate only with zero correctness failures, no per-database
      size regression, and at least 10% median improvement over raw ZPAQ.

## 6. Production decision

- [ ] 6.1 Present the complete evidence ledger and either reject all transforms
      or propose a separately versioned v2 production integration.
- [ ] 6.2 Do not alter current raw-ZPAQ production behavior in this change.
