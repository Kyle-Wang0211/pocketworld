import CryptoKit
import Foundation

enum RunReceiptState: String, Codable, CaseIterable {
    case started
    case validPass = "valid_pass"
    case validFail = "valid_fail"
    case invalid
    case aborted

    static let terminalStates: Set<RunReceiptState> = [.validPass, .validFail, .invalid, .aborted]
}

enum RunReceiptChannel: String, Codable, CaseIterable {
    case record = "record"
    case liveSoak = "live_soak"
    case replayDeviceRecording = "replay_device_recording"
    case replayPaced = "replay_paced"
    case replayMax = "replay_max"

    /// `liveSoak` is not a synonym for "ran a camera". Using it as one is how
    /// `record` was rejected as a replay, skipped camera permission, and would
    /// have failed receipt validation -- four separate guards written when
    /// liveSoak happened to be the only live mode.
    var isReplay: Bool {
        switch self {
        case .replayDeviceRecording, .replayPaced, .replayMax: return true
        case .record, .liveSoak: return false
        }
    }
}

struct RunAppIdentity: Codable, Equatable {
    var bundleID: String
    var usesARKit: Bool
    var backend: String
    var algorithmMode: String
    var engineID: String
    var upstreamRevision: String
    var openCVVersion: String

    private enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case usesARKit = "uses_arkit"
        case backend
        case algorithmMode = "algorithm_mode"
        case engineID = "engine_id"
        case upstreamRevision = "upstream_revision"
        case openCVVersion = "opencv_version"
    }
}

struct RunDeviceEvidence: Codable, Equatable {
    var modelIdentifier: String
    var operatingSystemVersion: String

    private enum CodingKeys: String, CodingKey {
        case modelIdentifier = "model_identifier"
        case operatingSystemVersion = "operating_system_version"
    }

    static func current() -> RunDeviceEvidence {
        RunDeviceEvidence(
            modelIdentifier: DeviceIdentity.current().modelIdentifier,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
}

struct RunSHA256Identities: Codable, Equatable {
    var contractSHA256: String
    var appBinarySHA256: String
    var engineArtifactSHA256: String
    var configSHA256: String
    var inputDefinitionSHA256: String
    var metricDefinitionsSHA256: String

    private enum CodingKeys: String, CodingKey {
        case contractSHA256 = "contract_sha256"
        case appBinarySHA256 = "app_binary_sha256"
        case engineArtifactSHA256 = "engine_artifact_sha256"
        case configSHA256 = "config_sha256"
        case inputDefinitionSHA256 = "input_definition_sha256"
        case metricDefinitionsSHA256 = "metric_definitions_sha256"
    }

    var all: [(name: String, value: String)] {
        [
            ("contract_sha256", contractSHA256),
            ("app_binary_sha256", appBinarySHA256),
            ("engine_artifact_sha256", engineArtifactSHA256),
            ("config_sha256", configSHA256),
            ("input_definition_sha256", inputDefinitionSHA256),
            ("metric_definitions_sha256", metricDefinitionsSHA256),
        ]
    }
}

struct RunPowerEvidence: Codable, Equatable {
    var powerW: Double?
    var powerWStatus: String
    var batteryAndThermalAreProxies: Bool

    init(
        powerW: Double? = nil,
        powerWStatus: String = "unavailable_public_api",
        batteryAndThermalAreProxies: Bool = true
    ) {
        self.powerW = powerW
        self.powerWStatus = powerWStatus
        self.batteryAndThermalAreProxies = batteryAndThermalAreProxies
    }

    private enum CodingKeys: String, CodingKey {
        case powerW = "power_w"
        case powerWStatus = "power_w_status"
        case batteryAndThermalAreProxies = "battery_and_thermal_are_proxies"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.powerW) else {
            throw DecodingError.keyNotFound(
                CodingKeys.powerW,
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "power_w must be present and null")
            )
        }
        powerW = try container.decodeIfPresent(Double.self, forKey: .powerW)
        powerWStatus = try container.decode(String.self, forKey: .powerWStatus)
        batteryAndThermalAreProxies = try container.decode(Bool.self, forKey: .batteryAndThermalAreProxies)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let powerW {
            try container.encode(powerW, forKey: .powerW)
        } else {
            try container.encodeNil(forKey: .powerW)
        }
        try container.encode(powerWStatus, forKey: .powerWStatus)
        try container.encode(batteryAndThermalAreProxies, forKey: .batteryAndThermalAreProxies)
    }
}

