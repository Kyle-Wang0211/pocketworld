## Why

Future official captures retain `official_sfm_live.db` after reconstruction.
These cold SQLite databases materially increase local and cloud storage, while
remaining valuable for explicit point-cloud recovery. The accepted physical
iPhone benchmark selected ZPAQ 7.15 method 5 over LZMA2 preset 9 for this cold
data, provided restoration remains byte-for-byte exact.

## What Changes

- Mark only newly created official captures with a durable database-archive
  policy.
- After the official final PLY and metadata are durable and reconstruction has
  released SQLite, archive `official_sfm_live.db` with pinned ZPAQ 7.15 method
  5.
- Decompress every candidate and require exact length, SHA-256, and byte
  equality before committing an archive or deleting the database.
- Keep the database when SQLite sidecars exist, the codec fails, verification
  fails, the result is not smaller, or foreground capture/reconstruction is
  active.
- Restore a verified archive on demand before official recovery, then
  re-archive the resulting database after recovered reconstruction completes.
- Reuse the existing official cold-archive coordinator; do not add behavior to
  the retired self-developed pipeline.
- Compile the pinned portable ZPAQ C++ core behind a file-oriented Dart FFI
  contract and ship its upstream license and revision evidence.

## Capabilities

### New Capabilities

- `future-official-database-archive`: future-only eligibility, byte-exact ZPAQ
  transactions, crash reconciliation, recovery materialization, and
  re-archiving for the official pipeline.

### Modified Capabilities

- `future-photo-archive`: the existing official cold coordinator also sequences
  the independent database transaction after JPEG XL photo work.

## Impact

- New Dart policy, manifest, codec, transaction, resolver, and FFI modules.
- Official capture creation, cold coordinator/runtime, recovery discovery, and
  Me-page recoverability checks.
- Pinned libzpaq 7.15 C++ source, a portable C ABI, Runner build wiring, native
  tests, build marker, and third-party notice.
- No migration or automatic write under `captures/`; no change to
  `sfm_live.db`; no modification of historical official projects.
