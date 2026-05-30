import Flutter
import UIKit

// EXP 9 (2026-04-28): Flutter stable 3.41.8 on iOS 26 requires Scene-based
// lifecycle — Info.plist must declare UIApplicationSceneManifest with
// UISceneDelegateClassName pointing here, and the class must inherit
// FlutterSceneDelegate so Flutter's engine can reliably attach its
// FlutterView to the active UIWindowScene.
// DA3 benchmark-only Swift entrypoints were removed from the Runner build
// when the local product path moved to Flutter/Dart-owned photo bundles.

class SceneDelegate: FlutterSceneDelegate {}
