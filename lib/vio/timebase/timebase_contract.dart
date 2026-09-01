// timebase_contract.dart — 时基归一化的数据契约。纯 Dart,零 Flutter 依赖。
//
// ── 为什么存在(病灶) ───────────────────────────────────────────────────
// XRSLAM 的 C API 只收一个 `double t`;`camera_time_offset` 是死旋钮(只解析
// 只打印,xrslam/src 里零消费),`ES_SIZE=15` 的误差状态里没有 td。于是当
// t_cam 与 t_imu 落在**不同时钟域**时,IMU 归并条件恒假 ⇒ preintegration 为
// 空 ⇒ 求解器里一个 IMU 因子都没有 ⇒ 系统静默退化成纯单目 SfM(**尺度不可
// 观、米制尺寸全错**),而状态照常返回 TRACKING。
//
// 这个失败模式的可怕之处是**没有任何一路会报错**。所以时基必须在采集侧就被
// 当成一等公民**测量并归一化**,而且检测器必须 fail-closed。
//
// ── 铁律映射 ────────────────────────────────────────────────────────────
// 「交付绝对无损,永久缺帧绝对禁止,fail-safe 只许推迟不许丢数据」
//   ⇒ 本文件里**故意没有** drop / discard 这个裁决。[TimebaseVerdict] 只有
//     三档:accept(可用)/ defer(留着,等偏置测准了再判)/ fault(整段
//     会话级故障,停下交给上层,而不是偷偷扔掉这一帧)。
//   ⇒ defer 的语义是**调用方必须保留样本**。任何把 defer 实现成丢弃的调用方
//     都违反铁律。
//
// ── 各时钟域的**文档实证**(2026-08-23 从一手文档核对,不是印象) ────────
// iOS:
//   • `CMLogItem.timestamp`(CMDeviceMotion 的父类属性)
//     Apple 原文:"The timestamp is the amount of time in seconds since the
//     device booted." —— 唯一一个把域**写进文档**的。
//   • `CACurrentMediaTime()`
//     Apple 原文:"A `CFTimeInterval` derived by calling `mach_absolute_time()`
//     and converting the result to seconds."
//   • `CMClockGetHostTimeClock()`
//     Apple 原文:"In macOS, the host time clock uses `mach_absolute_time` but
//     returns a value with a large integer timescale (e.g. nanoseconds)."
//     ⚠️ 注意这句只说了 **macOS**;iOS 上的实现 Apple 没写。所以「host clock
//        == mach_absolute_time」在 iOS 上是**未文档化**的,必须实测。
//   • `AVCaptureSession.synchronizationClock`(iOS 15.4+,取代 iOS 15.4 起
//     deprecated 的 `masterClock`;macOS 12.3+)
//     Apple 原文:"All capture output sample buffer timestamps are on the
//     synchronization clock's timebase. Use this clock in conjunction with the
//     clock from an `AVCaptureInput.Port` object to synchronize capture output
//     with external data sources **such as Core Motion samples**."
//     ⇒ Apple 的措辞是「**用这个钟去换算**」,不是「直接可比」。这正是
//        [TimeDomain.appleCaptureSynchronizationClock] 不等于
//        [TimeDomain.appleHostTime] 的原因。
//   • `ARFrame.timestamp`
//     Apple 全文只有一句:"The time at which the frame was captured."
//     🔴 **没有时钟域,没有参考原点,没有 Discussion。** 所以本模块对 ARKit
//        一路**不做任何假设**,只做测量([TimeDomain.appleArFrameUndocumented])。
//
// Android(verbatim from developer.android.com):
//   • `SystemClock.uptimeMillis()`:"counted in milliseconds since the system
//     was booted. This clock **stops when the system enters deep sleep** ...
//     This is the basis for most interval timing such as Thread.sleep(millis),
//     Object.wait(millis), and **System.nanoTime()**."
//     ⇒ `System.nanoTime()` 与 uptimeMillis 同域(CLOCK_MONOTONIC)。
//   • `SystemClock.elapsedRealtime()/elapsedRealtimeNanos()`:"return the time
//     since the system was booted, and **include deep sleep**."(CLOCK_BOOTTIME)
//   ⇒ elapsedRealtimeNanos − nanoTime = **开机以来累计休眠时长**。放一夜就是
//     小时级。这就是任务书里那个 3600 s 注入用例的物理来源。
//   • camera2 `SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME`(=1):"Timestamps ... are
//     in the same timebase as `SystemClock.elapsedRealtimeNanos()`, and they can
//     be compared to other timestamps using that base. ... Since
//     elapsedRealtimeNanos() and uptimeMillis() only diverge while the device is
//     asleep, **an offset between the two sources can be measured once per
//     active session** and applied to timestamps for su[bsequent frames]."
//     ⇒ Android 官方**背书**了「测一次偏置」的做法。我们再加周期重测,是因为
//        一次会话**可以**跨越休眠(App 切后台/息屏),官方那句只在会话不跨休眠
//        时成立。
//   • camera2 `SENSOR_INFO_TIMESTAMP_SOURCE_UNKNOWN`(=0):"Timestamps ... are in
//     nanoseconds and monotonic, but **can not be compared to timestamps from
//     other subsystems (e.g. accelerometer, gyro etc.) ... with accuracy**.
//     However, the timestamps are **roughly** in the same timebase as
//     `SystemClock.uptimeMillis()`."
//     🔴 这比任务书假设的更糟:UNKNOWN 机型上 camera↔IMU **不只是差一个可测
//        的常数偏置**,Google 明说「不能准确比较」。所以 UNKNOWN 只能给
//        [DomainComparability.approximate],残差必须留给求解器在线估 td;
//        采集侧只能把粗对齐做掉并**如实标注置信度**,不能宣称已对齐。

