import Foundation

enum Statistics {
    /// Nearest-rank percentile over the complete run sample. The caller must not
    /// feed UI-decimated data here.
    static func nearestRankPercentile(_ values: [Double], percentile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let bounded = min(1, max(0, percentile))
        let rank = max(1, Int(ceil(bounded * Double(sorted.count))))
        return sorted[rank - 1]
    }

    /// Integrates the complete fixed measurement window. The last sample at or
    /// before `start` seeds the head boundary; the final observed state is held
    /// through `end`, so neither boundary can disappear between 1 Hz samples.
    static func thermalDwell(
        samples: [SystemMetricSample],
        from start: Double,
        to end: Double
    ) -> [String: Double]? {
        guard end > start else { return nil }
        let ordered = samples.sorted { $0.monotonicSeconds < $1.monotonicSeconds }
        guard let seed = ordered.last(where: { $0.monotonicSeconds <= start }),
              let initialState = ThermalDwellAccumulator.state(named: seed.thermalState) else {
            return nil
        }
        var accumulator = ThermalDwellAccumulator(initial: initialState, at: start)
        for sample in ordered where sample.monotonicSeconds > start
            && sample.monotonicSeconds < end {
            guard let state = ThermalDwellAccumulator.state(named: sample.thermalState) else {
                return nil
            }
            accumulator.transition(to: state, at: sample.monotonicSeconds)
        }
        return accumulator.finish(at: end)
    }

    static func batteryLevelDelta(start: Double, end: Double) -> Double {
        end - start
    }

    static func peakPhysicalFootprintMiB(
        samples: [SystemMetricSample]
    ) -> Double? {
        guard !samples.isEmpty,
              samples.allSatisfy({ ($0.physicalFootprintBytes ?? 0) > 0 }),
              let peak = samples.compactMap(\.physicalFootprintBytes).max() else {
            return nil
        }
        return Double(peak) / 1_048_576
    }
}

struct ThermalDwellAccumulator {
    private(set) var firstSeriousSeconds: Double?
    private var state: ProcessInfo.ThermalState
    private var stateStartSeconds: Double
    private var dwell: [String: Double] = [:]

    init(initial: ProcessInfo.ThermalState, at seconds: Double) {
        state = initial
        stateStartSeconds = seconds
        if initial == .serious || initial == .critical {
            firstSeriousSeconds = seconds
        }
    }

    mutating func transition(to newState: ProcessInfo.ThermalState, at seconds: Double) {
        guard seconds >= stateStartSeconds else { return }
        dwell[Self.name(state), default: 0] += seconds - stateStartSeconds
        state = newState
        stateStartSeconds = seconds
        if firstSeriousSeconds == nil && (newState == .serious || newState == .critical) {
            firstSeriousSeconds = seconds
        }
    }

    mutating func finish(at seconds: Double) -> [String: Double] {
        transition(to: state, at: seconds)
        return dwell
    }

    static func name(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    static func state(named name: String) -> ProcessInfo.ThermalState? {
        switch name {
        case "nominal": return .nominal
        case "fair": return .fair
        case "serious": return .serious
        case "critical": return .critical
        default: return nil
        }
    }
}
