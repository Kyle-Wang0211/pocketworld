// auto_capture_geometry.dart — 自动采集的纯几何判据(零 Flutter 依赖)。
//
// 这一层只做数学,不知道"拍照"是什么。决策在 auto_capture_governor.dart。
//
// 相机约定与 ARKit / ARCore 一致:相机看向自身坐标系的 -Z,+X 右、+Y 上。
// 内参与特征点都由 ARPose 现成提供(intrinsicFxFyCxCy / previewPoints),
// 本文件不需要任何 native 改动。

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

import '../official_dome/ar_pose.dart';
import 'photo_card_state.dart' show medianOf;

/// 估计场景中位深度所需的最少特征点数。低于此数认为深度不可信。
/// 与 capture_session 的 `_minScaleAlignAnchorsForPersistedFrame` 同量级。
const int kAutoCaptureMinDepthAnchors = 8;

const double _radToDeg = 180.0 / math.pi;

/// 正式摄影测量帧的三档目标夹角。阈值只由跨端特征健康度选择，平台私有
/// tracking 枚举不得参与。
const double kAutoCaptureGeometryWeakDeg = 10.0;
const double kAutoCaptureGeometryNormalDeg = 12.0;
const double kAutoCaptureGeometryStrongDeg = 15.0;

/// COLMAP `IncrementalTriangulator::Options::min_angle` 的稳定三角化默认值。
/// 这里只用来区分“带一点有效平移”和“原地旋转”，不是正式几何帧阈值。
const double kAutoCaptureStableParallaxFloorDeg = 1.5;

/// 原地旋转累计到此角度时保留一张覆盖候选。
const double kAutoCaptureRotationCandidateDeg = 12.0;

/// 相邻照片的二维面积重叠安全线。RealityScan、Polycam 与 KIRI 的公开口径
/// 都集中在约 70%。
const double kAutoCaptureOverlapSafetyFraction = 0.70;

/// 仅前后移动时，画面尺度至少跨过一级才保留连接/细节帧。1.2 逐字采用
/// ORB-SLAM3 官方单目配置的尺度金字塔一级倍率。
const double kAutoCaptureRadialScaleStep = 1.20;

/// 后端无关的特征跟踪健康度。生产 ARKit 与影子 xrslam 都只能通过这一份
/// 归一化契约影响自适应阈值；不得把平台私有枚举塞进来。
class PortableTrackHealth {
  const PortableTrackHealth({
    required this.retentionRatio,
    required this.distributionHealthy,
  });

  /// 当前仍可跟踪的特征数 / 参考帧可跟踪特征数。
  final double retentionRatio;
  final bool distributionHealthy;
}

double autoCaptureGeometryAngleDeg(PortableTrackHealth? health) {
  final r = health?.retentionRatio;
  if (r == null || !r.isFinite || r < 0 || r > 1) {
    return kAutoCaptureGeometryNormalDeg;
  }
  if (r < 0.75) return kAutoCaptureGeometryWeakDeg;
  if (r >= 0.90 && health!.distributionHealthy) {
    return kAutoCaptureGeometryStrongDeg;
  }
  return kAutoCaptureGeometryNormalDeg;
}

class AutoCaptureIntrinsics {
  const AutoCaptureIntrinsics({
    required this.fx,
    required this.fy,
    required this.cx,
    required this.cy,
    required this.imageWidth,
    required this.imageHeight,
  });

  final double fx, fy, cx, cy;
  final int imageWidth, imageHeight;

  bool get isUsable =>
      fx.isFinite &&
      fy.isFinite &&
      cx.isFinite &&
      cy.isFinite &&
      fx > 0 &&
      fy > 0 &&
      imageWidth > 0 &&
      imageHeight > 0;
}

class AutoCaptureGeometryFrame {
  const AutoCaptureGeometryFrame({
    required this.camera,
    required this.orientation,
    required this.intrinsics,
  });

  final Vector3 camera;
  final Quaternion orientation;
  final AutoCaptureIntrinsics intrinsics;

  Vector3 get forward => cameraForwardInWorld(orientation);
}

enum AutoCaptureMotionRole {
  none,
  geometry,
  radialBridge,
  rotationCoverage,
  overlapSafety,
}

