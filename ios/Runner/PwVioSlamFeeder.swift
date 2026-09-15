// PwVioSlamFeeder.swift — 把 ARKit 帧与 CoreMotion 样本喂给 XRSLAM。
//
// 为什么在原生侧喂:ARFrame 本来就在原生。从 Dart 喂意味着每帧把像素缓冲跨
// FFI 边界拷一次 —— 1920×1440 灰度 = 2.7 MB/帧,30fps 就是 83 MB/s 的桥接拷贝。
// 原生侧保留 CVPixelBuffer,在 worker 上直接读亮度平面并只写一次降采样 scratch;
// Dart 侧只传配置、读位姿和健康状态,避免把整帧像素穿过平台通道。
//
// 跨端边界:
//   ① Swift 只抄录平台原始时间戳/跟踪枚举,不判时基、可用性或质量；
//   ② 每个成功 Push 的图像固定 RunOneFrame 一次,不在 Swift 写频率策略；
//   ③ 回调只尝试有界入队，绝不等算法；压力不能反向控制拍照。
//      任何溢出都显式计数并使整场影子运行失效，不伪造完整输入。

import ARKit
import CoreMotion
import Darwin
import Foundation
import simd

@available(iOS 11.0, *)
public final class PwVioSlamFeeder {
  public static let shared = PwVioSlamFeeder()
  private init() {}

  private enum ShadowState: String {
    case stopped, starting, running, stopping
  }

  private struct PendingFrame {
    let pixelBuffer: CVPixelBuffer
    let timestamp: Double
    let arkitWorldFromCamera: simd_float4x4
    // Raw ARKit enum facts only. Dart owns the cross-platform usable/rejected
    // decision and all quality policy.
    let referenceTrackingState: String
    let referenceTrackingReason: String
    let enqueuedAt: CFTimeInterval
  }

  private struct PendingAcceleration {
    let timestamp: Double
    let x: Double
    let y: Double
    let z: Double
  }

  private struct PendingGyroscope {
    let timestamp: Double
    let x: Double
    let y: Double
    let z: Double
  }

  private enum SensorStream {
    case image, acceleration, gyroscope
  }

  private enum PendingWork {
    case image(PendingFrame, epoch: Int)
    case acceleration(PendingAcceleration, epoch: Int)
    case gyroscope(PendingGyroscope, epoch: Int)

    var epoch: Int {
      switch self {
      case .image(_, let epoch),
           .acceleration(_, let epoch),
           .gyroscope(_, let epoch): return epoch
      }
    }

    var stream: SensorStream {
      switch self {
      case .image: return .image
      case .acceleration: return .acceleration
      case .gyroscope: return .gyroscope
      }
    }

    var isImage: Bool {
      if case .image = stream { return true }
      return false
    }
  }

  private static let maxStateTransitions = 16
  private static let maxQueuedWork = 256
  private static let maxRetainedImages = 2
  // Transport-only bound. Every processed image offers one raw pose/health
  // observation; Dart owns polling cadence and every semantic classification.

  private let lock = NSLock()
  private let coreQueue = DispatchQueue(
    label: "com.pocketworld.vio.shadow.core",
    qos: .utility
  )
  private var pendingWork = Array<PendingWork?>(
    repeating: nil,
    count: PwVioSlamFeeder.maxQueuedWork
  )
  private var pendingHead = 0
  private var pendingTail = 0
  private var pendingCount = 0
  private var pendingImageCount = 0
  private var inFlightImageCount = 0
  private var maxRetainedImageCount = 0
  private var drainScheduled = false
  private var inFlightCount = 0
  private var queueAccepted = 0
  private var queueProcessedSuccess = 0
  private var droppedOnStop = 0
  private var terminalRejected = 0
  private var maxQueueBacklog = 0
  private var shadowRunInvalidated = false
  private var runInvalidationReasons: [String: Int] = [:]
  private var state = ShadowState.stopped
  private var stateTransitions: [String] = []
  private var sessionGeneration = 0
  private struct StartRequest {
    let slamConfigPath: String
    let deviceConfigPath: String
    let sessionId: String
    let sessionEpoch: Int
    let effectiveConfigSha256: String
    let inputIdentitySha256: String
    let downsampleFactor: Int
    let downsampleFormula: String
    let requestedCameraHz: Double
    let cameraTimeOffsetSeconds: Double
    let accelerationScale: Double
    let requestedAccelerometerHz: Double
    let requestedGyroscopeHz: Double

    func matches(_ other: StartRequest) -> Bool {
      slamConfigPath == other.slamConfigPath &&
        deviceConfigPath == other.deviceConfigPath &&
        sessionId == other.sessionId &&
        sessionEpoch == other.sessionEpoch &&
        effectiveConfigSha256 == other.effectiveConfigSha256 &&
        inputIdentitySha256 == other.inputIdentitySha256 &&
        downsampleFactor == other.downsampleFactor &&
        downsampleFormula == other.downsampleFormula &&
        requestedCameraHz == other.requestedCameraHz &&
        cameraTimeOffsetSeconds == other.cameraTimeOffsetSeconds &&
        accelerationScale == other.accelerationScale &&
        requestedAccelerometerHz == other.requestedAccelerometerHz &&
        requestedGyroscopeHz == other.requestedGyroscopeHz
    }
  }
  private var startCompletions: [(Int32, Int) -> Void] = []
  private var canceledStartCompletions: [(Int32, Int) -> Void] = []
  private var pendingRestart: StartRequest?
  private var pendingRestartCompletions: [(Int32, Int) -> Void] = []
  private var stopCompletions: [([String: Any]) -> Void] = []
  private var created = false
  private var shutdownDrops = 0
  private var nativeDestroyReceipt: [String: Any] = [:]

  // Generation and count share one CAS word. A callback that captured an old
  // generation can never increment a newly reset counter, even if reset lands
  // between its load and compare-and-swap.
  private final class GenerationCounter {
    private static let countMask: UInt64 = 0xffff_ffff
    private var packed: Int64 = 0

    private static func load(_ value: inout Int64) -> UInt64 {
      UInt64(bitPattern: OSAtomicAdd64Barrier(0, &value))
    }

    private static func replace(_ value: inout Int64, with bits: UInt64) {
      while true {
        let old = OSAtomicAdd64Barrier(0, &value)
        if OSAtomicCompareAndSwap64Barrier(
          old,
          Int64(bitPattern: bits),
          &value
        ) { return }
      }
    }

    func beginGeneration(_ generation: Int) {
      let token = UInt64(UInt32(truncatingIfNeeded: generation)) << 32
      Self.replace(&packed, with: token)
    }

    @discardableResult
    func increment(generation: UInt32) -> Bool {
      while true {
        let old = Self.load(&packed)
        guard UInt32(truncatingIfNeeded: old >> 32) == generation else {
          return false
        }
        let count = old & Self.countMask
        guard count < Self.countMask else { return false }
        let next = (UInt64(generation) << 32) | (count + 1)
        if OSAtomicCompareAndSwap64Barrier(
          Int64(bitPattern: old),
          Int64(bitPattern: next),
          &packed
        ) { return true }
      }
    }

    func value(generation: Int) -> Int? {
      let bits = Self.load(&packed)
      guard UInt32(truncatingIfNeeded: bits >> 32) ==
              UInt32(truncatingIfNeeded: generation) else { return nil }
      return Int(bits & Self.countMask)
    }

    func seal(generation: Int) -> Int? {
      let expected = UInt32(truncatingIfNeeded: generation)
      while true {
        let old = Self.load(&packed)
        let token = UInt32(truncatingIfNeeded: old >> 32)
        guard token == expected else { return nil }
        let sealed = UInt64(expected | 0x8000_0000) << 32 |
          (old & Self.countMask)
        if OSAtomicCompareAndSwap64Barrier(
          Int64(bitPattern: old),
          Int64(bitPattern: sealed),
          &packed
        ) { return Int(old & Self.countMask) }
      }
    }
  }

  private final class AtomicCounter {
    private var storage: Int64 = 0
    func increment() { _ = OSAtomicIncrement64Barrier(&storage) }
    var value: Int { Int(OSAtomicAdd64Barrier(0, &storage)) }
  }

  private final class AdmissionGate {
    enum Phase: UInt64 { case open = 0, rejecting = 1, sealed = 2 }
    struct Entry { let generation: UInt32; let phase: Phase }
    private static let activeMask: UInt64 = 0x3fff_ffff
    private static let phaseShift: UInt64 = 30
    // Generation zero begins sealed. Before the first Dart-authorized start,
    // ARKit/CoreMotion callbacks must not acquire a phantom generation-0 lease.
    private var packed: Int64
    private let sealLock = NSLock()
    private var sealGeneration: Int?
    private var sealCompletion: (() -> Void)?

