import AVFoundation
import CoreMedia
import CoreMotion
import CoreVideo
import Foundation
import simd

/// Hardware sensor transport only. This type never creates ARKit, reads a pose,
/// performs VIO policy, touches disk, or dispatches UI work from a callback.
public final class LiveSensorTransport: NSObject, @unchecked Sendable {
    public enum TransportError: Error, Equatable {
        case cameraPermissionDenied
        case cameraUnavailable
        case cameraFormatUnavailable(width: Int32, height: Int32, rateHz: Int32)
        case cannotCreateCameraInput
        case cannotAddCameraInput
        case cannotAddCameraOutput
        case gyroscopeUnavailable
        case accelerometerUnavailable
        case invalidHostClock
        case invalidLifecycle
    }

    public let configuration: SensorTransportConfiguration
    public let clockMapper: MonotonicClockMapper
    public let imuDeliveryMode: IMUDeliveryMode
    public let accounting = SensorTransportAccounting()
    public let cameraHandoff: BoundedSensorHandoff<MonochromeCameraFrame>
    public let imuHandoff: BoundedSensorHandoff<PairedIMUSample>
    public let xrslamSensorHandoff: BoundedSensorHandoff<XRSLAMLiveSensorEvent>

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    /// Lens position actually locked, or nil when focus was left untouched.
    /// The format receipt carries it either way, so a run says which it was.
    private var lockedLensPosition: Float?
    /// What the output actually offered, comma separated fourCCs. Carried
    /// into the receipt so a format refusal is readable after the fact.
    private var availablePixelFormats: String = ""

    /// Set to persist this capture. Frames are recorded from the pooled gray
    /// plane the engine is handed, not from a second conversion of the camera
    /// buffer, so the file holds exactly the bytes the engine consumed.
    ///
    /// `record` (the ARKit arm) owns the camera through `ARSession`; this is
    /// the AVFoundation equivalent, and it is what makes a native 640x480
    /// upstream-shaped recording possible at all. iOS grants the rear camera
    /// to one session, so the two can never both be recording.
    var recorder: DeviceRecordingWriter?

    /// The capture device, kept so the frame callback can read
    /// `exposureDuration` for the recording (MARS logger practice: the device
    /// value at callback time, per frame). Set in `configureCamera()`; nil
    /// before it, and the recording then carries no `exposure_s` for those
    /// frames rather than a guessed 0.
    private var cameraDevice: AVCaptureDevice?

    /// Pairs gyroscope and acceleration for `imu.csv` only.
    ///
    /// In `xrslamRawSeparateEvents` the engine receives the two streams
    /// separately, exactly as upstream's own `Motion.swift` pushes them, and
    /// the main `imuAssembler` is not used at all. But `imu.csv` is a paired
    /// schema, so recording needs pairs. Rather than invent a pairing rule,
    /// this runs the same `GyroDrivenIMUAssembler` the Basalt arm already
    /// ships, on a separate instance, fed only when a recorder is attached --
    /// so the engine's input is untouched and no counter shifts on runs that
    /// are not recording. The run receipt names the representation, because
    /// pairs are not what the engine saw.
    private let recordingIMUAssemblerLock = NSLock()
    private var recordingIMUAssembler: GyroDrivenIMUAssembler?

    /// `-PWOfficialBGRA` captures 32BGRA and reaches gray through upstream's
    /// own conversion instead of taking the ISP's luma plane. It is the last of
    /// the three places this transport still differs from
    /// xrslam-ios/visualizer's capture; the other two -- resolution/rate and the
    /// raw CoreMotion feeds -- already match. Default off, so an unflagged run
    /// is the 420f path this bench has always used.
    static func wantsOfficialBGRA() -> Bool {
        ProcessInfo.processInfo.arguments.contains("-PWOfficialBGRA")
    }

