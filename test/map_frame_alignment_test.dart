// 坐标变换的判据:恒等、往返、以及拿**真机两套位姿**做的端到端对拍。
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/map_frame_alignment.dart';

CamFromWorldPose _pose(List<double> quatWxyz, List<double> tCw) =>
    CamFromWorldPose(
      rotCw: rotationFromQuatWxyz(
        quatWxyz[0],
        quatWxyz[1],
        quatWxyz[2],
        quatWxyz[3],
      ),
      transCw: tCw,
    );

double _centreDist(CamFromWorldPose a, CamFromWorldPose b) {
  final ca = a.cameraCentre, cb = b.cameraCentre;
  return math.sqrt(
    math.pow(ca[0] - cb[0], 2) +
        math.pow(ca[1] - cb[1], 2) +
        math.pow(ca[2] - cb[2], 2),
  );
}

double _rotDiffDeg(List<double> a, List<double> b) {
  // trace(AᵀB) = 1 + 2cosθ
  var tr = 0.0;
  for (var r = 0; r < 3; r++) {
    for (var c = 0; c < 3; c++) {
      tr += a[r * 3 + c] * b[r * 3 + c];
    }
  }
  final cos = ((tr - 1) / 2).clamp(-1.0, 1.0);
  return math.acos(cos) * 180 / math.pi;
}

