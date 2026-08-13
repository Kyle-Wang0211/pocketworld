/// DatabaseRecipeTransaction — B1 无损形态(2026-08-11 用户签决):
/// **删匹配期脚手架、保匹配图**。两级:
///   ① descriptors 整表(原 DB 80.5% 字节)
///   ② keypoints 的仿射形状列 a11/a12/a21/a22(裁后表的 2/3;cols 6→2)
/// 二者都只服务"匹配"这一步,重建("重新重建点云")只读 keypoints 的 x,y
/// 与 matches/two_view_geometries。COLMAP 原生支持 cols=2;核的身份指纹
/// 只混 x,y 与描述子长度,故 ② **不改变指纹**。
///
/// 天花板实验(b1-regen-ceiling-PROVEN.json)证明:匹配图无法从 q65 压缩帧
/// 再生(穷举匹配轨迹仍 −24%,信息物理损失),而 descriptors(DB 80.5% 字节)
/// 是匹配期的中间物——匹配已完成,重建("重新重建点云"= mapper 回放
/// keypoints+matches+TVG)不读它。删除纪律:
/// - 删掉的东西要么可再生(descriptors 可从归档帧重提,语义档,SfmDbRegen
///   留作深度兜底)要么不影响交付;匹配图不可再生 → 必须保留;
/// - 裁剪到副本 → 逐表内容 SHA(cameras/images/keypoints/matches/TVG)
///   与原版**逐字节等同**验证 + descriptors 空表 + integrity_check,
///   任一不过 = 零改动(全有或全无);
/// - prune manifest 原子落盘在先,原 DB 替换在后;
/// - 裁后 DB 交给下游既有 ZPAQ 线做逐字节归档,resolver 物化照旧;
/// - 🔴 [enabled] 默认 false:设备门(裁后重建 vs 库存点云,用户肉眼)
///   过门前不动生产。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'database_archive_policy.dart';
import 'database_prune_ffi.dart';

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

  /// 裁掉的字节数(原 DB − 裁后 DB)。
  final int deletedBytes;
  final bool paused;
  final String? reason;
}

class DatabaseRecipeManifest {
  static const schema = 'pw_database_prune_v3';
  static const fileName = 'official_database_prune.json';

  /// 逐字节保全的表(变更须升 schema)。
  /// ⚠️keypoints 不在此列:裁掉仿射形状列后它的字节必然变化,改用
  /// [keypointsXySha256] 证明"每点 x,y 逐点相同"——那才是重建读的东西。
  /// ⚠️matches 在 [DatabaseRecipeTransaction.dropRawMatches] 打开后也会被
  /// 清空(几何验证已蒸馏成 TVG 内点;COLMAP DatabaseCache::Load 只读 TVG),
  /// 故它按开关动态进出本清单。
  static const preservedTablesAlways = <String>[
    'cameras',
    'images',
    'two_view_geometries',
  ];

  static List<String> preservedTablesFor({required bool dropRawMatches}) => [
        ...preservedTablesAlways,
        if (!dropRawMatches) 'matches',
      ];

  static Future<bool> exists(Directory captureDirectory) =>
      File('${captureDirectory.path}/$fileName').exists();

  /// 不过 schema 闸的原始读取:**只用于溯源字段沿用**。
  /// [read] 故意只认当前 schema(旧版=需要升级),因此不能拿它做沿用来源——
  /// 否则 v1→v2 升级时 original_db_bytes 会退化成"上一轮裁后的大小"
  /// (2026-08-12 真机实证:cap_…928171 的 115.0MB 溯源就是这样丢的)。
  static Future<Map<String, dynamic>?> readAnyVersion(
      Directory captureDirectory) async {
    try {
      final f = File('${captureDirectory.path}/$fileName');
      if (!await f.exists()) return null;
      final json = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return json['schema'] is String ? json : null;
    } catch (_) {
      return null;
    }
  }

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

  /// 🔴 第三级:清空原始 matches 表(只留 two_view_geometries)。
  /// 依据:几何验证已把原始匹配蒸馏成 TVG 内点,COLMAP 建图缓存
  /// (database_cache.cc:137 DatabaseCache::Load)**只读 TVG**;核里唯一读
  /// matches 的地方在收尾增强的配对验证,而增强在描述子被删后已失效。
  /// **已于 2026-08-13 经设备门 PASS 后翻开**:未命名(6) 从归档物化的
  /// 6.6MB 库 → 4.9MB(−26%),cameras/images/two_view_geometries 逐字节相同,
  /// 两臂 resume 重建 **配准 59=59、交付点数 20196=20196 完全一致**。
  /// 回退:改回 false(已裁 capture 不受影响)。
  static const bool dropRawMatches = true;

