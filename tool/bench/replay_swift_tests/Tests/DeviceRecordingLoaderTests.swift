// 装载器单测。
//
// 源 BasaltVIOBench `BasaltVIOBenchTests/ReplayTests/DeviceRecordingTests.swift` 用它自己的
// DeviceRecordingWriter(带 HEVC 编码器)造夹具;台架没有搬 writer,所以这里用一个
// **按录制器落盘格式**直接写文件的小夹具(`Fixture`,格式出处见它的注释)。
// 与源一一对应的用例在名字后面标 [port 源:行];台架新增 / 改了口径的标 [D#]
// (D# 与 ios/Runner/PwBenchReplayRecording.swift 文件头的偏离编号一致)。
import CryptoKit
import XCTest
@testable import BenchReplayCore

final class DeviceRecordingLoaderTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: 往返与顺序

    /// [port DeviceRecordingTests.swift:85-163] 帧、IMU、顺序与像素都原样回来;
    /// 并列时间戳 IMU 在前。
    func testRoundTripPreservesFramesAndOrdering() throws {
        var fx = Fixture(width: 8, height: 6)
        for i in 0..<3 { fx.addFrame(t: Int64(i) * 33_333_333, fill: UInt8(i + 1)) }
        for i in 0..<6 { fx.addIMU(t: Int64(i) * 10_000_000) }
        try fx.write(to: root)

        let ds = try load(verifyDigest: true)
        XCTAssertEqual(ds.recordingID, "fixture")
        XCTAssertEqual(ds.inputCameraCount, 1)
        XCTAssertEqual(ds.events.count, 9)
        var previous: Int64 = .min
        for e in ds.events {
            XCTAssertGreaterThanOrEqual(e.timestampNanoseconds, previous)
            previous = e.timestampNanoseconds
        }
        XCTAssertEqual(ds.events.first?.kind, .imu, "t=0 并列:IMU 必须在相机前")
        XCTAssertTrue(ds.report.framesDigestVerified)

        let reader = try FrameStreamReader(url: ds.streamURL)
        let cams = ds.events.compactMap { e -> DeviceRecordingCameraFrame? in
            if case .camera(let f) = e { return f } else { return nil }
        }
        XCTAssertEqual(cams.count, 3)
        for (i, f) in cams.enumerated() {
            let bytes = try reader.read(f.byteRange)
            XCTAssertEqual(bytes.count, 48)
            XCTAssertEqual(Set(bytes), [UInt8(i + 1)])
        }
    }

    /// [port DeviceRecordingTests.swift:165-176]
    func testRecordedEventsDriveTheSharedScheduler() throws {
        try Fixture.minimal().write(to: root)
        let ds = try load()
        var delivered: [ReplayEvent.Kind] = []
        try ReplayScheduler(mode: .maximumThroughput).run(events: ds.events) {
            delivered.append($0.kind)
        }
        XCTAssertEqual(delivered.count, ds.events.count)
    }

    // MARK: 拒绝

    /// [port DeviceRecordingTests.swift:178-183]
    func testLossyRecordingIsRefused() throws {
        var fx = Fixture.minimal(); fx.lossCount = 1
        try fx.write(to: root)
        XCTAssertThrowsError(try load()) { error in
            XCTAssertEqual(error as? DeviceRecordingError, .lossyRecording(lossCount: 1))
        }
    }

    /// [D5] 显式放行后照装,loss 原样带出。
    func testLossyRecordingLoadsWhenAllowedAndIsFlagged() throws {
        var fx = Fixture.minimal(); fx.lossCount = 95
        try fx.write(to: root)
        let ds = try load(allowLossy: true)
        XCTAssertEqual(ds.report.lossCount, 95)
    }

    /// [D4] 源 :185-198 拒 640×480;台架照收并如实标。
    func testNonVerdictResolutionIsFlaggedNotRefused() throws {
        try Fixture.minimal().write(to: root)   // 8×6
        let ds = try load()
        XCTAssertFalse(ds.report.verdictResolution)
        XCTAssertEqual(ds.camera.width, 8)
    }

    func testVerdictResolutionIsRecognised() throws {
        var fx = Fixture(width: 1920, height: 1440)
        fx.addFrame(t: 0, fill: 3)
        fx.addIMU(t: 0)
        try fx.write(to: root)
        XCTAssertTrue(try load().report.verdictResolution)
    }

    /// [port DeviceRecordingTests.swift:200-213]
    func testFailedIntrinsicsCrossCheckIsRefused() throws {
        var fx = Fixture.minimal(); fx.crossCheckPassed = false
        try fx.write(to: root)
        XCTAssertThrowsError(try load()) { error in
            XCTAssertEqual(error as? DeviceRecordingError, .intrinsicsCrossCheckFailed)
        }
    }

    /// [port DeviceRecordingTests.swift:215-234] 截断由边界检查接住,不用哈希。
    func testTruncatedFrameIsRefusedWithoutDigestVerification() throws {
        try Fixture.minimal().write(to: root)
        try Data(count: 5).write(to: root.appendingPathComponent("frames.bin"))
        XCTAssertThrowsError(try load(verifyDigest: false)) { error in
            guard case .frameSizeMismatch = error as? DeviceRecordingError else {
                return XCTFail("expected frameSizeMismatch, got \(error)")
            }
        }
    }

    /// [port DeviceRecordingTests.swift:236-258] 同长度的原地损坏只有摘要看得见。
    func testCorruptedFrameIsCaughtByTheDigest() throws {
        try Fixture.minimal().write(to: root)
        let stream = root.appendingPathComponent("frames.bin")
        var bytes = try Data(contentsOf: stream)
        bytes[0] = bytes[0] &+ 1
        try bytes.write(to: stream)
        XCTAssertNoThrow(try load(verifyDigest: false))
        XCTAssertThrowsError(try load(verifyDigest: true)) { error in
            guard case .framesDigestMismatch = error as? DeviceRecordingError else {
                return XCTFail("expected framesDigestMismatch, got \(error)")
            }
        }
    }

    /// [port DeviceRecordingLoader.swift:345-375] 索引文件被改 ⇒ 哈希不对 ⇒ 拒。
    func testIndexFileHashMismatchIsRefused() throws {
        try Fixture.minimal().write(to: root)
        let imu = root.appendingPathComponent("imu.csv")
        try (String(contentsOf: imu, encoding: .utf8) + "\n").write(to: imu, atomically: true,
                                                                   encoding: .utf8)
        XCTAssertThrowsError(try load()) { error in
            guard case .fileHashMismatch(let p, _, _) = error as? DeviceRecordingError else {
                return XCTFail("expected fileHashMismatch, got \(error)")
            }
            XCTAssertEqual(p, "imu.csv")
        }
    }

    // MARK: 旧录制的格式差异

    /// [D2] run-5966aec0 的 frames.pwvi 是 `{"frame","offset","length"}`,没有 keyframe。
    func testLengthKeyAndMissingKeyframeAreAccepted() throws {
        var fx = Fixture.minimal(); fx.indexStyle = .length5966
        try fx.write(to: root)
        XCTAssertEqual(try load().cameraFrameCount, 1)
    }

    /// [D3] run-5966aec0 的 manifest 没有 late_frames_after_seal。
    func testManifestWithoutLaterAddedKeysStillDecodes() throws {
        var fx = Fixture.minimal(); fx.omitLaterManifestKeys = true
        try fx.write(to: root)
        XCTAssertNoThrow(try load())
    }

    /// [D1] 不是整帧 raw 平面的条目(编码过的访问单元)⇒ 拒,不跳过。
    func testEncodedAccessUnitIsRefused() throws {
        var fx = Fixture.minimal(); fx.truncateFrameEntryTo = 7
        try fx.write(to: root)
        XCTAssertThrowsError(try load()) { error in
            guard case .encodedFrameNotSupported = error as? DeviceRecordingError else {
                return XCTFail("expected encodedFrameNotSupported, got \(error)")
            }
        }
    }

    // MARK: D7 逐帧 K / 曝光配对

    /// 最近邻、1 ms 含、并列取前一个、超 1 ms 配不上 —— 逐条对照 pwvi_to_euroc.py:141-152。
    func testIntrinsicsPairingRules() throws {
        let frames = [0, 1_000_000_000, 2_000_000_000, 3_000_000_000].enumerated().map {
            DeviceRecordingCameraFrame(timestampNanoseconds: Int64($0.element), frameIndex: $0.offset,
                                       byteRange: 0..<1, intrinsicsFxFyCxCy: nil,
                                       exposureSeconds: nil)
        }
        func row(_ t: Int64, _ fx: Double, _ e: Double? = nil) -> DeviceRecordingLoader.IntrinsicsRow {
            .init(keyNanoseconds: t, fxfycxcy: [fx, fx, 1, 1], exposureSeconds: e)
        }
        let rows = [
            row(0, 100, 0.01),                  // 帧 0:正好
            row(1_000_000_000 - 400_000, 201),  // 帧 1:-0.4 ms
            row(1_000_000_000 + 300_000, 202),  // 帧 1:+0.3 ms(更近 ⇒ 胜)
            row(2_000_000_000 - 500_000, 301),  // 帧 2:-0.5 ms
            row(2_000_000_000 + 500_000, 302),  // 帧 2:+0.5 ms(并列 ⇒ 取前一个 301)
            row(3_000_000_000 + 1_000_001, 400) // 帧 3:+1.000001 ms ⇒ 配不上
        ]
        let (out, paired) = DeviceRecordingLoader.pairIntrinsics(rows: rows.shuffled(),
                                                                 frames: frames)
        XCTAssertEqual(paired, 3)
        XCTAssertEqual(out[0].intrinsicsFxFyCxCy?.first, 100)
        XCTAssertEqual(out[0].exposureSeconds, 0.01)
        XCTAssertEqual(out[1].intrinsicsFxFyCxCy?.first, 202)
        XCTAssertEqual(out[2].intrinsicsFxFyCxCy?.first, 301)
        XCTAssertNil(out[3].intrinsicsFxFyCxCy)
        XCTAssertNil(out[3].exposureSeconds)
    }

    /// 键 = round(t·1e9) 用四舍六入五成双(Python round)。
    func testIntrinsicsKeyUsesPythonRounding() throws {
        var fx = Fixture.minimal()
        fx.intrinsicsJSONL = """
        {"t":0.0000000025,"intrinsics_fxfycxcy":[1,1,1,1]}
        {"t":0.0000000035,"intrinsics_fxfycxcy":[2,2,2,2],"exposure_s":0.02}
        """
        try fx.write(to: root)
        let rows = try DeviceRecordingLoader().parseIntrinsicsIndex(
            url: root.appendingPathComponent("intrinsics.jsonl"))
        // 2.5 → 2,3.5 → 4(Python `round`);0.0000000025·1e9 在二进制里不恰是 2.5,
        // 这里只钉「与 Python 同一个数」,数值由 Python 预先算好:
        //   python3 -c "print(int(round(float('0.0000000025')*1e9)), int(round(float('0.0000000035')*1e9)))"
        //   ⇒ 2 4
        XCTAssertEqual(rows.map(\.keyNanoseconds), [2, 4])
        XCTAssertEqual(rows[1].exposureSeconds, 0.02)
        XCTAssertNil(rows[0].exposureSeconds)
    }

    /// 配对率 < 99% ⇒ 拒(pwvi_to_euroc.py:155-156;euroc_runner.cpp:234-241)。
    func testIntrinsicsPairingBelow99PercentIsRefused() throws {
        var fx = Fixture(width: 4, height: 2)
        for i in 0..<10 { fx.addFrame(t: Int64(i) * 16_000_000, fill: 1) }
        fx.addIMU(t: 0)
        fx.intrinsicsJSONL = (0..<9).map {
            "{\"t\":\(Double($0) * 0.016),\"intrinsics_fxfycxcy\":[5,5,2,1]}"
        }.joined(separator: "\n")
        try fx.write(to: root)
        XCTAssertThrowsError(try load()) { error in
            XCTAssertEqual(error as? DeviceRecordingError,
                           .intrinsicsPairingRate(paired: 9, total: 10))
        }
    }

    func testPairedIntrinsicsAndExposureRideOnTheFrames() throws {
        var fx = Fixture(width: 4, height: 2)
        for i in 0..<3 { fx.addFrame(t: 1_000_000_000 + Int64(i) * 16_666_667, fill: 1) }
        fx.addIMU(t: 900_000_000)
        fx.intrinsicsJSONL = """
        {"t":1.0,"intrinsics_fxfycxcy":[1279.01953125,1279.01953125,957.751708984375,719.0894775390625],"exposure_s":0.008547008547008548}
        {"t":1.016666667,"intrinsics_fxfycxcy":[1278.855712890625,1278.855712890625,957.78125,719.0957641601562]}
        {"t":1.033333334,"intrinsics_fxfycxcy":[1,2,3,4],"exposure_s":0.009}
        """
        try fx.write(to: root)
        let ds = try load()
        let cams = ds.events.compactMap { e -> DeviceRecordingCameraFrame? in
            if case .camera(let f) = e { return f } else { return nil }
        }
        XCTAssertEqual(cams.map { $0.intrinsicsFxFyCxCy?[2] },
                       [957.751708984375, 957.78125, 3])
        XCTAssertEqual(cams.map(\.exposureSeconds), [0.008547008547008548, nil, 0.009])
        XCTAssertEqual(ds.report.intrinsicsPaired, 3)
        XCTAssertEqual(ds.report.framesWithExposure, 2)
    }

    // MARK: D8 / D9 / D10

    /// [port DeviceRecordingLoader.swift:312-332] 第一条 IMU 之前的相机帧丢掉并计数。
    func testLeadingCameraFramesWithoutImuAreDropped() throws {
        var fx = Fixture(width: 4, height: 2)
        for i in 0..<5 { fx.addFrame(t: Int64(i) * 10, fill: 1) }
        fx.addIMU(t: 25)
        try fx.write(to: root)
        let ds = try load()
        XCTAssertEqual(ds.cameraFrameCount, 2)                       // t = 30, 40
        XCTAssertEqual(ds.report.leadingCameraFramesWithoutImuDropped, 3)
    }

    /// [D8] 先截前 N 行相机,再丢无 IMU 的开头帧;IMU 全留。
    func testLimitFramesKeepsPrefixAndAllImu() throws {
        var fx = Fixture(width: 4, height: 2)
        for i in 0..<10 { fx.addFrame(t: Int64(i) * 10, fill: 1) }
        for i in 0..<20 { fx.addIMU(t: 5 + Int64(i) * 5) }
        try fx.write(to: root)
        let ds = try load(limit: 4)
        XCTAssertEqual(ds.report.cameraRowsTotal, 10)
        XCTAssertEqual(ds.report.cameraRowsAfterLimit, 4)
        XCTAssertEqual(ds.cameraFrameCount, 3)   // t=0 在第一条 IMU(5)之前被丢
        XCTAssertEqual(ds.imuEventCount, 20)
    }

    /// [D9] 并列次数照实计;并列时 IMU 在前(源规则)。
    func testCameraImuTiesAreCounted() throws {
        var fx = Fixture(width: 4, height: 2)
        fx.addIMU(t: 0)
        fx.addFrame(t: 10, fill: 1); fx.addIMU(t: 10)
        fx.addFrame(t: 20, fill: 1); fx.addIMU(t: 21)
        try fx.write(to: root)
        let ds = try load()
        XCTAssertEqual(ds.report.cameraImuTimestampTies, 1)
        XCTAssertEqual(ds.events.map(\.kind), [.imu, .imu, .camera, .camera, .imu])
    }

    // MARK: 读帧进缓冲(stride 陷阱的反方向)

    /// 目标行宽 > 帧宽(CVPixelBuffer 行填充)时逐行读,不把 stride 烤进像素
    /// (源 DeviceRecordingTests.swift:21-25 说的那个陷阱)。
    func testReadIntoPaddedDestinationCopiesRowByRow() throws {
        let url = root.appendingPathComponent("s.bin")
        let plane: [UInt8] = (0..<12).map(UInt8.init)   // 4×3
        try Data([9, 9] + plane).write(to: url)
        let reader = try FrameStreamReader(url: url)
        var dst = [UInt8](repeating: 0xAA, count: 6 * 3)
        try dst.withUnsafeMutableBytes { p in
            try reader.read(2..<14, into: p.baseAddress!, rowBytes: 4, rows: 3,
                            destinationStride: 6)
        }
        XCTAssertEqual(dst, [0, 1, 2, 3, 0xAA, 0xAA,
                             4, 5, 6, 7, 0xAA, 0xAA,
                             8, 9, 10, 11, 0xAA, 0xAA])
    }

    // MARK: 帮手

    private func load(verifyDigest: Bool = false, allowLossy: Bool = false,
                      limit: Int = 0) throws -> DeviceRecordingDataset {
        var o = DeviceRecordingLoadOptions()
        o.verifyFramesDigest = verifyDigest
        o.allowLossy = allowLossy
        o.limitFrames = limit
        return try DeviceRecordingLoader(options: o)
            .load(manifestURL: root.appendingPathComponent("recording_manifest.json"))
    }
}

