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
  (label: 'Top', yaw: math.pi, pitch: -math.pi / 2), // 文字正立(探针实测)
  (label: 'Front', yaw: 0, pitch: 0),
  (label: 'Right', yaw: math.pi / 2, pitch: 0),
  (label: 'Back', yaw: math.pi, pitch: 0),
  (label: 'Left', yaw: -math.pi / 2, pitch: 0),
  (label: 'Bottom', yaw: math.pi, pitch: math.pi / 2), // 文字正立(探针实测)
];

class SelectionToolsLayer extends StatefulWidget {
  const SelectionToolsLayer({
    super.key,
    required this.box,
    required this.onBoxChanged,
    required this.camera,
    required this.controller,
    required this.onExit,
    this.onResetBoxSize,
  });

  final SelectionBox box;
  final ValueChanged<SelectionBox> onBoxChanged;

  /// 当前相机(骰子跟随它;归位时经 controller 写回)。用 Listenable 而非
  /// 值传递:相机每帧手势都在变,整页 setState 会白白重建点云层。
  final ValueListenable<CloudViewCamera?> camera;
  final CloudViewController controller;

  /// 返回浏览态(工具层收起)。
  final VoidCallback onExit;

  /// "恢复原始框大小":按当前点云重算初始框(位置/尺寸/朝向全复位)。
  /// 由父级实现 —— 它才持有点云数据。null 时不显示该菜单项。
  final VoidCallback? onResetBoxSize;

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
    // 拨滑轨自己造成的相机变化不算"用户转了视角",否则会当场把基准和读数
    // 重置掉(用户实机指认"点云自动重置到初始角度")。
    if (_rolling || !mounted) return;
    setState(_rebaseRoll);
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
      roll: 0, // 手动 orbit 不带滚转
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
  CloudViewCamera? get _cam => widget.camera.value;

