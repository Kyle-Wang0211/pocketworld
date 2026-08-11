# Proposal: Benchmark dense and global cross-photo exact JPEG forests

## Why

The currently verified complete-project estimate saves only about 25%. Photos
are roughly 68% of a representative project, while the previous cross-photo
prototype predicted only 12.85% of DCT blocks and stopped early. The next
experiment must run the complete frozen approximately-100-MiB JPEG set and test high-coverage cross-frame
prediction without relaxing byte-exact restoration.

## What Changes

- Add three host-only research arms over one 107,649,656-byte ordered JPEG set
  and its existing 88,409,901-byte exact-JXL members.
- Arm A uses an OpenCV dense-flow grid plus local DCT-block selection.
- Arm B uses a Faiss group-local global DCT-block similarity forest.
- Arm C audits and, only if commercially permitted and reproducible, runs the
  official ROMP/learned exact-JPEG implementation.
- Count roots, headers, models, flow grids, selectors, parent maps, manifests,
  and every other side byte in complete archive size.
- Decode and hash every JPEG after every completed arm.

## Impact

Experiment files only. No production code, phone bundle, project data, or
archive policy changes.
