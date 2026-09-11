// 对拍上游三段:
//   stella_landmark.cc:256-266     compute_mean_normal
//   stella_perspective.cc:130-148  reproject_to_image
//   stella_frame.cc:59-84          can_observe(ray_cos_thr = 0.5)
// (源码存档 ~/Developer/upstream_kf_sources_20260901/)
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/map_landmark_observability.dart';

/// 单位阵 = 相机在世界原点、朝 +z 看(与上游 rot_cw/trans_cw 同约定)。
const List<double> _identity = <double>[1, 0, 0, 0, 1, 0, 0, 0, 1];

MapLandmarkTable _tableOf(
  List<List<double>> points,
  List<List<int>> observedBy,
  Map<int, List<double>> centres,
) {
  final xyz = Float32List(points.length * 3);
  for (var i = 0; i < points.length; i++) {
    xyz[i * 3] = points[i][0];
    xyz[i * 3 + 1] = points[i][1];
    xyz[i * 3 + 2] = points[i][2];
  }
  final offsets = Int32List(points.length + 1);
  final frames = <int>[];
  for (var i = 0; i < observedBy.length; i++) {
    offsets[i] = frames.length;
    frames.addAll(observedBy[i]);
  }
  offsets[points.length] = frames.length;
  return buildMapLandmarkTable(
    xyz: xyz,
    obsOffsets: offsets,
    obsFrameIds: Int32List.fromList(frames),
    frameCameraCentre: (id) {
      final c = centres[id];
      return c == null ? null : Float32List.fromList(c);
    },
  );
}

