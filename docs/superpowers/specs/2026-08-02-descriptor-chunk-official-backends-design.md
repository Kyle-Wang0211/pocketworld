# Minimal Descriptor Chunk Official Backend A/B Design

## Scope

This is a host-only screening experiment. It does not change production code,
build or install an app, access the phone, or process a 100 MB corpus.

The measured unit is the smallest complete `similarity_forest_v1` chunk that
contains both roots and predicted descriptors:

- concatenate descriptor rows in SQLite `image_id` order;
- retain exactly 16,384 descriptors of 128 bytes each;
- descriptors 0 through 8,191 are roots;
- descriptors 8,192 through 16,383 use the existing deterministic
  `similarity_forest_v1` parent builder;
- persist every parent delta required to reverse the residual transform.

The original descriptor bytes are 2,097,152 bytes. A candidate's measured
size includes its fixed archive envelope, compressed descriptor payload, and
the complete parent sidecar. No candidate may omit decoding metadata.

## Arms

All arms receive exactly the same transformed descriptor array and parent
sidecar.

- Existing baseline: ZPAQ 7.15 method 5.
- Existing official screens: Pcodec 1.0.2 level 12, OpenZL 0.2.0 existing
  numeric selector, and C-Blosc2 3.3.0 Zstd 9 with NONE, SHUFFLE, and
  BITSHUFFLE.
- New OpenZL arm: official `serial` raw-byte profile with ACE training and
  clustering disabled. The `u8` profile was rejected during harness validation
  because its selected descriptor candidate could not be reattached across the
  serial-to-numeric graph boundary. Training is restricted to this one chunk;
  the persisted byte count is the self-contained frame that a generic decoder
  can decode without the training-time compressor.
- New B2ND arm: the logical `[16384, 128] uint8` array is persisted as 16,384
  fixed-width `S128` B2ND records so the official SHUFFLE filter can expose all
  128 lanes to the fixed `BLOSC_FILTER_BYTEDELTA` (ID 35), followed by Zstd 9.
  This changes no descriptor byte or order. Lossy filters are forbidden.

## Exactness and accounting

An arm is valid only if:

1. its decoded transformed array is byte-identical and has the same SHA-256;
2. its decoded parent sidecar is byte-identical;
3. inverse residual reconstruction yields all 2,097,152 original bytes in the
   original order with identical SHA-256;
4. deterministic single-byte corruption is rejected by the codec or the
   archive SHA-256 gate;
5. the source SQLite file remains unchanged.

Size comparison occurs only after all gates pass. The winner is the smallest
complete persisted candidate, even if the improvement is below 10%; the result
is only a local micro-benchmark baseline and cannot promote production.

## Stopping rule

Run one extraction and one encode/decode/corruption cycle per arm. Do not expand
to another chunk, the full SQLite database, 100 MB, or an iPhone in this task.
If an official pinned dependency cannot build or its requested feature is not
available at the frozen revision, record the arm as blocked instead of silently
substituting a different implementation.
