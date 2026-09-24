import Foundation

enum ARKitTrackingEvidence: String, Codable, Sendable {
    case normal
    case limitedInitializing = "limited_initializing"
    case limitedExcessiveMotion = "limited_excessive_motion"
    case limitedInsufficientFeatures = "limited_insufficient_features"
    case limitedRelocalizing = "limited_relocalizing"
    case limitedOther = "limited_other"
    case notAvailable = "not_available"
}

enum ARKitMappingEvidence: String, Codable, Sendable {
    case notAvailable = "not_available"
    case limited
    case extending
    case mapped
}

struct ARKitReferenceSnapshot: Equatable, Sendable {
    var framesReceived: UInt64 = 0
    var finitePoses: UInt64 = 0
    var nonfinitePoses: UInt64 = 0
    var timestampRegressions: UInt64 = 0
    var invalidCallbackLatencies: UInt64 = 0
    var estimatedMissedFrames: UInt64 = 0
    var callbacksAfterPause: UInt64 = 0
    var sessionInterruptions: UInt64 = 0
    var sessionInterruptionEnds: UInt64 = 0
    var sessionFailures: UInt64 = 0
    var trackingNormal: UInt64 = 0
    var trackingLimitedInitializing: UInt64 = 0
    var trackingLimitedExcessiveMotion: UInt64 = 0
    var trackingLimitedInsufficientFeatures: UInt64 = 0
    var trackingLimitedRelocalizing: UInt64 = 0
    var trackingLimitedOther: UInt64 = 0
    var trackingNotAvailable: UInt64 = 0
    var mappingNotAvailable: UInt64 = 0
    var mappingLimited: UInt64 = 0
    var mappingExtending: UInt64 = 0
    var mappingMapped: UInt64 = 0
    var firstFrameLatencyMilliseconds: Double?
    var firstNormalLatencyMilliseconds: Double?
    var firstNormalDeliveryLatencyMilliseconds: Double?
    var firstMappedLatencyMilliseconds: Double?
    var callbackLatenciesMilliseconds: [Double] = []
    var callbackHandlerDurationsMilliseconds: [Double] = []
    var frameIntervalsMilliseconds: [Double] = []
    var consecutiveTranslationMeters: [Double] = []
    var consecutiveRotationDegrees: [Double] = []
    var trackingTransitions: UInt64 = 0
    var mappingTransitions: UInt64 = 0
    var stallEventsOverOneSecond: UInt64 = 0
    var stallDurationMilliseconds: Double = 0
    var longestNonNormalSeconds: Double = 0
    var relocalizationAttempts: UInt64 = 0
    var relocalizationRecoveries: UInt64 = 0
    var relocalizationRecoveryMilliseconds: [Double] = []
    var trackingDwellSeconds: [String: Double] = [:]
    var mappingDwellSeconds: [String: Double] = [:]
    var lastCallbackNanoseconds: UInt64?
    /// Frames captured before the stop but delivered after it. ARKit enqueues
    /// delegate callbacks on the delegate queue, so at 60 Hz one or two are
    /// already queued behind the pause block when it runs. They describe the
    /// world before the stop and are counted separately from a genuine
    /// post-stop callback, which would mean the session never stopped.
    var lateFrameDeliveries: UInt64 = 0
    var poses: [NativePoseSample] = []
}

struct ARKitReferenceStatusSnapshot: Equatable, Sendable {
    let framesReceived: UInt64
    let finitePoses: UInt64
    let estimatedMissedFrames: UInt64
    let callbacksAfterPause: UInt64
    let lateFrameDeliveries: UInt64
    let sessionInterruptions: UInt64
    let sessionFailures: UInt64
    let timestampRegressions: UInt64
}

/// Pure accounting for the ARKit reference arm. It accepts already-classified
/// observations and never imports ARKit, opens sensors, or changes an engine.
final class ARKitReferenceAccounting: @unchecked Sendable {
    private let lock = NSLock()
    private let startMonotonicSeconds: Double
    private let nominalPeriodSeconds: Double
    private var accepting = true
    /// Capture timestamp, in the ARKit clock domain, of the moment the run
    /// stopped accepting frames. A late callback is told apart from a real
    /// post-stop callback by whether the frame was captured before this.
    private var pauseTimestampSeconds: Double?
    private var value = ARKitReferenceSnapshot()
    private var lastTimestampSeconds: Double?
    private var lastFinitePose: TimedPose?
    private var lastTracking: ARKitTrackingEvidence?
    private var lastMapping: ARKitMappingEvidence?
    private var nonNormalStartSeconds: Double?
    private var relocalizationStartSeconds: Double?

