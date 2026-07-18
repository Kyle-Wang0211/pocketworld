# Capture Glass Toggles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Add a compact, default-on two-toggle glass capsule to iOS capture, with reversible native photo-card/coverage visibility and a one-pass post-process that refracts the complete ARSCNView composition.

**Architecture:** Dart owns layout, visual controls, accessibility, state, and infrequent logical-rect reporting. The existing method channel forwards display-only state to a locked native store. ARSCNView consumes snapshots on its render thread, hides native nodes without deleting them, and applies one Metal SCNTechnique pass over a padded capsule viewport.

**Tech Stack:** Flutter 3.41.8 / Dart 3.11.5, UIKit Platform Views, Swift 5, ARKit/SceneKit, Metal, XCTest, Flutter widget tests.

---

## Frozen inputs and stop conditions

- Baseline commit: 1626543232eff47d1bd3664dad065165e472e1d7.
- Worktree: /Users/kaidongwang/.config/superpowers/worktrees/pocketworld/capture-glass-toggles-20260719.
- Acceptance device: Kyle’s iPhone, iPhone 14 Pro, iOS 26.5.2.
- Native-test environment deviation (verified 2026-07-19): the pinned
  `thermion_dart` 0.3.4+1 package links arm64-simulator builds against
  Filament objects built for iOS device, so RunnerTests cannot link on the
  simulator before any feature code is reached. Use generic-device
  `build-for-testing` as the deterministic RED/GREEN compile gate, then run
  the built tests and app on the acceptance iPhone. Pass
  `DEVELOPMENT_TEAM=26AH7V448L` because the existing RunnerTests target does
  not persist a development team.
- Preserve capture algorithms, camera/session lifecycle, SfM, and unrelated files.
- Stop SCNTechnique if the device spike omits camera, points, or cards from the same pass; clears outside pixels; or makes passthrough exceed the GPU gate.
- Never substitute ARFrame.capturedImage for the complete composition.

## File map

- Create lib/ui/capture/capture_overlay_controls.dart: controlled capsule and rect reporter.
- Create lib/ui/capture/capture_overlay_controller.dart: testable channel/state orchestration.
- Modify lib/ui/capture/ar_capture_page.dart: lifecycle and bottom HUD integration.
- Create test/capture_overlay_controls_test.dart and test/capture_overlay_controller_test.dart.
- Create ios/Runner/CaptureVisualStateStore.swift: locked native snapshot store.
- Create ios/Runner/CaptureGlassTechnique.swift and ios/Runner/CaptureGlass.metal.
- Modify ios/Runner/AetherARKitPlugin.swift, ios/RunnerTests/RunnerTests.swift, and ios/Runner.xcodeproj/project.pbxproj.
- Create ios/Runner/CaptureGlass-LICENSE.txt with the adapted upstream MIT notice.

### Task 1: Controlled Dart capsule and layout reporting

**Files:**
- Create: lib/ui/capture/capture_overlay_controls.dart
- Create: test/capture_overlay_controls_test.dart

- [ ] **Step 1: Write failing widget tests**

Create a Material harness and the wished-for public API:

~~~dart
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/capture/capture_overlay_controls.dart';

Widget harness(Widget child) => MaterialApp(
  home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: child)),
);

