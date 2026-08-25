// capability_probe_test.dart — Blocker 04 能力探测的单测。
//
// ⚠️ 这个文件按 territory 约束**暂时放在 lib/ 下**。主会话应当把它 git mv 到
//    test/vio/capability_probe_test.dart。跑法(两种都可):
//      flutter test lib/vio/capability/capability_probe_test.dart
//      flutter test test/vio/capability_probe_test.dart      (搬过去之后)
//
// 覆盖三块:
//   A. ImuTimingProbe —— Otsu 成簇判定 + 速率/抖动
//   B. IntrinsicsFacts.remap —— crop/zoom 缩放的代数不变量
//   C. CapabilityProbe.decide —— 三档判定的真值表(含 pose-source-independent 例外)

import 'package:flutter_test/flutter_test.dart';

import 'package:pocketworld_flutter/vio/capability/capability_decision.dart';
import 'package:pocketworld_flutter/vio/capability/capability_evidence.dart';
import 'package:pocketworld_flutter/vio/capability/capability_probe.dart';
import 'package:pocketworld_flutter/vio/capability/imu_timing_probe.dart';

// ═══════════════════════════════════════════════════════════════════════
// 造数据用的确定性伪随机(LCG)。不用 dart:math 的 Random,保证跨机可复现。
// ═══════════════════════════════════════════════════════════════════════
class _Lcg {
  _Lcg(this._s);
  int _s;
  /// 返回 [-span, span] 内的整数。
  int jitter(int span) {
    _s = (_s * 1103515245 + 12345) & 0x7FFFFFFF;
    return (_s % (2 * span + 1)) - span;
  }
}

/// 未成簇的健康流:200Hz,采样与交付都近似等间隔。
List<ImuArrival> healthyStream({
  int n = 400,
  int periodNs = 5000000, // 200Hz
  int sampleJitterNs = 60000, // ±60µs,relative MAD 约 0.006
  int deliveryJitterNs = 200000,
}) {
  final _Lcg r = _Lcg(7);
  final List<ImuArrival> out = <ImuArrival>[];
  for (int i = 0; i < n; i++) {
    final int s = i * periodNs + r.jitter(sampleJitterNs);
    out.add(ImuArrival(
      sampleTsNs: s,
      deliveryTsNs: s + 1500000 + r.jitter(deliveryJitterNs),
    ));
  }
  return out;
}

/// 成簇流:采样仍是 200Hz,但每 [burst] 个样本被一次性交付。
List<ImuArrival> burstStream({
  int n = 400,
  int periodNs = 5000000,
  int burst = 5,
  int intraBurstNs = 20000, // 簇内 20µs
  int sampleJitterNs = 60000,
}) {
  final _Lcg r = _Lcg(11);
  final List<ImuArrival> out = <ImuArrival>[];
  for (int i = 0; i < n; i++) {
    final int s = i * periodNs + r.jitter(sampleJitterNs);
    final int batchIndex = i ~/ burst;
    final int within = i % burst;
    // 整批在这批最后一个样本采到之后才交付。
    final int delivery =
        (batchIndex + 1) * burst * periodNs + within * intraBurstNs;
    out.add(ImuArrival(sampleTsNs: s, deliveryTsNs: delivery));
  }
  return out;
}


/// 交付间隔**确实双峰**,但低峰离零还很远(0.4T / 1.6T 交替)。
/// 这不是 batching,是调度抖动 —— C2 存在的唯一目的就是拒掉它。
/// 参数是解出来的:低峰 a、高峰 b 等量交替时 (a+b)/2 = T。要让 C3(b ≥ 1.5T)
/// 通过而 C2(a ≤ 0.25T)拒绝,必须 0.25T < a ≤ 0.5T。取 a = 0.4T ⇒ b = 1.6T。
List<ImuArrival> jitteryButUnbatchedStream({
  int n = 400,
  int periodNs = 5000000,
}) {
  final _Lcg r = _Lcg(23);
  final List<ImuArrival> out = <ImuArrival>[];
  int delivery = 0;
  for (int i = 0; i < n; i++) {
    if (i > 0) {
      delivery += i.isOdd ? (periodNs * 4) ~/ 10 : (periodNs * 16) ~/ 10;
    }
    out.add(ImuArrival(
      sampleTsNs: i * periodNs + r.jitter(60000),
      deliveryTsNs: delivery,
    ));
  }
  return out;
}

