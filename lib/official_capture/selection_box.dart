// 选区盒(任意 3D 朝向)。给未来稠密化划边界的元数据;PLY 永不因它改写。
//
// [2026-07-29 用户签决] 朝向从"仅绕竖直轴 yawDeg"升级为完整旋转矩阵:
// 旋转滑轨要"按当前正对的那个面为底开始旋转",正对 Front/Right 时转轴是
// 世界 Z/X —— 单一 yaw 表示不了。rot 是行主序 3×3,局部→世界。
// 设计:docs/superpowers/specs/2026-07-27-selection-region-design.md
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

const String kSelectionBoxFileName = 'official_selection_box.json';

/// 存档版本。**初始框的判定算法一变就要 +1** —— 否则老草稿会一直复用上一版
/// 算出的框,新算法根本看不到效果(用户实机指认"覆盖率明显不是 97%",实为
/// 读到了 MAD 判据存下的小框)。版本不符 = 当作没有存档,按当前算法重算。
const int kSelectionBoxSchemaVersion = 2;

/// 单位旋转(轴对齐)。
const List<double> kIdentityRot = <double>[1, 0, 0, 0, 1, 0, 0, 0, 1];

/// 绕任意单位轴转 deg° 的旋转矩阵(Rodrigues,行主序)。
List<double> rotAboutAxisDeg(List<double> axis, double deg) {
  final n = math.sqrt(
    axis[0] * axis[0] + axis[1] * axis[1] + axis[2] * axis[2],
  );
  if (n < 1e-12) return kIdentityRot;
  final x = axis[0] / n, y = axis[1] / n, z = axis[2] / n;
  final t = deg * math.pi / 180.0;
  final c = math.cos(t), s = math.sin(t), k = 1 - c;
  return <double>[
    c + x * x * k, x * y * k - z * s, x * z * k + y * s, //
    y * x * k + z * s, c + y * y * k, y * z * k - x * s,
    z * x * k - y * s, z * y * k + x * s, c + z * z * k,
  ];
}

/// 行主序 3×3 相乘(a·b)。
List<double> mulRot(List<double> a, List<double> b) {
  final out = List<double>.filled(9, 0);
  for (var r = 0; r < 3; r++) {
    for (var c = 0; c < 3; c++) {
      var v = 0.0;
      for (var k = 0; k < 3; k++) {
        v += a[r * 3 + k] * b[k * 3 + c];
      }
      out[r * 3 + c] = v;
    }
  }
  return out;
}

class SelectionBox {
  const SelectionBox({
    required this.cx,
    required this.cy,
    required this.cz,
    required this.sx,
    required this.sy,
    required this.sz,
    this.rot = kIdentityRot,
  });

  /// 绕世界 Y 轴 yaw 的便捷构造(旧存档与既有调用点)。
  factory SelectionBox.withYaw({
    required double cx,
    required double cy,
    required double cz,
    required double sx,
    required double sy,
    required double sz,
    required double yawDeg,
  }) => SelectionBox(
    cx: cx,
    cy: cy,
    cz: cz,
    sx: sx,
    sy: sy,
    sz: sz,
    // 负角:既有约定是 wx = lx·cosθ − lz·sinθ(见 selectionBoxCorners),
    // 与 Rodrigues 绕 +Y 的右手旋向相反,取 −θ 才逐位等价。
    rot: rotAboutAxisDeg(const [0, 1, 0], -yawDeg),
  );

  /// 盒中心(世界系,点云已重力对齐:Y=重力上)。
  final double cx, cy, cz;

  /// 盒全尺寸(局部系各轴)。
  final double sx, sy, sz;

  /// 局部→世界的旋转(行主序 3×3)。盒转、点云不动。
  final List<double> rot;

  /// 绕世界 Y 轴的分量(度)—— 兼容读数与旧存档。
  double get yawDeg => math.atan2(rot[6], rot[0]) * 180.0 / math.pi;

  /// 盒最小半尺寸 = fit radius × 此值(手柄 clamp 用,防拖成退化盒)。
  static const double kMinHalfSizeFraction = 0.02;

  /// 初始盒 = fit 球(SparseCloudPainter.fitOf)的外接立方。
  /// 屏幕标准尺寸系数:最长边的投影 = 此系数 × 取景半径的投影
  /// (= 半短边的 ~81%)。编辑态 zoom 按最长边反推,保证屏幕尺寸恒定。
  static const double kInitialBoxRadiusScale = 2.0;

