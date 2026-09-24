// PwBenchUnifiedPlugin.swift — channel 'pw_bench_unified' for the arloopbench home menu (bench-only,
// never compiled into production).
//
//   launchArgs            every `-PW<Key> <value>` pair of this launch, key without the dash
//                         (value = the next argv entry, as PWSplatAB's argStr and PwBenchReplayLaunch do).
//   enterFullChain        registers production 168's four Runner plugins (AppDelegate installs the closure);
//                         the Dart side then calls production main(). Idempotent.
//   vioKitStatus / openVioKit
//                         loads Frameworks/PWVIOBenchKit.framework on demand (the old VIO Replacement
//                         Bench harness, bench/viobench_kit) and presents its SwiftUI root full screen.
//                         The app does not link the kit, so nothing of it loads unless this is used.
//   splatStart / splatStatus
//                         the PWSplatAB benches (PwSplatABRunner.swift).
import Flutter
import UIKit

final class PwBenchUnifiedPlugin: NSObject, FlutterPlugin {
    /// Installed by AppDelegate: registers the production plugins on the running engine; returns
    /// true when they are registered (now or earlier).
    static var fullChainRegistrar: (() -> Bool)?

    static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "pw_bench_unified", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(PwBenchUnifiedPlugin(), channel: channel)
    }

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let a = call.arguments as? [String: Any] ?? [:]
        switch call.method {
        case "launchArgs":
            result(PwBenchUnifiedPlugin.launchArgs())
        case "enterFullChain":
            result(PwBenchUnifiedPlugin.fullChainRegistrar?() ?? false)
        case "vioKitStatus":
            result(PwBenchUnifiedPlugin.vioKitStatus())
        case "openVioKit":
            PwBenchUnifiedPlugin.openVioKit(result)
        case "splatStart":
            var p: [String: String] = [:]
            for (k, v) in a { p[k] = "\(v)" }
            result(PwSplatABRunner.start(p))
        case "splatStatus":
            result(PwSplatABRunner.snapshot())
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    static func launchArgs() -> [String: String] {
        var out: [String: String] = [:]
        let argv = ProcessInfo.processInfo.arguments
        var i = 1
        while i < argv.count {
            let k = argv[i]
            if k.hasPrefix("-PW") {
                let key = String(k.dropFirst())
                if i + 1 < argv.count {
                    out[key] = argv[i + 1]
                    i += 2
                    continue
                }
                out[key] = ""
            }
            i += 1
        }
        return out
    }

    // MARK: - old VIO Replacement Bench (PWVIOBenchKit.framework)

    private static var kitURL: URL? {
        Bundle.main.privateFrameworksURL?.appendingPathComponent("PWVIOBenchKit.framework", isDirectory: true)
    }

    static func vioKitStatus() -> [String: Any] {
        guard let url = kitURL else { return ["present": false] }
        let present = FileManager.default.fileExists(atPath: url.appendingPathComponent("PWVIOBenchKit").path)
        return ["present": present, "loaded": Bundle(url: url)?.isLoaded ?? false]
    }

    static func openVioKit(_ result: @escaping FlutterResult) {
        guard let url = kitURL, let bundle = Bundle(url: url) else {
            result(FlutterError(code: "NO_KIT", message: "Frameworks/PWVIOBenchKit.framework missing", details: nil))
            return
        }
        do {
            if !bundle.isLoaded { try bundle.loadAndReturnError() }
        } catch {
            result(FlutterError(code: "KIT_LOAD", message: "\(error)", details: nil))
            return
        }
        guard let cls = NSClassFromString("PWVIOBenchHost") as? NSObject.Type,
              let made = (cls as AnyObject).perform(NSSelectorFromString("makeViewController"))?.takeUnretainedValue(),
              let vc = made as? UIViewController
        else {
            result(FlutterError(code: "KIT_CLASS", message: "PWVIOBenchHost.makeViewController unavailable", details: nil))
            return
        }
        guard let root = topViewController() else {
            result(FlutterError(code: "NO_ROOT", message: "no key window", details: nil))
            return
        }
        root.present(vc, animated: true) { result(true) }
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var top = window?.rootViewController
        while let p = top?.presentedViewController { top = p }
        return top
    }
}
