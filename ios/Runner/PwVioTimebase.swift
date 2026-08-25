// PwVioTimebase.swift — iOS 侧时基**测量**(不做假设、不做判决)。
//
// 判决全部在 Dart 侧 lib/vio/timebase/ 里做,两端共用同一份算法。平台代码一旦
// 自己判档/自己对齐,就会重演 XRSLAM_IOS 那个宏的老问题:两端跑结构性不同的
// 算法。所以本文件**只做三件事**:读时钟、配对采样、上报。
//
// ════════════════════════════════════════════════════════════════════════
// 一、四路时间戳到底在不在同一个域?—— 逐条查过一手文档/SDK 头,不是凭印象
// ════════════════════════════════════════════════════════════════════════
//
// ① `CMDeviceMotion.timestamp`(继承自 `CMLogItem.timestamp`)
//    Apple 原文,全文只有一句:
//      "The timestamp is the amount of time in seconds since the device booted."
//    🔴 **「since the device booted」有歧义**:含不含休眠?Apple 没说。
//       在 Darwin 上这两种「自启动」是**两个不同的钟**(见③),差值就是累计
//       休眠时长。所以这一句**不足以**确定域,必须实测。
//
// ② `CMSampleBuffer.presentationTimeStamp`
//    Apple 没在该属性上写域;域写在 `AVCaptureSession.synchronizationClock`
//    (iPhoneOS26.2.sdk / AVCaptureSession.h:626,原文):
//      "Use synchronizationClock to synchronize AVCaptureOutput data with
//       external data sources (e.g motion samples). All capture output sample
//       buffer timestamps are on the synchronizationClock timebase."
//    并且 SDK 头里给的示范代码是:
//      CMTime originalPTS = CMSyncConvertTime(syncedPTS,
//                             [session synchronizationClock], originalClock);
//    ⇒ Apple 的措辞始终是「**用这个钟去换算**」,从来不是「直接可比」。
//    可用性(SDK 头实证):
//      synchronizationClock  API_AVAILABLE(ios(15.4))   ← 本工程 deployment
//                                                          target 是 15.0,
//                                                          所以必须 #available
//      masterClock           API_DEPRECATED ios(7.0, 15.4)  ← 15.0–15.3 的回退
//
// ③ `ARFrame.timestamp`
//    Apple 文档**全文只有一句**:"The time at which the frame was captured."
//    🔴 **没有时钟域、没有参考原点、没有 Discussion。** ARKit 也不把
//       CMSampleBuffer 交出来,所以②那条 synchronizationClock 的桥在这条链上
//       **用不了**。本类对 ARKit 一路**只测量**,绝不假设。
//
// ④ 参考钟的候选(`man 3 clock_gettime`,原文):
//      CLOCK_UPTIME_RAW  "clock that increments monotonically, in the same
//                         manner as CLOCK_MONOTONIC_RAW, but that **does not
//                         increment while the system is asleep**. The returned
//                         value is **identical to the result of
//                         mach_absolute_time()** after the appropriate
//                         mach_timebase conversion is applied."
//      CLOCK_MONOTONIC   "clock that increments monotonically, tracking the
//                         time since an arbitrary point, and **will continue to
//                         increment while the system is asleep**."
//
// ════════════════════════════════════════════════════════════════════════
// 二、🔴 本文件最重要的一条结论:iOS 有和 Android **一模一样**的休眠陷阱
// ════════════════════════════════════════════════════════════════════════
// Android 的病因是 `elapsedRealtimeNanos`(含休眠)与 `nanoTime`(不含休眠)
// 之差 = 累计休眠时长。而 Darwin 上 `CLOCK_MONOTONIC`(含休眠)与
// `CLOCK_UPTIME_RAW`(不含休眠)是**同一对关系**。
//
// 于是:如果 `CMDeviceMotion.timestamp` 的「since the device booted」实际是
// CLOCK_MONOTONIC 语义,而相机 PTS 经 host clock 落在 CLOCK_UPTIME_RAW 语义上,
// 那么**iPhone 上会出现和 Android 完全相同的域错配**,而且随机器待机时长增长。
// 业界普遍默认「CoreMotion == mach_absolute_time」,但 Apple **从没这么写过**。
//
// 所以 [PwVioTimebase] 对每一路都**同时**测到两个基准
// ([PwVioClockPair.uptimeRawSeconds] / [PwVioClockPair.monotonicSeconds]),
// 明早在真机上一眼就能看出 CoreMotion 贴着哪一个。这是本文件存在的首要理由。
//
// ════════════════════════════════════════════════════════════════════════
// 三、曝光起点还是曝光中心 —— Apple 未文档化,所以做成**可标定常量**
// ════════════════════════════════════════════════════════════════════════
// 本类**不**替 Dart 施加曝光修正(修正量是 Dart 侧
// `TimebaseNormalizerConfig.exposureCenterFraction`,默认 0.25 = minimax)。
// 本类只负责把**每帧真实曝光时长**捞出来交上去,因为不确定度 = fraction × D,
// 没有 D 就没法把这笔账记在明面上:
//   • AVCapture 链:`AVCaptureDevice.exposureDuration`(CMTime,iOS 8.0+)
//   • ARKit 链:`ARFrame.exifData`(NSDictionary,**iOS 16.0+**,SDK 头实证
//     ARFrame.h:88)里的 `kCGImagePropertyExifExposureTime`(ImageIO,iOS 4.0+)
//     iOS 15 上没有 exifData ⇒ 返回 nil ⇒ Dart 侧只能按 0 记账并**如实标注**。
//
// ════════════════════════════════════════════════════════════════════════
// 四、刻意没用的 API
// ════════════════════════════════════════════════════════════════════════
// ⛔ `ProcessInfo.processInfo.systemUptime` —— Apple 文档原文把它列为
//    fingerprinting 风险 API:"When you use this API in your app or third-party
//    SDK ..., declare your usage and the reason ... in your app or third-party
//    SDK's `PrivacyInfo.xcprivacy` file."
//    我们要的东西 `clock_gettime_nsec_np` 全能给,没必要给上架流程添一条
//    Required Reason 申报。

