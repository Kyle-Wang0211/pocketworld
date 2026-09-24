import CoreVideo
import Foundation

enum XRSLAMNativeSessionError: LocalizedError {
    case status(operation: String, code: xrslam_bench_status_t)
    case invalidTimestamp
    case invalidImageGeometry(expected: String, actual: String)
    case missingLumaPlane

    var errorDescription: String? {
        switch self {
        case .status(let operation, let code):
            return "XRSLAM \(operation) failed: \(String(cString: xrslam_bench_status_name(code)))"
        case .invalidTimestamp:
            return "Sensor timestamp is outside XRSLAM's signed Int64 nanosecond range."
        case .invalidImageGeometry(let expected, let actual):
            return "XRSLAM image geometry mismatch; expected \(expected), received \(actual)."
        case .missingLumaPlane:
            return "Camera frame does not expose a readable 8-bit luma plane."
        }
    }
}

/// Swift ownership layer for the frozen generic XRSLAM core. All estimator
/// calls are made by BenchmarkCoordinator's single run queue. The native bridge
/// preserves accepted sensor callback order; this type adds only buffer
/// ownership, run receipts, and the official BODY_POSE-to-TUM field mapping.
final class XRSLAMNativeSession {
    private var handle: OpaquePointer?
    private let imageWidth: Int
    private let imageHeight: Int
    private var acceptedCameraTimes: [Int64: UInt64] = [:]
    private var trackingPoseResults: UInt64 = 0
    private var initializingResults: UInt64 = 0
    private var trackingFailureResults: UInt64 = 0
    private var degenerateQuaternionResults: UInt64 = 0
    /// How many poses had already been accepted when the first degenerate
    /// quaternion arrived. 0 means it was the very first TRACKING_SUCCESS
    /// result -- an initialization-boundary artifact rather than a fault in a
    /// running estimator. UInt64.max means it never happened.
    private var degenerateQuaternionFirstAtPose: UInt64 = .max
    /// Which path saw it first: 1 = polled pose, 2 = per-frame result, 0 = never.
    private var degenerateQuaternionFirstPath: UInt64 = 0
    /// Degenerate quaternions that arrived *after* the estimator had already
    /// produced a pose. Measured: the engine returns TRACKING_SUCCESS with a
    /// zero-norm quaternion on its very first result and never again
    /// (`first_at_pose == 0`, 804 good poses after it, deterministic replay).
    /// That boundary case is not an estimator fault; one in a running estimator
    /// would be, so only this counter fails a run.
    private var degenerateQuaternionAfterFirstPose: UInt64 = 0
    private let stopRequestLock = NSLock()
    private var stopWasRequested = false
    /// Cross-stream ordering of the live accelerometer and gyroscope events.
    ///
    /// The native guard is per stream, which is all XRSLAM asks of each stream
    /// on its own. But `Detail::track_gyroscope` and `track_accelerometer` pair
    /// the two streams against each other, and both of their failure paths are
    /// silent: an accelerometer sample older than the oldest pending gyroscope
    /// is dropped, and a gyroscope sample older than the oldest pending
    /// accelerometer clears the entire gyroscope history. Nothing counted how
    /// often that happened, so a live run that starved the estimator of IMU
    /// looked identical to one that simply could not track.
    private var lastLiveEventTimestamp: Int64? = nil
    private var lastLiveEventWasGyroscope = false
    private var liveCrossStreamInversions: UInt64 = 0
    private var liveCrossStreamMaxInversionNanoseconds: Int64 = 0
    private var liveSeparateEventsSubmitted: UInt64 = 0