class AutoCaptureMotionMetrics {
  const AutoCaptureMotionMetrics({
    required this.role,
    required this.geometryParallaxDeg,
    required this.geometryThresholdDeg,
    required this.horizontalBaselineM,
    required this.verticalBaselineM,
    required this.radialTravelM,
    required this.depthScaleRatio,
    required this.viewTurnDeg,
    required this.overlapFraction,
    required this.advancesGeometryBaseline,
    required this.shouldPromptSlowDown,
    this.overlapSafetyEligible = false,
    this.geometryEligible = false,
    this.rotationCoverageEligible = false,
    this.radialBridgeEligible = false,
  });

  final AutoCaptureMotionRole role;
  final double geometryParallaxDeg;
  final double geometryThresholdDeg;
  final double horizontalBaselineM;
  final double verticalBaselineM;
  final double radialTravelM;
  final double depthScaleRatio;
  final double viewTurnDeg;
  final double? overlapFraction;
  final bool advancesGeometryBaseline;
  final bool shouldPromptSlowDown;

  /// 四个原始候选判据。它们与 [role] 分开保留，供聚合遥测区分“没命中”
  /// 和“命中但被更高优先级候选遮蔽”。只含相对几何量，不含绝对位姿。
  final bool overlapSafetyEligible;
  final bool geometryEligible;
  final bool rotationCoverageEligible;
  final bool radialBridgeEligible;

  bool get isOverlapSafety => role == AutoCaptureMotionRole.overlapSafety;

  /// 低重叠本身是“减速/重新构图”的警告，不是独立的照片价值。
  /// 只有同一帧还满足正式几何、旋转覆盖或径向连接之一，才值得在警告时
  /// 立即开火。这样不改任何摄影测量阈值，也不会用固定时间间隔掩盖问题。
  bool get shouldCapture => role != AutoCaptureMotionRole.none;

  /// [2026-09-06 抄对] 视差角退回它在 COLMAP 里的原始角色:稳定三角化底线
  /// (`min_angle` 1.5°),只回答"这张和上一张实拍之间有没有真实平移";
  /// 原地旋转由旋转覆盖(12°)、纯前后移动由径向尺度(1.2×)各自作答。
  /// 它不再决定"什么时候拍"——那是 AliceVision 累计光流(10% 短边)的事。
  bool get meetsParallaxFloor =>
      (geometryParallaxDeg.isFinite &&
          geometryParallaxDeg >= kAutoCaptureStableParallaxFloorDeg) ||
      rotationCoverageEligible ||
      radialBridgeEligible;

  bool isRoleEligible(AutoCaptureMotionRole candidate) {
    switch (candidate) {
      case AutoCaptureMotionRole.none:
        return role == AutoCaptureMotionRole.none &&
            !overlapSafetyEligible &&
            !geometryEligible &&
            !rotationCoverageEligible &&
            !radialBridgeEligible;
      case AutoCaptureMotionRole.overlapSafety:
        return overlapSafetyEligible || role == candidate;
      case AutoCaptureMotionRole.geometry:
        return geometryEligible || role == candidate;
      case AutoCaptureMotionRole.rotationCoverage:
        return rotationCoverageEligible || role == candidate;
      case AutoCaptureMotionRole.radialBridge:
        return radialBridgeEligible || role == candidate;
    }
  }
}

Vector3 _cross(Vector3 a, Vector3 b) => Vector3(
  a.y * b.z - a.z * b.y,
  a.z * b.x - a.x * b.z,
  a.x * b.y - a.y * b.x,
);

Vector2? _projectTargetNormalized(
  AutoCaptureGeometryFrame frame,
  Vector3 target,
) {
  final k = frame.intrinsics;
  if (!k.isUsable) return null;
  final rel = target - frame.camera;
  final cam = worldVectorToCamera(frame.orientation, rel);
  final depth = -cam.z;
  if (!depth.isFinite || depth <= 1e-9) {
    return null;
  }
  return Vector2(
    (k.fx * cam.x / depth + k.cx) / k.imageWidth,
    (k.fy * cam.y / depth + k.cy) / k.imageHeight,
  );
}

