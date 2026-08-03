## 1. Freeze identities and accounting

- [x] 1.1 Freeze the two input files, official PLR revision, primary and
  fallback Brunsli revisions, formal denominator, approved scope, baselines,
  model storage candidates, and stop rules.
- [x] 1.2 Separate Phase 0 provisional raw accounting from Phase 4 `final_M`.
- [x] 1.3 Record that reachable break-even does not authorize automatic
  production codec switching.

## 2. Build reproducible experiment infrastructure

- [ ] 2.1 Create the experiment-local `uv.lock`, contract, manifest, DVC stages,
  and MLflow metadata schema.
- [ ] 2.2 Implement and test exact integer model accounting and reachability.
- [ ] 2.3 Implement and test immutable input identity verification.

## 3. Prove the exact container split

- [ ] 3.1 Build the new adapter against unmodified Brunsli v0.1.
- [ ] 3.2 Separate reconstruction state from all component coefficients.
- [ ] 3.3 Restore both frozen inputs with byte, length, SHA, and coefficient
  equality.
- [ ] 3.4 Prove corruption, truncation, wrong version, and count mismatch fail
  before final output publication.
- [ ] 3.5 Use the pinned master fallback only if v0.1 fails upstream exactness.

## 4. Preserve evidence and stop

- [ ] 4.1 Record source/worktree/toolchain/binary/artifact identities, commands,
  metrics, failures, and deviations in DVC/MLflow-linked evidence.
- [ ] 4.2 Validate pytest, DVC reproduction, OpenSpec, and diff hygiene.
- [ ] 4.3 Stop before model training, terminal baselines, phone, production, or
  full-project work and request review of the Phase 2/3 plan.
