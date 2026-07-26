# PWOfficialSfm strict parity report — 2026-07-22

## Verdict

**PASS.** The initial native “官方” route is a physically separate build of
the exact shipping self-route algorithm source. Its only differences are
public/config/symbol/sidecar ownership names and separate framework packaging.
It does not contain the later b930 resume/tombstone behavior.

## Evidence chain

| Check | Evidence | Result |
|---|---|---|
| Shipping archive identity | SHA-256 `9c88366a1db32b42c3c402616c9eae90b76279a68b16763aefbbcfebeec07618` | PASS |
| Exact adapter source | `ea77244a` adapter/L1/arbitration/ABI + dirty ghost `d32694cb...` | PASS |
| Byte oracle | archive member = preserved build object = reconstructed object; SHA-256 `a01a7c356f5a8efc052b40d096566dbd5c65adb1a1346ff73bad73c606981c2d` | PASS |
| Negative ghost control | committed ghost gives different size/hash and 4-arg symbol | PASS |
| Source-copy gate | 11 algorithm source/header files match after reversing allowed ownership names | PASS |
| Product wrapper gate | export shim, Metal matcher, telemetry match shipping sources after mechanical names/visibility normalization | PASS |
| Mirrored build inputs | product vendor files byte-match Aether official build inputs | PASS |
| Rejected revision control | b930-only markers exist in b930 but not official source/binary | PASS |
| Shipped positive controls | `missing_jpeg=`, `n_frames_missing_jpeg`, and five-argument `FitFloorPlane` are present | PASS |
| ABI | 26 self/official C signatures correspond one-to-one | PASS |
| Dynamic boundary | exactly 26 exports; no public self/internal symbols; fixed install name | PASS |
| Link boundary | Mach-O `TWOLEVEL`, `NOUNDEFS`, no custom pipeline undefined symbols | PASS |
| Configuration boundary | no unprefixed self-route `AETHER_*` runtime keys | PASS |
| Native storage boundary | only official-prefixed sidecar filenames | PASS |

## Rejected b930 markers

The gates require all of the following to remain absent:

- `AETHER_SFM_ERR_BUSY`
- `AppendRemovedId`
- `RemovedSidecarPath`
- `.removed`
- `tombstone`

## Acceptance commands

```sh
vendor/official_sfm/scripts/rebuild_native.sh
vendor/official_sfm/scripts/verify_abi_signatures.py
vendor/official_sfm/scripts/verify_boundary.sh
vendor/official_sfm/scripts/verify_source_parity.py
pod lib lint vendor/official_sfm/official_sfm.podspec \
  --allow-warnings --skip-tests
```

Observed deterministic gate results:

```text
PASS: 26 pwsfm/pwofficial function signatures are identical
PASS: 26 official ABI exports; TWOLEVEL/NOUNDEFS; isolated install_name/config namespace
PASS: native official route is ea77244a self semantics plus only
      config/symbol/sidecar ownership names and the frozen dirty ghost-mask
```

The inherited iOS 26.2 object minimum is documented in `PROVENANCE.md`; this
report does not claim compatibility with earlier iOS runtimes.
