// selection_handles_3d.dart — 3D 选区框手柄(建模软件同款 bound-box gizmo)。
//
// [2026-07-28 用户签决] "预览跟编辑就是一个页面,点下一步只是让工具显现"
// ⇒ 编辑页必须与预览页同一投影(透视),否则一进编辑点云就跳变。原先
// 2D 屏幕矩形手柄依赖正交才能与盒的真实轮廓重合,于是"新版框改成 3D 的":
// 框 = 真 3D 线框(12 边),手柄 = 8 角 + 6 面中心的世界点投影,拖拽沿
// **世界轴**逆映射。透视下手柄天然贴合盒轮廓,框外红点与线框永远吻合。
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../official_capture/selection_box.dart';
import 'cloud_camera.dart';
import 'sparse_cloud_view.dart' show selectionBoxCorners;

/// 手柄标识:盒局部三轴上的符号 (sx,sy,sz) ∈ {-1,0,1}³(非全零)。
/// 恰一个非零 = 面手柄(单轴);三个非零 = 角手柄(三轴同动)。
typedef BoxHandle3D = ({int sx, int sy, int sz});

/// 6 面 + 8 角 = 14 个手柄(边手柄不做:屏幕上 26 个点太密,建模软件的
/// bound-box gizmo 同样只给角+面)。
const List<BoxHandle3D> kBoxHandles3D = [
  (sx: 1, sy: 0, sz: 0),
  (sx: -1, sy: 0, sz: 0),
  (sx: 0, sy: 1, sz: 0),
  (sx: 0, sy: -1, sz: 0),
  (sx: 0, sy: 0, sz: 1),
  (sx: 0, sy: 0, sz: -1),
  (sx: 1, sy: 1, sz: 1),
  (sx: 1, sy: 1, sz: -1),
  (sx: 1, sy: -1, sz: 1),
  (sx: 1, sy: -1, sz: -1),
  (sx: -1, sy: 1, sz: 1),
  (sx: -1, sy: 1, sz: -1),
  (sx: -1, sy: -1, sz: 1),
  (sx: -1, sy: -1, sz: -1),
];

bool isCornerHandle(BoxHandle3D h) => h.sx != 0 && h.sy != 0 && h.sz != 0;

/// 盒局部轴在世界中的单位方向(与 selectionBoxCorners 的正变换同约定:
/// world = c·lx − s·lz, ly, s·lx + c·lz)。
List<List<double>> boxWorldAxes(SelectionBox b) {
  final a = b.yawDeg * math.pi / 180.0;
  final c = math.cos(a), s = math.sin(a);
  return [
    [c, 0.0, s],
    [0.0, 1.0, 0.0],
    [-s, 0.0, c],
  ];
}

/// 手柄的世界坐标 = 盒心 + Σ sₖ·axisₖ·(sizeₖ/2)。
List<double> handleWorldPos(SelectionBox b, BoxHandle3D h) {
  final ax = boxWorldAxes(b);
  final half = [b.sx / 2, b.sy / 2, b.sz / 2];
  final sgn = [h.sx.toDouble(), h.sy.toDouble(), h.sz.toDouble()];
  var x = b.cx, y = b.cy, z = b.cz;
  for (var k = 0; k < 3; k++) {
    final d = sgn[k] * half[k];
    if (d == 0) continue;
    x += ax[k][0] * d;
    y += ax[k][1] * d;
    z += ax[k][2] * d;
  }
  return [x, y, z];
}

/// 命中最近的手柄(屏幕距离 ≤ tolPx;同在容差内取更近的那个)。
BoxHandle3D? hitBoxHandle3D(
  SelectionBox b,
  CloudProjection proj,
  Offset tap, {
  double tolPx = 30,
}) {
  BoxHandle3D? best;
  var bestD2 = tolPx * tolPx;
  for (final h in kBoxHandles3D) {
    final w = handleWorldPos(b, h);
    final (sx, sy, _) = proj.project(w[0], w[1], w[2]);
    final dx = sx - tap.dx, dy = sy - tap.dy;
    final d2 = dx * dx + dy * dy;
    if (d2 <= bestD2) {
      bestD2 = d2;
      best = h;
    }
  }
  return best;
}

