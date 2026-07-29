// selection_tools_layer.dart — 选区工具层(骰子 / 旋转刻度尺 / 开始处理)。
//
// [2026-07-28 用户签决] "浏览页面和编辑页面需要是同一个页面 —— 模型的角度
// 和位置自然相同,根本不用做两个画面":不再 push 独立的选区页,点"下一步"
// 只是把这一层**叠**到同一个 SparseCloudView 上。相机自始至终是那一个
// State,连一次重建都没有,所以位置/角度/缩放天然连续。
//
// 本层 = 朝向骰子(跟随相机 + 点击某面归位)+ 返回 + 开始处理。
// [2026-07-29 用户签决] 底部"旋转点云"滑轨回归,且升级语义:转轴 = 当前
// 正对面的法向("按那个面为底开始旋转"),不再固定绕竖直轴。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show DragStartBehavior, Velocity;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../l10n/app_localizations.dart';
import '../../official_capture/selection_box.dart';
import 'ruler_scrubber.dart';
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

  /// 旋转滑轨的读数(纯 UI 累计角,框的真实朝向在 box.rot 里)。
  double _rollDeg = 0;

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
    // 相机一动可能换正对面 ⇒ 换转轴、黄标归位。
    widget.camera.addListener(_onCameraChanged);
  }

  void _onCameraChanged() {
    final before = _rollFace;
    _syncRollAxis();
    if (before != _rollFace && mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.camera.removeListener(_onCameraChanged);
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

  /// 相机相对**框**的朝向 = camera.yaw − 框自身的 yaw。
  ///
  /// [2026-07-29 用户实机指认"立方体正面时框却是斜的"] 此前写成 **+**:
  /// 框绕 Y 转了 θ 时,要正对框的某个面相机也得转 +θ,相对朝向应当抵消
  /// (相减)。写成相加会让骰子与框差 2θ —— 骰子显示"后"正对,框却斜着。
  double get _boxYawRad => widget.box.yawDeg * math.pi / 180.0;
  CloudViewCamera? get _cam => widget.camera.value;
  double get _effectiveYaw => (_cam?.yaw ?? 0) - _boxYawRad;

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
    var delta = (targetYaw + _boxYawRad) - _fromYaw;
    delta = delta.remainder(2 * math.pi);
    if (delta > math.pi) delta -= 2 * math.pi;
    if (delta < -math.pi) delta += 2 * math.pi;
    _toYaw = _fromYaw + delta;
    if (delta.abs() < 1e-6 && (_toPitch - _fromPitch).abs() < 1e-6) return;
    unawaited(_snap.forward(from: 0));
  }

  /// 旋转滑轨的转轴(世界系),**一轮之内锁定**。
  ///
  /// [2026-07-29 用户实机指认"每次拨回初始刻度角度都不一样"] 原先每次
  /// onChanged 都拿**当前框**的面法向重算轴 —— 而框刚被上一次拨动转过,
  /// 轴就跟着转了。绕移动靶做增量旋转不可交换、也不可逆:拨 +30 再拨 −30
  /// 落在 R(a₂,−30)·R(a₁,+30) ≠ 单位阵,所以回到 0 刻度时框是歪的。
  /// 现在只在**正对面改变**时重算并锁定,同一参考面内轴恒定 ⇒
  /// R(a,d₁)·R(a,d₂)… = R(a,Σd),回到 0 精确复原。
  String _rollFace = '';
  List<double> _rollAxis = const [0, 1, 0];

  void _syncRollAxis() {
    final cam = _cam;
    if (cam == null) return;
    final label = primaryViewCubeFace(_effectiveYaw, cam.pitch);
    if (label == _rollFace) return;
    _rollFace = label;
    final f = kViewCubeFaces.firstWhere((e) => e.label == label);
    // 面法向是**框局部**方向(骰子六面 = 框的面),按当前朝向转成世界后锁定。
    final r = widget.box.rot;
    final n = f.normal;
    _rollAxis = [
      r[0] * n[0] + r[1] * n[1] + r[2] * n[2],
      r[3] * n[0] + r[4] * n[1] + r[5] * n[2],
      r[6] * n[0] + r[7] * n[1] + r[8] * n[2],
    ];
    // 换了参考面 ⇒ "0 刻度"的含义也换了:黄标归位到当前朝向。
    _rollDeg = 0;
  }

  void _onRoll(double v) {
    // ⚠️ 只在**首次**同步轴。不能每次拨动都同步:框一转,骰子的正对面就
    // 跟着变(骰子六面是模型的面),轴会被重算、黄标被悄悄归零 —— 用户
    // 拨"一整圈"时中途换了好几根轴,自然回不到原点(实机指认)。
    // 换轴只该由**相机变动**触发,见 _onCameraChanged。
    if (_rollFace.isEmpty) _syncRollAxis();
    // 增量取最短环向差(甩动惯性给的是无界连续值)。
    var delta = (v - _rollDeg) % 360.0;
    if (delta > 180.0) delta -= 360.0;
    if (delta == 0) return;
    final cam = _cam;
    if (cam == null) return;
    setState(() {
      _rollDeg = v - 360.0 * ((v + 180.0) / 360.0).floorToDouble();
    });
    // 绕相机枢轴刚性旋转 ⇒ 框在屏幕上不跑位,只有朝向变。
    widget.onBoxChanged(
      widget.box.rotatedAroundAxis(
        axis: _rollAxis,
        deltaDeg: delta,
        pivotX: cam.pivotX,
        pivotY: cam.pivotY,
        pivotZ: cam.pivotZ,
      ),
    );
  }

  /// [2026-07-29 用户签决] "⋯" 菜单项一:框朝向回到初始(轴对齐),滑轨
  /// 读数同步归零 —— 尺寸与位置不动,只把转过的角度还原。
  void _resetRotation() {
    setState(() {
      _rollDeg = 0;
      _rollFace = ''; // 强制下次拨动按新朝向重算轴
    });
    widget.onBoxChanged(widget.box.copyWith(rot: kIdentityRot));
  }

  /// 菜单项二:相机回到默认取景(点云回到刚进来时的大小)。框不动。
  void _resetZoom() {
    _fling.stop();
    _snap.stop();
    widget.controller.requestReframe();
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
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton.icon(
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
                const SizedBox(width: 4),
                _AbsorbCameraGestures(
                  child: PopupMenuButton<int>(
                    key: const ValueKey('selection-more'),
                    tooltip: '',
                    color: const Color(0xFF2A2A2E),
                    position: PopupMenuPosition.under,
                    icon: Container(
                      width: 34,
                      height: 34,
                      alignment: Alignment.center,
                      decoration: const BoxDecoration(
                        shape: BoxShape.circle,
                        color: Color(0x33FFFFFF),
                      ),
                      child: const Icon(
                        Icons.more_horiz_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                    onSelected: (i) => i == 0 ? _resetRotation() : _resetZoom(),
                    itemBuilder: (_) => [
                      PopupMenuItem<int>(
                        value: 0,
                        child: Text(
                          l.selectionResetRotation,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                      PopupMenuItem<int>(
                        value: 1,
                        child: Text(
                          l.selectionResetZoom,
                          style: const TextStyle(color: Colors.white),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
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
                  viewYaw: (cam?.yaw ?? 0) - _boxYawRad,
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
            // 底部面板**不**包手势拦截器:外层的 Scale 识别器会和刻度尺的
            // 水平拖动抢竞技场,把滑轨拖动整个吃掉(实测框纹丝不动)。
            // 下层点云视图改由 bottomGestureExclusion 按位置忽略该区域 ——
            // 确定性判定,不依赖竞技场。
            child: Container(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              color: const Color(0xE60B0B0D),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.selectionRotatePointCloud,
                    style: const TextStyle(color: Colors.white70, fontSize: 13),
                  ),
                  RulerScrubber(
                    value: _rollDeg,
                    onChanged: _onRoll,
                    originDeg: 0,
                  ),
                  const SizedBox(height: 8),
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
