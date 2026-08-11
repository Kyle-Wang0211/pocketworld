// selection_tools_layer.dart — 选区工具层(骰子 / 旋转刻度尺 / 开始处理)。
//
// [2026-07-28 用户签决] "浏览页面和编辑页面需要是同一个页面 —— 模型的角度
// 和位置自然相同,根本不用做两个画面":不再 push 独立的选区页,点"下一步"
// 只是把这一层**叠**到同一个 SparseCloudView 上。相机自始至终是那一个
// State,连一次重建都没有,所以位置/角度/缩放天然连续。
//
// 本层 = 朝向骰子(跟随相机 + 点击某面归位)+ 旋转滑轨 + 左"取消"/右"完成"。
// [2026-07-30 用户签决] 底部"旋转点云"滑轨语义 = **钟表指针**:转轴恒为
// 视线轴,点云在屏幕平面内原地打转(转轴四代变迁见 _rebaseRoll 上的注释)。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../official_capture/selection_box.dart';
import 'cloud_camera.dart'
    show
        axisAngleOf,
        composeViewMatrix,
        decomposeViewMatrix,
        mulMatrix,
        mulTransposed,
        rotationFromAxisAngle;
import 'ruler_scrubber.dart';
import 'sparse_cloud_view.dart' show CloudViewCamera, CloudViewController;
import 'view_cube.dart';

/// 左上"取消"按钮 —— 页面据此把"放弃更改"浮层锚定到它**下方**(苹果相册版式,
/// 2026-08-03 用户签决 + 截图)。用 GlobalKey 而不是让工具层自己弹:回滚逻辑
/// 在页面手里,浮层的去留必须由它裁决。
final GlobalKey kSelectionCancelKey = GlobalKey(debugLabel: 'selection-cancel');

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
    required this.onCancel,
    this.onRulerCollapsedChanged,
    this.onResetBoxSize,
  });

  final SelectionBox box;
  final ValueChanged<SelectionBox> onBoxChanged;

  /// 当前相机(骰子跟随它;归位时经 controller 写回)。用 Listenable 而非
  /// 值传递:相机每帧手势都在变,整页 setState 会白白重建点云层。
  final ValueListenable<CloudViewCamera?> camera;
  final CloudViewController controller;

  /// 右上"完成":提交本次编辑,**不问**。
  ///
  /// [2026-07-30 用户签决"直接学苹果的相册"] 左"取消" / 右"完成",确认的负担
  /// 全压在破坏性的那一侧:完成直接生效,取消才问(而且只在真改过时问)。
  final VoidCallback onExit;

  /// 左上"取消":放弃本次编辑。
  ///
  /// 没改过就直接回浏览态;改过则由父级弹"确定要放弃更改吗?"。父级必须实现成
  /// **真回滚** —— 编辑期改动是去抖自动落盘的,磁盘上早就是新值,"放弃"不能靠
  /// "跳过写盘"。
  final VoidCallback onCancel;

  /// 底部滑轨面板折叠状态变化 —— 页面据此收缩点云的手势排除区,否则收起后
  /// 点云下方仍有一大片点不动的死区。
  final ValueChanged<bool>? onRulerCollapsedChanged;

  /// "恢复原始框大小":按当前点云重算初始框(位置/尺寸/朝向全复位)。
  /// 由父级实现 —— 它才持有点云数据。null 时不显示该菜单项。
  final VoidCallback? onResetBoxSize;

  @override
  State<SelectionToolsLayer> createState() => _SelectionToolsLayerState();
}

