import Foundation

enum EuRoCFileRole: String, Codable, CaseIterable, Sendable {
    case camera0Index = "camera0_index"
    case camera1Index = "camera1_index"
    case imuIndex = "imu_index"
    case groundTruth = "ground_truth"
    case camera0Calibration = "camera0_calibration"
    case camera1Calibration = "camera1_calibration"
    case imuCalibration = "imu_calibration"
    case cameraImage = "camera_image"
}

struct EuRoCManifestFile: Codable, Equatable, Sendable {
    let role: EuRoCFileRole
    let relativePath: String
    var byteCount: Int64
    var sha256: String

    enum CodingKeys: String, CodingKey {
        case role
        case relativePath = "relative_path"
        case byteCount = "byte_count"
        case sha256
    }
}

struct EuRoCOrderedManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let datasetName: String
    var inputCameraCount: Int
    var datasetSHA256: String
    var files: [EuRoCManifestFile]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case datasetName = "dataset_name"
        case inputCameraCount = "input_camera_count"
        case datasetSHA256 = "dataset_sha256"
        case files
    }
}

struct EuRoCIMUSample: Equatable, Sendable {
    let timestampNanoseconds: Int64
    let gyroscopeRadiansPerSecond: Vector3
    let accelerationMetersPerSecondSquared: Vector3
}

struct EuRoCCameraFrame: Equatable, Sendable {
    let timestampNanoseconds: Int64
    let camera0ImageURL: URL
    let camera1ImageURL: URL?
    /// The access units to decode for this frame, in order, ending with its own.
    /// A device recording archives an HEVC bitstream the way production does, so
    /// a frame is not a slice that can be read on its own: decoding starts at
    /// the GOP's keyframe and runs forward, which is exactly what production's
    /// PwvaReader.readFrameNv12 does. EuRoC is one encoded image per file and
    /// leaves this nil.
    var camera0AccessUnits: [Range<Int>]?

    init(
        timestampNanoseconds: Int64,
        camera0ImageURL: URL,
        camera1ImageURL: URL?,
        camera0AccessUnits: [Range<Int>]? = nil
    ) {
        self.timestampNanoseconds = timestampNanoseconds
        self.camera0ImageURL = camera0ImageURL
        self.camera1ImageURL = camera1ImageURL
        self.camera0AccessUnits = camera0AccessUnits
    }

    var inputCameraCount: Int { camera1ImageURL == nil ? 1 : 2 }
}

enum ReplayEvent: Equatable, Sendable {
    case imu(EuRoCIMUSample)
    case camera(EuRoCCameraFrame)

    enum Kind: Int, Equatable, Sendable {
        case imu = 0
        case camera = 1
    }

    var timestampNanoseconds: Int64 {
        switch self {
        case .imu(let sample): sample.timestampNanoseconds
        case .camera(let frame): frame.timestampNanoseconds
        }
    }

    var kind: Kind {
        switch self {
        case .imu: .imu
        case .camera: .camera
        }
    }
}

struct EuRoCReplayDataset: Sendable {
    let datasetName: String
    /// Must be copied into the run receipt as `input_camera_count`.
    let inputCameraCount: Int
    let datasetSHA256: String
    let events: [ReplayEvent]
    let groundTruth: [TimedPose]
}

enum EuRoCReplayError: Error, Equatable, CustomStringConvertible {
    case unsupportedSchemaVersion(Int)
    case invalidDatasetName
    case invalidInputCameraCount(Int)
    case invalidDatasetIdentity
    case manifestFilesNotStrictlySorted
    case unsafeRelativePath(String)
    case missingRequiredRole(EuRoCFileRole)
    case duplicateRequiredRole(EuRoCFileRole)
    case roleNotAllowedForInputCameraCount(role: EuRoCFileRole, inputCameraCount: Int)
    case missingFile(String)
    case fileSizeMismatch(path: String, expected: Int64, actual: Int64)
    case fileHashMismatch(path: String, expected: String, actual: String)
    case datasetIdentityMismatch(expected: String, actual: String)
    case malformedCSV(path: String, line: Int, reason: String)
    case timestampRegression(path: String, previous: Int64, current: Int64)
    case stereoTimestampMismatch(camera0: Int64, camera1: Int64)
    case stereoFrameCountMismatch(camera0: Int, camera1: Int)
    case imageNotDeclared(String)
    case groundTruthDoesNotCoverReplay
    case emptyReplay

    var description: String {
        switch self {
        case .unsupportedSchemaVersion(let version): "unsupported EuRoC manifest schema version \(version)"
        case .invalidDatasetName: "dataset_name must not be empty"
        case .invalidInputCameraCount(let count): "input_camera_count must be 1 or 2; got \(count)"
        case .invalidDatasetIdentity: "dataset_sha256 must be a lowercase SHA-256 hex string"
        case .manifestFilesNotStrictlySorted: "manifest files must be unique and strictly sorted by relative_path"
        case .unsafeRelativePath(let path): "unsafe relative path: \(path)"
        case .missingRequiredRole(let role): "missing required file role: \(role.rawValue)"
        case .duplicateRequiredRole(let role): "duplicate required file role: \(role.rawValue)"
        case .roleNotAllowedForInputCameraCount(let role, let count): "file role \(role.rawValue) is not allowed for input_camera_count=\(count)"
        case .missingFile(let path): "missing dataset file: \(path)"
        case .fileSizeMismatch(let path, let expected, let actual): "file size mismatch for \(path): expected \(expected), got \(actual)"
        case .fileHashMismatch(let path, let expected, let actual): "file SHA-256 mismatch for \(path): expected \(expected), got \(actual)"
        case .datasetIdentityMismatch(let expected, let actual): "dataset identity mismatch: expected \(expected), got \(actual)"
        case .malformedCSV(let path, let line, let reason): "malformed CSV \(path):\(line): \(reason)"
        case .timestampRegression(let path, let previous, let current): "timestamp regression in \(path): \(previous) -> \(current)"
        case .stereoTimestampMismatch(let camera0, let camera1): "stereo timestamp mismatch: cam0=\(camera0), cam1=\(camera1)"
        case .stereoFrameCountMismatch(let camera0, let camera1): "stereo frame count mismatch: cam0=\(camera0), cam1=\(camera1)"
        case .imageNotDeclared(let path): "camera image is not declared by the manifest: \(path)"
        case .groundTruthDoesNotCoverReplay: "ground truth does not cover the full stereo replay span"
        case .emptyReplay: "replay has no stereo or IMU events"
        }
    }
}
