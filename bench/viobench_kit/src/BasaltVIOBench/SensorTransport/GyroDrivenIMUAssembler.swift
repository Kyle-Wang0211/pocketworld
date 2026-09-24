import Foundation

/// The paired sample accepted by `basalt_bench_submit_imu`: time and gyro come
/// from the gyroscope event; acceleration is linearly interpolated between the
/// adjacent accelerometer events. Values are SI (rad/s and m/s^2) and remain in
/// the Core Motion device coordinate frame. Before estimator submission, the
/// consumer must prove that the selected calibration's IMU frame is this frame,
/// or apply its declared device-to-IMU transform. This transport does not infer
/// a frame transform from phone model or orientation.
public struct PairedIMUSample: Equatable, Sendable {
    public let timestampNanoseconds: UInt64
    public let gyroscope: MotionVectorSample
    public let acceleration: MotionVectorSample
    public let accelerationLowerTimestampNanoseconds: UInt64
    public let accelerationUpperTimestampNanoseconds: UInt64
}

public enum IMUAssemblyViolation: Equatable, Sendable {
    case gyroscopeTimestampRegression(previous: UInt64, received: UInt64)
    case accelerationTimestampRegression(previous: UInt64, received: UInt64)
    case outputTimestampRegression(previous: UInt64, received: UInt64)
    case pendingGyroscopeOverflow(capacity: Int)
    case inputSealed
}

public struct IMUAssemblyBatch: Equatable, Sendable {
    public let samples: [PairedIMUSample]
    public let unbracketedGyroscopeDrops: UInt64
    public let violation: IMUAssemblyViolation?
}

public struct IMUAssemblyReceipt: Equatable, Sendable {
    public let state: IMUAssemblyState
    public let gyroscopeInputs: UInt64
    public let accelerationInputs: UInt64
    public let pairedOutputs: UInt64
    public let unbracketedGyroscopeDrops: UInt64
    public let pendingGyroscopeOverflowDrops: UInt64
    public let sealedPendingGyroscopeDrops: UInt64
    public let sealedInputRejections: UInt64
    public let gyroscopeTimestampRegressions: UInt64
    public let accelerationTimestampRegressions: UInt64
    public let outputTimestampRegressions: UInt64
    public let pendingGyroscopeDepth: Int
    public let pendingGyroscopeHighWatermark: Int

    /// Losses that indicate a broken live transport. The first gyroscopes
    /// before an acceleration bracket and the final gyroscopes left at seal
    /// are expected boundary effects of Basalt's upstream gyro-driven
    /// interpolation rule; they remain receipted but do not invalidate a run.
    public var integrityLossCount: UInt64 {
        pendingGyroscopeOverflowDrops
            + sealedInputRejections
            + gyroscopeTimestampRegressions
            + accelerationTimestampRegressions
            + outputTimestampRegressions
    }
}

public enum IMUAssemblyState: Equatable, Sendable {
    case accepting
    case sealed
}

/// Reproduces the official Basalt RST265 transport rule in
/// `src/device/rs_t265.cpp`: gyro samples are queued; on each strictly newer
/// acceleration sample, gyros before the previous acceleration are skipped and
/// gyros strictly before the new acceleration are emitted with linearly
/// interpolated acceleration. A gyro exactly at the upper acceleration boundary
/// remains queued for the next interval, matching the upstream `<` condition.
///
/// This is transport adaptation, not an estimator policy. Feed both Core Motion
/// callbacks through one serial queue, then submit only the paired output to the
/// native Basalt bridge.
public struct GyroDrivenIMUAssembler: Sendable {
    private struct Counters: Sendable {
        var gyroscopeInputs: UInt64 = 0
        var accelerationInputs: UInt64 = 0
        var pairedOutputs: UInt64 = 0
        var unbracketedGyroscopeDrops: UInt64 = 0
        var pendingGyroscopeOverflowDrops: UInt64 = 0
        var sealedPendingGyroscopeDrops: UInt64 = 0
        var sealedInputRejections: UInt64 = 0
        var gyroscopeTimestampRegressions: UInt64 = 0
        var accelerationTimestampRegressions: UInt64 = 0
        var outputTimestampRegressions: UInt64 = 0
        var pendingGyroscopeHighWatermark: Int = 0
    }

    public let pendingGyroscopeCapacity: Int
    private var previousAcceleration: MotionVectorSample?
    private var pendingGyroscopes: [MotionVectorSample] = []
    private var lastGyroscopeInputTimestamp: UInt64?
    private var lastOutputTimestamp: UInt64?
    private var counters = Counters()
    private var state: IMUAssemblyState = .accepting

    public init(pendingGyroscopeCapacity: Int) {
        precondition(pendingGyroscopeCapacity > 0)
        self.pendingGyroscopeCapacity = pendingGyroscopeCapacity
        pendingGyroscopes.reserveCapacity(pendingGyroscopeCapacity)
    }

    public var receipt: IMUAssemblyReceipt {
        IMUAssemblyReceipt(
            state: state,
            gyroscopeInputs: counters.gyroscopeInputs,
            accelerationInputs: counters.accelerationInputs,
            pairedOutputs: counters.pairedOutputs,
            unbracketedGyroscopeDrops: counters.unbracketedGyroscopeDrops,
            pendingGyroscopeOverflowDrops: counters.pendingGyroscopeOverflowDrops,
            sealedPendingGyroscopeDrops: counters.sealedPendingGyroscopeDrops,
            sealedInputRejections: counters.sealedInputRejections,
            gyroscopeTimestampRegressions: counters.gyroscopeTimestampRegressions,
            accelerationTimestampRegressions: counters.accelerationTimestampRegressions,
            outputTimestampRegressions: counters.outputTimestampRegressions,
            pendingGyroscopeDepth: pendingGyroscopes.count,
            pendingGyroscopeHighWatermark: counters.pendingGyroscopeHighWatermark
        )
    }

