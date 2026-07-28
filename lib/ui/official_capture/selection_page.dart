// selection_page.dart — RS Reconstruction Region 同款选区页。
// 返回 = flush 框 → pop('save_draft')(调用方走保存草稿链路;签决:
// 不回等待页,直接草稿列表)。Ready to Process = 稠密化占位。
// 滑杆↔相机联动:viewYaw = preset.yaw + box.yawDeg(调研修订,spec 有
// 差异记录)。
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../official_capture/selection_box.dart';
import '../../official_util/device_log.dart';
import 'cloud_camera.dart'
    show
        composeViewMatrix,
        decomposeViewMatrix,
        mulMatrix,
        mulTransposed,
        axisAngleOf,
        rotationFromAxisAngle;
import 'selection_cloud_view.dart';
import 'view_cube.dart';
import 'sparse_cloud_view.dart' show SparseCloudPainter;

/// 六向朝向预设(顺序即立方体循环顺序:Top → Front → Right → Back → Left →
/// Bottom)。索引 1..4 是水平面四向,0/5 是俯视/仰视。
const List<({String label, double yaw, double pitch})> kOrientationPresets = [
  (label: 'Top', yaw: 0, pitch: -math.pi / 2),
  (label: 'Front', yaw: 0, pitch: 0),
  (label: 'Right', yaw: math.pi / 2, pitch: 0),
  (label: 'Back', yaw: math.pi, pitch: 0),
  (label: 'Left', yaw: -math.pi / 2, pitch: 0),
  (label: 'Bottom', yaw: 0, pitch: math.pi / 2),
];

class SelectionPage extends StatefulWidget {
  const SelectionPage({
    super.key,
    required this.xyz,
    required this.rgb,
    required this.captureDir,
  });

  /// 3 floats per point(full set)。
  final Float32List xyz;

  /// 3 bytes per point。
  final Uint8List rgb;

  /// 选区盒 JSON 落盘目录(与采集目录同一处)。
  final String captureDir;

  @override
  State<SelectionPage> createState() => _SelectionPageState();
}

