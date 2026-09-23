// PwVioSlamFeeder.swift — 把 ARKit 帧与 CoreMotion 样本喂给 XRSLAM。
//
// 为什么在原生侧喂:ARFrame 本来就在原生。从 Dart 喂意味着每帧把像素缓冲跨
// FFI 边界拷一次 —— 1920×1440 灰度 = 2.7 MB/帧,30fps 就是 83 MB/s 的桥接拷贝。
// 原生入口把亮度平面写进预分配 640×480 灰度池,worker 只消费池槽;
// Dart 侧只传配置、读位姿和健康状态,避免把整帧像素穿过平台通道。
//
// 跨端边界:
//   ① Swift 只抄录平台原始时间戳/跟踪枚举,不判时基、可用性或质量；
//   ② 每个成功 Push 的图像固定 RunOneFrame 一次,不在 Swift 写频率策略；
//   ③ 回调只尝试有界入队，绝不等算法；压力不能反向控制拍照。
//      任何溢出都显式计数并使整场影子运行失效，不伪造完整输入。
//
// [pw 2026-09-23] 逐帧内参:每帧把 `ARFrame.camera.intrinsics` 换算到**真正推给
// 引擎的 640×480 灰度**上再随帧推(`PWXrslamTransportPushCameraAndRunRawWithIntrinsics`)。
// 🔴 ARKit 的 K 参照 `ARCamera.imageResolution`(1920×1440),而这里喂的是 box-d
// 降采样后的图 ⇒ 原值直推焦距就错 d 倍。换算只走传输层那一个 C 函数
// `PWXrslamTransportScaleIntrinsicsForBoxNxN`(fx/d、fy/d、(c+0.5)/d−0.5),与离线
// 回放证据用的转换器 `pwvi_to_euroc.py:224-226` 逐位一致(传输层单测用真录制钉死;
// 转换器 = arloopbench tools/pwvi_to_euroc.py,sha256 3c96ab11…)。
// 像素中心约定出处:ARCamera.h:54-63(iPhoneOS26.2.sdk)"The origin is at the
// center of the upper-left pixel."。官方在线文档:
//   https://developer.apple.com/documentation/arkit/arcamera/intrinsics(单位是像素)
//   https://developer.apple.com/documentation/arkit/arcamera/imageresolution
//     (K 所参照的「captured camera image」宽高,像素)
// 在线页对主点原点只写到「图像左上角」,没有细到像素中心还是像素角;这里按 SDK
// 头文件那句更具体的说法走,也就是转换器用的那套约定。开关与 ON 臂共用 `PwPerFrameIntrinsicsSwitch`
// (`-PWPerFrameIntrinsics off|on`,定义在 PwXrslamLive.swift)。

import ARKit
import CoreMotion
import Darwin
import Foundation
import simd

@available(iOS 11.0, *)
public final class PwVioSlamFeeder {
  public static let shared = PwVioSlamFeeder()
  private init() {}

  /// ARFrame itself never escapes the production callback. Its full-resolution
  /// CVPixelBuffer may escape only inside one of these generation-bound permits;
  /// release is exactly-once even when a caller never consumes the permit.
  public final class FrameIngressPermit {
    public let generation: Int
    public let sequence: UInt64
    public let timestamp: TimeInterval
    fileprivate let pixelBuffer: CVPixelBuffer
    fileprivate let cameraTransform: simd_float4x4
    /// [pw 2026-09-23] 这一帧的 `ARCamera.intrinsics` 与它参照的 `imageResolution`。
    fileprivate let cameraIntrinsics: simd_float3x3
    fileprivate let cameraImageResolution: CGSize
    fileprivate let referenceTrackingState: String
    fileprivate let referenceTrackingReason: String
    fileprivate let graySlot: Int
    fileprivate let grayBuffer: UnsafeMutablePointer<UInt8>

    private var state: Int32 = 0 // 0=offered, 1=consuming, 2=released
    private let releaseBody: (
      _ abandoned: Bool,
      _ reservationsTransferred: Bool
    ) -> Void

    fileprivate init(
      generation: UInt32,
      sequence: UInt64,
      timestamp: TimeInterval,
      pixelBuffer: CVPixelBuffer,
      cameraTransform: simd_float4x4,
      cameraIntrinsics: simd_float3x3,
      cameraImageResolution: CGSize,
      referenceTrackingState: String,
      referenceTrackingReason: String,
      graySlot: Int,
      grayBuffer: UnsafeMutablePointer<UInt8>,
      release: @escaping (
        _ abandoned: Bool,
        _ reservationsTransferred: Bool
      ) -> Void
    ) {
      self.generation = Int(generation)
      self.sequence = sequence
      self.timestamp = timestamp
      self.pixelBuffer = pixelBuffer
      self.cameraTransform = cameraTransform
      self.cameraIntrinsics = cameraIntrinsics
      self.cameraImageResolution = cameraImageResolution
      self.referenceTrackingState = referenceTrackingState
      self.referenceTrackingReason = referenceTrackingReason
      self.graySlot = graySlot
      self.grayBuffer = grayBuffer
      releaseBody = release
    }

    fileprivate func claim() -> Bool {
      OSAtomicCompareAndSwap32Barrier(0, 1, &state)
    }

    fileprivate func finish(reservationsTransferred: Bool) {
      if OSAtomicCompareAndSwap32Barrier(1, 2, &state) {
        releaseBody(false, reservationsTransferred)
      }
    }

    deinit {
      if OSAtomicCompareAndSwap32Barrier(0, 2, &state) {
        releaseBody(true, false)
      } else if OSAtomicCompareAndSwap32Barrier(1, 2, &state) {
        releaseBody(false, false)
      }
    }
  }

  private enum ShadowState: String {
    case stopped, starting, running, stopping
  }

  private struct PendingFrame {
    let graySlot: Int
    let grayBuffer: UnsafeMutablePointer<UInt8>
    let grayWidth: Int
    let grayHeight: Int
    let grayStride: Int
    let timestamp: Double
    let ingressSequence: UInt64
    let arkitWorldFromCamera: simd_float4x4
    // Raw ARKit enum facts only. Dart owns the cross-platform usable/rejected
    // decision and all quality policy.
    let referenceTrackingState: String
    let referenceTrackingReason: String
    let enqueuedAt: CFTimeInterval
    /// [pw 2026-09-23] 已换算到本帧灰度像素上的 fx fy cx cy;`nil` = 本帧不推逐帧 K。
    let grayIntrinsics: [Double]?
    /// 不推的原因(`IntrinsicsHostReason`);推的时候是 `.attach`。
    let intrinsicsHostReason: IntrinsicsHostReason
  }