void main() {
  testWidgets('capsule is 176 by 52 with two default-on semantics', (tester) async {
    await tester.pumpWidget(harness(CaptureOverlayControls(
      photoCardsVisible: true,
      coveragePointsVisible: true,
      onPhotoCardsChanged: (_) {},
      onCoveragePointsChanged: (_) {},
    )));
    expect(tester.getSize(find.byKey(CaptureOverlayControls.panelKey)),
        const Size(176, 52));
    final photo =
        tester.getSemantics(find.byKey(CaptureOverlayControls.photoKey));
    final points =
        tester.getSemantics(find.byKey(CaptureOverlayControls.pointsKey));
    expect(photo.label, '显示照片卡片');
    expect(photo.hasFlag(SemanticsFlag.isToggled), isTrue);
    expect(points.label, '显示覆盖点');
    expect(points.hasFlag(SemanticsFlag.isToggled), isTrue);
  });

  testWidgets('photo and coverage controls toggle independently', (tester) async {
    bool photo = true;
    bool points = true;
    await tester.pumpWidget(harness(StatefulBuilder(
      builder: (context, setState) => CaptureOverlayControls(
        photoCardsVisible: photo,
        coveragePointsVisible: points,
        onPhotoCardsChanged: (v) => setState(() => photo = v),
        onCoveragePointsChanged: (v) => setState(() => points = v),
      ),
    )));
    await tester.tap(find.byKey(CaptureOverlayControls.photoKey));
    await tester.pump();
    expect(photo, isFalse);
    expect(points, isTrue);
    await tester.tap(find.byKey(CaptureOverlayControls.pointsKey));
    await tester.pump();
    expect(photo, isFalse);
    expect(points, isFalse);
  });

  testWidgets('each half has at least a 44 point target', (tester) async {
    await tester.pumpWidget(harness(CaptureOverlayControls(
      photoCardsVisible: true,
      coveragePointsVisible: true,
      onPhotoCardsChanged: (_) {},
      onCoveragePointsChanged: (_) {},
    )));
    for (final key in [
      CaptureOverlayControls.photoKey,
      CaptureOverlayControls.pointsKey,
    ]) {
      final size = tester.getSize(find.byKey(key));
      expect(size.width, greaterThanOrEqualTo(44));
      expect(size.height, greaterThanOrEqualTo(44));
    }
  });

  testWidgets('rect reporter suppresses unchanged layout', (tester) async {
    final rects = <Rect>[];
    await tester.pumpWidget(harness(CaptureGlassRectReporter(
      onRectChanged: rects.add,
      child: const SizedBox(width: 176, height: 52),
    )));
    await tester.pump();
    expect(rects, hasLength(1));
    await tester.pump();
    expect(rects, hasLength(1));
  });
}
~~~

- [ ] **Step 2: Verify RED**

Run:

~~~sh
flutter test test/capture_overlay_controls_test.dart
~~~

Expected: compilation fails because the file/classes do not exist.

- [ ] **Step 3: Implement the minimum widget**

Use these constants and stable keys:

~~~dart
const captureGlassTint = Color(0x08FFFFFF);
const captureGlassActive = Color(0xFFFFC53D);
const captureGlassInactive = Color(0x99FFFFFF);

class CaptureOverlayControls extends StatelessWidget {
  static const panelKey = ValueKey('capture_glass_panel');
  static const photoKey = ValueKey('capture_photo_cards_toggle');
  static const pointsKey = ValueKey('capture_coverage_points_toggle');
}
~~~

The panel is exactly 176×52, radius 20, with 0x08FFFFFF tint, a 1 px
translucent white border, restrained shadow, and centered divider. Each 88×52
half is an opaque hit target wrapped by Semantics(button: true, toggled: value).
Use a 27 px outlined photo and a custom 3×3 grid of nine 5 px circles. Do not
add BackdropFilter, saveLayer, animated shader, or synthetic AR dots.

CaptureGlassRectReporter is a StatefulWidget that schedules post-frame
measurement, uses localToGlobal(Offset.zero) plus size, and suppresses an
unchanged Rect.

- [ ] **Step 4: Verify GREEN and commit**

~~~sh
dart format lib/ui/capture/capture_overlay_controls.dart \
  test/capture_overlay_controls_test.dart
flutter test test/capture_overlay_controls_test.dart
git add lib/ui/capture/capture_overlay_controls.dart \
  test/capture_overlay_controls_test.dart
git commit -m "feat(capture): add glass visibility controls"
~~~

### Task 2: Testable Dart channel/state controller

