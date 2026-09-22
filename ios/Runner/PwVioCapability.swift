//  PwVioCapability.swift
//  PocketWorld — Blocker 04:把「逐机型白名单」换成「运行期自证」(iOS 侧)。
//
//  ─────────────────────────────────────────────────────────────────────────
//  这个文件不查机型。没有 device model 字符串,没有查找表,没有 yaml。
//  它只做三件事,全部是**当场读真值**:
//    1. 机械执行 Dart 传入的原始防抖 mode,并读回原始请求/活动值。
//    2. 按四层优先级把内参读出来,并原样带上它所参照的分辨率。
//    3. 量 IMU 的实际速率/交付节奏,量实际帧耗时。
//  然后把这些事实原样交给 Dart 侧的 CapabilityProbe 去判档
//  (lib/vio/capability/capability_probe.dart)。**判定逻辑不在 Swift 里。**
//
//  ─────────────────────────────────────────────────────────────────────────
//  以下每条 API 事实都是从 iPhoneOS26.2.sdk 头文件里直接核对过的,不是回忆:
//
//  • AVCaptureSession.h(cameraIntrinsicMatrixDeliverySupported)原文:
//      "Note that if video stabilization is enabled (preferredVideoStabilizationMode
//       is set to something other than AVCaptureVideoStabilizationModeOff), camera
//       intrinsic matrix delivery is not supported."
//    ⇒ 内参下发与防抖**互斥**。这给了我们一个免费的自证:能拿到逐帧内参,
//      本身就是 EIS 关着的强证据。(但仍以 activeVideoStabilizationMode 读回为准 ——
//      preferredVideoStabilizationMode 在 session 跑起来之后仍可被改,而
//      cameraIntrinsicMatrixDeliveryEnabled "must be set before the session starts
//      running",两者的生命周期不同,所以不能拿前者当后者的证明。)
//
//  • AVCaptureDevice.h:2311 原文:
//      "...the pixels in stabilized video frames no longer match the relative
//       extrinsicMatrix ... The extrinsicMatrix and camera intrinsics should only be
//       used when video stabilization is disabled."
//    ⇒ 防抖开着 = 像素与物理位姿脱钩。这是 Apple 自己说的,不是我们的推测。
//
//  • 🔴 OIS:在整个 iPhoneOS26.2.sdk 的 System/Library/Frameworks 下
//    `grep -rli "opticalImageStabilization"` 命中 **0 个文件**
//    (同一条 grep 对 "preferredVideoStabilizationMode" 命中 4 个文件作为阳性对照)。
//    ⇒ iOS 上 OIS **既不可查也不可关**。任何声称"关掉了 iOS 的 OIS"的代码都是假的。
//      我们只能把它记为 unknown,由 Dart 侧判成 stabilizationUnverifiable → 降级。
//      (对照:Android 有 LENS_OPTICAL_STABILIZATION_MODE = OFF,真的关得掉。)
//
//  • AVCapturePhotoOutput 那条内参路**对我们不可用**:头文件写明
//    cameraCalibrationDataDeliveryEnabled 只有在
//    "2 or more devices are selected for virtual device constituent photo delivery"
//    时才能置 YES,且要求 contentAwareDistortionCorrectionEnabled == NO 且
//    geometricDistortionCorrectionEnabled == NO。单摄采集永远拿不到。
//    ⇒ 逐帧内参只能走 AVCaptureConnection.cameraIntrinsicMatrixDeliveryEnabled,
//      它只在 AVCaptureVideoDataOutput 的 connection 上可用。
//
//  • AVCaptureDevice.Format.videoFieldOfView 是**水平**视场角,单位度;
//    头文件:"If field of view is unknown, a value of 0 is returned."
//    所以 0 必须当作"没有",不能当作 0 度。
//
//  ─────────────────────────────────────────────────────────────────────────
//  铁律:本文件只观察与配置,不做统计判定。高频事实只写固定容量环形缓冲;
//  一旦覆盖,attempted/retained/overwritten/capacity 四账必须精确闭合。

import AVFoundation
import CoreMedia
import CoreMotion
import Foundation
import simd

#if canImport(ARKit)
import ARKit
#endif