void main() {
  test('当前帧 == 参考帧 时,结果就是参考帧的重建位姿(恒等)', () {
    final reconRef = _pose(<double>[0.7071, 0, 0.7071, 0], <double>[1, 2, 3]);
    final arkitRef = _pose(<double>[0.9239, 0.3827, 0, 0], <double>[-1, 0, 2]);
    final out = currentPoseInReconFrame(
      reconRef: reconRef,
      arkitRef: arkitRef,
      arkitCurrent: arkitRef,
    );
    expect(_centreDist(out, reconRef), lessThan(1e-9));
    expect(_rotDiffDeg(out.rotCw, reconRef.rotCw), lessThan(1e-6));
  });

  test('两系恒等时,输出就是 ARKit 当前位姿(不引入额外变换)', () {
    final same = _pose(<double>[1, 0, 0, 0], <double>[0, 0, 0]);
    final cur = _pose(<double>[0.8, 0.2, 0.1, 0.55], <double>[0.3, -0.2, 1.1]);
    final out = currentPoseInReconFrame(
      reconRef: same,
      arkitRef: same,
      arkitCurrent: cur,
    );
    expect(_centreDist(out, cur), lessThan(1e-9));
    expect(_rotDiffDeg(out.rotCw, cur.rotCw), lessThan(1e-6));
  });

  test('相对位移被完整搬过去:走多远,在 BA 系里也走多远', () {
    final reconRef = _pose(<double>[0.7071, 0, 0.7071, 0], <double>[1, 2, 3]);
    final arkitRef = _pose(<double>[0.9239, 0.3827, 0, 0], <double>[-1, 0, 2]);
    // 让 ARKit 当前帧相对参考帧平移一段(朝向不变)。
    final cArk = arkitRef.cameraCentre;
    const step = <double>[0.12, -0.05, 0.30];
    final cCur = <double>[
      cArk[0] + step[0],
      cArk[1] + step[1],
      cArk[2] + step[2],
    ];
    final tCur = <double>[
      -(arkitRef.rotCw[0] * cCur[0] +
          arkitRef.rotCw[1] * cCur[1] +
          arkitRef.rotCw[2] * cCur[2]),
      -(arkitRef.rotCw[3] * cCur[0] +
          arkitRef.rotCw[4] * cCur[1] +
          arkitRef.rotCw[5] * cCur[2]),
      -(arkitRef.rotCw[6] * cCur[0] +
          arkitRef.rotCw[7] * cCur[1] +
          arkitRef.rotCw[8] * cCur[2]),
    ];
    final arkitCur = CamFromWorldPose(
      rotCw: arkitRef.rotCw,
      transCw: tCur,
    );
    final out = currentPoseInReconFrame(
      reconRef: reconRef,
      arkitRef: arkitRef,
      arkitCurrent: arkitCur,
    );
    final moved = _centreDist(out, reconRef);
    final expected = math.sqrt(
      step[0] * step[0] + step[1] * step[1] + step[2] * step[2],
    );
    expect(moved, closeTo(expected, 1e-9));
  });

  group('🔴 端到端对拍:未命名(10) 的真机两套位姿', () {
    // 夹具 = 同一场的两套位姿,逐帧配对:
    //   重建位姿 = official_sfm_sparse_meta.json 的 poses(CamFromWorld)
    //   ARKit 位姿 = official_sfm_live.db.arkit_pose_v1 侧车(同约定)
    // 判据:拿**第 0 张**当参考(最坏情况 —— 参考离当前最远、累计漂移最大),
    // 只用 ARKit 的相对运动去预测其余 35 张在重建系里的位姿,与真值比。
    // 实测:中心误差 中位 7.2 mm / p90 9.9 / 最大 16.7;
    //       朝向误差 中位 0.55° / p90 0.92 / 最大 1.14。
    // 下面的界按实测留了余量;**现役接线里参考是最近一张照片(约 1.3 s 前)**,
    // 误差只会比这个最坏情况更小。
    test('以第 0 张为参考,预测其余 35 张', () {
      final fixture = File(
        'test/fixtures/frame_alignment_uncaptured10.json',
      );
      expect(fixture.existsSync(), isTrue, reason: '夹具必须在,否则这条判据是空的');
      final data =
          jsonDecode(fixture.readAsStringSync()) as Map<String, dynamic>;
      final frames = (data['frames'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(frames.length, 36);

      CamFromWorldPose poseOf(Map<String, dynamic> m) => _pose(
        (m['q'] as List<dynamic>).cast<num>().map((e) => e.toDouble()).toList(),
        (m['t'] as List<dynamic>).cast<num>().map((e) => e.toDouble()).toList(),
      );

      final reconRef = poseOf(frames[0]['recon'] as Map<String, dynamic>);
      final arkitRef = poseOf(frames[0]['arkit'] as Map<String, dynamic>);
      final centreErr = <double>[];
      final rotErr = <double>[];
      for (final f in frames.skip(1)) {
        final out = currentPoseInReconFrame(
          reconRef: reconRef,
          arkitRef: arkitRef,
          arkitCurrent: poseOf(f['arkit'] as Map<String, dynamic>),
        );
        final truth = poseOf(f['recon'] as Map<String, dynamic>);
        centreErr.add(_centreDist(out, truth));
        rotErr.add(_rotDiffDeg(out.rotCw, truth.rotCw));
      }
      centreErr.sort();
      rotErr.sort();
      final centreMedian = centreErr[centreErr.length ~/ 2];
      final rotMedian = rotErr[rotErr.length ~/ 2];
      expect(centreMedian, lessThan(0.010),
          reason: '实测 7.2 mm —— 超过 10 mm 说明变换写错了或两系关系变了');
      expect(centreErr.last, lessThan(0.025),
          reason: '实测最大 16.7 mm');
      expect(rotMedian, lessThan(1.0), reason: '实测 0.55 度');
      expect(rotErr.last, lessThan(2.0), reason: '实测最大 1.14 度');
    });

    test('阴性对照:把参考的 ARKit 朝向故意转 90 度,判据必须变红', () {
      final fixture = File(
        'test/fixtures/frame_alignment_uncaptured10.json',
      );
      final data =
          jsonDecode(fixture.readAsStringSync()) as Map<String, dynamic>;
      final frames = (data['frames'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      CamFromWorldPose poseOf(Map<String, dynamic> m) => _pose(
        (m['q'] as List<dynamic>).cast<num>().map((e) => e.toDouble()).toList(),
        (m['t'] as List<dynamic>).cast<num>().map((e) => e.toDouble()).toList(),
      );
      final reconRef = poseOf(frames[0]['recon'] as Map<String, dynamic>);
      final good = frames[0]['arkit'] as Map<String, dynamic>;
      // 绕 x 轴转 90 度后的参考朝向 —— 变换应当当场失真。
      final bad = _pose(<double>[0.7071, 0.7071, 0, 0],
          (good['t'] as List<dynamic>).cast<num>().map((e) => e.toDouble()).toList());
      final out = currentPoseInReconFrame(
        reconRef: reconRef,
        arkitRef: bad,
        arkitCurrent: poseOf(frames[10]['arkit'] as Map<String, dynamic>),
      );
      final truth = poseOf(frames[10]['recon'] as Map<String, dynamic>);
      expect(_rotDiffDeg(out.rotCw, truth.rotCw), greaterThan(10.0),
          reason: '参考朝向错了还能对上,说明这条判据根本没在测变换');
    });
  });
}