    init() {
      packed = Int64(
        bitPattern: Phase.sealed.rawValue << Self.phaseShift
      )
    }

    private func load() -> UInt64 {
      UInt64(bitPattern: OSAtomicAdd64Barrier(0, &packed))
    }

    @discardableResult
    func begin(generation: Int) -> Bool {
      let next = UInt64(UInt32(truncatingIfNeeded: generation)) << 32
      while true {
        let old = load()
        // A new session must never erase a callback lease from the previous
        // generation. Correct lifecycle closure seals that generation first;
        // a violation fails the start safely instead of corrupting accounting.
        guard old & Self.activeMask == 0 else { return false }
        if OSAtomicCompareAndSwap64Barrier(
          Int64(bitPattern: old), Int64(bitPattern: next), &packed
        ) {
          sealLock.lock()
          sealGeneration = nil
          sealCompletion = nil
          sealLock.unlock()
          return true
        }
      }
    }

    func enter() -> Entry? {
      while true {
        let old = load()
        let phaseRaw = (old >> Self.phaseShift) & 0x3
        guard let phase = Phase(rawValue: phaseRaw), phase != .sealed else {
          return nil
        }
        let active = old & Self.activeMask
        guard active < Self.activeMask else { return nil }
        let next = old + 1
        if OSAtomicCompareAndSwap64Barrier(
          Int64(bitPattern: old), Int64(bitPattern: next), &packed
        ) {
          return Entry(
            generation: UInt32(truncatingIfNeeded: old >> 32),
            phase: phase
          )
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

    func beginRejecting(generation: Int) {
      let expected = UInt32(truncatingIfNeeded: generation)
      while true {
        let old = load()
        guard UInt32(truncatingIfNeeded: old >> 32) == expected else { return }
        let phase = (old >> Self.phaseShift) & 0x3
        guard phase == Phase.open.rawValue else { return }
        let next = old | (Phase.rejecting.rawValue << Self.phaseShift)
        if OSAtomicCompareAndSwap64Barrier(
          Int64(bitPattern: old), Int64(bitPattern: next), &packed
        ) { return }
      }
    }

    func seal(generation: Int) -> Bool {
      let expected = UInt32(truncatingIfNeeded: generation)
      while true {
        let old = load()
        guard UInt32(truncatingIfNeeded: old >> 32) == expected else {
          return false
        }
        guard old & Self.activeMask == 0 else { return false }
        let phase = (old >> Self.phaseShift) & 0x3
        if phase == Phase.sealed.rawValue { return true }
        guard phase == Phase.rejecting.rawValue else { return false }
        let clearedPhase = old & ~(UInt64(0x3) << Self.phaseShift)
        let next = clearedPhase | (Phase.sealed.rawValue << Self.phaseShift)
        if OSAtomicCompareAndSwap64Barrier(
          Int64(bitPattern: old), Int64(bitPattern: next), &packed
        ) { return true }
      }
    }

    /// Arms exactly one completion and fires it on the transition to zero
    /// active callback leases. This is edge-triggered; no queue polls/spins.
    func sealWhenQuiescent(
      generation: Int,
      completion: @escaping () -> Void
    ) {
      sealLock.lock()
      guard sealCompletion == nil else {
        sealLock.unlock()
        return
      }
      sealGeneration = generation
      sealCompletion = completion
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
      var completion: (() -> Void)?
      guard sealLock.try() else { return }
      if sealGeneration == generation,
         sealCompletion != nil,
         seal(generation: generation) {
        completion = sealCompletion
        sealCompletion = nil
        sealGeneration = nil
      }
      sealLock.unlock()
      completion?()
    }
  }

  private let admissionGate = AdmissionGate()
  private let imageLockContention = GenerationCounter()
  private let accelerationLockContention = GenerationCounter()
  private let gyroscopeLockContention = GenerationCounter()
  private let imageStopRejections = GenerationCounter()
  private let accelerationStopRejections = GenerationCounter()
  private let gyroscopeStopRejections = GenerationCounter()
  private let outOfSessionImageOffers = AtomicCounter()
  private let outOfSessionAccelerationOffers = AtomicCounter()
  private let outOfSessionGyroscopeOffers = AtomicCounter()
  private var sealedImageLockContention: Int?
  private var sealedAccelerationLockContention: Int?
  private var sealedGyroscopeLockContention: Int?
  private var sealedImageStopRejections: Int?
  private var sealedAccelerationStopRejections: Int?
  private var sealedGyroscopeStopRejections: Int?

  private enum SensorRejectionReason: String, CaseIterable {
    case notRunning = "not_running"
    case lockContention = "lock_contention"
    case queueFull = "queue_full"
    case cameraFull = "camera_full"
    case lateAfterSeal = "late_after_seal"
    case droppedOnStop = "dropped_on_stop"
    case staleEpoch = "stale_epoch"
    case invalidInput = "invalid_input"
    case nonMonotonic = "non_monotonic"
    case nativeReject = "native_reject"
  }

  private struct SensorFacts {
    var attempted = 0
    var submitted = 0
    var rejected = 0
    var reasons = Dictionary(
      uniqueKeysWithValues: SensorRejectionReason.allCases.map { ($0, 0) }
    )

    mutating func offer() { attempted += 1 }
    mutating func submit() { submitted += 1 }
    mutating func reject(_ reason: SensorRejectionReason) {
      rejected += 1
      reasons[reason, default: 0] += 1
    }

    func wire(lockContention: Int, stopRejections: Int) ->
      (attempted: Int, submitted: Int, rejected: Int, reasons: [String: Int]) {
      var wireReasons = Dictionary(uniqueKeysWithValues: reasons.map {
        ($0.key.rawValue, $0.value)
      })
      wireReasons[SensorRejectionReason.lockContention.rawValue, default: 0] +=
        lockContention
      wireReasons[SensorRejectionReason.lateAfterSeal.rawValue, default: 0] +=
        stopRejections
      return (
        attempted + lockContention + stopRejections,
        submitted,
        rejected + lockContention + stopRejections,
        wireReasons
      )
    }
  }

  private var imageFacts = SensorFacts()
  private var accFacts = SensorFacts()
  private var gyroFacts = SensorFacts()
  private var overflowBase = 0

  private enum ProcessingOutcome {
    case success, invalidInput, nonMonotonic, nativeReject
  }
  private var terminalStale = 0
  private var terminalInvalidInput = 0
  private var terminalNonMonotonic = 0
  private var terminalNativeReject = 0
  private var terminalInternal = 0

  // ── 降采样到 VIO 的工作分辨率 ──
  // Dart selects the factor as part of the effective cross-platform config.
  // Dart also selects the versioned kernel + rounding formula. Swift only
  // applies that exact contract beside the source buffer and rejects unknown
  // formulas or dimensions that cannot represent it.
  private static let downsampleFormulaBoxNxnHalfUpV1 =
    "box-nxn-half-up-v1"
  private var scratch: UnsafeMutablePointer<UInt8>?
  private var scratchCapacity = 0
  private var vioWidth = 0, vioHeight = 0

  /// N×N 盒式降采样。返回 nil 表示尺寸不是 N 的整数倍(不猜,直接拒绝)。
  private func downsampleBox(src: UnsafePointer<UInt8>, srcW: Int, srcH: Int,
                             srcStride: Int, downsampleFactor: Int,
                             downsampleFormula: String) ->
    (UnsafeMutablePointer<UInt8>, Int, Int)? {
    guard downsampleFormula == Self.downsampleFormulaBoxNxnHalfUpV1 else {
      return nil
    }
    let n = downsampleFactor
    guard n >= 1, n <= srcW, n <= srcH,
          srcW % n == 0, srcH % n == 0 else { return nil }
    let dw = srcW / n, dh = srcH / n
    let need = dw * dh
    if scratchCapacity < need {
      scratch?.deallocate()
      scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: need)
      scratchCapacity = need
    }
    guard let dst = scratch else { return nil }
    let area = n * n
    let half = area / 2          // 四舍五入的偏置
    for y in 0..<dh {
      let orow = dst + y * dw
      for x in 0..<dw {
        var sum = 0
        for dy in 0..<n {
          let row = src + (y * n + dy) * srcStride + x * n
          for dx in 0..<n { sum += Int(row[dx]) }
        }
        orow[x] = UInt8((sum + half) / area)
      }
    }
    vioWidth = dw; vioHeight = dh
    return (dst, dw, dh)
  }

  /// XRSLAM 是全局单例(C API 没有句柄参数),全部入口只允许 coreQueue 调用。
  private var lastImageT: Double = 0
  private var lastImuT: Double = 0
  private var accSumX: Double = 0
  private var accSumY: Double = 0
  private var accSumZ: Double = 0
  private var accNativeSubmittedCount = 0
  private var runCalls = 0
  private var lastImageRc: Int32 = 0
  private var lastAccRc: Int32 = 0
  private var lastGyroRc: Int32 = 0
  private var lastHealthRc: Int32 = 2
  private var cachedHealth: [String: Any] = [:]
  private var cachedSnapshot: [String: Any] = [:]

  private var feedWallStartedAtUptimeSeconds: CFTimeInterval = 0
  private var solveWallSum: Double = 0
  private var previousImageTimestamp: Double = 0
  private var workerFrameCount = 0
  private var workerFrameMsSum = 0.0
  private var enqueueLatencyUsSum = 0.0

  private var sessionStartedAt: CFTimeInterval = 0

  // Transient raw status observations. Each processed image offers one. Dart
  // consumes and clears them, then persists aggregate classifications only.
  private var poseObservationSequence = 0
  private var poseObservationsOffered = 0
  private var poseObservationsDropped = 0
  private var poseObservations: [[String: Any]] = []

  private var lastStartRequest: StartRequest?
  // Only the ARSession delegate callback reads/writes these two values. The
  // generation stamp makes the first frame of every native run pass without
  // a cross-thread reset. Dart selects the rate; Swift only applies it.
  private var lastAdmittedCameraTimestamp = -Double.infinity
  private var lastAdmittedCameraGeneration: UInt32 = 0
  private var cameraRateSampledOut = 0

  // MARK: - 生命周期

  private func transitionLocked(to next: ShadowState) {
    let previous = state
    state = next
    if stateTransitions.count == Self.maxStateTransitions {
      stateTransitions.removeFirst()
    }
    stateTransitions.append("\(previous.rawValue)->\(next.rawValue)")
  }

  private func resetSessionMetricsLocked(generation: Int) {
    pendingWork = Array<PendingWork?>(
      repeating: nil,
      count: Self.maxQueuedWork
    )
    pendingHead = 0
    pendingTail = 0
    pendingCount = 0
    pendingImageCount = 0
    inFlightImageCount = 0
    maxRetainedImageCount = 0
    drainScheduled = false
    inFlightCount = 0
    queueAccepted = 0
    queueProcessedSuccess = 0
    droppedOnStop = 0
    terminalRejected = 0
    terminalStale = 0
    terminalInvalidInput = 0
    terminalNonMonotonic = 0
    terminalNativeReject = 0
    terminalInternal = 0
    maxQueueBacklog = 0
    shadowRunInvalidated = false
    runInvalidationReasons.removeAll(keepingCapacity: true)
    stateTransitions.removeAll(keepingCapacity: true)
    shutdownDrops = 0
    nativeDestroyReceipt.removeAll(keepingCapacity: true)
    imageFacts = SensorFacts()
    accFacts = SensorFacts()
    gyroFacts = SensorFacts()
    overflowBase = 0
    sealedImageLockContention = nil
    sealedAccelerationLockContention = nil
    sealedGyroscopeLockContention = nil
    sealedImageStopRejections = nil
    sealedAccelerationStopRejections = nil
    sealedGyroscopeStopRejections = nil
    imageLockContention.beginGeneration(generation)
    accelerationLockContention.beginGeneration(generation)
    gyroscopeLockContention.beginGeneration(generation)
    imageStopRejections.beginGeneration(generation)
    accelerationStopRejections.beginGeneration(generation)
    gyroscopeStopRejections.beginGeneration(generation)
    lastImageT = 0
    lastImuT = 0
    accSumX = 0
    accSumY = 0
    accSumZ = 0
    accNativeSubmittedCount = 0
    runCalls = 0
    lastImageRc = 0
    lastAccRc = 0
    lastGyroRc = 0
    lastHealthRc = 2
    cachedHealth.removeAll(keepingCapacity: true)
    feedWallStartedAtUptimeSeconds = 0
    solveWallSum = 0
    previousImageTimestamp = 0
    workerFrameCount = 0
    workerFrameMsSum = 0
    enqueueLatencyUsSum = 0
    sessionStartedAt = CACurrentMediaTime()
    poseObservationSequence = 0
    poseObservationsOffered = 0
    poseObservationsDropped = 0
    cameraRateSampledOut = 0
    poseObservations.removeAll(keepingCapacity: true)
    cachedSnapshot = makeCoreSnapshotLocked()
  }

  private func beginStartLocked(
    _ request: StartRequest,
    completions: [(Int32, Int) -> Void]
  ) -> Int? {
    sessionGeneration += 1
    let epoch = sessionGeneration
    resetSessionMetricsLocked(generation: epoch)
    // Publish only after every generation-scoped counter has reset. `begin`
    // refuses to overwrite any live lease from the prior generation.
    guard admissionGate.begin(generation: epoch) else { return nil }
    lastStartRequest = request
    startCompletions.append(contentsOf: completions)
    transitionLocked(to: .starting)
    cachedSnapshot = makeCoreSnapshotLocked()
    return epoch
  }

  /// Core-create failure uses the same sealed terminal path as an explicit
  /// stop. Caller holds `lock`; completion is withheld until every callback
  /// lease from `epoch` has left and AdmissionGate.seal succeeds.
  private func closeFailedCreateGeneration(epoch: Int) -> Bool {
    guard sessionGeneration == epoch, state == .starting else { return false }
    created = false
    transitionLocked(to: .stopping)
    admissionGate.beginRejecting(generation: epoch)
    rejectPendingOnStopLocked()
    cachedSnapshot = makeCoreSnapshotLocked()
    return true
  }

  private func scheduleCreate(_ request: StartRequest, epoch: Int) {
    coreQueue.async { [weak self] in
      guard let self else { return }
      let rc = request.slamConfigPath.withCString { slam in
        request.deviceConfigPath.withCString { device in
          PWXrslamTransportCreateWithCameraTimeOffset(
            slam,
            device,
            request.cameraTimeOffsetSeconds
          )
        }
      }

      var completed: [(Int32, Int) -> Void] = []
      var destroyOrphan = false
      var shouldCloseFailedCreate = false
      self.lock.lock()
      if self.sessionGeneration == epoch {
        self.created = (rc == 1)
        if self.state == .starting, self.created {
          self.transitionLocked(to: .running)
          completed = self.startCompletions
          self.startCompletions.removeAll(keepingCapacity: true)
        } else if self.state == .starting {
          shouldCloseFailedCreate = self.closeFailedCreateGeneration(
            epoch: epoch
          )
        }
        // If stop raced Create, state is stopping. The start completions stay
        // pending until Destroy has completed, then finish with rc=0. A stale
        // success can therefore never restart CoreMotion after stop.
        self.cachedSnapshot = self.makeCoreSnapshotLocked()
      } else if rc == 1 {
        // A newer generation cannot inherit a process-global core instance
        // created for an obsolete request. This block still owns coreQueue, so
        // Destroy is ordered before any newer Create.
        destroyOrphan = true
      }
      self.lock.unlock()

      if destroyOrphan { PWXrslamTransportDestroy() }
      if shouldCloseFailedCreate {
        self.finishStopOnCoreQueue()
      }

      if !completed.isEmpty {
        DispatchQueue.main.async {
          for completion in completed { completion(1, epoch) }
        }
      }
    }
  }

  /// Create is asynchronous and serialized with every later XRSLAM call.
  /// A start received while stopping becomes one coalesced post-Destroy
  /// restart rather than being lost or lying with an immediate success code.
  public func start(
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
    completion: @escaping (Int32, Int) -> Void
  ) {
    guard downsampleFactor > 0,
          downsampleFormula == Self.downsampleFormulaBoxNxnHalfUpV1,
          requestedCameraHz.isFinite,
          requestedCameraHz > 0,
          cameraTimeOffsetSeconds.isFinite,
          accelerationScale.isFinite,
          accelerationScale != 0,
          requestedAccelerometerHz.isFinite,
          requestedAccelerometerHz > 0,
          requestedGyroscopeHz.isFinite,
          requestedGyroscopeHz > 0 else {
      DispatchQueue.main.async { completion(0, 0) }
      return
    }
    let request = StartRequest(
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
    )
    lock.lock()
    switch state {
    case .running:
      let active = lastStartRequest
      let generation = sessionGeneration
      // Idempotent start is truthful only for the configuration that is
      // actually active. Callers requesting a different configuration must
      // explicitly stop/restart rather than receiving a false success.
      let success = created && active.map(request.matches) == true
      lock.unlock()
      DispatchQueue.main.async { completion(success ? 1 : 0, generation) }
      return
    case .starting:
      if lastStartRequest.map(request.matches) == true {
        startCompletions.append(completion)
        lock.unlock()
      } else {
        let generation = sessionGeneration
        lock.unlock()
        DispatchQueue.main.async { completion(0, generation) }
      }
      return
    case .stopping:
      if let pendingRestart, !request.matches(pendingRestart) {
        // Latest distinct restart wins; completions for a superseded request
        // finish false after Destroy, never true for somebody else's config.
        canceledStartCompletions.append(
          contentsOf: pendingRestartCompletions)
        pendingRestartCompletions.removeAll(keepingCapacity: true)
      }
      pendingRestart = request
      pendingRestartCompletions.append(completion)
      lock.unlock()
      return
    case .stopped:
      guard let epoch = beginStartLocked(
        request,
        completions: [completion]
      ) else {
        let generation = sessionGeneration
        lock.unlock()
        DispatchQueue.main.async { completion(0, generation) }
        return
      }
      // Enqueue Create before publishing the unlocked `.starting` state. A
      // racing stop will then enqueue Destroy/drain *after* Create, never
      // before it.
      scheduleCreate(request, epoch: epoch)
      lock.unlock()
    }
  }

  private func rejectPendingOnStopLocked() {
    while pendingCount > 0 {
      guard let item = pendingWork[pendingHead] else {
        terminalInternal += 1
        invalidateRunLocked(reason: "internal_empty_queue_slot")
        pendingHead = (pendingHead + 1) % Self.maxQueuedWork
        pendingCount -= 1
        continue
      }
      pendingWork[pendingHead] = nil
      pendingHead = (pendingHead + 1) % Self.maxQueuedWork
      pendingCount -= 1
      if item.isImage {
        pendingImageCount -= 1
      }
      droppedOnStop += 1
      shutdownDrops += 1
      rejectSensorLocked(stream: item.stream, reason: .droppedOnStop)
      invalidateRunLocked(reason: SensorRejectionReason.droppedOnStop.rawValue)
    }
    pendingHead = 0
    pendingTail = 0
  }

  /// Stop closes admission immediately, accounts every pending item, and then
  /// queues Destroy behind any in-flight native call. It never waits/syncs.
  public func stop(
    completion: @escaping ([String: Any]) -> Void = { _ in }
  ) {
    lock.lock()
    if state == .stopped {
      let receipt: [String: Any] = [
        "schema": "pw.vio.shadow-terminal-unavailable/1",
        "sessionGeneration": sessionGeneration,
        "receiptAvailable": false,
      ]
      lock.unlock()
      DispatchQueue.main.async { completion(receipt) }
      return
    }
    // A later stop supersedes a resume queued during the current stop. Those
    // start callers finish with rc=0 only after the terminal stopped state.
    if pendingRestart != nil {
      pendingRestart = nil
      canceledStartCompletions.append(
        contentsOf: pendingRestartCompletions)
      pendingRestartCompletions.removeAll(keepingCapacity: true)
    }
    if state == .stopping {
      // Join the in-progress linearized stop. No caller may observe completion
      // before in-flight C work, Destroy, and receipt freezing have finished.
      stopCompletions.append(completion)
      lock.unlock()
      return
    }
    stopCompletions.append(completion)
    transitionLocked(to: .stopping)
    admissionGate.beginRejecting(generation: sessionGeneration)
    rejectPendingOnStopLocked()
    let epoch = sessionGeneration
    let shouldSchedule = !drainScheduled
    if shouldSchedule { drainScheduled = true }
    lock.unlock()
    if shouldSchedule {
      coreQueue.async { [weak self] in self?.drain(epoch: epoch) }
    }
  }

  public var isRunning: Bool {
    lock.lock(); defer { lock.unlock() }
    return state == .running && created
  }

  /// Freezes the running facts only for the exact Create completion epoch.
  /// Generic snapshots never establish start provenance in Dart.
  public func directRunningReceipt(expectedGeneration: Int) -> [String: Any]? {
    lock.lock()
    defer { lock.unlock() }
    guard expectedGeneration > 0,
          sessionGeneration == expectedGeneration,
          state == .running,
          created else { return nil }
    return makeWireSnapshotLocked(includeRaw: false)
  }

  private enum AdmissionRejection {
    case notRunning, staleEpoch
  }

  private func offerSensorLocked(stream: SensorStream) {
    switch stream {
    case .image: imageFacts.offer()
    case .acceleration: accFacts.offer()
    case .gyroscope: gyroFacts.offer()
    }
  }

  private func rejectSensorLocked(
    stream: SensorStream,
    reason: SensorRejectionReason
  ) {
    switch stream {
    case .image: imageFacts.reject(reason)
    case .acceleration: accFacts.reject(reason)
    case .gyroscope: gyroFacts.reject(reason)
    }
  }

  private func noteOutOfSessionOffer(stream: SensorStream) {
    switch stream {
    case .image: outOfSessionImageOffers.increment()
    case .acceleration: outOfSessionAccelerationOffers.increment()
    case .gyroscope: outOfSessionGyroscopeOffers.increment()
    }
  }

  private func noteLockContention(
    stream: SensorStream,
    generation: UInt32
  ) {
    switch stream {
    case .image:
      if !imageLockContention.increment(generation: generation) {
        outOfSessionImageOffers.increment()
      }
    case .acceleration:
      if !accelerationLockContention.increment(generation: generation) {
        outOfSessionAccelerationOffers.increment()
      }
    case .gyroscope:
      if !gyroscopeLockContention.increment(generation: generation) {
        outOfSessionGyroscopeOffers.increment()
      }
    }
  }

  private func invalidateRunLocked(reason: String) {
    shadowRunInvalidated = true
    runInvalidationReasons[reason, default: 0] += 1
  }

  private func rejectUnadmittedLocked(
    stream: SensorStream,
    reason: AdmissionRejection
  ) {
    let sensorReason: SensorRejectionReason
    switch reason {
    case .notRunning:
      sensorReason = .notRunning
    case .staleEpoch:
      sensorReason = .staleEpoch
    }
    rejectSensorLocked(stream: stream, reason: sensorReason)
  }

  /// Nonblocking bounded admission. A callback that cannot acquire the short
  /// ledger lock or fit inside either hard capacity returns immediately and
  /// invalidates the shadow run; it never paces production capture.
  private func admit(
    _ unscopedWork: PendingWork,
    lease: AdmissionGate.Entry
  ) -> Bool {
    guard lock.try() else {
      noteLockContention(
        stream: unscopedWork.stream,
        generation: lease.generation
      )
      return false
    }
    offerSensorLocked(stream: unscopedWork.stream)
    guard state == .running && created else {
      rejectUnadmittedLocked(
        stream: unscopedWork.stream,
        reason: .notRunning
      )
      lock.unlock()
      return false
    }
    let generation = UInt32(truncatingIfNeeded: sessionGeneration)
    guard lease.generation == generation else {
      rejectUnadmittedLocked(
        stream: unscopedWork.stream,
        reason: .staleEpoch
      )
      lock.unlock()
      return false
    }
    let epoch = sessionGeneration
    let work: PendingWork
    switch unscopedWork {
    case .image(let frame, _): work = .image(frame, epoch: epoch)
    case .acceleration(let sample, _):
      work = .acceleration(sample, epoch: epoch)
    case .gyroscope(let sample, _):
      work = .gyroscope(sample, epoch: epoch)
    }
    guard pendingCount < Self.maxQueuedWork else {
      rejectSensorLocked(stream: work.stream, reason: .queueFull)
      overflowBase += 1
      invalidateRunLocked(reason: SensorRejectionReason.queueFull.rawValue)
      lock.unlock()
      return false
    }
    if work.isImage {
      guard pendingImageCount + inFlightImageCount < Self.maxRetainedImages
      else {
        rejectSensorLocked(stream: work.stream, reason: .cameraFull)
        overflowBase += 1
        invalidateRunLocked(reason: SensorRejectionReason.cameraFull.rawValue)
        lock.unlock()
        return false
      }
    }
    pendingWork[pendingTail] = work
    pendingTail = (pendingTail + 1) % Self.maxQueuedWork
    pendingCount += 1
    if work.isImage {
      pendingImageCount += 1
      maxRetainedImageCount = max(
        maxRetainedImageCount,
        pendingImageCount + inFlightImageCount
      )
    }
    queueAccepted += 1
    maxQueueBacklog = max(maxQueueBacklog, pendingCount)
    let shouldSchedule = !drainScheduled
    if shouldSchedule { drainScheduled = true }
    lock.unlock()

    if shouldSchedule {
      coreQueue.async { [weak self] in self?.drain(epoch: epoch) }
    }
    return true
  }

  // MARK: - 喂帧

  /// ARKit hot path: retain at most one bounded pixel-buffer reference and
  /// return. No downsample, native call, wait, or synchronous dispatch occurs.
  @discardableResult
  public func enqueue(frame: ARFrame) -> Bool {
    guard let lease = admissionGate.enter() else {
      outOfSessionImageOffers.increment()
      return false
    }
    defer { admissionGate.leave(lease) }
    guard lease.phase == .open else {
      if !imageStopRejections.increment(generation: lease.generation) {
        outOfSessionImageOffers.increment()
      }
      return false
    }
    let requestedCameraHz = lastStartRequest?.requestedCameraHz ?? 0
    guard requestedCameraHz.isFinite, requestedCameraHz > 0 else {
      return false
    }
    let cameraPeriod = 1.0 / requestedCameraHz
    if lastAdmittedCameraGeneration == lease.generation,
       frame.timestamp - lastAdmittedCameraTimestamp < cameraPeriod {
      cameraRateSampledOut += 1
      return false
    }
    lastAdmittedCameraGeneration = lease.generation
    lastAdmittedCameraTimestamp = frame.timestamp
    let tracking: (state: String, reason: String)
    switch frame.camera.trackingState {
    case .normal:
      tracking = ("normal", "none")
    case .notAvailable:
      tracking = ("notAvailable", "none")
    case .limited(let reason):
      let rawReason: String
      switch reason {
      case .initializing: rawReason = "initializing"
      case .excessiveMotion: rawReason = "excessiveMotion"
      case .insufficientFeatures: rawReason = "insufficientFeatures"
      case .relocalizing: rawReason = "relocalizing"
      @unknown default: rawReason = "unknown"
      }
      tracking = ("limited", rawReason)
    @unknown default:
      tracking = ("unknown", "unknown")
    }
    let pending = PendingFrame(
      pixelBuffer: frame.capturedImage,
      timestamp: frame.timestamp,
      arkitWorldFromCamera: frame.camera.transform,
      referenceTrackingState: tracking.state,
      referenceTrackingReason: tracking.reason,
      enqueuedAt: CACurrentMediaTime()
    )
    return admit(.image(pending, epoch: 0), lease: lease)
  }

  private func processFrameOnCore(
    _ pending: PendingFrame,
    generation: UInt32,
    downsampleFactor: Int,
    downsampleFormula: String
  ) -> ProcessingOutcome {
    let workerStartedAt = CACurrentMediaTime()
    defer {
      let workerMs = (CACurrentMediaTime() - workerStartedAt) * 1000.0
      lock.lock()
      workerFrameCount += 1
      workerFrameMsSum += workerMs
      lock.unlock()
    }
    let enqueueLatencyUs = (workerStartedAt - pending.enqueuedAt) * 1_000_000.0
    lock.lock()
    enqueueLatencyUsSum += enqueueLatencyUs
    lock.unlock()

    guard pending.timestamp.isFinite else {
      lock.lock(); imageFacts.reject(.invalidInput); lock.unlock()
      return .invalidInput
    }
    let pb = pending.pixelBuffer
    guard CVPixelBufferGetPlaneCount(pb) >= 1 else {
      lock.lock(); imageFacts.reject(.invalidInput); lock.unlock()
      return .invalidInput
    }

    let pixelLockStatus = CVPixelBufferLockBaseAddress(pb, .readOnly)
    guard pixelLockStatus == kCVReturnSuccess else {
      lock.lock(); imageFacts.reject(.invalidInput); lock.unlock()
      return .invalidInput
    }
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else {
      lock.lock(); imageFacts.reject(.invalidInput); lock.unlock()
      return .invalidInput
    }

    let w = CVPixelBufferGetWidthOfPlane(pb, 0)
    let h = CVPixelBufferGetHeightOfPlane(pb, 0)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)

    // 降采样。失败(尺寸不是倍数的整数倍)就**拒绝这一帧并计数**,
    // 不退回全分辨率 —— 那正是撑崩 App 的那条路。
    let srcPtr = base.assumingMemoryBound(to: UInt8.self)
    guard let (small, sw, _) =
            downsampleBox(
              src: srcPtr,
              srcW: w,
              srcH: h,
              srcStride: stride,
              downsampleFactor: downsampleFactor,
              downsampleFormula: downsampleFormula
            ) else {
      lock.lock(); imageFacts.reject(.invalidInput); lock.unlock()
      return .invalidInput
    }

    var rawState: Int32 = 0
    var rawPose = PWXrslamRawPose()
    let t0 = CACurrentMediaTime()
    let rc = PWXrslamTransportPushCameraAndRunRaw(
      small,
      pending.timestamp,
      Int32(sw),
      0,
      1,
      &rawState,
      &rawPose
    )
    let span = (CACurrentMediaTime() - t0) * 1000.0
    lock.lock()
    lastImageRc = rc
    if rc == 0 {
      imageFacts.submit()
      previousImageTimestamp = lastImageT
      lastImageT = pending.timestamp
    } else if rc == Int32(PW_XRSLAM_ERR_NON_MONOTONIC.rawValue) {
      imageFacts.reject(.nonMonotonic)
    } else {
      imageFacts.reject(.nativeReject)
    }
    lock.unlock()
    if rc == Int32(PW_XRSLAM_ERR_NON_MONOTONIC.rawValue) {
      return .nonMonotonic
    }
    guard rc == 0 else { return .nativeReject }
    lock.lock()
    runCalls += 1
    solveWallSum += span / 1000.0
    if feedWallStartedAtUptimeSeconds == 0 {
      feedWallStartedAtUptimeSeconds = t0
    }
    lock.unlock()
    updateHealthOnCore(frameMs: span, rawState: rawState)
    observePoseAndPrepareWire(
      frame: pending,
      generation: generation,
      rawState: rawState,
      rawPose: rawPose
    )
    return .success
  }