**Files:**
- Create: lib/ui/capture/capture_overlay_controller.dart
- Create: test/capture_overlay_controller_test.dart

- [ ] **Step 1: Write failing tests**

~~~dart
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/capture/capture_overlay_controller.dart';

void main() {
  test('defaults on and sends exact photo payload', () async {
    final calls = <NativeOverlayCall>[];
    final controller = CaptureOverlayController(
      invokeNative: (method, args) async {
        calls.add(NativeOverlayCall(method, args));
      },
      repushCoverage: () async {},
    );
    expect(controller.photoCardsVisible, isTrue);
    expect(controller.coveragePointsVisible, isTrue);
    await controller.setPhotoCardsVisible(false);
    expect(calls.single.method, 'setPhotoCardsVisible');
    expect(calls.single.arguments, {'visible': false});
  });

  test('coverage enable precedes latest-cloud repush', () async {
    final order = <String>[];
    final controller = CaptureOverlayController(
      invokeNative: (method, args) async => order.add(method),
      repushCoverage: () async => order.add('repushCoverage'),
    );
    await controller.setCoveragePointsVisible(false);
    order.clear();
    await controller.setCoveragePointsVisible(true);
    expect(order, ['setFeaturePointsVisible', 'repushCoverage']);
  });

  test('identical glass rect is sent once', () async {
    final calls = <NativeOverlayCall>[];
    final controller = CaptureOverlayController(
      invokeNative: (method, args) async {
        calls.add(NativeOverlayCall(method, args));
      },
      repushCoverage: () async {},
    );
    const rect = Rect.fromLTWH(100, 600, 176, 52);
    await controller.reportGlassRect(rect);
    await controller.reportGlassRect(rect);
    expect(calls.where((c) => c.method == 'setCaptureGlassRect'), hasLength(1));
    expect(calls.where((c) => c.method == 'setCaptureGlassEnabled'), hasLength(1));
  });

  test('display errors never escape', () async {
    final controller = CaptureOverlayController(
      invokeNative: (_, __) async => throw StateError('channel unavailable'),
      repushCoverage: () async => throw StateError('repush unavailable'),
    );
    await expectLater(controller.setCoveragePointsVisible(false), completes);
    await expectLater(controller.setPhotoCardsVisible(false), completes);
    await expectLater(controller.reportGlassRect(
      const Rect.fromLTWH(0, 0, 176, 52)), completes);
  });
}
~~~

- [ ] **Step 2: Verify RED**

~~~sh
flutter test test/capture_overlay_controller_test.dart
~~~

Expected: compilation fails because the controller API does not exist.

- [ ] **Step 3: Implement the minimum controller**

CaptureOverlayController extends ChangeNotifier, defaults both fields to true,
updates state optimistically, and catches display-channel errors. Required
calls:

~~~text
setPhotoCardsVisible    {visible: bool}
setFeaturePointsVisible {visible: bool}
setCaptureGlassRect     {x: double, y: double, width: double, height: double}
setCaptureGlassEnabled  {enabled: bool}
~~~

Coverage enable awaits native visibility then repushes. reportGlassRect rejects
non-finite/empty values, deduplicates, sends rect, then enables glass. detach
disables glass. syncNativeVisibility sends both current values and repushes only
when coverage is on.

- [ ] **Step 4: Verify GREEN and commit**

~~~sh
dart format lib/ui/capture/capture_overlay_controller.dart \
  test/capture_overlay_controller_test.dart
flutter test test/capture_overlay_controller_test.dart
git add lib/ui/capture/capture_overlay_controller.dart \
  test/capture_overlay_controller_test.dart
git commit -m "feat(capture): coordinate overlay visibility"
~~~

### Task 3: Integrate ARCapturePage

**Files:**
- Modify: lib/ui/capture/ar_capture_page.dart
- Test: test/capture_overlay_controller_test.dart

- [ ] **Step 1: Add a failing fresh-session sync test**

