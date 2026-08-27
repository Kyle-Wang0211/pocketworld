// capability_probe.dart — 运行期自证的**判定器**(Blocker 04 任务 2 的核心交付)。
// 纯 Dart,零 Flutter 依赖。纯函数:同一份 evidence 必定得到同一个 decision。
//
// ── 这个文件替掉了什么 ──────────────────────────────────────────────────
// 替掉「逐机型白名单」。不查机型、不查型号串、不带任何设备表。
// 输入全是**这次会话当场量到的**事实([CapabilityEvidence]),输出是三档判定 + 原因。
// 因此新机型上市不需要我们做任何事,而占位拷贝的假 yaml(iPhone 16e 与
// iPhone 14 Pro 逐字节相同)也不再有机会毒化任何东西 —— 我们压根不读它。
//
// ── 门限从哪来 ──────────────────────────────────────────────────────────
// 能推的都推了,推不出来的**明确标为约定**并可由调用方覆盖。见
// [CapabilityThresholds]。没有一个门限是「感觉差不多」。

import 'capability_decision.dart';
import 'capability_evidence.dart';
import 'imu_timing_probe.dart';

/// 判定门限。全部可覆盖 —— 但**没有用户可见的档位**(铁律),这是工程常量,
/// 不是给用户拨的旋钮。
class CapabilityThresholds {
  const CapabilityThresholds({
    this.maxReprojectionErrorPx = 1.0,
    this.peakHandheldAngularRateDegPerSec = 100.0,
    this.absoluteImuHzFloor = 100.0,
    this.minImuSamplesPerFrame = 4.0,
    this.maxImuRelativeJitter = 0.25,
    this.maxFrameIntervalRatio = 2.0,
    this.fallbackFocalPx = 1000.0,
  });

  /// 允许的最大重投影错位。1px 是重建管线通用口径(见既有 Sampson/4.0px 转换链
  /// 的单位铁则),这里当时间对齐的预算上限。
  final double maxReprojectionErrorPx;

  /// 手持扫描时的角速度峰值(度/秒)。
  /// ⚠️ 这是**约定值,不是实测**:100°/s 是手持环绕拍摄常见峰值量级。
  ///    真机上应当用 pose_drift_tracker / orientation_tracker 实测的角速度 p99 覆盖它。
  final double peakHandheldAngularRateDegPerSec;

  /// IMU 速率绝对下限(Hz)。
  /// ⚠️ 100Hz 是**行业约定**,不是我们推出来的。锚点:Android 12(API 31)把所有
  ///    sensor 硬压到 200Hz(除非持有 HIGH_SAMPLING_RATE_SENSORS),100 是它的一半。
  final double absoluteImuHzFloor;

  /// 每个帧间隔至少要有几个 IMU 样本。
  /// 4 是**推导**的:梯形积分要在帧间有内点才谈得上积分,首尾各一个 + 至少两个内点。
  final double minImuSamplesPerFrame;

  /// IMU 相对抖动(MAD/中位)上限。
  /// ⚠️ 0.25 是约定值。含义:半数样本的间隔偏离中位不超过 1/4 个周期。
  final double maxImuRelativeJitter;

  /// 帧间隔 p95/中位 的上限。
  /// 2.0 是**推导**的:比值 ≥2 意味着 p95 那一帧至少跨掉了一个完整的帧周期,
  /// 也就是**真的掉了帧**,而不是抖了一下。热降频从这里露头。
  final double maxFrameIntervalRatio;

  /// 内参完全拿不到时,推导时间门限用的保守焦距(像素)。
  /// 焦距越大,同样的时间错位造成的像素错位越大 ⇒ 用偏小的值是**乐观**的,
  /// 所以这里只在「连 FOV 都没有」时兜底,且此时 intrinsicsUnavailable 已经抬旗了。
  final double fallbackFocalPx;