  /// [pw 2026-09-23] 宿主侧决定本帧推不推逐帧 K 的原因。传输层自己拒收的
  /// 另记在它的 C 账本(`PWXrslamIntrinsicsTrace.rejected_invalid`)里。
  private enum IntrinsicsHostReason: String {
    case attach = "attach"
    case switchOff = "switch_off"
    case resolutionMismatch = "image_resolution_mismatch"
    case scaleRejected = "scale_rejected"
  }

  /// Fixed 30-slot gray carrier. A slot is reserved with lock-free CAS before
  /// a CVPixelBuffer can escape the ARSession callback, then transferred to the
  /// FIFO work item or returned by the permit's exactly-once release path.
  private final class GrayFramePool {
    struct Reservation {
      let slot: Int
      let buffer: UnsafeMutablePointer<UInt8>
      let activeCount: Int
    }

    private let slotCount: Int
    private var storage: UnsafeMutablePointer<UInt8>?
    private let slotByteCount: Int
    private let validMask: UInt64
    private var occupiedBits: Int64 = 0

    init(slotCount: Int, slotByteCount: Int) {
      precondition(slotCount > 0 && slotCount <= 63 && slotByteCount > 0)
      self.slotCount = slotCount
      self.slotByteCount = slotByteCount
      validMask = (UInt64(1) << UInt64(slotCount)) - 1
      storage = nil
    }

    deinit { storage?.deallocate() }

    /// Runs on coreQueue before admission is opened. This keeps the one-time
    /// 9.2 MB allocation and zero-fill off ARSession's production callback.
    func prepare() {
      guard storage == nil else {
        assert(activeCount == 0)
        return
      }
      let prepared = UnsafeMutablePointer<UInt8>.allocate(
        capacity: slotCount * slotByteCount
      )
      prepared.initialize(repeating: 0, count: slotCount * slotByteCount)
      storage = prepared
    }

    func tryAcquire() -> Reservation? {
      guard let storage else { return nil }
      while true {
        let oldRaw = OSAtomicAdd64Barrier(0, &occupiedBits)
        let old = UInt64(bitPattern: oldRaw)
        let available = (~old) & validMask
        guard available != 0 else { return nil }
        let slot = available.trailingZeroBitCount
        let next = old | (UInt64(1) << UInt64(slot))
        if OSAtomicCompareAndSwap64Barrier(
          oldRaw,
          Int64(bitPattern: next),
          &occupiedBits
        ) {
          return Reservation(
            slot: slot,
            buffer: storage + slot * slotByteCount,
            activeCount: next.nonzeroBitCount
          )
        }
      }
    }

    func release(_ slot: Int) {
      let bit = UInt64(1) << UInt64(slot)
      while true {
        let oldRaw = OSAtomicAdd64Barrier(0, &occupiedBits)
        let old = UInt64(bitPattern: oldRaw)
        assert(old & bit != 0)
        let next = old & ~bit
        if OSAtomicCompareAndSwap64Barrier(
          oldRaw,
          Int64(bitPattern: next),
          &occupiedBits
        ) { return }
      }
    }

    var activeCount: Int {
      UInt64(
        bitPattern: OSAtomicAdd64Barrier(0, &occupiedBits)
      ).nonzeroBitCount
    }
  }

  /// Fixed storage with FIFO wire order. Caller owns synchronization.
  private struct PoseObservationRing {
    private var storage: [[String: Any]?]
    private var head = 0
    private(set) var count = 0

    init(capacity: Int) {
      precondition(capacity > 0)
      storage = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ observation: [String: Any]) -> Bool {
      guard count < storage.count else { return false }
      storage[(head + count) % storage.count] = observation
      count += 1
      return true
    }

    func values() -> [[String: Any]] {
      (0..<count).compactMap { storage[(head + $0) % storage.count] }
    }

    mutating func removeAll() {
      for index in storage.indices { storage[index] = nil }
      head = 0
      count = 0
    }
  }

  private struct PendingAcceleration {
    let timestamp: Double
    let ingressSequence: UInt64
    let x: Double
    let y: Double
    let z: Double
  }

  private struct PendingGyroscope {
    let timestamp: Double
    let ingressSequence: UInt64
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

    var ingressSequence: UInt64 {
      switch self {
      case .image(let frame, _): return frame.ingressSequence
      case .acceleration(let sample, _): return sample.ingressSequence
      case .gyroscope(let sample, _): return sample.ingressSequence
      }
    }
  }

  private static let maxStateTransitions = 16
  private static let maxQueuedWork = 256
  /// This is the only bound that counts full-resolution ARFrame references.
  /// Gray pool slots below are 640x480 copies and have a separate capacity.
  private static let maxOutstandingCameraIngress = 2
  // One official 30 Hz camera envelope. The shared sensor ingress queue owns
  // admission ordering; this bound absorbs one second without sampling out or
  // replacing accepted camera input.
  private static let maxRetainedImages = 30
  private static let grayWidth = 640
  private static let grayHeight = 480
  private static let grayFrameBytes = grayWidth * grayHeight
  private static let maxPoseObservations = 128
  // Transport-only bound. Every processed image offers one raw pose/health
  // observation; Dart owns polling cadence and every semantic classification.

