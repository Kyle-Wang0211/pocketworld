# Change: Benchmark a joint semantic WorldPack v2

## Why

The existing archive chooses codecs per file and therefore cannot exploit
shared geometry among photographs, poses, tracks, descriptors, matches, and
point clouds. Previous cross-photo experiments were not faithful reproductions
of the published feature/spatial/frequency-domain collection method, and PWA2
did not combine the current full-coverage descriptor and graph winners.

## What Changes

- Add an experiment-only typed semantic project schema.
- Add a paper-fidelity and commercial-use gate before encoding work.
- Benchmark one deterministic two-photo cross-modal unit before any larger run.
- Preserve every JPEG byte and every registered logical numeric bit and order.
- Count all prediction, model, mapping, index, manifest, and checksum bytes.
- Reuse the saved complete baseline; never recompute it for this experiment.
- Keep production code, the production bundle, and the phone untouched.

## Impact

Only new OpenSpec, documentation, experiment, and host-test files are in scope
for the first stage. A host winner requires a separate physical-iPhone change.
