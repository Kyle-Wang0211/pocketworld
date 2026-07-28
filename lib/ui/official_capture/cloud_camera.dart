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
    this.roll = 0,
  });

  /// 屏幕空间滚转(弧度)。[2026-07-28] 过极翻面动画专用:纯 yaw/pitch
  /// 相机翻过极点必然倒置(SO(3) 拓扑),补一段 roll 自旋回正才能落到
  /// 正立对面。roll==0 时投影数学与历史逐位一致(painter 侧有零开销
  /// 跳过)。
  final double roll;

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
      cosR: math.cos(roll),
      sinR: math.sin(roll),
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
    required this.cosR,
    required this.sinR,
  });

  final double cosY, sinY, cosP, sinP, f, camDist, ox, oy;

  /// 屏幕滚转标量(见 CloudCamera.roll)。roll==0 ⇒ cosR==1.0 且 sinR==0.0
  /// (cos/sin 在 0 处精确),消费方可据此零开销跳过。
  final double cosR, sinR;
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
    final sx = ox - x1 * f / d;
    final sy = oy - y2 * f / d;
    if (sinR == 0.0 && cosR == 1.0) return (sx, sy, depth);
    // 屏幕空间滚转(绕视口中心 ox,oy)。
    final dx = sx - ox, dy = sy - oy;
    return (ox + dx * cosR - dy * sinR, oy + dx * sinR + dy * cosR, depth);
  }

  /// 深度 depth 处,1 屏幕像素对应的世界距离(手柄拖拽逆映射)。
  /// 正交模式下与 depth 无关(恒 camDist/f)。
  double worldPerPixelAt(double depth) => (orthographic ? camDist : depth) / f;

  /// 屏幕 +x 方向(注意投影带负号:sx = ox - x1·f/depth,所以屏幕右移
  /// = 视空间 x1 减小)对应的世界方向单位向量。
  List<double> rightAxisWorld() {
    final r = [-cosY, 0.0, -sinY];
    if (sinR == 0.0 && cosR == 1.0) return r;
    final u = _upNoRoll();
    // roll 后屏幕 +x 对应的世界方向 = cosR·right + sinR·up(数值微分测试锁)
    return [
      cosR * r[0] + sinR * u[0],
      cosR * r[1] + sinR * u[1],
      cosR * r[2] + sinR * u[2],
    ];
  }

  List<double> _upNoRoll() => [sinY * sinP, cosP, -cosY * sinP];

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
  List<double> upAxisWorld() {
    final u = _upNoRoll();
    if (sinR == 0.0 && cosR == 1.0) return u;
    final r = [-cosY, 0.0, -sinY];
    // roll 后屏幕 −y(上)对应的世界方向 = −sinR·right + cosR·up
    return [
      -sinR * r[0] + cosR * u[0],
      -sinR * r[1] + cosR * u[1],
      -sinR * r[2] + cosR * u[2],
    ];
  }
}

// ─── SO(3) 姿态工具(ViewCube 同款机制) ─────────────────────────────────
//
// [2026-07-28 用户签决"抄成熟开源机制"] 预设切换动画不再在 (yaw,pitch)
// 欧拉空间里插值(过极点只能水平长绕或跳变 —— 机制性缺陷),改为行业标准
// 的旋转矩阵 + 轴角 slerp(Shoemake 1985;three.js CameraControls /
// AutoCAD ViewCube 同款):任意两个规范姿态之间 = 绕单一固定轴的最短平滑
// 旋转。中间帧分解回 (yaw, pitch, roll) 喂现有投影管线 —— roll 正是
// SO(3) 的第三个自由度,(yaw,pitch,roll) 可参数化任意姿态。
// 视矩阵行约定(与 CloudProjection.project 展开式逐字一致):
//   row1 = ( cosY,      0,     sinY)          → x1
//   row2 = ( sinY·sinP, cosP, −cosY·sinP)     → y2
//   row3 = (−sinY·cosP, sinP,  cosY·cosP)     → z2(视线/深度方向)
// 总矩阵 M = Rz(roll)·M(yaw,pitch)(roll = 投影后屏幕旋转 = 视空间绕 z)。

/// (yaw, pitch, roll) → 3×3 视矩阵(行主序 9 元素)。
List<double> composeViewMatrix(double yaw, double pitch, double roll) {
  final cy = math.cos(yaw), sy = math.sin(yaw);
  final cp = math.cos(pitch), sp = math.sin(pitch);
  final cr = math.cos(roll), sr = math.sin(roll);
  // M(yaw,pitch) 三行
  final a = [cy, 0.0, sy];
  final b = [sy * sp, cp, -cy * sp];
  final c = [-sy * cp, sp, cy * cp];
  // Rz(roll) 左乘:row1' = cr·a − sr·b;row2' = sr·a + cr·b;row3' = c
  return [
    cr * a[0] - sr * b[0], cr * a[1] - sr * b[1], cr * a[2] - sr * b[2], //
    sr * a[0] + cr * b[0], sr * a[1] + cr * b[1], sr * a[2] + cr * b[2], //
    c[0], c[1], c[2],
  ];
}

