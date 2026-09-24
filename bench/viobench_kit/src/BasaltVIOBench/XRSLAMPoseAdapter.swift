import Foundation

enum XRSLAMPoseAdapter {
    static func makeTimedPose(
        timestampNanoseconds: Int64,
        translationX: Double,
        translationY: Double,
        translationZ: Double,
        quaternionX: Double,
        quaternionY: Double,
        quaternionZ: Double,
        quaternionW: Double
    ) -> TimedPose? {
        guard let rotation = Quaternion.normalizedOrNil(
            w: quaternionW,
            x: quaternionX,
            y: quaternionY,
            z: quaternionZ
        ) else {
            return nil
        }
        // Frozen upstream 4beb1a9 BODY_POSE is the body/IMU pose used by the
        // official PC trajectory writer. Basalt and EuRoC ground truth use the
        // same frame; display-only SceneKit camera remapping is absent here.
        return TimedPose(
            timestampNanoseconds: timestampNanoseconds,
            translation: Vector3(
                x: translationX,
                y: translationY,
                z: translationZ
            ),
            rotation: rotation
        )
    }
}

enum XRSLAMReplaySensorEvent: Equatable {
    case gyroscope(MotionVectorSample)
    case acceleration(MotionVectorSample)
}

enum XRSLAMReplayIMUAdapter {
    /// Pinned 4beb EuRoC reader inserts gyro before acceleration for equal
    /// timestamps, then stable-sorts the merged stream. Preserve that order.
    static func orderedEvents(_ sample: EuRoCIMUSample) -> [XRSLAMReplaySensorEvent] {
        let timestamp = UInt64(sample.timestampNanoseconds)
        let gyro = sample.gyroscopeRadiansPerSecond
        let acceleration = sample.accelerationMetersPerSecondSquared
        return [
            .gyroscope(MotionVectorSample(
                timestampNanoseconds: timestamp,
                x: gyro.x,
                y: gyro.y,
                z: gyro.z
            )),
            .acceleration(MotionVectorSample(
                timestampNanoseconds: timestamp,
                x: acceleration.x,
                y: acceleration.y,
                z: acceleration.z
            )),
        ]
    }
}
