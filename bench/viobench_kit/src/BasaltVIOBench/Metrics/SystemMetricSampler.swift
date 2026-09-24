import Darwin
import Foundation
import UIKit

struct SystemMetricSample: Codable, Equatable {
    let monotonicSeconds: Double
    let processUserSeconds: Double
    let processSystemSeconds: Double
    let cpuCoreEquivalent: Double
    let physicalFootprintBytes: UInt64?
    let thermalState: String
    let batteryLevel: Double?
    let batteryState: String
    let lowPowerModeEnabled: Bool
    let appState: String
}

final class SystemMetricSampler {
    typealias Sink = @Sendable (SystemMetricSample) -> Void

    private let queue = DispatchQueue(label: "com.kyle.viobench.system-metrics")
    private var timer: DispatchSourceTimer?
    private var previousCPU: (wall: UInt64, cpu: Double)?
    private let sink: Sink

    init(sink: @escaping Sink) {
        self.sink = sink
    }

    /// Takes the first sample synchronously.
    ///
    /// Scheduling one with `deadline: .now()` is not enough: the handler runs
    /// asynchronously, so it can still land after the caller has captured the run
    /// start timestamp. `Statistics.thermalDwell` then finds no sample at or
    /// before the window it must seed and returns nil, and the run is discarded
    /// as `thermal_telemetry_unavailable` -- which is what happened to a clean
    /// 300 s run and again to the first successful recording. Starting the timer
    /// earlier only narrowed the race; taking the sample inline removes it.
    func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        queue.sync {
            guard timer == nil else { return }
            sample()
            previousCPU = nil
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(50))
            source.setEventHandler { [weak self] in self?.sample() }
            timer = source
            source.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            previousCPU = nil
        }
    }

    private func sample() {
        let now = DispatchTime.now().uptimeNanoseconds
        let cpu = Self.processCPUSeconds()
        let coreEquivalent: Double
        if let previousCPU {
            let wall = Double(now - previousCPU.wall) / 1_000_000_000
            coreEquivalent = wall > 0 ? max(0, (cpu.total - previousCPU.cpu) / wall) : 0
        } else {
            coreEquivalent = 0
        }
        previousCPU = (now, cpu.total)

        let device = UIDevice.current
        let battery = device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil
        let sample = SystemMetricSample(
            monotonicSeconds: Double(now) / 1_000_000_000,
            processUserSeconds: cpu.user,
            processSystemSeconds: cpu.system,
            cpuCoreEquivalent: coreEquivalent,
            physicalFootprintBytes: Self.physicalFootprintBytes(),
            thermalState: ThermalDwellAccumulator.name(ProcessInfo.processInfo.thermalState),
            batteryLevel: battery,
            batteryState: Self.batteryStateName(device.batteryState),
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            appState: Self.applicationStateName()
        )
        sink(sample)
    }

    static func processCPUSeconds() -> (user: Double, system: Double, total: Double) {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return (0, 0, 0) }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return (user, system, user + system)
    }

    static func cpuSecondsDelta(start: Double, end: Double) -> Double {
        max(0, end - start)
    }

    /// Exposed so a heartbeat can carry it; a killed run leaves no receipt.
    static func currentFootprintMB() -> Double {
        guard let bytes = physicalFootprintBytes() else { return 0 }
        return Double(bytes) / (1024.0 * 1024.0)
    }

    private static func physicalFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS, info.phys_footprint > 0 else { return nil }
        return info.phys_footprint
    }

    private static func batteryStateName(_ state: UIDevice.BatteryState) -> String {
        switch state {
        case .unknown: return "unknown"
        case .unplugged: return "unplugged"
        case .charging: return "charging"
        case .full: return "full"
        @unknown default: return "unknown"
        }
    }

    private static func applicationStateName() -> String {
        let state = DispatchQueue.main.sync { UIApplication.shared.applicationState }
        switch state {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}
