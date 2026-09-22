// pw_focus_ffi.dart —— **对焦三臂**的 Dart 侧绑定。
//
// 对应 `ios/Runner/PwFocusArms.swift` 的五个 C ABI 出口:
//   `pw_camera_slot_focus_arm(int32 arm) -> int32`
//   `pw_camera_slot_focus_state(double* out16) -> int32`
//   `pw_camera_slot_focus_prepare(int32 mode) -> int32`
//   `pw_camera_slot_focus_series(double* out, int32 capSamples) -> int32`
//   `pw_camera_slot_focus_report(char* out, int32 cap) -> int32`
//
// ══ 三臂是什么 ═══════════════════════════════════════════════════════════
//   A 对照 = 现状锁焦 0.835(默认臂;不传 `-PWFocusArm` 就是它)
//   B 苹果 AF = `.continuousAutoFocus` + `.near` + 对焦区域框住物体
//   C 我们的 CDAF = `vendor/pw_af/` 的状态机驱动 `setFocusModeLocked`
// 判决书附录 B.3:`docs/research/autofocus_algorithm_survey_20260922.md`。
//
// ══ 降级风格与 `pw_camera_photo_ffi.dart` 一致 ═══════════════════════════
// 符号查不到(模拟器 / 单测 / 旧二进制)**返回 null,不抛**。台架页据此把
// 「这条路没编进去」如实写进 manifest,而不是崩在启动路径上。

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

typedef _ArmNative = ffi.Int32 Function(ffi.Int32);
typedef _ArmDart = int Function(int);
typedef _StateNative = ffi.Int32 Function(ffi.Pointer<ffi.Double>);
typedef _StateDart = int Function(ffi.Pointer<ffi.Double>);
typedef _PrepareNative = ffi.Int32 Function(ffi.Int32);
typedef _PrepareDart = int Function(int);
typedef _SeriesNative = ffi.Int32 Function(ffi.Pointer<ffi.Double>, ffi.Int32);
typedef _SeriesDart = int Function(ffi.Pointer<ffi.Double>, int);
typedef _ReportNative = ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Int32);
typedef _ReportDart = int Function(ffi.Pointer<ffi.Char>, int);

/// 三臂。`rawValue` 与 Swift 的 `PwFocusArm` 逐一对应,顺序是冻结的。
enum PwFocusArm {
  a(0, 'a', 'a_locked_baseline', 'A 对照:锁焦 0.835'),
  b(1, 'b', 'b_apple_af', 'B 苹果 AF:continuousAutoFocus + near + 对焦区域'),
  c(2, 'c', 'c_pw_af_cdaf', 'C 我们的 CDAF:pw_af 驱动 setFocusModeLocked');

  const PwFocusArm(this.rawValue, this.flag, this.label, this.describe);

  final int rawValue;

  /// 启动参数里写的那个字母:`-PWFocusArm a|b|c`。
  final String flag;
  final String label;
  final String describe;

  static PwFocusArm? fromRaw(int raw) {
    for (final PwFocusArm a in PwFocusArm.values) {
      if (a.rawValue == raw) return a;
    }
    return null;
  }

  /// 把启动参数的原文解析成臂。**解析规则与 Swift 侧同源**(那边是权威,
  /// 这里只是为了让页面在符号不在时也能显示「打算用哪个臂」)。
  /// 认不出来返回 null —— 不猜。
  static PwFocusArm? parse(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'a':
      case '0':
      case 'locked':
      case 'baseline':
        return PwFocusArm.a;
      case 'b':
      case '1':
      case 'apple':
      case 'apple_af':
        return PwFocusArm.b;
      case 'c':
      case '2':
      case 'cdaf':
      case 'pw_af':
        return PwFocusArm.c;
      default:
        return null;
    }
  }
}

/// 臂是从哪儿来的。与 Swift 的 `PwFocusArmSource` 对应。
enum PwFocusArmSource {
  defaultNoArgument(0, 'default_no_argument'),
  launchArgument(1, 'launch_argument(-PWFocusArm)'),
  explicitApi(2, 'explicit_api');

  const PwFocusArmSource(this.rawValue, this.label);
  final int rawValue;
  final String label;

  static PwFocusArmSource fromRaw(int raw) {
    for (final PwFocusArmSource s in PwFocusArmSource.values) {
      if (s.rawValue == raw) return s;
    }
    return PwFocusArmSource.defaultNoArgument;
  }
}

/// 快门前那一次对焦的进度。与 Swift 的 `PwFocusPrepareState` 对应。
enum PwFocusPrepareState {
  idle(0, 'idle'),
  running(1, 'running'),
  doneOk(2, 'done_ok'),
  doneFailed(3, 'done_failed'),
  timeout(4, 'timeout'),
  unsupported(5, 'unsupported_arm_a'),
  error(6, 'error');

  const PwFocusPrepareState(this.rawValue, this.label);
  final int rawValue;
  final String label;