  /// 运输一个原始加速度计样本。此处只拷贝 G 单位原值;
  /// Dart 选择的单位/符号换算在 serial coreQueue 上执行。
  @discardableResult
  public func enqueue(acceleration sample: CMAccelerometerData) -> Bool {
    guard let lease = admissionGate.enter() else {
      outOfSessionAccelerationOffers.increment()
      return false
    }
    defer { admissionGate.leave(lease) }
    guard lease.phase == .open else {
      if !accelerationStopRejections.increment(generation: lease.generation) {
        outOfSessionAccelerationOffers.increment()
      }
      return false
    }
    let pending = PendingAcceleration(
      timestamp: sample.timestamp,
      x: sample.acceleration.x,
      y: sample.acceleration.y,
      z: sample.acceleration.z
    )
    return admit(.acceleration(pending, epoch: 0), lease: lease)
  }

  /// 运输一个原始陀螺仪样本,rad/s 原值不改。
  @discardableResult
  public func enqueue(gyroscope sample: CMGyroData) -> Bool {
    guard let lease = admissionGate.enter() else {
      outOfSessionGyroscopeOffers.increment()
      return false
    }
    defer { admissionGate.leave(lease) }
    guard lease.phase == .open else {
      if !gyroscopeStopRejections.increment(generation: lease.generation) {
        outOfSessionGyroscopeOffers.increment()
      }
      return false
    }
    let pending = PendingGyroscope(
      timestamp: sample.timestamp,
      x: sample.rotationRate.x,
      y: sample.rotationRate.y,
      z: sample.rotationRate.z
    )
    return admit(.gyroscope(pending, epoch: 0), lease: lease)
  }

