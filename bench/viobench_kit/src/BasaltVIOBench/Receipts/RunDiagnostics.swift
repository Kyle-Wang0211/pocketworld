import Foundation

struct RunDiagnostics: Codable, Equatable {
    let schemaVersion: Int
    let runID: String
    let capturedAtUTC: String
    let status: String
    let reason: String?
    let device: RunDeviceEvidence
    let nativeCounters: [String: UInt64]
    let queueMeasurements: [String: UInt64]
    let transportCounters: [String: UInt64]
    let effectiveConfiguration: [String: String]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case capturedAtUTC = "captured_at_utc"
        case status, reason, device
        case nativeCounters = "native_counters"
        case queueMeasurements = "queue_measurements"
        case transportCounters = "transport_counters"
        case effectiveConfiguration = "effective_configuration"
    }
}

enum RunDiagnosticsWriter {
    static func writeARKit(
        runID: String,
        snapshot: ARKitReferenceSnapshot,
        configuration: ARKitReferenceConfigurationReceipt,
        lifecycle: ARKitReferenceLifecycleReceipt,
        applicationLifecycleViolations: UInt64,
        exclusivity: BenchRunExclusivityReceipt,
        to directoryURL: URL
    ) throws {
        try write(
            RunDiagnostics(
                schemaVersion: 1,
                runID: runID,
                capturedAtUTC: BenchmarkRunPreparation.utcTimestamp(),
                status: "full",
                reason: nil,
                device: .current(),
                nativeCounters: [
                    "frames_received": snapshot.framesReceived,
                    "finite_poses": snapshot.finitePoses,
                    "nonfinite_poses": snapshot.nonfinitePoses,
                    "tracking_normal": snapshot.trackingNormal,
                    "tracking_limited_initializing": snapshot.trackingLimitedInitializing,
                    "tracking_limited_excessive_motion": snapshot.trackingLimitedExcessiveMotion,
                    "tracking_limited_insufficient_features": snapshot.trackingLimitedInsufficientFeatures,
                    "tracking_limited_relocalizing": snapshot.trackingLimitedRelocalizing,
                    "tracking_limited_other": snapshot.trackingLimitedOther,
                    "tracking_not_available": snapshot.trackingNotAvailable,
                    "mapping_not_available": snapshot.mappingNotAvailable,
                    "mapping_limited": snapshot.mappingLimited,
                    "mapping_extending": snapshot.mappingExtending,
                    "mapping_mapped": snapshot.mappingMapped,
                    "tracking_transitions": snapshot.trackingTransitions,
                    "mapping_transitions": snapshot.mappingTransitions,
                    "stall_events_over_one_second": snapshot.stallEventsOverOneSecond,
                    "relocalization_attempts": snapshot.relocalizationAttempts,
                    "relocalization_recoveries": snapshot.relocalizationRecoveries,
                ],
                queueMeasurements: [:],
                transportCounters: [
                    "estimated_missed_frame_intervals": snapshot.estimatedMissedFrames,
                    "timestamp_regressions": snapshot.timestampRegressions,
                    "invalid_callback_latencies": snapshot.invalidCallbackLatencies,
                    "callbacks_after_pause": snapshot.callbacksAfterPause,
                    "session_interruptions": snapshot.sessionInterruptions,
                    "session_interruption_ends": snapshot.sessionInterruptionEnds,
                    "session_failures": snapshot.sessionFailures,
                    "application_lifecycle_violations": applicationLifecycleViolations,
                ],
                effectiveConfiguration: [
                    "engine_id": BenchBackend.arkit.id,
                    "engine_upstream_revision": BenchBackend.arkit.upstreamRevision,
                    "reference_only": "true",
                    "external_ground_truth": "none",
                    "live_accuracy_status": "not_evaluable",
                    "pose_frame": "world_from_camera",
                    "camera_imu_transport": "private_to_arkit",
                    "autofocus_enabled": String(configuration.autoFocusEnabled),
                    "world_alignment": configuration.worldAlignment,
                    "light_estimation_enabled": String(configuration.lightEstimationEnabled),
                    "horizontal_plane_detection_enabled": String(configuration.horizontalPlaneDetectionEnabled),
                    "physical_memory_bytes": String(configuration.physicalMemoryBytes),
                    "four_k_memory_threshold_bytes": String(configuration.fourKMemoryThresholdBytes),
                    "video_format_mode": configuration.videoFormatMode,
                    "four_k_policy_active": "false",
                    "camera_width": String(configuration.selectedWidth),
                    "camera_height": String(configuration.selectedHeight),
                    "camera_fps": String(configuration.selectedFramesPerSecond),
                    "recommended_for_high_resolution_capture": String(configuration.selectedForHighResolutionCapture),
                    "official_aether_ar_30fps": String(configuration.thirtyFPSOverrideEnabled),
                    // 🔴 Bench-only ruler, never a product input. Recorded so a
                    // run without depth says which of the two it was: no
                    // scanner on this device, or the arm never asked.
                    "scene_depth_supported": String(configuration.sceneDepthSupported),
                    "scene_depth_requested": String(configuration.sceneDepthRequested),
                    "scene_depth_role": "bench_only_metric_ruler_not_a_product_input",
                    "delegate_queue": configuration.delegateQueue,
                    "start_options": configuration.startOptions,
                    "missed_frame_count_semantics": "estimated_from_arframe_timestamp_gaps_not_platform_drop_ground_truth",
                    "callback_latency_semantics": "arframe_timestamp_to_delegate_entry_same_clock_assumption_proxy_not_hardware_ground_truth",
                    "run_request_ns": String(lifecycle.runRequestNanoseconds ?? 0),
                    "run_return_ns": String(lifecycle.runReturnNanoseconds ?? 0),
                    "stop_request_ns": String(lifecycle.stopRequestNanoseconds ?? 0),
                    "pause_return_ns": String(lifecycle.pauseReturnNanoseconds ?? 0),
                    "last_callback_ns": String(lifecycle.lastCallbackNanoseconds ?? 0),
                    "tracking_dwell_seconds": snapshot.trackingDwellSeconds
                        .sorted { $0.key < $1.key }
                        .map { "\($0.key)=\($0.value)" }
                        .joined(separator: ","),
                    "mapping_dwell_seconds": snapshot.mappingDwellSeconds
                        .sorted { $0.key < $1.key }
                        .map { "\($0.key)=\($0.value)" }
                        .joined(separator: ","),
                    "selected_arm": exclusivity.selectedArm,
                    "lease_acquired_ns": String(exclusivity.acquiredNanoseconds),
                    "lease_released_ns": String(exclusivity.releasedNanoseconds ?? 0),
                    "max_simultaneous_active_arms": String(exclusivity.maxSimultaneousActiveArms),
                    "overlap_duration_ns": String(exclusivity.overlapDurationNanoseconds),
                    "engine_session_active_during_lease": String(exclusivity.engineSessionActive),
                    "arsession_active_during_lease": String(exclusivity.arSessionActive),
                    "avfoundation_transport_active_during_lease": String(exclusivity.avFoundationTransportActive),
                ]
            ),
            to: directoryURL
        )
    }

