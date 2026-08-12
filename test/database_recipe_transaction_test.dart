// B1 无损形态(删描述子保匹配图)的机件测试。
//
// 裁剪/盖章本体依赖 iOS 静态链接的 native 符号,单测无法执行——那部分由
// host 台架(b1-prune-form-host.json:五表逐字节相同、裁后重建指标逐位相同)
// 与设备门(pw_b1_gate)把关。此处只钉住不依赖 native 的合同。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pocketworld_flutter/official_capture/database_recipe_transaction.dart';

void main() {
  late Directory captureDir;

  setUp(() async {
    captureDir = await Directory.systemTemp.createTemp('pw_prune_');
  });

  tearDown(() async {
    if (await captureDir.exists()) await captureDir.delete(recursive: true);
  });

  test('生产总闸已开(设备门 PASS 后用户签决 2026-08-11)', () {
    expect(DatabaseRecipeTransaction.enabled, isTrue,
        reason: '依据 b1-prune-device-gate-PASS.json;回退把它改回 false');
  });

  test('闸开着也不许在非 iOS 上动字节(native 符号只在 Runner)', () async {
    final db = File('${captureDir.path}/official_sfm_live.db');
    await db.writeAsBytes(List.filled(4096, 1));
    final r = await const DatabaseRecipeTransaction().recipeCapture(captureDir);
    expect(r.applicable, Platform.isIOS ? anything : isFalse);
    if (!Platform.isIOS) expect(r.reason, 'platform');
    expect(await db.exists(), isTrue);
    expect(await db.length(), 4096, reason: '未过验证链绝不动源字节');
  });

  test('非 iOS 平台裁剪本体不适用(native 符号只在 Runner 里)', () async {
    final r = await const DatabaseRecipeTransaction().pruneCapture(captureDir);
    expect(r.applicable, isFalse);
    expect(r.reason, Platform.isIOS ? isNot('platform') : 'platform');
  });

  test('保全表清单=匹配图三件套+相机+图像(变更须升 schema)', () {
    expect(DatabaseRecipeManifest.preservedTables, <String>[
      'cameras',
      'images',
      'keypoints',
      'matches',
      'two_view_geometries',
    ]);
    expect(DatabaseRecipeManifest.preservedTables, isNot(contains('descriptors')));
  });

  test('prune manifest 读写与 schema 门', () async {
    expect(await DatabaseRecipeManifest.exists(captureDir), isFalse);
    final f = File('${captureDir.path}/${DatabaseRecipeManifest.fileName}');
    await f.writeAsString(jsonEncode({
      'schema': DatabaseRecipeManifest.schema,
      'pruned_db_bytes': 10932224,
      'preserved_table_sha256': {'keypoints': 'abc'},
    }));
    expect(await DatabaseRecipeManifest.exists(captureDir), isTrue);
    expect((await DatabaseRecipeManifest.read(captureDir))!['pruned_db_bytes'],
        10932224);
    await f.writeAsString(jsonEncode({'schema': 'wrong'}));
    expect(await DatabaseRecipeManifest.read(captureDir), isNull);
  });
}
