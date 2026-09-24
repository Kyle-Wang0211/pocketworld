// static_init_window_vs_single_sample_test.dart
//
// 钉住「为什么抄 Kimera 而不是 Basalt」这个选择 —— 用**我们自己的实测噪声**,
// 不是拍脑袋。
//
// 两家的静止初始化只差一件事:
//   * Basalt  `sqrt_keypoint_vio.cpp:194-198`(BSD-3):
//       `FromTwoVectors(data->accel, Vec3::UnitZ())` —— **单条** accel 样本
//   * Kimera  `InitializationFromImu.cpp`(BSD-2)/ OKVIS:
//       `computeAverageImuMeasurements(imu_accgyr)` —— **窗内均值**
//   (两家都**没有**静止判定门,那一半是我们自己的 StationarityGate。)
//
// 姿态是靠"测到的重力方向"定的,所以加速度上的扰动 δ 会直接变成
// 角误差 ≈ δ/g 弧度。单样本吃满 δ,N 样本均值把随机部分压 √N。
//
// 实测输入(2026-09-18,iPhone,100 Hz×30 s,两场):
//   静止每样本 σ_a ≈ 1.2e-2 m/s²      运动窗 σ 中位数 1.554 m/s²
//
// 🔴 结论不是"均值精度高一点"(静止时两者都够用:0.070° vs 0.0070°),
//    而是**抗瞬态**:单样本撞上一次轻碰就是 9 度级的姿态错误,
//    而那个错误会被当成重力方向直接写进初始状态。

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/pose/gravity_attitude.dart';
import 'package:pocketworld_flutter/vio/pose/tracked_pose.dart';

const double _g = GravityAttitude.nominalGravity;

/// 实测:静止时每样本加速度标准差(m/s²)。两场 p50 1.19e-2 / 1.30e-2,取大的。
const double kMeasuredStillSigmaA = 1.30e-2;

/// 实测:运动窗标准差中位数(m/s²)。用来模拟一次轻碰/手抖瞬态。
const double kMeasuredMovingP50 = 1.554;

/// 设备平放(比力 = +g 在 z 轴),叠加一个只在 x 轴上的扰动。
ImuSample _s(double t, double perturbX) => ImuSample(
      timestampSeconds: t,
      ax: perturbX,
      ay: 0,
      az: _g,
      gx: 0,
      gy: 0,
      gz: 0,
    );

/// 解出的姿态相对"完美平放"(单位四元数)的角误差,弧度。
/// 四元数与旋转角的关系:θ = 2·acos(|w|)。
double _angleErrorRad(PoseQuaternion q) =>
    2.0 * math.acos(math.min(1.0, q.w.abs()));

/// 两个单位四元数之间的夹角,弧度。θ = 2·acos(|q1·q2|)。
double _angleBetween(PoseQuaternion a, PoseQuaternion b) {
  final double d = (a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w).abs();
  return 2.0 * math.acos(math.min(1.0, d));
}

