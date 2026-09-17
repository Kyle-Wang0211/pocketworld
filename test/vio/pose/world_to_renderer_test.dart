// world_to_renderer_test.dart — 换轴的每一条性质都单独钉住。
//
// 这一层错了不会崩,只会让内容歪着,而且很像"精度不够"。所以断言全部针对
// 能手算出答案的构型,并且**包含上游那个错误映射的阴性对照**。

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/vio/pose/tracked_pose.dart';
import 'package:pocketworld_flutter/vio/pose/world_to_renderer.dart';

void main() {
  test('实测的「上」必须落在渲染器的 +y', () {
    // run-eb74a545 实测:世界系平均比力。
    final List<double> up = WorldToRenderer.convertVector(
      <double>[0.0325, -0.0134, 9.7441],
    );
    final int dom = <int>[0, 1, 2].reduce(
        (int a, int b) => up[a].abs() >= up[b].abs() ? a : b);
    expect(dom, 1, reason: '主导轴必须是 y,实得 $up');
    expect(up[1], greaterThan(0), reason: '必须是 +y,不是 −y');
  });

  test('🔴 阴性对照:上游的映射会把「上」送到 −z', () {
    // (x,y,z) -> (-y,-x,-z)
    final List<double> g = <double>[0.0325, -0.0134, 9.7441];
    final List<double> upstream = <double>[-g[1], -g[0], -g[2]];
    final int dom = <int>[0, 1, 2].reduce(
        (int a, int b) => upstream[a].abs() >= upstream[b].abs() ? a : b);
    expect(dom, 2, reason: '上游映射的主导轴应当是 z(这正是它的错)');
    expect(upstream[2], lessThan(0));
  });

  test('矩阵是真旋转:det=+1,正交', () {
    final List<List<double>> m = WorldToRenderer.zUpToYUp;
    final double det = m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
        m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
        m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
    expect(det, closeTo(1.0, 1e-12), reason: '不能是镜像');
    for (int i = 0; i < 3; i++) {
      for (int j = 0; j < 3; j++) {
        final double dot =
            m[i][0] * m[j][0] + m[i][1] * m[j][1] + m[i][2] * m[j][2];
        expect(dot, closeTo(i == j ? 1.0 : 0.0, 1e-12));
      }
    }
  });

  test('不引入偏航:x 轴原地不动', () {
    expect(WorldToRenderer.convertVector(<double>[1, 0, 0]),
        <double>[1, 0, 0]);
  });

  test('四元数与矩阵必须描述同一个旋转', () {
    // 对若干方向,q 作用的结果应与矩阵作用的结果一致。
    for (final List<double> v in <List<double>>[
      <double>[1, 0, 0],
      <double>[0, 1, 0],
      <double>[0, 0, 1],
      <double>[0.3, -0.7, 0.2],
    ]) {
      final List<double> byMatrix = WorldToRenderer.convertVector(v);
      final q = WorldToRenderer.zUpToYUpQuaternion;
      final double x = q.x, y = q.y, z = q.z, w = q.w;
      final List<double> byQuat = <double>[
        (1 - 2 * (y * y + z * z)) * v[0] +
            2 * (x * y - z * w) * v[1] +
            2 * (x * z + y * w) * v[2],
        2 * (x * y + z * w) * v[0] +
            (1 - 2 * (x * x + z * z)) * v[1] +
            2 * (y * z - x * w) * v[2],
        2 * (x * z - y * w) * v[0] +
            2 * (y * z + x * w) * v[1] +
            (1 - 2 * (x * x + y * y)) * v[2],
      ];
      for (int i = 0; i < 3; i++) {
        expect(byQuat[i], closeTo(byMatrix[i], 1e-12), reason: 'v=$v 分量 $i');
      }
    }
  });

  group('viewMatrix', () {
    // 🔴 恒等位姿的视图矩阵**不是**单位阵,这一点值得单独钉住。
    // 引擎世界系是 z-up:恒等位姿意味着相机轴与那个世界的轴重合。换到
    // y-up 的渲染器世界后,相机自然是转过的,所以 view 的旋转部 = Cᵀ。
    // 我第一版把它断言成单位阵 —— 那是我推错了,不是代码错了。
    test('单位位姿在原点 ⇒ 视图矩阵的旋转部是 Cᵀ,不是单位阵', () {
      final TrackedPose p = TrackedPose.tracked(
        orientation: PoseQuaternion.identity,
        position: PosePosition.origin,
        timestampSeconds: 0,
      );
      final List<double>? m = WorldToRenderer.viewMatrixColumnMajor(p);
      expect(m, isNotNull);
      // Cᵀ = [[1,0,0],[0,0,-1],[0,1,0]],列主序展开。
      const List<double> expected = <double>[
        1, 0, 0, 0, //
        0, 0, 1, 0, //
        0, -1, 0, 0, //
        0, 0, 0, 1, //
      ];
      for (int i = 0; i < 16; i++) {
        expect(m![i], closeTo(expected[i], 1e-12), reason: '第 $i 个元素');
      }
    });

    test('平移:相机在世界 +z(上)⇒ 视图矩阵把它拉回 −y', () {
      final TrackedPose p = TrackedPose.tracked(
        orientation: PoseQuaternion.identity,
        position: const PosePosition(0, 0, 2),
        timestampSeconds: 0,
      );
      final List<double> m = WorldToRenderer.viewMatrixColumnMajor(p)!;
      // 相机在世界 (0,0,2) ⇒ 渲染器系 (0,2,0);view 平移 = −Cᵀ·(0,2,0)
      // = (0,0,−2)。逐步手推,不是从结果反推的。
      expect(m[12], closeTo(0, 1e-12));
      expect(m[13], closeTo(0, 1e-12));
      expect(m[14], closeTo(-2, 1e-12));
      expect(m[15], 1);
    });

    test('视图矩阵必须真的把世界点变换到相机系', () {
      final TrackedPose p = TrackedPose.tracked(
        orientation: PoseQuaternion.identity,
        position: const PosePosition(1, 2, 3),
        timestampSeconds: 0,
      );
      final List<double> m = WorldToRenderer.viewMatrixColumnMajor(p)!;
      // 相机所在的那个世界点,过视图矩阵之后必须是原点。
      final List<double> camInRenderer =
          WorldToRenderer.convertVector(<double>[1, 2, 3]);
      final List<double> out = <double>[
        m[0] * camInRenderer[0] + m[4] * camInRenderer[1] + m[8] * camInRenderer[2] + m[12],
        m[1] * camInRenderer[0] + m[5] * camInRenderer[1] + m[9] * camInRenderer[2] + m[13],
        m[2] * camInRenderer[0] + m[6] * camInRenderer[1] + m[10] * camInRenderer[2] + m[14],
      ];
      for (int i = 0; i < 3; i++) {
        expect(out[i], closeTo(0, 1e-12), reason: '相机自身应变到原点,实得 $out');
      }
    });

    test('🔴 3DOF 返回 null,不返回平移为零的视图矩阵', () {
      final TrackedPose p = TrackedPose.orientationOnly(
        orientation: PoseQuaternion.identity,
        timestampSeconds: 0,
      );
      expect(WorldToRenderer.viewMatrixColumnMajor(p), isNull,
          reason: '只有朝向时交出零平移 = 编造"相机在原点"');
    });

    test('🔴 什么都没有时返回 null', () {
      expect(
        WorldToRenderer.viewMatrixColumnMajor(
            TrackedPose.none(timestampSeconds: 0)),
        isNull,
      );
    });

    test('任意旋转下,相机自身仍变换到原点', () {
      final math.Random rnd = math.Random(7);
      for (int k = 0; k < 20; k++) {
        final PoseQuaternion q = PoseQuaternion(
          rnd.nextDouble() * 2 - 1,
          rnd.nextDouble() * 2 - 1,
          rnd.nextDouble() * 2 - 1,
          rnd.nextDouble() * 2 - 1,
        ).normalized();
        final PosePosition t = PosePosition(
          rnd.nextDouble() * 10 - 5,
          rnd.nextDouble() * 10 - 5,
          rnd.nextDouble() * 10 - 5,
        );
        final List<double> m = WorldToRenderer.viewMatrixColumnMajor(
          TrackedPose.tracked(
              orientation: q, position: t, timestampSeconds: 0),
        )!;
        final List<double> c =
            WorldToRenderer.convertVector(<double>[t.x, t.y, t.z]);
        final List<double> out = <double>[
          m[0] * c[0] + m[4] * c[1] + m[8] * c[2] + m[12],
          m[1] * c[0] + m[5] * c[1] + m[9] * c[2] + m[13],
          m[2] * c[0] + m[6] * c[1] + m[10] * c[2] + m[14],
        ];
        for (int i = 0; i < 3; i++) {
          expect(out[i].abs(), lessThan(1e-9), reason: 'k=$k 实得 $out');
        }
      }
    });
  });
}