/// 一路原始时间戳所处的**物理时钟域**。
///
/// 这个枚举的每一项都对应上面文档块里一条**一手引文**;没有引文支撑的域一律
/// 归入 [TimeDomain.unknown],而不是猜一个。
enum TimeDomain {
  /// iOS `mach_absolute_time()` 换算成秒(== `CACurrentMediaTime()`)。
  /// 本模块把它选作 iOS 侧的**会话参考钟**(见 PwVioTimebase.swift)。
  appleHostTime,

  /// iOS `CMLogItem.timestamp`(CMDeviceMotion / CMAccelerometerData 等)。
  /// 文档:"seconds since the device booted"。
  appleCoreMotionBoot,

  /// iOS `CMSampleBuffer.presentationTimeStamp`,位于
  /// `AVCaptureSession.synchronizationClock` 的 timebase 上。
  appleCaptureSynchronizationClock,

  /// iOS `ARFrame.timestamp`。**Apple 未文档化其时钟域**。
  appleArFrameUndocumented,

  /// Android `System.nanoTime()` / `SystemClock.uptimeMillis()`;deep sleep 停走。
  androidMonotonicUptime,

  /// Android `SystemClock.elapsedRealtimeNanos()`;含 deep sleep。
  androidBootRealtime,

  /// Android camera2 且 `SENSOR_INFO_TIMESTAMP_SOURCE == UNKNOWN`。
  /// 大致等于 uptime,但官方声明**不可与其它子系统精确比较**。
  androidCameraUnknownSource,

  /// 已经归一化到本会话参考钟上的时间(本模块的输出)。
  pwNormalized,

  /// 未知 —— 不许当成任何已知域使用。
  unknown,
}

/// 一个域与**其它子系统**(相机 vs IMU)对比时的可比性等级。
///
/// 这不是「精度」而是「可比性」:[none] 表示两路数字放在一起做减法**没有物理
/// 意义**,必须先归一化;[approximate] 表示可以做减法但残差无界(Android
/// UNKNOWN 机型),必须留给在线 td 估计;[exact] 表示同域可直接比较。
enum DomainComparability { none, approximate, exact }