void main() {
  group('单样本 vs 窗均值 —— 用实测噪声量化', () {
    test('完美静止时两者都精确(基线:没有扰动就没有误差)', () {
      final List<ImuSample> one = <ImuSample>[_s(0, 0)];
      final List<ImuSample> many =
          List<ImuSample>.generate(100, (int i) => _s(i / 100, 0));

      final StationaryAttitude? a =
          GravityAttitude.solve(one, minimumSamples: 1);
      final StationaryAttitude? b = GravityAttitude.solve(many);
      expect(a, isNotNull);
      expect(b, isNotNull);
      expect(_angleErrorRad(a!.attitude), closeTo(0, 1e-12));
      expect(_angleErrorRad(b!.attitude), closeTo(0, 1e-12));
    });

    test('🔴 撞上一次瞬态:单样本 ≈9°,窗均值把它摊掉', () {
      // Basalt 口径:恰好取到瞬态那一条。
      final StationaryAttitude? single = GravityAttitude.solve(
        <ImuSample>[_s(0, kMeasuredMovingP50)],
        minimumSamples: 1,
      );
      // Kimera 口径:100 条里只有 1 条是瞬态,其余干净。
      final List<ImuSample> window = List<ImuSample>.generate(
          100, (int i) => _s(i / 100, i == 50 ? kMeasuredMovingP50 : 0));
      final StationaryAttitude? mean = GravityAttitude.solve(window);

      final double eSingle = _angleErrorRad(single!.attitude);
      final double eMean = _angleErrorRad(mean!.attitude);

      // 单样本:θ ≈ atan(δ/g) = atan(1.554/9.80665) ≈ 0.1570 rad ≈ 9.0°
      expect(eSingle, closeTo(math.atan(kMeasuredMovingP50 / _g), 1e-6));
      expect(eSingle * 180 / math.pi, closeTo(9.0, 0.2));

      // 窗均值:扰动被 100 摊薄 ⇒ 约小两个数量级。
      expect(eMean * 180 / math.pi, lessThan(0.1));
      expect(eSingle / eMean, greaterThan(50),
          reason: '这就是选 Kimera 不选 Basalt 的量化理由');
    });

    test('🔴 Kimera 自带 ±2.56° 死区 —— 这是它的源码行为,不是我抄错', () {
      // Kimera `UtilsOpenCV.cpp:300`:
      //     if (std::fabs(1 - c) < 1e-3) { R = gtsam::Rot3(); }  // Already aligned
      // 1 − cos θ < 1e-3  ⇔  θ < arccos(0.999) = 0.044722 rad = **2.5624°**
      // 落在死区内一律交单位四元数。
      //
      // 🔴 「手机平放桌上」正好落在死区里 —— 那正是我们静止起步的主场景。
      //    好处:实测 σ_a 造成的 0.076° 伪倾斜被直接吃掉(它本来就是噪声);
      //    代价:真实倾斜若小于 2.56°,也会被当成"已对齐"抹平。
      const double deadZoneRad = 0.044722;
      expect(math.acos(1 - 1e-3), closeTo(deadZoneRad, 1e-5));
      expect(deadZoneRad * 180 / math.pi, closeTo(2.5624, 1e-3));

      // 死区内:交单位四元数。
      final double insideTilt = deadZoneRad * 0.9;
      final StationaryAttitude? inside = GravityAttitude.solve(
        <ImuSample>[
          ImuSample(
              timestampSeconds: 0,
              ax: _g * math.sin(insideTilt),
              ay: 0,
              az: _g * math.cos(insideTilt),
              gx: 0,
              gy: 0,
              gz: 0)
        ],
        minimumSamples: 1,
      );
      expect(_angleErrorRad(inside!.attitude), 0.0,
          reason: '死区内 ⇒ 恰好单位四元数');

      // 死区外:老老实实算。
      final double outsideTilt = deadZoneRad * 1.5;
      final StationaryAttitude? outside = GravityAttitude.solve(
        <ImuSample>[
          ImuSample(
              timestampSeconds: 0,
              ax: _g * math.sin(outsideTilt),
              ay: 0,
              az: _g * math.cos(outsideTilt),
              gx: 0,
              gy: 0,
              gz: 0)
        ],
        minimumSamples: 1,
      );
      expect(_angleErrorRad(outside!.attitude), closeTo(outsideTilt, 1e-6));
    });

    test('死区之外,√N 律成立:单样本吃满噪声,窗均值摊掉', () {
      // 🔴 必须在**死区之外**比,否则两边都被死区抹成单位四元数,
      //    那就是"断言死区等于死区",分辨不出均值的作用。
      //    这里把设备倾斜 30°(远在 2.56° 之外)。
      const double tilt = 30 * math.pi / 180;
      final double gx0 = _g * math.sin(tilt), gz0 = _g * math.cos(tilt);
      ImuSample at(double t, double dx) => ImuSample(
          timestampSeconds: t, ax: gx0 + dx, ay: 0, az: gz0, gx: 0, gy: 0, gz: 0);

      final PoseQuaternion clean =
          GravityAttitude.solve(<ImuSample>[at(0, 0)], minimumSamples: 1)!
              .attitude;
      final PoseQuaternion single = GravityAttitude.solve(
              <ImuSample>[at(0, kMeasuredStillSigmaA)],
              minimumSamples: 1)!
          .attitude;
      final PoseQuaternion mean = GravityAttitude.solve(
              List<ImuSample>.generate(
                  100,
                  (int i) => at(i / 100,
                      i.isEven ? kMeasuredStillSigmaA : -kMeasuredStillSigmaA)))!
          .attitude;

      final double eSingle = _angleBetween(single, clean);
      final double eMean = _angleBetween(mean, clean);

      // 🔴 闭式是 **δ·cos(tilt)/g**,不是 δ/g:
      //    x 轴上的扰动只有**垂直于重力方向**的那个分量才产生角误差,
      //    设备倾斜 tilt 时该分量被投影掉 cos(tilt)。
      //    平放(tilt=0)时才退化成 δ/g。
      //    δ·cos30°/g = 1.30e-2×0.86603/9.80665 = 1.148e-3 rad = 0.0658°
      expect(eSingle, closeTo(kMeasuredStillSigmaA * math.cos(tilt) / _g, 2e-6));
      expect(eSingle * 180 / math.pi, closeTo(0.0658, 0.001));
      // 零均值扰动 ⇒ 均值解与干净解一致。
      expect(eMean, lessThan(eSingle / 100));
    });

    test('Kimera 还多给一样 Basalt 没有的东西:IMU 零偏', () {
      // Basalt 的 initialize(bg, ba) 是**把零偏当入参要来的**;
      // Kimera 的 guessImuBias 从同一段静止数据里估出来。
      final List<ImuSample> window = List<ImuSample>.generate(
          100,
          (int i) => ImuSample(
                timestampSeconds: i / 100,
                ax: 0,
                ay: 0,
                az: _g,
                gx: 0.01, // 一个已知的陀螺零偏
                gy: 0,
                gz: 0,
              ));
      final StationaryAttitude? a = GravityAttitude.solve(window);
      expect(a, isNotNull);
      // guessImuBias 的陀螺那一半就是窗内均值,原样交出。
      expect(a!.gyroscopeBias[0], closeTo(0.01, 1e-12));
    });
  });
}
