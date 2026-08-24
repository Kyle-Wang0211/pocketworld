# Full-resolution A/B/C dense PLY comparison

Date: 2026-08-21

## Objective

Produce an honest, same-capture, three-pane browser comparison of the complete
dense point clouds for these pose pipelines:

- **A — refined:** cap41 dense reconstruction driven by the final model after
  the finish-time stage-1/stage-2 iterative global BA.
- **B — current live:** cap41 dense reconstruction driven by `live_end` after
  the shipped capture-time local BA path, with rolling global BA disabled.
- **C — rolling-global live:** cap41 dense reconstruction driven by a new
  `live_end` replay with capture-time rolling global BA enabled through the
  implementation's actual environment gate,
  `OFFICIAL_AETHER_INCREMENTAL_GLOBAL_BA=1`.

The historical “journal/frozen-input C” from `PREREG.md` is out of scope. It
was never run and has no PLY. This document uses C only for the rolling-global
live arm approved by the user.

## Immutable comparison contract

All three arms use the same cap41 capture, the same 98-frame intersection, the
same source photos, CasDiffMVS checkpoint, frame IDs, deterministic noise,
resolution, view count, and official fusion parameters. Only the sparse model
that supplies pose, depth range, and ordered source views may differ.

Existing immutable inputs:

- A PLY: `dense_A.ply`, SHA-256
  `9d0c1cc5cbad53805db1a9868a52785fd12d7c0b0c6fff3ae145a96bfaec7d27`,
  14,428,563 vertices.
- B PLY in native live gauge: `dense_B.ply`, SHA-256
  `be0f6213b39ba81aa9ef3aa348ca3b79b4e6df216c87ffbc71b6f46e96b2419b`,
  14,146,781 vertices.
- B aligned to A: `aligned_B.ply`, SHA-256
  `6845a8870c8ff41ffeb9c13281c1394a782df93ea85686db08ca4aea1f40be68`.

C must be generated from an `incr=on` replay. Existing B must not be relabeled
as C, and no placeholder or synthetic point cloud is allowed.

## C data flow

1. Verify the replay database, fed-frame manifest, photos, checkpoint, replay
   executable, scripts, and existing A/B artifacts are resident (`ls -lO`) and
   hash them before running.
2. Replay cap41 with `OFFICIAL_AETHER_INCREMENTAL_GLOBAL_BA=1` and the existing
   live-pose dump instrumentation. Confirm the log reports the gate as enabled
   and reports at least one incremental global BA; otherwise stop.
3. Use the resulting C `live_end` sparse model to run the same existing dense
   chain as A/B:
   `colmap_input.py -> run_arm_lever.py -> fuse_arm.py -> official filter_depth`.
4. Enforce the same 98 image names, deterministic seed policy, 768x576 input,
   `num_view=10`, and existing official fusion parameters.
5. Compute a new C-to-A Umeyama similarity from matched camera centers. Do not
   reuse the B-to-A transform. Apply it to C to create `aligned_C.ply` while
   preserving every RGB byte.
6. Record commands, environment, input/output hashes, image-name manifest,
   point counts, transform, residuals, timings, and deviations in a provenance
   manifest beside the artifacts.

This is a host comparison only. It does not change, rebuild, install, launch,
or configure the production iPhone application.

## Full-resolution viewer

The viewer reuses the established implementation in `export_bins.py` and
`build_page_fullres.py`. Each aligned PLY is exported in full to the existing
`.pos/.col` representation. Exported record counts must exactly equal the PLY
vertex counts; no random, uniform, voxel, or display-time sampling is allowed.

The page is served as a directory over local HTTP. It has three equal-width
panes in this order: A refined, B current live, C rolling-global live. Rendering
and interaction code is copied from `compare_lever1.html` /
`compare_dense_B_vs_A.html`:

- one shared camera for all three canvases;
- left-drag rotation;
- right-drag pan;
- wheel zoom;
- one shared point-size slider;
- true RGB colors, dark background, circular WebGL points, depth testing;
- the existing full-resolution float32 `.pos` / uint8 `.col` GPU buffer path.

The small self-contained comparison pages use quantized positions, but the
approved full-resolution path does not: `export_bins.py` writes unsampled
float32 XYZ. Changing that format would be a new renderer/data protocol and is
out of scope.

No new camera model, point renderer, level-of-detail algorithm, culling rule,
progressive sampler, color transform, background switcher, preset-view system,
or fullscreen interaction will be invented. Only the data plan, three-column
layout, factual labels, and provenance panel may change.

Each pane shows its real full vertex count and pose lineage. The page must not
claim quality, scale truth, or production readiness beyond measured evidence.

## Failure handling and safety

- Stop before reading any `dataless` critical input. Do not materialize it
  implicitly.
- Stop if free disk space is insufficient for C depth intermediates, C PLY,
  aligned C, and all six full-resolution viewer binaries.
- Stop if the rolling-global env gate is not observed in replay logs, no
  incremental solve fires, frame-name parity fails, deterministic inputs drift,
  fusion settings differ, PLY size/header checks fail, or alignment is invalid.
- Never substitute a sparse cloud, another capture, a checkpoint named “C”, or
  a journal/frozen-input result for the approved rolling-global C.
- Long commands use hard timeouts and write logs to files. MPS inference stays
  single-frame serial.

## Verification

Deterministic checks:

1. Verify every PLY header, byte length, RGB properties, SHA-256, and vertex
   count.
2. Verify A/B hashes remain unchanged.
3. Verify C replay telemetry proves rolling global BA ran.
4. Verify all three dense arms use the identical ordered 98-frame manifest and
   fixed dense parameters.
5. Verify C-to-A alignment on matched camera centers and RGB-byte preservation.
6. Verify each `.pos` and `.col` record count equals its source PLY vertex count.
7. Serve the page locally and verify three WebGL canvases, zero console errors,
   exact displayed counts, point-size control, rotation, pan, zoom, and shared
   camera motion across all panes.
8. Perform a visual check at the known floor-collapse region and at an overall
   room view. The user remains the final visual judge.

## Deliverables

- C replay output and logs.
- `dense_C.ply` in C's native gauge and `aligned_C.ply` in A's gauge.
- A/B/C full-resolution `.pos/.col` assets.
- Three-pane full-resolution comparison page and local launch command.
- Provenance manifest with hashes, counts, transforms, timings, and deviations.
- Browser verification evidence.
