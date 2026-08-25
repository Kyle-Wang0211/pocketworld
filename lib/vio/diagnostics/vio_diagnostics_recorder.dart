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

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../thermal/thermal_signal.dart';
import '../thermal/vio_thermal_channel.dart';
import '../ffi/xrslam_config.dart';
import '../ffi/xrslam_smoke.dart';
import '../timebase/ios_timebase_channel.dart';

/// 定长环形缓冲。满了丢**最老**的 —— 这里丢的是诊断样本,不是交付数据,
/// 与「fail-safe 只许推迟不许丢数据」的铁律不冲突(那条管的是采集帧)。
/// SLAM 状态的一次采样。字段刻意少 —— 只留能定位「何时推进 / 是否卡住」的,
/// 900 个点乘以整条快照会把落盘文件撑大好几倍。
class _SlamTick {
  const _SlamTick({
    required this.wallMillis,
    required this.slamState,
    required this.poseRc,
    required this.imagesPushed,
    required this.accPushed,
    required this.landmarksUsable,
    required this.landmarksPublished,
    required this.mappedLandmarks,
    required this.trackedKeypoints,
    required this.degenerate,
  });

  final int wallMillis;
  final int slamState;
  final int poseRc;
  final int imagesPushed;
  final int accPushed;
  final int landmarksUsable;
  final int landmarksPublished;
  final int mappedLandmarks;
  final int trackedKeypoints;
  final int degenerate;

  Map<String, Object?> toJson() => <String, Object?>{
        'wallMillis': wallMillis,
        'slamState': slamState,
        'poseRc': poseRc,
        'imagesPushed': imagesPushed,
        'accPushed': accPushed,
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
}

/// 一条时基采样点。
class TimebaseTick {
  const TimebaseTick({
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
  })  : _timebase = timebase ?? IosTimebaseChannel(),
        _thermal = thermal ?? VioThermalChannel(),
        _documentsDirProvider = documentsDirProvider;

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

  late final _Ring<TimebaseTick> _timebaseTicks = _Ring<TimebaseTick>(ringCapacity);
  late final _Ring<ThermalTick> _thermalTicks = _Ring<ThermalTick>(ringCapacity);
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
  int _startedAtMillis = 0;
  int _pollOk = 0;
  XrslamSmokeResult? _smoke;

  /// 是否已经用**真内参**重跑过一次生命周期。
  /// 启动时 ARKit 还没起来 ⇒ 第一次必然是 PLACEHOLDER;等 ARKit 出帧后补跑一次。
  /// 这也是产品上正确的生命周期:没在拍摄就不该有 VIO 实例占资源。
  bool _lifecycleUpgraded = false;

  /// 喂帧是否已启动。XRSLAM 是全局单例,只能起一次。
  bool _feedStarted = false;

  /// 最近一次喂帧快照(统计 + 位姿 + 健康)。
  Map<String, Object?>? _slam;
  int _pollFail = 0;

  bool get isRunning => _running;

  /// 只在 iOS 上有原生实现;其他平台直接不启动而不是假装在跑。
  bool get _supported => !kIsWeb && Platform.isIOS;

