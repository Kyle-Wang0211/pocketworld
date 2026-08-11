## ADDED Requirements

### Requirement: Source-preserving reversible preprocessing

The system SHALL apply descriptor preprocessing only to a temporary
byte-identical copy of a closed SQLite database and MUST NOT open the source for
writing. Inverse preprocessing MUST restore the original length, every byte, and
SHA-256.

#### Scenario: Exact transform round trip

- **WHEN** a compatible database is transformed and inversely transformed
- **THEN** the restored file has the source length, byte sequence, SHA-256, and
  successful SQLite integrity check

#### Scenario: Transform failure

- **WHEN** parsing, cancellation, allocation, I/O, or inverse verification fails
- **THEN** incomplete outputs are rejected and the source remains unchanged

### Requirement: Bounded SQLite structure validation

The preprocessor SHALL validate the descriptors schema and every SQLite
page/record/overflow offset before reading or writing it. It MUST reject
unsupported or malformed structures rather than guessing.

#### Scenario: Compatible descriptors table

- **WHEN** `descriptors.data` is a BLOB with `cols = 128` and
  `length(data) = rows × cols`
- **THEN** only those BLOB payload bytes may be transformed

#### Scenario: Malformed or unknown layout

- **WHEN** schema, page size/type, varint, payload length, or overflow linkage is
  invalid or unsupported
- **THEN** preprocessing fails closed without publishing output

### Requirement: Fixed reversible experiment arms

The benchmark SHALL compare raw ZPAQ method 5 with `track_delta_v1` using the
same immutable input and pinned libzpaq revision. `track_delta_v1` SHALL derive
an acyclic deterministic forest from verified `two_view_geometries` matches,
leave roots and unmatched descriptors literal, and encode each child with a
modulo-256 byte delta from its parent.

#### Scenario: Deterministic repeat

- **WHEN** one arm is run repeatedly on the same input and revision
- **THEN** transformed and archive identities are identical across repeats

### Requirement: Multi-layer exactness evidence

The preflight benchmark SHALL cover deterministic fixtures and one immutable
complete real database for three repeats. Production admission SHALL add
malformed/fault coverage, broader immutable real-database coverage, and
physical-iPhone execution. Every measured archive MUST be decoded and verified.

#### Scenario: Any exactness failure

- **WHEN** any length, byte, SHA-256, integrity, determinism, corruption, or
  source-immutability gate fails
- **THEN** that arm is ineligible regardless of compression ratio

### Requirement: Evidence-gated production admission

Host results SHALL be diagnostic only. Production selection SHALL use the
physical iPhone and SHALL require every measured complete database archive to
be strictly smaller than raw ZPAQ across three repeats. A 10% threshold SHALL
apply only to a separately proposed invasive COLMAP storage-layer replacement.

#### Scenario: Insufficient compression improvement

- **WHEN** a correct arm fails either compression threshold
- **THEN** the existing raw-ZPAQ production path remains unchanged

#### Scenario: Candidate passes benchmark

- **WHEN** `track_delta_v1` passes every correctness and compression gate on the physical
  iPhone
- **THEN** results may support a separate, explicitly versioned production
  integration proposal but do not silently change existing archives
