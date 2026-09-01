// thermal_signal.dart — 平台上报的热/降频原始信号 + 纯解码器(无 Flutter 依赖)。
//
// 两端上报**同一张 map**(schema v1),档位折叠与判定全在 Dart 侧做。
// 平台侧只负责"读得到什么就报什么,读不到报 null" —— null 永远表示
// **不可用**,绝不表示"正常"。这条是 08-18 的教训(正向白名单不可用
// "undefined 则拒",反过来也一样:缺失不可当成健康)。

import 'thermal_tier.dart';

/// 平台标识。
enum VioPlatform { ios, android, unknown }

/// 相机流状态。`interrupted` 在 iOS 上对应 AVCaptureSession 被打断
/// (含 videoDeviceNotAvailableDueToSystemPressure —— **那是断流不是降帧**)。
enum CameraStreamState { running, interrupted, stopped, unknown }

/// iOS `AVCaptureSessionInterruptionReason`(AVCaptureSession.h,已核对
/// iPhoneOS26.2.sdk):
///   1 VideoDeviceNotAvailableInBackground
///   2 AudioDeviceInUseByAnotherClient
///   3 VideoDeviceInUseByAnotherClient
///   4 VideoDeviceNotAvailableWithMultipleForegroundApps
///   5 VideoDeviceNotAvailableDueToSystemPressure   (iOS 11.1+)
///   6 SensitiveContentMitigationActivated          (iOS 26.0+)
const int kIosInterruptionReasonSystemPressure = 5;

/// iOS `AVCaptureSystemPressureLevel` 字符串常量(AVCaptureSystemPressure.h)。
/// 值是不透明字符串,这里只做**相对排序**用的已知集合。
const List<String> kIosSystemPressureLevelOrder = <String>[
  'AVCaptureSystemPressureLevelNominal',
  'AVCaptureSystemPressureLevelFair',
  'AVCaptureSystemPressureLevelSerious',
  'AVCaptureSystemPressureLevelCritical',
  'AVCaptureSystemPressureLevelShutdown',
];

/// 一次热/降频快照。所有可空字段的 null 一律读作"这台设备/这个系统版本
/// 拿不到这个数",不是 0、不是健康。
class ThermalSignal {
  const ThermalSignal({
    required this.platform,
    required this.timestampUs,
    required this.rawStatus,
    this.headroom,
    this.lowPowerMode,
    this.cameraStream = CameraStreamState.unknown,
    this.interruptionReason,
    this.systemPressureLevel,
    this.systemPressureFactors,
    this.activeProcessorCount,
    this.onlineCpuCount,
    this.presentCpuCount,
    this.lastCpuIndex,
    this.cpuMaxFreqKhz = const <int?>[],
    this.cpuCurFreqKhz = const <int?>[],
    this.statusReadable = true,
  });

  final VioPlatform platform;

  /// 单调时钟(自启动)微秒。**不是墙钟** —— 墙钟会被用户改。
  final int timestampUs;

  /// 平台原始热等级:iOS = NSProcessInfoThermalState(0..3);
  /// Android = PowerManager.THERMAL_STATUS_*(-1..6)。
  final int rawStatus;

  /// Android `PowerManager.getThermalHeadroom(int)`,API 30+。
  /// NaN(不支持 / 调用过快)在平台侧就已转成 null。
  final double? headroom;

  /// iOS `ProcessInfo.isLowPowerModeEnabled`(iOS 9+)。Android 侧为 null。
  final bool? lowPowerMode;

  final CameraStreamState cameraStream;

  /// iOS 打断原因原始值,见 [kIosInterruptionReasonSystemPressure]。
  final int? interruptionReason;

  /// iOS `AVCaptureSystemPressureState.level` 的原始字符串。
  final String? systemPressureLevel;

  /// iOS `AVCaptureSystemPressureState.factors` 位掩码:
  /// 1<<0 SystemTemperature / 1<<1 PeakPower /
  /// 1<<2 DepthModuleTemperature / 1<<3 CameraTemperature(iOS 17+)。
  final int? systemPressureFactors;

  /// iOS `ProcessInfo.activeProcessorCount`。
  final int? activeProcessorCount;

  /// Android `/sys/devices/system/cpu/online` 解析出的在线核数。
  final int? onlineCpuCount;

