// vio_diagnostics_recorder.dart — 真机第一测的读出口。
//
// 为什么需要它:lib/vio/ 下的时基/热/能力探测都写好了、单测全绿,但**没有任何
// 出口把结果交出来**。没有出口 = 上了真机也拿不到数字,而我们今天整份风险台账的
// 结论是「先有数字,再定架构」。
//
// 它测的三件事,都**不依赖 XRSLAM**(XRSLAM 还没进 App),是纯采集侧测量:
//   ① CoreMotion / ARFrame 各自贴哪个时钟基准(CLOCK_UPTIME_RAW vs CLOCK_MONOTONIC)
//      —— 这条推翻了「iOS 上两路时间戳同域、拿来即用」的旧判断:
//      man 3 clock_gettime 明写 UPTIME_RAW 休眠时停走、MONOTONIC 继续走,而
//      CMLogItem.timestamp 的文档只有一句 "since the device booted",没说是哪个。
//   ② IMU 实际到达间隔的直方图(记事实,不记你请求的频率)
//   ③ 热档位随时间的曲线(这条公开世界查不到,只能自己测)
//
// 三条纪律:
//   - **有界内存**:所有累积都是定长环形缓冲。手机上比 Mac 更不能涨。
//   - **不静默失败**:通道调不通就记 error 并计数,不当作「没数据」。
//   - **不编答案**:累计休眠不足时基准判据本来就分不开,如实记 indeterminate,
//     不退化成「大概是 uptimeRaw」。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:crypto/crypto.dart';

import '../thermal/thermal_signal.dart';
import '../thermal/vio_thermal_channel.dart';
import '../ffi/xrslam_build_contract.dart';
import '../ffi/xrslam_config.dart';
import '../timebase/ios_timebase_channel.dart';
import 'vio_shadow_downsample_contract.dart';
import 'vio_shadow_health.dart';
import 'vio_shadow_se3_comparison.dart';

String _newVioSessionId() {
  final Random random = Random.secure();
  final List<int> bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String byte(int index) => bytes[index].toRadixString(16).padLeft(2, '0');
  return '${byte(0)}${byte(1)}${byte(2)}${byte(3)}-'
      '${byte(4)}${byte(5)}-${byte(6)}${byte(7)}-'
      '${byte(8)}${byte(9)}-${byte(10)}${byte(11)}'
      '${byte(12)}${byte(13)}${byte(14)}${byte(15)}';
}

/// Portable capture policy. Platform glue applies this exact Dart-selected
/// value; it is never read back from Swift as a competing source of truth.
const int kVioShadowDownsampleFactor = 3;
const String kVioShadowDownsampleFormula =
    kVioShadowDownsampleFormulaBoxNxnHalfUpV1;
// Frozen upstream xrslam-ios uses Camera.setFps(30).
const double kVioShadowRequestedCameraHz = 30.0;
const double kVioShadowRequestedAccelerometerHz = 100.0;
const double kVioShadowRequestedGyroscopeHz = 100.0;
const double kVioShadowAccelerationScale = -9.80665;

enum VioDiagnosticsLifecycleState { stopped, starting, running, stopping }

/// 定长环形缓冲。满了丢**最老**的 —— 这里丢的是诊断样本,不是交付数据,
/// 与「fail-safe 只许推迟不许丢数据」的铁律不冲突(那条管的是采集帧)。
/// SLAM 状态的一次采样。字段刻意少 —— 只留能定位「何时推进 / 是否卡住」的,
/// 900 个点乘以整条快照会把落盘文件撑大好几倍。
class _SlamTick {
  const _SlamTick({
    required this.wallMillis,
    required this.slamState,
    required this.poseRc,
    required this.imagesAccepted,
    required this.accAccepted,
    required this.landmarksUsable,
    required this.landmarksPublished,
    required this.mappedLandmarks,
    required this.trackedKeypoints,
    required this.degenerate,
  });

  final int wallMillis;
  final int slamState;
  final int poseRc;
  final int imagesAccepted;
  final int accAccepted;
  final int landmarksUsable;
  final int landmarksPublished;
  final int mappedLandmarks;
  final int trackedKeypoints;
  final int degenerate;

  Map<String, Object?> toJson() => <String, Object?>{
    'wallMillis': wallMillis,
    'slamState': slamState,
    'poseRc': poseRc,
    'imagesAccepted': imagesAccepted,
    'accAccepted': accAccepted,
    'landmarksUsable': landmarksUsable,
    'landmarksPublished': landmarksPublished,
    'mappedLandmarks': mappedLandmarks,
    'trackedKeypoints': trackedKeypoints,
    'degenerate': degenerate,
  };
}

class _Ring<T> {
  _Ring(this.capacity) : assert(capacity > 0);
  final int capacity;
  final List<T> _buf = <T>[];
  int _dropped = 0;

  void add(T v) {
    _buf.add(v);
    if (_buf.length > capacity) {
      _buf.removeAt(0);
      _dropped++;
    }
  }

  List<T> get items => List<T>.unmodifiable(_buf);
  int get length => _buf.length;
  int get dropped => _dropped;

  void clear() {
    _buf.clear();
    _dropped = 0;
  }
}

/// Serializes diagnostic polling without imposing any lock or wait on native
/// ARKit/CoreMotion callbacks. Closing advances the token before awaiting the
/// one in-flight poll, so an old async continuation cannot mutate a terminal
/// session or a later restart.
class VioDiagnosticPollGate {
  int _generation = 0;
  bool _open = false;
  Future<void>? _inFlight;

  int open() {
    _generation++;
    _open = true;
    return _generation;
  }

  bool isCurrent(int token) => _open && token == _generation;

  Future<bool> run(Future<void> Function(int token) body) {
    if (!_open || _inFlight != null) return Future<bool>.value(false);
    final int token = _generation;
    final Completer<void> done = Completer<void>();
    final Future<void> future = done.future;
    _inFlight = future;
    unawaited(() async {
      try {
        await body(token);
        done.complete();
      } catch (error, stack) {
        done.completeError(error, stack);
      } finally {
        if (identical(_inFlight, future)) _inFlight = null;
      }
    }());
    return future.then((_) => true);
  }

  Future<void> closeAndDrain() async {
    _open = false;
    _generation++;
    final Future<void>? active = _inFlight;
    if (active != null) await active;
  }
}

/// 一条时基采样点。
class TimebaseTick {
  const TimebaseTick({
    required this.sessionId,
    required this.sessionEpoch,
    required this.nativeSessionGeneration,
    required this.wallMillis,
    required this.uptimeRawSeconds,
    required this.monotonicSeconds,
    required this.accumulatedSleepSeconds,
    required this.sessionSleepDeltaSeconds,
    required this.clockPairReadCostSeconds,
    required this.baseDiscriminable,
    required this.verdicts,
    required this.offsets,
  });

