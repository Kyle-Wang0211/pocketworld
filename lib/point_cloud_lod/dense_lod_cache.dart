// dense_lod_cache.dart — the finished dense cloud's octree, built on the phone and kept IN THE WORK
// DIRECTORY next to its PLYs (build 174; user 2026-09-24:「那为什么稠密不能是直接按『作品目录/…』去读
// 呢???有就直接打开，没有就显示稀疏呗」):
//
//   <work>/official_dense.ply        the dense stage's output (unchanged)
//   <work>/lod/                      metadata.json, hierarchy.bin, octree.bin (Potree 2.0, built by
//                                    pwlod_build_from_ply) + pw_lod_source.json (a small record:
//                                    engine, points, build time, checks — never used to decide)
//   <work>/lod.building/             the tree while it is built; renamed to lod/ after its self-check
//   <cache>/lod_chunks/<作品标识>/     pwlod_build_from_ply's scratch (system cache dir; deleted after;
//                                    <work>/lod.building.chunks/ if there is no cache dir)
//
// A tree is found by its place relative to the work directory — no absolute path, no path hash
// (171–173 kept trees in Library/Caches keyed by the absolute path, and every app update moved the
// container and orphaned them). VALID ⇔ lod/metadata.json, lod/hierarchy.bin, lod/octree.bin all
// exist, octree.bin is exactly 18 B × the tree's points (metadata.json `points`), and those points
// equal the vertex count of a COMPLETE official_dense.ply (densePlyPoints: header count fills the
// file; C1 on disk, header + length reads only). `lod.building/`, `lod.deleting.*` or anything else
// is never a tree.
//
// [174] User 2026-09-24 「永远不会重新训练稠密。如果有那就是 bug」: a complete official_dense.ply
// means the dense stage is DONE — this cache only ever turns that PLY into a tree (build, verify,
// rename), it never asks for training, and a failed build leaves the flat display (logged).
//
// Build gate (unchanged from 171): pwlod_build_from_ply → C1 (tree_points == the PLY header count read
// here, octree_bin_bytes == 18·tree_points) → pwlod_verify_octree → C2 (no byte gap/overlap), S2 (every
// leaf selectable), build == verify; only then lod.building/ becomes lod/. Any failure ⇒ no tree, the
// view keeps the flat display, the reason goes to the device log.
// A dense run (allowed only while the work has no complete dense PLY: the first one, or one whose
// PLY was cut short) deletes <work>/lod/ first (rename to lod.deleting.<ms>, then delete), so a
// tree can never outlive the PLY it was built from.
// Migration (one-off): 171–173 trees in <cache>/lod/<作品标识>/ whose points match this work's dense
// PLY are RENAMED into <work>/lod/ (same container, same volume: instant), never rebuilt; logged.
//
// ⚠️ Note for the install runbook: the tree now lives under Documents/captures_official/<cap_id>/,
// so it is part of every container backup (install gate B counts that directory's entries — the
// backup taken right before an install includes it) and of iOS device backups (7 M points ≈ 126 MB).
// The user chose this place over the cache directory on 2026-09-24.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:path_provider/path_provider.dart';

import '../official_util/device_log.dart';
import 'lod_bridge.dart';

/// The engine archive this build links (`vendor/aether_lod/libs/ios-arm64/libpw_lod_<sha8>.a`),
/// recorded in each tree's pw_lod_source.json (information only; a test pins it to the receipt).
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

/// [174] User 2026-09-24: 「永远不会重新训练稠密。如果有那就是 bug」. A work's dense stage is DONE iff
/// its official_dense.ply is COMPLETE: the vertex count declared in the header fills the file
/// exactly — header bytes + 15 B per point (float x,y,z + uchar red,green,blue, the header template
/// in PWDense.framework). Returns that count, or null when the file is missing, unreadable, shorter
/// (a run killed mid-write) or longer than its header says: such a work counts as never done and
/// 下一步 may train it. Reads the first 4 KB and the file length only.
int? densePlyPoints(String path) {
  try {
    final f = File(path);
    if (!f.existsSync()) return null;
    final raf = f.openSync();
    try {
      final head = raf.readSync(4096);
      final text = latin1.decode(head, allowInvalid: true);
      const marker = 'end_header\n';
      final end = text.indexOf(marker);
      if (!text.startsWith('ply') || end < 0) return null;
      final m = RegExp(r'element vertex (\d+)').firstMatch(text.substring(0, end));
      if (m == null) return null;
      final n = int.parse(m.group(1)!);
      if (n <= 0) return null;
      return raf.lengthSync() == end + marker.length + kDensePlyBytesPerPoint * n ? n : null;
    } finally {
      raf.closeSync();
    }
  } catch (_) {
    return null;
  }
}

