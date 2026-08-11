# Minimal Descriptor Chunk Official Backend A/B Implementation Plan

> Execute only in the shared PocketWorld checkout. Preserve unrelated dirty
> work. Do not change production behavior, stage or commit files, touch the
> phone, or run a 100 MB benchmark.

**Goal:** Complete a clean exact-lossless A/B on one 2 MiB descriptor chunk for
OpenZL ACE, B2ND BYTEDELTA, and the existing official backend screens.

**Architecture:** A benchmark-only extractor builds one complete
`similarity_forest_v1` chunk from the immutable SQLite source. Small official
codec adapters serialize self-contained frames. A common envelope counts the
same header and parent sidecar for every arm and performs reconstruction and
corruption gates.

**Tech stack:** C++17, SQLite, Faiss 1.14.0, official libzpaq 7.15, OpenZL
0.2.0, C-Blosc2/B2ND 3.3.0, Pcodec 1.0.2, shell, Dart contract test.

### Task 1: Freeze the contract and obtain RED

Create the OpenSpec delta, experiment contract, input manifest, Dart contract
test, and native codec test. Run the tests before the implementation exists and
record the expected failure.

### Task 2: Implement the minimum chunk and exact gates

Add a benchmark-only chunk extractor/transform helper and tests for fixed
dimensions, complete parent metadata, exact inverse, and corruption rejection.

### Task 3: Add pinned official backend adapters

Build all three upstream revisions in a temporary directory. Add independent
OpenZL ACE and B2ND BYTEDELTA adapters without modifying the older adapter.
Reuse the existing official Pcodec/OpenZL/Blosc2 adapter for the existing arms
and the pinned ZPAQ bridge for the baseline.

### Task 4: Run exactly one micro A/B

Run each arm once on the same transformed 2 MiB descriptor chunk. Persist only
the compact JSON result, hashes, immutable parameters, command, and evidence.
Delete temporary frames, decoded files, clones, and build outputs afterwards.

### Task 5: Verify and adjudicate

Run the focused Dart and native tests again, inspect the result and diff, and
report the smallest valid complete candidate. Explicitly label the result as
host-only micro evidence with no production promotion.
