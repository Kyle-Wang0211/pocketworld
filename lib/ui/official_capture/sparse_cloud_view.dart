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
import '../../point_cloud_lod/gpu_cloud_layer.dart';
import '../../point_cloud_lod/lod_bridge.dart';
import '../sparse_thumbnail.dart' show kSparseThumbPitch, kSparseThumbYaw;
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

/// [LIVE-WAIT 2026-09-15] A capture-pose start for [SparseCloudView].
///
/// The rig reproduces a real pinhole camera: eye = pivot − camDist·forward
/// with the pivot on the capture camera's optical axis (Potree View.getPivot,
/// src/viewer/View.js L73-75: pivot = position + direction·radius), so the
/// eye sits at the capture camera centre; [f]/[ox]/[oy] are the AR viewport's
/// pinhole in the cloud view's own pixel coordinates (top-left origin), which
/// the view turns into zoom/pan once it knows its size. Built by
/// capturePoseToRig() in capture_pose_camera.dart.
class PerspectiveStart {
  const PerspectiveStart({
    required this.yaw,
    required this.pitch,
    required this.roll,
    required this.pivotX,
    required this.pivotY,
    required this.pivotZ,
    required this.camDist,
    required this.f,
    required this.ox,
    required this.oy,
  });
  final double yaw, pitch, roll;
  final double pivotX, pivotY, pivotZ;

  /// Eye distance from the pivot along the view axis (world units).
  final double camDist;

  /// Pixel focal length and principal point (absolute px in the view).
  final double f, ox, oy;
}

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

  /// 视角吸附动画期间,选区矩形按**目标**姿态画(不跟中间帧)。
  ///
  /// [2026-08-09 用户实机指认] "切换视角,框不要每次突然变大再缩小,直接变成
  /// 对应角度的大小" —— 立方体在中间角度的投影支撑矩形必然鼓一下,锁定目标
  /// 姿态后矩形直达终态,点云照常转。
  (double yaw, double pitch, double roll)? rectPoseOverride;

  void setRectPoseOverride((double, double, double)? pose) {
    rectPoseOverride = pose;
    notifyListeners();
  }

  bool _browsePose = false;

  /// 请求把**朝向**恢复成浏览态的斜上 45°(退出编辑用)。
  ///
  /// [2026-08-08 用户签决] "如果用户在编辑页面什么都没做,直接点取消了,那就恢复
  /// 到斜上 45 度。如果用户编辑了点云大小,点击完成后,就保留在当前视角。" ——
  /// 所以这个请求只由"取消"发出,"完成"什么都不做。
  ///
  /// 只动朝向,不动 zoom/pan:用户说的是"恢复到斜上 45 度"(角度),把缩放一起
  /// 重置会顺手丢掉他在编辑期捏的远近。要连取景一起回,用 [requestReframe]。
  void requestBrowsePose() {
    _browsePose = true;
    notifyListeners();
  }

  bool takeBrowsePose() {
    final r = _browsePose;
    _browsePose = false;
    return r;
  }
}

/// 环绕 pivot:点云**范围中心**(P0.5–P99.5 中点,与初始 3D 框同源
/// sceneAabbOf),不是 fitOf 的密度中心(median±8MAD 内点均值)。
///
/// [2026-08-09 用户实机指认] "点云模型不是一直都是绕中心点旋转吗,为什么
/// 未命名(2)是围绕着最边的一个点转?转180度,整体在右了。" —— 低视差拍摄
/// 的云沿深度拖出不对称长尾:密度中心贴着密集端,可见整体的中点却在尾巴
/// 中段。绕密度中心转 180°,实测(该 PLY)可见团横跳自身宽度的 61%;绕
/// 范围中心是 0%(转盘感)。fitOf 本体不动 —— 它的 radius(取景)与桌面
/// viewer 逐字对齐,只有"绕哪转"换源。
List<double> orbitPivotOf(Float32List xyz) {
  final a = SparseCloudPainter.sceneAabbOf(xyz);
  return [a.cx, a.cy, a.cz];
}

/// 编辑态取景:初始框每个面看上去都是正方形,点云自适应缩放、沿最长轴
/// 严丝合缝顶住框的两端。
///
/// [2026-08-09 用户签决,当日三轮收敛] "我不需要'正立方体',只需要让用户
/// 每个面看到的初始框是正方形就行。内部的点云可以自适应大小" + "严丝合缝
/// 顶着最上面和最下面的那个点云" + "初始框大小不变,在屏幕中心" ——
/// 几何上"每个面都看着是正方形"⟺ 三边等长,所以:
///   center = 全量 AABB 中心(与框同心 ⇒ 框恒居中于屏幕);
///   框边长 = 2 × max(hx,hy,hz)(全量最长轴,精确贴住该轴两端的点 ——
///            "顶着最上面和最下面";其余轴向点云居中留白);
///   zoom  = fit.radius / 最长半边 ⇒ 框投影恒为标准尺寸,点云自适应缩放。
({List<double> center, double hx, double hy, double hz, double zoom})
editingFrameOf(Float32List xyz) {
  final a = SparseCloudPainter.fullAabbOf(xyz);
  final fit = SparseCloudPainter.fitOf(xyz);
  final hMax = math.max(a.hx, math.max(a.hy, a.hz));
  return (
    center: [a.cx, a.cy, a.cz],
    hx: a.hx,
    hy: a.hy,
    hz: a.hz,
    zoom: fit.radius / math.max(hMax, 1e-6),
  );
}