// ═══════════════════════════════════════════════════════════════════════
// 健康证据(判定测试的基准);每个用例只改一个变量。
// ═══════════════════════════════════════════════════════════════════════
const IntrinsicsFacts kHealthyIntrinsics = IntrinsicsFacts(
  source: IntrinsicsSource.perFrameAttachment,
  fx: 1400,
  fy: 1400,
  cx: 960,
  cy: 540,
  referenceWidth: 1920,
  referenceHeight: 1080,
);

const FrameTimingFacts kHealthyFrames = FrameTimingFacts(
  frameCount: 300,
  medianIntervalNs: 33333333, // 30fps
  p95IntervalNs: 35000000, // ratio 1.05
);

const StabilizationFacts kAllOff = StabilizationFacts(
  electronic: StabilizationState.off,
  optical: StabilizationState.absent,
  electronicControllable: true,
  opticalControllable: true,
);

CapabilityEvidence healthyEvidence({
  TimebaseFacts? timebase,
  ImuTimingFacts? imu,
  IntrinsicsFacts? intrinsics,
  StabilizationFacts? stabilization,
  FrameTimingFacts? frameTiming,
  RollingShutterFacts? rollingShutter,
  bool platformPoseAvailable = true,
}) {
  return CapabilityEvidence(
    timebase: timebase ?? const TimebaseFacts.unified(),
    imu: imu ?? ImuTimingProbe.analyze(healthyStream()),
    intrinsics: intrinsics ?? kHealthyIntrinsics,
    stabilization: stabilization ?? kAllOff,
    frameTiming: frameTiming ?? kHealthyFrames,
    rollingShutter: rollingShutter ?? const RollingShutterFacts.unknown(),
    platformPoseAvailable: platformPoseAvailable,
  );
}

