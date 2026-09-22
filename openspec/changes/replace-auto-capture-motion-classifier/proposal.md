# Change: Replace absolute-motion auto capture with a cross-platform motion classifier

## Why

The production trigger treats forward travel as lateral baseline and in-place
rotation as geometry. This creates redundant photos and cannot preserve the
different reconstruction value of orbit, radial, and rotation-only motion.

## What changes

- Classify every candidate as geometry, radial bridge, rotation coverage, or
  overlap safety using pure Dart geometry.
- Derive lateral/vertical parallax from pose plus an active target and derive
  overlap from runtime intrinsics instead of a fixed distance multiplier.
- Keep rotation-only captures out of the formal geometry-baseline update.
- Aggregate candidate, selected, blocked, and fired outcomes under exactly four
  role keys. Record decisions with no candidate in a separate `no_candidate`
  counter; `none` is not a fifth role.
- Resolve a frame that satisfies both rotation coverage and radial bridge as
  rotation coverage; radial travel must not hide a deliberate turn-in-place
  coverage frame.
- Keep only the existing 250 ms duplicate debounce in normal operation;
  selection remains motion-driven, while overlap safety may bypass a stretched
  soft/hard backpressure interval.
- Accept only backend-neutral inputs shared by ARKit and xrslam.

## Non-goals

- No Apple Object Capture, Vision, or private selection API.
- No change to the native reconstruction algorithm.
- No device installation in this change.
- No claim that host tests select a production winner.
