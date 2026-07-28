// selection_page.dart — RS Reconstruction Region 同款选区页。
// 返回 = flush 框 → pop('save_draft')(调用方走保存草稿链路;签决:
// 不回等待页,直接草稿列表)。Ready to Process = 稠密化占位。
// 滑杆↔相机联动:viewYaw = preset.yaw + box.yawDeg(调研修订,spec 有
// 差异记录)。
import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

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
import 'ruler_scrubber.dart';
import 'selection_cloud_view.dart';
import 'view_cube.dart';
import 'sparse_cloud_view.dart' show CloudViewCamera, SparseCloudPainter;

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
    this.initialCamera,
  });

  /// [2026-07-28 用户签决] "预览跟编辑就是一个页面":进来时点云的大小/
  /// 角度/位置**直接继承**预览页,不再重置到固定俯视预设。
  final CloudViewCamera? initialCamera;

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

  /// 点云 fit 中心 = 相机枢轴(与 SelectionCloudView 内部一致),滑杆
  /// 旋转时框绕它公转以钉死屏幕位置。
  ({double cx, double cy, double cz, double radius})? _fit;
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

  /// 相机唯一真值源(yaw/pitch/zoom/pan/pivot)。orbit、双指、骰子归位
  /// 动画都写它;骰子读它 ⇒ "模型怎么转骰子就怎么转"。
  CloudViewCamera _camera = (
    yaw: kOrientationPresets[0].yaw,
    pitch: kOrientationPresets[0].pitch,
    zoom: 1.0,
    panX: 0.0,
    panY: 0.0,
    pivotX: 0.0,
    pivotY: 0.0,
    pivotZ: 0.0,
  );

  /// 屏幕滚转(骰子归位动画途中非零)。
  double _viewRoll = 0;

  /// 滑杆分量(弧度):滑杆转的是模型自身,相机 yaw 与它相加才是"我相对
  /// 模型的观察方向"。
  double get _boxYawRad => (_box?.yawDeg ?? 0) * math.pi / 180.0;

  /// 观察方向 = 相机 yaw + 滑杆分量。骰子读它 ⇒ 模型怎么转骰子就怎么转
  /// (骰子六面是**模型**的面,建模软件同款语义)。
  double get _effectiveYaw => _camera.yaw + _boxYawRad;

  CloudViewCamera _withPose(double yaw, double pitch) => (
    yaw: yaw,
    pitch: pitch,
    zoom: _camera.zoom,
    panX: _camera.panX,
    panY: _camera.panY,
    pivotX: _camera.pivotX,
    pivotY: _camera.pivotY,
    pivotZ: _camera.pivotZ,
  );

  // [2026-07-28 用户签决三轮] **骰子机制**:姿态 = 完整旋转矩阵 _pose,
  // 箭头 = 绕**屏幕轴**premultiply ±90°(下 = 绕屏幕水平轴向下滚,右 =
  // 绕屏幕竖直轴向右滚)。每按一次严格 90°,任何序列、任何状态,无例外
  // —— 就像现实中滚骰子。翻过极点后背面自然倒置(roll≠0),不做"回正"
  // 规范化:此前为让落定永远正立搞的环/动量/上下文 yaw 机制被用户否决
  // ("我就需要像现实生活中扔骰子一样,必须只转 90°"),全部删除。
  // 动画仍是 SO(3) 轴角 slerp(90° 单轴)。
  List<double> get _pose =>
      composeViewMatrix(_effectiveYaw, _camera.pitch, _viewRoll);
  List<double> _slerpTo = composeViewMatrix(
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

  /// 测试用:当前姿态矩阵。
  @visibleForTesting
  List<double> get debugPose => List.unmodifiable(_pose);

  /// 测试用:当前相机(继承/orbit/归位守门)。
  @visibleForTesting
  CloudViewCamera get debugCamera => _camera;

  /// 测试用:当前屏幕滚转。
  @visibleForTesting
  double get debugRoll => _viewRoll;

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
    final fit = SparseCloudPainter.fitOf(widget.xyz);
    _fit = fit;
    final SelectionBox box;
    if (loaded != null) {
      box = loaded;
    } else {
      box = SelectionBox.initialFor(
        cx: fit.cx,
        cy: fit.cy,
        cz: fit.cz,
        radius: fit.radius,
      );
    }
    if (!mounted) return;
    // 相机继承:视图实际 viewYaw = _camera.yaw + box.yawDeg,所以继承
    // 绝对视角时要把滑杆分量先扣掉,肉眼所见才逐帧不变。
    final cam = widget.initialCamera;
    final boxYaw = box.yawDeg * math.pi / 180.0;
    _camera = cam != null
        ? (
            yaw: cam.yaw - boxYaw,
            pitch: cam.pitch,
            zoom: cam.zoom,
            panX: cam.panX,
            panY: cam.panY,
            pivotX: cam.pivotX,
            pivotY: cam.pivotY,
            pivotZ: cam.pivotZ,
          )
        : (
            yaw: kOrientationPresets[0].yaw - boxYaw,
            pitch: kOrientationPresets[0].pitch,
            zoom: 1.0,
            panX: 0.0,
            panY: 0.0,
            pivotX: fit.cx,
            pivotY: fit.cy,
            pivotZ: fit.cz,
          );
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
        final (y, p, r) = decomposeViewMatrix(_slerpTo);
        _camera = _withPose(y - _boxYawRad, p);
        _viewRoll = r;
        return;
      }
      final r = mulMatrix(
        rotationFromAxisAngle(_slerpAxis, _slerpAngle * t),
        _slerpFrom,
      );
      final (y, p, roll) = decomposeViewMatrix(r);
      _camera = _withPose(y - _boxYawRad, p);
      _viewRoll = roll;
    });
  }

  /// 点击骰子某个面 → 该面转到正对相机(建模软件同款一键归位),
  /// 走 SO(3) 轴角 slerp 的最短路径。
  ///
  /// [2026-07-28 用户签决] 六固定视图 + 四个箭头已删除:相机现在完全自由
  /// (盒外单指 orbit),骰子既是朝向指示器也是归位入口。
  void _snapToFace(String label) {
    final preset = kOrientationPresets.firstWhere((p) => p.label == label);
    var targetYaw = preset.yaw;
    if (label == 'Top' || label == 'Bottom') {
      // 极面朝向退化(世界 +Y 与视线平行):用最接近当前朝向的 90° 倍数
      // 作上下文 yaw,避免从侧视角进俯视时绕一个斜轴长转。
      const q = math.pi / 2;
      targetYaw = (_effectiveYaw / q).roundToDouble() * q;
    }
    _slerpFrom = composeViewMatrix(_effectiveYaw, _camera.pitch, _viewRoll);
    _slerpTo = composeViewMatrix(targetYaw, preset.pitch, 0);
    final (axis, angle) = axisAngleOf(mulTransposed(_slerpTo, _slerpFrom));
    if (angle < 1e-6) return; // 已经正对该面
    _slerpAxis = axis;
    _slerpAngle = angle;
    _presetAnim.duration = Duration(
      milliseconds: (200 * (angle / (math.pi / 2))).round().clamp(160, 320),
    );
    setState(() {});
    unawaited(_presetAnim.forward(from: 0));
  }

  /// 自由 orbit / 双指平移缩放:相机唯一写入口。
  void _onCameraChanged(CloudViewCamera cam) {
    if (_presetAnim.isAnimating) _presetAnim.stop(); // 手一碰就接管动画
    setState(() {
      _camera = cam;
      _viewRoll = 0; // 手动转视角 ⇒ 回到无滚转的自然姿态
    });
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
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(AppL10n.of(context).selectionDensifyComingSoon)),
    );
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
                ? Center(
                    child: Text(
                      AppL10n.of(context).selectionNoCloud,
                      style: TextStyle(color: Colors.white54, fontSize: 14),
                    ),
                  )
                : SelectionCloudView(
                    xyz: widget.xyz,
                    rgb: widget.rgb,
                    box: box,
                    liveBox: () => _box ?? box,
                    onBoxChanged: _onBoxChanged,
                    viewYaw: _effectiveYaw,
                    viewPitch: _camera.pitch,
                    viewRoll: _viewRoll,
                    camera: _camera,
                    onCameraChanged: _onCameraChanged,
                  ),
          ),
        ),
        Positioned(
          top: 8,
          left: 4,
          // [2026-07-28 用户签决] 返回箭头后带文字"返回预览页面"。
          child: TextButton.icon(
            key: const ValueKey('selection-back'),
            onPressed: () => unawaited(_onBackPressed()),
            icon: const Icon(
              Icons.arrow_back_ios_new_rounded,
              color: Colors.white,
              size: 20,
            ),
            label: Text(
              AppL10n.of(context).selectionBackToPreview,
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
          ),
        ),
        Positioned(top: 8, right: 12, child: _orientationCube()),
        Positioned(left: 0, right: 0, bottom: 0, child: _bottomPanel(box)),
      ],
    );
  }

  /// 面 ID(内部恒英文)→ 本地化显示词。
  Map<String, String> _cubeFaceLabels(BuildContext context) {
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

  Widget _orientationCube() {
    // [2026-07-28 用户签决] 四个箭头删除;骰子与相机完全绑定(含自由
    // orbit 的任意角度),点击某面 = 转到该面正对。
    return ViewCube(
      key: const ValueKey('view-cube'),
      viewYaw: _effectiveYaw,
      viewPitch: _camera.pitch,
      viewRoll: _viewRoll,
      faceLabels: _cubeFaceLabels(context),
      onFaceTap: _snapToFace,
      size: 72,
    );
  }

  Widget _bottomPanel(SelectionBox box) {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      decoration: const BoxDecoration(color: Color(0xFF0B0B0D)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppL10n.of(context).selectionRotatePointCloud,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          // [2026-07-28 用户签决] RS 同款无限刻度尺:无端点可一直拨,
          // 360° 循环;连续值不吸附刻度。落盘前归一化到 (-180,180]。
          RulerScrubber(
            value: box.yawDeg,
            onChanged: (v) {
              // [2026-07-28 用户签决] 旋转时框在屏幕上不动:增量取最短环向
              // 差(甩动惯性给的是无界连续值),整盒绕相机枢轴刚性旋转,
              // 与相机 viewYaw 增量精确抵消;yaw 落盘前归一化 (-180,180]。
              final fit = _fit;
              if (fit == null) return;
              // 用 state 最新盒(非 build 闭包快照):框手势可能同帧并发
              // 改盒,双写者都读改同步真值才互不覆盖。
              final live = _box ?? box;
              var delta = (v - live.yawDeg) % 360.0;
              if (delta > 180.0) delta -= 360.0;
              final rotated = live.rotatedAroundPivot(fit.cx, fit.cz, delta);
              final y = rotated.yawDeg;
              final wrapped = y - 360.0 * ((y + 180.0) / 360.0).floorToDouble();
              _onBoxChanged(rotated.copyWith(yawDeg: wrapped));
            },
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
              child: Text(AppL10n.of(context).selectionReadyToProcess),
            ),
          ),
        ],
      ),
    );
  }
}