~~~dart
await controller.setPhotoCardsVisible(false);
await controller.setCoveragePointsVisible(false);
calls.clear();
await controller.syncNativeVisibility();
expect(calls.map((c) => c.method), [
  'setPhotoCardsVisible',
  'setFeaturePointsVisible',
]);
~~~

- [ ] **Step 2: Verify RED, then implement lifecycle**

~~~sh
flutter test test/capture_overlay_controller_test.dart
~~~

In _ARCapturePageState create the controller in initState with injected
_arKitChannel.invokeMethod and _pushCoverageCloud. Add/remove one listener that
calls setState only when mounted. After fresh capture clears/reset coverage,
replace the hard-coded feature-points-on call with syncNativeVisibility. In
dispose call detach, remove listener, and dispose the controller without
changing existing capture teardown.

- [ ] **Step 3: Compose one transparent bottom HUD**

Under the existing _session != null && _sfmPhase == null condition, retain one
Positioned + SafeArea and use:

~~~dart
Column(
  mainAxisSize: MainAxisSize.min,
  children: [
    CaptureGlassRectReporter(
      onRectChanged: (rect) =>
          unawaited(_captureOverlay.reportGlassRect(rect)),
      child: CaptureOverlayControls(
        photoCardsVisible: _captureOverlay.photoCardsVisible,
        coveragePointsVisible: _captureOverlay.coveragePointsVisible,
        onPhotoCardsChanged: (value) =>
            unawaited(_captureOverlay.setPhotoCardsVisible(value)),
        onCoveragePointsChanged: (value) =>
            unawaited(_captureOverlay.setCoveragePointsVisible(value)),
      ),
    ),
    const SizedBox(height: 12),
    _ManualCaptureBar(
      targetPoints: _targetPoints,
      ready: _recording,
      capturing: _capturing,
      finishing: _finalizingRecording,
      onShutter: _onShutterTap,
      onOpenAlbum: _openAlbum,
      onFinish: _finalizingRecording ? null : _onFinishTap,
    ),
  ],
)
~~~

No sheet may wrap the column. Preserve shutter, album, finish, safe area,
reconstruction, and preview behavior.

- [ ] **Step 4: Verify and commit**

~~~sh
dart format lib/ui/capture/ar_capture_page.dart
flutter analyze lib/ui/capture/ar_capture_page.dart \
  lib/ui/capture/capture_overlay_controls.dart \
  lib/ui/capture/capture_overlay_controller.dart
flutter test test/capture_overlay_controls_test.dart \
  test/capture_overlay_controller_test.dart
git add lib/ui/capture/ar_capture_page.dart \
  lib/ui/capture/capture_overlay_controller.dart \
  test/capture_overlay_controller_test.dart
git commit -m "feat(capture): wire visibility toggles"
~~~

### Task 4: Native state and reversible photo-card visibility

**Files:**
- Create: ios/Runner/CaptureVisualStateStore.swift
- Modify: ios/Runner/AetherARKitPlugin.swift
- Modify: ios/RunnerTests/RunnerTests.swift
- Modify: ios/Runner.xcodeproj/project.pbxproj

- [ ] **Step 1: Write failing native state tests**

~~~swift
func testCaptureVisualDefaultsAndUpdates() {
  let store = CaptureVisualStateStore()
  let initial = store.snapshot()
  XCTAssertTrue(initial.photoCardsVisible)
  XCTAssertFalse(initial.glassEnabled)
  XCTAssertNil(initial.glassRect)
  store.setPhotoCardsVisible(false)
  store.setGlassEnabled(true)
  let updated = store.snapshot()
  XCTAssertFalse(updated.photoCardsVisible)
  XCTAssertTrue(updated.glassEnabled)
  XCTAssertGreaterThan(updated.generation, initial.generation)
}

