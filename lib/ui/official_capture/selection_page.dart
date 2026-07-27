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
import 'selection_cloud_view.dart';
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

  double _fromYaw = kOrientationPresets[0].yaw;
  double _fromPitch = kOrientationPresets[0].pitch;
  double _animPresetYaw = kOrientationPresets[0].yaw;
  double _animPitch = kOrientationPresets[0].pitch;

  /// 本次动画的 yaw 目标(见 _selectPreset)—— 与 kOrientationPresets 表中
  /// 的原始 yaw 不同:已归一化到与 _fromYaw 最短弧,避免 Back↔Left(表中
  /// 相差 270°)之类的预设走 3/4 圈长弧动画。
  double _toYaw = kOrientationPresets[0].yaw;

  /// 测试用:直接读当前盒(见 test/selection_page_test.dart)。
  @visibleForTesting
  SelectionBox? get debugBox => _box;

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
    final targetPitch = kOrientationPresets[_presetIdx].pitch;
    setState(() {
      // 用归一化后的 _toYaw(不是表里的原始 yaw)做 lerp 目标,见
      // _selectPreset 里的最短弧归一化。
      _animPresetYaw = _fromYaw + (_toYaw - _fromYaw) * t;
      _animPitch = _fromPitch + (targetPitch - _fromPitch) * t;
    });
  }

  void _selectPreset(int idx) {
    if (idx == _presetIdx) return;
    _fromYaw = _animPresetYaw;
    _fromPitch = _animPitch;
    // Back(π)↔Left(-π/2)之类的预设在表里相差 270°:朴素 lerp 会摆动经过
    // Front/Right,走 3/4 圈长弧。把目标 yaw 归一化到与 _fromYaw 的最短弧
    // (±π 内)再存进动画目标 _toYaw,而不是改 kOrientationPresets 表本身
    // (表仍是每个朝向的规范角度,供其它读者——如 orientation cube 标签——
    // 使用)。动画结束后 _animPresetYaw 可能带 2π 整数倍偏移,但它只会喂
    // 进 viewYaw 的 cos/sin(见 _buildLoaded),周期函数对整数倍 2π 偏移
    // 不敏感,不影响渲染或后续联动计算。
    var target = kOrientationPresets[idx].yaw;
    while (target - _fromYaw > math.pi) {
      target -= 2 * math.pi;
    }
    while (target - _fromYaw < -math.pi) {
      target += 2 * math.pi;
    }
    _toYaw = target;
    if (idx >= 1 && idx <= 4) _lastHorizontalIdx = idx; // 供上下箭头回落
    setState(() => _presetIdx = idx);
    unawaited(_presetAnim.forward(from: 0));
  }

  void _cycleHorizontal(int delta) {
    // [2026-07-28 用户签决:所有箭头每次只转一个面,无任何直达]
    if (_presetIdx == 0 || _presetIdx == 5) {
      // Top/Bottom 视角:左右箭头 = 俯/仰视图**原地**绕竖直轴转 90°
      // (RS 立方体同款),不跳到水平面。同步回落参考面
      // (_lastHorizontalIdx),让随后的下/上箭头落到与当前画面朝向
      // 一致的水平面。label 保持 Top/Bottom(yaw 只进 cos/sin,带整数
      // 倍 90° 偏移无碍)。
      final next = ((_lastHorizontalIdx - 1 + delta) % 4 + 4) % 4 + 1;
      _lastHorizontalIdx = next;
      _fromYaw = _animPresetYaw;
      _fromPitch = _animPitch;
      _toYaw = _fromYaw + delta * math.pi / 2; // 与水平循环同向,恒 90° 一步
      setState(() {});
      unawaited(_presetAnim.forward(from: 0));
      return;
    }
    // 水平四向(索引 1..4)循环:Front→Right→Back→Left→Front,每步 90°。
    final next = ((_presetIdx - 1 + delta) % 4 + 4) % 4 + 1;
    _selectPreset(next);
  }

  /// 记住最近停留的水平面(1..4),从 Top/Bottom 回落时回到它而不是硬编码
  /// Front。由 [_selectPreset] 在进入水平面时更新。
  int _lastHorizontalIdx = 1;

  /// 对面(Front↔Back,Right↔Left)。
  int _oppositeOf(int h) => ((h - 1 + 2) % 4) + 1;

  /// 上下箭头 = 竖直大圆滚动,每步 90° 相邻面,**过极点循环、永不无操作**。
  ///
  /// [2026-07-28 用户签决 + Autodesk ViewCube 官方行为核实] ViewCube 的
  /// orbit 箭头在 Top 视角继续按上会滚到 Back("already looking at the
  /// top, you'll get the back view"),四步一圈,不存在死点。AutoCAD 到达
  /// 的 Back 是倒置的(up 翻转);我们的 yaw/pitch 相机不表达 up 翻转,
  /// 采用 up 修正版:过极点直接落到**正立**的对面(label 立即有意义,
  /// 触屏产品更合适)。规则:
  /// · 上:水平面 → Top;Top → 对面(过极);Bottom → 回水平面。
  /// · 下:水平面 → Bottom;Bottom → 对面(过极);Top → 回水平面。
  /// 到达对面后 _selectPreset 会把 _lastHorizontalIdx 更新为该面,下一圈
  /// 自动以它为基 —— 连续按同一箭头 = Front→Top→Back→Top→Front… 的
  /// 四步循环(up 每步修正后"向上"语义重置,与 ViewCube 修正版一致)。
  void _stepVertical(int dir) {
    final horizontal = _presetIdx >= 1 && _presetIdx <= 4;
    if (dir < 0) {
      // 上箭头
      if (_presetIdx == 0) {
        _selectPreset(_oppositeOf(_lastHorizontalIdx)); // 过极 → 对面(正立)
      } else if (_presetIdx == 5) {
        _selectPreset(_lastHorizontalIdx);
      } else if (horizontal) {
        _selectPreset(0);
      }
    } else {
      // 下箭头
      if (_presetIdx == 5) {
        _selectPreset(_oppositeOf(_lastHorizontalIdx)); // 过极 → 对面(正立)
      } else if (_presetIdx == 0) {
        _selectPreset(_lastHorizontalIdx);
      } else if (horizontal) {
        _selectPreset(5);
      }
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
    final label = kOrientationPresets[_presetIdx].label;
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
            Container(
              width: 56,
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                border: Border.all(color: Colors.white38),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                label,
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
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
        iconSize: 20,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 32, minHeight: 24),
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
