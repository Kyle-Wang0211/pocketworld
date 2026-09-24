// gpu_cloud_layer.dart — the GPU half of SparseCloudView (pwlod_viewer.h v3): one engine viewer
// behind a Flutter Texture that draws whatever the view is showing (interim white cloud, sparse
// cloud, growing dense copy → set_points; finished dense octree → load_octree) with the view's
// own camera (CloudProjection) and look (pwlod_style). The view keeps every gesture, overlay,
// pick and selection edit in Dart; this class only mirrors state into the engine.
//
// Product glue, no upstream to copy for the orchestration itself. Its shapes are the ones already
// in this repo:
//   * texture at PHYSICAL size, recreated when the size changes (pwlod_viewer.h: viewport must
//     equal the targets) — feat/lod-viewer lod_cloud_view.dart _ensureTexture;
//   * at most one setCamera in flight, the newest state wins — same file, _pushCamera;
//   * stats polled every 250 ms, Potree near/far fed from lowest_spacing — same file, _pollStats;
//   * a failure never takes the picture away: the view keeps painting with the CPU painter
//     (SparseCloudPainter) whenever [textureId] is null — the coordinator's rule
//     「建树失败或自检不过时，保持平铺显示并记日志，不崩溃」 applied to every GPU failure.
//
// Hand-over: the view switches from its CPU painter to the Texture only after the engine has
// PUBLISHED a frame with a source loaded (stats.source != 0), so there is no black frame between
// the two. After that the texture stays; source changes (points re-sent, octree loaded) happen at
// an engine frame boundary with camera and style untouched (pwlod_viewer.h set_points comment).
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../official_util/device_log.dart';
import '../ui/official_capture/cloud_camera.dart';
import 'lod_bridge.dart';
import 'lod_camera.dart';
import 'lod_scene_fit.dart';

/// What the engine should draw.
@immutable
class GpuCloudSource {
  const GpuCloudSource({
    required this.xyz,
    required this.rgb,
    required this.colored,
    this.visibility,
    required this.boxMin,
    required this.boxMax,
    this.octreeDir,
  });

  /// The flat set (also the fallback when the octree cannot be loaded).
  final Float32List xyz;
  final Uint8List rgb;
  final bool colored;
  final Uint8List? visibility;

  /// Axis-aligned box of the flat set (Potree's far plane needs a scene box).
  final List<double> boxMin;
  final List<double> boxMax;

  /// Finished dense octree (Library/Caches/lod/<作品标识>/); null = draw the flat set.
  final String? octreeDir;

  bool sameFlatSetAs(GpuCloudSource o) =>
      identical(xyz, o.xyz) && identical(rgb, o.rgb) && identical(visibility, o.visibility) &&
      colored == o.colored;
}

class GpuCloudLayer extends ChangeNotifier {
  GpuCloudLayer({LodBridge? bridge, this.params = const LodParams(), this.statsPeriod = const Duration(milliseconds: 250)})
    : _bridge = bridge ?? LodBridge();

  final LodBridge _bridge;
  final LodParams params;
  final Duration statsPeriod;

  LodTextureInfo? _tex;
  bool _creating = false;
  bool _disposed = false;
  bool _failed = false;
  bool _published = false;

  Size _logical = Size.zero;
  double _dpr = 1;

  GpuCloudSource? _wantSource;
  GpuCloudSource? _sentFlat; // flat set the engine holds (null = none / octree only)
  String? _sentOctree; // octree the engine holds
  String? _octreeFailedFor; // octree dir that failed to load ⇒ stay flat
  bool _sourceInFlight = false;

  LodStyle? _wantStyle;
  LodStyle? _sentStyle;

  CloudProjection? _wantCamera;
  Size _wantCameraSize = Size.zero;
  Float64List? _sentCameraKey;
  bool _cameraInFlight = false;

  Timer? _statsTimer;
  LodFrameStats? _stats;
  double _lowestSpacing = double.infinity;
  final Map<bool, ({double near, double far})> _lastNearFar = {
    true: (near: kPotreeInitialNear, far: kPotreeInitialFar),
    false: (near: kPotreeInitialNear, far: kPotreeInitialFar),
  };
  List<double>? _octreeBoxMin, _octreeBoxMax;

  /// The texture to show, or null while the CPU painter must keep drawing (not created yet,
  /// nothing published yet, or failed).
  int? get textureId => (!_failed && _published) ? _tex?.textureId : null;

