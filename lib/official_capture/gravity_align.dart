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
  if (xyz.isEmpty) return null;
  final q = gravityAlignQuatWxyz(
    posesPacked: posesPacked,
    arkitQuatWxyzOf: arkitQuatWxyzOf,
  );
  if (q == null) return null;
  return rotatePointsByQuatWxyz(xyz, q);
}

/// [GRAV-CONSIST 2026-07-28] 均值 R_w 四元数本体([w,x,y,z],把 raw-COLMAP
/// 世界带到重力世界)。从 [gravityAlignedPoints] 原地拆出(数学一字未改,
/// 单一来源防漂移):调用方由此可"整模型一致变换 + 记录所施加变换"
/// (COLMAP `Reconstruction::Transform` 语义 + nerfstudio
/// dataparser_transforms.json 先例;行业查无"只转点不转位姿"的先例)。
/// 证据不足(已注册且带 ARKit 四元数的帧 <3)或退化时返回 null。
List<double>? gravityAlignQuatWxyz({
  required Float64List posesPacked,
  required List<double>? Function(int frameId) arkitQuatWxyzOf,
}) {
  final poses = posesPacked;
  if (poses.isEmpty) return null;

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
  return [aw / an, ax / an, ay / an, az / an];
}

/// [SCALE-ANCHOR 2026-07-28] 交付模型的米制尺度重锚:BA 后模型相对 ARKit
/// 的全局 scale 每 capture 偏 ±4%(35 run 实测钉死 ±0.5% 内可复现)。
/// 单目重投影对全局 scale 严格不可观测(Triggs gauge orbit;Strasdat
/// RSS'10),BA 的 scale 是无锚 gauge 滑移不是测量;ARKit 是 IMU+LiDAR
/// 物理测量(公开评测室内 ~0.3-1%)⇒ 锚回 ARKit。裁决档
/// `_host_fixtures/pose_drift_audit/SCALE_VERDICT.md`。
///
/// 估计:s = median_i(|c_ark_i − centroid_ark| / |c_ba_i − centroid_ba|)
/// (质心距比,逐帧中位数 —— 对离群帧鲁棒且 O(n) 确定性;scale 与旋转
/// 无关,原始/对齐后的中心算出来相同)。应用:x' = s·x,t' = s·t,R 不动
/// —— 相似变换,x_cam' = s·x_cam,针孔投影 u = fx·x/z 中 s 消去,
/// **全部重投影残差严格不变**(模型质量零扰动,变的只是坐标刻度)。
///
/// 证据不足(配对帧 <3)、比值退化(非有限/非正)、或 s 离 1 太远
/// (>15%,防 ARKit 位姿本身坏掉的采集)时返回 null —— 调用方不缩放,
/// 保持现状交付(fail-open,契约同 gravityAlignQuatWxyz)。
double? scaleAnchorFactor({
  required Float64List posesPacked,
  required List<double>? Function(int frameId) arkitCenterWorldOf,
}) {
  final poses = posesPacked;
  if (poses.isEmpty) return null;

  final baC = <List<double>>[];
  final arkC = <List<double>>[];
  for (var i = 0; i < poses.length; i += 9) {
    if (poses[i + 1] == 0) continue; // unregistered
    final ac = arkitCenterWorldOf(poses[i].toInt());
    if (ac == null || ac.length != 3) continue;
    final w = poses[i + 2], x = poses[i + 3], y = poses[i + 4], z = poses[i + 5];
    final n2 = w * w + x * x + y * y + z * z;
    if (n2 < 1e-12) continue; // synthetic all-zero quat (connectivity)
    // center = -R^T·t for CamFromWorld (R from quat, t = poses[i+6..8]).
    final tx = poses[i + 6], ty = poses[i + 7], tz = poses[i + 8];
    // R^T rows == R columns; R from unit quat (normalize by n2 for safety).
    final r00 = 1 - 2 * (y * y + z * z) / n2,
        r01 = 2 * (x * y - z * w) / n2,
        r02 = 2 * (x * z + y * w) / n2;
    final r10 = 2 * (x * y + z * w) / n2,
        r11 = 1 - 2 * (x * x + z * z) / n2,
        r12 = 2 * (y * z - x * w) / n2;
    final r20 = 2 * (x * z - y * w) / n2,
        r21 = 2 * (y * z + x * w) / n2,
        r22 = 1 - 2 * (x * x + y * y) / n2;
    baC.add([
      -(r00 * tx + r10 * ty + r20 * tz),
      -(r01 * tx + r11 * ty + r21 * tz),
      -(r02 * tx + r12 * ty + r22 * tz),
    ]);
    arkC.add(ac);
  }
  if (baC.length < 3) return null;

  List<double> centroid(List<List<double>> pts) {
    var cx = 0.0, cy = 0.0, cz = 0.0;
    for (final p in pts) {
      cx += p[0];
      cy += p[1];
      cz += p[2];
    }
    final n = pts.length.toDouble();
    return [cx / n, cy / n, cz / n];
  }

  final cb = centroid(baC), ca = centroid(arkC);
  final ratios = <double>[];
  for (var i = 0; i < baC.length; i++) {
    final db = math.sqrt(
      math.pow(baC[i][0] - cb[0], 2) +
          math.pow(baC[i][1] - cb[1], 2) +
          math.pow(baC[i][2] - cb[2], 2),
    );
    final da = math.sqrt(
      math.pow(arkC[i][0] - ca[0], 2) +
          math.pow(arkC[i][1] - ca[1], 2) +
          math.pow(arkC[i][2] - ca[2], 2),
    );
    if (db > 1e-6 && da.isFinite && da > 0) ratios.add(da / db);
  }
  if (ratios.length < 3) return null;
  ratios.sort();
  final s = ratios[ratios.length ~/ 2];
  if (!s.isFinite || s <= 0) return null;
  if ((s - 1.0).abs() > 0.15) return null; // ARKit 位姿可疑,不冒险
  return s;
}

