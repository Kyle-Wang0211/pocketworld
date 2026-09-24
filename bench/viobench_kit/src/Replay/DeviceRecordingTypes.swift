import Foundation

/// On-disk shape of one device recording.
///
/// The recording is the shared input that lets one hand-held capture serve every
/// arm. It stores the luma plane of `ARFrame.capturedImage` exactly as the engine
/// will receive it, so replaying it is feeding the same input, not a substitute
/// for it.
///
/// Frames are raw, one file each, never encoded. PNG or HEVC would put an encoder
/// on the capture path and, in the lossy case, would change the pixels the
/// algorithm sees. At 1920x1440 a frame is 2,764,800 bytes and 300 s is ~23.2
/// GiB; that cost is accepted rather than compressed away.
enum DeviceRecordingFileRole: String, Codable, CaseIterable, Sendable {
    case cameraIndex = "camera_index"
    /// Per-frame intrinsics, one JSON row per frame, mirroring the per-photo
    /// sidecar production already writes: the same `t` and `intrinsics_fxfycxcy`
    /// keys, pinned to the frame they came from. Production takes that care
    /// because autofocus moves the focal length during a scan and it carries a
    /// per-sample focusStable flag alongside. Keeping only frame 0's values, as
    /// this recorder did, pins a whole capture to whatever focus position the
    /// first frame happened to have.
    case intrinsicsIndex = "intrinsics_index"
    /// The frame stream and its index, copied from production's archive layout.
    case framesStream = "frames_stream"
    case framesIndex = "frames_index"
    case imuIndex = "imu_index"
    case arkitPoses = "arkit_poses"
    /// 🔴 **Bench-only ruler.** The LiDAR `ARFrame.sceneDepth` for the same
    /// frames, stored so an offline tool can put a *metric* number on a
    /// trajectory whose scale is otherwise only knowable relative to ARKit.
    ///
    /// It never leaves the bench. The product pipeline is monocular + IMU and
    /// stays that way: nothing here may be proposed as a product input, a
    /// product fallback, or a shipping requirement. It exists for the same
    /// reason a reference weight exists in a lab -- to check an instrument, not
    /// to be carried around by the instrument.
    ///
    /// Three files, in the same append-only shape `frames.bin` / `frames.pwvi`
    /// already use: a float32 stream in metres, a uint8 stream of
    /// `ARConfidenceLevel`, and one JSONL index row per depth frame.
    case depthStream = "depth_stream"
    case depthConfidenceStream = "depth_confidence_stream"
    case depthIndex = "depth_index"
}

struct DeviceRecordingFile: Codable, Equatable, Sendable {
    let role: DeviceRecordingFileRole
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

struct DeviceRecordingCameraFormat: Codable, Equatable, Sendable {
    var width: Int
    var height: Int
    var pixelFormat: String
    var nominalFPS: Double

    enum CodingKeys: String, CodingKey {
        case width, height
        case pixelFormat = "pixel_format"
        case nominalFPS = "nominal_fps"
    }

    static let scoring = DeviceRecordingCameraFormat(
        width: BenchResolution.scoring.width,
        height: BenchResolution.scoring.height,
        pixelFormat: "luma8_from_420f_full_range",
        nominalFPS: BenchResolution.scoringFramesPerSecond
    )

    /// The capture upstream's own iOS app performs: `AVCaptureSession` at
    /// 640x480 delivering 32BGRA, reduced to gray by
    /// `cvtColor(..., COLOR_BGRA2GRAY)`.
    ///
    /// The `pixel_format` string is not decoration. This gray and `scoring`'s
    /// gray are different images of the same scene -- BT.601 weights over the
    /// ISP's RGB against the ISP's own Y -- so a reader must be able to tell
    /// which one a file holds without rerunning the capture.
    ///
    /// 🔴 Not a scoring format, by construction:
    /// `BenchResolution.participatesInVerdict(640, 480)` is false, so
    /// `DeviceRecordingLoader` refuses it for anything but
    /// `.replication`. That is deliberate and must stay -- 1920x1440 is the
    /// floor every verdict is made at, and this recording exists to replicate
    /// upstream's input, never to score against it.
    static func nativeUpstream(fps: Double) -> DeviceRecordingCameraFormat {
        DeviceRecordingCameraFormat(
            width: BenchResolution.diagnostic.width,
            height: BenchResolution.diagnostic.height,
            pixelFormat: "luma8_from_32bgra_opencv_bgra2gray_upstream",
            nominalFPS: fps
        )
    }

