# Proposal: Benchmark full descriptor similarity forest with ZPAQ

## Why

The current exact SQLite research baseline, `track_delta_v1 + ZPAQ 7.15
method 5`, predicts only 224,119 of 1,251,246 descriptors because its parent
edges come only from verified COLMAP tracks. The next experiment must isolate
whether expanding prediction coverage across the full descriptor population is
worth space after the decoder metadata is counted.

## What Changes

- Add a host-only A/B benchmark over the frozen 198,983,680-byte SQLite input.
- Keep the ZPAQ revision, method, container layout, source bytes, and exactness
  gates identical between both arms.
- Arm A uses the existing verified-track forest.
- Arm B uses an encoder-only Faiss similarity index to choose an earlier parent
  for every descriptor after the initial root block.
- Store B's backward parent distances in a reversible varint sidecar and count
  it inside the ZPAQ input and final archive size.
- Restore and verify the original database byte-for-byte after each arm.

## Impact

This change adds experiment code and evidence only. It does not alter the
PocketWorld production archive path, the iPhone bundle, or historical projects.

