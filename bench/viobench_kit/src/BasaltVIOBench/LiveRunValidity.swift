import Foundation

struct LiveRunLossCounters: Equatable {
    let motionErrors: UInt64
    let platformCameraDrops: UInt64
    let captureInterruptions: UInt64
    let captureRuntimeErrors: UInt64
    let timestampRegressions: UInt64
    let applicationLifecycleViolations: UInt64
    let imuAssemblyDrops: UInt64
    let cameraHandoffDrops: UInt64
    let combinedSensorHandoffDrops: UInt64
    let imuHandoffDrops: UInt64
    let nativeIMUDrops: UInt64
    let nativeIMURejections: UInt64
    let nativeCameraTransportLoss: UInt64
    let nativeCameraTimestampRejections: UInt64
    let poseBridgeDrops: UInt64
    let nonfinitePoses: UInt64
    /// Degenerate (zero-norm) quaternions seen *after* the estimator had already
    /// produced a pose. The engine returns TRACKING_SUCCESS with a zero-norm
    /// quaternion on its very first result and never again -- measured on the
    /// deterministic replay as `first_at_pose == 0` with 804 good poses after it.
    /// Folding that boundary case into `nonfinitePoses` failed every live run
    /// that ever produced poses, so it is separate; one in a running estimator
    /// is still a fault and still fails the run.
    let degenerateQuaternionsAfterFirstPose: UInt64

    static let zero = LiveRunLossCounters(
        motionErrors: 0,
        platformCameraDrops: 0,
        captureInterruptions: 0,
        captureRuntimeErrors: 0,
        timestampRegressions: 0,
        applicationLifecycleViolations: 0,
        imuAssemblyDrops: 0,
        cameraHandoffDrops: 0,
        combinedSensorHandoffDrops: 0,
        imuHandoffDrops: 0,
        nativeIMUDrops: 0,
        nativeIMURejections: 0,
        nativeCameraTransportLoss: 0,
        nativeCameraTimestampRejections: 0,
        poseBridgeDrops: 0,
        nonfinitePoses: 0,
        degenerateQuaternionsAfterFirstPose: 0
    )

    func replacing(
        motionErrors: UInt64? = nil,
        platformCameraDrops: UInt64? = nil,
        captureInterruptions: UInt64? = nil,
        captureRuntimeErrors: UInt64? = nil,
        timestampRegressions: UInt64? = nil,
        applicationLifecycleViolations: UInt64? = nil,
        imuAssemblyDrops: UInt64? = nil,
        cameraHandoffDrops: UInt64? = nil,
        combinedSensorHandoffDrops: UInt64? = nil,
        imuHandoffDrops: UInt64? = nil,
        nativeIMUDrops: UInt64? = nil,
        nativeIMURejections: UInt64? = nil,
        nativeCameraTransportLoss: UInt64? = nil,
        nativeCameraTimestampRejections: UInt64? = nil,
        poseBridgeDrops: UInt64? = nil,
        nonfinitePoses: UInt64? = nil,
        degenerateQuaternionsAfterFirstPose: UInt64? = nil
    ) -> LiveRunLossCounters {
        LiveRunLossCounters(
            motionErrors: motionErrors ?? self.motionErrors,
            platformCameraDrops: platformCameraDrops ?? self.platformCameraDrops,
            captureInterruptions: captureInterruptions ?? self.captureInterruptions,
            captureRuntimeErrors: captureRuntimeErrors ?? self.captureRuntimeErrors,
            timestampRegressions: timestampRegressions ?? self.timestampRegressions,
            applicationLifecycleViolations:
                applicationLifecycleViolations ?? self.applicationLifecycleViolations,
            imuAssemblyDrops: imuAssemblyDrops ?? self.imuAssemblyDrops,
            cameraHandoffDrops: cameraHandoffDrops ?? self.cameraHandoffDrops,
            combinedSensorHandoffDrops:
                combinedSensorHandoffDrops ?? self.combinedSensorHandoffDrops,
            imuHandoffDrops: imuHandoffDrops ?? self.imuHandoffDrops,
            nativeIMUDrops: nativeIMUDrops ?? self.nativeIMUDrops,
            nativeIMURejections: nativeIMURejections ?? self.nativeIMURejections,
            nativeCameraTransportLoss:
                nativeCameraTransportLoss ?? self.nativeCameraTransportLoss,
            nativeCameraTimestampRejections: nativeCameraTimestampRejections ?? self.nativeCameraTimestampRejections,
            poseBridgeDrops: poseBridgeDrops ?? self.poseBridgeDrops,
            nonfinitePoses: nonfinitePoses ?? self.nonfinitePoses,
            degenerateQuaternionsAfterFirstPose: degenerateQuaternionsAfterFirstPose
                ?? self.degenerateQuaternionsAfterFirstPose
        )
    }
}

enum LiveRunValidity {
    /// `clockDomainViolation` is checked first: a run whose clocks are mixed has
    /// no valid latency, throughput or window membership, so no other verdict
    /// about it means anything. See `ClockDomainInvariant`.
    static func invalidReason(
        _ counters: LiveRunLossCounters,
        clockDomainViolation: ClockDomainInvariant.Violation? = nil
    ) -> String? {
        if let clockDomainViolation { return clockDomainViolation.reason }
        if counters.motionErrors > 0 { return "motion_transport_error" }
        if counters.platformCameraDrops > 0 { return "platform_camera_loss" }
        if counters.captureInterruptions > 0 { return "capture_interruption" }
        if counters.captureRuntimeErrors > 0 { return "capture_runtime_error" }
        if counters.timestampRegressions > 0 { return "timestamp_regression" }
        if counters.applicationLifecycleViolations > 0 { return "app_backgrounded" }
        if counters.imuAssemblyDrops > 0 { return "imu_assembly_loss" }
        if counters.cameraHandoffDrops > 0 { return "camera_handoff_loss" }
        if counters.combinedSensorHandoffDrops > 0 {
            return "combined_sensor_handoff_loss"
        }
        if counters.imuHandoffDrops > 0 { return "imu_handoff_loss" }
        if counters.nativeIMUDrops > 0 { return "native_imu_transport_loss" }
        if counters.nativeIMURejections > 0 { return "native_imu_rejection" }
        if counters.nativeCameraTransportLoss > 0 {
            return "native_camera_transport_loss"
        }
        if counters.nativeCameraTimestampRejections > 0 {
            return "native_camera_timestamp_rejection"
        }
        if counters.poseBridgeDrops > 0 { return "pose_bridge_loss" }
        if counters.nonfinitePoses > 0 { return "non_finite_pose" }
        if counters.degenerateQuaternionsAfterFirstPose > 0 {
            return "degenerate_quaternion"
        }
        return nil
    }
}

enum ARKitRunValidity {
    static func invalidReason(
        snapshot: ARKitReferenceSnapshot,
        applicationLifecycleViolations: UInt64,
        clockDomainViolation: ClockDomainInvariant.Violation? = nil
    ) -> String? {
        if let clockDomainViolation { return clockDomainViolation.reason }
        if applicationLifecycleViolations > 0 { return "app_backgrounded" }
        if snapshot.sessionInterruptions > 0 { return "arkit_session_interruption" }
        if snapshot.sessionFailures > 0 { return "arkit_session_failure" }
        if snapshot.timestampRegressions > 0 { return "arkit_timestamp_regression" }
        if snapshot.nonfinitePoses > 0 { return "non_finite_pose" }
        if snapshot.callbacksAfterPause > 0 { return "arkit_callbacks_after_pause" }
        return nil
    }
}
