// sparse_cloud_viewer_page.dart — full-screen viewer for a take's persisted
// sparse cloud (<captureDir>/official_sfm_sparse.ply), opened from the drafts
// long-press menu ("查看点云"). Same SparseCloudView as the capture-time
// preview, so the experience is identical everywhere.

import 'dart:math' as math;
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable, compute;
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

import '../../official_capture/dense_stage.dart';
import '../../dense/dense_stage_progress.dart';
import '../../dense/dense_stage_panel.dart';
import '../../dense/native_dense_stage_launcher.dart' show kDensePlyFileName;
import '../../official_capture/selection_box.dart';
import 'ruler_scrubber.dart';
import 'selection_tools_layer.dart';
import 'sfm_preview_overlay.dart' show SfmBottomActionButton;
import '../../point_cloud_display/progressive_octree_order.dart';
import '../../point_cloud_lod/dense_lod_cache.dart';
import 'sparse_cloud_view.dart';

/// Parsed cloud (full set — delivery never downsamples). [sourceCount] is the
/// number of points in the file; [count] the number held here (smaller only
/// when the review point budget truncated a progressive-ordered copy).
class SparseCloudData {
  const SparseCloudData(this.xyz, this.rgb, {int? sourceCount})
      : _sourceCount = sourceCount;
  final Float32List xyz;
  final Uint8List rgb;
  final int? _sourceCount;
  int get count => xyz.length ~/ 3;
  int get sourceCount => _sourceCount ?? count;
  bool get isBudgeted => sourceCount > count;
}

/// What the viewer loads (isolate entry): the full PLY when it fits the review
/// point budget, otherwise the first [ReviewPointCloudPolicy.kPointBudget]
/// points of the progressive octree order (uniform over the whole extent).
/// The file is left as is.
SparseCloudData? loadReviewCloud(String path) =>
    loadReviewCloudWithBudget(path, ReviewPointCloudPolicy.kPointBudget);

SparseCloudData? loadReviewCloudWithBudget(String path, int budget) {
  final full = loadSparsePly(path);
  if (full == null || full.count <= budget) return full;
  final ordered = ProgressiveOctreeOrder.reorder(xyz: full.xyz, rgb: full.rgb);
  return SparseCloudData(
    Float32List.fromList(ordered.xyz.sublist(0, budget * 3)),
    Uint8List.fromList(ordered.rgb.sublist(0, budget * 3)),
    sourceCount: full.count,
  );
}

/// Loads the app's own binary-little-endian PLY (xyz float32 + rgb uchar,
/// as written by sparse_ply.dart / the host regeneration tool).
SparseCloudData? loadSparsePly(String path) {
  try {
    final bytes = File(path).readAsBytesSync();
    // Find end_header\n
    const marker = 'end_header\n';
    final headEnd = _indexOfAscii(bytes, marker);
    if (headEnd < 0) return null;
    final header = String.fromCharCodes(bytes.sublist(0, headEnd));
    final m = RegExp(r'element vertex (\d+)').firstMatch(header);
    if (m == null || !header.contains('binary_little_endian')) return null;
    final n = int.parse(m.group(1)!);
    final body = bytes.sublist(headEnd + marker.length);
    if (body.length < n * 15) return null;
    final xyz = Float32List(n * 3);
    final rgb = Uint8List(n * 3);
    final bd = ByteData.sublistView(body);
    for (var i = 0; i < n; i++) {
      final o = i * 15;
      xyz[i * 3] = bd.getFloat32(o, Endian.little);
      xyz[i * 3 + 1] = bd.getFloat32(o + 4, Endian.little);
      xyz[i * 3 + 2] = bd.getFloat32(o + 8, Endian.little);
      rgb[i * 3] = body[o + 12];
      rgb[i * 3 + 1] = body[o + 13];
      rgb[i * 3 + 2] = body[o + 14];
    }
    return SparseCloudData(xyz, rgb);
  } catch (_) {
    return null;
  }
}

int _indexOfAscii(Uint8List bytes, String needle) {
  final n = needle.codeUnits;
  final limit = bytes.length - n.length;
  for (var i = 0; i <= limit && i < 4096; i++) {
    var hit = true;
    for (var j = 0; j < n.length; j++) {
      if (bytes[i + j] != n[j]) {
        hit = false;
        break;
      }
    }
    if (hit) return i;
  }
  return -1;
}