    init(startMonotonicSeconds: Double, nominalFramesPerSecond: Double) {
        precondition(startMonotonicSeconds.isFinite)
        precondition(nominalFramesPerSecond.isFinite && nominalFramesPerSecond > 0)
        self.startMonotonicSeconds = startMonotonicSeconds
        nominalPeriodSeconds = 1.0 / nominalFramesPerSecond
    }

    func recordFrame(
        timestampSeconds: Double,
        callbackSeconds: Double,
        pose: TimedPose,
        tracking: ARKitTrackingEvidence,
        mapping: ARKitMappingEvidence
    ) {
        lock.withLock {
            guard accepting else {
                // A frame captured at or before the stop is a late delivery of
                // work ARKit had already done -- normal, and not evidence that
                // the session kept running. Only a frame captured after the
                // stop means the session outlived the pause.
                if let pausedAt = pauseTimestampSeconds, timestampSeconds <= pausedAt {
                    value.lateFrameDeliveries += 1
                } else {
                    value.callbacksAfterPause += 1
                }
                return
            }
            value.framesReceived += 1
            if callbackSeconds.isFinite, callbackSeconds >= 0 {
                value.lastCallbackNanoseconds = UInt64(
                    (callbackSeconds * 1_000_000_000).rounded()
                )
            }
            if value.firstFrameLatencyMilliseconds == nil,
               timestampSeconds >= startMonotonicSeconds {
                value.firstFrameLatencyMilliseconds =
                    (timestampSeconds - startMonotonicSeconds) * 1_000
            }
            if let previous = lastTimestampSeconds {
                if timestampSeconds <= previous {
                    value.timestampRegressions += 1
                } else {
                    let interval = timestampSeconds - previous
                    value.frameIntervalsMilliseconds.append(interval * 1_000)
                    if let lastTracking {
                        value.trackingDwellSeconds[lastTracking.rawValue, default: 0] += interval
                    }
                    if let lastMapping {
                        value.mappingDwellSeconds[lastMapping.rawValue, default: 0] += interval
                    }
                    if interval > 1 {
                        value.stallEventsOverOneSecond += 1
                        value.stallDurationMilliseconds += interval * 1_000
                    }
                    let elapsedPeriods = interval / nominalPeriodSeconds
                    if elapsedPeriods > 1.5 {
                        value.estimatedMissedFrames += UInt64(
                            max(0, Int(elapsedPeriods.rounded()) - 1)
                        )
                    }
                }
            }
            if lastTimestampSeconds == nil || timestampSeconds > lastTimestampSeconds! {
                lastTimestampSeconds = timestampSeconds
            }

            let latency = callbackSeconds - timestampSeconds
            if latency.isFinite, latency >= 0, latency <= 5 {
                value.callbackLatenciesMilliseconds.append(latency * 1_000)
            } else {
                value.invalidCallbackLatencies += 1
            }

            incrementTracking(
                tracking,
                timestampSeconds: timestampSeconds,
                callbackSeconds: callbackSeconds
            )
            incrementMapping(mapping)
            lastTracking = tracking
            lastMapping = mapping

            guard pose.isFinite else {
                value.nonfinitePoses += 1
                return
            }
            value.finitePoses += 1
            if let previous = lastFinitePose {
                value.consecutiveTranslationMeters.append(
                    (pose.translation - previous.translation).norm
                )
                value.consecutiveRotationDegrees.append(
                    (previous.rotation.inverse * pose.rotation).shortestAngleRadians
                        * 180 / .pi
                )
            }
            lastFinitePose = pose
            let captureNS = UInt64(max(0, timestampSeconds * 1_000_000_000).rounded())
            let latencyNS = UInt64(max(0, latency * 1_000_000_000).rounded())
            value.poses.append(NativePoseSample(
                pose: pose,
                capturedMonotonicNanoseconds: captureNS,
                pipelineLatencyNanoseconds: latencyNS
            ))
        }
    }

    func recordInterruption() {
        lock.withLock { value.sessionInterruptions += 1 }
    }

    func recordInterruptionEnded() {
        lock.withLock { value.sessionInterruptionEnds += 1 }
    }

