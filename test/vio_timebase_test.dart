// vio_timebase_test.dart — lib/vio/timebase/ 的单测。
//
// 跑法:flutter test test/vio_timebase_test.dart(或直接 flutter test)
//
// 每个 group 末尾都标注了它的**负向对照**:破坏什么会让它变红。

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pocketworld_flutter/vio/timebase/android_boottime_bridge.dart';
import 'package:pocketworld_flutter/vio/timebase/clock_offset_estimator.dart';
import 'package:pocketworld_flutter/vio/timebase/domain_mismatch_detector.dart';
import 'package:pocketworld_flutter/vio/timebase/ios_timebase_channel.dart';
import 'package:pocketworld_flutter/vio/timebase/monotonicity_detector.dart';
import 'package:pocketworld_flutter/vio/timebase/timebase_contract.dart';
import 'package:pocketworld_flutter/vio/timebase/timebase_normalizer.dart';

/// 可复现的单边非负投递延迟:大部分很小,偶尔很大。min-filter 就是要吃掉它。
double _delay(math.Random rng, {double base = 0.0015}) {
  final double u = rng.nextDouble();
  if (u < 0.15) return 0.0; // 偶尔「零延迟」样本,让 min 收敛到真值
  if (u > 0.92) return base + 0.030 * rng.nextDouble(); // 长尾
  return base * rng.nextDouble();
}