    /// `-PWLockLens [position]`. Bare flag means 1.0 -- the far end, where a
    /// room-scale scan spends its time. Out-of-range or unparseable values are
    /// refused rather than clamped: a typo has to be visible, not silently
    /// become a different experiment.
    static func requestedLensPosition() -> Float? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-PWLockLens") else { return nil }
        guard i + 1 < args.count, !args[i + 1].hasPrefix("-") else { return 1.0 }
        guard let value = Float(args[i + 1]) else {
            preconditionFailure("-PWLockLens: \(args[i + 1]) is not a number")
        }
        precondition(value >= 0 && value <= 1,
                     "-PWLockLens: \(value) outside [0,1]")
        return value
    }
    private let motionManager = CMMotionManager()
    private let cameraCallbackQueue = DispatchQueue(
        label: "com.kyle.viobench.sensor.camera",
        qos: .userInitiated
    )
    private let controlQueue = DispatchQueue(
        label: "com.kyle.viobench.sensor.control",
        qos: .userInitiated
    )
    private lazy var motionCallbackQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.kyle.viobench.sensor.motion"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 1
        queue.underlyingQueue = cameraCallbackQueue
        return queue
    }()

    private let lifecycleLock = NSLock()
    private let imuAssemblerLock = NSLock()
    private var lifecycle = SensorTransportLifecycle()
    private var notificationTokens: [NSObjectProtocol] = []
    /// Pooled luma planes; see `LumaPlanePool` for the TN2445 / ImageReader /
    /// V4L2 contract it implements.
    public let lumaPool: LumaPlanePool

    /// `-PWLumaPlanes N`: depth of the luma pool, default 3. Reported in the
    /// diagnostics as `luma_pool_planes`, so a run always states the depth it
    /// actually parsed rather than the one the command line asked for.
    static let lumaPlaneCount: Int = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-PWLumaPlanes"), i + 1 < args.count,
              let n = Int(args[i + 1]), n >= 1, n <= 64 else { return 3 }
        return n
    }()
    private var cameraTimestamps = TimestampSequenceValidator()
    private var imuAssembler: GyroDrivenIMUAssembler
    private var captureFormatReceipt: LiveCaptureFormatReceipt?

    public init(
        configuration: SensorTransportConfiguration = .live,
        imuDeliveryMode: IMUDeliveryMode = .basaltGyroDrivenPaired,
        clockMapper: MonotonicClockMapper
    ) {
        self.configuration = configuration
        self.imuDeliveryMode = imuDeliveryMode
        self.clockMapper = clockMapper
        cameraHandoff = BoundedSensorHandoff(
            capacity: configuration.cameraQueueCapacity
        )
        imuHandoff = BoundedSensorHandoff(
            capacity: configuration.imuQueueCapacity
        )
        xrslamSensorHandoff = BoundedSensorHandoff(
            capacity: configuration.cameraQueueCapacity
                + configuration.imuQueueCapacity * 2
        )
        // The real bound on camera frames in flight. The handoff above is sized
        // for camera + IMU events together, so it never bounded camera buffers
        // on its own; the pool does, and it bounds the bytes the bench owns
        // rather than the camera buffers it borrows.
        //
        // Depth is the whole point. TN2445 describes the shape AVFoundation
        // itself uses -- `alwaysDiscardsLateVideoFrames` "enforces a buffer
        // queue size of 1 ... it will throw out the current frame, and append
        // the new one. In effect, it is always giving you the latest frame."
        // Three is that plus the two planes a non-stalling producer/consumer
        // needs: one the engine is reading, one queued, one being filled.
        //
        // With a pool this shallow, "refuse while full" *is* Android's
        // `acquireLatestImage` policy in effect: no stale frame can sit in the
        // queue, so whichever frame arrives the instant a plane frees up is the
        // freshest one available. Staleness is bounded by the depth, not by the
        // choice of which frame to discard -- which is why this needs no
        // eviction machinery and no race with a consumer mid-read.
        //
        // Measured at depth 8: p95 capture-to-pose 836 ms (a frame waits up to
        // 8 / 20 fps = 400 ms). Overridable so 2 / 3 / 8 can be settled by
        // measurement in one install rather than by argument.
        lumaPool = LumaPlanePool(
            planeCount: Self.lumaPlaneCount,
            planeCapacityBytes: Int(configuration.cameraWidth)
                * Int(configuration.cameraHeight)
        )
        imuAssembler = GyroDrivenIMUAssembler(
            pendingGyroscopeCapacity: configuration.pendingGyroscopeCapacity
        )
        super.init()
    }

    /// Samples the Core Media host clock around `systemUptime`, creating the
    /// sole production clock mapping used by both capture paths.
    public convenience init(
        configuration: SensorTransportConfiguration = .live,
        imuDeliveryMode: IMUDeliveryMode = .basaltGyroDrivenPaired
    ) throws {
        let hostBefore = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let uptime = ProcessInfo.processInfo.systemUptime
        let hostAfter = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let hostAnchor = (hostBefore + hostAfter) * 0.5
        let nanoseconds = hostAnchor * 1_000_000_000.0
        guard hostAnchor.isFinite,
              hostAnchor >= 0,
              nanoseconds.isFinite,
              nanoseconds >= 0,
              nanoseconds < Double(UInt64.max) else {
            throw TransportError.invalidHostClock
        }
        self.init(
            configuration: configuration,
            imuDeliveryMode: imuDeliveryMode,
            clockMapper: MonotonicClockMapper(
                cameraHostTimeAnchorSeconds: hostAnchor,
                coreMotionUptimeAnchorSeconds: uptime,
                monotonicAnchorNanoseconds: UInt64(
                    nanoseconds.rounded(.toNearestOrAwayFromZero)
                )
            )
        )
    }

    /// Display-only tap on frames already handed to the engine.
    var previewTap: PreviewFrameTap?

    public var state: SensorTransportLifecycle.State {
        lifecycleLock.withLock { lifecycle.state }
    }

    /// Configures and starts both hardware producers. Call this from a control
    /// thread; `AVCaptureSession.startRunning()` is intentionally not hidden in
    /// a sensor callback or main/UI dispatch.
    public func start() throws {
        try transition(to: .starting)
        do {
            try configureCamera()
            registerCaptureNotifications()
            try startMotionUpdates()
            captureSession.startRunning()
            try transition(to: .running)
        } catch {
            moveToFailedIfPossible()
            stop()
            throw error
        }
    }

    /// Stops producers first, then seals both channels. Items accepted
    /// before sealing remain available until the consumer drains them.
    public func stop() {
        let shouldStop = lifecycleLock.withLock { () -> Bool in
            switch lifecycle.state {
            case .starting, .running, .interrupted, .failed:
                try? lifecycle.transition(to: .stopping)
                return true
            case .idle, .stopping, .sealed, .drained:
                return false
            }
        }
        guard shouldStop else { return }

        motionManager.stopGyroUpdates()
        motionManager.stopAccelerometerUpdates()
        captureSession.stopRunning()
        motionCallbackQueue.waitUntilAllOperationsAreFinished()
        cameraCallbackQueue.sync {}
        unregisterCaptureNotifications()

        if imuDeliveryMode == .basaltGyroDrivenPaired {
            _ = imuAssemblerLock.withLock { imuAssembler.seal() }
        }
        cameraHandoff.seal()
        imuHandoff.seal()
        xrslamSensorHandoff.seal()
        try? transition(to: .sealed)
    }

    public func drainCamera(maxCount: Int) -> BoundedSensorHandoff<MonochromeCameraFrame>.DrainBatch {
        let batch = cameraHandoff.drain(maxCount: maxCount)
        updateDrainedStateIfNeeded()
        return batch
    }

    /// This is the only estimator-facing IMU channel. Each item has official
    /// gyro-driven time semantics and an interpolated acceleration value.
    public func drainIMU(maxCount: Int) -> BoundedSensorHandoff<PairedIMUSample>.DrainBatch {
        let batch = imuHandoff.drain(maxCount: maxCount)
        updateDrainedStateIfNeeded()
        return batch
    }

    /// Official XRSLAM live ordering: all three sensor callback types leave
    /// one serial producer queue through one bounded handoff.
    public func drainXRSLAMSensorEvents(
        maxCount: Int
    ) -> BoundedSensorHandoff<XRSLAMLiveSensorEvent>.DrainBatch {
        let batch = xrslamSensorHandoff.drain(maxCount: maxCount)
        updateDrainedStateIfNeeded()
        return batch
    }

    public func snapshot() -> LiveSensorTransportSnapshot {
        LiveSensorTransportSnapshot(
            state: state,
            accounting: accounting.snapshot(),
            imuDeliveryMode: imuDeliveryMode,
            imuAssembly: imuAssemblerLock.withLock { imuAssembler.receipt },
            cameraHandoff: cameraHandoff.snapshot(),
            imuHandoff: imuHandoff.snapshot(),
            xrslamSensorHandoff: xrslamSensorHandoff.snapshot(),
            captureFormat: lifecycleLock.withLock { captureFormatReceipt },
            lumaPoolPlanes: lumaPool.planeCount,
            lumaPoolPeakHeld: lumaPool.peakHeld,
            lumaPoolExhaustedDrops: lumaPool.exhaustedCount,
            lumaPoolSampleMeanLuma: lumaPool.sampleMeanLuma,
            lumaPoolSourceStride: lumaPool.observedSourceStride
        )
    }

    private func configureCamera() throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw TransportError.cameraPermissionDenied
        }
        guard let device = AVCaptureDevice.default(
            .builtInWideAngleCamera,
            for: .video,
            position: .back
        ) else {
            throw TransportError.cameraUnavailable
        }
        cameraDevice = device

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw TransportError.cannotCreateCameraInput
        }

        let officialBGRA = LiveSensorTransport.wantsOfficialBGRA()
        // Two different formats, and conflating them is what broke the first
        // `-PWOfficialBGRA` build. `AVCaptureDevice.Format` describes what the
        // SENSOR produces -- on iOS always a biplanar YpCbCr subtype ('420f',
        // '420v', 'x420'). 32BGRA is a conversion `AVCaptureVideoDataOutput`
        // performs on the way out; no device format ever carries that subtype,
        // so filtering `device.formats` by it matched nothing and `start()`
        // threw `cameraFormatUnavailable` before a single frame arrived.
        //
        // Upstream is the proof of the split: `xrslam-ios/visualizer/src/
        // Camera.swift:46` sets `kCVPixelFormatType_32BGRA` on
        // `output.videoSettings` and *never* touches `device.activeFormat` --
        // it only sets a session preset. This keeps upstream's split and adds
        // back the explicit device-format selection the bench needs for a
        // frozen resolution identity, which a preset cannot give.
        let deviceSubtype = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        let outputPixelFormat = officialBGRA
            ? kCVPixelFormatType_32BGRA
            : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        // `availableVideoPixelFormatTypes` is documented as the set this output
        // can currently produce, and an output that is not in a session yet has
        // no input to answer for. The 420f path happened to survive being asked
        // early; 32BGRA did not, and the run failed at start with nothing in the
        // receipt to say why. Ask after the output is connected instead, and
        // print the list when the answer is no so the next reader is not left
        // guessing the way this one was.

        captureSession.beginConfiguration()
        var configurationIsOpen = true
        defer {
            if configurationIsOpen { captureSession.commitConfiguration() }
        }
        // Explicit format selection is kept even though the diagnostic
        // resolution has a matching preset: it is the mechanism the replay
        // resolution will need, and selecting by frozen requirements is a
        // stronger identity than trusting a preset to pick.
        guard captureSession.canSetSessionPreset(.inputPriority) else {
            throw TransportError.cameraFormatUnavailable(
                width: configuration.cameraWidth,
                height: configuration.cameraHeight,
                rateHz: configuration.cameraRateHz
            )
        }
        captureSession.sessionPreset = .inputPriority

        guard captureSession.canAddInput(input) else {
            throw TransportError.cannotAddCameraInput
        }
        captureSession.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: cameraCallbackQueue)
        guard captureSession.canAddOutput(videoOutput) else {
            throw TransportError.cannotAddCameraOutput
        }
        captureSession.addOutput(videoOutput)

        // Only now. `availableVideoPixelFormatTypes` answers for an output in a
        // session with an input; an output on its own has nothing to answer for.
        // Asking early happened to work for 420f and did not for 32BGRA, and the
        // run died at start with nothing in the receipt to say why -- the format
        // list lands in the receipt below precisely so the next one does not.
        let supportedPixelFormats = videoOutput.availableVideoPixelFormatTypes
        availablePixelFormats = supportedPixelFormats.map {
            LiveCaptureFormatReceipt.fourCC($0)
        }.joined(separator: ",")
        guard supportedPixelFormats.contains(outputPixelFormat) else {
            throw TransportError.cameraFormatUnavailable(
                width: configuration.cameraWidth,
                height: configuration.cameraHeight,
                rateHz: configuration.cameraRateHz
            )
        }
        guard let connection = videoOutput.connection(with: .video),
              connection.isVideoRotationAngleSupported(0) else {
            throw TransportError.cameraFormatUnavailable(
                width: configuration.cameraWidth,
                height: configuration.cameraHeight,
                rateHz: configuration.cameraRateHz
            )
        }
        connection.videoRotationAngle = 0
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .off
        }
        // Ask the camera to attach the intrinsics it measured for the format it
        // actually selected. The calibration this run feeds the engines is the
        // frozen 640x480 one scaled by the resolution ratio, and that scaling is
        // only sound if the two formats share a field of view. With delivery on,
        // the run carries the camera's own answer next to the assumption, so a
        // reader can check it instead of trusting it.
        if connection.isCameraIntrinsicMatrixDeliverySupported {
            connection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }

        captureSession.commitConfiguration()
        configurationIsOpen = false

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            // `device.formats.first` stays forbidden: its ordering is not a
            // stable experiment identity. Formats are instead filtered by the
            // frozen requirements and ranked by a documented rule, and the number
            // of candidates is receipted so a reader can see whether the match
            // was unique.
            let candidates = device.formats.filter { candidate in
                let dimensions = CMVideoFormatDescriptionGetDimensions(
                    candidate.formatDescription
                )
                let subtype = CMFormatDescriptionGetMediaSubType(
                    candidate.formatDescription
                )
                return dimensions.width == configuration.cameraWidth
                    && dimensions.height == configuration.cameraHeight
                    && subtype == deviceSubtype
                    && candidate.videoSupportedFrameRateRanges.contains {
                        $0.minFrameRate <= Double(configuration.cameraRateHz)
                            && $0.maxFrameRate >= Double(configuration.cameraRateHz)
                    }
            }
            // Prefer an unbinned sensor readout: binning trades resolution for
            // low light, and this bench is about what the full readout supports.
            let preferred = candidates.filter { !$0.isVideoBinned }
            let ranked = (preferred.isEmpty ? candidates : preferred).sorted { lhs, rhs in
                let l = lhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                let r = rhs.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                if l != r { return l > r }
                return Double(lhs.videoFieldOfView) > Double(rhs.videoFieldOfView)
            }
            guard let format = ranked.first else {
                throw TransportError.cameraFormatUnavailable(
                    width: configuration.cameraWidth,
                    height: configuration.cameraHeight,
                    rateHz: configuration.cameraRateHz
                )
            }
            device.activeFormat = format
            let dimensions = CMVideoFormatDescriptionGetDimensions(
                format.formatDescription
            )
            // Only now, and this ordering is load-bearing. AVFoundation
            // validates `videoSettings` against the SOURCE DEVICE's
            // activeFormat and raises
            //   NSInvalidArgumentException "Video settings dimensions must
            //   maintain the source device activeFormat's aspect ratio"
            // -- an Objective-C exception, so it is not catchable from Swift
            // and it kills the process with SIGABRT rather than throwing.
            // Setting it before `addOutput` skipped the check (an output with
            // no source has nothing to validate against); setting it after
            // `addOutput` but before `activeFormat` validated 640x480 (4:3)
            // against whatever format the device happened to boot with (16:9)
            // and aborted. Set it once the device is on the format these
            // dimensions came from, where the ratio matches by construction.
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: outputPixelFormat,
                kCVPixelBufferWidthKey as String: Int(dimensions.width),
                kCVPixelBufferHeightKey as String: Int(dimensions.height),
            ]
            guard dimensions.width == configuration.cameraWidth,
                  dimensions.height == configuration.cameraHeight,
                  let range = format.videoSupportedFrameRateRanges.first(where: {
                      $0.minFrameRate <= Double(configuration.cameraRateHz)
                          && $0.maxFrameRate >= Double(configuration.cameraRateHz)
                  }) else {
                throw TransportError.cameraFormatUnavailable(
                    width: configuration.cameraWidth,
                    height: configuration.cameraHeight,
                    rateHz: configuration.cameraRateHz
                )
            }
            let duration = CMTime(value: 1, timescale: configuration.cameraRateHz)
            device.activeVideoMinFrameDuration = duration
            device.activeVideoMaxFrameDuration = duration

            // Upstream's own capture class locks the lens on request --
            // xrslam-ios/visualizer/src/Camera.swift exposes setFocus(_:) as
            //     device.setFocusModeLocked(lensPosition: value)
            // and its per-device calibration is a single frozen focal length,
            // which only describes every frame if the lens does not move. This
            // transport never touched focus, so it ran whatever the system
            // defaulted to, and the engine was handed one focal length for the
            // whole session regardless: across the shared recording ARKit
            // reported fx from 1280.37 to 1385.30, a 7.87% spread.
            //
            // `-PWLockLens <p>` locks at lens position p in [0,1]; bare
            // `-PWLockLens` uses 1.0, the far end, which is where a room-scale
            // scan spends its time. Absent the flag nothing is touched, so a
            // run without it is the transport as it has always been.
            if let requested = LiveSensorTransport.requestedLensPosition() {
                guard device.isFocusModeSupported(.locked) else {
                    throw TransportError.cameraFormatUnavailable(
                        width: configuration.cameraWidth,
                        height: configuration.cameraHeight,
                        rateHz: configuration.cameraRateHz
                    )
                }
                device.setFocusModeLocked(lensPosition: requested,
                                          completionHandler: nil)
                lockedLensPosition = requested
            }
            let receipt = LiveCaptureFormatReceipt(
                cameraDeviceType: device.deviceType.rawValue,
                activeFormatIndex: device.formats.firstIndex(where: { $0 === format }) ?? -1,
                activeFormatMediaSubtype: LiveCaptureFormatReceipt.fourCC(
                    CMFormatDescriptionGetMediaSubType(format.formatDescription)
                ),
                outputPixelFormat: LiveCaptureFormatReceipt.fourCC(outputPixelFormat),
                width: dimensions.width,
                height: dimensions.height,
                selectedFramesPerSecond: configuration.cameraRateHz,
                supportedFrameRateRange: "\(range.minFrameRate)...\(range.maxFrameRate)",
                fieldOfViewDegrees: Double(format.videoFieldOfView),
                lockedLensPosition: lockedLensPosition.map(Double.init) ?? -1,
                zoomFactor: Double(device.videoZoomFactor),
                rotationDegrees: connection.videoRotationAngle,
                preferredStabilizationMode: Int(connection.preferredVideoStabilizationMode.rawValue),
                activeStabilizationMode: Int(connection.activeVideoStabilizationMode.rawValue),
                sessionPreset: AVCaptureSession.Preset.inputPriority.rawValue,
                matchingFormatCount: candidates.count,
                availablePixelFormats: availablePixelFormats,
                grayscaleConversion: officialBGRA
                    ? "bgra32_opencv_cvtcolor_bgra2gray_upstream"
                    : "nv12_full_range_luma_plane_direct",
                xrslamPixelPipelineDivergence: "pinned_xrslam_sample_requests_32bgra_then_opencv_bgra2gray"
            )
            lifecycleLock.withLock { captureFormatReceipt = receipt }
        } catch {
            throw TransportError.cameraFormatUnavailable(
                width: configuration.cameraWidth,
                height: configuration.cameraHeight,
                rateHz: configuration.cameraRateHz
            )
        }
    }

    private func startMotionUpdates() throws {
        guard motionManager.isGyroAvailable else {
            throw TransportError.gyroscopeUnavailable
        }
        guard motionManager.isAccelerometerAvailable else {
            throw TransportError.accelerometerUnavailable
        }

        let interval = 1.0 / configuration.motionRateHz
        motionManager.gyroUpdateInterval = interval
        motionManager.accelerometerUpdateInterval = interval
        motionManager.startGyroUpdates(to: motionCallbackQueue) { [weak self] data, error in
            self?.handleGyroscope(data, error: error)
        }
        motionManager.startAccelerometerUpdates(to: motionCallbackQueue) { [weak self] data, error in
            self?.handleAccelerometer(data, error: error)
        }
    }

    /// Logged once: what the camera says its intrinsics are for the selected
    /// format, so the scaled calibration can be checked against a measurement.
    private var reportedIntrinsics = false

    fileprivate func reportIntrinsicsIfNeeded(_ sampleBuffer: CMSampleBuffer) {
        // The log line is once; the recording keeps every frame's, because the
        // ARKit recorder does and production's per-photo sidecar does. Autofocus
        // moves fx within a session, so a single sample cannot describe a file.
        guard !reportedIntrinsics || recorder != nil else { return }
        guard let raw = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
            attachmentModeOut: nil
        ) as? Data, raw.count >= MemoryLayout<Float>.size * 9 else { return }
        let firstReport = !reportedIntrinsics
        reportedIntrinsics = true
        // The attachment is a matrix_float3x3 in column-major order:
        // columns are (fx,0,0), (0,fy,0), (cx,cy,1).
        let matrix = raw.withUnsafeBytes { $0.load(as: matrix_float3x3.self) }
        let reported = CameraIntrinsics(
            fx: Double(matrix.columns.0.x),
            fy: Double(matrix.columns.1.y),
            cx: Double(matrix.columns.2.x),
            cy: Double(matrix.columns.2.y)
        )
        if firstReport {
            NSLog("[VIOBench] camera-reported intrinsics fx=%.3f fy=%.3f cx=%.3f cy=%.3f",
                  reported.fx, reported.fy, reported.cx, reported.cy)
        }
        guard let recorder else { return }
        // Compared against upstream's own 640x480 config, unscaled. The default
        // comparison is that config multiplied by 3 for the 1920x1440 scoring
        // format, which says nothing about a frame that is natively 640x480.
        try? recorder.recordIntrinsics(
            reported,
            timestampSeconds: CMTimeGetSeconds(
                CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            ),
            // Same callback, same frame: the PTS above is exposure start, this
            // is how long it lasted, so a replay can move to the midpoint.
            exposureSeconds: cameraDevice.map { CMTimeGetSeconds($0.exposureDuration) },
            source: "AVCaptureConnection.cameraIntrinsicMatrixDelivery",
            expected: ARKitIntrinsicsCrossCheck.frozenUpstream640x480
        )
    }

    private func handleGyroscope(_ data: CMGyroData?, error: Error?) {
        if error != nil {
            accounting.recordMotionError()
            failAndScheduleStop()
            return
        }
        guard let data else { return }
        accounting.recordGyroscopeInput()
        guard let timestamp = try? clockMapper.motionNanoseconds(
            uptimeSeconds: data.timestamp
        ) else {
            accounting.recordMotionError()
            failAndScheduleStop()
            return
        }
        let sample = CoreMotionIMUConversion.gyroscopeRadiansPerSecond(
            timestampNanoseconds: timestamp,
            x: data.rotationRate.x,
            y: data.rotationRate.y,
            z: data.rotationRate.z
        )
        if imuDeliveryMode == .xrslamRawSeparateEvents {
            xrslamSensorHandoff.offer(.imu(.gyroscope(sample)))
            recordPairedIMU { $0.ingestGyroscope(sample) }
            return
        }
        let batch = imuAssemblerLock.withLock { imuAssembler.ingestGyroscope(sample) }
        processIMUAssemblyBatch(batch)
    }

    private func handleAccelerometer(_ data: CMAccelerometerData?, error: Error?) {
        if error != nil {
            accounting.recordMotionError()
            failAndScheduleStop()
            return
        }
        guard let data else { return }
        accounting.recordAccelerometerInput()
        guard let timestamp = try? clockMapper.motionNanoseconds(
            uptimeSeconds: data.timestamp
        ) else {
            accounting.recordMotionError()
            failAndScheduleStop()
            return
        }
        if imuDeliveryMode == .xrslamRawSeparateEvents {
            xrslamSensorHandoff.offer(
                .imu(
                    .acceleration(
                        MotionVectorSample(
                            timestampNanoseconds: timestamp,
                            x: data.acceleration.x,
                            y: data.acceleration.y,
                            z: data.acceleration.z
                        )
                    )
                )
            )
            // The recorder's copy is in m/s^2, the unit `imu.csv` documents and
            // every replay consumer expects. The engine gets the raw event
            // above, unchanged -- these are two representations of one sample,
            // not two samples.
            let converted = CoreMotionIMUConversion.accelerationMetersPerSecondSquared(
                timestampNanoseconds: timestamp,
                xInG: data.acceleration.x,
                yInG: data.acceleration.y,
                zInG: data.acceleration.z
            )
            recordPairedIMU { $0.ingestAcceleration(converted) }
            return
        }
        let sample = CoreMotionIMUConversion.accelerationMetersPerSecondSquared(
            timestampNanoseconds: timestamp,
            xInG: data.acceleration.x,
            yInG: data.acceleration.y,
            zInG: data.acceleration.z
        )
        let batch = imuAssemblerLock.withLock { imuAssembler.ingestAcceleration(sample) }
        processIMUAssemblyBatch(batch)
    }

    /// Feeds the recording-only assembler and writes whatever pairs come out.
    /// A no-op when nothing is recording, so the non-recording path keeps the
    /// exact behaviour it had.
    private func recordPairedIMU(
        _ ingest: (inout GyroDrivenIMUAssembler) -> IMUAssemblyBatch
    ) {
        guard let recorder else { return }
        let batch: IMUAssemblyBatch = recordingIMUAssemblerLock.withLock {
            if recordingIMUAssembler == nil {
                recordingIMUAssembler = GyroDrivenIMUAssembler(
                    pendingGyroscopeCapacity: configuration.pendingGyroscopeCapacity
                )
            }
            return ingest(&recordingIMUAssembler!)
        }
        for sample in batch.samples {
            recorder.appendIMU(
                timestampNanoseconds: Int64(sample.timestampNanoseconds),
                gyroscope: (sample.gyroscope.x, sample.gyroscope.y, sample.gyroscope.z),
                acceleration: (
                    sample.acceleration.x, sample.acceleration.y, sample.acceleration.z
                )
            )
        }
    }

    private func processIMUAssemblyBatch(_ batch: IMUAssemblyBatch) {
        if let violation = batch.violation {
            switch violation {
            case .gyroscopeTimestampRegression,
                 .accelerationTimestampRegression,
                 .outputTimestampRegression:
                accounting.recordTimestampRegression()
            case .pendingGyroscopeOverflow:
                accounting.recordMotionError()
            case .inputSealed:
                accounting.recordMotionError()
            }
            failAndScheduleStop()
            return
        }
        for sample in batch.samples {
            imuHandoff.offer(sample)
        }
    }

    private func registerCaptureNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(
            center.addObserver(
                forName: AVCaptureSession.wasInterruptedNotification,
                object: captureSession,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                accounting.recordCaptureInterruption()
                lifecycleLock.withLock {
                    if self.lifecycle.state == .running {
                        try? self.lifecycle.transition(to: .interrupted)
                    }
                }
                failAndScheduleStop()
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: AVCaptureSession.interruptionEndedNotification,
                object: captureSession,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                lifecycleLock.withLock {
                    if self.lifecycle.state == .interrupted {
                        try? self.lifecycle.transition(to: .running)
                    }
                }
            }
        )
        notificationTokens.append(
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: captureSession,
                queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                accounting.recordCaptureRuntimeError()
                failAndScheduleStop()
            }
        )
    }

    private func unregisterCaptureNotifications() {
        let center = NotificationCenter.default
        notificationTokens.forEach(center.removeObserver)
        notificationTokens.removeAll(keepingCapacity: false)
    }

    private func transition(to next: SensorTransportLifecycle.State) throws {
        try lifecycleLock.withLock {
            try lifecycle.transition(to: next)
        }
    }

    private func moveToFailedIfPossible() {
        lifecycleLock.withLock {
            switch lifecycle.state {
            case .starting, .running, .interrupted:
                try? lifecycle.transition(to: .failed)
            case .idle, .failed, .stopping, .sealed, .drained:
                break
            }
        }
    }

    private func failAndScheduleStop() {
        moveToFailedIfPossible()
        controlQueue.async { [weak self] in
            self?.stop()
        }
    }

    private func updateDrainedStateIfNeeded() {
        let activeInputsDrained = imuDeliveryMode == .basaltGyroDrivenPaired
            ? cameraHandoff.state == .drained && imuHandoff.state == .drained
            : xrslamSensorHandoff.state == .drained
        guard activeInputsDrained else {
            return
        }
        lifecycleLock.withLock {
            if lifecycle.state == .sealed {
                try? lifecycle.transition(to: .drained)
            }
        }
    }
}

