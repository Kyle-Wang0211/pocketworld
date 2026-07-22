# Dual Capture Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a “自研 / 官方” capture chooser and ship two physically independent, initially behavior-identical capture/reconstruction stacks whose results appear in one My Works list with route labels.

**Architecture:** Keep the existing self-developed stack untouched. Mechanically copy the active Flutter capture directories, Swift ARKit plugin, Dart FFI binding, GPU/native adapter and native runtime into an official-prefixed stack with unique channels, symbols, sessions, storage and artifacts. The only shared application code is the chooser, design tokens, localization and the common `ScanRecord` gallery model; platform/third-party dependencies remain shared.

**Tech Stack:** Flutter/Dart, Swift/ARKit, Dart FFI, Objective-C++, C/C++17, Metal, CocoaPods/Xcode, Flutter widget/unit tests, shell symbol checks.

---

## Frozen inputs and non-negotiable constraints

- Product repository: `/Users/kaidongwang/Developer/pocketworld`
- Starting revision: `35d7e17` on `ar-capture-rs`
- Preserve pre-existing user changes:
  - `vendor/aether_ffi/include/aether_sfm_c.h`
  - `vendor/aether_ffi/libs/ios-arm64/sfm/libglomap_core.a.bak_*`
- Design authority: `docs/superpowers/specs/2026-07-22-dual-capture-pipeline-design.md`
- Do not change reconstruction behavior in this plan.
- Do not make the official route call, import or forward to the self route.
- Only one AR session may own the iPhone camera at a time.

## File map

### Shared selector and record identity

- Create: `lib/capture_pipeline_kind.dart`
- Create: `lib/ui/capture_pipeline_picker.dart`
- Modify: `lib/ui/me_root_page.dart`
- Modify: `lib/ui/scan_record.dart`
- Modify: `lib/me/scan_record_store.dart`
- Modify: `lib/ui/scan_record_cell.dart`
- Modify: `lib/ui/me_page.dart`
- Modify generated/localization inputs and outputs under `lib/l10n/`.

### Official Flutter copy

- Copy directory `lib/capture/` to `lib/official_capture/`.
- Copy directory `lib/dome/` to `lib/official_dome/`.
- Copy directory `lib/ui/capture/` to `lib/ui/official_capture/`.
- Copy `lib/aether_sfm_ffi.dart` to `lib/official_aether_sfm_ffi.dart`.
- Rename the public entry types to `OfficialARCapturePage`, `OfficialCaptureSession`, `OfficialPlatformARPoseProvider`, `OfficialSfmLiveRecon` and `OfficialAetherSfm`.
- Rewrite copied imports so official code references the official copies, never `lib/capture`, `lib/dome`, `lib/ui/capture` or `lib/aether_sfm_ffi.dart`.

### Official iOS copy

- Create: `ios/Runner/OfficialARKitPlugin.swift` as a physical copy of `AetherARKitPlugin.swift`.
- Modify: `ios/Runner/AppDelegate.swift`.
- Modify: `ios/Runner.xcodeproj/project.pbxproj` to compile the new Swift file.
- Unique identifiers:
  - `pocketworld_official_arkit`
  - `pocketworld_official_arkit/pose_stream`
  - `pocketworld_official_arkit_preview`
  - `OfficialARKitPlugin`, `OfficialPoseStreamHandler`, `OfficialARSessionForwarder`, `OfficialARKitPreviewFactory`, `OfficialARKitPreviewView`, `OfficialCaptureBrightnessGovernor`, `OfficialNativeTelemetry`.
- Replace copied environment names `AETHER_*` with `PWOFFICIAL_*` so future official changes cannot mutate the self stack’s process-global configuration.
- Replace copied native output names `ar_video_formats.json` and `telemetry_native.jsonl` with `official_ar_video_formats.json` and `telemetry_official_native.jsonl`.

### Official native copy

