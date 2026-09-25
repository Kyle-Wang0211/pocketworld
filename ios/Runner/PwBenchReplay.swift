// PwBenchReplay.swift —— 台架回放:把一份设备录制经**产品的 ON 臂喂料通路**重放一遍。
//
// 只进台架(arloopbench,bundle com.kyle.arloopbench)。生产 Runner.xcodeproj 不编它。
// Dart 侧是 `lib/vio/replay/bench_replay_native.dart`(绑定)与
// `lib/vio/render/bench_replay_page.dart`(页面)。
//
// ══ 喂到哪里 —— 与直播 ON 臂同一条路,不另写一套 ═══════════════════════════════
//   相机帧 → `PwXrslamLive.shared.onCameraFrame(pixelBuffer, pts, exposure, intrinsics)`
//            → 同一道有界闸 → 同一条 worker → `runOneFrame` 里同一段逐帧 K 决策
//            (开关 `-PWPerFrameIntrinsics`、yaml cam0.resolution 核对、参照尺寸核对)
//            → `PWXrslamTransportPushCameraAndRunRaw[WithIntrinsics]`
//   IMU 行 → `PwXrslamLive.shared.pushReplayImu`(同一个 enqueueImu)
//            → `PWXrslamTransportPushGyroscopeRaw` / `PushAccelerationRaw`
//   会话   → `PwXrslamLive.shared.create`(= Dart `XrslamLive.create` 调的那个)
//            → `beginReplay`(不起 CoreMotion)→ … → `destroy`
// 唯一换掉的叶子是「传感器从哪来」:相机槽与 CoreMotion 换成录制文件。上游自己也是
// 这么切的(xrslam-ios 的 Motion.swift / Camera.swift 是平台叶子),
// `xrslam_live_ffi.dart` 文件头「跨端口径」那段说的就是这件事。
//
// ══ 相机帧怎么变成 CVPixelBuffer ═══════════════════════════════════════════
// 录制里存的是 `ARFrame.capturedImage` 的 luma 平面,raw,一帧一段
// (BasaltVIOBench `DeviceRecordingTypes.swift:3-13`「replaying it is feeding the same
// input, not a substitute for it」)。这里原样读进一个 OneComponent8 的 CVPixelBuffer
// (宽高 = 录制的 camera.width/height,**不缩放**:录到 640 就喂 640,录到 1920×1440
// 就喂 1920×1440,回执里如实写)。`runOneFrame` 看到 OneComponent8 ⇒ channel 1,
// 引擎 channel==1 分支原样 clone(fork XRSLAMManager.cpp:167-169)。
// 逐帧 K = 录制里这一帧自己的 `intrinsics_fxfycxcy`,参照尺寸就是录制平面
// ⇒ `PwFrameIntrinsics` 的 reference/activeFormat 两组尺寸都填录制尺寸;
// 真正承重的第四组核对(推送尺寸 == yaml cam0.resolution)照常由 runOneFrame 做。
//
// ══ 节拍(三档,回执里写明是哪一档)══════════════════════════════════════════
//   paced            —— `ReplayScheduler(.paced)` 按录制时间戳投递;worker 忙时**等**,
//                        不丢帧(BasaltVIOBench `-PWPaceReplay` 的语义,
//                        BenchmarkCoordinator.swift:1178-1210 + waitForReplayCapacity
//                        :1457-1508)。引擎是 threading OFF 的同步核 ⇒ 轨迹与 max 档
//                        应逐位相同,差别只在计时读数的真实节奏。
//   max              —— `ReplayScheduler(.maximumThroughput)`,同样只等不丢(源 replay-max)。
//   paced-live-drop  —— 按录制时间戳投递相机帧但**不等**:吃不下的帧由
//                        PwXrslamLive 自己那道闸计数丢弃(PwXrslamLive.swift onCameraFrame,
//                        `maxPendingFrames = 2`),与直播 ON 臂同一种背压。IMU 仍然等
//                        (直播 IMU 闸从不该满)。轨迹**不**保证可复现。
//
// ══ 与 BasaltVIOBench 回放的差别 ═══════════════════════════════════════════
//   · 源的回放喂的是它自己的 XRSLAMNativeSession.swift;这里喂的是产品通路(上面那段)。
//   · 源在回放后算对 ARKit 的一致性;这里只落盘(TUM / 计时 / K 账 / 汇总),
//     ATE 回 Mac 用 ~/Developer/viobench-recordings/ate.py 算(与 Mac 宿主回放同一把尺)。
//   · 🔴 录制里的 IMU 是**陀螺驱动配对**的:每条陀螺配最近一条加速度,
//     加速度盖陀螺的时间戳(录制器 ARKitReferenceSession.swift:419-446)。
//     直播 ON 臂推的是加速度**自己的**时间戳(PwXrslamLive.swift onAccel)。
//     这是录制格式的性质,回放改不回来;A/B 两臂吃的是同一份,公平性不受影响,
//     但「回放 ≡ 直播」在这一点上不成立。Mac 宿主回放吃的也是同一份配对 IMU。

import CoreVideo
import CryptoKit
import Foundation

// MARK: - 启动参数

/// 台架回放的启动参数。读法逐字抄 `PwPerFrameIntrinsicsSwitch`
/// (PwXrslamLive.swift:144-154:先 UserDefaults 的 NSArgumentDomain,再自己扫一遍 argv),
/// 那段又是抄 `PwFocusArms.swift:214-235` 的 `-PWFocusArm`。
///
///   -PWBenchReplayRecording <目录名 | 录制 id 前缀>   选录制(有它就进回放页、默认自动开跑)
///   -PWBenchReplayAutoStart 1|0                       有录制参数时默认 1
///   -PWBenchReplayPace paced|max|paced-live-drop      默认 paced
///   -PWBenchReplayTag <标签>                          只进目录名与回执
///   -PWBenchReplayAllowLossy on|off                   默认 off(有损录制照源规矩拒)
///   -PWBenchReplayIgnoreExposure on|off               默认 off(用录制的 exposure_s)
///   -PWBenchReplayLimitFrames <N>                     默认 0 = 全部
///   -PWBenchReplayCameraTimeOffsetMs <毫秒>           默认:曝光中点 on(台架默认,2026-09-25 起)⇒ 按录制机型
///                                                     查表(camera_time_offset.dart,iPhone15,2 = 3.00 ms);
///                                                     -PWXrslamExposureMid off ⇒ 官方 0
///   -PWXrslamExposureMid on|off                       默认 on(PwXrslamLive.swift PwXrslamOfficialFeed ③);
///                                                     解析结果随 snapshot 交给 Dart 定 c 的默认值
///   -PWBenchReplayVerifyDigest on|off                 默认 off(整条 frames.bin 重哈希)
///   -PWPerFrameIntrinsics on|off                      已有开关,原样生效(PwXrslamLive.swift)
///   -PWYamlOverride <section>.<key>=<value>           可重复;规则见 Dart
///                                                     bench_replay_controller.dart applyYamlOverrides
///                                                     (抄 BasaltVIOBench BenchmarkRunPreparation.swift:153-211)
enum PwBenchReplayLaunch {
    static let keys: [String] = [
        "PWBenchReplayRecording", "PWBenchReplayAutoStart", "PWBenchReplayPace",
        "PWBenchReplayTag", "PWBenchReplayAllowLossy", "PWBenchReplayIgnoreExposure",
        "PWBenchReplayLimitFrames", "PWBenchReplayCameraTimeOffsetMs",
        "PWBenchReplayVerifyDigest",
    ]

