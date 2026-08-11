# PWA2 Official Codec Backends Benchmark Design

## Goal

Measure whether pinned official OpenZL, Pcodec, or C-Blosc2 implementations can
make the already-verified PWA2 logical archive smaller than the current
`track_delta_v1 + ZPAQ` baseline of `124,401,918` bytes. The production gate
remains `111,961,726` complete persisted bytes. This is a host rejection test;
it does not modify production or authorize a phone build.

## Frozen identities

- Input SQLite: `198,983,680` bytes, SHA-256
  `0c12c0dfa76d50cae59929774242282d8236daeb852bdee6ac99c3062d6d08b0`.
- Git starting revision: `13d2a4f05d491464c537a9135496eccaa05c2358`.
- ZPAQ fallback: official 7.15 method 5, revision
  `e85ec2529eb0ba22ceaeabd461e55357ef099b80f61c14f377b429ea3d49d418`.
- OpenZL: release `v0.2.0`, commit
  `3dceb64867840201fb8f57a29d179995f700c9b8`, BSD license.
- Pcodec: release `v1.0.2`, commit
  `2d8555888b21bbaa19326580b740fa24b7da6bd3`, Apache-2.0.
- C-Blosc2: release `v3.3.0`, peeled commit
  `7265419b23872707b1b52298d5f1469c9ea7b9e7`, BSD license.

All third-party source and build products remain under a fresh `/private/tmp`
directory. The runner verifies revision and license hash before compilation.
Commercial admission remains conditional pending a production dependency and
NOTICE audit; host benchmark use is not a commercial approval.

## Arms

All arms start from the same deterministic PWA2 logical members and preserve
the same 32,768-record block boundaries, topology, row order, member names,
manifest SHA values, and random-read contract.

- **B0**: every member uses ZPAQ method 5. Frozen result: `129,567,942` bytes.
- **C**: compatible homogeneous integer and IEEE float columns may use Pcodec
  level 12. Descriptors and unsupported members retain ZPAQ. For every eligible
  payload, retain the smaller exact result between Pcodec and ZPAQ.
- **D**: descriptor root/residual/literal byte-lane streams may use OpenZL's
  release-tagged public graphs. The official graph selector may choose among
  generic, FieldLZ, delta/integer, and supported numeric graphs; other members
  use the C/ZPAQ winner. No data-specific learned graph is persisted.
- **E**: every compatible PWA2 block tests C-Blosc2 Zstd level 9 with official
  no-filter, SHUFFLE, BITSHUFFLE, and BYTEDELTA combinations that are strictly
  reversible for that element layout. It retains the smallest exact candidate
  or the ZPAQ fallback.

Every selected member records codec, codec parameters, raw length, compressed
length, raw SHA-256, and payload offset. Codec identifiers, index, checksums,
and all payloads count toward `complete_persisted_bytes`.

## Staged execution

1. Build each pinned upstream and run its own focused tests or example
   round-trip.
2. Run a deterministic synthetic fixture through the benchmark adapter and
   require byte-exact recovery, corruption rejection, and complete accounting.
3. Run one small real descriptor block plus one keypoint and one match block.
   A backend that expands every compatible sample is recorded and skipped for
   the full arm.
4. Run each viable complete arm once on the frozen database. No repeat runs are
   required for a deterministic size result.
5. Fully decode the selected container and reuse PWA2 verification to check
   every logical value, order, random descriptor reads, SQLite materialization,
   `PRAGMA integrity_check`, and source immutability.

## Stop and acceptance rules

- Any byte, bit-pattern, order, checksum, random-read, materialization, or
  source-identity failure rejects that arm immediately.
- A backend unavailable for a compatible upstream/toolchain reason is reported
  as blocked; it is never silently replaced by a reimplementation.
- A valid arm larger than `124,401,918` bytes is inferior to production.
- A valid arm between `111,961,727` and `124,401,918` is a local improvement but
  does not enter production.
- Only a valid arm no larger than `111,961,726` may advance to a separately
  authorized physical-iPhone benchmark.
- No Dart, Swift, production native library, bundle, or phone installation is
  in scope.

