# Design: eight-photo global JPEG collection codec

The input is the first eight photos of the frozen official capture. The graph
stage examines all verified relationships and deterministically constructs one
maximum spanning tree without using compressed size. Each non-root image is
predicted from its tree parent with global homography, locally interpolated
displacement, bounded coefficient similarity search, reconstructed-child intra
context, and zero fallback.

All predictions are reversible because the archive stores exact coefficient
residuals and the decoder repeats only integer/fixed-point computations. The
residual and side information are split by component, frequency band, and role
before the unchanged ZPAQ method-5 backend. The root reuses its saved verified
JXL member. All persisted bytes count.

The executable is a declared PocketWorld implementation. Public sources do not
provide enough detail or code to claim reproduction of either the Microsoft
2016 codec or FDBM 2024. Their collection graph, hybrid compensation, and
frequency-domain stages are method evidence, while all concrete parameters and
syntax are preregistered here.

