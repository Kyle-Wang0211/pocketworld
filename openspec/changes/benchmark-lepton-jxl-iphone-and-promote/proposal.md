# Change: Benchmark official Lepton against production JXL on iPhone

## Why

Official Rust Lepton 0.5.8 beat production JPEG XL effort 10 by 55,614 bytes
on one identical JPEG in a host minimum-unit screen. Host evidence cannot select
a production codec, and the current app must keep byte-exact JPEG recovery and
the production bundle's data container untouched.

## What Changes

- Build official `lepton_jpeg` 0.5.8 as an iOS ARM64 static library behind a
  thin file-oriented C ABI.
- Add an independent Dart benchmark entrypoint and signed test bundle with ID
  `com.kyle.PocketWorld.LeptonBench`.
- Run JXL effort 10 and Lepton on the same frozen JPEG on the physical iPhone,
  verifying SHA-256 and byte equality after each official decode.
- Promote Lepton only if the phone-produced archive is strictly smaller while
  both arms remain exact.
- If promoted, keep legacy JXL archives readable and use Lepton only for future
  projects.

## Impact

- Benchmark-only Rust/C ABI, Dart entrypoint, build/run script, tests, and
  reproducibility evidence are added before any production change.
- A passing phone result conditionally enables changes to photo archive policy,
  manifest, transaction, resolver, runtime codec selection, iOS linking, and
  bundled notices.
- The production bundle is never installed, updated, uninstalled, or accessed
  by the benchmark.
