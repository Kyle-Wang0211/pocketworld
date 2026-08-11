## 1. Contract

- [x] 1.1 Freeze input, baseline, metrics, stopping rule and artifact identity.
- [x] 1.2 Validate this OpenSpec change strictly.

## 2. Native TDD

- [x] 2.1 Add RED exactness, determinism, table-coverage and cancellation tests.
- [x] 2.2 Implement page-preserving v2 forward and inverse transforms.
- [x] 2.3 Make native tests GREEN without changing existing transform behavior.

## 3. Benchmark TDD

- [x] 3.1 Add RED contract tests for the third benchmark arm and host early stop.
- [x] 3.2 Add v2 to host and independent-iPhone benchmark-only paths.
- [x] 3.3 Make focused tests GREEN.

## 4. Execution

- [x] 4.1 Run one host pass and retain only hashes and metrics.
- [x] 4.2 Stop if v2 is not strictly smaller than 124,401,918 bytes.
- [x] 4.3 Do not build or install the independent phone bundle because the host
      candidate was 64,155 bytes larger than the baseline.

## 5. Verification

- [x] 5.1 Run native, Dart, OpenSpec, analysis and regression suites.
- [x] 5.2 Report an evidence-backed accept or reject decision without touching the
      production bundle.
