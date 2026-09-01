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
// ① `CMAccelerometerData.timestamp` / `CMGyroData.timestamp`
//    (两者都继承自 `CMLogItem.timestamp`)
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
// 于是:如果原始 CoreMotion 时间戳的「since the device booted」实际是
// CLOCK_MONOTONIC 语义,而相机 PTS 经 host clock 落在 CLOCK_UPTIME_RAW 语义上,
// 那么**iPhone 上会出现和 Android 完全相同的域错配**,而且随机器待机时长增长。
// 业界普遍默认「CoreMotion == mach_absolute_time」,但 Apple **从没这么写过**。
//
// 所以 [PwVioTimebase] 对每一路都**同时**测到两个基准
// ([PwVioClockSandwich.uptimeRawBeforeSeconds] /
// [PwVioClockSandwich.monotonicSeconds] /
// [PwVioClockSandwich.uptimeRawAfterSeconds]),
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
import Darwin
import Foundation
import ImageIO
import simd

#if canImport(ARKit)
  import ARKit
#endif

#if canImport(Flutter)
  import Flutter
#endif

/// One ordered transport ingress for raw camera and IMU observations.
/// XRSLAM's sample uses the main queue because its demo has no concurrent
/// Flutter high-resolution shutter transaction. The product preserves the
/// sample's single-serial-order invariant on a dedicated queue so sensor
/// transport cannot block the UI/main camera-control path.
public enum PwVioSensorIngress {
  public static let dispatchQueue = DispatchQueue(
    label: "pw.vio.sensor-ingress",
    qos: .userInteractive
  )
  public static let operationQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.name = "pw.vio.sensor-ingress"
    queue.maxConcurrentOperationCount = 1
    queue.qualityOfService = .userInteractive
    queue.underlyingQueue = dispatchQueue
    return queue
  }()
}

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

/// 一次 uptime → monotonic → uptime 的三明治原始读数。
/// 中点、宽度和不确定性全部由 Dart 计算。
public struct PwVioClockSandwich {
  public let uptimeRawBeforeSeconds: Double
  public let monotonicSeconds: Double
  public let uptimeRawAfterSeconds: Double
}

/// 三明治采样:uptime → monotonic → uptime。中间那次的物理时刻被夹在两端之间。
@inline(__always)
public func pwVioTimebaseSampleClockPair() -> PwVioClockSandwich {
  return PwVioClockSandwich(
    uptimeRawBeforeSeconds: pwVioTimebaseUptimeRawSeconds(),
    monotonicSeconds: pwVioTimebaseMonotonicSeconds(),
    uptimeRawAfterSeconds: pwVioTimebaseUptimeRawSeconds()
  )
}

// MARK: - 原始配对样本（无估计、无阈值、无判决）

private struct PwVioRawTimestampSample {
  let sequence: Int
  let sourceSeconds: Double
  let uptimeRawBeforeSeconds: Double
  let monotonicSeconds: Double
  let uptimeRawAfterSeconds: Double

  var wire: [String: Any] {
    [
      "seq": sequence,
      "sourceSeconds": sourceSeconds,
      "uptimeRawBeforeSeconds": uptimeRawBeforeSeconds,
      "monotonicSeconds": monotonicSeconds,
      "uptimeRawAfterSeconds": uptimeRawAfterSeconds,
    ]
  }
}

/// Fixed raw-sample ring. This is transport backpressure only; min-filter,
/// jitter, drift and clock-domain decisions all live in shared Dart.
private final class PwVioRawSampleWindow {
  private static let capacity = 512
  private var storage = Array<PwVioRawTimestampSample?>(
    repeating: nil,
    count: capacity
  )
  private var head = 0
  private var count = 0
  private(set) var totalAdded = 0
  private(set) var overwritten = 0
  private(set) var totalDelivered = 0

  func clear() {
    for index in storage.indices { storage[index] = nil }
    head = 0
    count = 0
    totalAdded = 0
    overwritten = 0
    totalDelivered = 0
  }

  func add(sourceSeconds: Double, pair: PwVioClockSandwich) {
    totalAdded += 1
    let sample = PwVioRawTimestampSample(
      sequence: totalAdded,
      sourceSeconds: sourceSeconds,
      uptimeRawBeforeSeconds: pair.uptimeRawBeforeSeconds,
      monotonicSeconds: pair.monotonicSeconds,
      uptimeRawAfterSeconds: pair.uptimeRawAfterSeconds
    )
    if count == Self.capacity {
      storage[head] = sample
      head = (head + 1) % Self.capacity
      overwritten += 1
      return
    }
    storage[(head + count) % Self.capacity] = sample
    count += 1
  }

  func drain() -> [PwVioRawTimestampSample] {
    var out: [PwVioRawTimestampSample] = []
    out.reserveCapacity(count)
    for offset in 0..<count {
      if let sample = storage[(head + offset) % Self.capacity] {
        out.append(sample)
      }
    }
    for index in storage.indices { storage[index] = nil }
    head = 0
    count = 0
    totalDelivered += out.count
    return out
  }
}

/// One outcome counter packed with its native session generation. A callback
/// captured before a reset cannot mutate the new session's receipt.
private final class PwVioGenerationCounter {
  private static let countMask: UInt64 = 0xffff_ffff
  private var packed: Int64 = 0

  private func load() -> UInt64 {
    UInt64(bitPattern: OSAtomicAdd64Barrier(0, &packed))
  }

  func begin(_ generation: Int) {
    let next = UInt64(UInt32(truncatingIfNeeded: generation)) << 32
    while true {
      let old = OSAtomicAdd64Barrier(0, &packed)
      if OSAtomicCompareAndSwap64Barrier(
        old, Int64(bitPattern: next), &packed
      ) { return }
    }
  }

  @discardableResult
  func increment(generation: Int) -> Bool {
    let expected = UInt32(truncatingIfNeeded: generation)
    while true {
      let old = load()
      guard UInt32(truncatingIfNeeded: old >> 32) == expected else {
        return false
      }
      let count = old & Self.countMask
      guard count < Self.countMask else { return false }
      let next = (UInt64(expected) << 32) | (count + 1)
      if OSAtomicCompareAndSwap64Barrier(
        Int64(bitPattern: old), Int64(bitPattern: next), &packed
      ) { return true }
    }
  }

