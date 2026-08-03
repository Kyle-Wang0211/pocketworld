# Change: Gate official PLR on one exact PocketWorld JPEG

## Why

PLR reports strong lossless JPEG recompression on pathology data, but a paper
rate estimate is not a PocketWorld archive. Before any large training run or
cross-photo work, the published implementation must prove that it can create a
complete stored bitstream and reconstruct an arbitrary source JPEG byte for
byte.

## What Changes

- Stop the old PocketWorld cross-photo predictor experiment.
- Freeze the public PLR revision and audit its official train, encode, decode,
  checkpoint, and JPEG reconstruction paths before installing a large runtime.
- If the audit passes, train or adapt one fixed global model on natural photos,
  then test exactly one registered PocketWorld JPEG.
- Count the complete stream, container overhead, exact-JPEG reconstruction
  data, and amortized distributable model bytes.
- Require decoded source length, SHA-256, and every byte to match.
- Scale to a conditional cross-photo model or complete project only when the
  registered PLR effective size is strictly below the saved same-input JXL
  effort-10 result.

## Impact

This change adds experiment documentation and immutable audit evidence only.
It does not change production code, access the production app, install a phone
bundle, or create a project.
