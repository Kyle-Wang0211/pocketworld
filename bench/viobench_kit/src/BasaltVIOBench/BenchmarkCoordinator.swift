import CoreGraphics
import Foundation
import UIKit

private final class SystemSampleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [SystemMetricSample] = []

    func append(_ sample: SystemMetricSample) { lock.withLock { values.append(sample) } }
    var count: Int { lock.withLock { values.count } }
    var last: SystemMetricSample? { lock.withLock { values.last } }
    func snapshot(droppingFirst count: Int = 0) -> [SystemMetricSample] {
        lock.withLock { Array(values.dropFirst(count)) }
    }
}


/// Polls the engine's IMU-propagated pose on its own thread, on an absolute time grid.
///
/// [2026-09-09] Polling from inside the live drain loop capped delivery at 52.3 poses/s for a 60 Hz
/// request: that loop takes one pose per iteration and an iteration sometimes runs past 16.7 ms, so
/// the measurement was reporting the harness, not the engine. A consumer of a tracker does not poll
/// inside its own sensor loop -- ARKit hands poses to a display-rate callback -- so this thread is
/// what makes the pose rate an engine measurement.
///
/// Serialisation is the bridge's: xrslam_bench_query_pose takes the same mutex as the submit path.
final class PosePoller {
    private let session: ActiveVIOEngineSession
    private let periodNanoseconds: UInt64
    private let lock = NSLock()
    private var collected: [NativePoseSample] = []
    private var stopping = false
    private var thread: Thread?
    private(set) var queryFailures = 0

    init(session: ActiveVIOEngineSession, hz: Int) {
        self.session = session
        self.periodNanoseconds = UInt64(1_000_000_000 / max(1, hz))
    }

    func start() {
        let t = Thread { [weak self] in self?.run() }
        t.qualityOfService = .userInteractive
        t.name = "pose-poller"
        thread = t
        t.start()
    }

    private func run() {
        var deadline = DispatchTime.now().uptimeNanoseconds
        while true {
            lock.lock(); let done = stopping; lock.unlock()
            if done { return }
            deadline &+= periodNanoseconds
            let now = DispatchTime.now().uptimeNanoseconds
            if deadline > now {
                // Absolute grid: never "sleep one period from now", which folds each iteration's
                // overshoot into the next interval.
                Thread.sleep(forTimeInterval: Double(deadline &- now) / 1_000_000_000)
            } else if now &- deadline > periodNanoseconds {
                deadline = now   // fell far behind (a stall); resynchronise rather than burst
            }
            do {
                if let sample = try session.queryPose() {
                    lock.lock(); collected.append(sample); lock.unlock()
                }
            } catch {
                lock.lock(); queryFailures += 1; lock.unlock()
            }
        }
    }

    func drain() -> [NativePoseSample] {
        lock.lock(); defer { lock.unlock() }
        let out = collected
        collected.removeAll(keepingCapacity: true)
        return out
    }

    func stop() {
        lock.lock(); stopping = true; lock.unlock()
        while let t = thread, !t.isFinished { Thread.sleep(forTimeInterval: 0.001) }
        thread = nil
    }
}

