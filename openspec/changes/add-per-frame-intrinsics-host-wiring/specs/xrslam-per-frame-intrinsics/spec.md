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
- **THEN** the matrix values fx, fy, cx, cy are pushed unchanged with that buffer

#### Scenario: dimensions disagree

- **WHEN** any of those three dimension pairs differ
- **THEN** the frame is pushed through the legacy entry point and the mismatch
  reason is counted

#### Scenario: ARKit shadow pushes a box-d downsampled gray image

- **WHEN** `ARCamera.imageResolution` equals the luma plane that is downsampled
  by factor d
- **THEN** the pushed K is `fx/d, fy/d, (cx+0.5)/d-0.5, (cy+0.5)/d-0.5`,
  computed by `PWXrslamTransportScaleIntrinsicsForBoxNxN`, bit-identical to
  `pwvi_to_euroc.py --downscale d`

### Requirement: The legacy push is unchanged

`PWXrslamTransportPushCameraAndRunRaw` and a NULL or unattachable K SHALL hand
the core the same `XRSLAMImage` bytes and the same ABI call sequence as the
transport before this change.

#### Scenario: switch off

- **WHEN** `-PWPerFrameIntrinsics off` is passed
- **THEN** both iOS paths call `PWXrslamTransportPushCameraAndRunRaw`
- **AND** no `XRSLAM_INFO_INTRINSICS` query is issued

### Requirement: Engine consumption is observable

After every push that attached a per-frame K the transport SHALL read
`XRSLAM_INFO_INTRINSICS` and record whether the report equals the attached K.
Diagnostics SHALL expose attached, not-attached, rejected, and engine-matched
counts from that ledger, and the switch state and source.

#### Scenario: archive without the fork change is linked

- **WHEN** the per-frame K is attached but the linked core reports its YAML K
- **THEN** the frame is labelled `per_frame_not_consumed`, not `per_frame`

### Requirement: Research archive is receipt-bound and not the default

The per-frame K engine archive SHALL be selectable only through
`PW_XRSLAM_ENGINE=gpufenothread_pfk`, SHALL carry a receipt naming its source
commit, build recipe, toolchain and sha256, and the default link SHALL remain
`libxrslam_generic_4beb1a9.a` with unchanged flags.

#### Scenario: default build

- **WHEN** `PW_XRSLAM_ENGINE` is unset
- **THEN** the linked engine is `libxrslam_generic_4beb1a9.a` and its sha256 is
  `fdc75c99358014d9485bea36667547825465a85562847548d02a582da38c8011`
