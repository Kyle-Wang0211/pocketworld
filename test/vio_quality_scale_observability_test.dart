// 条目 11 单测:平移激励可观测性。
// 合成数据 → 已知激励量 → 确认判据给出正确结论。每组正向断言旁边都放了负向
// 对照(把算法的某一个关键部件按其**失效方式**参数化掉,断言结论会翻)。

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/quality/scale_observability.dart';
import 'package:pocketworld_flutter/vio/quality/scale_observability_ledger.dart';

/// 固定种子高斯,保证可复现。
class _Gauss {
  _Gauss(int seed) : _r = math.Random(seed);
  final math.Random _r;
  double? _spare;
  double next() {
    if (_spare != null) {
      final s = _spare!;
      _spare = null;
      return s;
    }
    double u, v, s;
    do {
      u = _r.nextDouble() * 2 - 1;
      v = _r.nextDouble() * 2 - 1;
      s = u * u + v * v;
    } while (s >= 1 || s == 0);
    final f = math.sqrt(-2 * math.log(s) / s);
    _spare = v * f;
    return u * f;
  }
}

const double kSigmaA = 0.02; // m/s²,逐轴白噪声(测试用的"已实测"值)
const double kImuHz = 300.0;
const double kPoseHz = 30.0;

/// 喂一段运动。[accelZ] 给出 t 时刻的世界系线加速度 z 分量(不含噪声)。
/// 相机沿 +x 以 [speed] 匀速走,物距固定 [depth]。
ScaleObservabilitySample _run({
  required ScaleObservabilityConfig config,
  required double Function(double t) accelZ,
  double speed = 0.40,
  double depth = 2.0,
  double durationSec = 2.0,
  double rotDegPerPose = 0.0,
  bool cameraMoves = true,
  int seed = 7,
}) {
  final est = ScaleObservabilityEstimator(config);
  final g = _Gauss(seed);
  final nImu = (durationSec * kImuHz).round();
  final nPose = (durationSec * kPoseHz).round();
  // 两条流按时间交错喂入,和真机一样。
  var iImu = 0, iPose = 0;
  while (iImu < nImu || iPose < nPose) {
    final tImu = iImu / kImuHz;
    final tPose = iPose / kPoseHz;
    if (iImu < nImu && (iPose >= nPose || tImu <= tPose)) {
      est.addLinearAccel(
        tImu,
        g.next() * kSigmaA,
        g.next() * kSigmaA,
        accelZ(tImu) + g.next() * kSigmaA,
      );
      iImu++;
    } else {
      est.addPose(
        tPose,
        cameraMoves ? speed * tPose : 0.0,
        0.0,
        0.0,
        medianLandmarkDepth: depth,
        rotationDeltaDeg: rotDegPerPose,
      );
      iPose++;
    }
  }
  return est.evaluate();
}