/// 3×3 视矩阵 → (yaw, pitch, roll)。row3 不受 roll 影响,先解 yaw/pitch,
/// 再从 row1 反解 roll。pitch=±90° 简并处 yaw 取 atan2(0,0)=0 的约定分支,
/// roll 吸收剩余自由度 —— compose(decompose(M)) 仍恒等于 M。
(double, double, double) decomposeViewMatrix(List<double> m) {
  final sp = m[7].clamp(-1.0, 1.0);
  final pitch = math.asin(sp);
  final yaw = math.atan2(-m[6], m[8]);
  // 由 yaw/pitch 重建无 roll 的 row1/row2,再投影出 roll
  final cy = math.cos(yaw), sy = math.sin(yaw);
  final cp = math.cos(pitch);
  final a = [cy, 0.0, sy];
  final b = [sy * sp, cp, -cy * sp];
  // row1' = cr·a − sr·b ⇒ cr = row1'·a,sr = −row1'·b(a、b 单位正交)
  final cr = m[0] * a[0] + m[1] * a[1] + m[2] * a[2];
  final sr = -(m[0] * b[0] + m[1] * b[1] + m[2] * b[2]);
  return (yaw, pitch, math.atan2(sr, cr));
}

/// R = a·bᵀ(b 正交,bᵀ=b⁻¹)—— 相对旋转。
List<double> mulTransposed(List<double> a, List<double> b) {
  final out = List<double>.filled(9, 0);
  for (var i = 0; i < 3; i++) {
    for (var j = 0; j < 3; j++) {
      out[i * 3 + j] =
          a[i * 3] * b[j * 3] +
          a[i * 3 + 1] * b[j * 3 + 1] +
          a[i * 3 + 2] * b[j * 3 + 2];
    }
  }
  return out;
}

/// 3×3 矩阵乘法 a·b。
List<double> mulMatrix(List<double> a, List<double> b) {
  final out = List<double>.filled(9, 0);
  for (var i = 0; i < 3; i++) {
    for (var j = 0; j < 3; j++) {
      out[i * 3 + j] =
          a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j];
    }
  }
  return out;
}

/// 旋转矩阵 → 轴角。angle ∈ [0, π];angle≈0 时轴无意义(返回 x 轴)。
/// 180° 简并分支用对角元素提取轴(Rodrigues 反解的标准处理)。
(List<double>, double) axisAngleOf(List<double> r) {
  final trace = r[0] + r[4] + r[8];
  final cosA = ((trace - 1) / 2).clamp(-1.0, 1.0);
  final angle = math.acos(cosA);
  if (angle < 1e-9) return ([1.0, 0.0, 0.0], 0.0);
  if (angle > math.pi - 1e-6) {
    // 180°:R = 2vvᵀ − I ⇒ v_i = sqrt((r_ii+1)/2),符号由非对角元定
    final vx = math.sqrt(((r[0] + 1) / 2).clamp(0.0, 1.0));
    final vy = math.sqrt(((r[4] + 1) / 2).clamp(0.0, 1.0));
    final vz = math.sqrt(((r[8] + 1) / 2).clamp(0.0, 1.0));
    // 取最大分量为正,其余符号从 r[ij] = 2·vi·vj 恢复
    if (vx >= vy && vx >= vz) {
      return ([vx, r[1] / (2 * vx), r[2] / (2 * vx)], math.pi);
    } else if (vy >= vz) {
      return ([r[3] / (2 * vy), vy, r[5] / (2 * vy)], math.pi);
    }
    return ([r[6] / (2 * vz), r[7] / (2 * vz), vz], math.pi);
  }
  final s = 2 * math.sin(angle);
  // 轴从反对称部分提取(行主序:r[7]-r[5], r[2]-r[6], r[3]-r[1])
  return ([(r[7] - r[5]) / s, (r[2] - r[6]) / s, (r[3] - r[1]) / s], angle);
}

/// 轴角 → 旋转矩阵(Rodrigues)。
List<double> rotationFromAxisAngle(List<double> axis, double angle) {
  final n = math.sqrt(
    axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2],
  );
  if (n < 1e-12 || angle.abs() < 1e-12) {
    return [1, 0, 0, 0, 1, 0, 0, 0, 1];
  }
  final x = axis[0] / n, y = axis[1] / n, z = axis[2] / n;
  final c = math.cos(angle), s = math.sin(angle), t = 1 - c;
  return [
    t * x * x + c, t * x * y - s * z, t * x * z + s * y, //
    t * x * y + s * z, t * y * y + c, t * y * z - s * x, //
    t * x * z - s * y, t * y * z + s * x, t * z * z + c,
  ];
}
