// xrslam_live_ffi.dart —— 读**原生活体通路**(`PwXrslamLive.swift`)的结果。
//
// ══ 🔴 这个文件**不推任何数据** ═══════════════════════════════════════════
// 喂料(相机帧 / 陀螺 / 加速度)全部在原生侧完成:三个回调**只做有界入队**,
// 一条串行 worker 按到达顺序消费(生产 `PwVioSlamFeeder.swift:9` 的做法 ——
// "回调只尝试有界入队,绝不等算法")。Dart 只做两件事:
//   ① 把两份 YAML 写成文件、把**路径**交给原生 create;
//   ② 每渲染帧读一次最新结果。
//
// 上一版把喂料放在 Dart 里(轮询 `NativeImu.latest()` + 每渲染帧推一帧),
// 真机实测位姿 45 秒发散到 1.6 km。三处偏离与证据见 `PwXrslamLive.swift` 文件头。
//
// ══ 跨端口径 ═════════════════════════════════════════════════════════════
// 底下是 `vendor/xrslam/transport/PwXrslamTransportCore.{h,cpp}`,**iOS 与
// 安卓编的是同一个源文件**(iOS:Runner.xcodeproj Sources;安卓:
// `android_ready/native/xrslam/CMakeLists.txt:24`),安卓侧 JNI 已经暴露同样
// 三个入口(`PwXrslamTransport.cpp:39,67,73`)。每端不同的只有"传感器从哪来"
// 这一片叶子 —— 上游自己也是这么切的(`Motion.swift`/`Camera.swift` 是
// iOS 专属)。
//
// ══ 🔴 位姿口径是 CAMERA_POSE,不是 BODY_POSE ════════════════════════════
// `PWXrslamTransportPushCameraAndRunRaw` 内部读的是 `XRSLAM_RESULT_CAMERA_POSE`
// (`PwXrslamTransportCore.cpp:229`),与上游 `XRSLAM_iOS.mm:172` 一致,
// `PWXrslamTransportGetPoseMetadata` 也自报 `PW_XRSLAM_T_WORLD_CAMERA`。
// 这一条很要紧:body 与 camera 之间差一个 `q_bc`,而上游 iPhone 标定里那是
// **180° 旋转**(`configs/iphone12.yaml`:`q_bc: [-0.7071068, 0.7071068, 0, 0]`,
// w=0)。拿 body 位姿当相机位姿去驱动渲染,朝向直接错 180°。

import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart';

typedef _CreateNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, ffi.Double);
typedef _CreateDart = int Function(
    ffi.Pointer<ffi.Char>, ffi.Pointer<ffi.Char>, double);
typedef _BeginNative = ffi.Int32 Function(ffi.Double);
typedef _BeginDart = int Function(double);
typedef _VoidNative = ffi.Void Function();
typedef _VoidDart = void Function();
typedef _OutDoubleNative = ffi.Int32 Function(ffi.Pointer<ffi.Double>);
typedef _OutDoubleDart = int Function(ffi.Pointer<ffi.Double>);
typedef _OutInt64Native = ffi.Void Function(ffi.Pointer<ffi.Int64>);
typedef _OutInt64Dart = void Function(ffi.Pointer<ffi.Int64>);

/// 引擎最近一次的结果。
class XrslamLiveSnapshot {
  const XrslamLiveSnapshot({
    required this.state,
    required this.timestampSeconds,
    required this.qx,
    required this.qy,
    required this.qz,
    required this.qw,
    required this.px,
    required this.py,
    required this.pz,
    required this.hasPose,
  });

  /// `XRSLAMState` 原值。1 = `XRSLAM_STATE_TRACKING_SUCCESS`。
  final int state;
  final double timestampSeconds;
  final double qx, qy, qz, qw;
  final double px, py, pz;

  /// 是否已经出现过至少一个 TRACKING_SUCCESS 的位姿。
  final bool hasPose;
}

