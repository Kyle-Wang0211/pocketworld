// stationarity_gate_test.dart —— 判据全部**闭式可验**,不引入任何我定的数。
// 形状沿用 Basalt test_camera.cpp 那一套:网格穷举 + 阴阳对照。

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/pose/stationarity_gate.dart';
import 'package:pocketworld_flutter/vio/pose/zero_velocity_detector.dart'
    show ImuSample;

final double kEps = math.sqrt(2.220446049250313e-16);

/// OpenVINS 三份配置里出现过的阈值,原样拿来做参数化测试。
const List<(String, double, double)> kOpenVinsConfigs = <(String, double, double)>[
  ('euroc_mav', 1.5, 10.0),
  ('rpng_aruco', 1.2, 2.0),
  ('rpng_plane', 0.5, 4.0),
];

StationarityGate _gate({double aTh = 1.5, double dTh = 10.0, double? gTh}) =>
    StationarityGate(
      accelVarianceThreshold: aTh,
      disparityThresholdPixels: dTh,
      gyroVarianceThreshold: gTh,
    );

/// 灌 [seconds] 秒、[hz] Hz 的样本;[jitter] 是加到每个分量上的确定性扰动幅度。
void _feed(StationarityGate g, {double seconds = 2.5, double hz = 100,
    double accelJitter = 0, double gyroJitter = 0, double t0 = 0}) {
  final int n = (seconds * hz).round();
  for (int i = 0; i < n; i++) {
    // 用确定性的 ±1 交替,而不是随机数 —— 测试必须可复现。
    final double s = (i.isEven ? 1.0 : -1.0);
    g.add(t0 + i / hz,
        ImuSample(
          ax: s * accelJitter,
          ay: 0,
          az: 9.81 + s * accelJitter,
          gx: s * gyroJitter,
          gy: 0,
          gz: 0,
        ));
  }
}

