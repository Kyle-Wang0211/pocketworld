// PwLodProbe.swift — the LOD shell's OS probe: the only numbers the engine cannot know
// (thermal state, process memory). [production 171] Only PwLodFootprintPeak is used (the build's
// peak memory); `pwLodProbe` / PwLodProbe serve pwlod_run (M1), which production does not call.
//
// `pwLodProbe` is pw_splat_ab_bench Sources/App.swift:29-43 @00b020db (`lodProbe`) verbatim
// apart from the name: it fills the PwLodProbeSample that pwlod_run (pw_lod_bench.h) asks for,
// so M1 on the phone reports thermal state and phys_footprint exactly as the standalone bench
// did.
//
// PwLodFootprintPeak is the shell-side peak-memory measurement pwlod_build_from_ply leaves to
// the shell (pwlod_viewer.h:204-205 "Peak memory is the shell's to measure"). Two readings:
//   * sampled: max phys_footprint over a DispatchSourceTimer (default 10 ms) — can miss a
//     spike shorter than the interval;
//   * ledger: task_vm_info.ledger_phys_footprint_peak (iPhoneOS SDK mach/task_info.h:376),
//     the kernel's lifetime peak for the process. If it rises during the call, the new value IS
//     the call's exact peak; if it does not rise, the call peaked below an earlier high-water
//     mark and only the sampled value bounds it. Both are reported; nothing is inferred.
import Darwin
import Foundation
import os

// 外壳探针:只有 OS 知道的量。thermalState 0..3 = nominal/fair/serious/critical,
// 与引擎约定的刻度一致;内存用 phys_footprint(Xcode 内存表同口径)。
let pwLodProbe: PwLodProbeFn = { out, _ in
    guard let out = out else { return }
    out.pointee.thermal_state = Int32(ProcessInfo.processInfo.thermalState.rawValue)
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    out.pointee.footprint_mb = kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1048576.0 : -1
    out.pointee.avail_mb = Double(os_proc_available_memory()) / 1048576.0
}

enum PwLodProbe {
    static func sample() -> PwLodProbeSample {
        var s = PwLodProbeSample(thermal_state: -1, footprint_mb: -1, avail_mb: -1)
        pwLodProbe(&s, nil)
        return s
    }

    static func toMap(_ s: PwLodProbeSample) -> [String: Any] {
        ["thermal_state": Int(s.thermal_state), "footprint_mb": s.footprint_mb, "avail_mb": s.avail_mb]
    }

    /// (phys_footprint, ledger_phys_footprint_peak) in MB; -1 where the kernel did not fill it.
    static func footprintAndLedgerPeakMb() -> (Double, Double) {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (-1, -1) }
        let now = Double(info.phys_footprint) / 1048576.0
        // The kernel reports how many words it filled; the peak field only counts if covered.
        let peakEnd = (MemoryLayout<task_vm_info_data_t>.offset(of: \.ledger_phys_footprint_peak) ?? Int.max)
            + MemoryLayout<Int64>.size
        let filled = Int(count) * MemoryLayout<natural_t>.size
        let peak = filled >= peakEnd ? Double(info.ledger_phys_footprint_peak) / 1048576.0 : -1
        return (now, peak)
    }
}

/// Peak phys_footprint while a blocking call runs on another thread.
final class PwLodFootprintPeak {
    private let queue = DispatchQueue(label: "io.pocketworld.lod.footprint", qos: .utility)
    private let timer: DispatchSourceTimer
    private let lock = NSLock()
    private var sampledPeakMb: Double = -1
    private var samples = 0
    private(set) var baselineMb: Double = -1
    private(set) var ledgerPeakBeforeMb: Double = -1

    init(intervalMs: Int = 10) {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(intervalMs))
        timer.setEventHandler { [weak self] in self?.take() }
    }

    private func take() {
        let (now, _) = PwLodProbe.footprintAndLedgerPeakMb()
        lock.lock()
        if now > sampledPeakMb { sampledPeakMb = now }
        samples += 1
        lock.unlock()
    }

    func start() {
        (baselineMb, ledgerPeakBeforeMb) = PwLodProbe.footprintAndLedgerPeakMb()
        timer.resume()
    }

    /// Stops sampling and returns the readings (one last sample is taken first).
    func stop() -> [String: Any] {
        timer.cancel()
        queue.sync {}  // drain an in-flight handler
        take()
        let (_, ledgerAfter) = PwLodProbe.footprintAndLedgerPeakMb()
        lock.lock()
        defer { lock.unlock() }
        return [
            "peak_footprint_mb": sampledPeakMb,
            "baseline_footprint_mb": baselineMb,
            "footprint_samples": samples,
            "ledger_peak_before_mb": ledgerPeakBeforeMb,
            "ledger_peak_after_mb": ledgerAfter,
        ]
    }
}
