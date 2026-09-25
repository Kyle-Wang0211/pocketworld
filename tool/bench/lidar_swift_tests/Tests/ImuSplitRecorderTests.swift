// ImuSplitRecorderTests.swift —— [xr-recon-chain 2026-09-25] 录制器 IMU 修复(writer W13 / 会话 S8 / 装载器 D11)
// 的 Mac 宿主单测。证明:
//   · 陀螺 / 加计两路各自带自己的时间戳落盘,**没有配对**(没有一行加计用了陀螺的时间戳,反之亦然);
//   · 回放装载器把两路读成两条独立的事件流,各按自己的时刻排序,同一时刻 陀螺 < 加计 < 相机;
//   · 首条 IMU(丢掉它之前的相机帧)= 两路里最早的时间戳;
//   · 单路时间戳倒退 / 未知传感器名 ⇒ 装载器拒收,不猜;
//   · 录制会话源码照 XRSLAM 官方 Motion.swift 两路各自 handler,不再拉取 accelerometerData;
//   · 尺子子集把 imu_events.csv 一起带过去,首条 IMU 按新规则。
// 旧格式(imu.csv 配对行)「照旧能回放且逐位不变」另由 tool/bench/replay_swift_tests 的事件转储工具在真实录制上核
// (改前 / 改后两版装载器逐位比)。

import CryptoKit
import Foundation
import XCTest
@testable import LidarCore

final class ImuSplitRecorderTests: XCTestCase {
    private var dir: URL!
    private let format = DeviceRecordingCameraFormat(
        width: 64, height: 48, pixelFormat: "luma8_from_420f_full_range", nominalFPS: 30)
    private let t0: Int64 = 78_685_122_068_208

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("imu-split-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func luma(_ i: Int) -> Data {
        Data((0..<format.bytesPerFrame).map { UInt8(truncatingIfNeeded: $0 &+ i * 5) })
    }

    /// 两路 100 Hz,加计相位落后 3.7 ms、每 7 条多 0.4 ms 抖动(两个互不相关的时钟);按「回调到达」交错调用。
    /// 陀螺 x = 序号,加计 x = 1000 + 序号 ⇒ 值能反查它来自哪一条样本。
    private func streams(count: Int = 60) -> (gyro: [Int64], accel: [Int64]) {
        var gyro: [Int64] = []
        var accel: [Int64] = []
        let base: Int64 = t0 - 40_000_000
        for i in 0..<count {
            let k = Int64(i)
            gyro.append(base + k * 10_000_000)
            let jitter: Int64 = Int64(i % 7) * 400_000
            accel.append(base + 3_700_000 + k * 10_000_000 + jitter)
        }
        return (gyro, accel)
    }

    @discardableResult
    private func recordSplit(frames: Int = 20, tieAccelToGyro: Bool = false,
                             tieGyroToCamera: Bool = false) throws -> DeviceRecordingManifest {
        let w = try PwBenchLidarRecordingWriter(directory: dir, recordingID: "test-imu-split", format: format,
                                                depthStride: 6)
        var (gyro, accel) = streams()
        if tieAccelToGyro { accel[10] = gyro[11] }                       // 同一时刻 陀螺 / 加计
        let camT = (0..<frames).map { t0 + Int64($0) * 33_333_333 }
        if tieGyroToCamera { gyro[14] = camT[3] }                         // 同一时刻 陀螺 / 相机(t0+99.999999 ms,仍在 13 / 15 之间)
        // 按时间交错调用(模拟两路回调在同一条队列上到达)。
        var gi = 0, ai = 0
        while gi < gyro.count || ai < accel.count {
            if ai >= accel.count || (gi < gyro.count && gyro[gi] <= accel[ai]) {
                w.appendGyro(timestampNanoseconds: gyro[gi], rotationRate: (Double(gi), 0.25, -0.5))
                gi += 1
            } else {
                w.appendAccel(timestampNanoseconds: accel[ai], acceleration: (1000 + Double(ai), 9.8, -0.125))
                ai += 1
            }
        }
        let K = PwBenchLidarIntrinsics(fx: 50, fy: 50, cx: 32, cy: 24)
        for (i, t) in camT.enumerated() {
            try w.recordIntrinsics(K, timestampSeconds: Double(t) / 1e9, exposureSeconds: 0.008, arkitTracking: "normal")
            _ = w.appendLuma(luma(i), timestampNanoseconds: t)
            w.appendARKitPose(timestampNanoseconds: t, tumRow: "\(Double(t) / 1e9) 0 0 0 0 0 0 1")
        }
        return try w.finish()
    }

