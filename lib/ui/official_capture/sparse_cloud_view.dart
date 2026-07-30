// sparse_cloud_view.dart — reusable sparse point-cloud viewer widget.
//
// One implementation serves BOTH surfaces:
//   • the capture-time preview overlay (sfm_preview_overlay.dart), and
//   • the drafts "查看点云" full-screen page (sparse_cloud_viewer_page.dart)
// so viewer behaviour (desktop-research-viewer parity: 1-finger rotate,
// 2-finger pinch zoom + drag pan, 点大小/AgX/曝光 controls, render-only
// outlier clip, palette-bucketed true colors) never drifts between them.
//
// Review is authoritative and renders the complete persisted PLY. Capture AR
// has its own display-only progressive LOD; neither surface can rewrite the
// reconstruction or exported point set.

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../official_capture/selection_box.dart';
import '../../point_cloud_display/progressive_octree_order.dart';
import 'cloud_camera.dart';
import 'selection_rect_handles.dart';

/// 框外点的调制色(RS 同款红;只影响渲染调制,不碰数据)。
const int kSelectionOutColor = 0xFFE05252;

/// 选区盒 8 角世界坐标。index = x位 + y位·2 + z位·4(0=负,1=正)。
List<List<double>> selectionBoxCorners(SelectionBox b) {
  final r = b.rot;
  final out = <List<double>>[];
  for (var zi = 0; zi < 2; zi++) {
    for (var yi = 0; yi < 2; yi++) {
      for (var xi = 0; xi < 2; xi++) {
        final lx = (xi == 0 ? -1 : 1) * b.sx / 2;
        final ly = (yi == 0 ? -1 : 1) * b.sy / 2;
        final lz = (zi == 0 ? -1 : 1) * b.sz / 2;
        // 局部 → 世界:world = rot·local(行主序)。
        out.add([
          b.cx + r[0] * lx + r[1] * ly + r[2] * lz,
          b.cy + r[3] * lx + r[4] * ly + r[5] * lz,
          b.cz + r[6] * lx + r[7] * ly + r[8] * lz,
        ]);
      }
    }
  }
  return out;
}

/// Snapshot of the animatable camera state (double-tap focus / reframe lerp).
class _CamState {
  const _CamState({
    required this.pivot,
    required this.panX,
    required this.panY,
    required this.zoom,
    required this.yaw,
    required this.pitch,
  });
  final List<double> pivot; // world [x,y,z]
  final double panX, panY, zoom, yaw, pitch;
}

/// Translucent round icon button (reframe control).
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0x552A2A2A),
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(9),
          child: Icon(icon, size: 20, color: Colors.white70),
        ),
      ),
    );
  }
}

/// 点云查看相机快照 —— 预览页 ⇄ 选区编辑页之间"原样继承"的载体。
/// [2026-07-28 用户签决] 进编辑页时大小/角度/位置直接继承,不再重置到
/// 固定俯视预设。
typedef CloudViewCamera = ({
  double yaw,
  double pitch,

  /// 屏幕滚转。[2026-07-29 用户签决"框不动、点云转"] 旋转滑轨绕任意世界轴
  /// 转相机,分解出来一般带滚转,故提升为一等相机分量。
  double roll,
  double zoom,
  double panX,
  double panY,
  double pivotX,
  double pivotY,
  double pivotZ,
});

/// 外部驱动相机的控制器(骰子点击归位用)。视图仍是相机的持有者 ——
/// 这里只投递"请转到这个姿态"的一次性目标,避免把整套相机状态提升出去。
class CloudViewController extends ChangeNotifier {
  CloudViewCamera? _target;
  bool _reframe = false;

  void moveTo(CloudViewCamera c) {
    _target = c;
    notifyListeners();
  }

  CloudViewCamera? takeTarget() {
    final t = _target;
    _target = null;
    return t;
  }

  /// 请求回到默认取景("回到初始点云大小")。
  void requestReframe() {
    _reframe = true;
    notifyListeners();
  }

  bool takeReframe() {
    final r = _reframe;
    _reframe = false;
    return r;
  }
}

class SparseCloudView extends StatefulWidget {
  const SparseCloudView({
    super.key,
    required this.xyz,
    required this.rgb,
    this.visibility,
    this.showControls = true,
    this.initialCamera,
    this.onCameraChanged,
    this.selectionBox,
    this.onBoxChanged,
    this.liveBox,
    this.editing = false,
    this.controller,
    this.bottomGestureExclusion = 0,
  });

  /// 底部这么高的区域不接受相机手势 —— 编辑态工具面板压在全屏点云视图
  /// 之上(视图保持全屏才不会在切换时跳),而手势竞技场拦不住:实测拨
  /// 刻度尺时下层仍吃到 8px 位移并把视角转走。位置判定是确定性的。
  final double bottomGestureExclusion;

  /// 见 [CloudViewController]。

  /// [2026-07-28 用户签决] "浏览页面和编辑页面需要是同一个页面 —— 根本
  /// 不用做两个画面":同一个视图既是预览也是编辑器。传 selectionBox 就画
  /// 3D 线框和红点;editing=true 再挂手柄与盒手势(单指命中手柄改尺寸 /
  /// 盒内平移盒 / 盒外自由 orbit)。相机自始至终是这一个 State,天然连续。
  final SelectionBox? selectionBox;
  final ValueChanged<SelectionBox>? onBoxChanged;

  /// 手势读数用的同步真值源(父级 setState 是同步写;widget.selectionBox
  /// 要等重建才刷新,双写者同帧并发会互相覆盖)。
  final SelectionBox Function()? liveBox;

  /// 编辑态:显示手柄、启用盒手势。false = 纯浏览(全屏 orbit)。
  final bool editing;

  final CloudViewController? controller;

  /// 初始相机(null = 默认取景)。
  final CloudViewCamera? initialCamera;

  /// 相机变化上报(供父页面记住,进编辑页时传下去)。**不要**在回调里
  /// setState —— 每帧手势都会触发。
  final ValueChanged<CloudViewCamera>? onCameraChanged;

  /// 3 floats per point (full set).
  final Float32List xyz;

  /// 3 bytes per point; all-zero → height-ramp grayscale fallback.
  final Uint8List rgb;

  /// L2 渲染门(ghost_view_filter.dart 产出):1 byte/point,0 = 渲染期
  /// 跳过,null = 全显示。RENDER-ONLY —— 只影响 paint / 双击拾取,数据
  /// (xyz/rgb)与取景 fit 永远吃全量,导出路径根本看不到这个数组。
  /// 长度与点数不符时整组忽略(容错,painter 侧核对)。
  final Uint8List? visibility;

