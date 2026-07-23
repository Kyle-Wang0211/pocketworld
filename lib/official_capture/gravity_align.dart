// gravity_align.dart — 重力对齐纯函数(live 主路径与断点续跑共用同一实现)。
//
// 从 SfmLiveRecon._gravityAlign 逐字提出(2026-07-10,resume 对齐战役):
// 数学与门限一字未改,facade 现在只是薄包装;断点续跑(sfm_resume.dart)
// 通过回填 _fedMeta 走同一条调用链。本文件零 Flutter 依赖
// (dart:math + dart:typed_data),纯 Dart VM 断言脚本
// tool/gravity_align_check.dart 用已知 ARKit+COLMAP pose 对直接驱动。
//
// 语义(照抄原 doc):COLMAP 的世界规约是任意的 —— 点云以随机姿态歪着
// 出来。ARKit 以 worldAlignment=.gravity 运行(世界 +Y = 天),每个已注册
// 帧配有 ARKit CamFromWorld。对每帧,
//   R_w = R_ark^T · C · R_col
// 是把 COLMAP 世界带到 ARKit(重力)世界的旋转;各帧估计高度聚簇(同一
// 刚性对齐),符号对齐后的朴素四元数均值足够稳健。所有点按均值 R_w 旋转,
// 使地面水平、+Y 朝上 —— viewer 无需任意默认倾角。只旋转点(poses 保持
// COLMAP 原样;下游没有人把它们与已对齐的点配对)。

import 'dart:math' as math;
import 'dart:typed_data';

/// 把 [xyz](COLMAP 世界)旋进 ARKit 重力世界(+Y 朝上)。
///
/// [posesPacked] 契约同 SfmLiveSnapshot.posesPacked(9 double/帧:
/// [frameId, registered, qw,qx,qy,qz, tx,ty,tz],CamFromWorld);
/// [arkitQuatWxyzOf] 按 frameId 提供该帧 ARKit CamFromWorld 四元数
/// [w,x,y,z](无则返回 null,该帧跳过)。
///
/// 返回旋转后的新 Float32List;证据不足(已注册且带 ARKit 四元数的帧
/// <3 个)或任何退化时返回 null —— 调用方保持原点云,不冒错误倾角的险。
/// 合成连通性 poses(四元数全 0)会被 norm 门自然跳过(刻意,契约见
/// SfmLiveConnectivity)。
Float32List? gravityAlignedPoints({
  required Float32List xyz,
  required Float64List posesPacked,
  required List<double>? Function(int frameId) arkitQuatWxyzOf,
}) {
  final poses = posesPacked;
  if (xyz.isEmpty || poses.isEmpty) return null;

  // Hamilton product a*b (w,x,y,z).
  List<double> qmul(List<double> a, List<double> b) => [
    a[0] * b[0] - a[1] * b[1] - a[2] * b[2] - a[3] * b[3],
    a[0] * b[1] + a[1] * b[0] + a[2] * b[3] - a[3] * b[2],
    a[0] * b[2] - a[1] * b[3] + a[2] * b[0] + a[3] * b[1],
    a[0] * b[3] + a[1] * b[2] - a[2] * b[1] + a[3] * b[0],
  ];

  var aw = 0.0, ax = 0.0, ay = 0.0, az = 0.0;
  List<double>? ref;
  var cnt = 0;
  for (var i = 0; i < poses.length; i += 9) {
    if (poses[i + 1] == 0) continue; // unregistered
    final aq = arkitQuatWxyzOf(poses[i].toInt());
    if (aq == null || aq.length != 4) continue;
    final qCol = [poses[i + 2], poses[i + 3], poses[i + 4], poses[i + 5]];
    final qArkConj = [aq[0], -aq[1], -aq[2], -aq[3]]; // R_ark^T
    // C = diag(1,-1,-1): ARKit camera looks along -Z with +Y up; COLMAP
    // looks along +Z with +Y down. Without this fixed camera-convention
    // flip the per-frame R_w estimates scatter ~33° (validated on real
    // capture data); with it they cluster to <2°. C = 180° about X = qC.
    const qC = [0.0, 1.0, 0.0, 0.0];
    var qw = qmul(qArkConj, qmul(qC, qCol)); // R_w = R_ark^T · C · R_col
    final norm = math.sqrt(
      qw[0] * qw[0] + qw[1] * qw[1] + qw[2] * qw[2] + qw[3] * qw[3],
    );
    if (norm < 1e-9) continue;
    qw = [qw[0] / norm, qw[1] / norm, qw[2] / norm, qw[3] / norm];
    ref ??= qw;
    // Sign-align to the reference hemisphere before summing.
    final dot =
        qw[0] * ref[0] + qw[1] * ref[1] + qw[2] * ref[2] + qw[3] * ref[3];
    final s = dot < 0 ? -1.0 : 1.0;
    aw += s * qw[0];
    ax += s * qw[1];
    ay += s * qw[2];
    az += s * qw[3];
    cnt++;
  }
  if (cnt < 3) return null; // not enough evidence — don't risk a bad tilt

  final an = math.sqrt(aw * aw + ax * ax + ay * ay + az * az);
  if (an < 1e-9) return null;
  final w = aw / an, x = ax / an, y = ay / an, z = az / an;
  // Rotation matrix rows for the mean R_w.
  final r00 = 1 - 2 * (y * y + z * z),
      r01 = 2 * (x * y - z * w),
      r02 = 2 * (x * z + y * w);
  final r10 = 2 * (x * y + z * w),
      r11 = 1 - 2 * (x * x + z * z),
      r12 = 2 * (y * z - x * w);
  final r20 = 2 * (x * z - y * w),
      r21 = 2 * (y * z + x * w),
      r22 = 1 - 2 * (x * x + y * y);

  final src = xyz;
  final out = Float32List(src.length);
  for (var i = 0; i < src.length; i += 3) {
    final px = src[i], py = src[i + 1], pz = src[i + 2];
    out[i] = r00 * px + r01 * py + r02 * pz;
    out[i + 1] = r10 * px + r11 * py + r12 * pz;
    out[i + 2] = r20 * px + r21 * py + r22 * pz;
  }
  return out;
}