  /// Android `/sys/devices/system/cpu/present` 解析出的物理核数。
  final int? presentCpuCount;

  /// Android `/proc/self/task/<tid>/stat` 第 39 个字段(processor):
  /// 该线程**最后一次运行在哪个核**。这是识别"被钉死在小核"的关键信号。
  final int? lastCpuIndex;

  /// Android 每核 `cpuinfo_max_freq`(kHz)。读不到的核为 null。
  final List<int?> cpuMaxFreqKhz;

  /// Android 每核 `scaling_cur_freq`(kHz)。Android 10+ 常被 SELinux 挡住,
  /// 读不到就是 null —— 所以**不能把它当主判据**。
  final List<int?> cpuCurFreqKhz;

  /// 平台侧是否真的读到了热等级。false 时 [rawStatus] 无意义。
  final bool statusReadable;

  /// 折叠后的统一档位:平台 status → 档位,再由 headroom **只向上**抬。
  ThermalTier get tier {
    if (!statusReadable) {
      // 读不到热等级时,只能靠 headroom;没有 headroom 就只能按 nominal,
      // 但调用方会看到 statusReadable=false 从而在遥测里标 unknown。
      return escalateWithHeadroom(ThermalTier.nominal, headroom);
    }
    final base = platform == VioPlatform.android
        ? tierFromAndroidThermalStatus(rawStatus)
        : tierFromIosThermalState(rawStatus);
    return escalateWithHeadroom(base, headroom);
  }

  /// 相机是否因**系统压力**被断流(iOS 专有,reason == 5)。
  /// 这跟"降帧"是两件事:断流意味着一帧都没有,VIO 只剩纯 IMU 推算。
  bool get cameraCutBySystemPressure =>
      cameraStream == CameraStreamState.interrupted &&
      interruptionReason == kIosInterruptionReasonSystemPressure;
}

/// 从平台 channel 的 map 解码。**纯函数,可离机单测。**
/// 任何类型不符一律降级为 null,绝不抛 —— 遥测通道不能把采集打挂。
ThermalSignal decodeThermalSignal(Map<Object?, Object?> raw) {
  int? asInt(Object? v) => v is int ? v : (v is num ? v.toInt() : null);
  double? asDouble(Object? v) {
    if (v is double) return v.isNaN ? null : v;
    if (v is num) return v.toDouble();
    return null;
  }

  List<int?> asIntList(Object? v) {
    if (v is! List) return const <int?>[];
    return v.map(asInt).toList(growable: false);
  }

  final platformName = raw['platform'];
  final platform = platformName == 'ios'
      ? VioPlatform.ios
      : platformName == 'android'
          ? VioPlatform.android
          : VioPlatform.unknown;

  CameraStreamState camera;
  switch (raw['cameraStream']) {
    case 'running':
      camera = CameraStreamState.running;
      break;
    case 'interrupted':
      camera = CameraStreamState.interrupted;
      break;
    case 'stopped':
      camera = CameraStreamState.stopped;
      break;
    default:
      camera = CameraStreamState.unknown;
  }

  final status = asInt(raw['rawStatus']);
  return ThermalSignal(
    platform: platform,
    timestampUs: asInt(raw['tsUs']) ?? 0,
    rawStatus: status ?? 0,
    statusReadable: status != null && raw['statusReadable'] != false,
    headroom: asDouble(raw['headroom']),
    lowPowerMode: raw['lowPowerMode'] is bool ? raw['lowPowerMode'] as bool : null,
    cameraStream: camera,
    interruptionReason: asInt(raw['interruptionReason']),
    systemPressureLevel:
        raw['systemPressureLevel'] is String ? raw['systemPressureLevel'] as String : null,
    systemPressureFactors: asInt(raw['systemPressureFactors']),
    activeProcessorCount: asInt(raw['activeProcessorCount']),
    onlineCpuCount: asInt(raw['onlineCpuCount']),
    presentCpuCount: asInt(raw['presentCpuCount']),
    lastCpuIndex: asInt(raw['lastCpuIndex']),
    cpuMaxFreqKhz: asIntList(raw['cpuMaxFreqKhz']),
    cpuCurFreqKhz: asIntList(raw['cpuCurFreqKhz']),
  );
}