    var bytesPerFrame: Int { width * height }
}

struct DeviceRecordingIntrinsics: Codable, Equatable, Sendable {
    var fx: Double
    var fy: Double
    var cx: Double
    var cy: Double
    /// Always `ARFrame.camera.intrinsics`; recorded so a reader never has to
    /// guess whether a value was measured or extrapolated.
    var source: String
    /// Result of `ARKitIntrinsicsCrossCheck` at record time.
    var crossCheckPassed: Bool

    enum CodingKeys: String, CodingKey {
        case fx, fy, cx, cy, source
        case crossCheckPassed = "cross_check_passed"
    }

    var asCameraIntrinsics: CameraIntrinsics {
        CameraIntrinsics(fx: fx, fy: fy, cx: cx, cy: cy)
    }
}

struct DeviceRecordingManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let recordingID: String
    var camera: DeviceRecordingCameraFormat
    var intrinsics: DeviceRecordingIntrinsics
    var frameCount: Int
    var imuSampleCount: Int
    /// One streaming SHA-256 over every frame's bytes in capture order.
    ///
    /// Hashing 9,000 files individually would cost 9,000 digests to verify a
    /// single logical object. One rolling digest gives the same integrity
    /// guarantee in one pass, and it is computed incrementally while recording
    /// so it costs nothing extra.
    var framesDigestSHA256: String
    var framesTotalByteCount: Int64
    /// Any dropped frame, dropped IMU sample or short write. A recording with
    /// losses is not a shorter recording; it is an invalid one.
    var lossCount: Int
    /// Loss split by cause. A single total said a recording was lossy without
    /// saying whether the pixel format was wrong, the write queue fell behind,
    /// or the filesystem returned an error -- three unrelated faults with three
    /// unrelated fixes, and no way to tell them apart after the fact.
    var lossFormatMismatch: Int = 0
    var lossWriteQueueFull: Int = 0
    var lossWriteError: Int = 0
    /// High-water mark of frames awaiting write, against a queue depth of 8.
    /// A run that never approached the cap did not lose frames to disk speed.
    var peakInFlight: Int = 0
    /// Slowest single frame write. Names the stall when the queue does fill.
    var slowestWriteMilliseconds: Double = 0
    /// Spread of the focal length across the recording. A wide range means
    /// autofocus moved while capturing and no single value describes the run.
    var focalLengthMinimum: Double = 0
    var focalLengthMaximum: Double = 0
    /// Frames delivered after the archive was sealed. Not loss inside the
    /// recording -- they arrived once it was closed -- but recorded rather than
    /// dropped in silence.
    var lateFramesAfterSeal: Int = 0
    /// 🔴 Bench-only ruler, see `DeviceRecordingFileRole.depthStream`.
    ///
    /// Optional, not defaulted-non-optional, because every recording made
    /// before this existed has no such key and must still decode: Swift's
    /// synthesised `init(from:)` ignores a property's default value and calls
    /// `decode(_:forKey:)`, which throws on a missing key, while an `Optional`
    /// goes through `decodeIfPresent`. `nil` therefore reads as "this recorder
    /// did not know about depth", which is different from
    /// `depthPresent == false` ("it knew, and the device had none").
    var depthPresent: Bool?
    var depthWidth: Int?
    var depthHeight: Int?
    var depthFrameCount: Int?
    /// Always `ARFrame.sceneDepth` when present -- named so a reader never has
    /// to guess whether the numbers came from LiDAR, from
    /// `smoothedSceneDepth` (a filtered estimate, deliberately not used), or
    /// from a monocular network.
    var depthSource: String?
    /// `ARDepthData.confidenceMap` is `nullable` in the SDK header, so a
    /// recording can hold depth with no confidence beside it. A consumer that
    /// filters on `high` must refuse such a recording rather than assume.
    var depthConfidencePresent: Bool?
    /// Depth frames the recorder could not keep (wrong geometry, write error,
    /// or its own backpressure cap).
    ///
    /// 🔴 Deliberately **not** added to `loss_count`: a camera-frame loss
    /// invalidates the recording, because every arm is scored on those frames.
    /// Depth is a bench-only ruler read offline over hundreds of frame pairs,
    /// so a gap in it costs measurements, not validity. Counted rather than
    /// dropped in silence, which is the same rule the camera losses follow.
    var depthDropped: Int?
    var files: [DeviceRecordingFile]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case recordingID = "recording_id"
        case camera, intrinsics, files
        case frameCount = "frame_count"
        case imuSampleCount = "imu_sample_count"
        case framesDigestSHA256 = "frames_digest_sha256"
        case framesTotalByteCount = "frames_total_byte_count"
        case lossCount = "loss_count"
        case lossFormatMismatch = "loss_format_mismatch"
        case lossWriteQueueFull = "loss_write_queue_full"
        case lossWriteError = "loss_write_error"
        case peakInFlight = "peak_in_flight"
        case slowestWriteMilliseconds = "slowest_write_ms"
        case focalLengthMinimum = "focal_length_min"
        case focalLengthMaximum = "focal_length_max"
        case lateFramesAfterSeal = "late_frames_after_seal"
        case depthPresent = "depth_present"
        case depthWidth = "depth_width"
        case depthHeight = "depth_height"
        case depthFrameCount = "depth_frame_count"
        case depthSource = "depth_source"
        case depthConfidencePresent = "depth_confidence_present"
        case depthDropped = "depth_dropped"
    }

    static let supportedSchemaVersion = 1
    static let framesDirectory = "frames"

    /// One append-only stream holding every frame back to back, and the sidecar
    /// index that says where each one starts. This mirrors production's archive
    /// -- photos.hevc plus photos.pwvi in pwva.dart -- rather than the file per
    /// frame this recorder used to write.
    static let framesStreamPath = "frames.bin"
    static let framesIndexPath = "frames.pwvi"
    /// Raw planes held only for the length of the capture, then transcoded into
    /// the archive and removed.
    static let captureScratchPath = "capture_scratch.raw"

    /// 🔴 Bench-only ruler. Same append-only stream + JSONL index shape as
    /// `frames.bin` / `frames.pwvi`, so one reader serves both.
    ///
    /// `depth.bin`      : float32, metres, row-major `depth_width x depth_height`.
    /// `depth_conf.bin` : uint8, `ARConfidenceLevel` (0 low, 1 medium, 2 high).
    /// `depth.pwvi`     : one JSON row per depth frame, `{frame, offset, len,
    ///                    t_ns, w, h, conf_offset, conf_len}`.
    static let depthStreamPath = "depth.bin"
    static let depthConfidencePath = "depth_conf.bin"
    static let depthIndexPath = "depth.pwvi"

    /// `ARDepthData.depthMap` on the LiDAR devices this bench runs on. Recorded
    /// per frame in the index all the same -- this constant is only the
    /// projection used before a capture starts, never what a reader trusts.
    static let expectedDepthWidth = 256
    static let expectedDepthHeight = 192
}