/// 域的静态性质表。
extension TimeDomainFacts on TimeDomain {
  /// 该域是否把「设备休眠」计入。null = 未文档化 / 不适用。
  bool? get includesDeepSleep {
    switch (this) {
      case TimeDomain.androidBootRealtime:
        return true;
      case TimeDomain.androidMonotonicUptime:
      case TimeDomain.androidCameraUnknownSource:
        return false;
      // iOS:Apple 只说 CoreMotion 是 "since the device booted",没说含不含
      // 休眠;mach_absolute_time 在 iOS 上的休眠行为同样未文档化。不猜。
      case TimeDomain.appleHostTime:
      case TimeDomain.appleCoreMotionBoot:
      case TimeDomain.appleCaptureSynchronizationClock:
      case TimeDomain.appleArFrameUndocumented:
      case TimeDomain.pwNormalized:
      case TimeDomain.unknown:
        return null;
    }
  }

  /// 与**另一个子系统**的时间戳直接相减是否有意义。
  DomainComparability get crossSubsystemComparability {
    switch (this) {
      case TimeDomain.pwNormalized:
        return DomainComparability.exact;
      case TimeDomain.androidCameraUnknownSource:
        // Google 原文:"can not be compared to timestamps from other subsystems
        // ... with accuracy"。
        return DomainComparability.approximate;
      case TimeDomain.appleArFrameUndocumented:
      case TimeDomain.unknown:
        return DomainComparability.none;
      default:
        // 其余域自身定义清楚,但与别域相比仍需归一化;归一化前按 none 处理。
        return DomainComparability.none;
    }
  }

  /// 该域是否**由文档给出**了参考原点。用于报告里区分「实测结论」与「文档结论」。
  bool get originIsDocumented {
    switch (this) {
      case TimeDomain.appleCoreMotionBoot:
      case TimeDomain.androidBootRealtime:
      case TimeDomain.androidMonotonicUptime:
        return true;
      default:
        return false;
    }
  }
}

/// 数据流类别。域错配检测是**跨流**的,所以需要这个标签。
enum StreamKind { camera, imu }

/// 一条带原始域标注的时间戳样本。
///
/// [rawSeconds] 是**原样**的平台数字(未做任何加减);[domain] 是它的域。
/// 归一化后的结果放在 [TimebaseNormalizerOutput] 里,而不是就地改写这个对象 ——
/// 保留原值是为了事后能复算,也是「无损」在时间戳这一层的体现。
class TimestampSample {
  const TimestampSample({
    required this.rawSeconds,
    required this.domain,
    required this.stream,
    this.hostArrivalSeconds,
    this.exposureDurationSeconds,
    this.sequence,
  });

  final double rawSeconds;
  final TimeDomain domain;
  final StreamKind stream;

  /// 收到该样本的**那一刻**在会话参考钟上的读数(iOS 侧 = mach_absolute_time
  /// 换算的秒)。偏置估计器全靠这一对 (raw, hostArrival)。
  final double? hostArrivalSeconds;

  /// 该帧的曝光时长(秒)。相机帧才有。
  /// 用来把「PTS 到底是曝光起点还是曝光中心」这个 Apple 未文档化的不确定性
  /// **量化**成 ±0.5·exposureDuration,而不是当成 0。
  final double? exposureDurationSeconds;

  /// 平台侧的单调序号(可选),用于把「时间戳回退」与「样本乱序」区分开。
  final int? sequence;

  @override
  String toString() =>
      'TimestampSample(raw=$rawSeconds, domain=$domain, stream=$stream, '
      'hostArrival=$hostArrivalSeconds, exposure=$exposureDurationSeconds)';
}

/// 偏置估计结果。
class ClockOffsetEstimate {
  const ClockOffsetEstimate({
    required this.offsetSeconds,
    required this.sampleCount,
    required this.jitterSeconds,
    required this.spanSeconds,
    required this.driftPpm,
    required this.driftPpmUncertainty,
  });

  /// ref = src + offsetSeconds(min-filter 估计,见 clock_offset_estimator.dart)。
  final double offsetSeconds;
  final int sampleCount;

  /// 投递延迟抖动 = p50(delta) − min(delta)。这是本次估计的**不确定度代理**:
  /// 真偏置 ∈ [offsetSeconds − d_min_true, offsetSeconds],而 d_min_true ≥ 0
  /// 且随样本数增加趋于 0;jitter 给出它的量级。
  final double jitterSeconds;

  /// 本次估计所覆盖的时间跨度。
  final double spanSeconds;

