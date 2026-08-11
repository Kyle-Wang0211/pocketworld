## 1. Contract and tests

- [x] 1.1 Freeze source, revisions, Faiss parameters, metrics, and stop rules.
- [x] 1.2 Add failing unit tests for forest validity, parent sidecar round-trip,
  and exact modulo-256 transform round-trip.

## 2. Benchmark implementation

- [x] 2.1 Implement deterministic encoder-only similarity forest construction.
- [x] 2.2 Implement parent sidecar encode/decode and validation.
- [x] 2.3 Implement the common exact SQLite container and both A/B arms.
- [x] 2.4 Keep all implementation outside the production app path.

## 3. Evidence

- [x] 3.1 Run focused unit/contract tests.
- [x] 3.2 Run exactly one complete A/B on the frozen input.
- [x] 3.3 Verify source unchanged, byte equality, SHA-256 equality, SQLite
  integrity, parent DAG, and full size accounting.
- [x] 3.4 Record the result and local-baseline verdict; remove large temporary
  artifacts while preserving hashes and metrics.
