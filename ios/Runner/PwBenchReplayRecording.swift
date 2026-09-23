// PwBenchReplayRecording.swift —— 台架回放:把一份设备录制(`run-<uuid>/`)读成事件流。
//
// 只进台架(arloopbench,bundle com.kyle.arloopbench)。生产 Runner.xcodeproj 不编它。
//
// ══ 这是**搬过来的**代码,不是新写的 ══════════════════════════════════════
// 真源(我们自己的代码):研究仓 pocketworld-research-benchmarks,worktree
//   ~/.config/superpowers/worktrees/pocketworld_research_benchmarks/basalt-vio-phone-bench-20260829
//   @ fbe30567(research/basalt-vio-phone-bench-20260829),目录 tools/ios_basalt_vio_bench/
//     Replay/DeviceRecordingTypes.swift   (354 行)
//     Replay/DeviceRecordingLoader.swift  (585 行)
//     Replay/EuRoCTypes.swift             (取 ReplayEvent 与 IMU 样本两个类型)
//   每个类型 / 函数上的 `[port] 文件:行` 标的是它对应的源。
//
// ══ 与源的偏离(每条都有原因,没有一条是「我觉得更好」)══════════════════════
// D1 只留 raw luma 一条读帧路径。源 `RawLumaFrameLoader.decode` 的 HEVC 分支要
//    `pw_vt_dec_*`,台架没有;源自己的注释(DeviceRecordingLoader.swift:86-90)说设备上
//    存的就是 raw 平面。遇到长度不是整帧的索引条目 ⇒ **拒绝**,不静默跳过。
//    相机帧因此不再带 `camera0ImageURL/camera0AccessUnits`,只带流内字节区间
//    (类型改名 DeviceRecordingCameraFrame,免得冒充源的 EuRoCCameraFrame)。
// D2 帧索引兼容 `length` 键、`keyframe` 可缺 —— run-5966aec0 的 frames.pwvi 就是
//    `{"frame","offset","length"}`,源的 parseArchiveIndex(:446-456)会拒;
//    arloopbench `tools/pwvi_to_euroc.py:84-87` 早就这样兼容。
// D3 manifest 里后来才加的字段改 Optional。理由与源给 depth 字段的一字不差
//    (DeviceRecordingTypes.swift:167-175:合成的 init(from:) 对缺键直接抛错);
//    run-5966aec0 就没有 `late_frames_after_seal`。
// D4 分辨率不拒。源 `.verdict` 只收 1920×1440(:208-225)。台架规矩是「录的是多少
//    就喂多少、不静默降采样,并说出来」⇒ 照收,`verdictResolution` 如实标 false 由
//    回执带出 —— 与源 `.replication` 同形(收下但标不可计分)。
// D5 有损录制默认仍拒(源 :226-228);`allowLossy` 显式放行,loss_count 原样带出。
//    理由:逐帧内参 A/C 用的三场里两场有损(4ad6e500 loss 95、5966aec0 loss 155),
//    Mac 宿主回放吃的就是同样带缺口的输入;同一份输入开/关各跑一次,A/B 仍公平。
// D6 不解析 arkit_poses.tum(源拿它做对照;台架的 ATE 在 Mac 上离线算),但它的
//    SHA-256 仍由 verifyIndexFiles 核对,role 仍必需(:237)。
// D7 新增 intrinsics.jsonl 逐帧配对(K 与 exposure_s),规则逐字抄
//    arloopbench `tools/pwvi_to_euroc.py:130-157` pair_intrinsics_rows:
//      键 = round(t·1e9)(Python round:四舍六入五成双),与相机 timestamp_ns 最近邻,
//      容差 1 ms(含),并列取前一个;配不上的帧不带 K;配对率 < 99% 拒绝。
//    xrslam fork `pw_tools/regression/euroc_runner.cpp:75-93,234-241`(Mac 宿主回放)
//    按同一条规则配对,两边吃到的逐帧 K 因此是同一组数。
// D8 新增 limitFrames:只取前 N 行相机索引(先截再做 D10 的丢帧),IMU 全留。
//    与 pwvi_to_euroc.py `--limit` 同义 —— Mac 等价核对要用同一个子集。
// D9 统计「相机与某条 IMU 时间戳相等」的次数。源在并列时 IMU 排前(:302-310);
//    上游 EuRoC reader 先插相机再 stable_sort(xrslam-pc/player/src/IO/
//    euroc_dataset_reader.cpp:13-33)⇒ 并列时相机在前。这个数为 0 时两者无差别。
// (D10 不是偏离:源 :312-332 丢掉第一条 IMU 之前的相机帧,原样保留,并计数带出。)

import CryptoKit
import Foundation

// MARK: - [port] EuRoCTypes.swift(子集)

