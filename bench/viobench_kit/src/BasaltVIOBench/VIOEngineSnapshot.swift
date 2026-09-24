import Foundation

struct VIOEngineCounters: Equatable, Sendable {
    var cameraOffered: UInt64 = 0
    var cameraAccepted: UInt64 = 0
    var cameraDroppedQueueFull: UInt64 = 0
    var cameraRejectedTimestamp: UInt64 = 0
    var cameraRejectedSealed: UInt64 = 0
    var cameraBytesCopied: UInt64 = 0
    var cameraCopyServiceNanosecondsTotal: UInt64 = 0
    var cameraCopyServiceNanosecondsMax: UInt64 = 0
    var imuOffered: UInt64 = 0
    var imuAccepted: UInt64 = 0
    var imuDroppedQueueFull: UInt64 = 0
    var imuRejectedTimestamp: UInt64 = 0
    var imuRejectedSealed: UInt64 = 0
    var posesProduced: UInt64 = 0
    var posesPolled: UInt64 = 0
    var posesDroppedBridgeQueue: UInt64 = 0
    var nonfinitePoseRejected: UInt64 = 0
    var imageEOFSentinelsSent: UInt64 = 0
    var imuEOFSentinelsSent: UInt64 = 0
    var poseEOFSentinelsReceived: UInt64 = 0
}

struct VIOEngineQueueMeasurement: Equatable, Sendable {
    var size: UInt64 = 0
    var capacity: UInt64 = 0
    var peak: UInt64 = 0
}

struct VIOEngineSnapshot: Equatable, Sendable {
    var counters = VIOEngineCounters()
    var cameraInputQueue = VIOEngineQueueMeasurement()
    var imuInputQueue = VIOEngineQueueMeasurement()
    var visionQueuePeak: UInt64 = 0
    var poseBridgeQueuePeak: UInt64 = 0
    var additionalCounters: [String: UInt64] = [:]
    var effectiveConfiguration: [String: String] = [:]

    init() {}

    init(basalt native: basalt_bench_snapshot_t) {
        let value = native.counters
        counters = VIOEngineCounters(
            cameraOffered: value.camera_offered,
            cameraAccepted: value.camera_accepted,
            cameraDroppedQueueFull: value.camera_dropped_queue_full,
            cameraRejectedTimestamp: value.camera_rejected_timestamp,
            cameraRejectedSealed: value.camera_rejected_sealed,
            cameraBytesCopied: value.camera_bytes_copied,
            cameraCopyServiceNanosecondsTotal: value.camera_copy_service_ns_total,
            cameraCopyServiceNanosecondsMax: value.camera_copy_service_ns_max,
            imuOffered: value.imu_offered,
            imuAccepted: value.imu_accepted,
            imuDroppedQueueFull: value.imu_dropped_queue_full,
            imuRejectedTimestamp: value.imu_rejected_timestamp,
            imuRejectedSealed: value.imu_rejected_sealed,
            posesProduced: value.poses_produced,
            posesPolled: value.poses_polled,
            posesDroppedBridgeQueue: value.poses_dropped_bridge_queue,
            nonfinitePoseRejected: value.nonfinite_pose_rejected,
            imageEOFSentinelsSent: value.image_eof_sentinels_sent,
            imuEOFSentinelsSent: value.imu_eof_sentinels_sent,
            poseEOFSentinelsReceived: value.pose_eof_sentinels_received
        )
        cameraInputQueue = VIOEngineQueueMeasurement(
            size: UInt64(native.optical_flow_input_queue_size),
            capacity: UInt64(native.optical_flow_input_queue_capacity),
            peak: UInt64(native.optical_flow_input_queue_peak)
        )
        imuInputQueue = VIOEngineQueueMeasurement(
            size: UInt64(native.vio_imu_queue_size),
            capacity: UInt64(native.vio_imu_queue_capacity),
            peak: UInt64(native.vio_imu_queue_peak)
        )
        visionQueuePeak = UInt64(native.vio_vision_queue_peak)
        poseBridgeQueuePeak = UInt64(native.bridge_pose_queue_peak)
        effectiveConfiguration = [
            "thread_policy": "upstream_default_no_global_control",
            "global_control_created": "false",
            "requested_max_allowed_parallelism": "null",
            "observed_tbb_active_parallelism": String(native.observed_tbb_active_parallelism),
        ]
    }
}
