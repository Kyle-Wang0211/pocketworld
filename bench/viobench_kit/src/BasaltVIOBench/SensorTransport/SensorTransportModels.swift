import CoreVideo
import Foundation

public struct SensorTransportConfiguration: Equatable, Sendable {
    public let cameraWidth: Int32
    public let cameraHeight: Int32
    public let cameraRateHz: Int32
    public let motionRateHz: Double
    public let cameraQueueCapacity: Int
    public let imuQueueCapacity: Int
    public let pendingGyroscopeCapacity: Int

    public init(
        // The candidate arms capture at the diagnostic resolution, not the
        // scoring one, and that is not a shortfall -- it is the architecture.
        //
        // Under contract v2 Basalt and XRSLAM are scored by replaying the ARKit
        // recording at 1920x1440, where the intrinsics come from
        // ARFrame.camera.intrinsics: measured for exactly those frames. A live
        // candidate run has no ARSession, so no measured intrinsics exist for it.
        //
        // Raising this to 1920x1440 on 2026-08-30 broke the arm outright: the
        // frozen calibration still declares [[640, 480]], and Basalt correctly
        // refused every frame with invalid_argument
        // (plane.width != resolution.x()). Unblocking it would have meant
        // inventing intrinsics by scaling the upstream values threefold -- and
        // that is only valid if both formats share a field of view, which cannot
        // be shown from the artifacts on hand. Fabricating a calibration to
        // unblock a run the contract already marks non-scoring is a bad trade.
        //
        // So live capture stays at the frozen, upstream-verified 640x480 pairing
        // and is used for what it can answer: transport, clock domain, loss and
        // stop semantics. Resolution pressure at 1920x1440 is answered by the
        // replay channel, on measured intrinsics.
        cameraWidth: Int32 = Int32(BenchResolution.diagnostic.width),
        cameraHeight: Int32 = Int32(BenchResolution.diagnostic.height),
        cameraRateHz: Int32 = 30,
        motionRateHz: Double = 100,
        cameraQueueCapacity: Int = 8,
        imuQueueCapacity: Int = 128,
        pendingGyroscopeCapacity: Int = 128
    ) {
        precondition(cameraWidth > 0 && cameraHeight > 0)
        precondition(cameraRateHz > 0 && motionRateHz > 0)
        precondition(cameraQueueCapacity > 0 && imuQueueCapacity > 0)
        precondition(pendingGyroscopeCapacity > 0)
        self.cameraWidth = cameraWidth
        self.cameraHeight = cameraHeight
        self.cameraRateHz = cameraRateHz
        self.motionRateHz = motionRateHz
        self.cameraQueueCapacity = cameraQueueCapacity
        self.imuQueueCapacity = imuQueueCapacity
        self.pendingGyroscopeCapacity = pendingGyroscopeCapacity
    }

    public static let benchmark = SensorTransportConfiguration()

    /// The production capture size. Selected by `-PWLiveFullResolution`; see
    /// BenchResolution.liveFullResolutionRequested for why the frozen 640x480
    /// pairing is no longer the only defensible live configuration.
    /// 60 Hz, not 30: production's nominal rate is 60 and drops to 30 only
    /// under thermal pressure. At 30 the camera, not the engine, sets the
    /// ceiling -- both tracker_frequent settings processed every frame the
    /// camera delivered and reported ~30 fps, which says nothing about how fast
    /// the engine could go. Comparing against ARKit's measured 56.7 fps needs
    /// the camera to offer more than 56.7.
    public static let productionResolution = SensorTransportConfiguration(
        cameraWidth: Int32(BenchResolution.scoring.width),
        cameraHeight: Int32(BenchResolution.scoring.height),
        cameraRateHz: 30
    )