/// [port] 源里 Vector3 由评测模块定义,这里只要三个分量。
struct Vector3: Equatable, Sendable {
    let x: Double
    let y: Double
    let z: Double
}

/// [port] EuRoCTypes.swift:45-49 —— 录制里 imu.csv 的一行。
struct EuRoCIMUSample: Equatable, Sendable {
    let timestampNanoseconds: Int64
    let gyroscopeRadiansPerSecond: Vector3
    let accelerationMetersPerSecondSquared: Vector3
}

/// 录制里的一帧相机(D1:流内字节区间;D7:配上的逐帧 K 与曝光)。
struct DeviceRecordingCameraFrame: Equatable, Sendable {
    let timestampNanoseconds: Int64
    /// camera_index.csv 第二列(= frames.pwvi 的 frame 号)。
    let frameIndex: Int
    /// frames.bin 里这一帧的字节区间,恰为一帧 luma(D1)。
    let byteRange: Range<Int>
    /// 这一帧自己的 fx fy cx cy(`intrinsics_fxfycxcy`,ARFrame.camera.intrinsics),
    /// 像素参照 = 录制平面本身。`nil` = 配不上。
    var intrinsicsFxFyCxCy: [Double]?
    /// 这一帧的曝光时长(秒,`exposure_s`)。`nil` = 录制器没写或配不上。
    var exposureSeconds: Double?
}

/// [port] EuRoCTypes.swift:80-102 —— 相机载荷换成 DeviceRecordingCameraFrame(D1)。
enum ReplayEvent: Equatable, Sendable {
    case imu(EuRoCIMUSample)
    case camera(DeviceRecordingCameraFrame)

    enum Kind: Int, Equatable, Sendable {
        case imu = 0
        case camera = 1
    }

    var timestampNanoseconds: Int64 {
        switch self {
        case .imu(let sample): sample.timestampNanoseconds
        case .camera(let frame): frame.timestampNanoseconds
        }
    }

    var kind: Kind {
        switch self {
        case .imu: .imu
        case .camera: .camera
        }
    }
}

// MARK: - [port] DeviceRecordingTypes.swift

/// [port] DeviceRecordingTypes.swift:14-45
enum DeviceRecordingFileRole: String, Codable, CaseIterable, Sendable {
    case cameraIndex = "camera_index"
    case intrinsicsIndex = "intrinsics_index"
    case framesStream = "frames_stream"
    case framesIndex = "frames_index"
    case imuIndex = "imu_index"
    case arkitPoses = "arkit_poses"
    case depthStream = "depth_stream"
    case depthConfidenceStream = "depth_confidence_stream"
    case depthIndex = "depth_index"
}

/// [port] DeviceRecordingTypes.swift:47-59
struct DeviceRecordingFile: Codable, Equatable, Sendable {
    let role: DeviceRecordingFileRole
    let relativePath: String
    var byteCount: Int64
    var sha256: String

    enum CodingKeys: String, CodingKey {
        case role
        case relativePath = "relative_path"
        case byteCount = "byte_count"
        case sha256
    }
}

/// [port] DeviceRecordingTypes.swift:61-105(去掉依赖 BenchResolution 的两个工厂)
struct DeviceRecordingCameraFormat: Codable, Equatable, Sendable {
    var width: Int
    var height: Int
    var pixelFormat: String
    var nominalFPS: Double

    enum CodingKeys: String, CodingKey {
        case width, height
        case pixelFormat = "pixel_format"
        case nominalFPS = "nominal_fps"
    }

    var bytesPerFrame: Int { width * height }
}

/// [port] DeviceRecordingTypes.swift:107-126
struct DeviceRecordingIntrinsics: Codable, Equatable, Sendable {
    var fx: Double
    var fy: Double
    var cx: Double
    var cy: Double
    var source: String
    var crossCheckPassed: Bool

    enum CodingKeys: String, CodingKey {
        case fx, fy, cx, cy, source
        case crossCheckPassed = "cross_check_passed"
    }
}