  /// 🔴 生产总闸。**已于 2026-08-11 经用户签决翻开**——依据:
  /// - 设备门 PASS(b1-prune-device-gate-PASS.json,真机 100 帧作品:
  ///   125.2MB→24.2MB;五张保全表逐字节相同;两臂配准/点数/误差/轨迹
  ///   逐位相同,交付点数 −0.10%,重建反快 12%);
  /// - host 台架同结论(b1-prune-form-host.json)+ 天花板证明匹配图不可
  ///   从压缩帧再生(b1-regen-ceiling-PROVEN.json),故只删描述子。
  /// 回退:改回 false 即刻停止任何新的裁剪(已裁 capture 不受影响)。
  static const bool enabled = true;

  final DatabaseRecipeContinueCheck? canContinue;

  Future<DatabaseRecipeResult> recipeCapture(Directory captureDirectory) async {
    if (!enabled) return const DatabaseRecipeResult(reason: 'gate_closed');
    return pruneCapture(captureDirectory);
  }

  /// 裁剪本体(设备门经由 b1_gate 直接调用,绕过生产总闸但不落生产目录)。
  Future<DatabaseRecipeResult> pruneCapture(
    Directory captureDirectory, {
    String? outputDbPath,
    /// 设备门用:在总闸翻开前强制试跑第三级。生产路径不传 = 用常量。
    bool? dropRawMatchesOverride,
  }) async {
    final dropMatches = dropRawMatchesOverride ?? dropRawMatches;
    if (!databasePruneSupported) {
      return const DatabaseRecipeResult(reason: 'platform');
    }
    try {
      final source = File(
          '${captureDirectory.path}/${DatabaseArchivePolicy.sourceFileName}');
      if (!await source.exists()) {
        return const DatabaseRecipeResult(reason: 'no_source_db');
      }
      final manifestExists =
          await DatabaseRecipeManifest.exists(captureDirectory);
      Map<String, dynamic>? priorManifest;
      if (manifestExists && outputDbPath == null) {
        // read() 只认当前 schema:v1(只删了描述子)会返回 null ⇒ 该 capture
        // 需要**升级**(补裁仿射列),不能被"已裁过"挡住。
        priorManifest = await DatabaseRecipeManifest.readAnyVersion(
            captureDirectory);
        final currentSchema = priorManifest?['schema'] ==
            DatabaseRecipeManifest.schema;
        final desc = await tableContentSha256(source.path, 'descriptors');
        // 这次检查以读写方式打开了源库,会重建 -wal/-shm;不清掉的话下游
        // ZPAQ 事务会一直判 db_not_cold 而永远跳过(真机 2026-08-11 实证)。
        await _dropStaleSiblings(source);
        if (currentSchema && desc == _sha256OfNothing) {
          return const DatabaseRecipeResult(
              applicable: true, committed: true, reason: 'already_pruned');
        }
        // 落到这里:要么 manifest 是旧版(补裁),要么替换前崩了(重做)。
        // 两种都再走一遍完整的裁剪+验证+替换,幂等。
      }
      // 冷库判定。[2026-08-11 真机实证] 采集结束后 db 旁常年残留
      // `-wal`(0 字节=已全部 checkpoint)与 `-shm`(共享内存索引)——既有
      // ZPAQ 事务因此一直判 db_not_cold 永久跳过,数据库才会堆到 125-267MB。
      // 真正危险的只有**非空 -wal**(有未落主文件的数据,字节拷贝会丢);
      // 0 字节 -wal + -shm 是已 checkpoint 的安全态,按冷库处理,并在提交后
      // 清掉这两个陈旧伴生(顺带解封 ZPAQ 线)。
      if (await File('${source.path}-journal').exists()) {
        return const DatabaseRecipeResult(reason: 'db_not_cold_journal');
      }
      final wal = File('${source.path}-wal');
      if (await wal.exists() && await wal.length() != 0) {
        return const DatabaseRecipeResult(reason: 'db_not_cold_wal');
      }
      if (!await _canContinueNow()) {
        return const DatabaseRecipeResult(paused: true);
      }

      final sourceBytes = await source.length();
      final sourceSha = await _sha256Of(source);

      // 工作副本:SQLite 打开 WAL 模式的 db 需要可写连接(建 -shm),而残留的
      // -wal/-shm 会让既有 ZPAQ 归档事务判 db_not_cold 而永远跳过。因此
      // **源文件全程只做字节读取**,一切打开都发生在副本上。
      final work = File('${source.path}.work.tmp');
      await _deleteWithSiblings(work);
      await source.copy(work.path);

      // 裁剪前逐表摘要(在副本上,内容与源逐字节相同)。
      final tables = DatabaseRecipeManifest.preservedTablesFor(
          dropRawMatches: dropMatches);
      final pre = <String, String>{};
      for (final t in tables) {
        final d = await tableContentSha256(work.path, t);
        if (d == null) {
          await _deleteWithSiblings(work);
          return const DatabaseRecipeResult(reason: 'pre_digest_failed');
        }
        pre[t] = d;
      }
      // keypoints 走 x,y 等价摘要(裁仿射后整表字节必然变化)。
      final preXy = await keypointsXySha256(work.path);
      if (preXy == null) {
        await _deleteWithSiblings(work);
        return const DatabaseRecipeResult(reason: 'pre_xy_digest_failed');
      }
      if (!await _canContinueNow()) {
        await _deleteWithSiblings(work);
        return const DatabaseRecipeResult(paused: true);
      }

      final pruned = File(outputDbPath ?? '${source.path}.pruned.tmp');
      await _deleteWithSiblings(pruned);
      final rc = await pruneDescriptorsFile(work.path, pruned.path,
          dropRawMatches: dropMatches);
      if (rc != 0 || !await pruned.exists()) {
        await _deleteWithSiblings(work);
        await _deleteWithSiblings(pruned);
        return DatabaseRecipeResult(reason: 'prune_failed_rc$rc');
      }

      // 裁剪后验证:保全表逐字节等同 + descriptors 空表。
      for (final t in tables) {
        final d = await tableContentSha256(pruned.path, t);
        if (d == null || d != pre[t]) {
          await _deleteWithSiblings(work);
          await _deleteWithSiblings(pruned);
          return DatabaseRecipeResult(reason: 'post_digest_mismatch_$t');
        }
      }
      final postXy = await keypointsXySha256(pruned.path);
      if (postXy == null || postXy != preXy) {
        await _deleteWithSiblings(work);
        await _deleteWithSiblings(pruned);
        return const DatabaseRecipeResult(reason: 'keypoint_xy_mismatch');
      }
      if (dropMatches) {
        final m = await tableContentSha256(pruned.path, 'matches');
        if (m != _sha256OfNothing) {
          await _deleteWithSiblings(work);
          await _deleteWithSiblings(pruned);
          return const DatabaseRecipeResult(reason: 'matches_not_empty');
        }
      }
      final emptyDescriptors =
          await tableContentSha256(pruned.path, 'descriptors');
      if (emptyDescriptors != _sha256OfNothing) {
        await _deleteWithSiblings(work);
        await _deleteWithSiblings(pruned);
        return const DatabaseRecipeResult(reason: 'descriptors_not_empty');
      }
      final prunedBytes = await pruned.length();

      // 身份链修复:核 resume 用 FrameIdentityDigestV1(含描述子)核对侧车,
      // 不重新盖章则重建必然 ERR_NOT_REGISTERED(host 实测 rc=5)。
      final sidecar = File('${source.path}$_poseSidecarSuffix');
      if (!await sidecar.exists()) {
        await _deleteWithSiblings(work);
        await _deleteWithSiblings(pruned);
        return const DatabaseRecipeResult(reason: 'pose_sidecar_missing');
      }
      final prunedSidecar = File('${pruned.path}$_poseSidecarSuffix');
      await sidecar.copy(prunedSidecar.path);
      final resealRc =
          await resealArkitPoseDigests(pruned.path, prunedSidecar.path);
      if (resealRc != 0) {
        await _deleteWithSiblings(work);
        await _deleteWithSiblings(pruned);
        await _deleteIfPresent(prunedSidecar);
        return DatabaseRecipeResult(reason: 'reseal_failed_rc$resealRc');
      }

      // 工作副本使命完成;裁后 db 的伴生文件也必须清掉(留着会让 ZPAQ
      // 事务判 db_not_cold 而永远跳过这个 capture)。prune 内已
      // checkpoint(TRUNCATE),主文件自洽。
      await _deleteWithSiblings(work);
      await _deleteSiblingsOnly(pruned);
      if (outputDbPath != null) {
        // 门模式:只产出裁后副本(含已盖章侧车),不动 capture。
        return DatabaseRecipeResult(
          applicable: true,
          committed: false,
          deletedBytes: sourceBytes - prunedBytes,
        );
      }

      // 提交:manifest 原子落盘在先,替换原 DB 在后。
      // 升级路径(v1→v2)必须沿用**最初**的原始体积/SHA,否则 provenance 会
      // 退化成"上一轮裁后的大小"。
      final priorOriginalBytes = priorManifest?['original_db_bytes'];
      final priorOriginalSha = priorManifest?['original_db_sha256'];
      final upgraded = manifestExists;
      final manifest = <String, Object?>{
        'schema': DatabaseRecipeManifest.schema,
        'created_at': DateTime.now().toUtc().toIso8601String(),
        'original_db_bytes': priorOriginalBytes ?? sourceBytes,
        'original_db_sha256': priorOriginalSha ?? sourceSha,
        if (upgraded) 'upgraded_from_bytes': sourceBytes,
        'pruned_db_bytes': prunedBytes,
        'preserved_table_sha256': pre,
        'keypoints_xy_sha256': preXy,
        'deleted': 'descriptors(匹配中间物;可从归档帧重提,语义档) + '
            'keypoints 仿射形状列 a11/a12/a21/a22(匹配期形状信息,重建只读 x,y)'
            '${dropMatches ? ' + matches 原始匹配表(已蒸馏成 TVG 内点)' : ''}',
        'drop_raw_matches': dropMatches,
        'rationale':
            'b1-regen-ceiling-PROVEN: 匹配图不可从 q65 帧再生(轨迹-24%),必须保留',
      };
      final manifestFile = File(
          '${captureDirectory.path}/${DatabaseRecipeManifest.fileName}');
      {
        // 总是原子重写(升级路径要换 schema/补字段;崩溃重做时内容等价)。
        final tmp = File('${manifestFile.path}.tmp');
        await tmp.writeAsString(
            const JsonEncoder.withIndent(' ').convert(manifest));
        await tmp.rename(manifestFile.path);
      }
      if (!await _canContinueNow()) {
        // manifest 已提交但未替换:重跑时 already_pruned 不成立(源仍带
        // descriptors)——重新验证再替换即可,幂等。这里直接完成替换,
        // 替换是单个 rename,不可中断出坏态。
      }
      // 侧车先就位(盖章版覆盖原版),再换 DB —— 两者必须成对。
      await File('${pruned.path}$_poseSidecarSuffix')
          .rename('${source.path}$_poseSidecarSuffix');
      await pruned.rename(source.path);
      // 陈旧伴生清除:裁后 db 自洽(prune 内已 checkpoint TRUNCATE),留着只会
      // 让下游 ZPAQ 事务继续判 db_not_cold。
      await _dropStaleSiblings(source);
      return DatabaseRecipeResult(
        applicable: true,
        committed: true,
        deletedBytes: sourceBytes - prunedBytes, // 本轮省下(升级轮=仿射列)
      );
    } catch (e) {
      return DatabaseRecipeResult(reason: 'exception:$e');
    }
  }

