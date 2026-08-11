/// DatabaseRecipeTransaction — B1 全配方化:DB 字节不存,存再生配方
///
/// 用户签决(2026-08-10,B1 签决文档四项全签):冷归档合同"不删可再生模块"
/// 修订为"可证明再生 + 抽查校验";DB 从位级档降为语义档(P2 后位级已
/// 结构性不可能)。
///
/// 语义:capture 的照片主本可完整物化(PWVA master 或 Lepton 全覆盖)且
/// 逐帧 AR sidecar 完整时,写 official_database_recipe.json(再生所需的
/// 全部指针与校验),然后删除 DB 字节(official_sfm_live.db 与/或
/// .zpaq+manifest)。需要 DB 时 [DatabaseArchiveResolver] 走
/// [SfmDbRegen.regenerate] 语义再生。
///
/// 删除纪律(与 Lepton/PWVA master 同款):
/// - 只在冷归档协调器 durably-ready 闸后运行;
/// - 全有或全无:任一帧无法物化/sidecar 不完整 → notApplicable,零删除,
///   capture 照旧走 ZPAQ 线;
/// - recipe 原子落盘在先,删除在后;
/// - 🔴 gate: [enabled] 默认 false —— 设备侧 V4/V5 门(pw_b1_gate 钩子)
///   过门前绝不在生产删除任何 DB 字节。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'database_archive_manifest.dart';
import 'database_archive_policy.dart';
import 'photo_archive_manifest.dart';
import 'pwva_master.dart';

typedef DatabaseRecipeContinueCheck = FutureOr<bool> Function();

class DatabaseRecipeResult {
  const DatabaseRecipeResult({
    this.applicable = false,
    this.committed = false,
    this.deletedBytes = 0,
    this.paused = false,
    this.reason,
  });

  final bool applicable;
  final bool committed;
  final int deletedBytes;
  final bool paused;
  final String? reason;
}

class DatabaseRecipeManifest {
  static const schema = 'pw_database_recipe_v1';
  static const fileName = 'official_database_recipe.json';

  /// 会话配置钉死(与拍摄期一致;变更须升 schema)。
  static const sessionConfig = <String, Object?>{
    'image_width': 4032,
    'image_height': 3024,
    'max_features': 8192,
    'k_neighbors': 12,
    'match_max_ratio': 0.8,
    'use_gpu_match': 1,
    'use_gpu_extract': 1,
    'feed': 'pwofficial_add_jpeg_frame(sidecar t/extrinsic/intrinsics)',
  };

  static Future<bool> exists(Directory captureDirectory) =>
      File('${captureDirectory.path}/$fileName').exists();

  static Future<Map<String, dynamic>?> read(Directory captureDirectory) async {
    try {
      final f = File('${captureDirectory.path}/$fileName');
      if (!await f.exists()) return null;
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      if (json['schema'] != schema) return null;
      return json;
    } catch (_) {
      return null;
    }
  }
}

class DatabaseRecipeTransaction {
  const DatabaseRecipeTransaction({this.canContinue});

  /// 🔴 生产删除总闸。设备 V4/V5 门 PASS 后才许翻 true(硬编码,
  /// dart-define 在本工程不生效)。false 时本事务恒 notApplicable。
  static const bool enabled = false;

  final DatabaseRecipeContinueCheck? canContinue;

