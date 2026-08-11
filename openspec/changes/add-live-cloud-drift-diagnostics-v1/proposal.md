# Change: Add live-cloud drift diagnostics v1

## Why

The live AR point cloud can appear coherently displaced from the camera image
by more than 10 cm. Existing logs persist tracking-state changes, but the ARKit
anchor transform is only printed to the unified log and the live-cloud display
path has no receive/render generation identity. The streaming SfM path also
does not persist how far local BA moved camera centers away from their immutable
ARKit seeds.

## What changes

- Persist the full subject-anchor transform delta relative to lock time and the
  previous sample, with observation-only 5 cm and 10 cm severity labels.
- Give every live-cloud receive and native render application a monotonic
  generation, source, version, point count, and timestamp.
- Persist a robust summary of optimized camera-center deltas relative to the
  immutable ARKit camera centers after each streaming local BA publication.
- At every post-local-BA and successful post-global-BA native model state,
  persist the robust best BA-to-ARKit Sim3 and its inverse.
- Across consecutive native model states, persist exact same-ID Point3D
  displacement statistics and ID churn.
- Emit exact app, Dart diagnostics-contract, and native diagnostics-contract
  identities; record final signed binary hashes in the update evidence ledger.

## Non-goals

- No point-cloud transform, anchoring correction, smoothing, stale-generation
  suppression, UI warning, capture gate, matcher change, BA change, or output
  filtering.
- No change to final PLY, registered poses, track topology, colors, or capture
  scheduling.
- No dependency, Flutter, Xcode, or package upgrade.

## Acceptance

- Translation severity is `normal` below 0.05 m, `warning` from 0.05 m to
  below 0.10 m, and `severe` at or above 0.10 m; labels never affect behavior.
- Every SfM live-cloud snapshot logs receive, compute completion, channel send,
  and native render application with the same generation/source/version.
- Every successful streaming local BA logs camera-center comparison count,
  component-wise median delta, latest delta, and p50/p90/max norm.
- Every published local/global snapshot logs a valid robust Sim3 or an explicit
  invalid reason, and every consecutive snapshot logs exact same-ID displacement
  and churn without altering the model.
- A capture log identifies the signed app marker, Dart contract, and native
  contract; the deployment ledger identifies Runner, App.framework, and
  PWOfficialSfm hashes.
- Focused tests demonstrate the new contracts and existing capture/reconstruction
  tests remain passing.