void main() {
  // ═════════════════════════════════════════════════════════════════════
  group('A. ImuTimingProbe', () {
    test('健康流:量出 200Hz,不判成簇', () {
      final ImuTimingFacts f = ImuTimingProbe.analyze(healthyStream());
      expect(f.isMeasured, isTrue);
      expect(f.hz, closeTo(200.0, 2.0));
      expect(f.clustered, isFalse,
          reason: '等间隔交付被判成簇 = C2/C3 门限失效');
      expect(f.estimatedBurstSize, 1.0);
      expect(f.relativeJitter, lessThan(0.05));
    });

    test('成簇流:判成簇,且 1/(1-p) 还原出簇长 5', () {
      final ImuTimingFacts f = ImuTimingProbe.analyze(burstStream(burst: 5));
      expect(f.clustered, isTrue,
          reason: '每 5 个样本一次性交付却没检出 batching');
      // p = 4/5 ⇒ 1/(1-p) = 5
      expect(f.estimatedBurstSize, closeTo(5.0, 0.15));
      // 采样速率不受交付方式影响 —— 这正是两条时间线必须分开看的原因。
      expect(f.hz, closeTo(200.0, 2.0));
    });

    test('簇长 2 也能检出(最小可观测成簇)', () {
      final ImuTimingFacts f = ImuTimingProbe.analyze(burstStream(burst: 2));
      expect(f.clustered, isTrue);
      expect(f.estimatedBurstSize, closeTo(2.0, 0.15));
    });

    test('采样戳完全等距 + 成簇 ⇒ 判为 HAL 合成时间戳', () {
      final ImuTimingFacts f =
          ImuTimingProbe.analyze(burstStream(sampleJitterNs: 0));
      expect(f.flags, contains(ImuTimingFlag.syntheticTimestamps));
    });

    test('真实抖动的成簇流不会被误判成合成时间戳', () {
      final ImuTimingFacts f =
          ImuTimingProbe.analyze(burstStream(sampleJitterNs: 60000));
      expect(f.clustered, isTrue);
      expect(f.flags, isNot(contains(ImuTimingFlag.syntheticTimestamps)));
    });

    test('样本不足:抬旗且不假装量到了', () {
      final ImuTimingFacts f = ImuTimingProbe.analyze(healthyStream(n: 50));
      expect(f.isMeasured, isFalse);
      expect(f.flags, contains(ImuTimingFlag.insufficientSamples));
      expect(f.hz, isNull, reason: '量不到就必须是 null,不能给个默认值');
    });

    test('时间戳倒流:抬旗但不丢样本', () {
      final List<ImuArrival> s = healthyStream();
      final List<ImuArrival> broken = List<ImuArrival>.of(s);
      broken[200] = ImuArrival(
        sampleTsNs: broken[199].sampleTsNs - 1000000,
        deliveryTsNs: broken[200].deliveryTsNs,
      );
      final ImuTimingFacts f = ImuTimingProbe.analyze(broken);
      expect(f.flags, contains(ImuTimingFlag.backwardsTimestamp));
      expect(f.sampleCount, broken.length,
          reason: '纯观察者铁律:offeredCount 必须恒等于 sampleCount');
    });

    test('大空洞:抬 gap 旗,且不污染中位周期', () {
      final List<ImuArrival> s = healthyStream();
      final List<ImuArrival> withGap = <ImuArrival>[];
      for (int i = 0; i < s.length; i++) {
        final int shift = i >= 200 ? 500000000 : 0; // 0.5s 挂起
        withGap.add(ImuArrival(
          sampleTsNs: s[i].sampleTsNs + shift,
          deliveryTsNs: s[i].deliveryTsNs + shift,
        ));
      }
      final ImuTimingFacts f = ImuTimingProbe.analyze(withGap);
      expect(f.flags, contains(ImuTimingFlag.gap));
      expect(f.hz, closeTo(200.0, 2.0),
          reason: '用中位数就是为了让一次挂起动不了周期估计');
    });

    test('🔴 C2 载重:交付间隔双峰但低峰=0.4T ⇒ 不是 batching,不得判成簇', () {
      final ImuTimingFacts f =
          ImuTimingProbe.analyze(jitteryButUnbatchedStream());
      // 先确认这份数据确实**越过了** C1 与 C3 —— 否则这个用例钉不住 C2。
      expect(f.burstMassFraction, greaterThanOrEqualTo(kMinBurstMassFraction),
          reason: 'C1 必须通过,否则拒绝来自 C1 而不是 C2');
      expect(f.clustered, isFalse,
          reason: '低峰离零还有 0.4 个采样周期,这是调度抖动不是成簇交付。'
              '判成簇说明 C2 没起作用。');
    });

    test('C1 对平稳流恒被 C3 蕴含(所以它不是独立的第三道闸)', () {
      // 平均簇长 k ⇒ 簇内间隔占比 p = (k−1)/k,簇间间隔 ≈ k·T。
      // C3 要求 k ≥ kBurstGapFactor = 1.5 ⇒ p ≥ 1/3 > kMinBurstMassFraction = 0.20。
      // 因此对任何平稳流,C3 一旦通过,C1 必然已经通过 —— C1 只在非平稳/样本
      // 极少的病态数据上才起作用。这条性质用常数直接钉住,免得日后调参调坏。
      for (final double k in <double>[1.5, 2, 3, 5, 8]) {
        final double p = (k - 1) / k;
        expect(p, greaterThanOrEqualTo(kMinBurstMassFraction),
            reason: 'k=$k 时 C1 反而比 C3 更松,常数组合失去自洽');
      }
      expect(kBurstGapFactor, greaterThan(1.0));
      expect((kBurstGapFactor - 1) / kBurstGapFactor,
          greaterThanOrEqualTo(kMinBurstMassFraction));
    });

    test('纯观察者:不修改入参', () {
      final List<ImuArrival> s = healthyStream();
      final List<int> before =
          s.map((ImuArrival a) => a.sampleTsNs).toList(growable: false);
      ImuTimingProbe.analyze(s);
      expect(s.map((ImuArrival a) => a.sampleTsNs).toList(), before);
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  group('B. IntrinsicsFacts.remap', () {
    test('恒等裁切是 no-op', () {
      final IntrinsicsFacts k = kHealthyIntrinsics.remap(
        cropInReference:
            const CropRect(x: 0, y: 0, width: 1920, height: 1080),
        outWidth: 1920,
        outHeight: 1080,
      );
      expect(k.fx, closeTo(1400, 1e-9));
      expect(k.cx, closeTo(960, 1e-9));
      expect(k.cy, closeTo(540, 1e-9));
    });

    test('纯缩放:f 与 c 同比例缩,视场角不变', () {
      final IntrinsicsFacts half = kHealthyIntrinsics.remap(
        cropInReference:
            const CropRect(x: 0, y: 0, width: 1920, height: 1080),
        outWidth: 960,
        outHeight: 540,
      );
      expect(half.fx, closeTo(700, 1e-9));
      expect(half.cx, closeTo(480, 1e-9));
      expect(half.horizontalFovDegrees,
          closeTo(kHealthyIntrinsics.horizontalFovDegrees, 1e-9),
          reason: '缩放不改变视场角');
    });

    test('2× 中心裁切:f 不变,主点按新原点平移,视场角减半方向正确', () {
      final IntrinsicsFacts z = kHealthyIntrinsics.remap(
        cropInReference:
            const CropRect(x: 480, y: 270, width: 960, height: 540),
        outWidth: 960,
        outHeight: 540,
      );
      expect(z.fx, closeTo(1400, 1e-9), reason: '等尺寸输出的裁切不改变焦距');
      expect(z.cx, closeTo(480, 1e-9));
      expect(z.horizontalFovDegrees,
          lessThan(kHealthyIntrinsics.horizontalFovDegrees));
    });

    test('🔴 非中心裁切:先减后乘。顺序反了会错开 crop.x*(sx-1)', () {
      // crop 原点 (300,0),宽 600 → 输出 1200,sx = 2
      final IntrinsicsFacts k = kHealthyIntrinsics.remap(
        cropInReference: const CropRect(x: 300, y: 0, width: 600, height: 1080),
        outWidth: 1200,
        outHeight: 1080,
      );
      // 正确: (960-300)*2 = 1320。 错误顺序(先乘后减): 960*2-300 = 1620。
      expect(k.cx, closeTo(1320, 1e-9));
      expect(k.cx, isNot(closeTo(1620, 1.0)));
    });

    test('两次 remap == 一次合成后的 remap', () {
      final IntrinsicsFacts twoStep = kHealthyIntrinsics
          .remap(
            cropInReference:
                const CropRect(x: 480, y: 270, width: 960, height: 540),
            outWidth: 960,
            outHeight: 540,
          )
          .remap(
            cropInReference:
                const CropRect(x: 0, y: 0, width: 960, height: 540),
            outWidth: 480,
            outHeight: 270,
          );
      final IntrinsicsFacts oneStep = kHealthyIntrinsics.remap(
        cropInReference:
            const CropRect(x: 480, y: 270, width: 960, height: 540),
        outWidth: 480,
        outHeight: 270,
      );
      expect(twoStep.fx, closeTo(oneStep.fx, 1e-9));
      expect(twoStep.cx, closeTo(oneStep.cx, 1e-9));
      expect(twoStep.cy, closeTo(oneStep.cy, 1e-9));
    });

    test('FOV 反推与 fx→FOV 往返一致', () {
      final IntrinsicsFacts k = IntrinsicsFacts.fromHorizontalFov(
        fovDegrees: 68.0,
        width: 1920,
        height: 1080,
      );
      expect(k.source, IntrinsicsSource.fieldOfViewFallback);
      expect(k.horizontalFovDegrees, closeTo(68.0, 1e-6));
      expect(k.cx, 960.0);
    });

    test('来源可信度序:每帧下发 > 平台跟踪器 > 静态表 > FOV > 无', () {
      expect(intrinsicsSourceRank(IntrinsicsSource.perFrameAttachment),
          greaterThan(intrinsicsSourceRank(IntrinsicsSource.platformTracker)));
      expect(intrinsicsSourceRank(IntrinsicsSource.platformTracker),
          greaterThan(
              intrinsicsSourceRank(IntrinsicsSource.staticCharacteristics)));
      expect(intrinsicsSourceRank(IntrinsicsSource.staticCharacteristics),
          greaterThan(
              intrinsicsSourceRank(IntrinsicsSource.fieldOfViewFallback)));
      expect(intrinsicsSourceRank(IntrinsicsSource.fieldOfViewFallback),
          greaterThan(intrinsicsSourceRank(IntrinsicsSource.none)));
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  group('C. CapabilityProbe.decide', () {
    const CapabilityProbe probe = CapabilityProbe();

    test('全健康 → SELF_CORE_OK,位姿来自自研核', () {
      final CapabilityDecision d = probe.decide(healthyEvidence());
      expect(d.tier, CapabilityTier.selfCoreOk, reason: d.toString());
      expect(d.poseSource, PoseSource.selfVio);
      expect(d.reasons, isEmpty);
      expect(d.canCapture, isTrue);
    });

    test('🔴 防抖确认开着 + 平台位姿在 → 仍然 UNUSABLE(与位姿来源无关)', () {
      final CapabilityDecision d = probe.decide(healthyEvidence(
        stabilization: const StabilizationFacts(
          electronic: StabilizationState.on,
          optical: StabilizationState.off,
        ),
        platformPoseAvailable: true,
      ));
      expect(d.tier, CapabilityTier.unusable,
          reason: '被 warp 的像素同样毒化 SfM,平台位姿救不了');
      expect(d.poseSource, PoseSource.none);
      expect(d.hasBlocker(CapabilityBlocker.stabilizationActive), isTrue);
      expect(d.fatalReasons, isNotEmpty);
    });

    test('OIS 确认开着(iOS 不可关的那一路)同样 UNUSABLE', () {
      final CapabilityDecision d = probe.decide(healthyEvidence(
        stabilization: const StabilizationFacts(
          electronic: StabilizationState.off,
          optical: StabilizationState.on,
        ),
      ));
      expect(d.tier, CapabilityTier.unusable);
    });

    test('防抖状态读不回来 → 只降级,不判死(unknown 不等于 on)', () {
      final CapabilityDecision d = probe.decide(healthyEvidence(
        stabilization: const StabilizationFacts.allUnknown(),
      ));
      expect(d.tier, CapabilityTier.degradeToPlatformPose);
      expect(
          d.hasBlocker(CapabilityBlocker.stabilizationUnverifiable), isTrue);
      expect(d.hasBlocker(CapabilityBlocker.stabilizationActive), isFalse);
    });

    test('内参拿不到 + 平台位姿在 → DEGRADE', () {
      final CapabilityDecision d = probe.decide(healthyEvidence(
        intrinsics: const IntrinsicsFacts.absent(),
      ));
      expect(d.tier, CapabilityTier.degradeToPlatformPose);
      expect(d.poseSource, PoseSource.platformVio);
      expect(d.hasBlocker(CapabilityBlocker.intrinsicsUnavailable), isTrue);
    });

    test('内参拿不到 + 平台位姿也没有 → UNUSABLE', () {
      final CapabilityDecision d = probe.decide(healthyEvidence(
        intrinsics: const IntrinsicsFacts.absent(),
        platformPoseAvailable: false,
      ));
      expect(d.tier, CapabilityTier.unusable);
      expect(d.poseSource, PoseSource.none);
    });

    test('主点落在画面外 → 判 implausible(错内参比没内参更危险)', () {
      final CapabilityDecision d = probe.decide(healthyEvidence(
        intrinsics: const IntrinsicsFacts(
          source: IntrinsicsSource.staticCharacteristics,
          fx: 1400,
          fy: 1400,
          cx: 2000, // > 1920:参考分辨率带错了
          cy: 540,
          referenceWidth: 1920,
          referenceHeight: 1080,
        ),
      ));
      expect(d.hasBlocker(CapabilityBlocker.intrinsicsImplausible), isTrue);
      expect(d.tier, CapabilityTier.degradeToPlatformPose);
    });

    test('时间基完全没解出来 → 阻断', () {
      final CapabilityDecision d = probe.decide(healthyEvidence(
        timebase: const TimebaseFacts(
            relation: TimebaseRelation.unrelatedUnmeasured),
      ));
      expect(d.hasBlocker(CapabilityBlocker.timebaseUnresolved), isTrue);
    });

    test('时间门限是推出来的:f=1400 下 100µs 过、21ms 不过', () {
      const CapabilityThresholds t = CapabilityThresholds();
      final int limit = t.maxTimebaseUncertaintyNs(1400);
      // 1 / (1400 * 100°/s) ≈ 409µs
      expect(limit, closeTo(409255, 50));

      final CapabilityDecision ok = probe.decide(healthyEvidence(
        timebase: const TimebaseFacts(
          relation: TimebaseRelation.offsetMeasured,
          offsetUncertaintyNs: 100000, // 100µs
        ),
      ));
      expect(ok.tier, CapabilityTier.selfCoreOk, reason: ok.toString());

      // xrapi default(27.8ms)与 huawei/p40(6.42ms)之差 ≈ 21.4ms
      final CapabilityDecision bad = probe.decide(healthyEvidence(
        timebase: const TimebaseFacts(
          relation: TimebaseRelation.offsetMeasured,
          offsetUncertaintyNs: 21400000,
        ),
      ));
      expect(
          bad.hasBlocker(CapabilityBlocker.timebaseUncertaintyTooLarge), isTrue,
          reason: '逐机型 time_offset 的量级差必须被这条门限抓住');
    });

    test('焦距越长,时间门限越紧(单调性)', () {
      const CapabilityThresholds t = CapabilityThresholds();
      expect(t.maxTimebaseUncertaintyNs(2800),
          lessThan(t.maxTimebaseUncertaintyNs(1400)));
    });

    test('IMU 速率下限随帧率抬升:60fps 下 200Hz 不再够', () {
      final CapabilityDecision at30 = probe.decide(healthyEvidence());
      expect(at30.tier, CapabilityTier.selfCoreOk);

      // 60fps ⇒ 需要 4×60 = 240Hz > 实测 200Hz
      final CapabilityDecision at60 = probe.decide(healthyEvidence(
        frameTiming: const FrameTimingFacts(
          frameCount: 300,
          medianIntervalNs: 16666667,
          p95IntervalNs: 17000000,
        ),
      ));
      expect(at60.hasBlocker(CapabilityBlocker.imuRateTooLow), isTrue,
          reason: '每帧 4 个 IMU 样本的下限必须跟着帧率走');
    });

    test('IMU 成簇 → 降级', () {
      final CapabilityDecision d = probe.decide(healthyEvidence(
        imu: ImuTimingProbe.analyze(burstStream(burst: 5)),
      ));
      expect(d.hasBlocker(CapabilityBlocker.imuClusteredDelivery), isTrue);
      expect(d.tier, CapabilityTier.degradeToPlatformPose);
    });

    test('IMU 完全没量到 → 阻断(不知道 ≠ 没问题)', () {
      final CapabilityDecision d = probe.decide(healthyEvidence(
        imu: const ImuTimingFacts.unmeasured(),
      ));
      expect(d.hasBlocker(CapabilityBlocker.imuNotMeasured), isTrue);
    });

    test('帧间隔 p95/中位 > 2 → 判掉帧(热降频)', () {
      final CapabilityDecision d = probe.decide(healthyEvidence(
        frameTiming: const FrameTimingFacts(
          frameCount: 300,
          medianIntervalNs: 33333333,
          p95IntervalNs: 100000000, // ratio 3.0
        ),
      ));
      expect(d.hasBlocker(CapabilityBlocker.frameTimingUnstable), isTrue);
    });

    test('卷帘只做合理性闸:典型 25ms 读出在 30fps 下不判死', () {
      final CapabilityDecision ok = probe.decide(healthyEvidence(
        rollingShutter: const RollingShutterFacts(readoutNs: 25000000),
      ));
      expect(ok.hasBlocker(CapabilityBlocker.rollingShutterImplausible),
          isFalse,
          reason: '把 readout 当质量门会把所有手机判死');
      expect(ok.tier, CapabilityTier.selfCoreOk);

      final CapabilityDecision bad = probe.decide(healthyEvidence(
        rollingShutter: const RollingShutterFacts(readoutNs: 40000000),
      ));
      expect(
          bad.hasBlocker(CapabilityBlocker.rollingShutterImplausible), isTrue);
    });

    test('眼镜端与手机端共用同一条降级路径', () {
      final CapabilityDecision hmd = CapabilityDecision.platformPoseByDesign();
      final CapabilityDecision phone = probe.decide(healthyEvidence(
        intrinsics: const IntrinsicsFacts.absent(),
      ));
      // 同一个类型、同一个 tier、同一个 PoseSource ⇒ 消费方只有一个 switch。
      expect(hmd.runtimeType, phone.runtimeType);
      expect(hmd.tier, phone.tier);
      expect(hmd.poseSource, phone.poseSource);
      expect(hmd.canCapture, isTrue);
      expect(hmd.hasBlocker(CapabilityBlocker.platformPoseByDesign), isTrue);
      expect(hmd.fatalReasons, isEmpty, reason: '按设计走平台位姿不是故障');
    });

    test('判定是纯函数:同输入同输出', () {
      final CapabilityEvidence e = healthyEvidence(
        stabilization: const StabilizationFacts.allUnknown(),
      );
      final CapabilityDecision a = probe.decide(e);
      final CapabilityDecision b = probe.decide(e);
      expect(a.tier, b.tier);
      expect(a.blockers, b.blockers);
    });

    test('多重阻断:原因全部列出,不是只报第一条', () {
      final CapabilityDecision d = probe.decide(healthyEvidence(
        intrinsics: const IntrinsicsFacts.absent(),
        imu: ImuTimingProbe.analyze(burstStream(burst: 5)),
        frameTiming: const FrameTimingFacts(
          frameCount: 300,
          medianIntervalNs: 33333333,
          p95IntervalNs: 100000000,
        ),
      ));
      expect(d.blockers, contains(CapabilityBlocker.intrinsicsUnavailable));
      expect(d.blockers, contains(CapabilityBlocker.imuClusteredDelivery));
      expect(d.blockers, contains(CapabilityBlocker.frameTimingUnstable));
      expect(d.reasons.length, greaterThanOrEqualTo(3));
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  group('D. CapabilityEvidence.fromWire', () {
    const CapabilityProbe probe = CapabilityProbe();

    Map<Object?, Object?> healthyWire() {
      final List<ImuArrival> s = healthyStream();
      return <Object?, Object?>{
        'timebase': <Object?, Object?>{
          'relation': 'unified',
          'offsetUncertaintyNs': 0,
        },
        'stabilization': <Object?, Object?>{
          'electronic': 'off',
          'optical': 'absent',
          'electronicControllable': true,
          'opticalControllable': true,
        },
        'intrinsics': <Object?, Object?>{
          'source': 'perFrameAttachment',
          'fx': 1400.0, 'fy': 1400.0, 'cx': 960.0, 'cy': 540.0, 'skew': 0.0,
          'referenceWidth': 1920, 'referenceHeight': 1080,
        },
        'imu': <Object?, Object?>{
          'sampleTsNs': s.map((ImuArrival a) => a.sampleTsNs).toList(),
          'deliveryTsNs': s.map((ImuArrival a) => a.deliveryTsNs).toList(),
        },
        'frameTiming': <Object?, Object?>{
          'frameCount': 300,
          'medianIntervalNs': 33333333,
          'p95IntervalNs': 35000000,
        },
        'rollingShutter': <Object?, Object?>{'readoutNs': null},
        'platformPoseAvailable': true,
      };
    }

    test('原生侧健康字典 → SELF_CORE_OK(端到端解析+判定)', () {
      final CapabilityDecision d =
          probe.decide(CapabilityEvidence.fromWire(healthyWire()));
      expect(d.tier, CapabilityTier.selfCoreOk, reason: d.toString());
    });

    test('🔴 空字典必须降级,绝不放行(缺字段=不可知,不是没问题)', () {
      final CapabilityEvidence e =
          CapabilityEvidence.fromWire(const <Object?, Object?>{});
      expect(e.timebase.relation, TimebaseRelation.unrelatedUnmeasured);
      expect(e.stabilization.electronic, StabilizationState.unknown);
      expect(e.imu.isMeasured, isFalse);
      expect(e.intrinsics.isPresent, isFalse);
      expect(e.platformPoseAvailable, isFalse);
      expect(probe.decide(e).tier, CapabilityTier.unusable);
    });

    test('🔴 单独抽掉 stabilization 字段 → 从 OK 掉到 DEGRADE', () {
      final Map<Object?, Object?> w = healthyWire()..remove('stabilization');
      final CapabilityDecision d =
          probe.decide(CapabilityEvidence.fromWire(w));
      expect(d.tier, CapabilityTier.degradeToPlatformPose,
          reason: '通道少送一个字段却仍判 selfCoreOk,就是「装机≠生效」的形状');
      expect(
          d.hasBlocker(CapabilityBlocker.stabilizationUnverifiable), isTrue);
    });

    test('声称 offsetMeasured 却不给误差界 → 当作没测出来', () {
      final Map<Object?, Object?> w = healthyWire();
      w['timebase'] = <Object?, Object?>{'relation': 'offsetMeasured'};
      final CapabilityEvidence e = CapabilityEvidence.fromWire(w);
      expect(e.timebase.relation, TimebaseRelation.unrelatedUnmeasured);
    });

    test('IMU 两条数组长度不一致 → 判为未测量,不做截断配对', () {
      final Map<Object?, Object?> w = healthyWire();
      final Map<Object?, Object?> imu =
          Map<Object?, Object?>.of(w['imu']! as Map<Object?, Object?>);
      // 🔴 必须截到 **仍然 ≥ kMinSamplesForTiming** 的长度(400→300)。
      // 截到 100 的话,即使配错了也会因为"样本不足"而判 unmeasured —— 用例
      // 会因为**错误的原因**通过,长度检查根本没被考到。(这条是负向对照 NC8
      // 抓出来的:去掉长度检查后测试仍然全绿。)
      imu['deliveryTsNs'] =
          (imu['deliveryTsNs']! as List<Object?>).sublist(0, 300);
      w['imu'] = imu;
      expect(CapabilityEvidence.fromWire(w).imu.isMeasured, isFalse,
          reason: '错位配对会造出假的交付间隔,宁可判不可知');
    });

    test('未知的 source 字符串 → 解成 none 而不是崩', () {
      final Map<Object?, Object?> w = healthyWire();
      w['intrinsics'] = <Object?, Object?>{'source': 'someFutureSource'};
      expect(CapabilityEvidence.fromWire(w).intrinsics.isPresent, isFalse);
    });
  });
}
