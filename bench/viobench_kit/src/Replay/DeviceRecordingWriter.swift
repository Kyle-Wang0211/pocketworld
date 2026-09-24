import CoreVideo
import CryptoKit
import QuartzCore
import Foundation

/// Persists one capture so every arm can be fed the identical trajectory.
///
/// Three rules shape this writer:
///
/// 1. **It must not block the capture callback.** `ARSession` delivers frames on
///    its delegate queue; a 2.76 MB synchronous file write there at 30 Hz would
///    stall ARKit itself, so the arm being measured would be measuring the
///    recorder. Frames are copied into a bounded queue and written on a private
///    serial queue.
/// 2. **A drop is a failure, not a shorter recording.** If the queue is full the
///    frame is counted as a loss and the recording is invalid. Silently skipping
///    a frame would leave a plausible file that no longer matches what ARKit saw.
/// 3. **No encoding, ever.** Raw luma only. An encoder on the capture path costs
///    the arm being measured, and a lossy one changes the pixels every candidate
///    is then scored on.
final class DeviceRecordingWriter: @unchecked Sendable {

    /// Bounded at eight frames (~22 MB at 1920x1440). Deep enough to absorb a
    /// filesystem hiccup, shallow enough that sustained write starvation is
    /// reported as loss instead of being hidden by an ever-growing buffer.
    /// Deep enough to ride out a filesystem stall instead of losing frames to
    /// one. Eight slots is 133 ms at 60 fps and a 168 ms stall was observed;
    /// sixty-four is a little over a second, at 177 MB of luma held at worst.
    /// This absorbs jitter, it does not hide loss -- an overflow is still
    /// counted and still invalidates the run.
    static let queueDepth = 64

    /// Refuse to start unless the device has the full recording plus this much
    /// headroom.
    ///
    /// The guard stays because running out of space mid-write leaves a truncated
    /// recording, which is strictly worse than a refusal: the operator has spent
    /// the time and the file cannot be replayed. But it was refusing 30 s
    /// captures by always projecting 300 s, and 2 GiB of slack on top of that
    /// made a device with 8.3 GiB free look unusable. The projection now follows
    /// the selected duration and the slack is the minimum that keeps the
    /// filesystem out of trouble.
    static let freeSpaceHeadroomBytes: Int64 = 512 * 1024 * 1024

    private let directory: URL
    private let framesDirectory: URL
    private var format: DeviceRecordingCameraFormat
    private let recordingID: String

    /// Serial, and explicitly user-initiated. At 60 fps this queue has 133 ms of
    /// slack across its eight slots, so letting the system deprioritise it costs
    /// frames directly.
    private let writeQueue = DispatchQueue(
        label: "com.kyle.viobench.recording.write",
        qos: .userInitiated
    )
    private let stateLock = NSLock()

    private var framesHandleDigest = SHA256()
    private var cameraIndexRows: [String] = []
    /// Both handles stay open for the life of the capture and are flushed after
    /// every frame, stream before index, exactly as pwva.dart does: an interrupt
    /// at any moment leaves a prefix that is self-consistent, because the index
    /// never names bytes the stream has not already committed.
    private let framesStream: FileHandle
    private let framesIndex: FileHandle
    private var streamOffset = 0

    /// Production's archive parameters, from capture_archive_service.dart.
    static let archiveGOP: Int32 = 8
    static let archiveQuality = 0.65
    /// Production's default. capture_archive_service.dart constructs
    /// AppleHevcEncoder without overriding powerEfficient, and its default is
    /// true -- the low-power encode path kept for thermal headroom.
    static let archivePowerEfficient: Int32 = 1

    private let encoder: OpaquePointer
    /// Chroma for the encoder. The bench records luma only -- the arms consume
    /// luma and nothing else -- so a neutral plane stands in for the chroma the
    /// capture never kept.
    private let neutralChroma: Data
    private var gopID = -1
    /// Set before the write queue is drained in finish(). A frame arriving after
    /// this must not be written into an archive that is being sealed: a late
    /// ARKit delivery did exactly that and left a manifest describing 1619
    /// frames over a stream holding 1616.
    private var sealed = false
    private var lateAfterSeal = 0
    private var intrinsicsRows: [String] = []
    private var focalMinimum = Double.greatestFiniteMagnitude
    private var focalMaximum = 0.0
    private var imuRows: [String] = []
    private var arkitPoseRows: [String] = []

    private var frameCount = 0
    private var framesTotalBytes: Int64 = 0
    private var lossCount = 0
    private var lossFormatMismatch = 0
    private var lossWriteQueueFull = 0
    private var lossWriteError = 0
    private var peakInFlight = 0
    private var slowestWriteMilliseconds: Double = 0
    private var inFlight = 0
    private var firstError: Error?

    private var intrinsics: DeviceRecordingIntrinsics?

