## ADDED Requirements

### Requirement: Independent physical-iPhone bundle

The system SHALL build and run the Lepton/JXL comparison only as bundle
`com.kyle.PocketWorld.LeptonBench` with its own app data container. It MUST NOT
install, update, uninstall, launch, or copy data into or out of
`com.kyle.PocketWorld`.

#### Scenario: Safe benchmark install

- **WHEN** the benchmark app is ready for device installation
- **THEN** its signed Info.plist and application identifier identify only
  `com.kyle.PocketWorld.LeptonBench`
- **AND** the install command contains no uninstall or production bundle target

### Requirement: Official pinned codecs

The Lepton arm SHALL use official `lepton_jpeg` 0.5.8 corresponding to commit
`90fdc27828676892fbb41777cfcc6bad1e470516`, its official vector write/read
feature presets, and its default thread pool. The JXL arm SHALL use the current
production libjxl revision and effort 10.

#### Scenario: Reproducible codec identity

- **WHEN** the iOS ARM64 static library and app are built
- **THEN** the result records both codec identities, Cargo lock, static-library
  hash, app binary hash, Xcode/SDK identity, and physical-device identity

### Requirement: Immutable same-input A/B

The benchmark SHALL reject every input except the 2,725,495-byte JPEG with
SHA-256 `a1cb8de1d3b91edbb7e05233c7930200c46e04554c3651153e267e5abd262138`.

#### Scenario: Input differs

- **WHEN** the file length or SHA-256 differs from the frozen identity
- **THEN** neither codec runs and the result records a failed input gate

### Requirement: Exact independent round trips

Each arm SHALL encode the frozen JPEG and restore it using that arm's official
decoder. Each restored file MUST match the input length, SHA-256, and every
byte.

#### Scenario: Any reconstruction differs

- **WHEN** either restored JPEG differs in length, digest, or any byte
- **THEN** the benchmark fails and production remains JPEG XL

### Requirement: Strict size promotion gate

Lepton SHALL become eligible for production only when its complete persisted
archive on the physical iPhone is strictly smaller than the JXL archive and
both exactness gates pass. A host, simulator, or equal-size result MUST NOT
promote it.

#### Scenario: Lepton wins exactly on phone

- **WHEN** both arms are exact and `lepton_archive_bytes < jxl_archive_bytes`
- **THEN** the result status is passed and conditional production work may begin

#### Scenario: Lepton does not strictly win

- **WHEN** Lepton is equal, larger, fails, or is not measured on the physical
  iPhone
- **THEN** production remains on the pinned JXL effort-10 encoder

### Requirement: Backward-compatible conditional promotion

If Lepton passes the phone gate and is promoted, only captures created by the
new policy SHALL use Lepton. Existing JXL archives MUST remain untouched and
readable, and the source JPEG MUST remain until the Lepton archive has been
officially decoded and verified byte-for-byte under the existing durable
transaction order.

#### Scenario: Existing JXL project after promotion

- **WHEN** an older project contains a verified JXL policy, manifest, and
  archive
- **THEN** the resolver uses the legacy JXL decoder without migration or
  rewriting

#### Scenario: Future Lepton archive transaction

- **WHEN** a future eligible JPEG produces a smaller exact Lepton archive
- **THEN** the system commits the archive and codec-aware manifest atomically,
  rechecks the production gate, and deletes the source JPEG last