/// 传输层账本。**这些数来自 C++ 侧的同一本账**,不在 Dart 或 Swift 里合成
/// (`PwXrslamTransportCore.h` 原话:"Swift must not synthesize them")。
class XrslamLiveStats {
  const XrslamLiveStats({
    required this.cameraSubmitted,
    required this.cameraRunCalls,
    required this.accelerationSubmitted,
    required this.gyroscopeSubmitted,
    required this.rejectedNonMonotonic,
    required this.rejectedInvalidArgument,
    required this.rejectedNotRunning,
    required this.running,
    required this.cameraCallbacks,
    required this.cameraLockFailures,
    required this.framesOffered,
    required this.framesDropped,
    required this.imuDropped,
    required this.maxPendingFrames,
  });

  final int cameraSubmitted;
  final int cameraRunCalls;
  final int accelerationSubmitted;
  final int gyroscopeSubmitted;

  /// 🔴 单调闸拒掉的数量。相机这一路不为零 ⇒ PTS 没有严格递增;
  /// IMU 两路不为零 ⇒ 同一条样本被推了两遍(上一版的原病)。
  final int rejectedNonMonotonic;
  final int rejectedInvalidArgument;
  final int rejectedNotRunning;
  final bool running;

  /// 相机回调进来的次数(Swift 侧计)。与 [cameraSubmitted] 的差 = 被闸拒的。
  final int cameraCallbacks;
  final int cameraLockFailures;

  /// 相机回调进来的总帧数。**这是相机的真实节奏**,不受引擎快慢影响。
  final int framesOffered;

  /// 🔴 被**我们自己的有界闸**丢掉的帧 = 引擎吃不下的量,归因明确。
  /// `framesOffered - framesDropped ≈ cameraSubmitted`。
  /// 这个数大不等于坏:它说明相机没被算法堵住(生产
  /// `PwVioSlamFeeder.swift:9`:"压力不能反向控制拍照")。
  final int framesDropped;

  /// IMU 在途上限被打满的次数。**应当恒 0** —— 非 0 说明 worker 被长时间占住。
  final int imuDropped;

  /// 观察到的最大在途帧数(上限 2)。
  final int maxPendingFrames;

  @override
  String toString() => 'cam交付=$framesOffered 背压丢=$framesDropped '
      '进引擎=$cameraSubmitted run=$cameraRunCalls 在途峰值=$maxPendingFrames '
      'acc=$accelerationSubmitted gyr=$gyroscopeSubmitted imu丢=$imuDropped '
      '拒:非单调=$rejectedNonMonotonic 参数=$rejectedInvalidArgument '
      '未运行=$rejectedNotRunning lockFail=$cameraLockFailures run=$running';
}

/// [pw 2026-09-23;复核修正后] 逐帧内参这一场的账(`PwXrslamLive.intrinsicsReport`,
/// 原生 `pw_xrslam_live_intrinsics` 写 31 个 double)。
///
/// 带「C 账本」字样的数来自传输层 `PWXrslamTransportGetIntrinsicsTrace`,
/// 不在 Swift / Dart 里合成。判读:
///   · [switchEnabled] = 启动参数 `-PWPerFrameIntrinsics` 的结果(默认 on);
///     台架 A/B 用它区分两臂,必须随结果一起落盘。[switchParseFailed] = 传了但
///     解析不了、按默认 on 跑 —— 这种场次的臂名不是操作者想要的,要单独看。
///   · [attached] 只说明**宿主推了**逐帧 K,不说明引擎收下了。
///   · 引擎收下没有,只由**构建身份**判定([engineConsumesPerFrameK]:Release 构建
///     时 `stamp_runtime_identity.sh` 核过指纹后盖进 Info.plist 的臂名):
///     1 = 链的是认逐帧 K 的 gpufenothread_pfk;0 = 链的是别的臂(核不读这条扩展,
///     引擎**实际仍用 yaml 常量**);-1 = 没盖章(Debug/Profile),**无法核实**。
///   · 传输层回读(`XRSLAM_INFO_INTRINSICS`)只有一侧是结论:
///     [engineReportDiffers] > 0 ⇒ 那些帧**证明**没被收下;
///     [engineReportEqualNotEvidence] 不是「收下了」的证据 —— 不认扩展的核报的是
///     yaml K,而 yaml K 可能就是从同一来源(比如第一帧)写的,数值相等。
///   · [configResolutionMismatch] > 0 ⇒ 推送尺寸 ≠ 引擎 yaml 的 cam0.resolution,
///     那些帧没推逐帧 K。
///   · [traceSequenceMismatch] 应恒 0。
class XrslamLiveIntrinsics {
  const XrslamLiveIntrinsics({
    required this.switchEnabled,
    required this.switchSource,
    required this.frames,
    required this.attached,
    required this.notAttached,
    required this.transportRejectedInvalid,
    required this.engineReportDiffers,
    required this.engineReportEqualNotEvidence,
    required this.engineConsumesPerFrameK,
    required this.hostSwitchOff,
    required this.hostNoAttachment,
    required this.hostReferenceMismatch,
    required this.hostActiveFormatMismatch,
    required this.hostConfigResolutionMismatch,
    required this.hostConfigResolutionUnknown,
    required this.lastSource,
    required this.lastAttachedFxFyCxCy,
    required this.lastEngineFxFyCxCy,
    required this.fxMin,
    required this.fxMax,
    required this.pushedWidth,
    required this.pushedHeight,
    required this.configWidth,
    required this.configHeight,
    required this.traceSequenceMismatch,
  });

