import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // In-Runner-target Swift plugins. AetherPrefsPlugin replaces
    // shared_preferences because the pod-shipped Swift plugin hit a
    // plugin-registrar metadata race on iOS 26 direct-launch.
    // AetherTexturePlugin bridges the Flutter Texture widget to the
    // aether3d_ffi native scene renderer (Dawn/Filament PBR + splat).
    // AetherARKitPlugin exposes ARKit world-tracking (ARSession +
    // delegate) to Dart for the dome capture flow — see
    // PlatformARPoseProvider on the Dart side.
    if let registrar = self.registrar(forPlugin: "AetherTexturePlugin") {
      AetherTexturePlugin.register(with: registrar)
    } else {
      NSLog("[AppDelegate] registrar(forPlugin: AetherTexturePlugin) nil — texture widget will be blank")
    }
    if let registrar = self.registrar(forPlugin: "AetherPrefsPlugin") {
      AetherPrefsPlugin.register(with: registrar.messenger())
    }
    if #available(iOS 11.0, *) {
      if let registrar = self.registrar(forPlugin: "AetherARKitPlugin") {
        AetherARKitPlugin.register(with: registrar)
      } else {
        NSLog("[AppDelegate] registrar(forPlugin: AetherARKitPlugin) nil — dome will fall back to mock pose")
      }
    }

    // ModelLoaderPlugin — legacy ODR bridge for optional model tiers.
    // MethodChannel `pocketworld/model_loader` + EventChannel
    // `pocketworld/model_loader/progress`. Long-lived because the
    // NSBundleResourceRequest objects retained inside the plugin keep
    // optional mlpackages pinned in the bundle cache. Stage 1 DA3-BASE
    // is intentionally bundled locally and loaded directly by Da3DepthPlugin.
    if let registrar = self.registrar(forPlugin: "ModelLoaderPlugin") {
      ModelLoaderPlugin.register(with: registrar.messenger())
    } else {
      NSLog("[AppDelegate] registrar(forPlugin: ModelLoaderPlugin) nil — DA3 ODR fetch will fail")
    }

    // Da3DepthPlugin — iOS CoreML adapter for Stage 1. Flutter/Dart owns
    // model policy, K-windowing, locked input size, and downstream geometry
    // contracts; this plugin only loads the allowed mlpackage and executes
    // the platform inference request it receives.
    if let registrar = self.registrar(forPlugin: "Da3DepthPlugin") {
      Da3DepthPlugin.register(with: registrar.messenger())
    } else {
      NSLog("[AppDelegate] registrar(forPlugin: Da3DepthPlugin) nil — Stage 1 DA3 CoreML adapter will stay pending")
    }

    // DeviceHealthPlugin — raw telemetry only. Dart owns pause/resume/abort
    // policy through DeviceHealthPolicy; native only reports thermal/RSS/
    // jetsam/CPU samples.
    if let registrar = self.registrar(forPlugin: "DeviceHealthPlugin") {
      DeviceHealthPlugin.register(with: registrar.messenger())
    } else {
      NSLog("[AppDelegate] registrar(forPlugin: DeviceHealthPlugin) nil — device health policy will record missing telemetry")
    }

    // MaterialClassifierPlugin — SigLIP zero-shot binary reflective/diffuse
    // classifier. Kept as material telemetry/preflight; DA3 model selection
    // now lives in Flutter/Dart policy and always uses commercial-safe
    // DA3-BASE tiers. MethodChannel `pocketworld/material_classifier`.
    if let registrar = self.registrar(forPlugin: "MaterialClassifierPlugin") {
      MaterialClassifierPlugin.register(with: registrar.messenger())
    } else {
      NSLog("[AppDelegate] registrar(forPlugin: MaterialClassifierPlugin) nil — material classification will be unavailable")
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
