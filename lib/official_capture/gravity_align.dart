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

/// [GRAV-DIAG 2026-07-30] 为什么重力对齐这一帧没生效。
///
/// 病因(用户实机发现,而不是遥测发现):[gravityAlignQuatWxyz] 返回 null 时
/// `_gravityAlign` 是 fail-open —— 直接交付**未对齐**的点云,而且不记日志、
/// 不发遥测。于是"编辑页里的点云是歪的"这种用户可见缺陷在日志里完全无痕,
/// 只能事后翻 `official_sfm_sparse_meta.json` 的 `gravity_align_quat_wxyz`
/// 是不是 null 才能知道。
///
/// fail-open 本身要保留(交付一朵歪云胜过不交付),但**静默**必须去掉:三个
/// null 分支的成因完全不同、修法也完全不同,所以诊断必须能区分它们,否则
/// 下一次仍然只能靠猜。
class GravityAlignDiagV1 {
  /// 已注册(有位姿)的帧数。
  int registeredFrames = 0;

  /// 其中能拿到 ARKit 四元数的帧数。`_fedMeta` 是内存态,resume/重启后为空。
  int framesWithArkitQuat = 0;

  /// [cnt < 3] 门的阈值,一并落盘,免得日后改了门槛而旧遥测无法解释。
  int requiredFrames = 3;

  /// null = 对齐成功。否则是下面三个常量之一。
  String? skipReason;

  /// 一个位姿都没有 —— 通常是空重建。
  static const String reasonNoPoses = 'no_poses';

  /// 证据不足:拿到 ARKit 四元数的帧 < 3。**resume/重启路径的典型表现。**
  static const String reasonNotEnoughArkitQuats = 'not_enough_arkit_quats';

  /// 逐帧 R_w 互相抵消,平均四元数退化 —— 位姿或四元数本身可疑。
  static const String reasonDegenerateAverage = 'degenerate_average';

  Map<String, Object?> toTelemetry() => <String, Object?>{
    'registered_frames': registeredFrames,
    'frames_with_arkit_quat': framesWithArkitQuat,
    'required_frames': requiredFrames,
    'skip_reason': skipReason,
  };
}

/// [SCALE-DIAG 2026-07-30] 为什么米制尺度锚定这一帧没生效。
///
/// 与 [GravityAlignDiagV1] 同一个动机,但这里更要紧:SCALE-ANCHOR **已经是生产
/// 开启的臂**(plugin 里 `OFFICIAL_AETHER_SCALE_ANCHOR=1`),而它有五个 fail-open
/// 分支,全部静默。也就是说交付物的尺度可能压根没被锚回米制,而没有任何信号。
///
/// 五个分支里有一个不是"数据不够",而是**实测到了尺度失配却拒绝施加**
/// ([reasonOutOfBand],|s−1| > 15%)。已记录的 BA gauge 漂移是 ±4~10.6%,所以
/// 一次 >15% 的拒绝是真实异常信号,必须带上被拒的 s 值上报,否则等于把测量结果
/// 丢掉了。
class ScaleAnchorDiagV1 {
  /// 已注册(有位姿)的帧数。
  int registeredFrames = 0;

  /// 其中能配上 ARKit 相机中心的帧数。`_fedMeta` 是内存态。
  int pairsWithArkitCenter = 0;

  /// 通过退化门(db>1e-6 且 da 有限为正)、真正参与中位数的比值个数。
  int usableRatios = 0;

  /// 两个 `< 3` 门的阈值,一并落盘,便于日后改门也能解释旧数据。
  int requiredPairs = 3;

  /// 算出来但被拒绝的 s(仅 [reasonNonFiniteScale] / [reasonOutOfBand] 时非 null)。
  /// **这是本诊断最有价值的字段** —— 它把"拒绝施加"和"量不出来"彻底分开。
  double? rejectedFactor;

  /// null = 锚定成功。
  String? skipReason;

