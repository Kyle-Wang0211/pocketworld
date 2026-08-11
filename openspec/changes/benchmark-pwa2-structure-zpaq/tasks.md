## 1. Contract

- [ ] 1.1 Freeze input, revisions, block configuration, metrics, exclusions,
      exactness gates, size gate, and stop rules.
- [ ] 1.2 Strictly validate the OpenSpec change.

## 2. Logical format TDD

- [ ] 2.1 Add RED fixture tests for complete typed-row preservation.
- [ ] 2.2 Implement deterministic schema/metadata and bounded member framing.
- [ ] 2.3 Add RED tests for root/residual/literal descriptor reconstruction.
- [ ] 2.4 Implement the deterministic verified-match forest and 128-lane blocks.
- [ ] 2.5 Add RED tests for keypoint/match column blocks and random reads.
- [ ] 2.6 Implement exact numeric-column blocks and fail-closed validation.

## 3. ZPAQ benchmark TDD

- [ ] 3.1 Add RED contract tests for pinned ZPAQ member compression and complete
      byte accounting.
- [ ] 3.2 Implement compressed-member index, decode verification, and canonical
      logical comparison.
- [ ] 3.3 Make focused tests green without modifying production paths.

## 4. Execution

- [ ] 4.1 Run Arm B once on the frozen database and retain only compact evidence.
- [ ] 4.2 Stop before phone work when valid bytes exceed 111,961,726.
- [ ] 4.3 If the gate passes, report that a separate phone task is required; do
      not install in this change.

## 5. Verification

- [ ] 5.1 Run focused native tests, strict OpenSpec validation, DVC status, and
      deterministic result checks.
- [ ] 5.2 Inspect only newly owned files and report the evidence-backed verdict.
