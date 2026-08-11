# Change: Benchmark SQLite exact transform v2

## Why

The accepted `track_delta_v1` candidate improves the exact complete-database
ZPAQ archive by 2.455%, but leaves 30.0 MB of keypoints and 6.9 MB of match
BLOBs untransformed. A page-preserving reversible transform can test their
remaining structure without giving up recovery of the original SQLite bytes.

## What Changes

- Add an experimental `exact_transform_v2` native transform composed of the
  existing descriptor track delta, keypoint byte-plane XOR, and match-index
  delta.
- Add this transform only to host and independent-iPhone benchmark paths.
- Require full-database byte, SHA-256 and SQLite-integrity equality after the
  complete inverse path.
- Stop before phone work unless the host archive is strictly smaller than the
  frozen `track_delta_v1` archive.

## Impact

- Native transform bridge and native smoke tests.
- Host and independent iPhone benchmark harnesses.
- No production archive policy, manifest, resolver, photo codec, capture, or
  training behavior changes.