import AVFoundation
import CoreMedia
import CoreMotion
import Foundation
import ImageIO

#if canImport(ARKit)
  import ARKit
#endif

#if canImport(Flutter)
  import Flutter
#endif

// MARK: - 通道名(必须与 Dart 侧一致)

public enum PwVioTimebaseIdentifiers {
  public static let methodChannel = "pocketworld_vio_timebase"
}

// MARK: - 两个候选参考钟

/// CLOCK_UPTIME_RAW,秒。man 原文:与 `mach_absolute_time()` 换算结果**完全相同**,
/// 且**休眠期间不走**。
@inline(__always)
public func pwVioTimebaseUptimeRawSeconds() -> Double {
  return Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) * 1e-9
}

/// CLOCK_MONOTONIC,秒。man 原文:**休眠期间继续走**。
/// 与上面那个之差 = 开机以来累计休眠时长(Darwin 版的 elapsedRealtime − nanoTime)。
@inline(__always)
public func pwVioTimebaseMonotonicSeconds() -> Double {
  return Double(clock_gettime_nsec_np(CLOCK_MONOTONIC)) * 1e-9
}

/// 一次「同时」读两个参考钟的结果,附读取开销(Cristian 夹逼的宽度)。
public struct PwVioClockPair {
  public let uptimeRawSeconds: Double
  public let monotonicSeconds: Double
  /// 读取这一对所花的时间(秒)。它就是本次配对的**硬**误差界。
  public let readCostSeconds: Double

  /// 累计休眠时长(秒)= monotonic − uptimeRaw。
  public var accumulatedSleepSeconds: Double { monotonicSeconds - uptimeRawSeconds }
}

/// 三明治采样:uptime → monotonic → uptime。中间那次的物理时刻被夹在两端之间。
@inline(__always)
public func pwVioTimebaseSampleClockPair() -> PwVioClockPair {
  let a = pwVioTimebaseUptimeRawSeconds()
  let m = pwVioTimebaseMonotonicSeconds()
  let c = pwVioTimebaseUptimeRawSeconds()
  return PwVioClockPair(
    uptimeRawSeconds: (a + c) * 0.5,
    monotonicSeconds: m,
    readCostSeconds: max(0.0, c - a)
  )
}

// MARK: - min-filter(与 Dart 侧 ClockOffsetEstimator 同一算法)

