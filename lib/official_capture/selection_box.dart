// 选区盒(重力系轴对齐 + 绕竖直轴 yaw)。给未来稠密化划边界的元数据;PLY 永不因它改写。
// 设计:docs/superpowers/specs/2026-07-27-selection-region-design.md
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

const String kSelectionBoxFileName = 'official_selection_box.json';

class SelectionBox {
  const SelectionBox({
    required this.cx,
    required this.cy,
    required this.cz,
    required this.sx,
    required this.sy,
    required this.sz,
    required this.yawDeg,
  });

  /// 盒中心(世界系,点云已重力对齐:Y=重力上)。
  final double cx, cy, cz;

  /// 盒全尺寸(局部系各轴)。
  final double sx, sy, sz;

  /// 绕世界 Y 轴旋转角(度)。盒转、点云不动。
  final double yawDeg;

  /// 盒最小半尺寸 = fit radius × 此值(手柄 clamp 用,防拖成退化盒)。
  static const double kMinHalfSizeFraction = 0.02;

  /// 初始盒 = fit 球(SparseCloudPainter.fitOf)的外接立方。
  factory SelectionBox.initialFor({
    required double cx,
    required double cy,
    required double cz,
    required double radius,
  }) => SelectionBox(
    cx: cx,
    cy: cy,
    cz: cz,
    sx: radius * 2,
    sy: radius * 2,
    sz: radius * 2,
    yawDeg: 0,
  );

  bool contains(double wx, double wy, double wz) {
    // 世界 → 盒局部。正变换(局部→世界,见 selectionBoxCorners)是
    //   wx = lx·cosθ − lz·sinθ; wz = lx·sinθ + lz·cosθ  (θ = yawDeg)
    // 其标准逆式如下(与 selectionBoxCorners 的正变换互逆)。注:数学上
    // R(−θ) = R(θ)⁻¹,所以"负角代入正变换公式"本身与下面这套逆式等价,
    // 并不是错误写法 —— 计划自审时抓到的那个 bug,根因是把逆变换的旋转
    // 方向写反了(符号搞反,不是"负角+正式"这个思路本身的问题)。
    final t = yawDeg * math.pi / 180.0;
    final c = math.cos(t), s = math.sin(t);
    final px = wx - cx, py = wy - cy, pz = wz - cz;
    final lx = px * c + pz * s;
    final lz = -px * s + pz * c;
    return lx.abs() <= sx / 2 && py.abs() <= sy / 2 && lz.abs() <= sz / 2;
  }

  SelectionBox copyWith({
    double? cx,
    double? cy,
    double? cz,
    double? sx,
    double? sy,
    double? sz,
    double? yawDeg,
  }) => SelectionBox(
    cx: cx ?? this.cx,
    cy: cy ?? this.cy,
    cz: cz ?? this.cz,
    sx: sx ?? this.sx,
    sy: sy ?? this.sy,
    sz: sz ?? this.sz,
    yawDeg: yawDeg ?? this.yawDeg,
  );

  Map<String, dynamic> toJson() => <String, dynamic>{
    'cx': cx,
    'cy': cy,
    'cz': cz,
    'sx': sx,
    'sy': sy,
    'sz': sz,
    'yawDeg': yawDeg,
  };

  /// 任何形状不对/类型不对/非有限值 → null(容错:选区文件坏不许拖垮查看器)。
  static SelectionBox? fromJson(Object? j) {
    if (j is! Map) return null;
    double? d(Object? v) => (v is num && v.isFinite) ? v.toDouble() : null;
    final cx = d(j['cx']), cy = d(j['cy']), cz = d(j['cz']);
    final sx = d(j['sx']), sy = d(j['sy']), sz = d(j['sz']);
    final yaw = d(j['yawDeg']);
    if ([cx, cy, cz, sx, sy, sz, yaw].contains(null)) return null;
    return SelectionBox(
      cx: cx!,
      cy: cy!,
      cz: cz!,
      sx: sx!,
      sy: sy!,
      sz: sz!,
      yawDeg: yaw!,
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
