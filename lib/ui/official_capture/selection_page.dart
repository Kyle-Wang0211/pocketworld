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
    final target = kOrientationPresets[_presetIdx];
    setState(() {
      _animPresetYaw = _fromYaw + (target.yaw - _fromYaw) * t;
      _animPitch = _fromPitch + (target.pitch - _fromPitch) * t;
    });
  }

  void _selectPreset(int idx) {
    if (idx == _presetIdx) return;
    _fromYaw = _animPresetYaw;
    _fromPitch = _animPitch;
    setState(() => _presetIdx = idx);
    unawaited(_presetAnim.forward(from: 0));
  }

  void _cycleHorizontal(int delta) {
    // 水平四向(索引 1..4)循环:Front→Right→Back→Left→Front。
    final cur = _presetIdx >= 1 && _presetIdx <= 4 ? _presetIdx : 1;
    final next = ((cur - 1 + delta) % 4 + 4) % 4 + 1;
    _selectPreset(next);
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
    return Scaffold(
      backgroundColor: const Color(0xFF0B0B0D),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: Colors.white70),
              )
            : _buildLoaded(context),
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
        _cubeArrow(Icons.keyboard_arrow_up_rounded, () => _selectPreset(0)),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _cubeArrow(
              Icons.keyboard_arrow_left_rounded,
              () => _cycleHorizontal(-1),
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
            ),
          ],
        ),
        _cubeArrow(Icons.keyboard_arrow_down_rounded, () => _selectPreset(5)),
      ],
    );
  }

  Widget _cubeArrow(IconData icon, VoidCallback onTap) => IconButton(
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