  private func processAccelerationOnCore(
    _ pending: PendingAcceleration,
    accelerationScale: Double
  ) -> ProcessingOutcome {
    guard pending.timestamp.isFinite,
          pending.x.isFinite, pending.y.isFinite, pending.z.isFinite,
          accelerationScale.isFinite, accelerationScale != 0 else {
      lock.lock()
      accFacts.reject(.invalidInput)
      lock.unlock()
      return .invalidInput
    }
    let scaledX = pending.x * accelerationScale
    let scaledY = pending.y * accelerationScale
    let scaledZ = pending.z * accelerationScale
    let accRc = PWXrslamTransportPushAccelerationRaw(
      pending.timestamp,
      scaledX,
      scaledY,
      scaledZ
    )
    lock.lock()
    lastAccRc = accRc
    if accRc == 0 {
      accFacts.submit()
      accNativeSubmittedCount += 1
      lastImuT = pending.timestamp
    } else if accRc == Int32(PW_XRSLAM_ERR_NON_MONOTONIC.rawValue) {
      accFacts.reject(.nonMonotonic)
    } else {
      accFacts.reject(.nativeReject)
    }
    accSumX += scaledX
    accSumY += scaledY
    accSumZ += scaledZ
    lock.unlock()
    if accRc == Int32(PW_XRSLAM_ERR_NON_MONOTONIC.rawValue) {
      return .nonMonotonic
    }
    return accRc == 0 ? .success : .nativeReject
  }