  final String sessionId;
  final int sessionEpoch;
  final int nativeSessionGeneration;
  final int wallMillis;
  final double uptimeRawSeconds;
  final double monotonicSeconds;
  final double accumulatedSleepSeconds;
  final double sessionSleepDeltaSeconds;
  final double clockPairReadCostSeconds;

  /// false ⇒ 累计休眠太少,两个候选基准数值重合,**任何基准结论都是自欺**。
  final bool baseDiscriminable;

  /// source -> verdict 名(uptimeRaw / monotonic / indeterminate / unavailable)
  final Map<String, String> verdicts;

  /// source -> {toUptimeRaw, toMonotonic} 偏置(秒),null 表示该路没样本。
  final Map<String, Map<String, double?>> offsets;

  Map<String, Object?> toJson() => <String, Object?>{
    'sessionId': sessionId,
    'sessionEpoch': sessionEpoch,
    'nativeSessionGeneration': nativeSessionGeneration,
    'wallMillis': wallMillis,
    'uptimeRawSeconds': uptimeRawSeconds,
    'monotonicSeconds': monotonicSeconds,
    'accumulatedSleepSeconds': accumulatedSleepSeconds,
    'sessionSleepDeltaSeconds': sessionSleepDeltaSeconds,
    'clockPairReadCostSeconds': clockPairReadCostSeconds,
    'baseDiscriminable': baseDiscriminable,
    'verdicts': verdicts,
    'offsets': offsets,
  };
}

/// 一条热采样点。字段直接取自 [ThermalSignal] 的结构化属性 ——
/// **不解析 toString()**:那种松判据今天已经把我坑过五次。
class ThermalTick {
  const ThermalTick({
    required this.wallMillis,
    required this.timestampUs,
    required this.tierName,
    required this.rawStatus,
    required this.statusReadable,
    required this.headroom,
    required this.lowPowerMode,
    required this.cameraStream,
    required this.cameraCutBySystemPressure,
    required this.interruptionReason,
    required this.systemPressureLevel,
    required this.activeProcessorCount,
    required this.cpuCurFreqKhz,
  });

  final int wallMillis;
  final int timestampUs;
  final String tierName;
  final int rawStatus;

  /// false ⇒ 热等级读不到,tier 是靠 headroom 推的,遥测里必须标 unknown 而不是当真。
  final bool statusReadable;

  final double? headroom;
  final bool? lowPowerMode;
  final String cameraStream;

  /// 相机因**系统压力**被断流(iOS reason==5)。断流 ≠ 降帧:一帧都没有,
  /// VIO 只剩纯 IMU 推算。
  final bool cameraCutBySystemPressure;

  final int? interruptionReason;
  final String? systemPressureLevel;
  final int? activeProcessorCount;

  /// 当前各核频率 —— 「被降频」与「算法发散」在日志上可分离的关键。
  final List<int?> cpuCurFreqKhz;

  Map<String, Object?> toJson() => <String, Object?>{
    'wallMillis': wallMillis,
    'timestampUs': timestampUs,
    'tier': tierName,
    'rawStatus': rawStatus,
    'statusReadable': statusReadable,
    'headroom': headroom,
    'lowPowerMode': lowPowerMode,
    'cameraStream': cameraStream,
    'cameraCutBySystemPressure': cameraCutBySystemPressure,
    'interruptionReason': interruptionReason,
    'systemPressureLevel': systemPressureLevel,
    'activeProcessorCount': activeProcessorCount,
    'cpuCurFreqKhz': cpuCurFreqKhz,
  };
}

/// 采集侧诊断记录器。
///
/// 用法:`await VioDiagnosticsRecorder.instance.start();`
/// 报告落在 App Documents 下的 `vio_diagnostics/` 目录,用
/// `xcrun devicectl device copy from ...` 拉走。
class VioDiagnosticsRecorder {
  VioDiagnosticsRecorder({
    IosTimebaseChannel? timebase,
    VioThermalChannel? thermal,
    this.pollInterval = const Duration(seconds: 2),
    this.flushInterval = const Duration(seconds: 20),
    this.ringCapacity = 900,
    Future<Directory> Function()? documentsDirProvider,
    String Function()? sessionIdFactory,
    bool? supportedOverride,
  }) : _timebase = timebase ?? IosTimebaseChannel(),
       _thermal = thermal ?? VioThermalChannel(),
       _documentsDirProvider = documentsDirProvider,
       _sessionIdFactory = sessionIdFactory ?? _newVioSessionId,
       _supportedOverride = supportedOverride;

  static final VioDiagnosticsRecorder instance = VioDiagnosticsRecorder();

  final IosTimebaseChannel _timebase;
  final VioThermalChannel _thermal;

  /// 快照轮询间隔。2s 足够看清基准偏置的漂移,又不至于自己变成负载。
  final Duration pollInterval;

  /// 落盘间隔。崩溃/被杀时最多丢这一段 —— 所以不能设太大。
  final Duration flushInterval;

  /// 环形缓冲容量。900 × 2s = 30 分钟,正好覆盖热压测的时长。
  final int ringCapacity;

  final Future<Directory> Function()? _documentsDirProvider;
  final String Function() _sessionIdFactory;
  final bool? _supportedOverride;

  late final _Ring<TimebaseTick> _timebaseTicks = _Ring<TimebaseTick>(
    ringCapacity,
  );
  late final _Ring<ThermalTick> _thermalTicks = _Ring<ThermalTick>(
    ringCapacity,
  );

  /// [pw] 2026-08-24 新增。缺它就回答不了「初始化发生在第几秒」——
  /// 上一次真机跑出 slamState=1 但 landmark 为 0,而 ring 里只有 timebase 与
  /// thermal 两条序列,只能靠推理说「大概是初始化太晚、之后相机就停了」。
  /// 推理不是证据。这条序列把它变成可读的时间点。
  late final _Ring<_SlamTick> _slamTicks = _Ring<_SlamTick>(ringCapacity);
  final List<String> _errors = <String>[];

