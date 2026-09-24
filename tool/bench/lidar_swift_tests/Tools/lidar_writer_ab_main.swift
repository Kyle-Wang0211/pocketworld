// lidar_writer_ab —— 写器 A/B:「录深度会不会挤掉相机帧」在 Mac 宿主上量一遍(机理,不是手机的数)。
// 🔴 bench-only ruler。用法:lidar_writer_ab <工作目录> <每臂秒数>
//
// 每臂按 60 fps 实时节拍喂 1920×1440 luma(每帧一次 2.76 MB 拷贝,同 ARFrame 回调里的 copyLumaPlane),
// 深度臂再按步长喂 256×192 DepthFloat32 + OneComponent8(每次 copyTightly)。臂:
//   off        不录深度(基线)
//   s6_own     每 6 帧一张深度、深度自己的队列(台架默认,W2+W3)
//   s1_own     每帧一张深度、自己的队列
//   s1_shared  每帧一张深度、与相机帧共用 writeQueue(= 源 @76b8d47 的做法)
// 顺序 ABCDDCBA 抵消热/缓存漂移;每臂封口后删目录。报丢帧(queue_full)、背压峰值、帧写入耗时分位、
// 「回调」耗时(appendLuma + appendDepth 在调用线程上花的时间)。
// 🔴 Mac SSD ≠ iPhone NAND:这里的绝对数不外推到手机;手机上的数由录制页「扰动自测」量。
import CoreVideo
import Foundation
import QuartzCore

let argv = CommandLine.arguments
guard argv.count >= 3, let seconds = Double(argv[2]) else {
    FileHandle.standardError.write(Data("usage: lidar_writer_ab <work_dir> <seconds_per_arm>\n".utf8)); exit(2)
}
let work = URL(fileURLWithPath: argv[1], isDirectory: true)
let format = DeviceRecordingCameraFormat(width: 1920, height: 1440,
                                         pixelFormat: "luma8_from_420f_full_range", nominalFPS: 60)
let base = Data((0..<format.bytesPerFrame).map { UInt8(truncatingIfNeeded: $0) })

func buffer(_ f: OSType, _ bpp: Int) -> CVPixelBuffer {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, 256, 192, f, nil, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    memset(CVPixelBufferGetBaseAddress(pb!)!, 0x3F, CVPixelBufferGetBytesPerRow(pb!) * 192)
    CVPixelBufferUnlockBaseAddress(pb!, [])
    return pb!
}
let depthPB = buffer(kCVPixelFormatType_DepthFloat32, 4)
let confPB = buffer(kCVPixelFormatType_OneComponent8, 1)

func pct(_ xs: [Double], _ q: Double) -> Double {
    guard !xs.isEmpty else { return .nan }
    let s = xs.sorted(); return s[min(s.count - 1, Int((q * Double(s.count - 1)).rounded()))]
}

func runArm(_ name: String, stride: Int, shared: Bool) throws -> [String: Any] {
    let dir = work.appendingPathComponent("arm_\(name)_\(UUID().uuidString.prefix(6))")
    let w = try PwBenchLidarRecordingWriter(directory: dir, recordingID: name, format: format,
                                            depthStride: max(1, stride))
    w.depthUsesSharedFrameQueue = shared
    let K = PwBenchLidarIntrinsics(fx: 1280, fy: 1280, cx: 960, cy: 720)
    let n = Int(seconds * 60)
    let start = CACurrentMediaTime()
    var callbackMs: [Double] = []
    var late = 0
    for i in 0..<n {
        let due = start + Double(i) / 60.0
        let now = CACurrentMediaTime()
        if due > now { Thread.sleep(forTimeInterval: due - now) } else if now - due > 1.0 / 60 { late += 1 }
        let t = Int64((due * 1e9).rounded())
        let c0 = CACurrentMediaTime()
        try w.recordIntrinsics(K, timestampSeconds: Double(t) / 1e9, exposureSeconds: 0.008, arkitTracking: "normal")
        let copy = Data(base)                       // 回调里那一次 luma 拷贝
        let cam = w.appendLuma(copy, timestampNanoseconds: t)
        if stride > 0 && i % stride == 0 {
            w.appendDepth(depthMap: depthPB, confidenceMap: confPB, timestampNanoseconds: t,
                          cameraFrameIndex: cam, arFrameIndex: i, imageIntrinsics: K)
        }
        callbackMs.append((CACurrentMediaTime() - c0) * 1000)
    }
    let snap = w.timingSnapshot()
    let f0 = CACurrentMediaTime()
    let m = try w.finish()
    let finishMs = (CACurrentMediaTime() - f0) * 1000
    try? FileManager.default.removeItem(at: dir)
    return ["arm": name, "frames_offered": n, "frames_accepted": m.frameCount, "loss_count": m.lossCount,
            "loss_write_queue_full": m.lossWriteQueueFull ?? 0, "peak_in_flight": m.peakInFlight ?? 0,
            "frame_write_ms_p50": pct(snap.frameWriteMilliseconds, 0.5),
            "frame_write_ms_p99": pct(snap.frameWriteMilliseconds, 0.99),
            "frame_write_ms_max": snap.slowestFrameWriteMilliseconds,
            "callback_ms_p50": pct(callbackMs, 0.5), "callback_ms_p99": pct(callbackMs, 0.99),
            "depth_frames": m.depthFrameCount ?? 0, "depth_dropped": m.depthDropped ?? 0,
            "depth_peak_in_flight": snap.depthPeakInFlight, "slowest_depth_write_ms": snap.slowestDepthWriteMilliseconds,
            "pacing_late_frames": late, "finish_ms": finishMs]
}

try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
let arms: [(String, Int, Bool)] = [("off", 0, false), ("s6_own", 6, false), ("s1_own", 1, false),
                                   ("s1_shared", 1, true)]
var results: [[String: Any]] = []
for (name, stride, shared) in arms + arms.reversed() {
    let r = try runArm(name, stride: stride, shared: shared)
    results.append(r)
    print(String(decoding: try JSONSerialization.data(withJSONObject: r, options: [.sortedKeys]), as: UTF8.self))
}
let d = try JSONSerialization.data(withJSONObject: ["schema": "pw.bench.lidar-writer-ab/1",
                                                    "seconds_per_arm": seconds, "runs": results],
                                   options: [.prettyPrinted, .sortedKeys])
try d.write(to: work.appendingPathComponent("writer_ab.json"))
print("写出 \(work.appendingPathComponent("writer_ab.json").path)")
