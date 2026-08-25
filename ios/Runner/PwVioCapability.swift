//  PwVioCapability.swift
//  PocketWorld — Blocker 04:把「逐机型白名单」换成「运行期自证」(iOS 侧)。
//
//  ─────────────────────────────────────────────────────────────────────────
//  这个文件不查机型。没有 device model 字符串,没有查找表,没有 yaml。
//  它只做三件事,全部是**当场读真值**:
//    1. 关掉防抖,并把**实际生效**的状态读回来(请求不等于生效)。
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
//  铁律:本文件只观察与配置,**从不丢数据**。IMU 采样一律 append,不做任何抽稀。

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
    public enum StabilizationState: String {
        case off, on, unknown, absent
    }
    public enum IntrinsicsSource: String {
        case none
        case fieldOfViewFallback
        case staticCharacteristics
        case platformTracker
        case perFrameAttachment
    }
    public enum TimebaseRelation: String {
        case unified, offsetMeasured, unrelatedUnmeasured
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

    /// 第四层:只有视场角。**主点只能假设在正中 —— 这是假设不是测量**,
    /// 所以单独一档,Dart 侧的可信度序把它排在静态标定表之下。
    ///
    ///     fx = (W/2) / tan(hfov/2)
    ///
    /// GDC(几何畸变校正)开着的时候视场角会变,所以这里优先读
    /// geometricDistortionCorrectedVideoFieldOfView(iOS 13+),它在设备不支持 GDC 时
    /// 「matches the videoFieldOfView property」,可以无条件优先用。
    public static func fromFieldOfView(device: AVCaptureDevice,
                                       width: Int,
                                       height: Int) -> PwVioIntrinsics {
        let format = device.activeFormat
        var fov = format.videoFieldOfView
        if #available(iOS 13.0, *) {
            let corrected = format.geometricDistortionCorrectedVideoFieldOfView
            if corrected > 0 { fov = corrected }
        }
        // 头文件:未知时返回 0。0 必须当作"没有",不能当 0 度算。
        guard fov > 0, width > 0, height > 0 else { return .absent }
        let half = Double(fov) * Double.pi / 360.0
        let f = (Double(width) / 2.0) / tan(half)
        return PwVioIntrinsics(source: .fieldOfViewFallback,
                               fx: f, fy: f,
                               cx: Double(width) / 2.0,
                               cy: Double(height) / 2.0,
                               skew: 0,
                               referenceWidth: width,
                               referenceHeight: height)
    }
}

// MARK: - 防抖

public struct PwVioStabilizationReport {
    public let electronic: PwVioWire.StabilizationState
    public let optical: PwVioWire.StabilizationState
    public let electronicControllable: Bool
    public let opticalControllable: Bool
    public let geometricDistortionCorrectionEnabled: Bool?

    public var wire: [String: Any] {
        var d: [String: Any] = [
            "electronic": electronic.rawValue,
            "optical": optical.rawValue,
            "electronicControllable": electronicControllable,
            "opticalControllable": opticalControllable,
        ]
        if let g = geometricDistortionCorrectionEnabled {
            d["geometricDistortionCorrectionEnabled"] = g
        }
        return d
    }
}

public enum PwVioStabilization {

    /// 显式关掉 EIS,然后把**实际生效**的模式读回来。
    ///
    /// 请求与生效是两件事:头文件写明「If the preferred stabilization mode isn't
    /// available, the activeVideoStabilizationMode will be set to
    /// AVCaptureVideoStabilizationModeOff」,而且 active 永远不会返回 .auto。
    /// 所以判据取 active,不取 preferred。
    ///
    /// 🔴 OIS 在 iOS 上没有任何公开 API(见文件头的 grep 阳性对照),
    ///    所以这里**如实报 unknown**,绝不假装关掉了。
    @discardableResult
    public static func disableAndVerify(connection: AVCaptureConnection,
                                        device: AVCaptureDevice) -> PwVioStabilizationReport {
        var eisControllable = false
        if connection.isVideoStabilizationSupported {
            eisControllable = true
            connection.preferredVideoStabilizationMode = .off
        }
        // 读回真实状态。
        let active = connection.activeVideoStabilizationMode
        let eis: PwVioWire.StabilizationState
        if !connection.isVideoStabilizationSupported {
            // 该 connection 上根本没有 EIS 这条路。
            eis = .absent
        } else {
            eis = (active == .off) ? .off : .on
        }

        var gdc: Bool? = nil
        if #available(iOS 13.0, *) {
            if device.isGeometricDistortionCorrectionSupported {
                // 只读不改:GDC 会改变有效视场角与内参口径,开关它是产品决策,
                // 不该由探测器偷偷做。这里如实上报,让 Dart 侧与标定口径对齐。
                gdc = device.isGeometricDistortionCorrectionEnabled
            }
        }

