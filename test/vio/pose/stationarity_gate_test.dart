// stationarity_gate_test.dart
//
// 判据全部闭式可验。🔴 其中有三项是**回归测试**,钉住我第一版
// (commit c4f63c0)写错、读 OpenVINS 源码后才改正的三处:
//   ① 比的是标准差不是方差(开方)
//   ② 除 N−1 不是 N
//   ③ 窗劈两半、两半都要过 —— 整窗一个均值会被稀释

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/pose/stationarity_gate.dart';
import 'package:pocketworld_flutter/vio/pose/zero_velocity_detector.dart' show ImuSample;

/// 造一条只在 x 轴上偏离 [dc] 的样本。
ImuSample _s(double x, {double dc = 0, double gyro = 0}) =>
    ImuSample(ax: dc + x, ay: 0, az: 0, gx: gyro, gy: 0, gz: 0);

/// 喂 [seconds] 秒、[hz] 赫兹的样本,第 i 条的 x 偏移由 [ax] 给出。
void _feed(
  StationarityGate g, {
  required double fromT,
  required double seconds,
  required double hz,
  required double Function(int i) ax,
  double dc = 0,
  double Function(int i)? gyro,
}) {
  final int n = (seconds * hz).round();
  for (int i = 0; i < n; i++) {
    g.add(fromT + (i + 1) / hz, _s(ax(i), dc: dc, gyro: gyro?.call(i) ?? 0));
  }
}