// MARK: - 宿主时钟
//
// ⛔ 这里**刻意不用** ProcessInfo.processInfo.systemUptime。Apple 把它列为
//    Required Reason API(fingerprinting 风险):用了就必须在
//    ios/Runner/PrivacyInfo.xcprivacy 里申报理由。我们要的东西
//    clock_gettime_nsec_np(CLOCK_UPTIME_RAW) 全能给,没必要给上架流程添一条申报。
//    (这条是与 PwVioTimebase.swift 对齐的口径;那边有同名的
//     pwVioTimebaseUptimeRawSeconds()。这里保留一份独立的一行实现,
//     是为了不让本文件依赖另一条并发开发中的文件。)
//
// man 原文:CLOCK_UPTIME_RAW 与 mach_absolute_time() 换算结果完全相同,
// 且休眠期间不走 —— 交付节奏只关心运行期,这正是我们要的语义。
@inline(__always)
public func pwVioCapabilityHostUptimeSeconds() -> Double {
    return Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
}

// MARK: - 与 Dart 侧对齐的字符串常量
//
// 这些字符串必须与 lib/vio/capability/capability_evidence.dart 的 enum name 一致。
// 用常量而不是散落的字面量,是为了让改名时编译器至少能帮上一点忙。
public enum PwVioWire {
    public enum IntrinsicsSource: String {
        case none
        case fieldOfViewFallback
        case staticCharacteristics
        case platformTracker
        case perFrameAttachment
    }
}

// MARK: - 内参

public struct PwVioIntrinsics {
    public let source: PwVioWire.IntrinsicsSource
    public let fx: Double
    public let fy: Double
    public let cx: Double
    public let cy: Double
    public let skew: Double
    public let referenceWidth: Int
    public let referenceHeight: Int

    public static let absent = PwVioIntrinsics(
        source: .none, fx: 0, fy: 0, cx: 0, cy: 0, skew: 0,
        referenceWidth: 0, referenceHeight: 0)

    public var wire: [String: Any] {
        return [
            "source": source.rawValue,
            "fx": fx, "fy": fy, "cx": cx, "cy": cy, "skew": skew,
            "referenceWidth": referenceWidth,
            "referenceHeight": referenceHeight,
        ]
    }

    /// 从 simd 的列主序 K 矩阵取值。
    /// 列 0 = (fx, 0, 0)、列 1 = (s, fy, 0)、列 2 = (cx, cy, 1)。
    /// 🔴 写成 columns.0.y 之类是最常见的转置错;这里显式按列取,并在
    ///    principalPointPlausible(Dart 侧)上有兜底检查。
    init(matrix m: matrix_float3x3,
         referenceWidth w: Int,
         referenceHeight h: Int,
         source: PwVioWire.IntrinsicsSource) {
        self.source = source
        self.fx = Double(m.columns.0.x)
        self.fy = Double(m.columns.1.y)
        self.skew = Double(m.columns.1.x)
        self.cx = Double(m.columns.2.x)
        self.cy = Double(m.columns.2.y)
        self.referenceWidth = w
        self.referenceHeight = h
    }

    init(source: PwVioWire.IntrinsicsSource, fx: Double, fy: Double,
         cx: Double, cy: Double, skew: Double,
         referenceWidth: Int, referenceHeight: Int) {
        self.source = source
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
        self.skew = skew
        self.referenceWidth = referenceWidth
        self.referenceHeight = referenceHeight
    }
}

public enum PwVioIntrinsicsReader {

    /// 第一层:逐帧下发。**必须在 session 启动之前调用。**
    /// 返回是否真的打开了 —— 不支持时返回 false,不抛异常,由上层降级。
    @discardableResult
    public static func enablePerFrameDelivery(on connection: AVCaptureConnection) -> Bool {
        guard connection.isCameraIntrinsicMatrixDeliverySupported else { return false }
        connection.isCameraIntrinsicMatrixDeliveryEnabled = true
        return connection.isCameraIntrinsicMatrixDeliveryEnabled
    }

