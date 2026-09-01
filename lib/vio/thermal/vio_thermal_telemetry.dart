// vio_thermal_telemetry.dart — 热/降频遥测记录(纯 Dart)。
//
// 目的只有一个:让「被平台降频」和「算法发散」在**同一行日志里可分离**。
// 明早真机 20 分钟曲线就是按这张表逐条落盘的。

import 'dart:convert';

import 'slowdown_attribution.dart';
import 'thermal_governor.dart';
import 'thermal_signal.dart';
import 'thermal_tier.dart';

/// 一条 10s 节拍的遥测记录。
class VioThermalSample {
  const VioThermalSample({
    required this.tsUs,
    required this.signal,
    required this.budget,
    required this.verdict,
    required this.observedVisualHz,
    required this.framesSeen,
    required this.visualUpdates,
    required this.imuOnlyFrames,
    required this.solverBusyDeferrals,
    required this.frameWallMsP50,
    required this.frameWallMsP95,
  });

  final int tsUs;
  final ThermalSignal signal;
  final VioBudget budget;
  final SlowdownVerdict? verdict;

  /// **实测**的视觉更新率(区间内 visualUpdates / 区间秒数),
  /// 与 [VioBudget.visualHz] 这个**目标值**分开记 —— 两者背离本身就是信号。
  final double observedVisualHz;

  final int framesSeen;
  final int visualUpdates;
  final int imuOnlyFrames;
  final int solverBusyDeferrals;
  final double frameWallMsP50;
  final double frameWallMsP95;

  /// 帧账目是否平衡(见 VioFrameScheduler)。false ⇒ 有帧下落不明,是红线。
  bool get accountingBalanced => framesSeen == visualUpdates + imuOnlyFrames;

  Map<String, Object?> toJson() => <String, Object?>{
    'schema': 1,
    'tsUs': tsUs,
    'platform': signal.platform.name,
    'tier': budget.tier.name,
    'tierInstant': signal.tier.name,
    'rawStatus': signal.rawStatus,
    'statusReadable': signal.statusReadable,
    'headroom': signal.headroom,
    'lowPowerMode': signal.lowPowerMode,
    'cameraStream': signal.cameraStream.name,
    'interruptionReason': signal.interruptionReason,
    'cameraCutBySystemPressure': signal.cameraCutBySystemPressure,
    'systemPressureLevel': signal.systemPressureLevel,
    'systemPressureFactors': signal.systemPressureFactors,
    'targetVisualHz': budget.visualHz,
    'observedVisualHz': observedVisualHz,
    'visualSuspended': budget.visualSuspended,
    'cameraShutdownAdvised': budget.cameraShutdownAdvised,
    'requiresVisualReacquire': budget.requiresVisualReacquire,
    'framesSeen': framesSeen,
    'visualUpdates': visualUpdates,
    'imuOnlyFrames': imuOnlyFrames,
    'solverBusyDeferrals': solverBusyDeferrals,
    'accountingBalanced': accountingBalanced,
    'frameWallMsP50': frameWallMsP50,
    'frameWallMsP95': frameWallMsP95,
    'slowdownCause': verdict?.cause.name ?? SlowdownCause.unknown.name,
    'platformAttributed': verdict?.platformAttributed,
    'cpuDuty': verdict?.cpuDuty,
    'nsPerUnitRatio': verdict?.nsPerUnitRatio,
    'workRatio': verdict?.workRatio,
    'coreDemotionSuspected': verdict?.coreDemotionSuspected,
    'coresOfflined': verdict?.coresOfflined,
    'lastCpuIndex': signal.lastCpuIndex,
    'onlineCpuCount': signal.onlineCpuCount,
    'presentCpuCount': signal.presentCpuCount,
    'activeProcessorCount': signal.activeProcessorCount,
  };

  /// 一行 JSON(JSONL),直接追加落盘。
  String toJsonLine() => jsonEncode(toJson());
}

/// 遥测节拍。Android 的 getThermalHeadroom **每 10s 最多取一次**
/// (调用过快返回 NaN),所以整条遥测就按 10s 对齐,两端同节拍。
const Duration kTelemetryCadence = Duration(seconds: 10);

/// 计算区间实测视觉更新率。
double observedVisualHzOver({
  required int visualUpdates,
  required int windowUs,
}) {
  if (windowUs <= 0) return 0;
  return visualUpdates * 1000000.0 / windowUs;
}

/// 目标与实测背离到这个比例以下,说明**没跑到该跑的速率**。
const double kVisualHzShortfallRatio = 0.75;

bool visualRateShortfall({
  required double targetHz,
  required double observedHz,
}) {
  if (targetHz <= 0) return false;
  return observedHz < targetHz * kVisualHzShortfallRatio;
}

/// 便捷:把档位映射成人读标签,给日志用。
String thermalTierLabel(ThermalTier t) => t.name;