- Create: `vendor/official_sfm/include/official_sfm_c.h`.
- Create: `vendor/official_sfm/src/pwofficial_export_shim.c`.
- Create: `vendor/official_sfm/src/pwofficial_gpu_match.mm`.
- Create: `vendor/official_sfm/official_sfm.podspec`.
- Create official native source/build target in `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/official_pipeline/` from the current production SfM sources.
- Export only `pwofficial_*` from an embedded dynamic framework; keep the copied COLMAP/Aether internals hidden in that framework so their same initial C++ names do not collide with the self stack statically linked into Runner.
- Add the built framework/XCFramework under `vendor/official_sfm/libs/` and link/embed it through the official podspec.

### Tests and gates

- Create: `test/capture_pipeline_kind_test.dart`
- Create: `test/capture_pipeline_picker_test.dart`
- Create: `test/scan_record_pipeline_kind_test.dart`
- Create: `test/dual_capture_source_boundary_test.dart`
- Create: `tool/check_dual_capture_native_symbols.sh`

---

### Task 1: Add immutable pipeline identity to records

**Files:**
- Create: `lib/capture_pipeline_kind.dart`
- Modify: `lib/ui/scan_record.dart`
- Modify: `lib/me/scan_record_store.dart`
- Test: `test/capture_pipeline_kind_test.dart`
- Test: `test/scan_record_pipeline_kind_test.dart`

- [ ] **Step 1: Write failing enum/wire tests**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/capture_pipeline_kind.dart';

void main() {
  test('legacy records default to self while official is explicit', () {
    expect(CapturePipelineKindWire.fromWireName(null), CapturePipelineKind.self);
    expect(CapturePipelineKindWire.fromWireName('self'), CapturePipelineKind.self);
    expect(CapturePipelineKindWire.fromWireName('official'), CapturePipelineKind.official);
    expect(CapturePipelineKind.official.wireName, 'official');
  });
}
```

- [ ] **Step 2: Run the focused test and confirm RED**

Run: `flutter test test/capture_pipeline_kind_test.dart`

Expected: compilation failure because `capture_pipeline_kind.dart` does not exist.

- [ ] **Step 3: Implement the common identity**

```dart
enum CapturePipelineKind { self, official }

extension CapturePipelineKindWire on CapturePipelineKind {
  String get wireName => switch (this) {
    CapturePipelineKind.self => 'self',
    CapturePipelineKind.official => 'official',
  };

  String get zhLabel => switch (this) {
    CapturePipelineKind.self => '自研',
    CapturePipelineKind.official => '官方',
  };

