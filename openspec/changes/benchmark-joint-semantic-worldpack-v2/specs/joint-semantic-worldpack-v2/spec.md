## ADDED Requirements

### Requirement: One shared semantic dependency group

The benchmark SHALL encode two adjacent photographs and their required camera,
SfM, descriptor, match, and sparse-geometry records as one versioned dependency
group rather than independent opaque files.

#### Scenario: Deterministic input selection

- **WHEN** the frozen complete capture is inspected
- **THEN** the first pair satisfying the preregistered capture-order and shared-
  track eligibility rule SHALL be selected
- **AND** encoded-size results SHALL NOT influence pair selection

### Requirement: Exact source reconstruction

The candidate SHALL restore every original JPEG byte and every registered
logical numeric bit, identity, count, and order represented by the joint unit.

#### Scenario: Successful exact round trip

- **WHEN** the candidate dependency group is decoded
- **THEN** both JPEG lengths, bytes, and SHA-256 values SHALL match their source
- **AND** every descriptor byte and IEEE float bit SHALL match
- **AND** every track, match, pose, sparse-point identity, count, and order SHALL
  match

#### Scenario: Corrupt dependency

- **WHEN** a payload, index, selector, model, mapping, or dependency hash is
  corrupted or absent
- **THEN** decoding SHALL fail closed before returning source data

### Requirement: Published-method fidelity

The candidate SHALL map every claimed photo-collection stage to the accessible
2016 paper, 2015 SfM extension, or author artifact and SHALL label every
deviation.

#### Scenario: Missing method detail

- **WHEN** a required transform, parameter, bitstream rule, or dependency cannot
  be recovered from authoritative evidence
- **THEN** the benchmark SHALL stop before claiming a faithful reproduction
- **AND** SHALL NOT silently replace the missing detail with a custom heuristic

### Requirement: Complete persisted byte comparison

The candidate SHALL count every byte required for independent decoding and
compare against the saved incumbent for the identical logical slice.

#### Scenario: Candidate does not win

- **WHEN** exact candidate bytes are greater than or equal to incumbent bytes
- **THEN** the registered configuration SHALL stop before an eight-photo run
- **AND** production and the phone SHALL remain unchanged

#### Scenario: Candidate wins

- **WHEN** exact candidate bytes are strictly smaller than incumbent bytes
- **THEN** the result MAY authorize a separate eight-photo experiment plan
- **AND** SHALL NOT itself authorize production promotion

### Requirement: Saved complete baseline remains immutable

The experiment SHALL reference the recorded `471,146,040`-byte complete
baseline and its evidence hash without executing the baseline encoders again.

#### Scenario: Complete-project expansion is later authorized

- **WHEN** a later candidate reaches the complete frozen project
- **THEN** only the candidate SHALL execute
- **AND** the product metric SHALL use the original `638,645,632`-byte input
  denominator