  final bool showControls;

  @override
  State<SparseCloudView> createState() => _SparseCloudViewState();
}

// [2026-07-29 用户签决] 所有点云的初始视角 = 骰子"顶"的**正面**(文字朝上)。
// 正俯视下 yaw 是屏幕内旋转:探针实测 yaw=π 时"顶"标签才正立(yaw=0 是
// 倒置)。与 kOrientationPresets['Top'].yaw 同值,点"顶"归位到同一姿态。
const double _kDefaultYaw = math.pi;
const double _kDefaultPitch = -math.pi / 2;
// Near-full pitch: reach straight-up/down (±90°) minus a hair to dodge the
// exact pole singularity. Was clamped to ±1.35 (±77°) — the head-on
// "can't see the top/bottom" dead zone the competitor audit flagged.
const double _kPitchLimit = math.pi / 2 - 0.02;

enum _BoxDrag { none, handle }

class _SparseCloudViewState extends State<SparseCloudView>
    with SingleTickerProviderStateMixin {
  double _yaw = _kDefaultYaw;
  double _pitch = _kDefaultPitch;
  double _roll = 0;
  double _zoom = 1.0;
  double _panX = 0;
  double _panY = 0;
  // Orbit pivot in WORLD space (rotation origin + what the projection
  // centers). Defaults to the fit center; double-tap re-targets it to the
  // tapped surface point (KIRI/Sketchfab-style focus), reframe resets it.
  late List<double> _pivot;
  ui.Image? _sprite; // white disc for drawRawAtlas point sprites
  // Vivid tone-mapped look (2026-07-08): bigger discs + PBR Neutral tone map.
  // Point size doubled 1.0→2.0 (user-requested; raise toward 5.0 for bigger).
  // Tone = PBR Neutral (Khronos, tone=2) + exposure 1.0. The user wants a
  // TONE-MAPPED look like RealityScan's (highlight rolloff, polished) but
  // VIVID. AgX (was tone=0) + exposure 5.0 tone-maps but DELIBERATELY
  // desaturates ("path to white"), washing colors pale; ACES (tone=1)
  // desaturates the same way. Khronos PBR Neutral is the industry tone map
  // built to roll off highlights WITHOUT killing in-gamut saturation (its
  // stated purpose: true-to-life product color). NOT a claim of literal
  // RealityScan-curve parity — RS's curve is closed/undocumented; this is the
  // standard "vivid + tone-mapped" choice. If dim scenes read too dark, raise
  // exposure toward ~1.3 (PBR Neutral rolls off the resulting brights safely).
  // Sliders still adjust live.
  // [SPLAT-RADIUS 2026-07-28 用户判决] 草稿页预览点径 2.67 → 6。
  //
  // 这是"预览/回看"面,诉求与拍摄期(AR)相反:AR 要看清红/黄/绿覆盖分层
  // 所以点必须小(放大到 20 实机判负,分层被糊掉);**预览要的是点糊成
  // 实体面**——RS 的 Review Scan 就是大圆盘。逐档试:20 过猛 → 6 → 4 → 3。
  //
  // 注:这里是**基准**点径,实际绘制已按 1/深度 透视缩放
  // (`scaleA[m] = baseScale * (camDist / depth)`,见 build 路径),
  // 圆盘 sprite + 画家算法深度排序都是既有能力,本次只放开基准值。
  // 纯渲染:点数据/几何/交付/导出零改动。
  final double _pointSize = 3.0; // 20 太猛 → 6 → 4 → 3;曾 2.67(07-12 −1/3)
  final double _exposure = 1.0; // PBR Neutral applies this first
  final int _tone = 2; // PBR Neutral (0=AgX, 1=ACES, 3+=None)

  // Smooth camera transitions (double-tap focus / reframe). Orbit/pinch stay
  // direct for responsiveness; only re-target/reset eases via this ticker.
  late final AnimationController _tween;
  _CamState? _tweenFrom, _tweenTo;
  Size _viewSize = Size.zero;
  double _fitRadius = 1;

  @override
  void initState() {
    super.initState();
    _buildSprite();
    final fit = SparseCloudPainter.fitOf(widget.xyz);
    _fitRadius = fit.radius;
    _pivot = [fit.cx, fit.cy, fit.cz];
    widget.controller?.addListener(_onControllerTarget);
    final cam = widget.initialCamera;
    if (cam != null) {
      _yaw = cam.yaw;
      _pitch = cam.pitch;
      _roll = cam.roll;
      _zoom = cam.zoom;
      _panX = cam.panX;
      _panY = cam.panY;
      _pivot = [cam.pivotX, cam.pivotY, cam.pivotZ];
    }
    _tween = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    )..addListener(_onTween);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _emitCamera();
    });
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onControllerTarget);
    _tween.dispose();
    super.dispose();
  }

  // ── 选区编辑手势(editing=true 时生效)────────────────────────────
  RectHandle? _activeHandle;
  _BoxDrag _boxMode = _BoxDrag.none;
  SelectionBox? _gestureBox;

  CloudProjection _projectionFor(Size size) => CloudCamera(
    yaw: _yaw,
    pitch: _pitch,
    roll: _roll,
    zoom: _zoom,
    panX: _panX,
    panY: _panY,
    pivotX: _pivot[0],
    pivotY: _pivot[1],
    pivotZ: _pivot[2],
    radius: _fitRadius,
    // [2026-07-29 用户签决] 编辑态切正交:RS 2D 矩形手柄与盒投影严格重合。
    // 浏览态保持透视(下方 painter 用 widget.editing 区分)。
    orthographic: widget.editing,
  ).projectionFor(size);

  SelectionBox? get _liveBox =>
      widget.liveBox?.call() ?? _gestureBox ?? widget.selectionBox;

  bool _ignoreGesture = false;

  void _onScaleStart(ScaleStartDetails d) {
    _gestureBox = null;
    _activeHandle = null;
    _boxMode = _BoxDrag.none;
    _ignoreGesture =
        widget.bottomGestureExclusion > 0 &&
        !_viewSize.isEmpty &&
        d.localFocalPoint.dy > _viewSize.height - widget.bottomGestureExclusion;
    if (_ignoreGesture) return;
    if (!widget.editing || _viewSize.isEmpty) return;
    final box = _liveBox;
    if (box == null) return;
    final proj = _projectionFor(_viewSize);
    final basis = boxScreenBasis(proj, box);
    final rect = selectionScreenRect(basis, box);
    final h = hitRectHandle(rect, d.localFocalPoint);
    if (h != null) {
      // 只有手柄接管手势,且只改尺寸 —— 框内空白拖动交给相机(转视角)。
      _activeHandle = h;
      _boxMode = _BoxDrag.handle;
    }
    _gestureBox = box;
  }

  /// 返回 true 表示这次手势归盒所有(相机不动)。
  bool _handleBoxGesture(ScaleUpdateDetails d) {
    if (_ignoreGesture) return true; // 手势属于工具面板,相机与盒都不动
    if (!widget.editing || d.pointerCount >= 2) return false;
    if (_boxMode == _BoxDrag.none) return false;
    final box = _liveBox;
    final cb = widget.onBoxChanged;
    if (box == null || cb == null || _viewSize.isEmpty) return false;
    final proj = _projectionFor(_viewSize);
    final SelectionBox next;
    if (_activeHandle != null) {
      next = applyRectHandleDrag(
        box: box,
        basis: boxScreenBasis(proj, box),
        h: _activeHandle!,
        screenDelta: d.focalPointDelta,
        minHalfSize: _fitRadius * SelectionBox.kMinHalfSizeFraction,
      );
    } else {
      return false;
    }
    _gestureBox = next;
    cb(next);
    return true;
  }

  void _onControllerTarget() {
    if (widget.controller?.takeReframe() ?? false) {
      if (mounted) _reframe();
      return;
    }
    final t = widget.controller?.takeTarget();
    if (t == null || !mounted) return;
    setState(() {
      _yaw = t.yaw;
      _pitch = t.pitch;
      _roll = t.roll;
      _zoom = t.zoom;
      _panX = t.panX;
      _panY = t.panY;
      _pivot = [t.pivotX, t.pivotY, t.pivotZ];
    });
    _emitCamera();
  }

  void _emitCamera() {
    widget.onCameraChanged?.call((
      yaw: _yaw,
      pitch: _pitch,
      roll: _roll,
      zoom: _zoom,
      panX: _panX,
      panY: _panY,
      pivotX: _pivot[0],
      pivotY: _pivot[1],
      pivotZ: _pivot[2],
    ));
  }

  void _onTween() {
    final a = _tweenFrom, b = _tweenTo;
    if (a == null || b == null) return;
    final t = Curves.easeOutCubic.transform(_tween.value);
    setState(() {
      _pivot = [
        a.pivot[0] + (b.pivot[0] - a.pivot[0]) * t,
        a.pivot[1] + (b.pivot[1] - a.pivot[1]) * t,
        a.pivot[2] + (b.pivot[2] - a.pivot[2]) * t,
      ];
      _panX = a.panX + (b.panX - a.panX) * t;
      _panY = a.panY + (b.panY - a.panY) * t;
      _zoom = a.zoom + (b.zoom - a.zoom) * t;
      _yaw = a.yaw + (b.yaw - a.yaw) * t;
      _pitch = a.pitch + (b.pitch - a.pitch) * t;
    });
    _emitCamera();
  }

  void _animateTo(_CamState to) {
    _tweenFrom = _CamState(
      pivot: List<double>.from(_pivot),
      panX: _panX,
      panY: _panY,
      zoom: _zoom,
      yaw: _yaw,
      pitch: _pitch,
    );
    _tweenTo = to;
    _tween
      ..reset()
      ..forward();
  }

  /// Double-tap → re-target the orbit pivot to the tapped surface point and
  /// recenter it (pan→0), so it becomes the rotation center you can then
  /// orbit/zoom around. Picks the front-most point within a screen radius of
  /// the tap; falls back to the globally closest projected point.
  void _focusAt(Offset tap) {
    if (_viewSize.isEmpty || widget.xyz.isEmpty) return;
    final world = SparseCloudPainter.pointAtScreen(
      xyz: widget.xyz,
      tap: tap,
      size: _viewSize,
      yaw: _yaw,
      pitch: _pitch,
      zoom: _zoom,
      panX: _panX,
      panY: _panY,
      pivot: _pivot,
      // 渲染门隐藏的点不该被双击对焦锁定(用户看不见它)。
      visibility: widget.visibility,
    );
    if (world == null) return;
    _animateTo(
      _CamState(
        pivot: world,
        panX: 0,
        panY: 0,
        zoom: _zoom,
        yaw: _yaw,
        pitch: _pitch,
      ),
    );
  }

  /// Reframe safety net — pivot back to the fit center, undo pan/zoom, return
  /// to the opening angle. Mandatory once free pan + movable pivot exist
  /// (model-viewer's warning: give the user a way back to the framing).
  void _reframe() {
    final fit = SparseCloudPainter.fitOf(widget.xyz);
    _animateTo(
      _CamState(
        pivot: [fit.cx, fit.cy, fit.cz],
        panX: 0,
        panY: 0,
        zoom: 1.0,
        yaw: _kDefaultYaw,
        pitch: _kDefaultPitch,
      ),
    );
  }

  /// 16×16 anti-aliased white disc — drawRawAtlas modulates it with each
  /// point's EXACT color (no palette quantization; the 4×4×4 palette used
  /// to shatter subtle warm/cool neutrals into saturated pastel speckle —
  /// the 2026-07-06 "五彩斑斓" bug).
  Future<void> _buildSprite() async {
    final rec = ui.PictureRecorder();
    final c = Canvas(rec);
    c.drawCircle(
      const Offset(8, 8),
      7,
      Paint()
        ..color = Colors.white
        ..isAntiAlias = true,
    );
    final img = await rec.endRecording().toImage(16, 16);
    if (mounted) setState(() => _sprite = img);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              _viewSize = constraints.biggest;
              return GestureDetector(
                onScaleStart: _onScaleStart,
                onScaleUpdate: (d) {
                  if (_tween.isAnimating) return; // don't fight a transition
                  // 编辑态:命中手柄/落在盒轮廓内的单指手势归盒所有,
                  // 相机不动。
                  if (_handleBoxGesture(d)) return;
                  setState(() {
                    if (d.pointerCount >= 2) {
                      // Two-finger drag = pan; pinch = zoom (dolly-in range
                      // widened so movable-pivot focus can push into corners).
                      _panX += d.focalPointDelta.dx;
                      _panY += d.focalPointDelta.dy;
                      if (d.scale != 1.0) {
                        _zoom = (_zoom * (1 + (d.scale - 1) * 0.08)).clamp(
                          0.15,
                          20.0,
                        );
                      }
                    } else if (!widget.editing) {
                      // Yaw sign negated to match the un-mirrored projection
                      // (screen-X flipped in the painter) — keeps "drag right
                      // → scene turns right" intuitive. Pitch now reaches the
                      // poles (±89°) instead of the old ±77° dead zone.
                      //
                      // [2026-07-30 用户签决] "完全复刻 RS,点云只能固定六个
                      // 面动" ⇒ **编辑态没有自由 orbit**,换面只能走骰子的四
                      // 个箭头或点骰子的面。浏览态不受影响(照旧自由转)。
                      // 双指 pan/zoom 两态都保留。
                      _yaw -= d.focalPointDelta.dx * 0.008;
                      _pitch = (_pitch + d.focalPointDelta.dy * 0.006).clamp(
                        -_kPitchLimit,
                        _kPitchLimit,
                      );
                    }
                  });
                  _emitCamera();
                },
                onScaleEnd: (_) {
                  _activeHandle = null;
                  _boxMode = _BoxDrag.none;
                  _gestureBox = null;
                },
                onDoubleTapDown: (d) => _focusAt(d.localPosition),
                child: RepaintBoundary(
                  child: Container(
                    color: const Color(0xFF1A1A1A), // scene.background
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: SparseCloudPainter(
                              xyz: widget.xyz,
                              rgb: widget.rgb,
                              visibility: widget.visibility,
                              sprite: _sprite,
                              yaw: _yaw,
                              pitch: _pitch,
                              roll: _roll,
                              zoom: _zoom,
                              panX: _panX,
                              panY: _panY,
                              pivotX: _pivot[0],
                              pivotY: _pivot[1],
                              pivotZ: _pivot[2],
                              pointSize: _pointSize,
                              exposure: _exposure,
                              tone: _tone,
                              selectionBox: widget.selectionBox,
                              // [2026-07-29 回退 2D 框] 编辑态不画 3D 线框
                              // (由 RS 2D 矩形手柄代替);框外点变红保留。
                              // painter 与手柄同用正交 ⇒ 红点判定与矩形严格
                              // 重合(RS 观感)。
                              drawSelectionWireframe: false,
                              orthographic: widget.editing,
                            ),
                            size: Size.infinite,
                          ),
                        ),
                        if (widget.editing && widget.selectionBox != null)
                          Positioned.fill(
                            child: CustomPaint(
                              painter: RectHandlesPainter(
                                rect: selectionScreenRect(
                                  boxScreenBasis(
                                    _projectionFor(_viewSize),
                                    widget.selectionBox!,
                                  ),
                                  widget.selectionBox!,
                                ),
                              ),
                              size: Size.infinite,
                            ),
                          ),
                        // Reframe safety net (top-right).
                        Positioned(
                          top: 10,
                          right: 10,
                          child: _RoundIconButton(
                            icon: Icons.filter_center_focus,
                            onTap: _reframe,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        // Adjustment strip removed 2026-07-06 (user-locked): point size, tone
        // (AgX), exposure stay at their defaults — a clean full-bleed cloud
        // with no controls to fiddle with. Defaults live in the state fields.
      ],
    );
  }
}

