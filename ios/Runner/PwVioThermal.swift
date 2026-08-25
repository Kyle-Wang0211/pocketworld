// PwVioThermal.swift — iOS 侧热/降频信号采集(**只上报,不判档**)。
//
// 档位折叠与调度决策全部在 Dart 侧 lib/vio/thermal/ 里做,两端共用同一份。
// 平台代码一旦开始自己判档,就会重演 XRSLAM_IOS 那个宏的老问题:
// 两端跑结构性不同的算法。所以这里**只做三件事**:读原始值、听通知、上报。
//
// 已核对 iPhoneOS26.2.sdk 头文件的 API(不是凭记忆写的):
//   * ProcessInfo.thermalState                     — NSProcessInfo.h,iOS 11.0+
//     NSProcessInfoThermalState: Nominal=0 Fair=1 Serious=2 Critical=3
//     文档明确:不支持/未知时返回 Nominal。
//   * ProcessInfo.thermalStateDidChangeNotification — Foundation.apinotes 已确认
//     由 NSProcessInfoThermalStateDidChangeNotification 重命名而来
//   * ProcessInfo.isLowPowerModeEnabled            — iOS 9.0+
//   * AVCaptureSession.wasInterruptedNotification  — NS_SWIFT_NAME 已确认
//   * AVCaptureSession.interruptionEndedNotification — NS_SWIFT_NAME 已确认
//   * AVCaptureSessionInterruptionReasonKey        — iOS 9.0+
//   * ...InterruptionReasonVideoDeviceNotAvailableDueToSystemPressure = 5,iOS 11.1+
//     ⚠️ 这个 reason **是断流,不是降帧** —— 相机会彻底停,一帧都没有。
//   * AVCaptureSessionInterruptionSystemPressureStateKey — 仅在 reason==5 时存在
//   * AVCaptureDevice.systemPressureState          — iOS 11.1+
//     Level 是不透明字符串常量;Factors 位掩码:
//     SystemTemperature=1<<0 PeakPower=1<<1 DepthModuleTemperature=1<<2
//     CameraTemperature=1<<3 (iOS 17+)
//
// Apple 对 thermalState == .critical 的官方建议原文:
//   "Consider stopping use of camera and other peripherals."
// 我们**不擅自停采集**(会丢数据,违反铁律),而是把建议原样上报给 Dart,
// 由采集层先把 spool 落盘再收尾。

import AVFoundation
import Foundation

#if canImport(Flutter)
import Flutter
#endif

// MARK: - 通道名(与 lib/vio/thermal/vio_thermal_channel.dart 必须一致)

public enum PwVioThermalIdentifiers {
  public static let methodChannel = "pocketworld_vio_thermal"
  public static let eventChannel = "pocketworld_vio_thermal/events"
}

// MARK: - 单调时钟 / 线程 CPU 时间

/// 自启动的单调微秒(不含睡眠)。绝不用墙钟 —— 用户改时间会把曲线毁掉。
@inline(__always)
public func pwVioMonotonicMicros() -> Int64 {
  return Int64(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1_000)
}

/// **当前线程**已消耗的 CPU 时间(毫秒)。读失败返回 -1。
///
/// ⚠️ 陷阱:必须在**真正跑 VIO 的那个线程上**调用。跨线程调用拿到的是
/// 调用者线程的时间,数字看着正常但完全没有意义 —— 这种静默错误正是
/// 我们要靠它抓的那类问题的伪装。
public func pwVioThreadCpuMillis() -> Double {
  var info = thread_basic_info()
  var count = mach_msg_type_number_t(
    MemoryLayout<thread_basic_info_data_t>.size / MemoryLayout<integer_t>.size
  )
  let thread = mach_thread_self()
  defer { mach_port_deallocate(mach_task_self_, thread) }

  let kr: kern_return_t = withUnsafeMutablePointer(to: &info) { ptr in
    ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
      thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), intPtr, &count)
    }
  }
  guard kr == KERN_SUCCESS else { return -1 }

  let userMs =
    Double(info.user_time.seconds) * 1000.0
    + Double(info.user_time.microseconds) / 1000.0
  let sysMs =
    Double(info.system_time.seconds) * 1000.0
    + Double(info.system_time.microseconds) / 1000.0
  return userMs + sysMs
}

// MARK: - 快照

public enum PwVioCameraStreamState: String {
  case running
  case interrupted
  case stopped
  case unknown
}

