// lod_cloud_view.dart — L5: the LOD point-cloud page (plan LOD_ARLOOPBENCH_PLAN_20260924 §2 L5).
//
// A new page next to the old viewer; it changes nothing in sparse_cloud_view.dart /
// sparse_cloud_viewer_page.dart (selection, double-tap pick etc. stay there).
// Branch feat/lod-viewer only — never production.
//
// Copied, not invented:
//   * Texture(textureId:) under a Stack — lib/ui/community/aether_cpp_card_demo.dart:612 @875fe67.
//   * Orbit camera state and defaults — sparse_cloud_view.dart:300-305 @875fe67
//     (yaw/pitch = the draft-card thumbnail pose kSparseThumbYaw/kSparseThumbPitch, :282-283;
//     roll 0, zoom 1, pan 0).
//   * Gestures — sparse_cloud_view.dart:722-757 @875fe67 verbatim in effect: two fingers pan
//     (focalPointDelta) and pinch-zoom (×(1 + (scale − 1)·0.08), clamp 0.15…20); one finger
//     yaw −= dx·0.008, pitch += dy·0.006 clamped to ±(π/2 − 0.02) (:294 _kPitchLimit).
//   * Projection — orthographic by default like the old viewer (sparse_cloud_view.dart:199
//     kCloudOrthographic); the matrix is lib/point_cloud_lod/lod_camera.dart (CloudCamera →
//     row-major WebGPU world→clip), a perspective switch is kept in the toolbar.
//   * Black canvas — sparse_cloud_view.dart:769 (user decision 2026-08-07 "纯黑").
// Not carried over (they need the points in Dart, which LOD by design does not have):
// double-tap focus/pick, selection box, point-size/tone controls. Pivot/radius = Potree
// fitToScreen's bounding sphere of the octree box; near/far = Potree Viewer.update
// (lod_scene_fit.dart, lod_camera.dart).
//
// Threads: gestures only compute the matrix and send it (pwlod_viewer_set_camera copies it
// under a lock); rendering happens on the engine's own thread (plan 3b / B1).
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../point_cloud_lod/lod_bridge.dart';
import '../../point_cloud_lod/lod_camera.dart';
import '../../point_cloud_lod/lod_scene_fit.dart';
import 'cloud_camera.dart';

// The old viewer's defaults, pinned here instead of imported: importing sparse_cloud_view.dart
// for three constants would drag its selection / octree-order / thumbnail imports into every
// app that mirrors this page (the bench has no lib/ui/). cloud_camera.dart is self-contained
// (dart:math + dart:ui) and IS imported. test/point_cloud_lod/lod_cloud_view_test.dart fails if
// any of these drifts from the old viewer's source.

/// sparse_cloud_view.dart:199 `kCloudOrthographic`.
const bool kLodDefaultOrthographic = true;

/// sparse_cloud_view.dart:282-283 = sparse_thumbnail.dart:34-35 `kSparseThumbYaw`/`Pitch`.
const double kLodDefaultYaw = math.pi;
const double kLodDefaultPitch = -math.pi / 4;

/// sparse_cloud_view.dart:294 `_kPitchLimit` (private there).
const double kLodPitchLimit = math.pi / 2 - 0.02;

class LodCloudView extends StatefulWidget {
  const LodCloudView({
    super.key,
    required this.octreeDir,
    this.bridge,
    this.params = const LodParams(),
    this.initialOrthographic = kLodDefaultOrthographic,
    this.showStats = true,
  });

  /// Directory holding metadata.json / hierarchy.bin / octree.bin (Potree 2.0).
  final String octreeDir;
  final LodBridge? bridge;
  final LodParams params;
  final bool initialOrthographic;
  final bool showStats;

  @override
  State<LodCloudView> createState() => _LodCloudViewState();
}

class _LodCloudViewState extends State<LodCloudView> {
  late final LodBridge _bridge = widget.bridge ?? LodBridge();

  // sparse_cloud_view.dart:300-305 @875fe67
  double _yaw = kLodDefaultYaw;
  double _pitch = kLodDefaultPitch;
  final double _roll = 0;
  double _zoom = 1.0;
  double _panX = 0;
  double _panY = 0;
  late bool _ortho = widget.initialOrthographic;