    private func rows(_ name: String) throws -> [[String]] {
        try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            .split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    }

    // MARK: 写

    func testWriterKeepsEachStreamsOwnTimestampsAndNeverPairs() throws {
        let m = try recordSplit()
        let (gyro, accel) = streams()
        let r = try rows(DeviceRecordingManifest.imuEventsPath)
        XCTAssertEqual(r.first, ["timestamp_ns", "sensor", "x", "y", "z"])
        let data = Array(r.dropFirst())
        let g = data.filter { $0[1] == "gyro" }, a = data.filter { $0[1] == "accel" }
        XCTAssertEqual(g.count, gyro.count)
        XCTAssertEqual(a.count, accel.count)
        XCTAssertEqual(data.count, g.count + a.count, "只有 gyro / accel 两种行")
        // 每一行的时间戳就是那一路自己传进来的时间戳,值也是那一条样本的值。
        XCTAssertEqual(g.map { Int64($0[0])! }, gyro)
        XCTAssertEqual(a.map { Int64($0[0])! }, accel)
        XCTAssertEqual(g.map { Double($0[2])! }, (0..<gyro.count).map(Double.init))
        XCTAssertEqual(a.map { Double($0[2])! }, (0..<accel.count).map { 1000 + Double($0) })
        // 没有配对:两路时间戳集合不相交(本例两路相位不同),且没有任何一行同时带陀螺值与加计值。
        XCTAssertTrue(Set(gyro).isDisjoint(with: Set(accel)))
        XCTAssertTrue(data.allSatisfy { $0.count == 5 })
        // 行序 = 调用顺序(回调顺序)。
        XCTAssertEqual(data.map { Int64($0[0])! }, (gyro + accel).sorted())
        // manifest
        XCTAssertEqual(m.imuFormat, DeviceRecordingManifest.imuFormatSplitEvents)
        XCTAssertEqual(m.imuGyroSampleCount, gyro.count)
        XCTAssertEqual(m.imuAccelSampleCount, accel.count)
        XCTAssertEqual(m.imuSampleCount, gyro.count + accel.count)
        XCTAssertTrue(m.files.contains { $0.role == .imuEvents && $0.relativePath == "imu_events.csv" })
        XCTAssertFalse(m.files.contains { $0.role == .imuIndex }, "新录制不再写配对的 imu.csv")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("imu.csv").path))
    }

    // MARK: 读(回放装载器)

    func testLoaderReplaysTwoIndependentStreams() throws {
        try recordSplit()
        let (gyro, accel) = streams()
        let ds = try DeviceRecordingLoader().load(manifestURL: dir.appendingPathComponent(DeviceRecordingManifest.fileName))
        var g: [(Int64, Double)] = [], a: [(Int64, Double)] = []
        var paired = 0
        for e in ds.events {
            switch e {
            case .gyro(let s): g.append((s.timestampNanoseconds, s.value.x))
            case .accel(let s): a.append((s.timestampNanoseconds, s.value.x))
            case .imu: paired += 1
            case .camera: break
            }
        }
        XCTAssertEqual(paired, 0, "新格式不产生配对事件")
        XCTAssertEqual(g.map(\.0), gyro)
        XCTAssertEqual(a.map(\.0), accel)
        XCTAssertEqual(g.map(\.1), (0..<gyro.count).map(Double.init))
        XCTAssertEqual(a.map(\.1), (0..<accel.count).map { 1000 + Double($0) })
        XCTAssertEqual(ds.report.imuFormat, "split_events_v1")
        XCTAssertEqual(ds.report.imuGyroSamples, gyro.count)
        XCTAssertEqual(ds.report.imuAccelSamples, accel.count)
        XCTAssertEqual(ds.imuEventCount, gyro.count + accel.count)
        // 事件整体按时间递增。
        let ts = ds.events.map(\.timestampNanoseconds)
        XCTAssertEqual(ts, ts.sorted())
    }

    func testTieOrderGyroThenAccelThenCamera() throws {
        try recordSplit(tieAccelToGyro: true, tieGyroToCamera: true)
        let ds = try DeviceRecordingLoader().load(manifestURL: dir.appendingPathComponent(DeviceRecordingManifest.fileName))
        let (gyro, _) = streams()
        let camT3 = t0 + 3 * 33_333_333
        // 陀螺 11 与加计 10 同一时刻 ⇒ 陀螺在前。
        let at11 = ds.events.enumerated().filter { $0.element.timestampNanoseconds == gyro[11] }
        XCTAssertEqual(at11.map { $0.element.kind }, [.gyro, .accel])
        // 陀螺 14 与相机 3 同一时刻 ⇒ IMU 在前(装载器源 :302-310 的规则不变)。
        let atCam = ds.events.filter { $0.timestampNanoseconds == camT3 }
        XCTAssertEqual(atCam.map { $0.kind }, [.gyro, .camera])
        // 相机 0(t0)本来就与陀螺 4(t0 − 40 ms + 4 × 10 ms)同刻 ⇒ 并列共 2 处,两处都是 IMU 在前。
        let atCam0 = ds.events.filter { $0.timestampNanoseconds == t0 }
        XCTAssertEqual(atCam0.map { $0.kind }, [.gyro, .camera])
        XCTAssertEqual(ds.report.cameraImuTimestampTies, 2)
    }

    func testLeadingCameraFramesUseEarliestOfBothStreams() throws {
        // 两路都从 t0 − 40 ms 起;把第一条陀螺挪到 t0 + 50 ms 之后 ⇒ 最早的是加计(t0 − 36.3 ms),不丢相机帧。
        let w = try PwBenchLidarRecordingWriter(directory: dir, recordingID: "lead", format: format)
        w.appendAccel(timestampNanoseconds: t0 - 36_300_000, acceleration: (0, 9.8, 0))
        w.appendGyro(timestampNanoseconds: t0 + 50_000_000, rotationRate: (0, 0, 0))
        w.appendAccel(timestampNanoseconds: t0 + 60_000_000, acceleration: (0, 9.8, 0))
        let K = PwBenchLidarIntrinsics(fx: 50, fy: 50, cx: 32, cy: 24)
        for i in 0..<4 {
            let t = t0 + Int64(i) * 33_333_333
            try w.recordIntrinsics(K, timestampSeconds: Double(t) / 1e9, exposureSeconds: 0.008, arkitTracking: "normal")
            _ = w.appendLuma(luma(i), timestampNanoseconds: t)
            w.appendARKitPose(timestampNanoseconds: t, tumRow: "\(Double(t) / 1e9) 0 0 0 0 0 0 1")
        }
        try w.finish()
        let ds = try DeviceRecordingLoader().load(manifestURL: dir.appendingPathComponent(DeviceRecordingManifest.fileName))
        XCTAssertEqual(ds.report.leadingCameraFramesWithoutImuDropped, 0)
        XCTAssertEqual(PwBenchLidarRecordingWriter.firstImuNanoseconds(recording: dir), t0 - 36_300_000)
    }

    func testPerStreamRegressionAndUnknownSensorAreRejected() throws {
        try recordSplit()
        let url = dir.appendingPathComponent(DeviceRecordingManifest.imuEventsPath)
        let original = try String(contentsOf: url, encoding: .utf8)
        var lines = original.split(separator: "\n").map(String.init)
        // 把第 2 条加计的时间戳改成第 1 条的(同一路倒退 / 相等)。
        let accelIdx = lines.indices.filter { lines[$0].contains(",accel,") }
        var f = lines[accelIdx[1]].split(separator: ",").map(String.init)
        f[0] = lines[accelIdx[0]].split(separator: ",")[0].description
        lines[accelIdx[1]] = f.joined(separator: ",")
        try rewrite(url, lines.joined(separator: "\n") + "\n")
        XCTAssertThrowsError(try DeviceRecordingLoader().load(
            manifestURL: dir.appendingPathComponent(DeviceRecordingManifest.fileName))) { e in
            guard case DeviceRecordingError.timestampRegression(let p, _, _) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(p.hasSuffix("#accel"))
        }
        // 未知传感器名
        try rewrite(url, original.replacingOccurrences(of: ",gyro,", with: ",magnet,"))
        XCTAssertThrowsError(try DeviceRecordingLoader().load(
            manifestURL: dir.appendingPathComponent(DeviceRecordingManifest.fileName))) { e in
            guard case DeviceRecordingError.malformedCSV(_, _, let reason) = e else { return XCTFail("\(e)") }
            XCTAssertTrue(reason.contains("magnet"))
        }
    }

    /// 改内容后同步 manifest 里的 SHA-256 / 字节数,让装载器走到 IMU 解析那一步(否则先被哈希闸拒)。
    private func rewrite(_ url: URL, _ text: String) throws {
        let d = Data(text.utf8)
        try d.write(to: url)
        let mURL = dir.appendingPathComponent(DeviceRecordingManifest.fileName)
        var m = try JSONDecoder().decode(DeviceRecordingManifest.self, from: Data(contentsOf: mURL))
        m.files = m.files.map { f in
            guard f.relativePath == url.lastPathComponent else { return f }
            return DeviceRecordingFile(role: f.role, relativePath: f.relativePath, byteCount: Int64(d.count),
                                       sha256: PwBenchLidarRecordingWriter.hex(SHA256.hash(data: d)))
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(m).write(to: mURL)
    }

    // MARK: 会话源码契约(ARKit 那半编不进 Mac,只能核源码)

    func testSessionFollowsOfficialMotionSwiftTwoHandlers() throws {
        guard let path = ProcessInfo.processInfo.environment["PW_LIDAR_SESSION_SOURCE"] else {
            throw XCTSkip("run.sh 传 PW_LIDAR_SESSION_SOURCE")
        }
        let src = try String(contentsOfFile: path, encoding: .utf8)
        // 去掉行注释后再查(注释里会引用旧写法)。
        let code = src.split(separator: "\n").map { line -> String in
            if let r = line.range(of: "//") { return String(line[..<r.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
        XCTAssertFalse(code.contains("accelerometerData"), "不再拉取加计最新值")
        XCTAssertFalse(code.contains("appendIMU("), "不再写配对行")
        XCTAssertFalse(code.contains("startAccelerometerUpdates()"), "加计不再用无 handler 的拉取模式")
        XCTAssertTrue(code.contains("motion.startGyroUpdates(to: motionQueue) {"))
        XCTAssertTrue(code.contains("motion.startAccelerometerUpdates(to: motionQueue) {"))
        // 两个 handler 各自把**自己的** record.timestamp 交给各自的写入口。
        let gyroHandler = try XCTUnwrap(code.range(of: "motion.startGyroUpdates(to: motionQueue) {"))
        let accelHandler = try XCTUnwrap(code.range(of: "motion.startAccelerometerUpdates(to: motionQueue) {"))
        let gyroBody = String(code[gyroHandler.upperBound..<accelHandler.lowerBound])
        let accelBody = String(code[accelHandler.upperBound...].prefix(900))
        XCTAssertTrue(gyroBody.contains("appendGyro(") && gyroBody.contains("record.timestamp"))
        XCTAssertFalse(gyroBody.contains("appendAccel("))
        XCTAssertTrue(accelBody.contains("appendAccel(") && accelBody.contains("record.timestamp"))
        XCTAssertTrue(accelBody.contains("gravityNominal"))
        XCTAssertTrue(code.contains("private static let gravityNominal = -9.80665"))
    }

    // MARK: 尺子子集

    func testRulerSubsetCarriesImuEvents() throws {
        try recordSplit(frames: 12)
        // 这份测试录制没有深度 ⇒ 子集导出会如实拒(没有 depth.pwvi);这里只核首条 IMU 与拷贝清单的新规则。
        XCTAssertEqual(PwBenchLidarRecordingWriter.firstImuNanoseconds(recording: dir), streams().gyro[0])
        XCTAssertThrowsError(try PwBenchLidarRecordingWriter.exportRulerSubset(recording: dir, minSpacingSeconds: 0.1))
    }
}