    static func value(_ key: String) -> String? {
        var raw = ""
        if let v = UserDefaults.standard.string(forKey: key) { raw = v }
        if raw.isEmpty {
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-\(key)"), i + 1 < args.count { raw = args[i + 1] }
        }
        return raw.isEmpty ? nil : raw
    }

    /// 可重复的 `-PWYamlOverride`:按 argv 顺序全收(源 BenchmarkRunPreparation.swift:159-208
    /// 也是扫 argv;UserDefaults 只给得出一个值)。
    static func yamlOverrides() -> [String] {
        let args = ProcessInfo.processInfo.arguments
        var out: [String] = []
        var i = 0
        while i < args.count {
            if args[i] == "-PWYamlOverride", i + 1 < args.count {
                out.append(args[i + 1]); i += 2
            } else { i += 1 }
        }
        if out.isEmpty, let v = UserDefaults.standard.string(forKey: "PWYamlOverride"), !v.isEmpty {
            out.append(v)
        }
        return out
    }

    static func snapshot() -> [String: Any] {
        var out: [String: Any] = [:]
        for k in keys { if let v = value(k) { out[k] = v } }
        out["PWYamlOverride"] = yamlOverrides()
        let sw = PwPerFrameIntrinsicsSwitch.resolved
        out["PWPerFrameIntrinsics"] = [
            "enabled": sw.enabled,
            "source": sw.source.rawValue,
            "raw": sw.raw,
        ] as [String: Any]
        // [bench 2026-09-25] 曝光中点开关的原生解析结果(唯一一处解析),Dart 用它定 c 的默认值。
        let feed = PwXrslamOfficialFeed.resolved
        out["PWXrslamExposureMid"] = [
            "enabled": feed.exposureMid,
            "source": feed.exposureMidSource,
            "raw": feed.rawExposure,
        ] as [String: Any]
        return out
    }
}

// MARK: - 配置(Dart 交过来的 JSON)

struct PwBenchReplayConfig: Decodable {
    let recordingDir: String
    let outDir: String
    let slamConfigPath: String
    let deviceConfigPath: String
    let cameraTimeOffsetSeconds: Double
    let pace: String
    let allowLossy: Bool
    let ignoreExposure: Bool
    let limitFrames: Int
    let verifyFramesDigest: Bool

    enum CodingKeys: String, CodingKey {
        case recordingDir = "recording_dir"
        case outDir = "out_dir"
        case slamConfigPath = "slam_config_path"
        case deviceConfigPath = "device_config_path"
        case cameraTimeOffsetSeconds = "camera_time_offset_s"
        case pace
        case allowLossy = "allow_lossy"
        case ignoreExposure = "ignore_exposure"
        case limitFrames = "limit_frames"
        case verifyFramesDigest = "verify_frames_digest"
    }

    static let paces = ["paced", "max", "paced-live-drop"]
}

// MARK: - 逐帧记录

private struct PwBenchReplayOffered {
    let ordinal: Int
    let recordingFrameIndex: Int
    let timestampNanoseconds: Int64
    let recordedK: [Double]?
    let exposureUsed: Double
    let exposureRecorded: Double?
}

private struct PwBenchReplayFrameRecord {
    let observation: PwXrslamFrameObservation
    let offered: PwBenchReplayOffered?
    let bodyPose: PWXrslamRawPose
    let telemetryDelta: PWBenchReplayTelemetry
}

private enum PwBenchReplayFailure: Error, CustomStringConvertible {
    case cancelled
    case stalled(String)
    case setup(String)

    var description: String {
        switch self {
        case .cancelled: return "cancelled"
        case .stalled(let s): return "replay_engine_stalled_\(s)"
        case .setup(let s): return s
        }
    }
}

// MARK: - 回放器

final class PwBenchReplayRunner {
    static let shared = PwBenchReplayRunner()

    /// [port] BenchmarkCoordinator.swift:1510-1514 —— 满闸且零进展这么久 ⇒ 判定卡死。
    static let stallTimeoutNanoseconds: UInt64 = 20_000_000_000

    private let lock = NSLock()
    private var phase = "idle"
    private var failure: String?
    private var cancelRequested = false
    private var thread: Thread?

    // 进度(status 用)
    private var eventsTotal = 0
    private var eventsDelivered = 0
    private var cameraTotal = 0
    private var cameraOffered = 0
    private var observations = 0
    private var startedAtNs: UInt64 = 0
    private var summary: [String: Any]?

    // 逐帧(worker 线程写、回放线程读;都在 recordLock 里)
    private let recordLock = NSLock()
    private var records: [PwBenchReplayFrameRecord] = []
    private var offeredByPts: [UInt64: PwBenchReplayOffered] = [:]
    private var lastTelemetry = PWBenchReplayTelemetry()
    // [bench 2026-09-25 后端位姿] 引擎后端出口(PwBenchReplayEngineProbe.h ③)取走的记录,与
    //   「推给引擎的帧时间(位模式)→ 投递记录」对照表。传输层把 XRSLAMImage.timeStamp 设成
    //   effective_timestamp(PwXrslamTransportCore.cpp),观察者的 effectiveTimestamp 就是同一个 double,
    //   引擎后端记录的 timestamp 又是 frame->image->t = 同一个 double ⇒ 按位模式整数相等配回录制帧,零容差。
    private var backendEvents: [XRSLAMBackendPose] = []
    private var backendWindowAtEnd: [XRSLAMBackendPose] = []
    private var backendDropped: UInt64 = 0
    private var backendExitAvailable = true
    private var offeredByEffective: [UInt64: PwBenchReplayOffered] = [:]

    private var bufferPool: CVPixelBufferPool?

    // MARK: 对外

    /// 0 已开跑;-1 正在跑;-2 配置 JSON 不对。
    func start(configJSON: String) -> Int32 {
        guard let data = configJSON.data(using: .utf8),
              let config = try? JSONDecoder().decode(PwBenchReplayConfig.self, from: data),
              PwBenchReplayConfig.paces.contains(config.pace) else {
            return -2
        }
        lock.lock()
        if phase == "loading" || phase == "running" || phase == "draining"
            || phase == "writing" {
            lock.unlock()
            return -1
        }
        phase = "loading"
        failure = nil
        cancelRequested = false
        eventsTotal = 0; eventsDelivered = 0; cameraTotal = 0; cameraOffered = 0
        observations = 0; summary = nil
        startedAtNs = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
        recordLock.lock(); records = []; offeredByPts = [:]
        backendEvents = []; backendWindowAtEnd = []; backendDropped = 0; backendExitAvailable = true
        offeredByEffective = [:]; recordLock.unlock()

        let t = Thread { [weak self] in self?.run(config) }
        t.name = "com.pocketworld.bench.replay"
        t.qualityOfService = .userInitiated
        lock.lock(); thread = t; lock.unlock()
        t.start()
        return 0
    }

    func cancel() {
        lock.lock(); cancelRequested = true; lock.unlock()
    }

