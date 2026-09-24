import Foundation

struct BenchBackend: Equatable, Hashable, Identifiable, Sendable {
    let id: String
    let displayName: String
    let upstreamRevision: String
    let bundleID: String
    let experimentID: String
    let algorithmMode: String
    let openCVVersion: String
    let runDirectoryName: String
    let usesARKit: Bool

    static let basalt = BenchBackend(
        id: "basalt",
        displayName: "Basalt",
        upstreamRevision: "0f3b2b52c807f70ff4e2973ce253c73329eea7bc",
        bundleID: "com.kyle.viobench",
        experimentID: BenchExperimentIdentity.experimentID,
        algorithmMode: "basalt_vio_only_float",
        openCVVersion: "4.12.0",
        runDirectoryName: "VIOBenchRuns",
        usesARKit: false
    )

    static let xrslam = BenchBackend(
        id: "xrslam",
        displayName: "XRSLAM",
        upstreamRevision: "4beb1a942f33da9afbfae2d70e2c641cfc2bb675",
        bundleID: "com.kyle.viobench",
        experimentID: BenchExperimentIdentity.experimentID,
        algorithmMode: "xrslam_generic_vio_only",
        openCVVersion: "4.0.1",
        runDirectoryName: "VIOBenchRuns",
        usesARKit: false
    )

    static let arkit = BenchBackend(
        id: "arkit_reference",
        displayName: "ARKit Reference",
        upstreamRevision: "apple_arkit_ios26_sdk",
        bundleID: "com.kyle.viobench",
        experimentID: BenchExperimentIdentity.experimentID,
        algorithmMode: "arkit_world_tracking_reference",
        openCVVersion: "not_applicable",
        runDirectoryName: "VIOBenchRuns",
        usesARKit: true
    )

    static let allCases: [BenchBackend] = [.basalt, .xrslam, .arkit]
}