enum RunAccuracyStatus: String, Codable {
    case notEvaluable = "not_evaluable"
    case evaluable
}

enum RunGroundTruth: String, Codable {
    case none
    case euroc
}

struct RunAccuracyEvidence: Codable, Equatable {
    var status: RunAccuracyStatus
    var groundTruth: RunGroundTruth

    private enum CodingKeys: String, CodingKey {
        case status
        case groundTruth = "ground_truth"
    }
}

struct RunTermination: Codable, Equatable {
    var reasonCode: String
    var detail: String?
    var recoveredFromInterruption: Bool

    private enum CodingKeys: String, CodingKey {
        case reasonCode = "reason_code"
        case detail
        case recoveredFromInterruption = "recovered_from_interruption"
    }

    init(reasonCode: String, detail: String? = nil, recoveredFromInterruption: Bool) {
        self.reasonCode = reasonCode
        self.detail = detail
        self.recoveredFromInterruption = recoveredFromInterruption
    }
}

struct RunReceipt: Codable, Equatable {
    var schemaVersion: Int
    var runID: String
    var experimentID: String
    var state: RunReceiptState
    var channel: RunReceiptChannel
    var inputCameraCount: Int
    var startedAtUTC: String
    var endedAtUTC: String?
    var scope: String
    var globalDefaultEligible: Bool
    var app: RunAppIdentity
    var device: RunDeviceEvidence
    var identities: RunSHA256Identities
    var power: RunPowerEvidence
    var accuracy: RunAccuracyEvidence
    var metrics: [String: Double]
    /// Whether `metrics` may be cited in a verdict.
    ///
    /// Invalid and aborted runs keep their metrics: discarding them threw away
    /// exactly the numbers needed to diagnose why the run failed, which is how
    /// the cross-clock-domain defect stayed invisible in every artifact and was
    /// only ever seen on screen. The flag exists so retained numbers can never be
    /// mistaken for scoreable ones, and `validate()` pins it to the state so it
    /// cannot drift.
    var metricsValidForScoring: Bool
    var termination: RunTermination?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case experimentID = "experiment_id"
        case state
        case channel
        case inputCameraCount = "input_camera_count"
        case startedAtUTC = "started_at_utc"
        case endedAtUTC = "ended_at_utc"
        case scope
        case globalDefaultEligible = "global_default_eligible"
        case app
        case device
        case identities
        case power
        case accuracy
        case metrics
        case metricsValidForScoring = "metrics_valid_for_scoring"
        case termination
    }

    init(
        schemaVersion: Int = 1,
        runID: String,
        experimentID: String = BenchExperimentIdentity.experimentID,
        state: RunReceiptState,
        channel: RunReceiptChannel,
        inputCameraCount: Int,
        startedAtUTC: String,
        endedAtUTC: String? = nil,
        scope: String = BenchExperimentIdentity.scope,
        globalDefaultEligible: Bool = false,
        app: RunAppIdentity,
        device: RunDeviceEvidence,
        identities: RunSHA256Identities,
        power: RunPowerEvidence,
        accuracy: RunAccuracyEvidence,
        metrics: [String: Double] = [:],
        metricsValidForScoring: Bool? = nil,
        termination: RunTermination? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.experimentID = experimentID
        self.state = state
        self.channel = channel
        self.inputCameraCount = inputCameraCount
        self.startedAtUTC = startedAtUTC
        self.endedAtUTC = endedAtUTC
        self.scope = scope
        self.globalDefaultEligible = globalDefaultEligible
        self.app = app
        self.device = device
        self.identities = identities
        self.power = power
        self.accuracy = accuracy
        self.metrics = metrics
        // Derived from state by default so a caller cannot accidentally mark
        // diagnostic numbers as scoreable.
        self.metricsValidForScoring = metricsValidForScoring
            ?? (state == .validPass || state == .validFail)
        self.termination = termination
    }

    func validate() throws {
        guard schemaVersion == 1 else { throw RunReceiptValidationError.invalid("schema_version must be 1") }
        guard UUID(uuidString: runID)?.uuidString.lowercased() == runID.lowercased() else {
            throw RunReceiptValidationError.invalid("run_id must be a UUID")
        }
        // Compared against the bundled contract, not a literal, so a contract
        // bump cannot leave receipts declaring the previous experiment while
        // hashing the current one.
        guard experimentID == BenchExperimentIdentity.experimentID,
              experimentID != BenchExperimentIdentity.unavailable else {
            throw RunReceiptValidationError.invalid("experiment_id does not match the bundled contract")
        }
        guard scope == BenchExperimentIdentity.scope,
              scope != BenchExperimentIdentity.unavailable else {
            throw RunReceiptValidationError.invalid("scope does not match the bundled contract")
        }
        guard !globalDefaultEligible else {
            throw RunReceiptValidationError.invalid("global_default_eligible must be false")
        }
        let expectedBackend: BenchBackend
        switch app.engineID {
        case BenchBackend.basalt.id: expectedBackend = .basalt
        case BenchBackend.xrslam.id: expectedBackend = .xrslam
        case BenchBackend.arkit.id: expectedBackend = .arkit
        default: throw RunReceiptValidationError.invalid("unknown engine_id")
        }
        guard app.bundleID == expectedBackend.bundleID,
              app.bundleID != "com.kyle.PocketWorld" else {
            throw RunReceiptValidationError.invalid("production or unexpected bundle")
        }
        guard app.usesARKit == expectedBackend.usesARKit else {
            throw RunReceiptValidationError.invalid("ARKit use does not match selected engine")
        }
        guard expectedBackend != .arkit || !channel.isReplay else {
            throw RunReceiptValidationError.invalid("ARKit reference cannot use replay channels")
        }
        // [bench 2026-09-04] gpufe arm: `-PWXrslamGpuFrontend` declares app.backend = "gpu_frontend"
        // (xrslam only). Any other combination is still rejected here.
        let gpuFrontEnd = expectedBackend == .xrslam
            && ProcessInfo.processInfo.arguments.contains("-PWXrslamGpuFrontend")
        let expectedComputeBackend = expectedBackend == .arkit ? "apple_arkit" : (gpuFrontEnd ? "gpu_frontend" : "cpu")
        guard app.backend == expectedComputeBackend,
              app.algorithmMode == expectedBackend.algorithmMode,
              app.upstreamRevision == expectedBackend.upstreamRevision,
              app.openCVVersion == expectedBackend.openCVVersion else {
            throw RunReceiptValidationError.invalid("unexpected backend or algorithm mode")
        }
        guard !device.modelIdentifier.isEmpty,
              !device.operatingSystemVersion.isEmpty else {
            throw RunReceiptValidationError.invalid("device identity is incomplete")
        }
        for identity in identities.all where !Self.isSHA256(identity.value) {
            throw RunReceiptValidationError.invalid("\(identity.name) is not SHA-256")
        }
        guard power.powerW == nil,
              power.powerWStatus == "unavailable_public_api",
              power.batteryAndThermalAreProxies else {
            throw RunReceiptValidationError.invalid("power evidence must preserve public-API unavailability")
        }
        guard Self.isUTCTimestamp(startedAtUTC) else {
            throw RunReceiptValidationError.invalid("started_at_utc is invalid")
        }
        guard metrics.values.allSatisfy(\.isFinite) else {
            throw RunReceiptValidationError.invalid("metrics must be finite")
        }
        // Only a valid result may claim scoreable metrics. Retained diagnostic
        // numbers on an invalid or aborted run must say so.
        guard metricsValidForScoring == (state == .validPass || state == .validFail) else {
            throw RunReceiptValidationError.invalid(
                "metrics_valid_for_scoring must match the receipt state"
            )
        }
        switch channel {
        case .record, .liveSoak, .replayDeviceRecording:
            guard inputCameraCount == 1 else {
                throw RunReceiptValidationError.invalid("live input_camera_count must be 1")
            }
            // The device recording has no external ground truth, so it may not
            // claim absolute accuracy no matter how well the arms agree on it.
            guard accuracy == RunAccuracyEvidence(status: .notEvaluable, groundTruth: .none) else {
                throw RunReceiptValidationError.invalid("live accuracy must be not_evaluable")
            }
        case .replayPaced, .replayMax:
            guard inputCameraCount == 1 || inputCameraCount == 2 else {
                throw RunReceiptValidationError.invalid("replay input_camera_count must be 1 or 2")
            }
            guard accuracy == RunAccuracyEvidence(status: .evaluable, groundTruth: .euroc) else {
                throw RunReceiptValidationError.invalid("replay accuracy must use EuRoC ground truth")
            }
        }
        if state == .started {
            guard endedAtUTC == nil, termination == nil, metrics.isEmpty else {
                throw RunReceiptValidationError.invalid("started receipt cannot contain terminal evidence")
            }
            return
        }
        guard let endedAtUTC, Self.isUTCTimestamp(endedAtUTC), let termination else {
            throw RunReceiptValidationError.invalid("terminal receipt is incomplete")
        }
        guard Self.timestamp(endedAtUTC)! >= Self.timestamp(startedAtUTC)! else {
            throw RunReceiptValidationError.invalid("terminal timestamp precedes start")
        }
        guard !termination.reasonCode.isEmpty else {
            throw RunReceiptValidationError.invalid("termination reason is empty")
        }
        if termination.recoveredFromInterruption {
            guard state == .aborted, termination.reasonCode == "interrupted_recovery" else {
                throw RunReceiptValidationError.invalid("recovery marker is inconsistent")
            }
        }
        if state == .validPass || state == .validFail {
            let required = channel.isReplay ? Self.replayResultMetrics : Self.liveResultMetrics
            guard required.isSubset(of: Set(metrics.keys)) else {
                throw RunReceiptValidationError.invalid("valid result is missing required metrics")
            }
            let expectedReason = state == .validPass ? "thresholds_met" : "gates_not_met"
            guard termination.reasonCode == expectedReason else {
                throw RunReceiptValidationError.invalid("valid result has inconsistent disposition")
            }
        }
    }

    private static let liveResultMetrics: Set<String> = [
        "first_usable_pose_latency_ms", "processed_fps",
        "p95_pipeline_latency_ms", "app_drop_rate",
        "thermal_critical_seconds", "thermal_serious_seconds", "peak_phys_footprint_mb",
        "finite_pose_ratio", "battery_level_delta", "cpu_seconds",
    ]

    private static let replayResultMetrics: Set<String> = [
        "processed_fps", "ate_rmse_m", "rpe_translation_rmse_m",
        "rpe_rotation_rmse_deg", "ground_truth_coverage", "cpu_seconds",
    ]

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value) || (97...102).contains($0.value)
        }
    }

    static func isUTCTimestamp(_ value: String) -> Bool {
        timestamp(value) != nil
    }

    private static func timestamp(_ value: String) -> Date? {
        guard value.hasSuffix("Z") else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: value)
    }
}