  /// 相对漂移(ppm)。同一晶振派生的两个钟应当是 0(在不确定度内)。
  final double driftPpm;

  /// 漂移的不确定度(ppm)= jitter / span × 1e6。**漂移只有超过这个数才算数**。
  final double driftPpmUncertainty;

  /// 漂移是否在噪声地板之上(可证伪的判据,而不是看着像)。
  bool get driftIsSignificant => driftPpm.abs() > driftPpmUncertainty;

  @override
  String toString() => 'ClockOffsetEstimate(offset=${offsetSeconds.toStringAsFixed(6)}s, '
      'n=$sampleCount, jitter=${(jitterSeconds * 1e3).toStringAsFixed(3)}ms, '
      'span=${spanSeconds.toStringAsFixed(1)}s, '
      'drift=${driftPpm.toStringAsFixed(1)}±${driftPpmUncertainty.toStringAsFixed(1)}ppm)';
}

/// 故障类别。每一项都对应一个**具体的物理成因**,不是笼统的 "error"。
enum TimebaseFaultKind {
  /// 跨流偏斜超出结构上限 ⇒ t_cam 与 t_imu 不同域。
  domainSkew,

  /// 两相邻相机帧之间**一条 IMU 样本都没有** ⇒ preintegration 必为空。
  /// 这是 XRSLAM 静默退化的**直接观测量**。
  emptyPreintegrationWindow,

  /// 时间戳回退(非乱序,序号也在前进)。
  nonMonotonic,

  /// 时间戳重复。
  duplicateTimestamp,

  /// 时间戳发生了「归零级」跳变 ⇒ 时钟基准被重置(重启 / 域切换)。
  clockReset,

  /// 声明的域本身不可用(unknown / ARKit 未测量)。
  undeterminedDomain,
}

/// 一次故障。
class TimebaseFault {
  const TimebaseFault({
    required this.kind,
    required this.detail,
    required this.measuredSeconds,
    required this.limitSeconds,
  });

  final TimebaseFaultKind kind;
  final String detail;

  /// 实测量(秒)。emptyPreintegrationWindow 时是该帧间隔长度。
  final double measuredSeconds;

  /// 触发该故障的上限(秒)。emptyPreintegrationWindow 时为 0(样本数判据)。
  final double limitSeconds;

  @override
  String toString() =>
      'TimebaseFault(${kind.name}: $detail; measured=${measuredSeconds}s, limit=${limitSeconds}s)';
}

/// 裁决。
///
/// 🔴 **没有 drop。** 见文件头「铁律映射」。
enum TimebaseDecision {
  /// 归一化成立,时间戳可以喂给求解器。
  accept,

  /// 偏置还没测准(样本不足 / 抖动过大)。调用方**必须保留样本**,等偏置收敛
  /// 后重新提交。丢弃 = 违反「永久缺帧绝对禁止」。
  defer,

  /// 会话级故障。停止喂数据并上报;**不许**静默继续,也**不许**丢帧。
  fault,
}

/// 一次归一化的完整结果。
class TimebaseVerdict {
  const TimebaseVerdict({
    required this.decision,
    this.normalizedSeconds,
    this.uncertaintySeconds,
    this.faults = const <TimebaseFault>[],
    this.reason = '',
  });

  final TimebaseDecision decision;

  /// 归一化到会话参考钟上的时间。仅 [TimebaseDecision.accept] 时非 null。
  final double? normalizedSeconds;

  /// 该时间的**总不确定度**(秒),包含:偏置抖动 + 曝光中心未知量
  /// (±0.5·exposureDuration)。下游可以拿它去 gate 米制尺寸的置信度。
  final double? uncertaintySeconds;

  final List<TimebaseFault> faults;
  final String reason;

  bool get isAccepted => decision == TimebaseDecision.accept;
  bool get isBlocking => decision != TimebaseDecision.accept;

  @override
  String toString() => 'TimebaseVerdict(${decision.name}'
      '${normalizedSeconds != null ? ', t=$normalizedSeconds' : ''}'
      '${faults.isEmpty ? '' : ', faults=$faults'}'
      '${reason.isEmpty ? '' : ', reason=$reason'})';
}
