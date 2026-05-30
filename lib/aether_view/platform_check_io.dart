// dart:io variant of `kAetherSceneBridgeAvailable`'s platform probe.
//
// G6 / G8 split this out because `dart:io` doesn't exist on web — a
// direct `import 'dart:io'` from scene_bridge.dart compiles fine for
// iOS / macOS / Android but fails on web with a `dart:html or
// js_interop is required` error. Conditional import in scene_bridge:
//
//   import 'platform_check_io.dart'
//     if (dart.library.html) 'platform_check_web.dart';
//
// The web variant short-circuits to false; this variant does the real
// `Platform.isIOS || Platform.isMacOS` check. iOS + macOS are the two
// platforms with a registered AetherTexturePlugin today (Phase 6.4e).
// Android is `false` here too — the `tool/android_stub/AetherTexturePlugin.kt`
// scaffold lands when `flutter create --platforms=android` runs, at
// which point this file flips to also accept `Platform.isAndroid`.

import 'dart:io' show Platform;

bool aetherSceneBridgeAvailableForPlatform() {
  return Platform.isIOS || Platform.isMacOS;
}
