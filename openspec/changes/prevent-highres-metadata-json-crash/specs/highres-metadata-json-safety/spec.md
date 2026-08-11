## ADDED Requirements

### Requirement: Invalid ARKit feature points cannot terminate capture

The native high-resolution still path SHALL exclude non-finite raw-feature
points before constructing metadata and SHALL preserve the matching identifier
and order for every retained point.

#### Scenario: One raw point contains NaN

- **WHEN** an ARKit raw-feature point contains `NaN` or infinity in any coordinate
- **THEN** that point and only its matching identifier are omitted from
  `anchors_world` and `anchor_ids`

#### Scenario: All raw points are finite

- **WHEN** all ARKit raw-feature points are finite
- **THEN** every point and identifier is retained in its original order and with
  unchanged numeric values

### Requirement: Required geometry fails closed

The native high-resolution still path SHALL require finite camera transform and
intrinsic values before persisting metadata.

#### Scenario: Camera transform is non-finite

- **WHEN** any camera-transform value is `NaN` or infinity
- **THEN** the affected save returns a native metadata error without invoking
  `JSONSerialization.data` and without terminating the process

#### Scenario: Intrinsics are non-finite

- **WHEN** any intrinsic value is `NaN` or infinity
- **THEN** the affected save returns a native metadata error without fabricating
  replacement calibration values

### Requirement: Complete JSON object is guarded

The native high-resolution still path SHALL validate the complete metadata
object with `JSONSerialization.isValidJSONObject` before invoking Foundation's
JSON writer.

#### Scenario: Nested metadata contains an invalid number

- **WHEN** any remaining nested metadata value is not JSON-safe
- **THEN** the affected save returns a native metadata error and the application
  process remains alive

#### Scenario: Complete metadata is valid

- **WHEN** all metadata values are JSON-safe
- **THEN** serialization preserves the existing schema and numeric values