/// 同一目标在两帧中的二维面积重叠近似。返回 null 表示内参不可用或目标无法
/// 投影；“不知道”绝不能编码成 0% 重叠，否则会误触重叠保底连拍。横、纵、
/// 斜向统一按面积相乘，不用固定 FOV 或焦段。
double? autoCaptureTargetOverlapFraction({
  required AutoCaptureGeometryFrame base,
  required AutoCaptureGeometryFrame current,
  required Vector3 target,
}) {
  final a = _projectTargetNormalized(base, target);
  final b = _projectTargetNormalized(current, target);
  if (a == null || b == null) return null;
  final ox = (1.0 - (b.x - a.x).abs()).clamp(0.0, 1.0);
  final oy = (1.0 - (b.y - a.y).abs()).clamp(0.0, 1.0);
  return ox * oy;
}

/// 把当前运动分成正式几何、前后连接、原地旋转覆盖候选、重叠保底四类。
/// [geometryBaseline] 与 [captureBaseline] 故意分开：连接/旋转帧会更新后者，
/// 但不能把正式几何基准带走。
AutoCaptureMotionMetrics classifyAutoCaptureMotion({
  required AutoCaptureGeometryFrame geometryBaseline,
  required AutoCaptureGeometryFrame captureBaseline,
  required AutoCaptureGeometryFrame current,
  required Vector3 target,
  PortableTrackHealth? trackHealth,
}) {
  const eps = 1e-9;
  final geometryThreshold = autoCaptureGeometryAngleDeg(trackHealth);
  final parallax = parallaxAngleDeg(
    baseCamera: geometryBaseline.camera,
    currentCamera: current.camera,
    target: target,
  );
  final turn = viewAxisTurnDeg(
    baseForward: captureBaseline.forward,
    currentForward: current.forward,
  );
  final overlap = autoCaptureTargetOverlapFraction(
    base: captureBaseline,
    current: current,
    target: target,
  );

  final ray = target - geometryBaseline.camera;
  final rayLength = ray.length;
  final radialAxis = rayLength > eps
      ? ray / rayLength
      : geometryBaseline.forward.normalized();
  final travel = current.camera - geometryBaseline.camera;
  final radial = travel.dot(radialAxis);

  final worldUp = Vector3(0, 1, 0);
  var horizontalAxis = _cross(worldUp, radialAxis);
  if (horizontalAxis.length < eps) {
    horizontalAxis = cameraLocalVectorToWorld(
      geometryBaseline.orientation,
      Vector3(1, 0, 0),
    );
  }
  horizontalAxis.normalize();
  var verticalAxis = _cross(radialAxis, horizontalAxis);
  if (verticalAxis.length < eps) {
    verticalAxis = cameraLocalVectorToWorld(
      geometryBaseline.orientation,
      Vector3(0, 1, 0),
    );
  }
  verticalAxis.normalize();

  final horizontal = travel.dot(horizontalAxis).abs();
  final vertical = travel.dot(verticalAxis).abs();
  final baseDepth = (target - captureBaseline.camera).length;
  final currentDepth = (target - current.camera).length;
  final depthScale = baseDepth > eps && currentDepth > eps
      ? math.max(baseDepth / currentDepth, currentDepth / baseDepth)
      : 1.0;

  final geometryReady = parallax + eps >= geometryThreshold;
  final overlapSafety =
      overlap != null && overlap <= kAutoCaptureOverlapSafetyFraction + eps;
  final rotationCoverage =
      turn + eps >= kAutoCaptureRotationCandidateDeg &&
      parallax < kAutoCaptureStableParallaxFloorDeg;
  final radialBridge = depthScale + eps >= kAutoCaptureRadialScaleStep;

  final AutoCaptureMotionRole role;
  // Approximate target projection is only a continuity warning. Industry
  // overlap guidance describes shared image features; it is not an
  // independent shutter role and must never outrank real spatial progress.
  if (geometryReady) {
    role = AutoCaptureMotionRole.geometry;
  } else if (rotationCoverage) {
    role = AutoCaptureMotionRole.rotationCoverage;
  } else if (radialBridge) {
    role = AutoCaptureMotionRole.radialBridge;
  } else {
    role = AutoCaptureMotionRole.none;
  }

  return AutoCaptureMotionMetrics(
    role: role,
    geometryParallaxDeg: parallax,
    geometryThresholdDeg: geometryThreshold,
    horizontalBaselineM: horizontal,
    verticalBaselineM: vertical,
    radialTravelM: radial.abs(),
    depthScaleRatio: depthScale,
    viewTurnDeg: turn,
    overlapFraction: overlap,
    advancesGeometryBaseline: geometryReady,
    shouldPromptSlowDown: overlapSafety,
    overlapSafetyEligible: overlapSafety,
    geometryEligible: geometryReady,
    rotationCoverageEligible: rotationCoverage,
    radialBridgeEligible: radialBridge,
  );
}

