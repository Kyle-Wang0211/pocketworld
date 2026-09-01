// timebase_normalizer.dart — 把各路原始时间戳归一化到会话参考钟,并 fail-closed。纯 Dart。
//
// 这是采集侧的**闸门**:相机帧和 IMU 样本都必须先过这里,拿到 accept 才允许
// 喂给 VIO。拿到 defer 的**必须留着**,拿到 fault 的**必须停下上报**。
// 铁律:没有 drop(见 timebase_contract.dart 文件头)。
//
// ── 曝光中心:把 Apple 的未文档化不确定性**量化**,而不是当成 0 ────────────
// Apple 对 `CMSampleBuffer.presentationTimeStamp` 只说它在
// `AVCaptureSession.synchronizationClock` 的 timebase 上,**从没说过它对应曝光
// 起点还是曝光中心**;`ARFrame.timestamp` 更是连域都没写。所以有两个假设:
//
//     H0: PTS = 曝光**中心**  ⇒ 正确修正量 f_true = 0.00 × D
//     H1: PTS = 曝光**起点**  ⇒ 正确修正量 f_true = 0.50 × D      (D = 曝光时长)
//
// 我们施加修正 f_applied × D,误差 = (f_true − f_applied) × D。
//   • f_applied = 0.0  ⇒ 最坏误差 0.50 D   (这就是「默认为 0」的代价,任务书
//                                            点名要避免的那个)
//   • f_applied = 0.5  ⇒ 最坏误差 0.50 D
//   • f_applied = 0.25 ⇒ 最坏误差 0.25 D   ← **minimax 最优**
//
// 所以默认取 [TimebaseNormalizerConfig.exposureCenterFraction] = 0.25,并把
// ±0.25 D 如实计入 [TimebaseVerdict.uncertaintySeconds]。这个数字是**可标定
// 常量**:真机上用陀螺角速度与图像光流的互相关峰值标定出真值后,把 fraction
// 设成实测值、把 uncertainty fraction 设成标定残差即可(见
// [TimebaseNormalizerConfig.calibratedExposure])。
//
// 量级感:1/60 s 曝光 ⇒ 0.25 D = 4.2 ms;手持横移 1 m/s 时对应 **4.2 mm** 的
// 位置误差 —— 正好落在我们「进 1%」的米制尺度 KPI 量级上。所以这个常量不是
// 学术洁癖,它直接吃掉我们的指标预算。
//
// ⚠️ 第三个未知量:卷帘快门。整帧只用一个时间戳时,物理上正确的锚点是**中间
//    行的读出时刻**,它与曝光中心不是一回事。本模块**不假装**能修卷帘 ——
//    只在 [TimebaseNormalizerConfig.rollingShutterReadoutSeconds] 非零时把
//    ±0.5×readout 也计进不确定度,把这笔账**记在明面上**。

import 'dart:math' as math;

import 'clock_offset_estimator.dart';
import 'domain_mismatch_detector.dart';
import 'monotonicity_detector.dart';
import 'timebase_contract.dart';

/// 归一化配置。
class TimebaseNormalizerConfig {
  const TimebaseNormalizerConfig({
    required this.rates,
    this.cameraDomain = TimeDomain.unknown,
    this.imuDomain = TimeDomain.unknown,
    this.referenceDomain = TimeDomain.appleHostTime,
    this.exposureCenterFraction = 0.25,
    this.exposureUncertaintyFraction = 0.25,
    this.rollingShutterReadoutSeconds = 0.0,
    this.maxAcceptableOffsetJitterSeconds = 0.020,
    this.minSamplesBeforeAccept = 16,
    this.offsetWindowSpanSeconds = 4.0,
  })  : assert(exposureCenterFraction >= -1.0 && exposureCenterFraction <= 1.0),
        assert(exposureUncertaintyFraction >= 0.0),
        assert(rollingShutterReadoutSeconds >= 0.0),
        assert(maxAcceptableOffsetJitterSeconds > 0);

  final StreamRateConfig rates;
  final TimeDomain cameraDomain;
  final TimeDomain imuDomain;
  final TimeDomain referenceDomain;

  /// 施加的曝光修正:t_corrected = t_pts + fraction × exposureDuration。
  /// 默认 0.25 = minimax(见文件头推导)。标定后改成实测值。
  final double exposureCenterFraction;

  /// 曝光修正的残余不确定度系数(× exposureDuration)。默认 0.25 = minimax 最坏误差。
  final double exposureUncertaintyFraction;

  /// 卷帘读出时长(秒)。非 0 时把 ±0.5×readout 计进不确定度。0 = 未知/全局快门。
  final double rollingShutterReadoutSeconds;

  /// 偏置抖动大于这个值就不给 accept(给 defer),因为归一化还不够准。
  /// 20 ms:低于结构判别线 200 ms 一个数量级,高于任何健康流的投递抖动。
  final double maxAcceptableOffsetJitterSeconds;

  final int minSamplesBeforeAccept;
  final double offsetWindowSpanSeconds;