/// 渐隐带高度:点从"边界上方这么多 px"开始变淡,到边界处为全透明。
/// [2026-08-09 用户实机指认"渐隐的范围x2,现在跟立刻消失没什么区别"] 120 → 240。
const double kCloudBottomFadeBand = 240.0;

/// [2026-08-09 用户实机指认] "点云应该在离滑轴更远一点的距离消失" ——
/// 全透明边界抬到滑轨弧线**上方**这么多 px,不再贴着弧线。
const double kCloudBottomFadeGap = 28.0;

/// 点云视图的投影模式 —— 浏览与编辑**共用**这一个值。
///
/// [2026-07-30 用户签决"点云和投影是同一个"] 两态分别取值会在进出编辑态时
/// 造成肉眼可见的形变(见 _projectionFor 上的注释)。要换回透视就改这一个
/// 常量,但先看清 CloudCamera.orthographic 的注释:选区手柄依赖正交才严格
/// 重合。
const bool kCloudOrthographic = true;

/// Potree's `maxSize` (50 px) over the 16 px point sprite: the largest a
/// perspective-attenuated point may be drawn (PointCloudMaterial.js v1.8.2).
const double kMaxPointSpriteScale = 50.0 / 16.0;

class SparseCloudView extends StatefulWidget {
  const SparseCloudView({
    super.key,
    required this.xyz,
    required this.rgb,
    this.visibility,
    this.showControls = true,
    this.initialCamera,
    this.initialPerspective,
    this.onCameraChanged,
    this.selectionBox,
    this.onBoxChanged,
    this.liveBox,
    this.editing = false,
    this.controller,
    this.bottomGestureExclusion = 0,
    this.bottomFade = 0,
    this.bottomFadeArcRadius = 0,
    this.gpu = false,
    this.octreeDir,
    this.lodBridge,
  });

  /// [LOD v3 2026-09-24, build 171] Draw the points with the GPU viewer (pwlod_viewer.h v3,
  /// lib/point_cloud_lod/gpu_cloud_layer.dart) instead of [SparseCloudPainter]: same camera
  /// (this view's CloudProjection, incl. the LIVE-WAIT morph), same look (pwlod_style from this
  /// view's _pointSize/_exposure/_tone and the painter's height ramp), same selection semantics
  /// (editing ⇒ tint outside, browsing ⇒ cull outside). Gestures, picking, selection editing and
  /// every overlay stay in Dart exactly as before. The CPU painter keeps drawing until the GPU
  /// has published a frame, and again for good if the GPU path fails. User 2026-09-24:
  /// 「查看器我觉得要全程一致」— the capture page and the full-screen viewer pass true; the
  /// gallery card (auto_rotating_cloud_view.dart) keeps false.
  final bool gpu;

  /// With [gpu]: the finished dense cloud's octree (DenseLodCache, Library/Caches/lod/…). When
  /// set, the engine draws the tree (zoom in ⇒ every point) instead of the flat [xyz] sample;
  /// [xyz]/[rgb] still drive the fit, picking and the CPU fallback, so the camera does not move.
  final String? octreeDir;

  /// Test hook for the GPU channel (null = the real `pw_lod_texture` channel).
  final LodBridge? lodBridge;

  /// 底部这么高的区域不接受相机手势 —— 编辑态工具面板压在全屏点云视图
  /// 之上(视图保持全屏才不会在切换时跳),而手势竞技场拦不住:实测拨
  /// 刻度尺时下层仍吃到 8px 位移并把视角转走。位置判定是确定性的。
  final double bottomGestureExclusion;

  /// 屏幕底部渐隐保留带(px),透传给 painter(见 SparseCloudPainter.bottomFade)。
  final double bottomFade;

  /// 渐隐边界的弧半径,透传给 painter(见 SparseCloudPainter.bottomFadeArcRadius)。
  final double bottomFadeArcRadius;

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

