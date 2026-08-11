# Design: PWA2 structure + ZPAQ benchmark

The benchmark serializes every query-visible SQLite value into a deterministic
logical container. Large computer-vision arrays are separated from SQLite
pages and grouped into statistically homogeneous bounded blocks. All persisted
payload members use the same pinned ZPAQ 7.15 method 5 backend as the baseline.

Descriptor nodes derive a deterministic forest from verified
`two_view_geometries` matches. Roots, parent-child residuals, and unmatched
literals are persisted separately, with 128 byte lanes inside each bounded
record block. Keypoints and match pairs are stored by exact numeric byte lane.
All remaining tables and fields use deterministic typed-row encoding.

The reader validates the container index, member bounds, dependency IDs,
lengths, and hashes before exposing data. It supports bounded record reads and
can materialize a logically equivalent SQLite database for complete canonical
comparison. The source remains read-only.

The archive's index, schema, topology, permutation/order metadata, compressed
members, and checksums all count toward the measured size. Host results can
reject but cannot select a production winner.