void main() {
  group('窗长:抄 OpenVINS 的 2.0 秒', () {
    test('默认窗长恒为 2.0 —— 三份 OpenVINS 配置一致,是设计值', () {
      expect(StationarityGate.kOpenVinsWindowSeconds, 2.0);
      expect(_gate().windowSeconds, 2.0);
    });

    test('🔴 窗按**时间**裁剪,不按样本数 —— 换采样率窗时长不能漂', () {
      for (final double hz in <double>[50, 100, 200, 400]) {
        final g = _gate();
        _feed(g, seconds: 5.0, hz: hz);
        // 窗内样本数应当≈ hz×2,而不是某个固定样本数
        expect(g.count, closeTo(hz * 2, hz * 0.05),
            reason: '$hz Hz 下窗内 ${g.count} 个样本,期望≈${hz * 2}');
      }
    });
  });

  group('🔴 三态,不许静默降级', () {
    test('窗没满 ⇒ unknown,不是 moving', () {
      final g = _gate();
      _feed(g, seconds: 1.0); // 只有 1 秒,不足 2 秒
      final v = g.evaluate(averageDisparityPixels: 0.0);
      expect(v.state, Stationarity.unknown,
          reason: '窗没满被当成了 ${v.state.name}');
    });

    test('🔴 没有视差输入 ⇒ unknown,不是 stationary', () {
      final g = _gate();
      _feed(g); // IMU 完全静止
      final v = g.evaluate(averageDisparityPixels: null);
      expect(v.state, Stationarity.unknown,
          reason: '缺一个量就断言静止,正是 XR-VIO 说的"两个都要"被绕过');
      // 但中间量仍然要报出来,便于诊断
      expect(v.accelVariance, isNotNull);
      expect(v.gyroVariance, isNotNull);
    });
  });

  group('两个量各自都能单独否决(闭式)', () {
    for (final (String name, double aTh, double dTh) in kOpenVinsConfigs) {
      test('$name(imu=$aTh disp=$dTh):完全静止 + 零视差 ⇒ stationary', () {
        final g = _gate(aTh: aTh, dTh: dTh);
        _feed(g);
        final v = g.evaluate(averageDisparityPixels: 0.0);
        expect(v.state, Stationarity.stationary, reason: '$v');
        expect(v.accelVariance!, lessThan(kEps),
            reason: '恒定输入的均方偏差应当为 0,实得 ${v.accelVariance}');
      });

      test('$name:IMU 静止但**视差超阈** ⇒ moving', () {
        final g = _gate(aTh: aTh, dTh: dTh);
        _feed(g);
        final v = g.evaluate(averageDisparityPixels: dTh * 1.01);
        expect(v.state, Stationarity.moving, reason: '$v');
      });

      test('$name:视差为零但 **IMU 方差超阈** ⇒ moving', () {
        final g = _gate(aTh: aTh, dTh: dTh);
        // ±j 交替 ⇒ 每轴方差 = j²,两轴有扰动 ⇒ 总均方偏差 = 2j²
        final double j = math.sqrt(aTh / 2) * 1.05;
        _feed(g, accelJitter: j);
        final v = g.evaluate(averageDisparityPixels: 0.0);
        expect(v.accelVariance!, greaterThan(aTh), reason: '$v');
        expect(v.state, Stationarity.moving, reason: '$v');
      });
    }
  });

  group('闭式:均方偏差的解析值', () {
    test('±j 交替时,单轴均方偏差恰为 j²(网格穷举 j)', () {
      // 🔴 容差**从条件数推**,不是拍一个数。
      //
      // 加速度带着 9.81 的直流分量,而扰动只有 j。求方差要先减掉均值,
      // 这是典型的灾难性抵消:相对误差的上界约为
      //     eps × (‖均值‖ / 标准差)²
      // j=1e-4 时 (9.81/1e-4)² ≈ 9.6e9,乘 eps=2.2e-16 ⇒ 约 2e-6。
      // 我一开始拍了个 1e-12,对 j=1e-4 这一档根本不成立(实测 2.3e-12)。
      //
      // 这不是实现的缺陷 —— 这里用的已经是数值上更稳的**两遍法**(先算均值
      // 再算偏差),而不是"平方和减均值平方"那种不稳的一遍法。
      const double eps = 2.220446049250313e-16;
      const double dc = 9.81;
      for (final double j in <double>[1e-4, 1e-3, 1e-2, 0.1, 1.0, 3.0]) {
        final g = _gate(aTh: 1e9, dTh: 1e9);
        _feed(g, accelJitter: j);
        // ax 与 az 各带 ±j ⇒ 总均方偏差 = 2j²
        final double got =
            g.evaluate(averageDisparityPixels: 0).accelVariance!;
        final double want = 2 * j * j;
        final double bound =
            math.max(1e-14, eps * (dc / j) * (dc / j) * 10);
        expect((got - want).abs() / want, lessThan(bound),
            reason: 'j=$j 实得 $got 期望 $want 条件数界 $bound');
      }
    });

    test('toStdDev 是均方偏差的平方根(XR-VIO 说 std,OpenVINS 字段说 variance)', () {
      for (final double v in <double>[1e-6, 1e-3, 0.25, 1.5, 100.0]) {
        expect((StationarityGate.toStdDev(v) - math.sqrt(v)).abs(),
            lessThan(kEps));
      }
    });
  });

  group('角速度阈值:可选,默认不参与(与 OpenVINS 一致)', () {
    test('不填 gyroVarianceThreshold ⇒ 陀螺再大也不否决', () {
      final g = _gate();
      _feed(g, gyroJitter: 10.0); // 极大的角速度扰动
      final v = g.evaluate(averageDisparityPixels: 0.0);
      expect(v.gyroVariance!, greaterThan(1.0), reason: '陀螺方差应当很大');
      expect(v.state, Stationarity.stationary,
          reason: 'OpenVINS 的配置里没有陀螺阈值,默认就不该参与');
    });

    test('填了就参与 —— XR-VIO 的文字提到了角速度', () {
      final g = _gate(gTh: 1.0);
      _feed(g, gyroJitter: 10.0);
      expect(g.evaluate(averageDisparityPixels: 0.0).state,
          Stationarity.moving);
    });
  });
}