/// [port] DeviceRecordingTypes.swift:128-254(D3:后加字段改 Optional)
struct DeviceRecordingManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let recordingID: String
    var camera: DeviceRecordingCameraFormat
    var intrinsics: DeviceRecordingIntrinsics
    var frameCount: Int
    var imuSampleCount: Int
    var framesDigestSHA256: String
    var framesTotalByteCount: Int64
    var lossCount: Int
    var lossFormatMismatch: Int?
    var lossWriteQueueFull: Int?
    var lossWriteError: Int?
    var peakInFlight: Int?
    var slowestWriteMilliseconds: Double?
    var focalLengthMinimum: Double?
    var focalLengthMaximum: Double?
    var lateFramesAfterSeal: Int?
    var depthPresent: Bool?
    var depthWidth: Int?
    var depthHeight: Int?
    var depthFrameCount: Int?
    var depthSource: String?
    var depthConfidencePresent: Bool?
    var depthDropped: Int?
    var files: [DeviceRecordingFile]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case recordingID = "recording_id"
        case camera, intrinsics, files
        case frameCount = "frame_count"
        case imuSampleCount = "imu_sample_count"
        case framesDigestSHA256 = "frames_digest_sha256"
        case framesTotalByteCount = "frames_total_byte_count"
        case lossCount = "loss_count"
        case lossFormatMismatch = "loss_format_mismatch"
        case lossWriteQueueFull = "loss_write_queue_full"
        case lossWriteError = "loss_write_error"
        case peakInFlight = "peak_in_flight"
        case slowestWriteMilliseconds = "slowest_write_ms"
        case focalLengthMinimum = "focal_length_min"
        case focalLengthMaximum = "focal_length_max"
        case lateFramesAfterSeal = "late_frames_after_seal"
        case depthPresent = "depth_present"
        case depthWidth = "depth_width"
        case depthHeight = "depth_height"
        case depthFrameCount = "depth_frame_count"
        case depthSource = "depth_source"
        case depthConfidencePresent = "depth_confidence_present"
        case depthDropped = "depth_dropped"
    }

    static let supportedSchemaVersion = 1
    static let fileName = "recording_manifest.json"
    static let framesStreamPath = "frames.bin"
    static let framesIndexPath = "frames.pwvi"

    /// [port] BenchResolution.swift:23,92-94 —— 计分分辨率(1920×1440)。台架不据此拒(D4)。
    static let verdictWidth = 1920
    static let verdictHeight = 1440
}

/// 装载时怎么对待这份录制。默认值 = 源的严格口径。
struct DeviceRecordingLoadOptions: Equatable, Sendable {
    /// [port] DeviceRecordingLoader.swift:181-190 —— 23 GiB 重哈希要时间,默认关。
    var verifyFramesDigest = false
    /// D5
    var allowLossy = false
    /// D8。0 = 全部。
    var limitFrames = 0
}

/// 装载的附带事实。全部进回执,一个都不在别处合成。
struct DeviceRecordingLoadReport: Equatable, Sendable {
    var verdictResolution = true
    var lossCount = 0
    var framesDigestVerified = false
    var indexFilesVerified = 0
    var cameraRowsTotal = 0
    var cameraRowsAfterLimit = 0
    var imuSamples = 0
    var intrinsicsIndexPresent = false
    var intrinsicsRows = 0
    var intrinsicsPaired = 0
    var intrinsicsUnmatched = 0
    var framesWithExposure = 0
    var leadingCameraFramesWithoutImuDropped = 0
    var cameraImuTimestampTies = 0
}

/// [port] DeviceRecordingTypes.swift:256-270(D6:无 arkitReference)
struct DeviceRecordingDataset: Sendable {
    let recordingID: String
    let root: URL
    let manifest: DeviceRecordingManifest
    let streamURL: URL
    let events: [ReplayEvent]
    let report: DeviceRecordingLoadReport

    var camera: DeviceRecordingCameraFormat { manifest.camera }
    var intrinsics: DeviceRecordingIntrinsics { manifest.intrinsics }
    var inputCameraCount: Int { 1 }
    var cameraFrameCount: Int {
        events.reduce(0) { if case .camera = $1 { return $0 + 1 } else { return $0 } }
    }
    var imuEventCount: Int {
        events.reduce(0) { if case .imu = $1 { return $0 + 1 } else { return $0 } }
    }
}

