import Foundation

struct NativePoseSample: Equatable {
    let pose: TimedPose
    let capturedMonotonicNanoseconds: UInt64
    let pipelineLatencyNanoseconds: UInt64
}