  Future<DatabaseRecipeResult> recipeCapture(Directory captureDirectory) async {
    if (!enabled) return const DatabaseRecipeResult(reason: 'gate_closed');
    if (!Platform.isIOS) return const DatabaseRecipeResult(reason: 'platform');
    try {
      if (await DatabaseRecipeManifest.exists(captureDirectory)) {
        // 已配方化:清理可能残留的 DB 字节(崩溃后收尾)。
        return _reconcile(captureDirectory);
      }
      final candidates =
          await PhotoArchiveManifest.loadCandidateNames(captureDirectory);
      if (candidates.isEmpty) {
        return const DatabaseRecipeResult(reason: 'no_candidates');
      }

      // 照片可物化性:每帧要么源 .jpg 在,要么 Lepton manifest 覆盖,
      // 要么 PWVA master 覆盖。
      final lepton = await PhotoArchiveManifest.read(captureDirectory);
      final pwva = await PwvaMasterManifest.read(captureDirectory);
      for (final name in candidates) {
        final jpg =
            File('${captureDirectory.path}/photos_highres/$name');
        final covered = await jpg.exists() ||
            (lepton?.entries.containsKey(name) ?? false) ||
            (pwva?.entries.containsKey(name) ?? false);
        if (!covered) {
          return const DatabaseRecipeResult(reason: 'photo_not_materializable');
        }
        final sidecar = File(
            '${captureDirectory.path}/photos_highres/${name.replaceAll(RegExp(r'\.jpe?g$'), '.json')}');
        if (!await _sidecarComplete(sidecar)) {
          return const DatabaseRecipeResult(reason: 'sidecar_incomplete');
        }
      }

      // DB 字节现状(至少一种在,否则无从删起=已经没有字节负担)。
      final source = File(
          '${captureDirectory.path}/${DatabaseArchivePolicy.sourceFileName}');
      final archive = File(
          '${captureDirectory.path}/${DatabaseArchiveManifest.archiveFileName}');
      final archiveManifest =
          File('${captureDirectory.path}/official_database_archive.json');
      final hasSource = await source.exists();
      final hasArchive = await archive.exists();
      if (!hasSource && !hasArchive) {
        return const DatabaseRecipeResult(reason: 'no_db_bytes');
      }
      if (!await _canContinueNow()) {
        return const DatabaseRecipeResult(paused: true);
      }

      // 记录被删 DB 的账目(体积/SHA),供抽查校验对照。
      final provenance = <String, Object?>{};
      if (hasSource) {
        provenance['source_bytes'] = await source.length();
        provenance['source_sha256'] = await _sha256Of(source);
      }
      final dbManifest = await DatabaseArchiveManifest.read(captureDirectory);
      if (dbManifest != null) {
        provenance['archived_source_bytes'] = dbManifest.sourceBytes;
        provenance['archived_source_sha256'] = dbManifest.sourceSha256;
      }

      final sidecarShas = <String, String>{};
      for (final name in candidates) {
        final sidecar = File(
            '${captureDirectory.path}/photos_highres/${name.replaceAll(RegExp(r'\.jpe?g$'), '.json')}');
        sidecarShas[name] = await _sha256Of(sidecar);
      }

      final recipe = <String, Object?>{
        'schema': DatabaseRecipeManifest.schema,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'grade': 'semantic',
        'session_config': DatabaseRecipeManifest.sessionConfig,
        'frame_count': candidates.length,
        'frames': [
          for (final name in candidates)
            {'name': name, 'sidecar_sha256': sidecarShas[name]},
        ],
        'photo_master': pwva != null
            ? {'kind': 'pwva', 'stream_sha256': pwva.streamSha256}
            : {'kind': 'lepton_or_source'},
        'deleted_db_provenance': provenance,
      };
      final recipeFile = File(
          '${captureDirectory.path}/${DatabaseRecipeManifest.fileName}');
      final tmp = File('${recipeFile.path}.tmp');
      await tmp.writeAsString(
          const JsonEncoder.withIndent(' ').convert(recipe));
      await tmp.rename(recipeFile.path);

      var deleted = 0;
      if (!await _canContinueNow()) {
        return const DatabaseRecipeResult(
            applicable: true, committed: true, paused: true);
      }
      if (hasSource) {
        deleted += await source.length();
        await source.delete();
      }
      if (hasArchive) {
        deleted += await archive.length();
        await archive.delete();
      }
      if (await archiveManifest.exists()) await archiveManifest.delete();
      return DatabaseRecipeResult(
          applicable: true, committed: true, deletedBytes: deleted);
    } catch (e) {
      return DatabaseRecipeResult(reason: 'exception:$e');
    }
  }

  Future<DatabaseRecipeResult> _reconcile(Directory captureDirectory) async {
    var deleted = 0;
    for (final rel in [
      DatabaseArchivePolicy.sourceFileName,
      DatabaseArchiveManifest.archiveFileName,
      'official_database_archive.json',
    ]) {
      final f = File('${captureDirectory.path}/$rel');
      if (await f.exists()) {
        deleted += await f.length();
        await f.delete();
      }
    }
    return DatabaseRecipeResult(
        applicable: true, committed: true, deletedBytes: deleted);
  }

  Future<bool> _canContinueNow() async =>
      canContinue == null || await canContinue!();
}

Future<bool> _sidecarComplete(File sidecar) async {
  try {
    if (!await sidecar.exists()) return false;
    final j = jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
    final ex = j['extrinsic'];
    final intr = j['intrinsics_fxfycxcy'];
    return (j['t'] as num?)?.isFinite == true &&
        (j['image_w'] as num?)?.toInt() == 4032 &&
        (j['image_h'] as num?)?.toInt() == 3024 &&
        ex is List &&
        ex.length == 16 &&
        intr is List &&
        intr.length >= 4;
  } catch (_) {
    return false;
  }
}

Future<String> _sha256Of(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}
