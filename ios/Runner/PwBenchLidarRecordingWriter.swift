// PwBenchLidarRecordingWriter.swift —— 台架录制器:把一次 ARKit 采集落成与 viobench-recordings/run-*
// **同格式**的 pwvi 录制(frames.bin / frames.pwvi / camera_index.csv / intrinsics.jsonl / imu.csv /
// arkit_poses.tum / recording_manifest.json),外加 🔴 **bench-only ruler** 的 LiDAR 深度三件套
// (depth.bin / depth_conf.bin / depth.pwvi)。
//
// ══ 🔴 口径(用户 2026-09-22 / 09-24)═════════════════════════════════════════════════
// **LiDAR 只作研发期量尺(bench-only ruler)。永不进产品代码、产品管线、产品提案。**
// 产品是纯单目 + IMU(上架版只有 XRSLAM)。本文件只编进台架 arloopbench(com.kyle.arloopbench),
// 生产 Runner.xcodeproj 不编它;深度段每个定义点都再写一遍这句话。
//
// ══ 这是**搬过来的**代码,不是新写的 ═════════════════════════════════════════════
// 真源(我们自己的代码,研究仓 pocketworld-research-benchmarks,只读取用):
//   research/basalt-vio-phone-bench-20260829 @ 76b8d47(「bench: record LiDAR sceneDepth and rule a
//   trajectory's scale by it」,09-22 子 agent D;当时编过 .app、**从未装机**)
//     tools/ios_basalt_vio_bench/Replay/DeviceRecordingWriter.swift   (944 行)
//     tools/ios_basalt_vio_bench/BasaltVIOBench/BenchResolution.swift ARKitIntrinsicsCrossCheck.check
//   每段上的 `[port] 文件:行` 标的是它对应的源。用户 09-23 定「只维护一个台架 arloopbench」,
//   所以录制器从 BasaltVIOBench 搬进来,而不是去装那个旧 .app。
//   类型(DeviceRecordingManifest / File / FileRole / CameraFormat / Intrinsics)**不重定义**,
//   直接用同一个 Runner 模块里 PwBenchReplayRecording.swift(回放装载器,09-23 从同一个源移植)
//   的那一份 —— 写与读用同一套 Codable 定义,录出来的东西回放页一定读得懂。
//
// ══ 方法地图(CLAUDE.md「上游复刻铁律」口径)════════════════════════════════════
//   exact_upstream  : 帧流写法(流→索引、每步 synchronize、边写边累加摘要)、背压即丢失即作废、
//                     深度三件套格式与 manifest 7 个字段、copyLumaPlane / copyTightly、finish 次序、
//                     IMU 行格式、主点居中交叉检查的判据(±24 px)
//   product_adapter : 下列 W1–W9(每条都有原因)
//   not_implemented : HEVC 归档编码(源里建了编码器但写路径从不调用,见 W1)
//
// ══ 与源的偏离(每条都有原因,没有一条是「我觉得更好」)══════════════════════════
// W1 去掉 VideoToolbox 编码器。源 init 里 `pw_vt_create_ex` 建了编码器,但 enqueue 写的是 raw
//    luma、`encode()` 全文件无调用者(源自己的注释:「Transcoding now happens off the device」);
//    台架没有 pw_vt_* 符号。录出来的字节与源逐位同形(raw luma,keyframe:true,gop=index)。
// W2 深度走**自己的串行队列**(QoS .utility),不与相机帧共用 writeQueue。源共用一条 FIFO:
//    每个深度帧的 3 次 write+synchronize 排在下一帧 luma 前面,相机帧丢失会作废整场录制,
//    而深度只是尺子 —— 尺子不能挤掉被测量的东西。Mac 上的对照测量见
//    tool/bench/lidar_swift_tests(深度开/关 × 共用/分队列,数在交付报告里)。
// W3 深度按 ARFrame **步长**录(默认每 6 帧一张 ⇒ 60 fps 下 10 Hz)。源每帧都录:
//    256×192×5 B = 240 KiB/帧,60 fps 时相机流之外再加 8.9% 的写入量;步长 6 降到 1.5%。
//    尺子离线只取几十个帧对(帧对间隔 0.5 s),10 Hz 绰绰有余。步长写进 manifest 旁证与每行索引。
// W4 深度/置信度像素格式**核实**再拷:Apple 文档给的是运行时查询,不是保证 ——
//    depthMap「if at runtime the depthMap format is kCVPixelFormatType_DepthFloat32」、
//    confidenceMap「if, for example, the confidenceMap format is kCVPixelFormatType_OneComponent8」
//    (developer.apple.com/documentation/arkit/ardepthdata/depthmap、…/confidencemap)。
//    源按 4 B/1 B 盲拷;格式不对就计进 depth_dropped 与 depth_format_mismatch,不写坏数。
// W5 depth.pwvi 每行在源的 8 个键之外多写:`camera_frame`(同一 ARFrame 在 frames.pwvi 里的帧号,
//    相机帧因背压没收下时为 −1)、`ar_frame`(ARFrame 序号)、`image_w/h`、`k_image`(这一帧的
//    ARFrame.camera.intrinsics)、`k_depth`(按分辨率比、像素面积中心对齐换算的深度图内参)。
//    🔴 `k_depth` 是**推论**,不是 Apple 公布的公式:依据只有 ARDepthData 概述那句「Every pixel in
//    the depthMap maps to a region of the visible scene (capturedImage)」与 WWDC20-10611「the depth map
//    is smaller in resolution compared to the captured image … which still presents the same aspect
//    ratio」。读者(depth_ruler.sample_depth)用的是同一条式子,写在这里只为读者不必再推。
// W6 intrinsics.jsonl 每行多一个 `arkit_tracking`(normal / limited_* / not_available)。
//    源不记跟踪状态,尺子与规范尺度估计器只能拿「平移恰为 0」当「没在跟踪」的代理;
//    09-24 根因审计又查到「ARKit 自标 limited_initializing 仍照喂」—— 有了这个键就按原话丢。
//    回放装载器按 JSONSerialization 读这一行,多出的键被忽略(PwBenchReplayRecording.swift D7)。
// W7 帧/深度计时统计(写入耗时分布、深度写入最慢一次)由 `timingSnapshot()` 交给会话层,
//    与 ARFrame 到达间隔一起落 recorder_timing.json —— 「开深度不扰动 VIO 流」要**量**出来。
// W8 交叉检查只留源 check() 的现行判据(有限、fx/fy>0、主点离画面中心 ≤ 24 px);源
//    intrinsics_observed.json 里「上游 640×480 ×3」那组对照源自己的注释已判为无意义,不再写。
// W9 录完的**尺子子集导出**(`exportRulerSubset`,录制封口之后跑,不在采集路径上):只把带深度、
//    间隔 ≥ spacing 的那些帧的 luma 拷成一份小 frames.bin,深度三件套硬链接过去。
//    理由:30 s 录制 frames.bin ≈ 5 GB,Mac 盘常年只剩 2–4 GiB,拉不回来;尺子只要几十帧。
// W10 [2026-09-24 rec30] 每帧落盘的同步方式可选(`PwBenchLidarWriteSync`),默认见 `defaultWriteSync`。
//    源(= `fsync_each`)每帧对流、索引各 `synchronize()`(fsync)一次。真机首跑 run-fb5d3a8f
//    (1920×1440 @60,166 MB/s)从 17.8 s 起队列 64 格打满、丢 341/1791 帧,写入最慢 548 ms、p99 94 ms。
//    Apple「Reducing disk writes」(developer.apple.com/documentation/xcode/reducing-disk-writes)原话:
//    「Writing data on iOS adds the data to a unified buffer cache that the system then writes to file
//    storage. Forcing iOS to flush pending filesystem changes from the unified buffer can result in
//    unnecessary writes to the disk, degrading performance … When possible, avoid calling fsync(_:) …
//    Some apps require a write barrier to ensure data persistence before subsequent operations can
//    proceed. Most apps can use the fcntl(_:_:) F_BARRIERFSYNC for this.」
//    ⇒ `barrier`:流写完发 F_BARRIERFSYNC(流先于索引这条次序仍由屏障保证,即源「索引永不指向没提交
//       的字节」),索引行不再 fsync;`none`:每帧都不同步,封口时各 fsync 一次;
//       `barrier_nocache`:`barrier` + 流句柄 F_NOCACHE(Apple File System Programming Guide
//       「Performance Tips」:只读一次的大文件别进文件缓存 ——「you can quickly fill up the disk cache
//       with data you won't use again」;那句是讲读的,用到写上是外推,单列一臂量)。
//    四种写法落盘字节逐位相同(Mac 单测核);差别只在计时。用哪种由台架「写入吞吐自测」在真机上量。
// W11 [2026-09-24 rec30] 逐秒时间线(`perSecondTimeline`):每秒交来 / 收下 / 丢的帧、写入耗时分位、
//    在途峰值、写入 MB —— 「从第几秒开始掉速」要能看出来,不能只有全场分位。
// W12 [2026-09-24 rec30] 尺子子集只挑 **XRSLAM 回放会收的帧**(`xrslamAdmittedFrames`):回放装载器
//    丢掉第一条 IMU 之前的相机帧、按 limitFrames 取前缀,再过 PwXrslamLive 的 30 Hz 准入闸
//    (`PwXrslamOfficialFeed.admits`,台架 App 里导出时直接传它进来;Mac 宿主用本文件的逐式拷贝
//    `xrslamGateCopy`,并用手机回放真账 intrinsics_ledger.csv 逐帧核过)。录制器按同一道闸 30 Hz
//    落盘时所有录下的帧都会被收(闸幂等);老的 60 Hz 录制靠这条仍能导出「每帧都有引擎位姿」的子集。
//
// ══ Android(不在本次范围,只记映射)═══════════════════════════════════════════════
// ARCore Depth API:Frame.acquireDepthImage16Bits()(DEPTH16,毫米)/ acquireRawDepthImage16Bits()
// + acquireRawDepthConfidenceImage();Config.DepthMode.AUTOMATIC / RAW_DEPTH_ONLY。🔴 大多数安卓机
// 的 ARCore 深度来自**运动恢复深度(depth-from-motion)**,只在带 ToF 的机型上用硬件 ——
// 那它的尺度就是 ARCore 自己 VIO 的尺度,**不能**当独立米尺。安卓上只有带 ToF 的机型才可能照搬本尺子。

