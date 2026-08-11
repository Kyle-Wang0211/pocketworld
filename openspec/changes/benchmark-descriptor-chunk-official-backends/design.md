# Design

The experiment extracts only the first 16,384 descriptors in deterministic
SQLite order. The first 8,192 are roots and the second 8,192 are predicted by
the existing `similarity_forest_v1` builder. This is the smallest chunk that
exercises the winning structure while remaining independently reversible.

Every backend compresses the identical transformed descriptor bytes. The
common archive accounting adds the same envelope and exact parent sidecar. A
backend frame must be self-contained for decode; training artifacts that are
not needed by the decoder are not archive bytes, while any decoder dependency
must be counted.

The benchmark accepts no lossy filter, no descriptor reorder, and no omitted
metadata. It runs once per arm and stops at the micro result.