struct RunHeartbeat: Codable, Equatable {
    var schemaVersion: Int
    var runID: String
    var receiptState: RunReceiptState
    var sequence: Int
    var monotonicNS: UInt64
    var writtenAtUTC: String
    var startedReceiptSHA256: String
    /// Resident footprint at the moment this heartbeat was written.
    ///
    /// The receipt's peak footprint only exists for runs that finish, so a run
    /// the OS kills leaves no memory record at all -- which is exactly the run
    /// whose memory needs explaining. The heartbeat survives the kill, so
    /// carrying the footprint here turns "it died" into a curve.
    var footprintMB: Double = 0

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case runID = "run_id"
        case receiptState = "receipt_state"
        case sequence
        case monotonicNS = "monotonic_ns"
        case footprintMB = "footprint_mb"
        case writtenAtUTC = "written_at_utc"
        case startedReceiptSHA256 = "started_receipt_sha256"
    }

    init(
        schemaVersion: Int = 1,
        runID: String,
        receiptState: RunReceiptState = .started,
        sequence: Int,
        monotonicNS: UInt64,
        writtenAtUTC: String,
        startedReceiptSHA256: String,
        footprintMB: Double = 0
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.receiptState = receiptState
        self.sequence = sequence
        self.monotonicNS = monotonicNS
        self.writtenAtUTC = writtenAtUTC
        self.startedReceiptSHA256 = startedReceiptSHA256
        self.footprintMB = footprintMB
    }

    func validate() throws {
        guard schemaVersion == 1,
              UUID(uuidString: runID) != nil,
              receiptState == .started,
              sequence >= 0,
              RunReceipt.isUTCTimestamp(writtenAtUTC),
              RunReceipt.isSHA256(startedReceiptSHA256) else {
            throw RunReceiptValidationError.invalid("heartbeat is invalid")
        }
    }
}