        return PwVioStabilizationReport(
            electronic: eis,
            optical: .unknown,          // iOS 上结构性不可知
            electronicControllable: eisControllable,
            opticalControllable: false, // iOS 上结构性不可控
            geometricDistortionCorrectionEnabled: gdc)
    }
}

// MARK: - 统计小工具(中位 / p95)

enum PwVioStats {
    static func median(_ xs: [Int64]) -> Int64? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// 最近秩法(nearest-rank)p95:第 ceil(0.95·n) 个元素。
    /// 不做插值 —— 插值出来的值在原数据里根本不存在,用来判"有没有掉帧"会失真。
    static func p95(_ xs: [Int64]) -> Int64? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let rank = Int((0.95 * Double(s.count)).rounded(.up))
        return s[min(max(rank - 1, 0), s.count - 1)]
    }
}

// MARK: - IMU 时序探测

/// 采集 (采样戳, 交付戳) 二元组。**纯观察者:只 append,永不丢弃。**
///
/// 两个时钟:
///   CMDeviceMotion.timestamp        —— CMLogItem 的 "Time at which the item is
///                                      valid"。它贴 CLOCK_UPTIME_RAW 还是
///                                      CLOCK_MONOTONIC **Apple 从未文档化**,由
///                                      PwVioTimebase 明早在真机上测定。
///   pwVioCapabilityHostUptimeSeconds() —— 回调里当场读,用来暴露成簇交付。
/// 采样率看前者,成簇看后者 —— 硬件 batching 不会改变采样戳的间隔。
public final class PwVioImuProbe {

    private let motion = CMMotionManager()
    private let queue: OperationQueue
    private let lock = NSLock()
    private var sampleTsNs: [Int64] = []
    private var deliveryTsNs: [Int64] = []

    public init() {
        queue = OperationQueue()
        // 串行:保证回调顺序即到达顺序,否则交付戳的差分没有意义。
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
    }

    public var isAvailable: Bool { return motion.isDeviceMotionAvailable }

    /// requestedHz 只是**请求**。iOS 同样不保证达成,所以我们照量不误。
    public func start(requestedHz: Double = 200.0) {
        guard motion.isDeviceMotionAvailable, !motion.isDeviceMotionActive else { return }
        motion.deviceMotionUpdateInterval = 1.0 / max(requestedHz, 1.0)
        motion.startDeviceMotionUpdates(
            using: .xArbitraryZVertical,
            to: queue
        ) { [weak self] motionSample, _ in
            guard let self = self, let m = motionSample else { return }
            // [pw][vio] 时基测量:必须在 handler 最前面,理由同 ARFrame ——
            //   CMLogItem.timestamp 的域 Apple 只说 "since the device booted",
            //   而 Darwin 上有两个 "since boot" 的钟(CLOCK_UPTIME_RAW 睡眠时停走、
            //   CLOCK_MONOTONIC 不停),差值就是累计休眠。这条只能实测,不能假设。
            PwVioTimebase.shared.noteCoreMotion(timestamp: m.timestamp)
            let delivery = pwVioCapabilityHostUptimeSeconds()
            self.lock.lock()
            self.sampleTsNs.append(Int64((m.timestamp * 1_000_000_000.0).rounded()))
            self.deliveryTsNs.append(Int64((delivery * 1_000_000_000.0).rounded()))
            self.lock.unlock()
        }
    }

