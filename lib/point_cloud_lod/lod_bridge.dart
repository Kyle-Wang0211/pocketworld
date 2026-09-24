// lod_bridge.dart — Dart side of the `pw_lod_texture` MethodChannel (plan L4).
//
// Shape copied from the in-house texture renderer's binding,
// lib/aether_view/scene_bridge.dart @875fe67:
//   :10-18  why MethodChannel and not Dart FFI for a Texture path — FlutterTexture
//           registration has to be native, so the shell owns the texture and this file
//           only marshals;
//   :71     `static const _channel = MethodChannel('aether_texture')` (same form here).
// Not `DynamicLibrary.process()`: the shell links the engine statically and talks to it
// directly (plan §2 L4), so no exported-symbol allow-list has to change.
//
// Wire contract (the native shell — ios/Runner/PwLodTexturePlugin.swift today, Android /
// HarmonyOS shells later — implements the same map keys):
//   * the texture handle is 'textureId' (as in scene_bridge.dart);
//   * every struct field travels under its C field name from the frozen
//     vendor/aether_lod/include/pwlod_viewer.h (pwlod_camera, pwlod_params,
//     pwlod_frame_stats, pwlod_build_report, pwlod_verify_report). A test parses that
//     header and fails if a key and a field ever diverge.
//   * errors come back as PlatformException whose code is the pwlod_status name
//     (e.g. 'PWLOD_ERR_GPU'), or a shell code for shell-side failures.
//
// No platform type appears here; the file is shared by every shell.
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'lod_camera.dart';

const String kPwLodChannel = 'pw_lod_texture';

/// pwlod_status (pwlod_viewer.h:37-45); index = C value.
const List<String> kPwLodStatusNames = <String>[
  'PWLOD_OK',
  'PWLOD_ERR_ARG',
  'PWLOD_ERR_IO',
  'PWLOD_ERR_FORMAT',
  'PWLOD_ERR_GPU',
  'PWLOD_ERR_STATE',
  'PWLOD_ERR_NOMEM',
];

/// octree.bin bytes per point: int32 xyz (12) + uint16 rgb (6)
/// (pwlod_viewer.h:194 "C1: must equal 18 * tree_points").
const int kPwLodBytesPerPoint = 18;

int _int(Map<Object?, Object?> m, String k) {
  final v = m[k];
  if (v is int) return v;
  if (v is num && v == v.roundToDouble()) return v.toInt();
  throw FormatException('pw_lod_texture: "$k" missing or not an integer', m);
}

double _double(Map<Object?, Object?> m, String k) {
  final v = m[k];
  if (v is num) return v.toDouble();
  throw FormatException('pw_lod_texture: "$k" missing or not a number', m);
}

Map<Object?, Object?> _map(Object? raw, String what) {
  if (raw is Map) return raw;
  throw FormatException('pw_lod_texture: $what returned ${raw.runtimeType}');
}

/// pwlod_viewer.h:93 default point budget (= pw_splat_ab_bench Sources/lod/pw_lod_bench.cpp:60
/// @2f83c6b5 `Args.budget`, "(33.3 - 0.20) / 9.12 ms per M on A16").
const int kLodDefaultPointBudget = 3630000;

/// pwlod_viewer.h:97: node cache "default and minimum 15 * point_budget" (bytes per budget point).
const int kLodNodeCacheBytesPerBudgetPoint = 15;

/// pw_splat_ab_bench Sources/lod/pw_lod_bench.cpp:61 @2f83c6b5
/// `double cache_mult = 3.0;  // NodeCache = cache_mult * 15 B * budget` — the multiplier every
/// Mac bench measurement ran with, i.e. 45 B per budget point, not the header's 15 B minimum.
const int kLodBenchCacheMult = 3;

/// cache_bytes the shell sends with every setParams: 3 × 15 × point_budget.
int lodBenchCacheBytes(int pointBudget) =>
    kLodBenchCacheMult * kLodNodeCacheBytesPerBudgetPoint * pointBudget;