/// 上报给 Dart 的一条快照。字段名与 decodeThermalSignal() 逐字对应。
public struct PwVioThermalSnapshot {
  public var tsUs: Int64
  public var rawStatus: Int
  public var statusReadable: Bool
  public var lowPowerMode: Bool
  public var cameraStream: PwVioCameraStreamState
  public var interruptionReason: Int?
  public var systemPressureLevel: String?
  public var systemPressureFactors: Int?
  public var activeProcessorCount: Int

  public func asDictionary() -> [String: Any] {
    var d: [String: Any] = [
      "schema": 1,
      "platform": "ios",
      "tsUs": NSNumber(value: tsUs),
      "rawStatus": rawStatus,
      "statusReadable": statusReadable,
      "lowPowerMode": lowPowerMode,
      "cameraStream": cameraStream.rawValue,
      "activeProcessorCount": activeProcessorCount,
    ]
    // headroom 是 Android 专有:iOS 上**不放这个 key**,Dart 侧解成 null。
    // 放 0 会被读成"完全没热压力",那是彻头彻尾的谎报。
    if let r = interruptionReason { d["interruptionReason"] = r }
    if let l = systemPressureLevel { d["systemPressureLevel"] = l }
    if let f = systemPressureFactors { d["systemPressureFactors"] = f }
    return d
  }
}

// MARK: - 采集器(不依赖 Flutter,可单独测)

/// 监听热状态与相机打断,产出 [PwVioThermalSnapshot]。
public final class PwVioThermalMonitor: NSObject {

  /// 每产生一条新快照时回调(主队列)。
  public var onSnapshot: ((PwVioThermalSnapshot) -> Void)?

  private var cameraStream: PwVioCameraStreamState = .unknown
  private var lastInterruptionReason: Int?
  private var lastPressureLevel: String?
  private var lastPressureFactors: Int?
  private var observing = false

  /// 弱持有采集会话,用于在快照时补读 systemPressureState。
  /// 用轮询而不是 KVO:每 10s 一次的节拍 + 打断通知已经覆盖了所有关键时刻,
  /// 少一个观察者就少一类生命周期 bug。
  private weak var session: AVCaptureSession?
  private weak var videoDevice: AVCaptureDevice?

  public func attach(session: AVCaptureSession?, videoDevice: AVCaptureDevice?) {
    self.session = session
    self.videoDevice = videoDevice
    if let s = session {
      cameraStream = s.isRunning ? .running : .stopped
    }
  }

  public func start() {
    guard !observing else { return }
    observing = true
    let nc = NotificationCenter.default
    nc.addObserver(
      self,
      selector: #selector(thermalStateChanged),
      name: ProcessInfo.thermalStateDidChangeNotification,
      object: nil)
    nc.addObserver(
      self,
      selector: #selector(sessionWasInterrupted(_:)),
      name: AVCaptureSession.wasInterruptedNotification,
      object: nil)
    nc.addObserver(
      self,
      selector: #selector(sessionInterruptionEnded(_:)),
      name: AVCaptureSession.interruptionEndedNotification,
      object: nil)
    emit()
  }

  public func stop() {
    guard observing else { return }
    observing = false
    NotificationCenter.default.removeObserver(self)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  @objc private func thermalStateChanged() {
    emit()
  }

  @objc private func sessionWasInterrupted(_ note: Notification) {
    cameraStream = .interrupted
    if let n = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber {
      lastInterruptionReason = n.intValue
    } else {
      lastInterruptionReason = nil
    }
    // 这个 key 只在 reason == VideoDeviceNotAvailableDueToSystemPressure(5)
    // 时存在,拿到就是最直接的"因为热而断流"的实证。
    if #available(iOS 11.1, *),
      let sp = note.userInfo?[AVCaptureSessionInterruptionSystemPressureStateKey]
        as? AVCaptureDevice.SystemPressureState
    {
      lastPressureLevel = sp.level.rawValue
      lastPressureFactors = Int(sp.factors.rawValue)
    }
    emit()
  }

  @objc private func sessionInterruptionEnded(_ note: Notification) {
    // [pw] 原为 `(session?.isRunning ?? false) ? .running : .stopped` ——
    //   session 为 nil 时 `?? false` 直接落到 .stopped,而我们**根本没有 session、
    //   没有任何知情权**。打断通知是以 object: nil 注册的,对进程内**任意**
    //   AVCaptureSession 生效,而 ARKit 内部自带一个 —— 于是 ARKit 的会话事件
    //   会把我们的状态写成 "stopped",实测就是这么误报的。
    //   没有 session ⇒ unknown。"不知道" 和 "已停止" 是两回事。
    cameraStream = session.map { $0.isRunning ? PwVioCameraStreamState.running
                                              : PwVioCameraStreamState.stopped }
      ?? .unknown
    lastInterruptionReason = nil
    emit()
  }

  /// 取一次当前快照(也用于 method channel 的 snapshot)。
  public func snapshot() -> PwVioThermalSnapshot {
    let pi = ProcessInfo.processInfo
    var level = lastPressureLevel
    var factors = lastPressureFactors
    if #available(iOS 11.1, *), let dev = videoDevice {
      let sp = dev.systemPressureState
      level = sp.level.rawValue
      factors = Int(sp.factors.rawValue)
    }
    // [pw] 同上:只有我们自己 attach 过 session 时,running/stopped 才是权威的。
    //   没 attach 就保持 unknown,不要用"没在跑"冒充"停了"。
    var stream = cameraStream
    if let s = session, stream != .interrupted {
      stream = s.isRunning ? .running : .stopped
    } else if session == nil && stream != .interrupted {
      stream = .unknown
    }
    return PwVioThermalSnapshot(
      tsUs: pwVioMonotonicMicros(),
      rawStatus: pi.thermalState.rawValue,
      // thermalState 在不支持的系统上返回 .nominal 而不是报错,所以
      // "读到了"这件事在 iOS 上恒真;Android 侧才会出现 false。
      statusReadable: true,
      lowPowerMode: pi.isLowPowerModeEnabled,
      cameraStream: stream,
      interruptionReason: lastInterruptionReason,
      systemPressureLevel: level,
      systemPressureFactors: factors,
      activeProcessorCount: pi.activeProcessorCount
    )
  }

