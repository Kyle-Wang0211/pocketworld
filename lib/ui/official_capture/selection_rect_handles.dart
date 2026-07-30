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
    required this.scale,
    required this.cxS,
    required this.cyS,
  });

  /// 屏幕水平/垂直方向对应的盒局部轴(0:x 1:y 2:z)。
  final int hAxis, vAxis;

  /// 该局部轴单位向量的屏幕分量(带符号;拖拽方向映射用)。
  final double hSx, vSy;

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
  var h = 0, v = 0;
  for (var a = 1; a < 3; a++) {
    if (sx[a].abs() > sx[h].abs()) h = a;
    if (sy[a].abs() > sy[v].abs()) v = a;
  }
  assert(h != v, 'boxScreenBasis: 视角退化,水平/垂直命中同一局部轴');
  return BoxScreenBasis(
    hAxis: h,
    vAxis: v,
    hSx: sx[h],
    vSy: sy[v],
    // 正交下缩放与深度无关(f/camDist,矩形与盒投影严格重合 —— 守门测试
    // 锁);透视下保留旧口径(盒中心深度的正交近似)。
    scale: proj.orthographic ? proj.f / proj.camDist : proj.f / d0,
    cxS: c0x,
    cyS: c0y,
  );
}

double _sizeOfAxis(SelectionBox b, int axis) =>
    axis == 0 ? b.sx : (axis == 1 ? b.sy : b.sz);

ui.Rect selectionScreenRect(BoxScreenBasis b, SelectionBox box) {
  final hw = _sizeOfAxis(box, b.hAxis) / 2 * b.scale;
  final hh = _sizeOfAxis(box, b.vAxis) / 2 * b.scale;
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
    out = _growAxis(
      out,
      basis.hAxis,
      faceSign,
      growPx / basis.scale,
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
      growPx / basis.scale,
      minHalfSize,
    );
  }
  return out;
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
