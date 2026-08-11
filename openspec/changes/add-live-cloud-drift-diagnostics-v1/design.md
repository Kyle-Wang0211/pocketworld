# Design

## Event clock and failure behavior

All events use epoch milliseconds for cross-file correlation. Swift JSONL writes
remain asynchronous on `OfficialPwNativeTelemetry`'s serial utility queue. Dart
events use the existing non-blocking `TelemetryWriter`. C++ writes use the
existing best-effort `AppendMatchFailJsonl`; exceptions and I/O failures remain
swallowed so telemetry cannot interrupt capture.

## ARKit anchor delta

At origin lock, retain the complete anchor transform. On later AR frames compute
`currentAnchor * inverse(lockAnchor)` and the equivalent transform from the
previous logged anchor. Record translation vector/norm and quaternion angle.
Sample at 1 Hz and immediately when the severity bucket changes. The existing
`worldOrigin` calculation is not changed.

## Live-cloud generation

Dart assigns a monotonically increasing receive generation before launching
progressive ordering. It records receive and compute completion and includes the
generation, source, version, and point count in the existing
`setCoveragePointCloud` method payload. Swift stores metadata beside the cloud
buffers under the existing lock. The SceneKit render loop records the metadata
only when it consumes that dirty generation. It does not reject or reorder any
generation.

## BA versus ARKit camera centers

`FrameRecord.cam_from_world` remains the immutable ARKit seed. Immediately after
streaming local refinement, compare its world camera center with the registered
image's optimized world camera center. Record component-wise median delta, the
latest frame's vector/norm, and p50/p90/max norms. No value is fed back into the
reconstruction.

## Snapshot ARKit-to-BA Sim3

At each post-local-BA and successful post-global-BA native model state, pair the
optimized camera center for each registered image with the immutable ARKit center
from its `FrameRecord`. Fit the BA-to-ARKit similarity with closed-form Umeyama,
compute residuals, then refit once using a median/MAD inlier threshold. Record
the BA-to-ARKit and inverse ARKit-to-BA scale, translation, quaternion/angle,
pair and inlier counts, and p50/p90/max residuals. Fewer than three valid pairs
or degenerate geometry produces a fail-open invalid event.

## Same-ID point displacement

The native diagnostic state keeps only the previous snapshot's exact COLMAP
Point3D ID-to-position map. Consecutive snapshots intersect those IDs and compute
current-minus-previous displacement. Record common/new/dropped counts, median
components, coherent median norm, p50/p90/p99/max norms, counts at or above 5 cm
and 10 cm, and the worst ID serialized as a decimal string. The first snapshot
is a baseline. The map is telemetry-only and never participates in BA, filtering,
snapshot publication, or rendering.

## Build identity

The signed app Info.plist carries `PWLiveCloudDiagnosticBuildId`. Swift and Dart
emit that contract identity at startup/capture. The native core emits a distinct
contract identity into `sfm_match_fail.jsonl`. The deployment evidence ledger
adds cryptographic hashes of the signed app executable, Dart App.framework, and
embedded PWOfficialSfm framework.

## Production update

Freeze the complete current local product tree, including dirty and relevant
untracked inputs. Build from an isolated copy under `/private/tmp` with the
already pinned Flutter/package cache and `--no-pub`. Before any install, use the
user's normal Terminal session to copy `Documents` and `Library` separately from
the existing `com.kyle.PocketWorld` container and verify every entry/hash. Install
only with `devicectl device install app`; never uninstall. Afterward re-copy and
prove all pre-existing files byte-identical, excluding only
`Library/SplashBoard/Snapshots/**`.