  private func emit() {
    let snap = snapshot()
    if Thread.isMainThread {
      onSnapshot?(snap)
    } else {
      DispatchQueue.main.async { [weak self] in self?.onSnapshot?(snap) }
    }
  }
}

// MARK: - 视觉更新计时(给降频归因用)

/// 一次 VIO 视觉更新的 wall/cpu 计时。
///
/// ⚠️ begin 与 end **必须在同一线程**上调用(线程 CPU 时间的定义使然)。
/// 跨线程调用不会报错,只会给出一个看着正常、其实无意义的数字。
public final class PwVioUpdateTimer {
  private var wallStartUs: Int64 = 0
  private var cpuStartMs: Double = -1
  private var startThread: ObjectIdentifier?

  public init() {}

  public func begin() {
    wallStartUs = pwVioMonotonicMicros()
    cpuStartMs = pwVioThreadCpuMillis()
    startThread = ObjectIdentifier(Thread.current)
  }

  /// 返回 (wallMs, cpuMs, sameThread)。cpuMs < 0 表示读不到。
  public func end() -> (wallMs: Double, cpuMs: Double, sameThread: Bool) {
    let wallMs = Double(pwVioMonotonicMicros() - wallStartUs) / 1000.0
    let cpuNow = pwVioThreadCpuMillis()
    let cpuMs = (cpuStartMs >= 0 && cpuNow >= 0) ? (cpuNow - cpuStartMs) : -1
    let same = startThread == ObjectIdentifier(Thread.current)
    return (wallMs, cpuMs, same)
  }
}

// MARK: - Flutter 绑定

#if canImport(Flutter)

public final class PwVioThermalPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

  private let monitor = PwVioThermalMonitor()
  private var sink: FlutterEventSink?
  private let timer = PwVioUpdateTimer()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = PwVioThermalPlugin()
    let method = FlutterMethodChannel(
      name: PwVioThermalIdentifiers.methodChannel,
      binaryMessenger: registrar.messenger())
    let events = FlutterEventChannel(
      name: PwVioThermalIdentifiers.eventChannel,
      binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: method)
    events.setStreamHandler(instance)
  }

  /// 采集侧在建好 session 之后调用,让 systemPressureState 可读。
  public func attach(session: AVCaptureSession?, videoDevice: AVCaptureDevice?) {
    monitor.attach(session: session, videoDevice: videoDevice)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "start":
      monitor.onSnapshot = { [weak self] snap in
        self?.sink?(snap.asDictionary())
      }
      monitor.start()
      result(nil)
    case "stop":
      monitor.stop()
      result(nil)
    case "snapshot":
      result(monitor.snapshot().asDictionary())
    case "beginVisualUpdate":
      timer.begin()
      result(nil)
    case "endVisualUpdate":
      let m = timer.end()
      result([
        "wallMs": m.wallMs,
        "cpuMs": m.cpuMs,
        "sameThread": m.sameThread,
      ])
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  public func onListen(
    withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink
  ) -> FlutterError? {
    sink = events
    monitor.onSnapshot = { [weak self] snap in
      self?.sink?(snap.asDictionary())
    }
    monitor.start()
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    monitor.stop()
    return nil
  }
}

#endif