  /// [2026-08-09 用户签决,当日三轮收敛] "只需要让用户每个面看到的初始框
  /// 是正方形就行,内部的点云可以自适应大小" —— 几何上"每面都是正方形"
  /// ⟺ 三边等长。边长取**全量最长轴**(调用方传 max(hx,hy,hz)),与全量
  /// AABB 同心 ⇒ 沿最长轴精确顶住两端的点("严丝合缝顶着最上面和最下面"),
  /// 其余轴向点云居中留白;屏幕尺寸恒定由编辑态 zoom 保证(editingFrameOf)。
  factory SelectionBox.initialSquareFace({
    required double cx,
    required double cy,
    required double cz,
    required double halfExtent,
  }) {
    final side = math.max(halfExtent, 1e-6) * 2;
    return SelectionBox(cx: cx, cy: cy, cz: cz, sx: side, sy: side, sz: side);
  }

  bool contains(double wx, double wy, double wz) {
    // 世界 → 局部 = rotᵀ·(p − c)(rot 行主序,其转置的第 i 行 = rot 第 i 列)。
    final px = wx - cx, py = wy - cy, pz = wz - cz;
    final lx = rot[0] * px + rot[3] * py + rot[6] * pz;
    final ly = rot[1] * px + rot[4] * py + rot[7] * pz;
    final lz = rot[2] * px + rot[5] * py + rot[8] * pz;
    return lx.abs() <= sx / 2 && ly.abs() <= sy / 2 && lz.abs() <= sz / 2;
  }

  /// 绕世界竖直枢轴 (pivotX, pivotZ) 刚性旋转 deltaDeg°:中心公转 +
  /// 自身 yaw 同步自转(旋转方向与 corners 正变换同约定)。
  ///
  /// [2026-07-28 用户签决] 旋转刻度尺期间"框在屏幕上不能动":相机
  /// viewYaw = preset + yawDeg,框朝向的 +Δ 正好抵消相机 +Δ(所以框
  /// 在屏幕上不转),但框心若不在相机枢轴上,投影位置仍会漂移 —— 解法
  /// 就是整盒绕**相机枢轴**(点云 fit 中心)刚性旋转,位置+朝向双抵消,
  /// 投影不变性由 selection_box_pivot_rotation_test 以 1e-6 锁定。
  /// 框是否仍然可用(旧版本手柄 bug 会把某一维压成纸片,或把框拖到点云
  /// 之外)。不可用时调用方回退到 [initialFor] —— 否则用户进来看到的是
  /// 一个选不中任何点的退化框,且没有任何自救入口。
  /// [SEL-DISCARD 2026-07-30] 两个框在**产品意义上**是否相同。
  ///
  /// 用途:判断"用户这次到底改过选区没有" —— 它直接决定退出时要不要弹
  /// "编辑记录是否保存"。所以宁可判成"改过"(多弹一次)也不能漏判(静默丢掉
  /// 用户的编辑)。
  ///
  /// 不用 `operator ==`:这是**近似**比较(浮点手势产生的 1e-12 抖动不算修改),
  /// 而 `==` 必须与 `hashCode` 一致且传递,近似相等两条都不满足。容差取 1e-9,
  /// 远小于任何手势能产生的位移,也远大于浮点往返噪声。
  bool sameAs(SelectionBox other, {double eps = 1e-9}) {
    bool near(double a, double b) => (a - b).abs() <= eps;
    if (!near(cx, other.cx) || !near(cy, other.cy) || !near(cz, other.cz)) {
      return false;
    }
    if (!near(sx, other.sx) || !near(sy, other.sy) || !near(sz, other.sz)) {
      return false;
    }
    if (rot.length != other.rot.length) return false;
    for (var i = 0; i < rot.length; i++) {
      if (!near(rot[i], other.rot[i])) return false;
    }
    return true;
  }

  bool isSaneFor({
    required double fitCx,
    required double fitCy,
    required double fitCz,
    required double fitRadius,
  }) {
    final minSide = fitRadius * 0.05;
    if (sx < minSide || sy < minSide || sz < minSide) return false;
    final dx = cx - fitCx, dy = cy - fitCy, dz = cz - fitCz;
    final dist = math.sqrt(dx * dx + dy * dy + dz * dz);
    return dist <= fitRadius * 5;
  }