/// 单边非负投递延迟下的偏置估计:δ = t_ref − t_src = θ + d,d ≥ 0。
/// 取滑动时间窗内的 **min(δ)** —— 偏差 = min(d),随样本数趋于 0;
/// 均值/中位数的偏差是 E[d]/median(d),不收敛。
///
/// 窗必须是**滑动**的:全历史 min 在存在漂移时单调不增,永远追不上漂移,
/// 而我们正要用相邻窗 min 之差来测漂移。
public final class PwVioMinFilter {
  public struct Estimate {
    public let offsetSeconds: Double
    public let jitterSeconds: Double   // p50 − min,θ̂ 偏差的量级
    public let sampleCount: Int
    public let spanSeconds: Double
    public let driftPpm: Double
    public let driftPpmUncertainty: Double
    public var driftIsSignificant: Bool { abs(driftPpm) > driftPpmUncertainty }
  }

  private let windowSpanSeconds: Double
  private let minSamples: Int
  private let maxSamples: Int

  private var refs: [Double] = []
  private var deltas: [Double] = []

  private var anchorOffset: Double?
  private var anchorRef: Double?
  private var anchorJitter: Double = 0

  public private(set) var totalAdded: Int = 0

  public init(windowSpanSeconds: Double = 4.0, minSamples: Int = 16, maxSamples: Int = 4096) {
    self.windowSpanSeconds = windowSpanSeconds
    self.minSamples = minSamples
    self.maxSamples = maxSamples
  }

  public func reset() {
    refs.removeAll(keepingCapacity: true)
    deltas.removeAll(keepingCapacity: true)
    anchorOffset = nil
    anchorRef = nil
    anchorJitter = 0
  }

  public func add(srcSeconds: Double, refSeconds: Double) {
    totalAdded += 1
    refs.append(refSeconds)
    deltas.append(refSeconds - srcSeconds)

    let cutoff = refSeconds - windowSpanSeconds
    var drop = 0
    while drop < refs.count && refs[drop] < cutoff { drop += 1 }
    if refs.count - drop < minSamples { drop = max(0, refs.count - minSamples) }
    if drop > 0 {
      refs.removeFirst(drop)
      deltas.removeFirst(drop)
    }
    if refs.count > maxSamples {
      let extra = refs.count - maxSamples
      refs.removeFirst(extra)
      deltas.removeFirst(extra)
    }
  }

  public func estimate() -> Estimate? {
    guard refs.count >= minSamples else { return nil }
    let sorted = deltas.sorted()
    let minDelta = sorted[0]
    let p50 = sorted[sorted.count / 2]
    let jitter = p50 - minDelta
    let refFirst = refs.first!
    let refLast = refs.last!

    if anchorOffset == nil {
      anchorOffset = minDelta
      anchorRef = refLast
      anchorJitter = jitter
    }

    var driftPpm = 0.0
    var driftUnc = Double.infinity
    let driftSpan = refLast - anchorRef!
    if driftSpan > 0 {
      driftPpm = (minDelta - anchorOffset!) / driftSpan * 1e6
      driftUnc = (jitter + anchorJitter) / driftSpan * 1e6
    }

    return Estimate(
      offsetSeconds: minDelta,
      jitterSeconds: jitter,
      sampleCount: refs.count,
      spanSeconds: refLast - refFirst,
      driftPpm: driftPpm,
      driftPpmUncertainty: driftUnc
    )
  }
}

// MARK: - 一路时间戳源的测量结果

public struct PwVioSourceMeasurement {
  public let sourceName: String
  /// 该路最近一次的原始戳(平台原样,秒)。
  public let lastRawSeconds: Double
  /// 相对 CLOCK_UPTIME_RAW 的偏置(min-filter)。
  public let offsetToUptimeRaw: PwVioMinFilter.Estimate?
  /// 相对 CLOCK_MONOTONIC 的偏置(min-filter)。
  /// 🔴 两者哪个的 |offset| 更接近 0,就说明这一路贴着哪个基准。
  public let offsetToMonotonic: PwVioMinFilter.Estimate?
  public let sampleCount: Int
}

// MARK: - 测量器主体

/// 时基测量器。**只测,不判。**
///
/// 线程安全:相机/ARKit/CoreMotion 的回调分别来自不同队列,所有可变状态都在
/// `lock` 内。锁内只做几次数组操作,不做 IO,不回调出去。
public final class PwVioTimebase {

  public static let shared = PwVioTimebase()