  /// 时间对齐的硬门限(纳秒),由焦距推出:
  ///
  ///   转动 ω 时,时间错位 dt 造成的像素位移 ≈ f · ω · dt
  ///   令其 ≤ maxReprojectionErrorPx ⇒ dt ≤ maxReprojectionErrorPx / (f · ω)
  ///
  /// 例:f=1400px、ω=100°/s=1.745rad/s ⇒ dt ≤ 409µs。
  /// 这就是为什么 xrapi 的 default(27.8ms)与 huawei/p40(6.42ms)差 21ms 是致命的:
  /// 两者都比这个门限大**一到两个数量级**,拿错一个就等于位姿直接报废。
  int maxTimebaseUncertaintyNs(double focalPx) {
    final double f = focalPx > 0 ? focalPx : fallbackFocalPx;
    final double omega =
        peakHandheldAngularRateDegPerSec * 3.141592653589793 / 180.0;
    if (f <= 0 || omega <= 0) return 0;
    return (maxReprojectionErrorPx / (f * omega) * 1e9).round();
  }
}

/// 一次会话开始时量到的全部事实。
class CapabilityEvidence {
  const CapabilityEvidence({
    required this.timebase,
    required this.imu,
    required this.intrinsics,
    required this.stabilization,
    required this.frameTiming,
    required this.platformPoseAvailable,
    this.rollingShutter = const RollingShutterFacts.unknown(),
  });

  final TimebaseFacts timebase;
  final ImuTimingFacts imu;
  final IntrinsicsFacts intrinsics;
  final StabilizationFacts stabilization;
  final FrameTimingFacts frameTiming;
  final RollingShutterFacts rollingShutter;

  /// 平台位姿在不在(iOS: ARSession 已 running 且 trackingState 正常;
  /// Android: ARCore 已安装且 session 可创建;眼镜端: 恒 true)。
  final bool platformPoseAvailable;

  /// `AVCaptureVideoStabilizationMode.off.rawValue` 的跨端协议值。
  ///
  /// 选择这个值是 Dart 策略;原生层只接受 raw int、机械赋值、
  /// 回传请求/活动 raw value,不自行选择或解释。
  static const int iosVideoStabilizationModeOffRawValue = 0;

  /// 从原生侧(ios/Runner/PwVioCapability.swift 的 evidenceWire /
  /// lib/vio/capability/android/PwVioCapability.kt 的各 *Wire)送上来的字典解出证据。
  ///
  /// 🔴 解析铁则:**缺字段一律解成「不可知」,绝不解成「没问题」。**
  ///    拿不到 stabilization → allUnknown(不是 off);
  ///    拿不到 timebase      → unrelatedUnmeasured(不是 unified);
  ///    拿不到 imu           → unmeasured(不是健康)。
  ///    这样通道少送一个字段时会**降级**,而不是静默放行 —— 后者正是
  ///    「装机≠生效」类事故的形状。
  ///
  /// IMU 的成簇/速率判定在这里就地跑 [ImuTimingProbe]:原生侧只搬运二元组,
  /// Otsu 算法两端共用一份实现、一套单测。
  factory CapabilityEvidence.fromWire(Map<Object?, Object?> wire) {
    return CapabilityEvidence(
      timebase: _timebaseFromWire(_map(wire['timebase'])),
      imu: _imuFromWire(_map(wire['imu'])),
      intrinsics: _intrinsicsFromWire(_map(wire['intrinsics'])),
      stabilization: _stabilizationFromWire(_map(wire['stabilization'])),
      frameTiming: _frameTimingFromWire(_map(wire['frameTiming'])),
      rollingShutter: RollingShutterFacts(
        readoutNs: _int(_map(wire['rollingShutter'])['readoutNs']),
      ),
      platformPoseAvailable: wire['platformPoseAvailable'] == true,
    );
  }

  static Map<Object?, Object?> _map(Object? v) =>
      v is Map<Object?, Object?> ? v : const <Object?, Object?>{};

  static int? _int(Object? v) => v is num ? v.toInt() : null;

  static double? _strictFiniteDouble(Object? v) {
    if (v is! num) return null;
    final double value = v.toDouble();
    return value.isFinite ? value : null;
  }

  static List<int>? _strictIntList(Object? v) {
    if (v is! List) return null;
    final List<int> out = <int>[];
    for (final Object? value in v) {
      if (value is! int) return null;
      out.add(value);
    }
    return List<int>.unmodifiable(out);
  }

  static int? _strictNonNegativeInt(Object? v) => v is int && v >= 0 ? v : null;