/// pwlod_params (pwlod_viewer.h:92-102). The shell starts from pwlod_params_default() and
/// overrides the keys present. point_budget and cache_bytes are ALWAYS present:
/// point_budget = [pointBudget] ?? kLodDefaultPointBudget and cache_bytes = [cacheBytes] ??
/// lodBenchCacheBytes(point_budget), so the engine never falls back to the 15× header default
/// (coordinator decision 2026-09-24: run what the Mac bench measured).
class LodParams {
  const LodParams({
    this.pointBudget,
    this.targetFrameMs,
    this.pointSizeMode,
    this.asyncLoading,
    this.cacheBytes,
    this.backgroundRgba,
    this.debugRenderSleepMs,
    this.debugPublishBeforeDone,
  });

  final int? pointBudget;
  final double? targetFrameMs;

  /// pwlod_point_size_mode: 0 FIXED (measurement arm only), 1 ADAPTIVE.
  final int? pointSizeMode;
  final bool? asyncLoading;
  final int? cacheBytes;
  final List<double>? backgroundRgba;

  /// Negative-control switches for the plan 3b judges; never set in a product.
  final int? debugRenderSleepMs;
  final bool? debugPublishBeforeDone;

  Map<String, Object> toWire() {
    final bg = backgroundRgba;
    if (bg != null && bg.length != 4) {
      throw ArgumentError.value(bg, 'backgroundRgba', 'needs 4 components');
    }
    final budget = pointBudget ?? kLodDefaultPointBudget;
    return <String, Object>{
      'point_budget': budget,
      'target_frame_ms': ?targetFrameMs,
      'point_size_mode': ?pointSizeMode,
      if (asyncLoading != null) 'async_loading': asyncLoading! ? 1 : 0,
      'cache_bytes': cacheBytes ?? lodBenchCacheBytes(budget),
      if (bg != null) 'background_rgba': Float64List.fromList(bg),
      'debug_render_sleep_ms': ?debugRenderSleepMs,
      if (debugPublishBeforeDone != null)
        'debug_publish_before_done': debugPublishBeforeDone! ? 1 : 0,
    };
  }
}

/// pwlod_frame_stats (pwlod_viewer.h:104-119, ABI v2).
class LodFrameStats {
  const LodFrameStats({
    required this.frameNumber,
    required this.completedFrameNumber,
    required this.pointsDrawn,
    required this.nodesDrawn,
    required this.nodesLoading,
    required this.uploadsThisFrame,
    required this.droppedForCache,
    required this.minNodePixelSize,
    required this.cpuMs,
    required this.gpuMs,
    required this.lowestSpacing,
    this.shell = const <String, Object?>{},
  });

  final int frameNumber;
  final int completedFrameNumber;
  final int pointsDrawn;
  final int nodesDrawn;
  final int nodesLoading;
  final int uploadsThisFrame;
  final int droppedForCache;
  final double minNodePixelSize;
  final double cpuMs;

  /// -1 if not yet known.
  final double gpuMs;

  /// v2: Potree's per-frame lowestSpacing (smallest spacing among the nodes drawn this
  /// frame); <= 0 if none were drawn (pwlod_viewer.h:115-118). Feeds potreeNearFar.
  final double lowestSpacing;

  /// Shell-side counters, not part of pwlod_frame_stats (iOS: copy_calls, copy_empty,
  /// last_acquired_frame_number, copy_max_us, frames_ready, running) — for the plan 3b judges.
  final Map<String, Object?> shell;

  static LodFrameStats fromWire(Map<Object?, Object?> m) => LodFrameStats(
    frameNumber: _int(m, 'frame_number'),
    completedFrameNumber: _int(m, 'completed_frame_number'),
    pointsDrawn: _int(m, 'points_drawn'),
    nodesDrawn: _int(m, 'nodes_drawn'),
    nodesLoading: _int(m, 'nodes_loading'),
    uploadsThisFrame: _int(m, 'uploads_this_frame'),
    droppedForCache: _int(m, 'dropped_for_cache'),
    minNodePixelSize: _double(m, 'min_node_pixel_size'),
    cpuMs: _double(m, 'cpu_ms'),
    gpuMs: _double(m, 'gpu_ms'),
    lowestSpacing: _double(m, 'lowest_spacing'),
    shell: m['shell'] is Map
        ? Map<String, Object?>.from(m['shell'] as Map)
        : const <String, Object?>{},
  );
}

/// What `create` returns.
class LodTextureInfo {
  const LodTextureInfo({
    required this.textureId,
    required this.version,
    required this.backend,
    required this.widthPx,
    required this.heightPx,
  });
  final int textureId;

  /// pwlod_version(): `"<engine git sha8> abi=1"`.
  final String version;

