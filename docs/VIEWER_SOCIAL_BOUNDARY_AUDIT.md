# Viewer / Social Boundary Audit

Flutter/Dart owns product policy. Native renderers are thin executors.

## Current Boundary

| Area | Dart owns | Native/renderer owns |
| --- | --- | --- |
| Feed | ordering, visibility thresholds, live mount debounce, delayed unmount, placeholder choice | no feed policy |
| Viewer quality | `ViewerQuality.feedThumbnail` vs `ViewerQuality.full`, splat override choice, format fallback | texture allocation, draw calls, raw load/render errors |
| Cache | GLB/cache lookup and fallback UI routing | no cache policy |
| Format | format detection, unsupported-format UX | format-specific loading once requested |
| Likes | optimistic state, rollback, count update | no social state |
| Product state | navigation, card live/dead state, first-frame placeholder | frame rendering into texture |

The machine-readable contract is `kViewerSocialPolicyContract` in
`lib/ui/viewer_social_contract.dart`.

## Hard Rule

```text
Dart feed/viewer/social policy -> thin renderer/service executor -> Dart report/state
```

Metal/Dawn/Filament/C++ must not decide feed ranking, live-card policy,
fallback UI, model format policy, like truth, or navigation state.

## Remaining Watchpoints

- `aether_cpp` may contain renderer tunables. They should be treated as
  executor defaults only; Dart must pass quality/override choices.
- Any future server feed ranking should still enter Flutter as data and be
  applied by a Dart view model, not by native renderer state.
- Thumbnail generation strategy should get its own Dart spec before native
  GPU thumbnail baking becomes production.