  func value(generation: Int) -> Int {
    let bits = load()
    guard UInt32(truncatingIfNeeded: bits >> 32) ==
            UInt32(truncatingIfNeeded: generation) else { return 0 }
    return Int(bits & Self.countMask)
  }
}

private final class PwVioAtomicCounter {
  private var storage: Int64 = 0
  func increment() { _ = OSAtomicIncrement64Barrier(&storage) }
  func reset() {
    while true {
      let old = OSAtomicAdd64Barrier(0, &storage)
      if old == 0 || OSAtomicCompareAndSwap64Barrier(old, 0, &storage) {
        return
      }
    }
  }
  var value: Int { Int(OSAtomicAdd64Barrier(0, &storage)) }
}

/// Native-only lifecycle gate for raw timebase transport. Hot callbacks use
/// CAS only; stop closes admission and waits asynchronously for existing
/// callback leases before a terminal timebase snapshot can be requested.
private final class PwVioTimebaseIngressGate {
  enum Phase: UInt64 { case open = 0, rejecting = 1, sealed = 2 }
  struct Entry { let generation: UInt32 }

  private static let activeMask: UInt64 = 0x3fff_ffff
  private static let phaseShift: UInt64 = 30
  private var packed: Int64
  private let sealLock = NSLock()
  private var sealGeneration: Int?
  private var sealCompletions: [() -> Void] = []

  init() {
    packed = Int64(bitPattern: Phase.sealed.rawValue << Self.phaseShift)
  }

  private func load() -> UInt64 {
    UInt64(bitPattern: OSAtomicAdd64Barrier(0, &packed))
  }

  func prepare(generation: Int) -> Bool {
    let expectedGeneration = UInt32(truncatingIfNeeded: generation)
    while true {
      let old = load()
      let phase = (old >> Self.phaseShift) & 0x3
      guard phase == Phase.sealed.rawValue,
            old & Self.activeMask == 0 else { return false }
      let next = (UInt64(expectedGeneration) << 32) |
        (Phase.sealed.rawValue << Self.phaseShift)
      if OSAtomicCompareAndSwap64Barrier(
        Int64(bitPattern: old), Int64(bitPattern: next), &packed
      ) {
        sealLock.lock()
        sealGeneration = nil
        sealCompletions.removeAll(keepingCapacity: true)
        sealLock.unlock()
        return true
      }
    }
  }

  func open(generation: Int) -> Bool {
    let expectedGeneration = UInt32(truncatingIfNeeded: generation)
    while true {
      let old = load()
      guard UInt32(truncatingIfNeeded: old >> 32) == expectedGeneration,
            old & Self.activeMask == 0,
            (old >> Self.phaseShift) & 0x3 == Phase.sealed.rawValue else {
        return false
      }
      let next = old & ~(UInt64(0x3) << Self.phaseShift)
      if OSAtomicCompareAndSwap64Barrier(
        Int64(bitPattern: old), Int64(bitPattern: next), &packed
      ) { return true }
    }
  }

  func enter() -> Entry? {
    while true {
      let old = load()
      guard (old >> Self.phaseShift) & 0x3 == Phase.open.rawValue else {
        return nil
      }
      let active = old & Self.activeMask
      guard active < Self.activeMask else { return nil }
      if OSAtomicCompareAndSwap64Barrier(
        Int64(bitPattern: old), Int64(bitPattern: old + 1), &packed
      ) {
        return Entry(generation: UInt32(truncatingIfNeeded: old >> 32))
      }
    }
  }

  func leave(_ entry: Entry) {
    while true {
      let old = load()
      guard UInt32(truncatingIfNeeded: old >> 32) == entry.generation,
            old & Self.activeMask > 0 else { return }
      let next = old - 1
      if OSAtomicCompareAndSwap64Barrier(
        Int64(bitPattern: old), Int64(bitPattern: next), &packed
      ) {
        if next & Self.activeMask == 0 { completeSealIfReady() }
        return
      }
    }
  }

  func closeWhenQuiescent(
    generation: Int,
    completion: @escaping () -> Void
  ) {
    let expectedGeneration = UInt32(truncatingIfNeeded: generation)
    while true {
      let old = load()
      guard UInt32(truncatingIfNeeded: old >> 32) == expectedGeneration else {
        completion()
        return
      }
      let phase = (old >> Self.phaseShift) & 0x3
      if phase == Phase.sealed.rawValue {
        completion()
        return
      }
      if phase == Phase.open.rawValue {
        let next = old | (Phase.rejecting.rawValue << Self.phaseShift)
        if !OSAtomicCompareAndSwap64Barrier(
          Int64(bitPattern: old), Int64(bitPattern: next), &packed
        ) { continue }
      }
      break
    }

    sealLock.lock()
    if sealCompletions.isEmpty {
      sealGeneration = generation
    }
    if sealGeneration == generation { sealCompletions.append(completion) }
    sealLock.unlock()
    completeSealIfReady()
  }

  private func completeSealIfReady() {
    let bits = load()
    guard bits & Self.activeMask == 0,
          (bits >> Self.phaseShift) & 0x3 == Phase.rejecting.rawValue else {
      return
    }
    let generation = Int(UInt32(truncatingIfNeeded: bits >> 32))
    guard sealLock.try() else { return }
    var completions: [() -> Void] = []
    if sealGeneration == generation, !sealCompletions.isEmpty {
      let clearedPhase = bits & ~(UInt64(0x3) << Self.phaseShift)
      let sealed = clearedPhase | (Phase.sealed.rawValue << Self.phaseShift)
      if OSAtomicCompareAndSwap64Barrier(
        Int64(bitPattern: bits), Int64(bitPattern: sealed), &packed
      ) {
        completions = sealCompletions
        sealCompletions.removeAll(keepingCapacity: true)
        sealGeneration = nil
      }
    }
    sealLock.unlock()
    for completion in completions { completion() }
  }
}