  /// [LIVE-WAIT 2026-09-15] 拍摄位姿起始态("关灯了,点云还在原地"):视图以
  /// **透视**投影从拍摄相机的位置/朝向/焦距开画,第一次手势(或进编辑)时
  /// 平滑过渡到本页的正交轨道相机。null = 历史行为逐位不变。
  final PerspectiveStart? initialPerspective;

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

// [2026-08-07 用户签决,学 Polycam] 浏览态初始视角 = **斜上 45°**,与草稿卡片
// 缩略图同一姿态 —— 卡片放大成详情页时角度连续、不跳。
//
// 进**编辑页**时才转到正上方(见 SelectionToolsLayer._alignToTopOnce):选区框
// 的 2D 手柄要求正俯视才与盒的投影严格重合。两者是不同用途的两个视角,不冲突。
//
// yaw 仍取 π(与 kOrientationPresets['Top'] 同侧):探针实测正俯视下 yaw=π 时
// "顶"标签才正立;取同值,45° → 正上方是同一条经线上的连续俯仰,不会横向甩。
const double _kDefaultYaw = kSparseThumbYaw;
const double _kDefaultPitch = kSparseThumbPitch;

/// 编辑态的视角:**正俯视**,与 kOrientationPresets['Top'] 同值。
///
/// [2026-08-07 用户签决] "编辑模式绝对不允许存在这种 45 度的情况" —— 选区的
/// 2D 矩形手柄依赖正交 + 正俯视才与盒的投影严格重合,斜视角下手柄和框会错位。
/// 所以编辑态的初始视角、以及"回到初始"的目标,都必须是这个值。
const double _kEditingPitch = -math.pi / 2;
// Near-full pitch: reach straight-up/down (±90°) minus a hair to dodge the
// exact pole singularity. Was clamped to ±1.35 (±77°) — the head-on
// "can't see the top/bottom" dead zone the competitor audit flagged.
const double _kPitchLimit = math.pi / 2 - 0.02;

enum _BoxDrag { none, handle }

class _SparseCloudViewState extends State<SparseCloudView>
    with TickerProviderStateMixin {
  // [LIVE-WAIT 2026-09-15] capture-pose start state. null/1.0 = the historical
  // rig, bit-identical (see CloudCamera.camDistOverride / orthoMix).
  double? _camDistOverride;
  double _orthoMix = kCloudOrthographic ? 1.0 : 0.0;
  PerspectiveStart? _pendingPerspective;
  late final AnimationController _morph;
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

  /// [LOD v3] The GPU half (null unless widget.gpu). See SparseCloudView.gpu.
  GpuCloudLayer? _gpu;
  GpuCloudSource? _gpuSource;

  @override
  void initState() {
    super.initState();
    _buildSprite();
    final fit = SparseCloudPainter.fitOf(widget.xyz);
    _fitRadius = fit.radius;
    _pivot = orbitPivotOf(widget.xyz);
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
    _pendingPerspective = widget.initialPerspective;
    _tween = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    )..addListener(_onTween);
    _morph = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    )..addListener(_onMorph);
    if (widget.gpu) _attachGpu();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _emitCamera();
    });
  }

  void _attachGpu() {
    _gpu = GpuCloudLayer(bridge: widget.lodBridge)..addListener(_onGpuChanged);
  }

  void _detachGpu() {
    _gpu?..removeListener(_onGpuChanged)..dispose();
    _gpu = null;
    _gpuSource = null;
  }

  void _onGpuChanged() {
    if (mounted) setState(() {});
  }

  /// The GPU layer's texture while it is the one drawing (null ⇒ the CPU painter draws).
  @visibleForTesting
  int? get debugGpuTextureId => _gpu?.textureId;

  @visibleForTesting
  GpuCloudLayer? get debugGpuLayer => _gpu;

  /// The projection this view paints with at its current size (the GPU camera's source).
  @visibleForTesting
  CloudProjection debugProjection() => _projectionFor(_viewSize);

  /// pwlod_style of this view: its own look fields + the painter's height ramp + the selection
  /// mode the painter would use (editing ⇒ tint outside the box, browsing ⇒ cull outside;
  /// drawSelectionWireframe is always false here, as in build()).
  LodStyle _gpuStyle() {
    final ramp = SparseCloudPainter.heightRampOf(widget.xyz);
    final box = widget.selectionBox;
    return LodStyle(
      pointSize: _pointSize,
      spritePx: 16, // SparseCloudPainter sprite edge (_buildSprite: 16×16)
      discRadiusPxAtScale1: 7, // _buildSprite: drawCircle(Offset(8, 8), 7)
      maxSpriteScale: kMaxPointSpriteScale,
      tone: LodTone.values[_tone],
      exposure: _exposure,
      uncoloredMinY: ramp.minY,
      uncoloredInvYSpan: ramp.invYSpan,
      selectionMode: box == null
          ? LodSelectionMode.none
          : (widget.editing ? LodSelectionMode.tintOutside : LodSelectionMode.cullOutside),
      selectionCenter: box == null ? const [0, 0, 0] : [box.cx, box.cy, box.cz],
      selectionSize: box == null ? const [0, 0, 0] : [box.sx, box.sy, box.sz],
      selectionRotRowMajor: box == null ? kIdentityRot : box.rot,
      selectionOutArgb: kSelectionOutColor,
    );
  }

  /// Mirrors this frame's state into the GPU layer (cheap when nothing changed).
  void _syncGpu(Size size, double dpr) {
    final g = _gpu;
    if (g == null || size.isEmpty) return;
    g.setViewport(size, dpr);
    var src = _gpuSource;
    final vis = widget.visibility;
    final n = widget.xyz.length ~/ 3;
    final visOk = vis != null && vis.length == n ? vis : null;
    if (src == null ||
        !identical(src.xyz, widget.xyz) ||
        !identical(src.rgb, widget.rgb) ||
        !identical(src.visibility, visOk) ||
        src.octreeDir != widget.octreeDir) {
      final a = SparseCloudPainter.fullAabbOf(widget.xyz);
      src = _gpuSource = GpuCloudSource(
        xyz: widget.xyz,
        rgb: widget.rgb,
        colored: SparseCloudPainter.hasColorOf(widget.rgb),
        visibility: visOk,
        boxMin: [a.cx - a.hx, a.cy - a.hy, a.cz - a.hz],
        boxMax: [a.cx + a.hx, a.cy + a.hy, a.cz + a.hz],
        octreeDir: widget.octreeDir,
      );
    }
    g.setStyle(_gpuStyle());
    g.setCamera(_projectionFor(size), size);
    g.setSource(src);
  }

  /// 当前俯仰 —— 守门断言"编辑态绝不出现 45°"。
  @visibleForTesting
  double get debugPitch => _pitch;

  /// 当前环绕 pivot —— 守门断言"绕范围中心转,不绕密度中心"。
  @visibleForTesting
  List<double> get debugPivot => List.of(_pivot);

  /// 完整相机快照 —— 守门断言"reframe 保持视角只复位取景"。
  @visibleForTesting
  CloudViewCamera get debugCamera => (
    yaw: _yaw,
    pitch: _pitch,
    roll: _roll,
    zoom: _zoom,
    panX: _panX,
    panY: _panY,
    pivotX: _pivot[0],
    pivotY: _pivot[1],
    pivotZ: _pivot[2],
  );

  @override
  void didUpdateWidget(SparseCloudView old) {
    super.didUpdateWidget(old);
    if (widget.gpu != old.gpu) {
      _detachGpu();
      if (widget.gpu) _attachGpu();
    }
    // [LIVE-WAIT] the cloud is swapped under a live view (white → refined →
    // dense): the fit radius (reframe zoom, handle minimum, near clip) must
    // follow the cloud on screen. The pivot and the user's camera do not move.
    if (!identical(widget.xyz, old.xyz)) {
      _fitRadius = SparseCloudPainter.fitOf(widget.xyz).radius;
    }
    // [LIVE-WAIT] the selection handles assume the orthographic rig.
    if (widget.editing && !old.editing) _beginOrthoMorph();
    // 浏览 → 编辑:立刻把视角拉回正俯视。
    //
    // [2026-08-07 用户签决] "编辑模式绝对不允许存在这种 45 度的情况"。
    // ⚠️ 这是**冗余防御**:实测单独去掉它守门仍绿 —— 工具层的 _alignToTopOnce
    // 已经覆盖了进编辑这条路。保留的理由是它不依赖相机通知的时序(_alignToTopOnce
    // 要等 camera notifier 有值、而且只跑一次)。真凶在 _reframe():那里原先无条件
    // 用浏览态的 _kDefaultPitch,所以"回到初始点云大小"会把视角拽回 45°(退回旧
    // 写法守门立刻红在 −45°)。
    if (widget.editing && !old.editing) {
      _tween.stop(); // 别让进编辑前的取景动画把视角又拽回 45°
      setState(() {
        _pitch = _kEditingPitch;
        // [2026-08-09 用户签决"所有的点云必须在初始框内…可以缩小点云"]
        // 编辑取景:zoom 缩到全部点都落进固定尺寸的初始框,云居中。
        final frame = editingFrameOf(widget.xyz);
        _zoom = frame.zoom;
        _panX = 0;
        _panY = 0;
        // pivot = 全量 AABB 中心(与框同心)⇒ 框投影恒在屏幕中心。
        _pivot = frame.center;
        _roll = 0;
      });
      _emitCamera();
    }
  }

  @override
  void dispose() {
    widget.controller?.removeListener(_onControllerTarget);
    _tween.dispose();
    _morph.dispose();
    _detachGpu();
    super.dispose();
  }

  // ── 选区编辑手势(editing=true 时生效)────────────────────────────
  RectHandle? _activeHandle;
  _BoxDrag _boxMode = _BoxDrag.none;
  SelectionBox? _gestureBox;

  /// 选区矩形专用投影:吸附动画期间锁定目标姿态(见
  /// CloudViewController.rectPoseOverride),其余与 [_projectionFor] 一致。
  CloudProjection _projectionForRect(Size size) {
    final o = widget.controller?.rectPoseOverride;
    if (o == null) return _projectionFor(size);
    return CloudCamera(
      yaw: o.$1,
      pitch: o.$2,
      roll: o.$3,
      zoom: _zoom,
      panX: _panX,
      panY: _panY,
      pivotX: _pivot[0],
      pivotY: _pivot[1],
      pivotZ: _pivot[2],
      radius: _fitRadius,
      orthographic: kCloudOrthographic,
      camDistOverride: _camDistOverride,
      orthoMix: _orthoMix,
    ).projectionFor(size);
  }

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
    camDistOverride: _camDistOverride,
    orthoMix: _orthoMix,
    // [2026-07-30 用户签决] 浏览与编辑用**同一种**投影。
    //
    // 曾经是 `orthographic: widget.editing` —— 07-29 为"框外必须全红"给编辑态
    // 切了正交,却把 07-28"浏览与编辑是同一个画面"破坏掉了:点"完成"时相机
    // 一个数没动,但每点的除数从恒定 camDist 换成各自的 depth,近处 +14%、
    // 远处 −11%(camDist = radius×kCamDistK = 8×radius),看上去就是"角度微微
    // 变了"(用户实机指认)。
    //
    // 统一取正交:2D 矩形手柄与盒投影严格重合这条必须留(透视下屏幕跑出矩形
    // 但 3D 仍在盒内的点不会红,与直觉相悖,是真机实测定的)。代价是预览失去
    // 近大远小,但 camDist 已是 8×radius 的长焦,原本的透视就很弱。
    orthographic: kCloudOrthographic,
  ).projectionFor(size);

  SelectionBox? get _liveBox =>
      widget.liveBox?.call() ?? _gestureBox ?? widget.selectionBox;

  bool _ignoreGesture = false;

  void _onScaleStart(ScaleStartDetails d) {
    _beginOrthoMorph();
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
    if (widget.controller?.takeBrowsePose() ?? false) {
      if (mounted) _restoreBrowsePose();
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

  // ── [LIVE-WAIT] perspective start → orthographic rig ──────────────────

  void _onMorph() {
    if (!mounted) return;
    setState(() {
      _orthoMix = Curves.easeOutCubic.transform(_morph.value);
    });
  }

  /// First gesture / entering edit after a perspective start: blend the
  /// divisor from depth to camDist (Cesium SceneTransitioner pattern — the
  /// pivot plane keeps its size throughout). No-op on the historical rig.
  void _beginOrthoMorph() {
    if (!kCloudOrthographic || _orthoMix == 1.0 || _morph.isAnimating) return;
    _morph
      ..reset()
      ..forward();
  }

  /// Applies the capture-pose start once the view knows its size (zoom/pan
  /// are size-relative: f = half·fillK·zoom, ox = w/2 + panX).
  void _applyPendingPerspective(Size size) {
    final p = _pendingPerspective;
    if (p == null || size.isEmpty) return;
    _pendingPerspective = null;
    _yaw = p.yaw;
    _pitch = p.pitch;
    _roll = p.roll;
    _pivot = [p.pivotX, p.pivotY, p.pivotZ];
    _camDistOverride = p.camDist;
    _zoom = p.f / (size.shortestSide * 0.5 * kFitFillK);
    _panX = p.ox - size.width * 0.5;
    _panY = p.oy - size.height * 0.5;
    _orthoMix = 0.0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _emitCamera();
    });
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
    _beginOrthoMorph();
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
      camDistOverride: _camDistOverride,
      orthoMix: _orthoMix,
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
    if (widget.editing) {
      // [2026-08-09 用户签决] "点击'回到初始点云大小',视角保持不变,不需要
      // 回到顶部视角" —— 只复位 pivot/pan/zoom(zoom 回编辑取景 = 全含),
      // yaw/pitch/roll 原样保留。
      final frame = editingFrameOf(widget.xyz);
      _animateTo(
        _CamState(
          pivot: frame.center,
          panX: 0,
          panY: 0,
          zoom: frame.zoom,
          yaw: _yaw,
          pitch: _pitch,
        ),
      );
      return;
    }
    // [LIVE-WAIT] back to the historical rig: no eye override, orthographic.
    // The ortho scale is f/camDist: rescale zoom so the picture does not jump
    // when camDist goes from the capture eye distance back to radius·k.
    _morph.stop();
    _pendingPerspective = null;
    final ov = _camDistOverride;
    if (ov != null && ov > 0) _zoom *= (_fitRadius * kCamDistK) / ov;
    _camDistOverride = null;
    _orthoMix = kCloudOrthographic ? 1.0 : 0.0;
    _animateTo(
      _CamState(
        pivot: orbitPivotOf(widget.xyz),
        panX: 0,
        panY: 0,
        zoom: 1.0,
        yaw: _kDefaultYaw,
        // [2026-08-07 用户实机指认"点击返回初始角度没回到正上方,编辑模式绝对
        // 不允许存在这种 45 度的情况"] 浏览态的默认取景是斜上 45°(与草稿卡片
        // 缩略图同姿态),但**编辑态的默认取景必须是正上方** —— 选区的 2D 手柄
        // 只有正俯视才与盒的投影严格重合。此前这里无条件用 _kDefaultPitch,
        // 于是"回到初始点云大小"会把编辑态的视角一起拽回 45°。
        pitch: _kDefaultPitch,
      ),
    );
  }

  /// 把朝向转回浏览态的斜上 45°(zoom/pan/pivot 原样保留)。
  ///
  /// [2026-08-08 用户签决] 见 [CloudViewController.requestBrowsePose]。走
  /// [_animateTo] 而不是直接 setState,是为了让"退出编辑"那一下是转过去的 ——
  /// 从正俯视瞬切到 45° 会像画面跳了一帧。
  void _restoreBrowsePose() {
    _animateTo(
      _CamState(
        pivot: _pivot,
        panX: _panX,
        panY: _panY,
        zoom: _zoom,
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
              _applyPendingPerspective(_viewSize);
              _syncGpu(_viewSize, MediaQuery.devicePixelRatioOf(context));
              final gpuTexture = _gpu?.textureId;
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
                    // [2026-08-07 用户签决] "整个屏幕背景统一一个颜色,纯黑!
                    // 不需要再为仪表盘位置单独设计一个背景" —— 此前画布是
                    // #1A1A1A 而底部面板是纯黑,实机能看出一条色差带。
                    color: Colors.black,
                    child: Stack(
                      children: [
                        if (gpuTexture != null) ...[
                          // [LOD v3] the GPU viewer draws the points (same camera/look).
                          Positioned.fill(child: Texture(textureId: gpuTexture)),
                          // Bottom fade above the scrubber, drawn over the texture with the
                          // painter's geometry (see CloudBottomFadeMask).
                          if (widget.bottomFade > 0)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: CustomPaint(
                                  painter: CloudBottomFadeMask(
                                    bottomFade: widget.bottomFade,
                                    arcRadius: widget.bottomFadeArcRadius,
                                  ),
                                ),
                              ),
                            ),
                        ] else
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
                              // [SEL-PREVIEW 2026-07-30] 浏览态剔除框外点
                              // (预览 = 交付预期);编辑态染红不剔除。
                              cullOutsideSelection: !widget.editing,
                              // [2026-07-29 回退 2D 框] 编辑态不画 3D 线框
                              // (由 RS 2D 矩形手柄代替);框外点变红保留。
                              // painter 与手柄同用正交 ⇒ 红点判定与矩形严格
                              // 重合(RS 观感)。
                              drawSelectionWireframe: false,
                              orthographic: kCloudOrthographic,
                              camDistOverride: _camDistOverride,
                              orthoMix: _orthoMix,
                              bottomFade: widget.bottomFade,
                              bottomFadeArcRadius: widget.bottomFadeArcRadius,
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
                                    _projectionForRect(_viewSize),
                                    widget.selectionBox!,
                                  ),
                                  widget.selectionBox!,
                                ),
                              ),
                              size: Size.infinite,
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

