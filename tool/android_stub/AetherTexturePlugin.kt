// G6 STAGING — Android plugin scaffold.
//
// pocketworld_flutter currently has NO `android/` directory; the App
// Store launch is iOS-only per the project plan, and `flutter create
// --platforms=android .` hasn't been run on this Flutter project yet.
// When Android enters scope:
//
//   1. Run `flutter create --platforms=android .` from
//      pocketworld_flutter/ to generate android/app/src/main/...
//   2. Drop this file at:
//        android/app/src/main/kotlin/com/kyle/pocketworld/AetherTexturePlugin.kt
//      (adjust the package to whatever flutter create generated)
//   3. Register it in MainActivity.kt.configureFlutterEngine:
//        flutterEngine.plugins.add(AetherTexturePlugin())
//   4. The real implementation (SurfaceTexture ↔ Dawn-Vulkan via Dawn's
//      Android backend) lands later — for now this stub returns the
//      same `UnsupportedViewerFormatError`-shaped FlutterError code
//      the iOS plugin uses on missing-symbol failures, so Dart-side
//      catch-and-cover logic handles both uniformly.
//
// Why a stub at all: when Android wiring lands, Dart's
// `kAetherSceneBridgeAvailable` flips true on Android (via
// `Platform.isAndroid` check in scene_bridge.dart). Without this stub
// registered, every MethodChannel call would hit
// MissingPluginException, which the existing catch path classifies as
// a hard error (red retry icon) instead of "platform not yet supported"
// (which is friendlier UX during the gradual Android rollout).

package com.kyle.pocketworld

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class AetherTexturePlugin : FlutterPlugin, MethodCallHandler {
    private var channel: MethodChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "aether_texture").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        // Every method returns the same error code. The Dart side
        // surfaces this as UnsupportedViewerFormatError-equivalent and
        // the PostCard cover layer shows a "Android viewer coming
        // soon" placeholder instead of crashing.
        result.error(
            "PLATFORM_NOT_SUPPORTED",
            "aether_texture is iOS / macOS only until G6 lands the " +
                "Android Dawn-Vulkan + SurfaceTexture wiring " +
                "(see pocketworld_flutter/lib/aether_view/scene_bridge.dart " +
                "kAetherSceneBridgeAvailable for the platform gate).",
            mapOf("method" to call.method),
        )
    }
}