    public static var live: SensorTransportConfiguration {
        let base: SensorTransportConfiguration = BenchResolution.liveFullResolutionRequested ? .productionResolution : .benchmark
        // [bench 2026-09-04] `-PWLiveCameraRate N` overrides the live camera rate (60 = production's nominal rate; the
        // receipt's active-format fields record what actually ran). Without the flag: byte-equivalent to before.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-PWLiveCameraRate"), i + 1 < args.count, let hz = Int32(args[i + 1]), hz > 0, hz <= 240 {
            return SensorTransportConfiguration(cameraWidth: base.cameraWidth, cameraHeight: base.cameraHeight, cameraRateHz: hz, motionRateHz: base.motionRateHz,
                                                cameraQueueCapacity: base.cameraQueueCapacity, imuQueueCapacity: base.imuQueueCapacity, pendingGyroscopeCapacity: base.pendingGyroscopeCapacity)
        }
        return base
    }
}

/// A pool of luma planes the bench owns, sized once and recycled forever.
///
/// [2026-09-15] `MonochromeCameraFrame` used to carry the `CVPixelBuffer`
/// AVFoundation handed the capture callback, and the serial handoff behind it is
/// 264 deep, so that many camera buffers could be held at once. Apple TN2445
/// names exactly this as the cause of `OutOfBuffers` drops -- "typically caused
/// by the client holding onto buffers for too long, and can be alleviated by
/// returning buffers to the provider" -- and prescribes the fix used here:
/// "copying the data into a new buffer and then calling `CFRelease` on the
/// sample buffer ... so the memory it references can be reused". Measured before
/// this change, live at 1920x1440 for 120 s: 539 of 3592 frames dropped
/// `OutOfBuffers` (15%), p95 pipeline latency 908 ms, handoff peak 264/264.
///
/// The rule is not an iOS special case, which is why the policy lives here
/// rather than in one platform's callback: Android's `ImageReader` caps
/// concurrently held `Image`s at `maxImages` and requires `close()` (its
/// `acquireLatestImage` names the drop-oldest policy outright), and V4L2
/// requires processed buffers be re-queued with `VIDIOC_QBUF` or the capture
/// pipeline starves. Same contract, three vocabularies.
public final class LumaPlanePool: @unchecked Sendable {
    private let lock = NSLock()
    private var free: [UnsafeMutablePointer<UInt8>]
    private var exhausted: UInt64 = 0
    private var peakInFlight = 0
    // Probe: is the plane we hand the engine actually an image? A mean near
    // zero means the copy is wrong, which no downstream counter can tell apart
    // from "the engine found nothing".
    private var sampleSum: UInt64 = 0
    private var sampleCount: UInt64 = 0
    private var lastSrcStride = 0
    public let planeCapacityBytes: Int
    public let planeCount: Int

    /// Allocations live for the process, so a lease can never outlive its
    /// storage. `planeCount` is the real bound on camera frames in flight --
    /// the number that used to be unbounded in practice.
    public init(planeCount: Int, planeCapacityBytes: Int) {
        precondition(planeCount > 0 && planeCapacityBytes > 0)
        self.planeCount = planeCount
        self.planeCapacityBytes = planeCapacityBytes
        free = (0..<planeCount).map { _ in
            UnsafeMutablePointer<UInt8>.allocate(capacity: planeCapacityBytes)
        }
    }