private final class PwVioShadowStopJoin {
  private let lock = NSLock()
  private let completion: ([String: Any]) -> Void
  private var receipt: [String: Any]?
  private var timebaseClosed = false
  private var delivered = false

  init(completion: @escaping ([String: Any]) -> Void) {
    self.completion = completion
  }

  func receive(receipt: [String: Any]) {
    finish(receipt: receipt, closed: nil)
  }

  func markTimebaseClosed() {
    finish(receipt: nil, closed: true)
  }

  private func finish(receipt newReceipt: [String: Any]?, closed: Bool?) {
    lock.lock()
    if let newReceipt { receipt = newReceipt }
    if closed == true { timebaseClosed = true }
    let ready = !delivered && timebaseClosed && receipt != nil
    let finalReceipt = ready ? receipt : nil
    if ready { delivered = true }
    lock.unlock()
    if let finalReceipt {
      DispatchQueue.main.async { self.completion(finalReceipt) }
    }
  }
}

private final class PwVioRawSourceLedger {
  let invalid = PwVioGenerationCounter()
  let lockContention = PwVioGenerationCounter()
  let staleGeneration = PwVioGenerationCounter()

  func begin(_ generation: Int) {
    invalid.begin(generation)
    lockContention.begin(generation)
    staleGeneration.begin(generation)
  }
}

private struct PwVioRawIntrinsics {
  let sessionId: String
  let sessionEpoch: Int
  let sessionGeneration: Int
  let intrinsicMatrix: matrix_float3x3
  let imageResolutionWidth: Double
  let imageResolutionHeight: Double
  let referenceTrackingState: String
  let referenceTrackingReason: String

  var wire: [String: Any] {
    [
      "schema": "pw.vio.ios.intrinsics-raw/1",
      "sessionId": sessionId,
      "sessionEpoch": sessionEpoch,
      "sessionGeneration": sessionGeneration,
      // simd 原生列主序原样上送。哪些元素是 fx/fy/cx/cy、
      // 数值是否有限/合理，全由 Dart 的版本化 parser 判定。
      "intrinsicMatrixColumnMajor": [
        Double(intrinsicMatrix.columns.0.x),
        Double(intrinsicMatrix.columns.0.y),
        Double(intrinsicMatrix.columns.0.z),
        Double(intrinsicMatrix.columns.1.x),
        Double(intrinsicMatrix.columns.1.y),
        Double(intrinsicMatrix.columns.1.z),
        Double(intrinsicMatrix.columns.2.x),
        Double(intrinsicMatrix.columns.2.y),
        Double(intrinsicMatrix.columns.2.z),
      ],
      "imageResolutionWidth": imageResolutionWidth,
      "imageResolutionHeight": imageResolutionHeight,
      "source": "ARCamera.intrinsics",
      "referenceTrackingState": referenceTrackingState,
      "referenceTrackingReason": referenceTrackingReason,
    ]
  }
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
  private var latestIntrinsics: PwVioRawIntrinsics?

  /// 供 Flutter channel 取。返回 nil 时调用方**必须**如实标成 PLACEHOLDER,
  /// 不要退回一组编出来的数 —— 那正是我们要避免的东西。
  public func snapshotIntrinsics() -> [String: Any]? {
    lock.lock(); defer { lock.unlock() }
    return latestIntrinsics?.wire
  }

  private let lock = NSLock()

  // Native retains only a bounded window of raw paired readings. Shared Dart
  // owns min-filtering, drift estimation, usability and every threshold.
  private var rawSources: [String: PwVioRawSampleWindow]
  private var sourceLedgers: [String: PwVioRawSourceLedger]
  private var timebaseSessionGeneration = 0
  private let timebaseIngress = PwVioTimebaseIngressGate()
  private var timebaseSessionId = ""
  private var timebaseSessionEpoch = 0
  private let outOfSessionStaleObservations = PwVioAtomicCounter()
  private let syncClockUnavailable = PwVioGenerationCounter()
  private let intrinsicsLockContention = PwVioGenerationCounter()
  private let intrinsicsStaleGeneration = PwVioGenerationCounter()
  private var intrinsicsAccepted = 0
  private var intrinsicsOverwritten = 0

  /// Raw lifecycle anchor. Dart alone computes clock differences.
  private var sessionStartPair: PwVioClockSandwich?

  public static let sourceCoreMotionAccelerometer = "coreMotionAccelerometer"
  public static let sourceCoreMotionGyroscope = "coreMotionGyroscope"
  public static let sourceArFrame = "arFrame"
  public static let sourceCaptureRawPts = "capturePtsRaw"
  public static let sourceCaptureHostPts = "capturePtsHost"

  public init() {
    let sources = [
      Self.sourceCoreMotionAccelerometer,
      Self.sourceCoreMotionGyroscope,
      Self.sourceArFrame,
      Self.sourceCaptureRawPts,
      Self.sourceCaptureHostPts,
    ]
    rawSources = Dictionary(uniqueKeysWithValues: sources.map {
      ($0, PwVioRawSampleWindow())
    })
    sourceLedgers = Dictionary(uniqueKeysWithValues: sources.map {
      ($0, PwVioRawSourceLedger())
    })
  }

  // MARK: 会话生命周期

  /// 会话开始时调用。清空所有测量,重新锚定。
  @discardableResult
  public func beginSession(sessionId: String, sessionEpoch: Int) -> Bool {
    lock.lock()
    let generation = timebaseSessionGeneration + 1
    guard timebaseIngress.prepare(generation: generation) else {
      lock.unlock()
      return false
    }
    outOfSessionStaleObservations.reset()
    let pair = pwVioTimebaseSampleClockPair()
    timebaseSessionGeneration = generation
    timebaseSessionId = sessionId
    timebaseSessionEpoch = sessionEpoch
    for source in rawSources.keys {
      rawSources[source]?.clear()
      sourceLedgers[source]?.begin(generation)
    }
    syncClockUnavailable.begin(generation)
    intrinsicsLockContention.begin(generation)
    intrinsicsStaleGeneration.begin(generation)
    intrinsicsAccepted = 0
    intrinsicsOverwritten = 0
    latestIntrinsics = nil
    sessionStartPair = pair
    let opened = timebaseIngress.open(generation: generation)
    lock.unlock()
    return opened
  }