  private let lock = NSLock()
  private let grayFramePool = GrayFramePool(
    slotCount: PwVioSlamFeeder.maxRetainedImages,
    slotByteCount: PwVioSlamFeeder.grayFrameBytes
  )
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
  private var nativeStartLifecycleGeneration: UInt64 = 0
  private var ingressClosed = false
  private var terminalIngressSequence: UInt64 = 0
  private var terminalIngressCompleted: UInt64 = 0

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
      incrementAndValue(generation: generation) != nil
    }

    func incrementAndValue(generation: UInt32) -> UInt64? {
      while true {
        let old = Self.load(&packed)
        guard UInt32(truncatingIfNeeded: old >> 32) == generation else {
          return nil
        }
        let count = old & Self.countMask
        guard count < Self.countMask else { return nil }
        let next = (UInt64(generation) << 32) | (count + 1)
        if OSAtomicCompareAndSwap64Barrier(
          Int64(bitPattern: old),
          Int64(bitPattern: next),
          &packed
        ) { return count + 1 }
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

  private final class AtomicLimiter {
    private let capacity: Int64
    private var active: Int64 = 0

    init(capacity: Int) {
      precondition(capacity > 0)
      self.capacity = Int64(capacity)
    }

    func tryAcquire() -> Bool {
      while true {
        let old = OSAtomicAdd64Barrier(0, &active)
        guard old < capacity else { return false }
        if OSAtomicCompareAndSwap64Barrier(old, old + 1, &active) {
          return true
        }
      }
    }

    func release() {
      let next = OSAtomicDecrement64Barrier(&active)
      assert(next >= 0)
    }

    var value: Int { Int(OSAtomicAdd64Barrier(0, &active)) }
  }

  private final class AdmissionGate {
    enum Phase: UInt64 { case open = 0, rejecting = 1, sealed = 2 }
    struct Entry { let generation: UInt32 }
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
    func prepare(generation: Int) -> Bool {
      let next = (UInt64(UInt32(truncatingIfNeeded: generation)) << 32) |
        (Phase.sealed.rawValue << Self.phaseShift)
      while true {
        let old = load()
        // A new session must never erase a callback lease from the previous
        // generation. Correct lifecycle closure seals that generation first;
        // a violation fails the start safely instead of corrupting accounting.
        guard old & Self.activeMask == 0,
              (old >> Self.phaseShift) & 0x3 == Phase.sealed.rawValue else {
          return false
        }
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

    func open(generation: Int) -> Bool {
      let expected = UInt32(truncatingIfNeeded: generation)
      while true {
        let old = load()
        guard UInt32(truncatingIfNeeded: old >> 32) == expected,
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

    func enter(expectedGeneration: Int? = nil) -> Entry? {
      while true {
        let old = load()
        let phaseRaw = (old >> Self.phaseShift) & 0x3
        guard phaseRaw == Phase.open.rawValue else {
          return nil
        }
        let generation = UInt32(truncatingIfNeeded: old >> 32)
        if let expectedGeneration,
           generation != UInt32(truncatingIfNeeded: expectedGeneration) {
          return nil
        }
        let active = old & Self.activeMask
        guard active < Self.activeMask else { return nil }
        let next = old + 1
        if OSAtomicCompareAndSwap64Barrier(
          Int64(bitPattern: old), Int64(bitPattern: next), &packed
        ) {
          return Entry(generation: generation)
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
      beginRejecting(generation: generation)
      let bits = load()
      guard UInt32(truncatingIfNeeded: bits >> 32) ==
              UInt32(truncatingIfNeeded: generation) else {
        completion()
        return
      }
      if (bits >> Self.phaseShift) & 0x3 == Phase.sealed.rawValue {
        completion()
        return
      }
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
  private let cameraIngressLimiter = AtomicLimiter(
    capacity: PwVioSlamFeeder.maxOutstandingCameraIngress
  )
  private let workSlotLimiter = AtomicLimiter(
    capacity: PwVioSlamFeeder.maxQueuedWork
  )
  private let ingressSequence = GenerationCounter()
  private let ingressCompleted = GenerationCounter()
  private let cameraIngressCapacityRejections = GenerationCounter()
  private let cameraFullFrameCapacityRejections = GenerationCounter()
  private let cameraWorkRingCapacityRejections = GenerationCounter()
  private let cameraGrayPoolCapacityRejections = GenerationCounter()
  private let accelerationWorkCapacityRejections = GenerationCounter()
  private let gyroscopeWorkCapacityRejections = GenerationCounter()
  private let abandonedCameraIngress = GenerationCounter()
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

  private enum CameraCapacityRejection {
    case fullFrame, workRing, grayPool
  }

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

    func wire(
      lockContention: Int,
      stopRejections: Int,
      queueFullRejections: Int = 0
    ) ->
      (attempted: Int, submitted: Int, rejected: Int, reasons: [String: Int]) {
      var wireReasons = Dictionary(uniqueKeysWithValues: reasons.map {
        ($0.key.rawValue, $0.value)
      })
      wireReasons[SensorRejectionReason.lockContention.rawValue, default: 0] +=
        lockContention
      wireReasons[SensorRejectionReason.lateAfterSeal.rawValue, default: 0] +=
        stopRejections
      wireReasons[SensorRejectionReason.queueFull.rawValue, default: 0] +=
        queueFullRejections
      return (
        attempted + lockContention + stopRejections + queueFullRejections,
        submitted,
        rejected + lockContention + stopRejections + queueFullRejections,
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
  private var vioWidth = 0, vioHeight = 0

  /// XRSLAM 是全局单例(C API 没有句柄参数),全部入口只允许 coreQueue 调用。
  private var lastImageT: Double = 0
  private var lastImuT: Double = 0
  private var accSumX: Double = 0
  private var accSumY: Double = 0
  private var accSumZ: Double = 0
  private var accNativeSubmittedCount = 0
  private var runCalls = 0
  private var lastImageRc: Int32 = 0
  // [pw 2026-09-23] 逐帧内参:宿主侧原因计数 + 最近一次 C 账本快照(计数在 C 里)。
  private var intrinsicsSwitchOffFrames = 0
  private var intrinsicsResolutionMismatchFrames = 0
  private var intrinsicsScaleRejectedFrames = 0
  private var lastIntrinsicsTrace = PWXrslamIntrinsicsTrace()
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
  private var poseObservations = PoseObservationRing(
    capacity: PwVioSlamFeeder.maxPoseObservations
  )

  private var lastStartRequest: StartRequest?

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
    assert(cameraIngressLimiter.value == 0)
    assert(workSlotLimiter.value == 0)
    assert(grayFramePool.activeCount == 0)
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
    nativeStartLifecycleGeneration = 0
    ingressClosed = false
    terminalIngressSequence = 0
    terminalIngressCompleted = 0
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
    ingressSequence.beginGeneration(generation)
    ingressCompleted.beginGeneration(generation)
    cameraIngressCapacityRejections.beginGeneration(generation)
    cameraFullFrameCapacityRejections.beginGeneration(generation)
    cameraWorkRingCapacityRejections.beginGeneration(generation)
    cameraGrayPoolCapacityRejections.beginGeneration(generation)
    accelerationWorkCapacityRejections.beginGeneration(generation)
    gyroscopeWorkCapacityRejections.beginGeneration(generation)
    abandonedCameraIngress.beginGeneration(generation)
    lastImageT = 0
    lastImuT = 0
    accSumX = 0
    accSumY = 0
    accSumZ = 0
    accNativeSubmittedCount = 0
    runCalls = 0
    lastImageRc = 0
    intrinsicsSwitchOffFrames = 0
    intrinsicsResolutionMismatchFrames = 0
    intrinsicsScaleRejectedFrames = 0
    lastIntrinsicsTrace = PWXrslamIntrinsicsTrace()
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
    poseObservations.removeAll()
    cachedSnapshot = makeCoreSnapshotLocked()
  }

  private func beginStartLocked(
    _ request: StartRequest,
    completions: [(Int32, Int) -> Void]
  ) -> Int? {
    let epoch = sessionGeneration + 1
    // Prepare a sealed generation first. Camera/IMU admission is published
    // only by the successful Create completion on coreQueue.
    guard admissionGate.prepare(generation: epoch) else { return nil }
    sessionGeneration = epoch
    resetSessionMetricsLocked(generation: epoch)
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
      var startCounters = PWXrslamTransportCounters()
      let startCountersRc: Int32 = rc == 1
        ? PWXrslamTransportGetCounters(&startCounters) : -1
      if rc == 1 { self.grayFramePool.prepare() }

      var completed: [(Int32, Int) -> Void] = []
      var destroyOrphan = false
      var shouldCloseFailedCreate = false
      self.lock.lock()
      if self.sessionGeneration == epoch {
        self.created = (rc == 1)
        self.nativeStartLifecycleGeneration = startCountersRc == 0
          ? startCounters.lifecycle_generation : 0
        if self.state == .starting, self.created {
          if startCountersRc == 0,
             startCounters.lifecycle_generation > 0 {
            if self.admissionGate.open(generation: epoch) {
              self.transitionLocked(to: .running)
              completed = self.startCompletions
              self.startCompletions.removeAll(keepingCapacity: true)
            } else {
              self.invalidateRunLocked(reason: "ingress_open_failed")
              self.transitionLocked(to: .stopping)
              shouldCloseFailedCreate = true
            }
          } else {
            // Create without a readable lifecycle receipt cannot publish
            // admission: there would be nothing exact for Destroy to match.
            self.invalidateRunLocked(reason: "native_start_receipt_unavailable")
            self.transitionLocked(to: .stopping)
            shouldCloseFailedCreate = true
          }
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
        self.closeIngressForStop(generation: epoch)
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

  /// Stop seals new admission, drains and publishes every already-admitted
  /// item in timestamp order, and queues Destroy last. It never waits/syncs.
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
    let epoch = sessionGeneration
    lock.unlock()
    closeIngressForStop(generation: epoch)
  }

  public var isRunning: Bool {
    lock.lock(); defer { lock.unlock() }
    return state == .running && created
  }

  public var runningGeneration: Int? {
    lock.lock(); defer { lock.unlock() }
    return state == .running && created ? sessionGeneration : nil
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

  private func rejectPreparedImage(
    reason: SensorRejectionReason,
    overflow: Bool = false
  ) {
    lock.lock()
    imageFacts.offer()
    imageFacts.reject(reason)
    if overflow { overflowBase += 1 }
    invalidateRunLocked(reason: reason.rawValue)
    lock.unlock()
  }

  private func recordCameraCapacityRejection(
    _ reason: CameraCapacityRejection,
    generation: UInt32
  ) {
    let aggregateRecorded = cameraIngressCapacityRejections.increment(
      generation: generation
    )
    let reasonRecorded: Bool
    switch reason {
    case .fullFrame:
      reasonRecorded = cameraFullFrameCapacityRejections.increment(
        generation: generation
      )
    case .workRing:
      reasonRecorded = cameraWorkRingCapacityRejections.increment(
        generation: generation
      )
    case .grayPool:
      reasonRecorded = cameraGrayPoolCapacityRejections.increment(
        generation: generation
      )
    }
    if !aggregateRecorded || !reasonRecorded {
      outOfSessionImageOffers.increment()
    }
  }

  private func recordImuWorkCapacityRejection(
    stream: SensorStream,
    generation: UInt32
  ) {
    let recorded: Bool
    switch stream {
    case .acceleration:
      recorded = accelerationWorkCapacityRejections.increment(
        generation: generation
      )
    case .gyroscope:
      recorded = gyroscopeWorkCapacityRejections.increment(
        generation: generation
      )
    case .image:
      recorded = false
    }
    if !recorded { noteOutOfSessionOffer(stream: stream) }
  }

  /// Loss-intolerant bounded admission. Camera and IMU producers already run
  /// on PwVioSensorIngress's one serial queue, so lock contention is not an
  /// input-rejection policy. The lock only publishes the ring mutation to the
  /// core consumer/snapshot reader; capacity remains explicit and bounded.
  private func admit(
    _ unscopedWork: PendingWork,
    generation offeredGeneration: UInt32
  ) -> Bool {
    lock.lock()
    offerSensorLocked(stream: unscopedWork.stream)
    guard (state == .running || (state == .stopping && !ingressClosed)),
          created else {
      rejectUnadmittedLocked(
        stream: unscopedWork.stream,
        reason: .notRunning
      )
      lock.unlock()
      return false
    }
    let generation = UInt32(truncatingIfNeeded: sessionGeneration)
    guard offeredGeneration == generation else {
      rejectUnadmittedLocked(
        stream: unscopedWork.stream,
        reason: .staleEpoch
      )
      lock.unlock()
      return false
    }
    // `ingressSequence` is immutable offer evidence, not a scheduling key.
    // Camera permits are issued in ARKit's callback before their closure is
    // appended to PwVioSensorIngress; an already-queued IMU operation can thus
    // legitimately be admitted first with a numerically later offer sequence.
    // The shared serial ingress queue is the sole work-order authority.
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

  /// O(1) production-callback boundary. Before retaining the pixel buffer this
  /// atomically reserves the generation lease, full-frame carrier, shared FIFO
  /// work slot, and gray-pool slot. The caller may move only the returned permit
  /// across a queue; a rejected offer never creates an escaping ARFrame closure.
  public func tryOfferFrame(frame: ARFrame) -> FrameIngressPermit? {
    guard frame.timestamp.isFinite else {
      outOfSessionImageOffers.increment()
      return nil
    }
    guard let lease = admissionGate.enter() else {
      outOfSessionImageOffers.increment()
      return nil
    }
    guard cameraIngressLimiter.tryAcquire() else {
      recordCameraCapacityRejection(.fullFrame, generation: lease.generation)
      admissionGate.leave(lease)
      return nil
    }
    guard workSlotLimiter.tryAcquire() else {
      recordCameraCapacityRejection(.workRing, generation: lease.generation)
      cameraIngressLimiter.release()
      admissionGate.leave(lease)
      return nil
    }
    guard let grayReservation = grayFramePool.tryAcquire() else {
      recordCameraCapacityRejection(.grayPool, generation: lease.generation)
      workSlotLimiter.release()
      cameraIngressLimiter.release()
      admissionGate.leave(lease)
      return nil
    }
    guard let sequence = ingressSequence.incrementAndValue(
      generation: lease.generation
    ) else {
      grayFramePool.release(grayReservation.slot)
      workSlotLimiter.release()
      cameraIngressLimiter.release()
      admissionGate.leave(lease)
      outOfSessionImageOffers.increment()
      return nil
    }
    let pixelBuffer = frame.capturedImage
    let cameraTransform = frame.camera.transform
    let cameraIntrinsics = frame.camera.intrinsics
    let cameraImageResolution = frame.camera.imageResolution
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
    let gate = admissionGate
    let cameraLimiter = cameraIngressLimiter
    let workLimiter = workSlotLimiter
    let grayPool = grayFramePool
    let completed = ingressCompleted
    let abandoned = abandonedCameraIngress
    return FrameIngressPermit(
      generation: lease.generation,
      sequence: sequence,
      timestamp: frame.timestamp,
      pixelBuffer: pixelBuffer,
      cameraTransform: cameraTransform,
      cameraIntrinsics: cameraIntrinsics,
      cameraImageResolution: cameraImageResolution,
      referenceTrackingState: tracking.state,
      referenceTrackingReason: tracking.reason,
      graySlot: grayReservation.slot,
      grayBuffer: grayReservation.buffer
    ) { wasAbandoned, reservationsTransferred in
      if wasAbandoned {
        _ = abandoned.increment(generation: lease.generation)
      }
      if !reservationsTransferred {
        grayPool.release(grayReservation.slot)
        workLimiter.release()
      }
      _ = completed.increment(generation: lease.generation)
      cameraLimiter.release()
      gate.leave(lease)
    }
  }

  /// Compatibility for non-production callers. Production ARKit must acquire
  /// the permit before it creates its escaping closure and call `consume`.
  @discardableResult
  public func enqueue(frame: ARFrame) -> Bool {
    guard let permit = tryOfferFrame(frame: frame) else {
      return false
    }
    return consume(permit: permit)
  }

  /// Shadow-ingress work. This may copy/downsample, so it belongs only on
  /// PwVioSensorIngress after production has already returned from its callback.
  @discardableResult
  public func consume(permit: FrameIngressPermit) -> Bool {
    guard permit.claim() else { return false }
    var reservationsTransferred = false
    defer {
      permit.finish(
        reservationsTransferred: reservationsTransferred
      )
    }
    let generation = UInt32(truncatingIfNeeded: permit.generation)
    guard permit.timestamp.isFinite else {
      rejectPreparedImage(reason: .invalidInput)
      return false
    }

    let factor: Int
    lock.lock()
    guard UInt32(truncatingIfNeeded: sessionGeneration) == generation,
          (state == .running || (state == .stopping && !ingressClosed)),
          created,
          let request = lastStartRequest,
          request.downsampleFormula == Self.downsampleFormulaBoxNxnHalfUpV1,
          request.downsampleFactor > 0 else {
      lock.unlock()
      rejectPreparedImage(reason: .staleEpoch)
      return false
    }
    factor = request.downsampleFactor
    lock.unlock()

    let pixelBuffer = permit.pixelBuffer
    guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 1 else {
      rejectPreparedImage(reason: .invalidInput)
      return false
    }
    let pixelLockStatus = CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
    guard pixelLockStatus == kCVReturnSuccess else {
      rejectPreparedImage(reason: .invalidInput)
      return false
    }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let source = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else {
      rejectPreparedImage(reason: .invalidInput)
      return false
    }
    let sourceWidth = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
    let sourceHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
    let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
    var outputWidth: Int32 = 0
    var outputHeight: Int32 = 0
    let prepareRc = PWXrslamTransportPrepareGrayBoxNxN(
      source.assumingMemoryBound(to: UInt8.self),
      Int32(sourceWidth),
      Int32(sourceHeight),
      Int32(sourceStride),
      Int32(factor),
      permit.grayBuffer,
      Int32(Self.grayFrameBytes),
      &outputWidth,
      &outputHeight
    )
    guard prepareRc == 0,
          outputWidth == Int32(Self.grayWidth),
          outputHeight == Int32(Self.grayHeight) else {
      rejectPreparedImage(reason: .invalidInput)
      return false
    }
    // [pw 2026-09-23] 逐帧内参(文件头)。ARKit 的 K 参照 imageResolution;只有
    //   它恰好等于被降采样的亮度平面尺寸时换算才成立,否则不推、按原因计数。
    //   换算不在 Swift 里写算术,只调传输层那一个 C 函数。
    var grayIntrinsics: [Double]? = nil
    var intrinsicsHostReason = IntrinsicsHostReason.attach
    if !PwPerFrameIntrinsicsSwitch.resolved.enabled {
      intrinsicsHostReason = .switchOff
    } else if permit.cameraImageResolution.width != CGFloat(sourceWidth) ||
                permit.cameraImageResolution.height != CGFloat(sourceHeight) {
      intrinsicsHostReason = .resolutionMismatch
    } else {
      let k = permit.cameraIntrinsics
      let source: [Double] = [
        Double(k.columns.0.x), Double(k.columns.1.y),
        Double(k.columns.2.x), Double(k.columns.2.y),
      ]
      var scaled = [Double](repeating: 0, count: 4)
      let scaleRc = source.withUnsafeBufferPointer { src in
        scaled.withUnsafeMutableBufferPointer { dst in
          PWXrslamTransportScaleIntrinsicsForBoxNxN(
            src.baseAddress, Int32(factor), dst.baseAddress)
        }
      }
      if scaleRc == 0 {
        grayIntrinsics = scaled
      } else {
        intrinsicsHostReason = .scaleRejected
      }
    }
    let pending = PendingFrame(
      graySlot: permit.graySlot,
      grayBuffer: permit.grayBuffer,
      grayWidth: Int(outputWidth),
      grayHeight: Int(outputHeight),
      grayStride: Int(outputWidth),
      timestamp: permit.timestamp,
      ingressSequence: permit.sequence,
      arkitWorldFromCamera: permit.cameraTransform,
      referenceTrackingState: permit.referenceTrackingState,
      referenceTrackingReason: permit.referenceTrackingReason,
      enqueuedAt: CACurrentMediaTime(),
      grayIntrinsics: grayIntrinsics,
      intrinsicsHostReason: intrinsicsHostReason
    )
    let admitted = admit(
      .image(pending, epoch: 0),
      generation: generation
    )
    reservationsTransferred = admitted
    if admitted { publishVioShape(width: Int(outputWidth), height: Int(outputHeight)) }
    return admitted
  }

  private func publishVioShape(width: Int, height: Int) {
    lock.lock()
    vioWidth = width
    vioHeight = height
    lock.unlock()
  }

  private func processFrameOnCore(
    _ pending: PendingFrame,
    generation: UInt32,
    downsampleFactor: Int,
    downsampleFormula: String
  ) -> ProcessingOutcome {
    defer { grayFramePool.release(pending.graySlot) }
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
    guard downsampleFormula == Self.downsampleFormulaBoxNxnHalfUpV1,
          downsampleFactor > 0,
          pending.grayWidth == Self.grayWidth,
          pending.grayHeight == Self.grayHeight,
          pending.grayStride == Self.grayWidth else {
      lock.lock(); imageFacts.reject(.invalidInput); lock.unlock()
      return .invalidInput
    }

    var rawState: Int32 = 0
    var rawPose = PWXrslamRawPose()
    let t0 = CACurrentMediaTime()
    let rc: Int32
    if let k = pending.grayIntrinsics {
      rc = k.withUnsafeBufferPointer { kp in
        PWXrslamTransportPushCameraAndRunRawWithIntrinsics(
          pending.grayBuffer,
          pending.timestamp,
          Int32(pending.grayStride),
          0,
          1,
          kp.baseAddress,
          &rawState,
          &rawPose
        )
      }
    } else {
      rc = PWXrslamTransportPushCameraAndRunRaw(
        pending.grayBuffer,
        pending.timestamp,
        Int32(pending.grayStride),
        0,
        1,
        &rawState,
        &rawPose
      )
    }
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
    // [pw 2026-09-23] 逐帧内参的 C 账本(本帧;coreQueue 串行、只有这里推相机)。
    var intrinsicsTrace = PWXrslamIntrinsicsTrace()
    let intrinsicsTraceRc = PWXrslamTransportGetIntrinsicsTrace(&intrinsicsTrace)
    lock.lock()
    switch pending.intrinsicsHostReason {
    case .attach: break
    case .switchOff: intrinsicsSwitchOffFrames += 1
    case .resolutionMismatch: intrinsicsResolutionMismatchFrames += 1
    case .scaleRejected: intrinsicsScaleRejectedFrames += 1
    }
    if intrinsicsTraceRc == 0 { lastIntrinsicsTrace = intrinsicsTrace }
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
      rawPose: rawPose,
      intrinsicsTrace: intrinsicsTraceRc == 0 ? intrinsicsTrace : nil
    )
    return .success
  }

  /// 运输一个原始加速度计样本。此处只拷贝 G 单位原值;
  /// Dart 选择的单位/符号换算在 serial coreQueue 上执行。
  @discardableResult
  public func enqueue(
    acceleration sample: CMAccelerometerData,
    expectedGeneration: Int? = nil
  ) -> Bool {
    guard let lease = admissionGate.enter(
      expectedGeneration: expectedGeneration
    ) else {
      outOfSessionAccelerationOffers.increment()
      return false
    }
    guard workSlotLimiter.tryAcquire() else {
      recordImuWorkCapacityRejection(
        stream: .acceleration,
        generation: lease.generation
      )
      admissionGate.leave(lease)
      return false
    }
    guard let sequence = ingressSequence.incrementAndValue(
      generation: lease.generation
    ) else {
      workSlotLimiter.release()
      admissionGate.leave(lease)
      outOfSessionAccelerationOffers.increment()
      return false
    }
    var reservationsTransferred = false
    defer {
      if !reservationsTransferred { workSlotLimiter.release() }
      _ = ingressCompleted.increment(generation: lease.generation)
      admissionGate.leave(lease)
    }
    let pending = PendingAcceleration(
      timestamp: sample.timestamp,
      ingressSequence: sequence,
      x: sample.acceleration.x,
      y: sample.acceleration.y,
      z: sample.acceleration.z
    )
    let admitted = admit(
      .acceleration(pending, epoch: 0),
      generation: lease.generation
    )
    reservationsTransferred = admitted
    return admitted
  }

  /// 运输一个原始陀螺仪样本,rad/s 原值不改。
  @discardableResult
  public func enqueue(
    gyroscope sample: CMGyroData,
    expectedGeneration: Int? = nil
  ) -> Bool {
    guard let lease = admissionGate.enter(
      expectedGeneration: expectedGeneration
    ) else {
      outOfSessionGyroscopeOffers.increment()
      return false
    }
    guard workSlotLimiter.tryAcquire() else {
      recordImuWorkCapacityRejection(
        stream: .gyroscope,
        generation: lease.generation
      )
      admissionGate.leave(lease)
      return false
    }
    guard let sequence = ingressSequence.incrementAndValue(
      generation: lease.generation
    ) else {
      workSlotLimiter.release()
      admissionGate.leave(lease)
      outOfSessionGyroscopeOffers.increment()
      return false
    }
    var reservationsTransferred = false
    defer {
      if !reservationsTransferred { workSlotLimiter.release() }
      _ = ingressCompleted.increment(generation: lease.generation)
      admissionGate.leave(lease)
    }
    let pending = PendingGyroscope(
      timestamp: sample.timestamp,
      ingressSequence: sequence,
      x: sample.rotationRate.x,
      y: sample.rotationRate.y,
      z: sample.rotationRate.z
    )
    let admitted = admit(
      .gyroscope(pending, epoch: 0),
      generation: lease.generation
    )
    reservationsTransferred = admitted
    return admitted
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
          guard ingressClosed else {
            drainScheduled = false
            cachedSnapshot = makeCoreSnapshotLocked()
            lock.unlock()
            return
          }
          lock.unlock()
          finishSealedStopOnCoreQueue(generation: epoch)
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
        workSlotLimiter.release()
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
        item.epoch == sessionGeneration &&
        (state == .running || state == .stopping) && created &&
        selectedStartRequest != nil
      lock.unlock()

      guard current,
            let selectedStartRequest = selectedStartRequest else {
        let staleStream = item.stream
        if case .image(let staleFrame, _) = item {
          grayFramePool.release(staleFrame.graySlot)
        }
        // Release the copied gray slot before publishing inFlightImageCount=0.
        item = .gyroscope(
          PendingGyroscope(
            timestamp: 0, ingressSequence: item.ingressSequence,
            x: 0, y: 0, z: 0
          ),
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
        workSlotLimiter.release()
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
        PendingGyroscope(
          timestamp: 0, ingressSequence: item.ingressSequence,
          x: 0, y: 0, z: 0
        ),
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
      workSlotLimiter.release()
    }
  }

  /// The close marker is armed after producer admission flips to rejecting.
  /// Its completion means every already-issued permit has either been consumed
  /// or abandoned. Only then may coreQueue observe the terminal boundary.
  private func closeIngressForStop(generation: Int) {
    admissionGate.sealWhenQuiescent(generation: generation) { [weak self] in
      guard let self else { return }
      self.coreQueue.async { [weak self] in
        guard let self else { return }
        self.lock.lock()
        guard self.sessionGeneration == generation,
              self.state == .stopping else {
          self.lock.unlock()
          return
        }
        self.ingressClosed = true
        self.terminalIngressSequence = UInt64(
          self.ingressSequence.value(generation: generation) ?? 0
        )
        self.terminalIngressCompleted = UInt64(
          self.ingressCompleted.value(generation: generation) ?? 0
        )
        self.drainScheduled = true
        self.lock.unlock()
        self.drain(epoch: generation)
      }
    }
  }

  private func finishSealedStopOnCoreQueue(generation: Int) {
    lock.lock()
    guard sessionGeneration == generation, state == .stopping,
          ingressClosed else {
      lock.unlock()
      return
    }
    let terminalReservationsReleased =
      terminalIngressSequence == terminalIngressCompleted &&
      cameraIngressLimiter.value == 0 &&
      workSlotLimiter.value == 0 &&
      grayFramePool.activeCount == 0
    if !terminalReservationsReleased {
      invalidateRunLocked(reason: "ingress_close_incomplete")
    }
    assert(terminalReservationsReleased)
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
      "receiptAvailable": shouldDestroy,
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
    if shouldDestroy &&
       (nativeStartLifecycleGeneration == 0 ||
        destroyReceipt.lifecycle_generation != nativeStartLifecycleGeneration) {
      invalidateRunLocked(reason: "native_lifecycle_generation_mismatch")
    }
    if shouldDestroy &&
       (destroyReceipt.camera_submitted != UInt64(imageFacts.submitted) ||
        destroyReceipt.camera_run_calls != UInt64(runCalls) ||
        destroyReceipt.acceleration_submitted != UInt64(accFacts.submitted) ||
        destroyReceipt.gyroscope_submitted != UInt64(gyroFacts.submitted)) {
      invalidateRunLocked(reason: "native_counter_mismatch")
    }
    if !terminalReservationsReleased {
      invalidateRunLocked(reason: "ingress_close_incomplete")
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
    // This executes on coreQueue after every admitted native call. Freeze all
    // unpolled poses into the terminal receipt before clearing their ring.
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
    terminalReceipt = makeWireSnapshotLocked(includeRaw: true)
    poseObservations.removeAll()
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
    var counters = PWXrslamTransportCounters()
    let countersRc = PWXrslamTransportGetCounters(&counters)
    let countersAvailable = countersRc == 0
    let submittedImuSamples = countersAvailable
      ? Int(counters.acceleration_submitted + counters.gyroscope_submitted)
      : 0
    let wire: [String: Any] = [
      "slamState": Int(rawState),
      "lastFrameMs": frameMs,
      "coreHealthAvailable": countersAvailable,
      "coreHealthSource": "transport_core_counters",
      "coreLifecycleGeneration": Int(counters.lifecycle_generation),
      "coreImuSamples": submittedImuSamples,
      "coreCameraSubmitted": Int(counters.camera_submitted),
      "coreCameraRunCalls": Int(counters.camera_run_calls),
      "coreAccelerationSubmitted": Int(counters.acceleration_submitted),
      "coreGyroscopeSubmitted": Int(counters.gyroscope_submitted),
      "coreRejectedInvalidArgument": Int(counters.rejected_invalid_argument),
      "coreRejectedNonMonotonic": Int(counters.rejected_non_monotonic),
      "coreRejectedNotRunning": Int(counters.rejected_not_running),
      "officialStateAvailable": 1,
      "coreFrameSeq": frameSequence,
    ]
    lock.lock()
    lastHealthRc = countersRc
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
    rawPose: PWXrslamRawPose,
    intrinsicsTrace: PWXrslamIntrinsicsTrace?
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
    // [pw 2026-09-23] 本帧用的是哪份 K(逐帧 / yaml 常量),原始事实照抄 C 账本。
    //   per_frame               = 推了逐帧 K 且引擎回读(XRSLAM_INFO_INTRINSICS)逐位一致
    //   per_frame_not_consumed  = 推了但引擎回读不一致(链的核不认这条扩展 ⇒ 实际是常量)
    //   config                  = 没推(原因见 intrinsicsHostReason / 传输层拒收)
    if let t = intrinsicsTrace {
      let attached = t.last_per_frame_attached == 1
      observation["intrinsicsSource"] = attached
        ? (t.last_engine_report_matches == 1 ? "per_frame" : "per_frame_not_consumed")
        : "config"
      observation["intrinsicsHostReason"] = frame.intrinsicsHostReason.rawValue
      observation["intrinsicsGrayFxFyCxCy"] = attached ? [
        t.last_attached_fxfycxcy.0, t.last_attached_fxfycxcy.1,
        t.last_attached_fxfycxcy.2, t.last_attached_fxfycxcy.3,
      ] : NSNull()
    } else {
      observation["intrinsicsSource"] = NSNull()
      observation["intrinsicsHostReason"] = frame.intrinsicsHostReason.rawValue
      observation["intrinsicsGrayFxFyCxCy"] = NSNull()
    }

    lock.lock()
    poseObservationsOffered += 1
    guard (state == .running || state == .stopping),
          UInt32(truncatingIfNeeded: sessionGeneration) == generation else {
      poseObservationsDropped += 1
      lock.unlock()
      return
    }
    poseObservationSequence += 1
    observation["seq"] = poseObservationSequence
    guard poseObservations.append(observation) else {
      poseObservationsDropped += 1
      invalidateRunLocked(reason: "pose_observation_full")
      lock.unlock()
      return
    }
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
      "fullFrameIngressCapacity": Self.maxOutstandingCameraIngress,
      "cameraAdmissionPolicy": "bounded-permit-no-cadence-sampling",
      "poseObservationCapacity": Self.maxPoseObservations,
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
      "xrslamZeroInlierMaskPatchSha256": stampedInfo(
        "PWXrslamZeroInlierMaskPatchSHA256"
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

  /// [pw 2026-09-23] 逐帧内参这一场的账。带 C 账本字样的四个数来自
  /// `PWXrslamTransportGetIntrinsicsTrace`,不在 Swift 合成。
  private func perFrameIntrinsicsWireLocked() -> [String: Any] {
    let sw = PwPerFrameIntrinsicsSwitch.resolved
    let t = lastIntrinsicsTrace
    return [
      "schema": "pw.vio.per-frame-intrinsics/1",
      "switchEnabled": sw.enabled,
      "switchSource": sw.source.rawValue,
      "switchLaunchArgument": "-\(PwPerFrameIntrinsicsSwitch.kLaunchArgumentKey)",
      "rescale": "PWXrslamTransportScaleIntrinsicsForBoxNxN",
      "transportAttached": t.attached,
      "transportNotAttached": t.not_attached,
      "transportRejectedInvalid": t.rejected_invalid,
      "transportEngineReportMatched": t.engine_report_matched,
      "hostSwitchOff": intrinsicsSwitchOffFrames,
      "hostImageResolutionMismatch": intrinsicsResolutionMismatchFrames,
      "hostScaleRejected": intrinsicsScaleRejectedFrames,
    ]
  }

  private func makeCoreSnapshotLocked() -> [String: Any] {
    var out: [String: Any] = [
      "schema": "pw.vio.shadow-native/6",
      "xrslamSha256": stampedInfo("PWXrslamSHA256"),
      "running": state == .running && created,
      "sessionGeneration": sessionGeneration,
      "nativeStartLifecycleGeneration": nativeStartLifecycleGeneration,
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
      "perFrameIntrinsics": perFrameIntrinsicsWireLocked(),
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
    let accelerationWorkFull = accelerationWorkCapacityRejections.value(
      generation: sessionGeneration
    ) ?? 0
    let gyroscopeWorkFull = gyroscopeWorkCapacityRejections.value(
      generation: sessionGeneration
    ) ?? 0
    let images = imageFacts.wire(
      lockContention: imageLock,
      stopRejections: imageStop
    )
    let acc = accFacts.wire(
      lockContention: accelerationLock,
      stopRejections: accelerationStop,
      queueFullRejections: accelerationWorkFull
    )
    let gyro = gyroFacts.wire(
      lockContention: gyroscopeLock,
      stopRejections: gyroscopeStop,
      queueFullRejections: gyroscopeWorkFull
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
    let imuWorkFull = accelerationWorkFull + gyroscopeWorkFull
    if imuWorkFull > 0 {
      invalidationReasons[
        SensorRejectionReason.queueFull.rawValue,
        default: 0
      ] += imuWorkFull
    }
    let cameraIngressFull = cameraIngressCapacityRejections.value(
      generation: sessionGeneration
    ) ?? 0
    let cameraFullFrame = cameraFullFrameCapacityRejections.value(
      generation: sessionGeneration
    ) ?? 0
    let cameraWorkRing = cameraWorkRingCapacityRejections.value(
      generation: sessionGeneration
    ) ?? 0
    let cameraGrayPool = cameraGrayPoolCapacityRejections.value(
      generation: sessionGeneration
    ) ?? 0
    let cameraIngressAbandoned = abandonedCameraIngress.value(
      generation: sessionGeneration
    ) ?? 0
    if cameraIngressFull > 0 {
      invalidationReasons["camera_ingress_full", default: 0] += cameraIngressFull
    }
    if cameraIngressAbandoned > 0 {
      invalidationReasons["camera_ingress_abandoned", default: 0] +=
        cameraIngressAbandoned
    }
    let transportValid = !shadowRunInvalidated &&
      lockContentionTotal == 0 && lateAfterSealTotal == 0 &&
      imuWorkFull == 0 && cameraIngressFull == 0 &&
      cameraIngressAbandoned == 0
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
    let currentIngressSequence = UInt64(
      ingressSequence.value(generation: sessionGeneration) ?? 0
    )
    let currentIngressCompleted = UInt64(
      ingressCompleted.value(generation: sessionGeneration) ?? 0
    )
    out["ingressClosed"] = ingressClosed
    out["ingressOffered"] = state == .stopped
      ? terminalIngressSequence : currentIngressSequence
    out["ingressCompleted"] = state == .stopped
      ? terminalIngressCompleted : currentIngressCompleted
    out["terminalIngressSequence"] = terminalIngressSequence
    out["outstandingCameraIngress"] = cameraIngressLimiter.value
    out["outstandingWorkReservations"] = workSlotLimiter.value
    out["reservedGrayFrameSlots"] = grayFramePool.activeCount
    out["cameraIngressCapacityRejections"] = cameraIngressFull
    out["cameraIngressCapacityReasons"] = [
      "full_frame": cameraFullFrame,
      "work_ring": cameraWorkRing,
      "gray_pool": cameraGrayPool,
    ]
    out["abandonedCameraIngress"] = cameraIngressAbandoned
    out["workConserved"] = queueAccepted == queueProcessedSuccess +
      droppedOnStop + terminalRejected + pendingCount + inFlightCount
    out["terminalReceiptComplete"] = state == .stopped &&
      ingressClosed && terminalIngressSequence == terminalIngressCompleted &&
      cameraIngressLimiter.value == 0 &&
      workSlotLimiter.value == 0 && grayFramePool.activeCount == 0 &&
      pendingCount == 0 && inFlightCount == 0 &&
      pendingImageCount == 0 && inFlightImageCount == 0
    out["shutdownDrops"] = shutdownDrops
    out["stateTransitions"] = stateTransitions
    out["poseObservationsOffered"] = poseObservationsOffered
    out["poseObservationsDropped"] = poseObservationsDropped
    out["poseObservations"] = includeRaw ? poseObservations.values() : []
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
    out["shadowOverflowDrops"] = overflowBase + lockContentionTotal +
      imuWorkFull + cameraIngressFull
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
    poseObservations.removeAll()
    lock.unlock()
    return out
  }
}
