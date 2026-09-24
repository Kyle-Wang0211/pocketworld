// dense_lod_cache.dart — the finished dense cloud's octree, built on the phone and kept in the
// system cache directory.
//
//   <cache>/lod/<作品标识>/            metadata.json, hierarchy.bin, octree.bin (Potree 2.0, built by
//                                      pwlod_build_from_ply) + pw_lod_source.json (this file's stamp)
//   <cache>/lod/<作品标识>.building/   the tree while it is being built (renamed into place)
//   <cache>/lod/<作品标识>.chunks/     pwlod_build_from_ply's scratch (the shell deletes it)
// <cache> = path_provider getApplicationCacheDirectory() (iOS Library/Caches), the directory the
// user chose for review caches on 2026-09-23 (feat/review-cloud-cache-on-dense-stage-168 aeb024b):
// derived data, rebuildable, never in captures_official/<cap_id>/ (install gate B counts that
// directory's entries), may be purged by the system at any time ⇒ rebuilt next time.
//
// Staleness = the review cache's rule, copied (902c509 review_cloud_cache.dart
// ReviewCloudCache.decode + 87b33dc 「内容换了拿新云」): a tree is used only if its stamp records
// the same format version, the same source path (hash), the same source byte length and the same
// source mtime (ms) as the PLY on disk now; anything else ⇒ rebuild. Added for trees: the engine
// identity (a new engine artifact may write a different tree) and the on-disk C1 re-check
// (octree.bin == 18 · tree_points, tree_points == the PLY header's vertex count).
// Pruning = the review cache's too (ReviewCloudCache.prune): at most [kMaxEntries] trees, oldest
// stamp first; `.building` / `.chunks` leftovers older than [kTmpStaleAfter] are removed; nothing
// outside <cache>/lod/ is ever touched.
//
// Gate before a tree is shown (coordinator 2026-09-24): pwlod_build_from_ply, then
// pwlod_verify_octree; C1 judged against the PLY's vertex count read HERE from the header
// (tree_points == ply points && octree_bin_bytes == 18·tree_points), C2 (no byte gap/overlap) and
// S2 (every leaf selectable) from the verify report, and build == verify. Any failure ⇒ no tree,
// the view keeps drawing the flat 1 M sample, the reason goes to the device log.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../official_util/device_log.dart';
import 'lod_bridge.dart';

/// The engine archive this build links (`vendor/aether_lod/libs/ios-arm64/libpw_lod_<sha8>.a`); a
/// test pins it to the vendored receipt. Part of every stamp: a different engine ⇒ rebuild.
const String kLodEngineSha8 = '72ee817f';
const int kLodEngineAbi = 3;

enum DenseLodPhase { building, ready, failed }

@immutable
class DenseLodState {
  const DenseLodState._(this.phase, {this.octreeDir, this.message});
  const DenseLodState.building() : this._(DenseLodPhase.building);
  const DenseLodState.ready(String dir) : this._(DenseLodPhase.ready, octreeDir: dir);
  const DenseLodState.failed(String why) : this._(DenseLodPhase.failed, message: why);

  final DenseLodPhase phase;

  /// Set only when [phase] is ready.
  final String? octreeDir;
  final String? message;

  @override
  String toString() => 'DenseLodState($phase${octreeDir != null ? ' $octreeDir' : ''}${message != null ? ' $message' : ''})';
}