/// [LOD v3 2026-09-24] The painter's bottom fade (SparseCloudPainter.bottomFade /
/// bottomFadeArcRadius) for the GPU path, drawn OVER the texture as a black mask. Same geometry:
/// crest = height − bottomFade − kCloudBottomFadeGap; with an arc of radius R the boundary circle is
/// centred at (width/2, crest + R) and a point `above` = |p − centre| − R px above it is drawn with
/// alpha × clamp(above / kCloudBottomFadeBand, 0, 1) (nothing at or below the arc); without an arc
/// the boundary is the line y = crest. On the view's black background, «point alpha × fade» equals
/// «black mask of alpha 1 − fade over the point», so the mask is black with alpha 1 − fade:
/// RadialGradient black → black at R → transparent at R + band (linear in the radius, like
/// `above`), or the same as a LinearGradient in y.
class CloudBottomFadeMask extends CustomPainter {
  const CloudBottomFadeMask({required this.bottomFade, required this.arcRadius});

  final double bottomFade;
  final double arcRadius;

  @override
  void paint(Canvas canvas, Size size) {
    if (bottomFade <= 0 || size.isEmpty) return;
    final crest = size.height - bottomFade - kCloudBottomFadeGap;
    const band = kCloudBottomFadeBand;
    const black = Color(0xFF000000), clear = Color(0x00000000);
    final paint = Paint();
    if (arcRadius > 0) {
      final center = Offset(size.width / 2, crest + arcRadius);
      final outer = arcRadius + band;
      paint.shader = ui.Gradient.radial(
        center,
        outer,
        const [black, black, clear],
        [0, arcRadius / outer, 1],
      );
    } else {
      paint.shader = ui.Gradient.linear(
        Offset(0, crest - band),
        Offset(0, crest),
        const [clear, black],
      );
    }
    canvas.drawRect(Offset.zero & size, paint);
  }

