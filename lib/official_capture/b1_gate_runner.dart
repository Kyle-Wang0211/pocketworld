/// B1 设备验收门执行器(pw_b1_gate)
///
/// 文件触发(与 AetherEnvFile 同款模式,零 UI):启动时若存在
/// `Documents/pw_b1_gate_request.json` 则删除请求文件并在后台执行
/// 再生验收:对指定 capture 连跑 N 遍 [SfmDbRegen.regenerate](输出到
/// `Documents/pw_b1_gate/<capture_id>/run_<i>/`,不触碰 capture 目录),
/// 进度与结果写 `Documents/pw_b1_gate_report.json`。
///
/// 用途:V4 确定性(两遍 db 的 SHA-256/体积对比;不等时把两份 db 拉回
/// Mac 做表级规范 diff)与 V5 质量(finalize 指标 vs 原采集 sparse meta)。
/// 请求文件由开发侧经 devicectl 投放;正常用户永远不会触发。
///
/// ⚠️ 再生持有 reconstructionLease:执行期间用户开拍会 start 失败。
/// 只在确认设备空闲时投放请求文件。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'sfm_db_regen.dart';

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
  // 请求文件立刻删除:一次投放只跑一次,崩溃也不会开机循环。
  try {
    await request.delete();
  } catch (_) {}

  final captureId = req['capture_id'] as String?;
  final runs = (req['runs'] as num?)?.toInt() ?? 2;
  if (captureId == null || captureId.isEmpty) return;
  final captureDir =
      Directory('$documentsPath/captures_official/$captureId');
  final gateDir = Directory('$documentsPath/pw_b1_gate/$captureId');
  final report = File('$documentsPath/pw_b1_gate_report.json');

  final results = <Map<String, Object?>>[];
  Future<void> writeReport(String stage) async {
    try {
      await report.writeAsString(jsonEncode({
        'schema': 'pw_b1_gate_report_v1',
        'capture_id': captureId,
        'stage': stage,
        'runs_requested': runs,
        'runs': results,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }));
    } catch (_) {}
  }

  await writeReport('starting');
  try {
    if (!await captureDir.exists()) {
      await writeReport('capture_missing');
      return;
    }
    if (await gateDir.exists()) await gateDir.delete(recursive: true);
    for (var i = 0; i < runs; i++) {
      final runDir = Directory('${gateDir.path}/run_$i');
      await runDir.create(recursive: true);
      final cache = Directory('${runDir.path}/cache');
      await cache.create(recursive: true);
      await writeReport('run_${i}_in_progress');
      final r = await SfmDbRegen.regenerate(
        captureDirectory: captureDir,
        targetDbPath: '${runDir.path}/official_sfm_live.db',
        materializeCache: cache,
      );
      final entry = <String, Object?>{'run': i, ...r.toJson()};
      final db = File('${runDir.path}/official_sfm_live.db');
      if (await db.exists()) {
        entry['db_bytes'] = await db.length();
        entry['db_sha256'] =
            (await sha256.bind(db.openRead()).first).toString();
      }
      results.add(entry);
      // 物化缓存即刻清掉(12MP JPEG × 帧数,不留盘)。
      try {
        await cache.delete(recursive: true);
      } catch (_) {}
      await writeReport('run_${i}_done');
      if (!r.ok) break;
    }
    final shas = results
        .map((r) => r['db_sha256'])
        .whereType<String>()
        .toSet();
    final allOk = results.isNotEmpty &&
        results.length == runs &&
        results.every((r) => r['ok'] == true);
    if (allOk) {
      await writeReport(
          shas.length == 1 ? 'done_bit_identical' : 'done_semantic_only');
    } else {
      await writeReport('done_with_failures');
    }
  } catch (e) {
    results.add({'error': '$e'});
    await writeReport('exception');
  }
}
