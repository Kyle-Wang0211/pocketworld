import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    // In-Runner-target Swift plugins.
    // AetherTexturePlugin bridges the Flutter Texture widget to the
    // aether3d_ffi native scene renderer (Dawn/Filament PBR + splat).
    // OfficialAetherARKitPlugin exposes the single production ARKit capture
    // runtime. Legacy self-route records remain readable from disk but cannot
    // start a second capture session.
    // (Key-value prefs now use the standard shared_preferences pod,
    // registered by GeneratedPluginRegistrant above.)
    if let registrar = self.registrar(forPlugin: "AetherTexturePlugin") {
      AetherTexturePlugin.register(with: registrar)
    } else {
      NSLog("[AppDelegate] registrar(forPlugin: AetherTexturePlugin) nil — texture widget will be blank")
    }
    if #available(iOS 11.0, *) {
      if let registrar = self.registrar(
        forPlugin: "OfficialAetherARKitPlugin"
      ) {
        OfficialAetherARKitPlugin.register(with: registrar)
      } else {
        NSLog("[AppDelegate] registrar(forPlugin: OfficialAetherARKitPlugin) nil — official capture route unavailable")
      }
    }

    // Background-continuation umbrella (iOS 26): the SfM finalize keeps running
    // if the user backgrounds the app mid-solve. MUST register the handler
    // before the app finishes launching, or the system drops the launch.
    if #available(iOS 26.0, *) {
      OfficialReconUmbrella.shared.register()
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