  Timer? _poll;
  Timer? _flush;
  StreamSubscription<ThermalSignal>? _thermalSub;
  bool _running = false;
  Future<void> _lifecycleTail = Future<void>.value();
  VioDiagnosticsLifecycleState _lifecycleState =
      VioDiagnosticsLifecycleState.stopped;
  int _lifecycleToken = 0;
  Future<File?>? _flushInFlight;
  final VioDiagnosticPollGate _pollGate = VioDiagnosticPollGate();
  int? _terminalReceiptGeneration;
  int? _trustedRunningGeneration;
  bool _trustedRunningGenerationConflict = false;
  bool _terminalReceiptConsumed = false;
  String _sessionId = '';
  int _sessionEpoch = 0;
  int _activeTimebaseGeneration = 0;
  VioShadowRunIdentityExpectation? _expectedIdentity;
  VioShadowTimebaseEvidence _timebaseEvidence =
      const VioShadowTimebaseEvidence.missing();
  int _startedAtMillis = 0;
  int _pollOk = 0;

  /// 是否已经用**真内参**重跑过一次生命周期。
  /// 启动时 ARKit 还没起来 ⇒ 第一次必然是 PLACEHOLDER;等 ARKit 出帧后补跑一次。
  /// 这也是产品上正确的生命周期:没在拍摄就不该有 VIO 实例占资源。
  bool _lifecycleUpgraded = false;

  /// 喂帧是否已启动。XRSLAM 是全局单例,只能起一次。
  bool _feedStarted = false;
  String? _lastStartGateReason;
  XrslamRuntimeConfigFiles? _runtimeConfigFiles;

  /// 最近一次隐私安全影子摘要。原生 wire map 只在当前 tick 栈上短暂存在；
  /// 绝对位姿、原始 IMU、图像即使误入 wire 也不会被保存或落盘。
  VioShadowHealthSummary? _shadowHealth;
  final VioShadowSe3ComparisonAccumulator _shadowComparison =
      VioShadowSe3ComparisonAccumulator();
  final VioShadowQualityAccumulator _shadowQuality =
      VioShadowQualityAccumulator();
  final VioShadowPoseAccumulator _shadowPose = VioShadowPoseAccumulator();
  int _pollFail = 0;

  bool get isRunning => _running;
  VioDiagnosticsLifecycleState get lifecycleState => _lifecycleState;

  /// 只在 iOS 上有原生实现;其他平台直接不启动而不是假装在跑。
  bool get _supported => _supportedOverride ?? (!kIsWeb && Platform.isIOS);

  Future<void> start() async {
    await _enqueueLifecycle(_startSerialized);
  }

  Future<void> stop() async {
    await _enqueueLifecycle(_stopSerialized);
  }

  Future<void> _enqueueLifecycle(Future<void> Function() operation) {
    final Future<void> scheduled = _lifecycleTail.then<void>(
      (_) => operation(),
    );
    _lifecycleTail = scheduled.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return scheduled;
  }

  bool _isLifecycleCurrent(int token, VioDiagnosticsLifecycleState expected) =>
      _lifecycleToken == token && _lifecycleState == expected;

  void _requireLifecycleCurrent(
    int token,
    VioDiagnosticsLifecycleState expected,
  ) {
    if (!_isLifecycleCurrent(token, expected)) {
      throw StateError(
        'stale VIO diagnostics lifecycle continuation: token=$token '
        'current=$_lifecycleToken state=$_lifecycleState expected=$expected',
      );
    }
  }

  Future<T> _awaitLifecycle<T>(
    int token,
    VioDiagnosticsLifecycleState expected,
    Future<T> future,
  ) async {
    final T value = await future;
    _requireLifecycleCurrent(token, expected);
    return value;
  }

  Future<void> _startSerialized() async {
    if (_lifecycleState == VioDiagnosticsLifecycleState.running ||
        _lifecycleState == VioDiagnosticsLifecycleState.starting) {
      return;
    }
    final int lifecycleToken = ++_lifecycleToken;
    _lifecycleState = VioDiagnosticsLifecycleState.starting;
    if (!_supported) {
      _note('unsupported-platform: 仅 iOS 有原生实现,未启动');
      _lifecycleState = VioDiagnosticsLifecycleState.stopped;
      return;
    }
    _running = true;
    _pollGate.open();
    _terminalReceiptGeneration = null;
    _trustedRunningGeneration = null;
    _trustedRunningGenerationConflict = false;
    _terminalReceiptConsumed = false;
    _sessionId = _sessionIdFactory();
    _sessionEpoch++;
    _activeTimebaseGeneration = 0;
    _expectedIdentity = null;
    _timebaseEvidence = const VioShadowTimebaseEvidence.missing();
    _timebaseTicks.clear();
    _thermalTicks.clear();
    _slamTicks.clear();
    _errors.clear();
    _pollOk = 0;
    _pollFail = 0;
    _startedAtMillis = DateTime.now().millisecondsSinceEpoch;
    _lifecycleUpgraded = false;
    _feedStarted = false;
    _lastStartGateReason = null;
    final XrslamRuntimeConfigFiles? staleConfigFiles = _runtimeConfigFiles;
    _runtimeConfigFiles = null;
    if (staleConfigFiles != null) await staleConfigFiles.dispose();
    _shadowHealth = null;
    _shadowComparison.reset();
    _shadowQuality.reset();
    _shadowPose.reset();

    try {
      await _awaitLifecycle<void>(
        lifecycleToken,
        VioDiagnosticsLifecycleState.starting,
        _timebase.beginSession(
          sessionId: _sessionId,
          sessionEpoch: _sessionEpoch,
        ),
      );
    } catch (e) {
      _requireLifecycleCurrent(
        lifecycleToken,
        VioDiagnosticsLifecycleState.starting,
      );
      _note('timebase.beginSession failed: $e');
    }
    // [pw] 必须显式启动 CoreMotion 投喂。原先 noteCoreMotion 只挂在
    //   PwVioCapability 的 IMU probe 里,而那个 probe 从没有人调用 ——
    //   真机第一测因此只拿到 arFrame 一路,而域错配是**两路对比**才成立的。
    try {
      // Cross-platform Dart policy: request 100 Hz explicitly. Native only
      // validates/applies this value and stores it for lifecycle resume.
      final bool ok = await _awaitLifecycle<bool>(
        lifecycleToken,
        VioDiagnosticsLifecycleState.starting,
        _timebase.startRawCoreMotionFeed(
          accelerometerHz: kVioShadowRequestedAccelerometerHz,
          gyroscopeHz: kVioShadowRequestedGyroscopeHz,
        ),
      );
      if (!ok) _note('startRawCoreMotionFeed: raw accelerometer/gyro 不可用');
    } catch (e) {
      _requireLifecycleCurrent(
        lifecycleToken,
        VioDiagnosticsLifecycleState.starting,
      );
      _note('startRawCoreMotionFeed failed: $e');
    }
    try {
      await _awaitLifecycle<void>(
        lifecycleToken,
        VioDiagnosticsLifecycleState.starting,
        _thermal.start(),
      );
    } catch (e) {
      _requireLifecycleCurrent(
        lifecycleToken,
        VioDiagnosticsLifecycleState.starting,
      );
      _note('thermal.start failed: $e');
    }

    _thermalSub = _thermal.signals().listen(
      _onThermal,
      onError: (Object e) => _note('thermal stream error: $e'),
      cancelOnError: false,
    );

    // [pw] 先问原生要真内参。这里绝不从 Dart FFI 直接 Create/Destroy XRSLAM:
    //   所有 native 生命周期都必须经过 iOS 的单一 serial coreQueue。ARKit 尚未
    //   出帧时只记「缺失」,等 tick 取到真内参后再通过 slamStart channel 启动。
    CameraIntrinsics? k;
    try {
      k = _currentSessionIntrinsics(
        await _awaitLifecycle<Map<String, Object?>?>(
          lifecycleToken,
          VioDiagnosticsLifecycleState.starting,
          _timebase.latestIntrinsics(),
        ),
      );
      _note(
        k == null
            ? 'intrinsics: 拿不到(ARKit 未跑帧或值不合理)⇒ 落 PLACEHOLDER'
            : 'intrinsics: fx=${k.fx.toStringAsFixed(2)} fy=${k.fy.toStringAsFixed(2)} '
                  'cx=${k.cx.toStringAsFixed(2)} cy=${k.cy.toStringAsFixed(2)} '
                  '@${k.resolutionWidth}x${k.resolutionHeight} [device-api]',
      );
    } catch (e) {
      _requireLifecycleCurrent(
        lifecycleToken,
        VioDiagnosticsLifecycleState.starting,
      );
      _note('latestIntrinsics failed: $e');
    }

    _poll = Timer.periodic(
      pollInterval,
      (_) => unawaited(_pollGate.run(_tickForGeneration)),
    );
    _flush = Timer.periodic(flushInterval, (_) => unawaited(_flushJoined()));
    await _awaitLifecycle<bool>(
      lifecycleToken,
      VioDiagnosticsLifecycleState.starting,
      _pollGate.run(_tickForGeneration),
    ); // 立刻取一条,不用等第一个间隔

    // [pw] **立刻落一次盘**,不等 20s 定时器。
    //   实测踩过:用 devicectl 启动后手机没人操作、屏幕一熄,iOS 就把 app 挂起,
    //   Dart 的 Timer 全停 ⇒ 第一次 flush 永远不来 ⇒ 拉到的永远是上一次会话的
    //   报告(设备上文件 mtime 卡在 12:37,而 12:44 的 Create/Destroy 有原生日志为证)。
    //   smoke 与 lifecycle 的结果在 t=0 就已经有了,本来也没理由等。
    await _awaitLifecycle<File?>(
      lifecycleToken,
      VioDiagnosticsLifecycleState.starting,
      _flushJoined(),
    );
    _lifecycleState = VioDiagnosticsLifecycleState.running;
  }

