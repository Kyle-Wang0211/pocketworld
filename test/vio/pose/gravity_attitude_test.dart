// gravity_attitude_test.dart — 验证复刻的数学,不是验证它"跑得通"。
//
// 这一层每一个错误都是静默的:四元数 w 放错位置、旋转方向反了、反平行分支
// 没走到 —— 全都不崩,只让姿态错一点点,看起来像"精度不够"。所以每条断言
// 都针对一个**能独立算出正确答案**的构型。

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/pose/gravity_attitude.dart';
import 'package:pocketworld_flutter/vio/pose/tracked_pose.dart';

/// 用四元数转向量,独立于被测代码的实现路径(这里用矩阵形式,
/// 被测代码用 Rodrigues 形式 —— 两条路算错的方式不一样,才有对照价值)。
List<double> rotate(PoseQuaternion q, List<double> v) {
  final PoseQuaternion u = q.normalized();
  final double x = u.x, y = u.y, z = u.z, w = u.w;
  final List<List<double>> r = <List<double>>[
    <double>[1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
    <double>[2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
    <double>[2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
  ];
  return <double>[
    r[0][0] * v[0] + r[0][1] * v[1] + r[0][2] * v[2],
    r[1][0] * v[0] + r[1][1] * v[1] + r[1][2] * v[2],
    r[2][0] * v[0] + r[2][1] * v[1] + r[2][2] * v[2],
  ];
}

void expectVectorClose(List<double> a, List<double> b, {double tol = 1e-9}) {
  for (int i = 0; i < 3; i++) {
    expect(a[i], closeTo(b[i], tol), reason: '分量 $i: $a vs $b');
  }
}

List<ImuSample> stationaryWindow({
  required double ax,
  required double ay,
  required double az,
  int count = 100,
}) {
  return List<ImuSample>.generate(
    count,
    (int i) => ImuSample(
      timestampSeconds: i * 0.01,
      ax: ax,
      ay: ay,
      az: az,
      gx: 0,
      gy: 0,
      gz: 0,
    ),
  );
}

void main() {
  group('alignVectors — R * from = to,这是契约本身', () {
    test('一般情形:任意方向都必须真的被转过去', () {
      final List<List<double>> cases = <List<double>>[
        <double>[1, 0, 0],
        <double>[0, 1, 0],
        <double>[0.3, -0.7, 0.2],
        <double>[-0.1, 0.05, 0.99],
      ];
      for (final List<double> from in cases) {
        const List<double> to = <double>[0, 0, -1];
        final PoseQuaternion? q = GravityAttitude.alignVectors(from, to);
        expect(q, isNotNull, reason: 'from=$from 应当有解');
        final double n =
            math.sqrt(from[0] * from[0] + from[1] * from[1] + from[2] * from[2]);
        final List<double> unitFrom = <double>[
          from[0] / n,
          from[1] / n,
          from[2] / n
        ];
        expectVectorClose(rotate(q!, unitFrom), to, tol: 1e-9);
      }
    });

    test('已对齐分支:返回单位四元数,不是"接近单位"', () {
      final PoseQuaternion? q =
          GravityAttitude.alignVectors(<double>[0, 0, -2], <double>[0, 0, -1]);
      expect(q, isNotNull);
      expect(q!.x, 0);
      expect(q.y, 0);
      expect(q.z, 0);
      expect(q.w, 1);
    });

    test('反平行分支:转 180° 且确实到位(最短弧公式在这里会退化成零四元数)',
        () {
      final PoseQuaternion? q =
          GravityAttitude.alignVectors(<double>[0, 0, 1], <double>[0, 0, -1]);
      expect(q, isNotNull);
      expect(q!.isUsableRotation, isTrue, reason: '反平行不能退化成零四元数');
      expectVectorClose(
        rotate(q, <double>[0, 0, 1]),
        <double>[0, 0, -1],
        tol: 1e-9,
      );
      // 180° ⇒ 实部为 0。
      expect(q.w.abs(), closeTo(0, 1e-12));
    });

    test('零向量返回 null,不返回单位姿态', () {
      expect(
        GravityAttitude.alignVectors(<double>[0, 0, 0], <double>[0, 0, -1]),
        isNull,
      );
    });

    test('round=true 把方向吸到最强轴(Kimera RoundUnit3 的语义)', () {
      // [0.01, 0.1, 1] 应当被吸成 [0, 0, 1]。
      final PoseQuaternion? rounded = GravityAttitude.alignVectors(
        <double>[0.01, 0.1, 1],
        <double>[0, 0, 1],
        round: true,
      );
      expect(rounded, isNotNull);
      // 吸附后两边同向 ⇒ 落到"已对齐"分支 ⇒ 单位四元数。
      expect(rounded!.w, 1);
    });
  });

  group('solve — 静止起步', () {
    test('手机平放、屏幕朝上:比力为 +z·g,姿态把 −比力 转到 −z', () {
      // 静止时加速度计读到的是比力 = −重力,平放朝上即 +z 方向、模长 g。
      final StationaryAttitude? s = GravityAttitude.solve(
        stationaryWindow(ax: 0, ay: 0, az: GravityAttitude.nominalGravity),
      );
      expect(s, isNotNull);
      // measured_gravity = −mean_acc = (0,0,−g),已与 globalGravityZUp 同向
      // ⇒ 单位姿态。
      expect(s!.attitude.w, closeTo(1, 1e-12));
      expect(s.sampleCount, 100);
    });

    test('手机侧放:姿态必须把测得的重力方向转到世界 −z', () {
      final StationaryAttitude? s = GravityAttitude.solve(
        stationaryWindow(ax: GravityAttitude.nominalGravity, ay: 0, az: 0),
      );
      expect(s, isNotNull);
      // 测得重力方向(归一)= −(1,0,0) = (−1,0,0)。
      expectVectorClose(
        rotate(s!.attitude, <double>[-1, 0, 0]),
        <double>[0, 0, -1],
        tol: 1e-9,
      );
    });

    test('偏置:理想无偏 IMU 解出的加速度计偏置应当接近零', () {
      final StationaryAttitude? s = GravityAttitude.solve(
        stationaryWindow(ax: 0, ay: 0, az: GravityAttitude.nominalGravity),
      );
      expect(s, isNotNull);
      for (final double b in s!.accelerometerBias) {
        expect(b.abs(), lessThan(1e-9), reason: '无偏输入不应解出偏置 $b');
      }
      for (final double b in s.gyroscopeBias) {
        expect(b, 0);
      }
    });

    test('陀螺偏置就是均值(Kimera guessImuBias 的 tail(3))', () {
      final List<ImuSample> w = List<ImuSample>.generate(
        50,
        (int i) => ImuSample(
          timestampSeconds: i * 0.01,
          ax: 0,
          ay: 0,
          az: GravityAttitude.nominalGravity,
          gx: 0.01,
          gy: -0.02,
          gz: 0.003,
        ),
      );
      final StationaryAttitude? s = GravityAttitude.solve(w);
      expect(s, isNotNull);
      expect(s!.gyroscopeBias[0], closeTo(0.01, 1e-12));
      expect(s.gyroscopeBias[1], closeTo(-0.02, 1e-12));
      expect(s.gyroscopeBias[2], closeTo(0.003, 1e-12));
    });

    test('样本不足返回 null,不返回"看起来像答案"的东西', () {
      expect(GravityAttitude.solve(stationaryWindow(ax: 0, ay: 0, az: 9.8, count: 3)),
          isNull);
      expect(GravityAttitude.solve(const <ImuSample>[]), isNull);
    });

    test('全非有限返回 null', () {
      final List<ImuSample> w = List<ImuSample>.generate(
        50,
        (int i) => ImuSample(
          timestampSeconds: i * 0.01,
          ax: double.nan,
          ay: 0,
          az: 0,
          gx: 0,
          gy: 0,
          gz: 0,
        ),
      );
      expect(GravityAttitude.solve(w), isNull);
    });

    test('自由落体(比力≈0)返回 null —— 没有重力方向可解', () {
      expect(
        GravityAttitude.solve(stationaryWindow(ax: 0, ay: 0, az: 0)),
        isNull,
      );
    });
  });

  group('交出的是 3DOF,不是 6DOF', () {
    test('toTrackedPose:朝向有效且在跟踪,位置无效', () {
      final StationaryAttitude? s = GravityAttitude.solve(
        stationaryWindow(ax: 0, ay: 0, az: GravityAttitude.nominalGravity),
      );
      final TrackedPose p = s!.toTrackedPose();
      expect(p.orientationValid, isTrue);
      expect(p.orientationTracked, isTrue);
      // 🔴 这两条是本次改动的全部意义:位置不可观,就不能被读到。
      expect(p.positionValid, isFalse);
      expect(p.positionTracked, isFalse);
      expect(p.position, isNull);
      expect(p.isOrientationOnly, isTrue);
      expect(p.isSixDegreeOfFreedom, isFalse);
    });
  });
}