class _SelectionPageState extends State<SelectionPage>
    with SingleTickerProviderStateMixin {
  SelectionBox? _box;
  bool _loading = true;
  int _presetIdx = 0;
  Timer? _saveDebounce;

  /// in-flight 守卫:_onBackPressed 里 await _flush() 期间(真实 IO)若
  /// 二次触发(例如返回按钮被连点),没有这个守卫会二次 Navigator.pop,
  /// 把本页之上的 capture route 也 pop 掉。
  bool _exiting = false;

  // 显式在 initState 里建(不用 late final = 惰性初始化):否则若用户全程
  // 没碰朝向立方体,_presetAnim 从未被访问过,首次访问会拖到 dispose() 里
  // 因 `_presetAnim.dispose()` 触发惰性构造 —— 此时 vsync(this) 要向上找
  // TickerMode 祖先,但 element 树已在 deactivate,炸"Looking up a
  // deactivated widget's ancestor is unsafe"(真机同样会炸,非测试专属)。
  late final AnimationController _presetAnim;

  double _animPresetYaw = kOrientationPresets[0].yaw;
  double _animPitch = kOrientationPresets[0].pitch;
  double _animRoll = 0;

  // [2026-07-28 用户签决"抄成熟机制"] 预设切换动画 = SO(3) 轴角 slerp
  // (ViewCube/three.js CameraControls 同款):从当前姿态到目标规范姿态
  // 绕单一固定轴平滑旋转。Bottom→Back 因此是一次连续翻转(翻+回正合成
  // 单轴),不再是 yaw 空间的水平长绕。中间帧分解回 (yaw,pitch,roll) 喂
  // 现有投影管线;落定 = 目标规范角,roll 精确归零。
  List<double> _slerpFrom = composeViewMatrix(
    kOrientationPresets[0].yaw,
    kOrientationPresets[0].pitch,
    0,
  );
  List<double> _slerpAxis = [1, 0, 0];
  double _slerpAngle = 0;

  /// 本次切换的目标姿态角。Top/Bottom 的 yaw **带上下文**(= 来源水平面的
  /// 朝向):kOrientationPresets 里 Top/Bottom yaw 固定 0 会让 Right→Top
  /// 变成 120° 斜轴歪转(host 角度表实测);上下文 yaw 下 H↔Top/Bottom
  /// 恒为纯 90° 翻转。落定用这两个值,不再拍回表里的规范 yaw。
  double _targetYaw = kOrientationPresets[0].yaw;
  double _targetPitch = kOrientationPresets[0].pitch;

  /// 测试用:直接读当前盒(见 test/selection_page_test.dart)。
  @visibleForTesting
  SelectionBox? get debugBox => _box;

  /// 测试用:当前预设面的标签(立方体改 TextPainter 绘制后 find.text 不再
  /// 可用,语义断言走这里)。
  @visibleForTesting
  String get debugFacingLabel => kOrientationPresets[_presetIdx].label;

  @override
  void initState() {
    super.initState();
    _presetAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..addListener(_onPresetTick);
    unawaited(_load());
  }

  Future<void> _load() async {
    final loaded = await SelectionBox.loadFrom(widget.captureDir);
    final SelectionBox box;
    if (loaded != null) {
      box = loaded;
    } else {
      final fit = SparseCloudPainter.fitOf(widget.xyz);
      box = SelectionBox.initialFor(
        cx: fit.cx,
        cy: fit.cy,
        cz: fit.cz,
        radius: fit.radius,
      );
    }
    if (!mounted) return;
    setState(() {
      _box = box;
      _loading = false;
    });
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _presetAnim.dispose();
    super.dispose();
  }

  void _onPresetTick() {
    final t = Curves.easeOutCubic.transform(_presetAnim.value);
    setState(() {
      if (t >= 1.0) {
        // 落定:精确取目标角(含上下文 yaw),不经分解(避免尾差),roll 归零。
        _animPresetYaw = _targetYaw;
        _animPitch = _targetPitch;
        _animRoll = 0;
        return;
      }
      final r = mulMatrix(
        rotationFromAxisAngle(_slerpAxis, _slerpAngle * t),
        _slerpFrom,
      );
      final (y, p, roll) = decomposeViewMatrix(r);
      _animPresetYaw = y;
      _animPitch = p;
      _animRoll = roll;
    });
  }

  // [2026-07-28 用户签决四轮定案] 纯骰子机制(严格每步 90°)已实测否决:
  // 真骰子滚两步后对面必倒置(SO(3) 几何),用户实机指认"Front 倒过来
  // 了,模型在手里不可能倒" —— **落定永不倒置(重力锚定)是最硬约束**。
  // 回到六固定视图+动量环:水平四面唯一正立;过极步动画 = 翻转+摆正
  // 合成的 180° 单轴平滑(时长缩放保持干脆观感)。
  void _selectPreset(int idx, {double? targetYaw}) {
    if (idx == _presetIdx) return;
    // slerp:从当前(可能在动画中途,含 roll)姿态到目标姿态的单轴最短
    // 旋转 —— 上下箭头进出 Top/Bottom(上下文 yaw)恒 90°,水平相邻 90°,
    // 过极 180°(翻+回正合成单轴),侧翻 120°(SO(3) 几何下限,AutoCAD
    // ViewCube 相同)。
    _slerpFrom = composeViewMatrix(_animPresetYaw, _animPitch, _animRoll);
    _targetYaw = targetYaw ?? kOrientationPresets[idx].yaw;
    _targetPitch = kOrientationPresets[idx].pitch;
    final to = composeViewMatrix(_targetYaw, _targetPitch, 0);
    final (axis, angle) = axisAngleOf(mulTransposed(to, _slerpFrom));
    _slerpAxis = axis;
    _slerpAngle = angle;
    // 时长按转角缩放:90° 一步 200ms;过极步(转过去+摆正合成 180°)
    // 280ms,保持"一次干脆翻转"的观感而不是慢悠悠转半圈。
    _presetAnim.duration = Duration(
      milliseconds: (200 * (angle / (math.pi / 2))).round().clamp(140, 280),
    );
    if (idx >= 1 && idx <= 4) _lastHorizontalIdx = idx; // 供上下箭头回落
    setState(() => _presetIdx = idx);
    unawaited(_presetAnim.forward(from: 0));
  }

  void _cycleHorizontal(int delta) {
    _vertMomentum = 0; // 左右切换打断竖直环
    // [2026-07-28 用户签决二轮:四个箭头**永远翻面**,每次一个相邻面]
    // 此前 Top/Bottom 的左右箭头做"原地转 90°"——用户实机指认:点了
    // 根本不翻面,点云只是转了 90°,不是想要的。删除原地转;极面的左右
    // 箭头 = 翻到回落参考面(_lastHorizontalIdx)的相邻水平面,与水平
    // 循环同一方向语义,恒 90° 一步。
    final base = (_presetIdx >= 1 && _presetIdx <= 4)
        ? _presetIdx
        : _lastHorizontalIdx;
    final next = ((base - 1 + delta) % 4 + 4) % 4 + 1;
    _selectPreset(next);
  }

  /// 记住最近停留的水平面(1..4),从 Top/Bottom 回落时回到它而不是硬编码
  /// Front。由 [_selectPreset] 在进入水平面时更新。
  int _lastHorizontalIdx = 1;

  /// 对面(Front↔Back,Right↔Left)。
  int _oppositeOf(int h) => ((h - 1 + 2) % 4) + 1;

  /// 滚动动量:+1 = 下行环,−1 = 上行环,0 = 无(刚点过左右箭头等)。
  /// [2026-07-28 用户实机指认] 无动量时"水平面下→必去 Bottom"会产生
  /// bottom→back→bottom→front 震荡,永远经过不了 Top。有动量后连续按
  /// 同一箭头 = 沿同一竖直大圆绕整圈:Front→Bottom→Back→Top→Front,
  /// 四面全经过(下行);上行对称反向。
  int _vertMomentum = 0;

  /// 本轮竖直环的基面(进入环时所在的水平面):环 = base → Bottom →
  /// opp(base) → Top → base(下行序)。水平面在环中的下一站由"它是 base
  /// 还是 opp(base)"决定。
  int _ringBase = 1;

  /// 上下箭头 = 竖直大圆滚动,每步一个相邻面,过极循环、永不无操作。
  /// 动画角:H↔极面(上下文 yaw)90° 纯翻;极面→对面水平面 180°
  /// (翻过极点+回正合成的单轴平滑旋转 —— SO(3) 里"90° 纯翻到正立对面"
  /// 不存在,翻过去必倒置,AutoCAD ViewCube 停在倒置,我们选正立落定)。
  void _stepVertical(int dir) {
    final horizontal = _presetIdx >= 1 && _presetIdx <= 4;
    final m = dir < 0 ? -1 : 1;
    final prevM = _vertMomentum;
    if (prevM != m) {
      // 方向改变/首次进入:以当前水平面(或极面的回落参考)为环基。
      _ringBase = horizontal ? _presetIdx : _lastHorizontalIdx;
    }
    _vertMomentum = m;
    if (_presetIdx == 0) {
      // Top:同向 = 环继续/过极 → 对面(180°);反向(刚沿环到达又按
      // 相反箭头)= 原路 retrace 回 lastH(90°),画面严格倒放上一步。
      final continueRing = (dir < 0 && prevM != 1) || (dir > 0 && prevM == 1);
      _selectPreset(
        continueRing ? _oppositeOf(_lastHorizontalIdx) : _lastHorizontalIdx,
      );
    } else if (_presetIdx == 5) {
      // Bottom:镜像对称。
      final continueRing = (dir > 0 && prevM != -1) || (dir < 0 && prevM == -1);
      _selectPreset(
        continueRing ? _oppositeOf(_lastHorizontalIdx) : _lastHorizontalIdx,
      );
    } else if (horizontal) {
      // 水平面:默认下→Bottom/上→Top(90° 纯翻,上下文 yaw);唯当处于
      // 环中继(带动量且已滚到环基对面)时反配极面,使连续同向按键沿
      // 大圆绕整圈把四个面全走一遍。
      final atOpp = _presetIdx == _oppositeOf(_ringBase);
      final int target;
      if (dir > 0) {
        target = (prevM == 1 && atOpp) ? 0 : 5;
      } else {
        target = (prevM == -1 && atOpp) ? 5 : 0;
      }
      _selectPreset(target, targetYaw: kOrientationPresets[_presetIdx].yaw);
    }
  }

  void _onBoxChanged(SelectionBox b) {
    setState(() => _box = b);
    _saveDebounce?.cancel();
    _saveDebounce = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(_persist(b)),
    );
  }

  Future<void> _persist(SelectionBox b) async {
    try {
      await b.saveTo(widget.captureDir);
    } catch (e) {
      DeviceLog.log('SelectionPage', 'save failed: $e');
    }
  }

  /// 立即落盘(取消 debounce),返回前调用。
  Future<void> _flush() async {
    _saveDebounce?.cancel();
    final b = _box;
    if (b == null) return;
    try {
      await b.saveTo(widget.captureDir);
    } catch (e) {
      DeviceLog.log('SelectionPage', 'save failed: $e');
    }
  }

  Future<void> _onBackPressed() async {
    // 防重入:_flush() 是真实 saveTo IO,await 期间若二次触发(连点返回
    // 按钮/Android 返回键连按两次)没有这个守卫会二次 pop,把本页之上的
    // capture route 也带出去。
    if (_exiting) return;
    _exiting = true;
    await _flush();
    if (!mounted) return;
    Navigator.pop(context, 'save_draft');
  }

  void _onReadyToProcess() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('稠密化处理即将上线')));
  }

  @override
  Widget build(BuildContext context) {
    // 隐式 pop(不经 _onBackPressed)必须被杜绝,否则会跳过 _flush()
    // (丢 500ms debounce 窗口内的最后一次改动)且 ar_capture_page.dart 的
    // `result == 'save_draft'` 判断不成立,用户会落回等待页 —— 违反
    // spec"选区页返回不回等待页"签决。canPop:false 下两端行为不同,准确
    // 表述(别再写成"两端都转发"):
    // · Android 系统返回键经 maybePop 触发 onPopInvokedWithResult
    //   (didPop=false)→ 转发到 _onBackPressed,走同一条 flush→pop 链路。
    // · iOS 侧滑手势被框架直接禁用(popGestureEnabled → false,手势
    //   inert,不产生 pop 尝试,onPopInvokedWithResult 不会因侧滑触发)。
    //   iOS 上唯一的返回出口是左上角返回按钮(与父路由 ar_capture_page
    //   同款处理)。
    // _onBackPressed 内部已有 mounted 守卫和显式
    // Navigator.pop(context, 'save_draft'),canPop:false 不影响显式 pop。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        unawaited(_onBackPressed());
      },
      child: Scaffold(
        backgroundColor: const Color(0xFF0B0B0D),
        body: SafeArea(
          child: _loading
              ? const Center(
                  child: CircularProgressIndicator(color: Colors.white70),
                )
              : _buildLoaded(context),
        ),
      ),
    );
  }

  Widget _buildLoaded(BuildContext context) {
    final box = _box!;
    return Stack(
      children: [
        Positioned.fill(
          child: Padding(
            padding: const EdgeInsets.only(top: 64, bottom: 148),
            child: widget.xyz.isEmpty
                ? const Center(
                    child: Text(
                      '暂无点云数据',
                      style: TextStyle(color: Colors.white54, fontSize: 14),
                    ),
                  )
                : SelectionCloudView(
                    xyz: widget.xyz,
                    rgb: widget.rgb,
                    box: box,
                    onBoxChanged: _onBoxChanged,
                    viewYaw: _animPresetYaw + box.yawDeg * math.pi / 180,
                    viewPitch: _animPitch,
                    viewRoll: _animRoll,
                  ),
          ),
        ),
        Positioned(
          top: 8,
          left: 4,
          child: IconButton(
            key: const ValueKey('selection-back'),
            onPressed: () => unawaited(_onBackPressed()),
            icon: const Icon(Icons.arrow_back_ios_new_rounded),
            color: Colors.white,
            iconSize: 22,
          ),
        ),
        Positioned(top: 8, right: 12, child: _orientationCube()),
        Positioned(left: 0, right: 0, bottom: 0, child: _bottomPanel(box)),
      ],
    );
  }

  Widget _orientationCube() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _cubeArrow(
          Icons.keyboard_arrow_up_rounded,
          () => _stepVertical(-1),
          key: const ValueKey('cube-up'),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _cubeArrow(
              Icons.keyboard_arrow_left_rounded,
              () => _cycleHorizontal(-1),
              key: const ValueKey('cube-left'),
            ),
            // [2026-07-28 用户签决二轮] 立方体 = **语义朝向指示器**:只吃
            // 预设姿态(_animPresetYaw/_animPitch),不吃滑杆分量 —— 滑杆是
            // "点云对齐盒"的任意角微调,喂进立方体会让它常年歪着
            // (用户实机两次指认)。预设切换动画期间立方体随动画转,落定
            // 即整齐正对。
            ViewCube(
              viewYaw: _animPresetYaw,
              viewPitch: _animPitch,
              viewRoll: _animRoll,
            ),
            _cubeArrow(
              Icons.keyboard_arrow_right_rounded,
              () => _cycleHorizontal(1),
              key: const ValueKey('cube-right'),
            ),
          ],
        ),
        _cubeArrow(
          Icons.keyboard_arrow_down_rounded,
          () => _stepVertical(1),
          key: const ValueKey('cube-down'),
        ),
      ],
    );
  }

  Widget _cubeArrow(IconData icon, VoidCallback onTap, {Key? key}) =>
      IconButton(
        key: key,
        onPressed: onTap,
        icon: Icon(icon),
        color: Colors.white70,
        iconSize: 18,
        padding: EdgeInsets.zero,
        // [2026-07-28 用户反馈] 与立方体贴紧(RS 观感)。
        constraints: const BoxConstraints(minWidth: 24, minHeight: 18),
        visualDensity: VisualDensity.compact,
      );

  Widget _bottomPanel(SelectionBox box) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      decoration: const BoxDecoration(color: Color(0xFF0B0B0D)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Rotate Point Cloud',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          Slider(
            min: -180,
            max: 180,
            value: box.yawDeg.clamp(-180, 180),
            onChanged: (v) => _onBoxChanged(box.copyWith(yawDeg: v)),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: _onReadyToProcess,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF0A84FF),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text('Ready to Process'),
            ),
          ),
        ],
      ),
    );
  }
}
