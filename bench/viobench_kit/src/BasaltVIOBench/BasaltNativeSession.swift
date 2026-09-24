import CoreVideo
import Foundation

enum BasaltNativeSessionError: LocalizedError {
    case status(operation: String, code: basalt_bench_status_t)
    case missingLumaPlane
    case invalidTimestamp

    var errorDescription: String? {
        switch self {
        case .status(let operation, let code):
            return "Basalt \(operation) 失败：\(String(cString: basalt_bench_status_name(code)))"
        case .missingLumaPlane:
            return "相机帧没有可读的 8-bit luma plane。"
        case .invalidTimestamp:
            return "传感器时间戳超出 Basalt Int64 纳秒范围。"
        }
    }
}

final class BasaltNativeSession {
    private var handle: OpaquePointer?

    init(configURL: URL, calibrationURL: URL, poseQueueCapacity: UInt32 = 4096) throws {
        var created: OpaquePointer?
        let status = configURL.path.withCString { configPath in
            calibrationURL.path.withCString { calibrationPath in
                var options = basalt_bench_create_options_t()
                options.struct_size = MemoryLayout<basalt_bench_create_options_t>.size
                options.config_path = configPath
                options.calibration_path = calibrationPath
                options.pose_queue_capacity = poseQueueCapacity
                return basalt_bench_create(&options, &created)
            }
        }
        try Self.requireOK(status, operation: "create")
        guard let created else {
            throw BasaltNativeSessionError.status(
                operation: "create-null",
                code: BASALT_BENCH_INTERNAL_ERROR
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
        basalt_bench_destroy(handle)
    }

    func submitIMU(_ sample: PairedIMUSample) throws {
        guard sample.timestampNanoseconds <= UInt64(Int64.max) else {
            throw BasaltNativeSessionError.invalidTimestamp
        }
        let status = basalt_bench_submit_imu(
            handle,
            Int64(sample.timestampNanoseconds),
            sample.acceleration.x,
            sample.acceleration.y,
            sample.acceleration.z,
            sample.gyroscope.x,
            sample.gyroscope.y,
            sample.gyroscope.z
        )
        try Self.requireOK(status, operation: "submit_imu")
    }

    func submitIMU(_ sample: EuRoCIMUSample) throws {
        let status = basalt_bench_submit_imu(
            handle,
            sample.timestampNanoseconds,
            sample.accelerationMetersPerSecondSquared.x,
            sample.accelerationMetersPerSecondSquared.y,
            sample.accelerationMetersPerSecondSquared.z,
            sample.gyroscopeRadiansPerSecond.x,
            sample.gyroscopeRadiansPerSecond.y,
            sample.gyroscopeRadiansPerSecond.z
        )
        try Self.requireOK(status, operation: "submit_imu")
    }

    func submitCamera(_ frame: MonochromeCameraFrame, acceptedNanoseconds: UInt64) throws {
        guard frame.timestampNanoseconds <= UInt64(Int64.max) else {
            throw BasaltNativeSessionError.invalidTimestamp
        }
        // Same contract as the XRSLAM arm: the plane is the bench's own copy and
        // the camera buffer was already returned to AVFoundation.
        try frame.withLumaPlane { pixels, bytesPerRow in
            try submitCamera(
                planes: [
                    NativeImagePlane(
                        pixels: pixels,
                        width: frame.width,
                        height: frame.height,
                        bytesPerRow: bytesPerRow
                    )
                ],
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
        try withNativePlanes(images: images) { planes in
            try submitCamera(
                planes: planes,
                timestampNanoseconds: timestampNanoseconds,
                acceptedNanoseconds: acceptedNanoseconds
            )
        }
    }

    func pollPose() throws -> NativePoseSample? {
        var output = basalt_bench_pose_t()
        let status = basalt_bench_poll_pose(handle, &output)
        if status == BASALT_BENCH_NO_OUTPUT || status == BASALT_BENCH_END_OF_STREAM {
            return nil
        }
        try Self.requireOK(status, operation: "poll_pose")
        guard let rotation = Quaternion.normalizedOrNil(
            w: output.quaternion_xyzw.3,
            x: output.quaternion_xyzw.0,
            y: output.quaternion_xyzw.1,
            z: output.quaternion_xyzw.2
        ) else {
            throw BasaltNativeSessionError.status(
                operation: "nonfinite_pose",
                code: BASALT_BENCH_INTERNAL_ERROR
            )
        }
        return NativePoseSample(
            pose: TimedPose(
                timestampNanoseconds: output.timestamp_ns,
                translation: Vector3(
                    x: output.translation_xyz.0,
                    y: output.translation_xyz.1,
                    z: output.translation_xyz.2
                ),
                rotation: rotation
            ),
            capturedMonotonicNanoseconds: output.camera_accepted_monotonic_ns,
            pipelineLatencyNanoseconds: output.pipeline_latency_ns
        )
    }

    func snapshot() throws -> VIOEngineSnapshot {
        var output = basalt_bench_snapshot_t()
        try Self.requireOK(
            basalt_bench_get_snapshot(handle, &output),
            operation: "snapshot"
        )
        return VIOEngineSnapshot(basalt: output)
    }

    func sealDrainStop() throws {
        try Self.requireOK(basalt_bench_seal_inputs(handle), operation: "seal")
        try Self.requireOK(basalt_bench_drain(handle), operation: "drain")
        try Self.requireOK(basalt_bench_stop(handle), operation: "stop")
    }

    func requestStop() {
        basalt_bench_request_stop_for_run(handle)
    }

    private func submitCamera(
        planes: [NativeImagePlane],
        timestampNanoseconds: Int64,
        acceptedNanoseconds: UInt64
    ) throws {
        var cPlanes = planes.map {
            basalt_bench_image_plane_t(
                pixels: $0.pixels,
                width: UInt32($0.width),
                height: UInt32($0.height),
                bytes_per_row: UInt32($0.bytesPerRow)
            )
        }
        let status = cPlanes.withUnsafeMutableBufferPointer {
            basalt_bench_submit_camera(
                handle,
                timestampNanoseconds,
                $0.baseAddress,
                $0.count,
                acceptedNanoseconds
            )
        }
        try Self.requireOK(status, operation: "submit_camera")
    }

    private static func requireOK(
        _ status: basalt_bench_status_t,
        operation: String
    ) throws {
        guard status == BASALT_BENCH_OK else {
            throw BasaltNativeSessionError.status(operation: operation, code: status)
        }
    }
}

private struct NativeImagePlane {
    let pixels: UnsafePointer<UInt8>
    let width: Int
    let height: Int
    let bytesPerRow: Int
}

private func withNativePlanes<T>(
    images: [GrayscaleImage],
    body: ([NativeImagePlane]) throws -> T
) throws -> T {
    func descend(_ index: Int, _ accumulated: [NativeImagePlane]) throws -> T {
        if index == images.count { return try body(accumulated) }
        return try images[index].pixels.withUnsafeBytes { rawBuffer in
            let pixels = rawBuffer.bindMemory(to: UInt8.self)
            return try descend(
                index + 1,
                accumulated + [
                    NativeImagePlane(
                        pixels: pixels.baseAddress!,
                        width: images[index].width,
                        height: images[index].height,
                        bytesPerRow: images[index].bytesPerRow
                    )
                ]
            )
        }
    }
    return try descend(0, [])
}