extension LiveSensorTransport: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        reportIntrinsicsIfNeeded(sampleBuffer)
        accounting.recordCameraInput()
        let officialBGRA = LiveSensorTransport.wantsOfficialBGRA()
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            accounting.recordCameraDrop(.invalidFormat)
            return
        }
        if officialBGRA {
            guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA,
                  !CVPixelBufferIsPlanar(pixelBuffer),
                  CVPixelBufferGetWidth(pixelBuffer) == Int(configuration.cameraWidth),
                  CVPixelBufferGetHeight(pixelBuffer) == Int(configuration.cameraHeight) else {
                accounting.recordCameraDrop(.invalidFormat)
                return
            }
        } else {
            guard CVPixelBufferGetPixelFormatType(pixelBuffer)
                    == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                  CVPixelBufferIsPlanar(pixelBuffer),
                  CVPixelBufferGetPlaneCount(pixelBuffer) > 0,
                  CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) == Int(configuration.cameraWidth),
                  CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) == Int(configuration.cameraHeight) else {
                accounting.recordCameraDrop(.invalidFormat)
                return
            }
        }

        // AVCapture timestamps are expressed on the session synchronization
        // clock. Convert explicitly instead of assuming that clock is already
        // the Core Media host clock used by MonotonicClockMapper.
        guard let synchronizationClock = captureSession.synchronizationClock else {
            accounting.recordCameraDrop(.invalidTimestamp)
            failAndScheduleStop()
            return
        }
        let hostTime = CMSyncConvertTime(
            CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            from: synchronizationClock,
            to: CMClockGetHostTimeClock()
        )
        let hostTimeSeconds = CMTimeGetSeconds(hostTime)
        guard let timestamp = try? clockMapper.cameraNanoseconds(
            hostTimeSeconds: hostTimeSeconds
        ) else {
            accounting.recordCameraDrop(.invalidTimestamp)
            failAndScheduleStop()
            return
        }
        guard cameraTimestamps.observe(timestamp) == .accepted else {
            accounting.recordCameraDrop(.timestampRegression)
            failAndScheduleStop()
            return
        }

        // Copy the luma plane into a plane the bench owns and let the camera
        // buffer go at the end of this callback. Holding it instead is what
        // TN2445 names as the cause of `OutOfBuffers`, and it cost 15% of frames
        // measured live at 1920x1440.
        let leaseOrNil = officialBGRA
            ? lumaPool.leaseConvertingBGRA(
                from: pixelBuffer,
                width: Int(configuration.cameraWidth),
                height: Int(configuration.cameraHeight))
            : lumaPool.lease(
                from: pixelBuffer,
                planeIndex: 0,
                width: Int(configuration.cameraWidth),
                height: Int(configuration.cameraHeight))
        guard let lease = leaseOrNil else {
            // Every pooled plane is still in flight: refuse this frame instead
            // of retaining one more camera buffer. Counted by the pool, never in
            // `camera_drops_*`, so our own backpressure stays distinguishable
            // from AVFoundation's.
            previewTap?.offer(pixelBuffer: pixelBuffer, monotonicNanoseconds: timestamp)
            return
        }
        // Strictly before the handoff. The lease is released by whoever
        // consumes the frame -- `deinit` returns the plane to the pool -- so
        // reading its storage after `offer` is a use-after-free. One memcpy of
        // 307200 bytes at 30 Hz, on the same callback thread that already
        // copied the frame once, and then the writer's own queue takes it.
        if let recorder {
            let bytes = Data(
                bytes: lease.base,
                count: Int(configuration.cameraWidth) * Int(configuration.cameraHeight)
            )
            recorder.appendLuma(bytes, timestampNanoseconds: Int64(timestamp))
        }
        let frame = MonochromeCameraFrame(
            timestampNanoseconds: timestamp,
            lease: lease,
            width: Int(configuration.cameraWidth),
            height: Int(configuration.cameraHeight)
        )
        if imuDeliveryMode == .xrslamRawSeparateEvents {
            xrslamSensorHandoff.offer(.camera(frame))
        } else {
            cameraHandoff.offer(frame)
        }
        // Strictly after handoff: the preview can never delay admission or change
        // what the engine receives.
        previewTap?.offer(pixelBuffer: pixelBuffer, monotonicNanoseconds: timestamp)
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        accounting.recordCameraDrop(Self.cameraDropReason(for: sampleBuffer))
    }

    private static func cameraDropReason(for sampleBuffer: CMSampleBuffer) -> CameraDropReason {
        guard let reason = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_DroppedFrameReason,
            attachmentModeOut: nil
        ) else {
            return .unknown
        }
        if CFEqual(reason, kCMSampleBufferDroppedFrameReason_FrameWasLate) {
            return .late
        }
        if CFEqual(reason, kCMSampleBufferDroppedFrameReason_OutOfBuffers) {
            return .outOfBuffers
        }
        if CFEqual(reason, kCMSampleBufferDroppedFrameReason_Discontinuity) {
            return .discontinuity
        }
        return .unknown
    }
}
