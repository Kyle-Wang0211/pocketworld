// selection_rect_handles.dart — RS Mobile 同款 2D 矩形手柄(纯函数 + 绘制)。
//
// [2026-07-29 用户签决] 回退到 RS 2D 框:框 = 当前(正交)视角下盒投影的
// 屏幕对齐矩形,角手柄双轴、边手柄单轴。从 3D bound-box gizmo 退回本方案
// (b3588f6 之前的实现,原样搬回),挂到共通的 SparseCloudView 编辑路径。
// 纯函数经 selection_rect_math_test 充分守门。
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../official_capture/selection_box.dart';
import 'cloud_camera.dart';

enum RectHandle {
  cornerTL,
  cornerTR,
  cornerBL,
  cornerBR,
  edgeL,
  edgeR,
  edgeT,
  edgeB,
}

class BoxScreenBasis {
  const BoxScreenBasis({
    required this.hAxis,
    required this.vAxis,
    required this.hSx,
    required this.vSy,
    required this.axSx,
    required this.axSy,
    required this.scale,
    required this.cxS,
    required this.cyS,
  });

  /// 屏幕水平/垂直方向对应的盒局部轴(0:x 1:y 2:z)。
  final int hAxis, vAxis;

  /// 该局部轴单位向量的屏幕分量(带符号;拖拽方向映射用)。
  final double hSx, vSy;

  /// 局部三轴单位向量的屏幕 x / y 分量(px per 世界长度,带符号)。
  ///
  /// 矩形边长不能用"盒沿某轴的尺寸 × scale" —— 那只在该局部轴与屏幕轴平行时
  /// 成立。框允许任意朝向(滑轨转框 + 用户自由转视角),斜朝向下真实投影宽度
  /// 是三轴投影分量的绝对值之和,必须逐轴累加。
  final List<double> axSx, axSy;

  /// f / centerDepth —— 世界长度 → 屏幕像素(正交近似)。
  final double scale;

  /// 盒中心屏幕坐标。
  final double cxS, cyS;
}

/// 盒局部三轴 → 屏幕方向(投影差分,符号自动正确)。
BoxScreenBasis boxScreenBasis(CloudProjection proj, SelectionBox box) {
  // 盒局部轴单位向量的世界方向 = box.rot 的列(与 selectionBoxCorners 的
  // 正变换 world=rot·local 一致)。[2026-07-29 支持任意朝向框:滑轨改横轴
  // 翻滚后框不再只绕竖直轴,不能再用 yawDeg 重建。]
  final r = box.rot;
  final axes = [
    [r[0], r[3], r[6]], // 局部 +x
    [r[1], r[4], r[7]], // 局部 +y
    [r[2], r[5], r[8]], // 局部 +z
  ];
  final (c0x, c0y, d0) = proj.project(box.cx, box.cy, box.cz);
  const eps = 1e-3;
  final sx = List<double>.filled(3, 0);
  final sy = List<double>.filled(3, 0);
  for (var a = 0; a < 3; a++) {
    final (px, py, _) = proj.project(
      box.cx + axes[a][0] * eps,
      box.cy + axes[a][1] * eps,
      box.cz + axes[a][2] * eps,
    );
    sx[a] = (px - c0x) / eps;
    sy[a] = (py - c0y) / eps;
  }
  // 水平轴取屏幕 x 分量最大者;垂直轴只在**剩下两轴**里选 —— 独立取最大时
  // 两者会撞到同一轴(例:框斜 45° + 正俯视,x/z 的 |sx|、|sy| 全相等),
  // release 下 assert 不生效,basis 就是坏的。
  var h = 0;
  for (var a = 1; a < 3; a++) {
    if (sx[a].abs() > sx[h].abs()) h = a;
  }
  var v = -1;
  for (var a = 0; a < 3; a++) {
    if (a == h) continue;
    if (v < 0 || sy[a].abs() > sy[v].abs()) v = a;
  }
  return BoxScreenBasis(
    hAxis: h,
    vAxis: v,
    hSx: sx[h],
    vSy: sy[v],
    axSx: sx,
    axSy: sy,
    // 正交下缩放与深度无关(f/camDist,矩形与盒投影严格重合 —— 守门测试
    // 锁);透视下保留旧口径(盒中心深度的正交近似)。
    scale: proj.orthographic ? proj.f / proj.camDist : proj.f / d0,
    cxS: c0x,
    cyS: c0y,
  );
}

