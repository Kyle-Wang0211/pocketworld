# Live-cloud drift diagnostics

## Requirements

### Requirement: observation only

The diagnostics SHALL NOT change capture, reconstruction, display selection,
point coordinates, camera poses, matcher results, or exported artifacts.

### Requirement: ARKit anchor transform

The application SHALL persist the complete subject-anchor translation and
rotation delta relative to lock time, with 0.05 m warning and 0.10 m severe
observation labels.

### Requirement: cloud generation correlation

The application SHALL correlate each live-cloud receive with the generation
actually consumed by the native render loop, including source, version, count,
and timestamps.

### Requirement: BA correction summary

The native pipeline SHALL persist robust optimized-versus-ARKit camera-center
delta statistics after streaming local BA without feeding them back into BA.

### Requirement: snapshot ARKit-to-BA Sim3

After every published local-BA or successful global-BA native model state, the
native pipeline SHALL robustly estimate the best similarity transform from the
optimized BA camera centers to their immutable ARKit camera centers. It SHALL
record forward and inverse translation, rotation, and scale, correspondence and
inlier counts, and residual statistics. An invalid or degenerate fit SHALL only
produce an invalid diagnostic event and SHALL NOT affect reconstruction.

### Requirement: same-ID point displacement

For consecutive native model states, the native pipeline SHALL compare exact
COLMAP Point3D IDs and record common, new, and dropped counts; the component-wise
median displacement; p50, p90, p99, and maximum displacement norms; counts at or
above 0.05 m and 0.10 m; and the worst point ID. The first state SHALL be logged
as the baseline. Diagnostic history SHALL NOT change any point or pose.

### Requirement: exact build identity

Each run SHALL identify its signed app marker, Dart diagnostics contract, and
native diagnostics contract; the deployment ledger SHALL record exact binary
hashes.

### Requirement: production data preservation

The update SHALL preserve the existing `com.kyle.PocketWorld` App Data
Container, use no uninstall path, and prove pre-existing `Documents` and
`Library` files byte-identical after installation except for recorded
`Library/SplashBoard/Snapshots/**` rotations.
