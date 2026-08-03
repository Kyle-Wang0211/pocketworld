# Design: Joint semantic WorldPack v2 benchmark

The candidate is a versioned append-only archive of typed logical streams. It
shares one deterministic dependency graph across exact JPEG coefficient
prediction, descriptor residuals, matches, camera state, and sparse geometry.
Legacy JPEG, SQLite, and PLY files are reconstructed views, not opaque members.

The first benchmark is deliberately one cross-modal unit: the first eligible
adjacent photo pair in frozen capture order, plus the registered pose, track,
match, and sparse-point information required to predict it. Selection happens
before compression. Root and child JPEGs must round-trip byte-for-byte. Every
logical database value and ordering relation used by the unit must round-trip at
the bit level.

The photo prediction transform follows the paper's three-stage boundary:
feature-domain prediction structure, hybrid global/local disparity
compensation, and adaptive frequency-domain residual coding. A method map must
identify published support for every stage and record deviations. OpenZL or
other entropy backends are downstream variables and cannot substitute for a
missing prediction stage.

The 2026-08-03 method audit found that the public 2016 abstract and accessible
precursor papers do not disclose enough parameters or bitstream rules for a
faithful 2016 implementation, and no author-owned reference codec was found.
Therefore the first executable arm is explicitly identified as
`pocketworld_independent_v2`. It uses verified two-view correspondences, a
preregistered deterministic homography/local DCT predictor, exact coefficient
residuals, and a pinned commercial-compatible entropy backend. It SHALL NOT be
described as the Microsoft codec, and the paper's reported 31% is not its
acceptance threshold.

All side information and framing count. The candidate must be strictly smaller
than the saved incumbent bytes for the same logical slice before expansion to
eight photos and then the complete frozen project. Production remains out of
scope.