  Future<void> _stopSerialized() async {
    if (_lifecycleState == VioDiagnosticsLifecycleState.stopped) return;
    final int lifecycleToken = ++_lifecycleToken;
    _lifecycleState = VioDiagnosticsLifecycleState.stopping;
    _running = false;
    _poll?.cancel();
    _poll = null;
    _flush?.cancel();
    _flush = null;
    final StreamSubscription<ThermalSignal>? thermalSub = _thermalSub;
    _thermalSub = null;
    if (thermalSub != null) {
      await _awaitLifecycle<void>(
        lifecycleToken,
        VioDiagnosticsLifecycleState.stopping,
        thermalSub.cancel(),
      );
    }
    try {
      await _awaitLifecycle<void>(
        lifecycleToken,
        VioDiagnosticsLifecycleState.stopping,
        _pollGate.closeAndDrain(),
      );
    } catch (e) {
      _requireLifecycleCurrent(
        lifecycleToken,
        VioDiagnosticsLifecycleState.stopping,
      );
      _pollFail++;
      _note('in-flight diagnostic tick failed during stop: $e');
    }
    final Future<File?>? activeFlush = _flushInFlight;
    if (activeFlush != null) {
      await _awaitLifecycle<File?>(
        lifecycleToken,
        VioDiagnosticsLifecycleState.stopping,
        activeFlush,
      );
    }
    try {
      final Map<String, Object?> terminal =
          await _awaitLifecycle<Map<String, Object?>?>(
            lifecycleToken,
            VioDiagnosticsLifecycleState.stopping,
            _timebase.slamStop(),
          ) ??
          const <String, Object?>{};
      // slamStop first revokes native resume authorization and stops the
      // CoreMotion producer. Sample the final clock ledger only after that
      // boundary, then bind it to the immutable terminal receipt below.
      final IosTimebaseSnapshot? finalTimebase =
          await _awaitLifecycle<IosTimebaseSnapshot?>(
            lifecycleToken,
            VioDiagnosticsLifecycleState.stopping,
            _timebase.snapshot(),
          );
      _timebaseEvidence = _timebaseEvidenceFrom(
        finalTimebase,
        prior: _timebaseEvidence,
      );
      _consumeShadowSnapshot(terminal, requireTerminal: true);
    } catch (e) {
      _requireLifecycleCurrent(
        lifecycleToken,
        VioDiagnosticsLifecycleState.stopping,
      );
      _shadowHealth = null;
      _clearTransientShadowAccumulators();
      _note('slamStop/terminal snapshot failed: $e');
    }
    try {
      await _awaitLifecycle<void>(
        lifecycleToken,
        VioDiagnosticsLifecycleState.stopping,
        _timebase.stopRawCoreMotionFeed(),
      );
    } catch (e) {
      _requireLifecycleCurrent(
        lifecycleToken,
        VioDiagnosticsLifecycleState.stopping,
      );
      _note('stopRawCoreMotionFeed failed: $e');
    }
    try {
      await _awaitLifecycle<void>(
        lifecycleToken,
        VioDiagnosticsLifecycleState.stopping,
        _thermal.stop(),
      );
    } catch (e) {
      _requireLifecycleCurrent(
        lifecycleToken,
        VioDiagnosticsLifecycleState.stopping,
      );
      _note('thermal.stop failed: $e');
    }
    _feedStarted = false;
    final XrslamRuntimeConfigFiles? configFiles = _runtimeConfigFiles;
    _runtimeConfigFiles = null;
    if (configFiles != null) await configFiles.dispose();
    _lifecycleUpgraded = false;
    await _awaitLifecycle<File?>(
      lifecycleToken,
      VioDiagnosticsLifecycleState.stopping,
      _flushJoined(),
    );
    _lifecycleState = VioDiagnosticsLifecycleState.stopped;
  }