/// 按 BasaltVIOBench 录制器的落盘格式直接写一份录制。格式出处:
///   frames.bin / frames.pwvi   DeviceRecordingTypes.swift:228-236(一条流 + JSONL 索引,
///                              行 `{"frame","offset","len","keyframe","gop"}`,与真录制
///                              run-4ad6e500 的第一行同形)
///   camera_index.csv           `timestamp_ns,relative_path`(帧号)
///   imu.csv                    `timestamp_ns,wx,wy,wz,ax,ay,az`(DeviceRecordingWriter.swift:726)
///   intrinsics.jsonl           `{"t":秒,"intrinsics_fxfycxcy":[4],"exposure_s":秒}`(:308-310)
///   recording_manifest.json    DeviceRecordingManifest 的键,files[] 带 sha256
struct Fixture {
    enum IndexStyle { case current, length5966 }

    let width: Int
    let height: Int
    var frames: [(t: Int64, fill: UInt8)] = []
    var imu: [Int64] = []
    var lossCount = 0
    var crossCheckPassed = true
    var indexStyle = IndexStyle.current
    var omitLaterManifestKeys = false
    var truncateFrameEntryTo: Int? = nil
    var intrinsicsJSONL: String? = nil

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    static func minimal() -> Fixture {
        var f = Fixture(width: 8, height: 6)
        f.addFrame(t: 0, fill: 7)
        f.addIMU(t: 0)
        return f
    }