  LodSceneFit? _fit;
  LodTextureInfo? _tex;
  bool _octreeLoaded = false;
  Size _logical = Size.zero;
  double _dpr = 1;
  String? _error;
  LodFrameStats? _stats;
  Timer? _statsTimer;
  bool _creating = false;
  bool _cameraInFlight = false;
  bool _cameraDirty = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _loadFit();
    if (widget.showStats) {
      _statsTimer = Timer.periodic(
        const Duration(milliseconds: 250),
        (_) => _pollStats(),
      );
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _statsTimer?.cancel();
    final tex = _tex;
    _tex = null;
    if (tex != null) {
      unawaited(
        _bridge.dispose(textureId: tex.textureId).catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  Future<void> _loadFit() async {
    try {
      final text = await File(
        '${widget.octreeDir}/metadata.json',
      ).readAsString();
      final fit = LodSceneFit.fromMetadataJson(text);
      if (_disposed) return;
      setState(() => _fit = fit);
      _pushCamera();
    } catch (e) {
      if (!_disposed) setState(() => _error = 'metadata.json: $e');
    }
  }

  /// (Re)creates the texture at the widget's physical size; the targets' size must equal the
  /// camera viewport (pwlod_viewer.h:87), so a size change = new texture.
  Future<void> _ensureTexture() async {
    if (_creating || _logical.isEmpty || _disposed) return;
    final w = (_logical.width * _dpr).round(),
        h = (_logical.height * _dpr).round();
    if (w <= 0 || h <= 0) return;
    final old = _tex;
    if (old != null && old.widthPx == w && old.heightPx == h) return;
    _creating = true;
    try {
      if (old != null) {
        setState(() {
          _tex = null;
          _octreeLoaded = false;
        });
        await _bridge.dispose(textureId: old.textureId);
      }
      final tex = await _bridge.create(widthPx: w, heightPx: h);
      if (_disposed) {
        await _bridge.dispose(textureId: tex.textureId);
        return;
      }
      await _bridge.setParams(textureId: tex.textureId, params: widget.params);
      setState(() => _tex = tex);
      _pushCamera();
      await _bridge.loadOctree(
        textureId: tex.textureId,
        octreeDir: widget.octreeDir,
      );
      if (!_disposed) setState(() => _octreeLoaded = true);
    } catch (e) {
      if (!_disposed) setState(() => _error = '$e');
    } finally {
      _creating = false;
      // the size may have changed again while we were creating
      if (!_disposed) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _ensureTexture());
      }
    }
  }

  CloudCamera _cloudCamera(LodSceneFit fit) => CloudCamera(
    yaw: _yaw,
    pitch: _pitch,
    roll: _roll,
    zoom: _zoom,
    panX: _panX,
    panY: _panY,
    pivotX: fit.pivot[0],
    pivotY: fit.pivot[1],
    pivotZ: fit.pivot[2],
    radius: fit.radius,
    orthographic: _ortho,
  );

  /// Latest camera wins: at most one setCamera in flight, the newest state is sent after it.
  void _pushCamera() {
    final tex = _tex, fit = _fit;
    if (tex == null || fit == null || _logical.isEmpty || _disposed) return;
    if (_cameraInFlight) {
      _cameraDirty = true;
      return;
    }
    _cameraInFlight = true;
    final frame = lodCameraFrame(
      camera: _cloudCamera(fit),
      logicalSize: _logical,
      viewportWidthPx: tex.widthPx,
      viewportHeightPx: tex.heightPx,
      sceneBoxMin: fit.boxMin,
      sceneBoxMax: fit.boxMax,
      // Potree's near/far wants the selection's lowestSpacing; the frozen pwlod_frame_stats
      // does not carry it, so this is Potree's "not known yet" branch (viewer.js:1766-1768:
      // keep Scene.js:21-22's near 0.1 / far 1e6; orthographic near = −far).
      lowestSpacing: double.infinity,
    );
    _bridge
        .setCamera(textureId: tex.textureId, camera: frame)
        .catchError((Object e) {
          if (!_disposed) setState(() => _error = 'setCamera: $e');
        })
        .whenComplete(() {
          _cameraInFlight = false;
          if (_cameraDirty) {
            _cameraDirty = false;
            _pushCamera();
          }
        });
  }

  Future<void> _pollStats() async {
    final tex = _tex;
    if (tex == null || _disposed) return;
    try {
      final s = await _bridge.stats(textureId: tex.textureId);
      if (!_disposed && s != null) setState(() => _stats = s);
    } catch (_) {
      // stats are diagnostics; a failed poll is not an error state
    }
  }

  void _reset() {
    setState(() {
      _yaw = kLodDefaultYaw;
      _pitch = kLodDefaultPitch;
      _zoom = 1.0;
      _panX = 0;
      _panY = 0;
    });
    _pushCamera();
  }

  @override
  Widget build(BuildContext context) {
    _dpr = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = constraints.biggest;
        if (size != _logical) {
          _logical = size;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _ensureTexture();
            _pushCamera();
          });
        }
        final id = _tex?.textureId;
        return GestureDetector(
          // sparse_cloud_view.dart:722-757 @875fe67
          onScaleUpdate: (d) {
            setState(() {
              if (d.pointerCount >= 2) {
                _panX += d.focalPointDelta.dx;
                _panY += d.focalPointDelta.dy;
                if (d.scale != 1.0) {
                  _zoom = (_zoom * (1 + (d.scale - 1) * 0.08)).clamp(
                    0.15,
                    20.0,
                  );
                }
              } else {
                _yaw -= d.focalPointDelta.dx * 0.008;
                _pitch = (_pitch + d.focalPointDelta.dy * 0.006).clamp(
                  -kLodPitchLimit,
                  kLodPitchLimit,
                );
              }
            });
            _pushCamera();
          },
          child: Container(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (id != null)
                  Texture(textureId: id)
                else
                  const SizedBox.shrink(),
                if (widget.showStats)
                  Positioned(left: 8, top: 8, child: _StatsPanel(this)),
                Positioned(
                  right: 8,
                  top: 8,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      _ToolButton(
                        label: _ortho ? '正交' : '透视',
                        onTap: () {
                          setState(() => _ortho = !_ortho);
                          _pushCamera();
                        },
                      ),
                      const SizedBox(height: 6),
                      _ToolButton(label: '复位', onTap: _reset),
                    ],
                  ),
                ),
                if (_error != null)
                  Positioned(
                    left: 8,
                    right: 8,
                    bottom: 24,
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white12,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: const TextStyle(color: Colors.white, fontSize: 13),
      ),
    ),
  );
}

