// auto_capture_geometry.dart — 自动采集的纯几何判据(零 Flutter 依赖)。
//
// 这一层只做数学,不知道"拍照"是什么。决策在 auto_capture_governor.dart。
//
// 相机约定与 ARKit / ARCore 一致:相机看向自身坐标系的 -Z,+X 右、+Y 上。
// 内参与特征点都由 ARPose 现成提供(intrinsicFxFyCxCy / previewPoints),
// 本文件不需要任何 native 改动。

import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../official_dome/ar_pose.dart';
import 'photo_card_state.dart' show medianOf;

/// 估计场景中位深度所需的最少特征点数。低于此数认为深度不可信。
/// 与 capture_session 的 `_minScaleAlignAnchorsForPersistedFrame` 同量级。
const int kAutoCaptureMinDepthAnchors = 8;

const double _radToDeg = 180.0 / math.pi;

/// 场景中位深度(米)。把每个特征点投到光轴上取正深度的中位数。
/// 有效点少于 [kAutoCaptureMinDepthAnchors] 时返回 null(调用方须降级)。
double? medianSceneDepthM({
  required Vector3 cameraPosition,
  required Vector3 forward,
  required List<ARPreviewPoint> points,
}) {
  final axis = forward.normalized();
  final depths = <double>[];
  for (final p in points) {
    final d = (p.position - cameraPosition).dot(axis);
    if (d > 0 && d.isFinite) depths.add(d);
  }
  if (depths.length < kAutoCaptureMinDepthAnchors) return null;
  return medianOf(depths);
}

/// 两个相机中心在 [target] 处张开的夹角(度)= 视差角。
///
/// 这是"移动够不够"的判据,**不能**用相机中心间的欧氏距离代替:
/// 沿光轴前进时三点共线,距离不为零而视差 ≈ 0 —— 那正是双墙成因。
double parallaxAngleDeg({
  required Vector3 baseCamera,
  required Vector3 currentCamera,
  required Vector3 target,
}) {
  final a = baseCamera - target;
  final b = currentCamera - target;
  final la = a.length;
  final lb = b.length;
  if (la < 1e-9 || lb < 1e-9) return 0;
  final cos = (a.dot(b) / (la * lb)).clamp(-1.0, 1.0);
  return math.acos(cos) * _radToDeg;
}

/// 两条光轴之间的夹角(度)。纯旋转时视差恒为 0,只能靠这个量。
double viewAxisTurnDeg({
  required Vector3 baseForward,
  required Vector3 currentForward,
}) {
  final la = baseForward.length;
  final lb = currentForward.length;
  if (la < 1e-9 || lb < 1e-9) return 0;
  final cos = (baseForward.dot(currentForward) / (la * lb)).clamp(-1.0, 1.0);
  return math.acos(cos) * _radToDeg;
}

/// [target] 投影到当前帧后的**面积重叠损失**:
///
///     sx = |u| / imageWidth,  sy = |v| / imageHeight
///     s  = sx + sy - sx*sy    ( = 1 - (1-sx)(1-sy) )
///
/// `s >= 0.30` 即与基准帧的**面积**重叠 <= 70%。
///
/// 两轴的重叠损失是**相乘**的,不是取大的。早先用 `max(sx, sy)` 只看更差的
/// 那一轴、把另一轴的损失整个丢掉,于是斜向运动被系统性低估、R2 被系统性
/// 推迟:45 度斜向要到真实面积重叠掉到 49% 才触发,比 RealityScan 官方下限
/// 60% 还低。而"绕物平移的同时抬高/压低手机"正是这种轨迹。
/// 面积口径在纯横移时退化成 sx、纯纵移时退化成 sy,标定数字逐位不变。
///
/// 目标跑到相机背后或深度非正时返回 [double.infinity];
/// 内参/画幅不可用时返回 **null**(见下)。
double? normalizedCenterShift({
  required Vector3 target,
  required Vector3 currentCamera,
  required Quaternion currentOrientation,
  required double fx,
  required double fy,
  required int imageWidth,
  required int imageHeight,
}) {
  if (fx <= 0 || fy <= 0 || imageWidth <= 0 || imageHeight <= 0) {
    // ⚠️ 返回 null 而不是 +inf。+inf >= 0.30,会被上层的 R2 读成"立刻拍" ——
    // 那等于把"不知道"编码成"马上开火"。null 让调用方走 spec §7 的降级路径
    // (只用下限判据),与"拿不到场景深度"同一套路。
    return null;
  }
  // 世界系 → 当前相机系
  final rel = target - currentCamera;
  final cam = currentOrientation.inverted().rotated(rel);
  final depth = -cam.z; // 相机看向 -Z
  if (depth <= 1e-6 || !depth.isFinite) return double.infinity;
  final uPx = fx * (cam.x / depth);
  final vPx = fy * (cam.y / depth);
  final sx = uPx.abs() / imageWidth;
  final sy = vPx.abs() / imageHeight;
  return sx + sy - sx * sy;
}
