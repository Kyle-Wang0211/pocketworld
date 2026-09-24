import Foundation

enum ActiveVIOEngineSessionError: LocalizedError {
    case queueFull
    case incompatibleInput(String)
    case operation(String, Error)

    var errorDescription: String? {
        switch self {
        case .queueFull:
            return "VIO 输入队列已满。"
        case .incompatibleInput(let detail):
            return "VIO 输入适配器不匹配：\(detail)"
        case .operation(let name, let error):
            return "VIO \(name) 失败：\(error.localizedDescription)"
        }
    }
}

/// One immutable engine selection per run. Basalt and XRSLAM live in separate
/// embedded dynamic frameworks so their pinned OpenCV versions never share a
/// link namespace. A session cannot change engine after creation.
final class ActiveVIOEngineSession {
    /// Temporary: counts frames handed to xrslam during a replay.
    static var xrslamSubmitCount = 0

    private enum Implementation {
        case basalt(BasaltNativeSession)
        case xrslam(XRSLAMNativeSession)
    }

    let backend: BenchBackend
    private let implementation: Implementation

    static func backendAvailable(_ backend: BenchBackend) -> Bool {
        switch backend {
        case .basalt: return basalt_bench_backend_available() == 1
        case .xrslam: return xrslam_bench_backend_available() == 1
        default: return false
        }
    }

    init(
        backend: BenchBackend,
        configURL: URL,
        calibrationURL: URL,
        imageWidth: Int,
        imageHeight: Int
    ) throws {
        self.backend = backend
        do {
            switch backend {
            case .basalt:
                implementation = .basalt(try BasaltNativeSession(
                    configURL: configURL,
                    calibrationURL: calibrationURL
                ))
            case .xrslam:
                implementation = .xrslam(try XRSLAMNativeSession(
                    configURL: configURL,
                    calibrationURL: calibrationURL,
                    imageWidth: imageWidth,
                    imageHeight: imageHeight
                ))
            default:
                throw ActiveVIOEngineSessionError.incompatibleInput(
                    "ARKit reference uses its isolated ARSession adapter"
                )
            }
        } catch {
            throw ActiveVIOEngineSessionError.operation("create", error)
        }
    }

    func submitIMU(_ sample: PairedIMUSample) throws {
        guard case .basalt(let session) = implementation else {
            throw ActiveVIOEngineSessionError.incompatibleInput(
                "XRSLAM requires separate raw events"
            )
        }
        try performBasalt("submit_paired_imu") { try session.submitIMU(sample) }
    }

    func submitIMU(_ event: RawIMUEvent) throws {
        guard case .xrslam(let session) = implementation else {
            throw ActiveVIOEngineSessionError.incompatibleInput(
                "Basalt requires gyro-driven paired IMU"
            )
        }
        try performXRSLAM("submit_raw_imu") { try session.submitIMU(event) }
    }

    func submitIMU(_ sample: EuRoCIMUSample) throws {
        switch implementation {
        case .basalt(let session):
            try performBasalt("submit_replay_imu") { try session.submitIMU(sample) }
        case .xrslam(let session):
            try performXRSLAM("submit_replay_imu") { try session.submitIMU(sample) }
        }
    }

    func submitCamera(
        _ frame: MonochromeCameraFrame,
        acceptedNanoseconds: UInt64
    ) throws {
        switch implementation {
        case .basalt(let session):
            try performBasalt("submit_live_camera") {
                try session.submitCamera(frame, acceptedNanoseconds: acceptedNanoseconds)
            }
        case .xrslam(let session):
            try performXRSLAM("submit_live_camera") {
                try session.submitCamera(frame, acceptedNanoseconds: acceptedNanoseconds)
            }
        }
    }

    /// A device recording carries raw luma inside one append-only stream, so a
    /// frame is a byte range and there is nothing to decode -- the only check
    /// that matters is that the range is exactly one frame long. EuRoC frames
    /// are encoded images in files of their own, and are told apart by having no
    /// range. The discriminator used to be a `.y` file extension, which stopped
    /// meaning anything once the frames moved into a single stream.
    /// Deterministic box downscale by [factor]. Used only by the diagnostic
    /// replay, so a failure at full resolution can be told apart from a failure
    /// of the algorithm itself.
    static func downscale(_ image: GrayscaleImage, by factor: Int) -> GrayscaleImage {
        let w = image.width / factor, h = image.height / factor
        var out = [UInt8](repeating: 0, count: w * h)
        image.pixels.withUnsafeBytes { src in
            let p = src.bindMemory(to: UInt8.self)
            for y in 0..<h {
                for x in 0..<w {
                    var sum = 0
                    for dy in 0..<factor {
                        let row = (y * factor + dy) * image.bytesPerRow
                        for dx in 0..<factor { sum += Int(p[row + x * factor + dx]) }
                    }
                    out[y * w + x] = UInt8(sum / (factor * factor))
                }
            }
        }
        return GrayscaleImage(width: w, height: h, bytesPerRow: w, pixels: Data(out))
    }

    /// Reads a replay frame and returns it at the engine's input size.
    ///
    /// The archive holds frames at the recording's own size. Reading one at the
    /// engine's downscaled size makes the raw-plane length check fail, and the
    /// full plane is then handed to the HEVC decoder, which cannot build a
    /// decoder from it. Both engines go through here so the correction cannot
    /// be applied to one arm and not the other -- which is what left Basalt
    /// with no measurement at the downscaled size at all.
    private static func loadReplayImageAtEngineSize(
        _ frame: EuRoCCameraFrame,
        width: Int,
        height: Int
    ) throws -> GrayscaleImage {
        let factor = BenchResolution.diagnosticDownscaleRequested
            ? BenchResolution.diagnosticDownscaleFactor : 1
        var image = try loadReplayImage(
            frame, width: width * factor, height: height * factor
        )
        if factor > 1 { image = downscale(image, by: factor) }
        return image
    }