void main() {
  group('compute_mean_normal(landmark.cc:256-266)', () {
    test('单观测:法向就是「相机中心 → 点」的单位向量', () {
      final t = _tableOf(
        <List<double>>[
          <double>[0, 0, 5],
        ],
        <List<int>>[
          <int>[0],
        ],
        <int, List<double>>{
          0: <double>[0, 0, 0],
        },
      );
      expect(t.meanNormal[0], closeTo(0, 1e-6));
      expect(t.meanNormal[1], closeTo(0, 1e-6));
      expect(t.meanNormal[2], closeTo(1, 1e-6));
      expect(t.observationCount[0], 1);
    });

    test('两个对称视角:先各自归一化再相加,最后再归一化(顺序照抄上游)', () {
      // 点在 (0,0,5);两台相机分别在 (-5,0,5) 与 (5,0,5) —— 视线一左一右。
      final t = _tableOf(
        <List<double>>[
          <double>[0, 0, 5],
        ],
        <List<int>>[
          <int>[0, 1],
        ],
        <int, List<double>>{
          0: <double>[-5, 0, 5],
          1: <double>[5, 0, 5],
        },
      );
      // (+1,0,0) 与 (-1,0,0) 相加 = 0 ⇒ 归一化后保持 0(上游同样得到零向量)。
      expect(t.meanNormal[0], closeTo(0, 1e-6));
      expect(t.meanNormal[1], closeTo(0, 1e-6));
      expect(t.meanNormal[2], closeTo(0, 1e-6));
    });

    test('取不到相机中心的观测被跳过,不会把法向拉向世界原点', () {
      final t = _tableOf(
        <List<double>>[
          <double>[0, 0, 5],
        ],
        <List<int>>[
          <int>[0, 42],
        ],
        <int, List<double>>{
          0: <double>[0, 0, 0],
        },
      );
      expect(t.meanNormal[2], closeTo(1, 1e-6));
      expect(t.observationCount[0], 2, reason: '观测数照数,跳过的只是法向那一项');
    });
  });

  group('can_observe + reproject_to_image', () {
    late MapLandmarkTable table;
    setUp(() {
      // 三个点都在相机正前方 z=5,分别位于画面中心/右上/画面外。
      table = _tableOf(
        <List<double>>[
          <double>[0, 0, 5],
          <double>[1, 1, 5],
          <double>[50, 0, 5],
        ],
        <List<int>>[
          <int>[0, 1, 2],
          <int>[0, 1],
          <int>[0],
        ],
        <int, List<double>>{
          0: <double>[0, 0, 0],
          1: <double>[0.2, 0, 0],
          2: <double>[-0.2, 0, 0],
        },
      );
    });

    ({int tracked, int reliable}) counts({int thr = 2}) =>
        observableLandmarkCounts(
          table: table,
          rotCw: _identity,
          transCw: const <double>[0, 0, 0],
          fx: 100,
          fy: 100,
          cx: 64,
          cy: 64,
          minX: 0,
          maxX: 128,
          minY: 0,
          maxY: 128,
          minNumObsThr: thr,
        );

    test('画面外的点被边界判定挡掉(perspective.cc:146-147)', () {
      final c = counts();
      expect(c.tracked, 2, reason: '第三个点投影到 u≈1064,超出 128');
    });

    test('观测门槛只影响 reliable,不影响 tracked', () {
      expect(counts(thr: 2).reliable, 2);
      expect(counts(thr: 3).reliable, 1, reason: '只有点0 有 3 次观测');
      expect(counts(thr: 3).tracked, 2);
    });

    test('相机跑到点背后:z<=0 一条就全部挡掉(perspective.cc:135)', () {
      final c = observableLandmarkCounts(
        table: table,
        rotCw: _identity,
        transCw: const <double>[0, 0, -10], // 相机中心移到 z=+10,点都在身后
        fx: 100,
        fy: 100,
        cx: 64,
        cy: 64,
        minX: 0,
        maxX: 128,
        minY: 0,
        maxY: 128,
        minNumObsThr: 2,
      );
      expect(c.tracked, 0);
      expect(c.reliable, 0);
    });

    test('🔴 ray_cos 闸:从背面看同一个点要被挡掉(frame.cc:76-80,阈值 0.5)', () {
      // 点在 (0,0,5),只被 (0,0,0) 观测过 ⇒ 平均法向 = +z。
      final t = _tableOf(
        <List<double>>[
          <double>[0, 0, 5],
        ],
        <List<int>>[
          <int>[0, 0, 0],
        ],
        <int, List<double>>{
          0: <double>[0, 0, 0],
        },
      );
      // 正面看:相机在原点,视线 +z,ray_cos = 1 ⇒ 通过。
      final front = observableLandmarkCounts(
        table: t,
        rotCw: _identity,
        transCw: const <double>[0, 0, 0],
        fx: 100, fy: 100, cx: 64, cy: 64,
        minX: 0, maxX: 128, minY: 0, maxY: 128,
        minNumObsThr: 2,
      );
      expect(front.tracked, 1);

      // 背面看:相机中心在 (0,0,10) 且绕 y 轴转 180°,点仍在画面中心、z>0,
      // 但 (pos_w - trans_wc) = (0,0,-5),与法向 +z 的夹角 cos = -1 < 0.5。
      const rotY180 = <double>[-1, 0, 0, 0, 1, 0, 0, 0, -1];
      final back = observableLandmarkCounts(
        table: t,
        rotCw: rotY180,
        // t_cw = -R_cw * C ,C = (0,0,10) ⇒ t_cw = (0,0,10)
        transCw: const <double>[0, 0, 10],
        fx: 100, fy: 100, cx: 64, cy: 64,
        minX: 0, maxX: 128, minY: 0, maxY: 128,
        minNumObsThr: 2,
      );
      expect(
        back.tracked,
        0,
        reason: '几何上看得见,但视线方向与观测法向相反 —— 上游这一条必须留',
      );
    });

    test('阴性对照:空表 => 全 0,不抛', () {
      final empty = buildMapLandmarkTable(
        xyz: Float32List(0),
        obsOffsets: Int32List.fromList(<int>[0]),
        obsFrameIds: Int32List(0),
        frameCameraCentre: (_) => null,
      );
      final c = observableLandmarkCounts(
        table: empty,
        rotCw: _identity,
        transCw: const <double>[0, 0, 0],
        fx: 100, fy: 100, cx: 64, cy: 64,
        minX: 0, maxX: 128, minY: 0, maxY: 128,
        minNumObsThr: 2,
      );
      expect(c.tracked, 0);
      expect(c.reliable, 0);
    });

    test('阈值就是上游实参 0.5(tracking_module.cc:584)', () {
      expect(kStellaRayCosThr, 0.5);
      // 60° 时 cos = 0.5,正好卡在 `ray_cos < thr` 的边界上(不小于 ⇒ 通过)。
      expect(math.cos(math.pi / 3), closeTo(0.5, 1e-12));
    });
  });

  test('候选收窄:位图为 0 的点不参与计数(组合在调用点,不在本模块)', () {
    final t = _tableOf(
      <List<double>>[
        <double>[0, 0, 5],
        <double>[0.5, 0, 5],
      ],
      <List<int>>[
        <int>[0, 0, 0],
        <int>[0, 0, 0],
      ],
      <int, List<double>>{
        0: <double>[0, 0, 0],
      },
    );
    ({int tracked, int reliable}) run(Uint8List? sel) => observableLandmarkCounts(
          table: t,
          rotCw: _identity,
          transCw: const <double>[0, 0, 0],
          fx: 100, fy: 100, cx: 64, cy: 64,
          minX: 0, maxX: 128, minY: 0, maxY: 128,
          minNumObsThr: 2,
          selected: sel,
        );
    expect(run(null).tracked, 2, reason: '不收窄 = 全图');
    expect(run(Uint8List.fromList(<int>[1, 0])).tracked, 1);
    expect(run(Uint8List.fromList(<int>[0, 0])).tracked, 0);
  });

  test('解耦纪律:只许依赖 dart:math / dart:typed_data', () {
    final src = File(
      'lib/official_capture/map_landmark_observability.dart',
    ).readAsStringSync();
    final imports = src
        .split('\n')
        .where((l) => l.trimLeft().startsWith('import '))
        .map((l) => l.trim())
        .toList();
    expect(imports, <String>[
      "import 'dart:math' as math;",
      "import 'dart:typed_data';",
    ], reason: '数数/看得见的模块一旦 import 判定方,就又耦合回去了');
  });
}