  /// 还在跑就继续等;其余一律是终态。
  bool get isTerminal => this != PwFocusPrepareState.running;

  static PwFocusPrepareState fromRaw(int raw) {
    for (final PwFocusPrepareState s in PwFocusPrepareState.values) {
      if (s.rawValue == raw) return s;
    }
    return PwFocusPrepareState.error;
  }
}

/// 一帧的对焦快照(表 B 的一条)。
class PwFocusSample {
  const PwFocusSample({
    required this.t,
    required this.lensPosition,
    required this.focusMeasure,
    required this.isAdjustingFocus,
    required this.armState,
    required this.meanLuma,
  });

  /// 帧 PTS 秒(host clock,与照片 sidecar 的 `t` 同域)。
  final double t;

  /// `AVCaptureDevice.lensPosition` 0…1。🔴 **0 = 最近、1 = 最远**
  /// (Apple 头文件原文),与直觉相反;-1 = 那一刻还没有设备。
  final double lensPosition;

  /// Tenengrad,ROI 内均值。越大越清晰。
  final double focusMeasure;

  final bool isAdjustingFocus;

  /// A 臂恒 0;B 臂 0/1 = 是否在调焦;C 臂 = `PwAfState`
  /// (0 Idle / 1 Scanning / 2 Focused / 3 Failed)。
  final int armState;

  final double meanLuma;

  Map<String, Object?> toJson() => <String, Object?>{
        't': t,
        'lens': lensPosition,
        'fm': focusMeasure,
        'adj': isAdjustingFocus ? 1 : 0,
        'st': armState,
        'luma': meanLuma,
      };
}

/// `pw_camera_slot_focus_state` 那 16 个 double 的解读。
class PwFocusState {
  const PwFocusState({
    required this.arm,
    required this.armSource,
    required this.lensPosition,
    required this.focusMeasure,
    required this.isAdjustingFocus,
    required this.armState,
    required this.prepareState,
    required this.prepareElapsedMs,
    required this.minimumFocusDistanceMm,
    required this.framesMeasured,
    required this.seriesPending,
    required this.seriesDropped,
    required this.roiX,
    required this.roiY,
    required this.roiWidth,
    required this.roiHeight,
  });

  final PwFocusArm? arm;
  final PwFocusArmSource armSource;
  final double lensPosition;
  final double focusMeasure;
  final bool isAdjustingFocus;
  final int armState;
  final PwFocusPrepareState prepareState;
  final double prepareElapsedMs;

  /// 🔴 `AVCaptureDevice.minimumFocusDistance`,**毫米,-1 = 未知**
  /// (Apple 头文件原文)。判决书附录 A.4:它决定 10 cm 档在主摄上能不能成立
  /// —— 主摄最近对焦距离若 > 10 cm,那一档必须切超广角(换镜头换内参)。
  final int minimumFocusDistanceMm;

  final int framesMeasured;
  final int seriesPending;
  final int seriesDropped;
  final int roiX;
  final int roiY;
  final int roiWidth;
  final int roiHeight;

  static PwFocusState parse(List<double> v) => PwFocusState(
        arm: PwFocusArm.fromRaw(v[0].toInt()),
        armSource: PwFocusArmSource.fromRaw(v[1].toInt()),
        lensPosition: v[2],
        focusMeasure: v[3],
        isAdjustingFocus: v[4] != 0,
        armState: v[5].toInt(),
        prepareState: PwFocusPrepareState.fromRaw(v[6].toInt()),
        prepareElapsedMs: v[7],
        minimumFocusDistanceMm: v[8].toInt(),
        framesMeasured: v[9].toInt(),
        seriesPending: v[10].toInt(),
        seriesDropped: v[11].toInt(),
        roiX: v[12].toInt(),
        roiY: v[13].toInt(),
        roiWidth: v[14].toInt(),
        roiHeight: v[15].toInt(),
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'arm': arm?.label,
        'arm_source': armSource.label,
        'lens_position': lensPosition,
        'focus_measure': focusMeasure,
        'is_adjusting_focus': isAdjustingFocus,
        'arm_state': armState,
        'prepare_state': prepareState.label,
        'prepare_elapsed_ms': prepareElapsedMs,
        'minimum_focus_distance_mm': minimumFocusDistanceMm,
        'frames_measured': framesMeasured,
        'series_pending': seriesPending,
        'series_dropped': seriesDropped,
        'roi_pixels': <String, Object?>{
          'x': roiX,
          'y': roiY,
          'w': roiWidth,
          'h': roiHeight,
        },
      };
}

/// 原生对焦三臂的 Dart 门面。
abstract final class PwFocus {
  static ffi.DynamicLibrary get _lib => ffi.DynamicLibrary.process();

  /// `focus_state` 的固定宽度。改了要同时改 Swift 那边。
  static const int stateSlots = 16;

  /// 一条时间序列样本占几个 double。同上。
  static const int sampleSlots = 6;

