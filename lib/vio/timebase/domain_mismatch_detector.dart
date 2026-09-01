// domain_mismatch_detector.dart — 跨流(相机 ↔ IMU)时钟域错配检测与**阻断**。纯 Dart。
//
// 这是本战线的核心。病灶复述:t_cam 与 t_imu 不同域 ⇒ XRSLAM 的 IMU 归并条件
// 恒假 ⇒ preintegration 为空 ⇒ 求解器里一个 IMU 因子都没有 ⇒ 静默退化成纯单目
// SfM,而状态照常返回 TRACKING。
//
// 🔴 关键设计决定:**两个互相独立的检测器,任何一个响都阻断。**
//    它们的失效模式不重叠,所以是真正的冗余,而不是同一个判据换个写法:
//
//    ① [_SkewDetector] —— 看 |t_imu_latest − t_cam_latest| 的**绝对偏斜**。
//       抓「域整体错开」。对 Android 休眠差(秒~小时级)瞬间响。
//       盲区:偏斜小于结构上限时看不见(例如只错开 50 ms 的 td 偏置)。
//
//    ② [_PreintegrationCoverageDetector] —— 数**两个相邻相机帧之间到底有几条
//       IMU 样本**。这是 XRSLAM 那个失败模式的**直接观测量**:归并条件恒假
//       的外在表现就是「窗口里一条都没有」。
//       盲区:偏斜恰好小于 IMU 缓冲长度时,窗口里仍可能有样本。
//
//    ①② 合起来:大偏斜被①抓、缓冲耗尽被②抓;而②抓的是**后果**,所以哪怕
//    偏斜是我们没想到的形式(例如 IMU 流干脆死了),②照样响。
//
// ── ① 的阈值怎么来的(不是拍脑袋) ─────────────────────────────────────
// 设相机帧 k 到达时:
//     t_cam[k] ≈ now − L_cam            (L_cam = ISP + 投递流水线延迟)
//     t_imu    ≈ now − L_imu − q_imu    (q_imu ∈ [0, 1/f_imu) 采样量化)
// 于是合法偏斜
//     skew := t_imu − t_cam ∈ [ −(L_imu_batch + 1/f_imu),  L_cam ]
//
// 我们**不**去精确建模 L_cam:本检测器是**类别判别器**,不是精度仪器。
// 精度对齐是 [ClockOffsetEstimator] 的活。判别器只需要一条能把
//     「同域,只差流水线延迟」(10⁻² s 量级)
// 和
//     「异域」(Android 休眠差:息屏一分钟就 ≥ 10⁰ s,放一夜 ≥ 10³ s)
// 分开的线。两者相差 2–5 个数量级,所以把线画在 0.2 s 有一整个数量级的余量:
// 任何真实手机的相机流水线延迟都远小于 200 ms,任何值得一提的休眠差都远大于
// 200 ms。**这条线不需要逐机型标定,这正是它可靠的原因。**
//
// ── ② 的阈值怎么来的 ───────────────────────────────────────────────────
// 期望样本数 = 帧间隔 × f_imu。
//   • 实测 0 条        ⇒ 立即 fault。没有任何合法情形能让两帧之间一条 IMU
//                        都没有(f_imu ≥ 100 Hz,帧间隔 ≥ 1/60 s ⇒ 期望 ≥ 1.6)。
//   • 覆盖率 < [minCoverageRatio] ⇒ 计数;**连续** [starvedFrameLimit] 帧
//     才升级为 fault。单次打嗝是打嗝,连着三帧是系统性问题。
//
// ── 铁律 ────────────────────────────────────────────────────────────────
// 本检测器**只报告**,不丢数据。裁决交给 [TimebaseNormalizer],且裁决集合里
// 没有 drop(见 timebase_contract.dart)。

import 'dart:math' as math;

import 'timebase_contract.dart';

/// 采集速率配置。阈值由它**推导**,不硬编码。
class StreamRateConfig {
  const StreamRateConfig({
    required this.cameraHz,
    required this.imuHz,
    this.cameraPipelineLatencyAllowanceSeconds = 0.200,
    this.imuBatchAllowanceSeconds = 0.200,
  }) : assert(cameraHz > 0),
       assert(imuHz > 0);

  final double cameraHz;
  final double imuHz;

  /// t_imu 允许**领先** t_cam 的上限 —— 即相机流水线延迟的宽松上界。
  /// 200 ms:高于任何真实手机的 ISP+投递延迟,低于任何值得一提的休眠差。
  final double cameraPipelineLatencyAllowanceSeconds;

  /// t_imu 允许**落后** t_cam 的上限(IMU 批投递 / 队列积压)。
  final double imuBatchAllowanceSeconds;

  double get cameraPeriodSeconds => 1.0 / cameraHz;
  double get imuPeriodSeconds => 1.0 / imuHz;

