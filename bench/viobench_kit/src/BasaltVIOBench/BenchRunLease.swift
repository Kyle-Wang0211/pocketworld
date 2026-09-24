import Foundation

struct BenchRunExclusivityReceipt: Equatable, Sendable {
    let selectedArm: String
    let acquiredNanoseconds: UInt64
    let releasedNanoseconds: UInt64?
    let maxSimultaneousActiveArms: UInt64
    let overlapDurationNanoseconds: UInt64
    let engineSessionActive: Bool
    let arSessionActive: Bool
    let avFoundationTransportActive: Bool
}

enum BenchRunLeaseActivityError: Error, Equatable {
    case wrongActivityForSelectedArm
    case activityAlreadyRecorded
}

/// Process-wide ownership boundary. UI state is not trusted to enforce sensor
/// exclusivity; every coordinator must acquire this lease before preparation.
enum BenchRunLease {
    private static let lock = NSLock()
    private static var ownerID: UUID?

    final class Token: @unchecked Sendable {
        fileprivate let ownerID: UUID
        fileprivate let backend: BenchBackend
        fileprivate let acquiredNanoseconds: UInt64
        private let lock = NSLock()
        private var finalReceipt: BenchRunExclusivityReceipt?
        private var engineSessionWasActive = false
        private var arSessionWasActive = false
        private var avFoundationTransportWasActive = false

        fileprivate init(
            ownerID: UUID,
            backend: BenchBackend,
            acquiredNanoseconds: UInt64
        ) {
            self.ownerID = ownerID
            self.backend = backend
            self.acquiredNanoseconds = acquiredNanoseconds
        }

        func snapshot() -> BenchRunExclusivityReceipt {
            lock.withLock {
                finalReceipt ?? makeReceipt(releasedNanoseconds: nil)
            }
        }

        func recordEngineSessionStarted() throws {
            try lock.withLock {
                guard backend != .arkit else {
                    throw BenchRunLeaseActivityError.wrongActivityForSelectedArm
                }
                guard !engineSessionWasActive else {
                    throw BenchRunLeaseActivityError.activityAlreadyRecorded
                }
                engineSessionWasActive = true
            }
        }

        func recordARSessionStarted() throws {
            try lock.withLock {
                guard backend == .arkit,
                      !engineSessionWasActive,
                      !avFoundationTransportWasActive else {
                    throw BenchRunLeaseActivityError.wrongActivityForSelectedArm
                }
                guard !arSessionWasActive else {
                    throw BenchRunLeaseActivityError.activityAlreadyRecorded
                }
                arSessionWasActive = true
            }
        }

        func recordAVFoundationTransportStarted() throws {
            try lock.withLock {
                guard backend != .arkit, !arSessionWasActive else {
                    throw BenchRunLeaseActivityError.wrongActivityForSelectedArm
                }
                guard !avFoundationTransportWasActive else {
                    throw BenchRunLeaseActivityError.activityAlreadyRecorded
                }
                avFoundationTransportWasActive = true
            }
        }

        @discardableResult
        func release() -> BenchRunExclusivityReceipt {
            lock.withLock {
                if let finalReceipt { return finalReceipt }
                let released = DispatchTime.now().uptimeNanoseconds
                BenchRunLease.release(ownerID: ownerID)
                let receipt = makeReceipt(releasedNanoseconds: released)
                finalReceipt = receipt
                return receipt
            }
        }

        private func makeReceipt(
            releasedNanoseconds: UInt64?
        ) -> BenchRunExclusivityReceipt {
            BenchRunExclusivityReceipt(
                selectedArm: backend.id,
                acquiredNanoseconds: acquiredNanoseconds,
                releasedNanoseconds: releasedNanoseconds,
                maxSimultaneousActiveArms: 1,
                overlapDurationNanoseconds: 0,
                engineSessionActive: engineSessionWasActive,
                arSessionActive: arSessionWasActive,
                avFoundationTransportActive: avFoundationTransportWasActive
            )
        }
    }

    static func acquire(backend: BenchBackend) -> Token? {
        lock.withLock {
            guard ownerID == nil else { return nil }
            let id = UUID()
            ownerID = id
            return Token(
                ownerID: id,
                backend: backend,
                acquiredNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
        }
    }

    private static func release(ownerID expected: UUID) {
        lock.withLock {
            if ownerID == expected { ownerID = nil }
        }
    }

    static func forceResetForTesting() {
        lock.withLock { ownerID = nil }
    }
}