    /// Copies plane `planeIndex` of `pixelBuffer` into a pooled plane and
    /// returns a lease. Returns nil when every plane is still in flight, which
    /// is the bounded-queue refusal -- never a stall, and never one more
    /// retained camera buffer.
    func lease(
        from pixelBuffer: CVPixelBuffer,
        planeIndex: Int,
        width: Int,
        height: Int
    ) -> LumaPlaneLease? {
        guard width > 0, height > 0, width * height <= planeCapacityBytes else { return nil }
        lock.lock()
        guard let base = free.popLast() else {
            exhausted &+= 1
            lock.unlock()
            return nil
        }
        peakInFlight = max(peakInFlight, planeCount - free.count)
        lock.unlock()

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) > planeIndex,
              let src = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, planeIndex)?
                .assumingMemoryBound(to: UInt8.self) else {
            give(base)
            return nil
        }
        let srcStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, planeIndex)
        // Packed rows: the engine receives a contiguous plane, and the copy is
        // the only place the camera's own memory is touched.
        if srcStride == width {
            base.update(from: src, count: width * height)
        } else {
            for y in 0..<height {
                (base + y * width).update(from: src + y * srcStride, count: width)
            }
        }
        var probe: UInt64 = 0
        var probeN: UInt64 = 0
        var i = 0
        while i < width * height { probe &+= UInt64(base[i]); probeN &+= 1; i += 1024 }
        lock.lock()
        sampleSum &+= probe; sampleCount &+= probeN; lastSrcStride = srcStride
        lock.unlock()
        return LumaPlaneLease(
            base: base, width: width, height: height, bytesPerRow: width, pool: self
        )
    }

    /// The official iOS app's path to gray. It captures 32BGRA and reaches
    /// grayscale through OpenCV (XRSLAM_iOS.mm processBuffer), where this
    /// transport captures 420f and takes the ISP's luma plane. Those are two
    /// different grayscales -- BT.601 weights applied to the ISP's RGB against
    /// the ISP's own Y -- so replicating upstream's input means replicating its
    /// conversion, not approximating it. `xrslam_bench_bgra_to_gray` holds
    /// upstream's two lines; nothing here reimplements them.
    func leaseConvertingBGRA(
        from pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int
    ) -> LumaPlaneLease? {
        guard width > 0, height > 0, width * height <= planeCapacityBytes else { return nil }
        lock.lock()
        guard let base = free.popLast() else {
            exhausted &+= 1
            lock.unlock()
            return nil
        }
        peakInFlight = max(peakInFlight, planeCount - free.count)
        lock.unlock()

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard !CVPixelBufferIsPlanar(pixelBuffer),
              let src = CVPixelBufferGetBaseAddress(pixelBuffer)?
                .assumingMemoryBound(to: UInt8.self) else {
            give(base)
            return nil
        }
        let srcStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let status = xrslam_bench_bgra_to_gray(
            src, Int32(width), Int32(height), Int32(srcStride),
            base, Int32(width)
        )
        guard status == XRSLAM_BENCH_OK else {
            give(base)
            return nil
        }
        var probe: UInt64 = 0
        var probeN: UInt64 = 0
        var i = 0
        while i < width * height { probe &+= UInt64(base[i]); probeN &+= 1; i += 1024 }
        lock.lock()
        sampleSum &+= probe; sampleCount &+= probeN; lastSrcStride = srcStride
        lock.unlock()
        return LumaPlaneLease(
            base: base, width: width, height: height, bytesPerRow: width, pool: self
        )
    }

    fileprivate func give(_ plane: UnsafeMutablePointer<UInt8>) {
        lock.lock(); free.append(plane); lock.unlock()
    }

    /// Frames refused because every pooled plane was still in flight.
    public var exhaustedCount: UInt64 {
        lock.lock(); defer { lock.unlock() }; return exhausted
    }

    public var inFlight: Int {
        lock.lock(); defer { lock.unlock() }; return planeCount - free.count
    }

    /// Mean luma over a 1-in-1024 sample of every plane copied. Near zero means
    /// the copy, not the engine, is what produced no features.
    public var sampleMeanLuma: Int {
        lock.lock(); defer { lock.unlock() }
        return sampleCount == 0 ? -1 : Int(sampleSum / sampleCount)
    }

    /// The camera's own row stride for the most recent plane. Equal to the width
    /// means unpadded; larger means the copy had to repack.
    public var observedSourceStride: Int {
        lock.lock(); defer { lock.unlock() }; return lastSrcStride
    }

    /// Most planes ever held at once. Equal to `planeCount` means the bound was
    /// reached and the refusals above are real backpressure, not noise.
    public var peakHeld: Int {
        lock.lock(); defer { lock.unlock() }; return peakInFlight
    }
}

/// One checked-out plane. ARC returns it the moment the last frame referencing
/// it is submitted or dropped, so no call site has to remember to recycle; the
/// pool stores the raw allocation, never this object, so there is no deinit
/// resurrection.
public final class LumaPlaneLease: @unchecked Sendable {
    let base: UnsafeMutablePointer<UInt8>
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    private let pool: LumaPlanePool

