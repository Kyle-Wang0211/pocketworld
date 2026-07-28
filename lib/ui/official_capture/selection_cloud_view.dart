// selection_cloud_view.dart — 选区页渲染 + 3D bound-box gizmo。
//
// [2026-07-28 用户签决] "预览跟编辑就是一个页面,点下一步只是让工具显现
// 出来" ⇒ 与预览页**同一投影(透视)、同一相机**,进编辑零跳变;框改
// 3D(见 selection_handles_3d.dart)。相机由父页面持有(骰子要跟随同一
// 姿态),本视图只上报增量。
//
// 手势路由:双指 = 平移视角 + 柔和缩放(预览页同款 0.08 阻尼);单指命中
// 手柄 = 改盒尺寸;单指落在盒轮廓内 = 平移盒;单指落在盒外 = 自由 orbit。
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../official_capture/selection_box.dart';
import 'cloud_camera.dart';
import 'selection_handles_3d.dart';
import 'sparse_cloud_view.dart' show CloudViewCamera, SparseCloudPainter;

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
    required this.camera,
    required this.onCameraChanged,
    this.viewRoll = 0,
    this.liveBox,
  });

  /// 3 floats per point(full set)。
  final Float32List xyz;

  /// 3 bytes per point。
  final Uint8List rgb;

  /// 当前选区盒(受控组件:变更经 onBoxChanged 上报,不在内部持有真值)。
  final SelectionBox box;
  final ValueChanged<SelectionBox> onBoxChanged;

  /// [2026-07-28 用户签决"旋转刻度尺与拖框可同时"] 手势读数用的**同步**
  /// 真值源:widget.box 要等父级 build 才刷新,双写者(框手势+旋转刻度
  /// 尺)同帧并发时各自的快照会互相覆盖(转着转着框被手柄流回滚)。
  /// 父级 setState 是同步写,经此 getter 每个触摸事件都拿到最新盒,
  /// 交错应用互不覆盖。null 时退回手势期快照(_gestureBox)。
  final SelectionBox Function()? liveBox;

  /// 视角 yaw(**已含**滑杆分量 —— Task 5 传 preset.yaw + box.yawDeg·π/180)。
  final double viewYaw;
  final double viewPitch;

  /// 屏幕滚转(过极翻面动画期间非零;见 CloudCamera.roll)。
  final double viewRoll;

  /// 相机(缩放/平移/枢轴)。yaw/pitch/roll 走上面三个字段(父级还要喂
  /// 骰子),这里取 zoom/panX/panY/pivot。
  final CloudViewCamera camera;

  /// 自由 orbit / 双指平移缩放的增量上报(父级是相机唯一真值源)。
  final ValueChanged<CloudViewCamera> onCameraChanged;

  @override
  State<SelectionCloudView> createState() => _SelectionCloudViewState();
}

enum _DragMode { none, handle, panBox, orbit }

class _SelectionCloudViewState extends State<SelectionCloudView> {
  BoxHandle3D? _activeHandle;
  _DragMode _mode = _DragMode.none;
  Size _viewSize = Size.zero;
  late ({double cx, double cy, double cz, double radius}) _fit;

  /// 视角俯仰限位(与预览页同值,躲开极点奇异)。
  static const double _kPitchLimit = math.pi / 2 - 0.02;

  @override
  void initState() {
    super.initState();
    _fit = SparseCloudPainter.fitOf(widget.xyz);
  }

  CloudProjection _projectionFor(Size size, {double? yawOverride}) =>
      CloudCamera(
        yaw: yawOverride ?? widget.viewYaw,
        pitch: widget.viewPitch,
        zoom: widget.camera.zoom,
        panX: widget.camera.panX,
        panY: widget.camera.panY,
        pivotX: widget.camera.pivotX,
        pivotY: widget.camera.pivotY,
        pivotZ: widget.camera.pivotZ,
        radius: _fit.radius,
        // [2026-07-28 用户签决"预览跟编辑是一个页面"] 与预览页同为透视:
        // 投影不同就会在进入编辑时跳变。框外全红的视觉一致性改由 3D 线框
        // + 3D 手柄保证(手柄就是盒的真实角/面投影,永远贴合)。
        orthographic: false,
        roll: widget.viewRoll,
      ).projectionFor(size);

  /// 手势期间的盒累积基准。⚠️不能每次 update 用 widget.box 做基准:
  /// 触摸事件一帧可到多个,widget.box 要等父级 setState 重建后才刷新,
  /// 同帧后到的事件会用同一个旧盒**覆盖**前一个的增量 —— 大半拖动量被吞,
  /// 实机观感"框拖不动/阻力大"(与 RulerScrubber 同根因,用户两次指认)。
  SelectionBox? _gestureBox;

  /// 手势用最新盒 + 与之匹配的 yaw 修正(滑杆同帧刚转过的角度,
  /// widget.viewYaw 还没跟上,按最短环向差补齐,盒与投影严格同系)。
  (SelectionBox, CloudProjection) _liveBoxAndProj() {
    final base = widget.liveBox?.call() ?? _gestureBox ?? widget.box;
    var dyaw = (base.yawDeg - widget.box.yawDeg) % 360.0;
    if (dyaw > 180.0) dyaw -= 360.0;
    final proj = _projectionFor(
      _viewSize,
      yawOverride: widget.viewYaw + dyaw * math.pi / 180.0,
    );
    return (base, proj);
  }

