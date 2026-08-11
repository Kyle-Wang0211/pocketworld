// VTProbe — P0-a Level-6 硬编探针
// 目的：回答"这台 iPhone 的硬件 HEVC 编码器能否吃下 4224x2376（Level 6）"，
// 以及各兜底分辨率与 GOP 模式的实测编码延迟。
// 拔线安全：启动即自动跑完整矩阵，结果写入 Documents/vtprobe-results.json；
// 无需保持连接，之后随时用 devicectl 取回。

import SwiftUI
import VideoToolbox
import CoreVideo
import UIKit

@main
struct VTProbeApp: App {
    var body: some Scene {
        WindowGroup { ProbeView() }
    }
}

struct ProbeView: View {
    @State private var status = "运行中…"
    var body: some View {
        ScrollView {
            Text(status).font(.system(size: 12, design: .monospaced)).padding()
        }
        .task {
            let report = await ProbeRunner.runAll()
            status = report
        }
    }
}

struct ConfigResult: Codable {
    let width: Int
    let height: Int
    let lumaSamples: Int
    let hevcLevelRequired: String
    let gop: Int
    let sessionCreated: Bool
    let sessionStatus: Int32
    let usingHardware: Bool?
    let framesRequested: Int
    let framesEncoded: Int
    let framesFailed: Int
    let totalOutputBytes: Int
    let avgEncodeMs: Double
    let firstError: Int32?
}

struct ProbeReport: Codable {
    let schema: String
    let device: String
    let systemVersion: String
    let thermalStateStart: String
    let thermalStateEnd: String
    let configs: [ConfigResult]
}

enum ProbeRunner {
    static let resolutions: [(Int, Int, String)] = [
        (4224, 2376, "L6 (10,036,224 > L5.2 上限 8,912,896)"),
        (4096, 2176, "L5.x 恰好压线 (8,912,896)"),
        (3840, 2160, "L5.1 安全 (8,294,400)"),
        (2112, 2376, "双流切片单条 (5,018,112)"),
    ]

    static func runAll() async -> String {
        let thermal0 = thermalName()
        var results: [ConfigResult] = []
        for (w, h, level) in resolutions {
            for gop in [1, 8] {
                let r = await runConfig(width: w, height: h, level: level, gop: gop)
                results.append(r)
            }
        }
        let report = ProbeReport(
            schema: "pw_vtprobe_v1",
            device: deviceModel(),
            systemVersion: UIDevice.current.systemVersion,
            thermalStateStart: thermal0,
            thermalStateEnd: thermalName(),
            configs: results
        )
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(report) {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("vtprobe-results.json")
            try? data.write(to: url, options: .atomic)
        }
        var lines = ["设备: \(deviceModel())  iOS \(UIDevice.current.systemVersion)", ""]
        for r in results {
            let mark = r.sessionCreated && r.framesFailed == 0 && r.framesEncoded == r.framesRequested ? "✅" : "❌"
            lines.append("\(mark) \(r.width)x\(r.height) gop\(r.gop): 建=\(r.sessionCreated ? "成" : "败(\(r.sessionStatus))") 帧=\(r.framesEncoded)/\(r.framesRequested) 均\(String(format: "%.1f", r.avgEncodeMs))ms 硬件=\(r.usingHardware.map { $0 ? "是" : "否" } ?? "未知")")
        }
        lines.append("")
        lines.append("结果已写入 Documents/vtprobe-results.json")
        return lines.joined(separator: "\n")
    }

    static func runConfig(width: Int, height: Int, level: String, gop: Int) async -> ConfigResult {
        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_HEVC, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        guard status == noErr, let s = session else {
            return ConfigResult(width: width, height: height, lumaSamples: width * height,
                                hevcLevelRequired: level, gop: gop, sessionCreated: false,
                                sessionStatus: status, usingHardware: nil, framesRequested: 0,
                                framesEncoded: 0, framesFailed: 0, totalOutputBytes: 0,
                                avgEncodeMs: 0, firstError: nil)
        }
        defer { VTCompressionSessionInvalidate(s) }

        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: gop))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: 30_000_000))
        VTSessionSetProperty(s, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: 3.33))

        var usingHW: Bool? = nil
        if #available(iOS 17.4, *) {
            var hwValue: CFTypeRef?
            if VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                     allocator: nil, valueOut: &hwValue) == noErr,
               let b = hwValue as? Bool { usingHW = b }
        }

        VTCompressionSessionPrepareToEncodeFrames(s)

        let frameCount = 9
        let counter = FrameCounter()
        var firstError: OSStatus?
        let t0 = CFAbsoluteTimeGetCurrent()
        for i in 0..<frameCount {
            guard let pb = makePixelBuffer(width: width, height: height, seed: i) else {
                firstError = firstError ?? -1
                continue
            }
            let pts = CMTime(value: CMTimeValue(i * 300), timescale: 1000)
            let st = VTCompressionSessionEncodeFrame(
                s, imageBuffer: pb, presentationTimeStamp: pts,
                duration: CMTime(value: 300, timescale: 1000),
                frameProperties: nil, infoFlagsOut: nil) { st2, _, sbuf in
                    if st2 == noErr, let sb = sbuf {
                        counter.record(bytes: CMSampleBufferGetTotalSampleSize(sb))
                    } else {
                        counter.recordFailure(status: st2)
                    }
                }
            if st != noErr { firstError = firstError ?? st; counter.recordFailure(status: st) }
        }
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0
        let (ok, fail, bytes, cbError) = counter.snapshot()
        return ConfigResult(width: width, height: height, lumaSamples: width * height,
                            hevcLevelRequired: level, gop: gop, sessionCreated: true,
                            sessionStatus: status, usingHardware: usingHW,
                            framesRequested: frameCount, framesEncoded: ok, framesFailed: fail,
                            totalOutputBytes: bytes,
                            avgEncodeMs: ok > 0 ? elapsed / Double(ok) : 0,
                            firstError: firstError ?? cbError)
    }

    static func makePixelBuffer(width: Int, height: Int, seed: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        guard CVPixelBufferCreate(nil, width, height,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  attrs as CFDictionary, &pb) == kCVReturnSuccess,
              let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        // 有结构的合成内容：梯度 + 帧间平移，保证 inter 有事可做、输出字节非平凡
        if let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let p = y.assumingMemoryBound(to: UInt8.self)
            for row in 0..<height {
                for col in 0..<width {
                    let v = (row &+ col &+ seed &* 17) & 0xFF
                    p[row * stride + col] = UInt8(truncatingIfNeeded: v)
                }
            }
        }
        if let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
            memset(uv, 128, stride * (height / 2))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    static func deviceModel() -> String {
        var info = utsname(); uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    static func thermalName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}

final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var ok = 0
    private var failed = 0
    private var bytes = 0
    private var firstError: OSStatus?

    func record(bytes b: Int) {
        lock.lock(); ok += 1; bytes += b; lock.unlock()
    }
    func recordFailure(status: OSStatus) {
        lock.lock(); failed += 1; if firstError == nil { firstError = status }; lock.unlock()
    }
    func snapshot() -> (Int, Int, Int, OSStatus?) {
        lock.lock(); defer { lock.unlock() }
        return (ok, failed, bytes, firstError)
    }
}
