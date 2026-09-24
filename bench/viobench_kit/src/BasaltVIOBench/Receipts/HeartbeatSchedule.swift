import Foundation

struct HeartbeatSchedule {
    private let intervalNanoseconds: UInt64
    private var nextSequence = 0
    private var nextDeadlineNanoseconds: UInt64?

    init(
        intervalNanoseconds: UInt64,
        startingSequence: Int = 0,
        firstDeadlineNanoseconds: UInt64? = nil
    ) {
        precondition(intervalNanoseconds > 0)
        precondition(startingSequence >= 0)
        self.intervalNanoseconds = intervalNanoseconds
        nextSequence = startingSequence
        nextDeadlineNanoseconds = firstDeadlineNanoseconds
    }

    mutating func consumeSequenceIfDue(nowNanoseconds: UInt64) -> Int? {
        if let deadline = nextDeadlineNanoseconds, nowNanoseconds < deadline { return nil }
        let sequence = nextSequence
        nextSequence += 1
        nextDeadlineNanoseconds = nowNanoseconds &+ intervalNanoseconds
        return sequence
    }
}