  @override
  bool shouldRepaint(CloudBottomFadeMask old) =>
      old.bottomFade != bottomFade || old.arcRadius != arcRadius;
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
    this.cullOutsideSelection = false,
    this.drawSelectionWireframe = true,
    this.orthographic = false,
    this.roll = 0,
    this.bottomFade = 0,
    this.bottomFadeArcRadius = 0,
    this.camDistOverride,
    this.orthoMix,
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

  /// [2026-08-09 用户签决] "点云要是靠近滑轴就自动慢慢变淡,在滑轴处和下方
  /// 都直接变透明(点云只在滑轴的上方出现)。"
  ///
  /// bottomFade = 屏幕底部保留带的高度(px):点的屏幕 y 落在
  /// `size.height - bottomFade` 以下不画;其上 [kCloudBottomFadeBand] px 内
  /// alpha 线性渐隐。0 = 关闭(缩略图/浏览态照旧)。只动显示 alpha —— 点
  /// 一个都不删,交付无损。
  final double bottomFade;

  /// [2026-08-09 用户实机指认] "边界需要是贴合滑轴的曲线而不是横线" ——
  /// 渐隐边界的圆弧半径(= rulerArcRadius(屏宽),圆心在弧顶正下方)。
  /// 0 = 退回水平直线(滑轨收起时弧已转出屏幕,以及非滑轨场景)。
  final double bottomFadeArcRadius;