    public mutating func ingestGyroscope(_ sample: MotionVectorSample) -> IMUAssemblyBatch {
        guard state == .accepting else {
            counters.sealedInputRejections += 1
            return IMUAssemblyBatch(
                samples: [],
                unbracketedGyroscopeDrops: 0,
                violation: .inputSealed
            )
        }
        counters.gyroscopeInputs += 1
        if let previous = lastGyroscopeInputTimestamp,
           sample.timestampNanoseconds <= previous {
            counters.gyroscopeTimestampRegressions += 1
            return IMUAssemblyBatch(
                samples: [],
                unbracketedGyroscopeDrops: 0,
                violation: .gyroscopeTimestampRegression(
                    previous: previous,
                    received: sample.timestampNanoseconds
                )
            )
        }
        lastGyroscopeInputTimestamp = sample.timestampNanoseconds

        guard pendingGyroscopes.count < pendingGyroscopeCapacity else {
            counters.pendingGyroscopeOverflowDrops += 1
            return IMUAssemblyBatch(
                samples: [],
                unbracketedGyroscopeDrops: 0,
                violation: .pendingGyroscopeOverflow(capacity: pendingGyroscopeCapacity)
            )
        }

        pendingGyroscopes.append(sample)
        counters.pendingGyroscopeHighWatermark = max(
            counters.pendingGyroscopeHighWatermark,
            pendingGyroscopes.count
        )
        return IMUAssemblyBatch(
            samples: [],
            unbracketedGyroscopeDrops: 0,
            violation: nil
        )
    }

    public mutating func ingestAcceleration(_ sample: MotionVectorSample) -> IMUAssemblyBatch {
        guard state == .accepting else {
            counters.sealedInputRejections += 1
            return IMUAssemblyBatch(
                samples: [],
                unbracketedGyroscopeDrops: 0,
                violation: .inputSealed
            )
        }
        counters.accelerationInputs += 1
        guard let lower = previousAcceleration else {
            previousAcceleration = sample
            return IMUAssemblyBatch(
                samples: [],
                unbracketedGyroscopeDrops: 0,
                violation: nil
            )
        }
        guard sample.timestampNanoseconds > lower.timestampNanoseconds else {
            counters.accelerationTimestampRegressions += 1
            return IMUAssemblyBatch(
                samples: [],
                unbracketedGyroscopeDrops: 0,
                violation: .accelerationTimestampRegression(
                    previous: lower.timestampNanoseconds,
                    received: sample.timestampNanoseconds
                )
            )
        }

        var skipped: UInt64 = 0
        while let gyro = pendingGyroscopes.first,
              gyro.timestampNanoseconds < lower.timestampNanoseconds {
            pendingGyroscopes.removeFirst()
            skipped += 1
        }
        counters.unbracketedGyroscopeDrops += skipped

        var output: [PairedIMUSample] = []
        while let gyro = pendingGyroscopes.first,
              gyro.timestampNanoseconds < sample.timestampNanoseconds {
            pendingGyroscopes.removeFirst()
            if let previousOutput = lastOutputTimestamp,
               gyro.timestampNanoseconds <= previousOutput {
                counters.outputTimestampRegressions += 1
                return IMUAssemblyBatch(
                    samples: output,
                    unbracketedGyroscopeDrops: skipped,
                    violation: .outputTimestampRegression(
                        previous: previousOutput,
                        received: gyro.timestampNanoseconds
                    )
                )
            }
            output.append(Self.pair(gyro: gyro, lower: lower, upper: sample))
            lastOutputTimestamp = gyro.timestampNanoseconds
        }

        previousAcceleration = sample
        counters.pairedOutputs += UInt64(output.count)
        return IMUAssemblyBatch(
            samples: output,
            unbracketedGyroscopeDrops: skipped,
            violation: nil
        )
    }

    /// Sealing cannot synthesize a future acceleration bracket. It therefore
    /// receipts and discards every still-pending gyro before the downstream IMU
    /// handoff is sealed. The operation is idempotent.
    @discardableResult
    public mutating func seal() -> IMUAssemblyState {
        guard state == .accepting else { return state }
        state = .sealed
        counters.sealedPendingGyroscopeDrops += UInt64(pendingGyroscopes.count)
        pendingGyroscopes.removeAll(keepingCapacity: false)
        return state
    }

    private static func pair(
        gyro: MotionVectorSample,
        lower: MotionVectorSample,
        upper: MotionVectorSample
    ) -> PairedIMUSample {
        let interval = Double(upper.timestampNanoseconds - lower.timestampNanoseconds)
        let upperWeight =
            Double(gyro.timestampNanoseconds - lower.timestampNanoseconds) / interval
        let lowerWeight = 1.0 - upperWeight
        let acceleration = MotionVectorSample(
            timestampNanoseconds: gyro.timestampNanoseconds,
            x: lowerWeight * lower.x + upperWeight * upper.x,
            y: lowerWeight * lower.y + upperWeight * upper.y,
            z: lowerWeight * lower.z + upperWeight * upper.z
        )
        return PairedIMUSample(
            timestampNanoseconds: gyro.timestampNanoseconds,
            gyroscope: gyro,
            acceleration: acceleration,
            accelerationLowerTimestampNanoseconds: lower.timestampNanoseconds,
            accelerationUpperTimestampNanoseconds: upper.timestampNanoseconds
        )
    }
}
