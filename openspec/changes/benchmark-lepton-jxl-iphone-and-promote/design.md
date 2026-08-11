# Design: Official Lepton iPhone gate and conditional promotion

## Context

The current production path uses pinned libjxl 0.12.0 in exact JPEG
reconstruction mode at effort 10. A host-only minimum-unit audit found official
Rust Lepton 0.5.8 smaller on the same 2,725,495-byte JPEG, but did not build or
run it on iOS.

The existing independent SQLite benchmark already proves a safe packaging
pattern: Flutter supplies a Dart entrypoint, Xcode build settings override the
bundle identity, the app is signed with a wildcard benchmark profile, input is
copied into the benchmark container, and a JSON result is copied back.

## Decisions

### Use the published official crate without algorithm changes

The static library depends on exactly `lepton_jpeg = 0.5.8` and calls the same
feature presets and default thread pool as the official utility/DLL. The local
crate exports only file-oriented C ABI functions. It does not fork or edit the
codec.

### Keep benchmark and production gates separate

The benchmark can be built, signed, installed, and run without linking Lepton
into the production target configuration. Production source changes are made
only after a durable physical-iPhone result passes all pre-registered gates.

### Use one immutable minimum unit

The input is the exact JPEG previously used for the host JXL/Lepton A/B. Its
length and SHA-256 are compiled into the benchmark contract. Any other input is
rejected so archive sizes remain comparable.

### Fail closed

Both codecs must produce an archive, reconstruct with their own official
decoder, match input length and SHA-256, and pass streaming byte comparison.
Lepton must then be strictly smaller. Any panic, native status, missing file,
identity mismatch, or equality failure produces a failed verdict and leaves
production on JXL.

### Preserve legacy JXL if promotion passes

Future Lepton policy and manifests receive a new schema/codec identity rather
than reinterpreting existing JXL records. Dispatch is based on persisted codec
identity. Existing `.jxl` archives remain untouched and resolvable.

## Risks

- **Rust target/toolchain drift:** use a task-local pinned toolchain, locked
  dependencies, and record hashes.
- **Static linker drops FFI symbols:** force-load the benchmark archive and
  verify exported symbols before signing and after building the app.
- **Benchmark accidentally targets production:** assert the built Info.plist,
  signing application identifier, command text, and result bundle ID.
- **Lepton size win but production integration regression:** production
  promotion also requires transaction, legacy-read, gate, cancellation/safe
  boundary, and notice tests; otherwise the benchmark winner is not shipped.
- **Commercial obligations:** Apache-2.0 permits the candidate direction, but
  distribution remains conditional on complete NOTICE and dependency-license
  inclusion and final binary audit.

## Physical-iPhone decision

Run `20260802T134334Z` used the registered 2,725,495-byte JPEG on the physical
iPhone in `com.kyle.PocketWorld.LeptonBench`. JXL effort 10 produced 2,215,345
bytes and official Lepton 0.5.8 produced 2,159,731 bytes. Both official
decoders restored the source byte-for-byte with SHA-256
`a1cb8de1d3b91edbb7e05233c7930200c46e04554c3651153e267e5abd262138`.
Lepton was therefore 55,614 bytes (2.510399%) smaller and passed the registered
strict promotion gate.

Future captures use policy v2 with codec identity `lepton`; policy v1 remains
pinned to JPEG XL for legacy reads. Native cancellation uses a monotonic
generation checked at the Rust I/O boundary, so a production or system
interruption removes any partial destination and leaves the source JPEG
authoritative. The production binary was link-verified only and was not
installed by this benchmark task.