    init(
        configURL: URL,
        calibrationURL: URL,
        imageWidth: Int,
        imageHeight: Int
    ) throws {
        guard imageWidth > 0, imageHeight > 0,
              imageWidth <= Int(UInt32.max), imageHeight <= Int(UInt32.max) else {
            throw XRSLAMNativeSessionError.invalidImageGeometry(
                expected: "positive UInt32 dimensions",
                actual: "\(imageWidth)x\(imageHeight)"
            )
        }
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight

        var created: OpaquePointer?
        let status = configURL.path.withCString { configPath in
            calibrationURL.path.withCString { calibrationPath in
                // [bench 2026-09-04] `-PWXrslamGpuFrontend`: the gpufe engine arm reads PW_XRSLAM_GPU_FRONTEND=1
                // once (xrslam::extra::GpuImage::front_end) and runs CLAHE/pyramid/GFTT/LK on the GPU.
                // Without the flag, or on an arm built without XRSLAM_GPU_FRONTEND, the engine is byte-for-byte
                // the CPU path. Audit trail: receipt app.backend = "gpu_frontend".
                if ProcessInfo.processInfo.arguments.contains("-PWXrslamGpuFrontend") {
                    setenv("PW_XRSLAM_GPU_FRONTEND", "1", 1)
                    // `-PWXrslamGpuFrontendAudit`: every 50th frame re-runs the CPU path and compares (costs ~0.5 ms/frame avg)
                    if ProcessInfo.processInfo.arguments.contains("-PWXrslamGpuFrontendAudit") { setenv("PW_XRSLAM_GPUFE_AUDIT", "1", 1) }
                    // `-PWXrslamGpuFrontendCpuPyr`: LK pyramid built on the CPU (buildOpticalFlowPyramid) instead of read back from the GPU
                    if ProcessInfo.processInfo.arguments.contains("-PWXrslamGpuFrontendGpuPyr") { setenv("PW_XRSLAM_GPUFE_PYR", "1", 1) }
                    if ProcessInfo.processInfo.arguments.contains("-PWXrslamGpuFrontendFusedHarris") { setenv("PW_GPUFE_FUSED_HARRIS", "1", 1) }
                    if ProcessInfo.processInfo.arguments.contains("-PWXrslamGpuFrontendSplit") { setenv("PW_GPUFE_SPLIT", "1", 1) }
                    // `-PWInitFastReject`: skip the mirror build when the shared-track test would fail anyway
                    if ProcessInfo.processInfo.arguments.contains("-PWInitFastReject") { setenv("PW_INIT_FAST_REJECT", "1", 1) }
                    // `-PWXrslamGpuLK`: optical flow on the GPU too — the pre-hybrid path, audited bit-exact
                    if ProcessInfo.processInfo.arguments.contains("-PWXrslamGpuLK") { setenv("PW_XRSLAM_GPUFE_LK", "1", 1) }
                    // `-PWXrslamGpuTimestamps`: per-kernel GPU ns, attributed in dispatch order and reported as
                    // `gpu_kernel_ms` in xrslam_gpufe_stats.json. Measurement only: the timestamp writes and the
                    // resolve after every batch inflate the frame totals, so read the split, never the absolutes.
                    // The key is OFFICIAL_AETHER_GPU_TIMESTAMPS, not the
                    // AETHER_GPU_TIMESTAMPS the frontend's own comment names:
                    // official_gpu_timestamp_diagnostics_v1.h switches the
                    // literal on AETHER_GPU_TIMESTAMPS_ENV_OFFICIAL, and this
                    // build defines it. Verified against the shipped binary --
                    // `strings` finds OFFICIAL_AETHER_GPU_TIMESTAMPS and does
                    // not find the other spelling. Setting the wrong one is
                    // silent: gpu_kernel_ms just stays {}.
                    if ProcessInfo.processInfo.arguments.contains("-PWXrslamGpuTimestamps") { setenv("OFFICIAL_AETHER_GPU_TIMESTAMPS", "1", 1) }
                }
                var options = xrslam_bench_create_options_t()
                options.struct_size = MemoryLayout<xrslam_bench_create_options_t>.size
                options.slam_config_path = configPath
                options.device_config_path = calibrationPath
                options.image_width = UInt32(imageWidth)
                options.image_height = UInt32(imageHeight)
                return xrslam_bench_create(&options, &created)
            }
        }
        try Self.requireOK(status, operation: "create")
        guard let created else {
            throw XRSLAMNativeSessionError.status(
                operation: "create-null",
                code: XRSLAM_BENCH_INTERNAL_ERROR
            )
        }
        handle = created
    }