  Future<bool> _canContinueNow() async =>
      canContinue == null || await canContinue!();
}

/// 核的 ARKit 位姿侧车后缀(ArkitPoseStorePath: `<db>`.arkit_pose_v1)。
const _poseSidecarSuffix = '.arkit_pose_v1';

/// 空表的内容摘要=空输入 SHA-256(e3b0c442…)。
const _sha256OfNothing =
    'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';

Future<String> _sha256Of(File file) async {
  final digest = await sha256.bind(file.openRead()).first;
  return digest.toString();
}

/// 只在安全时(无 -journal 且 -wal 为空)清除陈旧伴生:它们是刚才只读式
/// 访问留下的空壳,留着会让既有 ZPAQ 事务永久判 db_not_cold。
Future<void> _dropStaleSiblings(File db) async {
  try {
    if (await File('${db.path}-journal').exists()) return;
    final wal = File('${db.path}-wal');
    if (await wal.exists() && await wal.length() != 0) return;
    await _deleteIfPresent(wal);
    await _deleteIfPresent(File('${db.path}-shm'));
  } on FileSystemException {
    // 清不掉只是错过一次 ZPAQ,不影响正确性。
  }
}

/// 删除 db 与其 -wal/-shm/-journal 伴生文件。
Future<void> _deleteWithSiblings(File db) async {
  await _deleteIfPresent(db);
  await _deleteSiblingsOnly(db);
}

Future<void> _deleteSiblingsOnly(File db) async {
  for (final suffix in const <String>['-wal', '-shm', '-journal']) {
    await _deleteIfPresent(File('${db.path}$suffix'));
  }
}

Future<void> _deleteIfPresent(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // 失败时上层已 fail closed。
  }
}
