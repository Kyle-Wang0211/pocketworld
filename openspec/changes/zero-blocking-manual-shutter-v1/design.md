# Design

## Admission and execution

`ManualCaptureQueue` stores only a monotonic ticket ID and tap timestamp. The
tap callback performs readiness/cap checks, enqueues, and returns. A scheduled
single worker executes tickets in FIFO order through the existing
`CaptureSession.captureSinglePhoto()` transaction.

The queue never owns JPEG bytes, decoded images, `CVPixelBuffer`, pose arrays,
or descriptors. The existing capture session remains the owner of the native
4032x3024 transaction and persists the canonical original before album/SfM
acknowledgement.

## Lifecycle

- Finish freezes admission and drains. Native retry is bounded, so permanent
  camera failure becomes an explicit ticket error rather than an infinite wait.
  During Finish, the first error cancels only unstarted tickets and aborts
  finalization; verified originals remain intact and capture can resume.
- Background marks manual transactions suspended before stopping ARKit. If the
  active native request unwinds, its attempt is not charged and the same ticket
  waits without retry churn. Successful ARKit resume releases it.
- Discard prevents re-entry, cancels pending tickets, stops the capture retry
  loop, drains the active owner, and only then recursively deletes the bundle.
- Widget disposal follows the same ownership order asynchronously.

## UI cost

The capture bar reads `OfficialProjectPhotoAlbum.latestPath` in O(1) rather
than synchronously statting and sorting all photo paths on every rebuild. Heavy
reconstruction work remains in the existing backend queue; this change does not
claim to solve the separate tail O(N) curve.
