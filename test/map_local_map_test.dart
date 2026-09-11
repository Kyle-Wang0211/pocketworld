// 对拍上游 local_map_updater。判据来自源码,不是我编的用例:
//   stella_local_map_updater.cc:60-104 / 106-144 / 146-205 / 207-
//   stella_type.h:146-150(排序:共视数降序,平票 id 升序)
//   stella_tracking_module.cc:32(max_num_local_keyfrms 默认 60)
// (源码存档 ~/Developer/upstream_kf_sources_20260901/)
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/map_local_map.dart';

({Int32List offsets, Int32List frames}) _csr(List<List<int>> observedBy) {
  final offsets = Int32List(observedBy.length + 1);
  final frames = <int>[];
  for (var i = 0; i < observedBy.length; i++) {
    offsets[i] = frames.length;
    frames.addAll(observedBy[i]);
  }
  offsets[observedBy.length] = frames.length;
  return (offsets: offsets, frames: Int32List.fromList(frames));
}

void main() {
  test('常数就是上游的默认值', () {
    expect(kStellaMaxNumLocalKeyfrms, 60, reason: 'tracking_module.cc:32');
    expect(kStellaLocalKeyfrmMargin, 5, reason: 'local_map_updater.cc:90');
    expect(kStellaSecondOrderCovisibilities, 10,
        reason: 'local_map_updater.cc:182 get_top_n_covisibilities(10)');
  });

  test('一阶:共视数降序、平票 id 升序(type.h:146-150)', () {
    // 种子 = 帧 0。帧 1 与它共 2 个点,帧 2 与帧 3 各共 1 个。
    final c = _csr(<List<int>>[
      <int>[0, 1],
      <int>[0, 1],
      <int>[0, 3],
      <int>[0, 2],
    ]);
    final m = acquireStellaLocalMap(
      obsOffsets: c.offsets,
      obsFrameIds: c.frames,
      seedFrameId: 0,
    );
    // 帧0 自己共视 4(它名下 4 个点),帧1 = 2,帧2 = 1,帧3 = 1;
    // 平票的 2 与 3 按 id 升序。
    expect(m.keyframeIds.take(4).toList(), <int>[0, 1, 2, 3]);
    expect(m.nearestCovisibilityId, 0);
  });

  test('maxNumLocalKeyfrms 截断(local_map_updater.cc:138)', () {
    final c = _csr(<List<int>>[
      <int>[0, 1],
      <int>[0, 2],
      <int>[0, 3],
      <int>[0, 4],
    ]);
    final m = acquireStellaLocalMap(
      obsOffsets: c.offsets,
      obsFrameIds: c.frames,
      seedFrameId: 0,
      maxNumLocalKeyfrms: 2,
    );
    expect(m.keyframeIds.length, 2, reason: '一阶就已经到上限,二阶不再展开');
  });

  test('二阶:与种子无直接共视的帧,靠邻居的共视被拉进来', () {
    // 种子 0 与 1 共视;帧 2 只与 1 共视,与 0 毫无关系。
    final c = _csr(<List<int>>[
      <int>[0, 1],
      <int>[1, 2],
    ]);
    final m = acquireStellaLocalMap(
      obsOffsets: c.offsets,
      obsFrameIds: c.frames,
      seedFrameId: 0,
    );
    expect(m.keyframeIds, contains(2),
        reason: '帧2 不与种子共视,只能由二阶共视引入');
    expect(m.keyframeIds.indexOf(2), greaterThan(m.keyframeIds.indexOf(1)),
        reason: '上游先一阶后二阶,顺序不能乱');
  });

  test('🔴 收窄真的排除了局部地图之外的点', () {
    // 点0/1 属于种子那一簇;点2 只被一个与世隔绝的帧 9 观测。
    final c = _csr(<List<int>>[
      <int>[0, 1],
      <int>[0, 1],
      <int>[9],
    ]);
    final m = acquireStellaLocalMap(
      obsOffsets: c.offsets,
      obsFrameIds: c.frames,
      seedFrameId: 0,
    );
    expect(m.landmarkSelected[0], 1);
    expect(m.landmarkSelected[1], 1);
    expect(m.landmarkSelected[2], 0,
        reason: '帧9 既不与种子共视、也不是任何一阶帧的共视邻居');
    expect(m.selectedCount, 2);
  });

  test('阴性对照:种子帧不在地图里 => 空局部地图,不抛', () {
    final c = _csr(<List<int>>[
      <int>[1, 2],
    ]);
    final m = acquireStellaLocalMap(
      obsOffsets: c.offsets,
      obsFrameIds: c.frames,
      seedFrameId: 77,
    );
    expect(m.keyframeIds, isEmpty);
    expect(m.selectedCount, 0);
    expect(m.nearestCovisibilityId, isNull);
  });

  test('阴性对照:空地图 => 空,不抛', () {
    final m = acquireStellaLocalMap(
      obsOffsets: Int32List.fromList(<int>[0]),
      obsFrameIds: Int32List(0),
      seedFrameId: 0,
    );
    expect(m.keyframeIds, isEmpty);
    expect(m.landmarkSelected, isEmpty);
  });

  test('解耦纪律:只许依赖 dart:typed_data', () {
    final src = File(
      'lib/official_capture/map_local_map.dart',
    ).readAsStringSync();
    final imports = src
        .split('\n')
        .where((l) => l.trimLeft().startsWith('import '))
        .map((l) => l.trim())
        .toList();
    expect(imports, <String>["import 'dart:typed_data';"],
        reason: '挑局部地图的模块一旦 import 判定方,就又耦合回去了');
  });
}
