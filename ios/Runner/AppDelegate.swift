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

    // [pw][vio] Blocker 01 采集侧:时基测量。只测不判 —— 偏置/漂移/域判决全在
    //   Dart lib/vio/timebase/ 里做,与 Android 共用同一份实现。
    //   必须在采集开始前注册,否则域错配无法被检出(而域错配是静默的)。
    if let registrar = self.registrar(forPlugin: "PwVioTimebasePlugin") {
      PwVioTimebasePlugin.register(with: registrar)
    } else {
      NSLog("[AppDelegate] registrar(forPlugin: PwVioTimebasePlugin) nil — VIO 时基无法测量,采集侧将无法判定域错配")
    }

    // [pw][vio] 条目 07:热/降频信号采集。同样只上报原始值,判档在
    //   Dart lib/vio/thermal/ 里做(两端共用)。
    if let registrar = self.registrar(forPlugin: "PwVioThermalPlugin") {
      PwVioThermalPlugin.register(with: registrar)
    } else {
      NSLog("[AppDelegate] registrar(forPlugin: PwVioThermalPlugin) nil — VIO thermal telemetry unavailable")
    }
    // [pw][lod] 2026-09-24 build 171: GPU point-cloud viewer channel 'pw_lod_texture'
    //   (ios/Runner/PwLodTexturePlugin.swift). Same form as the plugins above; the bench's
    //   FlutterImplicitEngineBridge form (feat/lod-viewer 9e2bb09) does not apply here.
    if let registrar = self.registrar(forPlugin: "PwLodTexturePlugin") {
      PwLodTexturePlugin.register(with: registrar)
    } else {
      NSLog("[AppDelegate] registrar(forPlugin: PwLodTexturePlugin) nil — cloud views fall back to the CPU painter")
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

    // Automatic cold archive maintenance uses a separate BGProcessingTask.
    // Register before launch returns so iOS can deliver a persisted request to
    // a fresh process; Dart still owns every archive/deletion decision.
    if #available(iOS 13.0, *) {
      if let registrar = self.registrar(
        forPlugin: "OfficialArchiveBackgroundTask"
      ) {
        OfficialArchiveBackgroundTask.shared.register(with: registrar)
      } else {
        NSLog("[AppDelegate] archive background registrar unavailable")
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