void main() {
  const cfg = ScaleObservabilityConfig(accelNoiseSigmaMps2: kSigmaA);

  group('几何 ↔ 惯性 两条判据是独立的', () {
    test('b/d ↔ 三角化角换算,以及 0.30 与覆盖云 5° 的距离', () {
      // b/d = 2 tan(θ/2)
      expect(kMinBaselineOverDepthAsTriangulationDeg, closeTo(17.06, 0.05));
      expect(baselineOverDepthFromTriangulationDeg(5.0), closeTo(0.0873, 1e-4));
      // 往返自洽
      final rt = baselineOverDepthFromTriangulationDeg(
        triangulationDegFromBaselineOverDepth(0.42),
      );
      expect(rt, closeTo(0.42, 1e-12));
      // 文件头那条硬结论:覆盖云判绿离"可报尺寸"还差 3.4 倍基线。
      expect(
        kMinBaselineOverDepth / baselineOverDepthFromTriangulationDeg(5.0),
        closeTo(3.44, 0.05),
      );
    });

    test('requiredAcRmsMps2 与文件头的对表例子一致', () {
      // σ_a=0.02, target=0.01, N=200 ⇒ 0.02/(0.01·√200) = 0.14142
      expect(
        requiredAcRmsMps2(
          accelNoiseSigmaMps2: 0.02,
          targetRelativeScaleSigma: 0.01,
          samples: 200,
        ),
        closeTo(0.14142, 1e-4),
      );
    });

    test('estimateAccelNoiseSigmaMps2 能从静止段还原已知 σ_a', () {
      final g = _Gauss(11);
      const trueSigma = 0.05;
      final buf = <double>[];
      for (var i = 0; i < 3000; i++) {
        buf.add(g.next() * trueSigma);
      }
      expect(estimateAccelNoiseSigmaMps2(buf), closeTo(trueSigma, 0.003));
    });
  });

  group('NAVER 点名的失效模式:匀速平移', () {
    test('自动步道场景:视差达标,但加速度只有噪声 ⇒ constantVelocity', () {
      // 0.40 m/s,窗口内末位姿 t=1.967 s ⇒ 基线 0.787 m,物距 2 m ⇒ b/d≈0.393。
      // 刻意留出余量:窗口末端的位姿落在 1.967 s 而不是 2.000 s,贴着 0.30 写
      // 会得到 0.295 而误判 —— 本测试第一版就是这么挂的。
      final s = _run(config: cfg, accelZ: (t) => 0.0);
      expect(s.baselineOverDepth, greaterThan(kMinBaselineOverDepth));
      expect(s.baselineOverDepth, closeTo(0.393, 0.01));
      expect(s.parallaxOk, isTrue, reason: '几何看起来完全健康 —— 这正是它危险的原因');
      expect(s.excitationOk, isFalse);
      expect(s.verdict, ScaleObservabilityVerdict.constantVelocity);
      expect(s.relativeScaleSigma, greaterThan(0.01));
    });

    test('负向对照:σ_a 谎报成 ~0 ⇒ 同一段纯噪声被误判达标', () {
      // 这条钉的是「σ_a 必填、必须实测」这个设计决定:σ_a 同时出现在 (★) 的
      // 分子和扣除项里,谎报会让整条判据失效。它**不**证明扣除项单独挡住了
      // 匀速段 —— 那个更强的说法已被实测推翻,见源文件头 2026-08-23 更正。
      const broken = ScaleObservabilityConfig(accelNoiseSigmaMps2: 1e-6);
      final s = _run(config: broken, accelZ: (t) => 0.0);
      expect(s.excitationOk, isTrue);
      expect(s.verdict, ScaleObservabilityVerdict.sufficient);
    });

    test('噪声扣除让 acRms 无偏', () {
      // 3(K−1)σ_a² 扣除项的**真实职责**:让 acRms / σ_s/s 成为无偏估计,
      // 而不是"挡住匀速段"(挡住匀速段的是 Fisher 判据本身,见源文件头的
      // 2026-08-23 更正)。纯噪声段扣除后 acRms≈0.0030;不扣是 0.0113。
      final s = _run(config: cfg, accelZ: (t) => 0.0);
      expect(
        s.acRmsMps2,
        lessThan(0.3 * kSigmaA),
        reason: '纯噪声段的交流 RMS 必须被扣到接近 0,实测 ${s.acRmsMps2}',
      );
    });

    test('acRms 能还原已知的交流幅度', () {
      // 正弦幅度 A ⇒ 单轴 RMS = A/√2。A=0.6 ⇒ 0.4243。
      final s = _run(
        config: cfg,
        accelZ: (t) => 0.6 * math.sin(2 * math.pi * 2.0 * t),
      );
      expect(s.acRmsMps2, closeTo(0.6 / math.sqrt2, 0.02));
    });

    test('手持走动(2 Hz 步态起伏 1.0 m/s²)⇒ sufficient', () {
      final s = _run(
        config: cfg,
        accelZ: (t) => 1.0 * math.sin(2 * math.pi * 2.0 * t),
      );
      expect(s.parallaxOk, isTrue);
      expect(s.excitationOk, isTrue);
      expect(s.verdict, ScaleObservabilityVerdict.sufficient);
      expect(s.relativeScaleSigma, lessThan(0.01));
    });

    test('原地转 ⇒ pureRotation(而不是笼统的 parallaxStarved)', () {
      final s = _run(
        config: cfg,
        accelZ: (t) => 0.0,
        cameraMoves: false,
        rotDegPerPose: 1.0, // 60 帧 × 1° = 60°
      );
      expect(s.baselineMeters, 0.0);
      expect(s.rotationSpanDeg, greaterThan(30.0));
      expect(s.verdict, ScaleObservabilityVerdict.pureRotation);
    });

    test('走了但走得不够(b/d≈0.10)⇒ parallaxStarved', () {
      final s = _run(
        config: cfg,
        accelZ: (t) => 1.0 * math.sin(2 * math.pi * 2.0 * t),
        speed: 0.10,
      );
      expect(s.baselineOverDepth, lessThan(kMinBaselineOverDepth));
      expect(s.verdict, ScaleObservabilityVerdict.parallaxStarved);
    });
  });

  group('视觉带限(2026-08-23 修正)', () {
    test('band-limit is a no-op for in-band excitation', () {
      // 2 Hz 远低于视觉 Nyquist(30 Hz 位姿 ⇒ 15 Hz),带限应当基本不改变结论。
      double sig(double t) => 0.5 * math.sin(2 * math.pi * 2.0 * t);
      final banded = _run(config: cfg, accelZ: sig);
      const noBand = ScaleObservabilityConfig(
        accelNoiseSigmaMps2: kSigmaA,
        bandLimitToPoseRate: false,
      );
      final raw = _run(config: noBand, accelZ: sig);

      expect(banded.bandLimitBinSeconds, closeTo(1 / kPoseHz, 1e-9));
      expect(banded.excitationBins, lessThan(banded.imuSamples));
      expect(raw.excitationBins, raw.imuSamples);
      // (★) 的分子分母同比抵消 ⇒ σ_s/s 基本不动。
      expect(
        banded.relativeScaleSigma,
        closeTo(raw.relativeScaleSigma, raw.relativeScaleSigma * 0.10),
      );
      expect(banded.excitationOk, isTrue);
      expect(raw.excitationOk, isTrue);
    });

    test('band-limit rejects out-of-band vibration(带负向对照)', () {
      // 120 Hz 振动:IMU(300 Hz)看得见,视觉(30 Hz)完全看不见。
      // 幅度 3.0 m/s² —— 比"走路"还猛,但一点尺度信息都不提供。
      double vib(double t) => 3.0 * math.sin(2 * math.pi * 120.0 * t);

      final banded = _run(config: cfg, accelZ: vib);
      expect(
        banded.verdict,
        ScaleObservabilityVerdict.constantVelocity,
        reason: '带限之后正确识别为"视差够但没有可用激励"',
      );
      expect(banded.excitationOk, isFalse);

      // 🔴 负向对照:关掉带限 —— 上一版实现就是这个行为 —— 被骗过。
      const noBand = ScaleObservabilityConfig(
        accelNoiseSigmaMps2: kSigmaA,
        bandLimitToPoseRate: false,
      );
      final raw = _run(config: noBand, accelZ: vib);
      expect(
        raw.excitationOk,
        isTrue,
        reason: '证明带限就是把带外振动挡下来的那一件东西',
      );
      expect(raw.verdict, ScaleObservabilityVerdict.sufficient);
    });
  });

  group('基线口径', () {
    test('直径取弦长而不是路径长:绕一圈 R=1 应给 2.0 而不是 2π', () {
      final est = ScaleObservabilityEstimator(cfg);
      const n = 60;
      for (var i = 0; i < n; i++) {
        final t = i / kPoseHz;
        final a = 2 * math.pi * i / n;
        est.addPose(
          t,
          math.cos(a),
          math.sin(a),
          0.0,
          medianLandmarkDepth: 5.0,
        );
      }
      for (var i = 0; i < 600; i++) {
        est.addLinearAccel(i / kImuHz, 0, 0, 0);
      }
      final s = est.evaluate();
      expect(s.baselineMeters, closeTo(2.0, 0.01));
      expect(s.baselineMeters, lessThan(3.0)); // 2π = 6.28 会挂在这
    });

    test('引导信号:neededExtraBaselineMeters 指出还差多少', () {
      final s = _run(config: cfg, accelZ: (t) => 0.0, speed: 0.10, depth: 2.0);
      // b/d ≈ 0.098 ⇒ 基线 ≈ 0.197 m,需要 0.6 m ⇒ 还差 ≈ 0.4 m
      expect(s.neededExtraBaselineMeters, closeTo(0.4, 0.05));
      expect(s.parallaxProgress01, closeTo(0.33, 0.06));
    });
  });

  group('会话台账与交付层闸门', () {
    ScaleObservabilitySample fake(double t, ScaleObservabilityVerdict v) =>
        ScaleObservabilitySample(
          tSec: t,
          verdict: v,
          parallaxOk: v != ScaleObservabilityVerdict.parallaxStarved,
          excitationOk: v == ScaleObservabilityVerdict.sufficient,
          baselineMeters: 0.6,
          medianDepthMeters: 2.0,
          baselineOverDepth: 0.3,
          relativeScaleSigma: v == ScaleObservabilityVerdict.sufficient
              ? 0.005
              : double.infinity,
          acRmsMps2: 0.0,
          imuSamples: 200,
          windowSeconds: 2.0,
          rotationSpanDeg: 0.0,
          excitationBins: 60,
          bandLimitBinSeconds: 1 / 30,
        );

    test('整段自动步道 ⇒ 不许报绝对尺寸', () {
      final led = ScaleObservabilityLedger();
      for (var i = 0; i <= 300; i++) {
        led.add(fake(i / 30.0, ScaleObservabilityVerdict.constantVelocity));
      }
      final r = led.report();
      expect(r.mayReportAbsoluteDimensions, isFalse);
      expect(r.constantVelocitySeconds, closeTo(10.0, 0.05));
      expect(r.hasHiddenConstantVelocityRisk, isTrue);
    });

    test('中间有 2 s 连续可观测 ⇒ 放行', () {
      final led = ScaleObservabilityLedger();
      for (var i = 0; i <= 300; i++) {
        final t = i / 30.0;
        led.add(
          fake(
            t,
            (t >= 4.0 && t < 6.0)
                ? ScaleObservabilityVerdict.sufficient
                : ScaleObservabilityVerdict.constantVelocity,
          ),
        );
      }
      final r = led.report();
      expect(r.longestSufficientRunSeconds, closeTo(2.0, 0.05));
      expect(r.sufficientRatio, greaterThan(0.15));
      expect(r.mayReportAbsoluteDimensions, isTrue);
    });

    test('负向对照:只有 0.5 s 连续可观测 ⇒ 仍然不许报', () {
      final led = ScaleObservabilityLedger();
      for (var i = 0; i <= 300; i++) {
        final t = i / 30.0;
        led.add(
          fake(
            t,
            (t >= 4.0 && t < 4.5)
                ? ScaleObservabilityVerdict.sufficient
                : ScaleObservabilityVerdict.constantVelocity,
          ),
        );
      }
      final r = led.report();
      expect(r.longestSufficientRunSeconds, closeTo(0.5, 0.05));
      expect(r.mayReportAbsoluteDimensions, isFalse);
    });

    test('台账只打标不丢帧', () {
      final led = ScaleObservabilityLedger();
      const n = 401;
      for (var i = 0; i < n; i++) {
        led.add(
          fake(
            i / 30.0,
            i.isEven
                ? ScaleObservabilityVerdict.sufficient
                : ScaleObservabilityVerdict.constantVelocity,
          ),
        );
      }
      final r = led.report();
      expect(led.observedSamples, n, reason: '喂进去多少条就记多少条,一条不少');
      // 区间是注释:总时长必须精确等于会话跨度,不许有"被删掉的洞"。
      final covered = r.intervals.fold<double>(0, (a, iv) => a + iv.durationSec);
      expect(covered, closeTo((n - 1) / 30.0, 1e-9));
      expect(r.totalSeconds, closeTo((n - 1) / 30.0, 1e-9));
    });
  });
}
