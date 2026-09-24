// zero_velocity_detector_test.dart
//
// 判据一律**闭式可验**:GLRT 的统计量对这些构造出来的输入有解析解,所以
// 断言的是"等于算出来的那个数",不是"小于某个我定的阈值"。
// 形状沿用 Basalt `test_camera.cpp` 那一套:多组参数 × 网格穷举 × 阴性对照。

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/pose/zero_velocity_detector.dart';

final double kEps = math.sqrt(2.220446049250313e-16);

ImuSample _s(double ax, double ay, double az,
        [double gx = 0, double gy = 0, double gz = 0]) =>
    // GLRT 不看时间戳(它按**样本数**开窗,W=3 是 Skog 的原设定),
    // 但 ImuSample 已统一成带时间戳的那一个,这里给 0 占位。
    ImuSample(
        timestampSeconds: 0, ax: ax, ay: ay, az: az, gx: gx, gy: gy, gz: gz);

void main() {
  group('GLRT 的闭式解', () {
    test('完美静止(比力恰为 g、角速度恰为 0)⇒ T 恰好等于 0', () {
      const double g = kStandardGravity;
      // 任意朝向都应当为 0 —— 重力方向由窗内均值自己定出来,不假设朝上。
      for (final List<double> dir in <List<double>>[
        <double>[0, 0, 1],
        <double>[0, 0, -1],
        <double>[1, 0, 0],
        <double>[0.577, 0.577, 0.577],
        <double>[-0.6, 0.8, 0],
      ]) {
        final double n =
            math.sqrt(dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]);
        final List<ImuSample> w = List<ImuSample>.generate(
            3, (_) => _s(g * dir[0] / n, g * dir[1] / n, g * dir[2] / n));
        final double t = ZeroVelocityDetector.computeStatistic(w,
            sigmaA: ZuptReference.sigmaA,
            sigmaG: ZuptReference.sigmaG,
            gravity: g);
        expect(t, lessThan(1e-20), reason: '朝向 $dir 的完美静止 T=$t');
      }
    });

    test('只有角速度时 T = |ω|²/σ_g²(闭式)', () {
      const double g = kStandardGravity;
      for (final double w in <double>[1e-4, 1e-3, 1e-2, 0.1, 1.0]) {
        final List<ImuSample> win =
            List<ImuSample>.generate(3, (_) => _s(0, 0, g, w, 0, 0));
        final double t = ZeroVelocityDetector.computeStatistic(win,
            sigmaA: ZuptReference.sigmaA,
            sigmaG: ZuptReference.sigmaG,
            gravity: g);
        final double want = w * w / (ZuptReference.sigmaG * ZuptReference.sigmaG);
        expect((t - want).abs() / want, lessThan(1e-12),
            reason: 'ω=$w: 实得 $t 期望 $want');
      }
    });

    test('只有比力偏差时 T = |Δa|²/σ_a²(闭式)', () {
      const double g = kStandardGravity;
      // 让窗内所有样本有同样的**横向**偏差:均值方向随之偏转,所以这里
      // 用"模长偏差"更干净 —— 沿 z 加一个 δ,均值方向仍是 z。
      for (final double d in <double>[1e-4, 1e-3, 1e-2, 0.1]) {
        final List<ImuSample> win =
            List<ImuSample>.generate(3, (_) => _s(0, 0, g + d));
        final double t = ZeroVelocityDetector.computeStatistic(win,
            sigmaA: ZuptReference.sigmaA,
            sigmaG: ZuptReference.sigmaG,
            gravity: g);
        final double want = d * d / (ZuptReference.sigmaA * ZuptReference.sigmaA);
        expect((t - want).abs() / want, lessThan(1e-10),
            reason: 'Δa=$d: 实得 $t 期望 $want');
      }
    });

    test('T 严格按 1/σ² 缩放(网格穷举 σ 与窗长)', () {
      const double g = kStandardGravity;
      for (final int W in <int>[1, 2, 3, 5, 8, 13]) {
        for (final double ka in <double>[0.5, 1.0, 2.0, 10.0]) {
          final List<ImuSample> win =
              List<ImuSample>.generate(W, (int i) => _s(0, 0, g + 0.01, 0.002, 0, 0));
          final double t1 = ZeroVelocityDetector.computeStatistic(win,
              sigmaA: ZuptReference.sigmaA,
              sigmaG: ZuptReference.sigmaG,
              gravity: g);
          final double t2 = ZeroVelocityDetector.computeStatistic(win,
              sigmaA: ZuptReference.sigmaA * ka,
              sigmaG: ZuptReference.sigmaG * ka,
              gravity: g);
          // 两项都按同一个 ka 缩放 ⇒ 整个 T 除以 ka²
          expect((t2 - t1 / (ka * ka)).abs() / (t1 / (ka * ka)),
              lessThan(1e-12),
              reason: 'W=$W ka=$ka: t1=$t1 t2=$t2');
        }
      }
    });
  });

  group('🔴 不许静默降级', () {
    test('窗未满时 statistic / isStationary 都是 null,不是 0 / false', () {
      final d = ZeroVelocityDetector(windowSize: 5);
      for (int i = 0; i < 4; i++) {
        d.add(_s(0, 0, kStandardGravity));
        expect(d.statistic, isNull, reason: '第 ${i + 1} 条就给结论了');
        expect(d.isStationary, isNull,
            reason: '"还不知道"被当成了"在动/静止"');
      }
      d.add(_s(0, 0, kStandardGravity));
      expect(d.statistic, isNotNull);
      expect(d.isStationary, isTrue);
    });

    test('🔴 喂"去重力加速度"必须显式失败(NaN),不能静默给个数', () {
      // 这是文件头点名的那个误用:iOS userAcceleration / 安卓
      // TYPE_LINEAR_ACCELERATION 已经把重力减掉了,norm(ya_m)→0,式子发散。
      final List<ImuSample> win =
          List<ImuSample>.generate(3, (_) => _s(0, 0, 0, 0, 0, 0));
      final double t = ZeroVelocityDetector.computeStatistic(win,
          sigmaA: ZuptReference.sigmaA,
          sigmaG: ZuptReference.sigmaG,
          gravity: kStandardGravity);
      expect(t.isNaN, isTrue, reason: '实得 $t —— 应当是 NaN 而不是一个数');
    });
  });

  group('🔴 阴性对照:这把尺子分得开静止与运动吗', () {
    test('参考参数下,典型手持抖动的 T 必须远大于完美静止', () {
      const double g = kStandardGravity;
      double tOf(List<ImuSample> w) => ZeroVelocityDetector.computeStatistic(w,
          sigmaA: ZuptReference.sigmaA,
          sigmaG: ZuptReference.sigmaG,
          gravity: g);

      final double still =
          tOf(List<ImuSample>.generate(3, (_) => _s(0, 0, g)));
      // 手持轻微抖动:角速度 ~0.05 rad/s(≈3°/s),比力偏差 ~0.05 m/s²
      final double handheld = tOf(
          List<ImuSample>.generate(3, (_) => _s(0.05, 0, g, 0.05, 0.02, 0.01)));
      // 明显运动:~1 rad/s,~1 m/s²
      final double moving = tOf(
          List<ImuSample>.generate(3, (_) => _s(1.0, 0, g, 1.0, 0.5, 0.3)));

      // ignore: avoid_print
      print('T: 完美静止=$still  手持轻抖=${handheld.toStringAsExponential(3)}  '
          '明显运动=${moving.toStringAsExponential(3)}  '
          '参考阈值 gamma=${ZuptReference.gamma.toStringAsExponential(1)}');

      expect(still, lessThan(handheld));
      expect(handheld, lessThan(moving));
      // 若"明显运动"都压不过参考阈值,说明这组参数对我们毫无分辨力。
      expect(moving, greaterThan(ZuptReference.gamma),
          reason: '明显运动的 T=$moving 还没过 gamma=${ZuptReference.gamma}');
    });
  });
}
