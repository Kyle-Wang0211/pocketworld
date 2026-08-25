## ADDED Requirements

### Requirement: PTOL benchmark uses one installed production identity

The experiment SHALL run both arms on the same physical iPhone, installed
PocketWorld build, native framework, Dart AOT, and frozen capture identity. It
SHALL NOT rebuild, install, uninstall, or substitute an older application.

#### Scenario: An input or binary hash differs

- **WHEN** the phone copy of the application or selected capture differs from
  the registered SHA-256 identity
- **THEN** the run stops as invalid before reconstruction
- **AND** it does not relabel the changed state as the registered experiment

### Requirement: PTOL is the only experimental variable

The control arm SHALL preserve global `parameter_tolerance=0.0`, and the
candidate arm SHALL set only `OFFICIAL_AETHER_GLOBAL_PTOL=1e-8`. AR-every-frame
and every other production option SHALL remain identical.

#### Scenario: Shared environment file contains other keys

- **WHEN** an arm is prepared on the phone
- **THEN** the harness reads and merges the existing JSON
- **AND** changes only `OFFICIAL_AETHER_GLOBAL_PTOL`

### Requirement: Same source capture is replayed without mutation

Every arm SHALL reconstruct an isolated copy materialized from the registered
capture archive and sidecar. The source capture SHALL remain byte-identical.

#### Scenario: Existing reconstruction gate runs

- **WHEN** the gate materializes and rebuilds the selected capture
- **THEN** only `rebuild_full` is treated as the PTOL measurement
- **AND** the gate's pruned arm is excluded as a non-identical input

### Requirement: Phone evidence precedes a PTOL verdict

Each arm SHALL persist its environment receipt, gate report, finalize segments,
BA-round telemetry, thermal evidence, binary/input identities, and raw numeric
quality metrics before the next arm starts.

#### Scenario: One arm lacks an effective-value receipt

- **WHEN** the expected PTOL value cannot be proved before native work
- **THEN** that arm is invalid
- **AND** its timing does not enter the paired comparison

### Requirement: Quality gates precede speed

The candidate SHALL NOT be classified as promising unless reconstruction
succeeds, registered-image count is unchanged, and numeric quality remains
inside the measured control replay noise floor. A numeric pass SHALL NOT by
itself promote a shipping default without physical-phone visual review.

#### Scenario: Candidate is faster but changes quality beyond noise

- **WHEN** `1e-8` reduces wall time but violates a required quality gate
- **THEN** the verdict is negative
- **AND** the production default remains `0.0`

### Requirement: A direction screen cannot approve quality

The existing production gate MAY provide a zero-rebuild ABAB direction screen,
but its result SHALL remain non-promotable because it does not persist per-arm
PLY or final post-BA quality.

#### Scenario: Direction screen exceeds the speed noise floor

- **WHEN** `1e-8` is faster and passes the screen's numeric validity gates
- **THEN** the verdict is `promising_screen`
- **AND** a separate-bundle physical-phone quality A/B is required

### Requirement: Complete quality A/B uses a separate bundle

The complete phone comparison SHALL run as
`com.kyle.PocketWorld.PtolBench`, with its own container, the registered
production native framework, identical app bytes across arms, and independent
copies of the same frozen input.

#### Scenario: Full PTOL benchmark is installed

- **WHEN** the Stage-1 benchmark app is signed and installed
- **THEN** its application identifier is the PTOL benchmark bundle
- **AND** no command targets, updates, launches, or uninstalls
  `com.kyle.PocketWorld`

#### Scenario: Full ABAB completes

- **WHEN** all four arms finish on the physical iPhone
- **THEN** every arm preserves its refined PLY, complete quality summary,
  effective PTOL receipt, BA telemetry, and input/output hashes
- **AND** visual review precedes any shipping decision

### Requirement: Production state is restored

Fresh hash-verified Documents and Library backups SHALL precede the first
device write. After the final arm, the harness SHALL restore the exact pre-run
PTOL key state and verify every pre-existing production file.

#### Scenario: Cleanup cannot prove restoration

- **WHEN** the original environment state or pre-existing file identity cannot
  be verified
- **THEN** the run stops with a restoration failure
- **AND** no success verdict is emitted
