import Foundation

public struct SensorTransportLifecycle: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case starting
        case running
        case interrupted
        case failed
        case stopping
        case sealed
        case drained
    }

    public enum TransitionError: Error, Equatable {
        case invalid(from: State, to: State)
    }

    public private(set) var state: State = .idle

    public init() {}

    public mutating func transition(to next: State) throws {
        guard Self.isAllowed(from: state, to: next) else {
            throw TransitionError.invalid(from: state, to: next)
        }
        state = next
    }

    private static func isAllowed(from current: State, to next: State) -> Bool {
        switch (current, next) {
        case (.idle, .starting),
             (.starting, .running),
             (.starting, .failed),
             (.starting, .stopping),
             (.running, .interrupted),
             (.running, .failed),
             (.running, .stopping),
             (.interrupted, .running),
             (.interrupted, .failed),
             (.interrupted, .stopping),
             (.failed, .stopping),
             (.stopping, .sealed),
             (.sealed, .drained):
            true
        default:
            false
        }
    }
}