/// See [densePlyPoints].
bool densePlyComplete(String path) => densePlyPoints(path) != null;

/// official_dense.ply's record: 3 × float32 + 3 × uint8.
const int kDensePlyBytesPerPoint = 15;

class DenseLodCache {
  DenseLodCache({
    LodBridge? bridge,
    Future<Directory?> Function()? cacheRoot,
    DateTime Function() clock = DateTime.now,
  }) : _bridge = bridge ?? LodBridge(),
       _cacheRoot = cacheRoot ?? _defaultRoot,
       _clock = clock;

  static DenseLodCache _instance = DenseLodCache();

  /// The app's cache (the capture page, the viewer page and the dense launcher share it).
  static DenseLodCache get instance => _instance;

  /// Tests swap in a cache with a temp root and a mocked bridge.
  @visibleForTesting
  static set instanceForTesting(DenseLodCache c) => _instance = c;

  static const String kTreeDirName = 'lod';
  static const String kBuildingDirName = 'lod.building';
  static const String kStampName = 'pw_lod_source.json';

  /// 171–173 kept trees under `<cache>/lod/<作品标识>/`; the migration looks there.
  static const String kLegacyCacheDirName = 'lod';
  static const String kChunksDirName = 'lod_chunks';

  final LodBridge _bridge;

  /// The system cache directory (path_provider getApplicationCacheDirectory; tests pass a temp dir).
  final Future<Directory?> Function() _cacheRoot;
  final DateTime Function() _clock;

  final Map<String, ValueNotifier<DenseLodState>> _states = {};

  /// PLY identity a build already failed for: not retried until the PLY changes (a tree that
  /// cannot pass its self-check would otherwise be rebuilt on every visit). In memory only.
  final Map<String, String> _failedFor = {};
  Future<void>? _queue; // one build at a time (null = nothing ever queued)

  /// Completes when every queued check/build has finished (tests). With nothing queued the future
  /// is made in the caller's zone (a completed future made elsewhere would deliver into that
  /// zone — under flutter_test's fake async that never happens inside runAsync).
  @visibleForTesting
  Future<void> whenIdle() => _queue ?? Future<void>.value();

  static Future<Directory?> _defaultRoot() async {
    try {
      return await getApplicationCacheDirectory();
    } catch (_) {
      return null;
    }
  }

  /// The work directory of a dense PLY (`<work>/official_dense.ply`).
  static String workDirOf(String densePlyPath) => File(densePlyPath).parent.path;

  /// `<work>/lod`.
  static String treeDirOf(String densePlyPath) => '${workDirOf(densePlyPath)}/$kTreeDirName';

  /// `<作品标识>` = the work directory's name (`cap_<id>`): the key 171–173 used under
  /// `<cache>/lod/`, and the chunk scratch name.
  static String keyFor(String plyPath) => File(plyPath).parent.path.split(Platform.pathSeparator).last;

  /// Points of a Potree 2.0 tree = metadata.json `points`; null if unreadable.
  static int? treePointsOf(Directory tree) {
    try {
      final j = jsonDecode(File('${tree.path}/metadata.json').readAsStringSync());
      final p = j is Map ? j['points'] : null;
      return p is int ? p : (p is num && p == p.roundToDouble() ? p.toInt() : null);
    } catch (_) {
      return null;
    }
  }

  /// The validity rule (see the file header): three files, octree.bin = 18 B × points, points =
  /// [plyPoints] (the dense PLY header's vertex count). Reads metadata.json and file sizes only.
  static bool isValidTree(Directory tree, int plyPoints) {
    try {
      for (final f in ['metadata.json', 'hierarchy.bin', 'octree.bin']) {
        if (!File('${tree.path}/$f').existsSync()) return false;
      }
      final points = treePointsOf(tree);
      if (points == null || points <= 0 || points != plyPoints) return false;
      return File('${tree.path}/octree.bin').lengthSync() == kPwLodBytesPerPoint * points;
    } catch (_) {
      return false;
    }
  }