    func statusJSON() -> String {
        lock.lock()
        var s: [String: Any] = [
            "phase": phase,
            "events_total": eventsTotal,
            "events_delivered": eventsDelivered,
            "camera_total": cameraTotal,
            "camera_offered": cameraOffered,
            "observations": observations,
            "elapsed_s": startedAtNs == 0 ? 0.0
                : Double(DispatchTime.now().uptimeNanoseconds &- startedAtNs) / 1e9,
        ]
        if let failure { s["error"] = failure }
        if let summary { s["summary"] = summary }
        lock.unlock()
        return Self.json(s)
    }

    /// 只读地装载一次(不开会话),给 Dart 列表页与建 yaml 用。有损录制也照装(标出来)。
    static func inspectJSON(recordingDir: String) -> String {
        let root = URL(fileURLWithPath: recordingDir, isDirectory: true)
        let manifestURL = root.appendingPathComponent(DeviceRecordingManifest.fileName)
        do {
            var options = DeviceRecordingLoadOptions()
            options.allowLossy = true
            let ds = try DeviceRecordingLoader(options: options).load(manifestURL: manifestURL)
            var out = recordingSummary(ds)
            out["ok"] = true
            return json(out)
        } catch {
            return json(["ok": false, "error": "\(error)", "recording_dir": recordingDir])
        }
    }

    // MARK: 主流程(回放线程)