    public func stop() {
        if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
    }

    /// 把原始二元组交给 Dart —— **判定在 Dart 侧的 ImuTimingProbe**,
    /// 这样 Otsu 那套算法只有一份实现,两端共用,也只需要一套单测。
    public func drainWire() -> [String: Any] {
        lock.lock()
        let s = sampleTsNs
        let d = deliveryTsNs
        lock.unlock()
        return [
            "available": motion.isDeviceMotionAvailable,
            "sampleTsNs": s.map { NSNumber(value: $0) },
            "deliveryTsNs": d.map { NSNumber(value: $0) },
        ]
    }

    public func reset() {
        lock.lock(); sampleTsNs.removeAll(); deliveryTsNs.removeAll(); lock.unlock()
    }
}

// MARK: - 帧耗时探测

/// 用**交付到手的宿主时刻**量帧间隔,而不是 PTS。
/// 理由:PTS 是传感器曝光时刻,它对"我们这条链路有没有跟上"是失明的 ——
/// 热降频/过载表现为帧到手变慢,而 PTS 仍然规整。要量的是后者。
public final class PwVioFrameTimingProbe {
    private let lock = NSLock()
    private var lastNs: Int64?
    private var intervalsNs: [Int64] = []
    private var count: Int = 0

    public init() {}

    /// 在 captureOutput(_:didOutput:from:) 里每帧调一次。
    public func mark(hostUptimeSeconds: TimeInterval = pwVioCapabilityHostUptimeSeconds()) {
        let ns = Int64((hostUptimeSeconds * 1_000_000_000.0).rounded())
        lock.lock()
        count += 1
        if let last = lastNs, ns > last { intervalsNs.append(ns - last) }
        lastNs = ns
        lock.unlock()
    }

    public func wire() -> [String: Any] {
        lock.lock()
        let iv = intervalsNs
        let n = count
        lock.unlock()
        var d: [String: Any] = ["frameCount": n]
        if let m = PwVioStats.median(iv) { d["medianIntervalNs"] = NSNumber(value: m) }
        if let p = PwVioStats.p95(iv) { d["p95IntervalNs"] = NSNumber(value: p) }
        return d
    }

    public func reset() {
        lock.lock(); lastNs = nil; intervalsNs.removeAll(); count = 0; lock.unlock()
    }
}

// MARK: - 汇总

public enum PwVioCapability {

    /// 把一次会话的全部事实打包成 Dart 侧 CapabilityEvidence 能直接吃的字典。
    ///
    /// 🔴 timebase **不在这里硬编码**。业界普遍默认「CoreMotion == mach_absolute_time」,
    /// 但 Apple 从没这么写过;若 CMDeviceMotion.timestamp 实际贴的是 CLOCK_MONOTONIC
    /// 而相机 PTS 贴的是 CLOCK_UPTIME_RAW,iPhone 上就会出现与 Android 一样的域错配,
    /// 且随待机时长增长。该结论由 PwVioTimebase 在真机上测定后传进来。
    /// 探测器不替它下结论 —— 这正是把判定留在 Dart 侧的原因。
    public static func evidenceWire(
        timebaseRelation: PwVioWire.TimebaseRelation,
        timebaseUncertaintyNs: Int64?,
        stabilization: PwVioStabilizationReport,
        intrinsics: PwVioIntrinsics,
        imu: [String: Any],
        frameTiming: [String: Any],
        platformPoseAvailable: Bool
    ) -> [String: Any] {
        return [
            "timebase": [
                "relation": timebaseRelation.rawValue,
                "offsetUncertaintyNs": timebaseUncertaintyNs.map { NSNumber(value: $0) }
                    ?? NSNull(),
            ],
            "stabilization": stabilization.wire,
            "intrinsics": intrinsics.wire,
            "imu": imu,
            "frameTiming": frameTiming,
            // iOS 没有 SENSOR_ROLLING_SHUTTER_SKEW 的对应物 —— 如实缺省。
            "rollingShutter": ["readoutNs": NSNull()],
            "platformPoseAvailable": platformPoseAvailable,
        ]
    }
}
