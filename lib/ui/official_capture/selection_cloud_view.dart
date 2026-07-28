// selection_cloud_view.dart — 选区页专用渲染 + RS Mobile 同款 2D 矩形手柄。
//
// [2026-07-27 调研修订] RS Mobile 官方:角手柄=双轴、边手柄=单轴、框是
// 当前视角的屏幕对齐矩形(不是 3D 线框)。矩形用盒中心深度统一缩放
// (正交近似),拖拽逆映射用同一深度 —— 往返自洽;框是控制器 UI,不是
// 几何贴合线。盒局部轴的屏幕方向由投影差分求得,零手写映射表。
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../official_capture/selection_box.dart';
import 'cloud_camera.dart';
import 'sparse_cloud_view.dart' show SparseCloudPainter;

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
  final t = box.yawDeg * math.pi / 180.0;
  final c = math.cos(t), s = math.sin(t);
  // 盒局部轴单位向量的世界方向(corners 正变换的列向量)
  final axes = [
    [c, 0.0, s], // 局部 +x
    [0.0, 1.0, 0.0], // 局部 +y
    [-s, 0.0, c], // 局部 +z
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
  // 中心沿该局部面方向补偿一半(局部 → 世界用 corners 正变换)
  final t = b.yawDeg * math.pi / 180.0;
  final c = math.cos(t), s = math.sin(t);
  final shift = faceSign * applied / 2;
  double dx = 0, dy = 0, dz = 0;
  if (axis == 0) {
    dx = shift * c;
    dz = shift * s;
  } else if (axis == 1) {
    dy = shift;
  } else {
    dx = -shift * s;
    dz = shift * c;
  }
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

// ─── SelectionCloudView widget ──────────────────────────────────────────

/// 选区页专用视图:点云(框外红)+ RS Mobile 同款 2D 矩形手柄(角/边)。
/// 不画 3D 线框(那是草稿只读回显用的,见 SparseCloudPainter
/// drawSelectionWireframe)。
class SelectionCloudView extends StatefulWidget {
  const SelectionCloudView({
    super.key,
    required this.xyz,
    required this.rgb,
    required this.box,
    required this.onBoxChanged,
    required this.viewYaw,
    required this.viewPitch,
    this.viewRoll = 0,
  });

  /// 3 floats per point(full set)。
  final Float32List xyz;

  /// 3 bytes per point。
  final Uint8List rgb;

  /// 当前选区盒(受控组件:变更经 onBoxChanged 上报,不在内部持有真值)。
  final SelectionBox box;
  final ValueChanged<SelectionBox> onBoxChanged;

  /// 视角 yaw(**已含**滑杆分量 —— Task 5 传 preset.yaw + box.yawDeg·π/180)。
  final double viewYaw;
  final double viewPitch;

  /// 屏幕滚转(过极翻面动画期间非零;见 CloudCamera.roll)。
  final double viewRoll;

  @override
  State<SelectionCloudView> createState() => _SelectionCloudViewState();
}

class _SelectionCloudViewState extends State<SelectionCloudView> {
  double _zoom = 1.0;
  RectHandle? _activeHandle;
  bool _panningBox = false;
  Size _viewSize = Size.zero;
  late ({double cx, double cy, double cz, double radius}) _fit;

  @override
  void initState() {
    super.initState();
    _fit = SparseCloudPainter.fitOf(widget.xyz);
  }

  CloudProjection _projectionFor(Size size) => CloudCamera(
    yaw: widget.viewYaw,
    pitch: widget.viewPitch,
    zoom: _zoom,
    panX: 0,
    panY: 0,
    pivotX: _fit.cx,
    pivotY: _fit.cy,
    pivotZ: _fit.cz,
    radius: _fit.radius,
    // [2026-07-27 用户签决"框外必须全红"] 编辑视图正交:矩形/手柄/拖拽
    // 逆映射与点云渲染(painter 同模式)在同一正交空间,零透视错位。
    orthographic: true,
    roll: widget.viewRoll,
  ).projectionFor(size);

  void _onScaleStart(ScaleStartDetails d) {
    if (_viewSize.isEmpty) return;
    final proj = _projectionFor(_viewSize);
    final basis = boxScreenBasis(proj, widget.box);
    final rect = selectionScreenRect(basis, widget.box);
    final handle = hitRectHandle(rect, d.localFocalPoint);
    _activeHandle = handle;
    _panningBox = handle == null && rect.contains(d.localFocalPoint);
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_viewSize.isEmpty) return;
    if (d.pointerCount >= 2) {
      // 双指捏合缩放视角(与手柄/平移互斥)。
      if (d.scale != 1.0) {
        setState(() {
          _zoom = (_zoom * d.scale).clamp(0.3, 6.0);
        });
      }
      return;
    }
    final proj = _projectionFor(_viewSize);
    final basis = boxScreenBasis(proj, widget.box);
    if (_activeHandle != null) {
      final minHalfSize = _fit.radius * SelectionBox.kMinHalfSizeFraction;
      final next = applyRectHandleDrag(
        box: widget.box,
        basis: basis,
        h: _activeHandle!,
        screenDelta: d.focalPointDelta,
        minHalfSize: minHalfSize,
      );
      widget.onBoxChanged(next);
    } else if (_panningBox) {
      final (_, _, depth) = proj.project(
        widget.box.cx,
        widget.box.cy,
        widget.box.cz,
      );
      final next = applyBoxPan(
        box: widget.box,
        proj: proj,
        screenDelta: d.focalPointDelta,
        depth: depth,
      );
      widget.onBoxChanged(next);
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    _activeHandle = null;
    _panningBox = false;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewSize = constraints.biggest;
        final proj = _projectionFor(_viewSize);
        final basis = boxScreenBasis(proj, widget.box);
        final rect = selectionScreenRect(basis, widget.box);
        return GestureDetector(
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: SparseCloudPainter(
                    xyz: widget.xyz,
                    rgb: widget.rgb,
                    sprite: _sprite,
                    yaw: widget.viewYaw,
                    pitch: widget.viewPitch,
                    zoom: _zoom,
                    panX: 0,
                    panY: 0,
                    pivotX: _fit.cx,
                    pivotY: _fit.cy,
                    pivotZ: _fit.cz,
                    pointSize: 2.67,
                    exposure: 1.0,
                    tone: 2,
                    selectionBox: widget.box,
                    drawSelectionWireframe: false,
                    // [2026-07-27 用户签决"框外必须全红"] 编辑视图用正交:
                    // 矩形与盒投影严格重合,屏幕框外 ⇔ 可见两轴出盒 ⇔ 红。
                    orthographic: true,
                    roll: widget.viewRoll,
                  ),
                  size: Size.infinite,
                ),
              ),
              Positioned.fill(
                child: CustomPaint(painter: _RectHandlesPainter(rect: rect)),
              ),
            ],
          ),
        );
      },
    );
  }

  ui.Image? _sprite;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ensureSprite();
  }

  Future<void> _ensureSprite() async {
    if (_sprite != null) return;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawCircle(
      const Offset(8, 8),
      7,
      Paint()
        ..color = Colors.white
        ..isAntiAlias = true,
    );
    final img = await rec.endRecording().toImage(16, 16);
    if (mounted) setState(() => _sprite = img);
  }
}

/// 白描边矩形 + 4 角圆点 + 4 边中点圆角胶囊(RS Mobile 同款 2D 手柄)。
class _RectHandlesPainter extends CustomPainter {
  const _RectHandlesPainter({required this.rect});
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
      final capsule = ui.RRect.fromRectAndRadius(
        ui.Rect.fromCenter(center: p, width: 8, height: 22),
        const ui.Radius.circular(4),
      );
      canvas.drawRRect(capsule, fill);
    }
    for (final h in [RectHandle.edgeT, RectHandle.edgeB]) {
      final p = _handlePos(rect, h);
      final capsule = ui.RRect.fromRectAndRadius(
        ui.Rect.fromCenter(center: p, width: 22, height: 8),
        const ui.Radius.circular(4),
      );
      canvas.drawRRect(capsule, fill);
    }
  }

  @override
  bool shouldRepaint(covariant _RectHandlesPainter old) => old.rect != rect;
}
