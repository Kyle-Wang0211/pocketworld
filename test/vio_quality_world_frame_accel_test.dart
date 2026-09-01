// 世界系转换单测。重点是那条"路线 A 会把重力泄漏成假激励"的量化对照。

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/quality/scale_observability.dart';
import 'package:pocketworld_flutter/vio/quality/world_frame_accel.dart';

/// 绕 z 轴转 [deg] 的 device→world 四元数。
List<double> _qz(double deg) {
  final h = deg * math.pi / 180.0 / 2.0;
  return <double>[math.cos(h), 0.0, 0.0, math.sin(h)];
}

/// 绕 x 轴转 [deg]。
List<double> _qx(double deg) {
  final h = deg * math.pi / 180.0 / 2.0;
  return <double>[math.cos(h), math.sin(h), 0.0, 0.0];
}

void main() {
  group('旋转本身是对的', () {
    test('单位四元数 = 恒等', () {
      final v = rotateDeviceToWorld(1, 2, 3, qw: 1, qx: 0, qy: 0, qz: 0);
      expect(v[0], closeTo(1, 1e-12));
      expect(v[1], closeTo(2, 1e-12));
      expect(v[2], closeTo(3, 1e-12));
    });

    test('绕 z 转 90°:x 轴 → y 轴', () {
      final q = _qz(90);
      final v = rotateDeviceToWorld(
        1,
        0,
        0,
        qw: q[0],
        qx: q[1],
        qy: q[2],
        qz: q[3],
      );
      expect(v[0], closeTo(0, 1e-12));
      expect(v[1], closeTo(1, 1e-12));
      expect(v[2], closeTo(0, 1e-12));
    });

    test('一般四元数:绕 (1,1,1) 转 120° 应当循环置换三轴', () {
      // 🔴 前一版这一组只用了绕单轴的四元数,而那种情形下 Rodrigues 公式里
      // 有整整一项恒为 0 —— 把它的符号改反,测试照样全绿(M10 实测)。
      // 这条用一般四元数补上:q=(0.5,0.5,0.5,0.5) ⇒ x→y→z→x,三个分量全被用到。
      const q = <double>[0.5, 0.5, 0.5, 0.5];
      List<double> rot(double x, double y, double z) =>
          rotateDeviceToWorld(x, y, z, qw: q[0], qx: q[1], qy: q[2], qz: q[3]);
      final ex = rot(1, 0, 0), ey = rot(0, 1, 0), ez = rot(0, 0, 1);
      for (final pair in <List<Object>>[
        [
          ex,
          <double>[0, 1, 0],
        ],
        [
          ey,
          <double>[0, 0, 1],
        ],
        [
          ez,
          <double>[1, 0, 0],
        ],
      ]) {
        final got = pair[0] as List<double>;
        final want = pair[1] as List<double>;
        for (var i = 0; i < 3; i++) {
          expect(
            got[i],
            closeTo(want[i], 1e-12),
            reason: 'got=$got want=$want',
          );
        }
      }
    });

    test('旋转后的三个基向量仍是右手正交标架(通用符号错误都会挂在这)', () {
      const q = <double>[0.6, 0.4, -0.5, 0.48]; // 任意非轴对齐
      List<double> rot(double x, double y, double z) =>
          rotateDeviceToWorld(x, y, z, qw: q[0], qx: q[1], qy: q[2], qz: q[3]);
      final a = rot(1, 0, 0), b = rot(0, 1, 0), c = rot(0, 0, 1);
      double dot(List<double> u, List<double> v) =>
          u[0] * v[0] + u[1] * v[1] + u[2] * v[2];
      // 正交归一
      expect(dot(a, a), closeTo(1, 1e-12));
      expect(dot(b, b), closeTo(1, 1e-12));
      expect(dot(a, b), closeTo(0, 1e-12));
      expect(dot(a, c), closeTo(0, 1e-12));
      expect(dot(b, c), closeTo(0, 1e-12));
      // 右手:a × b == c(行列式 +1,排除镜像/共轭)
      final cross = <double>[
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
      ];
      for (var i = 0; i < 3; i++) {
        expect(cross[i], closeTo(c[i], 1e-12), reason: 'a×b=$cross c=$c');
      }
    });

    test('旋转保模长(否则会直接毒化 acRms)', () {
      final q = _qx(37.5);
      final v = rotateDeviceToWorld(
        0.3,
        -1.2,
        0.7,
        qw: q[0],
        qx: q[1],
        qy: q[2],
        qz: q[3],
      );
      final n0 = math.sqrt(0.3 * 0.3 + 1.2 * 1.2 + 0.7 * 0.7);
      final n1 = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
      expect(n1, closeTo(n0, 1e-12));
    });

    test('非单位四元数被归一化(AHRS 漂出单位模长时不缩放幅值)', () {
      final v = rotateDeviceToWorld(1, 0, 0, qw: 2, qx: 0, qy: 0, qz: 0);
      expect(
        math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]),
        closeTo(1, 1e-12),
      );
    });

    test('退化四元数不崩,原样返回', () {
      final v = rotateDeviceToWorld(1, 2, 3, qw: 0, qx: 0, qy: 0, qz: 0);
      expect(v, <double>[1, 2, 3]);
    });
  });

  group('🔴 重力泄漏:为什么必须用 userAcceleration', () {
    test('路线 A 的泄漏量与达标门槛同量级', () {
      // 姿态误差 0.5° ⇒ 重力漏进水平轴 g·sin(0.5°)
      const g = 9.81;
      final leak = g * math.sin(0.5 * math.pi / 180.0);
      // 2 s @ 300 Hz、σ_a=0.02 的达标门槛
      final gate = requiredAcRmsMps2(
        accelNoiseSigmaMps2: 0.02,
        targetRelativeScaleSigma: 0.01,
        samples: 600,
      );
      expect(leak, closeTo(0.0856, 1e-3));
      expect(gate, closeTo(0.0816, 1e-3));
      // 泄漏比门槛还大 ⇒ 站着原地转就能"达标",假阳性。
      expect(
        leak,
        greaterThan(gate),
        reason: '路线 A 泄漏 $leak vs 门槛 $gate —— 这就是不许走路线 A 的原因',
      );
    });

    test('路线 B 的泄漏按残差比例缩放,小三个数量级', () {
      // 手持典型残差 0.05 m/s²,同样 0.5° 姿态误差
      const residual = 0.05;
      final leakB = residual * math.sin(0.5 * math.pi / 180.0);
      expect(leakB, lessThan(0.001));
      final leakA = 9.81 * math.sin(0.5 * math.pi / 180.0);
      expect(leakA / leakB, closeTo(9.81 / residual, 1e-6));
      expect(leakA / leakB, greaterThan(100));
    });

    test('单位自证:把原始比力当 userAcceleration 会被认出来', () {
      expect(looksLikeGravityRemoved(0.05), isTrue);
      expect(looksLikeGravityRemoved(9.81), isFalse);
    });
  });

  group('与判据二串起来', () {
    test('原地绕 z 匀速转、真实线加速度为零 ⇒ 世界系读数仍为零 ⇒ 不达标', () {
      const cfg = ScaleObservabilityConfig(accelNoiseSigmaMps2: 0.02);
      final est = ScaleObservabilityEstimator(cfg);
      for (var i = 0; i < 600; i++) {
        final t = i / 300.0;
        final q = _qz(180.0 * t); // 180°/s 的原地自转
        // 真实(去重力后)线加速度恒为 0 —— 人站着没走。
        final w = rotateDeviceToWorld(
          0,
          0,
          0,
          qw: q[0],
          qx: q[1],
          qy: q[2],
          qz: q[3],
        );
        est.addLinearAccel(t, w[0], w[1], w[2]);
      }
      for (var i = 0; i < 60; i++) {
        est.addPose(
          i / 30.0,
          0,
          0,
          0,
          medianLandmarkDepth: 2.0,
          rotationDeltaDeg: 6.0,
        );
      }
      final s = est.evaluate();
      expect(s.excitationOk, isFalse);
      expect(s.verdict, ScaleObservabilityVerdict.pureRotation);
    });
  });
}
