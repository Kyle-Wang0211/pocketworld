// B 轨 Mac 侧再生对账(第 1、2 步) — 派生服务确定性与版本保真测量
//
// 实验设计:
//   在采集目录副本上连跑三遍 PhotoBundleDerivationService.deriveDirectory:
//   - 第 1 遍可能触发 manifest repair(瞬态,单独记录);
//   - 第 2 遍 vs 第 3 遍逐字节比较 = **纯确定性判决**(B 轨位级可行性);
//   - 若目录里预先存有同名旧产物(旧版 app 生成),第 0 步先快照,
//     与第 3 遍比较 = **跨版本保真测量**(版本锁的必要性证据)。
//
// 用法: dart run tool/btrack_derivation_recon.dart <采集目录副本> <报告.json>

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:official_capture_services/official_capture_services.dart';

Future<Map<String, String>> _snapshot(
    Directory root, List<String> relatives) async {
  final out = <String, String>{};
  for (final rel in relatives) {
    final f = File('${root.path}/$rel');
    if (f.existsSync()) {
      out[rel] = sha256.convert(await f.readAsBytes()).toString();
    }
  }
  return out;
}

Future<void> main(List<String> args) async {
  final dir = Directory(args[0]);
  final reportPath = args[1];
  const service = PhotoBundleDerivationService();

  // 第 0 步:记录目录中已存在的潜在旧产物(旧版 app 写的)
  const knownArtifacts = [
    'view_graph.json',
    'bundle_validation.json',
    'pointcloud_preflight_plan.json',
    'texture_plan.json',
    'local_policy_bundle.json',
    'photo_bundle_repair_report.json',
    'official_photo_bundle.json',
  ];
  final preExisting = await _snapshot(dir, knownArtifacts);

  final runs = <Map<String, String>>[];
  final writtenLists = <List<String>>[];
  for (var i = 0; i < 3; i++) {
    final result = await service.deriveDirectory(dir);
    final written = result.writtenRelativePaths.toList();
    writtenLists.add(written);
    runs.add(await _snapshot(dir, {...written, ...knownArtifacts}.toList()));
  }

  // 确定性:run2 vs run3 (跳过 repair 瞬态)
  final determinism = <String, Object?>{};
  var deterministic = true;
  for (final rel in {...runs[1].keys, ...runs[2].keys}) {
    final equal = runs[1][rel] == runs[2][rel];
    determinism[rel] = equal;
    if (!equal) deterministic = false;
  }

  // 跨版本保真:旧产物(手机 app 写的) vs 本机当前代码第 3 遍
  final versionFidelity = <String, Object?>{};
  for (final rel in preExisting.keys) {
    if (runs[2].containsKey(rel)) {
      versionFidelity[rel] =
          preExisting[rel] == runs[2][rel] ? 'byte_equal' : 'differs';
    }
  }

  final head = Process.runSync(
      'git', ['-C', Directory.current.path, 'rev-parse', 'HEAD']);
  final report = {
    'schema': 'pw_btrack_derivation_recon_v1',
    'capture': dir.path.split('/').last,
    'code_version': head.stdout.toString().trim(),
    'artifacts_written_per_run': writtenLists.map((w) => w.length).toList(),
    'repair_transient_run1_vs_run2': {
      for (final rel in {...runs[0].keys, ...runs[1].keys})
        if (runs[0][rel] != runs[1][rel]) rel: 'changed'
    },
    'determinism_run2_vs_run3': determinism,
    'deterministic': deterministic,
    'version_fidelity_stored_vs_regen': versionFidelity,
    'grade_verdict': deterministic
        ? 'BIT_LEVEL_REGENERATION_VIABLE(同版本代码)'
        : 'NON_DETERMINISTIC(降级语义档并查根因)',
  };
  File(reportPath).writeAsStringSync(
      const JsonEncoder.withIndent(' ').convert(report));
  stdout.writeln(jsonEncode({
    'deterministic': deterministic,
    'artifacts': determinism.length,
    'version_fidelity': versionFidelity,
  }));
}