  /// 原生写出的 double 个数。
  static const int wireLength = 31;

  /// 按 `PwXrslamLive.intrinsicsReport` 的下标解析。长度不对返回 `null`。
  static XrslamLiveIntrinsics? fromWire(List<double> v) {
    if (v.length != wireLength) return null;
    return XrslamLiveIntrinsics(
      switchEnabled: v[0] != 0,
      switchSource: v[1].toInt(),
      frames: v[2].toInt(),
      attached: v[3].toInt(),
      notAttached: v[4].toInt(),
      transportRejectedInvalid: v[5].toInt(),
      engineReportDiffers: v[6].toInt(),
      engineReportEqualNotEvidence: v[7].toInt(),
      engineConsumesPerFrameK: v[8].toInt(),
      hostSwitchOff: v[9].toInt(),
      hostNoAttachment: v[10].toInt(),
      hostReferenceMismatch: v[11].toInt(),
      hostActiveFormatMismatch: v[12].toInt(),
      hostConfigResolutionMismatch: v[13].toInt(),
      hostConfigResolutionUnknown: v[14].toInt(),
      lastSource: v[15].toInt(),
      lastAttachedFxFyCxCy: List<double>.unmodifiable(v.sublist(16, 20)),
      lastEngineFxFyCxCy: List<double>.unmodifiable(v.sublist(20, 24)),
      fxMin: v[24],
      fxMax: v[25],
      pushedWidth: v[26].toInt(),
      pushedHeight: v[27].toInt(),
      configWidth: v[28].toInt(),
      configHeight: v[29].toInt(),
      traceSequenceMismatch: v[30].toInt(),
    );
  }

  final bool switchEnabled;

  /// 0 默认值 / 1 启动参数 / 2 传了但解析不了(按默认 on 跑)。
  final int switchSource;
  final int frames;

  /// C 账本:带逐帧 K 推下去的帧数(宿主推了什么,不是引擎收下了什么)。
  final int attached;

  /// C 账本:没带逐帧 K 的帧数(= yaml 常量)。
  final int notAttached;

  /// C 账本:给了但不可附加(非有限 / fx,fy ≤ 0)。
  final int transportRejectedInvalid;

  /// C 账本:推了、回读 ≠ 推的值 ⇒ 证明没被收下。
  final int engineReportDiffers;

  /// C 账本:推了、回读 == 推的值。**不是**收下的证据。
  final int engineReportEqualNotEvidence;

  /// 构建身份:1 链的核认逐帧 K / 0 不认 / -1 没盖章、无法核实。
  final int engineConsumesPerFrameK;
  final int hostSwitchOff;
  final int hostNoAttachment;
  final int hostReferenceMismatch;
  final int hostActiveFormatMismatch;

  /// 推送尺寸 ≠ 引擎 yaml 的 `cam0.resolution`。
  final int hostConfigResolutionMismatch;

  /// yaml 里读不出 `cam0.resolution`。
  final int hostConfigResolutionUnknown;

  /// 最近一帧:0 none / 1 config / 2 per_frame / 3 per_frame_not_consumed /
  /// 4 per_frame_attached_unverified(`PwPerFrameIntrinsicsSource`)。
  final int lastSource;
  final List<double> lastAttachedFxFyCxCy;
  final List<double> lastEngineFxFyCxCy;
  final double fxMin;
  final double fxMax;
  final int pushedWidth;
  final int pushedHeight;