    /// 第一层:从一帧里把内参取出来。
    ///
    /// 参考分辨率取的是**这个 sample buffer 自己的**尺寸 —— 该 attachment 不像
    /// AVCameraCalibrationData 那样自带 intrinsicMatrixReferenceDimensions,
    /// 它对应的就是所交付的这一帧。把尺寸一起带走,Dart 侧才能做 remap。
    public static func fromSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> PwVioIntrinsics? {
        guard let raw = CMGetAttachment(
            sampleBuffer,
            key: kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix,
            attachmentModeOut: nil) as? Data,
            raw.count >= MemoryLayout<matrix_float3x3>.size
        else { return nil }

        let m: matrix_float3x3 = raw.withUnsafeBytes { buf in
            buf.loadUnaligned(as: matrix_float3x3.self)
        }
        guard let fd = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        return PwVioIntrinsics(matrix: m,
                               referenceWidth: Int(dims.width),
                               referenceHeight: Int(dims.height),
                               source: .perFrameAttachment)
    }

    #if canImport(ARKit)
    /// 第二层:平台跟踪器自报。ARCamera.intrinsics 参照的是 ARCamera.imageResolution。
    @available(iOS 11.0, *)
    public static func fromARCamera(_ camera: ARCamera) -> PwVioIntrinsics {
        return PwVioIntrinsics(matrix: camera.intrinsics,
                               referenceWidth: Int(camera.imageResolution.width),
                               referenceHeight: Int(camera.imageResolution.height),
                               source: .platformTracker)
    }
    #endif

    /// 第四层只搬运平台原始 FOV 与参考尺寸。选择 corrected/raw、判断 0 是否
    /// 可用、主点假设和 f=(W/2)/tan(hfov/2) 全由 Dart 的
    /// IntrinsicsFacts.fromHorizontalFov 统一处理。
    public static func fieldOfViewWire(device: AVCaptureDevice,
                                       width: Int,
                                       height: Int) -> [String: Any] {
        let format = device.activeFormat
        var corrected: Any = NSNull()
        if #available(iOS 13.0, *) {
            corrected = Double(
                format.geometricDistortionCorrectedVideoFieldOfView)
        }
        return [
            "videoFieldOfViewDegrees": Double(format.videoFieldOfView),
            "geometricDistortionCorrectedVideoFieldOfViewDegrees": corrected,
            "referenceWidth": width,
            "referenceHeight": height,
        ]
    }
}

// MARK: - 防抖

public struct PwVioStabilizationRawReport {
    public let videoStabilizationSupported: Bool
    public let requestedPreferredModeRawValue: Int
    public let requestedPreferredModeRecognized: Bool
    public let preferredModeAssignmentPerformed: Bool
    public let activeVideoStabilizationModeRawValue: Int
    public let geometricDistortionCorrectionSupported: Bool
    public let geometricDistortionCorrectionEnabled: Bool
    public let opticalImageStabilizationPublicApiAvailable: Bool

    public var wire: [String: Any] {
        return [
            "schema": "pw.vio.ios.stabilization-raw/1",
            "videoStabilizationSupported": videoStabilizationSupported,
            "requestedPreferredModeRawValue": requestedPreferredModeRawValue,
            "requestedPreferredModeRecognized": requestedPreferredModeRecognized,
            "preferredModeAssignmentPerformed": preferredModeAssignmentPerformed,
            "activeVideoStabilizationModeRawValue": activeVideoStabilizationModeRawValue,
            "geometricDistortionCorrectionSupported": geometricDistortionCorrectionSupported,
            "geometricDistortionCorrectionEnabled": geometricDistortionCorrectionEnabled,
            "opticalImageStabilizationPublicApiAvailable": opticalImageStabilizationPublicApiAvailable,
        ]
    }
}

public enum PwVioStabilization {

    /// 原生层不选 mode,不解释 mode,也不产出可控性结论。
    /// [requestedPreferredModeRawValue] 必须由跨端 Dart 策略显式传入;
    /// 本方法只在平台声称支持且 raw value 能构造成 SDK enum 时机械赋值,
    /// 然后返回赋值事实和 active raw value,供 Dart 判定。
    @discardableResult
    public static func configureAndReadRaw(
        connection: AVCaptureConnection,
        device: AVCaptureDevice,
        requestedPreferredModeRawValue: Int
    ) -> PwVioStabilizationRawReport {
        let supported = connection.isVideoStabilizationSupported
        let requestedMode = AVCaptureVideoStabilizationMode(
            rawValue: requestedPreferredModeRawValue)
        let recognized = requestedMode != nil
        let assignmentPerformed = supported && recognized
        if assignmentPerformed, let mode = requestedMode {
            connection.preferredVideoStabilizationMode = mode
        }

        var gdcSupported = false
        var gdcEnabled = false
        if #available(iOS 13.0, *) {
            gdcSupported = device.isGeometricDistortionCorrectionSupported
            gdcEnabled = device.isGeometricDistortionCorrectionEnabled
        }

