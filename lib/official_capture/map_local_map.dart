// map_local_map.dart — 「候选路标只取局部地图」,复刻上游 local_map_updater。
//
// 出处(BSD-2;源码存档 ~/Developer/upstream_kf_sources_20260901/):
//   · stella_local_map_updater.cc:26-41    acquire_local_map
//   · stella_local_map_updater.cc:60-104   count_num_shared_lms(margin = 5)
//   · stella_local_map_updater.cc:106-144  find_first_local_keyframes
//   · stella_local_map_updater.cc:146-205  find_second_local_keyframes(top 10)
//   · stella_local_map_updater.cc:207-...  find_local_landmarks
//   · stella_tracking_module.cc:32         max_num_local_keyfrms 默认 60
//   · stella_type.h:146-150                greater_number_and_id_object_pairs
//
// 为什么需要它(2026-09-11):
// 上游在 `can_observe` 之前先收窄了候选集 —— 它遍历的是 `local_landmarks_`
// (由共视关系挑出的局部地图),**不是整张地图**(tracking_module.cc:515-521、
// 560)。少了这一步,"远处/背面那些几何上恰好投影进画面的点"也会被算进
// num_reliable_lms,把比值系统性抬高。这一步是纯照抄:不需要描述子、
// 不引入任何新阈值。
//
// 🔴 与上游的偏离,逐条写明:
//
//  ① **种子集**。上游的种子是 `curr_frm_.get_landmarks()` —— 当前帧经跟踪
//     已经关联上的路标。我们的预览帧从不进地图,没有这个集合。改用
//     **上一张照片(ref keyframe)名下的路标**做种子:它在我们这里正是
//     上游 `nearest_covisibility` 通常会落到的那一帧。
//  ② **二阶展开少了生成树**。上游二阶取「top-10 共视 + 生成树 children +
//     parent」(local_map_updater.cc:182/191/200)。共视我们能从观测表精确
//     算出来;**生成树是 stella 自己的簿记结构,我们的地图里不存在** ⇒
//     只做共视那一半,如实少两条。后果:局部地图比上游略小(更保守)。
//  ③ 上游 `find_local_landmarks` 会把种子里已有的路标**排除**在
//     `local_lms_` 之外(它们已经匹配上了,不必再投影);我们这里要的是
//     「这个视角看得见几个」的**总数**,所以不排除。这一条是口径差异,
//     不是算法差异。
//  ④ `partial_sort` 换成全排序:两者在"前 K 个"上结果相同(K 之后的顺序
//     上游本来就未定义,而我们只取前 K)。
//
// 🔴 解耦纪律:本文件只回答「哪些路标算局部地图」。不 import governor、
// 不 import 跟踪器、不 import Flutter、不持有状态、不知道什么是快门。
library;

import 'dart:typed_data';

/// 上游 `tracking_module.cc:32`:`max_num_local_keyfrms` 默认 60。
const int kStellaMaxNumLocalKeyfrms = 60;

/// 上游 `local_map_updater.cc:90`:
/// `constexpr int margin = 5; // Keep a little more than max_num_local_keyfrms_`
const int kStellaLocalKeyfrmMargin = 5;

/// 上游 `local_map_updater.cc:182`:`get_top_n_covisibilities(10)`。
const int kStellaSecondOrderCovisibilities = 10;

/// 局部地图的结果。[keyframeIds] 按上游的顺序(先一阶后二阶),
/// [landmarkSelected] 是长度 = 点数的选中位图。
class StellaLocalMap {
  const StellaLocalMap({
    required this.keyframeIds,
    required this.landmarkSelected,
    required this.nearestCovisibilityId,
  });

  final List<int> keyframeIds;
  final Uint8List landmarkSelected;

  /// 上游 `nearest_covisibility_`(local_map_updater.cc:133-136):
  /// 共视路标最多的那一帧。上游用它更新 `curr_frm_.ref_keyfrm_`。
  final int? nearestCovisibilityId;

  int get selectedCount {
    var n = 0;
    for (final v in landmarkSelected) {
      if (v != 0) n++;
    }
    return n;
  }
}

