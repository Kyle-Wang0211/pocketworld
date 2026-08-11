## Why

Raw ZPAQ method 5 is byte-exact but treats `official_sfm_live.db` as an
unstructured byte stream. In the five preserved production-device databases,
the `descriptors.data` BLOBs are `rows × 128` uint8 matrices and account for
about 78%–80% of the file. Grouping values by descriptor dimension before ZPAQ
may expose stronger local contexts without discarding or quantizing any byte.

## What Changes

- Add an independent, reversible SQLite descriptor preprocessor that operates
  only on a temporary copy of a closed database.
- Parse the existing SQLite table b-tree and overflow chains without rebuilding
  the database, and transform only the physical bytes belonging to
  `descriptors.data`.
- Benchmark raw ZPAQ against a deterministic, reversible modulo-256 descriptor
  delta along verified cross-image match tracks.
- Require source immutability, exact restored length, byte equality, SHA-256
  equality, SQLite integrity, deterministic output, and fail-closed corruption
  behavior across synthetic, randomized, real-database, restart, and physical
  iPhone tests.
- Keep the current raw-ZPAQ production path unchanged during the benchmark.
  Admit this local preprocessing step only when it passes every hard gate and
  makes every measured complete archive strictly smaller; reserve the 10%
  threshold for an invasive COLMAP storage-layer replacement.

## Capabilities

### New Capabilities

- `sqlite-descriptor-zpaq-preprocessing`: portable reversible preprocessing and
  evidence-gated selection for future official SQLite archives.

### Modified Capabilities

- None during the benchmark phase. Production archive policy and deletion
  behavior remain unchanged until a separately reviewed integration step.

## Impact

- New portable C++ parser/transform module, host/native tests, benchmark harness,
  and reproducible experiment records.
- Read-only use of preserved copies of five physical-iPhone databases.
- No writes to the production iPhone container and no historical migration.
- No Apple-only compression API and no logical SQLite dump or rebuild.