  static bool _hasExactKeys(Map<Object?, Object?> wire, Set<String> expected) =>
      wire.length == expected.length &&
      wire.keys.every((Object? key) => key is String && expected.contains(key));

  static bool _rawRingAccountingIsExact({
    required int? attempted,
    required int? retained,
    required int? overwritten,
    required int? capacity,
    required int payloadLength,
  }) {
    if (attempted == null ||
        retained == null ||
        overwritten == null ||
        capacity == null ||
        capacity <= 0 ||
        retained > capacity ||
        retained != payloadLength ||
        attempted != retained + overwritten) {
      return false;
    }
    if (attempted <= capacity) {
      return retained == attempted && overwritten == 0;
    }
    return retained == capacity && overwritten == attempted - capacity;
  }

  static TimebaseFacts _timebaseFromWire(Map<Object?, Object?> m) {
    switch (m['relation']) {
      case 'unified':
        return const TimebaseFacts.unified();
      case 'offsetMeasured':
        final int? u = _int(m['offsetUncertaintyNs']);
        // 说测出来了却没给误差界 = 通道有问题,当没测出来处理。
        if (u == null) {
          return const TimebaseFacts(
            relation: TimebaseRelation.unrelatedUnmeasured,
          );
        }
        return TimebaseFacts(
          relation: TimebaseRelation.offsetMeasured,
          offsetUncertaintyNs: u,
        );
      default:
        return const TimebaseFacts(
          relation: TimebaseRelation.unrelatedUnmeasured,
        );
    }
  }

  static ImuTimingFacts _imuFromWire(Map<Object?, Object?> m) {
    if (m['schema'] == 'pw.vio.imu-arrivals.raw.v1') {
      const Set<String> keys = <String>{
        'schema',
        'available',
        'sampleTsNs',
        'deliveryTsNs',
        'attemptedCount',
        'retainedCount',
        'overwrittenCount',
        'capacity',
      };
      if (!_hasExactKeys(m, keys) || m['available'] != true) {
        return const ImuTimingFacts.unmeasured();
      }
      final List<int>? sample = _strictIntList(m['sampleTsNs']);
      final List<int>? delivery = _strictIntList(m['deliveryTsNs']);
      if (sample == null ||
          delivery == null ||
          sample.length != delivery.length ||
          !_rawRingAccountingIsExact(
            attempted: _strictNonNegativeInt(m['attemptedCount']),
            retained: _strictNonNegativeInt(m['retainedCount']),
            overwritten: _strictNonNegativeInt(m['overwrittenCount']),
            capacity: _strictNonNegativeInt(m['capacity']),
            payloadLength: sample.length,
          ) ||
          m['overwrittenCount'] != 0) {
        // IMU 的整段时序会进入 Otsu/抖动分析。环形窗口一旦覆盖就已截断;
        // CapabilityEvidence 没有“部分窗口”语义,因此必须显式 fail closed。
        return const ImuTimingFacts.unmeasured();
      }
      return _analyzeImuPairs(sample, delivery);
    }

    // 所有平台必须使用同一个带容量与覆盖账的版本化 raw wire。无 schema
    // 或未知 schema 都 fail closed，避免某个平台悄悄绕过丢样审计。
    return const ImuTimingFacts.unmeasured();
  }

  static ImuTimingFacts _analyzeImuPairs(List<int> sample, List<int> delivery) {
    final List<ImuArrival> arrivals = <ImuArrival>[
      for (int i = 0; i < sample.length; i++)
        ImuArrival(sampleTsNs: sample[i], deliveryTsNs: delivery[i]),
    ];
    return ImuTimingProbe.analyze(arrivals);
  }