  private func processGyroscopeOnCore(
    _ pending: PendingGyroscope
  ) -> ProcessingOutcome {
    guard pending.timestamp.isFinite,
          pending.x.isFinite, pending.y.isFinite, pending.z.isFinite else {
      lock.lock()
      gyroFacts.reject(.invalidInput)
      lock.unlock()
      return .invalidInput
    }
    let gyroRc = PWXrslamTransportPushGyroscopeRaw(
      pending.timestamp,
      pending.x,
      pending.y,
      pending.z
    )
    lock.lock()
    lastGyroRc = gyroRc
    if gyroRc == 0 {
      gyroFacts.submit()
      lastImuT = pending.timestamp
    } else if gyroRc == Int32(PW_XRSLAM_ERR_NON_MONOTONIC.rawValue) {
      gyroFacts.reject(.nonMonotonic)
    } else {
      gyroFacts.reject(.nativeReject)
    }
    lock.unlock()
    if gyroRc == Int32(PW_XRSLAM_ERR_NON_MONOTONIC.rawValue) {
      return .nonMonotonic
    }
    return gyroRc == 0 ? .success : .nativeReject
  }

  /// The only closure submitted for data work. At most one drain is scheduled;
  /// admission never schedules one closure per sensor sample.
  private func drain(epoch: Int) {
    while true {
      lock.lock()
      if pendingCount == 0 {
        pendingHead = 0
        pendingTail = 0
        if state == .stopping {
          lock.unlock()
          finishStopOnCoreQueue()
          return
        }
        drainScheduled = false
        cachedSnapshot = makeCoreSnapshotLocked()
        lock.unlock()
        return
      }

      guard var item = pendingWork[pendingHead] else {
        pendingHead = (pendingHead + 1) % Self.maxQueuedWork
        pendingCount -= 1
        terminalRejected += 1
        terminalInternal += 1
        invalidateRunLocked(reason: "internal_empty_queue_slot")
        cachedSnapshot = makeCoreSnapshotLocked()
        lock.unlock()
        continue
      }
      pendingWork[pendingHead] = nil
      pendingHead = (pendingHead + 1) % Self.maxQueuedWork
      pendingCount -= 1
      if item.isImage { pendingImageCount -= 1 }

      // Count the locally retained item before releasing the lock.
      inFlightCount = 1
      inFlightImageCount = item.isImage ? 1 : 0

      let selectedStartRequest = lastStartRequest
      let current = item.epoch == epoch &&
        item.epoch == sessionGeneration && state == .running && created &&
        selectedStartRequest != nil
      lock.unlock()

      guard current,
            let selectedStartRequest = selectedStartRequest else {
        let staleStream = item.stream
        // Release any CVPixelBuffer before publishing inFlightImageCount=0.
        // The logical ceiling and the actual ARC strong-reference ceiling are
        // therefore the same hard bound.
        item = .gyroscope(
          PendingGyroscope(timestamp: 0, x: 0, y: 0, z: 0),
          epoch: item.epoch
        )
        lock.lock()
        rejectSensorLocked(stream: staleStream, reason: .staleEpoch)
        terminalRejected += 1
        terminalStale += 1
        invalidateRunLocked(reason: SensorRejectionReason.staleEpoch.rawValue)
        inFlightCount = 0
        inFlightImageCount = 0
        cachedSnapshot = makeCoreSnapshotLocked()
        lock.unlock()
        continue
      }

      let outcome: ProcessingOutcome
      switch item {
      case .image(let frame, _):
        outcome = processFrameOnCore(
          frame,
          generation: UInt32(truncatingIfNeeded: item.epoch),
          downsampleFactor: selectedStartRequest.downsampleFactor,
          downsampleFormula: selectedStartRequest.downsampleFormula
        )
      case .acceleration(let sample, _):
        outcome = processAccelerationOnCore(
          sample,
          accelerationScale: selectedStartRequest.accelerationScale
        )
      case .gyroscope(let sample, _):
        outcome = processGyroscopeOnCore(sample)
      }

      // Drop the local PendingFrame (and its CVPixelBuffer) before admission
      // can observe an empty in-flight slot.
      item = .gyroscope(
        PendingGyroscope(timestamp: 0, x: 0, y: 0, z: 0),
        epoch: item.epoch
      )

      lock.lock()
      inFlightCount = 0
      inFlightImageCount = 0
      switch outcome {
      case .success:
        queueProcessedSuccess += 1
      case .invalidInput:
        terminalRejected += 1
        terminalInvalidInput += 1
        invalidateRunLocked(reason: SensorRejectionReason.invalidInput.rawValue)
      case .nonMonotonic:
        terminalRejected += 1
        terminalNonMonotonic += 1
        invalidateRunLocked(reason: SensorRejectionReason.nonMonotonic.rawValue)
      case .nativeReject:
        terminalRejected += 1
        terminalNativeReject += 1
        invalidateRunLocked(reason: SensorRejectionReason.nativeReject.rawValue)
      }
      // Work conservation is deliberately spelled out in native source and
      // independently recomputed by Dart from the wire snapshot.
      assert(
        queueAccepted == queueProcessedSuccess + droppedOnStop +
          terminalRejected + pendingCount + inFlightCount
      )
      cachedSnapshot = makeCoreSnapshotLocked()
      lock.unlock()
    }
  }