  void _onScaleStart(ScaleStartDetails d) {
    if (_viewSize.isEmpty) return;
    final (base, proj) = _liveBoxAndProj();
    final handle = hitBoxHandle3D(base, proj, d.localFocalPoint);
    _activeHandle = handle;
    if (handle != null) {
      _mode = _DragMode.handle;
    } else if (pointInBoxSilhouette(base, proj, d.localFocalPoint)) {
      _mode = _DragMode.panBox;
    } else {
      // [2026-07-28 用户签决] 盒外单指 = 自由 orbit(像预览页那样随便转)。
      _mode = _DragMode.orbit;
    }
    _gestureBox = base;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    if (_viewSize.isEmpty) return;
    if (d.pointerCount >= 2) {
      // 双指 = 平移视角 + 缩放(预览页同款柔和 0.08 阻尼)。
      final cam = widget.camera;
      widget.onCameraChanged((
        yaw: cam.yaw,
        pitch: cam.pitch,
        zoom: d.scale != 1.0
            ? (cam.zoom * (1 + (d.scale - 1) * 0.08)).clamp(0.15, 20.0)
            : cam.zoom,
        panX: cam.panX + d.focalPointDelta.dx,
        panY: cam.panY + d.focalPointDelta.dy,
        pivotX: cam.pivotX,
        pivotY: cam.pivotY,
        pivotZ: cam.pivotZ,
      ));
      return;
    }
    if (_mode == _DragMode.orbit) {
      // 与预览页逐字同款(含符号与系数):拖右 → 场景右转。
      final cam = widget.camera;
      widget.onCameraChanged((
        yaw: cam.yaw - d.focalPointDelta.dx * 0.008,
        pitch: (cam.pitch + d.focalPointDelta.dy * 0.006).clamp(
          -_kPitchLimit,
          _kPitchLimit,
        ),
        zoom: cam.zoom,
        panX: cam.panX,
        panY: cam.panY,
        pivotX: cam.pivotX,
        pivotY: cam.pivotY,
        pivotZ: cam.pivotZ,
      ));
      return;
    }
    final (base, proj) = _liveBoxAndProj();
    if (_mode == _DragMode.handle && _activeHandle != null) {
      final next = applyHandle3DDrag(
        box: base,
        proj: proj,
        handle: _activeHandle!,
        screenDelta: d.focalPointDelta,
        minHalfSize: _fit.radius * SelectionBox.kMinHalfSizeFraction,
      );
      _gestureBox = next;
      widget.onBoxChanged(next);
    } else if (_mode == _DragMode.panBox) {
      final (_, _, depth) = proj.project(base.cx, base.cy, base.cz);
      final next = applyBoxPan(
        box: base,
        proj: proj,
        screenDelta: d.focalPointDelta,
        depth: depth,
      );
      _gestureBox = next;
      widget.onBoxChanged(next);
    }
  }

  void _onScaleEnd(ScaleEndDetails d) {
    _activeHandle = null;
    _mode = _DragMode.none;
    _gestureBox = null;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _viewSize = constraints.biggest;
        final proj = _projectionFor(_viewSize);
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
                    zoom: widget.camera.zoom,
                    panX: widget.camera.panX,
                    panY: widget.camera.panY,
                    pivotX: widget.camera.pivotX,
                    pivotY: widget.camera.pivotY,
                    pivotZ: widget.camera.pivotZ,
                    pointSize: 2.67,
                    exposure: 1.0,
                    tone: 2,
                    selectionBox: widget.box,
                    // 3D 线框(12 边)—— 与红点判定是同一个盒,永远吻合。
                    drawSelectionWireframe: true,
                    orthographic: false,
                    roll: widget.viewRoll,
                  ),
                  size: Size.infinite,
                ),
              ),
              Positioned.fill(
                child: CustomPaint(
                  painter: _Handles3DPainter(box: widget.box, proj: proj),
                ),
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

/// 3D bound-box gizmo 手柄:8 角(大圆点)+ 6 面中心(小圆点),画在盒的
/// 真实角/面投影上 —— 透视下自动贴合线框,背面手柄淡显以保留体积感。
class _Handles3DPainter extends CustomPainter {
  const _Handles3DPainter({required this.box, required this.proj});

  final SelectionBox box;
  final CloudProjection proj;

  @override
  void paint(Canvas canvas, Size size) {
    final (_, _, centerDepth) = proj.project(box.cx, box.cy, box.cz);
    // 远的先画,近的后画(无深度缓冲的画家算法)。
    final items = <({Offset p, double depth, bool corner})>[];
    for (final h in kBoxHandles3D) {
      final w = handleWorldPos(box, h);
      final (sx, sy, depth) = proj.project(w[0], w[1], w[2]);
      items.add((p: Offset(sx, sy), depth: depth, corner: isCornerHandle(h)));
    }
    items.sort((a, b) => b.depth.compareTo(a.depth));
    for (final it in items) {
      final front = it.depth <= centerDepth;
      final paint = Paint()
        ..color = front ? const Color(0xFFFFFFFF) : const Color(0x66FFFFFF);
      canvas.drawCircle(it.p, it.corner ? 8.5 : 6.0, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _Handles3DPainter old) =>
      old.box != box || old.proj != proj;
}