func testCaptureVisualRectRejectsInvalidGeometry() {
  let store = CaptureVisualStateStore()
  store.setGlassRect(CGRect(x: .nan, y: 10, width: 176, height: 52))
  XCTAssertNil(store.snapshot().glassRect)
  let valid = CGRect(x: 10, y: 20, width: 176, height: 52)
  store.setGlassRect(valid)
  XCTAssertEqual(store.snapshot().glassRect, valid)
}
~~~

- [ ] **Step 2: Restore Pods and verify RED**

~~~sh
(cd ios && COCOAPODS_DISABLE_STATS=true pod install --deployment)
xcodebuild build-for-testing -workspace ios/Runner.xcworkspace -scheme Runner \
  -destination 'generic/platform=iOS' \
  -only-testing:RunnerTests/RunnerTests \
  DEVELOPMENT_TEAM=26AH7V448L CODE_SIGNING_ALLOWED=NO
~~~

Expected: compile failure because CaptureVisualStateStore does not exist.

- [ ] **Step 3: Implement and wire the locked store**

CaptureVisualSnapshot contains generation, photoCardsVisible, glassEnabled, and
glassRect. CaptureVisualStateStore uses NSLock, default cards on/glass off/no
rect, increments generation only on actual changes, rejects non-finite or empty
rects, and returns atomic copies.

Add exact channel cases for setPhotoCardsVisible, setCaptureGlassRect, and
setCaptureGlassEnabled; malformed payloads return bad_args. The preview tracks
last generation. On change, it sets every photoCardNodes container isHidden
without deleting anchors/specs/materials. New card containers inherit current
visibility before their first rendered frame. Hidden cards skip scaling work.

Add the Swift file to Runner Sources, not Resources.

- [ ] **Step 4: Verify and commit**

~~~sh
xcodebuild build-for-testing -workspace ios/Runner.xcworkspace -scheme Runner \
  -destination 'generic/platform=iOS' \
  -only-testing:RunnerTests/RunnerTests \
  DEVELOPMENT_TEAM=26AH7V448L CODE_SIGNING_ALLOWED=NO
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Debug -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
git add ios/Runner/CaptureVisualStateStore.swift \
  ios/Runner/AetherARKitPlugin.swift ios/RunnerTests/RunnerTests.swift \
  ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat(ios): add reversible capture card visibility"
~~~

### Task 5: One-pass complete-composition refraction

**Files:**
- Create: ios/Runner/CaptureGlass.metal
- Create: ios/Runner/CaptureGlassTechnique.swift
- Create: ios/Runner/CaptureGlass-LICENSE.txt
- Modify: ios/Runner/AetherARKitPlugin.swift
- Modify: ios/RunnerTests/RunnerTests.swift
- Modify: ios/Runner.xcodeproj/project.pbxproj

- [ ] **Step 1: Write failing technique tests**

~~~swift
func testCaptureGlassLayoutSeparatesPointViewportAndPixelUniforms() {
  let layout = CaptureGlassLayout(
    viewBounds: CGRect(x: 0, y: 0, width: 393, height: 852),
    contentScale: 3,
    logicalRect: CGRect(x: 108.5, y: 680, width: 176, height: 52),
    guardPixels: 6
  )
  XCTAssertEqual(layout.glassRectPixels.width, 528, accuracy: 0.001)
  XCTAssertEqual(layout.glassRectPixels.height, 156, accuracy: 0.001)
  XCTAssertTrue(layout.viewportPoints.contains(
    CGRect(x: 108.5, y: 680, width: 176, height: 52)
  ))
  XCTAssertEqual(layout.viewportPoints.minX * 3,
                 floor(layout.viewportPoints.minX * 3), accuracy: 0.001)
  XCTAssertEqual(layout.viewportPoints.maxX * 3,
                 ceil(layout.viewportPoints.maxX * 3), accuracy: 0.001)
}

