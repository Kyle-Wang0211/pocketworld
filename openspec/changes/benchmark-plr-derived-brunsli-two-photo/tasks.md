## 1. Freeze identities and accounting

- [x] 1.1 Freeze the two input files, official PLR revision, primary and
  fallback Brunsli revisions, formal denominator, approved scope, baselines,
  model storage candidates, and stop rules.
- [x] 1.2 Separate Phase 0 provisional raw accounting from Phase 4 `final_M`.
- [x] 1.3 Record that reachable break-even does not authorize automatic
  production codec switching.

## 2. Build reproducible experiment infrastructure

- [x] 2.1 Create the experiment-local `uv.lock`, contract, manifest, DVC stages,
  and MLflow metadata schema.
- [x] 2.2 Implement and test exact integer model accounting and reachability.
- [x] 2.3 Implement and test immutable input identity verification.

## 3. Prove the exact container split

- [x] 3.1 Build the new adapter against unmodified Brunsli v0.1.
- [x] 3.2 Separate reconstruction state from all component coefficients.
- [x] 3.3 Restore both frozen inputs with byte, length, SHA, and coefficient
  equality.
- [x] 3.4 Prove corruption, truncation, wrong version, and count mismatch fail
  before final output publication.
- [x] 3.5 Use the pinned master fallback only if v0.1 fails upstream exactness.

## 4. Preserve evidence and stop

- [x] 4.1 Record source/worktree/toolchain/binary/artifact identities, commands,
  metrics, failures, and deviations in DVC/MLflow-linked evidence.
- [x] 4.2 Validate pytest, DVC reproduction, OpenSpec, and diff hygiene.
- [x] 4.3 Stop before model training, terminal baselines, phone, production, or
  full-project work and request review of the Phase 2/3 plan.

## 5. Correct the pre-Phase-2 contract

- [x] 5.1 Bind the formal scope-2 denominator to the verified 96-photo capture
  and remove count-specific terminal names.
- [x] 5.2 Freeze complete-capture exclusion manifests for the canonical capture
  and its byte-identical `_v2` duplicate.
- [x] 5.3 DVC-track self-contained copies of the two frozen JPEG files.
- [x] 5.4 Register 22 decoder stages, reject more than 24, and require separate
  one-thread CPU encoder/decoder CDF parity.
- [x] 5.5 Validate all contracts without rerunning Phase 1 or measuring JXL.

## 6. Freeze and train the PLR-derived completion

- [x] 6.1 Audit the pinned public PLR codec paths and record the omitted Cb/Cr
  rate terms and undefined codec modules.
- [x] 6.2 Complete and test the same-repository 22-stage Y/Cb/Cr sibling with a
  mature pinned CompressAI entropy bridge and exact integer round-trip.
- [x] 6.3 Register the official-width and scope-2 compact arms, validation-only
  selection formula, training backend, seed, optimizer, and stopping rules.
- [ ] 6.4 Freeze 10,000 verified Open Images CVDF 4:2:0 JPEGs with attribution,
  immutable hashes, exact splits, and DVC identity.
- [ ] 6.5 Materialize deterministic exact-DCT training patches without
  admitting the frozen capture or any byte-identical input.
- [ ] 6.6 Train both registered arms once, preserve latest/best checkpoints and
  all epoch metrics, and select one arm using only the registered validation
  accounting formula.
- [ ] 6.7 In separate one-thread CPU processes, prove coefficient equality and
  integer-CDF trace parity before any frozen-pair terminal comparison.