void main() {
  group('ClockOffsetEstimator (min-filter)', () {
    test('样本不足时返回 null,而不是凑一个值出来', () {
      final ClockOffsetEstimator e = ClockOffsetEstimator(minSamples: 16);
      for (int i = 0; i < 15; i++) {
        e.add(srcSeconds: i * 0.005, refSeconds: i * 0.005 + 1.0);
      }
      expect(e.estimate(), isNull);
      e.add(srcSeconds: 15 * 0.005, refSeconds: 15 * 0.005 + 1.0);
      expect(e.estimate(), isNotNull);
    });

    test('单边非负延迟下 min-filter 收敛到真偏置(均值会明显偏高)', () {
      final math.Random rng = math.Random(20260823);
      const double trueOffset = -3600.0; // 模拟 boottime↔monotonic 的休眠差
      final ClockOffsetEstimator e = ClockOffsetEstimator(
        minSamples: 16,
        windowSpanSeconds: 4.0,
      );
      final List<double> deltas = <double>[];
      for (int i = 0; i < 400; i++) {
        final double host = i * 0.005;
        final double src = host - trueOffset; // host = src + trueOffset
        final double arrival = host + _delay(rng);
        e.add(srcSeconds: src, refSeconds: arrival);
        deltas.add(arrival - src);
      }
      final ClockOffsetEstimate est = e.estimate()!;
      // min-filter 是真偏置的上界,且偏差 = min(d) ≈ 0
      expect(est.offsetSeconds, greaterThanOrEqualTo(trueOffset - 1e-12));
      expect(est.offsetSeconds - trueOffset, lessThan(1e-6));
      // 均值明显更差 —— 这就是不用均值的理由,数字化地钉住
      final double mean =
          deltas.reduce((double a, double b) => a + b) / deltas.length;
      expect(mean - trueOffset, greaterThan(1e-4));
      expect(est.jitterSeconds, greaterThan(0.0));
    });

    test('无漂移时 driftIsSignificant 为 false;注入 200ppm 漂移后为 true', () {
      final math.Random rng = math.Random(7);
      ClockOffsetEstimator mk() =>
          ClockOffsetEstimator(minSamples: 16, windowSpanSeconds: 2.0);

      final ClockOffsetEstimator flat = mk();
      for (int i = 0; i < 4000; i++) {
        final double host = i * 0.005;
        flat.add(srcSeconds: host - 1.0, refSeconds: host + _delay(rng));
        flat.estimate(); // 让锚点在第一个成熟窗建立
      }
      expect(flat.estimate()!.driftIsSignificant, isFalse);

      final ClockOffsetEstimator drifting = mk();
      const double ppm = 200.0;
      for (int i = 0; i < 4000; i++) {
        final double host = i * 0.005;
        final double off = -1.0 - ppm * 1e-6 * host;
        drifting.add(srcSeconds: host - off, refSeconds: host + _delay(rng));
        drifting.estimate();
      }
      final ClockOffsetEstimate d = drifting.estimate()!;
      expect(d.driftIsSignificant, isTrue);
      expect(d.driftPpm.abs(), closeTo(ppm, ppm * 0.35));
    });
    // 负向对照:把 estimate() 里的 minDelta 换成 p50 ⇒ 第 2 个 test 的
    // `est.offsetSeconds - trueOffset < 1e-6` 立刻失败。
  });

  group('bracketOffset (Cristian 夹逼)', () {
    test('给出硬上下界,真值必落在区间内', () {
      const double trueOffset = 12345.678;
      const double a = 100.000000;
      const double c = 100.000004; // 4 us 读取开销
      final double m = (a + c) / 2 - trueOffset;
      final BracketedOffset o = bracketOffset(
        refBefore: a,
        srcMid: m,
        refAfter: c,
      );
      expect(o.halfWidthSeconds, closeTo(2e-6, 1e-12));
      expect(o.lowerBound, lessThanOrEqualTo(trueOffset));
      expect(o.upperBound, greaterThanOrEqualTo(trueOffset));
    });

    test('参考钟回退时抛异常(fail-closed,不返回悄悄错掉的偏置)', () {
      expect(
        () => bracketOffset(refBefore: 10.0, srcMid: 1.0, refAfter: 9.0),
        throwsArgumentError,
      );
    });

    test('OffsetTracker 把 3600s 休眠识别为不相交跳变', () {
      final OffsetTracker t = OffsetTracker();
      expect(
        t.record(
          bracketOffset(refBefore: 1.0, srcMid: 1.0, refAfter: 1.000002),
        ),
        isFalse,
      );
      expect(
        t.record(
          bracketOffset(refBefore: 2.0, srcMid: 2.0, refAfter: 2.000002),
        ),
        isFalse, // 偏置没变
      );
      final bool jumped = t.record(
        bracketOffset(refBefore: 3.0, srcMid: 3.0 - 3600.0, refAfter: 3.000002),
      );
      expect(jumped, isTrue);
      expect(t.jumpCount, 1);
      expect(t.lastJumpSeconds, closeTo(3600.0, 1e-3));
    });
    // 负向对照:把 isDisjointFrom 改成恒 false ⇒ 第 3 个 test 变红。
  });

  group('IosRawClockSandwich', () {
    test(
      'Dart derives midpoint width and half-width from three raw endpoints',
      () {
        final IosRawClockSandwich sample =
            IosRawClockSandwich.fromMap(<Object?, Object?>{
              'uptimeRawBeforeSeconds': 100.0,
              'monotonicSeconds': 123.0,
              'uptimeRawAfterSeconds': 100.000004,
            });
        expect(sample.schemaValid, isTrue);
        expect(sample.uptimeRawSeconds, closeTo(100.000002, 1e-12));
        expect(sample.readCostSeconds, closeTo(4e-6, 1e-12));
        expect(sample.halfWidthSeconds, closeTo(2e-6, 1e-12));
      },
    );

    test('clock reversal fails closed instead of being clamped to zero', () {
      final IosRawClockSandwich sample =
          IosRawClockSandwich.fromMap(<Object?, Object?>{
            'uptimeRawBeforeSeconds': 100.0,
            'monotonicSeconds': 123.0,
            'uptimeRawAfterSeconds': 99.0,
          });
      expect(sample.schemaValid, isFalse);
    });
  });

  group('MonotonicityDetector', () {
    TimestampSample s(double t, {int? seq}) => TimestampSample(
      rawSeconds: t,
      domain: TimeDomain.appleCoreMotionBoot,
      stream: StreamKind.imu,
      sequence: seq,
    );

    test('单调递增全部放行', () {
      final MonotonicityDetector d = MonotonicityDetector(
        stream: StreamKind.imu,
      );
      for (int i = 0; i < 50; i++) {
        expect(d.observe(s(i * 0.005)).isFaulty, isFalse);
      }
    });

    test('重复戳被抓(Δt=0 会毒化 preintegration)', () {
      final MonotonicityDetector d = MonotonicityDetector(
        stream: StreamKind.imu,
      );
      d.observe(s(1.0));
      final MonotonicityReport r = d.observe(s(1.0));
      expect(r.fault?.kind, TimebaseFaultKind.duplicateTimestamp);
      expect(d.duplicateCount, 1);
    });

    test('小幅回退且无 sequence ⇒ 按真回退处理(fail-closed)', () {
      final MonotonicityDetector d = MonotonicityDetector(
        stream: StreamKind.imu,
      );
      d.observe(s(1.0));
      final MonotonicityReport r = d.observe(s(0.995));
      expect(r.fault?.kind, TimebaseFaultKind.nonMonotonic);
    });

    test('小幅回退但 sequence 也在回退 ⇒ 判为投递乱序,不算故障', () {
      final MonotonicityDetector d = MonotonicityDetector(
        stream: StreamKind.imu,
      );
      d.observe(s(1.0, seq: 10));
      final MonotonicityReport r = d.observe(s(0.995, seq: 9));
      expect(r.isFaulty, isFalse);
      expect(r.outOfOrderDelivery, isTrue);
      expect(d.outOfOrderCount, 1);
    });

    test('大幅回退 ⇒ 判为时钟重置,并重新锚定', () {
      final MonotonicityDetector d = MonotonicityDetector(
        stream: StreamKind.imu,
      );
      d.observe(s(3600.0));
      final MonotonicityReport r = d.observe(s(0.5));
      expect(r.fault?.kind, TimebaseFaultKind.clockReset);
      // 重新锚定后,后续递增不再报错
      expect(d.observe(s(0.51)).isFaulty, isFalse);
    });
    // 负向对照:把 observe() 里 delta<0 的分支改成 return 正常 ⇒ 三个 test 变红。
  });

  group('DomainMismatchDetector — 3600s 休眠差注入', () {
    const StreamRateConfig rates = StreamRateConfig(
      cameraHz: 30.0,
      imuHz: 200.0,
    );

    test('健康流:零故障', () {
      final DomainMismatchDetector d = DomainMismatchDetector(rates: rates);
      double t = 0.0;
      for (int frame = 0; frame < 90; frame++) {
        for (int k = 0; k < 200 ~/ 30; k++) {
          d.pushImu(t + k * (1.0 / 200.0));
        }
        final DomainCheckResult r = d.checkCameraFrame(t + 1.0 / 200.0);
        expect(r.faults, isEmpty, reason: 'frame $frame: ${r.faults}');
        t += 1.0 / 30.0;
      }
      expect(d.emptyWindowCount, 0);
      expect(d.skewFaultCount, 0);
    });

    test('IMU 整体 +3600s(模拟 BOOTTIME vs MONOTONIC)⇒ 偏斜与空窗口都触发', () {
      final DomainMismatchDetector d = DomainMismatchDetector(rates: rates);
      const double sleepOffset = 3600.0;
      double t = 0.0;
      final Set<TimebaseFaultKind> seen = <TimebaseFaultKind>{};
      for (int frame = 0; frame < 30; frame++) {
        for (int k = 0; k < 200 ~/ 30; k++) {
          d.pushImu(t + k * (1.0 / 200.0) + sleepOffset);
        }
        final DomainCheckResult r = d.checkCameraFrame(t);
        seen.addAll(r.faults.map((TimebaseFault f) => f.kind));
        t += 1.0 / 30.0;
      }
      expect(seen, contains(TimebaseFaultKind.domainSkew));
      expect(seen, contains(TimebaseFaultKind.emptyPreintegrationWindow));
      expect(d.skewFaultCount, greaterThan(0));
      expect(d.emptyWindowCount, greaterThan(0));
    });

    test('偏移 60s(息屏一分钟)同样被拦住 —— 不需要小时级才响', () {
      final DomainMismatchDetector d = DomainMismatchDetector(rates: rates);
      double t = 0.0;
      bool blocked = false;
      for (int frame = 0; frame < 10; frame++) {
        for (int k = 0; k < 6; k++) {
          d.pushImu(t + k * (1.0 / 200.0) + 60.0);
        }
        blocked = blocked || d.checkCameraFrame(t).isBlocking;
        t += 1.0 / 30.0;
      }
      expect(blocked, isTrue);
    });

    test('结构上限确实在 0.2s 量级(判别器而非精度仪器)', () {
      final math.Point<double> b = structuralSkewBounds(rates);
      expect(b.y, closeTo(0.200 + 1 / 200.0, 1e-9));
      expect(b.x, lessThan(-0.2));
      expect(b.y, lessThan(1.0)); // 远低于任何值得一提的休眠差
    });

    test('IMU 流突然停死 ⇒ 空窗口故障(②抓后果,与偏斜大小无关)', () {
      final DomainMismatchDetector d = DomainMismatchDetector(rates: rates);
      double t = 0.0;
      for (int frame = 0; frame < 10; frame++) {
        for (int k = 0; k < 6; k++) {
          d.pushImu(t + k * (1.0 / 200.0));
        }
        d.checkCameraFrame(t);
        t += 1.0 / 30.0;
      }
      // IMU 死掉,相机继续
      bool sawEmpty = false;
      for (int frame = 0; frame < 5; frame++) {
        t += 1.0 / 30.0;
        final DomainCheckResult r = d.checkCameraFrame(t);
        sawEmpty =
            sawEmpty ||
            r.faults.any(
              (TimebaseFault f) =>
                  f.kind == TimebaseFaultKind.emptyPreintegrationWindow,
            );
      }
      expect(sawEmpty, isTrue);
    });
    // 负向对照:把 maxSkewLeadSeconds 调成 1e9 且删掉 inWindow==0 分支
    // ⇒ 后四个 test 全红。
  });

  group('TimebaseNormalizer 端到端', () {
    const StreamRateConfig rates = StreamRateConfig(
      cameraHz: 30.0,
      imuHz: 200.0,
    );

    test('偏置未收敛时给 defer(留着重投),不给 accept 也不丢', () {
      final TimebaseNormalizer n = TimebaseNormalizer(
        const TimebaseNormalizerConfig(
          rates: rates,
          cameraDomain: TimeDomain.appleCaptureSynchronizationClock,
          imuDomain: TimeDomain.appleCoreMotionBoot,
        ),
      );
      final TimebaseVerdict v = n.submitImu(
        const TimestampSample(
          rawSeconds: 10.0,
          domain: TimeDomain.appleCoreMotionBoot,
          stream: StreamKind.imu,
          hostArrivalSeconds: 10.001,
        ),
      );
      expect(v.decision, TimebaseDecision.defer);
      expect(v.normalizedSeconds, isNull);
      expect(n.deferredImu, 1);
    });

    test('声称同域但实际差 3600s ⇒ fault(这就是 XRSLAM 的静默退化)', () {
      final TimebaseNormalizer n = TimebaseNormalizer(
        const TimebaseNormalizerConfig(
          rates: rates,
          cameraDomain: TimeDomain.appleHostTime,
          imuDomain: TimeDomain.appleHostTime,
        ),
      );
      double t = 0.0;
      final Set<TimebaseFaultKind> seen = <TimebaseFaultKind>{};
      for (int frame = 0; frame < 20; frame++) {
        for (int k = 0; k < 6; k++) {
          n.submitImu(
            TimestampSample(
              rawSeconds: t + k / 200.0 + 3600.0,
              domain: TimeDomain.appleHostTime, // 谎报同域
              stream: StreamKind.imu,
            ),
          );
        }
        final TimebaseVerdict v = n.submitCamera(
          TimestampSample(
            rawSeconds: t,
            domain: TimeDomain.appleHostTime,
            stream: StreamKind.camera,
          ),
        );
        seen.addAll(v.faults.map((TimebaseFault f) => f.kind));
        t += 1 / 30.0;
      }
      expect(seen, contains(TimebaseFaultKind.domainSkew));
      expect(seen, contains(TimebaseFaultKind.emptyPreintegrationWindow));
      expect(n.acceptedCamera, 0);
      expect(n.faultedCamera, greaterThan(0));
    });

    test('真实 3600s 域差 + hostArrival ⇒ 被**测量修正**,最终 accept', () {
      final math.Random rng = math.Random(99);
      final TimebaseNormalizer n = TimebaseNormalizer(
        const TimebaseNormalizerConfig(
          rates: rates,
          cameraDomain: TimeDomain.appleCaptureSynchronizationClock,
          imuDomain: TimeDomain.appleCoreMotionBoot,
        ),
      );
      const double imuEpochShift = 3600.0; // IMU 域比 host 早 3600s 起算
      double host = 0.0;
      int acceptedCam = 0;
      int faultCam = 0;
      for (int frame = 0; frame < 150; frame++) {
        for (int k = 0; k < 6; k++) {
          final double h = host + k / 200.0;
          n.submitImu(
            TimestampSample(
              rawSeconds: h + imuEpochShift,
              domain: TimeDomain.appleCoreMotionBoot,
              stream: StreamKind.imu,
              hostArrivalSeconds: h + _delay(rng),
            ),
          );
        }
        final TimebaseVerdict v = n.submitCamera(
          TimestampSample(
            rawSeconds: host,
            domain: TimeDomain.appleCaptureSynchronizationClock,
            stream: StreamKind.camera,
            hostArrivalSeconds: host + 0.010 + _delay(rng),
            exposureDurationSeconds: 1 / 60.0,
          ),
        );
        if (v.decision == TimebaseDecision.accept) acceptedCam++;
        if (v.decision == TimebaseDecision.fault) faultCam++;
        host += 1 / 30.0;
      }
      expect(faultCam, 0, reason: '测量修正后不应再有域故障');
      expect(acceptedCam, greaterThan(100));
      final ClockOffsetEstimate imuEst = n.imuOffsetEstimate!;
      expect(imuEst.offsetSeconds, closeTo(-imuEpochShift, 1e-3));
    });

    test('曝光修正被施加,且不确定度把 Apple 未文档化的那一段计进来', () {
      const double d = 1 / 60.0;
      const TimebaseNormalizerConfig cfg = TimebaseNormalizerConfig(
        rates: rates,
        cameraDomain: TimeDomain.appleHostTime,
        imuDomain: TimeDomain.appleHostTime,
      );
      final TimebaseNormalizer n = TimebaseNormalizer(cfg);
      // 先喂足 IMU 让跨流检查有料
      for (int k = 0; k < 20; k++) {
        n.submitImu(
          TimestampSample(
            rawSeconds: k / 200.0,
            domain: TimeDomain.appleHostTime,
            stream: StreamKind.imu,
          ),
        );
      }
      final TimebaseVerdict v = n.submitCamera(
        const TimestampSample(
          rawSeconds: 0.05,
          domain: TimeDomain.appleHostTime,
          stream: StreamKind.camera,
          exposureDurationSeconds: d,
        ),
      );
      expect(v.decision, TimebaseDecision.accept);
      expect(
        v.normalizedSeconds,
        closeTo(0.05 + cfg.exposureCenterFraction * d, 1e-12),
      );
      expect(
        v.uncertaintySeconds,
        closeTo(cfg.exposureUncertaintyFraction * d, 1e-12),
      );
      // minimax:施加 0.25 时最坏误差 0.25D,严格优于默认 0
      expect(cfg.exposureCenterFraction, 0.25);
      expect(cfg.exposureUncertaintyFraction, 0.25);
      // 量级挂钩:1/60s 曝光、手持 1 m/s ⇒ 4.2mm
      expect(
        timingUncertaintyToMeters(
          uncertaintySeconds: v.uncertaintySeconds!,
          handSpeedMetersPerSecond: 1.0,
        ),
        closeTo(0.00417, 5e-5),
      );
    });

    test('域为 unknown ⇒ 直接 fault,不许当成任何已知域', () {
      final TimebaseNormalizer n = TimebaseNormalizer(
        const TimebaseNormalizerConfig(rates: rates),
      );
      final TimebaseVerdict v = n.submitImu(
        const TimestampSample(
          rawSeconds: 1.0,
          domain: TimeDomain.unknown,
          stream: StreamKind.imu,
        ),
      );
      expect(v.decision, TimebaseDecision.fault);
      expect(v.faults.first.kind, TimebaseFaultKind.undeterminedDomain);
    });

    test('裁决集合里没有 drop —— 铁律的结构性保证', () {
      expect(
        TimebaseDecision.values.map((TimebaseDecision d) => d.name).toSet(),
        <String>{'accept', 'defer', 'fault'},
      );
    });
  });

  group('AndroidTimebaseBridge', () {
    test('REALTIME 机型:相机已在 BOOTTIME 域,零换算、零不确定度', () {
      final AndroidTimebaseBridge b = AndroidTimebaseBridge(
        cameraTimestampSource: AndroidCameraTimestampSource.realtime,
      );
      expect(b.cameraToBootSeconds(1234567890), closeTo(1.23456789, 1e-9));
      expect(b.cameraOffsetHardHalfWidthSeconds(), 0.0);
      expect(b.cameraTimestampSource.domain, TimeDomain.androidBootRealtime);
    });

    test('UNKNOWN 机型:未测偏置前返回 null(⇒ 调用方必须 defer,不许丢)', () {
      final AndroidTimebaseBridge b = AndroidTimebaseBridge(
        cameraTimestampSource: AndroidCameraTimestampSource.unknown,
      );
      expect(b.cameraToBootSeconds(1000000000), isNull);
      expect(b.state(), isNull);
    });

    test('UNKNOWN 机型:探针到位后把 3600s 累计休眠补上', () {
      final AndroidTimebaseBridge b = AndroidTimebaseBridge(
        cameraTimestampSource: AndroidCameraTimestampSource.unknown,
      );
      // 开机已累计休眠 3600s ⇒ elapsedRealtime = nanoTime + 3600
      const int monoNs = 5000000000; // 5.0 s
      b.ingest(
        const AndroidClockProbe(
          monotonicBeforeNanos: monoNs,
          bootRealtimeNanos: monoNs + 3600000000000,
          monotonicAfterNanos: monoNs + 3000, // 3 us 读取开销
        ),
      );
      final AndroidBridgeState st = b.state()!;
      expect(st.accumulatedSleepSeconds, closeTo(3600.0, 1e-5));
      expect(st.bootMinusMonotonic.halfWidthSeconds, closeTo(1.5e-6, 1e-9));
      expect(st.cameraComparability, DomainComparability.approximate);
      // 相机戳(monotonic 域)被搬到 BOOTTIME 域
      expect(b.cameraToBootSeconds(monoNs), closeTo(5.0 + 3600.0, 1e-4));
    });

    test('会话中途休眠 ⇒ ingest 返回 true(缓冲必须重放,不许丢)', () {
      final AndroidTimebaseBridge b = AndroidTimebaseBridge(
        cameraTimestampSource: AndroidCameraTimestampSource.unknown,
      );
      expect(
        b.ingest(
          const AndroidClockProbe(
            monotonicBeforeNanos: 1000000000,
            bootRealtimeNanos: 1000000000,
            monotonicAfterNanos: 1000002000,
          ),
        ),
        isFalse,
      );
      expect(
        b.ingest(
          const AndroidClockProbe(
            monotonicBeforeNanos: 3000000000,
            bootRealtimeNanos: 3000000000 + 120000000000, // 睡了 120 s
            monotonicAfterNanos: 3000002000,
          ),
        ),
        isTrue,
      );
      expect(b.tracker.jumpCount, 1);
      expect(b.tracker.lastJumpSeconds, closeTo(120.0, 1e-3));
    });

    test('平台给出未知枚举值 ⇒ 落到更保守的 unknown 档,而不是猜 REALTIME', () {
      expect(
        AndroidCameraTimestampSource.fromPlatform(0),
        AndroidCameraTimestampSource.unknown,
      );
      expect(
        AndroidCameraTimestampSource.fromPlatform(1),
        AndroidCameraTimestampSource.realtime,
      );
      expect(
        AndroidCameraTimestampSource.fromPlatform(7),
        AndroidCameraTimestampSource.unknown,
      );
    });
  });

  group('域性质表(把文档结论钉成可执行判据)', () {
    test('只有文档写明原点的域才 originIsDocumented', () {
      expect(TimeDomain.appleCoreMotionBoot.originIsDocumented, isTrue);
      expect(TimeDomain.androidBootRealtime.originIsDocumented, isTrue);
      expect(TimeDomain.androidMonotonicUptime.originIsDocumented, isTrue);
      // Apple 对 ARFrame.timestamp 只有一句 "The time at which the frame was
      // captured." —— 没有域、没有原点。
      expect(TimeDomain.appleArFrameUndocumented.originIsDocumented, isFalse);
      expect(
        TimeDomain.appleCaptureSynchronizationClock.originIsDocumented,
        isFalse,
      );
      expect(TimeDomain.appleHostTime.originIsDocumented, isFalse);
    });

    test('休眠语义:Android 两个域相反,iOS 一律 null(未文档化,不猜)', () {
      expect(TimeDomain.androidBootRealtime.includesDeepSleep, isTrue);
      expect(TimeDomain.androidMonotonicUptime.includesDeepSleep, isFalse);
      expect(TimeDomain.appleHostTime.includesDeepSleep, isNull);
      expect(TimeDomain.appleCoreMotionBoot.includesDeepSleep, isNull);
    });

    test('camera UNKNOWN 只到 approximate;ARFrame 未测量时是 none', () {
      expect(
        TimeDomain.androidCameraUnknownSource.crossSubsystemComparability,
        DomainComparability.approximate,
      );
      expect(
        TimeDomain.appleArFrameUndocumented.crossSubsystemComparability,
        DomainComparability.none,
      );
      expect(
        TimeDomain.pwNormalized.crossSubsystemComparability,
        DomainComparability.exact,
      );
    });
  });

  group('IosTimebaseChannel — 「CoreMotion 贴哪个 boot」判据', () {
    Map<Object?, Object?> rawSource({
      required double offsetToUptime,
      required double offsetToMonotonic,
      required double readCost,
    }) {
      final List<Object?> samples = <Object?>[];
      for (int i = 0; i < 40; i++) {
        final double uptime = 1000.0 + i * 0.01;
        final double source = uptime - offsetToUptime;
        samples.add(<Object?, Object?>{
          'seq': i + 1,
          'sourceSeconds': source,
          'uptimeRawBeforeSeconds': uptime - readCost / 2,
          'monotonicSeconds': source + offsetToMonotonic,
          'uptimeRawAfterSeconds': uptime + readCost / 2,
        });
      }
      return <Object?, Object?>{
        'sampleCount': samples.length,
        'rawSamplesDropped': 0,
        'rawSamplesAttempted': samples.length,
        'rawSamplesAccepted': samples.length,
        'rawSamplesRejected': 0,
        'rawSamplesDelivered': samples.length,
        'rawSamplesBatchCount': samples.length,
        'rejectionReasons': <Object?, Object?>{
          'invalid_input': 0,
          'lock_contention': 0,
          'stale_generation': 0,
        },
        'rawSamples': samples,
      };
    }

    Map<Object?, Object?> emptySource() => <Object?, Object?>{
      'sampleCount': 0,
      'rawSamplesDropped': 0,
      'rawSamplesAttempted': 0,
      'rawSamplesAccepted': 0,
      'rawSamplesRejected': 0,
      'rawSamplesDelivered': 0,
      'rawSamplesBatchCount': 0,
      'rejectionReasons': <Object?, Object?>{
        'invalid_input': 0,
        'lock_contention': 0,
        'stale_generation': 0,
      },
      'rawSamples': <Object?>[],
    };

    Map<Object?, Object?> snap({
      required double sleep,
      required double cmOffUptime,
      required double cmOffMono,
      double readCost = 2e-7,
    }) => <Object?, Object?>{
      'schema': 'pw.vio.timebase-raw/5',
      'sessionId': '123e4567-e89b-42d3-a456-426614174000',
      'sessionEpoch': 1,
      'sessionGeneration': 1,
      'uptimeRawBeforeSeconds': 1000.0 - readCost / 2,
      'monotonicSeconds': 1000.0 + sleep,
      'uptimeRawAfterSeconds': 1000.0 + readCost / 2,
      'sessionStartUptimeRawBeforeSeconds': 900.0 - readCost / 2,
      'sessionStartMonotonicSeconds': 900.0 + sleep,
      'sessionStartUptimeRawAfterSeconds': 900.0 + readCost / 2,
      'syncClockUnavailableCount': 0,
      'outOfSessionStaleObservations': 0,
      'synchronizationClockAvailable': true,
      'arFrameExifAvailable': true,
      'intrinsicsAccounting': <Object?, Object?>{
        'rawSamplesAttempted': 1,
        'rawSamplesAccepted': 1,
        'rawSamplesRejected': 0,
        'intrinsicsOverwritten': 0,
        'rejectionReasons': <Object?, Object?>{
          'invalid_input': 0,
          'lock_contention': 0,
          'stale_generation': 0,
        },
      },
      'sources': <Object?, Object?>{
        IosTimebaseSources.coreMotionAccelerometer: rawSource(
          offsetToUptime: cmOffUptime,
          offsetToMonotonic: cmOffMono,
          readCost: readCost,
        ),
        IosTimebaseSources.coreMotionGyroscope: rawSource(
          offsetToUptime: cmOffUptime,
          offsetToMonotonic: cmOffMono,
          readCost: readCost,
        ),
        IosTimebaseSources.capturePtsHost: rawSource(
          offsetToUptime: 0.012,
          offsetToMonotonic: 0.012 + sleep,
          readCost: readCost,
        ),
        IosTimebaseSources.arFrame: emptySource(),
        IosTimebaseSources.capturePtsRaw: emptySource(),
      },
    };

    test('累计休眠 3600s + CoreMotion 贴 UPTIME_RAW ⇒ 判为 uptimeRaw,且与相机同域', () {
      final IosTimebaseSnapshot s = IosTimebaseSnapshot.fromMap(
        snap(sleep: 3600.0, cmOffUptime: 0.001, cmOffMono: 3600.001),
      );
      expect(s.baseDiscriminable, isTrue);
      expect(
        s.baseOf(IosTimebaseSources.coreMotionAccelerometer),
        IosClockBaseVerdict.uptimeRaw,
      );
      expect(
        s.sameBase(
          IosTimebaseSources.coreMotionAccelerometer,
          IosTimebaseSources.capturePtsHost,
        ),
        isTrue,
      );
      expect(
        s.domainOf(IosTimebaseSources.coreMotionAccelerometer),
        TimeDomain.appleHostTime,
      );
    });

    test(
      'CoreMotion 实际贴 CLOCK_MONOTONIC ⇒ 判出与相机**不同域**(iPhone 版 Android bug)',
      () {
        final IosTimebaseSnapshot s = IosTimebaseSnapshot.fromMap(
          snap(sleep: 3600.0, cmOffUptime: -3600.001, cmOffMono: -0.001),
        );
        expect(
          s.baseOf(IosTimebaseSources.coreMotionAccelerometer),
          IosClockBaseVerdict.monotonic,
        );
        expect(
          s.sameBase(
            IosTimebaseSources.coreMotionAccelerometer,
            IosTimebaseSources.capturePtsHost,
          ),
          isFalse,
        );
        // 判出异域 ⇒ 域标成 unknown ⇒ 进 normalizer 直接 fault,而不是照常跑
        expect(
          s.domainOf(IosTimebaseSources.coreMotionAccelerometer),
          TimeDomain.unknown,
        );
      },
    );

    test('🔴 累计休眠 ≈ 0 ⇒ 判据退化,必须给 indeterminate 而不是猜 uptimeRaw', () {
      final IosTimebaseSnapshot s = IosTimebaseSnapshot.fromMap(
        snap(sleep: 0.0, cmOffUptime: 0.001, cmOffMono: 0.001),
      );
      expect(s.baseDiscriminable, isFalse);
      expect(
        s.baseOf(IosTimebaseSources.coreMotionAccelerometer),
        IosClockBaseVerdict.indeterminate,
      );
      expect(
        s.sameBase(
          IosTimebaseSources.coreMotionAccelerometer,
          IosTimebaseSources.capturePtsHost,
        ),
        isNull,
      );
      expect(
        s.domainOf(IosTimebaseSources.coreMotionAccelerometer),
        TimeDomain.unknown,
      );
    });

    test('缺席的源 ⇒ unavailable,不是 uptimeRaw', () {
      final IosTimebaseSnapshot s = IosTimebaseSnapshot.fromMap(
        snap(sleep: 3600.0, cmOffUptime: 0.001, cmOffMono: 3600.001),
      );
      expect(s.schemaValid, isTrue);
      expect(
        s.baseOf(IosTimebaseSources.arFrame),
        IosClockBaseVerdict.unavailable,
      );
    });

    test('raw schema 缺失或样本账不守恒时 fail closed', () {
      final Map<Object?, Object?> missingSchema = snap(
        sleep: 3600.0,
        cmOffUptime: 0.001,
        cmOffMono: 3600.001,
      )..remove('schema');
      final IosTimebaseSnapshot missing = IosTimebaseSnapshot.fromMap(
        missingSchema,
      );
      expect(missing.schemaValid, isFalse);
      expect(
        missing.baseOf(IosTimebaseSources.coreMotionAccelerometer),
        IosClockBaseVerdict.unavailable,
      );

      final Map<Object?, Object?> oldSchema = snap(
        sleep: 3600.0,
        cmOffUptime: 0.001,
        cmOffMono: 3600.001,
      )..['schema'] = 'pw.vio.timebase-raw/4';
      expect(IosTimebaseSnapshot.fromMap(oldSchema).schemaValid, isFalse);

      final Map<Object?, Object?> badLedger = snap(
        sleep: 3600.0,
        cmOffUptime: 0.001,
        cmOffMono: 3600.001,
      );
      final Map<Object?, Object?> sources =
          badLedger['sources']! as Map<Object?, Object?>;
      final Map<Object?, Object?> core =
          sources[IosTimebaseSources.coreMotionAccelerometer]!
              as Map<Object?, Object?>;
      core['sampleCount'] = 999;
      final IosTimebaseSnapshot bad = IosTimebaseSnapshot.fromMap(badLedger);
      expect(bad.schemaValid, isFalse);
      expect(
        bad.baseOf(IosTimebaseSources.coreMotionAccelerometer),
        IosClockBaseVerdict.unavailable,
      );
    });

    test(
      'bounded raw ring overwrite is visible and cannot authorize a run',
      () {
        final Map<Object?, Object?> wire = snap(
          sleep: 3600.0,
          cmOffUptime: 0.001,
          cmOffMono: 3600.001,
        );
        final Map<Object?, Object?> sources =
            wire['sources']! as Map<Object?, Object?>;
        final Map<Object?, Object?> core =
            sources[IosTimebaseSources.coreMotionAccelerometer]!
                as Map<Object?, Object?>;
        core
          ..['sampleCount'] = 41
          ..['rawSamplesDropped'] = 1
          ..['rawSamplesAttempted'] = 41
          ..['rawSamplesAccepted'] = 41;

        final IosTimebaseSnapshot parsed = IosTimebaseSnapshot.fromMap(wire);
        expect(parsed.schemaValid, isTrue);
        expect(parsed.transportLossFree, isFalse);
      },
    );

    test('intrinsics rejection is not timestamp transport loss', () {
      final Map<Object?, Object?> wire = snap(
        sleep: 3600.0,
        cmOffUptime: 0.001,
        cmOffMono: 3600.001,
      );
      final Map<Object?, Object?> accounting =
          wire['intrinsicsAccounting']! as Map<Object?, Object?>;
      accounting
        ..['rawSamplesAttempted'] = 2
        ..['rawSamplesAccepted'] = 1
        ..['rawSamplesRejected'] = 1;
      final Map<Object?, Object?> reasons =
          accounting['rejectionReasons']! as Map<Object?, Object?>;
      reasons['invalid_input'] = 1;

      final IosTimebaseSnapshot parsed = IosTimebaseSnapshot.fromMap(wire);
      expect(parsed.schemaValid, isTrue);
      expect(parsed.transportLossFree, isTrue);
    });

    test('source/reason schema 的缺失、未知、负数与分数全部 fail closed', () {
      Map<Object?, Object?> mutatedSource(
        void Function(Map<Object?, Object?> source) mutate,
      ) {
        final Map<Object?, Object?> wire = snap(
          sleep: 3600.0,
          cmOffUptime: 0.001,
          cmOffMono: 3600.001,
        );
        final Map<Object?, Object?> sources =
            wire['sources']! as Map<Object?, Object?>;
        final Map<Object?, Object?> source =
            sources[IosTimebaseSources.coreMotionAccelerometer]!
                as Map<Object?, Object?>;
        mutate(source);
        return wire;
      }

      final Map<Object?, Object?> nonMapSource = snap(
        sleep: 3600.0,
        cmOffUptime: 0.001,
        cmOffMono: 3600.001,
      );
      (nonMapSource['sources']!
              as Map<Object?, Object?>)[IosTimebaseSources.arFrame] =
          'not-a-source-ledger';
      expect(IosTimebaseSnapshot.fromMap(nonMapSource).schemaValid, isFalse);

      for (final Map<Object?, Object?> wire in <Map<Object?, Object?>>[
        mutatedSource((Map<Object?, Object?> source) {
          source['unknown'] = 0;
        }),
        mutatedSource((Map<Object?, Object?> source) {
          (source['rejectionReasons']! as Map<Object?, Object?>).remove(
            'invalid_input',
          );
        }),
        mutatedSource((Map<Object?, Object?> source) {
          (source['rejectionReasons']! as Map<Object?, Object?>)['unknown'] = 0;
        }),
        mutatedSource((Map<Object?, Object?> source) {
          (source['rejectionReasons']!
                  as Map<Object?, Object?>)['lock_contention'] =
              -1;
        }),
        mutatedSource((Map<Object?, Object?> source) {
          (source['rejectionReasons']!
                  as Map<Object?, Object?>)['stale_generation'] =
              0.5;
        }),
      ]) {
        expect(IosTimebaseSnapshot.fromMap(wire).schemaValid, isFalse);
      }
    });

    test('通道往返:snapshot 能正确解析平台返回的 map', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const MethodChannel ch = MethodChannel(kPwVioTimebaseChannel);
      final List<String> calls = <String>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, (MethodCall call) async {
            calls.add(call.method);
            if (call.method == 'snapshot') {
              return snap(sleep: 120.0, cmOffUptime: 0.002, cmOffMono: 120.002);
            }
            if (call.method == 'remeasure') {
              return <Object?, Object?>{
                'schema': 'pw.vio.timebase-remeasure-raw/1',
                'sessionId': '123e4567-e89b-42d3-a456-426614174000',
                'sessionEpoch': 1,
                'sessionGeneration': 1,
                'uptimeRawBeforeSeconds': 1000.0,
                'monotonicSeconds': 1120.0,
                'uptimeRawAfterSeconds': 1000.000001,
                'sessionStartUptimeRawBeforeSeconds': 900.0,
                'sessionStartMonotonicSeconds': 900.0,
                'sessionStartUptimeRawAfterSeconds': 900.000001,
              };
            }
            if (call.method == 'startRawCoreMotionFeed') {
              expect(call.arguments, <String, Object?>{
                'accelerometerHz': 100.0,
                'gyroscopeHz': 100.0,
              });
              return true;
            }
            return null;
          });
      final IosTimebaseChannel c = IosTimebaseChannel();
      expect(
        await c.startRawCoreMotionFeed(
          accelerometerHz: 100.0,
          gyroscopeHz: 100.0,
        ),
        isTrue,
      );
      await c.beginSession(
        sessionId: '123e4567-e89b-42d3-a456-426614174000',
        sessionEpoch: 1,
      );
      final IosTimebaseRemeasurement measurement = await c.remeasure(
        expectedSessionId: '123e4567-e89b-42d3-a456-426614174000',
        expectedSessionEpoch: 1,
        expectedSessionGeneration: 1,
      );
      expect(measurement.schemaValid, isTrue);
      expect(measurement.sessionSleepDeltaSeconds, closeTo(120.0, 1e-12));
      expect(measurement.combinedHalfWidthSeconds, closeTo(1e-6, 1e-12));
      final IosTimebaseSnapshot? s = await c.snapshot();
      expect(s, isNotNull);
      expect(s!.accumulatedSleepSeconds, 120.0);
      expect(s.synchronizationClockAvailable, isTrue);
      expect(
        s.baseOf(IosTimebaseSources.coreMotionAccelerometer),
        IosClockBaseVerdict.uptimeRaw,
      );
      expect(calls, <String>[
        'startRawCoreMotionFeed',
        'beginSession',
        'remeasure',
        'snapshot',
      ]);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, null);
    });

    test('slamStart 只接受带直接代号与快照的原生回执', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      const MethodChannel ch = MethodChannel(kPwVioTimebaseChannel);
      Map<Object?, Object?> response = <Object?, Object?>{
        'schema': 'pw.vio.shadow-start-receipt/1',
        'rc': 1,
        'generation': 7,
        'failureReason': 'none',
        'snapshot': <Object?, Object?>{
          'sessionGeneration': 7,
          'state': 'running',
        },
      };
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, (MethodCall call) async {
            expect(call.method, 'slamStart');
            return response;
          });
      final IosTimebaseChannel c = IosTimebaseChannel();
      Future<IosShadowStartReceipt> start() => c.slamStart(
        slamConfigPath: '/private/tmp/slam.yaml',
        deviceConfigPath: '/private/tmp/device.yaml',
        sessionId: '123e4567-e89b-42d3-a456-426614174000',
        sessionEpoch: 1,
        effectiveConfigSha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        inputIdentitySha256:
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        downsampleFactor: 3,
        downsampleFormula: 'box-nxn-half-up-v1',
        requestedCameraHz: 30.0,
        cameraTimeOffsetSeconds: 0.0,
        accelerationScale: -9.80665,
        requestedAccelerometerHz: 100.0,
        requestedGyroscopeHz: 100.0,
      );

      final IosShadowStartReceipt accepted = await start();
      expect(accepted.schemaValid, isTrue);
      expect(accepted.accepted, isTrue);
      expect(accepted.generation, 7);
      expect(accepted.snapshot?['state'], 'running');

      response = <Object?, Object?>{...response, 'generation': 8};
      final IosShadowStartReceipt mismatched = await start();
      expect(mismatched.schemaValid, isFalse);
      expect(mismatched.accepted, isFalse);

      response = <Object?, Object?>{'sessionGeneration': 7, 'state': 'running'};
      final IosShadowStartReceipt genericPoll = await start();
      expect(genericPoll.schemaValid, isFalse);
      expect(genericPoll.accepted, isFalse);

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(ch, null);
    });
  });
}