        return PwVioStabilizationRawReport(
            videoStabilizationSupported: supported,
            requestedPreferredModeRawValue: requestedPreferredModeRawValue,
            requestedPreferredModeRecognized: recognized,
            preferredModeAssignmentPerformed: assignmentPerformed,
            activeVideoStabilizationModeRawValue:
                connection.activeVideoStabilizationMode.rawValue,
            geometricDistortionCorrectionSupported: gdcSupported,
            geometricDistortionCorrectionEnabled: gdcEnabled,
            opticalImageStabilizationPublicApiAvailable: false)
    }
}

// MARK: - IMU 时序探测

private struct PwVioImuArrival {
    let sampleTsNs: Int64
    let deliveryTsNs: Int64
}

/// 采集 (采样戳, 交付戳) 二元组。原生侧只保留固定容量的最近窗口,
/// 不算速率、抖动或成簇;发生覆盖时在 wire 里精确记账。
///
/// 两个时钟:
///   CMGyroData.timestamp            —— CMLogItem 的 "Time at which the item is
///                                      valid"。它贴 CLOCK_UPTIME_RAW 还是
///                                      CLOCK_MONOTONIC **Apple 从未文档化**,由
///                                      PwVioTimebase 明早在真机上测定。
///   pwVioCapabilityHostUptimeSeconds() —— 回调里当场读,用来暴露成簇交付。
/// 采样率看前者,成簇看后者 —— 硬件 batching 不会改变采样戳的间隔。
public final class PwVioImuProbe {

    private static let capacity = 4096
    private let motion = CMMotionManager()
    private let queue: OperationQueue
    private let lock = NSLock()
    private var imuArrivalRing = [PwVioImuArrival?](
        repeating: nil,
        count: PwVioImuProbe.capacity)
    private var writeIndex = 0
    private var retainedCount = 0
    private var attemptedCount = 0
    private var overwrittenCount = 0