// ─── painter ─────────────────────────────────────────────────────────

class SparseCloudPainter extends CustomPainter {
  SparseCloudPainter({
    required this.xyz,
    required this.rgb,
    this.visibility,
    required this.sprite,
    required this.yaw,
    required this.pitch,
    required this.zoom,
    required this.panX,
    required this.panY,
    required this.pivotX,
    required this.pivotY,
    required this.pivotZ,
    required this.pointSize,
    required this.exposure,
    required this.tone,
    this.selectionBox,
    this.drawSelectionWireframe = true,
    this.orthographic = false,
    this.roll = 0,
  });

  final Float32List xyz;
  final Uint8List rgb;

  /// L2 渲染门:1 byte/point,0 = 不进渲染 buffer(见 SparseCloudView 同名
  /// 字段)。null 或长度不符 = 全显示。
  final Uint8List? visibility;
  final ui.Image? sprite;
  final double yaw;
  final double pitch;
  final double zoom;
  final double panX;
  final double panY;
  // Orbit pivot (rotation origin) in world space. Defaults to the fit
  // center; double-tap re-targets it, reframe resets it.
  final double pivotX;
  final double pivotY;
  final double pivotZ;
  final double pointSize;
  final double exposure;
  final int tone; // 0=AgX, 1=ACES, 2=无 — three.js TONEMAPS parity