  /// [SEL-PREVIEW 2026-07-30] 框外点是**剔除**还是**染红**。
  ///
  /// 浏览态 true:预览呈现的就是选区后的范围,所见即交付预期。
  /// 编辑态 false:框外染红而不消失 —— 用户需要看见自己正在切掉什么,
  /// 点一消失就没法判断框拖得对不对了。
  final bool cullOutsideSelection;

  /// 是否画选区 3D 线框(8 角连边)。默认 true(草稿只读回显用)。
  /// SelectionCloudView(选区编辑页,Task 4)传 false —— 编辑页要框外红点,
  /// 但用自己的 2D 屏幕矩形手柄层,不要这条 3D 线框(会和手柄矩形叠加冗余)。
  final bool drawSelectionWireframe;

  /// 正交投影(见 CloudCamera.orthographic)。浏览与编辑同取
  /// [kCloudOrthographic] —— 两态用不同投影会在切换瞬间造成"角度变了"的错觉。
  final bool orthographic;

  /// See CloudCamera.camDistOverride / orthoMix (null = historical rig).
  final double? camDistOverride;
  final double? orthoMix;

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

  /// The painter's hasColor rule (was inline in [paint], moved here unchanged so the GPU viewer's
  /// set_points `colored` flag is the same decision): any non-black rgb triplet among the drawn
  /// points ⇒ coloured; an all-zero rgb ⇒ the height ramp.
  static bool hasColorOf(Uint8List rgb, {int stride = 1}) {
    for (var i = 0; i < rgb.length; i += 3 * math.max(1, stride)) {
      if (rgb[i] != 0 || rgb[i + 1] != 0 || rgb[i + 2] != 0) {
        return true;
      }
    }
    return false;
  }