  /// Return raw current/start clocks. Dart computes every difference/verdict.
  @discardableResult
  public func remeasure() -> [String: Any] {
    lock.lock()
    let pair = pwVioTimebaseSampleClockPair()
    let start = sessionStartPair
    let sessionId = timebaseSessionId
    let sessionEpoch = timebaseSessionEpoch
    let generation = timebaseSessionGeneration
    lock.unlock()
    let startBefore: Any = start.map { $0.uptimeRawBeforeSeconds } ?? NSNull()
    let startMonotonic: Any = start.map { $0.monotonicSeconds } ?? NSNull()
    let startAfter: Any = start.map { $0.uptimeRawAfterSeconds } ?? NSNull()
    return [
      "schema": "pw.vio.timebase-remeasure-raw/1",
      "sessionId": sessionId,
      "sessionEpoch": sessionEpoch,
      "sessionGeneration": generation,
      "uptimeRawBeforeSeconds": pair.uptimeRawBeforeSeconds,
      "monotonicSeconds": pair.monotonicSeconds,
      "uptimeRawAfterSeconds": pair.uptimeRawAfterSeconds,
      "sessionStartUptimeRawBeforeSeconds": startBefore,
      "sessionStartMonotonicSeconds": startMonotonic,
      "sessionStartUptimeRawAfterSeconds": startAfter,
    ]
  }

  // MARK: 各路投喂(都在各自的回调线程上直接调,越早越好)

  /// CoreMotion。**必须在 handler 的第一行调用** —— 晚一行就多一行的投递延迟,
  /// min-filter 只能吃掉抖动,吃不掉你自己加进去的固定延迟。
  public func noteCoreMotionAccelerometer(timestamp: TimeInterval) {
    note(
      source: PwVioTimebase.sourceCoreMotionAccelerometer,
      rawSeconds: timestamp
    )
  }

  public func noteCoreMotionGyroscope(timestamp: TimeInterval) {
    note(source: PwVioTimebase.sourceCoreMotionGyroscope, rawSeconds: timestamp)
  }

  // MARK: - 自带的 CoreMotion 驱动(诊断用)
  //
  // 为什么需要它:CoreMotion note 原本只挂在 PwVioCapability 的 IMU probe 的
  // handler 里,而**那个 probe 从来没有人调用**(它连 Flutter 插件都没有)。
  // 结果就是真机上只测到了 arFrame 一路,而域错配是**两路对比**才成立的问题:
  // ARFrame 贴 uptimeRaw 本身没有风险,风险在于 CoreMotion 会不会贴 monotonic
  // —— 那两者在实测这台机上差 61.68 小时。
  //
  // 所以这里自带一个最小的 CMMotionManager,不依赖任何其他模块。
  private let motion = CMMotionManager()
  // Serializes the *intent* to couple CoreMotion with the XRSLAM lifecycle.
  // Feeder Create/Destroy remain asynchronous; this tiny lock only prevents a
  // stale start completion from turning motion back on after a newer stop.
  private let shadowLifecycleLock = NSLock()
  private var shadowLifecycleGeneration = 0
  private var shadowMotionDesired = false
  private var shadowResumeAuthorized = false
  private var shadowAccelerometerHz: Double?
  private var shadowGyroscopeHz: Double?
  // Accessed only while holding shadowLifecycleLock. Binding the dedupe token
  // to the lifecycle generation prevents an old CoreMotion callback from
  // consuming the current generation's one allowed failure transition.
  private var rawMotionFailureScheduledGeneration = -1
  private let motionFailureQueue = DispatchQueue(
    label: "pw.vio.timebase.motion-failure",
    qos: .utility
  )
  // Frozen upstream Motion() and Camera() share one serial ingress. Keep that
  // order without occupying Flutter's UI/main camera-control path.
  private let motionQueue = PwVioSensorIngress.operationQueue

  /// 启动两路独立原始 IMU 投喂。频率是 Dart 显式选择的请求值,
  /// 平台层只校验和执行,不做配对、重采样或融合。
  @discardableResult
  public func startRawCoreMotionFeed(accelerometerHz: Double, gyroscopeHz: Double) -> Bool {
    shadowLifecycleLock.lock()
    guard accelerometerHz.isFinite, accelerometerHz > 0,
          gyroscopeHz.isFinite, gyroscopeHz > 0 else {
      shadowLifecycleLock.unlock()
      return false
    }
    shadowLifecycleGeneration += 1
    let generation = shadowLifecycleGeneration
    shadowMotionDesired = true
    shadowAccelerometerHz = accelerometerHz
    shadowGyroscopeHz = gyroscopeHz
    let result = startRawCoreMotionFeedLocked(
      accelerometerHz: accelerometerHz,
      gyroscopeHz: gyroscopeHz,
      lifecycleGeneration: generation,
      feederGeneration: nil
    )
    if !result {
      rollbackShadowStartIntentLocked()
    }
    shadowLifecycleLock.unlock()
    return result
  }

