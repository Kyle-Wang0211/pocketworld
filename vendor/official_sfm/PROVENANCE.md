# PWOfficialSfm provenance — 2026-07-22

## Frozen self-route identity

- Pocketworld revision at copy start:
  `2279d6ff6d7897b38e569928ec16ff21a9a924b9`
- Shipping self core archive:
  `vendor/aether_ffi/libs/ios-arm64/sfm/libglomap_core.a`
- Shipping self core SHA-256:
  `9c88366a1db32b42c3c402616c9eae90b76279a68b16763aefbbcfebeec07618`
- Pocketworld commit introducing that exact archive:
  `cb72962ff8cbc45dcaf44cf88df6b39f8f9ec90f`
- Git blob identity of that exact archive:
  `40016129f4d85d63eb8959f7fad994f92599b584`
- Shipping self GPU extractor SHA-256:
  `1e1d7660bfe487005eadd8ef27259b1e4e262bb007ccf973b1026743b460964d`
- Exact committed source snapshot:
  `ea77244a8fd54153544cddaf95b56c0010d575ca`
- Build-time committed parent:
  `8952bfc76e247a9e2674c0e9c7bbc09ef37c9efe`
- Required build-time dirty override, `aether_ghost_mask.h` SHA-256:
  `d32694cb42451095a66a093d61f47b668f075423733e5aabfe62944551e0ce20`
- Exact equivalent source tree for `ea77244a`:
  `724c84dc9fd3a1daec1894c3f567f2df6be6fc5e`
- Dirty ghost-mask Git blob:
  `3a752fd3fd4a366d3e601f6dda5a3b1d99fb0d16`
- Combined build-time dirty patch stable ID:
  `973464969a96f23dc7f3df0c65e9cb185db61404`
- Combined full-index patch stream SHA-256:
  `8f1847c322b1264067e12b3a9408f36b6a6ea3f541fc0f677be70a8374544a43`
- Rejected later revision:
  `b930ab185135dfbd172aef7c2bbeed67ef315f75`

The archive was built at 2026-07-20 20:41:59 +0800 while `ea77244a` was
committed at 21:08:06. Forensic reconstruction proves that the build used
parent `8952bfc` plus the working changes subsequently captured by `ea77244a`,
and the already-dirty ghost-mask header. Therefore `ea77244a + d32694cb...`,
not the later repository HEAD, is the frozen algorithm identity.

## Byte-level adapter oracle

The following three objects are byte-identical, size 566704, SHA-256
`a01a7c356f5a8efc052b40d096566dbd5c65adb1a1346ff73bad73c606981c2d`:

1. `aether_sfm_c.cc.o` extracted from the shipping archive.
2. The preserved original CMake build object from 2026-07-20 20:39:41 +0800.
3. A clean reconstruction compiled with the preserved AppleClang 17 / iOS
   26.2 arm64 command from `ea77244a` sources plus dirty ghost-mask
   `d32694cb...`.

Changing only the ghost-mask input to the committed `ea77244a` version
(`51da2cf0...`) produces a different object (`5f9798ada3...`, size 566720) and
a four-argument `FitFloorPlane` symbol instead of the shipped five-argument
form. The dirty override is therefore required source, not an assumption.

The later `b930ab` source adds `AETHER_SFM_ERR_BUSY`, `AppendRemovedId`,
`RemovedSidecarPath`, `.removed` persistence, and resume/tombstone behavior.
Those markers are absent from the shipping archive and from this official
copy. The earlier b930-based copy was rejected and rebuilt.

## Frozen source hashes before ownership renaming

- Streaming adapter: `32d708c37ea65fac134daeac63a3baea817800361bdf07e0f5489480f3133a87`
- Threaded extractor: `8a7501429f3e2dab88c7754d274d45e469ccc7ae1bb7384a41e4b865a6c4e159`
- DSP-SIFT: `26416fa017773dacd7165d1880dadb958e5c7ca78eeb258c08fec423e18b3941`
- Dawn DSP-SIFT: `9493748e207b254ee980ebc1582ccbfe7e0718754ded5309ac6e6a3a434073d8`
- Incremental pipeline: `be298c79eeaaf6411a9db749b7a5015c7f056782b60a2f98577fe2c3e51a1cef`
- BA backend: `dd9c4b70b945486c5cb7c7711ca3dfff673dde7223937a406bd3d56d5a3cc136`
- L1 plan: `c6d667a69c9e35c785d30146da457397ed68804addd6a9a8eb7877a7ac928f15`
- L1 arbitration: `d4c167353b5d4e3d2cb7c7f547dc9e35d79c4f8b7354396437929c544c87e86b`
- Type/ABI header: `11492767577dc1cfb8675fcabd9fc01bfdcd8675aa4ad78bde7771e659403878`
- Self app's product-facing unused `BUSY` ABI superset header:
  `3b2b005e2d1f31d68a8bb4e1b5b6d8860f5b44d44a65d30d19aa7dd8a90ee649`
- Dirty ghost-mask override: `d32694cb42451095a66a093d61f47b668f075423733e5aabfe62944551e0ce20`
- Production export shim: `517b8dd64b401c4e1185af723cd78ded82cba835f96d2542fe688ad6a28ae1d9`
- Production Metal matcher: `3906e349babc58950202ed4ce951013498ae6d1f07ef22469d80d1adaec252ed`
- Production telemetry probe: `ecc0137513672378b775ccdb92a8c439b092f7afcdb35944ead1ca7c27e210aa`

