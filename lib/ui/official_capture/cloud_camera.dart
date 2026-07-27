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
    this.orthographic = false,
  });

  /// [2026-07-27 用户签决"框外必须全红"] 正交投影模式:选区编辑视图专用。
  /// 透视下近点被放大,屏幕上跑出 2D 选区矩形但 3D 仍在盒内 → 不红,
  /// 与直觉相悖(真机实测)。正交下每点缩放因子相同(f/camDist),
  /// 选区矩形与盒投影**严格重合**,"屏幕框外 ⇔ 可见两轴出盒 ⇔ 红"。
  /// 这也是行业惯例:选区/裁剪编辑视图用正交,避免透视错位
  /// (RS 编辑页观感同款;查看器保持透视不受影响)。
  final bool orthographic;

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
      orthographic: orthographic,
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
    required this.orthographic,
  });

  final double cosY, sinY, cosP, sinP, f, camDist, ox, oy;
  final double pivotX, pivotY, pivotZ;

  /// 正交模式(见 CloudCamera.orthographic):缩放除数用 camDist 而非逐点
  /// depth。depth 仍按真值返回 —— 排序/衰减/裁剪语义不变。
  final bool orthographic;

  /// 权威投影:世界点 → (屏幕x, 屏幕y, 深度)。深度 <= 0 表示在相机后。
  (double, double, double) project(double wx, double wy, double wz) {
    final px = wx - pivotX, py = wy - pivotY, pz = wz - pivotZ;
    final x1 = px * cosY + pz * sinY;
    final z1 = -px * sinY + pz * cosY;
    final y2 = py * cosP - z1 * sinP;
    final z2 = py * sinP + z1 * cosP;
    final depth = z2 + camDist;
    final d = orthographic ? camDist : depth;
    return (ox - x1 * f / d, oy - y2 * f / d, depth);
  }

  /// 深度 depth 处,1 屏幕像素对应的世界距离(手柄拖拽逆映射)。
  /// 正交模式下与 depth 无关(恒 camDist/f)。
  double worldPerPixelAt(double depth) => (orthographic ? camDist : depth) / f;

  /// 屏幕 +x 方向(注意投影带负号:sx = ox - x1·f/depth,所以屏幕右移
  /// = 视空间 x1 减小)对应的世界方向单位向量。
  List<double> rightAxisWorld() => [-cosY, 0, -sinY];

  /// 屏幕 −y(向上)对应的世界方向单位向量(与函数名 upAxisWorld 一致:
  /// yaw=pitch=0 时返回 (0,1,0)=世界 +Y,即"抬头"方向)。
  /// 推导:sy = oy − y2·f/depth ⇒ ∂sy/∂y2 = −f/depth < 0,即 y2 增大会让
  /// sy 减小 ⇒ 屏幕上移(−y);
  /// y2 = py·cosP − z1·sinP,z1 = −px·sinY + pz·cosY
  /// ⇒ ∂y2/∂(px,py,pz) = (sinY·sinP, cosP, −cosY·sinP),此即"y2 增大方向"
  /// = 屏幕上移方向,不需要再取负。
  /// 注:brief 手推稿在此处符号有误(把"y2 增大 ⇒ 屏幕上移"误写成"屏幕
  /// 下移要求 y2 增大"),已用数值微分测试(test/cloud_camera_test.dart)
  /// 核验修正。
  List<double> upAxisWorld() => [sinY * sinP, cosP, -cosY * sinP];
}
