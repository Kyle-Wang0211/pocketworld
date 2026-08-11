## ADDED Requirements

### Requirement: Immutable consecutive production sample

The experiment SHALL select the first consecutive frames from the verified
photo-bundle order until cumulative JPEG bytes are at least 100 MiB, and SHALL
refuse to run if the resulting ordered manifest differs from the registered
37-file, 105,908,333-byte input identity.

#### Scenario: Input drift

- **WHEN** any selected JPEG, bundle, pose file, or sparse PLY hash differs
- **THEN** the experiment SHALL stop before extraction or compression

### Requirement: Byte-exact JPEG reconstruction

The experiment SHALL preserve enough JPEG syntax and coefficient information
to restore every source file byte-for-byte.

#### Scenario: Reconstructed JPEG differs

- **WHEN** length, byte comparison, or SHA-256 differs for any frame
- **THEN** the arm SHALL fail and its ratio SHALL NOT be considered

### Requirement: Real geometry-guided groups

Each non-anchor frame SHALL use registered SfM pose data and sparse PLY
projections to construct its coefficient-block predictor.

#### Scenario: Geometry is unavailable

- **WHEN** the selected frames lack registered poses or no valid sparse
  projections are produced
- **THEN** the experiment SHALL fail rather than silently report a temporal-only
  predictor as SfM-guided

### Requirement: Bounded random access

The experiment SHALL create independent group-size-4 and group-size-8 archives.

#### Scenario: One requested photo

- **WHEN** the fixed-seed audit requests one photo
- **THEN** the decoder SHALL open one group and reconstruct no more than that
  arm's group size

### Requirement: Pre-registered rejection threshold

The experiment SHALL use 2.165x as the immutable minimum photo ratio.

#### Scenario: Both arms miss the threshold

- **WHEN** both verified ratios are below 2.165x
- **THEN** the final verdict SHALL be `reject-before-phone` and no independent
  phone bundle SHALL be built

#### Scenario: An arm reaches the threshold

- **WHEN** a verified arm reaches at least 2.165x
- **THEN** the final verdict SHALL be `eligible-for-independent-phone-bundle`
  without changing production behavior
