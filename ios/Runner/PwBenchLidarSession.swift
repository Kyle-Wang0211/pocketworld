// PwBenchLidarSession.swift —— 台架「LiDAR 米尺录制」页的原生半边:ARKit 会话 + CoreMotion →
// PwBenchLidarRecordingWriter,外加 4 个 `@_cdecl` 给 dart:ffi(lib/bench_lidar/bench_lidar_native.dart)。
//
// ══ 🔴 口径 ══════════════════════════════════════════════════════════════════════
// **bench-only ruler。** LiDAR 深度只在台架里当研发期米尺,量 XRSLAM / ARKit 的绝对尺度误差;
// 永不进产品代码、产品管线、产品提案。只编进 arloopbench(com.kyle.arloopbench)。
//
// ══ 搬自哪里 ══════════════════════════════════════════════════════════════════════
// 研究仓 research/basalt-vio-phone-bench-20260829 @ 76b8d47,
//   tools/ios_basalt_vio_bench/BasaltVIOBench/ARKitReference/ARKitReferenceSession.swift(502 行)
// 的「record 臂」那一半:同一套 ARWorldTrackingConfiguration(生产 hires43 选法逐字、自动对焦开、
// gravity、关光照估计、水平面检测)、同一段 `.sceneDepth` 先查 supportsFrameSemantics 再插、
// 同一套 didUpdate 次序(内参 → luma → ARKit 位姿 → 深度)、同一个 CoreMotion 陀螺驱动 IMU 采集
// (100 Hz,加速度 ×−9.80665,不用 deviceMotion)、同一个 TUM 行格式。
// 方法地图:exact_upstream = 上述几条;product_adapter = 下列 S1–S6;not_implemented = 源的
// ARKitReferenceAccounting / PreviewFrameTap / 生命周期回执(台架这页不评 ARKit 的实时表现)。
//
// 偏离(每条都有原因):
// S1 delegate 队列用**专用串行队列**(QoS userInteractive),不用 main。源在 SwiftUI 台架里用 main;
//    这里 main 是 Flutter 的 platform 线程,UI/通道消息会排在 ARFrame 回调前面,拖久了 ARKit 会因
//    delegate 持有过多 ARFrame 而停发。帧的时间戳是 ARKit 的采集时间,不受队列影响。
// S2 深度按 `depth_stride` 隔帧录(见 writer W3);`depth` 开关关掉时**不插** `.sceneDepth` ——
//    这样同一台架包能做「开 / 关深度」A/B,量开深度对相机帧流的扰动(丢帧 / 到达间隔 / 回调时延)。
// S3 每帧记跟踪状态(writer W6),并按状态计数进 status。
// S4 计时统计落 `recorder_timing.json`:ARFrame 时间戳间隔(> 1.5× 名义间隔 = ARKit 侧少发的帧)、
//    回调时延(回调时刻 − frame.timestamp)、回调处理耗时(拆 luma / 深度两段)、写入耗时分布与背压峰值。
// S5 到时自动停(`seconds`),停后封口 → 计时 → depth_meta.json → 尺子子集导出(writer W9)。
//    `discard_streams` 为真时(A/B 自测用)封口后删掉 frames.bin / depth*.bin,只留 manifest 与计时。
// S6 录制落在 `Documents/replay_recordings/run-<uuid>/`,即回放页(bench_replay_page.dart)读的目录 ——
//    录完在手机上直接回放出 XRSLAM 位姿,不必把 5 GB 的帧流搬来搬去。input_manifest.json 写
//    `device_model`(hw.machine),回放页按它查相机时间偏置表(PwBenchReplayRecording.swift
//    DeviceRecordingSidecars.deviceModel)。
// S7 [2026-09-24 rec30] **按 XRSLAM 的 30 Hz 准入闸落盘**(`record_hz`,默认 30;0 = 每个 ARFrame 都录)。
//    真机首跑 run-fb5d3a8f 按 60 Hz 录 1920×1440(166 MB/s),17.8 s 起写队列满、丢 19% 帧,整场被回放
//    判有损;而 XRSLAM 本来就只收 30 Hz(PwXrslamLive.swift `PwXrslamOfficialFeed`,门限 0.8/R),
//    尺子子集的帧又必须是录下的帧。⇒ ARKit 仍跑 1920×1440@60 hires 格式(生产 hires43 选法不动,
//    ARKit 参照轨迹的节拍不变),录制器对**每个** ARFrame 调 `PwXrslamOfficialFeed.admits`(与引擎
//    同一个函数、同一个 pts = Double(t_ns)·1e-9),过闸的帧才落 luma / 内参行 / ARKit 位姿 / 深度。
//    闸幂等 ⇒ 回放时引擎那道闸对录下的每一帧都放行,录下的帧 = 引擎收的帧,与从哪一帧开始喂无关。
//    🔴 分辨率不降:仍是整幅 1920×1440 luma(用户:分辨率越高越好)。带宽减半 166 → 83 MB/s。
//    深度步长改按**过闸帧**数(默认每 3 帧一张 = 10 Hz,频率与原来 60 fps 每 6 帧相同)。
// S8 [2026-09-24 rec30] 写法(`write_sync`)与逐秒时间线见 writer W10 / W11;每秒热状态也记。

#if os(iOS)
import ARKit
import AVFoundation
import CoreMotion
import Foundation
import QuartzCore
import simd

final class PwBenchLidarSession: NSObject, ARSessionDelegate, @unchecked Sendable {
    static let shared = PwBenchLidarSession()