  Future<void> start() async {
    if (_running) return;
    if (!_supported) {
      _note('unsupported-platform: 仅 iOS 有原生实现,未启动');
      return;
    }
    _running = true;
    _startedAtMillis = DateTime.now().millisecondsSinceEpoch;

    try {
      await _timebase.beginSession();
    } catch (e) {
      _note('timebase.beginSession failed: $e');
    }
    // [pw] 必须显式启动 CoreMotion 投喂。原先 noteCoreMotion 只挂在
    //   PwVioCapability 的 IMU probe 里,而那个 probe 从没有人调用 ——
    //   真机第一测因此只拿到 arFrame 一路,而域错配是**两路对比**才成立的。
    try {
      final bool ok = await _timebase.startCoreMotionFeed();
      if (!ok) _note('startCoreMotionFeed: deviceMotion 不可用');
    } catch (e) {
      _note('startCoreMotionFeed failed: $e');
    }
    try {
      await _thermal.start();
    } catch (e) {
      _note('thermal.start failed: $e');
    }

    _thermalSub = _thermal.signals().listen(
      _onThermal,
      onError: (Object e) => _note('thermal stream error: $e'),
      cancelOnError: false,
    );

    // [pw] FFI 通路最小验证。只跑一次 —— 它不随时间变化,
    //   而且是**唯一**不需要配置和数据就能验的调用。不通的话后面所有
    //   XRSLAM 集成工作都建立在流沙上,越早知道越好。
    // [pw] 先问原生要真内参。ARKit 没跑过帧就拿不到 —— 那时 fromWire 返回 null,
    //   生命周期会退到 PLACEHOLDER 并**如实标出来**,不编一组数糊弄过去。
    CameraIntrinsics? k;
    try {
      k = CameraIntrinsics.fromWire(await _timebase.latestIntrinsics());
      _note(k == null
          ? 'intrinsics: 拿不到(ARKit 未跑帧或值不合理)⇒ 落 PLACEHOLDER'
          : 'intrinsics: fx=${k.fx.toStringAsFixed(2)} fy=${k.fy.toStringAsFixed(2)} '
              'cx=${k.cx.toStringAsFixed(2)} cy=${k.cy.toStringAsFixed(2)} '
              '@${k.resolutionWidth}x${k.resolutionHeight} [device-api]');
    } catch (e) {
      _note('latestIntrinsics failed: $e');
    }

    try {
      _smoke = runXrslamLifecycle(intrinsics: k);
      _note('xrslam smoke: $_smoke');
    } catch (e) {
      _note('xrslam smoke threw(不该发生,内部已兜): $e');
    }

    _poll = Timer.periodic(pollInterval, (_) => _tick());
    _flush = Timer.periodic(flushInterval, (_) => flush());
    await _tick(); // 立刻取一条,不用等第一个间隔

    // [pw] **立刻落一次盘**,不等 20s 定时器。
    //   实测踩过:用 devicectl 启动后手机没人操作、屏幕一熄,iOS 就把 app 挂起,
    //   Dart 的 Timer 全停 ⇒ 第一次 flush 永远不来 ⇒ 拉到的永远是上一次会话的
    //   报告(设备上文件 mtime 卡在 12:37,而 12:44 的 Create/Destroy 有原生日志为证)。
    //   smoke 与 lifecycle 的结果在 t=0 就已经有了,本来也没理由等。
    await flush();
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _poll?.cancel();
    _flush?.cancel();
    await _thermalSub?.cancel();
    try {
      await _timebase.stopCoreMotionFeed();
    } catch (e) {
      _note('stopCoreMotionFeed failed: $e');
    }
    try {
      await _thermal.stop();
    } catch (e) {
      _note('thermal.stop failed: $e');
    }
    await flush();
  }

  void _onThermal(ThermalSignal s) {
    _thermalTicks.add(ThermalTick(
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
    ));
  }