    fileprivate init(
        base: UnsafeMutablePointer<UInt8>,
        width: Int, height: Int, bytesPerRow: Int,
        pool: LumaPlanePool
    ) {
        self.base = base
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pool = pool
    }

    deinit { pool.give(base) }
}

/// One 8-bit monochrome luma image the bench owns outright. The camera's own
/// buffer is released inside the capture callback that produced this frame; see
/// `LumaPlanePool` for why.
public struct MonochromeCameraFrame: @unchecked Sendable {
    public let timestampNanoseconds: UInt64
    public let width: Int
    public let height: Int
    public let lumaPlaneIndex: Int
    private let lease: LumaPlaneLease

    public init(
        timestampNanoseconds: UInt64,
        lease: LumaPlaneLease,
        width: Int,
        height: Int,
        lumaPlaneIndex: Int = 0
    ) {
        self.timestampNanoseconds = timestampNanoseconds
        self.lease = lease
        self.width = width
        self.height = height
        self.lumaPlaneIndex = lumaPlaneIndex
    }

    /// The luma plane and its stride, valid for the duration of `body`.
    public func withLumaPlane<R>(
        _ body: (UnsafePointer<UInt8>, Int) throws -> R
    ) rethrows -> R {
        try body(UnsafePointer(lease.base), lease.bytesPerRow)
    }
}

/// One sensor vector. Core Motion gyroscope values are radians/second. Live
/// transport converts Core Motion accelerometer G values to m/s^2 before IMU
/// assembly. Pairing is the pinned upstream transport rule, not a VIO choice.
public struct MotionVectorSample: Equatable, Sendable {
    public let timestampNanoseconds: UInt64
    public let x: Double
    public let y: Double
    public let z: Double

    public init(timestampNanoseconds: UInt64, x: Double, y: Double, z: Double) {
        self.timestampNanoseconds = timestampNanoseconds
        self.x = x
        self.y = y
        self.z = z
    }
}

/// Selects only the transport adapter required by the frozen engine. Hardware
/// capture stays shared; the estimator-specific conversion happens after the
/// same Core Motion callbacks have produced SI-valued samples.
public enum IMUDeliveryMode: String, Equatable, Sendable {
    case basaltGyroDrivenPaired = "basalt_gyro_driven_paired"
    case xrslamRawSeparateEvents = "xrslam_raw_separate_events"

    static func forBackend(_ backend: BenchBackend) -> IMUDeliveryMode {
        backend == .xrslam ? .xrslamRawSeparateEvents : .basaltGyroDrivenPaired
    }
}

/// XRSLAM's official mobile adapter accepts accelerometer and gyroscope events
/// as distinct timestamped records. Acceleration stays in Core Motion G until
/// the frozen XRSLAM bridge multiplies it by -9.80665; gyroscope values are
/// radians/second. No interpolation or synthetic pairing is permitted here.
public enum RawIMUEvent: Equatable, Sendable {
    case acceleration(MotionVectorSample)
    case gyroscope(MotionVectorSample)

    public var timestampNanoseconds: UInt64 {
        switch self {
        case .acceleration(let sample), .gyroscope(let sample):
            return sample.timestampNanoseconds
        }
    }

    public var sample: MotionVectorSample {
        switch self {
        case .acceleration(let sample), .gyroscope(let sample):
            return sample
        }
    }
}

/// One callback-order-preserving ingress used only by the XRSLAM arm. Camera,
/// accelerometer, and gyroscope callbacks execute on the same serial queue and
/// enter this one bounded handoff, matching the official iOS transport order.
public enum XRSLAMLiveSensorEvent: @unchecked Sendable {
    case camera(MonochromeCameraFrame)
    case imu(RawIMUEvent)
}