    mutating func addFrame(t: Int64, fill: UInt8) { frames.append((t, fill)) }
    mutating func addIMU(t: Int64) { imu.append(t) }

    func write(to root: URL) throws {
        let frameBytes = width * height
        var stream = Data()
        var index: [String] = []
        for (i, f) in frames.enumerated() {
            let offset = stream.count
            stream.append(Data(repeating: f.fill, count: frameBytes))
            let len = (i == 0 ? truncateFrameEntryTo : nil) ?? frameBytes
            switch indexStyle {
            case .current:
                index.append("{\"frame\":\(i),\"offset\":\(offset),\"len\":\(len),\"keyframe\":true,\"gop\":\(i)}")
            case .length5966:
                index.append("{\"frame\":\(i),\"offset\":\(offset),\"length\":\(len)}")
            }
        }
        let camera = (["timestamp_ns,relative_path"]
            + frames.enumerated().map { "\($0.element.t),\($0.offset)" })
            .joined(separator: "\n") + "\n"
        let imuCSV = (["timestamp_ns,wx,wy,wz,ax,ay,az"]
            + imu.map { "\($0),0.01,0.02,0.03,0.0,0.0,-9.80665" })
            .joined(separator: "\n") + "\n"
        let poses = "0.000000000 0 0 0 0 0 0 1\n"
        let files: [(String, String, Data)] = [
            ("arkit_poses", "arkit_poses.tum", Data(poses.utf8)),
            ("camera_index", "camera_index.csv", Data(camera.utf8)),
            ("imu_index", "imu.csv", Data(imuCSV.utf8)),
            ("frames_index", "frames.pwvi", Data((index.joined(separator: "\n") + "\n").utf8)),
        ] + (intrinsicsJSONL.map { [("intrinsics_index", "intrinsics.jsonl", Data(($0 + "\n").utf8))] } ?? [])
        var manifestFiles: [[String: Any]] = []
        for (role, path, data) in files {
            try data.write(to: root.appendingPathComponent(path))
            manifestFiles.append(["role": role, "relative_path": path,
                                  "byte_count": data.count, "sha256": Self.hex(data)])
        }
        try stream.write(to: root.appendingPathComponent("frames.bin"))
        manifestFiles.append(["role": "frames_stream", "relative_path": "frames.bin",
                              "byte_count": stream.count, "sha256": Self.hex(stream)])
        var manifest: [String: Any] = [
            "schema_version": 1,
            "recording_id": "fixture",
            "camera": ["width": width, "height": height,
                       "pixel_format": "luma8_from_420f_full_range", "nominal_fps": 60],
            "intrinsics": ["fx": 5.0, "fy": 5.0, "cx": 2.0, "cy": 1.0,
                           "source": "ARFrame.camera.intrinsics",
                           "cross_check_passed": crossCheckPassed],
            "frame_count": frames.count,
            "imu_sample_count": imu.count,
            "frames_digest_sha256": Self.hex(stream),
            "frames_total_byte_count": stream.count,
            "loss_count": lossCount,
            "files": manifestFiles,
        ]
        if !omitLaterManifestKeys {
            manifest["loss_format_mismatch"] = 0
            manifest["loss_write_queue_full"] = lossCount
            manifest["loss_write_error"] = 0
            manifest["peak_in_flight"] = 1
            manifest["slowest_write_ms"] = 1.5
            manifest["focal_length_min"] = 5.0
            manifest["focal_length_max"] = 5.0
            manifest["late_frames_after_seal"] = 0
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: root.appendingPathComponent("recording_manifest.json"))
    }

    static func hex(_ d: Data) -> String {
        SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }
}
