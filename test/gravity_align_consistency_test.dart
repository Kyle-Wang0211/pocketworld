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
    final src = File(
      'lib/official_capture/sparse_ply.dart',
    ).readAsStringSync();
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
