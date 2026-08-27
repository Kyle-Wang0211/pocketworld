// ios_timebase_channel.dart — 读 iOS 侧 PwVioTimebase 的**实测量**,并在 Dart 里判决。
//
// 分工:Swift 只测(读钟、配对、bounded raw wire),min-filter 与判决全在这里 —— 与
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
// Swift 侧只把每一路原始戳与两个基准的原始读数配对；本文件复用
// [ClockOffsetEstimator] 计算两条偏置。判据很简单:
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

import 'clock_offset_estimator.dart';
import 'timebase_contract.dart';

/// 与 ios/Runner/PwVioTimebase.swift 的 `PwVioTimebaseIdentifiers` 一致。
const String kPwVioTimebaseChannel = 'pocketworld_vio_timebase';

double? _finite(Object? value) {
  if (value is! num) return null;
  final double result = value.toDouble();
  return result.isFinite ? result : null;
}

int? _nonNegativeInteger(Object? value) {
  final double? raw = _finite(value);
  if (raw == null || raw < 0) return null;
  final int result = raw.toInt();
  return raw == result.toDouble() ? result : null;
}

int? _positiveInteger(Object? value) {
  final int? result = _nonNegativeInteger(value);
  return result != null && result > 0 ? result : null;
}

Map<Object?, Object?>? _objectMap(Object? value) {
  if (value is! Map) return null;
  return value.map(
    (Object? key, Object? item) => MapEntry<Object?, Object?>(key, item),
  );
}

class IosRawClockSandwich {
  const IosRawClockSandwich._({
    required this.schemaValid,
    required this.uptimeRawBeforeSeconds,
    required this.monotonicSeconds,
    required this.uptimeRawAfterSeconds,
    required this.uptimeRawSeconds,
    required this.readCostSeconds,
    required this.halfWidthSeconds,
  });

  final bool schemaValid;
  final double uptimeRawBeforeSeconds;
  final double monotonicSeconds;
  final double uptimeRawAfterSeconds;
  final double uptimeRawSeconds;
  final double readCostSeconds;
  final double halfWidthSeconds;

  factory IosRawClockSandwich.fromMap(Map<Object?, Object?>? map) {
    final double? before = _finite(map?['uptimeRawBeforeSeconds']);
    final double? monotonic = _finite(map?['monotonicSeconds']);
    final double? after = _finite(map?['uptimeRawAfterSeconds']);
    final bool ordered =
        before != null &&
        monotonic != null &&
        after != null &&
        before >= 0 &&
        monotonic >= 0 &&
        after >= before;
    final double width = ordered ? after - before : 0;
    final double midpoint = ordered ? before + width / 2 : 0;
    final bool valid = ordered && width.isFinite && midpoint.isFinite;
    return IosRawClockSandwich._(
      schemaValid: valid,
      uptimeRawBeforeSeconds: before ?? 0,
      monotonicSeconds: monotonic ?? 0,
      uptimeRawAfterSeconds: after ?? 0,
      uptimeRawSeconds: valid ? midpoint : 0,
      readCostSeconds: valid ? width : 0,
      halfWidthSeconds: valid ? width / 2 : 0,
    );
  }
}

/// 一路时间戳源相对两个候选基准的实测偏置。
class IosSourceOffsets {
  const IosSourceOffsets({
    required this.schemaValid,
    required this.source,
    required this.sampleCount,
    required this.rawSamplesDropped,
    required this.rawSamplesAttempted,
    required this.rawSamplesAccepted,
    required this.rawSamplesRejected,
    required this.rawSamplesDelivered,
    required this.rawSamplesBatchCount,
    required this.rejectionReasons,
    required this.lastRawSeconds,
    required this.offsetToUptimeRawSeconds,
    required this.offsetToMonotonicSeconds,
    required this.jitterToUptimeRawSeconds,
    required this.driftPpm,
    required this.driftPpmUncertainty,
  });

  final bool schemaValid;
  final String source;
  final int sampleCount;
  final int rawSamplesDropped;
  final int rawSamplesAttempted;
  final int rawSamplesAccepted;
  final int rawSamplesRejected;
  final int rawSamplesDelivered;
  final int rawSamplesBatchCount;
  final Map<String, int> rejectionReasons;
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

