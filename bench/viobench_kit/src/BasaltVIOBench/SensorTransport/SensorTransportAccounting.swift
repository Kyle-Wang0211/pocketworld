import Foundation

public enum CameraDropReason: Equatable, Sendable {
    case late
    case outOfBuffers
    case discontinuity
    case invalidFormat
    case invalidTimestamp
    case timestampRegression
    case unknown
}

public struct SensorTransportAccountingSnapshot: Equatable, Sendable {
    public let cameraInputs: UInt64
    public let gyroscopeInputs: UInt64
    public let accelerometerInputs: UInt64
    public let cameraDropsLate: UInt64
    public let cameraDropsOutOfBuffers: UInt64
    public let cameraDropsDiscontinuity: UInt64
    public let cameraDropsInvalidFormat: UInt64
    public let cameraDropsInvalidTimestamp: UInt64
    public let cameraDropsTimestampRegression: UInt64
    public let cameraDropsUnknown: UInt64
    public let timestampRegressions: UInt64
    public let motionErrors: UInt64
    public let captureInterruptions: UInt64
    public let captureRuntimeErrors: UInt64

    public var totalCameraDrops: UInt64 {
        cameraDropsLate
            + cameraDropsOutOfBuffers
            + cameraDropsDiscontinuity
            + cameraDropsInvalidFormat
            + cameraDropsInvalidTimestamp
            + cameraDropsTimestampRegression
            + cameraDropsUnknown
    }
}

/// Exact input and platform-drop counters. Handoff admission counters live on
/// each `BoundedSensorHandoff` so snapshots can distinguish platform loss
/// from application queue pressure.
public final class SensorTransportAccounting: @unchecked Sendable {
    private struct Counters {
        var cameraInputs: UInt64 = 0
        var gyroscopeInputs: UInt64 = 0
        var accelerometerInputs: UInt64 = 0
        var cameraDropsLate: UInt64 = 0
        var cameraDropsOutOfBuffers: UInt64 = 0
        var cameraDropsDiscontinuity: UInt64 = 0
        var cameraDropsInvalidFormat: UInt64 = 0
        var cameraDropsInvalidTimestamp: UInt64 = 0
        var cameraDropsTimestampRegression: UInt64 = 0
        var cameraDropsUnknown: UInt64 = 0
        var timestampRegressions: UInt64 = 0
        var motionErrors: UInt64 = 0
        var captureInterruptions: UInt64 = 0
        var captureRuntimeErrors: UInt64 = 0
    }

    private let lock = NSLock()
    private var counters = Counters()

    public init() {}

    public func recordCameraInput() {
        lock.withLock { counters.cameraInputs += 1 }
    }

    public func recordGyroscopeInput() {
        lock.withLock { counters.gyroscopeInputs += 1 }
    }

    public func recordAccelerometerInput() {
        lock.withLock { counters.accelerometerInputs += 1 }
    }

    public func recordCameraDrop(_ reason: CameraDropReason) {
        lock.withLock {
            switch reason {
            case .late:
                counters.cameraDropsLate += 1
            case .outOfBuffers:
                counters.cameraDropsOutOfBuffers += 1
            case .discontinuity:
                counters.cameraDropsDiscontinuity += 1
            case .invalidFormat:
                counters.cameraDropsInvalidFormat += 1
            case .invalidTimestamp:
                counters.cameraDropsInvalidTimestamp += 1
            case .timestampRegression:
                counters.cameraDropsTimestampRegression += 1
                counters.timestampRegressions += 1
            case .unknown:
                counters.cameraDropsUnknown += 1
            }
        }
    }

    public func recordTimestampRegression() {
        lock.withLock { counters.timestampRegressions += 1 }
    }

    public func recordMotionError() {
        lock.withLock { counters.motionErrors += 1 }
    }

    public func recordCaptureInterruption() {
        lock.withLock { counters.captureInterruptions += 1 }
    }

    public func recordCaptureRuntimeError() {
        lock.withLock { counters.captureRuntimeErrors += 1 }
    }

    public func snapshot() -> SensorTransportAccountingSnapshot {
        lock.withLock {
            SensorTransportAccountingSnapshot(
                cameraInputs: counters.cameraInputs,
                gyroscopeInputs: counters.gyroscopeInputs,
                accelerometerInputs: counters.accelerometerInputs,
                cameraDropsLate: counters.cameraDropsLate,
                cameraDropsOutOfBuffers: counters.cameraDropsOutOfBuffers,
                cameraDropsDiscontinuity: counters.cameraDropsDiscontinuity,
                cameraDropsInvalidFormat: counters.cameraDropsInvalidFormat,
                cameraDropsInvalidTimestamp: counters.cameraDropsInvalidTimestamp,
                cameraDropsTimestampRegression: counters.cameraDropsTimestampRegression,
                cameraDropsUnknown: counters.cameraDropsUnknown,
                timestampRegressions: counters.timestampRegressions,
                motionErrors: counters.motionErrors,
                captureInterruptions: counters.captureInterruptions,
                captureRuntimeErrors: counters.captureRuntimeErrors
            )
        }
    }
}
