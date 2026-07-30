// selection_tools_layer.dart — 选区工具层(骰子 / 旋转刻度尺 / 开始处理)。
//
// [2026-07-28 用户签决] "浏览页面和编辑页面需要是同一个页面 —— 模型的角度
// 和位置自然相同,根本不用做两个画面":不再 push 独立的选区页,点"下一步"
// 只是把这一层**叠**到同一个 SparseCloudView 上。相机自始至终是那一个
// State,连一次重建都没有,所以位置/角度/缩放天然连续。
//
// 本层 = 朝向骰子(跟随相机 + 点击某面归位)+ 返回 + 开始处理。
// [2026-07-30 用户签决] 底部"旋转点云"滑轨语义 = **钟表指针**:转轴恒为
// 视线轴,点云在屏幕平面内原地打转(转轴四代变迁见 _rebaseRoll 上的注释)。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/gestures.dart' show DragStartBehavior, Velocity;
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../l10n/app_localizations.dart';
import '../../official_capture/selection_box.dart';
import 'cloud_camera.dart'
    show composeViewMatrix, decomposeViewMatrix, mulMatrix;
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
  double _fromYaw = 0, _fromPitch = 0, _fromRoll = 0;
  double _toYaw = 0, _toPitch = 0, _toRoll = 0;

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
    // 相机此刻可能已有值(浏览态一直在跑),不会再触发上面的监听 ⇒ 首帧后
    // 主动对齐一次。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _alignToTopOnce();
    });
  }

  void _onCameraChanged() {
    // 拨滑轨自己造成的相机变化不算"用户转了视角",否则会当场把基准和读数
    // 重置掉(用户实机指认"点云自动重置到初始角度")。
    if (_rolling || !mounted) return;
    _alignToTopOnce();
    setState(_rebaseRoll);
  }

  bool _alignedOnce = false;

  /// 进编辑时落到**重力正上方**的"顶",框朝向一并复位 —— 每次编辑做一次。
  ///
  /// [2026-07-30 用户签决] "初始视角永远是点云正上方的顶"、"你没有加重力的
  /// 参数吗"。点云世界 +Y 就是重力上(_gravityAlign,ARKit worldAlignment=
  /// .gravity),所以"正上方"= 相机 pitch 严格 −90°,与框的朝向无关。
  ///
  /// 三条路只有一条走得通,两条都被实机否决过:
  ///   ① 反解 M_cam = preset_Top · box.rotᵀ(让**框的**顶面正对)—— 框带 61°
  ///      俯仰时相机 pitch 实测只有 −29.1°,就是"顶不是点云正上方";
  ///   ② 硬写 pitch=−90° 而框保留朝向 —— 歪框的骰子重新变菱形("立方体没有
  ///      水平放置");
  ///   ③ 骰子改读相机相对世界 —— 点某面时框会斜,违反"框和立方体必须同步
  ///      的正"。
  /// ①② 数学上不可兼得(框歪着时"相机在重力正上方"与"骰子正着放"互斥),
  /// 唯一两全 = **框朝向也复位到重力对齐**。只复位朝向,中心/尺寸不动 ——
  /// 用户调过的选区大小必须留着。滑轨转出的朝向在编辑期间照常有效,只是不
  /// 跨会话保留("⋯"里本来就有"回到初始旋转角度")。
  void _alignToTopOnce() {
    if (_alignedOnce) return;
    if (_cam == null) return;
    _alignedOnce = true;
    var dev = 0.0;
    for (var i = 0; i < 9; i++) {
      dev += (widget.box.rot[i] - kIdentityRot[i]).abs();
    }
    if (dev > 1e-9) {
      widget.onBoxChanged(widget.box.copyWith(rot: kIdentityRot));
    }
    // 目标直接用 preset 而不是 _snapToFace('Top') —— onBoxChanged 要等父级
    // setState,当帧 widget.box.rot 还是旧的歪值,反解出来照样偏。
    final top = kOrientationPresets.first;
    _snapTo(top.yaw, top.pitch, 0);
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
      // 滚转原样保留 —— 钟表旋转(滑轨)把角度就存在相机 roll 里,框绕视线
      // 反转同角度抵消。这里硬写 0 会把滑轨的成果清掉而框的朝向留着,框与
      // 骰子当场歪掉(旧约束"手动 orbit 不带滚转"随钟表签决作废)。
      roll: cam.roll,
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

  CloudViewCamera? get _cam => widget.camera.value;

  /// 骰子 = **框的朝向指示器**:读框相对相机的水平朝向差。
  ///
  /// [2026-07-29 用户签决"框和立方体必须同步的正"] 骰子正对某面 ⟺ 框的那
  /// 一面正对屏幕,所以它必须反映**框相对相机**的关系,而不是相机相对世界。
  /// 完整姿态 = M_camera · box.rot(框局部 → 相机系)。
  /// "立方体永远正着放"现在是构造性的:钟表滑轨让相机与框同步转 ⇒ 这个乘积
  /// 恒定 ⇒ 拨动全程骰子一动不动;进编辑时又固定对齐到 Top(_alignToTopOnce)
  /// 把重开草稿的失配一次抹平。
  List<double> get _relPose {
    final cam = _cam;
    if (cam == null) return kIdentityRot;
    return mulMatrix(
      composeViewMatrix(cam.yaw, cam.pitch, cam.roll),
      widget.box.rot,
    );
  }

  void _onSnapTick() {
    final t = Curves.easeOutCubic.transform(_snap.value);
    final cam = _cam;
    if (cam == null) return;
    widget.controller.moveTo((
      yaw: _fromYaw + (_toYaw - _fromYaw) * t,
      pitch: _fromPitch + (_toPitch - _fromPitch) * t,
      roll: _fromRoll + (_toRoll - _fromRoll) * t,
      zoom: cam.zoom,
      panX: cam.panX,
      panY: cam.panY,
      pivotX: cam.pivotX,
      pivotY: cam.pivotY,
      pivotZ: cam.pivotZ,
    ));
  }

  /// 点击骰子某面 ⇒ 该面转到正对相机(建模软件同款一键归位)。
  ///
  /// 框可任意 3D 朝向(翻滚后带俯仰/滚转),所以走完整矩阵:目标相对姿态 =
  /// 该面正对(preset),反解相机姿态 M_cam = preset · box.rotᵀ,再分解成
  /// yaw/pitch/roll 三元由 _snap 插值动画。
  void _snapToFace(String label) {
    final preset = kOrientationPresets.firstWhere((p) => p.label == label);
    final cam = _cam;
    if (cam == null) return;
    final target = composeViewMatrix(preset.yaw, preset.pitch, 0);
    final r = widget.box.rot;
    final rotT = <double>[r[0], r[3], r[6], r[1], r[4], r[7], r[2], r[5], r[8]];
    final (ty, tp, tr) = decomposeViewMatrix(mulMatrix(target, rotT));
    _snapTo(ty, tp, tr);
  }

  /// 相机动画到给定姿态(yaw 走环向最短路;已在目标上则不启动动画)。
  void _snapTo(double yaw, double pitch, double roll) {
    final cam = _cam;
    if (cam == null) return;
    _fromYaw = cam.yaw;
    _fromPitch = cam.pitch;
    _fromRoll = cam.roll;
    _toPitch = pitch;
    _toRoll = roll;
    var delta = yaw - _fromYaw;
    delta = delta.remainder(2 * math.pi);
    if (delta > math.pi) delta -= 2 * math.pi;
    if (delta < -math.pi) delta += 2 * math.pi;
    _toYaw = _fromYaw + delta;
    if (delta.abs() < 1e-6 &&
        (_toPitch - _fromPitch).abs() < 1e-6 &&
        (_toRoll - _fromRoll).abs() < 1e-6) {
      return;
    }
    unawaited(_snap.forward(from: 0));
  }

  /// 旋转滑轨的转轴 = **视线轴**(相机系 z),任何视角下都固定为它。
  ///
  /// [2026-07-30 用户签决] "就跟钟表一样,指针一样" —— 点云在屏幕平面内原地
  /// 打转。三代都被实机否决过:①绕"正对面法向"(轴是移动靶,拨到中途换轴);
  /// ②绕世界竖直轴(只在顶/底视角碰巧是钟表,侧视角退化成水平自转 —— 用户
  /// 原话"现在只有顶部和底部是垂直方向");③绕横轴翻滚(顶视翻成侧视 ——
  /// "还是水平的翻转")。绕视线轴同时满足另两条老签决:相机与框同步转 ⇒
  /// 相对姿态恒定 ⇒ 骰子一动不动、永远正着放,框在屏幕上纹丝不动。

  /// 滑轨的**绝对**基准:相机 = 基准 yaw + 读数;框 = R(轴, −读数) · 基准。
  ///
  /// [2026-07-29 用户实机指认"转一圈回不到原点"] 增量累加太脆:任何一次
  /// 基准错位都会永久留下残差。绝对定位下"读数 = 0 ⇒ 回到基准"是恒等式。
  List<double> _rollBaseRot = kIdentityRot;
  List<double> _rollBaseCenter = const [0, 0, 0];

  /// 基准相机视图矩阵(拨滑轨那一刻锁定)。翻滚绕它的 right 轴(第 0 行)。
  List<double> _rollBaseView = kIdentityRot;

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
      _rollBaseView = composeViewMatrix(cam.yaw, cam.pitch, cam.roll);
    }
    _rollDeg = 0;
  }

  @override
  void didUpdateWidget(SelectionToolsLayer old) {
    super.didUpdateWidget(old);
    if (!_rolling && !identical(widget.box, _rollEmitted)) _rebaseRoll();
  }

  /// 拨滑轨 = **点云绕横轴俯仰翻滚、框在屏幕上不动**(RS 语义 + 用户签决
  /// "垂直方向旋转")。
  ///
  /// 点云世界坐标不能改(PLY 是交付物),所以相机与框反向同步:
  ///   · 相机绕**基准相机的 right 轴**(屏幕水平轴,世界系)转 +θ ⇒ 视觉上
  ///     点云俯仰翻滚 θ;绕 right 轴纯俯仰,过顶时自然出现滚转(点云倒置),
  ///     这是翻滚一圈的必然,与真实翻物体一致。
  ///   · 框绕同一世界轴 −θ(中心亦绕枢轴 −θ)⇒ M·q ≡ M_base·q_base,框在
  ///     屏幕上纹丝不动,但相对点云确实翻了,选中的点集随之改变。
  /// 读数归一化到 (-180,180],拨满一圈回到 0 ⇒ 相机与框同时精确复原。
  void _onRoll(double v) {
    final cam = _cam;
    if (cam == null) return;
    if (_rollEmitted == null) _rebaseRoll();
    final deg = v - 360.0 * ((v + 180.0) / 360.0).floorToDouble();
    // 相机:绕自身**视线轴**(相机系 z)转 deg = 视图矩阵左乘 Rz(deg) =
    // 屏幕平面内的旋转 ⇒ 点云像钟表指针一样在屏幕上原地打转。
    final camView = mulMatrix(
      rotAboutAxisDeg(const [0, 0, 1], deg),
      _rollBaseView,
    );
    final (ny, np, nr) = decomposeViewMatrix(camView);
    // 框:绕**世界**视线轴(= 基准视图第 3 行)转 −deg。
    //
    // 该轴在 Rz 作用下不动(它就是转轴),所以 camView 第 3 行 ≡ 基准第 3 行
    // —— 轴恒定,不随读数漂移。不变性:baseView·R(axis,−θ) = Rz(−θ)·baseView
    // (因 baseView·axis = e3),于是 camView·boxRot ≡ baseView·baseRot,框在
    // 屏幕上纹丝不动、相对姿态不变 ⇒ 骰子也一动不动、永远正着放。
    final worldViewDir = [_rollBaseView[6], _rollBaseView[7], _rollBaseView[8]];
    final inv = rotAboutAxisDeg(worldViewDir, -deg);
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
      yaw: ny,
      pitch: np,
      roll: nr,
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
                builder: (_, cam, _) {
                  final (cy, cp, cr) = decomposeViewMatrix(_relPose);
                  return ViewCube(
                    key: const ValueKey('view-cube'),
                    viewYaw: cy,
                    viewPitch: cp,
                    viewRoll: cr,
                    faceLabels: _faceLabels(context),
                    onFaceTap: _snapToFace,
                    size: 72,
                  );
                },
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
