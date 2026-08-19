// true_parallax.dart — 拍摄期"低视差"真值信号(route B)的纯 Dart 数学层。
//
// 背景(真机遥测实锤):route A 的视锥近似(CaptureCoverageCloud 的
// firstViewDir/maxParallaxDeg,"命中同一体素的视线夹角")判定过松两个
// 数量级 —— 5997 体素只 1 个 starved、98% 绿,而最终云 40.3% 的点真实
// 三角化角 <8°。黄框从不亮,引导闭环断裂。根因:视锥测试只证明"相机
// 看向了这个方向",不证明"同一特征点被两个角度真实观测到"。
//
// Route B:对流式 preview 云(previewTracked,ARKit gravity 世界系)逐点
// 算**真实三角化角** —— 该点 track 观测帧的相机中心对点的最大成对夹角,
// 与 COLMAP FilterPoints3DWithSmallTriangulationAngle 同语义(也与
// sfm_live_recon 的 finalize 后【geom】遥测 _triAngleTelemetry 同式)。
// 相机中心来自喂帧时的 ARKit CamFromWorld(与 preview 点同一世界系)。
//
// 聚合成两路引导信号:
//   ① 帧级:每帧观测点的角度中位数 → photo_card_state 判黄的真值输入;
//   ② 体素级:点世界坐标 → 覆盖云 voxel key → 体素真实视差中位数
//      (CaptureCoverageCloud.applyTrueParallax 注入,压黄逻辑改用真值,
//      视锥近似只在真值未到达时兜底)。
//
// 本文件零 Flutter 依赖(dart:math/typed_data + 同层纯文件),在 SfM
// worker isolate 上跑(节流 ≥3.5s,采样封顶),tool/true_parallax_check.dart
// 用纯 Dart VM 构造已知几何直接断言。

import 'dart:math' as math;
import 'dart:typed_data';

import 'photo_card_state.dart' show medianOf;

/// 覆盖云单一体素边长(米)。CaptureCoverageCloud 的默认值与 worker 侧
/// 体素聚合共用这一常量 —— 两边的 voxel key 必须逐位一致才能对上。
const double kCoverageVoxelSizeM = 0.04;

/// 视差下限(度)。2026-07-11 真机标定:低于此角的观测是"低视差深度噪声壳"
/// (双墙)的成因,不算有效双视角。
///
/// **单一出处**。此前 `CaptureCoverageCloud.parallaxMinDeg` 的构造默认值与
/// `kAutoCaptureParallaxMinDeg` 是两个各自写死的 `5.0`,而后者的注释宣称
/// 「同源同值……不新造常数」—— 那句话当时不是代码保证的事实,下一次重标定
/// 只会改到其中一个。〔2026-08-19 评审改正〕
const double kCaptureParallaxMinDeg = 5.0;

/// 覆盖云 voxel key(与 CaptureCoverageCloud._key 同一函数,后者委托到
/// 这里):21-bit 车道 + 0x100000 偏移容负数(±42 km @ 4 cm,远超任何
/// 拍摄空间)。
int coverageVoxelKeyFor(double x, double y, double z, double voxelSizeM) {
  final xi = (x / voxelSizeM).floor();
  final yi = (y / voxelSizeM).floor();
  final zi = (z / voxelSizeM).floor();
  return ((xi + 0x100000) << 42) | ((yi + 0x100000) << 21) | (zi + 0x100000);
}

/// CamFromWorld(四元数 [w,x,y,z] + 平移 [tx,ty,tz])→ 相机中心 C = -Rᵀt
/// (世界系)。四元数范数 ≈0(合成/降级 pose)→ null。
/// 与 sfm_live_recon._triAngleTelemetry 的中心恢复完全同式。
List<double>? cameraCenterFromCamFromWorld(
  List<double> quatWxyz,
  List<double> t,
) {
  if (quatWxyz.length < 4 || t.length < 3) return null;
  final qw = quatWxyz[0], qx = quatWxyz[1], qy = quatWxyz[2], qz = quatWxyz[3];
  final norm2 = qw * qw + qx * qx + qy * qy + qz * qz;
  if (norm2 < 1e-12) return null;
  final s = 1.0 / norm2;
  final tx = t[0], ty = t[1], tz = t[2];
  final r00 = 1 - 2 * s * (qy * qy + qz * qz);
  final r01 = 2 * s * (qx * qy - qz * qw);
  final r02 = 2 * s * (qx * qz + qy * qw);
  final r10 = 2 * s * (qx * qy + qz * qw);
  final r11 = 1 - 2 * s * (qx * qx + qz * qz);
  final r12 = 2 * s * (qy * qz - qx * qw);
  final r20 = 2 * s * (qx * qz - qy * qw);
  final r21 = 2 * s * (qy * qz + qx * qw);
  final r22 = 1 - 2 * s * (qx * qx + qy * qy);
  return [
    -(r00 * tx + r10 * ty + r20 * tz),
    -(r01 * tx + r11 * ty + r21 * tz),
    -(r02 * tx + r12 * ty + r22 * tz),
  ];
}

/// [trueParallaxAggregate] 的输出载体(worker → 主 isolate 的轻量事件
/// 'live_parallax' 原样携带这三个 TypedData)。
class TrueParallaxAggregate {
  const TrueParallaxAggregate({
    required this.framesPacked,
    required this.voxelKeys,
    required this.voxelDeg,
    required this.sampledPoints,
    required this.stride,
  });

