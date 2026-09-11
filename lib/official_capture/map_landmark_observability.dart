// map_landmark_observability.dart — 「当前这个视角看得见地图里的哪些路标」。
//
// 出处(逐行复刻,BSD-2;源码存档 ~/Developer/upstream_kf_sources_20260901/):
//   · stella_landmark.cc:256-266   landmark::compute_mean_normal
//   · stella_frame.cc:59-84        frame::can_observe(lm, ray_cos_thr, ...)
//   · stella_perspective.cc:130-148 perspective::reproject_to_image
//   · stella_tracking_module.cc:584 调用点,ray_cos_thr 实参 = 0.5
//
// 为什么需要它(2026-09-11):
// 上游判据吃的 `num_reliable_lms` 是「**当前帧**名下、被 ≥ min_num_obs_thr 个
// 关键帧观测到的地图路标数」。上游是靠"投影 + 描述子匹配 + 位姿优化"得到
// 「当前帧名下」这件事的 —— 因为它**没有外部位姿**。我们有 ARKit 位姿,
// 于是可以直接用上游自己的可观测谓词 `can_observe` 来回答同一个问题。
//
// 🔴 与上游的偏离,逐条写明(不写在注释里的偏离等于没有):
//
//  ① **省掉 `is_inside_in_orb_scale`(frame.cc:72)**。那一条是 ORB 金字塔的
//     尺度不变范围(max/min_valid_dist,由 `compute_orb_scale_variance` 从
//     观测该点时的 ORB octave 推出)。我们的前端是 **DSP-SIFT / RootSIFT**
//     (`official_pipeline/src/official_aether_sfm_c.cc:409`
//      "descriptors; // 128 * n_keypoints, RootSIFT"),**没有 ORB 金字塔**,
//     这条测试在我们这里无定义。硬凑一个"等效尺度"就是自研,所以**不做**,
//     如实少一条。后果:比上游宽松 —— 太近/太远的点也会被算作可观测。
//
//  ② **省掉描述子匹配(projection.cc:13-90)**。上游用它确定"当前帧真的看到
//     了这个路标";其阈值 `HAMMING_DIST_THR_HIGH = 100` / `MAX_HAMMING_DIST
//     = 256` 是 **ORB 二进制描述子的汉明距离**,对 128 维 RootSIFT(L2)
//     无定义。我们用位姿几何回答同一个问题 —— 这是「可观测」而不是「已匹配」,
//     是本文件最大的一处偏离。
//
//  ③ 上游的 `num_reliable_lms_ref` 走的是 ref_keyfrm **自己记录的**路标表
//     (keyframe.cc:472),不经过 can_observe;本文件只管"当前视角"那一半,
//     参考那一半仍由 [landmarkCountsForFrame] 按上游原样数。两边口径不同
//     **是上游本来就有的不对称**(匹配得到的 vs 记录下来的),不是我们引入的。
//
// 完全照抄、一个字没改的部分:`ray_cos_thr = 0.5`、平均法向的算法与归一化
// 顺序、投影的 z>0 与图像边界判定。
//
// 🔴 解耦纪律:本文件**只回答"看得见几个"**。不 import governor、不 import
// 跟踪器、不 import Flutter、不持有状态、不知道什么是快门。
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// 每个地图路标的预计算量。只依赖重建给出的点/观测/位姿,与判定无关。
class MapLandmarkTable {
  const MapLandmarkTable({
    required this.xyz,
    required this.observationCount,
    required this.meanNormal,
  });

  /// 3 × count,世界坐标。
  final Float32List xyz;

  /// 每个点的观测条数 = 上游 `lm->num_observations()`。
  /// 我们地图里每个已注册帧就是一张照片(关键帧),所以与上游同义。
  final Int32List observationCount;

  /// 3 × count,上游 `landmark::mean_normal_`(landmark.cc:256-266)。
  final Float32List meanNormal;

  int get count => observationCount.length;
}

