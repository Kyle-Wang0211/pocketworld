// lod_jobs.dart — the two device jobs of plan L6 / M1, as plain Dart over LodBridge:
//
//   L6  buildAndVerify:  <capture>/<ply>  --pwlod_build_from_ply-->  <capture>/lod/
//       then pwlod_verify_octree on the result, judged by judgeC1 / judgeVerify
//       (C1: tree_points == ply_points && octree_bin_bytes == 18 * tree_points; C2; S2), and a
//       receipt <capture>/lod_build_receipt.json with every number the verdict rests on.
//   M1  runM1:  pwlod_run(<octree>, Documents/lod_bench/<tag>_<stamp>/, args, probe, NULL),
//       receipt m1_receipt.json next to pwlod_run's own result. Pulled back after a detached
//       launch with `xcrun devicectl device copy from` (product CLAUDE.md: detached launch,
//       results in the app container, copied afterwards).
//
// Platform-neutral (dart:io + the channel). Nothing is deleted except this job's own scratch
// (the chunk dir, which the shell removes) and — only when the caller passes rebuild: true —
// a previous <capture>/lod/.
import 'dart:convert';
import 'dart:io';

import 'lod_bridge.dart';

const String kLodDirName = 'lod';
const String kLodChunkDirName = 'lod_chunks_tmp';
const String kLodBuildReceiptName = 'lod_build_receipt.json';
const String kLodBenchDirName = 'lod_bench';
const String kLodBenchReceiptName = 'm1_receipt.json';

/// The dense stage's output name (feat/dense-stage @1a43510 lib/dense/native_dense_stage_launcher.dart:24,
/// plan §1); any other *.ply in the capture dir is the fallback.
const String kPreferredPlyName = 'official_dense.ply';

/// Prefers [kPreferredPlyName], else the lexicographically first *.ply; null if none.
File? findCapturePly(Directory captureDir) {
  final preferred = File('${captureDir.path}/$kPreferredPlyName');
  if (preferred.existsSync()) return preferred;
  final plys =
      captureDir
          .listSync(followLinks: false)
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.ply'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return plys.isEmpty ? null : plys.first;
}

bool octreeReady(Directory octreeDir) =>
    File('${octreeDir.path}/metadata.json').existsSync() &&
    File('${octreeDir.path}/hierarchy.bin').existsSync() &&
    File('${octreeDir.path}/octree.bin').existsSync();

String _stamp(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}';
}

class LodBuildOutcome {
  const LodBuildOutcome({
    required this.pass,
    required this.checks,
    required this.build,
    required this.verify,
    required this.receipt,
    required this.octreeDir,
  });
  final bool pass;
  final List<LodCheck> checks;
  final LodBuildReport build;
  final LodVerifyReport? verify;
  final File receipt;
  final Directory octreeDir;
}

class LodBenchOutcome {
  const LodBenchOutcome({
    required this.result,
    required this.outDir,
    required this.receipt,
  });
  final LodBenchResult result;
  final Directory outDir;
  final File receipt;
}

/// Plan L6. Throws [StateError] if `<capture>/lod/` already holds files and [rebuild] is false.
Future<LodBuildOutcome> buildAndVerify({
  required LodBridge bridge,
  required Directory captureDir,
  File? ply,
  int threads = 0,
  int memoryBudgetMb = 0,
  bool rebuild = false,
  DateTime Function() clock = DateTime.now,
}) async {
  final plyFile = ply ?? findCapturePly(captureDir);
  if (plyFile == null) {
    throw StateError('no .ply in ${captureDir.path}');
  }
  final out = Directory('${captureDir.path}/$kLodDirName');
  if (out.existsSync() && out.listSync().isNotEmpty) {
    if (!rebuild) {
      throw StateError(
        '${out.path} is not empty; pass rebuild: true to replace it',
      );
    }
    out.deleteSync(recursive: true);
  }
  final chunk = Directory('${captureDir.path}/$kLodChunkDirName');
  final started = clock();
  final build = await bridge.buildFromPly(
    plyPath: plyFile.path,
    outDir: out.path,
    chunkDir: chunk.path,
    memoryBudgetMb: memoryBudgetMb,
    threads: threads,
  );
  final checks = <LodCheck>[judgeC1(build)];
  LodVerifyReport? verify;
  if (build.status == 'PWLOD_OK') {
    verify = await bridge.verifyOctree(octreeDir: out.path);
    checks.addAll(judgeVerify(verify, build: build));
  }
  final pass = checks.every((c) => c.pass) && verify != null;
  final receipt = File('${captureDir.path}/$kLodBuildReceiptName');
  final json = <String, Object?>{
    'schema': 'pw_lod_build_receipt/1',
    'started': started.toIso8601String(),
    'finished': clock().toIso8601String(),
    'ply_path': plyFile.path,
    'ply_bytes': plyFile.existsSync() ? plyFile.lengthSync() : -1,
    'octree_dir': out.path,
    'threads': threads,
    'memory_budget_mb': memoryBudgetMb,
    'build': build.toJson(),
    'verify': verify?.toJson(),
    'checks': [for (final c in checks) c.toJson()],
    'pass': pass,
  };
  receipt.writeAsStringSync(const JsonEncoder.withIndent('  ').convert(json));
  return LodBuildOutcome(
    pass: pass,
    checks: checks,
    build: build,
    verify: verify,
    receipt: receipt,
    octreeDir: out,
  );
}

/// Plan M1. [args] is pwlod_run's key=value string (pw_lod_bench.cpp ParseArgs); ` tag=<tag>`
/// is appended the way pw_splat_ab_bench Sources/App.swift:105 does.
Future<LodBenchOutcome> runM1({
  required LodBridge bridge,
  required Directory octreeDir,
  required Directory documentsDir,
  required String args,
  String tag = 'm1',
  DateTime Function() clock = DateTime.now,
}) async {
  final started = clock();
  final outDir = Directory(
    '${documentsDir.path}/$kLodBenchDirName/${tag}_${_stamp(started)}',
  )..createSync(recursive: true);
  final fullArgs = '$args tag=$tag'.trim();
  final r = await bridge.runBench(
    octreeDir: octreeDir.path,
    outDir: outDir.path,
    args: fullArgs,
  );
  final receipt = File('${outDir.path}/$kLodBenchReceiptName');
  receipt.writeAsStringSync(
    const JsonEncoder.withIndent('  ').convert(<String, Object?>{
      'schema': 'pw_lod_m1_receipt/1',
      'started': started.toIso8601String(),
      'finished': clock().toIso8601String(),
      'octree_dir': octreeDir.path,
      'args': fullArgs,
      'engine_version': r.version,
      'pwlod_run_result': r.result,
      'pwlod_run_result_is_file': r.resultIsFile,
      'wall_ms': r.wallMs,
      'probe_start': r.probeStart,
      'probe_end': r.probeEnd,
    }),
  );
  return LodBenchOutcome(result: r, outDir: outDir, receipt: receipt);
}
