## ADDED Requirements

### Requirement: Frozen source and upstream identities

The experiment SHALL reject any source file, PLR tree, or Brunsli tree whose
size, SHA-256, or commit differs from the registered contract.

#### Scenario: A same-named JPEG has different bytes

- **WHEN** either input path resolves to a different size or SHA-256
- **THEN** the experiment stops before encoding
- **AND** it does not substitute another capture or baseline

### Requirement: Provisional and final model accounting are distinct

Phase 0 SHALL report a frozen raw deployment-artifact upper bound and SHALL NOT
use untrained Zstd or ZPAQ output as formal `M`. Phase 4 SHALL rerun the same
registered candidate set on the final trained artifact and use only `final_M`.

#### Scenario: Only an untrained compressed size exists

- **WHEN** the final trained artifact has not been serialized and restored
- **THEN** `final_M`, `H`, and `N_break_even` remain unknown
- **AND** no terminal size verdict is emitted

### Requirement: Fixed exact model-storage candidates

The only registered storage candidates SHALL be raw, Zstandard 1.5.7 level 22,
and ZPAQ 7.15 method 5. A compressed candidate is eligible only when it restores
the canonical deployment artifact byte for byte with the same SHA-256.

#### Scenario: A smaller storage candidate changes one model byte

- **WHEN** its restored length, bytes, or SHA-256 differs
- **THEN** it is excluded from selection regardless of size

### Requirement: Scope-2 break-even reachability

The formal verdict SHALL use 141 photos and a self-contained per-project model.
Break-even SHALL be reachable only when the verified minimum photo count is at
most 300; rows at 1,000 and 10,000 are informational only.

#### Scenario: Break-even is 301 photos

- **WHEN** the candidate loses at 141 and `N_break_even` is 301
- **THEN** the verdict is `loser_at_141_break_even_unreachable_scope2`
- **AND** global model sharing cannot rescue it

### Requirement: Brunsli exact-container fallback is unmodified and bounded

The experiment SHALL run unmodified v0.1 first. It MAY run the pinned master
fallback exactly once only after an upstream v0.1 exact-container failure.

#### Scenario: Both pinned revisions fail

- **WHEN** neither revision restores both frozen JPEGs exactly
- **THEN** the verdict is `blocked_upstream_exact_container`
- **AND** no upstream source or local wrapper is patched

### Requirement: Coefficients and reconstruction state are physically separate

The Phase 1 archive SHALL place every Y, Cb, and Cr quantized DCT coefficient in
a coefficient payload that is distinct from the exact-JPEG reconstruction
state. The reconstruction payload SHALL NOT retain Brunsli DC or AC streams.

#### Scenario: A full Brunsli stream is retained beside coefficients

- **WHEN** the reconstruction payload contains DC or AC coefficient sections
- **THEN** Phase 1 is invalid because dominant data is duplicated

### Requirement: Both source JPEG files restore byte for byte

For A and B, restored length, byte comparison, and SHA-256 SHALL equal the
registered original. Coefficient component counts and every `int16_t` value
SHALL also match.

#### Scenario: Coefficients match but one JPEG marker byte differs

- **WHEN** the restored JPEG differs at any byte
- **THEN** exactness fails and no later phase starts

### Requirement: Corrupt or incomplete payloads fail closed

The adapter SHALL reject wrong magic, unsupported version, invalid length,
truncation, appended data, SHA mismatch, coefficient count mismatch, and bit
flips before atomically publishing a restored JPEG.

#### Scenario: One coefficient payload bit is flipped

- **WHEN** restore is attempted
- **THEN** the command exits nonzero
- **AND** no final output JPEG exists

### Requirement: Phase 1 success does not authorize later product work

Phase 1 success SHALL NOT authorize learned training, JXL or Lepton baseline
measurement, a terminal candidate, phone access, production changes, a full
project run, or automatic codec selection by photo count.

#### Scenario: Exact container round-trip passes

- **WHEN** both JPEGs and corruption tests pass
- **THEN** the experiment records Phase 1 success
- **AND** stops for a separately reviewed Phase 2/3 implementation plan