  void _onThermal(ThermalSignal s) {
    _thermalTicks.add(
      ThermalTick(
        wallMillis: DateTime.now().millisecondsSinceEpoch,
        timestampUs: s.timestampUs,
        tierName: s.tier.name,
        rawStatus: s.rawStatus,
        statusReadable: s.statusReadable,
        headroom: s.headroom,
        lowPowerMode: s.lowPowerMode,
        cameraStream: s.cameraStream.name,
        cameraCutBySystemPressure: s.cameraCutBySystemPressure,
        interruptionReason: s.interruptionReason,
        systemPressureLevel: s.systemPressureLevel,
        activeProcessorCount: s.activeProcessorCount,
        cpuCurFreqKhz: s.cpuCurFreqKhz,
      ),
    );
  }

  Future<void> _tickForGeneration(int token) async {
    if (!_running || !_pollGate.isCurrent(token)) return;
    try {
      final IosTimebaseSnapshot? snap = await _timebase.snapshot();
      if (!_pollGate.isCurrent(token)) return;
      if (snap == null) {
        _pollFail++;
        _note('timebase.snapshot returned null');
        return;
      }
      _pollOk++;
      if (_activeTimebaseGeneration == 0 &&
          snap.sessionId == _sessionId &&
          snap.sessionEpoch == _sessionEpoch) {
        _activeTimebaseGeneration = snap.sessionGeneration;
      }
      _timebaseEvidence = _timebaseEvidenceFrom(snap, prior: _timebaseEvidence);
      final Map<String, String> verdicts = <String, String>{};
      final Map<String, Map<String, double?>> offsets =
          <String, Map<String, double?>>{};
      for (final String key in snap.sources.keys) {
        verdicts[key] = snap.baseOf(key).name;
        final IosSourceOffsets o = snap.sources[key]!;
        offsets[key] = <String, double?>{
          'toUptimeRaw': o.offsetToUptimeRawSeconds,
          'toMonotonic': o.offsetToMonotonicSeconds,
        };
      }
      _timebaseTicks.add(
        TimebaseTick(
          sessionId: snap.sessionId,
          sessionEpoch: snap.sessionEpoch,
          nativeSessionGeneration: snap.sessionGeneration,
          wallMillis: DateTime.now().millisecondsSinceEpoch,
          uptimeRawSeconds: snap.uptimeRawSeconds,
          monotonicSeconds: snap.monotonicSeconds,
          accumulatedSleepSeconds: snap.accumulatedSleepSeconds,
          sessionSleepDeltaSeconds: snap.sessionSleepDeltaSeconds,
          clockPairReadCostSeconds: snap.clockPairReadCostSeconds,
          baseDiscriminable: snap.baseDiscriminable,
          verdicts: verdicts,
          offsets: offsets,
        ),
      );
    } catch (e) {
      if (!_pollGate.isCurrent(token)) return;
      _pollFail++;
      _note('timebase.snapshot threw: $e');
    }

    // [pw] 内参就位后补跑一次生命周期。
    //   启动路径上 ARKit 还没出帧,内参必然拿不到 ⇒ 第一次跑的是 PLACEHOLDER 配置。
    //   这里等真内参到位后**只补跑一次**,把 cam0.intrinsics 从 PLACEHOLDER
    //   升成 device-api。不重复跑 —— 每次 Create/Destroy 都有构造析构开销。
    if (!_lifecycleUpgraded) {
      try {
        final CameraIntrinsics? k = _currentSessionIntrinsics(
          await _timebase.latestIntrinsics(),
        );
        if (!_pollGate.isCurrent(token)) return;
        if (k != null && !_timebaseEvidence.preStartDomainAccepted) {
          _noteStartGate('timebase-not-accepted');
        } else if (k != null) {
          _lastStartGateReason = null;
          _note(
            'intrinsics 就位: '
            'fx=${k.fx.toStringAsFixed(2)} fy=${k.fy.toStringAsFixed(2)} '
            'cx=${k.cx.toStringAsFixed(2)} cy=${k.cy.toStringAsFixed(2)} '
            '@${k.resolutionWidth}x${k.resolutionHeight}',
          );
          // 配置直接交给原生 serial coreQueue 做唯一一次 Create。禁止先在
          // Dart FFI 做 smoke Create/Destroy,否则会绕过队列并与 feeder 竞态。
          if (!_feedStarted) {
            // ⚠️ 内参必须跟着降采样等比缩放。原生侧把 1920×1440 降成 640×480
            //   喂给 VIO,而这里若还用全分辨率的 fx/cx,整条位姿链会系统性错
            //   **而且不报错** —— 这是最典型的静默失效。
            //   上游 18 个 iPhone 配置全部是 640×480,这是回到它们的口径。
            // Dart owns the portable capture policy. Native receives and
            // validates this exact value; it does not choose or echo a second
            // algorithm default.
            const int n = kVioShadowDownsampleFactor;
            final bool divisible =
                k.resolutionWidth % n == 0 && k.resolutionHeight % n == 0;
            if (!divisible) {
              _note(
                '❌ ${k.resolutionWidth}x${k.resolutionHeight} 不是 $n 的'
                '整数倍 ⇒ Swift 侧会拒绝每一帧,这里也不启动',
              );
              await _flushJoined();
              return;
            }
            final CameraIntrinsics kVio = k.scaledTo(
              k.resolutionWidth ~/ n,
              k.resolutionHeight ~/ n,
            );
            _note(
              'VIO 内参(降采样后): fx=${kVio.fx.toStringAsFixed(2)} '
              'cx=${kVio.cx.toStringAsFixed(2)} '
              '@${kVio.resolutionWidth}x${kVio.resolutionHeight}  '
              '(降采样 ${n}x;上游 iPhone 口径就是 640x480 fx≈448.97)',
            );
            // 🔑 相机-IMU 外参。此前这里用的是默认的 iosPlaceholder ——
            //   单位四元数,而真值是 180 度翻转。真机实测那样喂 5731 帧
            //   一个位姿都没出(slamState 恒 0),前端跟踪却完全正常。
            //   上游 xrslam-ios/visualizer/configs 里就有全部 18 款 iPhone
            //   的标定值,我却在注释里写了"iOS 无 API ⇒ 真缺口"。
            final String? machine = await _timebase.deviceMachine();
            if (!_pollGate.isCurrent(token)) return;
            final CameraImuExtrinsic ext = CameraImuExtrinsic.forIosMachine(
              machine,
            );
            _note(
              '机型 ${machine ?? "未知"} -> 外参 '
              '${ext.provenance == FieldProvenance.deviceApi ? "上游标定值" : "分量中位数回退"}  '
              'q_bc=${ext.qbc}  p_bc=${ext.pbc}',
            );
            final XrslamConfigBuilder b = XrslamConfigBuilder(
              intrinsics: kVio,
              extrinsic: ext,
            );
            final String slamYaml = b.buildSlamConfigYaml();
            final String deviceYaml = b.buildDeviceConfigYaml();
            final String effectiveConfigSha256 = sha256
                .convert(utf8.encode('$slamYaml\u0000$deviceYaml'))
                .toString();
            final String inputIdentitySha256 = sha256
                .convert(
                  utf8.encode(
                    jsonEncode(<String, Object?>{
                      'schema': 'pw.vio.shadow-run-input-descriptor/4',
                      'sessionId': _sessionId,
                      'sessionEpoch': _sessionEpoch,
                      'machine': machine ?? 'UNAVAILABLE',
                      'imageSource': 'ARFrame.capturedImage/CVPixelBuffer.Y',
                      'requestedCameraHz': kVioShadowRequestedCameraHz,
                      'imuInputContract': 'raw-independent-v1',
                      'accelerometerSource':
                          'CoreMotion.CMAccelerometerData.acceleration',
                      'gyroscopeSource': 'CoreMotion.CMGyroData.rotationRate',
                      'requestedAccelerometerHz':
                          kVioShadowRequestedAccelerometerHz,
                      'requestedGyroscopeHz': kVioShadowRequestedGyroscopeHz,
                      'accelerationScale': kVioShadowAccelerationScale,
                      'imuPairing': 'none',
                      'imuResampling': 'none',
                      'timebaseSchema': 'pw.vio.timebase-raw/5',
                      'imageTimestampSource': 'ARFrame.timestamp',
                      'accelerometerTimestampSource':
                          'CMAccelerometerData.timestamp',
                      'gyroscopeTimestampSource': 'CMGyroData.timestamp',
                      'downsampleFactor': n,
                      'downsampleFormula': kVioShadowDownsampleFormula,
                      'cameraTimeOffsetSeconds': b.cameraTimeOffsetSeconds,
                      'cameraTimeOffsetProvenance':
                          b.cameraTimeOffsetProvenance.label,
                      'fx': kVio.fx,
                      'fy': kVio.fy,
                      'cx': kVio.cx,
                      'cy': kVio.cy,
                      'width': kVio.resolutionWidth,
                      'height': kVio.resolutionHeight,
                      'intrinsicsProvenance': kVio.provenance.label,
                      'extrinsicsProvenance': ext.provenance.label,
                      'cameraImuExtrinsicQbc': ext.qbc,
                      'cameraImuExtrinsicPbc': ext.pbc,
                    }),
                  ),
                )
                .toString();
            _expectedIdentity = VioShadowRunIdentityExpectation(
              sessionId: _sessionId,
              sessionEpoch: _sessionEpoch,
              effectiveConfigSha256: effectiveConfigSha256,
              inputIdentitySha256: inputIdentitySha256,
              downsampleFactor: n,
              downsampleFormula: kVioShadowDownsampleFormula,
              requestedCameraHz: kVioShadowRequestedCameraHz,
              cameraTimeOffsetSeconds: b.cameraTimeOffsetSeconds,
              accelerationScale: kVioShadowAccelerationScale,
              requestedAccelerometerHz: kVioShadowRequestedAccelerometerHz,
              requestedGyroscopeHz: kVioShadowRequestedGyroscopeHz,
            );
            final XrslamRuntimeConfigFiles configFiles =
                await XrslamRuntimeConfigFiles.materialize(
                  slamYaml: slamYaml,
                  deviceYaml: deviceYaml,
                );
            _runtimeConfigFiles = configFiles;
            final IosShadowStartReceipt startReceipt = await _timebase
                .slamStart(
                  slamConfigPath: configFiles.slamFile.path,
                  deviceConfigPath: configFiles.deviceFile.path,
                  sessionId: _sessionId,
                  sessionEpoch: _sessionEpoch,
                  effectiveConfigSha256: effectiveConfigSha256,
                  inputIdentitySha256: inputIdentitySha256,
                  downsampleFactor: n,
                  downsampleFormula: kVioShadowDownsampleFormula,
                  requestedCameraHz: kVioShadowRequestedCameraHz,
                  cameraTimeOffsetSeconds: b.cameraTimeOffsetSeconds,
                  accelerationScale: kVioShadowAccelerationScale,
                  requestedAccelerometerHz: kVioShadowRequestedAccelerometerHz,
                  requestedGyroscopeHz: kVioShadowRequestedGyroscopeHz,
                );
            if (!_pollGate.isCurrent(token)) return;
            final Map<String, Object?>? directSnapshot = startReceipt.snapshot;
            final VioShadowHealthSummary? startProbe = directSnapshot == null
                ? null
                : VioShadowHealthSummary.fromWire(
                    directSnapshot,
                    expectedIdentity: _expectedIdentity,
                  );
            final bool trustedStart =
                startReceipt.accepted &&
                startProbe != null &&
                startProbe.schemaValid &&
                startProbe.identity.valid &&
                startProbe.state == 'running' &&
                startProbe.sessionGeneration == startReceipt.generation;
            _feedStarted = trustedStart;
            if (trustedStart) {
              _lifecycleUpgraded = true;
              _trustedRunningGeneration = startReceipt.generation;
              _consumeShadowSnapshot(startReceipt.snapshot!);
            } else {
              _note(
                'slamStart receipt rejected: schema=${startReceipt.schemaValid} '
                'rc=${startReceipt.rc} generation=${startReceipt.generation} '
                'reason=${startReceipt.failureReason}',
              );
              await _timebase.slamStop();
              if (!_pollGate.isCurrent(token)) return;
              await configFiles.dispose();
              if (identical(_runtimeConfigFiles, configFiles)) {
                _runtimeConfigFiles = null;
              }
            }
            _note(
              'slamStart rc=${startReceipt.rc} generation=${startReceipt.generation} '
              'feedStarted=$_feedStarted',
            );
          }
          await _flushJoined(); // 立刻落盘,别等定时器(app 随时可能被挂起)
          if (!_pollGate.isCurrent(token)) return;
        }
      } catch (e) {
        if (!_pollGate.isCurrent(token)) return;
        _note('lifecycle 补跑失败: $e');
      }
    }

    if (_feedStarted) {
      try {
        final Map<String, Object?> sm =
            await _timebase.slamSnapshot() ?? const <String, Object?>{};
        if (!_pollGate.isCurrent(token)) return;
        _consumeShadowSnapshot(sm);
      } catch (e) {
        if (!_pollGate.isCurrent(token)) return;
        _note('slamSnapshot failed: $e');
      }
    }

    // [pw] 热必须**轮询**,不能只订阅事件流:事件只在档位变化时推,
    //   而热档位在 nominal 上稳着不变时,连跑 20 分钟会一个点都没有 ——
    //   「热曲线」要的恰恰是稳态也有点。事件流保留,用于抓变化的精确时刻。
    try {
      final ThermalSignal? th = await _thermal.snapshot();
      if (!_pollGate.isCurrent(token)) return;
      if (th != null) {
        _onThermal(th);
      } else {
        _note('thermal.snapshot returned null');
      }
    } catch (e) {
      if (!_pollGate.isCurrent(token)) return;
      _note('thermal.snapshot threw: $e');
    }
  }

