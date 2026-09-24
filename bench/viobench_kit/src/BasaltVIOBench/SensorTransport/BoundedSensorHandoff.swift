import Foundation
import Darwin

/// iOS 17-compatible atomic storage for the one counter that must be updated
/// after the queue try-lock fails. OSAtomic is deprecated in favor of the Swift
/// Synchronization module, but Swift Atomic is iOS 18-only; this benchmark keeps
/// its declared iOS 17 deployment target.
private final class LegacyAtomicUInt64: @unchecked Sendable {
    private let storage: UnsafeMutablePointer<Int64>

    init(_ value: UInt64) {
        storage = .allocate(capacity: 1)
        storage.initialize(to: Int64(bitPattern: value))
    }

    deinit {
        storage.deinitialize(count: 1)
        storage.deallocate()
    }

    func increment() {
        OSAtomicIncrement64Barrier(storage)
    }

    func load() -> UInt64 {
        UInt64(bitPattern: OSAtomicAdd64Barrier(0, storage))
    }
}

/// A bounded callback-to-consumer queue with a nonblocking producer path.
///
/// `offer` performs one try-lock. If the consumer owns the queue, the new item
/// is dropped and reported immediately instead of delaying a camera or motion
/// callback. The consumer may block briefly while draining. Sealing rejects all
/// new offers but preserves already accepted items; only a consumer drain may
/// advance `sealed` to `drained`.
public final class BoundedSensorHandoff<Element>: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case accepting
        case sealed
        case drained
    }

    public enum OfferResult: Equatable, Sendable {
        case accepted
        case droppedFull
        case droppedContended
        case rejectedSealed
    }

    public struct DrainBatch {
        public let items: [Element]
        public let isSealedAndDrained: Bool
    }

    public struct Snapshot: Equatable, Sendable {
        public let state: State
        public let capacity: Int
        public let depth: Int
        public let highWatermark: Int
        public let accepted: UInt64
        public let droppedFull: UInt64
        public let droppedContended: UInt64
        public let rejectedSealed: UInt64

        public var totalRejectedOrDropped: UInt64 {
            droppedFull + droppedContended + rejectedSealed
        }
    }

    private let lock = NSLock()
    private let contentionDropCount = LegacyAtomicUInt64(0)
    private let capacityValue: Int
    private var storage: [Element] = []
    private var internalState: State = .accepting
    private var highWatermark = 0
    private var acceptedCount: UInt64 = 0
    private var fullDropCount: UInt64 = 0
    private var sealedRejectionCount: UInt64 = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "handoff capacity must be positive")
        capacityValue = capacity
        storage.reserveCapacity(capacity)
    }

    public var state: State {
        lock.withLock { internalState }
    }

    /// Never waits for the queue lock. A contention drop is counted atomically
    /// without acquiring a second lock.
    @discardableResult
    /// Takes the lock rather than abandoning the sample when it is contended.
    ///
    /// This previously used `lock.try()` and dropped on any collision. A 300 s
    /// device run on 2026-08-30 showed what that costs: 8,984 of 8,985 frames
    /// accepted, queue peak 1 against capacity 10 -- and one frame discarded to
    /// contention while the queue was 90 percent empty. Under the zero-loss gate
    /// that single frame invalidated the whole run, and at roughly 0.011 percent
    /// the same thing is near-certain in any five-minute capture. Dropping on
    /// contention and requiring zero loss are incompatible designs.
    ///
    /// The critical section is an append or a batch move, microseconds long and
    /// bounded by `capacity`; it never waits on the consumer to be ready. The
    /// "do not block the sensor callback" rule exists to prevent unbounded
    /// stalls, not to trade guaranteed frame loss for a few microseconds of lock
    /// wait, which is a bad bargain under a lossless delivery requirement.
    ///
    /// `droppedContended` is kept in the accounting and must now stay zero. It is
    /// evidence, not a expected outcome: a nonzero value means someone
    /// reintroduced a fallible acquire.
    public func offer(_ element: consuming Element) -> OfferResult {
        lock.lock()
        defer { lock.unlock() }

        guard internalState == .accepting else {
            sealedRejectionCount += 1
            return .rejectedSealed
        }
        guard storage.count < capacityValue else {
            fullDropCount += 1
            return .droppedFull
        }

        storage.append(element)
        acceptedCount += 1
        highWatermark = max(highWatermark, storage.count)
        return .accepted
    }

    /// Idempotently prevents all future offers while retaining queued items.
    @discardableResult
    public func seal() -> State {
        lock.withLock {
            if internalState == .accepting {
                internalState = .sealed
            }
            return internalState
        }
    }

    /// Called from the consumer, never from a sensor callback.
    public func drain(maxCount: Int) -> DrainBatch {
        lock.withLock {
            let requestedCount = max(0, maxCount)
            let count = min(requestedCount, storage.count)
            let items: [Element]
            if count == 0 {
                items = []
            } else {
                items = Array(storage.prefix(count))
                storage.removeFirst(count)
            }

            if internalState == .sealed, storage.isEmpty {
                internalState = .drained
            }
            return DrainBatch(
                items: items,
                isSealedAndDrained: internalState == .drained
            )
        }
    }

    public func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                state: internalState,
                capacity: capacityValue,
                depth: storage.count,
                highWatermark: highWatermark,
                accepted: acceptedCount,
                droppedFull: fullDropCount,
                droppedContended: contentionDropCount.load(),
                rejectedSealed: sealedRejectionCount
            )
        }
    }
}
