// [GRAV-CONSIST 2026-07-28] 重力对齐"整模型一致变换"的契约。
//
// 背景:旧实现只旋点、posesPacked 留 raw-COLMAP,持久化产物是"混合帧工件
// 对"(PLY 对齐系 / meta 位姿原始系,且 R_w 无记录)。调研裁决(COLMAP
// Reconstruction::Transform / AliceVision applyTransform / nerfstudio
// dataparser_transforms.json;行业查无"只转点不转位姿"先例):点与位姿吃
// 同一个 R_w,R_w 落盘,raw 位姿以显式字段保留逐位真值。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/gravity_align.dart';

void main() {
  scaleAnchorTests();
  // 不变量:对任意点 X 与任意 CamFromWorld C,变换后相机坐标不变:
  //   C'(R·X) == C(X)   (C' = C∘R⁻¹,纯旋转、平移不变)
  // 相机坐标是重投影的唯一输入,所以这条恒等式成立 ⇔ 整模型变换零失真。
  test('C\'(R·X) == C(X) for random poses/points (round-trip invariant)', () {
    final rng = math.Random(42);
    List<double> randQuat() {
      // Uniform-ish random unit quaternion.
      final u1 = rng.nextDouble(), u2 = rng.nextDouble(), u3 = rng.nextDouble();
      final a = math.sqrt(1 - u1), b = math.sqrt(u1);
      return [
        a * math.sin(2 * math.pi * u2),
        a * math.cos(2 * math.pi * u2),
        b * math.sin(2 * math.pi * u3),
        b * math.cos(2 * math.pi * u3),
      ];
    }

    List<double> rotate(List<double> q, List<double> v) {
      final w = q[0], x = q[1], y = q[2], z = q[3];
      final r = [
        [1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)],
        [2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)],
        [2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)],
      ];
      return [
        r[0][0] * v[0] + r[0][1] * v[1] + r[0][2] * v[2],
        r[1][0] * v[0] + r[1][1] * v[1] + r[1][2] * v[2],
        r[2][0] * v[0] + r[2][1] * v[1] + r[2][2] * v[2],
      ];
    }

    for (var trial = 0; trial < 50; trial++) {
      final qAlign = randQuat();
      final qCam = randQuat();
      final t = [rng.nextDouble(), rng.nextDouble(), rng.nextDouble()];
      final pt = [
        rng.nextDouble() * 4 - 2,
        rng.nextDouble() * 4 - 2,
        rng.nextDouble() * 4 - 2,
      ];

      final poses = Float64List.fromList([
        0, 1, qCam[0], qCam[1], qCam[2], qCam[3], t[0], t[1], t[2], //
      ]);
      final aligned = gravityAlignedPosesPacked(poses, qAlign);
      final xyz = Float32List.fromList([
        pt[0].toDouble(),
        pt[1].toDouble(),
        pt[2].toDouble(),
      ]);
      final rotated = rotatePointsByQuatWxyz(xyz, qAlign);

      // cam coords before: R_cam·X + t
      final before = rotate(qCam, pt);
      // cam coords after: R'_cam·X' + t'  (t' == t by construction)
      final qCamNew = [aligned[2], aligned[3], aligned[4], aligned[5]];
      final after = rotate(qCamNew, [
        rotated[0].toDouble(),
        rotated[1].toDouble(),
        rotated[2].toDouble(),
      ]);
      for (var k = 0; k < 3; k++) {
        expect(
          after[k] + t[k],
          closeTo(before[k] + t[k], 1e-5),
          reason: 'trial $trial axis $k',
        );
      }
      // 平移分量必须原样(纯旋转世界变换不动相机系平移)。
      expect(aligned[6], t[0]);
      expect(aligned[7], t[1]);
      expect(aligned[8], t[2]);
    }
  });

  test('unregistered / all-zero synthetic quats pass through verbatim', () {
    final poses = Float64List.fromList([
      5, 0, 0.1, 0.2, 0.3, 0.4, 1, 2, 3, // unregistered → verbatim
      6, 1, 0, 0, 0, 0, 0, 0, 0, // synthetic all-zero quat (connectivity)
    ]);
    final aligned = gravityAlignedPosesPacked(poses, [1.0, 0.0, 0.0, 0.0]);
    expect(aligned.sublist(0, 9), poses.sublist(0, 9));
    // 全 0 四元数 ⊗ 任意单位四元数仍全 0(契约同 SfmLiveConnectivity)。
    expect(aligned.sublist(11, 15), [0.0, 0.0, 0.0, 0.0]);
  });

  test('persist writes the aligned/raw/quat triple (schema v2)', () {
    final src = File('lib/official_capture/sparse_ply.dart').readAsStringSync();
    expect(src, contains("'schema': 'pw_sfm_sparse_meta_v2'"));
    expect(src, contains("'gravity_align_quat_wxyz'"));
    expect(src, contains("'poses_raw_colmap'"));

    final live = File(
      'lib/official_capture/sfm_live_recon.dart',
    ).readAsStringSync();
    // 整模型一致:点与位姿同一个 R_w,raw 以显式字段保留。
    expect(live, contains('gravityAlignedPosesPacked(snap.posesPacked, q)'));
    expect(live, contains('posesPackedRawColmap: snap.posesPacked'));
    expect(live, contains('gravityAlignQuatWxyz: q'));
  });
}

