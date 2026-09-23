## ADDED Requirements

### Requirement: Per-frame intrinsics travel with their frame in pushed-buffer pixels

The host SHALL attach a frame's pinhole intrinsics to that same frame's camera
push, expressed in pixels of exactly the buffer passed to the transport. The
host SHALL NOT read a K from shared state that a later frame may have
overwritten. When the official reference dimensions of the K do not provably
equal the pushed buffer (after the documented conversion for that path), the
host SHALL push without per-frame K and count the reason.

#### Scenario: zero-ARKit ON arm pushes the full capture buffer

- **WHEN** the sample buffer carries `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`
  and its format-description, active-format and image-buffer dimensions are equal
  and the image-buffer dimensions equal the engine's configured `cam0.resolution`
- **THEN** the matrix values fx, fy, cx, cy are pushed unchanged with that buffer

#### Scenario: dimensions disagree

- **WHEN** any of those dimension pairs differ, or `cam0.resolution` cannot be
  read from the device configuration
- **THEN** the frame is pushed through the legacy entry point and the mismatch
  reason is counted

#### Scenario: ARKit shadow pushes a box-d downsampled gray image

- **WHEN** `ARCamera.imageResolution` equals the luma plane that is downsampled
  by factor d
- **THEN** the pushed K is `fx/d, fy/d, (cx+0.5)/d-0.5, (cy+0.5)/d-0.5`,
  computed by `PWXrslamTransportScaleIntrinsicsForBoxNxN`, bit-identical to
  `pwvi_to_euroc.py --downscale d`
- **AND** the session's YAML K for that path uses the same expression, so the
  on and off arms differ only in per-frame vs constant K

### Requirement: The legacy push is unchanged

`PWXrslamTransportPushCameraAndRunRaw` and a NULL or unattachable K SHALL hand
the core the same `XRSLAMImage` bytes and the same ABI call sequence as the
transport before this change.

#### Scenario: switch off

- **WHEN** `-PWPerFrameIntrinsics off` is passed
- **THEN** both iOS paths call `PWXrslamTransportPushCameraAndRunRaw`
- **AND** no `XRSLAM_INFO_INTRINSICS` query is issued

### Requirement: Engine consumption is not inferred from values

After every push that attached a per-frame K the transport SHALL read
`XRSLAM_INFO_INTRINSICS` and record whether the report differs from or equals
the attached K. An equal report SHALL NOT be counted or labelled as
consumption. Whether the linked core consumes per-frame K SHALL come only from
the build identity (`PWXrslamEngineArm` stamped by a Release build after its
fingerprint check). Diagnostics SHALL expose attached, not-attached, rejected,
report-differs and report-equal counts from that ledger, the build identity,
and the switch state, source and parse failure.

#### Scenario: report differs

- **WHEN** the per-frame K is attached and the linked core reports other values
- **THEN** the frame is labelled `per_frame_not_consumed`

#### Scenario: report equal, no build identity

- **WHEN** the report equals the attached K and the build carries no
  `PWXrslamEngineArm` stamp
- **THEN** the frame is labelled `per_frame_attached_unverified`, not `per_frame`

#### Scenario: report equal, build identity is another arm

- **WHEN** the report equals the attached K and the stamp names an arm other
  than `gpufenothread_pfk`
- **THEN** the frame is labelled `per_frame_not_consumed`

#### Scenario: unparseable switch value

- **WHEN** `-PWPerFrameIntrinsics` has a value that is neither on nor off
- **THEN** per-frame K stays on (the default) and the diagnostics record the
  parse failure

### Requirement: Research archive is receipt-bound and not the default

The per-frame K engine archive SHALL be selectable only through
`PW_XRSLAM_ENGINE=gpufenothread_pfk`, SHALL carry a receipt naming its source
commit, build recipe, toolchain and sha256, and the default link SHALL remain
`libxrslam_generic_4beb1a9.a` with unchanged flags.

#### Scenario: default build

- **WHEN** `PW_XRSLAM_ENGINE` is unset
- **THEN** the linked engine is `libxrslam_generic_4beb1a9.a` and its sha256 is
  `fdc75c99358014d9485bea36667547825465a85562847548d02a582da38c8011`