    // MARK: - Depth (🔴 bench-only ruler)

    /// The LiDAR depth ARKit hands back on the same frame, kept so an offline
    /// tool can put a *metric* number on a trajectory.
    ///
    /// 🔴 **This is a bench-only ruler and stays one.** The product pipeline is
    /// monocular + IMU; nothing recorded here may be proposed as a product
    /// input, a product fallback, or a shipping requirement. It is here to
    /// check the instrument, not to become part of it.
    ///
    /// The three handles are opened on the first depth frame, not in `init`,
    /// so a device without a LiDAR scanner leaves no empty files behind and
    /// `depth_present: false` in the manifest is a statement about the world
    /// rather than about three zero-byte files.
    private var depthStream: FileHandle?
    private var depthConfidenceStream: FileHandle?
    private var depthIndex: FileHandle?
    private var depthWidth = 0
    private var depthHeight = 0
    private var depthFrameCount = 0
    /// Depth frames whose bytes are actually in the stream. `depthFrameCount`
    /// counts what was accepted into the queue; a write that then failed leaves
    /// a hole in the index's `frame` numbering, so the manifest reports what
    /// was written rather than what was hoped for. (A reader walks index rows,
    /// not frame ids, so a hole costs a measurement and nothing else.)
    private var depthFramesWritten = 0
    private var depthStreamOffset = 0
    private var depthConfidenceOffset = 0
    private var depthDigest = SHA256()
    private var depthConfidenceDigest = SHA256()
    private var depthTotalBytes: Int64 = 0
    private var depthConfidenceTotalBytes: Int64 = 0
    private var depthConfidenceSeen = false
    private var depthDropped = 0
    private var depthInFlight = 0
    private var depthSource: String?

    /// Depth frames awaiting write.
    ///
    /// Separate from `queueDepth` on purpose. A 1920x1440 luma plane is 2.76 MB
    /// and 64 of them is 177 MB, so the camera queue is sized by memory. A
    /// depth frame is 256x192x4 B plus 256x192 B = 240 KiB, so the same slack in
    /// time costs 1/11 as much; sharing one cap would make depth evict camera
    /// frames, and a camera frame loss invalidates the whole recording.
    static let depthQueueDepth = 120

    /// 4 bytes of float32 metres plus 1 byte of `ARConfidenceLevel`, per depth
    /// pixel. 256 x 192 x 5 = 245,760 B per frame; 60 fps for 30 s is 422 MiB.
    static let depthBytesPerFrame =
        DeviceRecordingManifest.expectedDepthWidth
            * DeviceRecordingManifest.expectedDepthHeight * 5

    init(
        directory: URL,
        recordingID: String,
        format: DeviceRecordingCameraFormat = .scoring
    ) throws {
        // The manifest must state the rate the session actually selected. ARKit's
        // 1920x1440 format runs at 60 fps on this device, and a manifest that
        // hardcoded 30 both misdescribed the recording and halved every storage
        // projection built on it.
        self.directory = directory
        self.framesDirectory = directory.appendingPathComponent(
            DeviceRecordingManifest.framesDirectory
        )
        self.format = format
        self.recordingID = recordingID
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        // Create both files, then hold the handles open for the whole capture.
        let streamURL = directory.appendingPathComponent(
            DeviceRecordingManifest.framesStreamPath
        )
        let indexURL = directory.appendingPathComponent(
            DeviceRecordingManifest.framesIndexPath
        )
        FileManager.default.createFile(atPath: streamURL.path, contents: nil)
        FileManager.default.createFile(atPath: indexURL.path, contents: nil)
        self.framesStream = try FileHandle(forWritingTo: streamURL)
        self.framesIndex = try FileHandle(forWritingTo: indexURL)
        guard let encoder = pw_vt_create_ex(
            Int32(format.width),
            Int32(format.height),
            Self.archiveGOP,
            Self.archiveQuality,
            0,
            Self.archivePowerEfficient
        ) else {
            throw DeviceRecordingError.encoderUnavailable
        }
        self.encoder = encoder
        self.neutralChroma = Data(repeating: 128, count: format.width * format.height / 2)
    }

    // MARK: - Preflight

    /// Bytes a recording of `seconds` will occupy, so the operator is told before
    /// the capture rather than after it fails.
    /// `includingDepth` adds the bench-only LiDAR ruler's two streams. The
    /// ARKit `record` arm passes true unconditionally rather than waiting to
    /// learn whether the device has a scanner, because support is only knowable
    /// after `session.run` and a projection that is too large refuses a capture
    /// the device could have taken, while one that is too small truncates a
    /// capture the operator has already paid for.
    static func projectedByteCount(
        seconds: Double,
        format: DeviceRecordingCameraFormat = .scoring,
        includingDepth: Bool = false
    ) -> Int64 {
        let frames = Int64((seconds * format.nominalFPS).rounded(.up))
        let perFrame = Int64(format.bytesPerFrame)
            + (includingDepth ? Int64(depthBytesPerFrame) : 0)
        return frames * perFrame
    }