  /// 只读选区回显(见 SparseCloudView 同名字段):null = 无选区,不改渲染。
  final SelectionBox? selectionBox;

  /// 是否画选区 3D 线框(8 角连边)。默认 true(草稿只读回显用)。
  /// SelectionCloudView(选区编辑页,Task 4)传 false —— 编辑页要框外红点,
  /// 但用自己的 2D 屏幕矩形手柄层,不要这条 3D 线框(会和手柄矩形叠加冗余)。
  final bool drawSelectionWireframe;

  /// 正交投影(选区编辑视图专用;见 CloudCamera.orthographic)。查看器
  /// 保持透视(false)。
  final bool orthographic;

  /// 屏幕滚转(过极翻面动画专用;见 CloudCamera.roll)。roll==0 时热循环
  /// 零开销跳过,查看器路径逐位不变。
  final double roll;

  // ── Color pipeline: VERBATIM port of the desktop viewer_ab.html chain ──
  // PLY sRGB bytes → exact sRGB EOTF decode (their S2L table) →
  // three.js r160 tone mapping (AgX / ACESFilmic / None, exposure applied
  // in linear light exactly where three.js applies it) → sRGB OETF encode.

  static double _srgbDecode(int b) {
    final c = b / 255.0;
    return c <= 0.04045
        ? c / 12.92
        : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
  }

  static int _srgbEncode(double c) {
    final v = c.clamp(0.0, 1.0);
    final e = v <= 0.0031308
        ? v * 12.92
        : 1.055 * math.pow(v, 1 / 2.4).toDouble() - 0.055;
    return (e.clamp(0.0, 1.0) * 255).round();
  }