import CoreVideo
import CryptoKit
import Foundation
import QuartzCore

/// [port] BenchResolution.swift:98 CameraIntrinsics(子集)
struct PwBenchLidarIntrinsics: Equatable, Sendable {
    var fx: Double
    var fy: Double
    var cx: Double
    var cy: Double

    var isFinite: Bool { fx.isFinite && fy.isFinite && cx.isFinite && cy.isFinite }
}

/// [port] BenchResolution.swift:142-236 ARKitIntrinsicsCrossCheck.check —— 现行判据原样(W8)。
enum PwBenchLidarIntrinsicsCrossCheck {
    /// [port] :172 principalPointToleranceP
    static let principalPointTolerancePixels: Double = 24.0

    /// nil = agrees;否则是源 `Verdict.reason` 的同名字符串。
    static func check(_ k: PwBenchLidarIntrinsics, frameWidth: Int, frameHeight: Int) -> String? {
        guard k.isFinite else { return "arkit_intrinsics_non_finite" }
        guard k.fx > 0, k.fy > 0 else { return "arkit_intrinsics_disagree_fx" }
        for (name, reported, centre) in [
            ("cx", k.cx, Double(frameWidth) / 2),
            ("cy", k.cy, Double(frameHeight) / 2),
        ] where abs(reported - centre) > principalPointTolerancePixels {
            return "arkit_intrinsics_disagree_\(name)"
        }
        return nil
    }
}

/// W10:每帧落盘的同步方式。四种写出的字节逐位相同,只差在什么时候、怎样把数据推到存储上。
enum PwBenchLidarWriteSync: String, CaseIterable, Sendable {
    /// 源 @76b8d47:流 fsync → 索引行 → 索引 fsync(每帧两次 fsync)。
    case fsyncEach = "fsync_each"
    /// Apple「Reducing disk writes」:流 → F_BARRIERFSYNC(次序屏障)→ 索引行(不 fsync)。
    case barrier = "barrier"
    /// `barrier` + 流句柄 F_NOCACHE。
    case barrierNoCache = "barrier_nocache"
    /// Apple「avoid calling fsync」:每帧都不同步;封口时各 fsync 一次。
    case none = "none"
}

/// 录制器自己的错误(装载器那份 DeviceRecordingError 只收读侧的分支)。
enum PwBenchLidarRecorderError: Error, Equatable, LocalizedError {
    case insufficientFreeSpace(requiredBytes: Int64, availableBytes: Int64)
    /// [port] DeviceRecordingTypes.swift:312-317 noFramesCaptured
    case noFramesCaptured
    case intrinsicsCrossCheckFailed(reason: String)
    case subsetExport(String)

    var errorDescription: String? {
        switch self {
        case .insufficientFreeSpace(let required, let available):
            // [port] DeviceRecordingTypes.swift:340-348 原文
            return String(
                format: "存储空间不足:本次录制需要 %.1f GiB(含余量),设备可用 %.1f GiB,还差 %.1f GiB。"
                    + "请清理空间,或改用更短的录制时长。",
                Double(required) / 1_073_741_824,
                Double(available) / 1_073_741_824,
                Double(max(0, required - available)) / 1_073_741_824)
        case .noFramesCaptured:
            return "the session produced no frames, so there are no intrinsics to record"
        case .intrinsicsCrossCheckFailed(let r):
            return "ARKit intrinsics cannot describe the frames they arrived with (\(r))"
        case .subsetExport(let s):
            return "ruler subset export failed: \(s)"
        }
    }
}

/// [port] DeviceRecordingWriter.swift:21-944(偏离 W1–W9 见文件头)
final class PwBenchLidarRecordingWriter: @unchecked Sendable {

    /// [port] :23-31 —— 64 格(1920×1440 下 177 MB 上限),溢出即丢失、即作废。
    static let queueDepth = 64

    /// [port] :33-43
    static let freeSpaceHeadroomBytes: Int64 = 512 * 1024 * 1024

    // MARK: 🔴 bench-only ruler 常量([port] DeviceRecordingTypes.swift:231-249)

    static let depthStreamPath = "depth.bin"
    static let depthConfidencePath = "depth_conf.bin"
    static let depthIndexPath = "depth.pwvi"
    /// ARDepthData.depthMap 在本台架机型上的尺寸;只用于起录前的空间预估,读者从不信它。
    static let expectedDepthWidth = 256
    static let expectedDepthHeight = 192
    /// [port] :145-152 —— 深度自己的背压上限(240 KiB/格)。
    static let depthQueueDepth = 120
    /// [port] :154-158 —— float32 米 + uint8 置信度。
    static let depthBytesPerFrame = expectedDepthWidth * expectedDepthHeight * 5
    /// W3:默认每 3 个**录下的**帧一张深度(rec30:30 Hz 录制 ⇒ 10 Hz,与原来 60 fps 每 6 帧同一频率)。
    static let defaultDepthStride = 3
    /// W10:默认写法(真机「写入吞吐自测」量出来之后定;见交付报告)。
    static let defaultWriteSync: PwBenchLidarWriteSync = .barrier
    /// W4:Apple 文档给的运行时格式。
    static let depthPixelFormat: OSType = kCVPixelFormatType_DepthFloat32
    static let confidencePixelFormat: OSType = kCVPixelFormatType_OneComponent8

