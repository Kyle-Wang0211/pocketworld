# PWOfficialSfm

`PWOfficialSfm.xcframework` is the native runtime for Pocketworld's independent
“官方” capture route. It starts as a physical copy of the product `pwsfm_*`
pipeline but is loaded as a separate dynamic image with a separate
`pwofficial_*` ABI and separate `OFFICIAL_AETHER_*` configuration namespace.
There is no resolver or native fallback to `pwsfm_*`.

The device framework contains the copied streaming COLMAP runtime, copied
DSP-SIFT implementation, copied Dawn extractor archive, copied Metal matcher,
and copied telemetry probe. The simulator slice is an independent fail-closed
stub and supports both arm64 and x86_64.

Regenerate and verify the vendored artifact:

```sh
vendor/official_sfm/scripts/rebuild_native.sh
pod lib lint vendor/official_sfm/official_sfm.podspec --allow-warnings --skip-tests
```

The boundary gate requires exactly the frozen 26-symbol public surface,
`@rpath/PWOfficialSfm.framework/PWOfficialSfm`, no exported self/internal
symbols, no custom pipeline undefined symbols, and no unprefixed `AETHER_*`
runtime configuration keys. The source-parity gate freezes the native
algorithm at the shipping archive's exact `ea77244a + dirty ghost-mask`
identity and rejects the later b930 resume/tombstone behavior. See
`PROVENANCE.md` and `PARITY_REPORT.md` for the evidence and inherited iOS
deployment limitation.
