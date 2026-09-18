// projection_roundtrip_test.dart
//
// ══ 这是复刻,不是自研 ═════════════════════════════════════════════════════
// 对照件:**Basalt** `basalt-headers/test/src/test_camera.cpp`
// (BSD-3-Clause,Usenko/Demmel/Cremers,TUM)。它是相机模型验证的标准形状,
// 逐条照搬它的**结构**:
//
//   void testProjectUnproject() {
//     Eigen::aligned_vector<CamT> test_cams = CamT::getTestProjections();
//     for (const CamT &cam : test_cams)
//       for (int x = -10; x <= 10; x++)
//         for (int y = -10; y <= 10; y++)
//           for (int z = 0; z <= 5; z++) {
//             Vec4 p(x, y, z, 0.23424);
//             if (cam.project(p, res)) {
//               cam.unproject(res, p_uproj);
//               EXPECT_TRUE(p_normalized.isApprox(
//                   p_uproj, Sophus::Constants<Scalar>::epsilonSqrt()));
//             }
//           }
//   }
//
// 照搬的四条:
//   ① **多组相机参数**(它的 getTestProjections);
//   ② **网格穷举采样**,不是手挑几个点;
//   ③ 判据是**往返自洽**:project 再 unproject,必须回到**同一条归一化射线**;
//   ④ 容差 = `epsilonSqrt()` = √(机器 epsilon),**从浮点精度推出来**,
//      不是拍一个像素数。double 下 ≈ 1.49e-8。
//
// 🔴 我先前自己设计过一个"真机渲染 + 红块质心"的探针,调了三轮还在调阈值和
// 标记形状。那是自研。这一份是去看人家代码库抄回来的:纯 CPU、秒级、能进
// CI、不用设备不用相机,而且穷举采样没法平凡通过。
//
// ⚠️ 本文件验的是**投影链的自洽性**(frustum ↔ glProjection ↔ unproject)
// 与**位姿矩阵的互逆性**。`CameraProjection.rotate` 的**取值**对不对由
// rotate_intrinsics_agreement_test.dart 那组阴阳对照把关;`displayRoll` 的
// **取值**只能对着相机图像验,不在这里。别把这里的通过当成那两件事验过了。

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/pose/camera_projection.dart';
import 'package:pocketworld_flutter/vio/pose/tracked_pose.dart';
import 'package:pocketworld_flutter/vio/pose/world_to_renderer.dart';

/// 复刻 Basalt 的 `Sophus::Constants<Scalar>::epsilonSqrt()`。
/// double 的机器 epsilon 是 2^-52;开方 ≈ 1.49e-8。
final double kEpsilonSqrt = math.sqrt(2.220446049250313e-16);

/// 复刻 `CamT::getTestProjections()` —— 一组**有代表性**的相机参数,
/// 而不是只测一个。刻意包含非居中主点、非方形像素、极端宽高比。
List<PinholeIntrinsics> _getTestProjections() => <PinholeIntrinsics>[
      // 生产影子在跑的那一档(XRSLAM 上游 18/18 iPhone 标定的尺寸)
      const PinholeIntrinsics(
          fx: 437.222, fy: 437.222, cx: 330.5, cy: 225.25,
          imageWidth: 640, imageHeight: 480),
      // 主点严重偏心
      const PinholeIntrinsics(
          fx: 500, fy: 500, cx: 100.5, cy: 400.25,
          imageWidth: 640, imageHeight: 480),
      // 非方形像素
      const PinholeIntrinsics(
          fx: 900, fy: 600, cx: 960.5, cy: 720.5,
          imageWidth: 1920, imageHeight: 1440),
      // 长焦
      const PinholeIntrinsics(
          fx: 2400, fy: 2400, cx: 640, cy: 360,
          imageWidth: 1280, imageHeight: 720),
      // 广角
      const PinholeIntrinsics(
          fx: 180, fy: 180, cx: 320, cy: 240,
          imageWidth: 640, imageHeight: 480),
    ];

