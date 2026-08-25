# Realtime Solving Orb Splash Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Flutter cold-start overlay with one 128 pt realtime `solving` particle orb, centered on a pure-black screen, using white particles at speed `0.8`, then update the production iPhone without losing or replacing its app data container.

**Architecture:** Keep `AetherSplashOverlay` as the overlay/fade lifecycle owner and add a self-contained `SplashSolvingOrb` Canvas renderer. The renderer owns one `Ticker`, produces a deterministic depth-sorted sphere for each time value, and paints anti-aliased circles at device-native resolution. No image, GIF, video, Lottie, shader, SwiftUI, Metal, package dependency, auth timing, or Dawn initialization path changes. The production build is made from an APFS clone of the complete current dirty tree, signed under the existing team, and installed only with `devicectl device install app` after separately copied and per-file verified `Documents` and `Library` backups.

**Tech Stack:** Flutter 3.47.1 / Dart 3.13.1, `CustomPainter`, `Ticker`, `flutter_test`, Xcode automatic signing, `devicectl` CoreDevice workflow.

**Design spec:** `docs/superpowers/specs/2026-08-25-splash-solving-orb-design.md`

**Immutable upstream input:** `flutter_thinking_orbs` 0.1.0, repository `https://github.com/iamEtornam/thinking-orbs`, revision `24115f7fe39da85a85b1eeb638dcfc7becaa7022`, MIT license, solving/rubik mode only.

---

## Global constraints

- Production bundle and data container: `com.kyle.PocketWorld`; device: Kyle's iPhone. Use CoreDevice identifier `1B290474-D354-5B4C-AAB0-0805AC5DC832` for every `devicectl` command and hardware UDID `00008120-00146C4A1AEBC01E` only for `idevicescreenshot`; signing team: `26AH7V448L`.
- Never run `uninstall`, `flutter install`, or `flutter drive` for the production bundle. Never delete or replace its app data container.
- Preserve all unrelated tracked, staged, modified, and relevant untracked files. Never use `reset`, `clean`, `checkout`, or `stash`; never stage a directory or use `git add -A`.
- Build with the existing `/opt/homebrew/bin/flutter`, existing package cache, existing Pods and `--no-pub`. Do not fetch or upgrade dependencies.
- The pinned product baseline has `enable-swift-package-manager=false`. Reproduce that value explicitly in the task-local `XDG_CONFIG_HOME`; an empty isolated config re-enables SPM by Flutter 3.47 default and removes CocoaPods plugins such as `app_links` from this hybrid project.
- Build/sign/install commands run in one user-visible normal macOS Terminal window. Build output and source clone stay under `/private/tmp`.
- Copy `Documents` and `Library` separately; never copy app-container root `.`. Hash every copied file and verify the saved bytes with `shasum -c` before installing.
- Install only after bundle ID, deep signature, arm64 ABI, signed splash marker, Dart AOT identity and source-manifest identity are recorded.
- After installation, copy `Documents` and `Library` again. Every pre-existing file must be present and byte-identical. Only `Library/SplashBoard/Snapshots/**` may be excluded, and excluded paths must be recorded.
- Any failure before the explicit `UPDATE_COMPLETE` marker stops the update. Keep the backup and candidate; do not retry with another package.

## File structure

| File | Responsibility |
|---|---|
| `lib/ui/splash_solving_orb.dart` | Realtime clock, reduced-motion behavior, deterministic solving-particle geometry, projection, depth sort, Canvas circles. |
| `lib/ui/splash_overlay.dart` | Full-screen black substrate, exact geometric centering, white/light status bar style, 420 ms fade, ticker lifetime. |
| `test/splash_solving_orb_test.dart` | Pure geometry determinism, bounds, time progression and painter configuration. |
| `test/splash_overlay_test.dart` | Black/centered/128 pt/white/0.8 contract, old-content removal, reduced motion, fade teardown. |
| `ios/Runner/Info.plist` | Signed candidate identity `PWSplashExperimentMarker=solving-orb-20260825-v1`. |
| `THIRD_PARTY_NOTICES` | Append-only MIT attribution for the cropped upstream solving renderer. |

