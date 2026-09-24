import Foundation

/// Maps every sensor timestamp into one process-independent monotonic domain.
///
/// The canonical domain is nanoseconds on the Core Media host clock. Camera
/// presentation timestamps are offsets from a sampled host-clock anchor. Core
/// Motion timestamps are seconds since boot, so they are translated through a
/// `ProcessInfo.systemUptime` sample taken at the same anchor. Wall clock time is
/// never consulted, and the mapper never rewrites a timestamp to hide a
/// regression.
public struct MonotonicClockMapper: Sendable {
    public enum MappingError: Error, Equatable {
        case invalidAnchor
        case invalidTimestamp
        case outOfRange
    }

    private static let nanosecondsPerSecond = 1_000_000_000.0

    public let cameraHostTimeAnchorSeconds: Double
    public let coreMotionUptimeAnchorSeconds: Double
    public let monotonicAnchorNanoseconds: UInt64

    public init(
        cameraHostTimeAnchorSeconds: Double,
        coreMotionUptimeAnchorSeconds: Double,
        monotonicAnchorNanoseconds: UInt64
    ) {
        self.cameraHostTimeAnchorSeconds = cameraHostTimeAnchorSeconds
        self.coreMotionUptimeAnchorSeconds = coreMotionUptimeAnchorSeconds
        self.monotonicAnchorNanoseconds = monotonicAnchorNanoseconds
    }

    public func cameraNanoseconds(hostTimeSeconds: Double) throws -> UInt64 {
        try map(
            sourceSeconds: hostTimeSeconds,
            sourceAnchorSeconds: cameraHostTimeAnchorSeconds
        )
    }

    public func motionNanoseconds(uptimeSeconds: Double) throws -> UInt64 {
        try map(
            sourceSeconds: uptimeSeconds,
            sourceAnchorSeconds: coreMotionUptimeAnchorSeconds
        )
    }

    private func map(sourceSeconds: Double, sourceAnchorSeconds: Double) throws -> UInt64 {
        guard sourceAnchorSeconds.isFinite, sourceAnchorSeconds >= 0 else {
            throw MappingError.invalidAnchor
        }
        guard sourceSeconds.isFinite, sourceSeconds >= 0 else {
            throw MappingError.invalidTimestamp
        }

        let deltaNanoseconds =
            (sourceSeconds - sourceAnchorSeconds) * Self.nanosecondsPerSecond
        let mapped = Double(monotonicAnchorNanoseconds) + deltaNanoseconds

        // Double(UInt64.max) rounds up to 2^64, which UInt64 cannot represent.
        guard mapped.isFinite, mapped >= 0, mapped < Double(UInt64.max) else {
            throw MappingError.outOfRange
        }
        return UInt64(mapped.rounded(.toNearestOrAwayFromZero))
    }
}

public struct TimestampSequenceValidator: Sendable {
    public enum Observation: Equatable, Sendable {
        case accepted
        case regression(previous: UInt64, received: UInt64)
    }

    public private(set) var lastAcceptedTimestamp: UInt64?
    public private(set) var regressionCount: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func observe(_ timestamp: UInt64) -> Observation {
        if let previous = lastAcceptedTimestamp, timestamp <= previous {
            regressionCount += 1
            return .regression(previous: previous, received: timestamp)
        }
        lastAcceptedTimestamp = timestamp
        return .accepted
    }
}