  void _noteStartGate(String reason) {
    if (_lastStartGateReason == reason) return;
    _lastStartGateReason = reason;
    _note('XRSLAM_START_BLOCKED:$reason');
  }

  void _consumeShadowSnapshot(
    Map<String, Object?> sm, {
    bool requireTerminal = false,
  }) {
    int gi(String key) {
      final Object? value = sm[key];
      return value is num ? value.toInt() : -1;
    }

    VioShadowTerminalReceiptEvidence terminalReceipt =
        const VioShadowTerminalReceiptEvidence.missing();
    if (requireTerminal) {
      final Object? raw = sm['poseObservations'];
      final int generation = gi('sessionGeneration');
      if (_terminalReceiptConsumed) {
        _clearTransientShadowAccumulators();
        throw StateError('duplicate shadow terminal receipt call');
      }
      _terminalReceiptConsumed = true;
      final bool terminal =
          generation > 0 &&
          sm['state'] == 'stopped' &&
          gi('queueBacklog') == 0 &&
          gi('queueInFlight') == 0 &&
          raw is List &&
          raw.isEmpty &&
          !_trustedRunningGenerationConflict &&
          _trustedRunningGeneration != null &&
          generation == _trustedRunningGeneration;
      if (!terminal) {
        _clearTransientShadowAccumulators();
        throw StateError(
          'shadow terminal receipt invalid: state=${sm['state']} '
          'generation=$generation backlog=${gi('queueBacklog')} '
          'inflight=${gi('queueInFlight')} '
          'raw=${raw is List ? raw.length : 'missing'} '
          'runningGeneration=$_trustedRunningGeneration '
          'generationConflict=$_trustedRunningGenerationConflict',
        );
      }
      if (_terminalReceiptGeneration == generation) {
        _clearTransientShadowAccumulators();
        throw StateError('duplicate shadow terminal receipt: $generation');
      }
      _terminalReceiptGeneration = generation;
      terminalReceipt = VioShadowTerminalReceiptEvidence(
        trustedDirectSlamStopCall: true,
        consumedOnce: true,
        runningGeneration: _trustedRunningGeneration!,
        receiptGeneration: generation,
      );
    }

    final VioShadowHealthSummary identityProbe =
        VioShadowHealthSummary.fromWire(
          sm,
          expectedIdentity: _expectedIdentity,
          timebase: _timebaseEvidence,
          terminalReceipt: terminalReceipt,
        );
    final int observedGeneration = identityProbe.sessionGeneration;
    if (_trustedRunningGeneration != null &&
        observedGeneration > 0 &&
        observedGeneration != _trustedRunningGeneration) {
      _trustedRunningGenerationConflict = true;
      _shadowHealth = identityProbe;
      return;
    }

    _shadowPose.consumeSnapshot(sm);
    _shadowComparison.consumeSnapshot(sm);
    _shadowQuality.consumeSnapshot(sm);
    try {
      _shadowHealth = VioShadowHealthSummary.fromWire(
        sm,
        comparison: _shadowComparison.summary,
        quality: _shadowQuality.summary,
        pose: _shadowPose.summary,
        expectedIdentity: _expectedIdentity,
        timebase: _timebaseEvidence,
        terminalReceipt: terminalReceipt,
      );
    } finally {
      if (requireTerminal) _clearTransientShadowAccumulators();
    }

    _slamTicks.add(
      _SlamTick(
        wallMillis: DateTime.now().millisecondsSinceEpoch,
        slamState: gi('slamState'),
        poseRc:
            _shadowPose.latestClassification ==
                RawXrslamPoseClassification.valid
            ? 0
            : 2,
        imagesAccepted: gi('imagesAccepted'),
        accAccepted: gi('accAccepted'),
        landmarksUsable: gi('landmarksUsable'),
        landmarksPublished: gi('landmarksPublished'),
        mappedLandmarks: gi('mappedLandmarks'),
        trackedKeypoints: gi('trackedKeypoints'),
        degenerate:
            _shadowPose.latestClassification ==
                RawXrslamPoseClassification.degenerate
            ? 1
            : 0,
      ),
    );
  }