/// [port] DeviceRecordingTypes.swift:279-354(只留装载会用到的分支,另加 D1/D7 两条)
enum DeviceRecordingError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case invalidRecordingID
    case emptyRecording
    case lossyRecording(lossCount: Int)
    case frameCountMismatch(declared: Int, indexed: Int)
    case missingFrame(String)
    case frameSizeMismatch(path: String, expected: Int, actual: Int)
    case framesDigestMismatch(expected: String, actual: String)
    case fileHashMismatch(path: String, expected: String, actual: String)
    case unsafeRelativePath(String)
    case missingRequiredRole(DeviceRecordingFileRole)
    case timestampRegression(path: String, previous: Int64, current: Int64)
    case malformedCSV(path: String, line: Int, reason: String)
    case intrinsicsCrossCheckFailed
    /// D1:索引条目不是整帧 raw 平面(编码过的流),台架不解码。
    case encodedFrameNotSupported(frame: Int, length: Int, expected: Int)
    /// D7:intrinsics.jsonl 与相机帧配对率 < 99%。
    case intrinsicsPairingRate(paired: Int, total: Int)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .unsupportedSchemaVersion(let v): "unsupported device recording schema version \(v)"
        case .invalidRecordingID: "recording_id must not be empty"
        case .emptyRecording: "recording has no camera or IMU events"
        case .lossyRecording(let n):
            "recording declares \(n) losses; a lossy recording is invalid, not shorter "
                + "(pass -PWBenchReplayAllowLossy on to replay it anyway, flagged in the receipt)"
        case .frameCountMismatch(let d, let i): "frame_count \(d) does not match \(i) indexed frames"
        case .missingFrame(let p): "missing frame file: \(p)"
        case .frameSizeMismatch(let p, let e, let a): "frame \(p) is \(a) bytes, expected \(e)"
        case .framesDigestMismatch(let e, let a): "frames digest mismatch: expected \(e), got \(a)"
        case .fileHashMismatch(let p, let e, let a): "SHA-256 mismatch for \(p): expected \(e), got \(a)"
        case .unsafeRelativePath(let p): "unsafe relative path: \(p)"
        case .missingRequiredRole(let r): "missing required file role: \(r.rawValue)"
        case .timestampRegression(let p, let prev, let cur): "timestamp regression in \(p): \(prev) -> \(cur)"
        case .malformedCSV(let p, let l, let r): "malformed CSV \(p):\(l): \(r)"
        case .intrinsicsCrossCheckFailed:
            "ARKit intrinsics cannot describe the frames they arrived with"
        case .encodedFrameNotSupported(let f, let l, let e):
            "frame \(f) is an encoded access unit (\(l) bytes, raw plane is \(e)); "
                + "the bench replays raw luma only"
        case .intrinsicsPairingRate(let p, let t):
            "intrinsics.jsonl pairs \(p)/\(t) camera frames (< 99%); refused like pwvi_to_euroc.py"
        }
    }
}

// MARK: - [port] DeviceRecordingLoader.swift:17-65 FrameStreamReader

/// Reads byte ranges out of the recording's append-only frame stream without
/// holding the whole stream in memory. [port] :10-16 的理由原样适用:
/// `.mappedIfSafe` 在大文件上会静默整读,设备拒绝那次分配;定位读只花这一段。
///
/// 偏离:源每帧开一次(:21-23「A replay opens one of these per frame」),这里整场
/// 开一次、每帧 `pread` —— 同一个文件、同一段字节,少 1700 次 open/close。
final class FrameStreamReader {
    private let handle: FileHandle
    let count: Int

    deinit { try? handle.close() }

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        let size = try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? NSNumber
        count = size?.intValue ?? 0
    }

    /// [port] :32-48
    func forEachChunk(_ body: (Data) -> Void) throws {
        try handle.seek(toOffset: 0)
        var remaining = count
        while remaining > 0 {
            try autoreleasepool {
                let piece = min(remaining, 4 * 1024 * 1024)
                guard let chunk = try handle.read(upToCount: piece), !chunk.isEmpty else {
                    remaining = 0
                    return
                }
                body(chunk)
                remaining -= chunk.count
            }
        }
    }

    /// [port] :50-64(用 pread,不动文件游标)
    func read(_ range: Range<Int>) throws -> Data {
        guard range.lowerBound >= 0, range.upperBound <= count else {
            throw DeviceRecordingError.missingFrame(handle.description)
        }
        var data = Data(count: range.count)
        let got = data.withUnsafeMutableBytes { dst -> Int in
            pread(handle.fileDescriptor, dst.baseAddress, range.count, off_t(range.lowerBound))
        }
        guard got == range.count else {
            throw DeviceRecordingError.frameSizeMismatch(
                path: DeviceRecordingManifest.framesStreamPath,
                expected: range.count, actual: max(0, got))
        }
        return data
    }

    /// 把一帧 `rows × rowBytes` 的平面直接读进调用方的内存(例如 CVPixelBuffer 的
    /// 基址)。目标行宽 == rowBytes 时一次 pread;有行填充时逐行读,不把 stride
    /// 烤进像素(源 DeviceRecordingTests.swift:21-25 说的「stride 陷阱」反方向)。
    func read(_ range: Range<Int>, into destination: UnsafeMutableRawPointer,
              rowBytes: Int, rows: Int, destinationStride: Int) throws {
        guard range.lowerBound >= 0, range.upperBound <= count,
              rowBytes > 0, rows > 0, range.count == rowBytes * rows,
              destinationStride >= rowBytes else {
            throw DeviceRecordingError.frameSizeMismatch(
                path: DeviceRecordingManifest.framesStreamPath,
                expected: rowBytes * rows, actual: range.count)
        }
        let fd = handle.fileDescriptor
        if destinationStride == rowBytes {
            let got = pread(fd, destination, range.count, off_t(range.lowerBound))
            guard got == range.count else {
                throw DeviceRecordingError.frameSizeMismatch(
                    path: DeviceRecordingManifest.framesStreamPath,
                    expected: range.count, actual: max(0, got))
            }
            return
        }
        for row in 0..<rows {
            let got = pread(fd, destination + row * destinationStride, rowBytes,
                            off_t(range.lowerBound + row * rowBytes))
            guard got == rowBytes else {
                throw DeviceRecordingError.frameSizeMismatch(
                    path: DeviceRecordingManifest.framesStreamPath,
                    expected: rowBytes, actual: max(0, got))
            }
        }
    }
}