  /// 引擎 yaml 的 `cam0.resolution`;0 = 读不出来。
  final int configWidth;
  final int configHeight;
  final int traceSequenceMismatch;

  bool get switchParseFailed => switchSource == 2;

  /// 台架 A/B 的臂名。
  String get armLabel => switchEnabled ? 'per_frame_k_on' : 'per_frame_k_off';

  static const List<String> _switchSourceLabels = <String>[
    'default',
    'launch_argument',
    'unparseable_fell_back_to_default_on',
  ];

  String get switchSourceLabel =>
      switchSource >= 0 && switchSource < _switchSourceLabels.length
          ? _switchSourceLabels[switchSource]
          : 'unknown($switchSource)';

  static const List<String> _lastSourceLabels = <String>[
    'none',
    'config',
    'per_frame',
    'per_frame_not_consumed',
    'per_frame_attached_unverified',
  ];

  String get lastSourceLabel =>
      lastSource >= 0 && lastSource < _lastSourceLabels.length
          ? _lastSourceLabels[lastSource]
          : 'unknown($lastSource)';

  String get engineConsumesLabel => switch (engineConsumesPerFrameK) {
        1 => 'build_identity_per_frame_k_arm',
        0 => 'build_identity_other_arm_ignores_per_frame_k',
        _ => 'unverifiable_no_build_identity',
      };

  Map<String, Object?> toJson() => <String, Object?>{
        'schema': 'pw.vio.per-frame-intrinsics/2',
        'arm': armLabel,
        'switch_enabled': switchEnabled,
        'switch_source': switchSourceLabel,
        'switch_parse_failed': switchParseFailed,
        'switch_launch_argument': '-PWPerFrameIntrinsics',
        'frames': frames,
        'transport_attached': attached,
        'transport_not_attached': notAttached,
        'transport_rejected_invalid': transportRejectedInvalid,
        'transport_engine_report_differs': engineReportDiffers,
        'transport_engine_report_equal_not_evidence':
            engineReportEqualNotEvidence,
        'engine_consumes_per_frame_k': engineConsumesLabel,
        'host_switch_off': hostSwitchOff,
        'host_no_attachment': hostNoAttachment,
        'host_reference_dims_mismatch': hostReferenceMismatch,
        'host_active_format_mismatch': hostActiveFormatMismatch,
        'host_config_resolution_mismatch': hostConfigResolutionMismatch,
        'host_config_resolution_unknown': hostConfigResolutionUnknown,
        'last_source': lastSourceLabel,
        'last_attached_fxfycxcy': lastAttachedFxFyCxCy,
        'last_engine_fxfycxcy': lastEngineFxFyCxCy,
        'fx_min': fxMin,
        'fx_max': fxMax,
        'pushed_width': pushedWidth,
        'pushed_height': pushedHeight,
        'config_width': configWidth,
        'config_height': configHeight,
        'trace_sequence_mismatch': traceSequenceMismatch,
      };

  @override
  String toString() => '臂=$armLabel(开关来源 $switchSourceLabel) 帧=$frames '
      '宿主推逐帧=$attached 常量=$notAttached 回读不等(证明没收下)=$engineReportDiffers '
      '回读相等(不算证据)=$engineReportEqualNotEvidence 引擎身份=$engineConsumesLabel '
      '[开关off=$hostSwitchOff 无附件=$hostNoAttachment 参照≠推送=$hostReferenceMismatch '
      'activeFormat≠推送=$hostActiveFormatMismatch yaml尺寸≠推送=$hostConfigResolutionMismatch '
      'yaml尺寸读不出=$hostConfigResolutionUnknown 传输层拒=$transportRejectedInvalid] '
      '最近=$lastSourceLabel fx[min/max]=${fxMin.toStringAsFixed(2)}/'
      '${fxMax.toStringAsFixed(2)} 推送=${pushedWidth}x$pushedHeight '
      'yaml=${configWidth}x$configHeight 序号错=$traceSequenceMismatch';
}

/// 原生活体通路的 Dart 门面。符号查不到时所有调用**降级**返回失败,不抛。
abstract final class XrslamLive {
  static ffi.DynamicLibrary get _lib => ffi.DynamicLibrary.process();