  /// 标定后返回一份新配置。真机标定流程见 PwVioTimebase.swift 顶部说明。
  TimebaseNormalizerConfig calibratedExposure({
    required double measuredFraction,
    required double residualFraction,
  }) =>
      TimebaseNormalizerConfig(
        rates: rates,
        cameraDomain: cameraDomain,
        imuDomain: imuDomain,
        referenceDomain: referenceDomain,
        exposureCenterFraction: measuredFraction,
        exposureUncertaintyFraction: residualFraction,
        rollingShutterReadoutSeconds: rollingShutterReadoutSeconds,
        maxAcceptableOffsetJitterSeconds: maxAcceptableOffsetJitterSeconds,
        minSamplesBeforeAccept: minSamplesBeforeAccept,
        offsetWindowSpanSeconds: offsetWindowSpanSeconds,
      );
}

/// 会话级归一化闸门。
class TimebaseNormalizer {
  TimebaseNormalizer(this.config)
      : _cameraOffset = ClockOffsetEstimator(
          windowSpanSeconds: config.offsetWindowSpanSeconds,
          minSamples: config.minSamplesBeforeAccept,
        ),
        _imuOffset = ClockOffsetEstimator(
          windowSpanSeconds: config.offsetWindowSpanSeconds,
          minSamples: config.minSamplesBeforeAccept,
        ),
        _cameraMono = MonotonicityDetector(stream: StreamKind.camera),
        _imuMono = MonotonicityDetector(stream: StreamKind.imu),
        _cross = DomainMismatchDetector(rates: config.rates);

  final TimebaseNormalizerConfig config;

  final ClockOffsetEstimator _cameraOffset;
  final ClockOffsetEstimator _imuOffset;
  final MonotonicityDetector _cameraMono;
  final MonotonicityDetector _imuMono;
  final DomainMismatchDetector _cross;

  int acceptedCamera = 0;
  int acceptedImu = 0;
  int deferredCamera = 0;
  int deferredImu = 0;
  int faultedCamera = 0;
  int faultedImu = 0;

  ClockOffsetEstimate? get cameraOffsetEstimate => _cameraOffset.estimate();
  ClockOffsetEstimate? get imuOffsetEstimate => _imuOffset.estimate();
  DomainMismatchDetector get crossStream => _cross;

  void reset() {
    _cameraOffset.reset();
    _imuOffset.reset();
    _cameraMono.reset();
    _imuMono.reset();
    _cross.reset();
  }

  /// 该域是否**本身就是**参考域(无需偏置)。
  bool _isReference(TimeDomain d) =>
      d == config.referenceDomain || d == TimeDomain.pwNormalized;

  /// 求某一路的偏置。返回 null = 还测不出来(⇒ defer)。
  double? _offsetFor(
    TimestampSample s,
    ClockOffsetEstimator est,
    List<String> why,
  ) {
    if (_isReference(s.domain)) return 0.0;

    final double? arrival = s.hostArrivalSeconds;
    if (arrival == null) {
      why.add('样本未携带 hostArrivalSeconds,无法测量 ${s.domain.name} → '
          '${config.referenceDomain.name} 的偏置');
      return null;
    }
    est.add(srcSeconds: s.rawSeconds, refSeconds: arrival);

    final ClockOffsetEstimate? e = est.estimate();
    if (e == null) {
      why.add('偏置样本不足(${est.totalAdded}/${config.minSamplesBeforeAccept})');
      return null;
    }
    if (e.jitterSeconds > config.maxAcceptableOffsetJitterSeconds) {
      why.add('偏置抖动 ${(e.jitterSeconds * 1e3).toStringAsFixed(2)}ms 超过 '
          '${(config.maxAcceptableOffsetJitterSeconds * 1e3).toStringAsFixed(1)}ms');
      return null;
    }
    return e.offsetSeconds;
  }

  /// 提交一条 IMU 样本。
  TimebaseVerdict submitImu(TimestampSample s) {
    assert(s.stream == StreamKind.imu);
    final List<TimebaseFault> faults = <TimebaseFault>[];

    final MonotonicityReport m = _imuMono.observe(s);
    if (m.fault != null) faults.add(m.fault!);
    if (m.outOfOrderDelivery) {
      // 乱序不是故障,但这条样本的时间戳仍然有效(它只是晚到了)。
    }

    if (s.domain == TimeDomain.unknown) {
      faults.add(const TimebaseFault(
        kind: TimebaseFaultKind.undeterminedDomain,
        detail: 'IMU 流的时钟域为 unknown —— 不许当成任何已知域使用',
        measuredSeconds: 0,
        limitSeconds: 0,
      ));
    }

    if (faults.isNotEmpty) {
      faultedImu++;
      return TimebaseVerdict(decision: TimebaseDecision.fault, faults: faults);
    }

    final List<String> why = <String>[];
    final double? off = _offsetFor(s, _imuOffset, why);
    if (off == null) {
      deferredImu++;
      return TimebaseVerdict(
        decision: TimebaseDecision.defer,
        reason: why.join('; '),
      );
    }

    final double t = applyOffset(s.rawSeconds, off);
    _cross.pushImu(t);
    acceptedImu++;

    final ClockOffsetEstimate? e = _imuOffset.estimate();
    return TimebaseVerdict(
      decision: TimebaseDecision.accept,
      normalizedSeconds: t,
      uncertaintySeconds: e?.jitterSeconds ?? 0.0,
    );
  }

