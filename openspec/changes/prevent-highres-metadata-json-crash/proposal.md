## Why

The production iPhone intermittently terminates immediately after a
high-resolution shutter event. The 2026-07-31 crash report identifies an
uncaught `NSInvalidArgumentException` in Foundation's `_writeJSONNumber`, called
from `OfficialAetherARKitPlugin.captureHighResolutionStill`. A matching local
reproduction proves that `JSONSerialization` aborts the process when an array
contains `NaN`; Swift `do/catch` cannot catch that Objective-C exception.

ARKit values are runtime sensor data. A non-finite point must not be allowed to
terminate the whole capture process, and invalid camera calibration or pose data
must never be persisted as if it were usable reconstruction evidence.

## What Changes

- Remove non-finite ARKit raw-feature points while preserving each retained
  point's matching identifier and original order.
- Validate required camera transform and intrinsic arrays as finite before
  metadata serialization.
- Validate the complete metadata object with
  `JSONSerialization.isValidJSONObject` before calling the exception-prone
  serializer.
- Fail only the affected photo save with a field-specific native error if
  required pose/calibration data or another metadata value is not JSON-safe.
- Preserve all finite metadata values and all reconstruction/quality algorithms
  unchanged.

## Capabilities

### New Capabilities

- `highres-metadata-json-safety`: process-safe validation and sanitization at
  the native high-resolution ARKit metadata boundary.

## Impact

- Changes only `OfficialAetherARKitPlugin` metadata preparation and its iOS unit
  tests.
- No native archive rebuild, feature extraction change, matching change,
  reconstruction parameter change, frame-selection change, or cross-platform
  algorithm change.
- A future in-place production update still requires a fresh verified
  Documents/Library backup and the existing no-uninstall runbook.