  /// 最新一帧的相机内参。nil = ARKit 还没跑过任何一帧。
  /// 读写都在 [lock] 下 —— ARFrame 回调与 Flutter channel 不在同一队列。
  private var latestIntrinsics: [String: Any]?

  /// 供 Flutter channel 取。返回 nil 时调用方**必须**如实标成 PLACEHOLDER,
  /// 不要退回一组编出来的数 —— 那正是我们要避免的东西。
  public func snapshotIntrinsics() -> [String: Any]? {
    lock.lock(); defer { lock.unlock() }
    return latestIntrinsics
  }

  private let lock = NSLock()

  // 每一路都同时对两个参考钟建一条 min-filter —— 这就是「不做假设」的实现。
  private var filters: [String: (uptime: PwVioMinFilter, mono: PwVioMinFilter)] = [:]
  private var lastRaw: [String: Double] = [:]
  private var counts: [String: Int] = [:]

  /// 会话起点的时钟对(用来算整段会话内累计休眠的增量)。
  private var sessionStartPair: PwVioClockPair?
  /// 最近一次时钟对。
  private var latestPair: PwVioClockPair?
  /// 会话内观测到的休眠增量(秒)。>0 表示会话跨越了休眠 —— 这正是
  /// 「一次会话只测一次偏置」不够用的证据。
  public private(set) var sessionSleepDeltaSeconds: Double = 0

  /// 相机 PTS 经 `synchronizationClock` → host clock 换算失败的次数。
  public private(set) var syncClockUnavailableCount: Int = 0

  public static let sourceCoreMotion = "coreMotion"
  public static let sourceArFrame = "arFrame"
  public static let sourceCaptureRawPts = "capturePtsRaw"
  public static let sourceCaptureHostPts = "capturePtsHost"

  public init() {}

  // MARK: 会话生命周期

  /// 会话开始时调用。清空所有测量,重新锚定。
  public func beginSession() {
    let pair = pwVioTimebaseSampleClockPair()
    lock.lock()
    filters.removeAll()
    lastRaw.removeAll()
    counts.removeAll()
    sessionStartPair = pair
    latestPair = pair
    sessionSleepDeltaSeconds = 0
    syncClockUnavailableCount = 0
    lock.unlock()
  }

  /// 周期重测(建议 1–2 s 一次,或每次 App 从后台回前台时立刻调一次)。
  ///
  /// 返回本次相对会话起点的**累计休眠增量**。非 0 ⇒ 会话跨越了休眠 ⇒
  /// Dart 侧必须把缓冲里的时间戳按新偏置**重放**(不是丢掉 —— 铁律)。
  @discardableResult
  public func remeasure() -> Double {
    let pair = pwVioTimebaseSampleClockPair()
    lock.lock()
    latestPair = pair
    if let start = sessionStartPair {
      sessionSleepDeltaSeconds = pair.accumulatedSleepSeconds - start.accumulatedSleepSeconds
    }
    let d = sessionSleepDeltaSeconds
    lock.unlock()
    return d
  }

  // MARK: 各路投喂(都在各自的回调线程上直接调,越早越好)

  /// CoreMotion。**必须在 handler 的第一行调用** —— 晚一行就多一行的投递延迟,
  /// min-filter 只能吃掉抖动,吃不掉你自己加进去的固定延迟。
  public func noteCoreMotion(timestamp: TimeInterval) {
    note(source: PwVioTimebase.sourceCoreMotion, rawSeconds: timestamp)
  }

  // MARK: - 自带的 CoreMotion 驱动(诊断用)
  //
  // 为什么需要它:noteCoreMotion 原本只挂在 PwVioCapability 的 IMU probe 的
  // handler 里,而**那个 probe 从来没有人调用**(它连 Flutter 插件都没有)。
  // 结果就是真机上只测到了 arFrame 一路,而域错配是**两路对比**才成立的问题:
  // ARFrame 贴 uptimeRaw 本身没有风险,风险在于 CoreMotion 会不会贴 monotonic
  // —— 那两者在实测这台机上差 61.68 小时。
  //
  // 所以这里自带一个最小的 CMMotionManager,不依赖任何其他模块。
  private let motion = CMMotionManager()
  private let motionQueue: OperationQueue = {
    let q = OperationQueue()
    q.name = "pw.vio.timebase.motion"
    q.maxConcurrentOperationCount = 1   // 串行:note() 的调用方需要单线程语义
    return q
  }()

