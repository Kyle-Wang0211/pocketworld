# Compression Fidelity Audit and Micro-Supplement Plan

> **Scope:** host-only evidence audit and minimum-unit supplements. Do not change production code, build/install the app, access the phone, or run 100 MB/full-project benchmarks.

**Goal:** Reclassify every previously discussed compression route using durable repository evidence and official upstream semantics. Any old winner/loser claim that cannot be reproduced from a pinned official implementation is withdrawn. A missing official configuration that previously influenced a decision is supplemented on one complete minimum data unit only.

**Repository identity:** `/Users/kaidongwang/Developer/pocketworld` at `13d2a4f05d491464c537a9135496eccaa05c2358`, with a shared dirty worktree that must not be reset, stashed, cleaned, staged, or reformatted globally.

**Immutable inputs:**

- One original JPEG from capture `cap_1785512421333592`, identified by path, byte count, and SHA-256 before any photo-codec supplement.
- One complete `descriptors` SQLite row (`rows=8192`, `cols=128`, exactly 1,048,576 bytes), extracted read-only from the frozen 198,983,680-byte database whose SHA-256 is `0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0`.

**Audit classifications:**

1. `faithful_official`: pinned official source/API/CLI, official data model and parameters, all persisted bytes counted, official decode plus byte/SHA verification.
2. `faithful_subset`: the measured arm faithfully represents one documented official mode, but does not test the project's strongest or recommended configuration.
3. `invalid_reproduction`: local proxy, wrong data type/layout/filter order, omitted model/index bytes, or a claimed paper reproduction that omits essential stages.
4. `evidence_missing`: an experiment was said to have run, but no durable input identity, command, revision, output, and decode evidence remains.
5. `mentioned_not_run`: proposal/research only; it must not be called a failure.
6. `blocked_no_official_route`: no official runnable implementation or commercial-use-compatible route exists for the claimed reproduction.
7. `validated_internal`: PocketWorld-owned algorithm with no external upstream; the local frozen implementation and its declared verification contract are complete.

**Fidelity checks per measured scheme:** exact upstream revision, license file identity, official entry point, exact parameters, correct typed shape/layout, complete persisted byte accounting, decoder independence from encoder-only state, immutable input hash, byte equality, SHA-256 equality, corruption rejection where the format supports it, and a narrow statement of what the result can prove.

## Execution

1. Inventory repository results, source, plans, OpenSpec records, and Git history. Separate actual runs from proposals.
2. Verify upstream semantics from primary official repositories/documentation.
3. Preserve already-correct results for libjxl JPEG reconstruction, libzpaq method 5, Pcodec standalone files, local reversible transforms, and today's corrected OpenZL ACE/B2ND micro-run when their evidence passes the checklist.
4. Withdraw unsupported global claims from partial OpenZL/Blosc2 screens and the local cross-photo approximations.
5. Supplement only prior decision-bearing gaps with official tools on the minimum unit. Stop after one exact encode/decode cycle; do not automatically repeat or enlarge.
6. Write a machine-readable inventory and a Chinese audit report that lists what remains true, what is invalidated, and what has never been tested.
7. Delete only temporary source/build/output scratch after hashing the retained result. Keep failed-run diagnostics and small evidence files.

## Stop conditions

- Stop a candidate immediately if its official source identity, license, decoder path, or exact-restoration semantics cannot be established.
- A failed build is a tooling diagnostic, not a compression failure.
- A minimum-unit loss does not prove the entire upstream project can never win; it only blocks automatic scale-up for the tested official mode and input type.
- Host evidence cannot promote a production winner. Any future production choice still requires the physical-iPhone production pipeline.