    static func writeFull(
        backend: BenchBackend,
        runID: String,
        native: VIOEngineSnapshot,
        transport: LiveSensorTransportSnapshot? = nil,
        applicationLifecycleViolations: UInt64 = 0,
        evaluationConfiguration: TrajectoryEvaluationConfiguration? = nil,
        exclusivity: BenchRunExclusivityReceipt? = nil,
        to directoryURL: URL
    ) throws {
        let counters = native.counters
        var transportCounters: [String: UInt64] = [:]
        var effectiveConfiguration: [String: String] = [
            "engine_id": backend.id,
            "engine_upstream_revision": backend.upstreamRevision,
            "opencv_version": backend.openCVVersion,
            "camera_imu_time_offset_ns": "0",
            "temporal_calibration_status": "unverified_upstream_nominal",
            "live_accuracy_status": "not_evaluable",
        ]
        effectiveConfiguration["camera_imu_time_offset_source"] =
            backend == .xrslam
                ? "xrslam_config_4beb1a9"
                : "basalt_calibration_copied_from_xrslam_config_4beb1a9"
        if let exclusivity {
            effectiveConfiguration.merge([
                "selected_arm": exclusivity.selectedArm,
                "lease_acquired_ns": String(exclusivity.acquiredNanoseconds),
                "lease_released_ns": String(exclusivity.releasedNanoseconds ?? 0),
                "max_simultaneous_active_arms": String(exclusivity.maxSimultaneousActiveArms),
                "overlap_duration_ns": String(exclusivity.overlapDurationNanoseconds),
                "engine_session_active_during_lease": String(exclusivity.engineSessionActive),
                "arsession_active_during_lease": String(exclusivity.arSessionActive),
                "avfoundation_transport_active_during_lease": String(exclusivity.avFoundationTransportActive),
            ], uniquingKeysWith: { _, new in new })
        }
        effectiveConfiguration.merge(
            native.effectiveConfiguration,
            uniquingKeysWith: { _, new in new }
        )
        if let evaluationConfiguration {
            effectiveConfiguration.merge([
                "trajectory_association": "monotonic_one_to_one_nearest_neighbor",
                "trajectory_association_tie_policy": "earlier_ground_truth_timestamp",
                "trajectory_association_tolerance_ns": String(
                    evaluationConfiguration.associationToleranceNanoseconds
                ),
                "rpe_horizon_ns": String(
                    evaluationConfiguration.rpeHorizonNanoseconds
                ),
                "rpe_horizon_tolerance_ns": String(
                    evaluationConfiguration.rpeHorizonToleranceNanoseconds
                ),
                "trajectory_alignment": "single_se3_scale_fixed_1",
                "trajectory_frame": "body_imu",
            ], uniquingKeysWith: { _, new in new })
        }
        if let transport {
            let accounting = transport.accounting
            let assembly = transport.imuAssembly
            transportCounters = [
                "camera_inputs": accounting.cameraInputs,
                "gyroscope_inputs": accounting.gyroscopeInputs,
                "accelerometer_inputs": accounting.accelerometerInputs,
                "camera_drops_late": accounting.cameraDropsLate,
                "camera_drops_out_of_buffers": accounting.cameraDropsOutOfBuffers,
                "camera_drops_discontinuity": accounting.cameraDropsDiscontinuity,
                "camera_drops_invalid_format": accounting.cameraDropsInvalidFormat,
                "camera_drops_invalid_timestamp": accounting.cameraDropsInvalidTimestamp,
                "camera_drops_timestamp_regression": accounting.cameraDropsTimestampRegression,
                "camera_drops_unknown": accounting.cameraDropsUnknown,
                "timestamp_regressions": accounting.timestampRegressions,
                "motion_errors": accounting.motionErrors,
                "capture_interruptions": accounting.captureInterruptions,
                "capture_runtime_errors": accounting.captureRuntimeErrors,
                "application_lifecycle_violations": applicationLifecycleViolations,
                "imu_paired_outputs": assembly.pairedOutputs,
                "imu_unbracketed_gyro_boundary_drops": assembly.unbracketedGyroscopeDrops,
                "imu_pending_gyro_overflow_drops": assembly.pendingGyroscopeOverflowDrops,
                "imu_sealed_pending_gyro_boundary_drops": assembly.sealedPendingGyroscopeDrops,
                "imu_sealed_input_rejections": assembly.sealedInputRejections,
                "imu_gyro_timestamp_regressions": assembly.gyroscopeTimestampRegressions,
                "imu_accel_timestamp_regressions": assembly.accelerationTimestampRegressions,
                "imu_output_timestamp_regressions": assembly.outputTimestampRegressions,
                "camera_handoff_accepted": transport.cameraHandoff.accepted,
                "camera_handoff_dropped_full": transport.cameraHandoff.droppedFull,
                "camera_handoff_dropped_contended": transport.cameraHandoff.droppedContended,
                "camera_handoff_rejected_sealed": transport.cameraHandoff.rejectedSealed,
                "imu_handoff_accepted": transport.imuHandoff.accepted,
                "imu_handoff_dropped_full": transport.imuHandoff.droppedFull,
                "imu_handoff_dropped_contended": transport.imuHandoff.droppedContended,
                "imu_handoff_rejected_sealed": transport.imuHandoff.rejectedSealed,
                "xrslam_sensor_handoff_accepted": transport.xrslamSensorHandoff.accepted,
                "xrslam_sensor_handoff_dropped_full": transport.xrslamSensorHandoff.droppedFull,
                "xrslam_sensor_handoff_dropped_contended": transport.xrslamSensorHandoff.droppedContended,
                "xrslam_sensor_handoff_rejected_sealed": transport.xrslamSensorHandoff.rejectedSealed,
            ]
            effectiveConfiguration["imu_delivery_mode"] = transport.imuDeliveryMode.rawValue
            if let format = transport.captureFormat {
                effectiveConfiguration.merge([
                    "camera_device_type": format.cameraDeviceType,
                    "active_format_index": String(format.activeFormatIndex),
                    "active_format_media_subtype": format.activeFormatMediaSubtype,
                    "output_pixel_format": format.outputPixelFormat,
                    "camera_width": String(format.width),
                    "camera_height": String(format.height),
                    "camera_fps": String(format.selectedFramesPerSecond),
                    "supported_fps_range": format.supportedFrameRateRange,
                    "field_of_view_degrees": String(format.fieldOfViewDegrees),
                    "zoom_factor": String(format.zoomFactor),
                    "rotation_degrees": String(format.rotationDegrees),
                    "preferred_stabilization_mode": String(format.preferredStabilizationMode),
                    "active_stabilization_mode": String(format.activeStabilizationMode),
                    "session_preset": format.sessionPreset,
                    "matching_format_count": String(format.matchingFormatCount),
                    "available_pixel_formats": format.availablePixelFormats,
                    "grayscale_conversion": format.grayscaleConversion,
                    "locked_lens_position": String(format.lockedLensPosition),
                    "xrslam_pixel_pipeline_divergence": format.xrslamPixelPipelineDivergence,
                ], uniquingKeysWith: { _, new in new })
            }
        }
        var nativeCounters: [String: UInt64] = [
            "camera_offered": counters.cameraOffered,
            "camera_accepted": counters.cameraAccepted,
            "camera_dropped_queue_full": counters.cameraDroppedQueueFull,
            "camera_rejected_timestamp": counters.cameraRejectedTimestamp,
            "camera_rejected_sealed": counters.cameraRejectedSealed,
            "camera_bytes_copied": counters.cameraBytesCopied,
            "camera_copy_service_ns_total": counters.cameraCopyServiceNanosecondsTotal,
            "camera_copy_service_ns_max": counters.cameraCopyServiceNanosecondsMax,
            "imu_offered": counters.imuOffered,
            "imu_accepted": counters.imuAccepted,
            "imu_dropped_queue_full": counters.imuDroppedQueueFull,
            "imu_rejected_timestamp": counters.imuRejectedTimestamp,
            "imu_rejected_sealed": counters.imuRejectedSealed,
            "poses_produced": counters.posesProduced,
            "poses_polled": counters.posesPolled,
            "poses_dropped_bridge_queue": counters.posesDroppedBridgeQueue,
            "nonfinite_pose_rejected": counters.nonfinitePoseRejected,
            "image_eof_sentinels_sent": counters.imageEOFSentinelsSent,
            "imu_eof_sentinels_sent": counters.imuEOFSentinelsSent,
            "pose_eof_sentinels_received": counters.poseEOFSentinelsReceived,
        ]
        nativeCounters.merge(
            native.additionalCounters,
            uniquingKeysWith: { _, new in new }
        )
        // Hoisted and explicitly typed: inlining these three into the literal
        // below pushed it past the type checker's budget.
        let lumaPoolPlanes: UInt64 = UInt64(transport?.lumaPoolPlanes ?? 0)
        let lumaPoolPeakHeld: UInt64 = UInt64(transport?.lumaPoolPeakHeld ?? 0)
        let lumaPoolExhausted: UInt64 = transport?.lumaPoolExhaustedDrops ?? 0
        // This map is [String: UInt64]; both probes use 0 for "never sampled",
        // which is also the reading that would condemn the copy, so a 0 here is
        // read together with camera_inputs.
        let lumaPoolMean: UInt64 = UInt64(max(0, transport?.lumaPoolSampleMeanLuma ?? 0))
        let lumaPoolStride: UInt64 = UInt64(max(0, transport?.lumaPoolSourceStride ?? 0))
        try write(
            RunDiagnostics(
                schemaVersion: 1,
                runID: runID,
                capturedAtUTC: BenchmarkRunPreparation.utcTimestamp(),
                status: "full",
                reason: nil,
                device: .current(),
                nativeCounters: nativeCounters,
                queueMeasurements: [
                    "camera_input_capacity": native.cameraInputQueue.capacity,
                    "camera_input_peak": native.cameraInputQueue.peak,
                    "vision_queue_peak": native.visionQueuePeak,
                    "imu_input_capacity": native.imuInputQueue.capacity,
                    "imu_input_peak": native.imuInputQueue.peak,
                    "bridge_pose_peak": native.poseBridgeQueuePeak,
                    "xrslam_sensor_handoff_capacity": UInt64(
                        transport?.xrslamSensorHandoff.capacity ?? 0
                    ),
                    "xrslam_sensor_handoff_peak": UInt64(
                        transport?.xrslamSensorHandoff.highWatermark ?? 0
                    ),
                    // Bench-owned luma planes (TN2445 fix). A refusal here is
                    // our bounded queue saying no; it is deliberately not
                    // counted in any camera_drops_* so the two stay separable.
                    "luma_pool_planes": lumaPoolPlanes,
                    "luma_pool_peak_held": lumaPoolPeakHeld,
                    "luma_pool_exhausted_drops": lumaPoolExhausted,
                    "luma_pool_sample_mean_luma": lumaPoolMean,
                    "luma_pool_source_stride": lumaPoolStride,
                ],
                transportCounters: transportCounters,
                effectiveConfiguration: effectiveConfiguration
            ),
            to: directoryURL
        )
    }

    static func writeUnavailable(
        backend: BenchBackend,
        runID: String,
        reason: String,
        to directoryURL: URL
    ) throws {
        try write(
            RunDiagnostics(
                schemaVersion: 1,
                runID: runID,
                capturedAtUTC: BenchmarkRunPreparation.utcTimestamp(),
                status: "unavailable",
                reason: reason,
                device: .current(),
                nativeCounters: [:],
                queueMeasurements: [:],
                transportCounters: [:],
                effectiveConfiguration: [
                    "engine_id": backend.id,
                    "engine_upstream_revision": backend.upstreamRevision,
                ]
            ),
            to: directoryURL
        )
    }

    private static func write(_ diagnostics: RunDiagnostics, to directoryURL: URL) throws {
        try RunReceiptJSON.encoder.encode(diagnostics).write(
            to: directoryURL.appendingPathComponent("diagnostics.json"),
            options: .atomic
        )
    }
}