/// [SCALE-ANCHOR] 把 s 应用到 posesPacked:t' = s·t(R 不动;见上方推导,
/// 相似变换下 CamFromWorld 的平移分量按 s 缩放)。未注册帧原样透传。
Float64List scaleAnchoredPosesPacked(Float64List posesPacked, double s) {
  final out = Float64List.fromList(posesPacked);
  for (var i = 0; i < out.length; i += 9) {
    if (out[i + 1] == 0) continue;
    out[i + 6] *= s;
    out[i + 7] *= s;
    out[i + 8] *= s;
  }
  return out;
}

/// [SCALE-ANCHOR] 把 s 应用到点云:x' = s·x。
Float32List scaleAnchoredPoints(Float32List xyz, double s) {
  final out = Float32List(xyz.length);
  for (var i = 0; i < xyz.length; i++) {
    out[i] = xyz[i] * s;
  }
  return out;
}

/// 把点云按 R_w([q] = [w,x,y,z])旋转:x' = R_w·x。数学与旧
/// [gravityAlignedPoints] 内联段逐字相同(单一来源化拆出)。
Float32List rotatePointsByQuatWxyz(Float32List xyz, List<double> q) {
  final w = q[0], x = q[1], y = q[2], z = q[3];
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

/// [GRAV-CONSIST 2026-07-28] 把 R_w(=[qAlign],wxyz)按 COLMAP
/// `TransformCameraWorld` 语义作用到 CamFromWorld 位姿上:
///   世界变换 x' = R·x ⇒ C' = C∘R⁻¹ ⇒ q' = q ⊗ conj(qAlign),t' = t
/// (纯旋转、绕原点,平移分量在相机系,不变)。自检:代入任一点
/// C'(R·x) == C(x) 恒等。未注册帧(registered==0)原样透传;
/// 全 0 合成四元数不受影响(乘完仍全 0,契约同 SfmLiveConnectivity)。
Float64List gravityAlignedPosesPacked(
  Float64List posesPacked,
  List<double> qAlign,
) {
  final out = Float64List.fromList(posesPacked);
  final cw = qAlign[0], cx = -qAlign[1], cy = -qAlign[2], cz = -qAlign[3];
  for (var i = 0; i < out.length; i += 9) {
    if (out[i + 1] == 0) continue; // unregistered: leave verbatim
    final w = out[i + 2], x = out[i + 3], y = out[i + 4], z = out[i + 5];
    // q' = q ⊗ conj(qAlign)  (Hamilton)
    out[i + 2] = w * cw - x * cx - y * cy - z * cz;
    out[i + 3] = w * cx + x * cw + y * cz - z * cy;
    out[i + 4] = w * cy - x * cz + y * cw + z * cx;
    out[i + 5] = w * cz + x * cy - y * cx + z * cw;
    // t unchanged: rotation-only world transform about the origin keeps the
    // camera-frame translation component of CamFromWorld intact.
  }
  return out;
}