  static IntrinsicsFacts _intrinsicsFromWire(Map<Object?, Object?> m) {
    const Set<String> keys = <String>{
      'source',
      'fx',
      'fy',
      'cx',
      'cy',
      'skew',
      'referenceWidth',
      'referenceHeight',
    };
    if (!_hasExactKeys(m, keys) || m['source'] is! String) {
      return const IntrinsicsFacts.absent();
    }
    final IntrinsicsSource source = IntrinsicsSource.values.firstWhere(
      (IntrinsicsSource s) => s.name == m['source'],
      orElse: () => IntrinsicsSource.none,
    );
    if (source == IntrinsicsSource.none) return const IntrinsicsFacts.absent();

    final double? fx = _strictFiniteDouble(m['fx']);
    final double? fy = _strictFiniteDouble(m['fy']);
    final double? cx = _strictFiniteDouble(m['cx']);
    final double? cy = _strictFiniteDouble(m['cy']);
    final double? skew = _strictFiniteDouble(m['skew']);
    final int? width = _strictNonNegativeInt(m['referenceWidth']);
    final int? height = _strictNonNegativeInt(m['referenceHeight']);
    if (fx == null ||
        fy == null ||
        cx == null ||
        cy == null ||
        skew == null ||
        fx <= 0 ||
        fy <= 0 ||
        cx < 0 ||
        cy < 0 ||
        skew < 0 ||
        width == null ||
        height == null ||
        width <= 0 ||
        height <= 0) {
      return const IntrinsicsFacts.absent();
    }
    return IntrinsicsFacts(
      source: source,
      fx: fx,
      fy: fy,
      cx: cx,
      cy: cy,
      skew: skew,
      referenceWidth: width,
      referenceHeight: height,
    );
  }

  static StabilizationFacts _stabilizationFromWire(Map<Object?, Object?> m) {
    const Set<String> keys = <String>{
      'schema',
      'videoStabilizationSupported',
      'requestedPreferredModeRawValue',
      'requestedPreferredModeRecognized',
      'preferredModeAssignmentPerformed',
      'activeVideoStabilizationModeRawValue',
      'geometricDistortionCorrectionSupported',
      'geometricDistortionCorrectionEnabled',
      'opticalImageStabilizationPublicApiAvailable',
    };
    if (!_hasExactKeys(m, keys) ||
        m['schema'] != 'pw.vio.ios.stabilization-raw/1' ||
        m['videoStabilizationSupported'] is! bool ||
        m['requestedPreferredModeRawValue'] is! int ||
        m['requestedPreferredModeRecognized'] is! bool ||
        m['preferredModeAssignmentPerformed'] is! bool ||
        m['activeVideoStabilizationModeRawValue'] is! int ||
        m['geometricDistortionCorrectionSupported'] is! bool ||
        m['geometricDistortionCorrectionEnabled'] is! bool ||
        m['opticalImageStabilizationPublicApiAvailable'] is! bool) {
      return const StabilizationFacts.allUnknown();
    }

    final bool supported = m['videoStabilizationSupported']! as bool;
    final int requested = m['requestedPreferredModeRawValue']! as int;
    final bool recognized = m['requestedPreferredModeRecognized']! as bool;
    final bool assignmentPerformed =
        m['preferredModeAssignmentPerformed']! as bool;
    final int active = m['activeVideoStabilizationModeRawValue']! as int;
    final bool gdcSupported =
        m['geometricDistortionCorrectionSupported']! as bool;
    final bool gdcEnabled = m['geometricDistortionCorrectionEnabled']! as bool;

    // 协议事实自相矛盾、或原生层回显的请求不是 Dart 选的值,
    // 都不允许“猜”成安全。
    if (requested != iosVideoStabilizationModeOffRawValue ||
        !recognized ||
        assignmentPerformed != supported ||
        (!gdcSupported && gdcEnabled)) {
      return const StabilizationFacts.allUnknown();
    }

    final StabilizationState electronic = !supported
        ? StabilizationState.absent
        : active == iosVideoStabilizationModeOffRawValue
        ? StabilizationState.off
        : StabilizationState.on;

    // 该 raw schema 只能证明 iOS SDK 有没有 OIS 公开 API,不能证明
    // 镜组硬件没有防抖或防抖当下未激活;因此必须保持 unknown。
    return StabilizationFacts(
      electronic: electronic,
      optical: StabilizationState.unknown,
      electronicControllable: supported,
      opticalControllable: false,
    );
  }