  /// 绕**任意世界轴**刚性旋转 deltaDeg°(中心绕 pivot 公转 + 自身同步自转)。
  ///
  /// [2026-07-29 用户签决] 转轴 = 当前正对面的法向 ⇒ "以那个面为底转"。
  /// 中心公转保证框在屏幕上不动(相机也绕同一轴等量反转时精确抵消)。
  SelectionBox rotatedAroundAxis({
    required List<double> axis,
    required double deltaDeg,
    required double pivotX,
    required double pivotY,
    required double pivotZ,
  }) {
    final r = rotAboutAxisDeg(axis, deltaDeg);
    final dx = cx - pivotX, dy = cy - pivotY, dz = cz - pivotZ;
    return copyWith(
      cx: pivotX + r[0] * dx + r[1] * dy + r[2] * dz,
      cy: pivotY + r[3] * dx + r[4] * dy + r[5] * dz,
      cz: pivotZ + r[6] * dx + r[7] * dy + r[8] * dz,
      rot: mulRot(r, rot),
    );
  }

  SelectionBox copyWith({
    double? cx,
    double? cy,
    double? cz,
    double? sx,
    double? sy,
    double? sz,
    List<double>? rot,
  }) => SelectionBox(
    cx: cx ?? this.cx,
    cy: cy ?? this.cy,
    cz: cz ?? this.cz,
    sx: sx ?? this.sx,
    sy: sy ?? this.sy,
    sz: sz ?? this.sz,
    rot: rot ?? this.rot,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'v': kSelectionBoxSchemaVersion,
    'cx': cx,
    'cy': cy,
    'cz': cz,
    'sx': sx,
    'sy': sy,
    'sz': sz,
    'rot': rot,
    // 旧版本只认 yawDeg;写出来让降级安装仍能读到大致朝向。
    'yawDeg': yawDeg,
  };

  /// 任何形状不对/类型不对/非有限值 → null(容错:选区文件坏不许拖垮查看器)。
  /// 任何形状不对/类型不对/非有限值 → null(容错:选区文件坏不许拖垮查看器)。
  static SelectionBox? fromJson(Object? j) {
    if (j is! Map) return null;
    // 版本不符(含无版本的旧档)⇒ 交由调用方按当前算法重算初始框。
    if (j['v'] != kSelectionBoxSchemaVersion) return null;
    double? d(Object? v) => (v is num && v.isFinite) ? v.toDouble() : null;
    final cx = d(j['cx']), cy = d(j['cy']), cz = d(j['cz']);
    final sx = d(j['sx']), sy = d(j['sy']), sz = d(j['sz']);
    if ([cx, cy, cz, sx, sy, sz].contains(null)) return null;
    // 优先读完整旋转;旧存档只有 yawDeg。
    final rawRot = j['rot'];
    if (rawRot is List && rawRot.length == 9) {
      final r = rawRot.map(d).toList();
      if (!r.contains(null)) {
        // [2026-07-29 滑轨改横轴翻滚] 框朝向现在是任意 3D 旋转(翻滚会带
        // 俯仰/滚转分量),恢复完整 rot,不再投影到竖直。
        return SelectionBox(
          cx: cx!,
          cy: cy!,
          cz: cz!,
          sx: sx!,
          sy: sy!,
          sz: sz!,
          rot: r.cast<double>(),
        );
      }
    }
    final yaw = d(j['yawDeg']);
    if (yaw == null) return null;
    return SelectionBox.withYaw(
      cx: cx!,
      cy: cy!,
      cz: cz!,
      sx: sx!,
      sy: sy!,
      sz: sz!,
      yawDeg: yaw,
    );
  }

  static Future<SelectionBox?> loadFrom(String captureDir) async {
    try {
      final f = File('$captureDir/$kSelectionBoxFileName');
      if (!await f.exists()) return null;
      return fromJson(jsonDecode(await f.readAsString()));
    } catch (_) {
      return null;
    }
  }

  Future<void> saveTo(String captureDir) async {
    final f = File('$captureDir/$kSelectionBoxFileName');
    await f.writeAsString(jsonEncode(toJson()), flush: true);
  }
}