  /// [build 172+] Re-opening a work: `<work>/lod` if it is a valid tree for this work's COMPLETE
  /// dense PLY ([densePlyPoints]), else null. NEVER builds and never reads the PLY body (header and
  /// length only). With no `<work>/lod` at all, a valid 171–173 tree left in
  /// `<cache>/lod/<作品标识>/` is migrated into `<work>/lod` first (rename, once).
  Future<String?> findValid(String densePlyPath) async {
    try {
      final points = densePlyPoints(densePlyPath);
      if (points == null) return null;
      final tree = Directory(treeDirOf(densePlyPath));
      if (isValidTree(tree, points)) return tree.path;
      if (!tree.existsSync()) {
        final migrated = await _migrateLegacy(densePlyPath, points);
        if (migrated != null) return migrated;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 171–173 → 174: `<cache>/lod/<作品标识>/` → `<work>/lod/` when it is a valid tree for this
  /// work (same rule, same point count). Rename only; returns the new path or null.
  Future<String?> _migrateLegacy(String densePlyPath, int plyPoints) async {
    final root = await _cacheRoot();
    if (root == null) return null;
    final legacy = Directory('${root.path}/$kLegacyCacheDirName/${keyFor(densePlyPath)}');
    if (!legacy.existsSync()) return null;
    final target = treeDirOf(densePlyPath);
    if (!isValidTree(legacy, plyPoints)) {
      DeviceLog.log(
        'DenseLodCache',
        'legacy tree not migrated (points ${treePointsOf(legacy)} vs PLY $plyPoints or incomplete): ${legacy.path}',
      );
      return null;
    }
    try {
      legacy.renameSync(target);
      DeviceLog.log('DenseLodCache', 'migrated legacy tree ${legacy.path} → $target ($plyPoints pts, rename, no rebuild)');
      return target;
    } catch (e) {
      DeviceLog.log('DenseLodCache', 'legacy tree migration failed (left in place): $e');
      return null;
    }
  }

  /// Re-training the dense stage: remove `<work>/lod/` first (rename to `lod.deleting.<ms>`, then
  /// delete — a crash in between leaves a name that is never read as a tree), plus any
  /// `lod.building/` leftover. Called by the dense launcher when a job really starts.
  void discardTree(String workDir) {
    final w = Directory(workDir);
    if (!w.existsSync()) return;
    final tree = Directory('$workDir/$kTreeDirName');
    if (tree.existsSync()) {
      final gone = '$workDir/$kTreeDirName.deleting.${_clock().millisecondsSinceEpoch}';
      try {
        tree.renameSync(gone);
        DeviceLog.log('DenseLodCache', 'dense re-run: old tree removed from $workDir');
      } catch (e) {
        DeviceLog.log('DenseLodCache', 'dense re-run: could not move the old tree aside: $e');
      }
    }
    _removeLeftovers(workDir);
    // the next check must not reuse an answer about the old tree
    _states.remove('$workDir/official_dense.ply');
    _failedFor.remove('$workDir/official_dense.ply');
  }

  /// Deletes `lod.building*` / `lod.deleting.*` siblings of the tree (never `lod` itself).
  static void _removeLeftovers(String workDir) {
    try {
      for (final e in Directory(workDir).listSync(followLinks: false)) {
        if (e is! Directory) continue;
        final name = e.path.split(Platform.pathSeparator).last;
        if (name.startsWith(kBuildingDirName) || name.startsWith('$kTreeDirName.deleting.')) {
          e.deleteSync(recursive: true);
        }
      }
    } catch (_) {}
  }

  /// The tree state for a COMPLETE dense PLY: uses a valid tree (or migrates one), otherwise builds
  /// one from the PLY already on disk — never trains anything. The same notifier is returned for the
  /// same path, so pages share one build.
  ValueListenable<DenseLodState> watch(String densePlyPath) {
    final existing = _states[densePlyPath];
    if (existing != null) {
      if (existing.value.phase != DenseLodPhase.building) unawaited(_ensure(densePlyPath, existing));
      return existing;
    }
    final n = ValueNotifier<DenseLodState>(const DenseLodState.building());
    _states[densePlyPath] = n;
    unawaited(_ensure(densePlyPath, n));
    return n;
  }

  Future<void> _ensure(String ply, ValueNotifier<DenseLodState> out) {
    final run = (_queue ?? Future<void>.value()).then((_) async {
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
    final src = File(ply);
    if (!src.existsSync()) return _failed(ply, 'PLY missing');
    final stat = src.statSync();
    // [174] never from a truncated PLY (a dense run killed mid-write is "not done", not a source)
    final plyPoints = densePlyPoints(ply);
    if (plyPoints == null) return _failed(ply, 'dense PLY incomplete or unreadable (header count does not fill the file)');
    final workDir = workDirOf(ply);
    final key = keyFor(ply);
    final identity = '${stat.size}|${stat.modified.millisecondsSinceEpoch}|$plyPoints';
    final found = await findValid(ply);
    if (found != null) return DenseLodState.ready(found);
    if (_failedFor[ply] == identity) {
      return DenseLodState.failed('previous build of this PLY failed (not retried)');
    }
    out.value = const DenseLodState.building();
    _removeLeftovers(workDir);
    final tree = Directory('$workDir/$kTreeDirName');
    final tmp = Directory('$workDir/$kBuildingDirName');
    final root = await _cacheRoot();
    final chunks = Directory(
      root != null ? '${root.path}/$kChunksDirName/$key' : '$workDir/$kBuildingDirName.chunks',
    );
    if (chunks.existsSync()) chunks.deleteSync(recursive: true);
    final started = _clock();
    final lifecycle = _LifecycleTally.start();
    DeviceLog.log(
      'DenseLodCache',
      'build start $key at ${started.toIso8601String()}: $plyPoints pts, ${stat.size} B, '
          'app ${lifecycle.stateAtStart}',
    );
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
    final pass = verify != null && checks.every((c) => c.pass) && isValidTree(tmp, plyPoints);
    final finished = _clock();
    final bg = lifecycle.stop();
    // [172] the numbers a phone measurement rests on: wall clock start/end, peak memory (shell),
    // and whether the app was sent to the background meanwhile (iOS suspends it ⇒ the wall time
    // then includes the time it was not running; build 171's first on-device build did this).
    DeviceLog.log(
      'DenseLodCache',
      'build timing $key: start ${started.toIso8601String()} end ${finished.toIso8601String()} '
          'wall ${finished.difference(started).inMilliseconds} ms, engine ${build.elapsedMs.toStringAsFixed(0)} ms, '
          'peak ${build.peakFootprintMb.toStringAsFixed(0)} MB (baseline ${build.baselineFootprintMb.toStringAsFixed(0)} MB), '
          'background during build: ${bg.wentToBackground ? 'YES' : 'no'} '
          '(${bg.backgroundEntries}×, ${bg.backgroundMs} ms${bg.observed ? '' : ', lifecycle not observable'})',
    );
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
        'schema': 'pw_lod_source/2',
        'engine': '$kLodEngineSha8 abi=$kLodEngineAbi',
        'points': plyPoints,
        'started': started.toIso8601String(),
        'finished': finished.toIso8601String(),
        'background_during_build': bg.toJson(),
        'build': build.toJson(),
        'verify': verify.toJson(),
        'checks': [for (final c in checks) c.toJson()],
      }),
      flush: true,
    );
    if (tree.existsSync()) {
      final gone = Directory('$workDir/$kTreeDirName.deleting.${finished.millisecondsSinceEpoch}');
      tree.renameSync(gone.path);
      gone.deleteSync(recursive: true);
    }
    tmp.renameSync(tree.path);
    DeviceLog.log(
      'DenseLodCache',
      'build ok $key: ${build.treePoints} pts, ${build.nodes} nodes, ${build.elapsedMs.toStringAsFixed(0)} ms, '
          'peak ${build.peakFootprintMb.toStringAsFixed(0)} MB, leaves ${verify.leavesSelected}/${verify.leaves} → ${tree.path}',
    );
    return DenseLodState.ready(tree.path);
  }

  DenseLodState _failed(String ply, String why) {
    DeviceLog.log('DenseLodCache', 'no tree for $ply (flat display stays): $why');
    return DenseLodState.failed(why);
  }
}

/// Counts how often / how long the app was in the background while a build ran (Flutter lifecycle
/// events; iOS suspends a backgrounded app, so such a build's wall time is not the build's cost).
class _LifecycleTally with WidgetsBindingObserver {
  _LifecycleTally._(this.observed, this.stateAtStart);

  factory _LifecycleTally.start() {
    try {
      final b = WidgetsBinding.instance;
      final t = _LifecycleTally._(true, b.lifecycleState?.name ?? 'unknown');
      if (b.lifecycleState == AppLifecycleState.paused || b.lifecycleState == AppLifecycleState.hidden) {
        t._enter();
      }
      b.addObserver(t);
      return t;
    } catch (_) {
      return _LifecycleTally._(false, 'unknown');
    }
  }

  final bool observed;
  final String stateAtStart;
  int backgroundEntries = 0;
  int backgroundMs = 0;
  DateTime? _since;

  bool get wentToBackground => backgroundEntries > 0;

  void _enter() {
    if (_since != null) return;
    backgroundEntries++;
    _since = DateTime.now();
  }

  void _leave() {
    final t = _since;
    if (t == null) return;
    backgroundMs += DateTime.now().difference(t).inMilliseconds;
    _since = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _enter();
    } else if (state == AppLifecycleState.resumed) {
      _leave();
    }
  }

  _LifecycleTally stop() {
    _leave();
    if (observed) {
      try {
        WidgetsBinding.instance.removeObserver(this);
      } catch (_) {}
    }
    return this;
  }

  Map<String, Object> toJson() => <String, Object>{
    'observed': observed,
    'state_at_start': stateAtStart,
    'went_to_background': wentToBackground,
    'background_entries': backgroundEntries,
    'background_ms': backgroundMs,
  };
}