  /// WGPUBackendType the engine's device got.
  final int backend;
  final int widthPx;
  final int heightPx;
}

/// pwlod_build_report (pwlod_viewer.h:191-197) + the shell's own measurements.
class LodBuildReport {
  const LodBuildReport({
    required this.status,
    required this.error,
    required this.plyPoints,
    required this.treePoints,
    required this.octreeBinBytes,
    required this.nodes,
    required this.elapsedMs,
    required this.shellWallMs,
    required this.peakFootprintMb,
    required this.baselineFootprintMb,
    required this.footprintSamples,
    required this.chunkDirRemoved,
  });

  /// pwlod_status name.
  final String status;
  final String error;
  final int plyPoints;
  final int treePoints;
  final int octreeBinBytes;
  final int nodes;
  final double elapsedMs;

  /// Shell-side: wall clock around the blocking call, phys_footprint peak / before
  /// (the header leaves peak memory to the shell, pwlod_viewer.h:201-202), how many
  /// footprint samples the peak is over, whether the scratch chunk_dir was deleted.
  final double shellWallMs;
  final double peakFootprintMb;
  final double baselineFootprintMb;
  final int footprintSamples;
  final bool chunkDirRemoved;

  static LodBuildReport fromWire(Map<Object?, Object?> m) => LodBuildReport(
    status: (m['status'] as String?) ?? 'missing',
    error: (m['error'] as String?) ?? '',
    plyPoints: _int(m, 'ply_points'),
    treePoints: _int(m, 'tree_points'),
    octreeBinBytes: _int(m, 'octree_bin_bytes'),
    nodes: _int(m, 'nodes'),
    elapsedMs: _double(m, 'elapsed_ms'),
    shellWallMs: _double(m, 'shell_wall_ms'),
    peakFootprintMb: _double(m, 'peak_footprint_mb'),
    baselineFootprintMb: _double(m, 'baseline_footprint_mb'),
    footprintSamples: _int(m, 'footprint_samples'),
    chunkDirRemoved: m['chunk_dir_removed'] == true,
  );

  Map<String, Object> toJson() => <String, Object>{
    'status': status,
    'error': error,
    'ply_points': plyPoints,
    'tree_points': treePoints,
    'octree_bin_bytes': octreeBinBytes,
    'nodes': nodes,
    'elapsed_ms': elapsedMs,
    'shell_wall_ms': shellWallMs,
    'peak_footprint_mb': peakFootprintMb,
    'baseline_footprint_mb': baselineFootprintMb,
    'footprint_samples': footprintSamples,
    'chunk_dir_removed': chunkDirRemoved,
  };
}

/// pwlod_verify_report (pwlod_viewer.h:217-225) + the call's status.
class LodVerifyReport {
  const LodVerifyReport({
    required this.status,
    required this.treePoints,
    required this.octreeBinBytes,
    required this.nodes,
    required this.leaves,
    required this.leavesSelected,
    required this.byteGaps,
    required this.byteOverlaps,
  });

  final String status;
  final int treePoints;
  final int octreeBinBytes;
  final int nodes;
  final int leaves;
  final int leavesSelected;
  final int byteGaps;
  final int byteOverlaps;

  static LodVerifyReport fromWire(Map<Object?, Object?> m) => LodVerifyReport(
    status: (m['status'] as String?) ?? 'missing',
    treePoints: _int(m, 'tree_points'),
    octreeBinBytes: _int(m, 'octree_bin_bytes'),
    nodes: _int(m, 'nodes'),
    leaves: _int(m, 'leaves'),
    leavesSelected: _int(m, 'leaves_selected'),
    byteGaps: _int(m, 'byte_gaps'),
    byteOverlaps: _int(m, 'byte_overlaps'),
  );

  Map<String, Object> toJson() => <String, Object>{
    'status': status,
    'tree_points': treePoints,
    'octree_bin_bytes': octreeBinBytes,
    'nodes': nodes,
    'leaves': leaves,
    'leaves_selected': leavesSelected,
    'byte_gaps': byteGaps,
    'byte_overlaps': byteOverlaps,
  };
}

/// One C1/C2/S2 judgement with the numbers it was made on.
class LodCheck {
  const LodCheck(this.name, this.pass, this.detail);
  final String name;
  final bool pass;
  final String detail;
  Map<String, Object> toJson() => <String, Object>{
    'name': name,
    'pass': pass,
    'detail': detail,
  };
}

