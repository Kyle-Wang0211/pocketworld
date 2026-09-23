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
- [x] Android JNI/Kotlin plumbing. Checked at compile/unit level only: NDK r29
  `aarch64-linux-android26` compile of `PwXrslamTransport.cpp` +
  `PwXrslamTransportCore.cpp` with `-Wall -Wextra -Werror`, and a host-JVM run of
  the Kotlin wrapper through the JNI glue against the transport test fake
  (K = null, K given bit-exact through JNI, wrong length rejected before any
  core call, legacy entry unchanged). That smoke harness was run by hand and is
  not a committed test target; nothing ran on an Android device.
- [x] Host-side checks re-run on 2026-09-23: transport ctest 2/2 (with the
  fork contract test against a `git archive` of 04c0e83); a cross-binary dump
  of the `XRSLAMImage` bytes and ABI call sequence from the cfe7d44 transport vs
  this transport (legacy entry and K = NULL) is identical; the fork's guard-page
  ABI test 12/12 against both the fork header and this mirror header; the
  rescale matches `pwvi_to_euroc.py --downscale 3` on all 1702 rows of
  `run-6e2d4b99` (max abs diff 0); `PushImage` in the linked research binary
  carries the `ext_size == 72` compare, the generic-arm binary does not.
- [x] iOS generic-device Profile build without code signing
  (`flutter build ios --config-only` + `xcodebuild -destination
  'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`), both `gpufenothread_pfk` and
  the default `generic` arm: BUILD SUCCEEDED, `_pw_xrslam_live_intrinsics`
  exported. Nothing installed. The Release symbol count (45) is inferred from
  the previous 44 plus this one symbol, not measured.
- [ ] Android camera2 source of K mapped to pushed-buffer pixels and verified on
  a device.
- [ ] Rebuild `android_ready/native/xrslam/libs/arm64-v8a/libpw_xrslam_transport.so`
  (prebuilt is from before this change; needs NDK + the Android generic core).
- [ ] On-device bench A/B (`-PWPerFrameIntrinsics on|off`) under the research
  bundle id, per the design's required record.