  static bool _looked = false;
  static _CreateDart? _create;
  static _BeginDart? _begin;
  static _VoidDart? _destroy;
  static _OutDoubleDart? _latest;
  static _OutInt64Dart? _stats;

  static void _lookup() {
    if (_looked) return;
    _looked = true;
    try {
      _create = _lib.lookupFunction<_CreateNative, _CreateDart>(
          'pw_xrslam_live_create');
      _begin =
          _lib.lookupFunction<_BeginNative, _BeginDart>('pw_xrslam_live_begin');
      _destroy = _lib
          .lookupFunction<_VoidNative, _VoidDart>('pw_xrslam_live_destroy');
      _latest = _lib.lookupFunction<_OutDoubleNative, _OutDoubleDart>(
          'pw_xrslam_live_latest');
      _stats = _lib.lookupFunction<_OutInt64Native, _OutInt64Dart>(
          'pw_xrslam_live_stats');
    } catch (_) {
      // 没链上就保持 null —— 上层照样能跑静止兜底。
    }
  }

  /// 符号是否都在。
  static bool get available {
    _lookup();
    return _create != null && _latest != null;
  }

  /// 建会话。**返回 1 成功 / 0 失败**(冻结的 `XRSLAMCreate` 口径),
  /// 符号不在返回 `null`。
  ///
  /// [cameraTimeOffsetSeconds] = 每机常量 c,传输层只加在相机时间戳上
  /// (`PWXrslamTransportCreateWithCameraTimeOffset`)。曝光/2 那一项**不在这里**,
  /// 它在原生侧逐帧算(`PwXrslamLive.swift` 文件头偏离 (d))。
  static int? create({
    required String slamConfigPath,
    required String deviceConfigPath,
    double cameraTimeOffsetSeconds = 0.0,
  }) {
    _lookup();
    final _CreateDart? f = _create;
    if (f == null) return null;
    final ffi.Pointer<ffi.Char> a =
        slamConfigPath.toNativeUtf8().cast<ffi.Char>();
    final ffi.Pointer<ffi.Char> b =
        deviceConfigPath.toNativeUtf8().cast<ffi.Char>();
    try {
      return f(a, b, cameraTimeOffsetSeconds);
    } finally {
      calloc.free(a);
      calloc.free(b);
    }
  }

  /// 起 IMU 并开始推送。0 成功;-1/-2 传感器不可用;-3 还没 create;
  /// **-4 相机还没起**(串行队列没登记)。
  ///
  /// 🔴 [rateHz] 默认 100 —— 上游 `Motion.init(updateInterval: 0.01)`。
  static int? begin({double rateHz = 100}) {
    _lookup();
    return _begin?.call(rateHz);
  }

  static void destroy() {
    _lookup();
    _destroy?.call();
  }

  static final ffi.Pointer<ffi.Double> _poseOut = calloc<ffi.Double>(9);
  static final ffi.Pointer<ffi.Int64> _statsOut = calloc<ffi.Int64>(14);

  /// 最新结果。符号不在返回 `null`。
  static XrslamLiveSnapshot? latest() {
    _lookup();
    final _OutDoubleDart? f = _latest;
    if (f == null) return null;
    final int rc = f(_poseOut);
    return XrslamLiveSnapshot(
      state: _poseOut[0].toInt(),
      timestampSeconds: _poseOut[1],
      qx: _poseOut[2],
      qy: _poseOut[3],
      qz: _poseOut[4],
      qw: _poseOut[5],
      px: _poseOut[6],
      py: _poseOut[7],
      pz: _poseOut[8],
      hasPose: rc == 0,
    );
  }

  static _OutDoubleDart? _timing;
  static final ffi.Pointer<ffi.Double> _timingOut = calloc<ffi.Double>(4);