// ═══ [SCALE-ANCHOR 2026-07-28] 米制尺度锚定的契约 ═══
void scaleAnchorTests() {
  test('similarity transform preserves pinhole projection exactly', () {
    // x' = s·x, t' = s·t ⇒ x_cam' = s·x_cam ⇒ u = fx·x/z 不变(s 消去)。
    final rng = math.Random(7);
    for (var trial = 0; trial < 20; trial++) {
      final s = 0.9 + rng.nextDouble() * 0.2;
      final q = [0.9, 0.1, 0.3, math.sqrt(1 - 0.81 - 0.01 - 0.09)];
      final t = [rng.nextDouble(), rng.nextDouble(), rng.nextDouble() + 2];
      final pt = [rng.nextDouble(), rng.nextDouble(), rng.nextDouble()];
      final poses = Float64List.fromList([
        0, 1, q[0], q[1], q[2], q[3], t[0], t[1], t[2], //
      ]);
      final xyz = Float32List.fromList(pt.map((v) => v).toList());
      final sp = scaleAnchoredPosesPacked(poses, s);
      final sx = scaleAnchoredPoints(xyz, s);
      // cam coords: R·X + t vs R·(sX) + s·t = s·(R·X + t) → 比值逐轴 == s
      // 且投影 x/z 完全一致。用数值验证 x/z:
      List<double> cam(List<double> qq, List<double> X, List<double> tt) {
        final w = qq[0], x = qq[1], y = qq[2], z = qq[3];
        return [
          (1 - 2 * (y * y + z * z)) * X[0] +
              2 * (x * y - z * w) * X[1] +
              2 * (x * z + y * w) * X[2] +
              tt[0],
          2 * (x * y + z * w) * X[0] +
              (1 - 2 * (x * x + z * z)) * X[1] +
              2 * (y * z - x * w) * X[2] +
              tt[1],
          2 * (x * z - y * w) * X[0] +
              2 * (y * z + x * w) * X[1] +
              (1 - 2 * (x * x + y * y)) * X[2] +
              tt[2],
        ];
      }

      final c0 = cam(q, pt, t);
      final c1 = cam(q, [sx[0], sx[1], sx[2]], [sp[6], sp[7], sp[8]]);
      expect(c1[0] / c1[2], closeTo(c0[0] / c0[2], 1e-6));
      expect(c1[1] / c1[2], closeTo(c0[1] / c0[2], 1e-6));
    }
  });

  test('scaleAnchorFactor recovers a synthetic scale offset', () {
    // 构造 20 帧圆弧轨迹,ARKit 中心 = 1.043 × BA 中心(平移无关:两边
    // 各自减质心)——期望 s ≈ 1.043。
    const sTrue = 1.043;
    final poses = <double>[];
    final arkC = <int, List<double>>{};
    for (var i = 0; i < 20; i++) {
      final a = i * 0.3;
      final c = [math.cos(a) * 2, 0.1 * i, math.sin(a) * 2];
      // CamFromWorld with R=I: t = -c
      poses.addAll([i.toDouble(), 1, 1, 0, 0, 0, -c[0], -c[1], -c[2]]);
      arkC[i] = [c[0] * sTrue + 5, c[1] * sTrue - 3, c[2] * sTrue]; // 平移无关
    }
    final s = scaleAnchorFactor(
      posesPacked: Float64List.fromList(poses),
      arkitCenterWorldOf: (id) => arkC[id],
    );
    expect(s, isNotNull);
    expect(s!, closeTo(sTrue, 1e-6));
  });

  test('fail-open: too few frames / crazy scale / missing centers → null', () {
    final two = Float64List.fromList([
      0, 1, 1, 0, 0, 0, 1, 0, 0, //
      1, 1, 1, 0, 0, 0, 0, 1, 0, //
    ]);
    expect(
      scaleAnchorFactor(
        posesPacked: two,
        arkitCenterWorldOf: (id) => [1, 2, 3],
      ),
      isNull,
    );
    // >15% 偏差拒绝(ARKit 可疑)。
    final poses = <double>[];
    final arkC = <int, List<double>>{};
    for (var i = 0; i < 10; i++) {
      final c = [i * 1.0, 0.0, math.sin(i * 1.0)];
      poses.addAll([i.toDouble(), 1, 1, 0, 0, 0, -c[0], -c[1], -c[2]]);
      arkC[i] = [c[0] * 1.3, c[1] * 1.3, c[2] * 1.3];
    }
    expect(
      scaleAnchorFactor(
        posesPacked: Float64List.fromList(poses),
        arkitCenterWorldOf: (id) => arkC[id],
      ),
      isNull,
    );
  });

  test('Dart never rescales the delivered model (arm retired → core DEVICE-ALIGN-V1)', () {
    final ply = File('lib/official_capture/sparse_ply.dart').readAsStringSync();
    expect(ply, contains("'scale_anchor_factor': snapshot.scaleAnchorFactor"));
    final live = File(
      'lib/official_capture/sfm_live_recon.dart',
    ).readAsStringSync();
    // 双重缩放防线:Dart 侧不得再有尺度开关或缩放调用。
    expect(live, isNot(contains('OFFICIAL_AETHER_SCALE_ANCHOR')));
    expect(live, isNot(contains('scaleAnchoredPoints(')));
    expect(live, isNot(contains('scaleAnchoredPosesPacked(')));
    final plugin = File(
      'ios/Runner/OfficialAetherARKitPlugin.swift',
    ).readAsStringSync();
    expect(plugin, isNot(contains('setenv("OFFICIAL_AETHER_SCALE_ANCHOR"')));
    // raw 真值不含缩放:posesPackedRawColmap 存的是缩放前的 snap.posesPacked。
    expect(live, contains('posesPackedRawColmap: snap.posesPacked'));
  });
}
