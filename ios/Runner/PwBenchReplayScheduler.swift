// PwBenchReplayScheduler.swift —— 台架回放的节拍器。
//
// 只进台架(arloopbench)。生产 Runner.xcodeproj 不编它。
//
// [port] **逐字照抄**我们自己的 BasaltVIOBench:
//   研究仓 worktree basalt-vio-phone-bench-20260829 @ fbe30567
//   tools/ios_basalt_vio_bench/Replay/ReplayScheduler.swift:1-68
// 一个字符都没改(连 `.paced` 的绝对时刻算法:以第一条事件的墙钟为零点、
// 每条事件的截止时刻 = 零点 + 数据集时间差,不累积漂移)。它在源里驱动
// EuRoC 与设备录制两条回放通道;在这里驱动设备录制一条。
// 源的单测(BasaltVIOBenchTests/ReplayTests/ReplaySchedulerTests.swift)一并搬到
// tool/bench/replay_swift_tests/,在 Mac 上跑。

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