/// 场景中位深度(米)——**ARKit rawFeaturePoints 版,只许进遥测,禁入触发链**。
///
/// 〔2026-08-24 定罪〕它把 SfM 实测 1.29m 的房间**持续整场**报成 0.167m
/// (cap_1787553950501379 验尸,低 8 倍),当时的视差触发判据整套被它带崩。
/// 触发要用的深度见 [medianDepthFromPackedCloud](活体 SfM 点云,实测过的量)。
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

// [pw] 2026-08-24:这里曾经有一个 newFeatureRatio()(把当前帧特征点投回基准
// 相机、数落在基准画幅外的比例),用来做「新特征足够多」这道门。
// **算完账后整个撤掉了**,推导留在 auto_capture_governor.dart 的常量区:
// 8° 甜区上这个占比只有约 5%(视场 71.5°×56.7°,深度起伏 ±0%/±30% 两档几乎
// 相同),任何能放行甜区的阈值都低于 5° 地板处的 3.4% ⇒ 完全被视差地板覆盖;
// 而"特征全挤在画面中央一簇"时它还会**错误地**挡掉一张本该拍的照片
// (那一张恰恰能三角化那簇点)。
// 「相隔足够宽」与「新特征足够多」在几何上由同一个量承载 —— 视差角。
// 要重新引入,先拿真机特征分布做标定,别再凭几何直觉发明阈值。

/// 活体 SfM 点云的场景中位深度(米)—— 触发层唯一合法的深度来源。
///
/// [xyz] 是 `SfmLiveSnapshot.xyz`(每点 3 个 float)。**只许喂拍摄期的
/// 流式快照且 `gravityAlignQuatWxyz == null`**:那时点云与 ARKit 位姿在
/// 同一个世界系(喂帧位姿就是 ARKit `worldAlignment.gravity` 的
/// CamFromWorld,SfmLiveTrueParallax 的注释同一句话),[cameraPosition] /
/// [forward] 直接用当前 ARPose 即可,不跨系换算;尺度由 SfM 锚定 ARKit
/// 位姿,就是米。finalize 后带重力旋转的快照**不许**喂进来(那时自动拍
/// 早已结束,也没有消费者)。
///
/// 与 [medianSceneDepthM](ARKit rawFeaturePoints 版,已定罪)同一套数学,
/// 换了输入:这里的点是**重建实测过的**。点按 [sampleStride] 抽样
/// (中位数对均匀抽样稳健);5cm 下限剔除贴脸噪点(2026-08-24 验尸脚本
/// 同一条门,该脚本在 27 个真机位姿上得到 1.08–1.51m 的正确房间深度)。
/// 有效深度少于 [kAutoCaptureMinDepthAnchors] 时返回 null。
double? medianDepthFromCloudXyz({
  required Float32List xyz,
  required Vector3 cameraPosition,
  required Vector3 forward,
  int sampleStride = 16,
}) {
  if (xyz.length < 3) return null;
  final axis = forward.normalized();
  final ax = axis.x, ay = axis.y, az = axis.z;
  final cx = cameraPosition.x, cy = cameraPosition.y, cz = cameraPosition.z;
  final stride = (sampleStride < 1 ? 1 : sampleStride) * 3;
  final depths = <double>[];
  for (int i = 0; i + 2 < xyz.length; i += stride) {
    final d =
        (xyz[i] - cx) * ax + (xyz[i + 1] - cy) * ay + (xyz[i + 2] - cz) * az;
    if (d > 0.05 && d.isFinite) depths.add(d);
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
  final cam = worldVectorToCamera(currentOrientation, rel);
  final depth = -cam.z; // 相机看向 -Z
  if (depth <= 1e-6 || !depth.isFinite) return double.infinity;
  final uPx = fx * (cam.x / depth);
  final vPx = fy * (cam.y / depth);
  final sx = uPx.abs() / imageWidth;
  final sy = vPx.abs() / imageHeight;
  return sx + sy - sx * sy;
}
