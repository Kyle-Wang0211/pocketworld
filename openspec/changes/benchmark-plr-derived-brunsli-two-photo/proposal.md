# Change: Benchmark a PLR-derived Brunsli two-photo exact archive

## Why

The public PLR release contains a useful learned entropy architecture but no
complete target-aware entropy bitstream or exact-JPEG wrapper. Previous local
residual experiments were not faithful completions and cannot decide whether a
finished learned JPEG archive beats the current JXL exact-JPEG baseline.

The next valid step is a new, honestly named PLR-derived completion. Before any
training, it must prove that a pinned mature JPEG container can physically
separate every original coefficient from the reconstruction state and restore
the two immutable PocketWorld JPEG files byte for byte.

## What Changes

- Freeze two adjacent 4224x2376 source JPEGs, official PLR and Brunsli source
  revisions, exact model accounting, project scope, and stop rules.
- Separate provisional model-size accounting from the final trained-artifact
  accounting used by the terminal verdict.
- Build a standalone Mac research adapter around unmodified Brunsli sources.
- Store exact reconstruction state and DCT coefficients as separate,
  checksummed payloads, then reconstruct both original JPEGs exactly.
- Preserve corruption, revision, environment, DVC, and MLflow evidence.
- Stop before learned entropy training, JXL measurement, phone work, production
  edits, or a complete-project run.

## Impact

This change creates only a Mac research experiment, its tests, and evidence.
It does not change PocketWorld production code, access the production iPhone,
install a bundle, or replace any production codec.