    static func checkFreeSpace(
        at url: URL,
        requiredBytes: Int64
    ) throws {
        let values = try url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        let available = Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        let needed = requiredBytes + freeSpaceHeadroomBytes
        guard available >= needed else {
            throw DeviceRecordingError.insufficientFreeSpace(
                requiredBytes: needed,
                availableBytes: available
            )
        }
    }

    /// The selected frame rate is only knowable once the session has started, so
    /// the manifest is corrected then rather than shipping a constant. A manifest
    /// claiming 30 fps for a 60 fps recording misdescribes the input and halves
    /// every storage projection derived from it.
    func setNominalFPS(_ fps: Double) {
        guard fps > 0 else { return }
        stateLock.lock()
        format.nominalFPS = fps
        stateLock.unlock()
    }

    // MARK: - Intrinsics

    /// Recorded once, from the first frame that reports them. The cross-check
    /// runs here so a mismatched format halts before the operator spends five
    /// minutes on an unusable capture.
    /// Records this frame's intrinsics, then cross-checks the first frame's.
    /// Every frame is kept because production keeps every frame's: its per-photo
    /// sidecar pins `intrinsics_fxfycxcy` to the snapshot the pose came from.
    /// `source` names where the numbers came from, because a reader must never
    /// have to infer it: the ARKit arm reports `ARFrame.camera.intrinsics`, the
    /// AVFoundation transport reports the camera's own
    /// `kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix`. `expected` is what
    /// the observation is compared against in `intrinsics_observed.json`;
    /// the default is upstream's 640x480 config scaled to the 1920x1440
    /// scoring format, which is meaningless for a frame that is natively
    /// 640x480, so the native path passes the unscaled values instead.
    ///
    /// `exposureSeconds` is this frame's exposure duration, written as
    /// `exposure_s` on the same row. It is recorded because the frame timestamp
    /// (`ARFrame.timestamp` / `CMSampleBufferGetPresentationTimeStamp`) marks
    /// the *start* of exposure while a VIO wants the exposure midpoint, so a
    /// replay must shift each frame by exposure/2 to match what the live path
    /// now feeds the engine (Huai et al., arXiv 2001.00470 §IV.B: images are
    /// "timestamped at the beginning of exposure"; the correction is half the
    /// exposure plus half the rolling-shutter readout). The ARKit arm passes
    /// `ARFrame.camera.exposureDuration`, the AVFoundation transport passes
    /// `AVCaptureDevice.exposureDuration` -- the MARS logger's practice of
    /// reading the device value in the frame callback. `nil` means the caller
    /// cannot report it and the key is omitted; a reader must treat a missing
    /// key as unknown, never as 0 (`pwvi_to_euroc.py --exposure-half` refuses
    /// such recordings instead of silently shifting by nothing).
    func recordIntrinsics(
        _ reported: CameraIntrinsics,
        timestampSeconds: Double,
        exposureSeconds: Double? = nil,
        source: String = "ARFrame.camera.intrinsics",
        expected: CameraIntrinsics = ARKitIntrinsicsCrossCheck.expectedScoringIntrinsics
    ) throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        if reported.fx.isFinite, reported.fx > 0 {
            focalMinimum = min(focalMinimum, reported.fx)
            focalMaximum = max(focalMaximum, reported.fx)
        }
        // Same keys as the production sidecar, so a consumer that reads one
        // reads the other.
        // `exposure_s` only when the caller could report a finite, non-negative
        // value; the key's absence is the documented "unknown".
        let exposureField: String
        if let e = exposureSeconds, e.isFinite, e >= 0 {
            exposureField = ",\"exposure_s\":\(e)"
        } else {
            exposureField = ""
        }
        intrinsicsRows.append(
            "{\"t\":\(timestampSeconds),\"intrinsics_fxfycxcy\":"
                + "[\(reported.fx),\(reported.fy),\(reported.cx),\(reported.cy)]"
                + exposureField + "}"
        )

        guard intrinsics == nil else { return }