final class BenchmarkCoordinator {
    // [bench 2026-09-05] `-PWXrslamDropStaleCamera`: graceful degradation under overload. When the engine's producer-side
    // gate (xrslam await_capacity) stalls the feeder, sensor events pile up in the serial handoff (peak 155 of 264 seen live,
    // p95 latency 864 ms). With the flag, each drained batch submits only its NEWEST camera frame (IMU events all pass, in
    // order) and counts the older frames as stale drops. Without overload a batch holds at most one camera frame, so the
    // default path is byte-identical.
    private static let dropStaleCamera = ProcessInfo.processInfo.arguments.contains("-PWXrslamDropStaleCamera")
    // [bench 2026-09-09] `-PWPosePollHz N`: emit poses by polling the engine's IMU-propagated pose at
    // N Hz instead of taking one per processed camera frame. ARKit delivers 60 ARFrames/s while
    // skipping the vision work on some of them (WWDC18 610), so counting our frame results against
    // its ARFrame count compares two different quantities. xrslam already propagates
    // (Detail::get_latest_pose through frontal_imus); this reads it. xrslam arm only, live only, and
    // when it is off nothing about the pose path changes.
    private static let posePollHz: Int = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-PWPosePollHz"), i + 1 < args.count,
              let hz = Int(args[i + 1]), hz > 0, hz <= 240 else { return 0 }
        return hz
    }()
    private var lastPosePollNS: UInt64 = 0
    private var lastPollSensorNS: Int64 = 0
    // [2026-09-09] Time-to-first-pose splits into three parts and only the middle one is the engine's:
    // the capture session warming up, the engine consuming ~40 frames to initialise, and the first
    // pose reaching us. Counting only the total made a 2.1 s gap invisible.
    private var firstCameraSubmittedNS: UInt64 = 0
    private var firstEngineResultNS: UInt64 = 0
    private var polledPoseCount: UInt64 = 0
    private var xrslamStaleCameraDrops: UInt64 = 0
    enum CoordinatorError: LocalizedError {
        case backendUnavailable(String)
        case anotherRunActive
        case aborted
        case invalidRun(String)
        case receiptWrite(Error)

        var errorDescription: String? {
            switch self {
            case .backendUnavailable(let name):
                return "\(name) 后端尚未装入此构建，拒绝生成假跑分。"
            case .anotherRunActive:
                return "已有另一条 VIO 测试臂占用传感器；三条臂禁止同时运行。"
            case .aborted: return "测试已由用户中止，终态收据已经保存。"
            case .invalidRun(let reason): return "实验无效：\(reason)"
            case .receiptWrite(let error): return "实验收据写入失败：\(error.localizedDescription)"
            }
        }
    }

    private let backend: BenchBackend
    private let mode: BenchMode
    private let datasetURL: URL?
    private let onPhase: (BenchPhase) -> Void
    private let onSnapshot: (LiveSnapshot) -> Void
    /// Display only. Publishing a source never starts, stops or reconfigures
    /// capture; the coordinator stays the sole owner of camera lifecycle.
    private let onPreview: (BenchPreviewSource) -> Void
    private let onPreviewFrame: (CGImage) -> Void
    private let onFinish: (Result<URL, Error>) -> Void
    private let queue = DispatchQueue(label: "com.kyle.viobench.run", qos: .userInitiated)
    private let lock = NSLock()
    private var abortRequested = false
    /// Continuously refreshed so an aborted run still has evidence.
    ///
    /// Aborting used to write `metrics: [:]` and a diagnostics stub with
    /// `status: "unavailable"`, so a 48 s device run on 2026-08-30 produced no
    /// measurable artifact at all -- and aborting after ~15 s is exactly the
    /// diagnostic protocol. The snapshot is kept as plain values rather than
    /// live objects, because the abort unwinds through defers that tear those
    /// objects down before the handler runs.
    private struct LiveRunProgress {
        var startNS: UInt64
        var firstPoseLatencyMS: Double?
        var latenciesMS: [Double] = []
        var poseCount: Int = 0
        var native: VIOEngineSnapshot?
        var transport: LiveSensorTransportSnapshot?
        var arkit: ARKitReferenceSnapshot?
        var applicationLifecycleViolations: UInt64 = 0
    }
    private var liveProgress: LiveRunProgress?

    /// Owned by the coordinator and started before the run clock, because the
    /// thermal dwell computation needs a sample at or before the measurement
    /// window start to seed the initial state.
    ///
    /// These used to be created inside each run function and started hundreds of
    /// lines after `liveRunStartNS` was taken, so the first sample was always
    /// later than the window start, `Statistics.thermalDwell` always returned
    /// nil, and every live run that reached the computation was invalidated with
    /// `thermal_telemetry_unavailable`. A full clean 300 s run on 2026-08-30 --
    /// 8,990 frames in, 8,990 poses out, zero loss -- was discarded that way.
    ///
    /// Starting first is also what the contract's `metric_scope` already
    /// declared: the live clock, CPU accounting and system sampling begin before
    /// estimator initialisation. The code had it backwards.
    private let systemSamples = SystemSampleStore()
    private lazy var sampler = SystemMetricSampler { [systemSamples] sample in
        systemSamples.append(sample)
    }

    private weak var activeTransport: LiveSensorTransport?
    private var activeSession: ActiveVIOEngineSession?
    private var activeARKitSession: ARKitReferenceSession?

    init(
        backend: BenchBackend,
        mode: BenchMode,
        datasetURL: URL?,
        onPhase: @escaping (BenchPhase) -> Void,
        onSnapshot: @escaping (LiveSnapshot) -> Void,
        onPreview: @escaping (BenchPreviewSource) -> Void = { _ in },
        onPreviewFrame: @escaping (CGImage) -> Void = { _ in },
        onFinish: @escaping (Result<URL, Error>) -> Void
    ) {
        self.backend = backend
        self.mode = mode
        self.datasetURL = datasetURL
        self.onPhase = onPhase
        self.onSnapshot = onSnapshot
        self.onPreview = onPreview
        self.onPreviewFrame = onPreviewFrame
        self.onFinish = onFinish
    }

    func start() {
        queue.async { [weak self] in self?.run() }
    }

    func abort() {
        lock.withLock { abortRequested = true }
        lock.withLock { activeSession }?.requestStop()
        lock.withLock { activeARKitSession }?.pause()
    }

    private func run() {
        guard let runLease = BenchRunLease.acquire(backend: backend) else {
            onFinish(.failure(CoordinatorError.anotherRunActive))
            return
        }
        defer { runLease.release() }
        guard backend == .arkit || ActiveVIOEngineSession.backendAvailable(backend) else {
            onFinish(.failure(CoordinatorError.backendUnavailable(backend.displayName)))
            return
        }
        onPhase(.preparing)
        var prepared: PreparedBenchmarkRun?
        var datasetAccessLease: DatasetAccessLease?
        defer { datasetAccessLease?.close() }
        do {
            if let datasetURL {
                datasetAccessLease = try DatasetAccessLease.acquire(datasetURL: datasetURL)
            }
            // Preparation runs before the started receipt exists, so anything it
            // throws leaves a run directory with nothing in it and no statement
            // of why. That is what made a failing replay look like a hanging one
            // for twenty minutes.
            NSLog("[VIOBench] preparing %@ / %@ dataset=%@",
                  backend.id, mode.rawValue, datasetURL?.lastPathComponent ?? "none")
            let context = try BenchmarkRunPreparation.prepare(
                backend: backend,
                mode: mode,
                datasetURL: datasetURL
            )
            // `record` owns the camera through ARKit, because iOS grants the rear
            // camera to one session and the recording must be of the frames the
            // ARKit arm is actually tracking on. Selecting a candidate engine with
            // `record` used to fall through to the replay path and fail with a
            // missing-dataset error, which says nothing about the real mistake.
            if mode == .record, backend != .arkit {
                throw CoordinatorError.invalidRun("record_requires_arkit_arm")
            }
            prepared = context
            try writeStarted(context)
            let initialHeartbeatNS = DispatchTime.now().uptimeNanoseconds
            try writeHeartbeat(context, sequence: 0, monotonicNS: initialHeartbeatNS)
            // Before the run clock: the first sample must not be later than the
            // measurement window it seeds.
            sampler.start()
            let liveRunStartNS = DispatchTime.now().uptimeNanoseconds
            if backend == .arkit {
                try runARKitReference(
                    context,
                    initialHeartbeatNS: initialHeartbeatNS,
                    liveRunStartNS: liveRunStartNS,
                    runLease: runLease
                )
                onFinish(.success(context.directoryURL))
                return
            }
            if !mode.isReplay {
                try runLive(
                    context,
                    mode: mode,
                    initialHeartbeatNS: initialHeartbeatNS,
                    liveRunStartNS: liveRunStartNS,
                    runLease: runLease
                )
                onFinish(.success(context.directoryURL))
                return
            }
            let session = try ActiveVIOEngineSession(
                backend: backend,
                configURL: context.configURL,
                calibrationURL: context.calibrationURL,
                imageWidth: context.imageWidth,
                imageHeight: context.imageHeight
            )
            try runLease.recordEngineSessionStarted()
            lock.withLock { activeSession = session }
            defer {
                session.close()
                lock.withLock { activeSession = nil }
            }
            try runReplay(
                context,
                session: session,
                initialHeartbeatNS: initialHeartbeatNS,
                runLease: runLease
            )
            onFinish(.success(context.directoryURL))
        } catch CoordinatorError.aborted {
            if let prepared {
                // An aborted run is the diagnostic protocol, not a discarded one.
                // Write whatever the run actually produced before tearing down.
                let progress = lock.withLock { liveProgress }
                if let progress {
                    try? writeAbortDiagnostics(prepared, progress: progress)
                }
                try? writeTerminal(
                    prepared,
                    state: .aborted,
                    metrics: progress.map {
                        diagnosticMetrics(
                            startNS: $0.startNS,
                            firstPoseLatencyMS: $0.firstPoseLatencyMS,
                            latenciesMS: $0.latenciesMS,
                            poseCount: $0.poseCount
                        )
                    } ?? [:],
                    reason: "user_abort",
                    detail: nil
                )
                onFinish(.success(prepared.directoryURL))
            } else {
                onFinish(.failure(CoordinatorError.aborted))
            }
        } catch {
            NSLog("[VIOBench] run failed before/while preparing: %@",
                  String(describing: error))

            if let prepared {
                try? writeTerminal(
                    prepared,
                    state: .invalid,
                    metrics: [:],
                    reason: "runtime_error",
                    detail: error.localizedDescription
                )
            }
            onFinish(.failure(error))
        }
    }

    private func runARKitReference(
        _ context: PreparedBenchmarkRun,
        initialHeartbeatNS: UInt64,
        liveRunStartNS: UInt64,
        runLease: BenchRunLease.Token
    ) throws {
        // ARKit cannot be fed a recording, so it runs live in exactly two modes:
        // as the reference arm, and as the camera owner during a `record` run.
        guard !mode.isReplay else {
            throw CoordinatorError.invalidRun("arkit_replay_is_not_supported")
        }

        let applicationActivity = ApplicationActivityLatch()
        let initiallyActive = DispatchQueue.main.sync {
            UIApplication.shared.applicationState == .active
        }
        applicationActivity.start(initiallyActive: initiallyActive)
        defer { applicationActivity.stop() }

        sampler.start()
        defer { sampler.stop() }
        let measurementCPUStart = SystemMetricSampler.processCPUSeconds().total
        let reference = ARKitReferenceSession(
            startMonotonicSeconds: Double(liveRunStartNS) / 1_000_000_000
        )
        lock.withLock { activeARKitSession = reference }
        reference.previewTap = PreviewFrameTap { [onPreviewFrame] in onPreviewFrame($0) }
        onPreview(.liveFrames(label: backend.displayName))
        defer {
            reference.pause()
            onPreview(.none)
            lock.withLock { activeARKitSession = nil }
        }

        // A `record` run persists the frames ARKit is tracking on, so every
        // candidate can later replay the identical input. Free space is checked
        // before the operator starts, not after five minutes of capture.
        var recorder: DeviceRecordingWriter?
        if mode == .record {
            // The configuration receipt only exists after the session starts, so
            // the space check uses the conservative higher rate rather than a
            // value that is not knowable yet; the manifest is corrected to the
            // selected rate once the session reports it.
            var format = DeviceRecordingCameraFormat.scoring
            format.nominalFPS = BenchResolution.scoringFramesPerSecond
            // The bench-only LiDAR ruler rides along on this arm, so its two
            // streams are part of what the capture will occupy: 245,760 B per
            // frame on top of the luma, 422 MiB over 30 s at 60 fps. Projecting
            // without it is how a preflight passes and the capture still runs
            // the volume out partway through.
            let projected = DeviceRecordingWriter.projectedByteCount(
                seconds: Double(LiveBenchmarkDuration.measurementNanoseconds) / 1_000_000_000,
                format: format,
                includingDepth: true
            )
            try DeviceRecordingWriter.checkFreeSpace(
                at: context.directoryURL,
                requiredBytes: projected
            )
            let writer = try DeviceRecordingWriter(
                directory: context.directoryURL,
                recordingID: context.runID,
                format: format
            )
            reference.recorder = writer
            recorder = writer
        }

        let baseline = ARKitReferenceSnapshot()
        var measurementCPUEnd: Double?
        var heartbeatSchedule = HeartbeatSchedule(
            intervalNanoseconds: 5_000_000_000,
            startingSequence: 1,
            firstDeadlineNanoseconds: initialHeartbeatNS + 5_000_000_000
        )
        let startNS = liveRunStartNS
        let measurementStartNS = startNS
        let measurementEndNS = measurementStartNS + LiveBenchmarkDuration.measurementNanoseconds
        var actualMeasurementEndNS = measurementEndNS
        var lastUIUpdateNS = startNS
        var invalidReason: String?
        var safetyStopReason: String?

        do {
            onPhase(.measuring)
            try reference.start()
            if let selected = reference.configurationReceipt?.selectedFramesPerSecond {
                recorder?.setNominalFPS(Double(selected))
            }
            try runLease.recordARSessionStarted()
            while true {
                if isAbortRequested { throw CoordinatorError.aborted }
                let now = DispatchTime.now().uptimeNanoseconds
                let status = reference.accounting.statusSnapshot()
                if now >= measurementEndNS {
                    measurementCPUEnd = SystemMetricSampler.processCPUSeconds().total
                    break
                }
                if let sequence = heartbeatSchedule.consumeSequenceIfDue(nowNanoseconds: now) {
                    try writeHeartbeat(context, sequence: sequence, monotonicNS: now)
                }
                if status.sessionInterruptions > 0 {
                    invalidReason = "arkit_session_interruption"
                    break
                }
                if status.sessionFailures > 0 {
                    invalidReason = "arkit_session_failure"
                    break
                }
                if status.timestampRegressions > 0 {
                    invalidReason = "arkit_timestamp_regression"
                    break
                }
                if applicationActivity.snapshot().violationCount > 0 {
                    invalidReason = "app_backgrounded"
                    break
                }
                if ProcessInfo.processInfo.thermalState == .critical {
                    measurementCPUEnd = SystemMetricSampler.processCPUSeconds().total
                    actualMeasurementEndNS = now
                    safetyStopReason = "thermal_state_critical"
                    break
                }
                if let appState = systemSamples.last?.appState, appState != "active" {
                    invalidReason = "app_backgrounded"
                    break
                }
                if now - lastUIUpdateNS >= 1_000_000_000 {
                    lock.withLock {
                        liveProgress = LiveRunProgress(
                            startNS: startNS,
                            firstPoseLatencyMS:
                                reference.accounting.snapshot().firstNormalDeliveryLatencyMilliseconds,
                            latenciesMS: [],
                            poseCount: Int(reference.accounting.snapshot().framesReceived),
                            native: nil,
                            transport: nil,
                            arkit: reference.accounting.snapshot(),
                            applicationLifecycleViolations:
                                applicationActivity.snapshot().violationCount
                        )
                    }
                    publishARKitSnapshot(
                        startNS: startNS,
                        nowNS: now,
                        snapshot: reference.accounting.snapshot(),
                        systemSample: systemSamples.last
                    )
                    lastUIUpdateNS = now
                }
                Thread.sleep(forTimeInterval: 0.005)
            }
        } catch {
            reference.pause()
            sampler.stop()
            throw error
        }

        onPhase(.draining)
        reference.pause()
        // Seal the recording before the lease is released: a recorder failure or
        // any loss must invalidate the run, not leave a plausible file behind.
        if let recorder {
            if let failure = reference.recordingFailure() { throw failure }
            let manifest = try recorder.finish()
            guard manifest.lossCount == 0 else {
                throw CoordinatorError.invalidRun(
                    // The breakdown travels with the failure. A bare total sent
                    // the last investigation guessing between three unrelated
                    // causes when the manifest already knew which had fired.
                    "device_recording_lossy_\(manifest.lossCount)"
                        + "_format\(manifest.lossFormatMismatch)"
                        + "_queue\(manifest.lossWriteQueueFull)"
                        + "_werr\(manifest.lossWriteError)"
                        + "_peak\(manifest.peakInFlight)"
                        + String(format: "_slow%.0fms", manifest.slowestWriteMilliseconds)
                )
            }
        }
        let exclusivity = runLease.release()
        sampler.stop()
        applicationActivity.stop()
        let applicationFinal = applicationActivity.snapshot()
        let final = reference.accounting.snapshot()
        guard let configuration = reference.configurationReceipt else {
            throw CoordinatorError.invalidRun("arkit_configuration_receipt_missing")
        }
        try RunDiagnosticsWriter.writeARKit(
            runID: context.runID,
            snapshot: final,
            configuration: configuration,
            lifecycle: reference.lifecycleReceipt(),
            applicationLifecycleViolations: applicationFinal.violationCount,
            exclusivity: exclusivity,
            to: context.directoryURL
        )

        if isAbortRequested { throw CoordinatorError.aborted }
        guard invalidReason == nil else {
            try writeTerminal(
                context,
                state: .invalid,
                metrics: [:],
                reason: invalidReason ?? "live_run_invalid",
                detail: nil
            )
            return
        }
        if let finalInvalidReason = ARKitRunValidity.invalidReason(
            snapshot: final,
            applicationLifecycleViolations: applicationFinal.violationCount,
            clockDomainViolation: clockDomainViolation(
                runStartNanoseconds: startNS,
                firstPoseLatencyMS: final.firstNormalDeliveryLatencyMilliseconds,
                latenciesMS: []
            )
        ) {
            // [2026-09-03] An invalid verdict used to discard the system samples
            // (telemetry.jsonl stayed empty), so a 10-minute thermal soak that
            // lost one late camera frame left no memory or thermal series at
            // all. The verdict is unchanged; the measurement is kept.
            try writeSystemSamples(systemSamples.snapshot(), to: context.directoryURL)
            try writeTerminal(
                context,
                state: .invalid,
                metrics: diagnosticMetrics(
                    startNS: startNS,
                    firstPoseLatencyMS: final.firstNormalDeliveryLatencyMilliseconds,
                    latenciesMS: [],
                    poseCount: Int(final.framesReceived)
                ),
                reason: finalInvalidReason,
                detail: nil
            )
            return
        }

        let allSystemSamples = systemSamples.snapshot()
        let measuredSystem = allSystemSamples.filter {
            let timestampNS = UInt64(max(0, $0.monotonicSeconds * 1_000_000_000))
            return timestampNS >= measurementStartNS && timestampNS < actualMeasurementEndNS
        }
        guard let thermalDwell = Statistics.thermalDwell(
            samples: allSystemSamples,
            from: Double(measurementStartNS) / 1_000_000_000,
            to: Double(actualMeasurementEndNS) / 1_000_000_000
        ) else {
            try writeSystemSamples(measuredSystem, to: context.directoryURL)
            try writeTerminal(
                context,
                state: .invalid,
                metrics: [:],
                reason: "thermal_telemetry_unavailable",
                detail: nil
            )
            return
        }
        guard measuredSystem.first?.batteryLevel != nil,
              measuredSystem.last?.batteryLevel != nil else {
            try writeSystemSamples(measuredSystem, to: context.directoryURL)
            try writeTerminal(
                context,
                state: .invalid,
                metrics: [:],
                reason: "battery_telemetry_unavailable",
                detail: nil
            )
            return
        }
        guard let peakPhysicalFootprintMiB = Statistics.peakPhysicalFootprintMiB(
            samples: measuredSystem
        ), let measurementCPUEnd else {
            try writeSystemSamples(measuredSystem, to: context.directoryURL)
            try writeTerminal(
                context,
                state: .invalid,
                metrics: [:],
                reason: "resource_telemetry_unavailable",
                detail: nil
            )
            return
        }

        let frames = final.framesReceived - baseline.framesReceived
        let finite = final.finitePoses - baseline.finitePoses
        let nonfinite = final.nonfinitePoses - baseline.nonfinitePoses
        let missed = final.estimatedMissedFrames - baseline.estimatedMissedFrames
        let trackingNormal = final.trackingNormal - baseline.trackingNormal
        let latencyStart = min(
            baseline.callbackLatenciesMilliseconds.count,
            final.callbackLatenciesMilliseconds.count
        )
        let measurementLatencies = Array(
            final.callbackLatenciesMilliseconds.dropFirst(latencyStart)
        )
        let translationStart = min(
            baseline.consecutiveTranslationMeters.count,
            final.consecutiveTranslationMeters.count
        )
        let rotationStart = min(
            baseline.consecutiveRotationDegrees.count,
            final.consecutiveRotationDegrees.count
        )
        let intervalStart = min(
            baseline.frameIntervalsMilliseconds.count,
            final.frameIntervalsMilliseconds.count
        )
        let handlerStart = min(
            baseline.callbackHandlerDurationsMilliseconds.count,
            final.callbackHandlerDurationsMilliseconds.count
        )
        let firstBattery = measuredSystem.first!.batteryLevel!
        let lastBattery = measuredSystem.last!.batteryLevel!
        let firstUsablePoseLatencyMS = final.firstNormalDeliveryLatencyMilliseconds
            ?? (Double(LiveBenchmarkDuration.totalNanoseconds) / 1_000_000 + 1)
        var metrics: [String: Double] = [
            "first_usable_pose_latency_ms": firstUsablePoseLatencyMS,
            "measurement_duration_seconds": max(
                0.001,
                Double(actualMeasurementEndNS - measurementStartNS) / 1_000_000_000
            ),
            "processed_fps": Double(finite) / max(
                0.001,
                Double(actualMeasurementEndNS - measurementStartNS) / 1_000_000_000
            ),
            "p95_pipeline_latency_ms": Statistics.nearestRankPercentile(
                measurementLatencies,
                percentile: 0.95
            ) ?? 0,
            "app_drop_rate": Double(missed) / Double(max(UInt64(1), frames + missed)),
            "thermal_critical_seconds": safetyStopReason == "thermal_state_critical"
                ? max(0.001, thermalDwell["critical", default: 0])
                : thermalDwell["critical", default: 0],
            "thermal_serious_seconds": thermalDwell["serious", default: 0],
            "peak_phys_footprint_mb": peakPhysicalFootprintMiB,
            "finite_pose_ratio": Double(finite) / Double(max(UInt64(1), finite + nonfinite)),
            "battery_level_delta": Statistics.batteryLevelDelta(
                start: firstBattery,
                end: lastBattery
            ),
            "cpu_seconds": SystemMetricSampler.cpuSecondsDelta(
                start: measurementCPUStart,
                end: measurementCPUEnd
            ),
            "tracking_normal_ratio": Double(trackingNormal) / Double(max(UInt64(1), frames)),
            "estimated_missed_frames": Double(missed),
            "first_normal_latency_ms": final.firstNormalLatencyMilliseconds ?? -1,
            "first_mapped_latency_ms": final.firstMappedLatencyMilliseconds ?? -1,
            "p95_callback_handler_duration_ms": Statistics.nearestRankPercentile(
                Array(final.callbackHandlerDurationsMilliseconds.dropFirst(handlerStart)),
                percentile: 0.95
            ) ?? 0,
            "p95_frame_interval_ms": Statistics.nearestRankPercentile(
                Array(final.frameIntervalsMilliseconds.dropFirst(intervalStart)),
                percentile: 0.95
            ) ?? 0,
            "max_frame_interval_ms": Array(
                final.frameIntervalsMilliseconds.dropFirst(intervalStart)
            ).max() ?? 0,
            "stall_events_over_one_second": Double(
                final.stallEventsOverOneSecond - baseline.stallEventsOverOneSecond
            ),
            "stall_duration_ms": final.stallDurationMilliseconds
                - baseline.stallDurationMilliseconds,
            "longest_non_normal_seconds": final.longestNonNormalSeconds,
            "relocalization_attempts": Double(
                final.relocalizationAttempts - baseline.relocalizationAttempts
            ),
            "relocalization_recoveries": Double(
                final.relocalizationRecoveries - baseline.relocalizationRecoveries
            ),
            "p95_consecutive_translation_m": Statistics.nearestRankPercentile(
                Array(final.consecutiveTranslationMeters.dropFirst(translationStart)),
                percentile: 0.95
            ) ?? 0,
            "p95_consecutive_rotation_deg": Statistics.nearestRankPercentile(
                Array(final.consecutiveRotationDegrees.dropFirst(rotationStart)),
                percentile: 0.95
            ) ?? 0,
        ]
        try writePoses(final.poses.map(\.pose), to: context.directoryURL)
        try writeSystemSamples(measuredSystem, to: context.directoryURL)
        let arkitReferenceFirstUsablePoseLatencyMS = Self.arkitReferenceFirstUsablePoseLatencyMS()
        metrics["arkit_reference_first_usable_pose_latency_ms"] = arkitReferenceFirstUsablePoseLatencyMS ?? -1
        // Which reference run that number came from, so the choice is auditable
        // rather than implicit. -1 means no reference was found.
        let arkitRef = Self.arkitReference()
        metrics["arkit_reference_started_at_epoch_s"] = arkitRef?.startedAtEpochSeconds ?? -1
        metrics["arkit_reference_measurement_duration_seconds"] = arkitRef?.measurementDurationSeconds ?? -1
        let verdict = BenchGateEvaluator.live(
            firstUsablePoseLatencyMilliseconds: firstUsablePoseLatencyMS,
            processedFPS: metrics["processed_fps"]!,
            p95LatencyMilliseconds: metrics["p95_pipeline_latency_ms"]!,
            appDropRate: metrics["app_drop_rate"]!,
            thermalCriticalSeconds: metrics["thermal_critical_seconds"]!,
            thermalSeriousSeconds: metrics["thermal_serious_seconds"]!,
            peakFootprintMB: metrics["peak_phys_footprint_mb"]!,
            finitePoseRatio: metrics["finite_pose_ratio"]!,
            processedFPSMinimum: Double(configuration.selectedFramesPerSecond) * 0.9,
            referenceFirstUsablePoseLatencyMilliseconds: arkitReferenceFirstUsablePoseLatencyMS,
            reference: Self.arkitLiveReference()
        )
        try writeTerminal(
            context,
            state: verdict.passed ? .validPass : .validFail,
            metrics: metrics,
            reason: verdict.passed ? "thresholds_met" : "gates_not_met",
            detail: ([safetyStopReason].compactMap { $0 }
                + verdict.failedReasons).joined(separator: ",")
        )
    }

    private func runLive(
        _ context: PreparedBenchmarkRun,
        mode: BenchMode,
        initialHeartbeatNS: UInt64,
        liveRunStartNS: UInt64,
        runLease: BenchRunLease.Token
    ) throws {

        let applicationActivity = ApplicationActivityLatch()
        let initiallyActive = DispatchQueue.main.sync {
            UIApplication.shared.applicationState == .active
        }
        applicationActivity.start(initiallyActive: initiallyActive)
        defer { applicationActivity.stop() }
        sampler.start()
        defer { sampler.stop() }
        let measurementCPUStart = SystemMetricSampler.processCPUSeconds().total
        let session = try ActiveVIOEngineSession(
            backend: backend,
            configURL: context.configURL,
            calibrationURL: context.calibrationURL,
            imageWidth: context.imageWidth,
            imageHeight: context.imageHeight
        )
        try runLease.recordEngineSessionStarted()
        lock.withLock { activeSession = session }
        defer {
            session.close()
            lock.withLock { activeSession = nil }
        }
        let transport = try LiveSensorTransport(
            imuDeliveryMode: IMUDeliveryMode.forBackend(backend)
        )
        lock.withLock { activeTransport = transport }

        // `record-native` persists this capture through the bench's own
        // AVCaptureSession, in upstream's shape. Space is checked before the
        // operator spends the time, not after.
        var recorder: DeviceRecordingWriter?
        if mode == .recordNative {
            let configured = SensorTransportConfiguration.live
            let format = DeviceRecordingCameraFormat.nativeUpstream(
                fps: Double(configured.cameraRateHz)
            )
            try DeviceRecordingWriter.checkFreeSpace(
                at: context.directoryURL,
                requiredBytes: DeviceRecordingWriter.projectedByteCount(
                    seconds: Double(LiveBenchmarkDuration.measurementNanoseconds)
                        / 1_000_000_000,
                    format: format
                )
            )
            let writer = try DeviceRecordingWriter(
                directory: context.directoryURL,
                recordingID: context.runID,
                format: format
            )
            transport.recorder = writer
            recorder = writer
        }
        transport.previewTap = PreviewFrameTap { [onPreviewFrame] in onPreviewFrame($0) }
        onPreview(.liveFrames(label: backend.displayName))
        defer { onPreview(.none) }

        var poses: [NativePoseSample] = []
        var measurementPoseCount = 0
        var measurementLatenciesMS: [Double] = []
        let nativeBaseline = try session.snapshot()
        let transportBaseline = transport.snapshot()
        var firstUsablePoseLatencyMS: Double?
        var measurementCPUEnd: Double?
        var heartbeatSchedule = HeartbeatSchedule(
            intervalNanoseconds: 5_000_000_000,
            startingSequence: 1,
            firstDeadlineNanoseconds: initialHeartbeatNS + 5_000_000_000
        )
        let startNS = liveRunStartNS
        let measurementStartNS = startNS
        let measurementEndNS = measurementStartNS + LiveBenchmarkDuration.measurementNanoseconds
        var actualMeasurementEndNS = measurementEndNS
        let measurementWindow = BenchmarkMeasurementWindow(
            startNanoseconds: measurementStartNS,
            endNanoseconds: measurementEndNS
        )
        var lastUIUpdateNS = startNS
        var invalidReason: String?
        var safetyStopReason: String?

        let posePoller: PosePoller? = Self.posePollHz > 0
            ? PosePoller(session: session, hz: Self.posePollHz) : nil
        posePoller?.start()
        defer { posePoller?.stop() }
        do {
            onPhase(.measuring)
            try transport.start()
            try runLease.recordAVFoundationTransportStarted()
            while true {
                if isAbortRequested { throw CoordinatorError.aborted }
                let now = DispatchTime.now().uptimeNanoseconds
                if now >= measurementEndNS {
                    measurementCPUEnd = SystemMetricSampler.processCPUSeconds().total
                    break
                }

                try drainLiveTransport(transport, into: session)
                var livePoses = try drainPoses(session)
                if let poller = posePoller {
                    // The propagated track replaces the per-frame one rather than adding to it, so a
                    // pose is never counted twice. The engine calls happen on the poller's thread;
                    // this loop only moves what it has already collected.
                    livePoses.removeAll()
                    let polled = poller.drain()
                    polledPoseCount &+= UInt64(polled.count)
                    livePoses.append(contentsOf: polled)
                }
                if firstEngineResultNS == 0 && !livePoses.isEmpty {
                    firstEngineResultNS = DispatchTime.now().uptimeNanoseconds
                }
                for pose in livePoses {
                    poses.append(pose)
                    if firstUsablePoseLatencyMS == nil {
                        firstUsablePoseLatencyMS = firstPoseLatencyMilliseconds(
                            runStartNanoseconds: startNS,
                            pose: pose
                        )
                    }
                    if measurementWindow.contains(
                        captureNanoseconds: pose.capturedMonotonicNanoseconds
                    ) {
                        measurementPoseCount += 1
                        measurementLatenciesMS.append(
                            Double(pose.pipelineLatencyNanoseconds) / 1_000_000
                        )
                    }
                }
                if let sequence = heartbeatSchedule.consumeSequenceIfDue(nowNanoseconds: now) {
                    try writeHeartbeat(context, sequence: sequence, monotonicNS: now)
                }

                let transportState = transport.snapshot()
                if transportState.accounting.captureInterruptions > 0 {
                    invalidReason = "capture_interruption"
                    break
                }
                if transportState.accounting.captureRuntimeErrors > 0 {
                    invalidReason = "capture_runtime_error"
                    break
                }
                if transportState.accounting.timestampRegressions > 0 {
                    invalidReason = "timestamp_regression"
                    break
                }
                if applicationActivity.snapshot().violationCount > 0 {
                    invalidReason = "app_backgrounded"
                    break
                }
                if ProcessInfo.processInfo.thermalState == .critical {
                    measurementCPUEnd = SystemMetricSampler.processCPUSeconds().total
                    actualMeasurementEndNS = now
                    safetyStopReason = "thermal_state_critical"
                    break
                }
                if let appState = systemSamples.last?.appState, appState != "active" {
                    invalidReason = "app_backgrounded"
                    break
                }
                if now - lastUIUpdateNS >= 250_000_000 {
                    lock.withLock {
                        liveProgress = LiveRunProgress(
                            startNS: startNS,
                            firstPoseLatencyMS: firstUsablePoseLatencyMS,
                            latenciesMS: measurementLatenciesMS,
                            poseCount: measurementPoseCount,
                            native: try? session.snapshot(),
                            transport: transport.snapshot(),
                            arkit: nil,
                            applicationLifecycleViolations:
                                applicationActivity.snapshot().violationCount
                        )
                    }
                    publishLiveSnapshot(
                        startNS: startNS,
                        nowNS: now,
                        latenciesMS: measurementLatenciesMS,
                        poses: poses,
                        transport: transportState,
                        systemSample: systemSamples.last
                    )
                    lastUIUpdateNS = now
                }
                Thread.sleep(forTimeInterval: 0.001)
            }
        } catch {
            transport.stop()
            sampler.stop()
            throw error
        }

        onPhase(.draining)
        transport.stop()
        while true {
            let drained = try drainLiveTransport(transport, into: session)
            if drained { break }
            Thread.sleep(forTimeInterval: 0.001)
        }
        // Seal after the transport has stopped and before anything is scored:
        // a loss is a failed run, never a shorter recording. Same rule and same
        // breakdown as the ARKit recorder above.
        if let recorder {
            let manifest = try recorder.finish()
            guard manifest.lossCount == 0 else {
                throw CoordinatorError.invalidRun(
                    "device_recording_lossy_\(manifest.lossCount)"
                        + "_format\(manifest.lossFormatMismatch)"
                        + "_queue\(manifest.lossWriteQueueFull)"
                        + "_werr\(manifest.lossWriteError)"
                        + "_peak\(manifest.peakInFlight)"
                        + String(format: "_slow%.0fms", manifest.slowestWriteMilliseconds)
                )
            }
        }
        try session.sealDrainStop()
        for pose in try drainPoses(session) {
            poses.append(pose)
            if firstUsablePoseLatencyMS == nil {
                firstUsablePoseLatencyMS = firstPoseLatencyMilliseconds(
                    runStartNanoseconds: startNS,
                    pose: pose
                )
            }
            if pose.capturedMonotonicNanoseconds >= measurementStartNS,
               pose.capturedMonotonicNanoseconds < actualMeasurementEndNS {
                measurementPoseCount += 1
                measurementLatenciesMS.append(
                    Double(pose.pipelineLatencyNanoseconds) / 1_000_000
                )
            }
        }
        sampler.stop()
        applicationActivity.stop()
        let applicationActivityFinal = applicationActivity.snapshot()
        lock.withLock { activeTransport = nil }

        if isAbortRequested { throw CoordinatorError.aborted }
        guard invalidReason == nil else {
            try writeTerminal(
                context,
                state: .invalid,
                metrics: diagnosticMetrics(
                    startNS: startNS,
                    firstPoseLatencyMS: firstUsablePoseLatencyMS,
                    latenciesMS: measurementLatenciesMS,
                    poseCount: measurementPoseCount
                ),
                reason: invalidReason ?? "live_run_invalid",
                detail: nil
            )
            return
        }

        let nativeFinal = try session.snapshot()
        let transportFinal = transport.snapshot()
        session.close()
        lock.withLock { activeSession = nil }
        let exclusivity = runLease.release()
        try RunDiagnosticsWriter.writeFull(
            backend: backend,
            runID: context.runID,
            native: nativeFinal,
            transport: transportFinal,
            applicationLifecycleViolations: applicationActivityFinal.violationCount,
            exclusivity: exclusivity,
            to: context.directoryURL
        )
        if let lossReason = LiveRunValidity.invalidReason(
            liveLossCounters(
                native: nativeFinal,
                transport: transportFinal,
                applicationLifecycleViolations: applicationActivityFinal.violationCount
            ),
            clockDomainViolation: clockDomainViolation(
                runStartNanoseconds: startNS,
                firstPoseLatencyMS: firstUsablePoseLatencyMS,
                latenciesMS: measurementLatenciesMS
            )
        ) {
            // [2026-09-03] An invalid verdict used to discard the system samples
            // (telemetry.jsonl stayed empty), so a 10-minute thermal soak that
            // lost one late camera frame left no memory or thermal series at
            // all. The verdict is unchanged; the measurement is kept.
            try writeSystemSamples(systemSamples.snapshot(), to: context.directoryURL)
            try writeTerminal(
                context,
                state: .invalid,
                metrics: diagnosticMetrics(
                    startNS: startNS,
                    firstPoseLatencyMS: firstUsablePoseLatencyMS,
                    latenciesMS: measurementLatenciesMS,
                    poseCount: measurementPoseCount
                ),
                reason: lossReason,
                detail: nil
            )
            return
        }
        let allSystemSamples = systemSamples.snapshot()
        let measuredSystem = allSystemSamples.filter {
            let timestampNS = UInt64(max(0, $0.monotonicSeconds * 1_000_000_000))
            return timestampNS >= measurementStartNS && timestampNS < actualMeasurementEndNS
        }
        guard let thermalDwell = Statistics.thermalDwell(
            samples: allSystemSamples,
            from: Double(measurementStartNS) / 1_000_000_000,
            to: Double(actualMeasurementEndNS) / 1_000_000_000
        ) else {
            try writeSystemSamples(measuredSystem, to: context.directoryURL)
            try writeTerminal(
                context,
                state: .invalid,
                metrics: [:],
                reason: "thermal_telemetry_unavailable",
                detail: nil
            )
            return
        }
        guard measuredSystem.first?.batteryLevel != nil,
              measuredSystem.last?.batteryLevel != nil else {
            try writeSystemSamples(measuredSystem, to: context.directoryURL)
            try writeTerminal(
                context,
                state: .invalid,
                metrics: [:],
                reason: "battery_telemetry_unavailable",
                detail: nil
            )
            return
        }
        guard let peakPhysicalFootprintMiB = Statistics.peakPhysicalFootprintMiB(
            samples: measuredSystem
        ) else {
            try writeSystemSamples(measuredSystem, to: context.directoryURL)
            try writeTerminal(
                context,
                state: .invalid,
                metrics: [:],
                reason: "memory_telemetry_unavailable",
                detail: nil
            )
            return
        }
        guard let measurementCPUEnd else {
            throw CoordinatorError.invalidRun("measurement_cpu_endpoint_missing")
        }
        var metrics = liveMetrics(
            firstUsablePoseLatencyMilliseconds: firstUsablePoseLatencyMS
                ?? (Double(LiveBenchmarkDuration.totalNanoseconds) / 1_000_000 + 1),
            nativeBaseline: nativeBaseline,
            nativeFinal: nativeFinal,
            transportBaseline: transportBaseline,
            transportFinal: transportFinal,
            measurementPoseCount: measurementPoseCount,
            latenciesMS: measurementLatenciesMS,
            systemSamples: measuredSystem,
            thermalDwell: thermalDwell,
            peakPhysicalFootprintMiB: peakPhysicalFootprintMiB,
            cpuSeconds: SystemMetricSampler.cpuSecondsDelta(
                start: measurementCPUStart,
                end: measurementCPUEnd
            ),
            measurementDurationSeconds: max(
                0.001,
                Double(actualMeasurementEndNS - measurementStartNS) / 1_000_000_000
            ),
            thermalCriticalObserved: safetyStopReason == "thermal_state_critical"
        )
        try writePoses(poses.map(\.pose), to: context.directoryURL)
        try writeSystemSamples(measuredSystem, to: context.directoryURL)
        let arkitReferenceFirstUsablePoseLatencyMS = Self.arkitReferenceFirstUsablePoseLatencyMS()
        metrics["arkit_reference_first_usable_pose_latency_ms"] = arkitReferenceFirstUsablePoseLatencyMS ?? -1
        // Which reference run that number came from, so the choice is auditable
        // rather than implicit. -1 means no reference was found.
        let arkitRef = Self.arkitReference()
        metrics["arkit_reference_started_at_epoch_s"] = arkitRef?.startedAtEpochSeconds ?? -1
        metrics["arkit_reference_measurement_duration_seconds"] = arkitRef?.measurementDurationSeconds ?? -1
        let verdict = BenchGateEvaluator.live(
            firstUsablePoseLatencyMilliseconds: metrics["first_usable_pose_latency_ms"]!,
            processedFPS: metrics["processed_fps"]!,
            p95LatencyMilliseconds: metrics["p95_pipeline_latency_ms"]!,
            appDropRate: metrics["app_drop_rate"]!,
            thermalCriticalSeconds: metrics["thermal_critical_seconds"]!,
            thermalSeriousSeconds: metrics["thermal_serious_seconds"]!,
            peakFootprintMB: metrics["peak_phys_footprint_mb"]!,
            finitePoseRatio: metrics["finite_pose_ratio"]!,
            referenceFirstUsablePoseLatencyMilliseconds: arkitReferenceFirstUsablePoseLatencyMS,
            reference: Self.arkitLiveReference()
        )
        try writeTerminal(
            context,
            state: verdict.passed ? .validPass : .validFail,
            metrics: metrics,
            reason: verdict.passed ? "thresholds_met" : "gates_not_met",
            detail: ([safetyStopReason].compactMap { $0 }
                + verdict.failedReasons).joined(separator: ",")
        )
    }

    private func runReplay(
        _ context: PreparedBenchmarkRun,
        session: ActiveVIOEngineSession,
        initialHeartbeatNS: UInt64,
        runLease: BenchRunLease.Token
    ) throws {
        // One scheduler drives both replay channels, so pacing and ordering
        // cannot drift between EuRoC and the device recording.
        guard let events = context.replayEvents else {
            throw CoordinatorError.invalidRun("replay_dataset_missing")
        }
        guard context.inputCameraCount == 1 else {
            throw CoordinatorError.invalidRun("native_manifest_camera_count_mismatch")
        }

        var poses: [TimedPose] = []
        var heartbeatSchedule = HeartbeatSchedule(
            intervalNanoseconds: 5_000_000_000,
            startingSequence: 1,
            firstDeadlineNanoseconds: initialHeartbeatNS + 5_000_000_000
        )
        let startNS = DispatchTime.now().uptimeNanoseconds
        let cpuStart = SystemMetricSampler.processCPUSeconds().total
        sampler.start()
        onPhase(.measuring)
        // Unpaced replay assumes the engine cannot be outrun -- true only while
        // the engine is synchronous. A threaded XRSLAM returns from
        // `run_one_frame` before the frame is tracked and queues it in an
        // unbounded deque of full-size images, so an unpaced feeder grows that
        // deque by hundreds of MB per second until the OS kills the process.
        // `-PWPaceReplay` feeds the recording at its own timestamps, which is
        // the rate a camera would deliver at and the rate the real-time
        // question is actually about.
        let paceReplay = ProcessInfo.processInfo.arguments.contains("-PWPaceReplay")
        // The live channel runs the camera at 30 fps while this recording holds
        // 60. Halving the replay rate reproduces the live channel's camera
        // cadence against the identical pixels, which is the only way to ask
        // whether a live failure is about cadence without a hand-held capture.
        let halfFrameRate = ProcessInfo.processInfo.arguments.contains("-PWHalfFrameRate")
        var cameraFrameOrdinal = 0
        let scheduler = ReplayScheduler(
            mode: (mode == .replayPaced || paceReplay) ? .paced : .maximumThroughput
        )
        do {
            try scheduler.run(events: events) { event in
                // Decoding one frame allocates its luma and chroma planes and a
                // copy of the payload -- several MB that Foundation hands back
                // autoreleased. A replay loop drains no run loop of its own, so
                // without a pool per event those planes accumulate for the whole
                // recording and the OS kills the process partway through.
                try autoreleasepool {
                if isAbortRequested { throw CoordinatorError.aborted }
                switch event {
                case .imu(let sample):
                    try waitForReplayCapacity(
                        camera: false,
                        session: session,
                        context: context,
                        heartbeatSchedule: &heartbeatSchedule,
                        poses: &poses
                    )
                    try session.submitIMU(sample)
                    // [2026-09-09] With -PWPosePollHz N the replay emits the IMU-propagated pose on a
                    // SENSOR-time grid, not a wall-clock one: replay runs at 70-130 fps, so a wall
                    // clock would sample the trajectory at an arbitrary rate. This is what makes the
                    // propagated track scorable -- ate.py pairs it against ARKit by timestamp, which
                    // answers whether the poses between visual updates are as good as the ones on them.
                    if Self.posePollHz > 0 {
                        let period = Int64(1_000_000_000 / Self.posePollHz)
                        if sample.timestampNanoseconds &- lastPollSensorNS >= period {
                            lastPollSensorNS = sample.timestampNanoseconds
                            if let polled = try session.queryPose() {
                                polledPoseCount += 1
                                poses.append(polled.pose)
                            }
                        }
                    }
                case .camera(let frame):
                    guard frame.inputCameraCount == context.inputCameraCount,
                          frame.camera1ImageURL == nil else {
                        throw CoordinatorError.invalidRun("camera_count_drift")
                    }
                    cameraFrameOrdinal += 1
                    if halfFrameRate && cameraFrameOrdinal % 2 == 0 { return }
                    try waitForReplayCapacity(
                        camera: true,
                        session: session,
                        context: context,
                        heartbeatSchedule: &heartbeatSchedule,
                        poses: &poses
                    )
                    try session.submitReplayCamera(
                        frame,
                        acceptedNanoseconds: DispatchTime.now().uptimeNanoseconds,
                        width: context.imageWidth,
                        height: context.imageHeight
                    )
                }
                // With -PWPosePollHz the polled track is the arm: drain the per-frame results so the
                // engine's result queue cannot fill, but do not score both trajectories at once.
                if Self.posePollHz > 0 { _ = try drainPoses(session) }
                else { poses.append(contentsOf: try drainPoses(session).map(\.pose)) }
                let now = DispatchTime.now().uptimeNanoseconds
                if let sequence = heartbeatSchedule.consumeSequenceIfDue(nowNanoseconds: now) {
                    try writeHeartbeat(context, sequence: sequence, monotonicNS: now)
                }
                }
            }
        } catch {
            sampler.stop()
            throw error
        }
        onPhase(.draining)
        try session.sealDrainStop()
        // With -PWPosePollHz the polled track is the arm: drain the per-frame results so the
                // engine's result queue cannot fill, but do not score both trajectories at once.
                if Self.posePollHz > 0 { _ = try drainPoses(session) }
                else { poses.append(contentsOf: try drainPoses(session).map(\.pose)) }
        sampler.stop()
        let endNS = DispatchTime.now().uptimeNanoseconds
        let cpuEnd = SystemMetricSampler.processCPUSeconds().total
        if isAbortRequested { throw CoordinatorError.aborted }
        let snapshot = try session.snapshot()
        session.close()
        lock.withLock { activeSession = nil }
        let exclusivity = runLease.release()
        let evaluationConfiguration = TrajectoryEvaluationConfiguration()
        try RunDiagnosticsWriter.writeFull(
            backend: backend,
            runID: context.runID,
            native: snapshot,
            evaluationConfiguration: evaluationConfiguration,
            exclusivity: exclusivity,
            to: context.directoryURL
        )
        // Four unrelated conditions used to share the label
        // native_transport_loss. A run that dropped nothing and produced one
        // degenerate quaternion was reported as transport loss, which sent this
        // investigation looking at queue depths while the engine's own output
        // was the problem. Each condition now names itself, and the counts
        // travel with it.
        let transportDropped = snapshot.counters.cameraDroppedQueueFull
            + snapshot.counters.imuDroppedQueueFull
            + snapshot.counters.posesDroppedBridgeQueue
        guard transportDropped == 0 else {
            throw CoordinatorError.invalidRun(
                "native_transport_loss"
                    + "_camera\(snapshot.counters.cameraDroppedQueueFull)"
                    + "_imu\(snapshot.counters.imuDroppedQueueFull)"
                    + "_pose\(snapshot.counters.posesDroppedBridgeQueue)"
            )
        }
        // A degenerate pose is rejected -- it never enters the trajectory --
        // and counted, but it no longer throws the whole run away. That is how
        // production treats the same output from the same engine: its shadow
        // health classifies a pose as degenerate, increments a counter, breaks
        // the valid-pose segment and carries on. Discarding a 30 s capture over
        // one bad quaternion in 1650 made xrslam unscoreable in principle. The
        // count is in the receipt and in diagnostics, so nothing is hidden by
        // this.
        if snapshot.counters.nonfinitePoseRejected > 0 {
            NSLog("[VIOBench] %llu of %llu poses were rejected as non-finite",
                  snapshot.counters.nonfinitePoseRejected,
                  snapshot.counters.posesProduced)
        }
        // -PWHalfFrameRate deliberately submits every second frame, so the invariant is "everything
        // the arm meant to feed arrived", not "every event in the recording arrived". Comparing
        // against the raw event count invalidated every half-rate replay ever run (09-09).
        var expectedCamera = events.reduce(into: UInt64(0)) {
            if case .camera = $1 { $0 += 1 }
        }
        if halfFrameRate { expectedCamera = (expectedCamera + 1) / 2 }
        let expectedIMU = events.reduce(into: UInt64(0)) {
            if case .imu = $1 { $0 += 1 }
        }
        guard snapshot.counters.cameraAccepted == expectedCamera,
              snapshot.counters.imuAccepted == expectedIMU else {
            throw CoordinatorError.invalidRun("replay_input_count_mismatch")
        }
        let elapsed = max(1e-9, Double(endNS - startNS) / 1_000_000_000)
        let samples = systemSamples.snapshot()
        try writePoses(poses, to: context.directoryURL)
        try writeSystemSamples(samples, to: context.directoryURL)

        // Only EuRoC carries external ground truth, so only EuRoC may state an
        // absolute accuracy number or be scored against the accuracy gates. The
        // device recording gives every arm identical input, which makes them
        // mutually comparable -- comparability is not ground truth, and calling
        // ATE against ARKit's trajectory would be scoring one estimator by
        // another.
        guard let dataset = context.replayDataset else {
            let metrics: [String: Double] = [
                "processed_fps": Double(poses.count) / elapsed,
                "pose_count": Double(poses.count),
                "camera_frames_replayed": Double(expectedCamera),
                "imu_samples_replayed": Double(expectedIMU),
                "cpu_seconds": SystemMetricSampler.cpuSecondsDelta(start: cpuStart, end: cpuEnd),
            ]
            try writeTerminal(
                context,
                state: .invalid,
                metrics: metrics,
                reason: "device_recording_replay_complete_no_ground_truth",
                detail: "poses.tum written; accuracy is compared against the "
                    + "ARKit trajectory over the identical frames, outside this receipt"
            )
            return
        }

        let accuracy = try TrajectoryEvaluator(
            configuration: evaluationConfiguration
        ).evaluate(
            estimated: poses,
            groundTruth: dataset.groundTruth
        )
        let metrics: [String: Double] = [
            "processed_fps": Double(poses.count) / elapsed,
            "ate_rmse_m": accuracy.ateRMSEMeters,
            "rpe_translation_rmse_m": accuracy.rpeTranslationRMSEMeters,
            "rpe_rotation_rmse_deg": accuracy.rpeRotationRMSEDegrees,
            "ground_truth_coverage": accuracy.groundTruthCoverage,
            "cpu_seconds": SystemMetricSampler.cpuSecondsDelta(start: cpuStart, end: cpuEnd),
        ]
        let verdict = BenchGateEvaluator.replay(accuracy)
        try writeTerminal(
            context,
            state: verdict.passed ? .validPass : .validFail,
            metrics: metrics,
            reason: verdict.passed ? "thresholds_met" : "gates_not_met",
            detail: verdict.failedReasons.joined(separator: ",")
        )
    }

    @discardableResult
    private func drainLiveTransport(
        _ transport: LiveSensorTransport,
        into session: ActiveVIOEngineSession
    ) throws -> Bool {
        if transport.imuDeliveryMode == .xrslamRawSeparateEvents {
            let batch = transport.drainXRSLAMSensorEvents(maxCount: 512)
            var lastCameraIndex: Int? = nil
            if Self.dropStaleCamera {
                for (i, event) in batch.items.enumerated() { if case .camera = event { lastCameraIndex = i } }
            }
            for (index, event) in batch.items.enumerated() {
                do {
                    switch event {
                    case .camera(let frame):
                        if let last = lastCameraIndex, index != last { xrslamStaleCameraDrops += 1; continue }
                        if firstCameraSubmittedNS == 0 { firstCameraSubmittedNS = DispatchTime.now().uptimeNanoseconds }
                        try session.submitCamera(
                            frame,
                            acceptedNanoseconds: frame.timestampNanoseconds
                        )
                    case .imu(let sample):
                        try session.submitIMU(sample)
                    }
                } catch ActiveVIOEngineSessionError.queueFull {
                    continue
                }
            }
            return batch.isSealedAndDrained
        }

        let pairedIMU = transport.drainIMU(maxCount: 256)
        for sample in pairedIMU.items {
            do { try session.submitIMU(sample) }
            catch ActiveVIOEngineSessionError.queueFull { continue }
        }
        let camera = transport.drainCamera(maxCount: 8)
        for frame in camera.items {
            do {
                try session.submitCamera(
                    frame,
                    acceptedNanoseconds: frame.timestampNanoseconds
                )
            } catch ActiveVIOEngineSessionError.queueFull {
                continue
            }
        }
        return pairedIMU.isSealedAndDrained && camera.isSealedAndDrained
    }

    private func drainPoses(_ session: ActiveVIOEngineSession) throws -> [NativePoseSample] {
        var result: [NativePoseSample] = []
        while let pose = try session.pollPose() { result.append(pose) }
        return result
    }

    private func waitForReplayCapacity(
        camera: Bool,
        session: ActiveVIOEngineSession,
        context: PreparedBenchmarkRun,
        heartbeatSchedule: inout HeartbeatSchedule,
        poses: inout [TimedPose]
    ) throws {
        // An engine that has stopped consuming leaves this loop spinning
        // forever: the queue never drains, no pose is ever produced, and the
        // run neither finishes nor fails. Basalt printing "Finished VIOFilter"
        // and exiting its processing thread did exactly that -- fourteen
        // minutes of a full queue and a stale heartbeat, with nothing in any
        // artifact saying why. A stall is now a named failure.
        var stallDeadline: UInt64? = nil
        var posesAtStallStart = poses.count
        while true {
            if isAbortRequested { throw CoordinatorError.aborted }
            let snapshot = try session.snapshot()
            let size = camera
                ? snapshot.cameraInputQueue.size
                : snapshot.imuInputQueue.size
            let capacity = camera
                ? snapshot.cameraInputQueue.capacity
                : snapshot.imuInputQueue.capacity
            if capacity == 0 { return }
            if size < capacity { return }
            // With -PWPosePollHz the polled track is the arm: drain the per-frame results so the
                // engine's result queue cannot fill, but do not score both trajectories at once.
                if Self.posePollHz > 0 { _ = try drainPoses(session) }
                else { poses.append(contentsOf: try drainPoses(session).map(\.pose)) }
            let now = DispatchTime.now().uptimeNanoseconds
            if poses.count > posesAtStallStart {
                // Progress: the engine is alive, just slower than the feeder.
                posesAtStallStart = poses.count
                stallDeadline = nil
            } else if let deadline = stallDeadline {
                if now > deadline {
                    throw CoordinatorError.invalidRun(
                        camera
                            ? "replay_engine_stalled_camera_queue_full_no_pose_progress"
                            : "replay_engine_stalled_imu_queue_full_no_pose_progress"
                    )
                }
            } else {
                stallDeadline = now + Self.replayStallTimeoutNanoseconds
            }
            if let sequence = heartbeatSchedule.consumeSequenceIfDue(nowNanoseconds: now) {
                try writeHeartbeat(context, sequence: sequence, monotonicNS: now)
            }
            Thread.sleep(forTimeInterval: 0.0002)
        }
    }

    /// How long a full queue may make no pose progress before the run is
    /// declared stalled. Generous enough to cover a slow engine on a thermally
    /// throttled device, short enough that a dead one is reported in seconds
    /// rather than discovered by a human noticing nothing has happened.
    private static let replayStallTimeoutNanoseconds: UInt64 = 20_000_000_000

    /// ARKit's first-usable-pose latency measured on this device, read from
    /// the newest `arkit_reference` record receipt under VIOBenchRuns. nil when
    /// no such receipt exists; the cold-start gate is then not evaluated.
    /// The newest same-device ARKit **live-soak** reference receipt as a full metric set;
    /// nil when none exists (record-channel receipts are not comparable to a soak).
    static func arkitLiveReference() -> LiveReference? {
        let root = URL.documentsDirectory.appendingPathComponent("VIOBenchRuns")
        let runs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var best: (date: Date, ref: LiveReference)?
        for run in runs {
            guard let data = try? Data(contentsOf: run.appendingPathComponent("receipt.json")),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let app = json["app"] as? [String: Any], app["engine_id"] as? String == "arkit_reference",
                  json["channel"] as? String == "live_soak",
                  let m = json["metrics"] as? [String: Any],
                  let fps = m["processed_fps"] as? Double, let p95 = m["p95_pipeline_latency_ms"] as? Double,
                  let drop = m["app_drop_rate"] as? Double, let crit = m["thermal_critical_seconds"] as? Double,
                  let ser = m["thermal_serious_seconds"] as? Double, let fp = m["peak_phys_footprint_mb"] as? Double,
                  let fin = m["finite_pose_ratio"] as? Double else { continue }
            let date = (try? run.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let ref = LiveReference(processedFPS: fps, p95LatencyMilliseconds: p95, appDropRate: drop, thermalCriticalSeconds: crit, thermalSeriousSeconds: ser, peakFootprintMB: fp, finitePoseRatio: fin)
            if best == nil || date > best!.date { best = (date, ref) }
        }
        return best?.ref
    }

    /// The ARKit reference a live run is judged against, and enough of its
    /// identity to audit the choice.
    ///
    /// [2026-09-16] This used to pick by directory modification time, which is
    /// not the run's own clock: a directory re-copied off the device outranks a
    /// later run. On this device it selected a 30 s run from 08-31 (first pose
    /// 2874.9 ms) over the 300 s baseline from 09-15 (1762.1 ms) and the 600 s
    /// one from 09-03 (1480.7 ms) -- so a candidate was compared against the
    /// worst and shortest ARKit run on the device, and the receipt recorded only
    /// the number, never which run it came from. Now it orders by the receipt's
    /// own `started_at_utc` and carries the reference's identity out with it.
    struct ARKitReference {
        let firstUsablePoseLatencyMS: Double
        let runID: String
        let startedAtEpochSeconds: Double
        let measurementDurationSeconds: Double
    }

    static func arkitReference(
        runsRoot: URL = URL.documentsDirectory.appendingPathComponent("VIOBenchRuns")
    ) -> ARKitReference? {
        let root = runsRoot
        let runs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        )) ?? []
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        var best: ARKitReference?
        var bestStart = -Double.greatestFiniteMagnitude
        for run in runs {
            let receiptURL = run.appendingPathComponent("receipt.json")
            guard let data = try? Data(contentsOf: receiptURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let app = json["app"] as? [String: Any],
                  app["engine_id"] as? String == "arkit_reference",
                  let metrics = json["metrics"] as? [String: Any],
                  let value = metrics["first_usable_pose_latency_ms"] as? Double,
                  value > 0,
                  let startedAt = json["started_at_utc"] as? String,
                  let date = formatter.date(from: startedAt) ?? plain.date(from: startedAt)
            else { continue }
            let start = date.timeIntervalSince1970
            guard start > bestStart else { continue }
            bestStart = start
            best = ARKitReference(
                firstUsablePoseLatencyMS: value,
                runID: (json["run_id"] as? String) ?? run.lastPathComponent,
                startedAtEpochSeconds: start,
                measurementDurationSeconds:
                    (metrics["measurement_duration_seconds"] as? Double) ?? -1
            )
        }
        return best
    }

    static func arkitReferenceFirstUsablePoseLatencyMS() -> Double? {
        arkitReference()?.firstUsablePoseLatencyMS
    }

    private func liveMetrics(
        firstUsablePoseLatencyMilliseconds: Double,
        nativeBaseline: VIOEngineSnapshot,
        nativeFinal: VIOEngineSnapshot,
        transportBaseline: LiveSensorTransportSnapshot,
        transportFinal: LiveSensorTransportSnapshot,
        measurementPoseCount: Int,
        latenciesMS: [Double],
        systemSamples: [SystemMetricSample],
        thermalDwell: [String: Double],
        peakPhysicalFootprintMiB: Double,
        cpuSeconds: Double,
        measurementDurationSeconds: Double,
        thermalCriticalObserved: Bool
    ) -> [String: Double] {
        let offered = nativeFinal.counters.cameraOffered - nativeBaseline.counters.cameraOffered
        let nativeDrops = nativeFinal.counters.cameraDroppedQueueFull - nativeBaseline.counters.cameraDroppedQueueFull
        let handoffDrops = activeCameraHandoffDrops(transportFinal)
            - activeCameraHandoffDrops(transportBaseline)
        let platformDrops = transportFinal.accounting.totalCameraDrops
            - transportBaseline.accounting.totalCameraDrops
        let denominator = max(UInt64(1), offered + handoffDrops + platformDrops)
        let firstBattery = systemSamples.first?.batteryLevel
        let lastBattery = systemSamples.last?.batteryLevel
        let batteryDelta = Statistics.batteryLevelDelta(
            start: firstBattery!,
            end: lastBattery!
        )
        return [
            "first_usable_pose_latency_ms": firstUsablePoseLatencyMilliseconds,
            "measurement_duration_seconds": measurementDurationSeconds,
            "processed_fps": Double(measurementPoseCount) / measurementDurationSeconds,
            "p95_pipeline_latency_ms": Statistics.nearestRankPercentile(latenciesMS, percentile: 0.95) ?? 0,
            "app_drop_rate": Double(nativeDrops + handoffDrops + platformDrops) / Double(denominator),
            "stale_camera_dropped": Double(xrslamStaleCameraDrops),
            "thermal_critical_seconds": thermalCriticalObserved
                ? max(0.001, thermalDwell["critical", default: 0])
                : thermalDwell["critical", default: 0],
            "thermal_serious_seconds": thermalDwell["serious", default: 0],
            "peak_phys_footprint_mb": peakPhysicalFootprintMiB,
            "finite_pose_ratio": 1.0,
            "battery_level_delta": batteryDelta,
            "cpu_seconds": cpuSeconds,
        ]
    }

    private func liveLossCounters(
        native: VIOEngineSnapshot,
        transport: LiveSensorTransportSnapshot,
        applicationLifecycleViolations: UInt64
    ) -> LiveRunLossCounters {
        let assembly = transport.imuAssembly
        return LiveRunLossCounters(
            motionErrors: transport.accounting.motionErrors,
            platformCameraDrops: transport.accounting.totalCameraDrops,
            captureInterruptions: transport.accounting.captureInterruptions,
            captureRuntimeErrors: transport.accounting.captureRuntimeErrors,
            timestampRegressions: transport.accounting.timestampRegressions,
            applicationLifecycleViolations: applicationLifecycleViolations,
            imuAssemblyDrops: assembly.integrityLossCount,
            cameraHandoffDrops: transport.imuDeliveryMode == .basaltGyroDrivenPaired
                ? transport.cameraHandoff.totalRejectedOrDropped
                : 0,
            combinedSensorHandoffDrops:
                transport.imuDeliveryMode == .xrslamRawSeparateEvents
                    ? transport.xrslamSensorHandoff.totalRejectedOrDropped
                    : 0,
            imuHandoffDrops: activeIMUHandoffDrops(transport),
            nativeIMUDrops: native.counters.imuDroppedQueueFull,
            nativeIMURejections:
                native.counters.imuRejectedTimestamp
                + native.counters.imuRejectedSealed,
            nativeCameraTransportLoss:
                native.counters.cameraDroppedQueueFull
                + native.counters.cameraRejectedSealed,
            nativeCameraTimestampRejections: native.counters.cameraRejectedTimestamp,
            poseBridgeDrops: native.counters.posesDroppedBridgeQueue,
            nonfinitePoses: native.counters.nonfinitePoseRejected,
            // Only the degenerate quaternions that arrived after a pose already
            // existed; the one on the engine's first TRACKING_SUCCESS result is
            // an initialization boundary, not an estimator fault.
            degenerateQuaternionsAfterFirstPose:
                native.additionalCounters["xrslam_degenerate_quaternion_after_first_pose"] ?? 0
        )
    }

    private func activeIMUHandoffDrops(_ transport: LiveSensorTransportSnapshot) -> UInt64 {
        switch transport.imuDeliveryMode {
        case .basaltGyroDrivenPaired:
            return transport.imuHandoff.totalRejectedOrDropped
        case .xrslamRawSeparateEvents:
            return 0
        }
    }

    private func firstPoseLatencyMilliseconds(
        runStartNanoseconds: UInt64,
        pose: NativePoseSample
    ) -> Double? {
        let (publicationNanoseconds, overflow) = pose.capturedMonotonicNanoseconds
            .addingReportingOverflow(pose.pipelineLatencyNanoseconds)
        guard !overflow, publicationNanoseconds >= runStartNanoseconds else {
            return nil
        }
        return Double(publicationNanoseconds - runStartNanoseconds) / 1_000_000
    }

    /// Rejects any run whose reported latencies could not have been produced
    /// inside its own elapsed time. See `ClockDomainInvariant`; this is the guard
    /// that turns a cross-domain subtraction into an invalid receipt instead of a
    /// scored result.
    /// Numbers kept on a run that will not be scored.
    ///
    /// Clearing metrics on failure discarded exactly what a diagnostic run
    /// exists to produce. The cross-clock-domain defect lived only on screen for
    /// that reason: every artifact from those runs carried an empty metrics
    /// object. The receipt marks these `metrics_valid_for_scoring: false`.
    /// Overwrites the `status: "unavailable"` stub an abort would otherwise
    /// leave, using counters captured while the run was alive.
    private func writeAbortDiagnostics(
        _ context: PreparedBenchmarkRun,
        progress: LiveRunProgress
    ) throws {
        if let native = progress.native {
            try RunDiagnosticsWriter.writeFull(
                backend: backend,
                runID: context.runID,
                native: native,
                transport: progress.transport,
                applicationLifecycleViolations: progress.applicationLifecycleViolations,
                to: context.directoryURL
            )
        }
    }

    private func diagnosticMetrics(
        startNS: UInt64,
        firstPoseLatencyMS: Double?,
        latenciesMS: [Double],
        poseCount: Int
    ) -> [String: Double] {
        let elapsedSeconds = max(
            1e-9,
            Double(DispatchTime.now().uptimeNanoseconds &- startNS) / 1_000_000_000
        )
        var metrics: [String: Double] = [
            "diagnostic_elapsed_seconds": elapsedSeconds,
            "diagnostic_pose_count": Double(poseCount),
            "diagnostic_processed_fps": Double(poseCount) / elapsedSeconds,
            "diagnostic_stale_camera_dropped": Double(xrslamStaleCameraDrops),
            "diagnostic_first_camera_submitted_ms": firstCameraSubmittedNS == 0 ? -1
                : Double(firstCameraSubmittedNS &- startNS) / 1_000_000,
            "diagnostic_first_engine_result_ms": firstEngineResultNS == 0 ? -1
                : Double(firstEngineResultNS &- startNS) / 1_000_000,
            "diagnostic_polled_poses": Double(polledPoseCount),
            "diagnostic_half_frame_rate": ProcessInfo.processInfo.arguments.contains("-PWHalfFrameRate") ? 1 : 0,
            "diagnostic_pose_poll_hz": Double(Self.posePollHz),
        ]
        if let firstPoseLatencyMS, firstPoseLatencyMS.isFinite {
            metrics["diagnostic_first_usable_pose_latency_ms"] = firstPoseLatencyMS
        }
        if let p95 = Statistics.nearestRankPercentile(latenciesMS, percentile: 0.95) {
            metrics["diagnostic_p95_pipeline_latency_ms"] = p95
        }
        if let worst = latenciesMS.max() {
            metrics["diagnostic_max_pipeline_latency_ms"] = worst
        }
        return metrics
    }

    private func clockDomainViolation(
        runStartNanoseconds: UInt64,
        firstPoseLatencyMS: Double?,
        latenciesMS: [Double]
    ) -> ClockDomainInvariant.Violation? {
        let elapsedNS = DispatchTime.now().uptimeNanoseconds
            .subtractingReportingOverflow(runStartNanoseconds)
        guard !elapsedNS.overflow else {
            return .latencyExceedsElapsed(
                label: "run_elapsed",
                latencyNanoseconds: UInt64.max,
                elapsedNanoseconds: 0
            )
        }
        if let firstPoseLatencyMS,
           let violation = ClockDomainInvariant.check(
               label: "first_pose",
               latencyMilliseconds: firstPoseLatencyMS,
               elapsedNanoseconds: elapsedNS.partialValue
           ) {
            return violation
        }
        // The maximum bounds every percentile, so one check covers P95 too.
        if let worst = latenciesMS.max(),
           let violation = ClockDomainInvariant.check(
               label: "pipeline",
               latencyMilliseconds: worst,
               elapsedNanoseconds: elapsedNS.partialValue
           ) {
            return violation
        }
        return nil
    }

    private func activeCameraHandoffDrops(
        _ transport: LiveSensorTransportSnapshot
    ) -> UInt64 {
        switch transport.imuDeliveryMode {
        case .basaltGyroDrivenPaired:
            return transport.cameraHandoff.totalRejectedOrDropped
        case .xrslamRawSeparateEvents:
            return transport.xrslamSensorHandoff.totalRejectedOrDropped
        }
    }

    private func publishLiveSnapshot(
        startNS: UInt64,
        nowNS: UInt64,
        latenciesMS: [Double],
        poses: [NativePoseSample],
        transport: LiveSensorTransportSnapshot,
        systemSample: SystemMetricSample?
    ) {
        onSnapshot(LiveSnapshot(
            elapsedSeconds: Double(nowNS - startNS) / 1_000_000_000,
            firstUsablePoseLatencyMilliseconds: poses.first.flatMap {
                firstPoseLatencyMilliseconds(runStartNanoseconds: startNS, pose: $0)
            },
            processedFPS: Double(poses.count) / max(1, Double(nowNS - startNS) / 1_000_000_000),
            pipelineP95Milliseconds: Statistics.nearestRankPercentile(latenciesMS, percentile: 0.95) ?? 0,
            cameraDrops: Int(transport.accounting.totalCameraDrops),
            appDrops: Int(activeCameraHandoffDrops(transport)),
            poseCount: poses.count,
            cpuCoreEquivalent: systemSample?.cpuCoreEquivalent ?? 0,
            footprintMB: Double(systemSample?.physicalFootprintBytes ?? 0) / 1_048_576,
            thermalState: systemSample?.thermalState ?? "unknown",
            batteryLevel: systemSample?.batteryLevel
        ))
    }

    private func publishARKitSnapshot(
        startNS: UInt64,
        nowNS: UInt64,
        snapshot: ARKitReferenceSnapshot,
        systemSample: SystemMetricSample?
    ) {
        let elapsed = max(1, Double(nowNS - startNS) / 1_000_000_000)
        onSnapshot(LiveSnapshot(
            elapsedSeconds: elapsed,
            firstUsablePoseLatencyMilliseconds:
                snapshot.firstNormalDeliveryLatencyMilliseconds,
            processedFPS: Double(snapshot.finitePoses) / elapsed,
            pipelineP95Milliseconds: Statistics.nearestRankPercentile(
                snapshot.callbackLatenciesMilliseconds,
                percentile: 0.95
            ) ?? 0,
            cameraDrops: Int(snapshot.estimatedMissedFrames),
            appDrops: Int(snapshot.callbacksAfterPause),
            poseCount: Int(snapshot.finitePoses),
            cpuCoreEquivalent: systemSample?.cpuCoreEquivalent ?? 0,
            footprintMB: Double(systemSample?.physicalFootprintBytes ?? 0) / 1_048_576,
            thermalState: systemSample?.thermalState ?? "unknown",
            batteryLevel: systemSample?.batteryLevel
        ))
    }

    private func writeStarted(_ context: PreparedBenchmarkRun) throws {
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>!
        context.receiptWriter.enqueueStarted(context.startedReceipt) {
            result = $0
            semaphore.signal()
        }
        semaphore.wait()
        do { try result.get() } catch { throw CoordinatorError.receiptWrite(error) }
    }

    private func writeTerminal(
        _ context: PreparedBenchmarkRun,
        state: RunReceiptState,
        metrics: [String: Double],
        reason: String,
        detail: String?
    ) throws {
        let diagnosticsURL = context.directoryURL.appendingPathComponent("diagnostics.json")
        if !FileManager.default.fileExists(atPath: diagnosticsURL.path) {
            guard state != .validPass, state != .validFail else {
                throw CoordinatorError.invalidRun("full_diagnostics_missing")
            }
            try RunDiagnosticsWriter.writeUnavailable(
                backend: backend,
                runID: context.runID,
                reason: reason,
                to: context.directoryURL
            )
        }
        var terminal = context.startedReceipt
        terminal.state = state
        terminal.endedAtUTC = BenchmarkRunPreparation.utcTimestamp()
        terminal.metrics = metrics
        // Derived from the terminal state, not inherited from the started
        // receipt, where it was false because a started receipt has no metrics.
        // Carrying that stale false into a passing result made the receipt fail
        // its own validation and discarded a complete, zero-loss recording.
        // `-PWReplicationReplay` consumed a recording below the verdict
        // resolution. Whatever the gates said, these metrics may never be cited
        // by a verdict -- that is the price of the flag, paid here rather than
        // left to whoever reads the receipt later.
        terminal.metricsValidForScoring = (state == .validPass || state == .validFail)
            && !BenchResolution.replicationReplayRequested
        terminal.termination = RunTermination(
            reasonCode: reason,
            detail: detail,
            recoveredFromInterruption: false
        )
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>!
        context.receiptWriter.enqueueTerminal(terminal) {
            result = $0
            semaphore.signal()
        }
        semaphore.wait()
        do { try result.get() } catch { throw CoordinatorError.receiptWrite(error) }
        try BenchmarkArtifactFinalizer.finalize(
            directoryURL: context.directoryURL,
            runID: context.runID,
            channel: context.startedReceipt.channel
        )
    }

    private func writeHeartbeat(
        _ context: PreparedBenchmarkRun,
        sequence: Int,
        monotonicNS: UInt64
    ) throws {
        let heartbeat = RunHeartbeat(
            runID: context.runID,
            sequence: sequence,
            monotonicNS: monotonicNS,
            writtenAtUTC: BenchmarkRunPreparation.utcTimestamp(),
            startedReceiptSHA256: context.startedReceiptSHA256,
            footprintMB: SystemMetricSampler.currentFootprintMB()
        )
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<Void, Error>!
        context.receiptWriter.enqueueHeartbeat(heartbeat) {
            result = $0
            semaphore.signal()
        }
        semaphore.wait()
        do { try result.get() } catch { throw CoordinatorError.receiptWrite(error) }
    }

    private func writePoses(_ poses: [TimedPose], to directory: URL) throws {
        let rows = poses.map {
            String(
                format: "%@ %.9f %.9f %.9f %.12f %.12f %.12f %.12f",
                TUMTimestampFormatter.string(nanoseconds: $0.timestampNanoseconds),
                $0.translation.x, $0.translation.y, $0.translation.z,
                $0.rotation.x, $0.rotation.y, $0.rotation.z, $0.rotation.w
            )
        }.joined(separator: "\n") + "\n"
        try Data(rows.utf8).write(to: directory.appendingPathComponent("poses.tum"), options: .atomic)
    }

    private func writeSystemSamples(_ samples: [SystemMetricSample], to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let rows = try samples.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try Data((rows.joined(separator: "\n") + (rows.isEmpty ? "" : "\n")).utf8)
            .write(to: directory.appendingPathComponent("telemetry.jsonl"), options: .atomic)
    }

    private var isAbortRequested: Bool { lock.withLock { abortRequested } }
}