func testCaptureGlassTechniqueIsOnePassAndNeverClears() throws {
  let dict = CaptureGlassTechniqueBuilder.dictionary(
    viewportPoints: CGRect(x: 100, y: 633, width: 180, height: 56)
  )
  XCTAssertEqual(dict["sequence"] as? [String], ["captureGlass"])
  let passes = try XCTUnwrap(dict["passes"] as? [String: Any])
  let pass = try XCTUnwrap(passes["captureGlass"] as? [String: Any])
  XCTAssertEqual(pass["draw"] as? String, "DRAW_QUAD")
  XCTAssertEqual((pass["colorStates"] as? [String: Any])?["clear"] as? Bool,
                 false)
  XCTAssertEqual((pass["inputs"] as? [String: Any])?["sceneColor"] as? String,
                 "COLOR")
  XCTAssertEqual((pass["outputs"] as? [String: Any])?["color"] as? String,
                 "COLOR")
}
~~~

- [ ] **Step 2: Verify RED**

~~~sh
xcodebuild build-for-testing -workspace ios/Runner.xcworkspace -scheme Runner \
  -destination 'generic/platform=iOS' \
  -only-testing:RunnerTests/RunnerTests \
  DEVELOPMENT_TEAM=26AH7V448L CODE_SIGNING_ALLOWED=NO
~~~

Expected: compile failure because the layout/builder do not exist.

- [ ] **Step 3: Implement layout and technique**

CaptureGlassLayout intersects logical rect with view bounds, multiplies by
contentScale for its shader uniforms, and keeps a separate pass viewport in
local `ARSCNView` points. Expand the viewport by `6 / contentScale` points,
round its edges outward to physical-pixel boundaries, and clamp it to the view
bounds. The `SCNTechnique` viewport string uses these point values with a
top-left origin; never serialize physical pixels there.

CaptureGlassTechniqueBuilder creates exactly one DRAW_QUAD pass with:

~~~swift
"metalVertexShader": "captureGlassVertex"
"metalFragmentShader": "captureGlassFragment"
"inputs": [
  "sceneColor": "COLOR",
  "captureViewport": "captureViewport",
  "captureGlassRect": "captureGlassRect",
  "captureGlassOptics": "captureGlassOptics",
]
"outputs": ["color": "COLOR"]
"colorStates": ["clear": false]
"viewport": "x y width height"
~~~

Symbols are vec4. Set `captureViewport` to physical full-view width, height,
and their inverses; set `captureGlassRect` to physical full-view center and
half-size; set `captureGlassOptics` to radius, distortion, tint alpha, and
enabled. Use radius 20×scale, distortion 2×scale, tint 8/255, no dispersion.
Bind vec4 values as `SCNVector4` on the installed `arscnView.technique` copy,
not only on the pre-assignment object.

- [ ] **Step 4: Implement and compile the Metal shader**

Follow Apple's documented DRAW_QUAD Metal layout: `position [[attribute(0)]]`
and `texcoord0 [[attribute(1)]]`, a named custom-symbol struct at `[[buffer(0)]]`,
and `sceneColor [[texture(0)]]`. The vertex forwards the quad position and may
derive a local UV for diagnostics. The fragment derives full-frame UV from its
raster position and the inverse physical view size, evaluates a
rounded-rectangle SDF in physical pixels, applies a seam-safe analytic normal
displacement only inside, samples `sceneColor` exactly once, and adds only
0x08FFFFFF tint plus restrained edge light. Use half4 color, float coordinates,
a compile-time linear clamp-to-edge sampler, no RGB split/blur/mips/history/
second pass. Do not use SceneKit semantic constants for the quad attributes and
do not generate an unproven quad from `vertex_id`.

~~~sh
xcrun -sdk iphoneos metal -c ios/Runner/CaptureGlass.metal \
  -o /tmp/pocketworld-CaptureGlass.air
~~~

Expected: exit 0.

- [ ] **Step 5: Add Xcode sources, attribution, and preview application**