/// `element vertex N` of a binary PLY header (first 4 KB), null if unreadable. The native builder
/// validates the rest of the format (build.h openPly).
int? plyVertexCount(String path) {
  try {
    final raf = File(path).openSync();
    try {
      final head = raf.readSync(4096);
      final text = latin1.decode(head, allowInvalid: true);
      final end = text.indexOf('end_header');
      if (!text.startsWith('ply') || end < 0) return null;
      final m = RegExp(r'element vertex (\d+)').firstMatch(text.substring(0, end));
      return m == null ? null : int.parse(m.group(1)!);
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return null;
  }
}

class DenseLodCache {
  DenseLodCache({
    LodBridge? bridge,
    Future<Directory?> Function()? cacheRoot,
    DateTime Function() clock = DateTime.now,
  }) : _bridge = bridge ?? LodBridge(),
       _cacheRoot = cacheRoot ?? _defaultRoot,
       _clock = clock;

  static DenseLodCache _instance = DenseLodCache();

  /// The app's cache (the capture page and the viewer page share it, so they share one build).
  static DenseLodCache get instance => _instance;

  /// Tests swap in a cache with a temp root and a mocked bridge.
  @visibleForTesting
  static set instanceForTesting(DenseLodCache c) => _instance = c;

  static const String kDirName = 'lod';
  static const String kStampName = 'pw_lod_source.json';

  /// Bump when the stamp's meaning or the build call changes.
  static const int kFormatVersion = 1;

  /// ReviewCloudCache.kMaxEntries / kTmpStaleAfter (902c509).
  static const int kMaxEntries = 8;
  static const Duration kTmpStaleAfter = Duration(hours: 1);

  final LodBridge _bridge;
  final Future<Directory?> Function() _cacheRoot;
  final DateTime Function() _clock;

  final Map<String, ValueNotifier<DenseLodState>> _states = {};

  /// PLY identity a build already failed for: not retried until the PLY changes (a tree that
  /// cannot pass its self-check would otherwise be rebuilt on every visit).
  final Map<String, String> _failedFor = {};
  Future<void> _queue = Future<void>.value(); // one build at a time

  /// Completes when every queued check/build has finished (tests).
  @visibleForTesting
  Future<void> whenIdle() => _queue;

  static Future<Directory?> _defaultRoot() async {
    try {
      final c = await getApplicationCacheDirectory();
      return Directory('${c.path}/$kDirName');
    } catch (_) {
      return null;
    }
  }

  /// `<作品标识>` = the capture directory's name (e.g. cap_1788832166373381); anything unusual falls
  /// back to the review cache's 64-bit FNV-1a of the path (ReviewCloudCache.keyFor).
  static String keyFor(String plyPath) {
    final parent = File(plyPath).parent.path.split(Platform.pathSeparator).last;
    if (RegExp(r'^[A-Za-z0-9_.-]{1,96}$').hasMatch(parent) && parent != '.' && parent != '..') {
      return parent;
    }
    var hash = 0xcbf29ce484222325;
    for (final unit in plyPath.codeUnits) {
      hash ^= unit & 0xFF;
      hash *= 0x100000001b3;
      if (unit > 0xFF) {
        hash ^= (unit >> 8) & 0xFF;
        hash *= 0x100000001b3;
      }
    }
    final hi = (hash >> 32) & 0xFFFFFFFF, lo = hash & 0xFFFFFFFF;
    return 'p${hi.toRadixString(16).padLeft(8, '0')}${lo.toRadixString(16).padLeft(8, '0')}';
  }

  static int _pathHash32(String path) {
    var hash = 0x811c9dc5;
    for (final unit in path.codeUnits) {
      hash = ((hash ^ (unit & 0xFF)) * 0x01000193) & 0xFFFFFFFF;
      if (unit > 0xFF) hash = ((hash ^ ((unit >> 8) & 0xFF)) * 0x01000193) & 0xFFFFFFFF;
    }
    return hash;
  }

  /// The tree state for [densePlyPath]; starts (or reuses) the check/build. The same notifier is
  /// returned for the same path, so the capture page and the viewer page share one build.
  ValueListenable<DenseLodState> watch(String densePlyPath) {
    final existing = _states[densePlyPath];
    if (existing != null) {
      // A finished tree may have gone stale (dense re-run); a failure is retried only for a new PLY.
      if (existing.value.phase != DenseLodPhase.building) unawaited(_ensure(densePlyPath, existing));
      return existing;
    }
    final n = ValueNotifier<DenseLodState>(const DenseLodState.building());
    _states[densePlyPath] = n;
    unawaited(_ensure(densePlyPath, n));
    return n;
  }

  Future<void> _ensure(String ply, ValueNotifier<DenseLodState> out) {
    final run = _queue.then((_) async {
      try {
        out.value = await _ensureNow(ply, out);
      } catch (e) {
        DeviceLog.log('DenseLodCache', 'unexpected: $e');
        out.value = DenseLodState.failed('$e');
      }
    });
    _queue = run.catchError((Object _) {});
    return run;
  }

  Future<DenseLodState> _ensureNow(String ply, ValueNotifier<DenseLodState> out) async {
    final root = await _cacheRoot();
    if (root == null) return _failed(ply, 'no cache directory');
    final src = File(ply);
    if (!src.existsSync()) return _failed(ply, 'PLY missing');
    final stat = src.statSync();
    final plyPoints = plyVertexCount(ply);
    if (plyPoints == null || plyPoints <= 0) return _failed(ply, 'PLY header unreadable');
    final key = keyFor(ply);
    final identity = '${stat.size}|${stat.modified.millisecondsSinceEpoch}|$plyPoints';
    final tree = Directory('${root.path}/$key');
    final _SourceId source = (
      path: ply,
      bytes: stat.size,
      mtimeMs: stat.modified.millisecondsSinceEpoch,
      points: plyPoints,
    );
    if (isValidTree(tree, source)) {
      _touch(tree);
      return DenseLodState.ready(tree.path);
    }
    if (_failedFor[ply] == identity) {
      return DenseLodState.failed('previous build of this PLY failed (not retried)');
    }
    out.value = const DenseLodState.building();
    root.createSync(recursive: true);
    _prune(root, keep: key);
    final tmp = Directory('${root.path}/$key.building');
    final chunks = Directory('${root.path}/$key.chunks');
    for (final d in [tmp, chunks]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
    final started = _clock();
    DeviceLog.log('DenseLodCache', 'build start $key: $plyPoints pts, ${stat.size} B');
    final build = await _bridge.buildFromPly(plyPath: ply, outDir: tmp.path, chunkDir: chunks.path);
    try {
      if (chunks.existsSync()) chunks.deleteSync(recursive: true);
    } catch (_) {}
    final c1 = judgeC1(build);
    final c1Ply = build.plyPoints == plyPoints;
    final checks = <LodCheck>[
      c1,
      LodCheck('C1-ply-header', c1Ply, 'dart header $plyPoints vs build ply_points ${build.plyPoints}'),
    ];
    LodVerifyReport? verify;
    if (c1.pass && c1Ply) {
      verify = await _bridge.verifyOctree(octreeDir: tmp.path);
      checks.addAll(judgeVerify(verify, build: build));
    }
    final pass = verify != null && checks.every((c) => c.pass);
    final detail = checks.where((c) => !c.pass).map((c) => '${c.name}: ${c.detail}').join('; ');
    if (!pass) {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
      } catch (_) {}
      _failedFor[ply] = identity;
      return _failed(ply, 'tree rejected (${build.status} ${build.error}) $detail');
    }
    File('${tmp.path}/$kStampName').writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        'schema': 'pw_lod_source/1',
        'format_version': kFormatVersion,
        'engine': '$kLodEngineSha8 abi=$kLodEngineAbi',
        'ply_path': ply,
        'ply_path_hash32': _pathHash32(ply),
        'ply_bytes': source.bytes,
        'ply_mtime_ms': source.mtimeMs,
        'ply_points': plyPoints,
        'started': started.toIso8601String(),
        'finished': _clock().toIso8601String(),
        'build': build.toJson(),
        'verify': verify.toJson(),
        'checks': [for (final c in checks) c.toJson()],
        'pass': true,
      }),
      flush: true,
    );
    if (tree.existsSync()) tree.deleteSync(recursive: true);
    tmp.renameSync(tree.path);
    DeviceLog.log(
      'DenseLodCache',
      'build ok $key: ${build.treePoints} pts, ${build.nodes} nodes, ${build.elapsedMs.toStringAsFixed(0)} ms, '
          'peak ${build.peakFootprintMb.toStringAsFixed(0)} MB, leaves ${verify.leavesSelected}/${verify.leaves}',
    );
    return DenseLodState.ready(tree.path);
  }

  DenseLodState _failed(String ply, String why) {
    DeviceLog.log('DenseLodCache', 'no tree for $ply (flat display stays): $why');
    return DenseLodState.failed(why);
  }

  /// The stamp matches [source] (ReviewCloudCache.decode's rule: version, path hash, byte length,
  /// mtime) + engine identity + the three tree files + on-disk C1.
  @visibleForTesting
  static bool isValidTree(Directory tree, ({String path, int bytes, int mtimeMs, int points}) source) {
    try {
      final stamp = File('${tree.path}/$kStampName');
      if (!stamp.existsSync()) return false;
      final j = jsonDecode(stamp.readAsStringSync());
      if (j is! Map) return false;
      if (j['format_version'] != kFormatVersion) return false;
      if (j['engine'] != '$kLodEngineSha8 abi=$kLodEngineAbi') return false;
      if (j['pass'] != true) return false;
      if (j['ply_path_hash32'] != _pathHash32(source.path)) return false;
      if (j['ply_bytes'] != source.bytes) return false;
      if (j['ply_mtime_ms'] != source.mtimeMs) return false;
      if (j['ply_points'] != source.points) return false;
      for (final f in ['metadata.json', 'hierarchy.bin', 'octree.bin']) {
        if (!File('${tree.path}/$f').existsSync()) return false;
      }
      final build = j['build'];
      if (build is! Map) return false;
      final treePoints = build['tree_points'];
      if (treePoints is! int || treePoints != source.points) return false;
      return File('${tree.path}/octree.bin').lengthSync() == kPwLodBytesPerPoint * treePoints;
    } catch (_) {
      return false;
    }
  }

  static void _touch(Directory tree) {
    try {
      File('${tree.path}/$kStampName').setLastModifiedSync(DateTime.now());
    } catch (_) {}
  }

  /// ReviewCloudCache.prune's policy on directories: newest [kMaxEntries] trees kept (by stamp
  /// mtime), stale `.building` / `.chunks` removed; [keep] (the tree being built) is never removed.
  void _prune(Directory root, {required String keep}) {
    try {
      final staleBefore = _clock().subtract(kTmpStaleAfter);
      final trees = <({Directory dir, DateTime at})>[];
      for (final e in root.listSync(followLinks: false)) {
        if (e is! Directory) continue;
        final name = e.path.split(Platform.pathSeparator).last;
        if (name.endsWith('.building') || name.endsWith('.chunks')) {
          if (name.startsWith('$keep.')) continue;
          if (e.statSync().modified.isBefore(staleBefore)) e.deleteSync(recursive: true);
          continue;
        }
        if (name == keep) continue;
        final stamp = File('${e.path}/$kStampName');
        trees.add((dir: e, at: stamp.existsSync() ? stamp.statSync().modified : e.statSync().modified));
      }
      trees.sort((a, b) => b.at.compareTo(a.at));
      for (var i = kMaxEntries - 1; i < trees.length; i++) {
        trees[i].dir.deleteSync(recursive: true);
      }
    } catch (_) {}
  }
}

typedef _SourceId = ({String path, int bytes, int mtimeMs, int points});

/// Test helper: the source identity of a PLY as the cache sees it.
@visibleForTesting
({String path, int bytes, int mtimeMs, int points})? denseLodSourceOf(String ply) {
  final f = File(ply);
  if (!f.existsSync()) return null;
  final st = f.statSync();
  final n = plyVertexCount(ply);
  if (n == null) return null;
  return (path: ply, bytes: st.size, mtimeMs: st.modified.millisecondsSinceEpoch, points: n);
}
