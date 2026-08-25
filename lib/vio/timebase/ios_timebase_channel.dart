// ios_timebase_channel.dart — 读 iOS 侧 PwVioTimebase 的**实测量**,并在 Dart 里判决。
//
// 分工:Swift 只测(读钟、配对、min-filter),判决全在这里 —— 与
// lib/vio/thermal/ 同一条纪律,避免两端跑结构性不同的算法。
//
// ════════════════════════════════════════════════════════════════════════
// 🔴 本文件的核心:CoreMotion 的「since the device booted」到底是哪个 boot?
// ════════════════════════════════════════════════════════════════════════
// Apple 对 `CMLogItem.timestamp` 的全部文字是:
//     "The timestamp is the amount of time in seconds since the device booted."
// 而 Darwin 上「自启动」有**两个**互不相同的钟(`man 3 clock_gettime` 原文):
//     CLOCK_UPTIME_RAW  —— "does not increment while the system is asleep"
//     CLOCK_MONOTONIC   —— "will continue to increment while the system is asleep"
// 两者之差 = 开机以来累计休眠时长,与 Android 的
// (elapsedRealtimeNanos − nanoTime) 是**同一个物理量**。
//
// Swift 侧对每一路都同时测了到这两个基准的偏置。判据很简单:
//     |offset| 更接近 0 的那个基准,就是这一路所在的域。
//
// ⚠️ **但这个判据有一个致命的退化条件**,必须显式处理:
//     offset_to_monotonic − offset_to_uptimeRaw ≡ accumulatedSleep
// 也就是说,**如果手机开机以来从没真正睡过(accumulatedSleep ≈ 0),两个候选
// 基准在数值上完全重合,判据无法区分**。此时任何「结论」都是自欺。
// ⇒ [IosClockBaseVerdict.indeterminate],并要求先让设备睡一会儿再测。
//    明早真机测试**必须**先满足这个前提(见 device_test_plan)。

import 'dart:async';

import 'package:flutter/services.dart';

import 'timebase_contract.dart';

/// 与 ios/Runner/PwVioTimebase.swift 的 `PwVioTimebaseIdentifiers` 一致。
const String kPwVioTimebaseChannel = 'pocketworld_vio_timebase';

/// 一路时间戳源相对两个候选基准的实测偏置。
class IosSourceOffsets {
  const IosSourceOffsets({
    required this.source,
    required this.sampleCount,
    required this.lastRawSeconds,
    required this.offsetToUptimeRawSeconds,
    required this.offsetToMonotonicSeconds,
    required this.jitterToUptimeRawSeconds,
    required this.driftPpm,
    required this.driftPpmUncertainty,
  });

  final String source;
  final int sampleCount;
  final double? lastRawSeconds;
  final double? offsetToUptimeRawSeconds;
  final double? offsetToMonotonicSeconds;
  final double? jitterToUptimeRawSeconds;
  final double? driftPpm;
  final double? driftPpmUncertainty;

  bool get driftIsSignificant =>
      driftPpm != null &&
      driftPpmUncertainty != null &&
      driftPpm!.abs() > driftPpmUncertainty!;

  static double? _d(Object? v) => v is num ? v.toDouble() : null;

  factory IosSourceOffsets.fromMap(String source, Map<Object?, Object?> m) =>
      IosSourceOffsets(
        source: source,
        sampleCount: (m['sampleCount'] as num?)?.toInt() ?? 0,
        lastRawSeconds: _d(m['lastRawSeconds']),
        offsetToUptimeRawSeconds: _d(m['offsetToUptimeRawSeconds']),
        offsetToMonotonicSeconds: _d(m['offsetToMonotonicSeconds']),
        jitterToUptimeRawSeconds: _d(m['offsetToUptimeRawJitterSeconds']),
        driftPpm: _d(m['offsetToUptimeRawDriftPpm']),
        driftPpmUncertainty: _d(m['offsetToUptimeRawDriftPpmUncertainty']),
      );
}

/// 某一路贴着哪个基准。
enum IosClockBaseVerdict {
  /// 贴 CLOCK_UPTIME_RAW(== mach_absolute_time,休眠不走)。
  uptimeRaw,

  /// 贴 CLOCK_MONOTONIC(休眠继续走)。🔴 若相机贴 uptimeRaw 而 IMU 贴这个,
  /// iPhone 上就会出现与 Android 完全相同的域错配。
  monotonic,

  /// **无法区分** —— 设备累计休眠太少,两个候选基准数值重合。
  /// 这不是「大概是 uptimeRaw」,这是**没有结论**。
  indeterminate,

  /// 样本不足 / 该路没上报。
  unavailable,
}

