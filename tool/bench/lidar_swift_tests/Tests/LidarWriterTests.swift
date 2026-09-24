// LidarWriterTests.swift —— PwBenchLidarRecordingWriter 的 Mac 宿主单测。🔴 bench-only ruler。
//
// 源的三个深度测试(research @76b8d47 DeviceRecordingTests.swift:testDepthStreamsAndIndexAgree /
// testRecordingWithoutDepthDeclaresItAbsent / testProjectedByteCountIncludesTheDepthStreams)照同一判据
// 改写到本写器(步长 / 额外键 / 像素格式核实),再加:
//   · 写出来的录制**被回放装载器 DeviceRecordingLoader 读得懂**(写读同一套 Codable 的闭环);
//   · 深度缓冲带行填充(bytesPerRow > 宽×4)时仍紧致写出、值不串行;
//   · 像素格式不对 ⇒ 记 depth_dropped、不写文件、录制照样可装载;
//   · 子集导出:帧号保留、字节逐帧相同、深度硬链接、子集**不可回放**(装载器拒)。

import CoreVideo
import CryptoKit
import Foundation
import XCTest
@testable import LidarCore

final class LidarWriterTests: XCTestCase {
    private var dir: URL!
    private let format = DeviceRecordingCameraFormat(
        width: 64, height: 48, pixelFormat: "luma8_from_420f_full_range", nominalFPS: 60)
    private let t0: Int64 = 78_685_122_068_208

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("lidar-writer-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: helpers

    /// DepthFloat32 / OneComponent8 缓冲,**故意带行填充**(bytesPerRow = 紧致 + 64)。
    private func makeBuffer(w: Int, h: Int, format: OSType, bytesPerPixel: Int,
                            fill: (Int, Int) -> [UInt8]) -> CVPixelBuffer {
        let stride = w * bytesPerPixel + 64
        let raw = UnsafeMutableRawPointer.allocate(byteCount: stride * h, alignment: 64)
        raw.initializeMemory(as: UInt8.self, repeating: 0xEE, count: stride * h)   // 填充区是垃圾
        for y in 0..<h {
            for x in 0..<w {
                let px = fill(x, y)
                for b in 0..<bytesPerPixel {
                    raw.storeBytes(of: px[b], toByteOffset: y * stride + x * bytesPerPixel + b, as: UInt8.self)
                }
            }
        }
        var pb: CVPixelBuffer?
        let st = CVPixelBufferCreateWithBytes(
            nil, w, h, format, raw, stride,
            { _, base in base?.deallocate() }, nil, nil, &pb)
        XCTAssertEqual(st, kCVReturnSuccess)
        return pb!
    }

    private func depthBuffer(frame: Int) -> CVPixelBuffer {
        let base: Double = 1.0 + Double(frame) * 0.01
        return makeBuffer(w: 256, h: 192, format: kCVPixelFormatType_DepthFloat32,
                          bytesPerPixel: 4) { (x: Int, y: Int) -> [UInt8] in
            let dx: Double = Double(x) * 1e-3
            let dy: Double = Double(y) * 1e-5
            let v: Float = Float(base + dx + dy)
            let bits: UInt32 = v.bitPattern.littleEndian
            return withUnsafeBytes(of: bits) { Array($0) }
        }
    }

    private func confidenceBuffer() -> CVPixelBuffer {
        makeBuffer(w: 256, h: 192, format: kCVPixelFormatType_OneComponent8, bytesPerPixel: 1) { x, _ in
            [UInt8(x % 3)]
        }
    }

    private func luma(_ i: Int) -> Data {
        Data((0..<format.bytesPerFrame).map { UInt8(truncatingIfNeeded: $0 &+ i * 7) })
    }

    /// 30 帧 luma、每 6 帧一张深度、IMU 早于第一帧。返回 manifest。
    @discardableResult
    private func record(depth: Bool, depthFormatOK: Bool = true) throws -> DeviceRecordingManifest {
        let w = try PwBenchLidarRecordingWriter(directory: dir, recordingID: "test-lidar",
                                                format: format, depthStride: 6)
        for i in 0..<40 {
            w.appendIMU(timestampNanoseconds: t0 - 50_000_000 + Int64(i) * 10_000_000,
                        gyroscope: (0, 0, 0), acceleration: (0, 9.8, 0))
        }
        let K = PwBenchLidarIntrinsics(fx: 50, fy: 50, cx: 32, cy: 24)
        for i in 0..<30 {
            let t = t0 + Int64(i) * 16_666_667
            try w.recordIntrinsics(K, timestampSeconds: Double(t) / 1e9, exposureSeconds: 0.008,
                                   arkitTracking: i < 2 ? "limited_initializing" : "normal")
            let cam = w.appendLuma(luma(i), timestampNanoseconds: t)
            XCTAssertEqual(cam, i)
            w.appendARKitPose(timestampNanoseconds: t, tumRow: "\(Double(t) / 1e9) 0 0 0 0 0 0 1")
            if depth && i % w.depthStride == 0 {
                let d = depthFormatOK ? depthBuffer(frame: i) : confidenceBuffer()
                w.appendDepth(depthMap: d, confidenceMap: confidenceBuffer(), timestampNanoseconds: t,
                              cameraFrameIndex: cam, arFrameIndex: i, imageIntrinsics: K)
            }
        }
        return try w.finish()
    }

    private func sha(_ url: URL) throws -> String {
        PwBenchLidarRecordingWriter.hex(SHA256.hash(data: try Data(contentsOf: url)))
    }

    // MARK: tests

    /// 源 testDepthStreamsAndIndexAgree 的判据 + 本写器的额外键 + 回放装载器闭环。
    func testDepthStreamsIndexManifestAndReplayLoaderAgree() throws {
        let m = try record(depth: true)
        XCTAssertEqual(m.frameCount, 30)
        XCTAssertEqual(m.lossCount, 0)
        XCTAssertEqual(m.depthPresent, true)
        XCTAssertEqual(m.depthFrameCount, 5)
        XCTAssertEqual(m.depthDropped, 0)
        XCTAssertEqual(m.depthWidth, 256)
        XCTAssertEqual(m.depthHeight, 192)
        XCTAssertEqual(m.depthSource, "ARFrame.sceneDepth")
        XCTAssertEqual(m.depthConfidencePresent, true)

        let depthURL = dir.appendingPathComponent("depth.bin")
        let confURL = dir.appendingPathComponent("depth_conf.bin")
        // 紧致打包:行填充没有进文件。
        XCTAssertEqual(try Data(contentsOf: depthURL).count, 5 * 256 * 192 * 4)
        XCTAssertEqual(try Data(contentsOf: confURL).count, 5 * 256 * 192)
        for f in m.files {
            let url = dir.appendingPathComponent(f.relativePath)
            XCTAssertEqual(try sha(url), f.sha256, f.relativePath)
            XCTAssertEqual(Int64(try Data(contentsOf: url).count), f.byteCount, f.relativePath)
        }
        // 索引行:源的 8 个键 + W5 的额外键;t_ns 与相机帧精确相等;camera_frame 指向同一帧。
        let rows = try String(contentsOf: dir.appendingPathComponent("depth.pwvi"), encoding: .utf8)
            .split(separator: "\n").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
        XCTAssertEqual(rows.count, 5)
        for (n, r) in rows.enumerated() {
            let i = n * 6
            XCTAssertEqual(r["frame"] as? Int, n)
            XCTAssertEqual(r["offset"] as? Int, n * 256 * 192 * 4)
            XCTAssertEqual(r["len"] as? Int, 256 * 192 * 4)
            XCTAssertEqual(r["conf_offset"] as? Int, n * 256 * 192)
            XCTAssertEqual(r["conf_len"] as? Int, 256 * 192)
            XCTAssertEqual((r["t_ns"] as? NSNumber)?.int64Value, t0 + Int64(i) * 16_666_667)
            XCTAssertEqual(r["camera_frame"] as? Int, i)
            XCTAssertEqual(r["ar_frame"] as? Int, i)
            XCTAssertEqual(r["image_w"] as? Int, 64)
            let kd = r["k_depth"] as! [Double]
            XCTAssertEqual(kd[0], 50 * 256.0 / 64, accuracy: 1e-9)
            XCTAssertEqual(kd[2], (32 + 0.5) * 4 - 0.5, accuracy: 1e-9)
        }
        // 值没串行:第 2 张深度(帧 6)在 (x=10, y=7) 的值。
        let depth = try Data(contentsOf: depthURL)
        let at = (1 * 256 * 192 + 7 * 256 + 10) * 4
        let v = depth.subdata(in: at..<at + 4).withUnsafeBytes { Float(bitPattern: $0.load(as: UInt32.self)) }
        XCTAssertEqual(Double(v), 1.0 + 6 * 0.01 + 10 * 1e-3 + 7 * 1e-5, accuracy: 1e-6)
        let conf = try Data(contentsOf: confURL)
        XCTAssertEqual(conf[256 * 192 + 7 * 256 + 10], UInt8(10 % 3))

        // 回放装载器读得懂(写读同一套 Codable);arkit_tracking 这个额外键被忽略。
        let ds = try DeviceRecordingLoader().load(
            manifestURL: dir.appendingPathComponent(DeviceRecordingManifest.fileName))
        XCTAssertEqual(ds.cameraFrameCount, 30)
        XCTAssertEqual(ds.report.intrinsicsPaired, 30)
        XCTAssertEqual(ds.report.framesWithExposure, 30)
        XCTAssertEqual(ds.manifest.depthFrameCount, 5)
        let intrinsics = try String(contentsOf: dir.appendingPathComponent("intrinsics.jsonl"), encoding: .utf8)
        XCTAssertTrue(intrinsics.contains("\"arkit_tracking\":\"limited_initializing\""))
    }

    /// 源 testRecordingWithoutDepthDeclaresItAbsent。
    func testRecordingWithoutDepthDeclaresItAbsent() throws {
        let m = try record(depth: false)
        XCTAssertEqual(m.depthPresent, false)
        XCTAssertNil(m.depthWidth)
        XCTAssertNil(m.depthSource)
        XCTAssertEqual(m.depthDropped, 0)
        for p in ["depth.bin", "depth_conf.bin", "depth.pwvi"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(p).path), p)
        }
        XCTAssertFalse(m.files.contains { $0.role == .depthStream || $0.role == .depthIndex })
        _ = try DeviceRecordingLoader().load(
            manifestURL: dir.appendingPathComponent(DeviceRecordingManifest.fileName))
    }

    /// W4:像素格式不对 ⇒ 不写、计 depth_dropped,录制照样能装载。
    func testWrongDepthPixelFormatIsCountedNotWritten() throws {
        let m = try record(depth: true, depthFormatOK: false)
        XCTAssertEqual(m.depthPresent, false)
        XCTAssertEqual(m.depthDropped, 5)
        XCTAssertEqual(m.lossCount, 0, "尺子的损失不许作废录制")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("depth.bin").path))
        _ = try DeviceRecordingLoader().load(
            manifestURL: dir.appendingPathComponent(DeviceRecordingManifest.fileName))
    }

    /// 源 testProjectedByteCountIncludesTheDepthStreams,按步长计价(W3)。
    func testProjectedByteCountPricesDepthByStride() {
        let scoring = DeviceRecordingCameraFormat(
            width: 1920, height: 1440, pixelFormat: "luma8_from_420f_full_range", nominalFPS: 60)
        let luma = PwBenchLidarRecordingWriter.projectedByteCount(seconds: 30, format: scoring, depthStride: 0)
        XCTAssertEqual(luma, 1920 * 1440 * 60 * 30)
        XCTAssertEqual(PwBenchLidarRecordingWriter.depthBytesPerFrame, 245_760)
        let everyFrame = PwBenchLidarRecordingWriter.projectedByteCount(seconds: 30, format: scoring, depthStride: 1)
        XCTAssertEqual(everyFrame - luma, 1800 * 245_760)
        let stride6 = PwBenchLidarRecordingWriter.projectedByteCount(seconds: 30, format: scoring, depthStride: 6)
        XCTAssertEqual(stride6 - luma, 300 * 245_760)
        // 步长 6 时深度占总写入量:300×245760 / (1800×2764800) ≈ 1.48%
        XCTAssertLessThan(Double(stride6 - luma) / Double(luma), 0.015)
    }

    /// W9:子集导出 —— 帧号保留、字节逐帧相同、深度硬链接、子集不可回放。
    func testRulerSubsetExport() throws {
        try record(depth: true)
        let summary = try PwBenchLidarRecordingWriter.exportRulerSubset(recording: dir, minSpacingSeconds: 0.15)
        let sub = dir.appendingPathComponent("ruler_subset")
        // 深度帧在 0,6,12,18,24(间隔 0.1 s)⇒ 间隔 ≥ 0.15 s 取 0,12,24。
        XCTAssertEqual(summary["frames"] as? Int, 3)
        let idx = try String(contentsOf: sub.appendingPathComponent("frames.pwvi"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        XCTAssertEqual(idx.map { $0["frame"] as! Int }, [0, 12, 24])
        let subFrames = try Data(contentsOf: sub.appendingPathComponent("frames.bin"))
        XCTAssertEqual(subFrames.count, 3 * format.bytesPerFrame)
        for (n, i) in [0, 12, 24].enumerated() {
            XCTAssertEqual(subFrames.subdata(in: n * format.bytesPerFrame..<(n + 1) * format.bytesPerFrame),
                           luma(i), "帧 \(i)")
        }
        let cam = try String(contentsOf: sub.appendingPathComponent("camera_index.csv"), encoding: .utf8)
        XCTAssertTrue(cam.contains("\(t0 + 12 * 16_666_667),12"))
        XCTAssertTrue((summary["linked"] as! [String]).contains("depth.bin"))
        let a = try FileManager.default.attributesOfItem(atPath: sub.appendingPathComponent("depth.bin").path)
        XCTAssertEqual((a[.referenceCount] as? NSNumber)?.intValue, 2, "深度是硬链接,不占第二份空间")
        XCTAssertThrowsError(try DeviceRecordingLoader().load(
            manifestURL: sub.appendingPathComponent(DeviceRecordingManifest.fileName)),
            "子集不可回放(frames.pwvi 哈希对不上 manifest)")
    }
}