  /// 骰子 = **框的朝向指示器**:读框相对相机的水平朝向差。
  ///
  /// [2026-07-29 用户签决"框和立方体必须同步的正"] 骰子正对某面 ⟺ 框的那
  /// 一面正对屏幕,所以它必须反映**框相对相机**的关系,而不是相机相对世界。
  /// 之所以以前这样做会歪,是因为存档里的框带着非竖直旋转分量;现在
  /// SelectionBox.fromJson 会把朝向投影到纯竖直旋转、滑轨也只绕竖直轴,
  /// 加上相机滚转恒 0 ⇒ 相对姿态的滚转恒 0,立方体永远正着放。
  double get _relYaw => (_cam?.yaw ?? 0) - widget.box.yawDeg * math.pi / 180.0;
  void _onSnapTick() {
    final t = Curves.easeOutCubic.transform(_snap.value);
    final cam = _cam;
    if (cam == null) return;
    widget.controller.moveTo((
      yaw: _fromYaw + (_toYaw - _fromYaw) * t,
      pitch: _fromPitch + (_toPitch - _fromPitch) * t,
      roll: 0,
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
  /// 点击骰子某面 ⇒ 相机转到正对该世界方向(建模软件同款一键归位)。
  /// yaw 走最短角差、pitch 直插、roll 归零 —— 画面永远水平。
  void _snapToFace(String label) {
    final preset = kOrientationPresets.firstWhere((p) => p.label == label);
    final cam = _cam;
    if (cam == null) return;
    final boxYaw = widget.box.yawDeg * math.pi / 180.0;
    // 目标先在**相对朝向**(骰子看到的那个)上定,再加回框自身朝向换成相机
    // 朝向 —— 吸附必须作用在相对朝向上,否则减去 boxYaw 之后就不是 90° 的
    // 倍数了,立方体照样停在斜角度(用户实机指认,测试已复现)。
    // 极面(Top/Bottom)退化:视线与重力平行,yaw 是屏幕内旋转。直接落到
    // preset.yaw = 该面**文字正立**的 yaw(探针实测两极面均为 π),而不是
    // "吸附到最近 90° 倍数" —— 后者有 4 个不歪姿态、只有 1 个文字正,会让
    // 点"顶/底"后文字横着(用户签决"顶必须文字正")。
    final targetYaw = preset.yaw + boxYaw;
    _fromYaw = cam.yaw;
    _fromPitch = cam.pitch;
    _toPitch = preset.pitch;
    var delta = targetYaw - _fromYaw;
    delta = delta.remainder(2 * math.pi);
    if (delta > math.pi) delta -= 2 * math.pi;
    if (delta < -math.pi) delta += 2 * math.pi;
    _toYaw = _fromYaw + delta;
    if (delta.abs() < 1e-6 && (_toPitch - _fromPitch).abs() < 1e-6) return;
    unawaited(_snap.forward(from: 0));
  }

  /// 旋转滑轨的转轴 = **世界竖直轴(重力)**,固定不变。
  ///
  /// [2026-07-29 用户签决三条] "立方体必须永远正着放"、"点击面后立方体要
  /// 水平、不能有倾斜"。此前按"正对面法向"转,正对侧面时那根轴≈视线方向,
  /// 绕它转相机就是**屏幕内滚转** —— 画面整个歪掉、骰子文字横过来。
  /// 只有绕重力轴转才既让点云水平转动、又保证相机永不滚转(roll ≡ 0)。
  static const List<double> _kRollAxis = [0, 1, 0];

  /// 滑轨的**绝对**基准:相机 = 基准 yaw + 读数;框 = R(轴, −读数) · 基准。
  ///
  /// [2026-07-29 用户实机指认"转一圈回不到原点"] 增量累加太脆:任何一次
  /// 基准错位都会永久留下残差。绝对定位下"读数 = 0 ⇒ 回到基准"是恒等式。
  List<double> _rollBaseRot = kIdentityRot;
  List<double> _rollBaseCenter = const [0, 0, 0];
  double _rollBaseYaw = 0;
  double _rollBasePitch = 0;

  /// 我自己 emit 出去的框。父级回传的若不是它,说明框被别的入口改了
  /// (拖手柄),此时必须重新烘焙基准,否则拨滑轨会把那次改动拽回去。
  SelectionBox? _rollEmitted;

  /// "⋯" 菜单是否展开。自绘浮层、**不带遮罩** —— 展开时底下照常可以转立方体、
  /// 拨刻度、转点云(用户签决)。PopupMenuButton 自带全屏 ModalBarrier,会把
  /// 这些手势全吞掉,故不能用它。
  bool _menuOpen = false;

  /// 拨滑轨期间置位。
  ///
  /// [2026-07-29 用户实机指认"开始调节时点云自动重置到初始角度"] 根因是
  /// 顺序:_onRoll 先 moveTo 相机(同步通知 → _onCameraChanged),此刻框还
  /// 没更新,相对姿态自然偏离基准,于是被当成"用户转了视角"重新烘焙基准、
  /// 读数归零 —— 点云当场跳回原点。拨动期间必须屏蔽这条回路。
  bool _rolling = false;

  void _rebaseRoll() {
    _rollBaseRot = widget.box.rot;
    _rollBaseCenter = [widget.box.cx, widget.box.cy, widget.box.cz];
    final cam = _cam;
    if (cam != null) {
      _rollBaseYaw = cam.yaw;
      _rollBasePitch = cam.pitch;
    }
    _rollDeg = 0;
  }

  @override
  void didUpdateWidget(SelectionToolsLayer old) {
    super.didUpdateWidget(old);
    if (!_rolling && !identical(widget.box, _rollEmitted)) _rebaseRoll();
  }

  /// 拨滑轨 = **点云转、框不动**(复刻 RS)。
  ///
  /// [2026-07-29 用户签决] "RS 的做法是框不动,转的是点云;刻度转一圈是点云
  /// 转 360°"。点云世界坐标不能改(PLY 是交付物),所以:
  ///   · 相机绕重力轴 +θ(只改 yaw,roll 恒 0 ⇒ 画面永远水平);
  ///   · 框在世界里绕同轴 −θ(中心亦绕枢轴 −θ)⇒ 两者抵消,框在屏幕上纹丝
  ///     不动,但相对点云确实转了,选中的点集随之改变。
  /// 读数归一化到 (-180,180],拨满一圈回到 0 ⇒ 相机与框同时精确复原。
  void _onRoll(double v) {
    final cam = _cam;
    if (cam == null) return;
    if (_rollEmitted == null) _rebaseRoll(); // 首次:烘焙基准
    final deg = v - 360.0 * ((v + 180.0) / 360.0).floorToDouble();
    final inv = rotAboutAxisDeg(_kRollAxis, -deg);
    final dx = _rollBaseCenter[0] - cam.pivotX;
    final dy = _rollBaseCenter[1] - cam.pivotY;
    final dz = _rollBaseCenter[2] - cam.pivotZ;
    final next = widget.box.copyWith(
      cx: cam.pivotX + inv[0] * dx + inv[1] * dy + inv[2] * dz,
      cy: cam.pivotY + inv[3] * dx + inv[4] * dy + inv[5] * dz,
      cz: cam.pivotZ + inv[6] * dx + inv[7] * dy + inv[8] * dz,
      rot: mulRot(inv, _rollBaseRot),
    );
    _rolling = true;
    setState(() => _rollDeg = deg);
    _rollEmitted = next;
    widget.onBoxChanged(next);
    widget.controller.moveTo((
      yaw: _rollBaseYaw + deg * math.pi / 180.0,
      pitch: _rollBasePitch,
      roll: 0,
      zoom: cam.zoom,
      panX: cam.panX,
      panY: cam.panY,
      pivotX: cam.pivotX,
      pivotY: cam.pivotY,
      pivotZ: cam.pivotZ,
    ));
    _rolling = false;
  }

  /// [2026-07-29 用户签决] "⋯" 菜单项一:框朝向回到初始(轴对齐),滑轨
  /// 读数与基准同步归零 —— 尺寸与位置不动,只把转过的角度还原。
  void _resetRotation() {
    final next = widget.box.copyWith(rot: kIdentityRot);
    setState(() {
      _rollDeg = 0;
      _rollBaseRot = kIdentityRot;
      _rollBaseCenter = [next.cx, next.cy, next.cz];
    });
    _rollEmitted = next;
    widget.onBoxChanged(next);
  }

  /// 菜单项二:相机回到默认取景(点云回到刚进来时的大小)。框不动。
  void _resetZoom() {
    _fling.stop();
    _snap.stop();
    widget.controller.requestReframe();
  }

  Widget _menuItem(String label, VoidCallback onTap) => InkWell(
    onTap: () {
      setState(() => _menuOpen = false);
      onTap();
    },
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 13),
      child: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 15),
      ),
    ),
  );

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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              // [2026-07-29 用户签决] "⋯" 放在"返回预览页面"**下方、左对齐**。
              crossAxisAlignment: CrossAxisAlignment.start,
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
                Padding(
                  // 与返回箭头的左边缘对齐(TextButton 内边距 8)。
                  padding: const EdgeInsets.only(left: 8, top: 2),
                  child: GestureDetector(
                    key: const ValueKey('selection-more'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(() => _menuOpen = !_menuOpen),
                    child: Container(
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
                  ),
                ),
                if (_menuOpen)
                  Padding(
                    padding: const EdgeInsets.only(left: 8, top: 6),
                    child: Material(
                      color: const Color(0xF22A2A2E),
                      borderRadius: BorderRadius.circular(12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        // ⚠️ 不能用 stretch:菜单在 Stack 的 Positioned 里,
                        // 宽度无界,stretch 会让子项拿不到约束而崩(RenderBox
                        // was not laid out)。宽度由文本自然决定。
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _menuItem(l.selectionResetRotation, _resetRotation),
                          _menuItem(l.selectionResetZoom, _resetZoom),
                          if (widget.onResetBoxSize != null)
                            _menuItem(
                              l.selectionResetBoxSize,
                              widget.onResetBoxSize!,
                            ),
                        ],
                      ),
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
                  viewYaw: _relYaw,
                  viewPitch: cam?.pitch ?? 0,
                  viewRoll: cam?.roll ?? 0,
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