void main() {
  group('sampleStdDev —— 闭式', () {
    test('不足两条 ⇒ null', () {
      expect(StationarityGate.sampleStdDev(<List<double>>[]), isNull);
      expect(
        StationarityGate.sampleStdDev(<List<double>>[
          <double>[1, 2, 3]
        ]),
        isNull,
      );
    });

    test('常数序列 ⇒ 恰好 0(无论直流多大)', () {
      final List<List<double>> v = List<List<double>>.generate(
          200, (_) => <double>[9.80665, -0.3, 0.7]);
      // 不是"恰好 0":Σ/N 再减回去有舍入,残差在 eps·‖均值‖ 量级。
      expect(StationarityGate.sampleStdDev(v), closeTo(0.0, 1e-14));
    });

    test('🔴 ② Bessel:N=2 时 σ = |a−b|/√2,不是 |a−b|/2', () {
      // 除 N−1: Σ‖·‖²=(a−b)²/2, /(2−1) ⇒ sqrt = |a−b|/√2
      // 除 N   : 同分子 /2      ⇒ sqrt = |a−b|/2   ← 第一版会给这个
      const double a = 1.0, b = 4.0;
      final double? got = StationarityGate.sampleStdDev(<List<double>>[
        <double>[a, 0, 0],
        <double>[b, 0, 0],
      ]);
      expect(got, closeTo((b - a) / math.sqrt2, 1e-15));
      expect(got, isNot(closeTo((b - a) / 2, 1e-9)));
    });

    test('🔴 ① 开方:±j 交替 ⇒ σ = j·√(N/(N−1)),量纲是 m/s² 不是 (m/s²)²',
        () {
      const int n = 100;
      const double j = 3e-3;
      final List<List<double>> v = List<List<double>>.generate(
          n, (int i) => <double>[i.isEven ? j : -j, 0, 0]);
      final double expected = j * math.sqrt(n / (n - 1));
      expect(StationarityGate.sampleStdDev(v), closeTo(expected, 1e-15));
      // 未开方的量会是 j² 量级 —— 差了 j 倍,拿去比 1.5 就是量纲错。
      expect(StationarityGate.sampleStdDev(v)! / (j * j), greaterThan(100));
    });

    test('偏差是对均值向量取的、三轴点积求和 —— 三轴等幅 ⇒ σ = j·√3·√(N/(N−1))',
        () {
      const int n = 50;
      const double j = 1e-2;
      final List<List<double>> v = List<List<double>>.generate(n, (int i) {
        final double d = i.isEven ? j : -j;
        return <double>[d, d, d];
      });
      expect(
        StationarityGate.sampleStdDev(v),
        closeTo(j * math.sqrt(3) * math.sqrt(n / (n - 1)), 1e-14),
      );
    });

    test('🔴 直流不影响结果,但容差要按条件数给(灾难性抵消)', () {
      const int n = 100;
      const double j = 1e-4;
      const double dc = 9.80665;
      final List<List<double>> v = List<List<double>>.generate(
          n, (int i) => <double>[dc + (i.isEven ? j : -j), 0, 0]);
      final double expected = j * math.sqrt(n / (n - 1));
      // 相对误差上界 ≈ eps·(dc/j)²,不是拍一个 1e-12。
      const double eps = 2.220446049250313e-16;
      final double bound =
          math.max(1e-14, eps * (dc / j) * (dc / j) * 10) * expected;
      expect(StationarityGate.sampleStdDev(v), closeTo(expected, bound));
    });
  });

  group('DisparitySpan —— 闭式', () {
    test('空 ⇒ null / 0', () {
      final DisparitySpan d = DisparitySpan.fromMatchedPairs(<List<double>>[]);
      expect(d.meanPixels, isNull);
      expect(d.featureCount, 0);
    });

    test('3-4-5 直角三角形 ⇒ 平均位移恰好 5.0 像素', () {
      final DisparitySpan d =
          DisparitySpan.fromMatchedPairs(List<List<double>>.generate(
        20,
        (int i) => <double>[i.toDouble(), 0, i + 3.0, 4.0],
      ));
      expect(d.meanPixels, closeTo(5.0, 1e-15));
      expect(d.featureCount, 20);
    });

    test('原始像素、不归一化 —— 平移整批坐标不改位移', () {
      final DisparitySpan a = DisparitySpan.fromMatchedPairs(<List<double>>[
        <double>[0, 0, 3, 4],
      ]);
      final DisparitySpan b = DisparitySpan.fromMatchedPairs(<List<double>>[
        <double>[1000, 2000, 1003, 2004],
      ]);
      expect(a.meanPixels, b.meanPixels);
    });
  });

  group('门 —— 数据不足一律 unknown,不得当成 moving', () {
    StationarityGate gate() => StationarityGate(
          imuExcitationThreshold: 1.5,
          disparityThresholdPixels: 10.0,
        );

    test('窗未满', () {
      final StationarityGate g = gate();
      _feed(g, fromT: 0, seconds: 1.0, hz: 100, ax: (_) => 0, dc: 9.80665);
      final StationarityVerdict v = g.evaluate(
        disparityOlderPixels: 0.1,
        disparityNewerPixels: 0.1,
        featureCountOlder: 100,
        featureCountNewer: 100,
      );
      expect(v.state, Stationarity.unknown);
      expect(v.rejectedBy, contains('窗未满'));
    });

    test('无视差输入', () {
      final StationarityGate g = gate();
      _feed(g, fromT: 0, seconds: 2.2, hz: 100, ax: (_) => 0, dc: 9.80665);
      final StationarityVerdict v = g.evaluate(
        disparityOlderPixels: null,
        disparityNewerPixels: 0.1,
        featureCountOlder: 100,
        featureCountNewer: 100,
      );
      expect(v.state, Stationarity.unknown);
      expect(v.rejectedBy, contains('无视差'));
    });

    test('🔴 特征 < 15 ⇒ unknown(OpenVINS feat_thresh = 15)', () {
      final StationarityGate g = gate();
      _feed(g, fromT: 0, seconds: 2.2, hz: 100, ax: (_) => 0, dc: 9.80665);
      final StationarityVerdict v = g.evaluate(
        disparityOlderPixels: 0.1,
        disparityNewerPixels: 0.1,
        featureCountOlder: 14,
        featureCountNewer: 100,
      );
      expect(v.state, Stationarity.unknown);
      expect(v.rejectedBy, contains('特征不足'));
      expect(StationarityGate.kMinFeaturesPerHalfSpan, 15);
    });

    test('恰好 15 个特征 ⇒ 放行(边界是 <,不是 <=)', () {
      final StationarityGate g = gate();
      _feed(g, fromT: 0, seconds: 2.2, hz: 100, ax: (_) => 0, dc: 9.80665);
      final StationarityVerdict v = g.evaluate(
        disparityOlderPixels: 0.1,
        disparityNewerPixels: 0.1,
        featureCountOlder: 15,
        featureCountNewer: 15,
      );
      expect(v.state, Stationarity.stationary);
    });
  });

  group('门 —— 窗长与半窗', () {
    test('窗长默认 2.0,抄自 init_window_time(三份配置一致)', () {
      expect(StationarityGate.kOpenVinsWindowSeconds, 2.0);
      expect(
        StationarityGate(
          imuExcitationThreshold: 1.5,
          disparityThresholdPixels: 10.0,
        ).windowSeconds,
        2.0,
      );
    });

    test('两半各拿到一半样本', () {
      final StationarityGate g = StationarityGate(
        imuExcitationThreshold: 1.5,
        disparityThresholdPixels: 10.0,
      );
      _feed(g, fromT: 0, seconds: 2.2, hz: 100, ax: (_) => 0, dc: 9.80665);
      final StationarityVerdict v = g.evaluate(
        disparityOlderPixels: 0,
        disparityNewerPixels: 0,
        featureCountOlder: 100,
        featureCountNewer: 100,
      );
      expect(v.olderHalf.sampleCount, 100);
      expect(v.newerHalf.sampleCount, 100);
    });

    test('半窗样本 < 2 ⇒ unknown', () {
      // 2 秒窗只喂 3 条:老半窗会拿不到 2 条。
      final StationarityGate g = StationarityGate(
        imuExcitationThreshold: 1.5,
        disparityThresholdPixels: 10.0,
      );
      g.add(0.0, _s(0, dc: 9.80665));
      g.add(1.6, _s(0, dc: 9.80665));
      g.add(2.0, _s(0, dc: 9.80665));
      final StationarityVerdict v = g.evaluate(
        disparityOlderPixels: 0.1,
        disparityNewerPixels: 0.1,
        featureCountOlder: 100,
        featureCountNewer: 100,
      );
      expect(v.state, Stationarity.unknown);
      expect(v.rejectedBy, contains('半窗样本不足'));
    });

    test('🔴 ③ 回归:末尾急动被整窗均值稀释 —— 劈两半才咬得住', () {
      // 老的 1 秒纹丝不动;新的 1 秒里只有最后 0.2 秒剧烈抖动。
      // 整窗算一个 σ 会被前 1.8 秒拉低;劈两半后"新"那半必须超阈值。
      final StationarityGate g = StationarityGate(
        imuExcitationThreshold: 1.5,
        disparityThresholdPixels: 10.0,
      );
      const double hz = 100;
      const double dc = 9.80665;
      for (int i = 0; i < 220; i++) {
        final double t = (i + 1) / hz;
        // 新半窗是 (2.20−1.00, 2.20] = (1.20, 2.20];抖动只落在最后 0.2 秒。
        final bool lastFifth = t > 2.0;
        g.add(t, _s(lastFifth ? (i.isEven ? 6.0 : -6.0) : 0.0, dc: dc));
      }
      final StationarityVerdict v = g.evaluate(
        disparityOlderPixels: 0.1,
        disparityNewerPixels: 0.1,
        featureCountOlder: 100,
        featureCountNewer: 100,
      );

      // 老的那半:完全静止。
      expect(v.olderHalf.accelStdDev, closeTo(0.0, 1e-9));
      // 新的那半:20 条 ±6 混 80 条 0 ⇒ σ = 6·√(20/99) ≈ 2.70 > 1.5
      expect(v.newerHalf.accelStdDev!,
          closeTo(6.0 * math.sqrt(20 / 99), 1e-9));
      expect(v.newerHalf.accelStdDev!, greaterThan(1.5));
      expect(v.state, Stationarity.moving);
      expect(v.rejectedBy, contains('加速度σ(新)'));

      // 反证:整窗一个 σ 也会超 —— 所以本例还不足以证明"劈两半更严"。
      // 真正的证据在下一条。
    });

    test('🔴 ③ 回归(严格):整窗 σ 过关、但劈两半后新半窗不过关', () {
      // 构造:老半窗 100 条全 0;新半窗 100 条 ±1.9。
      // 新半窗 σ = 1.9·√(100/99) ≈ 1.9096 > 1.5  ⇒ 劈两半判 moving
      // 整窗    σ = √(100·1.9²/199) ≈ 1.3463 < 1.5 ⇒ 不劈会判 stationary ✗
      final StationarityGate g = StationarityGate(
        imuExcitationThreshold: 1.5,
        disparityThresholdPixels: 10.0,
      );
      const double hz = 100;
      const double dc = 9.80665;
      for (int i = 0; i < 220; i++) {
        final double t = (i + 1) / hz;
        // 新半窗 = (1.20, 2.20],整半都在抖。
        g.add(t, _s(t > 1.2 ? (i.isEven ? 1.9 : -1.9) : 0.0, dc: dc));
      }
      final StationarityVerdict v = g.evaluate(
        disparityOlderPixels: 0.1,
        disparityNewerPixels: 0.1,
        featureCountOlder: 100,
        featureCountNewer: 100,
      );

      expect(v.newerHalf.accelStdDev!, closeTo(1.9 * math.sqrt(100 / 99), 1e-9));
      expect(v.newerHalf.accelStdDev!, greaterThan(1.5));
      expect(v.state, Stationarity.moving);

      // 整窗口径确实会放过它 —— 这就是第一版的漏洞。
      final List<List<double>> whole = List<List<double>>.generate(
        200,
        (int i) => <double>[
          dc + ((i + 1) / hz > 1.0 ? (i.isEven ? 1.9 : -1.9) : 0.0),
          0,
          0
        ],
      );
      expect(StationarityGate.sampleStdDev(whole)!, lessThan(1.5));
    });
  });

  group('门 —— 判定与否决归因', () {
    StationarityGate still() {
      final StationarityGate g = StationarityGate(
        imuExcitationThreshold: 1.5,
        disparityThresholdPixels: 10.0,
      );
      // 7e-3 m/s² 量级的噪声地板,远低于 1.5。
      _feed(
        g,
        fromT: 0,
        seconds: 2.2,
        hz: 100,
        dc: 9.80665,
        ax: (int i) => i.isEven ? 7e-3 : -7e-3,
        gyro: (int i) => i.isEven ? 7.7e-4 : -7.7e-4,
      );
      return g;
    }

    test('四个量全过 ⇒ stationary', () {
      final StationarityVerdict v = still().evaluate(
        disparityOlderPixels: 0.4,
        disparityNewerPixels: 0.5,
        featureCountOlder: 120,
        featureCountNewer: 118,
      );
      expect(v.state, Stationarity.stationary);
      expect(v.rejectedBy, isNull);
    });

    test('只有老那半视差超 ⇒ moving,且归因指向"老"', () {
      final StationarityVerdict v = still().evaluate(
        disparityOlderPixels: 11.0,
        disparityNewerPixels: 0.5,
        featureCountOlder: 120,
        featureCountNewer: 118,
      );
      expect(v.state, Stationarity.moving);
      expect(v.rejectedBy, contains('视差(老)'));
    });

    test('只有新那半视差超 ⇒ moving,且归因指向"新"', () {
      final StationarityVerdict v = still().evaluate(
        disparityOlderPixels: 0.4,
        disparityNewerPixels: 11.0,
        featureCountOlder: 120,
        featureCountNewer: 118,
      );
      expect(v.state, Stationarity.moving);
      expect(v.rejectedBy, contains('视差(新)'));
    });

    test('阈值边界是 > 否决 ⇒ 恰好等于阈值算过', () {
      final StationarityVerdict v = still().evaluate(
        disparityOlderPixels: 10.0,
        disparityNewerPixels: 10.0,
        featureCountOlder: 120,
        featureCountNewer: 118,
      );
      expect(v.state, Stationarity.stationary);
    });
  });

  group('门 —— 角速度:两个出处不一致,默认照 OpenVINS(不参与)', () {
    StationarityGate withGyro(double? thresh) {
      final StationarityGate g = StationarityGate(
        imuExcitationThreshold: 1.5,
        disparityThresholdPixels: 10.0,
        gyroStdDevThreshold: thresh,
      );
      // 加速度安静,但角速度很大。
      _feed(
        g,
        fromT: 0,
        seconds: 2.2,
        hz: 100,
        dc: 9.80665,
        ax: (_) => 0,
        gyro: (int i) => i.isEven ? 2.0 : -2.0,
      );
      return g;
    }

    test('不给阈值 ⇒ 角速度再大也不否决(与 OpenVINS 源码一致)', () {
      final StationarityVerdict v = withGyro(null).evaluate(
        disparityOlderPixels: 0.1,
        disparityNewerPixels: 0.1,
        featureCountOlder: 100,
        featureCountNewer: 100,
      );
      expect(v.state, Stationarity.stationary);
      // 但它必须被**算出来并报出去**,不能悄悄不算。
      expect(v.olderHalf.gyroStdDev!, greaterThan(1.9));
    });

    test('给了阈值 ⇒ 参与否决,归因指明是角速度', () {
      final StationarityVerdict v = withGyro(0.05).evaluate(
        disparityOlderPixels: 0.1,
        disparityNewerPixels: 0.1,
        featureCountOlder: 100,
        featureCountNewer: 100,
      );
      expect(v.state, Stationarity.moving);
      expect(v.rejectedBy, contains('角速度σ'));
    });
  });

  group('门 —— 阈值必填,不得有普适默认值', () {
    test('三份 OpenVINS 配置的量级作为参考,互不相同', () {
      // 这一条是文档性的:它钉住"不存在普适常数"这个事实,
      // 防止日后有人给 imuExcitationThreshold 补一个默认值。
      const List<double> imu = <double>[1.5, 1.2, 0.5];
      const List<double> disp = <double>[10.0, 2.0, 4.0];
      expect(imu.toSet().length, 3);
      expect(disp.toSet().length, 3);
    });

    test('非正阈值被 assert 拦下', () {
      expect(
        () => StationarityGate(
            imuExcitationThreshold: 0, disparityThresholdPixels: 10),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => StationarityGate(
            imuExcitationThreshold: 1.5, disparityThresholdPixels: -1),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('门 —— 时间窗维护', () {
    test('按时间裁剪,换采样率窗时长不漂', () {
      for (final double hz in <double>[50, 100, 200]) {
        final StationarityGate g = StationarityGate(
          imuExcitationThreshold: 1.5,
          disparityThresholdPixels: 10.0,
        );
        _feed(g, fromT: 0, seconds: 10.0, hz: hz, ax: (_) => 0, dc: 9.80665);
        expect(g.windowFull, isTrue, reason: 'hz=$hz');
        final StationarityVerdict v = g.evaluate(
          disparityOlderPixels: 0,
          disparityNewerPixels: 0,
          featureCountOlder: 100,
          featureCountNewer: 100,
        );
        // 本意是"窗的**时长**不随采样率漂":两半各覆盖 1 秒 ⇒ 各 hz 条。
        expect(v.olderHalf.sampleCount, hz.round(), reason: 'hz=$hz 老半窗');
        expect(v.newerHalf.sampleCount, hz.round(), reason: 'hz=$hz 新半窗');
        // 缓冲区多留 0.10 秒的余量,所以总数比 2·hz 多一截。
        expect(g.count, greaterThan((2 * hz).round()), reason: 'hz=$hz');
      }
    });

    test('reset 清空', () {
      final StationarityGate g = StationarityGate(
        imuExcitationThreshold: 1.5,
        disparityThresholdPixels: 10.0,
      );
      _feed(g, fromT: 0, seconds: 2.2, hz: 100, ax: (_) => 0, dc: 9.80665);
      expect(g.windowFull, isTrue);
      g.reset();
      expect(g.count, 0);
      expect(g.windowFull, isFalse);
    });
  });
}