  static FrameTimingFacts _frameTimingFromWire(Map<Object?, Object?> m) {
    if (m['schema'] == 'pw.vio.frame-arrivals.raw.v1') {
      const Set<String> keys = <String>{
        'schema',
        'arrivalHostTsNs',
        'attemptedCount',
        'retainedCount',
        'overwrittenCount',
        'capacity',
      };
      if (!_hasExactKeys(m, keys)) {
        return const FrameTimingFacts.unmeasured();
      }
      final List<int>? arrivals = _strictIntList(m['arrivalHostTsNs']);
      final int? attempted = _strictNonNegativeInt(m['attemptedCount']);
      final int? overwritten = _strictNonNegativeInt(m['overwrittenCount']);
      if (arrivals == null ||
          !_rawRingAccountingIsExact(
            attempted: attempted,
            retained: _strictNonNegativeInt(m['retainedCount']),
            overwritten: overwritten,
            capacity: _strictNonNegativeInt(m['capacity']),
            payloadLength: arrivals.length,
          ) ||
          overwritten != 0) {
        // 发生覆盖的环形窗口已经截断会话。FrameTimingFacts 没有
        // “部分窗口”语义,因此不得从剩下 512 帧推导会话统计。
        return const FrameTimingFacts.unmeasured();
      }
      final List<int> intervals = <int>[];
      for (int i = 1; i < arrivals.length; i++) {
        final int interval = arrivals[i] - arrivals[i - 1];
        if (interval <= 0) return const FrameTimingFacts.unmeasured();
        intervals.add(interval);
      }
      if (intervals.isEmpty) return const FrameTimingFacts.unmeasured();
      intervals.sort();
      final int middle = intervals.length ~/ 2;
      final int median = intervals.length.isOdd
          ? intervals[middle]
          : (intervals[middle - 1] + intervals[middle]) ~/ 2;
      final int p95Index = (intervals.length * 0.95).ceil() - 1;
      return FrameTimingFacts(
        frameCount: attempted!,
        medianIntervalNs: median,
        p95IntervalNs: intervals[p95Index],
      );
    }

    // 与 IMU 相同：跨端只接受版本化的有界原始到达时间账。
    return const FrameTimingFacts.unmeasured();
  }
}

class CapabilityProbe {
  const CapabilityProbe({this.thresholds = const CapabilityThresholds()});

  final CapabilityThresholds thresholds;

  /// 事实 → 判定。纯函数。
  CapabilityDecision decide(CapabilityEvidence e) {
    final List<BlockerReason> reasons = <BlockerReason>[];

    _checkStabilization(e, reasons);
    _checkIntrinsics(e, reasons);
    _checkTimebase(e, reasons);
    _checkImu(e, reasons);
    _checkFrameTiming(e, reasons);
    _checkRollingShutter(e, reasons);

    final bool anyFatal = reasons.any(
      (BlockerReason r) => r.poseSourceIndependent,
    );

    if (anyFatal) {
      // 换谁出位姿都救不了 —— 像素本身已经坏了。
      return CapabilityDecision(
        tier: CapabilityTier.unusable,
        poseSource: PoseSource.none,
        reasons: reasons,
        platformPoseAvailable: e.platformPoseAvailable,
      );
    }
    if (reasons.isEmpty) {
      return CapabilityDecision(
        tier: CapabilityTier.selfCoreOk,
        poseSource: PoseSource.selfVio,
        reasons: const <BlockerReason>[],
        platformPoseAvailable: e.platformPoseAvailable,
      );
    }
    if (e.platformPoseAvailable) {
      return CapabilityDecision(
        tier: CapabilityTier.degradeToPlatformPose,
        poseSource: PoseSource.platformVio,
        reasons: reasons,
        platformPoseAvailable: true,
      );
    }
    return CapabilityDecision(
      tier: CapabilityTier.unusable,
      poseSource: PoseSource.none,
      reasons: reasons,
      platformPoseAvailable: false,
    );
  }