    struct Config {
        var seconds: Double = 30
        var depth: Bool = true
        var depthStride: Int = PwBenchLidarRecordingWriter.defaultDepthStride
        var subsetSpacingSeconds: Double = 0.25
        var exportSubset: Bool = true
        var discardStreams: Bool = false
        var outRoot: String = ""
        var tag: String = ""
        /// S7:过闸频率(0 = 每个 ARFrame 都录)。默认 30 = XRSLAM 官方喂料的准入频率。
        var recordHz: Double = 30
        /// S8 / writer W10。
        var writeSync: PwBenchLidarWriteSync = PwBenchLidarRecordingWriter.defaultWriteSync
        var writeSyncValid = true

        init(json: [String: Any]) {
            if let v = json["seconds"] as? NSNumber { seconds = v.doubleValue }
            if let v = json["depth"] as? Bool { depth = v }
            if let v = json["depth_stride"] as? NSNumber { depthStride = max(1, v.intValue) }
            if let v = json["subset_spacing_s"] as? NSNumber { subsetSpacingSeconds = v.doubleValue }
            if let v = json["export_subset"] as? Bool { exportSubset = v }
            if let v = json["discard_streams"] as? Bool { discardStreams = v }
            if let v = json["out_root"] as? String { outRoot = v }
            if let v = json["tag"] as? String { tag = v }
            if let v = json["record_hz"] as? NSNumber { recordHz = v.doubleValue }
            if let v = json["write_sync"] as? String {
                if let m = PwBenchLidarWriteSync(rawValue: v) { writeSync = m } else { writeSyncValid = false }
            }
        }
    }

    private let lock = NSLock()
    private let delegateQueue = DispatchQueue(
        label: "com.kyle.arloopbench.lidar.arkit", qos: .userInteractive)   // S1
    private let controlQueue = DispatchQueue(label: "com.kyle.arloopbench.lidar.control", qos: .userInitiated)
    private var session: ARSession?
    private var writer: PwBenchLidarRecordingWriter?
    private let motion = CMMotionManager()
    private let motionQueue = OperationQueue()

    // 状态(lock 保护)
    private var phase = "idle"
    private var config = Config(json: [:])
    private var runDir: URL?
    private var recordingID = ""
    private var errorText: String?
    private var sceneDepthSupported = false
    private var sceneDepthRequested = false
    private var selectedFormat: [String: Any] = [:]
    private var arFrames = 0
    private var firstFrameTimestamp: Double?
    private var lastFrameTimestamp: Double?
    private var trackingCounts: [String: Int] = [:]
    private var stopRequested = false
    private var thermalAtStart = ""
    private var startedWall = Date()
    // S4 计时
    private var frameIntervals: [Double] = []
    private var callbackLatencyMs: [Double] = []
    private var handlerMs: [Double] = []
    private var lumaCopyMs: [Double] = []
    private var depthCopyMs: [Double] = []
    private var depthOffered = 0
    private var depthMissingOnFrame = 0
    private var result: [String: Any] = [:]
    // S7 准入闸状态
    private var gateHave = false
    private var gateLastPts = 0.0
    private var admittedCount = 0
    private var gatedOut = 0
    private var arkitVideoFPS = 0
    // S8 每秒热状态(下标 = 录制第几秒)
    private var thermalPerSecond: [String] = []

    // MARK: 能力(不开会话)