  /// three.js r160 AgXToneMapping, matrices verbatim (GLSL mat3 columns
  /// expanded to row form). In/out: Linear-sRGB.
  static List<double> _agx(double r, double g, double b, double exposure) {
    r *= exposure;
    g *= exposure;
    b *= exposure;
    // LINEAR_SRGB_TO_LINEAR_REC2020
    var x = 0.6274 * r + 0.3293 * g + 0.0433 * b;
    var y = 0.0691 * r + 0.9195 * g + 0.0113 * b;
    var z = 0.0164 * r + 0.0880 * g + 0.8956 * b;
    // AgXInsetMatrix
    final ix =
        0.856627153315983 * x + 0.0951212405381588 * y + 0.0482516061458583 * z;
    final iy =
        0.137318972929847 * x + 0.761241990602591 * y + 0.101439036467562 * z;
    final iz =
        0.11189821299995 * x + 0.0767994186031903 * y + 0.811302368396859 * z;
    // Log2 encoding between AgxMinEv/AgxMaxEv, then 6th-order sigmoid.
    const minEv = -12.47393, maxEv = 4.026069;
    double enc(double v) {
      v = math.max(v, 1e-10);
      v = (math.log(v) / math.ln2 - minEv) / (maxEv - minEv);
      v = v.clamp(0.0, 1.0);
      final v2 = v * v;
      final v4 = v2 * v2;
      return 15.5 * v4 * v2 -
          40.14 * v4 * v +
          31.96 * v4 -
          6.868 * v2 * v +
          0.4298 * v2 +
          0.1191 * v -
          0.00232;
    }

    x = enc(ix);
    y = enc(iy);
    z = enc(iz);
    // AgXOutsetMatrix
    var or_ =
        1.1271005818144368 * x -
        0.11060664309660323 * y -
        0.016493938717834573 * z;
    var og =
        -0.1413297634984383 * x +
        1.157823702216272 * y -
        0.016493938717834257 * z;
    var ob =
        -0.14132976349843826 * x -
        0.11060664309660294 * y +
        1.2519364065950405 * z;
    // Linearize — the sigmoid output is 2.2-gamma encoded; three.js r160:
    //   color = pow( max( vec3(0.0), color ), vec3(2.2) );
    // Omitting this line was the 2026-07-06 "全浅色" washout: gamma-space
    // values got re-encoded by the output OETF (double brightening).
    or_ = math.pow(math.max(0.0, or_), 2.2).toDouble();
    og = math.pow(math.max(0.0, og), 2.2).toDouble();
    ob = math.pow(math.max(0.0, ob), 2.2).toDouble();
    // LINEAR_REC2020_TO_LINEAR_SRGB (renderer's output OETF clamps)
    return [
      (1.6605 * or_ - 0.5876 * og - 0.0728 * ob).clamp(0.0, 1.0),
      (-0.1246 * or_ + 1.1329 * og - 0.0083 * ob).clamp(0.0, 1.0),
      (-0.0182 * or_ - 0.1006 * og + 1.1187 * ob).clamp(0.0, 1.0),
    ];
  }

  /// three.js ACESFilmicToneMapping, verbatim.
  static List<double> _aces(double r, double g, double b, double exposure) {
    final e = exposure / 0.6;
    r *= e;
    g *= e;
    b *= e;
    var x = 0.59719 * r + 0.35458 * g + 0.04823 * b;
    var y = 0.07600 * r + 0.90834 * g + 0.01566 * b;
    var z = 0.02840 * r + 0.13383 * g + 0.83777 * b;
    double fit(double v) =>
        (v * (v + 0.0245786) - 0.000090537) /
        (v * (0.983729 * v + 0.4329510) + 0.238081);
    x = fit(x);
    y = fit(y);
    z = fit(z);
    return [
      (1.60475 * x - 0.53108 * y - 0.07367 * z).clamp(0.0, 1.0),
      (-0.10208 * x + 1.10813 * y - 0.00605 * z).clamp(0.0, 1.0),
      (-0.00327 * x - 0.07276 * y + 1.07602 * z).clamp(0.0, 1.0),
    ];
  }

  /// Khronos PBR Neutral tone mapper — three.js `NeutralToneMapping`, constants
  /// verified against KhronosGroup/ToneMapping (StartCompression 0.76,
  /// Desaturation 0.15). A filmic tone map that rolls off highlights (graceful
  /// "path to white") while PRESERVING in-gamut saturation — built precisely to
  /// fix the AgX/ACES desaturation that washed our colors. In/out: Linear-sRGB;
  /// exposure applied first (matches three.js `color *= toneMappingExposure`).
  static List<double> _pbrNeutral(
    double r,
    double g,
    double b,
    double exposure,
  ) {
    const startCompression = 0.8 - 0.04; // 0.76
    const desaturation = 0.15;
    r *= exposure;
    g *= exposure;
    b *= exposure;
    final x = math.min(r, math.min(g, b));
    final offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
    r -= offset;
    g -= offset;
    b -= offset;
    final peak = math.max(r, math.max(g, b));
    if (peak < startCompression) return [r, g, b];
    const d = 1.0 - startCompression;
    final newPeak = 1.0 - d * d / (peak + d - startCompression);
    final s = newPeak / peak;
    r *= s;
    g *= s;
    b *= s;
    // mix(color, vec3(newPeak), gg): desaturate bright peaks toward white.
    final gg = 1.0 - 1.0 / (desaturation * (peak - newPeak) + 1.0);
    return [
      r + (newPeak - r) * gg,
      g + (newPeak - g) * gg,
      b + (newPeak - b) * gg,
    ];
  }

  // Per-point display colors, cached on (cloud, exposure, tone) — colors
  // don't change while orbiting, so the full 3-channel pipeline runs only
  // when a slider moves, never per frame.
  static Uint8List? _ccRgbKey;
  static Float32List? _ccXyzKey;
  static double _ccExposure = -1;
  static int _ccTone = -1;
  static Int32List? _ccColors;

  Int32List _displayColors(bool hasColor) {
    if (identical(_ccRgbKey, rgb) &&
        identical(_ccXyzKey, xyz) &&
        _ccExposure == exposure &&
        _ccTone == tone &&
        _ccColors != null) {
      return _ccColors!;
    }
    final n = xyz.length ~/ 3;
    final out = Int32List(n);
    for (var i = 0; i < n; i++) {
      double lr, lg, lb;
      if (hasColor && i * 3 + 2 < rgb.length) {
        lr = _srgbDecode(rgb[i * 3]);
        lg = _srgbDecode(rgb[i * 3 + 1]);
        lb = _srgbDecode(rgb[i * 3 + 2]);
      } else {
        // Height-ramp gray fallback (uncolored clouds).
        final t = ((xyz[i * 3 + 1] - _minY) * _invYSpan).clamp(0.0, 1.0);
        final lum = _srgbDecode((120 + t * 135).round().clamp(0, 255));
        lr = lum;
        lg = lum;
        lb = lum;
      }
      List<double> m;
      switch (tone) {
        case 0:
          m = _agx(lr, lg, lb, exposure);
        case 1:
          m = _aces(lr, lg, lb, exposure);
        case 2:
          m = _pbrNeutral(lr, lg, lb, exposure);
        default:
          m = [
            (lr * exposure).clamp(0.0, 1.0),
            (lg * exposure).clamp(0.0, 1.0),
            (lb * exposure).clamp(0.0, 1.0),
          ];
      }
      out[i] =
          0xFF000000 |
          (_srgbEncode(m[0]) << 16) |
          (_srgbEncode(m[1]) << 8) |
          _srgbEncode(m[2]);
    }
    _ccRgbKey = rgb;
    _ccXyzKey = xyz;
    _ccExposure = exposure;
    _ccTone = tone;
    _ccColors = out;
    return out;
  }