double _sizeOfAxis(SelectionBox b, int axis) =>
    axis == 0 ? b.sx : (axis == 1 ? b.sy : b.sz);

/// 盒投影的屏幕对齐外接矩形。
///
/// 逐轴累加 |半尺寸 × 该轴屏幕分量| —— 这就是有朝向盒投影的支撑函数,任意朝向
/// / 任意视角下都严格等于盒 8 角投影的包围盒(正交下逐位相等,守门测试锁)。
/// 轴对齐时退化为旧口径 size/2 × scale,既有 11 例守门逐位不变。
ui.Rect selectionScreenRect(BoxScreenBasis b, SelectionBox box) {
  var hw = 0.0, hh = 0.0;
  for (var a = 0; a < 3; a++) {
    final half = _sizeOfAxis(box, a) / 2;
    hw += half * b.axSx[a].abs();
    hh += half * b.axSy[a].abs();
  }
  return ui.Rect.fromCenter(
    center: ui.Offset(b.cxS, b.cyS),
    width: hw * 2,
    height: hh * 2,
  );
}

ui.Offset _handlePos(ui.Rect r, RectHandle h) => switch (h) {
  RectHandle.cornerTL => r.topLeft,
  RectHandle.cornerTR => r.topRight,
  RectHandle.cornerBL => r.bottomLeft,
  RectHandle.cornerBR => r.bottomRight,
  RectHandle.edgeL => ui.Offset(r.left, r.center.dy),
  RectHandle.edgeR => ui.Offset(r.right, r.center.dy),
  RectHandle.edgeT => ui.Offset(r.center.dx, r.top),
  RectHandle.edgeB => ui.Offset(r.center.dx, r.bottom),
};

RectHandle? hitRectHandle(ui.Rect r, ui.Offset tap, {double tolPx = 34}) {
  RectHandle? best;
  var bestD2 = tolPx * tolPx;
  for (final h in RectHandle.values) {
    final p = _handlePos(r, h);
    final dx = p.dx - tap.dx, dy = p.dy - tap.dy;
    final d2 = dx * dx + dy * dy;
    if (d2 < bestD2) {
      bestD2 = d2;
      best = h;
    }
  }
  return best;
}

/// 手柄 → (是否控水平轴, 屏幕方向符号) ×(是否控垂直轴, 符号)。
/// 屏幕符号:+1 = 该手柄在矩形的右/下侧。
(({bool on, int side}), ({bool on, int side})) _handleControl(RectHandle h) =>
    switch (h) {
      RectHandle.cornerTL => ((on: true, side: -1), (on: true, side: -1)),
      RectHandle.cornerTR => ((on: true, side: 1), (on: true, side: -1)),
      RectHandle.cornerBL => ((on: true, side: -1), (on: true, side: 1)),
      RectHandle.cornerBR => ((on: true, side: 1), (on: true, side: 1)),
      RectHandle.edgeL => ((on: true, side: -1), (on: false, side: 0)),
      RectHandle.edgeR => ((on: true, side: 1), (on: false, side: 0)),
      RectHandle.edgeT => ((on: false, side: 0), (on: true, side: -1)),
      RectHandle.edgeB => ((on: false, side: 0), (on: true, side: 1)),
    };