  static CapturePipelineKind fromWireName(String? value) =>
      value == 'official' ? CapturePipelineKind.official : CapturePipelineKind.self;
}
```

Add a final `pipelineKind` field to `ScanRecord`, default it to `CapturePipelineKind.self`, preserve it in `copyWith`, write `pipeline_kind` for every new record, and default missing/unknown JSON values to `self` when reading legacy records.

- [ ] **Step 4: Add store round-trip coverage**

Test two records serialized through the store’s public test seam: an explicit official record returns official; a JSON fixture without `pipeline_kind` returns self.

- [ ] **Step 5: Run tests and commit**

Run: `flutter test test/capture_pipeline_kind_test.dart test/scan_record_pipeline_kind_test.dart`

Expected: PASS.

Commit only Task 1 files with: `git commit -m 'feat(capture): persist self and official pipeline identity'`.

---

### Task 2: Add the chooser and distinct Flutter page routes

**Files:**
- Create: `lib/ui/capture_pipeline_picker.dart`
- Modify: `lib/ui/me_root_page.dart`
- Create initially by copy: `lib/ui/official_capture/ar_capture_page.dart`
- Test: `test/capture_pipeline_picker_test.dart`

- [ ] **Step 1: Write a failing widget test**

The test pumps `MeRootPage` with injectable page builders, taps the existing `+`, asserts both `自研` and `官方` are visible, taps each in separate test cases, and verifies distinct route keys `self-capture-page` and `official-capture-page`.

- [ ] **Step 2: Run the focused test and confirm RED**

Run: `flutter test test/capture_pipeline_picker_test.dart`

Expected: FAIL because the FAB still opens `ARCapturePage` directly.

- [ ] **Step 3: Implement the chooser**

Create `CapturePipelinePicker.show(context)` returning `Future<CapturePipelineKind?>`. Use one community-matched `LiquidGlassLayer` with exactly these existing settings:

```dart
const LiquidGlassSettings(
  thickness: 20,
  blur: 4,
  glassColor: Color(0x08FFFFFF),
  refractiveIndex: 1.20,
  lightIntensity: 1.0,
  saturation: 1.0,
)
```

Render two equal tap targets with titles `自研` and `官方`; subtitles are `当前产品基线` and `官方对齐路线`. Dismissing returns null.

- [ ] **Step 4: Route to different concrete page classes**

Update `_openCapture()` to await the picker and push either the existing `ARCapturePage` or copied `OfficialARCapturePage`. Do not use a common page constructor with a mode argument.

- [ ] **Step 5: Run test and commit**

Run: `flutter test test/capture_pipeline_picker_test.dart`

Expected: PASS with two distinct page types.

Commit: `git commit -m 'feat(ui): choose self or official capture stack'`.

---

### Task 3: Mechanically copy the entire Flutter capture frontend and Dart orchestration

**Files:**
- Create all files under `lib/official_capture/` from `lib/capture/`.
- Create all files under `lib/official_dome/` from `lib/dome/`.
- Create all files under `lib/ui/official_capture/` from `lib/ui/capture/`.
- Create: `lib/official_aether_sfm_ffi.dart` from `lib/aether_sfm_ffi.dart`.
- Test: `test/dual_capture_source_boundary_test.dart`.

- [ ] **Step 1: Write the failing boundary test**

The test recursively scans official Dart files and fails if an import resolves to any of:

```text
lib/capture/
lib/dome/
lib/ui/capture/
lib/aether_sfm_ffi.dart
```

It also asserts the official tree contains the same relative file manifest as all three source directories.

- [ ] **Step 2: Run the boundary test and confirm RED**

Run: `flutter test test/dual_capture_source_boundary_test.dart`

Expected: FAIL because the official directories are missing/incomplete.

- [ ] **Step 3: Perform the literal directory copies**

Use mechanical directory copy operations, then rewrite only prefixes/imports/public entry names:

```text
lib/capture              -> lib/official_capture
lib/dome                 -> lib/official_dome
lib/ui/capture           -> lib/ui/official_capture
lib/aether_sfm_ffi.dart  -> lib/official_aether_sfm_ffi.dart
```

Required public renames:

```text
ARCapturePage             -> OfficialARCapturePage
CaptureSession            -> OfficialCaptureSession
PlatformARPoseProvider    -> OfficialPlatformARPoseProvider
SfmLiveRecon              -> OfficialSfmLiveRecon
AetherSfm                 -> OfficialAetherSfm
```

The copied provider uses only `pocketworld_official_arkit` and `pocketworld_official_arkit/pose_stream`; copied preview widgets use only `pocketworld_official_arkit_preview`.

- [ ] **Step 4: Separate the official artifact namespace**

In copied code use:

```text
Documents/captures_official/<capture-id>/
official_sfm_live.db
official_sfm_live.db.spool.<seq>.gray
official_sfm_sparse.ply
official_sfm_sparse_meta.json
```

Write `pipeline_kind: official` into official capture/photo manifests and every official `ScanRecord`. Keep all existing self names unchanged.

- [ ] **Step 5: Run copied pure-Dart tests against both trees**

Duplicate current capture pure-function tests so they import the official copies: queue, parallax, final-quality filter, pose drift, quality and target-point curation.

Run: `flutter test test/dual_capture_source_boundary_test.dart test/capture_pipeline_kind_test.dart test/sfm_final_quality_filter_test.dart`

Expected: PASS.

- [ ] **Step 6: Commit**

Commit: `git commit -m 'feat(capture): fork complete official Flutter capture stack'`.

---

### Task 4: Copy the Swift ARKit plugin and channels

**Files:**
- Create: `ios/Runner/OfficialARKitPlugin.swift`
- Modify: `ios/Runner/AppDelegate.swift`
- Modify: `ios/Runner.xcodeproj/project.pbxproj`
- Test: `test/dual_capture_source_boundary_test.dart`

- [ ] **Step 1: Extend the failing boundary test**

Assert the two Swift files contain distinct MethodChannel, EventChannel and platform-view IDs. Assert the official file contains no string literal equal to a self channel/view identifier, no self plugin type reference, no `AETHER_` environment key, and no self native-output filename.

- [ ] **Step 2: Confirm RED**

Run: `flutter test test/dual_capture_source_boundary_test.dart`

Expected: FAIL because `OfficialARKitPlugin.swift` is absent.

- [ ] **Step 3: Copy and mechanically rename the full plugin**

Copy all 3,500 lines, including preview factory/view, stream handler, session delegate, brightness governor and native telemetry. Rename every copied type listed in the file map. Replace channel IDs, replace every copied environment key prefix with `PWOFFICIAL_`, and write native diagnostics only to `official_ar_video_formats.json` and `telemetry_official_native.jsonl`.

- [ ] **Step 4: Register both plugins**

In `AppDelegate`, register `AetherARKitPlugin` and `OfficialARKitPlugin` with distinct registrar names. Neither plugin starts a session during registration; each starts only after its own page invokes `startSession`.

- [ ] **Step 5: Verify source and iOS compilation**

Run:

```sh
flutter test test/dual_capture_source_boundary_test.dart
flutter build ios --profile --no-codesign
```

Expected: boundary test PASS; Xcode compiles both Swift files without duplicate type/channel/platform-view errors.

- [ ] **Step 6: Commit**

Commit: `git commit -m 'feat(ios): fork independent official ARKit plugin'`.

---

### Task 5: Build and link an independent official native SfM runtime

**Files:**
- Create official source target under `/Users/kaidongwang/Developer/Aether3D-cross/aether_cpp/official_pipeline/`.
- Create/update the four `vendor/official_sfm/` files in the product repository.
- Modify: `ios/Podfile` only if the local pod cannot be declared through the existing pod stanza.
- Modify: `lib/official_aether_sfm_ffi.dart`.
- Create: `tool/check_dual_capture_native_symbols.sh`.

- [ ] **Step 1: Write the symbol gate before building**

The script checks the final Runner binary or linked framework with `nm -gU`/`dyld_info -exports` and requires every streaming entry point under both prefixes:

```text
pwsfm_options_default       pwofficial_options_default
pwsfm_create                pwofficial_create
pwsfm_add_frame             pwofficial_add_frame
pwsfm_remove_frame          pwofficial_remove_frame
pwsfm_finalize_async        pwofficial_finalize_async
pwsfm_finalize_status       pwofficial_finalize_status
pwsfm_get_poses             pwofficial_get_poses
pwsfm_get_points_tracked    pwofficial_get_points_tracked
pwsfm_free                  pwofficial_free
```

It must also fail if `official_aether_sfm_ffi.dart` contains a lookup string beginning `pwsfm_`.

- [ ] **Step 2: Run the gate and confirm RED**

Expected: FAIL because no `pwofficial_*` runtime exists.

- [ ] **Step 3: Create the independent framework target**

Copy the production adapter/extractor/matcher sources into `official_pipeline`; change copied environment reads to `PWOFFICIAL_*`. Compile the same initial COLMAP/Aether source set into an embedded dynamic framework with hidden-by-default visibility and an exported-symbols list containing only `pwofficial_*`. This is required because force-loading two same-named static COLMAP archives into Runner would produce duplicate symbols.

- [ ] **Step 4: Add the official visibility shim and pod**

`pwofficial_export_shim.c` is a full copy of `pwsfm_export_shim.c` whose exported names are `pwofficial_*` and whose calls bind to the official framework’s private underlying implementation. `pwofficial_gpu_match.mm` is a full copy with framework-local Metal state. The official pod embeds/signs the framework and does not alter the existing self pod/link flags.

- [ ] **Step 5: Point Dart only at official symbols**

The copied binding resolves every method through `pwofficial_*`. Missing official symbols throw an official-specific initialization error; there is no fallback to `pwsfm_*`.

- [ ] **Step 6: Verify native parity and isolation**

Run:

```sh
flutter build ios --profile --no-codesign
tool/check_dual_capture_native_symbols.sh build/ios/iphoneos/Runner.app/Runner
```

Expected: build PASS; both complete prefixes present; neither binding references the other prefix.

Record framework/archive SHA-256 and normalized source-copy diff in `vendor/official_sfm/BUILD_PROVENANCE.md`.

- [ ] **Step 7: Commit each repository independently**

Commit the Aether official target without touching unrelated dirty Aether files, then commit product vendor/build integration with: `git commit -m 'feat(native): ship independent official SfM runtime'`.

---

### Task 6: Route persistence, recovery and My Works labels

**Files:**
- Modify: `lib/me/scan_record_store.dart`
- Modify: `lib/me/draft_card_action.dart`
- Modify: `lib/ui/me_page.dart`
- Modify: `lib/ui/scan_record_cell.dart`
- Modify copied official resume files under `lib/official_capture/` and `lib/ui/official_capture/`.
- Test: `test/scan_record_pipeline_kind_test.dart`
- Test: `test/capture_pipeline_picker_test.dart`

- [ ] **Step 1: Write failing recovery and label tests**

Cover:

1. legacy record without a field displays `自研`;
2. official record displays `官方`;
3. orphan recovery scans both `captures/` and `captures_official/` and assigns the correct kind;
4. self resume looks for `sfm_live.db` and opens the self resume page;
5. official resume looks for `official_sfm_live.db` and opens the official resume page;
6. neither route falls back to the other route’s DB.

- [ ] **Step 2: Confirm RED**

Run: `flutter test test/scan_record_pipeline_kind_test.dart test/capture_pipeline_picker_test.dart`

Expected: FAIL for missing label and official recovery behavior.

- [ ] **Step 3: Implement fail-closed routing**

Add route-specific artifact-name helpers keyed by `CapturePipelineKind`. Use them in card actions and recovery. Unknown/missing remains self only for old records; an explicit official record with missing official DB must not probe the self DB.

- [ ] **Step 4: Render the route badge**

Place a small `自研`/`官方` pill on the thumbnail, separate from the completed badge. Keep both record types in the existing single sorted grid.

- [ ] **Step 5: Run tests and commit**

Run the two focused tests plus `flutter test`.

Expected: all existing and new tests PASS.

Commit: `git commit -m 'feat(me): label and resume independent capture routes'`.

---

### Task 7: Full verification and device smoke test

**Files:**
- No production changes unless verification reveals a defect.
- Update: `vendor/official_sfm/BUILD_PROVENANCE.md` with final hashes.

- [ ] **Step 1: Static and unit verification**

Run:

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

Expected: all exit 0.

- [ ] **Step 2: iOS Profile build and symbol gate**

Run:

```sh
flutter build ios --profile --no-codesign
tool/check_dual_capture_native_symbols.sh build/ios/iphoneos/Runner.app/Runner
```

Expected: build and symbol gate PASS.

- [ ] **Step 3: Install on the paired iPhone**

Install the Profile app on the paired iPhone and launch it. Do not delete app data.

- [ ] **Step 4: Smoke-test the self route**

Tap `+ → 自研`; confirm the self page badge/channel/session, take one photo, exit normally and verify a My Works card labeled `自研` with self paths.

- [ ] **Step 5: Smoke-test the official route**

Tap `+ → 官方`; confirm the official page badge/channel/session, take one photo, exit normally and verify a My Works card labeled `官方` with official paths.

- [ ] **Step 6: Prove camera/session isolation**

Device logs must show only the selected plugin starts in each run. Switching routes after closing the prior page must not report camera ownership, duplicate platform-view registration or ARSession contention errors.

- [ ] **Step 7: Final independent review**

Give a fresh read-only reviewer the design, complete diff, test outputs, symbol output and device logs. Acceptance requires no official-to-self import/call/fallback and no P0/P1 finding.

- [ ] **Step 8: Final commit**

Commit only any verification/provenance corrections with: `git commit -m 'test(capture): verify independent dual pipelines on device'`.