class SparseCloudViewerPage extends StatefulWidget {
  const SparseCloudViewerPage({super.key, required this.plyPath, this.title});

  final String plyPath;
  final String? title;

  @override
  State<SparseCloudViewerPage> createState() => _SparseCloudViewerPageState();
}

class _SparseCloudViewerPageState extends State<SparseCloudViewerPage> {
  SparseCloudData? _cloud;
  bool _loading = true;

  // [2026-07-28 用户签决] 浏览与编辑是**同一个页面**:点"下一步"只是把
  // 工具层叠上来(_editing=true),点云视图与相机是同一个 State,不重建、
  // 不 push 新路由 ⇒ 角度/位置/缩放天然连续。
  bool _editing = false;

  /// 底部滑轨面板是否收起(工具层回报)—— 只用来算手势排除区。
  bool _rulerCollapsed = false;

  // [SEL-PREVIEW 2026-07-30 用户签决] 选区不再是必经步骤,而是可选动作 ⇒ 框必须
  // 在**进页面时**就从磁盘读出来,否则重新打开一个已选区的草稿会显示全量点云。
  // 原先只在 _enterEditing() 里读,浏览态 _box 恒为 null。
  SelectionBox? _box;

  /// 打开本页那一刻磁盘上的框 —— ④"编辑记录是否保存"的比对基线。
  /// 磁盘无框时基线取按点云 AABB 算出的全域框,这样"点下一步再返回、什么都
  /// 没动"不会被判成修改。
  SelectionBox? _baseline;
  bool _baselineAbsentOnDisk = false;

  /// 用户**真的**选过区吗。
  ///
  /// [2026-07-30 用户签决"在用户未进入编辑页面之前,展示原始的点云"] 没选过区
  /// 时 _box 是按点云 AABB 算的兜底框,而 initialFor 会留边距 ⇒ 拿它去裁剪会
  /// 悄悄切掉外圈的点,用户看到的就不是"原始点云"了。所以浏览态只有在
  /// **盘上有存过的框**或**这次改过**时才裁剪,否则整朵云原样呈现。
  bool _selectionApplied = false;

  /// 进编辑态那一刻的框 —— "不保存"回滚到这里。
  SelectionBox? _editEntryBox;
  bool _editEntryApplied = false;

  /// 框内点数 —— 浏览态既然只画框内点,标题就不能再报全量数(会自相矛盾)。
  int? _visibleCount;

  final ValueNotifier<CloudViewCamera?> _camera = ValueNotifier(null);
  final CloudViewController _cloudController = CloudViewController();

  /// [LOD v3 2026-09-24] For the dense PLY (「稠密点云」, _openDense): its octree from
  /// DenseLodCache — the same path the capture page uses, so both show the same viewer. The
  /// sparse PLY never gets one (sparse stays a flat set, with its editing).
  ValueListenable<DenseLodState>? _denseLod;

  bool get _isDensePly =>
      File(widget.plyPath).uri.pathSegments.last == kDensePlyFileName;

  @override
  void initState() {
    super.initState();
    if (_isDensePly) {
      _denseLod = DenseLodCache.instance.watch(widget.plyPath)..addListener(_onDenseLod);
    }
    _load();
  }

  void _onDenseLod() {
    if (mounted) setState(() {});
  }

  String? get _lodOctreeDir {
    final s = _denseLod?.value;
    return s != null && s.phase == DenseLodPhase.ready ? s.octreeDir : null;
  }

  @override
  void dispose() {
    _denseLod?.removeListener(_onDenseLod);
    _cloudController.dispose();
    _camera.dispose();
    super.dispose();
  }

  String get _captureDir => File(widget.plyPath).parent.path;

