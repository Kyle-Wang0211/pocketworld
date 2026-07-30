// sparse_cloud_viewer_page.dart — full-screen viewer for a take's persisted
// sparse cloud (<captureDir>/official_sfm_sparse.ply), opened from the drafts
// long-press menu ("查看点云"). Same SparseCloudView as the capture-time
// preview, so the experience is identical everywhere.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

import '../../official_capture/selection_box.dart';
import 'selection_tools_layer.dart';
import 'sfm_preview_overlay.dart' show SfmBottomActionButton;
import 'sparse_cloud_view.dart';

/// Parsed cloud (full set — delivery never downsamples).
class SparseCloudData {
  const SparseCloudData(this.xyz, this.rgb);
  final Float32List xyz;
  final Uint8List rgb;
  int get count => xyz.length ~/ 3;
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
  SelectionBox? _box;
  final ValueNotifier<CloudViewCamera?> _camera = ValueNotifier(null);
  final CloudViewController _cloudController = CloudViewController();
  Timer? _saveDebounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _cloudController.dispose();
    _camera.dispose();
    super.dispose();
  }

  String get _captureDir => File(widget.plyPath).parent.path;

  Future<void> _enterEditing() async {
    final cloud = _cloud;
    if (cloud == null) return;
    final fit = SparseCloudPainter.fitOf(cloud.xyz);
    final aabb = SparseCloudPainter.sceneAabbOf(cloud.xyz);
    final loaded = await SelectionBox.loadFrom(_captureDir);
    final box =
        (loaded != null &&
            loaded.isSaneFor(
              fitCx: fit.cx,
              fitCy: fit.cy,
              fitCz: fit.cz,
              fitRadius: fit.radius,
            ))
        ? loaded
        : SelectionBox.initialFor(
            cx: aabb.cx,
            cy: aabb.cy,
            cz: aabb.cz,
            hx: aabb.hx,
            hy: aabb.hy,
            hz: aabb.hz,
          );
    if (!mounted) return;
    setState(() {
      _box = box;
      _editing = true;
    });
  }

  void _onBoxChanged(SelectionBox b) {
    setState(() => _box = b);
    _saveDebounce?.cancel();
    _saveDebounce = Timer(
      const Duration(milliseconds: 500),
      () => unawaited(b.saveTo(_captureDir)),
    );
  }

  /// "恢复原始框大小":按当前点云重算初始框(位置/尺寸/朝向全复位)。
  void _resetBoxSize(SparseCloudData cloud) {
    final aabb = SparseCloudPainter.sceneAabbOf(cloud.xyz);
    _onBoxChanged(
      SelectionBox.initialFor(
        cx: aabb.cx,
        cy: aabb.cy,
        cz: aabb.cz,
        hx: aabb.hx,
        hy: aabb.hy,
        hz: aabb.hz,
      ),
    );
  }

  Future<void> _exitEditing() async {
    _saveDebounce?.cancel();
    final b = _box;
    if (b != null) await b.saveTo(_captureDir);
    if (!mounted) return;
    setState(() => _editing = false);
  }

  Future<void> _load() async {
    final cloud = await compute(
      loadSparsePly,
      widget.plyPath,
      debugLabel: 'sparse_ply_load',
    );
    // [E25-D 2026-07-20] L2 渲染门已删除 —— 草稿查看页渲染全量交付点云。
    // 原逻辑读 ghost_view_mask.bin / ghost_mask.bin 算可见性并隐藏 band15
    // 非救援点;整条 L1/L2 已按用户签决移除(理由见 git log 7e98b5e)。
    if (!mounted) return;
    setState(() {
      _cloud = cloud;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final cloud = _cloud;
    // [2026-07-28 用户实机指认"进编辑页点云会上移"] 根因是编辑态隐藏了
    // AppBar ⇒ body 高度变 ⇒ 视图尺寸变 ⇒ 投影中心变。改为**点云视图恒占
    // 全屏**,标题/按钮/工具层全部叠加其上 —— 切换只是 UI 变化,点云一个
    // 像素都不动(用户原话:"整个背景和点云不是一个东西吗")。
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
                    controller: _cloudController,
                    onCameraChanged: (c) => _camera.value = c,
                    selectionBox: _editing ? _box : null,
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
                    bottomGestureExclusion: _editing ? 200 : 0,
                  ),
                ),
                if (!_editing) ...[
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: SafeArea(
                      bottom: false,
                      child: Row(
                        children: [
                          IconButton(
                            onPressed: () => Navigator.of(context).maybePop(),
                            icon: const Icon(
                              Icons.arrow_back_ios_new_rounded,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              AppL10n.of(context).viewerTitleWithCount(
                                widget.title ??
                                    AppL10n.of(context).viewerSparseCloudTitle,
                                cloud.count,
                              ),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                              ),
                            ),
                          ),
                          const SizedBox(width: 48),
                        ],
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
                        child: SfmBottomActionButton(
                          label: AppL10n.of(context).sfmNext,
                          onTap: () => unawaited(_enterEditing()),
                        ),
                      ),
                    ),
                  ),
                ],
                if (_editing && _box != null)
                  Positioned.fill(
                    child: SelectionToolsLayer(
                      box: _box!,
                      onBoxChanged: _onBoxChanged,
                      camera: _camera,
                      controller: _cloudController,
                      onExit: () => unawaited(_exitEditing()),
                      onResetBoxSize: () => _resetBoxSize(cloud),
                    ),
                  ),
              ],
            ),
    );
  }
}