/// 世界轴在手柄处的屏幕方向(像素/世界单位)。差分求得,零手写映射表 ——
/// 透视下随深度自动变化,正交下退化为常量。
Offset _axisScreenDir(
  CloudProjection proj,
  List<double> at,
  List<double> axis,
) {
  const eps = 1e-3;
  final (x0, y0, _) = proj.project(at[0], at[1], at[2]);
  final (x1, y1, _) = proj.project(
    at[0] + axis[0] * eps,
    at[1] + axis[1] * eps,
    at[2] + axis[2] * eps,
  );
  return Offset((x1 - x0) / eps, (y1 - y0) / eps);
}

/// 手柄拖拽:沿各激活轴改尺寸,对面保持不动。
///
/// 逐轴把屏幕位移投影到该轴的屏幕方向上(最小二乘的对角近似 —— 轴间近
/// 共线时最小二乘病态,逐轴投影稳定,是 gizmo 的标准做法)。
SelectionBox applyHandle3DDrag({
  required SelectionBox box,
  required CloudProjection proj,
  required BoxHandle3D handle,
  required Offset screenDelta,
  required double minHalfSize,
}) {
  final axes = boxWorldAxes(box);
  final at = handleWorldPos(box, handle);
  final sgn = [handle.sx, handle.sy, handle.sz];
  final sizes = [box.sx, box.sy, box.sz];
  var cx = box.cx, cy = box.cy, cz = box.cz;
  final newSizes = [...sizes];

  // [2026-07-28 用户实机指认"框仍然不是立方体"] 近视线轴必须禁用:轴越
  // 接近视线,它的屏幕方向越短,而 dWorld = ⟨Δ,dir⟩/|dir|² 要除以这个长度
  // 的平方 —— |dir| 掉到基准的 1/30 时,拖 10px 会改出 30 倍的世界位移,
  // 一下就把盒压成纸片(用户截图里的四边形"框"就是被压扁的立方体)。
  // 基准 = 该深度下的 像素/世界单位;低于 25% 视为不可操作,整轴跳过。
  final (_, _, atDepth) = proj.project(at[0], at[1], at[2]);
  final refPxPerWorld = 1.0 / proj.worldPerPixelAt(atDepth);
  final minDirLen = refPxPerWorld * 0.25;

  for (var k = 0; k < 3; k++) {
    if (sgn[k] == 0) continue;
    final dir = _axisScreenDir(proj, at, axes[k]);
    final len2 = dir.dx * dir.dx + dir.dy * dir.dy;
    if (len2 < minDirLen * minDirLen) continue; // 该轴近视线,不可靠
    // 屏幕位移在该轴屏幕方向上的世界位移量。
    final dWorld = (screenDelta.dx * dir.dx + screenDelta.dy * dir.dy) / len2;
    final want = sizes[k] + sgn[k] * dWorld;
    final clamped = math.max(want, minHalfSize * 2);
    final deltaSize = clamped - sizes[k];
    if (deltaSize == 0) continue;
    newSizes[k] = clamped;
    // 对面固定 ⇒ 盒心沿该轴移动 sgn·Δsize/2。
    final shift = sgn[k] * deltaSize / 2;
    cx += axes[k][0] * shift;
    cy += axes[k][1] * shift;
    cz += axes[k][2] * shift;
  }

  return box.copyWith(
    cx: cx,
    cy: cy,
    cz: cz,
    sx: newSizes[0],
    sy: newSizes[1],
    sz: newSizes[2],
  );
}

/// 盒 8 角投影的凸包(逆时针,Andrew monotone chain)。
List<Offset> boxSilhouette(SelectionBox b, CloudProjection proj) {
  final pts =
      selectionBoxCorners(b).map((w) {
        final (x, y, _) = proj.project(w[0], w[1], w[2]);
        return Offset(x, y);
      }).toList()..sort(
        (p, q) => p.dx != q.dx ? p.dx.compareTo(q.dx) : p.dy.compareTo(q.dy),
      );
  double cross(Offset o, Offset a, Offset c) =>
      (a.dx - o.dx) * (c.dy - o.dy) - (a.dy - o.dy) * (c.dx - o.dx);
  final lower = <Offset>[];
  for (final p in pts) {
    while (lower.length >= 2 &&
        cross(lower[lower.length - 2], lower.last, p) <= 0) {
      lower.removeLast();
    }
    lower.add(p);
  }
  final upper = <Offset>[];
  for (final p in pts.reversed) {
    while (upper.length >= 2 &&
        cross(upper[upper.length - 2], upper.last, p) <= 0) {
      upper.removeLast();
    }
    upper.add(p);
  }
  lower.removeLast();
  upper.removeLast();
  return [...lower, ...upper];
}

