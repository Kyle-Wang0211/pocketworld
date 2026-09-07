---
title: Replicate pinned upstream algorithms before product adaptation
date: 2026-08-27
category: workflow-issues
module: automatic capture and reconstruction algorithms
problem_type: workflow_issue
component: development_workflow
severity: critical
applies_when:
  - "Adopting or changing an external vision, VIO, SfM, robust-estimation, or keyframe-selection algorithm"
  - "Claiming that production behavior reproduces an upstream project or paper"
tags: [upstream-reproduction, provenance, auto-capture, keyframe-selection, robust-estimation, no-self-invention]
---

# Replicate pinned upstream algorithms before product adaptation

## Context

The 2026-08-27 automatic-capture audit found a repeated workflow failure: a
small part of an upstream method was copied, a causal product approximation was
added for the missing stages, and the combined result was then described as a
complete or equivalent reproduction. Local comments, local tests, and an old
adoption ledger subsequently repeated the claim, creating a self-confirming
audit loop.

The concrete status at the time of this learning was:

- `lib/official_capture/alicevision_motion_segment.dart` explicitly described
  the implementation as a diagnostic causal adapter that cannot revisit past
  preview frames. `lib/official_capture/auto_capture_controller.dart` still
  consumed `currentSelected` as a production gate. That is a PocketWorld
  adapter, not AliceVision Smart Selection.
- `lib/official_capture/continuous_feature_tracks.dart` reproduced the VINS
  normalized-parallax and under-20 keyframe predicates, but implemented its own
  reduced Dart tracker rather than the complete VINS feature-tracker front end.
- No RTAB-Map geometric-registration inlier-ratio implementation was present in
  the automatic-capture path.
- Every implementation item in
  `openspec/changes/benchmark-upright-magsac-consensus/tasks.md` remained
  unchecked. MAGSAC++ was a specification, not production code. GC-RANSAC was
  deliberately excluded from that experiment.

## Guidance

### Upstream-first is the default

When a selected upstream algorithm is publicly reproducible and commercially
usable, reproduce its complete pinned behavior before proposing a local
substitute. Difficulty, implementation time, or an intuition that a simpler
rule is "equivalent" is not evidence for omission. PocketWorld does not assume
that a local invention is better than a mature specialist implementation.

Direct source copying still requires a revision and commercial-license audit.
When the code license cannot be shipped, reproduce the published semantics
through a clean-room implementation and retain provenance tests; do not copy
restricted code and do not silently replace the method with an invention.

### A full-reproduction claim requires a method map

Before implementation, enumerate every upstream stage, input, state transition,
parameter, termination rule, output, and test vector. Each row receives exactly
one status:

- `exact_upstream`: unmodified pinned code or byte/behavior-equivalent port;
- `semantic_port`: separately written code proven against pinned upstream
  vectors and edge cases;
- `product_adapter`: necessary integration behavior that is not upstream;
- `not_implemented`: missing upstream behavior.

Any `product_adapter` or `not_implemented` row blocks the words "complete",
"official reproduction", "faithful", and "equivalent" for that arm. Local
comments and local tests cannot establish upstream fidelity; the oracle is the
pinned upstream source, its fixtures, and an end-to-end behavior comparison.

### These algorithms mostly complement one another

| Stage | Upstream responsibility | Composition rule |
|---|---|---|
| VINS feature tracker and keyframe test | Undistortion, LK tracking, outlier rejection, track management, compensated parallax, low-track keyframe trigger | Supplies trustworthy continuous tracks and keyframe evidence to later selection; it does not replace AliceVision segment selection. |
| AliceVision Smart Selection | Accumulate motion, close subsequences, score all historical candidates by sharpness and temporal position, select a frame | Consumes tracked motion and image quality. A true live reproduction requires retaining selectable historical image candidates; a causal current-frame shortcut is an adapter. |
| RTAB-Map registration health | Evaluate robust geometric-registration inliers against the previous keyframe/registration state | Can provide an early keyframe trigger when geometric support collapses. Its `0.3` ratio cannot be replaced by raw LK track survival. |
| MAGSAC++ | Robust quality score, weights, termination, and compatible local optimization around a model estimator | Operates after feature correspondence and model hypotheses; it can improve the same geometry used by tracking-health or reconstruction gates. |
| GC-RANSAC | Spatial-coherence graph-cut local optimization / consensus refinement | May complement a MAGSAC score inside one explicitly specified robust-estimation pipeline, but it also owns part of the same consensus/LO stage. It must not be stacked as a second independent model authority without a pinned composition and single-variable evidence. |

Primary references:

- [AliceVision KeyframeSelector implementation](https://github.com/alicevision/AliceVision/blob/develop/src/aliceVision/keyframe/KeyframeSelector.cpp)
- [VINS-Mono keyframe predicate](https://github.com/HKUST-Aerial-Robotics/VINS-Mono/blob/master/vins_estimator/src/feature_manager.cpp)
- [VINS-Mono feature tracker](https://github.com/HKUST-Aerial-Robotics/VINS-Mono/blob/master/feature_tracker/src/feature_tracker.cpp)
- [RTAB-Map odometry parameters](https://github.com/introlab/rtabmap/blob/master/corelib/include/rtabmap/core/Parameters.h)
- [OpenCV USAC implementation](https://github.com/opencv/opencv/tree/5.0.0/modules/calib3d/src/usac)

### Product integration is separate from algorithm semantics

Dart may own cross-platform orchestration, state, telemetry, and promotion
gates while a portable C++ core owns heavy upstream math. That language boundary
does not authorize rewriting the algorithm. Swift and Kotlin remain transport
adapters. Any unavoidable product behavior, including real-time buffering,
12-megapixel shutter timing, or UI receipts, is documented as a product adapter
outside the upstream algorithm map.

## Why This Matters

Partial replicas create two failures at once: the product misses mature upstream
behavior, and the label prevents later audits from noticing what is absent. In
the automatic-capture incident, the false-equivalence loop helped preserve a
causal selection shortcut and invert the VINS under-20 semantic, producing rapid
high-resolution rejection requests and disruptive UI failures.

## When to Apply

- Before adding or changing any capture, VIO, SfM, matching, robust-estimation,
  filtering, or reconstruction algorithm.
- Before calling a branch, experiment, or production behavior "official",
  "faithful", "complete", or "equivalent".
- When two upstream methods appear complementary: map their stage ownership
  first, then reproduce each without allowing two components to own the same
  state or decision implicitly.

## Examples

Incorrect: copy AliceVision's 10% accumulated-motion threshold, fire the current
frame causally, and call it Smart Selection.

Correct: retain the segment's eligible image candidates, close the segment under
the pinned upstream rule, apply the pinned sharpness and temporal weighting, and
select the actual historical candidate. If the product cannot yet retain a
selectable high-resolution history, mark the feature `not_implemented`; do not
rename a causal fallback as the upstream method.

Incorrect: feed raw LK track survival into RTAB-Map's `0.3` threshold.

Correct: reproduce RTAB-Map's geometric registration and compute the ratio over
its registration inliers and reference feature population.

## Prevention

- Every algorithm change must add a pinned method map and upstream provenance
  vectors before implementation. Reviews fail closed when a stage is missing,
  a local constant lacks an upstream source, or a product adapter is labeled as
  upstream behavior.

## Related

- `docs/ALICEVISION_ADOPTION_LEDGER_2026-08-25.md`
- `openspec/changes/replace-auto-capture-motion-classifier/`
- `openspec/changes/benchmark-upright-magsac-consensus/`

