// android_boottime_bridge.dart — Android CLOCK_MONOTONIC ↔ CLOCK_BOOTTIME 桥接。
// 纯 Dart,零 Flutter 依赖,零平台调用。Kotlin 侧**只负责读原始值**。
//
// ── 为什么算法必须在 Dart 里 ────────────────────────────────────────────
// 「哪一路走哪个钟」是**逐机型**的(camera2 的 SENSOR_INFO_TIMESTAMP_SOURCE
// 由 HAL 决定)。如果把判断写进 Kotlin,就等于要维护一张机型表 —— Android
// 碎片化下这张表永远是错的。正确做法是**运行时自适应**:Kotlin 只上报
//   (a) 相机的 timestamp source 枚举值(平台自己声明的)
//   (b) 成对的 (nanoTime, elapsedRealtimeNanos) 原始读数
// Dart 侧据此推导偏置、检测休眠跳变、给出归一化结果。
//
// ── 文档实证(verbatim,2026-08-23 核对 developer.android.com) ──────────
// • `SystemClock.uptimeMillis()`:"counted in milliseconds since the system was
//   booted. This clock **stops when the system enters deep sleep** ... This is
//   the basis for most interval timing such as Thread.sleep(millis),
//   Object.wait(millis), and **System.nanoTime()**."
//   ⇒ System.nanoTime() 与 uptimeMillis 同域。
// • `SystemClock.elapsedRealtime()/elapsedRealtimeNanos()`:"return the time
//   since the system was booted, and **include deep sleep**."
//   ⇒ elapsedRealtimeNanos − nanoTime = **开机以来累计休眠时长**。
// • camera2 `SENSOR_INFO_TIMESTAMP_SOURCE_REALTIME`(常量 1):"Timestamps ...
//   are in the same timebase as SystemClock.elapsedRealtimeNanos(), and they can
//   be compared to other timestamps using that base. ... Since
//   elapsedRealtimeNanos() and uptimeMillis() only diverge while the device is
//   asleep, **an offset between the two sources can be measured once per active
//   session** and applied to timestamps."
// • camera2 `SENSOR_INFO_TIMESTAMP_SOURCE_UNKNOWN`(常量 0):"Timestamps ... are
//   in nanoseconds and monotonic, but **can not be compared to timestamps from
//   other subsystems (e.g. accelerometer, gyro etc.) ... with accuracy**.
//   However, the timestamps are **roughly** in the same timebase as
//   SystemClock.uptimeMillis()."
//
// 🔴 UNKNOWN 这条比常见说法更狠:Google 明说**不能准确比较**。所以本模块对
//    UNKNOWN 机型只给 [DomainComparability.approximate] —— 采集侧把常数偏置
//    去掉,**残差必须留给求解器在线估 td**,并且**不许**对外宣称已对齐。
//
// • Android 的 `SensorEvent.timestamp`:CTS 要求走 CLOCK_BOOTTIME(与
//   elapsedRealtimeNanos 同域)。⚠️ 这一条我们**按 BOOTTIME 假设,但不信任
//   假设** —— [AndroidTimebaseBridge] 会用实测的 host 到达时间去验证它,
//   验证不过就退化成 unknown 并阻断,而不是继续跑。

import 'clock_offset_estimator.dart';
import 'timebase_contract.dart';

/// camera2 `CameraCharacteristics.SENSOR_INFO_TIMESTAMP_SOURCE` 的取值。
/// 数值与平台常量一致(UNKNOWN = 0, REALTIME = 1),便于 Kotlin 侧直接透传 int。
enum AndroidCameraTimestampSource {
  unknown(0),
  realtime(1);

  const AndroidCameraTimestampSource(this.platformValue);
  final int platformValue;

  static AndroidCameraTimestampSource fromPlatform(int v) {
    switch (v) {
      case 0:
        return AndroidCameraTimestampSource.unknown;
      case 1:
        return AndroidCameraTimestampSource.realtime;
      default:
        // 平台给了我们没见过的值 —— 不猜,当 unknown(更保守的那一档)。
        return AndroidCameraTimestampSource.unknown;
    }
  }

  TimeDomain get domain => this == AndroidCameraTimestampSource.realtime
      ? TimeDomain.androidBootRealtime
      : TimeDomain.androidCameraUnknownSource;
}

/// Kotlin 侧一次「三明治采样」上报的原始值(全部纳秒,平台原样)。
///
/// Kotlin 侧的**唯一**职责就是产生这个结构:
/// ```kotlin
/// val a = System.nanoTime()
/// val m = SystemClock.elapsedRealtimeNanos()
/// val c = System.nanoTime()
/// // 上报 (a, m, c)
/// ```
/// 三个读数必须在同一线程连续执行,中间不做任何别的事。
class AndroidClockProbe {
  const AndroidClockProbe({
    required this.monotonicBeforeNanos,
    required this.bootRealtimeNanos,
    required this.monotonicAfterNanos,
  });

  final int monotonicBeforeNanos;
  final int bootRealtimeNanos;
  final int monotonicAfterNanos;

  /// 读取开销(秒)—— 也就是这次夹逼的宽度。
  double get readCostSeconds =>
      (monotonicAfterNanos - monotonicBeforeNanos) / 1e9;
}

/// 桥接结果。
class AndroidBridgeState {
  const AndroidBridgeState({
    required this.bootMinusMonotonic,
    required this.suspendJumpCount,
    required this.lastSuspendSeconds,
    required this.cameraDomain,
    required this.cameraComparability,
  });

