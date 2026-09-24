import Foundation

/// Upper-bound invariants that make a cross-clock-domain subtraction impossible
/// to report as a latency.
///
/// Every timestamp the bench compares must live in one monotonic domain:
/// `mach_absolute_time` nanoseconds. Three producers feed it, and all three are
/// already in that domain once the fix of 2026-08-30 is applied:
///
/// * camera presentation timestamps, mapped from `CMClockGetHostTimeClock()`
///   through `MonotonicClockMapper`;
/// * run start, heartbeats and system samples, from
///   `DispatchTime.now().uptimeNanoseconds`;
/// * native publication timestamps, from `monotonic_now_ns()` in the engine
///   bridges, which calls `mach_absolute_time()` with the timebase applied.
///
/// The defect these invariants exist to catch: `BasaltBench.mm` used
/// `std::chrono::steady_clock`, which Darwin maps to `mach_continuous_time` and
/// which *includes* time the device spent asleep. Subtracting it from a
/// `mach_absolute_time` timestamp produced the whole sleep accumulation as a
/// constant offset. A 97 s run on a phone left idle overnight reported an
/// 81,219,463 ms P95 pipeline latency and an 81,219,577 ms first-pose latency;
/// the real first-pose latency was the 113.8 ms difference between them.
///
/// A latency can never exceed the elapsed time of the run that produced it. When
/// it does, the domains are mixed and the run is a diagnostic artifact, not a
/// measurement. It must be marked invalid rather than clamped, truncated, or
/// scored: clamping to zero would have hidden this defect behind a plausible
/// number instead of an absurd one.
enum ClockDomainInvariant {
    /// Allowance for dispatch between the moment a latency is stamped and the
    /// moment run elapsed is sampled. Generous enough that no scheduling delay
    /// trips it, and roughly nine orders of magnitude below a sleep offset.
    static let schedulingSlackNanoseconds: UInt64 = 250_000_000

    enum Violation: Equatable {
        case latencyExceedsElapsed(
            label: String,
            latencyNanoseconds: UInt64,
            elapsedNanoseconds: UInt64
        )

        var reason: String {
            switch self {
            case .latencyExceedsElapsed(let label, _, _):
                return "clock_domain_mismatch_\(label)"
            }
        }
    }

    /// Returns a violation when `latencyNanoseconds` cannot have been produced
    /// inside a run that has been going for `elapsedNanoseconds`.
    static func check(
        label: String,
        latencyNanoseconds: UInt64,
        elapsedNanoseconds: UInt64
    ) -> Violation? {
        let (bound, overflow) = elapsedNanoseconds
            .addingReportingOverflow(schedulingSlackNanoseconds)
        // An elapsed time within 250 ms of UInt64.max is itself nonsense, but the
        // saturating bound keeps this check total rather than trapping.
        let ceiling = overflow ? UInt64.max : bound
        guard latencyNanoseconds > ceiling else { return nil }
        return .latencyExceedsElapsed(
            label: label,
            latencyNanoseconds: latencyNanoseconds,
            elapsedNanoseconds: elapsedNanoseconds
        )
    }

    /// Convenience for the millisecond-valued metrics the coordinator carries.
    static func check(
        label: String,
        latencyMilliseconds: Double,
        elapsedNanoseconds: UInt64
    ) -> Violation? {
        guard latencyMilliseconds.isFinite, latencyMilliseconds >= 0 else {
            return .latencyExceedsElapsed(
                label: label,
                latencyNanoseconds: UInt64.max,
                elapsedNanoseconds: elapsedNanoseconds
            )
        }
        let nanoseconds = latencyMilliseconds * 1_000_000
        guard nanoseconds < Double(UInt64.max) else {
            return .latencyExceedsElapsed(
                label: label,
                latencyNanoseconds: UInt64.max,
                elapsedNanoseconds: elapsedNanoseconds
            )
        }
        return check(
            label: label,
            latencyNanoseconds: UInt64(nanoseconds.rounded(.toNearestOrAwayFromZero)),
            elapsedNanoseconds: elapsedNanoseconds
        )
    }
}