/// 一次完整快照。
class IosTimebaseSnapshot {
  const IosTimebaseSnapshot({
    required this.uptimeRawSeconds,
    required this.monotonicSeconds,
    required this.clockPairReadCostSeconds,
    required this.accumulatedSleepSeconds,
    required this.sessionSleepDeltaSeconds,
    required this.syncClockUnavailableCount,
    required this.synchronizationClockAvailable,
    required this.arFrameExifAvailable,
    required this.sources,
  });

  final double uptimeRawSeconds;
  final double monotonicSeconds;

  /// 三明治采样宽度 = Cristian 夹逼的**硬**误差界。
  final double clockPairReadCostSeconds;

  /// 开机以来累计休眠(秒)= monotonic − uptimeRaw。
  final double accumulatedSleepSeconds;

  /// 本次会话内新增的休眠(秒)。>0 ⇒ 会话跨越了休眠 ⇒ 缓冲必须按新偏置重放
  /// (不是丢弃 —— 铁律)。
  final double sessionSleepDeltaSeconds;

  final int syncClockUnavailableCount;

  /// iOS 15.4+ 才有 `AVCaptureSession.synchronizationClock`;15.0–15.3 走
  /// 已废弃的 `masterClock`。
  final bool synchronizationClockAvailable;

  /// iOS 16.0+ 才有 `ARFrame.exifData` ⇒ 才拿得到每帧曝光时长。
  final bool arFrameExifAvailable;

  final Map<String, IosSourceOffsets> sources;

  static double _d(Object? v, [double fallback = 0.0]) =>
      v is num ? v.toDouble() : fallback;

  factory IosTimebaseSnapshot.fromMap(Map<Object?, Object?> m) {
    final Map<String, IosSourceOffsets> src = <String, IosSourceOffsets>{};
    final Object? raw = m['sources'];
    if (raw is Map) {
      raw.forEach((Object? k, Object? v) {
        if (k is String && v is Map) {
          src[k] = IosSourceOffsets.fromMap(k, v);
        }
      });
    }
    return IosTimebaseSnapshot(
      uptimeRawSeconds: _d(m['uptimeRawSeconds']),
      monotonicSeconds: _d(m['monotonicSeconds']),
      clockPairReadCostSeconds: _d(m['clockPairReadCostSeconds']),
      accumulatedSleepSeconds: _d(m['accumulatedSleepSeconds']),
      sessionSleepDeltaSeconds: _d(m['sessionSleepDeltaSeconds']),
      syncClockUnavailableCount:
          (m['syncClockUnavailableCount'] as num?)?.toInt() ?? 0,
      synchronizationClockAvailable:
          m['synchronizationClockAvailable'] == true,
      arFrameExifAvailable: m['arFrameExifAvailable'] == true,
      sources: src,
    );
  }

  /// 判据是否**可用**:必须有足够的累计休眠,两个候选基准才在数值上分得开。
  ///
  /// 门槛 = max(1 s, 32 × 读取开销)。1 s 远大于任何投递抖动;32× 读取开销是
  /// 为了在极端情况下也留出信噪比。
  bool get baseDiscriminable {
    final double floor =
        clockPairReadCostSeconds * 32 > 1.0 ? clockPairReadCostSeconds * 32 : 1.0;
    return accumulatedSleepSeconds.abs() > floor;
  }

  /// 某一路贴着哪个基准。
  IosClockBaseVerdict baseOf(String source) {
    final IosSourceOffsets? s = sources[source];
    if (s == null ||
        s.offsetToUptimeRawSeconds == null ||
        s.offsetToMonotonicSeconds == null) {
      return IosClockBaseVerdict.unavailable;
    }
    if (!baseDiscriminable) return IosClockBaseVerdict.indeterminate;
    final double au = s.offsetToUptimeRawSeconds!.abs();
    final double am = s.offsetToMonotonicSeconds!.abs();
    return au <= am
        ? IosClockBaseVerdict.uptimeRaw
        : IosClockBaseVerdict.monotonic;
  }

  /// 两路是否同域。返回 null = 还判不了(其中一路 unavailable/indeterminate)。
  bool? sameBase(String a, String b) {
    final IosClockBaseVerdict va = baseOf(a);
    final IosClockBaseVerdict vb = baseOf(b);
    if (va == IosClockBaseVerdict.unavailable ||
        vb == IosClockBaseVerdict.unavailable ||
        va == IosClockBaseVerdict.indeterminate ||
        vb == IosClockBaseVerdict.indeterminate) {
      return null;
    }
    return va == vb;
  }