  factory IosSourceOffsets.fromRawMap(String source, Map<Object?, Object?> m) {
    const Set<String> sourceKeys = <String>{
      'sampleCount',
      'rawSamplesDropped',
      'rawSamplesAttempted',
      'rawSamplesAccepted',
      'rawSamplesRejected',
      'rawSamplesDelivered',
      'rawSamplesBatchCount',
      'rejectionReasons',
      'rawSamples',
    };
    final bool exactSourceKeys =
        m.keys.toSet().containsAll(sourceKeys) &&
        sourceKeys.containsAll(m.keys);
    final int? sampleCount = _nonNegativeInteger(m['sampleCount']);
    final int? dropped = _nonNegativeInteger(m['rawSamplesDropped']);
    final int? attempted = _nonNegativeInteger(m['rawSamplesAttempted']);
    final int? accepted = _nonNegativeInteger(m['rawSamplesAccepted']);
    final int? rejected = _nonNegativeInteger(m['rawSamplesRejected']);
    final int? delivered = _nonNegativeInteger(m['rawSamplesDelivered']);
    final int? batchCount = _nonNegativeInteger(m['rawSamplesBatchCount']);
    const Set<String> reasonKeys = <String>{
      'invalid_input',
      'lock_contention',
      'stale_generation',
    };
    final Map<Object?, Object?>? rawReasons = _objectMap(m['rejectionReasons']);
    final Map<String, int> reasons = <String, int>{};
    bool reasonsValid =
        rawReasons != null &&
        rawReasons.keys.toSet().containsAll(reasonKeys) &&
        reasonKeys.containsAll(rawReasons.keys);
    for (final String key in reasonKeys) {
      final int? count = _nonNegativeInteger(rawReasons?[key]);
      if (count == null) {
        reasonsValid = false;
      } else {
        reasons[key] = count;
      }
    }
    final Object? rawSamples = m['rawSamples'];
    bool valid =
        exactSourceKeys &&
        sampleCount != null &&
        dropped != null &&
        attempted != null &&
        accepted != null &&
        rejected != null &&
        delivered != null &&
        batchCount != null &&
        reasonsValid &&
        rawSamples is List;
    final ClockOffsetEstimator uptime = ClockOffsetEstimator(maxSamples: 512);
    final ClockOffsetEstimator monotonic = ClockOffsetEstimator(
      maxSamples: 512,
    );
    int? previousSequence;
    double? lastRaw;
    int parsed = 0;
    if (rawSamples is List) {
      for (final Object? raw in rawSamples) {
        final Map<Object?, Object?>? sample = _objectMap(raw);
        const Set<String> sampleKeys = <String>{
          'seq',
          'sourceSeconds',
          'uptimeRawBeforeSeconds',
          'monotonicSeconds',
          'uptimeRawAfterSeconds',
        };
        final bool exactSampleKeys =
            sample != null &&
            sample.keys.toSet().containsAll(sampleKeys) &&
            sampleKeys.containsAll(sample.keys);
        final int? sequence = _positiveInteger(sample?['seq']);
        final double? sourceSeconds = _finite(sample?['sourceSeconds']);
        final IosRawClockSandwich clock = IosRawClockSandwich.fromMap(sample);
        if (sample == null ||
            !exactSampleKeys ||
            sequence == null ||
            sourceSeconds == null ||
            !clock.schemaValid ||
            (previousSequence != null && sequence <= previousSequence)) {
          valid = false;
          continue;
        }
        previousSequence = sequence;
        lastRaw = sourceSeconds;
        parsed++;
        uptime.add(
          srcSeconds: sourceSeconds,
          refSeconds: clock.uptimeRawSeconds,
        );
        monotonic.add(
          srcSeconds: sourceSeconds,
          refSeconds: clock.monotonicSeconds,
        );
        // Establish the drift anchor at the first mature Dart window, not at
        // the time of a later UI poll.
        uptime.estimate();
        monotonic.estimate();
      }
    }
    if (batchCount != parsed ||
        delivered == null ||
        batchCount == null ||
        delivered < batchCount) {
      valid = false;
    }
    final int reasonSum = reasons.values.fold<int>(
      0,
      (int total, int value) => total + value,
    );
    if (sampleCount != accepted ||
        accepted != (delivered ?? 0) + (dropped ?? 0) ||
        attempted != (accepted ?? 0) + (rejected ?? 0) ||
        rejected != reasonSum) {
      valid = false;
    }
    final ClockOffsetEstimate? uptimeEstimate = uptime.estimate();
    final ClockOffsetEstimate? monotonicEstimate = monotonic.estimate();
    return IosSourceOffsets(
      schemaValid: valid,
      source: source,
      sampleCount: sampleCount ?? 0,
      rawSamplesDropped: dropped ?? 0,
      rawSamplesAttempted: attempted ?? 0,
      rawSamplesAccepted: accepted ?? 0,
      rawSamplesRejected: rejected ?? 0,
      rawSamplesDelivered: delivered ?? 0,
      rawSamplesBatchCount: batchCount ?? 0,
      rejectionReasons: Map<String, int>.unmodifiable(reasons),
      lastRawSeconds: lastRaw,
      offsetToUptimeRawSeconds: uptimeEstimate?.offsetSeconds,
      offsetToMonotonicSeconds: monotonicEstimate?.offsetSeconds,
      jitterToUptimeRawSeconds: uptimeEstimate?.jitterSeconds,
      driftPpm: uptimeEstimate?.driftPpm,
      driftPpmUncertainty: uptimeEstimate?.driftPpmUncertainty,
    );
  }
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
    required this.schemaValid,
    required this.sessionId,
    required this.sessionEpoch,
    required this.sessionGeneration,
    required this.uptimeRawSeconds,
    required this.monotonicSeconds,
    required this.clockPairReadCostSeconds,
    required this.accumulatedSleepSeconds,
    required this.sessionSleepDeltaSeconds,
    required this.syncClockUnavailableCount,
    required this.synchronizationClockAvailable,
    required this.arFrameExifAvailable,
    required this.outOfSessionStaleObservations,
    required this.intrinsicsAttempted,
    required this.intrinsicsAccepted,
    required this.intrinsicsRejected,
    required this.intrinsicsOverwritten,
    required this.intrinsicsRejectionReasons,
    required this.sources,
  });

  final bool schemaValid;
  final String sessionId;
  final int sessionEpoch;
  final int sessionGeneration;
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
  final int outOfSessionStaleObservations;
  final int intrinsicsAttempted;
  final int intrinsicsAccepted;
  final int intrinsicsRejected;
  final int intrinsicsOverwritten;
  final Map<String, int> intrinsicsRejectionReasons;

  final Map<String, IosSourceOffsets> sources;

  bool get transportLossFree =>
      schemaValid &&
      outOfSessionStaleObservations == 0 &&
      sources.values.every(
        (IosSourceOffsets source) =>
            source.rawSamplesRejected == 0 && source.rawSamplesDropped == 0,
      );

  factory IosTimebaseSnapshot.fromMap(Map<Object?, Object?> m) {
    const Set<String> sourceKeys = <String>{
      IosTimebaseSources.coreMotionAccelerometer,
      IosTimebaseSources.coreMotionGyroscope,
      IosTimebaseSources.arFrame,
      IosTimebaseSources.capturePtsRaw,
      IosTimebaseSources.capturePtsHost,
    };
    final Map<String, IosSourceOffsets> src = <String, IosSourceOffsets>{};
    final Object? raw = m['sources'];
    if (raw is Map) {
      raw.forEach((Object? k, Object? v) {
        if (k is String && v is Map) {
          src[k] = IosSourceOffsets.fromRawMap(k, v);
        }
      });
    }
    final String? sessionId = m['sessionId'] is String
        ? (m['sessionId']! as String).trim()
        : null;
    final int? sessionEpoch = _nonNegativeInteger(m['sessionEpoch']);
    final int? generation = _nonNegativeInteger(m['sessionGeneration']);
    final IosRawClockSandwich currentClock = IosRawClockSandwich.fromMap(m);
    final IosRawClockSandwich startClock =
        IosRawClockSandwich.fromMap(<Object?, Object?>{
          'uptimeRawBeforeSeconds': m['sessionStartUptimeRawBeforeSeconds'],
          'monotonicSeconds': m['sessionStartMonotonicSeconds'],
          'uptimeRawAfterSeconds': m['sessionStartUptimeRawAfterSeconds'],
        });
    final int? syncFailures = _nonNegativeInteger(
      m['syncClockUnavailableCount'],
    );
    final int? outOfSessionStale = _nonNegativeInteger(
      m['outOfSessionStaleObservations'],
    );
    final Map<Object?, Object?>? intrinsics = _objectMap(
      m['intrinsicsAccounting'],
    );
    final int? intrinsicsAttempted = _nonNegativeInteger(
      intrinsics?['rawSamplesAttempted'],
    );
    final int? intrinsicsAccepted = _nonNegativeInteger(
      intrinsics?['rawSamplesAccepted'],
    );
    final int? intrinsicsRejected = _nonNegativeInteger(
      intrinsics?['rawSamplesRejected'],
    );
    final int? intrinsicsOverwritten = _nonNegativeInteger(
      intrinsics?['intrinsicsOverwritten'],
    );
    const Set<String> intrinsicsReasonKeys = <String>{
      'invalid_input',
      'lock_contention',
      'stale_generation',
    };
    final Map<Object?, Object?>? rawIntrinsicsReasons = _objectMap(
      intrinsics?['rejectionReasons'],
    );
    final Map<String, int> intrinsicsReasons = <String, int>{};
    bool intrinsicsReasonsValid =
        rawIntrinsicsReasons != null &&
        rawIntrinsicsReasons.keys.toSet().containsAll(intrinsicsReasonKeys) &&
        intrinsicsReasonKeys.containsAll(rawIntrinsicsReasons.keys);
    for (final String key in intrinsicsReasonKeys) {
      final int? value = _nonNegativeInteger(rawIntrinsicsReasons?[key]);
      if (value == null) {
        intrinsicsReasonsValid = false;
      } else {
        intrinsicsReasons[key] = value;
      }
    }
    final int intrinsicsReasonSum = intrinsicsReasons.values.fold<int>(
      0,
      (int total, int value) => total + value,
    );
    const Set<String> topKeys = <String>{
      'schema',
      'sessionId',
      'sessionEpoch',
      'sessionGeneration',
      'uptimeRawBeforeSeconds',
      'monotonicSeconds',
      'uptimeRawAfterSeconds',
      'sessionStartUptimeRawBeforeSeconds',
      'sessionStartMonotonicSeconds',
      'sessionStartUptimeRawAfterSeconds',
      'syncClockUnavailableCount',
      'outOfSessionStaleObservations',
      'synchronizationClockAvailable',
      'arFrameExifAvailable',
      'intrinsicsAccounting',
      'sources',
    };
    final bool exactTopKeys =
        m.keys.toSet().containsAll(topKeys) && topKeys.containsAll(m.keys);
    final double accumulatedSleep = currentClock.schemaValid
        ? currentClock.monotonicSeconds - currentClock.uptimeRawSeconds
        : 0;
    final bool schemaValid =
        exactTopKeys &&
        m['schema'] == 'pw.vio.timebase-raw/5' &&
        sessionId != null &&
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ).hasMatch(sessionId) &&
        sessionEpoch != null &&
        generation != null &&
        currentClock.schemaValid &&
        startClock.schemaValid &&
        syncFailures != null &&
        outOfSessionStale != null &&
        m['synchronizationClockAvailable'] is bool &&
        m['arFrameExifAvailable'] is bool &&
        raw is Map &&
        raw.keys.toSet().containsAll(sourceKeys) &&
        sourceKeys.containsAll(raw.keys) &&
        src.keys.toSet().containsAll(sourceKeys) &&
        sourceKeys.containsAll(src.keys) &&
        intrinsicsAttempted != null &&
        intrinsicsAccepted != null &&
        intrinsicsRejected != null &&
        intrinsicsOverwritten != null &&
        intrinsicsReasonsValid &&
        intrinsicsAttempted == intrinsicsAccepted + intrinsicsRejected &&
        intrinsicsRejected == intrinsicsReasonSum &&
        src.values.every((IosSourceOffsets value) => value.schemaValid);
    return IosTimebaseSnapshot(
      schemaValid: schemaValid,
      sessionId: sessionId ?? '',
      sessionEpoch: sessionEpoch ?? -1,
      sessionGeneration: generation ?? 0,
      uptimeRawSeconds: currentClock.uptimeRawSeconds,
      monotonicSeconds: currentClock.monotonicSeconds,
      clockPairReadCostSeconds: currentClock.readCostSeconds,
      accumulatedSleepSeconds: accumulatedSleep,
      sessionSleepDeltaSeconds: startClock.schemaValid
          ? accumulatedSleep -
                (startClock.monotonicSeconds - startClock.uptimeRawSeconds)
          : 0,
      syncClockUnavailableCount: syncFailures ?? 0,
      synchronizationClockAvailable: m['synchronizationClockAvailable'] == true,
      arFrameExifAvailable: m['arFrameExifAvailable'] == true,
      outOfSessionStaleObservations: outOfSessionStale ?? 0,
      intrinsicsAttempted: intrinsicsAttempted ?? 0,
      intrinsicsAccepted: intrinsicsAccepted ?? 0,
      intrinsicsRejected: intrinsicsRejected ?? 0,
      intrinsicsOverwritten: intrinsicsOverwritten ?? 0,
      intrinsicsRejectionReasons: Map<String, int>.unmodifiable(
        intrinsicsReasons,
      ),
      sources: src,
    );
  }

  /// 判据是否**可用**:必须有足够的累计休眠,两个候选基准才在数值上分得开。
  ///
  /// 门槛 = max(1 s, 32 × 读取开销)。1 s 远大于任何投递抖动;32× 读取开销是
  /// 为了在极端情况下也留出信噪比。
  bool get baseDiscriminable {
    if (!schemaValid) return false;
    final double floor = clockPairReadCostSeconds * 32 > 1.0
        ? clockPairReadCostSeconds * 32
        : 1.0;
    return accumulatedSleepSeconds.abs() > floor;
  }

  /// 某一路贴着哪个基准。
  IosClockBaseVerdict baseOf(String source) {
    final IosSourceOffsets? s = sources[source];
    if (!schemaValid ||
        s == null ||
        !s.schemaValid ||
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
  static const String coreMotionAccelerometer = 'coreMotionAccelerometer';
  static const String coreMotionGyroscope = 'coreMotionGyroscope';
  static const String arFrame = 'arFrame';
  static const String capturePtsRaw = 'capturePtsRaw';
  static const String capturePtsHost = 'capturePtsHost';
}

/// 通道客户端。
class IosTimebaseRemeasurement {
  const IosTimebaseRemeasurement({
    required this.schemaValid,
    required this.sessionSleepDeltaSeconds,
    required this.combinedHalfWidthSeconds,
  });

  const IosTimebaseRemeasurement.invalid()
    : schemaValid = false,
      sessionSleepDeltaSeconds = 0,
      combinedHalfWidthSeconds = 0;

  final bool schemaValid;
  final double sessionSleepDeltaSeconds;
  final double combinedHalfWidthSeconds;

  factory IosTimebaseRemeasurement.fromMap(
    Map<Object?, Object?>? map, {
    required String expectedSessionId,
    required int expectedSessionEpoch,
    required int expectedSessionGeneration,
  }) {
    const Set<String> keys = <String>{
      'schema',
      'sessionId',
      'sessionEpoch',
      'sessionGeneration',
      'uptimeRawBeforeSeconds',
      'monotonicSeconds',
      'uptimeRawAfterSeconds',
      'sessionStartUptimeRawBeforeSeconds',
      'sessionStartMonotonicSeconds',
      'sessionStartUptimeRawAfterSeconds',
    };
    if (map == null ||
        !map.keys.toSet().containsAll(keys) ||
        !keys.containsAll(map.keys)) {
      return const IosTimebaseRemeasurement.invalid();
    }
    final IosRawClockSandwich current = IosRawClockSandwich.fromMap(map);
    final IosRawClockSandwich start =
        IosRawClockSandwich.fromMap(<Object?, Object?>{
          'uptimeRawBeforeSeconds': map['sessionStartUptimeRawBeforeSeconds'],
          'monotonicSeconds': map['sessionStartMonotonicSeconds'],
          'uptimeRawAfterSeconds': map['sessionStartUptimeRawAfterSeconds'],
        });
    final bool valid =
        map['schema'] == 'pw.vio.timebase-remeasure-raw/1' &&
        map['sessionId'] == expectedSessionId &&
        _nonNegativeInteger(map['sessionEpoch']) == expectedSessionEpoch &&
        _positiveInteger(map['sessionGeneration']) ==
            expectedSessionGeneration &&
        current.schemaValid &&
        start.schemaValid;
    if (!valid) return const IosTimebaseRemeasurement.invalid();
    final double currentSleep =
        current.monotonicSeconds - current.uptimeRawSeconds;
    final double startSleep = start.monotonicSeconds - start.uptimeRawSeconds;
    final double delta = currentSleep - startSleep;
    final double uncertainty =
        current.halfWidthSeconds + start.halfWidthSeconds;
    if (!delta.isFinite || !uncertainty.isFinite) {
      return const IosTimebaseRemeasurement.invalid();
    }
    return IosTimebaseRemeasurement(
      schemaValid: true,
      sessionSleepDeltaSeconds: delta,
      combinedHalfWidthSeconds: uncertainty,
    );
  }
}

class IosShadowStartReceipt {
  const IosShadowStartReceipt({
    required this.schemaValid,
    required this.rc,
    required this.generation,
    required this.failureReason,
    required this.snapshot,
  });

  const IosShadowStartReceipt.invalid()
    : schemaValid = false,
      rc = 0,
      generation = 0,
      failureReason = 'invalid-wire',
      snapshot = null;

  final bool schemaValid;
  final int rc;
  final int generation;
  final String failureReason;
  final Map<String, Object?>? snapshot;

  bool get accepted =>
      schemaValid &&
      rc == 1 &&
      generation > 0 &&
      failureReason == 'none' &&
      snapshot?['sessionGeneration'] == generation &&
      snapshot?['state'] == 'running';

  factory IosShadowStartReceipt.fromMap(Map<Object?, Object?>? raw) {
    const Set<String> keys = <String>{
      'schema',
      'rc',
      'generation',
      'failureReason',
      'snapshot',
    };
    if (raw == null || raw.keys.any((Object? key) => key is! String)) {
      return const IosShadowStartReceipt.invalid();
    }
    final Map<String, Object?> map = raw.map(
      (Object? key, Object? value) =>
          MapEntry<String, Object?>(key! as String, value),
    );
    final int? rc = _nonNegativeInteger(map['rc']);
    final int? generation = _nonNegativeInteger(map['generation']);
    final String failureReason = map['failureReason'] is String
        ? (map['failureReason']! as String).trim()
        : '';
    final Map<Object?, Object?>? rawSnapshot = _objectMap(map['snapshot']);
    Map<String, Object?>? snapshot;
    if (rawSnapshot != null &&
        rawSnapshot.keys.every((Object? key) => key is String)) {
      snapshot = rawSnapshot.map(
        (Object? key, Object? value) =>
            MapEntry<String, Object?>(key! as String, value),
      );
    }
    final bool exactKeys =
        map.keys.toSet().containsAll(keys) && keys.containsAll(map.keys);
    final bool successShape =
        rc == 1 &&
        generation != null &&
        generation > 0 &&
        failureReason == 'none' &&
        snapshot != null &&
        _nonNegativeInteger(snapshot['sessionGeneration']) == generation &&
        snapshot['state'] == 'running';
    final bool failureShape =
        rc == 0 &&
        generation != null &&
        failureReason.isNotEmpty &&
        failureReason != 'none' &&
        snapshot == null;
    return IosShadowStartReceipt(
      schemaValid:
          exactKeys &&
          map['schema'] == 'pw.vio.shadow-start-receipt/1' &&
          (successShape || failureShape),
      rc: rc ?? 0,
      generation: generation ?? 0,
      failureReason: failureReason.isEmpty ? 'invalid-wire' : failureReason,
      snapshot: snapshot,
    );
  }
}

class IosTimebaseChannel {
  IosTimebaseChannel([MethodChannel? channel])
    : _channel = channel ?? const MethodChannel(kPwVioTimebaseChannel);

  final MethodChannel _channel;

  Future<void> beginSession({
    required String sessionId,
    required int sessionEpoch,
  }) => _channel.invokeMethod<void>('beginSession', <String, Object?>{
    'sessionId': sessionId,
    'sessionEpoch': sessionEpoch,
  });

  /// 启动两路独立原始 IMU 运输。Dart 拥有两个请求频率;
  /// 平台只校验和执行,不配对、重采样或融合。
  Future<bool> startRawCoreMotionFeed({
    required double accelerometerHz,
    required double gyroscopeHz,
  }) async {
    if (!accelerometerHz.isFinite ||
        accelerometerHz <= 0 ||
        !gyroscopeHz.isFinite ||
        gyroscopeHz <= 0) {
      return false;
    }
    final bool? ok = await _channel.invokeMethod<bool>(
      'startRawCoreMotionFeed',
      <String, Object?>{
        'accelerometerHz': accelerometerHz,
        'gyroscopeHz': gyroscopeHz,
      },
    );
    return ok ?? false;
  }

  Future<void> stopRawCoreMotionFeed() =>
      _channel.invokeMethod<void>('stopRawCoreMotionFeed');

  /// 启动 XRSLAM 喂帧。只有这个直接调用返回的代号+快照能建立运行代信任；
  /// 后续通用轮询永远不能反向冒充 start receipt。
  Future<IosShadowStartReceipt> slamStart({
    required String slamConfigPath,
    required String deviceConfigPath,
    required String sessionId,
    required int sessionEpoch,
    required String effectiveConfigSha256,
    required String inputIdentitySha256,
    required int downsampleFactor,
    required String downsampleFormula,
    required double requestedCameraHz,
    required double cameraTimeOffsetSeconds,
    required double accelerationScale,
    required double requestedAccelerometerHz,
    required double requestedGyroscopeHz,
  }) async {
    final Map<Object?, Object?>? raw = await _channel
        .invokeMethod<Map<Object?, Object?>>('slamStart', <String, Object?>{
          'slamConfigPath': slamConfigPath,
          'deviceConfigPath': deviceConfigPath,
          'sessionId': sessionId,
          'sessionEpoch': sessionEpoch,
          'effectiveConfigSha256': effectiveConfigSha256,
          'inputIdentitySha256': inputIdentitySha256,
          'downsampleFactor': downsampleFactor,
          'downsampleFormula': downsampleFormula,
          'requestedCameraHz': requestedCameraHz,
          'cameraTimeOffsetSeconds': cameraTimeOffsetSeconds,
          'accelerationScale': accelerationScale,
          'requestedAccelerometerHz': requestedAccelerometerHz,
          'requestedGyroscopeHz': requestedGyroscopeHz,
        });
    return IosShadowStartReceipt.fromMap(raw);
  }

  Future<Map<String, Object?>?> slamStop() async {
    final Map<Object?, Object?>? receipt = await _channel
        .invokeMethod<Map<Object?, Object?>>('slamStop');
    return receipt?.map(
      (Object? key, Object? value) => MapEntry<String, Object?>('$key', value),
    );
  }

  /// 喂帧统计 + 位姿 + 健康状态。
  Future<Map<String, Object?>?> slamSnapshot() async {
    final Map<Object?, Object?>? m = await _channel
        .invokeMethod<Map<Object?, Object?>>('slamSnapshot');
    if (m == null) return null;
    return m.map((Object? k, Object? v) => MapEntry<String, Object?>('$k', v));
  }

  /// 取最新一帧的 ARKit 相机内参。ARKit 没跑过任何一帧时返回 null。
  ///
  /// ⚠️ 返回 null 时调用方**必须**如实标成 PLACEHOLDER,不要退回一组编出来的数。
  Future<Map<String, Object?>?> latestIntrinsics() async {
    final Map<Object?, Object?>? m = await _channel
        .invokeMethod<Map<Object?, Object?>>('latestIntrinsics');
    if (m == null) return null;
    return m.map((Object? k, Object? v) => MapEntry<String, Object?>('$k', v));
  }

  /// `hw.machine`,如 "iPhone15,2"。用于查相机-IMU 外参表。
  ///
  /// 用机器标识符而不是营销名:营销名要多经一层字符串映射,
  /// 而那层映射一旦漏掉一款机型就是静默回退到默认外参,不会报错。
  Future<String?> deviceMachine() =>
      _channel.invokeMethod<String>('deviceMachine');

  /// 返回版本化的原始三明治重测结果。非法/跨会话响应与合法零值严格可分。
  Future<IosTimebaseRemeasurement> remeasure({
    required String expectedSessionId,
    required int expectedSessionEpoch,
    required int expectedSessionGeneration,
  }) async {
    final Map<Object?, Object?>? raw = await _channel
        .invokeMapMethod<Object?, Object?>('remeasure');
    return IosTimebaseRemeasurement.fromMap(
      raw,
      expectedSessionId: expectedSessionId,
      expectedSessionEpoch: expectedSessionEpoch,
      expectedSessionGeneration: expectedSessionGeneration,
    );
  }

  Future<IosTimebaseSnapshot?> snapshot() async {
    final Map<Object?, Object?>? m = await _channel
        .invokeMapMethod<Object?, Object?>('snapshot');
    if (m == null) return null;
    return IosTimebaseSnapshot.fromMap(m);
  }
}