  static const String reasonNoPoses = 'no_poses';

  /// 能配上 ARKit 中心的帧 < 3 —— resume/重启路径的典型表现。
  static const String reasonNotEnoughPairs = 'not_enough_pairs';

  /// 配对够但比值几乎全退化(相机几乎不动 / 全挤在质心)。
  static const String reasonNotEnoughRatios = 'not_enough_ratios';

  /// 中位比值非有限或非正。
  static const String reasonNonFiniteScale = 'non_finite_scale';

  /// |s−1| > 15%:量出来了,但超出信任带,**主动拒绝**而不是失败。
  static const String reasonOutOfBand = 'scale_out_of_band';

  Map<String, Object?> toTelemetry() => <String, Object?>{
    'registered_frames': registeredFrames,
    'pairs_with_arkit_center': pairsWithArkitCenter,
    'usable_ratios': usableRatios,
    'required_pairs': requiredPairs,
    'rejected_factor': rejectedFactor,
    'skip_reason': skipReason,
  };
}

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
  GravityAlignDiagV1? diag,
}) {
  final poses = posesPacked;
  if (poses.isEmpty) {
    diag?.skipReason = GravityAlignDiagV1.reasonNoPoses;
    return null;
  }

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
    if (diag != null) diag.registeredFrames++;
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
  // [GRAV-DIAG] framesWithArkitQuat 记的是**通过了 norm 门、真正参与平均**的
  // 帧数(cnt),不是"有四元数的帧数" —— 后者会把退化四元数也算进去,让
  // not_enough 和 degenerate 两种成因混在一个数里。
  if (diag != null) diag.framesWithArkitQuat = cnt;
  if (cnt < 3) {
    diag?.skipReason = GravityAlignDiagV1.reasonNotEnoughArkitQuats;
    return null; // not enough evidence — don't risk a bad tilt
  }

  final an = math.sqrt(aw * aw + ax * ax + ay * ay + az * az);
  if (an < 1e-9) {
    diag?.skipReason = GravityAlignDiagV1.reasonDegenerateAverage;
    return null;
  }
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
  ScaleAnchorDiagV1? diag,
}) {
  final poses = posesPacked;
  if (poses.isEmpty) {
    diag?.skipReason = ScaleAnchorDiagV1.reasonNoPoses;
    return null;
  }

  final baC = <List<double>>[];
  final arkC = <List<double>>[];
  for (var i = 0; i < poses.length; i += 9) {
    if (poses[i + 1] == 0) continue; // unregistered
    if (diag != null) diag.registeredFrames++;
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
  // [SCALE-DIAG] pairsWithArkitCenter 记的是**通过了全部前置门**(有 ARKit 中心
  // 且四元数非全零)、真正进入配对集的帧数,不是"有中心的帧数"。
  if (diag != null) diag.pairsWithArkitCenter = baC.length;
  if (baC.length < 3) {
    diag?.skipReason = ScaleAnchorDiagV1.reasonNotEnoughPairs;
    return null;
  }

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
  if (diag != null) diag.usableRatios = ratios.length;
  if (ratios.length < 3) {
    diag?.skipReason = ScaleAnchorDiagV1.reasonNotEnoughRatios;
    return null;
  }
  ratios.sort();
  final s = ratios[ratios.length ~/ 2];
  if (!s.isFinite || s <= 0) {
    diag
      ?..rejectedFactor = s
      ..skipReason = ScaleAnchorDiagV1.reasonNonFiniteScale;
    return null;
  }
  if ((s - 1.0).abs() > 0.15) {
    // ARKit 位姿可疑,不冒险 —— 但**把量到的 s 报出去**:已记录的 gauge 漂移是
    // ±4~10.6%,一次 >15% 的拒绝是真实异常,丢掉这个数就等于丢掉证据。
    diag
      ?..rejectedFactor = s
      ..skipReason = ScaleAnchorDiagV1.reasonOutOfBand;
    return null;
  }
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