  /// 帧级信号①:[frameId, 该帧观测点真实三角化角中位数(度)] ×2/帧,
  /// frameId 升序。~90 帧 <1.5KB。
  final Float64List framesPacked;

  /// 体素级信号②:voxel key(coverageVoxelKeyFor @ kCoverageVoxelSizeM)
  /// 与该体素内采样点真实三角化角的中位数(度),逐下标配对。
  final Int64List voxelKeys;
  final Float32List voxelDeg;

  /// 实际得出角度的采样点数(跨步采样 + 观测封顶后)。
  final int sampledPoints;
  final int stride;
}

/// 对 track 标注点云逐点算真实三角化角并聚合(纯函数,worker isolate 跑)。
///
/// 每点:track 观测帧 → [centersByFrame] 查相机中心(点与中心必须同一
/// 世界系),"点→各相机"射线两两夹角的最大值 = 该点三角化角。成本护栏:
/// 超过 [maxSample] 点跨步采样;每点最多取前 [maxObsPerPoint] 个有中心的
/// 观测(O(k²) 封顶 15 对)——与 finalize 后【geom】遥测同一护栏。
///
/// 帧级归因:点的角度计入其**所有**有中心的观测帧(角度是点的属性,
/// 观测到它的每一帧共享这份证据)。体素级归因:点坐标→voxel key。
/// 无点/观测数组损坏/可用相机 <2 → null(调用方不发事件,真值缺席,
/// 下游自然回退视锥近似)。
TrueParallaxAggregate? trueParallaxAggregate({
  required Float32List xyz,
  required Int32List obsOffsets,
  required Int32List obsFrameIds,
  required Map<int, List<double>> centersByFrame,
  double voxelSizeM = kCoverageVoxelSizeM,
  int maxSample = 10000,
  int maxObsPerPoint = 6,
}) {
  final n = xyz.length ~/ 3;
  if (n == 0 || obsOffsets.length != n + 1 || centersByFrame.length < 2) {
    return null;
  }
  final stride = n <= maxSample ? 1 : (n / maxSample).ceil();
  final frameAngles = <int, List<double>>{};
  final voxelAngles = <int, List<double>>{};
  var sampled = 0;
  final cams = <List<double>>[];
  final obsFids = <int>[];
  for (var i = 0; i < n; i += stride) {
    final start = obsOffsets[i];
    final end = obsOffsets[i + 1];
    if (start < 0 || end < start || end > obsFrameIds.length) return null;
    cams.clear();
    obsFids.clear();
    for (var j = start; j < end; j++) {
      final fid = obsFrameIds[j];
      final c = centersByFrame[fid];
      if (c == null) continue; // 帧无位姿(降级 extrinsic)→ 不参与
      obsFids.add(fid);
      if (cams.length < maxObsPerPoint) cams.add(c);
    }
    if (cams.length < 2) continue;
    final px = xyz[i * 3], py = xyz[i * 3 + 1], pz = xyz[i * 3 + 2];
    var best = 0.0;
    var pairs = 0;
    for (var a = 0; a < cams.length; a++) {
      final ax = cams[a][0] - px, ay = cams[a][1] - py, az = cams[a][2] - pz;
      final an = math.sqrt(ax * ax + ay * ay + az * az);
      if (an < 1e-12) continue; // 相机中心与点重合 → 射线退化
      for (var b = a + 1; b < cams.length; b++) {
        final bx = cams[b][0] - px, by = cams[b][1] - py, bz = cams[b][2] - pz;
        final bn = math.sqrt(bx * bx + by * by + bz * bz);
        if (bn < 1e-12) continue;
        final cosAng = ((ax * bx + ay * by + az * bz) / (an * bn)).clamp(
          -1.0,
          1.0,
        );
        final ang = math.acos(cosAng);
        pairs++;
        if (ang > best) best = ang;
      }
    }
    if (pairs == 0) continue; // 全部射线退化 → 该点无证据,不伪造 0°
    final deg = best * 180.0 / math.pi;
    sampled++;
    for (final fid in obsFids) {
      frameAngles.putIfAbsent(fid, () => <double>[]).add(deg);
    }
    voxelAngles
        .putIfAbsent(
          coverageVoxelKeyFor(px, py, pz, voxelSizeM),
          () => <double>[],
        )
        .add(deg);
  }
  if (sampled == 0) return null;

  final fids = frameAngles.keys.toList()..sort();
  final framesPacked = Float64List(fids.length * 2);
  for (var k = 0; k < fids.length; k++) {
    framesPacked[k * 2] = fids[k].toDouble();
    framesPacked[k * 2 + 1] = medianOf(frameAngles[fids[k]]!)!;
  }
  final vkeys = voxelAngles.keys.toList();
  final voxelKeys = Int64List(vkeys.length);
  final voxelDeg = Float32List(vkeys.length);
  for (var k = 0; k < vkeys.length; k++) {
    voxelKeys[k] = vkeys[k];
    voxelDeg[k] = medianOf(voxelAngles[vkeys[k]]!)!;
  }
  return TrueParallaxAggregate(
    framesPacked: framesPacked,
    voxelKeys: voxelKeys,
    voxelDeg: voxelDeg,
    sampledPoints: sampled,
    stride: stride,
  );
}
