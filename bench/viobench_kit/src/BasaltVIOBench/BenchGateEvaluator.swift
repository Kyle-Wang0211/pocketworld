import Foundation

struct GateVerdict: Equatable {
    let passed: Bool
    let failedReasons: [String]
}

/// Live metrics of a same-device ARKit live-soak reference receipt.
struct LiveReference: Equatable {
    let processedFPS: Double
    let p95LatencyMilliseconds: Double
    let appDropRate: Double
    let thermalCriticalSeconds: Double
    let thermalSeriousSeconds: Double
    let peakFootprintMB: Double
    let finitePoseRatio: Double
}

enum BenchGateEvaluator {
    static func live(
        firstUsablePoseLatencyMilliseconds: Double,
        processedFPS: Double,
        p95LatencyMilliseconds: Double,
        appDropRate: Double,
        thermalCriticalSeconds: Double,
        thermalSeriousSeconds: Double,
        peakFootprintMB: Double,
        finitePoseRatio: Double,
        processedFPSMinimum: Double = 27,
        referenceFirstUsablePoseLatencyMilliseconds: Double? = nil,
        reference: LiveReference? = nil
    ) -> GateVerdict {
        var failures: [String] = []
        // [2026-09-03 owner decision] The old absolute 1 800 ms gate was a
        // transcription error: production's 1 800 ms is
        // `ar_capture_page.dart` `_warmupFallbackDuration`, a UI warm-up
        // fallback that opens the page whether or not tracking is normal. It
        // is not a tracking requirement, and ARKit itself measures ~2.9 s to
        // `.normal` on the shared recording, so the absolute gate failed the
        // reference it was meant to compare against. The 08-30 contract's own
        // wording is relative ("不劣于 ARKit 参考臂"); this is that gate. With
        // no reference receipt on the device the cold-start gate is not
        // evaluated and the receipt records the reference as unavailable.
        if let reference = referenceFirstUsablePoseLatencyMilliseconds,
           firstUsablePoseLatencyMilliseconds > reference {
            failures.append(
                "first_usable_pose_latency_ms>arkit_reference(\(reference))"
            )
        }
        // [2026-09-03 owner decision] The replacement bar is "not worse than production
        // ARKit on the same device under the same conditions", metric by metric. When a
        // same-device ARKit live-soak reference receipt is on the device every live gate is
        // relative to it; the absolute numbers below remain only as the fallback when no such
        // reference exists (the 08-30 contract's values, kept so a run without a reference
        // still gets a verdict rather than none).
        if let reference {
            if processedFPS < reference.processedFPS { failures.append("processed_fps<arkit_reference(\(reference.processedFPS))") }
            if p95LatencyMilliseconds > reference.p95LatencyMilliseconds { failures.append("p95_pipeline_latency_ms>arkit_reference(\(reference.p95LatencyMilliseconds))") }
            if appDropRate > reference.appDropRate { failures.append("app_drop_rate>arkit_reference(\(reference.appDropRate))") }
            if thermalCriticalSeconds > reference.thermalCriticalSeconds { failures.append("thermal_critical_seconds>arkit_reference(\(reference.thermalCriticalSeconds))") }
            if thermalSeriousSeconds > reference.thermalSeriousSeconds { failures.append("thermal_serious_seconds>arkit_reference(\(reference.thermalSeriousSeconds))") }
            if peakFootprintMB > reference.peakFootprintMB { failures.append("peak_phys_footprint_mb>arkit_reference(\(reference.peakFootprintMB))") }
            if finitePoseRatio < reference.finitePoseRatio { failures.append("finite_pose_ratio<arkit_reference(\(reference.finitePoseRatio))") }
            return GateVerdict(passed: failures.isEmpty, failedReasons: failures)
        }
        if processedFPS < processedFPSMinimum {
            failures.append("processed_fps<\(processedFPSMinimum)")
        }
        if p95LatencyMilliseconds > 66.7 { failures.append("p95_pipeline_latency_ms>66.7") }
        if appDropRate > 0 { failures.append("app_drop_rate>0") }
        if thermalCriticalSeconds > 0 { failures.append("thermal_critical_seconds>0") }
        if thermalSeriousSeconds > 0 { failures.append("thermal_serious_seconds>0") }
        if peakFootprintMB > 750 { failures.append("peak_phys_footprint_mb>750") }
        if finitePoseRatio < 0.995 { failures.append("finite_pose_ratio<0.995") }
        return GateVerdict(passed: failures.isEmpty, failedReasons: failures)
    }

    static func replay(_ metrics: TrajectoryMetrics) -> GateVerdict {
        var failures: [String] = []
        if metrics.ateRMSEMeters > 0.10 { failures.append("ate_rmse_m>0.10") }
        if metrics.rpeTranslationRMSEMeters > 0.05 {
            failures.append("rpe_translation_rmse_m>0.05")
        }
        if metrics.rpeRotationRMSEDegrees > 5 {
            failures.append("rpe_rotation_rmse_deg>5")
        }
        if metrics.groundTruthCoverage < 0.99 {
            failures.append("ground_truth_coverage<0.99")
        }
        return GateVerdict(passed: failures.isEmpty, failedReasons: failures)
    }
}