    public init() {
        queue = OperationQueue()
        // 串行:保证回调顺序即到达顺序,否则交付戳的差分没有意义。
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    public var isAvailable: Bool { return motion.isGyroAvailable }

    /// requestedHz 只是**请求**。它必须由跨端 Dart 配置显式传入;原生侧不设默认、
    /// 不夹紧。iOS 不保证达成,所以实际速率仍由 Dart 从原始时间戳测量。
    @discardableResult
    public func start(requestedHz: Double) -> Bool {
        guard requestedHz.isFinite, requestedHz > 0 else { return false }
        let requestedInterval = 1.0 / requestedHz
        guard requestedInterval.isFinite, requestedInterval > 0 else { return false }
        guard motion.isGyroAvailable, !motion.isGyroActive else {
            return false
        }
        motion.gyroUpdateInterval = requestedInterval
        motion.startGyroUpdates(to: queue) { [weak self] gyroSample, _ in
            guard let self = self, let sample = gyroSample else { return }
            // [pw][vio] 时基测量:必须在 handler 最前面,理由同 ARFrame ——
            //   CMLogItem.timestamp 的域 Apple 只说 "since the device booted",
            //   而 Darwin 上有两个 "since boot" 的钟(CLOCK_UPTIME_RAW 睡眠时停走、
            //   CLOCK_MONOTONIC 不停),差值就是累计休眠。这条只能实测,不能假设。
            PwVioTimebase.shared.noteCoreMotionGyroscope(
                timestamp: sample.timestamp)
            let delivery = pwVioCapabilityHostUptimeSeconds()
            let arrival = PwVioImuArrival(
                sampleTsNs: Int64((sample.timestamp * 1_000_000_000.0).rounded()),
                deliveryTsNs: Int64((delivery * 1_000_000_000.0).rounded()))
            self.lock.lock()
            self.attemptedCount += 1
            self.imuArrivalRing[self.writeIndex] = arrival
            self.writeIndex = (self.writeIndex + 1) % Self.capacity
            if self.retainedCount < Self.capacity {
                self.retainedCount += 1
            } else {
                self.overwrittenCount += 1
            }
            self.lock.unlock()
        }
        return motion.isGyroActive
    }

    public func stop() {
        if motion.isGyroActive { motion.stopGyroUpdates() }
    }

    /// 把原始二元组交给 Dart —— **判定在 Dart 侧的 ImuTimingProbe**,
    /// 这样 Otsu 那套算法只有一份实现,两端共用,也只需要一套单测。
    public func drainWire() -> [String: Any] {
        lock.lock()
        let n = retainedCount
        let attempted = attemptedCount
        let overwritten = overwrittenCount
        let oldest = n == Self.capacity ? writeIndex : 0
        var arrivals = [PwVioImuArrival]()
        arrivals.reserveCapacity(n)
        if n > 0 {
            for offset in 0..<n {
                let index = (oldest + offset) % Self.capacity
                if let arrival = imuArrivalRing[index] { arrivals.append(arrival) }
            }
        }
        lock.unlock()
        return [
            "schema": "pw.vio.imu-arrivals.raw.v1",
            "available": motion.isGyroAvailable,
            "sampleTsNs": arrivals.map { NSNumber(value: $0.sampleTsNs) },
            "deliveryTsNs": arrivals.map { NSNumber(value: $0.deliveryTsNs) },
            "attemptedCount": NSNumber(value: attempted),
            "retainedCount": n,
            "overwrittenCount": NSNumber(value: overwritten),
            "capacity": Self.capacity,
        ]
    }

    public func reset() {
        lock.lock()
        imuArrivalRing = [PwVioImuArrival?](repeating: nil, count: Self.capacity)
        writeIndex = 0
        retainedCount = 0
        attemptedCount = 0
        overwrittenCount = 0
        lock.unlock()
    }
}

// MARK: - 帧耗时探测

/// 用**交付到手的宿主时刻**量帧间隔,而不是 PTS。
/// 理由:PTS 是传感器曝光时刻,它对"我们这条链路有没有跟上"是失明的 ——
/// 热降频/过载表现为帧到手变慢,而 PTS 仍然规整。要量的是后者。
public final class PwVioFrameTimingProbe {
    private static let capacity = 512
    private let lock = NSLock()
    private var arrivalHostTsNs = [Int64](
        repeating: 0,
        count: PwVioFrameTimingProbe.capacity)
    private var writeIndex = 0
    private var retainedCount = 0
    private var attemptedCount = 0
    private var overwrittenCount = 0

    public init() {}

    /// 在 captureOutput(_:didOutput:from:) 里每帧调一次。
    public func mark(hostUptimeSeconds: TimeInterval = pwVioCapabilityHostUptimeSeconds()) {
        let ns = Int64((hostUptimeSeconds * 1_000_000_000.0).rounded())
        lock.lock()
        attemptedCount += 1
        arrivalHostTsNs[writeIndex] = ns
        writeIndex = (writeIndex + 1) % Self.capacity
        if retainedCount < Self.capacity {
            retainedCount += 1
        } else {
            overwrittenCount += 1
        }
        lock.unlock()
    }

    public func wire() -> [String: Any] {
        lock.lock()
        let n = retainedCount
        let attempted = attemptedCount
        let overwritten = overwrittenCount
        let oldest = n == Self.capacity ? writeIndex : 0
        var arrivals = [Int64]()
        arrivals.reserveCapacity(n)
        if n > 0 {
            for offset in 0..<n {
                arrivals.append(arrivalHostTsNs[(oldest + offset) % Self.capacity])
            }
        }
        lock.unlock()
        return [
            "schema": "pw.vio.frame-arrivals.raw.v1",
            "arrivalHostTsNs": arrivals.map { NSNumber(value: $0) },
            "attemptedCount": NSNumber(value: attempted),
            "retainedCount": n,
            "overwrittenCount": NSNumber(value: overwritten),
            "capacity": Self.capacity,
        ]
    }

    public func reset() {
        lock.lock()
        arrivalHostTsNs = [Int64](repeating: 0, count: Self.capacity)
        writeIndex = 0
        retainedCount = 0
        attemptedCount = 0
        overwrittenCount = 0
        lock.unlock()
    }
}
