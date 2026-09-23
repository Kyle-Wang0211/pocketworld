# Change: Wire per-frame camera intrinsics from the platform camera into XRSLAM

## Why

Continuous autofocus moves the focal length during a capture (three recordings
measured fx spans of 7.7 %, 8.0 % and 10.8 %), while the engine reads one
constant K from the device YAML at `XRSLAMCreate`. The engine side of per-frame
K already exists on the fork (`github.com/Kyle-Wang0211/xrslam`, branch
`feat/per-frame-intrinsics`, commit `04c0e83e9c4889612880529dd49dd8063819a776`):
`XRSLAMImage.ext_size` + a 72-byte `XRSLAMImageExtension` carrying
`intrinsics_fxfycxcy[4]` / `has_intrinsics`, consumed only when
`ext_size == sizeof(XRSLAMImageExtension)`; `detail.cpp:105-110` then uses the
frame's K instead of the YAML K. Offline PC replays of that commit (A = frozen
frame-0 K, C = per-frame K) improved SE3 ATE by 17-47 % on two of three
recordings and tied on the third. No host passes a per-frame K yet.

This is a research arm. It is not part of the official 4beb1a9 reproduction arm
and does not change the shipping engine archive or the default link.

## What changes

- Shared C++ transport (`vendor/xrslam/transport`): new
  `PWXrslamTransportPushCameraAndRunRawWithIntrinsics(..., const double *k, ...)`;
  the legacy `PWXrslamTransportPushCameraAndRunRaw` becomes its `k == NULL`
  wrapper and stays byte-for-byte identical in what it hands the core. New
  `PWXrslamTransportScaleIntrinsicsForBoxNxN` (K of the box-NxN gray output,
  the exact expression of the offline converter `pwvi_to_euroc.py:224-226`) and
  `PWXrslamTransportGetIntrinsicsTrace` (per-session ledger, including an
  `XRSLAM_INFO_INTRINSICS` read-back that shows whether the linked core
  consumed the K).
- Mirror header `vendor/xrslam/include/XRSLAM.h` follows the fork 04c0e83
  layout (struct sizes pinned by static_asserts in the transport).
- iOS zero-ARKit ON arm (`PwCameraSlot.swift` -> `PwXrslamLive.swift`): push the
  `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix` of each sample buffer
  with that frame, unscaled (the full BGRA buffer is pushed; no downsample).
- iOS ARKit shadow path (`PwVioSlamFeeder.swift`): rescale
  `ARFrame.camera.intrinsics` to the 640x480 box-d gray image through the shared
  C function before pushing.
- Runtime switch `-PWPerFrameIntrinsics on|off` (default on in this research
  branch); off pushes through the legacy entry point.
- Per-frame K source is recorded in the existing VIO diagnostics (shadow
  snapshot + per-observation key, `latest.json` slam ticks, ON-arm
  `pw_xrslam_live_intrinsics`, probe `run_manifest.json`).
- New research engine archive `libxrslam_gpufenothread_pfk_6f6aa21c.a` built
  from 04c0e83 with the receipted gpufe_nothread recipe, selectable with
  `PW_XRSLAM_ENGINE=gpufenothread_pfk`. Default stays `generic`.
- Android: JNI + Kotlin plumbing only; the camera2 source of K is a labelled
  TODO (see design).

## Non-goals

- No online self-calibration, no distortion model change, no change to any
  engine threshold or YAML parameter.
- No device install, no production default change, no bench A/B run in this
  change. Host/replay evidence cannot select a production winner.
