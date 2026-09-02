/// B1 无损形态设备验收门(pw_b1_gate)
///
/// 文件触发(与 AetherEnvFile 同款,零 UI):启动时若存在
/// `Documents/pw_b1_gate_request.json`,删除请求文件并在后台对指定 capture
/// 跑两臂重建对照,结果写 `Documents/pw_b1_gate_report.json`:
///   A 臂(对照):DB 原样副本 → resume 重建
///   B 臂(裁剪):副本裁掉 descriptors + 重新盖章侧车 → resume 重建
/// 判据:B 臂成功且交付点数/配准与 A 臂同带 → 形态在真机成立。
///
/// **绝不触碰 capture 目录**:一切在 `Documents/pw_b1_gate/<id>/` 内的副本上
/// 进行;源 DB 只读。请求文件由开发侧投放,正常用户永远不会触发。
///
/// ⚠️ 重建持有 reconstructionLease:执行期间用户开拍会失败。只在设备空闲
/// 且亮屏时投放(钩子挂首帧回调,锁屏不跑)。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'database_archive_manifest.dart';
import 'database_archive_resolver.dart';
import 'database_prune_ffi.dart';
import 'database_recipe_transaction.dart';
import 'photo_archive_runtime.dart';
import 'sfm_live_recon.dart';

const _poseSidecarSuffix = '.arkit_pose_v1';

Future<void> maybeRunB1Gate(String documentsPath) async {
  final request = File('$documentsPath/pw_b1_gate_request.json');
  try {
    if (!await request.exists()) return;
  } catch (_) {
    return;
  }
  Map<String, dynamic> req;
  try {
    req = jsonDecode(await request.readAsString()) as Map<String, dynamic>;
  } catch (_) {
    try {
      await request.delete();
    } catch (_) {}
    return;
  }
  // 请求立刻消费:一次投放只跑一次,崩溃也不会开机循环。
  try {
    await request.delete();
  } catch (_) {}

  final captureId = req['capture_id'] as String?;
  if (captureId == null || captureId.isEmpty) return;
  final captureDir = Directory('$documentsPath/captures_official/$captureId');
  final gateDir = Directory('$documentsPath/pw_b1_gate/$captureId');
  final report = File('$documentsPath/pw_b1_gate_report.json');
  final result = <String, Object?>{
    'schema': 'pw_b1_prune_gate_report_v1',
    'capture_id': captureId,
  };

  Future<void> flush(String stage) async {
    result['stage'] = stage;
    result['updated_at'] = DateTime.now().toUtc().toIso8601String();
    try {
      await report.writeAsString(jsonEncode(result));
    } catch (_) {}
  }

  await flush('starting');
  try {
    var source = File('${captureDir.path}/official_sfm_live.db');
    final sidecar = File('${source.path}$_poseSidecarSuffix');
    if (!await sidecar.exists()) {
      result['error'] = 'pose sidecar missing';
      await flush('inputs_missing');
      return;
    }
    if (await gateDir.exists()) await gateDir.delete(recursive: true);
    await gateDir.create(recursive: true);

    // 源 DB 已被 ZPAQ 归档掉时,把归档三件套复制进门目录再物化 —— capture
    // 目录**一个字节不动**。此时的"对照臂"= 当前生产态(已裁描述子/仿射),
    // 正好是验证下一级增量所需要的基准。
    if (!await source.exists()) {
      final src = Directory('${gateDir.path}/arm_src')..createSync();
      var ok = true;
      for (final rel in <String>[
        'official_database_archive_policy.json',
        DatabaseArchiveManifest.fileName,
        DatabaseArchiveManifest.archiveFileName,
      ]) {
        final f = File('${captureDir.path}/$rel');
        if (!await f.exists()) {
          ok = false;
          break;
        }
        await f.copy('${src.path}/$rel');
      }
      if (ok) {
        final resolved = await DatabaseArchiveResolver(
          codec: databaseArchiveCodec,
          preprocessor: databaseArchivePreprocessor,
        ).resolveDatabase(src);
        if (resolved != null) {
          source = resolved;
          result['materialized_from_archive'] = true;
        } else {
          ok = false;
        }
      }
      if (!ok) {
        result['error'] = 'db absent and archive materialization failed';
        await flush('inputs_missing');
        return;
      }
    }

    // A 臂:对照副本(源 DB 或从归档物化出的当前生产态)。
    final armA = Directory('${gateDir.path}/arm_full')..createSync();
    final dbA = File('${armA.path}/official_sfm_live.db');
    await source.copy(dbA.path);
    await sidecar.copy('${dbA.path}$_poseSidecarSuffix');
    result['source_db_bytes'] = await source.length();

    // B 臂:裁剪 + 重新盖章(复用生产事务的门模式,不动 capture)。
    final armB = Directory('${gateDir.path}/arm_pruned')..createSync();
    final dbB = File('${armB.path}/official_sfm_live.db');
    await source.copy(dbB.path);
    await sidecar.copy('${dbB.path}$_poseSidecarSuffix');
    // 门里强制试跑**当前最深一级**(含第三级 drop matches),即使生产常量
    // 还没翻 —— 门的意义就是先验证再翻闸。
    const gateDropsMatches = true;
    final prune = await const DatabaseRecipeTransaction().pruneCapture(
      armB,
      outputDbPath: '${armB.path}/pruned.db',
      dropRawMatchesOverride: gateDropsMatches,
    );
    result['prune'] = {
      'applicable': prune.applicable,
      'reason': prune.reason,
      'deleted_bytes': prune.deletedBytes,
    };
    if (!prune.applicable) {
      await flush('prune_failed');
      return;
    }
    // 裁后副本就位(pruneCapture 已把盖章侧车写在 pruned.db 旁)。
    await File(dbB.path).delete();
    await File('${dbB.path}$_poseSidecarSuffix').delete();
    await File('${armB.path}/pruned.db').rename(dbB.path);
    await File('${armB.path}/pruned.db$_poseSidecarSuffix')
        .rename('${dbB.path}$_poseSidecarSuffix');
    result['pruned_db_bytes'] = await dbB.length();

    // 保全表逐字节对账(裁前 vs 裁后)。
    final tables = <String, Object?>{};
    var tablesOk = true;
    for (final t in DatabaseRecipeManifest.preservedTablesFor(
      dropRawMatches: gateDropsMatches,
    )) {
      final a = await tableContentSha256(dbA.path, t);
      final b = await tableContentSha256(dbB.path, t);
      final same = a != null && a == b;
      tables[t] = same ? 'identical' : 'MISMATCH';
      tablesOk &= same;
    }
    result['preserved_tables'] = tables;
    result['preserved_tables_ok'] = tablesOk;
    await flush('pruned');

    // 两臂重建(产品 resume 路径,串行——lease 独占)。
    for (final arm in <List<Object>>[
      ['full', dbA],
      ['pruned', dbB],
    ]) {
      final name = arm[0] as String;
      final db = arm[1] as File;
      await flush('rebuild_${name}_in_progress');
      result['rebuild_$name'] = await _rebuild(db.path);
      await flush('rebuild_${name}_done');
    }

    final a = result['rebuild_full'] as Map<String, Object?>?;
    final b = result['rebuild_pruned'] as Map<String, Object?>?;
    final ok =
        tablesOk &&
        a?['ok'] == true &&
        b?['ok'] == true &&
        (b?['registered'] as int? ?? -1) == (a?['registered'] as int? ?? -2);
    await flush(ok ? 'done_pass' : 'done_fail');
  } catch (e, st) {
    result['error'] = '$e';
    result['stack'] = '$st';
    await flush('exception');
  }
}