  /// 把某一路的实测结论翻成 [TimeDomain]。判不了就是 [TimeDomain.unknown] ——
  /// 不猜(unknown 在 [TimebaseNormalizer] 里会直接 fault)。
  TimeDomain domainOf(String source) {
    switch (baseOf(source)) {
      case IosClockBaseVerdict.uptimeRaw:
        return TimeDomain.appleHostTime;
      case IosClockBaseVerdict.monotonic:
      case IosClockBaseVerdict.indeterminate:
      case IosClockBaseVerdict.unavailable:
        return TimeDomain.unknown;
    }
  }
}

/// iOS 侧源名(与 Swift 的 `PwVioTimebase.source*` 一致)。
class IosTimebaseSources {
  static const String coreMotion = 'coreMotion';
  static const String arFrame = 'arFrame';
  static const String capturePtsRaw = 'capturePtsRaw';
  static const String capturePtsHost = 'capturePtsHost';
}

/// 通道客户端。
class IosTimebaseChannel {
  IosTimebaseChannel([MethodChannel? channel])
      : _channel = channel ?? const MethodChannel(kPwVioTimebaseChannel);

  final MethodChannel _channel;

  Future<void> beginSession() => _channel.invokeMethod<void>('beginSession');

  /// 启动原生侧的 CoreMotion 投喂。返回 false = 设备没有 deviceMotion。
  /// ⚠️ hz 是**请求**不是保证 —— 实际频率由系统决定,所以判据只看到达时间戳。
  Future<bool> startCoreMotionFeed({double hz = 100.0}) async {
    final bool? ok = await _channel
        .invokeMethod<bool>('startCoreMotionFeed', <String, Object?>{'hz': hz});
    return ok ?? false;
  }

  Future<void> stopCoreMotionFeed() =>
      _channel.invokeMethod<void>('stopCoreMotionFeed');

  /// 启动 XRSLAM 喂帧。返回 XRSLAMCreate 的 rc(⚠️ 1=成功,与其余 API 相反)。
  Future<int> slamStart({
    required String slamYaml,
    required String deviceYaml,
    double runHz = 10.0,
  }) async {
    final int? rc = await _channel.invokeMethod<int>('slamStart', <String, Object?>{
      'slamYaml': slamYaml, 'deviceYaml': deviceYaml, 'runHz': runHz,
    });
    return rc ?? 0;
  }

  Future<void> slamStop() => _channel.invokeMethod<void>('slamStop');

  /// 喂帧统计 + 位姿 + 健康状态。
  Future<Map<String, Object?>?> slamSnapshot() async {
    final Map<Object?, Object?>? m =
        await _channel.invokeMethod<Map<Object?, Object?>>('slamSnapshot');
    if (m == null) return null;
    return m.map((Object? k, Object? v) => MapEntry<String, Object?>('$k', v));
  }

  /// 取最新一帧的 ARKit 相机内参。ARKit 没跑过任何一帧时返回 null。
  ///
  /// ⚠️ 返回 null 时调用方**必须**如实标成 PLACEHOLDER,不要退回一组编出来的数。
  Future<Map<String, Object?>?> latestIntrinsics() async {
    final Map<Object?, Object?>? m =
        await _channel.invokeMethod<Map<Object?, Object?>>('latestIntrinsics');
    if (m == null) return null;
    return m.map((Object? k, Object? v) => MapEntry<String, Object?>('$k', v));
  }

  /// 喂给 VIO 前的降采样倍数,**由 Swift 侧那一个常量作为唯一真源**。
  ///
  /// Dart 侧必须用它来缩放内参,而不是自己再写一个 3 —— 两边各写一份就是
  /// 「改了一边忘另一边 ⇒ 内参与实际图不匹配 ⇒ 位姿系统性错且不报错」。
  Future<int?> vioDownsampleFactor() =>
      _channel.invokeMethod<int>('vioDownsampleFactor');

  /// `hw.machine`,如 "iPhone15,2"。用于查相机-IMU 外参表。
  ///
  /// 用机器标识符而不是营销名:营销名要多经一层字符串映射,
  /// 而那层映射一旦漏掉一款机型就是静默回退到默认外参,不会报错。
  Future<String?> deviceMachine() =>
      _channel.invokeMethod<String>('deviceMachine');

  /// 返回会话内新增休眠(秒)。>0 ⇒ 必须按新偏置重放缓冲。
  Future<double> remeasure() async {
    final double? v = await _channel.invokeMethod<double>('remeasure');
    return v ?? 0.0;
  }

  Future<IosTimebaseSnapshot?> snapshot() async {
    final Map<Object?, Object?>? m =
        await _channel.invokeMapMethod<Object?, Object?>('snapshot');
    if (m == null) return null;
    return IosTimebaseSnapshot.fromMap(m);
  }
}