// MARK: - [port] DeviceRecordingLoader.swift:179-585

struct DeviceRecordingLoader {
    let options: DeviceRecordingLoadOptions

    init(options: DeviceRecordingLoadOptions = DeviceRecordingLoadOptions()) {
        self.options = options
    }

    /// [port] :192-341
    func load(manifestURL: URL) throws -> DeviceRecordingDataset {
        let root = manifestURL.deletingLastPathComponent()
        let manifest = try JSONDecoder().decode(
            DeviceRecordingManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        var report = DeviceRecordingLoadReport()

        guard manifest.schemaVersion == DeviceRecordingManifest.supportedSchemaVersion else {
            throw DeviceRecordingError.unsupportedSchemaVersion(manifest.schemaVersion)
        }
        guard !manifest.recordingID.isEmpty else {
            throw DeviceRecordingError.invalidRecordingID
        }
        // D4:不拒,如实标。
        report.verdictResolution =
            manifest.camera.width == DeviceRecordingManifest.verdictWidth
            && manifest.camera.height == DeviceRecordingManifest.verdictHeight
        // D5
        report.lossCount = manifest.lossCount
        guard manifest.lossCount == 0 || options.allowLossy else {
            throw DeviceRecordingError.lossyRecording(lossCount: manifest.lossCount)
        }
        guard manifest.intrinsics.crossCheckPassed else {
            throw DeviceRecordingError.intrinsicsCrossCheckFailed
        }

        report.indexFilesVerified = try verifyIndexFiles(manifest.files, root: root)

        let cameraRecord = try required(.cameraIndex, in: manifest.files)
        let imuRecord = try required(.imuIndex, in: manifest.files)
        _ = try required(.arkitPoses, in: manifest.files)   // D6:只核在不在 + 哈希

        let streamRecord = try required(.framesStream, in: manifest.files)
        try rejectUnsafePath(streamRecord.relativePath)
        let streamURL = root.appendingPathComponent(streamRecord.relativePath)
        // [port] :242-250 —— 上界取磁盘上的文件,不信 manifest。
        let streamAttributes = try? FileManager.default.attributesOfItem(
            atPath: streamURL.path
        )
        guard let streamSize = (streamAttributes?[.size] as? NSNumber)?.int64Value else {
            throw DeviceRecordingError.missingFrame(streamRecord.relativePath)
        }
        let indexRecord = try required(.framesIndex, in: manifest.files)
        try rejectUnsafePath(indexRecord.relativePath)
        let entries = try parseArchiveIndex(
            url: root.appendingPathComponent(indexRecord.relativePath),
            streamByteCount: Int(streamSize)
        )
        var frames = try parseCameraIndex(
            record: cameraRecord,
            root: root,
            format: manifest.camera,
            entries: entries
        )
        guard frames.count == manifest.frameCount else {
            throw DeviceRecordingError.frameCountMismatch(
                declared: manifest.frameCount,
                indexed: frames.count
            )
        }
        report.cameraRowsTotal = frames.count
        let imu = try parseIMU(record: imuRecord, root: root)
        report.imuSamples = imu.count
        guard !frames.isEmpty || !imu.isEmpty else {
            throw DeviceRecordingError.emptyRecording
        }

        if options.verifyFramesDigest {
            // 摘要覆盖**整份**录制(与 limitFrames 无关):核的是录制,不是子集。
            try verifyDigest(frames: frames, streamURL: streamURL,
                             expected: manifest.framesDigestSHA256)
            report.framesDigestVerified = true
        }

        // D8
        if options.limitFrames > 0 && frames.count > options.limitFrames {
            frames = Array(frames.prefix(options.limitFrames))
        }
        report.cameraRowsAfterLimit = frames.count

        // D7
        if let kRecord = manifest.files.first(where: { $0.role == .intrinsicsIndex }) {
            try rejectUnsafePath(kRecord.relativePath)
            report.intrinsicsIndexPresent = true
            let rows = try parseIntrinsicsIndex(
                url: root.appendingPathComponent(kRecord.relativePath))
            report.intrinsicsRows = rows.count
            let pairing = Self.pairIntrinsics(rows: rows, frames: frames)
            report.intrinsicsPaired = pairing.paired
            report.intrinsicsUnmatched = frames.count - pairing.paired
            if report.intrinsicsUnmatched * 100 > frames.count {
                throw DeviceRecordingError.intrinsicsPairingRate(
                    paired: pairing.paired, total: frames.count)
            }
            frames = pairing.frames
            report.framesWithExposure = frames.reduce(0) { $0 + ($1.exposureSeconds != nil ? 1 : 0) }
        }

        // D9
        let imuStamps = Set(imu.map(\.timestampNanoseconds))
        report.cameraImuTimestampTies = frames.reduce(0) {
            $0 + (imuStamps.contains($1.timestampNanoseconds) ? 1 : 0)
        }

        // [port] :302-310 —— IMU first at an equal timestamp: the estimator must
        // have integrated motion up to the shutter before the image arrives.
        var events: [ReplayEvent] = imu.map { .imu($0) } + frames.map { .camera($0) }
        events.sort {
            $0.timestampNanoseconds == $1.timestampNanoseconds
                ? $0.kind.rawValue < $1.kind.rawValue
                : $0.timestampNanoseconds < $1.timestampNanoseconds
        }

        // [port] :312-332 —— Motion recording starts at the end of the first camera
        // callback, so a capture opens with camera frames that have no inertial data
        // behind them. xrslam took a SIGBUS inside push_sensor_data on the first one
        // in the source bench; they are dropped here rather than left for the engine
        // to survive or not.
        if let firstIMU = imu.first?.timestampNanoseconds {
            let before = events.count
            events.removeAll {
                if case .camera(let frame) = $0 {
                    return frame.timestampNanoseconds < firstIMU
                }
                return false
            }
            report.leadingCameraFramesWithoutImuDropped = before - events.count
        }

        return DeviceRecordingDataset(
            recordingID: manifest.recordingID,
            root: root,
            manifest: manifest,
            streamURL: streamURL,
            events: events,
            report: report
        )
    }

    // MARK: Verification

    /// [port] :345-375 —— 返回核过的文件数。
    private func verifyIndexFiles(
        _ files: [DeviceRecordingFile],
        root: URL
    ) throws -> Int {
        let payloadRoles: Set<DeviceRecordingFileRole> = [
            .framesStream, .depthStream, .depthConfidenceStream,
        ]
        var verified = 0
        for record in files {
            try rejectUnsafePath(record.relativePath)
            guard !payloadRoles.contains(record.role) else { continue }
            let url = root.appendingPathComponent(record.relativePath)
            let data = try Data(contentsOf: url)
            let actual = Self.hex(SHA256.hash(data: data))
            guard actual == record.sha256 else {
                throw DeviceRecordingError.fileHashMismatch(
                    path: record.relativePath,
                    expected: record.sha256,
                    actual: actual
                )
            }
            verified += 1
        }
        return verified
    }

    /// [port] :377-408 —— raw 平面下,每帧的「自己那个访问单元」就是它的字节区间。
    private func verifyDigest(
        frames: [DeviceRecordingCameraFrame],
        streamURL: URL,
        expected: String
    ) throws {
        var digest = SHA256()
        let reader = try FrameStreamReader(url: streamURL)
        for frame in frames {
            try autoreleasepool { digest.update(data: try reader.read(frame.byteRange)) }
        }
        let actual = Self.hex(digest.finalize())
        guard actual == expected else {
            throw DeviceRecordingError.framesDigestMismatch(expected: expected, actual: actual)
        }
    }

    /// [port] DeviceRecordingWriter.hex 的同义实现(小写十六进制)。
    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// [port] :410-418
    private func required(
        _ role: DeviceRecordingFileRole,
        in files: [DeviceRecordingFile]
    ) throws -> DeviceRecordingFile {
        guard let record = files.first(where: { $0.role == role }) else {
            throw DeviceRecordingError.missingRequiredRole(role)
        }
        return record
    }

    /// [port] :420-427
    private func rejectUnsafePath(_ path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains(".."),
              !path.contains("\\") else {
            throw DeviceRecordingError.unsafeRelativePath(path)
        }
    }

    // MARK: Parsing

    /// [port] :432-437 —— 生产 archive 索引的一行。D2:keyframe 可缺。
    struct ArchiveIndexEntry: Equatable {
        let frame: Int
        let offset: Int
        let len: Int
    }

    /// [port] :439-471(D2)
    private func parseArchiveIndex(
        url: URL,
        streamByteCount: Int
    ) throws -> [ArchiveIndexEntry] {
        var entries: [ArchiveIndexEntry] = []
        let text = try String(contentsOf: url, encoding: .utf8)
        for (line, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            guard let object = try JSONSerialization.jsonObject(
                with: Data(raw.utf8)
            ) as? [String: Any],
                let frame = object["frame"] as? Int,
                let offset = object["offset"] as? Int,
                let len = (object["len"] as? Int) ?? (object["length"] as? Int) else {
                throw DeviceRecordingError.malformedCSV(
                    path: url.lastPathComponent, line: line + 1, reason: "index_row"
                )
            }
            guard offset >= 0, len > 0, offset + len <= streamByteCount else {
                throw DeviceRecordingError.frameSizeMismatch(
                    path: url.lastPathComponent,
                    expected: len,
                    actual: max(0, streamByteCount - offset)
                )
            }
            entries.append(ArchiveIndexEntry(frame: frame, offset: offset, len: len))
        }
        return entries
    }

    /// [port] :473-524(D1:只收整帧 raw 平面)
    private func parseCameraIndex(
        record: DeviceRecordingFile,
        root: URL,
        format: DeviceRecordingCameraFormat,
        entries: [ArchiveIndexEntry]
    ) throws -> [DeviceRecordingCameraFrame] {
        var frames: [DeviceRecordingCameraFrame] = []
        var previous: Int64?
        try forEachRow(record: record, root: root, expectedColumns: 2) { line, fields in
            guard let timestamp = Int64(fields[0]) else {
                throw DeviceRecordingError.malformedCSV(
                    path: record.relativePath, line: line, reason: "timestamp_ns"
                )
            }
            if let previous, timestamp <= previous {
                throw DeviceRecordingError.timestampRegression(
                    path: record.relativePath, previous: previous, current: timestamp
                )
            }
            previous = timestamp
            guard let frameIndex = Int(fields[1]), frameIndex >= 0 else {
                throw DeviceRecordingError.malformedCSV(
                    path: record.relativePath, line: line, reason: "frame_index"
                )
            }
            guard frameIndex < entries.count else {
                throw DeviceRecordingError.frameCountMismatch(
                    declared: frameIndex + 1, indexed: entries.count
                )
            }
            let entry = entries[frameIndex]
            // 源按数组下标取条目;这里再核一次条目自己的 frame 号,错位就拒。
            guard entry.frame == frameIndex else {
                throw DeviceRecordingError.malformedCSV(
                    path: record.relativePath, line: line,
                    reason: "frames.pwvi row \(frameIndex) is frame \(entry.frame)"
                )
            }
            guard entry.len == format.bytesPerFrame else {
                throw DeviceRecordingError.encodedFrameNotSupported(
                    frame: frameIndex, length: entry.len, expected: format.bytesPerFrame
                )
            }
            frames.append(DeviceRecordingCameraFrame(
                timestampNanoseconds: timestamp,
                frameIndex: frameIndex,
                byteRange: entry.offset ..< (entry.offset + entry.len),
                intrinsicsFxFyCxCy: nil,
                exposureSeconds: nil
            ))
        }
        return frames
    }

    /// [port] :526-559
    private func parseIMU(
        record: DeviceRecordingFile,
        root: URL
    ) throws -> [EuRoCIMUSample] {
        var samples: [EuRoCIMUSample] = []
        var previous: Int64?
        try forEachRow(record: record, root: root, expectedColumns: 7) { line, fields in
            guard let timestamp = Int64(fields[0]) else {
                throw DeviceRecordingError.malformedCSV(
                    path: record.relativePath, line: line, reason: "timestamp_ns"
                )
            }
            if let previous, timestamp <= previous {
                throw DeviceRecordingError.timestampRegression(
                    path: record.relativePath, previous: previous, current: timestamp
                )
            }
            previous = timestamp
            let values = try fields.dropFirst().map { field -> Double in
                guard let value = Double(field), value.isFinite else {
                    throw DeviceRecordingError.malformedCSV(
                        path: record.relativePath, line: line, reason: "non-finite \(field)"
                    )
                }
                return value
            }
            samples.append(EuRoCIMUSample(
                timestampNanoseconds: timestamp,
                gyroscopeRadiansPerSecond: Vector3(x: values[0], y: values[1], z: values[2]),
                accelerationMetersPerSecondSquared: Vector3(x: values[3], y: values[4], z: values[5])
            ))
        }
        return samples
    }

    /// [port] :561-584
    private func forEachRow(
        record: DeviceRecordingFile,
        root: URL,
        expectedColumns: Int,
        body: (Int, [String]) throws -> Void
    ) throws {
        let text = try String(
            contentsOf: root.appendingPathComponent(record.relativePath),
            encoding: .utf8
        )
        for (offset, rawLine) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || offset == 0 { continue }  // row 0 is the header
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == expectedColumns else {
                throw DeviceRecordingError.malformedCSV(
                    path: record.relativePath,
                    line: offset + 1,
                    reason: "expected \(expectedColumns) columns, got \(fields.count)"
                )
            }
            try body(offset + 1, fields)
        }
    }