SelectionBox applyRectHandleDrag({
  required SelectionBox box,
  required BoxScreenBasis basis,
  required RectHandle h,
  required ui.Offset screenDelta,
  required double minHalfSize,
}) {
  final (hc, vc) = _handleControl(h);
  var out = box;
  if (hc.on) {
    // 屏幕上"往外拖"(delta 与手柄侧同号)= 该侧外扩。
    final growPx = screenDelta.dx * hc.side;
    // 受控的是局部 hAxis;该手柄对应局部面的符号 = 屏幕侧 × 轴屏幕方向符号
    final faceSign = hc.side * (basis.hSx >= 0 ? 1 : -1);
    // 矩形边对该局部轴的敏感度 = |轴的屏幕 x 分量|(斜朝向下 < scale);用
    // scale 会让斜框拖不跟手。轴对齐时二者相等。
    out = _growAxis(
      out,
      basis.hAxis,
      faceSign,
      growPx / _sensitivity(basis.axSx[basis.hAxis], basis.scale),
      minHalfSize,
    );
  }
  if (vc.on) {
    final growPx = screenDelta.dy * vc.side;
    final faceSign = vc.side * (basis.vSy >= 0 ? 1 : -1);
    out = _growAxis(
      out,
      basis.vAxis,
      faceSign,
      growPx / _sensitivity(basis.axSy[basis.vAxis], basis.scale),
      minHalfSize,
    );
  }
  return out;
}

/// 轴近乎垂直于该屏幕方向时敏感度 →0,除法会把拖动放大成纸片/巨盒;
/// 退回 scale 兜底(该轴本来就不该被这个手柄控,选轴已优先避开)。
double _sensitivity(double axisScreenComponent, double scale) {
  final s = axisScreenComponent.abs();
  return s > scale.abs() * 0.25 ? s : scale.abs();
}

/// 局部轴 axis 的 faceSign 面外扩 grow(世界长度;负=收缩),对面不动。
SelectionBox _growAxis(
  SelectionBox b,
  int axis,
  int faceSign,
  double grow,
  double minHalfSize,
) {
  final old = _sizeOfAxis(b, axis);
  final next = math.max(old + grow, minHalfSize * 2);
  final applied = next - old;
  // 中心沿该局部轴世界方向补偿一半(rot 列,任意朝向通用)。
  final r = b.rot;
  final shift = faceSign * applied / 2;
  final dx = r[axis] * shift;
  final dy = r[3 + axis] * shift;
  final dz = r[6 + axis] * shift;
  return b.copyWith(
    cx: b.cx + dx,
    cy: b.cy + dy,
    cz: b.cz + dz,
    sx: axis == 0 ? next : b.sx,
    sy: axis == 1 ? next : b.sy,
    sz: axis == 2 ? next : b.sz,
  );
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
  required ui.Offset screenDelta,
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

/// 手柄在矩形上的屏幕位置(公开:命中反查与绘制共用)。
ui.Offset handleRectPos(ui.Rect r, RectHandle h) => _handlePos(r, h);

/// RS Mobile 同款:白描边矩形 + 4 角圆点 + 4 边中点圆角胶囊。
class RectHandlesPainter extends CustomPainter {
  const RectHandlesPainter({required this.rect});
  final ui.Rect rect;

  static const _kHandleColor = Color(0xFFFFFFFF);
  static const _kStrokeColor = Color(0xCCFFFFFF);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = _kStrokeColor
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    canvas.drawRect(rect, stroke);
    final fill = Paint()..color = _kHandleColor;
    for (final h in [
      RectHandle.cornerTL,
      RectHandle.cornerTR,
      RectHandle.cornerBL,
      RectHandle.cornerBR,
    ]) {
      canvas.drawCircle(_handlePos(rect, h), 9, fill);
    }
    for (final h in [RectHandle.edgeL, RectHandle.edgeR]) {
      final p = _handlePos(rect, h);
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(
          ui.Rect.fromCenter(center: p, width: 8, height: 22),
          const ui.Radius.circular(4),
        ),
        fill,
      );
    }
    for (final h in [RectHandle.edgeT, RectHandle.edgeB]) {
      final p = _handlePos(rect, h);
      canvas.drawRRect(
        ui.RRect.fromRectAndRadius(
          ui.Rect.fromCenter(center: p, width: 22, height: 8),
          const ui.Radius.circular(4),
        ),
        fill,
      );
    }
  }

  @override
  bool shouldRepaint(covariant RectHandlesPainter old) => old.rect != rect;
}
