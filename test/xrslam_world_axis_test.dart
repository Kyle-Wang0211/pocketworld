// xrslam_world_axis_test.dart —— 换轴函数的判据。
//
// 真值只有一个:09-16 共享录制上 SE(3) 拟合实测出来的置换
//     x_A = −y_X    y_A = +z_X    z_A = −x_X
// 下面每一条都是从这条推出来的,**不是**从「z-up vs y-up」的惯例推的
// (惯例只能给出「有一个轴换到了 y」,给不出三个符号)。

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/pose/xrslam_world_axis.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  group('置换表本身', () {
    test('三条基向量逐位落在实测的那张表上', () {
      // e_x(XRSLAM)→ ARKit 的 (0, 0, −1)
      expect(
        _v(xrslamPositionToArkit(Vector3(1, 0, 0))),
        <double>[0, 0, -1],
      );
      // e_y → (−1, 0, 0)
      expect(
        _v(xrslamPositionToArkit(Vector3(0, 1, 0))),
        <double>[-1, 0, 0],
      );
      // e_z(XRSLAM 的「上」)→ (0, 1, 0)(ARKit 的「上」)
      expect(
        _v(xrslamPositionToArkit(Vector3(0, 0, 1))),
        <double>[0, 1, 0],
      );
    });

    test('行列式 = +1 ⇒ 是旋转不是镜像', () {
      // ⚠️ 这一条**挡不住**「照上游那个 (−y,−x,−z) 改一下」—— 那个的行列式
      //    也是 +1(下一条测试里算了)。它挡的是手滑:写重一个轴、漏一个
      //    符号,行列式就不再是 ±1。
      expect(xrslamToArkitDeterminant(), closeTo(1.0, 1e-12));
      expect(xrslamToArkitDeterminant(), closeTo(kXrslamToArkitDeterminant, 1e-12));
    });

    test('🔴 真正把两个候选分开的判据:XRSLAM 的重力轴 +z 必须落到 ARKit 的 +y', () {
      // ⚠️ 我最早写的判据是「上游那个 (−y,−x,−z) 行列式 −1,所以是镜像」——
      //    **算过了,不是**:它的行列式也是 +1,也是真旋转。determinant
      //    分不开这两个候选。这条测试是改正后的判据。
      //
      // 上游 SceneKit 那个:(x,y,z) → (−y,−x,−z),行主序
      //   | 0 −1  0 |
      //   |−1  0  0 |
      //   | 0  0 −1 |
      final Matrix3 upstream = Matrix3.zero();
      upstream.setEntry(0, 1, -1);
      upstream.setEntry(1, 0, -1);
      upstream.setEntry(2, 2, -1);
      expect(
        upstream.determinant(),
        closeTo(1.0, 1e-12),
        reason: '两个候选都是真旋转 —— determinant 不是判据',
      );

      // 判据在这里:ARKit 的 worldAlignment = .gravity ⇒ +y 就是「上」;
      // XRSLAM 的世界系是 z-up ⇒ 换系后 +z 必须变成 +y。
      expect(
        _v(xrslamPositionToArkit(Vector3(0, 0, 1))),
        _closeVec(<double>[0, 1, 0]),
        reason: '实测那个把重力轴接上了',
      );
      // 上游那个把 +z 送到了 −z —— 一个**水平**方向 ⇒ 整个 dome 会躺倒 90°。
      final Vector3 upstreamUp = upstream * Vector3(0, 0, 1) as Vector3;
      expect(_v(upstreamUp), _closeVec(<double>[0, 0, -1]));
      expect(
        upstreamUp.y.abs() < 1e-12,
        isTrue,
        reason: '上游那个换完之后「上」没有分量落在 ARKit 的 y 上 ⇒ 不是世界系换算',
      );

      // 两者在 ARKit 系里差一个绕 x 轴的 90°(U·Mᵀ 固定 x、y→−z、z→+y)。
      final Matrix3 measured = Matrix3.zero();
      for (int r = 0; r < 3; r++) {
        for (int c = 0; c < 3; c++) {
          measured.setEntry(r, c, kXrslamToArkitRows[r][c]);
        }
      }
      final Matrix3 rel = upstream * measured.transposed() as Matrix3;
      expect(_v(rel * Vector3(1, 0, 0) as Vector3), _closeVec(<double>[1, 0, 0]));
      expect(_v(rel * Vector3(0, 1, 0) as Vector3), _closeVec(<double>[0, 0, -1]));
      expect(_v(rel * Vector3(0, 0, 1) as Vector3), _closeVec(<double>[0, 1, 0]));
    });

    test('模长严格不变(纯重排+取反,没有缩放、没有杠杆臂)', () {
      // 🔴 杠杆臂那一项如果被人「顺手补上」,模长就会变 —— 这条会红。
      //    两边同为 CAMERA_POSE ⇒ 33.75mm 的 p_bc 不该出现在这里。
      for (final Vector3 p in <Vector3>[
        Vector3(0.123, -4.56, 7.89),
        Vector3(1, 1, 1),
        Vector3(-0.001, 0, 1e6),
      ]) {
        expect(
          xrslamPositionToArkit(p).length,
          closeTo(p.length, 1e-9),
          reason: '换轴改了模长 ⇒ 混进了缩放或平移',
        );
      }
    });
  });

  group('姿态', () {
    test('「相机看向 XRSLAM 的天花板(+z)」换过去要变成「看向 ARKit 的 +y」', () {
      // 相机光轴是局部 −z(OpenGL 式)。构造一个姿态,使得光轴在 XRSLAM
      // 世界系里指向 +z。
      final Quaternion qX = _lookAlong(Vector3(0, 0, 1));
      final Vector3 fwdX = _forward(qX);
      expect(_v(fwdX), _closeVec(<double>[0, 0, 1]));

      final Quaternion qA = xrslamOrientationToArkit(qX);
      final Vector3 fwdA = _forward(qA);
      // XRSLAM 的 +z(上)→ ARKit 的 +y(上)。
      expect(_v(fwdA), _closeVec(<double>[0, 1, 0]));
    });

    test('换轴对姿态与位置是同一个变换(同一个向量两条路算出来一样)', () {
      // 把一个向量当成「相机局部 −z 方向」走姿态那条路,再当成位置走位置
      // 那条路,两条路必须给出同一个结果 —— 否则就是某一条少了/多了一步。
      final Vector3 dir = Vector3(0.3, -0.5, 0.81)..normalize();
      final Quaternion qX = _lookAlong(dir);
      final Vector3 viaOrientation = _forward(xrslamOrientationToArkit(qX));
      final Vector3 viaPosition = xrslamPositionToArkit(dir);
      expect(_v(viaOrientation), _closeVec(_v(viaPosition)));
    });

    test('退化四元数原样返回,不归一化成一个假的好数据', () {
      // 引擎在第一个 TRACKING_SUCCESS 会返回零范数四元数(09-16 实证)。
      final Quaternion zero = Quaternion(0, 0, 0, 0);
      final Quaternion out = xrslamOrientationToArkit(zero);
      expect(out.x, 0);
      expect(out.y, 0);
      expect(out.z, 0);
      expect(out.w, 0);
    });

    test('换出来的四元数是单位四元数', () {
      final Quaternion qX = Quaternion.axisAngle(
        Vector3(0.2, 0.9, -0.4)..normalize(),
        1.234,
      );
      final Quaternion qA = xrslamOrientationToArkit(qX);
      expect(qA.length, closeTo(1.0, 1e-12));
    });
  });

  group('4×4 外参', () {
    test('列主序、最后一列是换轴后的平移、左上 3×3 是换轴后的旋转', () {
      final Quaternion qX = Quaternion.axisAngle(Vector3(0, 0, 1), 0.7);
      final Vector3 pX = Vector3(1.0, 2.0, 3.0);
      final List<double> m = xrslamCameraToWorldArkitColumnMajor(qX, pX);
      expect(m.length, 16);

      final Vector3 pA = xrslamPositionToArkit(pX);
      // Matrix4 的 storage 是列主序 ⇒ 平移在 [12],[13],[14]。
      expect(m[12], closeTo(pA.x, 1e-12));
      expect(m[13], closeTo(pA.y, 1e-12));
      expect(m[14], closeTo(pA.z, 1e-12));
      expect(m[15], closeTo(1.0, 1e-12));

      final Matrix3 rA = Matrix3.identity();
      xrslamOrientationToArkit(qX).copyRotationInto(rA);
      for (int c = 0; c < 3; c++) {
        for (int r = 0; r < 3; r++) {
          expect(m[c * 4 + r], closeTo(rA.entry(r, c), 1e-12));
        }
      }
    });
  });
}

List<double> _v(Vector3 v) => <double>[v.x, v.y, v.z];

Matcher _closeVec(List<double> expected) => pairwiseCompare<double, double>(
      expected,
      (double a, double b) => (a - b).abs() < 1e-9,
      'each component within 1e-9',
    );

/// 造一个姿态,使相机光轴(局部 −z)在世界系里指向 [dir]。
Quaternion _lookAlong(Vector3 dir) {
  final Vector3 d = dir.normalized();
  final Vector3 minusZ = Vector3(0, 0, -1);
  final Vector3 axis = minusZ.cross(d);
  final double dot = minusZ.dot(d).clamp(-1.0, 1.0);
  if (axis.length < 1e-12) {
    // 平行或反平行。
    return dot > 0
        ? Quaternion.identity()
        : Quaternion.axisAngle(Vector3(0, 1, 0), math.pi);
  }
  return Quaternion.axisAngle(axis.normalized(), math.acos(dot));
}

/// 相机光轴在世界系里的方向。
Vector3 _forward(Quaternion q) {
  final Matrix3 r = Matrix3.identity();
  q.copyRotationInto(r);
  return r * Vector3(0, 0, -1) as Vector3;
}