    func capabilityJSON() -> String {
        var o: [String: Any] = [
            "bench_only_notice": Self.notice,
            "arkit_world_tracking_supported": ARWorldTrackingConfiguration.isSupported,
            "scene_depth_supported": ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth),
            "smoothed_scene_depth_supported":
                ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth),
            "camera_authorization": Self.cameraAuthorizationLabel(),
            "device_model": Self.deviceModel(),
            "thermal_state": Self.thermalLabel(),
        ]
        if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
           let v = try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let free = v.volumeAvailableCapacityForImportantUsage {
            o["free_bytes"] = free
        }
        o["launch"] = Self.launchArgs()
        o["record_defaults"] = [
            "record_hz": Config(json: [:]).recordHz,
            "write_sync": PwBenchLidarRecordingWriter.defaultWriteSync.rawValue,
            "write_sync_choices": PwBenchLidarWriteSync.allCases.map(\.rawValue),
            "depth_stride": PwBenchLidarRecordingWriter.defaultDepthStride,
            "writer_queue_depth": PwBenchLidarRecordingWriter.queueDepth,
            "xrslam_camera_hz_gate": PwXrslamOfficialFeed.resolved.cameraHz,
        ] as [String: Any]
        return Self.json(o)
    }

    /// 自动化用的启动参数(读法同 PwBenchReplayLaunch:先 UserDefaults 的 NSArgumentDomain,再扫 argv)。
    ///   -PWBenchLidarAuto soak|reexport          进页即跑写入吞吐自测 / 给已有录制重导子集
    ///   -PWBenchLidarSoakArms "30:barrier,60:fsync_each,…"   每臂 = 录制频率:写法(默认见 Dart)
    ///   -PWBenchLidarSoakSeconds <秒>             每臂时长(默认 60)
    ///   -PWBenchLidarReexport <run-… 目录名或前缀>   配 Auto=reexport
    ///   -PWBenchLidarReexportLimitFrames <N>      同回放的 -PWBenchReplayLimitFrames(0 = 全部)
    ///   -PWBenchLidarReexportOutName <目录名>      默认 ruler_subset_xr30(不覆盖原来的 ruler_subset)
    static let launchKeys = ["PWBenchLidarAuto", "PWBenchLidarSoakArms", "PWBenchLidarSoakSeconds",
                             "PWBenchLidarReexport", "PWBenchLidarReexportLimitFrames",
                             "PWBenchLidarReexportOutName"]

    static func launchArgs() -> [String: String] {
        var out: [String: String] = [:]
        let args = ProcessInfo.processInfo.arguments
        for k in launchKeys {
            var raw = UserDefaults.standard.string(forKey: k) ?? ""
            if raw.isEmpty, let i = args.firstIndex(of: "-\(k)"), i + 1 < args.count { raw = args[i + 1] }
            if !raw.isEmpty { out[k] = raw }
        }
        return out
    }

    // MARK: 给已有录制重导尺子子集(W12;录制本身一个字节不动)

    /// 0 已开跑;-1 正忙;-2 配置不对。进度 / 结果走 status()(phase exporting → done / failed)。
    func reexportSubset(configJSON: String) -> Int32 {
        guard let data = configJSON.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recPath = o["recording_dir"] as? String, !recPath.isEmpty else { return -2 }
        let outName = (o["out_name"] as? String) ?? "ruler_subset_xr30"
        let spacing = (o["subset_spacing_s"] as? NSNumber)?.doubleValue ?? 0.25
        let hz = (o["camera_hz"] as? NSNumber)?.doubleValue ?? PwXrslamOfficialFeed.resolved.cameraHz
        let limit = (o["limit_frames"] as? NSNumber)?.intValue ?? 0
        guard outName != PwBenchLidarRecordingWriter.rulerSubsetDirectory || o["allow_overwrite"] as? Bool == true
        else { return -2 }
        lock.lock()
        if ["starting", "recording", "stopping", "exporting"].contains(phase) { lock.unlock(); return -1 }
        phase = "exporting"
        errorText = nil
        result = [:]
        let dir = URL(fileURLWithPath: recPath, isDirectory: true)
        runDir = dir
        recordingID = dir.lastPathComponent
        lock.unlock()
        controlQueue.async { [weak self] in
            guard let self else { return }
            do {
                let s = try PwBenchLidarRecordingWriter.exportRulerSubset(
                    recording: dir, minSpacingSeconds: spacing, outName: outName, xrslamCameraHz: hz,
                    limitFrames: limit, gate: PwXrslamOfficialFeed.admits,
                    gateSource: "PwXrslamOfficialFeed.admits")
                NSLog("[bench-lidar] reexport %@/%@ frames=%@", dir.lastPathComponent, outName,
                      "\(s["frames"] ?? "?")")
                self.lock.lock()
                self.result = ["reexport": true, "subset": s, "run_dir": dir.path]
                self.phase = "done"
                self.lock.unlock()
            } catch {
                self.lock.lock()
                self.errorText = "reexport: \(error.localizedDescription)"
                self.phase = "failed"
                self.lock.unlock()
            }
        }
        return 0
    }

    // MARK: 开始

    /// 0 已开录;-1 正在录;-2 配置不对;-3 设备/权限不支持;-4 空间不足。
    func start(configJSON: String) -> Int32 {
        guard let data = configJSON.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return -2 }
        let cfg = Config(json: obj)
        guard !cfg.outRoot.isEmpty, cfg.seconds > 0, cfg.seconds <= 600,
              cfg.recordHz >= 0, cfg.recordHz.isFinite, cfg.writeSyncValid else { return -2 }
        lock.lock()
        if ["starting", "recording", "stopping", "exporting"].contains(phase) {
            lock.unlock(); return -1
        }
        phase = "starting"
        config = cfg
        errorText = nil
        result = [:]
        arFrames = 0
        firstFrameTimestamp = nil
        lastFrameTimestamp = nil
        trackingCounts = [:]
        stopRequested = false
        frameIntervals = []; callbackLatencyMs = []; handlerMs = []; lumaCopyMs = []; depthCopyMs = []
        depthOffered = 0; depthMissingOnFrame = 0
        gateHave = false; gateLastPts = 0; admittedCount = 0; gatedOut = 0
        thermalPerSecond = []
        lock.unlock()

        guard ARWorldTrackingConfiguration.isSupported else { return fail(-3, "ARWorldTrackingConfiguration unsupported") }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { _ in }
            return fail(-3, "相机权限刚请求,允许后再按一次开始")
        default:
            return fail(-3, "相机权限被拒(设置 → Arloopbench → 相机)")
        }

        // ── [port] ARKitReferenceSession.swift:96-202 配置 ──────────────────────────
        let configuration = ARWorldTrackingConfiguration()
        configuration.isAutoFocusEnabled = true          // 生产值(OfficialAetherARKitPlugin.swift)
        configuration.worldAlignment = .gravity
        configuration.isLightEstimationEnabled = false
        configuration.planeDetection = [.horizontal]
        // 生产 capture_format.dart 钉的 "hires43":1920×1440、isRecommendedForHighResolutionFrameCapturing、
        // 取最高帧率。[port] :151-168 逐字。
        guard #available(iOS 16.0, *) else { return fail(-3, "需要 iOS 16") }
        guard let hires = ARWorldTrackingConfiguration.supportedVideoFormats
            .filter({
                Int($0.imageResolution.width) == 1920
                    && Int($0.imageResolution.height) == 1440
                    && $0.isRecommendedForHighResolutionFrameCapturing
            })
            .max(by: { $0.framesPerSecond < $1.framesPerSecond }) else {
            return fail(-3, "没有 1920×1440 hires 视频格式")
        }
        configuration.videoFormat = hires
        // 🔴 **bench-only ruler,永远不是产品输入。** [port] :173-205
        // SDK 头:「Semantic frame understanding is not supported on all devices」,不支持时设置
        // 「An exception is thrown if the option is not supported」(ARConfiguration.h)——ObjC 异常,
        // Swift 接不住 ⇒ 必须先查。`.smoothedSceneDepth` 故意不要(见 writer appendDepth 文档)。
        let supported = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        var requested = false
        if cfg.depth && supported {
            configuration.frameSemantics.insert(.sceneDepth)
            requested = true
        }
        let fps = Double(hires.framesPerSecond)
        // S7:录下的帧流的名义频率 = 过闸频率(闸 0.8/R ⇒ 60 fps 源隔帧取 = 30;R ≥ 源 ⇒ 源频率)。
        let recordedFPS = Self.gatedRate(sourceFPS: fps, hz: cfg.recordHz)
        let format = DeviceRecordingCameraFormat(
            width: Int(hires.imageResolution.width), height: Int(hires.imageResolution.height),
            pixelFormat: "luma8_from_420f_full_range", nominalFPS: recordedFPS)

        // ── 目录、预检、写器 ──────────────────────────────────────────────────────
        let id = UUID().uuidString.lowercased()
        let dir = URL(fileURLWithPath: cfg.outRoot, isDirectory: true)
            .appendingPathComponent("run-\(id)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try PwBenchLidarRecordingWriter.checkFreeSpace(
                at: dir,
                requiredBytes: PwBenchLidarRecordingWriter.projectedByteCount(
                    seconds: cfg.seconds, format: format, depthStride: requested ? cfg.depthStride : 0))
        } catch {
            try? FileManager.default.removeItem(at: dir)
            return fail(-4, error.localizedDescription)
        }
        let w: PwBenchLidarRecordingWriter
        do {
            w = try PwBenchLidarRecordingWriter(directory: dir, recordingID: id, format: format,
                                                depthStride: cfg.depthStride, writeSync: cfg.writeSync)
        } catch {
            return fail(-4, "writer: \(error.localizedDescription)")
        }
        let formatInfo: [String: Any] = [
            "width": format.width, "height": format.height, "fps": hires.framesPerSecond,
            "recommended_for_high_resolution_capture": hires.isRecommendedForHighResolutionFrameCapturing,
            "recorded_fps_nominal": recordedFPS,
        ]
        writeSidecarsAtStart(dir: dir, id: id, cfg: cfg, supported: supported, requested: requested,
                             format: formatInfo)
        lock.lock()
        writer = w
        runDir = dir
        recordingID = id
        sceneDepthSupported = supported
        sceneDepthRequested = requested
        selectedFormat = formatInfo
        arkitVideoFPS = hires.framesPerSecond
        thermalAtStart = Self.thermalLabel()
        startedWall = Date()
        lock.unlock()
        NSLog("[bench-lidar] 🔴 bench-only ruler · start run-%@ depth=%@ supported=%@ stride=%d %dx%d@%d record_hz=%.1f write=%@",
              id, requested ? "on" : "off", supported ? "YES" : "NO", cfg.depthStride,
              format.width, format.height, hires.framesPerSecond, cfg.recordHz, cfg.writeSync.rawValue)

        let s = ARSession()
        s.delegateQueue = delegateQueue
        s.delegate = self
        lock.lock(); session = s; phase = "recording"; lock.unlock()
        DispatchQueue.main.async {
            s.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        }
        return 0
    }

    /// S7:匀速 `sourceFPS` 的源过 0.8/R 闸后的稳态频率 = sourceFPS / k,k = 满足 k/sourceFPS ≥ 0.8/R 的
    /// 最小整数(60 fps、R = 30 ⇒ k = 2 ⇒ 30)。R = 0 ⇒ 不设闸 = 源频率。只用于 manifest 的名义频率与空间预估。
    static func gatedRate(sourceFPS: Double, hz: Double) -> Double {
        guard hz > 0, sourceFPS > 0 else { return sourceFPS }
        var k = 1.0
        while k / sourceFPS < 0.8 / hz { k += 1 }
        return sourceFPS / k
    }

    private func fail(_ code: Int32, _ why: String) -> Int32 {
        lock.lock(); phase = "failed"; errorText = why; lock.unlock()
        NSLog("[bench-lidar] start refused (%d): %@", code, why)
        return code
    }

    // MARK: ARSessionDelegate [port] :300-395

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let handlerStart = CACurrentMediaTime()
        let timestampNS = Int64((frame.timestamp * 1_000_000_000).rounded())
        // S7:回放推给引擎的就是这个值(PwBenchReplay.swift:`Double(f.timestampNanoseconds) * 1e-9`)。
        let pts = Double(timestampNS) * 1e-9
        lock.lock()
        guard let writer, phase == "recording" else { lock.unlock(); return }
        let arIndex = arFrames
        arFrames += 1
        if let last = lastFrameTimestamp { frameIntervals.append(frame.timestamp - last) }
        lastFrameTimestamp = frame.timestamp
        if firstFrameTimestamp == nil { firstFrameTimestamp = frame.timestamp }
        let elapsed = frame.timestamp - (firstFrameTimestamp ?? frame.timestamp)
        callbackLatencyMs.append((handlerStart - frame.timestamp) * 1000)
        let tracking = Self.trackingLabel(frame.camera.trackingState)
        trackingCounts[tracking, default: 0] += 1
        if Int(elapsed) >= thermalPerSecond.count { thermalPerSecond.append(Self.thermalLabel()) }
        let cfg = config
        // S7:与引擎同一个函数、同一个 pts。
        let admitted = PwXrslamOfficialFeed.admits(ptsSeconds: pts, lastAdmittedPts: gateLastPts,
                                                   haveAdmitted: gateHave, cameraHz: cfg.recordHz)
        var admittedIndex = -1
        if admitted {
            gateHave = true
            gateLastPts = pts
            admittedIndex = admittedCount
            admittedCount += 1
        } else {
            gatedOut += 1
        }
        let wantDepth = admitted && sceneDepthRequested && admittedIndex % max(1, cfg.depthStride) == 0
        lock.unlock()

        guard admitted else {
            // 没过闸的帧什么都不落(luma / 内参 / 位姿 / 深度都跟着过闸帧走),只计入上面的 ARKit 统计。
            startMotionRecordingIfNeeded()
            if elapsed >= cfg.seconds { requestStop(reason: "duration") }
            return
        }

        let transform = frame.camera.transform
        let q = simd_quatf(transform)
        let K = PwBenchLidarIntrinsics(
            fx: Double(frame.camera.intrinsics.columns.0.x),
            fy: Double(frame.camera.intrinsics.columns.1.y),
            cx: Double(frame.camera.intrinsics.columns.2.x),
            cy: Double(frame.camera.intrinsics.columns.2.y))
        var cameraIndex: Int?
        let lumaStart = CACurrentMediaTime()
        do {
            try writer.recordIntrinsics(K, timestampSeconds: frame.timestamp,
                                        exposureSeconds: frame.camera.exposureDuration,
                                        arkitTracking: tracking)
            cameraIndex = writer.appendFrame(pixelBuffer: frame.capturedImage,
                                             timestampNanoseconds: timestampNS)
            writer.appendARKitPose(timestampNanoseconds: timestampNS,
                                   tumRow: Self.tumRow(timestampNanoseconds: timestampNS,
                                                       t: transform.columns.3, q: q))
        } catch {
            // 交叉检查不过 ⇒ 立刻停,不让操作者白拍([port] :375-381)。
            lock.lock(); errorText = error.localizedDescription; lock.unlock()
            requestStop(reason: "intrinsics_cross_check")
            return
        }
        let lumaMs = (CACurrentMediaTime() - lumaStart) * 1000
        var depthMs: Double?
        if wantDepth {
            // 🔴 bench-only ruler:同一 ARFrame、同一 frame.timestamp ⇒ 深度与它描述的图像不可能跨帧配错。
            if let depth = frame.sceneDepth {
                let depthStart = CACurrentMediaTime()
                writer.appendDepth(depthMap: depth.depthMap, confidenceMap: depth.confidenceMap,
                                   timestampNanoseconds: timestampNS, cameraFrameIndex: cameraIndex,
                                   arFrameIndex: arIndex, imageIntrinsics: K,
                                   admittedFrameIndex: admittedIndex)
                depthMs = (CACurrentMediaTime() - depthStart) * 1000
            }
        }
        startMotionRecordingIfNeeded()
        let total = (CACurrentMediaTime() - handlerStart) * 1000
        lock.lock()
        handlerMs.append(total)
        lumaCopyMs.append(lumaMs)
        if wantDepth {
            depthOffered += 1
            if let depthMs { depthCopyMs.append(depthMs) } else { depthMissingOnFrame += 1 }
        }
        lock.unlock()
        if elapsed >= cfg.seconds { requestStop(reason: "duration") }
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        lock.lock(); errorText = "ARSession failed: \(error.localizedDescription)"; lock.unlock()
        requestStop(reason: "session_failed")
    }

    func sessionWasInterrupted(_ session: ARSession) {
        lock.lock(); errorText = "ARSession interrupted"; lock.unlock()
        requestStop(reason: "interrupted")
    }

    // MARK: IMU [port] :412-452(逐字:陀螺驱动、100 Hz、×−9.80665、不用 deviceMotion)

    private func startMotionRecordingIfNeeded() {
        guard !motion.isGyroActive else { return }
        motionQueue.maxConcurrentOperationCount = 1
        motion.gyroUpdateInterval = 1.0 / 100.0
        motion.accelerometerUpdateInterval = 1.0 / 100.0
        motion.startAccelerometerUpdates()
        motion.startGyroUpdates(to: motionQueue) { [weak self] data, _ in
            guard let self, let data else { return }
            self.lock.lock(); let w = self.phase == "recording" ? self.writer : nil; self.lock.unlock()
            guard let w, let accel = self.motion.accelerometerData else { return }
            let timestampNS = Int64((data.timestamp * 1_000_000_000).rounded())
            w.appendIMU(
                timestampNanoseconds: timestampNS,
                gyroscope: (data.rotationRate.x, data.rotationRate.y, data.rotationRate.z),
                acceleration: (accel.acceleration.x * -9.80665,
                               accel.acceleration.y * -9.80665,
                               accel.acceleration.z * -9.80665))
        }
    }

    private func stopMotionRecording() {
        if motion.isGyroActive { motion.stopGyroUpdates() }
        if motion.isAccelerometerActive { motion.stopAccelerometerUpdates() }
    }

    // MARK: 停止 → 封口 → 计时 → 子集

    func requestStop(reason: String) {
        lock.lock()
        guard phase == "recording", !stopRequested else { lock.unlock(); return }
        stopRequested = true
        phase = "stopping"
        let s = session
        lock.unlock()
        NSLog("[bench-lidar] stop (%@)", reason)
        controlQueue.async { [weak self] in
            guard let self else { return }
            // [port] :269-294 —— 先摘 delegate 再 pause;已排队的回调看到 phase≠recording 直接返回。
            DispatchQueue.main.sync {
                s?.delegate = nil
                s?.pause()
            }
            self.stopMotionRecording()
            self.delegateQueue.sync {}     // 排空已进队列的回调
            self.finishRecording(stopReason: reason)
        }
    }

    private func finishRecording(stopReason: String) {
        lock.lock()
        let w = writer
        let dir = runDir
        let cfg = config
        lock.unlock()
        guard let w, let dir else { return }
        var out: [String: Any] = ["stop_reason": stopReason]
        do {
            let manifest = try w.finish()
            out["manifest"] = [
                "recording_id": manifest.recordingID,
                "frame_count": manifest.frameCount,
                "imu_sample_count": manifest.imuSampleCount,
                "loss_count": manifest.lossCount,
                "loss_write_queue_full": manifest.lossWriteQueueFull ?? 0,
                "peak_in_flight": manifest.peakInFlight ?? 0,
                "slowest_write_ms": manifest.slowestWriteMilliseconds ?? 0,
                "depth_present": manifest.depthPresent ?? false,
                "depth_frame_count": manifest.depthFrameCount ?? 0,
                "depth_dropped": manifest.depthDropped ?? 0,
                "depth_width": manifest.depthWidth ?? 0,
                "depth_height": manifest.depthHeight ?? 0,
            ] as [String: Any]
        } catch {
            lock.lock(); errorText = "finish: \(error.localizedDescription)"; phase = "failed"; lock.unlock()
            NSLog("[bench-lidar] finish failed: %@", error.localizedDescription)
            return
        }
        let timing = timingJSON(writer: w)
        out["timing"] = timing
        Self.writeJSON(timing, to: dir.appendingPathComponent("recorder_timing.json"))
        Self.writeJSON(depthMeta(), to: dir.appendingPathComponent("depth_meta.json"))

        lock.lock(); let depthWasRequested = sceneDepthRequested; lock.unlock()
        if cfg.exportSubset, depthWasRequested, !cfg.discardStreams {
            lock.lock(); phase = "exporting"; lock.unlock()
            do {
                // W12:子集只挑本 App 回放时引擎会收的帧 —— 闸函数就是引擎那一个。
                out["subset"] = try PwBenchLidarRecordingWriter.exportRulerSubset(
                    recording: dir, minSpacingSeconds: cfg.subsetSpacingSeconds,
                    xrslamCameraHz: PwXrslamOfficialFeed.resolved.cameraHz,
                    gate: PwXrslamOfficialFeed.admits, gateSource: "PwXrslamOfficialFeed.admits")
            } catch {
                out["subset_error"] = error.localizedDescription
            }
        }
        if cfg.discardStreams {   // S5:A/B 自测只留 manifest 与计时
            for name in [DeviceRecordingManifest.framesStreamPath,
                         PwBenchLidarRecordingWriter.depthStreamPath,
                         PwBenchLidarRecordingWriter.depthConfidencePath] {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent(name))
            }
            out["streams_discarded"] = true
        }
        out["run_dir"] = dir.path
        NSLog("[bench-lidar] done run-%@ %@", recordingID, Self.json(out["manifest"] ?? [:]))
        lock.lock()
        result = out
        phase = "done"
        session = nil
        writer = nil
        lock.unlock()
    }

    // MARK: 旁证文件

    private static let notice =
        "🔴 bench-only ruler:LiDAR 深度只用于研发期标定台架,永不进入产品代码、产品管线或产品方案"

    private func writeSidecarsAtStart(dir: URL, id: String, cfg: Config, supported: Bool,
                                      requested: Bool, format: [String: Any]) {
        // 与 viobench-recordings/run-*/config.json 同一套键,再加深度与队列几条。
        Self.writeJSON([
            "algorithm": "ARWorldTrackingConfiguration",
            "autofocus": true,
            "delegate_queue": "com.kyle.arloopbench.lidar.arkit (serial, userInteractive)",
            "light_estimation": false,
            "plane_detection": ["horizontal"],
            "production_source": "OfficialAetherARKitPlugin.startSession (hires43)",
            "recorder": "arloopbench PwBenchLidarSession (port of BasaltVIOBench ARKitReferenceSession @76b8d47)",
            "run_options": ["resetTracking", "removeExistingAnchors"],
            "video_format_policy": "locked_1920x1440_high_resolution_recommended_highest_fps",
            "selected_video_format": format,
            "world_alignment": "gravity",
            "scene_depth_supported": supported,
            "scene_depth_requested": requested,
            "scene_depth_role": "bench_only_metric_ruler_not_a_product_input",
            "smoothed_scene_depth": false,
            "depth_stride": cfg.depthStride,
            "depth_stride_unit": "admitted (recorded) frames",
            "record_hz": cfg.recordHz,
            "record_gate": cfg.recordHz > 0
                ? "PwXrslamOfficialFeed.admits: record an ARFrame iff it is the first, or "
                    + "Double(t_ns)*1e-9 - last_recorded_pts >= 0.8/record_hz (same function the "
                    + "XRSLAM replay gate calls ⇒ every recorded frame is admitted on replay)"
                : "off (every ARFrame recorded)",
            "write_sync": cfg.writeSync.rawValue,
            "writer_queue_depth": PwBenchLidarRecordingWriter.queueDepth,
            "tag": cfg.tag,
        ], to: dir.appendingPathComponent("config.json"))
        Self.writeJSON([
            "calibration_owner": "apple_arkit_runtime",
            "intrinsics_source": "ARFrame.camera.intrinsics",
            "pose_frame": "world_from_camera",
            "status": "runtime_selected_not_a_cross_engine_calibration",
        ], to: dir.appendingPathComponent("calibration.json"))
        Self.writeJSON([
            "device_model": Self.deviceModel(),
            "engine": "arkit_reference",
            "recorder": "arloopbench_lidar_ruler_page",
            "uses_arkit": true,
            "external_ground_truth": requested ? "lidar_scene_depth_bench_only_ruler" : "none",
            "operating_system_version": ProcessInfo.processInfo.operatingSystemVersionString,
        ], to: dir.appendingPathComponent("input_manifest.json"))
    }

    private func depthMeta() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return [
            "bench_only_notice": Self.notice,
            "depth_source": "ARFrame.sceneDepth",
            "scene_depth_supported": sceneDepthSupported,
            "scene_depth_requested": sceneDepthRequested,
            "depth_stride_ar_frames": config.depthStride,
            "depth_offered": depthOffered,
            "depth_missing_on_frame": depthMissingOnFrame,
            "smoothed_scene_depth_recorded": false,
            "smoothed_scene_depth_reason":
                "Apple: 'the framework smoothes the depth data over time to lessen its frame-to-frame "
                + "delta' (developer.apple.com/documentation/arkit/arframe/smoothedscenedepth) — "
                + "temporal smoothing mixes earlier frames into this frame's depth, so it no longer "
                + "corresponds one-to-one with this frame's pose; a ruler must be this frame's own "
                + "measurement, not another estimator's output",
            "depth_semantics":
                "Apple ARDepthData: 'Every pixel in the depthMap maps to a region of the visible scene "
                + "(capturedImage), where the pixel value defines that region's distance from the plane "
                + "of the camera in meters.' ⇒ planar z-depth, same FOV as capturedImage",
            "depth_origin":
                "WWDC20-10611: RGB and LiDAR readings 'are fused together using advanced machine learning "
                + "algorithms to create a dense depth map'; 'available at 60 Hz, associated with each AR "
                + "frame'. confidenceMap says how much each pixel is LiDAR-supported.",
            "pixel_mapping_inference":
                "u_d = (u_c + 0.5) * W_d / W_c - 0.5 (pixel-area centres); k_depth in depth.pwvi rows "
                + "uses the same rule. Inferred from the two quotes above + resolution ratio; NOT an "
                + "Apple-published formula.",
            "confidence_levels": ["0 low", "1 medium", "2 high"],
            "selected_video_format": selectedFormat,
        ]
    }

    private func timingJSON(writer w: PwBenchLidarRecordingWriter) -> [String: Any] {
        let snap = w.timingSnapshot()
        let timeline = w.perSecondTimeline()
        lock.lock(); defer { lock.unlock() }
        let fps = (selectedFormat["fps"] as? Int).map(Double.init) ?? 60
        let nominal = 1.0 / fps
        let gaps = frameIntervals.filter { $0 > 1.5 * nominal }
        let missed = frameIntervals.reduce(0) { $0 + max(0, Int(($1 / nominal).rounded()) - 1) }
        // 首尾两秒是半秒桶,不进持续写入速率的最小/最大。
        let sustained = timeline.dropFirst().dropLast().map { ($0["written_mb"] as? Double) ?? 0 }
        return [
            "schema": "pw.bench.lidar-recorder-timing/2",
            "depth_requested": sceneDepthRequested,
            "depth_stride": config.depthStride,
            "depth_stride_unit": "admitted (recorded) frames",
            "nominal_fps": fps,
            "arkit_video_fps": arkitVideoFPS,
            "record_hz": config.recordHz,
            "admitted_frames": admittedCount,
            "gated_out_frames": gatedOut,
            "write_sync": snap.writeSync,
            "barrier_fallbacks": snap.barrierFallbacks,
            "nocache_set_failed": snap.noCacheSetFailed,
            "written_mb_per_s_interior_min_max": sustained.isEmpty ? [] : [sustained.min()!, sustained.max()!],
            "per_second": timeline,
            "thermal_per_second": thermalPerSecond,
            "ar_frames": arFrames,
            "duration_s": (lastFrameTimestamp ?? 0) - (firstFrameTimestamp ?? 0),
            // ARKit 侧:到达间隔 > 1.5× 名义 ⇒ ARKit 少发了帧(在写器之前)。
            "arkit_frame_interval_ms": Self.stats(frameIntervals.map { $0 * 1000 }),
            "arkit_interval_gaps_over_1_5x": gaps.count,
            "arkit_frames_missed_estimate": missed,
            "callback_latency_ms": Self.stats(callbackLatencyMs),
            "handler_ms": Self.stats(handlerMs),
            "luma_copy_ms": Self.stats(lumaCopyMs),
            "depth_copy_ms": Self.stats(depthCopyMs),
            "frame_write_ms": Self.stats(snap.frameWriteMilliseconds),
            "writer": [
                "frames_accepted": snap.frameCount,
                "loss_count": snap.lossCount,
                "loss_write_queue_full": snap.lossWriteQueueFull,
                "peak_in_flight": snap.peakInFlight,
                "queue_depth": PwBenchLidarRecordingWriter.queueDepth,
                "slowest_frame_write_ms": snap.slowestFrameWriteMilliseconds,
                "depth_frames_written": snap.depthFramesWritten,
                "depth_dropped": snap.depthDropped,
                "depth_format_mismatch": snap.depthFormatMismatch,
                "depth_peak_in_flight": snap.depthPeakInFlight,
                "slowest_depth_write_ms": snap.slowestDepthWriteMilliseconds,
            ] as [String: Any],
            "tracking_counts": trackingCounts,
            "thermal_start": thermalAtStart,
            "thermal_end": Self.thermalLabel(),
        ]
    }

    // MARK: 状态

    func statusJSON() -> String {
        lock.lock()
        var o: [String: Any] = [
            "phase": phase,
            "ar_frames": arFrames,
            "elapsed_s": (lastFrameTimestamp ?? 0) - (firstFrameTimestamp ?? lastFrameTimestamp ?? 0),
            "seconds": config.seconds,
            "depth": config.depth,
            "scene_depth_supported": sceneDepthSupported,
            "scene_depth_requested": sceneDepthRequested,
            "tracking_counts": trackingCounts,
            "recording_id": recordingID,
            "tag": config.tag,
            "record_hz": config.recordHz,
            "write_sync": config.writeSync.rawValue,
            "admitted_frames": admittedCount,
            "gated_out_frames": gatedOut,
        ]
        if let e = errorText { o["error"] = e }
        if let d = runDir { o["run_dir"] = d.path }
        if !result.isEmpty { o["result"] = result }
        let w = writer
        lock.unlock()
        if let w {
            let s = w.timingSnapshot()
            o["frames_accepted"] = s.frameCount
            o["loss_count"] = s.lossCount
            o["depth_frames_written"] = s.depthFramesWritten
            o["depth_dropped"] = s.depthDropped
            o["peak_in_flight"] = s.peakInFlight
        }
        return Self.json(o)
    }

    // MARK: 小件

    /// [port] :397-407 TUM:`timestamp tx ty tz qx qy qz qw`
    static func tumRow(timestampNanoseconds: Int64, t: simd_float4, q: simd_quatf) -> String {
        let seconds = timestampNanoseconds / 1_000_000_000
        let remainder = timestampNanoseconds % 1_000_000_000
        return String(format: "%lld.%09lld %.9f %.9f %.9f %.9f %.9f %.9f %.9f",
                      seconds, remainder, Double(t.x), Double(t.y), Double(t.z),
                      Double(q.imag.x), Double(q.imag.y), Double(q.imag.z), Double(q.real))
    }

    static func trackingLabel(_ state: ARCamera.TrackingState) -> String {
        switch state {
        case .normal: return "normal"
        case .notAvailable: return "not_available"
        case .limited(let reason):
            switch reason {
            case .initializing: return "limited_initializing"
            case .excessiveMotion: return "limited_excessive_motion"
            case .insufficientFeatures: return "limited_insufficient_features"
            case .relocalizing: return "limited_relocalizing"
            @unknown default: return "limited_other"
            }
        }
    }

    static func stats(_ xs: [Double]) -> [String: Any] {
        guard !xs.isEmpty else { return ["n": 0] }
        let s = xs.sorted()
        func p(_ q: Double) -> Double { s[min(s.count - 1, Int((q * Double(s.count - 1)).rounded()))] }
        return ["n": s.count, "p50": p(0.5), "p95": p(0.95), "p99": p(0.99), "max": s.last!,
                "mean": s.reduce(0, +) / Double(s.count)]
    }

    static func cameraAuthorizationLabel() -> String {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return "authorized"
        case .notDetermined: return "not_determined"
        case .denied: return "denied"
        case .restricted: return "restricted"
        @unknown default: return "unknown"
        }
    }

    static func thermalLabel() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func deviceModel() -> String {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    static func json(_ o: Any) -> String {
        guard JSONSerialization.isValidJSONObject(o),
              let d = try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }

    static func writeJSON(_ o: [String: Any], to url: URL) {
        guard JSONSerialization.isValidJSONObject(o),
              let d = try? JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys])
        else { return }
        try? d.write(to: url, options: .atomic)
    }
}

