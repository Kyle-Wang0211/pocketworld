// 复现「num_reliable_lms 塌掉」。
//
// 未命名(12) 实测(build 152,ticks_map=643 真的接上了):
//   map_reliable_lms_ref_p50 = 389     参考帧名下、obs>=3 的路标
//   map_tracked_lms_p50      = 64      当前视角可观测(无门槛)
//   map_reliable_lms_p50     = 9       当前视角可观测且 obs>=3
// ⇒ 比值 9/389 = 0.023,把上游三条全钉死在一侧:view_changed 恒真、
//   almost_all 恒假、not_enough_lms 恒真 —— 冗余刹车等于没有。
//
// 相隔约 1.3 秒、位移约 0.16 m 的两个视角不该差 43 倍。这个文件搭一个
// **形状与真机同量级**的地图,把 MapKeyframeEvidenceSource 原样跑一遍:
// 若它给出接近参考的数,说明模块没错、塌陷来自真机数据的形状;
// 若它当场塌,就是我的代码有 bug,可以在这里二分。
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/map_frame_alignment.dart';
import 'package:pocketworld_flutter/official_capture/map_keyframe_evidence.dart';

/// 绕 y 轴的小角度朝向 + 相机中心 → CamFromWorld。
({List<double> quat, List<double> t}) _camAt(double x, double yawRad) {
  // R_wc = Ry(yaw);R_cw = R_wc^T = Ry(-yaw)
  final c = math.cos(-yawRad / 2), s = math.sin(-yawRad / 2);
  final q = <double>[c, 0, s, 0]; // wxyz
  final r = rotationFromQuatWxyz(q[0], q[1], q[2], q[3]);
  final centre = <double>[x, 0, 0];
  final t = <double>[
    -(r[0] * centre[0] + r[1] * centre[1] + r[2] * centre[2]),
    -(r[3] * centre[0] + r[4] * centre[1] + r[5] * centre[2]),
    -(r[6] * centre[0] + r[7] * centre[1] + r[8] * centre[2]),
  ];
  return (quat: q, t: t);
}

void main() {
  const nFrames = 6;
  const nPoints = 200;
  // 一面 z=1.0 的墙,±0.4 m;相机沿 x 轴一字排开,都朝 +z 看。
  final xyz = Float32List(nPoints * 3);
  final rnd = math.Random(7);
  for (var i = 0; i < nPoints; i++) {
    xyz[i * 3] = (rnd.nextDouble() - 0.5) * 0.8;
    xyz[i * 3 + 1] = (rnd.nextDouble() - 0.5) * 0.6;
    xyz[i * 3 + 2] = 1.0 + (rnd.nextDouble() - 0.5) * 0.1;
  }
  // 每个点被全部 6 帧观测 ⇒ obs=6,门槛 3 时全部 reliable。
  final offsets = Int32List(nPoints + 1);
  final frames = <int>[];
  for (var i = 0; i < nPoints; i++) {
    offsets[i] = frames.length;
    for (var f = 0; f < nFrames; f++) {
      frames.add(f);
    }
  }
  offsets[nPoints] = frames.length;

  final poses = <double>[];
  for (var f = 0; f < nFrames; f++) {
    final cam = _camAt(-0.25 + 0.1 * f, 0);
    poses.addAll(<double>[
      f.toDouble(), 1,
      cam.quat[0], cam.quat[1], cam.quat[2], cam.quat[3],
      cam.t[0], cam.t[1], cam.t[2],
    ]);
  }

  MapKeyframeEvidenceSource src() {
    final s = MapKeyframeEvidenceSource();
    s.updateFromSnapshot(
      xyz: xyz,
      obsOffsets: offsets,
      obsFrameIds: Int32List.fromList(frames),
      posesPacked: Float64List.fromList(poses),
    );
    return s;
  }

  // 参考 = 最后一帧(与现役接线一致:最后一张喂进重建的照片)。
  const refFrameId = nFrames - 1;
  final refCam = _camAt(-0.25 + 0.1 * refFrameId, 0);
  final arkitRef = CamFromWorldPose(
    rotCw: rotationFromQuatWxyz(
      refCam.quat[0], refCam.quat[1], refCam.quat[2], refCam.quat[3],
    ),
    transCw: refCam.t,
  );

  StellaMapEvidence run(double dx) {
    final cur = _camAt(-0.25 + 0.1 * refFrameId + dx, 0);
    return src().evidenceFor(
      refFrameId: refFrameId,
      arkitRefPose: arkitRef,
      arkitCurrentPose: CamFromWorldPose(
        rotCw: rotationFromQuatWxyz(
          cur.quat[0], cur.quat[1], cur.quat[2], cur.quat[3],
        ),
        transCw: cur.t,
      ),
      // 真机口径:照片的内参与画幅(4032×3024,fx≈2854.65,cx≈2023.4)
      fx: 2854.65, fy: 2854.65, cx: 2023.4, cy: 1511.4,
      imageWidth: 4032, imageHeight: 3024,
    )!;
  }

  test('阳性对照:参考帧名下的可靠路标数 = 全部 200', () {
    final e = run(0);
    expect(e.minNumObsThr, 3, reason: '6 帧已注册 ⇒ 上游取 3');
    expect(e.numReliableLmsRef, nPoints);
  });

  test('🔴 站在参考帧原地:可观测数必须接近参考数,不能塌', () {
    final e = run(0);
    expect(e.localLandmarkCount, nPoints, reason: '局部地图应含全部点');
    expect(
      e.numTrackedLms,
      greaterThan((nPoints * 0.8).round()),
      reason: '原地不动却看不见自己拍过的东西 ⇒ 可观测那一段有 bug。'
          '实测 64/389,这条就是用来把它逼出来的',
    );
    expect(e.numReliableLms, greaterThan((nPoints * 0.8).round()));
  });

  test('🔴 侧移 0.16 m(真机第3张起的中位步长):仍应大体看得见', () {
    final e = run(0.16);
    expect(e.numTrackedLms, greaterThan((nPoints * 0.5).round()));
  });

  test('阴性对照:走到墙背后,必须看不见', () {
    final cur = _camAt(0, 0);
    // 相机中心挪到 z = 3(墙在 z≈1,背面),仍朝 +z。
    final r = rotationFromQuatWxyz(1, 0, 0, 0);
    const centre = <double>[0, 0, 3];
    final t = <double>[
      -(r[0] * centre[0] + r[1] * centre[1] + r[2] * centre[2]),
      -(r[3] * centre[0] + r[4] * centre[1] + r[5] * centre[2]),
      -(r[6] * centre[0] + r[7] * centre[1] + r[8] * centre[2]),
    ];
    final e = src().evidenceFor(
      refFrameId: refFrameId,
      arkitRefPose: arkitRef,
      arkitCurrentPose: CamFromWorldPose(rotCw: r, transCw: t),
      fx: 2854.65, fy: 2854.65, cx: 2023.4, cy: 1511.4,
      imageWidth: 4032, imageHeight: 3024,
    )!;
    expect(e.numTrackedLms, 0, reason: '点都在身后,z<=0 一条就该全挡掉');
    expect(cur.quat.length, 4);
  });
}