/// Frozen unit/axis convention paired with the selected iPhone 14 Pro
/// calibration. Source: `openxrlab/xrslam` revision
/// `4beb1a942f33da9afbfae2d70e2c641cfc2bb675`,
/// `xrslam-ios/visualizer/src/Motion.swift:3,57`: acceleration uses
/// `GRAVITY_NOMINAL = -9.80665`; gyro x/y/z pass through unchanged.
public enum CoreMotionIMUConversion {
    public static let metersPerSecondSquaredPerG = -9.80665

    public static func accelerationMetersPerSecondSquared(
        timestampNanoseconds: UInt64,
        xInG: Double,
        yInG: Double,
        zInG: Double
    ) -> MotionVectorSample {
        MotionVectorSample(
            timestampNanoseconds: timestampNanoseconds,
            x: xInG * metersPerSecondSquaredPerG,
            y: yInG * metersPerSecondSquaredPerG,
            z: zInG * metersPerSecondSquaredPerG
        )
    }

    public static func gyroscopeRadiansPerSecond(
        timestampNanoseconds: UInt64,
        x: Double,
        y: Double,
        z: Double
    ) -> MotionVectorSample {
        MotionVectorSample(timestampNanoseconds: timestampNanoseconds, x: x, y: y, z: z)
    }
}

public struct LiveSensorTransportSnapshot: Equatable, Sendable {
    public let state: SensorTransportLifecycle.State
    public let accounting: SensorTransportAccountingSnapshot
    public let imuDeliveryMode: IMUDeliveryMode
    public let imuAssembly: IMUAssemblyReceipt
    public let cameraHandoff: BoundedSensorHandoff<MonochromeCameraFrame>.Snapshot
    public let imuHandoff: BoundedSensorHandoff<PairedIMUSample>.Snapshot
    public let xrslamSensorHandoff: BoundedSensorHandoff<XRSLAMLiveSensorEvent>.Snapshot
    public let captureFormat: LiveCaptureFormatReceipt?
    /// Bench-owned luma planes: how many exist, the most ever held at once, and
    /// how many frames were refused because all of them were in flight. A
    /// refusal is this bench's own backpressure and is deliberately kept out of
    /// `camera_drops_*`, which stay reserved for AVFoundation's own reasons.
    public let lumaPoolPlanes: Int
    public let lumaPoolPeakHeld: Int
    public let lumaPoolExhaustedDrops: UInt64
    public let lumaPoolSampleMeanLuma: Int
    public let lumaPoolSourceStride: Int
}

public struct LiveCaptureFormatReceipt: Equatable, Sendable {
    public let cameraDeviceType: String
    public let activeFormatIndex: Int
    public let activeFormatMediaSubtype: String
    public let outputPixelFormat: String
    public let width: Int32
    public let height: Int32
    public let selectedFramesPerSecond: Int32
    public let supportedFrameRateRange: String
    public let fieldOfViewDegrees: Double
    /// Lens position this run locked the focus at, or -1 when focus was left
    /// to the system. Upstream's capture class locks on request
    /// (Camera.swift setFocus -> setFocusModeLocked) and pairs that with one
    /// frozen focal length per device; a moving lens makes that calibration
    /// describe only the frame it was measured on.
    public let lockedLensPosition: Double
    public let zoomFactor: Double
    public let rotationDegrees: Double
    public let preferredStabilizationMode: Int
    public let activeStabilizationMode: Int
    public let sessionPreset: String
    /// How many device formats satisfied the frozen requirements. Recorded
    /// because selection among several is a weaker identity than a unique match,
    /// and a reader must be able to tell which one this run had.
    public let matchingFormatCount: Int
    /// Comma separated fourCCs the output offered once it was in the session.
    /// Present so a format refusal is diagnosable from the artifacts alone.
    public let availablePixelFormats: String
    public let grayscaleConversion: String
    public let xrslamPixelPipelineDivergence: String

    public static func fourCC(_ value: OSType) -> String {
        let scalars = [24, 16, 8, 0].map { shift -> UnicodeScalar in
            let byte = UInt8(truncatingIfNeeded: value >> OSType(shift))
            return UnicodeScalar(byte >= 32 && byte <= 126 ? byte : 46)
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