    // MARK: D7 intrinsics.jsonl

    /// intrinsics.jsonl 的一行(录制器 DeviceRecordingWriter.swift:308-310 写的
    /// `{"t":秒,"intrinsics_fxfycxcy":[4],"exposure_s":秒?}`)。
    struct IntrinsicsRow: Equatable, Sendable {
        /// round(t·1e9),四舍六入五成双(= Python round)。
        let keyNanoseconds: Int64
        let fxfycxcy: [Double]?
        let exposureSeconds: Double?
    }

    /// 逐行解析;没有 `t` 的行跳过(与 pwvi_to_euroc.py:139 `if 't' in r` 同)。
    func parseIntrinsicsIndex(url: URL) throws -> [IntrinsicsRow] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var rows: [IntrinsicsRow] = []
        for (line, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            guard let object = try JSONSerialization.jsonObject(
                with: Data(trimmed.utf8)) as? [String: Any] else {
                throw DeviceRecordingError.malformedCSV(
                    path: url.lastPathComponent, line: line + 1, reason: "intrinsics_row")
            }
            guard let t = (object["t"] as? NSNumber)?.doubleValue, t.isFinite else { continue }
            var k: [Double]? = nil
            if let list = object["intrinsics_fxfycxcy"] as? [NSNumber], list.count == 4 {
                let v = list.map(\.doubleValue)
                if v.allSatisfy(\.isFinite) { k = v }
            }
            var exposure: Double? = nil
            // pwvi_to_euroc.py:150-151:`isinstance(e, (int, float)) and e >= 0` 才算
            // (Python 的 bool 也是 int,NSNumber 同样照收 —— 逐字同义,不另加规则)。
            if let e = object["exposure_s"] as? NSNumber {
                let v = e.doubleValue
                if v.isFinite && v >= 0 { exposure = v }
            }
            let key = (t * 1e9).rounded(.toNearestOrEven)
            guard key.isFinite, abs(key) < 9.0e18 else { continue }
            rows.append(IntrinsicsRow(keyNanoseconds: Int64(key), fxfycxcy: k,
                                      exposureSeconds: exposure))
        }
        return rows
    }

    /// pwvi_to_euroc.py:130-157 pair_intrinsics_rows 的逐行照抄:按键排序(稳定),
    /// 对每帧 bisect_left,候选 i-1 与 i,|Δ| ≤ 1 ms,更近者胜、并列取 i-1。
    static func pairIntrinsics(rows: [IntrinsicsRow],
                               frames: [DeviceRecordingCameraFrame])
        -> (frames: [DeviceRecordingCameraFrame], paired: Int)
    {
        // Python sorted(..., key=x[0]) 是稳定排序;Swift sort 不保证稳定 ⇒ 带下标排。
        let table = rows.enumerated().sorted {
            $0.element.keyNanoseconds != $1.element.keyNanoseconds
                ? $0.element.keyNanoseconds < $1.element.keyNanoseconds
                : $0.offset < $1.offset
        }.map(\.element)
        let keys = table.map(\.keyNanoseconds)
        var out = frames
        var paired = 0
        for k in out.indices {
            let t = out[k].timestampNanoseconds
            // bisect_left
            var lo = 0, hi = keys.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if keys[mid] < t { lo = mid + 1 } else { hi = mid }
            }
            var best: Int? = nil
            for j in [lo - 1, lo] where j >= 0 && j < keys.count {
                let d = abs(keys[j] - t)
                guard d <= 1_000_000 else { continue }
                if let b = best {
                    if d < abs(keys[b] - t) { best = j }
                } else {
                    best = j
                }
            }
            guard let b = best else { continue }
            paired += 1
            out[k].intrinsicsFxFyCxCy = table[b].fxfycxcy
            out[k].exposureSeconds = table[b].exposureSeconds
        }
        return (out, paired)
    }
}

// MARK: - 录制目录外的只读旁证(不在 manifest.files 里 ⇒ 未核哈希,回执里如实标)

enum DeviceRecordingSidecars {
    /// 录制时的机型标识(`hw.machine`,如 iPhone15,2)。先读 input_manifest.json 的
    /// `device_model`,再读 receipt.json 的 `device.model_identifier`(两者都是
    /// BasaltVIOBench 录制器写的)。都没有 ⇒ nil。
    static func deviceModel(root: URL) -> (model: String, source: String)? {
        if let d = try? Data(contentsOf: root.appendingPathComponent("input_manifest.json")),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let m = o["device_model"] as? String, !m.isEmpty {
            return (m, "input_manifest.json:device_model")
        }
        if let d = try? Data(contentsOf: root.appendingPathComponent("receipt.json")),
           let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let dev = o["device"] as? [String: Any],
           let m = dev["model_identifier"] as? String, !m.isEmpty {
            return (m, "receipt.json:device.model_identifier")
        }
        return nil
    }
}
