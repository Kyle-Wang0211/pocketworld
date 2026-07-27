// cloud_camera.dart — 点云相机/投影的单一事实源。
//
// 公式所有权在 CloudProjection.project();SparseCloudPainter 与
// SelectionCloudView 的热循环仍用标量展开(数万点逐点调函数不划算),但
// 八个标量一律从这里取,一致性由 test/cloud_camera_test.dart 的 parity
// 测试锁死。历史:此前 paint() 与 pointAtScreen() 各写一份同式,注释靠
// "Kept bit-identical" 人肉维持 —— 本文件终结这种维持方式。
import 'dart:math' as math;
import 'dart:ui' show Size;

class CloudCamera {
  const CloudCamera({
    required this.yaw,
    required this.pitch,
    required this.zoom,
    required this.panX,
    required this.panY,
    required this.pivotX,
    required this.pivotY,
    required this.pivotZ,
    required this.radius,
    this.fillK = 2.6, // SparseCloudView 开屏取景系数(user-locked 2026-07-06)
  });

  final double yaw, pitch, zoom, panX, panY;
  final double pivotX, pivotY, pivotZ;

  /// 取景 fit 球半径(SparseCloudPainter.fitOf 的 radius)。
  final double radius;
  final double fillK;

  CloudProjection projectionFor(Size size) {
    final half = size.shortestSide * 0.5;
    return CloudProjection._(
      cosY: math.cos(yaw),
      sinY: math.sin(yaw),
      cosP: math.cos(pitch),
      sinP: math.sin(pitch),
      f: half * fillK * zoom,
      camDist: radius * 3.2,
      ox: size.width * 0.5 + panX,
      oy: size.height * 0.5 + panY,
      pivotX: pivotX,
      pivotY: pivotY,
      pivotZ: pivotZ,
    );
  }
}

class CloudProjection {
  const CloudProjection._({
    required this.cosY,
    required this.sinY,
    required this.cosP,
    required this.sinP,
    required this.f,
    required this.camDist,
    required this.ox,
    required this.oy,
    required this.pivotX,
    required this.pivotY,
    required this.pivotZ,
  });

  final double cosY, sinY, cosP, sinP, f, camDist, ox, oy;
  final double pivotX, pivotY, pivotZ;

  /// 权威投影:世界点 → (屏幕x, 屏幕y, 深度)。深度 <= 0 表示在相机后。
  (double, double, double) project(double wx, double wy, double wz) {
    final px = wx - pivotX, py = wy - pivotY, pz = wz - pivotZ;
    final x1 = px * cosY + pz * sinY;
    final z1 = -px * sinY + pz * cosY;
    final y2 = py * cosP - z1 * sinP;
    final z2 = py * sinP + z1 * cosP;
    final depth = z2 + camDist;
    return (ox - x1 * f / depth, oy - y2 * f / depth, depth);
  }

  /// 深度 depth 处,1 屏幕像素对应的世界距离(手柄拖拽逆映射)。
  double worldPerPixelAt(double depth) => depth / f;

  /// 屏幕 +x 方向(注意投影带负号:sx = ox - x1·f/depth,所以屏幕右移
  /// = 视空间 x1 减小)对应的世界方向单位向量。
  List<double> rightAxisWorld() => [-cosY, 0, -sinY];

  /// 屏幕 +y(向下)对应的世界方向单位向量。
  /// 推导:sy = oy − y2·f/depth ⇒ 屏幕下移(+y)要求 y2 增大;
  /// y2 = py·cosP − z1·sinP,z1 = −px·sinY + pz·cosY
  /// ⇒ ∂y2/∂(px,py,pz) = (sinY·sinP, cosP, −cosY·sinP)。
  /// 注:brief 手推稿在此处符号有误(多取了一次负),已用数值微分测试
  /// (test/cloud_camera_test.dart)核验修正 —— 不取负,直接是该梯度方向。
  List<double> upAxisWorld() => [sinY * sinP, cosP, -cosY * sinP];
}