  /// 读盘 + 合理性校验,得到本页开场的框。在 [_load] 里跑一次,浏览态就能
  /// 立刻按框裁剪;进编辑态不再需要读盘。
  Future<void> _resolveOpeningBox(SparseCloudData cloud) async {
    final fit = SparseCloudPainter.fitOf(cloud.xyz);
    // [2026-08-09 用户签决"严丝合缝"] 初始框 = 全量逐轴包围盒(见
    // editingFrameOf);编辑态 zoom 让最长边恒为标准屏幕尺寸。
    final frame = editingFrameOf(cloud.xyz);
    final fallback = SelectionBox.initialSquareFace(
      cx: frame.center[0],
      cy: frame.center[1],
      cz: frame.center[2],
      halfExtent: math.max(frame.hx, math.max(frame.hy, frame.hz)),
    );
    final loaded = await SelectionBox.loadFrom(_captureDir);
    final sane =
        loaded != null &&
        loaded.isSaneFor(
          fitCx: fit.cx,
          fitCy: fit.cy,
          fitCz: fit.cz,
          fitRadius: fit.radius,
        );

    _box = sane ? loaded : fallback;
    // 磁盘上没有可用的框 ⇒ 基线是"全域",且"不保存"要**删掉**新写的文件,
    // 而不是把全域框留在盘上。
    _baselineAbsentOnDisk = !sane;
    _baseline = sane ? loaded : fallback;
    _selectionApplied = sane;
  }

  void _enterEditing() {
    if (_cloud == null || _box == null) return;
    setState(() {
      _editEntryBox = _box;
      _editEntryApplied = _selectionApplied;
      _editing = true;
    });
  }

  /// 把 [box] 落盘;[applied] 为假表示"用户没有选区",此时删掉文件而不是留一个
  /// 兜底的全域框冒充选区。
  Future<void> _persist(SelectionBox box, {required bool applied}) async {
    if (applied) {
      await box.saveTo(_captureDir);
      return;
    }
    try {
      final f = File('$_captureDir/$kSelectionBoxFileName');
      if (f.existsSync()) await f.delete();
    } catch (_) {}
  }