    private func setPhase(_ p: String) { lock.lock(); phase = p; lock.unlock() }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelRequested }

    private func run(_ config: PwBenchReplayConfig) {
        let live = PwXrslamLive.shared
        var created = false
        do {
            let root = URL(fileURLWithPath: config.recordingDir, isDirectory: true)
            var options = DeviceRecordingLoadOptions()
            options.verifyFramesDigest = config.verifyFramesDigest
            options.allowLossy = config.allowLossy
            options.limitFrames = max(0, config.limitFrames)
            let ds = try DeviceRecordingLoader(options: options)
                .load(manifestURL: root.appendingPathComponent(DeviceRecordingManifest.fileName))
            let reader = try FrameStreamReader(url: ds.streamURL)
            let cameraFrames = ds.cameraFrameCount
            lock.lock(); eventsTotal = ds.events.count; cameraTotal = cameraFrames; lock.unlock()

            let outDir = URL(fileURLWithPath: config.outDir, isDirectory: true)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

            try makePool(width: ds.camera.width, height: ds.camera.height)

            // ── 会话:与 ON 臂同一个 create(Dart XrslamLive.create → pw_xrslam_live_create)
            guard live.create(slamConfigPath: config.slamConfigPath,
                              deviceConfigPath: config.deviceConfigPath,
                              cameraTimeOffsetSeconds: config.cameraTimeOffsetSeconds) == 1 else {
                throw PwBenchReplayFailure.setup("pw_xrslam_live create != 1(另一个会话在跑?yaml 路径?)")
            }
            created = true
            recordLock.lock()
            PWBenchReplayTelemetryTake(&lastTelemetry)
            recordLock.unlock()
            live.setFrameObserver { [weak self] obs in self?.observe(obs) }
            guard live.beginReplay() == 0 else {
                throw PwBenchReplayFailure.setup("beginReplay != 0")
            }
            let thermalStart = ProcessInfo.processInfo.thermalState.rawValue
            setPhase("running")

            // ── 投递
            let mode: ReplaySchedulerMode = config.pace == "max" ? .maximumThroughput : .paced
            let waitForCamera = config.pace != "paced-live-drop"
            let wallStart = DispatchTime.now().uptimeNanoseconds
            let firstEventNs = ds.events.first?.timestampNanoseconds ?? 0
            var lateness = PwBenchReplayLateness()
            var cameraOrdinal = 0
            var imuRowsPushed = 0
            var capacityWaitsCamera = 0
            var capacityWaitsImu = 0
            try ReplayScheduler(mode: mode).run(events: ds.events) { event in
                // [port] BenchmarkCoordinator.swift:1219-1224 —— 每条事件一个 pool,
                // 否则整场的像素缓冲都挂在 autorelease 上。
                try autoreleasepool {
                    if isCancelled { throw PwBenchReplayFailure.cancelled }
                    if mode == .paced {
                        let expected = wallStart &+ UInt64(max(0, event.timestampNanoseconds - firstEventNs))
                        lateness.add(nowNs: DispatchTime.now().uptimeNanoseconds, expectedNs: expected)
                    }
                    switch event {
                    case .imu(let s):
                        if try waitForCapacity(live, camera: false) { capacityWaitsImu += 1 }
                        let t = Double(s.timestampNanoseconds) * 1e-9
                        live.pushReplayImu(
                            timestamp: t,
                            gyro: (s.gyroscopeRadiansPerSecond.x, s.gyroscopeRadiansPerSecond.y,
                                   s.gyroscopeRadiansPerSecond.z),
                            accelerationMps2: (s.accelerationMetersPerSecondSquared.x,
                                               s.accelerationMetersPerSecondSquared.y,
                                               s.accelerationMetersPerSecondSquared.z))
                        imuRowsPushed += 1
                    // [xr-recon-chain 2026-09-25] 新 IMU 格式(装载器 D11):陀螺 / 加计各按自己的时刻推,
                    // 与直播 onGyro / onAccel 同一道闸、同两个传输层入口。
                    case .gyro(let s):
                        if try waitForCapacity(live, camera: false) { capacityWaitsImu += 1 }
                        live.pushReplayGyro(timestamp: Double(s.timestampNanoseconds) * 1e-9,
                                            gyro: (s.value.x, s.value.y, s.value.z))
                        imuRowsPushed += 1
                    case .accel(let s):
                        if try waitForCapacity(live, camera: false) { capacityWaitsImu += 1 }
                        live.pushReplayAccel(timestamp: Double(s.timestampNanoseconds) * 1e-9,
                                             accelerationMps2: (s.value.x, s.value.y, s.value.z))
                        imuRowsPushed += 1
                    case .camera(let f):
                        if waitForCamera, try waitForCapacity(live, camera: true) {
                            capacityWaitsCamera += 1
                        }
                        let pb = try makeFrame(f, reader: reader, format: ds.camera)
                        // 与 EuRoC reader `t *= 1e-9` 同一个换算(纳秒整数 → 秒)。
                        let pts = Double(f.timestampNanoseconds) * 1e-9
                        let exposure = config.ignoreExposure ? 0 : (f.exposureSeconds ?? 0)
                        let k: PwFrameIntrinsics? = f.intrinsicsFxFyCxCy.map {
                            PwFrameIntrinsics(
                                fx: $0[0], fy: $0[1], cx: $0[2], cy: $0[3],
                                referenceWidth: ds.camera.width,
                                referenceHeight: ds.camera.height,
                                activeFormatWidth: ds.camera.width,
                                activeFormatHeight: ds.camera.height)
                        }
                        recordLock.lock()
                        offeredByPts[pts.bitPattern] = PwBenchReplayOffered(
                            ordinal: cameraOrdinal,
                            recordingFrameIndex: f.frameIndex,
                            timestampNanoseconds: f.timestampNanoseconds,
                            recordedK: f.intrinsicsFxFyCxCy,
                            exposureUsed: exposure,
                            exposureRecorded: f.exposureSeconds)
                        recordLock.unlock()
                        cameraOrdinal += 1
                        live.onCameraFrame(pb, ptsSeconds: pts, exposureSeconds: exposure,
                                           intrinsics: k)
                        lock.lock(); cameraOffered += 1; lock.unlock()
                    }
                    lock.lock(); eventsDelivered += 1; lock.unlock()
                }
            }

            // ── 排空:等 worker 把在途的帧与 IMU 都跑完
            setPhase("draining")
            try drain(live)
            let feedEndNs = DispatchTime.now().uptimeNanoseconds
            // [bench 2026-09-25 后端位姿] 宿主队列排空后,引擎内部(前端/后端 worker)可能还在处理最后几帧。
            //   等它们空闲(至多 4 s;符号不在 ⇒ -1 ⇒ 不等),再留 0.5 s 让最后一次 track() 写完出口,
            //   然后取走剩下的事件、读收尾整窗快照。这里已经没有新输入,等多久都不改变任何已算出的值;
            //   与 Mac 回放器 bkpose/tools/pwvi_runner.cpp 收尾同一个做法。
            var enginePendingWaitMs = 0
            while PWBenchReplayEnginePendingFrames() > 0 && enginePendingWaitMs < 4000 {
                Thread.sleep(forTimeInterval: 0.01); enginePendingWaitMs += 10
            }
            Thread.sleep(forTimeInterval: 0.5)
            drainBackendPoses()
            let windowCount = PWBenchReplayBackendWindowPoses(nil, 0)
            if windowCount > 0 {
                var wbuf = [XRSLAMBackendPose](repeating: XRSLAMBackendPose(), count: Int(windowCount))
                let got = wbuf.withUnsafeMutableBufferPointer {
                    PWBenchReplayBackendWindowPoses($0.baseAddress, windowCount)
                }
                recordLock.lock()
                backendWindowAtEnd = Array(wbuf[0..<Int(min(got, windowCount))])
                recordLock.unlock()
            }
            let thermalEnd = ProcessInfo.processInfo.thermalState.rawValue

            // ── 读账(都在 destroy 之前)
            let stats = UnsafeMutablePointer<Int64>.allocate(capacity: 14)
            defer { stats.deallocate() }
            live.stats(into: stats)
            let ik = UnsafeMutablePointer<Double>.allocate(capacity: PwXrslamLive.intrinsicsReportCount)
            defer { ik.deallocate() }
            let ikRc = live.intrinsicsReport(into: ik)
            let tb = UnsafeMutablePointer<Double>.allocate(capacity: 12)
            defer { tb.deallocate() }
            let tbRc = live.timebase(into: tb)
            let trail = live.gpuFrontEndTrail()
            // [bench 2026-09-24] 官方喂料口径(30 Hz 准入 / box n / 原始 PTS)与构建戳,destroy 之前读。
            let feedReport = live.feedReport()
            live.setFrameObserver(nil)
            live.destroy()
            created = false

            setPhase("writing")
            recordLock.lock()
            let recs = records
            recordLock.unlock()
            let outputs = try writeOutputs(recs, outDir: outDir)

            var sum = Self.recordingSummary(ds)
            sum["schema"] = "pw.bench.replay-native/1"
            sum["config"] = [
                "recording_dir": config.recordingDir,
                "out_dir": config.outDir,
                "slam_config_path": config.slamConfigPath,
                "device_config_path": config.deviceConfigPath,
                "slam_config_sha256": Self.sha256(file: config.slamConfigPath) ?? "",
                "device_config_sha256": Self.sha256(file: config.deviceConfigPath) ?? "",
                // 与 vio_diagnostics_recorder.dart:870-872 的 effectiveConfigSha256 同一个式子:
                // sha256(slam 正文 + "\0" + device 正文)。
                "effective_config_sha256": Self.effectiveConfigSha256(
                    slamPath: config.slamConfigPath, devicePath: config.deviceConfigPath) ?? "",
                "camera_time_offset_s": config.cameraTimeOffsetSeconds,
                "pace": config.pace,
                "allow_lossy": config.allowLossy,
                "ignore_exposure": config.ignoreExposure,
                "limit_frames": config.limitFrames,
                "verify_frames_digest": config.verifyFramesDigest,
            ] as [String: Any]
            let statNames = ["camera_submitted", "camera_run_calls", "acceleration_submitted",
                             "gyroscope_submitted", "rejected_non_monotonic",
                             "rejected_invalid_argument", "rejected_not_running", "running",
                             "camera_callbacks", "camera_lock_failures", "frames_offered",
                             "frames_dropped", "imu_dropped", "max_pending_frames"]
            var statDict: [String: Any] = [:]
            for (i, n) in statNames.enumerated() { statDict[n] = stats[i] }
            sum["transport_stats"] = statDict
            sum["intrinsics_report_rc"] = Int(ikRc)
            sum["intrinsics_report"] = (0..<PwXrslamLive.intrinsicsReportCount).map { ik[$0] }
            sum["timebase_rc"] = Int(tbRc)
            sum["timebase"] = (0..<12).map { tb[$0] }
            sum["gpu_frontend_trail"] = trail
            sum["xrslam_feed"] = feedReport
            sum["telemetry_symbols_found"] = Int(PWBenchReplayTelemetrySymbolCount())
            sum["backend_pose_exit"] = [
                "available": backendExitAvailable,
                "events": backendEvents.count,
                "window_at_end": backendWindowAtEnd.count,
                "dropped_by_engine_queue": backendDropped,
                "engine_pending_wait_ms": enginePendingWaitMs,
                "window_count_rc": Int(windowCount),
            ] as [String: Any]
            sum["feeding"] = [
                "camera_offered": cameraOrdinal,
                "imu_rows_pushed": imuRowsPushed,
                "capacity_waits_camera": capacityWaitsCamera,
                "capacity_waits_imu": capacityWaitsImu,
                "observations": recs.count,
                "paced_late_events_over_5ms": lateness.over5ms,
                "paced_max_lateness_ms": lateness.maxMs,
                "wall_s": Double(feedEndNs &- wallStart) / 1e9,
                "recording_span_s": Double((ds.events.last?.timestampNanoseconds ?? 0)
                                           - firstEventNs) / 1e9,
            ] as [String: Any]
            sum["thermal_state"] = ["start": thermalStart, "end": thermalEnd]
            sum["per_frame_intrinsics_switch"] = [
                "enabled": PwPerFrameIntrinsicsSwitch.resolved.enabled,
                "source": PwPerFrameIntrinsicsSwitch.resolved.source.rawValue,
                "raw": PwPerFrameIntrinsicsSwitch.resolved.raw,
                "parse_failed": PwPerFrameIntrinsicsSwitch.parseFailed,
            ] as [String: Any]
            sum["engine_identity_info_plist"] = Self.engineIdentity()
            sum["device"] = ["hw_machine": Self.hwMachine() ?? "",
                             "os": ProcessInfo.processInfo.operatingSystemVersionString]
            sum["launch_arguments"] = PwBenchReplayLaunch.snapshot()
            sum["outputs"] = outputs
            sum["invariants"] = Self.invariants(stats: stats, observations: recs.count,
                                                offered: cameraOrdinal, pace: config.pace,
                                                ik: ik, ikRc: ikRc)
            try Self.json(sum).data(using: .utf8)!
                .write(to: outDir.appendingPathComponent("replay_native_summary.json"))

            lock.lock(); summary = sum; phase = "done"; lock.unlock()
        } catch {
            if created {
                live.setFrameObserver(nil)
                live.destroy()
            }
            lock.lock()
            failure = "\(error)"
            phase = "failed"
            lock.unlock()
            NSLog("[bench-replay] failed: %@", "\(error)")
        }
    }

    // MARK: 背压

    /// [port] BenchmarkCoordinator.swift:1457-1508 waitForReplayCapacity。
    /// 返回 true = 真的等过。满闸且 20 s 没进展 ⇒ 抛 stalled(源的判据)。
    private func waitForCapacity(_ live: PwXrslamLive, camera: Bool) throws -> Bool {
        let cap = PwXrslamLive.replayCapacity
        var stallDeadline: UInt64? = nil
        var last = live.pendingWork()
        var waited = false
        while true {
            if isCancelled { throw PwBenchReplayFailure.cancelled }
            let p = live.pendingWork()
            // 一行 IMU 推两次(陀螺 + 加速度)⇒ 要两个空位。
            if camera ? (p.frames < cap.frames) : (p.imu + 2 <= cap.imu) { return waited }
            waited = true
            let now = DispatchTime.now().uptimeNanoseconds
            if p.cameraCallbacks != last.cameraCallbacks || p.imu != last.imu
                || p.frames != last.frames {
                last = p
                stallDeadline = nil
            } else if let d = stallDeadline {
                if now > d {
                    throw PwBenchReplayFailure.stalled(camera
                        ? "camera_queue_full_no_progress" : "imu_queue_full_no_progress")
                }
            } else {
                stallDeadline = now + Self.stallTimeoutNanoseconds
            }
            Thread.sleep(forTimeInterval: 0.0002)
        }
    }

    private func drain(_ live: PwXrslamLive) throws {
        var last = live.pendingWork()
        var stallDeadline = DispatchTime.now().uptimeNanoseconds + Self.stallTimeoutNanoseconds
        while true {
            let p = live.pendingWork()
            if p.frames == 0 && p.imu == 0 { return }
            if p.frames != last.frames || p.imu != last.imu
                || p.cameraCallbacks != last.cameraCallbacks {
                last = p
                stallDeadline = DispatchTime.now().uptimeNanoseconds + Self.stallTimeoutNanoseconds
            } else if DispatchTime.now().uptimeNanoseconds > stallDeadline {
                throw PwBenchReplayFailure.stalled("drain_no_progress")
            }
            Thread.sleep(forTimeInterval: 0.001)
        }
    }

    // MARK: 帧

    private func makePool(width: Int, height: Int) throws {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_OneComponent8,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ]
        var pool: CVPixelBufferPool?
        let rc = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        guard rc == kCVReturnSuccess, let pool else {
            throw PwBenchReplayFailure.setup("CVPixelBufferPoolCreate \(rc)")
        }
        bufferPool = pool
    }

    private func makeFrame(_ f: DeviceRecordingCameraFrame, reader: FrameStreamReader,
                           format: DeviceRecordingCameraFormat) throws -> CVPixelBuffer {
        guard let pool = bufferPool else { throw PwBenchReplayFailure.setup("no pool") }
        var out: CVPixelBuffer?
        let rc = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out)
        guard rc == kCVReturnSuccess, let pb = out else {
            throw PwBenchReplayFailure.setup("CVPixelBufferPoolCreatePixelBuffer \(rc)")
        }
        guard CVPixelBufferGetWidth(pb) == format.width,
              CVPixelBufferGetHeight(pb) == format.height else {
            throw PwBenchReplayFailure.setup("pixel buffer size mismatch")
        }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else {
            throw PwBenchReplayFailure.setup("pixel buffer has no base address")
        }
        try reader.read(f.byteRange, into: base, rowBytes: format.width, rows: format.height,
                        destinationStride: CVPixelBufferGetBytesPerRow(pb))
        return pb
    }

    // MARK: 观察者(PwXrslamLive 的 worker 线程上)

    private func observe(_ obs: PwXrslamFrameObservation) {
        var body = PWXrslamRawPose()
        PWBenchReplayReadBodyPose(&body)
        var now = PWBenchReplayTelemetry()
        PWBenchReplayTelemetryTake(&now)
        recordLock.lock()
        let delta = Self.telemetryDelta(now, lastTelemetry)
        lastTelemetry = now
        let offered = offeredByPts.removeValue(forKey: obs.rawPts.bitPattern)
        records.append(PwBenchReplayFrameRecord(observation: obs, offered: offered,
                                                bodyPose: body, telemetryDelta: delta))
        if obs.traceOk, let offered {
            offeredByEffective[obs.effectiveTimestamp.bitPattern] = offered
        }
        recordLock.unlock()
        drainBackendPoses()
        lock.lock(); observations += 1; lock.unlock()
    }

    /// [bench 2026-09-25 后端位姿] 把引擎后端出口里已有的 First / Final 事件取走(只读;
    /// 引擎没有这个出口 ⇒ -1,记一次就不再调)。worker 线程每帧调一次,收尾再调一次。
    private func drainBackendPoses() {
        recordLock.lock()
        let available = backendExitAvailable
        recordLock.unlock()
        guard available else { return }
        let cap: Int32 = 256
        var buf = [XRSLAMBackendPose](repeating: XRSLAMBackendPose(), count: Int(cap))
        while true {
            var dropped: UInt64 = 0
            let n = buf.withUnsafeMutableBufferPointer {
                PWBenchReplayDrainBackendPoses($0.baseAddress, cap, &dropped)
            }
            recordLock.lock()
            if n < 0 {
                backendExitAvailable = false
                recordLock.unlock()
                return
            }
            backendDropped &+= dropped
            if n > 0 { backendEvents.append(contentsOf: buf[0..<Int(n)]) }
            recordLock.unlock()
            if n < cap { return }
        }
    }

    private static func telemetryDelta(_ e: PWBenchReplayTelemetry,
                                       _ s: PWBenchReplayTelemetry) -> PWBenchReplayTelemetry {
        // runner @b0937ef flush_period 的同一套差分:任一端缺 ⇒ -1 / NAN。
        func dl(_ b: Int64, _ a: Int64) -> Int64 { (a < 0 || b < 0) ? -1 : b - a }
        var d = PWBenchReplayTelemetry()
        d.scoped_ms = e.scoped_ms - s.scoped_ms
        d.unscoped_ms = e.unscoped_ms - s.unscoped_ms
        d.bk_work_ms = e.bk_work_ms - s.bk_work_ms
        d.bk_track_ms = e.bk_track_ms - s.bk_track_ms
        d.scoped_calls = dl(e.scoped_calls, s.scoped_calls)
        d.scoped_iters = dl(e.scoped_iters, s.scoped_iters)
        d.stop_budget = dl(e.stop_budget, s.stop_budget)
        d.stop_time = dl(e.stop_time, s.stop_time)
        d.stop_iter = dl(e.stop_iter, s.stop_iter)
        d.stop_conv = dl(e.stop_conv, s.stop_conv)
        d.bk_track_n = dl(e.bk_track_n, s.bk_track_n)
        return d
    }

    // MARK: 落盘

    static let hostReasonLabels = [
        "attached", "switch_off", "no_attachment", "reference_mismatch",
        "active_format_mismatch", "config_resolution_mismatch", "config_resolution_unknown",
    ]

    /// 数字格式逐字抄 pw_euroc_runner:TUM 的 t 用 %.9f、其余 %.7f(euroc_runner.cpp:248-254),
    /// 计时 CSV 用 `%ld,%.9f,%.4f,...`(@b0937ef flush_period)。同一口径才能逐行 diff。
    private func writeOutputs(_ recs: [PwBenchReplayFrameRecord],
                              outDir: URL) throws -> [String: Any] {
        var body = ""
        var camera = ""
        var timing = "frame,t,wall_ms,cpu_ms,sw_solver_ms,sw_solves,sw_iters,stop_budget,"
            + "stop_time,stop_iter,stop_conv,init_solver_ms,bk_work_ms,bk_track_ms,bk_track_n,"
            + "rc,state,queue_wait_ms,recording_frame\n"
        var ledger = "frame,recording_frame,t_ns,t_canonical,t_effective,exposure_used_s,"
            + "exposure_recorded_s,host_reason,host_reason_label,k_source,recorded_fx,"
            + "recorded_fy,recorded_cx,recorded_cy,attached,attached_fx,attached_fy,attached_cx,"
            + "attached_cy,engine_report_read,engine_fx,engine_fy,engine_cx,engine_cy,"
            + "engine_report_differs,pushed_w,pushed_h,channel,stride\n"
        var lastBodyT = -1.0
        var lastCamT = -Double.infinity
        var bodyRows = 0, cameraRows = 0
        // [2026-09-24 rec30] CAMERA 位姿按**录制帧**精确键控(🔴 bench-only ruler 用它量 XRSLAM 的米制尺度):
        //   recording_frame / t_ns = 这一帧在录制里的帧号与整数纳秒时间戳(观察者按 raw pts 位模式配回投递记录,
        //   不经任何时间容差);位姿 = 引擎交回的 CAMERA 位姿(与 poses_camera.tum 同一个 o.pose,
        //   world_from_camera、相机轴同 cam0.extrinsic 的相机系);engine_t = 引擎给位姿的时间戳
        //   (曝光中点 on:= t_ns·1e-9 + exposure/2 + camera_time_offset;off:= t_ns·1e-9 + camera_time_offset,可自证)。
        //   🔴 键控只用 t_ns(录制整数纳秒)与 raw pts 位模式,与曝光中点开关无关。闸同 poses_camera.tum(rc == 0、TRACKING_SUCCESS、
        //   时间严格前进)再加四元数模 ≥ 0.5(与 BODY 闸同式;初始化那一帧引擎交回全零四元数)。
        //   尺子(tool/bench/lidar_ruler/lidar_ruler.py --xrslam-camera)按 t_ns 整数相等取,不插值。
        var cameraByFrame = "recording_frame,t_ns,tx,ty,tz,qx,qy,qz,qw,engine_t\n"
        var cameraByFrameRows = 0
        var lastKeyedT = -Double.infinity
        for (i, r) in recs.enumerated() {
            let o = r.observation
            // BODY:runner 的闸 —— 四元数模 ≥ 0.5 且时间戳严格前进(euroc_runner.cpp:207-213)。
            let bq = r.bodyPose.quaternion
            let qn = (bq.0 * bq.0 + bq.1 * bq.1 + bq.2 * bq.2 + bq.3 * bq.3).squareRoot()
            if o.rc == 0, qn >= 0.5, r.bodyPose.timestamp > lastBodyT {
                lastBodyT = r.bodyPose.timestamp
                body += Self.tumRow(r.bodyPose)
                bodyRows += 1
            }
            // CAMERA:产品的闸 —— 只有 TRACKING_SUCCESS 才算位姿(PwXrslamLive.runOneFrame,
            // 抄上游 XRSLAM_iOS.mm:171),再加时间戳严格前进。
            if o.rc == 0, o.state == 1, o.pose.timestamp > lastCamT {
                lastCamT = o.pose.timestamp
                camera += Self.tumRow(o.pose)
                cameraRows += 1
            }
            let cq = o.pose.quaternion
            let cqn = (cq.0 * cq.0 + cq.1 * cq.1 + cq.2 * cq.2 + cq.3 * cq.3).squareRoot()
            if o.rc == 0, o.state == 1, cqn >= 0.5, o.pose.timestamp > lastKeyedT,
               let off = r.offered, off.recordingFrameIndex >= 0 {
                lastKeyedT = o.pose.timestamp
                let p = o.pose
                cameraByFrame += String(
                    format: "%ld,%lld,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f\n",
                    off.recordingFrameIndex, off.timestampNanoseconds,
                    p.translation.0, p.translation.1, p.translation.2,
                    p.quaternion.0, p.quaternion.1, p.quaternion.2, p.quaternion.3, p.timestamp)
                cameraByFrameRows += 1
            }
            let d = r.telemetryDelta
            func f4(_ v: Double) -> String { String(format: "%.4f", v) }
            let recFrame: Int = r.offered?.recordingFrameIndex ?? -1
            var tf: [String] = []
            tf.append("\(i)")
            tf.append(String(format: "%.9f", o.effectiveTimestamp))
            tf.append(f4(o.solveWallMs))
            tf.append(f4(o.solveCpuMs))
            tf.append(f4(d.scoped_ms))
            tf += [d.scoped_calls, d.scoped_iters, d.stop_budget, d.stop_time,
                   d.stop_iter, d.stop_conv].map { String($0) }
            tf.append(f4(d.unscoped_ms))
            tf.append(f4(d.bk_work_ms))
            tf.append(f4(d.bk_track_ms))
            tf.append(String(d.bk_track_n))
            tf.append(String(o.rc))
            tf.append(String(o.state))
            tf.append(f4(o.queueWaitMs))
            tf.append(String(recFrame))
            timing += tf.joined(separator: ",") + "\n"

            let t = o.intrinsicsTrace
            func g(_ v: Double) -> String { String(format: "%.17g", v) }
            let label: String = o.hostReason >= 0 && o.hostReason < Self.hostReasonLabels.count
                ? Self.hostReasonLabels[o.hostReason] : "unknown"
            let src: String =
                PwPerFrameIntrinsicsSource(rawValue: o.intrinsicsSource)?.label ?? "none"
            let attachedK: [Double] = [t.last_attached_fxfycxcy.0, t.last_attached_fxfycxcy.1,
                                       t.last_attached_fxfycxcy.2, t.last_attached_fxfycxcy.3]
            let engineK: [Double] = [t.last_engine_fxfycxcy.0, t.last_engine_fxfycxcy.1,
                                     t.last_engine_fxfycxcy.2, t.last_engine_fxfycxcy.3]
            var lf: [String] = []
            lf.append(String(i))
            lf.append(String(recFrame))
            lf.append(String(r.offered?.timestampNanoseconds ?? -1))
            lf.append(g(o.canonical))
            lf.append(o.traceOk ? g(o.effectiveTimestamp) : "")
            lf.append(g(r.offered?.exposureUsed ?? 0))
            lf.append(r.offered?.exposureRecorded.map(g) ?? "")
            lf.append(String(o.hostReason))
            lf.append(label)
            lf.append(src)
            if let rk = r.offered?.recordedK { lf += rk.map(g) } else { lf += ["", "", "", ""] }
            lf.append(o.intrinsicsTraceOk ? String(t.last_per_frame_attached) : "")
            lf += attachedK.map(g)
            lf.append(String(t.last_engine_report_read))
            lf += engineK.map(g)
            lf.append(String(t.last_engine_report_differs))
            lf.append(String(o.pushedWidth))
            lf.append(String(o.pushedHeight))
            lf.append(String(o.channel))
            lf.append(String(o.stride))
            ledger += lf.joined(separator: ",") + "\n"
        }
        // [bench 2026-09-25 后端位姿] 后端(滑动窗口 BA)已优化帧位姿,按录制帧精确键控(🔴 bench-only ruler 也吃它)。
        //   只有进过后端的帧才有行(初始化后约每 3 个准入帧 1 个);不插值、不平滑、不外推。
        //   first_* = 这一帧自己那次后端 track() 刚结束时的值(首次后端估计);
        //   final_* = 离开后端窗口前的最后值(final_source = marginalized);收尾时仍在窗口里的帧取收尾整窗快照
        //             (final_source = window_at_end);两者都没有则留空。
        //   位姿口径与 poses_camera_by_recording_frame.csv 相同(引擎 body→camera 与 GetResultCameraPose 同式)。
        //   键控:引擎记录的 timestamp 与观察者的 effectiveTimestamp 位模式整数相等 ⇒ 投递记录的 recording_frame / t_ns。
        //   另写 poses_backend_{first,final}_by_recording_frame.csv:列与 poses_camera_by_recording_frame.csv 逐列相同,
        //   lidar_ruler.py --xrslam-camera 直接吃。
        recordLock.lock()
        let bkEvents = backendEvents
        let bkWindow = backendWindowAtEnd
        let byEff = offeredByEffective
        recordLock.unlock()
        var bkFirst: [UInt64: XRSLAMBackendPose] = [:]
        var bkFinal: [UInt64: (XRSLAMBackendPose, String)] = [:]
        for e in bkEvents {
            let key = e.timestamp.bitPattern
            if e.kind == Int32(XRSLAM_BACKEND_POSE_FIRST) {
                if bkFirst[key] == nil { bkFirst[key] = e }
            } else if e.kind == Int32(XRSLAM_BACKEND_POSE_FINAL) {
                bkFinal[key] = (e, "marginalized")
            }
        }
        for w in bkWindow where bkFinal[w.timestamp.bitPattern] == nil {
            bkFinal[w.timestamp.bitPattern] = (w, "window_at_end")
        }
        func poseCols(_ p: XRSLAMBackendPose) -> String {
            String(format: "%.9f,%.9f,%.9f,%.9f,%.9f,%.9f,%.9f",
                   p.translation.0, p.translation.1, p.translation.2,
                   p.quaternion.0, p.quaternion.1, p.quaternion.2, p.quaternion.3)
        }
        var backend = "recording_frame,t_ns,engine_t,frame_id,first_is_keyframe,"
            + "first_tx,first_ty,first_tz,first_qx,first_qy,first_qz,first_qw,final_source,"
            + "final_tx,final_ty,final_tz,final_qx,final_qy,final_qz,final_qw\n"
        var backendFirstKeyed = "recording_frame,t_ns,tx,ty,tz,qx,qy,qz,qw,engine_t\n"
        var backendFinalKeyed = "recording_frame,t_ns,tx,ty,tz,qx,qy,qz,qw,engine_t\n"
        var backendRows = 0, backendFirstRows = 0, backendFinalRows = 0, backendUnmapped = 0
        for f in bkFirst.values.sorted(by: { $0.timestamp < $1.timestamp }) {
            let key = f.timestamp.bitPattern
            let off = byEff[key]
            let recFrame = off?.recordingFrameIndex ?? -1
            let tns = off?.timestampNanoseconds ?? -1
            if off == nil { backendUnmapped += 1 }
            var row = String(format: "%ld,%lld,%.9f,%llu,%d,", recFrame, tns, f.timestamp,
                             f.frame_id, f.is_keyframe) + poseCols(f) + ","
            if let fs = bkFinal[key] {
                row += fs.1 + "," + poseCols(fs.0)
            } else {
                row += ",,,,,,,"
            }
            backend += row + "\n"
            backendRows += 1
            if recFrame >= 0 {
                backendFirstKeyed += String(format: "%ld,%lld,", recFrame, tns) + poseCols(f)
                    + String(format: ",%.9f\n", f.timestamp)
                backendFirstRows += 1
                if let fs = bkFinal[key] {
                    backendFinalKeyed += String(format: "%ld,%lld,", recFrame, tns) + poseCols(fs.0)
                        + String(format: ",%.9f\n", fs.0.timestamp)
                    backendFinalRows += 1
                }
            }
        }
        var outputs: [String: Any] = [:]
        outputs["backend_pose_unmapped_rows"] = backendUnmapped
        for (name, text, rows) in [("poses_backend_by_recording_frame.csv", backend, backendRows),
                                   ("poses_backend_first_by_recording_frame.csv", backendFirstKeyed,
                                    backendFirstRows),
                                   ("poses_backend_final_by_recording_frame.csv", backendFinalKeyed,
                                    backendFinalRows),
                                   ("poses_body.tum", body, bodyRows),
                                   ("poses_camera.tum", camera, cameraRows),
                                   ("poses_camera_by_recording_frame.csv", cameraByFrame,
                                    cameraByFrameRows),
                                   ("frame_timing.csv", timing, recs.count),
                                   ("intrinsics_ledger.csv", ledger, recs.count)] {
            let data = text.data(using: .utf8)!
            try data.write(to: outDir.appendingPathComponent(name))
            outputs[name] = [
                "rows": rows,
                "bytes": data.count,
                "sha256": DeviceRecordingLoader.hex(SHA256.hash(data: data)),
            ] as [String: Any]
        }
        return outputs
    }

    private static func tumRow(_ p: PWXrslamRawPose) -> String {
        // timestamp tx ty tz qx qy qz qw(euroc_runner.cpp:249-254 的列序与精度)
        String(format: "%.9f %.7f %.7f %.7f %.7f %.7f %.7f %.7f\n",
               p.timestamp, p.translation.0, p.translation.1, p.translation.2,
               p.quaternion.0, p.quaternion.1, p.quaternion.2, p.quaternion.3)
    }

    // MARK: 汇总小件

    private static func invariants(stats: UnsafeMutablePointer<Int64>, observations: Int,
                                   offered: Int, pace: String,
                                   ik: UnsafeMutablePointer<Double>, ikRc: Int32) -> [String: Any] {
        // 源的回放收尾闸(BenchmarkCoordinator.swift:1341-1395)的同义:交出去的都到了、
        // 队列没丢。paced-live-drop 档允许 frames_dropped > 0(那正是它要看的)。
        var failed: [String] = []
        let framesDropped = stats[11], imuDropped = stats[12]
        let rejectedNonMono = stats[4], rejectedInvalid = stats[5]
        if pace != "paced-live-drop" && framesDropped != 0 { failed.append("frames_dropped") }
        if imuDropped != 0 { failed.append("imu_dropped") }
        if rejectedNonMono != 0 { failed.append("rejected_non_monotonic") }
        if rejectedInvalid != 0 { failed.append("rejected_invalid_argument") }
        if stats[9] != 0 { failed.append("camera_lock_failures") }
        if Int64(observations) != stats[10] - framesDropped {
            failed.append("observations_vs_offered")
        }
        if ikRc == 0 && ik[30] != 0 { failed.append("intrinsics_trace_sequence_mismatch") }
        return ["passed": failed.isEmpty, "failed": failed]
    }

    fileprivate static func recordingSummary(_ ds: DeviceRecordingDataset) -> [String: Any] {
        let m = ds.manifest
        let r = ds.report
        var out: [String: Any] = [
            "recording_id": ds.recordingID,
            "recording_dir_name": ds.root.lastPathComponent,
            "camera": [
                "width": m.camera.width, "height": m.camera.height,
                "pixel_format": m.camera.pixelFormat, "nominal_fps": m.camera.nominalFPS,
            ] as [String: Any],
            "manifest_intrinsics": [
                "fx": m.intrinsics.fx, "fy": m.intrinsics.fy,
                "cx": m.intrinsics.cx, "cy": m.intrinsics.cy,
                "source": m.intrinsics.source,
                "cross_check_passed": m.intrinsics.crossCheckPassed,
            ] as [String: Any],
            "frame_count": m.frameCount,
            "imu_sample_count": m.imuSampleCount,
            "frames_digest_sha256": m.framesDigestSHA256,
            "frames_total_byte_count": m.framesTotalByteCount,
            "loss_count": m.lossCount,
            "load_report": [
                "verdict_resolution_1920x1440": r.verdictResolution,
                "loss_count": r.lossCount,
                "frames_digest_verified": r.framesDigestVerified,
                "index_files_sha256_verified": r.indexFilesVerified,
                "camera_rows_total": r.cameraRowsTotal,
                "camera_rows_after_limit": r.cameraRowsAfterLimit,
                "imu_samples": r.imuSamples,
                // [xr-recon-chain 2026-09-25] 装载器 D11:录制的 IMU 格式与两路条数(旧格式 paired_v1 / 0 / 0)。
                "imu_format": r.imuFormat,
                "imu_gyro_samples": r.imuGyroSamples,
                "imu_accel_samples": r.imuAccelSamples,
                "intrinsics_index_present": r.intrinsicsIndexPresent,
                "intrinsics_rows": r.intrinsicsRows,
                "intrinsics_paired": r.intrinsicsPaired,
                "intrinsics_unmatched": r.intrinsicsUnmatched,
                "frames_with_exposure": r.framesWithExposure,
                "leading_camera_frames_without_imu_dropped": r.leadingCameraFramesWithoutImuDropped,
                "camera_imu_timestamp_ties": r.cameraImuTimestampTies,
            ] as [String: Any],
            "replay_camera_frames": ds.cameraFrameCount,
            "replay_imu_rows": ds.imuEventCount,
            "manifest_sha256": sha256(file: ds.root
                .appendingPathComponent(DeviceRecordingManifest.fileName).path) ?? "",
        ]
        if let dev = DeviceRecordingSidecars.deviceModel(root: ds.root) {
            out["device_model"] = dev.model
            out["device_model_source"] = dev.source + "(不在 manifest.files 内,未核哈希)"
        }
        return out
    }

    static func engineIdentity() -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in Bundle.main.infoDictionary ?? [:]
        where k.hasPrefix("PWXrslam") || k == "PWNativeHostUUID" {
            out[k] = v
        }
        out["consumes_per_frame_k"] = PwXrslamEngineIdentity.consumesPerFrameK
        return out
    }

    static func hwMachine() -> String? {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func sha256(file path: String) -> String? {
        guard let d = FileManager.default.contents(atPath: path) else { return nil }
        return DeviceRecordingLoader.hex(SHA256.hash(data: d))
    }

    static func effectiveConfigSha256(slamPath: String, devicePath: String) -> String? {
        guard let s = FileManager.default.contents(atPath: slamPath),
              let d = FileManager.default.contents(atPath: devicePath) else { return nil }
        var joined = s
        joined.append(0)
        joined.append(d)
        return DeviceRecordingLoader.hex(SHA256.hash(data: joined))
    }

    static func json(_ o: Any) -> String {
        let clean = Self.sanitize(o)
        guard JSONSerialization.isValidJSONObject(clean),
              let d = try? JSONSerialization.data(withJSONObject: clean,
                                                  options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    /// JSON 不收 NaN/Inf ⇒ 换成 null(遥测缺席时就是 NaN)。
    private static func sanitize(_ o: Any) -> Any {
        switch o {
        case let d as Double: return d.isFinite ? d : NSNull()
        case let a as [Any]: return a.map(sanitize)
        case let m as [String: Any]: return m.mapValues(sanitize)
        default: return o
        }
    }
}

/// paced 档的迟到统计:投递时刻 − 按录制时间戳应到的时刻。
private struct PwBenchReplayLateness {
    var over5ms = 0
    var maxMs = 0.0
    mutating func add(nowNs: UInt64, expectedNs: UInt64) {
        guard nowNs > expectedNs else { return }
        let ms = Double(nowNs - expectedNs) / 1e6
        if ms > 5 { over5ms += 1 }
        if ms > maxMs { maxMs = ms }
    }
}

// MARK: - C ABI(Dart `lib/vio/replay/bench_replay_native.dart` 绑这几个)

/// 把字符串写进调用方的缓冲(含结尾 0)。够 ⇒ 返回写了多少字节;不够 ⇒ 返回 −需要的字节数,
/// 不写(不截断 JSON)。
private func pwBenchReplayWrite(_ s: String, _ out: UnsafeMutablePointer<CChar>,
                                _ cap: Int32) -> Int32 {
    let bytes = Array(s.utf8)
    guard bytes.count + 1 <= Int(cap) else { return -Int32(bytes.count + 1) }
    bytes.withUnsafeBufferPointer { src in
        out.withMemoryRebound(to: UInt8.self, capacity: bytes.count + 1) { dst in
            if !bytes.isEmpty { dst.update(from: src.baseAddress!, count: bytes.count) }
            dst[bytes.count] = 0
        }
    }
    return Int32(bytes.count)
}

@_cdecl("pw_bench_replay_launch_args")
public func pw_bench_replay_launch_args(_ out: UnsafeMutablePointer<CChar>, _ cap: Int32) -> Int32 {
    pwBenchReplayWrite(PwBenchReplayRunner.json(PwBenchReplayLaunch.snapshot()), out, cap)
}

@_cdecl("pw_bench_replay_inspect")
public func pw_bench_replay_inspect(_ dir: UnsafePointer<CChar>,
                                    _ out: UnsafeMutablePointer<CChar>, _ cap: Int32) -> Int32 {
    pwBenchReplayWrite(PwBenchReplayRunner.inspectJSON(recordingDir: String(cString: dir)),
                       out, cap)
}

/// 0 已开跑;-1 正在跑;-2 配置不对。
@_cdecl("pw_bench_replay_start")
public func pw_bench_replay_start(_ config: UnsafePointer<CChar>) -> Int32 {
    PwBenchReplayRunner.shared.start(configJSON: String(cString: config))
}

@_cdecl("pw_bench_replay_status")
public func pw_bench_replay_status(_ out: UnsafeMutablePointer<CChar>, _ cap: Int32) -> Int32 {
    pwBenchReplayWrite(PwBenchReplayRunner.shared.statusJSON(), out, cap)
}

@_cdecl("pw_bench_replay_cancel")
public func pw_bench_replay_cancel() {
    PwBenchReplayRunner.shared.cancel()
}
