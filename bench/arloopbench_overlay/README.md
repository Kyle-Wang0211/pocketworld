# arloopbench overlay (bench-only)

The unified bench branch `bench/unified` = `bench/full-chain-168-fixes` (first parent)
+ merge of `bench/lidar-ruler` (second parent; it already contains `feat/bench-replay`).

The arloopbench app compiles two Dart packages side by side:

- `package:pocketworld_flutter` = this tree's `lib/` = production 168 + fixes, used by the
  full reconstruction chain. It must stay byte-identical to `bench/full-chain-168-fixes`.
- `package:arloopbench` = the bench pages. They are mirrored from this tree by
  `~/Developer/arloopbench/.sync_from_integration.sh`.

Four paths need a different version in each package, and one git tree can only hold one
version per path. Resolution used in the merge commit:

- The production path keeps the fixes version, so the full chain is unchanged.
- The bench-line version is kept here under the same relative path, byte-identical to
  `bench/lidar-ruler`. The sync script copies these files over the mirrored copies.

| path | why the bench needs its own version |
|---|---|
| `lib/official_dome/ar_pose.dart` | `ARPoseSourceLabel` / `ARPoseTransportLifecycle` interfaces used by the zero-ARKit pages |
| `lib/vio/ffi/xrslam_config.dart` | upstream-complete yaml, `boxDownsampledBy`, `devOverride` used by the VIO pages |
| `lib/vio/ffi/xrslam_smoke.dart` | bench-line comment fix; kept so the bench copy stays identical to the bench line |
| `lib/vio/ffi/xrslam_build_contract.dart` | bench line still records `zeroInlierMaskPatchSha256` |

Other production files touched by the bench line (`capture_session.dart`, `ar_capture_page.dart`,
`PwVioSlamFeeder.swift`, `vio_diagnostics_recorder.dart`, Podfile, pubspec, …) are the zero-ARKit
production integration. No bench page uses them, so this branch keeps the fixes version. Their
bench-line versions remain on `feat/bench-replay` / `bench/lidar-ruler`.

`vendor/xrslam/**` takes the bench-line version (per-frame-intrinsics transport). The bench
already compiled that version for both the VIO pages and the full chain's shadow XRSLAM
(only one transport can be linked).