  private func finishStopOnCoreQueue() {
    lock.lock()
    let generation = sessionGeneration
    lock.unlock()
    admissionGate.sealWhenQuiescent(generation: generation) { [weak self] in
      guard let self else { return }
      self.coreQueue.async { [weak self] in
        self?.finishSealedStopOnCoreQueue(generation: generation)
      }
    }
  }

  private func finishSealedStopOnCoreQueue(generation: Int) {
    lock.lock()
    guard sessionGeneration == generation, state == .stopping else {
      lock.unlock()
      return
    }
    let shouldDestroy = created
    lock.unlock()
    var destroyReceipt = PWXrslamDestroyReceipt()
    let destroyRc: Int32
    if shouldDestroy {
      destroyRc = PWXrslamTransportDestroyWithReceipt(&destroyReceipt)
    } else {
      destroyRc = -2
    }

    var canceledStarts: [(Int32, Int) -> Void] = []
    var completedStops: [([String: Any]) -> Void] = []
    var restartRequest: StartRequest?
    var restartEpoch: Int?
    var terminalReceipt: [String: Any] = [:]
    lock.lock()
    nativeDestroyReceipt = [
      "nativeDestroyRc": Int(destroyRc),
      "nativeDestroyAcknowledged": Int(
        destroyReceipt.destroy_acknowledged
      ),
      "nativeLifecycleGeneration": destroyReceipt.lifecycle_generation,
      "nativeCameraSubmitted": destroyReceipt.camera_submitted,
      "nativeCameraRunCalls": destroyReceipt.camera_run_calls,
      "nativeAccelerationSubmitted": destroyReceipt.acceleration_submitted,
      "nativeGyroscopeSubmitted": destroyReceipt.gyroscope_submitted,
      "nativeRejectedInvalidArgument":
        destroyReceipt.rejected_invalid_argument,
      "nativeRejectedNonMonotonic":
        destroyReceipt.rejected_non_monotonic,
      "nativeRejectedNotRunning": destroyReceipt.rejected_not_running,
    ]
    if shouldDestroy &&
       (destroyRc != 0 || destroyReceipt.destroy_acknowledged != 1) {
      invalidateRunLocked(reason: "native_destroy_unacknowledged")
    }
    sealedImageLockContention = imageLockContention.seal(
      generation: generation
    )
    sealedAccelerationLockContention = accelerationLockContention.seal(
      generation: generation
    )
    sealedGyroscopeLockContention = gyroscopeLockContention.seal(
      generation: generation
    )
    sealedImageStopRejections = imageStopRejections.seal(
      generation: generation
    )
    sealedAccelerationStopRejections = accelerationStopRejections.seal(
      generation: generation
    )
    sealedGyroscopeStopRejections = gyroscopeStopRejections.seal(
      generation: generation
    )
    created = false
    inFlightCount = 0
    inFlightImageCount = 0
    drainScheduled = false
    // This executes on coreQueue after every in-flight native call. No later
    // observation from the stopped epoch can append after this terminal clear.
    poseObservationsDropped += poseObservations.count
    poseObservations.removeAll(keepingCapacity: true)
    if scratchCapacity > 0 {
      scratch?.update(repeating: 0, count: scratchCapacity)
    }
    scratch?.deallocate()
    scratch = nil
    scratchCapacity = 0
    vioWidth = 0
    vioHeight = 0
    if state != .stopped { transitionLocked(to: .stopped) }
    cachedSnapshot = makeCoreSnapshotLocked()
    canceledStarts = startCompletions + canceledStartCompletions
    startCompletions.removeAll(keepingCapacity: true)
    canceledStartCompletions.removeAll(keepingCapacity: true)
    completedStops = stopCompletions
    stopCompletions.removeAll(keepingCapacity: true)
    // A terminal receipt is emitted only after the fixed ring and the single
    // in-flight slot are empty. Conservation includes every admitted item.
    assert(pendingCount == 0 && inFlightCount == 0)
    assert(pendingImageCount == 0 && inFlightImageCount == 0)
    assert(
      queueAccepted == queueProcessedSuccess + droppedOnStop +
        terminalRejected
    )
    // Freeze the old generation before a queued restart resets any field.
    terminalReceipt = makeWireSnapshotLocked(includeRaw: false)
    if pendingRestart == nil { lastStartRequest = nil }
    if let pendingRestart {
      restartRequest = pendingRestart
      let completions = pendingRestartCompletions
      self.pendingRestart = nil
      pendingRestartCompletions.removeAll(keepingCapacity: true)
      let candidateEpoch = beginStartLocked(
        pendingRestart,
        completions: completions
      )
      if let candidateEpoch {
        restartEpoch = candidateEpoch
      } else {
        restartRequest = nil
        canceledStarts.append(contentsOf: completions)
      }
    }
    if let restartRequest, let restartEpoch {
      // Preserve Create -> optional racing stop/drain ordering, as in start().
      scheduleCreate(restartRequest, epoch: restartEpoch)
    }
    lock.unlock()

    DispatchQueue.main.async {
      for completion in canceledStarts { completion(0, generation) }
      for completion in completedStops { completion(terminalReceipt) }
    }
  }