  // Fit-cache keyed by the cloud identity (recomputed on swap-in).
  static Float32List? _cachedXyz;
  static double _cx = 0, _cy = 0, _cz = 0, _radius = 1;
  static double _minY = 0, _invYSpan = 1;

  // Opening-view fill factor. f = half·K·zoom is CONSTANT (NOT /radius): the
  // scale lives only in camDist = radius·3.2, so vx = x1·f/depth is
  // scale-INVARIANT — a 2 m room and a 20 m hall both fill the same fraction.
  // (The old f = half·4.0/radius double-counted radius → scene shrank as the
  // cloud grew, and looked tiny here.) K=2.6 puts the 99.5th-pct radius at
  // ~0.78 × half-short-side (measured), i.e. ~20% margin — user-locked
  // 2026-07-06. Kept in ONE place: paint() and pointAtScreen() must project
  // identically or double-tap picking drifts.
  // Public (not `_`-private): CloudCamera's own default `fillK` (2.6, in
  // cloud_camera.dart) is a second, hand-synced literal copy of this same
  // constant — the two could silently drift and mis-scale the selection
  // page's handle rectangles. They stay two literals (CloudCamera can't
  // import this file without a cycle: this file already imports
  // cloud_camera.dart), but exposing this one lets
  // test/cloud_camera_test.dart assert `CloudCamera(...).fillK ==
  // SparseCloudPainter.fitFillK` as a runtime drift guard.
  static const double fitFillK = kFitFillK;

  /// Ensures the fit cache (center + radius) for [xyz] and returns it — the
  /// widget uses this to seed / reset the orbit pivot without re-deriving the
  /// robust fit itself.
  static ({double cx, double cy, double cz, double radius}) fitOf(
    Float32List xyz,
  ) {
    _ensureFit(xyz);
    return (cx: _cx, cy: _cy, cz: _cz, radius: _radius);
  }

  /// 旧名。行为已随 [sceneAabbOf] 升级(飞点不再撑大框)—— 保留别名是为了
  /// 不去动别的 agent 正在改的调用点文件。
  static ({double cx, double cy, double cz, double hx, double hy, double hz})
  aabbOf(Float32List xyz) => sceneAabbOf(xyz);

  /// 点云**场景本体**的轴对齐包围盒(中心 + 半边长),外围飞点不计入。
  ///
  /// [2026-07-29 用户签决] "初始 3D 框只包括场景,外围的浮点噪点直接在框外"。
  ///
  /// 判据 = 每轴 [P0.5, P99.5] 分位(与 fitOf 的 99.5 分位半径同口径):
  /// 最外 1% 留在框外,其余全部包住。
  ///
  /// ⚠️ 不要改回 median ± k·MAD:MAD 是**中位**绝对偏差,点云一旦是"密集
  /// 核心 + 稀疏外围"(床垫上万点、床架与地板几千点),MAD 就被核心压得
  /// 极小,8·MAD 只框得住核心,床架/地板整片被判到框外 —— 用户实机指认
  /// "一打开删了这么多"。分位不受密度分布影响,才是这里正确的统计量。
  ///
  /// 渲染仍是全量点(框外只变红,不删任何点;PLY 永不因此改写)。
  static ({double cx, double cy, double cz, double hx, double hy, double hz})
  sceneAabbOf(Float32List xyz) {
    final n = xyz.length ~/ 3;
    if (n == 0) {
      return (cx: 0, cy: 0, cz: 0, hx: 0.5, hy: 0.5, hz: 0.5);
    }
    final xs = Float64List(n), ys = Float64List(n), zs = Float64List(n);
    for (var i = 0; i < n; i++) {
      xs[i] = xyz[i * 3];
      ys[i] = xyz[i * 3 + 1];
      zs[i] = xyz[i * 3 + 2];
    }
    (double, double) span(Float64List a) {
      final b = a.toList()..sort();
      final lo = b[(b.length * 0.005).floor().clamp(0, b.length - 1)];
      final hi = b[(b.length * 0.995).ceil().clamp(0, b.length - 1)];
      return (lo, hi);
    }

    final (x0, x1) = span(xs);
    final (y0, y1) = span(ys);
    final (z0, z1) = span(zs);
    return (
      cx: (x0 + x1) / 2,
      cy: (y0 + y1) / 2,
      cz: (z0 + z1) / 2,
      hx: math.max((x1 - x0) / 2, 1e-4),
      hy: math.max((y1 - y0) / 2, 1e-4),
      hz: math.max((z1 - z0) / 2, 1e-4),
    );
  }

  /// Nearest surface point to a screen tap, in world coords (double-tap
  /// focus). No depth buffer, so we replicate the exact paint projection and
  /// pick the FRONT-MOST point within a screen radius of the tap; if nothing
  /// is within radius, the globally closest projected point. Returns null on
  /// an empty cloud. Kept bit-identical to [paint]'s transform.
  static List<double>? pointAtScreen({
    required Float32List xyz,
    required Offset tap,
    required Size size,
    required double yaw,
    required double pitch,
    required double zoom,
    required double panX,
    required double panY,
    required List<double> pivot,
    Uint8List? visibility,
  }) {
    if (xyz.isEmpty || size.isEmpty) return null;
    _ensureFit(xyz);
    final n = xyz.length ~/ 3;
    // 渲染门对齐:被隐藏的点不参与拾取(与 paint 同一容错——长度不符整组忽略)。
    final vis = visibility != null && visibility.length == n
        ? visibility
        : null;
    final proj = CloudCamera(
      yaw: yaw,
      pitch: pitch,
      zoom: zoom,
      panX: panX,
      panY: panY,
      pivotX: pivot[0],
      pivotY: pivot[1],
      pivotZ: pivot[2],
      radius: _radius,
      fillK: fitFillK,
    ).projectionFor(size);
    final cosY = proj.cosY, sinY = proj.sinY;
    final cosP = proj.cosP, sinP = proj.sinP;
    final f = proj.f, camDist = proj.camDist, ox = proj.ox, oy = proj.oy;
    const rPx = 44.0; // tap tolerance
    var bestInRadiusDepth = double.infinity;
    var bestInRadiusIdx = -1;
    var bestAnyD2 = double.infinity;
    var bestAnyIdx = -1;
    for (var i = 0; i < n; i++) {
      if (vis != null && vis[i] == 0) continue; // L2 渲染门:不可见不可拾取
      final px = xyz[i * 3] - pivot[0];
      final py = xyz[i * 3 + 1] - pivot[1];
      final pz = xyz[i * 3 + 2] - pivot[2];
      final x1 = px * cosY + pz * sinY;
      final z1 = -px * sinY + pz * cosY;
      final y2 = py * cosP - z1 * sinP;
      final z2 = py * sinP + z1 * cosP;
      final depth = z2 + camDist;
      if (depth <= _radius * 0.02) continue;
      final vx = ox - x1 * f / depth;
      final vy = oy - y2 * f / depth;
      final dx = vx - tap.dx, dy = vy - tap.dy;
      final d2 = dx * dx + dy * dy;
      if (d2 < bestAnyD2) {
        bestAnyD2 = d2;
        bestAnyIdx = i;
      }
      if (d2 <= rPx * rPx && depth < bestInRadiusDepth) {
        bestInRadiusDepth = depth;
        bestInRadiusIdx = i;
      }
    }
    final idx = bestInRadiusIdx >= 0 ? bestInRadiusIdx : bestAnyIdx;
    if (idx < 0) return null;
    return [xyz[idx * 3], xyz[idx * 3 + 1], xyz[idx * 3 + 2]];
  }

