import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// [pw][unified 2026-09-24] 隐式引擎的插件表,留给「进入完整链」时再注册生产插件用。
  private static var implicitRegistry: FlutterPluginRegistry?
  private static var fullChainPluginsRegistered = false

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // [pw][lod 2026-09-24] LOD 点云查看器的纹理插件(通道 'pw_lod_texture';真源 pocketworld
    // feat/lod-viewer ios/Runner/PwLodTexturePlugin.swift,同步脚本 LOD 段镜像)。台架自有代码,
    // 写法 = 外壳 agent 在 9e2bb09 冒烟里编过的那段。生产 AppDelegate 不注册它。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PwLodTexturePlugin") {
      PwLodTexturePlugin.register(with: registrar)
    } else {
      NSLog("[AppDelegate] registrar(forPlugin: PwLodTexturePlugin) nil — LOD page unavailable")
    }
    // [pw][unified 2026-09-24] 台架菜单的通道 'pw_bench_unified'(启动参数 / 进入完整链 / 旧 VIO 台架 / 泼溅 A/B)。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PwBenchUnifiedPlugin") {
      PwBenchUnifiedPlugin.register(with: registrar)
    } else {
      NSLog("[AppDelegate] registrar(forPlugin: PwBenchUnifiedPlugin) nil — bench menu channel unavailable")
    }
    AppDelegate.implicitRegistry = engineBridge.pluginRegistry
    PwBenchUnifiedPlugin.fullChainRegistrar = { AppDelegate.registerFullChainPlugins() }
    // 旧 define 包(--dart-define=PW_FULL_CHAIN_BENCH=true,构建期盖进 Info.plist 的 PWFullChainBench):
    // Dart main 一上来就跑生产 main(),插件要在这里就注册好。合一包里这个键是 NO,改由菜单「进入」时注册。
    if (Bundle.main.object(forInfoDictionaryKey: "PWFullChainBench") as? Bool) == true {
      _ = AppDelegate.registerFullChainPlugins()
    }
  }

  // [pw][full-chain 2026-09-24] 完整重建链 168:生产 AppDelegate.swift:9-50 的 Runner 内插件注册,原样照抄,
  //   只把 self.registrar(forPlugin:) 换成隐式引擎的 registry(台架是 FlutterImplicitEngineDelegate 形态)。
  //   [unified 2026-09-24] 从「启动时按 Info.plist 开关注册」改成「进入完整链时注册」(旧 define 包仍在启动时注册):
  //   不进完整链就不注册 ⇒ PwVioTimebasePlugin 不会给台架自己的 VIO 页凭空多出 pocketworld_vio_timebase 通道
  //   (那些页按「台架没有这个通道 ⇒ prime() 如实 null」写的),与原来的台架默认包一致。
  //   生产那两处后台任务登记(OfficialArchiveBackgroundTask / OfficialReconUmbrella)不照抄,理由见适配清单:
  //   BGTaskScheduler 必须在 didFinishLaunching 返回前登记、标识必须在 Info.plist 许可表里(台架 Info.plist 没有,
  //   登记即崩),且 recon 标识必须以 bundle id 为前缀(com.kyle.PocketWorld.* ≠ com.kyle.arloopbench)。
  //   两者缺席时生产代码都有兜底:Dart 侧 MissingPluginException → 进程内立即归档;umbrella submit 失败只记日志。
  static func registerFullChainPlugins() -> Bool {
    if fullChainPluginsRegistered { return true }
    guard let registry = implicitRegistry else {
      NSLog("[AppDelegate] full-chain plugins: no engine registry")
      return false
    }
    if let registrar = registry.registrar(forPlugin: "AetherTexturePlugin") {
      AetherTexturePlugin.register(with: registrar)
    } else {
      NSLog("[AppDelegate] registrar(forPlugin: AetherTexturePlugin) nil — texture widget will be blank")
    }
    if let registrar = registry.registrar(forPlugin: "PwVioTimebasePlugin") {
      PwVioTimebasePlugin.register(with: registrar)
    } else {
      NSLog("[AppDelegate] registrar(forPlugin: PwVioTimebasePlugin) nil — VIO 时基无法测量,采集侧将无法判定域错配")
    }
    if let registrar = registry.registrar(forPlugin: "PwVioThermalPlugin") {
      PwVioThermalPlugin.register(with: registrar)
    } else {
      NSLog("[AppDelegate] registrar(forPlugin: PwVioThermalPlugin) nil — VIO thermal telemetry unavailable")
    }
    if #available(iOS 11.0, *) {
      if let registrar = registry.registrar(forPlugin: "OfficialAetherARKitPlugin") {
        OfficialAetherARKitPlugin.register(with: registrar)
      } else {
        NSLog("[AppDelegate] registrar(forPlugin: OfficialAetherARKitPlugin) nil — official capture route unavailable")
      }
    }
    fullChainPluginsRegistered = true
    NSLog("[AppDelegate] full-chain 168 plugins registered")
    return true
  }
}