/// 按共视挑出局部地图。
///
/// [seedFrameId] = 种子帧(见偏离①:我们用上一张照片)。
StellaLocalMap acquireStellaLocalMap({
  required Int32List obsOffsets,
  required Int32List obsFrameIds,
  required int seedFrameId,
  int maxNumLocalKeyfrms = kStellaMaxNumLocalKeyfrms,
}) {
  final pointCount = obsOffsets.length - 1;
  final selected = Uint8List(pointCount < 0 ? 0 : pointCount);
  if (pointCount <= 0) {
    return StellaLocalMap(
      keyframeIds: const <int>[],
      landmarkSelected: selected,
      nearestCovisibilityId: null,
    );
  }

  // ── count_num_shared_lms(local_map_updater.cc:60-104)────────────────
  // 种子帧名下的每个路标,给它的每个观测帧记一票。
  final sharedLms = <int, int>{};
  for (var i = 0; i < pointCount; i++) {
    final begin = obsOffsets[i];
    final end = obsOffsets[i + 1];
    var isSeed = false;
    for (var o = begin; o < end; o++) {
      if (obsFrameIds[o] == seedFrameId) {
        isSeed = true;
        break;
      }
    }
    if (!isSeed) continue;
    for (var o = begin; o < end; o++) {
      final f = obsFrameIds[o];
      sharedLms[f] = (sharedLms[f] ?? 0) + 1;
    }
  }
  if (sharedLms.isEmpty) {
    // 上游:num_shared_lms_and_keyfrm.empty() ⇒ find_local_keyframes 返回 false。
    return StellaLocalMap(
      keyframeIds: const <int>[],
      landmarkSelected: selected,
      nearestCovisibilityId: null,
    );
  }

  // 上游的排序谓词(type.h:146-150):共视数降序,平票时 **id 升序**。
  final ranked = sharedLms.entries.toList()
    ..sort((a, b) {
      if (a.value != b.value) return b.value.compareTo(a.value);
      return a.key.compareTo(b.key);
    });
  // ── find_first_local_keyframes(local_map_updater.cc:106-144)─────────
  final alreadyFound = <int>{};
  final first = <int>[];
  int? nearest;
  var maxShared = 0;
  for (final e in ranked) {
    first.add(e.key);
    alreadyFound.add(e.key);
    if (maxShared < e.value) {
      maxShared = e.value;
      nearest = e.key;
    }
    if (maxNumLocalKeyfrms <= first.length) break;
  }

  // ── find_second_local_keyframes(local_map_updater.cc:146-205)────────
  // 只做「top-10 共视」那一半;生成树 children/parent 我们没有(偏离②)。
  final second = <int>[];
  if (first.length < maxNumLocalKeyfrms) {
    // 帧↔帧的共视计数:同一个路标被两帧同时观测就记一票。
    final covis = <int, Map<int, int>>{};
    for (var i = 0; i < pointCount; i++) {
      final begin = obsOffsets[i];
      final end = obsOffsets[i + 1];
      for (var a = begin; a < end; a++) {
        final fa = obsFrameIds[a];
        for (var b = a + 1; b < end; b++) {
          final fb = obsFrameIds[b];
          if (fa == fb) continue;
          (covis[fa] ??= <int, int>{})[fb] =
              ((covis[fa] ?? const <int, int>{})[fb] ?? 0) + 1;
          (covis[fb] ??= <int, int>{})[fa] =
              ((covis[fb] ?? const <int, int>{})[fa] ?? 0) + 1;
        }
      }
    }
    outer:
    for (final k in first) {
      if (maxNumLocalKeyfrms <= first.length + second.length) break;
      final neighbours = (covis[k] ?? const <int, int>{}).entries.toList()
        ..sort((a, b) {
          if (a.value != b.value) return b.value.compareTo(a.value);
          return a.key.compareTo(b.key);
        });
      final top = neighbours.length > kStellaSecondOrderCovisibilities
          ? neighbours.sublist(0, kStellaSecondOrderCovisibilities)
          : neighbours;
      for (final n in top) {
        if (alreadyFound.contains(n.key)) continue;
        alreadyFound.add(n.key);
        second.add(n.key);
        if (maxNumLocalKeyfrms <= first.length + second.length) break outer;
      }
    }
  }

  final localKeyframes = <int>[...first, ...second];

  // ── find_local_landmarks(local_map_updater.cc:207-...)───────────────
  // 局部关键帧名下的全部路标。不排除种子路标(偏离③)。
  final localSet = localKeyframes.toSet();
  for (var i = 0; i < pointCount; i++) {
    final begin = obsOffsets[i];
    final end = obsOffsets[i + 1];
    for (var o = begin; o < end; o++) {
      if (localSet.contains(obsFrameIds[o])) {
        selected[i] = 1;
        break;
      }
    }
  }

  return StellaLocalMap(
    keyframeIds: localKeyframes,
    landmarkSelected: selected,
    nearestCovisibilityId: nearest,
  );
}