    private static func loadReplayImage(
        _ frame: EuRoCCameraFrame,
        width: Int,
        height: Int
    ) throws -> GrayscaleImage {
        if let accessUnits = frame.camera0AccessUnits {
            return try RawLumaFrameLoader.decode(
                frame.camera0ImageURL,
                format: DeviceRecordingCameraFormat(
                    width: width,
                    height: height,
                    pixelFormat: "luma8_from_420f_full_range",
                    nominalFPS: BenchResolution.scoringFramesPerSecond
                ),
                accessUnits: accessUnits
            )
        }
        return try GrayscaleImageLoader.load(
            frame.camera0ImageURL,
            expectedWidth: width,
            expectedHeight: height
        )
    }

    func submitReplayCamera(
        _ frame: EuRoCCameraFrame,
        acceptedNanoseconds: UInt64,
        width: Int,
        height: Int
    ) throws {
        let isRaw = frame.camera0AccessUnits != nil
        switch implementation {
        case .basalt(let session):
            let image: GrayscaleImage
            do {
                image = try Self.loadReplayImageAtEngineSize(
                    frame, width: width, height: height
                )
            } catch {
                throw ActiveVIOEngineSessionError.operation("decode_replay_camera", error)
            }
            try performBasalt("submit_replay_camera") {
                try session.submitCamera(
                    images: [image],
                    timestampNanoseconds: frame.timestampNanoseconds,
                    acceptedNanoseconds: acceptedNanoseconds
                )
            }
        case .xrslam(let session):
            // The pinned EuRoC path is kept byte-for-byte for the EuRoC channel;
            // a recorded raw plane has no file format for it to open, so it goes
            // through the same in-memory submission Basalt uses.
            if isRaw {
                let image = try Self.loadReplayImageAtEngineSize(
                    frame, width: width, height: height
                )
                // Temporary instrumentation: a replay produced no poses at all
                // and no progress, and there was no way to tell whether frames
                // were reaching the engine or the engine was not returning.
                let seq = Self.xrslamSubmitCount
                Self.xrslamSubmitCount += 1
                if seq < 5 || seq % 100 == 0 {
                    NSLog("[VIOBench][xrslam] submit #%d %dx%d -> engine",
                          seq, image.width, image.height)
                }
                try performXRSLAM("submit_device_recording_camera") {
                    try session.submitCamera(
                        images: [image],
                        timestampNanoseconds: frame.timestampNanoseconds,
                        acceptedNanoseconds: acceptedNanoseconds
                    )
                }
                if seq < 5 || seq % 100 == 0 {
                    NSLog("[VIOBench][xrslam] submit #%d returned", seq)
                }
            } else {
                try performXRSLAM("submit_official_euroc_camera") {
                    try session.submitEuRoCCameraFile(
                        frame.camera0ImageURL,
                        timestampNanoseconds: frame.timestampNanoseconds,
                        acceptedNanoseconds: acceptedNanoseconds
                    )
                }
            }
        }
    }

    /// xrslam only: the IMU-propagated pose, polled on a timer instead of once per frame.
    /// Basalt exposes no equivalent, so its arm keeps the per-frame path.
    func queryPose() throws -> NativePoseSample? {
        switch implementation {
        case .basalt: return nil
        case .xrslam(let session):
            return try performXRSLAM("query_pose") { try session.queryPose() }
        }
    }

    func pollPose() throws -> NativePoseSample? {
        switch implementation {
        case .basalt(let session):
            return try performBasalt("poll_pose") { try session.pollPose() }
        case .xrslam(let session):
            return try performXRSLAM("poll_pose") { try session.pollPose() }
        }
    }

    func snapshot() throws -> VIOEngineSnapshot {
        switch implementation {
        case .basalt(let session):
            return try performBasalt("snapshot") { try session.snapshot() }
        case .xrslam(let session):
            return try performXRSLAM("snapshot") { try session.snapshot() }
        }
    }

    func sealDrainStop() throws {
        switch implementation {
        case .basalt(let session):
            try performBasalt("seal_drain_stop") { try session.sealDrainStop() }
        case .xrslam(let session):
            try performXRSLAM("seal_drain_stop") { try session.sealDrainStop() }
        }
    }

    func requestStop() {
        switch implementation {
        case .basalt(let session): session.requestStop()
        case .xrslam(let session): session.requestStop()
        }
    }

    /// Releases the selected bridge handle before the process run lease is
    /// handed to another arm. Both concrete close operations are idempotent.
    func close() {
        switch implementation {
        case .basalt(let session): session.close()
        case .xrslam(let session): session.close()
        }
    }

    private func performBasalt<T>(
        _ name: String,
        _ body: () throws -> T
    ) throws -> T {
        do { return try body() }
        catch let error as BasaltNativeSessionError {
            if case .status(_, let code) = error, code == BASALT_BENCH_QUEUE_FULL {
                throw ActiveVIOEngineSessionError.queueFull
            }
            throw ActiveVIOEngineSessionError.operation(name, error)
        } catch {
            throw ActiveVIOEngineSessionError.operation(name, error)
        }
    }

    private func performXRSLAM<T>(
        _ name: String,
        _ body: () throws -> T
    ) throws -> T {
        do { return try body() }
        catch let error as XRSLAMNativeSessionError {
            if case .status(_, let code) = error, code == XRSLAM_BENCH_QUEUE_FULL {
                throw ActiveVIOEngineSessionError.queueFull
            }
            throw ActiveVIOEngineSessionError.operation(name, error)
        } catch {
            throw ActiveVIOEngineSessionError.operation(name, error)
        }
    }
}