  /// 底部"下一步":把这一份点云交给后续处理。
  ///
  /// 选区只在用户**真的**选过时才带上 —— 没选区就传 null 表示"处理整朵云",
  /// 而不是把按 AABB 算出来的兜底框当成用户的意图(它留了边距,会悄悄切边)。
  Future<void> _startDenseStage(SparseCloudData cloud) async {
    final r = await denseStageLauncher.start(
      DenseStageRequest(
        captureDir: _captureDir,
        sparsePlyPath: widget.plyPath,
        pointCount: cloud.count,
        selection: _selectionApplied ? _box : null,
      ),
    );
    if (!mounted || r.status == DenseStageStatus.started) return;
    final l = AppL10n.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(r.message ?? l.denseStageUnavailable)),
    );
  }

  /// 稠密 PLY 用同一个查看页打开(同一格式,全量不降采样)。
  void _openDense(String ply) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SparseCloudViewerPage(plyPath: ply, title: '稠密点云'),
      ),
    );
  }

  /// 框内点数。浏览态每帧只画框内点,标题必须跟着走。
  static int _countInside(Float32List xyz, SelectionBox? box) {
    final n = xyz.length ~/ 3;
    if (box == null) return n;
    var c = 0;
    for (var i = 0; i < n; i++) {
      final o = i * 3;
      if (box.contains(xyz[o], xyz[o + 1], xyz[o + 2])) c++;
    }
    return c;
  }

  void _onBoxChanged(SelectionBox b) {
    setState(() {
      _box = b;
      // 用户动手改了框 ⇒ 从此这就是"他的选区",浏览态开始按它裁剪。
      _selectionApplied = true;
    });
  }

  /// "恢复原始框大小":按当前点云重算初始框(位置/尺寸/朝向全复位)。
  void _resetBoxSize(SparseCloudData cloud) {
    final frame = editingFrameOf(cloud.xyz);
    _onBoxChanged(
      SelectionBox.initialSquareFace(
        cx: frame.center[0],
        cy: frame.center[1],
        cz: frame.center[2],
        halfExtent: math.max(frame.hx, math.max(frame.hy, frame.hz)),
      ),
    );
  }

  /// 右上"完成":提交本次编辑,不问。
  ///
  /// [2026-07-30 用户签决"直接学苹果的相册"] 确认的负担只压在破坏性的那一侧。
  /// 顺带把退页基线推到当前值 —— 用户已明确表过态,退到草稿页不该再问。
  /// [2026-08-03 用户签决] "用户第一次点进来,点云其实就已经是被编辑的状态了
  /// (初始的框就已经算编辑了)" —— 所以 applied 恒为 true:点了"完成"就是把
  /// 当前框(哪怕一个手柄都没碰过的初始框)确立为选区。
  ///
  /// 此前取 _selectionApplied,而它只在 _onBoxChanged 里置真 ⇒ 首次进编辑不动
  /// 任何东西点"完成",_persist 走的是**删文件**分支,选区直接丢掉,"完成"和
  /// "取消"效果一模一样(点云都回到原样)。取消那一侧的撤回语义不变 —— 它读
  /// 的是进编辑那一刻的 _editEntryApplied,与这里无关。
  Future<void> _saveEditing() async {
    final b = _box;
    if (b == null) return;
    await _persist(b, applied: true);
    if (!mounted) return;
    setState(() {
      _editing = false;
      _selectionApplied = true;
      _baseline = b;
      _baselineAbsentOnDisk = false;
      _visibleCount = _countInside(_cloud!.xyz, b);
    });
  }

  /// "确定要放弃更改吗?" —— 锚定在左上"取消"按钮**下方**的浮层。
  ///
  /// [2026-08-03 用户签决 + 截图] 学苹果相册:确认不是从屏幕底部升起的动作单,
  /// 而是从被点的那个按钮下面弹出来,视觉上和"取消"连成一条。原实现用
  /// showCupertinoModalPopup + CupertinoActionSheet,弹在屏幕底部,离触发点最远。
  ///
  /// 位置由 kSelectionCancelKey 实测得到(不写死坐标 —— 按钮位置随 SafeArea
  /// 和机型变)。点浮层以外的任何地方 = 返回 null = 留在编辑页。
  Future<bool?> _askDiscard() {
    final l = AppL10n.of(context);
    final box =
        kSelectionCancelKey.currentContext?.findRenderObject() as RenderBox?;
    final anchor = box == null
        ? const Offset(12, 56)
        : box.localToGlobal(Offset.zero) + Offset(0, box.size.height + 2);
    return showDialog<bool>(
      context: context,
      barrierColor: Colors.transparent, // 苹果的 popover 不压暗背景
      // ⚠️ 必须关掉:默认 true 会把下面的 Stack 包进 SafeArea,而 anchor 是
      // **全局**坐标(localToGlobal),于是浮层被状态栏高度又顶下去一截 ——
      // 用户实机指认"位置需要调整,应该紧贴取消下面"的直接原因。
      useSafeArea: false,
      builder: (ctx) => Stack(
        children: [
          // 全屏透明命中层:点浮层以外 ⇒ 收起,什么都不做。
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(ctx).pop(),
            ),
          ),
          Positioned(
            left: anchor.dx,
            top: anchor.dy,
            child: Material(
              key: const ValueKey('selection-discard-popover'),
              color: const Color(0xF2F2F2F7), // iOS 系统菜单浅色
              borderRadius: BorderRadius.circular(14),
              elevation: 8,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 168, maxWidth: 212),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 11, 14, 10),
                      child: Text(
                        l.selectionDiscardTitle,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Color(0xFF1C1C1E),
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const Divider(height: 0.5, color: Color(0x33000000)),
                    InkWell(
                      onTap: () => Navigator.of(ctx).pop(true),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          l.selectionDiscardConfirm,
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                            color: Color(0xFFFF3B30), // iOS 破坏性红
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 左上"取消":放弃本次编辑。
  ///
  /// 没改过 → 直接回浏览态,不打扰。改过 → 苹果相册那张动作单:一个破坏性的
  /// "放弃更改",点屏幕其它地方就消失并留在编辑页(barrier 可关)。
  ///
  /// [2026-08-03 修正] 编辑期只更新内存预览,正式记录必须等"完成"才落盘。
  /// 这里仍把入口状态写回去作为防御性回滚,用于清理由旧版本提前写入的记录。
  Future<void> _cancelEditing() async {
    final entry = _editEntryBox;
    final b = _box;
    final dirty = entry != null && b != null && !b.sameAs(entry);

    if (dirty) {
      final confirmed = await _askDiscard();
      // null = 点了浮层以外的地方 ⇒ 留在编辑页,什么都不动。
      if (confirmed != true) return;
    }

    final finalBox = entry ?? b;
    final finalApplied = entry != null ? _editEntryApplied : _selectionApplied;
    if (finalBox != null) await _persist(finalBox, applied: finalApplied);
    if (!mounted) return;
    // [2026-08-08 用户签决] "什么都没做直接点取消 ⇒ 恢复到斜上 45 度。"进编辑时
    // 视角被强制拧成正俯视(手柄要求),取消既然撤回本次编辑,视角也一并还回去。
    // 注意"完成"(_saveEditing)刻意**不**发这个请求 —— 用户要"保留在当前视角"。
    _cloudController.requestBrowsePose();
    setState(() {
      _editing = false;
      if (finalBox != null) _box = finalBox;
      _selectionApplied = finalApplied;
      _baseline = finalBox;
      _baselineAbsentOnDisk = !finalApplied;
      _visibleCount = _countInside(_cloud!.xyz, finalApplied ? finalBox : null);
    });
  }

  /// ④ 退到草稿页时的裁决。返回 false = 留在本页。
  ///
  /// [2026-08-03 修正] 编辑期不再提前落盘；这里保留显式回滚，兼容旧版本
  /// 可能已经写入的选区记录。
  Future<bool> _confirmLeaveWithSelectionEdits() async {
    final baseline = _baseline;
    final current = _box;
    if (baseline == null || current == null) return true;
    if (current.sameAs(baseline)) return true; // 没动过 → 直接走

    final l = AppL10n.of(context);
    final choice = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(l.sfmSelectionSaveTitle),
        content: Text(l.sfmSelectionSaveBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('cancel'),
            child: Text(l.sfmSelectionSaveCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('discard'),
            child: Text(l.sfmSelectionSaveDiscard),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop('keep'),
            child: Text(l.sfmSelectionSaveKeep),
          ),
        ],
      ),
    );
    if (choice == null || choice == 'cancel') return false;

    if (choice == 'discard') {
      if (_baselineAbsentOnDisk) {
        // 开场时盘上没有框 ⇒ 回滚就是把这次写出来的文件删掉,而不是把全域框
        // 留下来当"用户的选区"。
        try {
          final f = File('$_captureDir/$kSelectionBoxFileName');
          if (f.existsSync()) await f.delete();
        } catch (_) {}
      } else {
        await baseline.saveTo(_captureDir);
      }
      if (mounted) {
        setState(() {
          _box = baseline;
          _visibleCount = _countInside(_cloud!.xyz, baseline);
        });
      }
    } else {
      await current.saveTo(_captureDir);
      _baseline = current;
      _baselineAbsentOnDisk = false;
    }
    return true;
  }

  Future<void> _onBack() async {
    if (!await _confirmLeaveWithSelectionEdits()) return;
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }

  Future<void> _load() async {
    final cloud = await compute(
      loadReviewCloud,
      widget.plyPath,
      debugLabel: 'sparse_ply_load',
    );
    // [E25-D 2026-07-20] L2 渲染门已删除 —— 草稿查看页渲染全量交付点云。
    // 原逻辑读 ghost_view_mask.bin / ghost_mask.bin 算可见性并隐藏 band15
    // 非救援点;整条 L1/L2 已按用户签决移除(理由见 git log 7e98b5e)。
    if (cloud != null) await _resolveOpeningBox(cloud);
    if (!mounted) return;
    setState(() {
      _cloud = cloud;
      _loading = false;
      if (cloud != null) _visibleCount = _countInside(cloud.xyz, _box);
    });
  }

  @override
  Widget build(BuildContext context) {
    final cloud = _cloud;
    // 侧滑/系统返回必须走同一条裁决,否则 ④ 的弹窗被手势绕过。编辑态的返回
    // 手势含义是"回预览",不是"离开本页"。
    return PopScope(
      canPop: !_editing && !_selectionDirty,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        if (_editing) {
          // 编辑态的系统侧滑返回 = 左上"取消"(改过就会先问一句)。
          unawaited(_cancelEditing());
          return;
        }
        unawaited(_onBack());
      },
      child: _buildScaffold(context, cloud),
    );
  }

  /// 框是否相对"打开本页那一刻"有实质改动。
  bool get _selectionDirty {
    final b = _baseline;
    final c = _box;
    return b != null && c != null && !c.sameAs(b);
  }

  // [2026-07-28 用户实机指认"进编辑页点云会上移"] 根因是编辑态隐藏了
  // AppBar ⇒ body 高度变 ⇒ 视图尺寸变 ⇒ 投影中心变。改为**点云视图恒占
  // 全屏**,标题/按钮/工具层全部叠加其上 —— 切换只是 UI 变化,点云一个
  // 像素都不动(用户原话:"整个背景和点云不是一个东西吗")。
  Widget _buildScaffold(BuildContext context, SparseCloudData? cloud) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _loading
          ? const Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.4,
                  color: Colors.white70,
                ),
              ),
            )
          : cloud == null
          ? Center(
              child: Text(
                AppL10n.of(context).viewerLoadFailed,
                style: const TextStyle(color: Colors.white54, fontSize: 14),
              ),
            )
          : Stack(
              children: [
                // 同一个视图实例贯穿浏览与编辑,尺寸恒为全屏。
                Positioned.fill(
                  child: SparseCloudView(
                    xyz: cloud.xyz,
                    rgb: cloud.rgb,
                    // [LOD v3] same GPU viewer as the capture page; the dense PLY's octree when ready.
                    gpu: true,
                    octreeDir: _lodOctreeDir,
                    controller: _cloudController,
                    onCameraChanged: (c) => _camera.value = c,
                    // 编辑态必须传框(画手柄 + 框外染红);浏览态只在用户
                    // **真的**选过区时才传 —— SparseCloudView 内部按
                    // `cullOutsideSelection: !editing` 剔除框外点,没选过区就
                    // 传 null,整朵原始点云原样呈现。
                    selectionBox: (_editing || _selectionApplied) ? _box : null,
                    onBoxChanged: _onBoxChanged,
                    liveBox: () =>
                        _box ??
                        const SelectionBox(
                          cx: 0,
                          cy: 0,
                          cz: 0,
                          sx: 1,
                          sy: 1,
                          sz: 1,
                        ),
                    editing: _editing,
                    // 滑轨收起后面板只剩把手 ⇒ 排除区跟着缩,否则点云下方留一
                    // 大片点不动的死区。
                    bottomGestureExclusion: !_editing
                        ? 0
                        : (_rulerCollapsed ? 44 : 200),
                    // [2026-08-09 用户签决] 编辑态点云在滑轨处及以下全透明,
                    // 靠近滑轨渐隐。边界用滑轨真实几何(弧顶 = 面板顶 +
                    // kRulerArcTop),不用上面 200 那个手势手感值 —— 那会让点
                    // 在弧顶上方 ~70px 就消失,凭空多出一条黑带。
                    bottomFade: !_editing
                        ? 0
                        : (_rulerCollapsed
                              ? 44
                              : MediaQuery.of(context).padding.bottom +
                                    kRulerHeight -
                                    kRulerArcTop),
                    // [2026-08-09 用户实机指认] 边界须贴合滑轨的弧线;收起时弧
                    // 已转出屏幕 ⇒ 0(横线)。
                    bottomFadeArcRadius: !_editing || _rulerCollapsed
                        ? 0
                        : rulerArcRadius(MediaQuery.of(context).size.width),
                  ),
                ),
                if (!_editing) ...[
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: SafeArea(
                      bottom: false,
                      // Stack 而不是 Row:左右两侧宽度不再对称("选区编辑"比
                      // 返回箭头宽得多),放进 Row 会把标题挤偏。标题绝对居中,
                      // 两个按钮各自贴边。
                      child: SizedBox(
                        height: 48,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: Center(
                                child: Text(
                                  AppL10n.of(context).viewerTitleWithCount(
                                    widget.title ??
                                        AppL10n.of(
                                          context,
                                        ).viewerSparseCloudTitle,
                                    // 浏览态只画框内点,标题跟着报框内数,
                                    // 否则"166853 点"会和眼前明显更少的点
                                    // 自相矛盾。
                                    _selectionApplied
                                        ? (_visibleCount ?? cloud.count)
                                        : cloud.sourceCount,
                                  ),
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                  ),
                                ),
                              ),
                            ),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: IconButton(
                                key: const ValueKey('viewer-back'),
                                onPressed: () => unawaited(_onBack()),
                                icon: const Icon(
                                  Icons.arrow_back_ios_new_rounded,
                                  color: Colors.white,
                                  size: 20,
                                ),
                              ),
                            ),
                            // [SEL-ENTRY 2026-07-30 用户签决] 选区编辑降级成
                            // 右上角可选入口(原先这里只是个 48pt 占位),用
                            // **文字**不用图标。编辑态里 SelectionToolsLayer
                            // 在同一位置写"完成" ⇒ 同一个开关在切换。
                            Align(
                              alignment: Alignment.centerRight,
                              // [PILL-BTN 2026-08-06 用户签决] 白色胶囊底+黑字
                              // (与编辑态的"取消/完成"同款)。
                              child: TextButton(
                                key: const ValueKey('viewer-enter-editing'),
                                onPressed: _enterEditing,
                                style: TextButton.styleFrom(
                                  backgroundColor: Colors.white,
                                  foregroundColor: Colors.black,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                  ),
                                  minimumSize: const Size(0, 38),
                                  shape: const StadiumBorder(),
                                ),
                                child: Text(
                                  AppL10n.of(context).sfmEditSelection,
                                  style: const TextStyle(
                                    color: Colors.black,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 16,
                    child: SafeArea(
                      top: false,
                      child: SizedBox(
                        width: double.infinity,
                        // [2026-07-31 用户签决]"下一步"不再是进选区编辑
                        // (那已降级成右上角的可选入口),而是启动后续处理。
                        // [2026-09-15] 同一颗按钮跟着稠密阶段走:处理中禁用、完成后
                        // 变「查看稠密点云」、失败后变「重试」。
                        child: ValueListenableBuilder<DenseStageProgress?>(
                          valueListenable: denseStageProgress,
                          builder: (context, p, _) {
                            final mine = p != null && p.captureDir == _captureDir ? p : null;
                            if (mine != null && mine.state == DenseStageState.running) {
                              return const SfmBottomActionButton(label: '稠密处理中…', onTap: null);
                            }
                            if (mine != null && mine.state == DenseStageState.done && mine.outPly != null) {
                              return SfmBottomActionButton(
                                label: '查看稠密点云',
                                onTap: () => _openDense(mine.outPly!),
                              );
                            }
                            return SfmBottomActionButton(
                              label: mine != null && mine.state == DenseStageState.failed
                                  ? '重试稠密处理'
                                  : AppL10n.of(context).sfmNext,
                              onTap: denseStageLauncher.isAvailable
                                  ? () => unawaited(_startDenseStage(cloud))
                                  : null,
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ],
                if (cloud.isBudgeted)
                  Positioned(
                    left: 16,
                    right: 16,
                    top: 60,
                    child: SafeArea(
                      bottom: false,
                      child: Text(
                        '显示前 ${cloud.count} 点(八叉树均匀抽样)· 文件含 ${cloud.sourceCount} 点',
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white38, fontSize: 12),
                      ),
                    ),
                  ),
                // [2026-09-15] 稠密阶段状态块(按钮上方)—— 必须是 Positioned 子项(见 dense_stage_panel.dart)
                DenseStagePanel(
                  captureDir: _captureDir,
                  densePlyPath: '$_captureDir/$kDensePlyFileName',
                  onView: _openDense,
                ),
                if (_editing && _box != null)
                  Positioned.fill(
                    child: SelectionToolsLayer(
                      box: _box!,
                      onBoxChanged: _onBoxChanged,
                      camera: _camera,
                      controller: _cloudController,
                      onExit: () => unawaited(_saveEditing()),
                      onCancel: () => unawaited(_cancelEditing()),
                      onRulerCollapsedChanged: (c) =>
                          setState(() => _rulerCollapsed = c),
                      onResetBoxSize: () => _resetBoxSize(cloud),
                    ),
                  ),
              ],
            ),
    );
  }
}