    private let directory: URL
    private var format: DeviceRecordingCameraFormat
    private let recordingID: String

    /// [port] :50-56
    private let writeQueue = DispatchQueue(
        label: "com.kyle.arloopbench.lidar.recording.write", qos: .userInitiated)
    /// W2:深度自己的串行队列。
    private let depthWriteQueue = DispatchQueue(
        label: "com.kyle.arloopbench.lidar.recording.depth", qos: .utility)
    private let stateLock = NSLock()

    private var framesHandleDigest = SHA256()
    private var cameraIndexRows: [String] = []
    private let framesStream: FileHandle
    private let framesIndex: FileHandle
    private var streamOffset = 0

    private var sealed = false
    private var lateAfterSeal = 0
    private var intrinsicsRows: [String] = []
    private var focalMinimum = Double.greatestFiniteMagnitude
    private var focalMaximum = 0.0
    private var imuRows: [String] = []
    private var arkitPoseRows: [String] = []

    private var frameCount = 0
    private var framesTotalBytes: Int64 = 0
    private var lossCount = 0
    private var lossFormatMismatch = 0
    private var lossWriteQueueFull = 0
    private var lossWriteError = 0
    private var peakInFlight = 0
    private var slowestWriteMilliseconds: Double = 0
    private var writeMillisecondsSamples: [Double] = []
    private var inFlight = 0
    private var firstError: Error?

    private var intrinsics: DeviceRecordingIntrinsics?

    // W10 / W11
    let writeSync: PwBenchLidarWriteSync
    /// F_BARRIERFSYNC / F_NOCACHE 返回 −1 的次数(屏障失败时退回 fsync,仍保次序)。
    private var barrierFallbacks = 0
    private var noCacheSetFailed = false
    /// 逐帧事件(CACurrentMediaTime 秒):交来(收下或丢)、写完 + 耗时、交来时的在途数。
    private var offeredAt: [Double] = []
    private var offeredAccepted: [Bool] = []
    private var offeredInFlight: [Int] = []
    private var writeDoneAt: [Double] = []
    private var writeDoneMs: [Double] = []
    private var writeDoneBytes: [Int] = []

    // MARK: - Depth(🔴 bench-only ruler)[port] :108-143

    /// 🔴 **bench-only ruler,永远不是产品输入。** 同一 ARFrame 上 ARKit 交回的 LiDAR 深度,
    /// 留给离线工具给轨迹一个**米制**尺度。句柄第一张深度帧到了才开 ⇒ 没有 LiDAR 的机器
    /// 不留三个空文件,manifest 里 depth_present:false 是关于世界的陈述。
    private var depthStream: FileHandle?
    private var depthConfidenceStream: FileHandle?
    private var depthIndex: FileHandle?
    private var depthWidth = 0
    private var depthHeight = 0
    private var depthFrameCount = 0
    private var depthFramesWritten = 0
    private var depthStreamOffset = 0
    private var depthConfidenceOffset = 0
    private var depthDigest = SHA256()
    private var depthConfidenceDigest = SHA256()
    private var depthTotalBytes: Int64 = 0
    private var depthConfidenceTotalBytes: Int64 = 0
    private var depthConfidenceSeen = false
    private var depthDropped = 0
    private var depthFormatMismatch = 0
    private var depthInFlight = 0
    private var depthPeakInFlight = 0
    private var depthSlowestWriteMilliseconds: Double = 0
    private var depthSource: String?
    let depthStride: Int
    /// 🔬 只给 Mac 宿主的 A/B 测量用(tool/bench/lidar_swift_tests):true = 回到源的做法,深度与相机帧
    /// 共用 writeQueue 一条 FIFO,用来量 W2 这条偏离到底省了什么。台架 App 里没有任何代码设它。
    var depthUsesSharedFrameQueue = false

    init(
        directory: URL,
        recordingID: String,
        format: DeviceRecordingCameraFormat,
        depthStride: Int = PwBenchLidarRecordingWriter.defaultDepthStride,
        writeSync: PwBenchLidarWriteSync = PwBenchLidarRecordingWriter.defaultWriteSync
    ) throws {
        self.directory = directory
        self.format = format
        self.recordingID = recordingID
        self.depthStride = max(1, depthStride)
        self.writeSync = writeSync
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let streamURL = directory.appendingPathComponent(DeviceRecordingManifest.framesStreamPath)
        let indexURL = directory.appendingPathComponent(DeviceRecordingManifest.framesIndexPath)
        FileManager.default.createFile(atPath: streamURL.path, contents: nil)
        FileManager.default.createFile(atPath: indexURL.path, contents: nil)
        self.framesStream = try FileHandle(forWritingTo: streamURL)
        self.framesIndex = try FileHandle(forWritingTo: indexURL)
        if writeSync == .barrierNoCache {
            noCacheSetFailed = fcntl(framesStream.fileDescriptor, F_NOCACHE, 1) == -1
        }
    }

    /// W10:流写完之后、它的索引行写之前。`fsync_each` = 源的 synchronize();`barrier*` = F_BARRIERFSYNC
    /// (失败退回 fsync 并计数);`none` = 不做。只在各自的串行写队列上调用。
    private func syncStreamBeforeIndex(_ handle: FileHandle) throws {
        switch writeSync {
        case .fsyncEach:
            try handle.synchronize()
        case .barrier, .barrierNoCache:
            if fcntl(handle.fileDescriptor, F_BARRIERFSYNC) == -1 {
                stateLock.lock(); barrierFallbacks += 1; stateLock.unlock()
                try handle.synchronize()
            }
        case .none:
            break
        }
    }

    /// W10:索引行写完之后。只有源的写法每帧再 fsync 索引。
    private func syncIndexAfterRow(_ handle: FileHandle) throws {
        if writeSync == .fsyncEach { try handle.synchronize() }
    }

    // MARK: - Preflight [port] :204-251

    /// `depthStride` 0 = 不录深度;否则按每 stride 帧一张深度计价(W3)。
    static func projectedByteCount(
        seconds: Double,
        format: DeviceRecordingCameraFormat,
        depthStride: Int
    ) -> Int64 {
        let frames = Int64((seconds * format.nominalFPS).rounded(.up))
        var bytes = frames * Int64(format.bytesPerFrame)
        if depthStride > 0 {
            let depthFrames = (frames + Int64(depthStride) - 1) / Int64(depthStride)
            bytes += depthFrames * Int64(depthBytesPerFrame)
        }
        return bytes
    }

    static func checkFreeSpace(at url: URL, requiredBytes: Int64) throws {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        let available = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        let needed = requiredBytes + freeSpaceHeadroomBytes
        guard available >= needed else {
            throw PwBenchLidarRecorderError.insufficientFreeSpace(
                requiredBytes: needed, availableBytes: available)
        }
    }

    func setNominalFPS(_ fps: Double) {
        guard fps > 0 else { return }
        stateLock.lock()
        format.nominalFPS = fps
        stateLock.unlock()
    }

    // MARK: - Intrinsics [port] :253-370(W6 / W8)