enum RunReceiptHash {
    static func sha256Hex(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    /// Hex for a digest computed incrementally, so an artifact can be hashed in
    /// chunks instead of being read whole.
    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum RunReceiptStateMachine {
    static func validateTransition(from previous: RunReceipt?, to current: RunReceipt) throws {
        try current.validate()
        guard let previous else {
            guard current.state == .started else {
                throw RunReceiptValidationError.illegalTransition(from: nil, to: current.state)
            }
            return
        }
        try previous.validate()
        guard previous.state == .started, RunReceiptState.terminalStates.contains(current.state) else {
            throw RunReceiptValidationError.illegalTransition(from: previous.state, to: current.state)
        }
        guard previous.schemaVersion == current.schemaVersion,
              previous.runID == current.runID,
              previous.experimentID == current.experimentID,
              previous.channel == current.channel,
              previous.inputCameraCount == current.inputCameraCount,
              previous.startedAtUTC == current.startedAtUTC,
              previous.scope == current.scope,
              previous.globalDefaultEligible == current.globalDefaultEligible,
              previous.app == current.app,
              previous.device == current.device,
              previous.identities == current.identities,
              previous.power == current.power,
              previous.accuracy == current.accuracy else {
            throw RunReceiptValidationError.invalid("immutable run identity changed")
        }
    }
}

/// `LocalizedError`, for the same reason `DeviceRecordingError` needed it: a bare
/// Swift error surfaces as "RunReceiptValidationError error 0", discarding the
/// message that says which invariant failed.
enum RunReceiptValidationError: Error, Equatable, LocalizedError {
    case invalid(String)
    case illegalTransition(from: RunReceiptState?, to: RunReceiptState)

    var errorDescription: String? {
        switch self {
        case .invalid(let reason):
            return "收据不合法:\(reason)"
        case .illegalTransition(let from, let to):
            return "收据状态非法迁移:\(from?.rawValue ?? "nil") → \(to.rawValue)"
        }
    }
}

enum RunReceiptJSON {
    static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    static var decoder: JSONDecoder {
        JSONDecoder()
    }
}
