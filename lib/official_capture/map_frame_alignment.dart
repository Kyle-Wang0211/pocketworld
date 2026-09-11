// map_frame_alignment.dart — 把**当前预览帧的 ARKit 位姿**放到重建(BA)坐标系里。
//
// 🔴 解耦纪律:本文件只做坐标变换。不 import governor、不 import 跟踪器、
// 不 import Flutter、不持有状态、不知道什么是快门。
//
// ── 为什么需要它 ────────────────────────────────────────────────────
// 上游 stella 的 `num_reliable_lms` 是拿**当前帧的位姿**去看地图路标的。
// 我们的当前帧是预览帧,它只有 ARKit 位姿,从不进重建;而地图点与已注册
// 帧的位姿都在重建自己的坐标系里。两者必须先对齐。
//
// ── 为什么不拟合 Sim(3) ─────────────────────────────────────────────
// 核里已经有一份 `SummarizeLiveCloudArkitBaSim3V2`
// (official_pipeline/src/live_cloud_diagnostics_v1.h:221),每个发布边界
// 用 Umeyama + MAD 内点重拟一次,结果无条件写进 `sfm_match_fail.jsonl`。
// 我读了它的全文,**没有照搬**,理由是照搬要在 Dart 里自己写 3×3 SVD ——
// 那是一段没有上游可抄的数值代码,写错了还不会报错,只会给出看起来合理的
// 位姿。改用一条**精确、无拟合**的路:
//
//     T_ba(current) = T_ba(ref) ∘ T_arkit(ref)⁻¹ ∘ T_arkit(current)
//
// 参考帧(上一张照片)在两个坐标系里都有位姿:BA 那份来自重建快照的
// `posesPacked`,ARKit 那份是快门那一刻记下的。用这一对就能把"自上一张
// 以来的相对运动"搬进 BA 系。旋转部分**精确**,不含任何拟合或阈值。
//
// ── 唯一的假设,以及它的实测值(不是我定的数)─────────────────────
// 平移部分假设两个坐标系**尺度相同**。核自己的诊断给了这个数:
// 未命名(10) 一场 38 条记录 ——
//     arkit_to_ba_scale        中位 1.00591(0.9787 – 1.0159)
//     ba_to_arkit_rotation_deg 中位 0.595°,最大 2.34°
//     residual_p50_m           中位 4.2 mm;residual_all_max_m 中位 12.5 mm
// 即 ±2% 尺度。相邻两张照片之间位移约 0.22 m,2% = **4 mm**;而判据数的是
// 4032 px 图里的路标,4 mm 在 0.85 m 深度上约合画面的 0.5%。
// 这个假设是**有实测、有量级**的,不是随手取的常数;它失效时(比如尺度
// 锚定被打开、或重建规范漂了)表现为投影计数系统性偏移,应当由调用方
// 用核那条 sim3 诊断复核,而不是在这里猜。
library;

import 'dart:math' as math;

/// 一个刚体位姿。约定与上游 `posesPacked` 一致:**CamFromWorld**,
/// 即 `x_cam = R_cw · x_world + t_cw`。
class CamFromWorldPose {
  const CamFromWorldPose({required this.rotCw, required this.transCw});

  /// 行主序 3×3。
  final List<double> rotCw;
  final List<double> transCw;

  /// 相机中心(世界坐标)= -R_cwᵀ · t_cw。
  List<double> get cameraCentre => <double>[
    -(rotCw[0] * transCw[0] + rotCw[3] * transCw[1] + rotCw[6] * transCw[2]),
    -(rotCw[1] * transCw[0] + rotCw[4] * transCw[1] + rotCw[7] * transCw[2]),
    -(rotCw[2] * transCw[0] + rotCw[5] * transCw[1] + rotCw[8] * transCw[2]),
  ];
}

/// 四元数(w,x,y,z)→ 行主序 3×3 旋转矩阵。
List<double> rotationFromQuatWxyz(double w, double x, double y, double z) {
  final n = math.sqrt(w * w + x * x + y * y + z * z);
  if (!(n > 0)) return <double>[1, 0, 0, 0, 1, 0, 0, 0, 1];
  final qw = w / n, qx = x / n, qy = y / n, qz = z / n;
  final xx = qx * qx, yy = qy * qy, zz = qz * qz;
  return <double>[
    1 - 2 * (yy + zz), 2 * (qx * qy - qz * qw), 2 * (qx * qz + qy * qw),
    2 * (qx * qy + qz * qw), 1 - 2 * (xx + zz), 2 * (qy * qz - qx * qw),
    2 * (qx * qz - qy * qw), 2 * (qy * qz + qx * qw), 1 - 2 * (xx + yy),
  ];
}

List<double> _matMul(List<double> a, List<double> b) => <double>[
  for (var r = 0; r < 3; r++)
    for (var c = 0; c < 3; c++)
      a[r * 3] * b[c] + a[r * 3 + 1] * b[3 + c] + a[r * 3 + 2] * b[6 + c],
];

List<double> _matT(List<double> m) =>
    <double>[m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]];

List<double> _matVec(List<double> m, List<double> v) => <double>[
  m[0] * v[0] + m[1] * v[1] + m[2] * v[2],
  m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
  m[6] * v[0] + m[7] * v[1] + m[8] * v[2],
];

/// 把当前预览帧的 ARKit 位姿搬进 BA 坐标系。
///
///     T_ba(cur) = T_ba(ref) ∘ T_arkit(ref)⁻¹ ∘ T_arkit(cur)
///
/// 用 CamFromWorld 展开(R = R_cw,t = t_cw):
///     R_rel = R_arkit(cur) · R_arkit(ref)ᵀ            相机自参考以来的相对旋转
///     R_ba(cur) = R_rel · R_ba(ref)
///     C_ba(cur) = C_ba(ref) + R_ba(ref)ᵀ · R_arkit(ref) · (C_ark(cur) - C_ark(ref))
///     t_ba(cur) = -R_ba(cur) · C_ba(cur)
///
/// 位移那一行是唯一吃"两系同尺度"假设的地方(见文件头)。
CamFromWorldPose currentPoseInReconFrame({
  required CamFromWorldPose reconRef,
  required CamFromWorldPose arkitRef,
  required CamFromWorldPose arkitCurrent,
}) {
  final rRel = _matMul(arkitCurrent.rotCw, _matT(arkitRef.rotCw));
  final rBaCur = _matMul(rRel, reconRef.rotCw);

  final cArkRef = arkitRef.cameraCentre;
  final cArkCur = arkitCurrent.cameraCentre;
  final dArk = <double>[
    cArkCur[0] - cArkRef[0],
    cArkCur[1] - cArkRef[1],
    cArkCur[2] - cArkRef[2],
  ];
  // 把 ARKit 世界里的位移搬到 BA 世界:先转进参考相机的相机系,再转出去。
  final dInRefCam = _matVec(arkitRef.rotCw, dArk);
  final dBa = _matVec(_matT(reconRef.rotCw), dInRefCam);
  final cBaRef = reconRef.cameraCentre;
  final cBaCur = <double>[
    cBaRef[0] + dBa[0],
    cBaRef[1] + dBa[1],
    cBaRef[2] + dBa[2],
  ];
  final tBaCur = _matVec(rBaCur, cBaCur);
  return CamFromWorldPose(
    rotCw: rBaCur,
    transCw: <double>[-tBaCur[0], -tBaCur[1], -tBaCur[2]],
  );
}
