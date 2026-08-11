## ADDED Requirements

### Requirement: Official codec identities are frozen

The benchmark SHALL reject upstream source whose release commit or license hash
differs from the experiment contract.

#### Scenario: Upstream identity differs

- **WHEN** a checked-out codec does not match its pinned release identity
- **THEN** the benchmark stops before compilation or data access

### Requirement: Every selected payload is exact

The benchmark SHALL decode and byte-compare every codec candidate before it may
be selected, and SHALL verify the final reconstructed PWA2 logical database.

#### Scenario: Candidate payload differs

- **WHEN** any decoded byte, logical value, row order, random read, or SQLite
  integrity check differs
- **THEN** that arm is rejected without a size verdict

### Requirement: Complete persisted bytes decide the result

The benchmark SHALL include container index, codec identifiers, parameters,
checksums, topology, metadata, and payloads in `complete_persisted_bytes`.

#### Scenario: Candidate is locally smaller

- **WHEN** a codec payload is smaller than ZPAQ and decodes exactly
- **THEN** it may be selected only after its codec metadata cost is included

### Requirement: Every exact improvement advances its scoped baseline

The benchmark SHALL promote a candidate as the new baseline for the same
algorithm scope whenever comparable complete-byte accounting is strictly
smaller and every exactness gate passes. No minimum percentage improvement is
required.

#### Scenario: Improvement is below ten percent

- **WHEN** an exact candidate is smaller than the current comparable baseline
  by any positive number of bytes
- **THEN** the candidate becomes the new baseline for subsequent experiments

#### Scenario: Research and production baselines differ

- **WHEN** a PWA2 candidate improves the PWA2 baseline but remains larger than
  the production baseline
- **THEN** it is promoted only within PWA2 and does not implicitly replace the
  production pipeline

### Requirement: Host work cannot mutate production

The benchmark SHALL NOT modify production Dart, Swift, native archive paths,
the production bundle, or the phone.

#### Scenario: Host arm misses the gate

- **WHEN** complete persisted bytes exceed `111,961,726`
- **THEN** the arm stops before any physical-phone work