/// 走产品 resume 路径重建一次,返回指标。
Future<Map<String, Object?>> _rebuild(String dbPath) async {
  final started = DateTime.now();
  SfmLiveRecon? recon;
  try {
    recon = await SfmLiveRecon.start(dbPath: dbPath);
    if (recon == null) {
      return {'ok': false, 'error': 'start failed (lease busy?)'};
    }
    final done = Completer<Map<String, Object?>>();
    final sub = recon.events.listen((e) {
      if (e is SfmLiveRefined && !done.isCompleted) {
        done.complete({
          'ok': true,
          'registered': e.snapshot.registeredCount,
          'delivered_points': e.snapshot.xyz.length ~/ 3,
          'summary': e.snapshot.summary,
          'refine_ms': e.refineMs,
        });
      } else if (e is SfmLiveFailed && !done.isCompleted) {
        done.complete({'ok': false, 'error': '${e.stage}: ${e.message}'});
      }
    });
    try {
      recon.resumeFromDb(imageWidth: 4032, imageHeight: 3024);
      final out = await done.future.timeout(
        const Duration(minutes: 25),
        onTimeout: () => {'ok': false, 'error': 'timeout'},
      );
      out['elapsed_ms'] = DateTime.now().difference(started).inMilliseconds;
      return out;
    } finally {
      await sub.cancel();
    }
  } catch (e) {
    return {'ok': false, 'error': '$e'};
  } finally {
    try {
      await recon?.dispose();
    } catch (_) {}
  }
}