  /// skew 的合法上界(t_imu 领先方向)。
  double get maxSkewLeadSeconds =>
      cameraPipelineLatencyAllowanceSeconds + imuPeriodSeconds;

  /// skew 的合法下界幅值(t_imu 落后方向)。
  double get maxSkewLagSeconds =>
      imuBatchAllowanceSeconds + imuPeriodSeconds + cameraPeriodSeconds;
}

/// 一次跨流检查的结果。
class DomainCheckResult {
  const DomainCheckResult({
    required this.faults,
    required this.skewSeconds,
    required this.imuSamplesInWindow,
    required this.expectedImuSamplesInWindow,
  });

  final List<TimebaseFault> faults;

  /// t_imu_latest − t_cam;没有 IMU 样本时为 null。
  final double? skewSeconds;

  /// 上一帧到本帧之间的 IMU 样本数;首帧为 null。
  final int? imuSamplesInWindow;

  /// 同一窗口按 [StreamRateConfig.imuHz] 推出的期望样本数;首帧为 null。
  final double? expectedImuSamplesInWindow;

  bool get isBlocking => faults.isNotEmpty;

  double? get coverageRatio {
    final int? n = imuSamplesInWindow;
    final double? e = expectedImuSamplesInWindow;
    if (n == null || e == null || e <= 0) return null;
    return n / e;
  }
}

/// 跨流域错配检测器。
///
/// 喂法:IMU 每来一条 [pushImu];相机每来一帧 [checkCameraFrame]。
/// 两路的时间都必须已经**归一化到同一参考钟**(即 [TimeDomain.pwNormalized]);
/// 传未归一化的值进来会被 assert 挡住 —— 这个检测器的职责是抓「归一化没做对」,
/// 不是替代归一化。
class DomainMismatchDetector {
  DomainMismatchDetector({
    required this.rates,
    this.minCoverageRatio = 0.5,
    this.starvedFrameLimit = 3,
    this.imuBufferSpanSeconds = 5.0,
  }) : assert(minCoverageRatio > 0 && minCoverageRatio <= 1),
       assert(starvedFrameLimit >= 1),
       assert(imuBufferSpanSeconds > 0);

  final StreamRateConfig rates;
  final double minCoverageRatio;
  final int starvedFrameLimit;
  final double imuBufferSpanSeconds;

  /// 已归一化的 IMU 时间戳环形缓冲(按时间裁剪)。
  final List<double> _imuTimes = <double>[];

  double? _lastCameraSeconds;
  int _consecutiveStarved = 0;

  // 诊断计数。
  int skewFaultCount = 0;
  int emptyWindowCount = 0;
  int starvedWindowCount = 0;
  int framesChecked = 0;

  double? get lastImuSeconds => _imuTimes.isEmpty ? null : _imuTimes.last;
  double? get lastCameraSeconds => _lastCameraSeconds;
  int get bufferedImuCount => _imuTimes.length;

  void reset() {
    _imuTimes.clear();
    _lastCameraSeconds = null;
    _consecutiveStarved = 0;
  }

  /// 送入一条**已归一化**的 IMU 时间戳。
  void pushImu(double normalizedSeconds) {
    _imuTimes.add(normalizedSeconds);
    // 只按最新样本自身的时间裁剪。注意不能拿相机时间来裁 —— 域错配时相机时间
    // 可能落在缓冲之外几千秒,那样会把整个缓冲清空,反而掩盖证据。
    final double cutoff = normalizedSeconds - imuBufferSpanSeconds;
    int drop = 0;
    while (drop < _imuTimes.length && _imuTimes[drop] < cutoff) {
      drop++;
    }
    if (drop > 0) _imuTimes.removeRange(0, drop);
  }