// MARK: - C ABI(dart:ffi)。缓冲约定同 PwBenchReplay.swift:够 ⇒ 返回字节数;不够 ⇒ −需要的字节数、不写。

private func pwBenchLidarWrite(_ s: String, _ out: UnsafeMutablePointer<CChar>, _ cap: Int32) -> Int32 {
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

@_cdecl("pw_bench_lidar_capability")
public func pw_bench_lidar_capability(_ out: UnsafeMutablePointer<CChar>, _ cap: Int32) -> Int32 {
    pwBenchLidarWrite(PwBenchLidarSession.shared.capabilityJSON(), out, cap)
}

@_cdecl("pw_bench_lidar_start")
public func pw_bench_lidar_start(_ config: UnsafePointer<CChar>) -> Int32 {
    PwBenchLidarSession.shared.start(configJSON: String(cString: config))
}

@_cdecl("pw_bench_lidar_stop")
public func pw_bench_lidar_stop() {
    PwBenchLidarSession.shared.requestStop(reason: "user")
}

@_cdecl("pw_bench_lidar_status")
public func pw_bench_lidar_status(_ out: UnsafeMutablePointer<CChar>, _ cap: Int32) -> Int32 {
    pwBenchLidarWrite(PwBenchLidarSession.shared.statusJSON(), out, cap)
}

/// [2026-09-24 rec30] 给已有录制重导尺子子集(只挑 XRSLAM 回放会收的帧)。0 已开跑;-1 正忙;-2 配置不对。
@_cdecl("pw_bench_lidar_reexport_subset")
public func pw_bench_lidar_reexport_subset(_ config: UnsafePointer<CChar>) -> Int32 {
    PwBenchLidarSession.shared.reexportSubset(configJSON: String(cString: config))
}
#endif