        // Persist what the device actually reported before judging it. The first
        // cross-check failure discarded the very numbers needed to understand it,
        // leaving only "they disagree" -- which says nothing about whether the
        // scaling premise is wrong, the format is cropped, or the tolerance is
        // simply too tight.
        let verdict = ARKitIntrinsicsCrossCheck.check(
            arkitReported: reported,
            frameWidth: format.width,
            frameHeight: format.height
        )
        let observed: [String: Any] = [
            "intrinsics_source": source,
            "arkit_reported": ["fx": reported.fx, "fy": reported.fy,
                               "cx": reported.cx, "cy": reported.cy],
            "expected_from_upstream_x3": ["fx": expected.fx, "fy": expected.fy,
                                          "cx": expected.cx, "cy": expected.cy],
            "delta_pixels": ["fx": reported.fx - expected.fx,
                             "fy": reported.fy - expected.fy,
                             "cx": reported.cx - expected.cx,
                             "cy": reported.cy - expected.cy],
            "focal_relative_tolerance": ARKitIntrinsicsCrossCheck.focalRelativeTolerance,
            "principal_point_tolerance_pixels":
                ARKitIntrinsicsCrossCheck.principalPointToleranceP,
            "focal_relative_delta": [
                "fx": expected.fx > 0 ? (reported.fx - expected.fx) / expected.fx : .nan,
                "fy": expected.fy > 0 ? (reported.fy - expected.fy) / expected.fy : .nan,
            ],
            // What ARKit actually handed us, so the format is evidence in the
            // artifact rather than something inferred from cx afterwards.
            "frame_width_from_principal_point": reported.cx * 2,
            "frame_height_from_principal_point": reported.cy * 2,
            "agrees": verdict.reason == nil,
            "reason": verdict.reason ?? "agrees",
        ]
        if let data = try? JSONSerialization.data(
            withJSONObject: observed, options: [.prettyPrinted, .sortedKeys]
        ) {
            try? data.write(
                to: directory.appendingPathComponent("intrinsics_observed.json"),
                options: .atomic
            )
        }