  /// The height-ramp domain the painter uses for an uncoloured cloud (`_minY` / `_invYSpan`
  /// from the same [_ensureFit]), exposed read-only so the GPU viewer's style
  /// (pwlod_style.uncolored_min_y / uncolored_inv_y_span) and the parity fixture take the
  /// painter's own numbers instead of re-deriving them. Behaviour unchanged.
  @visibleForTesting
  static ({double minY, double invYSpan}) heightRampOf(Float32List xyz) {
    _ensureFit(xyz);
    return (minY: _minY, invYSpan: _invYSpan);
  }

  /// 点云**全量**轴对齐包围盒(逐点 min/max,一个点都不排除)。
  ///
  /// [2026-08-09 用户签决] "框选点云的初始范围必须包含全部点云" —— 初始框
  /// 从此用这个,不再用 [sceneAabbOf] 的分位盒(那会把最外 1% 留在框外)。
  /// sceneAabbOf 本体保留:环绕 pivot(orbitPivotOf)仍用分位中心,飞点不
  /// 该拽歪旋转中心。
  static ({double cx, double cy, double cz, double hx, double hy, double hz})
  fullAabbOf(Float32List xyz) {
    final n = xyz.length ~/ 3;
    if (n == 0) {
      return (cx: 0, cy: 0, cz: 0, hx: 0.5, hy: 0.5, hz: 0.5);
    }
    var x0 = xyz[0], x1 = xyz[0];
    var y0 = xyz[1], y1 = xyz[1];
    var z0 = xyz[2], z1 = xyz[2];
    for (var i = 1; i < n; i++) {
      final x = xyz[i * 3], y = xyz[i * 3 + 1], z = xyz[i * 3 + 2];
      if (x < x0) x0 = x;
      if (x > x1) x1 = x;
      if (y < y0) y0 = y;
      if (y > y1) y1 = y;
      if (z < z0) z0 = z;
      if (z > z1) z1 = z;
    }
    return (
      cx: (x0 + x1) / 2,
      cy: (y0 + y1) / 2,
      cz: (z0 + z1) / 2,
      hx: math.max((x1 - x0) / 2, 1e-6),
      hy: math.max((y1 - y0) / 2, 1e-6),
      hz: math.max((z1 - z0) / 2, 1e-6),
    );
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
    double? camDistOverride,
    double orthoMix = 0.0,
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
      camDistOverride: camDistOverride,
      orthoMix: orthoMix,
    ).projectionFor(size);
    final cosY = proj.cosY, sinY = proj.sinY;
    final cosP = proj.cosP, sinP = proj.sinP;
    final f = proj.f, camDist = proj.camDist, ox = proj.ox, oy = proj.oy;
    // Historical pick divisor is the perspective depth (even on the ortho
    // page); a mid-morph view uses the painter's blend so the pick lands where
    // the point is drawn. With a perspective start (mix 0) depth is already
    // the painter's divisor and camDist is the capture eye distance.
    final blend = orthoMix != 1.0 && orthoMix != 0.0;
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
      final dd = blend ? proj.divisorAt(depth) : depth;
      final vx = ox - x1 * f / dd;
      final vy = oy - y2 * f / dd;
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
      camDistOverride: camDistOverride,
      orthoMix: orthoMix,
    ).projectionFor(size);
    final cosY = proj.cosY, sinY = proj.sinY;
    final cosP = proj.cosP, sinP = proj.sinP;
    final f = proj.f, camDist = proj.camDist, ox = proj.ox, oy = proj.oy;
    final mix = proj.orthoMix;
    final cosR = proj.cosR, sinR = proj.sinR;
    final hasRoll = !(sinR == 0.0 && cosR == 1.0);

    final hasColor = hasColorOf(rgb, stride: stride);
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
      // [SEL-PREVIEW 2026-07-30 用户签决] "用了选区,预览呈现的就是选区后的
      // 范围"。编辑态仍把框外点染红(用户要看见自己切掉了什么);浏览态直接
      // 剔除 —— 预览就是交付预期。剔除放在最前面:一旦写进 vxA/colorA 就
      // 已经付了投影与排序的代价,而这条路径每帧跑十几万次。
      final outsideSelection =
          selectionBox != null && !selectionBox!.contains(wx, wy, wz);
      if (outsideSelection && cullOutsideSelection) continue;
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
      final dd = mix == 1.0
          ? camDist
          : (mix == 0.0 ? depth : depth + (camDist - depth) * mix);
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
      // 滑轨上方渐隐(见 bottomFade/bottomFadeArcRadius 字段注释)。放在
      // roll 之后:判的是最终屏幕位置。边界 = 滑轨弧线抬高 kCloudBottomFadeGap。
      var fade = 1.0;
      if (bottomFade > 0) {
        final crest = size.height - bottomFade - kCloudBottomFadeGap;
        if (bottomFadeArcRadius > 0) {
          // 弧顶上方一个渐隐带以外的点占大多数 —— 先用纯 y 快速放行,
          // 只有靠近边界的才算距离(每帧十几万点,sqrt 不能人人都跑)。
          if (vy > crest - kCloudBottomFadeBand) {
            final dxc = vx - size.width / 2;
            final dyc = (crest + bottomFadeArcRadius) - vy;
            final above =
                math.sqrt(dxc * dxc + dyc * dyc) - bottomFadeArcRadius;
            if (above <= 0) continue; // 边界弧及以下:不画
            if (above < kCloudBottomFadeBand) {
              fade = above / kCloudBottomFadeBand;
            }
          }
        } else {
          if (vy >= crest) continue;
          final d = crest - vy;
          if (d < kCloudBottomFadeBand) fade = d / kCloudBottomFadeBand;
        }
      }
      vxA[m] = vx;
      vyA[m] = vy;
      // sizeAttenuation: point radius scales with 1/depth (unit size at
      // the fitted cloud distance).
      if (mix == 1.0) {
        scaleA[m] = baseScale;
      } else {
        // Potree caps attenuated point size at maxSize = 50 px
        // (src/materials/PointCloudMaterial.js v1.8.2:
        // getValid(parameters.maxSize, 50.0)); our sprite is 16 px at scale 1.
        final sc = baseScale * (camDist / dd);
        scaleA[m] = sc > kMaxPointSpriteScale ? kMaxPointSpriteScale : sc;
      }
      depthA[m] = depth;
      var argb = displayColors[i];
      if (outsideSelection) {
        argb = kSelectionOutColor; // 编辑态:框外 → 红(点不消失)
      }
      if (fade < 1.0) {
        final a = ((argb >>> 24) & 0xff) * fade;
        argb = (argb & 0x00ffffff) | (a.round() << 24);
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
          final dd = mix == 1.0
              ? camDist
              : (mix == 0.0 ? depth : depth + (camDist - depth) * mix);
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
      old.camDistOverride != camDistOverride ||
      old.orthoMix != orthoMix ||
      old.drawSelectionWireframe != drawSelectionWireframe;
}
