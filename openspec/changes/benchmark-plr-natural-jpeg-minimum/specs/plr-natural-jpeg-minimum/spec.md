## ADDED Requirements

### Requirement: Frozen official PLR identity

The experiment SHALL use unmodified official PLR commit
`8a65e4d0d3daa9292e40df0541e8f43fcaada2d7` and record its tree, source-file,
and license hashes before execution.

#### Scenario: Local repair would be required

- **WHEN** a missing encode, decode, serialization, or JPEG reconstruction path
  would need local algorithm code
- **THEN** the official experiment stops as incomplete
- **AND** the repaired candidate is not labeled official PLR

### Requirement: Actual archive rather than entropy estimate

The PLR size SHALL be the byte length of a complete persisted stream that its
official decoder consumes. A likelihood, `bpp_loss`, tensor byte count, or
unserialized collection of entropy strings MUST NOT be used as archive size.

#### Scenario: Only forward likelihood is available

- **WHEN** the official route produces only an estimated bit rate
- **THEN** no size comparison with JXL is reported

### Requirement: Exact source JPEG restoration

The official PLR decode route SHALL restore the registered 2,725,495-byte JPEG
with SHA-256
`a1cb8de1d3b91edbb7e05233c7930200c46e04554c3651153e267e5abd262138`
and byte equality.

#### Scenario: Coefficients match but the JPEG file differs

- **WHEN** decoded DCT values match but any marker, header, metadata, padding,
  byte, length, or SHA-256 differs
- **THEN** exactness fails and no scale-up is allowed

### Requirement: Complete cost accounting

The candidate SHALL report stream bytes, container bytes, exact-JPEG side-data
bytes, distributable model bytes, standalone effective bytes, and effective
bytes with the model amortized over exactly 141 photos.

#### Scenario: Model cost is omitted

- **WHEN** a result excludes or hides required model bytes
- **THEN** the result is invalid and cannot beat JXL

### Requirement: Strict minimum-unit scale-up gate

Cross-photo adaptation and complete-project testing SHALL remain forbidden
until the one-JPEG official archive is exact and its registered effective size
is strictly smaller than the saved 2,215,345-byte JXL result.

#### Scenario: Official public codec is incomplete

- **WHEN** preflight finds no executable end-to-end official exact-JPEG codec
- **THEN** the experiment records `official_codec_incomplete`
- **AND** does not install dependencies, train, create a phone bundle, edit
  production, or classify PLR's compression ratio as a failure