    deinit {
        close()
    }

    func close() {
        guard let handle else { return }
        self.handle = nil
        xrslam_bench_destroy(handle)
    }

    /// Monotonic time at which the newest IMU sample was handed to the engine, with its own sensor
    /// timestamp. A pose read by `queryPose()` is propagated up to that sensor time, so this pair
    /// dates it on the same clock the per-frame path uses for camera frames.
    private var lastIMUSensorNanoseconds: Int64 = 0
    private var lastIMUAcceptedNanoseconds: UInt64 = 0

    func submitIMU(_ event: RawIMUEvent) throws {
        lastIMUSensorNanoseconds = Int64(bitPattern: UInt64(event.timestampNanoseconds))
        lastIMUAcceptedNanoseconds = DispatchTime.now().uptimeNanoseconds
        guard event.timestampNanoseconds <= UInt64(Int64.max) else {
            throw XRSLAMNativeSessionError.invalidTimestamp
        }
        let sample = event.sample
        let timestamp = Int64(event.timestampNanoseconds)
        let isGyroscope: Bool
        if case .gyroscope = event { isGyroscope = true } else { isGyroscope = false }
        liveSeparateEventsSubmitted += 1
        if let previous = lastLiveEventTimestamp,
           lastLiveEventWasGyroscope != isGyroscope,
           timestamp < previous {
            liveCrossStreamInversions += 1
            liveCrossStreamMaxInversionNanoseconds = max(
                liveCrossStreamMaxInversionNanoseconds, previous - timestamp
            )
        }
        lastLiveEventTimestamp = timestamp
        lastLiveEventWasGyroscope = isGyroscope
        let status: xrslam_bench_status_t
        switch event {
        case .acceleration:
            status = xrslam_bench_push_accelerometer_g(
                handle, timestamp, sample.x, sample.y, sample.z
            )
        case .gyroscope:
            status = xrslam_bench_push_gyroscope(
                handle, timestamp, sample.x, sample.y, sample.z
            )
        }
        try Self.requireOK(status, operation: "submit_live_imu")
    }

    func submitIMU(_ sample: EuRoCIMUSample) throws {
        for event in XRSLAMReplayIMUAdapter.orderedEvents(sample) {
            switch event {
            case .gyroscope(let gyroscope):
                try Self.requireOK(
                    xrslam_bench_push_gyroscope(
                        handle,
                        sample.timestampNanoseconds,
                        gyroscope.x,
                        gyroscope.y,
                        gyroscope.z
                    ),
                    operation: "submit_replay_gyroscope"
                )
            case .acceleration(let acceleration):
                try Self.requireOK(
                    xrslam_bench_push_acceleration_mps2(
                        handle,
                        sample.timestampNanoseconds,
                        acceleration.x,
                        acceleration.y,
                        acceleration.z
                    ),
                    operation: "submit_replay_acceleration"
                )
            }
        }
    }

    func submitCamera(_ frame: MonochromeCameraFrame, acceptedNanoseconds: UInt64) throws {
        guard frame.timestampNanoseconds <= UInt64(Int64.max) else {
            throw XRSLAMNativeSessionError.invalidTimestamp
        }
        guard frame.width == imageWidth, frame.height == imageHeight else {
            throw XRSLAMNativeSessionError.invalidImageGeometry(
                expected: "\(imageWidth)x\(imageHeight)",
                actual: "\(frame.width)x\(frame.height)"
            )
        }
        // The plane is the bench's own copy; the camera buffer it came from was
        // released inside the capture callback (Apple TN2445). Nothing here
        // locks or retains a CVPixelBuffer any more.
        try frame.withLumaPlane { pixels, bytesPerRow in
            try submitCamera(
                pixels: pixels,
                width: frame.width,
                height: frame.height,
                bytesPerRow: bytesPerRow,
                timestampNanoseconds: Int64(frame.timestampNanoseconds),
                acceptedNanoseconds: acceptedNanoseconds
            )
        }
    }