/// Plan L6 C1: points on disk not fewer than in the PLY, and octree.bin is exactly
/// 18 bytes per tree point. Uses only the build report (task spec).
LodCheck judgeC1(LodBuildReport r) {
  final ok =
      r.status == 'PWLOD_OK' &&
      r.plyPoints > 0 &&
      r.treePoints == r.plyPoints &&
      r.octreeBinBytes == kPwLodBytesPerPoint * r.treePoints;
  return LodCheck(
    'C1',
    ok,
    'status=${r.status} ply_points=${r.plyPoints} tree_points=${r.treePoints} '
        'octree_bin_bytes=${r.octreeBinBytes} '
        '(18*tree_points=${kPwLodBytesPerPoint * r.treePoints})',
  );
}

/// Plan L6 C2 + S2 from the on-device verify, plus the cross-check that verify reads
/// back the same tree the build reported.
List<LodCheck> judgeVerify(LodVerifyReport v, {LodBuildReport? build}) {
  final c2 = v.byteGaps == 0 && v.byteOverlaps == 0 && v.status == 'PWLOD_OK';
  final s2 =
      v.leaves > 0 && v.leavesSelected == v.leaves && v.status == 'PWLOD_OK';
  final out = <LodCheck>[
    LodCheck(
      'C2',
      c2,
      'byte_gaps=${v.byteGaps} byte_overlaps=${v.byteOverlaps} '
          'status=${v.status}',
    ),
    LodCheck(
      'S2',
      s2,
      'leaves_selected=${v.leavesSelected} leaves=${v.leaves} '
          'status=${v.status}',
    ),
  ];
  if (build != null) {
    final same =
        v.treePoints == build.treePoints &&
        v.octreeBinBytes == build.octreeBinBytes &&
        v.nodes == build.nodes;
    out.add(
      LodCheck(
        'build==verify',
        same,
        'tree_points ${build.treePoints}/${v.treePoints} '
            'octree_bin_bytes ${build.octreeBinBytes}/${v.octreeBinBytes} '
            'nodes ${build.nodes}/${v.nodes}',
      ),
    );
  }
  return out;
}

/// What `runBench` (plan M1, pwlod_run) returns.
class LodBenchResult {
  const LodBenchResult({
    required this.result,
    required this.resultIsFile,
    required this.wallMs,
    required this.probeStart,
    required this.probeEnd,
    required this.version,
  });

  /// pwlod_run's return: the result JSON path, or a diagnostic string on failure.
  final String result;
  final bool resultIsFile;
  final double wallMs;

  /// PwLodProbeSample before / after, as {thermal_state, footprint_mb, avail_mb}.
  final Map<String, Object?> probeStart;
  final Map<String, Object?> probeEnd;
  final String version;

  static LodBenchResult fromWire(Map<Object?, Object?> m) => LodBenchResult(
    result: (m['result'] as String?) ?? '',
    resultIsFile: m['result_is_file'] == true,
    wallMs: _double(m, 'wall_ms'),
    probeStart: Map<String, Object?>.from(
      _map(m['probe_start'], 'probe_start'),
    ),
    probeEnd: Map<String, Object?>.from(_map(m['probe_end'], 'probe_end')),
    version: (m['version'] as String?) ?? '',
  );
}