---

## Task 1: Lock the visual and lifecycle contract with failing tests

**Files:**
- Create: `test/splash_solving_orb_test.dart`
- Create: `test/splash_overlay_test.dart`

- [ ] **Step 1: Add the widget contract test**

Create `test/splash_overlay_test.dart` with these exact assertions:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/splash_overlay.dart';
import 'package:pocketworld_flutter/ui/splash_solving_orb.dart';

Widget _host({required bool visible, bool disableAnimations = false}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: AetherSplashOverlay(
        visible: visible,
        progressMessage: 'legacy progress must not render',
      ),
    ),
  );
}

void main() {
  testWidgets('shows one 128pt white solving orb at speed 0.8 on black',
      (tester) async {
    tester.view.physicalSize = const Size(1179, 2556);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(_host(visible: true));

    final background = tester.widget<ColoredBox>(
      find.byKey(const ValueKey('splash-background')),
    );
    final orb = tester.widget<SplashSolvingOrb>(find.byType(SplashSolvingOrb));
    expect(background.color, Colors.black);
    expect(orb.size, 128);
    expect(orb.speed, 0.8);
    expect(orb.color, Colors.white);
    expect(tester.getCenter(find.byType(SplashSolvingOrb)),
        tester.getCenter(find.byKey(const ValueKey('splash-background'))));
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('legacy progress must not render'), findsNothing);
    expect(find.text('方寸间'), findsNothing);
  });

  testWidgets('reduced motion paints the representative frozen frame',
      (tester) async {
    await tester.pumpWidget(
      _host(visible: true, disableAnimations: true),
    );
    final paint = tester.widget<CustomPaint>(
      find.descendant(
        of: find.byType(SplashSolvingOrb),
        matching: find.byType(CustomPaint),
      ),
    );
    final painter = paint.painter! as SplashSolvingOrbPainter;
    expect(painter.frozenTime, SplashSolvingOrb.reducedMotionTime);
  });

  testWidgets('removes the orb after the 420ms fade', (tester) async {
    await tester.pumpWidget(_host(visible: true));
    await tester.pumpWidget(_host(visible: false));
    await tester.pump(const Duration(milliseconds: 420));
    await tester.pump();
    expect(find.byType(SplashSolvingOrb), findsNothing);
  });
}
```

- [ ] **Step 2: Add the pure renderer contract test**

Create `test/splash_solving_orb_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/ui/splash_solving_orb.dart';

List<String> _snapshot(List<SplashSolvingParticle> particles) => particles
    .map((p) => '${p.x.toStringAsFixed(8)},${p.y.toStringAsFixed(8)},'
        '${p.depth.toStringAsFixed(8)},${p.radius.toStringAsFixed(8)},'
        '${p.opacity.toStringAsFixed(8)}')
    .toList(growable: false);

void main() {
  test('solving particle field is deterministic, animated and in bounds', () {
    final first = buildSplashSolvingParticles(size: 128, time: 0.6);
    final repeated = buildSplashSolvingParticles(size: 128, time: 0.6);
    final later = buildSplashSolvingParticles(size: 128, time: 1.1);

    expect(_snapshot(first), _snapshot(repeated));
    expect(_snapshot(first), isNot(_snapshot(later)));
    expect(first, isNotEmpty);
    for (final p in first) {
      expect(p.x, inInclusiveRange(0, 128));
      expect(p.y, inInclusiveRange(0, 128));
      expect(p.radius, greaterThan(0));
      expect(p.opacity, inInclusiveRange(0, 1));
    }
  });

  test('painter carries the requested white color, speed and frozen time', () {
    final time = ValueNotifier<double>(0);
    addTearDown(time.dispose);
    final painter = SplashSolvingOrbPainter(
      time: time,
      speed: 0.8,
      color: Colors.white,
      frozenTime: 0.6,
    );
    expect(painter.speed, 0.8);
    expect(painter.color, Colors.white);
    expect(painter.frozenTime, 0.6);
  });
}
```

- [ ] **Step 3: Prove both tests fail for the missing renderer/old splash**

Run:

```bash
cd /Users/kaidongwang/Developer/pocketworld
flutter test test/splash_solving_orb_test.dart test/splash_overlay_test.dart
```

Expected: FAIL because `lib/ui/splash_solving_orb.dart` and `SplashSolvingOrb` do not exist; after that compile failure is resolved, the old gradient/logo/progress splash still violates the contract.

---

## Task 2: Implement the realtime solving particle renderer

**Files:**
- Create: `lib/ui/splash_solving_orb.dart`
- Test: `test/splash_solving_orb_test.dart`

- [ ] **Step 1: Add the public widget and painter interfaces**

Implement these exact public contracts, keeping all move/projection helpers library-private:

```dart
class SplashSolvingOrb extends StatefulWidget {
  const SplashSolvingOrb({
    super.key,
    this.size = 128,
    this.speed = 0.8,
    this.color = Colors.white,
    this.animate = true,
  }) : assert(size > 0), assert(speed > 0);

