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

  // [2026-07-28 用户签决三轮] **骰子机制**:姿态 = 完整旋转矩阵 _pose,
  // 箭头 = 绕**屏幕轴**premultiply ±90°(下 = 绕屏幕水平轴向下滚,右 =
  // 绕屏幕竖直轴向右滚)。每按一次严格 90°,任何序列、任何状态,无例外
  // —— 就像现实中滚骰子。翻过极点后背面自然倒置(roll≠0),不做"回正"
  // 规范化:此前为让落定永远正立搞的环/动量/上下文 yaw 机制被用户否决
  // ("我就需要像现实生活中扔骰子一样,必须只转 90°"),全部删除。
  // 动画仍是 SO(3) 轴角 slerp(90° 单轴)。
  List<double> _pose = composeViewMatrix(
    kOrientationPresets[0].yaw,
    kOrientationPresets[0].pitch,
    0,
  );
  List<double> _slerpFrom = composeViewMatrix(
    kOrientationPresets[0].yaw,
    kOrientationPresets[0].pitch,
    0,
  );
  List<double> _slerpAxis = [1, 0, 0];
  double _slerpAngle = 0;

  /// 测试用:直接读当前盒(见 test/selection_page_test.dart)。
  @visibleForTesting
  SelectionBox? get debugBox => _box;

  /// 测试用:当前(落定目标)姿态下最正对相机的面标签。
  @visibleForTesting
  String get debugFacingLabel {
    final (y, p, _) = decomposeViewMatrix(_pose);
    return primaryViewCubeFace(y, p);
  }

  /// 测试用:落定目标姿态矩阵(锁"每步严格 90°"守门断言)。
  @visibleForTesting
  List<double> get debugPose => List.unmodifiable(_pose);

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
        // 落定:精确取目标姿态角。骰子机制下 roll 不归零 —— 翻过极点
        // 背面就是倒的,和现实骰子一致。
        final (y, p, r) = decomposeViewMatrix(_pose);
        _animPresetYaw = y;
        _animPitch = p;
        _animRoll = r;
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

  /// 视空间 90° 旋转(premultiply 用):下/上 = 绕屏幕水平轴,右/左 =
  /// 绕屏幕竖直轴。方向验证:Top 按下 → Front;Front 按右 → Right。
  static const List<double> _kRollDown = [1, 0, 0, 0, 0, -1, 0, 1, 0];
  static const List<double> _kRollUp = [1, 0, 0, 0, 0, 1, 0, -1, 0];
  static const List<double> _kRollRight = [0, 0, 1, 0, 1, 0, -1, 0, 0];
  static const List<double> _kRollLeft = [0, 0, -1, 0, 1, 0, 1, 0, 0];

  /// 骰子滚动:目标姿态 = viewRot·当前目标姿态(严格 90°);动画从当前
  /// 显示姿态(可能在动画中途)slerp 过去,连点自然追赶累积。
  void _rollCube(List<double> viewRot) {
    _slerpFrom = composeViewMatrix(_animPresetYaw, _animPitch, _animRoll);
    _pose = mulMatrix(viewRot, _pose);
    final (axis, angle) = axisAngleOf(mulTransposed(_pose, _slerpFrom));
    _slerpAxis = axis;
    _slerpAngle = angle;
    setState(() {});
    unawaited(_presetAnim.forward(from: 0));
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
          () => _rollCube(_kRollUp),
          key: const ValueKey('cube-up'),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _cubeArrow(
              Icons.keyboard_arrow_left_rounded,
              () => _rollCube(_kRollLeft),
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
              () => _rollCube(_kRollRight),
              key: const ValueKey('cube-right'),
            ),
          ],
        ),
        _cubeArrow(
          Icons.keyboard_arrow_down_rounded,
          () => _rollCube(_kRollDown),
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