  Future<void> _tick() async {
    if (!_running) return;
    try {
      final IosTimebaseSnapshot? snap = await _timebase.snapshot();
      if (snap == null) {
        _pollFail++;
        _note('timebase.snapshot returned null');
        return;
      }
      _pollOk++;
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
      _timebaseTicks.add(TimebaseTick(
        wallMillis: DateTime.now().millisecondsSinceEpoch,
        uptimeRawSeconds: snap.uptimeRawSeconds,
        monotonicSeconds: snap.monotonicSeconds,
        accumulatedSleepSeconds: snap.accumulatedSleepSeconds,
        sessionSleepDeltaSeconds: snap.sessionSleepDeltaSeconds,
        clockPairReadCostSeconds: snap.clockPairReadCostSeconds,
        baseDiscriminable: snap.baseDiscriminable,
        verdicts: verdicts,
        offsets: offsets,
      ));
    } catch (e) {
      _pollFail++;
      _note('timebase.snapshot threw: $e');
    }

    // [pw] 内参就位后补跑一次生命周期。
    //   启动路径上 ARKit 还没出帧,内参必然拿不到 ⇒ 第一次跑的是 PLACEHOLDER 配置。
    //   这里等真内参到位后**只补跑一次**,把 cam0.intrinsics 从 PLACEHOLDER
    //   升成 device-api。不重复跑 —— 每次 Create/Destroy 都有构造析构开销。
    if (!_lifecycleUpgraded) {
      try {
        final CameraIntrinsics? k =
            CameraIntrinsics.fromWire(await _timebase.latestIntrinsics());
        if (k != null) {
          _lifecycleUpgraded = true;
          _note('intrinsics 就位: '
              'fx=${k.fx.toStringAsFixed(2)} fy=${k.fy.toStringAsFixed(2)} '
              'cx=${k.cx.toStringAsFixed(2)} cy=${k.cy.toStringAsFixed(2)} '
              '@${k.resolutionWidth}x${k.resolutionHeight}');
          // 先用 Dart 侧的 lifecycle 验一遍配置能被接受(它会 Create 再 Destroy),
          // 然后交给原生 feeder 真正跑起来 —— 喂帧必须在原生侧,零拷贝。
          _smoke = runXrslamLifecycle(intrinsics: k);
          if (!_feedStarted && _smoke!.createRc == 1) {
            // ⚠️ 内参必须跟着降采样等比缩放。原生侧把 1920×1440 降成 640×480
            //   喂给 VIO,而这里若还用全分辨率的 fx/cx,整条位姿链会系统性错
            //   **而且不报错** —— 这是最典型的静默失效。
            //   上游 18 个 iPhone 配置全部是 640×480,这是回到它们的口径。
            // 🔑 倍数从 Swift 侧取,不在这里写死 —— 唯一真源是
            //   PwVioSlamFeeder.kVioDownsampleFactor。两边各写一份常量,
            //   改了一边忘另一边就是内参与实际图不匹配:整条位姿链系统性错
            //   **而且不报错**。
            final int? n = await _timebase.vioDownsampleFactor();
            if (n == null || n < 1) {
              _note('❌ 取不到降采样倍数 ⇒ 不启动 SLAM(宁可不跑,也不跑在'
                  '内参与图像不匹配的状态上)');
              await flush();
              return;
            }
            final bool divisible =
                k.resolutionWidth % n == 0 && k.resolutionHeight % n == 0;
            if (!divisible) {
              _note('❌ ${k.resolutionWidth}x${k.resolutionHeight} 不是 $n 的'
                  '整数倍 ⇒ Swift 侧会拒绝每一帧,这里也不启动');
              await flush();
              return;
            }
            final CameraIntrinsics kVio =
                k.scaledTo(k.resolutionWidth ~/ n, k.resolutionHeight ~/ n);
            _note('VIO 内参(降采样后): fx=${kVio.fx.toStringAsFixed(2)} '
                'cx=${kVio.cx.toStringAsFixed(2)} '
                '@${kVio.resolutionWidth}x${kVio.resolutionHeight}  '
                '(降采样 ${n}x;上游 iPhone 口径就是 640x480 fx≈448.97)');
            // 🔑 相机-IMU 外参。此前这里用的是默认的 iosPlaceholder ——
            //   单位四元数,而真值是 180 度翻转。真机实测那样喂 5731 帧
            //   一个位姿都没出(slamState 恒 0),前端跟踪却完全正常。
            //   上游 xrslam-ios/visualizer/configs 里就有全部 18 款 iPhone
            //   的标定值,我却在注释里写了"iOS 无 API ⇒ 真缺口"。
            final String? machine = await _timebase.deviceMachine();
            final CameraImuExtrinsic ext =
                CameraImuExtrinsic.forIosMachine(machine);
            _note('机型 ${machine ?? "未知"} -> 外参 '
                '${ext.provenance == FieldProvenance.deviceApi
                    ? "上游标定值" : "分量中位数回退"}  '
                'q_bc=${ext.qbc}  p_bc=${ext.pbc}');
            final XrslamConfigBuilder b =
                XrslamConfigBuilder(intrinsics: kVio, extrinsic: ext);
            // runHz=0 ⇒ 每帧求解,不降频。
            // EuRoC 实测推翻了「降到 10Hz」那条:只在最简单序列上受益,
            // 难序列 ATE 恶化最多 +52%,尺度误差同向恶化 ⇒ 按无损铁律出局。
            final int rc = await _timebase.slamStart(
              slamYaml: b.buildSlamConfigYaml(),
              deviceYaml: b.buildDeviceConfigYaml(),
              runHz: 0.0,
            );
            _feedStarted = (rc == 1);
            _note('slamStart rc=$rc (1=成功) feedStarted=$_feedStarted');
          }
          await flush();   // 立刻落盘,别等定时器(app 随时可能被挂起)
        }
      } catch (e) {
        _note('lifecycle 补跑失败: $e');
      }
    }

