// PwSplatABRunner.swift — the PWSplatAB (com.kyle.PWSplatAB) shell, ported into arloopbench (bench-only).
//
// Source: pw_splat_ab_bench Sources/App.swift @ b792d57, class `Runner.go()` and `lodVerify(_:_:)`.
// The benches themselves (PwSplatAB/bench.mm, bench_points.mm, bench_cloud.mm, wgsl_arms.h) are copied
// verbatim. Deviations of this shell, all forced by living inside another app:
//   S1  Parameters come from a dictionary sent by the Flutter page (keys = the old launch-argument
//       names without the dash: PWMode, PWK, PWR, PWWarm, PWCell, PWRad, PWTag, PWCam, PWArms, PWCloud,
//       PWOct, PWLodArgs). The page fills it from the process launch arguments when present, so the
//       old `devicectl process launch … -- -PWMode points …` lines still work; defaults are App.swift's.
//   S2  The run starts when the page asks, not in ContentView.onAppear; one run at a time per process
//       (App.swift ran exactly one per launch).
//   S3  `Runner` is renamed (it would shadow the module name `Runner`); `lodProbe` is arloopbench's
//       existing `pwLodProbe` (PwLodProbe.swift, the same closure); `lod` mode calls the pwlod_run that
//       arloopbench already links (vendor/aether_lod, byte-identical to this bench's pw_lod_bench.cpp).
//   S4  Dawn is arloopbench's single copy (libaether3d_ffi.a). PWSplatAB force-loaded the Aether3D-cross
//       Release libwebgpu_dawn.a instead — a different build; compare old and new numbers with that in mind.
// Outputs are unchanged: Documents/SplatAB/{splat_ab,points,cloud}.json, lod_<tag>.json,
// lod_verify_<oct>_<tag>.json; inputs Documents/cloud.bin and Documents/lod/<oct>/.
import CryptoKit
import Foundation
import UIKit

enum PwSplatABRunner {
    private static let lock = NSLock()
    private static var running = false
    private static var status = "空闲"
    private static var lastResult: String?
    private static var lastSeconds: Double = 0
    private static var lastMode = ""

    static func docs() -> String {
        NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
    }

    static func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["running": running, "status": status, "result": lastResult ?? NSNull(),
                "seconds": lastSeconds, "mode": lastMode]
    }

    private static func set(_ s: String) { lock.lock(); status = s; lock.unlock() }

    /// Returns false if a run is already in progress.
    static func start(_ p: [String: String]) -> Bool {
        lock.lock()
        if running { lock.unlock(); return false }
        running = true
        lock.unlock()

        func int(_ k: String, _ d: Int) -> Int { p[k].flatMap { Int($0) } ?? d }
        func str(_ k: String, _ d: String) -> String { p[k] ?? d }

        let out = docs() + "/SplatAB"
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let K = int("PWK", 100)
        let R = int("PWR", 6)
        let W = int("PWWarm", 30)
        // -PWMode points ⇒ 跑裸点云台架(bench_points.mm),落 points.json。
        // 默认 splat,保持既有跑法逐字不变(旧结果不受影响)。
        let mode = str("PWMode", "splat")
        let cell = int("PWCell", -1)
        let rad = int("PWRad", 15)     // 0.1 px 为单位
        let tag = str("PWTag", "")
        // run 1(09:53)在最后一格出现 1.8x 的断崖,三条臂同步掉 —— 多半是
        // 自动锁屏把合成器让了出来。第二遍把屏幕状态钉死,消掉这个混杂。
        DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = true }
        NSLog("PWSPLATAB start mode=\(mode) K=\(K) R=\(R) warmup=\(W) cell=\(cell) rad=\(rad) tag=\(tag) out=\(out)")
        lock.lock(); lastMode = mode; lock.unlock()
        set("跑中 \(mode) K=\(K) R=\(R)…")
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = Date()
            let p: UnsafePointer<CChar>?
            if mode == "lodverify" {
                // 数据身份核对(外壳侧,CryptoKit):对 Documents/lod/<oct>/ 三个文件算 sha256,
                // 落 lod_verify_<oct>.json。🔴 整读 octree.bin 会把它灌进页缓存 ⇒
                // 必须在测帧率的那次启动【之后】单独跑,不能放在前面。
                let oct = str("PWOct", "oct_prod")
                p = lodVerify(docs() + "/lod/" + oct, out + "/lod_verify_" + oct + "_" + tag + ".json")
            } else if mode == "lod" {
                // LOD 台架(pw_lod_bench.cpp,平台无关 C++/Dawn)。
                // 八叉树由 `devicectl device copy to` 推进 Documents/lod/<name>/,
                // 外壳只负责两样 OS 才知道的东西:热状态、进程内存占用。
                let dir = docs() + "/lod/" + str("PWOct", "oct_prod")
                let largs = str("PWLodArgs", "mode=perf") + " tag=" + tag
                p = pwlod_run(dir, out, largs, pwLodProbe, nil)
            } else if mode == "cloud" {
                // cloud.bin 由 `devicectl device copy to` 推进 Documents,
                // **不开生产 app**(只读拷贝不算启动)。
                let cloudPath = docs() + "/" + str("PWCloud", "cloud.bin")
                p = pwcloud_run(out, cloudPath, Int32(K), Int32(R), Int32(W),
                                Int32(int("PWCam", 0)), Int32(rad),
                                Int32(int("PWArms", 63)), tag)
            } else if mode == "points" {
                p = pwpoints_run(out, Int32(K), Int32(R), Int32(W),
                                 Int32(cell), Int32(rad), tag)
            } else {
                p = pwsplat_ab_run(out, Int32(K), Int32(R), Int32(W))
            }
            let s = p.map { String(cString: $0) } ?? "(null)"
            let dt = Date().timeIntervalSince(t0)
            NSLog("PWSPLATAB done in %.1fs -> %@", dt, s)
            lock.lock()
            running = false
            lastResult = s
            lastSeconds = dt
            status = String(format: "完成 %.1fs\n%@", dt, s)
            lock.unlock()
            DispatchQueue.main.async { UIApplication.shared.isIdleTimerDisabled = false }
        }
        return true
    }

    // App.swift lodVerify(_:_:) verbatim.
    static func lodVerify(_ dir: String, _ outPath: String) -> UnsafePointer<CChar>? {
        var rows: [String] = []
        for name in ["metadata.json", "hierarchy.bin", "octree.bin"] {
            let path = dir + "/" + name
            guard let h = FileHandle(forReadingAtPath: path) else {
                rows.append("\"\(name)\": {\"error\": \"missing\"}"); continue
            }
            var hasher = SHA256()
            var total: UInt64 = 0
            while true {
                let chunk = h.readData(ofLength: 16 << 20)
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                total += UInt64(chunk.count)
            }
            h.closeFile()
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            rows.append("\"\(name)\": {\"bytes\": \(total), \"sha256\": \"\(hex)\"}")
        }
        let json = "{\n  \"dir\": \"\(dir)\",\n  " + rows.joined(separator: ",\n  ") + "\n}\n"
        try? json.write(toFile: outPath, atomically: true, encoding: .utf8)
        return UnsafePointer(strdup(outPath))
    }
}
