# Change: Replace absolute-motion auto capture with a cross-platform motion classifier

## Why

The production trigger treats forward travel as lateral baseline and in-place
rotation as geometry. This creates redundant photos and cannot preserve the
different reconstruction value of orbit, radial, and rotation-only motion.

## What changes

- Classify shutter candidates as geometry, radial bridge, or rotation coverage;
  keep overlap safety as a warning-only predicate.
- Derive lateral/vertical parallax from pose plus an active target and derive
  overlap from runtime intrinsics instead of a fixed distance multiplier.
- Keep rotation-only captures out of the formal geometry-baseline update.
- Aggregate candidate, selected, blocked, and fired outcomes under exactly four
  role keys. Record decisions with no candidate in a separate `no_candidate`
  counter; `none` is not a fifth role.
- Resolve a frame that satisfies both rotation coverage and radial bridge as
  rotation coverage; radial travel must not hide a deliberate turn-in-place
  coverage frame.
- Keep the existing 250 ms duplicate debounce and add the already-ported
  Aether3D 0.92 grayscale-signature redundancy gate. Overlap safety bypasses
  neither backpressure nor the image-evidence gates.
- Accept only backend-neutral inputs shared by ARKit and xrslam.
- Replace the official route's pending manual/automatic shutter FIFO with one
  shared single-flight 12 MP transaction. A busy executor returns
  `busy-not-admitted`; it never stores a delayed capture intent. This change
  explicitly replaces `zero-blocking-manual-shutter-v1`'s immediate-loss-aware
  FIFO and pre-finalization freeze/drain contract on the official route.
- Give every admitted shutter one exactly-once `transactionId`, explicitly name
  `requestPose`, `evidencePose`, and `cardPose`, and keep authoritative data
  outcome separate from best-effort presentation outcome. Atomically publish
  one immutable accepted-photo record as the sole membership authority; album,
  coverage, archive, SfM input, and controller state are replayable projections.
- Make Finish confirmation non-mutating. Only after every confirmation gate
  accepts may one synchronous commit expose the opaque processing surface and
  seal capture admission. An already-active high-resolution transaction reaches
  a bounded data terminal and a rendered-or-suppressed presentation terminal
  before AR is stopped.
- Remove live-SfM health from shutter and Finish authority. A worker crash emits
  a typed processing terminal, preserves accepted evidence, and still permits a
  draft to be saved.
- Give one Dart capture-lifecycle owner exclusive control of the matcher
  capture-active flag, and make the committed processing route unable to reveal
  the old capture root through back or system-pop navigation.

## Non-goals

- No Apple Object Capture, Vision, or private selection API.
- No change to the native reconstruction algorithm.
- No device installation in this change.
- No claim that host tests select a production winner.