  private func updateHealthOnCore(frameMs: Double, rawState: Int32) {
    lock.lock()
    let frameSequence = runCalls
    lock.unlock()
    let wire: [String: Any] = [
      "healthOverall": 0,
      "slamState": Int(rawState),
      "lastFrameMs": frameMs,
      "coreHealthAvailable": 0,
      "officialStateAvailable": 1,
      "coreFrameSeq": frameSequence,
    ]
    lock.lock()
    lastHealthRc = 0
    cachedHealth = wire
    lock.unlock()
  }

  private func finiteWireValue(_ value: Double) -> Any {
    value.isFinite ? value : NSNull()
  }

  /// Marshal one raw status observation for every processed image. No native
  /// availability class, initialization verdict, timestamp fallback, pacing,
  /// coordinate conversion, alignment, threshold, or error metric lives here.
  private func observePoseAndPrepareWire(
    frame: PendingFrame,
    generation: UInt32,
    rawState: Int32,
    rawPose: PWXrslamRawPose
  ) {
    lock.lock()
    let healthRc = lastHealthRc
    let healthWire = cachedHealth
    let rawPreviousImageTimestamp = previousImageTimestamp
    let rawSessionStartedAt = sessionStartedAt
    lock.unlock()
    let observedAt = CACurrentMediaTime()
    var observation: [String: Any] = [
      "rawStateCallCompleted": true,
      "rawCameraPoseCallCompleted": true,
      "rawPoseTimestamp": finiteWireValue(rawPose.timestamp),
      "sensorTimestamp": finiteWireValue(frame.timestamp),
      "xrslamPoseTimestamp": finiteWireValue(rawPose.timestamp),
      "rawHealthRc": Int(healthRc),
      "rawXrslamState": Int(rawState),
      "rawCoreFrameSeq": healthRc == 0
        ? (healthWire["coreFrameSeq"] ?? NSNull()) : NSNull(),
      "lastFrameMs": healthRc == 0
        ? (healthWire["lastFrameMs"] ?? NSNull()) : NSNull(),
      "previousImageTimestamp": finiteWireValue(rawPreviousImageTimestamp),
      "enqueuedAtUptimeSeconds": finiteWireValue(frame.enqueuedAt),
      "observedAtUptimeSeconds": finiteWireValue(observedAt),
      "sessionStartedAtUptimeSeconds": finiteWireValue(rawSessionStartedAt),
    ]

    let t = frame.arkitWorldFromCamera
    observation["referenceTrackingState"] = frame.referenceTrackingState
    observation["referenceTrackingReason"] = frame.referenceTrackingReason
    let referenceWorldFromCamera: [Double] = [
      Double(t.columns.0.x), Double(t.columns.0.y),
      Double(t.columns.0.z), Double(t.columns.0.w),
      Double(t.columns.1.x), Double(t.columns.1.y),
      Double(t.columns.1.z), Double(t.columns.1.w),
      Double(t.columns.2.x), Double(t.columns.2.y),
      Double(t.columns.2.z), Double(t.columns.2.w),
      Double(t.columns.3.x), Double(t.columns.3.y),
      Double(t.columns.3.z), Double(t.columns.3.w),
    ]
    observation["referenceWorldFromCamera"] = referenceWorldFromCamera
    // Exact XRSLAM iOS sample -> SceneKit camera convention:
    // position (-py, -px, -pz), rotation (-qy, -qx, -qz, qw).
    let xrslamWorldFromCamera: [String: Any] = [
      "qx": finiteWireValue(-rawPose.quaternion.1),
      "qy": finiteWireValue(-rawPose.quaternion.0),
      "qz": finiteWireValue(-rawPose.quaternion.2),
      "qw": finiteWireValue(rawPose.quaternion.3),
      "tx": finiteWireValue(-rawPose.translation.1),
      "ty": finiteWireValue(-rawPose.translation.0),
      "tz": finiteWireValue(-rawPose.translation.2),
    ]
    observation["xrslamPoseCoordinateConvention"] = "official_scene_kit_ios"
    observation["xrslamWorldFromCamera"] = xrslamWorldFromCamera

    lock.lock()
    poseObservationsOffered += 1
    guard state == .running,
          UInt32(truncatingIfNeeded: sessionGeneration) == generation else {
      poseObservationsDropped += 1
      lock.unlock()
      return
    }
    poseObservationSequence += 1
    observation["seq"] = poseObservationSequence
    poseObservations.append(observation)
    lock.unlock()
  }

  // MARK: - 读出