    func recordIntrinsics(
        _ reported: PwBenchLidarIntrinsics,
        timestampSeconds: Double,
        exposureSeconds: Double? = nil,
        arkitTracking: String? = nil,
        source: String = "ARFrame.camera.intrinsics"
    ) throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        if reported.fx.isFinite, reported.fx > 0 {
            focalMinimum = min(focalMinimum, reported.fx)
            focalMaximum = max(focalMaximum, reported.fx)
        }
        let exposureField: String
        if let e = exposureSeconds, e.isFinite, e >= 0 {
            exposureField = ",\"exposure_s\":\(e)"
        } else {
            exposureField = ""
        }
        let trackingField = arkitTracking.map { ",\"arkit_tracking\":\"\($0)\"" } ?? ""
        intrinsicsRows.append(
            "{\"t\":\(timestampSeconds),\"intrinsics_fxfycxcy\":"
                + "[\(reported.fx),\(reported.fy),\(reported.cx),\(reported.cy)]"
                + exposureField + trackingField + "}")

        guard intrinsics == nil else { return }
        let reason = PwBenchLidarIntrinsicsCrossCheck.check(
            reported, frameWidth: format.width, frameHeight: format.height)
        let observed: [String: Any] = [
            "intrinsics_source": source,
            "arkit_reported": ["fx": reported.fx, "fy": reported.fy,
                               "cx": reported.cx, "cy": reported.cy],
            "frame_width": format.width,
            "frame_height": format.height,
            "principal_point_tolerance_pixels":
                PwBenchLidarIntrinsicsCrossCheck.principalPointTolerancePixels,
            "agrees": reason == nil,
            "reason": reason ?? "agrees",
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: observed, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: directory.appendingPathComponent("intrinsics_observed.json"),
                            options: .atomic)
        }
        if let reason { throw PwBenchLidarRecorderError.intrinsicsCrossCheckFailed(reason: reason) }
        intrinsics = DeviceRecordingIntrinsics(
            fx: reported.fx, fy: reported.fy, cx: reported.cx, cy: reported.cy,
            source: source, crossCheckPassed: true)
    }

    // MARK: - Ingest [port] :372-481

    /// 返回这一帧在 frames.pwvi 里的帧号;没收下(格式不对 / 背压 / 已封口)⇒ nil。
    @discardableResult
    func appendFrame(pixelBuffer: CVPixelBuffer, timestampNanoseconds: Int64) -> Int? {
        guard let luma = Self.copyLumaPlane(pixelBuffer, expected: format) else {
            stateLock.lock()
            lossCount += 1
            lossFormatMismatch += 1
            stateLock.unlock()
            return nil
        }
        return enqueue(luma: luma, timestampNanoseconds: timestampNanoseconds)
    }

    /// [port] :393-415 —— 调用方已持有的灰度平面(Mac 宿主测试走这条)。
    @discardableResult
    func appendLuma(_ luma: Data, timestampNanoseconds: Int64) -> Int? {
        guard luma.count == format.bytesPerFrame else {
            stateLock.lock()
            lossCount += 1
            lossFormatMismatch += 1
            stateLock.unlock()
            return nil
        }
        return enqueue(luma: luma, timestampNanoseconds: timestampNanoseconds)
    }

    private func enqueue(luma: Data, timestampNanoseconds: Int64) -> Int? {
        stateLock.lock()
        guard !sealed else {
            lateAfterSeal += 1
            stateLock.unlock()
            return nil
        }
        let now = CACurrentMediaTime()
        guard inFlight < Self.queueDepth else {
            // 背压即丢失,丢失即作废;不靠加深队列、不跳帧吸收。
            lossCount += 1
            lossWriteQueueFull += 1
            offeredAt.append(now); offeredAccepted.append(false); offeredInFlight.append(inFlight)
            stateLock.unlock()
            return nil
        }
        let index = frameCount
        frameCount += 1
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        cameraIndexRows.append("\(timestampNanoseconds),\(index)")
        offeredAt.append(now); offeredAccepted.append(true); offeredInFlight.append(inFlight)
        stateLock.unlock()

        writeQueue.async { [weak self] in
            guard let self else { return }
            let writeStart = CACurrentMediaTime()
            do {
                // 流先、索引后(pwva.dart 的次序):任何时刻被打断,索引都不会指向没提交的字节。
                // W10:「流已提交」由 syncStreamBeforeIndex 保证(fsync 或 F_BARRIERFSYNC;none 臂不保)。
                let offset = self.streamOffset
                try self.framesStream.write(contentsOf: luma)
                try self.syncStreamBeforeIndex(self.framesStream)
                let row = "{\"frame\":\(index),\"offset\":\(offset)," +
                    "\"len\":\(luma.count),\"keyframe\":true,\"gop\":\(index)}\n"
                try self.framesIndex.write(contentsOf: Data(row.utf8))
                try self.syncIndexAfterRow(self.framesIndex)
                let done = CACurrentMediaTime()
                let elapsed = (done - writeStart) * 1000
                self.stateLock.lock()
                self.streamOffset = offset + luma.count
                self.slowestWriteMilliseconds = max(self.slowestWriteMilliseconds, elapsed)
                self.writeMillisecondsSamples.append(elapsed)
                self.writeDoneAt.append(done); self.writeDoneMs.append(elapsed)
                self.writeDoneBytes.append(luma.count)
                self.framesHandleDigest.update(data: luma)
                self.framesTotalBytes += Int64(luma.count)
                self.inFlight -= 1
                self.stateLock.unlock()
            } catch {
                self.stateLock.lock()
                self.lossCount += 1
                self.lossWriteError += 1
                self.inFlight -= 1
                if self.firstError == nil { self.firstError = error }
                self.stateLock.unlock()
            }
        }
        return index
    }

    /// 🔴 **bench-only ruler,永远不是产品输入。** [port] :483-624(W2 / W4 / W5)
    ///
    /// `depthMap` = ARDepthData.depthMap。Apple 概述原话:「Every pixel in the depthMap maps to a
    /// region of the visible scene (capturedImage), where the pixel value defines that region's
    /// distance from the plane of the camera in meters.」
    /// (developer.apple.com/documentation/arkit/ardepthdata)⇒ 相机平面 z 深度,可与三角化点的
    /// Z 直接相除。WWDC20-10611 原话:这张稠密深度图是广角 RGB 与 LiDAR 读数「fused together using
    /// advanced machine learning algorithms」得来,「available at 60 Hz, associated with each AR
    /// frame」⇒ 它与 capturedImage 同帧同时间戳,置信度图说明每像素有多少 LiDAR 支撑。
    ///
    /// `smoothedSceneDepth` 不录:Apple 原话它是「the framework smoothes the depth data over time
    /// to lessen its frame-to-frame delta」(…/arframe/smoothedscenedepth)—— 跨帧时域平滑 ⇒
    /// 某一帧的值掺了之前帧的几何,与这一帧的位姿不再一一对应;尺子要的是这一帧自己的测量,
    /// 且不能是另一个估计器的输出(源同一理由拒 CMDeviceMotion)。
    ///
    /// 深度帧留不下 ⇒ 计 depth_dropped,**不**作废录制(没有臂在它上面计分)。
    func appendDepth(
        depthMap: CVPixelBuffer,
        confidenceMap: CVPixelBuffer?,
        timestampNanoseconds: Int64,
        cameraFrameIndex: Int?,
        arFrameIndex: Int,
        imageIntrinsics: PwBenchLidarIntrinsics?,
        admittedFrameIndex: Int? = nil,
        source: String = "ARFrame.sceneDepth"
    ) {
        // rec30:这一帧在「过了 30 Hz 准入闸的帧」里的序号(深度步长按它数)。
        let admittedField = admittedFrameIndex.map { ",\"admitted_frame\":\($0)" } ?? ""
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        // W4:像素格式核实再拷。
        guard CVPixelBufferGetPixelFormatType(depthMap) == Self.depthPixelFormat else {
            stateLock.lock(); depthDropped += 1; depthFormatMismatch += 1; stateLock.unlock()
            return
        }
        guard width > 0, height > 0,
              let depth = Self.copyTightly(depthMap, bytesPerPixel: 4) else {
            stateLock.lock(); depthDropped += 1; stateLock.unlock()
            return
        }
        var confidence: Data?
        if let confidenceMap {
            guard CVPixelBufferGetPixelFormatType(confidenceMap) == Self.confidencePixelFormat else {
                stateLock.lock(); depthDropped += 1; depthFormatMismatch += 1; stateLock.unlock()
                return
            }
            guard CVPixelBufferGetWidth(confidenceMap) == width,
                  CVPixelBufferGetHeight(confidenceMap) == height,
                  let bytes = Self.copyTightly(confidenceMap, bytesPerPixel: 1) else {
                stateLock.lock(); depthDropped += 1; stateLock.unlock()
                return
            }
            confidence = bytes
        }

        stateLock.lock()
        guard !sealed else {
            lateAfterSeal += 1
            stateLock.unlock()
            return
        }
        if depthFrameCount == 0 {
            depthWidth = width
            depthHeight = height
            depthSource = source
        } else if width != depthWidth || height != depthHeight {
            depthDropped += 1
            stateLock.unlock()
            return
        }
        guard depthInFlight < Self.depthQueueDepth else {
            depthDropped += 1
            stateLock.unlock()
            return
        }
        let index = depthFrameCount
        depthFrameCount += 1
        depthInFlight += 1
        depthPeakInFlight = max(depthPeakInFlight, depthInFlight)
        if confidence != nil { depthConfidenceSeen = true }
        let imageW = format.width, imageH = format.height
        stateLock.unlock()

        // W5:同一行写上这一帧的图像内参与换算后的深度图内参(推论,见文件头)。
        var kFields = ",\"image_w\":\(imageW),\"image_h\":\(imageH)"
        if let k = imageIntrinsics, k.isFinite {
            let rx = Double(width) / Double(imageW)
            let ry = Double(height) / Double(imageH)
            kFields += ",\"k_image\":[\(k.fx),\(k.fy),\(k.cx),\(k.cy)]"
            kFields += ",\"k_depth\":[\(k.fx * rx),\(k.fy * ry),"
                + "\((k.cx + 0.5) * rx - 0.5),\((k.cy + 0.5) * ry - 0.5)]"
        }
        let cameraFrame = cameraFrameIndex ?? -1

        (depthUsesSharedFrameQueue ? writeQueue : depthWriteQueue).async { [weak self] in
            guard let self else { return }
            let writeStart = CACurrentMediaTime()
            do {
                try self.openDepthHandlesIfNeeded()
                guard let stream = self.depthStream, let indexHandle = self.depthIndex else {
                    self.stateLock.lock()
                    self.depthDropped += 1
                    self.depthInFlight -= 1
                    self.stateLock.unlock()
                    return
                }
                // 流 → 置信度 → 索引行,与 frames.bin / frames.pwvi 同一次序。
                let offset = self.depthStreamOffset
                try stream.write(contentsOf: depth)
                try self.syncStreamBeforeIndex(stream)
                var confidenceOffset = -1
                var confidenceLength = 0
                if let confidence, let confidenceStream = self.depthConfidenceStream {
                    confidenceOffset = self.depthConfidenceOffset
                    confidenceLength = confidence.count
                    try confidenceStream.write(contentsOf: confidence)
                    try self.syncStreamBeforeIndex(confidenceStream)
                }
                let row = "{\"frame\":\(index),\"offset\":\(offset),"
                    + "\"len\":\(depth.count),\"t_ns\":\(timestampNanoseconds),"
                    + "\"w\":\(width),\"h\":\(height),"
                    + "\"conf_offset\":\(confidenceOffset),"
                    + "\"conf_len\":\(confidenceLength),"
                    + "\"camera_frame\":\(cameraFrame),\"ar_frame\":\(arFrameIndex)"
                    + admittedField + kFields + "}\n"
                try indexHandle.write(contentsOf: Data(row.utf8))
                try self.syncIndexAfterRow(indexHandle)
                let elapsed = (CACurrentMediaTime() - writeStart) * 1000
                self.stateLock.lock()
                self.depthStreamOffset = offset + depth.count
                self.depthConfidenceOffset += confidenceLength
                self.depthDigest.update(data: depth)
                self.depthTotalBytes += Int64(depth.count)
                if let confidence {
                    self.depthConfidenceDigest.update(data: confidence)
                    self.depthConfidenceTotalBytes += Int64(confidence.count)
                }
                self.depthFramesWritten += 1
                self.depthInFlight -= 1
                self.depthSlowestWriteMilliseconds = max(self.depthSlowestWriteMilliseconds, elapsed)
                self.stateLock.unlock()
            } catch {
                // 从不设 firstError:深度写失败只损失尺子,不损失录制。
                self.stateLock.lock()
                self.depthDropped += 1
                self.depthInFlight -= 1
                self.stateLock.unlock()
            }
        }
    }

    /// [port] :626-645 —— 只在 depthWriteQueue(串行)上调用。
    private func openDepthHandlesIfNeeded() throws {
        guard depthStream == nil else { return }
        let stream = directory.appendingPathComponent(Self.depthStreamPath)
        let confidence = directory.appendingPathComponent(Self.depthConfidencePath)
        let index = directory.appendingPathComponent(Self.depthIndexPath)
        for url in [stream, confidence, index] {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        depthStream = try FileHandle(forWritingTo: stream)
        depthConfidenceStream = try FileHandle(forWritingTo: confidence)
        depthIndex = try FileHandle(forWritingTo: index)
    }

    /// [port] :647-655
    func appendIMU(
        timestampNanoseconds: Int64,
        gyroscope: (x: Double, y: Double, z: Double),
        acceleration: (x: Double, y: Double, z: Double)
    ) {
        let row = "\(timestampNanoseconds),\(gyroscope.x),\(gyroscope.y),\(gyroscope.z),"
            + "\(acceleration.x),\(acceleration.y),\(acceleration.z)"
        stateLock.lock(); imuRows.append(row); stateLock.unlock()
    }

    /// [port] :657-661
    func appendARKitPose(timestampNanoseconds: Int64, tumRow: String) {
        stateLock.lock(); arkitPoseRows.append(tumRow); stateLock.unlock()
    }

    // MARK: - Timing(W7)

    struct TimingSnapshot {
        var frameWriteMilliseconds: [Double]
        var slowestFrameWriteMilliseconds: Double
        var slowestDepthWriteMilliseconds: Double
        var peakInFlight: Int
        var depthPeakInFlight: Int
        var lossCount: Int
        var lossWriteQueueFull: Int
        var depthDropped: Int
        var depthFormatMismatch: Int
        var frameCount: Int
        var depthFramesWritten: Int
        var writeSync: String
        var barrierFallbacks: Int
        var noCacheSetFailed: Bool
    }

    func timingSnapshot() -> TimingSnapshot {
        stateLock.lock(); defer { stateLock.unlock() }
        return TimingSnapshot(
            frameWriteMilliseconds: writeMillisecondsSamples,
            slowestFrameWriteMilliseconds: slowestWriteMilliseconds,
            slowestDepthWriteMilliseconds: depthSlowestWriteMilliseconds,
            peakInFlight: peakInFlight,
            depthPeakInFlight: depthPeakInFlight,
            lossCount: lossCount,
            lossWriteQueueFull: lossWriteQueueFull,
            depthDropped: depthDropped,
            depthFormatMismatch: depthFormatMismatch,
            frameCount: frameCount,
            depthFramesWritten: depthFramesWritten,
            writeSync: writeSync.rawValue,
            barrierFallbacks: barrierFallbacks,
            noCacheSetFailed: noCacheSetFailed)
    }

    /// W11:逐秒时间线,秒号 = ⌊(事件时刻 − 第一次交帧时刻)⌋。每秒:交来 / 收下 / 丢(队列满)的帧数、
    /// 交来时的在途峰值、这一秒写完的帧的写入耗时 p50 / max、写完字节(MB)。
    /// 「写入 MB/s」是按**写完时刻**分桶的;队列在排、丢帧在涨的那几秒就是存储跟不上的那几秒。
    func perSecondTimeline() -> [[String: Any]] {
        stateLock.lock()
        let oa = offeredAt, ok = offeredAccepted, oi = offeredInFlight
        let wa = writeDoneAt, wm = writeDoneMs, wb = writeDoneBytes
        stateLock.unlock()
        guard let origin = oa.first else { return [] }
        let last = max(oa.last ?? origin, wa.last ?? origin)
        let n = Int(last - origin) + 1
        var offered = [Int](repeating: 0, count: n), accepted = offered, lost = offered, peak = offered
        var ms = [[Double]](repeating: [], count: n)
        var bytes = [Int](repeating: 0, count: n)
        for i in oa.indices {
            let s = min(n - 1, max(0, Int(oa[i] - origin)))
            offered[s] += 1
            if ok[i] { accepted[s] += 1 } else { lost[s] += 1 }
            peak[s] = max(peak[s], oi[i])
        }
        for i in wa.indices {
            let s = min(n - 1, max(0, Int(wa[i] - origin)))
            ms[s].append(wm[i]); bytes[s] += wb[i]
        }
        return (0..<n).map { s in
            let sorted = ms[s].sorted()
            var row: [String: Any] = ["s": s, "offered": offered[s], "accepted": accepted[s],
                                      "lost_queue_full": lost[s], "peak_in_flight": peak[s],
                                      "written": sorted.count,
                                      "written_mb": Double(bytes[s]) / 1_000_000]
            if !sorted.isEmpty {
                row["write_ms_p50"] = sorted[sorted.count / 2]
                row["write_ms_max"] = sorted.last!
            }
            return row
        }
    }

    // MARK: - Finish [port] :693-871

    @discardableResult
    func finish() throws -> DeviceRecordingManifest {
        // 先封口再排空([port] :700-707 的理由:封口前排空会让排空期间到的帧被写进、却没被计进总数)。
        stateLock.lock()
        sealed = true
        stateLock.unlock()
        writeQueue.sync {}
        depthWriteQueue.sync {}   // W2

        stateLock.lock()
        if let firstError { stateLock.unlock(); throw firstError }
        let manifestFrameCount = frameCount
        let archiveBytes = framesTotalBytes
        let archiveDigest = Self.hex(framesHandleDigest.finalize())
        let losses = lossCount
        let lossesFormat = lossFormatMismatch
        let lossesQueueFull = lossWriteQueueFull
        let lossesWriteError = lossWriteError
        let peak = peakInFlight
        let slowestWrite = slowestWriteMilliseconds
        let lateSeal = lateAfterSeal
        let cameraCSV = (["timestamp_ns,relative_path"] + cameraIndexRows).joined(separator: "\n") + "\n"
        let imuCSV = (["timestamp_ns,wx,wy,wz,ax,ay,az"] + imuRows).joined(separator: "\n") + "\n"
        let poseTUM = arkitPoseRows.joined(separator: "\n") + "\n"
        let intrinsicsJSONL = intrinsicsRows.joined(separator: "\n") + "\n"
        let focalLow = focalMinimum == .greatestFiniteMagnitude ? 0 : focalMinimum
        let focalHigh = focalMaximum
        let capturedIntrinsics = intrinsics
        let imuCount = imuRows.count
        let depthFrames = depthFramesWritten
        let depthW = depthWidth
        let depthH = depthHeight
        let depthBytes = depthTotalBytes
        let depthConfidenceBytes = depthConfidenceTotalBytes
        let depthSHA = Self.hex(depthDigest.finalize())
        let depthConfidenceSHA = Self.hex(depthConfidenceDigest.finalize())
        let depthHadConfidence = depthConfidenceSeen
        let depthDrops = depthDropped
        let depthSourceName = depthSource
        stateLock.unlock()

        guard let capturedIntrinsics else { throw PwBenchLidarRecorderError.noFramesCaptured }

        var files: [DeviceRecordingFile] = []
        for (role, path, contents) in [
            (DeviceRecordingFileRole.cameraIndex, "camera_index.csv", cameraCSV),
            (DeviceRecordingFileRole.intrinsicsIndex, "intrinsics.jsonl", intrinsicsJSONL),
            (DeviceRecordingFileRole.imuIndex, "imu.csv", imuCSV),
            (DeviceRecordingFileRole.arkitPoses, "arkit_poses.tum", poseTUM),
        ] {
            let data = Data(contents.utf8)
            try data.write(to: directory.appendingPathComponent(path), options: .atomic)
            files.append(DeviceRecordingFile(
                role: role, relativePath: path, byteCount: Int64(data.count),
                sha256: Self.hex(SHA256.hash(data: data))))
        }
        // W10:不逐帧 fsync 的写法在封口时各 fsync 一次(源的写法每帧都 fsync 过,这里是空操作)。
        if writeSync != .fsyncEach {
            try framesStream.synchronize()
            try framesIndex.synchronize()
        }
        try framesStream.close()
        try framesIndex.close()
        files.append(DeviceRecordingFile(
            role: .framesStream, relativePath: DeviceRecordingManifest.framesStreamPath,
            byteCount: archiveBytes, sha256: archiveDigest))
        let indexData = try Data(contentsOf: directory.appendingPathComponent(
            DeviceRecordingManifest.framesIndexPath))
        files.append(DeviceRecordingFile(
            role: .framesIndex, relativePath: DeviceRecordingManifest.framesIndexPath,
            byteCount: Int64(indexData.count), sha256: Self.hex(SHA256.hash(data: indexData))))

        // 🔴 bench-only ruler。这一段任何错误都不许抛出 finish():相机帧失败必须作废录制,
        // 深度失败不能 —— 否则一把 bench-only 的尺子能毁掉一场拍不回来的录制。[port] :790-830
        var depthDeclared = false
        if depthFrames > 0, depthStream != nil {
            if writeSync != .fsyncEach {
                try? depthStream?.synchronize()
                try? depthConfidenceStream?.synchronize()
                try? depthIndex?.synchronize()
            }
            try? depthStream?.close()
            try? depthConfidenceStream?.close()
            try? depthIndex?.close()
            if let depthIndexData = try? Data(contentsOf: directory.appendingPathComponent(
                Self.depthIndexPath)) {
                files.append(DeviceRecordingFile(
                    role: .depthStream, relativePath: Self.depthStreamPath,
                    byteCount: depthBytes, sha256: depthSHA))
                if depthHadConfidence {
                    files.append(DeviceRecordingFile(
                        role: .depthConfidenceStream, relativePath: Self.depthConfidencePath,
                        byteCount: depthConfidenceBytes, sha256: depthConfidenceSHA))
                }
                files.append(DeviceRecordingFile(
                    role: .depthIndex, relativePath: Self.depthIndexPath,
                    byteCount: Int64(depthIndexData.count),
                    sha256: Self.hex(SHA256.hash(data: depthIndexData))))
                depthDeclared = true
            }
        }
        files.sort { $0.relativePath < $1.relativePath }

        let manifest = DeviceRecordingManifest(
            schemaVersion: DeviceRecordingManifest.supportedSchemaVersion,
            recordingID: recordingID,
            camera: format,
            intrinsics: capturedIntrinsics,
            frameCount: manifestFrameCount,
            imuSampleCount: imuCount,
            framesDigestSHA256: archiveDigest,
            framesTotalByteCount: archiveBytes,
            lossCount: losses,
            lossFormatMismatch: lossesFormat,
            lossWriteQueueFull: lossesQueueFull,
            lossWriteError: lossesWriteError,
            peakInFlight: peak,
            slowestWriteMilliseconds: slowestWrite,
            focalLengthMinimum: focalLow,
            focalLengthMaximum: focalHigh,
            lateFramesAfterSeal: lateSeal,
            depthPresent: depthDeclared,
            depthWidth: depthDeclared ? depthW : nil,
            depthHeight: depthDeclared ? depthH : nil,
            depthFrameCount: depthDeclared ? depthFrames : 0,
            depthSource: depthDeclared ? depthSourceName : nil,
            depthConfidencePresent: depthDeclared ? depthHadConfidence : nil,
            depthDropped: depthDrops + (depthDeclared ? 0 : depthFrames),
            files: files)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent(DeviceRecordingManifest.fileName),
            options: .atomic)
        return manifest
    }

    // MARK: - Helpers [port] :873-943

    /// [port] :875-906 —— 420f 双平面的 Y 平面,逐行拷(bytesPerRow 常有填充)。
    static func copyLumaPlane(_ pixelBuffer: CVPixelBuffer, expected: DeviceRecordingCameraFormat) -> Data? {
        guard CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) == expected.width,
              CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) == expected.height else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        var out = Data(count: expected.bytesPerFrame)
        out.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            for row in 0..<expected.height {
                memcpy(destinationBase.advanced(by: row * expected.width),
                       base.advanced(by: row * stride), expected.width)
            }
        }
        return out
    }

    /// [port] :908-939 —— 非平面缓冲逐行拷成紧致字节(深度/置信度)。
    static func copyTightly(_ pixelBuffer: CVPixelBuffer, bytesPerPixel: Int) -> Data? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rowBytes = width * bytesPerPixel
        guard stride >= rowBytes else { return nil }
        var out = Data(count: rowBytes * height)
        out.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(destinationBase.advanced(by: row * rowBytes),
                       base.advanced(by: row * stride), rowBytes)
            }
        }
        return out
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - W9 尺子子集导出(录制封口之后,不在采集路径上)

    static let rulerSubsetDirectory = "ruler_subset"

    // MARK: - W12 XRSLAM 回放会收哪些帧

    /// (ptsSeconds, lastAdmittedPts, haveAdmitted, cameraHz) → 收不收。
    typealias XrslamGate = (Double, Double, Bool, Double) -> Bool

    /// `PwXrslamOfficialFeed.admits`(PwXrslamLive.swift)的**逐式拷贝**,只给 Mac 宿主(那边编不进
    /// PwXrslamLive.swift)。台架 App 里导出时传的是 `PwXrslamOfficialFeed.admits` 本身。
    /// 这份拷贝与引擎的实际取舍逐帧相等,由 LidarWriterTests 用手机回放真账核(run-fb5d3a8f)。
    static let xrslamGateCopy: XrslamGate = { pts, last, have, hz in
        guard hz > 0 else { return true }
        return !(have && pts - last < 0.8 / hz)
    }

    /// 手机回放(PwBenchReplay → PwXrslamLive.onCameraFrame)会**收**的录制帧号。逐步照抄回放:
    ///   ① 装载器按 camera_index.csv 行序取前 `limitFrames` 行(0 = 全部;DeviceRecordingLoader D8);
    ///   ② 按时间戳投递,丢掉早于第一条 IMU 的相机帧(装载器 [port] :312-332);
    ///   ③ 30 Hz 准入闸,pts = Double(t_ns)·1e-9(PwBenchReplay.swift 投递处的同一换算)。
    /// `cameraHz` ≤ 0 ⇒ 闸关着,②之后全收。
    static func xrslamAdmittedFrames(
        cameraRows: [(t: Int64, frame: Int)],
        firstImuNanoseconds: Int64?,
        limitFrames: Int = 0,
        cameraHz: Double,
        gate: XrslamGate = xrslamGateCopy
    ) -> (admitted: Set<Int>, fed: Int, leadingDropped: Int, gatedOut: Int) {
        var rows = cameraRows
        if limitFrames > 0 && rows.count > limitFrames { rows = Array(rows.prefix(limitFrames)) }
        rows.sort { $0.t < $1.t }
        var admitted = Set<Int>()
        var have = false
        var last = 0.0
        var fed = 0, leading = 0, gatedOut = 0
        for r in rows {
            if let imu0 = firstImuNanoseconds, r.t < imu0 { leading += 1; continue }
            fed += 1
            let pts = Double(r.t) * 1e-9
            guard gate(pts, last, have, cameraHz) else { gatedOut += 1; continue }
            have = true
            last = pts
            admitted.insert(r.frame)
        }
        return (admitted, fed, leading, gatedOut)
    }

    /// imu.csv 第一条数据行的时间戳(没有 IMU ⇒ nil,装载器此时也不丢任何相机帧)。
    static func firstImuNanoseconds(recording: URL) -> Int64? {
        guard let h = try? FileHandle(forReadingFrom: recording.appendingPathComponent("imu.csv")) else {
            return nil
        }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 4096),
              let text = String(data: head, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n")
        guard lines.count >= 2, let f = lines[1].split(separator: ",").first else { return nil }
        return Int64(f)
    }

    /// 从一份**已封口**的录制里挑出带深度、相邻间隔 ≥ `minSpacingSeconds`、**且 XRSLAM 回放会收**
    /// (W12)的相机帧,把它们的 luma
    /// 拷进 `<rec>/<outName>/frames.bin`(帧号保留、偏移重排),写对应的 frames.pwvi /
    /// camera_index.csv;深度三件套与小文件硬链接(同卷,不占空间),硬链接失败才拷贝。
    /// 离线尺子(tool/bench/lidar_ruler)对这个目录与对整份录制走同一条读取路径。
    /// 🔴 子集**不可回放**:拷过去的 recording_manifest.json 仍描述整份录制,回放装载器核
    /// frames.pwvi 哈希时会拒 —— 这是故意的,子集只给尺子。
    @discardableResult
    static func exportRulerSubset(
        recording: URL,
        minSpacingSeconds: Double,
        outName: String = rulerSubsetDirectory,
        xrslamCameraHz: Double = 30,
        limitFrames: Int = 0,
        gate: XrslamGate = xrslamGateCopy,
        gateSource: String = "PwBenchLidarRecordingWriter.xrslamGateCopy"
    ) throws -> [String: Any] {
        let fm = FileManager.default
        guard !outName.isEmpty, !outName.contains("/"), outName != "." , outName != ".." else {
            throw PwBenchLidarRecorderError.subsetExport("子集目录名不合法:\(outName)")
        }
        let out = recording.appendingPathComponent(outName)
        if fm.fileExists(atPath: out.path) { try fm.removeItem(at: out) }
        try fm.createDirectory(at: out, withIntermediateDirectories: true)

        let manifest = try JSONDecoder().decode(
            DeviceRecordingManifest.self,
            from: Data(contentsOf: recording.appendingPathComponent(DeviceRecordingManifest.fileName)))
        let frameBytes = manifest.camera.bytesPerFrame

        // frames.pwvi:帧号 → 偏移。
        var offsetByFrame: [Int: Int] = [:]
        let framesIndexText = try String(contentsOf: recording.appendingPathComponent(
            DeviceRecordingManifest.framesIndexPath), encoding: .utf8)
        for line in framesIndexText.split(separator: "\n") where !line.isEmpty {
            guard let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let f = (o["frame"] as? NSNumber)?.intValue,
                  let off = (o["offset"] as? NSNumber)?.intValue,
                  let len = ((o["len"] ?? o["length"]) as? NSNumber)?.intValue else {
                throw PwBenchLidarRecorderError.subsetExport("frames.pwvi 行无法解析")
            }
            guard len == frameBytes else {
                throw PwBenchLidarRecorderError.subsetExport("frames.pwvi 帧 \(f) 长度 \(len) ≠ \(frameBytes)")
            }
            offsetByFrame[f] = off
        }
        // camera_index.csv:时间戳 → 帧号。
        var frameByTimestamp: [Int64: Int] = [:]
        var cameraRows: [(t: Int64, frame: Int)] = []
        let cameraText = try String(contentsOf: recording.appendingPathComponent("camera_index.csv"),
                                    encoding: .utf8)
        for (n, line) in cameraText.split(separator: "\n").enumerated() where n > 0 && !line.isEmpty {
            let parts = line.split(separator: ",")
            guard parts.count == 2, let t = Int64(parts[0]), let f = Int(parts[1]) else {
                throw PwBenchLidarRecorderError.subsetExport("camera_index.csv 第 \(n + 1) 行无法解析")
            }
            frameByTimestamp[t] = f
            cameraRows.append((t, f))
        }
        // W12:XRSLAM 回放会收的帧。
        let imu0 = firstImuNanoseconds(recording: recording)
        let adm = xrslamAdmittedFrames(cameraRows: cameraRows, firstImuNanoseconds: imu0,
                                       limitFrames: limitFrames, cameraHz: xrslamCameraHz, gate: gate)
        // depth.pwvi 的时间戳(与相机帧同一个 ARFrame.timestamp ⇒ 精确相等)。
        let depthURL = recording.appendingPathComponent(depthIndexPath)
        guard fm.fileExists(atPath: depthURL.path) else {
            throw PwBenchLidarRecorderError.subsetExport("没有 depth.pwvi(这份录制没有深度)")
        }
        var depthStamps: [Int64] = []
        for line in try String(contentsOf: depthURL, encoding: .utf8).split(separator: "\n")
        where !line.isEmpty {
            if let o = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
               let t = (o["t_ns"] as? NSNumber)?.int64Value {
                depthStamps.append(t)
            }
        }
        depthStamps.sort()
        var picked: [(t: Int64, frame: Int)] = []
        var lastPicked: Int64 = .min
        var depthWithLuma = 0, depthNotAdmitted = 0
        let spacingNs = Int64((max(0, minSpacingSeconds) * 1e9).rounded())
        for t in depthStamps {
            guard let f = frameByTimestamp[t], offsetByFrame[f] != nil else { continue }
            depthWithLuma += 1
            // W12:XRSLAM 回放不收的帧没有引擎位姿 ⇒ 不进子集(尺子不插值)。
            guard adm.admitted.contains(f) else { depthNotAdmitted += 1; continue }
            if lastPicked != .min && t - lastPicked < spacingNs { continue }
            picked.append((t, f))
            lastPicked = t
        }
        guard !picked.isEmpty else {
            throw PwBenchLidarRecorderError.subsetExport(
                "没有一帧同时有 luma、深度且被 XRSLAM 回放收下(带深度帧 \(depthWithLuma),其中不被收 \(depthNotAdmitted))")
        }

        let source = try FileHandle(forReadingFrom: recording.appendingPathComponent(
            DeviceRecordingManifest.framesStreamPath))
        defer { try? source.close() }
        let subsetStreamURL = out.appendingPathComponent(DeviceRecordingManifest.framesStreamPath)
        fm.createFile(atPath: subsetStreamURL.path, contents: nil)
        let sink = try FileHandle(forWritingTo: subsetStreamURL)
        defer { try? sink.close() }
        var index = ""
        var camera = "timestamp_ns,relative_path\n"
        var digest = SHA256()
        var offset = 0
        for p in picked {
            try autoreleasepool {
                try source.seek(toOffset: UInt64(offsetByFrame[p.frame]!))
                guard let bytes = try source.read(upToCount: frameBytes), bytes.count == frameBytes else {
                    throw PwBenchLidarRecorderError.subsetExport("frames.bin 在帧 \(p.frame) 短读")
                }
                try sink.write(contentsOf: bytes)
                digest.update(data: bytes)
            }
            index += "{\"frame\":\(p.frame),\"offset\":\(offset),\"len\":\(frameBytes),"
                + "\"keyframe\":true,\"gop\":\(p.frame)}\n"
            camera += "\(p.t),\(p.frame)\n"
            offset += frameBytes
        }
        try sink.synchronize()
        try Data(index.utf8).write(to: out.appendingPathComponent(DeviceRecordingManifest.framesIndexPath))
        try Data(camera.utf8).write(to: out.appendingPathComponent("camera_index.csv"))

        var linked: [String] = []
        var copied: [String] = []
        for name in [DeviceRecordingManifest.fileName, "intrinsics.jsonl", "arkit_poses.tum",
                     "imu.csv", depthStreamPath, depthConfidencePath, depthIndexPath,
                     "depth_meta.json", "recorder_timing.json", "config.json",
                     "input_manifest.json", "calibration.json", "intrinsics_observed.json"] {
            let src = recording.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = out.appendingPathComponent(name)
            do {
                try fm.linkItem(at: src, to: dst)
                linked.append(name)
            } catch {
                try fm.copyItem(at: src, to: dst)
                copied.append(name)
            }
        }
        let summary: [String: Any] = [
            "schema": "pw.bench.lidar-ruler-subset/1",
            "bench_only_notice": "🔴 bench-only ruler:LiDAR 深度只用于研发期标定台架,永不进入产品管线,"
                + "也不作为任何产品方案的一部分",
            "source_recording_id": manifest.recordingID,
            "source_frame_count": manifest.frameCount,
            "depth_rows": depthStamps.count,
            "min_spacing_s": minSpacingSeconds,
            "frames": picked.count,
            "frames_bin_bytes": offset,
            "frames_bin_sha256": hex(digest.finalize()),
            "linked": linked,
            "copied": copied,
            "not_replayable_reason": "recording_manifest.json 描述的是整份录制;子集只给离线尺子",
            "out_name": outName,
            "xrslam_admission": [
                "rule": "phone replay: camera_index rows (limit_frames prefix) → drop t < first IMU → "
                    + "PwXrslamOfficialFeed.admits(pts=Double(t_ns)*1e-9): reject if pts - last_admitted < 0.8/R",
                "gate_source": gateSource,
                "camera_hz": xrslamCameraHz,
                "limit_frames": limitFrames,
                "first_imu_ns": imu0.map { NSNumber(value: $0) } ?? NSNull(),
                "camera_rows": cameraRows.count,
                "fed": adm.fed,
                "leading_without_imu_dropped": adm.leadingDropped,
                "gated_out": adm.gatedOut,
                "admitted": adm.admitted.count,
                "depth_rows_with_luma": depthWithLuma,
                "depth_rows_not_admitted": depthNotAdmitted,
                "every_subset_frame_admitted": picked.allSatisfy { adm.admitted.contains($0.frame) },
            ] as [String: Any],
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: out.appendingPathComponent("ruler_subset_manifest.json"), options: .atomic)
        return summary
    }
}