        guard case .agrees(let scoring) = verdict else {
            throw DeviceRecordingError.intrinsicsCrossCheckFailed
        }
        intrinsics = DeviceRecordingIntrinsics(
            fx: scoring.fx,
            fy: scoring.fy,
            cx: scoring.cx,
            cy: scoring.cy,
            source: source,
            crossCheckPassed: true
        )
    }

    // MARK: - Ingest

    /// Copies the luma plane out of an `ARFrame.capturedImage` and enqueues it.
    ///
    /// The copy happens on the caller's thread because the pixel buffer is only
    /// valid for the duration of the callback; it is a single memcpy per row,
    /// with no encoding and no format conversion.
    func appendFrame(
        pixelBuffer: CVPixelBuffer,
        timestampNanoseconds: Int64
    ) {
        guard let luma = Self.copyLumaPlane(pixelBuffer, expected: format) else {
            stateLock.lock()
            lossCount += 1
            lossFormatMismatch += 1
            stateLock.unlock()
            return
        }
        enqueue(luma: luma, timestampNanoseconds: timestampNanoseconds)
    }

    /// Records a grayscale plane the caller already holds.
    ///
    /// The AVFoundation transport reaches gray before the recorder does: it
    /// captures 32BGRA and converts through upstream's own
    /// `cvtColor(BGRA2GRAY)` into a pooled plane, and that plane -- not a
    /// pixel buffer -- is what the engine is handed. Recording from it is the
    /// point: the file then holds the exact bytes the engine consumed, rather
    /// than a second conversion of the same frame that could differ from it.
    ///
    /// The caller must copy before handing the lease to the engine. A lease is
    /// released by whoever consumes the frame, so reading its storage after
    /// handoff is a use-after-free; this takes `Data` so that copy is explicit
    /// at the call site rather than implied here.
    func appendLuma(_ luma: Data, timestampNanoseconds: Int64) {
        guard luma.count == format.bytesPerFrame else {
            stateLock.lock()
            lossCount += 1
            lossFormatMismatch += 1
            stateLock.unlock()
            return
        }
        enqueue(luma: luma, timestampNanoseconds: timestampNanoseconds)
    }

    private func enqueue(luma: Data, timestampNanoseconds: Int64) {
        stateLock.lock()
        guard !sealed else {
            lateAfterSeal += 1
            stateLock.unlock()
            return
        }
        guard inFlight < Self.queueDepth else {
            // Backpressure is loss, and loss invalidates. It is never absorbed by
            // growing the queue or by skipping ahead.
            lossCount += 1
            lossWriteQueueFull += 1
            stateLock.unlock()
            return
        }
        let index = frameCount
        frameCount += 1
        inFlight += 1
        peakInFlight = max(peakInFlight, inFlight)
        cameraIndexRows.append("\(timestampNanoseconds),\(index)")
        stateLock.unlock()

        writeQueue.async { [weak self] in
            guard let self else { return }
            let writeStart = CACurrentMediaTime()
            do {
                // Stream first, then the index row -- pwva.dart's order, so an
                // interrupted capture leaves a prefix the index never
                // over-claims. The payload is the raw plane.
                //
                // Encoding was tried in both places production suggests and
                // neither survives this requirement. In the capture path a
                // hardware encode cost 127 ms on one frame against a 16.6 ms
                // budget and lost 73 to backpressure. After the capture, as
                // production does it, 1800 frames took minutes and iOS
                // suspended the app partway, leaving a run with no manifest at
                // all. Production never faces this: it archives a few dozen
                // shutter stills, not every frame at 60 fps, so there is no
                // production answer here to copy. Transcoding now happens off
                // the device, where nothing suspends it.
                let offset = self.streamOffset
                try self.framesStream.write(contentsOf: luma)
                try self.framesStream.synchronize()
                let row = "{\"frame\":\(index),\"offset\":\(offset)," +
                    "\"len\":\(luma.count),\"keyframe\":true,\"gop\":\(index)}\n"
                try self.framesIndex.write(contentsOf: Data(row.utf8))
                try self.framesIndex.synchronize()
                let elapsed = (CACurrentMediaTime() - writeStart) * 1000
                self.stateLock.lock()
                self.streamOffset = offset + luma.count
                self.slowestWriteMilliseconds = max(self.slowestWriteMilliseconds, elapsed)
                self.framesHandleDigest.update(data: luma)
                self.framesTotalBytes += Int64(luma.count)
                self.inFlight -= 1
                self.stateLock.unlock()
            } catch {
                self.stateLock.lock()
                self.lossCount += 1
                self.lossWriteError += 1
                self.inFlight -= 1
                if self.firstError == nil { self.firstError = error }
                self.stateLock.unlock()
            }
        }
    }

    /// Records one LiDAR depth frame beside the camera frame it arrived with.
    ///
    /// 🔴 **Bench-only ruler.** See the `depthStream` comment above: this
    /// never becomes a product input.
    ///
    /// `depthMap` is `ARDepthData.depthMap` -- "A pixel buffer that contains
    /// per-pixel depth data (in meters)" (ARKit SDK header `ARDepthData.h`) --
    /// and Apple's own overview fixes what a pixel of it means: "Every pixel in
    /// the depthMap maps to a region of the visible scene (capturedImage),
    /// where the pixel value defines that region's distance from the plane of
    /// the camera in meters."
    /// (https://developer.apple.com/documentation/arkit/ardepthdata)
    /// It is therefore a *planar* z-depth in the camera frame, directly
    /// comparable with the z of a triangulated point -- not a radial range that
    /// would need converting first.
    ///
    /// `confidenceMap` is `ARDepthData.confidenceMap`, one `ARConfidenceLevel`
    /// per pixel (`ARConfidenceLevelLow` = 0, `Medium` = 1, `High` = 2, from
    /// `ARDepthData.h`). It is `nullable` in the header, so the recording
    /// records whether it was there instead of assuming it was.
    ///
    /// The depth map is 256x192 while `capturedImage` is 1920x1440, and the
    /// consumer maps between them by scaling the intrinsics by the resolution
    /// ratio. That is a consequence of the sentence quoted above -- every depth
    /// pixel covers a region of the *same* captured image -- and not a separate
    /// Apple-published formula; the offline tool states the same thing where it
    /// does the scaling.
    ///
    /// `smoothedSceneDepth` is deliberately not recorded. It is ARKit's own
    /// temporally filtered estimate, i.e. another estimator's output, and this
    /// file already refuses `CMDeviceMotion` for the same reason.
    ///
    /// A depth frame that cannot be kept is counted in `depth_dropped` and does
    /// not invalidate the recording: unlike a camera frame, no arm is scored on
    /// it.
    func appendDepth(
        depthMap: CVPixelBuffer,
        confidenceMap: CVPixelBuffer?,
        timestampNanoseconds: Int64,
        source: String = "ARFrame.sceneDepth"
    ) {
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        guard width > 0, height > 0,
              let depth = Self.copyTightly(depthMap, bytesPerPixel: 4) else {
            stateLock.lock(); depthDropped += 1; stateLock.unlock()
            return
        }
        var confidence: Data?
        if let confidenceMap {
            guard CVPixelBufferGetWidth(confidenceMap) == width,
                  CVPixelBufferGetHeight(confidenceMap) == height,
                  let bytes = Self.copyTightly(confidenceMap, bytesPerPixel: 1) else {
                stateLock.lock(); depthDropped += 1; stateLock.unlock()
                return
            }
            confidence = bytes
        }

        stateLock.lock()
        guard !sealed else {
            lateAfterSeal += 1
            stateLock.unlock()
            return
        }
        if depthFrameCount == 0 {
            depthWidth = width
            depthHeight = height
            depthSource = source
        } else if width != depthWidth || height != depthHeight {
            // Fixed stride is the whole point of an append-only stream; a
            // geometry change mid-run would shear every later frame exactly the
            // way an unhandled camera row stride does.
            depthDropped += 1
            stateLock.unlock()
            return
        }
        guard depthInFlight < Self.depthQueueDepth else {
            depthDropped += 1
            stateLock.unlock()
            return
        }
        let index = depthFrameCount
        depthFrameCount += 1
        depthInFlight += 1
        if confidence != nil { depthConfidenceSeen = true }
        stateLock.unlock()

        writeQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.openDepthHandlesIfNeeded()
                guard let stream = self.depthStream, let index_ = self.depthIndex else {
                    self.stateLock.lock()
                    self.depthDropped += 1
                    self.depthInFlight -= 1
                    self.stateLock.unlock()
                    return
                }
                // Stream, then confidence, then the index row -- the same order
                // frames.bin / frames.pwvi use, so an interrupted capture leaves
                // a prefix the index never over-claims.
                let offset = self.depthStreamOffset
                try stream.write(contentsOf: depth)
                try stream.synchronize()
                var confidenceOffset = -1
                var confidenceLength = 0
                if let confidence, let confidenceStream = self.depthConfidenceStream {
                    confidenceOffset = self.depthConfidenceOffset
                    confidenceLength = confidence.count
                    try confidenceStream.write(contentsOf: confidence)
                    try confidenceStream.synchronize()
                }
                let row = "{\"frame\":\(index),\"offset\":\(offset),"
                    + "\"len\":\(depth.count),\"t_ns\":\(timestampNanoseconds),"
                    + "\"w\":\(width),\"h\":\(height),"
                    + "\"conf_offset\":\(confidenceOffset),"
                    + "\"conf_len\":\(confidenceLength)}\n"
                try index_.write(contentsOf: Data(row.utf8))
                try index_.synchronize()
                self.stateLock.lock()
                self.depthStreamOffset = offset + depth.count
                self.depthConfidenceOffset += confidenceLength
                self.depthDigest.update(data: depth)
                self.depthTotalBytes += Int64(depth.count)
                if let confidence {
                    self.depthConfidenceDigest.update(data: confidence)
                    self.depthConfidenceTotalBytes += Int64(confidence.count)
                }
                self.depthFramesWritten += 1
                self.depthInFlight -= 1
                self.stateLock.unlock()
            } catch {
                // Never sets firstError: a depth write failure costs the ruler,
                // not the recording.
                self.stateLock.lock()
                self.depthDropped += 1
                self.depthInFlight -= 1
                self.stateLock.unlock()
            }
        }
    }

    /// Opens the three depth files on first use. Called only from `writeQueue`,
    /// which is serial, so no lock is needed around the handles themselves.
    private func openDepthHandlesIfNeeded() throws {
        guard depthStream == nil else { return }
        let stream = directory.appendingPathComponent(
            DeviceRecordingManifest.depthStreamPath
        )
        let confidence = directory.appendingPathComponent(
            DeviceRecordingManifest.depthConfidencePath
        )
        let index = directory.appendingPathComponent(
            DeviceRecordingManifest.depthIndexPath
        )
        for url in [stream, confidence, index] {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        depthStream = try FileHandle(forWritingTo: stream)
        depthConfidenceStream = try FileHandle(forWritingTo: confidence)
        depthIndex = try FileHandle(forWritingTo: index)
    }

    func appendIMU(
        timestampNanoseconds: Int64,
        gyroscope: (x: Double, y: Double, z: Double),
        acceleration: (x: Double, y: Double, z: Double)
    ) {
        let row = "\(timestampNanoseconds),\(gyroscope.x),\(gyroscope.y),\(gyroscope.z),"
            + "\(acceleration.x),\(acceleration.y),\(acceleration.z)"
        stateLock.lock(); imuRows.append(row); stateLock.unlock()
    }

    /// ARKit's own trajectory over these frames: a same-input system reference,
    /// recorded so the comparison is against the identical motion.
    func appendARKitPose(timestampNanoseconds: Int64, tumRow: String) {
        stateLock.lock(); arkitPoseRows.append(tumRow); stateLock.unlock()
    }

    /// Encodes one luma plane through production's encoder.
    private func encode(luma: Data, index: Int) throws -> (bytes: Data, keyframe: Bool) {
        var out: UnsafeMutablePointer<UInt8>?
        var length: Int64 = 0
        var keyframe: Int32 = 0
        let status: Int32 = luma.withUnsafeBytes { y in
            neutralChroma.withUnsafeBytes { uv in
                pw_vt_encode_nv12(
                    encoder,
                    y.bindMemory(to: UInt8.self).baseAddress,
                    uv.bindMemory(to: UInt8.self).baseAddress,
                    Int64(index) * 1000 / Int64(format.nominalFPS),
                    1000 / Int64(format.nominalFPS),
                    &out,
                    &length,
                    &keyframe
                )
            }
        }
        guard status == 0, let out, length > 0 else {
            throw DeviceRecordingError.encodeFailed(frame: index, status: Int(status))
        }
        defer { pw_vt_free(out) }
        return (Data(bytes: out, count: Int(length)), keyframe != 0)
    }

    deinit {
        pw_vt_destroy(encoder)
    }

    // MARK: - Finish

    /// Drains the write queue and seals the manifest. Any loss makes the
    /// recording invalid; the manifest still records the count so the failure is
    /// legible rather than silent.
    @discardableResult
    func finish() throws -> DeviceRecordingManifest {
        // Seal before draining. Otherwise a frame delivered while the drain is
        // running is accepted, written, and counted after the totals have been
        // read -- which is how a manifest came to describe 1619 frames over a
        // stream that held 1616.
        stateLock.lock()
        sealed = true
        stateLock.unlock()
        writeQueue.sync {}

        stateLock.lock()
        if let firstError { stateLock.unlock(); throw firstError }
        let manifestFrameCount = frameCount
        let archiveBytes = framesTotalBytes
        let archiveDigest = Self.hex(framesHandleDigest.finalize())
        // Every counter is snapshotted here, under the same lock, for the same
        // reason the totals are: read outside it they are a race, and a manifest
        // reported one write error on a run that had none and could not have had
        // one -- a write failure sets firstError, which makes finish throw.
        let losses = lossCount
        let lossesFormat = lossFormatMismatch
        let lossesQueueFull = lossWriteQueueFull
        let lossesWriteError = lossWriteError
        let peak = peakInFlight
        let slowestWrite = slowestWriteMilliseconds
        let lateSeal = lateAfterSeal
        let cameraCSV = (["timestamp_ns,relative_path"] + cameraIndexRows).joined(separator: "\n") + "\n"
        let imuCSV = (["timestamp_ns,wx,wy,wz,ax,ay,az"] + imuRows).joined(separator: "\n") + "\n"
        let poseTUM = arkitPoseRows.joined(separator: "\n") + "\n"
        let intrinsicsJSONL = intrinsicsRows.joined(separator: "\n") + "\n"
        let focalLow = focalMinimum == .greatestFiniteMagnitude ? 0 : focalMinimum
        let focalHigh = focalMaximum
        let capturedIntrinsics = intrinsics
        let depthFrames = depthFramesWritten
        let depthW = depthWidth
        let depthH = depthHeight
        let depthBytes = depthTotalBytes
        let depthConfidenceBytes = depthConfidenceTotalBytes
        let depthSHA = Self.hex(depthDigest.finalize())
        let depthConfidenceSHA = Self.hex(depthConfidenceDigest.finalize())
        let depthHadConfidence = depthConfidenceSeen
        let depthDrops = depthDropped
        let depthSourceName = depthSource
        stateLock.unlock()

        guard let capturedIntrinsics else {
            // No intrinsics means no frame ever arrived. Reporting that as a
            // failed cross-check named the wrong cause and cost an investigation.
            throw DeviceRecordingError.noFramesCaptured
        }

        var files: [DeviceRecordingFile] = []
        for (role, path, contents) in [
            (DeviceRecordingFileRole.cameraIndex, "camera_index.csv", cameraCSV),
            (DeviceRecordingFileRole.intrinsicsIndex, "intrinsics.jsonl", intrinsicsJSONL),
            (DeviceRecordingFileRole.imuIndex, "imu.csv", imuCSV),
            (DeviceRecordingFileRole.arkitPoses, "arkit_poses.tum", poseTUM),
        ] {
            let data = Data(contents.utf8)
            try data.write(to: directory.appendingPathComponent(path), options: .atomic)
            files.append(DeviceRecordingFile(
                role: role,
                relativePath: path,
                byteCount: Int64(data.count),
                sha256: Self.hex(SHA256.hash(data: data))
            ))
        }
        try framesStream.close()
        try framesIndex.close()

        // The stream's hash is the digest already accumulated frame by frame as
        // they were written -- the same bytes in the same order -- so it is
        // taken from there rather than by reading the file back. pwva.dart
        // accumulates its stream hash the same way while writing. Re-reading
        // instead left a 30 s capture stuck in finalize hashing 4.55 GB.
        files.append(DeviceRecordingFile(
            role: .framesStream,
            relativePath: DeviceRecordingManifest.framesStreamPath,
            byteCount: archiveBytes,
            sha256: archiveDigest
        ))
        let indexURL = directory.appendingPathComponent(
            DeviceRecordingManifest.framesIndexPath
        )
        let indexData = try Data(contentsOf: indexURL)
        files.append(DeviceRecordingFile(
            role: .framesIndex,
            relativePath: DeviceRecordingManifest.framesIndexPath,
            byteCount: Int64(indexData.count),
            sha256: Self.hex(SHA256.hash(data: indexData))
        ))
        // 🔴 Bench-only ruler. Present only when the device actually delivered
        // depth; on a phone without a LiDAR scanner these three files do not
        // exist and the manifest says so rather than naming empty files.
        //
        // Nothing in here may throw out of `finish()`. A camera-frame failure
        // must fail the recording; a depth failure must not, or a bench-only
        // ruler would be able to destroy a capture the operator cannot retake.
        var depthDeclared = false
        if depthFrames > 0, depthStream != nil {
            try? depthStream?.close()
            try? depthConfidenceStream?.close()
            try? depthIndex?.close()
            let depthIndexURL = directory.appendingPathComponent(
                DeviceRecordingManifest.depthIndexPath
            )
            if let depthIndexData = try? Data(contentsOf: depthIndexURL) {
                files.append(DeviceRecordingFile(
                    role: .depthStream,
                    relativePath: DeviceRecordingManifest.depthStreamPath,
                    byteCount: depthBytes,
                    // Accumulated while writing, like the frame stream's, so
                    // sealing does not re-read hundreds of megabytes.
                    sha256: depthSHA
                ))
                if depthHadConfidence {
                    files.append(DeviceRecordingFile(
                        role: .depthConfidenceStream,
                        relativePath: DeviceRecordingManifest.depthConfidencePath,
                        byteCount: depthConfidenceBytes,
                        sha256: depthConfidenceSHA
                    ))
                }
                files.append(DeviceRecordingFile(
                    role: .depthIndex,
                    relativePath: DeviceRecordingManifest.depthIndexPath,
                    byteCount: Int64(depthIndexData.count),
                    sha256: Self.hex(SHA256.hash(data: depthIndexData))
                ))
                depthDeclared = true
            }
        }
        files.sort { $0.relativePath < $1.relativePath }

        let manifest = DeviceRecordingManifest(
            schemaVersion: DeviceRecordingManifest.supportedSchemaVersion,
            recordingID: recordingID,
            camera: format,
            intrinsics: capturedIntrinsics,
            frameCount: manifestFrameCount,
            imuSampleCount: imuRows.count,
            framesDigestSHA256: archiveDigest,
            framesTotalByteCount: archiveBytes,
            lossCount: losses,
            lossFormatMismatch: lossesFormat,
            lossWriteQueueFull: lossesQueueFull,
            lossWriteError: lossesWriteError,
            peakInFlight: peak,
            slowestWriteMilliseconds: slowestWrite,
            focalLengthMinimum: focalLow,
            focalLengthMaximum: focalHigh,
            lateFramesAfterSeal: lateSeal,
            depthPresent: depthDeclared,
            depthWidth: depthDeclared ? depthW : nil,
            depthHeight: depthDeclared ? depthH : nil,
            depthFrameCount: depthDeclared ? depthFrames : 0,
            depthSource: depthDeclared ? depthSourceName : nil,
            depthConfidencePresent: depthDeclared ? depthHadConfidence : nil,
            // Frames that never reached the stream are drops, whatever stage
            // lost them -- including the case where the files could not be
            // declared at all.
            depthDropped: depthDrops + (depthDeclared ? 0 : depthFrames),
            files: files
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: directory.appendingPathComponent("recording_manifest.json"),
            options: .atomic
        )
        return manifest
    }

    // MARK: - Helpers

    /// Extracts the Y plane of a 420f biplanar buffer.
    ///
    /// `bytesPerRow` is frequently padded beyond `width`, so rows are copied
    /// individually; blitting the plane wholesale would embed the stride in the
    /// file and every replayed frame would be sheared.
    static func copyLumaPlane(
        _ pixelBuffer: CVPixelBuffer,
        expected: DeviceRecordingCameraFormat
    ) -> Data? {
        guard CVPixelBufferGetWidthOfPlane(pixelBuffer, 0) == expected.width,
              CVPixelBufferGetHeightOfPlane(pixelBuffer, 0) == expected.height else {
            return nil
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
            return nil
        }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        var out = Data(count: expected.bytesPerFrame)
        out.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            for row in 0..<expected.height {
                memcpy(
                    destinationBase.advanced(by: row * expected.width),
                    base.advanced(by: row * stride),
                    expected.width
                )
            }
        }
        return out
    }

    /// Copies a non-planar pixel buffer row by row into tightly packed bytes.
    ///
    /// Same trap as `copyLumaPlane`: `CVPixelBufferGetBytesPerRow` is padded
    /// past `width * bytesPerPixel` (256 float32 columns is 1024 B, and the
    /// buffer is commonly 1024 or more), so blitting wholesale would bake the
    /// stride into the file and every depth frame would be sheared.
    static func copyTightly(
        _ pixelBuffer: CVPixelBuffer,
        bytesPerPixel: Int
    ) -> Data? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let rowBytes = width * bytesPerPixel
        guard stride >= rowBytes else { return nil }
        var out = Data(count: rowBytes * height)
        out.withUnsafeMutableBytes { destination in
            guard let destinationBase = destination.baseAddress else { return }
            for row in 0..<height {
                memcpy(
                    destinationBase.advanced(by: row * rowBytes),
                    base.advanced(by: row * stride),
                    rowBytes
                )
            }
        }
        return out
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