  private func stampedInfo(_ key: String) -> String {
    let raw = (Bundle.main.infoDictionary?[key] as? String ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return raw.isEmpty ? "UNSTAMPED" : raw
  }

  private func selectedDownsampleFactorLocked() -> Any {
    guard let factor = lastStartRequest?.downsampleFactor else {
      return NSNull()
    }
    return factor
  }

  private func selectedDownsampleFormulaLocked() -> Any {
    guard let formula = lastStartRequest?.downsampleFormula else {
      return NSNull()
    }
    return formula
  }

  private func runIdentityLocked() -> [String: Any] {
    let request = lastStartRequest
    return [
      "sessionId": request?.sessionId ?? "UNSTAMPED",
      "sessionEpoch": request?.sessionEpoch ?? -1,
      "epoch": sessionGeneration,
      "queueCapacity": Self.maxQueuedWork,
      "cameraCapacity": Self.maxRetainedImages,
      "poseObservationCapacity": "loss-intolerant-dynamic",
      "dropPolicy": "invalidate-on-overflow",
      "appVersion": stampedInfo("CFBundleShortVersionString"),
      "appBuild": stampedInfo("CFBundleVersion"),
      "diagnosticBuildId": stampedInfo("PWLiveCloudDiagnosticBuildId"),
      "productSourceManifestSha256": stampedInfo(
        "PWProductSourceManifestSHA256"
      ),
      "dartAotSha256": stampedInfo("PWDartAOTSHA256"),
      "nativeHostUuid": stampedInfo("PWNativeHostUUID"),
      "nativeFrameworkSha256": stampedInfo("PWOfficialSfmSHA256"),
      "xrslamSha256": stampedInfo("PWXrslamSHA256"),
      "xrslamUpstreamRevision": stampedInfo("PWXrslamUpstreamRevision"),
      "xrslamBuildPatchSha256": stampedInfo("PWXrslamBuildPatchSHA256"),
      "xrslamDestroyLifecyclePatchSha256": stampedInfo(
        "PWXrslamDestroyLifecyclePatchSHA256"
      ),
      "xrslamAlgorithmBranch": stampedInfo("PWXrslamAlgorithmBranch"),
      "xrslamIosEnabled": stampedInfo("PWXrslamIosEnabled"),
      "xrslamThreadingEnabled": stampedInfo("PWXrslamThreadingEnabled"),
      "xrslamCompileFlags": stampedInfo("PWXrslamCompileFlags"),
      "opencvUpstreamRevision": stampedInfo("PWOpenCVUpstreamRevision"),
      "opencvBuildPatchSha256": stampedInfo("PWOpenCVBuildPatchSHA256"),
      "opencvSha256": stampedInfo("PWOpenCVSHA256"),
      "ceresUpstreamRevision": stampedInfo("PWCeresUpstreamRevision"),
      "ceresSha256": stampedInfo("PWCeresSHA256"),
      "spdlogCompatibilityPatchSha256": stampedInfo(
        "PWSpdlogCompatibilityPatchSHA256"
      ),
      "effectiveConfigSha256": request?.effectiveConfigSha256 ?? "UNSTAMPED",
      "inputIdentitySha256": request?.inputIdentitySha256 ?? "UNSTAMPED",
      "downsampleFactor": selectedDownsampleFactorLocked(),
      "downsampleFormula": selectedDownsampleFormulaLocked(),
      "requestedCameraHz": request.map { $0.requestedCameraHz } ?? NSNull(),
      "cameraTimeOffsetSeconds": request.map {
        $0.cameraTimeOffsetSeconds
      } ?? NSNull(),
      "accelerationScale": request.map { $0.accelerationScale } ?? NSNull(),
      "requestedAccelerometerHz": request.map {
        $0.requestedAccelerometerHz
      } ?? NSNull(),
      "requestedGyroscopeHz": request.map {
        $0.requestedGyroscopeHz
      } ?? NSNull(),
    ]
  }

  private func makeCoreSnapshotLocked() -> [String: Any] {
    var out: [String: Any] = [
      "schema": "pw.vio.shadow-native/6",
      "xrslamSha256": stampedInfo("PWXrslamSHA256"),
      "running": state == .running && created,
      "sessionGeneration": sessionGeneration,
      "state": state.rawValue,
      "runCalls": runCalls,
      "lastImageRc": Int(lastImageRc),
      "lastAccRc": Int(lastAccRc),
      "lastGyroRc": Int(lastGyroRc),
      "lastImageTimestamp": lastImageT,
      "previousImageTimestamp": previousImageTimestamp,
      "lastImuTimestamp": lastImuT,
      "accSumX": accSumX,
      "accSumY": accSumY,
      "accSumZ": accSumZ,
      // Compatibility field retains its wire spelling; its value is only a
      // successful submission to the void XRSLAM C API, not core acceptance.
      "accNativeAcceptedCount": accNativeSubmittedCount,
      "accNativeSubmittedCount": accNativeSubmittedCount,
      "vioDownsampleFactor": selectedDownsampleFactorLocked(),
      "vioDownsampleFormula": selectedDownsampleFormulaLocked(),
      "vioWidth": vioWidth,
      "vioHeight": vioHeight,
      "workerFrameCount": workerFrameCount,
      "workerFrameMsSum": workerFrameMsSum,
      "enqueueLatencyUsSum": enqueueLatencyUsSum,
      "solveWallSecondsSum": solveWallSum,
      "feedWallStartedAtUptimeSeconds": feedWallStartedAtUptimeSeconds,
      "snapshotAtUptimeSeconds": CACurrentMediaTime(),
      "healthRc": Int(lastHealthRc),
      "poseObservationsOffered": poseObservationsOffered,
      "poseObservationsDropped": poseObservationsDropped,
      "cameraRateSampledOut": cameraRateSampledOut,
    ]
    for (key, value) in cachedHealth { out[key] = value }
    return out
  }

  private func generationCount(
    _ counter: GenerationCounter,
    sealed: Int?
  ) -> Int {
    sealed ?? counter.value(generation: sessionGeneration) ?? 0
  }

  private func makeWireSnapshotLocked(includeRaw: Bool) -> [String: Any] {
    var out = makeCoreSnapshotLocked()
    let imageLock = generationCount(
      imageLockContention, sealed: sealedImageLockContention
    )
    let accelerationLock = generationCount(
      accelerationLockContention,
      sealed: sealedAccelerationLockContention
    )
    let gyroscopeLock = generationCount(
      gyroscopeLockContention,
      sealed: sealedGyroscopeLockContention
    )
    let imageStop = generationCount(
      imageStopRejections, sealed: sealedImageStopRejections
    )
    let accelerationStop = generationCount(
      accelerationStopRejections,
      sealed: sealedAccelerationStopRejections
    )
    let gyroscopeStop = generationCount(
      gyroscopeStopRejections,
      sealed: sealedGyroscopeStopRejections
    )
    let images = imageFacts.wire(
      lockContention: imageLock,
      stopRejections: imageStop
    )
    let acc = accFacts.wire(
      lockContention: accelerationLock,
      stopRejections: accelerationStop
    )
    let gyro = gyroFacts.wire(
      lockContention: gyroscopeLock,
      stopRejections: gyroscopeStop
    )
    var invalidationReasons = runInvalidationReasons
    let lockContentionTotal = imageLock + accelerationLock + gyroscopeLock
    if lockContentionTotal > 0 {
      invalidationReasons[
        SensorRejectionReason.lockContention.rawValue,
        default: 0
      ] += lockContentionTotal
    }
    let lateAfterSealTotal = imageStop + accelerationStop + gyroscopeStop
    if lateAfterSealTotal > 0 {
      invalidationReasons[
        SensorRejectionReason.lateAfterSeal.rawValue,
        default: 0
      ] += lateAfterSealTotal
    }
    // [pw] 2026-09-14 锁争用不再计入「输入丢弃」,依据是本功能自己的 spec:
    // openspec/changes/add-xrslam-bounded-shadow-promotion-gates/specs/
    //   xrslam-shadow-promotion/spec.md:37
    //   "ordinary ledger-lock contention is **not** classified as an input drop"
    // 计数与上报一个字没动(wire() 仍照常汇总、reasons 仍带 lock_contention),
    // 改的只是**分类**:它不再让整场影子运行失效。
    let transportValid = !shadowRunInvalidated && lateAfterSealTotal == 0
    out["identity"] = runIdentityLocked()
    for (key, value) in nativeDestroyReceipt { out[key] = value }
    out["queueAdmitted"] = queueAccepted
    out["queueAccepted"] = queueAccepted
    out["queueSubmitted"] = queueProcessedSuccess
    out["queueProcessedSuccess"] = queueProcessedSuccess
    out["droppedOnStop"] = droppedOnStop
    out["terminalRejected"] = terminalRejected
    out["queueBacklog"] = pendingCount
    out["queueInFlight"] = inFlightCount
    out["retainedImageCount"] = pendingImageCount + inFlightImageCount
    out["maxRetainedImageCount"] = maxRetainedImageCount
    out["maxQueueBacklog"] = maxQueueBacklog
    out["transportValid"] = transportValid
    out["shadowRunInvalidated"] = !transportValid
    out["runInvalidationReasons"] = invalidationReasons
    out["workConserved"] = queueAccepted == queueProcessedSuccess +
      droppedOnStop + terminalRejected + pendingCount + inFlightCount
    out["terminalReceiptComplete"] = state == .stopped &&
      pendingCount == 0 && inFlightCount == 0 &&
      pendingImageCount == 0 && inFlightImageCount == 0
    out["shutdownDrops"] = shutdownDrops
    out["stateTransitions"] = stateTransitions
    out["poseObservationsOffered"] = poseObservationsOffered
    out["poseObservationsDropped"] = poseObservationsDropped
    out["poseObservations"] = includeRaw ? poseObservations : []
    out["imagesAttempted"] = images.attempted
    out["imagesSubmitted"] = images.submitted
    out["imagesAccepted"] = images.submitted
    out["imagesRejected"] = images.rejected
    out["accAttempted"] = acc.attempted
    out["accSubmitted"] = acc.submitted
    out["accAccepted"] = acc.submitted
    out["accRejected"] = acc.rejected
    out["gyroAttempted"] = gyro.attempted
    out["gyroSubmitted"] = gyro.submitted
    out["gyroAccepted"] = gyro.submitted
    out["gyroRejected"] = gyro.rejected
    out["acceptedCompatibilitySemantics"] = "submitted_to_void_c_api"
    // [pw] 2026-09-14 同上:overflow 只数真正的容量溢出(queue_full / camera_full),
    // 不再把锁争用混进来。lockContentionTotal 仍在 reasons 与 invalidationReasons
    // 里逐项可见,只是不再当作丢弃计入这个闸用的总数。
    out["shadowOverflowDrops"] = overflowBase
    out["outOfSessionImageOffers"] = outOfSessionImageOffers.value
    out["outOfSessionAccelerationOffers"] =
      outOfSessionAccelerationOffers.value
    out["outOfSessionGyroscopeOffers"] = outOfSessionGyroscopeOffers.value
    out["rejectionReasons"] = [
      "images": images.reasons,
      "acc": acc.reasons,
      "gyro": gyro.reasons,
      "workTerminal": [
        "stale_epoch": terminalStale,
        "invalid_input": terminalInvalidInput,
        "non_monotonic": terminalNonMonotonic,
        "native_reject": terminalNativeReject,
        "internal": terminalInternal,
      ],
      "workDroppedOnStop": ["dropped_on_stop": droppedOnStop],
    ]
    return out
  }

  /// Snapshot is cached data only. No XRSLAM API is called from Flutter/UI.
  public func snapshot() -> [String: Any] {
    lock.lock()
    let out = makeWireSnapshotLocked(includeRaw: true)
    // Deliver-and-clear: raw absolute poses exist only in this reply. Dart
    // consumes them in memory and persists aggregate status/residuals only.
    poseObservations.removeAll(keepingCapacity: true)
    lock.unlock()
    return out
  }
}
