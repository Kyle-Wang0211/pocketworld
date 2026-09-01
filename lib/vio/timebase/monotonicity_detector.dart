// monotonicity_detector.dart — 单流时间戳单调性 / 时钟重置检测。纯 Dart。
//
// 为什么单独一个模块:域错配检测是**跨流**的,而下面这三种病是**单流内**就能
// 看出来的,且成因完全不同:
//
//   1. 回退(t 变小)。成因:域被中途切换(例如相机从 UNKNOWN 切到 REALTIME)、
//      平台 bug、或者上游把两路不同源的样本混进了同一个队列。
//   2. 重复(t 相同)。成因:同一帧被投递两次,或时钟分辨率不足。对
//      preintegration 是致命的:Δt = 0 会让积分除零或产生零权重因子。
//   3. 时钟重置(t 突然跳回接近 0)。成因:设备重启后残留的旧样本、或
//      elapsedRealtime↔uptime 域整段切换。
//
// 🔴 三种都**不允许静默丢弃**。检测器只负责给出 [TimebaseFault];
//    「留着还是停」由 [TimebaseNormalizer] 按铁律决定(defer / fault,没有 drop)。
//
// ── 「回退」与「乱序」的区分 ────────────────────────────────────────────
// 如果平台提供了单调序号([TimestampSample.sequence]),那么:
//   • seq 前进而 t 后退  ⇒ 真回退(时钟有问题)          ⇒ nonMonotonic
//   • seq 后退           ⇒ 只是投递乱序(时钟没问题)     ⇒ 不算故障,记数
// 没有 seq 时无法区分,一律按真回退处理(fail-closed)。

import 'timebase_contract.dart';

/// 单流单调性检测结果。
class MonotonicityReport {
  const MonotonicityReport({
    required this.fault,
    required this.outOfOrderDelivery,
    required this.deltaSeconds,
  });

  /// null = 本条正常。
  final TimebaseFault? fault;

  /// true = 只是投递乱序(有 sequence 佐证),时钟本身没问题。
  final bool outOfOrderDelivery;

  /// 与上一条的差(秒);首条为 null。
  final double? deltaSeconds;

  bool get isFaulty => fault != null;
}

/// 单流单调性检测器。每路(camera / imu)各一个实例。
class MonotonicityDetector {
  MonotonicityDetector({
    required this.stream,
    this.clockResetBackwardJumpSeconds = 1.0,
  }) : assert(clockResetBackwardJumpSeconds > 0);

  final StreamKind stream;

  /// 后退超过这么多秒就不再当「抖动/乱序」,而是当**时钟重置**。
  ///
  /// 阈值来源:任何一路合法的投递乱序都限制在硬件队列深度之内 —— 相机队列
  /// 典型 ≤ 8 帧(30fps ⇒ 0.27 s),IMU 批投递 ≤ 数百毫秒。1 s 高于全部合法
  /// 乱序,又远低于任何真实的时钟重置(重置意味着 t 跳回接近 0,即数千秒级)。
  /// 这不是精度参数,是**类别判别**参数(和 domain skew 的上限同理)。
  final double clockResetBackwardJumpSeconds;

  double? _lastSeconds;
  int? _lastSequence;

  int backwardCount = 0;
  int duplicateCount = 0;
  int outOfOrderCount = 0;
  int resetCount = 0;

  double? get lastSeconds => _lastSeconds;

  void reset() {
    _lastSeconds = null;
    _lastSequence = null;
  }

  MonotonicityReport observe(TimestampSample s) {
    final double t = s.rawSeconds;
    final double? prev = _lastSeconds;
    final int? prevSeq = _lastSequence;

    if (prev == null) {
      _lastSeconds = t;
      _lastSequence = s.sequence;
      return const MonotonicityReport(
        fault: null,
        outOfOrderDelivery: false,
        deltaSeconds: null,
      );
    }

    final double delta = t - prev;

    if (delta == 0.0) {
      duplicateCount++;
      // 重复戳不推进 _lastSeconds(它已经等于 t)。
      _lastSequence = s.sequence ?? prevSeq;
      return MonotonicityReport(
        fault: TimebaseFault(
          kind: TimebaseFaultKind.duplicateTimestamp,
          detail:
              '${stream.name} 流出现重复时间戳 t=$t;'
              'Δt=0 会让 preintegration 产生零权重/除零因子',
          measuredSeconds: 0.0,
          limitSeconds: 0.0,
        ),
        outOfOrderDelivery: false,
        deltaSeconds: 0.0,
      );
    }

    if (delta > 0.0) {
      _lastSeconds = t;
      _lastSequence = s.sequence ?? prevSeq;
      return MonotonicityReport(
        fault: null,
        outOfOrderDelivery: false,
        deltaSeconds: delta,
      );
    }

    // delta < 0:回退。
    final bool sequenceSaysOutOfOrder =
        s.sequence != null && prevSeq != null && s.sequence! < prevSeq;

    if (sequenceSaysOutOfOrder && -delta < clockResetBackwardJumpSeconds) {
      // 序号也在后退 ⇒ 只是投递乱序,时钟没病。不推进 last。
      outOfOrderCount++;
      return MonotonicityReport(
        fault: null,
        outOfOrderDelivery: true,
        deltaSeconds: delta,
      );
    }

    if (-delta >= clockResetBackwardJumpSeconds) {
      resetCount++;
      // 时钟重置后必须重新锚定,否则后续每一条都会被判回退。
      _lastSeconds = t;
      _lastSequence = s.sequence;
      return MonotonicityReport(
        fault: TimebaseFault(
          kind: TimebaseFaultKind.clockReset,
          detail:
              '${stream.name} 流时间戳后退 ${(-delta).toStringAsFixed(3)}s,'
              '超过 ${clockResetBackwardJumpSeconds}s ⇒ 判为时钟基准被重置'
              '(重启残留样本 / 域被中途切换)',
          measuredSeconds: -delta,
          limitSeconds: clockResetBackwardJumpSeconds,
        ),
        outOfOrderDelivery: false,
        deltaSeconds: delta,
      );
    }

    backwardCount++;
    return MonotonicityReport(
      fault: TimebaseFault(
        kind: TimebaseFaultKind.nonMonotonic,
        detail:
            '${stream.name} 流时间戳后退 ${(-delta).toStringAsFixed(6)}s'
            '${s.sequence == null ? '(无 sequence,无法排除投递乱序,按 fail-closed 处理)' : '(sequence 仍在前进 ⇒ 真回退)'}',
        measuredSeconds: -delta,
        limitSeconds: 0.0,
      ),
      outOfOrderDelivery: false,
      deltaSeconds: delta,
    );
  }
}