  /// 相机 PTS 与 IMU 时间戳的**域差**。`null` = 符号不在或还没样本。
  ///
  /// 🔴 判读:两者同域时 `deltaSeconds` 应是**相机管线延迟**的量级
  /// (几十毫秒,可能为负 —— PTS 可能是曝光起点);若是**开机时长**那个
  /// 量级(成千上万秒),说明两条流根本不在一个时间轴上,视觉-惯性关联全错。
  /// 传输层的单调闸只管每条流自己递增,**捕不到这个偏移**。
  static ({double cameraPts, double imuTs, double delta, double maxAbsDelta})?
      timing() {
    _lookup();
    _timing ??= () {
      try {
        return _lib.lookupFunction<_OutDoubleNative, _OutDoubleDart>(
            'pw_xrslam_live_timing');
      } catch (_) {
        return null;
      }
    }();
    final _OutDoubleDart? f = _timing;
    if (f == null) return null;
    if (f(_timingOut) != 0) return null;
    return (
      cameraPts: _timingOut[0],
      imuTs: _timingOut[1],
      delta: _timingOut[2],
      maxAbsDelta: _timingOut[3],
    );
  }

  static _OutDoubleDart? _timebase;
  static final ffi.Pointer<ffi.Double> _timebaseOut = calloc<ffi.Double>(12);

  /// [pw 2026-09-22] 相机时间戳换算的**运行期自证**(`PwXrslamLive.timebase`)。
  /// `null` = 符号不在或还没推过帧。
  ///
  /// 判读(见 `PwXrslamLive.swift` 文件头偏离 (d)):
  ///   · `framesWithExposure == frames` ⇒ 每帧都拿到了曝光时长;差的那些是按 0
  ///     换算的(没猜,如实计数)。
  ///   · `maxAbsRawResidual` **必须为 0** —— C 账本收到的 raw 就是我们推的
  ///     PTS+exposure/2;非 0 = 推的不是换算值。
  ///   · `maxAbsOffsetResidual` **必须为 0** —— 传输层加的就是 applied_offset。
  ///   · `appliedOffsetSeconds` 应等于 create 时传的 [cameraTimeOffsetSeconds]。
  ///   · `effectiveMinusPtsSeconds` = 引擎实际收到的时刻 − 原始 PTS
  ///     = exposure/2 + c,是这条链**唯一**的端到端读数。
  static ({
    double cameraTimeOffsetSeconds,
    double appliedOffsetSeconds,
    int frames,
    int framesWithExposure,
    double meanExposureSeconds,
    double minExposureSeconds,
    double maxExposureSeconds,
    double meanHalfAppliedSeconds,
    double maxAbsRawResidual,
    double maxAbsOffsetResidual,
    double effectiveMinusPtsSeconds,
    int traceReads,
  })? timebase() {
    _lookup();
    _timebase ??= () {
      try {
        return _lib.lookupFunction<_OutDoubleNative, _OutDoubleDart>(
            'pw_xrslam_live_timebase');
      } catch (_) {
        return null;
      }
    }();
    final _OutDoubleDart? f = _timebase;
    if (f == null) return null;
    if (f(_timebaseOut) != 0) return null;
    return (
      cameraTimeOffsetSeconds: _timebaseOut[0],
      appliedOffsetSeconds: _timebaseOut[1],
      frames: _timebaseOut[2].toInt(),
      framesWithExposure: _timebaseOut[3].toInt(),
      meanExposureSeconds: _timebaseOut[4],
      minExposureSeconds: _timebaseOut[5],
      maxExposureSeconds: _timebaseOut[6],
      meanHalfAppliedSeconds: _timebaseOut[7],
      maxAbsRawResidual: _timebaseOut[8],
      maxAbsOffsetResidual: _timebaseOut[9],
      effectiveMinusPtsSeconds: _timebaseOut[10],
      traceReads: _timebaseOut[11].toInt(),
    );
  }

  static int Function(ffi.Pointer<ffi.Double>, int)? _intrinsics;
  static bool _intrinsicsLooked = false;
  static final ffi.Pointer<ffi.Double> _intrinsicsOut =
      calloc<ffi.Double>(XrslamLiveIntrinsics.wireLength);