    func recordFailure() {
        lock.withLock { value.sessionFailures += 1 }
    }

    func recordHandlerDuration(milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        lock.withLock { value.callbackHandlerDurationsMilliseconds.append(milliseconds) }
    }

    /// [timestampSeconds] is the capture timestamp, in ARKit's clock domain,
    /// that separates a late delivery from a genuine post-stop callback.
    func markPaused(timestampSeconds: Double) {
        lock.withLock {
            accepting = false
            pauseTimestampSeconds = timestampSeconds
        }
    }

    func snapshot() -> ARKitReferenceSnapshot {
        lock.withLock {
            var snapshot = value
            if let start = nonNormalStartSeconds, let end = lastTimestampSeconds {
                snapshot.longestNonNormalSeconds = max(
                    snapshot.longestNonNormalSeconds,
                    end - start
                )
            }
            return snapshot
        }
    }

    func statusSnapshot() -> ARKitReferenceStatusSnapshot {
        lock.withLock {
            ARKitReferenceStatusSnapshot(
                framesReceived: value.framesReceived,
                finitePoses: value.finitePoses,
                estimatedMissedFrames: value.estimatedMissedFrames,
                callbacksAfterPause: value.callbacksAfterPause,
                lateFrameDeliveries: value.lateFrameDeliveries,
                sessionInterruptions: value.sessionInterruptions,
                sessionFailures: value.sessionFailures,
                timestampRegressions: value.timestampRegressions
            )
        }
    }

    private func incrementTracking(
        _ tracking: ARKitTrackingEvidence,
        timestampSeconds: Double,
        callbackSeconds: Double
    ) {
        if let previous = lastTracking, previous != tracking {
            value.trackingTransitions += 1
        }
        if tracking != .normal, nonNormalStartSeconds == nil {
            nonNormalStartSeconds = timestampSeconds
        } else if tracking == .normal, let start = nonNormalStartSeconds {
            value.longestNonNormalSeconds = max(
                value.longestNonNormalSeconds,
                timestampSeconds - start
            )
            nonNormalStartSeconds = nil
        }
        if tracking == .limitedRelocalizing,
           lastTracking != .limitedRelocalizing {
            value.relocalizationAttempts += 1
            relocalizationStartSeconds = timestampSeconds
        } else if tracking == .normal,
                  lastTracking == .limitedRelocalizing,
                  let start = relocalizationStartSeconds {
            value.relocalizationRecoveries += 1
            value.relocalizationRecoveryMilliseconds.append(
                (timestampSeconds - start) * 1_000
            )
            relocalizationStartSeconds = nil
        }
        switch tracking {
        case .normal:
            value.trackingNormal += 1
            if value.firstNormalLatencyMilliseconds == nil,
               timestampSeconds >= startMonotonicSeconds {
                value.firstNormalLatencyMilliseconds =
                    (timestampSeconds - startMonotonicSeconds) * 1_000
            }
            if value.firstNormalDeliveryLatencyMilliseconds == nil,
               callbackSeconds.isFinite,
               callbackSeconds >= startMonotonicSeconds {
                value.firstNormalDeliveryLatencyMilliseconds =
                    (callbackSeconds - startMonotonicSeconds) * 1_000
            }
        case .limitedInitializing: value.trackingLimitedInitializing += 1
        case .limitedExcessiveMotion: value.trackingLimitedExcessiveMotion += 1
        case .limitedInsufficientFeatures: value.trackingLimitedInsufficientFeatures += 1
        case .limitedRelocalizing: value.trackingLimitedRelocalizing += 1
        case .limitedOther: value.trackingLimitedOther += 1
        case .notAvailable: value.trackingNotAvailable += 1
        }
    }

    private func incrementMapping(_ mapping: ARKitMappingEvidence) {
        if let previous = lastMapping, previous != mapping {
            value.mappingTransitions += 1
        }
        switch mapping {
        case .notAvailable: value.mappingNotAvailable += 1
        case .limited: value.mappingLimited += 1
        case .extending: value.mappingExtending += 1
        case .mapped:
            value.mappingMapped += 1
            if value.firstMappedLatencyMilliseconds == nil,
               let timestamp = lastTimestampSeconds,
               timestamp >= startMonotonicSeconds {
                value.firstMappedLatencyMilliseconds =
                    (timestamp - startMonotonicSeconds) * 1_000
            }
        }
    }
}