/// 我们这条链的 "project":眼空间点 → NDC。
/// 相机看 **−z**(GL/OpenXR 约定),所以 z<0 才在前方。
/// 返回 null = 在相机后面或退化,对应 Basalt 的 `success == false`。
List<double>? _project(List<double> proj, List<double> eye) {
  double m(int r, int c) => proj[c * 4 + r];
  final double w = m(3, 0) * eye[0] +
      m(3, 1) * eye[1] +
      m(3, 2) * eye[2] +
      m(3, 3);
  if (w <= 1e-12) return null; // 在相机后面/在平面上
  final double x = m(0, 0) * eye[0] + m(0, 2) * eye[2];
  final double y = m(1, 1) * eye[1] + m(1, 2) * eye[2];
  return <double>[x / w, y / w];
}

/// "unproject":NDC → 眼空间**单位射线**。
///
/// 由 glFrustum 的闭式反解得到(不是数值求逆):
///   ndc.x = 2n/(r−l)·(x/−z) − (r+l)/(r−l)
/// ⇒ x/−z = (ndc.x + (r+l)/(r−l))·(r−l)/(2n),y 同理。
List<double> _unproject(FrustumBounds f, List<double> ndc) {
  final double rl = f.right - f.left;
  final double tb = f.top - f.bottom;
  final double xOverNegZ = (ndc[0] + (f.right + f.left) / rl) * rl / (2 * f.near);
  final double yOverNegZ = (ndc[1] + (f.top + f.bottom) / tb) * tb / (2 * f.near);
  final List<double> d = <double>[xOverNegZ, yOverNegZ, -1.0];
  final double n = math.sqrt(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]);
  return <double>[d[0] / n, d[1] / n, d[2] / n];
}