  // ── 防抖 ────────────────────────────────────────────────────────────
  //
  // 🔴 这是唯一一条 pose-source-independent 的检查。
  void _checkStabilization(CapabilityEvidence e, List<BlockerReason> out) {
    final StabilizationFacts s = e.stabilization;
    if (s.anyConfirmedOn) {
      out.add(
        BlockerReason(
          blocker: CapabilityBlocker.stabilizationActive,
          detail:
              'Stabilization is ACTIVE (eis=${s.electronic.name}, '
              'ois=${s.optical.name}). Stabilized pixels no longer correspond to the '
              'physical IMU pose, and the warped frames also poison downstream SfM/MVS. '
              'Apple states this directly in AVCaptureDevice.h: intrinsics "should only '
              'be used when video stabilization is disabled".',
        ),
      );
      return;
    }
    if (s.anyUnknown) {
      out.add(
        BlockerReason(
          blocker: CapabilityBlocker.stabilizationUnverifiable,
          detail:
              'Stabilization state could not be read back '
              '(eis=${s.electronic.name}, ois=${s.optical.name}). Unknown is not off. '
              'On iOS there is no public OIS symbol in the SDK at all, so OIS is '
              'structurally unverifiable there.',
        ),
      );
    }
  }

  // ── 内参 ────────────────────────────────────────────────────────────
  void _checkIntrinsics(CapabilityEvidence e, List<BlockerReason> out) {
    final IntrinsicsFacts k = e.intrinsics;
    if (!k.isPresent) {
      out.add(
        const BlockerReason(
          blocker: CapabilityBlocker.intrinsicsUnavailable,
          detail:
              'No usable intrinsics from any of the four layers '
              '(per-frame attachment / platform tracker / static characteristics / FOV).',
        ),
      );
      return;
    }
    if (!k.principalPointPlausible) {
      out.add(
        BlockerReason(
          blocker: CapabilityBlocker.intrinsicsImplausible,
          detail:
              'Principal point (${k.cx.toStringAsFixed(1)}, '
              '${k.cy.toStringAsFixed(1)}) falls outside the reference frame '
              '${k.referenceWidth}x${k.referenceHeight}. The reference resolution was '
              'almost certainly mismatched — wrong intrinsics are worse than none.',
        ),
      );
    }
  }

  // ── 时间基 ──────────────────────────────────────────────────────────
  void _checkTimebase(CapabilityEvidence e, List<BlockerReason> out) {
    final int? unc = e.timebase.effectiveUncertaintyNs;
    if (unc == null) {
      out.add(
        const BlockerReason(
          blocker: CapabilityBlocker.timebaseUnresolved,
          detail:
              'Camera and IMU timestamps live in unrelated clock bases and the '
              'offset was not measured. The two streams cannot be fused at all.',
        ),
      );
      return;
    }
    final double focal = e.intrinsics.isPresent ? e.intrinsics.fx : 0.0;
    final int limit = thresholds.maxTimebaseUncertaintyNs(focal);
    if (unc > limit) {
      out.add(
        BlockerReason(
          blocker: CapabilityBlocker.timebaseUncertaintyTooLarge,
          detail:
              'Clock-offset uncertainty exceeds the budget derived from '
              'f=${focal > 0 ? focal.toStringAsFixed(0) : "fallback"}px and '
              '${thresholds.peakHandheldAngularRateDegPerSec.toStringAsFixed(0)} deg/s '
              'peak rotation at ${thresholds.maxReprojectionErrorPx}px reprojection.',
          measured: unc,
          threshold: limit,
        ),
      );
    }
  }