  /// 启动 deviceMotion 投喂。幂等。
  /// - Parameter hz: 请求频率。⚠️ 这是**请求**不是保证 —— 实际频率由系统决定,
  ///   所以我们记的是**到达时间戳**,不是这个数。
  @discardableResult
  public func startCoreMotionFeed(hz: Double = 100.0) -> Bool {
    guard motion.isDeviceMotionAvailable else { return false }
    guard !motion.isDeviceMotionActive else { return true }
    motion.deviceMotionUpdateInterval = 1.0 / max(hz, 1.0)
    motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: motionQueue) {
      [weak self] sample, _ in
      guard let self = self, let m = sample else { return }
      // 必须是 handler 第一行:晚一行就多一行固定投递延迟,而 min-filter
      // 只吃得掉抖动,吃不掉你自己加进去的固定延迟。
      self.noteCoreMotion(timestamp: m.timestamp)
      // [pw][vio] 同一个样本也喂给 XRSLAM。feeder 未 start 时是空操作。
      if #available(iOS 11.0, *) { PwVioSlamFeeder.shared.feed(motion: m) }
    }
    return true
  }

  public func stopCoreMotionFeed() {
    if motion.isDeviceMotionActive { motion.stopDeviceMotionUpdates() }
  }

  #if canImport(ARKit)
    /// ARKit。域完全未文档化 ⇒ 纯测量。
    @available(iOS 11.0, *)
    public func noteARFrame(_ frame: ARFrame) {
      note(source: PwVioTimebase.sourceArFrame, rawSeconds: frame.timestamp)
      noteIntrinsics(frame.camera)
    }

    /// 顺手留一份最新的相机内参。
    ///
    /// 为什么用 ARCamera.intrinsics 而不是 AVCameraCalibrationData:
    /// pocketworld 的主采集链走 ARKit,ARKit **不交出 AVCaptureSession**,
    /// 所以 cameraIntrinsicMatrixDeliveryEnabled 那条路在这里够不着。
    /// ARCamera.intrinsics 自 iOS 11 就有,参照系是 ARCamera.imageResolution。
    ///
    /// ⚠️ 内参与分辨率是**绑定的**:同一台机换采集分辨率,fx/cx 必须等比缩放,
    ///    否则整条位姿链系统性错而且不报错。所以这里把分辨率一起带出去。
    @available(iOS 11.0, *)
    private func noteIntrinsics(_ camera: ARCamera) {
      let k = camera.intrinsics   // simd_float3x3,列主序
      let res = camera.imageResolution
      lock.lock()
      latestIntrinsics = [
        "fx": Double(k.columns.0.x),
        "fy": Double(k.columns.1.y),
        "cx": Double(k.columns.2.x),
        "cy": Double(k.columns.2.y),
        "width": Int(res.width),
        "height": Int(res.height),
        "source": "arkit-arcamera",
        "capturedAtSeconds": camera.trackingState.pwVioIsNormal ? 1.0 : 0.0,
      ]
      lock.unlock()
    }

    /// 从 `ARFrame.exifData`(iOS 16.0+)里取曝光时长(秒)。
    /// iOS 15 或字段缺失时返回 nil —— **返回 nil 而不是编一个默认值**,
    /// Dart 侧据此如实标注「曝光不确定度未知」。
    @available(iOS 11.0, *)
    public func exposureDurationSeconds(of frame: ARFrame) -> Double? {
      guard #available(iOS 16.0, *) else { return nil }
      let key = kCGImagePropertyExifExposureTime as String
      guard let v = frame.exifData[key] as? NSNumber else { return nil }
      let d = v.doubleValue
      return d.isFinite && d > 0 ? d : nil
    }
  #endif

  /// AVCapture 链。同时记两条:
  ///   • `capturePtsRaw`  —— PTS 原样(synchronizationClock timebase)
  ///   • `capturePtsHost` —— 经 `CMSyncConvertTime` 换到 host clock 之后的值
  /// 两条的偏置一对比,就能看出这层换算到底动了多少 —— 而不是猜「反正一样」。
  public func noteSampleBuffer(_ sampleBuffer: CMSampleBuffer, session: AVCaptureSession) {
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard pts.isValid && !pts.isIndefinite else { return }
    note(source: PwVioTimebase.sourceCaptureRawPts, rawSeconds: CMTimeGetSeconds(pts))

    guard let clock = captureClock(of: session) else {
      lock.lock(); syncClockUnavailableCount += 1; lock.unlock()
      return
    }
    let host = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
    guard host.isValid && !host.isIndefinite else {
      lock.lock(); syncClockUnavailableCount += 1; lock.unlock()
      return
    }
    note(source: PwVioTimebase.sourceCaptureHostPts, rawSeconds: CMTimeGetSeconds(host))
  }

  /// `synchronizationClock`(iOS 15.4+)优先;15.0–15.3 回退到已废弃的
  /// `masterClock`。本工程 deployment target 是 15.0,所以两条都要留。
  private func captureClock(of session: AVCaptureSession) -> CMClock? {
    if #available(iOS 15.4, *) {
      return session.synchronizationClock
    } else {
      return session.masterClock
    }
  }

  /// AVCapture 链的曝光时长(秒)。CMTime 无效时返回 nil。
  public func exposureDurationSeconds(of device: AVCaptureDevice) -> Double? {
    let d = device.exposureDuration
    guard d.isValid && !d.isIndefinite else { return nil }
    let s = CMTimeGetSeconds(d)
    return s.isFinite && s > 0 ? s : nil
  }

  // MARK: 核心记账

  private func note(source: String, rawSeconds: Double) {
    guard rawSeconds.isFinite else { return }
    // 先读钟再上锁 —— 锁等待时间不能算进投递延迟。
    let pair = pwVioTimebaseSampleClockPair()
    lock.lock()
    var f = filters[source]
    if f == nil {
      f = (uptime: PwVioMinFilter(), mono: PwVioMinFilter())
      filters[source] = f
    }
    f!.uptime.add(srcSeconds: rawSeconds, refSeconds: pair.uptimeRawSeconds)
    f!.mono.add(srcSeconds: rawSeconds, refSeconds: pair.monotonicSeconds)
    lastRaw[source] = rawSeconds
    counts[source] = (counts[source] ?? 0) + 1
    latestPair = pair
    if let start = sessionStartPair {
      sessionSleepDeltaSeconds = pair.accumulatedSleepSeconds - start.accumulatedSleepSeconds
    }
    lock.unlock()
  }

  // MARK: 上报

  public func measurement(for source: String) -> PwVioSourceMeasurement? {
    lock.lock()
    defer { lock.unlock() }
    guard let f = filters[source], let raw = lastRaw[source] else { return nil }
    return PwVioSourceMeasurement(
      sourceName: source,
      lastRawSeconds: raw,
      offsetToUptimeRaw: f.uptime.estimate(),
      offsetToMonotonic: f.mono.estimate(),
      sampleCount: counts[source] ?? 0
    )
  }

  /// 给 Dart 的快照。全部是**实测量**,没有任何一个判决。
  public func snapshot() -> [String: Any] {
    let pair = pwVioTimebaseSampleClockPair()
    lock.lock()
    let sources = Array(filters.keys)
    let start = sessionStartPair
    let sleepDelta = sessionSleepDeltaSeconds
    let syncFail = syncClockUnavailableCount
    lock.unlock()

    var out: [String: Any] = [
      "uptimeRawSeconds": pair.uptimeRawSeconds,
      "monotonicSeconds": pair.monotonicSeconds,
      "clockPairReadCostSeconds": pair.readCostSeconds,
      // 🔴 明早第一个要看的数:开机以来累计休眠。它就是 iOS 版的
      //    (elapsedRealtimeNanos − nanoTime)。
      "accumulatedSleepSeconds": pair.accumulatedSleepSeconds,
      "sessionSleepDeltaSeconds": sleepDelta,
      "sessionStartAccumulatedSleepSeconds": start?.accumulatedSleepSeconds as Any,
      "syncClockUnavailableCount": syncFail,
      "synchronizationClockAvailable": {
        if #available(iOS 15.4, *) { return true } else { return false }
      }(),
      "arFrameExifAvailable": {
        if #available(iOS 16.0, *) { return true } else { return false }
      }(),
    ]

    var per: [String: Any] = [:]
    for s in sources {
      guard let m = measurement(for: s) else { continue }
      var e: [String: Any] = [
        "lastRawSeconds": m.lastRawSeconds,
        "sampleCount": m.sampleCount,
      ]
      if let u = m.offsetToUptimeRaw {
        e["offsetToUptimeRawSeconds"] = u.offsetSeconds
        e["offsetToUptimeRawJitterSeconds"] = u.jitterSeconds
        e["offsetToUptimeRawDriftPpm"] = u.driftPpm
        e["offsetToUptimeRawDriftPpmUncertainty"] = u.driftPpmUncertainty
        e["offsetToUptimeRawDriftSignificant"] = u.driftIsSignificant
      }
      if let mo = m.offsetToMonotonic {
        e["offsetToMonotonicSeconds"] = mo.offsetSeconds
        e["offsetToMonotonicJitterSeconds"] = mo.jitterSeconds
      }
      // 判据的**原料**:哪个基准的 |offset| 更小。判决留给 Dart。
      if let u = m.offsetToUptimeRaw, let mo = m.offsetToMonotonic {
        e["absOffsetToUptimeRaw"] = abs(u.offsetSeconds)
        e["absOffsetToMonotonic"] = abs(mo.offsetSeconds)
      }
      per[s] = e
    }
    out["sources"] = per
    return out
  }
}

