// 对拍上游两处循环。判据来自源码本身,不是我编的用例:
//   stella_tracking_module.cc:144 / 459-481、stella_keyframe.cc:472-489
// (源码存档 ~/Developer/upstream_kf_sources_20260901/)
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/map_landmark_counts.dart';

/// 手搭的小地图,观测表按 CSR 排:
///   点0:帧 0,1,2   (3 次观测)
///   点1:帧 0,1     (2 次)
///   点2:帧 0       (1 次)
///   点3:帧 1,2,3,4 (4 次)
({Int32List offsets, Int32List frames}) _fixture() {
  final obs = <List<int>>[
    <int>[0, 1, 2],
    <int>[0, 1],
    <int>[0],
    <int>[1, 2, 3, 4],
  ];
  final offsets = Int32List(obs.length + 1);
  final frames = <int>[];
  for (var i = 0; i < obs.length; i++) {
    offsets[i] = frames.length;
    frames.addAll(obs[i]);
  }
  offsets[obs.length] = frames.length;
  return (offsets: offsets, frames: Int32List.fromList(frames));
}

void main() {
  group('min_num_obs_thr(tracking_module.cc:144)', () {
    test('关键帧 < 3 时是 2,>= 3 时是 3', () {
      expect(stellaMinNumObsThr(0), 2);
      expect(stellaMinNumObsThr(1), 2);
      expect(stellaMinNumObsThr(2), 2);
      expect(stellaMinNumObsThr(3), 3, reason: '上游写的是 3 <= num_keyframes');
      expect(stellaMinNumObsThr(36), 3);
    });
  });

  group('landmarkCountsForFrame', () {
    late Int32List offsets;
    late Int32List frames;
    setUp(() {
      final f = _fixture();
      offsets = f.offsets;
      frames = f.frames;
    });

    test('帧 0:名下 3 个路标,其中观测数 >=3 的只有点0', () {
      final c = landmarkCountsForFrame(
        obsOffsets: offsets,
        obsFrameIds: frames,
        frameId: 0,
        minNumObsThr: 3,
      );
      expect(c.tracked, 3, reason: '点0/1/2 都有帧0 的观测');
      expect(c.reliable, 1, reason: '只有点0 的观测数(3)达到 3');
    });

    test('同一帧换成门槛 2:点0(3次)与点1(2次)都算可靠', () {
      final c = landmarkCountsForFrame(
        obsOffsets: offsets,
        obsFrameIds: frames,
        frameId: 0,
        minNumObsThr: 2,
      );
      expect(c.tracked, 3);
      expect(c.reliable, 2);
    });

    test('帧 1:名下 3 个(点0/1/3),门槛 3 时可靠 2 个(点0、点3)', () {
      final c = landmarkCountsForFrame(
        obsOffsets: offsets,
        obsFrameIds: frames,
        frameId: 1,
        minNumObsThr: 3,
      );
      expect(c.tracked, 3);
      expect(c.reliable, 2);
    });

    test('门槛 0 = 上游 else 支:只数该帧名下路标数,reliable 恒 0', () {
      final c = landmarkCountsForFrame(
        obsOffsets: offsets,
        obsFrameIds: frames,
        frameId: 1,
        minNumObsThr: 0,
      );
      expect(c.tracked, 3);
      expect(
        c.reliable,
        0,
        reason: '上游 if (0 < min_num_obs_thr) 为假时根本不累加 reliable',
      );
    });

    test('一个点在同一帧里有多条观测也只算一次(上游按路标数,不按观测数)', () {
      final off = Int32List.fromList(<int>[0, 3]);
      final fr = Int32List.fromList(<int>[7, 7, 8]);
      final c = landmarkCountsForFrame(
        obsOffsets: off,
        obsFrameIds: fr,
        frameId: 7,
        minNumObsThr: 3,
      );
      expect(c.tracked, 1);
      expect(c.reliable, 1);
    });

    test('阴性对照:地图里没有这一帧 => 全 0', () {
      final c = landmarkCountsForFrame(
        obsOffsets: offsets,
        obsFrameIds: frames,
        frameId: 99,
        minNumObsThr: 3,
      );
      expect(c.tracked, 0);
      expect(c.reliable, 0);
    });

    test('阴性对照:空地图 => 全 0,不抛', () {
      final c = landmarkCountsForFrame(
        obsOffsets: Int32List.fromList(<int>[0]),
        obsFrameIds: Int32List(0),
        frameId: 0,
        minNumObsThr: 3,
      );
      expect(c.tracked, 0);
      expect(c.reliable, 0);
    });
  });

  test('解耦纪律:数数的模块不许 import 判定方,也不许碰 Flutter', () {
    final src = File(
      'lib/official_capture/map_landmark_counts.dart',
    ).readAsStringSync();
    final imports = src
        .split('\n')
        .where((l) => l.trimLeft().startsWith('import '))
        .toList();
    expect(imports, <String>["import 'dart:typed_data';"],
        reason: '只许依赖 dart:typed_data —— 多一条都是耦合的开始');
  });
}