class LodBridge {
  LodBridge({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel(kPwLodChannel);

  final MethodChannel _channel;

  /// Creates the engine's GPU + a viewer + a ring of PWLOD_TARGET_COUNT render targets
  /// of exactly [widthPx]×[heightPx] physical pixels, starts the render thread, and
  /// registers the Flutter texture.
  Future<LodTextureInfo> create({
    required int widthPx,
    required int heightPx,
  }) async {
    if (widthPx <= 0 || heightPx <= 0) {
      throw ArgumentError('viewport must be positive: ${widthPx}x$heightPx');
    }
    final raw = await _channel.invokeMethod<Object?>('create', <String, Object>{
      'viewport_width_px': widthPx,
      'viewport_height_px': heightPx,
    });
    final m = _map(raw, 'create');
    return LodTextureInfo(
      textureId: _int(m, 'textureId'),
      version: (m['version'] as String?) ?? '',
      backend: _int(m, 'backend'),
      widthPx: _int(m, 'viewport_width_px'),
      heightPx: _int(m, 'viewport_height_px'),
    );
  }

  /// pwlod_viewer_load_octree; the shell runs it off the platform thread.
  Future<void> loadOctree({
    required int textureId,
    required String octreeDir,
  }) => _channel.invokeMethod<void>('loadOctree', <String, Object>{
    'textureId': textureId,
    'octree_dir': octreeDir,
  });

  /// Wire form of pwlod_camera. Exposed for the wire test.
  static Map<String, Object> cameraToWire(int textureId, LodCameraFrame f) {
    for (final v in f.viewProjRowMajor) {
      if (!v.isFinite) throw ArgumentError('view_proj_row_major not finite');
    }
    return <String, Object>{
      'textureId': textureId,
      // Row-major world -> clip, element [r*4+c]; copied, never reordered.
      'view_proj_row_major': Float64List.fromList(f.viewProjRowMajor),
      'eye_world': Float64List.fromList(f.eyeWorld),
      'projection': f.projection.wireValue,
      'fov_y_degrees': f.fovYDegrees,
      'ortho_width_world': f.orthoWidthWorld,
      'ortho_height_world': f.orthoHeightWorld,
      'viewport_width_px': f.viewportWidthPx,
      'viewport_height_px': f.viewportHeightPx,
    };
  }

  /// pwlod_viewer_set_camera — called from the gesture handler on every change.
  Future<void> setCamera({
    required int textureId,
    required LodCameraFrame camera,
  }) =>
      _channel.invokeMethod<void>('setCamera', cameraToWire(textureId, camera));

  Future<void> setParams({required int textureId, required LodParams params}) =>
      _channel.invokeMethod<void>('setParams', <String, Object>{
        'textureId': textureId,
        ...params.toWire(),
      });

  /// Stats of the latest published frame; null before the first frame.
  Future<LodFrameStats?> stats({required int textureId}) async {
    final raw = await _channel.invokeMethod<Object?>('stats', <String, Object>{
      'textureId': textureId,
    });
    if (raw == null) return null;
    return LodFrameStats.fromWire(_map(raw, 'stats'));
  }

  /// pwlod_build_from_ply on a background queue in the shell; [chunkDir] is scratch the
  /// shell deletes afterwards. 0 for budget/threads = library defaults.
  Future<LodBuildReport> buildFromPly({
    required String plyPath,
    required String outDir,
    required String chunkDir,
    int memoryBudgetMb = 0,
    int threads = 0,
  }) async {
    final raw = await _channel
        .invokeMethod<Object?>('buildFromPly', <String, Object>{
          'ply_path': plyPath,
          'out_dir': outDir,
          'chunk_dir': chunkDir,
          'memory_budget_mb': memoryBudgetMb,
          'threads': threads,
        });
    return LodBuildReport.fromWire(_map(raw, 'buildFromPly'));
  }

  Future<LodVerifyReport> verifyOctree({required String octreeDir}) async {
    final raw = await _channel.invokeMethod<Object?>(
      'verifyOctree',
      <String, Object>{'octree_dir': octreeDir},
    );
    return LodVerifyReport.fromWire(_map(raw, 'verifyOctree'));
  }

  /// Plan M1: pwlod_run(octree_dir, out_dir, args, probe, NULL) on a background queue.
  Future<LodBenchResult> runBench({
    required String octreeDir,
    required String outDir,
    required String args,
  }) async {
    final raw = await _channel.invokeMethod<Object?>(
      'runBench',
      <String, Object>{
        'octree_dir': octreeDir,
        'out_dir': outDir,
        'args': args,
      },
    );
    return LodBenchResult.fromWire(_map(raw, 'runBench'));
  }

  Future<void> dispose({required int textureId}) => _channel.invokeMethod<void>(
    'dispose',
    <String, Object>{'textureId': textureId},
  );

  /// `-PWLod*` process launch arguments (detached `devicectl ... launch -- -PWLodX v`),
  /// keys without the leading dash. Empty map when none.
  Future<Map<String, String>> launchArgs() async {
    final raw = await _channel.invokeMethod<Object?>('launchArgs');
    if (raw is! Map) return <String, String>{};
    return <String, String>{
      for (final e in raw.entries)
        if (e.key is String && e.value is String)
          e.key as String: e.value as String,
    };
  }
}
