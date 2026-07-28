// selection_tools_layer.dart — 选区工具层(骰子 / 旋转刻度尺 / 开始处理)。
//
// [2026-07-28 用户签决] "浏览页面和编辑页面需要是同一个页面 —— 模型的角度
// 和位置自然相同,根本不用做两个画面":不再 push 独立的选区页,点"下一步"
// 只是把这一层**叠**到同一个 SparseCloudView 上。相机自始至终是那一个
// State,连一次重建都没有,所以位置/角度/缩放天然连续。
//
// 本层 = 朝向骰子(跟随相机 + 点击某面归位)+ 返回 + 开始处理。
// [2026-07-28 用户签决] 底部"旋转点云"刻度尺已删除:自由 orbit 上线后它
// 是冗余入口(而且压在全屏点云视图上会跟视图抢手势)。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show DragStartBehavior, Velocity;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../l10n/app_localizations.dart';
import '../../official_capture/selection_box.dart';
import 'sparse_cloud_view.dart' show CloudViewCamera, CloudViewController;
import 'view_cube.dart';

/// 六向朝向预设(骰子点击归位的目标姿态)。
const List<({String label, double yaw, double pitch})> kOrientationPresets = [
  (label: 'Top', yaw: 0, pitch: -math.pi / 2),
  (label: 'Front', yaw: 0, pitch: 0),
  (label: 'Right', yaw: math.pi / 2, pitch: 0),
  (label: 'Back', yaw: math.pi, pitch: 0),
  (label: 'Left', yaw: -math.pi / 2, pitch: 0),
  (label: 'Bottom', yaw: 0, pitch: math.pi / 2),
];

class SelectionToolsLayer extends StatefulWidget {
  const SelectionToolsLayer({
    super.key,
    required this.box,
    required this.onBoxChanged,
    required this.camera,
    required this.controller,
    required this.onExit,
  });

  final SelectionBox box;
  final ValueChanged<SelectionBox> onBoxChanged;

  /// 当前相机(骰子跟随它;归位时经 controller 写回)。用 Listenable 而非
  /// 值传递:相机每帧手势都在变,整页 setState 会白白重建点云层。
  final ValueListenable<CloudViewCamera?> camera;
  final CloudViewController controller;

  /// 返回浏览态(工具层收起)。
  final VoidCallback onExit;

  @override
  State<SelectionToolsLayer> createState() => _SelectionToolsLayerState();
}