  bool get failed => _failed;

  /// 0 nothing, 1 flat set, 2 octree — from the latest published frame.
  int get publishedSource => _stats?.source ?? 0;

  @visibleForTesting
  LodFrameStats? get debugStats => _stats;

  @visibleForTesting
  String? get debugLoadedOctree => _sentOctree;

  // ── inputs (the view calls these from build; each is cheap when nothing changed) ──────────

  void setViewport(Size logical, double devicePixelRatio) {
    if (_failed || _disposed || logical.isEmpty) return;
    if (logical == _logical && devicePixelRatio == _dpr && _tex != null) return;
    _logical = logical;
    _dpr = devicePixelRatio;
    unawaited(_ensureTexture());
  }

  void setSource(GpuCloudSource source) {
    if (_failed || _disposed) return;
    _wantSource = source;
    _pumpSource();
  }

  void setStyle(LodStyle style) {
    if (_failed || _disposed) return;
    _wantStyle = style;
    _pumpStyle();
  }

  void setCamera(CloudProjection projection, Size logicalSize) {
    if (_failed || _disposed) return;
    _wantCamera = projection;
    _wantCameraSize = logicalSize;
    _pumpCamera();
  }

  // ── engine side ──────────────────────────────────────────────────────────────────────────

  Future<void> _ensureTexture() async {
    if (_creating || _disposed || _failed || _logical.isEmpty) return;
    final w = (_logical.width * _dpr).round(), h = (_logical.height * _dpr).round();
    if (w <= 0 || h <= 0) return;
    final old = _tex;
    if (old != null && old.widthPx == w && old.heightPx == h) return;
    _creating = true;
    try {
      if (old != null) {
        _tex = null;
        _published = false;
        if (!_disposed) notifyListeners();
        await _bridge.dispose(textureId: old.textureId);
      }
      final tex = await _bridge.create(widthPx: w, heightPx: h);
      if (_disposed) {
        await _bridge.dispose(textureId: tex.textureId);
        return;
      }
      _tex = tex;
      // A fresh viewer holds nothing: everything is re-sent.
      _sentFlat = null;
      _sentOctree = null;
      _sentStyle = null;
      _sentCameraKey = null;
      await _bridge.setParams(textureId: tex.textureId, params: params);
      _pumpStyle();
      _pumpCamera();
      _pumpSource();
      _statsTimer ??= Timer.periodic(statsPeriod, (_) => unawaited(_pollStats()));
    } catch (e) {
      _fail('create ${w}x$h', e);
    } finally {
      _creating = false;
      if (!_disposed && !_failed) {
        final t = _tex;
        final w2 = (_logical.width * _dpr).round(), h2 = (_logical.height * _dpr).round();
        if (t != null && (t.widthPx != w2 || t.heightPx != h2)) unawaited(_ensureTexture());
      }
    }
  }

  void _pumpStyle() {
    final tex = _tex, s = _wantStyle;
    if (tex == null || s == null || s == _sentStyle || _failed) return;
    _sentStyle = s;
    _bridge.setStyle(textureId: tex.textureId, style: s).catchError((Object e) => _fail('setStyle', e));
  }

  void _pumpSource() {
    final tex = _tex, want = _wantSource;
    if (tex == null || want == null || _sourceInFlight || _failed) return;
    final octree = want.octreeDir != null && want.octreeDir != _octreeFailedFor ? want.octreeDir : null;
    if (octree != null) {
      if (_sentOctree == octree) return;
      _sourceInFlight = true;
      unawaited(_loadOctree(tex, octree));
      return;
    }
    if (_sentOctree == null && _sentFlat != null && _sentFlat!.sameFlatSetAs(want)) return;
    _sourceInFlight = true;
    unawaited(_sendFlat(tex, want));
  }

  Future<void> _sendFlat(LodTextureInfo tex, GpuCloudSource s) async {
    try {
      await _bridge.setPoints(
        textureId: tex.textureId,
        xyz: s.xyz,
        rgb: s.rgb,
        colored: s.colored,
        visibility: s.visibility,
      );
      if (!identical(_tex, tex)) return;
      _sentFlat = s;
      _sentOctree = null;
    } catch (e) {
      _fail('setPoints n=${s.xyz.length ~/ 3}', e);
    } finally {
      _sourceInFlight = false;
      if (!_disposed) _pumpSource();
    }
  }

