# Change: Benchmark global PTOL on the physical iPhone

## Why

The installed production framework already exposes
`OFFICIAL_AETHER_GLOBAL_PTOL`, but the knob has never been evaluated. Ceres
2.2.0 defaults `parameter_tolerance` to `1e-8`; PocketWorld inherits COLMAP's
explicit `0.0`. A same-input phone A/B is required before making any claim
about speed or quality.

## What changes

- Add a durable experiment contract for build 32 and the frozen 136-frame
  capture.
- Run a zero-rebuild ABAB direction screen through the installed production
  resume path.
- If the direction is promising, run a complete ABAB quality comparison in
  separate bundle `com.kyle.PocketWorld.PtolBench`, linked to the same native
  framework and using the same production reconstruction classes.
- Preserve raw reports, BA-round telemetry, effective environment receipts,
  input and binary identities, thermal evidence, and invalid runs.
- Restore the shared environment file to its exact pre-run state.

## Non-goals

- No rebuild or installation for the direction screen.
- No in-place production application update at any stage.
- No local-BA tolerance change.
- No sweep of `1e-7` or `1e-6`.
- No MAGSAC, TVG, matcher, capture, AR display, or UI change.
- No automatic promotion of `1e-8` to a shipping default.

## Acceptance

- Both arms use the same installed build and hash-verified capture.
- An environment receipt proves the effective PTOL value before native work.
- Every arm produces a complete `rebuild_full` report and matching BA telemetry.
- Registered-image count is unchanged and numeric quality stays inside the A/A
  noise floor.
- The speed effect exceeds twice the paired A/A noise floor to be classified as
  promising.
- Direction-screen results remain non-promotable.
- The separate-bundle stage persists per-arm PLY and complete quality evidence
  before a candidate may be presented for a shipping decision.