List<double> _normalize(List<double> v) {
  final double n = math.sqrt(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
  return <double>[v[0] / n, v[1] / n, v[2] / n];
}

void main() {
  group('复刻 Basalt testProjectUnproject:投影往返', () {
    test('网格穷举,往返必须回到同一条归一化射线', () {
      int tested = 0, skipped = 0;
      double worst = 0;
      for (final PinholeIntrinsics cam in _getTestProjections()) {
        final FrustumBounds? f = CameraProjection.frustum(
          cam,
          near: 0.01,
          far: 100.0,
          convention: PrincipalPointConvention.pixelCenter,
        );
        expect(f, isNotNull, reason: '$cam 应当能算出视锥');
        final List<double> proj = CameraProjection.glProjectionColumnMajor(f!);

        // 复刻 Basalt 的三重网格。它的相机看 +z 用 z∈[0,5];
        // 我们看 −z,所以取 z∈[−5,0]。
        for (int x = -10; x <= 10; x++) {
          for (int y = -10; y <= 10; y++) {
            for (int z = -5; z <= 0; z++) {
              final List<double> p =
                  <double>[x.toDouble(), y.toDouble(), z.toDouble()];
              final List<double>? ndc =
                  _project(proj, <double>[p[0], p[1], p[2], 1.0]);
              if (ndc == null) {
                skipped++;
                continue; // 对应 Basalt 的 success == false
              }
              final List<double> back = _unproject(f, ndc);
              final List<double> want = _normalize(p);
              for (int i = 0; i < 3; i++) {
                final double e = (back[i] - want[i]).abs();
                if (e > worst) worst = e;
                expect(e, lessThan(kEpsilonSqrt),
                    reason: 'cam=$cam p=$p 分量$i: '
                        '往返=${back[i]} 期望=${want[i]}');
              }
              tested++;
            }
          }
        }
      }
      // 阳性对照:必须真的测到了东西,别"零个点全通过"。
      expect(tested, greaterThan(5000),
          reason: '实际参与往返的点太少($tested),这组网格没覆盖到');
      // ignore: avoid_print
      print('往返: $tested 点通过,$skipped 点在相机后被跳过,'
          '最差分量误差 ${worst.toStringAsExponential(2)} '
          '(容差 ${kEpsilonSqrt.toStringAsExponential(2)})');
    });

    test('🔴 阴性对照:投影矩阵里动一个元素,往返必须爆掉', () {
      final PinholeIntrinsics cam = _getTestProjections().first;
      final FrustumBounds f = CameraProjection.frustum(cam,
          near: 0.01, far: 100.0,
          convention: PrincipalPointConvention.pixelCenter)!;
      final List<double> proj =
          List<double>.from(CameraProjection.glProjectionColumnMajor(f));
      proj[0] *= 1.01; // 焦距动 1%

      int blown = 0, total = 0;
      for (int x = -10; x <= 10; x += 3) {
        for (int y = -10; y <= 10; y += 3) {
          for (int z = -5; z <= -1; z++) {
            final List<double> p =
                <double>[x.toDouble(), y.toDouble(), z.toDouble()];
            final List<double>? ndc =
                _project(proj, <double>[p[0], p[1], p[2], 1.0]);
            if (ndc == null) continue;
            final List<double> back = _unproject(f, ndc);
            final List<double> want = _normalize(p);
            total++;
            final double e = math.max(math.max((back[0] - want[0]).abs(),
                (back[1] - want[1]).abs()), (back[2] - want[2]).abs());
            if (e > kEpsilonSqrt) blown++;
          }
        }
      }
      expect(total, greaterThan(20));
      // 若绝大多数点都还"通过",说明这把尺子分辨不出 1% 的焦距错 —— 平凡。
      expect(blown / total, greaterThan(0.9),
          reason: '注入 1% 焦距错之后只有 $blown/$total 个点超标 ⇒ 判据太松');
    });
  });

  group('复刻同一形状:位姿矩阵的互逆性', () {
    test('网格穷举:viewMatrix 必须是 modelMatrix 的逆', () {
      int tested = 0;
      double worst = 0;
      // 用规则网格生成四元数与平移,而不是手挑几组。
      for (int a = 0; a < 8; a++) {
        final double ang = a * math.pi / 8;
        for (final List<double> axis in <List<double>>[
          <double>[1, 0, 0],
          <double>[0, 1, 0],
          <double>[0, 0, 1],
          <double>[0.577, 0.577, 0.577],
        ]) {
          final double s = math.sin(ang / 2);
          final PoseQuaternion q = PoseQuaternion(
              axis[0] * s, axis[1] * s, axis[2] * s, math.cos(ang / 2));
          for (int t = -2; t <= 2; t++) {
            final TrackedPose pose = TrackedPose.tracked(
              orientation: q,
              position: PosePosition(t * 0.5, t * -0.3, t * 0.7),
              timestampSeconds: 0,
            );
            final List<double> m =
                WorldToRenderer.modelMatrixColumnMajor(pose)!;
            final List<double> v =
                WorldToRenderer.viewMatrixColumnMajor(pose)!;
            final List<double> prod =
                WorldToRenderer.multiplyColumnMajor(v, m);
            for (int c = 0; c < 4; c++) {
              for (int r = 0; r < 4; r++) {
                final double want = (r == c) ? 1.0 : 0.0;
                final double e = (prod[c * 4 + r] - want).abs();
                if (e > worst) worst = e;
                expect(e, lessThan(kEpsilonSqrt),
                    reason: 'view·model 的 ($r,$c) = ${prod[c * 4 + r]}');
              }
            }
            tested++;
          }
        }
      }
      expect(tested, greaterThan(100));
      // ignore: avoid_print
      print('互逆: $tested 组位姿通过,最差元素误差 '
          '${worst.toStringAsExponential(2)}');
    });

    test('displayRoll 必须是真旋转(正交 + det=+1),且 θ 与 −θ 互逆', () {
      for (final int deg in <int>[0, 90, 180, 270]) {
        final List<double> r = WorldToRenderer.displayRollColumnMajor(deg);
        final List<double> back =
            WorldToRenderer.displayRollColumnMajor((360 - deg) % 360);
        final List<double> prod = WorldToRenderer.multiplyColumnMajor(r, back);
        for (int c = 0; c < 4; c++) {
          for (int rr = 0; rr < 4; rr++) {
            expect((prod[c * 4 + rr] - ((rr == c) ? 1.0 : 0.0)).abs(),
                lessThan(kEpsilonSqrt),
                reason: '$deg° 与其逆相乘不是单位阵');
          }
        }
        // det 必须是 +1(真旋转,不是镜像)
        double at(int rr, int cc) => r[cc * 4 + rr];
        final double det = at(0, 0) *
                (at(1, 1) * at(2, 2) - at(1, 2) * at(2, 1)) -
            at(0, 1) * (at(1, 0) * at(2, 2) - at(1, 2) * at(2, 0)) +
            at(0, 2) * (at(1, 0) * at(2, 1) - at(1, 1) * at(2, 0));
        expect((det - 1.0).abs(), lessThan(kEpsilonSqrt),
            reason: '$deg° 的 det = $det,应为 +1');
      }
    });
  });
}