Add Swift and Metal as Runner Sources. Add the MIT notice as a Runner resource.
The preview owns one technique controller and rebuilds only when glass-related
state or view bounds/scale changes. Convert the Flutter global rect to local
`ARSCNView` points and install/remove the technique on the view-owning main
path. Disabled/invalid means `arscnView.technique = nil`. Technique creation is
failable; missing default-library functions or a nil dictionary must disable
the effect safely. Set `colorStates.clear` false. Set `rendersCameraGrain`
false before technique installation, while keeping a no-technique comparison
with identical settings for performance attribution. Do not assume the
symbolic COLOR read/write is zero-copy or that a partial viewport preserves
outside pixels; both remain physical-device stop conditions.

- [ ] **Step 6: Verify and commit**

~~~sh
xcodebuild build-for-testing -workspace ios/Runner.xcworkspace -scheme Runner \
  -destination 'generic/platform=iOS' \
  -only-testing:RunnerTests/RunnerTests \
  DEVELOPMENT_TEAM=26AH7V448L CODE_SIGNING_ALLOWED=NO
xcodebuild -workspace ios/Runner.xcworkspace -scheme Runner \
  -configuration Profile -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
# Inspect Runner.app/default.metallib and require both exact function names.
xcrun metal-nm -j <profile Runner.app>/default.metallib | \
  rg 'captureGlass(Vertex|Fragment)'
git add ios/Runner/CaptureGlass.metal ios/Runner/CaptureGlassTechnique.swift \
  ios/Runner/CaptureGlass-LICENSE.txt ios/Runner/AetherARKitPlugin.swift \
  ios/RunnerTests/RunnerTests.swift ios/Runner.xcodeproj/project.pbxproj
git commit -m "feat(ios): refract complete AR composition"
~~~

### Task 6: Integrated verification and iPhone deployment

**Files:**
- Verify all modified files; record evidence without inventing benchmark data.

- [ ] **Step 1: Run all deterministic checks**

~~~sh
dart format --output=none --set-exit-if-changed \
  lib/ui/capture/ar_capture_page.dart \
  lib/ui/capture/capture_overlay_controls.dart \
  lib/ui/capture/capture_overlay_controller.dart \
  test/capture_overlay_controls_test.dart \
  test/capture_overlay_controller_test.dart
flutter analyze
flutter test
git diff --check
~~~

Expected: all exit 0 and full tests report zero failures.

- [ ] **Step 2: Deploy Debug with the phone unlocked**

Use flutter run, not flutter install, because install uninstalls first:

~~~sh
flutter --suppress-analytics -d "Kyle’s iPhone" run \
  --debug --no-pub --device-timeout 60
~~~

Expected: signed build installs and launches.

- [ ] **Step 3: Execute the functional gate**

Capture at least two photos so cards and colored cloud exist. Verify transparent
surroundings, pure-yellow icons, no synthetic green point, independent off/on
toggles, immediate point-cloud restoration, cards created while hidden restore,
all camera/point/card pixels bend in the same glass, outside pixels stay
unchanged, and page re-entry resets default-on. Stop if any native layer is
missing from the refraction.

- [ ] **Step 4: Run Profile performance gate**

~~~sh
flutter --suppress-analytics -d "Kyle’s iPhone" run \
  --profile --no-pub --device-timeout 60
~~~

Compare interleaved no-technique, passthrough, and one-sample runs with the same
scene, counts, and thermal start. Accept only when p95 GPU delta is ≤1.0 ms, no
extra 30 Hz miss appears, outside pixels remain unchanged, and GPU capture shows
no disqualifying hidden full-screen transfer. If instrumentation is unavailable,
report functional status separately and leave performance unresolved.

- [ ] **Step 5: Fresh independent review**

Give a read-only reviewer the frozen spec, integrated diff, tests, builds,
device observations, and trace identities. Resolve every issue and rerun
affected commands before acceptance.