  void _clearTransientShadowAccumulators() {
    _shadowComparison.reset();
    _shadowQuality.reset();
    _shadowPose.reset();
  }

  VioShadowTimebaseEvidence _timebaseEvidenceFrom(
    IosTimebaseSnapshot? snapshot, {
    VioShadowTimebaseEvidence? prior,
  }) {
    if (snapshot == null) return const VioShadowTimebaseEvidence.missing();
    final IosClockBaseVerdict accelerometer = snapshot.baseOf(
      IosTimebaseSources.coreMotionAccelerometer,
    );
    final IosClockBaseVerdict gyroscope = snapshot.baseOf(
      IosTimebaseSources.coreMotionGyroscope,
    );
    final IosClockBaseVerdict camera = snapshot.baseOf(
      IosTimebaseSources.arFrame,
    );
    final bool wireAccepted =
        snapshot.schemaValid &&
        snapshot.transportLossFree &&
        snapshot.sessionId == _sessionId &&
        snapshot.sessionEpoch == _sessionEpoch &&
        snapshot.sessionGeneration == _activeTimebaseGeneration;
    final bool priorMatches =
        prior != null &&
        prior.schemaValid &&
        prior.sessionId == snapshot.sessionId &&
        prior.sessionEpoch == snapshot.sessionEpoch &&
        prior.nativeGeneration == snapshot.sessionGeneration &&
        prior.expectedNativeGeneration == _activeTimebaseGeneration;
    String carry(IosClockBaseVerdict current, String previous) =>
        current == IosClockBaseVerdict.unavailable && priorMatches
        ? previous
        : current.name;
    final String accelerometerBase = carry(
      accelerometer,
      prior?.accelerometerBase ?? IosClockBaseVerdict.unavailable.name,
    );
    final String gyroscopeBase = carry(
      gyroscope,
      prior?.gyroscopeBase ?? IosClockBaseVerdict.unavailable.name,
    );
    final String cameraBase = carry(
      camera,
      prior?.arFrameBase ?? IosClockBaseVerdict.unavailable.name,
    );
    bool? sameBase(String sensorBase) {
      const Set<String> unavailable = <String>{
        'unavailable',
        'indeterminate',
        'unknown',
      };
      if (unavailable.contains(sensorBase) ||
          unavailable.contains(cameraBase)) {
        return null;
      }
      return sensorBase == cameraBase;
    }

    return VioShadowTimebaseEvidence(
      schemaValid: wireAccepted,
      sessionId: snapshot.sessionId,
      sessionEpoch: snapshot.sessionEpoch,
      nativeGeneration: snapshot.sessionGeneration,
      expectedNativeGeneration: _activeTimebaseGeneration,
      boundShadowGeneration: _trustedRunningGeneration ?? -1,
      accelerometerBase: accelerometerBase,
      gyroscopeBase: gyroscopeBase,
      arFrameBase: cameraBase,
      accelerometerSameBaseAsCamera: sameBase(accelerometerBase),
      gyroscopeSameBaseAsCamera: sameBase(gyroscopeBase),
      // [pw] 2026-09-14 把 wireAccepted 的两个布尔输入各自摊开落盘。
      // `schemaValid: wireAccepted` 是合取,为 false 时无法回答「倒在哪一项」;
      // 这四行纯观测,判据一个字没动。
      wireSchemaValid: snapshot.schemaValid,
      wireTransportLossFree: snapshot.transportLossFree,
      wireOutOfSessionStaleObservations: snapshot.outOfSessionStaleObservations,
      wireSourceLoss: <String, Map<String, int>>{
        for (final MapEntry<String, IosSourceOffsets> e
            in snapshot.sources.entries)
          e.key: <String, int>{
            'rejected': e.value.rawSamplesRejected,
            'dropped': e.value.rawSamplesDropped,
            'attempted': e.value.rawSamplesAttempted,
            'accepted': e.value.rawSamplesAccepted,
          },
      },
    );
  }

