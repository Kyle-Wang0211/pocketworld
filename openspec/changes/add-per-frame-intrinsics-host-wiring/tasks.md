# Tasks

Physical-device evidence is a separate box and cannot be inferred from source
tests or a build.

- [x] Shared transport: `PushCameraAndRunRawWithIntrinsics`, legacy wrapper,
  `ScaleIntrinsicsForBoxNxN`, `GetIntrinsicsTrace`; mirror header on the 04c0e83
  layout with static_asserts.
- [x] C++ tests: K == NULL is byte-for-byte the legacy push; K given attaches the
  exact 72-byte extension; unattachable K falls back; rescale equals the offline
  converter on 120 real rows; fork `take_frame_intrinsics` accepts the pushed
  struct.
- [x] iOS ON arm: per-sample-buffer K pushed with its frame, reference-dimension
  guard, switch, `pw_xrslam_live_intrinsics` report.
- [x] iOS ARKit shadow: rescale via the shared C function, per-observation K
  source, snapshot ledger, persisted in diagnostics ticks.
- [x] Research engine archive from 04c0e83 with receipt; `gpufenothread_pfk` arm
  in Podfile, select script and runtime identity stamp; default unchanged.
- [x] Android JNI/Kotlin plumbing with host JNI smoke test.
- [ ] Android camera2 source of K mapped to pushed-buffer pixels and verified on
  a device.
- [ ] Rebuild `android_ready/native/xrslam/libs/arm64-v8a/libpw_xrslam_transport.so`
  (prebuilt is from before this change; needs NDK + the Android generic core).
- [ ] On-device bench A/B (`-PWPerFrameIntrinsics on|off`) under the research
  bundle id, per the design's required record.