    func submitCamera(
        images: [GrayscaleImage],
        timestampNanoseconds: Int64,
        acceptedNanoseconds: UInt64
    ) throws {
        guard images.count == 1, let image = images.first else {
            throw XRSLAMNativeSessionError.invalidImageGeometry(
                expected: "one \(imageWidth)x\(imageHeight) grayscale image",
                actual: "\(images.count) images"
            )
        }
        guard image.width == imageWidth, image.height == imageHeight else {
            throw XRSLAMNativeSessionError.invalidImageGeometry(
                expected: "\(imageWidth)x\(imageHeight)",
                actual: "\(image.width)x\(image.height)"
            )
        }
        try image.pixels.withUnsafeBytes { rawBuffer in
            guard let pixels = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                throw XRSLAMNativeSessionError.missingLumaPlane
            }
            try submitCamera(
                pixels: pixels,
                width: image.width,
                height: image.height,
                bytesPerRow: image.bytesPerRow,
                timestampNanoseconds: timestampNanoseconds,
                acceptedNanoseconds: acceptedNanoseconds
            )
        }
    }

    func submitEuRoCCameraFile(
        _ imageURL: URL,
        timestampNanoseconds: Int64,
        acceptedNanoseconds: UInt64
    ) throws {
        let status = imageURL.path.withCString { path in
            xrslam_bench_push_euroc_image_file(handle, timestampNanoseconds, path)
        }
        try Self.requireOK(status, operation: "submit_official_euroc_camera")
        acceptedCameraTimes[timestampNanoseconds] = acceptedNanoseconds
        let runStatus = xrslam_bench_run_one_frame(handle)
        if runStatus == XRSLAM_BENCH_NONFINITE_OUTPUT {
            acceptedCameraTimes.removeValue(forKey: timestampNanoseconds)
            return
        }
        try Self.requireOK(runStatus, operation: "run_one_frame")
    }

    /// Reads the engine's IMU-propagated pose without consuming a frame result.
    ///
    /// [2026-09-09] The per-frame path emits exactly one pose per image, so our pose rate has always
    /// been the visual frame rate. ARKit's is not: it delivers 60 ARFrames/s and skips the vision
    /// work on some of them (WWDC18 610). Upstream's `get_result(BODY_POSE)` is the same
    /// construction -- the last optimised state propagated through the IMU that arrived after it --
    /// so polling it on a timer measures our pose delivery the way ARKit's is measured.
    ///
    /// Returns nil when the engine has no pose yet, when the state is not tracking-success, or when
    /// the propagation has not advanced since the previous call (no new IMU, so no new pose).
    func queryPose() throws -> NativePoseSample? {
        var output = xrslam_bench_frame_result_t()
        let status = xrslam_bench_query_pose(handle, &output)
        if status == XRSLAM_BENCH_NO_OUTPUT || status == XRSLAM_BENCH_END_OF_STREAM
            || status == XRSLAM_BENCH_NONFINITE_OUTPUT {
            return nil
        }
        try Self.requireOK(status, operation: "query_pose")
        guard output.state == 1 else { return nil }
        guard output.pose_timestamp_ns > lastQueriedPoseNanoseconds else { return nil }
        lastQueriedPoseNanoseconds = output.pose_timestamp_ns
        guard let pose = XRSLAMPoseAdapter.makeTimedPose(
            timestampNanoseconds: output.pose_timestamp_ns,
            translationX: output.translation_xyz.0,
            translationY: output.translation_xyz.1,
            translationZ: output.translation_xyz.2,
            quaternionX: output.quaternion_xyzw.0,
            quaternionY: output.quaternion_xyzw.1,
            quaternionZ: output.quaternion_xyzw.2,
            quaternionW: output.quaternion_xyzw.3
        ) else {
            if degenerateQuaternionResults == 0 {
                degenerateQuaternionFirstAtPose = trackingPoseResults
                degenerateQuaternionFirstPath = 1
            }
            if trackingPoseResults > 0 { degenerateQuaternionAfterFirstPose += 1 }
            degenerateQuaternionResults += 1
            return nil
        }
        // Staleness of the sensor data behind this pose, on the same monotonic clock the per-frame
        // path uses: the pose is propagated to the newest IMU sample, which entered the app at
        // lastIMUAcceptedNanoseconds.
        let now = DispatchTime.now().uptimeNanoseconds
        let accepted = lastIMUAcceptedNanoseconds == 0 ? now : lastIMUAcceptedNanoseconds
        return NativePoseSample(
            pose: pose,
            capturedMonotonicNanoseconds: accepted,
            pipelineLatencyNanoseconds: now >= accepted ? now - accepted : 0
        )
    }

    private var lastQueriedPoseNanoseconds: Int64 = 0

    func pollPose() throws -> NativePoseSample? {
        while true {
            var output = xrslam_bench_frame_result_t()
            let status = xrslam_bench_poll_result(handle, &output)
            if status == XRSLAM_BENCH_NO_OUTPUT || status == XRSLAM_BENCH_END_OF_STREAM {
                return nil
            }
            try Self.requireOK(status, operation: "poll_pose")
            let accepted = acceptedCameraTimes.removeValue(
                forKey: output.input_timestamp_ns
            ) ?? DispatchTime.now().uptimeNanoseconds

            // Frozen XRSLAM state enum: initializing=0, tracking success=1,
            // tracking fail=2. Only successful estimates are benchmark poses.
            switch output.state {
            case 0:
                initializingResults += 1
                continue
            case 1:
                break
            case 2:
                trackingFailureResults += 1
                continue
            default:
                throw XRSLAMNativeSessionError.status(
                    operation: "invalid_tracking_state",
                    code: XRSLAM_BENCH_INTERNAL_ERROR
                )
            }

            guard let pose = XRSLAMPoseAdapter.makeTimedPose(
                timestampNanoseconds: output.pose_timestamp_ns,
                translationX: output.translation_xyz.0,
                translationY: output.translation_xyz.1,
                translationZ: output.translation_xyz.2,
                quaternionX: output.quaternion_xyzw.0,
                quaternionY: output.quaternion_xyzw.1,
                quaternionZ: output.quaternion_xyzw.2,
                quaternionW: output.quaternion_xyzw.3
            ) else {
                // Second increment site: the per-frame result path. The polled
                // path is instrumented the same way; without both, the ordinal
                // reads "never" while the count reads 1.
                if degenerateQuaternionResults == 0 {
                    degenerateQuaternionFirstAtPose = trackingPoseResults
                    degenerateQuaternionFirstPath = 2
                }
                if trackingPoseResults > 0 { degenerateQuaternionAfterFirstPose += 1 }
                degenerateQuaternionResults += 1
                continue
            }
            trackingPoseResults += 1
            let now = DispatchTime.now().uptimeNanoseconds
            return NativePoseSample(
                pose: pose,
                capturedMonotonicNanoseconds: accepted,
                pipelineLatencyNanoseconds: now >= accepted ? now - accepted : 0
            )
        }
    }

    func snapshot() throws -> VIOEngineSnapshot {
        var native = xrslam_bench_snapshot_t()
        try Self.requireOK(
            xrslam_bench_get_snapshot(handle, &native),
            operation: "snapshot"
        )
        let value = native.counters
        var snapshot = VIOEngineSnapshot()
        snapshot.counters = VIOEngineCounters(
            cameraOffered: value.images_offered,
            cameraAccepted: value.images_accepted,
            cameraDroppedQueueFull: value.images_rejected_queue_full,
            cameraRejectedTimestamp: value.images_rejected_timestamp,
            cameraRejectedSealed: value.images_rejected_sealed,
            cameraBytesCopied: value.image_bytes_copied,
            imuOffered: min(value.accel_offered, value.gyro_offered),
            imuAccepted: min(value.accel_accepted, value.gyro_accepted),
            imuDroppedQueueFull:
                value.accel_rejected_queue_full + value.gyro_rejected_queue_full,
            imuRejectedTimestamp:
                value.accel_rejected_timestamp + value.gyro_rejected_timestamp,
            imuRejectedSealed:
                value.accel_rejected_sealed + value.gyro_rejected_sealed,
            posesProduced: trackingPoseResults,
            posesPolled: trackingPoseResults,
            posesDroppedBridgeQueue: value.results_rejected_queue_full,
            // [2026-09-16] The degenerate quaternion used to be folded in here,
            // which failed every live run that ever produced poses on a
            // once-per-initialization artifact. It is reported on its own now;
            // `degenerateQuaternionAfterFirstPose` is the half that is a fault.
            nonfinitePoseRejected: value.nonfinite_results_rejected
        )
        // [bench 2026-09-02] `-PWFeederGateOff` 让回放喂帧端不再按引擎 backlog 等待
        // (waitForReplayCapacity 见 capacity==0 立即返回)。用途只有一个:验证
        // 库内部的生产者侧背压闸(libxrslam_thrbp)能否独自把队列封顶。size 仍是
        // 真实 backlog,所以 diagnostics 里 camera_input_peak 照常可读;
        // camera_input_capacity=0 即为本旗生效的可审计痕迹。不设旗时逐字节等价。
        let feederGateOff = ProcessInfo.processInfo.arguments.contains("-PWFeederGateOff")
        snapshot.cameraInputQueue = VIOEngineQueueMeasurement(
            size: native.pending_event_count,
            capacity: feederGateOff ? 0 : native.event_queue_capacity,
            peak: native.event_queue_peak
        )
        snapshot.imuInputQueue = VIOEngineQueueMeasurement(
            size: native.pending_event_count,
            capacity: 0,
            peak: 0
        )
        snapshot.poseBridgeQueuePeak = native.result_queue_peak
        snapshot.additionalCounters = [
            // Upstream reports no health at all; these are VINS-Mono's
            // published divergence criteria, ported verbatim and read-only, so
            // a consumer can tell a good pose from one behind a diverged
            // estimator the way ARKit's non-normal tracking state lets it.
            "xrslam_divergence_frames": native.divergence_frames,
            "xrslam_divergence_longest_ms": native.divergence_longest_ms,
            "xrslam_divergence_sustained_frames": native.divergence_sustained_frames,
            "xrslam_divergence_flags_seen": native.divergence_flags_seen,
            // [2026-09-09] Why initialisation has not finished. Two of the engine's four SfM exits
            // are silent, so before these a run could not separate "the user has not moved enough"
            // from "the geometry is degenerate" -- which is the whole question behind our 3.5 s
            // time-to-first-pose against ARKit's 1.5 s.
            // [2026-09-16] The three causes the live validity gate collapses into
            // `nonfinite_pose_rejected`, plus the Swift-side degenerate quaternion
            // that is added to it. Every live run so far is invalid on a count of
            // exactly 1, and that 1 appears in every run that produced poses and in
            // none that produced zero -- so which cause it is decides whether the
            // gate is catching a real fault or a once-per-initialization artifact.
            "xrslam_result_state_out_of_range": native.result_state_out_of_range,
            "xrslam_result_pose_nonfinite": native.result_pose_nonfinite,
            "xrslam_result_timestamp_unconvertible": native.result_timestamp_unconvertible,
            "xrslam_degenerate_quaternion": degenerateQuaternionResults,
            "xrslam_degenerate_quaternion_first_at_pose": degenerateQuaternionFirstAtPose,
            "xrslam_degenerate_quaternion_first_path": degenerateQuaternionFirstPath,
            "xrslam_degenerate_quaternion_after_first_pose": degenerateQuaternionAfterFirstPose,
            "xrslam_init_too_few_frames": native.init_too_few_frames,
            "xrslam_init_attempts": native.init_attempts,
            "xrslam_init_fail_matches": native.init_fail_matches,
            "xrslam_init_fail_parallax": native.init_fail_parallax,
            "xrslam_init_fail_rotation": native.init_fail_rotation,
            "xrslam_init_fail_triangulation": native.init_fail_triangulation,
            "xrslam_init_fail_imu": native.init_fail_imu,
            "xrslam_init_success": native.init_success,
            // [2026-09-17] Solver / reprojection telemetry: values the sliding window already
            // computed and dropped. ~0 in every slot means the linked engine has no instrumentation.
            "xrslam_solve_calls": native.solve_calls,
            "xrslam_solve_unusable": native.solve_unusable,
            "xrslam_track_evaluated": native.track_evaluated,
            "xrslam_track_reject_depth": native.track_reject_depth,
            "xrslam_track_reject_rpe": native.track_reject_rpe,
            "xrslam_track_rpe_samples": native.track_rpe_samples,
            "xrslam_track_rpe_millipx": native.track_rpe_millipx,
            "xrslam_frames_rpe_calls": native.frames_rpe_calls,
            "xrslam_frames_rpe_reject": native.frames_rpe_reject,
            "xrslam_frames_rpe_samples": native.frames_rpe_samples,
            "xrslam_frames_rpe_millipx": native.frames_rpe_millipx,
            // [2026-09-17] OpenXR/Monado relation contract. relation_samples == 0 means the linked
            // engine predates the contract; a zero mask from an engine that has it is a real answer.
            "xrslam_relation_samples": native.relation_samples,
            "xrslam_relation_none": native.relation_none,
            "xrslam_relation_orientation_unreadable": native.relation_orientation_unreadable,
            "xrslam_relation_position_unreadable": native.relation_position_unreadable,
            "xrslam_relation_valid_untracked": native.relation_valid_untracked,
            "xrslam_relation_tracked": native.relation_tracked,
            "xrslam_init_mirror_us": native.init_mirror_us,
            "xrslam_estimator_imu_ingested": native.estimator_imu_ingested,
            "xrslam_estimator_camera_ingested": native.estimator_camera_ingested,
            "xrslam_live_separate_events_submitted": liveSeparateEventsSubmitted,
            "xrslam_live_cross_stream_inversions": liveCrossStreamInversions,
            "xrslam_live_cross_stream_max_inversion_ns":
                UInt64(max(0, liveCrossStreamMaxInversionNanoseconds)),
            "xrslam_events_offered": value.events_offered,
            "xrslam_events_accepted": value.events_accepted,
            "xrslam_events_processed": value.events_processed,
            "xrslam_events_rejected_queue_full": value.events_rejected_queue_full,
            "xrslam_accel_offered": value.accel_offered,
            "xrslam_accel_accepted": value.accel_accepted,
            "xrslam_accel_processed": value.accel_processed,
            "xrslam_accel_rejected_queue_full": value.accel_rejected_queue_full,
            "xrslam_gyro_offered": value.gyro_offered,
            "xrslam_gyro_accepted": value.gyro_accepted,
            "xrslam_gyro_processed": value.gyro_processed,
            "xrslam_gyro_rejected_queue_full": value.gyro_rejected_queue_full,
            "xrslam_images_offered": value.images_offered,
            "xrslam_images_accepted": value.images_accepted,
            "xrslam_images_processed": value.images_processed,
            "xrslam_images_rejected_queue_full": value.images_rejected_queue_full,
            "xrslam_replay_images_decoded": value.replay_images_decoded,
            "xrslam_replay_images_undistorted": value.replay_images_undistorted,
            "xrslam_replay_image_decode_failures": value.replay_image_decode_failures,
            "xrslam_replay_image_preprocess_failures": value.replay_image_preprocess_failures,
            "xrslam_frames_run": value.frames_run,
            "xrslam_results_produced": value.results_produced,
            "xrslam_results_polled": value.results_polled,
            "xrslam_results_rejected_queue_full": value.results_rejected_queue_full,
            "xrslam_initializing_results": initializingResults,
            "xrslam_tracking_failure_results": trackingFailureResults,
            "xrslam_degenerate_quaternion_results": degenerateQuaternionResults,
            "xrslam_upstream_destroy_calls": value.upstream_destroy_calls,
        ]
        snapshot.effectiveConfiguration = [
            "thread_policy": "single_serial_benchmark_coordinator",
            "sensor_fifo_policy": "serialized_direct_imu_then_image_run",
            "native_image_slot": "one_create_time_preallocated_grayscale_buffer",
            "native_event_queue_capacity": String(native.event_queue_capacity),
            // [bench 2026-09-02] 引擎内部 deque 的峰值(不是单槽峰值)。
            "xrslam_engine_backlog_peak": String(native.engine_backlog_peak),
            "native_result_queue_capacity": String(native.result_queue_capacity),
            "camera_width": String(imageWidth),
            "camera_height": String(imageHeight),
            "pose_frame": "upstream_body_imu_pose_direct_to_tum",
            "scene_kit_axis_remap_applied": "false",
            "acceleration_live_units_at_bridge": "core_motion_g_times_negative_9_80665",
            "acceleration_replay_units_at_bridge": "meters_per_second_squared_passthrough",
            "replay_equal_timestamp_imu_order": "gyroscope_then_accelerometer",
            "replay_image_decode": "opencv_4_0_1_imread_unchanged",
            "replay_image_undistortion": "opencv_4_0_1_cv_undistort_mh01_cam0_float_kd",
            "config_transport": "filesystem_paths_yaml_load_file",
            "stop_requested": String(stopRequestLock.withLock { stopWasRequested }),
        ]
        return snapshot
    }

    func sealDrainStop() throws {
        try Self.requireOK(xrslam_bench_seal_inputs(handle), operation: "seal")
        try Self.requireOK(xrslam_bench_drain(handle), operation: "drain")
        try Self.requireOK(xrslam_bench_stop(handle), operation: "stop")
    }

    func requestStop() {
        // The frozen core is synchronous and the coordinator is its sole
        // caller. Cross-thread Destroy would violate that contract; the run
        // loop observes this request, then deinit performs seal/drain/stop on
        // the owner queue.
        stopRequestLock.withLock { stopWasRequested = true }
    }

    private func submitCamera(
        pixels: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        timestampNanoseconds: Int64,
        acceptedNanoseconds: UInt64
    ) throws {
        var image = xrslam_bench_image_t()
        image.gray_pixels = pixels
        image.width = UInt32(width)
        image.height = UInt32(height)
        image.bytes_per_row = UInt32(bytesPerRow)
        try Self.requireOK(
            xrslam_bench_push_image(handle, timestampNanoseconds, &image),
            operation: "submit_camera"
        )
        acceptedCameraTimes[timestampNanoseconds] = acceptedNanoseconds
        let runStatus = xrslam_bench_run_one_frame(handle)
        if runStatus == XRSLAM_BENCH_NONFINITE_OUTPUT {
            acceptedCameraTimes.removeValue(forKey: timestampNanoseconds)
            return
        }
        try Self.requireOK(runStatus, operation: "run_one_frame")
    }

    private static func requireOK(
        _ status: xrslam_bench_status_t,
        operation: String
    ) throws {
        guard status == XRSLAM_BENCH_OK else {
            throw XRSLAMNativeSessionError.status(operation: operation, code: status)
        }
    }
}