The backend was compiled against the `114927...` header without `BUSY`; the
self app later carried `3b2b00...` as a product-facing enum superset. That
unused declaration does not change the shipping backend. The official route
therefore uses the actual backend header and does not expose or implement
`AETHER_SFM_ERR_BUSY`.

## Intentional mechanical deltas only

1. Public functions are renamed from `pwsfm_*` to `pwofficial_*`.
2. Runtime configuration keys are renamed from `AETHER_*` to
   `OFFICIAL_AETHER_*`, including `AETHER_L1_DUMP`; defaults and branches are
   unchanged. ABI/result strings named `AETHER_SFM_*` remain unchanged.
3. The Metal symbol/log identity is renamed from `pwsfm_gpu_match` to
   `pwofficial_gpu_match`.
4. Native sidecars are renamed to `official_sfm_fed_frames.jsonl` and
   `official_finalize_segments.json` (including `.tmp`).
5. The copied telemetry entry point receives the public visibility attribute
   needed by the separate framework.
6. Internal COLMAP/Aether/C++ symbols are hidden inside a dynamic framework.
7. The simulator is an independent fail-closed arm64/x86_64 stub; it never
   resolves or falls back to the self route.

`verify_source_parity.py` reverses only these ownership names and byte-compares
every algorithm source/header against the frozen snapshot. It also compares
the copied product shim/Metal/telemetry sources and rejects all b930-only
markers in source and device binary.

## Current artifacts

- `libpwofficial_core.a`:
  `7b0eca5e7253d95e0b13680e855ba1df420b4ff5afa43c7e6120c22b03a1ce5e`
- Copied GPU extractor:
  `1e1d7660bfe487005eadd8ef27259b1e4e262bb007ccf973b1026743b460964d`
- Device `PWOfficialSfm`:
  `15f59af6e4a97fb3503d887e6becd7113561995f0d56dadd5b42da92378b0118`
- Universal simulator `PWOfficialSfm`:
  `f4c9476a174afb4501e9d39c4c9e15bef0519fae1e7d63dc276f960a469a22d1`

The device binary exports exactly 26 `pwofficial_*` symbols, has the fixed
install name `@rpath/PWOfficialSfm.framework/PWOfficialSfm`, is `TWOLEVEL` and
`NOUNDEFS`, and has no custom pipeline undefined symbols.

## Deployment constraint preserved for parity

The self-route core and dependencies were compiled with iOS 26.2 as the
minimum object deployment version. This copy intentionally preserves those
exact flags; rebuilding the objects for iOS 14 would no longer be the byte-
faithful baseline requested here. The final framework load command currently
records minOS 14.0, so the linker emits inherited newer-object warnings.
Runtime support below iOS 26.2 is **not validated or claimed** by this artifact.

## Dawn archive update — mixed subgroup-matrix config (2026-09-04)

- Old pinned Dawn archive SHA-256 (2026-06-21 build):
  `625cf65dded708ad1abd3dc92f3b47c3c90c384f508676b56303f9341d301b42`
- New pinned Dawn archive SHA-256:
  `a283007b6bb4f3a328434205e93a73be5738563393033c2dd81b29e3364ccb17`
- Change: **one object replaced** inside the pinned archive —
  `PhysicalDeviceMTL.o`, recompiled from the vendored Dawn source with the
  `[PW-MIXED-MMA 2026-09-03]` patch that advertises a third subgroup-matrix
  config `f16 in → f32 out, 8x8x8` (upstream Dawn hardcodes only f32→f32 and
  f16→f16 in `src/dawn/native/metal/PhysicalDeviceMTL.mm`, while Apple's
  hardware, MSL, the WGSL language (`core.def` overload `T: f16, TR: f32_f16`)
  and tint's MSL writer all support the mixed form — PocketWorld's shipped
  Metal matcher kernel uses it directly).
- Verification: archive member count 640 → 640; the replaced member is
  byte-identical to the freshly compiled object; spot-checked members
  (`ChainUtils_autogen.o`, `ObjectType_autogen.o`) byte-identical to the old
  archive; only `__.SYMDEF` differs (rebuilt by `ranlib`).
- Why not a full rebuild: the June archive was bundled in a build tree that no
  longer exists (`/private/tmp/aether_p2_gpu_timestamp_probe_20260730`); the
  current Xcode build regenerates `dawn_native_objects.a` but not the bundled
  `libwebgpu_dawn.a`. The surgical replacement keeps every other object at its
  pinned identity, which is stronger than a full rebuild for single-variable
  discipline. Old archive retained at
  `build-ios-device-dawn/.../Debug-iphoneos/libwebgpu_dawn.a.pinned-0621`.
- Cross-platform note: the patch is in the **Metal backend source shared by
  macOS and iOS** (one source change, two cross-compiles). The Vulkan backend
  (Android/HarmonyOS) enumerates configs dynamically from the driver
  (`vulkan/PhysicalDeviceVk.cpp: EnumerateSubgroupMatrixConfigs`) and needs no
  patch — `fp16×fp16→fp32` is a standard `VK_KHR_cooperative_matrix` config.