  static const double reducedMotionTime = 0.6;
  final double size;
  final double speed;
  final Color color;
  final bool animate;
}

class SplashSolvingParticle {
  const SplashSolvingParticle({
    required this.x,
    required this.y,
    required this.depth,
    required this.radius,
    required this.opacity,
  });
  final double x;
  final double y;
  final double depth;
  final double radius;
  final double opacity;
}

class SplashSolvingOrbPainter extends CustomPainter {
  SplashSolvingOrbPainter({
    required this.time,
    required this.speed,
    required this.color,
    this.frozenTime,
  }) : super(repaint: time);
  final ValueListenable<double> time;
  final double speed;
  final Color color;
  final double? frozenTime;
}
```

The state owns one `Stopwatch`, `ValueNotifier<double>` and `Ticker`. It starts only when `animate && !MediaQuery.disableAnimations`, is naturally muted by `TickerMode`, freezes at `0.6` for reduced motion, and disposes all three lifecycle resources. Wrap the 128 pt `CustomPaint` in `Semantics(label: 'Solving', image: true)`.

- [ ] **Step 2: Port only the solving/rubik geometry**

Use the upstream large-mode resolved constants exactly:

```dart
const _latRings = 9;       // round(15 * sqrt(0.35))
const _lonDensity = 24;    // round(40 * sqrt(0.35))
const _moveCount = 14;
const _bakedSpeed = 1.82;
const _radiusScale = 1.05;
const _rBase = 0.6 * _radiusScale;
const _rDepth = 1.7 * _radiusScale;
const _rActive = 0.3 * _radiusScale;
const _inkFar = 0.62;
const _inkSpan = 0.54;
const _radiusPower = 0.6;
const _minimumRadius = 0.3;
```

`paint()` resolves draw time as:

```dart
final drawTime = frozenTime ?? time.value * _bakedSpeed * speed;
final particles = buildSplashSolvingParticles(
  size: size.shortestSide,
  time: drawTime,
);
for (final particle in particles) {
  paint.color = color.withValues(alpha: particle.opacity);
  canvas.drawCircle(
    Offset(particle.x, particle.y),
    particle.radius,
    paint,
  );
}
```

The pure builder must reproduce upstream `_solveCycle`, `_makeMoves`, `_applyMoves`, orthographic yaw/tilt projection, far-to-near depth sorting and sub-linear radius scaling. Convert the upstream light/dark grayscale into white particle opacity on black:

```dart
final brightness = 1 - (_inkFar - _inkSpan * depth - (inActive ? 0.14 : 0));
final opacity = brightness.clamp(0.0, 1.0);
```

Keep the upstream MIT provenance and exact revision in the file header. Do not copy the other five modes or add a package dependency.

- [ ] **Step 3: Run the pure renderer test**

Run: `flutter test test/splash_solving_orb_test.dart`

Expected: PASS.

---

## Task 3: Replace the old splash without changing boot timing

**Files:**
- Modify: `lib/ui/splash_overlay.dart`
- Modify: `ios/Runner/Info.plist`
- Test: `test/splash_overlay_test.dart`

- [ ] **Step 1: Reduce the overlay to one fade controller**

Delete the logo spin/pulse controllers, logo painter, localization and design-system imports. Preserve the public `progressMessage` parameter so the two dirty-tree call sites in `lib/main.dart` do not change. Keep the existing 420 ms fade. Render this exact body while visible or fading:

```dart
return IgnorePointer(
  ignoring: !widget.visible,
  child: FadeTransition(
    opacity: _fadeCtrl,
    child: const AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: ColoredBox(
        key: ValueKey('splash-background'),
        color: Colors.black,
        child: Center(
          child: SplashSolvingOrb(
            key: ValueKey('splash-solving-orb'),
            size: 128,
            speed: 0.8,
            color: Colors.white,
          ),
        ),
      ),
    ),
  ),
);
```

When `!widget.visible && _fadeCtrl.isDismissed`, return `SizedBox.shrink()` so the orb is disposed and its realtime ticker cannot repaint behind sign-in/home.

- [ ] **Step 2: Add a signed candidate marker**

Add to `ios/Runner/Info.plist` immediately after `AetherExperimentMarker`:

```xml
<key>PWSplashExperimentMarker</key>
<string>solving-orb-20260825-v1</string>
```

- [ ] **Step 3: Run the overlay test**

Run: `flutter test test/splash_overlay_test.dart`

Expected: PASS.

- [ ] **Step 4: Run the existing app boot test**

Run: `flutter test test/widget_test.dart`

Expected: PASS; auth boot and sign-in timing are unchanged.

---

## Task 4: Preserve third-party license evidence

**Files:**
- Modify append-only: `THIRD_PARTY_NOTICES`

- [ ] **Step 1: Append, never replace, the notice**

Append this exact section after the user's existing dirty notice additions:

```text