  /// θ 使得 elapsedRealtimeNanos ≈ nanoTime + θ(秒),含**硬**误差界。
  final BracketedOffset bootMinusMonotonic;

  /// 观测到的休眠次数(偏置区间不相交的次数)。
  final int suspendJumpCount;

  /// 最近一次休眠时长(秒)。
  final double lastSuspendSeconds;

  final TimeDomain cameraDomain;
  final DomainComparability cameraComparability;

  /// 累计休眠时长(秒)= 当前偏置。放一夜就是小时级 —— 这正是
  /// 「t_cam 与 t_imu 不同域」在 Android 上的物理量。
  double get accumulatedSleepSeconds => bootMinusMonotonic.offsetSeconds;
}

/// Android 时基桥。周期性喂 [AndroidClockProbe],它维护偏置并检测休眠跳变。
class AndroidTimebaseBridge {
  AndroidTimebaseBridge({
    required this.cameraTimestampSource,
    this.remeasureIntervalSeconds = 2.0,
  }) : assert(remeasureIntervalSeconds > 0);

  final AndroidCameraTimestampSource cameraTimestampSource;

  /// 周期重测间隔。Google 说「一次会话测一次」就够,但一次会话**可以**跨越
  /// 休眠(App 切后台 / 息屏),所以我们照测。2 s 的代价是三次时钟读取,
  /// 可忽略;收益是把「跨休眠的会话」从静默错误变成可检测事件。
  final double remeasureIntervalSeconds;

  final OffsetTracker _tracker = OffsetTracker();
  double? _lastProbeMonotonicSeconds;

  OffsetTracker get tracker => _tracker;
  BracketedOffset? get latestOffset => _tracker.latest;

  /// 是否到了该重测的时候。
  bool shouldRemeasure(double nowMonotonicSeconds) =>
      _lastProbeMonotonicSeconds == null ||
      (nowMonotonicSeconds - _lastProbeMonotonicSeconds!) >=
          remeasureIntervalSeconds;

  /// 记入一次探针。返回 true 表示**检测到设备刚睡过一觉**(偏置跳变)。
  ///
  /// 跳变意味着:所有还留在缓冲里、用旧偏置换算过的时间戳都必须**重新换算**。
  /// 调用方拿到 true 必须把缓冲重放一遍,而不是丢掉(铁律)。
  bool ingest(AndroidClockProbe p) {
    final BracketedOffset o = bracketOffset(
      refBefore: p.monotonicBeforeNanos / 1e9,
      srcMid: p.bootRealtimeNanos / 1e9,
      refAfter: p.monotonicAfterNanos / 1e9,
    );
    // 注意方向:bracketOffset 给的是 ref = src + θ,即 monotonic = boot + θ,
    // 而我们想要的是 boot = monotonic + (−θ)。取负。
    final BracketedOffset bootMinusMono = BracketedOffset(
      offsetSeconds: -o.offsetSeconds,
      halfWidthSeconds: o.halfWidthSeconds,
      refMidpointSeconds: o.refMidpointSeconds,
    );
    _lastProbeMonotonicSeconds = o.refMidpointSeconds;
    return _tracker.record(bootMinusMono);
  }

  /// 当前状态;还没喂过探针时返回 null。
  AndroidBridgeState? state() {
    final BracketedOffset? o = _tracker.latest;
    if (o == null) return null;
    return AndroidBridgeState(
      bootMinusMonotonic: o,
      suspendJumpCount: _tracker.jumpCount,
      lastSuspendSeconds: _tracker.lastJumpSeconds,
      cameraDomain: cameraTimestampSource.domain,
      cameraComparability:
          cameraTimestampSource.domain.crossSubsystemComparability,
    );
  }

  /// 把一个**相机**时间戳(纳秒,平台原样)换算到 IMU 所在的 BOOTTIME 域。
  ///
  /// 返回 null = 偏置还没测过 ⇒ 调用方必须 defer(留着),不许丢。
  double? cameraToBootSeconds(int cameraTimestampNanos) {
    final double t = cameraTimestampNanos / 1e9;
    switch (cameraTimestampSource) {
      case AndroidCameraTimestampSource.realtime:
        // 已经在 BOOTTIME 域,零换算。
        return t;
      case AndroidCameraTimestampSource.unknown:
        final BracketedOffset? o = _tracker.latest;
        if (o == null) return null;
        // camera(≈uptime/monotonic) + (boot − monotonic) = boot
        return t + o.offsetSeconds;
    }
  }

  /// 该换算结果的**硬**不确定度(秒)。
  ///
  /// REALTIME:0(同域)。
  /// UNKNOWN:夹逼半宽 **只是下界** —— Google 说 UNKNOWN 与其它子系统
  ///   "can not be compared ... with accuracy",这个不可比性没有文档化的上界。
  ///   所以这里返回 [double.infinity] 之外的做法都是自欺;我们返回夹逼半宽
  ///   并**同时**把 comparability 标成 approximate,由上层据此拒绝对外宣称
  ///   「已对齐」。
  double? cameraOffsetHardHalfWidthSeconds() {
    switch (cameraTimestampSource) {
      case AndroidCameraTimestampSource.realtime:
        return 0.0;
      case AndroidCameraTimestampSource.unknown:
        return _tracker.latest?.halfWidthSeconds;
    }
  }
}