    if (_feedStarted) {
      try {
        _slam = await _timebase.slamSnapshot();
        final Map<String, Object?> sm = _slam ?? const <String, Object?>{};
        int gi(String k) {
          final Object? v = sm[k];
          return v is num ? v.toInt() : -1;
        }
        _slamTicks.add(_SlamTick(
          wallMillis: DateTime.now().millisecondsSinceEpoch,
          slamState: gi('slamState'),
          poseRc: gi('poseRc'),
          imagesPushed: gi('imagesPushed'),
          accPushed: gi('accPushed'),
          landmarksUsable: gi('landmarksUsable'),
          landmarksPublished: gi('landmarksPublished'),
          mappedLandmarks: gi('mappedLandmarks'),
          trackedKeypoints: gi('trackedKeypoints'),
          degenerate: gi('latestPoseDegenerate'),
        ));
      } catch (e) {
        _note('slamSnapshot failed: $e');
      }
    }

    // [pw] 热必须**轮询**,不能只订阅事件流:事件只在档位变化时推,
    //   而热档位在 nominal 上稳着不变时,连跑 20 分钟会一个点都没有 ——
    //   「热曲线」要的恰恰是稳态也有点。事件流保留,用于抓变化的精确时刻。
    try {
      final ThermalSignal? th = await _thermal.snapshot();
      if (th != null) {
        _onThermal(th);
      } else {
        _note('thermal.snapshot returned null');
      }
    } catch (e) {
      _note('thermal.snapshot threw: $e');
    }
  }

  void _note(String msg) {
    if (_errors.length < 200) _errors.add(msg);
    debugPrint('[pw][vio-diag] $msg');
  }

  /// 人可读的一行摘要 —— 直接进设备日志,不用拉文件也能先看一眼。
  String summaryLine() {
    final TimebaseTick? t =
        _timebaseTicks.length > 0 ? _timebaseTicks.items.last : null;
    if (t == null) return '[pw][vio-diag] 尚无时基样本 (ok=$_pollOk fail=$_pollFail)';
    final String verdictStr = t.verdicts.entries
        .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
        .join(' ');
    return '[pw][vio-diag] sleep=${t.accumulatedSleepSeconds.toStringAsFixed(3)}s '
        'discriminable=${t.baseDiscriminable} $verdictStr '
        '| tb=${_timebaseTicks.length} th=${_thermalTicks.length} '
        'ok=$_pollOk fail=$_pollFail err=${_errors.length} '
        'ffi=${_smoke?.ok == true ? _smoke!.version : "FAIL"}'
        '${_slam == null ? "" : " | feed img=${_slam!["imagesPushed"]} "
            "run=${_slam!["runCalls"]} state=${_slam!["slamState"]} "
            "trk=${_slam!["trackedKeypoints"]} lm=${_slam!["mappedLandmarks"]} "
            "duty=${_slam!["dutyCycle"]} behind=${_slam!["behindMax"]}"}';
  }

  Map<String, Object?> report() => <String, Object?>{
        'schema': 'pw.vio.diagnostics/1',
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
        'xrslamSmoke': _smoke?.toJson(),
        'slamFeed': _slam,
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
      tmp.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(report()));
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
  Future<Directory> _defaultDocumentsDir() => getApplicationDocumentsDirectory();
}
