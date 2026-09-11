// map_landmark_counts.dart — stella_vslam 关键帧判据所吃的那两个量,**从地图里数**。
//
// 出处(逐行复刻,BSD-2,源码存档在 ~/Developer/upstream_kf_sources_20260901/):
//   · stella_tracking_module.cc:144      min_num_obs_thr
//   · stella_tracking_module.cc:459-481  num_tracked_lms / num_reliable_lms
//   · stella_keyframe.cc:472-489         keyframe::get_num_tracked_landmarks
//
// 为什么要有这个文件(2026-09-11):
// 我们此前把上游的 `num_reliable_lms` / `num_reliable_lms_ref` 换成了
// 「128×128 预览图上 LK 轨迹的存活数 / 上一张照片种下的数」。常数是照抄的,
// **量是自研的**。而上游那两个量是**地图路标的计数**:
//     num_reliable_lms_ref = ref_keyfrm 名下、被 ≥ min_num_obs_thr 个关键帧
//                            观测到的 3D 路标数(keyframe.cc:485)
//     num_reliable_lms     = 当前帧名下、同一条件的路标数(tracking_module.cc:475)
// 两处**是同一个谓词套在两个不同帧的路标集合上**,所以这里只实现一个原语。
//
// 🔴 解耦纪律:本文件**只负责数数**。
//   · 不 import governor、不 import 跟踪器、不 import 任何 Flutter;
//   · 不知道什么是"快门",不做任何判定,不持有状态;
//   · 入参是重建已经给出的 CSR 观测表,出参是整数。
//   谁来用、什么时候用、用哪个帧当 ref —— 全部由调用方决定,不在这里。
library;

import 'dart:typed_data';

/// 上游 `tracking_module.cc:144`:
/// ```cpp
/// const unsigned int min_num_obs_thr = (3 <= map_db_->get_num_keyframes()) ? 3 : 2;
/// ```
/// [numKeyframes] = 地图里已注册的关键帧数。我们这边每一个已注册帧**就是**
/// 一张照片(地图里不存在非关键帧的帧),所以这个数就是已注册照片数。
int stellaMinNumObsThr(int numKeyframes) => 3 <= numKeyframes ? 3 : 2;

/// 一个帧名下的路标计数。上游两处循环的共同原语:
///
/// `tracking_module.cc:459-481`(当前帧)
/// ```cpp
/// for (idx : curr_frm_.frm_obs_.undist_keypts_) {
///   lm = curr_frm_.get_landmark(idx);
///   if (!lm) continue;
///   if (lm->will_be_erased()) continue;
///   if (0 < min_num_obs_thr) { if (min_num_obs_thr <= lm->num_observations()) ++num_reliable_lms; }
///   ++num_tracked_lms;
/// }
/// ```
/// `keyframe.cc:472-489`(参考关键帧)是同一个谓词,只是遍历 `landmarks_`。
///
/// 映射到我们的数据(`AetherSfmPointsTracked` 的 CSR 观测表):
///   · 「帧 F 名下的路标」= 观测表里存在一条 `frameId == F` 的那些 3D 点;
///   · `lm->num_observations()` = 该点的观测条数。上游数的是**关键帧**观测数,
///     而我们地图里每个已注册帧都是关键帧(照片),所以两者同义;
///   · `!lm` / `will_be_erased()` 两条跳过在这里天然满足 —— CSR 里只有活点。
///
/// [minNumObsThr] == 0 时上游走的是"不设门槛"那一支(keyframe.cc:490 的 else),
/// 这里同样只数"该帧名下的路标数"。
({int tracked, int reliable}) landmarkCountsForFrame({
  required Int32List obsOffsets,
  required Int32List obsFrameIds,
  required int frameId,
  required int minNumObsThr,
}) {
  // CSR:obsOffsets 有 count+1 项,点 i 的观测是 [offsets[i], offsets[i+1])。
  final pointCount = obsOffsets.length - 1;
  if (pointCount <= 0) return (tracked: 0, reliable: 0);
  var tracked = 0;
  var reliable = 0;
  for (var i = 0; i < pointCount; i++) {
    final begin = obsOffsets[i];
    final end = obsOffsets[i + 1];
    if (end <= begin) continue;
    var observedHere = false;
    for (var o = begin; o < end; o++) {
      if (obsFrameIds[o] == frameId) {
        observedHere = true;
        break;
      }
    }
    if (!observedHere) continue;
    // num_observations() —— 该 3D 点被多少帧观测到。
    final numObservations = end - begin;
    if (0 < minNumObsThr && minNumObsThr <= numObservations) {
      reliable++;
    }
    tracked++;
  }
  return (tracked: tracked, reliable: reliable);
}

/// 上游 `tracking_module.cc:483`:
/// ```cpp
/// constexpr unsigned int num_tracked_lms_thr = 20;
/// ```
const int kStellaNumTrackedLmsThr = 20;

/// 局部地图跟踪算不算成功(`tracking_module.cc:483-497`)。
///
/// 🔴 这是判据的**前置门**,不是判据的一部分:上游在
/// `tracking_module.cc:148` 写的是
/// ```cpp
/// if (succeeded && !is_stopped_keyframe_insertion_ && new_keyframe_is_needed(...))
/// ```
/// —— 跟踪没成功时,`new_keyframe_is_needed` **根本不会被调用**。
///
/// 为什么必须一起搬过来(2026-09-11 离线复算):把 num_reliable_lms 换成地图
/// 口径之后,开局地图太小会让 `not_enough_lms`(< 100)恒为真。用未命名(10)
/// 的真实数据算上界(每个点至少 2 次观测,故 #(obs>=3) <= O - 2P):
///   第2张 P=93   O=186   ⇒ 上界 0    ⇒ not_enough_lms 必然为真
///   第3张 P=1208 O=2493  ⇒ 上界 77   ⇒ 仍然必然为真
///   第4张起上界才过 100。
/// 而 `not_enough_lms` 在上游是**触发项**(与 view_changed 并列在第一个析取
/// 里),再叠上「关键帧 <= 5 时 min_interval / min_distance 被豁免」
/// (keyframe_inserter.cc:124 的 `!enough_keyfrms ||`),第 2–6 张就会按 tick
/// 连拍 —— 正是 09-06 那一类事故。
///
/// 上游不会这样,是因为它有这道前置门:地图小的时候 `num_tracked_lms` 不够,
/// 跟踪直接判失败,判据压根不参与。所以这道门**不是可选项**。
///
/// [recentlyRelocalized] 对应上游 `curr_frm_.timestamp_ <
/// last_reloc_frm_timestamp_ + 1.0`,此时门槛翻倍(tracking_module.cc:486)。
bool stellaLocalMapTrackingSucceeded({
  required int numTrackedLms,
  bool recentlyRelocalized = false,
}) {
  if (recentlyRelocalized && numTrackedLms < 2 * kStellaNumTrackedLmsThr) {
    return false;
  }
  return numTrackedLms >= kStellaNumTrackedLmsThr;
}