  private func startRawCoreMotionFeedLocked(
    accelerometerHz: Double,
    gyroscopeHz: Double,
    lifecycleGeneration: Int,
    feederGeneration: Int?
  ) -> Bool {
    guard accelerometerHz.isFinite, accelerometerHz > 0,
          gyroscopeHz.isFinite, gyroscopeHz > 0,
          motion.isAccelerometerAvailable,
          motion.isGyroAvailable else { return false }
    stopRawCoreMotionFeedLocked()
    motion.accelerometerUpdateInterval = 1.0 / accelerometerHz
    motion.gyroUpdateInterval = 1.0 / gyroscopeHz
    // Match upstream xrslam-ios transport order: raw gyro first, then raw acc.
    motion.startGyroUpdates(to: motionQueue) { [weak self] sample, error in
      if error != nil {
        self?.scheduleRawMotionFailure(generation: lifecycleGeneration)
        return
      }
      guard let self, let sample else { return }
      self.noteCoreMotionGyroscope(timestamp: sample.timestamp)
      if #available(iOS 11.0, *), let feederGeneration {
        _ = PwVioSlamFeeder.shared.enqueue(
          gyroscope: sample,
          expectedGeneration: feederGeneration
        )
      }
    }
    motion.startAccelerometerUpdates(to: motionQueue) { [weak self] sample, error in
      if error != nil {
        self?.scheduleRawMotionFailure(generation: lifecycleGeneration)
        return
      }
      guard let self, let sample else { return }
      self.noteCoreMotionAccelerometer(timestamp: sample.timestamp)
      if #available(iOS 11.0, *), let feederGeneration {
        _ = PwVioSlamFeeder.shared.enqueue(
          acceleration: sample,
          expectedGeneration: feederGeneration
        )
      }
    }
    // CoreMotion activation is asynchronous. On a physical iPhone the two
    // `is*Active` flags can still be false immediately after these start calls;
    // treating that transient observation as failure stops both streams before
    // their first callbacks. Availability was checked above. Any real delivery
    // error is reported asynchronously by the handlers and closes this exact
    // lifecycle generation via scheduleRawMotionFailure.
    return true
  }

  private func scheduleRawMotionFailure(generation: Int) {
    motionFailureQueue.async { [weak self] in
      guard let self else { return }
      self.shadowLifecycleLock.lock()
      let current = generation == self.shadowLifecycleGeneration &&
        self.shadowMotionDesired &&
        self.rawMotionFailureScheduledGeneration != generation
      if current {
        self.rawMotionFailureScheduledGeneration = generation
        self.rollbackShadowStartIntentLocked()
      }
      self.shadowLifecycleLock.unlock()
      if current, #available(iOS 11.0, *) {
        PwVioSlamFeeder.shared.stop { _ in }
      }
    }
  }

  public func stopRawCoreMotionFeed() {
    shadowLifecycleLock.lock()
    shadowLifecycleGeneration += 1
    shadowMotionDesired = false
    stopRawCoreMotionFeedLocked()
    shadowLifecycleLock.unlock()
  }

  private func stopRawCoreMotionFeedLocked() {
    // CoreMotion start/stop is asynchronous. The active flags may still be
    // false while a start request is pending, so they cannot authorize stop.
    motion.stopAccelerometerUpdates()
    motion.stopGyroUpdates()
  }

  /// A platform interruption pauses only platform delivery. Dart's explicit
  /// authorization and feeder configuration remain available for resume.
  public func suspendShadowPipeline() {
    shadowLifecycleLock.lock()
    shadowLifecycleGeneration += 1
    shadowMotionDesired = false
    stopRawCoreMotionFeedLocked()
    shadowLifecycleLock.unlock()
  }

  private func revokeShadowAuthorization() {
    shadowLifecycleLock.lock()
    shadowLifecycleGeneration += 1
    rollbackShadowStartIntentLocked()
    shadowLifecycleLock.unlock()
  }

  /// Caller holds shadowLifecycleLock. A failed or revoked start must not leave
  /// a platform producer or reusable policy behind for a later native resume.
  private func rollbackShadowStartIntentLocked() {
    shadowMotionDesired = false
    shadowResumeAuthorized = false
    shadowAccelerometerHz = nil
    shadowGyroscopeHz = nil
    stopRawCoreMotionFeedLocked()
  }

  public func shutdownShadowPipeline(
    completion: @escaping ([String: Any]) -> Void
  ) {
    revokeShadowAuthorization()
    lock.lock()
    let timebaseGeneration = timebaseSessionGeneration
    lock.unlock()
    let join = PwVioShadowStopJoin(completion: completion)
    if #available(iOS 11.0, *) {
      // Feeder stop closes camera/IMU work admission synchronously. Timebase
      // admission closes immediately after it; completion is withheld until
      // both old-generation boundaries are terminal.
      PwVioSlamFeeder.shared.stop { receipt in
        join.receive(receipt: receipt)
      }
    } else {
      join.receive(receipt: [
          "schema": "pw.vio.shadow-terminal-unavailable/1",
          "receiptAvailable": false,
      ])
    }
    timebaseIngress.closeWhenQuiescent(generation: timebaseGeneration) {
      join.markTimebaseClosed()
    }
  }

  public func resumeShadowPipeline() {
    guard #available(iOS 11.0, *) else { return }
    shadowLifecycleLock.lock()
    guard shadowResumeAuthorized else {
      shadowLifecycleLock.unlock()
      return
    }
    guard let feederGeneration = PwVioSlamFeeder.shared.runningGeneration else {
      shadowLifecycleGeneration += 1
      rollbackShadowStartIntentLocked()
      shadowLifecycleLock.unlock()
      return
    }
    shadowLifecycleGeneration += 1
    shadowMotionDesired = true
    if let accelerometerHz = shadowAccelerometerHz,
       let gyroscopeHz = shadowGyroscopeHz {
      let started = startRawCoreMotionFeedLocked(
        accelerometerHz: accelerometerHz,
        gyroscopeHz: gyroscopeHz,
        lifecycleGeneration: shadowLifecycleGeneration,
        feederGeneration: feederGeneration
      )
      if !started { rollbackShadowStartIntentLocked() }
    } else {
      rollbackShadowStartIntentLocked()
    }
    shadowLifecycleLock.unlock()
  }

  private func beginShadowStartIntent(
    accelerometerHz: Double,
    gyroscopeHz: Double
  ) -> Int {
    shadowLifecycleLock.lock()
    shadowLifecycleGeneration += 1
    shadowResumeAuthorized = true
    shadowMotionDesired = true
    shadowAccelerometerHz = accelerometerHz
    shadowGyroscopeHz = gyroscopeHz
    let generation = shadowLifecycleGeneration
    shadowLifecycleLock.unlock()
    return generation
  }

  private struct PwVioShadowStartIntentResult {
    let accepted: Bool
    let failureReason: String?
  }

  /// Returns success only when the completion still represents the newest
  /// desired lifecycle and the feeder is truly running. Holding the intent
  /// lock across CoreMotion start makes the check/start atomic with stop:
  /// either motion starts first and stop immediately turns it off, or stop
  /// wins and the stale completion cannot start it at all.
  private func completeShadowStartIntent(
    generation: Int,
    feederGeneration: Int,
    rc: Int32
  ) -> PwVioShadowStartIntentResult {
    shadowLifecycleLock.lock()
    let intentCurrent = generation == shadowLifecycleGeneration
    guard intentCurrent && shadowMotionDesired && shadowResumeAuthorized else {
      shadowLifecycleLock.unlock()
      return PwVioShadowStartIntentResult(
        accepted: false,
        failureReason: "stale-start-receipt"
      )
    }
    guard rc == 1 &&
          PwVioSlamFeeder.shared.runningGeneration == feederGeneration else {
      rollbackShadowStartIntentLocked()
      shadowLifecycleLock.unlock()
      return PwVioShadowStartIntentResult(
        accepted: false,
        failureReason: nil
      )
    }
    guard let accelerometerHz = shadowAccelerometerHz,
          let gyroscopeHz = shadowGyroscopeHz else {
      rollbackShadowStartIntentLocked()
      shadowLifecycleLock.unlock()
      return PwVioShadowStartIntentResult(
        accepted: false,
        failureReason: "raw-imu-start-failed"
      )
    }
    let rawFeedStarted = startRawCoreMotionFeedLocked(
        accelerometerHz: accelerometerHz,
        gyroscopeHz: gyroscopeHz,
        lifecycleGeneration: generation,
        feederGeneration: feederGeneration
    )
    if !rawFeedStarted {
      rollbackShadowStartIntentLocked()
      shadowLifecycleLock.unlock()
      return PwVioShadowStartIntentResult(
        accepted: false,
        failureReason: "raw-imu-start-failed"
      )
    }
    shadowLifecycleLock.unlock()
    return PwVioShadowStartIntentResult(
      accepted: true,
      failureReason: nil
    )
  }

  public func startShadowPipeline(
    slamConfigPath: String,
    deviceConfigPath: String,
    sessionId: String,
    sessionEpoch: Int,
    effectiveConfigSha256: String,
    inputIdentitySha256: String,
    downsampleFactor: Int,
    downsampleFormula: String,
    requestedCameraHz: Double,
    cameraTimeOffsetSeconds: Double,
    accelerationScale: Double,
    requestedAccelerometerHz: Double,
    requestedGyroscopeHz: Double,
    completion: @escaping ([String: Any]) -> Void
  ) {
    guard #available(iOS 11.0, *) else {
      DispatchQueue.main.async {
        completion([
          "schema": "pw.vio.shadow-start-receipt/1",
          "rc": 0,
          "generation": 0,
          "failureReason": "unsupported-platform",
          "snapshot": NSNull(),
        ])
      }
      return
    }
    guard requestedCameraHz.isFinite,
          requestedCameraHz > 0,
          cameraTimeOffsetSeconds.isFinite,
          requestedAccelerometerHz.isFinite,
          requestedAccelerometerHz > 0,
          requestedGyroscopeHz.isFinite,
          requestedGyroscopeHz > 0 else {
      DispatchQueue.main.async {
        completion([
          "schema": "pw.vio.shadow-start-receipt/1",
          "rc": 0,
          "generation": 0,
          "failureReason": "invalid-raw-imu-request",
          "snapshot": NSNull(),
        ])
      }
      return
    }
    let generation = beginShadowStartIntent(
      accelerometerHz: requestedAccelerometerHz,
      gyroscopeHz: requestedGyroscopeHz
    )
    PwVioSlamFeeder.shared.start(
      slamConfigPath: slamConfigPath,
      deviceConfigPath: deviceConfigPath,
      sessionId: sessionId,
      sessionEpoch: sessionEpoch,
      effectiveConfigSha256: effectiveConfigSha256,
      inputIdentitySha256: inputIdentitySha256,
      downsampleFactor: downsampleFactor,
      downsampleFormula: downsampleFormula,
      requestedCameraHz: requestedCameraHz,
      cameraTimeOffsetSeconds: cameraTimeOffsetSeconds,
      accelerationScale: accelerationScale,
      requestedAccelerometerHz: requestedAccelerometerHz,
      requestedGyroscopeHz: requestedGyroscopeHz
    ) { [weak self] rc, feederGeneration in
      guard let self else {
        completion([
          "schema": "pw.vio.shadow-start-receipt/1",
          "rc": 0,
          "generation": feederGeneration,
          "failureReason": "owner-released",
          "snapshot": NSNull(),
        ])
        return
      }
      let intentResult = self.completeShadowStartIntent(
        generation: generation,
        feederGeneration: feederGeneration,
        rc: rc
      )
      let directSnapshot = intentResult.accepted
        ? PwVioSlamFeeder.shared.directRunningReceipt(
          expectedGeneration: feederGeneration
        ) : nil
      let success = directSnapshot != nil
      let failureReason: String
      if success {
        failureReason = "none"
      } else if let exactFailure = intentResult.failureReason {
        failureReason = exactFailure
      } else if rc == 0 && PwVioSlamFeeder.shared.isRunning {
        failureReason = "configuration-conflict"
      } else if rc == 0 {
        failureReason = "create-failed-or-canceled"
      } else {
        failureReason = "direct-running-receipt-unavailable"
      }
      completion([
        "schema": "pw.vio.shadow-start-receipt/1",
        "rc": success ? 1 : 0,
        "generation": feederGeneration,
        "failureReason": failureReason,
        "snapshot": directSnapshot ?? NSNull(),
      ])
    }
  }

  #if canImport(ARKit)
    /// ARKit。域完全未文档化 ⇒ 纯测量。
    @available(iOS 11.0, *)
    public func noteARFrame(_ frame: ARFrame) {
      guard let entry = timebaseIngress.enter() else { return }
      defer { timebaseIngress.leave(entry) }
      let generation = Int(entry.generation)
      note(
        source: PwVioTimebase.sourceArFrame,
        rawSeconds: frame.timestamp,
        generation: generation
      )
      noteIntrinsics(frame.camera, generation: generation)
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
    private func noteIntrinsics(_ camera: ARCamera, generation: Int) {
      let res = camera.imageResolution
      let tracking: (state: String, reason: String)
      switch camera.trackingState {
      case .normal:
        tracking = ("normal", "none")
      case .notAvailable:
        tracking = ("notAvailable", "none")
      case .limited(let reason):
        switch reason {
        case .initializing:
          tracking = ("limited", "initializing")
        case .excessiveMotion:
          tracking = ("limited", "excessiveMotion")
        case .insufficientFeatures:
          tracking = ("limited", "insufficientFeatures")
        case .relocalizing:
          tracking = ("limited", "relocalizing")
        @unknown default:
          tracking = ("limited", "unknown")
        }
      @unknown default:
        tracking = ("unknown", "unknown")
      }
      guard generation > 0 else {
        outOfSessionStaleObservations.increment()
        return
      }
      guard lock.try() else {
        if !intrinsicsLockContention.increment(generation: generation) {
          outOfSessionStaleObservations.increment()
        }
        return
      }
      guard generation == timebaseSessionGeneration else {
        lock.unlock()
        if !intrinsicsStaleGeneration.increment(generation: generation) {
          outOfSessionStaleObservations.increment()
        }
        return
      }
      if latestIntrinsics != nil { intrinsicsOverwritten += 1 }
      intrinsicsAccepted += 1
      latestIntrinsics = PwVioRawIntrinsics(
        sessionId: timebaseSessionId,
        sessionEpoch: timebaseSessionEpoch,
        sessionGeneration: generation,
        intrinsicMatrix: camera.intrinsics,
        imageResolutionWidth: Double(res.width),
        imageResolutionHeight: Double(res.height),
        referenceTrackingState: tracking.state,
        referenceTrackingReason: tracking.reason
      )
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
    guard let entry = timebaseIngress.enter() else { return }
    defer { timebaseIngress.leave(entry) }
    let generation = Int(entry.generation)
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    guard pts.isValid && !pts.isIndefinite else { return }
    note(
      source: PwVioTimebase.sourceCaptureRawPts,
      rawSeconds: CMTimeGetSeconds(pts),
      generation: generation
    )

    guard let clock = captureClock(of: session) else {
      recordSyncClockUnavailable(generation: generation)
      return
    }
    let host = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
    guard host.isValid && !host.isIndefinite else {
      recordSyncClockUnavailable(generation: generation)
      return
    }
    note(
      source: PwVioTimebase.sourceCaptureHostPts,
      rawSeconds: CMTimeGetSeconds(host),
      generation: generation
    )
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

  private func recordSyncClockUnavailable(generation: Int) {
    if !syncClockUnavailable.increment(generation: generation) {
      outOfSessionStaleObservations.increment()
    }
  }

  private func note(source: String, rawSeconds: Double) {
    guard let entry = timebaseIngress.enter() else { return }
    defer { timebaseIngress.leave(entry) }
    note(
      source: source,
      rawSeconds: rawSeconds,
      generation: Int(entry.generation)
    )
  }

  private func note(
    source: String,
    rawSeconds: Double,
    generation: Int
  ) {
    guard let ledger = sourceLedgers[source] else {
      outOfSessionStaleObservations.increment()
      return
    }
    guard generation > 0, rawSeconds.isFinite else {
      if !ledger.invalid.increment(generation: generation) {
        outOfSessionStaleObservations.increment()
      }
      return
    }
    // Capture the generation before sampling; a reset that straddles this read
    // is rejected below and can never enter the next session.
    let pair = pwVioTimebaseSampleClockPair()
    guard lock.try() else {
      if !ledger.lockContention.increment(generation: generation) {
        outOfSessionStaleObservations.increment()
      }
      return
    }
    guard generation == timebaseSessionGeneration,
          let window = rawSources[source] else {
      lock.unlock()
      if !ledger.staleGeneration.increment(generation: generation) {
        outOfSessionStaleObservations.increment()
      }
      return
    }
    window.add(sourceSeconds: rawSeconds, pair: pair)
    lock.unlock()
  }

  // MARK: 上报

  /// 给 Dart 的快照。只有原始钟读数和原始配对样本；不包含偏置、抖动、
  /// 漂移、跟踪可用性或域判决。
  public func snapshot() -> [String: Any] {
    lock.lock()
    let pair = pwVioTimebaseSampleClockPair()
    let start = sessionStartPair
    let generation = timebaseSessionGeneration
    let sessionId = timebaseSessionId
    let sessionEpoch = timebaseSessionEpoch
    let syncFail = syncClockUnavailable.value(generation: generation)
    var per: [String: Any] = [:]
    for (source, window) in rawSources {
      let samples = window.drain()
      let ledger = sourceLedgers[source]!
      let invalid = ledger.invalid.value(generation: generation)
      let contention = ledger.lockContention.value(generation: generation)
      let stale = ledger.staleGeneration.value(generation: generation)
      let accepted = window.totalAdded
      let rejected = invalid + contention + stale
      per[source] = [
        "sampleCount": window.totalAdded,
        "rawSamplesDropped": window.overwritten,
        "rawSamplesAttempted": accepted + rejected,
        "rawSamplesAccepted": accepted,
        "rawSamplesRejected": rejected,
        "rawSamplesDelivered": window.totalDelivered,
        "rawSamplesBatchCount": samples.count,
        "rejectionReasons": [
          "invalid_input": invalid,
          "lock_contention": contention,
          "stale_generation": stale,
        ],
        "rawSamples": samples.map { $0.wire },
      ]
    }
    let intrinsicsContentionCount = intrinsicsLockContention.value(
      generation: generation
    )
    let intrinsicsStaleCount = intrinsicsStaleGeneration.value(
      generation: generation
    )
    let intrinsicsRejected = intrinsicsContentionCount + intrinsicsStaleCount
    let intrinsicsWire: [String: Any] = [
      "rawSamplesAttempted": intrinsicsAccepted + intrinsicsRejected,
      "rawSamplesAccepted": intrinsicsAccepted,
      "rawSamplesRejected": intrinsicsRejected,
      "intrinsicsOverwritten": intrinsicsOverwritten,
      "rejectionReasons": [
        // Native transports every platform numeric value unchanged. Numeric
        // validation/rejection happens only in the Dart raw-wire parser.
        "invalid_input": 0,
        "lock_contention": intrinsicsContentionCount,
        "stale_generation": intrinsicsStaleCount,
      ],
    ]
    lock.unlock()
    let startBefore: Any = start.map { $0.uptimeRawBeforeSeconds } ?? NSNull()
    let startMonotonic: Any = start.map { $0.monotonicSeconds } ?? NSNull()
    let startAfter: Any = start.map { $0.uptimeRawAfterSeconds } ?? NSNull()

    var out: [String: Any] = [
      "schema": "pw.vio.timebase-raw/5",
      "sessionId": sessionId,
      "sessionEpoch": sessionEpoch,
      "sessionGeneration": generation,
      "uptimeRawBeforeSeconds": pair.uptimeRawBeforeSeconds,
      "monotonicSeconds": pair.monotonicSeconds,
      "uptimeRawAfterSeconds": pair.uptimeRawAfterSeconds,
      "sessionStartUptimeRawBeforeSeconds": startBefore,
      "sessionStartMonotonicSeconds": startMonotonic,
      "sessionStartUptimeRawAfterSeconds": startAfter,
      "syncClockUnavailableCount": syncFail,
      "synchronizationClockAvailable": {
        if #available(iOS 15.4, *) { return true } else { return false }
      }(),
      "arFrameExifAvailable": {
        if #available(iOS 16.0, *) { return true } else { return false }
      }(),
      "outOfSessionStaleObservations": outOfSessionStaleObservations.value,
      "intrinsicsAccounting": intrinsicsWire,
    ]

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
        let args = call.arguments as? [String: Any] ?? [:]
        guard let sessionId = args["sessionId"] as? String,
              let sessionEpoch = args["sessionEpoch"] as? Int else {
          result(FlutterError(
            code: "PW_VIO_INVALID_SESSION",
            message: "beginSession requires sessionId/sessionEpoch",
            details: nil
          ))
          return
        }
        let began = PwVioTimebase.shared.beginSession(
          sessionId: sessionId,
          sessionEpoch: sessionEpoch
        )
        if began {
          result(nil)
        } else {
          result(FlutterError(
            code: "PW_VIO_SESSION_OVERLAP",
            message: "previous timebase session is not sealed",
            details: nil
          ))
        }
      case "remeasure":
        result(PwVioTimebase.shared.remeasure())
      case "snapshot":
        result(PwVioTimebase.shared.snapshot())
      case "startRawCoreMotionFeed":
        let args = call.arguments as? [String: Any] ?? [:]
        guard let accelerometerHz = args["accelerometerHz"] as? Double,
              let gyroscopeHz = args["gyroscopeHz"] as? Double,
              accelerometerHz.isFinite, accelerometerHz > 0,
              gyroscopeHz.isFinite, gyroscopeHz > 0 else {
          result(false)
          return
        }
        result(PwVioTimebase.shared.startRawCoreMotionFeed(
          accelerometerHz: accelerometerHz,
          gyroscopeHz: gyroscopeHz
        ))
      case "stopRawCoreMotionFeed":
        PwVioTimebase.shared.stopRawCoreMotionFeed()
        result(nil)
      case "slamStart":
        let args = call.arguments as? [String: Any] ?? [:]
        guard let slam = args["slamConfigPath"] as? String,
              let dev = args["deviceConfigPath"] as? String,
              let sessionId = args["sessionId"] as? String,
              let sessionEpoch = args["sessionEpoch"] as? Int,
              let configSha = args["effectiveConfigSha256"] as? String,
              let inputSha = args["inputIdentitySha256"] as? String,
              let downsampleFactor = args["downsampleFactor"] as? Int,
              let downsampleFormula = args["downsampleFormula"] as? String,
              let requestedCameraHz = args["requestedCameraHz"] as? Double,
              let cameraTimeOffsetSeconds = args["cameraTimeOffsetSeconds"] as? Double,
              let accelerationScale = args["accelerationScale"] as? Double,
              let requestedAccelerometerHz = args["requestedAccelerometerHz"] as? Double,
              let requestedGyroscopeHz = args["requestedGyroscopeHz"] as? Double,
              downsampleFactor > 0,
              !downsampleFormula.isEmpty,
              requestedCameraHz.isFinite,
              requestedCameraHz > 0,
              cameraTimeOffsetSeconds.isFinite,
              accelerationScale.isFinite,
              accelerationScale != 0,
              requestedAccelerometerHz.isFinite,
              requestedAccelerometerHz > 0,
              requestedGyroscopeHz.isFinite,
              requestedGyroscopeHz > 0 else {
          result([
            "schema": "pw.vio.shadow-start-receipt/1",
            "rc": 0,
            "generation": 0,
            "failureReason": "invalid-arguments",
            "snapshot": NSNull(),
          ])
          return
        }
        if #available(iOS 11.0, *) {
          PwVioTimebase.shared.startShadowPipeline(
            slamConfigPath: slam,
            deviceConfigPath: dev,
            sessionId: sessionId,
            sessionEpoch: sessionEpoch,
            effectiveConfigSha256: configSha,
            inputIdentitySha256: inputSha,
            downsampleFactor: downsampleFactor,
            downsampleFormula: downsampleFormula,
            requestedCameraHz: requestedCameraHz,
            cameraTimeOffsetSeconds: cameraTimeOffsetSeconds,
            accelerationScale: accelerationScale,
            requestedAccelerometerHz: requestedAccelerometerHz,
            requestedGyroscopeHz: requestedGyroscopeHz
          ) { receipt in
            result(receipt)
          }
        } else {
          result([
            "schema": "pw.vio.shadow-start-receipt/1",
            "rc": 0,
            "generation": 0,
            "failureReason": "unsupported-platform",
            "snapshot": NSNull(),
          ])
        }
      case "slamStop":
        PwVioTimebase.shared.shutdownShadowPipeline { receipt in
          result(receipt)
        }
      case "slamSnapshot":
        if #available(iOS 11.0, *) { result(PwVioSlamFeeder.shared.snapshot()) }
        else { result(nil) }
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
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
#endif