class _SelectionToolsLayerState extends State<SelectionToolsLayer>
    with TickerProviderStateMixin {
  late final AnimationController _snap;

  /// 旋转滑轨的读数(纯 UI 累计角,框的真实朝向在 box.rot 里)。
  double _rollDeg = 0;

  @override
  void initState() {
    super.initState();
    _snap = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 240),
    )..addListener(_onSnapTick);
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
    final target = composeViewMatrix(top.yaw, top.pitch, 0);
    _logicalRel = target;
    _snapToPose(target);
  }

  @override
  void dispose() {
    widget.camera.removeListener(_onCameraChanged);
    _snap.dispose();
    super.dispose();
  }

  /// 右侧六视图列的起点 —— 让开上方 48pt 的"完成"按钮,再留 4pt 间隙。
  /// 左侧的 "⋯" 同样被上方的"取消"顶下来,两边高度因此对齐。
  /// 两个 Positioned 都包在 SafeArea 里,所以这是同一个基准。
  static const double _kRightColumnTop = 8 + 48 + 4;

  /// 骰子箭头 = 绕**屏幕轴** premultiply ±90°。
  ///
  /// [2026-07-30 用户签决] "完全复刻 RS,点云只能固定六个面动,立方体上下
  /// 左右的四个箭头也加回来" —— 机制照 b3588f6^ 的骰子实现回滚:下 = 绕屏幕
  /// 水平轴向下滚,右 = 绕屏幕竖直轴向右滚,每按一次严格 90°。
  ///
  /// [2026-07-31 用户签决,推翻 6e83756] "前后左右的文字和点云都要永远正面
  /// 朝上(重力参数),因为用户可以用旋转刻度来转"。此前的终审是"接受背面
  /// 倒置" —— 现在反过来:滚出的姿态一律吸附回该面的 preset(_uprightSnap),
  /// 于是任何序列都不会出现倒置或歪斜的面。倾斜只能来自用户拨滑轨,不能
  /// 来自换面。
  static const List<double> _kRollDown = [1, 0, 0, 0, 0, -1, 0, 1, 0];
  static const List<double> _kRollUp = [1, 0, 0, 0, 0, 1, 0, -1, 0];
  static const List<double> _kRollRight = [0, 0, 1, 0, 1, 0, -1, 0, 0];
  static const List<double> _kRollLeft = [0, 0, -1, 0, 1, 0, 1, 0, 0];

  /// 目标姿态 = viewRot · 当前目标姿态(动画中途连点也精确累积 90°,不会因为
  /// 拿"显示中的中途姿态"当基准而漂)。
  /// 骰子换面的**逻辑**姿态(框局部 → 相机):照常自然滚,允许倒置。
  ///
  /// 相机实际落到它回正之后的姿态,但下一次按箭头是从**逻辑**姿态继续滚的。
  /// 分开这两者是必需的:若拿回正后的姿态当基准,过极点那一下的 180° 修正会
  /// 把"上/下"调个个儿 —— 按上再按下回不到原处(实测,测试已锁)。
  ///
  /// 存**相对**姿态而不是世界姿态,是因为拨滑轨时相机与框同步转 ⇒ 相对姿态
  /// 恒定,逻辑姿态天然不会被滑轨弄脏。
  List<double>? _logicalRel;

  void _rollCube(List<double> viewRot) {
    if (_cam == null) return;
    _closeMenu();
    // [2026-07-31 用户实机指认] "我在左的角度,当我想要向左转,就到了底部"。
    // 根因:逻辑姿态原样保留滚转分量,下一次箭头绕的"屏幕竖直轴"在带滚转的
    // 姿态里已经不竖直,"左"就退化成俯仰。**纯按箭头也会累积滚转**,不只是
    // 拨滑轨:从"顶"按一次"左",视线到了"右"但整个姿态比 Right preset 多转
    // 90°,再按"左"就掉到"底"(探针实测,与实机吻合)。
    // 修法:逻辑姿态每步一并摆正(_upright),于是"摆正 ⇒ 屏幕竖直 ≡ 框局部
    // +Y(重力上)",左右恒为水平换面、四次一圈精确回原处。
    //
    // ⚠️ 代价(已向用户明示):上下往返不再可逆 —— 顶按"上"到前、前按"下"到
    // 底,回不到顶。"沿经线 4 循环"能可逆,但与"永远正面朝上"几何互斥:绕一
    // 条经线转整圈,侧面必然经过倒置(底按下到后时 up = 框局部 −Y)。既然
    // 07-31 签决是"前后左右的文字和点云都要永远正面朝上",取正立、舍可逆。
    final next = _upright(mulMatrix(viewRot, _logicalRel ?? _relPose));
    _logicalRel = next;
    _snapToPose(_poseForRel(next));
  }

  /// 把姿态摆正:视线吸附到最近的主轴,屏幕上方对齐"正立"方向。
  ///
  /// 侧面的正立 = 上方朝框局部 +Y(重力上);极面(视线沿 ±Y)时上方无法对齐
  /// 重力,取 preset 的水平上方 —— 探针实测那才是"顶/底"标签正立的朝向。
  List<double> _upright(List<double> rel) {
    final f = _snapAxis([rel[6], rel[7], rel[8]]);
    final up = f[1].abs() > 0.5
        ? <double>[0, 0, f[1] < 0 ? -1 : 1]
        : const <double>[0, 1, 0];
    // right = up × forward(与视图矩阵的右手约定一致,六个 preset 全对得上)。
    return <double>[
      up[1] * f[2] - up[2] * f[1],
      up[2] * f[0] - up[0] * f[2],
      up[0] * f[1] - up[1] * f[0],
      up[0], up[1], up[2], //
      f[0], f[1], f[2],
    ];
  }

  /// 吸附到 ±x/±y/±z 中分量绝对值最大的那根。
  List<double> _snapAxis(List<double> v) {
    var k = 0;
    for (var i = 1; i < 3; i++) {
      if (v[i].abs() > v[k].abs()) k = i;
    }
    final s = v[k] >= 0 ? 1.0 : -1.0;
    return <double>[k == 0 ? s : 0.0, k == 1 ? s : 0.0, k == 2 ? s : 0.0];
  }

  /// 逻辑相对姿态 → 相机世界姿态:先按**视线轴**吸附到最近的 preset(把滚转
  /// 分量整个丢掉 —— 那正是倒置的来源),再回代 preset · box.rotᵀ。
  ///
  /// 与 _snapToFace 同一族公式,所以用户拨滑轨转出的倾斜照常保留(它记在
  /// box.rot 里,相机跟着一起转)。
  List<double> _poseForRel(List<double> rel) {
    final vz = [rel[6], rel[7], rel[8]];
    var best = kOrientationPresets.first;
    var bestDot = -2.0;
    for (final p in kOrientationPresets) {
      final m = composeViewMatrix(p.yaw, p.pitch, 0);
      final d = m[6] * vz[0] + m[7] * vz[1] + m[8] * vz[2];
      if (d > bestDot) {
        bestDot = d;
        best = p;
      }
    }
    final r = widget.box.rot;
    final rotT = <double>[r[0], r[3], r[6], r[1], r[4], r[7], r[2], r[5], r[8]];
    return mulMatrix(composeViewMatrix(best.yaw, best.pitch, 0), rotT);
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

  /// 姿态过渡走 **SO(3) 轴角 slerp**,不是三个欧拉角各自线性插值 —— 过极点
  /// 时欧拉分量会突变(yaw/roll 在 pitch=±90° 处简并),线性插值会让画面绕
  /// 一大圈。slerp 走的是两姿态之间的最短大圆弧。
  List<double> _slerpFrom = kIdentityRot;
  List<double> _slerpAxis = const [1, 0, 0];
  double _slerpAngle = 0;
  List<double>? _slerpTarget;

  void _snapToPose(List<double> target) {
    final cam = _cam;
    if (cam == null) return;
    _slerpFrom = composeViewMatrix(cam.yaw, cam.pitch, cam.roll);
    final (axis, angle) = axisAngleOf(mulTransposed(target, _slerpFrom));
    if (angle.abs() < 1e-6) return;
    _slerpAxis = axis;
    _slerpAngle = angle;
    _slerpTarget = target;
    // [2026-08-09 用户实机指认"框不要突然变大再缩小"] 动画期间矩形按目标姿态
    // 画,直达终态;点云照常转。结束/被打断时清除(_onSnapTick / stop 处)。
    final (ty, tp, tr) = decomposeViewMatrix(target);
    widget.controller.setRectPoseOverride((ty, tp, tr));
    unawaited(_snap.forward(from: 0));
  }

  void _onSnapTick() {
    final t = Curves.easeOutCubic.transform(_snap.value);
    final cam = _cam;
    if (cam == null) return;
    final r = t >= 1.0
        ? (_slerpTarget ?? _slerpFrom)
        : mulMatrix(
            rotationFromAxisAngle(_slerpAxis, _slerpAngle * t),
            _slerpFrom,
          );
    if (t >= 1.0) widget.controller.setRectPoseOverride(null);
    final (y, p, roll) = decomposeViewMatrix(r);
    widget.controller.moveTo((
      yaw: y,
      pitch: p,
      roll: roll,
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
    _closeMenu();
    final preset = kOrientationPresets.firstWhere((p) => p.label == label);
    final cam = _cam;
    if (cam == null) return;
    final target = composeViewMatrix(preset.yaw, preset.pitch, 0);
    _logicalRel = target; // 显式指定了面 ⇒ 逻辑姿态一并归位
    final r = widget.box.rot;
    final rotT = <double>[r[0], r[3], r[6], r[1], r[4], r[7], r[2], r[5], r[8]];
    _snapToPose(mulMatrix(target, rotT));
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

  /// 底部"旋转"滑轨是否收起。
  ///
  /// [2026-08-06 用户签决,复刻 RealityScan] "下方控制模型旋转的滑轴可以收起再
  /// 打开;收起后中间有一个半圆凸起,点击可以拉起滑轴"。
  bool _rulerCollapsed = false;

  /// 关掉 "⋯" 浮层(已关就不 setState —— _onRoll 每帧都会调它)。
  void _closeMenu() {
    if (_menuOpen && mounted) setState(() => _menuOpen = false);
  }

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
    _closeMenu();
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
  ///
  /// [2026-07-30 用户实机指认"框变大而且红色点云在框内"] 原实现只复位了**框**,
  /// 没有把**视角**一起送回"顶"。拨滑轨的机制是点云转、框反向补偿以保持屏幕
  /// 对齐 —— 单独把 rot 打回单位阵,框就相对当前(转过的)视角歪着了:2D 手柄
  /// 矩形退化成歪框的屏幕包围盒(看着"变大"),而落在这个矩形里、却在 3D 框
  /// 之外的点照常判为框外染红(看着"红点在框内")。两者都不是渲染 bug,是
  /// 框与视角失配。进编辑态的 _alignToTopOnce 本来就是"框复位 + 视角回顶"
  /// 一起做的,这里必须同款。
  void _resetRotation() {
    final next = widget.box.copyWith(rot: kIdentityRot);
    setState(() {
      _rollDeg = 0;
      _rollBaseRot = kIdentityRot;
      _rollBaseCenter = [next.cx, next.cy, next.cz];
    });
    _rollEmitted = next;
    widget.onBoxChanged(next);
    // 视角同步回重力正上方的"顶" —— 与 _alignToTopOnce 同一个目标姿态。
    final top = kOrientationPresets.first;
    final target = composeViewMatrix(top.yaw, top.pitch, 0);
    _logicalRel = target;
    _snapToPose(target);
  }

  /// 菜单项二:相机回到默认取景(点云回到刚进来时的大小)。框不动。
  void _resetZoom() {
    _snap.stop();
    widget.controller.setRectPoseOverride(null);
    widget.controller.requestReframe();
  }

  /// 箭头按钮:与立方体贴紧(RS 观感),18px 图标 + 紧凑命中区。
  Widget _cubeArrow(IconData icon, VoidCallback onTap, Key key) => IconButton(
    key: key,
    onPressed: onTap,
    icon: Icon(icon),
    color: Colors.white70,
    // [2026-07-31 用户签决] 骰子与箭头整体变小,箭头再贴近骰子(对齐 RS)。
    iconSize: 15,
    padding: EdgeInsets.zero,
    constraints: const BoxConstraints(minWidth: 17, minHeight: 13),
    visualDensity: VisualDensity.compact,
  );

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
        // [2026-08-03 用户签决] "点击屏幕其他区域时,'⋯' 弹窗自动消失(跟取消
        // 的弹窗逻辑一样)"。
        //
        // ⚠️ 不能像取消弹窗那样用全屏 opaque 遮罩:那会吞掉手势,而 07-30 那条
        // 签决要求"拉开 ⋯ 时依然能转立方体 / 拨刻度 / 转点云"。这里放在 Stack
        // **最底层**且 translucent —— Stack 的命中测试是上层优先、命中即止,所以
        // 它只收得到落在空白处的点击(那正是"其他区域");点骰子/滑轨/箭头由那
        // 些交互自己顺手关菜单(见 _closeMenu 的调用点),一次点击既关菜单又生效。
        if (_menuOpen)
          Positioned.fill(
            key: const ValueKey('selection-menu-dismiss'),
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => _closeMenu(),
            ),
          ),
        Positioned(
          top: 8,
          left: 4,
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              // [2026-07-30 用户签决] 苹果相册版式:左上"取消",右上"完成",
              // "⋯" 排在取消下方、左对齐。
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // [PILL-BTN 2026-08-06 用户签决] 白色胶囊底+黑字。
                TextButton(
                  key: kSelectionCancelKey,
                  onPressed: widget.onCancel,
                  style: TextButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    minimumSize: const Size(0, 38),
                    shape: const StadiumBorder(),
                  ),
                  child: Text(
                    l.selectionCancel,
                    style: const TextStyle(
                      color: Colors.black,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Padding(
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
        // [2026-07-30 用户签决] 右上角是**文字**不是图标:预览页写"选区编辑",
        // 编辑页同一位置写"完成"(点它弹"编辑记录是否保存",三选一)。
        Positioned(
          top: 8,
          right: 4,
          child: SafeArea(
            // [PILL-BTN 2026-08-06 用户签决] 白色胶囊底+黑字。
            child: TextButton(
              key: const ValueKey('selection-back'),
              onPressed: widget.onExit,
              style: TextButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                minimumSize: const Size(0, 38),
                shape: const StadiumBorder(),
              ),
              child: Text(
                l.sfmDone,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
        // 六视图箭头 + 立方体整体下移,给上面的"完成"让位。
        Positioned(
          top: _kRightColumnTop,
          right: 12,
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _cubeArrow(
                  Icons.keyboard_arrow_up_rounded,
                  () => _rollCube(_kRollUp),
                  const ValueKey('cube-up'),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _cubeArrow(
                      Icons.keyboard_arrow_left_rounded,
                      () => _rollCube(_kRollLeft),
                      const ValueKey('cube-left'),
                    ),
                    ValueListenableBuilder<CloudViewCamera?>(
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
                          size: 54,
                        );
                      },
                    ),
                    _cubeArrow(
                      Icons.keyboard_arrow_right_rounded,
                      () => _rollCube(_kRollRight),
                      const ValueKey('cube-right'),
                    ),
                  ],
                ),
                _cubeArrow(
                  Icons.keyboard_arrow_down_rounded,
                  () => _rollCube(_kRollDown),
                  const ValueKey('cube-down'),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          // [2026-08-03 用户实机"黑色滑轴 UI 下面还有灰色背景"] 背景色必须在
          // SafeArea **外面** —— 包在里面时 home indicator 那条 inset 落在
          // Container 之外,露出下层灰底。现在黑色一直铺到屏幕最底边,内容靠
          // SafeArea 的 inset 自适应避开 indicator。
          // [2026-08-07 用户签决,附手绘图] 弧形刻度盘(汽车仪表盘式)。收起/
          // 展开不再靠半圆把手 —— **整个盘绕弧心转 180°** 就是收起动作(弧心在
          // 面板下方,转过去后弧线落到屏幕外),点指针或在指针上下滑动切换。
          // 背景纯黑、所有部件纯白,与三维编辑舱同一套规则。
          // [2026-08-09 用户签决] "滑轴不需要额外的黑色背景,跟点云浏览共用一个
          // 背景" —— 原来这里铺纯黑到屏幕底(2026-08-03 是为盖住下层灰底;
          // 现在画布本身已是纯黑,见 sparse_cloud_view 的 color: Colors.black,
          // 灰底问题不复存在)。点云不会从滑轨后面穿出来:painter 的
          // bottomFade 在滑轨处及以下直接不画(sparse_cloud_view.dart)。
          child: SafeArea(
            top: false,
            // 底部面板**不**包手势拦截器:外层的 Scale 识别器会和刻度盘的拖动
            // 抢竞技场,把拨动整个吃掉(实测框纹丝不动)。下层点云视图改由
            // bottomGestureExclusion 按位置忽略该区域 —— 确定性判定。
            child: RulerScrubber(
              value: _rollDeg,
              onChanged: _onRoll,
              originDeg: 0,
              deployed: !_rulerCollapsed,
              onDeployedChanged: (up) {
                setState(() => _rulerCollapsed = !up);
                widget.onRulerCollapsedChanged?.call(_rulerCollapsed);
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// 骰子手势:单指拖 = 转视角(带惯性),同时不让手势落到下层点云视图。
/// 点击某面归位由 ViewCube 自己的 onTapDown 处理,与拖动共存。
