// 组合器的判据。它只负责"按上游定义取三个数",不做任何快门判断。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/map_frame_alignment.dart';
import 'package:pocketworld_flutter/official_capture/map_keyframe_evidence.dart';

/// 相机在原点朝 +z,单位朝向。
CamFromWorldPose _atOrigin() => CamFromWorldPose(
  rotCw: rotationFromQuatWxyz(1, 0, 0, 0),
  transCw: const <double>[0, 0, 0],
);

/// 一张 5×5 的小地图:25 个点铺在 z = 2 的平面上,全部被帧 0/1/2 观测。
MapKeyframeEvidenceSource _sourceWithGrid({int observers = 3}) {
  final pts = <double>[];
  final obsOffsets = <int>[];
  final obsFrames = <int>[];
  for (var i = 0; i < 25; i++) {
    final gx = (i % 5 - 2) * 0.1;
    final gy = (i ~/ 5 - 2) * 0.1;
    obsOffsets.add(obsFrames.length);
    pts.addAll(<double>[gx, gy, 2.0]);
    for (var f = 0; f < observers; f++) {
      obsFrames.add(f);
    }
  }
  obsOffsets.add(obsFrames.length);

  // 三台相机都在原点附近朝 +z(法向 ≈ -z 方向的反向,ray_cos 通过)。
  final poses = <double>[];
  for (var f = 0; f < observers; f++) {
    poses.addAll(<double>[f.toDouble(), 1, 1, 0, 0, 0, 0, 0, 0]);
  }

  final src = MapKeyframeEvidenceSource();
  src.updateFromSnapshot(
    xyz: Float32List.fromList(pts),
    obsOffsets: Int32List.fromList(obsOffsets),
    obsFrameIds: Int32List.fromList(obsFrames),
    posesPacked: Float64List.fromList(poses),
  );
  return src;
}

StellaMapEvidence? _query(MapKeyframeEvidenceSource src, {int refFrameId = 0}) =>
    src.evidenceFor(
      refFrameId: refFrameId,
      arkitRefPose: _atOrigin(),
      arkitCurrentPose: _atOrigin(),
      fx: 100,
      fy: 100,
      cx: 64,
      cy: 64,
      imageWidth: 128,
      imageHeight: 128,
    );

void main() {
  test('没有快照时返回 null(fail closed,不用半套数据凑比值)', () {
    final src = MapKeyframeEvidenceSource();
    expect(src.hasSnapshot, isFalse);
    expect(_query(src), isNull);
  });

  test('参考帧不在重建里 => null', () {
    final src = _sourceWithGrid();
    expect(_query(src, refFrameId: 99), isNull);
  });

  test('内参非法 => null', () {
    final src = _sourceWithGrid();
    expect(
      src.evidenceFor(
        refFrameId: 0,
        arkitRefPose: _atOrigin(),
        arkitCurrentPose: _atOrigin(),
        fx: 0,
        fy: 100,
        cx: 64,
        cy: 64,
        imageWidth: 128,
        imageHeight: 128,
      ),
      isNull,
    );
  });

  test('三个量都取到,且 min_num_obs_thr 随已注册帧数切换', () {
    final three = _query(_sourceWithGrid(observers: 3))!;
    expect(three.minNumObsThr, 3, reason: '3 帧已注册 => 上游取 3');
    expect(three.numReliableLmsRef, 25, reason: '参考帧名下 25 个点,每个 3 次观测');
    expect(three.numTrackedLms, greaterThan(0));
    expect(three.numReliableLms, greaterThan(0));

    final two = _query(_sourceWithGrid(observers: 2))!;
    expect(two.minNumObsThr, 2, reason: '2 帧已注册 => 上游取 2');
  });

  test('🔴 跟踪成功门接在结果上(tracking_module.cc:148)', () {
    final e = _query(_sourceWithGrid())!;
    expect(e.numTrackedLms, 25);
    expect(e.trackingSucceeded, isTrue, reason: '25 >= 20');

    // 相机转身背对地图 => 一个也看不见 => 门关上。
    final src = _sourceWithGrid();
    final away = src.evidenceFor(
      refFrameId: 0,
      arkitRefPose: _atOrigin(),
      arkitCurrentPose: CamFromWorldPose(
        rotCw: rotationFromQuatWxyz(0, 0, 1, 0), // 绕 y 轴 180 度
        transCw: const <double>[0, 0, 0],
      ),
      fx: 100,
      fy: 100,
      cx: 64,
      cy: 64,
      imageWidth: 128,
      imageHeight: 128,
    )!;
    expect(away.numTrackedLms, 0);
    expect(away.trackingSucceeded, isFalse, reason: '看不见 => 判据不该参与');
  });

  test('局部地图确实参与了(收窄后的候选数被报出来)', () {
    final e = _query(_sourceWithGrid())!;
    expect(e.localKeyframeCount, greaterThan(0));
    expect(e.localLandmarkCount, 25);
  });

  test('reset 之后回到无快照状态', () {
    final src = _sourceWithGrid();
    expect(_query(src), isNotNull);
    src.reset();
    expect(src.hasSnapshot, isFalse);
    expect(_query(src), isNull);
  });

  test('解耦纪律:组合器不许 import governor / 控制器 / Flutter', () {
    final src = File(
      'lib/official_capture/map_keyframe_evidence.dart',
    ).readAsStringSync();
    final imports = src
        .split('\n')
        .where((l) => l.trimLeft().startsWith('import '))
        .map((l) => l.trim())
        .toList();
    expect(imports, <String>[
      "import 'dart:typed_data';",
      "import 'map_frame_alignment.dart';",
      "import 'map_landmark_counts.dart';",
      "import 'map_landmark_observability.dart';",
      "import 'map_local_map.dart';",
    ], reason: '组合器只许组合那四个纯模块 —— 多一条就是把判定方拉进来了');
  });
}