  // ── IMU ─────────────────────────────────────────────────────────────
  void _checkImu(CapabilityEvidence e, List<BlockerReason> out) {
    final ImuTimingFacts imu = e.imu;
    if (!imu.isMeasured) {
      out.add(
        BlockerReason(
          blocker: CapabilityBlocker.imuNotMeasured,
          detail:
              'IMU timing was not measurable (n=${imu.sampleCount}, need '
              '$kMinSamplesForTiming). "Unknown" is not "fine".',
          measured: imu.sampleCount,
          threshold: kMinSamplesForTiming,
        ),
      );
      return;
    }

    // 速率下限 = max(绝对地板, 每帧样本数 × 实测帧率)。
    // 帧率没量到时退化为只用绝对地板 —— 不假装知道。
    final double? frameHz = e.frameTiming.hz;
    final double required = frameHz != null
        ? _max(
            thresholds.absoluteImuHzFloor,
            thresholds.minImuSamplesPerFrame * frameHz,
          )
        : thresholds.absoluteImuHzFloor;
    final double hz = imu.hz!;
    if (hz < required) {
      out.add(
        BlockerReason(
          blocker: CapabilityBlocker.imuRateTooLow,
          detail:
              'Measured IMU rate is below the floor '
              '(absolute floor ${thresholds.absoluteImuHzFloor.toStringAsFixed(0)}Hz, '
              '${thresholds.minImuSamplesPerFrame.toStringAsFixed(0)} samples/frame at '
              '${frameHz?.toStringAsFixed(1) ?? "?"}fps).',
          measured: double.parse(hz.toStringAsFixed(2)),
          threshold: double.parse(required.toStringAsFixed(2)),
        ),
      );
    }

    if (imu.clustered) {
      out.add(
        BlockerReason(
          blocker: CapabilityBlocker.imuClusteredDelivery,
          detail:
              'IMU samples arrive in bursts of about '
              '${imu.estimatedBurstSize.toStringAsFixed(1)}. Batched delivery degenerates '
              'the gyro/accel interleave the tracker depends on.',
          measured: double.parse(imu.burstMassFraction.toStringAsFixed(3)),
          threshold: kMinBurstMassFraction,
        ),
      );
    }
    if (imu.flags.contains(ImuTimingFlag.syntheticTimestamps)) {
      out.add(
        const BlockerReason(
          blocker: CapabilityBlocker.imuTimestampsSynthetic,
          detail:
              'Per-sample intervals are equidistant beyond physical plausibility: '
              'the HAL fabricated the timestamps, so per-sample dt is not measured data.',
        ),
      );
    }
    final double jitter = imu.relativeJitter ?? double.infinity;
    if (jitter > thresholds.maxImuRelativeJitter) {
      out.add(
        BlockerReason(
          blocker: CapabilityBlocker.imuRateTooLow,
          detail:
              'IMU inter-sample jitter (relative MAD) is too high for '
              'preintegration to be trusted.',
          measured: double.parse(jitter.toStringAsFixed(3)),
          threshold: thresholds.maxImuRelativeJitter,
        ),
      );
    }
  }

  // ── 帧时序 ──────────────────────────────────────────────────────────
  void _checkFrameTiming(CapabilityEvidence e, List<BlockerReason> out) {
    final FrameTimingFacts f = e.frameTiming;
    if (!f.isMeasured) {
      // 帧时序量不到不是自研核的硬伤(只是不知道热状态),但它会让 IMU 速率
      // 下限退化成绝对地板。这里不抬旗,由 _checkImu 承担后果。
      return;
    }
    final double? ratio = f.intervalRatio;
    if (ratio != null && ratio > thresholds.maxFrameIntervalRatio) {
      out.add(
        BlockerReason(
          blocker: CapabilityBlocker.frameTimingUnstable,
          detail:
              'Frame interval p95/median indicates dropped frames — at this ratio '
              'the p95 frame spans at least one extra full frame period. Thermal '
              'throttling or overload.',
          measured: double.parse(ratio.toStringAsFixed(3)),
          threshold: thresholds.maxFrameIntervalRatio,
        ),
      );
    }
  }

  // ── 卷帘 ────────────────────────────────────────────────────────────
  //
  // 这里**只做合理性闸**,不做质量闸:典型手机读出时间本来就接近一个帧间隔
  // (30fps 下 20-30ms),拿它当质量门会把所有机型判死。真正的用法是把 readout
  // 当**参数**传给核,而不是当门。只有报了物理上不可能的值才说明字段本身不可信。
  void _checkRollingShutter(CapabilityEvidence e, List<BlockerReason> out) {
    final RollingShutterFacts rs = e.rollingShutter;
    if (!rs.isKnown) return;
    final int? frameNs = e.frameTiming.medianIntervalNs;
    if (frameNs == null || frameNs <= 0) return;
    if (rs.readoutNs! >= frameNs) {
      out.add(
        BlockerReason(
          blocker: CapabilityBlocker.rollingShutterImplausible,
          detail:
              'Reported rolling-shutter readout is not shorter than one frame '
              'interval, which is physically impossible for a running stream. AOSP '
              'bounds this key by getOutputMinFrameDuration, so the value is unreliable '
              'and must not be fed to the tracker.',
          measured: rs.readoutNs,
          threshold: frameNs,
        ),
      );
    }
  }

  static double _max(double a, double b) => a > b ? a : b;
}