  /// 送入一帧**已归一化**的相机时间戳,返回检查结果。
  DomainCheckResult checkCameraFrame(double normalizedSeconds) {
    framesChecked++;
    final List<TimebaseFault> faults = <TimebaseFault>[];

    // ── ① 绝对偏斜 ──────────────────────────────────────────────────
    double? skew;
    final double? tImu = lastImuSeconds;
    if (tImu != null) {
      skew = tImu - normalizedSeconds;
      if (skew > rates.maxSkewLeadSeconds) {
        skewFaultCount++;
        faults.add(
          TimebaseFault(
            kind: TimebaseFaultKind.domainSkew,
            detail:
                't_imu 领先 t_cam ${skew.toStringAsFixed(6)}s,'
                '超过结构上限 ${rates.maxSkewLeadSeconds.toStringAsFixed(3)}s'
                '(= 相机流水线延迟余量 ${rates.cameraPipelineLatencyAllowanceSeconds}s '
                '+ IMU 周期 ${rates.imuPeriodSeconds.toStringAsFixed(4)}s)'
                ' ⇒ 两路不在同一时钟域',
            measuredSeconds: skew,
            limitSeconds: rates.maxSkewLeadSeconds,
          ),
        );
      } else if (-skew > rates.maxSkewLagSeconds) {
        skewFaultCount++;
        faults.add(
          TimebaseFault(
            kind: TimebaseFaultKind.domainSkew,
            detail:
                't_imu 落后 t_cam ${(-skew).toStringAsFixed(6)}s,'
                '超过结构上限 ${rates.maxSkewLagSeconds.toStringAsFixed(3)}s'
                ' ⇒ 两路不在同一时钟域,或 IMU 流已停',
            measuredSeconds: -skew,
            limitSeconds: rates.maxSkewLagSeconds,
          ),
        );
      }
    }

    // ── ② preintegration 窗口覆盖 ──────────────────────────────────
    int? inWindow;
    double? expected;
    final double? prevCam = _lastCameraSeconds;
    if (prevCam != null && normalizedSeconds > prevCam) {
      final double dt = normalizedSeconds - prevCam;
      expected = dt * rates.imuHz;
      inWindow = 0;
      for (final double t in _imuTimes) {
        if (t > prevCam && t <= normalizedSeconds) inWindow = inWindow! + 1;
      }

      if (inWindow == 0) {
        emptyWindowCount++;
        _consecutiveStarved++;
        faults.add(
          TimebaseFault(
            kind: TimebaseFaultKind.emptyPreintegrationWindow,
            detail:
                '相机帧间隔 ${dt.toStringAsFixed(4)}s 内 **0 条** IMU 样本'
                '(期望 ${expected.toStringAsFixed(1)} 条,缓冲里共 ${_imuTimes.length} 条,'
                '缓冲区间 ${_imuTimes.isEmpty ? "空" : "[${_imuTimes.first.toStringAsFixed(3)}, ${_imuTimes.last.toStringAsFixed(3)}]"})'
                ' ⇒ preintegration 必为空,求解器将退化成纯单目',
            measuredSeconds: dt,
            limitSeconds: 0.0,
          ),
        );
      } else if (expected > 0 && inWindow! / expected < minCoverageRatio) {
        starvedWindowCount++;
        _consecutiveStarved++;
        if (_consecutiveStarved >= starvedFrameLimit) {
          faults.add(
            TimebaseFault(
              kind: TimebaseFaultKind.emptyPreintegrationWindow,
              detail:
                  '连续 $_consecutiveStarved 帧 IMU 覆盖率不足'
                  '(本帧 $inWindow/${expected.toStringAsFixed(1)} = '
                  '${(inWindow / expected * 100).toStringAsFixed(1)}% < '
                  '${(minCoverageRatio * 100).toStringAsFixed(0)}%)'
                  ' ⇒ 系统性欠采样,不是单次打嗝',
              measuredSeconds: inWindow / expected,
              limitSeconds: minCoverageRatio,
            ),
          );
        }
      } else {
        _consecutiveStarved = 0;
      }
    }

    _lastCameraSeconds = normalizedSeconds;

    return DomainCheckResult(
      faults: faults,
      skewSeconds: skew,
      imuSamplesInWindow: inWindow,
      expectedImuSamplesInWindow: expected,
    );
  }

  /// 供上层做诊断展示。
  Map<String, Object?> diagnostics() => <String, Object?>{
    'framesChecked': framesChecked,
    'skewFaultCount': skewFaultCount,
    'emptyWindowCount': emptyWindowCount,
    'starvedWindowCount': starvedWindowCount,
    'consecutiveStarved': _consecutiveStarved,
    'bufferedImuCount': _imuTimes.length,
    'maxSkewLeadSeconds': rates.maxSkewLeadSeconds,
    'maxSkewLagSeconds': rates.maxSkewLagSeconds,
    'lastSkewSeconds': (lastImuSeconds != null && _lastCameraSeconds != null)
        ? lastImuSeconds! - _lastCameraSeconds!
        : null,
  };
}

/// 把 [DomainCheckResult] 里最严重的那条故障挑出来(用于日志/UI 只显示一条)。
TimebaseFault? mostSevere(List<TimebaseFault> faults) {
  if (faults.isEmpty) return null;
  const List<TimebaseFaultKind> order = <TimebaseFaultKind>[
    TimebaseFaultKind.emptyPreintegrationWindow,
    TimebaseFaultKind.domainSkew,
    TimebaseFaultKind.clockReset,
    TimebaseFaultKind.nonMonotonic,
    TimebaseFaultKind.duplicateTimestamp,
    TimebaseFaultKind.undeterminedDomain,
  ];
  faults.sort(
    (TimebaseFault a, TimebaseFault b) =>
        order.indexOf(a.kind).compareTo(order.indexOf(b.kind)),
  );
  return faults.first;
}

/// 便捷:按配置算出两条结构上限,便于测试与日志直接引用。
math.Point<double> structuralSkewBounds(StreamRateConfig c) =>
    math.Point<double>(-c.maxSkewLagSeconds, c.maxSkewLeadSeconds);
