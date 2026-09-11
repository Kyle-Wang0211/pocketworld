// map_keyframe_evidence.dart — 把四个纯模块组合成上游判据要的三个量。
//
// 🔴 解耦纪律:**组合发生在这里,不在任何一个纯模块里**。
// 本文件 import 那四个模块(它就是组合器),但**不 import governor、
// 不 import 控制器、不 import Flutter、不做任何"要不要拍"的判断**。
// 它只回答:「按上游的定义,现在这三个数是多少」。
//
// 上游对应(源码存档 ~/Developer/upstream_kf_sources_20260901/):
//   num_tracked_lms / num_reliable_lms       tracking_module.cc:459-481
//   num_reliable_lms_ref                     keyframe.cc:472-489
//   min_num_obs_thr                          tracking_module.cc:144
//   局部地图收窄                              tracking_module.cc:515-521, 560
//   跟踪成功门(判据是否参与)                 tracking_module.cc:483-497, 148
library;

import 'dart:typed_data';

import 'map_frame_alignment.dart';
import 'map_landmark_counts.dart';
import 'map_landmark_observability.dart';
import 'map_local_map.dart';

/// 上游判据的一次取数结果。
class StellaMapEvidence {
  const StellaMapEvidence({
    required this.numTrackedLms,
    required this.numReliableLms,
    required this.numReliableLmsRef,
    required this.minNumObsThr,
    required this.localKeyframeCount,
    required this.localLandmarkCount,
  });

  final int numTrackedLms;
  final int numReliableLms;
  final int numReliableLmsRef;
  final int minNumObsThr;
  final int localKeyframeCount;
  final int localLandmarkCount;

  /// 上游 tracking_module.cc:148 —— 跟踪没成功,判据根本不会被调用。
  bool get trackingSucceeded =>
      stellaLocalMapTrackingSucceeded(numTrackedLms: numTrackedLms);
}

/// 按重建快照持有派生数据;每 tick 只做投影计数,不重建表。
class MapKeyframeEvidenceSource {
  MapLandmarkTable? _table;
  Int32List? _obsOffsets;
  Int32List? _obsFrameIds;
  int _registeredFrameCount = 0;
  final Map<int, CamFromWorldPose> _reconPoseByFrame =
      <int, CamFromWorldPose>{};

  /// 局部地图按「快照 × 参考帧」缓存 —— 参考帧只在拍成一张时才变。
  int? _localMapRefFrameId;
  StellaLocalMap? _localMap;

  bool get hasSnapshot => _table != null;

  /// 重建每发布一次新快照调一次(**不是每 tick**)。
  ///
  /// [posesPacked] 每帧 9 个 double:[frameId, registered, qw,qx,qy,qz, tx,ty,tz]
  /// (CamFromWorld,与上游 rot_cw/trans_cw 同约定)。
  void updateFromSnapshot({
    required Float32List xyz,
    required Int32List obsOffsets,
    required Int32List obsFrameIds,
    required Float64List posesPacked,
  }) {
    _reconPoseByFrame.clear();
    var registered = 0;
    for (var i = 0; i + 8 < posesPacked.length; i += 9) {
      if (posesPacked[i + 1] == 0) continue;
      registered++;
      final frameId = posesPacked[i].round();
      _reconPoseByFrame[frameId] = CamFromWorldPose(
        rotCw: rotationFromQuatWxyz(
          posesPacked[i + 2],
          posesPacked[i + 3],
          posesPacked[i + 4],
          posesPacked[i + 5],
        ),
        transCw: <double>[
          posesPacked[i + 6],
          posesPacked[i + 7],
          posesPacked[i + 8],
        ],
      );
    }
    _registeredFrameCount = registered;
    _obsOffsets = obsOffsets;
    _obsFrameIds = obsFrameIds;
    _table = buildMapLandmarkTable(
      xyz: xyz,
      obsOffsets: obsOffsets,
      obsFrameIds: obsFrameIds,
      frameCameraCentre: (frameId) {
        final p = _reconPoseByFrame[frameId];
        if (p == null) return null;
        final c = p.cameraCentre;
        return Float32List.fromList(<double>[c[0], c[1], c[2]]);
      },
    );
    // 快照换了,局部地图要重挑。
    _localMapRefFrameId = null;
    _localMap = null;
  }

  void reset() {
    _table = null;
    _obsOffsets = null;
    _obsFrameIds = null;
    _reconPoseByFrame.clear();
    _registeredFrameCount = 0;
    _localMapRefFrameId = null;
    _localMap = null;
  }

  /// 取一次数。任一前提缺失就返回 null —— **fail closed**,由调用方退回
  /// 现役口径,绝不用半套数据凑一个比值出来。
  StellaMapEvidence? evidenceFor({
    required int refFrameId,
    required CamFromWorldPose arkitRefPose,
    required CamFromWorldPose arkitCurrentPose,
    required double fx,
    required double fy,
    required double cx,
    required double cy,
    required double imageWidth,
    required double imageHeight,
  }) {
    final table = _table;
    final offsets = _obsOffsets;
    final frameIds = _obsFrameIds;
    final reconRef = _reconPoseByFrame[refFrameId];
    if (table == null ||
        offsets == null ||
        frameIds == null ||
        reconRef == null ||
        table.count == 0) {
      return null;
    }
    if (!(fx > 0 && fy > 0 && imageWidth > 0 && imageHeight > 0)) return null;

    final minNumObsThr = stellaMinNumObsThr(_registeredFrameCount);

    // 参考那一半:上游走 ref_keyfrm 自己记录的路标表,不经过 can_observe。
    final refCounts = landmarkCountsForFrame(
      obsOffsets: offsets,
      obsFrameIds: frameIds,
      frameId: refFrameId,
      minNumObsThr: minNumObsThr,
    );

    // 候选收窄:局部地图(按参考帧当种子,见该模块偏离①)。
    if (_localMapRefFrameId != refFrameId || _localMap == null) {
      _localMap = acquireStellaLocalMap(
        obsOffsets: offsets,
        obsFrameIds: frameIds,
        seedFrameId: refFrameId,
      );
      _localMapRefFrameId = refFrameId;
    }

    // 当前视角:先把 ARKit 位姿搬进重建系,再按 can_observe 数。
    final current = currentPoseInReconFrame(
      reconRef: reconRef,
      arkitRef: arkitRefPose,
      arkitCurrent: arkitCurrentPose,
    );
    final counts = observableLandmarkCounts(
      table: table,
      rotCw: current.rotCw,
      transCw: current.transCw,
      fx: fx,
      fy: fy,
      cx: cx,
      cy: cy,
      minX: 0,
      maxX: imageWidth,
      minY: 0,
      maxY: imageHeight,
      minNumObsThr: minNumObsThr,
      selected: _localMap!.landmarkSelected,
    );

    return StellaMapEvidence(
      numTrackedLms: counts.tracked,
      numReliableLms: counts.reliable,
      numReliableLmsRef: refCounts.reliable,
      minNumObsThr: minNumObsThr,
      localKeyframeCount: _localMap!.keyframeIds.length,
      localLandmarkCount: _localMap!.selectedCount,
    );
  }
}