  /// 一次 drain 最多取多少条。30 fps 下 1 秒 30 条,512 有巨大余量。
  static const int drainCapacity = 512;

  /// report JSON 的缓冲上限。能力位 + notes,实测几百字节;64 KiB 是充裕上限。
  static const int reportCapacity = 65536;

  static bool _looked = false;
  static _ArmDart? _arm;
  static _StateDart? _state;
  static _PrepareDart? _prepare;
  static _SeriesDart? _series;
  static _ReportDart? _report;

  static void _lookup() {
    if (_looked) return;
    _looked = true;
    try {
      _arm = _lib.lookupFunction<_ArmNative, _ArmDart>(
          'pw_camera_slot_focus_arm');
      _state = _lib.lookupFunction<_StateNative, _StateDart>(
          'pw_camera_slot_focus_state');
      _prepare = _lib.lookupFunction<_PrepareNative, _PrepareDart>(
          'pw_camera_slot_focus_prepare');
      _series = _lib.lookupFunction<_SeriesNative, _SeriesDart>(
          'pw_camera_slot_focus_series');
      _report = _lib.lookupFunction<_ReportNative, _ReportDart>(
          'pw_camera_slot_focus_report');
    } catch (_) {
      // 没链上就保持 null —— 调用方如实记录,不崩。
    }
  }

  /// 五个符号是否都在。
  static bool get available {
    _lookup();
    return _arm != null &&
        _state != null &&
        _prepare != null &&
        _series != null &&
        _report != null;
  }

  /// 读当前臂(不改)。`null` = 符号不在。
  static PwFocusArm? currentArm() {
    _lookup();
    final int? raw = _arm?.call(-1);
    return raw == null ? null : PwFocusArm.fromRaw(raw);
  }

  /// 显式设臂。**只在相机没起来时生效**(中途换臂会让一条序列里混两种配置)。
  /// 返回设置后的臂;`null` = 符号不在;设置被拒时原生返回 -2 ⇒ 这里返回 null。
  static PwFocusArm? setArm(PwFocusArm arm) {
    _lookup();
    final int? raw = _arm?.call(arm.rawValue);
    return raw == null || raw < 0 ? null : PwFocusArm.fromRaw(raw);
  }

  static final ffi.Pointer<ffi.Double> _stateOut =
      calloc<ffi.Double>(stateSlots);
  static final ffi.Pointer<ffi.Double> _seriesOut =
      calloc<ffi.Double>(drainCapacity * sampleSlots);
  static final ffi.Pointer<ffi.Char> _reportOut =
      calloc<ffi.Char>(reportCapacity);

  /// 当前状态。`null` = 符号不在。
  static PwFocusState? state() {
    _lookup();
    final _StateDart? f = _state;
    if (f == null) return null;
    if (f(_stateOut) != 0) return null;
    return PwFocusState.parse(
        List<double>.generate(stateSlots, (int i) => _stateOut[i]));
  }

  /// 受理一次「拍之前先对焦」。A 臂立刻回 `unsupported`(它本来就不动镜头)。
  static PwFocusPrepareState? prepareBegin() {
    _lookup();
    final int? raw = _prepare?.call(1);
    return raw == null ? null : PwFocusPrepareState.fromRaw(raw);
  }

  /// 轮询一次。超时的上限在原生侧(B 臂 2 s、C 臂 3 s),这里不重复实现。
  static PwFocusPrepareState? preparePoll() {
    _lookup();
    final int? raw = _prepare?.call(0);
    return raw == null ? null : PwFocusPrepareState.fromRaw(raw);
  }

  /// 拍完之后把臂放回常时状态(B 臂回 `.continuousAutoFocus`、C 臂回连续档)。
  static void prepareEnd() {
    _lookup();
    _prepare?.call(2);
  }

  /// 取走一批时间序列(FIFO,取走即消费)。符号不在返回空表。
  static List<PwFocusSample> drainSeries() {
    _lookup();
    final _SeriesDart? f = _series;
    if (f == null) return const <PwFocusSample>[];
    final int n = f(_seriesOut, drainCapacity);
    if (n <= 0) return const <PwFocusSample>[];
    return List<PwFocusSample>.generate(n, (int i) {
      final int b = i * sampleSlots;
      return PwFocusSample(
        t: _seriesOut[b],
        lensPosition: _seriesOut[b + 1],
        focusMeasure: _seriesOut[b + 2],
        isAdjustingFocus: _seriesOut[b + 3] != 0,
        armState: _seriesOut[b + 4].toInt(),
        meanLuma: _seriesOut[b + 5],
      );
    });
  }

  /// 原生侧的 report JSON 原文(能力位 / 注释 / ROI / 臂来源)。
  /// `null` = 符号不在或放不下。
  static String? reportJson() {
    _lookup();
    final _ReportDart? f = _report;
    if (f == null) return null;
    final int n = f(_reportOut, reportCapacity);
    if (n < 0) return null;
    return _reportOut.cast<Utf8>().toDartString();
  }
}