// MARK: - Flutter 插件

#if canImport(Flutter)
  public final class PwVioTimebasePlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
      let channel = FlutterMethodChannel(
        name: PwVioTimebaseIdentifiers.methodChannel,
        binaryMessenger: registrar.messenger()
      )
      registrar.addMethodCallDelegate(PwVioTimebasePlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
      switch call.method {
      case "beginSession":
        PwVioTimebase.shared.beginSession()
        result(nil)
      case "remeasure":
        result(PwVioTimebase.shared.remeasure())
      case "snapshot":
        result(PwVioTimebase.shared.snapshot())
      case "startCoreMotionFeed":
        let hz = (call.arguments as? [String: Any])?["hz"] as? Double ?? 100.0
        result(PwVioTimebase.shared.startCoreMotionFeed(hz: hz))
      case "stopCoreMotionFeed":
        PwVioTimebase.shared.stopCoreMotionFeed()
        result(nil)
      case "slamStart":
        let args = call.arguments as? [String: Any] ?? [:]
        let slam = args["slamYaml"] as? String ?? ""
        let dev = args["deviceYaml"] as? String ?? ""
        let hz = args["runHz"] as? Double ?? 10.0
        if #available(iOS 11.0, *) {
          result(Int(PwVioSlamFeeder.shared.start(slamYaml: slam, deviceYaml: dev, runHz: hz)))
        } else { result(0) }
      case "slamStop":
        if #available(iOS 11.0, *) { PwVioSlamFeeder.shared.stop() }
        result(nil)
      case "slamSnapshot":
        if #available(iOS 11.0, *) { result(PwVioSlamFeeder.shared.snapshot()) }
        else { result(nil) }
      case "vioDownsampleFactor":
        result(PwVioSlamFeeder.vioDownsampleFactorForDart)

      case "deviceMachine":
        // hw.machine(如 "iPhone15,2")。用它而不是营销名去查外参表 ——
        // 营销名要多经一层字符串映射,多一层就多一个静默错的地方。
        var sz = 0
        sysctlbyname("hw.machine", nil, &sz, nil, 0)
        if sz > 0 {
          var buf = [CChar](repeating: 0, count: sz)
          sysctlbyname("hw.machine", &buf, &sz, nil, 0)
          result(String(cString: buf))
        } else {
          result(nil)
        }

      case "latestIntrinsics":
        result(PwVioTimebase.shared.snapshotIntrinsics())
      case "sampleClockPair":
        let p = pwVioTimebaseSampleClockPair()
        result([
          "uptimeRawSeconds": p.uptimeRawSeconds,
          "monotonicSeconds": p.monotonicSeconds,
          "readCostSeconds": p.readCostSeconds,
          "accumulatedSleepSeconds": p.accumulatedSleepSeconds,
        ])
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
#endif

#if canImport(ARKit)
  @available(iOS 11.0, *)
  extension ARCamera.TrackingState {
    /// 只有 .normal 时内参才可信 —— limited/notAvailable 期间 ARKit 自己
    /// 还在收敛,此时的内参不该被当成标定值用。
    var pwVioIsNormal: Bool {
      if case .normal = self { return true }
      return false
    }
  }
#endif