/// 点是否落在盒的屏幕轮廓内(决定单指拖是"平移框"还是"转视角")。
bool pointInBoxSilhouette(SelectionBox b, CloudProjection proj, Offset p) {
  final hull = boxSilhouette(b, proj);
  if (hull.length < 3) return false;
  var sign = 0;
  for (var i = 0; i < hull.length; i++) {
    final a = hull[i], c = hull[(i + 1) % hull.length];
    final cr = (c.dx - a.dx) * (p.dy - a.dy) - (c.dy - a.dy) * (p.dx - a.dx);
    if (cr.abs() < 1e-9) continue;
    final s = cr > 0 ? 1 : -1;
    if (sign == 0) {
      sign = s;
    } else if (s != sign) {
      return false;
    }
  }
  return true;
}

/// 空白拖动整盒平移(视平面 right/up × worldPerPixelAt)。
///
/// ⚠️ Controller resolution(binding,覆盖 brief 原始实现):Task 2 实测
/// 锁定 `upAxisWorld()` 返回的是**屏幕 −y(向上)**方向的世界向量(该函数
/// 注释已写明),`rightAxisWorld()` 是屏幕 +x(向右)。brief 原式
/// `c? + (r·dx + u·dy)·wpp` 会让垂直方向反向(往下拖 dy>0 却把盒往屏幕
/// 上方移)。这里改为垂直分量取 `−screenDelta.dy`:
/// screenDelta.dy>0(手指下拖)对应"屏幕向下" = up 的反方向,故世界位移
/// 沿 up 的分量是 `u · (−dy)`。
SelectionBox applyBoxPan({
  required SelectionBox box,
  required CloudProjection proj,
  required Offset screenDelta,
  required double depth,
}) {
  final wpp = proj.worldPerPixelAt(depth);
  final r = proj.rightAxisWorld();
  final u = proj.upAxisWorld();
  final dx = screenDelta.dx;
  final dy = -screenDelta.dy; // controller correction:垂直分量反号
  return box.copyWith(
    cx: box.cx + (r[0] * dx + u[0] * dy) * wpp,
    cy: box.cy + (r[1] * dx + u[1] * dy) * wpp,
    cz: box.cz + (r[2] * dx + u[2] * dy) * wpp,
  );
}

/// 3D bound-box gizmo 手柄绘制:8 角(大点)+ 6 面中心(小点),画在盒的
/// 真实角/面投影上 —— 透视下自动贴合线框,背面手柄淡显以保留体积感。
class BoxHandlesPainter extends CustomPainter {
  const BoxHandlesPainter({required this.box, required this.proj});

  final SelectionBox box;
  final CloudProjection proj;

  @override
  void paint(Canvas canvas, Size size) {
    final (_, _, centerDepth) = proj.project(box.cx, box.cy, box.cz);
    final items = <({Offset p, double depth, bool corner})>[];
    for (final h in kBoxHandles3D) {
      final w = handleWorldPos(box, h);
      final (sx, sy, depth) = proj.project(w[0], w[1], w[2]);
      items.add((p: Offset(sx, sy), depth: depth, corner: isCornerHandle(h)));
    }
    items.sort((a, b) => b.depth.compareTo(a.depth));
    for (final it in items) {
      final front = it.depth <= centerDepth;
      canvas.drawCircle(
        it.p,
        it.corner ? 8.5 : 6.0,
        Paint()
          ..color = front ? const Color(0xFFFFFFFF) : const Color(0x66FFFFFF),
      );
    }
  }

  @override
  bool shouldRepaint(covariant BoxHandlesPainter old) =>
      old.box != box || old.proj != proj;
}
