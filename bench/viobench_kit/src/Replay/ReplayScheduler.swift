import Foundation

enum ReplaySchedulerMode: String, Codable, Sendable {
    case paced
    case maximumThroughput = "max"
}

protocol ReplayClock: AnyObject {
    func nowNanoseconds() -> UInt64
    func sleep(untilNanoseconds deadline: UInt64) throws
}

final class MonotonicReplayClock: ReplayClock {
    func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    func sleep(untilNanoseconds deadline: UInt64) throws {
        while true {
            let now = nowNanoseconds()
            guard now < deadline else { return }
            Thread.sleep(forTimeInterval: Double(deadline - now) / 1_000_000_000.0)
        }
    }
}

enum ReplaySchedulerError: Error, Equatable {
    case timestampRegression(previous: Int64, current: Int64)
    case deadlineOverflow
}

struct ReplayScheduler {
    let mode: ReplaySchedulerMode

    func run(
        events: [ReplayEvent],
        clock: ReplayClock = MonotonicReplayClock(),
        deliver: (ReplayEvent) throws -> Void
    ) throws {
        try validateOrder(events)
        guard mode == .paced, let first = events.first else {
            for event in events { try deliver(event) }
            return
        }

        let wallStart = clock.nowNanoseconds()
        try deliver(first)
        for event in events.dropFirst() {
            let datasetOffset = event.timestampNanoseconds - first.timestampNanoseconds
            guard datasetOffset >= 0,
                  let offset = UInt64(exactly: datasetOffset),
                  wallStart <= UInt64.max - offset else {
                throw ReplaySchedulerError.deadlineOverflow
            }
            try clock.sleep(untilNanoseconds: wallStart + offset)
            try deliver(event)
        }
    }

    private func validateOrder(_ events: [ReplayEvent]) throws {
        for (previous, current) in zip(events, events.dropFirst()) where current.timestampNanoseconds < previous.timestampNanoseconds {
            throw ReplaySchedulerError.timestampRegression(
                previous: previous.timestampNanoseconds,
                current: current.timestampNanoseconds
            )
        }
    }
}