  Future<void> _loadOctree(LodTextureInfo tex, String dir) async {
    try {
      final fit = LodSceneFit.fromMetadataJson(await File('$dir/metadata.json').readAsString());
      await _bridge.loadOctree(textureId: tex.textureId, octreeDir: dir);
      if (!identical(_tex, tex)) return;
      _octreeBoxMin = fit.boxMin;
      _octreeBoxMax = fit.boxMax;
      _sentOctree = dir;
      _sentFlat = null;
      _sentCameraKey = null; // the scene box changed ⇒ Potree far plane changes
      _pumpCamera();
      DeviceLog.log('GpuCloudLayer', 'octree loaded: $dir');
    } catch (e) {
      // 「建树失败或自检不过时，保持平铺显示」: the flat set stays (or is re-sent).
      _octreeFailedFor = dir;
      DeviceLog.log('GpuCloudLayer', 'octree load failed, staying on the flat set: $dir: $e');
    } finally {
      _sourceInFlight = false;
      if (!_disposed) _pumpSource();
    }
  }

  void _pumpCamera() {
    final tex = _tex, proj = _wantCamera, src = _wantSource;
    if (tex == null || proj == null || src == null || _failed) return;
    if (_cameraInFlight) return;
    final ortho = proj.orthoMix == 1.0;
    final useOctreeBox = _sentOctree != null && _octreeBoxMin != null;
    final frame = lodCameraFrame(
      projection: proj,
      logicalSize: _wantCameraSize,
      viewportWidthPx: tex.widthPx,
      viewportHeightPx: tex.heightPx,
      sceneBoxMin: useOctreeBox ? _octreeBoxMin! : src.boxMin,
      sceneBoxMax: useOctreeBox ? _octreeBoxMax! : src.boxMax,
      lowestSpacing: _lowestSpacing,
      previousNear: _lastNearFar[ortho]!.near,
      previousFar: _lastNearFar[ortho]!.far,
    );
    final key = Float64List.fromList([
      ...frame.viewProjRowMajor,
      frame.focalPx,
      frame.orbitDistance,
      frame.orthoMix,
      frame.viewportWidthPx.toDouble(),
      frame.viewportHeightPx.toDouble(),
    ]);
    if (_sameKey(key, _sentCameraKey)) return;
    _lastNearFar[ortho] = (near: frame.near, far: frame.far);
    _sentCameraKey = key;
    _cameraInFlight = true;
    _bridge
        .setCamera(textureId: tex.textureId, camera: frame)
        .catchError((Object e) => _fail('setCamera', e))
        .whenComplete(() {
          _cameraInFlight = false;
          if (!_disposed) _pumpCamera(); // newest state wins
        });
  }

  static bool _sameKey(Float64List a, Float64List? b) {
    if (b == null || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _pollStats() async {
    final tex = _tex;
    if (tex == null || _disposed || _failed) return;
    try {
      final s = await _bridge.stats(textureId: tex.textureId);
      if (_disposed || s == null || !identical(_tex, tex)) return;
      _stats = s;
      if (!_published && s.source != 0 && s.frameNumber > 0) {
        _published = true;
        DeviceLog.log('GpuCloudLayer', 'first frame published (source ${s.source}, ${tex.widthPx}x${tex.heightPx}, ${tex.version})');
        notifyListeners();
      }
      final ls = potreeLowestSpacingFromStats(s.lowestSpacing);
      if (ls != _lowestSpacing) {
        _lowestSpacing = ls;
        _sentCameraKey = null;
        _pumpCamera();
      }
    } catch (_) {
      // stats are diagnostics; a failed poll is not an error state
    }
  }

  void _fail(String what, Object e) {
    if (_failed || _disposed) return;
    _failed = true;
    final quiet = e is MissingPluginException;
    DeviceLog.log('GpuCloudLayer', 'GPU viewer off, CPU painter keeps drawing ($what): ${quiet ? 'no plugin' : e}');
    _statsTimer?.cancel();
    _statsTimer = null;
    final tex = _tex;
    _tex = null;
    _published = false;
    if (tex != null) unawaited(_bridge.dispose(textureId: tex.textureId).catchError((Object _) {}));
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _statsTimer?.cancel();
    final tex = _tex;
    _tex = null;
    if (tex != null) unawaited(_bridge.dispose(textureId: tex.textureId).catchError((Object _) {}));
    super.dispose();
  }
}