  /// 提交一帧相机时间戳。
  TimebaseVerdict submitCamera(TimestampSample s) {
    assert(s.stream == StreamKind.camera);
    final List<TimebaseFault> faults = <TimebaseFault>[];

    final MonotonicityReport m = _cameraMono.observe(s);
    if (m.fault != null) faults.add(m.fault!);

    if (s.domain == TimeDomain.unknown) {
      faults.add(const TimebaseFault(
        kind: TimebaseFaultKind.undeterminedDomain,
        detail: '相机流的时钟域为 unknown',
        measuredSeconds: 0,
        limitSeconds: 0,
      ));
    }

    if (faults.isNotEmpty) {
      faultedCamera++;
      return TimebaseVerdict(decision: TimebaseDecision.fault, faults: faults);
    }

    final List<String> why = <String>[];
    final double? off = _offsetFor(s, _cameraOffset, why);
    if (off == null) {
      deferredCamera++;
      return TimebaseVerdict(
        decision: TimebaseDecision.defer,
        reason: why.join('; '),
      );
    }

    // 曝光修正。
    final double d = s.exposureDurationSeconds ?? 0.0;
    final double t =
        applyOffset(s.rawSeconds, off) + config.exposureCenterFraction * d;

    // 跨流检查(这一步才是抓 XRSLAM 病灶的那一刀)。
    final DomainCheckResult cross = _cross.checkCameraFrame(t);
    if (cross.isBlocking) {
      faultedCamera++;
      return TimebaseVerdict(
        decision: TimebaseDecision.fault,
        faults: cross.faults,
        reason: '跨流域错配 / preintegration 窗口为空',
      );
    }

    final ClockOffsetEstimate? e = _cameraOffset.estimate();
    final double unc = (e?.jitterSeconds ?? 0.0) +
        config.exposureUncertaintyFraction * d +
        0.5 * config.rollingShutterReadoutSeconds;

    acceptedCamera++;
    return TimebaseVerdict(
      decision: TimebaseDecision.accept,
      normalizedSeconds: t,
      uncertaintySeconds: unc,
    );
  }

  /// 会话诊断快照。给 UI / 遥测用;**不含**任何用户可见的质量档位。
  Map<String, Object?> diagnostics() {
    final ClockOffsetEstimate? c = _cameraOffset.estimate();
    final ClockOffsetEstimate? i = _imuOffset.estimate();
    return <String, Object?>{
      'referenceDomain': config.referenceDomain.name,
      'cameraDomain': config.cameraDomain.name,
      'imuDomain': config.imuDomain.name,
      'cameraDomainOriginDocumented': config.cameraDomain.originIsDocumented,
      'imuDomainOriginDocumented': config.imuDomain.originIsDocumented,
      'cameraOffsetSeconds': c?.offsetSeconds,
      'cameraOffsetJitterMs':
          c == null ? null : c.jitterSeconds * 1e3,
      'cameraDriftPpm': c?.driftPpm,
      'cameraDriftSignificant': c?.driftIsSignificant,
      'imuOffsetSeconds': i?.offsetSeconds,
      'imuOffsetJitterMs': i == null ? null : i.jitterSeconds * 1e3,
      'imuDriftPpm': i?.driftPpm,
      'imuDriftSignificant': i?.driftIsSignificant,
      'exposureCenterFraction': config.exposureCenterFraction,
      'accepted': <String, int>{'camera': acceptedCamera, 'imu': acceptedImu},
      'deferred': <String, int>{'camera': deferredCamera, 'imu': deferredImu},
      'faulted': <String, int>{'camera': faultedCamera, 'imu': faultedImu},
      'cameraDuplicates': _cameraMono.duplicateCount,
      'cameraBackward': _cameraMono.backwardCount,
      'cameraResets': _cameraMono.resetCount,
      'imuDuplicates': _imuMono.duplicateCount,
      'imuBackward': _imuMono.backwardCount,
      'imuResets': _imuMono.resetCount,
      'cross': _cross.diagnostics(),
    };
  }
}

/// 把不确定度换算成**位置误差**(米),用于把时基预算和米制尺度 KPI 挂钩。
///
/// 这是本模块存在的商业理由的量化出口:时基不确定度 × 手持速度 = 位置误差。
double timingUncertaintyToMeters({
  required double uncertaintySeconds,
  required double handSpeedMetersPerSecond,
}) =>
    uncertaintySeconds * math.max(0.0, handSpeedMetersPerSecond);