  static void _ensureFit(Float32List xyz) {
    if (identical(xyz, _cachedXyz) || xyz.isEmpty) return;
    _cachedXyz = xyz;
    final n = xyz.length ~/ 3;
    // VERBATIM desktop-viewer fit (viewer_ab.html): median ± 8·MAD inlier
    // mask → center = inlier mean, radius = 97th-percentile inlier
    // distance. Fit is inlier-based but RENDERING shows every point.
    final xs = Float64List(n), ys = Float64List(n), zs = Float64List(n);
    for (var i = 0; i < n; i++) {
      xs[i] = xyz[i * 3];
      ys[i] = xyz[i * 3 + 1];
      zs[i] = xyz[i * 3 + 2];
    }
    double med(Float64List a) {
      final b = a.toList()..sort();
      return b[b.length >> 1];
    }

    double mad(Float64List a, double m) {
      final b = [for (final v in a) (v - m).abs()]..sort();
      final r = b[b.length >> 1];
      return r == 0 ? 1 : r;
    }

    final mx = med(xs), myv = med(ys), mz = med(zs);
    final kx = 8 * mad(xs, mx), ky = 8 * mad(ys, myv), kz = 8 * mad(zs, mz);
    var sx = 0.0, sy = 0.0, sz = 0.0;
    var cnt = 0;
    for (var i = 0; i < n; i++) {
      if ((xs[i] - mx).abs() > kx ||
          (ys[i] - myv).abs() > ky ||
          (zs[i] - mz).abs() > kz) {
        continue;
      }
      sx += xs[i];
      sy += ys[i];
      sz += zs[i];
      cnt++;
    }
    _cx = cnt > 0 ? sx / cnt : mx;
    _cy = cnt > 0 ? sy / cnt : myv;
    _cz = cnt > 0 ? sz / cnt : mz;
    // Contain radius over ALL delivered points (not just inliers): the
    // opening view MUST show the whole scene regardless of size. The 99.5th
    // percentile drops only the ~0.5% most-distant points — the sparse SfM
    // strays that would otherwise shrink the whole scene to a dot — while
    // keeping every real surface (dense, so far walls sit well below 99.5%).
    // Paired with the 20%-margin framing constant (fitFillK) and a SPHERE
    // fit, this guarantees full visibility at ANY orbit angle. Full set still
    // renders; a zoom-out reveals the dropped strays.
    final dd = <double>[];
    for (var i = 0; i < n; i++) {
      final dx = xs[i] - _cx, dy = ys[i] - _cy, dz = zs[i] - _cz;
      dd.add(math.sqrt(dx * dx + dy * dy + dz * dz));
    }
    dd.sort();
    _radius = dd.isEmpty
        ? 1
        : math.max(
            1e-6,
            dd[(dd.length * 0.995).floor().clamp(0, dd.length - 1)],
          );
    // Height ramp domain for uncolored clouds.
    final ysSorted = ys.toList()..sort();
    _minY = ysSorted[(ysSorted.length * 0.05).floor()];
    final ySpan =
        ysSorted[(ysSorted.length * 0.95).floor().clamp(
          0,
          ysSorted.length - 1,
        )] -
        _minY;
    _invYSpan = ySpan.abs() < 1e-9 ? 1 : 1 / ySpan;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final spr = sprite;
    if (xyz.isEmpty || size.isEmpty || spr == null) return;
    _ensureFit(xyz);

    final n = xyz.length ~/ 3;
    // Review is the authoritative visual inspection surface. It must render
    // every persisted PLY point; Capture AR owns the separate dynamic LOD.
    final stride = ReviewPointCloudPolicy.drawStrideFor(n);
    // L2 渲染门(默认 null = 全显示):被标记的点不进渲染 buffer。
    // 长度不符 = mask 与当前点序错位 → 整组忽略(容错,绝不隐藏错点)。
    // 取景 fit(_ensureFit)刻意仍吃全量:开关翻转不得改变取景/尺度。
    final vis = visibility != null && visibility!.length == n
        ? visibility
        : null;
    // Scale-invariant fit: constant focal (f = half·K·zoom), scale only in
    // camDist = radius·3.2. Fills the 99.5th-pct radius to ~0.78·half (see
    // fitFillK). Sphere fit → whole scene stays framed at any orbit angle.
    final proj = CloudCamera(
      yaw: yaw,
      pitch: pitch,
      zoom: zoom,
      panX: panX,
      panY: panY,
      pivotX: pivotX,
      pivotY: pivotY,
      pivotZ: pivotZ,
      radius: _radius,
      fillK: fitFillK,
      orthographic: orthographic,
      roll: roll,
    ).projectionFor(size);
    final cosY = proj.cosY, sinY = proj.sinY;
    final cosP = proj.cosP, sinP = proj.sinP;
    final f = proj.f, camDist = proj.camDist, ox = proj.ox, oy = proj.oy;
    final ortho = proj.orthographic;
    final cosR = proj.cosR, sinR = proj.sinR;
    final hasRoll = !(sinR == 0.0 && cosR == 1.0);

    var hasColor = false;
    for (var i = 0; i < rgb.length; i += 3 * math.max(1, stride)) {
      if (rgb[i] != 0 || rgb[i + 1] != 0 || rgb[i + 2] != 0) {
        hasColor = true;
        break;
      }
    }
    final displayColors = _displayColors(hasColor);

    // drawRawAtlas: ONE call renders every point with its EXACT tone-mapped
    // color (white disc sprite × per-instance modulate color). Like the
    // desktop viewer, ALL points render (fit is inlier-based, rendering is
    // not culled), point size attenuates with distance
    // (PointsMaterial sizeAttenuation:true), and — matching WebGL's depth
    // buffer — instances are drawn FAR→NEAR so near (often dark, object)
    // points correctly occlude far (often bright, wall) points instead of
    // being buried under them at large point sizes.
    final maxOut = (n + stride - 1) ~/ stride;
    final vxA = Float32List(maxOut);
    final vyA = Float32List(maxOut);
    final scaleA = Float32List(maxOut);
    final depthA = Float32List(maxOut);
    final colorA = Int32List(maxOut);
    final baseScale = pointSize / 16.0;
    var m = 0;

    for (var i = 0; i < n; i += stride) {
      if (vis != null && vis[i] == 0) continue; // L2 渲染门:ghost 点不进 buffer
      final wx = xyz[i * 3], wy = xyz[i * 3 + 1], wz = xyz[i * 3 + 2];
      final px = wx - pivotX, py = wy - pivotY, pz = wz - pivotZ;
      // yaw about Y, then pitch about X
      final x1 = px * cosY + pz * sinY;
      final z1 = -px * sinY + pz * cosY;
      final y2 = py * cosP - z1 * sinP;
      final z2 = py * sinP + z1 * cosP;
      final depth = z2 + camDist;
      if (depth <= _radius * 0.02) continue; // behind the eye only
      // Screen-X negated: the rotated world basis (x1,y2,z2) is right-handed,
      // but (right,up,into-screen) is a left-handed visual arrangement — using
      // +x1 as screen-right renders the scene MIRRORED (nightstand jumps to
      // the wrong side). Negating x1 flips "right" so the visual basis is
      // right-handed again, matching the desktop three.js viewer.
      // 除数按投影模式选(与 CloudProjection.project() 同式,parity 测试锁)
      final dd = ortho ? camDist : depth;
      var vx = ox - x1 * f / dd;
      var vy = oy - y2 * f / dd;
      if (hasRoll) {
        final rx = vx - ox, ry = vy - oy;
        vx = ox + rx * cosR - ry * sinR;
        vy = oy + rx * sinR + ry * cosR;
      }
      if (vx < -24 ||
          vx > size.width + 24 ||
          vy < -24 ||
          vy > size.height + 24) {
        continue;
      }
      vxA[m] = vx;
      vyA[m] = vy;
      // sizeAttenuation: point radius scales with 1/depth (unit size at
      // the fitted cloud distance).
      scaleA[m] = ortho ? baseScale : baseScale * (camDist / depth);
      depthA[m] = depth;
      var argb = displayColors[i];
      if (selectionBox != null && !selectionBox!.contains(wx, wy, wz)) {
        argb = kSelectionOutColor; // 框外 → 红(点不消失)
      }
      colorA[m] = argb;
      m++;
    }
    if (m == 0) return;

    // Painter's algorithm: far → near.
    final order = List<int>.generate(m, (i) => i)
      ..sort((a, b) => depthA[b].compareTo(depthA[a]));

    final rst = Float32List(m * 4);
    final rects = Float32List(m * 4);
    final colors = Int32List(m);
    for (var k = 0; k < m; k++) {
      final i = order[k];
      final scale = scaleA[i];
      final anchor = scale * 8.0;
      final o = k * 4;
      rst[o] = scale; // scos (rotation 0)
      rst[o + 1] = 0; // ssin
      rst[o + 2] = vxA[i] - anchor;
      rst[o + 3] = vyA[i] - anchor;
      rects[o] = 0;
      rects[o + 1] = 0;
      rects[o + 2] = 16;
      rects[o + 3] = 16;
      colors[k] = colorA[i];
    }

    canvas.drawRawAtlas(
      spr,
      Float32List.sublistView(rst, 0, m * 4),
      Float32List.sublistView(rects, 0, m * 4),
      Int32List.sublistView(colors, 0, m),
      BlendMode.modulate,
      null,
      Paint()..isAntiAlias = true,
    );

    // 选区框线(只读回显):8 角连边,与点用同一套投影标量。
    final selBox = selectionBox;
    if (selBox != null && drawSelectionWireframe) {
      final corners = selectionBoxCorners(selBox);
      const edges = [
        [0, 1], [2, 3], [4, 5], [6, 7], // x 向边
        [0, 2], [1, 3], [4, 6], [5, 7], // y 向边
        [0, 4], [1, 5], [2, 6], [3, 7], // z 向边
      ];
      final line = Paint()
        ..color = const Color(0xCCFFFFFF)
        ..strokeWidth = 1.4
        ..style = PaintingStyle.stroke;
      for (final e in edges) {
        final a = corners[e[0]], b = corners[e[1]];
        // 用与点同一套标量投影(cosY 等就是循环上方的那批局部变量)
        Offset? proj3(List<double> w) {
          final px = w[0] - pivotX, py = w[1] - pivotY, pz = w[2] - pivotZ;
          final x1 = px * cosY + pz * sinY;
          final z1 = -px * sinY + pz * cosY;
          final y2 = py * cosP - z1 * sinP;
          final z2 = py * sinP + z1 * cosP;
          final depth = z2 + camDist;
          if (depth <= 1e-6) return null;
          final dd = ortho ? camDist : depth;
          var lx = ox - x1 * f / dd;
          var ly = oy - y2 * f / dd;
          if (hasRoll) {
            final rx = lx - ox, ry = ly - oy;
            lx = ox + rx * cosR - ry * sinR;
            ly = oy + rx * sinR + ry * cosR;
          }
          return Offset(lx, ly);
        }

        final pa = proj3(a), pb = proj3(b);
        if (pa != null && pb != null) canvas.drawLine(pa, pb, line);
      }
    }
  }

  @override
  bool shouldRepaint(SparseCloudPainter old) =>
      old.xyz != xyz ||
      old.rgb != rgb ||
      old.visibility != visibility ||
      old.sprite != sprite ||
      old.yaw != yaw ||
      old.pitch != pitch ||
      old.zoom != zoom ||
      old.panX != panX ||
      old.panY != panY ||
      old.pivotX != pivotX ||
      old.pivotY != pivotY ||
      old.pivotZ != pivotZ ||
      old.pointSize != pointSize ||
      old.exposure != exposure ||
      old.tone != tone ||
      old.selectionBox != selectionBox ||
      old.drawSelectionWireframe != drawSelectionWireframe;
}
