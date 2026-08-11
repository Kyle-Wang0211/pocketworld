## ADDED Requirements

### Requirement: Every prior scheme has an evidence classification

The audit SHALL classify every previously discussed compression scheme as `faithful_official`, `faithful_subset`, `invalid_reproduction`, `evidence_missing`, `mentioned_not_run`, `blocked_no_official_route`, or `validated_internal`.

PocketWorld-owned transforms that have no external upstream SHALL use `validated_internal` instead of implying that an official third-party reproduction exists.

#### Scenario: A partial mode was previously described as a project failure

- **WHEN** a result used an official library but omitted an official recommended transform, trainer, typed layout, or persisted side data
- **THEN** the result SHALL be limited to that measured subset and SHALL NOT be reported as failure of the upstream project

#### Scenario: No durable result exists

- **WHEN** the repository has no immutable input identity, pinned implementation, command, measured output, and exact decode evidence
- **THEN** the old size or winner claim SHALL be withdrawn

### Requirement: Supplements use the minimum complete unit

Every decision-bearing experimental gap with an official runnable path SHALL be supplemented on the smallest complete data unit that can prove exact encode/decode behavior.

#### Scenario: A prior decision-bearing gap has an official runnable path

- **WHEN** a missing or invalid official configuration can be tested safely on a complete data unit
- **THEN** the audit SHALL run exactly one host encode/decode cycle on one original JPEG or one complete descriptor row, verify byte and SHA-256 equality, count every persisted byte, and stop without scaling up

#### Scenario: No official runnable path exists

- **WHEN** only a paper, patent, local approximation, or license-incompatible implementation exists
- **THEN** the audit SHALL record `blocked_no_official_route` rather than silently substituting a self-written approximation

### Requirement: Audit work cannot alter production

The audit SHALL remain host-only and SHALL NOT change production source, phone state, app bundles, archive data, or production configuration.

#### Scenario: The audit is executed

- **WHEN** any inventory, source verification, or micro-supplement runs
- **THEN** no production source, phone state, app bundle, archive data, or 100 MB/full-project benchmark SHALL be changed or executed

### Requirement: Commercial candidate screening covers previously unrun routes

The audit SHALL screen every previously unrun candidate on its smallest semantically complete unit or record a precise build or semantic blocker. Each candidate SHALL pin an official revision and receive an `allow`, `conditional`, `conflict`, `block`, or `insufficient-evidence` commercial-use engineering verdict.

#### Scenario: A candidate has a runnable exact official implementation

- **WHEN** the official encoder and decoder can operate on one complete PocketWorld data unit
- **THEN** the audit SHALL count every persisted byte and require byte and SHA-256 equality before comparing it with the same-input baseline

#### Scenario: A candidate is not an exact replacement for the scoped file

- **WHEN** an official format preserves logical values but cannot reconstruct the old file serialization
- **THEN** the audit SHALL test it only against the normalized logical-data scope and SHALL NOT present it as exact old-file recovery

#### Scenario: A candidate wins a host micro-screen

- **WHEN** a commercially admissible candidate is smaller on the minimum unit
- **THEN** the result SHALL authorize only a larger isolated benchmark, not production modification or phone installation