  CameraIntrinsics? _currentSessionIntrinsics(Map<String, Object?>? wire) {
    if (wire == null ||
        wire['sessionId'] != _sessionId ||
        wire['sessionEpoch'] != _sessionEpoch ||
        wire['sessionGeneration'] != _activeTimebaseGeneration ||
        _activeTimebaseGeneration <= 0) {
      return null;
    }
    return CameraIntrinsics.fromWire(wire);
  }

  void _note(String msg) {
    if (_errors.length < 200) _errors.add(msg);
    debugPrint('[pw][vio-diag] $msg');
  }

  /// 人可读的一行摘要 —— 直接进设备日志,不用拉文件也能先看一眼。
  String summaryLine() {
    final TimebaseTick? t = _timebaseTicks.length > 0
        ? _timebaseTicks.items.last
        : null;
    if (t == null) return '[pw][vio-diag] 尚无时基样本 (ok=$_pollOk fail=$_pollFail)';
    final String verdictStr = t.verdicts.entries
        .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
        .join(' ');
    final VioShadowHealthSummary? shadow = _shadowHealth;
    return '[pw][vio-diag] sleep=${t.accumulatedSleepSeconds.toStringAsFixed(3)}s '
        'discriminable=${t.baseDiscriminable} $verdictStr '
        '| tb=${_timebaseTicks.length} th=${_thermalTicks.length} '
        'ok=$_pollOk fail=$_pollFail err=${_errors.length} '
        '${shadow == null ? "" : " | shadow state=${shadow.state} "
                  "valid=${shadow.runValid} overflow=${shadow.shadowOverflowDrops} "
                  "img=${shadow.images.accepted}/${shadow.images.attempted} "
                  "pose=${shadow.pose.valid}/${shadow.pose.totalAttempts} "
                  "accounting=${shadow.allAccountingConserved}"}';
  }

  Map<String, Object?> report() => <String, Object?>{
    'schema': 'pw.vio.diagnostics/3',
    'startedAtMillis': _startedAtMillis,
    'generatedAtMillis': DateTime.now().millisecondsSinceEpoch,
    'running': _running,
    'poll': <String, Object?>{
      'intervalMs': pollInterval.inMilliseconds,
      'ok': _pollOk,
      'fail': _pollFail,
    },
    'ring': <String, Object?>{
      'capacity': ringCapacity,
      'timebaseKept': _timebaseTicks.length,
      'timebaseDropped': _timebaseTicks.dropped,
      'thermalKept': _thermalTicks.length,
      'thermalDropped': _thermalTicks.dropped,
      'slamKept': _slamTicks.length,
      'slamDropped': _slamTicks.dropped,
    },
    'shadowHealth': _shadowHealth?.toJson(),
    'errors': _errors,
    'timebase': _timebaseTicks.items
        .map((TimebaseTick t) => t.toJson())
        .toList(growable: false),
    'slam': _slamTicks.items
        .map((_SlamTick t) => t.toJson())
        .toList(growable: false),
    'thermal': _thermalTicks.items
        .map((ThermalTick t) => t.toJson())
        .toList(growable: false),
  };

  Future<File?> _flushJoined() {
    final Future<File?>? active = _flushInFlight;
    if (active != null) return active;
    late final Future<File?> next;
    next = flush().whenComplete(() {
      if (identical(_flushInFlight, next)) _flushInFlight = null;
    });
    _flushInFlight = next;
    return next;
  }

  /// 落盘。写临时文件再 rename,避免拉走时读到写了一半的 JSON。
  Future<File?> flush() async {
    debugPrint(summaryLine());
    try {
      final Directory docs = _documentsDirProvider != null
          ? await _documentsDirProvider()
          : await _defaultDocumentsDir();
      final Directory dir = Directory('${docs.path}/vio_diagnostics');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final File tmp = File('${dir.path}/latest.json.tmp');
      final File out = File('${dir.path}/latest.json');
      tmp.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(report()),
      );
      // [pw] 原来这里先 deleteSync(out) 再 rename —— 那制造了一个**文件不存在的
      //   窗口**,实测拉数据时撞上过一次 `no such file`。POSIX 的 rename() 本身
      //   就是原子替换,不需要先删;先删反而在 rename 失败时把旧数据也弄丢了。
      tmp.renameSync(out.path);
      return out;
    } catch (e) {
      _note('flush failed: $e');
      return null;
    }
  }

  // path_provider 本来就是产品依赖(main.dart 已在用),没必要为了"少一个依赖"
  // 去手推 HOME —— 那条路在沙箱路径变更时会静默指错目录。
  Future<Directory> _defaultDocumentsDir() =>
      getApplicationDocumentsDirectory();
}