/// 从重建的 CSR 观测表 + 各帧相机中心,算出上游 landmark 的两个预测参数里
/// **我们能精确算的那个** —— 平均法向。
///
/// 上游 `landmark::compute_mean_normal`(landmark.cc:256-266),逐字:
/// ```cpp
/// mean_normal = Vec3_t::Zero();
/// for (observation : observations) {
///   const Vec3_t normal = pos_w - keyfrm->get_trans_wc();
///   mean_normal = mean_normal + normal.normalized();
/// }
/// mean_normal = mean_normal.normalized();
/// ```
///
/// [frameCameraCentre] 把 frameId 映射到该帧的相机中心(世界坐标,
/// 即上游的 `trans_wc`)。取不到的帧按上游"观测必然挂在关键帧上"的前提
/// 跳过 —— 跳过而不是当成原点,后者会把法向拉向世界原点。
MapLandmarkTable buildMapLandmarkTable({
  required Float32List xyz,
  required Int32List obsOffsets,
  required Int32List obsFrameIds,
  required Float32List? Function(int frameId) frameCameraCentre,
}) {
  final count = obsOffsets.length - 1;
  if (count <= 0) {
    return MapLandmarkTable(
      xyz: Float32List(0),
      observationCount: Int32List(0),
      meanNormal: Float32List(0),
    );
  }
  final obsCount = Int32List(count);
  final normals = Float32List(count * 3);
  for (var i = 0; i < count; i++) {
    final begin = obsOffsets[i];
    final end = obsOffsets[i + 1];
    obsCount[i] = end - begin;
    final px = xyz[i * 3], py = xyz[i * 3 + 1], pz = xyz[i * 3 + 2];
    var nx = 0.0, ny = 0.0, nz = 0.0;
    for (var o = begin; o < end; o++) {
      final centre = frameCameraCentre(obsFrameIds[o]);
      if (centre == null) continue;
      final vx = px - centre[0];
      final vy = py - centre[1];
      final vz = pz - centre[2];
      final len = math.sqrt(vx * vx + vy * vy + vz * vz);
      if (!(len > 0)) continue;
      nx += vx / len;
      ny += vy / len;
      nz += vz / len;
    }
    final nlen = math.sqrt(nx * nx + ny * ny + nz * nz);
    if (nlen > 0) {
      normals[i * 3] = nx / nlen;
      normals[i * 3 + 1] = ny / nlen;
      normals[i * 3 + 2] = nz / nlen;
    }
  }
  return MapLandmarkTable(
    xyz: xyz,
    observationCount: obsCount,
    meanNormal: normals,
  );
}

/// 上游调用 `can_observe` 时实参就是 0.5(tracking_module.cc:584)。
const double kStellaRayCosThr = 0.5;

/// 「这个视角看得见几个路标」。
///
/// [rotCw] 行主序 3×3(世界→相机),[transCw] 3 元;与上游
/// `reproject_to_image(rot_cw, trans_cw, pos_w, ...)` 同一约定。
///
/// 逐条对应:
///   · `pos_c = rot_cw * pos_w + trans_cw; if (pos_c(2) <= 0) return false;`
///     (perspective.cc:132-137)
///   · `reproj = (fx*x/z+cx, fy*y/z+cy)`,并落在图像边界内
///     (perspective.cc:140-147)
///   · `ray_cos = (pos_w - trans_wc)·mean_normal / dist; ray_cos < thr ⇒ false`
///     (frame.cc:76-80)
///   · 少了 `is_inside_in_orb_scale` —— 见文件头偏离①。
///
/// 返回的两个数与上游 `optimize_current_frame_with_local_map`
/// (tracking_module.cc:459-481)同名:`tracked` 不设观测门槛,
/// `reliable` 要求 `minNumObsThr <= num_observations()`。
({int tracked, int reliable}) observableLandmarkCounts({
  required MapLandmarkTable table,
  required List<double> rotCw,
  required List<double> transCw,
  required double fx,
  required double fy,
  required double cx,
  required double cy,
  required double minX,
  required double maxX,
  required double minY,
  required double maxY,
  required int minNumObsThr,
  double rayCosThr = kStellaRayCosThr,
}) {
  final count = table.count;
  if (count == 0) return (tracked: 0, reliable: 0);
  // trans_wc = -R_cw^T * t_cw(相机中心,世界坐标)。
  final twcX =
      -(rotCw[0] * transCw[0] + rotCw[3] * transCw[1] + rotCw[6] * transCw[2]);
  final twcY =
      -(rotCw[1] * transCw[0] + rotCw[4] * transCw[1] + rotCw[7] * transCw[2]);
  final twcZ =
      -(rotCw[2] * transCw[0] + rotCw[5] * transCw[1] + rotCw[8] * transCw[2]);
  var tracked = 0;
  var reliable = 0;
  for (var i = 0; i < count; i++) {
    final px = table.xyz[i * 3];
    final py = table.xyz[i * 3 + 1];
    final pz = table.xyz[i * 3 + 2];
    final cxz = rotCw[6] * px + rotCw[7] * py + rotCw[8] * pz + transCw[2];
    if (cxz <= 0.0) continue;
    final cxx = rotCw[0] * px + rotCw[1] * py + rotCw[2] * pz + transCw[0];
    final cyy = rotCw[3] * px + rotCw[4] * py + rotCw[5] * pz + transCw[1];
    final zInv = 1.0 / cxz;
    final u = fx * cxx * zInv + cx;
    final v = fy * cyy * zInv + cy;
    if (!(minX < u && u < maxX && minY < v && v < maxY)) continue;
    final rx = px - twcX, ry = py - twcY, rz = pz - twcZ;
    final dist = math.sqrt(rx * rx + ry * ry + rz * rz);
    if (!(dist > 0)) continue;
    final nx = table.meanNormal[i * 3];
    final ny = table.meanNormal[i * 3 + 1];
    final nz = table.meanNormal[i * 3 + 2];
    final rayCos = (rx * nx + ry * ny + rz * nz) / dist;
    if (rayCos < rayCosThr) continue;
    if (0 < minNumObsThr && minNumObsThr <= table.observationCount[i]) {
      reliable++;
    }
    tracked++;
  }
  return (tracked: tracked, reliable: reliable);
}