class _SelectionToolsLayerState extends State<SelectionToolsLayer>
    with TickerProviderStateMixin {
  late final AnimationController _snap;
  double _fromYaw = 0, _fromPitch = 0, _toYaw = 0, _toPitch = 0;

  /// 骰子甩动惯性(与刻度尺同款 FrictionSimulation)。
  late final AnimationController _fling;
  double _flingYaw0 = 0, _flingPitch0 = 0;
  double _flingDirYaw = 0, _flingDirPitch = 0;

  /// 骰子拖动灵敏度(rad/px)。比点云视图(0.008/0.006)大 2.5 倍 ——
  /// 骰子只有 72px 宽,同样的手指行程要能转得动(用户:"阻力要小")。
  static const double _kCubeYawPerPx = 0.020;
  static const double _kCubePitchPerPx = 0.015;
  static const double _kPitchLimit = math.pi / 2 - 0.02;

  @override
  void initState() {
    super.initState();
    _snap = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..addListener(_onSnapTick);
    _fling = AnimationController.unbounded(vsync: this)
      ..addListener(_onFlingTick);
  }

  @override
  void dispose() {
    _snap.dispose();
    _fling.dispose();
    super.dispose();
  }

  void _applyPose(double yaw, double pitch) {
    final cam = _cam;
    if (cam == null) return;
    widget.controller.moveTo((
      yaw: yaw,
      pitch: pitch.clamp(-_kPitchLimit, _kPitchLimit),
      zoom: cam.zoom,
      panX: cam.panX,
      panY: cam.panY,
      pivotX: cam.pivotX,
      pivotY: cam.pivotY,
      pivotZ: cam.pivotZ,
    ));
  }

  void _onFlingTick() {
    final d = _fling.value;
    _applyPose(
      _flingYaw0 + _flingDirYaw * d,
      _flingPitch0 + _flingDirPitch * d,
    );
  }

  /// [2026-07-28 用户签决] 立方体可自由拖动,点云跟着转(它就是相机的
  /// 另一个把手)。单指拖 = orbit;松手按摩擦模型滑行渐停。
  void _onCubeDragStart() {
    _fling.stop();
    _snap.stop();
  }

  void _onCubeDrag(Offset delta) {
    final cam = _cam;
    if (cam == null) return;
    _applyPose(
      cam.yaw - delta.dx * _kCubeYawPerPx,
      cam.pitch + delta.dy * _kCubePitchPerPx,
    );
  }

  void _onCubeDragEnd(Velocity v) {
    final cam = _cam;
    if (cam == null) return;
    final px = v.pixelsPerSecond;
    final speed = px.distance;
    if (speed < 40) return; // 轻推不甩
    _flingYaw0 = cam.yaw;
    _flingPitch0 = cam.pitch;
    // 单位方向上的角速度(rad/单位距离),距离标量由摩擦模型驱动。
    _flingDirYaw = -px.dx / speed * _kCubeYawPerPx;
    _flingDirPitch = px.dy / speed * _kCubePitchPerPx;
    _fling.value = 0;
    unawaited(_fling.animateWith(FrictionSimulation(0.135, 0, speed)));
  }

  /// 观察方向 = 相机 yaw + 滑杆分量。骰子读它 ⇒ 模型怎么转骰子怎么转
  /// (骰子六面是**模型**的面)。
  double get _boxYawRad => widget.box.yawDeg * math.pi / 180.0;
  CloudViewCamera? get _cam => widget.camera.value;
  double get _effectiveYaw => (_cam?.yaw ?? 0) + _boxYawRad;

  void _onSnapTick() {
    final t = Curves.easeOutCubic.transform(_snap.value);
    final cam = _cam;
    if (cam == null) return;
    widget.controller.moveTo((
      yaw: _fromYaw + (_toYaw - _fromYaw) * t,
      pitch: _fromPitch + (_toPitch - _fromPitch) * t,
      zoom: cam.zoom,
      panX: cam.panX,
      panY: cam.panY,
      pivotX: cam.pivotX,
      pivotY: cam.pivotY,
      pivotZ: cam.pivotZ,
    ));
  }

  /// 点击骰子某面 ⇒ 该面转到正对(建模软件同款一键归位)。
  /// yaw 走最短角差、pitch 直插 —— 相机 up 始终朝上,不产生滚转。
  void _snapToFace(String label) {
    final preset = kOrientationPresets.firstWhere((p) => p.label == label);
    var targetYaw = preset.yaw;
    if (label == 'Top' || label == 'Bottom') {
      // 极面朝向退化(世界 +Y 与视线平行):保留当前朝向的最近 90° 倍数,
      // 从侧视角进俯视时才不会莫名其妙横转一圈。
      const q = math.pi / 2;
      targetYaw = (_effectiveYaw / q).roundToDouble() * q;
    }
    // 目标是"观察方向",写回相机要扣掉滑杆分量。
    final cam = _cam;
    if (cam == null) return;
    _fromYaw = cam.yaw;
    _fromPitch = cam.pitch;
    _toPitch = preset.pitch;
    var delta = (targetYaw - _boxYawRad) - _fromYaw;
    delta = delta.remainder(2 * math.pi);
    if (delta > math.pi) delta -= 2 * math.pi;
    if (delta < -math.pi) delta += 2 * math.pi;
    _toYaw = _fromYaw + delta;
    if (delta.abs() < 1e-6 && (_toPitch - _fromPitch).abs() < 1e-6) return;
    unawaited(_snap.forward(from: 0));
  }

  Map<String, String> _faceLabels(BuildContext context) {
    final l = AppL10n.of(context);
    return {
      'Top': l.cubeFaceTop,
      'Front': l.cubeFaceFront,
      'Right': l.cubeFaceRight,
      'Back': l.cubeFaceBack,
      'Left': l.cubeFaceLeft,
      'Bottom': l.cubeFaceBottom,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = AppL10n.of(context);
    return Stack(
      children: [
        Positioned(
          top: 8,
          left: 4,
          child: SafeArea(
            child: TextButton.icon(
              key: const ValueKey('selection-back'),
              onPressed: widget.onExit,
              icon: const Icon(
                Icons.arrow_back_ios_new_rounded,
                color: Colors.white,
                size: 20,
              ),
              label: Text(
                l.selectionBackToPreview,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ),
        ),
        Positioned(
          top: 8,
          right: 12,
          child: SafeArea(
            child: _CubeGestures(
              onDragStart: _onCubeDragStart,
              onDrag: _onCubeDrag,
              onDragEnd: _onCubeDragEnd,
              child: ValueListenableBuilder<CloudViewCamera?>(
                valueListenable: widget.camera,
                builder: (_, cam, _) => ViewCube(
                  key: const ValueKey('view-cube'),
                  viewYaw: (cam?.yaw ?? 0) + _boxYawRad,
                  viewPitch: cam?.pitch ?? 0,
                  faceLabels: _faceLabels(context),
                  onFaceTap: _snapToFace,
                  size: 72,
                ),
              ),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            // [2026-07-28 实测] 点云视图是全屏 Positioned.fill(切换编辑态
            // 时尺寸不变才不会跳),所以工具层必须自己吃掉手势 —— 否则拨
            // 刻度尺时下层同时在 orbit(实测刻度尺只收到 1/5 位移)。
            child: _AbsorbCameraGestures(
              child: Container(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
                color: const Color(0xE60B0B0D),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton(
                        onPressed: () =>
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(l.selectionDensifyComingSoon),
                              ),
                            ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF0A84FF),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        child: Text(l.selectionReadyToProcess),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 骰子手势:单指拖 = 转视角(带惯性),同时不让手势落到下层点云视图。
/// 点击某面归位由 ViewCube 自己的 onTapDown 处理,与拖动共存。
class _CubeGestures extends StatefulWidget {
  const _CubeGestures({
    required this.onDragStart,
    required this.onDrag,
    required this.onDragEnd,
    required this.child,
  });

  final VoidCallback onDragStart;
  final ValueChanged<Offset> onDrag;
  final ValueChanged<Velocity> onDragEnd;
  final Widget child;

  @override
  State<_CubeGestures> createState() => _CubeGesturesState();
}

class _CubeGesturesState extends State<_CubeGestures> {
  Duration? _lastTimestamp;
  Offset _fallbackVelocity = Offset.zero;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    dragStartBehavior: DragStartBehavior.down,
    onPanStart: (d) {
      _lastTimestamp = d.sourceTimeStamp;
      _fallbackVelocity = Offset.zero;
      widget.onDragStart();
    },
    onPanUpdate: (d) {
      final timestamp = d.sourceTimeStamp;
      final previous = _lastTimestamp;
      if (timestamp != null && previous != null) {
        final elapsed = timestamp - previous;
        if (elapsed > Duration.zero && d.delta != Offset.zero) {
          _fallbackVelocity =
              d.delta *
              (Duration.microsecondsPerSecond / elapsed.inMicroseconds);
        }
      }
      _lastTimestamp = timestamp;
      widget.onDrag(d.delta);
    },
    onPanEnd: (d) {
      var velocity = d.velocity;
      if (velocity.pixelsPerSecond == Offset.zero &&
          _fallbackVelocity != Offset.zero) {
        velocity = Velocity(
          pixelsPerSecond: _fallbackVelocity,
        ).clampMagnitude(0, 8000);
      }
      widget.onDragEnd(velocity);
    },
    child: widget.child,
  );
}

/// 吃掉缩放/拖拽手势,阻止它们落到下层的点云视图(Stack 上层先命中,
/// 先入竞技场者胜)。
class _AbsorbCameraGestures extends StatelessWidget {
  const _AbsorbCameraGestures({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onScaleStart: (_) {},
    onScaleUpdate: (_) {},
    onScaleEnd: (_) {},
    child: child,
  );
}