Flutter Thinking Orbs — solving renderer (source-derived Dart subset)
=====================================================================

Use in PocketWorld: realtime dotted solving orb on the Flutter startup overlay.
Source: https://github.com/iamEtornam/thinking-orbs
Version: 0.1.0
Revision: 24115f7fe39da85a85b1eeb638dcfc7becaa7022
License: MIT
Copyright (c) 2026 Bright Sunu

This is a Flutter port of "thinking-orbs"
(https://github.com/Jakubantalik/thinking-orbs) by Jakub Antalik, used under
the MIT License. The orb animation algorithms and tunings originate from that
project. The MIT copyright and permission notice are retained in
lib/ui/splash_solving_orb.dart.
```

- [ ] **Step 2: Verify only an append was made over the pre-existing dirty notice**

Run:

```bash
git diff -- THIRD_PARTY_NOTICES
tail -25 THIRD_PARTY_NOTICES
```

Expected: prior uncommitted native/license additions remain byte-for-byte present, followed by the new orb section.

---

## Task 5: Local quality gate and independent review

- [ ] **Step 1: Format only owned Dart files**

Run:

```bash
dart format lib/ui/splash_solving_orb.dart lib/ui/splash_overlay.dart \
  test/splash_solving_orb_test.dart test/splash_overlay_test.dart
```

- [ ] **Step 2: Run targeted deterministic verification**

Run:

```bash
flutter test test/splash_solving_orb_test.dart test/splash_overlay_test.dart test/widget_test.dart
flutter analyze lib/ui/splash_solving_orb.dart lib/ui/splash_overlay.dart \
  test/splash_solving_orb_test.dart test/splash_overlay_test.dart
```

Expected: all tests PASS; analyzer reports `No issues found!`.

- [ ] **Step 3: Inspect the owned diff and run a fresh-context read-only review**

Review scope:

```bash
git diff -- lib/ui/splash_solving_orb.dart lib/ui/splash_overlay.dart \
  test/splash_solving_orb_test.dart test/splash_overlay_test.dart \
  ios/Runner/Info.plist THIRD_PARTY_NOTICES
```

Acceptance: exact approved visual contract, no frame loop after dismissal, no boot/auth timing change, no package/network/native renderer dependency, preserved dirty-tree notice, no install path violation.

---

## Task 6: Freeze the complete local product identity

All following commands run in one normal macOS Terminal window. Do not run them in the Codex shell.

- [ ] **Step 1: Preflight storage, device and toolchain**

```bash
set -euo pipefail
PW_REPO=/Users/kaidongwang/Developer/pocketworld
PW_COREDEVICE=1B290474-D354-5B4C-AAB0-0805AC5DC832
PW_HARDWARE_UDID=00008120-00146C4A1AEBC01E
PW_BUNDLE=com.kyle.PocketWorld
PW_RUN=20260825-splash-solving-orb-v1
PW_STAGE=/private/tmp/pocketworld-${PW_RUN}
PW_BACKUP=/Users/kaidongwang/pw_device_backups/${PW_RUN}
PW_EVIDENCE=${PW_STAGE}/evidence
test "$(df -Pk /Users/kaidongwang | awk 'NR==2 {print int($4/1024/1024)}')" -ge 6
test "$(command -v flutter)" = /opt/homebrew/bin/flutter
flutter --version
xcrun devicectl list devices | grep -F "$PW_COREDEVICE"
mkdir -p "$PW_EVIDENCE" "$PW_BACKUP/pre/Documents" \
  "$PW_BACKUP/pre/Library" "$PW_BACKUP/post/Documents" \
  "$PW_BACKUP/post/Library"
```

Expected: at least 6 GiB free, Flutter 3.47.1 / Dart 3.13.1, exact paired iPhone visible.

- [ ] **Step 2: Record HEAD, index, working-tree and relevant untracked content**

```bash
cd "$PW_REPO"
git rev-parse HEAD > "$PW_EVIDENCE/source-head.txt"
git status --porcelain=v1 -uall > "$PW_EVIDENCE/source-status.txt"
git diff --binary > "$PW_EVIDENCE/unstaged.patch"
git diff --cached --binary > "$PW_EVIDENCE/staged.patch"
git ls-files -co --exclude-standard -z | while IFS= read -r -d '' p; do
  test -f "$p" && shasum -a 256 "$p"
done | LC_ALL=C sort > "$PW_EVIDENCE/source-content.sha256"
shasum -a 256 "$PW_EVIDENCE/source-head.txt" \
  "$PW_EVIDENCE/source-status.txt" "$PW_EVIDENCE/unstaged.patch" \
  "$PW_EVIDENCE/staged.patch" "$PW_EVIDENCE/source-content.sha256" \
  > "$PW_EVIDENCE/source-identity.sha256"
```

Expected: manifest covers tracked, modified, staged and relevant untracked files; it is not represented by Git HEAD alone.

- [ ] **Step 3: APFS-clone the exact complete tree and verify its source manifest**

```bash
test ! -e "$PW_STAGE/source"
cp -cR "$PW_REPO" "$PW_STAGE/source"
cd "$PW_STAGE/source"
git ls-files -co --exclude-standard -z | while IFS= read -r -d '' p; do
  test -f "$p" && shasum -a 256 "$p"
done | LC_ALL=C sort > "$PW_EVIDENCE/cloned-content.sha256"
cmp "$PW_EVIDENCE/source-content.sha256" "$PW_EVIDENCE/cloned-content.sha256"
find /Users/kaidongwang/Developer/Aether3D-cross/dist -type f \
  -exec shasum -a 256 {} + | LC_ALL=C sort \
  > "$PW_EVIDENCE/sibling-dist.sha256"
```

Expected: exact content manifest match. `cp -cR` is an APFS copy-on-write clone, retaining all current local state without rebuilding from an old commit.

---

## Task 7: Copy and verify pre-install phone data

- [ ] **Step 1: Copy `Documents` and `Library` separately**

```bash
xcrun devicectl device copy from --device "$PW_COREDEVICE" \
  --domain-type appDataContainer --domain-identifier "$PW_BUNDLE" \
  --user mobile --source Documents --destination "$PW_BACKUP/pre/Documents" \
  --timeout 1200
xcrun devicectl device copy from --device "$PW_COREDEVICE" \
  --domain-type appDataContainer --domain-identifier "$PW_BUNDLE" \
  --user mobile --source Library --destination "$PW_BACKUP/pre/Library" \
  --timeout 1200
```

No `--source .` call is permitted.

- [ ] **Step 2: Hash and reopen every copied file**

```bash
cd "$PW_BACKUP/pre/Documents"
find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort \
  > "$PW_EVIDENCE/Documents.before.sha256"
cd "$PW_BACKUP/pre/Library"
find . -type f ! -path './SplashBoard/Snapshots/*' \
  -exec shasum -a 256 {} + | LC_ALL=C sort \
  > "$PW_EVIDENCE/Library.before.sha256"
test -s "$PW_EVIDENCE/Documents.before.sha256"
test -s "$PW_EVIDENCE/Library.before.sha256"
(cd "$PW_BACKUP/pre/Documents" && \
  shasum -a 256 -c "$PW_EVIDENCE/Documents.before.sha256")
(cd "$PW_BACKUP/pre/Library" && \
  shasum -a 256 -c "$PW_EVIDENCE/Library.before.sha256")
```

Expected: both directory manifests are non-empty and every saved file reopens with its recorded SHA-256. Any mismatch stops the update.

---

## Task 8: Build and validate the signed candidate in `/private/tmp`

- [ ] **Step 1: Configure with the pinned Flutter/package state and build under `/private/tmp`**

```bash
PW_SOURCE="$PW_STAGE/source"
PW_CONFIG="$PW_STAGE/flutter-config"
PW_BUILD="$PW_STAGE/flutter-build/ios/iphoneos"
mkdir -p "$PW_CONFIG"
cd "$PW_SOURCE"
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 XDG_CONFIG_HOME="$PW_CONFIG" \
  flutter config --no-enable-swift-package-manager
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 XDG_CONFIG_HOME="$PW_CONFIG" \
  flutter config --build-dir=../flutter-build
LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8 XDG_CONFIG_HOME="$PW_CONFIG" \
  flutter build ios --release --no-pub | tee "$PW_EVIDENCE/flutter-build.log"
PW_APP="$PW_BUILD/Runner.app"
test -d "$PW_APP"
```

The full Flutter command is intentional: `--config-only` does not provide the product build. The task-local relative build directory resolves below `/private/tmp`, avoids reusing any cloned historical output, and keeps signed artifacts away from Documents/File Provider. Do not override Xcode's `BUILD_DIR` or switch dependency managers.

Expected: a newly built signed app under `/private/tmp`; no dependency fetch and no build output in Documents/File Provider.

- [ ] **Step 2: Validate identity, signature, architecture, marker and native ABI**

```bash
test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PW_APP/Info.plist")" = "$PW_BUNDLE"
test "$(/usr/libexec/PlistBuddy -c 'Print :PWSplashExperimentMarker' "$PW_APP/Info.plist")" = solving-orb-20260825-v1
codesign --verify --deep --strict --verbose=2 "$PW_APP"
lipo -info "$PW_APP/Runner" | grep -F arm64
nm -gU "$PW_APP/Runner" | grep -F _pw_official_sfm_
codesign -d --entitlements :- "$PW_APP" > "$PW_EVIDENCE/signed-entitlements.plist" 2>&1
plutil -p "$PW_APP/Info.plist" > "$PW_EVIDENCE/signed-info-plist.txt"
shasum -a 256 "$PW_APP/Runner" "$PW_APP/Frameworks/App.framework/App" \
  > "$PW_EVIDENCE/signed-app.sha256"
```

Expected: exact production bundle ID, valid deep signature, arm64, expected native SFM ABI, exact signed splash marker.

---

## Task 9: Install only while the phone is idle, then prove data identity

- [ ] **Step 1: Immediately before install, confirm the app is not capturing/reconstructing**

Use `devicectl device copy from` to pull `Documents/telemetry_official_dart.jsonl` into `$PW_EVIDENCE/pre-install-telemetry.jsonl`, then inspect the last ten minutes for active `shutter`, `hires_still`, `frame`, capture or reconstruction events. If active, stop and wait; do not terminate the app during work.

- [ ] **Step 2: Perform the only permitted installation command**

```bash
xcrun devicectl device install app --device "$PW_COREDEVICE" "$PW_APP" \
  | tee "$PW_EVIDENCE/install.log"
```

Expected: in-place update of `com.kyle.PocketWorld`. There must be no uninstall command anywhere in the Terminal history or evidence.

- [ ] **Step 3: Verify registration without launching the app**

```bash
xcrun devicectl device info apps --device "$PW_COREDEVICE" | grep -F PocketWorld \
  | tee "$PW_EVIDENCE/post-install-app.txt"
```

Expected: the updated app is registered. Do not launch yet, because app startup may legitimately rewrite files under `Library` before the container identity check.

- [ ] **Step 4: Copy post-install data and compare every pre-existing file**

```bash
xcrun devicectl device copy from --device "$PW_COREDEVICE" \
  --domain-type appDataContainer --domain-identifier "$PW_BUNDLE" \
  --user mobile --source Documents --destination "$PW_BACKUP/post/Documents" \
  --timeout 1200
xcrun devicectl device copy from --device "$PW_COREDEVICE" \
  --domain-type appDataContainer --domain-identifier "$PW_BUNDLE" \
  --user mobile --source Library --destination "$PW_BACKUP/post/Library" \
  --timeout 1200
(cd "$PW_BACKUP/post/Documents" && \
  shasum -a 256 -c "$PW_EVIDENCE/Documents.before.sha256") \
  | tee "$PW_EVIDENCE/Documents.after.verify.txt"
(cd "$PW_BACKUP/post/Library" && \
  shasum -a 256 -c "$PW_EVIDENCE/Library.before.sha256") \
  | tee "$PW_EVIDENCE/Library.after.verify.txt"
cd "$PW_BACKUP/post/Library"
find ./SplashBoard/Snapshots -type f -exec shasum -a 256 {} + \
  > "$PW_EVIDENCE/excluded-splashboard.sha256" 2>/dev/null || true
```

Expected: both `shasum -c` commands exit zero, proving every pre-existing `Documents`/`Library` file is present and byte-identical; only recorded SplashBoard snapshots are outside identity comparison.

- [ ] **Step 5: Launch the exact installed app and visually validate the splash**

```bash
xcrun devicectl device process launch --terminate-existing \
  --device "$PW_COREDEVICE" "$PW_BUNDLE" \
  | tee "$PW_EVIDENCE/post-install-launch.txt"
```

Expected: the exact production bundle launches; visually confirm the realtime white solving orb is centered on black and animates at the approved pace.

- [ ] **Step 6: Emit completion only after every gate passed**

```bash
printf '%s\n' UPDATE_COMPLETE | tee "$PW_EVIDENCE/UPDATE_COMPLETE"
```

No completion claim is allowed unless this exact marker exists and the preceding `cmp` exited zero.

---

## Plan self-review checklist

- [ ] Approved design is exact: black full screen, one centered 128 pt white realtime solving orb, speed 0.8, no text/progress/logo.
- [ ] Rendering is realtime Canvas/Ticker at device pixel ratio, not a prerendered asset.
- [ ] Reduced motion and overlay dismissal stop animation work.
- [ ] Existing `progressMessage` call sites and boot/auth timing remain compatible.
- [ ] Upstream revision and MIT attribution are frozen and retained.
- [ ] Tests fail before implementation and pass after it.
- [ ] Current dirty product tree—not an old commit—is the build carrier.
- [ ] `--no-pub`, pinned Flutter, `/private/tmp`, separate per-file-verified backups, exact device/bundle/team are explicit.
- [ ] No uninstall/reinstall/`flutter install`/`flutter drive` path exists.
- [ ] Post-install byte identity and `UPDATE_COMPLETE` are mandatory.