/// A recording replayed as the same event stream `ReplayScheduler` already
/// drives for EuRoC, so the pacing, ordering and delivery path are shared rather
/// than duplicated.
struct DeviceRecordingDataset: Sendable {
    let recordingID: String
    let camera: DeviceRecordingCameraFormat
    let intrinsics: DeviceRecordingIntrinsics
    let events: [ReplayEvent]
    /// ARKit's trajectory over the identical frames. A same-input system
    /// reference for comparison; never ground truth, and never an accuracy
    /// denominator.
    let arkitReference: [TimedPose]

    var inputCameraCount: Int { 1 }
}

/// `LocalizedError`, not just `CustomStringConvertible`.
///
/// Swift bridges a bare `Error` to NSError, and `localizedDescription` then
/// yields "The operation couldn't be completed. (DeviceRecordingError error 12.)"
/// -- which is what the operator actually saw when a recording was refused for
/// lack of disk space. Every diagnosis this type can offer was being discarded
/// at the last step.
enum DeviceRecordingError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case unsupportedSchemaVersion(Int)
    case invalidRecordingID
    case resolutionIsNotScoring(width: Int, height: Int)
    case emptyRecording
    case lossyRecording(lossCount: Int)
    case frameCountMismatch(declared: Int, indexed: Int)
    case missingFrame(String)
    case frameSizeMismatch(path: String, expected: Int, actual: Int)
    case framesDigestMismatch(expected: String, actual: String)
    case fileHashMismatch(path: String, expected: String, actual: String)
    case unsafeRelativePath(String)
    case missingRequiredRole(DeviceRecordingFileRole)
    case timestampRegression(path: String, previous: Int64, current: Int64)
    case malformedCSV(path: String, line: Int, reason: String)
    case intrinsicsCrossCheckFailed
    /// The session ended without a single frame, so there are no intrinsics to
    /// record. Distinct from a failed cross-check, which this used to be
    /// reported as -- sending an investigation after the camera calibration when
    /// the camera had simply never delivered.
    case noFramesCaptured
    case encoderUnavailable
    case encodeFailed(frame: Int, status: Int)
    case decoderUnavailable
    case decodeFailed(status: Int)
    case insufficientFreeSpace(requiredBytes: Int64, availableBytes: Int64)
    /// A depth frame arrived with a different geometry than the first one. The
    /// stream is fixed-stride by construction, so a size change would silently
    /// shear every later frame the way a camera stride change would.
    case depthGeometryChanged(expected: String, actual: String)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .unsupportedSchemaVersion(let v): "unsupported device recording schema version \(v)"
        case .invalidRecordingID: "recording_id must not be empty"
        case .resolutionIsNotScoring(let w, let h):
            "recording is \(w)x\(h); only \(BenchResolution.scoring.width)x\(BenchResolution.scoring.height) may be scored"
        case .emptyRecording: "recording has no camera or IMU events"
        case .lossyRecording(let n):
            "recording declares \(n) losses; a lossy recording is invalid, not shorter"
        case .frameCountMismatch(let d, let i): "frame_count \(d) does not match \(i) indexed frames"
        case .missingFrame(let p): "missing frame file: \(p)"
        case .frameSizeMismatch(let p, let e, let a): "frame \(p) is \(a) bytes, expected \(e)"
        case .framesDigestMismatch(let e, let a): "frames digest mismatch: expected \(e), got \(a)"
        case .fileHashMismatch(let p, let e, let a): "SHA-256 mismatch for \(p): expected \(e), got \(a)"
        case .unsafeRelativePath(let p): "unsafe relative path: \(p)"
        case .missingRequiredRole(let r): "missing required file role: \(r.rawValue)"
        case .timestampRegression(let p, let prev, let cur): "timestamp regression in \(p): \(prev) -> \(cur)"
        case .malformedCSV(let p, let l, let r): "malformed CSV \(p):\(l): \(r)"
        case .intrinsicsCrossCheckFailed:
            "ARKit intrinsics cannot describe the frames they arrived with"
        case .noFramesCaptured:
            "the session produced no frames, so there are no intrinsics to record"
        case .encoderUnavailable:
            "VideoToolbox HEVC encoder could not be created"
        case .encodeFailed(let frame, let status):
            "HEVC encode failed for frame \(frame): status \(status)"
        case .decoderUnavailable:
            "VideoToolbox HEVC decoder could not be created from the keyframe"
        case .decodeFailed(let status):
            "HEVC decode failed: status \(status)"
        case .insufficientFreeSpace(let required, let available):
            String(
                format: "存储空间不足:本次录制需要 %.1f GiB(含余量),设备可用 %.1f GiB,还差 %.1f GiB。"
                    + "请清理空间,或改用更短的录制时长。",
                Double(required) / 1_073_741_824,
                Double(available) / 1_073_741_824,
                Double(max(0, required - available)) / 1_073_741_824
            )
        case .depthGeometryChanged(let e, let a):
            "depth frame geometry changed mid-recording: \(e) -> \(a)"
        }
    }
}
