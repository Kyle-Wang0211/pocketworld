## Context

The faulting queue was `com.pocketworld.official.arkit.jpeg`. The device stack
entered `_writeJSONNumber` from the high-resolution metadata dictionary and
terminated with `SIGABRT`. A local `Float.nan` array produces the same
Foundation stack. The user intentionally covered the camera to exercise a
black/zero-texture input when the crash occurred; later normally textured
captures succeeded. This makes degenerate ARKit sensor output, not capture
startup timing, the relevant trigger.

## Decisions

### Sanitize only optional ARKit raw-feature points

Raw feature points are auxiliary scale-alignment evidence. A point containing
fewer than three coordinates or any non-finite coordinate is removed together
with its identifier. All valid point/identifier pairs remain ordered and
byte-for-value identical.

### Fail closed for required camera pose and intrinsics

The camera transform and intrinsics are required reconstruction evidence.
Replacing a non-finite value with zero would fabricate geometry, so the affected
save returns a native error instead.

### Guard the complete Foundation serialization boundary

The final metadata dictionary is checked with
`JSONSerialization.isValidJSONObject` before serialization. This catches an
unexpected non-finite Dart contract value or unsupported bridged type without
entering Foundation's exception-throwing writer. The serializer is called only
after the object passes the guard.

## Non-goals

- No change to valid JSON schema values.
- No reconstruction fallback and no fabricated pose/calibration values.
- No performance or quality winner decision from simulator/host evidence.
