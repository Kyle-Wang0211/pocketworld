# Design

## Stage identity

`SfmLiveRecon` passes an explicit private stage into the delivery transform:
`preview`, `localReady`, or `refined`. The existing `refined` boolean cannot
identify preview because both preview and `local_ready` snapshots use
`refined=false`.

## Preview

The preview handler emits:

```json
{
  "type": "preview_skip",
  "schema_version": 1,
  "phase": "preview",
  "reason": "already_arkit_gravity_metric",
  "gravity_status": "not_required",
  "scale_status": "not_required"
}
```

It returns the snapshot without invoking the final alignment transforms. This
preserves current output: synthetic zero-quaternion preview poses already make
the existing transform a no-op.

## Delivery snapshots

Both `local_ready` and `refined` invoke the existing gravity and optional scale
functions. Each invocation emits exactly one `final_alignment_result` containing:

- `phase` and `authority`;
- `gravity_status`, `gravity_reason`, `gravity_quat_wxyz`;
- registered/usable ARKit quaternion counts;
- `scale_status`, `scale_reason`, `scale_factor`;
- registered/usable ARKit-center counts;
- `fed_meta_size` and `n_points`.

`refined` is authoritative. `local_ready` remains an explicit fallback
candidate for runs where no refined result is delivered.

## Failure behavior

Alignment stays fail-open. Missing or degenerate evidence returns the original
snapshot and records `skipped`; it never blocks point-cloud delivery. If
gravity cannot be applied, scale is recorded as `skipped` with
`scale_reason=gravity_not_applied`, matching the current early-return behavior.