  /// [pw 2026-09-23] 逐帧内参这一场的账。`null` = 符号不在(旧包)或还没推过帧。
  static XrslamLiveIntrinsics? intrinsics() {
    if (!_intrinsicsLooked) {
      _intrinsicsLooked = true;
      try {
        _intrinsics = _lib.lookupFunction<
            ffi.Int32 Function(ffi.Pointer<ffi.Double>, ffi.Int32),
            int Function(ffi.Pointer<ffi.Double>, int)>(
          'pw_xrslam_live_intrinsics',
        );
      } catch (_) {
        _intrinsics = null;
      }
    }
    final int Function(ffi.Pointer<ffi.Double>, int)? f = _intrinsics;
    if (f == null) return null;
    if (f(_intrinsicsOut, XrslamLiveIntrinsics.wireLength) != 0) return null;
    return XrslamLiveIntrinsics.fromWire(<double>[
      for (int i = 0; i < XrslamLiveIntrinsics.wireLength; i++)
        _intrinsicsOut[i],
    ]);
  }

  static ffi.Pointer<ffi.Char>? _trailBuf;

  /// GPU 前端的初始化痕迹(`gpu_image.cpp` 自己写的那份日志)。
  ///
  /// 🔴 判读:
  ///   · 空串            = 没链 GPU 前端那条臂(或没走到 init)
  ///   · `init: FAILED …` = Dawn 起不来,引擎**已静默回落 CPU**
  ///                        —— 这时"没提速"不等于"GPU 前端没用"
  ///   · `init: front end ok; selfcheck …` = 真的在跑 GPU 路径
  static String gpuFrontEndTrail() {
    _lookup();
    try {
      final f = _lib.lookupFunction<
          ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Int32),
          int Function(ffi.Pointer<ffi.Char>,
              int)>('pw_xrslam_live_gpufe_trail');
      _trailBuf ??= calloc<ffi.Char>(4096);
      final int n = f(_trailBuf!, 4096);
      if (n <= 0) return '';
      return _trailBuf!.cast<Utf8>().toDartString();
    } catch (_) {
      return '';
    }
  }

  static ffi.Pointer<ffi.Char>? _stampBuf;

  /// [bench 2026-09-24] 构建戳 + 当前喂料口径(`PwXrslamLive.buildStampLine`):
  /// 链的是哪条引擎臂 / 归档 / sha16 / 线程化 / 官方规则,以及 yaml 喂料尺寸、30 Hz 准入、
  /// 源尺寸与 box 因子、被准入挡掉的帧数。找不到符号 ⇒ 空串。
  static String buildStamp() {
    _lookup();
    try {
      final f = _lib.lookupFunction<
          ffi.Int32 Function(ffi.Pointer<ffi.Char>, ffi.Int32),
          int Function(ffi.Pointer<ffi.Char>,
              int)>('pw_xrslam_live_build_stamp');
      _stampBuf ??= calloc<ffi.Char>(1024);
      final int n = f(_stampBuf!, 1024);
      if (n <= 0) return '';
      return _stampBuf!.cast<Utf8>().toDartString();
    } catch (_) {
      return '';
    }
  }

  /// [bench 2026-09-25] 原生曝光中点开关的解析结果(`PwXrslamOfficialFeed.resolved.exposureMid`,
  /// 台架默认 on;`-PWXrslamExposureMid off` 退回原始 PTS)。true = on,false = off,
  /// null = 找不到符号(旧原生)。Dart 只用它定 c 的默认值,不在 Dart 里再解析启动参数。
  static bool? exposureMidEnabled() {
    _lookup();
    try {
      final f = _lib.lookupFunction<ffi.Int32 Function(), int Function()>(
          'pw_xrslam_live_exposure_mid');
      return f() != 0;
    } catch (_) {
      return null;
    }
  }

  static XrslamLiveStats? stats() {
    _lookup();
    final _OutInt64Dart? f = _stats;
    if (f == null) return null;
    f(_statsOut);
    return XrslamLiveStats(
      cameraSubmitted: _statsOut[0],
      cameraRunCalls: _statsOut[1],
      accelerationSubmitted: _statsOut[2],
      gyroscopeSubmitted: _statsOut[3],
      rejectedNonMonotonic: _statsOut[4],
      rejectedInvalidArgument: _statsOut[5],
      rejectedNotRunning: _statsOut[6],
      running: _statsOut[7] != 0,
      cameraCallbacks: _statsOut[8],
      cameraLockFailures: _statsOut[9],
      framesOffered: _statsOut[10],
      framesDropped: _statsOut[11],
      imuDropped: _statsOut[12],
      maxPendingFrames: _statsOut[13],
    );
  }
}