/// Frame number, points, nodes, uploads, min_node_pixel_size, cpu/gpu ms (task spec) plus the
/// shell's copyPixelBuffer counters.
class _StatsPanel extends StatelessWidget {
  const _StatsPanel(this.s);
  final _LodCloudViewState s;

  @override
  Widget build(BuildContext context) {
    final st = s._stats;
    final tex = s._tex;
    String f(double v, [int d = 1]) => v < 0 ? '—' : v.toStringAsFixed(d);
    final lines = <String>[
      if (tex != null) '${tex.widthPx}×${tex.heightPx}px  ${tex.version}',
      'octree ${s._octreeLoaded ? '已载入' : '载入中'}  ${s._ortho ? '正交' : '透视'}'
          '${s._fit != null ? '  树点数 ${s._fit!.points}' : ''}',
      if (st != null) ...[
        '帧 ${st.frameNumber}  GPU完成 ${st.completedFrameNumber}',
        '点 ${st.pointsDrawn}  节点 ${st.nodesDrawn}  加载中 ${st.nodesLoading}',
        '上传 ${st.uploadsThisFrame}  缓存丢弃 ${st.droppedForCache}',
        'min_node_pixel_size ${f(st.minNodePixelSize, 2)}',
        'cpu ${f(st.cpuMs, 2)} ms  gpu ${f(st.gpuMs, 2)} ms',
        if (st.shell.isNotEmpty)
          '取帧 ${st.shell['copy_calls']}  空 ${st.shell['copy_empty']}  '
              '最新 ${st.shell['last_acquired_frame_number']}  '
              '最慢 ${st.shell['copy_max_us']} µs',
      ] else
        '尚无已发布帧',
    ];
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.all(6),
        color: Colors.black54,
        child: Text(
          lines.join('\n'),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontFamily: 'Menlo',
            height: 1.3,
          ),
        ),
      ),
    );
  }
}

/// Full-screen wrapper.
class LodCloudPage extends StatelessWidget {
  const LodCloudPage({
    super.key,
    required this.octreeDir,
    this.title = 'LOD 点云',
    this.bridge,
  });
  final String octreeDir;
  final String title;
  final LodBridge? bridge;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
      title: Text(title),
    ),
    body: LodCloudView(octreeDir: octreeDir, bridge: bridge),
  );
}
